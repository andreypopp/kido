import { rowKey, type RowId } from './extent.ts';
import type { PromptResult } from '../koa-records.ts';

export type ItemId = { kind: 'message'; seq: number; row?: RowId } | { kind: 'job'; byte: number };
export type Anchor = { item: ItemId; offset: number; edge: 'row' | 'divider' };
type Scope = { view: string; sessionId: string | undefined; topic?: string };
const scopeKey = (scope: Scope): string => JSON.stringify([scope.view, scope.topic ?? null]);
export type Saved = { scope: Scope; anchor: Anchor; last: number } | { scope: Scope; last: number };
type Travel = { from: number; start: number };
type Geometry = { top: number; max: number; viewport: number; width: number; origin: number };
type Candidate = { row?: RowId; index: number; visible: boolean; unread: boolean };
type Common = {
  scope: Scope;
  floor?: number;
  last?: Geometry;
  written?: { top: number; echo: boolean };
  pendingSend?: true;
  forceItem?: { seq: number };
  saved: Map<string, Saved>;
  candidates: Map<number, Map<string, Candidate>>;
  threshold: boolean;
  filtered: boolean;
  generation: number;
  lastSeq: number;
  settling: 'none' | 'render' | 'delivery';
};
export type State = Common & (
  | { kind: 'following'; positioning?: boolean }
  | { kind: 'reader'; anchor?: Anchor; travel?: Travel }
  | { kind: 'restoring'; target: Extract<Saved, { anchor: Anchor }>; waiting: 'none' | 'snapshot' | 'catchup' }
);
type Cause = 'layout' | 'instant';
export type ScrollEvent =
  | { type: 'input'; direction: 'up' | 'down' }
  | { type: 'scroll' }
  | { type: 'layout'; cause: Cause }
  | { type: 'layout'; cause: 'toggle'; anchor: Anchor }
  | { type: 'submit' }
  | { type: 'send-result'; result: PromptResult['disposition'] | 'failed' }
  | { type: 'item'; seq: number; kind: 'user' | 'assistant' | 'other'; visible: boolean; appended: boolean; rows?: { row: RowId; visible: boolean }[] }
  | { type: 'focus' | 'visibility' | 'frame' | 'resize' | 'latest' | 'history' }
  | { type: 'switch'; scope: Scope; loaded: boolean; filtered: boolean }
  | { type: 'reset' }
  | { type: 'filter'; active: boolean; topic?: string }
  | { type: 'restore-result'; generation: number; found: boolean }
  | { type: 'catchup'; generation: number; pending: boolean }
  | { type: 'navigate'; anchor: Anchor };
export type Row = { item: ItemId; top: number; bottom: number; windowTop?: number; leading?: number };
export type Lookup =
  | { kind: 'mounted'; row: Row }
  | { kind: 'unmounted'; row: Row }
  | { kind: 'unloaded' }
  | { kind: 'removed'; next?: Row };
export type Measure = Geometry & {
  naturalHeight: number;
  now: number;
  focused: boolean;
  visible: boolean;
  reducedMotion: boolean;
  dock: number;
  lookup: (item: ItemId) => Lookup;
  windowMax?: number;
  anchor?: Anchor;
};
export type Decision = {
  scrollTop?: number;
  minHeight?: number;
  latest: { show: boolean; count: number };
  divider?: { seq: number; row?: RowId };
  windowTop: number;
  request?: { type: 'mount'; item: ItemId } | { type: 'load'; item: ItemId; generation: number };
  frame: 'none' | 'animation' | 'measure';
};
export function scrollMemory(state: State): Saved[] {
  const saved = new Map(state.saved);
  if (state.kind === 'reader' && !state.travel && state.anchor) saved.set(scopeKey(state.scope), { scope: state.scope, anchor: state.anchor, last: state.lastSeq });
  else if (state.kind === 'restoring') saved.set(scopeKey(state.scope), state.target);
  else saved.set(scopeKey(state.scope), { scope: state.scope, last: state.lastSeq });
  return [...saved.values()];
}
export function scrollInitial(scope: Scope, memory: Saved[] = []): State {
  return {
    kind: 'following',
    positioning: true,
    scope,
    saved: new Map(memory.map(saved => [scopeKey(saved.scope), saved])),
    candidates: new Map(),
    threshold: false,
    filtered: false,
    generation: 0,
    lastSeq: -1,
    settling: 'none',
  };
}
function common(state: State): Common {
  switch (state.kind) {
    case 'following': { const { kind, positioning, ...data } = state; return data; }
    case 'reader': { const { kind, anchor, travel, ...data } = state; return data; }
    case 'restoring': { const { kind, target, waiting, ...data } = state; return data; }
  }
}
export function scrollWindow(state: State, position: (item: ItemId, edge: 'row' | 'divider') => number | undefined, top: number, bottom: number): number {
  if (state.kind === 'following') return bottom;
  if (state.kind === 'reader' && state.travel) return top;
  const anchor = state.kind === 'reader' ? state.anchor : state.target.anchor;
  const y = anchor && position(anchor.item, anchor.edge);
  return y !== undefined && anchor ? y - anchor.offset : state.kind === 'restoring' ? bottom : top;
}
export function scrollStored(state: State, top: number): State {
  return { ...state, written: { top, echo: true }, last: state.last && { ...state.last, top } };
}
export function scrollUpdate(previous: State, events: readonly ScrollEvent[], m: Measure): { state: State; decision: Decision } {
  let state: State = { ...previous };
  const wasSettling = previous.settling;
  let instant = state.settling !== 'none';
  let newInstant = false;
  let filtering = false, sawScroll = false;
  let force = state.forceItem !== undefined;
  let scrollTop: number | undefined;
  let minHeight: number | undefined;
  let request: Decision['request'];
  const focused = m.focused && m.visible;
  const overscrolled = m.top < -1 || m.top > m.max + 1;
  const candidates = (seq: number) => {
    if (state.candidates === previous.candidates) state.candidates = new Map(state.candidates);
    let rows = state.candidates.get(seq);
    if (!rows || rows === previous.candidates.get(seq)) { rows = new Map(rows); state.candidates.set(seq, rows); }
    return rows;
  };
  const clear = () => {
    for (const [seq, rows] of state.candidates) if (Array.from(rows.values()).some(candidate => candidate.unread && candidate.visible)) {
      for (const [key, candidate] of rows) if (candidate.unread) candidates(seq).set(key, { ...candidate, unread: false });
    }
    state.threshold = false;
  };
  const follow = () => {
    state = { ...common(state), kind: 'following', positioning: true };
    clear();
    force = true;
  };
  const clamp = !!state.last && state.last.top > m.top && state.last.max > m.max && Math.abs(m.max - m.top) < 1;
  if (!overscrolled && state.kind === 'reader' && state.anchor && !state.travel && state.last && !clamp) state.anchor = { ...state.anchor, offset: state.anchor.offset - m.top + state.last.top };
  const reader = (anchor = m.anchor) => {
    state = { ...common(state), kind: 'reader', anchor };
  };
  for (const event of events) {
    if (event.type === 'history' || event.type === 'reset' || event.type === 'switch' || event.type === 'resize' || event.type === 'layout' && event.cause === 'instant') {
      state.settling = 'render';
      newInstant = true;
    } else if (event.type === 'layout' && state.settling === 'render') state.settling = 'delivery';
    switch (event.type) {
      case 'input':
        if (overscrolled) break;
        if (state.kind === 'following') state.positioning = undefined;
        if (state.kind === 'following' && event.direction === 'up' && m.max > 1 || state.kind === 'reader' && state.travel) {
          state.forceItem = undefined;
          reader();
        }
        break;
      case 'scroll': {
        if (overscrolled) break;
        const written = state.written;
        if (written) state.written = { ...written, echo: false };
        if (written?.echo && m.top === written.top || !state.last || clamp) break;
        sawScroll = true;
        const last = state.last;
        if (state.kind === 'following') { if (!force && m.top < Math.min(written?.top ?? last.max, last.max)) reader(); }
        else if (state.kind !== 'reader') break;
        else if (state.travel) { if (written && m.top < written.top) reader(); }
        else if (m.top > last.top && m.max - m.top <= 1) follow();
        else if (!events.some(other => other.type === 'layout' || other.type === 'history' || other.type === 'resize')) reader();
        break;
      }
      case 'submit':
        state.pendingSend = true;
        follow();
        instant = true;
        break;
      case 'send-result':
        if (event.result === 'handled' || event.result === 'failed') state.pendingSend = undefined;
        else follow();
        instant = true;
        break;
      case 'item': {
        state.lastSeq = Math.max(state.lastSeq, event.seq);
        if (event.appended && event.kind === 'user' && state.pendingSend) {
          state.forceItem = { seq: event.seq };
          state.pendingSend = undefined;
          follow();
        }
        if (event.kind !== 'assistant') break;
        const rows = event.rows?.length ? event.rows : [{ row: undefined, visible: event.visible }];
        const known = state.candidates.get(event.seq);
        const baseline = !event.appended && !known && state.kind !== 'restoring';
        const keys = new Set(rows.map(({ row }) => row ? rowKey(row) : ''));
        for (const [key, candidate] of known ?? []) if (!keys.has(key) && (candidate.visible || candidate.unread)) candidates(event.seq).set(key, { ...candidate, visible: false, unread: state.filtered && candidate.unread });
        rows.forEach(({ row, visible }, index) => {
          const key = row ? rowKey(row) : '', before = known?.get(key);
          const arrived = event.rows?.length ? !Array.from(known?.values() ?? []).some(candidate => candidate.row) : !before?.visible;
          const unread = (before ? before.unread : Array.from(known?.values() ?? []).some(candidate => candidate.unread)) && (state.filtered || visible) || (!!event.rows?.length || event.visible) && arrived && !baseline && !filtering && !(state.kind === 'following' && focused && visible) && (state.kind !== 'restoring' || event.seq > state.target.last);
          if (before?.visible !== visible || before?.unread !== unread || before?.index !== index) candidates(event.seq).set(key, { row, index, visible, unread });
          if (unread && visible && state.kind === 'following' && !state.positioning) reader();
        });
        break;
      }
      case 'filter':
      case 'switch': {
        const scope = event.type === 'filter' ? { ...state.scope, topic: event.topic } : event.scope;
        state.filtered = event.type === 'filter' ? event.active : event.filtered;
        if (state.kind === 'reader' && state.travel) reader();
        state.saved = new Map(scrollMemory(state).map(saved => [scopeKey(saved.scope), saved]));
        const target = state.saved.get(scopeKey(scope));
        state.scope = scope;
        state.floor = undefined;
        state.pendingSend = undefined;
        state.forceItem = undefined;
        state.last = undefined;
        state.written = undefined;
        if (event.type === 'switch') {
          state.lastSeq = -1;
          state.candidates = new Map();
          clear();
        } else {
          for (const [seq, rows] of state.candidates) for (const [key, candidate] of rows) if (candidate.visible) candidates(seq).set(key, { ...candidate, visible: false });
        }
        state.generation++;
        state.settling = 'render';
        instant = true; newInstant = true;
        filtering = event.type === 'filter';
        state = target && 'anchor' in target && target.scope.sessionId === scope.sessionId
          ? { ...common(state), kind: 'restoring', target, waiting: event.type === 'filter' || event.filtered ? 'catchup' : !event.loaded ? 'snapshot' : 'none' }
          : { ...common(state), kind: 'following', positioning: true };
        force = state.kind === 'following';
        if (filtering && !target) state = { ...common(state), kind: 'reader' };
        break;
      }
      case 'reset':
        state.floor = undefined;
        state.pendingSend = undefined;
        state.forceItem = undefined;
        state.last = undefined;
        state.written = undefined;
        state.candidates = new Map();
        clear();
        instant = true;
        force = state.kind === 'following';
        if (state.kind === 'following') state.positioning = true;
        if (state.kind === 'restoring') state = { ...state, waiting: 'none' };
        break;
      case 'catchup':
        if (state.kind === 'restoring' && event.generation === state.generation) state = { ...state, waiting: event.pending ? 'catchup' : 'none' };
        break;
      case 'restore-result':
        if (state.kind === 'restoring' && event.generation === state.generation) {
          if (event.found) state = { ...state, waiting: state.waiting === 'catchup' ? 'catchup' : 'none' };
          else follow();
          instant = true;
        }
        break;
      case 'navigate':
        reader(event.anchor);
        instant = true;
        break;
      case 'latest':
        if (m.reducedMotion) follow();
        else state = {
          ...common(state),
          kind: 'reader',
          anchor: state.kind === 'reader' ? state.anchor : m.anchor,
          travel: { from: m.top, start: m.now },
        };
        instant = true;
        break;
      case 'history': case 'resize': instant = true; break;
      case 'layout':
        if (event.cause === 'toggle') {
          state.forceItem = undefined;
          force = false;
          reader(event.anchor);
          instant = true;
          const found = m.lookup(event.anchor.item);
          if ((found.kind === 'mounted' || found.kind === 'unmounted') && found.row.top - event.anchor.offset >= m.max) follow();
        } else instant ||= event.cause === 'instant';
        break;
      case 'visibility':
        if (!m.visible && state.kind === 'reader' && state.travel) reader();
        break;
      case 'focus': case 'frame': break;
    }
  }
  if (filtering && state.kind === 'reader' && !state.anchor) {
    let first: { seq: number; candidate: Candidate } | undefined;
    for (const [seq, rows] of state.candidates) for (const candidate of rows.values()) if (candidate.visible && candidate.unread && (!first || seq < first.seq || seq === first.seq && candidate.index < first.candidate.index)) first = { seq, candidate };
    if (first) reader({ item: { kind: 'message', seq: first.seq, row: first.candidate.row }, offset: 0, edge: 'divider' });
    else follow();
  }
  if (state.kind === 'restoring' && state.waiting === 'none') {
    const target = state.target;
    const found = m.lookup(target.anchor.item);
    if (found.kind === 'mounted') {
      reader(target.anchor);
      instant = true;
      for (const [seq, rows] of state.candidates) for (const [key, candidate] of rows) {
        if (seq > target.last && candidate.visible && !candidate.unread) candidates(seq).set(key, { ...candidate, unread: true });
      }
    } else if (found.kind === 'unmounted') request = { type: 'mount', item: target.anchor.item };
    else if (found.kind === 'unloaded') request = { type: 'load', item: target.anchor.item, generation: state.generation };
    else if (events.some(event => event.type === 'frame' || event.type === 'layout')) follow();
  }
  const resized = state.last && (state.last.viewport !== m.viewport || state.last.width !== m.width);
  if (resized || events.some(event => event.type === 'resize')) state.floor = undefined;
  if (resized) {
    instant = true;
    newInstant = true;
    state.settling = 'delivery';
  }
  if (!overscrolled && state.kind === 'following' && !focused && !force && !state.positioning && m.max - m.top > 1) reader(previous.kind === 'following' ? m.anchor : undefined);
  if (!overscrolled && state.kind === 'following') {
    if (force || focused || state.positioning) scrollTop = Math.max(0, Math.max(state.floor ?? 0, m.naturalHeight) - m.viewport);
    if (focused) clear();
  } else if (!overscrolled && state.kind === 'reader') {
    if (state.travel) {
      const progress = Math.min(1, Math.max(0, (m.now - state.travel.start) / 250));
      if (progress === 1 || m.reducedMotion || Math.abs(m.max - state.travel.from) <= 1) {
        follow();
        scrollTop = m.max;
      } else scrollTop = state.travel.from + (m.max - state.travel.from) * (1 - (1 - progress) ** 3);
    } else if (state.anchor && (instant || events.some(event => event.type === 'layout'))) {
      const anchor = state.anchor;
      const found = m.lookup(anchor.item);
      if (found.kind === 'mounted' || found.kind === 'unmounted') {
        const target = Math.max(0, Math.min(m.max, (anchor.edge === 'divider' ? found.row.leading ?? found.row.top : found.row.top) - anchor.offset));
        if (target !== m.top && (events.some(event => event.type === 'layout' && event.cause === 'toggle') || Math.abs(target - m.top) >= 1)) scrollTop = target;
        if (found.kind === 'unmounted') request = { type: 'mount', item: anchor.item };
      } else if (found.kind === 'unloaded') request = { type: 'load', item: anchor.item, generation: state.generation };
      else if (found.next) state = { ...state, anchor: { item: found.next.item, offset: found.next.top - m.top, edge: 'row' } };
      else scrollTop = m.max;
    }
  }
  if (state.kind === 'following') {
    state.floor = Math.max(state.floor ?? 0, m.naturalHeight);
    minHeight = state.floor;
  } else if (state.kind === 'reader' && state.floor !== undefined) {
    minHeight = Math.max(m.naturalHeight, Math.min(state.floor, (scrollTop ?? m.top) + m.viewport));
    state.floor = minHeight > m.naturalHeight ? minHeight : undefined;
  }
  if (state.kind === 'following' && scrollTop === Math.max(0, (minHeight ?? 0) - m.viewport) && scrollTop > 0 && !events.some(event => event.type === 'reset' || event.type === 'switch')) state.positioning = undefined;
  if (scrollTop !== undefined) scrollTop = Math.max(0, Math.min(Math.max(m.max, (minHeight ?? 0) - m.viewport), scrollTop));
  const top = scrollTop ?? (overscrolled ? state.last?.top ?? Math.max(0, Math.min(m.max, m.top)) : m.top);
  const distance = m.max - top;
  if (state.kind !== 'reader') state.threshold = false;
  else if (distance > m.viewport / 3) state.threshold = true;
  else if (distance < m.viewport / 4) state.threshold = false;
  if (sawScroll && focused && !filtering) {
    for (const [seq, rows] of state.candidates) for (const candidate of rows.values()) {
      if (!candidate.visible || !candidate.unread) continue;
      const found = m.lookup({ kind: 'message', seq, row: candidate.row });
      if (found.kind === 'mounted' && found.row.top >= top && found.row.bottom <= top + m.dock) for (const [key, item] of rows) if (item.unread) candidates(seq).set(key, { ...item, unread: false });
    }
  }
  let count = 0;
  let divider: Decision['divider'], dividerIndex = Infinity;
  for (const [seq, rows] of state.candidates) for (const candidate of rows.values()) {
    if (!candidate.unread || !candidate.visible) continue;
    const { row, index } = candidate;
    if (!divider || seq < divider.seq || seq === divider.seq && index < dividerIndex) { divider = { seq, row }; dividerIndex = index; }
    const found = m.lookup({ kind: 'message', seq, row });
    if ((found.kind === 'mounted' || found.kind === 'unmounted') && found.row.top >= top + m.dock) count++;
  }
  if (state.forceItem && m.lookup({ kind: 'message', seq: state.forceItem.seq }).kind === 'mounted') state.forceItem = undefined;
  if (!newInstant && events.some(event => event.type === 'frame') && !request && state.kind !== 'restoring') {
    if (wasSettling === 'delivery') state.settling = 'none';
    else if (wasSettling === 'render') state.settling = 'delivery';
  }
  if (!overscrolled) state.last = { top, max: m.max, viewport: m.viewport, width: m.width, origin: m.origin };
  const windowTop = scrollWindow(state, (item, edge) => {
    const found = m.lookup(item);
    return found.kind === 'mounted' || found.kind === 'unmounted' ? (edge === 'divider' ? found.row.leading ?? found.row.windowTop ?? found.row.top : found.row.windowTop ?? found.row.top) - m.origin : undefined;
  }, top - m.origin, m.windowMax ?? Math.max(0, m.max - m.origin));
  let frame: Decision['frame'] = 'none';
  if (state.kind === 'following' && (resized || events.some(event => event.type === 'layout'))) frame = 'measure';
  else if (state.settling !== 'none' && state.kind !== 'restoring' || state.kind === 'reader' && state.travel) frame = 'animation';
  return {
    state,
    decision: {
      scrollTop,
      minHeight,
      latest: { show: state.kind === 'reader' && (count > 0 || state.threshold), count },
      divider,
      windowTop,
      request,
      frame,
    },
  };
}
