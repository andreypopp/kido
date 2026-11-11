import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { createServer } from "node:net";
import { pollUntil } from "../pi/ko-pi-fixture.ts";
import { fixture } from "./koa-program-fixture.ts";
test('bang completion asks the child for its cwd and returns shell replacements', { timeout: 7000 }, async t => {
  const cwd = await mkdtemp('/tmp/koa-tab-context-');
  t.after(() => rm(cwd, { recursive: true, force: true }));
  await writeFile(join(cwd, 'bridge-file'), '');
  const app = await fixture(t, [{ type: 'wait', command: 'prompt' }], { KOA_FAKE_COMPLETION_CONTEXT: JSON.stringify({ type: 'host', cwd }) }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const started = performance.now();
  const response = await app.post('complete', { text: '!!cat bridge-', pos: 13 });
  t.diagnostic(`One host Tab, HTTP + context bridge + Bash: ${(performance.now() - started).toFixed(1)} ms`);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.type, 'shell'); assert.equal(result.from, 6); assert.equal(result.to, 13);
  assert.deepEqual(result.options, [{ label: 'bridge-file', insert: 'bridge-file ' }]);
  assert.equal((await app.log()).some(row => row.type === 'bash'), false);
  const stale = await app.post('complete', { sessionId: 'previous', text: '!!cat bridge-', pos: 13 });
  assert.equal(stale.status, 409);
  assert.deepEqual(await stale.json(), { error: 'pi session changed' });
});

test("--help prints usage without starting pi or a webview", { timeout: 5000 }, async () => {
  const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), '--help', '--pi', '/does-not-exist'], { env: { PATH: '' }, stdio: 'pipe' });
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

test('resume requires a terminal before starting a webview', { timeout: 5000 }, async t => {
  const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), '--browser', '--resume', '--pi', resolve('../koa/koa-fake-pi.ts')], { stdio: 'pipe' });
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'close');
  assert.equal(code, 1);
  assert.match(stderr, /resume requires a terminal/);
  assert.doesNotMatch(stderr, /koa: http:/);
});

test('resume selects before the browser, cancels, and reports a broken picker', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-resume-');
  const log = join(dir, 'log'), urls = join(dir, 'urls'), script = join(dir, 'steps');
  const server = createServer();
  const children = new Set<ReturnType<typeof spawn>>();
  const sockets = new Set<import('node:net').Socket>();
  server.on('connection', socket => { sockets.add(socket); socket.on('error', (error: NodeJS.ErrnoException) => { if (error.code !== 'ECONNRESET') throw error; }); socket.once('close', () => sockets.delete(socket)); });
  t.after(async () => {
    for (const child of children) child.kill('SIGTERM');
    for (const socket of sockets) socket.destroy();
    server.close();
    await rm(dir, { recursive: true, force: true });
  });
  server.listen(join(dir, 'gate')); await once(server, 'listening');
  await writeFile(script, '{"type":"wait","command":"prompt"}\n{"type":"exit","code":0}\n');
  await writeFile(join(dir, process.platform === 'darwin' ? 'open' : 'xdg-open'), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  const readLog = async () => (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  const chosen = join(dir, 'chosen.jsonl');
  for (const item of [
    { gate: JSON.stringify({ type: 'selected', path: chosen }), code: 0, output: /koa: http:/ },
    { gate: '{"type":"cancel"}', code: 0, output: /No session selected/ },
    { gate: 'exit', code: 1, output: /fake-pi-resume-1.*session picker exited without a result/ },
    { gate: 'rpc', code: 1, output: /fake-pi-resume-1.*session picker did not become ready/ },
    { gate: 'eof', code: 1, output: /fake-pi-resume-1.*session picker exited without a result/ },
    { gate: 'signal', code: 1, output: /session picker interrupted by SIGTERM/ },
    { gate: 'skip', code: 0, output: /koa: http:/ },
  ]) {
    await writeFile(log, ''); await rm(urls, { force: true });
    await writeFile(script, (item.gate.startsWith('{"type":"selected"') ? '{"type":"wait","command":"prompt"}\n' : '') + '{"type":"wait","command":"prompt"}\n{"type":"exit","code":0}\n');
    const connected = once(server, 'connection');
    const pass = item.gate === 'skip' ? ['--resume', '--session', 'existing.jsonl'] : ['--resume', '-r', '--session-dir', dir, '--', 'prompt'];
    const child = spawn(process.execPath, ['--import', resolve('../koa/koa-fake-tty.ts'), resolve('../../build/ko/share/ko/koa/koa.ts'), '--browser', '--pi', resolve('../koa/koa-fake-pi.ts'), ...pass], { stdio: 'pipe', env: { ...process.env, KO_PANE: '', KOA_FAKE_LOG: log, KOA_FAKE_SCRIPT: script, KOA_FAKE_PICKER_GATE: join(dir, 'gate'), KOA_RESUME_READY_MS: '1000', OPEN_LOG: urls, PATH: `${dir}:${process.env.PATH}` } });
    children.add(child);
    let output = ''; child.stdout.on('data', bytes => { output += bytes; }); child.stderr.on('data', bytes => { output += bytes; });
    const closed = once(child, 'close');
    const [gate] = await Promise.race([connected, closed.then(() => { throw new Error(output); })]);
    assert.deepEqual((await readLog()).map(record => record.type), ['picker']);
    assert.doesNotMatch(output, /koa: http:/);
    await assert.rejects(readFile(urls), { code: 'ENOENT' });
    gate.end(item.gate);
    if (item.gate === 'signal') child.kill('SIGTERM');
    if (item.gate === 'skip' || item.gate.startsWith('{"type":"selected"')) {
      await pollUntil(async () => (await readLog()).some(record => record.type === 'get_state'));
      const argv = (await readLog()).find(record => record.type === 'argv').args;
      const expected = [...pass];
      if (item.gate !== 'skip') expected.splice(expected.indexOf('--'), 0, '--session', chosen);
      assert.deepEqual(argv.slice(argv.indexOf('--harness') + 2), expected);
      await pollUntil(async () => { try { return (await readFile(urls, 'utf8')).startsWith('http:'); } catch { return false; } });
      const base = output.match(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/)?.[1]; assert.ok(base, output);
      await fetch(base + 'prompt', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionId: 'fake', text: 'exit', mode: 'prompt', attachments: [] }) });
    }
    assert.equal((await closed)[0], item.code, output);
    children.delete(child);
    assert.match(output, item.output);
    if (item.gate === 'signal') {
      assert.ok((await readLog()).some(record => record.type === 'picker_signal' && record.signal === 'SIGTERM'));
      assert.ok((await readLog()).some(record => record.type === 'picker_exit'));
    }
    if (!output.includes('koa: http:')) await assert.rejects(readFile(urls), { code: 'ENOENT' });
  }
});
test('startup refuses incompatible flags before opening a webview', { timeout: 10000 }, async () => {
  for (const args of [['--mode','text'], ['-p'], ['--export','out.html'], ['--list-models'], ['-v'], ['--tui-mode','fullscreen'], ['--theme','dark'], ['--use-theme','dark'], ['--no-themes'], ['@notes.txt']]) {
    const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), '--browser', '--pi', resolve('../koa/koa-fake-pi.ts'), ...args]);
    let output = ''; child.stderr.on('data', bytes => { output += bytes; });
    const [code] = await once(child, 'close');
    assert.equal(code, 1, output);
    assert.match(output, /koa: /);
    assert.doesNotMatch(output, /koa: http:/);
  }
});

test('startup messages run separately after readiness without a page connection', { timeout: 10000 }, async t => {
  const f = await fixture(t, [
    { type: 'wait', command: 'prompt', after: [{ type: 'agent_settled', aborted: false }] },
    { type: 'wait', command: 'prompt', after: [{ type: 'agent_settled', aborted: false }] },
    { type: 'exit', code: 1 },
  ], {}, undefined, true, ['--', 'first', '--help'], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await pollUntil(async () => (await f.log()).filter(value => value.type === 'prompt').length === 2);
  assert.deepEqual((await f.log()).filter(value => value.type === 'prompt').map(value => value.message), ['first', '--help']);
  await f.until(record => record.type === 'state' && record.pi?.type === 'exited');
  assert.equal((await f.post('pi/start')).status, 200);
  assert.equal((await f.log()).filter(value => value.type === 'prompt').length, 2);
});

test('startup handled commands continue and agent_end does not release a retry', { timeout: 10000 }, async t => {
  const f = await fixture(t, [
    { type: 'wait', command: 'prompt', data: { disposition: 'handled' } },
    { type: 'wait', command: 'prompt', events: [{ type: 'agent_start' }, { type: 'agent_end', messages: [] }] },
    { type: 'wait', command: 'get_commands', data: { commands: [] }, after: [{ type: 'agent_settled', aborted: false }] },
    { type: 'wait', command: 'prompt', after: [{ type: 'agent_settled', aborted: false }] },
  ], {}, undefined, true, ['--', '/extension', 'retry', 'last'], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await pollUntil(async () => (await f.log()).filter(value => value.type === 'prompt').length >= 2);
  assert.deepEqual((await f.log()).filter(value => value.type === 'prompt').map(value => value.message), ['/extension', 'retry']);
  assert.equal((await f.post('complete', { text: '/', pos: 1 })).status, 200);
  await pollUntil(async () => (await f.log()).filter(value => value.type === 'prompt').length === 3);
  assert.deepEqual((await f.log()).filter(value => value.type === 'prompt').map(value => value.message), ['/extension', 'retry', 'last']);
});
