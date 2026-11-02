import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, mkdirSync, statSync } from "node:fs";

import { createServer, type Server } from "node:net";

import { join } from "node:path";

import koPi from "./ko-pi.ts";

import {
  makeFixture,
  fakeCtx,
  startSession,
  startSessionCore,
  withEnv,
  asSubagent,
  pollUntil,
  pollForStable,
} from "./ko-pi-fixture.ts";

// Pins a real incident: every KO_AGENT_* variable is inherited by anything an
// agent's process starts, so a nested pi run arrives with a child's entire
// environment. What tells the two apart: the child's directory records the
// child's own pi session id; a nested pi mints its own.
test("a process that merely inherited a subagent's environment is not a subagent", async () => {
  const fx = makeFixture();
  try {
    const realSession = "the-real-childs-run";
    const agentDir = fx.writeAgent("parent-x", "worker", { session: realSession, run: realSession });
    await withEnv({ KO_RUN_ID: realSession, KO_AGENT_DIR: agentDir, KO_AGENT_PARENT_SESSION: "parent-x" }, async () => {
      const s = await startSession(fx, { sessionId: "a-nested-pis-own-session" });

      const event: { systemPrompt: string; systemPromptOptions: { promptGuidelines: string[] } } = {
        systemPrompt: "base prompt",
        systemPromptOptions: { promptGuidelines: [] },
      };
      await s.emit("before_agent_start", event);
      assert.ok(
        event.systemPromptOptions.promptGuidelines.every((line) => !line.includes("You were spawned as a subagent")),
        "it is told nothing about a parent it does not have",
      );
    });
  } finally {
    await fx.restore();
  }
});

// Negative control for the test above: the directory names this process's own
// session id, so the parent edge is trustworthy.
test("a real subagent still gets the parent edge and the standing subagent instruction", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(fx, "child-session", async () => {
      const s = await startSession(fx, { sessionId: "child-session" });
      const event: { systemPrompt: string; systemPromptOptions: { promptGuidelines: string[] } } = {
        systemPrompt: "base prompt",
        systemPromptOptions: { promptGuidelines: [] },
      };
      await s.emit("before_agent_start", event);
      const guidelines = event.systemPromptOptions.promptGuidelines.join("\n");
      assert.match(guidelines, /your report is the last message of a turn that ends after all of them finish/, "the standing instruction rides on every turn");
      assert.match(guidelines, /never run `sleep`/i, "so does the always-on never-sleep rule");
    });
  } finally {
    await fx.restore();
  }
});

test("an unresolved session id is not a subagent, whatever the environment claims", async () => {
  const fx = makeFixture();
  try {
    const agentDir = fx.writeAgent("parent-x", "worker", { session: "self-session", run: "self-session" });
    await withEnv({ KO_RUN_ID: "self-session", KO_AGENT_DIR: agentDir, KO_AGENT_PARENT_SESSION: "parent-x" }, async () => {
      const s = await startSession(fx, { sessionId: "" });

      const event: { systemPrompt: string; systemPromptOptions: { promptGuidelines: string[] } } = {
        systemPrompt: "base prompt",
        systemPromptOptions: { promptGuidelines: [] },
      };
      await s.emit("before_agent_start", event);
      assert.equal(event.systemPromptOptions.promptGuidelines.length, 1, "the always-on never-sleep rule still applies");
      assert.doesNotMatch(event.systemPromptOptions.promptGuidelines.join("\n"), /You were spawned as a subagent/);
    });
  } finally {
    await fx.restore();
  }
});

test("a headless pi writes nothing and binds no inbox", async () => {
  const fx = makeFixture();
  try {
    const s = await startSessionCore(fx, koPi, (c) => ({ ...fakeCtx("headless-session", c.ui), hasUI: false }));
    await s.emit("turn_start");
    await s.emit("session_shutdown", { reason: "quit" });
    assert.deepEqual(fx.apiCalls(), [], "a headless pi writes no pane variable");
    assert.equal(existsSync(fx.inboxPath("headless-session")), false, "and binds no inbox");
  } finally {
    await fx.restore();
  }
});

test("the session id, the session name and the inbox path are written as pane options", async () => {
  const fx = makeFixture();
  try {
    const s = await startSessionCore(fx, koPi, (c) => {
      c.pi.sessionName = "Parent";
      return fakeCtx("self-session", c.ui);
    });
    assert.deepEqual(fx.optionWrites(), [
      { key: "pi.session", value: "self-session" },
      { key: "pi.name", value: "Parent" },
      { key: "pi.inbox", value: fx.inboxPath("self-session") },
    ]);
    assert.equal(statSync(join(fx.stateDir, "inbox")).mode & 0o777, 0o700, "the inbox directory is private");

    const renames = () => fx.optionWrites().filter((w) => w.key === "pi.name").length;
    const last = () => fx.optionWrites().filter((w) => w.key === "pi.name").at(-1)?.value;

    s.pi.sessionName = "Renamed Agent";
    await s.emit("session_info_changed", { name: "not the authoritative name" });
    await pollUntil(() => last() === "Renamed Agent", 2000, "the rename to be written");

    const before = renames();
    await s.emit("session_info_changed", {});
    await pollForStable(renames, 150, 2000, "the rename write count");
    assert.equal(renames(), before, "an unchanged name is not written again");

    s.pi.sessionName = undefined;
    await s.emit("session_info_changed", {});
    await pollUntil(() => last() === "", 2000, "the cleared name to be written");
  } finally {
    await fx.restore();
  }
});

test("a pane whose inbox is already answered keeps it: the extension binds nothing and publishes nothing", async () => {
  const fx = makeFixture();
  let other: Server | undefined;
  try {
    const path = fx.inboxPath("shared-session");
    mkdirSync(join(fx.stateDir, "inbox"), { recursive: true, mode: 0o700 });
    other = createServer();
    await new Promise<void>((resolve) => other!.listen(path, resolve));

    const s = await startSession(fx, { sessionId: "shared-session" });
    assert.equal(fx.optionWrites().filter((w) => w.key === "pi.inbox").length, 0, "it published no inbox of its own");
    assert.deepEqual(fx.optionWrites().filter((w) => w.key === "pi.session"), [{ key: "pi.session", value: "shared-session" }]);
    assert.ok(existsSync(path), "the live listener's socket file is still there");
    await s.emit("session_shutdown", { reason: "quit" });
    assert.ok(existsSync(path), "its shutdown must not unlink a socket it never bound");
  } finally {
    if (other) await new Promise<void>((resolve) => other!.close(() => resolve()));
    await fx.restore();
  }
});

test("shutdown unsets the four options on this pane", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    await s.emit("session_shutdown", { reason: "quit" });
    const unset = fx.optionWrites().filter((w) => w.value === undefined);
    assert.deepEqual(unset.map((w) => w.key), ["pi.session", "pi.name", "pi.inbox", "pi.activity"]);
    assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE").length, 4, "the four unsets are four deletes");
  } finally {
    await fx.restore();
  }
});
