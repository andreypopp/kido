// The fixture for the ko-pi.ts suite. A real pi host loads one extension and
// drives it only through registered tools, registered lifecycle events and the
// processes the extension runs. A fake stands in for the program the extension
// runs: `ko api` for the pane table, posts and vars, and `ko api --stream`
// for the message stream. Delays are gates that a test releases, never timers.

import childProcess from "node:child_process";
import { EventEmitter, once } from "node:events";
import type { TestContext } from "node:test";

import assert from "node:assert/strict";

import { syncBuiltinESMExports } from "node:module";

import { appendFileSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, symlinkSync } from "node:fs";

import { join, delimiter } from "node:path";

import { SessionManager, initTheme } from "@earendil-works/pi-coding-agent";

import koPi from "./ko-pi.ts";
import type { components } from "./ko-api.d.ts";

initTheme("dark");

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
  posts(path: string): Array<Record<string, any>>;
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
  execLog(): Array<{ runtime: string; request: Record<string, any> }>;
  running(): number;
  restore(): Promise<void>;
}

function jsonLines(file: string): any[] {
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
    .map((l) => JSON.parse(l));
}

const commandWork = new Map<string, Set<childProcess.ChildProcess>>();

let barePathWork: Set<childProcess.ChildProcess> | undefined;

const spawn = childProcess.spawn;

childProcess.spawn = ((command: string, args: string[] = [], options: childProcess.SpawnOptions = {}) => {
  const child = spawn(command, args, options);
  const work = commandWork.get(command) ?? (command === "ko" ? barePathWork : undefined) ?? args?.map((arg) => commandWork.get(arg)).find(Boolean);
  if (work) {
    work.add(child);
    child.once("close", () => work.delete(child));
  }
  return child;
}) as typeof childProcess.spawn;

syncBuiltinESMExports();

let cachedFakeKo: string | null = null;

export function makeFixture(): Fixture {
  statusRecords.length = 0;
  cachedFakeKo ??= process.env.KO_FAKE_KO ?? null;
  if (!cachedFakeKo || !existsSync(cachedFakeKo)) {
    throw new Error("KO_FAKE_KO is not set or not built; run scripts/test-ts.sh");
  }
  const dir = mkdtempSync(join("/tmp", "ko-pi-test-"));
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

  const saved: Record<string, string | undefined> = { TMPDIR: process.env.TMPDIR };
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KO_") || key === "PATH") saved[key] = process.env[key];
  }
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KO_AGENT_") || key.startsWith("KO_FAKE_")) delete process.env[key];
  }
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMPDIR = dir;
  process.env.KO_SOCKET = "/tmp/ko-pi-test/socket";
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
  globalThis.__koPiExtensionReceiver = undefined;
  globalThis.__koPiExtensionWebview = undefined;
  globalThis.__koPiExtensionWebviewWish = undefined;
  globalThis.__koPiExtensionReceived = undefined;

  let seq = 0;
  const calls = (): ApiCall[] => jsonLines(apiLog);
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
      return jsonLines(file("client-layouts.jsonl"));
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
    webviewActions() { return jsonLines(file("ko.jsonl")).filter((args) => args[0] === "webview" && args[1] !== "serve").map((args) => args[1]); },
    acks() {
      return jsonLines(acksFile);
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
      return jsonLines(execLog);
    },
    running() {
      return [...work].filter((child) => !child.spawnargs.includes("/client")).length;
    },
    async restore() {
      for (const shutdown of sessions.reverse()) await shutdown();
      if (globalThis.__koPiExtensionWebview) {
        await globalThis.__koPiExtensionWebview.wv.close();
        await new Promise<void>(resolve => globalThis.__koPiExtensionWebview!.server.close(() => resolve()));
      }
      globalThis.__koPiExtensionWebview = undefined;
      globalThis.__koPiExtensionReceiver?.child.kill();
      globalThis.__koPiExtensionReceiver = undefined;
      await pollUntil(() => work.size === 0, 15000, "all fake commands to close");
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
    },
  };
}

type Entry = { type: "custom"; customType: string; data: Record<string, any> };

export function createFakePi(sessionDir = "/tmp/ko-pi-no-sessions/caller", entries: Entry[] = []) {
  const tools = new Map<string, any>();
  const toolSources = [{ name: "bash", sourceInfo: { path: "builtin:bash" } }];
  const terminalListeners = new Set<(data: string) => { consume?: boolean; data?: string } | undefined>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
  const messages: Array<{ message: any; opts: unknown }> = [];
  const renderers = new Map<string, (message: any, options: any, theme: any) => { render(width: number): string[]; handleMouse(event: any): unknown }>();
  const widgets = new Map<string, { content: string[] | ((tui: unknown, theme: any) => { render(width: number): string[]; handleMouse?(event: any): unknown }) | undefined; options?: unknown }>();
  const failAppends = new Set<string>();
  const flags = new Map<string, boolean | string>();
  const pi = {
    registerFlag(_name: string, _options: unknown) {},
    getFlag: (name: string) => flags.get(name),
    sessionName: undefined as string | undefined,
    getSessionName: (): string | undefined => pi.sessionName,
    settings: { tuiMode: "regular" as "regular" | "fullscreen", shellPath: undefined as string | undefined, shellCommandPrefix: undefined as string | undefined },
    getSettings: () => pi.settings,
    getThinkingLevel: () => "high",
    getAllTools: () => [...toolSources.filter((tool) => !tools.has(tool.name)), ...tools.values()],
    registerTool(tool: any) {
      const execute = tool.execute;
      tools.set(tool.name, { ...tool, sourceInfo: { path: "extension:test" }, execute: (id: string, params: unknown, signal?: AbortSignal, update?: unknown, ctx = fakeCtx("self-session", undefined, () => true, sessionDir, () => entries)) => execute(id, params, signal, update, ctx) });
    },
    on(event: string, handler: (...args: any[]) => unknown) {
      (handlers.get(event) ?? handlers.set(event, []).get(event)!).push(handler);
    },
    sendUserMessage(text: string, opts: unknown) {
      delivered.push({ text, opts });
    },
    sendMessage(message: any, opts: unknown) {
      messages.push({ message, opts });
    },
    appendEntry(customType: string, data: Record<string, any>) {
      if (failAppends.has(customType)) throw new Error(`cannot append ${customType}`);
      entries.push({ type: "custom", customType, data });
    },
    registerMessageRenderer(customType: string, renderer: Parameters<typeof renderers.set>[1]) {
      renderers.set(customType, renderer);
    },
  };
  async function emit(event: string, ...args: unknown[]): Promise<unknown[]> {
    const results: unknown[] = [];
    for (const h of handlers.get(event) ?? []) results.push(await h(...args));
    return results;
  }
  const notifications: Array<{ message: string; type?: string }> = [];
  const autocompleteFactories: Array<(current: any) => any> = [];
  const ui = {
    onTerminalInput(handler: (data: string) => { consume?: boolean; data?: string } | undefined) {
      terminalListeners.add(handler);
      return () => { terminalListeners.delete(handler); };
    },
    setWidget(key: string, content: string[] | ((tui: unknown, theme: any) => { render(width: number): string[]; handleMouse?(event: any): unknown }) | undefined, options?: unknown) {
      widgets.set(key, { content, options });
    },
    notify(message: string, type?: string) {
      notifications.push({ message, type });
    },
    addAutocompleteProvider(factory: (current: any) => any) {
      autocompleteFactories.push(factory);
    },
  };
  return {
    pi,
    tools,
    toolSources,
    terminalListeners,
    terminalInput: (data: string) => [...terminalListeners].map((handler) => handler(data)),
    handlers,
    delivered,
    messages,
    renderers,
    widgets,
    notifications,
    autocompleteFactories,
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

export function ndjson(input: NodeJS.ReadableStream, state = { text: "", records: [] as any[], ended: false }) {
  const changes = new EventEmitter();
  const decoder = new TextDecoder();
  let partial = "";
  input.on("data", (bytes: Uint8Array | string) => {
    const text = typeof bytes === "string" ? bytes : decoder.decode(bytes, { stream: true });
    state.text += text; partial += text;
    let end: number;
    while ((end = partial.indexOf("\n")) >= 0) {
      const line = partial.slice(0, end); partial = partial.slice(end + 1);
      try { state.records.push(JSON.parse(line)); } catch {}
    }
    changes.emit("record");
  });
  const end = () => { state.ended = true; changes.emit("record"); };
  input.once("end", end); input.once("error", end); input.once("close", end);
  return {
    state,
    async until(predicate: (record: any) => boolean, after = 0) {
      for (;;) {
        const record = state.records.slice(after).find(predicate);
        if (record) return record;
        if (state.ended) throw new Error("NDJSON stream ended before the expected record");
        await once(changes, "record", { signal: AbortSignal.timeout(5000) });
      }
    },
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
  sessionDir = "/tmp/ko-pi-no-sessions/caller",
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

export type Started = ReturnType<typeof createFakePi> & { aborts(): number; shutdowns(): number };

export async function startSession(
  fx: Fixture,
  opts: { mode?: "tui" | "print" | "rpc" | "json"; factory?: (pi: never) => void; sessionId?: string; name?: string; idle?: () => boolean; entries?: Entry[]; ctx?: Record<string, unknown>; record?: boolean; startup?: boolean; flags?: Record<string, string | boolean>; bashSource?: string } = {},
): Promise<Started> {
  const { factory = koPi, sessionId = "self-session", name, idle, entries = [], ctx, record = true, flags = {} } = opts;
  const created = createFakePi(join(fx.dir, "sessions", "caller"), entries);
  if (opts.bashSource) created.toolSources[0]!.sourceInfo.path = opts.bashSource;
  for (const [flag, value] of Object.entries(flags)) created.flags.set(flag, value);
  if (name) created.pi.sessionName = name;
  factory(created.pi as never);
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

export async function freshExtension(): Promise<(pi: never) => void> {
  const fresh = `?fresh=${process.pid}-${freshImportCounter++}`;
  const mod = await import(`./ko-pi.ts${fresh}`);
  return mod.default as (pi: never) => void;
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

export const jobRegistry = () => Reflect.get(globalThis, Symbol.for("ko-pi.jobs"));
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

export function entriesOf(s: Pick<ReturnType<typeof createFakePi>, "entries">, customType: string): Array<Record<string, any>> {
  return s.entries.filter((entry) => entry.customType === customType).map((entry) => entry.data);
}

export const text = (result: { content: Array<{ text: string }> }): string => result.content[0]!.text;
