import { runOwner, runOf, sourceKey, visibleText, type RunContext } from './extent.ts';
import { markdownLine } from '../markdown-line.ts';
import { markdownPlain } from './markdown.ts';
import { agentBody, noticeOf, noticeText, sessionFields, stepInfo, stepParts, toolArgs } from './steps.ts';
import type { WireItem } from '../koa-records.ts';

export type Segment = { text: string; lowered: string; folds: string[]; fences: string[]; lazy?: string; step?: string };
type Lookup = (seq: number) => WireItem | undefined;
export type FindContext = { items: Lookup; raw?: Lookup; fold: number; cwd: string; owners: RunContext['owners'] };

export function lowered(text: string) {
  let result = '';
  for (let at = 0; at < text.length; at++) { const unit = text[at], lower = unit.toLowerCase(); result += lower.length === 1 ? lower : unit; }
  return result;
}

const contextOf = (context: FindContext): RunContext => ({ raw: context.raw ?? context.items, shown: context.items, owners: context.owners });

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
  return [...labels, ...stepParts(step, info, context.cwd, false).flatMap(part => part.kind === 'notice' ? [] : plainSegments(part.text, ...folds))];
}

export function findSegments(item: WireItem, context: FindContext): Segment[] {
  const notice = noticeOf(item), owner = notice && runOf(contextOf(context), { kind: 'item', seq: item.seq });
  let noticeSegments: Segment[] = [];
  if (notice) {
    const content = notice.content;
    if (content.type === 'markdown') {
      const [head, ...rest] = content.text.split(/\r\n?|\n/);
      noticeSegments = [...plainSegments(markdownLine(head)), ...proseSegments(context, rest.join('\n'), notice.key, [notice.key])];
    } else noticeSegments = headSegments(content.type === 'summary' ? content.text : noticeText(notice), notice.key);
    if (content.type === 'command' && content.result.type === 'session') noticeSegments.push(...sessionFields(content.result).flatMap(([name, value]) => plainSegments(name + ' ' + value, notice.key)));
    if (owner) noticeSegments = noticeSegments.map(segment => ({ ...segment, folds: ['run:' + sourceKey(owner), ...segment.folds.map(() => sourceKey({ kind: 'item', seq: item.seq }))], step: sourceKey({ kind: 'item', seq: item.seq }) }));
    if (item.kind !== 'assistant') return noticeSegments;
  }
  switch (item.kind) {
    case 'user': return proseSegments(context, item.text, item.seq + ':user', [], true);
    case 'annotations': case 'threads': return [];
    case 'assistant': return [...item.blocks.flatMap((block, index) => blockSegments(item, index, context).map(segment => block.type === 'text' ? segment : { ...segment, step: item.seq + ':' + index })), ...noticeSegments];
    case 'agent': {
      const key = sourceKey({ kind: 'item', seq: item.seq }), run = 'run:' + sourceKey(runOwner(contextOf(context), { kind: 'item', seq: item.seq }));
      return [...plainSegments(stepInfo({ kind: 'agent', item, args: {} }).label, run), ...proseSegments(context, agentBody(item), key, [run, key])].map(segment => ({ ...segment, step: key }));
    }
    case 'job': {
      const key = sourceKey({ kind: 'item', seq: item.seq }), run = 'run:' + sourceKey(runOwner(contextOf(context), { kind: 'item', seq: item.seq }));
      const step = { kind: 'job' as const, item, args: {} }, info = stepInfo(step);
      return [...plainSegments(info.label, run), ...plainSegments(info.detail, run), ...stepParts(step, info, context.cwd, false).flatMap(part => part.kind === 'notice' ? [] : plainSegments(part.text, run, key))].map(segment => ({ ...segment, step: key }));
    }
    case 'notify': case 'command': case 'notice': case 'summary': return noticeSegments;
    case 'bash': return [...plainSegments(item.command), ...plainSegments(item.result.output.text, 'bash:' + item.seq)];
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
