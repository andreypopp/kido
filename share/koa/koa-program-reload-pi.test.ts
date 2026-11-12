import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import type { RpcResponse } from '@earendil-works/pi-coding-agent';
import { koaChannel } from './koa-channel.ts';
import { stopChild } from './koa-program-fixture.ts';

test('koa-reload reloads the extensions of one real pi process', { timeout: 20000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-reload-pi-');
  const cwd = join(dir, 'project'), sessions = join(dir, 'sessions'), agent = join(dir, 'agent'), probe = join(dir, 'probe.ts');
  await Promise.all([cwd, sessions, agent].map(path => mkdir(path)));
  const write = (description: string) => writeFile(probe, `export default function (pi) { pi.registerCommand('probe', { description: '${description}', handler: async () => {} }); }\n`);
  await write('first');
  const child = spawn(process.execPath, [resolve('node_modules/@earendil-works/pi-coding-agent/dist/cli.js'), '--mode', 'rpc', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--session-dir', sessions, '--extension', resolve('ko-pi.ts'), '--extension', resolve('../koa/koa-sessions.ts'), '--extension', probe, '--harness', 'koa'], { cwd, env: { ...process.env, HOME: dir, PI_CODING_AGENT_DIR: agent }, stdio: ['pipe', 'pipe', 'pipe', 'pipe'] });
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  const closed = once(child, 'close');
  const channel = koaChannel(child.stdio[3]);
  const lines = createInterface({ input: child.stdout });
  t.after(async () => { channel.close(); lines.close(); await stopChild(child, closed); await rm(dir, { recursive: true, force: true }); });
  let serial = 0;
  const command = async (value: object) => {
    const id = String(++serial);
    const result = new Promise<RpcResponse>(resolve => {
      const receive = (line: string) => { const reply = JSON.parse(line); if (reply.type === 'response' && reply.id === id) { lines.off('line', receive); resolve(reply); } };
      lines.on('line', receive);
    });
    child.stdin.write(JSON.stringify({ ...value, id }) + '\n');
    const reply = await result;
    assert.ok(reply.success, stderr + JSON.stringify(reply));
    return 'data' in reply ? reply.data : undefined;
  };
  const description = async () => {
    const result = await command({ type: 'get_commands' });
    assert.ok(result && 'commands' in result);
    return result.commands.find((entry: { name: string; description?: string }) => entry.name === 'probe')?.description;
  };
  const initial = await command({ type: 'get_state' });
  assert.ok(initial && 'sessionId' in initial);
  assert.equal(await description(), 'first');
  assert.deepEqual(await channel.restartState(channel.signal()), { type: 'ready' });
  const before = channel.generation;
  await write('second');
  assert.deepEqual(await command({ type: 'prompt', message: '/koa-reload' }), { disposition: 'handled' });
  assert.equal(await description(), 'second');
  assert.ok((await channel.current(initial.sessionId, before)).generation > before);
  assert.equal(child.exitCode, null);
  assert.deepEqual(await channel.restartState(channel.signal()), { type: 'ready' });
});
