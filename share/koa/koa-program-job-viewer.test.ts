import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { selfPane, pollUntil, gatedCommand } from "./koa-agent-fixture.ts";
import { realFixture } from "./koa-program-fixture.ts";

const execFileAsync = promisify(execFile);
type Row = { id: string; command?: string[]; parent?: string; close?: string; fixed_title?: string; close_confirm?: string; float?: object };

async function viewing(t: TestContext, env: NodeJS.ProcessEnv = {}) {
  const aux = await mkdtemp(join(tmpdir(), "koa-viewer-test-"));
  t.after(() => rm(aux, { recursive: true, force: true }));
  const feed = join(aux, "client-feed");
  await writeFile(feed, "");
  const gated = (name: string) => env[name] === "gate" ? join(aux, name) : "";
  const gates = { one: join(aux, "one"), two: join(aux, "two") };
  const tools = [{ name: "async_bash", args: { command: gatedCommand(gates.one), name: "one" } }, { name: "async_bash", args: { command: gatedCommand(gates.two), name: "two" } }];
  const app = await realFixture(t, { panes: [selfPane()], replies: [{ tools }, { text: "started" }], env: { KO_RUNTIME: "", KO_FAKE_CLIENT_FEED: feed, KO_FAKE_CLIENT_FED: join(aux, "fed"), KO_FAKE_CLIENT_LAYOUTS: join(aux, "layouts"), KO_FAKE_INSTANCE: "a".repeat(32), ...env, KO_FAKE_PUT_GATE: gated("KO_FAKE_PUT_GATE"), KO_FAKE_PUT_DONE_GATE: gated("KO_FAKE_PUT_DONE_GATE"), KO_FAKE_DELETE_GATE: gated("KO_FAKE_DELETE_GATE") } });
  const api = async () => (await app.apiCalls());
  const statuses = async () => (await api()).filter(call => call.path === "/panes/pane_1/status").map(call => { const body: { id: string; state?: string; selection?: string; closeable?: boolean } = JSON.parse(call.body); return body; });
  const rows = async (): Promise<Row[]> => JSON.parse(await readFile(join(app.dir, "panes.json"), "utf8"));
  const floats = async () => (await rows()).filter(row => row.float);
  await app.post("prompt", { text: "run jobs", mode: "prompt", attachments: [] });
  await pollUntil(async () => new Set((await statuses()).map(r => r.id).filter(id => id.startsWith("jobs/"))).size === 2, 10000, "both job records");
  const ids = [...new Set((await statuses()).map(r => r.id).filter(id => id.startsWith("jobs/")))];
  assert.equal(ids.length, 2);
  let seq = 0;
  const select = (id: string) => app.feed({ id: `select-${++seq}-xxxxxx`, kind: "select", text: id });
  const close = (id: string) => app.feed({ id: `close-${++seq}-xxxxxx`, kind: "close", text: id });
  const focused = () => app.records().filter(record => record.type === "focus").map(record => record.pane);
  const dead = (pane: string) => appendFile(feed, JSON.stringify({ type: "dead", pane, dead: { at: 1, cause: { type: "exited", code: 0 } } }) + "\n");
  const deleted = (pane: string) => pollUntil(async () => (await api()).some(call => call.method === "DELETE" && call.path === `/panes/${pane}`), 5000, `${pane} is deleted`);
  const lines = async (name: string) => (await readFile(join(aux, name), "utf8").catch(() => "")).split("\n").filter(Boolean);
  const release = (name: string) => writeFile(join(aux, name), "");
  return { app, aux, gates, ids, select, close, focused, dead, deleted, api, statuses, floats, rows, lines, release };
}

test("concurrent selects open one viewer, reuse focuses it, and job completion keeps it", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  const [first, second] = f.ids;
  assert.ok(first && second);
  await Promise.all([f.select(first), f.select(first)]);
  await pollUntil(() => f.focused().length === 2, 5000, "a focus for each select");
  assert.deepEqual(f.focused(), ["pane_10", "pane_10"]);
  assert.equal((await f.api()).filter(call => call.method === "PUT" && call.path === "/layout").length, 1);
  const [float] = await f.floats();
  assert.ok(float?.command);
  assert.deepEqual(float.command.slice(1, 5), ["shell", "--", "less", "-R"]);
  assert.equal(float.command[5], "+F");
  assert.match(float.command[6] ?? "", /\.log$/);
  assert.equal(float.parent, "pane_1");
  assert.equal(float.close, "on_exit");
  assert.equal(float.close_confirm, "never");
  assert.match(float.fixed_title ?? "", /^Job · (one|two)$/);
  const title = float.fixed_title;
  const firstName = title === "Job · one" ? "one" : "two";
  await writeFile(f.gates[firstName], "");
  await pollUntil(async () => (await f.statuses()).some(r => r.id === first && r.state === "done"), 5000, "the job ends");
  assert.equal((await f.api()).some(call => call.method === "DELETE"), false, "the viewer outlives its job");
  await f.select(second);
  await pollUntil(async () => (await f.floats()).length === 2, 5000, "a second viewer for the second job");
  await pollUntil(() => f.focused().length === 3, 5000, "a focus for the second viewer");
  assert.deepEqual(f.focused().slice(2), ["pane_11"]);
  await f.dead("pane_10");
  await f.deleted("pane_10");
  await f.select(first);
  await pollUntil(() => f.focused().length === 4, 5000, "the job has a viewer again");
  assert.equal(f.focused()[3], "pane_12");
});

test("a death that the observer delivered before the placement returns ends the viewer", { timeout: 30000 }, async t => {
  const f = await viewing(t, { KO_FAKE_PUT_GATE: "gate" });
  await f.select(f.ids[0] ?? "");
  await pollUntil(async () => (await f.api()).some(call => call.method === "PUT" && call.path === "/layout"), 5000, "the placement starts");
  await f.dead("pane_10");
  await pollUntil(async () => (await f.lines("fed")).some(line => line.includes('"dead"')), 5000, "the observer delivers the death");
  await f.release("KO_FAKE_PUT_GATE");
  await f.deleted("pane_10");
});

test("a float removed before the placement returns ends the viewer", { timeout: 30000 }, async t => {
  const f = await viewing(t, { KO_FAKE_PUT_DONE_GATE: "gate" });
  await f.select(f.ids[0] ?? "");
  await pollUntil(async () => (await f.lines("layouts")).some(line => line.includes("pane_10")), 5000, "the observer sees the new float");
  const before = (await f.lines("layouts")).length;
  await execFileAsync(join(f.app.dir, "ko"), ["api", "-X", "DELETE", "/panes/pane_10"], { env: { KO_FAKE_PANES: join(f.app.dir, "panes.json"), KO_FAKE_API_LOG: "" } });
  await pollUntil(async () => (await f.lines("layouts")).length > before, 5000, "the observer sees the float gone");
  await f.release("KO_FAKE_PUT_DONE_GATE");
  await f.deleted("pane_10");
});

test("koa shutdown waits for a viewer whose pane is being deleted", { timeout: 30000 }, async t => {
  const f = await viewing(t, { KO_FAKE_DELETE_GATE: "gate" });
  await f.select(f.ids[0] ?? "");
  await pollUntil(() => f.focused().length === 1, 5000, "the viewer opens");
  await f.dead("pane_10");
  await pollUntil(async () => (await f.api()).some(call => call.method === "DELETE" && call.path === "/panes/pane_10"), 5000, "the delete starts");
  await f.app.post("quit");
  const exited = await Promise.race([f.app.close.then(() => true), new Promise<boolean>(resolve => { setTimeout(resolve, 500, false); })]);
  assert.equal(exited, false, "koa waits for the delete");
  await f.release("KO_FAKE_DELETE_GATE");
  await f.app.close;
  assert.equal((await f.floats()).length, 0);
});

test("closing a running job record stops the job and a finished one clears it", { timeout: 30000 }, async t => {
  const f = await viewing(t);
  const [first] = f.ids;
  assert.ok(first);
  assert.ok((await f.statuses()).filter(r => r.id === first).every(r => r.selection === "offered" && r.closeable === true));
  await f.close(first);
  await pollUntil(async () => (await f.statuses()).some(r => r.id === first && r.state === "error"), 10000, "the stopped job ends");
  await f.close(first);
  await pollUntil(async () => (await f.api()).some(call => call.path === "/panes/pane_1/status" && call.body.includes('"clear"') && call.body.includes(first)), 5000, "the record is cleared");
});

