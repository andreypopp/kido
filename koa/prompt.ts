import type { Attachment } from './koa-records.ts';
import { parseThreadName, type ThreadName } from './records.ts';

export function decodePrompt(source: string, attachments: readonly Attachment[], kind: 'root' | 'subagent'): { text: string; thread?: ThreadName } {
  const paths = attachments.filter(file => file.kind === 'file').map(file => file.path).join('\n');
  const text = paths && source === paths ? '' : paths && source.endsWith('\n' + paths) ? source.slice(0, -paths.length - 1) : source;
  const marker = kind === 'root' ? /^\[thread: ([^\]]*)\](?:\r?\n|$)/.exec(text) : null;
  const thread = marker ? parseThreadName(marker[1]) : undefined;
  return marker && thread ? { text: text.slice(marker[0].length), thread } : { text };
}

export function threadPrompt(text: string, thread: ThreadName | undefined): string {
  return thread ? `[thread: ${thread}]\n${decodePrompt(text, [], 'root').text}` : text;
}

export function bashCommand(text: string): { command: string; excludeFromContext: boolean; prefixLength: 1 | 2 } | undefined {
  if (!text.startsWith('!')) return;
  const prefixLength = text.startsWith('!!') ? 2 : 1;
  return { command: text.slice(prefixLength).trimStart(), excludeFromContext: prefixLength === 2, prefixLength };
}

