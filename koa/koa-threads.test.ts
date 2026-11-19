import assert from 'node:assert/strict';
import { scenarios } from './testdata/scenarios/threads.ts';
import { test } from 'node:test';
import { parseThreadName } from './records.ts';
import { threadSections } from './text.ts';

test('thread replay accepts the scoped filtered history query and refuses another thread', () => {
  const scenario = scenarios.testKoaWebviewThreadsFilter('/tmp/thread-replay');
  const state = scenario.open.find(record => record.type === 'state');
  assert.ok(state);
  const step = scenario.steps[0];
  assert.ok(step.on !== 'next');
  assert.equal(step.on.body?.({ before: String(Number.MAX_SAFE_INTEGER), thread: 'sidebar', sessionId: state.sessionId }), true);
  assert.equal(step.on.body?.({ before: String(Number.MAX_SAFE_INTEGER), thread: 'palette', sessionId: state.sessionId }), false);
  const history = step.reply.json;
  assert.ok(typeof history !== 'function' && 'items' in history);
  assert.deepEqual(history.items.map(item => item.seq), [0, 1, 2, 3, 4, 5, 6, 7]);
});

test('thread names validate at the edge', () => {
  for (const name of ['a', 'work-2', '-'.repeat(32)]) assert.equal(parseThreadName(name), name);
  for (const name of ['', 'A', 'two words', 'x'.repeat(33), null, 3]) assert.equal(parseThreadName(name), undefined);
});

test('thread sections preserve source code point ranges and fence text', () => {
  const text = '😀 before\r\n[thread: one]\r\n**first**\r\n```ts\r\n[thread: fenced]\r\n```\r\n[thread: two]\r\nlast';
  const sections = threadSections(text, true);
  assert.deepEqual(sections.map(({ text, thread }) => ({ text, thread })), [
    { text: '😀 before\r\n', thread: undefined },
    { text: '**first**\r\n```ts\r\n[thread: fenced]\r\n```\r\n', thread: 'one' },
    { text: 'last', thread: 'two' },
  ]);
  for (const section of sections) assert.equal(Array.from(text).slice(section.start, section.end).join(''), section.text);
  assert.equal(threadSections('[thread: BAD]\ntext', true)[0].text, '[thread: BAD]\ntext');
  assert.equal(threadSections('~~~~\n[thread: hidden]\n~~~\n[thread: hidden-too]\n~~~~\n[thread: shown]\n', true).at(-1)?.thread, 'shown');
});

test('every partial marker stays hidden until complete or invalid', () => {
  const marker = '[thread: work-2]';
  for (let end = 1; end < marker.length; end++) assert.deepEqual(threadSections('body\n' + marker.slice(0, end), false).map(section => section.text), ['body\n']);
  assert.deepEqual(threadSections(marker, false), []);
  assert.deepEqual(threadSections(marker + '\n', false).map(section => [section.thread, section.text]), [['work-2', '']]);
  assert.deepEqual(threadSections('body\n[thread: one]\r', false).map(section => section.text), ['body\n']);
  assert.equal(threadSections('[thread: work', true)[0].text, '[thread: work');
  assert.equal(threadSections('[thread: BAD', false)[0].text, '[thread: BAD');
  assert.deepEqual(threadSections('[thread: one]\n[thread: two]\nlast', true).map(section => [section.thread, section.text]), [['one', ''], ['two', 'last']]);
});
