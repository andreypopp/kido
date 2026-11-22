import assert from 'node:assert/strict';
import { test } from 'node:test';
import { quotedTopic, topicContext } from './koa-classify.ts';
import type { Item, QueuedPrompt } from './koa-records.ts';
import { parseTopicName } from './records.ts';
import { classifierPrompt, parseClassification } from './koa-classify.ts';

test('quotes require one unambiguous topic and ignore short fragments', () => {
  const one = parseTopicName('one'), two = parseTopicName('two'); assert.ok(one && two);
  const reply = (seq: number, topic: typeof one): Item => ({ kind: 'assistant', seq, revision: 0, at: 1, final: true, lifecycle: 'ended', blocks: [{ type: 'text', topic, text: 'A sufficiently long **quoted** passage' }], stop: 'stop', error: '' });
  assert.equal(quotedTopic([reply(0, one)], '> A sufficiently long quoted passage\nYes', new Set()), one);
  assert.equal(quotedTopic([reply(0, one), reply(1, two)], '> A sufficiently long quoted passage', new Set()), undefined);
  assert.equal(quotedTopic([reply(0, one)], '> short', new Set()), undefined);
  assert.equal(quotedTopic([reply(0, one)], '> A sufficiently long quoted passage', new Set([one])), undefined);
  assert.equal(quotedTopic([reply(0, one), reply(1, two)], '> A sufficiently long quoted passage', new Set([one])), two);
});

test('classification accepts only one complete valid name', () => {
  for (const value of ['Pane resize bug', '#Pane resize bug', '[topic: Pane resize bug]', ' Pane  resize bug\n']) assert.equal(parseClassification(value), 'Pane resize bug');
  for (const value of ['', '#', 'a]b', 'a'.repeat(201)]) assert.equal(parseClassification(value), undefined);
});

test('topic context selects five recent topics, three prose messages, and queued users', () => {
  const names = Array.from({ length: 7 }, (_, index) => parseTopicName(`topic-${index}`)).filter(name => name !== undefined);
  const items: Item[] = [];
  for (const topic of names) {
    for (let index = 0; index < 4; index++) items.push({ kind: 'user', seq: items.length, revision: 0, at: 1, final: true, topic, text: `message ${index}`, images: [], attachments: [] });
    items.push({ kind: 'assistant', seq: items.length, revision: 0, at: 1, final: true, blocks: [{ type: 'thinking', topic, text: 'secret' }, { type: 'text', topic, text: 'prose\n' + 'é'.repeat(300) }], stop: 'stop', error: '', lifecycle: 'ended' });
  }
  const first = names[0];
  assert.ok(first);
  const queued: QueuedPrompt[] = [{ topic: first, text: 'queued\tuser', attachments: [] }];
  const context = topicContext(items, names, queued, new Set());
  assert.deepEqual(context.topics.map(topic => topic.name), [...names.slice(3), first]);
  assert.deepEqual(context.others, names.slice(1, 3));
  const excluded = topicContext(items, names, queued, new Set([first, names[1], names[6]]));
  assert.deepEqual(excluded.topics.map(topic => topic.name), names.slice(2, 6));
  assert.deepEqual(excluded.others, []);
  assert.deepEqual(context.topics.at(-1)?.messages.map(message => message.from), ['user', 'assistant', 'user']);
  assert.equal(context.topics.at(-1)?.messages.at(-1)?.text, 'queued user');
  assert.equal(context.topics[0]?.messages[0]?.text, 'message 2');
  for (const topic of context.topics) for (const message of topic.messages) { assert.ok(Buffer.byteLength(message.text) <= 300); assert.ok(!/[\n\t]/.test(message.text)); assert.notEqual(message.text, 'secret'); }
});

test('classifier context is prose only with a bounded new message', () => {
  const build = parseTopicName('build'), release = parseTopicName('release');
  assert.ok(build && release);
  const context = classifierPrompt([{ name: build, messages: [{ from: 'user', text: 'fix it' }] }], [release], 'é'.repeat(2000));
  assert.equal(context.tools, undefined);
  assert.match(context.systemPrompt ?? '', /one topic name/);
  const message = context.messages[0];
  assert.equal(message.role, 'user');
  assert.equal(typeof message.content, 'string');
  assert.equal(message.content, 'Topics of this session, oldest first. The last one is the current topic.\n## build\nuser: fix it\nOther topics:\n- release\nNew message:\n' + 'é'.repeat(1000));
});
