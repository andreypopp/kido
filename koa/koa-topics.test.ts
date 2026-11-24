import assert from 'node:assert/strict';
import { scenarios } from './testdata/scenarios/topics.ts';
import { test } from 'node:test';
import { parseTopicName, topicArchive } from './records.ts';
import { topicList } from './topic-list.ts';
import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { topicSections } from './text.ts';

test('topic replay accepts the scoped filtered history query and refuses another topic', () => {
  const scenario = scenarios.TopicsFilter('/tmp/topic-replay');
  const state = scenario.open.find(record => record.type === 'state');
  assert.ok(state);
  const step = scenario.steps.find(step => step.on !== 'next');
  assert.ok(step);
  assert.equal(step.on.body?.({ before: String(Number.MAX_SAFE_INTEGER), topic: 'sidebar', sessionId: state.sessionId }), true);
  assert.equal(step.on.body?.({ before: String(Number.MAX_SAFE_INTEGER), topic: 'palette', sessionId: state.sessionId }), false);
  const history = step.reply.json;
  assert.ok(typeof history !== 'function' && 'items' in history);
  assert.deepEqual(history.items.map(item => item.seq), [0, 1, 2, 3, 4, 5, 6, 7]);
});

test('topic names validate at the edge', () => {
  for (const name of ['a', 'work-2', 'Two Words', 'x'.repeat(200)]) assert.equal(parseTopicName(name), name);
  for (const name of ['', 'a]b', 'x'.repeat(201), 'a\tb', 'a\nb', 'a\u007fb', 'a\u009fb', null, 3]) assert.equal(parseTopicName(name), undefined);
  assert.equal(parseTopicName('  Two\u00a0  Words  '), 'Two Words');
});

test('topic list folds alias chains, rename-back and valid entry overrides once', () => {
  const branch: SessionEntry[] = [{ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: '[topic: a]\nWork', timestamp: 1 } }];
  const custom = (customType: string, data: unknown) => branch.push({ type: 'custom', id: String(branch.length), parentId: branch.at(-1)?.id ?? null, timestamp: new Date(2).toISOString(), customType, data });
  custom('koa.topic-move', { from: 'a', to: 'b' }); custom('koa.topic-move', { from: 'b', to: 'c' });
  let list = topicList(branch);
  assert.equal(list.assignment('user', parseTopicName('a')), 'c');
  custom('koa.topic-move', { from: 'c', to: 'a' });
  list = topicList(branch);
  assert.equal(list.assignment('user', parseTopicName('a')), 'a');
  const b = parseTopicName('b'); assert.ok(b);
  assert.equal(list.resolve(b), 'a');
  custom('koa.message-topic', { entries: ['user', 'missing'], topic: 'invalid' });
  assert.equal(topicList(branch).assignment('user', parseTopicName('a')), 'a');
  custom('koa.message-topic', { anchor: 'user', topic: 'override' });
  assert.equal(topicList(branch).assignment('user', parseTopicName('a')), 'override');
  assert.deepEqual(topicList(branch).names, ['override']);
});

test('turn corrections include later replies and stop at the next user', () => {
  const branch: SessionEntry[] = [{ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: '[topic: original]\nWork', timestamp: 1 } }];
  const correction: SessionEntry = { type: 'custom', id: 'correction', parentId: 'user', timestamp: new Date(2).toISOString(), customType: 'koa.message-topic', data: { anchor: 'user', topic: 'chosen' } };
  branch.push(correction);
  branch.push({ type: 'message', id: 'reply', parentId: 'correction', timestamp: new Date(3).toISOString(), message: { role: 'assistant', content: [{ type: 'text', text: '[topic: conflict]\nReply' }], api: 'openai-responses', provider: 'test', model: 'test', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: 'stop', timestamp: 3 } });
  branch.push({ type: 'message', id: 'next', parentId: 'reply', timestamp: new Date(4).toISOString(), message: { role: 'user', content: '[topic: next]\nNext', timestamp: 4 } });
  assert.equal(topicList(branch).assignment('reply', parseTopicName('conflict')), 'chosen');
  assert.equal(topicList(branch).assignment('next', parseTopicName('next')), 'next');
  branch.push({ ...correction, id: 'again', data: { anchor: 'user', topic: 'latest' } });
  assert.equal(topicList(branch).assignment('reply', undefined), 'latest');
  assert.equal(topicList(branch.filter(entry => entry.id !== 'correction' && entry.id !== 'again')).assignment('reply', parseTopicName('conflict')), 'conflict');
});

test('archive replay follows rename aliases and only an archive entry restores a topic', () => {
  const a = parseTopicName('a'), b = parseTopicName('b'); assert.ok(a && b);
  const branch: SessionEntry[] = [{ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: '[topic: a]\nWork', timestamp: 1 } }];
  const custom = (customType: string, data: unknown) => branch.push({ type: 'custom', id: String(branch.length), parentId: branch.at(-1)?.id ?? null, timestamp: new Date(2).toISOString(), customType, data });
  custom('koa.topic-archive', { name: 'a', archived: true });
  custom('koa.topic-move', { from: 'a', to: 'b' });
  assert.equal(topicList(branch).archived(b), true);
  custom('koa.topic', { name: 'b' });
  custom('koa.message-topic', { anchor: 'user', topic: 'b' });
  assert.equal(topicList(branch).archived(b), true);
  custom('koa.topic-archive', { name: 'a', archived: false });
  assert.equal(topicList(branch).archived(b), false);
  custom('koa.topic-archive', { name: 'b', archived: true });
  custom('koa.topic-move', { from: 'b', to: 'a' });
  assert.equal(topicList(branch).archived(a), true);
  assert.equal(topicList(branch).archived(b), true);
  for (const data of [{ name: 'a' }, { name: 'a', archived: 1 }, { name: 'a]b', archived: true }]) assert.equal(topicArchive({ type: 'custom', customType: 'koa.topic-archive', data }), undefined);
});

test('a merge takes the existing target archive state even when the target has no name index', () => {
  const a = parseTopicName('a'), b = parseTopicName('b'); assert.ok(a && b);
  for (const source of [false, true]) for (const target of [false, true]) {
    const branch: SessionEntry[] = ['a', 'other'].map((name, index) => ({ type: 'message', id: 'user' + index, parentId: index ? 'user0' : null, timestamp: new Date(index).toISOString(), message: { role: 'user', content: '[topic: ' + name + ']\nWork', timestamp: index } }));
    const custom = (customType: string, data: unknown) => branch.push({ type: 'custom', id: String(branch.length), parentId: branch.at(-1)?.id ?? null, timestamp: new Date(2).toISOString(), customType, data });
    custom('koa.message-topic', { anchor: 'user1', topic: 'b' });
    custom('koa.topic-archive', { name: 'a', archived: source });
    custom('koa.topic-archive', { name: 'b', archived: target });
    custom('koa.topic-move', { from: 'a', to: 'b' });
    const list = topicList(branch);
    assert.deepEqual(list.names, ['b']);
    assert.equal(list.archived(a), target); assert.equal(list.archived(b), target);
  }
});

test('topic sections preserve source code point ranges and fence text', () => {
  const text = '😀 before\r\n[topic: one]\r\n**first**\r\n```ts\r\n[topic: fenced]\r\n```\r\n[topic: two]\r\nlast';
  const sections = topicSections(text, true);
  assert.deepEqual(sections.map(({ text, topic }) => ({ text, topic })), [
    { text: '😀 before\r\n', topic: undefined },
    { text: '**first**\r\n```ts\r\n[topic: fenced]\r\n```\r\n', topic: 'one' },
    { text: 'last', topic: 'two' },
  ]);
  for (const section of sections) assert.equal(Array.from(text).slice(section.start, section.end).join(''), section.text);
  assert.equal(topicSections('[topic: a\tb]\ntext', true)[0].text, '[topic: a\tb]\ntext');
  assert.equal(topicSections('~~~~\n[topic: hidden]\n~~~\n[topic: hidden-too]\n~~~~\n[topic: shown]\n', true).at(-1)?.topic, 'shown');
});

test('every partial marker stays hidden until complete or invalid', () => {
  const marker = '[topic: Pane resize bug]';
  for (let end = 1; end < marker.length; end++) assert.deepEqual(topicSections('body\n' + marker.slice(0, end), false).map(section => section.text), ['body\n']);
  assert.deepEqual(topicSections(marker, false), []);
  assert.deepEqual(topicSections(marker + '\n', false).map(section => [section.topic, section.text]), [['Pane resize bug', '']]);
  assert.deepEqual(topicSections('body\n[topic: one]\r', false).map(section => section.text), ['body\n']);
  assert.equal(topicSections('[topic: work', true)[0].text, '[topic: work');
  assert.equal(topicSections('[topic: ' + 'x'.repeat(201), false)[0].text, '[topic: ' + 'x'.repeat(201));
  assert.deepEqual(topicSections('[topic: one]\n[topic: two]\nlast', true).map(section => [section.topic, section.text]), [['one', ''], ['two', 'last']]);
});
