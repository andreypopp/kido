import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, freshExtension, pollUntil, gatedCommand, captureStatusRecords, at, jobId, liveRegistry, backgroundJob } from "./koa-agent-fixture.ts";

for (const mode of ["interactive", "rpc"]) test(`job reports use the status route in ${mode} mode`, async (t) => {
  const stdout = captureStatusRecords(t);
  const fx = makeFixture();
  const reports = () => fx.posts(`/panes/${process.env.KO_PANE}/status`);
  const reported = (id: string, state: string) => reports().filter(r => r.id === `job/${id}` && (state === "clear" ? r.type === "clear" : r.type === "set" && r.state === state));
  try {
    process.env.KO_JOB_RECORD_LINGER_MS = "10";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx, { ctx: { hasUI: true, mode } });
    const gate = join(fx.dir, "done");
    const started = await first.tool("async_bash").execute("a", { command: gatedCommand(gate), name: "build" });
    const id = jobId(started);
    await pollUntil(() => reported(id, "working").length === 1);
    assert.equal(at(reported(id, "working"), 0).title, "build");
    assert.equal(at(reported(id, "working"), 0).msg, gatedCommand(gate));
    writeFileSync(gate, "");
    await pollUntil(() => reported(id, "clear").length === 1);
    assert.deepEqual(reports().filter(r => r.id === `job/${id}`).map(r => r.type === "clear" ? "clear" : r.state), ["working", "done", "clear"]);
    assert.equal(at(reported(id, "done"), 0).title, "build");
    assert.equal(at(reported(id, "done"), 0).msg, "exit 0");
    process.env.KO_JOB_RECORD_LINGER_MS = "10000";
    const live = await first.tool("async_bash").execute("b", { command: gatedCommand(join(fx.dir, "live")), name: "live" });
    const liveId = jobId(live);
    const failed = await first.tool("async_bash").execute("c", { command: "exit 7", name: "failed" });
    await pollUntil(() => reported(jobId(failed), "error").length === 1);
    assert.equal(at(reported(jobId(failed), "error"), 0).title, "failed");
    assert.equal(at(reported(jobId(failed), "error"), 0).msg, "exit 7");
    await first.emit("session_shutdown", { reason: "reload" });
    const before = reports().length;
    const second = await startSession(fx, { factory: await freshExtension(), ctx: { hasUI: true, mode } });
    await pollUntil(() => reported(liveId, "working").length === 2);
    assert.deepEqual(reports()[before], { type: "clear", id: "job" });
    for (const record of reported(liveId, "working")) {
      assert.equal(record.title, "live");
      assert.equal(record.msg, gatedCommand(join(fx.dir, "live")));
    }
    await second.emit("session_shutdown", { reason: "quit" });
    assert.deepEqual(reports().at(-1), { type: "clear", id: "job" });
    assert.deepEqual(stdout, []);
  } finally { await fx.restore(); }
});

test("the process exit handler clears job records synchronously", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await startSession(fx);
    const reports = () => fx.posts(`/panes/${process.env.KO_PANE}/status`);
    await pollUntil(() => reports().length === 1);
    liveRegistry().exit();
    assert.equal(reports().length, 2);
    assert.deepEqual(reports().at(-1), { type: "clear", id: "job" });
  } finally { await fx.restore(); }
});

test("service reports stay idle and job text and capacity are bounded", async (t) => {
  const stdout = captureStatusRecords(t);
  const fx = makeFixture();
  const reports = () => fx.posts(`/panes/${process.env.KO_PANE}/status`);
  const reported = (id: string, state?: string) => reports().filter(r => r.id === `job/${id}` && (state === undefined || r.state === state));
  try {
    process.env.KO_JOB_RECORD_LINGER_MS = "10000";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const service = await s.tool("async_bash").execute("s", { command: gatedCommand(join(fx.dir, "service")), name: "server", service: true });
    const started = await s.tool("async_bash").execute("a", { command: gatedCommand(join(fx.dir, "live")), name: "live" });
    await pollUntil(() => reported(jobId(service), "idle").length === 1);
    assert.equal(at(reported(jobId(service)), 0).title, "server");
    assert.equal(at(reported(jobId(service)), 0).msg, gatedCommand(join(fx.dir, "service")));
    const job = backgroundJob(jobId(started));
    const registry = liveRegistry();
    assert.ok(registry.owner);
    const owner = registry.owner;
    owner.onStart({ ...job, id: "encoded", command: "a:b;\n\x1b\x9b λ", mode: { ...job.mode, name: "a:b;\tλ" } });
    owner.onStart({ ...job, id: "bounded", command: "λ".repeat(1100), mode: { ...job.mode, name: "λ".repeat(100) } });
    for (let i = 0; i < 32; i++) owner.onStart({ ...job, id: `extra${i}` });
    owner.onEnd({ ...job, state: { type: "ended", end: { type: "exit", code: 0 }, announced: true } });
    owner.onStart({ ...job, id: "replacement" });
    await pollUntil(() => reported("replacement", "working").length === 1);
    assert.equal(at(reported("encoded"), 0).title, "a:b; λ");
    assert.equal(at(reported("encoded"), 0).msg, "a:b; λ");
    assert.equal(at(reported("bounded"), 0).title, "λ".repeat(96));
    assert.equal(at(reported("bounded"), 0).msg, "λ".repeat(1024));
    assert.equal(reported("extra31").length, 0);
    assert.ok(reported(job.id).some(r => r.type === "clear"));
    await s.emit("session_shutdown", { reason: "reload" });
    await startSession(fx, { factory: await freshExtension() });
    await pollUntil(() => reported(jobId(service), "idle").length === 2);
    assert.equal(reported(jobId(service), "working").length, 0);
    assert.deepEqual(stdout, []);
  } finally { await fx.restore(); }
});
