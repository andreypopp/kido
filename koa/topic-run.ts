import type { Block, WireItem } from './koa-records.ts';
import type { TopicName } from './records.ts';

const isRunNotice = (item: WireItem) => item.kind === 'assistant' ? !!item.error : item.kind === 'notify' || item.kind === 'notice' || item.kind === 'summary' || item.kind === 'command';
export type Source = { kind: 'item'; seq: number } | { kind: 'block'; seq: number; index: number };
type RunPart = { kind: 'step' | 'notice'; source: Source } | { kind: 'boundary' };
type RunTail = { owner: Source };
type OwnerItem = { sources: Map<string, Source>; tail?: RunTail };
export type RunContext = { raw: (seq: number) => WireItem | undefined; shown: (seq: number) => WireItem | undefined; owners: Map<number, OwnerItem> };
export const visibleText = (block: Block) => block.type === 'text' && block.text.trim() !== '';
export const sourceKey = (source: Source) => source.seq + ':' + (source.kind === 'block' ? source.index : 'item');
export function runParts(raw: WireItem | undefined, shown: WireItem | undefined): RunPart[] {
  if (raw?.kind === 'annotations' || raw?.kind === 'topics') return [];
  if (!shown) return raw ? raw.kind === 'user' || raw.kind === 'bash' || raw.kind === 'assistant' && raw.blocks.some(visibleText) ? [{ kind: 'boundary' }] : [] : [{ kind: 'boundary' }];
  const notice = isRunNotice(shown) ? [{ kind: 'notice' as const, source: { kind: 'item' as const, seq: shown.seq } }] : [];
  switch (shown.kind) {
    case 'assistant': return [...shown.blocks.flatMap((block, index): RunPart[] => block.type === 'text' ? visibleText(block) || raw?.kind === 'assistant' && visibleText(raw.blocks[index]) ? [{ kind: 'boundary' }] : [] : [{ kind: 'step', source: { kind: 'block', seq: shown.seq, index } }]), ...notice];
    case 'agent': return [{ kind: 'step', source: { kind: 'item', seq: shown.seq } }];
    case 'job': return [{ kind: 'step', source: { kind: 'item', seq: shown.seq } }];
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

export type TopicContext = { items: ReadonlyMap<number, WireItem>; labels: (seq: number) => readonly TopicName[]; runs: RunContext; topics?: Map<string, TopicName> };
export function stepTopic(item: WireItem | undefined, source: Source, labels: readonly TopicName[]): TopicName | undefined {
  return source.kind === 'block' && item?.kind === 'assistant' ? item.blocks[source.index].topic ?? labels[0] : item?.kind === 'agent' || item?.kind === 'job' ? item.topic ?? labels[0] : undefined;
}
export function messageTopics(item: WireItem | undefined, labels: readonly TopicName[] = []): readonly TopicName[] {
  return item?.kind === 'user' ? item.topic ? [item.topic] : labels : item?.kind === 'assistant' ? [...new Set(item.blocks.flatMap(block => visibleText(block) ? block.topic ?? labels[0] ?? [] : []))] : [];
}
export type TopicStep = { source: Source; topic: TopicName };
export function firstTopicStep(first: TopicStep | undefined, source: Source, topic: TopicName | undefined): TopicStep | undefined {
  if (!topic) return first;
  const previous = first?.source;
  const earlier = !previous || source.seq < previous.seq || source.seq === previous.seq && source.kind === 'block' && (previous.kind === 'item' || source.index < previous.index);
  return earlier ? { source, topic } : first;
}
function runTopic(context: TopicContext, source: Source): TopicName | undefined {
  if (!context.topics) {
    const names = new Map<string, TopicStep>();
    for (const seq of [...context.items.keys()].sort((a, b) => a - b)) {
      const item = context.items.get(seq);
      for (const part of runParts(item, item)) {
        if (part.kind !== 'step') continue;
        const key = sourceKey(runOwner(context.runs, part.source));
        const first = firstTopicStep(names.get(key), part.source, stepTopic(item, part.source, context.labels(seq)));
        if (first) names.set(key, first);
      }
    }
    context.topics = new Map([...names].map(([key, step]) => [key, step.topic]));
  }
  return context.topics.get(sourceKey(runOwner(context.runs, source)));
}
export function projectTopic(context: TopicContext, seq: number, filter?: TopicName): WireItem | undefined {
  const item = context.items.get(seq);
  if (!item || item.kind === 'annotations' || item.kind === 'topics') return item;
  const names = context.labels(seq);
  if (!filter) {
    if ((item.kind === 'agent' || item.kind === 'job') && !item.topic && names[0]) return { ...item, topic: names[0] };
    if (item.kind !== 'assistant' || !names[0] || item.blocks.every(block => block.topic)) return item;
    return { ...item, blocks: item.blocks.map(block => block.topic ? block : { ...block, topic: names[0] }) };
  }
  if (item.kind === 'assistant') {
    const matches = (block: Block, index: number) => (block.type === 'text' ? textInTopic(block, names, filter) : runTopic(context, { kind: 'block', seq, index }) === filter);
    const error = item.error && runTopic(context, { kind: 'item', seq }) === filter ? item.error : '';
    if (item.blocks.some(matches) || error) return { ...item, error, blocks: item.blocks.map((block, index) => matches(block, index) ? block.topic ? block : { ...block, topic: names[0] } : { type: 'text', text: '' }) };
  } else if (item.kind === 'agent' || item.kind === 'job' || isRunNotice(item)) {
    if (runTopic(context, { kind: 'item', seq }) === filter) return item;
  } else if (item.kind === 'user' && countedMessage(item, names, filter)) return item;
}
const textInTopic = (block: Block, labels: readonly TopicName[], filter?: TopicName) => !filter || (block.topic ?? labels[0]) === filter;
export const countedMessage = (item: WireItem | undefined, labels: readonly TopicName[] = [], filter?: TopicName) => filter ? messageTopics(item, labels).includes(filter) : item?.kind === 'user' || item?.kind === 'assistant' && item.blocks.some(visibleText);
