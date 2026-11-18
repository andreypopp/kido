import { markdownLine } from './markdown.ts';
import type { AgentCall, Block, WireAssistant, WireItem } from '../koa-records.ts';

export type StepInput = { block: Exclude<Block, { type: 'text' }>; item: WireAssistant };
export type AgentCard = AgentCall | Extract<WireItem, { kind: 'agent' }>;
export type Part =
  | { kind: 'redacted' | 'command' | 'cwd' | 'cut'; text: string }
  | { kind: 'head'; text: string }
  | { kind: 'diff'; text: string; mark: string; change: 'ctx' | 'del' | 'add' }
  | { kind: 'log'; job: Extract<Block, { type: 'tool' }>['job'] & object; text: string }
  | { kind: 'result'; text: string; note: boolean };

export function toolArgs(block: Extract<Block, { type: 'tool' }>): Record<string, unknown> {
  try { const value = JSON.parse(block.args.text); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  catch { return {}; }
}
export function stepInfo(step: StepInput & { args: Record<string, unknown> }) {
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

export const agentBody = (card: AgentCard) => card.text.text || (card.direction === 'out' && card.outcome?.ok === false ? card.outcome.message : '');

export function stepParts(step: StepInput & { args: Record<string, unknown> }, info: ReturnType<typeof stepInfo>, cwd: string, images: boolean): Part[] {
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
