import { markdownLine } from '../markdown-line.ts';
import type { AgentCall, Block, WireAssistant, WireItem } from '../koa-records.ts';

export type NoticeData = { key: string; at: number; name: 'note' | 'notify' | 'command' | 'error' | 'branch' | 'compacted'; level?: 'warning' | 'error'; content: { type: 'text'; text: string } | { type: 'markdown'; text: string } | { type: 'summary'; lead: string; text: string } | { type: 'command'; seq: number; result: Extract<WireItem, { kind: 'command' }>['result'] } };
export function noticeOf(item: WireItem): NoticeData | undefined {
  const base = { key: item.kind === 'assistant' ? item.seq + ':error' : 'notice:' + item.seq, at: item.at };
  switch (item.kind) {
    case 'assistant': return item.error ? { ...base, name: 'error', level: 'error', content: { type: 'text', text: item.error } } : undefined;
    case 'notify': return { ...base, name: 'notify', level: item.level === 'info' ? undefined : item.level, content: { type: 'text', text: item.text.text } };
    case 'notice': return { ...base, name: 'note', content: { type: 'markdown', text: item.text } };
    case 'summary': return { ...base, name: item.source === 'branch' ? 'branch' : 'compacted', content: { type: 'summary', lead: item.source === 'branch' ? 'branch' : 'compacted', text: item.text } };
    case 'command': return { ...base, name: 'command', level: item.result.type === 'compaction' && item.result.state.type === 'failed' ? 'error' : undefined, content: { type: 'command', seq: item.seq, result: item.result } };
    default: return undefined;
  }
}
const quantity = (value: number) => value >= 1000000 ? Number((value / 1000000).toFixed(1)) + 'M' : value >= 1000 ? Number((value / 1000).toFixed(1)) + 'k' : String(value);
export function sessionFields(result: Extract<Extract<WireItem, { kind: 'command' }>['result'], { type: 'session' }>) {
  const stats = result.stats;
  return [['name', result.name, false], ['id', stats.sessionId, true], ['file', stats.sessionFile ?? '—', true], ['model', result.model ? result.model.id + (result.thinking ? ' · thinking ' + result.thinking : '') : '—', false], ['messages', stats.totalMessages + ' · ' + stats.userMessages + ' user · ' + stats.assistantMessages + ' assistant · ' + stats.toolResults + ' tool', false], ['tokens', quantity(stats.tokens.input) + ' in · ' + quantity(stats.tokens.output) + ' out · ' + quantity(stats.tokens.cacheRead) + ' cache read · ' + quantity(stats.tokens.cacheWrite) + ' cache write', false], ['cost', '$' + stats.cost.toFixed(2), false], ['context', stats.contextUsage?.tokens === null || !stats.contextUsage ? '—' : quantity(stats.contextUsage.tokens) + ' / ' + quantity(stats.contextUsage.contextWindow) + (stats.contextUsage.percent === null ? '' : ' · ' + Math.round(stats.contextUsage.percent) + '%'), false]] as const;
}
export function noticeText(row: NoticeData): string {
  const content = row.content;
  if (content.type === 'text' || content.type === 'markdown') return content.text;
  if (content.type === 'summary') return content.lead + ' · ' + content.text;
  const result = content.result;
  switch (result.type) {
    case 'copy': return 'copied the last reply · ' + quantity(result.characters) + ' characters';
    case 'export': return 'exported ' + result.path;
    case 'session': return result.name + ' · ' + result.stats.totalMessages + ' messages · $' + result.stats.cost.toFixed(2);
    case 'compaction': switch (result.state.type) {
      case 'running': return 'compacting';
      case 'cancelled': return 'compaction cancelled';
      case 'failed': return 'compaction · ' + result.state.message;
    }
  }
}
export type StepInput =
  | { kind: 'notice'; item: WireItem; row: NoticeData }
  | { kind: 'block'; block: Exclude<Block, { type: 'text' }>; item: WireAssistant; index: number }
  | { kind: 'agent'; item: Extract<WireItem, { kind: 'agent' }> }
  | { kind: 'job'; item: Extract<WireItem, { kind: 'job' }> };
export type AgentCard = AgentCall | Extract<WireItem, { kind: 'agent' }>;
export type Part =
  | { kind: 'notice'; row: NoticeData }
  | { kind: 'redacted' | 'command' | 'cwd' | 'cut'; text: string }
  | { kind: 'head'; text: string }
  | { kind: 'diff'; text: string; mark: string; change: 'ctx' | 'del' | 'add' }
  | { kind: 'log'; job: Extract<Block, { type: 'tool' }>['job'] & object; text: string }
  | { kind: 'result'; text: string; note: boolean }
  | { kind: 'agent'; text: string }
  | { kind: 'job'; job: Extract<WireItem, { kind: 'job' }>['job']; text: string; facts: string };

export function toolArgs(block: Extract<Block, { type: 'tool' }>): Record<string, unknown> {
  try { const value = JSON.parse(block.args.text); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  catch { return {}; }
}
export function stepInfo(step: StepInput & { args: Record<string, unknown> }) {
  if (step.kind === 'notice') return { label: markdownLine(noticeText(step.row).split(/\r\n?|\n/)[0]), labelClass: 'notice' + (step.row.level ? ' ' + step.row.level : ''), detail: '', kind: step.row.name };
  const card = step.kind === 'agent' ? step.item : step.kind === 'block' && step.block.type === 'tool' ? step.block.agent : undefined;
  if (card) {
    const inbound = card.direction === 'in', ref = inbound ? card.from : card.to;
    let phrase: string = inbound ? card.inbound.form : card.call.tool === 'spawn' ? 'task' : card.call.mode === 'interrupt-and-steer' ? 'interrupt' : card.call.mode;
    const failed = card.direction === 'out' && card.outcome?.ok === false;
    if (card.direction === 'out' && card.outcome?.ok === false) phrase = card.call.tool === 'spawn' ? 'refused' : card.outcome.failure === 'refused' || card.outcome.failure === 'gone' ? card.outcome.failure : card.outcome.message;
    const direction = inbound ? 'from' : 'to';
    return { label: phrase + ' ' + direction + ' @' + ref.name, labelClass: 'agent-name', detail: markdownLine(agentBody(card)), kind: direction + ':' + (ref.session ?? ref.name), summary: direction + ' @' + ref.name, card, failed };
  }
  if (step.kind === 'job') {
    const { job, event } = step.item;
    const end = event.type === 'ended' ? event.end : undefined;
    let detail: string;
    if (event.type === 'stream') detail = event.batch.text.split('\n').length + ' lines';
    else switch (event.end.type) {
      case 'exit': detail = 'exit ' + event.end.code; break;
      case 'signal': detail = 'signal ' + event.end.signal; break;
      case 'failed': detail = 'failed'; break;
      case 'stopped': detail = 'stopped'; break;
      case 'timeout': detail = 'timeout ' + event.end.seconds + 's'; break;
    }
    return { label: 'job ' + job.name, labelClass: 'job-name', detail, kind: 'job:' + job.id, summary: 'job ' + job.name, failed: !!end && (end.type === 'exit' ? end.code !== 0 : end.type !== 'stopped') };
  }
  if (step.kind !== 'block') throw Error('Missing agent step');
  const { block, item } = step;
  if (block.type === 'thinking') {
    const first = block.text.indexOf('\n');
    const second = first < 0 ? -1 : block.text.indexOf('\n', first + 1);
    return { label: 'thinking', labelClass: 'name', detail: block.redacted ? 'redacted' : markdownLine(second < 0 ? block.text : block.text.slice(0, second)), kind: 'thinking' };
  }
  const values = step.args;
  const kind = block.name;
  if (block.name === 'async_bash' && block.job && block.state.type === 'done' && !block.state.error) return { label: 'job ' + block.job.name, labelClass: 'job-name', detail: 'started', kind: 'job:' + block.job.id, summary: 'job ' + block.job.name };
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

export const agentBody = (card: AgentCard) => card.text.text || (card.direction === 'out' && card.outcome?.ok === false ? card.outcome.message : '');

export function stepParts(step: StepInput & { args: Record<string, unknown> }, info: ReturnType<typeof stepInfo>, cwd: string, images: boolean): Part[] {
  if (step.kind === 'notice') return [{ kind: 'notice', row: step.row }];
  if (info.card) return [{ kind: 'agent', text: agentBody(info.card) }];
  if (step.kind === 'job') {
    const { event, job } = step.item, text = event.type === 'stream' ? event.batch : event.tail;
    const facts = [text.cut ? text.cut + ' bytes omitted' : '', event.type === 'stream' && event.omitted ? event.omitted + ' lines omitted' : '', event.type === 'stream' && event.cut ? 'long lines truncated' : ''].filter(Boolean).join(' · ');
    return [{ kind: 'job', job, text: text.text, facts }];
  }
  if (step.kind !== 'block') return [];
  const { block } = step, parts: Part[] = [];
  const log = (job: NonNullable<Extract<Block, { type: 'tool' }>['job']>): Part => ({ kind: 'log', job, text: 'log: ' + job.log + (job.gone ? '' : ' open') });
  if (block.type === 'thinking' && block.redacted) parts.push({ kind: 'redacted', text: block.text || 'Redacted thinking' });
  else if (block.type === 'tool') {
    if (info.edit) {
      const { old, next, prefix, suffix } = info.edit;
      parts.push({ kind: 'head', text: info.label });
      old.slice(0, prefix).forEach(text => parts.push({ kind: 'diff', text, mark: '', change: 'ctx' }));
      old.slice(prefix, old.length - suffix).forEach(text => parts.push({ kind: 'diff', text, mark: '−', change: 'del' }));
      next.slice(prefix, next.length - suffix).forEach(text => parts.push({ kind: 'diff', text, mark: '+', change: 'add' }));
      if (suffix) old.slice(-suffix).forEach(text => parts.push({ kind: 'diff', text, mark: '', change: 'ctx' }));
    } else {
      if (block.name === 'async_bash') { if (typeof step.args.command === 'string') parts.push({ kind: 'command', text: step.args.command }); if (block.job) parts.push(log(block.job)); }
      else if (block.name === 'bash') { parts.push({ kind: 'cwd', text: 'cwd ' + cwd }); if (block.job) parts.push(log(block.job)); }
      if ((block.name !== 'async_bash' || !block.job) && 'result' in block.state && block.state.result?.text) parts.push({ kind: 'result', text: block.state.result.text, note: images && block.name === 'read' });
    }
    if ('result' in block.state && block.state.result?.cut) parts.push({ kind: 'cut', text: block.state.result.cut + ' bytes omitted' });
  }
  return parts;
}
