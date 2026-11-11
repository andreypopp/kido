import { test } from "node:test";

import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";

import { gatedCommand, makeFixture, agentPane, selfPane, startSession, entriesOf, asSubagent, withEnv, pollUntil, idleTurn, assistant, exited, notices, text, type Fixture, type Started } from "./ko-pi-fixture.ts";

const TASK = { text: "the work", from: { session: "boss-session", name: "boss", pane: "pane_2" } };
const NOTICES = "/panes/pane_2/messages";

function asChild(fx: Fixture, extra: Parameters<typeof selfPane>[0] = {}): void {
  fx.setPanes([selfPane({ parent: "pane_2", vars: { "ko-pi.task": TASK }, ...extra }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss" })]);
}

const child = (fn: (s: Started) => Promise<void>, fx: Fixture, name = "worker") => asSubagent("self-session", async () => fn(await startSession(fx, { name })));

test("a child reports its last message once the turn settles: an entry before the send, the same id on every send, a mark after the ack", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await child(async (s) => {
      await s.emit("agent_start");
      await s.emit("agent_end", {
        messages: [
          { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "looking" }, { type: "toolCall", name: "read" }] },
          { role: "assistant", stopReason: "stop", content: [{ type: "thinking", thinking: "hidden" }, { type: "text", text: "the merge is done" }, { type: "text", text: "; two conflicts" }] },
        ],
      });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      const [post] = fx.posts(NOTICES);
      assert.equal(fx.posts(NOTICES).length, 1);
      assert.deepEqual({ kind: post!.kind, text: post!.text, data: post!.data }, { kind: "notice", text: "the merge is done; two conflicts", data: { report: true } });
      assert.match(post!.id, /^[A-Za-z0-9_-]{22}$/);
      assert.deepEqual(entriesOf(s, "ko-pi.report").map((r) => [r.id, r.text]), [[post!.id, "the merge is done; two conflicts"]]);
      assert.deepEqual(entriesOf(s, "ko-pi.sent").map((r) => r.id), [post!.id], "the ack is a mark of its own, not a report");

      await idleTurn(s, "again with nothing new");
      assert.equal(fx.posts(NOTICES).length, 1, "a second turn on the same work reports nothing");
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true } } });
      await idleTurn(s, "second work done");
      assert.equal(fx.posts(NOTICES).length, 2, "new work owes a new report");
      assert.notEqual(fx.posts(NOTICES)[1]!.id, post!.id);
    }, fx);
  } finally {
    await fx.restore();
  }
});

test("an empty last message is still a report", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await child(async (s) => {
      await idleTurn(s);
      assert.equal(fx.posts(NOTICES)[0]!.text, 'subagent "worker" ended its turn with no message');
    }, fx);
  } finally {
    await fx.restore();
  }
});

test("a report whose ack is lost is sent again with its id, by the parent watch, until the parent acks it", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await withEnv({ KO_PARENT_POLL_MS: "20" }, () => child(async (s) => {
      fx.scriptSends([
        { status: 200, body: { state: "delivered", seq: 1 } },
        { status: 500, body: { kind: "io", message: "x" } },
        { status: 200, body: { state: "delivered", seq: 1 } },
        { status: 200, body: { state: "acked", seq: 1 } },
      ]);
      await idleTurn(s, "done");
      await pollUntil(() => entriesOf(s, "ko-pi.sent").length === 1, 2000, "the tick to resend until the ack");
      const posts = fx.posts(NOTICES);
      assert.ok(posts.length >= 4, `${posts.length} sends: three at the settle, then the tick`);
      assert.equal(new Set(posts.map((p) => p.id)).size, 1, "one id for the one report");
      const settled = fx.posts(NOTICES).length;
      const layouts = fx.apiCalls().filter((c) => c.path === "/layout").length;
      await pollUntil(() => fx.apiCalls().filter((c) => c.path === "/layout").length > layouts + 1, 500, "a completed tick");
      assert.equal(entriesOf(s, "ko-pi.sent").length, 1, "concurrent sends record the ack once");
      assert.equal(fx.posts(NOTICES).length, settled, "an acked report is not sent again");
    }, fx));
  } finally {
    await fx.restore();
  }
});

test("the parent watch skips a report while its settle send is active", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await withEnv({ KO_PARENT_POLL_MS: "20" }, () => child(async (s) => {
      fx.scriptSends([{ status: 200, body: { state: "acked", seq: 1 } }]);
      await withEnv({ KO_FAKE_SEND_GATE: `${fx.dir}/send-gate` }, async () => {
        const turn = idleTurn(s, "done");
        try {
          await pollUntil(() => fx.posts(NOTICES).length === 1, 2000, "the settle send to reach the gate");
          const layouts = fx.apiCalls().filter((c) => c.path === "/layout").length;
          await pollUntil(() => fx.posts(NOTICES).length > 1 || fx.apiCalls().filter((c) => c.path === "/layout").length > layouts + 2, 2000, "parent-watch ticks during the send");
          assert.equal(fx.posts(NOTICES).length, 1, "the active report is not sent again");
        } finally {
          writeFileSync(`${fx.dir}/send-gate`, "");
          await turn;
        }
        const layouts = fx.apiCalls().filter((c) => c.path === "/layout").length;
        await pollUntil(() => fx.apiCalls().filter((c) => c.path === "/layout").length > layouts + 1, 2000, "a completed tick");
        assert.equal(entriesOf(s, "ko-pi.sent").length, 1);
        assert.equal(fx.posts(NOTICES).length, 1, "the acked report is not sent again");
        assert.equal(new Set(fx.posts(NOTICES).map((post) => post.id)).size, 1);
      });
    }, fx));
  } finally {
    await fx.restore();
  }
});

test("the late ack of an old report does not count as a report of the new work", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane({ parent: "pane_2", vars: { "ko-pi.task": TASK } }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss", inbox: false })]);
    await withEnv({ KO_PARENT_POLL_MS: "20" }, () => child(async (s) => {
      await idleTurn(s, "work A done");
      assert.equal(entriesOf(s, "ko-pi.sent").length, 0, "the parent has not acked it: it only queued it");
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true } } });
      fx.scriptSends([{ status: 200, body: { state: "acked", seq: 1 } }]);
      await pollUntil(() => entriesOf(s, "ko-pi.sent").length === 1, 2000, "the late ack of report A");
      await idleTurn(s, "work B done");
      const texts = fx.posts(NOTICES).map((post) => post.text);
      assert.ok(texts.includes("work B done"), `report B was sent: ${texts.join("|")}`);
      assert.equal(entriesOf(s, "ko-pi.report").length, 2);
    }, fx));
  } finally {
    await fx.restore();
  }
});

test("a refused report ends the retries", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await withEnv({ KO_PARENT_POLL_MS: "20" }, () => child(async (s) => {
      fx.scriptSends([{ status: 409, body: { kind: "refused", message: "no" } }]);
      await idleTurn(s, "done");
      assert.deepEqual(entriesOf(s, "ko-pi.sent").map((r) => r.refused), [true]);
      await pollUntil(() => fx.apiCalls().filter((c) => c.path === "/layout").length > 2, 1000, "ticks");
      assert.equal(fx.posts(NOTICES).length, 1);
    }, fx));
  } finally {
    await fx.restore();
  }
});

test("a child reports with a live service, lists it, and receives its ending notice", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await child(async (s) => {
      const gate = `${fx.dir}/service-gate`;
      const job = await s.tools.get("async_bash").execute("c", { command: gatedCommand(gate), name: "server", service: true });
      const rows = JSON.parse(text(await s.tools.get("list_async_bash").execute("l", {})));
      assert.equal(rows[0].service, true);
      await idleTurn(s, "server ready");
      assert.equal(fx.posts(NOTICES)[0]?.text, "server ready");
      assert.deepEqual(notices(s), []);
      writeFileSync(gate, "");
      await pollUntil(() => notices(s).length === 1);
      assert.ok(notices(s)[0]!.includes(job.details.job.id));
      assert.match(notices(s)[0]!, /exit 0/);
      await idleTurn(s, "service ended");
      assert.equal(fx.posts(NOTICES).length, 1);
    }, fx);
  } finally { await fx.restore(); }
});

test("a child reports nothing while a bash run of its own lives or a subagent of its own owes a report", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await child(async (s) => {
      const job = await s.tools.get("async_bash").execute("c", { command: gatedCommand(`${fx.dir}/gate`), name: "build" });
      await idleTurn(s, "waiting");
      assert.deepEqual(fx.posts(NOTICES), [], "a live run");
      await s.tools.get("stop_async_bash").execute("c", { job: job.details.job.id });
      await pollUntil(async () => !JSON.parse(text(await s.tools.get("list_async_bash").execute("l", {}))).some((row: { job: string; state: string }) => row.job === job.details.job.id && row.state !== "ended"));
      s.entries.push({ type: "custom", customType: "ko-pi.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "m", fork: false, cwd: "/tmp", pane: { instance: "a".repeat(32), pane: "pane_5" } } });
      s.entries.push({ type: "custom", customType: "ko-pi.work", data: { owner: "self-session", child: "kid-session", at: 1 } });
      fx.setPanes([...fx.panes(), agentPane({ pane: "pane_5", session: "kid-session", name: "kid", parent: "pane_1" })]);
      await idleTurn(s, "waiting");
      assert.deepEqual(fx.posts(NOTICES), [], "a child that owes its report");
      s.entries.push({ type: "custom", customType: "ko-pi.report", data: { owner: "self-session", child: "kid-session", text: "ok", at: 2, id: "k" } });
      await idleTurn(s, "all done");
      assert.equal(fx.posts(NOTICES).length, 1);
      assert.equal(fx.posts(NOTICES)[0]!.text, "all done");
    }, fx);
  } finally {
    await fx.restore();
  }
});

test("a turn that ends on an error is told once to the parent as a status notice, and an abort says nothing", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await child(async (s) => {
      await s.emit("agent_start");
      await s.emit("agent_end", { messages: [assistant("error", undefined, "provider down")] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      const posts = fx.posts(NOTICES);
      assert.equal(posts.length, 1);
      assert.deepEqual({ kind: posts[0]!.kind, text: posts[0]!.text, data: posts[0]!.data }, { kind: "notice", text: "subagent stopped on an error: provider down\nmessage it to retry, or stop_agent to end it", data: undefined });
      await s.emit("agent_start");
      await s.emit("agent_end", { messages: [assistant("aborted")] });
      await s.emit("agent_settled", { aborted: true }, { isIdle: () => true });
      assert.equal(fx.posts(NOTICES).length, 1);
      assert.deepEqual(entriesOf(s, "ko-pi.report"), []);
    }, fx);
  } finally {
    await fx.restore();
  }
});

test("quitting owes the parent an exit notice only without a report and without a stop from outside", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await child(async (s) => {
      await s.emit("session_shutdown", { reason: "quit" });
      assert.deepEqual(fx.posts(NOTICES).map((p) => p.text), ['subagent "worker" is exiting before its first turn ran']);
    }, fx);

    asChild(fx);
    await child(async (s) => {
      await s.emit("agent_start");
      await s.emit("agent_end", { messages: [assistant("error", undefined, "boom")] });
      await s.emit("session_shutdown", { reason: "quit" });
      assert.equal(fx.posts(NOTICES).at(-1)!.text, 'subagent "worker" is exiting without a report on its last work: its last turn failed: boom');
    }, fx);

    const before = fx.posts(NOTICES).length;
    asChild(fx);
    await child(async (s) => {
      await s.emit("session_shutdown", { reason: "reload" });
    }, fx);
    asChild(fx);
    await child(async (s) => {
      await idleTurn(s, "done");
      await s.emit("session_shutdown", { reason: "quit" });
    }, fx);
    asChild(fx);
    await child(async (s) => {
      fx.feed({ id: "stop-from-boss", kind: "stop" });
      await pollUntil(() => s.shutdowns() === 1, 2000, "the stop");
      await s.emit("session_shutdown", { reason: "quit" });
    }, fx);
    assert.equal(fx.posts(NOTICES).length, before + 1, "only the report of the one that reported");
  } finally {
    await fx.restore();
  }
});

test("a child ends itself when its parent pane is gone, dead or held by another session; an unreadable layout is no evidence", async () => {
  const fx = makeFixture();
  try {
    asChild(fx);
    await withEnv({ KO_PARENT_POLL_MS: "10" }, () => child(async (s) => {
      const layouts = () => fx.apiCalls().filter((call) => call.path === "/layout").length;
      await withEnv({ KO_FAKE_LAYOUT_FAIL: "1" }, async () => {
        const before = layouts();
        await pollUntil(() => layouts() >= before + 3, 1000, "failing ticks");
      });
      assert.equal(s.shutdowns(), 0);
      fx.setPanes([selfPane({ parent: "pane_2" }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss" })]);
      const live = layouts();
      await pollUntil(() => layouts() >= live + 3, 1000, "ticks with a living parent");
      assert.equal(s.shutdowns(), 0, "a living parent keeps the child");
      fx.setPanes([selfPane({ parent: "pane_2" }), agentPane({ pane: "pane_2", session: "boss-session", name: "boss", dead: exited(0) })]);
      await pollUntil(() => s.shutdowns() === 1, 2000, "a dead parent");
      await new Promise((resolve) => setTimeout(resolve, 60));
      assert.equal(s.shutdowns(), 1, "once");
    }, fx));

    fx.setPanes([selfPane({ parent: "pane_2" }), agentPane({ pane: "pane_2", session: "someone-else", name: "boss" })]);
    await withEnv({ KO_PARENT_POLL_MS: "10" }, () => child(async (s) => {
      await pollUntil(() => s.shutdowns() === 1, 2000, "a parent pane that another session holds");
    }, fx));
  } finally {
    await fx.restore();
  }
});
