import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir, cp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { createServer } from "node:net";
import { pollUntil, ofType } from "./koa-agent-fixture.ts";
import { realFixture } from "./koa-program-fixture.ts";
test('completion limits active searches and kills expired children', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-search-limit-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const gate = join(dir, 'gate'), fd = join(dir, 'fd');
  await writeFile(fd, `#!${process.execPath}\nrequire('node:net').connect(${JSON.stringify(gate)}).on('connect',function(){this.write('ready')});\n`, { mode: 0o700 });
  const sockets = new Set<import('node:net').Socket>(); let accepted = 0;
  const server = createServer(socket => { accepted++; sockets.add(socket); socket.on('data', () => {}); socket.once('close', () => sockets.delete(socket)); });
  server.listen(gate); await once(server, 'listening'); t.after(() => { for (const socket of sockets) socket.destroy(); server.close(); });
  const app = await realFixture(t, {replies: [], env: { KOA_FD: fd } });
  const controller = new AbortController();
  const first = fetch(app.base + 'complete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionId: app.records().filter(record => record.type === 'state').at(-1)?.sessionId, text: '@', pos: 1 }), signal: controller.signal });
  const rejected = assert.rejects(first, { name: 'AbortError' });
  let secondEnded = false;
  const second = app.post('complete', { text: '@', pos: 1 }).then(response => { secondEnded = true; return response; });
  await pollUntil(() => sockets.size === 4, 1500, 'four fd children');
  const capped = await app.post('complete', { text: '@', pos: 1 });
  assert.equal(capped.status, 200); assert.deepEqual((await capped.json()).options, []); assert.equal(accepted, 4);
  controller.abort(); await rejected;
  await pollUntil(() => sockets.size === 2, 1000, 'disconnect releases children');
  const replacements: Promise<Response>[] = [];
  let retry = true;
  await pollUntil(() => {
    if (accepted > 4) return true;
    if (retry) {
      retry = false;
      const replacement = app.post('complete', { text: '@', pos: 1 });
      replacements.push(replacement);
      void replacement.then(() => { retry = true; });
    }
    return false;
  }, 1000, 'disconnect releases capacity');
  assert.equal(secondEnded, false);
  assert.deepEqual((await (await second).json()).options, []);
  for (const replacement of replacements) assert.deepEqual((await (await replacement).json()).options, []);
  await pollUntil(() => sockets.size === 0, 1000, 'expired children ended');
});

test("document loads read the current page files and recover after a failed read", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-page-reload-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../../build/ko/share/ko/koa"), dir, { recursive: true });
  const program = join(dir, "koa.ts");
  await writeFile(program, `import ${JSON.stringify(resolve('../../build/ko/share/ko/koa/koa.ts'))};`);
  const app = await realFixture(t, {replies: [], env: { KOA_PAGE_RELOAD: '1' }, program });
  for (const name of ["page.html", "page.css", "page.js"]) {
    const file = join(dir, name), marker = `reload-${name}`;
    assert.doesNotMatch(await (await fetch(app.base)).text(), new RegExp(marker));
    const original = await readFile(file, "utf8");
    await writeFile(file, original + `\n/* ${marker} */`);
    assert.match(await (await fetch(app.base)).text(), new RegExp(marker));
  }
  const file = join(dir, "page.css"), style = await readFile(file, "utf8");
  await rm(file);
  const failed = await fetch(app.base);
  assert.equal(failed.status, 500);
  assert.match(await failed.text(), /ENOENT.*page\.css/);
  await writeFile(file, style);
  const restored = await fetch(app.base);
  assert.equal(restored.status, 200);
  assert.match(await restored.text(), /reload-page\.css/);
});

test("metrics are opt-in and record frame samples with stream counters", { timeout: 10000 }, async t => {
  const off = await realFixture(t, { replies: [] });
  assert.equal((await off.post("metrics", [])).status, 404);
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
  assert.equal((await on.post("metrics", samples)).status, 200);
  const record = JSON.parse((await readFile(file, "utf8")).trim());
  assert.deepEqual(record.samples, samples);
  assert.equal(record.type, "metrics");
  assert.equal(record.opens, 1); assert.equal(record.resets, 1); assert.equal(record.cursors, 0);
  assert.equal(record.caps, 0); assert.equal(record.subscribers, 1);
  assert.ok(record.bytes > 0); assert.ok(record.highWater > 0);
  assert.equal((await on.post("metrics", [{ t: flush.t, applied: flush.t + 1, bytes: 100, clockError: 0 }])).status, 200);
  assert.equal((await on.post("metrics", [{ t: "bad" }])).status, 400);
  await rm(file); await mkdir(file);
  assert.equal((await on.post("metrics", samples)).status, 500);
  await rm(file, { recursive: true }); await writeFile(file, "");
  assert.equal((await on.post("metrics", samples)).status, 200);
  assert.deepEqual(JSON.parse((await readFile(file, "utf8")).trim()).samples, samples);
});

test("metrics mode is explicit and requires metrics", { timeout: 10000 }, async () => {
  for (const args of [["--metrics-mode", "frame"], ["--metrics-mode", "invalid"]]) {
    const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), ...args], { env: { ...process.env, PATH: '' }, timeout: 5000 });
    let error = "";
    child.stderr.on("data", bytes => { error += bytes; });
    const [code] = await once(child, "close");
    assert.equal(code, 1);
    assert.match(error, args[1] === "frame" ? /--metrics-mode requires --metrics/ : /--metrics-mode requires applied or frame/);
  }
});

