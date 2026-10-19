import { test } from "node:test";

import assert from "node:assert/strict";

import { readFileSync } from "node:fs";

import { join } from "node:path";

import { makeFixture, selfPane, agentPane, startNamedSession, startSession, asSubagent } from "./kido-pi-fixture.ts";

const SELF = "self-session";

const GUIDANCE = "\n\nThe child stays alive after it reports. End it with stop_run when you need nothing more from it. To continue it, use message_agent.";

type Envelope = { kind: string; text: string; from: { session: string; name?: string; pane?: string } };

test("notify_parent keeps the report, sends the notice to the parent's inbox, and says how to act on it", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([agentPane({ pane: "%1", session: "child-session", name: "worker", inbox: fx.inboxPath("child-session") }), agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path })]);
    await asSubagent(fx, "child-session", async () => {
      const s = await startNamedSession(fx, "worker", "child-session");
      const result = await s.tools.get("notify_parent").execute("c1", { summary: "the merge is done; two conflicts, both in README.md" });
      assert.equal(result.content[0].text, "delivered to boss by inbox");

      const notices = inbox.received().map((payload) => JSON.parse(payload) as Envelope);
      assert.equal(notices.length, 1, "one notice reaches the parent");
      assert.equal(notices[0].kind, "notice");
      assert.equal(notices[0].text, "the merge is done; two conflicts, both in README.md" + GUIDANCE);
      assert.deepEqual(notices[0].from, { session: "child-session", name: "worker", pane: "%1" });

      const report = join(fx.agentDir("boss-session", "worker"), "report");
      assert.equal(readFileSync(report, "utf8"), "the merge is done; two conflicts, both in README.md", "the report file keeps the summary byte for byte");
    }, { parent: "boss-session", name: "worker" });
  } finally {
    await fx.restore();
  }
});

test("notify_parent refuses a session with no parent, and one whose parent is gone", async () => {
  const fx = makeFixture();
  try {
    const plain = await startSession(fx);
    assert.match((await plain.tools.get("notify_parent").execute("c1", { summary: "nobody to tell" })).content[0].text, /no parent/);

    await asSubagent(fx, SELF, async () => {
      fx.setPanes([selfPane()]);
      const s = await startNamedSession(fx, "worker", SELF);
      assert.equal(
        (await s.tools.get("notify_parent").execute("c1", { summary: "anybody there?" })).content[0].text,
        'could not notify parent: no live process holds session "boss-session"; the parent is gone, nothing sent',
      );
      const inbox = await fx.startInbox();
      fx.setPanes([selfPane(), { ...agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path }), pane_dead: "1" }]);
      assert.equal(
        (await s.tools.get("notify_parent").execute("c2", { summary: "anybody there?" })).content[0].text,
        'could not notify parent: no live process holds session "boss-session"; the parent is gone, nothing sent',
        "a dead pane with stale options is a gone parent",
      );
    });
  } finally {
    await fx.restore();
  }
});

test("notify_parent reaches a parent whose pi root is cleared but whose session option remains", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([
      agentPane({ pane: "%1", session: "child-session", name: "worker", inbox: fx.inboxPath("child-session") }),
      { ...agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path }), pane_program_status: "" },
    ]);
    await asSubagent(fx, "child-session", async () => {
      const s = await startNamedSession(fx, "worker", "child-session");
      const result = await s.tools.get("notify_parent").execute("c1", { summary: "the merge is done" });
      assert.equal(result.content[0].text, "delivered to boss by inbox", "the parent in its editor is still the parent");
      assert.equal(inbox.received().length, 1);
    }, { parent: "boss-session", name: "worker" });
  } finally {
    await fx.restore();
  }
});

test("a report over the cap is kept whole, and the notice names the file within 4000 bytes", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([agentPane({ pane: "%1", session: SELF, name: "worker" }), agentPane({ pane: "%2", session: "boss-session", name: "boss", inbox: inbox.path })]);
    await asSubagent(fx, SELF, async () => {
      const s = await startNamedSession(fx, "worker", SELF);
      const long = "findings and more findings. ".repeat(200) + "CONCLUSION: ship it";
      await s.tools.get("notify_parent").execute("c1", { summary: long });
      const report = join(fx.agentDir("boss-session", "worker"), "report");
      assert.equal(readFileSync(report, "utf8"), long, "the whole report is kept aside");

      const notice = (JSON.parse(inbox.received()[0]) as Envelope).text;
      assert.ok(Buffer.byteLength(notice, "utf8") <= 4000, `the notice is ${Buffer.byteLength(notice, "utf8")} bytes`);
      assert.ok(notice.startsWith(long.slice(0, 100)), "it opens with the report");
      assert.ok(notice.includes(`\n\nfull report: ${report}`), "it names the file");
      assert.ok(notice.endsWith(GUIDANCE), "and still says how to act on it");

      await s.tools.get("notify_parent").execute("c2", { summary: "日".repeat(3000) });
      const multibyte = (JSON.parse(inbox.received()[1]) as Envelope).text;
      assert.ok(multibyte.isWellFormed(), "the head of a multi-byte report is cut on a rune boundary");
      assert.ok(!multibyte.includes("\uFFFD"));
    });
  } finally {
    await fx.restore();
  }
});
