import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { appendFileSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { makeFixture, selfPane, agentPane, startSession, savedSession, entriesOf, pollUntil, text, createChannel, withEnv, at, jsonRows, get } from "./koa-agent-fixture.ts";

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
    fx.clientEvent({ type: "pwd", pane: "pane_2", pwd: fx.dir });
    await pollUntil(() => entriesOf(s, "koa.agent").filter((e) => e.role === "peer" && e.session === id).at(-1)?.cwd === fx.dir);
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
    assert.equal(body.env, undefined, "no agent environment");
    assert.deepEqual(body.command, { type: "koa", start: { type: "resume", session: file }, model: "acme/saved", browser: false });
    assert.equal(get(body.vars, "koa.task", "text"), "continue");
    fx.setPanes([selfPane()]);
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "Peer", resume_from: id, task: "again" })), /independent peer/);
    assert.equal(at(fx.posts("/panes"), 1).parent, undefined);
    assert.deepEqual(entriesOf(s, "koa.work"), []);
    assert.deepEqual(entriesOf(s, "koa.ended"), []);
  } finally { await fx.restore(); }
});

test("a restarted toplevel peer keeps its runtime", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setRuntimes({ dev: { paths: [], koa: "host" } });
    fx.setClientPanes([selfPane()]);
    const s = await startSession(fx);
    await pollUntil(() => fx.clientLayouts().length > 0, 2000, "client snapshot before spawning the peer");
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "Routed", task: "go", toplevel: true, runtime: "dev" })), /^spawned/);
    const peer = entriesOf(s, "koa.agent").find((entry) => entry.role === "peer");
    assert.equal(typeof peer?.session, "string");
    const id = String(peer?.session);
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_10", session: id, name: "Renamed", vars: { "koa.runtime": { name: "dev", cwd: process.cwd() } } })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((entry) => entry.session === id && entry.name === "Renamed"));
    fx.setClientPanes([selfPane()]);
    fx.setPanes([selfPane()]);
    assert.match(text(await s.tool("message_agent").execute("c", { to: id, message: "continue" })), /restarted/);
    assert.equal(at(fx.posts("/panes"), 1).runtime, "dev");
  } finally { await fx.restore(); }
});

test("spawn_agent resumes a recorded peer in its runtime unless explicitly changed", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setRuntimes({ dev: { paths: [], koa: "host" }, other: { paths: [], koa: "host" } });
    const s = await startSession(fx);
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "Routed", task: "go", toplevel: true, runtime: "dev" })), /^spawned/);
    const id = String(entriesOf(s, "koa.agent").find((entry) => entry.role === "peer")?.session);
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    for (const runtime of [undefined, "other"]) {
      fx.setPanes([selfPane()]);
      assert.match(text(await s.tool("spawn_agent").execute("c", { name: "Routed", resume_from: id, task: "continue", ...(runtime ? { runtime } : {}) })), /^spawned/);
    }
    assert.deepEqual(fx.posts("/panes").map((body) => body.runtime), ["dev", "dev", "other"]);
  } finally { await fx.restore(); }
});

test("an observed inside-runtime peer has no recorded tool route", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "88888888abcdef08";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    const inside = agentPane({ pane: "pane_2", session: id, name: "Inside" });
    inside.runtime = "dev";
    inside.status = { kind: { type: "runtime", pane: { type: "koa_agent", session: id, status: { since: 0, state: { type: "idle" } } } } };
    fx.setClientPanes([selfPane(), inside]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((entry) => entry.session === id));
    assert.equal(entriesOf(s, "koa.agent").find((entry) => entry.session === id)?.runtime, undefined);
    fx.setClientPanes([selfPane()]);
    assert.match(text(await s.tool("message_agent").execute("c", { to: id, message: "continue" })), /restarted/);
    assert.equal(at(fx.posts("/panes"), 0).runtime, undefined);
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

test("an untrusted stale koa.session does not hide an ended peer", async () => {
  const fx = makeFixture();
  try {
    const id = "55555555abcdef05";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Stale" })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.session === id));
    fx.setPanes([selfPane(), { id: "pane_2", vars: { "koa.session": id } }]);
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

test("a subagent and a pi inside a runtime open no peer observer", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const channel = createChannel();
    Object.assign(channel.host.self, { parent: { id: "boss-session", children: [] } });
    await startSession(fx, { channel });
    assert.equal(fx.streamOpens("/client"), 0);
    await withEnv({ KO_RUNTIME: "dev" }, () => startSession(fx));
    assert.equal(fx.streamOpens("/client"), 0);
  } finally { await fx.restore(); }
});

test("an ended peer resumes without --name, whatever name its record has", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "33333333abcdef03";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "", title: "" })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.role === "peer" && e.session === id && e.name === ""));
    fx.setClientPanes([selfPane()]);
    assert.match(text(await s.tool("message_agent").execute("c", { to: id, message: "continue" })), /restarted/);
    const body = at(fx.posts("/panes"), 0);
    assert.equal(get(body.command, "name"), undefined);
    assert.equal(body.name, undefined);
    const named = "44444444abcdef04";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), named, "kido-app-design");
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_3", session: named, name: "", title: "koa - Old - kido" })]);
    await pollUntil(() => entriesOf(s, "koa.agent").some((e) => e.role === "peer" && e.session === named && e.name === "koa - Old - kido"));
    fx.setClientPanes([selfPane()]);
    assert.match(text(await s.tool("message_agent").execute("c", { to: named, message: "continue" })), /restarted/);
    const revived = at(fx.posts("/panes"), 1);
    assert.equal(get(revived.command, "name"), undefined);
    assert.equal(revived.name, "kido-app-design");
  } finally { await fx.restore(); }
});

test("a peer's koa.name replaces its title-derived name, on arrival, on rename and on the next layout", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "77777777abcdef07";
    savedSession(join(fx.dir, "sessions", "peer"), process.cwd(), id);
    const titled = agentPane({ pane: "pane_2", session: id, name: "", title: "koa - Real - kido" });
    fx.setClientPanes([selfPane(), titled]);
    const latest = () => entriesOf(s, "koa.agent").filter((e) => e.role === "peer" && e.session === id).at(-1)?.name;
    const listed = async () => jsonRows(await s.tool("list_agents").execute("c", { which: "peers" })).find((a) => a.id === id)?.name;
    await pollUntil(() => latest() === "koa - Real - kido");
    fx.clientEvent({ type: "var", pane: "pane_2", name: "koa.name", value: "Real" });
    await pollUntil(() => latest() === "Real", 2000, "name from the var event");
    fx.clientEvent({ type: "var", pane: "pane_2", name: "koa.name", value: "Renamed" });
    await pollUntil(() => latest() === "Renamed", 2000, "name from a rename");
    fx.setPanes([selfPane()]);
    const before = fx.clientLayouts().length;
    fx.setClientPanes([selfPane()]);
    await pollUntil(() => fx.clientLayouts().length > before, 2000, "layout without the peer");
    assert.equal(await listed(), "Renamed");
    const snapshots = fx.clientLayouts().length;
    fx.dropClient();
    await pollUntil(() => fx.streamOpens("/client") === 2 && fx.clientLayouts().length > snapshots, 2000, "snapshot of the reconnect");
    fx.setClientPanes([selfPane(), agentPane({ pane: "pane_2", session: id, name: "Final", title: "koa - Real - kido" })]);
    await pollUntil(() => latest() === "Final", 2000, "name corrected by a layout");
    assert.equal(await listed(), "Final");
    assert.equal(readFileSync(join(fx.dir, "client-fed.jsonl"), "utf8").trim().split("\n").length, 2, "the reconnect replays no event from before its snapshot");
    fx.clientEvent({ type: "var_deleted", pane: "pane_2", name: "koa.name" });
    fx.clientEvent({ type: "title", pane: "pane_2", title: "koa - Later - kido" });
    await pollUntil(() => latest() === "koa - Later - kido", 2000, "latest title without a name");
  } finally { await fx.restore(); }
});

test("a refused koa.name write is retried until koa.name is set", async () => {
  const fx = makeFixture();
  try {
    const fail = join(fx.dir, "var-fail");
    writeFileSync(fail, "");
    await withEnv({ KO_FAKE_VAR_FAIL: fail }, async () => {
      fx.setPanes([selfPane({ vars: { "koa.name": "" } })]);
      await startSession(fx, { name: "Named" });
      await pollUntil(() => get(fx.row("pane_1"), "vars", "koa.name") === "Named", 3000, "koa.name written after the refusal");
    });
  } finally { await fx.restore(); }
});
