// Regression suite for the reply correlation, timeout, cycle refusal and
// inbox teardown logic in kido-status.ts and its companion extension
// kido-agents.ts. One suite covers the pair because the pair is what a pi
// host loads: every case here needs the status half's inbox and the agent
// half's dispatch at once, and splitting them would mean two suites
// sharing one fixture and each loading both files anyway. It drives the
// extensions only through what a real pi host and a real peer agent would
// use: the registered tools, the registered lifecycle events, and a real
// unix socket speaking the inbox wire protocol - never by reaching into
// either module's closures.
//
// A fake `kido` executable stands in for the real binary: it is what
// findKido() discovers on PATH, and every call the extension shells out
// to (agents --json, agent-status, message) is answered by it. It never
// actually delivers a message anywhere - the "reply" half of a
// conversation is always injected directly onto the extension's own
// inbox socket, exactly as a real peer's `kido message` would arrive.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter, dirname } from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";
import kidoStatus, { parseEnvelope } from "./kido-status.ts";
import kidoAgents, { isAncestor } from "./kido-agents.ts";

// The fake kido binary. Written to disk once per fixture so it can be
// found on PATH as a file literally named "kido" - findKido() joins a
// PATH entry with that name and checks it is executable, nothing fancier.
const FAKE_KIDO = `#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

function readStdin() {
  try { return fs.readFileSync(0, "utf8"); } catch { return ""; }
}

const args = process.argv.slice(2);
switch (args[0]) {
  case "inbox-path": {
    if (process.env.KIDO_FAKE_INBOX_FAIL === "1") process.exit(1);
    const dir = process.env.KIDO_FAKE_INBOX_DIR;
    fs.mkdirSync(dir, { recursive: true });
    process.stdout.write(path.join(dir, args[1] + ".sock") + "\\n");
    process.exit(0);
  }
  case "agents": {
    const file = process.env.KIDO_FAKE_AGENTS_FILE;
    const callLog = process.env.KIDO_FAKE_AGENTS_CALL_LOG;
    if (callLog) fs.appendFileSync(callLog, "1\\n");
    process.stdout.write(file && fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "[]");
    process.exit(0);
  }
  case "agent-status": {
    const logFile = process.env.KIDO_FAKE_STATUS_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  case "message": {
    let kind = "message", replyTo = "", id = "", to = null;
    for (let i = 1; i < args.length; i++) {
      if (args[i] === "--kind") kind = args[++i];
      else if (args[i] === "--reply-to") replyTo = args[++i];
      else if (args[i] === "--id") id = args[++i];
      else if (args[i] === "--") { to = args[i + 1]; break; }
    }
    const text = readStdin();
    const respond = () => {
      const failed = !!(process.env.KIDO_FAKE_MESSAGE_FAIL_TO && to === process.env.KIDO_FAKE_MESSAGE_FAIL_TO);
      // Logged either way: a test asserting a dropped delivery still needs
      // to see the attempt was made, with the right kind and target.
      const logFile = process.env.KIDO_FAKE_LOG;
      if (logFile) fs.appendFileSync(logFile, JSON.stringify({ kind, replyTo, id, to, text, failed }) + "\\n");
      if (failed) {
        process.stderr.write("kido message: no agent listening on the inbox\\n");
        process.exit(1);
      }
      process.stdout.write("delivered to " + to + " by inbox\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_MESSAGE_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "spawn": {
    const logFile = process.env.KIDO_FAKE_SPAWN_LOG;
    const task = readStdin();
    if (logFile) fs.appendFileSync(logFile, JSON.stringify({ args, task }) + "\\n");
    const respond = () => {
      process.stdout.write("@9 %9 fake-run-id\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_SPAWN_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "run-outcome": {
    const logFile = process.env.KIDO_FAKE_RUN_OUTCOME_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  case "close-window": {
    const logFile = process.env.KIDO_FAKE_CLOSE_WINDOW_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  case "window-focused": {
    const logFile = process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.stdout.write((process.env.KIDO_FAKE_WINDOW_FOCUSED === "1" ? "true" : "false") + "\\n");
    process.exit(0);
  }
  case "interrupt":
  case "stop": {
    const logFile = process.env.KIDO_FAKE_CONTROL_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.stdout.write((args[0] === "interrupt" ? "interrupted " : "stopped ") + args[args.length - 1] + "\\n");
    process.exit(0);
  }
  default:
    process.exit(1);
}
`;

interface Fixture {
  agentsFile: string;
  logFile: string;
  inboxDir: string;
  setAgents(agents: unknown[]): void;
  setInboxFail(fail: boolean): void;
  setMessageFailTo(to: string | undefined): void;
  setWindowFocused(focused: boolean): void;
  windowFocusedCallCount(): number;
  selfInboxPath(): string;
  lastLogFor(to: string, kind?: string): { id: string; replyTo: string; to: string; text: string; failed?: boolean } | undefined;
  lastSpawnArgs(): string[] | undefined;
  lastSpawnTask(): string | undefined;
  lastRunOutcomeArgs(): string[] | undefined;
  waitForCloseWindow(ms?: number): Promise<string[]>;
  lastStatusArgs(): string[] | undefined;
  statusReportsWith(status: string): string[][];
  statusReportsWithRemove(): string[][];
  agentsCallCount(): number;
  lastControlArgs(): string[] | undefined;
  // waitForLog polls lastLogFor until it has a match (see pollUntil).
  waitForLog(to: string, kind?: string, ms?: number): Promise<{ id: string; replyTo: string; to: string; text: string; failed?: boolean }>;
  restore(): void;
}

// jsonLines reads back one of the fake kido's JSONL logs; an empty file is
// simply no entries. last is the most recent of them, or undefined.
function jsonLines(file: string): any[] {
  return readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function last<T>(items: T[]): T | undefined {
  return items[items.length - 1];
}

function makeFixture(): Fixture {
  const dir = mkdtempSync(join(tmpdir(), "kido-status-test-"));
  const binDir = join(dir, "bin");
  mkdirSync(binDir);
  writeFileSync(join(binDir, "kido"), FAKE_KIDO, { mode: 0o755 });
  const inboxDir = join(dir, "inbox");
  mkdirSync(inboxDir);
  const agentsFile = join(dir, "agents.json");
  const logFile = join(dir, "log.jsonl");
  const spawnLogFile = join(dir, "spawn.jsonl");
  const closeWindowLogFile = join(dir, "close-window.jsonl");
  const statusLogFile = join(dir, "status.jsonl");
  const controlLogFile = join(dir, "control.jsonl");
  const runOutcomeLogFile = join(dir, "run-outcome.jsonl");
  const agentsCallLogFile = join(dir, "agents-calls.jsonl");
  writeFileSync(agentsFile, "[]");
  writeFileSync(logFile, "");
  writeFileSync(spawnLogFile, "");
  writeFileSync(closeWindowLogFile, "");
  writeFileSync(statusLogFile, "");
  writeFileSync(controlLogFile, "");
  writeFileSync(runOutcomeLogFile, "");
  writeFileSync(agentsCallLogFile, "");
  const windowFocusedLogFile = join(dir, "window-focused.jsonl");
  writeFileSync(windowFocusedLogFile, "");

  const saved = {
    PATH: process.env.PATH,
    TMUX_PANE: process.env.TMUX_PANE,
    KIDO_FAKE_AGENTS_FILE: process.env.KIDO_FAKE_AGENTS_FILE,
    KIDO_FAKE_LOG: process.env.KIDO_FAKE_LOG,
    KIDO_FAKE_SPAWN_LOG: process.env.KIDO_FAKE_SPAWN_LOG,
    KIDO_FAKE_CLOSE_WINDOW_LOG: process.env.KIDO_FAKE_CLOSE_WINDOW_LOG,
    KIDO_FAKE_STATUS_LOG: process.env.KIDO_FAKE_STATUS_LOG,
    KIDO_FAKE_CONTROL_LOG: process.env.KIDO_FAKE_CONTROL_LOG,
    KIDO_FAKE_RUN_OUTCOME_LOG: process.env.KIDO_FAKE_RUN_OUTCOME_LOG,
    KIDO_FAKE_AGENTS_CALL_LOG: process.env.KIDO_FAKE_AGENTS_CALL_LOG,
    KIDO_FAKE_WINDOW_FOCUSED_LOG: process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG,
    KIDO_FAKE_WINDOW_FOCUSED: process.env.KIDO_FAKE_WINDOW_FOCUSED,
    KIDO_FAKE_INBOX_DIR: process.env.KIDO_FAKE_INBOX_DIR,
    KIDO_FAKE_INBOX_FAIL: process.env.KIDO_FAKE_INBOX_FAIL,
    KIDO_FAKE_MESSAGE_FAIL_TO: process.env.KIDO_FAKE_MESSAGE_FAIL_TO,
    KIDO_FAKE_MESSAGE_DELAY_MS: process.env.KIDO_FAKE_MESSAGE_DELAY_MS,
  };
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMUX_PANE = "%1";
  process.env.KIDO_FAKE_AGENTS_FILE = agentsFile;
  process.env.KIDO_FAKE_LOG = logFile;
  process.env.KIDO_FAKE_SPAWN_LOG = spawnLogFile;
  process.env.KIDO_FAKE_CLOSE_WINDOW_LOG = closeWindowLogFile;
  process.env.KIDO_FAKE_STATUS_LOG = statusLogFile;
  process.env.KIDO_FAKE_CONTROL_LOG = controlLogFile;
  process.env.KIDO_FAKE_RUN_OUTCOME_LOG = runOutcomeLogFile;
  process.env.KIDO_FAKE_AGENTS_CALL_LOG = agentsCallLogFile;
  process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG = windowFocusedLogFile;
  delete process.env.KIDO_FAKE_WINDOW_FOCUSED; // default: not focused
  process.env.KIDO_FAKE_INBOX_DIR = inboxDir;
  delete process.env.KIDO_FAKE_INBOX_FAIL;
  delete process.env.KIDO_FAKE_MESSAGE_FAIL_TO;
  delete process.env.KIDO_FAKE_MESSAGE_DELAY_MS;

  return {
    agentsFile,
    logFile,
    inboxDir,
    setAgents(agents) {
      writeFileSync(agentsFile, JSON.stringify(agents));
    },
    setInboxFail(fail) {
      if (fail) process.env.KIDO_FAKE_INBOX_FAIL = "1";
      else delete process.env.KIDO_FAKE_INBOX_FAIL;
    },
    setMessageFailTo(to) {
      if (to) process.env.KIDO_FAKE_MESSAGE_FAIL_TO = to;
      else delete process.env.KIDO_FAKE_MESSAGE_FAIL_TO;
    },
    setWindowFocused(focused) {
      if (focused) process.env.KIDO_FAKE_WINDOW_FOCUSED = "1";
      else delete process.env.KIDO_FAKE_WINDOW_FOCUSED;
    },
    windowFocusedCallCount() {
      return jsonLines(windowFocusedLogFile).length;
    },
    lastSpawnArgs() {
      return last(jsonLines(spawnLogFile))?.args;
    },
    lastSpawnTask() {
      return last(jsonLines(spawnLogFile))?.task;
    },
    lastRunOutcomeArgs() {
      return last(jsonLines(runOutcomeLogFile));
    },
    async waitForCloseWindow(ms = 2000) {
      let found: string[] | undefined;
      await pollUntil(() => (found = last(jsonLines(closeWindowLogFile))) !== undefined, ms, "a kido close-window call");
      return found!;
    },
    lastStatusArgs() {
      return last(jsonLines(statusLogFile));
    },
    statusReportsWith(status) {
      return jsonLines(statusLogFile).filter((args: string[]) => {
        const i = args.indexOf("--status");
        return i >= 0 && args[i + 1] === status;
      });
    },
    statusReportsWithRemove() {
      return jsonLines(statusLogFile).filter((args: string[]) => args.includes("--remove"));
    },
    agentsCallCount() {
      return jsonLines(agentsCallLogFile).length;
    },
    lastControlArgs() {
      return last(jsonLines(controlLogFile));
    },
    // Named after this test process's own pid, exactly as startInbox asks
    // kido for - the same reason a /reload rebinds at the same path.
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
    restore() {
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete process.env[k];
        else process.env[k] = v;
      }
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

// A fake pi host: enough of ExtensionAPI to register tools and lifecycle
// handlers and to record what the extension tried to say to the model.
function createFakePi() {
  const tools = new Map<string, any>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
  const messages: Array<{ message: any; opts: unknown }> = [];
  const renderers = new Map<string, (message: any, options: any, theme: any) => unknown>();
  const pi = {
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
    registerMessageRenderer(customType: string, renderer: (message: any, options: any, theme: any) => unknown) {
      renderers.set(customType, renderer);
    },
  };
  // emit returns each handler's own return value, in registration order,
  // so a test can read what a hook like before_agent_start would hand
  // back to a real pi host - the fake host applies none of it itself.
  async function emit(event: string, ...args: unknown[]): Promise<unknown[]> {
    const results: unknown[] = [];
    for (const h of handlers.get(event) ?? []) results.push(await h(...args));
    return results;
  }
  return { pi, tools, delivered, messages, renderers, emit };
}

// fakeTheme is the minimal Theme surface a message renderer reads: fg()
// applied as an identity function, so a rendered line's text is asserted
// on directly rather than through a colour-code-stripping helper.
const fakeTheme = { fg: (_color: string, text: string) => text } as any;

function fakeCtx(sessionId = "self-session") {
  return {
    sessionManager: { getSessionId: () => sessionId, getSessionName: () => undefined },
    model: undefined,
    isIdle: () => true,
  };
}

async function startSession(fx: Fixture, sessionId?: string) {
  const { pi, tools, delivered, messages, renderers, emit } = createFakePi();
  loadExtensions(pi);
  await emit("session_start", {}, fakeCtx(sessionId));
  return { tools, delivered, messages, renderers, emit, inboxPath: fx.selfInboxPath() };
}

// loadExtensions is what a pi host does with the pair: run both factories
// against the same host. The order is deliberately agents-last here and
// asserted both ways in its own test below - neither extension may depend
// on the other's factory having run first (see the seam note in
// kido-status.ts), since pi discovers a directory and picks its own order.
function loadExtensions(pi: unknown): void {
  (kidoStatus as (pi: unknown) => void)(pi);
  (kidoAgents as (pi: unknown) => void)(pi);
}

// startSessionUsing is startSession but for factories that are not the
// modules' static default exports - needed by tests that must vary
// KIDO_AGENT_TASK_FILE or KIDO_AGENT_PARENT_INSTANCE, which the extensions
// read once, at module scope, when they are first imported.
// freshExtensions below reloads both so those module-scope constants are
// recomputed from whatever the environment holds at that moment.
async function startSessionUsing(factory: (pi: unknown) => void, fx: Fixture, sessionId?: string) {
  const { pi, tools, delivered, messages, renderers, emit } = createFakePi();
  factory(pi);
  await emit("session_start", {}, fakeCtx(sessionId));
  return { tools, delivered, messages, renderers, emit, inboxPath: fx.selfInboxPath() };
}

// freshExtensions reimports both extensions under a cache-busting
// specifier, so the module-scope constants each reads from the
// environment are recomputed. Both, and with the same counter: they are
// two modules that find each other through globalThis rather than through
// an import (see the seam note in kido-status.ts), so a fresh half and a
// cached half would silently pair up and serve a session neither started.
let freshImportCounter = 0;
async function freshExtensions(order: "status-first" | "agents-first" = "status-first"): Promise<(pi: unknown) => void> {
  const fresh = `?fresh=${process.pid}-${freshImportCounter++}`;
  const status = await import(`./kido-status.ts${fresh}`);
  const agents = await import(`./kido-agents.ts${fresh}`);
  const factories = [status.default, agents.default] as Array<(pi: unknown) => void>;
  if (order === "agents-first") factories.reverse();
  return (pi: unknown) => {
    for (const factory of factories) factory(pi);
  };
}

// pi discovers extensions in a directory and picks its own order, so
// neither half may read the other at factory time (see the seam note in
// kido-status.ts). Loaded the other way round, the pair must still wire
// up whole: the agent half's tools registered, and an envelope arriving
// on the status half's inbox dispatched by kind rather than falling back
// to the plain-text path. Through freshExtensions only because that is
// what lets a case choose the order; nothing here depends on the
// constants a fresh import recomputes.
test("either load order wires the pair up: agents first, status second", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const factory = await freshExtensions("agents-first");
    const s = await startSessionUsing(factory, fx);
    assert.ok(s.tools.get("ask_agent"), "the agent half registered its tools");
    const resp = await sendToInbox(s.inboxPath, envelope("notice", "loaded either way", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      s.messages.some((m) => m.message.content === "loaded either way"),
      "the envelope was dispatched by the agent half, not delivered as plain text",
    );
  } finally {
    fx.restore();
  }
});

// pollUntil waits for a condition to become true, polling rather than
// listening for anything: several assertions below observe work this
// extension does fire-and-forget (a detached, unref'd status report) or
// asynchronously via a real subprocess (runKido shells out via spawn, not
// execFileSync), so there is no promise to await and no event to subscribe
// to - only a file on disk to keep checking. In particular ask_agent's
// execute() can return control to its caller before the fake kido
// subprocess for the outbound send has appended its log entry.
async function pollUntil(cond: () => boolean, ms = 2000, what = "a condition"): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    if (cond()) return;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

// sendToInbox plays a peer's half of the wire protocol: connect, write the
// payload, half-close, and read back "ok\n" or "refused\n".
function sendToInbox(path: string, payload: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(path);
    let out = "";
    sock.on("connect", () => sock.end(payload));
    sock.on("data", (c) => (out += c.toString("utf8")));
    sock.on("end", () => resolve(out.trim()));
    sock.on("error", reject);
  });
}

function envelope(kind: string, text: string, extra: { id?: string; replyTo?: string; from?: { session: string; name?: string; pane?: string } } = {}): string {
  return JSON.stringify({
    v: 1,
    kind,
    id: extra.id ?? "env-" + Math.random().toString(36).slice(2),
    from: extra.from ?? { session: "peer-x", name: "peer-x" },
    replyTo: extra.replyTo,
    text,
  });
}

// pendingState races a promise against a short timer, purely to observe
// that it has *not yet* settled - it must never be used to prove the
// opposite, since a promise that "settles" 1ms after the window closes
// would still read as pending.
function pendingState(p: Promise<unknown>, ms = 30): Promise<"pending" | "settled"> {
  const timeout = Symbol();
  return Promise.race([p.then(() => "settled" as const), new Promise((r) => setTimeout(() => r(timeout), ms))]).then(
    (v) => (v === timeout ? "pending" : (v as "settled")),
  );
}

// settlesWithin asserts a promise resolves before ms elapse - the
// "promptly" half of the abandonPending contract - by racing it against a
// timer that throws.
function settlesWithin<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`did not settle within ${ms}ms`)), ms)),
  ]);
}

const twoPeers = [
  { id: "self", name: "self", parent: "", self: true, canMessage: true },
  { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true },
  { id: "peer-b", name: "peer-b", parent: "", self: false, canMessage: true },
];

test("reply correlation: a foreign replyTo settles nothing and is surfaced; the right id settles only that ask", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
    const ask1 = await fx.waitForLog("peer-a", "ask");
    assert.ok(ask1?.id, "ask 1 was sent with an id");

    const p2 = ask.execute("c2", { to: "peer-b", question: "q2" });
    const ask2 = await fx.waitForLog("peer-b", "ask");
    assert.ok(ask2?.id && ask2.id !== ask1!.id, "ask 2 has its own id");

    const foreign = await sendToInbox(s.inboxPath, envelope("reply", "stray answer", { replyTo: "nope", from: { session: "someone-else" } }));
    assert.equal(foreign, "ok");
    assert.ok(s.delivered.some((d) => d.text.includes("stray answer")), "an unmatched reply is surfaced to the model");
    assert.equal(await pendingState(p1), "pending");
    assert.equal(await pendingState(p2), "pending");

    const r1 = await sendToInbox(s.inboxPath, envelope("reply", "answer 1", { replyTo: ask1!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(r1, "ok");
    assert.equal((await p1).content[0].text, "answer 1");
    assert.equal(await pendingState(p2), "pending", "ask 2 is unaffected by ask 1's reply");

    const r2 = await sendToInbox(s.inboxPath, envelope("reply", "answer 2", { replyTo: ask2!.id, from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(r2, "ok");
    assert.equal((await p2).content[0].text, "answer 2");
  } finally {
    fx.restore();
  }
});

test("a timed-out ask names its id in the error", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    const result = await ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 20 });
    const sent = fx.lastLogFor("peer-a", "ask");
    assert.match(result.content[0].text, /no reply/);
    assert.ok(result.content[0].text.includes(sent!.id), "the timeout error names the ask id");
  } finally {
    fx.restore();
  }
});

test("a reply arriving after its ask timed out is still surfaced, never dropped", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    await ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 20 });
    const sent = fx.lastLogFor("peer-a", "ask");

    const resp = await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      s.delivered.some((d) => d.text.includes("late answer") && d.text.includes(sent!.id)),
      "a late reply is delivered as a message, naming the ask it answered",
    );
  } finally {
    fx.restore();
  }
});

test("cycle refusal: an inbound ask from a session we're already asking is refused on the wire and not shown; others are ok", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    const p1 = ask.execute("c1", { to: "peer-a", question: "outbound q" }); // holds an edge to peer-a
    // pendingOutbound.set runs strictly before the send that produces this
    // log entry (see its comment in kido-agents.ts), so waiting for the
    // entry is a safe way to know the edge is already registered.
    await fx.waitForLog("peer-a", "ask");

    const refused = await sendToInbox(s.inboxPath, envelope("ask", "are you free?", { id: "inbound-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(refused, "refused");
    assert.ok(!s.delivered.some((d) => d.text.includes("are you free?")), "a refused ask is not shown to the model");

    const ok = await sendToInbox(s.inboxPath, envelope("ask", "another question", { id: "inbound-2", from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(ok, "ok");
    assert.ok(s.delivered.some((d) => d.text.includes("another question")), "an ask from anyone else is shown");

    // Release the edge so p1 does not dangle past the test.
    const sent = fx.lastLogFor("peer-a", "ask");
    await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent!.id, from: { session: "peer-a" } }));
    await p1;
  } finally {
    fx.restore();
  }
});

test("the cycle edge is released by a correlated reply or a timeout, but not by an uncorrelated reply", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
    const sent1 = await fx.waitForLog("peer-a", "ask");
    await sendToInbox(s.inboxPath, envelope("reply", "not it", { replyTo: "wrong-id", from: { session: "peer-a" } }));
    assert.equal(
      await sendToInbox(s.inboxPath, envelope("ask", "still holding?", { id: "in-1", from: { session: "peer-a" } })),
      "refused",
      "an uncorrelated reply does not release the edge",
    );

    await sendToInbox(s.inboxPath, envelope("reply", "here", { replyTo: sent1!.id, from: { session: "peer-a" } }));
    await p1;
    assert.equal(
      await sendToInbox(s.inboxPath, envelope("ask", "free now?", { id: "in-2", from: { session: "peer-a" } })),
      "ok",
      "a correlated reply releases the edge",
    );

    const p2 = ask.execute("c2", { to: "peer-a", question: "q2", timeoutMs: 20 });
    await p2;
    assert.equal(
      await sendToInbox(s.inboxPath, envelope("ask", "free again?", { id: "in-3", from: { session: "peer-a" } })),
      "ok",
      "a timeout releases the edge",
    );
  } finally {
    fx.restore();
  }
});

// A pi session with no title falls back to its session id as the reply
// address (labelFrom); a /reload changes that id while leaving the
// sender's pane and instance untouched. message_agent must re-resolve
// the reply against the sender's current session, found by pane, not
// the stale one the model was told about when the ask arrived.
test("a reply to an unnamed asker still reaches it after the asker reloads and its session id changes", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-old", name: "", pane: "%42", parent: "", self: false, canMessage: true },
    ]);
    const s = await startSession(fx);

    const resp = await sendToInbox(
      s.inboxPath,
      envelope("ask", "still there?", { id: "ask-reload-1", from: { session: "peer-a-old", pane: "%42" } }),
    );
    assert.equal(resp, "ok");
    const asked = s.delivered.find((d) => d.text.includes("is asking"));
    assert.ok(asked, "the ask was delivered to the model");
    assert.match(asked!.text, /message_agent\(to="peer-a-old"/, "an unnamed asker's fallback label is its session id");

    // The asker reloads: same pane and agent, a new session id, before
    // this session gets around to replying.
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-new", name: "", pane: "%42", parent: "", self: false, canMessage: true },
    ]);

    // The model does exactly what it was told: replies to the now-stale
    // "peer-a-old" label.
    const reply = await s.tools.get("message_agent").execute("c1", { to: "peer-a-old", message: "still here", replyTo: "ask-reload-1" });
    assert.doesNotMatch(reply.content[0].text, /could not message/, "the reply must not fail just because the asker reloaded");

    const sent = fx.lastLogFor("peer-a-new");
    assert.ok(sent, "the reply was actually addressed to the asker's current session, not its stale one");
    assert.equal(fx.lastLogFor("peer-a-old"), undefined, "the stale session id was never dialled");
  } finally {
    fx.restore();
  }
});

// message_agent's own returned text is the strongest of the three places
// the stop-after instruction is repeated - the last thing the model reads
// before deciding whether to keep talking - so it must carry it, but only
// when replyTo genuinely answers an ask this session has pending; a
// reply to a notice, or a stale/unknown id, is not that and must not gain
// an instruction that makes no sense attached to it.
test("message_agent's result says to stop after replying to a pending ask, but not after any other send", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", pane: "%2", parent: "", self: false, canMessage: true },
    ]);
    const s = await startSession(fx);

    // pane set: handleInboundAsk only remembers a pending ask when the
    // envelope carries one (pendingInboundAsks is keyed by pane).
    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-z", from: { session: "peer-a", name: "peer-a", pane: "%2" } }));
    const toAsk = await s.tools.get("message_agent").execute("c1", { to: "peer-a", message: "yes", replyTo: "ask-z" });
    assert.match(toAsk.content[0].text, /entire response|whole response/i, "a reply to a pending ask carries the stop-after instruction");

    const plain = await s.tools.get("message_agent").execute("c2", { to: "peer-a", message: "unprompted" });
    assert.doesNotMatch(plain.content[0].text, /entire response|whole response/i, "an unprompted message carries no such instruction");

    const staleReplyTo = await s.tools.get("message_agent").execute("c3", { to: "peer-a", message: "late", replyTo: "no-such-ask" });
    assert.doesNotMatch(
      staleReplyTo.content[0].text,
      /entire response|whole response/i,
      "a replyTo naming no ask this session has pending carries no such instruction either",
    );
  } finally {
    fx.restore();
  }
});

test("abandonPending: session_shutdown and a failed rebind settle a waiting ask promptly; a successful rebind stays answerable", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a

    // session_shutdown: nothing is coming back, so the wait must not run
    // out its own (5-minute default) timeout.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      await s.emit("session_shutdown");
      const out = await settlesWithin(p, 500);
      // Which message comes back depends on whether ask_agent had already
      // registered its waiter (fetchAgents is async - see the `!inbox`
      // check in kido-status.ts) by the time
      // session_shutdown ran: either abandonPending caught an
      // already-registered waiter, or the check turned away a
      // registration that had not happened yet. Both are "gave up because
      // of shutdown", never "will try again later".
      assert.match(out.content[0].text, /inbox closed|inbox is unavailable/);
      assert.doesNotMatch(out.content[0].text, /will still arrive/, "must not promise a reply that can no longer land");
    }

    // A /reload whose rebind fails abandons the same way.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      fx.setInboxFail(true);
      await s.emit("session_start", {}, fakeCtx());
      const out = await settlesWithin(p, 500);
      assert.match(out.content[0].text, /inbox closed|inbox is unavailable/);
      fx.setInboxFail(false);
    }

    // A plain reload whose rebind succeeds must not abandon anything: the
    // waiter survives and a reply on the rebound (same-path) inbox still
    // resolves it.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      const sent = await fx.waitForLog("peer-a", "ask");
      await s.emit("session_start", {}, fakeCtx());
      const resp = await sendToInbox(s.inboxPath, envelope("reply", "still here", { replyTo: sent!.id, from: { session: "peer-a" } }));
      assert.equal(resp, "ok");
      const out = await settlesWithin(p, 500);
      assert.equal(out.content[0].text, "still here");
    }
  } finally {
    fx.restore();
  }
});

// parseEnvelope mirrors internal/msg.Parse: the same v0/v1 discriminator
// rule implemented twice, once in Go and once here. A disagreement
// between the two is how a user's prompt gets silently swallowed as a
// control message (or the reverse: a real envelope treated as raw text).
// Driven from internal/msg/testdata/discriminator.json, the fixture
// internal/msg's own discriminator table test drives, so the two suites
// cannot drift apart by someone editing only one list.
test("parseEnvelope agrees with internal/msg.Parse's v0/v1 discriminator table", () => {
  const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "..", "internal", "msg", "testdata", "discriminator.json");
  const cases: { name: string; raw: string; ok: boolean }[] = JSON.parse(readFileSync(fixturePath, "utf8"));
  assert.ok(cases.length >= 11, `expected at least 11 cases in the shared fixture, got ${cases.length}`);
  for (const c of cases) {
    const got = parseEnvelope(c.raw) !== null;
    assert.equal(got, c.ok, `${c.name}: parseEnvelope(${JSON.stringify(c.raw)}) ok = ${got}, want ${c.ok}`);
  }
});

// A model answering an ask correctly calls message_agent - that part
// already worked - and then went on to write a user-facing summary of
// what it had just done, in the same turn. That trailing narration
// reaches nobody: the asker already has its answer, and no user is
// waiting on a report in this session. The delivered text must say the
// message_agent call IS the whole response, not merely how to make it.
test("an inbound ask's delivered text says the message_agent reply is the whole response, with no summary after it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-y", from: { session: "peer-a", name: "peer-a" } }));
    const delivered = s.delivered.find((d) => d.text.includes("is asking"))?.text ?? "";
    assert.match(delivered, /message_agent/, "names the tool that actually reaches the asker");
    assert.match(delivered, /entire response|whole response/i, "says the reply call is the whole response, not just how to send it");
    assert.match(delivered, /no summary|sign-off/i, "says plainly not to follow the reply with narration");
    assert.match(delivered, /self-contained/i, "still tells the model the asker cannot see this session's context");
  } finally {
    fx.restore();
  }
});

test("kind dispatch: message, ask, reply, notice, an unrecognised kind, and v0 raw text all reach the model", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, "plain v0 text");
    assert.ok(s.delivered.some((d) => d.text === "plain v0 text"), "v0 raw text is delivered unchanged");

    await sendToInbox(s.inboxPath, envelope("message", "hello", { from }));
    assert.ok(s.delivered.some((d) => d.text === "hello"), "kind message delivers its text as-is");

    await sendToInbox(s.inboxPath, envelope("notice", "build finished", { from }));
    assert.ok(
      s.messages.some((m) => m.message.customType === "kido-notice" && m.message.content === "build finished" && m.message.details?.from === "peer-a"),
      "kind notice reaches the model as a custom message, named by its sender, full text intact",
    );

    const askResp = await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-x", from }));
    assert.equal(askResp, "ok");
    assert.ok(s.delivered.some((d) => d.text.includes("peer-a is asking") && d.text.includes("you there?")));

    await sendToInbox(s.inboxPath, envelope("reply", "an answer", { replyTo: "no-such-ask", from }));
    assert.ok(s.delivered.some((d) => d.text.includes("replied") && d.text.includes("an answer")));

    await sendToInbox(s.inboxPath, envelope("ping", "unknown kind text", { from }));
    assert.ok(s.delivered.some((d) => d.text.includes("unrecognised message kind") && d.text.includes("unknown kind text")));
  } finally {
    fx.restore();
  }
});

// Part 4 of the notify_parent refactor (docs/design.md, "Notifying the
// parent"): an inbound notice renders collapsed by default and expands
// under pi's own ctrl-o toggle (options.expanded), which this extension
// never binds itself - see kido-agents.ts's registerMessageRenderer call.
test("an inbound notice renders collapsed by default, naming the sender, and expands to the full text", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("notice", "the whole result, in full", { from }));
    const sent = s.messages.find((m) => m.message.customType === "kido-notice");
    assert.ok(sent, "a notice was sent as a custom message");
    assert.equal(sent!.message.content, "the whole result, in full", "the model-visible content is the notice's full text");

    const renderer = s.renderers.get("kido-notice");
    assert.ok(renderer, "the agent half registered a renderer for its own custom type");

    const collapsed = renderer!(sent!.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(collapsed, /notification from peer-a.*ctrl-o to expand/, "the collapsed line names the sender and hints at expansion");
    assert.ok(!collapsed.includes("the whole result, in full"), "the collapsed line does not leak the full text");

    const expanded = renderer!(sent!.message, { expanded: true, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.ok(expanded.includes("the whole result, in full"), "expanding shows the full content");
  } finally {
    fx.restore();
  }
});

test("a notice from a nameless sender still renders sanely, collapsed and expanded", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // No name and no session: what a human running `kido message --kind
    // notice` from a bare pane looks like on the wire (labelFrom's own
    // fallback order: name, session, pane, "another agent").
    await sendToInbox(s.inboxPath, envelope("notice", "from a human", { from: { session: "", pane: "%12" } as any }));
    const sent = s.messages.find((m) => m.message.customType === "kido-notice");
    assert.equal(sent!.message.details.from, "%12", "the pane stands in for a name when there is none");

    const renderer = s.renderers.get("kido-notice")!;
    const collapsed = renderer(sent!.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(collapsed, /notification from %12/, "a nameless sender still gets a sane, non-empty label");
  } finally {
    fx.restore();
  }
});

// Part 3 of the notify_parent refactor: a spawned child must be told
// reporting is its own job now that nothing does it automatically. Fires
// on every prompt, not just the child's first, since a task delivered
// once via deliverTask is the wrong lifetime for a standing rule (a
// parent's later message_agent call produces a follow-up turn with no
// other memory of it).
test("a subagent's system prompt carries the notify_parent instruction; a root session's does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
      const override = results.find((r: any) => r?.systemPrompt) as { systemPrompt: string } | undefined;
      assert.ok(override, "a subagent's before_agent_start hook returns a replacement system prompt");
      assert.ok(override!.systemPrompt.startsWith("base prompt"), "the base prompt is preserved, not replaced");
      assert.match(override!.systemPrompt, /notify_parent/, "the instruction names the tool the model must call");
      assert.match(
        override!.systemPrompt,
        /entire response|whole response/i,
        "also carries the stop-after-replying instruction, at system-prompt level where it can compete with the host's own",
      );
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }

  const rootFx = makeFixture();
  try {
    rootFx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(rootFx); // root session: no KIDO_AGENT_PARENT_INSTANCE
    const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
    assert.ok(results.every((r) => r === undefined), "a root session's system prompt is left alone");
  } finally {
    rootFx.restore();
  }
});

test("interrupt_subagent runs kido interrupt with the target, and stop_subagent runs kido stop, passing --force through", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);

    const interruptRes = await s.tools.get("interrupt_subagent").execute("c1", { to: "peer-a" });
    assert.match(interruptRes.content[0].text, /interrupted peer-a/);
    assert.deepEqual(fx.lastControlArgs(), ["interrupt", "--", "peer-a"]);

    const stopRes = await s.tools.get("stop_subagent").execute("c2", { to: "peer-b" });
    assert.match(stopRes.content[0].text, /stopped peer-b/);
    assert.deepEqual(fx.lastControlArgs(), ["stop", "--", "peer-b"]);

    await s.tools.get("stop_subagent").execute("c3", { to: "peer-b", force: true });
    assert.deepEqual(fx.lastControlArgs(), ["stop", "--force", "--", "peer-b"]);
  } finally {
    fx.restore();
  }
});

// argAfter reads the value following a flag in an argv-shaped array, the
// same way the args a fake kido logged are read back apart.
function argAfter(args: string[] | undefined, flag: string): string | undefined {
  if (!args) return undefined;
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

test("spawn_subagent passes its task as text on stdin and calls kido spawn with its own identity and depth+1, without waiting for the child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // send()'s agent-status report is fire-and-forget (a detached, unref'd
    // subprocess), so there is nothing to await here but the file it
    // eventually writes.
    await pollUntil(() => fx.lastStatusArgs() !== undefined);
    const ownInstance = argAfter(fx.lastStatusArgs(), "--instance");
    assert.ok(ownInstance, "session_start reported its own --instance");

    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
    assert.match(result.content[0].text, /kid-1/);
    assert.equal(result.details.run, "fake-run-id", "the run id kido spawn printed is returned so the model can refer to it later");

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido spawn was invoked");
    assert.equal(argAfter(spawnArgs, "--parent-pid"), String(process.pid), "passes its own pid as --parent-pid");
    assert.equal(argAfter(spawnArgs, "--parent-instance"), ownInstance, "passes its own --instance as --parent-instance");
    assert.equal(argAfter(spawnArgs, "--depth"), "1", "a root agent (no KIDO_AGENT_DEPTH) spawns at depth+1 = 1");
    assert.equal(argAfter(spawnArgs, "--name"), "kid-1");
    assert.equal(argAfter(spawnArgs, "--task-file"), "-", "the task is passed as text on stdin, not as a file this tool manages");
    assert.equal(fx.lastSpawnTask(), "go do the thing", "the task's own text goes on stdin, not on the command line");

    const sepIndex = spawnArgs!.indexOf("--");
    assert.ok(sepIndex >= 0, "the child command follows --");
    assert.deepEqual(spawnArgs!.slice(sepIndex + 1), ["pi", "--name", "kid-1"]);
  } finally {
    fx.restore();
  }
});

test("spawn_subagent passes --model and --tools through to the child's pi invocation, and generates a safe name when omitted", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { task: "t", model: "anthropic/sonnet", tools: ["read", "bash"] });

    const spawnArgs = fx.lastSpawnArgs()!;
    const command = spawnArgs.slice(spawnArgs.indexOf("--") + 1);
    assert.equal(command[0], "pi");
    assert.equal(argAfter(command, "--model"), "anthropic/sonnet");
    assert.equal(argAfter(command, "--tools"), "read,bash", "--tools is the capability ceiling handed to the child, comma-joined");

    const name = argAfter(spawnArgs, "--name");
    assert.ok(name, "a name was generated");
    assert.doesNotMatch(name!, /['"$#`\n\r]/, "a generated name avoids the characters tmux's own parsing cannot survive");
    assert.match(result.content[0].text, new RegExp(name!.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  } finally {
    fx.restore();
  }
});

test("spawn_subagent is refused at the depth ceiling without writing a task file or calling kido", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_DEPTH;
    process.env.KIDO_AGENT_DEPTH = "2"; // already a subagent at the ceiling; +1 would be 3
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "t" });
      assert.match(result.content[0].text, /maximum subagent nesting depth/);
      assert.equal(fx.lastSpawnArgs(), undefined, "kido spawn must not be invoked for a refused depth");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_DEPTH;
      else process.env.KIDO_AGENT_DEPTH = saved;
    }
  } finally {
    fx.restore();
  }
});

// A timeout is reported as a timeout, not folded into a generic failure:
// kido may already have done its work, and a caller that treats the two
// alike can end up cleaning up after something that succeeded.
test("spawn_subagent reports a kido spawn timeout as a timeout, not a generic failure", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const savedTimeout = process.env.KIDO_SPAWN_TIMEOUT_MS;
    process.env.KIDO_SPAWN_TIMEOUT_MS = "300";
    process.env.KIDO_FAKE_SPAWN_DELAY_MS = "2000"; // longer than the timeout: an in-flight, not a failed, spawn
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
      assert.match(result.content[0].text, /timed out/);
      assert.ok(fx.lastSpawnArgs(), "kido spawn was invoked before the timeout fired");
    } finally {
      delete process.env.KIDO_FAKE_SPAWN_DELAY_MS;
      if (savedTimeout === undefined) delete process.env.KIDO_SPAWN_TIMEOUT_MS;
      else process.env.KIDO_SPAWN_TIMEOUT_MS = savedTimeout;
    }
  } finally {
    fx.restore();
  }
});

test("a child started with KIDO_AGENT_TASK_FILE delivers its task as the first message, keeps the file, and marks it delivered", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "task.txt");
    writeFileSync(taskFile, "do the important thing");

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      assert.ok(
        s.delivered.some((d) => d.text === "do the important thing"),
        "the task reached the model as a user message, the same way an inbox prompt is delivered",
      );
      // Kept, not unlinked: the task file is the run's own permanent
      // record, read back later by `kido runs <run-id>`. A sibling marker,
      // not the file's absence, is what stops a later /reload from
      // delivering it again.
      assert.equal(existsSync(taskFile), true, "the task file survives delivery");
      assert.equal(existsSync(join(dirname(taskFile), "delivered")), true, "a delivered marker is written");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

test("a /reload does not deliver an already-delivered task a second time", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "reload-task.txt");
    writeFileSync(taskFile, "do the important thing");

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      assert.equal(s.delivered.filter((d) => d.text === "do the important thing").length, 1);

      // A /reload re-runs session_start with a fresh ctx, but not the
      // factory: the delivered marker, not the module's own state, is what
      // must stop a second delivery.
      await s.emit("session_start", {}, fakeCtx());
      assert.equal(
        s.delivered.filter((d) => d.text === "do the important thing").length,
        1,
        "the task must not be delivered again once its marker exists",
      );
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

// An unreadable task file must leave no delivered marker, so a later
// /reload gets another try rather than never showing the task at all.
test("an unreadable KIDO_AGENT_TASK_FILE delivers nothing, breaks nothing, and leaves nothing behind", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "unreadable-task.txt");
    writeFileSync(taskFile, "a task nobody can read");
    chmodSync(taskFile, 0o000);

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing is delivered from a file that could not be read");
      assert.equal(existsSync(join(dirname(taskFile), "delivered")), false, "no marker is written for a read that failed, so a later /reload gets another try");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
      if (existsSync(taskFile)) chmodSync(taskFile, 0o600);
    }
  } finally {
    fx.restore();
  }
});

test("a missing KIDO_AGENT_TASK_FILE does not break session_start", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = join(fx.inboxDir, "..", "no-such-task.txt");
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing spurious is delivered when the task file is absent");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

// Part 1 of the notify_parent refactor (docs/design.md, "Notifying the
// parent"): a settled turn and a plain shutdown must no longer tell the
// parent anything on their own. A subagent that wants that now calls
// notify_parent itself - see its own tests below.
test("a settled turn sends no automatic notice, and neither does a plain shutdown", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await new Promise((r) => setTimeout(r, 200));
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "a settle must send no notice on its own");
      await s.emit("session_shutdown");
      await new Promise((r) => setTimeout(r, 200));
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "a plain shutdown must send no notice either");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }
});

// Part 2: notify_parent is the only way a subagent tells its parent
// anything now; unlike the automatic notices it replaced, it is sent via
// runKido and awaited, since a deliberate tool call has no reason to race
// this process's own exit the way session_shutdown's notice used to.
test("notify_parent sends a notice to the resolved parent, carrying the given summary", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const tool = s.tools.get("notify_parent");
      const result = await tool.execute("call-1", { summary: "the answer is 42" });
      assert.ok(result.content[0].text.length > 0, "the tool reports what happened");
      const sent = await fx.waitForLog("parent-x", "notice");
      assert.equal(sent!.text, "the answer is 42", "the notice carries the summary verbatim");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }
});

test("notify_parent from a session with no parent refuses clearly, and sends nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx); // root session: no KIDO_AGENT_PARENT_INSTANCE
    const tool = s.tools.get("notify_parent");
    const result = await tool.execute("call-1", { summary: "nobody to tell" });
    assert.match(result.content[0].text, /no parent/i, "the refusal names the reason rather than reading as a silent no-op");
    assert.equal(jsonLines(fx.logFile).length, 0, "nothing was sent");
  } finally {
    fx.restore();
  }
});

test("session_shutdown schedules the window linger helper for a subagent", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);

    const saved = { INST: process.env.KIDO_AGENT_PARENT_INSTANCE, LINGER: process.env.KIDO_LINGER_SECONDS };
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    process.env.KIDO_LINGER_SECONDS = "0.05"; // sleep(1) accepts fractional seconds on macOS and Linux
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      await s.emit("session_shutdown");
      const args = await fx.waitForCloseWindow();
      assert.deepEqual(args, ["close-window", "@7"], "the linger helper closes this session's own window");
    } finally {
      if (saved.INST === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved.INST;
      if (saved.LINGER === undefined) delete process.env.KIDO_LINGER_SECONDS;
      else process.env.KIDO_LINGER_SECONDS = saved.LINGER;
    }
  } finally {
    fx.restore();
  }
});

test("session_shutdown records this run's own outcome as completed when it ends idle, or failed otherwise", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx, "run-completed");
      await s.emit("session_shutdown");
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", "run-completed"]);
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }

  const fx2 = makeFixture();
  try {
    fx2.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx2, "run-failed");
      await s.emit("ui_prompt_start"); // leaves current = "waiting", not idle
      await s.emit("session_shutdown");
      assert.deepEqual(fx2.lastRunOutcomeArgs(), ["run-outcome", "--result", "failed", "--", "run-failed"]);
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx2.restore();
  }
});

// pi fires session_shutdown on /reload too (reason "reload"), with the
// session carrying straight on in the same process - so an outcome
// written there reports a live run as finished, and since RecordOutcome
// is O_EXCL the run's real ending can never be recorded afterwards.
// Measured against a real pi 0.85.1 subagent: a /reload left the run
// reading "completed" while it was still in kido agents, and a later
// kido stop was silently discarded.
test("a session_shutdown that is a reload or a session replacement records no outcome", async () => {
  for (const reason of ["reload", "new", "resume", "fork"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
      const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
      process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
      try {
        const factory = await freshExtensions();
        const s = await startSessionUsing(factory, fx, `run-${reason}`);
        await s.emit("session_shutdown", { type: "session_shutdown", reason });
        assert.equal(fx.lastRunOutcomeArgs(), undefined, `a "${reason}" shutdown does not end the run`);
      } finally {
        if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
        else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
      }
    } finally {
      fx.restore();
    }
  }

  // The negative control: an explicit "quit" still records, so the guard
  // above cannot pass by never recording anything at all.
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx, "run-quit");
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", "run-quit"]);
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }
});

// The parent-side fix for the same incident the child-side debounce
// above guards against: session_shutdown used to remove this session's
// own record unconditionally, including on a reload, which is what left
// a gap for a child's poll to land in. Measured against a real pi 0.85.1
// session_start/session_shutdown pair: a /reload delivers reason "reload"
// and keeps the same session id (session_start's own
// ctx.sessionManager.getSessionId() call returns it unchanged), while
// "new", "resume" and "fork" each hand back a different one in the same
// process - so those three must still remove the old record, or it is a
// live-pid file that nothing ever cleans up, claiming this pane alongside
// the fresh one under the new id.
test("session_shutdown removes the record for every reason except a reload", async () => {
  for (const reason of ["new", "resume", "fork", "quit", undefined]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
      const s = await startSession(fx, `sess-${reason}`);
      await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
      await s.emit("session_shutdown", reason === undefined ? undefined : { type: "session_shutdown", reason });
      await pollUntil(() => fx.statusReportsWithRemove().length >= 1, 2000, `a "${reason}" shutdown to report --remove`);
    } finally {
      fx.restore();
    }
  }

  // The case under test: a reload must not remove the record at all.
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, "sess-reload");
    await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
    await s.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });
    // No event to wait on for a negative outcome - the reload branch
    // returns before ever calling send(), so there is no spawnDetached
    // call in flight to race against. The grace period is only margin
    // against a regression that makes the call asynchronously instead.
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(fx.statusReportsWithRemove().length, 0, "a reload must never report --remove");
  } finally {
    fx.restore();
  }
});

test("session_shutdown never records an outcome for a root session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, "root-session");
    await s.emit("session_shutdown");
    assert.equal(fx.lastRunOutcomeArgs(), undefined, "a root session has no run record to write into");
  } finally {
    fx.restore();
  }
});

// The same reason/reload gate that keeps recordOwnOutcome from
// recording a live run as finished must also keep scheduleCompletionLinger
// from scheduling the child's own window to be closed out from under it
// ~30s later. Measured against a real pi 0.85.1 subagent: typing /reload
// in a live subagent left its window closed, plus an orphaned
// `sh -c sleep ...` helper in `ps` on top of the one the real ending
// later spawns.
test("a reload shutdown schedules no linger; a quit does", async () => {
  const reload = makeFixture();
  try {
    reload.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@9" }]);
    const saved = { INST: process.env.KIDO_AGENT_PARENT_INSTANCE, LINGER: process.env.KIDO_LINGER_SECONDS };
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    process.env.KIDO_LINGER_SECONDS = "0.05";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, reload);
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });
      const closeWindowLog = await reload
        .waitForCloseWindow(50)
        .then(() => "called")
        .catch(() => "not called");
      assert.equal(closeWindowLog, "not called", "a reload must not schedule this session's own window to close");
    } finally {
      if (saved.INST === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved.INST;
      if (saved.LINGER === undefined) delete process.env.KIDO_LINGER_SECONDS;
      else process.env.KIDO_LINGER_SECONDS = saved.LINGER;
    }
  } finally {
    reload.restore();
  }

  // Negative control: an actual quit still schedules the linger, so the
  // assertion above cannot pass by disabling it outright.
  const quit = makeFixture();
  try {
    quit.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@9" }]);
    const saved = { INST: process.env.KIDO_AGENT_PARENT_INSTANCE, LINGER: process.env.KIDO_LINGER_SECONDS };
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    process.env.KIDO_LINGER_SECONDS = "0.05";
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, quit);
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      const args = await quit.waitForCloseWindow();
      assert.deepEqual(args, ["close-window", "@9"], "a quit still schedules this session's own window to close");
    } finally {
      if (saved.INST === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved.INST;
      if (saved.LINGER === undefined) delete process.env.KIDO_LINGER_SECONDS;
      else process.env.KIDO_LINGER_SECONDS = saved.LINGER;
    }
  } finally {
    quit.restore();
  }
});

// A root session (no KIDO_AGENT_PARENT_INSTANCE) must never get its own
// window auto-closed: PARENT_INSTANCE undefined is what sendCompletionNotice
// already reads as "not a subagent", and the linger is scheduled from
// inside that same early return.
test("session_shutdown never schedules a window linger for a root session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@7" }]);
    process.env.KIDO_LINGER_SECONDS = "0.05";
    try {
      const s = await startSession(fx);
      await s.emit("session_shutdown");
      const closeWindowLog = await fx
        .waitForCloseWindow(50)
        .then(() => "called")
        .catch(() => "not called");
      assert.equal(closeWindowLog, "not called", "a root session's window must never be scheduled for close");
    } finally {
      delete process.env.KIDO_LINGER_SECONDS;
    }
  } finally {
    fx.restore();
  }
});

test("interleaving: an inbound ask from the same target is refused even while the outbound send to it is still in flight", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a
    fx.setMessageFailTo(undefined);
    process.env.KIDO_FAKE_MESSAGE_DELAY_MS = "800";
    try {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");

      // ask_agent's own kido message send is held for 800ms by the fake
      // kido below - this only races at all because runKido shells out via
      // spawn rather than execFileSync; the old blocking call could never
      // let an inbound connection be dispatched before the send finished.
      const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
      // A fixed wait, not a poll on the agents-lookup subprocess's own log
      // write: that write happens near the start of the child's short
      // life, well before the parent's spawn 'close' event fires at the
      // end of it, so watching for it is not a reliable proxy for
      // "fetchAgents() has resolved in this process". 120ms comfortably
      // covers one undelayed subprocess round trip (tens of ms, measured)
      // while staying well short of the 800ms the outbound send itself is
      // held up for below.
      await new Promise((r) => setTimeout(r, 120));

      // The load-bearing half of this test. "Refused" alone is true
      // whether or not the send is still running: the waiter is not
      // dropped until a reply or a timeout, so a runKido that blocked the
      // event loop for the whole 800ms would finish the send first and
      // still refuse afterwards - verified by making runKido
      // execFileSync-based again, at which point everything below this
      // line still passed. The fake kido appends its log entry in the same
      // breath as its reply, so an absent entry here is the only available
      // evidence that the send really had not finished yet.
      const inFlight = fx.lastLogFor("peer-a", "ask") === undefined;
      const refused = await sendToInbox(s.inboxPath, envelope("ask", "sneaky", { id: "race-1", from: { session: "peer-a" } }));
      assert.ok(inFlight, "the outbound send must still be in flight when the inbound ask is dispatched, or this pins nothing");
      assert.equal(refused, "refused", "the cycle edge is registered before the send resolves, not after");

      const sent = await fx.waitForLog("peer-a", "ask");
      await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent.id, from: { session: "peer-a" } }));
      const outcome = await p1;
      assert.equal(outcome.content[0].text, "done");
    } finally {
      delete process.env.KIDO_FAKE_MESSAGE_DELAY_MS;
    }
  } finally {
    fx.restore();
  }
});

// deadPid starts and waits for a trivial child process, returning its pid:
// guaranteed to belong to no process by the time the caller uses it. The
// same trick internal/state/state_test.go uses on the Go side.
function deadPid(): number {
  const r = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  return r.pid!;
}

// withParentEnv sets KIDO_AGENT_PARENT_PID/INSTANCE and a short poll
// interval, restoring whatever was there before on the way out - the
// extensions read all three once at module scope, so every case below
// goes through freshExtensions() to pick them up.
async function withParentEnv<T>(pid: number, instance: string, pollMs: number, fn: () => Promise<T>): Promise<T> {
  const saved = {
    KIDO_AGENT_PARENT_PID: process.env.KIDO_AGENT_PARENT_PID,
    KIDO_AGENT_PARENT_INSTANCE: process.env.KIDO_AGENT_PARENT_INSTANCE,
    KIDO_PARENT_POLL_MS: process.env.KIDO_PARENT_POLL_MS,
  };
  process.env.KIDO_AGENT_PARENT_PID = String(pid);
  process.env.KIDO_AGENT_PARENT_INSTANCE = instance;
  process.env.KIDO_PARENT_POLL_MS = String(pollMs);
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// startWithShutdownSpy is startSessionUsing but with a ctx.shutdown() the
// test can observe - fakeCtx has no such spy, since no other test needs
// one.
async function startWithShutdownSpy(factory: (pi: unknown) => void) {
  const { pi, tools, delivered, emit } = createFakePi();
  let shutdowns = 0;
  const ctx = { ...fakeCtx(), shutdown: () => { shutdowns++; } };
  factory(pi);
  await emit("session_start", {}, ctx);
  return { tools, delivered, emit, shutdowns: () => shutdowns };
}

test("parent-liveness poll: shuts the session down when the parent's process is gone", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(deadPid(), "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a dead parent pid");
      await s.emit("session_shutdown"); // stop the poll, as a real shutdown would
    });
  } finally {
    fx.restore();
  }
});

test("parent-liveness poll: does not shut down while the parent is alive and its instance still matches", async () => {
  const fx = makeFixture();
  try {
    // list_agents' own parent field is non-empty: some live record in
    // scope still reports parent-inst as its own Instance.
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      // Long enough for several poll ticks at 20ms; still short by test
      // standards, and this is what proves the poll ran and chose not to
      // shut down, not merely that it hadn't fired yet.
      await new Promise((r) => setTimeout(r, 150));
      assert.equal(s.shutdowns(), 0, "a live, correctly-matched parent must never trigger a shutdown");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// The regression test for the actual incident: a subagent spawned with
// keepAlive died the moment its parent ran /reload. The parent's record
// disappearing and reappearing (what session_shutdown's remove-then-
// session_start's re-report looked like before the parent-side fix, and
// what missedParentPolls's debounce keeps absorbing even if some future
// change reopens a gap like it) must never end the child on its own - a
// single missed poll is not evidence, exactly like an unreachable kido
// already is not evidence just above it.
test("parent-liveness poll: a single missed poll for the parent's record does not shut the child down (the /reload regression)", async () => {
  const fx = makeFixture();
  try {
    const alive = [{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }];
    const gone = [{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }];
    fx.setAgents(alive);
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => fx.agentsCallCount() >= 1, 2000, "the first liveness poll");
      const before = fx.agentsCallCount();
      fx.setAgents(gone);
      // Exactly one poll observes the gap, then it closes - a bounded
      // window, not a wall-clock guess, so this cannot flake by racing an
      // extra poll into the gone window.
      await pollUntil(() => fx.agentsCallCount() >= before + 1, 2000, "one poll to observe the missing parent record");
      fx.setAgents(alive);
      await pollUntil(() => fx.agentsCallCount() >= before + 4, 2000, "several more polls once the record reappears");
      assert.equal(s.shutdowns(), 0, "a single missed poll must never end the session on its own");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

test("parent-liveness poll: a recycled pid with a different instance counts as gone", async () => {
  const fx = makeFixture();
  try {
    // kill(pid, 0) succeeds - this process's own pid is certainly alive -
    // but no record in scope resolves this session's parent edge, exactly
    // as if the real parent exited and something else now holds its old
    // pid. state.Alive (internal/state) reports EPERM as alive for the
    // same reason pid alone is not proof here (see AGENTS.md). Every poll
    // sees the same empty record, so missedParentPolls's debounce (see the
    // test above) reaches its threshold and this still ends the session -
    // the debounce delays a genuine death by a couple of polls, it does
    // not defeat it.
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a recycled pid with no matching instance");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// withHeartbeatEnv sets KIDO_HEARTBEAT_MS, restoring whatever was there
// before - kido-status.ts reads it once at module scope, so a case using
// it goes through freshExtensions() to pick it up (see withParentEnv).
async function withHeartbeatEnv<T>(ms: number, fn: () => Promise<T>): Promise<T> {
  const saved = process.env.KIDO_HEARTBEAT_MS;
  process.env.KIDO_HEARTBEAT_MS = String(ms);
  try {
    return await fn();
  } finally {
    if (saved === undefined) delete process.env.KIDO_HEARTBEAT_MS;
    else process.env.KIDO_HEARTBEAT_MS = saved;
  }
}

test("a running session re-sends its status on a heartbeat, bypassing the coalescing key that would otherwise drop a repeat", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    await withHeartbeatEnv(20, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      // turn_start, tool_execution_start and tool_call all send the same
      // "running" key: without the heartbeat bypass this is exactly the
      // sequence send()'s coalescing collapses to a single report.
      await s.emit("turn_start");
      await s.emit("tool_execution_start");
      await s.emit("tool_call");
      await pollUntil(() => fx.statusReportsWith("running").length >= 1, 2000, "the first running report");
      assert.equal(fx.statusReportsWith("running").length, 1, "coalescing must still drop the identical follow-ups");

      await pollUntil(() => fx.statusReportsWith("running").length >= 2, 2000, "a heartbeat re-report past KIDO_HEARTBEAT_MS");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

test("the heartbeat stops once the session is no longer running", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    await withHeartbeatEnv(15, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      await s.emit("turn_start");
      // Wait for the heartbeat to have actually fired at least once, not
      // merely the first (turn_start's own) report - otherwise stopping it
      // immediately would prove nothing.
      await pollUntil(() => fx.statusReportsWith("running").length >= 2, 2000, "a heartbeat re-report");
      await s.emit("agent_settled", {}, { isIdle: () => true }); // the true idle signal; see the handler in kido-status.ts
      // Each spawnDetached call already made before the stop still lands in
      // the log asynchronously, so the count can grow briefly after this
      // point regardless; what must not happen is it growing forever. Two
      // readings several intervals apart, equal to each other, is that
      // proof without racing the exact moment the last in-flight spawn
      // lands.
      await new Promise((r) => setTimeout(r, 200));
      const a = fx.statusReportsWith("running").length;
      await new Promise((r) => setTimeout(r, 200));
      const b = fx.statusReportsWith("running").length;
      assert.equal(b, a, "the running report count must stabilise once the session went idle, not keep growing");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// startWithControlSpies is startSession but with ctx.abort()/ctx.shutdown()
// spies the tests below observe - what an inbound "interrupt"/"stop"
// envelope (handleInboundControl) actually calls.
async function startWithControlSpies(fx: Fixture) {
  const { pi, tools, delivered, emit } = createFakePi();
  let aborts = 0;
  let shutdowns = 0;
  const ctx = { ...fakeCtx(), abort: () => { aborts++; }, shutdown: () => { shutdowns++; } };
  loadExtensions(pi);
  await emit("session_start", {}, ctx);
  return { tools, delivered, emit, inboxPath: fx.selfInboxPath(), aborts: () => aborts, shutdowns: () => shutdowns };
}

// controlTree is a self whose parent is "root-1", the shape
// handleInboundControl's ancestor check needs: isAncestor walks self's own
// parent chain looking for the envelope's sender.
const controlTree = [
  { id: "self", name: "self", parent: "root-1", pane: "%1", self: true, canMessage: true },
  { id: "root-1", name: "root-1", parent: "", pane: "%2", self: false, canMessage: true },
  { id: "peer-x", name: "peer-x", parent: "", pane: "%3", self: false, canMessage: true },
];

// TestIsAncestorRefusesSelfEdge's TS twin: without the explicit refusal
// at the top of isAncestor, a record whose own "parent" named itself
// would make isAncestor(agents, X, X) true, and handleInboundControl's
// ancestor check would let a session act on a "stop" or "interrupt" that
// claimed to be from itself. Nothing writes such a record today (see the
// function's own doc); this pins the belt-and-braces refusal anyway.
test("isAncestor refuses a self-edge, even with a corrupted self-parent record", () => {
  const self = { id: "x", name: "x", parent: "x", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self], self, self), false);
});

// isAncestor's `seen` set is what stands between a corrupted parent chain
// and a hang: internal/tree's own cycle safety (AGENTS.md) has a Go twin,
// but nothing here pinned the TS walk directly. Without `seen`, a genuine
// cycle among records none of which is self would loop forever instead of
// eventually returning false.
test("isAncestor terminates on a parent cycle that never reaches self", () => {
  const a = { id: "a", name: "a", parent: "b", pane: "%1", self: false, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const b = { id: "b", name: "b", parent: "a", pane: "%2", self: false, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%3", self: true, canMessage: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, a, b], self, a), false);
  assert.equal(isAncestor([self, a, b], self, b), false);
});

// A dangling parent id - one that names no agent in the list at all, the
// shape a race between a spawn and an exit can leave behind - must end
// the walk rather than loop on `cur` never changing.
test("isAncestor terminates when a parent names nobody in the list", () => {
  const orphan = { id: "orphan", name: "orphan", parent: "ghost-parent", pane: "%1", self: false, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%2", self: true, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, orphan], self, orphan), false);
});

// isAncestor must also find self two levels up, not merely the immediate
// parent - the shape a grandparent's `kido interrupt grandchild` relies
// on.
test("isAncestor finds a two-level ancestor", () => {
  const grand = { id: "grand", name: "grand", parent: "", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const mid = { id: "mid", name: "mid", parent: "grand", pane: "%2", self: false, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  const child = { id: "child", name: "child", parent: "mid", pane: "%3", self: false, canMessage: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([grand, mid, child], grand, child), true);
});

test("an interrupt envelope from an ancestor calls ctx.abort() and does not shut the session down", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1, "ctx.abort() must be called exactly once");
    assert.equal(s.shutdowns(), 0, "an interrupt must never shut the session down");
  } finally {
    fx.restore();
  }
});

test("a stop envelope from an ancestor shuts the session down", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const resp = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.shutdowns(), 1, "ctx.shutdown() must be called exactly once");
    assert.equal(s.aborts(), 0, "a stop must not also abort");
  } finally {
    fx.restore();
  }
});

test("interrupt and stop are both refused, and neither abort nor shutdown is called, when the sender is not an ancestor", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const interruptResp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "peer-x", name: "peer-x" } }));
    assert.equal(interruptResp, "refused");

    const stopResp = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "peer-x", name: "peer-x" } }));
    assert.equal(stopResp, "refused");

    assert.equal(s.aborts(), 0);
    assert.equal(s.shutdowns(), 0);
  } finally {
    fx.restore();
  }
});

// A control envelope naming a session id that is not in kido's agents
// list at all - not a peer, not a descendant, just unknown - must be
// refused the same way a peer is. isAncestor's `byId.get(cur)?.parent`
// already tolerates a missing sender, but handleInboundControl's own
// `listed.agents.find((a) => a.id === env.from.session)` lookup is a
// second, independent place this could be gotten wrong: nothing stops a
// forged envelope from naming an id that never existed.
test("interrupt and stop are refused when the sender's id matches no agent kido knows about", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "no-such-id", name: "ghost" } }));
    assert.equal(resp, "refused");
    assert.equal(s.aborts(), 0);
  } finally {
    fx.restore();
  }
});

// An interrupt leaves the session alive and able to take a following
// message, which is more than "shutdown was not
// called" - the inbox itself must still be answering. And an interrupt of
// an idle agent (the shape here: session_start with no turn begun) must
// be harmless, not refused or treated specially just because there was
// nothing to abort.
test("an interrupt of an idle agent is harmless, and the session still answers a following message", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1);
    assert.equal(s.shutdowns(), 0);

    const followUp = await sendToInbox(s.inboxPath, envelope("message", "still there?", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(followUp, "ok");
    assert.ok(s.delivered.some((d) => d.text === "still there?"), "the session must still accept a message after an interrupt");
  } finally {
    fx.restore();
  }
});

// A person running `kido interrupt`/`kido stop` by hand has no state
// record, so kido has no session id to put in the envelope's `from` - and
// the scope rule deliberately lets that caller reach anything
// (cmd/kido/control.go's isAgent check). Matching only on `from.session`
// would refuse them here, so the two enforcement layers would disagree
// and a human's stop could not stop anything. Recognised by the
// empty session *and* a pane no agent occupies, so an agent that simply
// omits its session id is still held to the descendant rule.
test("a control envelope from a human at the CLI is honoured; one merely missing a session id is not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const human = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "", name: "", pane: "%99" } }));
    assert.equal(human, "ok", "a human at the CLI may interrupt anything");
    assert.equal(s.aborts(), 1);

    const impostor = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "", name: "", pane: "%3" } }));
    assert.equal(impostor, "refused", "a pane an agent occupies is an agent, whatever `from` says");
    assert.equal(s.shutdowns(), 0);
  } finally {
    fx.restore();
  }
});

// askTree is grand -> mid -> child, three levels, used below to pin
// ask_agent's ancestor guard in both directions: which of self/target is
// the caller decides which one gets marked self:true per case.
const askTree = [
  { id: "grand", name: "grand", parent: "", self: false, canMessage: true },
  { id: "mid", name: "mid", parent: "grand", self: false, canMessage: true },
  { id: "child", name: "child", parent: "mid", self: false, canMessage: true },
];

// isAncestor(agents, self, target) means "self is an ancestor of target"
// (see its own doc above); ask_agent's guard must refuse a child asking
// upward, not a parent asking downward. The inverted check refused the
// ordinary case and let the dangerous one through - a subagent could
// block its own parent for the full ask timeout, exactly the deadlock
// docs/design.md's cycle-edge section exists to prevent - so each case
// below checks not just the refusal text but that nothing was actually
// sent (or was), off the fake kido's own log.
test("ask_agent allows a parent asking its own child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "mid" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "child", question: "status?", timeoutMs: 50 });
    assert.doesNotMatch(result.content[0].text, /ancestor/, "a parent asking its own child must not be refused as an ancestor violation");
    assert.ok(await fx.waitForLog("child", "ask"), "the ask was actually sent to the child");
  } finally {
    fx.restore();
  }
});

test("ask_agent refuses a child asking its parent", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "child" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "mid", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /ancestor/, "a child asking its parent must be refused");
    assert.equal(fx.lastLogFor("mid", "ask"), undefined, "nothing must actually be sent to the parent");
  } finally {
    fx.restore();
  }
});

test("ask_agent refuses a child asking its grandparent, two levels up", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "child" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "grand", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /ancestor/, "a child asking its grandparent must be refused");
    assert.equal(fx.lastLogFor("grand", "ask"), undefined, "nothing must actually be sent to the grandparent");
  } finally {
    fx.restore();
  }
});

test("ask_agent still allows a peer asking a peer, unaffected by the ancestor guard", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a - unrelated parents
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "status?", timeoutMs: 50 });
    assert.doesNotMatch(result.content[0].text, /ancestor/);
    assert.ok(await fx.waitForLog("peer-a", "ask"), "the ask was actually sent to the peer");
  } finally {
    fx.restore();
  }
});

test("ask_agent still refuses asking yourself", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "mid" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "mid", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /cannot ask yourself/);
    assert.equal(fx.lastLogFor("mid", "ask"), undefined);
  } finally {
    fx.restore();
  }
});

test("ask_agent refuses a stalled target immediately, without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, stalled: true, sinceReport: 245 },
    ]);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const result = await settlesWithin(ask.execute("c1", { to: "peer-a", question: "q" }), 500);
    assert.match(result.content[0].text, /stalled/);
    assert.match(result.content[0].text, /245/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a stalled target must never actually be asked");
  } finally {
    fx.restore();
  }
});

// withIdleExitEnv sets KIDO_IDLE_EXIT_SECONDS and, optionally,
// KIDO_AGENT_KEEP_ALIVE, restoring whatever was there before - both are
// read once at module scope, so every case below goes through
// freshExtensions() to pick them up (see withParentEnv).
async function withIdleExitEnv<T>(seconds: number, keepAlive: boolean, fn: () => Promise<T>): Promise<T> {
  const saved = {
    KIDO_IDLE_EXIT_SECONDS: process.env.KIDO_IDLE_EXIT_SECONDS,
    KIDO_AGENT_KEEP_ALIVE: process.env.KIDO_AGENT_KEEP_ALIVE,
  };
  process.env.KIDO_IDLE_EXIT_SECONDS = String(seconds);
  if (keepAlive) process.env.KIDO_AGENT_KEEP_ALIVE = "1";
  else delete process.env.KIDO_AGENT_KEEP_ALIVE;
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("idle self-exit: a settled turn with no further work shuts the session down after the configured idle interval, measured", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.1, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        const t0 = Date.now();
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() after the idle interval");
        const elapsed = Date.now() - t0;
        assert.ok(elapsed >= 100, `shut down after ${elapsed}ms, want at least the configured 100ms idle interval`);
        assert.ok(elapsed < 1500, `shut down after ${elapsed}ms, want well under 1500ms - it must not wait on the heartbeat or the parent poll`);
      });
    });
  } finally {
    fx.restore();
  }
});

test("idle self-exit: new work resets the timer instead of letting it fire mid-turn", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.15, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true }); // arms the 150ms timer
        await new Promise((r) => setTimeout(r, 80)); // well under it
        await s.emit("turn_start"); // new work: must cancel the pending shutdown
        await new Promise((r) => setTimeout(r, 100)); // would have fired by 150ms from the settle, had it not reset
        assert.equal(s.shutdowns(), 0, "new work must cancel the pending idle self-exit");
        await s.emit("agent_settled", {}, { isIdle: () => true }); // the follow-up turn settles too
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once idle again after the follow-up");
      });
    });
  } finally {
    fx.restore();
  }
});

test("idle self-exit: a root session (no parent) never arms the timer", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    delete process.env.KIDO_AGENT_PARENT_INSTANCE;
    try {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300)); // several times the configured interval
        assert.equal(s.shutdowns(), 0, "a root session must never self-reap");
      });
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }
});

test("idle self-exit: keepAlive opts a child out entirely", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.05, true, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300));
        assert.equal(s.shutdowns(), 0, "keepAlive must prevent the idle timer from ever arming");
      });
    });
  } finally {
    fx.restore();
  }
});

test("idle self-exit: a focused window re-arms instead of shutting down, then exits once unfocused", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setWindowFocused(true);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        // Each re-arm check costs a fake-kido subprocess start (tens of ms),
        // so the wait has to be generous relative to the 50ms interval to
        // actually observe more than one of them.
        await new Promise((r) => setTimeout(r, 600));
        assert.equal(s.shutdowns(), 0, "a focused window must not be closed out from under the user");
        assert.ok(
          fx.windowFocusedCallCount() >= 2,
          `window-focused was checked ${fx.windowFocusedCallCount()} times, want re-arming to have checked more than once`,
        );

        fx.setWindowFocused(false);
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once the window is no longer focused");
      });
    });
  } finally {
    fx.restore();
  }
});

test("spawn_subagent passes --keep-alive through only when keepAlive is set", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");

    await spawn.execute("c1", { task: "a", name: "kid-a" });
    assert.ok(!fx.lastSpawnArgs()!.includes("--keep-alive"), "omitted keepAlive must not pass --keep-alive");

    await spawn.execute("c2", { task: "b", name: "kid-b", keepAlive: true });
    assert.ok(fx.lastSpawnArgs()!.includes("--keep-alive"), "keepAlive: true must pass --keep-alive");
  } finally {
    fx.restore();
  }
});
