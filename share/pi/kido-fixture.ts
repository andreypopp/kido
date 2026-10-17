// The fixture for the kido-status.ts and kido-agents.ts suites. A real pi host
// loads that pair together, and every case drives them only through registered
// tools, registered lifecycle events, and a real unix socket speaking the inbox
// wire protocol. A fake `kido` executable stands in for the real binary on PATH;
// a "reply" is injected directly onto the extension's own inbox socket, exactly
// as a real peer's `kido tool message_agent` would arrive.

import childProcess from "node:child_process";

import { syncBuiltinESMExports } from "node:module";

import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, rmSync, existsSync, symlinkSync } from "node:fs";

import { tmpdir } from "node:os";

import { join, delimiter } from "node:path";

import net from "node:net";

import kidoStatus from "./kido-status.ts";

import kidoAgents from "./kido-agents.ts";

export interface Fixture {
  agentsFile: string;
  logFile: string;
  inboxDir: string;
  setAgents(agents: unknown[]): void;
  setParentAlive(mode: "alive" | "gone" | "fail"): void;
  killSession(session: string): void;
  setParentAliveDelay(ms: number): void;
  parentAliveCalls(): string[][];
  setInboxFail(fail: boolean): void;
  setMessageFailTo(to: string | undefined): void;
  selfInboxPath(): string;
  lastLogFor(to: string, kind?: string): { id: string; replyTo: string; to: string; text: string; failed?: boolean; args: string[] } | undefined;
  lastSpawnArgs(): string[] | undefined;
  lastSpawnTask(): string | undefined;
  lastSpawnCaller(): string | undefined;
  lastRunOutcomeArgs(): string[] | undefined;
  lastAsyncBashArgs(): string[] | undefined;
  runsDir: string;
  lastStatusArgs(): string[] | undefined;
  setStatusCalls(): string[][];
  identityReports(): string[][];
  statusReportCount(): number;
  statusReportsWithRemove(): string[][];
  agentsCallCount(): number;
  lastControlArgs(): string[] | undefined;
  waitForLog(to: string, kind?: string, ms?: number): Promise<{ id: string; replyTo: string; to: string; text: string; failed?: boolean; args: string[] }>;
  sessions: Array<() => Promise<unknown>>;
  restore(): Promise<void>;
}

export function jsonLines(file: string): any[] {
  return readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

export function last<T>(items: T[]): T | undefined {
  return items.at(-1);
}


export const commandWork = new Map<string, Set<childProcess.ChildProcess>>();

export const spawn = childProcess.spawn;

childProcess.spawn = ((command: string, args: string[] = [], options: childProcess.SpawnOptions = {}) => {
  const child = spawn(command, args, options);
  const work = commandWork.get(command) ?? args?.map((arg) => commandWork.get(arg)).find(Boolean);
  if (work) {
    work.add(child);
    child.once("close", () => work.delete(child));
  }
  return child;
}) as typeof childProcess.spawn;

syncBuiltinESMExports();

// The suite's fake kido is one OCaml binary built by scripts/test-ts.sh; every
// fixture links it as a file literally named "kido", because findKido() joins a
// PATH entry with that name and checks that it is executable.
const fakeKidoEnv = process.env.KIDO_FAKE_KIDO;
if (!fakeKidoEnv) {
  throw new Error("KIDO_FAKE_KIDO is not set; run scripts/test-ts.sh, which builds and exports it");
}
if (!existsSync(fakeKidoEnv)) {
  throw new Error(`fake kido not built at ${fakeKidoEnv}; run scripts/test-ts.sh`);
}
const fakeKido: string = fakeKidoEnv;

export function makeFixture(): Fixture {
  const dir = mkdtempSync(join(tmpdir(), "kido-status-test-"));
  const binDir = join(dir, "bin");
  mkdirSync(binDir);
  const command = join(binDir, "kido");
  symlinkSync(fakeKido, command);
  const work = new Set<childProcess.ChildProcess>();
  commandWork.set(command, work);
  const sessions: Array<() => Promise<unknown>> = [];
  const inboxDir = join(dir, "inbox");
  const agentsFile = join(dir, "agents.json");
  const logFile = join(dir, "log.jsonl");
  const spawnLogFile = join(dir, "spawn.jsonl");
  const statusLogFile = join(dir, "status.jsonl");
  const setStatusLogFile = join(dir, "set-status.jsonl");
  const controlLogFile = join(dir, "control.jsonl");
  const runOutcomeLogFile = join(dir, "run-outcome.jsonl");
  const asyncBashLogFile = join(dir, "async-bash.jsonl");
  const agentsCallLogFile = join(dir, "agents-calls.jsonl");
  const parentAliveLogFile = join(dir, "parent-alive.jsonl");
  const stateDir = join(dir, "state");
  const deadSessionsFile = join(dir, "dead-sessions");
  writeFileSync(deadSessionsFile, "");
  writeFileSync(agentsFile, "[]");
  writeFileSync(logFile, "");
  writeFileSync(spawnLogFile, "");
  writeFileSync(statusLogFile, "");
  writeFileSync(setStatusLogFile, "");
  writeFileSync(controlLogFile, "");
  writeFileSync(runOutcomeLogFile, "");
  writeFileSync(asyncBashLogFile, "");
  writeFileSync(agentsCallLogFile, "");
  writeFileSync(parentAliveLogFile, "");

  const saved: Record<string, string | undefined> = { PATH: process.env.PATH, TMUX_PANE: process.env.TMUX_PANE };
  for (const [key, value] of Object.entries(process.env)) {
    if (key.startsWith("KIDO_FAKE_")) saved[key] = value;
  }
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KIDO_AGENT_") || key.startsWith("KIDO_FAKE_")) delete process.env[key];
  }
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMUX_PANE = "%1";
  process.env.KIDO_FAKE_AGENTS_FILE = agentsFile;
  process.env.KIDO_FAKE_LOG = logFile;
  process.env.KIDO_FAKE_SPAWN_LOG = spawnLogFile;
  process.env.KIDO_FAKE_STATUS_LOG = statusLogFile;
  process.env.KIDO_FAKE_SET_STATUS_LOG = setStatusLogFile;
  process.env.KIDO_FAKE_CONTROL_LOG = controlLogFile;
  process.env.KIDO_FAKE_RUN_OUTCOME_LOG = runOutcomeLogFile;
  process.env.KIDO_FAKE_ASYNC_BASH_LOG = asyncBashLogFile;
  process.env.KIDO_FAKE_STATE_DIR = stateDir;
  process.env.KIDO_FAKE_AGENTS_CALL_LOG = agentsCallLogFile;
  process.env.KIDO_FAKE_PARENT_ALIVE_LOG = parentAliveLogFile;
  process.env.KIDO_FAKE_DEAD_FILE = deadSessionsFile;
  delete process.env.KIDO_FAKE_PARENT_ALIVE; // default: the parent is alive
  delete process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS;
  process.env.KIDO_FAKE_INBOX_DIR = inboxDir;
  delete process.env.KIDO_FAKE_INBOX_FAIL;
  delete process.env.KIDO_FAKE_MESSAGE_FAIL_TO;
  delete process.env.KIDO_FAKE_MESSAGE_DELAY_MS;
  delete process.env.KIDO_FAKE_AGENTS_DELAY_MS;
  delete process.env.KIDO_FAKE_SESSION_HELD;

  return {
    agentsFile,
    logFile,
    inboxDir,
    setAgents(agents) {
      writeFileSync(agentsFile, JSON.stringify(agents.map((agent) => ({ named: true, ...(agent as object) }))));
    },
    setParentAlive(mode) {
      if (mode === "alive") delete process.env.KIDO_FAKE_PARENT_ALIVE;
      else process.env.KIDO_FAKE_PARENT_ALIVE = mode === "gone" ? "0" : "fail";
    },
    killSession(session) {
      appendFileSync(deadSessionsFile, session + "\n");
    },
    setParentAliveDelay(ms) {
      if (ms > 0) process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS = String(ms);
      else delete process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS;
    },
    parentAliveCalls() {
      return jsonLines(parentAliveLogFile);
    },
    setInboxFail(fail) {
      if (fail) process.env.KIDO_FAKE_INBOX_FAIL = "1";
      else delete process.env.KIDO_FAKE_INBOX_FAIL;
    },
    setMessageFailTo(to) {
      if (to) process.env.KIDO_FAKE_MESSAGE_FAIL_TO = to;
      else delete process.env.KIDO_FAKE_MESSAGE_FAIL_TO;
    },
    lastSpawnArgs() {
      return last(jsonLines(spawnLogFile))?.args;
    },
    lastSpawnTask() {
      return last(jsonLines(spawnLogFile))?.task;
    },
    lastSpawnCaller() {
      return last(jsonLines(spawnLogFile))?.caller;
    },
    lastRunOutcomeArgs() {
      return last(jsonLines(runOutcomeLogFile));
    },
    lastAsyncBashArgs() {
      return last(jsonLines(asyncBashLogFile));
    },
    runsDir: join(stateDir, "runs"),
    lastStatusArgs() {
      return last(jsonLines(statusLogFile));
    },
    setStatusCalls() {
      return jsonLines(setStatusLogFile);
    },
    identityReports() {
      return jsonLines(statusLogFile).filter((args: string[]) => !args.includes("--remove"));
    },
    statusReportsWithRemove() {
      return jsonLines(statusLogFile).filter((args: string[]) => args.includes("--remove"));
    },
    statusReportCount() {
      return jsonLines(statusLogFile).length;
    },
    agentsCallCount() {
      return jsonLines(agentsCallLogFile).length;
    },
    lastControlArgs() {
      return last(jsonLines(controlLogFile));
    },
    // Named after this test process's own pid, exactly as startInbox asks kido for.
    selfInboxPath() {
      return join(inboxDir, String(process.pid) + ".sock");
    },
    lastLogFor(to, kind) {
      return last(jsonLines(logFile).filter((l) => l.to === to && (!kind || l.kind === kind)));
    },
    async waitForLog(to, kind, ms = 2000) {
      let found: any;
      await pollUntil(() => (found = this.lastLogFor(to, kind)) !== undefined, ms, `a log entry for ${JSON.stringify({ to, kind })}`);
      return found;
    },
    sessions,
    async restore() {
      for (const shutdown of sessions.reverse()) await shutdown();
      await pollUntil(() => work.size === 0, 15000, "all fake commands to close");
      commandWork.delete(command);
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete process.env[k];
        else process.env[k] = v;
      }
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export function createFakePi() {
  const tools = new Map<string, any>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
  const messages: Array<{ message: any; opts: unknown }> = [];
  const renderers = new Map<string, (message: any, options: any, theme: any) => { render(width: number): string[]; handleMouse(event: any): unknown }>();
  // Keyed the same way the real UI keys a widget: content undefined means "cleared".
  const widgets = new Map<string, { content: ((tui: unknown, theme: any) => { render(width: number): string[]; handleMouse?(event: any): unknown }) | undefined; options?: unknown }>();
  const pi = {
    sessionName: undefined as string | undefined,
    getSessionName: (): string | undefined => pi.sessionName,
    getSettings: (): { tuiMode?: "regular" | "fullscreen" } => ({ tuiMode: "regular" }),
    getAllTools: () => [...tools.values()],
    appendEntry(_customType: string, _data: unknown) {},
    registerTool(tool: any) {
      tools.set(tool.name, tool);
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
    registerMessageRenderer(customType: string, renderer: Parameters<typeof renderers.set>[1]) {
      renderers.set(customType, renderer);
    },
  };
  async function emit(event: string, ...args: unknown[]): Promise<unknown[]> {
    const results: unknown[] = [];
    for (const h of handlers.get(event) ?? []) results.push(await h(...args));
    return results;
  }
  const autocompleteFactories: Array<(current: any) => any> = [];
  const notifications: Array<{ message: string; type?: string }> = [];
  let editorText = "";
  const ui = {
    setEditorText(text: string) { editorText = text; },
    getEditorText() { return editorText; },
    setWidget(key: string, content: ((tui: unknown, theme: any) => { render(width: number): string[]; handleMouse?(event: any): unknown }) | undefined, options?: unknown) {
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
    handlers,
    delivered,
    messages,
    renderers,
    widgets,
    notifications,
    autocompleteFactories,
    ui,
    emit,
  };
}

export const fakeTheme = {
  fg: (_color: string, text: string) => text,
  bgCalls: [] as Array<{ color: string; text: string }>,
  bg(color: string, text: string) {
    this.bgCalls.push({ color, text });
    return text;
  },
} as any;

export function fakeCtx(sessionId = "self-session", ui?: unknown, idle: () => boolean = () => true) {
  return {
    hasUI: true,
    sessionManager: { getSessionId: () => sessionId, getSessionName: () => undefined, getSessionFile: () => "/tmp/" + sessionId + ".json", getLeafId: () => null, getBranch: () => [] },
    model: undefined,
    isIdle: idle,
    hasPendingMessages: () => false,
    ui,
  };
}

// The shape every session-starting helper below shares: build a fake pi, run one
// or more extension factories against it, emit session_start with a ctx buildCtx
// assembles from the fake pi's own bundle.
export async function startSessionCore(fx: Fixture, factory: (pi: unknown) => void, buildCtx: (created: ReturnType<typeof createFakePi>) => unknown) {
  const created = createFakePi();
  factory(created.pi);
  const ctx = buildCtx(created);
  fx.sessions.push(() => created.emit("session_shutdown", { reason: "new" }));
  await created.emit("session_start", {}, ctx);
  return { ...created, inboxPath: fx.selfInboxPath() };
}

export async function startSession(
  fx: Fixture,
  { factory = loadExtensions, sessionId, idle }: { factory?: (pi: unknown) => void; sessionId?: string; idle?: () => boolean } = {},
) {
  return startSessionCore(fx, factory, (c) => fakeCtx(sessionId, c.ui, idle));
}

// Order is deliberately agents-last here and asserted both ways in its own test
// below: neither extension may depend on the other's factory having run first,
// since pi discovers a directory and picks its own order.
export function loadExtensions(pi: unknown): void {
  (kidoStatus as (pi: unknown) => void)(pi);
  (kidoAgents as (pi: unknown) => void)(pi);
}

// Reimports both extensions under a cache-busting specifier, so the module-scope
// constants each reads from the environment are recomputed. Both, with the same
// counter: the two find each other through globalThis rather than an import, so a
// fresh half and a cached half would silently pair up.
let freshImportCounter = 0;

export async function freshExtensions(order: "status-first" | "agents-first" = "status-first"): Promise<(pi: unknown) => void> {
  const fresh = `?fresh=${process.pid}-${freshImportCounter++}`;
  const status = await import(`./kido-status.ts${fresh}`);
  const agents = await import(`./kido-agents.ts${fresh}`);
  const factories = [status.default, agents.default] as Array<(pi: unknown) => void>;
  if (order === "agents-first") factories.reverse();
  return (pi: unknown) => {
    for (const factory of factories) factory(pi);
  };
}

// A subagent's session id is its run id, so a case playing one has to keep the two in step.
export const DEFAULT_SESSION = "self-session";

// Sets the parent edge and the run id equal to the session id the case then
// starts: an inherited parent edge alone does not make a subagent
// (kido-agents.ts, ownRunID). extra carries whatever else a case needs in the
// same save/restore; the extensions read all of it once at module scope, so each
// case still goes through freshExtensions() to pick it up.
export async function asSubagent<T>(sessionId: string, fn: () => Promise<T>, extra: Record<string, string> = {}): Promise<T> {
  return withEnv({ KIDO_AGENT_PARENT_SESSION: "boss-session", KIDO_AGENT_RUN_ID: sessionId, ...extra }, fn);
}

// Restores whatever was there. The extensions read their knobs once at module
// scope, so a case that sets one has to go through freshExtensions() inside this.
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

// Polls rather than listening for anything: several assertions below observe
// fire-and-forget or real-subprocess work with no promise to await and no event
// to subscribe to, only a file on disk to keep checking.
export async function pollUntil(cond: () => boolean | Promise<boolean>, ms = 2000, what = "a condition"): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

// Waits for `read()` to stop changing for a full `quietMs` window, not merely two
// samples some fixed delay apart: a late-arriving in-flight call can land at any
// point on a loaded runner. A source that never goes quiet times out rather than
// returning a false-stable reading.
export async function pollForStable(read: () => number, quietMs: number, timeoutMs: number, what: string): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  let last = read();
  let lastChange = Date.now();
  for (;;) {
    await new Promise((r) => setTimeout(r, 20));
    const cur = read();
    if (cur !== last) {
      last = cur;
      lastChange = Date.now();
    } else if (Date.now() - lastChange >= quietMs) {
      return last;
    }
    if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs}ms waiting for ${what} to stabilise (stuck growing, last count ${last})`);
  }
}

// sendToInbox plays a peer's half of the wire protocol: connect, write the
// payload, half-close, and read back "ok\n" or "refused\n".
export function sendToInbox(path: string, payload: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(path);
    let out = "";
    sock.on("connect", () => sock.end(payload));
    sock.on("data", (c) => (out += c.toString("utf8")));
    sock.on("end", () => resolve(out.trim()));
    sock.on("error", reject);
  });
}

export function envelope(kind: string, text: string, extra: { id?: string; replyTo?: string; from?: { session: string; name?: string; pane?: string } } = {}): string {
  return JSON.stringify({
    v: 1,
    kind,
    id: extra.id ?? "env-" + Math.random().toString(36).slice(2),
    from: extra.from ?? { session: "peer-x", name: "peer-x" },
    replyTo: extra.replyTo,
    text,
  });
}

// customMessages returns every message of one kido custom type a session
// recorded, the shared lookup every kido-ask/kido-notice/kido-message site
// below filters through.
export function customMessages(s: Pick<ReturnType<typeof createFakePi>, "messages">, customType: string) {
  return s.messages.filter((m) => m.message.customType === customType);
}

// askSent finds the kido-ask message a handleInboundAsk call handed to
// sendMessage, matching by a substring of its full content (the model's
// text, not the renderer's trimmed-down question).
export function askSent(s: Pick<ReturnType<typeof createFakePi>, "messages">, includes: string) {
  return customMessages(s, "kido-ask").find((m) => m.message.content.includes(includes));
}

// pendingState races a promise against a short timer, purely to observe
// that it has *not yet* settled - it must never be used to prove the
// opposite, since a promise that "settles" 1ms after the window closes
// would still read as pending.
export function pendingState(p: Promise<unknown>, ms = 30): Promise<"pending" | "settled"> {
  const timeout = Symbol();
  return Promise.race([p.then(() => "settled" as const), new Promise((r) => setTimeout(() => r(timeout), ms))]).then(
    (v) => (v === timeout ? "pending" : (v as "settled")),
  );
}

// settlesWithin asserts a promise resolves before ms elapse - the
// "promptly" half of the abandonPending contract - by racing it against a
// timer that throws.
export function settlesWithin<T = { content: Array<{ text: string }> }>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`did not settle within ${ms}ms`)), ms);
  });
  return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
}

export const twoPeers = [
  { id: "self", name: "self", parent: "", self: true, canMessage: true },
  { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
  { id: "peer-b", name: "peer-b", parent: "", self: false, canMessage: true, canReply: true },
];








export function argAfter(args: string[] | undefined, flag: string): string | undefined {
  if (!args) return undefined;
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

// A "stream" envelope is buffered on arrival and reaches the model only when
// flushStreams runs, so every case below asserts on pi.sendMessage calls, never on
// what arrived on the wire.
export const streamMessages = (messages: ReturnType<typeof createFakePi>["messages"]) =>
  messages.filter((m) => m.message.customType === "kido-stream");

export function streamEnvelope(text: string, run = "run-1", output = "/state/runs/run-1/output"): string {
  return JSON.stringify({ v: 1, kind: "stream", id: "env-" + Math.random().toString(36).slice(2), from: { session: "", name: "chatty" }, text, run, output });
}


export async function startWithShutdownSpy(fx: Fixture, factory: (pi: unknown) => void, sessionId?: string) {
  let shutdowns = 0;
  const s = await startSessionCore(fx, factory, () => ({ ...fakeCtx(sessionId), shutdown: () => { shutdowns++; } }));
  return { ...s, shutdowns: () => shutdowns };
}






