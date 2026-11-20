import assert from 'node:assert/strict';
import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';
import { mkdtempSync } from 'node:fs';
import { test } from 'node:test';
import { sessionEntryToContextMessages, type AgentSession, type AgentSessionRuntime, type SessionEntry } from '@earendil-works/pi-coding-agent';
import { attachments } from './koa-attach.ts';
import { createView } from './koa-view.ts';

test('saved compaction adds one summary without resetting the live transcript', t => {
  const dir = mkdtempSync('/tmp/koa-view-');
  const entries: SessionEntry[] = [{ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: 'before', timestamp: 1 } }];
  const session: AgentSession = Object.assign(Object.create(null), {
    getSessionStats: () => ({ totalMessages: 1 }), sessionId: 'session',
    sessionManager: { getEntries: () => entries, getBranch: () => entries, getLeafId: () => entries.at(-1)?.id ?? null },
  });
  const runtime: AgentSessionRuntime = Object.assign(Object.create(null), { cwd: dir });
  const view = createView({ sessionEntryToContextMessages,
    kind: 'root', dir, metrics: false, attached: attachments(dir), name: 'test', cwd: dir, home: dir,
    agent: () => ({ session, runtime }), compose: () => { throw Error('a starting view does not publish'); },
    status() {}, title() {}, closed: () => false, cancelEditor() {}, shutdown() {}, agentsChanged() {},
  });
  t.after(() => view.close());
  view.rebuild();
  const req = new IncomingMessage(new Socket()); req.method = 'GET'; req.url = '/events';
  const res = new ServerResponse(req), records: { type: string; epoch?: string; items?: { seq: number; revision: number }[]; item?: { kind: string; seq: number; revision: number; at: number } }[] = [];
  res.write = chunk => { records.push(JSON.parse(String(chunk).slice(6))); return true; };
  assert.equal(view.feed.handle(req, res, { type: 'selected' }), true);
  const initial = records[0];
  view.hooks.onEvent({ type: 'compaction_start', reason: 'manual' });
  entries.push({ type: 'compaction', id: 'compact', parentId: 'user', timestamp: new Date(3).toISOString(), summary: 'saved', tokensBefore: 100, firstKeptEntryId: 'user' });
  view.hooks.onEvent({ type: 'compaction_end', reason: 'manual', result: { summary: 'saved', tokensBefore: 100, firstKeptEntryId: 'user' }, aborted: false, willRetry: false });
  assert.equal(records.filter(record => record.type === 'reset').length, 1);
  const updates = records.filter(record => record.type === 'item').map(record => record.item);
  assert.deepEqual(updates.map(item => item?.kind), ['command', 'summary']);
  assert.equal(updates[0]?.seq, updates[1]?.seq);
  assert.equal(updates[1]?.revision, (updates[0]?.revision ?? 0) + 1);
  assert.equal(updates[1]?.at, 3);
  assert.equal(records[0], initial);
  assert.ok(!updates.some(item => item?.seq === initial.items?.[0].seq));
  view.hooks.onEvent({ type: 'compaction_start', reason: 'manual' });
  view.state.bash.push({ id: 'bash', command: 'pwd', excludeFromContext: false, started: 4, phase: 'completed', ended: 5, result: { output: { text: dir, cut: 0 }, exit: 0, cancelled: false, truncated: false } });
  entries.push({ type: 'message', id: 'bash', parentId: 'compact', timestamp: new Date(5).toISOString(), message: { role: 'bashExecution', command: 'pwd', output: dir, exitCode: 0, cancelled: false, truncated: false, timestamp: 5 } });
  view.hooks.onEvent({ type: 'compaction_end', reason: 'manual', result: undefined, aborted: true, willRetry: false });
  assert.deepEqual(view.state.bash, []);
  assert.equal(records.filter(record => record.type === 'reset').length, 2);
});

test('reply status strips Markdown but provider and compaction errors stay raw', t => {
  const dir = mkdtempSync('/tmp/koa-view-');
  const session: AgentSession = Object.assign(Object.create(null), { getSessionStats: () => ({ totalMessages: 1 }) });
  const runtime: AgentSessionRuntime = Object.assign(Object.create(null), { cwd: dir });
  const statuses: [string, string][] = [];
  const view = createView({ sessionEntryToContextMessages,
    kind: 'root', dir, metrics: false, attached: attachments(dir), name: 'test', cwd: dir, home: dir,
    agent: () => ({ session, runtime }),
    compose: () => { throw Error('a starting view does not publish'); },
    status: (value, message) => { statuses.push([value, message]); },
    title() {}, closed: () => false, cancelEditor() {}, shutdown() {}, agentsChanged() {},
  });
  t.after(() => view.close());
  for (const [stopReason, errorMessage, expected] of [
    ['stop', undefined, ['done', 'Ready with code']],
    ['error', '\n **Provider** `failed`\nDetails', ['error', '**Provider** `failed`']],
  ] as const) {
    view.hooks.onEvent({ type: 'agent_start' });
    view.hooks.onEvent({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: '\n \n## **Ready** with `code`\nMore' }], stopReason, errorMessage, api: 'anthropic-messages', provider: 'test', model: 'test', timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } } });
    view.hooks.onEvent({ type: 'agent_settled', aborted: false });
    assert.deepEqual(statuses.at(-1), expected);
  }
  view.hooks.onEvent({ type: 'compaction_start', reason: 'manual' });
  view.finishCompaction({ type: 'failed', message: '**Compaction** `failed`\nDetails' });
  assert.deepEqual(statuses.at(-1), ['error', '**Compaction** `failed`']);
});
