import { rowKey, type RowId } from './extent.ts';
import type { PromptResult } from '../koa-records.ts';

export type ItemId = { kind: 'message'; seq: number; row?: RowId } | { kind: 'job'; byte: number };
export type Anchor = { item: ItemId; offset: number; edge: 'row' | 'divider' };
type Scope = { view: string; sessionId: string | undefined; topic?: string };
const scopeKey = (scope: Scope): string => JSON.stringify([scope.view, scope.topic ?? null]);
export type Saved = { scope: Scope; anchor: Anchor; last: number } | { scope: Scope; last: number };
type Geometry = { top: number; max: number; viewport: number; width: number; origin: number };
type Candidate = { row?: RowId; index: number; visible: boolean; status: 'read' | 'unread' | 'own' };
type Mode =
  | { kind: 'following' }
  | { kind: 'reader'; anchor?: Anchor }
  | { kind: 'travel'; anchor?: Anchor; from: number; start: number }
  | { kind: 'landing'; target: { at: 'end' } | { at: 'unread' } | { at: 'reader'; anchor: Anchor } | { at: 'anchor'; saved: Saved & { anchor: Anchor } } };
export type State = {
  mode: Mode;
  seen?: { top: number; max: number };
  latestShown: boolean;
  scope: Scope;
  saved: Map<string, Saved>;
  generation: number;
  transcript?: string;
  unread: { candidates: Map<number, Map<string, Candidate>>; lastSeq: number; filtered: boolean; pendingSend?: true };
};
export type Observation = { top: number; max: number; anchor?: Anchor; now: number; focused: boolean; visible: boolean; reducedMotion: boolean };
export type ScrollEvent =
  | ({ type: 'input'; direction: 'up' | 'down' } & Observation)
  | ({ type: 'scroll'; layout: boolean } & Observation)
  | { type: 'layout'; cause: 'layout' }
  | { type: 'layout'; cause: 'toggle'; anchor: Anchor }
  | { type: 'submit' }
  | { type: 'send-result'; result: PromptResult['disposition'] | 'failed' }
  | { type: 'item'; seq: number; kind: 'user' | 'assistant' | 'other'; visible: boolean; appended: boolean; focused: boolean; rows?: { row?: RowId; visible: boolean }[] }
  | ({ type: 'focus' | 'visibility' | 'latest' } & Observation)
  | ({ type: 'resize' } & Observation)
  | { type: 'history' }
  | { type: 'reset'; epoch: string }
  | { type: 'scope'; scope: Scope; filtered: boolean; anchor?: Anchor }
  | { type: 'load-failed'; generation: number }
  | { type: 'navigate'; anchor: Anchor };
export type Row = { item: ItemId; top: number; bottom: number; windowTop?: number; leading?: number };
export type Lookup = { kind: 'mounted'; row: Row } | { kind: 'unmounted'; row: Row } | { kind: 'unloaded' } | { kind: 'removed'; next?: Row };
export type Measure = Geometry & Observation & {
  dock: number;
  lookup: (item: ItemId) => Lookup;
  windowMax?: number;
  settled: boolean;
  layout: 'none' | 'layout' | 'toggle';
  scrolled: boolean;
};
export type Decision = {
  scrollTop?: number;
  latest: { show: boolean; count: number };
  divider?: { seq: number; row?: RowId };
  windowTop: number;
  request?: { type: 'mount'; item: ItemId } | { type: 'load'; item: ItemId; generation: number };
  frame: boolean;
};
export function scrollMemory(state: State): Saved[] {
  const saved = new Map(state.saved), mode = state.mode;
  if (mode.kind === 'reader' && mode.anchor) saved.set(scopeKey(state.scope), { scope: state.scope, anchor: mode.anchor, last: state.unread.lastSeq });
  else if (mode.kind === 'landing' && mode.target.at === 'anchor') saved.set(scopeKey(state.scope), mode.target.saved);
  else if (mode.kind === 'landing' && mode.target.at === 'reader') saved.set(scopeKey(state.scope), { scope: state.scope, anchor: mode.target.anchor, last: state.unread.lastSeq });
  else saved.set(scopeKey(state.scope), { scope: state.scope, last: state.unread.lastSeq });
  return [...saved.values()];
}
export function scrollInitial(scope: Scope, memory: Saved[] = []): State {
  return { mode: { kind: 'landing', target: { at: 'end' } }, scope, saved: new Map(memory.map(saved => [scopeKey(saved.scope), saved])), latestShown: false, generation: 0, unread: { candidates: new Map(), lastSeq: -1, filtered: false } };
}
export function scrollWindow(state: State, position: (item: ItemId, edge: 'row' | 'divider') => number | undefined, top: number, bottom: number): number {
  const mode = state.mode;
  if (mode.kind === 'following') return bottom;
  if (mode.kind === 'travel') return top;
  const anchor = mode.kind === 'reader' ? mode.anchor : mode.target.at === 'anchor' ? mode.target.saved.anchor : mode.target.at === 'reader' ? mode.target.anchor : undefined;
  const y = anchor && position(anchor.item, anchor.edge);
  return y !== undefined && anchor ? y - anchor.offset : mode.kind === 'landing' ? bottom : top;
}
export function scrollStored(state: State, top: number): State {
  return { ...state, seen: state.seen && { ...state.seen, top } };
}
function unread(state: State, event: ScrollEvent | { type: 'clear' }, filtering = false, original = state.unread.candidates): State['unread'] {
  const before = state.unread;
  let result = before;
  const changed = new Set<number>();
  const candidates = (seq: number) => {
    if (result.candidates === original) result = { ...result, candidates: new Map(original) };
    let rows = result.candidates.get(seq);
    if (!rows || !changed.has(seq)) { rows = new Map(rows); result.candidates.set(seq, rows); changed.add(seq); }
    return rows;
  };
  if (event.type === 'clear') {
    for (const [seq, rows] of before.candidates) if (Array.from(rows.values()).some(candidate => candidate.status === 'unread' && candidate.visible)) {
      for (const [key, candidate] of rows) if (candidate.status === 'unread') candidates(seq).set(key, { ...candidate, status: 'read' });
    }
  } else if (event.type === 'submit') result = { ...before, pendingSend: true };
  else if (event.type === 'send-result') {
    if (event.result === 'handled' || event.result === 'failed') result = { ...before, pendingSend: undefined };
  } else if (event.type === 'reset') {
    if (state.transcript !== undefined && state.transcript !== event.epoch) result = { ...before, candidates: new Map(), lastSeq: -1, pendingSend: undefined };
    else {
      for (const [seq, rows] of before.candidates) for (const [key, candidate] of rows) if (candidate.visible) candidates(seq).set(key, { ...candidate, visible: false });
      result = { ...result, pendingSend: undefined };
    }
  } else if (event.type === 'scope') {
    if (state.scope.view === event.scope.view && state.scope.sessionId === event.scope.sessionId && state.scope.topic === event.scope.topic) return before;
    if (state.scope.view !== event.scope.view || state.scope.sessionId !== event.scope.sessionId) result = { candidates: new Map(), lastSeq: -1, filtered: event.filtered };
    else {
      for (const [seq, rows] of before.candidates) for (const [key, candidate] of rows) if (candidate.visible) candidates(seq).set(key, { ...candidate, visible: false });
      result = { ...result, filtered: event.filtered, pendingSend: undefined };
    }
  } else if (event.type === 'item') {
    const own = event.appended && event.kind === 'user' && before.pendingSend;
    if (event.kind !== 'other') {
      const rows = event.rows?.length ? event.rows : [{ row: undefined, visible: event.visible }];
      const known = before.candidates.get(event.seq);
      const restoring = state.mode.kind === 'landing' && state.mode.target.at === 'anchor' ? state.mode.target.saved : undefined;
      const baseline = !event.appended && !known && !restoring;
      const keys = new Set(rows.map(({ row }) => row ? rowKey(row) : ''));
      for (const [key, candidate] of known ?? []) if (!keys.has(key) && (candidate.visible || candidate.status === 'unread')) candidates(event.seq).set(key, { ...candidate, visible: false, status: !before.filtered && candidate.status === 'unread' ? 'read' : candidate.status });
      rows.forEach(({ row, visible }, index) => {
        const key = row ? rowKey(row) : '', prior = known?.get(key);
        const arrived = event.rows?.length ? event.kind === 'user' ? !known?.size : !Array.from(known?.values() ?? []).some(candidate => candidate.row) : !prior?.visible;
        const isUnread = (prior ? prior.status === 'unread' : Array.from(known?.values() ?? []).some(candidate => candidate.status === 'unread')) && (before.filtered || visible) || (!!event.rows?.length || event.visible) && arrived && !baseline && !filtering && !(state.mode.kind === 'following' && event.focused && visible) && (!restoring || event.seq > restoring.last);
        const status = own || prior?.status === 'own' ? 'own' : isUnread ? 'unread' : 'read';
        if (prior?.visible !== visible || prior?.status !== status || prior?.index !== index) candidates(event.seq).set(key, { row, index, visible, status });
      });
    }
    result = { ...result, lastSeq: Math.max(before.lastSeq, event.seq), pendingSend: own ? undefined : before.pendingSend };
  }
  return result;
}
function firstUnread(state: State): Decision['divider'] {
  let first: { seq: number; row?: RowId; index: number } | undefined;
  for (const [seq, rows] of state.unread.candidates) for (const candidate of rows.values()) if (candidate.visible && candidate.status === 'unread' && (!first || seq < first.seq || seq === first.seq && candidate.index < first.index)) first = { seq, row: candidate.row, index: candidate.index };
  return first && { seq: first.seq, row: first.row };
}
export function reduce(previous: State, events: readonly ScrollEvent[]): { state: State; scrolled: boolean } {
  let state = { ...previous }, scrolled = false;
  const filtering = events.some(event => event.type === 'scope' && event.scope.view === previous.scope.view && event.scope.sessionId === previous.scope.sessionId && event.scope.topic !== previous.scope.topic);
  const follow = () => { state.mode = { kind: 'landing', target: { at: 'end' } }; state.latestShown = false; state.unread = unread(state, { type: 'clear' }, false, previous.unread.candidates); };
  for (const event of events) {
    const own = event.type === 'item' && event.appended && event.kind === 'user' && state.unread.pendingSend;
    const nextUnread = unread(state, event, filtering, previous.unread.candidates);
    if (event.type !== 'scope') state.unread = nextUnread;
    switch (event.type) {
      case 'scope': {
        if (state.scope.view === event.scope.view && state.scope.sessionId === event.scope.sessionId && state.scope.topic === event.scope.topic) break;
        if (state.mode.kind === 'travel') state.mode = { kind: 'reader', anchor: event.anchor };
        state.saved = new Map(scrollMemory(state).map(saved => [scopeKey(saved.scope), saved]));
        const target = state.saved.get(scopeKey(event.scope));
        const topicChanged = state.scope.view === event.scope.view && state.scope.sessionId === event.scope.sessionId;
        if (!topicChanged) state.transcript = undefined;
        state.scope = event.scope; state.seen = undefined; state.generation++; state.latestShown = false; state.unread = nextUnread;
        state.mode = { kind: 'landing', target: target && 'anchor' in target && target.scope.sessionId === event.scope.sessionId ? { at: 'anchor', saved: target } : topicChanged && !target ? { at: 'unread' } : { at: 'end' } };
        break;
      }
      case 'reset': case 'resize': {
        if (event.type === 'resize' && (event.top < -1 || event.top > event.max + 1)) break;
        if (event.type === 'reset' && state.transcript !== undefined && state.transcript !== event.epoch) {
          state.saved = new Map([...state.saved].filter(([, saved]) => saved.scope.view !== state.scope.view || saved.scope.sessionId !== state.scope.sessionId));
          if (state.mode.kind === 'landing' && state.mode.target.at === 'anchor') state.mode = { kind: 'landing', target: { at: 'reader', anchor: state.mode.target.saved.anchor } };
        }
        const mode = state.mode;
        state.mode = mode.kind === 'reader' && mode.anchor ? { kind: 'landing', target: { at: 'reader', anchor: mode.anchor } } : mode.kind === 'landing' ? mode : { kind: 'landing', target: { at: 'end' } };
        if (event.type === 'reset') { state.transcript = event.epoch; state.seen = undefined; state.generation++; }
        break;
      }
      case 'submit': follow(); break;
      case 'send-result': if (event.result !== 'handled' && event.result !== 'failed') follow(); break;
      case 'item':
        if (own) follow();
        else if (state.mode.kind === 'following' && Array.from(nextUnread.candidates.get(event.seq)?.values() ?? []).some(candidate => candidate.visible && candidate.status === 'unread')) state.mode = { kind: 'reader' };
        break;
      case 'input': {
        if (event.top < -1 || event.top > event.max + 1) break;
        const mode = state.mode;
        if (mode.kind === 'travel' || event.direction === 'up' && event.max > 1 && (mode.kind === 'following' || mode.kind === 'landing')) state.mode = { kind: 'reader', anchor: event.anchor };
        else if (mode.kind === 'landing') state.mode = { kind: 'following' };
        if (mode.kind !== 'reader') state.seen = { top: event.top, max: event.max };
        break;
      }
      case 'scroll': {
        const seen = state.seen;
        if (!seen || event.top < -1 || event.top > event.max + 1 || event.top === seen.top || seen.top > event.top && seen.max > event.max && Math.abs(event.max - event.top) < 1) break;
        const mode = state.mode;
        if (mode.kind === 'following' && event.top < Math.min(seen.top, seen.max) || mode.kind === 'travel' && event.top < seen.top) state.mode = { kind: 'reader', anchor: event.anchor };
        else if (mode.kind === 'reader' && event.top > seen.top && event.max - event.top <= 1) follow();
        else if (mode.kind === 'reader' && !event.layout) state.mode = { kind: 'reader', anchor: event.anchor };
        else if (mode.kind === 'reader' && mode.anchor) state.mode = { ...mode, anchor: { ...mode.anchor, offset: mode.anchor.offset + seen.top - event.top } };
        scrolled ||= state.mode.kind === 'reader';
        state.seen = { top: event.top, max: event.max };
        break;
      }
      case 'latest':
        if (event.reducedMotion) follow();
        else state.mode = { kind: 'travel', anchor: state.mode.kind === 'reader' ? state.mode.anchor : event.anchor, from: event.top, start: event.now };
        break;
      case 'visibility': if (!event.visible && state.mode.kind === 'travel') state.mode = { kind: 'reader', anchor: event.anchor }; break;
      case 'navigate': state.mode = { kind: 'landing', target: { at: 'reader', anchor: event.anchor } }; break;
      case 'layout':
        if (event.cause === 'toggle') state.mode = { kind: 'reader', anchor: event.anchor };
        break;
      case 'load-failed': if (state.generation === event.generation && state.mode.kind === 'landing') state.mode = { kind: 'landing', target: { at: 'end' } }; break;
      case 'history': case 'focus': break;
    }
  }
  const mode = state.mode;
  if (mode.kind === 'landing' && mode.target.at === 'unread') {
    const first = firstUnread(state);
    if (first) state.mode = { kind: 'landing', target: { at: 'reader', anchor: { item: { kind: 'message', ...first }, offset: 0, edge: 'divider' } } };
  }
  return { state, scrolled: scrolled && !filtering };
}
export function place(previous: State, m: Measure): { state: State; decision: Decision } {
  let state = { ...previous }, mode = state.mode;
  const focused = m.focused && m.visible, elastic = m.top < -1 || m.top > m.max + 1;
  const clamp = !!state.seen && state.seen.top > m.top && state.seen.max > m.max && Math.abs(m.max - m.top) < 1;
  let scrollTop: number | undefined, request: Decision['request'];
  if (!elastic) {
    if (mode.kind === 'reader' && !mode.anchor) mode = { ...mode, anchor: m.anchor };
    if (mode.kind === 'reader' && mode.anchor && state.seen && !clamp) mode = { ...mode, anchor: { ...mode.anchor, offset: mode.anchor.offset + state.seen.top - m.top } };
    if (mode.kind === 'following' && !focused && m.max - m.top > 1) mode = { kind: 'reader', anchor: m.anchor };
    if (mode.kind === 'travel') {
      const progress = Math.min(1, Math.max(0, (m.now - mode.start) / 250));
      if (progress === 1 || m.reducedMotion || Math.abs(m.max - mode.from) <= 1) { mode = { kind: 'following' }; scrollTop = m.max; }
      else scrollTop = mode.from + (m.max - mode.from) * (1 - (1 - progress) ** 3);
    }
    if (mode.kind === 'following') { if (focused) scrollTop = m.max; }
    else if (mode.kind === 'landing' || mode.kind === 'reader' && m.layout !== 'none') {
      const anchor = mode.kind === 'reader' ? mode.anchor : mode.target.at === 'anchor' ? mode.target.saved.anchor : mode.target.at === 'reader' ? mode.target.anchor : undefined;
      if (anchor) {
        const found = m.lookup(anchor.item);
        if (found.kind === 'mounted' || found.kind === 'unmounted') {
          const target = Math.max(0, Math.min(m.max, (anchor.edge === 'divider' ? found.row.leading ?? found.row.top : found.row.top) - anchor.offset));
          if (mode.kind === 'landing' || m.layout === 'toggle' || Math.abs(target - m.top) >= 1) scrollTop = target;
          if (found.kind === 'unmounted') request = { type: 'mount', item: anchor.item };
          else if (mode.kind === 'landing' && m.settled) mode = { kind: 'reader', anchor };
          if (mode.kind === 'reader' && m.layout === 'toggle' && target >= m.max) mode = { kind: 'following' };
        } else if (found.kind === 'unloaded') request = { type: 'load', item: anchor.item, generation: state.generation };
        else if (mode.kind === 'landing') { scrollTop = m.max; if (m.settled) mode = { kind: 'following' }; }
        else if (found.next) mode = { kind: 'reader', anchor: { item: found.next.item, offset: found.next.top - m.top, edge: 'row' } };
        else scrollTop = m.max;
      } else if (mode.kind === 'landing') { scrollTop = m.max; if (m.settled) mode = { kind: 'following' }; }
    }
  }
  state.mode = mode;
  if (mode.kind === 'following' && focused) state.unread = unread(state, { type: 'clear' });
  const top = scrollTop ?? (elastic ? state.seen?.top ?? Math.max(0, Math.min(m.max, m.top)) : m.top);
  if (!elastic) state.seen = { top, max: m.max };
  const distance = m.max - top;
  if (mode.kind !== 'reader' && mode.kind !== 'travel') state.latestShown = false;
  else if (distance > m.viewport / 3) state.latestShown = true;
  else if (distance < m.viewport / 4) state.latestShown = false;
  if (m.scrolled && focused) {
    for (const [seq, rows] of state.unread.candidates) for (const candidate of rows.values()) {
      if (!candidate.visible || candidate.status !== 'unread') continue;
      const found = m.lookup({ kind: 'message', seq, row: candidate.row });
      if (found.kind === 'mounted' && found.row.top >= top && found.row.bottom <= top + m.dock) {
        const candidates = new Map(state.unread.candidates), next = new Map(rows);
        for (const [key, item] of rows) if (item.status === 'unread') next.set(key, { ...item, status: 'read' });
        candidates.set(seq, next); state.unread = { ...state.unread, candidates };
      }
    }
  }
  const counted = new Set<number>();
  let divider: Decision['divider'], dividerIndex = Infinity;
  for (const [seq, rows] of state.unread.candidates) for (const candidate of rows.values()) {
    if (candidate.status !== 'unread' || !candidate.visible) continue;
    if (!divider || seq < divider.seq || seq === divider.seq && candidate.index < dividerIndex) { divider = { seq, row: candidate.row }; dividerIndex = candidate.index; }
    const found = m.lookup({ kind: 'message', seq, row: candidate.row });
    if ((found.kind === 'mounted' || found.kind === 'unmounted') && found.row.top >= top + m.dock) counted.add(seq);
  }
  const windowTop = scrollWindow(state, (item, edge) => {
    const found = m.lookup(item);
    return found.kind === 'mounted' || found.kind === 'unmounted' ? (edge === 'divider' ? found.row.leading ?? found.row.windowTop ?? found.row.top : found.row.windowTop ?? found.row.top) - m.origin : undefined;
  }, top - m.origin, m.windowMax ?? Math.max(0, m.max - m.origin));
  return { state, decision: { scrollTop, latest: { show: (mode.kind === 'reader' || mode.kind === 'travel') && (counted.size > 0 || state.latestShown), count: counted.size }, divider, windowTop, request, frame: mode.kind === 'travel' } };
}
