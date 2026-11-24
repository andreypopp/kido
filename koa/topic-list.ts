import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { decodePrompt } from './prompt.ts';
import { turnAnchors } from './topic-turn.ts';
import { contentText, isRecord, topicSections } from './text.ts';
import { messageTopic, topicMove, topicArchive, parseTopicName, type TopicName } from './records.ts';

const resolveTopic = (moves: ReadonlyMap<TopicName, TopicName>, name: TopicName): TopicName => moves.get(name) ?? name;
const movable = (moves: ReadonlyMap<TopicName, TopicName>, from: TopicName, to: TopicName): boolean => from !== to && !moves.has(from) && (!moves.has(to) || moves.get(to) === from);

export type TopicList = { names: TopicName[]; recent: TopicName[]; indexed: TopicName[]; resolve(name: TopicName): TopicName; movable(from: TopicName, to: TopicName): boolean; archived(name: TopicName): boolean; assignment(entryId: string | undefined, original: TopicName | undefined): TopicName | undefined; overridden(entryId: string | undefined): boolean };

export function topicList(branch: readonly SessionEntry[]): TopicList {
  const moves = new Map<TopicName, TopicName>(), overrides = new Map<string, TopicName>(), order: TopicName[] = [];
  const archived = new Set<TopicName>();
  const seen: [string | undefined, TopicName[]][] = [];
  const occurrences: [string | undefined, TopicName[]][] = [];
  const usedNames = () => {
    const used = new Set<TopicName>();
    const use = (name: TopicName | undefined) => { if (name) used.add(resolveTopic(moves, name)); };
    for (const [id, names] of seen) {
      const name = forced(id);
      if (name) use(name); else names.forEach(use);
    }
    return used;
  };
  const indices = new Map(branch.map((entry, index) => [entry.id, index]));
  const turn = turnAnchors(branch, entry => entry.type === 'message' && (entry.message.role === 'user' || entry.message.role === 'assistant') ? entry.message.role : undefined);
  const anchor = (id: string) => { const index = indices.get(id), at = index === undefined ? undefined : turn(index); return at === undefined ? undefined : branch[at]?.id; };
  const forced = (id: string | undefined) => id === undefined ? undefined : overrides.get(anchor(id) ?? id);
  for (const entry of branch) {
    const names: TopicName[] = [];
    const use = (name: TopicName | undefined) => { if (name) names.push(name); };
    let id: string | undefined;
    if (entry.type === 'custom_message' && entry.display && isRecord(entry.details)) use(parseTopicName(entry.details.topic));
    if (entry.type === 'message') {
      const { message } = entry;
      if (message.role === 'user' || message.role === 'assistant') id = entry.id;
      if (message.role === 'user') use(decodePrompt(contentText(message.content), [], 'root').topic);
      else if (message.role === 'assistant') { for (const block of message.content) if (block.type === 'text') for (const section of topicSections(block.text, true)) use(section.topic); }
      else if (message.role === 'toolResult' && isRecord(message.details)) use(parseTopicName(message.details.topic));
    }
    if (id !== undefined || names.length) { seen.push([id, names]); occurrences.push([id, names]); }
    const move = topicMove(entry);
    if (move) {
      if (movable(moves, move.from, move.to)) {
        const keep = archived.has(usedNames().has(move.to) ? move.to : move.from);
        archived.delete(move.from);
        if (keep) archived.add(move.to); else archived.delete(move.to);
        for (const [alias, target] of moves) if (target === move.from) moves.set(alias, move.to);
        moves.set(move.from, move.to);
        moves.delete(move.to);
      }
      continue;
    }
    const archive = topicArchive(entry);
    if (archive) { const name = resolveTopic(moves, archive.name); if (archive.archived) archived.add(name); else archived.delete(name); continue; }
    const override = messageTopic(entry);
    if (override && anchor(override.anchor) === override.anchor) overrides.set(override.anchor, override.topic);
    else if (entry.type === 'custom' && entry.customType === 'koa.topic' && isRecord(entry.data)) { const name = parseTopicName(entry.data.name); if (name) { order.push(name); occurrences.push([undefined, [name]]); } }
  }
  const used = usedNames();
  const indexed = [...new Set(order.map(name => resolveTopic(moves, name)))];
  const resolve = (name: TopicName): TopicName => resolveTopic(moves, name);
  const recent = [...new Set(occurrences.reverse().flatMap(([id, names]) => { const name = forced(id); return (name ? [name] : names).map(resolve); }))].filter(name => used.has(name));
  return { recent, archived: name => archived.has(resolve(name)), movable: (from, to) => movable(moves, from, to), indexed, names: [...new Set([...indexed, ...used])].filter(name => used.has(name)), resolve, assignment: (entryId, original) => { const name = forced(entryId) ?? original; return name && resolve(name); }, overridden: entryId => forced(entryId) !== undefined };
}
