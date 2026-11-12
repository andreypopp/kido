import { test } from "node:test";

import assert from "node:assert/strict";

import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";

import { makeFixture, agentPane, selfPane, startSession, text, entriesOf, withEnv, asSubagent, savedSession, pollUntil } from "./koa-agent-fixture.ts";

const INSTANCE = "a".repeat(32);

type Body = Record<string, any>;

function recordModelChanges(file: string) {
  const entries = [
    { type: "model_change", provider: "acme", modelId: "earlier" },
    { type: "thinking_level_change", thinkingLevel: "low" },
    { type: "model_change", provider: "acme", modelId: "saved" },
    { type: "thinking_level_change", thinkingLevel: "medium" },
  ];
  appendFileSync(file, entries.map((entry, i) => JSON.stringify({ ...entry, id: `entry${i}`, parentId: i ? `entry${i - 1}` : null, timestamp: new Date().toISOString() })).join("\n"));
}

const env = (body: Body, name: string): string | undefined => (body.env as Array<{ name: string; value: string }>).find((v) => v.name === name)?.value;

for (const mode of ["koa", "koa-browser"]) test(`spawn_agent creates one pane with the ${mode} mode, a parent and the task`, async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self", flags: mode === "koa-browser" ? { "koa-browser": true } : {} });
    const result = await s.tools.get("spawn_agent").execute("c", { name: "worker", task: "build it", model: undefined });
    const reply = text(result);
    const [body] = fx.posts("/panes") as Body[];
    assert.equal(fx.posts("/panes").length, 1, "one POST makes the pane: no layout edit, no rename");
    const session = result.details.session as string;
    assert.match(session, /^[0-9a-f]{32}$/);
    const ko = join(fx.binDir, "ko");
    assert.deepEqual(body!.command, { type: "argv", argv: [ko, "shell", "--", "koa", ...(mode === "koa-browser" ? ["--browser"] : []), "--session-id", session, "--name", "worker", "--model", "acme/caller:high", "--session-dir", join(getAgentDir(), "ko-subagents", `--${process.cwd().slice(1).split("/").join("-")}--`)] });
    assert.deepEqual({ name: body!.name, cwd: body!.cwd, parent: body!.parent, close: body!.close, session: body!.session }, { name: "worker", cwd: process.cwd(), parent: "pane_1", close: "on_exit", session: undefined });
    assert.equal(env(body!, "KO_AGENT_SESSION"), session);
    assert.equal(env(body!, "KO_AGENT_PARENT_SESSION"), "self-session");
    assert.equal(env(body!, "KO_AGENT_TRUSTED_CWD"), undefined, "a session that does not trust its project passes no trust");
    assert.deepEqual(body!.vars, { "koa.task": { text: "build it", from: { session: "self-session", name: "Self", pane: "pane_1" } } });

    assert.match(reply, new RegExp(`^spawned worker \\(session ${session}, window window_10, pane pane_10\\); session id is what resume_from takes later; its result arrives as a notice`));
    assert.match(reply, /list_agents lists this agent and stop_agent stops it/);
    const [child] = entriesOf(s, "koa.agent");
    assert.deepEqual(child, { role: "subagent", owner: "self-session", at: child!.at, name: "worker", session, model: "acme/caller:high", fork: false, cwd: process.cwd(), pane: { instance: INSTANCE, pane: "pane_10" } });
    assert.deepEqual(entriesOf(s, "koa.work").map((work) => [work.owner, work.child]), [["self-session", session]]);
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
    assert.ok(!body!.command.argv.includes("--session-dir"));
    assert.ok(env(body!, "KO_AGENT_SESSION"));
    assert.equal(body!.vars["koa.task"].text, "go");
    assert.match(reply, /independent peer; no report or ending notice$/);
    assert.deepEqual(entriesOf(s, "koa.agent").map((entry) => entry.role), ["peer"]);
    assert.deepEqual(entriesOf(s, "koa.work"), []);
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
    assert.equal(await refused({ name: "kid", task: "x", cwd: "/nonexistent-dir-for-koa" }), "could not spawn agent: cwd is not a directory: /nonexistent-dir-for-koa");
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
    assert.deepEqual(entriesOf(s, "koa.agent"), []);
    await spawn.execute("c", { name: "worker", task: "x" });
    assert.match(text(await spawn.execute("c", { name: "Worker", task: "x" })), /^could not spawn agent: the name "Worker" is already taken by one of this session's agents; message it instead$/);
    const concurrent = await Promise.all([spawn.execute("c", { name: "twin", task: "x" }), spawn.execute("c", { name: "twin", task: "x" })]);
    assert.equal(concurrent.filter((result) => text(result).startsWith("spawned twin")).length, 1, "two spawns of one name make one pane");
  } finally {
    await fx.restore();
  }
});

test(`resume_from continues a saved session; fork copies it under a new id`, async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_agent");
    const sessions = join(fx.dir, "ko-subagents", "caller");
    const cwd = fx.dir;
    const file = savedSession(sessions, cwd, "0123456789abcdef0123456789abcdef");
    recordModelChanges(file);
    appendFileSync(file, '\n{"type":');
    const original = readFileSync(file, "utf8");
    const resumed = await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => text(await spawn.execute("c", { name: "again", task: "", resume_from: "01234567" })));
    assert.match(resumed, /^spawned again \(session 0123456789abcdef0123456789abcdef,/);
    const [body] = fx.posts("/panes") as Body[];
    assert.deepEqual((body!.command.argv as string[]).slice(3, 7), ["koa", "--session", file, "--name"]);
    assert.equal(body!.command.argv[body!.command.argv.indexOf("--model") + 1], "acme/saved:medium");
    assert.equal(body!.cwd, cwd, "the recorded directory");
    assert.equal(body!.vars, undefined, "an empty task is no variable");
    assert.deepEqual(entriesOf(s, "koa.work"), [], "and owes no report");

    fx.setPanes([selfPane(), agentPane({ pane: "pane_30", session: "0123456789abcdef0123456789abcdef", name: "again", parent: "pane_1" })]);
    assert.equal(text(await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, () => spawn.execute("c", { name: "again", task: "", resume_from: "0123456789abcdef0123456789abcdef" }))), "could not spawn agent: session 0123456789abcdef0123456789abcdef is live in a pane");

    const forked = await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => text(await spawn.execute("c", { name: "copy", task: "do it differently", resume_from: "0123456789abcdef0123456789abcdef", fork: true })));
    assert.match(forked, /, forked from session 0123456789abcdef0123456789abcdef;/);
    const argv = (fx.posts("/panes").at(-1)!.command.argv as string[]).slice(3);
    assert.deepEqual(argv.slice(0, 2), ["koa", "--session-id"]);
    assert.notEqual(argv[2], "0123456789abcdef0123456789abcdef");
    assert.deepEqual(argv.slice(-2), ["--fork", file]);
    assert.equal(argv[argv.indexOf("--model") + 1], "acme/saved:medium");
    assert.equal(argv[argv.indexOf("--session-dir") + 1], join(fx.dir, "ko-subagents", `--${cwd.slice(1).split("/").join("-")}--`));
    fx.setPi("#!/bin/sh\nprintf 'provider model\\nacme caller\\n'\n");
    const explicit = await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => text(await spawn.execute("c", { name: "peer-copy", task: "go", resume_from: "01234567", fork: true, toplevel: true, model: "acme/caller:low" })));
    assert.match(explicit, /^spawned peer-copy /);
    const explicitArgv = fx.posts("/panes").at(-1)!.command.argv;
    assert.equal(explicitArgv[explicitArgv.indexOf("--model") + 1], "acme/caller:low");
    assert.ok(!fx.posts("/panes").at(-1)!.command.argv.includes("--session-dir"));
    assert.equal(readFileSync(file, "utf8"), original, "resume and fork do not change an unterminated source file");
  } finally {
    await fx.restore();
  }
});

test("saved selection keeps virtual models across responses and leaves unrecorded thinking to pi's default", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "0123456789abcdef0123456789abcdef";
    const file = savedSession(join(fx.dir, "sessions", "caller"), fx.dir, id);
    appendFileSync(file, JSON.stringify({ type: "model_change", id: "model", parentId: null, timestamp: new Date().toISOString(), provider: "acme", modelId: "saved" }));
    const reply = await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => text(await s.tools.get("spawn_agent").execute("c", { name: "again", task: "", resume_from: id })));
    assert.match(reply, /^spawned again /);
    const argv = fx.posts("/panes")[0]!.command.argv;
    assert.equal(argv[argv.indexOf("--model") + 1], "acme/saved");
    appendFileSync(file, "\n" + JSON.stringify({ type: "message", id: "response", parentId: "model", timestamp: new Date().toISOString(), message: { role: "assistant", api: "test", provider: "acme", model: "physical", content: [], stopReason: "stop" } }));
    let virtual = true;
    const context = { cwd: process.cwd(), sessionManager: { getSessionDir: () => join(fx.dir, "sessions", "caller") }, modelRegistry: { find: (provider: string, id: string) => provider === "acme" && id === "saved" ? { api: virtual ? "pi-virtual" : "test" } : undefined } };
    const fork = async (name: string) => {
      const reply = await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => text(await s.tools.get("spawn_agent").execute("c", { name, task: "go", resume_from: id, fork: true }, undefined, undefined, context)));
      assert.match(reply, new RegExp(`^spawned ${name} `));
      const argv = fx.posts("/panes").at(-1)!.command.argv;
      return argv[argv.indexOf("--model") + 1];
    };
    assert.equal(await fork("virtual"), "acme/saved");
    virtual = false;
    assert.equal(await fork("physical"), "acme/physical");
    appendFileSync(file, "\n" + JSON.stringify({ type: "thinking_level_change", id: "thinking", parentId: "response", timestamp: new Date().toISOString(), thinkingLevel: "off" }));
    assert.equal(await fork("off"), "acme/physical:off");
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
      assert.equal(text(await s.tools.get("spawn_agent").execute("c", { name: "again", task: "", resume_from: id })), `could not spawn agent: invalid session header: ${file}`);
      assert.equal(text(await s.tools.get("message_agent").execute("c", { to: "kid", message: "continue" })), `could not message kid: invalid session header: ${file}`);
    });
    assert.equal(readFileSync(file, "utf8"), "{}");
    unlinkSync(file);
    mkdirSync(file);
    await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => {
      assert.ok(text(await s.tools.get("spawn_agent").execute("c", { name: "again", task: "", resume_from: id })).startsWith(`could not spawn agent: could not read session file ${file}: `));
      assert.ok(text(await s.tools.get("message_agent").execute("c", { to: "kid", message: "continue" })).startsWith(`could not message kid: could not read session file ${file}: `));
    });
    assert.deepEqual(fx.posts("/panes"), []);
  } finally {
    await fx.restore();
  }
});

test("a message to an ended subagent restarts it by --session-id in its recorded cwd, with the message as its task; two at once restart it once", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "acme/m:low", fork: false, cwd: "/work/kid", pane: { instance: INSTANCE, pane: "pane_77" } } });
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
    assert.deepEqual(argv.slice(3), ["koa", "--session-id", "kid-session", "--name", "kid", "--model", "acme/m:low", "--session-dir", join(getAgentDir(), "ko-subagents", "--work-kid--")]);
    assert.equal(posts[0]!.cwd, "/work/kid");
    assert.equal(posts[0]!.parent, "pane_1");
    assert.equal(posts[0]!.vars["koa.task"].text, winning);
    assert.ok(texts[1 - winner]!.startsWith("queued for kid:"), "the other message goes to the pane that the first started");
    const children = entriesOf(s, "koa.agent");
    assert.deepEqual(children.map((child) => child.pane.pane), ["pane_77", "pane_10"]);
    assert.equal(entriesOf(s, "koa.work").length, 2, "the restart and the second message are each work");
    assert.deepEqual(fx.posts("/panes/pane_10/messages").map((post) => post.text), [losing]);

    const steered = text(await (async () => {
      s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", ...children[0], owner: "self-session", pane: { instance: INSTANCE, pane: "pane_78" } } });
      return message.execute("c", { to: "kid", message: "now", mode: "steer" });
    })());
    assert.equal(steered, "could not message kid: kid is no longer running", "only a message restarts");
  } finally {
    await fx.restore();
  }
});

test("message_agent continues an ended child's session file in the normal tree", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = "0123456789abcdef0123456789abcdef";
    const file = savedSession(join(fx.dir, "sessions", "caller"), fx.dir, id);
    recordModelChanges(file);
    s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: id, model: "acme/m:low", fork: false, cwd: fx.dir, pane: { instance: INSTANCE, pane: "pane_77" } } });
    const result = await withEnv({ PI_CODING_AGENT_DIR: fx.dir }, async () => text(await s.tools.get("message_agent").execute("c", { to: "kid", message: "continue" })));
    assert.match(result, /^restarted kid in pane pane_10;/);
    assert.deepEqual(fx.posts("/panes")[0]!.command.argv.slice(3, 7), ["koa", "--session", file, "--name"]);
    const argv = fx.posts("/panes")[0]!.command.argv;
    assert.equal(argv[argv.indexOf("--model") + 1], "acme/saved:medium");
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
    assert.equal(message!.message.content, "message from @stranger (another agent in this session, not the user):\nplease look");
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
