import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { selfPane, pollUntil, gatedCommand, ofType, sse } from "./koa-agent-fixture.ts";
import type { PageRecord } from "./koa-records.ts";
import { realFixture } from "./koa-program-fixture.ts";

type Reset = { type: "job-reset"; view: string; epoch: string; start: number; end: number; data: string };
type Append = { type: "job-append"; view: string; epoch: string; start: number; data: string };
const isReset = (record: { type: string }): record is Reset => record.type === "job-reset";
const isAppend = (record: { type: string }): record is Append => record.type === "job-append";
const text = (record: { data: string }) => Buffer.from(record.data, "base64").toString("utf8");
const received = (records: { type: string }[]) => records.flatMap(record => isReset(record) || isAppend(record) ? [text(record)] : []).join("");

async function viewing(t: TestContext, before = "hello\n", env: NodeJS.ProcessEnv = {}) {
  const aux = await mkdtemp(join(tmpdir(), "koa-job-view-test-"));
  t.after(() => rm(aux, { recursive: true, force: true }));
  const gate = join(aux, "gate");
  const output = join(aux, "before");
  await writeFile(output, before);
  const tools = [{ name: "async_bash", args: { command: `cat '${output}'; ${gatedCommand(gate, "", "bye\n", 1)}`, name: "one" } }];
  const app = await realFixture(t, { panes: [selfPane()], replies: [{ tools }, { text: "started" }], env: { KO_RUNTIME: "", ...env } });
  await app.post("prompt", { text: "run a job", mode: "prompt", attachments: [] });
  const statuses = async () => (await app.apiCalls()).filter(call => call.path === "/panes/pane_1/status").map(call => { const body: { id: string; state?: string; selection?: string } = JSON.parse(call.body); return body; });
  await pollUntil(async () => (await statuses()).some(r => r.id.startsWith("jobs/")), 10000, "the job record");
  const record = (await statuses()).find(r => r.id.startsWith("jobs/"))?.id ?? "";
  const id = record.slice("jobs/".length);
  let seq = 0;
  const select = (target: string) => app.feed({ id: `select-${++seq}-xxxxxx`, kind: "select", text: target });
  const close = (target: string) => app.feed({ id: `close-${++seq}-xxxxxx`, kind: "close", text: target });
  const states = () => app.records().filter(ofType("state"));
  return { app, aux, gate, record, id, select, close, statuses, states, release: () => writeFile(gate, "") };
}

test("selecting a job record shows the job: its state, then its tail, with no float", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  await f.select(f.record);
  const state = await f.app.until(ofType("state", record => record.view.type === "job"));
  assert.equal(state.view.id, f.id);
  assert.deepEqual(state.view.path.map(entry => [entry.type, entry.name]).at(-1), ["job", "one"]);
  assert.equal(state.view.path.length, 2);
  assert.equal(state.view.path[0]?.type, "agent");
  assert.ok(state.view.type === "job");
  assert.equal(state.view.job.name, "one");
  assert.equal(state.view.job.state.type, "running");
  const reset = await f.app.until(isReset);
  assert.equal(reset.view, f.id);
  assert.equal(reset.start, 0);
  await pollUntil(() => received(f.app.records()) === "hello\n", 5000, "the output arrives");
  assert.equal((await f.app.apiCalls()).some(call => call.method === "PUT" && call.path === "/layout"), false);
  assert.equal(JSON.stringify(f.app.records()).includes('"type":"focus"'), false);
  const before = f.app.count();
  await f.select(f.record);
  await f.select("");
  await f.app.until(ofType("state", record => record.view.type === "agent" && f.app.records().indexOf(record) > f.app.records().indexOf(state)));
  assert.equal(f.app.records().slice(before).filter(isReset).length, 0);
});

test("output after the open arrives as appends with absolute offsets, and the end follows it in place", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  await f.select(f.record);
  const reset = await f.app.until(isReset);
  await pollUntil(() => received(f.app.records()) === "hello\n", 5000, "the output arrives");
  await f.release();
  const ended = await f.app.until(ofType("state", record => record.view.type === "job" && record.view.job.state.type === "ended"));
  const append = f.app.records().filter(isAppend).at(-1);
  assert.ok(append);
  assert.deepEqual([append.epoch, append.view, append.start, text(append)], [reset.epoch, f.id, 6, "bye\n"]);
  assert.ok(f.app.records().indexOf(append) < f.app.records().indexOf(ended));
  assert.ok(ended.view.type === "job" && ended.view.job.state.type === "ended" && ended.view.job.state.end.type === "exit");
});

test("output of a job that does not stream still reaches the viewer, and earlier history reads the log", { timeout: 30000 }, async t => {
  const f = await viewing(t, "x".repeat(70000) + "\n");
  await f.release();
  await pollUntil(async () => (await f.statuses()).some(r => r.id === f.record && r.state === "error"), 10000, "the job ends");
  await f.select(f.record);
  const reset = await f.app.until(isReset);
  assert.equal(reset.end, 70005);
  assert.equal(reset.end - reset.start, 65536);
  const response = await f.app.post("job/earlier", { id: f.id, epoch: reset.epoch, before: reset.start });
  assert.equal(response.status, 200);
  const chunk: { start: number; end: number; data: string } = await response.json();
  assert.deepEqual([chunk.start, chunk.end], [0, reset.start]);
  assert.equal((await f.app.post("job/earlier", { id: f.id, epoch: "stale", before: 5 })).status, 409);
});

test("Stop ends the job in place and Clear leaves the view and removes the record", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  await f.select(f.record);
  await f.app.until(isReset);
  assert.equal((await f.app.post("job/stop", { id: f.id })).status, 200);
  await f.app.until(ofType("state", record => record.view.type === "job" && record.view.job.state.type === "ended" && record.view.job.state.end.type === "stopped"));
  assert.equal((await f.app.post("job/clear", { id: f.id })).status, 200);
  await f.app.until(ofType("state", record => record.view.type === "agent" && f.states().filter(s => s.view.type === "job").length > 0));
  await pollUntil(async () => (await f.app.apiCalls()).some(call => call.path === "/panes/pane_1/status" && call.body.includes('"clear"') && call.body.includes(f.id)), 5000, "the record is cleared");
});

test("a job view takes no agent action: abort and prompts are refused, and a view switch returns to the agent", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  await f.select(f.record);
  await f.app.until(isReset);
  assert.equal((await f.app.post("abort")).status, 409);
  assert.equal((await f.app.post("prompt", { text: "hi", mode: "prompt", attachments: [] })).status, 409);
  const self = f.states().at(0)?.view.id ?? "";
  assert.equal((await f.app.post("view", { id: self })).status, 200);
  await f.app.until(ofType("state", record => record.view.type === "agent" && f.app.records().indexOf(record) > f.app.records().findIndex(isReset)));
  assert.equal((await f.app.post("view", { id: f.id })).status, 200);
  await pollUntil(async () => f.app.records().filter(isReset).length === 2, 5000, "the job opens again");
});

test("an external clear keeps the open view as cleared", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  await f.release();
  await pollUntil(async () => (await f.statuses()).some(r => r.id === f.record && r.state === "error"), 10000, "the job ends");
  await f.select(f.record);
  await f.app.until(isReset);
  await f.close(f.record);
  const cleared = await f.app.until(ofType("state", record => record.view.type === "job" && record.view.job.state.type === "cleared"));
  assert.equal(cleared.view.id, f.id);
  await pollUntil(async () => /\\"clear\\"/.test(await readFile(join(f.app.dir, "api-log"), "utf8")), 5000, "the record is cleared");
});

test("a reconnect with a byte cursor catches up from the log in bounded steps and then from the tail, without a gap", { timeout: 30000 }, async t => {
  const f = await viewing(t, "y".repeat(200000) + "\n");
  await f.release();
  await pollUntil(async () => (await f.statuses()).some(r => r.id === f.record && r.state === "error"), 10000, "the job ends");
  await f.select(f.record);
  const reset = await f.app.until(isReset);
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(f.app.base + `events?epoch=${encodeURIComponent(reset.epoch)}&after=0`, { signal: controller.signal });
  assert.ok(response.body);
  const resumed = sse(Readable.from(response.body));
  await pollUntil(() => resumed.state.records.filter(isAppend).reduce((end, record) => record.start === end ? end + Buffer.from(record.data, "base64").length : end, 0) === reset.end, 5000, "every byte arrives in order");
  const appends = resumed.state.records.filter(isAppend);
  assert.equal(appends.some(record => Buffer.from(record.data, "base64").length > 262144), false);
  assert.ok(appends.length >= 2, "the older bytes come from disk, then the tail");
  assert.equal(resumed.state.records.some(isReset), false, "a matching epoch resumes and does not reset");
  const records = resumed.state.records;
  assert.ok(records.findIndex(record => record.type === "state") > records.findLastIndex(isAppend), "the state follows the catch-up output");
});

const cards = (records: PageRecord[]) => records.flatMap(record => record.type === "item" ? [record.item] : record.type === "reset" ? record.items : []).flatMap(item => item.kind === "assistant" ? item.blocks.flatMap(block => block.type === "tool" && block.job ? [block.job] : []) : []);

test("a card whose job left the registry opens a read-only view from its stored facts, and its open link goes once the log does", { timeout: 60000 }, async t => {
  const tools = Array.from({ length: 22 }, (_, i) => ({ name: "async_bash", args: { command: `echo hi-${i}`, name: `n${i}` } }));
  const app = await realFixture(t, { panes: [selfPane()], replies: [{ tools }, ...Array.from({ length: 40 }, () => ({ text: "ok" }))], env: { KO_RUNTIME: "" } });
  await app.post("prompt", { text: "run jobs", mode: "prompt", attachments: [] });
  const statuses = async () => (await app.apiCalls()).filter(call => call.path === "/panes/pane_1/status").map(call => { const body: { id: string; state?: string } = JSON.parse(call.body); return body; });
  await pollUntil(async () => new Set((await statuses()).filter(r => r.state === "done").map(r => r.id)).size === 22, 20000, "all jobs end");
  await pollUntil(() => app.records().filter(record => record.type === "item" && record.item.kind === "job" && record.item.event.type === "ended").length >= 22, 30000, "every job is announced, so the registry pruned the oldest");
  let first: ReturnType<typeof cards>[number] | undefined, state: Extract<PageRecord, { type: "state" }> | undefined;
  for (const card of cards(app.records())) {
    const after = app.count();
    assert.equal((await app.post("view", { id: card.id })).status, 200);
    const opened = await app.until(ofType("state", record => record.view.type === "job" && record.view.id === card.id), after);
    if (opened.view.type === "job" && opened.view.job.state.type === "cleared") { first = card; state = opened; break; }
  }
  assert.ok(first && state && state.view.type === "job", "a pruned job opens from its card");
  assert.deepEqual([state.view.job.command.startsWith("echo hi-"), state.view.job.log], [true, first.log]);
  const reset = await app.until(isReset, app.records().findIndex(record => record === state));
  assert.equal(text(reset), first.command.replace("echo ", "") + "\n");
  assert.equal((await app.post("job/stop", { id: first.id })).status, 409);
  const self = state.view.path[0]?.id ?? "";
  await rm(first.log);
  assert.equal((await app.post("view", { id: self })).status, 200);
  assert.equal((await app.post("view", { id: self })).status, 200);
  const window: { items: Extract<PageRecord, { type: "reset" }>["items"] } = await (await fetch(app.url("items?before=2"))).json();
  const shown = cards([{ type: "reset", epoch: "", more: false, items: window.items }]);
  assert.equal(shown.find(card => card.id === first.id)?.gone, true, "the card of the missing log has no open link");
  assert.equal(shown.filter(card => card.gone).length, 1);
  assert.equal((await app.post("view", { id: first.id })).status, 200);
  await app.until(ofType("job-gone", record => record.view === first.id));
});

test("a registry job whose log was deleted opens with the log is gone", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  await f.release();
  await pollUntil(async () => (await f.statuses()).some(r => r.id === f.record && r.state === "error"), 10000, "the job ends");
  await f.select(f.record);
  const state = await f.app.until(ofType("state", record => record.view.type === "job"));
  assert.ok(state.view.type === "job");
  const self = state.view.path[0]?.id ?? "";
  assert.equal((await f.app.post("view", { id: self })).status, 200);
  await rm(state.view.job.log);
  const after = f.app.count();
  assert.equal((await f.app.post("view", { id: f.id })).status, 200);
  await f.app.until(ofType("job-gone", record => record.view === f.id), after);
});
