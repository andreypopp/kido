import { test } from "node:test";

import assert from "node:assert/strict";

import { makeFixture, selfPane, startSession, pollUntil, customMessages, entriesOf, asSubagent, idleTurn, notices, at, get } from "./koa-agent-fixture.ts";

import { PARENT_GUIDANCE } from "./koa-agent.ts";

const parent = { type: "pane", pane: "pane_2", session: "boss-session", name: "boss" };
const peer = { type: "pane", pane: "pane_3", session: "peer-session", name: "peer" };

const acked = async (fx: ReturnType<typeof makeFixture>, id: string): Promise<void> =>
  pollUntil(() => fx.acks().some((ack) => ack.id === id), 2000, `the ack of ${id}`);

test("each kind reaches pi as its own kind of message and is acked once handed over", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);

    fx.feed({ id: "kind-user-01", kind: "user", text: "typed by a person", from: { type: "user" } });
    await acked(fx, "kind-user-01");
    assert.deepEqual(s.delivered, [{ text: "typed by a person", opts: { deliverAs: "followUp" } }]);

    fx.feed({ id: "kind-msg-001", kind: "message", text: "when you can", relation: "parent", from: parent });
    await acked(fx, "kind-msg-001");
    const message = at(customMessages(s, "ko-message"), 0);
    assert.equal(message.message.content, "message from @boss (your parent, who spawned you):\nwhen you can");
    assert.deepEqual(message.opts, { deliverAs: "followUp", triggerTurn: true });
    assert.equal(get(message.message.details, "work"), true, "work from the parent is marked");
    assert.deepEqual(get(message.message.details, "agent"), { name: 'boss', session: 'boss-session', pane: 'pane_2' });
    assert.equal(get(message.message.details, "body"), 'when you can');

    fx.feed({ id: "kind-msg-002", kind: "message", text: "fyi", relation: "sibling", from: peer });
    await acked(fx, "kind-msg-002");
    const second = at(customMessages(s, "ko-message"), 1);
    assert.equal(second.message.content, "message from @peer (another agent in this session, not the user):\nfyi");
    assert.equal(get(second.message.details, "work"), false);

    fx.feed({ id: "kind-steer-01", kind: "steer", text: "do X instead", relation: "parent", from: parent });
    await acked(fx, "kind-steer-01");
    const steer = at(customMessages(s, "ko-steer"), 0);
    assert.equal(steer.message.content, "boss is redirecting this work: do X instead");
    assert.deepEqual(steer.opts, { deliverAs: "steer", triggerTurn: true }, "a steer joins the running turn");
    assert.equal(get(steer.message.details, "work"), true);
    assert.deepEqual(get(steer.message.details, "agent"), { name: 'boss', session: 'boss-session', pane: 'pane_2' });
    assert.equal(get(steer.message.details, "body"), 'do X instead');

    fx.feed({ id: "kind-note-01", kind: "notice", text: "heads up", relation: "sibling", from: peer });
    await acked(fx, "kind-note-01");
    assert.deepEqual(notices(s), ["notice from peer (a subagent or background job's report, not the user):\nheads up"]);
    assert.equal(get(at(customMessages(s, 'ko-notice'), 0).message.details, "inbound", "form"), 'notice');
    assert.equal(get(at(customMessages(s, 'ko-notice'), 0).message.details, "body"), 'heads up');

    fx.feedRaw({ id: "kind-weird-01", kind: "weird", text: "?", relation: "sibling", from: peer });
    await acked(fx, "kind-weird-01");
    assert.deepEqual(fx.acks().at(-1), { type: "refuse", id: "kind-weird-01" }, "a message that has no known shape is refused");
    assert.equal(s.delivered.length, 1, "and delivers nothing");
    fx.feedRaw({ id: "kind-norel-01", kind: "message", text: "no relation", from: peer, relation: undefined });
    await acked(fx, "kind-norel-01");
    assert.deepEqual(fx.acks().at(-1), { type: "refuse", id: "kind-norel-01" }, "a pane sender without its relation has not the shape either");

    fx.feed({ id: "kind-plain-01", kind: "message", text: "from a terminal", from: { type: "user" } });
    await acked(fx, "kind-plain-01");
    assert.equal(at(s.delivered, -1).text, "from a terminal", "a message with no calling agent is plain text");
  } finally {
    await fx.restore();
  }
});

test("work marks follow the parent's messages: at message_start in the child, not at the receiving", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await asSubagent("self-session", async () => {
      const s = await startSession(fx);
      assert.equal(entriesOf(s, "koa.work").length, 0);
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true } } });
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: false } } });
      assert.deepEqual(entriesOf(s, "koa.work").map((work) => work.owner), ["self-session"]);
    });
  } finally {
    await fx.restore();
  }
});

test("an interrupt aborts at once and delivers its text when the turn settles; idle, it delivers at once", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await s.emit("agent_start");
    fx.feed({ id: "int-0000001", kind: "interrupt", text: "new work", relation: "parent", from: parent });
    await acked(fx, "int-0000001");
    assert.equal(s.aborts(), 1);
    assert.equal(customMessages(s, "ko-message").length, 0, "held while the turn still runs");
    await s.emit("agent_settled", { aborted: true }, { isIdle: () => true });
    assert.equal(customMessages(s, "ko-message").length, 1);
    assert.match(at(customMessages(s, "ko-message"), 0).message.content, /new work$/);

    fx.feed({ id: "int-0000002", kind: "interrupt", text: "more", relation: "parent", from: parent });
    await acked(fx, "int-0000002");
    assert.equal(s.aborts(), 2);
    assert.equal(customMessages(s, "ko-message").length, 2, "idle: nothing to wait for");
  } finally {
    await fx.restore();
  }
});

test("a stop shuts the session down once, after it has been acked, and discards held interrupts", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await s.emit("agent_start");
    fx.feed({ id: "stop-held-01", kind: "interrupt", text: "held", from: parent });
    await acked(fx, "stop-held-01");
    fx.feed({ id: "stop-stop-01", kind: "stop", from: parent });
    await pollUntil(() => s.shutdowns() === 1, 2000, "the shutdown");
    await acked(fx, "stop-stop-01");
    await s.emit("agent_settled", { aborted: true }, { isIdle: () => true });
    assert.equal(customMessages(s, "ko-message").length, 0, "stop discards the held replacement work");
    assert.equal(s.shutdowns(), 1);
  } finally {
    await fx.restore();
  }
});

test("a notice that cannot be recorded is refused, and one that can is acked and recorded once", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const report = { type: "pane", pane: "pane_5", session: "kid-session", name: "kid" };
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "m", fork: false, cwd: "/tmp", pane: { instance: "a".repeat(32), pane: "pane_5" } } });
    s.failAppends.add("koa.report");
    fx.feed({ id: "rep-fail-001", kind: "notice", text: "done", data: { report: true }, relation: "child", from: report });
    await pollUntil(() => fx.acks().some((ack) => ack.id === "rep-fail-001"), 2000, "the verdict");
    assert.deepEqual(fx.acks(), [{ type: "refuse", id: "rep-fail-001" }], "the child retries a report that was not recorded");
    assert.equal(notices(s).length, 0);

    s.failAppends.clear();
    fx.forgetAcks();
    fx.dropStream();
    await pollUntil(() => fx.acks().length === 1, 2000, "the report to arrive again");
    assert.deepEqual(fx.acks(), [{ type: "ack", id: "rep-fail-001" }]);
    assert.deepEqual(entriesOf(s, "koa.report").map((entry) => [entry.child, entry.text]), [["kid-session", "done"]]);
    assert.equal(notices(s).length, 1);
    assert.ok(at(notices(s), 0).endsWith(PARENT_GUIDANCE));
  } finally {
    await fx.restore();
  }
});

test("an idle turn of a child with no work owed reports nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane({ parent: "pane_2" })]);
    await asSubagent("self-session", async () => {
      const s = await startSession(fx);
      await idleTurn(s, "nothing was asked");
      assert.deepEqual(fx.posts("/panes/pane_2/messages"), []);
    });
  } finally {
    await fx.restore();
  }
});
