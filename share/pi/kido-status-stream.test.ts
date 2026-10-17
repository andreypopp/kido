import { test } from "node:test";

import assert from "node:assert/strict";

import { streamBatch } from "./kido-agents.ts";

import { jsonLines, last, commandWork, makeFixture, startSession, freshExtensions, DEFAULT_SESSION, asSubagent, pollUntil, sendToInbox, envelope, streamMessages, streamEnvelope } from "./kido-fixture.ts";

// Negative control (second half): the same chunks after a turn with no tool calls
// must produce nothing until the debounce fires - flushing on every turn_end
// would buy an endless run of empty turns.
test("a batch rides a turn that ran tools, and a turn that ran none leaves it held for the debounce (TestStreamBatchRidesAToolTurn)", { timeout: 10000 }, async (t) => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, { idle: () => false });
    t.mock.timers.enable({ apis: ["setTimeout", "Date"] });

    for (const text of ["line 1\nline 2", "line 3", "line 4\nline 5"]) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(text)), "ok");
    }
    assert.equal(streamMessages(s.messages).length, 0, "a chunk on the wire reaches the model on nobody's schedule but flushStreams'");

    await s.emit("turn_end", { turnIndex: 0, toolResults: [{ role: "toolResult" }] });
    const sent = streamMessages(s.messages);
    assert.equal(sent.length, 1, "three chunks during one turn are one message, not three");
    assert.match(sent[0].message.content, /line 1[\s\S]*line 5/, "the one message carries every line that arrived");
    assert.equal((sent[0].opts as any).deliverAs, "steer", "a batch is steered, so the turn already committed to is the one that carries it");

    for (const text of ["line 6", "line 7"]) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(text)), "ok");
    }
    await s.emit("turn_end", { turnIndex: 1, toolResults: [] });
    assert.equal(streamMessages(s.messages).length, 1, "a turn with no tool calls was the agent stopping: flushing there would buy a turn, and another");

    t.mock.timers.tick(1000);
    assert.equal(streamMessages(s.messages).length, 2, "the held batch is flushed by the debounce");
    assert.match(streamMessages(s.messages)[1].message.content, /line 6[\s\S]*line 7/, "the held lines arrive on the debounce instead");
  } finally {
    t.mock.timers.reset();
    await fx.restore();
  }
});

test("a chunk flushes after 1s of quiet, and a chunk inside that second restarts it: one delivery with both (TestStreamDebounce)", { timeout: 10000 }, async (t) => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);

    t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 1")), "ok");
    t.mock.timers.tick(600);
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 2")), "ok");
    t.mock.timers.tick(999);
    assert.equal(streamMessages(s.messages).length, 0, "999ms after the second chunk: the restarted timer must still hold both chunks");

    t.mock.timers.tick(1);
    assert.equal(streamMessages(s.messages).length, 1, "1s after the second chunk: the restarted timer must flush once");
    assert.match(streamMessages(s.messages)[0].message.content, /line 1[\s\S]*line 2/, "both chunks arrive in the one message");
    t.mock.timers.tick(1300);
    assert.equal(streamMessages(s.messages).length, 1, "and nothing else follows");
  } finally {
    t.mock.timers.reset();
    await fx.restore();
  }
});

// The cap lives in the receiver, since it is what spends the parent's context;
// tail, not head, since what a failure has to say, it says last.
test("a batch is the tail, with one line saying how many it left out and where they are (TestBatchTailAndOmittedCount)", async () => {
  const thousand = Array.from({ length: 1000 }, (_, i) => `line ${i + 1}`);
  const batch = streamBatch(thousand, "/state/runs/run-1/output").split("\n");
  assert.equal(batch[0], "... 800 lines omitted (see /state/runs/run-1/output)", "the first line of a capped batch says what is missing and where to read it");
  assert.equal(batch.length, 201, "200 lines and the one that accounts for the rest");
  assert.equal(batch[1], "line 801", "the tail, not the head");
  assert.equal(batch[200], "line 1000");

  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(thousand.join("\n"))), "ok");
    await s.emit("turn_end", { turnIndex: 0, toolResults: [{ role: "toolResult" }] });

    const sent = streamMessages(s.messages);
    assert.equal(sent.length, 1);
    const lines = sent[0].message.content.split("\n");
    assert.match(lines[0], /^async run "chatty" output \(run run-1\)$/, "the header names the run, which is all the collapsed row shows");
    assert.equal(lines[1], "... 800 lines omitted (see /state/runs/run-1/output)");
    assert.equal(lines.at(-1), "line 1000");
  } finally {
    await fx.restore();
  }
});

// A run's completion notice must never reach the model before the output it is
// the ending of; lib/async_run.ml sends the last chunk first, and this is
// the receiving half, where a held batch is flushed by the notice's own arrival.
test("a completion notice flushes whatever output was still held, and arrives after it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 1\nline 2")), "ok");
    assert.equal(streamMessages(s.messages).length, 0, "nothing is flushed on arrival");

    assert.equal(
      await sendToInbox(s.inboxPath, envelope("notice", 'async run "chatty" completed: exit status 0', { from: { session: "", name: "chatty" } })),
      "ok",
    );
    const kinds = s.messages.map((m) => m.message.customType);
    assert.deepEqual(kinds, ["kido-stream", "kido-notice"], "the held batch goes first; the ending follows the output it is the ending of");
  } finally {
    await fx.restore();
  }
});

// notify_parent is sent via runKido and awaited, since a deliberate tool call has
// The agent list says this session's parent is "parent-x"; the environment says
// "boss-session", which is what `kido tool notify_parent` reads and what the notice
// must be addressed to - asserting the latter, and that nothing was listed, pins that.
// The cap is `kido tool notify_parent`'s alone: the schema must not reject a long
// call, and the tool must pass the summary on whole, byte for byte.
test("notify_parent sends to the environment's parent without listing agents, and passes a summary over the cap whole", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const listedBefore = fx.agentsCallCount();
      const tool = s.tools.get("notify_parent");
      const result = await tool.execute("call-1", { summary: "the answer is 42" });
      assert.ok(result.content[0].text.length > 0, "the tool reports what happened");
      const sent = await fx.waitForLog("boss-session", "notice");
      assert.equal(sent!.text, "the answer is 42", "the notice carries the summary verbatim");
      assert.equal(fx.agentsCallCount(), listedBefore, "and no agent list was fetched to find it");

      const longSummary = "x".repeat(4500);
      const long = await tool.execute("call-2", { summary: longSummary });
      assert.ok(long.content[0].text.length > 0, "the call succeeds rather than failing schema validation");
      const longSent = await fx.waitForLog("boss-session", "notice");
      assert.equal(longSent!.text, longSummary, "the whole report reaches kido untouched; where it is split, and what is kept, is the command's own business");
    });
  } finally {
    await fx.restore();
  }
});

test("set_status accepts an activity over the byte cap and reports it whole", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const tool = s.tools.get("set_status");
    const longActivity = "y".repeat(500);

    await tool.execute("call-1", { activity: longActivity });
    await s.emit("agent_settled", {}, { isIdle: () => true });
    let report: string[] | undefined;
    await pollUntil(() => {
      report = fx.identityReports().find((args) => {
        const i = args.indexOf("--activity");
        return i >= 0 && args[i + 1] !== "";
      });
      return report !== undefined;
    }, 2000, "a status report reflecting the activity");
    const i = report!.indexOf("--activity");
    assert.equal(report![i + 1], longActivity, "the report carries the same untruncated activity");
    await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "detached reports finish");
    assert.equal(fx.setStatusCalls().length, 0);
  } finally {
    await fx.restore();
  }
});

test("set_status without a reporter sends the activity as a positional argument", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx, { sessionId: "" });
    const activity = "-" + "y".repeat(500);
    await s.tools.get("set_status").execute("call-1", { activity });
    let call: string[] | undefined;
    await pollUntil(() => (call = last(fx.setStatusCalls())) !== undefined, 2000, "a kido tool set_status call");
    assert.deepEqual(call, ["tool", "set_status", "--", activity]);
    assert.equal(fx.identityReports().length, 0);
  } finally {
    await fx.restore();
  }
});

test("notify_parent from a session with no parent refuses clearly, and sends nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx); // root session: no KIDO_AGENT_PARENT_SESSION
    const tool = s.tools.get("notify_parent");
    const result = await tool.execute("call-1", { summary: "nobody to tell" });
    assert.match(result.content[0].text, /no parent/i, "the refusal names the reason rather than reading as a silent no-op");
    assert.equal(jsonLines(fx.logFile).length, 0, "nothing was sent");
  } finally {
    await fx.restore();
  }
});

// Pins a real bug: a turn ending with a provider error left a child idle until
// the idle-exit clock ended it, so the parent's only notice was "completed
// without reporting" - the error itself never reached it.
test("a subagent's errored turn notifies the parent at once, naming the error and how to continue", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-errored", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-errored" });
      await s.emit("agent_end", {
        messages: [{ role: "assistant", stopReason: "error", errorMessage: "prompt-capture: no capture for this system prompt" }],
      });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      const sent = await fx.waitForLog("boss-session", "notice");
      assert.match(sent!.text, /stopped on an error/i);
      assert.match(sent!.text, /prompt-capture: no capture for this system prompt/);
      assert.match(sent!.text, /run-errored/, "names the run id so the parent can act on it");
      assert.match(sent!.text, /resume|retry/i, "says how to continue it");
      assert.ok(sent!.args.includes("--status"), "an error notice is a status, not a report: a later stop must record stopped");
    });
  } finally {
    await fx.restore();
  }
});

// The negative control: an interrupt is not a failure, and nothing about
// it should read as one.
test("an aborted turn sends no error notice", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-aborted", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-aborted" });
      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "aborted" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await new Promise((r) => setTimeout(r, 30));
      assert.equal(jsonLines(fx.logFile).length, 0, "an interrupt is not an error and sends nothing");
    });
  } finally {
    await fx.restore();
  }
});

test("a top-level session's errored turn sends no notice: it has nobody to tell", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx); // root session: no KIDO_AGENT_PARENT_SESSION
    await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "boom" }] });
    await s.emit("agent_settled", {}, { isIdle: () => true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(jsonLines(fx.logFile).length, 0);
  } finally {
    await fx.restore();
  }
});

// Once per error, not per retry: pi 0.87.1 can fire agent_end more than
// agent_end fires once per retry but agent_settled only once retries are
// exhausted, so a redundant settle must not repeat the notice, and a genuinely new failure must.
test("once per error: a redundant settle does not resend, and a later fresh failure does", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-retry", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-retry" });

      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "first failure" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await fx.waitForLog("boss-session", "notice");
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 1);

      await s.emit("agent_settled", {}, { isIdle: () => true });
      await new Promise((r) => setTimeout(r, 30));
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 1, "no duplicate for the same error");

      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "second failure" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await pollUntil(() => jsonLines(fx.logFile).filter((l) => l.kind === "notice").length >= 2, 2000, "a second notice");
      const notices = jsonLines(fx.logFile).filter((l) => l.kind === "notice");
      assert.equal(notices.length, 2, "a later, genuinely new failure notifies again");
      assert.match(notices[1].text, /second failure/);
    });
  } finally {
    await fx.restore();
  }
});

// A silent child's ending must carry the last turn's own error.
test("the ending outcome text carries the last turn's error when the child never reported", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-error-idle", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-error-idle" });
      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "prompt-capture: no capture" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await fx.waitForLog("boss-session", "notice");
      await s.emit("session_shutdown");
      const args = fx.lastRunOutcomeArgs();
      assert.deepEqual(args?.slice(0, 3), ["run-outcome", "--result", "completed"]);
      const i = args!.indexOf("--text");
      assert.ok(i >= 0, "the ending outcome carries a --text detail");
      assert.match(args![i + 1], /last turn failed/);
      assert.match(args![i + 1], /prompt-capture: no capture/);
    });
  } finally {
    await fx.restore();
  }
});

test("session_shutdown records this run's own outcome as completed when it ends idle, or failed otherwise", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-completed", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-completed" });
      await s.emit("session_shutdown");
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", "run-completed"]);
    });
  } finally {
    await fx.restore();
  }

  const fx2 = makeFixture();
  try {
    fx2.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-failed", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx2, { factory, sessionId: "run-failed" });
      await s.emit("agent_start");
      await s.emit("session_shutdown");
      assert.deepEqual(fx2.lastRunOutcomeArgs(), ["run-outcome", "--result", "failed", "--", "run-failed"]);
    });
  } finally {
    await fx2.restore();
  }
});

// A reload (reason "reload") carries the session straight on in the same
// process; recording an outcome there would report a live run as finished, and
// since RecordOutcome refuses to overwrite the real ending could never be recorded after.
test("a session_shutdown that is a reload or a session replacement records no outcome", async () => {
  for (const reason of ["reload", "new"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
      await asSubagent(`run-${reason}`, async () => {
        const factory = await freshExtensions();
        const s = await startSession(fx, { factory, sessionId: `run-${reason}` });
        await s.emit("session_shutdown", { type: "session_shutdown", reason });
        assert.equal(fx.lastRunOutcomeArgs(), undefined, `a "${reason}" shutdown does not end the run`);
      });
    } finally {
      await fx.restore();
    }
  }

  // Negative control: an explicit "quit" still records.
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-quit", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-quit" });
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", "run-quit"]);
    });
  } finally {
    await fx.restore();
  }
});

// A /reload delivers reason "reload" and keeps the same session id
// (measured against pi 0.85.1), while "new", "resume" and "fork" each hand back a
// different one in the same process - so those three must still remove the old
// record, or it is a live-pid file that nothing ever cleans up, claiming this pane alongside
// the fresh one under the new id.
test("session_shutdown removes the record for every reason except a reload", async () => {
  for (const reason of ["new", undefined]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
      const s = await startSession(fx, { sessionId: `sess-${reason}` });
      await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
      await s.emit("session_shutdown", reason === undefined ? undefined : { type: "session_shutdown", reason });
      await pollUntil(() => fx.statusReportsWithRemove().length >= 1, 2000, `a "${reason}" shutdown to report --remove`);
    } finally {
      await fx.restore();
    }
  }

  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, { sessionId: "sess-reload" });
    await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
    await s.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });
    // No event to wait on: the reload branch returns before ever calling send().
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(fx.statusReportsWithRemove().length, 0, "a reload must never report --remove");
  } finally {
    await fx.restore();
  }
});

test("session_shutdown never records an outcome for a root session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, { sessionId: "root-session" });
    await s.emit("session_shutdown");
    assert.equal(fx.lastRunOutcomeArgs(), undefined, "a root session has no run record to write into");
  } finally {
    await fx.restore();
  }
});
