import type { WireItem } from '../koa-records.ts';
import { runParts, runOwner, runOf, sourceKey, visibleText, type Source, type RunContext } from '../topic-run.ts';

export type RowId = { kind: 'text'; source: Extract<Source, { kind: 'block' }> } | { kind: 'run'; source: Source };
export const rowKey = (row: RowId) => (row.kind === 'run' ? 'run:' : '') + sourceKey(row.source);
export const sameRow = (a: RowId | undefined, b: RowId | undefined) => a === b || !!a && !!b && a.kind === b.kind && a.source.seq === b.source.seq && (a.source.kind === 'item' ? b.source.kind === 'item' : b.source.kind === 'block' && a.source.index === b.source.index);

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
