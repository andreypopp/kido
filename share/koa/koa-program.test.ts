import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir, cp, symlink, truncate } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, relative } from "node:path";
import { once } from "node:events";
import { createServer, connect } from "node:net";
import timers from "node:timers/promises";
import { Readable } from "node:stream";
import { assistant, sse, selfPane, agentPane, pollUntil } from "../pi/ko-pi-fixture.ts";

test("--help prints usage without starting pi or a webview", { timeout: 5000 }, async () => {
  const child = spawn(process.execPath, [resolve('../koa/koa.ts'), '--help', '--pi', '/does-not-exist'], { env: { PATH: '' }, stdio: 'pipe' });
  let stdout = '', stderr = '';
  child.stdout.on('data', bytes => { stdout += bytes; });
  child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'close');
  assert.equal(code, 0, stderr);
  assert.equal(stderr, '');
  assert.match(stdout, /Usage: koa/);
  assert.match(stdout, /--browser/);
  assert.match(stdout, /Other arguments go to pi/);
});

async function fixture(t: TestContext, steps: object[], env: NodeJS.ProcessEnv = {}, pi?: string, startup = true, args: string[] = [], program = resolve("../../build/ko/share/ko/koa/koa.ts")) {
  const dir = await mkdtemp(join(tmpdir(), "koa-test-"));
  const script = join(dir, "script");
  const log = join(dir, "log");
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  await writeFile(script, steps.map(value => JSON.stringify(value)).join("\n"));
  const child = spawn(process.execPath, [program, "--browser", "--pi", pi ?? resolve("../koa/koa-fake-pi.ts"), "--no-session", ...args], { env: { ...process.env, OPEN_LOG: join(dir, "urls"), KO_PANE: "", KOA_FAKE_SCRIPT: script, KOA_FAKE_LOG: log, KOA_PI_EXIT_MS: "30", ...env, PATH: `${dir}:${env.PATH ?? process.env.PATH}` }, stdio: "pipe" });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", bytes => { stdout += bytes; });
  let ready: (url: string) => void = () => {};
  const url = new Promise<string>(resolve => { ready = resolve; });
  child.stderr.on("data", bytes => { stderr += bytes; const match = stderr.match(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/); if (match?.[1]) ready(match[1]); });
  const close = once(child, "close");
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM"); await close; await rm(dir, { recursive: true, force: true }); });
  const base = await url;
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(base + "events", { signal: controller.signal });
  assert.ok(response.body);
  const { state: stream, until } = sse(Readable.from(response.body));
  const post = (path: string, body: object = {}) => fetch(base + path, { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (startup) await until(record => record.type === "state" && (pi ? record.pi?.type === "exited" : Array.isArray(record.levels) && record.levels.length === 3));
  return { post, until, records: () => stream.records, count: () => stream.records.length, close, stdout: () => stdout, stderr: () => stderr, log: async () => (await readFile(log, "utf8")).trim().split("\n").map(line => JSON.parse(line)), base };
}
test('startup failures release the view before exiting', { timeout: 5000 }, async t => {
  for (const args of [[], ['--metrics', '/does-not-exist/metrics']]) {
    const child = spawn(process.execPath, [resolve('../koa/koa.ts'), '--browser', ...args], { env: { ...process.env, ...(args.length ? {} : { KOA_UPLOAD_IDLE_MS: 'bad' }) }, stdio: 'pipe' });
    const close = once(child, 'close'); t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
    let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
    const [code] = await close; assert.equal(code, 1); assert.match(stderr, args.length ? /ENOENT/ : /KOA_UPLOAD_IDLE_MS/);
  }
});

test('a listen failure closes the acquired view and pi', { timeout: 5000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-listen-failure-'); t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../../build/ko/share/ko/koa'), join(dir, 'koa'), { recursive: true });
  await symlink(resolve('../../build/ko/share/ko/pi'), join(dir, 'pi'));
  await mkdir(join(dir, 'webview'));
  const marker = join(dir, 'socket');
  await writeFile(join(dir, 'webview/index.ts'), `import {webview as real} from ${JSON.stringify(new URL('../webview/index.ts', import.meta.url).href)};import {writeFileSync} from 'node:fs';export async function webview(options){const view=await real(options);writeFileSync(${JSON.stringify(marker)},view.socketPath);writeFileSync(view.socketPath,'occupied');return view;}`);
  const child = spawn(process.execPath, [join(dir, 'koa/koa.ts'), '--browser', '--pi', resolve('../koa/koa-fake-pi.ts')], { env: { ...process.env, KOA_PI_EXIT_MS: '30', KOA_FAKE_STUBBORN: '1' }, stdio: 'pipe' });
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'close'); assert.equal(code, 1); assert.match(stderr, /EADDRINUSE/);
  await assert.rejects(readFile(await readFile(marker, 'utf8')), { code: 'ENOENT' });
});

test('mutations refuse simple content types and browser path grants', { timeout: 10000 }, async t => {
  const app = await fixture(t, [], {}, undefined, true, [], resolve('../koa/koa.ts'));
  const before = (await app.log()).length;
  for (const path of ['abort', 'complete', 'attachments', 'attachments/absent/delete']) {
    assert.equal((await fetch(app.base + path, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
  }
  const grants: Record<string, string>[] = [{ 'Content-Type': 'application/json' }, { 'Content-Type': 'application/json', 'Kido-Native-Drop': '1' }];
  for (const headers of grants) {
    assert.equal((await fetch(app.base + 'attachments', { method: 'POST', headers, body: JSON.stringify({ path: '/etc/passwd' }) })).status, 403);
  }
  assert.equal((await app.log()).length, before);
});

test('step previews resolve only transcript-owned regular files', { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'koa-preview-')); t.after(() => rm(dir, { recursive: true, force: true }));
  await writeFile(join(dir, 'notes.md'), '# Preview'); await mkdir(join(dir, 'folder')); await symlink(join(dir, 'notes.md'), join(dir, 'link'));
  await writeFile(join(dir, 'huge'), ''); await truncate(join(dir, 'huge'), 65 * 1048576);
  const message = { ...assistant(''), content: ['notes.md', 'folder', 'missing', 'link', 'huge', 'notes.md', '~/notes.md', '@' + join(dir, 'notes.md')].map((path, i) => ({ type: 'toolCall', id: 'r' + i, name: i === 5 ? 'bash' : 'read', arguments: { path: i === 0 ? relative(process.cwd(), join(dir, path)) : i >= 6 ? path : join(dir, path) } })) };
  const app = await fixture(t, [{ type: 'wait', command: 'get_messages', data: { messages: [message] } }], { HOME: dir });
  const good = await fetch(app.base + 'steps/0/0/file'); assert.equal(good.status, 200); assert.equal(await good.text(), '# Preview'); assert.match(good.headers.get('content-disposition') ?? '', /notes.md/);
  for (const [path, status] of [['steps/0/1/file',403],['steps/0/2/file',404],['steps/0/3/file',403],['steps/0/4/file',413],['steps/0/5/file',404],['steps/0/6/file',200],['steps/0/7/file',200],['steps/0/8/file',404],['steps/0/0/file?path=/etc/passwd',404]]) assert.equal((await fetch(app.base + path)).status, status);
});

test('/name is a session command, with pi query and empty-name rules', { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: 'wait', command: 'set_session_name', events: [{ type: 'session_info_changed', name: 'test-koa' }] },
    { type: 'respond', command: 'get_state', data: { sessionName: 'test-koa' } },
    { type: 'wait', command: 'set_session_name', events: [{ type: 'session_info_changed', name: 'second' }] },
    { type: 'respond', command: 'get_state', data: {} },
  ]);
  await app.post('prompt', { text: '/name   test-koa  ', mode: 'prompt', attachments: [] });
  const commands = (await app.log()).filter(record => ['prompt', 'set_session_name'].includes(record.type));
  assert.deepEqual(commands.map(record => [record.type, record.name]), [['set_session_name', 'test-koa']]);
  await app.until(record => record.type === 'state' && record.name === 'test-koa');
  await app.until(record => record.type === 'item' && record.item.kind === 'notify' && record.item.text.text === 'Session name set: test-koa');
  assert.equal((await app.post('prompt', { text: '/name', mode: 'prompt', attachments: [] })).status, 200);
  await app.until(record => record.type === 'item' && record.item.kind === 'notify' && record.item.text.text === 'Session name: test-koa');
  await app.post('prompt', { text: ' /name second ', mode: 'prompt', attachments: ['unsent'] });
  await app.post('prompt', { text: '/name   ', mode: 'prompt', attachments: [] });
  await app.until(record => record.type === 'item' && record.item.kind === 'notify' && record.item.level === 'warning' && record.item.text.text === 'Usage: /name <name>');
  assert.equal(app.records().some(record => record.type === 'item' && record.item.kind !== 'notify'), false);
  await app.post('prompt', { text: '/names other', mode: 'prompt', attachments: [] });
  assert.deepEqual((await app.log()).filter(record => record.type === 'prompt').map(record => record.message), ['/names other']);
});

test("a sent copy survives a later queue take-back and removal", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', echo: true, events: [{ type: 'agent_start' }] },
    { type: 'wait', command: 'prompt', events: [{ type: 'queue_update', steering: ['again'], followUp: [] }] },
    { type: 'wait', command: 'clear_queue', events: [{ type: 'queue_update', steering: [], followUp: [] }], data: { steering: ['again'], followUp: [] } },
  ]);
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==', 'base64');
  const file = await (await app.post('attachments', { name: 'keep.png', type: 'image/png', size: bytes.length })).json();
  await fetch(app.base + `attachments/${file.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(bytes) });
  await app.post('prompt', { text: 'first', mode: 'prompt', attachments: [file.id] });
  await app.post('prompt', { text: 'again', mode: 'prompt', attachments: [file.id] });
  await app.post('queue/clear');
  assert.equal((await app.post(`attachments/${file.id}/delete`)).status, 409);
  assert.deepEqual(await readFile(file.path), bytes);
});

test('a queued image survives compaction and take-back', { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'koa-compaction-image-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'image.png');
  await writeFile(path, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==', 'base64'));
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', events: [{ type: 'agent_start' }] },
    { type: 'wait', command: 'prompt', events: [{ type: 'queue_update', steering: [''], followUp: [] }, { type: 'compaction_end' }] },
    { type: 'wait', command: 'clear_queue', data: { steering: [''], followUp: [] } },
  ]);
  await app.post('prompt', { text: 'go', mode: 'prompt', attachments: [] });
  const bytes = await readFile(path);
  const created = await (await app.post('attachments', { name: 'image.png', type: 'image/png', size: bytes.length })).json();
  const file = (await (await fetch(app.base + `attachments/${created.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(bytes) })).json()).attachment;
  const before = app.count();
  await app.post('prompt', { text: '', mode: 'prompt', attachments: [file.id] });
  await app.until(record => record.type === 'reset', before);
  assert.deepEqual(await (await app.post('queue/clear')).json(), { steering: [{ text: '', attachments: [file] }], followUp: [] });
});

test("queue take-back returns attachment chips with their typed text", { timeout: 10000 }, async t => {
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==', 'base64');
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [{ type: "agent_start" }] },
    { type: "wait", command: "prompt", events: [{ type: "queue_update", steering: ["Compare"], followUp: [] }] },
    { type: "wait", command: "clear_queue", events: [{ type: "queue_update", steering: [], followUp: [] }], data: { steering: ["Compare"], followUp: [] } },
  ]);
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
  const created = await (await app.post('attachments', { name: 'image.png', type: 'image/png', size: bytes.length })).json();
  const file = (await (await fetch(app.base + `attachments/${created.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(bytes) })).json()).attachment;
  await app.post("prompt", { text: "Compare", mode: "prompt", attachments: [file.id] });
  const restored = await (await app.post("queue/clear")).json();
  assert.deepEqual(restored, { steering: [{ text: "Compare", attachments: [file] }], followUp: [] });
});

test("attachments stream chunks into prompts", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-attachments-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const image = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==", "base64");
  const file = join(dir, "original.txt");
  await writeFile(file, "original");
  const app = await fixture(t, []);
  const created = await app.post("attachments", { name: "pixel.png", type: "text/html", size: image.length });
  assert.equal(created.status, 200);
  const uploaded = await created.json();
  const { id } = uploaded;
  const chunk = (offset: number, body: Uint8Array<ArrayBuffer>) => fetch(app.base + `attachments/${id}/${offset}`, { method: "POST", headers: { 'Content-Type': 'application/octet-stream' }, body });
  assert.equal((await chunk(1, image.subarray(0, 10))).status, 409);
  assert.deepEqual(await (await chunk(0, image.subarray(0, 10))).json(), { received: 10 });
  const done = await (await chunk(10, image.subarray(10))).json();
  assert.deepEqual(done, { received: image.length, attachment: { id, path: uploaded.path, origin: "upload", name: "pixel.png", size: image.length, kind: "image", mimeType: "image/png", width: 1, height: 1 } });
  const downloaded = await fetch(app.base + `attachments/${id}`);
  assert.equal(downloaded.headers.get("content-type"), "image/png");
  assert.match(downloaded.headers.get("content-disposition") ?? "", /pixel.png/);
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), image);
  assert.equal((await app.post("attachments", { path: file })).status, 403);
  assert.equal((await app.post("attachments", { name: "large", size: 64 * 1024 * 1024 + 1, type: "" })).status, 413);
  const copy = await (await app.post("attachments", { name: "copied.txt", type: "text/plain", size: 4 })).json();
  await fetch(app.base + `attachments/${copy.id}/0`, { method: "POST", headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(Buffer.from("copy")) });
  assert.equal((await app.post("prompt", { text: "Compare", mode: "prompt", attachments: [id, copy.id] })).status, 200);
  const sent = (await app.log()).find(record => record.type === "prompt");
  assert.deepEqual(sent.images, [{ type: "image", data: image.toString("base64"), mimeType: "image/png" }]);
  const lines = sent.message.split("\n");
  assert.equal(lines[0], "Compare");
  assert.equal(await readFile(lines.at(-1), "utf8"), "copy");
  assert.equal((await app.post("prompt", { text: "", mode: "prompt", attachments: [id] })).status, 200);
  const last = (await app.log()).filter(record => record.type === "prompt").at(-1);
  assert.equal(last.message, ""); assert.deepEqual(last.images, sent.images);
  const extra = await (await app.post("attachments", { name: 'extra', type: '', size: 0 })).json();
  assert.equal((await app.post(`attachments/${extra.id}/delete`)).status, 200);
  assert.equal((await fetch(app.base + `attachments/${extra.id}`)).status, 404);
  assert.equal(await readFile(file, 'utf8'), 'original');
  const link = join(dir, 'link'); await symlink(file, link);
  assert.equal((await app.post('attachments', { path: link })).status, 403);
  const unfinished: string[] = [];
  for (let i = 0; i < 16; i++) { const response = await app.post('attachments', { name: 'empty', type: '', size: 0 }); assert.equal(response.status, 200); unfinished.push((await response.json()).id); }
  assert.equal((await app.post('attachments', { name: 'seventeenth', type: '', size: 0 })).status, 409);
  for (const id of unfinished) await app.post(`attachments/${id}/delete`);
  const boundary = await (await app.post('attachments', { name: 'boundary', type: '', size: 768 * 1024 + 1 })).json();
  assert.equal((await fetch(app.base + `attachments/${boundary.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(768 * 1024 + 1) })).status, 413);
  assert.equal((await fetch(app.base + `attachments/${boundary.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(0) })).status, 400);
  await app.post(`attachments/${boundary.id}/delete`);
  const reserved: string[] = [];
  for (let i = 0; i < 4; i++) { const response = await app.post('attachments', { name: 'reserved', type: '', size: 64 * 1024 * 1024 }); assert.equal(response.status, 200); reserved.push((await response.json()).id); }
  assert.equal((await app.post('attachments', { name: 'over-budget', type: '', size: 1 })).status, 409);
  for (const id of reserved) await app.post(`attachments/${id}/delete`);
  const html = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>globalThis.pwned=true</script></svg>');
  const unsafe = await (await app.post('attachments', { name: 'evil.svg', type: 'image/svg+xml', size: html.length })).json();
  assert.equal((await (await fetch(app.base + `attachments/${unsafe.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: html })).json()).attachment.kind, 'file');
  const download = await fetch(app.base + `attachments/${unsafe.id}`);
  assert.equal(download.headers.get('content-type'), 'application/octet-stream');
  assert.equal(download.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(download.headers.get('content-security-policy'), "sandbox; default-src 'none'");
  await app.post('quit'); await app.close;
  await assert.rejects(readFile(lines.at(-1)), { code: 'ENOENT' });
});

test('completion limits active searches and kills expired children', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-search-limit-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const gate = join(dir, 'gate'), fd = join(dir, 'fd');
  await writeFile(fd, `#!${process.execPath}\nrequire('node:net').connect(${JSON.stringify(gate)}).on('connect',function(){this.write('ready')});\n`, { mode: 0o700 });
  const sockets = new Set<import('node:net').Socket>(); let accepted = 0;
  const server = createServer(socket => { accepted++; sockets.add(socket); socket.on('data', () => {}); socket.once('close', () => sockets.delete(socket)); });
  server.listen(gate); await once(server, 'listening'); t.after(() => { for (const socket of sockets) socket.destroy(); server.close(); });
  const app = await fixture(t, [], { KOA_FD: fd }, undefined, true, [], resolve('../koa/koa.ts'));
  const controller = new AbortController();
  const first = fetch(app.base + 'complete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text: '@', pos: 1 }), signal: controller.signal });
  const rejected = assert.rejects(first, { name: 'AbortError' });
  const second = app.post('complete', { text: '@', pos: 1 });
  await pollUntil(() => sockets.size === 4, 1500, 'four fd children');
  const capped = await app.post('complete', { text: '@', pos: 1 });
  assert.equal(capped.status, 200); assert.deepEqual((await capped.json()).options, []); assert.equal(accepted, 4);
  controller.abort(); await rejected;
  await pollUntil(() => sockets.size === 2, 1000, 'disconnect releases children');
  const replacement = app.post('complete', { text: '@', pos: 1 });
  await pollUntil(() => accepted === 6, 1000, 'disconnect releases capacity');
  assert.deepEqual((await (await second).json()).options, []); assert.deepEqual((await (await replacement).json()).options, []);
  await pollUntil(() => sockets.size === 0, 1000, 'expired children ended');
});

test("completion reads pi commands on every request and validates offsets", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "respond", command: "get_commands", data: { commands: [{ name: "find", description: "Find a file", source: "extension" }] } }]);
  for (let i = 0; i < 2; i++) {
    const response = await app.post("complete", { text: "/fi", pos: 3 });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { from: 0, to: 3, options: [{ label: "/find", detail: "Find a file", insert: "/find ", kind: "command", source: "extension", matched: [1, 2] }] });
  }
  assert.equal((await app.log()).filter(record => record.type === "get_commands").length, 2);
  for (const body of [{ text: "@", pos: -1 }, { text: "@", pos: 2 }, { text: "@", pos: 0.5 }, { text: 1, pos: 0 }]) assert.equal((await app.post("complete", body)).status, 400);
});

test("completion serves files and live agents during startup and cancels its fd child", { timeout: 10000 }, async t => {
  const dir = await mkdtemp("/tmp/koa-completion-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  const layout = join(dir, "panes.json"), gate = join(dir, "gate"), fd = join(dir, "fd");
  await symlink(resolve("../../target/debug/fake_ko"), join(dir, "ko"));
  await writeFile(layout, JSON.stringify([selfPane(), agentPane({ pane: "pane_2", session: "22222222aaaa", name: "sidebar" }), agentPane({ pane: "pane_3", session: "22222222bbbb", name: "fix-sidebar" }), agentPane({ pane: "pane_4", session: "elsewhere", name: "sidebar-elsewhere", koSession: "session_2" }), agentPane({ pane: "pane_5", session: "other", name: "sidebar-other", parent: "pane_99" })]));
  await writeFile(fd, `#!/usr/bin/env node
const fs=require('node:fs'),net=require('node:net'),path=${JSON.stringify(dir)},args=process.argv.slice(2);
if(args[0]!=='--base-directory'||!args.includes('--hidden')||!args.includes('--follow')||!args.includes('.git/**'))process.exit(91);
if(fs.existsSync(path+'/block')){fs.writeFileSync(path+'/pid',String(process.pid));net.connect(path+'/gate',function(){this.write('fd')})}else if(new RegExp(args.at(-1)).test('sidebar.txt'))console.log('sidebar.txt');
`, { mode: 0o700 });
  const server = createServer();
  server.listen(gate); await once(server, "listening");
  t.after(() => server.close());
  const starting = once(server, "connection");
  const app = await fixture(t, [{ type: "respond", command: "get_commands", data: { commands: [{ name: "find", source: "extension" }] } }], { KO_PANE: "pane_1", KO_SOCKET: "", KO_PANE_TOKEN: "", KO_FAKE_PANES: layout, KO_FAKE_API_LOG: join(dir, "ko-log"), KOA_FD: fd, KOA_FAKE_STARTUP_GATE: gate, PATH: dir + ":" + process.env.PATH, KO_AGENT_LIST_TTL_MS: "1000" }, undefined, false);
  const [startup] = await starting;
  t.after(() => startup.destroy());
  assert.deepEqual((await (await app.post("complete", { text: "/fi", pos: 3 })).json()).options, []);
  assert.equal((await app.log()).some(record => record.type === "get_commands"), false);
  let items: { kind: string; insert: string }[] = [];
  await pollUntil(async () => { items = (await (await app.post("complete", { text: "@si", pos: 3 })).json()).options; return items.some(item => item.kind === "agent"); }, 5000, "agent completion refresh").catch(async error => { throw new Error(String(error) + "\n" + app.stderr() + "\n" + JSON.stringify(items) + "\n" + await readFile(join(dir, "ko-log"), "utf8").catch(() => "no ko calls")); });
  assert.deepEqual(items.map(item => item.insert), ["@sidebar (session 22222222a) ", "@fix-sidebar (session 22222222b) ", "@sidebar.txt "]);
  startup.write("ready");
  await app.until(record => record.type === "state" && record.pi?.type === "ready");
  assert.equal((await (await app.post("complete", { text: "/fi", pos: 3 })).json()).options[0].insert, "/find ");
  await writeFile(join(dir, "block"), "");
  const connected = once(server, "connection"), controller = new AbortController();
  const request = fetch(app.base + "complete", { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text: "@si", pos: 3 }), signal: controller.signal });
  const [socket] = await connected;
  t.after(() => socket.destroy());
  await once(socket, "data");
  assert.match(await readFile(join(dir, "pid"), "utf8"), /^[1-9]\d+$/);
  const closed = once(socket, "close");
  controller.abort();
  await assert.rejects(request, { name: "AbortError" });
  await closed;
});

test("document loads read the current page files and recover after a failed read", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-page-reload-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../../build/ko/share/ko/koa"), dir, { recursive: true });
  const program = join(dir, "koa.ts");
  await writeFile(program, `import ${JSON.stringify(resolve("../koa/koa.ts"))};`);
  const app = await fixture(t, [], {}, undefined, true, [], program);
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
  const off = await fixture(t, []);
  assert.equal((await off.post("metrics", [])).status, 404);
  assert.equal(off.records().some(record => record.type === "flush"), false);
  assert.doesNotMatch(await (await fetch(off.base)).text(), /<meta name="koa-metrics"/);
  const dir = await mkdtemp(join(tmpdir(), "koa-metrics-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, "metrics.jsonl");
  const on = await fixture(t, [], {}, undefined, true, ["--metrics", file, "--metrics-mode", "frame"]);
  const flush = await on.until(record => record.type === "flush");
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
    const child = spawn(process.execPath, [resolve("../koa/koa.ts"), ...args], { timeout: 5000 });
    let error = "";
    child.stderr.on("data", bytes => { error += bytes; });
    const [code] = await once(child, "close");
    assert.equal(code, 1);
    assert.match(error, args[1] === "frame" ? /--metrics-mode requires --metrics/ : /--metrics-mode requires applied or frame/);
  }
});

test("startup refuses prompts until the snapshot response is applied", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-startup-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const gate = join(dir, "gate");
  const server = createServer();
  await new Promise<void>(resolve => server.listen(gate, resolve));
  t.after(() => server.close());
  const connected = once(server, "connection");
  const pi = join(dir, "pi.mjs");
  await writeFile(pi, `#!/usr/bin/env node
import { connect } from 'node:net';
let buffer = '', snapshot, answered = false, released = false;
const complete = () => { if (snapshot && answered && released) { send(snapshot, {messages:[{role:'user',content:'snapshot',timestamp:1}]}); snapshot = undefined; } };
const send = (v, data) => process.stdout.write(JSON.stringify({type:'response',command:v.type,id:v.id,success:true,data})+'\\n');
process.stdin.on('data', bytes => {
  buffer += bytes;
  let end;
  while ((end = buffer.indexOf('\\n')) >= 0) {
    const v = JSON.parse(buffer.slice(0,end)); buffer = buffer.slice(end+1);
    if (v.type === 'get_messages') {
      snapshot = v;
      process.stdout.write(JSON.stringify({type:'extension_ui_request',method:'select',id:'startup-dialog',title:'Continue?',options:['Yes','No']})+'\\n');
      const socket = connect(process.env.KOA_STARTUP_GATE);
      socket.on('data', () => { released = true; complete(); socket.end(); });
    } else if (v.type === 'extension_ui_response') { answered = v.id === 'startup-dialog' && v.value === 'Yes'; complete(); }
    else send(v, v.type === 'get_available_thinking_levels' ? {levels:['off','low','high']} : {});
  }
});
process.stdin.on('end', () => process.exit(0));
`, { mode: 0o700 });
  const app = await fixture(t, [], { KOA_STARTUP_GATE: gate }, pi, false);
  const [socket] = await connected;
  t.after(() => socket.destroy());
  const early = await app.post("prompt", { text: "too early", mode: "prompt", attachments: [] });
  assert.equal(early.status, 409);
  assert.match((await early.json()).error, /starting/);
  for (const [route, body] of [["model", {provider:"test",modelId:"early"}], ["thinking", {level:"high"}], ["queue/clear", {}], ["abort", {}], ["editor/ack", {id:"early"}]] as const) {
    const result = await app.post(route, body);
    assert.equal(result.status, 409, route);
    assert.match((await result.json()).error, /starting/, route);
  }
  const models = await fetch(app.base + "models");
  assert.equal(models.status, 409);
  assert.match((await models.json()).error, /starting/);
  const startup = await app.until(record => record.type === "state" && record.dialogs?.[0]?.id === "startup-dialog");
  assert.equal(startup.pi.type, "starting");
  const afterDialog = app.count();
  assert.equal((await app.post("dialog", {id:"startup-dialog",value:"Yes"})).status, 200);
  assert.equal((await app.post("prompt", {text:"still starting",mode: "prompt", attachments: []})).status, 409);
  socket.write("ready");
  const ready = await app.until(record => record.type === "state" && record.pi?.type === "ready", afterDialog);
  assert.equal(ready.dialogs.length, 0);
  const page = await (await fetch(app.base + "items?before=99")).json();
  assert.equal(page.items[0].text, "snapshot");
  assert.equal((await app.post("prompt", { text: "ready", mode: "prompt", attachments: [] })).status, 200);
});

const assistantMessage = { ...assistant("stop"), api: "test", provider: "test", model: "test", usage: {}, timestamp: 42 };

test("RPC deltas, authoritative ends, tools, state, status and command correlation", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "agent_start" },
      { type: "message_start", message: assistantMessage },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "text_start", contentIndex: 0 } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "hello\u2028world" } },
      { type: "queue_update", steering: ["next"], followUp: [] },
    ], data: { disposition: "started" } },
    { type: "wait", command: "prompt", data: { disposition: "queued" } },
    { type: "wait", command: "prompt", data: { disposition: "handled" } },
    { type: "wait", command: "abort", events: [
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "authoritative" } },
      { type: "message_end", message: { ...assistantMessage, content: [{ type: "text", text: "final" }], stopReason: "error", errorMessage: "failure\nsecret" } },
      { type: "agent_settled", aborted: false },
      { type: "thinking_level_changed", level: "high" },
      { type: "session_info_changed", name: "Renamed" },
    ] },
  ]);
  const started = await app.post("prompt", { text: "go", mode: "steer", attachments: [] });
  assert.equal(started.status, 200);
  assert.deepEqual(await started.json(), { disposition: "started" });
  const item = await app.until(record => ["item", "patch"].includes(String(record.type)) && JSON.stringify(record).includes("hello\u2028world"));
  assert.match(JSON.stringify(item), /hello\\u2028world|hello\u2028world/);
  assert.deepEqual(await (await app.post("prompt", { text: "steering", mode: "steer", attachments: [] })).json(), { disposition: "queued" });
  assert.deepEqual(await (await app.post("prompt", { text: "later", mode: "follow_up", attachments: [] })).json(), { disposition: "handled" });
  assert.equal((await app.post("abort")).status, 200);
  const patch = await app.until(record => record.type === "patch" && JSON.stringify(record).includes("final"));
  assert.match(JSON.stringify(patch), /final/);
  const state = await app.until(record => record.type === "state" && record.thinking === "high");
  assert.deepEqual(state.queue, { steering: [{ text: "next", attachments: [] }], followUp: [] });
  assert.deepEqual(state.context, { tokens: 123, window: 1000, percent: 12.3 });
  await app.until(record => record.type === "state" && record.name === "Renamed");
  assert.match(app.stdout(), /\x1b\]7501;state=working:app=pi/);
  assert.match(app.stdout(), /\x1b\]7501;state=error:app=pi:msg=ZmFpbHVyZQ==/);
  assert.match(app.stdout(), /\x1b\]0;koa - Renamed - /);
  const commands = (await app.log()).filter(record => record.id);
  assert.equal(new Set(commands.map(record => record.id)).size, commands.length);
  assert.deepEqual(commands.filter(record => ["prompt", "abort"].includes(record.type)).map(record => record.type), ["prompt", "prompt", "prompt", "abort"]);
  assert.deepEqual(commands.filter(record => record.type === "prompt").map(record => record.streamingBehavior), [undefined, "steer", "followUp"]);
  assert.equal((await fetch(app.base)).status, 200);
  assert.equal((await app.post("quit")).status, 200);
  await app.close;
});

test("tool deltas, end replacement, timing and compaction rebuild", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "agent_start" },
      { type: "message_start", message: assistantMessage },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "thinking_start", contentIndex: 0 } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "thought" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "thinking_end", contentIndex: 0, content: "replaced thought" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_start", contentIndex: 1, id: "tool", toolName: "read" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_delta", contentIndex: 1, delta: "{\"path\":\"a\"}" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_end", contentIndex: 1, toolCall: { type: "toolCall", id: "tool", name: "read", arguments: { path: "b" } } } },
      { type: "tool_execution_start", toolCallId: "tool" },
      { type: "tool_execution_update", toolCallId: "tool", partialResult: { content: [{ type: "text", text: "partial" }] } },
      { type: "tool_execution_end", toolCallId: "tool", result: { content: [{ type: "text", text: "result" }] }, isError: false, durationMs: 17 },
      { type: "message_end", message: { ...assistantMessage, content: [{ type: "thinking", thinking: "final thought" }, { type: "toolCall", id: "tool", name: "read", arguments: { path: "b" } }] } },
      { type: "agent_settled", aborted: false },
    ] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end" }] },
    { type: "wait", command: "get_messages", data: { messages: [{ role: "user", content: "rebuilt", timestamp: 99 }] } },
  ]);
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
  const record = await app.until(record => record.type === "patch" && JSON.stringify(record).includes('"durationMs":17'));
  const text = JSON.stringify(record);
  assert.match(text, /result/);
  assert.match(text, /durationMs":17/);
  assert.match(text, /started":\d+/);
  assert.match(text, /ended":\d+/);
  const timed = await (await fetch(app.base + "items?before=99")).json();
  const thinking = timed.items[0].blocks[0];
  assert.equal(thinking.type, "thinking");
  assert.equal(typeof thinking.started, "number");
  assert.equal(typeof thinking.ended, "number");
  assert.ok(thinking.ended >= thinking.started);
  assert.equal(typeof timed.items[0].ended, "number");
  await app.until(record => record.type === "patch" && JSON.stringify(record).includes("final thought"));
  await app.until(record => record.type === "state" && record.working === false && record.aborted === false);
  assert.match(app.stdout(), /\x1b\]7501;state=done:app=pi/);
  await app.post("abort");
  const reset = await app.until(record => record.type === "reset" && JSON.stringify(record).includes("rebuilt"));
  assert.match(JSON.stringify(reset), /"at":99/);
});

test("a rebuild response is applied before later records in the same byte chunk", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "get_messages", data: { messages: [{ role: "user", content: "before", timestamp: 1 }] }, after: [{ type: "message_end", message: { role: "user", content: "after", timestamp: 2 } }] }]);
  const page = await (await fetch(app.base + "items?before=99")).json();
  assert.deepEqual(page.items.map((item: { text: string }) => item.text), ["before", "after"]);
});

test("queue, model, thinking and dialog routes carry RPC state", { timeout: 10000 }, async t => {
  const dialog = { type: "extension_ui_request", method: "select", id: "dialog-1", title: "Pick", options: ["Yes", "No"] };
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "agent_start" },
      { type: "queue_update", steering: ["steer"], followUp: ["later"] },
      dialog,
      { ...dialog, id: "dialog-2", method: "confirm", message: "Really?" },
      { type: "extension_ui_request", method: "notify", id: "notify", message: "Notice", notifyType: "warning" },
      { type: "extension_ui_request", method: "setStatus", id: "status", statusKey: "check", statusText: "Checking" },
      { type: "extension_ui_request", method: "set_editor_text", id: "editor", text: "Draft" },
    ] },
    { type: "wait", command: "clear_queue", data: { steering: ["steer"], followUp: ["later"] } },
    { type: "wait", command: "get_available_models", data: { models: [{ id: "new", provider: "test" }] } },
    { type: "wait", command: "set_model", data: { id: "new", provider: "test" } },
    { type: "wait", command: "set_thinking_level", events: [{ type: "thinking_level_changed", level: "high" }] },
    { type: "wait", command: "extension_ui_response" },
    { type: "wait", command: "extension_ui_response", events: [{ ...dialog, id: "dialog-3", method: "input" }] },
    { type: "wait", command: "extension_ui_response", events: [{ ...dialog, id: "dialog-4", method: "editor" }] },
    { type: "wait", command: "extension_ui_response" },

  ]);
  assert.equal((await app.post("prompt", { text: "go", mode: "prompt", attachments: [] })).status, 200);
  const state = await app.until(record => record.type === "state" && record.dialogs?.length === 2);
  assert.deepEqual(state.dialogs, [dialog, { ...dialog, id: "dialog-2", method: "confirm", message: "Really?" }]);
  await app.until(record => record.type === "item" && record.item.kind === "notify" && record.item.text.text === "Notice" && record.item.level === "warning");
  await app.until(record => record.type === "state" && record.editor?.text === "Draft");
  await app.until(record => record.type === "state" && record.statuses?.check === "Checking");
  assert.match(app.stdout(), /state=blocked:app=pi:kind=question/);
  const controller = new AbortController();
  const reloaded = await fetch(app.base + "events", { signal: controller.signal });
  assert.ok(reloaded.body);
  const reload = sse(Readable.from(reloaded.body));
  const reloadedState = await reload.until(record => record.type === "state");
  assert.deepEqual(reloadedState.dialogs, state.dialogs);
  assert.deepEqual(reloadedState.editor, { id: "editor", text: "Draft" });
  controller.abort();
  assert.equal((await app.post("editor/ack", { id: "old" })).status, 200);
  const editorAfter = app.count();
  assert.equal((await app.post("editor/ack", { id: "editor" })).status, 200);
  await app.until(record => record.type === "state" && !record.editor, editorAfter);
  assert.deepEqual(await (await app.post("queue/clear")).json(), { steering: [{ text: "steer", attachments: [] }], followUp: [{ text: "later", attachments: [] }] });
  assert.deepEqual(await (await fetch(app.base + "models")).json(), { models: [{ id: "new", provider: "test" }] });
  assert.equal((await app.post("model", { provider: "test", modelId: "new" })).status, 200);
  await app.until(record => record.type === "state" && record.model?.provider === "test" && record.model.id === "new");
  assert.equal((await app.post("thinking", { level: "max" })).status, 409);
  assert.equal((await app.post("thinking", { level: "high" })).status, 200);
  assert.equal((await app.post("dialog", { id: "dialog-1", value: "Yes" })).status, 200);
  assert.equal((await app.post("dialog", { id: "dialog-1", value: "Yes" })).status, 409);
  assert.equal((await app.post("dialog", { id: "dialog-2", confirmed: true })).status, 200);
  await app.until(record => record.type === "state" && record.dialogs[0]?.id === "dialog-3");
  assert.equal((await app.post("dialog", { id: "dialog-3", value: "typed" })).status, 200);
  await app.until(record => record.type === "state" && record.dialogs[0]?.id === "dialog-4");
  assert.equal((await app.post("dialog", { id: "dialog-4", cancelled: true })).status, 200);
  const commands = await app.log();
  assert.deepEqual(commands.find(record => record.type === "set_model"), { type: "set_model", provider: "test", modelId: "new", id: commands.find(record => record.type === "set_model").id });
  assert.deepEqual(commands.filter(record => record.type === "extension_ui_response").map(({ id, value, confirmed }) => ({ id, value, confirmed })), [{ id: "dialog-1", value: "Yes", confirmed: undefined }, { id: "dialog-2", value: undefined, confirmed: true }, { id: "dialog-3", value: "typed", confirmed: undefined }, { id: "dialog-4", value: undefined, confirmed: undefined }]);
});

test("session headers keep the startup cwd for a missing file and report invalid files", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-session-header-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const invalid = join(dir, "invalid.jsonl");
  await writeFile(invalid, "not json\n");
  for (const [sessionFile, reports] of [[join(dir, "missing.jsonl"), false], [invalid, true], [dir, true]] as const) {
    const app = await fixture(t, [{ type: "respond", command: "get_state", data: { sessionFile } }]);
    const state = await app.until(record => record.type === "state" && record.pi?.type === "ready");
    assert.equal(state.cwd, process.cwd());
    assert.equal(app.stderr().includes("koa: session header:"), reports, app.stderr());
  }
});

test("restart keeps the saved picker selection, harness and runtime", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-restart-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const session = join(dir, "last.jsonl");
  await writeFile(session, JSON.stringify({ cwd: dir }) + "\n");
  const selection = join(dir, "selection");
  await writeFile(selection, JSON.stringify({}));
  const app = await fixture(t, [
    { type: "respond", command: "get_state", data: { sessionFile: session } },
    { type: "wait", command: "set_model", data: { provider: "test", id: "picked" } },
    { type: "wait", command: "set_thinking_level", events: [{ type: "thinking_level_changed", level: "high" }] },
    { type: "wait", command: "prompt" }, { type: "exit", code: 7 },
  ], { KOA_FAKE_SELECTION_FILE: selection }, undefined, true, ["--runtime", "remote", "--session", "old.jsonl", "--fork", "source.jsonl", "--model", "test/original", "--thinking", "low"]);
  assert.equal((await app.post("pi/start")).status, 409);
  assert.equal((await app.post("model", { provider: "test", modelId: "picked" })).status, 200);
  assert.equal((await app.post("thinking", { level: "high" })).status, 200);
  await app.post("prompt", { text: "exit", mode: "prompt", attachments: [] });
  await app.until(record => record.type === "state" && record.pi?.type === "exited");
  const after = app.count();
  assert.equal((await app.post("pi/start")).status, 200);
  const restarted = await app.until(record => record.type === "state" && record.pi?.type === "ready" && record.levels?.length === 3, after);
  assert.deepEqual(restarted.model, {provider:"test",id:"picked"});
  assert.equal(restarted.thinking, "high");
  const argv = (await app.log()).filter(record => record.type === "argv").map(record => record.args);
  assert.equal(argv.length, 2);
  assert.deepEqual(argv[1], ["--mode", "rpc", "--extension", resolve("../../build/ko/share/ko/pi/ko-pi.ts"), "--harness", "koa-browser", "--runtime", "remote", "--session", session]);
});

test("spawn failure is distinct from an exit code", { timeout: 10000 }, async t => {
  const app = await fixture(t, [], {}, "/koa-no-such-pi");
  const state = await app.until(record => record.type === "state" && record.pi?.type === "exited");
  assert.match(state.pi.failed, /ENOENT/);
  assert.equal("exited" in state.pi, false);
  assert.equal((await app.post("abort")).status, 409);
});

test("clean pi exit closes koa", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "exit", code: 0 }]);
  await app.post("prompt", { text: "quit", mode: "prompt", attachments: [] });
  const result = await Promise.race([app.close, timers.setTimeout(1000, "still running", { ref: false })]);
  assert.deepEqual(result, [0, null]);
  await assert.rejects(fetch(app.base));
});

test("pi crash keeps koa serving its transcript and exit state", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "raw", text: "not json\r\n" }, { type: "stderr", text: "old1\nold2\na\nb\nc\npar" }, { type: "stderr", text: "tial\nlast\n" }, { type: "exit", code: 7 }]);
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
  const state = await app.until(record => record.type === "state" && record.pi?.type === "exited");
  assert.equal(state.pi.exited, 7);
  assert.equal(typeof state.pi.at, "number");
  assert.equal(state.pi.stderr, "a\nb\nc\npartial\nlast");
  assert.match(app.stdout(), /\x1b\]7501;state=clear\x1b\\/);
  assert.match(app.stderr(), /koa: pi stdout: not json/);
  assert.equal((await app.post("abort")).status, 409);
  assert.equal((await fetch(app.base)).status, 200);
  assert.equal(state.sessionFile, undefined);
  assert.equal((await app.post("pi/start")).status, 200);
  const args = (await app.log()).filter(record => record.type === "argv").map(record => record.args);
  assert.deepEqual(args[1], args[0]);
});

test("concurrent large commands cross pipe back-pressure without lost ids or bytes", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-pressure-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "pressure.mjs");
  const pressureLog = join(dir, "writes");
  await writeFile(hook, `import { ChildProcess } from "node:child_process";
    import { appendFileSync } from "node:fs";
    const spawn = ChildProcess.prototype.spawn;
    ChildProcess.prototype.spawn = function(...args) {
      const result = spawn.apply(this, args);
      if (this.spawnargs.includes("rpc") && this.stdin) {
        const input = this.stdin;
        const write = input.write;
        let blocked = false;
        input.on("drain", () => { blocked = false; });
        input.write = function(...args) {
          if (blocked) throw Error("command written before drain");
          const ready = write.apply(this, args);
          if (!ready) { blocked = true; appendFileSync(process.env.KOA_PRESSURE_LOG, "blocked\\n"); }
          return ready;
        };
      }
      return result;
    };`);
  const app = await fixture(t, [], { NODE_OPTIONS: `--import=${hook}`, KOA_PRESSURE_LOG: pressureLog });
  const texts = ["a", "b", "c"].map(prefix => prefix.repeat(900 * 1024));
  const responses = await Promise.all(texts.map(text => app.post("prompt", { text, mode: "prompt", attachments: [] })));
  assert.deepEqual(responses.map(response => response.status), [200, 200, 200]);
  assert.equal((await app.post("abort")).status, 200);
  assert.equal((await app.post("prompt", { text: "x".repeat(1500 * 1024), mode: "prompt", attachments: [] })).status, 413);
  const invalid = await app.post("prompt", { text: "", mode: "prompt", attachments: [] });
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: "Text or attachments and prompt, steer or follow_up mode are required" });
  const commands = await app.log();
  const prompts = commands.filter(command => command.type === "prompt");
  assert.deepEqual(prompts.map(command => command.message).sort(), texts.sort());
  const ids = commands.filter(command => command.id).map(command => command.id);
  assert.equal(new Set(ids).size, ids.length);
  assert.ok((await readFile(pressureLog, "utf8")).split("\n").filter(Boolean).length >= 3);
});

test("tool argument JSON is parsed once per flush, not per delta", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-json-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "json.mjs");
  const log = join(dir, "parses");
  await writeFile(hook, `import { appendFileSync } from "node:fs";
    const parse = JSON.parse;
    JSON.parse = function(text, ...args) {
      if (text.startsWith('{"instrumented":')) appendFileSync(process.env.KOA_PARSE_LOG, "parse\\n");
      return parse.call(this, text, ...args);
    };`);
  const app = await fixture(t, [{ type: "wait", command: "prompt", events: [
    { type: "message_start", message: assistantMessage },
    { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_start", contentIndex: 0, id: "args", toolName: "read" } },
    ...['{"instrumented":', ...Array.from({ length: 98 }, () => " "), "1}"].map(delta => ({ type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta } })),
  ] }], { NODE_OPTIONS: `--import=${hook}`, KOA_PARSE_LOG: log });
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
  await app.until(record => record.type === "patch" && JSON.stringify(record).includes("instrumented"));
  assert.equal(await readFile(log, "utf8"), "parse\n");
});

test("HTTP UTF-8 chunks reach pi without replacement characters", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-body-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "chunks.mjs");
  await writeFile(hook, `import { IncomingMessage } from "node:http";
    const read = IncomingMessage.prototype[Symbol.asyncIterator];
    IncomingMessage.prototype[Symbol.asyncIterator] = async function* () {
      for await (const bytes of read.call(this)) for (let i = 0; i < bytes.length; i++) yield bytes.subarray(i, i + 1);
    };`);
  const app = await fixture(t, [], { NODE_OPTIONS: `--import=${hook}` });
  const text = "héllo 🌎";
  assert.equal((await app.post("prompt", { text, mode: "prompt", attachments: [] })).status, 200);
  assert.equal((await app.log()).find(record => record.type === "prompt").message, text);
});

test("manual compaction restores status and retries stay working", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [{ type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: false, willRetry: false }] },
    { type: "wait", command: "prompt", events: [{ type: "agent_start" }, { type: "agent_settled", aborted: false }, { type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: true, willRetry: false }] },
    { type: "wait", command: "prompt", events: [{ type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: false, willRetry: false, errorMessage: "compact failed\nmore" }] },
    { type: "wait", command: "prompt", events: [{ type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: false, willRetry: false }] },
    { type: "wait", command: "prompt", events: [{ type: "agent_start" }, { type: "compaction_start", reason: "overflow" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "overflow", aborted: false, willRetry: true }, { type: "queue_update", steering: ["retry"], followUp: [] }] },
  ]);
  for (const expected of ["idle", "done", "error", "error"]) {
    let after = app.count();
    assert.equal((await app.post("prompt", { text: "compact", mode: "prompt", attachments: [] })).status, 200);
    await app.until(record => record.type === "state" && record.working === true, after);
    after = app.count();
    assert.equal((await app.post("abort")).status, 200);
    await app.until(record => record.type === "state" && record.working === false, after);
    assert.match(app.stdout().split("\x1b]7501;").at(-1) ?? "", new RegExp(`^state=${expected}:`));
  }
  assert.equal((await app.post("prompt", { text: "retry", mode: "prompt", attachments: [] })).status, 200);
  await app.post("abort");
  const state = await app.until(record => record.type === "state" && JSON.stringify(record.queue).includes("retry"));
  assert.equal(state.working, true);
  assert.match(app.stdout().split("\x1b]7501;").at(-1) ?? "", /^state=working:/);
});

test("pi exit does not wait for a descendant that holds its pipes", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-pipes-"));
  const gate = join(dir, "gate");
  const server = createServer();
  await new Promise<void>(resolve => server.listen(gate, resolve));
  const connected = once(server, "connection");
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "exit", code: 7 }], { KOA_FAKE_KEEP_PIPES: gate });
  await app.post("prompt", { text: "exit", mode: "prompt", attachments: [] });
  const [peer] = await connected;
  try {
    await app.post("quit");
    assert.equal(await Promise.race([app.close.then(() => true), timers.setTimeout(500, false)]), true);
  } finally {
    peer.end("release");
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test("quit exits at its deadline when the reply stalls and the client never reads", { timeout: 6000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-quit-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "stall.mjs");
  await writeFile(hook, `import { ServerResponse } from "node:http";
    const end = ServerResponse.prototype.end;
    ServerResponse.prototype.end = function(...args) {
      return this.req.url === "/quit" ? this : end.apply(this, args);
    };`);
  const app = await fixture(t, [], { NODE_OPTIONS: `--import=${hook}` });
  const url = new URL(app.base);
  const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`POST /quit HTTP/1.1\r\nHost: ${url.host}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}`));
  socket.pause();
  socket.on("error", () => {});
  t.after(() => socket.destroy());
  assert.equal(await Promise.race([app.close.then(() => true), timers.setTimeout(3000, false, { ref: false })]), true);
});

test("shutdown closes stdin before group TERM and KILL", { timeout: 10000 }, async t => {
  const app = await fixture(t, [], { KOA_FAKE_STUBBORN: "1" });
  assert.equal((await app.post("quit")).status, 200);
  await app.close;
  const log = await app.log();
  const eof = log.findIndex(record => record.type === "stdin_end");
  const term = log.findIndex(record => record.type === "signal");
  assert.ok(eof >= 0 && term > eof);
});
