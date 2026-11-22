import type { Block, WireItem } from '../koa-records.ts';
import { noticeOf, type StepInput } from './steps.ts';

type Source = { kind: 'item'; seq: number } | { kind: 'block'; seq: number; index: number };
type RunPart = { kind: 'step' | 'notice'; source: Source; step: StepInput } | { kind: 'boundary' };
type RunTail = { owner: Source };
type OwnerItem = { sources: Map<string, Source>; tail?: RunTail };
export type RunContext = { raw: (seq: number) => WireItem | undefined; shown: (seq: number) => WireItem | undefined; owners: Map<number, OwnerItem> };
export const visibleText = (block: Block) => block.type === 'text' && block.text.trim() !== '';
export const sourceKey = (source: Source) => source.seq + ':' + (source.kind === 'block' ? source.index : 'item');
export function runParts(raw: WireItem | undefined, shown: WireItem | undefined): RunPart[] {
  if (raw?.kind === 'annotations' || raw?.kind === 'topics') return [];
  if (!shown) return raw ? raw.kind === 'user' || raw.kind === 'bash' || raw.kind === 'assistant' && raw.blocks.some(visibleText) ? [{ kind: 'boundary' }] : [] : [{ kind: 'boundary' }];
  const row = noticeOf(shown), notice = row ? [{ kind: 'notice' as const, source: { kind: 'item' as const, seq: shown.seq }, step: { kind: 'notice' as const, item: shown, row } }] : [];
  switch (shown.kind) {
    case 'assistant': return [...shown.blocks.flatMap((block, index): RunPart[] => block.type === 'text' ? visibleText(block) || raw?.kind === 'assistant' && visibleText(raw.blocks[index]) ? [{ kind: 'boundary' }] : [] : [{ kind: 'step', source: { kind: 'block', seq: shown.seq, index }, step: { kind: 'block', item: shown, block, index } }]), ...notice];
    case 'agent': return [{ kind: 'step', source: { kind: 'item', seq: shown.seq }, step: { kind: 'agent', item: shown } }];
    case 'job': return [{ kind: 'step', source: { kind: 'item', seq: shown.seq }, step: { kind: 'job', item: shown } }];
    default: return notice.length ? notice : [{ kind: 'boundary' }];
  }
}
function ownersAt(context: RunContext, seq: number): OwnerItem {
  const known = context.owners.get(seq);
  if (known) return known;
  const pending: { seq: number; parts: RunPart[] }[] = [];
  let tail: RunTail | undefined;
  for (let at = seq; at >= 0; at--) {
    const cached = context.owners.get(at);
    if (cached) { tail = cached.tail; break; }
    const parts = runParts(context.raw(at), context.shown(at));
    pending.push({ seq: at, parts });
    if (parts[0]?.kind === 'boundary') break;
  }
  let result: OwnerItem = { sources: new Map() };
  for (const item of pending.reverse()) {
    const sources = new Map<string, Source>();
    for (const part of item.parts) {
      if (part.kind === 'boundary') { tail = undefined; continue; }
      if (part.kind === 'notice' && !tail) continue;
      const owner = tail?.owner ?? part.source;
      sources.set(sourceKey(part.source), owner); tail = { owner };
    }
    result = { sources, tail }; context.owners.set(item.seq, result);
  }
  return result;
}
export function runOf(context: RunContext, source: Source): Source | undefined {
  return ownersAt(context, source.seq).sources.get(sourceKey(source));
}
export function runOwner(context: RunContext, source: Source): Source {
  return runOf(context, source) ?? source;
}
export function invalidateRuns(context: RunContext, seq: number): number {
  let last = seq;
  for (let at = seq; ; at++) {
    const raw = context.raw(at);
    if (!raw) break;
    const previous = context.owners.get(at);
    context.owners.delete(at);
    const current = ownersAt(context, at);
    last = at;
    if (previous && (!previous.tail && !current.tail || previous.tail && current.tail && sourceKey(previous.tail.owner) === sourceKey(current.tail.owner))) break;
    if (at > seq && runParts(raw, context.shown(at)).some(part => part.kind === 'boundary')) break;
  }
  return last;
}

export type SeqRange = { from: number; to: number };

const lineCount = (text: string) => { let count = 1; for (let at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) count++; return count; };

export function estimateExtent(item: WireItem, lh: number, context: RunContext): number {
  const runs = runParts(context.raw(item.seq), item).filter(part => part.kind === 'step' && sourceKey(part.source) === sourceKey(runOwner(context, part.source))).length;
  switch (item.kind) {
    case 'user': return lineCount(item.text) * lh + 30;
    case 'annotations': case 'topics': return 0;
    case 'assistant': return (runs + (item.error && !runOf(context, { kind: 'item', seq: item.seq }) ? 1 : 0)) * (lh + 16) + item.blocks.reduce((total, block) => total + (block.type === 'text' && visibleText(block) ? lineCount(block.text) * lh : 0), 0);
    case 'agent': case 'job': return runs * (lh + 16);
    case 'notify': case 'command': case 'notice': case 'bash': case 'summary': return runOf(context, { kind: 'item', seq: item.seq }) ? 0 : lh + 16;
  }
}

export function groupAt<G extends SeqRange>(groups: readonly G[], seq: number): G | undefined {
  let low = 0, high = groups.length - 1, found: G | undefined;
  while (low <= high) { const middle = (low + high) >> 1; if (groups[middle].from <= seq) { found = groups[middle]; low = middle + 1; } else high = middle - 1; }
  return found && found.to >= seq ? found : undefined;
}

export function windowOf(order: readonly number[], starts: readonly number[], top: number, viewport: number, overscan: number, groups: readonly SeqRange[]): SeqRange | undefined {
  if (!order.length) return undefined;
  const total = starts[order.length], clamp = (value: number) => Math.min(total, Math.max(0, value));
  const low = clamp(top - overscan), high = clamp(top + viewport + overscan);
  let from = 0, to = order.length - 1;
  while (from < to) { const middle = (from + to) >> 1; if (starts[middle + 1] >= low) to = middle; else from = middle + 1; }
  const first = from;
  to = order.length - 1;
  while (from < to) { const middle = (from + to + 1) >> 1; if (starts[middle] <= high) from = middle; else to = middle - 1; }
  const head = groupAt(groups, order[first]), tail = groupAt(groups, order[from]);
  return { from: head ? head.from : order[first], to: tail ? tail.to : order[from] };
}
