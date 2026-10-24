import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, mkdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import { makeFixture, selfPane, agentPane, startNamedSession, asSubagent, withEnv, pollUntil, parentSetup, idleTurn, assertReport } from "./kido-pi-fixture.ts";

import { PARENT_GUIDANCE } from "./kido-pi.ts";

const SELF = "self-session";

type Envelope = { kind: string; text: string; from: { session: string; name?: string; pane?: string } };

test("a child's last assistant message is its report: its text blocks, without thinking or tool calls", async () => {
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
        await s.emit("agent_end", {
          messages: [
            { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "looking into it" }, { type: "toolCall", name: "read" }] },
            { role: "assistant", stopReason: "stop", content: [{ type: "thinking", thinking: "hidden" }, { type: "text", text: "the merge is done" }, { type: "text", text: "; two conflicts" }] },
          ],
        });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => inbox.received().length === 1, 2000, "the report");
        assertReport(inbox, 0, "the merge is done; two conflicts");
        const notice = JSON.parse(inbox.received()[0]!) as Envelope;
        assert.deepEqual(notice.from, { session: SELF, name: "worker", pane: "%1" });
        const report = join(fx.agentDir("boss-session", "worker"), "report");
        assert.equal(readFileSync(report, "utf8"), "the merge is done; two conflicts", "the report file holds the text alone");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("an empty last message is still the report: the notice says so, the file is empty, and stop_run records completed", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    const workerInbox = await fx.startInbox();
    parentSetup(fx, inbox.path, workerInbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await idleTurn(s);
        await pollUntil(() => inbox.received().length === 1, 2000, "the empty report");
        assertReport(inbox, 0, 'subagent "worker" ended its turn with no message');
        const report = join(fx.agentDir("boss-session", "worker"), "report");
        assert.equal(readFileSync(report, "utf8"), "", "an empty report file is still a report");
      },
      { parent: "boss-session", name: "worker" },
    );

    fx.setRuns([{ id: SELF, name: "worker", parent: "boss-session", pane: "%1", session: SELF, startedAt: "" }]);
    const boss = await startNamedSession(fx, "boss", "boss-session");
    const stopped = await boss.tools.get("stop_run").execute("c", { to: "worker" });
    assert.match(stopped.content[0].text, /^stopped worker/);
    assert.deepEqual(fx.runOutcomeCalls()[0], ["run-outcome", SELF, "--result", "completed"]);
  } finally {
    await fx.restore();
  }
});

test("a report over the cap is kept whole, and the notice names the file within 4000 bytes", async () => {
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
        const report = join(dir, "report");
        const long = "findings and more findings. ".repeat(200) + "CONCLUSION: ship it";
        await s.emit("agent_start");
        await idleTurn(s, long);
        await pollUntil(() => inbox.received().length === 1, 2000, "the long report");
        assert.equal(readFileSync(report, "utf8"), long, "the whole report is kept aside");

        const notice = (JSON.parse(inbox.received()[0]!) as Envelope).text;
        assert.ok(Buffer.byteLength(notice, "utf8") <= 4000, `the notice is ${Buffer.byteLength(notice, "utf8")} bytes`);
        assert.ok(notice.startsWith(long.slice(0, 100)), "it opens with the report");
        assert.ok(notice.includes(`\n\nfull report: ${report}`), "it names the file");
        assert.ok(notice.endsWith(PARENT_GUIDANCE), "and still says how to act on it");

        writeFileSync(join(dir, "work"), "");
        const future = new Date(Date.now() + 2000);
        utimesSync(join(dir, "work"), future, future);
        await idleTurn(s, "日".repeat(3000));
        await pollUntil(() => inbox.received().length === 2, 2000, "the multi-byte report");
        const multibyte = (JSON.parse(inbox.received()[1]!) as Envelope).text;
        assert.ok(multibyte.isWellFormed(), "the head of a multi-byte report is cut on a rune boundary");
        assert.ok(!multibyte.includes("\uFFFD"));
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("the report reaches a parent whose pi root is cleared but whose session option remains", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([
      agentPane({ pane: "%1", session: SELF, name: "worker" }),
      { ...agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path }), pane_program_status: "" },
    ]);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        await s.emit("agent_start");
        await idleTurn(s, "the merge is done");
        await pollUntil(() => inbox.received().length === 1, 2000, "the report");
        assertReport(inbox, 0, "the merge is done");
        assert.equal(inbox.received().length, 1, "the parent in its editor is still the parent");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a gone parent still gets the report file; nothing is sent, and the next settle sends nothing either", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    await asSubagent(
      fx,
      SELF,
      async () => {
        fx.setPanes([selfPane()]);
        const s = await startNamedSession(fx, "worker", SELF);
        await s.emit("agent_start");
        await idleTurn(s, "anybody there?");
        const report = join(fx.agentDir("boss-session", "worker"), "report");
        assert.equal(readFileSync(report, "utf8"), "anybody there?", "the report is written before the parent is looked up");
        assert.equal(inbox.received().length, 0, "there is nobody to send to");
        await s.emit("agent_settled", {}, { isIdle: () => true });
        assert.equal(inbox.received().length, 0, "the file says the work was reported");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a report that cannot be written sends nothing, and the next settle tries again", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        const report = join(fx.agentDir("boss-session", "worker"), "report");
        mkdirSync(report);
        await idleTurn(s, "the merge is done");
        assert.equal(inbox.received().length, 0, "a report that was not kept is not sent");

        rmSync(report, { recursive: true });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => inbox.received().length === 1, 2000, "the retried report");
        assertReport(inbox, 0, "the merge is done");
        assert.equal(readFileSync(report, "utf8"), "the merge is done");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});

test("a tmux read failure at settlement writes and sends nothing; a later settle sends the report", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    parentSetup(fx, inbox.path);
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "worker", SELF);
        const report = join(fx.agentDir("boss-session", "worker"), "report");
        await withEnv({ KIDO_FAKE_TMUX_FAIL: "1" }, async () => {
          await idleTurn(s, "the merge is done");
          assert.equal(existsSync(report), false, "a failed read says nothing about the parent, so it writes nothing");
          assert.equal(inbox.received().length, 0);
        });
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => inbox.received().length === 1, 2000, "the report once tmux is readable");
        assertReport(inbox, 0, "the merge is done");
        assert.equal(readFileSync(report, "utf8"), "the merge is done");
      },
      { parent: "boss-session", name: "worker" },
    );
  } finally {
    await fx.restore();
  }
});
