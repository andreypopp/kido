import type { TestContext } from "node:test";
import type { components } from "../webview/ko-api.d.ts";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { realpathSync } from "node:fs";
import { mkdtemp, mkdir, readFile, writeFile, appendFile, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { assistant, sse, ofType } from "./koa-agent-fixture.ts";
import { startProvider, writeAgentDir, type Model, type Reply } from "./koa-fake-provider.ts";
export async function linkFakeKo(dir: string) {
  const fake = process.env.KO_FAKE_KO;
  if (!fake) throw new Error("KO_FAKE_KO is not set; run make -C koa test");
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
export type After = { after(hook: () => unknown): void };
export async function serveChild(t: After, dir: string, args: string[], options: { env: NodeJS.ProcessEnv; cwd?: string; label: string }) {
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  const child = spawn(process.execPath, args, { env: { ...options.env, PATH: `${dir}:${options.env.PATH ?? process.env.PATH}` }, stdio: "pipe", cwd: options.cwd });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", bytes => { stdout += bytes; });
  let ready: (url: string) => void = () => {};
  const url = new Promise<string>(resolve => { ready = resolve; });
  const pattern = new RegExp(`${options.label}: (http://127\\.0\\.0\\.1:\\d+/)`);
  child.stderr.on("data", bytes => { stderr += bytes; const match = stderr.match(pattern); if (match?.[1]) ready(match[1]); });
  const close = once(child, "close");
  t.after(async () => { await stopChild(child, close); await rm(dir, { recursive: true, force: true }); });
  const base = await Promise.race([url, close.then(() => { throw new Error(`${options.label} exited before serving: ${stderr}`); }), new Promise<never>((_, reject) => { setTimeout(reject, 8000, new Error(`${options.label} did not serve within 8 s: ${stderr}`)).unref(); })]);
  return { child, base, close, stdout: () => stdout, stderr: () => stderr };
}
async function launch(t: After, dir: string, cwd: string, env: NodeJS.ProcessEnv, pi: string, args: string[], program: string) {
  const { child, base, close, stdout, stderr } = await serveChild(t, dir, [program, "--browser", "--pi", pi, ...args], { env: { ...hostEnv, HOME: join(dir, "home"), OPEN_LOG: join(dir, "urls"), KO_PANE: "", ...env }, cwd, label: "koa" });
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(base + "events", { signal: controller.signal });
  assert.ok(response.body);
  const { state: stream, until } = sse(Readable.from(response.body));
  const sessionId = () => stream.records.filter(record => record.type === 'state').at(-1)?.sessionId;
  const url = (path: string) => base + path + (path.includes('?') ? '&' : '?') + 'sessionId=' + encodeURIComponent(sessionId() ?? '');
  const post = (path: string, body: object = {}) => fetch(path.startsWith('attachments') ? url(path) : base + path, { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Array.isArray(body) ? body : { sessionId: stream.records.filter(record => record.type === 'state').at(-1)?.sessionId, ...body }) });
  const subscribe = async (view: string, query = "") => {
    const viewer = new AbortController();
    t.after(() => viewer.abort());
    const named = await fetch(base + "events?view=" + encodeURIComponent(view) + query, { signal: viewer.signal });
    const opened = sse(Readable.from(named.ok && named.body ? named.body : []));
    const own = () => opened.state.records.filter(record => record.type === 'state').at(-1)?.sessionId;
    const scoped = (path: string) => base + path + (path.includes('?') ? '&' : '?') + 'view=' + encodeURIComponent(view) + '&sessionId=' + encodeURIComponent(own() ?? '');
    return {
      status: named.status, error: named.ok ? undefined : await named.json(), until: opened.until, records: () => opened.state.records, ended: () => opened.state.ended, close: () => viewer.abort(),
      get: (path: string) => fetch(scoped(path)),
      post: (path: string, body: object = {}) => fetch(base + path, { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionId: own(), view, ...body }) }),
    };
  };
  return { pid: child.pid, post, url, subscribe, until, records: () => stream.records, count: () => stream.records.length, disconnect: () => controller.abort(), close, stdout, stderr, base };
}
export const assistantMessage = { ...assistant("stop"), api: "test", provider: "test", model: "test", usage: {}, timestamp: 42 };

const isApiCall = (value: unknown): value is { method: string; path: string; body: string } => typeof value === "object" && value !== null && "method" in value && typeof value.method === "string" && "path" in value && typeof value.path === "string" && "body" in value && typeof value.body === "string";
export const realPi = fileURLToPath(new URL("./node_modules/.bin/pi", import.meta.url));
export type Real = { resources?: boolean; discover?: boolean; panes?: object[]; replies: Reply[]; models?: Model[]; args?: string[]; env?: NodeJS.ProcessEnv; extensions?: Record<string, string>; settings?: object; program?: string; setup?: (paths: { dir: string; cwd: string; sessions: string }) => Promise<string[] | void>; start?: boolean };
export async function realFixture(t: TestContext, options: Real) {
  const hooks: (() => unknown)[] = [];
  t.after(async () => {
    let first: unknown;
    for (const hook of hooks.reverse()) try { await hook(); } catch (error) { first ??= error; }
    if (first) throw first;
  });
  const scope: After = { after: hook => { hooks.push(hook); } };
  const dir = await mkdtemp(join(tmpdir(), "koa-real-"));
  scope.after(() => rm(dir, { recursive: true, force: true }));
  const provider = await startProvider(options.replies, 10000, options.models?.map(model => model.id));
  scope.after(() => provider.close());
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
    await writeFile(join(dir, "feed.jsonl"), "");
    await writeFile(join(dir, "acks.jsonl"), "");
    await writeFile(join(dir, "status-revisions.jsonl"), "");
  }
  const ko = options.panes ? { KO_PANE: "pane_1", KO_SOCKET: "/tmp/koa-agent-test/socket", KO_PANE_TOKEN: "", KO_FAKE_PANES: join(dir, "panes.json"), KO_FAKE_API_LOG: join(dir, "api-log"), KO_FAKE_FEED: join(dir, "feed.jsonl"), KO_FAKE_ACKS: join(dir, "acks.jsonl"), KO_FAKE_STATUS_REVISIONS: join(dir, "status-revisions.jsonl") } : {};
  const app = await launch(scope, dir, cwd, { PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", ...ko, ...options.env }, realPi, [...(options.discover ? [] : ["--no-extensions"]), ...(options.resources ? [] : ["--no-skills", "--no-prompt-templates"]), "--no-context-files", "--session-dir", sessions, ...extensions.flat(), ...extra, ...options.args ?? []], options.program ?? resolve("../build/koa/share/koa/koa/koa.ts"));
  if (options.start !== false) await app.until(ofType("state", record => record.life?.type === "ready"));
  let seq = 0;
  const feed = (message: { id: string; kind: string; text?: string; record?: string; data?: unknown; from?: object; relation?: string }) => {
    const from = message.from ?? { type: "user" };
    return appendFile(join(dir, "feed.jsonl"), JSON.stringify({ seq: ++seq, text: "", ...("pane" in from ? { relation: message.relation ?? "sibling" } : {}), ...message, from }) + "\n");
  };
  const acks = async () => (await readFile(join(dir, "acks.jsonl"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map((line): { type: string; id: string } => JSON.parse(line));
  const statusRevisions = async () => (await readFile(join(dir, "status-revisions.jsonl"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map((line): { pane: string; status: components["schemas"]["ProgramStatus"] } => JSON.parse(line));
  return { ...app, provider, dir, cwd, sessions, agentDir, feed, acks, statusRevisions, apiCalls: async () => (await readFile(join(dir, "api-log"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).flatMap(line => { const call: unknown = JSON.parse(line); return isApiCall(call) ? [call] : []; }) };
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
