import assert from 'node:assert/strict';
import { test } from 'node:test';
import { prompts } from './koa-queue.ts';
import { bashCommand, decodePrompt, threadPrompt } from './prompt.ts';
import { parseThreadName } from './records.ts';

test('thread prompts hide their marker and retain attachment identity in queues', () => {
  const one = parseThreadName('one'); assert.ok(one);
  const two = parseThreadName('two'); assert.ok(two);
  assert.equal(threadPrompt('[thread: one]\nhello', two), '[thread: two]\nhello');
  assert.deepEqual(decodePrompt('[thread: one]\nhello\n/tmp/a', [{ id: 'f', name: 'a', path: '/tmp/a', kind: 'file', size: 1 }], 'root'), { text: 'hello', thread: one });
  assert.deepEqual(decodePrompt('[thread: one]\nhello', [], 'subagent'), { text: '[thread: one]\nhello' });
  const queue = prompts('root');
  queue.add(threadPrompt('same', one), 'steer', []); queue.add(threadPrompt('same', two), 'steer', []);
  queue.update({ steering: [threadPrompt('same', one), threadPrompt('same', two)], followUp: [] });
  assert.deepEqual(queue.view().steering, [{ text: 'same', thread: one, attachments: [] }, { text: 'same', thread: two, attachments: [] }]);
  assert.deepEqual(queue.takeBack({ steering: [threadPrompt('same', two)], followUp: [] }).steering, [{ text: 'same', thread: two, attachments: [] }]);
});

test('bang commands keep shell text and context choice', () => {
  assert.deepEqual(bashCommand('! echo hi'), { command: 'echo hi', excludeFromContext: false, prefixLength: 1 });
  assert.deepEqual(bashCommand('!!echo hi\nnext'), { command: 'echo hi\nnext', excludeFromContext: true, prefixLength: 2 });
  assert.deepEqual(bashCommand('!'), { command: '', excludeFromContext: false, prefixLength: 1 });
  assert.equal(bashCommand('hello ! echo'), undefined);
});
import type { Attachment } from './koa-records.ts';

const a: Attachment = { id: 'a', name: 'a.png', path: '/tmp/a.png', kind: 'image', mimeType: 'image/png', size: 1 };
const b: Attachment = { ...a, id: 'b', name: 'b.png', path: '/tmp/b.png' };

test('equal prompt texts follow pi queue mode, not submission order', () => {
  const queue = prompts();
  queue.add('same', 'followUp', [a]); queue.add('same', 'steer', [b]);
  queue.update({ steering: [], followUp: ['same'] });
  queue.update({ steering: ['same'], followUp: ['same'] });
  queue.update({ steering: [], followUp: ['same'] });
  assert.deepEqual((queue.start('same')?.attachments ?? []), [b]);
  queue.update({ steering: [], followUp: [] });
  assert.deepEqual((queue.start('same')?.attachments ?? []), [a]);
  queue.add('', 'followUp', [a]); queue.add('', 'steer', [b]);
  assert.deepEqual((queue.start('')?.attachments ?? []), [b]); assert.deepEqual((queue.start('')?.attachments ?? []), [a]);
});

test('delivered empty texts do not remain in the queue or return in take-back', () => {
  const queue = prompts();
  queue.add('', 'followUp', [a]); queue.update({ steering: [], followUp: [''] });
  queue.add('', 'steer', [b]); queue.update({ steering: [''], followUp: [''] });
  assert.deepEqual((queue.start('')?.attachments ?? []), [b]);
  assert.deepEqual(queue.view(), { steering: [], followUp: [{ text: '', attachments: [a] }] });
  assert.deepEqual((queue.start('')?.attachments ?? []), [a]);
  assert.deepEqual(queue.view(), { steering: [], followUp: [] });
  queue.beginClear();
  assert.deepEqual(queue.takeBack({ steering: [''], followUp: [''] }), { steering: [], followUp: [] });
  queue.endClear();
  queue.add('', 'steer', [a]); queue.update({ steering: [''], followUp: ['external'] });
  queue.update({ steering: [], followUp: ['external'] });
  assert.deepEqual((queue.start('')?.attachments ?? []), [a]);
  queue.add('', 'steer', [b]); queue.update({ steering: [''], followUp: ['external'] });
  assert.deepEqual(queue.view(), { steering: [{ text: '', attachments: [b] }], followUp: [{ text: 'external', attachments: [] }] });
});

test('a delivering duplicate is not in the visible queue or taken back', () => {
  const queue = prompts();
  queue.add('same', 'steer', [a]); queue.add('same', 'steer', [b]);
  queue.update({ steering: ['same', 'same'], followUp: [] });
  queue.update({ steering: ['same'], followUp: [] });
  assert.deepEqual(queue.view(), { steering: [{ text: 'same', attachments: [b] }], followUp: [] });
  queue.beginClear(); queue.update({ steering: [], followUp: [] });
  assert.deepEqual(queue.takeBack({ steering: ['same'], followUp: [] }), { steering: [{ text: 'same', attachments: [b] }], followUp: [] });
  queue.endClear();
  assert.deepEqual((queue.start('same')?.attachments ?? []), [a]);
});
