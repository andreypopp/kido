import type { Attachment, PageRecord, QueuedPrompt } from '../koa-records.ts';
import type { Routes } from '../page/http.ts';

type StepPath = Exclude<keyof Routes, `/attachments${string}`>;
export type Input = { body: unknown; attachments: Attachment[] };
export type Batch = PageRecord[] | ((input: Input) => PageRecord[]);
export type Expect<P extends StepPath = StepPath> = { method: 'GET' | 'POST'; path: P; body?: (value: unknown) => boolean };
type ErrorStatus = 400 | 403 | 404 | 409 | 413 | 500;
type Json<T> = T | ((input: Input) => T);
export type Reply<P extends StepPath = StepPath> = ({ status: 200; json: Json<Routes[P]['response']> } | { status: ErrorStatus; json: Json<{ error: string; unsent?: { steering: QueuedPrompt[]; followUp: QueuedPrompt[] } }> }) & { hold?: string };
type Expected<P extends StepPath> = { on: Expect<P>; before?: Batch; reply: Reply<P>; after?: Batch };
export type Step = { on: 'next'; records: PageRecord[] } | Expected<StepPath>;
export const next = (records: PageRecord[]): Step => ({ on: 'next', records });
export const expect = <P extends StepPath>(step: Expected<P>): Step => step;
export type Scenario = { open: PageRecord[]; steps: Step[]; files: Record<string, string> };
export type Scenarios = Record<string, (dir: string) => Scenario>;

export function sequence(phases: Scenario[]): Scenario {
  const files: Record<string, string> = {};
  const prepared = phases.map((phase, index) => {
    const records = (batch: PageRecord[]): PageRecord[] => batch.map(record => record.type === 'reset' || record.type === 'job-reset' ? { ...record, epoch: `${index}:${record.epoch}` } : record);
    const batch = (value: Batch): Batch => typeof value === 'function' ? input => records(value(input)) : records(value);
    for (const [name, contents] of Object.entries(phase.files)) {
      if (name in files && files[name] !== contents) throw new Error(`Conflicting scenario file: ${name}`);
      files[name] = contents;
    }
    return {
      open: records(phase.open),
      steps: phase.steps.map((step): Step => {
        if (step.on === 'next') return next(records(step.records));
        let reply = step.reply;
        if (step.on.path === '/items' && reply.status === 200) {
          const history = (value: Routes[StepPath]['response']): Routes['/items']['response'] => {
            if (!('epoch' in value) || typeof value.epoch !== 'string' || !('items' in value) || !Array.isArray(value.items) || !('more' in value) || typeof value.more !== 'boolean') throw new Error('Invalid history scenario response');
            return { epoch: `${index}:${value.epoch}`, items: value.items, more: value.more };
          };
          const original = reply.json;
          reply = { ...reply, json: typeof original === 'function' ? input => history(original(input)) : history(original) };
        }
        return { ...step, reply, ...(step.before ? { before: batch(step.before) } : {}), ...(step.after ? { after: batch(step.after) } : {}) };
      }),
    };
  });
  if (!prepared.length) throw new Error('A scenario sequence needs a phase');
  return { open: prepared[0].open, steps: prepared.flatMap((phase, index) => index ? [next(phase.open), ...phase.steps] : phase.steps), files };
}

export const anything = Symbol('anything');

export function same(value: unknown, expected: unknown): boolean {
  if (expected === anything) return true;
  if (Array.isArray(expected)) return Array.isArray(value) && value.length === expected.length && expected.every((item, index) => same(value[index], item));
  if (expected && typeof expected === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    const keys = Object.keys(expected);
    return keys.length === Object.keys(value).length && keys.every(key => key in value && same(Reflect.get(value, key), Reflect.get(expected, key)));
  }
  return value === expected;
}
