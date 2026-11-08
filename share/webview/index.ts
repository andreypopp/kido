import { spawn, type ChildProcess, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { components } from "../pi/ko-api.d.ts";

type SupportedLine = Extract<components["schemas"]["ServeOut"], { type: "supported" }>;

export type Webview = {
  readonly socketPath: string;
  readonly supported: boolean;
  readonly shown: boolean;
  on(event: "supported", listener: (supported: boolean) => void): void;
  off(event: "supported", listener: (supported: boolean) => void): void;
  show(path?: string): Promise<void>;
  hide(): Promise<void>;
  close(): Promise<void>;
};

function stderrTail(child: ChildProcess): () => string {
  let text = "";
  child.stderr?.on("data", bytes => { text = (text + bytes).slice(-16384); });
  return () => text;
}

export async function webview(options: { ko?: string } = {}): Promise<Webview | null> {
  const dir = mkdtempSync(join(tmpdir(), "kido-webview-"));
  chmodSync(dir, 0o700);
  const socketPath = join(dir, "webview.sock");
  const events = new EventEmitter();
  const ko = options.ko ?? "ko";
  let child: ChildProcessWithoutNullStreams | undefined;
  let supported = false;
  let shown: { path: string | undefined } | undefined;
  let closed = false;
  let closing: Promise<void> | undefined;
  let restart: ReturnType<typeof setTimeout> | undefined;
  let action = Promise.resolve();
  const setSupported = (value: boolean) => {
    if (supported === value) return;
    supported = value;
    if (!closed) events.emit("supported", value);
  };
  const command = (args: string[]) => new Promise<void>((resolve, reject) => {
    const command = spawn(ko, ["webview", ...args], { stdio: ["ignore", "inherit", "pipe"] });
    const stderr = stderrTail(command);
    command.once("error", reject);
    command.once("close", code => code === 0 ? resolve() : reject(new Error(stderr() || `ko webview exited with ${code}`)));
  });
  const cleanup = () => {
    closed = true;
    if (restart) clearTimeout(restart);
    child?.stdin.end();
    rmSync(dir, { recursive: true, force: true });
  };
  process.once("exit", cleanup);
  const start = (initial: boolean) => new Promise<boolean>((resolve, reject) => {
    if (closed) { resolve(false); return; }
    const bridge = spawn(ko, ["webview", "serve", "--socket", socketPath], { stdio: "pipe" });
    child = bridge;
    let ready = false;
    const stderr = stderrTail(bridge);
    bridge.stdin.on("error", () => {});
    const lines = createInterface({ input: bridge.stdout });
    lines.on("line", line => {
      let value: SupportedLine;
      try { value = JSON.parse(line); } catch { return; }
      if (!value || value.type !== "supported" || typeof value.supported !== "boolean") return;
      setSupported(value.supported);
      ready = true;
      resolve(true);
    });
    let ended = false;
    const end = (code: number | null, error?: NodeJS.ErrnoException) => {
      if (ended) return;
      ended = true;
      lines.close();
      setSupported(false);
      if (!ready && initial) {
        cleanup();
        process.off("exit", cleanup);
        if (code === 6 || error?.code === "ENOENT") resolve(false);
        else reject(new Error(stderr() || error?.message || "ko webview serve exited before supported"));
      } else if (!closed) {
        restart = setTimeout(() => { void start(false); }, 100);
        resolve(false);
      } else resolve(false);
    };
    bridge.once("error", error => end(null, error));
    bridge.once("close", code => end(code));
  });
  if (!await start(true)) return null;
  return {
    socketPath,
    get supported() { return supported; },
    get shown() { return shown !== undefined; },
    on(event, listener) { events.on(event, listener); },
    off(event, listener) { events.off(event, listener); },
    show(path) {
      if (closed) return Promise.reject(new Error("webview is closed"));
      action = action.catch(() => {}).then(async () => {
        if (shown && shown.path === path) return;
        if (!process.stdout.isTTY) throw new Error("webview.show requires a TTY on stdout");
        await command(["enter", ...(path === undefined ? [] : ["--path", path])]);
        shown = { path };
      });
      return action;
    },
    hide() {
      if (closed) return Promise.reject(new Error("webview is closed"));
      action = action.catch(() => {}).then(async () => {
        if (!shown) return;
        await command(["leave"]);
        shown = undefined;
      });
      return action;
    },
    close() {
      if (closing) return closing;
      if (closed) return Promise.resolve();
      closed = true;
      events.removeAllListeners();
      if (restart) clearTimeout(restart);
      closing = (async () => {
        try {
          await action.catch(() => {});
          if (shown) { await command(["leave"]); shown = undefined; }
        } finally {
          const bridge = child;
          if (bridge && bridge.exitCode === null && bridge.signalCode === null) {
            await new Promise<void>(resolve => { bridge.once("close", resolve); bridge.stdin.end(); });
          }
          cleanup();
          process.off("exit", cleanup);
        }
      })();
      return closing;
    },
  };
}
