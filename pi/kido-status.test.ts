// Regression suite for the reply correlation, timeout, cycle refusal and
// inbox teardown logic in kido-status.ts. It drives the extension only
// through what a real pi host and a real peer agent would use: the
// registered tools, the registered lifecycle events, and a real unix
// socket speaking the inbox wire protocol - never by reaching into the
// module's closures.
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
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter } from "node:path";
import net from "node:net";
import kidoStatus from "./kido-status.ts";

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
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    const respond = () => {
      process.stdout.write("@9 %9\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_SPAWN_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "close-window": {
    const logFile = process.env.KIDO_FAKE_CLOSE_WINDOW_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
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
  selfInboxPath(): string;
  lastLogFor(to: string, kind?: string): { id: string; replyTo: string; to: string; text: string; failed?: boolean } | undefined;
  lastSpawnArgs(): string[] | undefined;
  waitForCloseWindow(ms?: number): Promise<string[]>;
  lastStatusArgs(): string[] | undefined;
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
  writeFileSync(agentsFile, "[]");
  writeFileSync(logFile, "");
  writeFileSync(spawnLogFile, "");
  writeFileSync(closeWindowLogFile, "");
  writeFileSync(statusLogFile, "");

  const saved = {
    PATH: process.env.PATH,
    TMUX_PANE: process.env.TMUX_PANE,
    KIDO_FAKE_AGENTS_FILE: process.env.KIDO_FAKE_AGENTS_FILE,
    KIDO_FAKE_LOG: process.env.KIDO_FAKE_LOG,
    KIDO_FAKE_SPAWN_LOG: process.env.KIDO_FAKE_SPAWN_LOG,
    KIDO_FAKE_CLOSE_WINDOW_LOG: process.env.KIDO_FAKE_CLOSE_WINDOW_LOG,
    KIDO_FAKE_STATUS_LOG: process.env.KIDO_FAKE_STATUS_LOG,
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
    lastSpawnArgs() {
      return last(jsonLines(spawnLogFile));
    },
    async waitForCloseWindow(ms = 2000) {
      let found: string[] | undefined;
      await pollUntil(() => (found = last(jsonLines(closeWindowLogFile))) !== undefined, ms, "a kido close-window call");
      return found!;
    },
    lastStatusArgs() {
      return last(jsonLines(statusLogFile));
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
      // spawn_subagent's task file goes in the OS temp directory, not in
      // this fixture's own, because that is where a real subagent's does -
      // and the fake `kido spawn` above, unlike a real child, never reads
      // or unlinks it. Left alone, every run of this suite would add one
      // per spawn to the user's /tmp for good. Matched on this process's
      // own pid, which is what kido-status.ts puts in the name, so a
      // concurrently running suite's files are not touched.
      for (const f of readdirSync(tmpdir())) {
        if (f.startsWith(`kido-task-${process.pid}-`)) rmSync(join(tmpdir(), f), { force: true });
      }
    },
  };
}

// A fake pi host: enough of ExtensionAPI to register tools and lifecycle
// handlers and to record what the extension tried to say to the model.
function createFakePi() {
  const tools = new Map<string, any>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
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
  };
  async function emit(event: string, ...args: unknown[]) {
    for (const h of handlers.get(event) ?? []) await h(...args);
  }
  return { pi, tools, delivered, emit };
}

function fakeCtx(sessionId = "self-session") {
  return {
    sessionManager: { getSessionId: () => sessionId, getSessionName: () => undefined },
    model: undefined,
    isIdle: () => true,
  };
}

async function startSession(fx: Fixture, sessionId?: string) {
  const { pi, tools, delivered, emit } = createFakePi();
  (kidoStatus as (pi: unknown) => void)(pi);
  await emit("session_start", {}, fakeCtx(sessionId));
  return { tools, delivered, emit, inboxPath: fx.selfInboxPath() };
}

// startSessionUsing is startSession but for a factory that is not the
// module's static default export - needed by tests that must vary
// KIDO_AGENT_TASK_FILE or KIDO_AGENT_PARENT_INSTANCE, which kido-status.ts
// reads once, at module scope, when it is first imported. freshKidoStatus
// below reimports the module under a cache-busting specifier so those
// module-scope constants are recomputed from whatever the environment
// holds at that moment.
async function startSessionUsing(factory: (pi: unknown) => void, fx: Fixture, sessionId?: string) {
  const { pi, tools, delivered, emit } = createFakePi();
  factory(pi);
  await emit("session_start", {}, fakeCtx(sessionId));
  return { tools, delivered, emit, inboxPath: fx.selfInboxPath() };
}

let freshImportCounter = 0;
async function freshKidoStatus(): Promise<(pi: unknown) => void> {
  const mod = await import(`./kido-status.ts?fresh=${process.pid}-${freshImportCounter++}`);
  return mod.default as (pi: unknown) => void;
}

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

function envelope(kind: string, text: string, extra: { id?: string; replyTo?: string; from?: { session: string; name?: string } } = {}): string {
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
    // log entry (see its own comment in kido-status.ts), so waiting for the
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
    assert.ok(s.delivered.some((d) => d.text.includes("notice from peer-a") && d.text.includes("build finished")));

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

// argAfter reads the value following a flag in an argv-shaped array, the
// same way the args a fake kido logged are read back apart.
function argAfter(args: string[] | undefined, flag: string): string | undefined {
  if (!args) return undefined;
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

test("spawn_subagent writes a task file and calls kido spawn with its own identity and depth+1, without waiting for the child", async () => {
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

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido spawn was invoked");
    assert.equal(argAfter(spawnArgs, "--parent-pid"), String(process.pid), "passes its own pid as --parent-pid");
    assert.equal(argAfter(spawnArgs, "--parent-instance"), ownInstance, "passes its own --instance as --parent-instance");
    assert.equal(argAfter(spawnArgs, "--depth"), "1", "a root agent (no KIDO_AGENT_DEPTH) spawns at depth+1 = 1");
    assert.equal(argAfter(spawnArgs, "--name"), "kid-1");

    const taskFile = argAfter(spawnArgs, "--task-file");
    assert.ok(taskFile, "a task file path was passed");
    assert.equal(readFileSync(taskFile!, "utf8"), "go do the thing", "the task's own text goes in the file, not on the command line");

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
      const factory = await freshKidoStatus();
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

test("spawn_subagent does not unlink the task file when kido spawn merely times out", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const savedTimeout = process.env.KIDO_SPAWN_TIMEOUT_MS;
    process.env.KIDO_SPAWN_TIMEOUT_MS = "300";
    process.env.KIDO_FAKE_SPAWN_DELAY_MS = "2000"; // longer than the timeout: an in-flight, not a failed, spawn
    try {
      const factory = await freshKidoStatus();
      const s = await startSessionUsing(factory, fx);
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
      assert.match(result.content[0].text, /timed out/);

      const spawnArgs = fx.lastSpawnArgs();
      assert.ok(spawnArgs, "kido spawn was invoked before the timeout fired");
      const taskFile = argAfter(spawnArgs, "--task-file")!;
      assert.equal(
        existsSync(taskFile),
        true,
        "a spawn that only timed out may have actually succeeded, so its task file must not be deleted out from under a live child",
      );
    } finally {
      delete process.env.KIDO_FAKE_SPAWN_DELAY_MS;
      if (savedTimeout === undefined) delete process.env.KIDO_SPAWN_TIMEOUT_MS;
      else process.env.KIDO_SPAWN_TIMEOUT_MS = savedTimeout;
    }
  } finally {
    fx.restore();
  }
});

test("a child started with KIDO_AGENT_TASK_FILE delivers its task as the first message and unlinks the file", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "task.txt");
    writeFileSync(taskFile, "do the important thing");

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshKidoStatus();
      const s = await startSessionUsing(factory, fx);
      assert.ok(
        s.delivered.some((d) => d.text === "do the important thing"),
        "the task reached the model as a user message, the same way an inbox prompt is delivered",
      );
      assert.equal(existsSync(taskFile), false, "the task file is unlinked once delivered");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

// An unreadable task file is the one case that used to leak: the read
// threw, the unlink was never reached, and a file with the task's own text
// in it stayed in the temp directory for good, since session_start is its
// only reader and never runs against it twice.
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
      const factory = await freshKidoStatus();
      const s = await startSessionUsing(factory, fx);
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing is delivered from a file that could not be read");
      assert.equal(existsSync(taskFile), false, "the task file is unlinked even when the read failed");
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
      const factory = await freshKidoStatus();
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

test("a completion notice addressed to a dead parent is dropped without failing session_shutdown", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "dead-parent", self: true, canMessage: true }]);
    fx.setMessageFailTo("dead-parent");

    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshKidoStatus();
      const s = await startSessionUsing(factory, fx);
      await assert.doesNotReject(s.emit("session_shutdown"), "a dead parent must never make shutdown itself fail");
      const sent = fx.lastLogFor("dead-parent", "notice");
      assert.ok(sent, "a notice to the parent was attempted");
      assert.equal(sent!.failed, true, "the fake kido reports the same failure a dead parent's inbox would cause");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
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
      const factory = await freshKidoStatus();
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

test("a completion notice reaches a live parent", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);

    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    process.env.KIDO_AGENT_PARENT_INSTANCE = "parent-inst";
    try {
      const factory = await freshKidoStatus();
      const s = await startSessionUsing(factory, fx);
      await s.emit("session_shutdown");
      const sent = fx.lastLogFor("parent-x", "notice");
      assert.ok(sent, "a notice was sent to the resolved parent");
      assert.ok(sent!.text.length > 0, "the notice carries some result text");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
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
// interval, restoring whatever was there before on the way out -
// kido-status.ts reads all three once at module scope, so every case
// below goes through freshKidoStatus() to pick them up.
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
      const factory = await freshKidoStatus();
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
      const factory = await freshKidoStatus();
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

test("parent-liveness poll: a recycled pid with a different instance counts as gone", async () => {
  const fx = makeFixture();
  try {
    // kill(pid, 0) succeeds - this process's own pid is certainly alive -
    // but no record in scope resolves this session's parent edge, exactly
    // as if the real parent exited and something else now holds its old
    // pid. state.Alive (internal/state) reports EPERM as alive for the
    // same reason pid alone is not proof here (see AGENTS.md).
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshKidoStatus();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a recycled pid with no matching instance");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});
