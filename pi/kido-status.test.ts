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
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
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
  case "agent-status":
    process.exit(0);
  case "message": {
    let kind = "message", replyTo = "", id = "", to = null;
    for (let i = 1; i < args.length; i++) {
      if (args[i] === "--kind") kind = args[++i];
      else if (args[i] === "--reply-to") replyTo = args[++i];
      else if (args[i] === "--id") id = args[++i];
      else if (args[i] === "--") { to = args[i + 1]; break; }
    }
    const text = readStdin();
    const logFile = process.env.KIDO_FAKE_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify({ kind, replyTo, id, to, text }) + "\\n");
    process.stdout.write("delivered to " + to + " by inbox\\n");
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
  selfInboxPath(): string;
  lastLogFor(to: string, kind?: string): { id: string; replyTo: string; to: string; text: string } | undefined;
  restore(): void;
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
  writeFileSync(agentsFile, "[]");
  writeFileSync(logFile, "");

  const saved = {
    PATH: process.env.PATH,
    TMUX_PANE: process.env.TMUX_PANE,
    KIDO_FAKE_AGENTS_FILE: process.env.KIDO_FAKE_AGENTS_FILE,
    KIDO_FAKE_LOG: process.env.KIDO_FAKE_LOG,
    KIDO_FAKE_INBOX_DIR: process.env.KIDO_FAKE_INBOX_DIR,
    KIDO_FAKE_INBOX_FAIL: process.env.KIDO_FAKE_INBOX_FAIL,
  };
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMUX_PANE = "%1";
  process.env.KIDO_FAKE_AGENTS_FILE = agentsFile;
  process.env.KIDO_FAKE_LOG = logFile;
  process.env.KIDO_FAKE_INBOX_DIR = inboxDir;
  delete process.env.KIDO_FAKE_INBOX_FAIL;

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
    // Named after this test process's own pid, exactly as askInboxPath
    // does in kido-status.ts - the same reason a /reload rebinds at the
    // same path.
    selfInboxPath() {
      return join(inboxDir, String(process.pid) + ".sock");
    },
    lastLogFor(to, kind) {
      const lines = readFileSync(logFile, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((l) => JSON.parse(l));
      const matches = lines.filter((l) => l.to === to && (!kind || l.kind === kind));
      return matches[matches.length - 1];
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
    const ask1 = fx.lastLogFor("peer-a", "ask");
    assert.ok(ask1?.id, "ask 1 was sent with an id");

    const p2 = ask.execute("c2", { to: "peer-b", question: "q2" });
    const ask2 = fx.lastLogFor("peer-b", "ask");
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
    const sent1 = fx.lastLogFor("peer-a", "ask");
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
      assert.match(out.content[0].text, /inbox closed/);
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
      assert.match(out.content[0].text, /inbox closed/);
      fx.setInboxFail(false);
    }

    // A plain reload whose rebind succeeds must not abandon anything: the
    // waiter survives and a reply on the rebound (same-path) inbox still
    // resolves it.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      const sent = fx.lastLogFor("peer-a", "ask");
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
