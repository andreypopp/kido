import { test } from "node:test";

import assert from "node:assert/strict";

import {
  makeFixture,
  selfPane,
  agentPane,
  startNamedSession,
  asSubagent,
  withEnv,
  pollUntil,
  sendToInbox,
  envelope,
  customMessages,
  pendingState,
  settlesWithin,
  shellStatus,
  type Inbox,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

type Sent = { id: string; kind: string; text: string; from: { session: string; name?: string } };

function sent(inbox: Inbox): Sent {
  const payloads = inbox.received();
  return JSON.parse(payloads[payloads.length - 1]);
}

async function reply(fx: Fixture, inbox: Inbox, text: string, session = SELF): Promise<string> {
  const ask = sent(inbox);
  return sendToInbox(fx.inboxPath(session), envelope("reply", text, { replyTo: ask.id, from: ask.from }));
}

test("reply correlation: a foreign replyTo settles nothing and is surfaced; the right id settles only that ask", async () => {
  const fx = makeFixture();
  try {
    const a = await fx.startInbox();
    const b = await fx.startInbox();
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: a.path }),
      agentPane({ pane: "%3", session: "peer-b", name: "peer-b", inbox: b.path }),
    ]);
    const s = await startNamedSession(fx, "Self", SELF);
    const ask = s.tools.get("ask_agent");

    const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
    await pollUntil(() => a.received().length === 1, 2000, "ask 1");
    const p2 = ask.execute("c2", { to: "peer-b", question: "q2" });
    await pollUntil(() => b.received().length === 1, 2000, "ask 2");
    assert.notEqual(sent(a).id, sent(b).id, "each ask has its own id");

    assert.equal(await sendToInbox(s.inboxPath, envelope("reply", "stray answer", { replyTo: "nope", from: { session: "someone-else" } })), "ok");
    assert.ok(customMessages(s, "kido-reply").some((m) => m.message.content.includes("stray answer")), "an unmatched reply is surfaced to the model");
    assert.equal(await pendingState(p1), "pending");
    assert.equal(await pendingState(p2), "pending");

    assert.equal(await reply(fx, a, "answer 1"), "ok");
    assert.equal((await p1).content[0].text, "answer 1");
    assert.equal(await pendingState(p2), "pending", "ask 2 is unaffected by ask 1's reply");

    assert.equal(await reply(fx, b, "answer 2"), "ok");
    assert.equal((await p2).content[0].text, "answer 2");
  } finally {
    await fx.restore();
  }
});

test("a reply arriving after its ask timed out is still surfaced, never dropped", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);

    const timedOut = await s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "q", timeoutMs: 20 });
    const ask = sent(inbox);
    assert.match(timedOut.content[0].text, /no reply/);
    assert.ok(timedOut.content[0].text.includes(ask.id), "the timeout error names the ask id");

    assert.equal(await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: ask.id, from: { session: "peer-a", name: "peer-a" } })), "ok");
    const late = customMessages(s, "kido-reply");
    assert.equal(late.length, 1, "a late reply is delivered as a kido-reply custom message");
    assert.equal(late[0]!.message.content, `peer-a replied (to ask ${ask.id}): late answer`);
    assert.deepEqual(late[0]!.opts, { deliverAs: "followUp", triggerTurn: true }, "pi starts the reply's turn itself");
  } finally {
    await fx.restore();
  }
});

test("cycle refusal: an inbound ask from a session we're already asking is refused on the wire, and the edge is released by a reply or a timeout", async () => {
  const fx = makeFixture();
  try {
    const a = await fx.startInbox();
    const b = await fx.startInbox();
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: a.path }),
      agentPane({ pane: "%3", session: "peer-b", name: "peer-b", inbox: b.path }),
    ]);
    const s = await startNamedSession(fx, "Self", SELF);
    const p1 = s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "outbound q" });
    await pollUntil(() => a.received().length === 1, 2000, "the outbound ask");

    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "are you free?", { id: "in-1", from: { session: "peer-a", name: "peer-a" } })), "refused");
    assert.ok(!customMessages(s, "kido-ask").some((m) => m.message.content.includes("are you free?")), "a refused ask is not shown to the model");
    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "another question", { id: "in-2", from: { session: "peer-b", name: "peer-b" } })), "ok");
    assert.ok(customMessages(s, "kido-ask").some((m) => m.message.content.includes("another question")));

    await reply(fx, a, "done");
    await p1;
    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "free now?", { id: "in-3", from: { session: "peer-a", name: "peer-a" } })), "ok", "a correlated reply releases the edge");

    const p2 = s.tools.get("ask_agent").execute("c2", { to: "peer-a", question: "q2", timeoutMs: 20 });
    await p2;
    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "free again?", { id: "in-4", from: { session: "peer-a", name: "peer-a" } })), "ok", "a timeout releases the edge");
  } finally {
    await fx.restore();
  }
});

test("ask_agent allows a parent asking its child and a peer, and refuses a child asking an ancestor or itself", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.writeAgent("root", "mid", { session: "mid" });
    fx.writeAgent("mid", "child", { session: "child" });
    fx.writeAgent("child", "grand", { session: "grand" });
    fx.writeAgent("root", "peer", { session: "peer" });
    const panes = [
      agentPane({ pane: "%1", session: "root", name: "root", inbox: inbox.path }),
      agentPane({ pane: "%2", session: "mid", name: "mid", inbox: inbox.path }),
      agentPane({ pane: "%3", session: "child", name: "child", inbox: inbox.path }),
      agentPane({ pane: "%4", session: "grand", name: "grand", inbox: inbox.path }),
      agentPane({ pane: "%5", session: "peer", name: "peer", inbox: inbox.path }),
    ];
    fx.setPanes(panes);

    await asSubagent(fx, "mid", async () => {
      const s = await startNamedSession(fx, "mid", "mid");
      const ask = s.tools.get("ask_agent");
      const toChild = ask.execute("c1", { to: "child", question: "status?", timeoutMs: 50 });
      await pollUntil(() => inbox.received().length === 1, 2000, "the ask to the child");
      assert.equal(sent(inbox).kind, "ask");
      await reply(fx, inbox, "fine", "mid");
      assert.equal((await toChild).content[0].text, "fine", "a parent asking its own child is allowed");

      const toPeer = ask.execute("c2", { to: "peer", question: "status?", timeoutMs: 50 });
      await pollUntil(() => inbox.received().length === 2, 2000, "the ask to the peer");
      await reply(fx, inbox, "ok", "mid");
      await toPeer;

      assert.match((await ask.execute("c3", { to: "root", question: "q", timeoutMs: 50 })).content[0].text, /root is an ancestor/);
      assert.match((await ask.execute("c4", { to: "mid", question: "q", timeoutMs: 50 })).content[0].text, /cannot ask yourself/);
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});

test("a child asking its parent or grandparent is refused as an ancestor, and nothing is sent", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.writeAgent("root", "mid", { session: "mid" });
    fx.writeAgent("mid", "child", { session: "child" });
    fx.setPanes([
      agentPane({ pane: "%1", session: "mid", name: "mid", inbox: inbox.path }),
      agentPane({ pane: "%2", session: "child", name: "child", inbox: inbox.path }),
      agentPane({ pane: "%3", session: "root", name: "root", inbox: inbox.path }),
    ]);
    await asSubagent(fx, "child", async () => {
      const s = await startNamedSession(fx, "child", "child");
      assert.match((await s.tools.get("ask_agent").execute("c1", { to: "mid", question: "q", timeoutMs: 50 })).content[0].text, /mid is an ancestor/);
      assert.match((await s.tools.get("ask_agent").execute("c2", { to: "root", question: "q", timeoutMs: 50 })).content[0].text, /root is an ancestor/);
      assert.equal(inbox.received().length, 0, "nothing was sent");
    }, { parent: "mid", name: "child" });
  } finally {
    await fx.restore();
  }
});

test("ask_agent refuses a target with no inbox, without the message_agent tool, or with no live pane", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.writeAgent("root", "quiet", { session: "quiet", tools: ["read"] });
    fx.writeAgent("root", "mute", { session: "mute" });
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "quiet", name: "quiet", inbox: inbox.path }),
      agentPane({ pane: "%3", session: "mute", name: "mute" }),
    ]);
    const s = await startNamedSession(fx, "Self", SELF);
    const ask = s.tools.get("ask_agent");

    assert.equal((await ask.execute("c1", { to: "mute", question: "q", timeoutMs: 50 })).content[0].text, "mute has no inbox; an ask cannot work over a paste, there is no way back");
    assert.match((await ask.execute("c2", { to: "quiet", question: "q", timeoutMs: 50 })).content[0].text, /spawned without the message_agent tool/);
    fx.setPanes([selfPane()]);
    assert.equal(
      (await ask.execute("c3", { to: "quiet", question: "q", timeoutMs: 50 })).content[0].text,
      'could not ask quiet: no agent session matches "quiet"',
      "a target whose pane is gone is not waited for and is never sent to",
    );
    assert.equal(inbox.received().length, 0, "no refusal sent anything");
  } finally {
    await fx.restore();
  }
});

test("ask_agent releases its waiter when the target dies mid-wait, long before the timeout", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);
    const ask = s.tools.get("ask_agent");
    await withEnv({ KIDO_ASK_POLL_MS: "20" }, async () => {
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 });
      await pollUntil(() => inbox.received().length === 1, 2000, "the ask to go out");
      assert.equal(await pendingState(p), "pending", "a live target is still being waited for");

      fx.setPanes([selfPane(), { ...agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path }), pane_dead: "1", pane_program_status: shellStatus() }]);
      const result = await settlesWithin(p, 3000);
      assert.match(result.content[0].text, /stopped running before answering/);
      assert.ok(result.content[0].text.includes(sent(inbox).id), "the error names the ask id");
    });
  } finally {
    await fx.restore();
  }
});

// A failed tmux read is no evidence: only a successful read that shows the
// target absent settles the ask as stopped.
test("a failed tmux read does not settle a waiting ask as gone", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);
    await withEnv({ KIDO_ASK_POLL_MS: "20" }, async () => {
      const p = s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 });
      await pollUntil(() => inbox.received().length === 1, 2000, "the ask to go out");
      const before = fx.tmuxCalls().length;
      process.env.KIDO_FAKE_TMUX_FAIL = "1";
      try {
        await pollUntil(() => fx.tmuxCalls().length >= before + 2, 2000, "two failed liveness reads");
        assert.equal(await pendingState(p), "pending", "an unreadable pane is not a gone target");
      } finally {
        delete process.env.KIDO_FAKE_TMUX_FAIL;
      }
      const ask = sent(inbox);
      assert.equal(await sendToInbox(fx.inboxPath(SELF), envelope("reply", "still here", { replyTo: ask.id, from: ask.from })), "ok");
      assert.equal((await p).content[0].text, "still here");
    });
  } finally {
    await fx.restore();
  }
});

test("a waiting ask honours pi's abort signal", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);
    const ask = s.tools.get("ask_agent");

    const controller = new AbortController();
    const p = ask.execute("c1", { to: "peer-a", question: "q" }, controller.signal);
    await pollUntil(() => inbox.received().length === 1, 2000, "the ask to go out");
    controller.abort();
    const aborted = await settlesWithin(p, 500);
    assert.match(aborted.content[0].text, /interrupted \(ask id [0-9a-f]+\)/);
  } finally {
    await fx.restore();
  }
});

test("abandonPending: session_shutdown settles a waiting ask promptly; a successful rebind stays answerable", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);

    {
      const s = await startNamedSession(fx, "Self", SELF);
      const p = s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "q" });
      await pollUntil(() => inbox.received().length === 1, 2000, "the ask to go out");
      await s.emit("session_shutdown");
      const out = await settlesWithin(p, 500);
      assert.match(out.content[0].text, /inbox closed/);
    }

    {
      const s = await startNamedSession(fx, "Self", SELF);
      const p = s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "q" });
      await pollUntil(() => inbox.received().length === 2, 2000, "the second ask to go out");
      await s.emit("session_start", {}, {
        hasUI: true,
        sessionManager: { getSessionId: () => SELF, getSessionName: () => "Self", getSessionFile: () => "/tmp/self.json" },
        model: undefined,
        isIdle: () => true,
        hasPendingMessages: () => false,
        abort: () => {},
        shutdown: () => {},
        ui: s.ui,
      });
      assert.equal(await reply(fx, inbox, "still here"), "ok");
      const out = await settlesWithin(p, 1000);
      assert.equal(out.content[0].text, "still here");
    }
  } finally {
    await fx.restore();
  }
});

// The stop-after instruction belongs only when replyTo genuinely answers an ask
// this session has pending; a reply to a notice, or a stale id, must not gain it.
test("message_agent's result says to stop after replying to a pending ask, but not after any other send", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);

    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-z", from: { session: "peer-a", name: "peer-a", pane: "%2" } }));
    const toAsk = await s.tools.get("message_agent").execute("c1", { to: "peer-a", message: "yes", replyTo: "ask-z" });
    assert.match(toAsk.content[0].text, /entire response/);

    const plain = await s.tools.get("message_agent").execute("c2", { to: "peer-a", message: "unprompted" });
    assert.doesNotMatch(plain.content[0].text, /entire response/);

    const stale = await s.tools.get("message_agent").execute("c3", { to: "peer-a", message: "late", replyTo: "no-such-ask" });
    assert.doesNotMatch(stale.content[0].text, /entire response/);
  } finally {
    await fx.restore();
  }
});

test("interleaving: an inbound ask from the target is refused even while the outbound send to it is still in flight", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "peer-a", name: "peer-a", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);
    const release = inbox.hold();

    const p1 = s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "q1" });
    await pollUntil(() => inbox.received().length === 1, 2000, "the ask to be written");
    const refused = await sendToInbox(s.inboxPath, envelope("ask", "sneaky", { id: "race-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(refused, "refused", "the edge is held from before the send, not after it");

    release();
    const ask = sent(inbox);
    assert.equal(await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: ask.id, from: ask.from })), "ok");
    assert.equal((await p1).content[0].text, "done");
  } finally {
    await fx.restore();
  }
});

// A /reload changes a session's id while leaving its pane untouched; message_agent
// must re-resolve the reply against the sender's current session, found by pane,
// not the stale one the model was told about when the ask arrived.
test("a reply to an unnamed asker still reaches it after the asker reloads and its session id changes", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%42", session: "peer-a-old", inbox: inbox.path })]);
    const s = await startNamedSession(fx, "Self", SELF);

    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "still there?", { id: "ask-reload-1", from: { session: "peer-a-old", pane: "%42" } })), "ok");
    const asked = customMessages(s, "kido-ask")[0];
    assert.ok(asked, "the ask was delivered to the model");
    assert.match(asked!.message.content, /message_agent\(to="peer-a-old"/, "an unnamed asker's fallback label is its session id");

    fx.setPanes([selfPane(), agentPane({ pane: "%42", session: "peer-a-new", inbox: inbox.path })]);
    const replyResult = await s.tools.get("message_agent").execute("c1", { to: "peer-a-old", message: "still here", replyTo: "ask-reload-1" });
    assert.doesNotMatch(replyResult.content[0].text, /could not message/);
    const reply = sent(inbox);
    assert.equal(reply.kind, "reply");
    assert.equal(reply.text, "still here");
  } finally {
    await fx.restore();
  }
});
