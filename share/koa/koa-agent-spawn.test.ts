import { test } from "node:test";

import assert from "node:assert/strict";

import { join } from "node:path";
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";

import { makeFixture, selfPane, startSession, createChannel, text, entriesOf, withEnv, savedSession, argvOf, get } from "./koa-agent-fixture.ts";

test("a toplevel spawn is one POST with the session and neither parent nor close nor edge, and records no child", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane({ session: "session_3" })]);
    const s = await startSession(fx);
    const reply = text(await s.tool("spawn_agent").execute("c", { name: "peer", task: "go", toplevel: true }));
    const [body] = fx.posts("/panes");
    assert.equal(fx.posts("/panes").length, 1);
    assert.deepEqual({ session: body.session, parent: body.parent, close: body.close }, { session: "session_3", parent: undefined, close: undefined });
    assert.equal(body.env, undefined, "no agent environment");
    assert.ok(!argvOf(body).includes("--session-dir"));
    assert.ok(argvOf(body).includes("--session-id"));
    assert.equal(get(body.vars, "koa.task", "text"), "go");
    assert.match(reply, /independent peer; no report or ending notice$/);
    assert.deepEqual(entriesOf(s, "koa.agent").map((entry) => entry.role), ["peer"]);
    assert.deepEqual(entriesOf(s, "koa.work"), []);
  } finally {
    await fx.restore();
  }
});

test("invalid session headers and unreadable files return tool errors for resume and child revival", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "0123456789abcdef0123456789abcdef";
    const file = savedSession(join(fx.dir, "sessions", "caller"), fx.dir, id);
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: id, model: "acme/m:low", fork: false, cwd: fx.dir } });
    writeFileSync(file, "{}");
    await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => {
      assert.equal(text(await s.tool("spawn_agent").execute("c", { name: "again", task: "", resume_from: id })), `could not spawn agent: invalid session header: ${file}`);
      assert.equal(text(await s.tool("message_agent").execute("c", { to: "kid", message: "continue" })), `could not message kid: invalid session header: ${file}`);
    });
    assert.equal(readFileSync(file, "utf8"), "{}");
    unlinkSync(file);
    mkdirSync(file);
    await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => {
      assert.ok(text(await s.tool("spawn_agent").execute("c", { name: "again", task: "", resume_from: id })).startsWith(`could not spawn agent: could not read session file ${file}: `));
      assert.ok(text(await s.tool("message_agent").execute("c", { to: "kid", message: "continue" })).startsWith(`could not message kid: could not read session file ${file}: `));
    });
    assert.deepEqual(fx.posts("/panes"), []);
  } finally {
    await fx.restore();
  }
});

test("the root delivers a task from another session as a message with its sender header, once, and an unreadable layout leaves the variable", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "please look", from: { session: "stranger-session", name: "stranger", pane: "pane_8" } };
    fx.setPanes([selfPane({ vars: { "koa.task": task } })]);
    const cancelled = await startSession(fx, { startup: false });
    await cancelled.emit("session_shutdown", { reason: "reload" });
    assert.deepEqual(fx.row("pane_1")?.vars?.["koa.task"], task, "the cancelled instance never starts the task");
    assert.deepEqual(cancelled.messages, []);
    const s = await startSession(fx);
    const [message] = s.messages.filter((m) => m.message.customType === "ko-message");
    assert.equal(message.message.content, "message from @stranger (another agent in this session, not the user):\nplease look");
    assert.deepEqual(entriesOf(s, "koa.work"), [], "work comes only from the parent");
    assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE" && call.path === "/panes/pane_1/vars/koa.task").length, 1);

    fx.setPanes([selfPane({ vars: { "koa.task": task } })]);
    await withEnv({ KO_FAKE_LAYOUT_FAIL: "1" }, async () => {
      const failing = await startSession(fx);
      assert.deepEqual(failing.messages, []);
    });
    assert.deepEqual(fx.row("pane_1")?.vars?.["koa.task"], task, "a read that failed leaves the variable for the next attempt");
  } finally {
    await fx.restore();
  }
});

test("a subagent reads no task variable: its task is its first user message", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "the work", from: { session: "boss-session", name: "boss", pane: "pane_2" } };
    fx.setPanes([selfPane({ vars: { "koa.task": task } })]);
    const channel = createChannel();
    Object.assign(channel.host.self, { parent: { id: "boss-session", children: [] } });
    const s = await startSession(fx, { channel });
    assert.deepEqual(s.delivered, []);
    assert.deepEqual(fx.row("pane_1")?.vars?.["koa.task"], task);
  } finally {
    await fx.restore();
  }
});

test("a tool call to spawn in a host without a tree is the host's refusal, and no pane is made", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "bad/name", task: "x" })), /^could not spawn agent: refusing agent name "bad\/name"/);
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "x".repeat(65), task: "x" })), /^could not spawn agent: refusing agent name .* it is over 64 bytes/);
    assert.match(text(await s.tool("spawn_agent").execute("c", { name: "worker", task: "x", model: "acme/nonexistent" })), /^could not spawn agent: model "acme\/nonexistent" is not a model of a configured provider/);
    assert.deepEqual(fx.posts("/panes"), []);
    assert.deepEqual(entriesOf(s, "koa.agent"), []);
  } finally {
    await fx.restore();
  }
});
