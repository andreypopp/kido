import { runOwner, sourceKey, visibleText, type RunContext } from './extent.ts';
import { markdownPlain } from './markdown.ts';
import { agentBody, stepInfo, stepParts, toolArgs } from './steps.ts';
import type { WireItem } from '../koa-records.ts';

export type Segment = { text: string; lowered: string; folds: string[]; fences: string[]; lazy?: string; step?: string };
type Lookup = (seq: number) => WireItem | undefined;
export type FindContext = { items: Lookup; raw?: Lookup; fold: number; cwd: string; owners: RunContext['owners']; threads?: boolean };

export function lowered(text: string) {
  let result = '';
  for (let at = 0; at < text.length; at++) { const unit = text[at], lower = unit.toLowerCase(); result += lower.length === 1 ? lower : unit; }
  return result;
}

const contextOf = (context: FindContext): RunContext => ({ raw: context.raw ?? context.items, shown: context.items, owners: context.owners, threads: context.threads });

const makeSegment = (text: string, folds: string[] = [], fences: string[] = [], lazy?: string): Segment => ({ text, lowered: lowered(text), folds, fences, lazy });
const plainSegments = (text: string, ...folds: string[]): Segment[] => text ? [makeSegment(text, folds)] : [];
const proseSegments = (context: FindContext, source: string, key: string, folds: string[], user = false, lazy?: string): Segment[] =>
  markdownPlain(source, context.fold, user).map(part => makeSegment(part.text, folds, part.fence ? [key + ':' + part.fence.block + '.' + part.fence.ordinal] : [], lazy));
const headSegments = (text: string, key: string): Segment[] => { const [first, ...rest] = text.split('\n'); return [...plainSegments(first), ...plainSegments(rest.join('\n'), key)]; };

function blockSegments(item: Extract<WireItem, { kind: 'assistant' }>, index: number, context: FindContext): Segment[] {
  const block = item.blocks[index], key = item.seq + ':' + index;
  if (block.type === 'text') return visibleText(block) ? proseSegments(context, block.text, key, []) : [];
  const run = 'run:' + sourceKey(runOwner(contextOf(context), { kind: 'block', seq: item.seq, index })), folds = [run, key];
  const step = { kind: 'block' as const, block, item, index, args: block.type === 'tool' ? toolArgs(block) : {} }, info = stepInfo(step);
  if (block.type === 'tool' && block.agent) return [...plainSegments(info.label, run), ...proseSegments(context, agentBody(block.agent), key, folds)];
  const thinking = block.type === 'thinking' && !block.redacted;
  const labels = [...block.type === 'tool' && (block.name === 'bash' || info.labelClass === 'path') ? plainSegments(block.name, run) : [], ...plainSegments(info.label, run), ...thinking ? [] : plainSegments(info.detail, run)];
  if (thinking && block.type === 'thinking') return [...labels, ...proseSegments(context, block.text, key, folds, false, key)];
  return [...labels, ...stepParts(step, info, context.cwd, false).flatMap(part => plainSegments(part.text, ...folds))];
}

export function findSegments(item: WireItem, context: FindContext): Segment[] {
  switch (item.kind) {
    case 'user': return proseSegments(context, item.text, item.seq + ':user', [], true);
    case 'annotations': case 'threads': return [];
    case 'assistant': return [...item.blocks.flatMap((block, index) => blockSegments(item, index, context).map(segment => block.type === 'text' ? segment : { ...segment, step: item.seq + ':' + index })), ...plainSegments(item.error)];
    case 'agent': {
      const key = sourceKey({ kind: 'item', seq: item.seq }), run = 'run:' + sourceKey(runOwner(contextOf(context), { kind: 'item', seq: item.seq }));
      return [...plainSegments(stepInfo({ kind: 'agent', item, args: {} }).label, run), ...proseSegments(context, agentBody(item), key, [run, key])].map(segment => ({ ...segment, step: key }));
    }
    case 'job': {
      const key = sourceKey({ kind: 'item', seq: item.seq }), run = 'run:' + sourceKey(runOwner(contextOf(context), { kind: 'item', seq: item.seq }));
      const step = { kind: 'job' as const, item, args: {} }, info = stepInfo(step);
      return [...plainSegments(info.label, run), ...plainSegments(info.detail, run), ...stepParts(step, info, context.cwd, false).flatMap(part => plainSegments(part.text, run, key))].map(segment => ({ ...segment, step: key }));
    }
    case 'notify': return headSegments(item.text.text, 'notice:' + item.seq);
    case 'command': switch (item.result.type) {
      case 'copy': return [];
      case 'export': return plainSegments('exported ' + item.result.path);
      case 'session': return plainSegments(item.result.name);
      case 'compaction': return [];
    }
    case 'notice': return headSegments(item.text, 'notice:' + item.seq);
    case 'bash': return [...plainSegments(item.command), ...plainSegments(item.result.output.text, 'bash:' + item.seq)];
    case 'summary': return headSegments(item.text, 'notice:' + item.seq);
  }
}

export function exportText(item: WireItem, context: FindContext) {
  if (item.kind === 'user') return item.text;
  if (item.kind !== 'assistant') return findSegments(item, context).map(part => part.text).join('\n');
  return [...item.blocks.flatMap((block, index) => block.type === 'text' ? visibleText(block) ? [block.text] : [] : blockSegments(item, index, context).map(part => part.text)), item.error].filter(Boolean).join('\n');
}

export function matchesIn(segment: Segment, needle: string): number[] {
  const starts: number[] = [];
  for (let at = needle ? segment.lowered.indexOf(needle) : -1; at >= 0; at = segment.lowered.indexOf(needle, at + needle.length)) starts.push(at);
  return starts;
}
