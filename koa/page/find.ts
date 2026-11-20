import { continuesRun, isStep, joinsRun } from './extent.ts';
import { markdownPlain } from './markdown.ts';
import { agentBody, stepInfo, stepParts, toolArgs } from './steps.ts';
import type { WireItem } from '../koa-records.ts';

export type Segment = { text: string; lowered: string; folds: string[]; fences: string[]; lazy?: string };
type Lookup = (seq: number) => WireItem | undefined;
export type FindContext = { items: Lookup; fold: number; cwd: string; owners: Map<string, string> };

export function lowered(text: string) {
  let result = '';
  for (let at = 0; at < text.length; at++) { const unit = text[at], lower = unit.toLowerCase(); result += lower.length === 1 ? lower : unit; }
  return result;
}

function trailingRun(context: FindContext, seq: number): string {
  const key = 'run:' + seq, known = context.owners.get(key);
  if (known !== undefined) return known;
  const item = context.items(seq);
  let result = '';
  if (item?.kind === 'assistant' && item.blocks.length && isStep(item.blocks[item.blocks.length - 1])) {
    let at = item.blocks.length - 1;
    while (at > 0 && joinsRun(item.blocks[at - 1], item.blocks[at])) at--;
    const previous = context.items(seq - 1);
    result = at === 0 && previous?.kind === 'assistant' && continuesRun(previous) && joinsRun(previous.blocks.at(-1), item.blocks[0]) ? trailingRun(context, seq - 1) : 'run:' + seq + ':' + at;
  }
  context.owners.set(key, result);
  return result;
}

function runOf(context: FindContext, seq: number, index: number, blocks: readonly Parameters<typeof isStep>[0][]) {
  let at = index;
  while (at > 0 && joinsRun(blocks[at - 1], blocks[at])) at--;
  const previous = context.items(seq - 1);
  return at === 0 && previous?.kind === 'assistant' && continuesRun(previous) && joinsRun(previous.blocks.at(-1), blocks[0]) ? trailingRun(context, seq - 1) : 'run:' + seq + ':' + at;
}

function jobFirst(context: FindContext, seq: number): number {
  const key = 'job:' + seq, known = context.owners.get(key);
  if (known !== undefined) return Number(known);
  const item = context.items(seq), previous = context.items(seq - 1);
  const first = item?.kind === 'job' && previous?.kind === 'job' && previous.job.id === item.job.id && previous.event.type === 'stream' ? jobFirst(context, seq - 1) : seq;
  context.owners.set(key, String(first));
  return first;
}

const makeSegment = (text: string, folds: string[] = [], fences: string[] = [], lazy?: string): Segment => ({ text, lowered: lowered(text), folds, fences, lazy });
const plainSegments = (text: string, ...folds: string[]): Segment[] => text ? [makeSegment(text, folds)] : [];
const proseSegments = (context: FindContext, source: string, key: string, folds: string[], user = false, lazy?: string): Segment[] =>
  markdownPlain(source, context.fold, user).map(part => makeSegment(part.text, folds, part.fence ? [key + ':' + part.fence.block + '.' + part.fence.ordinal] : [], lazy));
const headSegments = (text: string, key: string): Segment[] => { const [first, ...rest] = text.split('\n'); return [...plainSegments(first), ...plainSegments(rest.join('\n'), key)]; };

function blockSegments(item: Extract<WireItem, { kind: 'assistant' }>, index: number, context: FindContext): Segment[] {
  const block = item.blocks[index], key = item.seq + ':' + index;
  if (block.type === 'text') return proseSegments(context, block.text, key, []);
  if (block.type === 'tool' && block.agent) return plainSegments(agentBody(block.agent), 'agent:' + key);
  const run = runOf(context, item.seq, index, item.blocks), folds = [run, key];
  const step = { block, item, args: block.type === 'tool' ? toolArgs(block) : {} }, info = stepInfo(step);
  const thinking = block.type === 'thinking' && !block.redacted;
  const labels = [...block.type === 'tool' && (block.name === 'bash' || info.labelClass === 'path') ? plainSegments(block.name, run) : [], ...plainSegments(info.label, run), ...thinking ? [] : plainSegments(info.detail, run)];
  if (thinking && block.type === 'thinking') return [...labels, ...proseSegments(context, block.text, key, folds, false, key)];
  return [...labels, ...stepParts(step, info, context.cwd, false).flatMap(part => plainSegments(part.text, ...folds))];
}

export function findSegments(item: WireItem, context: FindContext): Segment[] {
  switch (item.kind) {
    case 'user': return proseSegments(context, item.text, item.seq + ':user', [], true);
    case 'annotations': case 'threads': return [];
    case 'assistant': return [...item.blocks.flatMap((_, index) => blockSegments(item, index, context)), ...plainSegments(item.error)];
    case 'agent': return plainSegments(agentBody(item), 'agent:' + item.seq);
    case 'job': return [...plainSegments(item.job.name), ...plainSegments(item.event.type === 'stream' ? item.event.batch.text : item.event.tail.text, 'job:' + jobFirst(context, item.seq))];
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
  return [...item.blocks.flatMap((block, index) => block.type === 'text' ? [block.text] : blockSegments(item, index, context).map(part => part.text)), item.error].filter(Boolean).join('\n');
}

export function matchesIn(segment: Segment, needle: string): number[] {
  const starts: number[] = [];
  for (let at = needle ? segment.lowered.indexOf(needle) : -1; at >= 0; at = segment.lowered.indexOf(needle, at + needle.length)) starts.push(at);
  return starts;
}
