import { test } from "node:test";

import assert from "node:assert/strict";

import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, statSync, symlinkSync } from "node:fs";

import { tmpdir, userInfo } from "node:os";

import { createServer, type Server } from "node:net";

import { dirname, join } from "node:path";

import koPi, { privateDir } from "./ko-pi.ts";

import {
  makeFixture,
  selfPane,
  fakeCtx,
  startSession,
  startSessionCore,
  withEnv,
  asSubagent,
  pollUntil,
  pollForStable,
  startNamedSession,
  idleTurn,
  parentSetup,
  assertReport,
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
    const deletes = fx.apiCalls().filter((call) => call.method === "DELETE");
    assert.deepEqual(
      deletes.map((call) => [call.path, JSON.parse(call.body)]),
      [["/panes/pane_1/vars", { names: ["pi.session", "pi.name", "pi.inbox", "pi.activity"], if: { name: "pi.session", value: "self-session" } }]],
      "the four unsets are one delete, conditional on this session",
    );
  } finally {
    await fx.restore();
  }
});

test("a shutdown leaves the variables of a new owner of the pane", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    fx.setPanes([selfPane({ pi_session: "new-owner", pi_name: "Newcomer" })]);
    await s.emit("session_shutdown", { reason: "quit" });
    assert.equal(fx.apiCalls().filter((call) => call.method === "DELETE").length, 1, "this session asked once");
    assert.deepEqual(fx.panes().map((row) => [row.pi_session, row.pi_name]), [["new-owner", "Newcomer"]]);
  } finally {
    await fx.restore();
  }
});

const LONG_SESSION = "01a1a221-a4a0-75a8-bfda-8d670f98c9f4";

function longStateDir(base: string): string {
  const long = join(base, "a".repeat(60), "ko-pi");
  mkdirSync(long, { recursive: true });
  return long;
}

test("a long state directory publishes a short pi.inbox in a private directory", async () => {
  const fx = makeFixture();
  let inbox: string | undefined;
  try {
    await withEnv({ KO_PI_STATE_DIR: longStateDir(fx.stateDir) }, async () => {
      await startSessionCore(fx, koPi, (c) => fakeCtx(LONG_SESSION, c.ui));
    });
    inbox = fx.optionWrites().find((w) => w.key === "pi.inbox")?.value;
    assert.ok(inbox, "pi.inbox was published");
    assert.ok(Buffer.byteLength(inbox, "utf8") <= 103, inbox);
    assert.ok(!inbox.startsWith(fx.stateDir), inbox);
    const info = statSync(dirname(inbox));
    assert.equal(info.mode & 0o777, 0o700);
    assert.equal(info.uid, userInfo().uid);
  } finally {
    await fx.restore();
    if (inbox) rmSync(inbox, { force: true });
  }
});

test("with a long state directory a child's report reaches the inbox that its parent published", async () => {
  const fx = makeFixture();
  let parentInbox: string | undefined;
  try {
    await withEnv({ KO_PI_STATE_DIR: longStateDir(fx.stateDir) }, async () => {
      const parent = await startSessionCore(fx, koPi, (c) => fakeCtx("boss-session", c.ui));
      parentInbox = fx.optionWrites().find((w) => w.key === "pi.inbox")?.value;
      assert.ok(parentInbox, "the parent published an inbox");
      await parent.emit("session_shutdown", { reason: "quit" });
      const inbox = await fx.startInboxAt(parentInbox);
      parentSetup(fx, parentInbox);
      await asSubagent(fx, "self-session", async () => {
        const s = await startNamedSession(fx, "worker", "self-session");
        await idleTurn(s, "done");
        await pollUntil(() => inbox.received().length === 1, 2000, "the report");
        assertReport(inbox, 0, "done");
      });
    });
  } finally {
    await fx.restore();
    if (parentInbox) rmSync(parentInbox, { force: true });
  }
});

test("an inbox that cannot be made is a visible warning", async () => {
  const fx = makeFixture();
  try {
    const s = await startSessionCore(fx, koPi, (c) => fakeCtx("../escape", c.ui));
    assert.match(s.notifications[0]?.message ?? "", /no inbox/);
    assert.equal(s.notifications[0]?.type, "warning");
  } finally {
    await fx.restore();
  }
});

test("privateDir refuses a directory that is open to others or is a symlink", () => {
  const root = mkdtempSync(join(tmpdir(), "ko-pi-private-"));
  try {
    assert.equal(privateDir(join(root, "mine")), null);
    assert.equal(statSync(join(root, "mine")).mode & 0o777, 0o700);
    assert.equal(privateDir(join(root, "mine")), null);
    mkdirSync(join(root, "open"));
    chmodSync(join(root, "open"), 0o755);
    assert.match(privateDir(join(root, "open")) ?? "", /not a private directory/);
    assert.equal(statSync(join(root, "open")).mode & 0o777, 0o755);
    symlinkSync(join(root, "mine"), join(root, "link"));
    assert.match(privateDir(join(root, "link")) ?? "", /not a private directory/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
