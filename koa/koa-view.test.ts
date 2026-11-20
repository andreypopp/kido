import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { test } from 'node:test';
import type { AgentSession, AgentSessionRuntime } from '@earendil-works/pi-coding-agent';
import { attachments } from './koa-attach.ts';
import { createView } from './koa-view.ts';

test('reply status strips Markdown but provider and compaction errors stay raw', t => {
  const dir = mkdtempSync('/tmp/koa-view-');
  const session: AgentSession = Object.assign(Object.create(null), { getSessionStats: () => ({ totalMessages: 1 }) });
  const runtime: AgentSessionRuntime = Object.assign(Object.create(null), { cwd: dir });
  const statuses: [string, string][] = [];
  const view = createView({
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
