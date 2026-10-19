import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import kidoPi from "./kido-pi.ts";

import {
  makeFixture,
  selfPane,
  paneRow,
  agentPane,
  startNamedSession,
  startWithSpies,
  asSubagent,
  withEnv,
  pollUntil,
  pendingState,
  agentJson,
  customMessages,
  sendToInbox,
  envelope,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

const IDLE_NOTICE = /is idle without reporting/;

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

const LIVE_RUN_TOOLS: Array<[string, Record<string, unknown>]> = [
  ["spawn_subagent", { task: "x", name: "kid" }],
  ["async_bash", { command: "make", name: "build" }],
];

for (const [tool, params] of LIVE_RUN_TOOLS) {
  test(`a child waiting on its own live ${tool} run sends no idle notice, and one once it ends`, async () => {
    const fx = makeFixture();
    try {
      const inbox = await fx.startInbox();
      parentSetup(fx, inbox.path);
      const gate = join(fx.stateDir, "gate");
      await asSubagent(
        fx,
        SELF,
        async () => {
          await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate }, async () => {
            const s = await startNamedSession(fx, "worker", SELF);
            await s.emit("agent_start");
            await s.emit("agent_end", { messages: [assistant("stop")] });
            await s.emit("agent_settled", {}, { isIdle: () => true });
            await pollUntil(() => inbox.received().length === 1, 2000, "the idle notice when nothing is running");
            assert.match(JSON.parse(inbox.received()[0]!).text, IDLE_NOTICE);

            await s.emit("agent_start");
            await s.tools.get(tool).execute("c", params);
            await pollUntil(() => fx.runWaitCalls().length === 1, 2000, "the run-wait");
            await s.emit("agent_end", { messages: [assistant("stop")] });
            await s.emit("agent_settled", {}, { isIdle: () => true });
            assert.equal(inbox.received().length, 1, "no idle notice while its run is live");

            writeFileSync(gate, "");
            await pollUntil(() => customMessages(s, "kido-notice").length === 1, 3000, "the run's ending notice");
            assert.equal(inbox.received().length, 1, "the ending notice goes to the child, not the parent");
            await s.emit("agent_start");
            await s.emit("agent_end", { messages: [assistant("stop")] });
            await s.emit("agent_settled", {}, { isIdle: () => true });
            await pollUntil(() => inbox.received().length === 2, 2000, "the idle notice once its last run ended");
            assert.match(JSON.parse(inbox.received()[1]!).text, IDLE_NOTICE);
          });
        },
        { parent: "boss-session", name: "worker" },
      );
    } finally {
      await fx.restore();
    }
  });
}

test("a child whose only live subagent already reported sends the idle notice", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    const gate = join(fx.stateDir, "gate");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate }, async () => {
          const s = await startNamedSession(fx, "worker", SELF);
          await s.emit("agent_start");
          await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
          await pollUntil(() => fx.runWaitCalls().length === 1, 2000, "the child's run-wait");
          writeFileSync(join(fx.agentDir(SELF, "kid"), "report"), "done");
          await s.emit("agent_end", { messages: [assistant("stop")] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => inbox.received().length === 1, 2000, "the idle notice");
          assert.match(JSON.parse(inbox.received()[0]!).text, IDLE_NOTICE);
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("new work delivered to a child that already reported holds back the parent's idle notice until the child reports again", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    const childInbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    const gate = join(fx.stateDir, "gate");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate }, async () => {
          const s = await startNamedSession(fx, "worker", SELF);
          await s.emit("agent_start");
          await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
          await pollUntil(() => fx.runWaitCalls().length === 1, 2000, "the child's run-wait");
          const child = agentJson(fx, SELF, "kid");
          fx.setPanes([
            agentPane({ pane: "%1", session: SELF, name: "worker" }),
            agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path }),
            agentPane({ pane: "%9", session: child.session, name: "kid", inbox: childInbox.path }),
          ]);
          const report = join(fx.agentDir(SELF, "kid"), "report");
          const work = join(fx.agentDir(SELF, "kid"), "work");
          writeFileSync(report, "first account");
          const past = new Date(Date.now() - 2000);
          utimesSync(report, past, past);

          const sent = await s.tools.get("message_agent").execute("c", { to: "kid", message: "fix the review findings" });
          assert.equal(sent.content[0].text, "delivered to kid by inbox");
          await s.emit("agent_end", { messages: [assistant("stop")] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
          assert.equal(inbox.received().length, 0, "a child at work on new work is not idle without news, though its earlier report is still there");
          assert.ok(existsSync(work), "delivering new work marks it before the message goes");
          assert.equal(readFileSync(report, "utf8"), "first account", "the earlier report stays readable");

          writeFileSync(report, "second account");
          const future = new Date(Date.now() + 2000);
          utimesSync(report, future, future);
          await s.emit("agent_start");
          await s.emit("agent_end", { messages: [assistant("stop")] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => inbox.received().length === 1, 2000, "the idle notice after the child reported on its new work");
          assert.match(JSON.parse(inbox.received()[0]!).text, IDLE_NOTICE);

          await s.emit("agent_start");
          writeFileSync(report, "third account");
          utimesSync(report, past, past);
          const steered = await s.tools.get("steer_subagent").execute("c", { to: "kid", message: "also check the docs" });
          assert.equal(steered.content[0].text, "delivered to kid by inbox");
          await s.emit("agent_end", { messages: [assistant("stop")] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
          assert.equal(inbox.received().length, 1, "a steer is new work too, so its report must be newer than it");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a restart's first idle settle waits for discovery and finds the live run", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    const runsGate = join(fx.stateDir, "runs-gate");
    const waitGate = join(fx.stateDir, "wait-gate");
    fx.writeAgent(SELF, "kid", { session: "kid-session", run: "live-kid" });
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path }),
      agentPane({ pane: "%3", session: "kid-session", name: "kid" }),
    ]);
    const output = join(fx.stateDir, "runs", "live-kid", "output");
    mkdirSync(join(fx.stateDir, "runs", "live-kid"), { recursive: true });
    writeFileSync(output, "line\n");
    fx.setRuns([{ id: "live-kid", name: "kid", parent: SELF, pane: "%3", session: "kid-session", startedAt: "2023-11-14T22:00:00Z", output }]);
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv(
          { KIDO_FAKE_RUNS_GATE: runsGate, KIDO_FAKE_RUN_WAIT_GATE: waitGate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) },
          async () => {
            const s = await startNamedSession(fx, "worker", SELF);
            await s.emit("agent_start");
            await pollUntil(() => fx.runsCalls().length >= 1, 2000, "the restart's discovery read");
            await s.emit("agent_end", { messages: [assistant("stop")] });
            const settling = s.emit("agent_settled", {}, { isIdle: () => true });
            assert.equal(await pendingState(settling, 300), "pending", "the settle waits for the restart's discovery");
            writeFileSync(runsGate, "");
            await settling;
            assert.equal(inbox.received().length, 0, "the live unreported child found by discovery is not idle without news");

            await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("live-kid")), 2000, "the live child's run-wait");
            writeFileSync(waitGate, "");
            await pollUntil(() => customMessages(s, "kido-notice").length === 1, 3000, "the live child's ending notice");
            await s.emit("agent_start");
            await s.emit("agent_end", { messages: [assistant("stop")] });
            await s.emit("agent_settled", {}, { isIdle: () => true });
            await pollUntil(() => inbox.received().length === 1, 2000, "the idle notice once its live child ended");
            assert.match(JSON.parse(inbox.received()[0]!).text, IDLE_NOTICE);
          },
        );
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

test("the parent watch finds its parent by the session option alone, without a pi root", async () => {
  const fx = makeFixture();
  try {
    parentSetup(fx, "/tmp/none.sock");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_PARENT_POLL_MS: "20" }, async () => {
          const s = await startWithSpies(fx, kidoPi, SELF);
          const editing = paneRow({ pane_id: "%2", kido_session: "boss-session", kido_name: "boss", kido_inbox: "/tmp/none.sock", pane_program_status: "" });
          fx.setPanes([agentPane({ pane: "%1", session: SELF, name: "worker" }), editing]);
          await pollUntil(
            () => fx.tmuxCalls().filter((argv) => argv[0] === "list-panes" || argv[0] === "display-message").length >= 3,
            2000,
            "several parent readings",
          );
          assert.equal(s.shutdowns(), 0, "a parent in the editor, with no root, never ends the child");
          fx.setPanes([agentPane({ pane: "%1", session: SELF, name: "worker" })]);
          await pollUntil(() => s.shutdowns() > 0, 2000, "the child to shut down once the parent pane is gone");
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

test("a stop request silences the error ending it causes", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startWithSpies(fx, kidoPi, SELF);
        await s.emit("agent_start");
        assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "boss-session", name: "boss", pane: "%2" } })), "ok");
        assert.equal(s.shutdowns(), 1);
        await s.emit("agent_end", { messages: [assistant("error", "Claude Code process exited with code 143")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "a stopped child's dying turn sends no error notice");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("an interrupted turn's error ending sends no notice either", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startWithSpies(fx, kidoPi, SELF);
        await s.emit("agent_start");
        assert.equal(await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "boss-session", name: "boss", pane: "%2" } })), "ok");
        assert.equal(s.aborts(), 1);
        await s.emit("agent_end", { messages: [assistant("error", "Claude Code process exited with code 143")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "an interrupted turn's error ending is not news");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a child whose run already has an outcome sends no notice for its error ending", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    fx.setRuns([{ id: SELF, name: "worker", parent: "boss-session", pane: "%1", output: "", startedAt: "", outcome: { result: "stopped" } }]);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await s.emit("agent_start");
        await s.emit("agent_end", { messages: [assistant("error", "Claude Code process exited with code 143")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "a run that already ended by another account is not an error to report");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a stop accepted while an ending's outcome query runs still silences it", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    const gate = join(fx.stateDir, "runs-gate");
    await asSubagent(
      fx,
      SELF,
      async () => {
        await withEnv({ KIDO_FAKE_RUNS_GATE: gate }, async () => {
          const s = await startWithSpies(fx, kidoPi, SELF);
          await s.emit("agent_end", { messages: [assistant("error", "Claude Code process exited with code 143")] });
          const settling = s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => fx.runsCalls().length >= 1, 2000, "the ending's outcome query");
          assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "boss-session", name: "boss", pane: "%2" } })), "ok");
          assert.equal(s.shutdowns(), 1);
          writeFileSync(gate, "");
          await settling;
          assert.equal(inbox.received().length, 0, "a stop during the outcome query still silences the ending");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});
