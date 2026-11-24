import type { PageRecord, Patch, WireItem } from '../koa-records.ts';
import type { TopicName } from '../records.ts';
import { scoped } from './http.ts';

type Snapshot = Extract<PageRecord, { type: 'reset' }>;
type Buffered = Patch | Extract<PageRecord, { type: 'item' }>;
type Request = { before: number; topic?: TopicName; patches: Buffered[]; done: Promise<void>; transition: 'history' | 'filter'; anchor?: { seq: number; generation: number } };
export function createTranscriptHistory(deps: {
  epoch(): string; session(): string | undefined; view(): 'root' | 'job' | 'subagent'; filter(): TopicName | undefined; first(): number | undefined;
  viewport(): { scrollHeight: number; clientHeight: number; scrollTop: number };
  has(seq: number): boolean; accept(items: readonly WireItem[]): void; apply(record: Buffered): void;
  history(): void; filtered(): void; rendered(): Promise<void>; error(error: unknown): void; changed(): void; failed(generation: number): void;
}) {
  let before: number | undefined, filled: number | undefined, more = false, request: Request | undefined;
  let boundary = Infinity, catchup: { patches: Buffered[] } | undefined, caught: number | undefined;
  function cancel(mode: 'request' | 'scope') { request = undefined; catchup = undefined; caught = undefined; deps.changed(); if (mode === 'scope') { before = undefined; filled = undefined; } }
  function reset(snapshot: Snapshot) {
    request = undefined; catchup = undefined; caught = undefined; filled = undefined; more = snapshot.more;
    boundary = snapshot.more ? snapshot.items.reduce((lowest, item) => Math.min(lowest, item.seq), Infinity) : -Infinity;
    before = snapshot.items.filter(item => !deps.filter() || item.kind !== 'annotations' && item.kind !== 'topics').reduce((lowest, item) => Math.min(lowest, item.seq), Infinity);
  }
  function fill() {
    if (deps.view() === 'job' || !more || request || catchup || deps.first() === filled) return;
    const scroll = deps.viewport(); if (scroll.scrollHeight <= scroll.clientHeight || scroll.scrollTop < 80) void earlier();
  }
  function earlier() {
    const first = deps.first();
    if (deps.view() === 'job' || !more || first === undefined) return;
    if (!request) { filled = first; const mine = request = { before: before ?? first, ...(deps.filter() ? { topic: deps.filter() } : {}), patches: [], done: Promise.resolve(), transition: 'history' }; mine.done = load(mine); }
    return request.done;
  }
  async function reload(transition: Request['transition'] = 'history') {
    const mine = request = { before: Number.MAX_SAFE_INTEGER, ...(deps.filter() ? { topic: deps.filter() } : {}), patches: [], done: Promise.resolve(), transition };
    mine.done = load(mine); return mine.done;
  }
  async function catchUp(last: number): Promise<void> {
    if (catchup || caught !== undefined && caught <= last || !Number.isFinite(boundary) || boundary <= last) return;
    caught = last;
    const mine: { patches: Buffered[] } = { patches: [] };
    catchup = mine;
    const epoch = deps.epoch(), session = deps.session();
    let cursor = boundary;
    try {
      while (cursor > last && Number.isFinite(cursor) && catchup === mine) {
        const response = await fetch(scoped('/items?before=' + cursor, session));
        if (!response.ok) throw Error('Could not load unread messages');
        const result: Snapshot = await response.json();
        if (catchup !== mine || result.epoch !== epoch || deps.epoch() !== epoch || deps.session() !== session) return;
        deps.history();
        deps.accept(result.items.filter(item => !deps.has(item.seq)));
        for (const patch of mine.patches.splice(0)) {
          if (patch.type === 'patch' || deps.has(patch.item.seq)) deps.apply(patch);
          if (catchup !== mine) return;
        }
        const next = result.items.reduce((lowest, item) => Math.min(lowest, item.seq), cursor);
        if (!result.more) { cursor = -Infinity; break; }
        if (next >= cursor) break;
        cursor = next;
      }
      if (catchup !== mine) return;
      boundary = cursor;
      return;
    } catch (error) {
      if (catchup !== mine) return;
      deps.error(error);
      return;
    }
    finally { if (catchup === mine) { catchup = undefined; deps.changed(); } }
  }
  async function load(mine: Request) {
    try {
      const response = await fetch(scoped('/items?before=' + mine.before + (mine.topic ? '&topic=' + encodeURIComponent(mine.topic) : ''), deps.session())); if (!response.ok) throw Error('Could not load earlier messages');
      const result: Snapshot = await response.json();
      if (request === mine && result.epoch === deps.epoch()) {
        deps.history(); more = result.more;
        before = result.items.filter(item => !mine.topic || item.kind !== 'annotations' && item.kind !== 'topics').reduce((lowest, item) => Math.min(lowest, item.seq), mine.before);
        deps.accept(result.items.filter(item => !deps.has(item.seq)));
        for (const patch of mine.patches) {
          if (patch.type === 'patch' || deps.has(patch.item.seq)) deps.apply(patch);
          if (request !== mine) return;
        }
        if (mine.transition === 'filter') { mine.transition = 'history'; deps.filtered(); }
        if (mine.anchor && before >= mine.before && !deps.has(mine.anchor.seq)) deps.failed(mine.anchor.generation);
        await deps.rendered();
      }
    } catch (error) { if (request === mine) { if (mine.anchor) deps.failed(mine.anchor.generation); deps.error(error); } } finally { if (request === mine) { if (mine.transition === 'filter') deps.filtered(); request = undefined; deps.history(); deps.changed(); } }
  }
  return { get more() { return more; }, get pending() { return request !== undefined || catchup !== undefined; }, cancel, reset, earlier, reload, fill, catchUp,
    anchor(seq: number, generation: number) {
      void earlier();
      if (request) request.anchor = { seq, generation };
      else deps.failed(generation);
    },
    buffer(record: Buffered) { request?.patches.push(record); catchup?.patches.push(record); },
    outside(seq: number) { return before !== undefined && Number.isFinite(before) && seq < before; },
  };
}
