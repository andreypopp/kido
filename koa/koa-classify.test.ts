import assert from 'node:assert/strict';
import { test } from 'node:test';
import { quotedThread, threadContext } from './koa-classify.ts';
import type { Item, QueuedPrompt } from './koa-records.ts';
import { parseThreadName } from './records.ts';
import { classifierPrompt, parseClassification } from './koa-classify.ts';

test('quotes require one unambiguous thread and ignore short fragments', () => {
  const one = parseThreadName('one'), two = parseThreadName('two'); assert.ok(one && two);
  const reply = (seq: number, thread: typeof one): Item => ({ kind: 'assistant', seq, revision: 0, at: 1, final: true, lifecycle: 'ended', blocks: [{ type: 'text', thread, text: 'A sufficiently long **quoted** passage' }], stop: 'stop', error: '' });
  assert.equal(quotedThread([reply(0, one)], '> A sufficiently long quoted passage\nYes'), one);
  assert.equal(quotedThread([reply(0, one), reply(1, two)], '> A sufficiently long quoted passage'), undefined);
  assert.equal(quotedThread([reply(0, one)], '> short'), undefined);
});

test('classification accepts only one complete valid name', () => {
  for (const value of ['Pane resize bug', '#Pane resize bug', '[thread: Pane resize bug]', ' Pane  resize bug\n']) assert.equal(parseClassification(value), 'Pane resize bug');
  for (const value of ['', '#', 'a]b', 'a'.repeat(201)]) assert.equal(parseClassification(value), undefined);
});

test('thread context selects five recent threads, three prose messages, and queued users', () => {
  const names = Array.from({ length: 7 }, (_, index) => parseThreadName(`thread-${index}`)).filter(name => name !== undefined);
  const items: Item[] = [];
  for (const thread of names) {
    for (let index = 0; index < 4; index++) items.push({ kind: 'user', seq: items.length, revision: 0, at: 1, final: true, thread, text: `message ${index}`, images: [], attachments: [] });
    items.push({ kind: 'assistant', seq: items.length, revision: 0, at: 1, final: true, blocks: [{ type: 'thinking', thread, text: 'secret' }, { type: 'text', thread, text: 'prose\n' + 'é'.repeat(300) }], stop: 'stop', error: '', lifecycle: 'ended' });
  }
  const first = names[0];
  assert.ok(first);
  const queued: QueuedPrompt[] = [{ thread: first, text: 'queued\tuser', attachments: [] }];
  const context = threadContext(items, names, queued);
  assert.deepEqual(context.threads.map(thread => thread.name), [...names.slice(3), first]);
  assert.deepEqual(context.others, names.slice(1, 3));
  assert.deepEqual(context.threads.at(-1)?.messages.map(message => message.from), ['user', 'assistant', 'user']);
  assert.equal(context.threads.at(-1)?.messages.at(-1)?.text, 'queued user');
  assert.equal(context.threads[0]?.messages[0]?.text, 'message 2');
  for (const thread of context.threads) for (const message of thread.messages) { assert.ok(Buffer.byteLength(message.text) <= 300); assert.ok(!/[\n\t]/.test(message.text)); assert.notEqual(message.text, 'secret'); }
});

test('classifier context is prose only with a bounded new message', () => {
  const build = parseThreadName('build'), release = parseThreadName('release');
  assert.ok(build && release);
  const context = classifierPrompt([{ name: build, messages: [{ from: 'user', text: 'fix it' }] }], [release], 'é'.repeat(2000));
  assert.equal(context.tools, undefined);
  assert.match(context.systemPrompt ?? '', /one thread name/);
  const message = context.messages[0];
  assert.equal(message.role, 'user');
  assert.equal(typeof message.content, 'string');
  assert.equal(message.content, 'Threads of this session, oldest first. The last one is the current thread.\n## build\nuser: fix it\nOther threads:\n- release\nNew message:\n' + 'é'.repeat(1000));
});
