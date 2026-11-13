import type { Attachment, Block, PageRecord, State, WireItem } from '../../koa-records.ts';
import { expect, same, type Scenarios, type Scenario } from '../scenario.ts';

const state: State = { compaction: 'idle', agents: [], bash: [], working: false, aborted: false, name: 'pi', levels: ['off'], cwd: '/work', home: '/home', sessionId: 's1', sessionFile: '/work/s1.jsonl', queue: { steering: [], followUp: [] }, dialogs: [], statuses: {}, pi: { type: 'ready' } };
const user = (seq: number, text: string, attachments: Attachment[] = []): WireItem => ({ seq, revision: 0, at: 1, final: true, kind: 'user', text, images: [], attachments });
const open: PageRecord[] = [{ type: 'reset', epoch: 'e1', more: false, items: [user(0, 'hello')] }, { type: 'state', ...state }];
const queued = (attachments: Attachment[]): PageRecord => ({ type: 'state', ...state, working: true, queue: { steering: [{ text: 'later', attachments }], followUp: [] } });

const read = (path: string): Block => ({ type: 'tool', id: 't1', name: 'read', args: { text: JSON.stringify({ path }), cut: 0 }, state: { type: 'pending' } });
const reading = (dir: string): WireItem => ({ seq: 0, revision: 0, at: 1, final: false, kind: 'assistant', blocks: [read(`${dir}/a.txt`)], stop: '', error: '' });

export const scenarios: Scenarios = {
  file: (dir): Scenario => ({
    open: [{ type: 'reset', epoch: 'e1', more: false, items: [reading(dir)] }, { type: 'state', ...state }],
    steps: [{ on: 'next', records: [{ type: 'patch', seq: 0, baseRevision: 0, revision: 1, blocks: [{ index: 0, block: read(`${dir}/b.txt`) }], final: false, stop: '', error: '' }] }],
    files: {},
  }),
  order: (): Scenario => ({
    open,
    steps: [
      { on: 'next', records: [{ type: 'item', item: user(1, 'one') }] },
      expect({ on: { method: 'POST', path: '/prompt', body: value => same(value, { sessionId: 's1', text: 'two', mode: 'prompt', attachments: [] }) }, before: [{ type: 'item', item: user(2, 'two') }], reply: { status: 200, json: { disposition: 'started' } }, after: [{ type: 'item', item: user(3, 'three') }] }),
    ],
    files: {},
  }),
  wait: (): Scenario => ({
    open,
    steps: [
      expect({ on: { method: 'POST', path: '/abort' }, reply: { status: 200, json: {} } }),
      { on: 'next', records: [{ type: 'item', item: user(1, 'after') }] },
    ],
    files: {},
  }),
  sequence: (): Scenario => ({
    open,
    steps: [
      expect({ on: { method: 'POST', path: '/prompt' }, before: [{ type: 'item', item: user(10, 'before') }], reply: { status: 200, json: { disposition: 'started' } }, after: [{ type: 'item', item: user(11, 'after') }] }),
      { on: 'next', records: [{ type: 'item', item: user(12, 'next') }] },
    ],
    files: {},
  }),
  hold: (): Scenario => ({
    open,
    steps: [
      expect({ on: { method: 'POST', path: '/sessions/list' }, reply: { status: 200, json: { rows: [] }, hold: 'rows' }, after: [{ type: 'item', item: user(1, 'released') }] }),
      expect({ on: { method: 'POST', path: '/abort' }, reply: { status: 200, json: {} } }),
    ],
    files: {},
  }),
  queue: (): Scenario => ({
    open,
    steps: [
      expect({ on: { method: 'POST', path: '/prompt' }, before: ({ attachments }) => [queued(attachments)], reply: { status: 200, json: { disposition: 'queued' } } }),
      expect({ on: { method: 'POST', path: '/queue/remove' }, after: ({ attachments }) => [{ type: 'item', item: user(1, 'taken back', attachments) }], reply: { status: 200, json: {} } }),
      expect({ on: { method: 'POST', path: '/prompt' }, reply: { status: 200, json: { disposition: 'started' } } }),
    ],
    files: {},
  }),
};
