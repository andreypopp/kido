import { test } from "node:test";

import assert from "node:assert/strict";

import { join } from "node:path";
import { writeFileSync } from "node:fs";

import { makeFixture, agentPane, selfPane, startSession, text, entriesOf, withEnv, asSubagent, savedSession, pollUntil } from "./ko-pi-fixture.ts";

const INSTANCE = "a".repeat(32);

type Body = Record<string, any>;

const env = (body: Body, name: string): string | undefined => (body.env as Array<{ name: string; value: string }>).find((v) => v.name === name)?.value;

test("spawn_agent creates one pane with a parent, close on_exit, the task as a variable and the edge in its environment", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    const result = await s.tools.get("spawn_agent").execute("c", { name: "worker", task: "build it", model: undefined });
    const reply = text(result);
    const [body] = fx.posts("/panes") as Body[];
    assert.equal(fx.posts("/panes").length, 1, "one POST makes the pane: no layout edit, no rename");
    const session = result.details.session as string;
    assert.match(session, /^[0-9a-f]{32}$/);
    const ko = join(fx.binDir, "ko");
    assert.deepEqual(body!.command, { type: "argv", argv: [ko, "shell", "--", "ko-pi", "--session-id", session, "--name", "worker", "--model", "acme/caller:high"] });
    assert.deepEqual({ name: body!.name, cwd: body!.cwd, parent: body!.parent, close: body!.close, session: body!.session }, { name: "worker", cwd: process.cwd(), parent: "pane_1", close: "on_exit", session: undefined });
    assert.equal(env(body!, "KO_AGENT_SESSION"), session);
    assert.equal(env(body!, "KO_AGENT_PARENT_SESSION"), "self-session");
    assert.equal(env(body!, "KO_AGENT_TRUSTED_CWD"), undefined, "a session that does not trust its project passes no trust");
    assert.deepEqual(body!.vars, { "ko-pi.task": { text: "build it", from: { session: "self-session", name: "Self", pane: "pane_1" } } });

    assert.match(reply, new RegExp(`^spawned worker \\(session ${session}, window window_10, pane pane_10\\); session id is what resume_from takes later; its result arrives as a notice`));
    assert.match(reply, /list_agents lists this agent and stop_agent stops it/);
    const [child] = entriesOf(s, "ko-pi.child");
    assert.deepEqual(child, { owner: "self-session", at: child!.at, name: "worker", session, model: "acme/caller:high", fork: false, cwd: process.cwd(), pane: { instance: INSTANCE, pane: "pane_10" } });
    assert.deepEqual(entriesOf(s, "ko-pi.work").map((work) => [work.owner, work.child]), [["self-session", session]]);
    assert.equal(fx.row("pane_10")?.parent, "pane_1");
  } finally {
    await fx.restore();
  }
});

test("a toplevel spawn is one POST with the session and neither parent nor close nor edge, and records no child", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane({ session: "session_3" })]);
    const s = await startSession(fx);
    const reply = text(await s.tools.get("spawn_agent").execute("c", { name: "peer", task: "go", toplevel: true }));
    const [body] = fx.posts("/panes") as Body[];
    assert.equal(fx.posts("/panes").length, 1);
    assert.deepEqual({ session: body!.session, parent: body!.parent, close: body!.close }, { session: "session_3", parent: undefined, close: undefined });
    assert.equal(env(body!, "KO_AGENT_PARENT_SESSION"), undefined);
    assert.ok(env(body!, "KO_AGENT_SESSION"));
    assert.equal(body!.vars["ko-pi.task"].text, "go");
    assert.match(reply, /independent peer; no report or ending notice$/);
    assert.deepEqual(entriesOf(s, "ko-pi.child"), []);
    assert.deepEqual(entriesOf(s, "ko-pi.work"), []);
  } finally {
    await fx.restore();
  }
});

test("spawn_agent refuses what it must, before it posts", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([
      selfPane({ parent: "pane_2" }),
      agentPane({ pane: "pane_2", session: "boss-session", name: "boss", parent: "pane_9" }),
      agentPane({ pane: "pane_9", session: "top-session", name: "top" }),
      agentPane({ pane: "pane_4", session: "elder-session", name: "elder", close: "keep" }),
    ]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_agent");
    const refused = async (params: Record<string, unknown>) => text(await spawn.execute("c", params));
    assert.equal(await refused({ name: "kid", task: "x" }), "could not spawn agent: refusing to spawn at depth 3: maximum nesting is 2 (root 0, subagent 1, subagent 2)");
    assert.equal(await refused({ name: "../x", task: "x" }), 'could not spawn agent: refusing window name "../x": it must be one path-safe name, not an empty, dot or slashed path');
    assert.equal(await refused({ name: "kid", task: "" }), "could not spawn agent: task is required unless resuming without fork");
    assert.equal(await refused({ name: "kid", task: "y".repeat(1_100_000) }), "could not spawn agent: the task does not fit the 1044480 byte limit of a pane variable");
    assert.equal(await refused({ name: "elder", task: "x", toplevel: true }), 'could not spawn agent: the name "elder" is already taken by a live agent in this session');
    assert.equal(await refused({ name: "kid", task: "x", cwd: "/nonexistent-dir-for-ko-pi" }), "could not spawn agent: cwd is not a directory: /nonexistent-dir-for-ko-pi");
    fx.setPi("#!/bin/sh\nprintf 'provider model\\nacme caller\\n'\n");
    assert.match(await refused({ name: "kid", task: "x", model: "acme/none" }), /^could not spawn agent: model "acme\/none" is not a model of a configured provider; configured: acme\/\{caller\}$/);
    assert.deepEqual(fx.posts("/panes"), []);
  } finally {
    await fx.restore();
  }
});

test("a name taken by an own child is refused, and a failed POST leaves no registry entry", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_agent");
    await withEnv({ KO_FAKE_SPAWN_FAIL: "no room" }, async () => {
      assert.equal(text(await spawn.execute("c", { name: "worker", task: "x" })), "could not spawn agent: no room");
    });
    assert.deepEqual(entriesOf(s, "ko-pi.child"), []);
    await spawn.execute("c", { name: "worker", task: "x" });
    assert.match(text(await spawn.execute("c", { name: "Worker", task: "x" })), /^could not spawn agent: the name "Worker" is already taken by one of this session's agents; message it instead$/);
    const concurrent = await Promise.all([spawn.execute("c", { name: "twin", task: "x" }), spawn.execute("c", { name: "twin", task: "x" })]);
    assert.equal(concurrent.filter((result) => text(result).startsWith("spawned twin")).length, 1, "two spawns of one name make one pane");
  } finally {
    await fx.restore();
  }
});

test("resume_from continues a saved session by --session in its directory; fork copies it under a new id", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_agent");
    const sessions = join(fx.dir, "sessions", "caller");
    const cwd = fx.dir;
    const file = savedSession(sessions, cwd, "0123456789abcdef0123456789abcdef");
    const resumed = await spawn.execute("c", { name: "again", task: "", resume_from: "01234567" });
    assert.match(text(resumed), /^spawned again \(session 0123456789abcdef0123456789abcdef,/);
    const [body] = fx.posts("/panes") as Body[];
    assert.deepEqual((body!.command.argv as string[]).slice(3, 7), ["ko-pi", "--session", file, "--name"]);
    assert.equal(body!.cwd, cwd, "the recorded directory");
    assert.equal(body!.vars, undefined, "an empty task is no variable");
    assert.deepEqual(entriesOf(s, "ko-pi.work"), [], "and owes no report");

    fx.setPanes([selfPane(), agentPane({ pane: "pane_30", session: "0123456789abcdef0123456789abcdef", name: "again", parent: "pane_1" })]);
    assert.equal(text(await spawn.execute("c", { name: "again", task: "", resume_from: "0123456789abcdef0123456789abcdef" })), "could not spawn agent: session 0123456789abcdef0123456789abcdef is live in a pane");

    const forked = await spawn.execute("c", { name: "copy", task: "do it differently", resume_from: "0123456789abcdef0123456789abcdef", fork: true });
    assert.match(text(forked), /, forked from session 0123456789abcdef0123456789abcdef;/);
    const argv = (fx.posts("/panes").at(-1)!.command.argv as string[]).slice(3);
    assert.deepEqual(argv.slice(0, 2), ["ko-pi", "--session-id"]);
    assert.notEqual(argv[2], "0123456789abcdef0123456789abcdef");
    assert.deepEqual(argv.slice(-2), ["--fork", file]);
  } finally {
    await fx.restore();
  }
});

test("a message to an ended subagent restarts it by --session-id in its recorded cwd, with the message as its task; two at once restart it once", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    s.entries.push({ type: "custom", customType: "ko-pi.child", data: { owner: "self-session", name: "kid", session: "kid-session", model: "acme/m:low", fork: false, cwd: "/work/kid", pane: { instance: INSTANCE, pane: "pane_77" } } });
    const message = s.tools.get("message_agent");
    const results = await Promise.all([message.execute("c", { to: "kid", message: "carry on" }), message.execute("c", { to: "kid", message: "also this" })]);
    const texts = results.map(text);
    const winner = texts.findIndex((t) => t.startsWith("restarted kid in pane pane_10; "));
    assert.notEqual(winner, -1, texts.join("|"));
    const winning = ["carry on", "also this"][winner]!;
    const losing = ["carry on", "also this"][1 - winner]!;
    const posts = fx.posts("/panes") as Body[];
    assert.equal(posts.length, 1, "one restart");
    const argv = posts[0]!.command.argv as string[];
    assert.deepEqual(argv.slice(3), ["ko-pi", "--session-id", "kid-session", "--name", "kid", "--model", "acme/m:low"]);
    assert.equal(posts[0]!.cwd, "/work/kid");
    assert.equal(posts[0]!.parent, "pane_1");
    assert.equal(posts[0]!.vars["ko-pi.task"].text, winning);
    assert.ok(texts[1 - winner]!.startsWith("queued for kid:"), "the other message goes to the pane that the first started");
    const children = entriesOf(s, "ko-pi.child");
    assert.deepEqual(children.map((child) => child.pane.pane), ["pane_77", "pane_10"]);
    assert.equal(entriesOf(s, "ko-pi.work").length, 2, "the restart and the second message are each work");
    assert.deepEqual(fx.posts("/panes/pane_10/messages").map((post) => post.text), [losing]);

    const steered = text(await (async () => {
      s.entries.push({ type: "custom", customType: "ko-pi.child", data: { ...children[0], owner: "self-session", pane: { instance: INSTANCE, pane: "pane_78" } } });
      return message.execute("c", { to: "kid", message: "now", mode: "steer" });
    })());
    assert.equal(steered, "could not message kid: kid is no longer running", "only a message restarts");
  } finally {
    await fx.restore();
  }
});

test("a child delivers its task after session_start returns, exactly once across reload", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "the work", from: { session: "boss-session", name: "boss", pane: "pane_2" } };
    fx.setPanes([selfPane({ parent: "pane_2", vars: { "ko-pi.task": task } }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss" })]);
    await asSubagent("self-session", async () => {
      const cancelled = await startSession(fx, { startup: false });
      await cancelled.emit("session_shutdown", { reason: "reload" });
      assert.deepEqual(fx.row("pane_1")?.vars?.["ko-pi.task"], task);
      const s = await startSession(fx, { startup: false });
      assert.deepEqual(s.delivered, [], "the host can subscribe after session_start returns");
      await pollUntil(() => fx.row("pane_1")?.vars?.["ko-pi.task"] === undefined);
      assert.deepEqual(cancelled.delivered, [], "the cancelled instance never starts the task");
      assert.deepEqual(s.delivered, [{ text: "the work", opts: { deliverAs: "followUp" } }]);
      assert.deepEqual(entriesOf(s, "ko-pi.work").map((work) => work.owner), ["self-session"]);
      assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE" && call.path === "/panes/pane_1/vars/ko-pi.task").length, 1);
      assert.equal(fx.row("pane_1")?.vars?.["ko-pi.task"], undefined);
      await s.emit("session_shutdown", { reason: "reload" });
      const again = await startSession(fx, { entries: s.entries });
      assert.deepEqual(again.delivered, [], "the variable is gone, so a reload delivers nothing");
    });
  } finally {
    await fx.restore();
  }
});

test("shutdown during the startup layout read leaves the task for the next session", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "the work", from: { session: "boss-session", name: "boss", pane: "pane_2" } };
    fx.setPanes([selfPane({ parent: "pane_2", vars: { "ko-pi.task": task } }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss" })]);
    await asSubagent("self-session", async () => {
      const gate = join(fx.dir, "layout-ready");
      await withEnv({ KO_FAKE_LAYOUT_GATE: gate }, async () => {
        const s = await startSession(fx, { startup: false });
        await pollUntil(() => fx.apiCalls().some((call) => call.path === "/layout"));
        const shutdown = s.emit("session_shutdown", { reason: "reload" });
        writeFileSync(gate, "");
        await shutdown;
        assert.deepEqual(s.delivered, []);
        assert.deepEqual(fx.row("pane_1")?.vars?.["ko-pi.task"], task);
      });
      const again = await startSession(fx);
      assert.deepEqual(again.delivered, [{ text: "the work", opts: { deliverAs: "followUp" } }]);
      assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE" && call.path === "/panes/pane_1/vars/ko-pi.task").length, 1);
    });
  } finally {
    await fx.restore();
  }
});

test("a task from another session arrives as a message with its sender header, and an unreadable layout leaves the variable", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "please look", from: { session: "stranger-session", name: "stranger", pane: "pane_8" } };
    fx.setPanes([selfPane({ vars: { "ko-pi.task": task } })]);
    const s = await startSession(fx);
    const [message] = s.messages.filter((m) => m.message.customType === "ko-message");
    assert.equal(message!.message.content, "message from @stranger (another agent in this session, not the user):\nplease look");
    assert.deepEqual(entriesOf(s, "ko-pi.work"), [], "work comes only from the parent");

    fx.setPanes([selfPane({ vars: { "ko-pi.task": task } })]);
    await withEnv({ KO_FAKE_LAYOUT_FAIL: "1" }, async () => {
      const failing = await startSession(fx);
      assert.deepEqual(failing.messages, []);
    });
    assert.deepEqual(fx.row("pane_1")?.vars?.["ko-pi.task"], task, "a read that failed leaves the variable for the next attempt");
  } finally {
    await fx.restore();
  }
});
