import assert from 'node:assert/strict';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { test } from 'node:test';
import { createFakePi, koaExtension, makeFixture, startSession, entriesOf, get, createChannel, stubAgent, text, selfPane, agentPane, gatedCommand, pollUntil, customMessages, jobLog, logHas } from './koa-agent-fixture.ts';

test('root indexes markers once on the branch and supplies names only after compaction', async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx, { entries: [{ type: 'custom', customType: 'koa.thread', data: { name: 'copied', at: 1, owner: 'another-session' } }] });
    const reply = { role: 'assistant', content: [{ type: 'text', text: '[thread: copied]\nOld\n[thread: fresh]\nNew\n```\n[thread: fenced]\n```' }], timestamp: 123 };
    await s.emit('message_end', { message: reply }); await s.emit('message_end', { message: reply });
    s.entries.push(
      { type: 'message', id: 'copied', message: { role: 'user', content: '[thread: copied]\nOld', timestamp: 122 } },
      { type: 'message', id: 'fresh', message: { role: 'user', content: '[thread: fresh]\nNew', timestamp: 123 } },
    );
    assert.deepEqual(entriesOf(s, 'koa.thread').map(entry => entry.name), ['copied', 'fresh']);
    assert.equal(entriesOf(s, 'koa.thread')[1].at, 123);
    const guidelines: string[] = [], sections: Record<string, string> = {};
    const event = { systemPromptOptions: { promptGuidelines: guidelines, sections } };
    await s.emit('before_agent_start', event);
    assert.match(sections.threads, /^# Threads\n\nEvery reply in this session starts/);
    assert.ok(sections.threads.includes('the thread `general`'));
    assert.equal(guidelines.some(rule => rule.includes('[thread: name]')), false);
    assert.equal(s.messages.some(({ message }) => message.customType === 'koa.threads'), false);
    await s.emit('session_compact_failed', { aborted: true });
    assert.equal(s.messages.some(({ message }) => message.customType === 'koa.threads'), false);
    await s.emit('session_compact', {});
    const messages = s.messages.filter(({ message }) => message.customType === 'koa.threads');
    assert.equal(messages.length, 1); assert.match(messages[0].message.content, /copied.*fresh/s);
    assert.deepEqual(messages[0].opts, { triggerTurn: false });
    assert.equal(get(messages[0].message, 'display'), false);
    s.entries.splice(0);
    await s.emit('session_compact', {});
    assert.equal(s.messages.filter(({ message }) => message.customType === 'koa.threads').length, 1, 'empty branch sends no thread fixture');
    await s.emit('message_end', { message: reply });
    assert.deepEqual(entriesOf(s, 'koa.thread').map(entry => entry.name), ['copied', 'fresh']);
  } finally { await fx.restore(); }
});

test('child copied indexes stay inert and direct thread arguments are refused', async () => {
  const fx = makeFixture();
  try {
    const channel = createChannel(); Object.assign(channel.host.self, { parent: stubAgent({ id: 'parent', children: [] }) });
    const s = await startSession(fx, { channel, entries: [{ type: 'custom', customType: 'koa.thread', data: { name: 'copied', at: 1 } }] });
    for (const name of ['spawn_agent', 'async_bash']) assert.equal(get(s.tool(name), 'parameters', 'properties', 'thread'), undefined);
    const args = { thread: 'work', task: 'do it', name: 'worker', command: 'true' };
    assert.match(text(await s.tool('spawn_agent').execute('spawn', args)), /threads belong only to a root/);
    assert.match(text(await s.tool('async_bash').execute('job', args)), /threads belong only to a root/);
    const guidelines: string[] = [], sections: Record<string, string> = {};
    const event = { systemPromptOptions: { promptGuidelines: guidelines, sections } }; await s.emit('before_agent_start', event);
    assert.equal(sections.threads, undefined);
    assert.equal(event.systemPromptOptions.promptGuidelines.some(rule => rule.includes('[thread: name]')), false);
    await s.emit('message_end', { message: { role: 'assistant', content: [{ type: 'text', text: '[thread: new]\ntext' }], timestamp: 1 } });
    await s.emit('session_compact', {});
    assert.deepEqual(entriesOf(s, 'koa.thread').map(entry => entry.name), ['copied']);
    assert.equal(s.messages.some(({ message }) => message.customType === 'koa.threads'), false);
    await s.emit('agent_start');
    await s.emit('agent_end', { messages: [{ role: 'assistant', content: [{ type: 'text', text: 'Unmarked child reply' }], stopReason: 'stop' }] });
    await s.emit('agent_settled', {}, { isIdle: () => true });
    assert.equal(s.messages.some(({ message }) => message.customType === 'koa.thread-reminder'), false);
  } finally { await fx.restore(); }
});

test('root sends one hidden reminder only after an unmarked non-aborted reply settles', async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    const reply = (text: string, stopReason = 'stop') => ({ role: 'assistant', content: [{ type: 'text', text }], stopReason });
    const settle = async (messages: unknown[], aborted = false) => {
      await s.emit('agent_start'); await s.emit('agent_end', { messages });
      await s.emit('agent_settled', { aborted }, { isIdle: () => true });
    };
    const reminders = () => s.messages.filter(({ message }) => message.customType === 'koa.thread-reminder');
    await settle([reply('Before a tool'), reply('After a tool')]);
    assert.equal(reminders().length, 1);
    assert.deepEqual(reminders()[0], { message: { customType: 'koa.thread-reminder', content: 'Your last reply had no `[thread: name]` line. Start every reply with one.', display: false }, opts: { triggerTurn: false } });
    await s.emit('agent_settled', {}, { isIdle: () => true }); assert.equal(reminders().length, 1);
    await settle([reply('[thread: work]\nEarlier labelled part'), reply('Last part without another marker')]);
    await settle([reply('Aborted partial reply', 'aborted')]);
    await settle([reply('Cancelled reply')], true);
    await settle([{ role: 'assistant', content: [{ type: 'thinking', thinking: 'No public text' }], stopReason: 'stop' }]);
    await settle([]);
    assert.equal(reminders().length, 1);
    await settle([reply('```\n[thread: example]\n```')]);
    assert.equal(reminders().length, 2, 'a fenced example is not a marker');
  } finally { await fx.restore(); }
});

test('root spawn records its thread and resolves inbound reports in its namespace', async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const channel = createChannel(); const tasks: string[] = [];
    channel.host.spawn = async plan => stubAgent({ id: plan.id, name: plan.name, extension: { receive: async (message: { text: string }) => { tasks.push(message.text); } } });
    const s = await startSession(fx, { channel });
    await s.emit('message_end', { message: { role: 'assistant', content: [{ type: 'text', text: '[thread: first]\nStart' }], timestamp: 1 } });
    const result = await s.tool('spawn_agent').execute('spawn', { name: 'worker', task: 'do it', thread: 'work' });
    assert.equal(get(result.details, 'thread'), 'work');
    const child = entriesOf(s, 'koa.agent').find(entry => entry.name === 'worker'); assert.ok(child);
    assert.equal(child.thread, 'work'); assert.deepEqual(tasks, ['do it']);
    assert.deepEqual(entriesOf(s, 'koa.thread').map(entry => entry.name), ['first', 'work']);
    channel.host.extension?.receiveReport({ session: String(child.session), name: 'worker' }, 'done', false);
    assert.equal(get(s.messages.at(-1)?.message.details, 'thread'), 'work');
  } finally { await fx.restore(); }
});

test('peer discovery keeps the root relationship thread when facts change', async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { entries: [{ type: 'custom', customType: 'koa.agent', data: { owner: 'self-session', role: 'peer', name: 'old', session: '0123456789abcdef', cwd: '/old', thread: 'work' } }] });
    fx.setClientPanes([selfPane(), agentPane({ pane: 'pane_2', session: '0123456789abcdef', name: 'renamed', cwd: '/new' })]);
    await pollUntil(() => entriesOf(s, 'koa.agent').some(entry => entry.name === 'renamed'));
    assert.equal(entriesOf(s, 'koa.agent').at(-1)?.thread, 'work');
  } finally { await fx.restore(); }
});

test('root job results, streams and ending notices retain the assigned thread', async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]); const s = await startSession(fx);
    const gate = join(fx.dir, 'job-gate');
    const result = await s.tool('async_bash').execute('job', { name: 'build', command: gatedCommand(gate, 'output\n'), thread: 'work', stream: true });
    assert.equal(get(result.details, 'thread'), 'work');
    await pollUntil(() => logHas(jobLog(result), 'output\n'));
    writeFileSync(gate, '');
    await pollUntil(() => customMessages(s, 'ko-notice').length === 1);
    assert.equal(get(customMessages(s, 'ko-notice')[0].message.details, 'thread'), 'work');
    assert.equal(get(customMessages(s, 'ko-stream')[0].message.details, 'thread'), 'work');
    assert.deepEqual(entriesOf(s, 'koa.thread').map(entry => entry.name), ['work']);
  } finally { await fx.restore(); }
});

test('root tool schemas expose thread validation', () => {
  const s = createFakePi(); koaExtension(s.pi);
  for (const name of ['spawn_agent', 'async_bash']) {
    const pattern = new RegExp(String(get(s.tool(name), 'parameters', 'properties', 'thread', 'pattern')), 'u');
    assert.ok(pattern.test('Reload UI open items') && pattern.test('x'.repeat(200)));
    for (const bad of ['', 'a]b', 'a\nb', 'x'.repeat(201)]) assert.ok(!pattern.test(bad), bad);
  }
});
