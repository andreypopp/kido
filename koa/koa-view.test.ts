import assert from 'node:assert/strict';
import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';
import { mkdtempSync } from 'node:fs';
import { test } from 'node:test';
import { sessionEntryToContextMessages, type AgentSession, type AgentSessionRuntime, type SessionEntry } from '@earendil-works/pi-coding-agent';
import { attachments } from './koa-attach.ts';
import { createView } from './koa-view.ts';

test('topic anchors wait for post-callback persistence and cancel with their session', async t => {
  const dir = mkdtempSync('/tmp/koa-view-'), entries: SessionEntry[] = [];
  const session: AgentSession = Object.assign(Object.create(null), { sessionId: 'session', sessionManager: { getBranch: () => entries } });
  const runtime: AgentSessionRuntime = Object.assign(Object.create(null), { cwd: dir });
  const view = createView({ sessionEntryToContextMessages, branch: () => entries, kind: 'root', dir, metrics: false, attached: attachments(dir), name: 'test', cwd: dir, home: dir, agent: () => ({ session, runtime }), compose: () => { throw Error('a starting view does not publish'); }, status() {}, title() {}, closed: () => false, cancelEditor() {}, shutdown() {}, agentsChanged() {}, changed() {} });
  t.after(() => view.close());
  const message = { role: 'user' as const, content: 'Work', timestamp: 1 };
  view.hooks.onEvent({ type: 'message_end', message });
  const waiting = view.waitTopicAnchor(0);
  let serialFree = false; await view.serial(async () => { serialFree = true; }); assert.equal(serialFree, true);
  entries.push({ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message });
  assert.deepEqual(await waiting, { type: 'ready', anchor: 'user' });
  const next = { ...message, content: 'Next', timestamp: 2 }; view.hooks.onEvent({ type: 'message_end', message: next });
  assert.deepEqual(await view.waitTopicAnchor(1, 1), { type: 'timeout' });
  const cancelled = view.waitTopicAnchor(1); view.newSessionScope();
  assert.deepEqual(await cancelled, { type: 'changed' });
  const disconnected = view.waitTopicAnchor(1); view.close();
  assert.deepEqual(await disconnected, { type: 'changed' });
});

test('saved compaction adds one summary without resetting the live transcript', t => {
  const dir = mkdtempSync('/tmp/koa-view-');
  const entries: SessionEntry[] = [{ type: 'message', id: 'user', parentId: null, timestamp: new Date(1).toISOString(), message: { role: 'user', content: 'before', timestamp: 1 } }];
  const session: AgentSession = Object.assign(Object.create(null), {
    getSessionStats: () => ({ totalMessages: 1 }), sessionId: 'session',
    sessionManager: { getEntries: () => entries, getBranch: () => entries, getLeafId: () => entries.at(-1)?.id ?? null },
  });
  const runtime: AgentSessionRuntime = Object.assign(Object.create(null), { cwd: dir });
  const view = createView({ sessionEntryToContextMessages, branch: () => [],
    kind: 'root', dir, metrics: false, attached: attachments(dir), name: 'test', cwd: dir, home: dir,
    agent: () => ({ session, runtime }), compose: () => { throw Error('a starting view does not publish'); },
    status() {}, title() {}, closed: () => false, cancelEditor() {}, shutdown() {}, agentsChanged() {}, changed() {},
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

test('a completed command reset arrives before the state that removes its live card', t => {
  const dir=mkdtempSync('/tmp/koa-view-'), entries: SessionEntry[]=[];
  const session: AgentSession=Object.assign(Object.create(null),{sessionId:'session',sessionName:'test',getSessionStats:()=>({totalMessages:entries.length}),getAvailableThinkingLevels:()=>[],sessionManager:{getEntries:()=>entries,getBranch:()=>entries,getLeafId:()=>entries.at(-1)?.id??null}});
  const runtime: AgentSessionRuntime=Object.assign(Object.create(null),{cwd:dir});
  const view=createView({sessionEntryToContextMessages,branch:()=>[],kind:'root',dir,metrics:false,attached:attachments(dir),name:'test',cwd:dir,home:dir,agent:()=>({session,runtime}),compose:own=>({...own,agents:[],pathEditor:false,view:{id:'root',path:[],type:'root'},topics:[]}),status(){},title(){},closed:()=>false,cancelEditor(){},shutdown(){},agentsChanged(){},changed(){}});
  t.after(()=>view.close());view.refresh();
  const req=new IncomingMessage(new Socket());req.method='GET';req.url='/events';
  const res=new ServerResponse(req),records:{type:string;items?:{kind:string}[];bash?:unknown[]}[]=[];
  res.write=chunk=>{records.push(JSON.parse(String(chunk).slice(6)));return true};
  view.feed.handle(req,res,{type:'selected'});records.length=0;
  view.state.bash.push({id:'command',command:'pwd',excludeFromContext:false,started:4,phase:'completed',ended:5,result:{output:{text:dir,cut:0},exit:0,cancelled:false,truncated:false}});
  entries.push({type:'message',id:'command',parentId:null,timestamp:new Date(5).toISOString(),message:{role:'bashExecution',command:'pwd',output:dir,exitCode:0,cancelled:false,truncated:false,timestamp:5}});
  view.rebuild();
  assert.deepEqual(records.map(record=>record.type),['reset','state']);
  assert.equal(records[0].items?.some(item=>item.kind==='bash'),true);
  assert.deepEqual(records[1].bash,[]);
  view.hooks.onEvent({type:'agent_start'});
  view.state.bash.push({id:'A',command:'pwd',excludeFromContext:false,started:6,phase:'completed',ended:7,result:{output:{text:dir,cut:0},exit:0,cancelled:false,truncated:false}},{id:'B',command:'make',excludeFromContext:false,started:8,phase:'running',output:{text:'running',cut:0}});
  entries.push({type:'message',id:'A',parentId:'command',timestamp:new Date(7).toISOString(),message:{role:'bashExecution',command:'pwd',output:dir,exitCode:0,cancelled:false,truncated:false,timestamp:7}});
  records.length=0;view.hooks.onEvent({type:'agent_settled',aborted:false});
  const reset=records.findIndex(record=>record.type==='reset');
  assert.ok(reset>=0,'settling publishes a completed execution while another command runs');
  assert.equal(records[reset].items?.filter(item=>item.kind==='bash').length,2);
  assert.deepEqual(view.state.bash.map(card=>card.id),['B']);
  assert.deepEqual(records.slice(reset).map(record=>record.type),['reset','state']);
});

test('root status keeps the latest visible message through work, errors and resume', t => {
  const dir = mkdtempSync('/tmp/koa-view-');
  const entries: SessionEntry[] = [];
  const session: AgentSession = Object.assign(Object.create(null), {
    getSessionStats: () => ({ totalMessages: entries.length }), getAvailableThinkingLevels: () => [],
    sessionManager: { getEntries: () => entries, getBranch: () => entries, getLeafId: () => entries.at(-1)?.id ?? null },
  });
  const runtime: AgentSessionRuntime = Object.assign(Object.create(null), { cwd: dir });
  const statuses: [string, string][] = [];
  const view = createView({ sessionEntryToContextMessages, branch: () => [],
    kind: 'root', dir, metrics: false, attached: attachments(dir), name: 'test', cwd: dir, home: dir,
    agent: () => ({ session, runtime }),
    compose: own => ({ ...own, agents: [], pathEditor: false, view: { id: 'root', path: [], type: 'root' }, topics: [] }),
    status: (value, message) => { statuses.push([value, message]); },
    title() {}, closed: () => false, cancelEditor() {}, shutdown() {}, agentsChanged() {}, changed() {},
  });
  t.after(() => view.close());
  const user = (content: string) => {
    const message = { role: 'user' as const, content, timestamp: entries.length };
    entries.push({ type: 'message', id: String(entries.length), parentId: entries.at(-1)?.id ?? null, timestamp: new Date().toISOString(), message });
    view.hooks.onEvent({ type: 'message_end', message });
  };
  user('\n## **User** request\nDetails');
  view.hooks.onEvent({ type: 'agent_start' });
  assert.deepEqual(statuses.at(-1), ['working', 'User request']);
  view.hooks.onEvent({ type: 'compaction_start', reason: 'manual' });
  assert.deepEqual(statuses.at(-1), ['working', 'User request']);
  view.finishCompaction({ type: 'done' });
  for (const [stopReason, errorMessage, expected] of [
    ['toolUse', undefined, ['done', 'User request']],
    ['stop', undefined, ['done', 'Ready with code']],
    ['error', '\n **Provider** `failed`\nDetails', ['error', 'Ready with code']],
  ] as const) {
    view.hooks.onEvent({ type: 'agent_start' });
    view.hooks.onEvent({ type: 'message_end', message: { role: 'assistant', content: stopReason === 'stop' ? [{ type: 'text', text: '\n \n## **Ready** with `code`\nMore' }] : [{ type: 'toolCall', id: 'call', name: 'read', arguments: {} }], stopReason, errorMessage, api: 'anthropic-messages', provider: 'test', model: 'test', timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } } });
    view.hooks.onEvent({ type: 'agent_settled', aborted: false });
    assert.deepEqual(statuses.at(-1), expected);
  }
  view.hooks.onEvent({ type: 'agent_start' });
  assert.deepEqual(statuses.at(-1), ['working', 'Ready with code']);
  view.hooks.onEvent({ type: 'compaction_start', reason: 'manual' });
  view.finishCompaction({ type: 'failed', message: '**Compaction** `failed`\nDetails' });
  assert.deepEqual(statuses.at(-1), ['error', 'Ready with code']);
  user('Next **request**\nMore');
  assert.deepEqual(statuses.at(-1), ['error', 'Next request']);
  user('/command arguments');
  assert.deepEqual(statuses.at(-1), ['error', 'Next request']);
  for (const text of ['[topic: files]\n/tmp/report.txt', '[topic: files]\n \n/tmp/report.txt']) {
    const message = { role: 'user' as const, content: text, timestamp: 0 };
    view.prompts.add(text, 'prompt', [{ id: 'file', name: 'report.txt', size: 1, path: '/tmp/report.txt', kind: 'file' }]);
    view.hooks.onEvent({ type: 'message_start', message });
    view.hooks.onEvent({ type: 'message_end', message });
    assert.deepEqual(statuses.at(-1), ['error', 'Next request']);
  }
  view.resetSession();
  view.refresh();
  assert.deepEqual(statuses.at(-1), ['idle', 'Next request']);
  entries.splice(0, entries.length, { type: 'message', id: 'other', parentId: null, timestamp: new Date().toISOString(), message: { role: 'user', content: '[topic: other]\nOther **branch**\nDetails', timestamp: 0 } });
  view.hooks.treeNavigated(undefined);
  assert.deepEqual(statuses.at(-1), ['idle', 'Other branch']);
});
