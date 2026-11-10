import { execFile, spawn, type ChildProcess } from "node:child_process";
import { Readable } from "node:stream";
import timers from "node:timers/promises";
import { errorText, isRecord } from "../pi/text.ts";

export function signalChild(child: ChildProcess, signal: NodeJS.Signals): void {
  if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if (!(error instanceof Error && "code" in error && (error.code === "ESRCH" || error.code === "EPERM"))) process.stderr.write(`koa: ${signal}: ${errorText(error)}\n`);
  }
}

export async function pickSession(executable: string, args: string[], extension: string, readyMs: number): Promise<{ type: "skip" } | { type: "cancel" } | { type: "selected"; path: string }> {
  let picker: ChildProcess | undefined;
  let interrupt: (error: Error) => void = () => {};
  const interrupted = new Promise<never>((_resolve, reject) => { interrupt = reject; });
  const signals = (["SIGTERM", "SIGHUP", "SIGINT"] as const).map(signal => {
    const handler = () => { picker?.kill(signal); interrupt(new Error(`session picker interrupted by ${signal}`)); };
    process.on(signal, handler);
    return { signal, handler };
  });
  const controller = new AbortController();
  try {
    const child = spawn(executable, ["--mode", "rpc", "--no-session", "--no-extensions", "--extension", extension], { env: { ...process.env, KOA_RESUME_ARGS: JSON.stringify(args) }, stdio: ["inherit", "inherit", "inherit", "pipe"] });
    picker = child;
    const exited = new Promise<void>(resolve => { child.once("exit", () => resolve()); child.once("error", () => resolve()); });
    const pipe = child.stdio[3];
    if (!(pipe instanceof Readable)) throw new Error("session picker has no result pipe");
    const lines = (async function* () {
      let buffer = "";
      for await (const chunk of pipe.setEncoding("utf8")) {
        buffer += chunk;
        let end: number;
        while ((end = buffer.indexOf("\n")) >= 0) {
          const value: unknown = JSON.parse(buffer.slice(0, end));
          buffer = buffer.slice(end + 1);
          yield value;
        }
      }
    })();
    try {
      const first = await Promise.race([lines.next(), interrupted, timers.setTimeout(readyMs, undefined, { signal: controller.signal }).then(() => { throw new Error("session picker did not become ready"); })]);
      controller.abort();
      if (first.done) throw new Error("session picker exited without a result");
      if (!isRecord(first.value)) throw new Error("invalid session picker result");
      let result: { type: "skip" } | { type: "cancel" } | { type: "selected"; path: string };
      if (first.value.type === "skip") result = { type: "skip" };
      else {
        if (first.value.type !== "ready") throw new Error("invalid session picker result");
        if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error("resume requires a terminal");
        const next = await Promise.race([lines.next(), interrupted]);
        if (next.done) throw new Error("session picker exited without a result");
        if (!isRecord(next.value)) throw new Error("invalid session picker result");
        if (next.value.type === "cancel") result = { type: "cancel" };
        else if (next.value.type === "selected" && typeof next.value.path === "string" && next.value.path) result = { type: "selected", path: next.value.path };
        else throw new Error("invalid session picker result");
      }
      await Promise.race([exited, interrupted, timers.setTimeout(1000, undefined, { ref: false }).then(() => { throw new Error("session picker did not exit after selection"); })]);
      if (picker.exitCode !== 0) throw new Error("session picker failed");
      return result;
    } finally {
      picker.kill("SIGTERM");
      await Promise.race([exited, timers.setTimeout(1000, undefined, { ref: false })]);
      picker.kill("SIGKILL");
      await exited;
      pipe.destroy();
    }
  } catch (error) {
    const version = await new Promise<string>(resolve => execFile(executable, ["--version"], { timeout: 2000 }, (error, stdout) => resolve(error ? "version unavailable" : stdout.trim())));
    throw new Error(`${executable} (${version}): ${errorText(error)}`);
  } finally {
    controller.abort();
    for (const { signal, handler } of signals) process.off(signal, handler);
  }
}
