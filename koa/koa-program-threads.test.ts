import assert from 'node:assert/strict';
import { test } from 'node:test';
import { realFixture } from './koa-program-fixture.ts';
import { ofType } from './koa-agent-fixture.ts';

test('threaded queues preserve full identity and slash commands dispatch unchanged', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: '[thread: work]\nDone', gate: 'hold' }], extensions: { 'command.ts': `export default pi => pi.registerCommand('probe', {description:'probe',handler:(_args,ctx)=>ctx.ui.notify('command dispatched','info')});` } });
  assert.equal((await app.post('prompt', { text: 'begin', mode: 'prompt', attachments: [], thread: 'work' })).status, 200);
  await app.until(ofType('state', record => record.working));
  for (const thread of ['one', 'two']) assert.equal((await app.post('prompt', { text: 'same', mode: 'follow_up', attachments: [], thread })).status, 200);
  const queued = await app.until(ofType('state', record => record.queue.followUp.length === 2));
  assert.deepEqual(queued.queue.followUp.map(entry => [entry.text, entry.thread]), [['same', 'one'], ['same', 'two']]);
  assert.equal((await app.post('queue/remove', { kind: 'follow-up', index: 0, text: 'same', thread: 'two' })).status, 409);
  assert.equal((await app.post('queue/remove', { kind: 'follow-up', index: 0, text: 'same', thread: 'one' })).status, 200);
  const restored = await (await app.post('queue/clear')).json();
  assert.deepEqual(restored.followUp, [{ text: 'same', attachments: [], thread: 'two' }]);
  const command = await (await app.post('prompt', { text: '/probe', mode: 'prompt', attachments: [], thread: 'work' })).json();
  assert.equal(command.disposition, 'handled');
  await app.until(ofType('item', record => record.item.kind === 'notify' && record.item.text.text === 'command dispatched'));
  app.provider.release('hold');
});

test('root prompt threads reach pi, state and sparse history without marker text', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: '[thread: work]\n**First summary**\nBody\n[thread: other]\nOther summary' }] });
  const response = await app.post('prompt', { text: 'hello', mode: 'prompt', attachments: [], thread: 'work' });
  assert.equal(response.status, 200);
  const user = await app.until(ofType('item', record => record.item.kind === 'user'));
  assert.equal(user.item.kind === 'user' ? user.item.thread : undefined, 'work');
  assert.equal(user.item.kind === 'user' ? user.item.text : undefined, 'hello');
  const state = await app.until(ofType('state', record => !record.working && 'threads' in record && record.threads.length === 2));
  assert.equal(state.view.type, 'root'); assert.ok('threads' in state);
  assert.deepEqual(state.threads.map(thread => [thread.name, thread.last?.summary]), [['work', '**First summary**'], ['other', 'Other summary']]);
  assert.ok(state.threads.every(thread => typeof thread.last?.at === 'number'));
  const page = await (await fetch(app.url('items?before=' + Number.MAX_SAFE_INTEGER + '&thread=other'))).json();
  assert.equal(page.more, false);
  assert.equal(page.items.some((item: { kind: string }) => item.kind === 'user'), false);
  assert.equal((await app.post('prompt', { text: 'bad', mode: 'prompt', attachments: [], thread: 'BAD' })).status, 400);
});
