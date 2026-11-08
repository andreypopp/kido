import { markdown } from './koa-markdown.js';

const element = id => document.getElementById(id);
const node = (tag, text, className) => {
  const result = document.createElement(tag);
  if (text !== undefined) result.textContent = text;
  if (className) result.className = className;
  return result;
};
const items = new Map();
const views = new Map();
const template = document.createElement('template');
const promptMaxHeight = parseFloat(getComputedStyle(element('prompt')).maxHeight);
const folds = new Map();
const texts = new Map();
let state = { pi: { type: 'starting' }, working: false, queue: { steering: [], followUp: [] }, dialogs: [] };
let epoch = '', after = -1, first, more = false, paging = false, follow = true, delay = 200, scrollFrame;
let escaped = false, notificationTimer, dialogId, buttonWorking;
let submitting = false, editorId, dialogTimer, shownExit, pickerButton, shownQueue, shownStatuses;
const pagingPatches = [];

if (!window.ko) {
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const theme = () => document.documentElement.toggleAttribute('data-browser-dark', scheme.matches);
  scheme.addEventListener('change', theme);
  theme();
}

function timestamp(at) {
  const date = new Date(at), today = new Date();
  const time = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  if (date.toDateString() === today.toDateString()) return time;
  return (date.getFullYear() === today.getFullYear() ? '' : date.getFullYear() + ' ') + date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ' ' + time;
}

function prose(key, source, final) {
  let memo = texts.get(key);
  if (!memo) { memo = { render: markdown(), view: node('div', undefined, 'msg assistant'), blocks: [] }; texts.set(key, memo); }
  if (memo.source === source && memo.final === final) return memo.view;
  memo.source = source; memo.final = final;
  memo.view.querySelector('.caret')?.remove();
  const blocks = memo.render(source, final);
  let first = 0;
  while (first < blocks.length && memo.blocks[first]?.block === blocks[first]) first++;
  for (const saved of memo.blocks.splice(first)) for (const child of saved.nodes) child.remove();
  for (const block of blocks.slice(first)) {
    template.innerHTML = block.html;
    const nodes = [...template.content.childNodes];
    if (!block.streaming) delete block.html;
    for (const pre of nodes.flatMap(child => child.nodeType === 1 ? [child, ...child.querySelectorAll('pre')] : []).filter(child => child.tagName === 'PRE')) {
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

const displayCwd = () => state.home && (state.cwd === state.home || state.cwd?.startsWith(state.home + '/')) ? '~' + state.cwd.slice(state.home.length) : state.cwd;
const duration = ms => ms === undefined ? '' : ms < 100 ? Math.round(ms) + 'ms' : ms >= 60000 ? Math.floor(ms / 60000) + 'm' + String(Math.floor(ms / 1000) % 60).padStart(2, '0') + 's' : Number((ms / 1000).toFixed(1)) + 's';
function args(block) {
  try { const value = JSON.parse(block.args.text); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  catch { return {}; }
}
function stepInfo(step) {
  const { block, item } = step;
  if (block.type === 'thinking') return { mark: '∴', label: 'thinking', detail: block.redacted ? 'redacted' : block.text.split('\n')[0], kind: 'thinking' };
  const values = step.args;
  const kind = ({ bash: 'command', edit: 'edit', read: 'read' })[block.name] || block.name;
  const first = Object.values(values)[0];
  const label = block.name === 'bash' ? values.command : ['read', 'edit', 'write'].includes(block.name) ? values.path : block.name + (first === undefined ? '' : ' ' + (typeof first === 'string' ? first : JSON.stringify(first)));
  let detail = '';
  if (block.name === 'read' && block.state.result) detail = block.state.result.text.split('\n').length + ' lines';
  let edit;
  if (block.name === 'edit' && typeof values.oldText === 'string' && typeof values.newText === 'string') {
    const old = values.oldText.split('\n'), next = values.newText.split('\n');
    let prefix = 0, suffix = 0;
    while (prefix < old.length && prefix < next.length && old[prefix] === next[prefix]) prefix++;
    while (suffix < old.length - prefix && suffix < next.length - prefix && old[old.length - 1 - suffix] === next[next.length - 1 - suffix]) suffix++;
    edit = { old, next, prefix, suffix };
    detail = '+' + (next.length - prefix - suffix) + ' −' + (old.length - prefix - suffix);
  }
  return { edit, mark: ({ bash: '$', edit: '✎', read: '◇' })[block.name] || '◇', label: typeof label === 'string' ? label : label === undefined ? block.name + ' ' + block.args.text : JSON.stringify(label), detail, kind, aborted: item.stop === 'aborted' && block.state.type !== 'done' };
}
function fold(view, key, line, details) {
  view.classList.toggle('open', folds.get(key) === true);
  line.setAttribute('role', 'button'); line.tabIndex = 0;
  line.setAttribute('aria-expanded', String(folds.get(key) === true));
  const toggle = () => { const open = !view.classList.contains('open'); folds.set(key, open); view.classList.toggle('open', open); line.setAttribute('aria-expanded', String(open)); };
  line.onclick = toggle;
  line.onkeydown = event => { if (!event.metaKey && !event.ctrlKey && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); toggle(); } };
  view.append(line, details);
}
function run(steps) {
  steps = steps.map(step => { const value = { ...step, args: step.block.type === 'tool' ? args(step.block) : {} }; return { ...value, info: stepInfo(value) }; });
  const view = node('div', undefined, 'run');
  const line = node('div', undefined, 'line');
  const summary = node('span', undefined, 'sum');
  const failed = steps.filter(step => step.block.state?.type === 'done' && step.block.state.error);
  const aborted = steps.some(step => step.item.stop === 'aborted' && step.item.blocks.slice(step.index + 1).every(block => block.type !== 'text' || !block.text));
  const active = steps.find(step => step.block.state?.type === 'running') ?? steps.findLast(step => step.block.type === 'tool' ? step.block.state.type === 'pending' && !step.item.final : !step.item.final && step.block.ended === undefined);
  if (aborted) summary.append(node('span', '⊘', 'warn'), ' aborted · ' + steps.length + ' steps, you pressed Escape');
  else if (failed.length) summary.append(node('span', '✕', 'err'), ' ' + steps.length + ' steps · ' + failed.length + ' ' + failed[0].info.kind + (failed.length === 1 ? '' : 's') + ' failed');
  else if (active) summary.append(node('span', undefined, 'spin'), ' running ', node('b', active.info.label), ' · step ' + (steps.indexOf(active) + 1) + ' of ' + steps.length);
  else {
    const counts = new Map();
    for (const step of steps) { const kind = step.info.kind; counts.set(kind, (counts.get(kind) || 0) + 1); }
    summary.append(node('span', '✓', 'ok'), ' ' + steps.length + ' steps · ' + [...counts].map(([kind, count]) => kind === 'thinking' ? 'thinking' : count + ' ' + kind + (count === 1 ? '' : 's')).join(', '));
  }
  const timed = steps.filter(step => step.block.started !== undefined);
  const started = steps[0].block.started ?? steps[0].item.at;
  const ended = aborted ? steps.at(-1).item.ended : timed.at(-1)?.block.ended ?? (active ? Date.now() : undefined);
  line.append(node('span', '›', 'chev'), summary, node('span', duration(started === undefined || ended === undefined ? undefined : ended - started), 'time'));
  const children = node('div', undefined, 'steps');
  for (const step of steps) {
    const { block, key, info } = step;
    const child = node('div', undefined, 'step');
    const row = node('div', undefined, 'line');
    const sum = node('span', undefined, 'sum');
    sum.append(node('span', info.label, 'cmd'), ' ');
    const counts = info.detail.match(/^\+(\d+) −(\d+)$/);
    if (counts) sum.append(node('span', '+' + counts[1], 'ok'), ' ', node('span', '−' + counts[2], 'err'));
    else sum.append(node('span', info.detail, 'delta'));
    const result = block.state?.type === 'done' ? block.state.error ? info.kind === 'command' ? 'exit' + (block.exit === undefined ? '' : ' ' + block.exit) : 'failed' : '✓' : info.aborted ? 'aborted' : block.type === 'thinking' && (block.ended !== undefined || step.item.final) ? '✓' : '…';
    const outcome = node('span', undefined, block.state?.error ? 'time err' : 'time');
    const ended = block.ended ?? (info.aborted ? step.item.ended : undefined);
    outcome.append(node('span', result, block.state?.error ? 'err' : result === '✓' ? 'ok' : result === 'aborted' ? 'warn' : ''), ' ' + duration(block.durationMs ?? (block.started !== undefined && ended !== undefined ? ended - block.started : undefined)));
    row.append(node('span', '›', 'chev'), node('span', info.mark, 'mark'), sum, outcome);
    const detail = node('div', undefined, 'detail');
    if (block.type === 'thinking') detail.append(node('div', block.text || (block.redacted ? 'Redacted thinking' : ''), 'think'));
    else {
      if (info.edit) {
        const diff = node('div', undefined, 'diff'); diff.append(node('div', info.label, 'h'));
        const { old, next, prefix, suffix } = info.edit;
        const line = (text, mark, kind) => { const row = node('div', undefined, 'l ' + kind); row.append(node('span', mark, 'g'), text); diff.append(row); };
        old.slice(0, prefix).forEach(text => line(text, '', 'ctx'));
        old.slice(prefix, old.length - suffix).forEach(text => line(text, '−', 'del'));
        next.slice(prefix, next.length - suffix).forEach(text => line(text, '+', 'add'));
        if (suffix) old.slice(-suffix).forEach(text => line(text, '', 'ctx'));
        detail.append(diff);
      } else {
        if (block.name === 'bash') detail.append(node('div', 'cwd ' + displayCwd(), 'kv'));
        detail.append(node('pre', block.state.result?.text ?? block.args.text));
      }
      if (block.state.result?.cut) detail.append(node('div', block.state.result.cut + ' bytes omitted', 'delta'));
    }
    fold(child, key, row, detail); children.append(child);
  }
  fold(view, 'run:' + steps[0].key, line, children);
  return view;
}

function reconcileRuns(seq) {
  if (items.get(seq)?.kind !== 'assistant') return;
  let start = seq, end = seq;
  while (items.get(start - 1)?.kind === 'assistant') start--;
  while (items.get(end + 1)?.kind === 'assistant') end++;
  let steps = [];
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
    const item = items.get(current);
    item.blocks.forEach((block, index) => {
      if (block.type === 'text') flush();
      else steps.push({ block, item, index, key: item.seq + ':' + index });
    });
    if (item.error) flush();
  }
  flush();
}
function put(item) {
  items.set(item.seq, item);
  first = first === undefined ? item.seq : Math.min(first, item.seq);
  const signature = JSON.stringify(item);
  const previous = views.get(item.seq);
  if (previous?.signature === signature) return previous.view;
  const view = previous?.view ?? node('div');
  view.dataset.seq = item.seq;
  const children = [], slots = new Map();
  let steps = [];
  const flush = () => {
    if (steps.length) {
      const key = steps[0].key, slot = previous?.slots.get(key) ?? node('div');
      slots.set(key, slot); children.push(slot);
    }
    steps = [];
  };
  if (item.kind === 'assistant') {
    item.blocks.forEach((block, index) => {
      const key = item.seq + ':' + index;
      if (block.type === 'text') { flush(); if (block.text) children.push(prose(key, block.text, item.final)); }
      else steps.push({ block, item, key, index });
    });
    flush();
    if (item.error) children.push(node('div', item.error, 'msg err'));
  } else {
    view.className = 'msg ' + item.kind;
    if (item.kind === 'user') {
      const time = node('time', timestamp(item.at)); time.dateTime = new Date(item.at).toISOString();
      children.push(node('div', item.text + (item.images ? '\n' + item.images + ' images' : ''), 't'), time);
    } else if (item.kind === 'bash') children.push(node('div', '$ ' + item.command), node('pre', item.output.text), node('div', 'Exit ' + (item.exit ?? 'unknown'), 'delta'));
    else children.push(node('div', item.text, 'notice'));
  }
  children.forEach((child, index) => { if (view.childNodes[index] !== child) view.insertBefore(child, view.childNodes[index] ?? null); });
  while (view.childNodes.length > children.length) view.lastChild.remove();
  views.set(item.seq, { view, signature, slots });
  if (!previous) {
    const next = [...views.keys()].filter(seq => seq > item.seq).sort((a, b) => a - b)[0];
    element('items').insertBefore(view, views.get(next)?.view ?? null);
  }
  if (slots.size || previous?.slots.size || !previous) reconcileRuns(item.seq);
  element('empty').hidden = true;
  element('older').hidden = !more;
  after = Math.max(after, first - 1);
  while (items.get(after + 1)?.final) after++;
  return view;
}

function composer() {
  const input = element('prompt'), sendButton = element('send');
  const blocked = state.pi?.type === 'starting' || !!state.dialogs?.length, working = state.working && !blocked;
  element('field').inert = blocked;
  element('field').classList.toggle('blocked', blocked);
  element('empty').hidden = items.size > 0 || input.value.length > 0 || blocked || hasExited();
  element('field').classList.toggle('working', working);
  input.placeholder = working ? 'Steer koa…' : 'Message koa…';
  sendButton.disabled = blocked || !working && !input.value.trim();
  sendButton.className = 'act' + (sendButton.disabled ? ' off' : working ? ' stop' : '');
  sendButton.setAttribute('aria-label', working ? 'Stop' : 'Send');
  if (buttonWorking !== working) {
    buttonWorking = working;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 14 14');
    const shape = document.createElementNS(svg.namespaceURI, working ? 'rect' : 'path');
    if (working) { for (const [key, value] of Object.entries({ x: 3.5, y: 3.5, width: 7, height: 7, rx: 1 })) shape.setAttribute(key, value); shape.setAttribute('fill', 'currentColor'); shape.setAttribute('stroke', 'none'); }
    else shape.setAttribute('d', 'M3 7h8M7 3l4 4-4 4');
    svg.append(shape); sendButton.replaceChildren(svg);
  }
  element('hint').textContent = [input.value ? '⇧↩ newline' : '', working ? '↩ steers while koa works' : ''].filter(Boolean).join(' · ');
  input.style.height = 'auto'; input.style.height = Math.min(promptMaxHeight, input.scrollHeight) + 'px';
}
function status() {
  const waiting = state.dialogs?.length > 0;
  element('status').textContent = hasExited() ? 'pi exited · ' + exitCause() : waiting ? 'waiting for you' : state.pi?.type === 'starting' ? 'starting' : state.working ? 'working ' + Math.max(0, Math.floor((Date.now() - (state.since ?? Date.now())) / 1000)) + 's' : state.aborted ? 'aborted' : 'idle';
  element('dot').className = 'dot' + (hasExited() ? ' off' : waiting ? ' wait' : state.working ? ' on' : '');
  element('model').textContent = state.model?.id ?? '';
  element('thinking').textContent = state.thinking ? '· thinking ' + state.thinking : '';
  const context = state.context, percent = context?.percent;
  element('tokens').textContent = context ? (context.tokens === null ? '—' : Math.round(context.tokens / 1000) + 'k') + ' / ' + Math.round(context.window / 1000) + 'k' : '';
  element('percent').textContent = percent === null || percent === undefined ? '—' : Math.round(percent) + '%';
  element('context-bar').classList.toggle('high', percent > 75);
  element('context-bar').firstElementChild.style.width = Math.min(100, Math.max(0, percent ?? 0)) + '%';
  const path = (displayCwd() || '').replace(/\/$/, ''), slash = path.lastIndexOf('/');
  element('cwd').replaceChildren(node('span', path.slice(0, slash + 1), 'hide-n k'), node('span', path.slice(slash + 1)), ...(state.branch ? [node('span', '· ' + state.branch)] : []), ...(state.dirty ? [node('span', '*', 'warn')] : []));
}
function button(label, key, primary = false) {
  const result = node('button', label, 'btn' + (primary ? ' primary' : ''));
  result.type = 'button';
  if (key) result.append(node('kbd', key));
  return result;
}
function cursor(rows, onMark) {
  let index = 0;
  const mark = value => { index = Math.max(0, Math.min(rows.length - 1, value)); rows.forEach((row, i) => { row.classList.toggle('cur', i === index); onMark(row, i === index); }); rows[index]?.scrollIntoView({ block: 'nearest' }); };
  return { mark, get index() { return index; } };
}
function dialogs() {
  const request = state.dialogs?.[0], host = element('dialogs');
  host.querySelector('.queued-next')?.remove();
  if (state.dialogs?.length > 1) {
    const next = node('div', '+' + (state.dialogs.length - 1) + ' queued ', 'queued-next');
    next.append(node('b', '·'), node('b', state.dialogs[1].title)); host.append(next);
  }
  if (dialogId === request?.id) return;
  dialogId = request?.id;
  clearInterval(dialogTimer);
  host.querySelector('.dialog')?.remove();
  if (!request) { element('prompt').focus(); return; }
  const card = node('form', undefined, 'dialog'); card.tabIndex = -1;
  const head = node('div', undefined, 'head'); head.append(node('span', request.title, 'title')); card.append(head);
  if (request.message) card.append(node('div', request.message, 'msg2'));
  if (request.timeout) {
    const count = node('span', undefined, 'count'), fuse = node('span', undefined, 'fuse'); head.append(count); card.append(fuse);
    const end = request.expires ?? Date.now() + request.timeout;
    const left = Math.max(0, end - Date.now());
    fuse.style.width = Math.min(100, left / request.timeout * 100) + '%'; fuse.style.animation = 'burn ' + left + 'ms linear forwards';
    const tick = () => { count.textContent = Math.ceil(Math.max(0, end - Date.now()) / 1000) + 's'; };
    tick(); dialogTimer = setInterval(tick, 1000);
  }
  let field, selection;
  if (request.method === 'select') {
    const list = node('div', undefined, 'opts'); list.setAttribute('role', 'listbox');
    const options = request.options.map((text, index) => { const option = node('div', undefined, 'opt'); option.append(node('span', '', 'k'), node('span', text)); option.onclick = () => selection.mark(index); option.ondblclick = () => answer(false); list.append(option); return option; });
    selection = cursor(options, (row, chosen) => { row.firstElementChild.textContent = chosen ? '›' : ''; });
    selection.mark(0); card.append(list);
  } else if (request.method !== 'confirm') {
    field = node(request.method === 'editor' ? 'textarea' : 'input', undefined, 'in' + (request.method === 'editor' ? ' multi' : ''));
    field.value = request.prefill || ''; field.placeholder = request.placeholder || ''; field.setAttribute('aria-label', request.title); card.append(field);
  }
  const foot = node('div', undefined, 'foot'); foot.append(node('span', request.method === 'select' ? '↑↓ choose' : request.method === 'editor' ? '⇧↩ newline' : ''), node('span', undefined, 'sp'));
  const cancel = button(request.method === 'confirm' ? 'No' : 'Cancel', '⎋');
  const submit = button(request.method === 'confirm' ? 'Yes' : request.method === 'select' ? 'Select' : 'Submit', request.method === 'editor' ? '⌃↩' : '↩', true);
  const answer = async cancelled => {
    if (submit.disabled) return;
    submit.disabled = cancel.disabled = true;
    try { await fetchJSON('/dialog', { id: request.id, ...(cancelled ? { cancelled: true } : request.method === 'confirm' ? { confirmed: true } : { value: field ? field.value : request.options[selection.index] }) }); }
    catch (error) { reportError(error); submit.disabled = cancel.disabled = false; }
  };
  card.onsubmit = event => { event.preventDefault(); void answer(false); };
  submit.onclick = () => answer(false); cancel.onclick = () => answer(true);
  card.onkeydown = event => {
    if (event.metaKey || event.isComposing || event.ctrlKey && event.key !== 'Enter') return;
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); void answer(true); }
    else if (request.method === 'select' && ['ArrowUp', 'ArrowDown'].includes(event.key)) { event.preventDefault(); selection.mark(selection.index + (event.key === 'ArrowDown' ? 1 : -1)); }
    else if (request.method === 'select' && /^[1-9]$/.test(event.key)) { event.preventDefault(); selection.mark(Number(event.key) - 1); }
    else if (event.key === 'Enter' && (request.method !== 'editor' || event.ctrlKey) && event.target !== cancel) { event.preventDefault(); void answer(false); }
  };
  foot.append(cancel, submit); card.append(foot); host.prepend(card); (field || card).focus();
}
function queue() {
  const entries = [...(state.queue?.steering || []).map(text => ['steer', text]), ...(state.queue?.followUp || []).map(text => ['follow-up', text])];
  const signature = JSON.stringify(entries);
  if (shownQueue === signature) return;
  shownQueue = signature;
  const host = element('queue'); host.replaceChildren();
  if (!entries.length) return;
  for (const [tag, text] of entries) { const row = node('div', undefined, 'q'); row.append(node('span', tag, 'tag'), node('span', text, 't')); host.append(row); }
  const take = node('div', entries.length + ' queued', 'take'), back = button('take back');
  take.append(node('span', undefined, 'sp'), back); host.append(take);
  back.onclick = async () => {
    back.disabled = true;
    try { await takeBack(); }
    catch (error) { reportError(error); back.disabled = false; }
  };
}
async function takeBack() {
  const result = await fetchJSON('/queue/clear'), input = element('prompt');
  input.value = [input.value, ...(result.steering || []), ...(result.followUp || [])].filter(Boolean).join('\n\n');
  composer(); input.focus(); input.setSelectionRange(input.value.length, input.value.length);
}
async function stop() {
  if (submitting) return;
  submitting = true;
  try { await takeBack(); await fetchJSON('/abort'); }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
function hasExited() { return state.pi?.type === 'exited'; }
function exitCause() { return 'exited' in state.pi ? 'code ' + state.pi.exited : 'signal' in state.pi ? 'signal ' + state.pi.signal : state.pi.failed; }
function exited() {
  const host = element('exited'); host.hidden = !hasExited(); element('composer').hidden = hasExited();
  if (shownExit === state.pi?.at) return;
  shownExit = state.pi?.at; host.replaceChildren();
  if (!hasExited()) return;
  closePicker();
  const card = node('div', undefined, 'card'), head = node('div', undefined, 'head');
  const title = node('span', 'pi exited ', 'title'); title.append(node('span', '· ' + exitCause(), 'err')); head.append(title, node('span', timestamp(state.pi.at), 'count'));
  const actions = node('div', "last 5 lines of pi's stderr · the whole output is in the pane's terminal", 'acts'), start = button('Start pi again', '↩', true);
  start.onclick = async () => { start.disabled = true; try { await fetchJSON('/pi/start'); } catch (error) { reportError(error); start.disabled = false; } };
  actions.append(node('span', undefined, 'sp'), start); card.append(head, node('pre', state.pi.stderr || ''));
  if (!state.sessionFile) card.append(node('div', 'No session file was saved. Start pi again starts a fresh session.', 'fresh'));
  card.append(actions); host.append(card); start.focus();
}
function closePicker() { element('picker').hidden = true; pickerButton?.classList.remove('pick'); pickerButton = undefined; }
async function picker(kind) {
  if (state.pi?.type !== 'ready') return;
  const trigger = element(kind), host = element('picker');
  if (pickerButton === trigger) { closePicker(); return; }
  closePicker();
  let choices;
  try { choices = kind === 'model' ? (await fetchJSON('/models', undefined, 'GET')).models : state.levels.map(id => ({ id })); }
  catch (error) { reportError(error); return; }
  pickerButton = trigger; trigger.classList.add('pick'); host.replaceChildren(); host.hidden = false; host.tabIndex = -1;
  host.style.left = Math.min(trigger.getBoundingClientRect().left, innerWidth - 244) + 'px';
  host.append(node('div', kind === 'model' ? 'Model' : 'Thinking', 'ph'));
  const current = choice => kind === 'model' ? choice.id === state.model?.id && choice.provider === state.model?.provider : choice.id === state.thinking;
  const rows = choices.map((choice, index) => {
    const row = node('button', undefined, 'row'); row.type = 'button'; row.tabIndex = -1;
    row.append(node('span', current(choice) ? '✓' : '', 'tick'), node('span', choice.id, 'n'));
    if (choice.provider) row.append(node('span', choice.provider, 'p'));
    row.onmouseenter = () => selection.mark(index); row.onclick = () => choose(index); host.append(row); return row;
  });
  const selection = cursor(rows, () => {});
  const choose = async index => { const choice = choices[index]; if (!choice) return; try { await fetchJSON('/' + kind, kind === 'model' ? { provider: choice.provider, modelId: choice.id } : { level: choice.id }); closePicker(); trigger.focus(); } catch (error) { reportError(error); } };
  host.append(node('div', '↑↓ move · ↩ choose · ⎋ close', 'hints')); selection.mark(Math.max(0, choices.findIndex(current))); host.focus();
  host.onkeydown = event => { if (event.metaKey || event.ctrlKey || event.isComposing) return; if (['ArrowUp', 'ArrowDown', 'Enter', 'Escape'].includes(event.key)) { event.preventDefault(); event.stopPropagation(); if (event.key === 'Escape') { closePicker(); trigger.focus(); } else if (event.key === 'Enter') void choose(selection.index); else selection.mark(selection.index + (event.key === 'ArrowDown' ? 1 : -1)); } };
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
function toast(record) {
  clearTimeout(notificationTimer);
  const notice = node('button', undefined, 'toast ' + record.level); notice.type = 'button';
  notice.append(node('span', record.level === 'warning' ? '!' : record.level === 'error' ? '✕' : 'i', 'i'), node('span', record.message, 't'));
  notice.onclick = () => element('notice').replaceChildren(); element('notice').replaceChildren(notice);
  notificationTimer = setTimeout(() => { element('notice').replaceChildren(); }, 4000);
}
function apply(record) {
  if (record.type === 'reset') {
    epoch = record.epoch; after = -1; first = undefined; items.clear(); views.clear(); texts.clear(); folds.clear(); pagingPatches.length = 0; more = record.more;
    element('items').replaceChildren();
    element('older').hidden = !more;
    for (const item of record.items) put(item);
    composer();
  } else if (record.type === 'item') put(record.item);
  else if (record.type === 'patch') {
    const item = items.get(record.seq);
    if (!item) { if (paging) pagingPatches.push(record); return; }
    Object.assign(item, { final: record.final, stop: record.stop, error: record.error, ended: record.ended });
    for (const change of record.blocks) {
      if (change.block) { item.blocks[change.index] = change.block; texts.delete(record.seq + ':' + change.index); }
      else item.blocks[change.index].text += change.suffix;
    }
    put(item);
  } else if (record.type === 'state') {
    state = record; status(); composer(); dialogs(); queue(); exited();
    if (state.pi.type === 'ready' && state.editor && editorId !== state.editor.id) {
      element('prompt').value = state.editor.text; composer(); editorId = state.editor.id;
      void fetchJSON('/editor/ack', { id: state.editor.id }).catch(reportError);
    }
    statuses();
  } else if (record.type === 'notify') toast(record);
}

function followBottom() {
  if (scrollFrame !== undefined) return;
  scrollFrame = requestAnimationFrame(() => { scrollFrame = undefined; if (follow) element('scroll').scrollTop = element('scroll').scrollHeight; });
}
async function connect() {
  try {
    const response = await fetch('/events?epoch=' + encodeURIComponent(epoch) + '&after=' + after);
    if (!response.ok) throw Error('Connection failed');
    const reader = response.body.getReader(), decoder = new TextDecoder(); let partial = ''; delay = 200;
    element('error').textContent = '';
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      partial += decoder.decode(value, { stream: true });
      let end;
      while ((end = partial.indexOf('\n')) >= 0) { const line = partial.slice(0, end); partial = partial.slice(end + 1); if (line) { try { apply(JSON.parse(line)); } catch (error) { console.error(error); reportError(error); } } }
      followBottom();
    }
  } catch { element('error').textContent = 'Connection lost. Reconnecting…'; }
  setTimeout(connect, delay); delay = Math.min(delay * 2, 5000);
}
async function older() {
  if (!more || paging || first === undefined) return;
  paging = true;
  const scroll = element('scroll'), anchor = views.get(first)?.view;
  const top = anchor?.getBoundingClientRect().top;
  try {
    const response = await fetch('/items?before=' + first); if (!response.ok) throw Error('Could not load earlier messages');
    const result = await response.json();
    if (result.epoch === epoch) {
      more = result.more;
      for (const item of result.items) if (!items.has(item.seq)) put(item);
      for (const patch of pagingPatches.splice(0)) apply(patch);
      element('older').hidden = !more;
      if (anchor && top !== undefined) scroll.scrollTop += anchor.getBoundingClientRect().top - top;
    }
  } catch (error) { reportError(error); } finally { paging = false; }
}
async function fetchJSON(path, body = {}, method = 'POST') {
  const response = await fetch(path, { method, ...(method === 'GET' ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }) });
  const result = await response.json(); if (!response.ok) throw Error(result.error || 'Request failed'); return result;
}
function reportError(error) { element('error').textContent = error.message; }
async function send(mode = 'prompt') {
  const input = element('prompt'), text = input.value; if (!text.trim() || submitting) return;
  submitting = true;
  try { await fetchJSON('/prompt', { text, mode }); if (input.value === text) input.value = ''; composer(); input.focus(); element('error').textContent = ''; }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
element('send').onclick = () => state.working ? stop() : send();
element('older').onclick = older;
element('prompt').oninput = () => { escaped = false; composer(); };
element('prompt').onkeydown = event => { if (!event.metaKey && !event.ctrlKey && !event.isComposing && event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void send(event.altKey ? 'follow_up' : 'prompt'); } };
document.addEventListener('keydown', event => { if (event.metaKey || event.ctrlKey || event.isComposing || state.dialogs?.length) return; if (event.key === 'Enter' && hasExited() && event.target === document.body) element('exited').querySelector('button')?.click(); if (event.key === 'Escape') { event.preventDefault(); if (escaped) { element('prompt').value = ''; composer(); } else { escaped = true; if (state.working) void stop(); } } });
element('model').onclick = () => picker('model'); element('thinking').onclick = () => picker('thinking');
document.addEventListener('pointerdown', event => { if (!element('picker').contains(event.target) && event.target !== pickerButton) closePicker(); });
element('scroll').onscroll = () => { const scroll = element('scroll'); follow = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 60; if (scroll.scrollTop < 80) void older(); };
setInterval(status, 1000);
new ResizeObserver(followBottom).observe(element('scroll'));
composer(); element('prompt').focus(); void connect();
