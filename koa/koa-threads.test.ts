import assert from 'node:assert/strict';
import { scenarios } from './testdata/scenarios/threads.ts';
import { test } from 'node:test';
import { parseThreadName } from './records.ts';
import { threadList } from './thread-list.ts';
import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { threadSections } from './text.ts';

test('thread replay accepts the scoped filtered history query and refuses another thread', () => {
  const scenario = scenarios.ThreadsFilter('/tmp/thread-replay');
  const state = scenario.open.find(record => record.type === 'state');
  assert.ok(state);
  const step = scenario.steps.find(step => step.on !== 'next');
  assert.ok(step);
  assert.equal(step.on.body?.({ before: String(Number.MAX_SAFE_INTEGER), thread: 'sidebar', sessionId: state.sessionId }), true);
  assert.equal(step.on.body?.({ before: String(Number.MAX_SAFE_INTEGER), thread: 'palette', sessionId: state.sessionId }), false);
  const history = step.reply.json;
  assert.ok(typeof history !== 'function' && 'items' in history);
  assert.deepEqual(history.items.map(item => item.seq), [0, 1, 2, 3, 4, 5, 6, 7]);
});

test('thread names validate at the edge', () => {
  for (const name of ['a', 'work-2', 'Two Words', 'x'.repeat(200)]) assert.equal(parseThreadName(name), name);
  for (const name of ['', 'a]b', 'x'.repeat(201), 'a\tb', 'a\nb', 'a\u007fb', 'a\u009fb', null, 3]) assert.equal(parseThreadName(name), undefined);
  assert.equal(parseThreadName('  Two\u00a0  Words  '), 'Two Words');
});

test('thread list folds alias chains, rename-back and valid entry overrides once', () => {
  const branch: SessionEntry[] = [{ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: '[thread: a]\nWork', timestamp: 1 } }];
  const custom = (customType: string, data: unknown) => branch.push({ type: 'custom', id: String(branch.length), parentId: branch.at(-1)?.id ?? null, timestamp: new Date(2).toISOString(), customType, data });
  custom('koa.thread-move', { from: 'a', to: 'b' }); custom('koa.thread-move', { from: 'b', to: 'c' });
  let list = threadList(branch);
  assert.equal(list.assignment('user', parseThreadName('a')), 'c');
  custom('koa.thread-move', { from: 'c', to: 'a' });
  list = threadList(branch);
  assert.equal(list.assignment('user', parseThreadName('a')), 'a');
  const b = parseThreadName('b'); assert.ok(b);
  assert.equal(list.resolve(b), 'a');
  custom('koa.message-thread', { entries: ['user', 'missing'], thread: 'invalid' });
  assert.equal(threadList(branch).assignment('user', parseThreadName('a')), 'a');
  custom('koa.message-thread', { entries: ['user'], thread: 'override' });
  assert.equal(threadList(branch).assignment('user', parseThreadName('a')), 'override');
  assert.deepEqual(threadList(branch).names, ['override']);
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
  assert.equal(threadSections('[thread: a\tb]\ntext', true)[0].text, '[thread: a\tb]\ntext');
  assert.equal(threadSections('~~~~\n[thread: hidden]\n~~~\n[thread: hidden-too]\n~~~~\n[thread: shown]\n', true).at(-1)?.thread, 'shown');
});

test('every partial marker stays hidden until complete or invalid', () => {
  const marker = '[thread: Pane resize bug]';
  for (let end = 1; end < marker.length; end++) assert.deepEqual(threadSections('body\n' + marker.slice(0, end), false).map(section => section.text), ['body\n']);
  assert.deepEqual(threadSections(marker, false), []);
  assert.deepEqual(threadSections(marker + '\n', false).map(section => [section.thread, section.text]), [['Pane resize bug', '']]);
  assert.deepEqual(threadSections('body\n[thread: one]\r', false).map(section => section.text), ['body\n']);
  assert.equal(threadSections('[thread: work', true)[0].text, '[thread: work');
  assert.equal(threadSections('[thread: ' + 'x'.repeat(201), false)[0].text, '[thread: ' + 'x'.repeat(201));
  assert.deepEqual(threadSections('[thread: one]\n[thread: two]\nlast', true).map(section => [section.thread, section.text]), [['one', ''], ['two', 'last']]);
});
