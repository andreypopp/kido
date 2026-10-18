import { test } from "node:test";

import assert from "node:assert/strict";

import { copyFileSync, mkdtempSync, rmSync, statSync } from "node:fs";

import { join, dirname } from "node:path";

import { fileURLToPath, pathToFileURL } from "node:url";

import kidoPi from "./kido-pi.ts";

import { makeFixture, createFakePi, startSession, freshExtension, pollUntil, sendToInbox, envelope, customMessages, pendingState, settlesWithin } from "./kido-pi-fixture.ts";

// Negative control: the file that claimed the slot still registers everything
// when run again (what a /reload does) - a guard refusing every second factory
// call would pass the first half and leave a reloaded session with no tools.
test("a second copy of the extension at another path registers nothing, and a reload of the first still does", async () => {
  const first = createFakePi();
  kidoPi(first.pi as never);
  assert.ok(first.tools.size > 0 && first.handlers.size > 0, "the extension registered nothing at all");

  const here = dirname(fileURLToPath(import.meta.url));
  const dir = mkdtempSync(join(here, ".copy-"));
  try {
    copyFileSync(join(here, "kido-pi.ts"), join(dir, "kido-pi.ts"));
    const copy = await import(pathToFileURL(join(dir, "kido-pi.ts")).href);
    const registered = createFakePi();
    copy.default(registered.pi);
    assert.deepEqual([...registered.tools.keys()], [], "the copy registered tools");
    assert.deepEqual([...registered.handlers.keys()], [], "the copy registered handlers");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  const reloaded = createFakePi();
  kidoPi(reloaded.pi as never);
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

function noticesIn(s: Pick<ReturnType<typeof createFakePi>, "messages">, text: string) {
  return customMessages(s, "kido-notice").filter((m) => m.message.content.includes(text));
}

test("pi's clearQueue restores only editor text and preserves both custom queues in order", async () => {
  assert.equal(typeof globalThis.__kidoPiExtensionClearQueue, "function", "pi must expose clearQueue");
  const { Agent } = await import(import.meta.resolve("@earendil-works/pi-agent-core"));
  const agent = new Agent();
  const custom = ["kido-message", "kido-ask", "kido-notice", "kido-reply"].map((customType) => ({
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
