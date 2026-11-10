import { markdown } from './markdown.ts';
import { composer } from './composer.ts';
import { attach } from './attach.ts';
import { nameCommand } from '../prompt.ts';
import { fetchJSON } from './http.ts';
import { ATTACHMENT_LIMITS } from '../records.ts';
import type { State, WireItem, WireAssistant, Block, Patch, PageRecord, PromptMode, ImageRef } from '../records.ts';

type Step = { block: Exclude<Block, { type: 'text' }>;  item: WireAssistant; index: number; key: string; slots: Map<string, Slot> };
type Slot = (HTMLDivElement | HTMLButtonElement) & { signature?: string };
declare global {
  interface Window {
    ko?: { local: boolean };
    composer: Pick<ReturnType<typeof composer>, 'text' | 'setText' | 'focus'>;
    koaMetrics?: { flush(): Promise<void>; readonly after: number; readonly items: WireItem[] };
  }
}

function element(id: 'send'): HTMLButtonElement;
function element(id: string): HTMLElement;
function element(id: string) {
  const result = document.getElementById(id);
  if (!result) throw Error('Missing element: ' + id);
  if (id === 'send' && !(result instanceof HTMLButtonElement)) throw Error('Invalid send button');
  return result;
}
const node = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string) => {
  const result = document.createElement(tag);
  if (text !== undefined) result.textContent = text;
  if (className) result.className = className;
  return result;
};
const items = new Map<number, WireItem>();
const views = new Map<number, { view: HTMLElement; item: WireItem; slots: Map<string, Slot> }>();
const template = document.createElement('template');
const folds = new Map<string, boolean>();
const texts = new Map<string, { render: ReturnType<typeof markdown>; view: HTMLElement; blocks: { block: ReturnType<ReturnType<typeof markdown>>[number]; nodes: ChildNode[] }[]; final?: boolean; source?: string }>();
let state: State = { pi: { type: 'starting' }, working: false, aborted: false, name: '', levels: [], cwd: '', home: '', statuses: {}, queue: { steering: [], followUp: [] }, dialogs: [] };
let epoch = '', after = -1, first: number | undefined, more = false, paging = false, follow = true, delay = 200, scrollFrame: number | undefined;
let escaped = false, notificationTimer: number | undefined, dialogId: string | undefined, buttonWorking: boolean | undefined;
let submitting = false, editorId: string | undefined, dialogTimer: number | undefined, shownExit: number | undefined, pickerButton: HTMLElement | undefined, shownQueue: string | undefined, shownStatuses: string | undefined;
const pagingPatches: Patch[] = [];
const draft = attach(element('attachments'), () => refreshComposer(), displayPath);
const editor = composer(element('prompt'), {
  drop: draft.drop, paste: draft.paste,
  input(user) { if (user) escaped = false; refreshComposer(); },
  send(mode) { void send(mode); },
  quit() { if (!draft.count && !draft.busy) void fetchJSON('/quit'); },
});
window.composer = editor;
const composerBlocked = () => state.pi.type === 'starting' || state.dialogs.length > 0;
const workingText = () => 'working ' + Math.max(0, Math.floor((Date.now() - (state.since ?? Date.now())) / 1000)) + 's';

if (!window.ko) {
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const theme = () => document.documentElement.toggleAttribute('data-browser-dark', scheme.matches);
  scheme.addEventListener('change', theme);
  theme();
}

function timestamp(at: number) {
  const date = new Date(at), today = new Date();
  const time = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === today.toDateString()) return time;
  return (date.getFullYear() === today.getFullYear() ? '' : date.getFullYear() + ' ') + date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ' ' + time;
}

function prose(key: string, source: string, final: boolean) {
  let memo = texts.get(key);
  if (!memo) { memo = { render: markdown(), view: node('div', undefined, 'msg prose'), blocks: [] }; texts.set(key, memo); }
  if (memo.final && final) return memo.view;
  if (memo.source === source && memo.final === final) return memo.view;
  if (final) delete memo.source;
  else memo.source = source;
  memo.final = final;
  memo.view.querySelector('.caret')?.remove();
  const blocks = memo.render(source, final);
  let first = 0;
  while (first < blocks.length && memo.blocks[first]?.block === blocks[first]) first++;
  for (const saved of memo.blocks.splice(first)) for (const child of saved.nodes) child.remove();
  for (const block of blocks.slice(first)) {
    template.innerHTML = block.html ?? '';
    const nodes = [...template.content.childNodes];
    if (!block.streaming) delete block.html;
    for (const pre of nodes.flatMap(child => child instanceof Element ? [child, ...child.querySelectorAll('pre')] : []).filter(child => child.tagName === 'PRE')) {
      const language = pre.querySelector('code')?.className.match(/language-(\S+)/)?.[1];
      if (language) pre.append(node('span', language, 'lang'));
    }
    memo.blocks.push({ block, nodes });
    memo.view.append(...nodes);
  }
  if (!final) {
    const last = memo.view.lastElementChild;
    (last?.tagName === 'P' ? last : memo.view).append(node('span', undefined, 'caret'));
  }
  return memo.view;
}

function thumbnails(refs: ImageRef[], slots: Map<string, Slot>) {
  const view = node('div', undefined, 'thumbs');
  return { view, load() {
    if (view.childNodes.length) return;
    for (const ref of refs) {
      const key = 'image:' + ref.id;
      let thumb = slots.get(key);
      if (!thumb) { thumb = node('button', undefined, 'thumb'); thumb.type = 'button'; thumb.append(node('img'), node('span', undefined, 'sz')); slots.set(key, thumb); }
      if (!(thumb instanceof HTMLButtonElement)) throw Error('Invalid thumbnail slot');
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
      view.append(thumb);
    }
  } };
}

function displayPath(value: string) { return state.home && (value === state.home || value.startsWith(state.home + '/')) ? '~' + value.slice(state.home.length) : value; }
const duration = (ms: number | undefined) => ms === undefined ? '' : ms < 100 ? Math.round(ms) + 'ms' : ms >= 60000 ? Math.floor(ms / 60000) + 'm' + String(Math.floor(ms / 1000) % 60).padStart(2, '0') + 's' : Number((ms / 1000).toFixed(1)) + 's';
function args(block: Extract<Block, { type: 'tool' }>): Record<string, unknown> {
  try { const value = JSON.parse(block.args.text); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  catch { return {}; }
}
function stepInfo(step: Step & { args: Record<string, unknown> }) {
  const { block, item } = step;
  if (block.type === 'thinking') return { label: 'thinking', labelClass: 'name', detail: block.redacted ? 'redacted' : block.text.split('\n')[0], kind: 'thinking' };
  const values = step.args;
  const kind = block.name;
  const first = Object.values(values)[0];
  const label = block.name === 'bash' ? values.command : ['read', 'edit', 'write'].includes(block.name) ? values.path : block.name + (first === undefined ? '' : ' ' + (typeof first === 'string' ? first : JSON.stringify(first)));
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
  return { edit, labelClass: block.name === 'bash' ? 'cmd' : ['read', 'edit', 'write'].includes(block.name) ? 'path' : '', label: typeof label === 'string' ? label : label === undefined ? block.name + ' ' + block.args.text : JSON.stringify(label), detail, kind, aborted: item.stop === 'aborted' && block.state.type !== 'done' };
}
function fold(view: HTMLElement, key: string, line: HTMLElement, details: HTMLElement, show?: () => void) {
  view.classList.toggle('open', folds.get(key) === true);
  line.setAttribute('role', 'button'); line.tabIndex = 0;
  line.setAttribute('aria-expanded', String(folds.get(key) === true));
  const toggle = () => { const open = !view.classList.contains('open'); folds.set(key, open); view.classList.toggle('open', open); line.setAttribute('aria-expanded', String(open)); if (open) show?.(); };
  line.onclick = toggle;
  line.onkeydown = event => { if (!event.metaKey && !event.ctrlKey && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); toggle(); } };
  view.append(line, details);
  if (folds.get(key)) show?.();
}
function run(input: Step[]) {
  const steps = input.map(step => { const value = { ...step, args: step.block.type === 'tool' ? args(step.block) : {} }; return { ...value, info: stepInfo(value) }; });
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
    if (block.type === 'tool' && ['bash', 'read', 'edit', 'write'].includes(block.name)) sum.append(node('span', block.name, error ? 'name err' : 'name'), ' ');
    sum.append(node('span', info.label, error && block.type === 'tool' && !['bash', 'read', 'edit', 'write'].includes(block.name) ? 'err' : info.labelClass), ' ');
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
    const images = refs?.length ? thumbnails(refs, step.slots) : undefined;
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
        if (block.name === 'bash') detail.append(node('div', 'cwd ' + displayPath(state.cwd), 'kv'));
        if ('result' in block.state && block.state.result?.text) detail.append(node(images && block.name === 'read' ? 'div' : 'pre', block.state.result.text, images && block.name === 'read' ? 'note' : ''));
      }
      if ('result' in block.state && block.state.result?.cut) detail.append(node('div', block.state.result.cut + ' bytes omitted', 'delta'));
    }
    if (images) { if (block.type === 'tool' && block.name === 'read') images.view.classList.add('large'); detail.append(images.view); }
    fold(child, key, row, detail, images?.load); children.append(child);
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
    if (owner) {
      const signature = JSON.stringify(steps.map(step => [step.block, step.item.final, step.item.stop, step.item.ended]));
      if (owner.signature !== signature) { owner.replaceChildren(run(steps)); owner.signature = signature; }
      for (const step of steps.slice(1)) {
        const slot = views.get(step.item.seq)?.slots.get(step.key);
        if (slot && slot !== owner) { slot.replaceChildren(); slot.signature = undefined; }
      }
    }
    steps = [];
  };
  for (let current = start; current <= end; current++) {
    const item = items.get(current), owner = views.get(current);
    if (item?.kind !== 'assistant' || !owner) continue;
    item.blocks.forEach((block, index) => {
      if (block.type === 'text') flush();
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
      const key = steps[0].key, slot = previous?.slots.get(key) ?? node('div');
      slots.set(key, slot); children.push(slot);
    }
    steps = [];
  };
  if (item.kind === 'assistant') {
    view.className = 'assistant';
    item.blocks.forEach((block, index) => {
      const key = item.seq + ':' + index;
      if (block.type === 'text') { flush(); if (block.text) children.push(prose(key, block.text, item.final)); }
      else steps.push({ block, item, key, index, slots });
    });
    flush();
    if (item.error) children.push(node('div', item.error, 'msg err'));
  } else {
    view.className = 'msg ' + item.kind;
    if (item.kind === 'user') {
      const time = node('time', timestamp(item.at)); time.dateTime = new Date(item.at).toISOString();
      const text = node('div', undefined, 't'); text.append(prose(item.seq + ':user', item.text, true));
      if (item.images.length) { const images = thumbnails(item.images, slots); images.load(); text.append(images.view); }
      const paths = item.attachments.filter(file => file.kind === 'file').map(file => file.path);
      if (paths.length) text.append(node('div', paths.join('\n'), 'paths'));
      children.push(time, text);
    } else if (item.kind === 'bash') children.push(node('div', '$ ' + item.command), node('pre', item.output.text), node('div', 'Exit ' + (item.exit ?? 'unknown'), 'delta'));
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
  element('older').hidden = !more;
  after = Math.max(after, first - 1);
  while (items.get(after + 1)?.final) after++;
  return view;
}

function refreshComposer() {
  const sendButton = element('send');
  const blocked = composerBlocked(), working = state.working && !blocked;
  const available = element('field').inert && !blocked;
  element('field').inert = blocked;
  if (available) focusComposer();
  element('field').classList.toggle('blocked', blocked);
  element('field').classList.toggle('working', working);
  element('field').classList.toggle('drop', draft.hover);
  editor.placeholder(draft.hover ? 'Drop to attach' : working ? 'Steer koa…' : 'Message koa…');
  const text = editor.text();
  sendButton.disabled = blocked || !working && !canSend(text);
  sendButton.className = 'act' + (sendButton.disabled ? ' off' : working ? ' stop' : '');
  sendButton.setAttribute('aria-label', working ? 'Stop' : 'Send');
  if (buttonWorking !== working) {
    buttonWorking = working;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 16 16');
    const shape = document.createElementNS(svg.namespaceURI, working ? 'rect' : 'path');
    if (working) { for (const [key, value] of Object.entries({ x: 4, y: 4, width: 8, height: 8, rx: 1.5 })) shape.setAttribute(key, String(value)); shape.setAttribute('fill', 'currentColor'); shape.setAttribute('stroke', 'none'); }
    else shape.setAttribute('d', 'M3 8h9.5M8.3 3.8 12.5 8l-4.2 4.2');
    svg.append(shape); sendButton.replaceChildren(svg);
  }
  composerHint(status());
}
function composerHint(working: string) {
  const hint = element('hint');
  if (state.working && !composerBlocked()) {
    if (hint.firstElementChild?.className !== 'spin') hint.replaceChildren(node('span', undefined, 'spin'), node('span'), node('kbd', '⎋'), node('span', ' abort'));
    const clock = hint.children[1];
    if (clock) clock.textContent = working + ' · ';
  } else hint.textContent = editor.empty() ? '' : '⇧↩ newline';
}
function status() {
  const working = workingText();
  const waiting = state.dialogs.length > 0;
  element('status').textContent = hasExited() ? 'pi exited · ' + exitCause() : waiting ? 'waiting for you' : state.pi.type === 'starting' ? 'starting' : state.working ? working : state.aborted ? 'aborted' : 'idle';
  element('dot').className = 'dot' + (hasExited() ? ' off' : waiting ? ' wait' : state.working ? ' on' : '');
  element('model').textContent = state.model?.id ?? '';
  element('thinking').textContent = state.thinking ? '· thinking ' + state.thinking : '';
  const context = state.context, percent = context?.percent;
  element('tokens').textContent = context ? (context.tokens === null ? '—' : Math.round(context.tokens / 1000) + 'k') + ' / ' + Math.round(context.window / 1000) + 'k' : '';
  element('percent').textContent = percent === null || percent === undefined ? '—' : Math.round(percent) + '%';
  element('context-bar').classList.toggle('high', percent !== null && percent !== undefined && percent > 75);
  const bar = element('context-bar').firstElementChild;
  if (bar instanceof HTMLElement) bar.style.width = Math.min(100, Math.max(0, percent ?? 0)) + '%';
  const path = displayPath(state.cwd).replace(/\/$/, ''), slash = path.lastIndexOf('/');
  element('cwd').replaceChildren(node('span', path.slice(0, slash + 1), 'hide-n k'), node('span', path.slice(slash + 1)));
  return working;
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
  try { await takeBack(); await fetchJSON('/abort'); }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
function hasExited() { return state.pi.type === 'exited'; }
function exitCause() { return 'exited' in state.pi ? 'code ' + state.pi.exited : 'signal' in state.pi ? 'signal ' + state.pi.signal : 'failed' in state.pi ? state.pi.failed : undefined; }
function exited() {
  const host = element('exited'); host.hidden = !hasExited(); element('composer').hidden = hasExited();
  const pi = state.pi;
  const at = pi.type === 'exited' ? pi.at : undefined;
  if (shownExit === at) return;
  shownExit = at; host.replaceChildren();
  if (pi.type !== 'exited') return;
  closePicker();
  const card = node('div', undefined, 'card'), head = node('div', undefined, 'head');
  const title = node('span', 'pi exited ', 'title'); title.append(node('span', '· ' + exitCause(), 'err')); head.append(title, node('span', timestamp(pi.at), 'count'));
  const actions = node('div', "last 5 lines of pi's stderr · the whole output is in the pane's terminal", 'acts'), start = button('Start pi again', '↩', true);
  start.onclick = async () => { start.disabled = true; try { await fetchJSON('/pi/start'); } catch (error) { reportError(error); start.disabled = false; } };
  actions.append(node('span', undefined, 'sp'), start); card.append(head, node('pre', pi.stderr || ''));
  if (!state.sessionFile) card.append(node('div', 'No session file was saved. Start pi again starts a fresh session.', 'fresh'));
  card.append(actions); host.append(card); start.focus();
}
function closePicker() { element('picker').hidden = true; const trigger = pickerButton; pickerButton = undefined; if (trigger) { trigger.classList.remove('pick'); focusComposer(); } }
async function picker(kind: 'model' | 'thinking') {
  if (state.pi.type !== 'ready') return;
  const trigger = element(kind), host = element('picker');
  if (pickerButton === trigger) { closePicker(); return; }
  closePicker();
  let choices: { id: string; provider?: string }[];
  try { choices = kind === 'model' ? (await fetchJSON('/models', undefined, 'GET')).models : state.levels.map(id => ({ id })); }
  catch (error) { reportError(error); return; }
  pickerButton = trigger; trigger.classList.add('pick'); host.replaceChildren(); host.hidden = false; host.tabIndex = -1;
  host.style.left = Math.min(trigger.getBoundingClientRect().left, innerWidth - 244) + 'px';
  host.append(node('div', kind === 'model' ? 'Model' : 'Thinking', 'ph'));
  const current = (choice: { id: string; provider?: string }) => kind === 'model' ? choice.id === state.model?.id && choice.provider === state.model?.provider : choice.id === state.thinking;
  const rows = choices.map((choice, index) => {
    const row = node('button', undefined, 'row'); row.type = 'button'; row.tabIndex = -1;
    row.append(node('span', current(choice) ? '✓' : '', 'tick'), node('span', choice.id, 'n'));
    if (choice.provider) row.append(node('span', choice.provider, 'p'));
    row.onmouseenter = () => selection.mark(index); row.onclick = () => choose(index); host.append(row); return row;
  });
  const selection = cursor(rows, () => {});
  const choose = async (index: number) => { const choice = choices[index]; if (!choice) return; try { await fetchJSON('/' + kind, kind === 'model' ? { provider: choice.provider, modelId: choice.id } : { level: choice.id }); closePicker(); } catch (error) { reportError(error); } };
  host.append(node('div', '↑↓ move · ↩ choose · ⎋ close', 'hints')); selection.mark(Math.max(0, choices.findIndex(current))); host.focus();
  host.onkeydown = event => { if (event.metaKey || event.ctrlKey || event.isComposing) return; if (['ArrowUp', 'ArrowDown', 'Enter', 'Escape'].includes(event.key)) { event.preventDefault(); event.stopPropagation(); if (event.key === 'Escape') { closePicker(); } else if (event.key === 'Enter') void choose(selection.index); else selection.mark(selection.index + (event.key === 'ArrowDown' ? 1 : -1)); } };
}
function statuses() {
  const entries = Object.entries(state.statuses || {}).sort(([a], [b]) => a.localeCompare(b)), signature = JSON.stringify(entries);
  if (shownStatuses === signature) return;
  shownStatuses = signature;
  document.querySelectorAll('.status .ext').forEach(segment => segment.remove());
  for (const [key, text] of entries) {
    const segment = node('div', undefined, 'seg ext'); segment.append(node('span', key, 'k'), node('span', text)); element('notice').before(segment);
  }
}
function toast(record: Extract<PageRecord, { type: 'notify' }>) {
  clearTimeout(notificationTimer);
  const notice = node('button', undefined, 'toast ' + record.level); notice.type = 'button';
  notice.append(node('span', record.level === 'warning' ? '!' : record.level === 'error' ? '✕' : 'i', 'i'), node('span', record.message, 't'));
  notice.onclick = () => element('notice').replaceChildren(); element('notice').replaceChildren(notice);
  notificationTimer = setTimeout(() => { element('notice').replaceChildren(); }, 4000);
}
function apply(record: PageRecord) {
  if (record.type === 'reset') {
    epoch = record.epoch; after = -1; first = undefined; items.clear(); views.clear(); texts.clear(); folds.clear(); pagingPatches.length = 0; more = record.more;
    element('items').replaceChildren();
    element('older').hidden = !more;
    for (const item of record.items) put(item);
    refreshComposer();
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
    state = record; refreshComposer(); dialogs(); queue(); exited();
    if (state.pi.type === 'ready' && state.editor && editorId !== state.editor.id) {
      editor.setText(state.editor.text); editorId = state.editor.id;
      void fetchJSON('/editor/ack', { id: state.editor.id }).catch(reportError);
    }
    statuses();
  } else if (record.type === 'notify') toast(record);
}

function followBottom() {
  if (scrollFrame !== undefined) return;
  scrollFrame = requestAnimationFrame(() => { scrollFrame = undefined; if (follow) element('scroll').scrollTop = element('scroll').scrollHeight; });
}
const metricsMode = document.querySelector<HTMLMetaElement>('meta[name="koa-metrics"]')?.content;
const metrics: { mode: string; bytes: number; pending: number[]; samples: { t: number; bytes: number; clockError: number; applied?: number; frame?: number }[]; timer?: number; writes: Promise<void>; frames: Set<Promise<void>>; error?: string } | undefined = metricsMode ? { mode: metricsMode, bytes: 0, pending: [], samples: [], timer: undefined, writes: Promise.resolve(), frames: new Set(), error: undefined } : undefined;
function sendMetrics(force = false) {
  if (!metrics || !force && !metrics.samples.length) return;
  clearTimeout(metrics.timer); metrics.timer = undefined;
  const samples = metrics.samples.splice(0, 50);
  metrics.writes = metrics.writes.then(async () => {
    const response = await fetch('/metrics', { method: 'POST', body: JSON.stringify(samples) });
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
function canSend(text: string) { return !!nameCommand(text) || !draft.busy && draft.count <= ATTACHMENT_LIMITS.files && (!!text.trim() || draft.count > 0); }
function reportError(error: unknown) { element('error').textContent = error instanceof Error ? error.message : String(error); }
async function send(mode: PromptMode = 'prompt') {
  const text = editor.text(), name = nameCommand(text), files = name ? [] : draft.files;
  if (!canSend(text) || submitting) return;
  submitting = true;
  try { await fetchJSON('/prompt', { text, mode, attachments: files.map(file => file.id) }); if (!name) draft.sent(files); if (editor.text() === text) editor.setText(''); refreshComposer(); focusComposer(); element('error').textContent = ''; }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
element('send').onclick = () => state.working ? stop() : send();
element('older').onclick = older;
const isControl = (target: EventTarget | null) => target instanceof HTMLElement && (target.isContentEditable || target.closest('input,textarea,select,button,[role=button],[role=option],[role=listbox],[role=menuitem]'));
function focusComposer() { if (document.hasFocus() && !element('field').inert && !state.dialogs.length && !pickerButton && (!isControl(document.activeElement) || editor.hasFocus())) editor.focus(); }
window.addEventListener('focus', focusComposer);
window.addEventListener('load', focusComposer);
document.addEventListener('keydown', event => { if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.isComposing || state.dialogs.length || pickerButton) return; if (!element('field').inert && !event.altKey && event.key.length === 1 && !(event.key === ' ' && isControl(event.target)) && !(event.target instanceof HTMLElement && (event.target.isContentEditable || event.target.closest('input,textarea,select')))) { event.preventDefault(); editor.focus(); editor.insert(event.key); return; } if (event.key === 'Enter' && hasExited() && event.target === document.body) element('exited').querySelector('button')?.click(); if (event.key === 'Escape') { event.preventDefault(); if (escaped) { editor.setText(''); } else { escaped = true; if (state.working) void stop(); } } });
element('model').onclick = () => picker('model'); element('thinking').onclick = () => picker('thinking');
document.addEventListener('pointerdown', event => { if (!element('picker').contains(event.target instanceof Node ? event.target : null) && event.target !== pickerButton) closePicker(); });
element('scroll').onscroll = () => { const scroll = element('scroll'); follow = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 60; if (scroll.scrollTop < 80) void older(); };
setInterval(() => composerHint(status()), 1000);
new ResizeObserver(followBottom).observe(element('scroll'));
new ResizeObserver(([entry]) => {
  document.body.style.setProperty('--dock-h', entry.borderBoxSize[0].blockSize + 'px');
  followBottom();
}).observe(element('dock'));
refreshComposer(); focusComposer(); void connect();
