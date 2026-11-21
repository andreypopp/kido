import type { TestContext } from "node:test";
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { sse, ofType, pollUntil } from "./koa-agent-fixture.ts";
import { serveChild } from "./koa-program-fixture.ts";
import { expect, next, sequence, type Scenarios, type Scenario } from "./testdata/scenario.ts";

const replay = fileURLToPath(new URL("./testdata/replay.ts", import.meta.url));

async function start(t: TestContext, name: string) {
  const dir = await mkdtemp(join(tmpdir(), "koa-replay-test-"));
  const { base } = await serveChild(t, dir, [replay, "--browser", "selftest", name, dir], { env: { HOME: dir, OPEN_LOG: join(dir, "urls") }, label: "replay" });
  const json = async (path: string, body?: object) => {
    const response = await fetch(base + path, body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const events = async () => {
    const controller = new AbortController();
    t.after(() => controller.abort());
    const response = await fetch(base + "events", { signal: controller.signal });
    assert.ok(response.body);
    return { ...sse(Readable.from(response.body)), abort: () => controller.abort() };
  };
  return { base, json, events, status: () => json("replay/status"), dir };
}

test("a held reply waits for its release, then pushes its after records; a disconnect is no mismatch", async t => {
  const app = await start(t, "hold");
  const feed = await app.events();
  await feed.until(ofType("state"));
  const held = new AbortController();
  const pending = fetch(app.base + "sessions/list", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sessionId: "s1", scope: "all" }), signal: held.signal });
  await pollUntil(async () => (await app.status()).body.pending.length === 1, 5000, "the held reply");
  assert.equal((await app.json("replay/release", { name: "other" })).status, 409);
  assert.deepEqual((await app.status()).body, { step: 1, total: 2, mismatches: 1, last: "no held reply named other", pending: ["rows"] });
  assert.equal(feed.state.records.some(ofType("item")), false);
  held.abort();
  await assert.rejects(pending);
  assert.equal((await app.json("replay/release", { name: "rows" })).status, 200);
  await feed.until(ofType("item", record => record.item.seq === 1));
  assert.deepEqual((await app.status()).body, { step: 1, total: 2, mismatches: 1, last: "no held reply named other", pending: [] });
  assert.equal((await app.json("abort", {})).status, 200);
  assert.equal((await app.status()).body.mismatches, 1);
});

test("a real upload goes through prompt, the queue and its take-back", async t => {
  const app = await start(t, "queue");
  const feed = await app.events();
  await feed.until(ofType("state"));
  const created = await app.json("attachments", { name: "note.txt", type: "text/plain", size: 5 });
  assert.equal(created.status, 200);
  const chunk = await fetch(app.base + `attachments/${created.body.id}/0`, { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: "hello" });
  assert.equal(chunk.status, 200);
  const prompt = { sessionId: "s1", text: "later", mode: "prompt", attachments: [created.body.id] };
  assert.equal((await app.json("prompt", prompt)).body.disposition, "queued");
  const queue = await feed.until(ofType("state", record => record.queue.steering.length === 1));
  assert.equal(queue.queue.steering[0]?.attachments[0]?.id, created.body.id);
  assert.equal(queue.queue.steering[0]?.attachments[0]?.path, created.body.path);
  assert.equal((await app.json("attachments/" + created.body.id + "/delete", {})).status, 409);
  assert.equal((await app.json("queue/remove", { sessionId: "s1", kind: "steer", index: 0, text: "later" })).status, 200);
  const back = await feed.until(ofType("item", record => record.item.seq === 1));
  assert.equal(back.item.kind === "user" && back.item.attachments[0]?.id, created.body.id);
  assert.equal((await app.json("prompt", prompt)).body.disposition, "started");
  assert.deepEqual((await app.status()).body, { step: 3, total: 3, mismatches: 0, pending: [] });
  assert.equal((await app.json("attachments/" + created.body.id + "/delete", {})).status, 409);
});

test("every scenario module builds its scenarios", async () => {
  const names = (await readdir(new URL("./testdata/scenarios/", import.meta.url))).filter(name => name.endsWith(".ts"));
  const keys = new Set<string>();
  for (const name of names) {
    const loaded: { scenarios: Scenarios } = await import(new URL(`./testdata/scenarios/${name}`, import.meta.url).href);
    for (const [method, build] of Object.entries(loaded.scenarios)) {
      const scenario = build("/tmp/koa-replay-dir");
      assert.ok(scenario.open.length, `${name} ${method}`);
      keys.add(method);
    }
  }
  const driver = await readFile(new URL('./visual/driver.ts', import.meta.url), 'utf8');
  const calls = [...driver.matchAll(/\bkoaWebview\("([^"]+)"|\bscrollPage\(\s*"[^"]+",\s*"([^"]+)"/g)];
  assert.equal(calls.length, 41);
  for (const match of calls) {
    const key = match[1] ?? match[2];
    assert.ok(keys.has(key), `No replay scenario for ${key}`);
  }
});

test('scenario sequences keep strict steps and give reset phases separate epochs', () => {
  const phase: Scenario = { open: [{ type: 'reset', epoch: 'same', items: [], more: false }], steps: [next([])], files: { 'a.txt': 'a' } };
  const combined = sequence([phase, phase]);
  assert.deepEqual(combined.open, [{ type: 'reset', epoch: '0:same', items: [], more: false }]);
  assert.deepEqual(combined.steps, [next([]), next([{ type: 'reset', epoch: '1:same', items: [], more: false }]), next([])]);
  assert.deepEqual(combined.files, { 'a.txt': 'a' });
  assert.throws(() => sequence([phase, { ...phase, files: { 'a.txt': 'b' } }]), /Conflicting scenario file/);
});

test('scenario sequences remap static and computed history replies without changing request predicates', () => {
  const matches = (value: unknown) => value === 'exact';
  const input = { body: 'exact', attachments: [] };
  const history = { epoch: 'same', more: false, items: [] };
  const staticStep = expect({ on: { method: 'GET', path: '/items', body: matches }, reply: { status: 200, json: history } });
  const computedStep = expect({ on: { method: 'GET', path: '/items', body: matches }, before: () => [{ type: 'reset', epoch: 'same', more: false, items: [] }], reply: { status: 200, json: () => history }, after: [{ type: 'reset', epoch: 'same', more: false, items: [] }] });
  const combined = sequence([{ open: [], steps: [staticStep], files: {} }, { open: [], steps: [computedStep], files: {} }]);
  const first = combined.steps[0], last = combined.steps[2];
  assert.ok(first.on !== 'next' && last.on !== 'next');
  assert.equal(first.on.body, matches);
  assert.equal(last.on.body, matches);
  assert.equal(last.on.body?.('wrong'), false);
  assert.deepEqual(first.reply.json, { ...history, epoch: '0:same' });
  assert.equal(typeof last.reply.json, 'function');
  if (typeof last.reply.json !== 'function') throw Error('Missing computed reply');
  assert.deepEqual(last.reply.json(input), { ...history, epoch: '1:same' });
  assert.equal(typeof last.before, 'function');
  if (typeof last.before !== 'function') throw Error('Missing computed records');
  assert.deepEqual(last.before(input), [{ type: 'reset', epoch: '1:same', more: false, items: [] }]);
  assert.deepEqual(last.after, [{ type: 'reset', epoch: '1:same', more: false, items: [] }]);
});

test("a step's file is served from the path in its block, and follows a patch", async t => {
  const app = await start(t, "file");
  await writeFile(join(app.dir, "a.txt"), "A");
  await writeFile(join(app.dir, "b.txt"), "B");
  const text = async (path: string) => { const response = await fetch(app.base + path); return [response.status, await response.text()]; };
  assert.deepEqual(await text("steps/0/0/file"), [200, "A"]);
  assert.equal((await app.json("replay/next", {})).status, 200);
  assert.deepEqual(await text("steps/0/0/file"), [200, "B"]);
  assert.equal((await text("steps/0/1/file"))[0], 404);
  assert.equal((await text("steps/9/0/file"))[0], 404);
});

test("a next that arrives before the page's earlier request waits for it; a mismatch names itself in the status", async t => {
  const app = await start(t, "wait");
  const feed = await app.events();
  await feed.until(ofType("state"));
  const next = app.json("replay/next", {});
  assert.equal((await app.json("abort", {})).status, 200);
  assert.equal((await next).status, 200);
  await feed.until(ofType("item", record => record.item.seq === 1));
  assert.equal((await app.json("abort", {})).status, 409);
  const status = (await app.status()).body;
  assert.equal(status.mismatches, 1);
  assert.match(status.last, /expected no request, got POST \/abort/);
});

test("a next that waits for a prompt with an upload pushes its records after the prompt's", async t => {
  const app = await start(t, "sequence");
  const feed = await app.events();
  await feed.until(ofType("state"));
  const created = await app.json("attachments", { name: "note.txt", type: "text/plain", size: 5 });
  await fetch(app.base + `attachments/${created.body.id}/0`, { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: "hello" });
  const next = app.json("replay/next", {});
  assert.equal((await app.json("prompt", { sessionId: "s1", text: "go", mode: "prompt", attachments: [created.body.id] })).status, 200);
  assert.equal((await next).status, 200);
  await feed.until(ofType("item", record => record.item.seq === 12));
  assert.deepEqual(feed.state.records.filter(ofType("item")).map(record => record.item.seq), [10, 11, 12]);
});
