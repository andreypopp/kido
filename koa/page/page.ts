import { annotations, update } from './annotations.ts';
import { head, quote } from './answers.ts';
import { scrollInitial, scrollMemory, type Saved, scrollStored, scrollUpdate, scrollWindow, type ItemId, type ScrollEvent, type Measure, type Decision, type Row, type Lookup } from './scroll.ts';
import { pathToken } from '../path-token.ts';
import { markdown, type Tail } from './markdown.ts';
import { markdownLine } from '../markdown-line.ts';
import { revealHeight, unitsOf, type Unit } from './reveal.ts';
import { estimateExtent, groupAt, windowOf, rowKey, sameRow, type RowId, type SeqRange } from './extent.ts';
import { visibleText, runParts, runOwner, runOf, invalidateRuns, sourceKey, projectTopic, type RunContext, type TopicContext } from '../topic-run.ts';
import { composer } from './composer.ts';
import { stepInfo, stepParts, toolArgs, noticeOf, noticeText, sessionFields, type NoticeData, type StepInput } from './steps.ts';
import { exportText, findSegments, lowered, matchesIn, type Segment } from './find.ts';
import { attach } from './attach.ts';
import { closeLightbox, preview, previewKey } from './preview.ts';
import { fetchJSON, scoped } from './http.ts';
import { createJobPage } from './job.ts';
import { dots } from './working.ts';
import { install } from './metrics.ts';
import { ATTACHMENT_LIMITS, pathArg } from '../koa-records.ts';
import type { State, WireJob, WireItem, QueuedPrompt, Patch, PageRecord, MetricsSample, Stages, PromptMode, ImageRef, Bash, SessionRow, SessionScope, ThinkingLevel } from '../koa-records.ts';
import type { TopicName, AgentRef, Relation } from '../records.ts';
import { createTopics, topicsMemory, type TopicsMemory } from './topics.ts';
import { createTranscriptHistory } from './transcript-history.ts';

type Step = StepInput & { key: string; slots: Map<string, Slot> };
type Slot = { type: 'image'; view: HTMLButtonElement } | { type: 'run'; view: HTMLDivElement };
declare global {
  interface Window {
    composer: Pick<ReturnType<typeof composer>, 'text' | 'setText' | 'focus'>;
    koaFocused?: boolean;
    __koFind?: (query: string, backwards: boolean) => Promise<{ index: number; count: number; loading: boolean } | { cancelled: true } | null>;
    __koFindCancel?: () => void;
    __koQuoteSelection?: () => { record: string; quote?: string } | undefined;
    __koComposer?: (state: { type: 'focus' | 'quote' } | { type: 'prompt' | 'prompt_quote'; record: string }) => void;
    koaMetrics?: { flush(): Promise<void>; readonly after: number; readonly count: number; readonly items: WireItem[] };
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
const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
type PageMemory = TopicsMemory & { scroll: Saved[]; drafts: [view: string, text: string][] };
const stored: unknown = history.state;
const pageMemory = (stored: unknown): stored is PageMemory => isRecord(stored) && Array.isArray(stored.scroll) && stored.scroll.every(saved => {
  if (!isRecord(saved) || !isRecord(saved.scope) || typeof saved.scope.view !== 'string' || saved.scope.sessionId !== undefined && typeof saved.scope.sessionId !== 'string' || saved.scope.topic !== undefined && typeof saved.scope.topic !== 'string' || !Number.isInteger(saved.last)) return false;
  if (!('anchor' in saved)) return true;
  if (!isRecord(saved.anchor) || saved.anchor.edge !== 'row' && saved.anchor.edge !== 'divider' || typeof saved.anchor.offset !== 'number' || !Number.isFinite(saved.anchor.offset) || !isRecord(saved.anchor.item)) return false;
  const item = saved.anchor.item;
  return item.kind === 'message' && Number.isInteger(item.seq) && (item.row === undefined || isRecord(item.row) && isRecord(item.row.source) && Number.isInteger(item.row.source.seq) && (item.row.kind === 'text' && item.row.source.kind === 'block' && Number.isInteger(item.row.source.index) || item.row.kind === 'run' && (item.row.source.kind === 'item' || item.row.source.kind === 'block' && Number.isInteger(item.row.source.index)))) || item.kind === 'job' && Number.isInteger(item.byte);
}) && Array.isArray(stored.drafts) && stored.drafts.every(entry => Array.isArray(entry) && entry.length === 2 && entry.every(value => typeof value === 'string')) && topicsMemory(stored);
const memory = pageMemory(stored) ? stored : undefined;
const topicItems = new Map<number, Extract<WireItem, { kind: 'topics' }>>();
const projections = new Map<number, WireItem | undefined>();

const rhythmPending = new Set<HTMLElement>();
const annotationItems = new Map<number, Map<number, Extract<WireItem, { kind: 'annotations' }>>>();
const items = new Map<number, WireItem>();
const views = new Map<number, { view: HTMLElement; item: WireItem; warning?: string; slots: Map<string, Slot>; filter?: TopicName; runs: string }>();
const openers = new Map<string, { view: HTMLElement; open: () => void }>(), fenceOpeners = new Map<string, { view: HTMLElement; open: () => void }>(), patched = new Set<number>(), live = new Set<number>(), order: number[] = [], extents = new Map<number, Extent>(), openFences = new Set<string>(), animating = new Map<HTMLElement, { seq: number; until: number }>();
type Extent = { kind: 'measured'; width: number; lh: number; px: number } | { kind: 'estimated'; px: number };
type Group = SeqRange;
type Table = { index: Map<number, number>; starts: number[]; groups: Group[]; divider: { before: number; px: number } | undefined };
let table: Table | undefined, windowDirty = true, mountedSpans: { start: number; end: number }[] = [], gaps: HTMLElement[] = [], measured = { width: 0, lh: 0 }, dividerPx: number | undefined;
const template = document.createElement('template');
const folds = new Map<string, boolean>();
const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const REVEAL = { cap: .4, wait: 1500, fold: 15, grow: 220 };
type Reveal = { at: number; tail?: { block: Tail; view: HTMLElement; shown: number; units?: Unit[] } };
type TextMemo = { render: ReturnType<typeof markdown>; view: HTMLElement; blocks: { block: ReturnType<ReturnType<typeof markdown>>[number]; nodes: ChildNode[] }[]; final?: boolean; source?: string; annotationItem?: Extract<WireItem, { kind: 'annotations' }>; assistant: boolean; paths: boolean; key?: string; reveal?: Reveal; grown: number };
const texts = new Map<string, TextMemo>();
type StepMarks = { key: string; shape: string; links: string; cwd: string; card?: NonNullable<ReturnType<typeof stepInfo>['card']>; child: HTMLElement; sum: HTMLElement; name?: HTMLElement; label: HTMLElement; after: HTMLElement; tail: HTMLElement[]; tailKey: string; result: HTMLElement; time: HTMLElement; detail: HTMLElement; current: Step; live: boolean; file?: string; images?: ReturnType<typeof thumbnails>; show?: () => void };
type RunMarks = { key: string; links: string; cwd: string; summary: HTMLElement; names: HTMLElement; namesKey: string; time: HTMLElement; children: HTMLElement; steps: StepMarks[] };
const runMarks = new WeakMap<HTMLElement, RunMarks>();
const liveMarks = new Map<string, RunMarks>();
type WorkingPlace = { kind: 'bare'; row: HTMLElement; line: HTMLElement; sum: HTMLElement } | { kind: 'run'; owner: HTMLElement };
let working: { view: string; since: number; primary: HTMLElement; place: WorkingPlace; extra: Map<string, HTMLElement> } | undefined;
const runContext = (): RunContext => ({ raw: seq => items.get(seq), shown: visible, owners });
type Spot = { key: string; parent: HTMLElement; before: ChildNode | null };
const revealing = new Set<TextMemo>(), revealPreparation = new Set<TextMemo>();
let capTimer: number | undefined;
let pending: { kind: 'frame' | 'timer'; id: number } | undefined;
const dirty = new Set<number>(), stale = new Set<string>(), waiters: (() => void)[] = [];
const scrollEvents: ScrollEvent[] = [];
let revealDirty = false, resetting = false, annotated = false;
const growing: HTMLElement[] = [], measuredHolds = new Map<HTMLElement, number>(), fits = new Map<HTMLElement, HTMLElement>(), extentDirty = new Set<HTMLElement>(), fitPending = new Set<HTMLElement>();
let fontsReady = false;
const pathWarnings = new Map<number, string>();
let pathWarningEpoch = 0;
let state: State = { pathEditor: false, view: { id: '', path: [], type: 'root' }, topics: [], agents: [], bash: [], compaction: 'idle', life: { type: 'starting' }, working: false, aborted: false, name: '', levels: [], cwd: '', home: '', statuses: {}, queue: { steering: [], followUp: [], classifying: [] }, dialogs: [] };
let shownFilter: TopicName | undefined;
function topicUnread(): Map<TopicName, number> {
  const counts = new Map<TopicName, number>();
  if (!('topics' in state)) return counts;
  for (const [seq, rows] of scrolling.candidates) {
    if (!Array.from(rows.values()).some(row => row.unread)) continue;
    for (const topic of state.topics) {
      const item = projectTopic(topicContext, seq, topic.name);
      if (Array.from(rows.values()).some(row => row.unread && (item?.kind === 'user' || item?.kind === 'assistant' && row.row?.kind === 'text' && row.row.source.kind === 'block' && visibleText(item.blocks[row.row.source.index])))) counts.set(topic.name, (counts.get(topic.name) ?? 0) + 1);
    }
  }
  return counts;
}
const topics = createTopics({
  unread: topicUnread,
  state: () => state, items, element, node, timestamp, refreshComposer, layout: dirtyExtent, focus: () => editor.focus(),
  filterChanged() {
    transcriptHistory.cancel('scope'); topics.close(); topics.render(); refreshComposer();
    if (epoch) void transcriptHistory.reload('filter');
    else finishTopicFilter();
  },
  async correct(correction) {
    const { kind, ...body } = correction;
    try { await fetchJSON(kind === 'message' ? '/messages/topic' : kind === 'move' ? '/topics/move' : '/topics/archive', body); }
    catch (error) { reportError(error); throw error; }
  },
}, memory);
function finishTopicFilter() {
  refreshTopicItems();
  enqueue({ type: 'filter', active: topics.filter() !== undefined, topic: topics.filter() });
  for (const seq of items.keys()) changedItem(seq, false);
}
function latestTopicInput(): WireItem | undefined {
  let latest: WireItem | undefined;
  for (const item of items.values()) if ((item.kind === 'user' || item.kind === 'agent' || item.kind === 'job') && (!latest || item.seq > latest.seq)) latest = item;
  return latest;
}
function waitingForTopic(item: WireItem): boolean {
  return state.view.type === 'root' && state.working && item.kind === 'user' && !item.topic && !topicItems.has(item.seq) && latestTopicInput()?.seq === item.seq;
}
const runKeys = new Map<number, string>();
const allRuns: RunContext = { raw: seq => items.get(seq), shown: seq => items.get(seq), owners: new Map() };
const topicContext: TopicContext = { items, labels: seq => topicItems.get(seq)?.topics ?? [], runs: allRuns };
function visible(seq: number): WireItem | undefined {
  const item = items.get(seq);
  if (projections.has(seq)) return projections.get(seq);
  const projected = projectTopic(topicContext, seq, shownFilter) ?? (item && waitingForTopic(item) ? item : undefined);
  projections.set(seq, projected);
  return projected;
}
function refreshTopicItems() {
  shownFilter = topics.filter();
  topicContext.topics = undefined;
  projections.clear(); segmentCache.clear(); owners.clear(); find = undefined; selected = undefined;
  order.length = 0; extents.clear(); table = undefined;
  for (const seq of items.keys()) { if (visible(seq)) order.splice(orderIndex(seq), 0, seq); dirty.add(seq); }
  for (const seq of views.keys()) if (!visible(seq)) unmountRow(seq);
  windowDirty = true; schedule();
}
let scrolling = scrollInitial({ view: '', sessionId: undefined }, memory?.scroll);
let scrollDecision: Decision = { latest: { show: false, count: 0 }, windowTop: 0, frame: 'none' };
let lastMeasurement: Measure | undefined;
let divider: HTMLElement | undefined;
let dockHeight = 0;
let epoch = '', after = -1, first: number | undefined, delay = 200;
let escaped = false, dialogId: string | undefined;
let submitting = false, editorId: string | undefined, dialogTimer: number | undefined, shownExit: number | undefined, pickerButton: HTMLElement | undefined, shownQueue: string | undefined, shownStatuses: string | undefined;
const transcriptHistory = createTranscriptHistory({
  epoch: () => epoch, session: () => state.sessionId, view: () => state.view.type, filter: () => topics.filter(), first: () => first,
  viewport: () => element('scroll'), has: seq => items.has(seq), accept: rows => acceptHistory(rows),
  apply: record => { if (record.type === 'patch') applyPatch(record, false); else apply(record); },
  history: () => enqueue({ type: 'history' }), filtered: finishTopicFilter, rendered: () => rendered(), error: reportError,
});
let editorOpening = false;
const draft = attach(element('attachments'), () => refreshComposer(), () => state.edit ? 'editing' : editor.bash() ? 'command' : undefined);
const pendingBash = new Map<string, ReturnType<typeof commandRun>>();
const editor = composer(element('prompt'), {
  drop: draft.drop, paste: draft.paste,
  dropTopic: () => !element('field').inert && topics.dropComposer(),
  input(user) { if (user) escaped = false; refreshComposer(); },
  send(mode) { void send(mode); },
  quit() { if (!draft.count && !draft.busy) void fetchJSON('/quit', { sessionId: state.sessionId }); },
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
function agentLead(card: NonNullable<ReturnType<typeof stepInfo>['card']>, label: string) {
  const lead = node('span', undefined, 'agent-name');
  const ref = card.direction === 'in' ? card.from : card.to;
  lead.append(label.slice(0, label.lastIndexOf('@')), who(ref));
  if (card.direction === 'in' && 'relation' in card.inbound && card.inbound.relation) lead.append(' ', node('span', relationWords[card.inbound.relation], 'rel'));
  return lead;
}

function previewFile(label: HTMLElement, url: string) {
  label.classList.add('preview-file');
  let press: { x: number; y: number } | undefined;
  label.onmousedown = event => { press = undefined; if (event.button === 0 && previewModifiers(event)) { event.preventDefault(); press = { x: event.clientX, y: event.clientY }; } };
  label.onclick = event => { const start = press; press = undefined; if (start && Math.hypot(event.clientX - start.x, event.clientY - start.y) < 3) { event.preventDefault(); event.stopPropagation(); preview(scoped(url, state.sessionId), label, 'file', composerFocus); } };
}
function timestamp(at: number, today = new Date(), kind: 'message' | 'session' = 'message') {
  const date = new Date(at);
  const time = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === today.toDateString()) return time;
  return (date.getFullYear() === today.getFullYear() ? '' : date.getFullYear() + ' ') + date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + (kind === 'session' ? '' : ' ' + time);
}

function decoratePaths(fragment: DocumentFragment) {
  for (const code of fragment.querySelectorAll<HTMLElement>('code')) {
    if (code.closest('pre, a') || !pathToken(code.textContent ?? '')) continue;
    code.classList.add('path-open');
    let press: { x: number; y: number } | undefined;
    code.onmousedown = event => { press = event.button === 0 ? { x: event.clientX, y: event.clientY } : undefined; };
    code.onclick = async event => {
      const start = press; press = undefined;
      if (!start || Math.hypot(event.clientX - start.x, event.clientY - start.y) >= 3 || window.getSelection()?.isCollapsed === false) return;
      event.preventDefault(); event.stopPropagation();
      const row = code.closest<HTMLElement>('[data-seq]'), seq = Number(row?.dataset.seq), origin = state.view.id, sessionId = state.sessionId, generation = pathWarningEpoch;
      if (!row || !Number.isSafeInteger(seq)) return;
      try {
        const result = await fetchJSON('/editor/path', { sessionId, view: origin, text: code.textContent ?? '' });
        if (state.view.id !== origin || state.sessionId !== sessionId || generation !== pathWarningEpoch) return;
        if (result.type === 'opened') window.ko?.focus?.(result.pane);
        else {
          pathWarnings.set(seq, result.text);
          dirty.add(seq); schedule();
        }
      } catch (error) { reportError(error); }
    };
  }
}

function prose(key: string | undefined, source: string, final: boolean, annotationItem?: Extract<WireItem, { kind: 'annotations' }>, kind: 'assistant' | 'user' | 'agent' | 'plain' = 'plain') {
  let memo = key === undefined ? undefined : texts.get(key);
  if (!memo) {
    memo = { render: markdown(kind === 'user'), view: node('div', undefined, 'msg prose'), blocks: [], assistant: kind === 'assistant', paths: kind !== 'plain', key, reveal: kind === 'assistant' && !final ? { at: performance.now() } : undefined, grown: 0 };
    if (key !== undefined) texts.set(key, memo);
  }
  if (memo.annotationItem === annotationItem && (memo.final && final || memo.source === source && memo.final === final)) return memo.view;
  const changed = memo.source !== undefined && source.startsWith(memo.source) ? memo.source.length : 0;
  if (final) delete memo.source;
  else memo.source = source;
  memo.annotationItem = annotationItem;
  memo.final = final;
  show(memo, source, final, changed);
  return memo.view;
}
function show(memo: TextMemo, source: string, final: boolean, changed = 0) {
  const { reveal } = memo, before = reveal?.tail;
  const annotated = memo.annotationItem ? annotations(source, memo.annotationItem.annotations, editor) : undefined;
  if (!reveal) memo.view.querySelector<HTMLElement>('.caret')?.remove();
  const blocks = memo.render(source, final, annotated?.marks, changed);
  let first = 0;
  while (first < blocks.length && memo.blocks[first]?.block === blocks[first]) first++;
  const removed = memo.blocks.splice(first);
  for (const saved of removed) for (const child of saved.nodes) { unwatch(child); child.remove(); }
  blocks.slice(first).forEach((block, offset) => {
    const index = first + offset;
    template.innerHTML = linkNames(block.html ?? '');
    annotated?.decorate(template.content);
    if (memo.paths && state.pathEditor) decoratePaths(template.content);
    const pres = [...template.content.querySelectorAll<HTMLElement>('pre')];
    pres.forEach((pre, ordinal) => {
      if (memo.assistant && memo.key !== undefined) foldFence(pre, memo.key + ':' + index + '.' + ordinal);
      const language = pre.querySelector('code')?.className.match(/language-(\S+)/)?.[1];
      if (language) pre.append(node('span', language, 'lang'));
    });
    const { tail } = block, content = [...template.content.childNodes];
    if (!block.streaming) delete block.html;
    const shown = reveal && tail && before?.block.start === tail.start ? before.shown : 0;
    const wrapper = reveal && tail ? node('div', undefined, shown ? 'reveal' : 'reveal dormant') : undefined;
    wrapper?.append(...content);
    const nodes = wrapper ? [wrapper] : content;
    memo.blocks.push({ block, nodes });
    memo.view.append(...nodes);
    if (!reveal) return;
    if (wrapper && tail) {
      wrapper.style.maxHeight = shown + 'px';
      reveal.tail = { block: tail, view: wrapper, shown };
      revealPreparation.add(memo); revealDirty = true;
      if (before?.block.start !== tail.start) reveal.at = performance.now();
      return;
    }
    const elements = nodes.filter(child => child instanceof HTMLElement), fresh = index >= memo.grown;
    if (!elements.length) return;
    if (fresh) { memo.grown = index + 1; if (scrolling.kind !== 'restoring' && !reducedMotion()) { growing.push(...elements); for (const element of elements) animating.set(element, { seq: Number(memo.key?.split(':')[0]), until: Infinity }); } reveal.at = performance.now(); }
  });
  if (reveal) {
    if (!blocks.at(-1)?.tail) reveal.tail = undefined;
    if (reveal.tail && !final) revealing.add(memo); else revealing.delete(memo);
    armCap();
  }
  if (!final && !reveal) {
    const last = memo.view.lastElementChild;
    (last?.tagName === 'P' ? last : memo.view).append(node('span', undefined, 'caret'));
  }
  dirtyExtent(memo.view);
}
function unwatch(target: ChildNode) {
  if (!(target instanceof HTMLElement)) return;
  extentDirty.delete(target); fits.delete(target); fitPending.delete(target); measuredHolds.delete(target); animating.delete(target);
  for (const child of target.children) unwatch(child);
}
function clear(view: HTMLElement) {
  for (const child of [...view.childNodes]) unwatch(child);
  view.replaceChildren();
}
function foldFence(pre: HTMLElement, key: string) {
  const count = (pre.textContent ?? '').replace(/\n$/, '').split('\n').length;
  if (count <= REVEAL.fold || openFences.has(key)) return;
  const bar = node('button', 'Show ' + (count - REVEAL.fold) + ' more lines', 'more');
  pre.classList.add('folded');
  pre.style.setProperty('--fold', String(REVEAL.fold));
  const expand = () => { openFences.add(key); pre.classList.remove('folded'); bar.remove(); dirtyExtent(pre); };
  bar.onclick = () => toggleAt(bar, expand);
  fenceOpeners.set(key, { view: pre, open: () => { if (pre.classList.contains('folded')) expand(); } });
  pre.after(bar);
}
const transcriptVisible = () => state.view.type !== 'job' && !element('items').hidden;
const wanted = () => fontsReady && (transcriptVisible() && (extentDirty.size > 0 || animating.size > 0 || windowDirty || revealDirty || fitPending.size > 0 || growing.length > 0 || measuredHolds.size > 0) || dirty.size > 0 || resetting || scrollEvents.length > 0 || scrollDecision.frame !== 'none' || waiters.length > 0 || !!metrics?.waiting.length);
function schedule() {
  if (pending || !wanted()) return;
  pending = document.hidden ? { kind: 'timer', id: setTimeout(tick, 50) } : { kind: 'frame', id: requestAnimationFrame(tick) };
}
function armCap() {
  if (capTimer !== undefined || document.hidden) return;
  const now = performance.now(), next = Math.min(...[...revealing].flatMap(({ reveal }) => reveal && reveal.at + REVEAL.wait > now ? [reveal.at + REVEAL.wait] : []));
  if (next < Infinity) capTimer = setTimeout(() => { capTimer = undefined; revealDirty = true; schedule(); }, next - now);
}
function cancelPending() {
  if (pending?.kind === 'frame') cancelAnimationFrame(pending.id);
  else if (pending) clearTimeout(pending.id);
  pending = undefined;
}
function stopFrames() {
  cancelPending();
  clearTimeout(capTimer);
  capTimer = undefined;
}
function rendered() { return new Promise<void>(resolve => { waiters.push(resolve); schedule(); }); }
function tick() {
  pending = undefined;
  const now = performance.now(), geo = geometry();
  const grown = [...measuredHolds];
  measuredHolds.clear();
  for (const [target, height] of grown) {
    if (height) target.style.setProperty('--h', height + 'px');
    target.style.animationDuration = REVEAL.grow + 'ms';
    target.classList.remove('hold');
    target.classList.add('grow');
    const active = animating.get(target); if (active) active.until = now + REVEAL.grow;
    const finish = () => { target.classList.remove('grow'); animating.delete(target); dirtyExtent(target); };
    for (const type of ['animationend', 'animationcancel']) target.addEventListener(type, finish, { once: true });
  }
  renderDirty(geo);
  for (const target of fitPending) {
    const row = fits.get(target); if (!row || !target.isConnected) continue;
    const overflows = target.scrollWidth > target.clientWidth;
    if (row.classList.contains('more') !== overflows) { row.classList.toggle('more', overflows); dirtyExtent(row); }
  }
  fitPending.clear();
  for (const memo of revealPreparation) { const tail = memo.reveal?.tail; if (tail) tail.units = unitsOf(tail.view, tail.block.token); }
  revealPreparation.clear();
  if (revealDirty) {
    revealDirty = false;
    for (const memo of revealing) revealStep(memo, now, geo.viewport);
  }
  const holds = growing.splice(0);
  for (const target of holds) target.classList.add('hold');
  for (const target of holds) { measuredHolds.set(target, target.scrollHeight + target.offsetHeight - target.clientHeight); dirtyExtent(target); }
  for (const [target, active] of animating) {
    if (target.isConnected) dirtyExtent(target);
    if (!target.isConnected || now >= active.until) { target.classList.remove('grow'); animating.delete(target); }
  }
  const layout = flushExtents();
  if (layout) scrollEvents.push({ type: 'layout', cause: 'layout' });
  const scroll = element('scroll'), viewport = scroll.clientHeight;
  const fresh = {
    now, top: scroll.scrollTop, max: Math.max(0, scroll.scrollHeight - viewport),
    naturalHeight: element('transcript').offsetHeight, viewport, width: scroll.clientWidth,
  };
  const measurement = !lastMeasurement || layout || scrollDecision.frame === 'measure'
    || fresh.naturalHeight !== lastMeasurement.naturalHeight || fresh.max !== lastMeasurement.max
    || fresh.viewport !== lastMeasurement.viewport || fresh.width !== lastMeasurement.width
    ? measure() : { ...lastMeasurement, ...fresh };
  decide({ type: 'frame' }, measurement);
  for (const resolve of waiters.splice(0)) resolve();
  for (const waiter of metrics?.waiting.splice(0) ?? []) waiter();
  schedule();
  armCap();
}
type Geo = { top: number; max: number; viewport: number; width: number; origin: number };
const geometry = (): Geo => scrolling.last ?? lastMeasurement ?? measure();
const messageRows = (): ArrayLike<Element> => state.view.type === 'job' ? job.rows() : element('items').children;
const itemOf = (row: Element | undefined): ItemId | undefined => row instanceof HTMLElement ? row.dataset.seq !== undefined ? { kind: 'message', seq: Number(row.dataset.seq) } : row.dataset.byte !== undefined ? { kind: 'job', byte: Number(row.dataset.byte) } : undefined : undefined;
const unitView = (row: RowId) => row.kind === 'run' ? openers.get(rowKey(row))?.view : texts.get(rowKey(row))?.view;
const rowOf = (item: ItemId): HTMLElement | undefined => {
  if (item.kind === 'job') return job.row(item.byte);
  if (item.row) return sameRow(unitRows(item.seq)[0], item.row) ? views.get(item.seq)?.view : unitView(item.row);
  const parts = runParts(items.get(item.seq), visible(item.seq)), first = parts[0];
  const seq = first && first.kind !== 'boundary' ? runOf(runContext(), first.source)?.seq ?? item.seq : item.seq;
  return views.get(seq)?.view;
};
function measure(): Measure {
  const scroll = element('scroll');
  const top = scroll.scrollTop;
  const origin = element('transcript').offsetTop + element('items').offsetTop;
  const viewport = scroll.clientHeight;
  const rect = scroll.getBoundingClientRect();
  const mounted = new Map<number, { row: Row; element: Element }>(), projected = new Map<string, { row: Row; element: Element }>(), units = new Map<number, RowId[]>();
  const jobView = state.view.type === 'job';
  const leading = (row: Row): Row => {
    if (row.item.kind !== 'message' || row.item.seq !== scrollDecision.divider?.seq || !divider?.isConnected || !sameRow(row.item.row ?? unitRows(row.item.seq)[0], scrollDecision.divider?.row)) return row;
    const start = top + divider.getBoundingClientRect().top - rect.top - parseFloat(getComputedStyle(divider).marginTop);
    return { ...row, leading: Math.min(row.top, start) };
  };
  for (const view of jobView ? Array.from(messageRows()) : resetting ? [] : [...views.values()].map(entry => entry.view)) {
    const item = itemOf(view);
    if (!item || view instanceof HTMLElement && view.hidden) continue;
    const box = view.getBoundingClientRect();
    const row = leading({
      item,
      top: top + box.top - rect.top,
      bottom: top + box.bottom - rect.top,
    });
    mounted.set(item.kind === 'message' ? item.seq : item.byte, { row, element: view });
    if (item.kind === 'message') {
      const keys = unitRows(item.seq); units.set(item.seq, keys);
      for (const key of keys) {
        const address: ItemId = { ...item, row: key }, target = key === keys[0] ? view : unitView(key);
        if (!target) continue;
        const bounds = target === view ? box : target.getBoundingClientRect();
        projected.set(rowKey(key), { element: target, row: leading({ item: address, top: top + bounds.top - rect.top, bottom: top + bounds.bottom - rect.top }) });
      }
    }
  }
  let anchorRow: Row | undefined;
  for (const { row } of [...mounted.values()].filter(({ row }) => row.item.kind !== 'message' || !units.get(row.item.seq)?.length).concat([...projected.values()])) {
    if (row.bottom > top && (!anchorRow || row.top < anchorRow.top)) anchorRow = row;
  }
  if (!jobView && (!anchorRow || anchorRow.top > top + viewport)) {
    const t = ensureTable();
    let low = 0, high = order.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (t.starts[middle + 1] > top - origin) high = middle; else low = middle + 1;
    }
    const seq = order[Math.min(low, order.length - 1)];
    if (seq !== undefined) {
      const y = origin + rowTop(seq);
      anchorRow = { item: { kind: 'message', seq }, top: y, bottom: y + extentOf(t, seq) };
    }
  }
  return lastMeasurement = {
    now: performance.now(),
    top,
    max: Math.max(0, scroll.scrollHeight - viewport),
    naturalHeight: element('transcript').offsetHeight,
    viewport,
    width: scroll.clientWidth,
    origin,
    dock: viewport - dockHeight,
    focused: window.koaFocused ?? document.hasFocus(),
    visible: window.koaFocused ?? document.visibilityState === 'visible',
    reducedMotion: reducedMotion(),
    windowMax: jobView ? undefined : Math.max(0, ensureTable().starts[order.length] - viewport),
    anchor: anchorRow && { item: anchorRow.item, offset: anchorRow.top - top, edge: 'row' },
    lookup(item): Lookup {
      const key = item.kind === 'message' ? item.seq : item.byte;
      const target = item.kind === 'message' && item.row ? sameRow(units.get(item.seq)?.[0], item.row) ? views.get(item.seq)?.view : unitView(item.row) : rowOf(item), unit = item.kind === 'message' && item.row ? projected.get(rowKey(item.row)) : undefined;
      if (unit && target === unit.element) return { kind: 'mounted', row: unit.row };
      const found = mounted.get(item.kind === 'message' && target ? rowSeq(target) ?? key : key);
      if (found && target === found.element) return { kind: 'mounted', row: { ...found.row, item } };
      if (item.kind === 'message') {
        const t = ensureTable();
        if (t.index.has(item.seq)) {
          const y = origin + rowTop(item.seq);
          return { kind: 'unmounted', row: { item, top: y, bottom: y + extentOf(t, item.seq), windowTop: y } };
        }
        if (transcriptHistory.more && first !== undefined && item.seq < first) return { kind: 'unloaded' };
        let low = 0, high = order.length;
        while (low < high) {
          const middle = (low + high) >> 1;
          if (order[middle] > item.seq) high = middle; else low = middle + 1;
        }
        const seq = order[low];
        const y = seq === undefined ? 0 : origin + rowTop(seq);
        return { kind: 'removed', next: seq === undefined ? undefined : { item: { kind: 'message', seq }, top: y, bottom: y + extentOf(t, seq) } };
      }
      if (item.byte < job.start()) return { kind: 'unloaded' };
      let next: Row | undefined;
      for (const { row } of mounted.values()) {
        if (row.item.kind === 'job' && row.item.byte > item.byte && (!next || row.top < next.top)) next = row;
      }
      return { kind: 'removed', next };
    },
  };
}
function applyScroll(decision: Decision, measurement: Measure) {
  let stored: number | undefined;
  const latest = element('latest'), label = decision.latest.count ? '↓ ' + decision.latest.count + ' new' : '↓ Latest';
  if (latest.textContent !== label) latest.textContent = label;
  latest.classList.toggle('show', decision.latest.show);
  const before = decision.divider?.seq, inside = before !== undefined && decision.divider?.row && !sameRow(unitRows(before)[0], decision.divider?.row);
  const view = before === undefined ? undefined : inside ? rowOf({ kind: 'message', seq: before, row: decision.divider?.row }) : views.get(before)?.view;
  const changed: Element[] = [];
  const remember = () => {
    if (!divider) return;
    const parent = divider.parentNode;
    for (const at of [divider.previousElementSibling, divider.nextElementSibling, parent instanceof HTMLElement && parent !== element('items') ? parent : undefined]) if (at) changed.push(at);
  };
  if (!view) { remember(); divider?.remove(); divider = undefined; }
  else {
    if (!divider) { divider = node('div', undefined, 'newmsgs'); divider.append(node('span', 'new messages')); }
    if (divider.nextSibling !== view) { remember(); view.parentNode?.insertBefore(divider, view); remember(); }
  }
  if (changed.length) {
    rhythm(changed); changed.forEach(dirtyExtent);
    flushExtents();
    const correcting = scrolling.kind === 'following' && decision.scrollTop !== undefined
      ? { ...scrolling, positioning: true, last: measurement } : { ...scrolling, last: measurement };
    const correction = scrollUpdate(correcting, [{ type: 'layout', cause: 'layout' }], {
      ...measure(), focused: measurement.focused, visible: measurement.visible,
    });
    scrolling = scrolling.kind === 'following' && correction.state.kind === 'following'
      ? { ...correction.state, positioning: scrolling.positioning } : correction.state;
    scrollDecision = decision = correction.decision;
  }
  element('transcript-clip').style.minHeight = decision.minHeight === undefined ? '' : decision.minHeight + 'px';
  if (decision.scrollTop !== undefined) {
    const scroll = element('scroll');
    scroll.scrollTop = decision.scrollTop;
    stored = scroll.scrollTop;
  }
  if (decision.request?.type === 'mount') windowDirty = true;
  else if (decision.request?.type === 'load') void loadAnchor(decision.request.item, decision.request.generation);
  if (decision.frame !== 'none') schedule();
  return stored;
}
function decide(event?: ScrollEvent, measurement = measure()) {
  if (event) scrollEvents.push(event);
  const events = scrollEvents.splice(0);
  const result = scrollUpdate(scrolling, events, measurement);
  const previousTop = scrollDecision.windowTop, previousDivider = scrollDecision.divider?.seq, previousRow = scrollDecision.divider?.row;
  const unreadChanged = scrolling.candidates !== result.state.candidates;
  scrolling = result.state; scrollDecision = result.decision;
  if (events.some(event => event.type === 'filter')) catchUpReader();
  if (unreadChanged) topics.render();
  if (previousTop !== scrollDecision.windowTop) windowDirty = true;
  if (previousDivider !== scrollDecision.divider?.seq || !sameRow(previousRow, scrollDecision.divider?.row)) { if (previousDivider !== undefined) extents.delete(previousDivider); if (scrollDecision.divider?.seq !== undefined) extents.delete(scrollDecision.divider?.seq); table = undefined; dividerPx = undefined; windowDirty = true; }
  const stored = applyScroll(scrollDecision, measurement);
  if (stored !== undefined) scrolling = scrollStored(scrolling, stored);
}
function enqueue(event: ScrollEvent) { scrollEvents.push(event); schedule(); }
function unitRows(seq: number, source: 'visible' | 'all' = 'visible'): RowId[] {
  const shown = source === 'all' ? (seq: number) => items.get(seq) : visible;
  const item = shown(seq), context: RunContext = source === 'all' ? allRuns : runContext(), keys: RowId[] = [];
  if (!item) return keys;
  if (item.kind === 'assistant') item.blocks.forEach((block, index) => { if (visibleText(block)) keys.push({ kind: 'text', source: { kind: 'block', seq, index } }); });
  for (const part of runParts(items.get(seq), item)) if (part.kind === 'step' && sourceKey(part.source) === sourceKey(runOwner(context, part.source))) keys.push({ kind: 'run', source: part.source });
  return keys.sort((a, b) => (a.source.kind === 'block' ? a.source.index : 0) - (b.source.kind === 'block' ? b.source.index : 0));
}
function changedItem(seq: number, appended: boolean) {
  const item = items.get(seq), shown = new Set(unitRows(seq).map(rowKey));
  const counts = (item: WireItem | undefined) => item?.kind === 'user' ? !!(item.text.trim() || item.images.length || item.attachments.length) : item?.kind === 'assistant' && item.blocks.some(visibleText);
  if (item) enqueue({ type: 'item', seq, kind: item.kind === 'user' ? 'user' : item.kind === 'assistant' ? 'assistant' : 'other', visible: counts(visible(seq)), rows: item.kind === 'assistant' ? unitRows(seq, 'all').filter(row => row.kind === 'text').map(row => ({ row, visible: shown.has(rowKey(row)) })) : item.kind === 'user' && counts(item) ? [{ visible: counts(visible(seq)) }] : undefined, appended });
}
let resets = 0, loadingAnchor: string | undefined;
async function loadAnchor(item: ItemId, generation: number) {
  const reset = resets, key = generation + ':' + reset;
  const current = () => scrolling.generation === generation && resets === reset;
  if (loadingAnchor === key) return;
  loadingAnchor = key;
  try {
    if (item.kind === 'job') {
      while (current() && state.view.type === 'job' && job.start() > item.byte && await job.earlier());
    } else for (let before = first; transcriptHistory.more && first !== undefined && item.seq < first && current();) { await transcriptHistory.earlier(); if (first === before) break; before = first; }
    if (current()) enqueue({ type: 'restore-result', generation, found: item.kind === 'message' ? items.has(item.seq) : !!rowOf(item) });
  } catch (error) { if (current()) enqueue({ type: 'restore-result', generation, found: false }); reportError(error); }
  finally { if (loadingAnchor === key) loadingAnchor = undefined; }
}
function revealStep(memo: TextMemo, now: number, viewport: number) {
  const { reveal } = memo, tail = reveal?.tail;
  if (!reveal || !tail?.units) return;
  const shown = revealHeight(tail.units, tail.shown, REVEAL.cap * viewport, now - reveal.at >= REVEAL.wait);
  if (shown === undefined) return;
  if (shown > tail.shown) { reveal.at = now; memo.grown = Math.max(memo.grown, memo.blocks.length); }
  tail.shown = shown;
  tail.view.style.maxHeight = shown + 'px';
  tail.view.classList.toggle('dormant', shown === 0);
  dirtyExtent(memo.view);
}

function thumbnails(refs: ImageRef[], owner: () => Map<string, Slot>, name?: string) {
  const view = node('div', undefined, 'thumbs');
  return { view, load() {
    if (view.childNodes.length) return;
    const slots = owner();
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
        thumb.classList.remove('gone'); thumb.removeAttribute('role'); thumb.removeAttribute('title'); thumb.disabled = false;
        while (thumb.children.length > 2) thumb.lastElementChild?.remove();
        const size = ref.width && ref.height ? ref.width + '×' + ref.height : '';
        label.textContent = size; label.hidden = !size;
        thumb.setAttribute('aria-label', 'Preview image' + (size ? ' ' + size : ''));
        image.alt = ''; image.hidden = false;
        if (ref.width && ref.height) { image.width = ref.width; image.height = ref.height; image.style.setProperty('--w', ref.width + 'px'); image.style.setProperty('--r', String(ref.width / ref.height)); }
        else { image.removeAttribute('width'); image.removeAttribute('height'); image.style.removeProperty('--w'); image.style.removeProperty('--r'); }
        const target = thumb;
        image.onerror = () => {
          if (target.classList.contains('gone')) return;
          target.classList.add('gone'); target.setAttribute('role', 'img'); target.setAttribute('aria-label', 'Image unavailable'); target.title = 'Image unavailable'; target.disabled = true;
          target.append(node('span', 'Image unavailable'));
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
function toggleAt(line: HTMLElement, change: () => void) {
  const row = Array.from(messageRows()).find(row => row.contains(line));
  const item = itemOf(row);
  if (!row || !item) { change(); return; }
  const before = line.getBoundingClientRect().top;
  const rowBefore = row.getBoundingClientRect().top;
  change();
  flushExtents();
  const measurement = measure();
  const found = measurement.lookup(item);
  if (found.kind !== 'mounted') return;
  const delta = row.contains(line) ? line.getBoundingClientRect().top - before : row.getBoundingClientRect().top - rowBefore;
  const top = measurement.top + delta;
  decide({ type: 'layout', cause: 'toggle', anchor: { item, offset: found.row.top - top, edge: 'row' } }, measurement);
}
function fold(view: HTMLElement, key: string, line: HTMLElement, details: HTMLElement, show?: () => void, className = 'open', changed?: () => void) {
  view.classList.toggle(className, folds.get(key) === true);
  line.setAttribute('role', 'button'); line.tabIndex = -1;
  line.setAttribute('aria-expanded', String(folds.get(key) === true));
  const toggle = () => { if (view.classList.contains('no-detail')) return; const open = !view.classList.contains(className); folds.set(key, open); view.classList.toggle(className, open); line.setAttribute('aria-expanded', String(open)); if (open) show?.(); changed?.(); const row = Array.from(messageRows()).find(row => row.contains(view)); rhythm(row ? [row] : []); dirtyExtent(view); };
  openers.set(key, { view, open: () => { if (!view.classList.contains(className)) toggle(); } });
  line.onclick = event => { if (!(event?.target instanceof Element && event.target.closest('a'))) toggleAt(line, toggle); };
  line.onkeydown = event => { if (!(event.target instanceof Element && event.target.closest('a')) && !event.metaKey && !event.ctrlKey && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); toggleAt(line, toggle); } };
  if (view !== line && line.parentNode !== view) view.append(line);
  view.append(details);
  if (folds.get(key)) show?.();
}
const isLive = (step: Step) => step.kind === 'block' && !step.item.final && step.item.stop !== 'aborted' && (step.block.type === 'tool' ? step.block.state.type === 'running' || step.block.state.type === 'pending' : step.block.ended === undefined);
const setText = (target: HTMLElement, next: string) => { if (target.textContent !== next) target.textContent = next; };
const stepShape = (step: Step) => step.kind !== 'block' ? step.kind : step.block.type === 'tool' ? 'tool:' + step.block.name : step.block.type;
const stepFailed = (step: Step) => step.kind === 'block' && step.block.type === 'tool' && step.block.state.type === 'done' && step.block.state.error;
function rescue(host: HTMLElement, into: HTMLElement) {
  if (working) for (const mark of [working.primary, ...working.extra.values()]) if (host.contains(mark)) into.append(mark);
}
function stepMarks(step: Step): StepMarks {
  const child = node('div', undefined, 'step'), row = node('div', undefined, 'line'), sum = node('span', undefined, 'sum');
  const block = step.kind === 'block' ? step.block : undefined;
  const name = block?.type === 'tool' && !block.agent && block.name !== 'async_bash' && (block.name === 'bash' || stepInfo({ ...step, args: {} }).labelClass === 'path') ? node('span', block.name) : undefined;
  const label = node('span'), result = node('span'), time = node('span'), outcome = node('span', undefined, 'outcome'), detail = node('div', undefined, 'detail');
  if (name) sum.append(name, ' ');
  sum.append(label, ' '); outcome.append(result, time); row.append(node('span', '›', 'chev'), sum, outcome);
  const marks: StepMarks = { key: step.key, shape: stepShape(step), links: '', cwd: '', child, sum, name, label, after: name ?? label, tail: [], tailKey: '', result, time, detail, current: step, live: false };
  fold(child, step.key, row, detail, () => marks.show?.());
  return marks;
}
function stepDetail(marks: StepMarks, step: Step & { args: Record<string, unknown>; file: string | undefined }, info: ReturnType<typeof stepInfo>) {
  const block = step.kind === 'block' ? step.block : undefined, nodes: Node[] = [];
  const refs = block?.type === 'tool' && 'result' in block.state ? block.state.result?.images : undefined;
  marks.images = refs?.length ? thumbnails(refs, () => marks.current.slots, step.file) : undefined;
  let diff: HTMLElement | undefined;
  for (const part of stepParts(step, info, displayPath(state.cwd), !!marks.images)) {
    switch (part.kind) {
      case 'notice': { const body = noticeRow(part.row, true); if (body.childNodes.length) nodes.push(body); break; }
      case 'agent': { const body = prose(undefined, part.text, true, undefined, 'agent'); body.className = 'agent-body prose'; nodes.push(body); break; }
      case 'job': { const head = node('div', undefined, 'job-head'); head.append(jobOpen(part.job)); nodes.push(head, node('pre', part.text)); if (part.facts) nodes.push(node('div', part.facts, 'delta')); break; }
      case 'redacted': nodes.push(node('div', part.text, 'think redacted')); break;
      case 'head': diff = node('div', undefined, 'diff'); diff.append(node('div', part.text, 'h')); nodes.push(diff); break;
      case 'diff': { const row = node('div', undefined, 'l ' + part.change); row.append(node('span', part.mark, 'g'), part.text); diff?.append(row); break; }
      case 'command': nodes.push(node('pre', part.text)); break;
      case 'cwd': nodes.push(node('div', part.text, 'kv')); break;
      case 'log': nodes.push(jobLog(part.job)); break;
      case 'result': nodes.push(node(part.note ? 'div' : 'pre', part.text, part.note ? 'note' : '')); break;
      case 'cut': nodes.push(node('div', part.text, 'delta')); break;
    }
  }
  marks.child.classList.toggle('agent-step', !!info.card);
  marks.child.classList.toggle('job-step', step.kind === 'job');
  if (marks.images) { if (block?.type === 'tool' && block.name === 'read') marks.images.view.classList.add('large'); nodes.push(marks.images.view); }
  marks.detail.replaceChildren(...nodes);
  const disclosure = nodes.length > 0 || block?.type === 'thinking' && !!block.text;
  marks.child.classList.toggle('no-detail', !disclosure);
  const line = marks.child.firstElementChild;
  if (!disclosure) { marks.child.classList.remove('open'); folds.delete(step.key); line?.removeAttribute('role'); line?.removeAttribute('aria-expanded'); }
  else { line?.setAttribute('role', 'button'); line?.setAttribute('aria-expanded', String(folds.get(step.key) === true)); }
}
function patchStep(marks: StepMarks, step: Step & { args: Record<string, unknown>; file: string | undefined }, info: ReturnType<typeof stepInfo>, links: string) {
  const block = step.kind === 'block' ? step.block : undefined, error = stepFailed(step) || info.failed;
  const previous = marks.current, cwd = block?.type === 'tool' && block.name === 'bash' ? displayPath(state.cwd) : '';
  const changed = step.kind === 'block' ? previous.kind !== 'block' || previous.block !== step.block : previous.kind !== step.kind || previous.item !== step.item;
  const detailsChanged = (info.card ? marks.card !== info.card || marks.links !== links : changed || marks.cwd !== cwd) || !marks.tail.length;
  marks.current = step; marks.live = isLive(step);
  if (step.file !== marks.file) {
    marks.file = step.file;
    if (step.file && step.kind === 'block') previewFile(marks.label, '/steps/' + step.item.seq + '/' + step.index + '/file');
    else marks.label.onmousedown = marks.label.onclick = null;
  }
  if (marks.name) marks.name.className = error ? 'name err' : 'name';
  const labelClass = error ? info.labelClass + ' err' : info.labelClass;
  marks.label.className = marks.file ? labelClass + ' preview-file' : labelClass;
  if (info.card && (marks.card !== info.card || marks.links !== links)) marks.label.replaceChildren(...agentLead(info.card, info.label).childNodes);
  else if (!info.card) setText(marks.label, info.label);
  marks.card = info.card; marks.links = links; marks.cwd = cwd;
  if (marks.tailKey !== info.detail || !marks.tail.length) {
    marks.tailKey = info.detail;
    for (const old of marks.tail) old.remove();
    const counts = info.detail.match(/^\+(\d+) −(\d+)$/);
    marks.tail = counts ? [node('span', '+' + counts[1], 'added'), node('span', ' '), node('span', '−' + counts[2], 'err')] : [node('span', info.detail, info.card ? 'agent-preview' : step.kind === 'job' && error ? 'delta err' : 'delta')];
    marks.sum.append(...marks.tail);
  }
  const result = info.aborted ? 'aborted' : '', ended = block?.ended ?? (info.aborted && step.kind === 'block' ? step.item.ended : !step.item.final ? Date.now() : undefined);
  setText(marks.result, result); marks.result.className = error ? 'err' : '';
  setText(marks.time, step.kind !== 'block' ? timestamp(step.item.at) : (result ? ' ' : '') + duration((block?.type === 'tool' ? block.durationMs : undefined) ?? (block?.started !== undefined && ended !== undefined ? ended - block.started : undefined)));
  marks.time.className = step.kind === 'block' && !info.card && error ? 'time err' : 'time';
  if (detailsChanged) {
    const thinking = block?.type === 'thinking' && !block.redacted;
    if (!thinking) stepDetail(marks, step, info);
    marks.show = thinking ? () => {
      const current = marks.current;
      if (current.kind !== 'block' || current.block.type !== 'thinking' || !current.block.text) return;
      const view = prose(current.key, current.block.text, current.item.final); view.className = 'think prose';
      if (marks.detail.firstChild !== view) marks.detail.replaceChildren(view);
    } : marks.images?.load;
  }
  if (folds.get(step.key)) marks.show?.();
}
function patchRun(marks: RunMarks, input: Step[], links = JSON.stringify(state.agents)) {
  marks.links = links; marks.cwd = displayPath(state.cwd);
  const entries = input.map(step => { const block = step.kind === 'block' ? step.block : undefined; const value = { ...step, args: block?.type === 'tool' ? toolArgs(block) : {}, file: block ? pathArg(block) : undefined }; return { step, value, info: stepInfo(value) }; });
  const failed = new Set(entries.filter(({ step, info }) => stepFailed(step) || info.failed).map(({ info }) => info.kind));
  const aborted = input.some(step => step.kind === 'block' && step.item.stop === 'aborted' && step.item.blocks.slice(step.index + 1).every(block => block.type !== 'text' || !block.text));
  const active = input.some(isLive), counts = new Map<string, { count: number; info: ReturnType<typeof stepInfo> }>();
  for (const { info } of entries) { const old = counts.get(info.kind); counts.set(info.kind, { count: (old?.count ?? 0) + 1, info }); }
  const namesKey = (aborted ? 'aborted' : [...counts].map(([kind, { count }]) => kind + ':' + count + (failed.has(kind) ? '!' : '')).join(',')) + ':' + links;
  if (marks.namesKey !== namesKey) {
    marks.namesKey = namesKey; const parts: (Node | string)[] = [];
    if (aborted) parts.push('aborted, you pressed Escape');
    else for (const [kind, { count, info }] of counts) {
      if (parts.length) parts.push(', ');
      const name = node('span', undefined, failed.has(kind) ? 'err' : '');
      if (info.card) { const ref = info.card.direction === 'in' ? info.card.from : info.card.to; name.append((info.card.direction === 'in' ? 'from' : 'to') + ' ', who(ref)); }
      else name.textContent = (info.summary ?? info.kind) + (count > 1 ? ' x' + count : '');
      if (info.card && count > 1) name.append(' x' + count);
      parts.push(name);
    }
    marks.names.replaceChildren(...parts);
  }
  const timed = input.filter((step): step is Step & Extract<StepInput, { kind: 'block' }> => step.kind === 'block');
  const first = timed[0], last = timed.at(-1), moment = input.at(-1), started = first ? first.block.started ?? first.item.at : undefined;
  const ended = active ? Date.now() : aborted ? last?.item.ended : last?.block.ended;
  setText(marks.time, first ? duration(started === undefined || ended === undefined ? undefined : ended - started) : moment ? timestamp(moment.item.at) : '');
  const known = new Map(marks.steps.map(record => [record.key, record]));
  marks.steps = entries.map(({ step, value, info }) => {
    let record = known.get(step.key); known.delete(step.key);
    if (record && record.shape !== stepShape(step)) { rescue(record.child, marks.summary); record.child.remove(); record = undefined; }
    record ??= stepMarks(step); patchStep(record, value, info, links); return record;
  });
  for (const old of known.values()) { rescue(old.child, marks.summary); old.child.remove(); }
  marks.steps.forEach((record, index) => { if (marks.children.children[index] !== record.child) marks.children.insertBefore(record.child, marks.children.children[index] ?? null); });
  if (marks.steps.some(step => step.live)) liveMarks.set(marks.key, marks); else liveMarks.delete(marks.key);
  dirtyExtent(marks.summary);
}
function bareRun(): Extract<WorkingPlace, { kind: 'bare' }> {
  const row = node('div', undefined, 'run working'), line = node('div', undefined, 'line'), sum = node('span', undefined, 'sum');
  line.append(sum); row.append(line); return { kind: 'bare', row, line, sum };
}
function trailingOwner() {
  for (const seq of [...order].reverse()) {
    const part = runParts(items.get(seq), visible(seq)).at(-1);
    if (part) { const owner = part.kind !== 'boundary' ? runOf(runContext(), part.source) : undefined; return owner; }
  }
}
function run(input: Step[]) {
  const tail = trailingOwner(), first = input[0];
  const adopt = working?.place.kind === 'bare' && tail && first.key === sourceKey(tail) ? working.place : undefined;
  const { row: view, line, sum: summary } = adopt ?? bareRun(), names = node('span', undefined, 'names'), time = node('span', undefined, 'time'), children = node('div', undefined, 'steps');
  view.classList.remove('working'); summary.insertBefore(names, summary.firstChild); line.append(time);
  const marks: RunMarks = { key: rowKey({ kind: 'run', source: first.kind === 'block' ? { kind: 'block', seq: first.item.seq, index: first.index } : { kind: 'item', seq: first.item.seq } }), links: '', cwd: '', summary, names, namesKey: '', time, children, steps: [] };
  fold(view, marks.key, line, children, undefined, 'open', reconcileWorking);
  runMarks.set(view, marks); if (adopt && working) working.place = { kind: 'run', owner: view };
  patchRun(marks, input); return view;
}
function removeRow(view: HTMLElement) {
  const before = view.previousElementSibling;
  if (before instanceof HTMLElement) { rhythmPending.add(before); dirtyExtent(before); }
  dirtyExtent(view.parentElement ?? view);
  extentDirty.delete(view); view.remove();
}
function clearWorking() {
  if (working?.place.kind === 'bare') removeRow(working.place.row);
  if (working) { dirtyExtent(working.primary); working.primary.remove(); working.extra.forEach(mark => { dirtyExtent(mark); mark.remove(); }); working = undefined; }
}
function lastRun() { const source = trailingOwner(); return source ? openers.get(rowKey({ kind: 'run', source }))?.view : undefined; }
function reconcileWorking() {
  const since = state.working && state.view.type !== 'job' && state.compaction !== 'running' ? state.since : undefined;
  const tail = since === undefined ? undefined : lastRun();
  let endsInRun = false;
  for (const seq of [...order].reverse()) {
    const shown = visible(seq), part = shown && runParts(shown, shown).at(-1);
    if (part) { endsInRun = part.kind !== 'boundary'; break; }
  }
  element('tail-slot').hidden = state.view.type === 'job' || endsInRun && !(since !== undefined && !tail);
  if (since === undefined) { clearWorking(); return; }
  if (working?.view !== state.view.id || working.since !== since) {
    clearWorking(); working = { view: state.view.id, since, primary: dots(), place: bareRun(), extra: new Map() };
  }
  const turn = working, spots: Spot[] = [];
  if (tail) {
    if (turn.place.kind === 'bare' && turn.place.row !== tail) removeRow(turn.place.row);
    turn.place = { kind: 'run', owner: tail };
    for (const marks of liveMarks.values()) {
      const live = marks.steps.filter(step => step.live), open = folds.get(marks.key) === true;
      if (!open) spots.push({ key: 'sum:' + marks.key, parent: marks.summary, before: null });
      if (open || live.length > 1) for (const step of live) spots.push({ key: 'step:' + step.key, parent: step.sum, before: step.after.nextSibling });
    }
    if (!spots.length) { const marks = runMarks.get(tail); if (marks) spots.push({ key: 'sum:' + marks.key, parent: marks.summary, before: null }); }
  } else {
    if (turn.place.kind !== 'bare') turn.place = bareRun();
    const { row, sum } = turn.place, slot = element('tail-slot');
    if (row.parentNode !== slot) { removeRow(row); slot.append(row); }
    spots.push({ key: 'bare', parent: sum, before: null });
  }
  const place = (mark: HTMLElement, { parent, before }: Omit<Spot, 'key'>) => {
    if (before !== mark && (mark.parentNode !== parent || mark.nextSibling !== before)) { dirtyExtent(mark); parent.insertBefore(mark, before); dirtyExtent(parent); }
  };
  if (spots[0]) place(turn.primary, spots[0]);
  const extra = new Map(spots.slice(1).map(spot => [spot.key, spot]));
  for (const [key, mark] of turn.extra) if (!extra.has(key)) { dirtyExtent(mark); mark.remove(); turn.extra.delete(key); }
  for (const [key, spot] of extra) { let mark = turn.extra.get(key); if (!mark) { mark = dots(); turn.extra.set(key, mark); } place(mark, spot); }
}
function reconcileRuns() {
  const context = runContext(), groups = new Map<string, Step[]>(), touched = new Set<number>(), links = JSON.stringify(state.agents);
  for (const seq of [...views.keys()].sort((a, b) => a - b)) {
    touched.add(seq);
    const entry = views.get(seq); if (!entry) continue;
    for (const part of runParts(items.get(seq), visible(seq))) if (part.kind !== 'boundary' && runOf(context, part.source)) {
      const key = sourceKey(part.source), owner = sourceKey(runOwner(context, part.source)), steps = groups.get(owner) ?? [];
      const item = visible(seq); if (!item) continue;
      let step: StepInput | undefined;
      if (part.kind === 'notice') { const row = noticeOf(item); if (row) step = { kind: 'notice', item, row }; }
      else if (part.source.kind === 'block' && item.kind === 'assistant') {
        const index = part.source.index, block = item.blocks[index];
        if (block.type !== 'text') step = { kind: 'block', item, block, index };
      } else if (item.kind === 'agent') step = { kind: 'agent', item };
      else if (item.kind === 'job') step = { kind: 'job', item };
      if (step) { steps.push({ ...step, key, slots: entry.slots }); groups.set(owner, steps); }
    }
  }
  for (const [key, steps] of groups) {
    const owner = views.get(steps[0].item.seq)?.slots.get(key);
    if (owner?.type !== 'run') continue;
    const current = owner.view.firstElementChild;
    let marks = current instanceof HTMLElement ? runMarks.get(current) : undefined;
    if (!marks) { const next = run(steps); owner.view.replaceChildren(next); dirtyExtent(owner.view); marks = runMarks.get(next); }
    else {
      const records = marks.steps;
      if (marks.links !== links || marks.cwd !== displayPath(state.cwd) || records.length !== steps.length || steps.some((step, index) => {
        const previous = records[index]?.current;
        return !previous || previous.key !== step.key || (step.kind === 'block' ? previous.kind !== 'block' || previous.block !== step.block || previous.item.final !== step.item.final || previous.item.stop !== step.item.stop || previous.item.ended !== step.item.ended : previous.kind !== step.kind || previous.item !== step.item);
      })) patchRun(marks, steps, links);
      else steps.forEach((step, index) => { records[index].current = step; });
    }
    for (const step of steps.slice(1)) {
      const slot = views.get(step.item.seq)?.slots.get(step.key);
      if (slot?.type === 'run' && slot !== owner && slot.view.childNodes.length) {
        const first = slot.view.firstElementChild; if (first instanceof HTMLElement) liveMarks.delete(runMarks.get(first)?.key ?? '');
        dirtyExtent(slot.view);
        if (marks) { rescue(slot.view, marks.summary); dirtyExtent(marks.summary); }
        clear(slot.view);
      }
    }
  }
  return touched;
}
type NoticeContent = { type: 'text'; text: string } | { type: 'markdown'; text: string } | { type: 'details'; text: string; body: HTMLElement } | { type: 'lead'; lead: string; preview: string; body: HTMLElement } | { type: 'inline'; head: () => HTMLElement[] };
type NoticeRow = { key: string; at: number; level?: 'warning' | 'error'; content: NoticeContent };
function noticeRow(input: NoticeRow | NoticeData, bodyOnly = false) {
  if (input.content.type === 'command') return noticeRow(commandNotice({ seq: input.content.seq, at: input.at, result: input.content.result }, noticeText({ key: input.key, at: input.at, name: 'command', content: input.content })), bodyOnly);
  if (input.content.type === 'summary') return noticeRow({ ...input, content: { type: 'lead', lead: input.content.lead, preview: ' · ' + input.content.text.split('\n')[0], body: paragraphs(input.content.text) } }, bodyOnly);
  const { key, at, level, content } = input;
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
  if (bodyOnly) { if (!more) clear(details); return details; }
  line.append(tx, node('time', timestamp(at)));
  if (more) row.classList.add('more'); else { fits.set(tx, row); fitPending.add(tx); }
  fold(row, key, line, details);
  return row;
}
function paragraphs(text: string) {
  const body = node('div');
  for (const paragraph of text.split(/\n\s*\n/)) body.append(node('p', paragraph.trim()));
  return body;
}
function commandNotice(item: Pick<Extract<WireItem, { kind: 'command' }>, 'seq' | 'at' | 'result'>, text: string): NoticeRow {
  const key = 'notice:' + item.seq, at = item.at, result = item.result;
  switch (result.type) {
    case 'copy': return { key, at, content: { type: 'text', text } };
    case 'export': {
      const head = () => { const path = node('span', result.path, 'path preview-file'); previewFile(path, '/steps/' + item.seq + '/0/file'); return [node('span', text.slice(0, -result.path.length)), path]; };
      return { key, at, content: { type: 'inline', head } };
    }
    case 'session': {
      const grid = node('div', undefined, 'kv');
      for (const [name, value, mono] of sessionFields(result)) grid.append(node('b', name), node('span', value, mono ? 'path' : ''));
      return { key, at, content: { type: 'details', text, body: grid } };
    }
    case 'compaction': switch (result.state.type) {
      case 'running': return { key, at, content: { type: 'inline', head: () => [node('span', text), dots()] } };
      case 'cancelled': return { key, at, content: { type: 'text', text } };
      case 'failed': return { key, at, level: 'error', content: { type: 'text', text } };
    }
  }
}
function installItem(item: WireItem) {
  const old = items.get(item.seq);
  const rawKey = runParts(item, item).map(part => part.kind === 'boundary' ? 'boundary' : part.kind + ':' + sourceKey(part.source) + ':' + (part.source.kind === 'block' && item.kind === 'assistant' ? item.blocks[part.source.index].topic ?? topicItems.get(item.seq)?.topics[0] ?? '' : item.kind === 'agent' || item.kind === 'job' ? item.topic ?? '' : '')).join('|') + ':' + (item.kind === 'assistant' ? item.blocks.filter(visibleText).map(block => block.topic ?? topicItems.get(item.seq)?.topics[0] ?? '').join('|') : item.kind === 'user' ? item.topic ?? topicItems.get(item.seq)?.topics.join('|') ?? '' : '');
  const changedRun = runKeys.get(item.seq) !== rawKey;
  runKeys.set(item.seq, rawKey);
  items.set(item.seq, item);
  if (item.kind === 'assistant' && !item.final || item.kind === 'command' && item.result.type === 'compaction' && item.result.state.type === 'running') live.add(item.seq); else live.delete(item.seq);
  first = first === undefined ? item.seq : Math.min(first, item.seq);
  let related: number | undefined;
  if (item.kind === 'topics') {
    const previous = topicItems.get(item.target);
    if (!previous || previous.seq < item.seq || previous.seq === item.seq && previous.revision < item.revision) {
      topicItems.set(item.target, item);
      if (!previous || previous.topics.length !== item.topics.length || previous.topics.some((name, index) => name !== item.topics[index])) related = item.target;
    }
  }
  if (item.kind === 'annotations') {
    let blocks = annotationItems.get(item.reply.seq);
    if (!blocks) { blocks = new Map(); annotationItems.set(item.reply.seq, blocks); }
    const previous = blocks.get(item.reply.block);
    if (!previous || previous.seq < item.seq) { blocks.set(item.reply.block, item); related = item.reply.seq; annotated = true; }
  }
  return { old, changedRun, related };
}
function acceptHistory(rows: readonly WireItem[]) {
  if (!rows.length) return;
  const related = new Set<number>();
  for (const item of rows) { const result = installItem(item); if (result.related !== undefined) related.add(result.related); }
  for (const seq of related) { const item = items.get(seq); if (item) items.set(seq, { ...item }); }
  allRuns.owners.clear(); topicContext.topics = undefined;
  projections.clear(); segmentCache.clear(); owners.clear(); extents.clear(); table = undefined;
  order.length = 0;
  for (const seq of [...items.keys()].sort((a, b) => a - b)) { if (visible(seq)) order.push(seq); dirty.add(seq); }
  for (const seq of views.keys()) if (!visible(seq)) unmountRow(seq);
  for (const item of rows) changedItem(item.seq, false);
  windowDirty = true;
  after = Math.max(after, (first ?? 0) - 1);
  while (items.get(after + 1)?.final) after++;
  schedule();
}
function accept(item: WireItem) {
  const previous = visible(item.seq);
  const priorInput = !items.has(item.seq) && shownFilter && (item.kind === 'user' || item.kind === 'agent' || item.kind === 'job') ? latestTopicInput() : undefined;
  if (item.kind === 'topics') projections.set(item.target, visible(item.target));
  const { old, changedRun, related } = installItem(item);
  if (changedRun) { topicContext.topics = undefined; invalidateRuns(allRuns, item.seq); }
  if (old !== item || changedRun) projections.delete(item.seq);
  const shown = visible(item.seq);
  if (shown && !previous) order.splice(orderIndex(item.seq), 0, item.seq);
  else if (!shown && previous) { const position = order.indexOf(item.seq); if (position >= 0) order.splice(position, 1); unmountRow(item.seq); }
  if (!views.has(item.seq)) extents.delete(item.seq);
  const topology = (raw: WireItem | undefined, shown: WireItem | undefined) => runParts(raw, shown).map(part => part.kind === 'boundary' ? 'boundary' : part.kind + ':' + sourceKey(part.source)).join('|');
  const same = old && topology(old, previous) === topology(item, shown);
  const appended = !old && shown && table && order.at(-1) === item.seq;
  const affected = same ? item.seq : invalidateRuns(runContext(), item.seq);
  for (let at = item.seq; at <= affected; at++) { segmentCache.delete(at); if (!views.has(at)) extents.delete(at); }
  if (!same && !appended) table = undefined;
  else if (appended && table) appendRow(table, item.seq);
  else if (table) patched.add(item.seq);
  windowDirty = true;
  if (related !== undefined) {
    const target = items.get(related);
    if (target) { accept({ ...target }); if (item.kind === 'topics') changedItem(target.seq, false); }
  }
  dirty.add(item.seq);
  for (const seq of views.keys()) {
    if (seq > item.seq) dirty.add(seq);
  }
  if (item.kind === 'topics' || item.kind === 'assistant' && old?.kind === 'assistant' && item.blocks.some((block, index) => block.topic !== old.blocks[index]?.topic)) topics.render();
  if (priorInput?.kind === 'user' && priorInput.seq !== item.seq) accept({ ...priorInput });
  if (shownFilter && changedRun) {
    let from = item.seq, to = item.seq;
    while (from > 0) {
      const previous = items.get(from - 1); if (!previous) break;
      from--; if (runParts(previous, previous).some(part => part.kind === 'boundary')) break;
    }
    while (items.has(to + 1)) {
      to++; const next = items.get(to);
      if (runParts(next, next).some(part => part.kind === 'boundary')) break;
    }
    for (let at = from; at <= to; at++) { projections.delete(at); owners.delete(at); segmentCache.delete(at); extents.delete(at); }
    for (let at = from; at <= to; at++) {
      const shown = visible(at), position = order.indexOf(at);
      if (shown && position < 0) order.splice(orderIndex(at), 0, at);
      else if (!shown && position >= 0) { order.splice(position, 1); unmountRow(at); }
      dirty.add(at);
    }
    table = undefined;
  }
  after = Math.max(after, (first ?? 0) - 1);
  while (items.get(after + 1)?.final) after++;
  schedule();
}
function syncChildren(parent: HTMLElement, children: HTMLElement[]) {
  children.forEach((child, index) => { if (parent.childNodes[index] !== child) parent.insertBefore(child, parent.childNodes[index] ?? null); });
  while (parent.childNodes.length > children.length) { const extra = parent.lastChild; if (extra) unwatch(extra); extra?.remove(); }
}
function renderItem(item: WireItem) {
  const previous = views.get(item.seq), warning = pathWarnings.get(item.seq), filter = shownFilter;
  const context = runContext(), runs = runParts(items.get(item.seq), item).map(part => part.kind === 'boundary' ? 'boundary' : part.kind + ':' + sourceKey(part.source) + ':' + (runOf(context, part.source) ? sourceKey(runOwner(context, part.source)) : '')).join('|');
  if (previous?.item === item && previous.warning === warning && previous.filter === filter && previous.runs === runs) return false;
  const view = previous?.view ?? node('div');
  view.dataset.seq = String(item.seq);
  const refs = item.kind === 'user' ? item.images : item.kind === 'assistant' ? item.blocks.flatMap(block => block.type === 'tool' && 'result' in block.state ? block.state.result?.images ?? [] : []) : [];
  const ids = new Set(refs.map(ref => 'image:' + ref.id));
  const children: HTMLElement[] = [], slots = new Map([...previous?.slots ?? []].filter(([key]) => ids.has(key)));
  let steps: Step[] = [], parts = children;
  let section: HTMLElement | undefined, sectionTopic: TopicName | undefined, hasHeader = false;
  const finishSection = () => {
    if (section) syncChildren(section, parts);
    section = undefined; parts = children;
  };
  const flush = () => {
    if (steps.length) {
      const key = steps[0].key, saved = previous?.slots.get(key);
      const slot: Slot = saved?.type === 'run' ? saved : { type: 'run', view: node('div') };
      slots.set(key, slot); parts.push(slot.view);
    }
    steps = [];
  };
  const startSection = (name: TopicName | undefined, index: number) => {
    if (filter) { if (section) { flush(); finishSection(); } sectionTopic = undefined; return; }
    if (section && sectionTopic === name) return;
    flush(); finishSection(); sectionTopic = name;
    section = [...previous?.view.children ?? []].find((child): child is HTMLElement => child instanceof HTMLElement && child.classList.contains('reply-section') && child.dataset.block === String(index));
    section ??= node('div', undefined, 'reply-section'); section.dataset.block = String(index);
    children.push(section); parts = [];
  };
  if (item.kind === 'assistant') {
    if (item.blocks.some(block => block.topic) || topicItems.get(item.seq)?.topics.length) topics.cancelMessage(item.seq);
    view.className = 'assistant';
    item.blocks.forEach((block, index) => {
      if (block.type === 'text' && !visibleText(block)) return;
      const previousStep = steps.at(-1), context = runContext();
      if (block.type === 'text' || previousStep?.kind === 'block' && sourceKey(runOwner(context, { kind: 'block', seq: item.seq, index })) !== sourceKey(runOwner(context, { kind: 'block', seq: item.seq, index: previousStep.index }))) flush();
      if (block.type === 'text') startSection(block.topic, index);
      const key = item.seq + ':' + index;
      if (block.type === 'text') {
        flush();
        const message = prose(key, block.text, item.final || index < item.blocks.length - 1, annotationItems.get(item.seq)?.get(index), 'assistant');
        const header = message.querySelector('.message-header');
        if (!header?.contains(topics.namingChip() ?? null)) header?.remove();
        if (!parts.some(part => part.classList.contains('msg'))) { if (!message.querySelector('.message-header')) message.prepend(topics.header(block.topic, hasHeader ? undefined : item.at, item.blocks.some(block => block.topic) || topicItems.get(item.seq)?.topics.length ? undefined : { kind: 'message', seq: item.seq, key })); hasHeader = true; }
        parts.push(message);
      }
      else steps.push({ kind: 'block', block, item, key, index, slots });
    });
    flush(); finishSection();
    const error = noticeOf(item);
    if (error) {
      if (runOf(runContext(), { kind: 'item', seq: item.seq })) {
        const key = sourceKey({ kind: 'item', seq: item.seq }), slot: Slot = { type: 'run', view: node('div') };
        slots.set(key, slot); children.push(slot.view);
      } else children.push(noticeRow(error));
    }
  } else {
    view.className = 'msg ' + item.kind;
    if (item.kind === 'user') {
      const names = topicItems.get(item.seq)?.topics ?? [];
      const header = topics.header(item.topic ?? (names.length === 1 ? names[0] : undefined), item.at, item.topic || names.length ? undefined : { kind: 'message', seq: item.seq, key: item.seq + ':user' });
      const text = node('div', undefined, 't'); text.append(prose(item.seq + ':user', item.text, true, undefined, 'user'));
      if (item.images.length) { const images = thumbnails(item.images, () => slots); images.load(); text.append(images.view); }
      const paths = item.attachments.filter(file => file.kind === 'file').map(file => file.path);
      if (paths.length) text.append(node('div', paths.join('\n'), 'paths'));
      children.push(header, text);
    } else if (item.kind === 'agent' || item.kind === 'job' || noticeOf(item) && runOf(runContext(), { kind: 'item', seq: item.seq })) {
      view.className = '';
      const key = sourceKey({ kind: 'item', seq: item.seq }), saved = previous?.slots.get(key);
      const slot: Slot = saved?.type === 'run' ? saved : { type: 'run', view: node('div') };
      slots.set(key, slot); children.push(slot.view);
    }
    else if (item.kind === 'annotations' || item.kind === 'topics') { view.hidden = true; }
    else if (item.kind === 'bash') { view.className = ''; children.push(commandRun(item, 'bash:' + item.seq).view); }
    else { const row = noticeOf(item); view.className = ''; if (row) children.push(noticeRow(row)); }
  }
  if (warning) {
    if (item.kind === 'user') { const user = node('div', undefined, 'msg user'); user.append(...children); children.splice(0, children.length, user); view.className = ''; }
    children.push(noticeRow({ key: 'path:' + item.seq, at: item.at, level: 'warning', content: { type: 'text', text: warning } }));
  }
  syncChildren(view, children);
  views.set(item.seq, { view, item, warning, slots, filter, runs });
  if (!previous) {
    const container = element('items'), next = [...views.keys()].filter(seq => seq > item.seq).sort((a, b) => a - b)[0];
    container.insertBefore(view, views.get(next)?.view ?? null);
    if (view.previousElementSibling) dirtyExtent(view.previousElementSibling);
  }
  dirtyExtent(view);
  return true;
}
function orderIndex(seq: number) {
  let low = 0, high = order.length;
  while (low < high) { const middle = (low + high) >> 1; if (order[middle] < seq) low = middle + 1; else high = middle; }
  return low;
}
const lineHeight = () => parseFloat(getComputedStyle(element('items')).lineHeight);
function readMetrics() { measured = { width: element('items').clientWidth, lh: lineHeight() }; }
function extentOf(t: Table, seq: number) {
  let extent = extents.get(seq);
  if (!extent) { const item = visible(seq); extent = { kind: 'estimated', px: !item ? 0 : estimateExtent(item, measured.lh, runContext()) + (scrollDecision.divider?.seq === seq && scrollDecision.divider?.row && !sameRow(unitRows(seq)[0], scrollDecision.divider?.row) ? measured.lh + 28 : 0) }; extents.set(seq, extent); }
  return extent.px + (t.divider?.before === seq ? t.divider.px : 0);
}
function groupsAfter(t: Table, seq: number) {
  const context = runContext();
  for (const part of runParts(items.get(seq), visible(seq))) if (part.kind !== 'boundary') {
    const owner = runOf(context, part.source);
    if (!owner) continue;
    if (owner.seq === seq) continue;
    const last = t.groups.at(-1);
    if (last && last.to >= owner.seq) last.to = seq;
    else t.groups.push({ from: owner.seq, to: seq });
  }
}
function refreshTable(t: Table) {
  let low = order.length;
  for (const seq of patched) { const at = t.index.get(seq); if (at !== undefined) { extentOf(t, seq); low = Math.min(low, at); } }
  patched.clear();
  for (let at = low; at < order.length; at++) t.starts[at + 1] = t.starts[at] + extentOf(t, order[at]);
}
function ensureTable(): Table {
  if (table) { if (patched.size) refreshTable(table); return table; }
  patched.clear();
  if (!measured.lh) readMetrics();
  const t: Table = { index: new Map(), starts: [0], groups: [], divider: scrollDecision.divider?.seq === undefined || scrollDecision.divider?.row && !sameRow(unitRows(scrollDecision.divider.seq)[0], scrollDecision.divider.row) ? undefined : { before: scrollDecision.divider?.seq, px: dividerPx ?? measured.lh + 28 } };
  for (const seq of order) { groupsAfter(t, seq); t.index.set(seq, t.index.size); t.starts.push(t.starts[t.starts.length - 1] + extentOf(t, seq)); }
  return table = t;
}
function appendRow(t: Table, seq: number) {
  groupsAfter(t, seq); t.index.set(seq, t.index.size);
  t.starts.push(t.starts[t.starts.length - 1] + extentOf(t, seq));
}
const rowTop = (seq: number) => { const t = ensureTable(); return (t.starts[t.index.get(seq) ?? 0] ?? 0) + (t.divider?.before === seq ? t.divider.px : 0); };
function dirtyExtent(target: Element) {
  const list = element('items');
  let row: Element | null = target;
  while (row && row.parentNode !== list) row = row.parentElement;
  if (row instanceof HTMLElement && row.dataset.seq !== undefined) { extentDirty.add(row); schedule(); }
}
function invalidateExtents() {
  readMetrics(); extents.clear(); dividerPx = undefined; table = undefined; windowDirty = true;
  for (const entry of views.values()) dirtyExtent(entry.view);
  for (const target of fits.keys()) fitPending.add(target);
  for (const memo of texts.values()) { const tail = memo.reveal?.tail; if (tail) { tail.units = unitsOf(tail.view, tail.block.token); revealDirty = true; } }
  schedule();
}
function flushExtents() {
  const list = element('items');
  if (list.hidden || state.view.type === 'job') return false;
  const { width, lh } = measured, rows = [...extentDirty];
  extentDirty.clear();
  const next = (row: Element) => { for (let at = row.nextElementSibling; at; at = at.nextElementSibling) if (at instanceof HTMLElement && !at.hidden) return at; return null; };
  let changed = false;
  for (const row of rows) {
    if (!row.isConnected || row.hidden || row.dataset.seq === undefined) continue;
    const seq = Number(row.dataset.seq), after = next(row), joined = after instanceof HTMLElement && after.dataset.seq !== undefined;
    const earlier = extents.get(seq), bounds = row.getBoundingClientRect();
    const px = joined ? after.getBoundingClientRect().top - bounds.top : bounds.height + (parseFloat(getComputedStyle(row).marginBottom) || 0);
    changed ||= earlier?.kind !== 'measured' || earlier.px !== px;
    if (earlier?.kind === 'measured' && earlier.px === px && earlier.width === width && earlier.lh === lh) continue;
    extents.set(seq, { kind: 'measured', width, lh, px });
    if (table) patched.add(seq);
    windowDirty = true;
  }
  const after = divider && next(divider), gapPx = after instanceof HTMLElement && after.dataset.seq !== undefined && divider ? after.getBoundingClientRect().top - divider.getBoundingClientRect().top : undefined;
  if (gapPx !== undefined && gapPx !== dividerPx) {
    dividerPx = gapPx; windowDirty = true; changed = true;
    if (table?.divider) { table.divider.px = gapPx; patched.add(table.divider.before); }
  }
  if (table && patched.size) refreshTable(table);
  return changed;
}
function liveRange(t: Table) {
  let from = order.length && (state.working && state.view.type !== 'job' || state.bash.length) ? order[order.length - 1] : Infinity;
  for (const seq of live) from = Math.min(from, seq);
  for (const [target, { seq }] of animating) if (element('items').contains(target)) from = Math.min(from, seq); else animating.delete(target);
  const at = t.index.get(from), group = groupAt(t.groups, from);
  return at === undefined ? undefined : { lo: group ? t.index.get(group.from) ?? at : at, hi: order.length - 1 };
}
function unmountRow(seq: number) {
  const entry = views.get(seq);
  if (!entry) return;
  views.delete(seq); removeRow(entry.view);
  unwatch(entry.view);
  for (const registry of [openers, fenceOpeners]) for (const [key, opener] of [...registry]) if (entry.view.contains(opener.view)) registry.delete(key);
  for (const [key, memo] of [...texts]) if (key.startsWith(seq + ':')) { texts.delete(key); revealing.delete(memo); }
  for (const [key, marks] of [...liveMarks]) if (entry.view.contains(marks.summary)) liveMarks.delete(key);
}
function windowStep(geo: Geo, rendered: number[]) {
  const t = ensureTable(), top = scrollWindow(scrolling, item => item.kind === 'message' && t.index.has(item.seq) ? rowTop(item.seq) : undefined, geo.top - geo.origin, Math.max(0, t.starts[order.length] - geo.viewport));
  windowDirty = false;
  const want = windowOf(order, t.starts, top, geo.viewport, geo.viewport, t.groups), tail = liveRange(t), chosen = selected && { lo: t.index.get(selected.from), hi: t.index.get(selected.to) };
  const pins = [tail, chosen && chosen.lo !== undefined && chosen.hi !== undefined ? { lo: chosen.lo, hi: chosen.hi } : undefined].filter(range => range !== undefined);
  const lo = want ? t.index.get(want.from) ?? 0 : 0, hi = want ? t.index.get(want.to) ?? -1 : -1;
  const inPins = (at: number) => pins.some(range => at >= range.lo && at <= range.hi), keep = (at: number) => at >= lo && at <= hi || inPins(at);
  const at = (seq: number) => t.index.get(seq);
  for (const seq of [...views.keys()]) { const index = at(seq); if (index === undefined || !keep(index)) unmountRow(seq); }
  const mount = (index: number) => {
    const seq = order[index];
    if (views.has(seq)) return;
    const item = visible(seq);
    if (item && renderItem(item)) rendered.push(seq);
  };
  const bounds = (index: number): [number, number] => { const group = groupAt(t.groups, order[index]); return group ? [at(group.from) ?? index, at(group.to) ?? index] : [index, index]; };
  let pivot = 0;
  { let low = 0, high = order.length; while (low < high) { const middle = (low + high) >> 1; if (t.starts[middle + 1] > top) high = middle; else low = middle + 1; } pivot = Math.max(lo, Math.min(hi, low)); }
  const have = [...views.keys()].map(seq => at(seq) ?? -1).filter(index => index >= lo && index <= hi && !inPins(index)).sort((x, y) => x - y);
  const runs: { lo: number; hi: number }[] = [];
  for (const index of have) { const last = runs.at(-1); if (last && last.hi === index - 1) last.hi = index; else runs.push({ lo: index, hi: index }); }
  const distance = (run: { lo: number; hi: number }) => pivot < run.lo ? run.lo - pivot : pivot > run.hi ? pivot - run.hi : 0;
  const best = runs.reduce<{ lo: number; hi: number } | undefined>((chosen, run) => !chosen || distance(run) < distance(chosen) ? run : chosen, undefined);
  for (const run of runs) if (run !== best) for (let index = run.lo; index <= run.hi; index++) unmountRow(order[index]);
  if (want) {
    const deadline = performance.now() + 8;
    let low = best?.lo ?? pivot, high = best?.hi ?? pivot - 1;
    if (!best) { const [from, to] = bounds(pivot); for (let index = from; index <= to; index++) mount(index); low = from; high = to; }
    while ((low > lo || high < hi) && performance.now() < deadline) {
      const down = high < hi, up = low > lo;
      const below = down && (!up || high < pivot || low <= pivot && Math.max(0, t.starts[high + 1] - top - geo.viewport) <= Math.max(0, top - t.starts[low]));
      if (below) { const to = bounds(high + 1)[1]; for (let index = high + 1; index <= to; index++) mount(index); high = to; }
      else { const from = bounds(low - 1)[0]; for (let index = from; index < low; index++) mount(index); low = from; }
    }
    if (low > lo || high < hi) windowDirty = true;
  }
  for (const range of pins) for (let index = range.lo; index <= range.hi; index++) mount(index);
  layoutWindow(t);
}
function layoutWindow(t: Table) {
  const list = element('items'), indexes = [...views.keys()].map(seq => t.index.get(seq) ?? -1).sort((x, y) => x - y);
  const ranges: { lo: number; hi: number }[] = [];
  for (const index of indexes) { const last = ranges.at(-1); if (last && last.hi === index - 1) last.hi = index; else ranges.push({ lo: index, hi: index }); }
  const first = ranges[0], last = ranges.at(-1);
  list.style.paddingTop = (first ? t.starts[first.lo] : 0) + 'px';
  list.style.paddingBottom = (last ? t.starts[order.length] - t.starts[last.hi + 1] : 0) + 'px';
  gaps.splice(Math.max(0, ranges.length - 1)).forEach(extra => { if (extra.previousElementSibling) dirtyExtent(extra.previousElementSibling); extra.remove(); });
  ranges.slice(1).forEach((range, index) => {
    const next = views.get(order[range.lo])?.view, between = gaps[index] ??= node('div', undefined, 'gap');
    between.style.height = t.starts[range.lo] - t.starts[ranges[index].hi + 1] + 'px';
    if (next && between.nextSibling !== next) { if (between.previousElementSibling) dirtyExtent(between.previousElementSibling); list.insertBefore(between, next); if (between.previousElementSibling) dirtyExtent(between.previousElementSibling); }
  });
  mountedSpans = ranges.map(range => ({ start: t.starts[range.lo], end: t.starts[range.hi + 1] }));
}
function rhythm(changed: Iterable<Element> = []) {
  const pending = new Set([...rhythmPending, ...changed]), roots = new Set<HTMLElement>(), list = element('items'), lines = '.run,.nrow,.cmdrun,.step,.agent-step,.job-step';
  const cached = new Map<HTMLElement, HTMLElement[]>();
  rhythmPending.clear();
  for (let root of pending) {
    while (root.parentNode instanceof HTMLElement && root.parentNode !== list) root = root.parentNode;
    if (root instanceof HTMLElement && root.parentNode === list) roots.add(root);
  }
  const parts = (root: HTMLElement) => {
    const known = cached.get(root); if (known) return known;
    const blocks: HTMLElement[] = [];
    const collect = (view: HTMLElement) => {
      if (view.hidden) return;
      if (view.matches('.msg,' + lines + ',.gap,.newmsgs')) blocks.push(view);
      else for (const child of view.children) if (child instanceof HTMLElement) collect(child);
    };
    collect(root); cached.set(root, blocks); return blocks;
  };
  const adjacent = (start: Element | null, previous: boolean) => {
    for (let row = start; row; row = previous ? row.previousElementSibling : row.nextElementSibling) if (row instanceof HTMLElement) {
      const blocks = parts(row), edge = previous ? blocks.at(-1) : blocks[0];
      if (edge) return edge;
    }
  };
  for (const root of roots) {
    const before = adjacent(root.previousElementSibling, true), after = adjacent(root.nextElementSibling, false);
    const blocks = before ? [before, ...parts(root)] : parts(root);
    blocks.forEach((view, index) => {
      if (view.matches('.gap,.newmsgs')) return;
      const next = blocks[index + 1] ?? after, spacing = view.matches(lines) && next?.matches(lines) ? 'compact' : 'block';
      if (view.dataset.rhythm !== spacing) { view.dataset.rhythm = spacing; dirtyExtent(view); }
    });
  }
}
function renderDirty(geo: Geo = geometry()) {
  const reset = resetting;
  if (resetting) {
    resetting = false;
    const list = element('items');
    extentDirty.clear();
    if (working && working.view === state.view.id && working.since === state.since && state.working) {
      if (working.place.kind === 'run') {
        const row = working.place.owner, line = row.firstElementChild, sum = runMarks.get(row)?.summary;
        if (sum && line instanceof HTMLElement) { sum.replaceChildren(working.primary); line.replaceChildren(sum); row.replaceChildren(line); row.className = 'run working'; working.place = { kind: 'bare', row, line, sum }; }
      }
      working.extra.forEach(mark => mark.remove()); working.extra.clear();
    } else clearWorking();
    views.clear(); texts.clear(); openers.clear(); fenceOpeners.clear(); liveMarks.clear(); revealing.clear(); revealPreparation.clear(); growing.length = 0; measuredHolds.clear(); fits.clear(); fitPending.clear(); animating.clear(); openFences.clear();
    list.replaceChildren(); divider = undefined; gaps.length = 0; mountedSpans = []; table = undefined; windowDirty = true;
  }
  for (const key of stale) { const memo = texts.get(key); if (memo) revealing.delete(memo); texts.delete(key); }
  stale.clear();
  const seqs = [...dirty].sort((a, b) => a - b), rendered: number[] = [];
  dirty.clear();
  if (windowDirty && state.view.type !== 'job') windowStep(geo, rendered);
  for (const seq of seqs) { const item = visible(seq); if (item && views.has(seq) && renderItem(item)) rendered.push(seq); }
  const touched = rendered.length || seqs.length ? reconcileRuns() : [];
  if (annotated) { annotated = false; update(editor.text()); }
  if (reset) { refreshBash(); refreshComposer(); }
  reconcileWorking(); rhythm(new Set([...seqs, ...rendered].flatMap(seq => { const view = views.get(seq)?.view; return view ? [view] : []; })));
  for (const seq of new Set([...seqs, ...seqs.map(seq => seq + 1), ...touched])) changedItem(seq, false);
  const older = element('older');
  if (older.hidden === transcriptHistory.more) older.hidden = !transcriptHistory.more;
  return reset;
}

function commandRun(value: Extract<WireItem, { kind: 'bash' }> | Bash, key: string) {
  const view = node('div', undefined, 'cmdrun'), line = node('div', undefined, 'line');
  const live = dots();
  const bang = node('span'), command = node('span'), meta = node('span', undefined, 'meta'), outcome = node('span'), time = node('span');
  meta.append(outcome, time); line.append(bang, command, meta);
  const output = node('div', undefined, 'out'), pre = node('pre'), footer = node('div', undefined, 'ft');
  output.append(pre, footer);
  if ('phase' in value && value.phase !== 'completed' && !folds.has(key)) folds.set(key, true);
  fold(view, key, line, output);
  const update = (value: Extract<WireItem, { kind: 'bash' }> | Bash) => {
    const running = 'phase' in value && value.phase !== 'completed';
    const result = 'phase' in value ? value.phase === 'completed' ? value.result : undefined : value.result;
    const failed = result?.exit !== undefined && result.exit !== 0;
    if (running) { if (bang.firstChild !== live) bang.replaceChildren(live); }
    else setText(bang, value.excludeFromContext ? '!!' : '!');
    const marker = running ? 'busy' : 'bang' + (value.excludeFromContext ? ' quiet' : '');
    if (bang.className !== marker) bang.className = marker;
    const title = value.excludeFromContext ? "not in the model's context" : '';
    if (bang.title !== title) bang.title = title;
    setText(command, value.command);
    const commandClass = 'cmd' + (failed ? ' err' : '');
    if (command.className !== commandClass) command.className = commandClass;
    setText(outcome, result?.cancelled ? 'cancelled' : failed ? 'exit ' + result?.exit : '');
    const outcomeClass = 'ex' + (failed && !result?.cancelled ? ' err' : '');
    if (outcome.className !== outcomeClass) outcome.className = outcomeClass;
    outcome.hidden = !outcome.textContent;
    setText(time, 'phase' in value ? duration((value.phase === 'completed' ? value.ended : Date.now()) - value.started) : '');
    setText(pre, result?.output.text ?? ('output' in value ? value.output.text : '')); pre.classList.toggle('live', running);
    footer.hidden = !(result?.truncated || result?.output.cut);
    setText(footer, result?.fullOutputPath ? '… full output: ' + result.fullOutputPath : '… output truncated');
    dirtyExtent(view);
  };
  update(value);
  return { view, update };
}
function refreshBash() {
  const ids = new Set(state.bash.map(item => item.id));
  for (const [id, card] of pendingBash) if (!ids.has(id)) { removeRow(card.view); pendingBash.delete(id); }
  for (const item of state.bash) {
    let card = pendingBash.get(item.id);
    if (!card) { card = commandRun(item, 'live-bash:' + item.id); pendingBash.set(item.id, card); }
    else card.update(item);
    if (!card.view.isConnected) { element('items').append(card.view); rhythmPending.add(card.view); }
  }
}
function refreshComposer() {
  if (state.view.type === 'job') { element('field').inert = true; composerFocus(); return; }
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
  draft.refresh();
  topics.renderComposer();
  const addressed = viewedName();
  editor.placeholder(state.life.type === 'starting' ? 'Starting pi…' : state.life.type === 'switching' ? 'Loading…' : running ? 'running… ⎋ cancels' : draft.hover && !state.edit ? 'Drop to attach' : hasFailed() ? 'koa could not start the agent' : working && state.compaction !== 'running' ? 'Steer ' + addressed + '…' : 'Message ' + addressed + '…');
  if (state.edit) element('composer').setAttribute('title', 'Editing in ' + state.edit.editor); else element('composer').removeAttribute('title');
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
  const classifying = state.queue.classifying.map(entry => ({ kind: entry.mode === 'steer' ? 'steer' : entry.mode === 'followUp' ? 'follow-up' : 'sending', entry }));
  const signature = JSON.stringify([entries, classifying]);
  if (shownQueue === signature) return;
  shownQueue = signature;
  const host = element('queue'); host.replaceChildren();
  const pendingRow = (kind: string, entry: QueuedPrompt) => {
    const row = node('div', undefined, 'qmsg user');
    row.dataset.kind = kind;
    row.append(node('div', markdownLine(entry.text), 't'));
    if (entry.attachments.length) { const count = node('span', undefined, 'att'); count.innerHTML = '<svg viewBox="0 0 16 16"><path d="M10.5 5.5 6 10a1.6 1.6 0 0 0 2.3 2.3l5-5a3.2 3.2 0 0 0-4.5-4.5l-5.2 5.2a4.8 4.8 0 0 0 6.8 6.8l4-4"/></svg>'; count.append(document.createTextNode(String(entry.attachments.length))); row.append(count); }
    return row;
  };
  for (const { kind, index, entry } of entries) {
    const row = pendingRow(kind, entry), close = node('button', undefined, 'attach-remove');
    close.type = 'button'; close.title = 'Remove from the queue'; close.setAttribute('aria-label', 'Remove from the queue');
    close.innerHTML = '<svg viewBox="0 0 10 10"><path d="m2 2 6 6m0-6-6 6"/></svg>';
    close.onclick = () => {
      close.disabled = true;
      const origin = state.sessionId;
      fetchJSON('/queue/remove', { sessionId: origin, kind, index, text: entry.text, ...(entry.topic ? { topic: entry.topic } : {}) }).catch(error => {
        const unsent = error?.body?.unsent;
        if (unsent && state.sessionId === origin) restoreQueued([...unsent.steering, ...unsent.followUp]);
        reportError(error); close.disabled = false;
      });
    };
    const label = node('span', kind, 'kind'); label.append(close); row.append(label);
    host.append(row);
  }
  for (const { kind, entry } of classifying) { const row = pendingRow(kind, entry), label = node('span', kind, 'kind'); label.append(dots()); row.append(label); host.append(row); }
}
function restoreQueued(entries: QueuedPrompt[]) {
  editor.setText([editor.text(), ...entries.map(entry => entry.text)].filter(Boolean).join('\n\n'));
  draft.restore(entries.flatMap(entry => entry.attachments));
  refreshComposer(); editor.focus();
}
let takingBack: Promise<void> | undefined;
const drafts = new Map<string, string>(memory?.drafts);
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
  transcriptHistory.cancel('request'); refreshTopicItems(); epoch = ''; after = -1;
  if (source) source.onmessage = source.onerror = source.onopen = null;
  source?.close(); clearTimeout(reconnect);
  connect();
}
function applyPatch(record: Patch, buffer: boolean) {
  const current = items.get(record.seq);
  if (!current) { if (buffer) transcriptHistory.buffer(record); return; }
  if (current.kind !== 'assistant') return resync();
  if (record.revision <= current.revision) return;
  if (record.baseRevision !== current.revision) return resync();
  const item = { ...current, blocks: current.blocks.slice(), revision: record.revision };
  Object.assign(item, { final: record.final, stop: record.stop, error: record.error, ended: record.ended });
  for (const change of record.blocks) {
    if ('block' in change) {
      const key = record.seq + ':' + change.index;
      item.blocks[change.index] = change.block;
      stale.add(key);
    }
    else {
      const block = item.blocks[change.index];
      if (block.type !== 'tool') item.blocks[change.index] = { ...block, text: block.text + change.suffix };
    }
  }
  accept(item);
}
let readerCatchup: object | undefined;
function catchUpReader() {
  if (scrolling.kind !== 'restoring' || scrolling.target.scope.sessionId !== state.sessionId) return;
  const operation = readerCatchup = {};
  const generation = scrolling.generation, session = state.sessionId, view = state.view.id, origin = epoch;
  if (!topics.filter() || !transcriptHistory.needsCatchUp(scrolling.target.last)) { enqueue({ type: 'catchup', generation, pending: false }); return; }
  enqueue({ type: 'catchup', generation, pending: true });
  void transcriptHistory.catchUp(scrolling.target.last).then(outcome => {
    if (readerCatchup === operation && outcome !== 'cancelled' && epoch === origin && state.sessionId === session && state.view.id === view) enqueue({ type: 'catchup', generation, pending: false });
  });
}
function apply(record: PageRecord) {
  if (record.type === 'reset') {
    readerCatchup = undefined;
    topics.cancel();
    pathWarnings.clear(); pathWarningEpoch++;
    editor.resetCompletion();
    find = undefined; selected = undefined; segmentCache.clear(); owners.clear(); epoch = record.epoch; after = -1; first = undefined; items.clear(); allRuns.owners.clear(); runKeys.clear(); topicContext.topics = undefined; order.length = 0; extents.clear(); live.clear(); dirty.clear(); stale.clear(); annotationItems.clear(); topicItems.clear(); projections.clear(); folds.clear(); transcriptHistory.cancel('request');
    resets++;
    enqueue({ type: 'reset' });
    lastMeasurement = undefined;
    resetting = true;
    refreshTopicItems();
    acceptHistory(record.items);
    transcriptHistory.reset(record);
    catchUpReader();
    if (topics.filter()) void transcriptHistory.reload();
    else void rendered().then(() => { if (epoch === record.epoch) transcriptHistory.fill(); });
    schedule();
  } else if (record.type === 'item') {
    const current = items.get(record.item.seq);
    if (!current && transcriptHistory.outside(record.item.seq)) { transcriptHistory.buffer(record); return; }
    if (!current || record.item.revision > current.revision) { accept(record.item); changedItem(record.item.seq, !current); }
  } else if (record.type === 'patch') applyPatch(record, true);
  else if (record.type === 'reload') location.reload();
  else if (record.type === 'job-reset') { resets++; enqueue({ type: 'reset' }); epoch = record.epoch; job.reset(record); after = job.cursor(); }
  else if (record.type === 'job-gone') job.gone(record);
  else if (record.type === 'job-append') { job.append(record); after = job.cursor(); }
  else if (record.type === 'state') {
    if (state.sessionId !== record.sessionId || state.life.type !== record.life.type) editor.resetCompletion();
    if (state.sessionId && state.sessionId !== record.sessionId) { closeSessions(); closePicker(); editorId = undefined; }
    const agentsChanged = JSON.stringify(state.agents) !== JSON.stringify(record.agents);
    const wasEditing = !!state.edit, viewChanged = state.view.id !== record.view.id, transcriptWasVisible = transcriptVisible();
    if (viewChanged) leaveView(record.view.id);
    if (viewChanged || state.sessionId !== record.sessionId) { pathWarnings.clear(); pathWarningEpoch++; }
    const loaded = state.view.id === '' && epoch !== '';
    const scopeChanged = viewChanged || state.sessionId !== record.sessionId, previousFilter = topics.filter(), priorInput = latestTopicInput();
    if (previousFilter && priorInput?.kind === 'user') visible(priorInput.seq);
    const workingChanged = state.working !== record.working;
    const previousScope = topics.scope();
    state = record;
    reportComposer();
    topics.update(record, previousScope);
    if (scopeChanged) transcriptHistory.cancel('scope');
    if (scopeChanged) decide({ type: 'switch', scope: { view: record.view.id, sessionId: record.sessionId, topic: topics.filter() }, loaded, filtered: topics.filter() !== undefined });
    if (scopeChanged && loaded) catchUpReader();
    topics.render();
    if (scopeChanged) { refreshTopicItems(); if (epoch && record.view.type === 'root' && (previousFilter !== topics.filter() || topics.filter() !== undefined)) void transcriptHistory.reload(); }
    if (workingChanged && previousFilter === shownFilter && shownFilter && priorInput?.kind === 'user') accept({ ...priorInput });
    windowDirty = true; schedule(); if (agentsChanged || viewChanged) { for (const seq of views.keys()) dirty.add(seq); } document.body.dataset.sessionId = state.sessionId ?? ''; element('items').hidden = state.life.type === 'switching';
    showJobView();
    if (!transcriptWasVisible && transcriptVisible()) invalidateExtents();
    if (viewChanged) rescopeImages();
    renderBar(); refreshBash(); reconcileWorking(); refreshComposer(); dialogs(); queue(); exited();
    if (state.life.type === 'ready' && state.editor && editorId !== state.editor.id) {
      if (state.editor.attachments) restoreQueued([{ text: state.editor.text, attachments: state.editor.attachments }]);
      else editor.setText(state.editor.text);
      editorId = state.editor.id;
      void fetchJSON('/editor/ack', { sessionId: state.sessionId, id: state.editor.id }).catch(reportError);
    }
    statuses();
    if (wasEditing && !state.edit) focusComposer();
  }
}

function leaveView(next: string) {
  const previous = state.view.id;
  closeSessions(); closePicker(); closeLightbox(); closeBarMenu();
  editor.resetCompletion(); transcriptHistory.cancel('request'); editorId = undefined; escaped = false; takingBack = undefined;
  element('error').textContent = '';
  draft.view(next);
  if (previous) drafts.set(previous, editor.text());
  editor.setText(drafts.get(next) ?? ''); drafts.delete(next);
}
function rescopeImages() {
  for (const thumb of element('items').querySelectorAll<HTMLButtonElement>('[data-base]')) {
    const image = thumb.firstElementChild, src = scoped(thumb.getAttribute('data-base') ?? '', state.sessionId);
    if (!(image instanceof HTMLImageElement) || image.getAttribute('src') === src) continue;
    thumb.classList.remove('gone'); thumb.removeAttribute('role'); thumb.removeAttribute('title'); thumb.disabled = false;
    while (thumb.children.length > 2) thumb.lastElementChild?.remove();
    image.hidden = false; image.setAttribute('src', src);
  }
}
// The job view: its page module, and the hooks that tie it to the one follow mechanism above.
const job = createJobPage({
  root: element('jobv'), foot: { dot: element('job-dot'), word: element('job-word'), time: element('job-time'), count: element('job-count'), act: element('job-act') }, node, resync, reportError,
  log: link => previewFile(link, '/job/log'),
  earlier: async (id, jobEpoch, before) => { const result = await fetchJSON('/job/earlier', { sessionId: state.sessionId, id, epoch: jobEpoch, before }); enqueue({ type: 'history' }); return result; },
  act: (action, id) => { fetchJSON(action === 'stop' ? '/job/stop' : '/job/clear', { sessionId: state.sessionId, id }).catch(reportError); },
  changed: () => enqueue({ type: 'layout', cause: 'layout' }),
});
function showJobView() {
  const current = state.view.type === 'job' ? state.view : undefined;
  document.body.classList.toggle('jobmode', !!current);
  element('jobv').hidden = element('jobfoot').hidden = !current;
  if (current) job.show(current); else job.hide();
}
function jobOpen(ref: WireJob) {
  if (ref.gone) return '';
  const link = node('a', 'open', 'jopen');
  link.onclick = event => { event.preventDefault(); event.stopPropagation(); fetchJSON('/view', { sessionId: state.sessionId, id: ref.id }).catch(reportError); };
  return link;
}
function jobLog(ref: WireJob) { const result = node('div', 'log: ' + ref.log, 'delta'); result.append(' ', jobOpen(ref)); return result; }
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
  bar.append(part((path[last].type === 'job' ? '' : '@') + path[last].name, 'cur'));
}
function openBarMenu(anchor: HTMLElement, hidden: { id: string; name: string }[]) {
  if (!barMenu.hidden) { closeBarMenu(); return; }
  barMenu.replaceChildren(...hidden.map(entry => { const row = node('button', '@' + entry.name); row.setAttribute('role', 'menuitem'); row.onclick = () => viewTo(entry.id); return row; }));
  const rect = anchor.getBoundingClientRect(), bounds = bar.getBoundingClientRect();
  barMenu.style.left = Math.max(8, Math.min(rect.left - 6, innerWidth - 8 - 140)) + 'px'; barMenu.style.top = bounds.bottom + 4 + 'px';
  barMenu.hidden = false;
}
function layoutBar(column = element('transcript').getBoundingClientRect()) {
  if (bar.hidden) return;
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
function dockResized(height: number) {
  document.body.style.setProperty('--dock-h', height + 'px');
  if (height === dockHeight) return;
  dockHeight = height;
  enqueue({ type: 'layout', cause: 'layout' });
}
type Match = { seq: number; segment: number; start: number };
type Find = { query: string; backwards: boolean; started: boolean; loadedFrom: number | undefined; cursor: Match | undefined };
type FindAnswer = { index: number; count: number; loading: boolean } | { cancelled: true } | null;
let find: Find | undefined;
type Cached = { item: WireItem; previous: WireItem | undefined; segments: Segment[]; needle?: string; starts?: number[][] };
const segmentCache = new Map<number, Cached>(), owners: RunContext['owners'] = new Map();
const findContext = () => ({ items: visible, raw: (at: number) => items.get(at), fold: REVEAL.fold, cwd: displayPath(state.cwd), owners });
let selected: { from: number; to: number } | undefined;
function rowSeq(node: Node | null) {
  for (let at = node; at; at = at.parentNode) if (at.parentNode === element('items') && at instanceof HTMLElement && at.dataset.seq !== undefined) return Number(at.dataset.seq);
  return undefined;
}
function wholeSelection() {
  const selection = getSelection();
  if (!selection || !order.length || !selection.rangeCount || selection.isCollapsed) return false;
  const content = leaves(element('items')), first = content[0], last = content.at(-1);
  if (!first || !last) return false;
  const range = selection.getRangeAt(0), length = last.textContent?.length ?? 0;
  const top = range.startContainer === first && range.startOffset === 0 || selection.containsNode(first, false);
  const bottom = range.endContainer === last && range.endOffset === length || selection.containsNode(last, false);
  return first !== last && top && bottom;
}
function pinnedRows() {
  const selection = getSelection();
  if (!selection || !selection.rangeCount || selection.isCollapsed || wholeSelection()) return undefined;
  const range = selection.getRangeAt(0), list = element('items'), rows = [...list.children].flatMap(child => child instanceof HTMLElement && child.dataset.seq !== undefined ? [Number(child.dataset.seq)] : []);
  const first = rowSeq(range.startContainer), last = rowSeq(range.endContainer);
  const from = first ?? (last !== undefined && list.compareDocumentPosition(range.startContainer) & 2 ? rows[0] : undefined);
  const to = last ?? (first !== undefined && list.compareDocumentPosition(range.endContainer) & 4 ? rows[rows.length - 1] : undefined);
  if (from === undefined || to === undefined) return;
  const groups = ensureTable().groups, firstGroup = groupAt(groups, Math.min(from, to)), lastGroup = groupAt(groups, Math.max(from, to));
  return { from: firstGroup?.from ?? Math.min(from, to), to: lastGroup?.to ?? Math.max(from, to) };
}
function transcriptText() {
  const context = findContext();
  return order.flatMap(seq => { const item = visible(seq), text = item ? exportText(item, context) : ''; return text ? [text] : []; }).join('\n\n');
}
function cached(seq: number) {
  const item = visible(seq), previous = visible(seq - 1), entry = segmentCache.get(seq);
  if (!item) return undefined;
  if (entry?.item === item && entry.previous === previous) return entry;
  const fresh: Cached = { item, previous, segments: findSegments(item, findContext()) };
  segmentCache.set(seq, fresh);
  return fresh;
}
const segmentsOf = (seq: number) => cached(seq)?.segments ?? [];
function allMatches(needle: string) {
  const list: Match[] = [];
  for (const seq of order) {
    const entry = cached(seq);
    if (!entry) continue;
    if (entry.needle !== needle) { entry.starts = entry.segments.map(segment => matchesIn(segment, needle)); entry.needle = needle; }
    entry.starts?.forEach((starts, segment) => { for (const start of starts) list.push({ seq, segment, start }); });
  }
  return list;
}
const squash = (text: string) => text.replace(/\s+/g, '');
function leaves(node: Node, into: Node[] = []) {
  if (node instanceof HTMLElement && node.classList.contains('message-header')) return into;
  if (!node.childNodes.length) { if (node.textContent) into.push(node); }
  else for (const child of node.childNodes) leaves(child, into);
  return into;
}
function locate(row: HTMLElement, segments: Segment[], match: Match, length: number) {
  const segment = segments[match.segment], key = squash(segment.text);
  const earlier = segments.slice(0, match.segment).filter(other => other.step === segment.step && squash(other.text) === key).length;
  const containers: Node[] = [];
  const deepest = (node: Node): boolean => {
    if (!squash(leaves(node).map(leaf => leaf.textContent ?? '').join('')).includes(key)) return false;
    let deeper = false;
    for (const child of node.childNodes) if (child.childNodes.length && deepest(child)) deeper = true;
    if (!deeper) containers.push(node);
    return true;
  };
  deepest(row);
  const container = containers[Math.min(earlier, containers.length - 1)];
  if (!container) return undefined;
  const chars: { node: Node; offset: number }[] = [];
  let flat = '';
  for (const leaf of leaves(container)) { const text = leaf.textContent ?? ''; for (let offset = 0; offset < text.length; offset++) if (!/\s/.test(text[offset])) { chars.push({ node: leaf, offset }); flat += text[offset]; } }
  const at = flat.indexOf(key), first = at + squash(segment.text.slice(0, match.start)).length, count = squash(segment.text.slice(match.start, match.start + length)).length;
  if (at < 0 || !count || !chars[first] || !chars[first + count - 1]) return undefined;
  return { start: chars[first], end: { node: chars[first + count - 1].node, offset: chars[first + count - 1].offset + 1 } };
}
function collapseAt(match: Match, needle: string, backwards: boolean) {
  const segment = segmentsOf(match.seq)[match.segment], step = segment.step && openers.get(segment.step)?.view;
  const row = step ? segment.step && segment.folds.includes(segment.step) ? step.querySelector<HTMLElement>('.detail') ?? step : step : views.get(match.seq)?.view;
  const found = row && locate(row, segmentsOf(match.seq), match, needle.length);
  if (found) getSelection()?.collapse(backwards ? found.end.node : found.start.node, backwards ? found.end.offset : found.start.offset);
}
async function reveal(mine: Find, match: Match, needle: string, backwards: boolean) {
  const view = state.view.id, generation = epoch, seq = match.seq, segment = segmentsOf(seq)[match.segment];
  const alive = () => find === mine && state.view.id === view && epoch === generation && segmentsOf(seq)[match.segment]?.text === segment.text && segmentsOf(seq)[match.segment]?.folds.join() === segment.folds.join();
  for (const key of segment.folds) folds.set(key, true);
  for (const key of segment.fences) openFences.add(key);
  enqueue({ type: 'navigate', anchor: { item: { kind: 'message', seq }, offset: geometry().viewport / 3, edge: 'row' } });
  windowDirty = true;
  for (let turn = 0; turn < 8; turn++) { await rendered(); if (!alive()) return false; if (views.has(seq) && !windowDirty) break; }
  for (const key of segment.folds) openers.get(key)?.open();
  for (const key of segment.fences) fenceOpeners.get(key)?.open();
  if (!alive()) return false;
  collapseAt(match, needle, backwards);
  return true;
}
async function koFind(query: string, backwards: boolean): Promise<FindAnswer> {
  if (state.view.type === 'job') return null;
  const needle = lowered(query), view = state.view.id;
  if (!needle) { find = undefined; return { index: 0, count: 0, loading: false }; }
  if (find?.query !== needle) find = { query: needle, backwards, started: false, loadedFrom: undefined, cursor: undefined };
  const mine = find, list = allMatches(needle);
  if (transcriptHistory.more) {
    if (!transcriptHistory.pending) {
      if (mine.started && mine.loadedFrom === first) { find = undefined; throw Error('Could not load earlier messages'); }
      mine.started = true; mine.loadedFrom = first;
      void transcriptHistory.earlier();
    }
    return { index: 0, count: list.length, loading: true };
  }
  const direction = mine.started ? mine.backwards : backwards, cursor = mine.cursor;
  mine.started = false;
  if (!list.length) { mine.cursor = undefined; return { index: 0, count: 0, loading: false }; }
  const current = cursor ? list.findIndex(match => match.seq === cursor.seq && match.segment === cursor.segment && match.start === cursor.start) : -1;
  const index = current < 0 ? direction ? list.length - 1 : 0 : (current + (direction ? list.length - 1 : 1)) % list.length;
  mine.cursor = list[index];
  if (!await reveal(mine, list[index], needle, direction) || state.view.id !== view) return { cancelled: true };
  return { index: index + 1, count: list.length, loading: false };
}
if (window.ko) { window.__koFind = koFind; window.__koFindCancel = () => { find = undefined; }; }
const koaInstance = document.querySelector<HTMLMetaElement>('meta[name="koa-instance"]')?.content;
const metricsMode = document.querySelector<HTMLMetaElement>('meta[name="koa-metrics"]')?.content;
const metrics: { mode: string; bytes: number; pending: { t: number; stages: Stages }[]; samples: MetricsSample[]; timer?: number; writes: Promise<void>; frames: Set<Promise<void>>; waiting: (() => void)[]; error?: string } | undefined = metricsMode ? { mode: metricsMode, bytes: 0, pending: [], samples: [], timer: undefined, writes: Promise.resolve(), frames: new Set(), waiting: [], error: undefined } : undefined;
const probe = metrics && install(tick, metrics.mode === 'probe');
function sendMetrics(force = false) {
  if (!metrics || !force && !metrics.samples.length && !probe?.pending()) return;
  clearTimeout(metrics.timer); metrics.timer = undefined;
  const samples = metrics.samples.splice(0, 50), observations = probe?.drain(200) ?? [];
  metrics.writes = metrics.writes.then(async () => {
    const response = await fetch('/metrics', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ samples, observations }) });
    if (!response.ok) throw Error('Metrics write failed: ' + response.status);
  }).catch(error => { metrics.error = error.message; console.error(error); });
}
if (metrics) window.koaMetrics = {
  async flush() {
    await Promise.all([...metrics.frames]);
    while (metrics.samples.length || probe?.pending()) sendMetrics();
    sendMetrics(true); await metrics.writes;
    if (metrics.error) throw Error(metrics.error);
  },
  get after() { return after; },
  get count() { return items.size; },
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
    const received = metrics ? performance.timeOrigin + performance.now() : 0, visibility = metrics && document.hidden ? 'hidden' : 'visible';
    try {
      const record: PageRecord = JSON.parse(event.data);
      if (metrics && record.type === 'flush') { metrics.bytes = record.bytes; metrics.pending.push({ t: record.t, stages: { id: record.id, received, visibility } }); }
      else if (probe) probe.applying(record.type, () => apply(record));
      else apply(record);
      if (metrics?.pending.length) {
        const pending = metrics.pending.splice(0), bytes = metrics.bytes;
        const sampled = (kind: 'applied' | 'frame') => {
          const at = performance.timeOrigin + performance.now();
          const request = kind === 'frame' ? probe?.request() : undefined;
          for (const { t, stages } of pending) {
            if (request && request.fired >= stages.received) stages.request = request;
            metrics.samples.push({ t, [kind]: at, bytes, clockError: Date.now() - at, ...kind === 'frame' && { stages } });
            if (metrics.samples.length === 50) sendMetrics();
          }
          metrics.timer ??= setTimeout(sendMetrics, 250);
        };
        if (metrics.mode === 'applied') sampled('applied');
        else {
          let finish: () => void = () => {};
          const frame = new Promise<void>(resolve => { finish = resolve; });
          metrics.frames.add(frame);
          metrics.waiting.push(() => { sampled('frame'); metrics.frames.delete(frame); finish(); });
          schedule();
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
  const sendingSession = state.sessionId, origin = state.view.id, generation = scrolling.generation;
  submitting = true;
  decide({ type: 'submit' });
  try {
    const result = await fetchJSON('/prompt', { sessionId: sendingSession, text, mode, attachments: files.map(file => file.id), ...(topics.composer() ? { topic: topics.composer() } : {}) });
    if (result.disposition !== 'handled') draft.sent(files);
    if (state.view.id !== origin) { if (drafts.get(origin) === text) drafts.delete(origin); return; }
    if (state.sessionId !== sendingSession || scrolling.generation !== generation) return;
    decide({ type: 'send-result', result: result.disposition });
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
  catch (error) { if (state.view.id === origin && state.sessionId === sendingSession && scrolling.generation === generation) decide({ type: 'send-result', result: 'failed' }); reportError(error); }
  finally { submitting = false; }
}
element('older').onclick = () => { void transcriptHistory.earlier(); };
const isTextInput = (target: EventTarget | null) => target instanceof HTMLElement && (target.isContentEditable || !!target.closest('input,textarea,select'));
const isControl = (target: EventTarget | null) => isTextInput(target) || target instanceof HTMLElement && !!target.closest('button,[role=button],[role=option],[role=listbox],[role=menuitem]');
function composerReceivesKeys() { return document.hasFocus() && !element('field').inert && !state.dialogs.length && !document.querySelector('.lightbox') && (editor.hasFocus() || !isTextInput(document.activeElement)); }
function composerFocus() { element('field').classList.toggle('focus', composerReceivesKeys()); }
function focusComposer() { composerFocus(); if (composerReceivesKeys() && !pickerButton && sessionPicker === 'closed' && (!isControl(document.activeElement) || editor.hasFocus())) editor.focus(); }
window.addEventListener('focus', () => { focusComposer(); decide({ type: 'focus' }); });
matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', () => decide({ type: 'frame' }));
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
window.addEventListener('pagehide', () => {
  const scroll = scrollMemory(scrolling);
  decide({ type: 'visibility' }); stopFrames();
  const current = new Map(drafts);
  current.set(state.view.id, editor.text());
  const memory: PageMemory = { scroll, drafts: [...current].filter(([view, text]) => !!view && !!text), ...topics.memory() };
  history.replaceState(memory, '');
});
document.addEventListener('visibilitychange', () => { decide({ type: 'visibility' }); cancelPending(); if (!document.hidden) { revealDirty ||= revealing.size > 0; windowDirty = true; armCap(); } schedule(); });
document.addEventListener('focusin', composerFocus);
document.addEventListener('focusout', composerFocus);
const previewModifiers = (event: MouseEvent | KeyboardEvent) => event.shiftKey && event.metaKey && !event.ctrlKey && !event.altKey;
const previewHover = (event: KeyboardEvent) => document.documentElement.classList.toggle('preview-modifiers', previewModifiers(event));
document.addEventListener('keyup', previewHover);
window.addEventListener('blur', () => { decide({ type: 'focus' }); document.documentElement.classList.remove('preview-modifiers'); composerFocus(); });
document.addEventListener('selectionchange', () => {
  reportComposer();
  const next = pinnedRows();
  if (next?.from === selected?.from && next?.to === selected?.to) return;
  selected = next; windowDirty = true; schedule();
});
function transcriptSelected(selection: Selection | null) {
  return selection && !selection.isCollapsed && !element('prompt').contains(selection.anchorNode) && !element('prompt').contains(selection.focusNode) && (wholeSelection() || element('items').contains(selection.anchorNode) && element('items').contains(selection.focusNode));
}
function reportComposer() {
  if (!window.__koComposer) return;
  const selection = window.getSelection();
  window.__koComposer(state.view.type === 'job'
    ? { type: jobSelected(selection) ? 'prompt_quote' : 'prompt', record: state.view.record }
    : { type: transcriptSelected(selection) ? 'quote' : 'focus' });
}
function jobSelected(selection: Selection | null) {
  return selection && !selection.isCollapsed && element('jobv').contains(selection.anchorNode) && element('jobv').contains(selection.focusNode);
}
function quoteSelection() {
  const selection = window.getSelection();
  if (state.view.type === 'job') return window.ko ? { record: state.view.record, ...(selection && jobSelected(selection) ? { quote: selection.toString() } : {}) } : undefined;
  if (selection && !selection.isCollapsed && (element('prompt').contains(selection.anchorNode) || element('prompt').contains(selection.focusNode))) return;
  if (selection && transcriptSelected(selection)) {
    const text = quote(wholeSelection() ? transcriptText() : selection.toString());
    if (text) {
      const draft = editor.text();
      escaped = false;
      editor.setText(draft + (draft && !draft.endsWith('\n\n') ? draft.endsWith('\n') ? '\n' : '\n\n' : '') + head(text));
      selection.removeAllRanges();
    }
  }
  editor.focus();
}
if (window.ko) window.__koQuoteSelection = quoteSelection;
document.addEventListener('copy', event => {
  if (state.view.type === 'job' || !wholeSelection()) return;
  event.preventDefault();
  event.clipboardData?.setData('text/plain', transcriptText());
});
document.addEventListener('keydown', event => {
  if (!window.ko && !event.defaultPrevented && !event.isComposing && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'o' && (/Mac|iPhone|iPad/.test(navigator.platform) ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey)) {
    event.preventDefault(); quoteSelection(); return;
  }
  if (!isControl(event.target)) {
    const direction = ['ArrowUp', 'PageUp', 'Home'].includes(event.key) || event.key === ' ' && event.shiftKey ? 'up'
      : ['ArrowDown', 'PageDown', 'End', ' '].includes(event.key) ? 'down' : undefined;
    if (direction) decide({ type: 'input', direction });
  }
  previewHover(event); if (previewKey(event)) return; if (event.key === 'Escape' && element('topics').dataset.mode === 'line' && element('topics').querySelector<HTMLElement>('.topic-panel')?.hidden === false) { event.preventDefault(); topics.close(); return; } if (!barMenu.hidden && event.key === 'Escape') { event.preventDefault(); closeBarMenu(); return; } if (state.view.type === 'job') return; if (!event.defaultPrevented && event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey && !event.isComposing && event.key === 'g' && composerReceivesKeys() && !editing()) { event.preventDefault(); void openEditor(); return; } if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.isComposing || state.dialogs.length || pickerButton || sessionPicker !== 'closed') return; if (event.key === 'Tab') { event.preventDefault(); if (!element('field').inert) editor.focus(); return; } if (composerReceivesKeys() && !event.altKey && event.key.length === 1 && !(event.key === ' ' && isControl(event.target)) && !isTextInput(event.target)) { event.preventDefault(); editor.focus(); editor.insert(event.key); return; } if (event.key === 'Enter' && hasFailed() && event.target === document.body) element('exited').querySelector('button')?.click(); if (event.key === 'Escape') { event.preventDefault(); if (editing()) return; if (state.bash.some(item => item.phase === 'running')) { escaped = false; void stop(); } else if (state.working) { escaped = true; void stop(); } else if (escaped) { editor.setText(''); } else { escaped = true; } } });
element('model').onclick = () => picker('model'); element('thinking').onclick = () => picker('thinking');
document.addEventListener('pointerdown', event => { topics.pointerDown(event); if (!barMenu.hidden && !barMenu.contains(event.target instanceof Node ? event.target : null) && !(event.target instanceof Element && event.target.closest('.ellipsis'))) closeBarMenu(); if (!element('picker').contains(event.target instanceof Node ? event.target : null) && !pickerButton?.contains(event.target instanceof Node ? event.target : null)) closePicker(); });
element('scroll').onscroll = () => {
  decide({ type: 'scroll' });
  const geo = geometry(), top = geo.top - geo.origin, half = geo.viewport / 2, total = ensureTable().starts[order.length];
  if (!mountedSpans.some(span => span.start <= Math.max(0, top - half) && span.end >= Math.min(total, top + geo.viewport + half))) { windowDirty = true; schedule(); }
  transcriptHistory.fill();
};
element('scroll').addEventListener('wheel', event => {
  if (event.deltaY && Math.abs(event.deltaY) >= Math.abs(event.deltaX)) decide({ type: 'input', direction: event.deltaY < 0 ? 'up' : 'down' });
}, { passive: true });
let touchY = 0;
element('scroll').addEventListener('touchstart', event => { touchY = event.touches[0].clientY; }, { passive: true });
element('scroll').addEventListener('touchmove', event => {
  const y = event.touches[0].clientY;
  if (y !== touchY) decide({ type: 'input', direction: y > touchY ? 'up' : 'down' });
  touchY = y;
}, { passive: true });
element('latest').onmousedown = event => event.preventDefault();
element('latest').onclick = () => decide({ type: 'latest' });
const layoutObserver = new ResizeObserver(entries => probe ? probe.within('ResizeObserver', () => resized(entries)) : resized(entries));
function resized(entries: ResizeObserverEntry[]) {
  if (fontsReady && transcriptVisible() && (element('items').clientWidth !== measured.width || lineHeight() !== measured.lh)) invalidateExtents();
  const column = entries.some(({ target }) => target === element('scroll')) && !bar.hidden ? element('transcript').getBoundingClientRect() : undefined;
  for (const { target, borderBoxSize } of entries) {
    if (target === element('dock')) { dockResized(borderBoxSize[0].blockSize); positionPicker(); }
    if (target === element('scroll') && column) layoutBar(column);
  }
  topics.resize(entries);
  decide({ type: 'layout', cause: 'layout' });
}
layoutObserver.observe(topics.measure);
for (const id of ['scroll', 'items', 'jobv', 'dock']) layoutObserver.observe(element(id));
setInterval(() => { job.tick(); if (state.view.type === 'job') return; for (const item of state.bash) pendingBash.get(item.id)?.update(item); }, 1000);
window.addEventListener('resize', positionPicker);
let fontGeneration = 0;
let fontKey = '';
function readyFonts() {
  const style = getComputedStyle(element('items'));
  const key = [style.fontFamily, style.fontSize, ...['--ko-font-family', '--ko-font-size', '--prose'].map(name => style.getPropertyValue(name))].join(':');
  if (key === fontKey) return;
  const generation = ++fontGeneration;
  fontKey = key; fontsReady = false; cancelPending();
  void document.fonts.ready.then(() => {
    if (generation !== fontGeneration) return;
    fontsReady = true; invalidateExtents(); schedule();
  });
}
window.addEventListener('ko-theme', readyFonts);
readyFonts();
refreshComposer(); focusComposer(); void connect();
