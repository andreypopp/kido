import { Lexer } from 'marked';
import type { Observation, PageRecord, WriteSource } from '../koa-records.ts';
import { fallbacks, instrument } from './markdown.ts';

type Label = { type: 'frame'; gap?: number } | { type: 'apply'; record: PageRecord['type'] };
type Scope = { kind: Label['type']; source: WriteSource; lex: number; strays: number; probes: number; by: Partial<Record<WriteSource, number>> };
type Probe = { matches(selector: string): boolean; querySelector(selector: string): unknown };
export type Spot = 'row' | 'step';

export function strayReads(schedule: () => void) {
  let dirty = false, scheduled = false, outside = false;
  return {
    write(inFrame: boolean) { dirty = true; if (!inFrame) outside = true; if (!scheduled) { scheduled = true; schedule(); } },
    settle() { dirty = false; scheduled = false; },
    frameStart() { if (!outside) { dirty = false; scheduled = false; } outside = false; },
    read() { const stray = dirty; dirty = false; return stray; },
  };
}

export function holdsDots(node: object): boolean {
  const probe: Partial<Probe> = node;
  return probe.matches?.('.dots') === true || (probe.querySelector?.('.dots') ?? null) !== null;
}

export function dotsPhase(before: Spot | undefined, after: Spot | undefined): 'call' | 'text' | 'end' {
  if (after === undefined) return 'end';
  return before !== undefined && before !== after ? 'call' : 'text';
}

function around(proto: object, key: string, part: 'value' | 'get' | 'set', hook: (self: unknown) => void) {
  const descriptor = Object.getOwnPropertyDescriptor(proto, key);
  const original = descriptor?.[part];
  if (!descriptor || typeof original !== 'function' || !descriptor.configurable) return;
  Object.defineProperty(proto, key, { ...descriptor, [part]: function (this: unknown, ...args: unknown[]) { hook(this); return original.apply(this, args); } });
}

function owning(proto: object, key: string, owners: WeakMap<object, Node>) {
  const descriptor = Object.getOwnPropertyDescriptor(proto, key);
  const get = descriptor?.get;
  if (!descriptor || !get || !descriptor.configurable) return;
  Object.defineProperty(proto, key, { ...descriptor, get(this: Node) { const value = get.call(this); owners.set(value, this); return value; } });
}

export function install(tick: () => void, probe: boolean) {
  const observations: Observation[] = [];
  const epoch = (time: number) => performance.timeOrigin + time;
  let scope: Scope | undefined, source: WriteSource = 'other', dirtySource: WriteSource = 'frame';
  const run = <T>(label: Label, body: () => T): T => {
    const start = performance.now(), mine: Scope = { kind: label.type, source: label.type === 'frame' ? 'frame' : `apply:${label.record}`, lex: 0, strays: 0, probes: 0, by: {} };
    scope = mine;
    try { return body(); } finally {
      scope = undefined;
      observations.push({ ...label, at: epoch(start), duration: performance.now() - start, lex: mine.lex, strays: mine.strays, probes: mine.probes, by: mine.by });
    }
  };

  let lexTotal = 0;
  const lex = Lexer.prototype.lex;
  Lexer.prototype.lex = function (this: Lexer, ...args: Parameters<Lexer['lex']>) {
    const start = performance.now();
    try { return lex.apply(this, args); } finally { const spent = performance.now() - start; lexTotal += spent; if (scope) scope.lex += spent; }
  };
  instrument(<T>(source: string, body: () => T): T => {
    const start = performance.now(), before = lexTotal, skipped = fallbacks();
    try { return body(); } finally { observations.push({ type: 'markdown', at: epoch(start), words: source.match(/\S+/g)?.length ?? 0, lex: lexTotal - before, fallbacks: fallbacks() - skipped }); }
  });

  const native = window.requestAnimationFrame.bind(window), nativeCancel = window.cancelAnimationFrame.bind(window);
  let last = 0, continuous = false, requested: number | undefined, asked = 0, fired: { at: number; fired: number } | undefined, frameStart = () => {};
  const frame = () => {
    const start = performance.now(), gap = continuous && !document.hidden ? start - last : undefined;
    last = start; continuous = false; requested = undefined; fired = { at: epoch(asked), fired: epoch(start) };
    frameStart();
    run(gap === undefined ? { type: 'frame' } : { type: 'frame', gap }, tick);
  };
  window.requestAnimationFrame = callback => {
    if (callback !== tick) return native(callback);
    if (scope?.kind === 'frame') continuous = true;
    if (requested === undefined) asked = performance.now();
    return requested = native(frame);
  };
  window.cancelAnimationFrame = id => { if (id === requested) { continuous = false; requested = undefined; } nativeCancel(id); };
  document.addEventListener('visibilitychange', () => { continuous = false; });

  const mark = (name: WriteSource) => () => { source = name; queueMicrotask(() => { source = 'other'; }); };
  const events: Record<string, WriteSource> = { keydown: 'key', input: 'key', animationend: 'animationend', pointerdown: 'pointer', click: 'pointer' };
  for (const [type, name] of Object.entries(events)) document.addEventListener(type, mark(name), true);
  window.addEventListener('scroll', mark('scroll'), true);
  document.addEventListener('keydown', event => {
    if (!(event.target instanceof Element && event.target.closest('#prompt'))) return;
    native(() => observations.push({ type: 'key', at: epoch(performance.now()), latency: performance.now() - event.timeStamp }));
  }, true);

  if (probe) {
    const channel = new MessageChannel();
    const reads = strayReads(() => { native(() => channel.port2.postMessage(0)); });
    channel.port1.onmessage = reads.settle;
    frameStart = reads.frameStart;
    const owners = new WeakMap<object, Node>();
    const written = (self: unknown) => {
      const owner = self instanceof Node ? self : typeof self === 'object' && self ? owners.get(self) : undefined;
      if (owner?.isConnected === false) return;
      dirtySource = scope?.source ?? source;
      reads.write(scope?.kind === 'frame');
    };
    const stray = (self: unknown) => {
      if (self instanceof Node && !self.isConnected || !reads.read()) return;
      const probing = self instanceof Element && self.classList.contains('measure');
      if (scope) { scope[probing ? 'probes' : 'strays']++; if (!probing) scope.by[dirtySource] = (scope.by[dirtySource] ?? 0) + 1; }
      else observations.push(probing ? { type: 'probe', at: epoch(performance.now()) } : { type: 'stray', at: epoch(performance.now()), source: dirtySource });
    };
    owning(Element.prototype, 'classList', owners);
    owning(HTMLElement.prototype, 'style', owners);
    for (const key of ['appendChild', 'insertBefore', 'removeChild', 'replaceChild']) around(Node.prototype, key, 'value', written);
    for (const key of ['textContent', 'nodeValue']) around(Node.prototype, key, 'set', written);
    for (const key of ['append', 'prepend', 'replaceChildren', 'remove', 'before', 'after', 'replaceWith', 'setAttribute', 'removeAttribute', 'toggleAttribute', 'insertAdjacentHTML', 'insertAdjacentElement', 'insertAdjacentText']) around(Element.prototype, key, 'value', written);
    for (const key of ['innerHTML', 'outerHTML', 'className', 'id']) around(Element.prototype, key, 'set', written);
    for (const key of ['hidden', 'innerText']) around(HTMLElement.prototype, key, 'set', written);
    around(CharacterData.prototype, 'data', 'set', written);
    for (const key of ['add', 'remove', 'toggle', 'replace']) around(DOMTokenList.prototype, key, 'value', written);
    for (const key of Object.getOwnPropertyNames(CSSStyleDeclaration.prototype)) around(CSSStyleDeclaration.prototype, key, 'set', written);
    for (const key of ['setProperty', 'removeProperty']) around(CSSStyleDeclaration.prototype, key, 'value', written);
    for (const key of ['getBoundingClientRect', 'getClientRects']) around(Element.prototype, key, 'value', stray);
    for (const key of ['clientWidth', 'clientHeight', 'scrollTop', 'scrollHeight', 'scrollWidth', 'offsetHeight']) around(Element.prototype, key, 'get', stray);

    const items = document.getElementById('items');
    const locate = (): Spot | undefined => {
      const dots = items?.lastElementChild?.querySelector('.dots') ?? items?.lastElementChild?.previousElementSibling?.querySelector('.dots');
      return dots ? dots.closest('.run.working') ? 'row' : 'step' : undefined;
    };
    let spot = locate();
    if (items) new MutationObserver(records => {
      const count = records.reduce((sum, record) => sum + [...record.removedNodes].filter(holdsDots).length, 0);
      const now = locate();
      if (count) observations.push({ type: 'dots', at: epoch(performance.now()), phase: dotsPhase(spot, now), count });
      spot = now ?? spot;
    }).observe(items, { childList: true, subtree: true });
  }

  return { within: <T>(name: WriteSource, body: () => T): T => { source = name; try { return body(); } finally { source = 'other'; } }, applying: <T>(record: PageRecord['type'], body: () => T) => run({ type: 'apply', record }, body), request: () => fired, pending: () => observations.length, drain: (max: number) => observations.splice(0, max) };
}
