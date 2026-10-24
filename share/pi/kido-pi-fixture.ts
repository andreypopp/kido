// The fixture for the kido-pi.ts suite. A real pi host loads one extension and
// drives it only through registered tools, registered lifecycle events, and a
// real unix socket speaking the inbox wire protocol. Fakes stand in for the two
// programs the extension runs: `kido` for the run commands and `tmux` for pane
// options and discovery.

import childProcess from "node:child_process";

import assert from "node:assert/strict";

import { syncBuiltinESMExports } from "node:module";

import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, symlinkSync } from "node:fs";

import { dirname, join, delimiter } from "node:path";

import net from "node:net";

import kidoPi, { PARENT_GUIDANCE } from "./kido-pi.ts";

export interface AgentRecord {
  session: string;
  run?: string;
  model?: string;
  tools?: string[];
  fork?: boolean;
}

export interface PaneRow {
  pane_id: string;
  session_id?: string;
  window_id?: string;
  pane_active?: string;
  kido_run?: string;
  kido_session?: string;
  kido_name?: string;
  kido_inbox?: string;
  kido_activity?: string;
  pane_dead?: string;
  pane_dead_status?: string;
  pane_dead_signal?: string;
  pane_current_path?: string;
  pane_program_status?: string;
  pane_title?: string;
}

export type Inbox = { path: string; received(): string[]; setReply(reply: string): void; hold(): () => void };

export const piStatus = (state = "idle"): string => JSON.stringify({ serial: 1, records: [{ id: "", state, app: "pi" }] });

export const shellStatus = (state = "idle"): string => JSON.stringify({ serial: 1, records: [{ id: "", state }] });

export function selfPane(row: Partial<PaneRow> = {}): PaneRow {
  return paneRow({ pane_id: "%1", kido_session: "self-session", kido_name: "Self", pane_title: "π - Self", ...row });
}

export function agentPane(row: {
  pane: string;
  session: string;
  name?: string;
  inbox?: string;
  state?: string;
  tmux?: string;
  window?: string;
  title?: string;
  cwd?: string;
  status?: string;
}): PaneRow {
  return paneRow({
    pane_id: row.pane,
    session_id: row.tmux ?? "$1",
    window_id: row.window ?? "@1",
    kido_session: row.session,
    kido_name: row.name ?? "",
    kido_inbox: row.inbox ?? "",
    kido_activity: row.status ?? "",
    pane_program_status: piStatus(row.state ?? "idle"),
    pane_title: row.title ?? "",
    pane_current_path: row.cwd ?? "/tmp",
  });
}

export function paneRow(row: Partial<PaneRow> & { pane_id: string }): PaneRow {
  return {
    session_id: "$1",
    window_id: "@1",
    pane_active: "0",
    kido_run: "",
    kido_session: "",
    kido_name: "",
    kido_inbox: "",
    kido_activity: "",
    pane_dead: "0",
    pane_dead_status: "",
    pane_dead_signal: "",
    pane_current_path: "/tmp",
    pane_program_status: piStatus(),
    pane_title: "",
    ...row,
  };
}

export interface Fixture {
  stateDir: string;
  binDir: string;
  tmuxLogFile: string;
  panesFile: string;
  kidoLogFile: string;
  runsFile: string;
  runLogFile: string;
  runWaitLogFile: string;
  runStopLogFile: string;
  runOutcomeLogFile: string;
  runOutcomeCalls(): string[][];
  runsCalls(): string[][];
  setPi(script: string): void;
  runCalls(): string[][];
  runWaitCalls(): string[][];
  runStopCalls(): string[][];
  sessions: Array<() => Promise<unknown>>;
  setPanes(panes: PaneRow[]): void;
  setRuns(rows: unknown[]): void;
  tmuxCalls(): string[][];
  optionWrites(): Array<{ key: string; value: string | undefined }>;
  agentDir(parent: string, name: string): string;
  writeAgent(parent: string, name: string, record: AgentRecord): string;
  inboxPath(session: string): string;
  startInbox(reply?: string): Promise<Inbox>;
  startInboxAt(path: string, reply?: string): Promise<Inbox>;
  restore(): Promise<void>;
}

export function jsonLines(file: string): any[] {
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


let cachedFakeKido: string | null = null;
let cachedFakeTmux: string | null = null;

export function makeFixture(): Fixture {
  cachedFakeKido ??= process.env.KIDO_FAKE_KIDO ?? null;
  cachedFakeTmux ??= process.env.KIDO_FAKE_TMUX ?? null;
  if (!cachedFakeKido || !existsSync(cachedFakeKido)) {
    throw new Error("KIDO_FAKE_KIDO is not set or not built; run scripts/test-ts.sh");
  }
  if (!cachedFakeTmux || !existsSync(cachedFakeTmux)) {
    throw new Error("KIDO_FAKE_TMUX is not set or not built; run scripts/test-ts.sh");
  }
  // A short root: the extension refuses an inbox path over 103 bytes, and a
  // spawned child's socket is named after its 32-hex session id.
  const dir = mkdtempSync(join("/tmp", "kido-pi-test-"));
  const binDir = join(dir, "bin");
  mkdirSync(binDir);
  const command = join(binDir, "kido");
  symlinkSync(cachedFakeKido, command);
  symlinkSync(cachedFakeTmux, join(binDir, "tmux"));
  const work = new Set<childProcess.ChildProcess>();
  commandWork.set(command, work);
  const sessions: Array<() => Promise<unknown>> = [];
  const inboxes: Array<{ close(): Promise<void> }> = [];
  const stateDir = join(dir, "state");
  const tmuxLogFile = join(dir, "tmux.jsonl");
  const panesFile = join(dir, "panes.json");
  const kidoLogFile = join(dir, "kido.jsonl");
  const runsFile = join(dir, "runs.json");
  const runLogFile = join(dir, "run.jsonl");
  const runWaitLogFile = join(dir, "run-wait.jsonl");
  const runStopLogFile = join(dir, "run-stop.jsonl");
  const runOutcomeLogFile = join(dir, "run-outcome.jsonl");
  const runsLogFile = join(dir, "runs-log.jsonl");
  mkdirSync(stateDir);
  writeFileSync(tmuxLogFile, "");
  writeFileSync(panesFile, "[]");
  writeFileSync(kidoLogFile, "");
  writeFileSync(runsFile, "[]");
  writeFileSync(runLogFile, "");
  writeFileSync(runWaitLogFile, "");
  writeFileSync(runStopLogFile, "");
  writeFileSync(runOutcomeLogFile, "");
  writeFileSync(runsLogFile, "");

  const saved: Record<string, string | undefined> = {};
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KIDO_") || key === "TMUX" || key === "TMUX_PANE" || key === "PATH" || key === "XDG_STATE_HOME") saved[key] = process.env[key];
  }
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("KIDO_AGENT_") || key.startsWith("KIDO_FAKE_")) delete process.env[key];
  }
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMUX = "/tmp/kido-pi-test/default,123,0";
  process.env.TMUX_PANE = "%1";
  process.env.KIDO_PI_STATE_DIR = stateDir;
  delete process.env.XDG_STATE_HOME;
  process.env.KIDO_FAKE_KIDO = cachedFakeKido;
  process.env.KIDO_FAKE_TMUX_LOG = tmuxLogFile;
  process.env.KIDO_FAKE_TMUX_PANES = panesFile;
  process.env.KIDO_FAKE_STATE_DIR = stateDir;
  process.env.KIDO_FAKE_LOG = kidoLogFile;
  process.env.KIDO_FAKE_RUNS_FILE = runsFile;
  process.env.KIDO_FAKE_RUN_LOG = runLogFile;
  process.env.KIDO_FAKE_RUN_WAIT_LOG = runWaitLogFile;
  process.env.KIDO_FAKE_RUN_STOP_LOG = runStopLogFile;
  process.env.KIDO_FAKE_RUN_OUTCOME_LOG = runOutcomeLogFile;
  process.env.KIDO_FAKE_RUNS_LOG = runsLogFile;
  delete process.env.KIDO_FAKE_RUN_WAIT_GATE;
  delete process.env.KIDO_FAKE_RUN_WAIT_OUTCOME;
  delete process.env.KIDO_FAKE_RUN_ID;

  const agentDir = (parent: string, name: string) => join(stateDir, "agents", parent, name);

  return {
    stateDir,
    binDir,
    tmuxLogFile,
    panesFile,
    kidoLogFile,
    runsFile,
    runLogFile,
    runWaitLogFile,
    runStopLogFile,
    runOutcomeLogFile,
    runOutcomeCalls() {
      return jsonLines(runOutcomeLogFile);
    },
    runsCalls() {
      return jsonLines(runsLogFile);
    },
    setPi(script) {
      writeFileSync(join(binDir, "pi"), script, { mode: 0o755 });
    },
    runCalls() {
      return jsonLines(runLogFile);
    },
    runWaitCalls() {
      return jsonLines(runWaitLogFile);
    },
    runStopCalls() {
      return jsonLines(runStopLogFile);
    },
    sessions,
    setPanes(panes) {
      writeFileSync(panesFile, JSON.stringify(panes));
    },
    setRuns(rows) {
      writeFileSync(runsFile, JSON.stringify(rows));
    },
    tmuxCalls() {
      return jsonLines(tmuxLogFile);
    },
    optionWrites() {
      const writes: Array<{ key: string; value: string | undefined }> = [];
      for (const argv of jsonLines(tmuxLogFile) as string[][]) {
        for (const command of argv.join("\u0000").split("\u0000;\u0000").map((part) => part.split("\u0000"))) {
          if (command[0] !== "set-option") continue;
          const unset = command.includes("-pu") || command.includes("-u");
          const keyIndex = command.findIndex((arg) => arg.startsWith("@kido_"));
          writes.push({ key: command[keyIndex]!, value: unset ? undefined : command[keyIndex + 1] });
        }
      }
      return writes;
    },
    agentDir,
    writeAgent(parent, name, record) {
      const child = agentDir(parent, name);
      mkdirSync(child, { recursive: true });
      writeFileSync(join(child, "agent.json"), JSON.stringify({ run: record.session, model: "", tools: [], fork: false, ...record }));
      return child;
    },
    inboxPath(session) {
      return join(stateDir, "inbox", session + ".sock");
    },
    async startInbox(reply = "ok") {
      return serveInbox(join(stateDir, "inbox", "peer-" + inboxes.length + "-" + process.pid + ".sock"), reply);
    },
    async startInboxAt(path, reply = "ok") {
      return serveInbox(path, reply);
    },
    async restore() {
      for (const shutdown of sessions.reverse()) await shutdown();
      for (const inbox of inboxes) await inbox.close();
      await pollUntil(() => work.size === 0, 15000, "all fake commands to close");
      commandWork.delete(command);
      for (const key of Object.keys(process.env)) {
        if (key.startsWith("KIDO_") || key === "TMUX" || key === "TMUX_PANE" || key === "XDG_STATE_HOME") delete process.env[key];
      }
      for (const [k, v] of Object.entries(saved)) {
        if (v !== undefined) process.env[k] = v;
      }
      rmSync(dir, { recursive: true, force: true });
    },
  };

  async function serveInbox(path: string, reply: string): Promise<Inbox> {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    const received: string[] = [];
    let answer = reply;
    let gate: Promise<void> | null = null;
    let openGate: (() => void) | null = null;
    const server = net.createServer({ allowHalfOpen: true }, (sock) => {
      const chunks: Buffer[] = [];
      sock.on("error", () => {});
      sock.on("data", (chunk: Buffer) => chunks.push(chunk));
      sock.on("end", () => {
        received.push(Buffer.concat(chunks).toString("utf8"));
        const held = gate;
        if (held) held.then(() => sock.end(answer + "\n"));
        else sock.end(answer + "\n");
      });
    });
    await new Promise<void>((resolve) => server.listen(path, resolve));
    const inbox: Inbox = {
      path,
      received: () => received,
      setReply(next) {
        answer = next;
      },
      hold() {
        gate = new Promise<void>((resolve) => {
          openGate = resolve;
        });
        return () => {
          gate = null;
          openGate?.();
          openGate = null;
        };
      },
    };
    inboxes.push({
      close: async () => {
        await new Promise<void>((resolve) => server.close(() => resolve()));
      },
    });
    return inbox;
  }
}

export function createFakePi() {
  const tools = new Map<string, any>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
  const messages: Array<{ message: any; opts: unknown }> = [];
  const renderers = new Map<string, (message: any, options: any, theme: any) => { render(width: number): string[]; handleMouse(event: any): unknown }>();
  const widgets = new Map<string, { content: ((tui: unknown, theme: any) => { render(width: number): string[]; handleMouse?(event: any): unknown }) | undefined; options?: unknown }>();
  const pi = {
    sessionName: undefined as string | undefined,
    getSessionName: (): string | undefined => pi.sessionName,
    getSettings: (): { tuiMode?: "regular" | "fullscreen" } => ({ tuiMode: "regular" }),
    getAllTools: () => [...tools.values()],
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
  const notifications: Array<{ message: string; type?: string }> = [];
  const autocompleteFactories: Array<(current: any) => any> = [];
  const ui = {
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

export function parentSetup(fx: Fixture, inboxPath: string, workerInbox = ""): void {
  fx.setPanes([
    agentPane({ pane: "%1", session: "self-session", name: "worker", inbox: workerInbox }),
    agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inboxPath }),
  ]);
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

export function assertReport(inbox: Inbox, index: number, text: string): void {
  const notice: { kind?: string; text?: string } = JSON.parse(inbox.received()[index]!);
  assert.equal(notice.kind, "notice");
  assert.equal(notice.text, text + PARENT_GUIDANCE);
}

export function fakeCtx(sessionId: string | undefined = "self-session", ui?: unknown, idle: () => boolean = () => true) {
  return {
    hasUI: true,
    sessionManager: {
      getSessionId: () => sessionId,
      getSessionName: () => undefined,
      getSessionFile: () => (sessionId ? "/tmp/" + sessionId + ".json" : undefined),
    },
    model: undefined,
    isIdle: idle,
    hasPendingMessages: () => false,
    abort: () => {},
    shutdown: () => {},
    ui,
  };
}

export async function startSessionCore(
  fx: Fixture,
  factory: (pi: never) => void,
  buildCtx: (created: ReturnType<typeof createFakePi>) => unknown,
  { record = true }: { record?: boolean } = {},
) {
  const created = createFakePi();
  factory(created.pi as never);
  const ctx = buildCtx(created);
  if (record) fx.sessions.push(() => created.emit("session_shutdown", { reason: "new" }));
  await created.emit("session_start", {}, ctx);
  return created;
}

// A session with a live pi name, so @kido_name and an envelope's from.name agree.
export async function startNamedSession(fx: Fixture, name: string, sessionId = "self-session", factory: (pi: never) => void = kidoPi) {
  const created = await startSessionCore(fx, factory, (c) => {
    c.pi.sessionName = name;
    return fakeCtx(sessionId, c.ui);
  });
  return { ...created, inboxPath: fx.inboxPath(sessionId) };
}

export async function startSession(
  fx: Fixture,
  { factory = kidoPi, sessionId = "self-session", idle }: { factory?: (pi: never) => void; sessionId?: string; idle?: () => boolean } = {},
) {
  const created = await startSessionCore(fx, factory, (c) => fakeCtx(sessionId, c.ui, idle));
  return { ...created, inboxPath: fx.inboxPath(sessionId) };
}

// Reimports the extension under a cache-busting specifier: the module reads the
// state directory and the environment at call time, but a /reload is a fresh
// module instance in the same process and must be played as one.
let freshImportCounter = 0;

export async function freshExtension(): Promise<(pi: never) => void> {
  const fresh = `?fresh=${process.pid}-${freshImportCounter++}`;
  const mod = await import(`./kido-pi.ts${fresh}`);
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

// A real child: its own agent directory records its own session id, which is
// what makes the parent edge trustworthy.
export async function asSubagent<T>(fx: Fixture, sessionId: string, fn: () => Promise<T>, opts: { parent?: string; name?: string; run?: string; extra?: Record<string, string> } = {}): Promise<T> {
  const parent = opts.parent ?? "boss-session";
  const name = opts.name ?? "worker";
  const run = opts.run ?? sessionId;
  const agentDir = fx.writeAgent(parent, name, { session: sessionId, run });
  return withEnv({ KIDO_RUN_ID: run, KIDO_AGENT_DIR: agentDir, KIDO_AGENT_PARENT_SESSION: parent, ...opts.extra }, fn);
}

export async function pollUntil(cond: () => boolean | Promise<boolean>, ms = 2000, what = "a condition"): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

export async function pollForStable(read: () => number, quietMs: number, timeoutMs: number, what: string): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  let previous = read();
  let lastChange = Date.now();
  for (;;) {
    await new Promise((r) => setTimeout(r, 20));
    const cur = read();
    if (cur !== previous) {
      previous = cur;
      lastChange = Date.now();
    } else if (Date.now() - lastChange >= quietMs) {
      return previous;
    }
    if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs}ms waiting for ${what} to stabilise`);
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

export function envelope(kind: string, text: string, extra: { from?: { session: string; name?: string; pane?: string } } = {}): string {
  return JSON.stringify({
    v: 1,
    kind,
    id: "env-" + Math.random().toString(36).slice(2),
    from: extra.from ?? { session: "peer-x", name: "peer-x" },
    text,
  });
}

export function customMessages(s: Pick<ReturnType<typeof createFakePi>, "messages">, customType: string) {
  return s.messages.filter((m) => m.message.customType === customType);
}

export function agentJson(fx: Fixture, parent: string, name: string): { session: string; run: string; model: string; tools: string[]; fork: boolean } {
  return JSON.parse(readFileSync(join(fx.agentDir(parent, name), "agent.json"), "utf8"));
}

export function argAfter(args: string[] | undefined, flag: string): string | undefined {
  if (!args) return undefined;
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

export function pendingState(p: Promise<unknown>, ms = 30): Promise<"pending" | "settled"> {
  const timeout = Symbol();
  return Promise.race([p.then(() => "settled" as const), new Promise((r) => setTimeout(() => r(timeout), ms))]).then(
    (v) => (v === timeout ? "pending" : (v as "settled")),
  );
}

export function settlesWithin<T = { content: Array<{ text: string }> }>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`did not settle within ${ms}ms`)), ms);
  });
  return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
}

export async function startWithSpies(fx: Fixture, factory: (pi: never) => void, sessionId?: string) {
  let aborts = 0;
  let shutdowns = 0;
  const created = await startSessionCore(fx, factory, (c) => ({
    ...fakeCtx(sessionId, c.ui),
    abort: () => {
      aborts++;
    },
    shutdown: () => {
      shutdowns++;
    },
  }));
  return { ...created, inboxPath: fx.inboxPath(sessionId ?? "self-session"), aborts: () => aborts, shutdowns: () => shutdowns };
}
