import assert from 'node:assert/strict';
import { test, type TestContext } from 'node:test';
import { createServer, request } from 'node:http';
import { once } from 'node:events';
import { mkdtempSync, rmSync, existsSync, writeFileSync, appendFileSync, renameSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { attachments, fileResponse } from './koa-attach.ts';
import { connect } from 'node:net';
import { pollUntil } from '../pi/ko-pi-fixture.ts';

test('a file response keeps its validated descriptor and byte boundary', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'koa-file-response-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'file.txt'); writeFileSync(path, 'original');
  const server = createServer((_request, response) => {
    response.on('pipe', () => { appendFileSync(path, 'growth'); renameSync(path, path + '.old'); writeFileSync(path, 'replacement'); });
    void fileResponse(response, path);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); });
  const address = server.address(); assert.ok(address && typeof address !== 'string');
  const socket = connect(address.port, '127.0.0.1'), chunks: Buffer[] = [];
  socket.on('data', chunk => chunks.push(chunk)); socket.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n');
  await once(socket, 'end');
  const wire = Buffer.concat(chunks).toString(); assert.equal(wire.slice(wire.indexOf('\r\n\r\n') + 4), 'original');
});

async function fixture(t: TestContext, idleMs: number) {
  const dir = mkdtempSync(join(tmpdir(), 'koa-upload-cleanup-'));
  const store = attachments(join(dir, 'attachments'), idleMs);
  const server = createServer((req, res) => { void store.handle(req, res, true); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { store.close(); server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); rmSync(dir, { recursive: true, force: true }); });
  const address = server.address(); assert.ok(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}/attachments`;
  return { base, create: (size: number) => fetch(base, { method: 'POST', body: JSON.stringify({ name: 'file', type: '', size }) }) };
}

test('an aborted chunk releases its file and reserved bytes', { timeout: 10000 }, async t => {
  const app = await fixture(t, 60000);
  const size = 64 * 1024 * 1024;
  const file = await (await app.create(size)).json();
  for (let i = 0; i < 3; i++) assert.equal((await app.create(size)).status, 200);
  assert.equal((await app.create(1)).status, 409);
  const chunk = request(app.base + '/' + file.id + '/0', { method: 'POST', headers: { 'Content-Length': 4, Expect: '100-continue' } });
  chunk.on('error', () => {}); chunk.flushHeaders(); await once(chunk, 'continue');
  await new Promise<void>(resolve => chunk.write(Buffer.from([1]), () => resolve()));
  chunk.destroy();
  await pollUntil(async () => (await app.create(size)).status === 200, 1000, 'aborted upload budget recovered');
  assert.equal(existsSync(file.path), false);
  assert.equal((await fetch(app.base + '/' + file.id)).status, 404);
});

test('a stalled upload expires and releases all sixteen slots', { timeout: 10000 }, async t => {
  const app = await fixture(t, 100);
  const paths: string[] = [];
  for (let i = 0; i < 16; i++) { const response = await app.create(0); assert.equal(response.status, 200); paths.push((await response.json()).path); }
  assert.equal((await app.create(0)).status, 409);
  await pollUntil(async () => (await app.create(0)).status === 200, 1000, 'stalled upload slots recovered');
  await pollUntil(async () => paths.every(path => !existsSync(path)), 1000, 'all stalled files removed');
  for (let i = 0; i < 15; i++) assert.equal((await app.create(0)).status, 200);
  assert.equal((await app.create(0)).status, 409);
});
