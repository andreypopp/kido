import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { realpathSync } from "node:fs";
import { mkdtemp, mkdir, readFile, writeFile, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { assistant, sse, ofType } from "./koa-agent-fixture.ts";
import { startProvider, writeAgentDir, type Model, type Reply } from "./koa-fake-provider.ts";
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
async function launch(t: TestContext, dir: string, cwd: string, env: NodeJS.ProcessEnv, pi: string, args: string[], program: string) {
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  const child = spawn(process.execPath, [program, "--browser", "--pi", pi, ...args], { env: { ...hostEnv, HOME: join(dir, "home"), OPEN_LOG: join(dir, "urls"), KO_PANE: "", ...env, PATH: `${dir}:${env.PATH ?? process.env.PATH}` }, stdio: "pipe", cwd });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", bytes => { stdout += bytes; });
  let ready: (url: string) => void = () => {};
  const url = new Promise<string>(resolve => { ready = resolve; });
  child.stderr.on("data", bytes => { stderr += bytes; const match = stderr.match(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/); if (match?.[1]) ready(match[1]); });
  const close = once(child, "close");
  t.after(async () => { await stopChild(child, close); await rm(dir, { recursive: true, force: true }); });
  const base = await Promise.race([url, close.then(() => { throw new Error(`koa exited before serving: ${stderr}`); }), new Promise<never>((_, reject) => { setTimeout(reject, 8000, new Error(`koa did not serve within 8 s: ${stderr}`)).unref(); })]);
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(base + "events", { signal: controller.signal });
  assert.ok(response.body);
  const { state: stream, until } = sse(Readable.from(response.body));
  const post = (path: string, body: object = {}) => fetch(base + path, { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Array.isArray(body) ? body : { sessionId: stream.records.filter(record => record.type === 'state').at(-1)?.sessionId, ...body }) });
  return { pid: child.pid, post, until, records: () => stream.records, count: () => stream.records.length, close, stdout: () => stdout, stderr: () => stderr, base };
}
export const assistantMessage = { ...assistant("stop"), api: "test", provider: "test", model: "test", usage: {}, timestamp: 42 };

const isApiCall = (value: unknown): value is { method: string; path: string; body: string } => typeof value === "object" && value !== null && "method" in value && typeof value.method === "string" && "path" in value && typeof value.path === "string" && "body" in value && typeof value.body === "string";
export const realPi = fileURLToPath(new URL("./node_modules/.bin/pi", import.meta.url));
export const realPiPackage = fileURLToPath(new URL("./node_modules/@earendil-works/pi-coding-agent", import.meta.url));
export type Real = { resources?: boolean; discover?: boolean; panes?: object[]; replies: Reply[]; models?: Model[]; args?: string[]; env?: NodeJS.ProcessEnv; extensions?: Record<string, string>; settings?: object; program?: string; setup?: (paths: { dir: string; cwd: string; sessions: string }) => Promise<string[] | void>; start?: boolean };
export async function realFixture(t: TestContext, options: Real) {
  const dir = await mkdtemp(join(tmpdir(), "koa-real-"));
  const provider = await startProvider(options.replies, 10000, options.models?.map(model => model.id));
  const agentDir = join(dir, "agent"), sessions = join(dir, "sessions");
  let cwd = join(dir, "project");
  await Promise.all([mkdir(join(dir, "home")), mkdir(cwd), mkdir(sessions)]);
  cwd = realpathSync(cwd);
  await writeAgentDir(agentDir, provider.baseUrl, { images: { autoResize: false }, ...options.settings }, options.models);
  const extensions = await Promise.all(Object.entries(options.extensions ?? {}).map(async ([name, source]) => { const file = join(dir, name); await writeFile(file, source); return ["--extension", file]; }));
  const extra = (await options.setup?.({ dir, cwd, sessions })) ?? [];
  if (options.panes) {
    await linkFakeKo(dir);
    await writeFile(join(dir, "panes.json"), JSON.stringify(options.panes));
  }
  const ko = options.panes ? { KO_PANE: "pane_1", KO_SOCKET: "/tmp/koa-agent-test/socket", KO_PANE_TOKEN: "", KO_FAKE_PANES: join(dir, "panes.json"), KO_FAKE_API_LOG: join(dir, "api-log") } : {};
  const app = await launch(t, dir, cwd, { PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", ...ko, ...options.env }, realPi, [...(options.discover ? [] : ["--no-extensions"]), ...(options.resources ? [] : ["--no-skills", "--no-prompt-templates"]), "--no-context-files", "--session-dir", sessions, ...extensions.flat(), ...extra, ...options.args ?? []], options.program ?? resolve("../../build/ko/share/ko/koa/koa.ts"));
  t.after(async () => { await provider.close(); });
  if (options.start !== false) await app.until(ofType("state", record => record.pi?.type === "ready"));
  return { ...app, provider, dir, cwd, sessions, agentDir, apiCalls: async () => (await readFile(join(dir, "api-log"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).flatMap(line => { const call: unknown = JSON.parse(line); return isApiCall(call) ? [call] : []; }) };
}

export async function writeSession(cwd: string, sessions: string, turns: number, name: string) {
  const { SessionManager } = await import("@earendil-works/pi-coding-agent");
  const manager = SessionManager.create(cwd, sessions);
  for (let i = 0; i < turns; i++) {
    manager.appendMessage({ role: "user", content: `${name} ${i}`, timestamp: 2 * i + 1 });
    manager.appendMessage({ role: "assistant", content: [{ type: "text", text: `${name} answer ${i}` }], api: "openai-completions", provider: "fake", model: "fake-model", usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 2 * i + 2 });
  }
  manager.appendSessionInfo(name);
  return manager.getSessionFile() ?? "";
}
