import { test } from "node:test";

import assert from "node:assert/strict";

import { appendFileSync, copyFileSync, existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";

import { join, dirname } from "node:path";

import { fileURLToPath, pathToFileURL } from "node:url";

import koPi from "./ko-pi.ts";

import { makeFixture, createFakePi, selfPane, startSession, freshExtension, withEnv, pollUntil, sendToInbox, envelope, customMessages, pendingState, settlesWithin } from "./ko-pi-fixture.ts";

// Negative control: the file that claimed the slot still registers everything
// when run again (what a /reload does) - a guard refusing every second factory
// call would pass the first half and leave a reloaded session with no tools.
test("a second copy of the extension at another path registers nothing, and a reload of the first still does", async () => {
  const first = createFakePi();
  koPi(first.pi as never);
  assert.ok(first.tools.size > 0 && first.handlers.size > 0, "the extension registered nothing at all");

  const here = dirname(fileURLToPath(import.meta.url));
  const dir = mkdtempSync(join(here, ".copy-"));
  try {
    copyFileSync(join(here, "ko-pi.ts"), join(dir, "ko-pi.ts"));
    const copy = await import(pathToFileURL(join(dir, "ko-pi.ts")).href);
    const registered = createFakePi();
    copy.default(registered.pi);
    assert.deepEqual([...registered.tools.keys()], [], "the copy registered tools");
    assert.deepEqual([...registered.handlers.keys()], [], "the copy registered handlers");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  const reloaded = createFakePi();
  koPi(reloaded.pi as never);
  assert.deepEqual([...reloaded.tools.keys()].sort(), [...first.tools.keys()].sort());
  assert.deepEqual([...reloaded.handlers.keys()].sort(), [...first.handlers.keys()].sort());
});

test("a /reload leaves exactly one listener, on the same socket", async () => {
  const fx = makeFixture();
  try {
    const s1 = await startSession(fx, { factory: await freshExtension() });
    const before = statSync(s1.inboxPath).ino;

    await s1.emit("session_shutdown", { reason: "reload" });
    const s2 = await startSession(fx, { factory: await freshExtension() });
    assert.equal(statSync(s2.inboxPath).ino, before, "the reload rebound the socket instead of keeping it");

    for (const text of ["after one", "after two"]) {
      assert.equal(await sendToInbox(s2.inboxPath, envelope("notice", text, { from: { session: "peer-a", name: "peer-a" } })), "ok");
      await pollUntil(() => noticesIn(s2, text).length === 1, 2000, `the notice ${JSON.stringify(text)} to arrive exactly once`);
    }
    assert.equal(noticesIn(s1, "after one").length + noticesIn(s1, "after two").length, 0, "a second listener still pointing at the old module");
  } finally {
    await fx.restore();
  }
});

test("an envelope that arrives in the /reload gap is held, then answered and delivered once", async () => {
  const fx = makeFixture();
  try {
    const s1 = await startSession(fx, { factory: await freshExtension() });
    await s1.emit("session_shutdown", { reason: "reload" });

    const sent = sendToInbox(s1.inboxPath, envelope("message", "in the gap", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(await pendingState(sent, 100), "pending", "the gap must hold the connection, not answer it");

    const s2 = await startSession(fx, { factory: await freshExtension() });
    assert.equal(await settlesWithin(sent, 2000), "ok");
    const inGap = (s: { delivered: Array<{ text: string }>; messages: Array<{ message: { content: unknown } }> }) =>
      s.delivered.filter((d) => d.text.includes("in the gap")).length +
      s.messages.filter((m) => String(m.message.content).includes("in the gap")).length;
    await pollUntil(() => inGap(s2) > 0, 2000, "the held message to reach the reloaded session");
    assert.equal(inGap(s2), 1, "the held message was delivered more than once");
    assert.equal(inGap(s1), 0, "the module that shut down must not deliver it too");
  } finally {
    await fx.restore();
  }
});

test("a session_shutdown that is not a reload still closes and unlinks the inbox", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx, { factory: await freshExtension() });
    assert.equal(await sendToInbox(s.inboxPath, envelope("message", "before", { from: { session: "peer-a", name: "peer-a" } })), "ok");

    await s.emit("session_shutdown", { reason: "quit" });
    assert.equal(statSync(join(fx.stateDir, "inbox")).isDirectory(), true, "the inbox directory is not the socket");
    await assert.rejects(
      () => sendToInbox(s.inboxPath, envelope("message", "after", { from: { session: "peer-a", name: "peer-a" } })),
      /ENOENT|ECONNREFUSED/,
    );
  } finally {
    await fx.restore();
  }
});

test("a /reload restores an outstanding run-wait, including a run that ended in the gap", async () => {
  const fx = makeFixture();
  try {
    const gate = join(fx.stateDir, "gate");
    fx.setPanes([selfPane()]);
    await withEnv({ KO_FAKE_RUN_WAIT_GATE: gate, KO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) }, async () => {
      const s1 = await startSession(fx, { factory: await freshExtension() });
      await s1.tools.get("async_bash").execute("c", { command: "make", name: "build" });
      await pollUntil(() => customMessages(s1, "ko-stream").length === 0 && fx.runWaitCalls().length === 1, 2000, "the first run-wait");
      await s1.emit("session_shutdown", { reason: "reload" });
      writeFileSync(gate, "");
      const s2 = await startSession(fx, { factory: await freshExtension() });
      await pollUntil(() => customMessages(s2, "ko-notice").some((m) => String(m.message.content).includes('async run "build" completed')), 2000, "the ending notice after the reload");
      assert.equal(fx.runWaitCalls().filter((call) => call.includes("fake-run-id")).length, 2, "the reload started a fresh run-wait for the same run");
    });
  } finally {
    await fx.restore();
  }
});

test("a /reload keeps this session's pane variables, and a real shutdown unsets them", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s1 = await startSession(fx, { factory: await freshExtension() });
    await s1.emit("session_shutdown", { reason: "reload" });
    const unsetSession = fx.optionWrites().filter((write) => write.key === "pi.session" && write.value === undefined);
    assert.deepEqual(unsetSession, [], "a reload must keep the options a child's report reads");

    const s2 = await startSession(fx, { factory: await freshExtension() });
    await s2.emit("session_shutdown", { reason: "quit" });
    const unsetAfterQuit = fx.optionWrites().filter((write) => write.key === "pi.session" && write.value === undefined);
    assert.equal(unsetAfterQuit.length, 1, "a real shutdown unsets the options");
  } finally {
    await fx.restore();
  }
});

const ownDelete = (call: { method: string; path: string }): boolean => call.method === "DELETE" && call.path === "/panes/pane_1/vars";

test("an uncaught exit unsets the variables in one delete that holds only while the pane still names this session", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await startSession(fx, { factory: await freshExtension() });
    const before = fx.apiCalls().length;
    process.emit("exit", 0);
    const first = fx.apiCalls().slice(before);
    assert.deepEqual(
      first.map((call) => [call.method, call.path, JSON.parse(call.body)]),
      [["DELETE", "/panes/pane_1/vars", { names: ["pi.session", "pi.name", "pi.inbox", "pi.activity"], if: { name: "pi.session", value: "self-session" } }]],
      "the four variables go in one request that names this session as the condition",
    );
    assert.deepEqual(fx.panes().map((row) => row.pi_session), [""], "the pane's own variables are gone");

    fx.setPanes([selfPane({ pi_session: "another-session", pi_name: "Newcomer" })]);
    const other = fx.apiCalls().length;
    process.emit("exit", 0);
    assert.equal(fx.apiCalls().slice(other).filter(ownDelete).length, 1, "the exit handler still asks");
    assert.deepEqual(
      fx.panes().map((row) => [row.pi_session, row.pi_name]),
      [["another-session", "Newcomer"]],
      "the server refused the delete, so the pane's new owner keeps its variables",
    );
  } finally {
    await fx.restore();
  }
});

test("a /reload keeps the exit handler until the next session replaces it, and a real shutdown removes it", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s1 = await startSession(fx, { factory: await freshExtension() });
    await s1.emit("session_shutdown", { reason: "reload" });
    const handlerRuns = (since: number): number => fx.apiCalls().slice(since).filter(ownDelete).length;
    const afterReload = fx.apiCalls().length;
    process.emit("exit", 0);
    assert.equal(handlerRuns(afterReload), 1, "a reload with no new session keeps a handler for the session that still owns the variables");

    const s2 = await startSession(fx, { factory: await freshExtension() });
    const afterStart = fx.apiCalls().length;
    process.emit("exit", 0);
    assert.equal(handlerRuns(afterStart), 1, "the new session replaced the old handler instead of stacking another");

    await s2.emit("session_shutdown", { reason: "quit" });
    const afterQuit = fx.apiCalls().length;
    process.emit("exit", 0);
    assert.equal(handlerRuns(afterQuit), 0, "a real shutdown removes the handler");
  } finally {
    await fx.restore();
  }
});

test("a reload detaches the old run-wait waiter, so only the restored watch reports", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const ready = join(fx.stateDir, "waiter-ready");
    const exitGate = join(fx.stateDir, "waiter-exit");
    await withEnv({ KO_FAKE_RUN_WAIT_READY: ready, KO_FAKE_RUN_WAIT_EXIT_GATE: exitGate, KO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) }, async () => {
      const s1 = await startSession(fx, { factory: await freshExtension() });
      await s1.tools.get("async_bash").execute("c", { command: "make", name: "build" });
      await pollUntil(() => existsSync(ready), 2000, "the waiter's stdout to arrive");
      await s1.emit("session_shutdown", { reason: "reload" });
      writeFileSync(exitGate, "");
      const s2 = await startSession(fx, { factory: await freshExtension() });
      await pollUntil(() => customMessages(s2, "ko-notice").some((m) => String(m.message.content).includes('async run "build" completed')), 2000, "the restored ending");
      await new Promise((resolve) => setTimeout(resolve, 100));
      assert.equal(customMessages(s1, "ko-notice").length, 0, "the old module sent no ending");
      assert.equal(customMessages(s2, "ko-notice").filter((m) => String(m.message.content).includes('async run "build"')).length, 1, "the restored watch sent exactly one notice");
    });
  } finally {
    await fx.restore();
  }
});

test("a reload keeps a spent stream budget, so it sends no new budget", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    const output = join(fx.stateDir, "runs", "fake-run-id", "output");
    await withEnv(
      { KO_FAKE_RUN_WAIT_GATE: gate, KO_STREAM_POLL_MS: "20", KO_STREAM_FLUSH_MS: "20", KO_STREAM_MAX_WAIT_MS: "40", KO_STREAM_BUDGET_BYTES: "1" },
      async () => {
        const s1 = await startSession(fx, { factory: await freshExtension() });
        await s1.tools.get("async_bash").execute("c", { command: "make", name: "build", stream: true });
        appendFileSync(output, "first\n");
        await pollUntil(async () => {
          await s1.emit("turn_end", { toolResults: [{}] });
          return customMessages(s1, "ko-stream").some((m) => String(m.message.content).includes("first"));
        }, 2000, "the first batch");
        appendFileSync(output, "spend\n");
        await pollUntil(async () => {
          await s1.emit("turn_end", { toolResults: [{}] });
          return customMessages(s1, "ko-stream").some((m) => String(m.message.content).includes("output budget spent"));
        }, 2000, "the budget line");
        await s1.emit("session_shutdown", { reason: "reload" });
        const parked = (globalThis as unknown as { __koPiExtensionWatches?: Array<{ budget: number; budgetTold: boolean }> }).__koPiExtensionWatches;
        assert.equal(parked?.length, 1, "the spent watch is parked");
        assert.equal(parked[0]!.budgetTold, true, "the budget line is remembered");
        assert.ok(parked[0]!.budget <= 0, "the spent budget is remembered");
        await startSession(fx, { factory: await freshExtension() });
      },
    );
  } finally {
    await fx.restore();
  }
});

function noticesIn(s: Pick<ReturnType<typeof createFakePi>, "messages">, text: string) {
  return customMessages(s, "ko-notice").filter((m) => m.message.content.includes(text));
}

test("pi's clearQueue restores only editor text and preserves both custom queues in order", async () => {
  assert.equal(typeof globalThis.__koPiExtensionClearQueue, "function", "pi must expose clearQueue");
  const { Agent } = await import(import.meta.resolve("@earendil-works/pi-agent-core"));
  const agent = new Agent();
  const custom = ["ko-message", "ko-notice", "ko-steer"].map((customType) => ({
    role: "custom", customType, content: customType, display: true, timestamp: 0,
  }));
  const user = { role: "user", content: "editor text", timestamp: 0 };
  for (const message of [custom[0], user, ...custom.slice(1)]) {
    agent.steer(message);
    agent.followUp(message);
  }
  const { AgentSession } = await import("@earendil-works/pi-coding-agent");
  const session = Object.assign(Object.create(AgentSession.prototype), {
    agent, _steeringMessages: ["steering text"], _followUpMessages: ["follow-up text"], _emitQueueUpdate() {},
  });
  await freshExtension();
  assert.deepEqual(session.clearQueue(), { steering: ["steering text"], followUp: ["follow-up text"] });
  assert.deepEqual(session.clearQueue(), { steering: [], followUp: [] });
  assert.deepEqual(agent.steeringQueue.messages, custom);
  assert.deepEqual(agent.followUpQueue.messages, custom);
  let cleared = false;
  Object.assign(session, {
    agent: { clearAllQueues() { cleared = true; } },
    _steeringMessages: ["steering text"], _followUpMessages: ["follow-up text"],
  });
  assert.deepEqual(session.clearQueue(), { steering: ["steering text"], followUp: ["follow-up text"] });
  assert.equal(cleared, true, "missing core queues must leave the original clearQueue intact");
});
