import assert from 'node:assert/strict';
import { test } from 'node:test';
import { prompts } from './koa-queue.ts';
import { bashCommand, decodePrompt, topicPrompt } from './prompt.ts';
import { parseTopicName } from './records.ts';

test('topic prompts hide their marker and retain attachment identity in queues', () => {
  const one = parseTopicName('one'); assert.ok(one);
  const two = parseTopicName('two'); assert.ok(two);
  assert.equal(topicPrompt('[topic: one]\nhello', two), '[topic: two]\nhello');
  assert.deepEqual(decodePrompt('[topic: one]\nhello\n/tmp/a', [{ id: 'f', name: 'a', path: '/tmp/a', kind: 'file', size: 1 }], 'root'), { text: 'hello', topic: one });
  assert.deepEqual(decodePrompt('[topic: one]\nhello', [], 'subagent'), { text: '[topic: one]\nhello' });
  const queue = prompts('root');
  queue.add(topicPrompt('same', one), 'steer', []); queue.add(topicPrompt('same', two), 'steer', []);
  queue.update({ steering: [topicPrompt('same', one), topicPrompt('same', two)], followUp: [] });
  assert.deepEqual(queue.view().steering, [{ text: 'same', topic: one, attachments: [] }, { text: 'same', topic: two, attachments: [] }]);
  assert.deepEqual(queue.takeBack({ steering: [topicPrompt('same', two)], followUp: [] }).steering, [{ text: 'same', topic: two, attachments: [] }]);
});

test('held duplicate texts keep attachments through settle, start and rejection', () => {
  const queue = prompts('root');
  const first = queue.hold('same', 'prompt', [a]), second = queue.hold('same', 'prompt', [b]);
  assert.deepEqual(queue.view().classifying.map(entry => entry.attachments), [[a], [b]]);
  queue.settle(first, '[topic: one]\nsame', 'followUp');
  queue.update({ steering: [], followUp: ['[topic: one]\nsame'] });
  assert.deepEqual(queue.view().followUp, [{ text: 'same', topic: 'one', attachments: [a] }]);
  queue.reject(second);
  assert.deepEqual(queue.view().classifying, []);
  queue.update({ steering: [], followUp: [] });
  assert.deepEqual(queue.start('[topic: one]\nsame')?.attachments, [a]);
  assert.deepEqual(queue.view(), { steering: [], followUp: [], classifying: [] });
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
  assert.deepEqual(queue.view(), { steering: [], followUp: [{ text: '', attachments: [a] }], classifying: [] });
  assert.deepEqual((queue.start('')?.attachments ?? []), [a]);
  assert.deepEqual(queue.view(), { steering: [], followUp: [], classifying: [] });
  queue.beginClear();
  assert.deepEqual(queue.takeBack({ steering: [''], followUp: [''] }), { steering: [], followUp: [] });
  queue.endClear();
  queue.add('', 'steer', [a]); queue.update({ steering: [''], followUp: ['external'] });
  queue.update({ steering: [], followUp: ['external'] });
  assert.deepEqual((queue.start('')?.attachments ?? []), [a]);
  queue.add('', 'steer', [b]); queue.update({ steering: [''], followUp: ['external'] });
  assert.deepEqual(queue.view(), { steering: [{ text: '', attachments: [b] }], followUp: [{ text: 'external', attachments: [] }], classifying: [] });
});

test('a delivering duplicate is not in the visible queue or taken back', () => {
  const queue = prompts();
  queue.add('same', 'steer', [a]); queue.add('same', 'steer', [b]);
  queue.update({ steering: ['same', 'same'], followUp: [] });
  queue.update({ steering: ['same'], followUp: [] });
  assert.deepEqual(queue.view(), { steering: [{ text: 'same', attachments: [b] }], followUp: [], classifying: [] });
  queue.beginClear(); queue.update({ steering: [], followUp: [] });
  assert.deepEqual(queue.takeBack({ steering: ['same'], followUp: [] }), { steering: [{ text: 'same', attachments: [b] }], followUp: [] });
  queue.endClear();
  assert.deepEqual((queue.start('same')?.attachments ?? []), [a]);
});
