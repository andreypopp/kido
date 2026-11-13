import { test } from "node:test";

import assert from "node:assert/strict";

import { join } from "node:path";
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";

import { makeFixture, agentPane, selfPane, startSession, text, entriesOf, withEnv, asSubagent, savedSession, pollUntil, argvOf, envOf, get } from "./koa-agent-fixture.ts";

const INSTANCE = "a".repeat(32);


test("a toplevel spawn is one POST with the session and neither parent nor close nor edge, and records no child", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane({ session: "session_3" })]);
    const s = await startSession(fx);
    const reply = text(await s.tool("spawn_agent").execute("c", { name: "peer", task: "go", toplevel: true }));
    const [body] = fx.posts("/panes");
    assert.equal(fx.posts("/panes").length, 1);
    assert.deepEqual({ session: body.session, parent: body.parent, close: body.close }, { session: "session_3", parent: undefined, close: undefined });
    assert.equal(envOf(body, "KO_AGENT_PARENT_SESSION"), undefined);
    assert.ok(!argvOf(body).includes("--session-dir"));
    assert.ok(envOf(body, "KO_AGENT_SESSION"));
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
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: id, model: "acme/m:low", fork: false, cwd: fx.dir, pane: { instance: INSTANCE, pane: "pane_77" } } });
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

test("a child delivers its task after session_start returns, exactly once across reload", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "the work", from: { session: "boss-session", name: "boss", pane: "pane_2" } };
    fx.setPanes([selfPane({ parent: "pane_2", vars: { "koa.task": task } }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss" })]);
    await asSubagent("self-session", async () => {
      const cancelled = await startSession(fx, { startup: false });
      await cancelled.emit("session_shutdown", { reason: "reload" });
      assert.deepEqual(fx.row("pane_1")?.vars?.["koa.task"], task);
      const s = await startSession(fx, { startup: false });
      assert.deepEqual(s.delivered, [], "the host can subscribe after session_start returns");
      await pollUntil(() => fx.row("pane_1")?.vars?.["koa.task"] === undefined);
      assert.deepEqual(cancelled.delivered, [], "the cancelled instance never starts the task");
      assert.deepEqual(s.delivered, [{ text: "the work", opts: { deliverAs: "followUp" } }]);
      assert.deepEqual(entriesOf(s, "koa.work").map((work) => work.owner), ["self-session"]);
      assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE" && call.path === "/panes/pane_1/vars/koa.task").length, 1);
      assert.equal(fx.row("pane_1")?.vars?.["koa.task"], undefined);
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
    fx.setPanes([selfPane({ parent: "pane_2", vars: { "koa.task": task } }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss" })]);
    await asSubagent("self-session", async () => {
      const gate = join(fx.dir, "layout-ready");
      await withEnv({ KO_FAKE_LAYOUT_GATE: gate }, async () => {
        const s = await startSession(fx, { startup: false });
        await pollUntil(() => fx.apiCalls().some((call) => call.path === "/layout"));
        const shutdown = s.emit("session_shutdown", { reason: "reload" });
        writeFileSync(gate, "");
        await shutdown;
        assert.deepEqual(s.delivered, []);
        assert.deepEqual(fx.row("pane_1")?.vars?.["koa.task"], task);
      });
      const again = await startSession(fx);
      assert.deepEqual(again.delivered, [{ text: "the work", opts: { deliverAs: "followUp" } }]);
      assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE" && call.path === "/panes/pane_1/vars/koa.task").length, 1);
    });
  } finally {
    await fx.restore();
  }
});

test("a task from another session arrives as a message with its sender header, and an unreadable layout leaves the variable", async () => {
  const fx = makeFixture();
  try {
    const task = { text: "please look", from: { session: "stranger-session", name: "stranger", pane: "pane_8" } };
    fx.setPanes([selfPane({ vars: { "koa.task": task } })]);
    const s = await startSession(fx);
    const [message] = s.messages.filter((m) => m.message.customType === "ko-message");
    assert.equal(message.message.content, "message from @stranger (another agent in this session, not the user):\nplease look");
    assert.deepEqual(entriesOf(s, "koa.work"), [], "work comes only from the parent");

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

test("an ordinary spawn is refused before any POST, and a saved child is not revived as a pane", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    assert.equal(text(await s.tool("spawn_agent").execute("c", { name: "worker", task: "build it", model: undefined })), "could not spawn agent: in-process subagents are not yet available; use toplevel: true");
    assert.deepEqual(fx.posts("/panes"), []);
    assert.deepEqual(entriesOf(s, "koa.agent"), []);
  } finally {
    await fx.restore();
  }
});

test("message_agent to a recorded child posts no pane and says why", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "acme/m:low", fork: false, cwd: "/work/kid", pane: { instance: INSTANCE, pane: "pane_77" } } });
    assert.equal(text(await s.tool("message_agent").execute("c", { to: "kid", message: "carry on" })), "could not message kid: in-process subagents are not yet available; use toplevel: true");
    assert.deepEqual(fx.posts("/panes"), []);
  } finally {
    await fx.restore();
  }
});
