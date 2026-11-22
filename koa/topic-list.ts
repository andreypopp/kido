import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { decodePrompt } from './prompt.ts';
import { contentText, isRecord, topicSections } from './text.ts';
import { messageTopic, topicMove, topicArchive, parseTopicName, type TopicName } from './records.ts';

const resolveTopic = (moves: ReadonlyMap<TopicName, TopicName>, name: TopicName): TopicName => moves.get(name) ?? name;
const movable = (moves: ReadonlyMap<TopicName, TopicName>, from: TopicName, to: TopicName): boolean => from !== to && !moves.has(from) && (!moves.has(to) || moves.get(to) === from);
const noteTopicMove = (moves: Map<TopicName, TopicName>, move: { from: TopicName; to: TopicName }): void => {
  if (!movable(moves, move.from, move.to)) return;
  for (const [alias, target] of moves) if (target === move.from) moves.set(alias, move.to);
  moves.set(move.from, move.to);
  moves.delete(move.to);
};


export type TopicList = { names: TopicName[]; indexed: TopicName[]; resolve(name: TopicName): TopicName; movable(from: TopicName, to: TopicName): boolean; archived(name: TopicName): boolean; assignment(entryId: string | undefined, original: TopicName | undefined): TopicName | undefined; overridden(entryId: string | undefined): boolean };

export function topicList(branch: readonly SessionEntry[]): TopicList {
  const moves = new Map<TopicName, TopicName>(), overrides = new Map<string, TopicName>(), order: TopicName[] = [];
  const archived = new Set<TopicName>();
  const seen: [string | undefined, TopicName[]][] = [];
  const usedNames = () => {
    const used = new Set<TopicName>();
    const use = (name: TopicName | undefined) => { if (name) used.add(resolveTopic(moves, name)); };
    for (const [id, names] of seen) {
      const forced = id === undefined ? undefined : overrides.get(id);
      if (forced) use(forced); else names.forEach(use);
    }
    return used;
  };
  const messages = new Set(branch.flatMap(entry => entry.type === 'message' && (entry.message.role === 'user' || entry.message.role === 'assistant') ? [entry.id] : []));
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
    if (id !== undefined || names.length) seen.push([id, names]);
    const move = topicMove(entry);
    if (move) {
      if (movable(moves, move.from, move.to)) {
        const keep = archived.has(usedNames().has(move.to) ? move.to : move.from);
        archived.delete(move.from);
        if (keep) archived.add(move.to); else archived.delete(move.to);
        noteTopicMove(moves, move);
      }
      continue;
    }
    const archive = topicArchive(entry);
    if (archive) { const name = resolveTopic(moves, archive.name); if (archive.archived) archived.add(name); else archived.delete(name); continue; }
    const override = messageTopic(entry);
    if (override && override.entries.every(id => messages.has(id))) for (const id of override.entries) overrides.set(id, override.topic);
    else if (entry.type === 'custom' && entry.customType === 'koa.topic' && isRecord(entry.data)) { const name = parseTopicName(entry.data.name); if (name) order.push(name); }
  }
  const used = usedNames();
  const indexed = [...new Set(order.map(name => resolveTopic(moves, name)))];
  const resolve = (name: TopicName): TopicName => resolveTopic(moves, name);
  return { archived: name => archived.has(resolve(name)), movable: (from, to) => movable(moves, from, to), indexed, names: [...new Set([...indexed, ...used])].filter(name => used.has(name)), resolve, assignment: (entryId, original) => { const name = (entryId === undefined ? undefined : overrides.get(entryId)) ?? original; return name && resolve(name); }, overridden: entryId => entryId !== undefined && overrides.has(entryId) };
}
