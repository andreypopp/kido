// The fixture for the koa-agent.ts suite. A real pi host loads one extension and
// drives it only through registered tools, registered lifecycle events and the
// processes the extension runs. A fake stands in for the program the extension
// runs: `ko api` for the pane table, posts and vars, and `ko api --stream`
// for the message stream. Delays are gates that a test releases, never timers.

import childProcess from "node:child_process";

import { EventEmitter, once } from "node:events";
import type { TestContext } from "node:test";
import { hostFacts, type AgentHost } from "./koa-agents.ts";
import type { CompletionContext } from "./completion-context.ts";
import type { RestartState } from "./records.ts";
import type { PageRecord } from "./koa-records.ts";

import assert from "node:assert/strict";

import { syncBuiltinESMExports } from "node:module";

import { appendFileSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, symlinkSync } from "node:fs";

import { join, delimiter } from "node:path";

import { SessionManager, initTheme } from "@earendil-works/pi-coding-agent";

import { agentExtension, isBackgroundJob, type BackgroundJob, type Job, type JobRegistry } from "./koa-agent.ts";
import type { components } from "./ko-api.d.ts";
import { isRecord } from "./text.ts";

initTheme("dark");

export function at<T>(items: readonly T[], index: number): T {
  const item = items.at(index);
  if (item === undefined) throw new Error(`no item at ${index} of ${items.length}`);
  return item;
}

export function get(value: unknown, ...path: string[]): unknown {
  let current = value;
  for (const [i, key] of path.entries()) {
    if (!isRecord(current)) throw new Error(`${path.slice(0, i).join(".") || "value"} is not an object`);
    current = current[key];
  }
  return current;
}

export function getStr(value: unknown, ...path: string[]): string {
  const found = get(value, ...path);
  if (typeof found !== "string") throw new Error(`${path.join(".")} is not a string`);
  return found;
}

export function getList(value: unknown, ...path: string[]): unknown[] {
  const found = get(value, ...path);
  if (!Array.isArray(found)) throw new Error(`${path.join(".")} is not a list`);
  return found;
}

export function getRecord(value: unknown, ...path: string[]): Record<string, unknown> {
  const found = get(value, ...path);
  if (!isRecord(found)) throw new Error(`${path.join(".")} is not an object`);
  return found;
}

export function getRows(value: unknown, ...path: string[]): Array<Record<string, unknown>> {
  return getList(value, ...path).map((row) => {
    if (!isRecord(row)) throw new Error(`${path.join(".")} holds a row that is not an object`);
    return row;
  });
}

export const jsonRows = (result: ToolResult): Array<Record<string, unknown>> => getRows(JSON.parse(text(result)));

export const argvOf = (body: Record<string, unknown>): string[] => getList(body, "command", "argv").map((arg) => {
  if (typeof arg !== "string") throw new Error("an argv entry is not a string");
  return arg;
});

export const envOf = (body: Record<string, unknown>, name: string): unknown => getRows(body, "env").find((variable) => variable.name === name)?.value;

export function rowWhere(rows: Array<Record<string, unknown>>, key: string, value: unknown): Record<string, unknown> {
  const row = rows.find((candidate) => candidate[key] === value);
  if (!row) throw new Error(`no row with ${key} ${String(value)}`);
  return row;
}

export type ToolResult = { content: Array<{ type: string; text?: string }>; isError?: boolean; details?: unknown; structuredContent?: unknown };
type CallContext = { cwd?: string; sessionManager?: Partial<ReturnType<typeof fakeCtx>["sessionManager"]> };
type Tool = { name: string; execute(id: string, params: Record<string, unknown>, signal?: AbortSignal, update?: (result: ToolResult) => void, ctx?: CallContext): Promise<ToolResult> };
type Handler = (...args: unknown[]) => unknown;
type FakeMessage = { customType: string; content: string; details?: unknown };

// The fake pi implements only what the extension calls, so the extension's
// parameter type, which is pi's own, cannot take it. A method signature is
// bivariant in its parameter, which lets the extension stand in for a loader
// of any host.
type Extension = (pi: object) => void;

const hosts = new Map<object, AgentHost>();
const liveHosts: AgentHost[] = [];
let shared: ReturnType<typeof createChannel> | undefined;
export const koaExtension: Extension = pi => { Reflect.apply(agentExtension(hosts.get(pi) ?? (() => { throw new Error("no host for this pi"); })()), undefined, [pi]); };

export const jobId = (result: ToolResult): string => getStr(result.details, "job", "id");
export const jobLog = (result: ToolResult): string => getStr(result.details, "job", "log");

const statusRecords: string[] = [];
const stdoutWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (chunk: string | Uint8Array, encodingOrCallback?: BufferEncoding | ((error?: Error | null) => void), callback?: (error?: Error | null) => void): boolean => {
  const text = typeof chunk === "string" ? chunk : Buffer.from(chunk).toString();
  if (text.startsWith("\x1b]7501;")) { statusRecords.push(text); return true; }
  return typeof encodingOrCallback === "string" ? stdoutWrite(chunk, encodingOrCallback, callback) : stdoutWrite(chunk, encodingOrCallback);
};

export function captureStatusRecords(t: TestContext): string[] {
  t.after(() => { statusRecords.length = 0; });
  return statusRecords;
}

interface PaneRow {
  id: string;
  session?: string;
  window?: string;
  parent?: string;
  close?: string;
  inbox?: boolean;
  dead?: unknown;
  cwd?: string;
  title?: string;
  vars?: Record<string, unknown>;
  program_status?: unknown;
  runtime?: string;
  status?: unknown;
}

type ApiCall = { method: string; path: string; body: string };

const piStatus = (state = "idle") => ({ serial: 1, records: [{ id: "", state, app: "pi" }] });
const piKind = (session: string) => ({ kind: { type: "host", pane: { type: "pi_agent", session, status: { since: 0, state: { type: "idle" } } } } });

export const exited = (code: number) => ({ at: 1, cause: { type: "exited", code } });

function paneRow(row: PaneRow): PaneRow {
  return {
    session: "session_1",
    window: `window_${row.id.replace("pane_", "")}`,
    cwd: "/tmp",
    title: "",
    dead: null,
    program_status: piStatus(),
    status: { kind: { type: "host", pane: { type: "terminal", phase: { type: "unknown" } } } },
    ...row,
    vars: row.vars ?? {},
  };
}

export function selfPane(row: Partial<PaneRow> = {}): PaneRow {
  return paneRow({ id: "pane_1", title: "π - Self", status: piKind(String(row.vars?.["pi.session"] ?? "self-session")), ...row, vars: { "pi.session": "self-session", "pi.name": "Self", ...row.vars } });
}

export function agentPane(row: {
  pane: string;
  session: string;
  name?: string;
  inbox?: boolean;
  state?: string;
  koSession?: string;
  parent?: string;
  close?: string;
  title?: string;
  cwd?: string;
  dead?: unknown;
  vars?: Record<string, unknown>;
}): PaneRow {
  return paneRow({
    id: row.pane,
    session: row.koSession ?? "session_1",
    parent: row.parent,
    close: row.close,
    inbox: row.inbox ?? true,
    dead: row.dead ?? null,
    program_status: piStatus(row.state ?? "idle"),
    status: piKind(row.session),
    title: row.title ?? "",
    cwd: row.cwd ?? "/tmp",
    vars: { "pi.session": row.session, "pi.name": row.name ?? "", ...row.vars },
  });
}

type FeedMessage = {
  id: string;
  kind: string;
  text?: string;
  data?: unknown;
  relation?: string;
  from?: unknown;
  end?: unknown;
};

export interface Fixture {
  dir: string;
  binDir: string;
  sessions: Array<() => Promise<unknown>>;
  setPi(script: string): void;
  setPanes(panes: PaneRow[]): void;
  setClientPanes(panes: PaneRow[]): void;
  clientEvent(event: components["schemas"]["ClientEvent"]): void;
  dropClient(): void;
  clientLayouts(): Array<{ panes: unknown[] }>;
  panes(): PaneRow[];
  row(pane: string): PaneRow | undefined;
  apiCalls(): ApiCall[];
  posts(path: string): Array<Record<string, unknown>>;
  streamOpens(path: string): number;
  feed(message: FeedMessage): void;
  feedRaw(message: FeedMessage): void;
  serve(message: components["schemas"]["ServeOut"]): void;
  webviewActions(): string[];
  acks(): Array<{ type: string; id: string }>;
  forgetAcks(): void;
  dropStream(): void;
  setScreen(name: string, text: string): void;
  scriptSends(replies: Array<{ status: number; body: unknown }>): void;
  setRuntimes(runtimes: Record<string, Record<string, unknown>>): void;
  execLog(): Array<{ runtime: string; request: Record<string, unknown> }>;
  running(): number;
  restore(): Promise<void>;
}

function jsonLines<T>(file: string, parse: (value: unknown) => T): T[] {
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    return [];
  }
  return raw
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => parse(JSON.parse(l)));
}

const commandWork = new Map<string, Set<childProcess.ChildProcess>>();

let barePathWork: Set<childProcess.ChildProcess> | undefined;

const spawn = childProcess.spawn;

Reflect.set(childProcess, "spawn", (command: string, args: string[] = [], options: childProcess.SpawnOptions = {}) => {
  const child = spawn(command, args, options);
  const work = commandWork.get(command) ?? (command === "ko" ? barePathWork : undefined) ?? args?.map((arg) => commandWork.get(arg)).find(Boolean);
  if (work) {
    work.add(child);
    child.once("close", () => work.delete(child));
  }
  return child;
});

syncBuiltinESMExports();

let cachedFakeKo: string | null = null;

export function makeFixture(): Fixture {
  shared = undefined;
  statusRecords.length = 0;
  cachedFakeKo ??= process.env.KO_FAKE_KO ?? null;
  if (!cachedFakeKo || !existsSync(cachedFakeKo)) {
    throw new Error("KO_FAKE_KO is not set or not built; run scripts/test-ts.sh");
  }
  const dir = mkdtempSync(join("/tmp", "koa-agent-test-"));
  const binDir = join(dir, "bin");
  mkdirSync(binDir);
  const command = join(binDir, "ko");
  symlinkSync(cachedFakeKo, command);
  const work = new Set<childProcess.ChildProcess>();
  commandWork.set(command, work);
  barePathWork = work;
  const sessions: Array<() => Promise<unknown>> = [];
  const file = (name: string) => join(dir, name);
  const [apiLog, panesFile, feedFile, acksFile, dropFile, sendScript, runtimesFile, execLog] = [
    "api.jsonl", "panes.json", "feed.jsonl", "acks.jsonl", "drop", "sends.json", "runtimes.json", "exec.jsonl",
  ].map(file);
  const screens = file("screens");
  mkdirSync(screens);
  for (const empty of [apiLog, feedFile, acksFile, file("ko.jsonl"), execLog]) writeFileSync(empty, "");
  writeFileSync(runtimesFile, "{}");
  writeFileSync(panesFile, "[]");
  writeFileSync(sendScript, "[]");
  writeFileSync(file("sent.json"), "[]");

  const saved: Record<string, string | undefined> = { TMPDIR: process.env.TMPDIR, HOME: process.env.HOME };
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KO_") || key === "PATH") saved[key] = process.env[key];
  }
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KO_")) delete process.env[key];
  }
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMPDIR = dir;
  mkdirSync(file("home"));
  process.env.HOME = file("home");
  process.env.KO_SOCKET = "/tmp/koa-agent-test/socket";
  process.env.KO_PANE = "pane_1";
  process.env.KO_FAKE_KO = cachedFakeKo;
  process.env.KO_FAKE_API_LOG = apiLog;
  process.env.KO_FAKE_PANES = panesFile;
  process.env.KO_FAKE_CLIENT_PANES = file("client-panes.json");
  process.env.KO_FAKE_CLIENT_FEED = file("client-feed.jsonl");
  process.env.KO_FAKE_CLIENT_DROP = file("client-drop");
  process.env.KO_FAKE_CLIENT_LAYOUTS = file("client-layouts.jsonl");
  process.env.KO_FAKE_FEED = feedFile;
  process.env.KO_FAKE_ACKS = acksFile;
  process.env.KO_FAKE_SERVE = file("serve.jsonl");
  writeFileSync(file("serve.jsonl"), JSON.stringify({ type: "supported", supported: false }) + "\n");
  process.env.KO_FAKE_STREAM_DROP = dropFile;
  process.env.KO_FAKE_SEND_SCRIPT = sendScript;
  process.env.KO_FAKE_SENT = file("sent.json");
  process.env.KO_FAKE_SCREENS = screens;
  process.env.KO_FAKE_INSTANCE = "a".repeat(32);
  process.env.KO_FAKE_LOG = file("ko.jsonl");
  process.env.KO_FAKE_RUNTIMES = runtimesFile;
  process.env.KO_FAKE_EXEC_LOG = execLog;
  process.env.KO_RESEND_MS = "5";
  process.env.KO_RECEIVER_BACKOFF_MS = "5";
  process.env.KO_JOB_KILL_MS = "50";
  process.env.KO_STREAM_INTERVAL_MS = "5";

  let seq = 0;
  const calls = (): ApiCall[] => jsonLines(apiLog, (v) => ({ method: getStr(v, "method"), path: getStr(v, "path"), body: getStr(v, "body") }));
  const feed = (message: FeedMessage, raw: boolean) => {
    seq++;
    const from = message.from ?? { type: "pane", pane: "pane_2", session: "boss-session", name: "boss" };
    const pane = typeof from === "object" && from !== null && "type" in from && from.type === "pane";
    const record = { seq, text: "", relation: pane ? "sibling" : undefined, ...message, from };
    appendFileSync(feedFile, JSON.stringify(raw ? { id: message.id, fake_raw: JSON.stringify(record) } : record) + "\n");
  };

  return {
    dir,
    binDir,
    sessions,
    setPi(script) {
      writeFileSync(join(binDir, "pi"), script, { mode: 0o755 });
    },
    setPanes(panes) {
      writeFileSync(panesFile, JSON.stringify(panes));
    },
    setClientPanes(panes) {
      writeFileSync(file("client-panes.json"), JSON.stringify(panes));
    },
    clientEvent(event) {
      appendFileSync(file("client-feed.jsonl"), JSON.stringify(event) + "\n");
    },
    dropClient() {
      writeFileSync(file("client-drop"), "");
    },
    clientLayouts() {
      return jsonLines(file("client-layouts.jsonl"), (v) => ({ panes: getList(v, "panes") }));
    },
    panes() {
      return JSON.parse(readFileSync(panesFile, "utf8"));
    },
    row(pane) {
      return this.panes().find((row) => row.id === pane);
    },
    apiCalls: calls,
    posts(path) {
      return calls().filter((call) => call.method === "POST" && call.path === path).map((call) => JSON.parse(call.body));
    },
    streamOpens(path) {
      return calls().filter((call) => call.method === "STREAM" && call.path === path).length;
    },
    feed(message) {
      feed(message, false);
    },
    feedRaw(message) {
      feed(message, true);
    },
    serve(message) { appendFileSync(file("serve.jsonl"), JSON.stringify(message) + "\n"); },
    webviewActions() { return jsonLines(file("ko.jsonl"), getList).filter((args) => args[0] === "webview" && args[1] !== "serve").map((args) => String(args[1])); },
    acks() {
      return jsonLines(acksFile, (v) => ({ type: getStr(v, "type"), id: getStr(v, "id") }));
    },
    forgetAcks() {
      writeFileSync(acksFile, "");
    },
    dropStream() {
      writeFileSync(dropFile, "");
    },
    setScreen(name, text) {
      writeFileSync(join(screens, name), text);
    },
    scriptSends(replies) {
      writeFileSync(sendScript, JSON.stringify(replies));
    },
    setRuntimes(runtimes) {
      writeFileSync(runtimesFile, JSON.stringify(runtimes));
    },
    execLog() {
      return jsonLines(execLog, (v) => ({ runtime: getStr(v, "runtime"), request: getRecord(v, "request") }));
    },
    running() {
      return [...work].filter((child) => !child.spawnargs.includes("/client")).length;
    },
    async restore() {
      let first: unknown;
      for (const shutdown of sessions.reverse()) {
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
          await Promise.race([shutdown(), new Promise<never>((_, reject) => { timer = setTimeout(reject, 5000, new Error("timed out waiting for session shutdown")); })]);
        } catch (error) { first ??= error; } finally { clearTimeout(timer); }
      }
      try {
        for (const host of liveHosts.splice(0)) host.slots.receiver?.child.kill();
        shared = undefined;
        await pollUntil(() => work.size === 0, 15000, "all fake commands to close");
      } catch (error) { first ??= error; } finally {
        commandWork.delete(command);
        barePathWork = undefined;
        for (const key of Object.keys(process.env)) {
          if (key.startsWith("KO_")) delete process.env[key];
        }
        for (const [k, v] of Object.entries(saved)) {
          if (v !== undefined) process.env[k] = v;
          else delete process.env[k];
        }
        rmSync(dir, { recursive: true, force: true });
      }
      if (first) throw first;
    },
  };
}

type Entry = { type: "custom"; customType: string; data: Record<string, unknown> };

export function createChannel() {
  const unused = (): never => { throw new Error("this fixture has no session runtime"); };
  const host: AgentHost = {
    get facts() { return hostFacts(process.env); },
    get runtime() { return unused(); }, get session() { return unused(); },
    slots: {}, browser: false, extension: undefined,
    notify() {}, list: unused, start: unused, newSession: unused, switchSession: unused, usable: unused, dispose: unused,
  };
  liveHosts.push(host);
  return {
    host,
    ask: async (query: { type: "completion_context" | "restart_state" }): Promise<{ type: "completion_context"; context: CompletionContext } | { type: "restart_state"; state: RestartState }> => {
      if (!host.extension) throw new Error("the extension is not registered");
      return query.type === "completion_context" ? { type: "completion_context", context: await host.extension.completionContext(new AbortController().signal) } : { type: "restart_state", state: host.extension.restartState() };
    },
    receivers: () => host.extension ? 1 : 0,
  };
}

export function createFakePi(sessionDir = "/tmp/koa-agent-no-sessions/caller", entries: Entry[] = [], channel = shared ??= createChannel()) {
  const tools = new Map<string, Tool & { sourceInfo: { path: string } }>();
  const toolSources = [{ name: "bash", sourceInfo: { path: "builtin:bash" } }];
  const handlers = new Map<string, Handler[]>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
  const messages: Array<{ message: FakeMessage; opts: unknown }> = [];
  const failAppends = new Set<string>();
  const flags = new Map<string, boolean | string>();
  const host: { sessionName?: string; settings: { shellPath?: string; shellCommandPrefix?: string } } = { settings: {} };
  const pi = {
    ...host,
    registerFlag(_name: string, _options: unknown) {},
    registerCommand(_name: string, _options: unknown) {},
    getFlag: (name: string) => flags.get(name),
    getSessionName: (): string | undefined => pi.sessionName,
    getSettings: () => pi.settings,
    getThinkingLevel: () => "high",
    getAllTools: () => [...toolSources.filter((tool) => !tools.has(tool.name)), ...tools.values()],
    registerTool(tool: { name: string; execute(id: string, params: Record<string, unknown>, signal: AbortSignal | undefined, update: ((result: ToolResult) => void) | undefined, ctx: CallContext): Promise<ToolResult> }) {
      const execute = tool.execute;
      tools.set(tool.name, { ...tool, sourceInfo: { path: "extension:test" }, execute: (id, params, signal, update, ctx) => execute(id, params, signal, update, ctx ?? fakeCtx("self-session", undefined, () => true, sessionDir, () => entries)) });
    },
    on(event: string, handler: Handler) {
      const list = handlers.get(event) ?? [];
      handlers.set(event, list);
      list.push(handler);
    },
    sendUserMessage(text: string, opts: unknown) {
      delivered.push({ text, opts });
    },
    sendMessage(message: FakeMessage, opts: unknown) {
      messages.push({ message, opts });
    },
    appendEntry(customType: string, data: Record<string, unknown>) {
      if (failAppends.has(customType)) throw new Error(`cannot append ${customType}`);
      entries.push({ type: "custom", customType, data });
    },
    registerMessageRenderer() {
      throw new Error("koa renders in its page: registerMessageRenderer");
    },
  };
  async function emit(event: string, ...args: unknown[]): Promise<unknown[]> {
    const results: unknown[] = [];
    for (const h of handlers.get(event) ?? []) results.push(await h(...args));
    return results;
  }
  const notifications: Array<{ message: string; type?: string }> = [];
  const ui = {
    onTerminalInput() {
      throw new Error("koa renders in its page: onTerminalInput");
    },
    setWidget() {
      throw new Error("koa renders in its page: setWidget");
    },
    notify(message: string, type?: string) {
      notifications.push({ message, type });
    },
    addAutocompleteProvider() {
      throw new Error("koa renders in its page: addAutocompleteProvider");
    },
  };
  const tool = (name: string) => {
    const found = tools.get(name);
    if (!found) throw new Error(`no tool ${name}`);
    return found;
  };
  hosts.set(pi, channel.host);
  return {
    pi,
    channel,
    tools,
    tool,
    toolSources,
    handlers,
    delivered,
    messages,
    notifications,
    ui,
    emit,
    entries,
    failAppends,
    flags,
  };
}

export function savedSession(dir: string, cwd: string, id: string): string {
  mkdirSync(dir, { recursive: true });
  const session = SessionManager.create(cwd, dir, { id });
  const path = session.getSessionFile();
  assert.ok(path);
  writeFileSync(path, JSON.stringify(session.getHeader()) + "\n");
  return path;
}

type Of<T extends PageRecord["type"]> = Extract<PageRecord, { type: T }>;

export const isType = <T extends PageRecord["type"]>(record: PageRecord, type: T): record is Of<T> => record.type === type;

export const ofType = <T extends PageRecord["type"]>(type: T, where: (record: Of<T>) => unknown = () => true) => (record: PageRecord): record is Of<T> => isType(record, type) && !!where(record);

export const lastOf = <T extends PageRecord["type"]>(records: PageRecord[], type: T): Of<T> => at(records.filter(ofType(type)), -1);

export function sse(input: NodeJS.ReadableStream, state: { text: string; records: PageRecord[]; ended: boolean } = { text: "", records: [], ended: false }) {
  const changes = new EventEmitter();
  const decoder = new TextDecoder();
  let partial = "";
  input.on("data", (bytes: Uint8Array | string) => {
    const text = typeof bytes === "string" ? bytes : decoder.decode(bytes, { stream: true });
    state.text += text; partial += text;
    let end: number;
    while ((end = partial.indexOf("\n\n")) >= 0) {
      const line = partial.slice(0, end); partial = partial.slice(end + 2);
      assert.match(line, /^data: [^\r\n]*$/);
      state.records.push(JSON.parse(line.slice(6)));
    }
    changes.emit("record");
  });
  const end = () => { state.ended = true; changes.emit("record"); };
  input.once("end", end); input.once("error", end); input.once("close", end);
  function until<T extends PageRecord>(predicate: (record: PageRecord) => record is T, after?: number): Promise<T>;
  function until(predicate: (record: PageRecord) => boolean, after?: number): Promise<PageRecord>;
  async function until(predicate: (record: PageRecord) => boolean, after = 0): Promise<PageRecord> {
    for (;;) {
      const record = state.records.slice(after).find(predicate);
      if (record) return record;
      if (state.ended) throw new Error("SSE stream ended before the expected record");
      await once(changes, "record", { signal: AbortSignal.timeout(5000) });
    }
  }
  return {
    state,
    until,
  };
}

export function assistant(stopReason: string, text?: string, errorMessage?: string) {
  return { role: "assistant", stopReason, errorMessage, content: text === undefined ? [] : [{ type: "text", text }] };
}

export async function idleTurn(
  s: { emit: (event: string, ...args: unknown[]) => Promise<unknown[]> },
  text?: string,
  settle: { aborted?: boolean } = {},
): Promise<void> {
  await s.emit("agent_start");
  await s.emit("agent_end", { messages: [assistant("stop", text)] });
  await s.emit("agent_settled", settle, { isIdle: () => true });
}

function fakeCtx(
  sessionId: string | undefined = "self-session",
  ui?: unknown,
  idle: () => boolean = () => true,
  sessionDir = "/tmp/koa-agent-no-sessions/caller",
  branch: () => Entry[] = () => [],
) {
  return {
    hasUI: true,
    mode: "print",
    modelRegistry: { hasConfiguredAuth: () => true, find: () => undefined },
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionName: () => undefined,
      getSessionDir: () => sessionDir,
      getCwd: () => process.cwd(),
      getSessionFile: () => (sessionId ? "/tmp/" + sessionId + ".json" : undefined),
      getBranch: () => branch(),
    },
    cwd: process.cwd(),
    model: { provider: "acme", id: "caller" },
    isProjectTrusted: () => false,
    isIdle: idle,
    hasPendingMessages: () => false,
    abort: () => {},
    shutdown: () => {},
    ui,
  };
}

type FakeChannel = ReturnType<typeof createChannel>;

type FakePi = ReturnType<typeof createFakePi>["pi"];

export type Started = ReturnType<typeof createFakePi> & { aborts(): number; shutdowns(): number };

export async function startSession(
  fx: Fixture,
  opts: { mode?: "tui" | "print" | "rpc" | "json"; factory?: (pi: FakePi) => void; sessionId?: string; name?: string; idle?: () => boolean; entries?: Entry[]; channel?: FakeChannel; ctx?: Record<string, unknown>; record?: boolean; startup?: boolean; flags?: Record<string, string | boolean>; bashSource?: string } = {},
): Promise<Started> {
  const { factory = koaExtension, sessionId = "self-session", name, idle, entries = [], ctx, record = true, flags = {} } = opts;
  const created = createFakePi(join(fx.dir, "sessions", "caller"), entries, opts.channel);
  if (opts.bashSource) at(created.toolSources, 0).sourceInfo.path = opts.bashSource;
  for (const [flag, value] of Object.entries(flags)) created.flags.set(flag, value);
  Object.assign(created.channel.host, { browser: !!flags["koa-browser"] });
  if (name) created.pi.sessionName = name;
  factory(created.pi);
  let aborts = 0;
  let shutdowns = 0;
  const context = {
    ...fakeCtx(sessionId, created.ui, idle, join(fx.dir, "sessions", "caller"), () => created.entries),
    mode: opts.mode ?? "print",
    abort: () => {
      aborts++;
    },
    shutdown: () => {
      shutdowns++;
    },
    ...ctx,
  };
  if (record) fx.sessions.push(() => created.emit("session_shutdown", { reason: "new" }));
  await created.emit("session_start", {}, context);
  if (opts.startup !== false) {
    await new Promise<void>((resolve) => setImmediate(resolve));
    await pollUntil(() => [...(commandWork.get(join(fx.binDir, "ko")) ?? [])].every((child) => child.spawnargs.includes("--stream") || child.spawnargs.includes("webview")), 2000, "startup API calls to close");
  }
  return { ...created, aborts: () => aborts, shutdowns: () => shutdowns };
}

// Reimports the extension under a cache-busting specifier: a /reload is a fresh
// module instance in the same process and must be played as one.
let freshImportCounter = 0;

export async function freshExtension(): Promise<Extension> {
  const fresh = `?fresh=${process.pid}-${freshImportCounter++}`;
  void fresh;
  return koaExtension;
}

export async function withEnv<T>(vars: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// A real child: its environment names its own session and its parent's, which
// is what makes the parent edge trustworthy.
export async function asSubagent<T>(sessionId: string, fn: () => Promise<T>, parent = "boss-session"): Promise<T> {
  return withEnv({ KO_AGENT_SESSION: sessionId, KO_AGENT_PARENT_SESSION: parent }, fn);
}

export async function pollUntil(cond: () => boolean | Promise<boolean>, ms = 2000, what = "a condition"): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

export function gatedCommand(gate: string, before = "", after = "", code = 0): string {
  const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
  const body = `printf '%s' ${quote(before)}; i=0; while [ ! -e ${quote(gate)} ]; do i=$((i+1)); [ "$i" -le 1500 ] || exit 99; /bin/sleep 0.01; done; printf '%s' ${quote(after)} >&2; exit ${code}`;
  return `exec /bin/sh -c ${quote(body)}`;
}

export function jobRegistry(): JobRegistry | undefined {
  return liveHosts.at(-1)?.slots.jobs;
}

export function liveRegistry(): JobRegistry {
  const held = jobRegistry();
  assert.ok(held);
  return held;
}

export function jobOf(id: string): Job {
  const job = liveRegistry().jobs.get(id);
  assert.ok(job);
  return job;
}

export function endedState(job: Job): Extract<Job["state"], { type: "ended" }> {
  assert.ok(job.state.type === "ended");
  return job.state;
}

export function timerFire(timer: NodeJS.Timeout | null): () => void {
  assert.ok(timer);
  const fire: unknown = Reflect.get(timer, "_onTimeout");
  assert.ok(typeof fire === "function");
  return () => Reflect.apply(fire, undefined, []);
}

export function timerDelay(timer: NodeJS.Timeout | null): number {
  assert.ok(timer);
  const delay: unknown = Reflect.get(timer, "_idleTimeout");
  assert.ok(typeof delay === "number");
  return delay;
}

export function backgroundJob(id: string): BackgroundJob {
  const job = jobOf(id);
  assert.ok(isBackgroundJob(job));
  return job;
}
export const processGone = (marker: string): Promise<boolean> => new Promise((resolve) => {
  childProcess.execFile("/usr/bin/pgrep", ["-f", marker], (error) => resolve(error !== null));
});

export function movedId(result: Parameters<typeof text>[0] & { isError?: boolean }): string {
  assert.notEqual(result.isError, true);
  const id = text(result).match(/continues as job (j[a-z0-9]{7})/)?.[1];
  if (!id) throw new Error("no moved job in " + text(result));
  return id;
}

export const logHas = (path: string, value: string): boolean => existsSync(path) && readFileSync(path, "utf8").includes(value);

export function customMessages(s: Pick<ReturnType<typeof createFakePi>, "messages">, customType: string) {
  return s.messages.filter((m) => m.message.customType === customType);
}

export function notices(s: Pick<ReturnType<typeof createFakePi>, "messages">): string[] {
  return customMessages(s, "ko-notice").map((m) => String(m.message.content));
}

export function entriesOf(s: Pick<ReturnType<typeof createFakePi>, "entries">, customType: string): Array<Record<string, unknown>> {
  return s.entries.filter((entry) => entry.customType === customType).map((entry) => entry.data);
}

export function text(result: ToolResult): string {
  const block = at(result.content, 0);
  if (block.text === undefined) throw new Error(`a ${block.type} block has no text`);
  return block.text;
}
