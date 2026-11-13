import { test } from "node:test";

import assert from "node:assert/strict";

import { mkdirSync, existsSync } from "node:fs";

import { join, dirname } from "node:path";

import { fileURLToPath } from "node:url";

import { makeFixture, createFakePi, startSession, freshExtension, withEnv, pollUntil, selfPane, at, koaExtension } from "./koa-agent-fixture.ts";

const MESSAGES = "/panes/pane_1/messages";

test("the ko skill and its guideline are available only inside ko", async () => {
  const fx = makeFixture();
  try {
    const { pi, emit } = createFakePi();
    koaExtension(pi);
    const skills = join(dirname(fileURLToPath(import.meta.url)), "skills");
    assert.deepEqual(await emit("resources_discover"), [{ skillPaths: [skills] }]);
    assert.ok(existsSync(join(skills, "ko/SKILL.md")));
    const guideline = "The user runs the ko terminal multiplexer, and this pi runs in one of its panes. When the user talks about windows, tabs, panes, sessions, splits, floats or the sidebar, read the ko skill first.";
    const event = (): { systemPromptOptions: { promptGuidelines: string[] } } => ({ systemPromptOptions: { promptGuidelines: [] } });
    const inside = event();
    await emit("before_agent_start", inside);
    assert.ok(inside.systemPromptOptions.promptGuidelines.includes(guideline));
    await withEnv({ KO_SOCKET: undefined }, async () => {
      assert.deepEqual(await emit("resources_discover"), [undefined]);
      const outside = event();
      await emit("before_agent_start", outside);
      assert.ok(!outside.systemPromptOptions.promptGuidelines.includes(guideline));
    });
  } finally {
    await fx.restore();
  }
});

test("a session writes its pane variables and opens its message stream; quitting deletes the variables and closes the stream", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    await pollUntil(() => fx.streamOpens(MESSAGES) === 1, 2000, "the message stream");
    const puts = fx.apiCalls().filter((call) => call.method === "PUT");
    assert.deepEqual(
      puts.map((call) => [call.path, JSON.parse(call.body)]),
      [["/panes/pane_1/vars/pi.session", "self-session"], ["/panes/pane_1/vars/pi.name", "Self"]],
    );
    await pollUntil(() => fx.row("pane_1")?.inbox === true, 2000, "the row to show its inbox");

    await s.emit("session_shutdown", { reason: "quit" });
    const deletes = fx.apiCalls().filter((call) => call.method === "DELETE");
    assert.deepEqual(deletes.map((call) => [call.path, JSON.parse(call.body)]), [
      ["/panes/pane_1/vars", { names: ["pi.session", "pi.name", "pi.activity"], if: { name: "pi.session", value: "self-session" } }],
    ]);
    assert.equal(fx.row("pane_1")?.vars?.["pi.session"], undefined, "the conditional delete took effect");
  } finally {
    await fx.restore();
  }
});

test("a headless session writes no variable and opens no stream", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await startSession(fx, { ctx: { hasUI: false } });
    assert.deepEqual(fx.apiCalls().filter((call) => call.method !== "GET"), []);
  } finally {
    await fx.restore();
  }
});

test("a stream that closes is opened again, and a message the receiver has seen is acked and not delivered twice", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await pollUntil(() => fx.streamOpens(MESSAGES) === 1, 2000, "the stream");
    fx.feed({ id: "once-0001", kind: "user", text: "hello" });
    await pollUntil(() => fx.acks().length === 1, 2000, "the ack");
    assert.deepEqual(fx.acks(), [{ type: "ack", id: "once-0001" }]);
    assert.deepEqual(s.delivered.map((d) => d.text), ["hello"]);

    fx.forgetAcks();
    fx.dropStream();
    await pollUntil(() => fx.streamOpens(MESSAGES) === 2, 2000, "the stream to open again");
    await pollUntil(() => fx.acks().length === 1, 2000, "the repeat to be acked");
    assert.deepEqual(s.delivered.map((d) => d.text), ["hello"], "a repeat is acked and not handed to pi again");
  } finally {
    await fx.restore();
  }
});

test("a /reload parks the stream and keeps the variables; the next module takes the same stream over", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s1 = await startSession(fx, { factory: await freshExtension() });
    await pollUntil(() => fx.streamOpens(MESSAGES) === 1, 2000, "the stream");
    const before = fx.apiCalls().length;

    await s1.emit("session_shutdown", { reason: "reload" });
    assert.equal(fx.apiCalls().slice(before).some((call) => call.method === "DELETE"), false, "a reload keeps the variables");
    fx.feed({ id: "gap-0001", kind: "user", text: "in the gap" });
    const s2 = await startSession(fx, { factory: await freshExtension() });
    await pollUntil(() => s2.delivered.length === 1, 2000, "the message of the gap");
    assert.equal(at(s2.delivered, 0).text, "in the gap");
    assert.equal(s1.delivered.length, 0, "the module that shut down delivers nothing");
    assert.equal(fx.streamOpens(MESSAGES), 1, "the reload kept the one stream");
    fx.feed({ id: "after-0001", kind: "user", text: "after" });
    await pollUntil(() => s2.delivered.length === 2, 2000, "a message after the reload");
  } finally {
    await fx.restore();
  }
});

test("project trust answers yes only for the real path of KO_AGENT_TRUSTED_CWD", async () => {
  const fx = makeFixture();
  try {
    const trusted = join(fx.dir, "trusted");
    const other = join(fx.dir, "other");
    mkdirSync(trusted);
    mkdirSync(other);
    const s = createFakePi();
    koaExtension(s.pi);
    await withEnv({ KO_AGENT_TRUSTED_CWD: trusted }, async () => {
      assert.deepEqual(await s.emit("project_trust", { cwd: trusted }), [{ trusted: "yes" }]);
      assert.deepEqual(await s.emit("project_trust", { cwd: other }), [{ trusted: "undecided" }]);
      assert.deepEqual(await s.emit("project_trust", { cwd: join(fx.dir, "missing") }), [{ trusted: "undecided" }]);
      assert.deepEqual(await s.emit("project_trust", { cwd: join(trusted, "..", "trusted") }), [{ trusted: "yes" }], "paths compare by their real path");
    });
    await withEnv({ KO_AGENT_TRUSTED_CWD: undefined }, async () => {
      assert.deepEqual(await s.emit("project_trust", { cwd: trusted }), [{ trusted: "undecided" }]);
    });
  } finally {
    await fx.restore();
  }
});

