import type { Block, PageRecord, State, WireAssistant, WireItem, WireJob } from '../../koa-records.ts';
import { next, type Scenarios } from '../scenario.ts';

const at = 1700000000000;
const state: State = { pathEditor: false, compaction: 'idle', view: { id: 's1', path: [{ id: 's1', name: 'ko', type: 'agent' }], type: 'root' }, threads: [], agents: [], bash: [], life: { type: 'ready' }, working: false, aborted: false, name: 'runsteps', levels: [], cwd: '/work', home: '/home', sessionId: 's1', statuses: {}, queue: { steering: [], followUp: [], classifying: [] }, dialogs: [] };
const job: WireJob = { id: 'build', name: 'build', service: false, log: '/tmp/build.log', command: 'make build', startedAt: at, place: { type: 'mac' } };
const tool = (id: string, done: boolean): Block => ({ type: 'tool', id, name: 'bash', args: { text: JSON.stringify({ command: id }), cut: 0 }, state: done ? { type: 'done', error: false, result: { text: 'ok', cut: 0, images: [] } } : { type: 'running' }, started: at, ...done ? { ended: at + 1000 } : {} });
const reply = (seq: number, blocks: Block[]): WireAssistant => ({ seq, revision: 0, at, final: false, kind: 'assistant', stop: '', error: '', blocks });
const report = (seq: number, text: string): WireItem => ({ seq, revision: 0, at, final: true, kind: 'agent', direction: 'in', from: { name: 'worker', session: 'worker-id' }, inbound: { form: 'report', relation: 'child' }, text: { text, cut: 0 } });
const item = (item: WireItem): PageRecord => ({ type: 'item', item });
const message: Block = { type: 'tool', id: 'message', name: 'message_agent', started: at, ended: at + 1000, args: { text: '{}', cut: 0 }, state: { type: 'done', error: false, result: { text: '', cut: 0, images: [] } }, agent: { direction: 'out', to: { name: 'worker', session: 'worker-id' }, text: { text: 'Check the **run** and return findings.', cut: 0 }, call: { tool: 'message', mode: 'message' }, outcome: { ok: true } } };
const blocks = [tool('first', false), tool('parallel', false), message];

export const scenarios: Scenarios = {
  testKoaWebviewRunStepsTransitions: () => ({
    open: [{ ...state, type: 'state' }, { type: 'reset', epoch: 'runsteps', more: false, items: [{ seq: 0, revision: 0, at, final: true, kind: 'user', text: 'Check the run transitions', images: [], attachments: [] }] }],
    steps: [
      next([{ ...state, type: 'state', working: true, since: at }]),
      next([item(reply(1, blocks)), item(report(2, '**Report**\n\n' + 'Foreground prose stays visible.\n\n'.repeat(30))), item({ seq: 3, revision: 0, at, final: true, kind: 'job', job, event: { type: 'stream', batch: { text: 'build output\n'.repeat(80), cut: 0 }, omitted: 2, cut: false } }), item({ seq: 4, revision: 0, at, final: true, kind: 'job', job, event: { type: 'ended', end: { type: 'exit', code: 0 }, tail: { text: 'PASS build', cut: 0 } } })]),
      next([item({ ...reply(1, [tool('first', true), tool('parallel', true), message]), revision: 1, final: true }), { ...state, type: 'state' }, item(report(5, 'Idle report joins the same run.'))]),
      next([item({ ...reply(6, [{ type: 'text', text: 'The first run is complete.' }]), final: true }), item(report(7, 'A new idle run after the text.'))]),
      next([{ ...state, type: 'state', working: true, since: at + 2000 }, item(reply(8, [tool('next', false)]))]),
      next([item({ ...reply(8, [tool('next', true)]), revision: 1, final: true }), item({ ...reply(9, [{ type: 'text', text: 'Text grows above a new bare row.' }]), final: true })]),
      next([item(reply(10, [tool('last', false)]))]),
      next([item({ ...reply(10, [tool('last', false)]), revision: 1, final: true, stop: 'aborted', ended: at + 3000 }), { ...state, type: 'state', aborted: true }]),
      next([
        item({ ...reply(11, [{ type: 'text', text: 'Check failed delivery names.' }]), final: true }),
        item({ ...reply(12, ['worker', 'ghost'].map((name): Block => ({ type: 'tool', id: name, name: 'message_agent', args: { text: '{}', cut: 0 }, state: { type: 'done', error: true, result: { text: 'Refused', cut: 0, images: [] } }, agent: { direction: 'out', to: { name }, text: { text: 'Refused', cut: 0 }, call: { tool: 'message', mode: 'message' }, outcome: { ok: false, failure: 'refused', message: 'Refused' } } }))), final: true }),
        { ...state, type: 'state', agents: [{ name: 'worker', target: { type: 'pane', pane: 'p-live' } }] },
      ]),
    ],
    files: {},
  }),
};
