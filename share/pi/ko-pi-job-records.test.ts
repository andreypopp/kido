import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, freshExtension, pollUntil, gatedCommand, jobRegistry, captureStatusRecords, jobRecords } from "./ko-pi-fixture.ts";

test("job records report exact bytes, linger, reload, refresh after TUI restarts, and clear on quit", async (t) => {
  const records = captureStatusRecords(t);
  const reported = (id: string, state: string) => jobRecords(records, id, state);
  const fx = makeFixture();
  try {
    process.env.KO_JOB_RECORD_LINGER_MS = "10";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const gate = join(fx.dir, "done");
    const started = await first.tools.get("async_bash").execute("a", { command: gatedCommand(gate), name: "build" });
    const id = started.details.job;
    assert.equal(reported(id, "working").length, 1);
    writeFileSync(gate, "");
    await pollUntil(() => reported(id, "done").length === 1);
    assert.ok(reported(id, "done")[0]!.endsWith(":msg=ZXhpdCAw\x1b\\"));
    await pollUntil(() => reported(id, "clear").length === 1);
    process.env.KO_JOB_RECORD_LINGER_MS = "10000";
    const live = await first.tools.get("async_bash").execute("b", { command: gatedCommand(join(fx.dir, "live")), name: "live" });
    const liveId = live.details.job;
    const failed = await first.tools.get("async_bash").execute("c", { command: "exit 7", name: "failed" });
    const failedId = failed.details.job;
    await pollUntil(() => reported(failedId, "error").length === 1);
    assert.equal(reported(failedId, "working")[0], `\x1b]7501;state=working:id=job/${failedId}:title=ZXhpdCA3:msg=ZmFpbGVk\x1b\\`);
    assert.equal(reported(failedId, "error")[0], `\x1b]7501;state=error:id=job/${failedId}:title=ZXhpdCA3:msg=ZXhpdCA3\x1b\\`);
    await first.emit("session_shutdown", { reason: "reload" });
    const before = records.length;
    const second = await startSession(fx, { factory: await freshExtension() });
    assert.equal(records[before], "\x1b]7501;state=clear:id=job\x1b\\");
    assert.equal(records.length, before + 2);
    assert.equal(reported(liveId, "working").length, 2);
    const beforeKey = records.length;
    second.terminalInput("x");
    assert.equal(records.length, beforeKey);
    await second.emit("input", { text: "next", source: "interactive" });
    assert.equal(reported(liveId, "working").length, 3);
    await second.emit("agent_start");
    assert.equal(reported(liveId, "working").length, 4);
    await second.emit("session_shutdown", { reason: "quit" });
    assert.equal(records.at(-1), "\x1b]7501;state=clear:id=job\x1b\\");
  } finally { await fx.restore(); }
});

test("service records stay idle on start, reload, and TUI restore while normal jobs work", async (t) => {
  const records = captureStatusRecords(t);
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const service = await first.tools.get("async_bash").execute("s", { command: gatedCommand(join(fx.dir, "service")), name: "server", service: true });
    const normal = await first.tools.get("async_bash").execute("n", { command: gatedCommand(join(fx.dir, "normal")), name: "build" });
    const check = (count: number) => {
      assert.equal(jobRecords(records, service.details.job, "idle").length, count);
      assert.equal(jobRecords(records, service.details.job, "working").length, 0);
      assert.ok(jobRecords(records, service.details.job, "idle").every(record => record.endsWith(":msg=c2VydmljZTogc2VydmVy\x1b\\")));
      assert.equal(jobRecords(records, normal.details.job, "working").length, count);
    };
    check(1);
    await first.emit("session_shutdown", { reason: "reload" });
    const second = await startSession(fx, { factory: await freshExtension() });
    check(2);
    await second.emit("input", { text: "next", source: "interactive" });
    check(3);
    await second.emit("agent_start");
    check(4);
  } finally { await fx.restore(); }
});

test("the record cap drops new working jobs and reuses the oldest finished slot; text is bounded and encoded", async (t) => {
  const records = captureStatusRecords(t);
  const fx = makeFixture();
  try {
    process.env.KO_JOB_RECORD_LINGER_MS = "10000";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const started = await s.tools.get("async_bash").execute("a", { command: gatedCommand(join(fx.dir, "live")), name: "live" });
    const registry = jobRegistry();
    const job = registry.jobs.get(started.details.job);
    const pane = process.env.KO_PANE;
    delete process.env.KO_PANE;
    registry.owner.onStart({ ...job, id: "hidden" });
    process.env.KO_PANE = pane;
    assert.equal(jobRecords(records, "hidden").length, 0);
    registry.owner.onStart({ ...job, id: "encoded", command: "a:b;\n\x1b\x9b λ", mode: { ...job.mode, name: "a:b;\tλ" } });
    assert.equal(records.at(-1), "\x1b]7501;state=working:id=job/encoded:title=YTpiOyDOuw==:msg=YTpiOyDOuw==\x1b\\");
    const sample = { ...job, id: "signal", command: "test" };
    registry.owner.onStart(sample);
    registry.owner.onEnd({ ...sample, state: { type: "ended", end: { type: "signal", signal: "SIGTERM" }, announced: true } });
    assert.equal(records.at(-1), "\x1b]7501;state=error:id=job/signal:title=dGVzdA==:msg=c2lnbmFsIFNJR1RFUk0=\x1b\\");
    registry.owner.onStart({ ...job, id: "bounded", command: "λ".repeat(100) });
    assert.equal(records.at(-1)!.split(":title=")[1]!.split(":")[0], Buffer.from("λ".repeat(96)).toString("base64"));
    for (let i = 0; i < 32; i++) registry.owner.onStart({ ...job, id: `extra${i}` });
    assert.equal(jobRecords(records, undefined, "working").length, 33);
    assert.equal(jobRecords(records, "extra31").length, 0);
    registry.owner.onEnd({ ...job, state: { type: "ended", end: { type: "exit", code: 0 }, announced: true } });
    registry.owner.onStart({ ...job, id: "replacement" });
    assert.ok(records.includes(`\x1b]7501;state=clear:id=job/${job.id}\x1b\\`));
    assert.equal(jobRecords(records, "replacement", "working").length, 1);
  } finally { await fx.restore(); }
});
