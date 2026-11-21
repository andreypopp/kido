import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { ofType } from "./koa-agent-fixture.ts";
import { realFixture } from "./koa-program-fixture.ts";
test("metrics are opt-in and record frame samples with stream counters", { timeout: 10000 }, async t => {
  const off = await realFixture(t, { replies: [] });
  assert.equal((await off.post("metrics", { samples: [], observations: [] })).status, 404);
  assert.equal(off.records().some(record => record.type === "flush"), false);
  assert.doesNotMatch(await (await fetch(off.base)).text(), /<meta name="koa-metrics"/);
  const dir = await mkdtemp(join(tmpdir(), "koa-metrics-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, "metrics.jsonl");
  const on = await realFixture(t, {replies: [], args: ["--metrics", file, "--metrics-mode", "frame"] });
  const flush = await on.until(ofType("flush"));
  assert.equal(typeof flush.t, "number");
  assert.ok(flush.bytes > 0);
  assert.match(await (await fetch(on.base)).text(), /<meta name="koa-metrics" content="frame">/);
  const samples = [{ t: flush.t, frame: flush.t + 12, bytes: 100, clockError: 0 }];
  assert.equal((await on.post("metrics", { samples, observations: [] })).status, 200);
  const record = JSON.parse((await readFile(file, "utf8")).trim());
  assert.deepEqual(record.samples, samples);
  assert.equal(record.type, "metrics");
  assert.equal(record.opens, 1); assert.equal(record.resets, 1); assert.equal(record.cursors, 0);
  assert.equal(record.caps, 0); assert.equal(record.subscribers, 1);
  assert.ok(record.bytes > 0); assert.ok(record.highWater > 0);
  assert.equal((await on.post("metrics", { samples: [{ t: flush.t, applied: flush.t + 1, bytes: 100, clockError: 0 }], observations: [{ type: "frame", at: 1, duration: 2, lex: 0, strays: 0, by: {} }] })).status, 200);
  assert.equal((await on.post("metrics", { samples: [{ t: "bad" }], observations: [] })).status, 400);
  assert.equal((await on.post("metrics", { samples: [], observations: [{ type: "bogus", at: 1 }] })).status, 400);
  await rm(file); await mkdir(file);
  assert.equal((await on.post("metrics", { samples, observations: [] })).status, 500);
  await rm(file, { recursive: true }); await writeFile(file, "");
  assert.equal((await on.post("metrics", { samples, observations: [] })).status, 200);
  assert.deepEqual(JSON.parse((await readFile(file, "utf8")).trim()).samples, samples);
});

test("metrics mode is explicit and requires metrics", { timeout: 10000 }, async () => {
  for (const args of [["--metrics-mode", "frame"], ["--metrics-mode", "invalid"]]) {
    const child = spawn(process.execPath, [resolve('../build/koa/share/koa/koa/koa.ts'), ...args], { env: { ...process.env, PATH: '' }, timeout: 5000 });
    let error = "";
    child.stderr.on("data", bytes => { error += bytes; });
    const [code] = await once(child, "close");
    assert.equal(code, 1);
    assert.match(error, args[1] === "frame" ? /--metrics-mode requires --metrics/ : /--metrics-mode requires applied, frame or probe/);
  }
});

