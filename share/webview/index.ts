import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { createServer, request, STATUS_CODES, type IncomingMessage, type ServerResponse } from "node:http";
import type { Socket } from "node:net";
import type { components } from "../pi/ko-api.d.ts";

type SupportedLine = Extract<components["schemas"]["ServeOut"], { type: "supported" }>;
type Options = { ko?: string; target?: "pane" | "browser"; timeoutMs?: number };

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

export function webview(options: Options & { target: "browser" }): Promise<Webview>;
export function webview(options?: Options): Promise<Webview | null>;
export async function webview(options: Options = {}): Promise<Webview | null> {
  const timeoutMs = options.timeoutMs === undefined ? 5000 : options.timeoutMs;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2147483647) throw new Error("timeoutMs must be a positive timer duration");
  const dir = mkdtempSync(join(tmpdir(), "kido-webview-"));
  chmodSync(dir, 0o700);
  const socketPath = join(dir, "webview.sock");
  const events = new EventEmitter();
  const children = new Map<ChildProcess, { kind: "command" | "bridge"; cancel(): void; stopping?: Promise<void> }>();
  const stop = (child: ChildProcess): Promise<void> => {
    const record = children.get(child);
    if (!record) return Promise.resolve();
    if (record.stopping) return record.stopping;
    const work = new Promise<void>(resolve => {
      let ended = false;
      const finish = () => {
        if (ended) return;
        ended = true; clearTimeout(timer); child.off("close", finish); child.unref();
        child.stdin?.destroy(); child.stdout?.destroy(); child.stderr?.destroy(); resolve();
      };
      const timer = setTimeout(() => { child.kill("SIGKILL"); finish(); }, 1000);
      if (child.exitCode !== null || child.signalCode !== null) finish();
      else { child.once("close", finish); child.kill("SIGTERM"); }
    });
    record.stopping = work;
    return work;
  };
  const own = (child: ChildProcess, kind: "command" | "bridge", cancel: () => void) => {
    children.set(child, { kind, cancel });
    child.once("close", () => children.delete(child));
  };
  const transport = options.target === "browser"
    ? { kind: "browser" as const, listener: Object.assign(createServer(), { httpAllowHalfOpen: true }), sockets: new Set<Socket>(), responses: new Set<ServerResponse>(), url: "" }
    : { kind: "pane" as const, restart: undefined as ReturnType<typeof setTimeout> | undefined };
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
  const deadline = (ms: number, fail: () => void) => {
    const timer = setTimeout(fail, Math.max(0, ms));
    return () => clearTimeout(timer);
  };
  const command = (executable: string, args: string[], stdio: "ignore" | ["ignore", "inherit", "pipe"], budget = timeoutMs) => new Promise<void>((resolve, reject) => {
    const child = spawn(executable, args, { stdio });
    const stderr = stderrTail(child);
    let ended = false;
    let failure: Error | undefined;
    const finish = (error?: Error) => {
      if (ended) return;
      ended = true; cancelDeadline();
      if (failure || error) reject(failure ?? error); else resolve();
    };
    const cancel = () => { cancelDeadline(); failure = new Error("webview is closed"); void stop(child).then(() => finish(failure)); };
    own(child, "command", cancel);
    const cancelDeadline = deadline(budget, () => { failure = new Error(closed ? "webview is closed" : "webview command timed out"); void stop(child).then(() => finish(failure)); });
    child.once("error", finish);
    child.once("close", code => finish(code === 0 ? undefined : new Error(stderr() || `webview command exited with ${code}`)));
  });
  const cleanup = () => {
    closed = true;
    if (transport.kind === "browser") {
      transport.listener.close();
      for (const socket of transport.sockets) socket.destroy();
    } else if (transport.restart) clearTimeout(transport.restart);
    for (const record of children.values()) record.cancel();
    rmSync(dir, { recursive: true, force: true });
    events.removeAllListeners(); process.off("exit", cleanup);
  };
  process.once("exit", cleanup);
  if (transport.kind === "browser") {
    const { listener, sockets } = transport;
    let port: number;
    const check = (req: IncomingMessage) => {
      const hosts = req.headersDistinct.host ?? [], origins = req.headersDistinct.origin ?? [];
      if (hosts.length !== 1 || ![`127.0.0.1:${port}`, `localhost:${port}`].includes(hosts[0]!)) return 421;
      return origins.length && (origins.length !== 1 || origins[0] !== `http://${hosts[0]}`) ? 403 : undefined;
    };
    const pageHeaders = (pairs: string[]) => pairs.filter((_value, index) => !pairs[index - index % 2]!.toLowerCase().startsWith("kido-"));
    const headers = (message: IncomingMessage) => {
      const skip = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade', ...(message.headers.connection ?? '').split(',').map(value => value.trim().toLowerCase())]);
      return pageHeaders(message.rawHeaders).filter((_value, index, values) => !skip.has(values[index - index % 2]!.toLowerCase()));
    };
    const track = (socket: Socket) => { sockets.add(socket); socket.once("close", () => sockets.delete(socket)); socket.on("error", () => socket.destroy()); };
    listener.on("connection", track);
    listener.on("request", (req, res) => {
      const socket = req.socket;
      transport.responses.add(res);
      const finish = () => {
        transport.responses.delete(res);
        if (closed && ![...transport.responses].some(other => other.socket === socket)) socket.end();
      };
      res.once("finish", finish); res.once("close", finish);
      const status = check(req);
      if (status) { res.writeHead(status, { Connection: "close" }); res.end(); return; }
      const app = request({ socketPath, path: req.url, method: req.method, headers: headers(req), agent: false }, upstream => {
        res.writeHead(upstream.statusCode ?? 502, headers(upstream));
        upstream.pipe(res);
        upstream.on("error", () => res.destroy());
      });
      app.on("socket", track);
      const eof = () => { if (app.writableFinished) app.socket?.end(); else app.once("finish", () => app.socket?.end()); };
      req.socket.once("end", eof);
      res.once("close", () => req.socket.off("end", eof));
      app.on("error", () => res.destroy());
      req.on("aborted", () => app.destroy());
      res.on("close", () => { if (!res.writableFinished) app.destroy(); });
      req.pipe(app);
    });
    listener.on("upgrade", (req, socket, head) => {
      const status = check(req);
      if (status) { socket.end(`HTTP/1.1 ${status} ${STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); return; }
      const app = request({ socketPath, path: req.url, method: req.method, headers: pageHeaders(req.rawHeaders), agent: false });
      app.on("socket", track);
      socket.on("close", () => app.destroy());
      app.on("error", () => socket.destroy());
      app.on("response", response => { response.destroy(); socket.destroy(); });
      app.on("upgrade", (response, upstream, bytes) => {
        socket.write(`HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\n${response.rawHeaders.reduce((text, value, index) => text + (index % 2 ? `${value}\r\n` : `${value}: `), "")}\r\n`);
        if (bytes.length) socket.write(bytes);
        if (head.length) upstream.write(head);
        upstream.on("error", () => socket.destroy());
        upstream.on("close", () => socket.destroy());
        socket.on("close", () => upstream.destroy());
        socket.pipe(upstream); upstream.pipe(socket);
      });
      app.end();
    });
    try {
      await new Promise<void>((resolve, reject) => {
        const fail = (error: Error) => { cancelDeadline(); listener.off("error", fail); reject(error); };
        const cancelDeadline = deadline(timeoutMs, () => fail(new Error("webview readiness timed out")));
        listener.once("error", fail);
        listener.listen(0, "127.0.0.1", () => { cancelDeadline(); listener.off("error", fail); resolve(); });
      });
      const address = listener.address();
      if (!address || typeof address === "string") throw new Error("missing browser listener address");
      port = address.port; transport.url = `http://127.0.0.1:${port}/`;
    } catch (error) { cleanup(); throw error; }
  } else {
    const pane = transport;
    const start = (initial: boolean) => new Promise<boolean>((resolve, reject) => {
      if (closed) { resolve(false); return; }
      const bridge = spawn(ko, ["webview", "serve", "--socket", socketPath], { stdio: "pipe" });
      let ready = false, ended = false;
      let failure: Error | undefined;
      const stderr = stderrTail(bridge);
      bridge.stdin.on("error", () => {});
      const lines = createInterface({ input: bridge.stdout });
      const cancelDeadline = deadline(timeoutMs, () => {
        failure = new Error("webview readiness timed out");
        void stop(bridge).then(() => end(null, failure));
      });
      const end = (code: number | null, error?: Error & { code?: string }) => {
        if (ended) return;
        ended = true; cancelDeadline(); lines.close(); setSupported(false);
        if (!ready && initial) {
          cleanup();
          if (code === 6 || error?.code === "ENOENT") resolve(false);
          else reject(new Error(failure?.message || stderr() || error?.message || "ko webview serve exited before supported"));
        } else {
          if (!closed) pane.restart = setTimeout(() => { void start(false); }, 100);
          resolve(false);
        }
      };
      own(bridge, "bridge", () => { void stop(bridge).then(() => end(null)); });
      lines.on("line", line => {
        let value: SupportedLine;
        try { value = JSON.parse(line); } catch { return; }
        if (!value || value.type !== "supported" || typeof value.supported !== "boolean") return;
        setSupported(value.supported); ready = true; cancelDeadline(); resolve(true);
      });
      bridge.once("error", error => end(null, error)); bridge.once("close", code => end(code));
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
        if (transport.kind === "browser") await command(process.platform === "darwin" ? "open" : "xdg-open", [`${transport.url.slice(0, -1)}${path}`], "ignore");
        else {
          if (!process.stdout.isTTY) throw new Error("webview.show requires a TTY on stdout");
          await command(ko, ["webview", "enter", ...(path === undefined ? [] : ["--path", path])], ["ignore", "inherit", "pipe"]);
        }
        if (!closed) shown = { path };
      });
      return action;
    },
    hide() {
      if (closed) return Promise.reject(new Error("webview is closed"));
      if (transport.kind === "browser") return Promise.resolve();
      action = action.catch(() => {}).then(async () => {
        if (closed) throw new Error("webview is closed");
        if (!shown) return;
        await command(ko, ["webview", "leave"], ["ignore", "inherit", "pipe"]); shown = undefined;
      });
      return action;
    },
    close() {
      if (closing) return closing;
      closed = true; events.removeAllListeners();
      if (transport.kind === "pane" && transport.restart) clearTimeout(transport.restart);
      if (transport.kind === "browser") for (const record of children.values()) if (record.kind === "command") record.cancel();
      const until = Date.now() + timeoutMs;
      const expire = deadline(timeoutMs, () => { for (const record of children.values()) record.cancel(); });
      closing = (async () => {
        try {
          if (transport.kind === "browser") {
            await new Promise<void>(resolve => {
              const timer = setTimeout(resolve, Math.min(timeoutMs, 1000));
              transport.listener.close(() => { clearTimeout(timer); resolve(); });
              transport.listener.closeIdleConnections();
            });
          } else {
            await action.catch(() => {});
            if (shown && Date.now() < until) await command(ko, ["webview", "leave"], ["ignore", "inherit", "pipe"], until - Date.now()).catch(() => {});
            await Promise.all([...children.keys()].map(child => new Promise<void>(resolve => {
              const cancelDeadline = deadline(until - Date.now(), () => { void stop(child).then(resolve); });
              child.once("close", () => { cancelDeadline(); resolve(); }); child.stdin?.end();
              if (child.exitCode !== null || child.signalCode !== null) { cancelDeadline(); resolve(); }
            })));
          }
        } finally {
          shown = undefined;
          await Promise.all([...children.keys()].map(stop)); expire(); cleanup();
        }
      })();
      return closing;
    },
  };
}
