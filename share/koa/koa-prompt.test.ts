import assert from 'node:assert/strict';
import { test } from 'node:test';
import { prompts } from './koa-queue.ts';
import type { Attachment } from './records.ts';

const a: Attachment = { id: 'a', name: 'a.png', path: '/tmp/a.png', origin: 'upload', kind: 'image', mimeType: 'image/png', size: 1 };
const b: Attachment = { ...a, id: 'b', name: 'b.png', path: '/tmp/b.png' };

test('equal prompt texts follow pi queue mode, not submission order', () => {
  const queue = prompts();
  queue.add('same', 'followUp', [a]); queue.add('same', 'steer', [b]);
  queue.update({ steering: [], followUp: ['same'] });
  queue.update({ steering: ['same'], followUp: ['same'] });
  queue.update({ steering: [], followUp: ['same'] });
  assert.deepEqual(queue.start('same'), [b]);
  queue.update({ steering: [], followUp: [] });
  assert.deepEqual(queue.start('same'), [a]);
  queue.add('', 'followUp', [a]); queue.add('', 'steer', [b]);
  assert.deepEqual(queue.start(''), [b]); assert.deepEqual(queue.start(''), [a]);
});

test('delivered empty texts do not remain in the queue or return in take-back', () => {
  const queue = prompts();
  queue.add('', 'followUp', [a]); queue.update({ steering: [], followUp: [''] });
  queue.add('', 'steer', [b]); queue.update({ steering: [''], followUp: [''] });
  assert.deepEqual(queue.start(''), [b]);
  assert.deepEqual(queue.view(), { steering: [], followUp: [{ text: '', attachments: [a] }] });
  assert.deepEqual(queue.start(''), [a]);
  assert.deepEqual(queue.view(), { steering: [], followUp: [] });
  queue.beginClear();
  assert.deepEqual(queue.takeBack({ steering: [''], followUp: [''] }), { steering: [], followUp: [] });
  queue.endClear();
  queue.add('', 'steer', [a]); queue.update({ steering: [''], followUp: ['external'] });
  queue.update({ steering: [], followUp: ['external'] });
  assert.deepEqual(queue.start(''), [a]);
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
  assert.deepEqual(queue.start('same'), [a]);
});
