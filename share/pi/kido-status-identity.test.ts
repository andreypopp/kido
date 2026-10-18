import { test } from "node:test";

import assert from "node:assert/strict";

import { writeFileSync } from "node:fs";

import { withEnv, jsonLines, commandWork, makeFixture, fakeCtx, startSessionCore, startSession, loadExtensions, freshExtensions, DEFAULT_SESSION, asSubagent, pollUntil, pollForStable, sendToInbox, envelope, twoPeers, argAfter, streamMessages, streamEnvelope, startWithShutdownSpy } from "./kido-fixture.ts";

// Pins a real incident: every KIDO_AGENT_* variable is inherited by anything an
// agent's process starts, so a nested pi run (a human debugging, a tool shelling
// out) arrives with a child's entire environment. Trusting it killed two live
// agents. What tells the two apart: the real child's pi session id is the run id,
// a nested pi mints its own.
test("a process that merely inherited a subagent's environment is not a subagent", async () => {
  const fx = makeFixture();
  try {
    // What the pane lookup finds: the REAL agent's record, window and all.
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    fx.setParentAlive("gone");
    await asSubagent(
      "the-real-childs-run",
      async () => {
        const factory = await freshExtensions();
        // This process's own session id: minted by pi, not the run id.
        const s = await startWithShutdownSpy(fx, factory, "a-nested-pis-own-session");

        const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
        const results = await s.emit("before_agent_start", event);
        assert.ok(results.every((r) => r === undefined), "it is told nothing about a parent it does not have");

        const result = await s.tools.get("notify_parent").execute("call-1", { summary: "not mine to send" });
        assert.match(result.content[0].text, /no parent/i, "notify_parent refuses rather than reporting to the real child's parent");
        assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "and sends nothing");

        // Several times over the 20ms parent poll, whose parent is gone: the
        // child's clock does not belong to this process, so it may not end it.
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300));
        assert.equal(s.shutdowns(), 0, "it never self-exits on a child's parent poll");
        assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "nor does it send an idle notice as a child");

        await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
        assert.equal(fx.lastRunOutcomeArgs(), undefined, "the real child's run is never given an outcome");
      },
      { KIDO_PARENT_POLL_MS: "20" },
    );
  } finally {
    await fx.restore();
  }
});

// Negative control for the test above: a fresh spawn (`pi --session-id
// <run-id>`) and a resume (`pi --session <run-id>`) both give the child's own
// session id as the run id.
test("a real subagent, fresh or resumed, is still a subagent in every respect", async () => {
  for (const runID of ["fresh-spawn-run"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
      await asSubagent(
        runID,
        async () => {
          const factory = await freshExtensions();
          const s = await startWithShutdownSpy(fx, factory, runID);

          const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
          await s.emit("before_agent_start", event);
          assert.match(event.systemPromptOptions.promptGuidelines.join("\n"), /notify_parent/, `${runID}: the standing instruction still rides on every turn`);

          const result = await s.tools.get("notify_parent").execute("call-1", { summary: "done" });
          assert.ok(result.content[0].text.length > 0, `${runID}: notify_parent still runs`);
          const sent = await fx.waitForLog("boss-session", "notice");
          assert.equal(sent!.text, "done", `${runID}: the notice reaches the parent`);

          await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
          assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", runID], `${runID}: the outcome is recorded against the run`);
        },
        { KIDO_PARENT_POLL_MS: "5000" },
      );
    } finally {
      await fx.restore();
    }
  }
});

// A session id not yet known - null until session_start resolves one, and
// forever outside tmux or with no kido on PATH - reads as "not a subagent", not
// "probably one". Driven by taking TMUX_PANE away, which leaves the id
// unresolved while the rest of a child's environment is in place.
test("an unresolved session id is not a subagent, whatever the environment claims", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    delete process.env.TMUX_PANE; // fx.restore() puts it back
    await asSubagent(
      DEFAULT_SESSION, // would match the session id, had one ever been resolved
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);

        const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
        const results = await s.emit("before_agent_start", event);
        assert.ok(results.every((r) => r === undefined), "no standing instruction for a session that may not be a child at all");
        assert.equal(event.systemPromptOptions.promptGuidelines.length, 1, "the always-on never-sleep rule still applies");

        const result = await s.tools.get("notify_parent").execute("call-1", { summary: "nobody to tell" });
        assert.match(result.content[0].text, /no parent/i, "notify_parent refuses rather than guessing");
      },
      {},
    );
  } finally {
    await fx.restore();
  }
});

test("interleaving: an inbound ask from the same target is refused even while the outbound send to it is still in flight", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a
    fx.setMessageFailTo(undefined);
    const gate = fx.logFile + ".gate";
    process.env.KIDO_FAKE_MESSAGE_GATE = gate;
    try {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");

      // Held for 800ms by the fake kido: this only races because runKido shells
      // out via spawn rather than execFileSync, which could never let an inbound
      // connection be dispatched before the send finished.
      const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
      await pollUntil(() => commandWork.size > 0, 2000, "the outbound send's fake kido to start");

      // The load-bearing assertion: "refused" alone is true whether or not the
      // send is still running (the waiter is not dropped until a reply or
      // timeout), so `inFlight` - the fake kido's log entry not yet written - is
      // the only evidence the send really had not finished yet.
      let inFlight = false;
      let n = 0;
      await pollUntil(async () => {
        inFlight = fx.lastLogFor("peer-a", "ask") === undefined;
        const resp = await sendToInbox(s.inboxPath, envelope("ask", "sneaky", { id: `race-${n++}`, from: { session: "peer-a" } }));
        return resp === "refused";
      }, 2000, "an inbound ask from the target to be refused");
      assert.ok(inFlight, "the outbound send must still be in flight when the inbound ask is refused, or this pins nothing");
      writeFileSync(gate, "");

      const sent = await fx.waitForLog("peer-a", "ask");
      await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent.id, from: { session: "peer-a" } }));
      const outcome = await p1;
      assert.equal(outcome.content[0].text, "done");
    } finally {
      delete process.env.KIDO_FAKE_MESSAGE_GATE;
    }
  } finally {
    await fx.restore();
  }
});

test("a stream that never goes quiet for 1s is still delivered 30s after its first chunk (TestStreamMaxWait)", async (t) => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);

    t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
    for (let i = 0; i < 59; i++) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(`line ${i}`)), "ok");
      t.mock.timers.tick(500);
    }
    assert.equal(streamMessages(s.messages).length, 0, "29.5s of chunks 0.5s apart: the debounce never fires");
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 59")), "ok");
    t.mock.timers.tick(500);
    assert.equal(streamMessages(s.messages).length, 1, "30s after the first chunk the held batch goes anyway");
    assert.match(streamMessages(s.messages)[0].message.content, /line 59/);
  } finally {
    t.mock.timers.reset();
    await fx.restore();
  }
});

// Also pins what the poll asks: `kido get-agent` naming its own parent
// session, never `kido tool list_runs`, whose per-pane view is the wrong source for a liveness fact.
test("parent-liveness poll: does not shut down while the parent is alive, and asks get-agent about its own parent session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("alive");
    await withParentEnv("boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      const agentsBefore = fx.agentsCallCount();
      await pollUntil(() => fx.parentAliveCalls().length >= 3, 2000, "several get-agent polls");
      assert.equal(s.shutdowns(), 0, "a live, correctly-matched parent must never trigger a shutdown");
      assert.deepEqual(
        fx.parentAliveCalls()[0],
        ["get-agent", "boss-session"],
        "the poll asks about its own parent session, by session id and nothing else",
      );
      assert.equal(
        fx.agentsCallCount(),
        agentsBefore,
        "and never through kido tool list_runs, whose per-pane view can lose the parent's record",
      );
      await s.emit("session_shutdown");
    });
  } finally {
    await fx.restore();
  }
});

// A kido that cannot answer has said nothing about the parent, so it must never
// be read as a dead one.
test("parent-liveness poll: a kido that cannot answer is not evidence, and never ends the child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("fail");
    await withParentEnv("boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      await pollUntil(() => fx.parentAliveCalls().length >= 4, 2000, "several failed get-agent polls");
      assert.equal(s.shutdowns(), 0, "a failing query says nothing; it must not be read as a dead parent");
      await s.emit("session_shutdown");
    });
  } finally {
    await fx.restore();
  }
});

// Pins the absence of a debounce: one "false" reading ends the session, within
// about one poll interval.
test("parent-liveness poll: a parent session with no live holder counts as gone, on the first reading", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("gone");
    fx.setParentAliveDelay(100);
    await withParentEnv("boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a parent session with no live holder");
      assert.equal(fx.parentAliveCalls().length, 1, "one reading is conclusive; nothing waits for a second");
      await s.emit("session_shutdown");
    });
  } finally {
    await fx.restore();
  }
});

// setInterval fires on schedule whether or not the previous callback finished,
// so a reading slower than the interval would have every tick spawn another
// process on top of those already waiting; pollInFlight guards against that pile-up.
test("parent-liveness poll: a slow reply does not let ticks pile up concurrent readings", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    const delayMs = 100;
    const pollMs = 10;
    fx.setParentAlive("alive");
    fx.setParentAliveDelay(delayMs);
    await withParentEnv("boss-session", pollMs, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      const started = Date.now();
      await new Promise((r) => setTimeout(r, 500));
      const elapsed = Date.now() - started;
      const calls = fx.parentAliveCalls().length;
      const sequential = Math.ceil(elapsed / delayMs) + 1; // +1: the reading in flight right now
      assert.ok(calls >= 2, `only ${calls} readings in ${elapsed}ms - the poll stopped running, so this proves nothing`);
      assert.ok(
        calls <= sequential,
        `${calls} readings in ${elapsed}ms, want at most ${sequential} - ticks every ${pollMs}ms are piling up concurrent ${delayMs}ms calls`,
      );
      assert.equal(s.shutdowns(), 0, "and a slow but affirmative answer is still an affirmative answer");
      await s.emit("session_shutdown");
    });
  } finally {
    await fx.restore();
  }
});

// The second incident: two pi processes on one session id. kido refuses
// the newcomer's claim (exit 6, Run.write_pi), and what this
// pins is everything that must then NOT happen - no second report, no
// removal report on the way out, all of which would be writes to a
// record that belongs to the process still running. The
// notify is the only thing the user gets, and it names where the other
// one is.
//
// The claim is the session's first report, awaited: every assertion here
// is about what came after it, so the one status call in the log is the
// claim itself and its presence is what distinguishes a refusal from a
// pi that simply never spoke to kido at all.
test("a second pi on one session id claims nothing, reports nothing, and says so once", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    process.env.KIDO_FAKE_SESSION_HELD = "1";
    const s = await startSession(fx);

    assert.equal(fx.statusReportCount(), 1, "the claim was attempted exactly once");
    assert.equal(argAfter(fx.lastStatusArgs(), "--caller"), DEFAULT_SESSION);

    const notified = s.notifications;
    assert.equal(notified.length, 1, `want one notification, got ${JSON.stringify(notified)}`);
    assert.match(notified[0].message, /already open in pane %9 \(pid 4242\)/, "names where the holder is");
    assert.equal(notified[0].type, "warning");

    await s.emit("turn_start");
    await s.emit("tool_call");
    await s.emit("agent_settled", {}, { isIdle: () => true });
    await s.emit("session_shutdown", { reason: "quit" });
    // A report is a detached subprocess appending to a file; when every
    // such subprocess has closed, "nothing yet" cannot become "something".
    await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "detached reports finish");
    assert.equal(fx.statusReportCount(), 1, "an untracked pi reports nothing after the refusal");
    assert.equal(fx.statusReportsWithRemove().length, 0, "and never removes the holder's record");
  } finally {
    await fx.restore();
  }
});

// The pair of the test below, which a gate refusing every session would also pass.
test("a headless pi claims nothing and reports nothing", async () => {
  const fx = makeFixture();
  try {
    const s = await startSessionCore(fx, loadExtensions, (c) => ({ ...fakeCtx(undefined, c.ui), hasUI: false }));
    await s.emit("turn_start");
    await s.emit("session_shutdown", { reason: "quit" });
    await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "detached reports finish");
    assert.equal(fx.statusReportCount(), 0, "a headless pi never reports to kido");
  } finally {
    await fx.restore();
  }
});

// Negative control: a gate that refused every session would pass the tests above too.
test("the first pi on a session id is tracked and goes on reporting", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await pollUntil(() => fx.identityReports().length >= 2, 2000, "the claim and the first identity report from a tracked session");
    for (const args of fx.identityReports()) {
      for (const flag of ["--status", "--title", "--ended"]) assert.ok(!args.includes(flag), args.join(" "));
    }
    assert.deepEqual(s.notifications, [], "nothing to tell the user about");
    await s.emit("session_shutdown", { reason: "quit" });
  } finally {
    await fx.restore();
  }
});

test("identity reports read the live pi session name on every report and rename event", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    await pollUntil(() => fx.identityReports().length >= 2, 2000, "initial reports");
    assert.ok(fx.identityReports().every((args) => argAfter(args, "--name") === ""));
    s.pi.sessionName = "Review - exact";
    await s.emit("session_info_changed", { name: "not the authoritative name" });
    await pollUntil(() => fx.identityReports().some((args) => argAfter(args, "--name") === "Review - exact"), 2000, "rename report");
    const n = fx.identityReports().length;
    await s.emit("session_info_changed", {});
    await pollForStable(() => fx.identityReports().length, 200, 2000, "the identity report count");
    assert.equal(fx.identityReports().length, n, "an unchanged rename is coalesced");
    assert.equal(argAfter(fx.identityReports().at(-1)!, "--name"), "Review - exact");
    s.pi.sessionName = undefined;
    await s.emit("session_info_changed", {});
    await pollUntil(() => argAfter(fx.identityReports().at(-1)!, "--name") === "", 2000, "cleared name report");
  } finally {
    await fx.restore();
  }
});

async function withParentEnv<T>(session: string, pollMs: number, fn: () => Promise<T>): Promise<T> {
  const vars = { KIDO_AGENT_PARENT_SESSION: session, KIDO_PARENT_POLL_MS: String(pollMs) };
  return withEnv({ ...vars, KIDO_AGENT_RUN_ID: DEFAULT_SESSION }, fn);
}
