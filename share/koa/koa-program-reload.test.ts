import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, appendFile, rm, cp, symlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { Readable } from "node:stream";
import type { NotifyLevel } from "./koa-records.ts";
import { pollUntil, sse, ofType } from "./koa-agent-fixture.ts";
import { fixture } from "./koa-program-fixture.ts";

type App = Awaited<ReturnType<typeof fixture>>;
const state = (dir: string) => ({ type: "respond", command: "get_state", data: { sessionFile: join(dir, "session.jsonl") } });
const note = (level: NotifyLevel, text: string) => ofType("item", record => record.item.kind === "notify" && record.item.level === level && record.item.text.text === text);
const reload = (app: App) => app.post("prompt", { text: "/reload", mode: "prompt", attachments: [] });
const argvs = async (app: App) => (await app.log()).filter(row => row.type === "argv").length;
const instanceOf = async (base: string) => /name="koa-instance" content="([^"]+)"/.exec(await (await fetch(base)).text())?.[1];
const urls = (app: App) => [...app.stderr().matchAll(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/g)].flatMap(match => match[1] ?? []);

async function install(t: TestContext) {
  const dir = await mkdtemp("/tmp/koa-reload-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../../build/ko/share/ko/koa"), join(dir, "koa"), { recursive: true });
  await symlink(resolve("../../build/ko/share/ko/pi"), join(dir, "pi"));
  await symlink(resolve("../../build/ko/share/ko/webview"), join(dir, "webview"));
  return dir;
}
const update = async (dir: string) => writeFile(join(dir, "koa/page.html"), (await readFile(join(dir, "koa/page.html"), "utf8")).replace("<title>koa</title>", "<title>RELOADED-MARKER</title>"));
const restartState = (dir: string, value: object) => writeFile(join(dir, "restart-state"), JSON.stringify(value));

test("/reload with an unchanged install reloads pi in place and keeps koa", { timeout: 15000 }, async t => {
  const dir = await install(t);
  const commands = [{ name: "koa-reload", description: "Reload pi", source: "extension" }];
  const app = await fixture(t, [state(dir), { type: "respond", command: "get_commands", data: { commands } }], { KOA_FAKE_RESTART_FILE: join(dir, "restart-state") }, undefined, true, [], join(dir, "koa/koa.ts"));
  const instance = await instanceOf(app.base);
  assert.ok(instance);
  assert.deepEqual(await (await reload(app)).json(), { disposition: "handled", action: { type: "none" } });
  await app.until(note("info", "reloaded"));
  assert.equal((await app.log()).filter(row => row.type === "prompt" && row.message === "/koa-reload").length, 1);
  assert.equal(await argvs(app), 1);
  assert.equal((await app.log()).some(row => row.type === "restart_state"), false);
  assert.equal(await instanceOf(app.base), instance);
  assert.equal(urls(app).length, 1);
  const completion: { options: { label: string }[] } = await (await app.post("complete", { text: "/koa", pos: 4 })).json();
  assert.deepEqual(completion.options, []);
  assert.equal((await app.post("quit")).status, 200);
  assert.equal((await app.close)[0], 0);
});

test("/reload restarts koa in place on the same session with the new page", { timeout: 15000 }, async t => {
  const dir = await install(t);
  const app = await fixture(t, [state(dir)], {}, undefined, true, ["first message"], join(dir, "koa/koa.ts"));
  const before = await (await fetch(app.base)).text();
  const instance = /name="koa-instance" content="([^"]+)"/.exec(before)?.[1];
  assert.ok(instance);
  assert.doesNotMatch(before, /RELOADED-MARKER/);
  await update(dir);
  const answer = await reload(app);
  assert.deepEqual(await answer.json(), { disposition: "handled", action: { type: "reload" } });
  await pollUntil(() => urls(app).length === 2, 10000, "the restarted koa's URL");
  const base = urls(app)[1];
  assert.ok(base);
  await pollUntil(async () => (await app.log()).filter(row => row.type === "argv").length === 2, 5000, "the second pi");
  const second: string[] = (await app.log()).filter(row => row.type === "argv")[1].args;
  assert.equal(second[second.indexOf("--session") + 1], join(dir, "session.jsonl"));
  assert.equal(second.includes("--no-session"), false);
  assert.equal((await app.log()).filter(row => row.type === "prompt" && row.message !== "/koa-reload").length, 1);
  const after = await (await fetch(base)).text();
  assert.match(after, /RELOADED-MARKER/);
  assert.notEqual(/name="koa-instance" content="([^"]+)"/.exec(after)?.[1], instance);
  assert.equal(await (await fetch(base + "events?koa=" + instance)).text(), 'data: {"type":"reload"}\n\n');
  const events = new AbortController();
  t.after(() => events.abort());
  const response = await fetch(base + "events?koa=" + /name="koa-instance" content="([^"]+)"/.exec(after)?.[1], { signal: events.signal });
  assert.ok(response.body);
  const { state: stream, until } = sse(Readable.from(response.body));
  await until(record => record.type === "state" && Array.isArray(record.levels) && record.levels.length === 3);
  const reloaded = () => stream.records.flatMap(record => record.type === "reset" ? record.items : record.type === "item" ? [record.item] : []).filter(item => item.kind === "notify" && item.level === "info" && item.text.text === "reloaded");
  await pollUntil(() => reloaded().length > 0, 5000, "the reloaded note");
  assert.equal(reloaded().length, 1);
  assert.doesNotMatch(app.stderr(), /Warning/);
  assert.equal((await fetch(base + "quit", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 200);
  assert.equal((await app.close)[0], 0);
});

test("/reload restarts koa when only the agent extension changed", { timeout: 15000 }, async t => {
  const dir = await install(t);
  const app = await fixture(t, [state(dir)], {}, undefined, true, [], join(dir, "koa/koa.ts"));
  await appendFile(join(dir, "koa/koa-agent.ts"), "\n// changed\n");
  assert.deepEqual(await (await reload(app)).json(), { disposition: "handled", action: { type: "reload" } });
  await pollUntil(async () => (await app.log()).filter(row => row.type === "argv").length === 2, 10000, "the second pi");
  await pollUntil(() => urls(app).length === 2, 10000, "the restarted koa's URL");
  assert.equal((await fetch(urls(app)[1] + "quit", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 200);
  assert.equal((await app.close)[0], 0);
});

test("a newer koa waits while jobs or subagents run and restarts at the next /reload", { timeout: 15000 }, async t => {
  const dir = await install(t);
  const app = await fixture(t, [state(dir)], { KOA_FAKE_RESTART_FILE: join(dir, "restart-state") }, undefined, true, [], join(dir, "koa/koa.ts"));
  await update(dir);
  await restartState(dir, { type: "blocked", jobs: 3, children: 1 });
  assert.deepEqual(await (await reload(app)).json(), { disposition: "handled", action: { type: "none" } });
  await app.until(note("info", "reloaded · a newer koa waits for 3 jobs"));
  await restartState(dir, { type: "blocked", jobs: 0, children: 1 });
  await reload(app);
  await app.until(note("info", "reloaded · a newer koa waits for 1 subagent to report"));
  assert.equal(await argvs(app), 1);
  assert.equal(urls(app).length, 1);
  await restartState(dir, { type: "ready" });
  assert.deepEqual(await (await reload(app)).json(), { disposition: "handled", action: { type: "reload" } });
  await pollUntil(() => urls(app).length === 2, 10000, "the restarted koa's URL");
  const restarted = urls(app)[1];
  assert.ok(restarted);
  assert.equal((await fetch(restarted + "quit", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 200);
  assert.equal((await app.close)[0], 0);
});

test("a newer koa needs a saved session, and pi still reloads", { timeout: 10000 }, async t => {
  const dir = await install(t);
  const app = await fixture(t, [], {}, undefined, true, [], join(dir, "koa/koa.ts"));
  await update(dir);
  await reload(app);
  await app.until(note("info", "reloaded · a newer koa needs a saved session"));
  assert.equal((await app.log()).filter(row => row.type === "prompt" && row.message === "/koa-reload").length, 1);
  assert.equal(await argvs(app), 1);
});

test("/reload is refused while a turn runs", { timeout: 10000 }, async t => {
  const dir = await mkdtemp("/tmp/koa-reload-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  const app = await fixture(t, [state(dir), { type: "wait", command: "prompt", events: [{ type: "agent_start" }] }], {}, undefined, true, [], resolve("../../build/ko/share/ko/koa/koa.ts"));
  await app.post("prompt", { text: "work", mode: "prompt", attachments: [] });
  await app.until(ofType("state", record => record.working === true));
  assert.deepEqual(await (await reload(app)).json(), { disposition: "handled", action: { type: "none" } });
  await app.until(note("warning", "reload: not while a turn, a command, a queue, a dialog or an editor is open"));
  assert.equal(await argvs(app), 1);
  assert.equal((await app.log()).some(row => row.type === "prompt" && row.message === "/koa-reload"), false);
});

test("a turn that starts during /reload stays visible and blocks the restart", { timeout: 10000 }, async t => {
  const dir = await install(t);
  const app = await fixture(t, [state(dir)], { KOA_FAKE_RELOAD_TURN: "1" }, undefined, true, [], join(dir, "koa/koa.ts"));
  await update(dir);
  assert.deepEqual(await (await reload(app)).json(), { disposition: "handled", action: { type: "none" } });
  await app.until(ofType("state", record => record.working === true && record.pi.type === "ready"));
  const turn = () => app.records().flatMap(record => record.type === "reset" ? record.items : record.type === "item" ? [record.item] : []).filter(item => item.kind === "user" && item.text === "queued before reload");
  await pollUntil(() => turn().length > 0, 5000, "the turn's user message");
  await app.until(note("info", "reloaded"));
  assert.equal(await argvs(app), 1);
  assert.equal(urls(app).length, 1);
});
