import { spawn, type ChildProcess, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { createServer, connect, type Socket, type Server } from "node:net";
import type { components } from "../pi/ko-api.d.ts";

type SupportedLine = Extract<components["schemas"]["ServeOut"], { type: "supported" }>;
const BROWSER_CLOSE_MS = 1000;

export type Webview = {
  readonly socketPath: string;
  readonly url?: string;
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

export function webview(options: { target: "browser"; ko?: string }): Promise<Webview>;
export function webview(options?: { ko?: string; target?: "pane" | "browser" }): Promise<Webview | null>;
export async function webview(options: { ko?: string; target?: "pane" | "browser" } = {}): Promise<Webview | null> {
  const dir = mkdtempSync(join(tmpdir(), "kido-webview-"));
  chmodSync(dir, 0o700);
  const socketPath = join(dir, "webview.sock");
  const events = new EventEmitter();
  const transport: { kind: "browser"; listener: Server; connections: Set<{ socket: Socket; app?: Socket }>; url?: string } | { kind: "pane"; child?: ChildProcessWithoutNullStreams; restart?: ReturnType<typeof setTimeout> } = options.target === "browser"
    ? { kind: "browser", listener: createServer({ allowHalfOpen: true }), connections: new Set() }
    : { kind: "pane" };
  const ko = options.ko ?? "ko";
  let supported = transport.kind === "browser";
  let shown: { path: string | undefined } | undefined;
  let closed = false;
  let closing: Promise<void> | undefined;
  let action = Promise.resolve();
  const setSupported = (value: boolean) => {
    if (supported === value) return;
    supported = value;
    if (!closed) events.emit("supported", value);
  };
  const command = (args: string[]) => new Promise<void>((resolve, reject) => {
    const child = spawn(ko, ["webview", ...args], { stdio: ["ignore", "inherit", "pipe"] });
    const stderr = stderrTail(child);
    child.once("error", reject);
    child.once("close", code => code === 0 ? resolve() : reject(new Error(stderr() || `ko webview exited with ${code}`)));
  });
  const cleanup = () => {
    closed = true;
    if (transport.kind === "browser") {
      transport.listener.close();
      for (const { socket, app } of transport.connections) { socket.destroy(); app?.destroy(); }
    } else {
      if (transport.restart) clearTimeout(transport.restart);
      transport.child?.stdin.end();
    }
    rmSync(dir, { recursive: true, force: true });
    events.removeAllListeners();
    process.off("exit", cleanup);
  };
  process.once("exit", cleanup);
  if (transport.kind === "browser") {
    const { listener, connections } = transport;
    let port: number;
    listener.on("connection", socket => {
      const connection: { socket: Socket; app?: Socket } = { socket };
      connections.add(connection);
      socket.once("close", () => connections.delete(connection));
      socket.on("error", () => socket.destroy());
      let head = Buffer.alloc(0);
      const reject = (status: string) => socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`, () => socket.destroy());
      const read = (bytes: Buffer) => {
        head = Buffer.concat([head, bytes]);
        const end = head.indexOf("\r\n\r\n");
        if ((end < 0 && head.length > 16384) || end + 4 > 16384) {
          socket.off("data", read);
          reject("431 Request Header Fields Too Large");
          return;
        }
        if (end < 0) return;
        socket.off("data", read);
        const hosts = head.subarray(0, end).toString("latin1").split("\r\n").slice(1).filter(line => /^host:/i.test(line)).map(line => line.slice(5).trim());
        if (hosts.length !== 1 || ![`127.0.0.1:${port}`, `localhost:${port}`].includes(hosts[0]!)) {
          reject("421 Misdirected Request");
          return;
        }
        socket.pause();
        const app = connect({ path: socketPath, allowHalfOpen: true });
        connection.app = app;
        app.once("close", () => {
          if (app.readableEnded) socket.end();
          else socket.destroy();
        });
        socket.once("close", () => { if (!socket.writableFinished || !socket.readableEnded) app.destroy(); });
        app.on("error", () => { app.destroy(); socket.destroy(); });
        socket.on("error", () => app.destroy());
        app.once("connect", () => {
          app.write(head);
          socket.pipe(app);
          app.pipe(socket);
        });
      };
      socket.on("data", read);
      socket.once("end", () => { if (head.indexOf("\r\n\r\n") < 0) reject("400 Bad Request"); });
    });
    try {
      await new Promise<void>((resolve, reject) => {
        listener.once("error", reject);
        listener.listen(0, "127.0.0.1", () => { listener.off("error", reject); resolve(); });
      });
      const address = listener.address();
      if (!address || typeof address === "string") throw new Error("missing browser listener address");
      port = address.port;
      transport.url = `http://127.0.0.1:${port}/`;
    } catch (error) { cleanup(); throw error; }
  } else {
    const pane = transport;
    const start = (initial: boolean) => new Promise<boolean>((resolve, reject) => {
      if (closed) { resolve(false); return; }
      const bridge = spawn(ko, ["webview", "serve", "--socket", socketPath], { stdio: "pipe" });
      pane.child = bridge;
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
          if (code === 6 || error?.code === "ENOENT") resolve(false);
          else reject(new Error(stderr() || error?.message || "ko webview serve exited before supported"));
        } else if (!closed) {
          pane.restart = setTimeout(() => { void start(false); }, 100);
          resolve(false);
        } else resolve(false);
      };
      bridge.once("error", error => end(null, error));
      bridge.once("close", code => end(code));
    });
    if (!await start(true)) return null;
  }
  return {
    socketPath,
    get url() { return transport.kind === "browser" ? transport.url : undefined; },
    get supported() { return supported; },
    get shown() { return shown !== undefined; },
    on(event, listener) { events.on(event, listener); },
    off(event, listener) { events.off(event, listener); },
    show(path) {
      if (closed) return Promise.reject(new Error("webview is closed"));
      if (transport.kind === "browser") {
        path ??= "/";
        if (!path.startsWith("/")) return Promise.reject(new Error("browser webview path must start with /"));
      }
      action = action.catch(() => {}).then(async () => {
        if (closed) throw new Error("webview is closed");
        if (shown && shown.path === path) return;
        if (transport.kind === "browser") {
          await new Promise<void>((resolve, reject) => {
            const child = spawn(process.platform === "darwin" ? "open" : "xdg-open", [`${transport.url!.slice(0, -1)}${path}`], { stdio: "ignore" });
            child.once("error", reject);
            child.once("close", code => code === 0 ? resolve() : reject(new Error(`browser opener exited with ${code}`)));
          });
        } else {
          if (!process.stdout.isTTY) throw new Error("webview.show requires a TTY on stdout");
          await command(["enter", ...(path === undefined ? [] : ["--path", path])]);
        }
        if (!closed) shown = { path };
      });
      return action;
    },
    hide() {
      if (closed) return Promise.reject(new Error("webview is closed"));
      if (transport.kind === "browser") return Promise.resolve();
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
      if (transport.kind === "browser") {
        const browser = transport;
        browser.listener.close();
        shown = undefined;
        closing = (async () => {
          let timer: ReturnType<typeof setTimeout> | undefined;
          const drained = Promise.all([...browser.connections].map(({ socket, app }) => new Promise<void>(resolve => {
            socket.once("close", () => resolve());
            if (app) app.end();
            else socket.destroy();
          })));
          try {
            await Promise.race([drained, new Promise<void>(resolve => { timer = setTimeout(resolve, BROWSER_CLOSE_MS); })]);
          } finally { clearTimeout(timer); cleanup(); }
        })();
      } else {
        const pane = transport;
        if (pane.restart) clearTimeout(pane.restart);
        closing = (async () => {
          try {
            await action.catch(() => {});
            if (shown) { await command(["leave"]); shown = undefined; }
          } finally {
            const bridge = pane.child;
            if (bridge && bridge.exitCode === null && bridge.signalCode === null) {
              await new Promise<void>(resolve => { bridge.once("close", resolve); bridge.stdin.end(); });
            }
            cleanup();
          }
        })();
      }
      return closing;
    },
  };
}
