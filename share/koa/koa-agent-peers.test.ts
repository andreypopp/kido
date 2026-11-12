import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { appendFileSync, unlinkSync, writeFileSync } from "node:fs";
import { makeFixture, selfPane, agentPane, startSession, savedSession, entriesOf, pollUntil, text, asSubagent, withEnv, at, jsonRows, get, getList } from "./koa-agent-fixture.ts";

test("peers observed only on /client can end and resume as independent peers", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "0123456789abcdef";
    const file = savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    appendFileSync(file, JSON.stringify({ type: "model_change", id: "m", parentId: null, timestamp: new Date().toISOString(), provider: "acme", modelId: "saved" }) + "\n");
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Peer", cwd: process.cwd() })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.role === "peer" && e.session === id), 2000, "peer registry entry");
    fx.clientEvent({ type: "pwd", pane: "pane_2", pwd: fx.dir });
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.role === "peer" && e.cwd === fx.dir));
    fx.dropClient();
    await pollUntil(() => fx.streamOpens("/client") === 2);
    await pollUntil(() => entriesOf(s, "koa.agent").filter((e) => e.role === "peer" && e.session === id && e.cwd === process.cwd()).length === 2);
    const live = agentPane({ pane: "pane_3", session: "0123456789abcdee", name: "PeerLive" });
    fx.setPanes([selfPane(), live]);
    fx.setClientPanes([selfPane(), live]);
    await pollUntil(async () => jsonRows(await s.tool("list_agents").execute("c", { which: "peers" })).some((a) => a.id === id && a.state === "ended" && a.cwd === fx.dir));
    const completed = { value: `@Peer (session ${id})` };
    const calls = fx.apiCalls().length;
    assert.match(text(await s.tool("stop_agent").execute("c", { agent: "Peer" })), /had already ended/);
    assert.equal(fx.posts("/panes").length, 0);
    assert.ok(fx.apiCalls().slice(calls).every((c) => c.method === "GET"));
    assert.match(text(await s.tool("message_agent").execute("c", { to: completed.value, message: "continue" })), /restarted Peer/);
    const body = at(fx.posts("/panes"), 0);
    assert.equal(body.session, "session_1");
    assert.equal(body.cwd, process.cwd(), "resume uses the session header cwd, not the observed peer cwd");
    assert.equal(body.parent, undefined);
    assert.equal(body.close, undefined);
    assert.ok(!getList(body, "env").some((e) => get(e, "name") === "KO_AGENT_PARENT_SESSION"));
    assert.ok(!getList(body, "command", "argv").includes("--session-dir"));
    assert.ok(getList(body, "command", "argv").includes(file));
    assert.ok(getList(body, "command", "argv").includes("acme/saved"));
    assert.equal(get(body.vars, "koa.task", "text"), "continue");
    fx.setPanes([selfPane()]);
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "Peer", resume_from: id, task: "again" })), /independent peer/);
    assert.equal(at(fx.posts("/panes"), 1).parent, undefined);
    assert.deepEqual(entriesOf(s, "koa.work"), []);
    assert.deepEqual(entriesOf(s, "koa.ended"), []);
  } finally { await fx.restore(); }
});

test("ended peers use session ids when names collide and omit missing files", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const ids = ["11111111abcdef01", "22222222abcdef02"];
    const files = ids.map((id) => savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id));
    fx.setClientPanes([selfPane(), ...ids.map((id, i) => agentPane({ pane: `pane_${i + 2}`, session: id, name: "Same" }))]);
    await pollUntil(() => entriesOf(s, "koa.agent").filter((e) => e.role === "peer").length === 2);
    fx.setClientPanes([selfPane()]);
    const list = async () => jsonRows(await s.tool("list_agents").execute("c", { which: "peers" }));
    assert.equal((await list()).length, 2);
    assert.match(text(await s.tool("message_agent").execute("c", { to: "Same", message: "go" })), /matches several by name/);
    assert.match(text(await s.tool("message_agent").execute("c", { to: ids[0], message: "go", mode: "steer" })), /no longer running/);
    unlinkSync(at(files, 0));
    assert.deepEqual((await list()).map((a) => a.id), [ids[1]]);
    assert.equal(entriesOf(s, "koa.agent").filter((e) => e.role === "peer").length, 2);
    assert.equal(fx.posts("/panes").length, 0);
  } finally { await fx.restore(); }
});

test("sparse layouts retain existing rows and unchanged reconnects append nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await pollUntil(() => fx.clientLayouts().length === 1);
    fx.setClientPanes([selfPane({ title: "changed" })]);
    await pollUntil(() => fx.clientLayouts().some((event) => event.panes.length === 0));
    const id = "33333333abcdef03";
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Sparse" })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.session === id), 2000, "peer after sparse layout");
    const before = entriesOf(s, "koa.agent").length;
    fx.dropClient();
    await pollUntil(() => fx.clientLayouts().filter((event) => event.panes.length === 2).length === 1);
    const second = "44444444abcdef04";
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Sparse" }), agentPane({ pane: "pane_3", session: second, name: "After" })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.session === second));
    assert.equal(entriesOf(s, "koa.agent").length, before + 1);
  } finally { await fx.restore(); }
});

test("an untrusted stale pi.session does not hide an ended peer", async () => {
  const fx = makeFixture();
  try {
    const id = "55555555abcdef05";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Stale" })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.session === id));
    fx.setPanes([selfPane(), { id: "pane_2", vars: { "pi.session": id } }]);
    const rows = jsonRows(await s.tool("list_agents").execute("c", { which: "peers" }));
    assert.equal(rows.find((a) => a.id === id)?.state, "ended");
  } finally { await fx.restore(); }
});

test("concurrent peer messages reuse a pane before pi publishes its identity", async () => {
  const fx = makeFixture();
  try {
    const id = "66666666abcdef06";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    const gate = join(fx.dir, "identity-gate");
    await withEnv({ KO_FAKE_PEER_IDENTITY_GATE: gate }, async () => {
      fx.setPanes([selfPane()]);
      const s = await startSession(fx);
      fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Pending" })]);
      await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.session === id));
      fx.setClientPanes([selfPane()]);
      await Promise.all(["first", "second"].map((message) => s.tool("message_agent").execute("c", { to: "Pending", message })));
      assert.equal(fx.posts("/panes").length, 1);
      assert.equal(fx.posts("/panes/pane_10/messages").length, 1);
      writeFileSync(gate, "");
      assert.equal(jsonRows(await s.tool("list_agents").execute("c", {})).find((a) => a.id === id)?.state, "running");
    });
  } finally { await fx.restore(); }
});

test("children and pi inside a runtime open no peer observer", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await asSubagent("self-session", () => startSession(fx));
    assert.equal(fx.streamOpens("/client"), 0);
    await withEnv({ KO_RUNTIME: "dev" }, () => startSession(fx));
    assert.equal(fx.streamOpens("/client"), 0);
  } finally { await fx.restore(); }
});
