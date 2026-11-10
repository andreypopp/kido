import { test } from "node:test";

import assert from "node:assert/strict";

import { makeFixture, agentPane, selfPane, startSession, entriesOf, notices, customMessages, pollUntil, exited, text, type Fixture, type Started } from "./ko-pi-fixture.ts";

const INSTANCE = "a".repeat(32);
const kid = { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "acme/m:low", fork: false, cwd: "/work/kid", pane: { instance: INSTANCE, pane: "pane_5" } };

async function withKid(fx: Fixture, state: { reported: boolean; dead?: unknown }): Promise<Started> {
  fx.setPanes([selfPane(), agentPane({ pane: "pane_5", session: "kid-session", name: "kid", parent: "pane_1", close: "on_exit", dead: state.dead })]);
  const s = await startSession(fx);
  s.entries.push({ type: "custom", customType: "ko-pi.agent", data: kid });
  s.entries.push({ type: "custom", customType: "ko-pi.work", data: { owner: "self-session", child: "kid-session", at: 1 } });
  if (state.reported) s.entries.push({ type: "custom", customType: "ko-pi.report", data: { owner: "self-session", child: "kid-session", name: "kid", text: "done", at: 2, id: "r" } });
  return s;
}

const end = (cause: unknown) => ({ type: "dead", at: 3, cause });

test("the ended message of a child that reported is a one-line notice", async () => {
  const fx = makeFixture();
  try {
    const s = await withKid(fx, { reported: true, dead: exited(0) });
    fx.setScreen("pane_5", "never read");
    fx.feed({ id: "ended-pane_5", kind: "ended", relation: "child", from: { type: "pane", pane: "pane_5" }, end: end(exited(0).cause) });
    await pollUntil(() => notices(s).length === 1, 2000, "the ending notice");
    assert.deepEqual(notices(s), ["notice from kid (a subagent or background job's report, not the user):\nsubagent \"kid\" ended: exit 0; it had reported"]);
    assert.equal(fx.apiCalls().some((call) => call.path.includes("/screen")), false, "no screen when it had reported");
    const details = customMessages(s, 'ko-notice')[0]!.message.details;
    assert.deepEqual(details.inbound, { form: 'ended', reported: true, relation: 'child' });
    assert.deepEqual(details.agent, { name: 'kid', session: 'kid-session', pane: 'pane_5' });
    assert.equal(details.body, 'subagent "kid" ended: exit 0; it had reported');
    assert.deepEqual(entriesOf(s, "ko-pi.ended").map((e) => [e.child, e.pane]), [["kid-session", "pane_5"]]);
  } finally {
    await fx.restore();
  }
});

test("a child that had not reported ends with the tail of its lingering screen and how to go on", async () => {
  const fx = makeFixture();
  try {
    const s = await withKid(fx, { reported: false, dead: exited(1) });
    const screen = "x".repeat(5000) + "\nthe last line\n";
    fx.setScreen("pane_5", screen);
    fx.feed({ id: "ended-pane_5", kind: "ended", from: { type: "pane", pane: "pane_5" }, end: end(exited(1).cause) });
    await pollUntil(() => notices(s).length === 1, 2000, "the ending notice");
    const body = notices(s)[0]!.split("\n").slice(1).join("\n");
    assert.equal(body.split("\n")[0], 'subagent "kid" ended: exit 1; it had not reported on its last work');
    assert.equal(body.split("\n")[1], "--- last 4000 bytes of its screen ---");
    assert.ok(body.includes("the last line\n"));
    assert.ok(body.endsWith("\nmessage it to continue it, or stop_agent to end it"));
    const tail = body.split("\n").slice(2, -1).join("\n");
    assert.equal(Buffer.byteLength(tail, "utf8"), 4000, "the screen is cut to its last 4000 bytes");
  } finally {
    await fx.restore();
  }
});

test("a signal, a failed start and a removed pane each have their words, and a removed pane has no screen", async () => {
  const fx = makeFixture();
  try {
    const s = await withKid(fx, { reported: false, dead: exited(0) });
    const cases: Array<[unknown, string]> = [
      [end({ type: "signaled", signal: 9 }), 'subagent "kid" ended: signal KILL; it had not reported on its last work'],
      [end({ type: "failed", message: "openpty: no ptys" }), 'subagent "kid" ended: failed: openpty: no ptys; it had not reported on its last work'],
      [{ type: "gone" }, 'subagent "kid" ended: its pane was removed; it had not reported on its last work'],
    ];
    for (const [i, [ending, first]] of cases.entries()) {
      s.entries.push({ type: "custom", customType: "ko-pi.agent", data: kid });
      fx.feed({ id: `ended-pane_5-${i}`, kind: "ended", from: { type: "pane", pane: "pane_5" }, end: ending });
      await pollUntil(() => notices(s).length === i + 1, 2000, `notice ${i}`);
      assert.equal(notices(s)[i]!.split("\n")[1], first);
    }
    assert.equal(notices(s)[2]!.includes("--- last"), false, "a removed pane has no screen to read");
  } finally {
    await fx.restore();
  }
});

test("an ended message for no current child, or for one that was stopped or already announced, says nothing", async () => {
  const fx = makeFixture();
  try {
    const s = await withKid(fx, { reported: false, dead: exited(0) });
    fx.feed({ id: "ended-stranger", kind: "ended", from: { type: "pane", pane: "pane_66" }, end: end(exited(0).cause) });
    s.entries.push({ type: "custom", customType: "ko-pi.ended", data: { owner: "self-session", child: "kid-session", pane: "pane_5", at: 4 } });
    fx.feed({ id: "ended-pane_5", kind: "ended", from: { type: "pane", pane: "pane_5" }, end: end(exited(0).cause) });
    await pollUntil(() => fx.acks().length === 2, 2000, "both acked");
    assert.deepEqual(notices(s), []);
  } finally {
    await fx.restore();
  }
});

test("a parent that returns finds the endings it missed once: a gone pane, a dead pane's cause, and nothing again after", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "pane_5", session: "kid-session", name: "kid", parent: "pane_1", dead: exited(3) }),
      agentPane({ pane: "pane_6", session: "well-session", name: "well", parent: "pane_1" }),
    ]);
    const entries = [
      { type: "custom" as const, customType: "ko-pi.agent", data: kid },
      { type: "custom" as const, customType: "ko-pi.work", data: { owner: "self-session", child: "kid-session", at: 1 } },
      { type: "custom" as const, customType: "ko-pi.agent", data: { ...kid, name: "lost", session: "lost-session", pane: { instance: "b".repeat(32), pane: "pane_8" } } },
      { type: "custom" as const, customType: "ko-pi.agent", data: { ...kid, name: "well", session: "well-session", pane: { instance: INSTANCE, pane: "pane_6" } } },
    ];
    fx.setScreen("pane_5", "it crashed");
    const s = await startSession(fx, { entries: [...entries] });
    assert.deepEqual(
      notices(s).map((n) => n.split("\n")[1]).sort(),
      ['subagent "kid" ended: exit 3; it had not reported on its last work', 'subagent "lost" ended: its pane is gone; it had reported'],
      "a living child says nothing",
    );
    assert.ok(notices(s).some((n) => n.includes("it crashed")));
    await s.emit("session_shutdown", { reason: "reload" });
    const again = await startSession(fx, { entries: s.entries });
    assert.deepEqual(notices(again), [], "an announced ending is recorded and not announced twice");
    assert.equal(entriesOf(again, "ko-pi.ended").length, 2);

    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { ...kid, pane: { instance: INSTANCE, pane: "pane_7" } } });
    await again.emit("session_shutdown", { reason: "reload" });
    fx.setPanes([selfPane()]);
    const third = await startSession(fx, { entries: s.entries });
    assert.deepEqual(
      notices(third).map((n) => n.split("\n")[1]).sort(),
      ['subagent "kid" ended: its pane is gone; it had not reported on its last work', 'subagent "well" ended: its pane is gone; it had reported'],
      "a restart makes the child eligible again; the lost one stays announced",
    );
  } finally {
    await fx.restore();
  }
});

test("stop_agent stops a peer with a stop message and then the pane, and says so", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "pane_3", session: "peer-session", name: "peer" })]);
    const s = await startSession(fx);
    const result = await s.tools.get("stop_agent").execute("c", { agent: "peer" });
    assert.equal(text(result), "stopped peer");
    const [stop] = fx.posts("/panes/pane_3/messages");
    assert.deepEqual({ kind: stop!.kind, text: stop!.text }, { kind: "stop", text: "" });
    assert.match(stop!.id, /^[A-Za-z0-9_-]{22}$/);
    assert.deepEqual(fx.posts("/panes/pane_3/stop"), [{ wait_ms: 5000 }]);
    assert.equal(fx.row("pane_3"), undefined, "the pane is gone");
    const order = fx.apiCalls().filter((call) => call.method === "POST" && call.path.startsWith("/panes/pane_3/")).map((call) => call.path);
    assert.deepEqual(order, ["/panes/pane_3/messages", "/panes/pane_3/stop"]);
  } finally {
    await fx.restore();
  }
});

test("stop_agent of an own child says whether it had reported and silences its ending", async () => {
  const fx = makeFixture();
  try {
    const s = await withKid(fx, { reported: false });
    const stop = s.tools.get("stop_agent");
    assert.equal(text(await stop.execute("c", { agent: "kid" })), "stopped kid; it had not reported on its last work");
    fx.feed({ id: "ended-pane_5", kind: "ended", from: { type: "pane", pane: "pane_5" }, end: end({ type: "signaled", signal: 15 }) });
    await pollUntil(() => fx.acks().length === 1, 2000, "the ended message to be read");
    assert.deepEqual(notices(s), [], "a child that was stopped sends no ending notice");

    const reported = await withKid(fx, { reported: true });
    assert.equal(text(await reported.tools.get("stop_agent").execute("c", { agent: "kid" })), "stopped kid; it had reported");
  } finally {
    await fx.restore();
  }
});

test("stop_agent without an open stream refuses unless forced, and force kills without the request", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "pane_3", session: "peer-session", name: "peer", inbox: false })]);
    const s = await startSession(fx);
    const stop = s.tools.get("stop_agent");
    const refused = await stop.execute("c", { agent: "peer" });
    assert.equal(text(refused), "peer is not receiving messages; pass force to kill its pane");
    assert.equal(refused.isError, true);
    assert.deepEqual(fx.posts("/panes/pane_3/stop"), []);
    assert.equal(text(await stop.execute("c", { agent: "peer", force: true })), "stopped peer");
    assert.deepEqual(fx.posts("/panes/pane_3/messages"), [], "force sends no stop message");
    assert.equal(fx.posts("/panes/pane_3/stop").length, 1);
  } finally {
    await fx.restore();
  }
});

test("stop_agent refuses only the caller, reports an ended child, and names a failed stop request", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "pane_3", session: "peer-session", name: "peer" }), agentPane({ pane: "pane_5", session: "kid-session", name: "kid", parent: "pane_1", dead: exited(1) })]);
    const s = await startSession(fx, { name: "Self" });
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: kid });
    const stop = s.tools.get("stop_agent");
    const self = await stop.execute("c", { agent: "Self" });
    assert.equal(text(self), "refusing to stop Self: it is this agent");
    assert.equal(text(await stop.execute("c", { agent: "kid" })), "kid had already ended: exit 1");
    assert.deepEqual(fx.posts("/panes/pane_5/stop"), [], "an ended child needs no stop");
    fx.scriptSends([{ status: 500, body: { kind: "io", message: "queue" } }, { status: 500, body: { kind: "io", message: "queue" } }, { status: 500, body: { kind: "io", message: "queue" } }]);
    assert.equal(text(await stop.execute("c", { agent: "peer" })), "stopped peer; the stop request failed: queue");
    assert.match(text(await stop.execute("c", { agent: "nobody" })), /no agent session matches "nobody"/);
  } finally {
    await fx.restore();
  }
});
