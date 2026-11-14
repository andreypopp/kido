import { annotations, update } from './annotations.ts';
import { markdown, markdownLine, sliceEnd, type Tail } from './markdown.ts';
import { composer } from './composer.ts';
import { attach } from './attach.ts';
import { closeLightbox, preview, previewKey } from './preview.ts';
import { fetchJSON, scoped } from './http.ts';
import { ATTACHMENT_LIMITS, pathArg } from '../koa-records.ts';
import type { State, WireItem, QueuedPrompt, WireAssistant, Block, Patch, PageRecord, PromptMode, ImageRef, AgentCall, Bash, SessionRow, SessionScope, ThinkingLevel } from '../koa-records.ts';
import type { AgentRef, Relation } from '../records.ts';

type Step = { block: Exclude<Block, { type: 'text' }>;  item: WireAssistant; index: number; key: string; slots: Map<string, Slot> };
type AgentCard = AgentCall | Extract<WireItem, { kind: 'agent' }>;
type JobItem = Extract<WireItem, { kind: 'job' }>;
type JobGroup = { first: JobItem; next: number; items: JobItem[]; shown: number; shownStreams?: number; streams: number; omitted: number; cut: boolean; view: HTMLDivElement; details: HTMLDivElement; footer?: HTMLDivElement; kind: HTMLSpanElement };
type Slot = { type: 'image'; view: HTMLButtonElement } | { type: 'run'; view: HTMLDivElement; signature?: string } | { type: 'agent'; view: HTMLDivElement; rendered?: { card: AgentCard; at: number; key: string } } | { type: 'job'; view: HTMLDivElement; group: JobGroup };
declare global {
  interface Window {
    composer: Pick<ReturnType<typeof composer>, 'text' | 'setText' | 'focus'>;
    koaFocused?: boolean;
    koaMetrics?: { flush(): Promise<void>; readonly after: number; readonly items: WireItem[] };
  }
}

function element(id: string) {
  const result = document.getElementById(id);
  if (!result) throw Error('Missing element: ' + id);
  return result;
}
const node = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string) => {
  const result = document.createElement(tag);
  if (tag === 'button') result.tabIndex = -1;
  if (text !== undefined) result.textContent = text;
  if (className) result.className = className;
  return result;
};
const annotationItems = new Map<number, Map<number, Extract<WireItem, { kind: 'annotations' }>>>();
const items = new Map<number, WireItem>();
const views = new Map<number, { view: HTMLElement; item: WireItem; slots: Map<string, Slot> }>();
const template = document.createElement('template');
const folds = new Map<string, boolean>();
const REVEAL = { cap: .4, wait: 1500, fold: 15, grow: 220, glide: 150, dash: 45, dashFor: 250 };
type Reveal = { at: number; tail?: Tail; measured?: { tail: Tail; width: number; full: number; waiting: number; end?: number } };
type TextMemo = { render: ReturnType<typeof markdown>; view: HTMLElement; blocks: { block: ReturnType<ReturnType<typeof markdown>>[number]; nodes: ChildNode[] }[]; final?: boolean; source?: string; annotationItem?: Extract<WireItem, { kind: 'annotations' }>; assistant: boolean; reveal?: Reveal; grown: number; open: Set<string> };
const texts = new Map<string, TextMemo>();
const revealing = new Set<TextMemo>();
let measurer: HTMLElement | undefined, frame: number | undefined, frameAt = 0, capTimer: number | undefined, scrollMode: 'snap' | 'glide' | 'dash' | 'load' | undefined, glideUntil = 0, dirty = false;
const growing: HTMLElement[] = [];
let state: State = { view: { id: '', path: [] }, agents: [], bash: [], compaction: 'idle', life: { type: 'starting' }, working: false, aborted: false, name: '', levels: [], cwd: '', home: '', statuses: {}, queue: { steering: [], followUp: [] }, dialogs: [] };
let divider: HTMLElement | undefined, wasFocused = paneFocused();
const fresh = new Map<string, HTMLElement>(), counted = new Set<string>(), liveBash = new Map<string, string>();
let epoch = '', after = -1, first: number | undefined, more = false, follow = true, lastScrollTop = 0, delay = 200;
let escaped = false, dialogId: string | undefined;
let submitting = false, editorId: string | undefined, dialogTimer: number | undefined, shownExit: number | undefined, pickerButton: HTMLElement | undefined, shownQueue: string | undefined, shownStatuses: string | undefined;
let historyRequest: { patches: Patch[] } | undefined;
let attachmentRefusalTimer: number | undefined, editorOpening = false;
const draft = attach(element('attachments'), () => refreshComposer(), displayPath, () => !!editor.bash() || !!state.edit, () => {
  if (state.edit) return;
  clearTimeout(attachmentRefusalTimer);
  element('error').textContent = 'a command takes no attachments';
  attachmentRefusalTimer = setTimeout(() => { if (element('error').textContent === 'a command takes no attachments') element('error').textContent = ''; }, 4000);
});
const pendingBash = new Map<string, ReturnType<typeof commandRun>>();
const editor = composer(element('prompt'), {
  drop: draft.drop, paste: draft.paste,
  input(user) { if (user) escaped = false; refreshComposer(); },
  send(mode) { void send(mode); },
  quit() { if (!draft.count && !draft.busy) void fetchJSON('/quit', { sessionId: state.sessionId }); },
  edit() { void openEditor(); },
  takeBack() { if (state.life.type === 'ready' && !editing() && !state.dialogs.length && !submitting) void takeBack().catch(reportError); },
});
window.composer = editor;
let reloading = false;
const composerBlocked = () => reloading || !!state.edit || state.life.type !== 'ready' || state.dialogs.length > 0 || sessionPicker !== 'closed';

if (!window.ko) {
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const theme = () => document.documentElement.toggleAttribute('data-browser-dark', scheme.matches);
  scheme.addEventListener('change', theme);
  theme();
}

const relationWords: Record<Relation, string> = { parent: 'parent', child: 'subagent', sibling: 'peer', descendant: 'subagent', sibling_descendant: 'peer' };
const htmlEscape = (text: string) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const mentionOf = (agent: State['agents'][number]) => agent.target.type === 'view' ? { kind: 'view', id: agent.target.id, title: 'Open @' + agent.name } : { kind: 'pane', id: agent.target.pane, title: 'Focus the pane of @' + agent.name };
function who(ref: AgentRef) {
  const agent = (ref.session ? state.agents.find(agent => agent.target.type === 'view' && agent.target.id === ref.session) : undefined) ?? state.agents.find(agent => agent.name === ref.name);
  if (!agent) { const gone = node('span', '@' + ref.name, 'who gone'); gone.title = 'ended'; return gone; }
  const { kind, id, title } = mentionOf(agent), link = node('a', '@' + ref.name, 'who');
  link.href = '#' + kind + ':' + agent.name; link.title = title; link.setAttribute('data-' + kind, id);
  return link;
}
function linkNames(html: string) {
  if (!state.agents.length) return html;
  const agents = new Map(state.agents.map(agent => [htmlEscape(agent.name), agent]));
  const names = [...agents.keys()].map(name => name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).sort((a, b) => b.length - a.length);
  const mention = new RegExp('(^|[^\\w@])@(' + names.join('|') + ')(?![\\w-])', 'g');
  let hidden = 0;
  return html.split(/(<[^>]*>)/).map(part => {
    if (part.startsWith('<')) { const tag = /^<(\/?)(a|code|pre)\b/.exec(part); if (tag) hidden += tag[1] ? -1 : 1; return part; }
    return hidden > 0 ? part : part.replace(mention, (match, before, name) => {
      const agent = agents.get(name);
      if (!agent) return match;
      const { kind, id, title } = mentionOf(agent);
      return before + '<a class="who" href="#' + kind + ':' + name + '" data-' + kind + '="' + htmlEscape(id) + '" title="' + htmlEscape(title) + '">@' + name + '</a>';
    });
  }).join('');
}
function agentCard(card: AgentCard, at: number, key: string, slots: Map<string, Slot>) {
  const saved = slots.get(key), slot: Extract<Slot, { type: 'agent' }> = saved?.type === 'agent' ? saved : { type: 'agent', view: node('div') };
  slots.set(key, slot);
  if (slot.rendered?.card === card && slot.rendered.at === at) return slot.view;
  slot.rendered = { card, at, key };
  const inbound = card.direction === 'in', ref = inbound ? card.from : card.to;
  let kind = inbound ? card.inbound.form : card.call.tool === 'spawn' ? 'task' : card.call.mode === 'interrupt-and-steer' ? 'interrupt' : card.call.mode;
  let failed = false;
  if (card.direction === 'out' && card.outcome?.ok === false) { failed = true; kind = card.call.tool === 'spawn' ? 'refused' : card.outcome.failure === 'refused' || card.outcome.failure === 'gone' ? card.outcome.failure : card.outcome.message; }
  const view = slot.view; view.className = failed ? 'aline err' : 'aline';
  const header = node('div', undefined, 'hd'), lead = node('span', undefined, 'lead');
  lead.append(kind + ' ' + (inbound ? 'from' : 'to') + ' ', who(ref));
  if (card.direction === 'in' && 'relation' in card.inbound && card.inbound.relation) lead.append(' ', node('span', relationWords[card.inbound.relation], 'rel'));
  const body = card.text.text || (card.direction === 'out' && card.outcome?.ok === false ? card.outcome.message : '');
  header.append(lead, node('span', markdownLine(body), 'tx'), node('time', timestamp(at)));
  const details = prose(undefined, body, true); details.className = 'bd prose';
  view.replaceChildren();
  fold(view, key, header, details);
  return view;
}
function refreshAgentCards() {
  for (const { slots } of views.values()) for (const slot of slots.values()) if (slot.type === 'agent' && slot.rendered) { const { card, at, key } = slot.rendered; slot.rendered = undefined; agentCard(card, at, key, slots); }
}
function jobCard(first: JobItem, slots: Map<string, Slot>): JobGroup {
  const view = node('div', undefined, 'job'), line = node('div', undefined, 'hd'), details = node('div', undefined, 'out');
  const kind = node('span', undefined, 'kind'), time = node('time', timestamp(first.at));
  line.append(node('span', first.job.name, 'nm'), kind, time);
  const group: JobGroup = { first, next: first.seq, items: [], shown: 0, streams: 0, omitted: 0, cut: false, view, details, kind };
  slots.set('job', { type: 'job', view, group });
  fold(view, 'job:' + first.seq, line, details, () => showJob(group));
  return group;
}
function showJob(group: JobGroup) {
  if (!group.footer) { group.footer = node('div', undefined, 'ft'); group.details.append(group.footer); }
  let batches = group.shownStreams ?? 0;
  for (; group.shown < group.items.length; group.shown++) {
    const item = group.items[group.shown];
    if (item.event.type === 'stream') {
      if (batches++) group.details.insertBefore(node('div', '+ ' + timestamp(item.at), 'sep'), group.footer);
      group.details.insertBefore(node('pre', item.event.batch.text), group.footer);
    } else if (!group.streams && item.event.tail.text) group.details.insertBefore(node('pre', item.event.tail.text), group.footer);
  }
  group.shownStreams = batches;
  group.footer.textContent = 'log: ' + group.first.job.log + (group.omitted ? ' · … ' + group.omitted + ' lines omitted' : '') + (group.cut ? ' · long lines truncated' : '');
}
const jobOwners = new Map<number, JobGroup>();
function reconcileJobs(seq: number) {
  const current = items.get(seq); if (current?.kind !== 'job') return;
  const previous = jobOwners.get(seq - 1);
  let group = previous && previous.first.job.id === current.job.id && previous.items.at(-1)?.event.type === 'stream' ? previous : jobOwners.get(seq);
  if (!group) { const owner = views.get(seq); if (!owner) return; group = jobCard(current, owner.slots); owner.view.replaceChildren(group.view); }
  while (group.items.at(-1)?.event.type !== 'ended') {
    const item = items.get(group.next), wrapper = views.get(group.next);
    if (item?.kind !== 'job' || item.job.id !== group.first.job.id || !wrapper) break;
    group.items.push(item); jobOwners.set(group.next, group);
    if (group.next !== group.first.seq) { wrapper.view.replaceChildren(); wrapper.view.hidden = true; }
    group.next++;
    if (item.event.type === 'stream') { group.streams++; group.omitted += item.event.omitted; group.cut ||= item.event.cut || item.event.batch.cut > 0; }
    else { group.view.classList.toggle('err', item.event.end.type === 'exit' ? item.event.end.code !== 0 : item.event.end.type !== 'stopped'); break; }
  }
  const owner = views.get(group.first.seq);
  if (owner && owner.view.firstElementChild !== group.view) owner.view.replaceChildren(group.view);
  group.kind.textContent = group.first.job.service ? 'service' : group.streams ? 'stream' : ''; group.kind.hidden = !group.kind.textContent;
  if (group.view.classList.contains('open')) showJob(group);
}

function previewFile(label: HTMLElement, url: string) {
  label.classList.add('preview-file');
  let press: { x: number; y: number } | undefined;
  label.onmousedown = event => { press = undefined; if (event.button === 0 && previewModifiers(event)) { event.preventDefault(); press = { x: event.clientX, y: event.clientY }; } };
  label.onclick = event => { const start = press; press = undefined; if (start && Math.hypot(event.clientX - start.x, event.clientY - start.y) < 3) { event.preventDefault(); event.stopPropagation(); preview(scoped(url, state.sessionId), label, 'file', composerFocus); } };
}
const quantity = (value: number) => value >= 1000000 ? Number((value / 1000000).toFixed(1)) + 'M' : value >= 1000 ? Number((value / 1000).toFixed(1)) + 'k' : String(value);
function timestamp(at: number, today = new Date(), kind: 'message' | 'session' = 'message') {
  const date = new Date(at);
  const time = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === today.toDateString()) return time;
  return (date.getFullYear() === today.getFullYear() ? '' : date.getFullYear() + ' ') + date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + (kind === 'session' ? '' : ' ' + time);
}

function prose(key: string | undefined, source: string, final: boolean, annotationItem?: Extract<WireItem, { kind: 'annotations' }>, kind: 'assistant' | 'user' | 'plain' = 'plain') {
  let memo = key === undefined ? undefined : texts.get(key);
  if (!memo) {
    memo = { render: markdown(kind === 'user'), view: node('div', undefined, 'msg prose'), blocks: [], assistant: kind === 'assistant', reveal: kind === 'assistant' && !final ? { at: performance.now() } : undefined, grown: 0, open: new Set() };
    if (key !== undefined) texts.set(key, memo);
  }
  if (memo.annotationItem === annotationItem && (memo.final && final || memo.source === source && memo.final === final)) return memo.view;
  if (final) delete memo.source;
  else memo.source = source;
  memo.annotationItem = annotationItem;
  memo.final = final;
  show(memo, source, final);
  return memo.view;
}
function show(memo: TextMemo, source: string, final: boolean) {
  const { reveal } = memo, before = reveal?.tail;
  const annotated = memo.annotationItem ? annotations(source, memo.annotationItem.annotations, editor) : undefined;
  memo.view.querySelector(reveal ? '.typing' : '.caret')?.remove();
  const blocks = memo.render(source, final, annotated?.marks, reveal && (before ?? { start: -1, end: 0 }));
  let first = 0;
  while (first < blocks.length && memo.blocks[first]?.block === blocks[first]) first++;
  for (const saved of memo.blocks.splice(first)) for (const child of saved.nodes) child.remove();
  blocks.slice(first).forEach((block, offset) => {
    const index = first + offset;
    template.innerHTML = linkNames(block.html ?? '');
    annotated?.decorate(template.content);
    const pres = [...template.content.querySelectorAll<HTMLElement>('pre')];
    pres.forEach((pre, ordinal) => {
      if (memo.assistant) foldFence(memo, pre, index + '.' + ordinal);
      const language = pre.querySelector('code')?.className.match(/language-(\S+)/)?.[1];
      if (language) pre.append(node('span', language, 'lang'));
    });
    const nodes = [...template.content.childNodes];
    if (!block.streaming) delete block.html;
    memo.blocks.push({ block, nodes });
    memo.view.append(...nodes);
    const elements = nodes.filter(child => child instanceof HTMLElement);
    if (!reveal || !elements.length) return;
    const { tail } = block, fresh = index >= memo.grown;
    if (fresh) { memo.grown = index + 1; growing.push(...elements); }
    if (fresh || !tail || tail.start !== before?.start || tail.end > (before?.end ?? 0)) startGlide(reveal);
  });
  if (reveal) {
    reveal.tail = blocks.at(-1)?.tail;
    if (reveal.tail && !final) revealing.add(memo); else revealing.delete(memo);
    dirty = true;
    schedule();
    armCap();
  }
  if (!final) {
    if (reveal) {
      const dots = node('span', undefined, 'typing');
      dots.append(node('i'), node('i'), node('i'));
      memo.view.append(dots);
    } else {
      const last = memo.view.lastElementChild;
      (last?.tagName === 'P' ? last : memo.view).append(node('span', undefined, 'caret'));
    }
  }
}
function foldFence(memo: TextMemo, pre: HTMLElement, key: string) {
  const count = (pre.textContent ?? '').replace(/\n$/, '').split('\n').length;
  if (count <= REVEAL.fold || memo.open.has(key)) return;
  const bar = node('button', 'Show ' + (count - REVEAL.fold) + ' more lines', 'more');
  pre.classList.add('folded');
  pre.style.setProperty('--fold', String(REVEAL.fold));
  bar.onclick = () => { memo.open.add(key); pre.classList.remove('folded'); bar.remove(); };
  pre.after(bar);
}
function startGlide(reveal: Reveal) {
  reveal.at = performance.now();
  glideUntil = reveal.at + REVEAL.grow;
  scrollMode = 'glide';
}
function schedule(urgent = false) {
  if (frame !== undefined || document.hidden && !urgent || !dirty && !fitPending.size && !fitAll && !growing.length && !scrollMode) return;
  frameAt = performance.now();
  frame = requestAnimationFrame(tick);
}
function armCap() {
  if (capTimer !== undefined || document.hidden) return;
  const now = performance.now(), next = Math.min(...[...revealing].flatMap(({ reveal }) => reveal && reveal.at + REVEAL.wait > now ? [reveal.at + REVEAL.wait] : []));
  if (next < Infinity) capTimer = setTimeout(() => { capTimer = undefined; dirty = true; schedule(); }, next - now);
}
function stopFrames() {
  if (frame !== undefined) cancelAnimationFrame(frame);
  clearTimeout(capTimer);
  frame = capTimer = undefined;
}
function tick() {
  frame = undefined;
  const now = performance.now(), dt = Math.min(50, now - frameAt);
  if (dirty) { dirty = false; for (const memo of revealing) revealStep(memo, now); }
  if (fitPending.size || fitAll) measureNotices();
  const targets = growing.splice(0), heights = targets.map(target => target.getBoundingClientRect().height);
  targets.forEach((target, index) => {
    if (heights[index]) target.style.setProperty('--h', heights[index] + 'px');
    target.style.animationDuration = REVEAL.grow + 'ms';
    target.classList.add('grow');
    target.addEventListener('animationend', () => target.classList.remove('grow'), { once: true });
  });
  const scroll = element('scroll'), gap = scroll.scrollHeight - scroll.clientHeight - scroll.scrollTop;
  if (scrollMode && follow && (scrollMode === 'dash' || scrollMode === 'load' || paneFocused())) {
    scroll.scrollTop = scrollMode === 'snap' || scrollMode === 'load' ? scroll.scrollHeight : scroll.scrollTop + gap * (1 - Math.exp(-dt / (scrollMode === 'dash' ? REVEAL.dash : REVEAL.glide)));
    lastScrollTop = scroll.scrollTop;
    if (scrollMode === 'snap' || scrollMode === 'load' || gap < .5 && now >= glideUntil) scrollMode = undefined;
  } else scrollMode = undefined;
  sync();
  schedule();
  armCap();
}
function paneFocused() { return window.koaFocused ?? (document.hasFocus() && document.visibilityState === 'visible'); }
function clearDivider() { divider?.remove(); divider = undefined; fresh.clear(); }
function sync() {
  const scroll = element('scroll'), latest = element('latest'), gap = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight;
  if (gap < 60 && paneFocused()) { clearDivider(); follow = true; }
  const dockTop = fresh.size ? element('dock').getBoundingClientRect().top : 0, below = [...fresh.values()].filter(view => view.getBoundingClientRect().top >= dockTop).length, label = below ? '↓ ' + below + ' new' : '↓ Latest';
  if (latest.textContent !== label) latest.textContent = label;
  latest.classList.toggle('show', gap >= 60);
  wasFocused = paneFocused();
}
function refocus() {
  const scroll = element('scroll');
  if (!wasFocused && scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight >= 60) follow = false;
  sync();
}
function arrive(key: string, view: HTMLElement | undefined) {
  if (!view) return;
  if (counted.has(key)) { if (fresh.has(key)) fresh.set(key, view); return; }
  counted.add(key);
  if (follow && paneFocused()) return;
  if (!divider) { divider = node('div', undefined, 'newmsgs'); divider.append(node('span', 'new messages')); element('items').insertBefore(divider, view); }
  fresh.set(key, view); follow = false; sync();
}
function toLatest() {
  follow = true; glideUntil = performance.now() + REVEAL.dashFor;
  scrollMode = matchMedia('(prefers-reduced-motion: reduce)').matches ? 'snap' : 'dash';
  schedule(true);
}
function revealStep(memo: TextMemo, now: number) {
  const { reveal, view, source } = memo, tail = reveal?.tail, width = view.clientWidth;
  if (!reveal || !tail || source === undefined || !width) return;
  if (!measurer) { measurer = node('div', undefined, 'prose measure'); document.body.append(measurer); }
  const host = measurer;
  const measure = (end: number) => { host.style.width = width + 'px'; host.innerHTML = tail.html(end); return host.getBoundingClientRect().height; };
  let measured = reveal.measured;
  if (measured?.tail !== tail || measured.width !== width) {
    const full = measure(tail.token.raw.length);
    measured = reveal.measured = { tail, width, full, waiting: full - measure(tail.end) };
  }
  const { full } = measured;
  if (measured.end === undefined && (measured.waiting >= REVEAL.cap * element('scroll').clientHeight || now - reveal.at >= REVEAL.wait && tail.end < tail.token.raw.length)) measured.end = sliceEnd(tail.token, end => end >= tail.token.raw.length ? full : measure(end));
  if (measured.end === undefined || measured.end <= tail.end) return;
  reveal.tail = { ...tail, end: measured.end };
  show(memo, source, false);
}

function thumbnails(refs: ImageRef[], slots: Map<string, Slot>, name?: string) {
  const view = node('div', undefined, 'thumbs');
  return { view, load() {
    if (view.childNodes.length) return;
    for (const ref of refs) {
      const key = 'image:' + ref.id;
      const saved = slots.get(key);
      const thumb = saved?.type === 'image' ? saved.view : node('button', undefined, 'thumb');
      if (!saved || saved.type !== 'image') { thumb.type = 'button'; thumb.append(node('img'), node('span', undefined, 'sz')); slots.set(key, { type: 'image', view: thumb }); }
      const image = thumb.firstElementChild, label = thumb.children[1];
      if (!(image instanceof HTMLImageElement) || !(label instanceof HTMLElement)) throw Error('Invalid image slot');
      const base = '/images/' + encodeURIComponent(ref.id) + '?e=' + encodeURIComponent(epoch) + '&r=' + ref.revision, src = scoped(base, state.sessionId);
      thumb.setAttribute('data-base', base);
      if (image.getAttribute('src') !== src) {
        thumb.classList.remove('gone'); thumb.removeAttribute('role'); thumb.disabled = false;
        while (thumb.children.length > 2) thumb.lastElementChild?.remove();
        const size = ref.width && ref.height ? ref.width + '×' + ref.height : '';
        label.textContent = size; label.hidden = !size;
        thumb.setAttribute('aria-label', 'Preview image' + (size ? ' ' + size : ''));
        image.alt = ''; image.hidden = false;
        if (ref.width && ref.height) { image.width = ref.width; image.height = ref.height; }
        else { image.removeAttribute('width'); image.removeAttribute('height'); }
        const target = thumb;
        image.onload = followBottom;
        image.onerror = () => {
          target.classList.add('gone'); target.setAttribute('role', 'img'); target.setAttribute('aria-label', 'Image unavailable'); target.disabled = true;
          image.hidden = true; target.append(node('span', 'Image unavailable')); followBottom();
        };
        image.setAttribute('src', src);
      }
      const target = thumb;
      target.onclick = () => { if (!target.disabled) preview(scoped(base, state.sessionId), target, 'image', composerFocus, name); };
      view.append(thumb);
    }
  } };
}

function displayPath(value: string) { return state.home && (value === state.home || value.startsWith(state.home + '/')) ? '~' + value.slice(state.home.length) : value; }
const duration = (ms: number | undefined, separator = '') => ms === undefined ? '' : ms < 100 && !separator ? Math.round(ms) + 'ms' : ms >= 60000 ? Math.floor(ms / 60000) + 'm' + separator + String(Math.floor(ms / 1000) % 60).padStart(2, '0') + 's' : Number((ms / 1000).toFixed(1)) + 's';
function args(block: Extract<Block, { type: 'tool' }>): Record<string, unknown> {
  try { const value = JSON.parse(block.args.text); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  catch { return {}; }
}
function stepInfo(step: Step & { args: Record<string, unknown> }) {
  const { block, item } = step;
  if (block.type === 'thinking') {
    const first = block.text.indexOf('\n');
    const second = first < 0 ? -1 : block.text.indexOf('\n', first + 1);
    return { label: 'thinking', labelClass: 'name', detail: block.redacted ? 'redacted' : markdownLine(second < 0 ? block.text : block.text.slice(0, second)), kind: 'thinking' };
  }
  const values = step.args;
  const kind = block.name;
  if (block.name === 'async_bash') return { label: block.job?.name ?? (typeof values.name === 'string' ? values.name : 'async_bash'), labelClass: 'path', detail: '', kind };
  const first = Object.values(values)[0];
  const labelClass = block.name === 'bash' ? 'cmd' : ['read', 'edit', 'write'].includes(block.name) ? 'path' : '';
  const label = labelClass === 'cmd' ? values.command : labelClass === 'path' ? values.path : block.name + (first === undefined ? '' : ' ' + (typeof first === 'string' ? first : JSON.stringify(first)));
  let detail = '';
  if (block.name === 'read' && 'result' in block.state && block.state.result) {
    const image = block.state.result.images[0];
    detail = image ? image.mimeType.replace(/^image\//, '') + (image.width && image.height ? ' · ' + image.width + '×' + image.height : '') : block.state.result.text.split('\n').length + ' lines';
  }
  let edit;
  if (block.name === 'edit' && typeof values.oldText === 'string' && typeof values.newText === 'string') {
    const old = values.oldText.split('\n'), next = values.newText.split('\n');
    let prefix = 0, suffix = 0;
    while (prefix < old.length && prefix < next.length && old[prefix] === next[prefix]) prefix++;
    while (suffix < old.length - prefix && suffix < next.length - prefix && old[old.length - 1 - suffix] === next[next.length - 1 - suffix]) suffix++;
    edit = { old, next, prefix, suffix };
    detail = '+' + (next.length - prefix - suffix) + ' −' + (old.length - prefix - suffix);
  }
  return { edit, labelClass, label: typeof label === 'string' ? label : label === undefined ? block.name + (block.state.type === 'pending' && !item.final ? '' : ' ' + block.args.text) : JSON.stringify(label), detail, kind, aborted: item.stop === 'aborted' && block.state.type !== 'done' };
}
function fold(view: HTMLElement, key: string, line: HTMLElement, details: HTMLElement, show?: () => void, className = 'open') {
  view.classList.toggle(className, folds.get(key) === true);
  line.setAttribute('role', 'button'); line.tabIndex = -1;
  line.setAttribute('aria-expanded', String(folds.get(key) === true));
  const toggle = () => { const open = !view.classList.contains(className); folds.set(key, open); view.classList.toggle(className, open); line.setAttribute('aria-expanded', String(open)); if (open) show?.(); };
  line.onclick = event => { if (!(event?.target instanceof Element && event.target.closest('a'))) toggle(); };
  line.onkeydown = event => { if (!(event.target instanceof Element && event.target.closest('a')) && !event.metaKey && !event.ctrlKey && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); toggle(); } };
  if (view !== line) view.append(line);
  view.append(details);
  if (folds.get(key)) show?.();
}
function run(input: Step[]) {
  const steps = input.map(step => { const value = { ...step, args: step.block.type === 'tool' ? args(step.block) : {}, file: pathArg(step.block) }; return { ...value, info: stepInfo(value) }; });
  const view = node('div', undefined, 'run');
  const line = node('div', undefined, 'line');
  const summary = node('span', undefined, 'sum');
  const failed = steps.filter(step => step.block.type === 'tool' && step.block.state.type === 'done' && step.block.state.error);
  const aborted = steps.some(step => step.item.stop === 'aborted' && step.item.blocks.slice(step.index + 1).every(block => block.type !== 'text' || !block.text));
  const active = steps.find(step => step.block.type === 'tool' && step.block.state.type === 'running') ?? steps.findLast(step => step.block.type === 'tool' ? step.block.state.type === 'pending' && !step.item.final : !step.item.final && step.block.ended === undefined);
  if (aborted) summary.append('aborted, you pressed Escape');
  else if (active) summary.append(node('span', active.info.kind, 'names'), node('span', undefined, 'spin'));
  else {
    const counts = new Map<string, number>();
    for (const step of steps) { const kind = step.info.kind; counts.set(kind, (counts.get(kind) || 0) + 1); }
    const names = node('span', undefined, 'names');
    for (const [kind, count] of counts) {
      if (names.childNodes.length) names.append(', ');
      names.append(node('span', kind === 'thinking' || count === 1 ? kind : kind + ' x' + count, failed.some(step => step.info.kind === kind) ? 'err' : ''));
    }
    summary.append(names);
  }
  const timed = steps.filter(step => step.block.started !== undefined);
  const started = steps[0].block.started ?? steps[0].item.at;
  const ended = aborted ? steps.at(-1)?.item.ended : timed.at(-1)?.block.ended ?? (active ? Date.now() : undefined);
  line.append(summary, node('span', duration(started === undefined || ended === undefined ? undefined : ended - started), 'time'));
  const children = node('div', undefined, 'steps');
  for (const step of steps) {
    const { block, key, info } = step;
    const error = block.type === 'tool' && block.state.type === 'done' && block.state.error;
    const child = node('div', undefined, 'step');
    const row = node('div', undefined, 'line');
    const sum = node('span', undefined, 'sum');
    if (block.type === 'tool' && (block.name === 'bash' || info.labelClass === 'path')) sum.append(node('span', block.name, error ? 'name err' : 'name'), ' ');
    const label = node('span', info.label, error && block.type === 'tool' && block.name !== 'bash' && info.labelClass !== 'path' ? 'err' : info.labelClass);
    sum.append(label, ' ');
    const counts = info.detail.match(/^\+(\d+) −(\d+)$/);
    if (counts) sum.append(node('span', '+' + counts[1], 'added'), ' ', node('span', '−' + counts[2], 'err'));
    else sum.append(node('span', info.detail, 'delta'));
    const result = info.aborted ? 'aborted' : '';
    const outcome = node('span', undefined, 'outcome');
    const ended = block.ended ?? (info.aborted ? step.item.ended : !step.item.final ? Date.now() : undefined);
    outcome.append(node('span', result, error ? 'err' : ''), node('span', (result ? ' ' : '') + duration((block.type === 'tool' ? block.durationMs : undefined) ?? (block.started !== undefined && ended !== undefined ? ended - block.started : undefined)), error ? 'time err' : 'time'));
    row.append(node('span', '›', 'chev'), sum, outcome);
    const detail = node('div', undefined, 'detail');
    const refs = block.type === 'tool' && 'result' in block.state ? block.state.result?.images : undefined;
    const images = refs?.length ? thumbnails(refs, step.slots, step.file) : undefined;
    if (block.type === 'thinking' && block.redacted) detail.append(node('div', block.text || 'Redacted thinking', 'think redacted'));
    else if (block.type === 'tool') {
      if (info.edit) {
        const diff = node('div', undefined, 'diff'); diff.append(node('div', info.label, 'h'));
        const { old, next, prefix, suffix } = info.edit;
        const line = (text: string, mark: string, kind: string) => { const row = node('div', undefined, 'l ' + kind); row.append(node('span', mark, 'g'), text); diff.append(row); };
        old.slice(0, prefix).forEach(text => line(text, '', 'ctx'));
        old.slice(prefix, old.length - suffix).forEach(text => line(text, '−', 'del'));
        next.slice(prefix, next.length - suffix).forEach(text => line(text, '+', 'add'));
        if (suffix) old.slice(-suffix).forEach(text => line(text, '', 'ctx'));
        detail.append(diff);
      } else {
        if (block.name === 'async_bash') { if (typeof step.args.command === 'string') detail.append(node('pre', step.args.command)); if (block.job) detail.append(node('div', 'log: ' + block.job.log, 'delta')); }
        else if (block.name === 'bash') detail.append(node('div', 'cwd ' + displayPath(state.cwd), 'kv'));
        if ((block.name !== 'async_bash' || !block.job) && 'result' in block.state && block.state.result?.text) detail.append(node(images && block.name === 'read' ? 'div' : 'pre', block.state.result.text, images && block.name === 'read' ? 'note' : ''));
      }
      if ('result' in block.state && block.state.result?.cut) detail.append(node('div', block.state.result.cut + ' bytes omitted', 'delta'));
    }
    if (images) { if (block.type === 'tool' && block.name === 'read') images.view.classList.add('large'); detail.append(images.view); }
    fold(child, key, row, detail, block.type === 'thinking' && !block.redacted ? () => {
      if (!block.text) return;
      const thinking = prose(key, block.text, step.item.final);
      thinking.className = 'think prose';
      detail.replaceChildren(thinking);
    } : images?.load);
    if (step.file) {
      previewFile(label, '/steps/' + step.item.seq + '/' + step.index + '/file');
    }
    children.append(child);
  }
  fold(view, 'run:' + steps[0].key, line, children);
  return view;
}

function reconcileRuns(seq: number) {
  if (items.get(seq)?.kind !== 'assistant') return;
  let start = seq, end = seq;
  while (items.get(start - 1)?.kind === 'assistant') start--;
  while (items.get(end + 1)?.kind === 'assistant') end++;
  let steps: Step[] = [];
  const flush = () => {
    if (!steps.length) return;
    const owner = views.get(steps[0].item.seq)?.slots.get(steps[0].key);
    if (owner?.type === 'run') {
      const signature = JSON.stringify(steps.map(step => [step.block, step.item.final, step.item.stop, step.item.ended]));
      if (owner.signature !== signature) { owner.view.replaceChildren(run(steps)); owner.signature = signature; }
      for (const step of steps.slice(1)) {
        const slot = views.get(step.item.seq)?.slots.get(step.key);
        if (slot?.type === 'run' && slot !== owner) { slot.view.replaceChildren(); slot.signature = undefined; }
      }
    }
    steps = [];
  };
  for (let current = start; current <= end; current++) {
    const item = items.get(current), owner = views.get(current);
    if (item?.kind !== 'assistant' || !owner) continue;
    item.blocks.forEach((block, index) => {
      if (block.type === 'text' || block.type === 'tool' && block.agent) flush();
      else steps.push({ block, item, index, key: item.seq + ':' + index, slots: owner.slots });
    });
    if (item.error) flush();
  }
  flush();
}
type NoticeContent = { type: 'text'; text: string } | { type: 'markdown'; text: string } | { type: 'details'; text: string; body: HTMLElement } | { type: 'lead'; lead: string; preview: string; body: HTMLElement } | { type: 'inline'; head: () => HTMLElement[] };
type NoticeRow = { key: string; at: number; level?: 'warning' | 'error'; content: NoticeContent };
const fitPending = new Set<HTMLElement>();
let fitAll = false, fitWidth = 0;
function noticeRow({ key, at, level, content }: NoticeRow) {
  const row = node('div', undefined, level ? 'nrow ' + level : 'nrow'), line = node('div', undefined, 'hd'), tx = node('span', undefined, 'tx'), details = node('div', undefined, 'bd');
  let more = false;
  if (content.type === 'text' || content.type === 'markdown') {
    const [head, ...rest] = content.text.split(/\r\n?|\n/), body = rest.length ? rest.join('\n') : content.text;
    more = rest.length > 0;
    if (content.type === 'text') { tx.textContent = head; details.textContent = body; }
    else { tx.textContent = markdownLine(head); details.className = 'bd prose'; details.append(prose(undefined, body, true)); }
  } else if (content.type === 'details') { more = true; tx.textContent = content.text; details.append(content.body); }
  else if (content.type === 'lead') { more = true; tx.append(node('span', content.lead, 'lead'), node('span', content.preview, 'prev')); details.append(content.body); }
  else { tx.append(...content.head()); details.append(...content.head()); }
  line.append(tx, node('time', timestamp(at)));
  if (more) row.classList.add('more'); else { row.dataset.fit = ''; fitPending.add(row); }
  fold(row, key, line, details);
  return row;
}
function measureNotices() {
  const rows = fitAll ? [...views.values()].flatMap(({ view }) => Array.from(view.children).filter((row): row is HTMLElement => row instanceof HTMLElement && row.dataset.fit !== undefined)) : [...fitPending];
  const measured = rows.flatMap(row => { const tx = row.firstElementChild?.firstElementChild; return tx instanceof HTMLElement && tx.clientWidth ? [[row, tx.scrollWidth > tx.clientWidth] as const] : []; });
  for (const [row, overflows] of measured) { row.classList.toggle('more', overflows); fitPending.delete(row); }
  fitAll = false;
}
function paragraphs(text: string) {
  const body = node('div');
  for (const paragraph of text.split(/\n\s*\n/)) body.append(node('p', paragraph.trim()));
  return body;
}
function commandNotice(item: Extract<WireItem, { kind: 'command' }>): NoticeRow {
  const key = 'notice:' + item.seq, at = item.at, result = item.result;
  switch (result.type) {
    case 'copy': return { key, at, content: { type: 'text', text: 'copied the last reply · ' + quantity(result.characters) + ' characters' } };
    case 'export': {
      const head = () => { const path = node('span', result.path, 'path preview-file'); previewFile(path, '/steps/' + item.seq + '/0/file'); return [node('span', 'exported '), path]; };
      return { key, at, content: { type: 'inline', head } };
    }
    case 'session': {
      const stats = result.stats, grid = node('div', undefined, 'kv');
      for (const [name, value, mono] of [['name', result.name, false], ['id', stats.sessionId, true], ['file', stats.sessionFile ?? '—', true], ['model', result.model ? result.model.id + (result.thinking ? ' · thinking ' + result.thinking : '') : '—', false], ['messages', stats.totalMessages + ' · ' + stats.userMessages + ' user · ' + stats.assistantMessages + ' assistant · ' + stats.toolResults + ' tool', false], ['tokens', quantity(stats.tokens.input) + ' in · ' + quantity(stats.tokens.output) + ' out · ' + quantity(stats.tokens.cacheRead) + ' cache read · ' + quantity(stats.tokens.cacheWrite) + ' cache write', false], ['cost', '$' + stats.cost.toFixed(2), false], ['context', stats.contextUsage?.tokens === null || !stats.contextUsage ? '—' : quantity(stats.contextUsage.tokens) + ' / ' + quantity(stats.contextUsage.contextWindow) + (stats.contextUsage.percent === null ? '' : ' · ' + Math.round(stats.contextUsage.percent) + '%'), false]] as const) grid.append(node('b', name), node('span', value, mono ? 'path' : ''));
      return { key, at, content: { type: 'details', text: result.name + ' · ' + stats.totalMessages + ' messages · $' + stats.cost.toFixed(2), body: grid } };
    }
    case 'compaction': switch (result.state.type) {
      case 'running': return { key, at, content: { type: 'inline', head: () => [node('span', 'compacting'), node('span', undefined, 'spin')] } };
      case 'cancelled': return { key, at, content: { type: 'text', text: 'compaction cancelled' } };
      case 'failed': return { key, at, level: 'error', content: { type: 'text', text: 'compaction · ' + result.state.message } };
      case 'done': return { key, at, content: { type: 'details', text: 'compacted · ' + quantity(result.state.before) + ' → ' + (result.state.after === undefined ? '—' : quantity(result.state.after)) + ' tokens', body: paragraphs(result.state.summary) } };
    }
  }
}
function put(item: WireItem) {
  items.set(item.seq, item);
  first = first === undefined ? item.seq : Math.min(first, item.seq);
  const previous = views.get(item.seq);
  if (previous?.item === item) return previous.view;
  const view = previous?.view ?? node('div');
  view.dataset.seq = String(item.seq);
  const refs = item.kind === 'user' ? item.images : item.kind === 'assistant' ? item.blocks.flatMap(block => block.type === 'tool' && 'result' in block.state ? block.state.result?.images ?? [] : []) : [];
  const ids = new Set(refs.map(ref => 'image:' + ref.id));
  const children: HTMLElement[] = [], slots = new Map([...previous?.slots ?? []].filter(([key]) => ids.has(key)));
  let steps: Step[] = [];
  const flush = () => {
    if (steps.length) {
      const key = steps[0].key, saved = previous?.slots.get(key);
      const slot: Slot = saved?.type === 'run' ? saved : { type: 'run', view: node('div') };
      slots.set(key, slot); children.push(slot.view);
    }
    steps = [];
  };
  if (item.kind === 'assistant') {
    view.className = 'assistant';
    item.blocks.forEach((block, index) => {
      const key = item.seq + ':' + index;
      if (block.type === 'text') { flush(); if (block.text) children.push(prose(key, block.text, item.final || index < item.blocks.length - 1, annotationItems.get(item.seq)?.get(index), 'assistant')); }
      else if (block.type === 'tool' && block.agent) { flush(); const saved = previous?.slots.get('agent:' + key); if (saved?.type === 'agent') slots.set('agent:' + key, saved); children.push(agentCard(block.agent, block.started ?? item.at, 'agent:' + key, slots)); }
      else steps.push({ block, item, key, index, slots });
    });
    flush();
    if (item.error) children.push(noticeRow({ key: item.seq + ':error', at: item.at, level: 'error', content: { type: 'text', text: item.error } }));
  } else {
    view.className = 'msg ' + item.kind;
    if (item.kind === 'user') {
      const time = node('time', timestamp(item.at)); time.dateTime = new Date(item.at).toISOString();
      const text = node('div', undefined, 't'); text.append(prose(item.seq + ':user', item.text, true, undefined, 'user'));
      if (item.images.length) { const images = thumbnails(item.images, slots); images.load(); text.append(images.view); }
      const paths = item.attachments.filter(file => file.kind === 'file').map(file => file.path);
      if (paths.length) text.append(node('div', paths.join('\n'), 'paths'));
      children.push(time, text);
    } else if (item.kind === 'notify') { view.className = ''; children.push(noticeRow({ key: 'notice:' + item.seq, at: item.at, level: item.level === 'info' ? undefined : item.level, content: { type: 'text', text: item.text.text } })); }
    else if (item.kind === 'command') { view.className = ''; children.push(noticeRow(commandNotice(item))); }
    else if (item.kind === 'agent') { view.className = ''; children.push(agentCard(item, item.at, 'agent:' + item.seq, slots)); }
    else if (item.kind === 'annotations') { view.hidden = true; }
    else if (item.kind === 'job') { view.className = ''; const saved = previous?.slots.get('job'); if (saved?.type === 'job') slots.set('job', saved); }
    else if (item.kind === 'notice') { view.className = ''; children.push(noticeRow({ key: 'notice:' + item.seq, at: item.at, content: { type: 'markdown', text: item.text } })); }
    else if (item.kind === 'bash') { view.className = ''; children.push(commandRun(item, 'bash:' + item.seq).view); }
    else { view.className = ''; children.push(noticeRow({ key: 'notice:' + item.seq, at: item.at, content: { type: 'lead', lead: item.source === 'branch' ? 'branch' : 'compacted', preview: ' · ' + item.text.split('\n')[0], body: paragraphs(item.text) } })); }
  }
  children.forEach((child, index) => { if (view.childNodes[index] !== child) view.insertBefore(child, view.childNodes[index] ?? null); });
  while (view.childNodes.length > children.length) view.lastChild?.remove();
  views.set(item.seq, { view, item, slots });
  if (!previous) {
    const next = [...views.keys()].filter(seq => seq > item.seq).sort((a, b) => a - b)[0];
    element('items').insertBefore(view, views.get(next)?.view ?? null);
  }
  if (slots.size || previous?.slots.size || !previous) reconcileRuns(item.seq);
  if (item.kind === 'annotations') {
    let blocks = annotationItems.get(item.reply.seq);
    if (!blocks) { blocks = new Map(); annotationItems.set(item.reply.seq, blocks); }
    const previous = blocks.get(item.reply.block);
    if (!previous || previous.seq < item.seq) {
      blocks.set(item.reply.block, item);
      const reply = items.get(item.reply.seq);
      if (reply) { put({ ...reply }); update(editor.text()); }
    }
  }
  if (item.kind === 'job') reconcileJobs(item.seq);
  element('older').hidden = !more;
  after = Math.max(after, first - 1);
  while (items.get(after + 1)?.final) after++;
  return view;
}

function commandRun(value: Extract<WireItem, { kind: 'bash' }> | Bash, key: string) {
  const view = node('div', undefined, 'cmdrun'), line = node('div', undefined, 'line');
  const bang = node('span'), command = node('span'), meta = node('span', undefined, 'meta'), outcome = node('span'), time = node('span');
  meta.append(outcome, time); line.append(bang, command, meta);
  const output = node('div', undefined, 'out'), pre = node('pre'), footer = node('div', undefined, 'ft');
  output.append(pre, footer);
  if ('phase' in value && value.phase !== 'completed' && !folds.has(key)) folds.set(key, true);
  fold(view, key, line, output);
  const text = (target: HTMLElement, next: string) => { if (target.textContent !== next) target.textContent = next; };
  const update = (value: Extract<WireItem, { kind: 'bash' }> | Bash) => {
    const live = 'phase' in value && value.phase !== 'completed';
    const result = 'phase' in value ? value.phase === 'completed' ? value.result : undefined : value.result;
    const failed = result?.exit !== undefined && result.exit !== 0;
    text(bang, live ? '' : value.excludeFromContext ? '!!' : '!');
    const marker = live ? 'spin' : 'bang' + (value.excludeFromContext ? ' quiet' : '');
    if (bang.className !== marker) bang.className = marker;
    const title = value.excludeFromContext ? "not in the model's context" : '';
    if (bang.title !== title) bang.title = title;
    text(command, value.command);
    const commandClass = 'cmd' + (failed ? ' err' : '');
    if (command.className !== commandClass) command.className = commandClass;
    text(outcome, result?.cancelled ? 'cancelled' : failed ? 'exit ' + result?.exit : '');
    const outcomeClass = 'ex' + (failed && !result?.cancelled ? ' err' : '');
    if (outcome.className !== outcomeClass) outcome.className = outcomeClass;
    outcome.hidden = !outcome.textContent;
    text(time, 'phase' in value ? duration((value.phase === 'completed' ? value.ended : Date.now()) - value.started) : '');
    text(pre, result?.output.text ?? ('output' in value ? value.output.text : '')); pre.classList.toggle('live', live);
    footer.hidden = !(result?.truncated || result?.output.cut);
    text(footer, result?.fullOutputPath ? '… full output: ' + result.fullOutputPath : '… output truncated');
  };
  update(value);
  return { view, update };
}
function refreshBash() {
  const ids = new Set(state.bash.map(item => item.id));
  for (const [id, card] of pendingBash) if (!ids.has(id)) { card.view.remove(); pendingBash.delete(id); }
  for (const item of state.bash) {
    let card = pendingBash.get(item.id);
    if (!card) { card = commandRun(item, 'live-bash:' + item.id); pendingBash.set(item.id, card); }
    else card.update(item);
    if (!card.view.isConnected) element('items').append(card.view);
    if ((item.phase === 'completed' ? item.result.output : item.output).text) { liveBash.set(item.command, 'bash:' + item.id); arrive('bash:' + item.id, card.view); }
  }
}
function refreshComposer() {
  update(editor.text());
  const blocked = composerBlocked(), working = state.working && !blocked;
  const available = element('field').inert && !blocked;
  element('field').inert = blocked;
  element('field').classList.toggle('editing', !!state.edit);
  composerFocus();
  if (available) focusComposer();
  element('field').classList.toggle('drop', draft.hover && !state.edit);
  const running = state.bash.some(item => item.phase !== 'completed') && !working && editor.empty();
  editor.running(running);
  editor.readonly(editing());
  if (!editor.bash() && element('error').textContent === 'a command takes no attachments') { clearTimeout(attachmentRefusalTimer); element('error').textContent = ''; }
  editor.placeholder(state.life.type === 'switching' ? 'loading…' : running ? 'running… ⎋ cancels' : draft.hover && !state.edit ? 'Drop to attach' : hasFailed() ? 'koa could not start the agent' : working && state.compaction !== 'running' ? 'Steer ' + viewedName() + '…' : 'Message ' + viewedName() + '…');
  status();
}
function status() {
  const waiting = state.dialogs.length > 0, label = element('status');
  const bang = editor.bash(), running = state.bash.find(item => item.phase !== 'completed');
  label.classList.toggle('err', !!bang && draft.count > 0);
  const word = hasFailed() ? 'failed' : waiting ? 'waiting' : state.edit ? 'Editing…' : state.life.type === 'starting' ? 'starting' : state.life.type === 'switching' ? 'loading' : state.working ? state.compaction === 'running' ? 'compacting' : 'working' : running ? 'running' : bang ? bang.excludeFromContext ? 'run, quiet' : 'run' : state.aborted ? 'aborted' : 'idle';
  const completing = editor.completionStatus();
  label.title = word === 'Editing…' && state.edit ? `Editing in ${state.edit.editor}` : bang && draft.count ? 'remove the attachments' : '';
  label.textContent = bang && completing === 'pending' ? 'completing…' : bang && completing === 'none' ? 'no completions' : word;
  label.classList.toggle('completion-hint', !!bang && completing !== 'idle');
  if (state.life.type === 'ready' && (state.working || running) && !waiting) {
    const ms = Math.max(0, Math.floor((Date.now() - (state.working ? state.since ?? Date.now() : running?.started ?? Date.now())) / 1000)) * 1000;
    label.append(node('span', ' ' + duration(ms, ' '), 'k'));
  }
  element('dot').className = 'dot' + (hasFailed() ? ' off' : waiting ? ' wait' : state.life.type === 'ready' && (state.working || running) ? ' on' : '');
  if (bang && completing === 'pending') element('dot').className = 'spin completion-spin';
  element('model-name').textContent = state.model?.id ?? '';
  element('thinking').textContent = state.thinking ? '· ' + state.thinking : '';
  const context = state.context, percent = context?.percent;
  element('tokens').textContent = context ? (context.tokens === null ? '—' : Math.round(context.tokens / 1000) + 'k') + ' / ' + Math.round(context.window / 1000) + 'k' : '';
  element('percent').textContent = percent === null || percent === undefined ? '—' : Math.round(percent) + '%';
  element('context-bar').classList.toggle('high', percent !== null && percent !== undefined && percent > 75);
  const bar = element('context-bar').firstElementChild;
  if (bar instanceof HTMLElement) bar.style.width = Math.min(100, Math.max(0, percent ?? 0)) + '%';
  const path = displayPath(state.cwd).replace(/\/$/, ''), slash = path.lastIndexOf('/');
  element('cwd').replaceChildren(node('span', path.slice(0, slash + 1), 'lead k'), node('span', path.slice(slash + 1)));
}
function button(label: string, key?: string, primary = false) {
  const result = node('button', label, 'btn' + (primary ? ' primary' : ''));
  result.type = 'button';
  if (key) result.append(node('kbd', key));
  return result;
}
function cursor(rows: HTMLElement[], onMark: (row: HTMLElement, chosen: boolean) => void) {
  let index = 0;
  const mark = (value: number) => { index = Math.max(0, Math.min(rows.length - 1, value)); rows.forEach((row, i) => { row.classList.toggle('cur', i === index); onMark(row, i === index); }); rows[index]?.scrollIntoView({ block: 'nearest' }); };
  return { mark, get index() { return index; } };
}
function dialogs() {
  composerFocus();
  const request = state.dialogs[0], host = element('dialogs');
  host.querySelector('.queued-next')?.remove();
  if (state.dialogs.length > 1) {
    const next = node('div', '+' + (state.dialogs.length - 1) + ' queued ', 'queued-next');
    next.append(node('b', '·'), node('b', state.dialogs[1].title)); host.append(next);
  }
  if (dialogId === request?.id) return;
  dialogId = request?.id;
  clearInterval(dialogTimer);
  host.querySelector('.dialog')?.remove();
  if (!request) { focusComposer(); return; }
  const card = node('form', undefined, 'dialog'); card.tabIndex = -1;
  const head = node('div', undefined, 'head'); head.append(node('span', request.title, 'title')); card.append(head);
  if ('message' in request && request.message) card.append(node('div', request.message, 'msg2'));
  if ('timeout' in request && request.timeout) {
    const count = node('span', undefined, 'count'), fuse = node('span', undefined, 'fuse'); head.append(count); card.append(fuse);
    const end = request.expires ?? Date.now() + request.timeout;
    const left = Math.max(0, end - Date.now());
    fuse.style.width = Math.min(100, left / request.timeout * 100) + '%'; fuse.style.animation = 'burn ' + left + 'ms linear forwards';
    const tick = () => { count.textContent = Math.ceil(Math.max(0, end - Date.now()) / 1000) + 's'; };
    tick(); dialogTimer = setInterval(tick, 1000);
  }
  let field: HTMLInputElement | HTMLTextAreaElement | undefined, selection: ReturnType<typeof cursor> | undefined;
  if (request.method === 'select') {
    const list = node('div', undefined, 'opts'); list.setAttribute('role', 'listbox');
    const options = request.options.map((text, index) => { const option = node('div', undefined, 'opt'); option.append(node('span', '', 'k'), node('span', text)); option.onclick = () => selection?.mark(index); option.ondblclick = () => answer(false); list.append(option); return option; });
    selection = cursor(options, (row, chosen) => { if (row.firstElementChild) row.firstElementChild.textContent = chosen ? '›' : ''; });
    selection.mark(0); card.append(list);
  } else if (request.method !== 'confirm') {
    field = node(request.method === 'editor' ? 'textarea' : 'input', undefined, 'in' + (request.method === 'editor' ? ' multi' : ''));
    field.value = request.method === 'editor' ? request.prefill || '' : ''; field.placeholder = request.method === 'input' ? request.placeholder || '' : ''; field.setAttribute('aria-label', request.title); card.append(field);
  }
  const foot = node('div', undefined, 'foot'); foot.append(node('span', request.method === 'select' ? '↑↓ choose' : request.method === 'editor' ? '⇧↩ newline' : ''), node('span', undefined, 'sp'));
  const cancel = button(request.method === 'confirm' ? 'No' : 'Cancel', '⎋');
  const submit = button(request.method === 'confirm' ? 'Yes' : request.method === 'select' ? 'Select' : 'Submit', request.method === 'editor' ? '⌃↩' : '↩', true);
  cancel.tabIndex = submit.tabIndex = 0;
  const answer = async (cancelled: boolean) => {
    if (submit.disabled) return;
    submit.disabled = cancel.disabled = true;
    try { await fetchJSON('/dialog', { sessionId: state.sessionId, id: request.id, ...(cancelled ? { cancelled: true } : request.method === 'confirm' ? { confirmed: true } : { value: field ? field.value : request.method === 'select' && selection ? request.options[selection.index] : undefined }) }); }
    catch (error) { reportError(error); submit.disabled = cancel.disabled = false; }
  };
  card.onsubmit = event => { event.preventDefault(); void answer(false); };
  submit.onclick = () => answer(false); cancel.onclick = () => answer(true);
  card.onkeydown = event => {
    if (event.metaKey || event.isComposing || event.ctrlKey && event.key !== 'Enter') return;
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); void answer(true); }
    else if (request.method === 'select' && ['ArrowUp', 'ArrowDown'].includes(event.key)) { event.preventDefault(); selection?.mark(selection.index + (event.key === 'ArrowDown' ? 1 : -1)); }
    else if (request.method === 'select' && /^[1-9]$/.test(event.key)) { event.preventDefault(); selection?.mark(Number(event.key) - 1); }
    else if (event.key === 'Enter' && (request.method !== 'editor' || event.ctrlKey) && event.target !== cancel) { event.preventDefault(); void answer(false); }
  };
  foot.append(cancel, submit); card.append(foot); host.prepend(card); (field || card).focus();
}
function queue() {
  const entries = [...state.queue.steering.map((entry, index) => ({ kind: 'steer', index, entry }) as const), ...state.queue.followUp.map((entry, index) => ({ kind: 'follow-up', index, entry }) as const)];
  const signature = JSON.stringify(entries);
  if (shownQueue === signature) return;
  shownQueue = signature;
  const host = element('queue'); host.replaceChildren();
  for (const { kind, index, entry } of entries) {
    const row = node('div', undefined, 'qmsg user'), close = node('button', undefined, 'attach-remove');
    row.dataset.kind = kind;
    row.append(node('div', markdownLine(entry.text), 't'));
    if (entry.attachments.length) { const count = node('span', undefined, 'att'); count.innerHTML = '<svg viewBox="0 0 16 16"><path d="M10.5 5.5 6 10a1.6 1.6 0 0 0 2.3 2.3l5-5a3.2 3.2 0 0 0-4.5-4.5l-5.2 5.2a4.8 4.8 0 0 0 6.8 6.8l4-4"/></svg>'; count.append(document.createTextNode(String(entry.attachments.length))); row.append(count); }
    close.type = 'button'; close.title = 'Remove from the queue'; close.setAttribute('aria-label', 'Remove from the queue');
    close.innerHTML = '<svg viewBox="0 0 10 10"><path d="m2 2 6 6m0-6-6 6"/></svg>';
    close.onclick = () => {
      close.disabled = true;
      const origin = state.sessionId;
      fetchJSON('/queue/remove', { sessionId: origin, kind, index, text: entry.text }).catch(error => {
        const unsent = error?.body?.unsent;
        if (unsent && state.sessionId === origin) restoreQueued([...unsent.steering, ...unsent.followUp]);
        reportError(error); close.disabled = false;
      });
    };
    row.append(node('span', kind, 'kind'), close);
    host.append(row);
  }
}
function restoreQueued(entries: QueuedPrompt[]) {
  editor.setText([editor.text(), ...entries.map(entry => entry.text)].filter(Boolean).join('\n\n'));
  draft.restore(entries.flatMap(entry => entry.attachments));
  refreshComposer(); editor.focus();
}
let takingBack: Promise<void> | undefined;
const drafts = new Map<string, string>();
function takeBack(): Promise<void> {
  if (state.life.type !== 'ready' || state.dialogs.length) return Promise.resolve();
  return takingBack ??= (async () => {
    const session = state.sessionId;
    const result = await fetchJSON('/queue/clear', { sessionId: session });
    if (state.sessionId !== session) return;
    restoreQueued([...result.steering, ...result.followUp]);
  })().finally(() => { takingBack = undefined; });
}
async function stop() {
  if (submitting || state.life.type !== 'ready' || state.dialogs.length) return;
  submitting = true;
  const origin = state.view.id, session = state.sessionId;
  try { if (!state.bash.some(item => item.phase === 'running')) await takeBack(); if (state.view.id !== origin) return; await fetchJSON('/abort', { sessionId: session }); }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
function hasFailed() { return state.life.type === 'failed'; }
function exited() {
  composerFocus();
  const host = element('exited'); host.hidden = !hasFailed();
  const life = state.life;
  const at = life.type === 'failed' ? life.at : undefined;
  if (shownExit === at) return;
  shownExit = at; host.replaceChildren();
  if (life.type !== 'failed') return;
  closePicker();
  const card = node('div', undefined, 'card'), head = node('div', undefined, 'head');
  const title = node('span', 'koa could not start the agent', 'title'); head.append(title, node('span', timestamp(life.at), 'count'));
  const actions = node('div', 'Start again creates the session again', 'acts'), start = button('Start again', '↩', true);
  start.onclick = async () => { start.disabled = true; try { await fetchJSON('/agent/start', { sessionId: state.sessionId }); } catch (error) { reportError(error); start.disabled = false; } };
  actions.append(node('span', undefined, 'sp'), start); card.append(head, node('pre', life.message));
  if (!state.sessionFile) card.append(node('div', 'No session file was saved. Start again starts a fresh session.', 'fresh'));
  card.append(actions); host.append(card); start.focus();
}
function closePicker() { element('picker').hidden = true; const trigger = pickerButton; pickerButton = undefined; if (trigger) { trigger.classList.remove('pick'); focusComposer(); } composerFocus(); }
function positionPicker() {
  if (!pickerButton) return;
  const host = element('picker'), cell = element('model-cell'), rect = (cell.offsetParent === null ? element('field') : cell).getBoundingClientRect();
  host.style.left = Math.max(0, Math.min(rect.left - 6, innerWidth - 244)) + 'px';
  host.style.bottom = (innerHeight - rect.top + 8) + 'px';
  host.style.maxHeight = Math.max(0, rect.top - 16) + 'px';
}
async function picker(kind: 'model' | 'thinking', search = '') {
  if (editing()) return;
  if (state.life.type !== 'ready') return;
  const trigger = element(kind), host = element('picker');
  if (pickerButton === trigger) { closePicker(); return; }
  closePicker();
  let choices: ({ kind: 'model'; id: string; provider: string } | { kind: 'thinking'; id: ThinkingLevel })[] = [];
  try {
    if (kind === 'model') {
      const origin = state.view.id, models = (await fetchJSON('/models', undefined, 'GET', undefined, state.sessionId)).models;
      if (state.view.id !== origin) return;
      choices.push(...models.map(model => ({ kind: 'model' as const, id: model.id, provider: model.provider })));
      if (element('thinking').offsetParent === null) choices.push(...state.levels.map(id => ({ kind: 'thinking' as const, id })));
    } else choices.push(...state.levels.map(id => ({ kind: 'thinking' as const, id })));
  } catch (error) { reportError(error); return; }
  if (search) {
    const query = search.toLowerCase();
    choices = choices.filter(choice => (choice.kind === 'model' ? choice.provider + '/' + choice.id : choice.id).toLowerCase().includes(query));
  }
  pickerButton = trigger; trigger.classList.add('pick'); host.replaceChildren(); host.hidden = false; host.tabIndex = -1;
  positionPicker();
  host.append(node('div', kind === 'model' ? 'Model' : 'Thinking', 'ph'));
  const current = (choice: typeof choices[number]) => choice.kind === 'model' ? choice.id === state.model?.id && choice.provider === state.model?.provider : choice.id === state.thinking;
  const rows = choices.map((choice, index) => {
    if (kind === 'model' && choice.kind === 'thinking' && choices[index - 1]?.kind !== 'thinking') host.append(node('div', 'Thinking', 'ph'));
    const row = node('button', undefined, 'row'); row.type = 'button'; row.tabIndex = -1;
    row.append(node('span', current(choice) ? '✓' : '', 'tick'), node('span', choice.id, 'n'));
    if (choice.kind === 'model') row.append(node('span', choice.provider, 'p'));
    row.onmouseenter = () => selection.mark(index); row.onclick = () => choose(index); host.append(row); return row;
  });
  const selection = cursor(rows, () => {});
  const choose = async (index: number) => { const choice = choices[index]; if (!choice) return; try { if (choice.kind === 'model') await fetchJSON('/model', { sessionId: state.sessionId, provider: choice.provider, modelId: choice.id }); else await fetchJSON('/thinking', { sessionId: state.sessionId, level: choice.id }); closePicker(); } catch (error) { reportError(error); } };
  host.append(node('div', '↑↓ move · ↩ choose · ⎋ close', 'hints')); selection.mark(Math.max(0, choices.findIndex(current))); host.focus(); composerFocus();
  host.onkeydown = event => { if (event.metaKey || event.ctrlKey || event.isComposing) return; if (['ArrowUp', 'ArrowDown', 'Enter', 'Escape'].includes(event.key)) { event.preventDefault(); event.stopPropagation(); if (event.key === 'Escape') { closePicker(); } else if (event.key === 'Enter') void choose(selection.index); else selection.mark(selection.index + (event.key === 'ArrowDown' ? 1 : -1)); } };
}
function statuses() {
  const entries = Object.entries(state.statuses || {}).sort(([a], [b]) => a.localeCompare(b)), signature = JSON.stringify(entries);
  if (shownStatuses === signature) return;
  shownStatuses = signature;
  element('status-extras').replaceChildren(...entries.map(([key, text]) => {
    const segment = node('span', undefined, 'ext'); segment.append(node('i', undefined, 'sep'), node('span', key, 'k'), node('span', text)); return segment;
  }));
}
function resync() {
  historyRequest = undefined; epoch = ''; after = -1;
  if (source) source.onmessage = source.onerror = source.onopen = null;
  source?.close(); clearTimeout(reconnect);
  connect();
}
function applyPatch(record: Patch, buffer: boolean) {
  const current = items.get(record.seq);
  if (!current) { if (buffer) historyRequest?.patches.push(record); return; }
  if (current.kind !== 'assistant') return resync();
  if (record.revision <= current.revision) return;
  if (record.baseRevision !== current.revision) return resync();
  const item = { ...current, blocks: current.blocks.slice(), revision: record.revision };
  Object.assign(item, { final: record.final, stop: record.stop, error: record.error, ended: record.ended });
  for (const change of record.blocks) {
    if ('block' in change) {
      const key = record.seq + ':' + change.index, memo = texts.get(key);
      item.blocks[change.index] = change.block;
      if (memo) revealing.delete(memo);
      texts.delete(key);
    }
    else {
      const block = item.blocks[change.index];
      if (block.type !== 'tool') item.blocks[change.index] = { ...block, text: block.text + change.suffix };
    }
  }
  put(item);
}
function apply(record: PageRecord) {
  if (record.type === 'reset') {
    editor.resetCompletion();
    epoch = record.epoch; after = -1; first = undefined; items.clear(); views.clear(); texts.clear(); revealing.clear(); growing.length = 0; scrollMode = undefined; dirty = false; stopFrames(); annotationItems.clear(); folds.clear(); jobOwners.clear(); historyRequest = undefined; more = record.more;
    element('items').replaceChildren(); divider = undefined; fresh.clear(); counted.clear(); liveBash.clear();
    element('older').hidden = !more;
    for (const item of record.items) put(item);
    if (follow) { scrollMode = 'load'; schedule(true); }
    sync();
    refreshBash(); refreshComposer();
  } else if (record.type === 'item') {
    const current = items.get(record.item.seq);
    if (!current || record.item.revision >= current.revision) { put(record.item); if (!current && record.item.kind !== 'user' && record.item.kind !== 'annotations' && (record.item.kind !== 'bash' || record.item.result.output.text)) arrive(liveBash.get(record.item.kind === 'bash' ? record.item.command : '') ?? String(record.item.seq), views.get(record.item.seq)?.view); if (record.item.kind === 'bash') liveBash.delete(record.item.command); }
  } else if (record.type === 'patch') applyPatch(record, true);
  else if (record.type === 'reload') location.reload();
  else if (record.type === 'state') {
    if (state.sessionId !== record.sessionId || state.life.type !== record.life.type) editor.resetCompletion();
    if (state.sessionId && state.sessionId !== record.sessionId) { closeSessions(); closePicker(); editorId = undefined; }
    const agentsChanged = JSON.stringify(state.agents) !== JSON.stringify(record.agents);
    const wasEditing = !!state.edit, viewChanged = state.view.id !== record.view.id;
    if (viewChanged) leaveView(record.view.id);
    state = record; if (agentsChanged || viewChanged) refreshAgentCards(); document.body.dataset.sessionId = state.sessionId ?? ''; element('items').hidden = state.life.type === 'switching';
    if (viewChanged) { rescopeImages(); follow = true; scrollMode = 'load'; schedule(true); }
    renderBar(); refreshBash(); refreshComposer(); dialogs(); queue(); exited();
    if (state.life.type === 'ready' && state.editor && editorId !== state.editor.id) {
      editor.setText(state.editor.text); editorId = state.editor.id;
      void fetchJSON('/editor/ack', { sessionId: state.sessionId, id: state.editor.id }).catch(reportError);
    }
    statuses();
    if (wasEditing && !state.edit) focusComposer();
  }
}

function leaveView(next: string) {
  const previous = state.view.id;
  closeSessions(); closePicker(); closeLightbox(); closeBarMenu();
  editor.resetCompletion(); historyRequest = undefined; editorId = undefined; escaped = false; takingBack = undefined;
  element('error').textContent = '';
  draft.view(next);
  if (!previous) return;
  drafts.set(previous, editor.text());
  editor.setText(drafts.get(next) ?? ''); drafts.delete(next);
}
function rescopeImages() {
  for (const thumb of element('items').querySelectorAll<HTMLButtonElement>('[data-base]')) {
    const image = thumb.firstElementChild, src = scoped(thumb.getAttribute('data-base') ?? '', state.sessionId);
    if (!(image instanceof HTMLImageElement) || image.getAttribute('src') === src) continue;
    thumb.classList.remove('gone'); thumb.removeAttribute('role'); thumb.disabled = false;
    while (thumb.children.length > 2) thumb.lastElementChild?.remove();
    image.hidden = false; image.setAttribute('src', src);
  }
}
const bar = element('bar'), barMenu = element('bar-menu');
let shownBar: string | undefined;
const viewedName = () => state.view.path.length > 1 ? '@' + (state.view.path.at(-1)?.name ?? '') : 'koa';
function closeBarMenu() { barMenu.hidden = true; barMenu.replaceChildren(); }
function viewTo(id: string) {
  closeBarMenu();
  fetchJSON('/view', { sessionId: state.sessionId, id }).catch(error => { if (error?.status !== 409) reportError(error); });
}
function drawBar(collapse: boolean) {
  const path = state.view.path, last = path.length - 1, ancestors = path.slice(0, last), hidden = collapse ? ancestors.slice(1, -1) : [];
  const part = (label: string, className: string, id?: string, title = label) => {
    const result = node(id === undefined ? 'span' : 'button', label, className);
    result.title = title;
    if (id !== undefined) result.onclick = () => viewTo(id);
    return result;
  };
  const separator = () => { const result = node('span', '›', 'sep'); result.setAttribute('aria-hidden', 'true'); return result; };
  const back = part('‹', 'back', path[last - 1].id, 'Back to @' + path[last - 1].name);
  back.setAttribute('aria-label', back.title);
  bar.replaceChildren(back);
  ancestors.forEach(ancestor => {
    if (hidden.includes(ancestor)) {
      if (ancestor !== hidden[0]) return;
      const menu = node('button', '…', 'ellipsis'); menu.title = hidden.map(entry => '@' + entry.name).join(' › ');
      menu.setAttribute('aria-haspopup', 'menu'); menu.onclick = () => openBarMenu(menu, hidden);
      bar.append(menu, separator());
      return;
    }
    bar.append(part('@' + ancestor.name, 'anc', ancestor.id), separator());
  });
  bar.append(part('@' + path[last].name, 'cur'));
}
function openBarMenu(anchor: HTMLElement, hidden: { id: string; name: string }[]) {
  if (!barMenu.hidden) { closeBarMenu(); return; }
  barMenu.replaceChildren(...hidden.map(entry => { const row = node('button', '@' + entry.name); row.setAttribute('role', 'menuitem'); row.onclick = () => viewTo(entry.id); return row; }));
  const rect = anchor.getBoundingClientRect(), bounds = bar.getBoundingClientRect();
  barMenu.style.left = Math.max(8, Math.min(rect.left - 6, innerWidth - 8 - 140)) + 'px'; barMenu.style.top = bounds.bottom + 4 + 'px';
  barMenu.hidden = false;
}
function layoutBar() {
  if (bar.hidden) return;
  const column = element('transcript').getBoundingClientRect();
  bar.style.left = column.left + 8 + 'px'; bar.style.maxWidth = Math.max(0, column.width - 16) + 'px';
  bar.classList.remove('cap', 'shrink', 'noback');
  const overflows = () => bar.scrollWidth > bar.clientWidth + 1.5;
  drawBar(false);
  if (!overflows()) return;
  if (state.view.path.length > 3) { drawBar(true); if (!overflows()) return; }
  bar.classList.add('cap');
  if (!overflows()) return;
  bar.classList.add('shrink');
  if ((bar.querySelector('.cur')?.getBoundingClientRect().width ?? 40) < 40) bar.classList.add('noback');
}
function renderBar() {
  const signature = JSON.stringify(state.view.path), shown = state.view.path.length > 1;
  document.body.classList.toggle('viewing', shown);
  bar.hidden = !shown;
  if (signature === shownBar) return;
  shownBar = signature; closeBarMenu();
  if (shown) layoutBar(); else bar.replaceChildren();
}
function followBottom() {
  scrollMode ??= 'snap';
  schedule(true);
}
function dockResized(height: number) {
  const scroll = element('scroll');
  document.body.style.setProperty('--dock-h', height + 'px');
  if (follow && paneFocused()) { scroll.scrollTop = scroll.scrollHeight; lastScrollTop = scroll.scrollTop; }
  followResize();
}
function followResize() {
  const scroll = element('scroll');
  if (scroll.clientWidth !== fitWidth) { fitWidth = scroll.clientWidth; fitAll = true; }
  lastScrollTop = Math.min(lastScrollTop, Math.max(0, scroll.scrollHeight - scroll.clientHeight));
  dirty ||= revealing.size > 0;
  followBottom();
}
const koaInstance = document.querySelector<HTMLMetaElement>('meta[name="koa-instance"]')?.content;
const metricsMode = document.querySelector<HTMLMetaElement>('meta[name="koa-metrics"]')?.content;
const metrics: { mode: string; bytes: number; pending: number[]; samples: { t: number; bytes: number; clockError: number; applied?: number; frame?: number }[]; timer?: number; writes: Promise<void>; frames: Set<Promise<void>>; error?: string } | undefined = metricsMode ? { mode: metricsMode, bytes: 0, pending: [], samples: [], timer: undefined, writes: Promise.resolve(), frames: new Set(), error: undefined } : undefined;
function sendMetrics(force = false) {
  if (!metrics || !force && !metrics.samples.length) return;
  clearTimeout(metrics.timer); metrics.timer = undefined;
  const samples = metrics.samples.splice(0, 50);
  metrics.writes = metrics.writes.then(async () => {
    const response = await fetch('/metrics', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(samples) });
    if (!response.ok) throw Error('Metrics write failed: ' + response.status);
  }).catch(error => { metrics.error = error.message; console.error(error); });
}
if (metrics) window.koaMetrics = {
  async flush() {
    await Promise.all([...metrics.frames]);
    while (metrics.samples.length) sendMetrics();
    sendMetrics(true); await metrics.writes;
    if (metrics.error) throw Error(metrics.error);
  },
  get after() { return after; },
  get items() { return [...items.values()]; },
};
let source: EventSource, reconnect: number | undefined, closed = false, failed = false;
function connect() {
  if (closed) return;
  source = new EventSource('/events?epoch=' + encodeURIComponent(epoch) + '&after=' + after + '&koa=' + encodeURIComponent(koaInstance ?? ''));
  const lost = () => {
    source.onmessage = source.onerror = source.onopen = null;
    source.close();
    if (!reloading) element('error').textContent = 'Connection lost. Reconnecting…';
    reconnect = setTimeout(connect, delay); delay = Math.min(delay * 2, 5000);
  };
  source.onopen = () => { delay = 200; if (!reloading) element('error').textContent = ''; };
  source.onerror = lost;
  source.onmessage = event => {
    try {
      const record: PageRecord = JSON.parse(event.data);
      if (metrics && record.type === 'flush') { metrics.bytes = record.bytes; metrics.pending.push(record.t); }
      else apply(record);
      followBottom();
      if (metrics?.pending.length) {
        const pending = metrics.pending.splice(0), bytes = metrics.bytes;
        const sampled = (kind: 'applied' | 'frame') => {
          const at = performance.timeOrigin + performance.now();
          for (const t of pending) {
            metrics.samples.push({ t, [kind]: at, bytes, clockError: Date.now() - at });
            if (metrics.samples.length === 50) sendMetrics();
          }
          metrics.timer ??= setTimeout(sendMetrics, 250);
        };
        if (metrics.mode === 'applied') sampled('applied');
        else {
          let finish: () => void = () => {};
          const frame = new Promise<void>(resolve => { finish = resolve; });
          metrics.frames.add(frame);
          requestAnimationFrame(() => { sampled('frame'); metrics.frames.delete(frame); finish(); });
        }
      }
    } catch (error) {
      failed = true;
      console.error(error);
      source.onmessage = source.onerror = source.onopen = null;
      source.close();
      element('error').textContent = `This page cannot show koa's state: ${error instanceof Error ? error.message : String(error)}. Reload the pane.`;
    }
  };
}
window.addEventListener('pagehide', () => { closed = true; source?.close(); clearTimeout(reconnect); });
window.addEventListener('pageshow', event => { if (event.persisted && closed && !failed) { closed = false; connect(); } });
async function older() {
  if (!more || historyRequest || first === undefined) return;
  const patches: Patch[] = [], mine = historyRequest = { patches };
  const scroll = element('scroll'), anchor = views.get(first)?.view;
  const top = anchor?.getBoundingClientRect().top;
  try {
    const response = await fetch(scoped('/items?before=' + first, state.sessionId)); if (!response.ok) throw Error('Could not load earlier messages');
    const result: Extract<PageRecord, { type: 'reset' }> = await response.json();
    if (historyRequest === mine && result.epoch === epoch) {
      more = result.more;
      for (const item of result.items) if (!items.has(item.seq)) put(item);
      for (const patch of mine.patches) { applyPatch(patch, false); if (historyRequest !== mine) return; }
      element('older').hidden = !more;
      if (anchor && top !== undefined) scroll.scrollTop += anchor.getBoundingClientRect().top - top;
    }
  } catch (error) { reportError(error); } finally { if (historyRequest === mine) historyRequest = undefined; }
}
const sessionHost = element('session-picker');
const sessionSearch = node('input', undefined, 'q'); sessionSearch.placeholder = 'Search sessions…'; sessionSearch.setAttribute('aria-label', 'Search sessions');
const sessionResults = node('div', undefined, 'rows'); sessionResults.setAttribute('role', 'listbox'); sessionResults.setAttribute('aria-label', 'Sessions');
const sessionCurrent = button('this folder'), sessionAll = button('all');
const sessionHints = node('div', undefined, 'hints');
const sessionCard = node('div', undefined, 'sess'), sessionTop = node('div', undefined, 'top'), sessionScopes = node('span', undefined, 'scope');
sessionScopes.append(sessionCurrent, sessionAll); sessionTop.append(sessionSearch, sessionScopes); sessionCard.append(sessionTop, sessionResults, sessionHints);
let sessionRows: Partial<Record<SessionScope, (SessionRow & { search: string[] })[]>> = {};
let visibleSessions: SessionRow[] = [], sessionCursor: ReturnType<typeof cursor> | undefined;
let sessionScope: SessionScope = 'current', sessionScan: AbortController | undefined, sessionAction: AbortController | undefined;
let sessionPicker: 'closed' | 'loading' | 'list' | 'filtered' | 'empty' | 'error' | 'switching' | 'confirm' = 'closed';
function closeSessions() {
  sessionScan?.abort(); sessionScan = undefined; sessionAction?.abort(); sessionAction = undefined;
  sessionRows = {}; visibleSessions = []; sessionCursor = undefined;
  sessionPicker = 'closed'; sessionHost.hidden = true; refreshComposer(); focusComposer();
}
function renderSessions(selected?: number) {
  const rows = sessionRows[sessionScope];
  if (!rows) return;
  const query = sessionSearch.value.trim().toLocaleLowerCase(), today = new Date();
  visibleSessions = rows.filter(row => row.search.some(text => {
    let offset = 0;
    for (const char of query) { const found = text.indexOf(char, offset); if (found < 0) return false; offset = found + 1; }
    return true;
  }));
  sessionPicker = !visibleSessions.length ? 'empty' : query ? 'filtered' : 'list'; sessionHost.dataset.state = sessionPicker;
  sessionResults.replaceChildren();
  const choices = visibleSessions.map(row => {
    const choice = button(''); choice.className = 'row';
    choice.setAttribute('role', 'option');
    const name = node('span', row.name || row.firstMessage || row.id, 'n');
    if (row.id === state.sessionId) name.append(node('span', 'current', 'tag'));
    if (sessionScope === 'all' && row.cwd !== state.cwd) name.append(node('span', displayPath(row.cwd), 'dir'));
    const meta = node('span', undefined, 'm'); meta.append(node('span', timestamp(row.modified, today, 'session')), node('br'), node('span', String(row.messageCount)));
    choice.append(name, node('span', row.name ? row.firstMessage : '', 'f'), meta);
    choice.dataset.path = row.path; choice.onclick = () => { if (row.id !== state.sessionId) void chooseSession({ type: 'switch', path: row.path }); };
    sessionResults.append(choice); return choice;
  });
  sessionCursor = cursor(choices, (row, chosen) => row.setAttribute('aria-selected', String(chosen)));
  sessionCursor.mark(selected ?? Math.max(0, visibleSessions.findIndex(row => row.id !== state.sessionId)));
  if (!visibleSessions.length) { const empty = node('div', query ? 'no match' : 'no sessions in this folder', 'empty'); empty.append(node('div', '⇥ all folders', 'h')); sessionResults.append(empty); }
}
sessionSearch.oninput = () => renderSessions(0);
sessionCurrent.onclick = () => { void openSessions('current'); }; sessionAll.onclick = () => { void openSessions('all'); };
async function openSessions(scope: SessionScope = 'current') {
  if (editing()) return;
  closePicker(); sessionScan?.abort(); sessionScan = undefined;
  sessionScope = scope; sessionPicker = 'loading'; visibleSessions = []; sessionCursor = undefined;
  sessionHost.dataset.state = sessionPicker; sessionHost.hidden = false;
  sessionCurrent.className = scope === 'current' ? 'on' : ''; sessionAll.className = scope === 'all' ? 'on' : '';
  sessionCurrent.setAttribute('aria-pressed', String(scope === 'current')); sessionAll.setAttribute('aria-pressed', String(scope === 'all'));
  sessionHints.replaceChildren(node('span', '↑↓ move · ↩ open · ⎋ close'), node('span', undefined, 'sp'), node('span', '⇥ ' + (scope === 'all' ? 'this folder' : 'all folders')));
  if (sessionHost.firstElementChild !== sessionCard) sessionHost.replaceChildren(sessionCard);
  sessionHost.onkeydown = event => {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
    if (['Escape', 'Tab', 'ArrowUp', 'ArrowDown', 'Enter'].includes(event.key)) { event.preventDefault(); event.stopPropagation(); }
    if (event.key === 'Escape') closeSessions();
    else if (event.key === 'Tab') void openSessions(sessionScope === 'current' ? 'all' : 'current');
    else if (event.key === 'ArrowUp' || event.key === 'ArrowDown') sessionCursor?.mark(sessionCursor.index + (event.key === 'ArrowUp' ? -1 : 1));
    else if (event.key === 'Enter' && sessionCursor) { const row = visibleSessions[sessionCursor.index]; if (row && row.id !== state.sessionId) void chooseSession({ type: 'switch', path: row.path }); }
  };
  refreshComposer(); sessionSearch.focus();
  if (sessionRows[scope]) { renderSessions(); return; }
  const scan = new AbortController(); sessionScan = scan;
  sessionResults.replaceChildren(node('div', 'loading sessions…', 'empty'));
  try {
    const result = await fetchJSON('/sessions/list', { sessionId: state.sessionId, scope }, 'POST', scan.signal);
    if (scan.signal.aborted || sessionScan !== scan) return;
    sessionRows[scope] = result.rows.map(row => ({ ...row, search: [row.name ?? '', row.firstMessage].map(text => text.toLocaleLowerCase()) }));
    renderSessions();
  } catch (error) {
    if (scan.signal.aborted || sessionScan !== scan) return;
    sessionPicker = 'error'; sessionHost.dataset.state = sessionPicker;
    sessionResults.replaceChildren(node('p', error instanceof Error ? error.message : String(error), 'session-error'));
    const retry = button('Try again'); retry.onclick = () => { void openSessions(scope); }; sessionResults.append(retry);
  }
}
async function chooseSession(choice: { type: 'switch'; path: string } | { type: 'new' }) {
  const sessionId = state.sessionId;
  closeSessions(); sessionPicker = 'switching'; refreshComposer();
  try { await fetchJSON(choice.type === 'switch' ? '/sessions/switch' : '/sessions/new', { sessionId, ...(choice.type === 'switch' ? { path: choice.path } : {}) }); }
  catch (error) { reportError(error); if (choice.type === 'switch') await openSessions(sessionScope); }
  finally { if (sessionPicker === 'switching') closeSessions(); }
}
async function sessionCommand(kind: 'resume' | 'new') {
  const continueSession = async () => { closeSessions(); if (kind === 'resume') { sessionSearch.value = ''; await openSessions(); } else await chooseSession({ type: 'new' }); };
  const commandRunning = state.bash.some(item => item.phase !== 'completed'), turnRunning = state.working;
  if (!turnRunning && !commandRunning) { await continueSession(); return; }
  const action = new AbortController(); sessionAction = action;
  sessionPicker = 'confirm'; sessionHost.dataset.state = 'confirm'; sessionHost.hidden = false;
  const card = node('div', undefined, 'dialog'), head = node('div', undefined, 'head'); head.append(node('span', 'Switch session?', 'title'));
  const foot = node('div', '⎋ cancel · ↩ switch', 'foot'), cancel = button('Cancel'), confirm = button('Switch', '↩', true);
  cancel.tabIndex = confirm.tabIndex = 0;
  const perform = async () => {
    if (confirm.disabled || action.signal.aborted) return;
    confirm.disabled = true;
    try {
      await fetchJSON('/abort', { sessionId: state.sessionId }, 'POST', action.signal);
      if (action.signal.aborted) return;
      if (commandRunning && turnRunning) await fetchJSON('/abort', { sessionId: state.sessionId }, 'POST', action.signal);
      if (!action.signal.aborted) await continueSession();
    }
    catch (error) { if (!action.signal.aborted) { closeSessions(); reportError(error); } }
  };
  cancel.onclick = closeSessions; confirm.onclick = () => { void perform(); };
  foot.append(node('span', undefined, 'sp'), cancel, confirm);
  card.append(head, node('div', turnRunning ? 'koa is working on a turn; it will be aborted.' : 'a command is running; it will be cancelled.', 'msg2'), foot); sessionHost.replaceChildren(card);
  sessionHost.onkeydown = event => { if (event.key === 'Escape' || event.key === 'Enter') { event.preventDefault(); event.stopPropagation(); if (event.key === 'Escape') closeSessions(); else void perform(); } };
  refreshComposer(); confirm.focus();
}
function canSend(text: string) { if (state.compaction === 'running' || editing()) return false; const bang = editor.bash(); if (bang) return !!bang.command.trim() && !state.bash.some(item => item.phase !== 'completed') && !draft.busy && !draft.count; return /^\/\S+/.test(text.trim()) || !draft.busy && draft.count <= ATTACHMENT_LIMITS.files && (!!text.trim() || draft.count > 0); }
let noticeTimer: number | undefined;
function notice(text: string) {
  clearTimeout(noticeTimer);
  element('error').textContent = text;
  noticeTimer = setTimeout(() => { if (element('error').textContent === text) element('error').textContent = ''; }, 4000);
}
function editing() { return !!state.edit || editorOpening; }
async function openEditor() {
  if (state.life.type !== 'ready' || state.dialogs.length || submitting || editorOpening) return;
  editorOpening = true; refreshComposer();
  const origin = state.view.id;
  try { const { pane } = await fetchJSON('/editor/open', { sessionId: state.sessionId, text: editor.text() }); if (state.view.id === origin) window.ko?.focus?.(pane); }
  catch (error) { notice(error instanceof Error ? error.message : String(error)); }
  finally { editorOpening = false; refreshComposer(); }
}
function reportError(error: unknown) { element('error').textContent = error instanceof Error ? error.message : String(error); }
async function send(mode: PromptMode = 'prompt') {
  const text = editor.text(), files = draft.files;
  if (!canSend(text) || submitting) return;
  const sendingSession = state.sessionId, origin = state.view.id;
  submitting = true;
  try {
    const result = await fetchJSON('/prompt', { sessionId: sendingSession, text, mode, attachments: files.map(file => file.id) });
    if (result.disposition !== 'handled') draft.sent(files);
    if (state.view.id !== origin) { if (drafts.get(origin) === text) drafts.delete(origin); return; }
    if (state.sessionId !== sendingSession) return;
    clearDivider(); sync();
    if (editor.text() === text) editor.setText('');
    refreshComposer(); focusComposer(); element('error').textContent = '';
    if (result.disposition === 'handled') {
      switch (result.action.type) {
        case 'picker': await picker(result.action.kind, result.action.search); break;
        case 'session': await sessionCommand(result.action.kind); break;
        case 'reload': reloading = true; element('error').textContent = 'Reloading…'; refreshComposer(); break;
        case 'none': case 'quit': break;
      }
    }
  }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
element('older').onclick = older;
const isTextInput = (target: EventTarget | null) => target instanceof HTMLElement && (target.isContentEditable || !!target.closest('input,textarea,select'));
const isControl = (target: EventTarget | null) => isTextInput(target) || target instanceof HTMLElement && !!target.closest('button,[role=button],[role=option],[role=listbox],[role=menuitem]');
function composerReceivesKeys() { return document.hasFocus() && !element('field').inert && !state.dialogs.length && !document.querySelector('.lightbox') && (editor.hasFocus() || !isTextInput(document.activeElement)); }
function composerFocus() { element('field').classList.toggle('focus', composerReceivesKeys()); }
function focusComposer() { composerFocus(); if (composerReceivesKeys() && !pickerButton && sessionPicker === 'closed' && (!isControl(document.activeElement) || editor.hasFocus())) editor.focus(); }
window.addEventListener('focus', () => { focusComposer(); refocus(); });
window.addEventListener('load', focusComposer);
const onEditingComposer = (event: Event) => !!state.edit && event.target instanceof Element && element('composer').contains(event.target);
document.addEventListener('mousedown', event => { if (onEditingComposer(event)) event.preventDefault(); });
document.addEventListener('click', event => {
  if (state.edit && onEditingComposer(event)) { event.preventDefault(); window.ko?.focus?.(state.edit.pane); return; }
  const link = event.target instanceof Element ? event.target.closest('a') : null;
  if (!link?.classList.contains('who')) return;
  event.preventDefault();
  const view = link.getAttribute('data-view'), pane = link.getAttribute('data-pane');
  if (view) viewTo(view);
  else if (pane) window.ko?.focus?.(pane);
});
window.addEventListener('pagehide', stopFrames);
document.addEventListener('visibilitychange', () => { refocus(); if (document.hidden) stopFrames(); else { dirty ||= revealing.size > 0; schedule(); armCap(); } });
document.addEventListener('focusin', composerFocus);
document.addEventListener('focusout', composerFocus);
const previewModifiers = (event: MouseEvent | KeyboardEvent) => event.shiftKey && event.metaKey && !event.ctrlKey && !event.altKey;
const previewHover = (event: KeyboardEvent) => document.documentElement.classList.toggle('preview-modifiers', previewModifiers(event));
document.addEventListener('keyup', previewHover);
window.addEventListener('blur', () => { document.documentElement.classList.remove('preview-modifiers'); composerFocus(); sync(); });
document.addEventListener('keydown', event => { previewHover(event); if (previewKey(event)) return; if (!barMenu.hidden && event.key === 'Escape') { event.preventDefault(); closeBarMenu(); return; } if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.isComposing || state.dialogs.length || pickerButton || sessionPicker !== 'closed') return; if (event.key === 'Tab') { event.preventDefault(); if (!element('field').inert) editor.focus(); return; } if (composerReceivesKeys() && !event.altKey && event.key.length === 1 && !(event.key === ' ' && isControl(event.target)) && !isTextInput(event.target)) { event.preventDefault(); editor.focus(); editor.insert(event.key); return; } if (event.key === 'Enter' && hasFailed() && event.target === document.body) element('exited').querySelector('button')?.click(); if (event.key === 'Escape') { event.preventDefault(); if (editing()) return; if (state.bash.some(item => item.phase === 'running')) { escaped = false; void stop(); } else if (state.working) { escaped = true; void stop(); } else if (escaped) { editor.setText(''); } else { escaped = true; } } });
element('model').onclick = () => picker('model'); element('thinking').onclick = () => picker('thinking');
document.addEventListener('pointerdown', event => { if (!barMenu.hidden && !barMenu.contains(event.target instanceof Node ? event.target : null) && !(event.target instanceof Element && event.target.closest('.ellipsis'))) closeBarMenu(); if (!element('picker').contains(event.target instanceof Node ? event.target : null) && !pickerButton?.contains(event.target instanceof Node ? event.target : null)) closePicker(); });
element('scroll').onscroll = () => { const scroll = element('scroll'); if (Math.abs(scroll.scrollTop - lastScrollTop) >= 1) { follow = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 60; lastScrollTop = scroll.scrollTop; } sync(); if (scroll.scrollTop < 80) void older(); };
element('latest').onmousedown = event => event.preventDefault();
element('latest').onclick = toLatest;
setInterval(() => { status(); for (const item of state.bash) pendingBash.get(item.id)?.update(item); }, 1000);
window.addEventListener('resize', positionPicker);
new ResizeObserver(() => { followResize(); layoutBar(); }).observe(element('scroll'));
new ResizeObserver(([entry]) => dockResized(entry.borderBoxSize[0].blockSize)).observe(element('dock'));
refreshComposer(); focusComposer(); void connect();
