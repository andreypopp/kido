import { test } from "node:test";

import type { Fixture } from "./kido-fixture.ts";

import assert from "node:assert/strict";

import { writeFileSync } from "node:fs";

import { isAncestor } from "./kido-agents.ts";

import { commandWork, fakeCtx, loadExtensions, makeFixture, startSessionCore, withEnv, startSession, freshExtensions, asSubagent, pollUntil, pollForStable, sendToInbox, envelope, customMessages, askSent, pendingState, settlesWithin, DEFAULT_SESSION, twoPeers } from "./kido-fixture.ts";

// TestIsAncestorRefusesSelfEdge's TS twin: a corrupted record whose "parent"
// names itself must not make isAncestor(agents, X, X) true.
test("isAncestor refuses a self-edge, even with a corrupted self-parent record", () => {
  const self = { id: "x", name: "x", parent: "x", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self], self, self), false);
});

// Without the `seen` set, a genuine cycle among records none of which is self
// would loop forever instead of returning false.
test("isAncestor terminates on a parent cycle that never reaches self", () => {
  const a = { id: "a", name: "a", parent: "b", pane: "%1", self: false, canMessage: true, canReply: true, window: "@1", stalled: false, sinceReport: 0 };
  const b = { id: "b", name: "b", parent: "a", pane: "%2", self: false, canMessage: true, canReply: true, window: "@2", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%3", self: true, canMessage: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, a, b], self, a), false);
  assert.equal(isAncestor([self, a, b], self, b), false);
});

// A dangling parent id (a race between a spawn and an exit can leave one) must
// end the walk rather than loop on `cur` never changing.
test("isAncestor terminates when a parent names nobody in the list", () => {
  const orphan = { id: "orphan", name: "orphan", parent: "ghost-parent", pane: "%1", self: false, canMessage: true, canReply: true, window: "@1", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%2", self: true, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, orphan], self, orphan), false);
});

test("isAncestor finds a two-level ancestor", () => {
  const grand = { id: "grand", name: "grand", parent: "", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const mid = { id: "mid", name: "mid", parent: "grand", pane: "%2", self: false, canMessage: true, canReply: true, window: "@2", stalled: false, sinceReport: 0 };
  const child = { id: "child", name: "child", parent: "mid", pane: "%3", self: false, canMessage: true, canReply: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([grand, mid, child], grand, child), true);
});

test("an interrupt envelope from an ancestor aborts, and a stop envelope shuts down, each exactly once", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const interrupt = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(interrupt, "ok");
    assert.equal(s.aborts(), 1, "ctx.abort() must be called exactly once");
    assert.equal(s.shutdowns(), 0, "an interrupt must never shut the session down");

    const stop = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(stop, "ok");
    assert.equal(s.shutdowns(), 1, "ctx.shutdown() must be called exactly once");
    assert.equal(s.aborts(), 1, "a stop must not also abort");
  } finally {
    await fx.restore();
  }
});

// An id not in kido's agents list at all - not a peer, not a descendant, just
// unknown - must be refused the same way a peer is.
test("interrupt and stop are refused, with neither abort nor shutdown, for a peer or an unknown sender", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    for (const from of [{ session: "peer-x", name: "peer-x" }, { session: "no-such-id", name: "ghost" }]) {
      assert.equal(await sendToInbox(s.inboxPath, envelope("interrupt", "", { from })), "refused");
      assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from })), "refused");
    }

    assert.equal(s.aborts(), 0);
    assert.equal(s.shutdowns(), 0);
  } finally {
    await fx.restore();
  }
});

// The bug this pins: an unawaited ctxAbort?.() let the interrupt's inbox reply -
// and any envelope handled after it - race pi's own abort still settling. A
// message sent right after an interrupt (kido tool interrupt_subagent then
// message_agent) would land while pi still thought it was streaming, routing it
// into pi's low-level followUp queue instead of the run-starting path, which
// nothing ever drained. Pre-fix, this failed on the second assertion: the reply
// came back in a handful of ms while ctx.abort() was
// still 150ms from settling.
test("an interrupt does not answer until ctx.abort() settles, so a message sent right after is not orphaned", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithDelayedAbort(fx, 150);

    const before = Date.now();
    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    const answeredAt = Date.now();
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1);
    assert.ok(
      answeredAt - before >= 150,
      `the interrupt reply must not arrive before ctx.abort() settles (answered after ${answeredAt - before}ms)`,
    );
    assert.ok(
      s.abortSettledAt() > 0 && s.abortSettledAt() <= answeredAt,
      "ctx.abort() must have already settled by the time the reply is sent",
    );

    const msgResp = await sendToInbox(s.inboxPath, envelope("message", "still there?", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(msgResp, "ok");
    assert.ok(
      customMessages(s, "kido-message").some((m) => m.message.content.endsWith("\nstill there?")),
      "the message sent right after the interrupt must reach pi.sendMessage",
    );
  } finally {
    await fx.restore();
  }
});

// Negative control: an already-idle abort() settles at once, so the fix must
// not have added a fixed wait of its own.
test("an interrupt to an idle session still answers promptly", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithDelayedAbort(fx, 0);

    const before = Date.now();
    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1);
    assert.ok(Date.now() - before < 150, `an interrupt to an idle session must not be held up (answered after ${Date.now() - before}ms)`);
  } finally {
    await fx.restore();
  }
});

// A human running `kido tool interrupt_subagent` by hand has no session id for `from`;
// recognised by the empty session *and* a pane no agent occupies, so an agent
// that simply omits its session id is still held to the descendant rule.
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
    await fx.restore();
  }
});

// Worth pinning: a model-authored `to` beginning with a dash would otherwise be
// read as a kido flag.
test("steer_subagent runs kido tool steer_subagent with the target behind -- and the message on stdin", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const res = await s.tools.get("steer_subagent").execute("c1", { to: "peer-a", message: "drop that, do X" });
    assert.match(res.content[0].text, /peer-a/);
    const sent = await fx.waitForLog("peer-a", "steer");
    assert.deepEqual(sent.args, ["tool", "steer_subagent", "--", "peer-a"], "the target follows --, so a leading dash is not read as a flag");
    assert.equal(sent.text, "drop that, do X", "the message goes on stdin, verbatim");
  } finally {
    await fx.restore();
  }
});

// Asserts the mode, not merely that something arrived: a steer delivered as
// followUp would wait for the agent to decide to stop, exactly what steering
// exists to skip. Negative control: an ask must stay followUp - it carries a
// reply-correlation id, so two interleaved asks risk an answer reaching the wrong asker.
test("an inbound steer is delivered as steer; a message and an ask stay followUp", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx, () => false);
    const from = { session: "root-1", name: "root-1", pane: "%2" };

    assert.equal(await sendToInbox(s.inboxPath, envelope("steer", "drop that, do X", { from })), "ok");
    const steered = s.delivered.find((d) => d.text.includes("drop that, do X"));
    assert.ok(steered, "the steer reached the model");
    assert.equal((steered!.opts as any).deliverAs, "steer", "a steer joins the running turn rather than queueing behind it");
    assert.match(steered!.text, /root-1/, "and says who is redirecting the work, arriving mid-task as it does");

    assert.equal(await sendToInbox(s.inboxPath, envelope("message", "when you get a moment", { from })), "ok");
    const queued = customMessages(s, "kido-message")[0];
    assert.ok(queued, "the message reached the model");
    assert.equal((queued!.opts as any).deliverAs, "followUp", "a message still waits for the current turn to end");

    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "are you done?", { from })), "ok");
    const asked = askSent(s, "are you done?");
    assert.ok(asked, "the ask reached the model");
    assert.equal((asked!.opts as any).deliverAs, "followUp", "an ask must never steer: a correlated reply has to be answered one at a time");
  } finally {
    await fx.restore();
  }
});

test("an inbound steer from a non-ancestor is refused and delivers nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const resp = await sendToInbox(s.inboxPath, envelope("steer", "do my bidding", { from: { session: "peer-x", name: "peer-x", pane: "%3" } }));
    assert.equal(resp, "refused");
    assert.equal(s.delivered.filter((d) => d.text.includes("do my bidding")).length, 0, "and nothing reached the model");
  } finally {
    await fx.restore();
  }
});

test("ask_agent allows a parent, a peer and a self-peer, and refuses a child, a grandchild and yourself", async () => {
  const fx = makeFixture();
  try {
    const midSelf = askTree.map((a) => (a.id === "mid" ? { ...a, self: true } : a));
    const childSelf = askTree.map((a) => (a.id === "child" ? { ...a, self: true } : a));
    const cases = [
      { agents: midSelf, sessionId: "mid", to: "child", case: "a parent asking its own child", allowed: true },
      { agents: childSelf, sessionId: "child", to: "mid", case: "a child asking its parent", allowed: false },
      { agents: childSelf, sessionId: "child", to: "grand", case: "a child asking its grandparent, two levels up", allowed: false },
      { agents: twoPeers.slice(0, 2), sessionId: DEFAULT_SESSION, to: "peer-a", case: "a peer asking a peer, unaffected by the ancestor guard", allowed: true },
      { agents: midSelf, sessionId: "mid", to: "mid", case: "asking yourself", allowed: false, pattern: /cannot ask yourself/ },
    ];
    for (const c of cases) {
      fx.setAgents(c.agents);
      const s = await startSession(fx, { sessionId: c.sessionId });
      const result = await s.tools.get("ask_agent").execute("c1", { to: c.to, question: "status?", timeoutMs: 50 });
      if (c.allowed) {
        assert.doesNotMatch(result.content[0].text, /ancestor/, `${c.case} must not be refused as an ancestor violation`);
        assert.ok(await fx.waitForLog(c.to, "ask"), `${c.case}: the ask was actually sent`);
      } else {
        assert.match(result.content[0].text, c.pattern ?? /ancestor/, `${c.case} must be refused`);
        assert.equal(fx.lastLogFor(c.to, "ask"), undefined, `${c.case}: nothing must actually be sent`);
      }
      await s.emit("session_shutdown", { reason: "new" });
    }
  } finally {
    await fx.restore();
  }
});

test("ask_agent refuses a stalled target immediately, without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true, stalled: true, sinceReport: 245 },
    ]);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const result = await settlesWithin(ask.execute("c1", { to: "peer-a", question: "q" }), 500);
    assert.match(result.content[0].text, /245s while reporting working; likely stalled, refusing to wait for a reply/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a stalled target must never actually be asked");
  } finally {
    await fx.restore();
  }
});

// The assertion with teeth: timeoutMs 600000 against settlesWithin(..., 500) -
// a version missing the liveness check would still answer correctly, only 600000ms later.
test("ask_agent refuses a target that is not alive, promptly and without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    fx.setParentAlive("gone");
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const result = await settlesWithin(ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }), 500);
    assert.match(result.content[0].text, /no longer running/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a dead target must never actually be asked");
    assert.ok(
      fx.parentAliveCalls().some((args) => args.includes("peer-a")),
      "the resolved target's own session id was queried",
    );
  } finally {
    await fx.restore();
  }
});

// canReply is a run record's fact, not canMessage's: a target with an inbox but
// no message_agent tool has somewhere to send a reply, and still cannot send one.
test("ask_agent refuses a target without canReply and still sends to one with it", async () => {
  const fx = makeFixture();
  try {
    const self = { id: "self", name: "self", parent: "", self: true, canMessage: true };
    const target = (canReply: boolean) => ({ id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply });
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    fx.setAgents([self, target(false)]);
    const refused = await ask.execute("c1", { to: "peer-a", question: "status?", timeoutMs: 50 });
    assert.match(refused.content[0].text, /message_agent/);
    assert.match(refused.content[0].text, /notify_parent/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a target that cannot reply must never actually be asked");

    fx.setAgents([self, target(true)]);
    const sent = await ask.execute("c2", { to: "peer-a", question: "status?", timeoutMs: 50 });
    assert.doesNotMatch(sent.content[0].text, /message_agent tool/);
    assert.ok(await fx.waitForLog("peer-a", "ask"), "the ask was actually sent to a target that can reply");
  } finally {
    await fx.restore();
  }
});

// The three cases below are about one thing: an ask that will never be
// answered has to end anyway, and end *promptly*. Each asserts settling
// well inside a timeoutMs generous enough that reaching it would be the
// bug - the failure being fixed is not a wrong message, it is no
// resolution arriving at all.
test("ask_agent releases its waiter when the target dies mid-wait, long before the timeout", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const ask = s.tools.get("ask_agent");

      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 });
      // The target was alive at the precheck: the ask really went out.
      const sent = await fx.waitForLog("peer-a", "ask");
      assert.equal(await pendingState(p), "pending", "a live target is still being waited for");

      fx.killSession("peer-a");
      const result = await settlesWithin(p, 3000);
      assert.match(result.content[0].text, /stopped running before answering/);
      assert.ok(result.content[0].text.includes(sent!.id), "the error names the ask id");
    });
  } finally {
    await fx.restore();
  }
});

test("a waiting ask honours pi's abort signal, so the turn can be interrupted", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const ac = new AbortController();
    const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
    const sent = await fx.waitForLog("peer-a", "ask");
    assert.equal(await pendingState(p), "pending", "nothing has interrupted it yet");

    ac.abort();
    const result = await settlesWithin(p, 1000);
    assert.match(result.content[0].text, /interrupted/);

    const resp = await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      customMessages(s, "kido-reply").some((m) => m.message.content.includes("late answer")),
      "an abandoned ask leaves no waiter behind for a later reply to settle",
    );
  } finally {
    await fx.restore();
  }
});

// The one ordering where the wait is over before the liveness watch is armed:
// an interval started after its own settle is one nothing will ever clear.
test("an ask aborted while its send is in flight leaves no liveness watch running", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const gate = fx.logFile + ".gate";
    process.env.KIDO_FAKE_MESSAGE_GATE = gate;
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const ask = s.tools.get("ask_agent");

      const ac = new AbortController();
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
      await pollUntil(() => commandWork.size > 0, 2000, "the send's fake kido to start");
      ac.abort();
      writeFileSync(gate, "");
      // Not instant: execute cannot return before the send it is awaiting does,
      // capped at 5s by runKido's own timeoutMs, a real subprocess spawn.
      const result = await settlesWithin(p, 9000);
      assert.match(result.content[0].text, /interrupted/);

      const readings = () => fx.parentAliveCalls().filter((args) => args.includes("peer-a")).length;
      await pollForStable(readings, 400, 6000, "the liveness readings for an abandoned ask to stop");
    });
  } finally {
    delete process.env.KIDO_FAKE_MESSAGE_GATE;
    await fx.restore();
  }
});

// Negative control: giving up on a healthy target that is merely slow would be
// worse than the hang.
test("a live target that takes its time is still waited for, and its reply is what arrives", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const ask = s.tools.get("ask_agent");

      const ac = new AbortController();
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
      const sent = await fx.waitForLog("peer-a", "ask");

      const readings = () => fx.parentAliveCalls().filter((args) => args.includes("peer-a")).length;
      await pollUntil(() => readings() >= 3, 6000, "several liveness readings that came back alive");
      assert.equal(await pendingState(p), "pending", "a slow but live target must still be waited for");

      const resp = await sendToInbox(s.inboxPath, envelope("reply", "the slow answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
      assert.equal(resp, "ok");
      assert.equal((await settlesWithin(p, 2000)).content[0].text, "the slow answer");
    });
  } finally {
    await fx.restore();
  }
});

// A child that reported and then ended: kido derives "unreported" from the
// report file it wrote, so the child's own ending is not made to speak for it.
test("a child that reported records the same ending args; kido decides who speaks", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-spoke", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-spoke" });
      const res = await s.tools.get("notify_parent").execute("c1", { summary: "done: the tty fix landed" });
      assert.match(res.content[0].text, /delivered/, "the report itself has to have gone out");
      await s.emit("session_shutdown");
      assert.deepEqual(fx.lastRunOutcomeArgs(), [
        "run-outcome", "--result", "completed", "--", "run-spoke",
      ], "a child that reported gets the same ending args");
    });
  } finally {
    await fx.restore();
  }
});

async function startWithControlSpies(fx: Fixture, idle?: () => boolean) {
  let aborts = 0;
  let shutdowns = 0;
  const s = await startSessionCore(fx, loadExtensions, () => ({
    ...fakeCtx(undefined, undefined, idle),
    abort: () => { aborts++; },
    shutdown: () => { shutdowns++; },
  }));
  return { ...s, aborts: () => aborts, shutdowns: () => shutdowns };
}

const controlTree = [
  { id: "self", name: "self", parent: "root-1", pane: "%1", self: true, canMessage: true },
  { id: "root-1", name: "root-1", parent: "", pane: "%2", self: false, canMessage: true, canReply: true },
  { id: "peer-x", name: "peer-x", parent: "", pane: "%3", self: false, canMessage: true, canReply: true },
];

// ctx.abort() settles only after delayMs, the shape pi's own AgentSession.abort()
// takes while it waits out a live run (agent-session.js: `await this.waitForIdle()`).
async function startWithDelayedAbort(fx: Fixture, delayMs: number) {
  let aborts = 0;
  let abortSettledAt = 0;
  const s = await startSessionCore(fx, loadExtensions, () => ({
    ...fakeCtx(),
    abort: () =>
      new Promise<void>((resolve) => {
        setTimeout(() => {
          aborts++;
          abortSettledAt = Date.now();
          resolve();
        }, delayMs);
      }),
  }));
  return { ...s, aborts: () => aborts, abortSettledAt: () => abortSettledAt };
}

// grand -> mid -> child; which of self/target is the caller decides which one
// gets marked self:true per case below.
const askTree = [
  { id: "grand", name: "grand", parent: "", self: false, canMessage: true, canReply: true },
  { id: "mid", name: "mid", parent: "grand", self: false, canMessage: true, canReply: true },
  { id: "child", name: "child", parent: "mid", self: false, canMessage: true, canReply: true },
];

// withAskPollEnv sets the interval a waiting ask re-reads its target's
// liveness on. It is read once at module scope, so every case using it
// goes through freshExtensions() to pick it up (see withParentEnv).
async function withAskPollEnv<T>(pollMs: number, fn: () => Promise<T>): Promise<T> {
  return withEnv({ KIDO_ASK_POLL_MS: String(pollMs) }, fn);
}
