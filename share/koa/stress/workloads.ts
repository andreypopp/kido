import { writeFile, mkdir, realpath } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const names = ['long-session', 'fast-tokens', 'large-output', 'large-prompt', 'reconnects', 'many-panes', 'hidden-shown', 'themes', 'fetch-concurrency', 'slow-page', 'body-kinds', 'children'];
export const pageWorkloads = [1, 2, 3, 4, 5, 8, 9, 10, 11];
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const assistant = (content: object[]) => ({ role: 'assistant', api: 'test', provider: 'test', model: 'test', usage, timestamp: Date.now(), stopReason: 'stop', content });
export async function scripts(directory: string) {
  await mkdir(directory, { recursive: true });
  for (let id = 1; id <= 12; id++) {
    const messages = id === 1 ? Array.from({ length: 2000 }, (_, i) => assistant(i % 2 ? [{ type: 'toolCall', id: 'tool-' + i, name: 'read', arguments: { path: 'file-' + i } }] : [{ type: 'text', text: 'Paragraph ' + i + '\n\n' + 'Long session text. '.repeat(20) }])) : [];
    const steps: object[] = [
      { type: 'respond', command: 'get_messages', data: { messages } },
      { type: 'wait', command: 'prompt', events: [{ type: 'agent_start' }, { type: 'message_start', message: assistant([{ type: 'text', text: '' }]) }] },
    ];
    if (id === 3) {
      const call = { type: 'toolCall', id: 'large', name: 'bash', arguments: { command: 'a'.repeat(4 * 1024 * 1024) } };
      steps.push({ type: 'emit', event: { type: 'message_start', message: assistant([call]) } }, { type: 'emit', event: { type: 'tool_execution_end', toolCallId: 'large', result: { content: [{ type: 'text', text: 'r'.repeat(16 * 1024 * 1024) }] }, isError: false } }, { type: 'emit', event: { type: 'message_end', message: assistant([call]) } });
    } else if (id === 10) {
      steps.push({ type: 'repeat', count: 1024, delayMs: 1, events: [{ type: 'message_end', message: assistant([{ type: 'text', text: 'slow reader payload '.repeat(3277) }]) }] });
    } else if (![1, 4, 11].includes(id)) {
      const delta = 'abcdefghijklmnopqr\n\n';
      steps.push({ type: 'repeat', count: 20000, delayMs: 1, events: [{ type: 'message_update', usage, assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta } }] }, { type: 'emit', event: { type: 'message_end', message: assistant([{ type: 'text', text: delta.repeat(20000) }]) } });
    }
    steps.push({ type: 'emit', event: { type: 'message_end', message: { role: 'custom', customType: 'stress', display: true, timestamp: Date.now(), content: `STRESS DONE ${id}` } } }, { type: 'emit', event: { type: 'agent_settled', aborted: false } });
    await writeFile(resolve(directory, `${id}.jsonl`), steps.map(step => JSON.stringify(step)).join('\n'));
  }
}
if (process.argv[1] && await realpath(process.argv[1]) === await realpath(fileURLToPath(import.meta.url))) {
  const directory = process.argv[2];
  if (!directory) throw Error('A script directory is required');
  await scripts(resolve(directory));
}
