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
let state = { working: false, queue: { steering: [], followUp: [] }, dialogs: [] };
let epoch = '', after = -1, first, more = false, paging = false, follow = true, delay = 200, scrollFrame;
let escaped = false, notificationTimer, dialogId, buttonWorking;
let submitting = false;
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
const duration = ms => ms === undefined ? '' : ms < 100 ? Math.round(ms) + 'ms' : Number((ms / 1000).toFixed(1)) + 's';
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
  line.onkeydown = event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); toggle(); } };
  view.append(line, details);
}
function run(steps) {
  steps = steps.map(step => { const value = { ...step, args: step.block.type === 'tool' ? args(step.block) : {} }; return { ...value, info: stepInfo(value) }; });
  const view = node('div', undefined, 'run');
  const line = node('div', undefined, 'line');
  const summary = node('span', undefined, 'sum');
  const failed = steps.filter(step => step.block.state?.type === 'done' && step.block.state.error);
  const aborted = steps.some(step => step.item.stop === 'aborted' && step.item.blocks.slice(step.index + 1).every(block => block.type !== 'text' || !block.text));
  const active = steps.find(step => step.block.state?.type === 'running') ?? steps.findLast(step => step.block.type === 'tool' ? step.block.state.type === 'pending' && !step.item.final : !step.item.final);
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
  const ended = timed.at(-1)?.block.ended ?? (active ? Date.now() : undefined);
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
    const result = block.state?.type === 'done' ? block.state.error ? info.kind === 'command' ? 'exit' + (block.exit === undefined ? '' : ' ' + block.exit) : 'failed' : '✓' : info.aborted ? 'aborted' : block.type === 'thinking' && step.item.final ? '✓' : '…';
    const outcome = node('span', undefined, block.state?.error ? 'time err' : 'time');
    outcome.append(node('span', result, block.state?.error ? 'err' : result === '✓' ? 'ok' : result === 'aborted' ? 'warn' : ''), ' ' + duration(block.durationMs ?? (block.started !== undefined && block.ended !== undefined ? block.ended - block.started : undefined)));
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
      const signature = JSON.stringify(steps.map(step => [step.block, step.item.final, step.item.stop]));
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
  const input = element('prompt'), button = element('send');
  element('empty').hidden = items.size > 0 || input.value.length > 0;
  element('field').classList.toggle('working', state.working);
  input.placeholder = state.working ? 'Steer koa…' : 'Message koa…';
  button.disabled = !state.working && !input.value.trim();
  button.className = 'act' + (state.working ? ' stop' : button.disabled ? ' off' : '');
  button.setAttribute('aria-label', state.working ? 'Stop' : 'Send');
  if (buttonWorking !== state.working) {
    buttonWorking = state.working;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 14 14');
    const shape = document.createElementNS(svg.namespaceURI, state.working ? 'rect' : 'path');
    if (state.working) { for (const [key, value] of Object.entries({ x: 3.5, y: 3.5, width: 7, height: 7, rx: 1 })) shape.setAttribute(key, value); shape.setAttribute('fill', 'currentColor'); shape.setAttribute('stroke', 'none'); }
    else shape.setAttribute('d', 'M3 7h8M7 3l4 4-4 4');
    svg.append(shape); button.replaceChildren(svg);
  }
  element('hint').textContent = [input.value ? '⇧↩ newline' : '', state.working ? '↩ steers while koa works' : ''].filter(Boolean).join(' · ');
  input.style.height = 'auto'; input.style.height = Math.min(promptMaxHeight, input.scrollHeight) + 'px';
}
function status() {
  const waiting = state.dialogs?.length > 0;
  element('status').textContent = state.pi ? 'pi exited' : waiting ? 'waiting for you' : state.working ? 'working ' + Math.max(0, Math.floor((Date.now() - (state.since ?? Date.now())) / 1000)) + 's' : state.aborted ? 'aborted' : 'idle';
  element('dot').className = 'dot' + (waiting ? ' wait' : state.working ? ' on' : '');
  element('model').textContent = state.model ?? '';
  element('thinking').textContent = state.thinking ? '· thinking ' + state.thinking : '';
  const context = state.context, percent = context?.percent;
  element('tokens').textContent = context ? (context.tokens === null ? '—' : Math.round(context.tokens / 1000) + 'k') + ' / ' + Math.round(context.window / 1000) + 'k' : '';
  element('percent').textContent = percent === null || percent === undefined ? '—' : Math.round(percent) + '%';
  element('context-bar').classList.toggle('high', percent > 75);
  element('context-bar').firstElementChild.style.width = Math.min(100, Math.max(0, percent ?? 0)) + '%';
  const path = (displayCwd() || '').replace(/\/$/, ''), slash = path.lastIndexOf('/');
  element('cwd').replaceChildren(node('span', path.slice(0, slash + 1), 'hide-n k'), node('span', path.slice(slash + 1)), ...(state.branch ? [node('span', '· ' + state.branch)] : []), ...(state.dirty ? [node('span', '*', 'warn')] : []));
}
function dialogs() {
  const request = state.dialogs?.[0];
  if (dialogId === request?.id) return;
  dialogId = request?.id;
  element('dialogs').replaceChildren();
  if (!request) return;
  const card = node('form', undefined, 'dialog');
  card.append(node('div', request.title || request.method));
  if (request.message) card.append(node('div', request.message));
  if (request.timeout) card.append(node('div', 'Timeout ' + request.timeout + 'ms', 'delta'));
  let field;
  if (request.method === 'select') {
    field = node('select'); for (const option of request.options || []) { const value = node('option', option); value.value = option; field.append(value); }
  } else if (request.method !== 'confirm') { field = node(request.method === 'editor' ? 'textarea' : 'input'); field.value = request.prefill || ''; field.placeholder = request.placeholder || ''; }
  if (field) card.append(field);
  const submit = node('button', request.method === 'confirm' ? 'Confirm' : 'Submit'); submit.type = 'submit';
  const cancel = node('button', 'Cancel'); cancel.type = 'button';
  const answer = async cancelled => {
    submit.disabled = cancel.disabled = true;
    try { await post('/dialog', { id: request.id, ...(cancelled ? { cancelled: true } : request.method === 'confirm' ? { confirmed: true } : { value: field.value }) }); }
    catch (error) { reportError(error); submit.disabled = cancel.disabled = false; }
  };
  card.onsubmit = event => { event.preventDefault(); void answer(false); }; cancel.onclick = () => answer(true);
  card.append(submit, cancel); element('dialogs').append(card);
}
function apply(record) {
  if (record.type === 'reset') {
    epoch = record.epoch; after = -1; first = undefined; items.clear(); views.clear(); texts.clear(); folds.clear(); pagingPatches.length = 0; more = record.more;
    element('items').replaceChildren();
    element('empty').hidden = record.items.length > 0;
    element('older').hidden = !more;
    for (const item of record.items) put(item);
  } else if (record.type === 'item') put(record.item);
  else if (record.type === 'patch') {
    const item = items.get(record.seq);
    if (!item) { if (paging) pagingPatches.push(record); return; }
    Object.assign(item, { final: record.final, stop: record.stop, error: record.error });
    for (const change of record.blocks) {
      if (change.block) { item.blocks[change.index] = change.block; texts.delete(record.seq + ':' + change.index); }
      else item.blocks[change.index].text += change.suffix;
    }
    put(item);
  } else if (record.type === 'state') {
    state = record; status(); composer(); dialogs();
    element('queue').replaceChildren();
    const queued = [...(state.queue?.steering || []), ...(state.queue?.followUp || [])];
    if (queued.length) { const button = node('button', queued.length + ' queued · edit'); button.onclick = async () => { try { const result = await post('/queue/clear'); element('prompt').value = [...(result.steering || []), ...(result.followUp || [])].join('\n'); composer(); } catch (error) { reportError(error); } }; element('queue').append(button); }
  } else if (record.type === 'editor') { element('prompt').value = record.text; composer(); }
  else if (record.type === 'notify') { clearTimeout(notificationTimer); element('notice').textContent = record.message; notificationTimer = setTimeout(() => { element('notice').textContent = ''; }, 4000); }
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
      while ((end = partial.indexOf('\n')) >= 0) { const line = partial.slice(0, end); partial = partial.slice(end + 1); if (line) apply(JSON.parse(line)); }
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
async function post(path, body = {}) {
  const response = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const result = await response.json(); if (!response.ok) throw Error(result.error || 'Request failed'); return result;
}
function reportError(error) { element('error').textContent = error.message; }
async function send(mode = 'prompt') {
  const input = element('prompt'), text = input.value; if (!text.trim() || submitting) return;
  submitting = true;
  try { await post('/prompt', { text, mode }); if (input.value === text) input.value = ''; composer(); input.focus(); element('error').textContent = ''; }
  catch (error) { reportError(error); }
  finally { submitting = false; }
}
element('send').onclick = () => state.working ? post('/abort').catch(reportError) : send();
element('older').onclick = older;
element('prompt').oninput = () => { escaped = false; composer(); };
element('prompt').onkeydown = event => { if (!event.isComposing && event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void send(event.altKey ? 'follow_up' : 'prompt'); } };
document.addEventListener('keydown', event => { if (event.key === 'Escape') { event.preventDefault(); if (escaped) { element('prompt').value = ''; composer(); } else { escaped = true; if (state.working) void post('/abort').catch(reportError); } } });
element('scroll').onscroll = () => { const scroll = element('scroll'); follow = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 60; if (scroll.scrollTop < 80) void older(); };
setInterval(status, 1000);
new ResizeObserver(followBottom).observe(element('scroll'));
composer(); element('prompt').focus(); void connect();
