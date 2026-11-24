import type { JobEnd, JobPlace, JobSnapshot } from '../records.ts';
import type { LogChunk, PageRecord, View } from '../koa-records.ts';
import { createOutput, type StyledLine } from './job-output.ts';

type JobView = Extract<View, { type: 'job' }>;
type Reset = Extract<PageRecord, { type: 'job-reset' }>;
type Append = Extract<PageRecord, { type: 'job-append' }>;

type JobEnv = {
  root: HTMLElement;
  foot: { dot: HTMLElement; word: HTMLElement; time: HTMLElement; count: HTMLElement; act: HTMLElement };
  node<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string): HTMLElementTagNameMap[K];
  log(label: HTMLElement): void;
  earlier(id: string, epoch: string, before: number): Promise<LogChunk>;
  act(action: 'stop' | 'clear', id: string): void;
  resync(): void;
  changed(): void;
  reportError(error: unknown): void;
};

const bytes64 = (data: string): Uint8Array => Uint8Array.from(atob(data), char => char.charCodeAt(0));
const at = (ms: number) => new Date(ms).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
const size = (value: number) => value >= 1e6 ? Number((value / 1e6).toFixed(1)) + ' MB' : value >= 1e3 ? Number((value / 1e3).toFixed(1)) + ' kB' : value + ' B';
function clock(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000)), pad = (value: number) => String(value).padStart(2, '0');
  return seconds >= 3600 ? Math.floor(seconds / 3600) + 'h ' + pad(Math.floor(seconds / 60) % 60) + 'm' : seconds >= 60 ? Math.floor(seconds / 60) + 'm ' + pad(seconds % 60) + 's' : seconds + 's';
}
const place = (value: JobPlace) => value.type === 'runtime' ? 'runtime ' + value.name : value.type === 'remote' ? value.host : value.type === 'mac' ? 'this Mac' : 'this machine';

function outcome(end: JobEnd, at_: number): { word: string; lead: string; rest: string; tone: 'ok' | 'err' | '' } {
  const when = ' · ' + at(at_);
  switch (end.type) {
    case 'exit': return { word: end.code === 0 ? 'done' : 'exit ' + end.code, lead: 'exit ' + end.code, rest: when, tone: end.code === 0 ? 'ok' : 'err' };
    case 'signal': return { word: 'signal ' + end.signal, lead: 'signal ' + end.signal, rest: when, tone: 'err' };
    case 'failed': return { word: 'failed', lead: 'failed', rest: ' · ' + end.message, tone: 'err' };
    case 'timeout': return { word: 'timeout ' + clock(end.seconds * 1000), lead: 'timeout', rest: when, tone: 'err' };
    case 'stopped': return { word: 'stopped', lead: 'stopped', rest: when, tone: '' };
  }
}

export function createJobPage(env: JobEnv) {
  const { node, root } = env, { dot, word, time, count, act } = env.foot;
  const header = node('div', undefined, 'jhd'), older = node('button', undefined, 'jolder'), out = node('pre', undefined, 'jout'), end = node('div', undefined, 'jend');
  older.hidden = out.hidden = end.hidden = true;
  root.append(older, header, out, end);
  let view: JobView | undefined, loaded: { id: string; epoch: string; start: number; end: number; chunks: Uint8Array[]; output: ReturnType<typeof createOutput>; rows: HTMLElement[]; pending?: Promise<boolean> } | undefined;
  let gone = false;

  const row = (line: StyledLine) => {
    const result = node('div', undefined, 'ln');
    result.dataset.byte = String(line.byte);
    for (const span of line.spans) {
      const part = node('span', span.text);
      if (span.bold) part.style.fontWeight = '600';
      if (span.dim) part.style.opacity = '.6';
      if (span.fg !== undefined) part.style.color = 'var(--ko-color-' + span.fg + ')';
      if (span.bg !== undefined) { part.style.background = 'var(--ko-color-' + span.bg + ')'; }
      result.append(part);
    }
    if (!line.spans.length) result.append(node('br'));
    return result;
  };
  const paint = (replaceFrom: number, lines: StyledLine[]) => {
    if (!loaded) return;
    for (const stale of loaded.rows.splice(replaceFrom)) stale.remove();
    const rows = lines.map(row);
    out.append(...rows); loaded.rows.push(...rows);
    out.hidden = !loaded.rows.length && !gone;
  };
  const joined = (chunks: Uint8Array[]) => { const all = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0)); let offset = 0; for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.length; } return all; };
  const render = (start: number, bytes: Uint8Array) => {
    if (!loaded) return;
    for (const stale of loaded.rows.splice(0)) stale.remove();
    loaded.output = createOutput(start, start > 0);
    paint(0, loaded.output.append(bytes).lines);
  };

  const drawHeader = (job: JobSnapshot, owner: { id: string; name: string } | undefined) => {
    const name = env.node('div', job.name, 'nm');
    if (job.service) name.append(env.node('span', 'service', 'svc'));
    const command = env.node('div', job.command, 'cmd'), facts = env.node('div', undefined, 'facts');
    const by = env.node('a', owner ? '@' + owner.name : '', 'who'); if (owner) by.dataset.view = owner.id;
    const started = env.node('span'); started.append(env.node('span', 'started ', 'k'), at(job.startedAt));
    if (owner) started.append(env.node('span', ' by ', 'k'), by);
    const where = env.node('span'); where.append(env.node('span', 'on ', 'k'), place(job.place));
    const path = env.node('a', job.log, 'path'); path.href = '/job/log'; path.target = '_blank'; path.rel = 'noopener';
    env.log(path);
    const log = env.node('span'); log.append(env.node('span', 'log ', 'k'), path);
    facts.append(started, where, log);
    header.replaceChildren(name, command, facts);
  };
  const drawFoot = () => {
    if (!view) return;
    const { job } = view, state = job.state;
    const finished = state.type === 'ended' ? outcome(state.end, state.at) : undefined;
    dot.className = 'dot' + (state.type === 'running' ? ' on' : finished?.tone === 'err' ? ' off' : '');
    word.textContent = state.type === 'running' ? 'running' : state.type === 'cleared' ? 'cleared' : finished?.word ?? '';
    const elapsed = state.type === 'running' ? Date.now() - job.startedAt : state.type === 'ended' ? state.at - job.startedAt : undefined;
    time.textContent = elapsed !== undefined && !(state.type === 'ended' && (state.end.type === 'timeout' || state.end.type === 'stopped' || state.end.type === 'failed' || state.end.type === 'signal')) ? clock(elapsed) : '';
    count.textContent = loaded ? size(loaded.end) : '';
    act.hidden = state.type === 'cleared';
    act.textContent = state.type === 'running' ? 'Stop' : 'Clear';
    act.classList.toggle('stop', state.type === 'running');
  };
  const drawEnd = () => {
    const state = view?.job.state;
    end.hidden = state?.type !== 'ended';
    if (state?.type !== 'ended') return;
    const result = outcome(state.end, state.at);
    end.replaceChildren(env.node('span', result.lead, result.tone), result.rest);
  };
  const drawOlder = () => {
    older.hidden = !loaded || loaded.start === 0;
    if (loaded && loaded.start > 0) older.textContent = 'Load earlier output · ' + size(loaded.start) + ' on disk';
  };
  const missing = () => { loaded?.rows.splice(0); gone = true; out.hidden = false; out.replaceChildren(env.node('span', 'the log is gone', 'gone')); };

  const earlier = (): Promise<boolean> => {
    const current = loaded;
    if (!current || current.start === 0) return Promise.resolve(false);
    return current.pending ??= env.earlier(current.id, current.epoch, current.start).then(chunk => {
      if (loaded !== current || chunk.end !== current.start) return false;
      const all = joined([bytes64(chunk.data), ...current.chunks]);
      current.chunks = [all];
      current.start = chunk.start;
      render(current.start, all);
      drawOlder();
      env.changed();
      return true;
    }).catch(error => { if (loaded === current) { if (error?.status === 404) missing(); else env.reportError(error); } return false; }).finally(() => { current.pending = undefined; env.changed(); });
  };
  older.onclick = () => { void earlier(); };
  act.onclick = () => { if (view) env.act(view.job.state.type === 'running' ? 'stop' : 'clear', view.id); };

  return {
    get pending() { return loaded?.pending !== undefined; },
    rows: () => loaded?.rows ?? [],
    row(byte: number) {
      const rows = loaded?.rows ?? [];
      let low = 0, high = rows.length;
      while (low < high) { const middle = (low + high) >> 1; if (Number(rows[middle].dataset.byte) < byte) low = middle + 1; else high = middle; }
      return rows[low]?.dataset.byte === String(byte) ? rows[low] : undefined;
    },
    start: () => loaded?.start ?? 0,
    earlier,
    show(next: JobView) {
      if (view?.id !== next.id) { loaded = undefined; gone = false; out.replaceChildren(); out.hidden = true; older.hidden = true; }
      view = next;
      const owner = next.path.at(-2);
      drawHeader(next.job, owner);
      drawEnd(); drawFoot(); drawOlder();
    },
    hide() { view = undefined; loaded = undefined; gone = false; out.replaceChildren(); header.replaceChildren(); end.hidden = true; older.hidden = true; },
    tick() { drawFoot(); },
    gone(record: Extract<PageRecord, { type: 'job-gone' }>) { if (view?.id === record.view) missing(); },
    cursor: () => loaded?.end ?? 0,
    reset(record: Reset) {
      if (!view || view.id !== record.view) return;
      const first = bytes64(record.data);
      gone = false; out.replaceChildren();
      loaded = { id: record.view, epoch: record.epoch, start: record.start, end: record.end, chunks: [first], output: createOutput(record.start, record.start > 0), rows: [] };
      render(record.start, first);
      drawOlder(); drawFoot();
    },
    append(record: Append) {
      if (!loaded || loaded.id !== record.view || loaded.epoch !== record.epoch) return;
      if (record.start > loaded.end) { env.resync(); return; }
      const data = bytes64(record.data), skip = loaded.end - record.start;
      if (skip >= data.length) return;
      const fresh = data.subarray(skip);
      loaded.chunks.push(fresh); loaded.end += fresh.length;
      const result = loaded.output.append(fresh, false);
      paint(result.replaceFrom, result.lines);
      drawFoot();
    },
  };
}
