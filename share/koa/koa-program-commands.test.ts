import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir, cp, symlink, truncate } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, relative } from "node:path";
import { once } from "node:events";
import { createServer } from "node:net";
import { request } from "node:http";
import { EventEmitter } from 'node:events';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import { assistant } from "./koa-agent-fixture.ts";
import { pollUntil } from "./koa-agent-fixture.ts";
import { fixture } from "./koa-program-fixture.ts";
test('history comes from the whole transcript and omits consecutive duplicates', { timeout: 10000 }, async t => {
  const messages = Array.from({ length: 110 }, (_, i) => ({ role: 'user', content: 'prompt ' + i, timestamp: i + 1 }));
  messages.push({ role: 'user', content: ' prompt 109 ', timestamp: 112 });
  const f = await fixture(t, [{ type: 'respond', command: 'get_messages', data: { messages: [...messages,
    { role: 'bashExecution', command: 'pwd', excludeFromContext: false, output: '', exitCode: 0, cancelled: false, truncated: false, timestamp: 113 },
    { role: 'bashExecution', command: 'pwd', excludeFromContext: true, output: '', exitCode: 0, cancelled: false, truncated: false, timestamp: 114 },
  ] } }], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const result: { entries: string[] } = await (await fetch(f.base + 'history')).json();
  assert.equal(result.entries.length, 100);
  assert.deepEqual(result.entries.slice(0, 3), ['!!pwd', '!pwd', 'prompt 109']);
  assert.equal(result.entries.at(-1), 'prompt 12');
});

test('model selection, completion collisions, session statistics and export defaults use pi', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-export-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const exported = join(dir, 'default.html'); await writeFile(exported, '<html>exported session</html>');
  const stats = { sessionId: 'test-session', userMessages: 2, assistantMessages: 1, toolCalls: 0, toolResults: 0, totalMessages: 3, tokens: { input: 12, output: 34, cacheRead: 56, cacheWrite: 78, total: 180 }, cost: 0.01 };
  const f = await fixture(t, [
    { type: 'respond', command: 'get_commands', data: { commands: [{ name: 'model', source: 'extension' }, { name: 'custom', source: 'extension' }] } },
    { type: 'respond', command: 'get_session_stats', data: stats },
    { type: 'wait', command: 'get_available_models', data: { models: [{ provider: 'test', id: 'exact' }] } },
    { type: 'wait', command: 'set_model', data: { provider: 'test', id: 'exact' } },
    { type: 'wait', command: 'set_thinking_level', events: [{ type: 'thinking_level_changed', level: 'high' }] },
    { type: 'wait', command: 'export_html', data: { path: exported } },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const completion: { options: { label: string; source: string }[] } = await (await f.post('complete', { text: '/', pos: 1 })).json();
  assert.deepEqual(completion.options.map(value => value.label), ['/model', '/thinking', '/compact', '/session', '/copy', '/export', '/name', '/resume', '/new', '/quit', '/reload', '/custom']);
  assert.equal(completion.options[0]?.source, 'builtin');
  for (const text of ['/model TEST/EXACT', '/thinking HIGH', '/session', '/export']) assert.equal((await f.post('prompt', { text, mode: 'prompt', attachments: [] })).status, 200);
  await f.until(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'session');
  assert.deepEqual(f.records().find(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'session')?.item.result.stats, stats);
  assert.ok((await f.log()).some(value => value.type === 'set_thinking_level' && value.level === 'high'));
  assert.ok((await f.log()).some(value => value.type === 'export_html' && !('outputPath' in value)));
  const notice = await f.until(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'export');
  assert.equal(await (await fetch(f.base + 'steps/' + notice.item.seq + '/0/file')).text(), '<html>exported session</html>');
  assert.equal((await f.post('prompt', { text: '/quit', mode: 'prompt', attachments: [] })).status, 200);
  assert.equal((await f.close)[0], 0);
});

test('manual compaction has one result per attempt and restores the working state', { timeout: 10000 }, async t => {
  const result = { summary: 'Preserved decisions', firstKeptEntryId: 'entry', tokensBefore: 10000, estimatedTokensAfter: 2000 };
  const f = await fixture(t, [
    { type: 'wait', command: 'compact', events: [{ type: 'compaction_start', reason: 'manual' }], after: [{ type: 'compaction_end', reason: 'manual', result, willRetry: false }] },
    { type: 'wait', command: 'compact', error: 'request failed', events: [{ type: 'compaction_start', reason: 'manual' }], after: [{ type: 'compaction_end', reason: 'manual', errorMessage: 'request failed', willRetry: false }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  for (const state of ['done', 'failed']) {
    const cursor = f.count();
    assert.equal((await f.post('prompt', { text: '/compact', mode: 'prompt', attachments: [] })).status, 200);
    await f.until(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'compaction' && record.item.result.state.type === state, cursor);
    await f.until(record => record.type === 'state' && record.compaction === 'idle' && !record.working, cursor);
  }
  assert.equal(f.records().filter(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'compaction' && record.item.result.state.type === 'failed').length, 1);
  assert.ok(f.records().some(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'compaction' && record.item.result.state.type === 'done' && record.item.result.state.before === 10000 && record.item.result.state.after === 2000));
});

test('a held compaction can be aborted and finishes as cancelled', { timeout: 10000 }, async t => {
  const f = await fixture(t, [
    { type: 'wait', command: 'compact', defer: true, events: [{ type: 'compaction_start', reason: 'manual' }] },
    { type: 'wait', command: 'clear_queue', data: { steering: [], followUp: [] } },
    { type: 'wait', command: 'abort', events: [{ type: 'compaction_end', reason: 'manual', aborted: true, willRetry: false }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await f.post('prompt', { text: '/compact', mode: 'prompt', attachments: [] })).status, 200);
  await f.until(record => record.type === 'state' && record.compaction === 'running');
  assert.equal((await f.post('queue/clear')).status, 200);
  assert.equal((await f.post('abort')).status, 200);
  await f.until(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'compaction' && record.item.result.state.type === 'cancelled');
  await f.until(record => record.type === 'state' && record.compaction === 'idle' && !record.working);
});

test('a compaction crash clears its state and restart accepts a prompt', { timeout: 10000 }, async t => {
  const f = await fixture(t, [
    { type: 'wait', command: 'compact', defer: true, events: [{ type: 'compaction_start', reason: 'manual' }] },
    { type: 'wait', command: 'abort' }, { type: 'exit', code: 7 },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await f.post('prompt', { text: '/compact', mode: 'prompt', attachments: [] })).status, 200);
  await f.until(record => record.type === 'state' && record.compaction === 'running');
  await f.post('abort');
  await f.until(record => record.type === 'state' && record.pi.type === 'exited' && record.compaction === 'idle' && !record.working);
  assert.ok(f.records().some(record => record.type === 'item' && record.item.kind === 'command' && record.item.result.type === 'compaction' && record.item.result.state.type === 'failed' && /code 7/.test(record.item.result.state.message)));
  await writeFile(f.script, JSON.stringify({ type: 'wait', command: 'prompt', echo: true }));
  assert.equal((await f.post('pi/start')).status, 200);
  assert.equal((await f.post('prompt', { text: 'after restart', mode: 'prompt', attachments: [] })).status, 200);
  await f.until(record => record.type === 'item' && record.item.kind === 'user' && record.item.text === 'after restart');
});

test('built-in commands use RPC and never become prompts', { timeout: 10000 }, async t => {
  const f = await fixture(t, [
    { type: 'wait', command: 'get_last_assistant_text', data: { text: 'copied reply' } },
    { type: 'wait', command: 'export_html', data: { path: '/tmp/export.html' } },
    { type: 'wait', command: 'compact', data: {} },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  for (const text of ['/tree args', '/resume', '/new', '/copy', '/export /tmp/export.html', '/compact keep decisions', '/model', '/thinking', '/export test.jsonl']) {
    const response = await f.post('prompt', { text, mode: 'prompt', attachments: [] });
    assert.equal(response.status, 200);
    if (text === '/resume' || text === '/new') assert.deepEqual(await response.json(), { disposition: 'handled', action: { type: 'session', kind: text.slice(1) } });
  }
  const history = await (await fetch(f.base + 'history')).json();
  assert.deepEqual(history.entries, []);
  const log = await f.log();
  assert.equal(log.filter(value => value.type === 'prompt').length, 0);
  assert.ok(log.some(value => value.type === 'export_html' && value.outputPath === '/tmp/export.html'));
  assert.ok(log.some(value => value.type === 'compact' && value.customInstructions === 'keep decisions'));
  assert.ok(f.stdout().includes('\x1b]52;c;' + Buffer.from('copied reply').toString('base64') + '\x1b\\'));
});

test('in-page session switches refresh only on success', { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: 'respond', command: 'get_messages', data: { messages: [{ role: 'user', timestamp: 1, content: [{ type: 'image', mimeType: 'image/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==' }] }] } },
    { type: 'emit', event: { type: 'queue_update', steering: ['keep queued'], followUp: [] } },
    { type: 'wait', command: 'switch_session', data: { cancelled: true } },
    { type: 'wait', command: 'switch_session', data: { cancelled: false } },
    { type: 'respond', command: 'get_state', data: { sessionId: 'chosen', sessionName: 'Chosen', thinkingLevel: 'low' } },
    { type: 'respond', command: 'get_messages', data: { messages: [{ role: 'user', timestamp: 1, content: [{ type: 'text', text: 'Chosen history' }] }] } },
    { type: 'wait', command: 'new_session', error: 'Cannot create session' },
  ], { KOA_FAKE_SESSIONS: JSON.stringify([{ path: '/tmp/chosen.jsonl' }]) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const before = app.records().filter(record => record.type === 'reset').length;
  assert.equal((await app.post('sessions/switch', { path: '/tmp/chosen.jsonl' })).status, 200);
  assert.equal(app.records().filter(record => record.type === 'reset').length, before);
  const cancelled = app.records().filter(record => record.type === 'state').at(-1);
  assert.equal(cancelled.queue.steering[0].text, 'keep queued');
  assert.equal(app.records().filter(record => record.type === 'reset').at(-1).items[0].images.length, 1);
  assert.equal((await app.post('sessions/switch', { path: '/tmp/chosen.jsonl' })).status, 200);
  await app.until(record => record.type === 'state' && record.sessionId === 'chosen' && record.pi.type === 'ready');
  assert.ok(app.records().some(record => record.type === 'reset' && record.items.some((item: { text?: string }) => item.text === 'Chosen history')));
  const ready = app.records().filter(record => record.type === 'state').at(-1);
  assert.equal(ready.name, 'Chosen'); assert.equal(ready.cwd, process.cwd());
  assert.deepEqual(ready.queue, { steering: [], followUp: [] });
  assert.equal((await app.post('sessions/new')).status, 409);
});

test('session startup UI records survive switching and refresh', { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: 'wait', command: 'switch_session', data: { cancelled: false }, events: [{ type: 'extension_ui_request', id: 'before', method: 'setStatus', statusKey: 'startup', statusText: 'before response' }] },
    { type: 'respond', command: 'get_state', data: { sessionId: 'chosen', sessionName: 'Chosen' } },
    { type: 'respond', command: 'get_messages', data: { messages: [] }, after: [{ type: 'extension_ui_request', id: 'during', method: 'setStatus', statusKey: 'refresh', statusText: 'during refresh' }] },
  ], { KOA_FAKE_SESSIONS: JSON.stringify([{ path: '/tmp/chosen.jsonl' }]) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await app.post('sessions/switch', { path: '/tmp/chosen.jsonl' })).status, 200);
  const ready = await app.until(record => record.type === 'state' && record.pi.type === 'ready' && record.statuses.refresh === 'during refresh');
  assert.equal(ready.statuses.startup, 'before response');
});

test('session switching blocks racing prompts and preserves draft attachments', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-switch-gate-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const gate = createServer(); gate.listen(join(dir, 'gate')); await once(gate, 'listening');
  t.after(() => gate.close());
  const rows = [{ id: 'chosen', path: '/tmp/chosen.jsonl', cwd: '/tmp', firstMessage: 'Chosen', modified: 1, messageCount: 1 }];
  const app = await fixture(t, [
    { type: 'wait', command: 'switch_session', data: { cancelled: false }, after: [{ type: 'message_end', message: assistant('stale old reply') }] },
    { type: 'respond', command: 'get_state', data: { sessionId: 'chosen', sessionName: 'Chosen' } },
    { type: 'wait', command: 'prompt', echo: true },
  ], { KOA_FAKE_SESSION_GATE: join(dir, 'gate'), KOA_FAKE_SESSIONS: JSON.stringify(rows) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.deepEqual(await (await app.post('sessions/list', { scope: 'all' })).json(), { rows });
  const bytes = new Uint8Array([104, 105]);
  const pending = await (await app.post('attachments', { name: 'draft.txt', type: 'text/plain', size: bytes.length })).json();
  await fetch(app.base + `attachments/${pending.id}/0`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: bytes });
  const before = app.count();
  const connected = once(gate, 'connection');
  const chosen = rows[0]; assert.ok(chosen);
  const switched = app.post('sessions/switch', { path: chosen.path });
  const [socket] = await connected; t.after(() => socket.destroy());
  assert.equal((await app.post('prompt', { text: 'racing', mode: 'prompt', attachments: [] })).status, 409);
  assert.equal((await app.post('sessions/new')).status, 409);
  socket.end('go'); assert.equal((await switched).status, 200);
  assert.equal((await app.post('prompt', { text: 'draft', mode: 'prompt', attachments: [pending.id] })).status, 200);
  assert.ok(!JSON.stringify(app.records().slice(before)).includes('stale old reply'));
  assert.ok(!(await app.log()).some(record => record.type === 'prompt' && record.message === 'racing'));
});

test('a prompt body held across a completed switch cannot enter the new session', { timeout: 10000 }, async t => {
  const path = '/tmp/chosen.jsonl';
  const app = await fixture(t, [
    { type: 'wait', command: 'switch_session', data: { cancelled: false } },
    { type: 'respond', command: 'get_state', data: { sessionId: 'chosen' } },
  ], { KOA_FAKE_SESSIONS: JSON.stringify([{ path }]) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const body = JSON.stringify({ sessionId: 'fake', text: 'stale body', mode: 'prompt', attachments: [] });
  const held = request(app.base + 'prompt', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } });
  const response = new Promise<number | undefined>(resolve => {
    held.once('response', response => { response.resume(); response.once('end', () => resolve(response.statusCode)); });
  });
  held.write(body.slice(0, 20));
  t.after(() => held.destroy());
  assert.equal((await app.post('sessions/switch', { path })).status, 200);
  held.end(body.slice(20));
  assert.equal(await response, 409);
  assert.ok(!(await app.log()).some(record => record.type === 'prompt'));
});

test('a failed switch refresh clears old history and returns to a usable session', { timeout: 10000 }, async t => {
  const path = '/tmp/chosen.jsonl';
  const app = await fixture(t, [
    { type: 'respond', command: 'get_messages', data: { messages: [{ role: 'user', timestamp: 1, content: [{ type: 'text', text: 'old session history' }] }] } },
    { type: 'wait', command: 'switch_session', data: { cancelled: false } },
    { type: 'respond', command: 'get_state', data: { sessionId: 'chosen', sessionName: 'Chosen' } },
    { type: 'wait', command: 'get_messages', error: 'History unavailable' },
    { type: 'wait', command: 'prompt', echo: true },
  ], { KOA_FAKE_SESSIONS: JSON.stringify([{ path }]) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await app.post('sessions/switch', { path: '/tmp/not-a-fixture-session' })).status, 409);
  assert.equal((await app.post('sessions/switch', { path })).status, 200);
  await app.until(record => JSON.stringify(record).includes('History unavailable'));
  const state = app.records().filter(record => record.type === 'state').at(-1);
  assert.equal(state.pi.type, 'ready'); assert.equal(state.sessionId, 'chosen');
  assert.deepEqual(app.records().filter(record => record.type === 'reset').at(-1).items, []);
  assert.equal((await app.post('prompt', { text: 'fresh prompt', mode: 'prompt', attachments: [] })).status, 200);
});

test('startup failures release the view before exiting', { timeout: 5000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'koa-startup-failure-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await symlink(process.execPath, join(dir, 'node'));
  for (const args of [[], ['--pi', resolve('./koa-fake-pi.ts'), '--metrics', '/does-not-exist/metrics']]) {
    const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), '--browser', ...args], { env: { ...process.env, PATH: dir, ...(args.length ? {} : { KOA_UPLOAD_IDLE_MS: 'bad' }) }, stdio: 'pipe' });
    const close = once(child, 'close'); t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
    let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
    const [code] = await close; assert.equal(code, 1); assert.match(stderr, args.length ? /ENOENT/ : /KOA_UPLOAD_IDLE_MS/);
  }
});

test('page assets stay with the running program', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-page-install-');
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../koa'), join(dir, 'koa'), { recursive: true, filter: path => !path.includes('node_modules') });
  await symlink(resolve('../webview'), join(dir, 'webview'));
  await writeFile(join(dir, 'koa/page.html'), '<head><!-- style --></head><body>original<!-- script --></body>');
  await writeFile(join(dir, 'koa/page.css'), 'original-style');
  await writeFile(join(dir, 'koa/page.js'), 'original-script');
  const app = await fixture(t, [], { KOA_PAGE_RELOAD: '0' }, undefined, true, [], join(dir, 'koa/koa.ts'));
  const original = await (await fetch(app.base)).text();
  assert.match(original, /original-script/);
  await writeFile(join(dir, 'koa/page.html'), '<head><!-- style --></head><body>replacement<!-- script --></body>');
  await writeFile(join(dir, 'koa/page.js'), 'replacement-script');
  assert.equal(await (await fetch(app.base)).text(), original);
});

test('a listen failure closes the acquired view and pi', { timeout: 5000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-listen-failure-'); t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../../build/ko/share/ko/koa'), join(dir, 'koa'), { recursive: true });
  await mkdir(join(dir, 'webview'));
  const marker = join(dir, 'socket');
  await writeFile(join(dir, 'webview/index.ts'), `import {webview as real} from ${JSON.stringify(new URL('../webview/index.ts', import.meta.url).href)};import {writeFileSync} from 'node:fs';export async function webview(options){const view=await real(options);writeFileSync(${JSON.stringify(marker)},view.socketPath);writeFileSync(view.socketPath,'occupied');return view;}`);
  const child = spawn(process.execPath, [join(dir, 'koa/koa.ts'), '--browser', '--pi', resolve('./koa-fake-pi.ts')], { env: { ...process.env, KOA_PI_EXIT_MS: '30', KOA_FAKE_STUBBORN: '1' }, stdio: 'pipe' });
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'close'); assert.equal(code, 1); assert.match(stderr, /EADDRINUSE/);
  await assert.rejects(readFile(await readFile(marker, 'utf8')), { code: 'ENOENT' });
});

test('mutations refuse simple content types and browser path grants', { timeout: 10000 }, async t => {
  const app = await fixture(t, [], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
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

test('bash response waits for its release gate, not the RPC deadline', async t => {
  const source = await readFile(new URL('./koa.ts', import.meta.url), 'utf8');
  const body = stripTypeScriptTypes(source.slice(source.indexOf('class RpcTimeout'), source.indexOf('const RPC_RESPONSE_MS')) + source.slice(source.indexOf('function rpc('), source.indexOf('async function main(')));
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const child = Object.assign(new EventEmitter(), { exitCode: null, signalCode: null, stdin: Object.assign(new EventEmitter(), { destroyed: false, write: () => true, destroy() {} }), stdout: new EventEmitter() });
  const { link, RpcTimeout } = runInNewContext(body + '\n({link:rpc(child),RpcTimeout})', { child, Buffer, process, once, errorText: String, clearTimeout, later: (callback: () => void, delay: number) => setTimeout(callback, delay), RPC_RESPONSE_MS: 10000 });
  t.after(() => link.close());
  let ended = false;
  const bash = link.command({ type: 'bash', command: 'gated' }, { deadline: 'none' }).finally(() => { ended = true; });
  const ordinary = assert.rejects(link.command({ type: 'get_state' }), (error: unknown) => error instanceof RpcTimeout);
  await Promise.resolve();
  t.mock.timers.tick(10001);
  await ordinary;
  assert.equal(ended, false);
  child.stdout.emit('data', Buffer.from(JSON.stringify({ type: 'response', command: 'bash', id: '1', success: true, data: { output: 'released', cancelled: false, truncated: false } }) + '\n'));
  assert.equal((await bash).data.output, 'released');
});

test('bash output is bounded live, replaced by the result, and replayed once', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-bash-gate-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const server = createServer(); server.listen(join(dir, 'gate')); await once(server, 'listening'); t.after(() => server.close());
  const connected = once(server, 'connection');
  const app = await fixture(t, [
    { type: 'wait', command: 'bash', gate: join(dir, 'gate'), events: [{ type: 'bash_execution_update', delta: 'a'.repeat(32768) }, { type: 'bash_execution_update', delta: 'b'.repeat(32768) }], data: { output: 'authoritative final', exitCode: 3, cancelled: false, truncated: true, fullOutputPath: '/tmp/full' } },
    { type: 'wait', command: 'prompt', events: [{ type: 'compaction_end' }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await app.post('prompt', { text: '!gated', mode: 'prompt', attachments: [] })).status, 200);
  const [gate] = await connected; t.after(() => gate.destroy());
  const live = await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'running' && record.bash[0].output.cut > 0);
  assert.equal(live.bash[0].output.text, 'b'.repeat(16384)); assert.equal(live.bash[0].output.cut, 49152);
  gate.end('release');
  const completed = await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'completed');
  assert.deepEqual(completed.bash[0].result, { output: { text: 'authoritative final', cut: 0 }, exit: 3, cancelled: false, truncated: true, fullOutputPath: '/tmp/full' });
  await app.until(record => record.type === 'state' && record.bash?.length === 0);
  await app.until(record => record.type === 'reset' && JSON.stringify(record).includes('authoritative final'));
  const records = app.records(), completedIndex = records.indexOf(completed);
  const clearedIndex = records.findIndex((record, index) => index > completedIndex && record.type === 'state' && record.bash?.length === 0);
  const resetIndex = records.findIndex((record, index) => index > completedIndex && record.type === 'reset');
  assert.ok(clearedIndex > completedIndex && resetIndex > clearedIndex);
  const before = app.count(); await app.post('prompt', { text: 'rebuild', mode: 'prompt', attachments: [] });
  await app.until(record => record.type === 'reset', before);
  const stored = await (await fetch(app.base + 'items?before=99')).json();
  assert.equal(stored.items.length, 1); assert.equal(stored.items[0].result.output.text, 'authoritative final');
});

test('a late bash result cannot enter the switched session', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-session-bash-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const server = createServer(); server.listen(join(dir, 'gate')); await once(server, 'listening'); t.after(() => server.close());
  const connected = once(server, 'connection');
  const app = await fixture(t, [
    { type: 'wait', command: 'bash', gate: join(dir, 'gate'), data: { output: 'late old command output', exitCode: 0, cancelled: false, truncated: false }, after: [{ type: 'extension_ui_request', id: 'delivered', method: 'notify', message: 'late result delivered' }] },
    { type: 'wait', command: 'switch_session', data: { cancelled: false } },
    { type: 'respond', command: 'get_state', data: { sessionId: 'chosen', sessionName: 'Chosen' } },
    { type: 'respond', command: 'get_messages', data: { messages: [] } },
  ], { KOA_FAKE_SESSIONS: JSON.stringify([{ path: '/tmp/chosen.jsonl' }]) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await app.post('prompt', { text: '!old command', mode: 'prompt', attachments: [] });
  const [gate] = await connected; t.after(() => gate.destroy());
  await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'running');
  assert.equal((await app.post('sessions/switch', { path: '/tmp/chosen.jsonl' })).status, 200);
  const ready = await app.until(record => record.type === 'state' && record.sessionId === 'chosen' && record.pi.type === 'ready');
  assert.deepEqual(ready.bash, []);
  const before = app.count(); gate.end('release');
  await app.until(record => record.type === 'item' && record.item.kind === 'notify' && record.item.text.text === 'late result delivered', before);
  assert.equal(JSON.stringify(app.records().slice(before)).includes('late old command output'), false);
  assert.deepEqual(app.records().findLast(record => record.type === 'state')?.bash, []);
  assert.equal(JSON.stringify(await (await fetch(app.base + 'items?before=99')).json()).includes('late old command output'), false);
});

test('a resumed bash message has one stored item and no running state', { timeout: 5000 }, async t => {
  const message = { role: 'bashExecution', command: 'saved', output: 'saved output', exitCode: 0, cancelled: false, truncated: true, fullOutputPath: '/tmp/saved-output', excludeFromContext: true, timestamp: 42 };
  const app = await fixture(t, [{ type: 'respond', command: 'get_messages', data: { messages: [message] } }], {}, undefined, true, ['--session', '/tmp/saved-session'], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const page = await (await fetch(app.base + 'items?before=99')).json();
  assert.equal(page.items.length, 1);
  assert.deepEqual(page.items[0], { seq: 0, revision: 0, at: 42, final: true, kind: 'bash', command: 'saved', result: { output: { text: 'saved output', cut: 0 }, exit: 0, cancelled: false, truncated: true, fullOutputPath: '/tmp/saved-output' }, excludeFromContext: true });
  const ready = app.records().findLast(record => record.type === 'state');
  assert.deepEqual(ready?.bash, []);
});

test('a second abort reaches the turn while bash cancellation is still pending', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-bash-cancel-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const server = createServer(); server.listen(join(dir, 'gate')); await once(server, 'listening'); t.after(() => server.close());
  const connected = once(server, 'connection');
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', events: [{ type: 'agent_start' }] },
    { type: 'wait', command: 'bash', gate: join(dir, 'gate'), data: { output: 'kept output', cancelled: false, truncated: false } },
    { type: 'wait', command: 'abort', events: [{ type: 'agent_settled', aborted: true }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await app.post('prompt', { text: 'turn', mode: 'prompt', attachments: [] });
  await app.post('prompt', { text: '!slow cleanup', mode: 'prompt', attachments: [] });
  const [gate] = await connected; t.after(() => gate.destroy());
  await app.post('abort');
  await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'cancelling');
  await app.post('abort');
  const settled = await app.until(record => record.type === 'state' && !record.working && record.bash?.[0]?.phase === 'cancelling');
  assert.equal(settled.bash.length, 1);
  assert.deepEqual((await app.log()).filter(record => ['abort', 'abort_bash'].includes(record.type)).map(record => record.type), ['abort_bash', 'abort']);
  assert.equal((await app.log()).filter(record => record.type === 'get_messages').length, 1);
  const before = app.count(); gate.end('finished');
  await app.until(record => record.type === 'state' && record.bash?.length === 0, before);
  await app.until(record => record.type === 'reset', before);
  const page = await (await fetch(app.base + 'items?before=99')).json();
  assert.equal(page.items[0].result.cancelled, true); assert.equal(page.items[0].result.output.text, 'kept output');
});

test('an idle compaction rebuild clears its completed command before stored replay', { timeout: 7000 }, async t => {
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', events: [{ type: 'compaction_start' }] },
    { type: 'wait', command: 'bash', data: { output: 'saved during compaction', exitCode: 0, cancelled: false, truncated: false } },
    { type: 'wait', command: 'prompt', events: [{ type: 'compaction_end' }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await app.post('prompt', { text: 'compact', mode: 'prompt', attachments: [] });
  await app.post('prompt', { text: '!echo saved', mode: 'prompt', attachments: [] });
  await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'completed');
  const before = app.count(); await app.post('prompt', { text: 'finish compaction', mode: 'prompt', attachments: [] });
  await app.until(record => record.type === 'reset', before);
  const records = app.records().slice(before);
  const cleared = records.findIndex(record => record.type === 'state' && !record.working && record.bash?.length === 0);
  assert.ok(cleared >= 0 && cleared < records.findIndex(record => record.type === 'reset'), 'completed command must clear before reset');
  const page = await (await fetch(app.base + 'items?before=99')).json();
  const commands = page.items.filter((item: { kind: string }) => item.kind === 'bash');
  assert.equal(commands.length, 1); assert.equal(commands[0].command, 'echo saved');
});

test('sequential commands during a turn keep acceptance order and enforce the pending budget', { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', events: [{ type: 'agent_start' }] },
    ...Array.from({ length: 16 }, (_, index) => ({ type: 'wait', command: 'bash', data: { output: String(index), exitCode: 0, cancelled: false, truncated: false }, after: [{ type: 'session_info_changed', name: 'command ' + index }] })),
    { type: 'wait', command: 'abort', events: [{ type: 'agent_settled', aborted: true }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await app.post('prompt', { text: 'turn', mode: 'prompt', attachments: [] });
  for (let index = 0; index < 16; index++) {
    assert.equal((await app.post('prompt', { text: '!echo ' + index, mode: 'prompt', attachments: [] })).status, 200);
    await app.until(record => record.type === 'state' && record.bash?.length === index + 1 && record.bash[index].phase === 'completed');
  }
  const pending = app.records().findLast(record => record.type === 'state');
  assert.deepEqual(pending?.bash.map((item: { command: string }) => item.command), Array.from({ length: 16 }, (_, index) => 'echo ' + index));
  const refused = await app.post('prompt', { text: '!echo 17', mode: 'prompt', attachments: [] });
  assert.equal(refused.status, 409); assert.deepEqual(await refused.json(), { error: 'too many commands wait for the turn to end' });
  await app.until(record => record.type === 'state' && record.name === 'command 15');
  const before = app.count(); await app.post('abort');
  await app.until(record => record.type === 'state' && record.bash?.length === 0, before);
  await app.until(record => record.type === 'reset', before);
  const page = await (await fetch(app.base + 'items?before=99')).json();
  assert.equal(page.items.length, 16); assert.deepEqual(page.items.map((item: { command: string }) => item.command), pending?.bash.map((item: { command: string }) => item.command));
});

test('bang commands run outside the prompt queue and stream until cancelled', { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', events: [{ type: 'agent_start' }] },
    { type: 'wait', command: 'bash', events: [{ type: 'bash_execution_update', delta: 'live output' }], data: { output: 'final output', exitCode: 0, cancelled: false, truncated: true, fullOutputPath: '/tmp/full' }, gate: true },
    { type: 'wait', command: 'abort', events: [{ type: 'agent_settled', aborted: true }] },
    { type: 'wait', command: 'bash', data: { output: 'quiet', exitCode: 0, cancelled: false, truncated: false } },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await app.post('prompt', { text: 'go', mode: 'prompt', attachments: [] });
  assert.equal((await app.post('prompt', { text: '! echo hi', mode: 'prompt', attachments: ['missing'] })).status, 409);
  assert.equal((await app.post('prompt', { text: '! echo hi', mode: 'follow_up', attachments: [] })).status, 200);
  await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'running' && record.bash[0].output.text === 'live output');
  assert.equal((await app.post('prompt', { text: '! other', mode: 'prompt', attachments: [] })).status, 409);
  await app.post('abort');
  await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'completed' && record.bash[0].result.cancelled === true);
  await app.post('abort');
  await app.until(record => record.type === 'state' && record.working === false && record.bash?.length === 0);
  const quiet = app.count();
  assert.equal((await app.post('prompt', { text: '!! quiet', mode: 'prompt', attachments: [] })).status, 200);
  await app.until(record => record.type === 'state' && record.bash?.[0]?.phase === 'completed' && record.bash[0].result.output.text === 'quiet', quiet);
  await app.until(record => record.type === 'state' && record.bash?.length === 0 && record.working === false, quiet);
  let stored: { items: { kind: string; command: string }[] } = { items: [] };
  await pollUntil(async () => { stored = await (await fetch(app.base + 'items?before=99')).json(); return stored.items.some(item => item.kind === 'bash' && item.command === 'quiet'); });
  assert.deepEqual(stored.items.filter((item: { kind: string }) => item.kind === 'bash').map((item: { command: string }) => item.command), ['echo hi', 'quiet']);
  const log = await app.log();
  assert.deepEqual(log.filter(record => record.type === 'bash').map(({ command, excludeFromContext }) => ({ command, excludeFromContext })), [{ command: 'echo hi', excludeFromContext: false }, { command: 'quiet', excludeFromContext: true }]);
  assert.equal(log.filter(record => record.type === 'prompt').length, 1);
  assert.equal(log.some(record => record.type === 'abort_bash'), true);
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
