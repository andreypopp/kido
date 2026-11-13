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
