import { parseTopicName, type TopicName } from '../../records.ts';
import type { Block, Topic, WireItem } from '../../koa-records.ts';
import { stateIdle } from '../scenario-parts.ts';
import { expect, next, same, sequence, type Scenario, type Scenarios } from '../scenario.ts';

function scene(dir: string, kind: 'two' | 'many' | 'marks' | 'marks-narrow' | 'filter', withoutTopic = false): Scenario {
  const names = ['sidebar', 'palette', 'remote-mtls-pairing-ios', 'release-0-32', 'koa-virtual-transcript', 'float-win', 'topics', 'docs-cleanup-after-the-sessions', 'ci-linux-flake'].map(value => {
    const name = parseTopicName(value);
    if (!name) throw Error('invalid fixture topic: ' + value);
    return name;
  });
  const [sidebar, palette, , , , , , , ci] = names;
  const now = new Date(2026, 10, 10, 14, 46, 12).getTime();
  const minutes = [2, 14, 20, 35, 60, 120, 180, 300, 1440];
  const summaries = ['Recording the right-side indicator snapshots; the unit reports in a minute.', 'Should the Theme mode keep the "This session only" row?', 'The iOS unit builds the Pair sheet; the scan well is a stand-in without a camera.', 'Waiting on CI for the rebase; nothing to do until it is green.', 'Find over the model lands the match in the mounted row; the WebKit check is pending.', 'Merged. The child windows pass the full visual stage.', 'Which capsule family for the widget: the view bar’s, or a new one?', 'Deferred until the sessions plan moves into docs/.', 'Reproduced once under --contend 4; the fix is in the sweep test’s wait.'];
  const topics: Topic[] = names.slice(0, kind === 'two' ? 2 : undefined).map((name, index) => ({ name, last: { summary: summaries[index], at: now - minutes[index] * 60000 } }));
  const items: WireItem[] = [];
  const at = (hour: number, minute: number) => new Date(2026, 10, 10, hour, minute).getTime();
  const user = (text: string, hour: number, minute: number) => { items.push({ kind: 'user', seq: items.length, revision: 1, final: true, text, images: [], attachments: [], at: at(hour, minute) }); return items.length - 1; };
  const reply = (blocks: Block[], hour: number, minute: number) => items.push({ kind: 'assistant', seq: items.length, revision: 1, final: true, blocks, at: at(hour, minute), stop: 'stop', error: '' });
  const text = (topic: TopicName, text: string): Block => ({ type: 'text', topic, text });
  const report = (topic: TopicName, name: string, body: string, hour: number, minute: number) => items.push({ kind: 'agent', seq: items.length, revision: 1, final: true, topic, from: { name, session: name }, direction: 'in', inbound: { form: name === 'sidebar-right' ? 'report' : 'message', relation: 'child' }, text: { text: body, cut: 0 }, at: at(hour, minute) });
  const run = (topic: TopicName, tools: string[], milliseconds: number, hour: number, minute: number) => reply(tools.map((name, index) => ({ type: 'tool', topic, id: 'call-' + items.length + '-' + index, name, args: { text: JSON.stringify(name === 'read' ? { path: 'app/App/SidebarRow.swift' } : { command: 'make lint' }), cut: 0 }, durationMs: milliseconds / tools.length, state: { type: 'done', error: false, result: { text: '', cut: 0, images: [] } } })), hour, minute);
  const label = (target: number, topics: TopicName[]) => items.push({ kind: 'topics', seq: items.length, revision: 1, final: true, target, topics, at: at(14, 41) });
  if (kind !== 'marks-narrow') {
    const first = user(kind === 'filter' ? 'Start the sidebar unit on the right-side indicators.' : 'Start the sidebar unit on the right-side indicators, and ask the palette unit about the Theme mode’s session row.', 13, 50);
    reply([text(sidebar, 'Spawned **@sidebar-right** with the indicator spec; it records the snapshots at the end.'), ...(kind === 'filter' ? [] : [text(palette, 'Asked **@palette** whether the Theme mode keeps the "This session only" row; its answer decides the save step.')])], 13, 51);
    label(first, kind === 'filter' ? [sidebar] : [sidebar, palette]);
    if (kind !== 'filter') {
      reply([{ type: 'tool', topic: palette, id: 'message-palette', name: 'message_agent', args: { text: '{}', cut: 0 }, state: { type: 'done', error: false, result: { text: '', cut: 0, images: [] } }, agent: { direction: 'out', to: { name: 'palette', session: 'palette' }, text: { text: 'Does the Theme mode keep the "This session only" row, or does the config file always change?', cut: 0 }, call: { tool: 'message', mode: 'message' }, outcome: { ok: true } } }], 13, 51);
      run(palette, ['read', 'read', 'bash'], 6000, 13, 51);
    }
    report(sidebar, 'sidebar-right', 'Built the right-side indicators; the snapshots are recorded and inspected.', 14, 31);
    reply([text(sidebar, 'The sidebar unit reports done; every stage passes. I start the reviewers now.')], 14, 31);
    if (kind !== 'filter') {
      report(palette, 'palette', 'It keeps the row; the config file changes only for Light, Dark and Both.', 14, 33);
      reply([text(palette, 'Then the save step stays as mocked: four rows, the session row last.')], 14, 33);
    }
  }
  if (kind === 'marks' || kind === 'marks-narrow') {
    const both = user('Check both: is the sidebar unit done, and what did the palette unit answer?', 14, 40);
    reply([text(sidebar, 'Done. The unit’s twelve snapshots changed as expected and the reviewers found nothing to apply.'), text(palette, 'It keeps the "This session only" row; the config file changes only for the other three choices.')], 14, 40);
    label(both, [sidebar, palette]);
    items.push({ kind: 'notify', seq: items.length, revision: 1, final: true, level: 'info', text: { text: 'session: Release · 14 messages', cut: 0 }, at: at(14, 41) });
  }
  if (kind === 'filter' || kind === 'marks' || kind === 'marks-narrow') {
    items.push({ kind: 'job', seq: items.length, revision: 1, final: true, topic: sidebar, at: at(14, 44), job: { id: 'verify-sidebar', name: 'verify-sidebar', service: false, command: 'make checks', log: '/tmp/verify-sidebar.log', place: { type: 'mac' }, startedAt: at(14, 40) }, event: { type: 'ended', end: { type: 'exit', code: 0 }, tail: { text: '', cut: 0 } } });
    run(sidebar, ['bash', 'bash'], 41000, 14, 44);
    reply([text(sidebar, 'Verification passed; I merge the unit next.')], 14, 44);
    const pending = user('Also look at the Linux flake in the sweep test when you have a minute.', 14, 46);
    if (kind !== 'filter') { reply([text(ci, 'I reproduced it once under contention; the test waits for the process, not for the row’s exit. A fix is in the test’s wait.')], 14, 46); label(pending, [ci]); }
  }
  if (withoutTopic) { user('Check one more detail.', 14, 46); reply([{ type: 'text', text: 'I will check it next.' }], 14, 46); }
  const state = { ...stateIdle(dir), name: 'ko', topics, working: kind === 'filter', agents: ['sidebar-right', 'palette'].map(name => ({ name, target: { type: 'view' as const, id: name } })) };
  const labels = new Map(items.flatMap(item => item.kind === 'topics' ? [[item.target, item.topics] as const] : []));
  const filtered = items.filter(item => item.kind === 'topics' ? item.topics.includes(sidebar) : labels.get(item.seq)?.includes(sidebar) || 'topic' in item && item.topic === sidebar || item.kind === 'assistant' && item.blocks.some(block => block.topic === sidebar));
  return {
    open: [state, { type: 'reset', epoch: 'topics', more: false, items }],
    steps: kind === 'filter' ? [expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), topic: sidebar, sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: 'topics', more: false, items: filtered } } })] : [],
    files: {},
  };
}

const phases = {
  testKoaWebviewTopicsModes: dir => {
    const result = scene(dir, 'filter'), initial = result.open.find(record => record.type === 'reset'), state = result.open.find(record => record.type === 'state');
    if (!initial || !state) throw Error('Missing topics fixture state');
    result.steps.push(expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: initial.epoch, more: false, items: initial.items } } }));
    return result;
  },
  testKoaWebviewTopicsTwo: dir => scene(dir, 'two'),
  testKoaWebviewTopicsMany: dir => scene(dir, 'many'),
  testKoaWebviewTopicsMarks: dir => scene(dir, 'marks'),
  testKoaWebviewTopicsMarksNarrow: dir => scene(dir, 'marks-narrow'),
  testKoaWebviewTopicsFilter: dir => scene(dir, 'filter'),
  testKoaWebviewTopicsFilterPanel: dir => scene(dir, 'filter'),
} satisfies Scenarios;

const paletteName = parseTopicName('palette');
if (!paletteName) throw Error('Invalid palette topic');
const order: (keyof typeof phases)[] = ['testKoaWebviewTopicsTwo', 'testKoaWebviewTopicsMany', 'testKoaWebviewTopicsMarks', 'testKoaWebviewTopicsMarksNarrow'];

export const scenarios: Scenarios = {
  TopicsUnread: dir => {
    const result = scene(dir, 'many'), state = result.open.find(record => record.type === 'state'), reset = result.open.find(record => record.type === 'reset');
    if (!state || !('topics' in state) || !reset) throw Error('Missing unread fixture state');
    state.topics[3].archived = true;
    result.steps.push(next(Array.from({ length: 100 }, (_, index) => ({ type: 'item' as const, item: { kind: 'assistant' as const, seq: reset.items.length + index, revision: 1, final: true, at: Date.parse('2026-11-10T22:46:12Z'), stop: 'stop' as const, error: '', blocks: state.topics.slice(0, 4).flatMap((topic, topicIndex) => index < [3, 12, 1, 100][topicIndex] ? [{ type: 'text' as const, topic: topic.name, text: 'Unread update ' + (index + 1) }] : []) } }))));
    return result;
  },
  TopicsFilterRestored: dir => scene(dir, 'filter'),
  TopicsGeometry: dir => sequence(['placement','hover','block','panel','capsule','drag'].map(phase => {
    const result = scene(dir, phase === 'placement' ? 'many' : phase === 'hover' || phase === 'drag' ? 'marks-narrow' : 'filter', phase === 'hover' || phase === 'drag');
    if (phase === 'drag') {
      const reset = result.open.find(record => record.type === 'reset'), state = result.open.find(record => record.type === 'state');
      if (!reset || !state) throw Error('Missing drag state');
      for (const mode of ['line','block']) for (const text of ['Check both:', 'Check one more detail.', 'Done. The unit’s twelve snapshots']) {
        const item = reset.items.find(item => item.kind === 'user' ? item.text.startsWith(text) : item.kind === 'assistant' && item.blocks.some(block => block.type === 'text' && block.text.startsWith(text)));
        if (!item) throw Error('Missing drag target in ' + mode);
        result.steps.push(expect({ on: { method: 'POST', path: '/messages/topic', body: value => same(value, { sessionId: state.sessionId, seq: item.seq, topic: 'remote-mtls-pairing-ios' }) }, reply: { status: 200, json: {} } }));
      }
    } else if (phase !== 'placement' && phase !== 'hover') {
      const state = result.open.find(record => record.type === 'state'), reset = result.open.find(record => record.type === 'reset');
      if (!state || !reset) throw Error('Missing geometry state');
      if (phase === 'block') result.steps.push(expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), topic: 'palette', sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: reset.epoch, more: false, items: [] } } }));
      result.steps.push(expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: reset.epoch, more: false, items: reset.items } } }));
    }
    return result;
  })),
  TopicsCreate: dir => sequence(Array.from({ length: 5 }, () => scene(dir, 'marks-narrow', true))),
  TopicsArchive: dir => sequence(Array.from({ length: 7 }, (_, index) => {
    const result = scene(dir, 'many'), state = result.open.find(record => record.type === 'state'), reset = result.open.find(record => record.type === 'reset');
    if (!state || !('topics' in state) || !reset) throw Error('Missing archive fixture state');
    state.topics = state.topics.map(topic => ({ ...topic, ...(index === 4 || topic.name === paletteName || topic.name === 'docs-cleanup-after-the-sessions' ? { archived: true as const } : {}) }));
    if (index >= 5) state.topics = state.topics.map((topic, i) => ({ ...topic, archived: i !== 0 ? true : undefined, last: { summary: 'Earlier discussion', at: Date.now() - (topic.name === paletteName ? 10 : i + 1) * 3600000 } }));
    if (index === 3 || index >= 5) {
      const labels = new Map(reset.items.flatMap(item => item.kind === 'topics' ? [[item.target, item.topics] as const] : []));
      const items = reset.items.filter(item => item.kind === 'topics' ? item.topics.includes(paletteName) : labels.get(item.seq)?.includes(paletteName) || 'topic' in item && item.topic === paletteName || item.kind === 'assistant' && item.blocks.some(block => block.topic === paletteName));
      result.steps.push(expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), topic: paletteName, sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: reset.epoch, more: false, items } } }), expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: reset.epoch, more: false, items: reset.items } } }));
    }
    return result;
  })),
  testKoaWebviewTopicsModes: phases.testKoaWebviewTopicsModes,
  Topics: dir => sequence(order.map(key => phases[key](dir))),
  TopicsEdit: dir => sequence(Array.from({ length: 4 }, (_, index) => {
    const result = scene(dir, 'marks');
    if (index === 3) {
      const state = result.open.find(record => record.type === 'state');
      if (!state) throw Error('Missing pending state');
      state.queue.classifying = [{ text: 'Check the Linux sweep test and keep the failure output.', attachments: [], mode: 'followUp' }];
    }
    return result;
  })),
  TopicsFilter: phases.testKoaWebviewTopicsFilter,
  TopicsFilterPanel: phases.testKoaWebviewTopicsFilterPanel,
};
