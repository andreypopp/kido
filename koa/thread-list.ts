import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { decodePrompt } from './prompt.ts';
import { contentText, isRecord, threadSections } from './text.ts';
import { messageThread, threadMove, threadArchive, parseThreadName, type ThreadName } from './records.ts';

const resolveThread = (moves: ReadonlyMap<ThreadName, ThreadName>, name: ThreadName): ThreadName => moves.get(name) ?? name;
const movable = (moves: ReadonlyMap<ThreadName, ThreadName>, from: ThreadName, to: ThreadName): boolean => from !== to && !moves.has(from) && (!moves.has(to) || moves.get(to) === from);
const noteThreadMove = (moves: Map<ThreadName, ThreadName>, move: { from: ThreadName; to: ThreadName }): void => {
  if (!movable(moves, move.from, move.to)) return;
  for (const [alias, target] of moves) if (target === move.from) moves.set(alias, move.to);
  moves.set(move.from, move.to);
  moves.delete(move.to);
};


export type ThreadList = { names: ThreadName[]; indexed: ThreadName[]; resolve(name: ThreadName): ThreadName; movable(from: ThreadName, to: ThreadName): boolean; archived(name: ThreadName): boolean; assignment(entryId: string | undefined, original: ThreadName | undefined): ThreadName | undefined; overridden(entryId: string | undefined): boolean };

export function threadList(branch: readonly SessionEntry[]): ThreadList {
  const moves = new Map<ThreadName, ThreadName>(), overrides = new Map<string, ThreadName>(), order: ThreadName[] = [];
  const archived = new Set<ThreadName>();
  const seen: [string | undefined, ThreadName[]][] = [];
  const usedNames = () => {
    const used = new Set<ThreadName>();
    const use = (name: ThreadName | undefined) => { if (name) used.add(resolveThread(moves, name)); };
    for (const [id, names] of seen) {
      const forced = id === undefined ? undefined : overrides.get(id);
      if (forced) use(forced); else names.forEach(use);
    }
    return used;
  };
  const messages = new Set(branch.flatMap(entry => entry.type === 'message' && (entry.message.role === 'user' || entry.message.role === 'assistant') ? [entry.id] : []));
  for (const entry of branch) {
    const names: ThreadName[] = [];
    const use = (name: ThreadName | undefined) => { if (name) names.push(name); };
    let id: string | undefined;
    if (entry.type === 'custom_message' && entry.display && isRecord(entry.details)) use(parseThreadName(entry.details.thread));
    if (entry.type === 'message') {
      const { message } = entry;
      if (message.role === 'user' || message.role === 'assistant') id = entry.id;
      if (message.role === 'user') use(decodePrompt(contentText(message.content), [], 'root').thread);
      else if (message.role === 'assistant') { for (const block of message.content) if (block.type === 'text') for (const section of threadSections(block.text, true)) use(section.thread); }
      else if (message.role === 'toolResult' && isRecord(message.details)) use(parseThreadName(message.details.thread));
    }
    if (id !== undefined || names.length) seen.push([id, names]);
    const move = threadMove(entry);
    if (move) {
      if (movable(moves, move.from, move.to)) {
        const keep = archived.has(usedNames().has(move.to) ? move.to : move.from);
        archived.delete(move.from);
        if (keep) archived.add(move.to); else archived.delete(move.to);
        noteThreadMove(moves, move);
      }
      continue;
    }
    const archive = threadArchive(entry);
    if (archive) { const name = resolveThread(moves, archive.name); if (archive.archived) archived.add(name); else archived.delete(name); continue; }
    const override = messageThread(entry);
    if (override && override.entries.every(id => messages.has(id))) for (const id of override.entries) overrides.set(id, override.thread);
    else if (entry.type === 'custom' && entry.customType === 'koa.thread' && isRecord(entry.data)) { const name = parseThreadName(entry.data.name); if (name) order.push(name); }
  }
  const used = usedNames();
  const indexed = [...new Set(order.map(name => resolveThread(moves, name)))];
  const resolve = (name: ThreadName): ThreadName => resolveThread(moves, name);
  return { archived: name => archived.has(resolve(name)), movable: (from, to) => movable(moves, from, to), indexed, names: [...new Set([...indexed, ...used])].filter(name => used.has(name)), resolve, assignment: (entryId, original) => { const name = (entryId === undefined ? undefined : overrides.get(entryId)) ?? original; return name && resolve(name); }, overridden: entryId => entryId !== undefined && overrides.has(entryId) };
}
