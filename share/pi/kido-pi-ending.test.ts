import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, mkdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import kidoPi from "./kido-pi.ts";

import {
  makeFixture,
  selfPane,
  paneRow,
  agentPane,
  startNamedSession,
  startWithSpies,
  startSessionCore,
  fakeCtx,
  asSubagent,
  withEnv,
  pollUntil,
  pendingState,
  agentJson,
  customMessages,
  sendToInbox,
  envelope,
  parentSetup,
  assistant,
  idleTurn,
  assertReport,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

const NO_TURN = "no turn ever ran: the task was delivered and the session never started work on it (the pane's own screen, kept with the run, is the only account of why)";

function paneReads(fx: Fixture): number {
  return fx.tmuxCalls().filter((argv) => argv[0] === "list-panes").length;
}

async function duringParentLookup(fx: Fixture, settle: () => Promise<unknown>, action: () => Promise<void> | void): Promise<void> {
  const gate = join(fx.stateDir, "tmux-gate");
  await withEnv({ KIDO_FAKE_TMUX_GATE: gate }, async () => {
    const before = paneReads(fx);
    const settling = settle();
    await pollUntil(() => paneReads(fx) > before, 2000, "the ending's parent lookup");
    await action();
    writeFileSync(gate, "");
    await settling;
  });
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
      await s.emit("agent_end", { messages: [assistant("error", undefined, "boom")] });
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

test("a settled turn sends its text as the report; a later settle on the same work sends nothing", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await idleTurn(s, "done");
        await pollUntil(() => inbox.received().length === 1, 2000, "the report");
        assertReport(inbox, 0, "done");
        assert.equal(readFileSync(join(fx.agentDir("boss-session", "worker"), "report"), "utf8"), "done");

        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 1, "a redundant settle does not resend");

        await s.emit("turn_end", { toolResults: [{}] });
        await s.emit("turn_start");
        await s.emit("agent_end", { messages: [assistant("stop", "after the tools")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 1, "a reported child sends nothing, even when pi starts another turn for the tool result");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a child woken by its own async_bash ending notice after it reported sends no report", async () => {
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
          await idleTurn(s, "done");
          await pollUntil(() => inbox.received().length === 1, 2000, "the report");

          await s.emit("agent_start");
          await s.tools.get("async_bash").execute("c", { command: "make", name: "build" });
          await pollUntil(() => fx.runWaitCalls().length === 1, 2000, "the run-wait");
          writeFileSync(gate, "");
          await pollUntil(() => customMessages(s, "kido-notice").length === 1, 3000, "the run's ending notice");

          await idleTurn(s, "after the notice");
          assert.equal(inbox.received().length, 1, "a notice that wakes a child after its report is not unreported work");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a child woken by a user prompt after it reported sends no report", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await idleTurn(s, "done");
        await pollUntil(() => inbox.received().length === 1, 2000, "the report");

        await idleTurn(s, "a typed prompt");
        assert.equal(inbox.received().length, 1, "a typed prompt is not the parent's new work");
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
  test(`a child waiting on its own live ${tool} run sends no report, then sends one once that run ends`, async () => {
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
            await s.tools.get(tool).execute("c", params);
            await pollUntil(() => fx.runWaitCalls().length === 1, 2000, "the run-wait");
            await s.emit("agent_end", { messages: [assistant("stop", "done")] });
            await s.emit("agent_settled", {}, { isIdle: () => true });
            assert.equal(inbox.received().length, 0, "no report while its run is live");

            writeFileSync(gate, "");
            await pollUntil(() => customMessages(s, "kido-notice").length === 1, 3000, "the run's ending notice");
            assert.equal(inbox.received().length, 0, "the ending notice goes to the child, not the parent");

            await idleTurn(s, "done");
            await pollUntil(() => inbox.received().length === 1, 2000, "the report once its last run ended");
            assertReport(inbox, 0, "done");
          });
        },
        { parent: "boss-session", name: "worker" },
      );
    } finally {
      await fx.restore();
    }
  });
}

test("a child whose only live subagent already reported sends the report", async () => {
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
          await s.emit("agent_end", { messages: [assistant("stop", "my account")] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => inbox.received().length === 1, 2000, "the report");
          assertReport(inbox, 0, "my account");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("new work delivered to a child that already reported holds back the parent's report until the child reports again", async () => {
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
          assert.equal(inbox.received().length, 0, "a child at work on new work is not reported, though its earlier report is still there");
          assert.ok(existsSync(work), "delivering new work marks it before the message goes");
          assert.equal(readFileSync(report, "utf8"), "first account", "the earlier report stays readable");

          writeFileSync(report, "second account");
          const future = new Date(Date.now() + 2000);
          utimesSync(report, future, future);
          await idleTurn(s, "my account");
          await pollUntil(() => inbox.received().length === 1, 2000, "the report after the child reported on its new work");
          assertReport(inbox, 0, "my account");

          await s.emit("agent_start");
          writeFileSync(report, "third account");
          utimesSync(report, past, past);
          const steered = await s.tools.get("message_agent").execute("c", { to: "kid", message: "also check the docs", mode: "steer" });
          assert.equal(steered.content[0].text, "delivered to kid by inbox");
          await s.emit("agent_end", { messages: [assistant("stop", "a later account")] });
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

test("a restart's first settle waits for discovery and finds the live run", async () => {
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
            await s.emit("agent_end", { messages: [assistant("stop", "done")] });
            const settling = s.emit("agent_settled", {}, { isIdle: () => true });
            assert.equal(await pendingState(settling, 300), "pending", "the settle waits for the restart's discovery");
            writeFileSync(runsGate, "");
            await settling;
            assert.equal(inbox.received().length, 0, "the live unreported child found by discovery holds the report back");

            await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("live-kid")), 2000, "the live child's run-wait");
            writeFileSync(waitGate, "");
            await pollUntil(() => customMessages(s, "kido-notice").length === 1, 3000, "the live child's ending notice");
            await idleTurn(s, "my account");
            await pollUntil(() => inbox.received().length === 1, 2000, "the report once its live child ended");
            assertReport(inbox, 0, "my account");
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
        await s.emit("agent_end", { messages: [assistant("error", undefined, "boom")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => inbox.received().length === 1, 2000, "the error notice");
        const notice = JSON.parse(inbox.received()[0]!);
        assert.equal(notice.text, `subagent stopped on an error: boom\nrun: ${SELF}\nmessage it to retry, or stop_run to end it`);
        assert.ok(!notice.text.includes("resume"));
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 1, "a redundant settle does not repeat the error notice");
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
    await root.emit("agent_end", { messages: [assistant("error", undefined, "boom")] });
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
          await pollUntil(() => paneReads(fx) >= 3, 2000, "several failing readings");
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
          await pollUntil(() => paneReads(fx) >= 6, 2000, "parent polls");
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
          await pollUntil(() => paneReads(fx) >= 1, 2000, "the first reading");
          await new Promise((r) => setTimeout(r, 120));
          const stuck = paneReads(fx);
          assert.equal(stuck, 1, "one reading in flight holds every later tick back");
          writeFileSync(gate, "");
          await pollUntil(() => paneReads(fx) >= 3, 2000, "later readings on the parent's own pane");
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
        await s.emit("agent_end", { messages: [assistant("error", undefined, "Claude Code process exited with code 143")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "a stopped child's dying turn sends no error notice");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("interrupt-and-steer suppresses the aborted turn's error and reports only the new work", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(fx, SELF, async () => {
      let aborts = 0;
      let noticesDuringAbort = -1;
      let messagesDuringAbort = -1;
      const s = await startSessionCore(fx, kidoPi, c => ({
        ...fakeCtx(SELF, c.ui),
        abort: async () => {
          aborts++;
          await c.emit("agent_end", { messages: [assistant("error", undefined, "terminated provider")] });
          await c.emit("agent_settled", {}, { isIdle: () => true });
          noticesDuringAbort = inbox.received().length;
          messagesDuringAbort = customMessages(c, "kido-message").length;
        },
      }));
      await s.emit("agent_start");
      assert.equal(await sendToInbox(fx.inboxPath(SELF), envelope("interrupt-and-steer", "do B instead", { from: { session: "boss-session", name: "boss", pane: "%2" } })), "ok");
      assert.equal(aborts, 1);
      assert.equal(noticesDuringAbort, 0, "the aborted turn sends no error, idle or report notice");
      assert.equal(messagesDuringAbort, 0, "new work waits until abort settles");
      const message = customMessages(s, "kido-message")[0]!;
      assert.ok(message.message.content.endsWith("do B instead"));
      assert.equal(message.message.details.work, true);
      await s.emit("message_start", { message: message.message });
      assert.ok(existsSync(join(fx.agentDir("boss-session", "worker"), "work")));
      await idleTurn(s, "done B");
      await pollUntil(() => inbox.received().length === 1, 2000, "the new work's report");
      assertReport(inbox, 0, "done B");
    }, { parent: "boss-session", name: "worker" });
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
        await s.emit("agent_end", { messages: [assistant("error", undefined, "Claude Code process exited with code 143")] });
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
          await s.emit("agent_end", { messages: [assistant("error", undefined, "Claude Code process exited with code 143")] });
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

test("a settled user abort sends neither an error nor a report", async () => {
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
        await s.emit("agent_end", { messages: [assistant("error", undefined, "boom")] });
        await s.emit("agent_settled", { aborted: true }, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "Escape during a retry is not an error to report");

        await idleTurn(s, "a cancelled turn", { aborted: true });
        assert.equal(inbox.received().length, 0, "a cancelled turn is not a report");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("work the parent writes during an ending's parent lookup silences the report", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await s.emit("agent_end", { messages: [assistant("stop", "done")] });
        await duringParentLookup(fx, () => s.emit("agent_settled", {}, { isIdle: () => true }), () => {
          writeFileSync(join(fx.agentDir("boss-session", "worker"), "work"), "");
        });
        assert.equal(inbox.received().length, 0, "the captured work was replaced while the lookup ran");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a stop accepted during an ending's parent lookup silences the report", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startWithSpies(fx, kidoPi, SELF);
        await s.emit("agent_end", { messages: [assistant("stop", "done")] });
        await duringParentLookup(fx, () => s.emit("agent_settled", {}, { isIdle: () => true }), async () => {
          assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "boss-session", name: "boss", pane: "%2" } })), "ok");
          assert.equal(s.shutdowns(), 1);
        });
        assert.equal(inbox.received().length, 0, "the stop arrived while the lookup ran");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a parent's queued message becomes work only when pi consumes it", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        assert.equal(await sendToInbox(s.inboxPath, envelope("message", "do B", { from: { session: "boss-session", name: "boss" } })), "ok");
        const queued = customMessages(s, "kido-message")[0]!;
        await idleTurn(s, "A is done");
        const report = join(fx.agentDir("boss-session", "worker"), "report");
        const past = new Date(Date.now() - 2000);
        utimesSync(report, past, past);
        await s.emit("message_start", { message: queued.message });
        await s.emit("agent_end", { messages: [assistant("stop", "B is done")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 2, "the report for A does not cover the consumed work B");
        assertReport(inbox, 1, "B is done");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("each parent message mode rewrites work when pi changes the content", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        const work = join(fx.agentDir("boss-session", "worker"), "work");
        const from = { session: "boss-session", name: "boss" };
        for (const [kind, customType] of [
          ["message", "kido-message"],
          ["steer", "kido-steer"],
          ["interrupt-and-steer", "kido-message"],
        ] as const) {
          assert.equal(await sendToInbox(s.inboxPath, envelope(kind, `do ${kind}`, { from })), "ok");
          const sent = customMessages(s, customType).at(-1)!;
          const past = new Date(Date.now() - 2000);
          writeFileSync(work, "");
          utimesSync(work, past, past);
          await s.emit("message_start", { message: { ...sent.message, content: `  ${sent.message.content}\n` } });
          assert.ok(statSync(work).mtimeMs > past.getTime(), `work is rewritten from the ${kind}'s details`);
        }
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a flagged message still marks work after pi settles idle before consuming it", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        assert.equal(await sendToInbox(s.inboxPath, envelope("message", "do B", { from: { session: "boss-session", name: "boss" } })), "ok");
        const queued = customMessages(s, "kido-message")[0]!;
        const dir = fx.agentDir("boss-session", "worker");
        const work = join(dir, "work");
        const past = new Date(Date.now() - 2000);
        writeFileSync(work, "");
        utimesSync(work, past, past);
        writeFileSync(join(dir, "report"), "earlier");
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await s.emit("message_start", { message: { ...queued.message, content: `  ${queued.message.content}\n` } });
        assert.ok(statSync(work).mtimeMs > past.getTime(), "work is rewritten after an idle settle");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a fresh extension instance marks work from a flagged message it did not send", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const first = await startNamedSession(fx, "worker", SELF);
        assert.equal(await sendToInbox(first.inboxPath, envelope("message", "do B", { from: { session: "boss-session", name: "boss" } })), "ok");
        const queued = customMessages(first, "kido-message")[0]!;
        const second = await startNamedSession(fx, "worker", SELF);
        const work = join(fx.agentDir("boss-session", "worker"), "work");
        const past = new Date(Date.now() - 2000);
        writeFileSync(work, "");
        utimesSync(work, past, past);
        await second.emit("message_start", { message: { ...queued.message, content: `  ${queued.message.content}\n` } });
        assert.ok(statSync(work).mtimeMs > past.getTime(), "work is rewritten from the message's own flag");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a peer's message is not work when pi consumes it", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        const dir = fx.agentDir("boss-session", "worker");
        writeFileSync(join(dir, "work"), "");
        const past = new Date(Date.now() - 2000);
        utimesSync(join(dir, "work"), past, past);
        writeFileSync(join(dir, "report"), "A is done");
        assert.equal(await sendToInbox(s.inboxPath, envelope("message", "hello", { from: { session: "peer-x", name: "peer" } })), "ok");
        await s.emit("message_start", { message: customMessages(s, "kido-message")[0]!.message });
        await s.emit("agent_end", { messages: [assistant("stop")] });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "a peer's message creates no report obligation");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a failed discovery at settlement is not cached as no live children", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    const failOnce = join(fx.stateDir, "runs-fail-once");
    const waitGate = join(fx.stateDir, "wait-gate");
    const childDir = fx.writeAgent(SELF, "kid", { session: "kid-session", run: "live-kid" });
    writeFileSync(join(childDir, "report"), "done");
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
        await withEnv({ KIDO_FAKE_RUNS_FAIL_ONCE: failOnce, KIDO_FAKE_RUN_WAIT_GATE: waitGate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) }, async () => {
          const s = await startNamedSession(fx, "worker", SELF);
          await s.emit("agent_end", { messages: [assistant("stop", "my account")] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
          assert.equal(inbox.received().length, 0, "a failed read is not evidence that nothing is live");

          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => inbox.received().length === 1, 2000, "the report after a successful retry");
          assertReport(inbox, 0, "my account");
          await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("live-kid")), 2000, "the live child's watch after the retry");
        });
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});
