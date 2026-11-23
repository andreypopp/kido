import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { CompletionContext } from './completion-context.ts';
import type { Routes } from './page/http.ts';
import { appendFile, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { selfPane, pollUntil, ofType } from "./koa-agent-fixture.ts";
import { realFixture, linkFakeKo } from "./koa-program-fixture.ts";

const keepFailedPath = 's=$?; if [ "$s" -ne 0 ] && [ "$s" -le 128 ]; then printf \'{"close":"keep"}\' | "$k" api -X PATCH --input - "/panes/$KO_PANE" >/dev/null; fi; exit "$s"';

const f_notified = (app: Awaited<ReturnType<typeof realFixture>>, text: string) => app.until(ofType("item", record => record.item.kind === "notify" && record.item.text.text === text));

async function editing(t: TestContext, env: NodeJS.ProcessEnv = {}, args: string[] = []) {
  const dir = await mkdtemp(join(tmpdir(), "koa-editor-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const panes = join(dir, "panes.json"), feed = join(dir, "feed"), apiLog = join(dir, "api");
  await linkFakeKo(dir);
  await writeFile(panes, JSON.stringify([selfPane()]));
  await writeFile(feed, "");
  const app = await realFixture(t, { replies: [], args, env: { KO_PANE: "pane_1", KO_SOCKET: "", KO_PANE_TOKEN: "", KO_RUNTIME: "", KO_FAKE_PANES: panes, KO_FAKE_CLIENT_FEED: feed, KO_FAKE_API_LOG: apiLog, KO_FAKE_INSTANCE: "a".repeat(32), KO_FAKE_CLIENT_DROP: join(dir, "client-drop"), KO_FAKE_PUT_STALE: join(dir, "stale"), ...(env.KO_FAKE_PUT_GATE === "gate" ? { KO_FAKE_PUT_GATE: join(dir, "put-gate") } : {}), VISUAL: "", EDITOR: "myeditor --flag", PATH: `${dir}:${process.env.PATH}`, ...env, ...(env.KO_FAKE_PUT_GATE === "gate" ? { KO_FAKE_PUT_GATE: join(dir, "put-gate") } : {}) } });
  const api = async () => (await readFile(apiLog, "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map(line => { const call: { method: string; path: string; body: string } = JSON.parse(line); return call; });
  const rows = async (): Promise<{ id: string; command?: string[]; parent?: string; runtime?: string; cwd?: string; close?: string; fixed_title?: string; close_confirm?: string; float?: { cols: number; rows: number; x: number; y: number; border: boolean } }[]> => JSON.parse(await readFile(panes, "utf8"));
  const float = async () => {
    const row = (await rows()).find(row => row.float);
    assert.ok(row?.command);
    return { ...row, command: row.command, file: row.command.at(-1) ?? "" };
  };
  const open = async (text: string) => { const response = await app.post("editor/open", { text }); return { status: response.status, body: await response.json() }; };
  const path = async (text: string, context: CompletionContext = { type: 'host', cwd: app.cwd }): Promise<Routes['/editor/path']['response']> => {
    const { stdout } = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', `import { openPathEditor } from ${JSON.stringify(new URL('./koa-editor.ts', import.meta.url).href)}; console.log(JSON.stringify(await openPathEditor(process.argv[1], JSON.parse(process.argv[2]), process.argv[3], 'pane_1', () => true)));`, text, JSON.stringify(context), app.agentDir], { env: { ...process.env, KO_PANE: 'pane_1', KO_SOCKET: '', KO_PANE_TOKEN: '', KO_RUNTIME: '', KO_FAKE_PANES: panes, KO_FAKE_API_LOG: apiLog, ...env, PATH: `${dir}:${process.env.PATH}`, VISUAL: '', EDITOR: 'myeditor --flag' }, timeout: 10000 });
    return JSON.parse(stdout);
  };
  const dead = (pane: string, cause: object) => appendFile(feed, JSON.stringify({ type: "dead", pane, dead: { at: 1, cause } }) + "\n");
  const closed = (pane: string) => pollUntil(async () => (await api()).some(call => call.method === "DELETE" && call.path === `/panes/${pane}`) && !(await rows()).some(row => row.id === pane), 5000, "the float is deleted");
  const sent = (method: string) => pollUntil(async () => (await api()).some(call => call.method === method), 5000, `a ${method} reaches ko`);
  const reopen = async (text: string) => { let last = await open(text); await pollUntil(async () => { if (last.body.error === "The editor is busy") last = await open(text); return last.body.error !== "The editor is busy"; }, 5000, "the editor is idle"); return last; };
  const notified = (text: string) => f_notified(app, text);
  const gone = (path: string) => pollUntil(() => stat(path).then(() => false, () => true), 5000, `${path} is removed`);
  return { dir, app, api, rows, float, open, path, dead, closed, gone, sent, reopen, notified, panes, gate: join(dir, "put-gate") };
}

test('a routed path uses the runtime editor, home and cwd and opens a runtime pane', { timeout: 15000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'koa-path-runtime-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const runtimes = join(dir, 'runtimes.json'), log = join(dir, 'exec-log');
  await writeFile(join(dir, 'review.ts'), 'runtime');
  await writeFile(runtimes, JSON.stringify({ dev: { cwd: dir, env: { HOME: dir, EDITOR: '/bin/nvim -u NONE' } } }));
  const f = await editing(t, { KO_SOCKET: join(dir, 'socket'), KO_FAKE_RUNTIMES: runtimes, KO_FAKE_EXEC_LOG: log }, ['--runtime', 'dev']);
  const result = await f.path('~/review.ts:12:3', { type: 'runtime', name: 'dev', cwd: dir });
  assert.equal(result.type, 'opened', JSON.stringify({ result, calls: await f.api(), exec: await readFile(log, 'utf8').catch(() => '') }));
  assert.equal(result.type, 'opened');
  if (result.type !== 'opened') return;
  const row = (await f.rows()).find(row => row.id === result.pane);
  assert.equal(row?.runtime, 'dev');
  assert.equal(row?.cwd, undefined);
  assert.deepEqual(row?.command, ['sh', '-c', 's=$1; shift; exec sh -lc "$s" sh "$(command -v ko)" "$@"', 'sh', 'k=$1; cd -- "$2" && { shift 2; ${EDITOR:-vi} "$@"; }; ' + keepFailedPath, dir, '+12', join(dir, 'review.ts')]);
  assert.equal(row?.fixed_title, '~/review.ts:12:3');
  const execs: { request: { argv: string[] } }[] = (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.equal(execs.filter(call => call.request.argv.includes('~/review.ts')).length, 1);
  await writeFile(runtimes, JSON.stringify({ dev: { cwd: dir, state: { type: 'failed', message: 'offline' } } }));
  const failed = await f.path('~/review.ts', { type: 'runtime', name: 'dev', cwd: dir });
  assert.deepEqual(failed, { type: 'warning', text: '~/review.ts: the runtime is not up' });
  assert.equal((await f.rows()).filter(row => row.float).length, 1);
});

test('each path click opens a new float beside the draft; missing paths warn and directories open', { timeout: 15000 }, async t => {
  const f = await editing(t);
  const file = join(f.app.cwd, 'review.ts');
  await writeFile(file, 'review');
  const open = f.path;
  const browser = await f.app.post('editor/path', { text: 'review.ts' });
  assert.deepEqual(await browser.json(), { type: 'warning', text: 'review.ts: cannot open an editor here' });
  assert.equal((await f.rows()).filter(row => row.float).length, 0);
  await f.open('draft stays');
  const draft = await f.float();
  const first = await open('review.ts:12:3'), second = await open('review.ts:12:3');
  assert.equal(first.type, 'opened'); assert.equal(second.type, 'opened');
  if (first.type !== 'opened' || second.type !== 'opened') return;
  assert.notEqual(first.pane, second.pane);
  for (const id of [first.pane, second.pane]) {
    const row = (await f.rows()).find(row => row.id === id);
    assert.deepEqual(row?.command, [join(f.dir, 'ko'), 'shell', '--', 'sh', '-c', 'k=$1; shift; "$@"; ' + keepFailedPath, 'sh', join(f.dir, 'ko'), 'myeditor', '--flag', file]);
    assert.equal(row?.fixed_title, 'review.ts:12:3');
    assert.equal(row?.parent, 'pane_1'); assert.equal(row?.close, 'exit'); assert.equal(row?.close_confirm, 'never');
  }
  assert.ok((await f.rows()).some(row => row.id === draft.id));
  assert.equal(await readFile(draft.file, 'utf8'), 'draft stays');
  assert.deepEqual(await open('missing.ts'), { type: 'warning', text: 'missing.ts: no such file' });
  assert.equal((await f.rows()).filter(row => row.float).length, 3);
  const directory = await open('./');
  assert.equal(directory.type, 'opened');
  if (directory.type !== 'opened') return;
  assert.equal((await f.rows()).find(row => row.id === directory.pane)?.command?.at(-1), f.app.cwd);
});

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
  assert.equal(pane.fixed_title, "Draft for @koa");
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
  assert.equal(f.app.provider.requests.length, 0);
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
  assert.equal((await f.reopen("same")).status, 200);
  pane = await f.float(); file = pane.file;
  assert.notEqual(pane.id, first);
  await writeFile(file, "same\n");
  await f.dead(pane.id, { type: "exited", code: 0 });
  await f.closed(pane.id); await f.gone(dirname(file));
  assert.equal(f.app.records().filter(record => record.type === "item" && record.item.kind === "notify" && record.item.text.text === "Editor exited 3; draft kept").length, 1);
  assert.equal(f.app.records().some(record => record.type === "state" && record.editor), false);
});

test("an open while the float's delete is still in flight is busy, and works once it is done", { timeout: 15000 }, async t => {
  const gate = join(await mkdtemp(join(tmpdir(), "koa-delete-gate-")), "gate");
  t.after(() => rm(dirname(gate), { recursive: true, force: true }));
  const f = await editing(t, { KO_FAKE_DELETE_DONE_GATE: gate });
  await f.open("held");
  const pane = await f.float();
  await f.dead(pane.id, { type: "exited", code: 3 });
  await f.closed(pane.id); await f.gone(dirname(pane.file));
  assert.deepEqual(await f.open("early"), { status: 409, body: { error: "The editor is busy" } });
  await writeFile(gate, "");
  assert.equal((await f.reopen("late")).status, 200);
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
  const f = await editing(t, { KO_FAKE_PUT_GATE: "gate" });
  const opening = f.open("racing");
  await f.sent("PUT");
  assert.equal((await f.app.post("sessions/new")).status, 200);
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

test("two opens at once make one draft and one float", { timeout: 15000 }, async t => {
  const f = await editing(t);
  const [one, two] = await Promise.all([f.open("a"), f.open("b")]);
  assert.equal(one.status, 200);
  assert.ok(two.status === 409 || two.body.pane === one.body.pane);
  assert.equal((await f.api()).filter(call => call.method === "PUT").length, 1);
  assert.equal((await f.rows()).filter(row => row.float).length, 1);
});
