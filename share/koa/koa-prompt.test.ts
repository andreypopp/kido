import assert from 'node:assert/strict';
import { test } from 'node:test';
import { prompts } from './koa-queue.ts';
import { bashCommand, shellPathToken } from './prompt.ts';

test('bang commands keep shell text and context choice', () => {
  assert.deepEqual(bashCommand('! echo hi'), { command: 'echo hi', excludeFromContext: false, prefixLength: 1 });
  assert.deepEqual(bashCommand('!!echo hi\nnext'), { command: 'echo hi\nnext', excludeFromContext: true, prefixLength: 2 });
  assert.deepEqual(bashCommand('!'), { command: '', excludeFromContext: false, prefixLength: 1 });
  assert.equal(bashCommand('hello ! echo'), undefined);
});
import type { Attachment } from './koa-records.ts';

test('shell paths use explicit unquoted path tokens, including executable paths', () => {
  assert.deepEqual(shellPathToken('!./scripts/ch', 13), { from: 1, to: 13, query: './scripts/ch' });
  assert.deepEqual(shellPathToken('!! cat ~/not', 12), { from: 7, to: 12, query: '~/not' });
  assert.equal(shellPathToken('! cat ./abc', 9), undefined);
  for (const text of ['! @foo', '! /name args', '! cat plain', '! cat "./space', '! cat ./a$X', '! cat ./a;cmd', '! cat ./a*', '! cat ./{a,b}', '! cat ./a\\b']) assert.equal(shellPathToken(text, text.length), undefined, text);
});

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
