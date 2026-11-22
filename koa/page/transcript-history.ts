import type { PageRecord, Patch, WireItem } from '../koa-records.ts';
import type { TopicName } from '../records.ts';
import { scoped } from './http.ts';

type Snapshot = Extract<PageRecord, { type: 'reset' }>;
type Buffered = Patch | Extract<PageRecord, { type: 'item' }>;
type Request = { before: number; topic?: TopicName; patches: Buffered[]; done: Promise<void> };
export function createTranscriptHistory(deps: {
  epoch(): string; session(): string | undefined; view(): 'root' | 'job' | 'subagent'; filter(): TopicName | undefined; first(): number | undefined;
  viewport(): { scrollHeight: number; clientHeight: number; scrollTop: number };
  has(seq: number): boolean; accept(item: WireItem): void; apply(record: Buffered): void;
  history(): void; rendered(): Promise<void>; error(error: unknown): void;
}) {
  let before: number | undefined, more = false, request: Request | undefined;
  function cancel(mode: 'request' | 'scope') { request = undefined; if (mode === 'scope') before = undefined; }
  function reset(snapshot: Snapshot) {
    request = undefined; more = snapshot.more;
    before = snapshot.items.filter(item => !deps.filter() || item.kind !== 'annotations' && item.kind !== 'topics').reduce((lowest, item) => Math.min(lowest, item.seq), Infinity);
  }
  function fill() { const scroll = deps.viewport(); if (scroll.scrollHeight <= scroll.clientHeight || scroll.scrollTop < 80) void earlier(); }
  function earlier() {
    const first = deps.first();
    if (deps.view() === 'job' || !more || first === undefined) return;
    if (!request) { const mine = request = { before: before ?? first, ...(deps.filter() ? { topic: deps.filter() } : {}), patches: [], done: Promise.resolve() }; mine.done = load(mine); }
    return request.done;
  }
  async function reload() {
    const mine = request = { before: Number.MAX_SAFE_INTEGER, ...(deps.filter() ? { topic: deps.filter() } : {}), patches: [], done: Promise.resolve() };
    mine.done = load(mine); return mine.done;
  }
  async function load(mine: Request) {
    let applied = false;
    try {
      const response = await fetch(scoped('/items?before=' + mine.before + (mine.topic ? '&topic=' + encodeURIComponent(mine.topic) : ''), deps.session())); if (!response.ok) throw Error('Could not load earlier messages');
      const result: Snapshot = await response.json();
      if (request === mine && result.epoch === deps.epoch()) {
        deps.history(); more = result.more;
        before = result.items.filter(item => !mine.topic || item.kind !== 'annotations' && item.kind !== 'topics').reduce((lowest, item) => Math.min(lowest, item.seq), mine.before);
        for (const item of result.items) if (!deps.has(item.seq)) deps.accept(item);
        for (const patch of mine.patches) {
          if (patch.type === 'patch' || deps.has(patch.item.seq)) deps.apply(patch);
          if (request !== mine) return;
        }
        await deps.rendered(); applied = true;
      }
    } catch (error) { deps.error(error); } finally { if (request === mine) { request = undefined; if (applied && before !== mine.before) fill(); } }
  }
  return { get more() { return more; }, get pending() { return request !== undefined; }, cancel, reset, earlier, reload, fill,
    buffer(record: Buffered) { request?.patches.push(record); },
    outside(seq: number) { return before !== undefined && Number.isFinite(before) && seq < before; },
  };
}
