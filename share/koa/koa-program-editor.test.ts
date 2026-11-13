import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { appendFile, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { selfPane, pollUntil, ofType } from "./koa-agent-fixture.ts";
import { fixture, linkFakeKo } from "./koa-program-fixture.ts";

const f_notified = (app: Awaited<ReturnType<typeof fixture>>, text: string) => app.until(ofType("item", record => record.item.kind === "notify" && record.item.text.text === text));

async function editing(t: TestContext, env: NodeJS.ProcessEnv = {}, steps: object[] = []) {
  const dir = await mkdtemp(join(tmpdir(), "koa-editor-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const panes = join(dir, "panes.json"), feed = join(dir, "feed"), apiLog = join(dir, "api");
  await linkFakeKo(dir);
  await writeFile(panes, JSON.stringify([selfPane()]));
  await writeFile(feed, "");
  const app = await fixture(t, steps, { KO_PANE: "pane_1", KO_SOCKET: "", KO_PANE_TOKEN: "", KO_RUNTIME: "", KO_FAKE_PANES: panes, KO_FAKE_CLIENT_FEED: feed, KO_FAKE_API_LOG: apiLog, KO_FAKE_INSTANCE: "a".repeat(32), KO_FAKE_CLIENT_DROP: join(dir, "client-drop"), KO_FAKE_PUT_STALE: join(dir, "stale"), ...(env.KO_FAKE_PUT_GATE === "gate" ? { KO_FAKE_PUT_GATE: join(dir, "put-gate") } : {}), VISUAL: "", EDITOR: "myeditor --flag", PI_CODING_AGENT_DIR: join(dir, "agent"), PATH: `${dir}:${process.env.PATH}`, ...env, ...(env.KO_FAKE_PUT_GATE === "gate" ? { KO_FAKE_PUT_GATE: join(dir, "put-gate") } : {}) });
  const api = async () => (await readFile(apiLog, "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map(line => { const call: { method: string; path: string; body: string } = JSON.parse(line); return call; });
  const rows = async (): Promise<{ id: string; command?: string[]; parent?: string; close?: string; fixed_title?: string; close_confirm?: string; float?: { cols: number; rows: number; x: number; y: number; border: boolean } }[]> => JSON.parse(await readFile(panes, "utf8"));
  const float = async () => {
    const row = (await rows()).find(row => row.float);
    assert.ok(row?.command);
    return { ...row, command: row.command, file: row.command.at(-1) ?? "" };
  };
  const open = async (text: string) => { const response = await app.post("editor/open", { text }); return { status: response.status, body: await response.json() }; };
  const dead = (pane: string, cause: object) => appendFile(feed, JSON.stringify({ type: "dead", pane, dead: { at: 1, cause } }) + "\n");
  const closed = (pane: string) => pollUntil(async () => (await api()).some(call => call.method === "DELETE" && call.path === `/panes/${pane}`) && !(await rows()).some(row => row.id === pane), 5000, "the float is deleted");
  const sent = (method: string) => pollUntil(async () => (await api()).some(call => call.method === method), 5000, `a ${method} reaches ko`);
  const notified = (text: string) => f_notified(app, text);
  const gone = (path: string) => pollUntil(() => stat(path).then(() => false, () => true), 5000, `${path} is removed`);
  return { dir, app, api, rows, float, open, dead, closed, gone, sent, notified, panes, gate: join(dir, "put-gate") };
}

test("an edit with exit 0 replaces the draft, does not send it and leaves nothing behind", { timeout: 15000 }, async t => {
  const f = await editing(t);
  const opened = await f.open("draft text");
  assert.equal(opened.status, 200);
  const pane = await f.float();
  assert.equal(opened.body.pane, pane.id);
  const file = pane.file;
  assert.deepEqual(pane.command, [join(f.dir, "ko"), "shell", "--", "myeditor", "--flag", file]);
  assert.equal(pane.parent, "pane_1");
  assert.equal(pane.close, "on_exit");
  assert.equal(pane.fixed_title, "Draft for @Fake pi");
  assert.equal(pane.close_confirm, "never");
  assert.deepEqual({ ...pane.float }, { x: 8, y: 2, cols: 64, rows: 19, z: 0, border: true, title: "" });
  assert.match(file, /koa-draft-pane_1\.md$/);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal((await stat(dirname(file))).mode & 0o777, 0o700);
  assert.equal(await readFile(file, "utf8"), "draft text");
  const editingState = await f.app.until(ofType("state", record => record.edit));
  assert.deepEqual(editingState.edit, { pane: pane.id, editor: "myeditor" });
  await writeFile(file, "edited text\n");
  await f.dead(pane.id, { type: "exited", code: 0 });
  const replaced = await f.app.until(ofType("state", record => record.editor?.text === "edited text"));
  assert.equal(replaced.edit, undefined);
  await f.closed(pane.id);
  await f.gone(dirname(file));
  assert.equal((await f.app.log()).some(record => record.type === "prompt"), false);
});

test("a failed or unchanged edit keeps the draft", { timeout: 15000 }, async t => {
  const f = await editing(t);
  await f.open("keep me");
  let pane = await f.float(), file = pane.file;
  await writeFile(file, "ignored");
  await f.dead(pane.id, { type: "exited", code: 3 });
  await f.notified("Editor exited 3; draft kept");
  await f.closed(pane.id); await f.gone(dirname(file));
  const first = pane.id;
  assert.equal((await f.open("same")).status, 200);
  pane = await f.float(); file = pane.file;
  assert.notEqual(pane.id, first);
  await writeFile(file, "same\n");
  await f.dead(pane.id, { type: "exited", code: 0 });
  await f.closed(pane.id); await f.gone(dirname(file));
  assert.equal(f.app.records().filter(record => record.type === "item" && record.item.kind === "notify" && record.item.text.text === "Editor exited 3; draft kept").length, 1);
  assert.equal(f.app.records().some(record => record.type === "state" && record.editor), false);
});

test("a second open reuses the float, and a stale revision is retried", { timeout: 15000 }, async t => {
  const f = await editing(t);
  await writeFile(join(f.dir, "stale"), "");
  const first = await f.open("one");
  assert.equal(first.status, 200);
  assert.deepEqual(await f.open("one"), { status: 200, body: first.body });
  assert.deepEqual((await f.api()).filter(call => call.method === "PUT").map(call => call.path), ["/layout", "/layout"]);
  assert.equal((await f.rows()).filter(row => row.float).length, 1);
});

test("a lost observer cancels the edit and cleans up", { timeout: 15000 }, async t => {
  const f = await editing(t);
  await f.open("lost");
  const pane = await f.float(), file = pane.file;
  await writeFile(join(f.dir, "client-drop"), "");
  await f.app.until(ofType("item", record => record.item.kind === "notify" && record.item.text.text === "Editor link lost; draft kept"));
  await f.closed(pane.id);
  await f.gone(dirname(file));
});

test("koa shutdown during an edit deletes the float and the draft", { timeout: 15000 }, async t => {
  const f = await editing(t);
  await f.open("bye");
  const pane = await f.float(), file = pane.file;
  await f.app.post("quit");
  await f.app.close;
  await f.closed(pane.id); await f.gone(dirname(file));
});

test("C-g is refused outside a ko pane, inside a runtime and for a stale session", { timeout: 15000 }, async t => {
  const browser = await editing(t, { KO_PANE: "" });
  assert.deepEqual(await browser.open("x"), { status: 409, body: { error: "C-g needs a ko pane" } });
  const runtime = await editing(t, { KO_RUNTIME: "box" });
  assert.equal((await runtime.open("x")).status, 409);
  assert.equal((await runtime.api()).some(call => call.method === "PUT"), false);
  const stale = await editing(t);
  const response = await stale.app.post("editor/open", { sessionId: "old", text: "x" });
  assert.equal(response.status, 409);
  assert.equal((await stale.api()).some(call => call.method === "PUT"), false);
});

test("a dead event that precedes the open ends the edit at once", { timeout: 15000 }, async t => {
  const f = await editing(t);
  await f.dead("pane_10", { type: "exited", code: 4 });
  await f.open("early");
  await f.app.until(ofType("item", record => record.item.kind === "notify" && record.item.text.text === "Editor exited 4; draft kept"));
  await f.closed("pane_10");
});

test("a float removed without an exit is a cancelled edit: the draft is as before, one info notice", { timeout: 15000 }, async t => {
  const f = await editing(t);
  await f.open("kept");
  const pane = await f.float();
  await writeFile(pane.file, "typed in the editor\n");
  await writeFile(f.panes, JSON.stringify((await f.rows()).filter(row => row.id !== pane.id)));
  await f.notified("editor closed · the draft is as before");
  await f.closed(pane.id); await f.gone(dirname(pane.file));
  const notices = f.app.records().flatMap(record => record.type === "item" && record.item.kind === "notify" ? [[record.item.level, record.item.text.text]] : []);
  assert.deepEqual(notices, [["info", "editor closed · the draft is as before"]]);
  assert.equal(f.app.records().some(record => record.type === "state" && record.editor), false, "no replacement text");
});

test("a refused delete of the float gives a notice", { timeout: 15000 }, async t => {
  const f = await editing(t, { KO_FAKE_DELETE_FAIL: "busy" });
  await f.open("same");
  const pane = await f.float();
  await f.dead(pane.id, { type: "exited", code: 0 });
  await f.notified("Editor pane not closed: busy");
  await f.gone(dirname(pane.file));
});

test("koa shutdown while the float is being placed deletes the float that the placement made", { timeout: 15000 }, async t => {
  const f = await editing(t, { KO_FAKE_PUT_GATE: "gate" });
  const opening = f.open("racing").catch(() => undefined);
  await f.sent("PUT");
  const put = (await f.api()).find(call => call.method === "PUT");
  const dir = /(\/[^"\\]*koa-editor-[^"\\/]*)\/koa-draft/.exec(put?.body ?? "")?.[1];
  assert.ok(dir);
  await f.app.post("quit");
  await writeFile(f.gate, "");
  await opening;
  await f.app.close;
  await f.closed("pane_10");
  await f.gone(dir);
});

test("a session change while the float is being placed cancels the edit", { timeout: 15000 }, async t => {
  const f = await editing(t, { KO_FAKE_PUT_GATE: "gate", KOA_FAKE_SESSIONS: JSON.stringify([{ path: "/tmp/chosen.jsonl" }]) }, [
    { type: "wait", command: "switch_session", data: { cancelled: false } },
    { type: "respond", command: "get_state", data: { sessionId: "chosen", sessionName: "Chosen" } },
    { type: "respond", command: "get_messages", data: { messages: [] } },
  ]);
  const opening = f.open("racing");
  await f.sent("PUT");
  assert.equal((await f.app.post("sessions/switch", { path: "/tmp/chosen.jsonl" })).status, 200);
  await writeFile(f.gate, "");
  assert.equal((await opening).status, 409);
  await f.closed("pane_10");
  assert.equal(f.app.records().some(record => record.type === "state" && record.edit), false);
});

test("an observer lost while the float is being placed deletes the float", { timeout: 15000 }, async t => {
  const f = await editing(t, { KO_FAKE_PUT_GATE: "gate" });
  const opening = f.open("racing");
  await f.sent("PUT");
  await writeFile(join(f.dir, "client-drop"), "");
  await pollUntil(async () => !(await stat(join(f.dir, "client-drop")).then(() => true, () => false)), 5000, "the observer ends");
  await writeFile(f.gate, "");
  assert.deepEqual(await opening, { status: 409, body: { error: "Editor link lost" } });
  await f.closed("pane_10");
});
