import type { TestContext } from "node:test";
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { sse, ofType, pollUntil } from "./koa-agent-fixture.ts";
import { serveChild } from "./koa-program-fixture.ts";
import type { Scenarios } from "./testdata/scenario.ts";

const replay = fileURLToPath(new URL("./testdata/replay.ts", import.meta.url));

async function start(t: TestContext, name: string) {
  const dir = await mkdtemp(join(tmpdir(), "koa-replay-test-"));
  const { base } = await serveChild(t, dir, [replay, "--browser", "selftest", name, dir], { env: { HOME: dir, OPEN_LOG: join(dir, "urls") }, label: "replay" });
  const json = async (path: string, body?: object, headers: Record<string, string> = { "Content-Type": "application/json" }) => {
    const response = await fetch(base + path, body === undefined ? {} : { method: "POST", headers, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const events = async (query = "") => {
    const controller = new AbortController();
    t.after(() => controller.abort());
    const response = await fetch(base + "events" + query, { signal: controller.signal });
    assert.ok(response.body);
    return { ...sse(Readable.from(response.body)), abort: () => controller.abort() };
  };
  const rawEvents = async (query: string) => {
    const controller = new AbortController();
    t.after(() => controller.abort());
    const response = await fetch(base + "events" + query, { signal: controller.signal });
    assert.ok(response.body);
    const decoder = new TextDecoder();
    const chunks = response.body.values();
    let buffered = "";
    return async () => {
      while (!buffered.includes("\n\n")) { const chunk = await chunks.next(); assert.ok(!chunk.done); buffered += decoder.decode(chunk.value, { stream: true }); }
      const end = buffered.indexOf("\n\n");
      const block = buffered.slice(0, end + 2);
      buffered = buffered.slice(end + 2);
      return block;
    };
  };
  return { base, json, events, rawEvents, status: () => json("replay/status"), dir };
}

test("the replay serves the page, walks its steps in order and keeps a cursored feed quiet", async t => {
  const app = await start(t, "order");
  const html = await (await fetch(app.base)).text();
  assert.match(html, /<meta name="koa-instance" content="[0-9a-f-]{36}">/);
  const instance = html.match(/koa-instance" content="([^"]+)/)?.[1];
  const feed = await app.events("?epoch=&after=-1&koa=" + instance);
  await feed.until(ofType("state"));
  assert.deepEqual(feed.state.records.map(record => record.type), ["reset", "state"]);
  const cursored = await app.rawEvents("?epoch=e1&after=0");
  assert.equal(await cursored(), ":\n\n");
  const stale = await app.events("?epoch=e1&after=0&koa=other");
  await stale.until(ofType("reload"));
  assert.deepEqual(stale.state.records, [{ type: "reload" }]);
  const prompt = { sessionId: "s1", text: "two", mode: "prompt", attachments: [] };
  const early = await app.json("prompt", prompt);
  assert.equal(early.status, 409);
  assert.match(early.body.error, /expected \/replay\/next, got POST \/prompt/);
  assert.deepEqual((await app.status()).body, { step: 0, total: 2, mismatches: 1, last: 'expected /replay/next, got POST /prompt {"sessionId":"s1","text":"two","mode":"prompt","attachments":[]}', pending: [] });
  assert.equal((await app.json("replay/next", {})).status, 200);
  await feed.until(ofType("item", record => record.item.seq === 1));
  assert.equal(JSON.parse((await cursored()).slice(6)).item.seq, 1);
  const wrong = await app.json("prompt", { ...prompt, text: "other" });
  assert.equal(wrong.status, 409);
  assert.match(wrong.body.error, /expected POST \/prompt, got POST \/prompt/);
  assert.equal((await app.json("prompt", prompt)).body.disposition, "started");
  await feed.until(ofType("item", record => record.item.seq === 3));
  assert.deepEqual(feed.state.records.filter(ofType("item")).map(record => record.item.seq), [1, 2, 3]);
  assert.deepEqual((await app.status()).body, { step: 2, total: 2, mismatches: 2, last: 'expected POST /prompt, got POST /prompt {"sessionId":"s1","text":"other","mode":"prompt","attachments":[]}', pending: [] });
  assert.equal((await app.json("replay/next", {})).status, 409);
  assert.equal((await app.json("prompt", prompt, { "Content-Type": "text/plain" })).status, 415);
  assert.equal((await fetch(app.base + "images/missing?e=1&r=1")).status, 410);
});

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
  let count = 0;
  for (const name of names) {
    const loaded: { scenarios: Scenarios } = await import(new URL(`./testdata/scenarios/${name}`, import.meta.url).href);
    for (const [method, build] of Object.entries(loaded.scenarios)) {
      const scenario = build("/tmp/koa-replay-dir");
      assert.ok(scenario.open.length, `${name} ${method}`);
      count++;
    }
  }
  assert.ok(count > 60, `${count} scenarios`);
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
