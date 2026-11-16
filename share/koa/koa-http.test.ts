import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { test } from 'node:test';
import { afterReply, respond } from './koa-http.ts';

test('shutdown waits for the peer to consume the reply and close', { timeout: 5000 }, async () => {
  let stopped = () => {};
  const shutdown = new Promise<void>(resolve => { stopped = resolve; });
  const server = createServer((_request, response) => {
    afterReply(response, 4000, () => { server.closeAllConnections(); stopped(); });
    respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'reload' } }));
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  const socket = connect({ port: address.port, host: '127.0.0.1', allowHalfOpen: true });
  let reply = '';
  const closed = new Promise<void>((resolve, reject) => {
    socket.on('data', bytes => { reply += bytes; if (reply.endsWith('\r\n0\r\n\r\n')) socket.end(); });
    socket.on('end', () => socket.end());
    socket.on('close', () => resolve());
    socket.on('error', reject);
  });
  try {
    socket.write('POST /restart HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n');
    await shutdown;
    assert.match(reply, /"action":\{"type":"reload"\}/, 'shutdown cut the connection before the peer consumed the reply');
    await closed;
    assert.match(reply, /"action":\{"type":"reload"\}/);
  } finally {
    socket.destroy();
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
