import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants } from "node:fs";
import os from "node:os";
import { delimiter, join } from "node:path";
import { errorText, isRecord, isString } from "./text.ts";
import type { components } from "./ko-api.d.ts";
import type { JobEnd } from "./records.ts";
type Api = components["schemas"];
export const KO_TIMEOUT_MS = 5000;
export type RunResult = { ok: true; out: string; raw: string } | { ok: false; error: string; code?: number; out: string; err: string };

export type ExecResult = { end: JobEnd };
const EXEC_CHUNK = 64 * 1024;
const isNodeSignal = (signal: string): signal is NodeJS.Signals => Object.hasOwn(os.constants.signals, signal);
function isExecServer(value: unknown): value is Api["ExecServer"] {
  if (!isRecord(value)) return false;
  if (value.type === "stdout" || value.type === "stderr") return isString(value.data);
  if (value.type === "exit") return typeof value.status === "number" || isString(value.signal);
  return value.type === "error" && isString(value.message);
}

export function lineReader(hold: { partial: Buffer }, onLine: (line: string) => void, cap?: { bytes: number; overflow(): void }): (chunk: Buffer) => void {
  return (chunk) => {
    let rest = Buffer.concat([hold.partial, chunk]);
    for (let at = rest.indexOf(0x0a); at >= 0; at = rest.indexOf(0x0a)) {
      if (cap && at > cap.bytes) { cap.overflow(); return; }
      const line = rest.subarray(0, at).toString("utf8");
      rest = rest.subarray(at + 1);
      if (line) onLine(line);
    }
    if (cap && rest.length > cap.bytes) { cap.overflow(); return; }
    hold.partial = Buffer.from(rest);
  };
}

export function openStream(ko: string, path: string, stderr: "pipe" | "ignore" = "ignore"): ChildProcess {
  const child = spawn(ko, ["api", "--stream", path], { stdio: ["pipe", "pipe", stderr], env: process.env });
  child.on("error", () => {});
  child.stdin?.on("error", () => {});
  return child;
}

export type ExecOptions = {
  onSpawn?: (child: ChildProcess, completion: Promise<ExecResult>) => void;
  argv: string[];
  cwd?: string;
  input?: Buffer;
  signal?: AbortSignal;
  onStdout?: (data: Buffer) => void;
  onStderr?: (data: Buffer) => void;
};

export function runtimeExec(ko: string, runtime: string, opts: ExecOptions): Promise<ExecResult> {
  if (opts.signal?.aborted) return Promise.reject(new Error("aborted"));
  const child = openStream(ko, `/runtimes/${runtime}/exec`, "pipe");
  const completion = new Promise<ExecResult>((resolve, reject) => {
    const stdin = child.stdin;
    let ended: ExecResult | Error | undefined;
    let aborted = false;
    const stderr: Buffer[] = [];
    const onAbort = (): void => {
      aborted = true;
      child.kill();
    };
    opts.signal?.addEventListener("abort", onAbort, { once: true });
    const send = (message: Api["ExecClient"]): boolean => stdin?.write(JSON.stringify(message) + "\n") ?? false;
    send({ type: "exec", argv: opts.argv, ...(opts.cwd === undefined ? {} : { cwd: opts.cwd }), stdin: opts.input !== undefined });
    const input = opts.input ?? Buffer.alloc(0);
    void (async () => {
      for (let at = 0; at < input.length && !stdin?.destroyed; at += EXEC_CHUNK) {
        if (!send({ type: "stdin", data: input.subarray(at, at + EXEC_CHUNK).toString("base64") })) {
          await new Promise<void>((done) => {
            const resume = (): void => {
              stdin?.off("drain", resume);
              child.off("close", resume);
              done();
            };
            stdin?.once("drain", resume);
            child.once("close", resume);
          });
        }
      }
      if (opts.input !== undefined) send({ type: "eof" });
      stdin?.end();
    })();
    child.stdout?.on(
      "data",
      lineReader({ partial: Buffer.alloc(0) }, (line) => {
        let message: unknown;
        try {
          message = JSON.parse(line);
        } catch {
          return;
        }
        if (!isExecServer(message)) return;
        if ("data" in message) (message.type === "stdout" ? opts.onStdout : opts.onStderr)?.(Buffer.from(message.data, "base64"));
        else if ("status" in message) ended = { end: { type: "exit", code: message.status } };
        else if ("signal" in message) {
          const signal = `SIG${message.signal}`;
          ended = {
            end: isNodeSignal(signal) ? { type: "signal", signal } : { type: "failed", message: "the command ended with an unknown signal" },
          };
        }
        else if ("message" in message) ended = new Error(message.message);
      }),
    );
    child.stderr?.on("data", (chunk: Buffer) => stderr.push(chunk));
    const finish = (): void => opts.signal?.removeEventListener("abort", onAbort);
    child.on("error", (error) => {
      finish();
      reject(error);
    });
    child.on("close", () => {
      finish();
      if (aborted) reject(new Error("aborted"));
      else if (ended instanceof Error) reject(ended);
      else if (ended) resolve(ended);
      else reject(new Error(Buffer.concat(stderr).toString("utf8").trim() || "the exec session ended without an exit"));
    });
  });
  opts.onSpawn?.(child, completion);
  return completion;
}

export async function runCommand(command: string, args: string[], opts: { timeoutMs: number; env?: NodeJS.ProcessEnv; input?: string } = { timeoutMs: KO_TIMEOUT_MS }): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: [opts.input === undefined ? "ignore" : "pipe", "pipe", "pipe"], env: opts.env ?? process.env });
    if (opts.input !== undefined) {
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input);
    }
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const finish = (result: RunResult): void => {
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish({ ok: false, error: `${command} timed out after ${opts.timeoutMs}ms`, out: "", err: "" });
    }, opts.timeoutMs);
    timer.unref();
    child.stdout?.on("data", (c: Buffer) => stdout.push(c));
    child.stderr?.on("data", (c: Buffer) => stderr.push(c));
    child.on("error", (err) => finish({ ok: false, error: errorText(err), out: "", err: "" }));
    child.on("close", (code) => {
      const out = Buffer.concat(stdout).toString("utf8");
      const err = Buffer.concat(stderr).toString("utf8");
      if (code === 0) finish({ ok: true, out: out.trim(), raw: out });
      else finish({ ok: false, error: err.trim() || `${command} exited with code ${code}`, ...(code === null ? {} : { code }), out, err });
    });
  });
}

export type Reply = { status: number; body: string } | { error: string };

export const apiArgs = (method: string, path: string, body: unknown): string[] => [
  "api",
  ...(method === "GET" ? [] : ["-X", method]),
  ...(body === undefined ? [] : ["--input", "-"]),
  path,
];

export async function apiCall(method: string, path: string, body?: unknown, timeoutMs = KO_TIMEOUT_MS): Promise<Reply> {
  const res = await runCommand("ko", apiArgs(method, path, body), { timeoutMs, input: body === undefined ? undefined : JSON.stringify(body) });
  if (res.ok) return { status: 200, body: res.raw };
  const status = /ko api: HTTP (\d+)/.exec(res.err)?.[1];
  return status ? { status: Number(status), body: res.out.trim() } : { error: res.error };
}

export function findKo(path = process.env.PATH): string | null {
  if (!path) return null;
  for (const dir of path.split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, "ko");
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {}
  }
  return null;
}
