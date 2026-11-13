import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { Readable } from "node:stream";
import { assistant, sse } from "./koa-agent-fixture.ts";
export async function linkFakeKo(dir: string) {
  const fake = process.env.KO_FAKE_KO;
  if (!fake) throw new Error("KO_FAKE_KO is not set; run scripts/test-ts.sh");
  await stat(fake);
  await symlink(fake, join(dir, "ko"));
}
const hostEnv = Object.fromEntries(["PATH", "LANG", "LC_ALL", "TERM"].flatMap(key => process.env[key] === undefined ? [] : [[key, process.env[key]]]));
export async function stopChild(child: ChildProcess, closed: Promise<unknown>, ms = 5000) {
  for (const stream of child.stdio) stream?.destroy();
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  for (const signal of ["SIGTERM", "SIGKILL"] as const) {
    if (!exited()) child.kill(signal);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const done = await Promise.race([closed.then(() => true), new Promise<boolean>(resolve => { timer = setTimeout(resolve, ms, false); })]);
    clearTimeout(timer);
    if (done) return;
  }
  throw new Error(`child ${child.pid} did not close after SIGKILL: ${child.spawnargs.join(" ")}`);
}
export async function fixture(t: TestContext, steps: object[], env: NodeJS.ProcessEnv = {}, pi?: string, startup = true, args: string[] = [], program = resolve("../../build/ko/share/ko/koa/koa.ts")) {
  const dir = await mkdtemp(join(tmpdir(), "koa-test-"));
  const script = join(dir, "script");
  const log = join(dir, "log");
  await mkdir(join(dir, "home"));
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  await writeFile(script, steps.map(value => JSON.stringify(value)).join("\n"));
  const child = spawn(process.execPath, [program, "--browser", "--pi", pi ?? resolve("./koa-fake-pi.ts"), "--no-session", ...args], { env: { ...hostEnv, HOME: join(dir, "home"), OPEN_LOG: join(dir, "urls"), KO_PANE: "", KOA_FAKE_SCRIPT: script, KOA_FAKE_LOG: log, KOA_PI_EXIT_MS: "30", ...env, PATH: `${dir}:${env.PATH ?? process.env.PATH}` }, stdio: "pipe" });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", bytes => { stdout += bytes; });
  let ready: (url: string) => void = () => {};
  let failed: (error: Error) => void = () => {};
  const url = new Promise<string>((resolve, reject) => { ready = resolve; failed = reject; });
  child.stderr.on("data", bytes => { stderr += bytes; const match = stderr.match(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/); if (match?.[1]) ready(match[1]); });
  const close = once(child, "close");
  child.once("exit", (code, signal) => failed(new Error(`koa exited (${code ?? signal}) before it was ready: ${stderr}`)));
  t.after(async () => { await stopChild(child, close); await rm(dir, { recursive: true, force: true }); });
  const base = await url;
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(base + "events", { signal: controller.signal });
  assert.ok(response.body);
  const { state: stream, until } = sse(Readable.from(response.body));
  const post = (path: string, body: object = {}) => fetch(base + path, { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Array.isArray(body) ? body : { sessionId: stream.records.filter(record => record.type === 'state').at(-1)?.sessionId, ...body }) });
  if (startup) await until(record => record.type === "state" && (pi ? record.pi?.type === "exited" : Array.isArray(record.levels) && record.levels.length === 3));
  return { script, post, until, records: () => stream.records, count: () => stream.records.length, close, stdout: () => stdout, stderr: () => stderr, log: async () => (await readFile(log, "utf8")).trim().split("\n").map(line => JSON.parse(line)), base };
}
export const assistantMessage = { ...assistant("stop"), api: "test", provider: "test", model: "test", usage: {}, timestamp: 42 };
