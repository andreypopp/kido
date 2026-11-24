import type { WireItem } from './koa-records.ts';

export function turnAnchors<T>(items: readonly T[], role: (item: T) => 'user' | 'assistant' | undefined) {
  const cache = new Map<number, number>();
  return (index: number): number | undefined => {
    const item = items[index];
    if (!item || !role(item)) return;
    const known = cache.get(index);
    if (known !== undefined) return known;
    let anchor = index;
    const visited: number[] = [];
    for (let at = index; at >= 0; at--) {
      const value = items[at];
      if (!value) continue;
      const kind = role(value);
      if (!kind) continue;
      const saved = cache.get(at);
      if (saved !== undefined) { anchor = saved; break; }
      visited.push(at); anchor = at;
      if (kind === 'user') break;
    }
    for (const at of visited) cache.set(at, anchor);
    return anchor;
  };
}

export const itemTurnAnchors = (items: readonly WireItem[]) => turnAnchors(items, item => item.kind === 'user' || item.kind === 'assistant' ? item.kind : undefined);

export function topicTurn(items: Iterable<WireItem>, seq: number) {
  const ordered = [...items].sort((a, b) => a.seq - b.seq);
  const index = ordered.findIndex(item => item.seq === seq), anchor = itemTurnAnchors(ordered)(index);
  if (anchor === undefined) return;
  const next = ordered.findIndex((item, at) => at > index && item.kind === 'user');
  return ordered.slice(anchor, next < 0 ? undefined : next).filter((item): item is Extract<WireItem, { kind: 'user' | 'assistant' }> => item.kind === 'user' || item.kind === 'assistant');
}
