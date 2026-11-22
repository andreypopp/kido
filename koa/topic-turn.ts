import type { WireItem } from './koa-records.ts';

export function topicTurn(items: Iterable<WireItem>, seq: number) {
  const ordered = [...items].sort((a, b) => a.seq - b.seq);
  const item = ordered.find(item => item.seq === seq);
  if (!item || item.kind !== 'user' && item.kind !== 'assistant') return;
  const user = ordered.findLast(other => other.kind === 'user' && other.seq <= seq);
  const next = ordered.find(other => other.kind === 'user' && other.seq > seq)?.seq ?? Infinity;
  return ordered.filter((other): other is Extract<WireItem, { kind: 'user' | 'assistant' }> => (other.kind === 'user' || other.kind === 'assistant') && other.seq >= (user?.seq ?? 0) && other.seq < next);
}
