import { test } from "node:test";

import assert from "node:assert/strict";

import { makeFixture, agentPane, selfPane, startSession, text, exited, type Fixture } from "./ko-pi-fixture.ts";

const INSTANCE = "a".repeat(32);

// top (root) > boss > self > kid; boss > peer > cousin; top has a root sibling; one agent in another ko session.
function tree(fx: Fixture): void {
  fx.setPanes([
    selfPane({ parent: "pane_2", cwd: "/work/self" }),
    agentPane({ pane: "pane_2", session: "boss-session", name: "boss", parent: "pane_9", state: "working" }),
    agentPane({ pane: "pane_3", session: "peer-session", name: "Peer", parent: "pane_2" }),
    agentPane({ pane: "pane_4", session: "cousin-session", name: "cousin", parent: "pane_3" }),
    agentPane({ pane: "pane_5", session: "kid-session", name: "kid", parent: "pane_1", close: "on_exit", cwd: "/work/kid" }),
    agentPane({ pane: "pane_6", session: "rootpeer-session", name: "rootpeer" }),
    agentPane({ pane: "pane_7", session: "elsewhere-session", name: "elsewhere", koSession: "session_2" }),
    agentPane({ pane: "pane_8", session: "abc12345-one", name: "twin", parent: "pane_2" }),
    agentPane({ pane: "pane_10", session: "abc12345-two", name: "twin", parent: "pane_2" }),
    agentPane({ pane: "pane_9", session: "top-session", name: "top" }),
  ]);
}

const kid = { role: "subagent", name: "kid", session: "kid-session", model: "acme/m:high", fork: false, cwd: "/work/kid", pane: { instance: INSTANCE, pane: "pane_5" } };

test("list_agents lists the scope with each relationship, depth and the own subagent's report", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    const s = await startSession(fx, { name: "Self" });
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { owner: "self-session", ...kid } });
    s.entries.push({ type: "custom", customType: "ko-pi.work", data: { owner: "self-session", child: "kid-session", at: 1 } });
    s.entries.push({ type: "custom", customType: "ko-pi.report", data: { owner: "self-session", child: "kid-session", name: "kid", text: "x".repeat(1500), at: 2, id: "r" } });
    const list = s.tools.get("list_agents");
    const rows = JSON.parse(text(await list.execute("c", {}))) as Array<Record<string, unknown>>;
    const byName = new Map(rows.map((row) => [row.name, row]));
    assert.deepEqual(rows.map((row) => row.name).sort(), ["Peer", "boss", "kid", "rootpeer", "top", "twin", "twin"].sort());
    assert.deepEqual(
      rows.filter((row) => row.name !== "twin").map((row) => [row.name, row.relationship, row.depth, row.kind]).sort(),
      [
        ["Peer", "peer", 2, "subagent"],
        ["boss", "parent", 1, "subagent"],
        ["kid", "own", 3, "subagent"],
        ["rootpeer", "relative", 0, "agent"],
        ["top", "relative", 0, "agent"],
      ].sort(),
    );
    const own = byName.get("kid")!;
    assert.equal(own.state, "running");
    assert.equal(own.reported, true);
    assert.equal(own.model, "acme/m:high");
    assert.equal((own.report as string).length, 1000, "the report is capped at 1000 bytes");
    assert.equal(own.parent, "self-session");
    assert.equal(own.canMessage, true);
    assert.equal(byName.get("boss")!.status, "working");
    assert.equal(byName.get("boss")!.parent, "top-session");
    assert.equal(byName.has("cousin"), false, "a cousin is outside the scope");
    assert.equal(byName.has("elsewhere"), false, "another session is outside it too");

    const peers = JSON.parse(text(await list.execute("c", { which: "peers" }))) as Array<Record<string, unknown>>;
    assert.deepEqual(peers.map((row) => row.name).sort(), ["Peer", "twin", "twin"]);
    const subs = JSON.parse(text(await list.execute("c", { which: "subagents" }))) as Array<Record<string, unknown>>;
    assert.deepEqual(subs.map((row) => row.name), ["kid"]);
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
    const rows = JSON.parse(text(await s.tools.get("list_agents").execute("c", {}))) as Array<Record<string, unknown>>;
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

test("an ended subagent lists from the registry, with the cause of its lingering pane or a gone pane", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "pane_5", session: "kid-session", name: "kid", parent: "pane_1", dead: exited(1) })]);
    const s = await startSession(fx);
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { owner: "self-session", ...kid } });
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { owner: "self-session", ...kid, name: "old", session: "old-session", pane: { instance: INSTANCE, pane: "pane_77" } } });
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { owner: "other-session", ...kid, name: "foreign", session: "foreign-session" } });
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { owner: "self-session", ...kid, name: "stale", session: "stale-session", pane: { instance: "b".repeat(32), pane: "pane_1" } } });
    const rows = JSON.parse(text(await s.tools.get("list_agents").execute("c", {}))) as Array<Record<string, unknown>>;
    assert.deepEqual(
      rows.map((row) => [row.name, row.state, row.ended, row.canMessage]).sort(),
      [
        ["kid", "ended", "exit 1", false],
        ["old", "ended", "its pane is gone", false],
        ["stale", "ended", "its pane is gone", false],
      ],
      "a child of another owner is not listed; a pane of another server instance is gone",
    );
  } finally {
    await fx.restore();
  }
});

test("message_agent resolves by name, session id, unique prefix and pane, and explains every refusal", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    const s = await startSession(fx, { name: "Self" });
    const message = s.tools.get("message_agent");
    const send = async (to: string) => text(await message.execute("c", { to, message: "x" }));

    assert.equal(await send("peer"), "delivered to Peer", "a name is caseless");
    assert.equal(await send("@Peer"), "delivered to Peer", "a leading @ is ignored");
    assert.equal(await send("peer-session"), "delivered to Peer");
    assert.equal(await send("pane_3"), "delivered to Peer", "a pane id is an address");
    assert.equal(await send("rootpeer-s"), "delivered to rootpeer", "a unique prefix resolves");
    assert.equal(await send("@Peer (session peer-session)"), "delivered to Peer", "a mention names the session");
    assert.equal(await send("abc12345-one"), "delivered to twin", "an exact session id wins over a prefix");
    assert.equal(await send("abc12345"), 'could not message abc12345: "abc12345" matches several by id: abc12345-one (twin), abc12345-two (twin)');
    assert.equal(await send("abc"), "could not message abc: id prefixes need at least 8 characters");
    assert.equal(await send("twin"), 'could not message twin: "twin" matches several by name: abc12345-one (twin), abc12345-two (twin)');
    assert.equal(await send("nope"), 'could not message nope: no agent session matches "nope"');
    assert.equal(await send("Self"), "Self is this agent");
    assert.equal(await send("elsewhere"), "could not message elsewhere: elsewhere (elsewhere-session) is in another session, not this one");

    assert.equal(text(await message.execute("c", { to: "Peer", message: "" })), "could not message Peer: the message is empty; nothing sent");
    assert.equal(text(await message.execute("c", { to: "Peer", message: "bad:\ud800:end" })), "could not message Peer: the message is not valid UTF-8");

    const posts = fx.posts("/panes/pane_3/messages");
    assert.equal(posts.length, 5);
    assert.match(posts[0]!.id, /^[A-Za-z0-9_-]{22}$/, "128 random bits as 22 base64url characters");
    assert.equal(new Set(posts.map((post) => post.id)).size, 5, "one fresh id for each intent");
    const { id: _id, ...body } = posts[0]!;
    assert.deepEqual(body, { kind: "message", text: "x" });
  } finally {
    await fx.restore();
  }
});

test("a send resends the same id on a delivered or io answer, and reports what the last answer was", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    const s = await startSession(fx);
    const message = s.tools.get("message_agent");
    const call = async (script: Array<{ status: number; body: unknown }>) => {
      fx.scriptSends(script);
      const before = fx.posts("/panes/pane_3/messages").length;
      const said = text(await message.execute("c", { to: "Peer", message: "hello" }));
      return { said, posts: fx.posts("/panes/pane_3/messages").slice(before) };
    };
    const io = { status: 500, body: { kind: "io", message: "the queue broke" } };
    const delivered = { status: 200, body: { state: "delivered", seq: 1 } };
    const acked = { status: 200, body: { state: "acked", seq: 1 } };

    const lost = await call([delivered, io, acked]);
    assert.equal(lost.said, "delivered to Peer");
    assert.equal(lost.posts.length, 3);
    assert.equal(new Set(lost.posts.map((post) => post.id)).size, 1, "the resends carry the one id");

    const stuck = await call([delivered, delivered, delivered]);
    assert.equal(stuck.posts.length, 3, "three tries, then the last state");
    assert.equal(stuck.said, "sent to Peer: written to its message stream, not yet confirmed");

    const down = await call([io, io, io]);
    assert.equal(down.said, "could not message Peer: the queue broke");

    const queued = await call([{ status: 200, body: { state: "queued", seq: 4 } }]);
    assert.equal(queued.posts.length, 1, "a queued answer is final");
    assert.match(queued.said, /^queued for Peer: it is not receiving messages now/);

    const refused = await call([{ status: 409, body: { kind: "refused", message: "pane_3 is not in your scope" } }]);
    assert.equal(refused.said, "could not message Peer: Peer refused the message: pane_3 is not in your scope");
    const gone = await call([{ status: 410, body: { kind: "gone", message: "pane_3 is dead" } }]);
    assert.equal(gone.said, "could not message Peer: Peer is dead: pane_3 is dead");
  } finally {
    await fx.restore();
  }
});

test("steer and interrupt-and-steer send their kinds, and a message to a working agent says it waits", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    const s = await startSession(fx);
    const message = s.tools.get("message_agent");
    assert.equal(text(await message.execute("c", { to: "boss", message: "a" })), "queued for boss: it is running and reads this when its current turn ends; to reach it now, use message_agent with mode steer");
    assert.equal(text(await message.execute("c", { to: "boss", message: "b", mode: "steer" })), "delivered to boss");
    assert.equal(text(await message.execute("c", { to: "boss", message: "c", mode: "interrupt-and-steer" })), "delivered to boss");
    assert.deepEqual(fx.posts("/panes/pane_2/messages").map((post) => post.kind), ["message", "steer", "interrupt"]);
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
    s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { owner: "self-session", ...kid } });
    const read = s.tools.get("read_report");
    assert.equal(text(await read.execute("c", { agent: "kid" })), "kid has not reported");
    s.entries.push({ type: "custom", customType: "ko-pi.report", data: data({ text: "first", at: 1 }) });
    s.entries.push({ type: "custom", customType: "ko-pi.report", data: data({ text: "y".repeat(6000), at: 2 }) });
    assert.equal(text(await read.execute("c", { agent: "kid" })), "y".repeat(6000), "the whole text, past every cap");
    const all = text(await read.execute("c", { agent: "@kid", which: "all" }));
    assert.match(all, /^--- report 1 of 2, .*---\nfirst\n\n--- report 2 of 2/);
    assert.match(text(await read.execute("c", { agent: "Peer" })), /no agent session matches "Peer"/, "a peer is no subagent of this session");
  } finally {
    await fx.restore();
  }
});
