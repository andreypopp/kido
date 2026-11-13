import { test } from "node:test";

import assert from "node:assert/strict";

import { makeFixture, agentPane, selfPane, startSession, createChannel, stubAgent, text, type Fixture, at, jsonRows, get, getStr } from "./koa-agent-fixture.ts";
import type { Agent } from "./koa-agents.ts";
import type { InProcessMessage } from "./records.ts";

type Stub = Agent & { received: InProcessMessage[] };
const stub = (id: string, name: string, parent: Agent | undefined, status = "idle"): Stub => {
  const received: InProcessMessage[] = [];
  return Object.assign(stubAgent({ id, name, parent, children: [], runtime: {}, stopping: false, extension: { receive: async (message: InProcessMessage) => { received.push(message); } }, view: { state: { name, cwd: `/work/${name}`, dialogs: [] }, root: { value: status } } }), { received });
};

// top > boss > self > kid; boss > Peer, twin, twin; a cousin outside the scope; roots of other panes: rootpeer, and one in another ko session.
function tree(fx: Fixture) {
  fx.setPanes([
    selfPane({ cwd: "/work/self" }),
    agentPane({ pane: "pane_6", session: "rootpeer-session", name: "rootpeer" }),
    agentPane({ pane: "pane_7", session: "elsewhere-session", name: "elsewhere", koSession: "session_2" }),
  ]);
  const top = stub("top-session", "top", undefined);
  const boss = stub("boss-session", "boss", top, "working");
  const channel = createChannel();
  const kid = stub("kid-session", "kid", channel.host.self);
  const peer = stub("peer-session", "Peer", boss);
  const twins = [stub("abc12345-one", "twin", boss), stub("abc12345-two", "twin", boss)];
  const cousin = stub("cousin-session", "cousin", peer);
  const scope = [{ agent: boss, relationship: "parent" as const }, { agent: top, relationship: "relative" as const }, { agent: peer, relationship: "peer" as const }, ...twins.map(agent => ({ agent, relationship: "peer" as const })), { agent: kid, relationship: "own" as const }];
  Object.assign(channel.host.self, { parent: boss, name: "Self" });
  Object.assign(channel.host, { scope: () => scope, find: (id: string) => [...scope.map(entry => entry.agent), cousin].find(agent => agent.id === id) });
  return { channel, boss, peer, kid, top, twins };
}

const kid = { role: "subagent", name: "kid", session: "kid-session", model: "acme/m:high", fork: false, cwd: "/work/kid" };

test("list_agents lists the scope with each relationship, depth and the own subagent's report; another pane's subagents never list", async () => {
  const fx = makeFixture();
  try {
    const { channel } = tree(fx);
    const s = await startSession(fx, { name: "Self", channel });
    s.entries.push({ type: "custom", customType: "koa.agent", data: { owner: "self-session", ...kid } });
    s.entries.push({ type: "custom", customType: "koa.work", data: { owner: "self-session", child: "kid-session", at: 1 } });
    s.entries.push({ type: "custom", customType: "koa.report", data: { owner: "self-session", child: "kid-session", name: "kid", text: "x".repeat(1500), at: 2 } });
    const list = s.tool("list_agents");
    const rows = jsonRows(await list.execute("c", {}));
    const byName = new Map(rows.map((row) => [row.name, row]));
    assert.deepEqual(rows.map((row) => row.name).sort(), ["Peer", "boss", "kid", "rootpeer", "top", "twin", "twin"].sort());
    assert.deepEqual(
      rows.filter((row) => row.name !== "twin").map((row) => [row.name, row.relationship, row.depth, row.kind, JSON.stringify(row.where)]).sort(),
      [
        ["Peer", "peer", 2, "subagent", '{"type":"process"}'],
        ["boss", "parent", 1, "subagent", '{"type":"process"}'],
        ["kid", "own", 3, "subagent", '{"type":"process"}'],
        ["rootpeer", "relative", 0, "agent", '{"type":"pane","pane":"pane_6","window":"window_6"}'],
        ["top", "relative", 0, "agent", '{"type":"process"}'],
      ].sort(),
    );
    const own = byName.get("kid");
    assert.ok(own);
    assert.equal(own.state, "running");
    assert.equal(own.reported, true);
    assert.equal(own.model, "acme/m:high");
    assert.equal(getStr(own, "report").length, 1000, "the report is capped at 1000 bytes");
    assert.equal(own.parent, "self-session");
    assert.equal(own.canMessage, true);
    assert.equal(byName.get("boss")?.status, "working");
    assert.equal(byName.get("boss")?.parent, "top-session");
    assert.equal(byName.has("cousin"), false, "a cousin is outside the scope");
    assert.equal(byName.has("elsewhere"), false, "another session is outside it too");
    assert.ok(rows.every((row) => !("pane" in row) && !("window" in row)), "where is the one place of a row's pane and window");
    assert.deepEqual(jsonRows(await list.execute("c", { which: "peers" })).map((row) => row.name).sort(), ["Peer", "twin", "twin"]);
    assert.deepEqual(jsonRows(await list.execute("c", { which: "subagents" })).map((row) => row.name), ["kid"]);
  } finally {
    await fx.restore();
  }
});

test("runtime agent placement uses the row before routed pi variables", async () => {
  const fx = makeFixture();
  try {
    const row = agentPane({ pane: "pane_2", session: "runtime-session", name: "runtime-pi", cwd: "/runtime/work", vars: { "pi.runtime": { name: "wrong", cwd: "/wrong" } } });
    row.runtime = "actual";
    row.status = { kind: { type: "runtime", pane: { type: "pi_agent", session: "classified-session", status: { since: 0, state: { type: "idle" } } } } };
    const host = agentPane({ pane: "pane_3", session: "host-session", name: "host-pi", cwd: "/host", vars: { "pi.runtime": { name: "route", cwd: "/routed" } } });
    const shell = agentPane({ pane: "pane_4", session: "stale-session", name: "stale-shell", vars: { "pi.runtime": { name: "wrong", cwd: "/wrong" } } });
    shell.status = { kind: { type: "host", pane: { type: "terminal", phase: { type: "idle" } } } };
    const ssh = agentPane({ pane: "pane_5", session: "ssh-session", name: "ssh-agent", vars: { "pi.runtime": { name: "wrong", cwd: "/wrong" } } });
    ssh.status = { kind: { type: "ssh", destination: "host", pane: { type: "agent", name: "pi", status: { since: 0, state: { type: "idle" } } } } };
    fx.setPanes([selfPane(), row, host, shell, ssh]);
    const s = await startSession(fx);
    const rows = jsonRows(await s.tool("list_agents").execute("c", {}));
    const agent = rows.find((row) => row.name === "runtime-pi");
    assert.equal(agent?.id, "classified-session");
    assert.equal(agent?.runtime, "actual");
    assert.equal(agent?.cwd, "/runtime/work");
    const routed = rows.find((row) => row.name === "host-pi");
    assert.equal(routed?.runtime, "route");
    assert.equal(routed?.cwd, "/routed");
    assert.deepEqual(rows.map((row) => row.name).sort(), ["host-pi", "runtime-pi"]);
  } finally {
    await fx.restore();
  }
});

test("an ended subagent lists from the registry with its cause: stopped, or koa restarted when nothing says so", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    s.entries.push({ type: "custom", customType: "koa.agent", data: { owner: "self-session", ...kid } });
    s.entries.push({ type: "custom", customType: "koa.agent", data: { owner: "self-session", ...kid, name: "old", session: "old-session" } });
    s.entries.push({ type: "custom", customType: "koa.ended", data: { owner: "self-session", child: "old-session", cause: "stopped" } });
    s.entries.push({ type: "custom", customType: "koa.agent", data: { owner: "other-session", ...kid, name: "foreign", session: "foreign-session" } });
    const rows = jsonRows(await s.tool("list_agents").execute("c", {}));
    assert.deepEqual(
      rows.map((row) => [row.name, row.state, row.ended, row.canMessage]).sort(),
      [["kid", "ended", "koa restarted", false], ["old", "ended", "stopped", false]],
      "a child of another owner is not listed",
    );
  } finally {
    await fx.restore();
  }
});

test("message_agent resolves by name, session id, unique prefix and pane, delivers in process or posts to a pane, and explains every refusal", async () => {
  const fx = makeFixture();
  try {
    const { channel, peer, twins } = tree(fx);
    const s = await startSession(fx, { name: "Self", channel });
    const message = s.tool("message_agent");
    const outcomes = new Map<string, unknown>();
    const send = async (to: string) => { const result = await message.execute('c', { to, message: 'x' }); outcomes.set(to, get(result.details, "outcome")); return text(result); };

    assert.equal(await send("peer"), "delivered to Peer", "a name is caseless");
    assert.equal(await send("@Peer"), "delivered to Peer", "a leading @ is ignored");
    assert.equal(await send("peer-session"), "delivered to Peer");
    assert.equal(await send("@Peer (session peer-session)"), "delivered to Peer", "a mention names the session");
    assert.equal(await send("abc12345-one"), "delivered to twin", "an exact session id wins over a prefix");
    assert.equal(await send("rootpeer-s"), "delivered to rootpeer", "a unique prefix resolves");
    assert.equal(await send("pane_6"), "delivered to rootpeer", "a pane id is an address");
    assert.equal(await send("abc12345"), 'could not message abc12345: "abc12345" matches several by id: abc12345-one (twin), abc12345-two (twin)');
    assert.equal(await send("abc"), "could not message abc: id prefixes need at least 8 characters");
    assert.equal(await send("twin"), 'could not message twin: "twin" matches several by name: abc12345-one (twin), abc12345-two (twin)');
    assert.equal(await send("nope"), 'could not message nope: no agent session matches "nope"');
    assert.equal(await send("Self"), "Self is this agent");
    assert.deepEqual(outcomes.get('peer'), { ok: true });
    assert.deepEqual(outcomes.get('nope'), { ok: false, failure: 'not_found', message: 'no agent session matches "nope"' });
    assert.deepEqual(outcomes.get('twin'), { ok: false, failure: 'ambiguous', message: '"twin" matches several by name: abc12345-one (twin), abc12345-two (twin)' });
    assert.equal(await send("elsewhere"), "could not message elsewhere: elsewhere (elsewhere-session) is in another session, not this one");
    assert.equal(text(await message.execute("c", { to: "Peer", message: "" })), "could not message Peer: the message is empty; nothing sent");
    assert.equal(text(await message.execute("c", { to: "Peer", message: "bad:\ud800:end" })), "could not message Peer: the message is not valid UTF-8");

    assert.deepEqual(peer.received.map((m) => [m.kind, m.text, "relation" in m ? m.relation : undefined]), [["message", "x", "sibling"], ["message", "x", "sibling"], ["message", "x", "sibling"], ["message", "x", "sibling"]]);
    assert.equal(twins[0]?.received.length, 1);
    const posts = fx.posts("/panes/pane_6/messages");
    assert.equal(posts.length, 2);
    assert.match(getStr(at(posts, 0), "id"), /^[A-Za-z0-9_-]{22}$/, "128 random bits as 22 base64url characters");
    assert.notEqual(at(posts, 0).id, at(posts, 1).id, "one fresh id for each intent");
    const { id: _id, ...body } = at(posts, 0);
    assert.deepEqual(body, { kind: "message", text: "x", data: { from: { session: "self-session", name: "Self" } } }, "a sender that is not its pane's root names itself");

    assert.equal(text(await message.execute("c", { to: "pane_7/0123456789abcdef", message: "hi" })), "delivered to pane_7/0123456789abcdef");
    const explicit = at(fx.posts("/panes/pane_7/messages"), 0);
    assert.deepEqual(explicit.data, { to: "0123456789abcdef", from: { session: "self-session", name: "Self" } });
  } finally {
    await fx.restore();
  }
});

test("a send to a pane resends the same id on a delivered or io answer, and reports what the last answer was", async () => {
  const fx = makeFixture();
  try {
    const { channel } = tree(fx);
    const s = await startSession(fx, { channel });
    const message = s.tool("message_agent");
    const call = async (script: Array<{ status: number; body: unknown }>) => {
      fx.scriptSends(script);
      const before = fx.posts("/panes/pane_6/messages").length;
      const result = await message.execute('c', { to: 'rootpeer', message: 'hello' });
      return { said: text(result), details: result.details, posts: fx.posts("/panes/pane_6/messages").slice(before) };
    };
    const io = { status: 500, body: { kind: "io", message: "the queue broke" } };
    const delivered = { status: 200, body: { state: "delivered", seq: 1 } };
    const acked = { status: 200, body: { state: "acked", seq: 1 } };

    const lost = await call([delivered, io, acked]);
    assert.equal(lost.said, "delivered to rootpeer");
    assert.deepEqual(lost.details, { to: 'rootpeer', outcome: { ok: true } });
    assert.equal(lost.posts.length, 3);
    assert.equal(new Set(lost.posts.map((post) => post.id)).size, 1, "the resends carry the one id");
    const stuck = await call([delivered, delivered, delivered]);
    assert.equal(stuck.posts.length, 3, "three tries, then the last state");
    assert.equal(stuck.said, "sent to rootpeer: written to its message stream, not yet confirmed");
    const down = await call([io, io, io]);
    assert.equal(down.said, "could not message rootpeer: the queue broke");
    assert.deepEqual(get(down.details, "outcome"), { ok: false, failure: 'error', message: 'the queue broke' });
    const queued = await call([{ status: 200, body: { state: "queued", seq: 4 } }]);
    assert.equal(queued.posts.length, 1, "a queued answer is final");
    assert.match(queued.said, /^queued for rootpeer: it is not receiving messages now/);
    const refused = await call([{ status: 409, body: { kind: "refused", message: "pane_6 is not in your scope" } }]);
    assert.equal(refused.said, "could not message rootpeer: rootpeer refused the message: pane_6 is not in your scope");
    assert.deepEqual(get(refused.details, "outcome"), { ok: false, failure: 'refused', message: 'pane_6 is not in your scope' });
    const gone = await call([{ status: 410, body: { kind: "gone", message: "pane_6 is dead" } }]);
    assert.equal(gone.said, "could not message rootpeer: rootpeer is dead: pane_6 is dead");
    assert.deepEqual(get(gone.details, "outcome"), { ok: false, failure: 'gone', message: 'pane_6 is dead' });
  } finally {
    await fx.restore();
  }
});

test("steer and interrupt-and-steer reach an agent of the process as their own kinds, with the relation from the tree", async () => {
  const fx = makeFixture();
  try {
    const { channel, boss, kid: child } = tree(fx);
    const s = await startSession(fx, { channel });
    s.entries.push({ type: "custom", customType: "koa.agent", data: { owner: "self-session", ...kid } });
    const message = s.tool("message_agent");
    assert.equal(text(await message.execute("c", { to: "boss", message: "a" })), "delivered to boss");
    assert.equal(text(await message.execute("c", { to: "boss", message: "b", mode: "steer" })), "delivered to boss");
    assert.equal(text(await message.execute("c", { to: "boss", message: "c", mode: "interrupt-and-steer" })), "delivered to boss");
    assert.deepEqual(boss.received.map((m) => [m.kind, "relation" in m ? m.relation : undefined]), [["message", "child"], ["steer", "child"], ["interrupt", "child"]]);
    await message.execute("c", { to: "kid", message: "carry on" });
    assert.deepEqual(child.received.map((m) => ["relation" in m ? m.relation : undefined]), [["parent"]]);
    assert.deepEqual(s.entries.filter((entry) => entry.customType === "koa.work").map((entry) => entry.data.child), ["kid-session"], "a message to an own child is work for it");
  } finally {
    await fx.restore();
  }
});

test("read_report returns the whole last report or all of them, only for an own subagent", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    const s = await startSession(fx);
    const data = (extra: Record<string, unknown>) => ({ owner: "self-session", child: "kid-session", name: "kid", id: "r", ...extra });
    s.entries.push({ type: "custom", customType: "koa.agent", data: { owner: "self-session", ...kid } });
    const read = s.tool("read_report");
    assert.equal(text(await read.execute("c", { agent: "kid" })), "kid has not reported");
    s.entries.push({ type: "custom", customType: "koa.report", data: data({ text: "first", at: 1 }) });
    s.entries.push({ type: "custom", customType: "koa.report", data: data({ text: "y".repeat(6000), at: 2 }) });
    assert.equal(text(await read.execute("c", { agent: "kid" })), "y".repeat(6000), "the whole text, past every cap");
    const all = text(await read.execute("c", { agent: "@kid", which: "all" }));
    assert.match(all, /^--- report 1 of 2, .*---\nfirst\n\n--- report 2 of 2/);
    assert.match(text(await read.execute("c", { agent: "Peer" })), /no agent session matches "Peer"/, "a peer is no subagent of this session");
  } finally {
    await fx.restore();
  }
});
