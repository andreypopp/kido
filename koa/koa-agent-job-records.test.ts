import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, freshExtension, pollUntil, gatedCommand, processGone, captureStatusRecords, getRows, jobId, liveRegistry, backgroundJob, liveJobs, viewing } from "./koa-agent-fixture.ts";

for (const mode of ["interactive", "rpc"]) test(`job snapshots and retention survive reload in ${mode} mode`, async (t) => {
  const stdout = captureStatusRecords(t);
  const fx = makeFixture();
  const reports = () => fx.posts(`/panes/${process.env.KO_PANE}/status`);
  const latest = (id: string) => getRows(reports().at(-1), "records").find(record => record.id === `jobs/${id}`);
  try {
    process.env.KO_JOB_RECORD_LINGER_MS = "60000";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx, { ctx: { hasUI: true, mode } });
    const gate = join(fx.dir, "done");
    const id = jobId(await first.tool("async_bash").execute("a", { command: gatedCommand(gate), name: "build" }));
    await pollUntil(() => latest(id)?.state === "working");
    assert.equal(latest(id)?.title, "build");
    assert.equal(latest(id)?.msg, gatedCommand(gate));
    writeFileSync(gate, "");
    await pollUntil(() => latest(id)?.state === "done");
    assert.equal(latest(id)?.msg, "exit 0");
    assert.equal(backgroundJob(id).mode.retention.type, "lingering");
    const failed = jobId(await first.tool("async_bash").execute("c", { command: "exit 7", name: "failed" }));
    await pollUntil(() => latest(failed)?.state === "error");
    assert.equal(latest(failed)?.msg, "exit 7");
    await first.emit("session_shutdown", { reason: "reload" });
    const before = reports().length;
    const second = await startSession(fx, { factory: await freshExtension(), ctx: { hasUI: true, mode } });
    await second.channel.host.records.drain();
    assert.equal(reports().length, before, "reload keeps the acknowledged projection");
    await second.emit("session_shutdown", { reason: "quit" });
    assert.deepEqual(reports().at(-1), { type: "replace_subtrees", roots: ["agents", "jobs"], records: [] });
    for (const report of reports()) assert.equal(report.type, "replace_subtrees");
    assert.deepEqual(stdout, []);
  } finally { await fx.restore(); }
});

test("the registry exit handler stops only owned jobs", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const gate = join(fx.dir, "gate");
    await s.tool("async_bash").execute("a", { command: gatedCommand(gate), name: "live" });
    await pollUntil(async () => !(await processGone(gate)));
    liveRegistry().exit();
    await pollUntil(() => processGone(gate));
  } finally { await fx.restore(); }
});

test("service snapshots stay idle, text is bounded, and synthetic jobs must be registered", async (t) => {
  captureStatusRecords(t);
  const fx = makeFixture();
  const reports = () => fx.posts(`/panes/${process.env.KO_PANE}/status`);
  const latest = (id: string) => getRows(reports().at(-1), "records").find(record => record.id === `jobs/${id}`);
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = jobId(await s.tool("async_bash").execute("s", { command: gatedCommand(join(fx.dir, "service")), name: "server", service: true }));
    await pollUntil(() => latest(id)?.state === "idle");
    const job = backgroundJob(id), registry = liveRegistry();
    assert.ok(registry.owner);
    const encoded = { ...job, id: "encoded", command: "a:b;\n\x1b\x9b λ", mode: { ...job.mode, name: "a:b;\tλ", retention: { type: "retained" as const } } };
    const bounded = { ...job, id: "bounded", command: "λ".repeat(1100), mode: { ...job.mode, name: "λ".repeat(100), retention: { type: "retained" as const } } };
    registry.jobs.set(encoded.id, encoded); registry.jobs.set(bounded.id, bounded);
    registry.owner.onStart(encoded); registry.owner.onStart(bounded);
    await s.channel.host.records.drain();
    assert.equal(latest("encoded")?.title, "a:b; λ");
    assert.equal(latest("encoded")?.msg, "a:b; λ");
    assert.equal(latest("bounded")?.title, "λ".repeat(96));
    assert.equal(latest("bounded")?.msg, "λ".repeat(1024));
    assert.equal(latest(id)?.state, "idle");
    registry.jobs.delete(encoded.id); registry.jobs.delete(bounded.id);
  } finally { await fx.restore(); }
});

test("actual watchers cancel expiry, selection alone does not, and dismissal is final", async (t) => {
  captureStatusRecords(t);
  const fx = makeFixture();
  try {
    delete process.env.KO_JOB_RECORD_LINGER_MS;
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const id = jobId(await s.tool("async_bash").execute("a", { command: gatedCommand(gate), name: "watched" }));
    const job = backgroundJob(id);
    viewing.job = job; viewing.watched.add(job); liveJobs().viewChanged();
    writeFileSync(gate, "");
    await pollUntil(() => job.state.type === "ended");
    assert.equal(backgroundJob(id).mode.retention.type, "retained");
    viewing.watched.delete(job); liveJobs().viewChanged();
    assert.equal(backgroundJob(id).mode.retention.type, "lingering", "selection is not a subscriber");
    viewing.watched.add(job); liveJobs().viewChanged();
    assert.equal(backgroundJob(id).mode.retention.type, "retained");
    t.mock.timers.enable({ apis: ["setTimeout"] });
    viewing.watched.delete(job); viewing.job = undefined; liveJobs().viewChanged();
    assert.equal(backgroundJob(id).mode.retention.type, "lingering");
    t.mock.timers.tick(60000);
    assert.equal(backgroundJob(id).mode.retention.type, "dismissed");
    t.mock.timers.reset();
    assert.equal(liveJobs().owns(`jobs/${id}`), false);
    liveJobs().viewChanged(); liveRegistry().owner?.onEnd(job);
    await s.channel.host.records.drain();
    const records = getRows(fx.posts(`/panes/${process.env.KO_PANE}/status`).at(-1), "records");
    assert.ok(!records.some(record => record.id === `jobs/${id}`));
    assert.equal(backgroundJob(id).mode.retention.type, "dismissed");
  } finally { viewing.job = undefined; viewing.watched.clear(); await fx.restore(); }
});

test("close stops live jobs and dismisses ended jobs", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_KILL_MS = "100";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const id = jobId(await s.tool("async_bash").execute("a", { command: gatedCommand(join(fx.dir, "live")), name: "live" }));
    assert.equal(liveJobs().close(`jobs/${id}`), true);
    await pollUntil(() => backgroundJob(id).state.type === "ended");
    assert.equal(backgroundJob(id).mode.retention.type, "lingering");
    assert.equal(liveJobs().close(`jobs/${id}`), true);
    assert.equal(backgroundJob(id).mode.retention.type, "dismissed");
    assert.equal(liveJobs().close(`jobs/${id}`), false);
  } finally { await fx.restore(); }
});
