import { test } from "node:test";

import assert from "node:assert/strict";

import { makeFixture, agentPane, selfPane, startSession, text, at, getStr } from "./koa-agent-fixture.ts";

test("stop_agent stops a peer with a stop message and then the pane, and says so", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "pane_3", session: "peer-session", name: "peer" })]);
    const s = await startSession(fx);
    const result = await s.tool("stop_agent").execute("c", { agent: "peer" });
    assert.equal(text(result), "stopped peer");
    const stop = at(fx.posts("/panes/pane_3/messages"), 0);
    assert.deepEqual({ kind: stop.kind, text: stop.text }, { kind: "stop", text: "" });
    assert.match(getStr(stop, "id"), /^[A-Za-z0-9_-]{22}$/);
    assert.deepEqual(fx.posts("/panes/pane_3/stop"), [{ wait_ms: 5000 }]);
    assert.equal(fx.row("pane_3"), undefined, "the pane is gone");
    const order = fx.apiCalls().filter((call) => call.method === "POST" && call.path.startsWith("/panes/pane_3/")).map((call) => call.path);
    assert.deepEqual(order, ["/panes/pane_3/messages", "/panes/pane_3/stop"]);
  } finally {
    await fx.restore();
  }
});

test("stop_agent without an open stream refuses unless forced, and force kills without the request", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "pane_3", session: "peer-session", name: "peer", inbox: false })]);
    const s = await startSession(fx);
    const stop = s.tool("stop_agent");
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
    fx.setPanes([selfPane(), agentPane({ pane: "pane_3", session: "peer-session", name: "peer" }), ]);
    const s = await startSession(fx, { name: "Self" });
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "acme/m:low", fork: false, cwd: "/work/kid" } });
    const stop = s.tool("stop_agent");
    const self = await stop.execute("c", { agent: "Self" });
    assert.equal(text(self), "refusing to stop Self: it is this agent");
    assert.equal(text(await stop.execute("c", { agent: "kid" })), "kid had already ended: koa restarted");
    assert.deepEqual(fx.posts("/panes/pane_5/stop"), [], "an ended child needs no stop");
    fx.scriptSends([{ status: 500, body: { kind: "io", message: "queue" } }, { status: 500, body: { kind: "io", message: "queue" } }, { status: 500, body: { kind: "io", message: "queue" } }]);
    assert.equal(text(await stop.execute("c", { agent: "peer" })), "stopped peer; the stop request failed: queue");
    assert.match(text(await stop.execute("c", { agent: "nobody" })), /no agent session matches "nobody"/);
  } finally {
    await fx.restore();
  }
});
