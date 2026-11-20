import { expect, type Scenarios } from '../scenario.ts';
import { stateIdle } from '../scenario-parts.ts';

export const scenarios: Scenarios = {
  Paths: dir => ({
    open: [
      { type: 'reset', epoch: 'paths', more: false, items: [{ seq: 0, revision: 0, at: 1794148320000, final: true, kind: 'assistant', blocks: [{ type: 'text', text: 'Review `koa/koa.ts:120`, then `koa.ts`. The command is `git add koa.ts`.' }], stop: 'stop', error: '' }] },
      stateIdle(dir),
    ],
    steps: [expect({ on: { method: 'POST', path: '/editor/path', body: value => typeof value === 'object' && value !== null && 'text' in value && value.text === 'koa/koa.ts:120' }, reply: { status: 200, json: { type: 'warning', text: 'koa/koa.ts:120: no such file' } } })],
    files: {},
  }),
};
