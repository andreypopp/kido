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
] as const;
export const pageWorkloads = [1, 2, 3, 4, 5, 8, 9, 10, 11];
export const stressModels = [{ provider: 'fake', id: 'fake-model', contextWindow: 1_000_000_000 }];
export const stressSettings = { compaction: { enabled: false } };
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
type Assistant = Extract<Parameters<SessionManager['appendMessage']>[0], { role: 'assistant' }>;
const assistant = (content: Assistant['content'], timestamp: number): Assistant => ({ role: 'assistant', api: 'test', provider: 'test', model: 'test', usage, timestamp, stopReason: 'stop', content });

// Writes `${id}.json` for each workload: the provider's replies and, for the long session, the seeded session file.
export async function scripts(directory: string, cwd: string) {
  await mkdir(directory, { recursive: true });
  await mkdir(cwd, { recursive: true });
  for (let id = 1; id <= workloads.length; id++) {
    let replies: Reply[];
    let session: string | undefined;
    if (id === 3) replies = [{ tools: [{ name: 'big', args: { data: 'a'.repeat(4 * 1024 * 1024) }, pieces: 256 }] }, {}];
    else if (id === 10) replies = [{ tools: Array.from({ length: 1024 }, () => ({ name: 'pay', args: {} })) }, {}];
    else if ([1, 4, 11].includes(id)) replies = [{}];
    else replies = [{ chunks: Array(20000).fill('abcdefghijklmnopqr\n\n'), delayMs: 1 }];
    if (id === 1) {
      const manager = SessionManager.create(cwd, resolve(directory, 'session-1'));
      for (let i = 0; i < 2000; i++) manager.appendMessage(assistant(i % 2 ? [{ type: 'toolCall', id: 'tool-' + i, name: 'read', arguments: { path: 'file-' + i } }] : [{ type: 'text', text: 'Paragraph ' + i + '\n\n' + 'Long session text. '.repeat(20) }], 1700000000000 + i));
      session = manager.getSessionFile();
      if (!session) throw Error('The long session has no file');
      await writeFile(session, [manager.getHeader(), ...manager.getEntries()].map(entry => JSON.stringify(entry)).join('\n') + '\n');
    }
    await writeFile(resolve(directory, `${id}.json`), JSON.stringify({ replies, session }));
  }
}
if (process.argv[1] && await realpath(process.argv[1]) === await realpath(fileURLToPath(import.meta.url))) {
  const [directory, cwd] = process.argv.slice(2);
  if (!directory || !cwd) throw Error('A script directory and a working directory are required');
  await scripts(resolve(directory), resolve(cwd));
}
