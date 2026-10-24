import { test } from "node:test";

import assert from "node:assert/strict";

import kidoPi from "./kido-pi.ts";

import { makeFixture, agentPane, asSubagent, startWithSpies, fakeCtx, startSessionCore, sendToInbox, envelope, customMessages, pendingState, pollUntil } from "./kido-pi-fixture.ts";

function tree(fx: ReturnType<typeof makeFixture>): void {
  fx.writeAgent("root", "mid", { session: "mid" });
  fx.writeAgent("root", "peer", { session: "peer" });
  fx.writeAgent("other", "stranger", { session: "stranger" });
  fx.setPanes([
    agentPane({ pane: "%1", session: "mid", name: "mid" }),
    agentPane({ pane: "%2", session: "root", name: "root" }),
    agentPane({ pane: "%3", session: "peer", name: "peer" }),
    agentPane({ pane: "%4", session: "stranger", name: "stranger" }),
  ]);
}

test("an interrupt envelope from an ancestor aborts, and a stop envelope shuts down, each exactly once", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    await asSubagent(fx, "mid", async () => {
      const s = await startWithSpies(fx, kidoPi, "mid");
      const from = { session: "root", name: "root", pane: "%2" };
      assert.equal(await sendToInbox(s.inboxPath, envelope("interrupt-and-steer", "new work", { from })), "ok");
      assert.equal(s.aborts(), 1);
      assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from })), "ok");
      assert.equal(s.shutdowns(), 1);
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});

test("interrupt and stop are refused, with neither abort nor shutdown, for a peer or an unknown sender", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    await asSubagent(fx, "mid", async () => {
      const s = await startWithSpies(fx, kidoPi, "mid");
      for (const from of [{ session: "peer", name: "peer", pane: "%3" }, { session: "stranger", name: "stranger", pane: "%4" }, { session: "nobody" }]) {
        assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from })), "refused");
        assert.equal(await sendToInbox(s.inboxPath, envelope("interrupt-and-steer", "new work", { from })), "refused");
      }
      assert.equal(s.aborts(), 0);
      assert.equal(s.shutdowns(), 0);
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});

test("a control is accepted from an ancestor at any depth, and refused from a descendant or a self-edge", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    fx.writeAgent("mid", "leaf", { session: "leaf" });
    await asSubagent(fx, "leaf", async () => {
      const s = await startWithSpies(fx, kidoPi, "leaf");
      assert.equal(await sendToInbox(s.inboxPath, envelope("interrupt-and-steer", "new work", { from: { session: "root", name: "root" } })), "ok", "a grandparent may interrupt");
      assert.equal(s.aborts(), 1);
      assert.equal(await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "leaf" } })), "refused", "a self-edge is no ancestor");
    }, { parent: "mid", name: "leaf" });
    await asSubagent(fx, "mid", async () => {
      const s = await startWithSpies(fx, kidoPi, "mid");
      assert.equal(await sendToInbox(s.inboxPath, envelope("interrupt-and-steer", "new work", { from: { session: "leaf", name: "leaf" } })), "refused", "a child may not interrupt its parent");
      assert.equal(s.aborts(), 0);
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});

test("an interrupt does not answer until ctx.abort() settles, so a message sent right after is not orphaned", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    await asSubagent(fx, "mid", async () => {
      let release = (): void => {};
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      let aborts = 0;
      const s = await startSessionCore(fx, kidoPi, (c) => ({
        ...fakeCtx("mid", c.ui),
        abort: () => {
          aborts++;
          return gate;
        },
      }));
      const from = { session: "root", name: "root", pane: "%2" };
      const sent = sendToInbox(fx.inboxPath("mid"), envelope("interrupt-and-steer", "new work", { from }));
      await pollUntil(() => aborts === 1, 2000, "the abort to start");
      try {
        assert.equal(await pendingState(sent, 50), "pending", "the answer waits for the abort");
        assert.equal(customMessages(s, "kido-message").length, 0, "new work cannot start during the abort");
      } finally {
        release();
      }
      assert.equal(await sent, "ok");
      const message = customMessages(s, "kido-message")[0]!;
      assert.ok(message.message.content.endsWith("new work"), "the new turn starts with the supplied text");
      assert.deepEqual(message.opts, { deliverAs: "followUp", triggerTurn: true });
      assert.equal(message.message.details.work, true, "new parent work retains its marker");
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});

// Asserts the mode, not merely that something arrived: a steer delivered as
// followUp would wait for the agent to decide to stop, exactly what steering
// exists to skip. A message must stay followUp.
test("an inbound steer is delivered as steer; a message stays followUp", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    await asSubagent(fx, "mid", async () => {
      const s = await startWithSpies(fx, kidoPi, "mid");
      const from = { session: "root", name: "root", pane: "%2" };

      assert.equal(await sendToInbox(s.inboxPath, envelope("steer", "drop that, do X", { from })), "ok");
      const steered = customMessages(s, "kido-steer")[0];
      assert.ok(steered, "the steer reached the model");
      assert.equal((steered!.opts as { deliverAs?: string }).deliverAs, "steer", "a steer joins the running turn rather than queueing behind it");
      assert.equal((steered!.opts as { triggerTurn?: boolean }).triggerTurn, true, "and triggers a turn when idle");
      assert.match(steered!.message.content, /root/, "and says who is redirecting the work");

      assert.equal(await sendToInbox(s.inboxPath, envelope("message", "when you get a moment", { from })), "ok");
      const queued = customMessages(s, "kido-message")[0];
      assert.ok(queued, "the message reached the model");
      assert.equal((queued!.opts as { deliverAs?: string }).deliverAs, "followUp");

      assert.match(queued!.message.content, /^message from @root \(your parent, who spawned you\):/);
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});

test("an inbound steer from a non-ancestor is refused and delivers nothing", async () => {
  const fx = makeFixture();
  try {
    tree(fx);
    await asSubagent(fx, "mid", async () => {
      const s = await startWithSpies(fx, kidoPi, "mid");
      const resp = await sendToInbox(s.inboxPath, envelope("steer", "do my bidding", { from: { session: "peer", name: "peer", pane: "%3" } }));
      assert.equal(resp, "refused");
      assert.equal(customMessages(s, "kido-steer").length, 0, "and nothing reached the model");
    }, { parent: "root", name: "mid" });
  } finally {
    await fx.restore();
  }
});
