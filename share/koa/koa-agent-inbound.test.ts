import { test } from "node:test";
import assert from "node:assert/strict";
import { makeFixture, selfPane, startSession, customMessages, entriesOf, createChannel, stubAgent, idleTurn, notices, at, get } from "./koa-agent-fixture.ts";
import type { Extension } from "./koa-agents.ts";

const parent = { name: "boss", session: "boss-session", pane: "pane_2" };
const peer = { name: "peer", session: "peer-session", pane: "pane_3" };

const extensionOf = (s: Awaited<ReturnType<typeof startSession>>): Extension => {
  const found = s.channel.host.extension;
  assert.ok(found);
  return found;
};

test("each kind reaches pi as its own kind of message", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const receive = extensionOf(s).receive;

    await receive({ kind: "user", text: "typed by a person" });
    assert.deepEqual(s.delivered, [{ text: "typed by a person", opts: { deliverAs: "followUp" } }]);

    await receive({ kind: "message", text: "when you can", relation: "parent", agent: parent });
    const message = at(customMessages(s, "ko-message"), 0);
    assert.equal(message.message.content, "message from @boss (your parent, who spawned you):\nwhen you can");
    assert.deepEqual(message.opts, { deliverAs: "followUp", triggerTurn: true });
    assert.equal(get(message.message.details, "work"), true, "work from the parent is marked");
    assert.deepEqual(get(message.message.details, "agent"), parent);

    await receive({ kind: "message", text: "fyi", relation: "sibling", agent: peer });
    const second = at(customMessages(s, "ko-message"), 1);
    assert.equal(second.message.content, "message from @peer (another agent in this session, not the user):\nfyi");
    assert.equal(get(second.message.details, "work"), false);

    await receive({ kind: "message", text: "ping", relation: "sibling", agent: peer, returnTo: { session: "peer-session", pane: "pane_3" } });
    assert.equal(at(customMessages(s, "ko-message"), 2).message.content, "message from @peer (session peer-session in pane_3; another agent in this session, not the user):\nping");

    await receive({ kind: "steer", text: "do X instead", relation: "parent", agent: parent });
    const steer = at(customMessages(s, "ko-steer"), 0);
    assert.equal(steer.message.content, "boss is redirecting this work: do X instead");
    assert.deepEqual(steer.opts, { deliverAs: "steer", triggerTurn: true }, "a steer joins the running turn");
    assert.equal(get(steer.message.details, "work"), true);

    await receive({ kind: "steer", text: "now", relation: "sibling", agent: peer, returnTo: { session: "peer-session", pane: "pane_3" }, runtime: "dev" });
    assert.equal(at(customMessages(s, "ko-steer"), 1).message.content, "peer (session peer-session in pane_3) (in runtime dev) is redirecting this work: now");

    await receive({ kind: "notice", text: "heads up", agent: peer });
    assert.deepEqual(notices(s), ["notice from peer (a subagent or background job's report, not the user):\nheads up"]);
    assert.equal(get(at(customMessages(s, "ko-notice"), 0).message.details, "inbound", "form"), "notice");

    await receive({ kind: "message", text: "from a terminal", relation: undefined, agent: { name: "the user" } });
    assert.equal(at(s.delivered, -1).text, "from a terminal", "a message with no relation is plain text");
  } finally {
    await fx.restore();
  }
});

test("a child marks its work in its parent's registry at message_start: a message of the parent and the user's own text", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const marked: string[] = [];
    const channel = createChannel();
    Object.assign(channel.host.self, { parent: stubAgent({ id: "boss-session", children: [], extension: { markWork: (child: string) => { marked.push(child); } } }) });
    const s = await startSession(fx, { channel });
    await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true } } });
    await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: false } } });
    await s.emit("message_start", { message: { role: "user", content: "typed in the child's view" } });
    assert.deepEqual(marked, ["self-session", "self-session"]);
    assert.deepEqual(entriesOf(s, "koa.work"), [], "the child writes no work entry of its own");
  } finally {
    await fx.restore();
  }
});

test("an interrupt aborts at once and delivers its text when the turn settles; idle, it delivers at once", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const receive = extensionOf(s).receive;
    await s.emit("agent_start");
    await receive({ kind: "interrupt", text: "new work", relation: "parent", agent: parent });
    assert.equal(s.aborts(), 1);
    assert.equal(customMessages(s, "ko-message").length, 0, "held while the turn still runs");
    await s.emit("agent_settled", { aborted: true }, { isIdle: () => true });
    assert.equal(customMessages(s, "ko-message").length, 1);
    assert.match(at(customMessages(s, "ko-message"), 0).message.content, /new work$/);

    await receive({ kind: "interrupt", text: "more", relation: "parent", agent: parent });
    assert.equal(s.aborts(), 2);
    assert.equal(customMessages(s, "ko-message").length, 2, "idle: nothing to wait for");
  } finally {
    await fx.restore();
  }
});

test("a child with no work owed reports nothing at an idle turn", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const reports: string[] = [];
    const channel = createChannel();
    Object.assign(channel.host.self, { parent: stubAgent({ id: "boss-session", children: [], extension: { childState: () => ({ reported: true }), receiveReport: (_child: unknown, text: string) => { reports.push(text); }, receive: async () => {} } }) });
    const s = await startSession(fx, { channel });
    await idleTurn(s, "nothing was asked");
    assert.deepEqual(reports, []);
  } finally {
    await fx.restore();
  }
});
