import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { decodePrompt } from './prompt.ts';
import { contentText, isRecord, threadSections } from './text.ts';
import { messageThread, threadMove, parseThreadName, type ThreadName } from './records.ts';

const resolveThread = (moves: ReadonlyMap<ThreadName, ThreadName>, name: ThreadName): ThreadName => moves.get(name) ?? name;
const movable = (moves: ReadonlyMap<ThreadName, ThreadName>, from: ThreadName, to: ThreadName): boolean => from !== to && !moves.has(from) && (!moves.has(to) || moves.get(to) === from);
const noteThreadMove = (moves: Map<ThreadName, ThreadName>, move: { from: ThreadName; to: ThreadName }): void => {
  if (!movable(moves, move.from, move.to)) return;
  for (const [alias, target] of moves) if (target === move.from) moves.set(alias, move.to);
  moves.set(move.from, move.to);
  moves.delete(move.to);
};


export type ThreadList = { names: ThreadName[]; indexed: ThreadName[]; resolve(name: ThreadName): ThreadName; movable(from: ThreadName, to: ThreadName): boolean; assignment(entryId: string | undefined, original: ThreadName | undefined): ThreadName | undefined; overridden(entryId: string | undefined): boolean };

export function threadList(branch: readonly SessionEntry[]): ThreadList {
  const moves = new Map<ThreadName, ThreadName>(), overrides = new Map<string, ThreadName>(), order: ThreadName[] = [];
  const messages = new Set(branch.flatMap(entry => entry.type === 'message' && (entry.message.role === 'user' || entry.message.role === 'assistant') ? [entry.id] : []));
  for (const entry of branch) {
    const move = threadMove(entry);
    if (move) { noteThreadMove(moves, move); continue; }
    const override = messageThread(entry);
    if (override && override.entries.every(id => messages.has(id))) for (const id of override.entries) overrides.set(id, override.thread);
    else if (entry.type === 'custom' && entry.customType === 'koa.thread' && isRecord(entry.data)) { const name = parseThreadName(entry.data.name); if (name) order.push(name); }
  }
  const used = new Set<ThreadName>();
  const use = (name: ThreadName | undefined) => { if (name) used.add(resolveThread(moves, name)); };
  for (const entry of branch) {
    if (entry.type === 'custom_message') { if (entry.display && isRecord(entry.details)) use(parseThreadName(entry.details.thread)); continue; }
    if (entry.type !== 'message') continue;
    const { message } = entry;
    if (message.role === 'user') use(overrides.get(entry.id) ?? decodePrompt(contentText(message.content), [], 'root').thread);
    else if (message.role === 'assistant') {
      const forced = overrides.get(entry.id);
      if (forced) use(forced);
      else for (const block of message.content) if (block.type === 'text') for (const section of threadSections(block.text, true)) use(section.thread);
    } else if (message.role === 'toolResult' && isRecord(message.details)) use(parseThreadName(message.details.thread));
  }
  const indexed = [...new Set(order.map(name => resolveThread(moves, name)))];
  const resolve = (name: ThreadName): ThreadName => resolveThread(moves, name);
  return { movable: (from, to) => movable(moves, from, to), indexed, names: [...new Set([...indexed, ...used])].filter(name => used.has(name)), resolve, assignment: (entryId, original) => { const name = (entryId === undefined ? undefined : overrides.get(entryId)) ?? original; return name && resolve(name); }, overridden: entryId => entryId !== undefined && overrides.has(entryId) };
}
