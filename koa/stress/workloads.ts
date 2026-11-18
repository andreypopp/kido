import { writeFile, mkdir, realpath } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SessionManager } from '@earendil-works/pi-coding-agent';
import type { Reply } from '../koa-fake-provider.ts';

export const workloads = [
  { name: 'long-session', memory: { type: 'limited' } },
  { name: 'fast-tokens', memory: { type: 'limited' } },
  { name: 'large-output', memory: { type: 'limited' } },
  { name: 'large-prompt', memory: { type: 'limited' } },
  { name: 'reconnects', memory: { type: 'limited' } },
  { name: 'many-panes', memory: { type: 'limited' } },
  { name: 'hidden-shown', memory: { type: 'limited' } },
  { name: 'themes', memory: { type: 'limited' } },
  { name: 'fetch-concurrency', memory: { type: 'limited' } },
  { name: 'slow-page', memory: { type: 'reported', reason: '64 MiB transcript tests back-pressure' } },
  { name: 'body-kinds', memory: { type: 'limited' } },
  { name: 'children', memory: { type: 'limited' } },
  { name: 'streaming-history', memory: { type: 'limited' } },
  { name: 'streaming', memory: { type: 'limited' } },
] as const;
export const pageWorkloads = [1, 2, 3, 4, 5, 8, 9, 10, 11];
export const streaming = [13, 14];
export const STREAM_MEMORY_MIB = { page: 32, kidoOverShortHistory: 400 };
export const HISTORY_ROWS = 100_000;
export const STREAM_TOKENS = 10_000;
export const STREAM_RESPONSES = 21;
const TOKENS_PER_SECOND = 200;
export const CHUNK_TOKENS = 10;
export const stressModels = [{ provider: 'fake', id: 'fake-model', contextWindow: 1_000_000_000 }];
export const stressSettings = { compaction: { enabled: false } };
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
type Assistant = Extract<Parameters<SessionManager['appendMessage']>[0], { role: 'assistant' }>;
const assistant = (content: Assistant['content'], timestamp: number): Assistant => ({ role: 'assistant', api: 'test', provider: 'test', model: 'test', usage, timestamp, stopReason: 'stop', content });

const lexicon = 'the stream render frame layout block token patch scroll reveal paragraph history window message answer measure reader screen cursor line item cache state view'.split(' ');
const seeded = (seed: number) => () => { seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
const tokenCount = (text: string) => text.match(/\S+/g)?.length ?? 0;

// One block of mixed markdown, and the rows it renders to: a row is about 90 characters of a paragraph, or one list item, code line or table row. A fence stays under the fold limit of 15 lines.
function mixedBlock(random: () => number, limit = Infinity): { text: string; rows: number } {
  const pick = (count: number) => Array.from({ length: count }, () => lexicon[Math.floor(random() * lexicon.length)]).join(' ');
  const count = (low: number, span: number) => low + Math.floor(random() * span);
  const kind = random();
  if (kind < .5 || limit < 12) { const size = Math.min(limit, count(8, 50)), text = pick(size); return { text: text + '\n\n', rows: Math.ceil(text.length / 90) + 1 }; }
  if (kind < .7) { const items = Array.from({ length: count(3, 4) }, () => '- ' + pick(count(3, 5))); return { text: items.join('\n') + '\n\n', rows: items.length + 1 }; }
  if (kind < .85) { const lines = Array.from({ length: count(3, 5) }, () => '  ' + pick(count(2, 4))); return { text: '```ts\n' + lines.join('\n') + '\n```\n\n', rows: lines.length + 2 }; }
  const body = Array.from({ length: count(3, 3) }, () => `| ${pick(1)} | ${pick(1)} | ${pick(1)} |`);
  return { text: ['| a | b | c |', '| - | - | - |', ...body].join('\n') + '\n\n', rows: body.length + 3 };
}

export function streamingReplies(): Reply[] {
  const random = seeded(13);
  const reply = (budget: number, tools: boolean): Reply => {
    let text = '', left = budget;
    while (left > 0) {
      const block = mixedBlock(random, left);
      const size = tokenCount(block.text);
      if (size > left) continue;
      text += block.text; left -= size;
    }
    const pieces = text.match(/\S+\s*/g) ?? [];
    const chunks = Array.from({ length: Math.ceil(pieces.length / CHUNK_TOKENS) }, (_, at) => pieces.slice(at * CHUNK_TOKENS, (at + 1) * CHUNK_TOKENS).join(''));
    return { chunks, delayMs: 1000 * CHUNK_TOKENS / TOKENS_PER_SECOND, ...tools && { tools: [{ name: 'probe', args: {} }] } };
  };
  const short = Array.from({ length: STREAM_RESPONSES }, (_, index) => reply(Math.floor(STREAM_TOKENS / STREAM_RESPONSES) + (index < STREAM_TOKENS % STREAM_RESPONSES ? 1 : 0), true));
  return [...short, reply(STREAM_TOKENS, false)];
}

export function historyMessages(): { texts: string[]; rows: number } {
  const random = seeded(12), texts: string[] = [];
  let rows = 0;
  for (let turn = 0; rows < HISTORY_ROWS; turn++) {
    texts.push('Question ' + turn + ' about the stream');
    let answer = '';
    for (let blocks = 3 + Math.floor(random() * 10); blocks > 0; blocks--) { const block = mixedBlock(random); answer += block.text; rows += block.rows; }
    texts.push(answer);
    rows += 2;
  }
  return { texts, rows };
}

async function seed(cwd: string, directory: string, messages: Parameters<SessionManager['appendMessage']>[0][]) {
  const manager = SessionManager.create(cwd, directory);
  for (const message of messages) manager.appendMessage(message);
  const file = manager.getSessionFile();
  if (!file) throw Error('The seeded session has no file');
  await writeFile(file, [manager.getHeader(), ...manager.getEntries()].map(entry => JSON.stringify(entry)).join('\n') + '\n');
  return file;
}

// Writes `${id}.json` for each workload: the provider's replies and, for the long session, the seeded session file.
export async function scripts(directory: string, cwd: string) {
  await mkdir(directory, { recursive: true });
  await mkdir(cwd, { recursive: true });
  for (let id = 1; id <= workloads.length; id++) {
    let replies: Reply[];
    let session: string | undefined;
    if (streaming.includes(id)) replies = streamingReplies();
    else if (id === 3) replies = [{ tools: [{ name: 'big', args: { data: 'a'.repeat(4 * 1024 * 1024) }, pieces: 256 }] }, {}];
    else if (id === 10) replies = [{ tools: Array.from({ length: 1024 }, () => ({ name: 'pay', args: {} })) }, {}];
    else if ([1, 4, 11].includes(id)) replies = [{}];
    else replies = [{ chunks: Array(20000).fill('abcdefghijklmnopqr\n\n'), delayMs: 1 }];
    let seededItems: number | undefined;
    if (id === 1) session = await seed(cwd, resolve(directory, 'session-1'), Array.from({ length: 2000 }, (_, i) => i % 2 ? assistant([{ type: 'toolCall', id: 'tool-' + i, name: 'read', arguments: { path: 'file-' + i } }], 1700000000000 + i) : assistant([{ type: 'text', text: 'Paragraph ' + i + '\n\n' + 'Long session text. '.repeat(20) }], 1700000000000 + i)));
    if (id === 13) {
      const { texts } = historyMessages();
      session = await seed(cwd, resolve(directory, 'session-13'), texts.map((text, at) => at % 2 ? assistant([{ type: 'text', text }], 1700000000000 + at) : { role: 'user', content: text, timestamp: 1700000000000 + at }));
      seededItems = texts.length;
    }
    await writeFile(resolve(directory, `${id}.json`), JSON.stringify({ replies, session, items: seededItems }));
  }
}
if (process.argv[1] && await realpath(process.argv[1]) === await realpath(fileURLToPath(import.meta.url))) {
  const [directory, cwd] = process.argv.slice(2);
  if (!directory || !cwd) throw Error('A script directory and a working directory are required');
  await scripts(resolve(directory), resolve(cwd));
}
