import type { Block, WireItem } from '../../koa-records.ts';
import { parseThreadName } from '../../records.ts';
import { stateIdle } from '../scenario-parts.ts';
import { expect, same, type Scenarios } from '../scenario.ts';

export const scenarios: Scenarios = {
  testKoaWebviewRhythm: dir => {
    const one = parseThreadName('one'), two = parseThreadName('two');
    if (!one || !two) throw Error('Invalid rhythm threads');
    const base = { revision: 0, final: true, at: 1700000000000 };
    const text = (value: string): Block => ({ type: 'text', thread: one, text: value });
    const tool = (): Block => ({ type: 'tool', thread: one, id: 'tool', name: 'bash', args: { text: '{"command":"true"}', cut: 0 }, state: { type: 'done', error: false, result: { text: '', cut: 0, images: [] } } });
    const assistant = (seq: number, blocks: Block[]): WireItem => ({ ...base, seq, kind: 'assistant', blocks, stop: 'stop', error: '' });
    const items: WireItem[] = [
      assistant(0, [text('List before the run\n\n- Last point')]),
      { ...base, seq: 1, kind: 'agent', thread: one, from: { name: 'helper', session: 'helper' }, direction: 'in', inbound: { form: 'report', relation: 'child' }, text: { text: 'Finished the check', cut: 0 } },
      assistant(2, [tool()]),
      assistant(3, [text('Prose before a run')]),
      assistant(4, [tool()]),
      assistant(5, [{ type: 'text', thread: two, text: 'Hidden boundary' }]),
      assistant(6, [tool()]),
      { ...base, seq: 7, kind: 'user', thread: one, text: 'User after the run', images: [], attachments: [] },
      assistant(8, [text('First prose')]),
      assistant(9, [text('Second prose')]),
      assistant(10, [text('Inside the section'), tool(), text('After the section run')]),
      assistant(11, [text('Inside list\n\n- Last point'), tool(), text('After the list run')]),
      { ...base, seq: 12, kind: 'notice', customType: 'test', from: 'fixture', text: 'First notice' },
      { ...base, seq: 13, kind: 'notice', customType: 'test', from: 'fixture', text: 'Second notice' },
      assistant(14, [text('After notices')]),
    ];
    const state = { ...stateIdle(dir), threads: [{ name: one }, { name: two }] };
    return {
      open: [{ type: 'reset', epoch: 'rhythm', items, more: false }, state],
      steps: [expect({ on: { method: 'GET', path: '/items', body: value => same(value, { before: String(Number.MAX_SAFE_INTEGER), thread: one, sessionId: state.sessionId }) }, reply: { status: 200, json: { epoch: 'rhythm', more: false, items: items.filter(item => item.seq !== 5) } } })],
      files: {},
    };
  },
};
