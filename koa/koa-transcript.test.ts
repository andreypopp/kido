import assert from "node:assert/strict";
import { IncomingMessage, ServerResponse, createServer } from "node:http";
import { Socket } from "node:net";
import { test, type TestContext } from "node:test";
import { mkdtempSync, rmSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sessionEntryToContextMessages, type SessionEntry } from "@earendil-works/pi-coding-agent";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { transcript, appendBashOutput } from "./koa-transcript.ts";
import type { WireItem } from "./koa-records.ts";
import { projectTopic, type TopicContext } from './topic-run.ts';
import { parseTopicName } from './records.ts';

function directory(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "koa-transcript-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function request(view: ReturnType<typeof transcript>, path: string, address: Parameters<ReturnType<typeof transcript>["handle"]>[2] = { type: "selected" }) {
  const request = new IncomingMessage(new Socket());
  request.method = "GET";
  request.url = path;
  const response = new ServerResponse(request);
  const lines: string[] = [];
  response.write = (chunk: string) => { lines.push(chunk); return true; };
  response.end = (chunk?: unknown) => { if (typeof chunk === "string") lines.push(chunk); return response; };
  assert.equal(view.handle(request, response, address), true);
  return lines;
}

function record(line: string | undefined) {
  assert.ok(line !== undefined);
  assert.match(line, /^data: [^\r\n]*\n\n$/);
  return JSON.parse(line.slice(6, -2));
}

test('large resets keep a stalled stream open until live output exceeds the cap', t => {
  const parent = transcript({ dir: directory(t), flushMs: 1, branch: () => [], sessionEntryToContextMessages });
  const child = transcript({ dir: directory(t), flushMs: 1, branch: () => [], sessionEntryToContextMessages });
  t.after(() => { parent.close(); child.close(); });
  for (let i = 0; i < 80; i++) child.message({ role: 'user', content: 'x'.repeat(16384), timestamp: i }, 'end');
  const incoming = new IncomingMessage(new Socket());
  incoming.method = 'GET'; incoming.url = '/events';
  const response = new ServerResponse(incoming);
  assert.equal(parent.handle(incoming, response), true);
  child.show(parent);
  assert.ok(response.writableLength > 1 << 20);
  assert.equal(response.writableEnded, false);
  for (let i = 0; i < 80; i++) child.message({ role: 'user', content: 'y'.repeat(16384), timestamp: 100 + i }, 'end');
  assert.equal(response.writableEnded, true);
});

test('message moves use persisted entry identity with equal timestamps', t => {
  const branch: SessionEntry[] = [
    { type: 'message', id: 'one', parentId: null, timestamp: new Date(123).toISOString(), message: { role: 'user', content: '[topic: one]\nFirst', timestamp: 123 } },
    { type: 'message', id: 'two', parentId: 'one', timestamp: new Date(123).toISOString(), message: { role: 'user', content: '[topic: two]\nSecond', timestamp: 123 } },
  ];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  view.rebuild(branch, 'session', 'two');
  assert.deepEqual(view.moveTargets(0), ['one']);
  const before = JSON.parse(request(view, '/items?before=100').join(''));
  const move: SessionEntry = { type: 'custom', id: 'move', parentId: 'two', timestamp: new Date(124).toISOString(), customType: 'koa.message-topic', data: { entries: ['one'], topic: 'target' } };
  branch.push(move); view.annotation(move);
  const after = JSON.parse(request(view, '/items?before=100').join(''));
  assert.deepEqual(after.items.filter((item: WireItem) => item.kind === 'user').map((item: { topic: string }) => item.topic), ['target', 'two']);
  assert.equal(after.epoch, before.epoch);
  view.rebuild(branch, 'session', 'move');
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items.map((item: WireItem) => ({ ...item, revision: 0 })), after.items.map((item: WireItem) => ({ ...item, revision: 0 })));
});

test('topic windows follow a message move', t => {
  const branch: SessionEntry[] = [{ type: 'message', id: 'reply', parentId: null, timestamp: new Date(123).toISOString(), message: assistant('[topic: old]\nReply') }];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  view.rebuild(branch, 'session', 'reply');
  const page = (topic: string): WireItem[] => JSON.parse(request(view, '/items?before=100&topic=' + topic).join('')).items;
  assert.equal(page('old').filter(item => item.kind === 'assistant').length, 1);
  const move: SessionEntry = { type: 'custom', id: 'move', parentId: 'reply', timestamp: new Date(124).toISOString(), customType: 'koa.message-topic', data: { entries: ['reply'], topic: 'new' } };
  branch.push(move); view.annotation(move);
  assert.equal(page('old').filter(item => item.kind === 'assistant').length, 0);
  assert.equal(page('new').filter(item => item.kind === 'assistant').length, 1);
});

test('corrections preserve reconnect cursors and replay merges and whole reply turns', t => {
  const branch: SessionEntry[] = [];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const user: AgentMessage = { role: 'user', content: '[topic: one]\nWork', timestamp: 100 };
  const reply = assistant('[topic: one]\nReply with a sufficiently long quotation');
  reply.content.push({ type: 'toolCall', id: 'call', name: 'read', arguments: { path: 'a' } });
  const later = { ...assistant('[topic: one]\nFinal'), timestamp: 124 };
  const add = (id: string, message: Extract<AgentMessage, { role: 'user' | 'assistant' }>) => { branch.push({ type: 'message', id, parentId: branch.at(-1)?.id ?? null, timestamp: new Date(message.timestamp).toISOString(), message }); view.message(message, 'end'); };
  add('user', user); add('reply', reply); add('later', later);
  assert.deepEqual(view.moveTargets(0), ['user', 'reply', 'later']);
  assert.deepEqual(view.moveTargets(1), ['user', 'reply', 'later']);
  const unpersisted = { ...assistant('Not saved'), timestamp: 125 }; view.message(unpersisted, 'end');
  assert.equal(view.moveTargets(3), undefined);
  branch.push({ type: 'message', id: 'unsaved', parentId: 'later', timestamp: new Date(125).toISOString(), message: unpersisted });
  const before = JSON.parse(request(view, '/items?before=100').join(''));
  const custom = (id: string, customType: string, data: unknown) => { const entry: SessionEntry = { type: 'custom', id, parentId: branch.at(-1)?.id ?? null, timestamp: new Date(130).toISOString(), customType, data }; branch.push(entry); view.annotation(entry); };
  const events = request(view, '/events?epoch=' + before.epoch + '&after=100');
  events.length = 0;
  custom('move', 'koa.message-topic', { entries: ['user', 'reply', 'later', 'unsaved'], topic: 'target' });
  custom('merge', 'koa.topic-move', { from: 'target', to: 'renamed' });
  const live = JSON.parse(request(view, '/items?before=100').join(''));
  assert.ok(live.items.filter((item: WireItem) => item.kind === 'assistant').every((item: { blocks: { topic: string }[] }) => item.blocks.every(block => block.topic === 'renamed')));
  const reconnect = record(request(view, '/events?epoch=' + before.epoch + '&after=3')[0]);
  assert.equal(live.epoch, before.epoch);
  assert.equal(reconnect.type, 'item');
  assert.equal(reconnect.item.topic, 'renamed');
  assert.ok(events.length > 0);
  assert.ok(events.map(record).every(event => event.type === 'item'));
  const updates = events.map(record).filter(event => event.item.seq === 0);
  assert.deepEqual(updates.map(event => [event.item.topic, event.item.revision]), [['target', before.items[0].revision + 1], ['renamed', before.items[0].revision + 2]]);
  assert.equal(view.quotedTopic('> Reply with a sufficiently long quotation'), 'renamed');
  view.rebuild(branch, 'session', 'merge');
  const replay = JSON.parse(request(view, '/items?before=100').join(''));
  assert.deepEqual(replay.items.map((item: WireItem) => item.kind === 'assistant' ? item.blocks.map(block => block.topic) : item.kind === 'user' ? item.topic : item.kind), live.items.map((item: WireItem) => item.kind === 'assistant' ? item.blocks.map(block => block.topic) : item.kind === 'user' ? item.topic : item.kind));
});

test('a correction of an unfinished reply keeps the next patch revision', t => {
  const branch: SessionEntry[] = [];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const reply = assistant('[topic: old]\nGrowing');
  view.message(reply, 'update');
  const events = request(view, '/events');
  const initial = record(events[0]);
  const move: SessionEntry = { type: 'custom', id: 'move', parentId: null, timestamp: new Date(124).toISOString(), customType: 'koa.topic-move', data: { from: 'old', to: 'new' } };
  branch.push(move); view.annotation(move);
  const correction = events.map(record).find(event => event.type === 'item');
  assert.equal(correction.item.revision, initial.items[0].revision + 1);
  assert.equal(correction.item.blocks[0].topic, 'new');
  view.message(assistant('[topic: old]\nGrowing more'), 'update');
  request(view, '/items?before=100');
  const patch = events.map(record).find(event => event.type === 'patch');
  assert.equal(patch.baseRevision, correction.item.revision);
  assert.equal(patch.revision, correction.item.revision + 1);
});

test('moving the latest persisted reply removes its only old topic', t => {
  const branch: SessionEntry[] = [];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const reply = assistant('[topic: old]\nThe only reply in the old topic');
  view.message(reply, 'end');
  branch.push({ type: 'message', id: 'reply', parentId: null, timestamp: new Date(123).toISOString(), message: reply });
  const move: SessionEntry = { type: 'custom', id: 'move', parentId: 'reply', timestamp: new Date(124).toISOString(), customType: 'koa.message-topic', data: { entries: ['reply'], topic: 'target' } };
  branch.push(move); view.annotation(move);
  assert.deepEqual(view.topics().map(topic => topic.name), ['target']);
  assert.deepEqual(view.topicContext([]).others, []);
});

test('archive metadata changes topic state without changing feed items or epoch and survives rebuild', t => {
  const branch: SessionEntry[] = [];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const reply = assistant('[topic: one]\nReply with a sufficiently long quotation');
  branch.push({ type: 'message', id: 'reply', parentId: null, timestamp: new Date(123).toISOString(), message: reply }); view.message(reply, 'end');
  const before = JSON.parse(request(view, '/items?before=100').join(''));
  const archive: SessionEntry = { type: 'custom', id: 'archive', parentId: 'reply', timestamp: new Date(124).toISOString(), customType: 'koa.topic-archive', data: { name: 'one', archived: true } };
  branch.push(archive); view.annotation(archive);
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')), before);
  assert.equal(view.topics()[0]?.archived, true);
  assert.deepEqual(view.topicContext([]), { topics: [], others: [] });
  assert.equal(view.quotedTopic('> Reply with a sufficiently long quotation'), undefined);
  view.rebuild(branch, 'session', 'archive');
  assert.equal(view.topics()[0]?.archived, true);
  const restore: SessionEntry = { ...archive, id: 'restore', parentId: 'archive', data: { name: 'one', archived: false } };
  branch.push(restore); view.annotation(restore);
  assert.equal(view.topics()[0]?.archived, undefined);
  assert.equal(view.quotedTopic('> Reply with a sufficiently long quotation'), 'one');
});

test('rebuild replays the whole active branch across compactions', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }); t.after(() => view.close());
  const entries: SessionEntry[] = [
    { type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: 'before', timestamp: 1 } },
    { type: 'message', id: 'reply', parentId: 'user', timestamp: new Date(123).toISOString(), message: assistant('Proceed?') },
    { type: 'custom', id: 'annotation', parentId: 'reply', timestamp: new Date(124).toISOString(), customType: 'reply-annotations', data: { reply: { at: 123, block: 0, length: 8 }, annotations: [{ type: 'question', kind: 'yes_no', range: [0, 8] }] } },
    { type: 'compaction', id: 'compact1', parentId: 'annotation', timestamp: new Date(125).toISOString(), summary: 'first summary', tokensBefore: 100, firstKeptEntryId: 'reply' },
    { type: 'custom_message', id: 'custom', parentId: 'compact1', timestamp: new Date(126).toISOString(), customType: 'test', content: 'custom body', display: true },
    { type: 'branch_summary', id: 'branch', parentId: 'custom', timestamp: new Date(127).toISOString(), summary: 'branch summary', fromId: 'sibling' },
    { type: 'message', id: 'middle', parentId: 'branch', timestamp: new Date(128).toISOString(), message: { role: 'user', content: 'middle', timestamp: 128 } },
    { type: 'compaction', id: 'compact2', parentId: 'middle', timestamp: new Date(129).toISOString(), summary: 'second summary', tokensBefore: 200, firstKeptEntryId: 'middle' },
    { type: 'message', id: 'last', parentId: 'compact2', timestamp: new Date(130).toISOString(), message: { ...assistant('after'), timestamp: 130 } },
    { type: 'message', id: 'sibling', parentId: 'user', timestamp: new Date(131).toISOString(), message: { role: 'user', content: 'excluded', timestamp: 131 } },
  ];
  view.rebuild(entries, 'session', 'last');
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items.map((item: WireItem) => item.kind), ['user', 'assistant', 'annotations', 'summary', 'notice', 'summary', 'user', 'summary', 'assistant']);
  assert.deepEqual(items.filter((item: WireItem) => item.kind === 'summary').map((item: { source: string; text: string }) => [item.source, item.text]), [['compaction', 'first summary'], ['branch', 'branch summary'], ['compaction', 'second summary']]);
  assert.deepEqual(items[2].reply, { seq: 1, block: 0 });
  assert.equal(items[4].text, 'custom body');
  assert.deepEqual(items.filter((item: WireItem) => item.kind === 'user').map((item: { text: string }) => item.text), ['before', 'middle']);
  assert.equal(items[8].blocks[0].text, 'after');
});

test('selecting a topic loads its items before compaction and outside the live window', t => {
  let branch: SessionEntry[] = [];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const entries: SessionEntry[] = [
    { type: 'message', id: 'old', parentId: null, timestamp: new Date(123).toISOString(), message: assistant('[topic: old]\nHistorical reply') },
    { type: 'custom', id: 'index', parentId: 'old', timestamp: new Date(124).toISOString(), customType: 'koa.topic', data: { name: 'old', at: 123 } },
    { type: 'message', id: 'recent', parentId: 'index', timestamp: new Date(125).toISOString(), message: { role: 'user', content: 'Recent input', timestamp: 125 } },
    { type: 'compaction', id: 'compact', parentId: 'recent', timestamp: new Date(126).toISOString(), summary: 'Compacted history', tokensBefore: 100, firstKeptEntryId: 'recent' },
  ];
  branch = entries; view.rebuild(entries, 'session', 'compact');
  assert.ok(view.topics().some(topic => topic.name === 'old'));
  const selected = () => JSON.parse(request(view, '/items?before=' + Number.MAX_SAFE_INTEGER + '&topic=old').join(''));
  const historical = selected();
  assert.deepEqual(historical.items.filter((item: WireItem) => item.kind === 'assistant').map((item: { blocks: { text: string }[] }) => item.blocks[0].text), ['Historical reply']);
  assert.equal(historical.more, false);
  for (let index = 0; index < 120; index++) view.message({ ...assistant('[topic: recent]\nRecent reply ' + index), timestamp: 200 + index }, 'end');
  const live = JSON.parse(request(view, '/items?before=' + Number.MAX_SAFE_INTEGER).join(''));
  assert.equal(live.more, true);
  assert.equal(live.items.some((item: WireItem) => item.kind === 'assistant' && item.blocks.some(block => block.topic === 'old')), false);
  const olderTopic = selected();
  assert.deepEqual(olderTopic.items.slice(0, historical.items.length), historical.items);
  assert.equal(olderTopic.items.filter((item: WireItem) => item.kind === 'assistant' && item.blocks.some(block => block.topic === 'recent')).length, 0);
  assert.equal(olderTopic.more, false);
});

test('live compaction replaces its command without changing earlier items or epoch', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }); t.after(() => view.close());
  view.message({ role: 'user', content: 'before', timestamp: 1 }, 'end');
  const before = JSON.parse(request(view, '/items?before=100').join(''));
  view.command({ type: 'compaction', state: { type: 'running' } });
  view.message({ role: 'compactionSummary', summary: 'saved', tokensBefore: 10, timestamp: 3 }, 'end');
  const after = JSON.parse(request(view, '/items?before=100').join(''));
  assert.equal(after.epoch, before.epoch);
  assert.deepEqual(after.items[0], before.items[0]);
  assert.deepEqual(after.items.map((item: WireItem) => item.kind), ['user', 'summary']);
  assert.equal(after.items[1].seq, 1);
  assert.equal(after.items[1].at, 3);
});

const fresh = (items: object[]) => items.map(item => ({ ...item, revision: 0 }));

function linked(messages: readonly AgentMessage[], session?: string, extra: readonly SessionEntry[] = []): [SessionEntry[], string | undefined, string | null] {
  const entries: SessionEntry[] = messages.map((message, index) => ({ type: 'message', id: 'message-' + index, parentId: index ? 'message-' + (index - 1) : null, timestamp: new Date(message.timestamp).toISOString(), message }));
  const leaf = entries.at(-1)?.id ?? null;
  return [[...entries, ...extra.map(entry => entry.parentId === null ? { ...entry, parentId: leaf } : entry)], session, leaf];
}

function assistant(text: string, stopReason: "stop" | "error" = "stop"): Extract<AgentMessage, { role: "assistant" }> {
  return { role: "assistant", content: [{ type: "text", text }], api: "openai-responses", provider: "openai", model: "test", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason, timestamp: 123 };
}

test('root topic projection splits sections, preserves tool indexes and remaps annotations', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const text = '[topic: one]\n😀 Pick one?\n[topic: two]\nNext?';
  const message = { ...assistant(text), content: [{ type: 'text' as const, text }, { type: 'toolCall' as const, id: 'read', name: 'read', arguments: { path: '/tmp/source' } }] };
  view.rebuild(...linked([message]));
  let items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items[0].blocks.map((block: { type: string; topic?: string; text?: string }) => [block.type, block.topic, block.text]), [['text', 'one', '😀 Pick one?\n'], ['text', 'two', 'Next?'], ['tool', 'two', undefined]]);
  assert.equal(view.itemFile(0, 2), '/tmp/source');
  view.toolDone('read', [{ type: 'image', data: Buffer.from('image').toString('base64'), mimeType: 'image/png' }], false, 124);
  const tool = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks[2];
  assert.equal(tool.state.result.images[0].id, '0.1.0');
  view.annotation({ type: 'custom', id: 'mark', parentId: null, timestamp: new Date(124).toISOString(), customType: 'reply-annotations', data: { reply: { at: 123, block: 0, length: Array.from(text).length }, annotations: [{ type: 'question', kind: 'choice', range: [15, 24], options: [[20, 23]] }, { type: 'question', kind: 'open', range: [15, 41] }] } });
  items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items[1].reply, { seq: 0, block: 0 });
  assert.deepEqual(items[1].annotations, [{ type: 'question', kind: 'choice', range: [2, 11], options: [[7, 10]] }]);
  const child = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }); t.after(() => child.close()); child.rebuild(...linked([assistant(text)]));
  assert.equal(JSON.parse(request(child, '/items?before=100').join('')).items[0].blocks[0].text, text);
});

test('topic attribution labels final prefixes with metadata without changing them', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const user = { role: 'user' as const, content: 'work', timestamp: 100 };
  const prefix = { ...assistant(''), content: [{ type: 'thinking' as const, thinking: 'Plan' }] };
  view.message(user, 'end'); view.message(prefix, 'end');
  const before = JSON.parse(request(view, '/items?before=100').join('')).items;
  view.message({ ...assistant('[topic: one]\nFirst\n[topic: two]\nSecond'), timestamp: 130 }, 'end');
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items[1], before[1]); assert.equal(items[1].final, true);
  assert.ok(items.some((item: { kind: string; target?: number; topics?: string[] }) => item.kind === 'topics' && item.target === 1 && item.topics?.join() === 'one'));
  assert.deepEqual(items.filter((item: { kind: string; target?: number }) => item.kind === 'topics' && item.target === 0).at(-1).topics, ['one', 'two']);
  const filtered = JSON.parse(request(view, '/items?before=100&topic=two').join(''));
  assert.ok(filtered.items.some((item: { kind: string }) => item.kind === 'user'));
  assert.equal(filtered.more, false);
  const prefixPage = JSON.parse(request(view, '/items?before=1&topic=two').join(''));
  assert.deepEqual(prefixPage.items.map((item: WireItem) => item.kind), ['user', 'topics']);
  assert.deepEqual(prefixPage.items[1].topics, ['one', 'two']);
  assert.equal(prefixPage.items[1].target, 0);
  assert.equal(prefixPage.more, false);
});

test('streaming markers do not leak and explicit users stay in one topic', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  view.message({ role: 'user', content: '[topic: selected]\nwork', timestamp: 100 }, 'end');
  view.message(assistant('[topic: one]\nBody\n[topi'), 'update');
  let items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.equal(items[0].text, 'work'); assert.equal(items[0].topic, 'selected');
  assert.deepEqual(items[1].blocks.map((block: { text: string }) => block.text), ['Body\n']);
  view.message(assistant('[topic: one]\nBody\n[topic: two]\nOther'), 'end');
  items = JSON.parse(request(view, '/items?before=100&topic=two').join('')).items;
  assert.equal(items.some((item: WireItem) => item.kind === 'user'), false);
});

test('topic intervals follow inputs, tools inherit the turn topic and unmarked replies stay unlabelled', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const inbound: AgentMessage = { role: 'custom', customType: 'agent-message', display: true, content: 'event', details: { topic: 'agent', agent: { name: 'worker' }, body: 'event', inbound: { form: 'message', relation: 'child' } }, timestamp: 100 };
  const tool = { ...assistant(''), content: ['read', 'spawn_agent', 'message_agent', 'async_bash'].map(name => ({ type: 'toolCall' as const, id: name, name, arguments: { path: '/tmp/file' } })) };
  const messages: AgentMessage[] = [
    { role: 'user', content: 'first', timestamp: 90 }, assistant('[topic: first]\nFirst'),
    inbound, tool,
    { role: 'user', content: 'steer', timestamp: 140 }, { ...assistant('[topic: steer]\nSteered'), timestamp: 150 },
    { role: 'user', content: 'follow-up', timestamp: 160 }, { ...assistant('No marker'), timestamp: 170 },
  ];
  view.rebuild(...linked(messages));
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.equal(items.find((item: { kind: string }) => item.kind === 'agent').topic, 'agent');
  assert.deepEqual(items.find((item: { kind: string; blocks?: { type: string }[] }) => item.kind === 'assistant' && item.blocks?.[0].type === 'tool').blocks.map((block: { topic?: string }) => block.topic), ['agent', 'agent', 'agent', 'agent']);
  const users = items.filter((item: { kind: string }) => item.kind === 'user');
  const names = (seq: number) => items.filter((item: { kind: string; target?: number }) => item.kind === 'topics' && item.target === seq).at(-1)?.topics;
  assert.deepEqual(names(users[0].seq), ['first']); assert.deepEqual(names(users[1].seq), ['steer']); assert.equal(names(users[2].seq), undefined);
  const unmarked = items.filter((item: { kind: string }) => item.kind === 'assistant').at(-1);
  assert.deepEqual(unmarked.blocks.map((block: { topic?: string }) => block.topic), [undefined]);
});

test('topic state keeps entry order, raw last section and source time through compaction', t => {
  let branch: SessionEntry[] = [];
  const view = transcript({ sessionEntryToContextMessages, branch: () => branch, dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const historical = { type: 'message' as const, id: 'old', parentId: null, timestamp: new Date(123).toISOString(), message: assistant('[topic: old]\n**raw summary**\nBody') };
  const entries = [historical, { type: 'custom' as const, id: 'empty', parentId: 'old', timestamp: new Date(124).toISOString(), customType: 'koa.topic', data: { name: 'empty', at: 124 } }, { type: 'custom' as const, id: 'index', parentId: 'empty', timestamp: new Date(125).toISOString(), customType: 'koa.topic', data: { name: 'old', at: 125 } }];
  branch = entries; view.rebuild(entries, 'session', 'index');
  assert.deepEqual(view.topics(), [{ name: 'old', last: { summary: '**raw summary**', at: 123 } }]);
  view.message({ ...assistant('[topic: fresh]\n# New'), timestamp: 200 }, 'update');
  request(view, '/items?before=100');
  assert.deepEqual(view.topics().at(-1), { name: 'fresh', last: { summary: '# New', at: 200 } });
  view.annotation({ type: 'custom', id: 'promoted', parentId: 'index', timestamp: new Date(201).toISOString(), customType: 'koa.topic', data: { name: 'fresh', at: 200 } });
  assert.deepEqual(view.topics().map(topic => topic.name), ['old', 'fresh']);
});

test('topic rebuild emits one final label set per user across several assistant messages', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  view.rebuild(...linked([{ role: 'user', content: 'both', timestamp: 1 }, { ...assistant('[topic: one]\nOne'), timestamp: 2 }, { ...assistant('[topic: two]\nTwo'), timestamp: 3 }, { role: 'user', content: 'next', timestamp: 4 }]));
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  const labels = items.filter((item: { kind: string; target?: number }) => item.kind === 'topics' && item.target === 0);
  assert.equal(labels.length, 1); assert.deepEqual(labels[0].topics, ['one', 'two']);
  assert.deepEqual(items.filter((item: { kind: string }) => item.kind === 'user').map((item: { text: string }) => item.text), ['both', 'next']);
});

test('live output bounds keep a UTF-8 tail and count omitted bytes', () => {
  assert.deepEqual(appendBashOutput({ text: 'first', cut: 4 }, '😀' + 'x'.repeat(16383)), { text: 'x'.repeat(16383), cut: 13 });
  assert.deepEqual(appendBashOutput({ text: '😀', cut: 0 }, 'x'.repeat(16380)), { text: '😀' + 'x'.repeat(16380), cut: 0 });
});

test('stored bash facts survive live conversion and authoritative rebuild', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }); t.after(() => view.close());
  const message = { role: 'bashExecution' as const, command: 'quiet', output: 'partial', exitCode: 2, cancelled: true, truncated: true, fullOutputPath: '/tmp/full', excludeFromContext: true, timestamp: 42 };
  view.message(message, 'end');
  const live = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(live, [{ seq: 0, revision: 1, at: 42, final: true, kind: 'bash', command: 'quiet', result: { output: { text: 'partial', cut: 0 }, exit: 2, cancelled: true, truncated: true, fullOutputPath: '/tmp/full' }, excludeFromContext: true }]);
  view.rebuild(...linked([message]));
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, fresh(live));
});

test('reply annotations resolve live and replay, validate code points and keep cursor and paging items', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  t.after(() => view.close());
  const message = assistant('😀 Pick one or two?');
  const question = { type: 'question', kind: 'choice', range: [2, 18], options: [[7, 10], [14, 17], [0, 1], [9, 8], [7, 30]] };
  const entry = { type: 'custom' as const, id: 'annotation', parentId: null, customType: 'reply-annotations', timestamp: new Date(124).toISOString(), data: { reply: { at: 123, block: 0, length: 18 }, annotations: [question, { ...question, type: 'future' }, { ...question, kind: 'future' }, { ...question, range: [18, 2] }, { ...question, range: [0, 19] }] } };
  view.message(message, 'start'); view.message(message, 'end');
  const events = request(view, '/events'), epoch = record(events[0]).epoch;
  view.annotation(entry);
  const item = { seq: 1, revision: 1, at: 124, final: true, kind: 'annotations', reply: { seq: 0, block: 0 }, annotations: [{ ...question, options: [[7, 10], [14, 17]] }] };
  assert.deepEqual(record(events.at(-1)).item, item);
  assert.deepEqual(record(request(view, '/events?epoch=' + epoch + '&after=0')[0]).item, item);
  const live = JSON.parse(request(view, '/items?before=100').join('')).items;
  for (const bad of [{ ...entry, data: { ...entry.data, reply: { ...entry.data.reply, length: 19 } } }, { ...entry, data: { ...entry.data, reply: { ...entry.data.reply, at: 999 } } }, { ...entry, data: { ...entry.data, annotations: [{ ...question, type: 'unknown' }] } }]) view.annotation(bad);
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, live);
  const replacement = { ...entry, id: 'replacement', parentId: entry.id, timestamp: new Date(126).toISOString(), data: { ...entry.data, annotations: [{ ...question, kind: 'open' }] } };
  view.annotation(replacement);
  const replaced = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.equal(replaced[2].annotations[0].kind, 'open'); assert.equal(replaced[2].annotations[0].options, undefined);
  view.rebuild(linked([message, { ...assistant('Later'), timestamp: 130 }], 'same', [entry, replacement])[0], 'same', 'replacement');
  const replay = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(replay.slice(0, 3), fresh(replaced));
  assert.deepEqual(replay.map((item: WireItem) => item.kind), ['assistant', 'annotations', 'annotations', 'assistant']);
  assert.deepEqual(JSON.parse(request(view, '/items?before=2').join('')).items, fresh(live));
});

test('reply annotations keep disjoint questions and options in text order', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  t.after(() => view.close());
  view.rebuild(...linked([assistant('01234567890123456789')]));
  const question = (range: number[], options: number[][] = []) => ({ type: 'question', kind: 'choice', range, options });
  view.annotation({ type: 'custom', id: 'overlap', parentId: null, timestamp: new Date(124).toISOString(), customType: 'reply-annotations', data: {
    reply: { at: 123, block: 0, length: 20 },
    annotations: [question([8, 14]), question([2, 10], [[7, 9], [3, 6], [5, 8], [6, 7], [3, 4]]), question([10, 15]), question([15, 20]), question([2, 3])],
  } });
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items[1].annotations, [question([2, 10], [[3, 6], [6, 7], [7, 9]]), question([10, 15]), question([15, 20])]);
});

test('reply annotation replay follows the active leaf, not another branch with the same reply', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  t.after(() => view.close());
  const message = assistant('Should I proceed?');
  const root = { type: 'message' as const, id: 'reply', parentId: null, timestamp: new Date(123).toISOString(), message };
  const left = { type: 'custom' as const, id: 'left', parentId: root.id, timestamp: new Date(124).toISOString(), customType: 'reply-annotations', data: { reply: { at: 123, block: 0, length: 17 }, annotations: [{ type: 'question', kind: 'open', range: [0, 17] }] } };
  const right = { ...left, id: 'right', timestamp: new Date(125).toISOString(), data: { ...left.data, annotations: [{ type: 'question', kind: 'yes_no', range: [0, 17] }] } };
  for (const [leaf, kind] of [['left', 'open'], ['right', 'yes_no']]) {
    view.rebuild([root, left, right], 'branch', leaf);
    const items = JSON.parse(request(view, '/items?before=100').join('')).items;
    assert.equal(items.length, 2); assert.equal(items[1].annotations[0].kind, kind);
  }
  view.rebuild([root, left, right], 'branch', root.id);
  assert.equal(JSON.parse(request(view, '/items?before=100').join('')).items.length, 1);
  view.annotation({ ...left, timestamp: 'not a timestamp' });
  assert.equal(JSON.parse(request(view, '/items?before=100').join('')).items.length, 1);
});

test('reply annotation replay keeps branch message order when timestamps go backward', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  t.after(() => view.close());
  view.rebuild(...linked([{ ...assistant('first'), timestamp: 200 }, { ...assistant('second'), timestamp: 100 }]));
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items.map((item: { blocks: { text: string }[] }) => item.blocks[0].text), ['first', 'second']);
});

test('startup notifications bind to the first session and not to a later session', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  view.notify('Extension failed to load', 'error');
  view.rebuild(...linked([], 'first-session'));
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.equal(items.length, 1); assert.equal(items[0].text.text, 'Extension failed to load');
  view.rebuild(...linked([], 'second-session'));
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, []); view.close();
});

test('notifications are retained transcript items across reconnect and same-session rebuild', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }), first = assistant('before');
  view.rebuild(...linked([first], 'session-one'));
  view.notify('Remember this warning', 'warning');
  const live = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.equal(live.length, 2);
  assert.equal(live[1].kind, 'notify'); assert.equal(live[1].text.text, 'Remember this warning');
  view.rebuild(...linked([first], 'session-one'));
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, fresh(live));
  const reconnect = record(request(view, '/events')[0]);
  assert.deepEqual(reconnect.items, fresh(live));
  const later = { ...assistant('after'), timestamp: live[1].at + 1 };
  view.rebuild(...linked([first, later], 'session-one'));
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items.map((item: WireItem) => item.kind), ['assistant', 'notify', 'assistant']);
  view.notify('x'.repeat(20000), 'error');
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items.at(-1).text, { text: 'x'.repeat(16384), cut: 3616 });
  view.rebuild(...linked([], 'new-session')); assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, []); view.close();
});

test('structured agent and job details render identically live and on rebuild', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }), log = join(directory(t), 'build.log');
  writeFileSync(log, '');
  const messages: AgentMessage[] = [
    { role: 'custom', customType: 'ko-message', display: true, timestamp: 1, content: 'Do not parse this header', details: { agent: { name: 'boss', session: 'boss-id', pane: 'pane_2' }, body: 'Review the module', inbound: { form: 'message', relation: 'parent', runtime: 'dev' } } },
    { role: 'custom', customType: 'ko-stream', display: true, timestamp: 2, content: 'Do not parse this output', details: { job: { id: 'j1', name: 'build', service: false, log, command: 'make', startedAt: 1, place: { type: 'mac' as const } }, batch: 'compiled', omitted: 2, cut: true } },
    { role: 'custom', customType: 'other-extension', display: true, timestamp: 3, content: 'plain notice', details: {} },
  ];
  for (const message of messages) view.message(message, 'end');
  const live = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(live[0], { seq: 0, revision: 1, at: 1, final: true, kind: 'agent', direction: 'in', from: { name: 'boss', session: 'boss-id', pane: 'pane_2' }, text: { text: 'Review the module', cut: 0 }, inbound: { form: 'message', relation: 'parent', runtime: 'dev' } });
  assert.deepEqual(live[1], { seq: 1, revision: 1, at: 2, final: true, kind: 'job', job: { id: 'j1', name: 'build', service: false, log, command: 'make', startedAt: 1, place: { type: 'mac' as const } }, event: { type: 'stream', batch: { text: 'compiled', cut: 0 }, omitted: 2, cut: true } });
  assert.equal(live[2].kind, 'notice'); view.rebuild(...linked(messages));
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, fresh(live)); view.close();
});

test('agent forms and every job ending use typed details, capped bodies and strict shape checks', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }), agent = { name: 'worker' }, job = { id: 'j', name: 'build', service: false, log: '/tmp/log', command: 'make', startedAt: 1, place: { type: 'mac' as const } };
  const forms = [
    { customType: 'ko-steer', details: { agent, body: 'redirect', inbound: { form: 'steer' } }, inbound: { form: 'steer' } },
    { customType: 'ko-notice', details: { agent, inbound: { form: 'report' }, body: 'x'.repeat(20000) }, inbound: { form: 'report' } },
    { customType: 'ko-notice', details: { agent, inbound: { form: 'notice' }, body: 'notice' }, inbound: { form: 'notice' } },
    { customType: 'ko-notice', details: { agent, inbound: { form: 'ended', reported: false }, body: 'an ended form is not a notice' }, inbound: undefined },
  ];
  for (const [index, value] of forms.entries()) view.message({ role: 'custom', display: true, timestamp: index, customType: value.customType, content: 'Do not read me', details: value.details }, 'end');
  const ends = [{ type: 'exit', code: 0 }, { type: 'exit', code: 1 }, { type: 'signal', signal: 'SIGKILL' }, { type: 'failed', message: 'could not start' }, { type: 'timeout', seconds: 600 }, { type: 'stopped' }];
  for (const end of ends) view.message({ role: 'custom', display: true, timestamp: 5, customType: 'ko-notice', content: 'wrong', details: { kind: 'job', job: { ...job, end }, tail: 'tail' } }, 'end');
  view.message({ role: 'custom', display: true, timestamp: 6, customType: 'ko-notice', content: 'unknown', details: { agent, inbound: { form: 'ended' }, body: 'not a typed ending' } }, 'end');
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items.slice(0, forms.length - 1).map((item: { inbound: unknown }) => item.inbound), forms.slice(0, -1).map(value => value.inbound));
  assert.equal(items[forms.length - 1].kind, 'notice');
  assert.deepEqual(items[1].text, { text: 'x'.repeat(16384), cut: 3616 });
  assert.deepEqual(items.slice(forms.length, forms.length + ends.length).map((item: { event: { end: unknown } }) => item.event.end), ends);
  assert.equal(items.at(-1).kind, 'notice'); view.close();
});

test('agent tool cards keep full capped arguments and typed outcomes on live and replay paths', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 }), message = assistant(''), log = join(directory(t), 'build.log');
  writeFileSync(log, '');
  message.content = [
    { type: 'toolCall', id: 'spawn', name: 'spawn_agent', arguments: { name: 'worker', task: 'x'.repeat(20000), model: 'provider/model' } },
    { type: 'toolCall', id: 'send', name: 'message_agent', arguments: { to: 'worker', message: 'Review', mode: 'steer' } },
    { type: 'toolCall', id: 'job', name: 'async_bash', arguments: { command: 'make', name: 'build' } },
  ];
  view.message(message, 'start');
  const before = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks;
  assert.deepEqual(before[0].agent.text, { text: 'x'.repeat(16384), cut: 3616 }); assert.equal(before[0].agent.outcome, undefined);
  const results: Extract<AgentMessage, { role: 'toolResult' }>[] = [
    { role: 'toolResult', toolCallId: 'spawn', toolName: 'spawn_agent', content: [{ type: 'text', text: 'do not parse this result' }], isError: false, timestamp: 200, details: { name: 'worker', session: 'worker-id', pane: 'pane_2', outcome: { ok: true } } },
    { role: 'toolResult', toolCallId: 'send', toolName: 'message_agent', content: [], isError: false, timestamp: 201, details: { to: 'worker', outcome: { ok: false, failure: 'refused', message: 'Not now' } } },
    { role: 'toolResult', toolCallId: 'job', toolName: 'async_bash', content: [], isError: false, timestamp: 202, details: { job: { id: 'j1', name: 'build', log, service: true, command: 'make', startedAt: 1, place: { type: 'mac' as const } }, stream: false } },
  ];
  for (const result of results) view.toolDone(result.toolCallId, result.content, result.isError, result.timestamp, undefined, undefined, result.details);
  const live = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks;
  assert.deepEqual(live[0].agent.to, { name: 'worker', session: 'worker-id', pane: 'pane_2' });
  assert.deepEqual(live[1].agent.outcome, { ok: false, failure: 'refused', message: 'Not now' }); assert.equal(live[1].agent.text.text, 'Review');
  assert.deepEqual(live[2].job, { id: 'j1', name: 'build', log, service: true, command: 'make', startedAt: 1, place: { type: 'mac' as const } });
  view.rebuild(...linked([message, ...results])); const replay = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks;
  assert.deepEqual(replay.map((block: { agent?: unknown; job?: unknown }) => [block.agent, block.job]), live.map((block: { agent?: unknown; job?: unknown }) => [block.agent, block.job])); view.close();
});

test("events use SSE framing", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 10 });
  const lines = request(view, "/events");
  assert.ok(lines.length > 0);
  for (const line of lines) {
    assert.match(line, /^data: .*\n\n$/);
    assert.equal(JSON.parse(line.slice(6)).type, "reset");
  }
  view.close();
});

test("caps preserve UTF-8 and windows retain the newest hundred messages", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  view.message({ role: "bashExecution", command: "test", output: "a".repeat(16383) + "😀", exitCode: 0, cancelled: false, truncated: false, timestamp: 12 }, "end");
  const item = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(item.kind, "bash");
  if (item.kind !== "bash") return;
  assert.deepEqual(item.result.output, { text: "a".repeat(16383), cut: 4 });
  assert.equal(item.at, 12);
  for (let i = 0; i < 105; i++) view.message({ role: "user", content: `message ${i}`, timestamp: i }, "end");
  const page = JSON.parse(request(view, "/items?before=106").join(""));
  assert.equal(page.items.length, 100);
  assert.equal(page.items[0].text, "message 5");
  assert.equal(page.items.at(-1).text, "message 104");
  assert.equal(page.more, true);
  view.close();
});

test('tool-heavy reset and older pages count messages, including with a topic filter', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const messages: AgentMessage[] = [];
  for (let turn = 0; turn < 120; turn++) {
    messages.push({ role: 'user', content: '[topic: one]\nQuestion ' + turn, timestamp: turn });
    for (let step = 0; step < 5; step++) {
      const id = turn + '-' + step;
      messages.push({ ...assistant(''), content: [{ type: 'toolCall', id, name: 'bash', arguments: { command: 'x'.repeat(4096) } }] });
      messages.push({ role: 'toolResult', toolCallId: id, toolName: 'bash', content: [{ type: 'text', text: 'y'.repeat(16384) }], isError: false, timestamp: turn });
    }
    messages.push(assistant('[topic: one]\nAnswer ' + turn));
  }
  view.rebuild(...linked(messages));
  const counted = (item: WireItem) => item.kind === 'user' || item.kind === 'assistant' && item.blocks.some(block => block.type === 'text' && block.text.trim());
  const check = (page: { items: WireItem[]; more: boolean }, first: string) => {
    assert.equal(page.items.filter(counted).length, 100);
    assert.equal(page.items[0].kind === 'user' && page.items[0].text, first);
    assert.equal(page.items.filter(item => item.kind === 'assistant' && !counted(item)).length, 250);
    assert.equal(page.more, true);
  };
  const reset = record(request(view, '/events')[0]);
  check(reset, 'Question 70');
  for (const suffix of ['', '&topic=one']) {
    const newest = JSON.parse(request(view, '/items?before=' + Number.MAX_SAFE_INTEGER + suffix).join(''));
    check(newest, 'Question 70');
    const older = JSON.parse(request(view, '/items?before=' + newest.items[0].seq + suffix).join(''));
    check(older, 'Question 20');
  }
});

test('sparse topic pages contain only selected messages and their run context', t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1, kind: 'root' }); t.after(() => view.close());
  const messages: AgentMessage[] = [
    { ...assistant(''), content: [{ type: 'toolCall', id: 'mixed-two', name: 'read', arguments: { path: 'two' } }] },
    { role: 'toolResult', toolCallId: 'mixed-two', toolName: 'read', content: [], details: { topic: 'two' }, isError: false, timestamp: 123 },
    { ...assistant(''), content: [{ type: 'toolCall', id: 'mixed-one', name: 'read', arguments: { path: 'one' } }, { type: 'text', text: '[topic: one]\nMixed reply' }] },
    { role: 'toolResult', toolCallId: 'mixed-one', toolName: 'read', content: [], details: { topic: 'one' }, isError: false, timestamp: 123 },
  ];
  for (let turn = 0; turn < 105; turn++) {
    messages.push({ role: 'user', content: '[topic: one]\nQuestion ' + turn, timestamp: turn });
    for (const topic of ['one', 'two']) {
      const id = turn + topic;
      messages.push({ ...assistant(''), content: [{ type: 'toolCall', id, name: 'read', arguments: { path: topic } }] });
      messages.push({ role: 'toolResult', toolCallId: id, toolName: 'read', content: [{ type: 'text', text: topic }], details: { topic }, isError: false, timestamp: turn });
    }
    messages.push(assistant('[topic: two]\nOther ' + turn));
  }
  view.rebuild(...linked(messages));
  view.notify('Trailing boundary notice', 'info');
  const get = (before: number, topic = 'one'): { items: WireItem[]; more: boolean } => JSON.parse(request(view, '/items?before=' + before + '&topic=' + topic).join(''));
  const newest = get(Number.MAX_SAFE_INTEGER);
  assert.equal(newest.items.filter(item => item.kind === 'user').length, 100);
  assert.equal(newest.items[0].kind === 'user' && newest.items[0].text, 'Question 5');
  assert.equal(newest.items.filter(item => item.kind === 'assistant' && item.blocks.some(block => block.type === 'tool')).length, 200);
  assert.ok(newest.items.length < 450, 'sparse page returned ' + newest.items.length + ' rows');
  assert.equal(newest.items.some(item => item.kind === 'assistant' && item.blocks.some(block => block.type === 'text' && block.text.startsWith('Other '))), false);
  assert.equal(newest.more, true);
  assert.equal(new Set(newest.items.map(item => item.seq)).size, newest.items.length);
  const cursor = Math.min(...newest.items.filter(item => item.kind !== 'topics' && item.kind !== 'annotations').map(item => item.seq));
  const older = get(cursor);
  assert.equal(older.items.filter(item => item.kind === 'user').length, 5);
  assert.deepEqual(older.items.slice(0, 2).map(item => item.kind === 'assistant' ? item.blocks.map(block => block.topic) : []), [['two'], ['one', 'one']]);
  const raw = new Map(older.items.map(item => [item.seq, item]));
  const context: TopicContext = { items: raw, labels: () => [], runs: { raw: seq => raw.get(seq), shown: seq => raw.get(seq), owners: new Map() } };
  assert.equal(projectTopic(context, 0, parseTopicName('one')), undefined);
  const mixed = projectTopic(context, 1, parseTopicName('one'));
  assert.deepEqual(mixed?.kind === 'assistant' ? mixed.blocks.map(block => block.type) : [], ['text', 'text']);
  assert.equal(older.more, false);
  assert.ok(older.items.every(item => item.kind === 'topics' || item.kind === 'annotations' || item.seq < cursor));
  const unmatched = get(cursor, 'missing');
  assert.equal(unmatched.more, false);
  assert.deepEqual(unmatched.items, []);
});

test("patches append only unchanged text prefixes and replace changed blocks", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const lines = request(view, "/events");
  view.message(assistant("hello"), "start");
  view.message(assistant("hello world"), "update");
  request(view, "/events");
  assert.deepEqual(record(lines.findLast(line => line.includes('"type":"patch"'))).blocks, [{ index: 0, suffix: " world" }]);
  view.message(assistant("replacement"), "update");
  request(view, "/events");
  assert.deepEqual(record(lines.findLast(line => line.includes('"type":"patch"'))).blocks, [{ index: 0, block: { type: "text", text: "replacement" } }]);
  view.message(assistant("replacement", "error"), "end");
  const patch = record(lines.findLast(line => line.includes('"type":"patch"')));
  assert.equal(patch.stop, "error");
  assert.equal(patch.final, true);
  assert.deepEqual(patch.blocks, []);
  assert.equal(JSON.parse(request(view, "/items?before=100").join("")).items[0].at, 123);
  const thinking = assistant("");
  thinking.content = [{ type: "thinking", thinking: "hidden", redacted: false }];
  view.message(thinking, "start");
  thinking.content = [{ type: "thinking", thinking: "hidden", redacted: true }];
  view.message(thinking, "update");
  request(view, "/events");
  assert.deepEqual(record(lines.findLast(line => line.includes('"type":"patch"'))).blocks, [{ index: 0, block: { type: "thinking", text: "hidden", redacted: true } }]);
  view.close();
});

test("a history snapshot holds only published state and carries the stream's revision", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const lines = request(view, "/events");
  view.message(assistant("hello"), "start");
  view.message(assistant("hello world"), "update");
  const page = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  const patch = record(lines.findLast(line => line.includes('"type":"patch"')));
  assert.deepEqual([page.revision, page.blocks[0].text, patch.baseRevision, patch.revision, patch.blocks], [2, "hello world", 1, 2, [{ index: 0, suffix: " world" }]]);
  view.message(assistant("hello world!"), "update");
  request(view, "/events");
  const next = record(lines.findLast(line => line.includes('"type":"patch"')));
  assert.deepEqual([next.baseRevision, next.revision, next.blocks], [2, 3, [{ index: 0, suffix: "!" }]]);
  view.close();
});

test("tool timing survives assistant updates and reaches patches", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const message = assistant("");
  message.content = [{ type: "toolCall", id: "call", name: "read", arguments: { path: "file" } }];
  const lines = request(view, "/events");
  view.message(message, "start");
  view.toolRunning("call", 200);
  view.toolPartial("call", [{ type: "text", text: "partial" }]);
  view.toolDone("call", [{ type: "text", text: "done" }], false, 250, 49);
  view.message(message, "end");
  const item = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(item.kind, "assistant");
  if (item.kind !== "assistant") return;
  assert.deepEqual(item.blocks[0], { type: "tool", id: "call", name: "read", args: { text: '{"path":"file"}', cut: 0 }, state: { type: "done", result: { text: "done", cut: 0, images: [] }, error: false }, started: 200, ended: 250, durationMs: 49 });
  assert.equal(lines.some(line => line.includes('"started":200') && line.includes('"ended":250') && line.includes('"durationMs":49')), true);
  assert.equal(lines.some(line => line.includes('"text":"partial"')), false);
  view.rebuild(...linked([message, { role: "toolResult", toolCallId: "call", toolName: "read", content: [{ type: "text", text: "saved" }], isError: false, timestamp: 300 }]));
  const restored = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(restored.kind, "assistant");
  if (restored.kind === "assistant" && restored.blocks[0].type === "tool") assert.deepEqual({ started: restored.blocks[0].started, ended: restored.blocks[0].ended }, { started: 123, ended: 300 });
  else assert.fail("The restored tool is missing");
  view.close();
});

test("bash exit codes come from structured results or the status footer", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const message = assistant("");
  message.content = [{ type: "toolCall", id: "call", name: "bash", arguments: { command: "make verify" } }];
  const block = () => JSON.parse(request(view, "/items?before=100").join("")).items[0].blocks[0];
  view.message(message, "start");
  view.toolDone("call", [{ type: "text", text: "failed\n\nCommand exited with code 101" }], true, 250, 49, { exit_code: 101 });
  assert.equal(block().exit, 101);
  assert.equal(block().state.result.text, "failed");
  view.rebuild(...linked([message, { role: "toolResult", toolCallId: "call", toolName: "bash", content: [{ type: "text", text: "saved\n\nCommand exited with code 7" }], isError: true, timestamp: 300 }]));
  assert.equal(block().exit, 7);
  assert.equal(block().state.result.text, "saved");
  view.close();
});

test("delivered attachment paths are data and a rebuild never guesses them", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  const lines = request(view, "/events");
  const file = { id: "upload", name: "data.txt", size: 4, path: "/tmp/copy/data.txt", kind: "file" as const };
  const message = { role: "user" as const, timestamp: 1, content: "Inspect\n" + file.path };
  view.message(message, "start");
  view.message(message, "end", undefined, [file]);
  const item = lines.map(record).filter(record => record.type === "item").at(-1)?.item;
  assert.equal(item?.text, "Inspect");
  assert.deepEqual(item?.attachments, [file]);
  lines.length = 0;
  view.rebuild(...linked([message]));
  const rebuilt = lines.map(record).find(record => record.type === "reset")?.items[0];
  assert.equal(rebuilt?.text, message.content);
  assert.deepEqual(rebuilt?.attachments, []);
  view.close();
});

test("identical image partials emit no patch and changed bytes advance the wire revision", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const lines = request(view, "/events");
  view.message({ ...assistant(""), content: [{ type: "toolCall", id: "image", name: "read", arguments: {} }] }, "start");
  const image = { type: "image" as const, mimeType: "image/png", data: Buffer.from("old").toString("base64") }, old = [image];
  view.toolPartial("image", old); request(view, "/events");
  const before = lines.length;
  view.toolPartial("image", old); request(view, "/events");
  assert.equal(lines.length, before);
  const next = [{ ...image, data: Buffer.from("new").toString("base64") }];
  view.toolPartial("image", next); request(view, "/events");
  assert.equal(lines.length, before + 1);
  const patch = record(lines.at(-1));
  assert.equal(patch.type, "patch");
  assert.deepEqual(patch.blocks[0].block.state.result.images, [{ id: "0.0.0", revision: 1, mimeType: "application/octet-stream", bytes: 3 }]);
  view.close();
});

test("rebuild sends reset then exactly one caller-supplied state and keeps the epoch format", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const state = { pathEditor: false, agents: [], bash: [], compaction: 'idle' as const, working: false, name: "before", model: { provider: "test", id: "test" }, aborted: false, levels: [], cwd: "/tmp", home: "/tmp", dialogs: [], statuses: {}, queue: { steering: [], followUp: [], classifying: [] }, view: { id: "root", path: [{ id: "root", name: "pi", type: "agent" as const }], type: 'root' as const }, topics: [], life: { type: "ready" as const } };
  view.state(state);
  const lines = request(view, "/events");
  assert.deepEqual(lines.map(record).map(record => record.type), ['state', 'reset']);
  const firstEpoch = record(lines[1]).epoch;
  assert.match(firstEpoch, /^[A-Za-z0-9_-]{22}$/);
  lines.length = 0;
  view.rebuild(...linked([{ role: "user", content: "restored", timestamp: 456 }]));
  view.state({ ...state, working: true, name: "after" });
  const records = lines.map(record);
  assert.deepEqual(records.map(record => record.type), ["reset", "state"]);
  assert.deepEqual(records[0].items, [{ seq: 0, revision: 0, at: 456, final: true, kind: "user", text: "restored", images: [], attachments: [] }]);
  assert.match(records[0].epoch, /^[A-Za-z0-9_-]{22}$/);
  assert.notEqual(records[0].epoch, firstEpoch);
  assert.deepEqual(records[1], { ...state, type: "state", working: true, name: "after" });
  view.close();
});

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==", "base64");

test("image references keep disk bytes beyond the feed window and serve missing and unknown images", async t => {
  const dir = directory(t);
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir, flushMs: 1 });
  const server = createServer((request, response) => { if (!view.handle(request, response)) { response.writeHead(404); response.end(); } });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise<void>(resolve => { view.close(); server.closeAllConnections(); server.close(() => resolve()); }));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const url = `http://127.0.0.1:${address.port}`;
  const user = { role: "user" as const, timestamp: 1, content: [{ type: "text" as const, text: "Compare this" }, { type: "image" as const, mimeType: "image/png", data: png.toString("base64") }] };
  view.message(user, "end");
  const page: { items: WireItem[] } = await (await fetch(url + "/items?before=1")).json();
  const item = page.items[0];
  assert.equal(item?.kind, "user");
  if (item?.kind !== "user") return;
  assert.ok(Array.isArray(item.images));
  assert.equal(item.images.length, 1);
  const image = item.images[0];
  assert.ok(image);
  assert.deepEqual(image, { id: image.id, revision: 0, mimeType: "image/png", bytes: png.length, width: 1, height: 1 });
  assert.deepEqual(readFileSync(join(dir, "images", image.id)), png);
  const call: Extract<AgentMessage, { role: "assistant" }> = { role: "assistant", timestamp: 2, api: "openai-responses", provider: "openai", model: "test", stopReason: "toolUse", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, content: [{ type: "toolCall", id: "a", name: "read", arguments: {} }, { type: "toolCall", id: "b", name: "read", arguments: {} }] };
  view.message(call, "start");
  const imageContent = { type: "image" as const, data: png.toString("base64"), mimeType: "image/png" }, content = [imageContent];
  view.toolPartial("a", content); view.toolRunning("b", 3);
  const path = join(dir, "images", "1.0.0"), inode = statSync(path).ino;
  view.toolPartial("a", content); view.toolRunning("b", 4);
  assert.equal(statSync(path).ino, inode, "an identical partial result must not rewrite its image");
  const changed = Buffer.from(png); changed.writeUInt8(changed.readUInt8(changed.length - 1) ^ 1, changed.length - 1);
  const replacement = [{ ...imageContent, data: changed.toString("base64") }];
  view.toolPartial("a", replacement); view.toolRunning("b", 5);
  const current: { items: WireItem[] } = await (await fetch(url + "/items?before=2")).json();
  const block = current.items[1]?.kind === "assistant" ? current.items[1].blocks[0] : undefined;
  assert.ok(block?.type === "tool" && "result" in block.state && block.state.result);
  assert.equal(block.state.result.images[0]?.revision, 1);
  assert.deepEqual(Buffer.from(await (await fetch(url + "/images/1.0.0?r=1")).arrayBuffer()), changed);
  view.toolDone("b", content, false, 6);
  view.toolDone("a", [], false, 7);
  assert.equal((await fetch(url + "/images/1.0.0")).status, 404);
  assert.equal((await fetch(url + "/images/1.1.0")).status, 200, "another tool block keeps its image");
  for (let i = 0; i < 105; i++) view.message({ role: "user", timestamp: i + 2, content: "later" }, "end");
  const response = await fetch(url + "/images/" + image.id);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(response.headers.get("content-length"), String(png.length));
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
  rmSync(join(dir, "images", image.id));
  assert.equal((await fetch(url + "/images/" + image.id)).status, 410);
  assert.equal((await fetch(url + "/images/unknown")).status, 404);
  view.rebuild(...linked([user]));
  assert.deepEqual(readFileSync(join(dir, "images", image.id)), png);
  view.rebuild(...linked([]));
  assert.equal((await fetch(url + "/images/" + image.id)).status, 404);
  for (const [mimeType, data] of [["text/html", "<!doctype html><script>globalThis.pwned=true</script>"], ["image/svg+xml", '<svg xmlns="http://www.w3.org/2000/svg"><script>globalThis.pwned=true</script></svg>']]) {
    assert.ok(mimeType !== undefined && data !== undefined);
    view.rebuild(...linked([{ role: "user", timestamp: 1, content: [{ type: "image", mimeType, data: Buffer.from(data).toString("base64") }] }]));
    const response = await fetch(url + "/images/0.0");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/octet-stream");
    assert.equal(response.headers.get("x-content-type-options"), "nosniff");
    assert.equal(response.headers.get("content-security-policy"), "sandbox; default-src 'none'");
    assert.equal(await response.text(), data);
  }
});

test("an aborted turn shows no provider error text and a real error still shows", t => {
  const view = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1 });
  view.message({ ...assistant("partial"), stopReason: "aborted", errorMessage: "Request was aborted" }, "end");
  view.message({ ...assistant("failed", "error"), errorMessage: "provider said no" }, "end");
  const items = JSON.parse(request(view, "/items?before=100").join("")).items;
  assert.deepEqual(items.map((item: { stop: string; error: string }) => [item.stop, item.error]), [["aborted", ""], ["error", "provider said no"]]);
  view.close();
});

test("show moves the open pages to this feed, sends its state before the reset under a fresh epoch", t => {
  const before = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 }), after = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  const state = { pathEditor: false, agents: [], bash: [], compaction: 'idle' as const, working: false, name: "a", aborted: false, levels: [], cwd: "/tmp", home: "/tmp", dialogs: [], statuses: {}, queue: { steering: [], followUp: [], classifying: [] }, view: { id: "a", path: [{ id: "a", name: "a", type: "agent" as const }], type: 'root' as const }, topics: [], life: { type: "ready" as const } };
  before.state(state);
  after.state({ ...state, name: "b", view: { id: "b", path: [{ id: "a", name: "a", type: "agent" as const }, { id: "b", name: "b", type: "agent" as const }], type: 'root' as const }, topics: [] });
  after.message(assistant("from b"), "end");
  const lines = request(before, "/events");
  const firstEpoch = record(lines[0]).epoch;
  lines.length = 0;
  after.show(before);
  const records = lines.map(record);
  assert.deepEqual(records.map(entry => entry.type), ["state", "reset"]);
  assert.notEqual(records[1].epoch, firstEpoch);
  assert.deepEqual(records[1].items.map((item: { kind: string }) => item.kind), ["assistant"]);
  assert.equal(records[0].view.id, "b");
  lines.length = 0;
  before.state({ ...state, name: "stale" });
  after.state({ ...state, name: "later" });
  assert.deepEqual(lines.map(record).map(entry => entry.name), ["later"]);
  before.close(); after.close();
});

test("a page that moved to another feed and then disconnects is held by neither feed", t => {
  const before = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000, metrics: true }), after = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000, metrics: true });
  const incoming = new IncomingMessage(new Socket());
  incoming.method = "GET";
  incoming.url = "/events";
  const response = new ServerResponse(incoming);
  response.write = () => true;
  response.end = () => response;
  assert.equal(before.handle(incoming, response), true);
  assert.equal(before.metrics?.subscribers, 1);
  after.show(before);
  assert.deepEqual([before.metrics?.subscribers, after.metrics?.subscribers], [0, 1]);
  response.emit("close");
  assert.deepEqual([before.metrics?.subscribers, after.metrics?.subscribers], [0, 0]);
  before.close(); after.close();
});

test("show keeps a named page's epoch and cursor: pending output reaches it first, and only the moved pages get a reset", t => {
  const before = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 }), after = transcript({ sessionEntryToContextMessages, branch: () => [], dir: directory(t), flushMs: 1000 });
  after.message(assistant("a"), "start");
  const moved = request(before, "/events");
  const named = request(after, "/events", { type: "named", id: "b" });
  const epoch = record(named[0]).epoch;
  after.message(assistant("ab"), "update");
  moved.length = 0; named.length = 0;
  after.show(before);
  const patches = named.map(record);
  assert.deepEqual(patches.map(entry => [entry.type, entry.blocks?.[0]?.suffix]), [["patch", "b"]]);
  const reset = moved.map(record).find(entry => entry.type === "reset");
  assert.equal(reset?.epoch, epoch);
  assert.ok(JSON.stringify(reset?.items).includes('"ab"'));
  before.close(); after.close();
});
