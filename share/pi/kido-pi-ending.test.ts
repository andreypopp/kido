import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import kidoPi from "./kido-pi.ts";

import {
  makeFixture,
  selfPane,
  agentPane,
  startNamedSession,
  startWithSpies,
  asSubagent,
  withEnv,
  pollUntil,
  sendToInbox,
  envelope,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

const NO_TURN = "no turn ever ran: the task was delivered and the session never started work on it (the pane's own screen, kept with the run, is the only account of why)";

function parentSetup(fx: Fixture, inboxPath: string): void {
  fx.setPanes([agentPane({ pane: "%1", session: SELF, name: "worker" }), agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inboxPath })]);
}

function assistant(stopReason: string, errorMessage?: string) {
  return { role: "assistant", stopReason, errorMessage };
}

test("session_shutdown records this run's own outcome: completed when it settled, failed while a turn is running", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(fx, SELF, async () => {
      fx.setPanes([selfPane()]);
      const s = await startNamedSession(fx, "worker", SELF);
      await s.emit("agent_start");
      await s.emit("turn_start");
      await s.emit("agent_end", { messages: [assistant("stop")] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await s.emit("session_shutdown", { reason: "quit" });
      assert.deepEqual(fx.runOutcomeCalls()[0], ["run-outcome", "--result", "completed", "--", SELF]);
    });

    const fx2 = makeFixture();
    try {
      await asSubagent(fx2, SELF, async () => {
        fx2.setPanes([selfPane()]);
        const s = await startNamedSession(fx2, "worker", SELF);
        await s.emit("agent_start");
        await s.emit("turn_start");
        await s.emit("session_shutdown", { reason: "quit" });
        assert.deepEqual(fx2.runOutcomeCalls()[0], ["run-outcome", "--result", "failed", "--", SELF]);
      });
    } finally {
      await fx2.restore();
    }
  } finally {
    await fx.restore();
  }
});

test("the ending outcome text carries the last turn's error, and a child that never started a turn says so", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(fx, SELF, async () => {
      fx.setPanes([selfPane()]);
      const s = await startNamedSession(fx, "worker", SELF);
      await s.emit("agent_start");
      await s.emit("agent_end", { messages: [assistant("error", "boom")] });
      await s.emit("session_shutdown", { reason: "quit" });
      assert.deepEqual(fx.runOutcomeCalls()[0], ["run-outcome", "--result", "failed", "--text", "its last turn failed: boom", "--", SELF]);
    });
  } finally {
    await fx.restore();
  }

  const fx2 = makeFixture();
  try {
    await asSubagent(fx2, SELF, async () => {
      fx2.setPanes([selfPane()]);
      writeFileSync(join(fx2.agentDir("boss-session", "worker"), "task"), "do the thing");
      const s = await startNamedSession(fx2, "worker", SELF);
      assert.deepEqual(s.delivered.map((d) => d.text), ["do the thing"]);
      await s.emit("session_shutdown", { reason: "quit" });
      assert.deepEqual(fx2.runOutcomeCalls()[0], ["run-outcome", "--result", "failed", "--text", NO_TURN, "--", SELF]);
    });
  } finally {
    await fx2.restore();
  }
});

test("a reload, a session replacement, and a root session record no outcome", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(fx, SELF, async () => {
      fx.setPanes([selfPane()]);
      const s = await startNamedSession(fx, "worker", SELF);
      await s.emit("session_shutdown", { reason: "reload" });
      await s.emit("session_shutdown", { reason: "new" });
      assert.equal(fx.runOutcomeCalls().length, 0);
    });
    const root = await startNamedSession(fx, "Self");
    await root.emit("session_shutdown", { reason: "quit" });
    assert.equal(fx.runOutcomeCalls().length, 0, "a top-level pi has no run of its own");
  } finally {
    await fx.restore();
  }
});

test("a settled turn without a report tells the parent once that the child is idle; a reported one does not", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await s.emit("agent_start");
        await s.emit("agent_end", { messages: [assistant("stop")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => inbox.received().length === 1, 2000, "the idle notice");
        const notice = JSON.parse(inbox.received()[0]!);
        assert.equal(notice.kind, "notice");
        assert.equal(notice.text, `subagent ${SELF} is idle without reporting: its last turn ended and it did not call notify_parent. Continue it with message_agent, or end it with stop_run.`);
        assert.ok(!notice.text.includes("The child stays alive"), "a status notice carries no report guidance");
        assert.equal(existsSync(join(fx.agentDir("boss-session", "worker"), "report")), false, "a status notice writes no report");

        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 1, "a redundant settle does not resend");

        await s.tools.get("notify_parent").execute("c", { summary: "done" });
        await s.emit("turn_end", { toolResults: [{}] });
        await s.emit("turn_start");
        await s.emit("agent_end", { messages: [assistant("stop")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 2, "a child that reported gets no idle notice, even when pi starts another turn for the tool result");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a subagent's errored turn notifies the parent at once; an aborted one and a root's do not", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await s.emit("agent_start");
        await s.emit("agent_end", { messages: [assistant("error", "boom")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => inbox.received().length === 1, 2000, "the error notice");
        const notice = JSON.parse(inbox.received()[0]!);
        assert.equal(notice.text, `subagent stopped on an error: boom\nrun: ${SELF}\nmessage it to retry, or stop_run to end it`);
        assert.ok(!notice.text.includes("resume"));
      },
      { parent: "boss-session", name: "worker" },
    );

    const inboxBefore = inbox.received().length;
    await asSubagent(
      fx,
      "aborted-session",
      async () => {
        const s = await startNamedSession(fx, "worker", "aborted-session");
        await s.emit("agent_start");
        await s.emit("agent_end", { messages: [assistant("aborted")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, inboxBefore, "an aborted turn's silence is not news");
      },
      { parent: "boss-session", name: "worker" },
    );

    const root = await startNamedSession(fx, "Self");
    await root.emit("agent_start");
    await root.emit("agent_end", { messages: [assistant("error", "boom")] });
    await root.emit("agent_settled", {}, { isIdle: () => true });
    assert.equal(inbox.received().length, inboxBefore, "a top-level session has nobody to tell");
  } finally {
    await fx.restore();
  }
});

test("the parent watch shuts the child down when its parent's pi pane is gone", async () => {
  const fx = makeFixture();
  try {
    parentSetup(fx, "/tmp/none.sock");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_PARENT_POLL_MS: "20" }, async () => {
          const s = await startWithSpies(fx, kidoPi, SELF);
          await pollUntil(
            () => fx.tmuxCalls().filter((argv) => argv[0] === "list-panes" || argv[0] === "display-message").length >= 3,
            2000,
            "several parent readings",
          );
          assert.equal(s.shutdowns(), 0, "an alive parent never ends the child");
          fx.setPanes([agentPane({ pane: "%1", session: SELF, name: "worker" })]);
          await pollUntil(() => s.shutdowns() > 0, 2000, "the child to shut down");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a tmux read that fails is not evidence that the parent is gone", async () => {
  const fx = makeFixture();
  try {
    parentSetup(fx, "/tmp/none.sock");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_PARENT_POLL_MS: "20", KIDO_FAKE_TMUX_FAIL: "1" }, async () => {
          const s = await startWithSpies(fx, kidoPi, SELF);
          await pollUntil(() => fx.tmuxCalls().filter((argv) => argv[0] === "list-panes").length >= 3, 2000, "several failing readings");
          assert.equal(s.shutdowns(), 0, "a failing query says nothing");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a parent poll with a pane hint reads only that pane", async () => {
  const fx = makeFixture();
  try {
    parentSetup(fx, "/tmp/none.sock");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_PARENT_POLL_MS: "10" }, async () => {
          const s = await startWithSpies(fx, kidoPi, SELF);
          await pollUntil(() => fx.tmuxCalls().filter((argv) => argv[0] === "list-panes").length >= 6, 2000, "parent polls");
          const calls = fx.tmuxCalls().filter((argv) => argv[0] === "list-panes");
          const later = calls.slice(1);
          assert.ok(
            later.every((argv) => argv.includes("-t") && argv.includes("%2")),
            `every poll after the first targets the parent pane: ${JSON.stringify(calls)}`,
          );
          assert.equal(s.shutdowns(), 0, "the parent is still there");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a slow parent read does not let ticks pile up concurrent readings", async () => {
  const fx = makeFixture();
  try {
    parentSetup(fx, "/tmp/none.sock");
    const gate = join(fx.stateDir, "tmux-gate");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_PARENT_POLL_MS: "10", KIDO_FAKE_TMUX_GATE: gate }, async () => {
          const s = await startWithSpies(fx, kidoPi, SELF);
          await pollUntil(() => fx.tmuxCalls().filter((argv) => argv[0] === "list-panes").length >= 1, 2000, "the first reading");
          await new Promise((r) => setTimeout(r, 120));
          const stuck = fx.tmuxCalls().filter((argv) => argv[0] === "list-panes").length;
          assert.equal(stuck, 1, "one reading in flight holds every later tick back");
          writeFileSync(gate, "");
          await pollUntil(() => fx.tmuxCalls().filter((argv) => argv[0] === "list-panes").length >= 3, 2000, "later readings on the parent's own pane");
          assert.equal(s.shutdowns(), 0, "the parent is still there");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("an inbound message from the parent is labelled as the parent, from the agent map", async () => {
  const fx = makeFixture();
  try {
    parentSetup(fx, "/tmp/none.sock");
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        assert.equal(await sendToInbox(s.inboxPath, envelope("message", "carry on", { from: { session: "boss-session", name: "boss" } })), "ok");
        const sent = s.messages.find((m) => m.message.customType === "kido-message");
        assert.match(String(sent!.message.content), /^message from @boss \(your parent, who spawned you\):/);
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});
