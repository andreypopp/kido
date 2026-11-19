import type { PromptResult } from '../koa-records.ts';

export type ItemId = { kind: 'message'; seq: number } | { kind: 'job'; byte: number };
export type Anchor = { item: ItemId; offset: number };
type Scope = { view: string; sessionId: string | undefined };
type Saved = { scope: Scope; anchor: Anchor; last: number };
type Glide = { from: number; start: number; offset: number };
type Travel = { from: number; start: number };
type Geometry = { top: number; max: number; viewport: number; width: number; origin: number };
type Candidate = { visible: boolean; unread: boolean };
type Common = {
  scope: Scope;
  last?: Geometry;
  written?: { top: number; echo: boolean };
  pendingSend?: { mode: 'following' | 'reader' };
  forceItem?: { seq: number; mode: 'following' | 'reader' };
  saved: Map<string, Saved>;
  candidates: Map<number, Candidate>;
  threshold: boolean;
  generation: number;
  lastSeq: number;
  settling: 'none' | 'render' | 'delivery';
};
export type State = Common & (
  | { kind: 'following'; glide?: Glide }
  | { kind: 'reader'; anchor?: Anchor; travel?: Travel }
  | { kind: 'restoring'; target: Saved; waiting: boolean }
);
type Cause = 'layout' | 'instant';
export type ScrollEvent =
  | { type: 'input'; direction: 'up' | 'down' }
  | { type: 'scroll' }
  | { type: 'layout'; cause: Cause }
  | { type: 'layout'; cause: 'toggle'; anchor: Anchor }
  | { type: 'submit' }
  | { type: 'send-result'; result: PromptResult['disposition'] | 'failed' }
  | { type: 'item'; seq: number; kind: 'user' | 'assistant' | 'other'; visible: boolean; appended: boolean }
  | { type: 'focus' | 'visibility' | 'frame' | 'resize' | 'latest' | 'history' }
  | { type: 'switch'; scope: Scope }
  | { type: 'reset' }
  | { type: 'restore-result'; generation: number; found: boolean }
  | { type: 'navigate'; anchor: Anchor };
export type Row = { item: ItemId; top: number; bottom: number; windowTop?: number };
export type Lookup =
  | { kind: 'mounted'; row: Row }
  | { kind: 'unmounted'; row: Row }
  | { kind: 'unloaded' }
  | { kind: 'removed'; next?: Row };
export type Measure = Geometry & {
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
  glideOffset: number;
  latest: { show: boolean; count: number };
  dividerBefore?: number;
  windowTop: number;
  request?: { type: 'mount'; item: ItemId } | { type: 'load'; item: ItemId; generation: number };
  frame: 'none' | 'animation' | 'measure';
};
export function scrollInitial(scope: Scope): State {
  return {
    kind: 'following',
    scope,
    saved: new Map(),
    candidates: new Map(),
    threshold: false,
    generation: 0,
    lastSeq: -1,
    settling: 'none',
  };
}
function common(state: State): Common {
  switch (state.kind) {
    case 'following': { const { kind, glide, ...data } = state; return data; }
    case 'reader': { const { kind, anchor, travel, ...data } = state; return data; }
    case 'restoring': { const { kind, target, waiting, ...data } = state; return data; }
  }
}
export function scrollWindow(state: State, position: (item: ItemId) => number | undefined, top: number, bottom: number): number {
  if (state.kind === 'following') return bottom;
  if (state.kind === 'reader' && state.travel) return top;
  const anchor = state.kind === 'reader' ? state.anchor : state.target.anchor;
  const y = anchor && position(anchor.item);
  return y !== undefined && anchor ? y - anchor.offset : state.kind === 'restoring' ? bottom : top;
}
function offset(glide: Glide | undefined, now: number) {
  if (!glide) return 0;
  const progress = Math.min(1, Math.max(0, (now - glide.start) / 180));
  if (!progress) return glide.from;
  if (progress === 1) return 0;
  let low = 0, high = 1;
  for (let n = 0; n < 24; n++) {
    const t = (low + high) / 2;
    if (1.74 * t * t * (1 - t) + t ** 3 < progress) low = t; else high = t;
  }
  const t = (low + high) / 2;
  return glide.from * (1 - (3 * t * t - 2 * t ** 3));
}
export function scrollStored(state: State, top: number): State {
  return { ...state, written: { top, echo: true }, last: state.last && { ...state.last, top } };
}
export function scrollUpdate(previous: State, events: readonly ScrollEvent[], m: Measure): { state: State; decision: Decision } {
  let state: State = { ...previous };
  const wasSettling = previous.settling;
  let instant = state.settling !== 'none';
  let newInstant = false;
  let force = state.forceItem !== undefined;
  let sentHeight: number | undefined;
  let scrollTop: number | undefined;
  let request: Decision['request'];
  const focused = m.focused && m.visible;
  const candidates = () => {
    if (state.candidates === previous.candidates) state.candidates = new Map(state.candidates);
    return state.candidates;
  };
  const clear = () => {
    for (const [seq, candidate] of state.candidates) {
      if (candidate.unread) candidates().set(seq, { ...candidate, unread: false });
    }
    state.threshold = false;
  };
  const follow = () => {
    state = { ...common(state), kind: 'following' };
    clear();
    force = true;
  };
  const clamp = !!state.last && state.last.top > m.top && state.last.max > m.max && Math.abs(m.max - m.top) < 1;
  if (state.kind === 'reader' && state.anchor && !state.travel && state.last && !clamp) state.anchor = { ...state.anchor, offset: state.anchor.offset - m.top + state.last.top };
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
        if (state.kind === 'following' && event.direction === 'up' && m.max > 1 || state.kind === 'reader' && state.travel) {
          state.forceItem = undefined;
          reader();
        }
        break;
      case 'scroll': {
        const written = state.written;
        if (written) state.written = { ...written, echo: false };
        if (written?.echo && m.top === written.top || !state.last || clamp) break;
        const last = state.last;
        if (state.kind === 'following') { if (!force && m.top < Math.min(written?.top ?? last.max, last.max)) reader(); }
        else if (state.kind !== 'reader') break;
        else if (state.travel) { if (written && m.top < written.top) reader(); }
        else if (m.top > last.top && m.max - m.top <= 1) follow();
        else if (!events.some(other => other.type === 'layout' || other.type === 'history' || other.type === 'resize')) reader();
        break;
      }
      case 'submit':
        state.pendingSend = { mode: state.kind === 'following' ? 'following' : 'reader' };
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
          state.forceItem = { seq: event.seq, mode: state.pendingSend.mode };
          state.pendingSend = undefined;
          follow();
        }
        if (event.kind !== 'assistant') break;
        const before = state.candidates.get(event.seq);
        if (!event.appended && !before && state.kind !== 'restoring') break;
        const unread = event.visible && (before?.unread || !before?.visible && !(state.kind === 'following' && focused) && (state.kind !== 'restoring' || event.seq > state.target.last));
        if (before?.visible !== event.visible || before?.unread !== unread) candidates().set(event.seq, { visible: event.visible, unread });
        if (unread && state.kind === 'following') reader();
        break;
      }
      case 'switch': {
        if (state.kind === 'reader' && state.travel) reader();
        if (state.kind === 'reader' && state.anchor) {
          state.saved = new Map(state.saved);
          state.saved.set(state.scope.view, { scope: state.scope, anchor: state.anchor, last: state.lastSeq });
        } else if (state.kind !== 'restoring' && state.saved.has(state.scope.view)) {
          state.saved = new Map(state.saved);
          state.saved.delete(state.scope.view);
        }
        const target = state.saved.get(event.scope.view);
        state.scope = event.scope;
        state.pendingSend = undefined;
        state.forceItem = undefined;
        state.last = undefined;
        state.written = undefined;
        state.lastSeq = -1;
        state.generation++;
        state.candidates = new Map();
        clear();
        instant = true;
        state = target && target.scope.sessionId === event.scope.sessionId
          ? { ...common(state), kind: 'restoring', target, waiting: true }
          : { ...common(state), kind: 'following' };
        force = state.kind === 'following';
        break;
      }
      case 'reset':
        state.pendingSend = undefined;
        state.forceItem = undefined;
        state.last = undefined;
        state.written = undefined;
        state.candidates = new Map();
        clear();
        instant = true;
        force = state.kind === 'following';
        if (state.kind === 'restoring') state = { ...state, waiting: false };
        break;
      case 'restore-result':
        if (state.kind === 'restoring' && event.generation === state.generation) {
          if (event.found) state = { ...state, waiting: false };
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
  if (state.kind === 'restoring' && !state.waiting) {
    const target = state.target;
    const found = m.lookup(target.anchor.item);
    if (found.kind === 'mounted') {
      reader(target.anchor);
      instant = true;
      for (const [seq, candidate] of state.candidates) {
        if (seq > target.last && candidate.visible && !candidate.unread) candidates().set(seq, { ...candidate, unread: true });
      }
    } else if (found.kind === 'unmounted') request = { type: 'mount', item: target.anchor.item };
    else if (found.kind === 'unloaded') request = { type: 'load', item: target.anchor.item, generation: state.generation };
    else if (events.some(event => event.type === 'frame' || event.type === 'layout')) follow();
  }
  if (state.forceItem?.mode === 'reader') {
    const found = m.lookup({ kind: 'message', seq: state.forceItem.seq });
    if (found.kind === 'mounted') sentHeight = found.row.bottom - found.row.top;
    else instant = true;
  }
  const resized = state.last && (state.last.viewport !== m.viewport || state.last.width !== m.width);
  if (resized) {
    instant = true;
    newInstant = true;
    state.settling = 'delivery';
  }
  if (state.kind === 'following' && !focused && !force && m.max - m.top > 1) reader(previous.kind === 'following' ? m.anchor : undefined);
  if (state.kind === 'following') {
    if (force || focused) scrollTop = m.max;
    if (instant || !focused || m.reducedMotion || !state.last) state = { ...state, glide: undefined };
    else {
      const delta = sentHeight ?? m.max - state.last.max;
      const current = sentHeight === undefined ? offset(state.glide, m.now) : 0;
      if (delta) {
        const from = Math.max(-m.viewport, Math.min(m.viewport, current + delta));
        state = { ...state, glide: { from, start: m.now, offset: from } };
      } else if (state.glide) state = { ...state, glide: current ? { ...state.glide, offset: current } : undefined };
    }
    if (focused) clear();
  } else if (state.kind === 'reader') {
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
        const target = Math.max(0, Math.min(m.max, found.row.top - anchor.offset));
        if (target !== m.top && (events.some(event => event.type === 'layout' && event.cause === 'toggle') || Math.abs(target - m.top) >= 1)) scrollTop = target;
        if (found.kind === 'unmounted') request = { type: 'mount', item: anchor.item };
      } else if (found.kind === 'unloaded') request = { type: 'load', item: anchor.item, generation: state.generation };
      else if (found.next) state = { ...state, anchor: { item: found.next.item, offset: found.next.top - m.top } };
      else scrollTop = m.max;
    }
  }
  if (scrollTop !== undefined) scrollTop = Math.max(0, Math.min(m.max, scrollTop));
  const top = scrollTop ?? m.top;
  const distance = m.max - top;
  if (state.kind !== 'reader') state.threshold = false;
  else if (distance > m.viewport / 3) state.threshold = true;
  else if (distance < m.viewport / 4) state.threshold = false;
  let count = 0;
  let dividerBefore: number | undefined;
  for (const [seq, candidate] of state.candidates) {
    if (!candidate.unread || !candidate.visible) continue;
    dividerBefore = dividerBefore === undefined ? seq : Math.min(dividerBefore, seq);
    const found = m.lookup({ kind: 'message', seq });
    if ((found.kind === 'mounted' || found.kind === 'unmounted') && found.row.top >= top + m.dock) count++;
  }
  if (state.forceItem && m.lookup({ kind: 'message', seq: state.forceItem.seq }).kind === 'mounted') state.forceItem = undefined;
  const glideOffset = state.kind === 'following' ? state.glide?.offset ?? 0 : 0;
  if (!newInstant && events.some(event => event.type === 'frame') && !request && state.kind !== 'restoring') {
    if (wasSettling === 'delivery') state.settling = 'none';
    else if (wasSettling === 'render') state.settling = 'delivery';
  }
  state.last = { top, max: m.max, viewport: m.viewport, width: m.width, origin: m.origin };
  const windowTop = scrollWindow(state, item => {
    const found = m.lookup(item);
    return found.kind === 'mounted' || found.kind === 'unmounted' ? (found.row.windowTop ?? found.row.top) - m.origin : undefined;
  }, top - m.origin, m.windowMax ?? Math.max(0, m.max - m.origin));
  let frame: Decision['frame'] = 'none';
  if (state.kind === 'following' && (resized || events.some(event => event.type === 'layout'))) frame = 'measure';
  else if (state.settling !== 'none' && state.kind !== 'restoring' || state.kind === 'following' && state.glide || state.kind === 'reader' && state.travel) frame = 'animation';
  return {
    state,
    decision: {
      scrollTop,
      glideOffset,
      latest: { show: state.kind === 'reader' && (count > 0 || state.threshold), count },
      dividerBefore,
      windowTop,
      request,
      frame,
    },
  };
}
