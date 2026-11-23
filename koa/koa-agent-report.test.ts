import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { gatedCommand, makeFixture, selfPane, startSession, entriesOf, createChannel, stubAgent, pollUntil, idleTurn, assistant, notices, type Fixture, type Started, jobId } from "./koa-agent-fixture.ts";

// The parent's branch as the host reads it: a mark for the last work and one for the last report.
function parentLedger() {
  let counter = 0, work = -1, report = -1, text: string | undefined;
  const reports: string[] = [];
  const notes: string[] = [];
  const extension = {
    markWork: () => { work = ++counter; },
    receiveReport: (_child: unknown, body: string, interim: boolean) => { report = interim ? -1 : ++counter; text = body; reports.push(body); },
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

test("a child reports completed work only before queued parent input or after settle", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger, channel) => {
      const extension = channel.host.extension;
      assert.ok(extension);
      const service = await s.tool("async_bash").execute("c", { command: gatedCommand(`${fx.dir}/service`), name: "service", service: true });
      const own = await s.tool("async_bash").execute("c", { command: gatedCommand(`${fx.dir}/own`), name: "own" });
      await s.emit("agent_start");
      writeFileSync(`${fx.dir}/own`, "");
      await pollUntil(() => notices(s).some(text => text.includes(jobId(own))));
      await s.emit("turn_end", { message: assistant("stop", "first result"), toolResults: [] });
      assert.deepEqual(ledger.reports, [], "own queued job notice must not release the report");
      await s.emit("agent_end", { messages: [assistant("stop", "first result")] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      assert.deepEqual(ledger.reports, ["first result"], "a service does not hold the report");
      assert.deepEqual(entriesOf(s, "koa.report"), []);

      await s.emit("message_start", { message: { role: "user", content: "next task" } });
      await s.emit("agent_start");
      await extension.receive({ kind: "message", agent: { name: "boss", session: "boss-session" }, relation: "parent", text: "follow up" });
      await s.emit("turn_end", { message: assistant("stop", "second result"), toolResults: [] });
      assert.deepEqual(ledger.reports, ["first result", "second result"]);
      await s.emit("turn_start");
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true, body: "follow up" } } });
      await s.emit("turn_end", { message: assistant("stop", "follow-up result"), toolResults: [] });
      assert.deepEqual(ledger.reports, ["first result", "second result"]);
      await s.emit("agent_end", { messages: [assistant("stop", "follow-up result")] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      assert.deepEqual(ledger.reports, ["first result", "second result", "follow-up result"]);
      await idleTurn(s, "follow-up result");
      assert.equal(ledger.reports.length, 3);

      await s.emit("message_start", { message: { role: "user", content: "build" } });
      const build = await s.tool("async_bash").execute("c", { command: gatedCommand(`${fx.dir}/build`), name: "build" });
      const job = channel.host.jobs.registry.jobs.get(jobId(build));
      assert.ok(job);
      await idleTurn(s, "build result");
      assert.equal(ledger.reports.length, 3, "a live non-service job holds the report");
      await s.tool("stop_async_bash").execute("s", { job: job.id });
      await job.closed;
      assert.deepEqual(ledger.reports, ["first result", "second result", "follow-up result", "build result"]);
      await s.emit("message_start", { message: { role: "user", content: "wait for job" } });
      const waiting = await s.tool("async_bash").execute("c", { command: gatedCommand(`${fx.dir}/waiting`), name: "waiting" });
      await idleTurn(s);
      const beforeNotice = [...ledger.reports];
      assert.equal(beforeNotice.length, 4, "an empty turn with a live job holds the report");
      writeFileSync(`${fx.dir}/waiting`, "");
      await pollUntil(() => notices(s).some(text => text.includes(jobId(waiting))));
      assert.deepEqual(ledger.reports, beforeNotice, "a job end notice must not release the report before its turn");
      await s.emit("agent_start");
      await idleTurn(s, "job notice result");
      assert.deepEqual(ledger.reports, [...beforeNotice, "job notice result"]);

      await s.emit("message_start", { message: { role: "user", content: "empty result" } });
      await idleTurn(s);
      assert.equal(ledger.reports.at(-1), 'subagent "worker" ended its turn with no message');
      await s.emit("message_start", { message: { role: "user", content: "page task" } });
      await s.emit("agent_start");
      await s.emit("input", { type: "input", text: "page steer", source: "rpc", streamingBehavior: "steer" });
      await s.emit("turn_end", { message: assistant("stop", "before page steer"), toolResults: [] });
      assert.equal(ledger.reports.at(-1), "before page steer", "a queued page steer releases the completed turn report");
      await extension.receive({ kind: "message", agent: { name: "boss", session: "boss-session" }, relation: "parent", text: "parent after page" });
      await s.emit("message_start", { message: { role: "user", content: [{ type: "text", text: "page steer" }] } });
      await s.emit("turn_end", { message: assistant("stop", "before parent message"), toolResults: [] });
      assert.equal(ledger.reports.at(-1), "before parent message", "starting the page steer preserves queued parent input");
      await s.emit("message_start", { message: { role: "user", content: "different page input" } });
      await s.emit("turn_end", { message: assistant("stop", "parent still queued"), toolResults: [] });
      assert.equal(ledger.reports.at(-1), "parent still queued", "unmatched user input does not consume queued parent work");
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true, body: "parent after page" } } });
      const count = ledger.reports.length;
      await s.emit("turn_end", { message: assistant("stop", "after parent starts"), toolResults: [] });
      assert.equal(ledger.reports.length, count, "each queued input is consumed only once");
      await s.emit("input", { type: "input", text: "page image follow-up", source: "rpc", streamingBehavior: "followUp" });
      await s.emit("message_start", { message: { role: "user", content: [{ type: "text", text: "page image follow-up\nImage resized to fit model limits." }] } });
      await s.emit("turn_end", { message: assistant("stop", "after image follow-up"), toolResults: [] });
      assert.equal(ledger.reports.length, count, "an appended image hint does not leave queued user input");
      await s.tool("stop_async_bash").execute("s", { job: jobId(service) });
    });
  } finally { await fx.restore(); }
});

test("a child preserves its report before a queued sibling message", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger, channel) => {
      const extension = channel.host.extension;
      assert.ok(extension);
      await s.emit("agent_start");
      await extension.receive({ kind: "message", agent: { name: "sib", session: "sib-session" }, relation: "sibling", text: "hi" });
      await s.emit("turn_end", { message: assistant("stop", "A"), toolResults: [] });
      assert.deepEqual(ledger.reports, ["A"]);
      await s.emit("turn_start");
      await s.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: false, body: "hi" } } });
      await s.emit("turn_end", { message: assistant("stop", "B"), toolResults: [] });
      await s.emit("agent_end", { messages: [assistant("stop", "B")] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      assert.deepEqual(ledger.reports, ["A", "B"]);
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

test("an interim child report holds the parent's report until the final report", async () => {
  const fx = makeFixture();
  try {
    await child(fx, async (s, ledger, channel) => {
      s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name: "kid", session: "kid-session", model: "m", fork: false, cwd: "/tmp" } });
      Object.assign(channel.host.self, { extension: channel.host.extension });
      const kidChannel = createChannel();
      Object.assign(kidChannel.host.self, { id: "kid-session", parent: channel.host.self, name: "kid" });
      Object.assign(channel.host, { find: (id: string) => id === "kid-session" ? kidChannel.host.self : undefined });
      const kid = await startSession(fx, { channel: kidChannel, sessionId: "kid-session", name: "kid" });
      const parentExtension = channel.host.extension;
      const kidExtension = kidChannel.host.extension;
      assert.ok(parentExtension);
      assert.ok(kidExtension);
      for (const finalText of ["same result", ""]) {
        await s.emit("message_start", { message: { role: "user", content: "manage child" } });
        await kid.emit("message_start", { message: { role: "user", content: "task" } });
        await kid.emit("agent_start");
        await kidExtension.receive({ kind: "message", agent: { name: "worker", session: "self-session" }, relation: "parent", text: "follow up" });
        await kid.emit("turn_end", { message: assistant("stop", "same result"), toolResults: [] });
        assert.equal(entriesOf(s, "koa.report").at(-1)?.text, "same result");
        const count = ledger.reports.length;
        await idleTurn(s, "parent done");
        assert.equal(ledger.reports.length, count, "the parent must wait while the child's queued work is pending");
        assert.equal(parentExtension.childState("kid-session").reported, false);
        await kid.emit("message_start", { message: { role: "custom", customType: "ko-message", details: { work: true, body: "follow up" } } });
        await idleTurn(kid, finalText);
        assert.equal(parentExtension.childState("kid-session").reported, true);
        await idleTurn(s, "parent done");
        assert.equal(ledger.reports.length, count + 1);
      }
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
