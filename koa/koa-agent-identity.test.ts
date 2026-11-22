import { test } from "node:test";

import assert from "node:assert/strict";

import { mkdirSync, existsSync } from "node:fs";

import { join, dirname } from "node:path";

import { fileURLToPath } from "node:url";

import { makeFixture, createFakePi, createChannel, startSession, withEnv, selfPane, koaExtension } from "./koa-agent-fixture.ts";

test("the ko skill and its guideline are available only inside ko", async () => {
  const fx = makeFixture();
  try {
    const { pi, emit } = createFakePi();
    koaExtension(pi);
    const skills = join(dirname(fileURLToPath(import.meta.url)), "skills");
    assert.deepEqual(await emit("resources_discover"), [{ skillPaths: [skills] }]);
    assert.ok(existsSync(join(skills, "ko/SKILL.md")));
    const guideline = "The user runs the ko terminal multiplexer, and this pi runs in one of its panes. When the user talks about windows, tabs, panes, sessions, splits, floats or the sidebar, read the ko skill first.";
    const event = (): { systemPromptOptions: { promptGuidelines: string[]; sections: Record<string, string> } } => ({ systemPromptOptions: { promptGuidelines: [], sections: {} } });
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

test("path guidelines follow the host's path editor availability", async () => {
  const fx = makeFixture();
  try {
    const channel = createChannel();
    const { pi, emit } = createFakePi(undefined, [], channel);
    koaExtension(pi);
    const rules = async () => {
      const event: { systemPromptOptions: { promptGuidelines: string[]; sections: Record<string, string> } } = { systemPromptOptions: { promptGuidelines: [], sections: {} } };
      await emit("before_agent_start", event);
      return event.systemPromptOptions.promptGuidelines.filter(rule => rule.includes("The user clicks such a span"));
    };
    assert.equal((await rules()).length, 1);
    Object.assign(channel.host, { browser: true, pathEditor: false });
    assert.deepEqual(await rules(), []);
  } finally {
    await fx.restore();
  }
});

test("a root session writes its pane variables; quitting deletes them", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    const puts = fx.apiCalls().filter((call) => call.method === "PUT");
    assert.deepEqual(
      puts.map((call) => [call.path, JSON.parse(call.body)]),
      [["/panes/pane_1/vars/koa.session", "self-session"], ["/panes/pane_1/vars/koa.name", "Self"]],
    );

    await s.emit("session_shutdown", { reason: "quit" });
    const deletes = fx.apiCalls().filter((call) => call.method === "DELETE");
    assert.deepEqual(deletes.map((call) => [call.path, JSON.parse(call.body)]), [
      ["/panes/pane_1/vars", { names: ["koa.session", "koa.name", "koa.activity"], if: { name: "koa.session", value: "self-session" } }],
    ]);
    assert.equal(fx.row("pane_1")?.vars?.["koa.session"], undefined, "the conditional delete took effect");
  } finally {
    await fx.restore();
  }
});

test("a headless session writes no variable", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await startSession(fx, { ctx: { hasUI: false } });
    assert.deepEqual(fx.apiCalls().filter((call) =>
      (call.method === "PUT" && call.path.startsWith("/panes/pane_1/vars/")) ||
      (call.method === "DELETE" && call.path === "/panes/pane_1/vars")), []);
  } finally {
    await fx.restore();
  }
});

test("project trust answers yes only for the real path of the directory the host grants", async () => {
  const fx = makeFixture();
  try {
    const trusted = join(fx.dir, "trusted");
    const other = join(fx.dir, "other");
    mkdirSync(trusted);
    mkdirSync(other);
    const granted = createChannel();
    Object.assign(granted.host, { trusted });
    const s = createFakePi(undefined, [], granted);
    koaExtension(s.pi);
    assert.deepEqual(await s.emit("project_trust", { cwd: trusted }), [{ trusted: "yes" }]);
    assert.deepEqual(await s.emit("project_trust", { cwd: other }), [{ trusted: "undecided" }]);
    assert.deepEqual(await s.emit("project_trust", { cwd: join(fx.dir, "missing") }), [{ trusted: "undecided" }]);
    assert.deepEqual(await s.emit("project_trust", { cwd: join(trusted, "..", "trusted") }), [{ trusted: "yes" }], "paths compare by their real path");
    const none = createFakePi();
    koaExtension(none.pi);
    assert.deepEqual(await none.emit("project_trust", { cwd: trusted }), [{ trusted: "undecided" }], "no grant, no trust");
  } finally {
    await fx.restore();
  }
});

test("a subagent writes no pane variable and unsets none: only the pane's root names the pane", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const channel = createChannel();
    Object.assign(channel.host.self, { parent: { id: "boss-session", children: [] } });
    const s = await startSession(fx, { channel });
    await s.emit("session_info_changed", {});
    await s.emit("session_shutdown", { reason: "quit" });
    assert.deepEqual(fx.apiCalls().filter((call) => call.method === "PUT" || call.method === "DELETE"), []);
  } finally {
    await fx.restore();
  }
});
