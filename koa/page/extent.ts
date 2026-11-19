import type { Block, WireAssistant, WireItem } from '../koa-records.ts';

export type SeqRange = { from: number; to: number };

const lineCount = (text: string) => { let count = 1; for (let at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) count++; return count; };

export const isStep = (block: Block): block is Exclude<Block, { type: 'text' }> & { agent?: undefined } => block.type !== 'text' && !(block.type === 'tool' && block.agent);

export const joinsRun = (previous: Block | undefined, next: Block | undefined) => !!previous && !!next && isStep(previous) && isStep(next) && previous.thread === next.thread;

export const continuesRun = (previous: WireItem | undefined) => previous?.kind === 'assistant' && !previous.error && previous.blocks.length > 0 && isStep(previous.blocks[previous.blocks.length - 1]);

export function runStarts(item: WireAssistant, joined: boolean) {
  let count = 0, run = joined, previous: Block | undefined;
  for (const block of item.blocks) {
    if (!isStep(block)) run = false;
    else { if (previous && !joinsRun(previous, block)) run = false; if (!run) { run = true; count++; } }
    previous = block;
  }
  return count;
}

export function estimateExtent(item: WireItem, lh: number, joined = false): number {
  switch (item.kind) {
    case 'user': return lineCount(item.text) * lh + 30;
    case 'annotations': case 'threads': return 0;
    case 'assistant': return (runStarts(item, joined) + (item.error ? 1 : 0)) * (lh + 16) + item.blocks.reduce((total, block) => total + (block.type === 'text' && block.text.trim() ? lineCount(block.text) * lh : block.type === 'tool' && block.agent ? lh + 16 : 0), 0);
    case 'agent': case 'job': case 'notify': case 'command': case 'notice': case 'bash': case 'summary': return lh + 16;
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
