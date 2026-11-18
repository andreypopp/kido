import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { gatedCommand, makeFixture, selfPane, startSession, entriesOf, createChannel, stubAgent, pollUntil, idleTurn, assistant, notices, type Fixture, type Started, at, jobId, jsonRows } from "./koa-agent-fixture.ts";

// The parent's branch as the host reads it: a mark for the last work and one for the last report.
function parentLedger() {
  let counter = 0, work = -1, report = -1, text: string | undefined;
  const reports: string[] = [];
  const notes: string[] = [];
  const extension = {
    markWork: () => { work = ++counter; },
    receiveReport: (_child: unknown, body: string) => { report = ++counter; text = body; reports.push(body); },
    childState: () => {
      const reported = work === -1 || report > work;
      return { reported, ...(work !== -1 && reported && text !== undefined ? { text } : {}) };
    },
    receive: async (message: { text: string }) => { notes.push(message.text); },
  };
  return { extension, reports, notes, agent: stubAgent({ id: "boss-session", children: [], extension }) };
}

async function child(fx: Fixture, run: (s: Started, ledger: ReturnType<typeof parentLedger>, channel: ReturnType<typeof createChannel>) => Promise<void>) {
  fx.setPanes([selfPane()]);
  const ledger = parentLedger();
  const channel = createChannel();
  Object.assign(channel.host.self, { parent: ledger.agent, name: "worker" });
  const s = await startSession(fx, { channel, name: "worker" });
  await s.emit("message_start", { message: { role: "user", content: "the task" } });
  await run(s, ledger, channel);
}

test("a child reports its last message to its parent once the turn settles, and new work owes a new report", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger) => {
      await s.emit("agent_start");
      await s.emit("agent_end", {
        messages: [
          { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "looking" }, { type: "toolCall", name: "read" }] },
          { role: "assistant", stopReason: "stop", content: [{ type: "thinking", thinking: "hidden" }, { type: "text", text: "the merge is done" }, { type: "text", text: "; two conflicts" }] },
        ],
      });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      assert.deepEqual(ledger.reports, ["the merge is done; two conflicts"]);
      assert.deepEqual(entriesOf(s, "koa.report"), [], "the child keeps no report entry: the parent's branch holds it");
      await idleTurn(s, "the merge is done; two conflicts");
      assert.equal(ledger.reports.length, 1, "a second turn on the same work with the same text reports nothing");
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true } } });
      await idleTurn(s, "the merge is done; two conflicts");
      assert.equal(ledger.reports.length, 2, "new work makes identical text a new report");
    });
  } finally { await fx.restore(); }
});

test("an empty last message is still a report", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger) => {
      await idleTurn(s);
      assert.deepEqual(ledger.reports, ['subagent "worker" ended its turn with no message']);
    });
  } finally { await fx.restore(); }
});

test("a service does not hold the report; a non-service job does until it ends", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger) => {
      const gate = `${fx.dir}/service-gate`;
      const job = await s.tool("async_bash").execute("c", { command: gatedCommand(gate), name: "server", service: true });
      assert.equal(jsonRows(await s.tool("list_async_bash").execute("l", {}))[0]?.service, true);
      await idleTurn(s, "server ready");
      assert.deepEqual(ledger.reports, ["server ready"]);
      assert.deepEqual(notices(s), []);
      writeFileSync(gate, "");
      await pollUntil(() => notices(s).length === 1);
      assert.ok(at(notices(s), 0).includes(jobId(job)));
      await s.emit("message_start", { message: { role: "user", content: "more" } });
      const build = await s.tool("async_bash").execute("c", { command: gatedCommand(`${fx.dir}/build-gate`), name: "build" });
      await idleTurn(s, "Building.");
      assert.deepEqual(ledger.reports, ["server ready"], "a live run holds the report");
      await s.tool("stop_async_bash").execute("c", { job: jobId(build) });
      await pollUntil(async () => !jsonRows(await s.tool("list_async_bash").execute("l", {})).some((row) => row.job === jobId(build) && row.state !== "ended"));
      await idleTurn(s, "The real result.");
      assert.deepEqual(ledger.reports, ["server ready", "The real result."]);
    });
  } finally { await fx.restore(); }
});

test("a child that owes its own parent a report holds the report until it has reported", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger, channel) => {
      s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "m", fork: false, cwd: "/tmp" } });
      s.entries.push({ type: "custom", customType: "koa.work", data: { owner: "self-session", child: "kid-session", at: 1 } });
      Object.assign(channel.host, { find: (id: string) => id === "kid-session" ? stubAgent({ id }) : undefined });
      await idleTurn(s, "waiting");
      assert.deepEqual(ledger.reports, []);
      s.entries.push({ type: "custom", customType: "koa.report", data: { owner: "self-session", child: "kid-session", text: "ok", at: 2 } });
      await idleTurn(s, "all done");
      assert.deepEqual(ledger.reports, ["all done"]);
    });
  } finally { await fx.restore(); }
});

test("an error is told once to the parent as a notice; an abort, a control turn and a stop say nothing", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger, channel) => {
      await s.emit("agent_start");
      await s.emit("agent_end", { messages: [assistant("error", undefined, "provider down")] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      assert.deepEqual(ledger.notes, ["subagent stopped on an error: provider down\nmessage it to retry, or stop_agent to end it"]);
      await s.emit("agent_start");
      await s.emit("agent_end", { messages: [assistant("aborted")] });
      await s.emit("agent_settled", { aborted: true }, { isIdle: () => true });
      assert.equal(ledger.notes.length, 1);
      Object.assign(channel.host.self, { stopping: true });
      await idleTurn(s, "late words");
      assert.deepEqual(ledger.reports, []);
    });
  } finally { await fx.restore(); }
});
