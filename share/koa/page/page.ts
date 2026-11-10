import { annotations, update } from './annotations.ts';
import { markdown, markdownLine } from './markdown.ts';
import { composer } from './composer.ts';
import { attach } from './attach.ts';
import { preview, previewKey } from './preview.ts';
import { nameCommand } from '../prompt.ts';
import { fetchJSON } from './http.ts';
import { ATTACHMENT_LIMITS, pathArg } from '../koa-records.ts';
import { jobEndText } from '../../pi/records.ts';
import type { State, WireItem, WireAssistant, Block, Patch, PageRecord, PromptMode, ImageRef, AgentCall, Bash } from '../koa-records.ts';
import type { Relation } from '../../pi/records.ts';

type Step = { block: Exclude<Block, { type: 'text' }>;  item: WireAssistant; index: number; key: string; slots: Map<string, Slot> };
type AgentCard = AgentCall | Extract<WireItem, { kind: 'agent' }>;
type JobItem = Extract<WireItem, { kind: 'job' }>;
type JobGroup = { first: JobItem; next: number; items: JobItem[]; shown: number; shownStreams?: number; streams: number; omitted: number; cut: boolean; view: HTMLDivElement; details: HTMLDivElement; footer?: HTMLDivElement; kind: HTMLSpanElement; end: HTMLSpanElement };
type Slot = { type: 'image'; view: HTMLButtonElement } | { type: 'run'; view: HTMLDivElement; signature?: string } | { type: 'agent'; view: HTMLDivElement; rendered?: { card: AgentCard; at: number } } | { type: 'job'; view: HTMLDivElement; group: JobGroup };
declare global {
  interface Window {
    composer: Pick<ReturnType<typeof composer>, 'text' | 'setText' | 'focus'>;
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
  if (text !== undefined) result.textContent = text;
  if (className) result.className = className;
  return result;
};
const annotationItems = new Map<number, Map<number, Extract<WireItem, { kind: 'annotations' }>>>();
const items = new Map<number, WireItem>();
const views = new Map<number, { view: HTMLElement; item: WireItem; slots: Map<string, Slot> }>();
const template = document.createElement('template');
const folds = new Map<string, boolean>();
const texts = new Map<string, { render: ReturnType<typeof markdown>; view: HTMLElement; blocks: { block: ReturnType<ReturnType<typeof markdown>>[number]; nodes: ChildNode[] }[]; final?: boolean; source?: string; annotationItem?: Extract<WireItem, { kind: 'annotations' }> }>();
let state: State = { bash: [], pi: { type: 'starting' }, working: false, aborted: false, name: '', levels: [], cwd: '', home: '', statuses: {}, queue: { steering: [], followUp: [] }, dialogs: [] };
let epoch = '', after = -1, first: number | undefined, more = false, paging = false, follow = true, lastScrollTop = 0, delay = 200, scrollFrame: number | undefined;
let escaped = false, dialogId: string | undefined;
let submitting = false, editorId: string | undefined, dialogTimer: number | undefined, shownExit: number | undefined, pickerButton: HTMLElement | undefined, shownQueue: string | undefined, shownStatuses: string | undefined;
const pagingPatches: Patch[] = [];
let attachmentRefusalTimer: number | undefined;
const draft = attach(element('attachments'), () => refreshComposer(), displayPath, () => !!editor.bash(), () => {
  clearTimeout(attachmentRefusalTimer);
  element('error').textContent = 'a command takes no attachments';
  attachmentRefusalTimer = setTimeout(() => { if (element('error').textContent === 'a command takes no attachments') element('error').textContent = ''; }, 4000);
});
const pendingBash = new Map<string, ReturnType<typeof commandRun>>();
const editor = composer(element('prompt'), {
  drop: draft.drop, paste: draft.paste,
  input(user) { if (user) escaped = false; refreshComposer(); },
  send(mode) { void send(mode); },
  quit() { if (!draft.count && !draft.busy) void fetchJSON('/quit'); },
});
window.composer = editor;
const composerBlocked = () => state.pi.type !== 'ready' || state.dialogs.length > 0;

if (!window.ko) {
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const theme = () => document.documentElement.toggleAttribute('data-browser-dark', scheme.matches);
  scheme.addEventListener('change', theme);
  theme();
}

const relationWords: Record<Relation, string> = { parent: 'your parent', child: 'your subagent', sibling: 'another agent in this session', descendant: 'a subagent of your subagent', sibling_descendant: 'a subagent of another agent in this session' };
function agentCard(card: AgentCard, at: number, key: string, slots: Map<string, Slot>) {
  const saved = slots.get(key), slot: Extract<Slot, { type: 'agent' }> = saved?.type === 'agent' ? saved : { type: 'agent', view: node('div') };
  slots.set(key, slot);
  if (slot.rendered?.card === card && slot.rendered.at === at) return slot.view;
  slot.rendered = { card, at };
  const inbound = card.direction === 'in', ref = inbound ? card.from : card.to;
  let kind = inbound ? card.inbound.form : card.call.tool === 'spawn' ? 'task' : card.call.mode === 'interrupt-and-steer' ? 'interrupt' : card.call.mode;
  let failed = false;
  if (card.direction === 'out' && card.outcome?.ok === false) { failed = true; kind = card.call.tool === 'spawn' ? 'refused' : card.outcome.failure === 'refused' || card.outcome.failure === 'gone' ? card.outcome.failure : card.outcome.message; }
  if (card.direction === 'in' && card.inbound.form === 'ended' && !card.inbound.reported) { failed = true; kind = 'not reported'; }
  const view = slot.view; view.className = 'amsg';
  const header = node('div', undefined, 'hd'), who = node('span', '@' + ref.name, 'who'); if (ref.session) who.title = ref.session;
  if (failed && card.direction === 'out' && card.call.tool === 'spawn') who.classList.add('err');
  header.append(node('span', inbound ? 'from' : 'to', 'dir'), who);
  if (card.direction === 'in' && 'relation' in card.inbound && card.inbound.relation) header.append(node('span', '· ' + relationWords[card.inbound.relation], 'rel'));
  header.append(node('span', kind, failed ? 'tag err' : 'tag'), node('time', timestamp(at)));
  const body = card.text.text || (card.direction === 'out' && card.outcome?.ok === false ? card.outcome.message : '');
  view.replaceChildren(header);
  view.append(node('div', markdownLine(body), 'preview'));
  const details = prose(undefined, body, true); details.className = 'bd prose';
  fold(view, key, view, details, undefined, 'expanded');
  return view;
}
function jobCard(first: JobItem, slots: Map<string, Slot>): JobGroup {
  const view = node('div', undefined, 'job'), line = node('div', undefined, 'hd'), details = node('div', undefined, 'out');
  const kind = node('span', undefined, 'kind'), end = node('span', undefined, 'end'), time = node('time', timestamp(first.at));
  line.append(node('span', '›', 'chev'), node('span', first.job.name, 'nm'), kind, end, time);
  const group: JobGroup = { first, next: first.seq, items: [], shown: 0, streams: 0, omitted: 0, cut: false, view, details, kind, end };
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
    else { group.end.textContent = jobEndText(item.event.end); group.view.classList.toggle('err', item.event.end.type === 'exit' ? item.event.end.code !== 0 : item.event.end.type !== 'stopped'); break; }
  }
  const owner = views.get(group.first.seq);
  if (owner && owner.view.firstElementChild !== group.view) owner.view.replaceChildren(group.view);
  group.kind.textContent = group.first.job.service ? 'service' : group.streams ? 'stream' : ''; group.kind.hidden = !group.kind.textContent;
  group.end.hidden = !group.end.textContent;
  if (group.view.classList.contains('open')) showJob(group);
}

function timestamp(at: number) {
  const date = new Date(at), today = new Date();
  const time = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === today.toDateString()) return time;
  return (date.getFullYear() === today.getFullYear() ? '' : date.getFullYear() + ' ') + date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ' ' + time;
}

function prose(key: string | undefined, source: string, final: boolean, annotationItem?: Extract<WireItem, { kind: 'annotations' }>, user = false) {
  let memo = key === undefined ? undefined : texts.get(key);
  if (!memo) { memo = { render: markdown(user), view: node('div', undefined, 'msg prose'), blocks: [] }; if (key !== undefined) texts.set(key, memo); }
  if (memo.annotationItem === annotationItem && (memo.final && final || memo.source === source && memo.final === final)) return memo.view;
  if (final) delete memo.source;
  else memo.source = source;
  memo.annotationItem = annotationItem;
  const annotated = annotationItem ? annotations(source, annotationItem.annotations, editor) : undefined;
  memo.final = final;
  memo.view.querySelector('.caret')?.remove();
  const blocks = memo.render(source, final, annotated?.marks);
  let first = 0;
  while (first < blocks.length && memo.blocks[first]?.block === blocks[first]) first++;
  for (const saved of memo.blocks.splice(first)) for (const child of saved.nodes) child.remove();
  for (const block of blocks.slice(first)) {
    template.innerHTML = block.html ?? '';
    annotated?.decorate(template.content);
    const nodes = [...template.content.childNodes];
    for (const pre of nodes.flatMap(child => child instanceof Element ? [child, ...child.querySelectorAll('pre')] : []).filter(child => child.tagName === 'PRE')) {
      const language = pre.querySelector('code')?.className.match(/language-(\S+)/)?.[1];
      if (language) pre.append(node('span', language, 'lang'));
    }
    if (!block.streaming) delete block.html;
    memo.blocks.push({ block, nodes });
    memo.view.append(...nodes);
  }
  if (!final) {
    const last = memo.view.lastElementChild;
    (last?.tagName === 'P' ? last : memo.view).append(node('span', undefined, 'caret'));
  }
  return memo.view;
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
      const src = '/images/' + encodeURIComponent(ref.id) + '?e=' + encodeURIComponent(epoch) + '&r=' + ref.revision;
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
      target.onclick = () => { if (!target.disabled) preview(src, target, 'image', composerFocus, name); };
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
  if (block.type === 'thinking') return { label: 'thinking', labelClass: 'name', detail: block.redacted ? 'redacted' : block.text.split('\n')[0], kind: 'thinking' };
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
  line.setAttribute('role', 'button'); line.tabIndex = 0;
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
  else if (active) summary.append(node('span', undefined, 'spin'), ' ', node('span', active.info.label, 'names'));
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
  line.append(node('span', '›', 'chev'), summary, node('span', duration(started === undefined || ended === undefined ? undefined : ended - started), 'time'));
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
    if (block.type === 'thinking') detail.append(node('div', block.text || (block.redacted ? 'Redacted thinking' : ''), 'think'));
    else {
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
    fold(child, key, row, detail, images?.load);
    if (step.file) {
      label.classList.add('preview-file');
      let press: { x: number; y: number } | undefined;
      label.onmousedown = event => { press = undefined; if (event.button === 0 && previewModifiers(event)) { event.preventDefault(); press = { x: event.clientX, y: event.clientY }; } };
      label.onclick = event => { const start = press; press = undefined; if (start && Math.hypot(event.clientX - start.x, event.clientY - start.y) < 3) { event.preventDefault(); event.stopPropagation(); preview('/steps/' + step.item.seq + '/' + step.index + '/file', label, 'file', composerFocus); } };
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
      if (block.type === 'text') { flush(); if (block.text) children.push(prose(key, block.text, item.final, annotationItems.get(item.seq)?.get(index))); }
      else if (block.type === 'tool' && block.agent) { flush(); const saved = previous?.slots.get('agent:' + key); if (saved?.type === 'agent') slots.set('agent:' + key, saved); children.push(agentCard(block.agent, block.started ?? item.at, 'agent:' + key, slots)); }
      else steps.push({ block, item, key, index, slots });
    });
    flush();
    if (item.error) children.push(node('div', item.error, 'msg err'));
  } else {
    view.className = 'msg ' + item.kind;
    if (item.kind === 'user') {
      const time = node('time', timestamp(item.at)); time.dateTime = new Date(item.at).toISOString();
      const text = node('div', undefined, 't'); text.append(prose(item.seq + ':user', item.text, true, undefined, true));
      if (item.images.length) { const images = thumbnails(item.images, slots); images.load(); text.append(images.view); }
      const paths = item.attachments.filter(file => file.kind === 'file').map(file => file.path);
      if (paths.length) text.append(node('div', paths.join('\n'), 'paths'));
      children.push(time, text);
    } else if (item.kind === 'notify') { view.className = 'note ' + item.level; children.push(node('span', item.text.text, 'tx'), node('time', timestamp(item.at))); }
    else if (item.kind === 'agent') { view.className = ''; children.push(agentCard(item, item.at, 'agent:' + item.seq, slots)); }
    else if (item.kind === 'annotations') { view.hidden = true; }
    else if (item.kind === 'job') { view.className = ''; const saved = previous?.slots.get('job'); if (saved?.type === 'job') slots.set('job', saved); }
    else if (item.kind === 'notice') { view.className = 'note'; children.push(node('span', markdownLine(item.text), 'tx'), node('time', timestamp(item.at))); }
    else if (item.kind === 'bash') { view.className = ''; children.push(commandRun(item, 'bash:' + item.seq).view); }
    else children.push(node('div', item.text, 'notice'));
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
  }
}
function refreshComposer() {
  update(editor.text());
  const blocked = composerBlocked(), working = state.working && !blocked;
  const available = element('field').inert && !blocked;
  element('field').inert = blocked;
  composerFocus();
  if (available) focusComposer();
  element('field').classList.toggle('drop', draft.hover);
  const running = state.bash.some(item => item.phase !== 'completed') && !working && editor.empty();
  editor.running(running);
  if (!editor.bash() && element('error').textContent === 'a command takes no attachments') { clearTimeout(attachmentRefusalTimer); element('error').textContent = ''; }
  editor.placeholder(running ? 'running… ⎋ cancels' : draft.hover ? 'Drop to attach' : hasExited() ? 'pi has exited' : working ? 'Steer koa…' : 'Message koa…');
  status();
}
function status() {
  const waiting = state.dialogs.length > 0, label = element('status');
  const cause = exitCause();
  const bang = editor.bash(), running = state.bash.find(item => item.phase !== 'completed');
  label.classList.toggle('err', !!bang && draft.count > 0);
  label.title = bang && draft.count ? 'remove the attachments' : '';
  const word = cause ? (cause.kind === 'code' ? 'exited' : cause.kind) + ' ' + cause.value : waiting ? 'waiting' : state.pi.type === 'starting' ? 'starting' : state.working ? 'working' : running ? 'running' : bang ? bang.excludeFromContext ? 'run, quiet' : 'run' : state.aborted ? 'aborted' : 'idle';
  label.textContent = word;
  if (state.pi.type === 'ready' && (state.working || running) && !waiting) {
    const ms = Math.max(0, Math.floor((Date.now() - (state.working ? state.since ?? Date.now() : running?.started ?? Date.now())) / 1000)) * 1000;
    label.append(node('span', ' ' + duration(ms, ' '), 'k'));
  }
  element('dot').className = 'dot' + (hasExited() ? ' off' : waiting ? ' wait' : state.pi.type === 'ready' && (state.working || running) ? ' on' : '');
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
  const answer = async (cancelled: boolean) => {
    if (submit.disabled) return;
    submit.disabled = cancel.disabled = true;
    try { await fetchJSON('/dialog', { id: request.id, ...(cancelled ? { cancelled: true } : request.method === 'confirm' ? { confirmed: true } : { value: field ? field.value : request.method === 'select' && selection ? request.options[selection.index] : undefined }) }); }
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
  const entries = [...state.queue.steering.map(entry => ['steer', entry] as const), ...state.queue.followUp.map(entry => ['follow-up', entry] as const)];
  const signature = JSON.stringify(entries);
  if (shownQueue === signature) return;
  shownQueue = signature;
  const host = element('queue'); host.replaceChildren();
  if (!entries.length) return;
  for (const [tag, entry] of entries) {
    const row = node('div', undefined, 'q'); row.append(node('span', tag, 'tag'), node('span', entry.text, 't'));
    if (entry.attachments.length) { const count = node('span', undefined, 'att'); count.innerHTML = '<svg viewBox="0 0 16 16"><path d="M10.5 5.5 6 10a1.6 1.6 0 0 0 2.3 2.3l5-5a3.2 3.2 0 0 0-4.5-4.5l-5.2 5.2a4.8 4.8 0 0 0 6.8 6.8l4-4"/></svg>'; count.append(document.createTextNode(String(entry.attachments.length))); row.append(count); }
    host.append(row);
  }
  const take = node('div', entries.length + ' queued', 'take'), back = button('take back');
  take.append(node('span', undefined, 'sp'), back); host.append(take);
  back.onclick = async () => {
    back.disabled = true;
    try { await takeBack(); }
    catch (error) { reportError(error); back.disabled = false; }
  };
}
async function takeBack() {
  const result = await fetchJSON('/queue/clear');
  const entries = [...result.steering, ...result.followUp];
  editor.setText([editor.text(), ...entries.map(entry => entry.text)].filter(Boolean).join('\n\n'));
  draft.restore(entries.flatMap(entry => entry.attachments));
  refreshComposer(); editor.focus();
}
async function stop() {
  if (submitting) return;
  submitting = true;
  try { if (!state.bash.some(item => item.phase === 'running')) await takeBack(); await fetchJSON('/abort'); }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
function hasExited() { return state.pi.type === 'exited'; }
function exitCause(): { kind: 'code' | 'signal' | 'failed'; value: string } | undefined { return 'exited' in state.pi ? { kind: 'code', value: String(state.pi.exited) } : 'signal' in state.pi ? { kind: 'signal', value: state.pi.signal } : 'failed' in state.pi ? { kind: 'failed', value: state.pi.failed } : undefined; }
function exited() {
  composerFocus();
  const host = element('exited'); host.hidden = !hasExited();
  const pi = state.pi;
  const at = pi.type === 'exited' ? pi.at : undefined;
  if (shownExit === at) return;
  shownExit = at; host.replaceChildren();
  if (pi.type !== 'exited') return;
  closePicker();
  const card = node('div', undefined, 'card'), head = node('div', undefined, 'head');
  const cause = exitCause();
  const title = node('span', 'pi exited ', 'title'); title.append(node('span', '· ' + (cause ? cause.kind + ' ' + cause.value : ''), 'err')); head.append(title, node('span', timestamp(pi.at), 'count'));
  const actions = node('div', "last 5 lines of pi's stderr · the whole output is in the pane's terminal", 'acts'), start = button('Start pi again', '↩', true);
  start.onclick = async () => { start.disabled = true; try { await fetchJSON('/pi/start'); } catch (error) { reportError(error); start.disabled = false; } };
  actions.append(node('span', undefined, 'sp'), start); card.append(head, node('pre', pi.stderr || ''));
  if (!state.sessionFile) card.append(node('div', 'No session file was saved. Start pi again starts a fresh session.', 'fresh'));
  card.append(actions); host.append(card); start.focus();
}
function closePicker() { element('picker').hidden = true; const trigger = pickerButton; pickerButton = undefined; if (trigger) { trigger.classList.remove('pick'); focusComposer(); } composerFocus(); }
function positionPicker() {
  if (!pickerButton) return;
  const host = element('picker'), rect = element('model-cell').getBoundingClientRect();
  host.style.left = Math.max(0, Math.min(rect.left - 6, innerWidth - 244)) + 'px';
  host.style.bottom = (innerHeight - rect.top + 8) + 'px';
  host.style.maxHeight = Math.max(0, rect.top - 16) + 'px';
}
async function picker(kind: 'model' | 'thinking') {
  if (state.pi.type !== 'ready') return;
  const trigger = element(kind), host = element('picker');
  if (pickerButton === trigger) { closePicker(); return; }
  closePicker();
  const choices: ({ kind: 'model'; id: string; provider: string } | { kind: 'thinking'; id: string })[] = [];
  try {
    if (kind === 'model') {
      choices.push(...(await fetchJSON('/models', undefined, 'GET')).models.map(model => ({ kind: 'model' as const, id: model.id, provider: model.provider })));
      if (getComputedStyle(element('thinking')).display === 'none') choices.push(...state.levels.map(id => ({ kind: 'thinking' as const, id })));
    } else choices.push(...state.levels.map(id => ({ kind: 'thinking' as const, id })));
  } catch (error) { reportError(error); return; }
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
  const choose = async (index: number) => { const choice = choices[index]; if (!choice) return; try { await fetchJSON('/' + choice.kind, choice.kind === 'model' ? { provider: choice.provider, modelId: choice.id } : { level: choice.id }); closePicker(); } catch (error) { reportError(error); } };
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
function apply(record: PageRecord) {
  if (record.type === 'reset') {
    epoch = record.epoch; after = -1; first = undefined; items.clear(); views.clear(); texts.clear(); annotationItems.clear(); folds.clear(); jobOwners.clear(); pagingPatches.length = 0; more = record.more;
    element('items').replaceChildren();
    element('older').hidden = !more;
    for (const item of record.items) put(item);
    refreshBash(); refreshComposer();
  } else if (record.type === 'item') put(record.item);
  else if (record.type === 'patch') {
    const current = items.get(record.seq);
    if (!current) { if (paging) pagingPatches.push(record); return; }
    if (current.kind !== 'assistant') return;
    const item = { ...current, blocks: current.blocks.slice() };
    Object.assign(item, { final: record.final, stop: record.stop, error: record.error, ended: record.ended });
    for (const change of record.blocks) {
      if ('block' in change) { item.blocks[change.index] = change.block; texts.delete(record.seq + ':' + change.index); }
      else {
        const block = item.blocks[change.index];
        if (block.type !== 'tool') item.blocks[change.index] = { ...block, text: block.text + change.suffix };
      }
    }
    put(item);
  } else if (record.type === 'state') {
    state = record; refreshBash(); refreshComposer(); dialogs(); queue(); exited();
    if (state.pi.type === 'ready' && state.editor && editorId !== state.editor.id) {
      editor.setText(state.editor.text); editorId = state.editor.id;
      void fetchJSON('/editor/ack', { id: state.editor.id }).catch(reportError);
    }
    statuses();
  }
}

function followBottom() {
  if (scrollFrame !== undefined) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = undefined;
    if (follow) {
      const scroll = element('scroll');
      scroll.scrollTop = scroll.scrollHeight;
      lastScrollTop = scroll.scrollTop;
    }
  });
}
function followResize() {
  const scroll = element('scroll');
  lastScrollTop = Math.min(lastScrollTop, Math.max(0, scroll.scrollHeight - scroll.clientHeight));
  followBottom();
}
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
let source: EventSource, reconnect: number | undefined, closed = false;
function connect() {
  if (closed) return;
  source = new EventSource('/events?epoch=' + encodeURIComponent(epoch) + '&after=' + after);
  const lost = () => {
    source.onmessage = source.onerror = source.onopen = null;
    source.close();
    element('error').textContent = 'Connection lost. Reconnecting…';
    reconnect = setTimeout(connect, delay); delay = Math.min(delay * 2, 5000);
  };
  source.onopen = () => { delay = 200; element('error').textContent = ''; };
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
    } catch (error) { console.error(error); lost(); }
  };
}
window.addEventListener('pagehide', () => { closed = true; source?.close(); clearTimeout(reconnect); });
window.addEventListener('pageshow', event => { if (event.persisted && closed) { closed = false; connect(); } });
async function older() {
  if (!more || paging || first === undefined) return;
  paging = true;
  const scroll = element('scroll'), anchor = views.get(first)?.view;
  const top = anchor?.getBoundingClientRect().top;
  try {
    const response = await fetch('/items?before=' + first); if (!response.ok) throw Error('Could not load earlier messages');
    const result: Extract<PageRecord, { type: 'reset' }> = await response.json();
    if (result.epoch === epoch) {
      more = result.more;
      for (const item of result.items) if (!items.has(item.seq)) put(item);
      for (const patch of pagingPatches.splice(0)) apply(patch);
      element('older').hidden = !more;
      if (anchor && top !== undefined) scroll.scrollTop += anchor.getBoundingClientRect().top - top;
    }
  } catch (error) { reportError(error); } finally { paging = false; }
}
function canSend(text: string) { const bang = editor.bash(); if (bang) return !!bang.command.trim() && !state.bash.some(item => item.phase !== 'completed') && !draft.busy && !draft.count; return !!nameCommand(text) || !draft.busy && draft.count <= ATTACHMENT_LIMITS.files && (!!text.trim() || draft.count > 0); }
function reportError(error: unknown) { element('error').textContent = error instanceof Error ? error.message : String(error); }
async function send(mode: PromptMode = 'prompt') {
  const text = editor.text(), name = nameCommand(text), files = name ? [] : draft.files;
  if (!canSend(text) || submitting) return;
  submitting = true;
  try { await fetchJSON('/prompt', { text, mode, attachments: files.map(file => file.id) }); if (!name) draft.sent(files); if (editor.text() === text) editor.setText(''); refreshComposer(); focusComposer(); element('error').textContent = ''; }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
element('older').onclick = older;
const isTextInput = (target: EventTarget | null) => target instanceof HTMLElement && (target.isContentEditable || !!target.closest('input,textarea,select'));
const isControl = (target: EventTarget | null) => isTextInput(target) || target instanceof HTMLElement && !!target.closest('button,[role=button],[role=option],[role=listbox],[role=menuitem]');
function composerReceivesKeys() { return document.hasFocus() && !element('field').inert && !state.dialogs.length && !document.querySelector('.lightbox') && (editor.hasFocus() || !isTextInput(document.activeElement)); }
function composerFocus() { element('field').classList.toggle('focus', composerReceivesKeys()); }
function focusComposer() { composerFocus(); if (composerReceivesKeys() && !pickerButton && (!isControl(document.activeElement) || editor.hasFocus())) editor.focus(); }
window.addEventListener('focus', focusComposer);
window.addEventListener('load', focusComposer);
document.addEventListener('focusin', composerFocus);
document.addEventListener('focusout', composerFocus);
const previewModifiers = (event: MouseEvent | KeyboardEvent) => event.shiftKey && event.metaKey && !event.ctrlKey && !event.altKey;
const previewHover = (event: KeyboardEvent) => document.documentElement.classList.toggle('preview-modifiers', previewModifiers(event));
document.addEventListener('keyup', previewHover);
window.addEventListener('blur', () => { document.documentElement.classList.remove('preview-modifiers'); composerFocus(); });
document.addEventListener('keydown', event => { previewHover(event); if (previewKey(event)) return; if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.isComposing || state.dialogs.length || pickerButton) return; if (composerReceivesKeys() && !event.altKey && event.key.length === 1 && !(event.key === ' ' && isControl(event.target)) && !isTextInput(event.target)) { event.preventDefault(); editor.focus(); editor.insert(event.key); return; } if (event.key === 'Enter' && hasExited() && event.target === document.body) element('exited').querySelector('button')?.click(); if (event.key === 'Escape') { event.preventDefault(); if (state.bash.some(item => item.phase === 'running')) { escaped = false; void stop(); } else if (state.working) { escaped = true; void stop(); } else if (escaped) { editor.setText(''); } else { escaped = true; } } });
element('model').onclick = () => picker('model'); element('thinking').onclick = () => picker('thinking');
document.addEventListener('pointerdown', event => { if (!element('picker').contains(event.target instanceof Node ? event.target : null) && !pickerButton?.contains(event.target instanceof Node ? event.target : null)) closePicker(); });
element('scroll').onscroll = () => { const scroll = element('scroll'); if (Math.abs(scroll.scrollTop - lastScrollTop) >= 1) { follow = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 60; lastScrollTop = scroll.scrollTop; } if (scroll.scrollTop < 80) void older(); };
setInterval(() => { status(); for (const item of state.bash) pendingBash.get(item.id)?.update(item); }, 1000);
window.addEventListener('resize', positionPicker);
new ResizeObserver(followResize).observe(element('scroll'));
new ResizeObserver(([entry]) => {
  document.body.style.setProperty('--dock-h', entry.borderBoxSize[0].blockSize + 'px');
  followResize();
}).observe(element('dock'));
refreshComposer(); focusComposer(); void connect();
