import { test } from "node:test";

import assert from "node:assert/strict";

import { copyFileSync, mkdtempSync, readFileSync, rmSync, existsSync, statSync } from "node:fs";

import { join, dirname } from "node:path";

import { fileURLToPath, pathToFileURL } from "node:url";

import { makeFixture, createFakePi, fakeCtx, startSession, loadExtensions, freshExtensions, pollUntil, sendToInbox, envelope, customMessages, askSent, pendingState, settlesWithin, twoPeers,  } from "./kido-fixture.ts";

// Negative control: the file that claimed the slot still registers everything
// when run again (what a /reload does) - a guard refusing every second factory
// call would pass the first half and leave a reloaded session with no tools.
test("a second copy of the extensions at another path registers nothing, and a reload of the first still does", async () => {
  const first = createFakePi();
  loadExtensions(first.pi);
  assert.ok(first.tools.size > 0 && first.handlers.size > 0, "the extensions registered nothing at all");

  const here = dirname(fileURLToPath(import.meta.url));
  const dir = mkdtempSync(join(here, ".copy-"));
  try {
    for (const name of ["kido-status.ts", "kido-agents.ts"]) copyFileSync(join(here, name), join(dir, name));
    const status = await import(pathToFileURL(join(dir, "kido-status.ts")).href);
    const agents = await import(pathToFileURL(join(dir, "kido-agents.ts")).href);
    const copy = createFakePi();
    status.default(copy.pi);
    agents.default(copy.pi);
    assert.deepEqual([...copy.tools.keys()], [], "the copy registered tools");
    assert.deepEqual([...copy.handlers.keys()], [], "the copy registered handlers");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  const reloaded = createFakePi();
  loadExtensions(reloaded.pi);
  assert.deepEqual([...reloaded.tools.keys()].sort(), [...first.tools.keys()].sort());
  assert.deepEqual([...reloaded.handlers.keys()].sort(), [...first.handlers.keys()].sort());
});

// pi discovers extensions in a directory and picks its own order: loaded agents
// first, the pair must still wire up whole, dispatching an envelope by kind
// rather than falling back to the plain-text path.
test("either load order wires the pair up: agents first, status second", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const factory = await freshExtensions("agents-first");
    const s = await startSession(fx, { factory });
    assert.ok(s.tools.get("ask_agent"), "the agent half registered its tools");
    assert.equal(statSync(fx.inboxDir).mode & 0o777, 0o700, "the extension creates the uid-private inbox directory");
    const resp = await sendToInbox(s.inboxPath, envelope("notice", "loaded either way", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      customMessages(s, "kido-notice").some((m) => m.message.content.endsWith("\nloaded either way")),
      "the envelope was dispatched by the agent half, not delivered as plain text",
    );
  } finally {
    await fx.restore();
  }
});

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
    assert.ok(customMessages(s, "kido-reply").some((m) => m.message.content.includes("stray answer")), "an unmatched reply is surfaced to the model");
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
    await fx.restore();
  }
});

test("a reply arriving after its ask timed out is still surfaced, never dropped", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    const timedOut = await ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 20 });
    const sent = fx.lastLogFor("peer-a", "ask");
    assert.match(timedOut.content[0].text, /no reply/);
    assert.ok(timedOut.content[0].text.includes(sent!.id), "the timeout error names the ask id");

    const resp = await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    const late = customMessages(s, "kido-reply");
    assert.equal(late.length, 1, "a late reply is delivered as a kido-reply custom message");
    assert.equal(late[0]!.message.content, `peer-a replied (to ask ${sent!.id}): late answer`, "the model reads the same text, naming the ask it answered");
    assert.deepEqual(late[0]!.opts, { deliverAs: "followUp", triggerTurn: true }, "pi starts the reply's turn itself");
  } finally {
    await fx.restore();
  }
});

test("cycle refusal: an inbound ask from a session we're already asking is refused on the wire and not shown; others are ok", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    const p1 = ask.execute("c1", { to: "peer-a", question: "outbound q" }); // holds an edge to peer-a
    await fx.waitForLog("peer-a", "ask");

    const refused = await sendToInbox(s.inboxPath, envelope("ask", "are you free?", { id: "inbound-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(refused, "refused");
    assert.ok(!askSent(s, "are you free?"), "a refused ask is not shown to the model");

    const ok = await sendToInbox(s.inboxPath, envelope("ask", "another question", { id: "inbound-2", from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(ok, "ok");
    assert.ok(askSent(s, "another question"), "an ask from anyone else is shown");

    const sent = fx.lastLogFor("peer-a", "ask");
    await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent!.id, from: { session: "peer-a" } }));
    await p1;
  } finally {
    await fx.restore();
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
    await fx.restore();
  }
});

// A /reload changes a session's id while leaving its pane untouched; message_agent
// must re-resolve the reply against the sender's current session, found by pane,
// not the stale one the model was told about when the ask arrived.
test("a reply to an unnamed asker still reaches it after the asker reloads and its session id changes", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-old", name: "", pane: "%42", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);

    const resp = await sendToInbox(
      s.inboxPath,
      envelope("ask", "still there?", { id: "ask-reload-1", from: { session: "peer-a-old", pane: "%42" } }),
    );
    assert.equal(resp, "ok");
    const asked = askSent(s, "is asking");
    assert.ok(asked, "the ask was delivered to the model");
    assert.match(asked!.message.content, /message_agent\(to="peer-a-old"/, "an unnamed asker's fallback label is its session id");

    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-new", name: "", pane: "%42", parent: "", self: false, canMessage: true, canReply: true },
    ]);

    const reply = await s.tools.get("message_agent").execute("c1", { to: "peer-a-old", message: "still here", replyTo: "ask-reload-1" });
    assert.doesNotMatch(reply.content[0].text, /could not message/, "the reply must not fail just because the asker reloaded");

    const sent = fx.lastLogFor("peer-a-new");
    assert.ok(sent, "the reply was actually addressed to the asker's current session, not its stale one");
    assert.equal(fx.lastLogFor("peer-a-old"), undefined, "the stale session id was never dialled");
  } finally {
    await fx.restore();
  }
});

// The stop-after instruction belongs only when replyTo genuinely answers an ask
// this session has pending; a reply to a notice, or a stale/unknown id, must not gain it.
test("message_agent's result says to stop after replying to a pending ask, but not after any other send", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", pane: "%2", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);

    // pendingInboundAsks is keyed by pane, so the envelope must carry one.
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
    await fx.restore();
  }
});

test("abandonPending: session_shutdown and a failed rebind settle a waiting ask promptly; a successful rebind stays answerable", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a

    // session_shutdown: nothing is coming back, so the wait must not run out its
    // own (5-minute default) timeout.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      await s.emit("session_shutdown");
      const out = await settlesWithin(p, 500);
      assert.match(out.content[0].text, /inbox closed|inbox is unavailable/);
      assert.doesNotMatch(out.content[0].text, /will still arrive/, "must not promise a reply that can no longer land");
    }

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
    await fx.restore();
  }
});

// A shutdown module must still refuse to wait for a reply: the inbox it was
// serving is gone even though the socket is not.
test("an envelope that arrives in the /reload gap is held, then answered and delivered once", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s1 = await startSession(fx, { factory: await freshExtensions() });
    await s1.emit("session_shutdown", { reason: "reload" });

    const sent = sendToInbox(s1.inboxPath, envelope("message", "in the gap", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(await pendingState(sent, 100), "pending", "the gap must hold the connection, not answer it");

    const refused = await s1.tools.get("ask_agent").execute("c1", { to: "peer-b", question: "q" });
    assert.match(refused.content[0].text, /inbox is unavailable/, "a shut-down module must still refuse to wait for a reply");

    const s2 = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(await settlesWithin(sent, 2000), "ok");
    const inGap = (s: { delivered: Array<{ text: string }>; messages: Array<{ message: any }> }) =>
      s.delivered.filter((d) => d.text.includes("in the gap")).length +
      s.messages.filter((m) => String(m.message.content).includes("in the gap")).length;
    await pollUntil(() => inGap(s2) > 0, 2000, "the held message to reach the reloaded session");
    assert.equal(inGap(s2), 1, "the held message was delivered more than once");
    assert.equal(inGap(s1), 0, "the module that shut down must not deliver it too");
  } finally {
    await fx.restore();
  }
});

// Negative control: every other reason still closes and unlinks.
test("a session_shutdown that is not a reload still closes the inbox", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(await sendToInbox(s.inboxPath, envelope("message", "before", { from: { session: "peer-a", name: "peer-a" } })), "ok");

    await s.emit("session_shutdown", { reason: "quit" });
    assert.equal(existsSync(s.inboxPath), false, "the socket file is still there after a quit");
    await assert.rejects(
      () => sendToInbox(s.inboxPath, envelope("message", "after", { from: { session: "peer-a", name: "peer-a" } })),
      /ENOENT|ECONNREFUSED/,
    );
  } finally {
    await fx.restore();
  }
});

// The inode is what tells "handed forward" from "torn down and replaced": a
// rebind unlinks and creates a new one.
test("a /reload leaves exactly one listener, on the same socket", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s1 = await startSession(fx, { factory: await freshExtensions() });
    const before = statSync(s1.inboxPath).ino;

    await s1.emit("session_shutdown", { reason: "reload" });
    const s2 = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(statSync(s2.inboxPath).ino, before, "the reload rebound the socket instead of keeping it");

    for (const text of ["after one", "after two"]) {
      assert.equal(await sendToInbox(s2.inboxPath, envelope("notice", text, { from: { session: "peer-a", name: "peer-a" } })), "ok");
      await pollUntil(() => noticesIn(s2, text).length === 1, 2000, `the notice ${JSON.stringify(text)} to arrive exactly once`);
    }
    assert.equal(noticesIn(s1, "after one").length + noticesIn(s1, "after two").length, 0, "a second listener still pointing at the old module");
  } finally {
    await fx.restore();
  }
});

// This half asserts the registered tools are exactly the names in
// share/pi/testdata/tools.json; lib/test/test_tool_parity.ml asserts
// every name in that file is a kido subcommand, so a tool added here fails until
// both are updated.
test("the registered tools are exactly the shared list both suites check subcommand parity against", async () => {
  const fixtures = createFakePi();
  loadExtensions(fixtures.pi);
  const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "testdata", "tools.json");
  const expected: string[] = JSON.parse(readFileSync(fixturePath, "utf8"));
  const registered = [...fixtures.tools.keys()];

    const missing = expected.filter((name) => !registered.includes(name));
    const extra = registered.filter((name) => !expected.includes(name));
    assert.deepEqual(
      missing,
      [],
      `share/pi/testdata/tools.json names ${JSON.stringify(missing)}, but no tool registers ${missing.length === 1 ? "it" : "them"}`,
    );
    assert.deepEqual(
      extra,
      [],
      `${JSON.stringify(extra)} ${extra.length === 1 ? "is" : "are"} registered but not in share/pi/testdata/tools.json, ` +
        "so nothing checks that a kido subcommand of that name exists - add it to the fixture and give it a subcommand",
    );
});

function noticesIn(s: Pick<ReturnType<typeof createFakePi>, "messages">, text: string) {
  return customMessages(s, "kido-notice").filter((m) => m.message.content.includes(text));
}
