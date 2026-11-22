import type { Attachment } from './koa-records.ts';
import { parseTopicName, type TopicName } from './records.ts';

export function decodePrompt(source: string, attachments: readonly Attachment[], kind: 'root' | 'subagent'): { text: string; topic?: TopicName } {
  const paths = attachments.filter(file => file.kind === 'file').map(file => file.path).join('\n');
  const text = paths && source === paths ? '' : paths && source.endsWith('\n' + paths) ? source.slice(0, -paths.length - 1) : source;
  const marker = kind === 'root' ? /^\[topic: ([^\]]*)\](?:\r?\n|$)/.exec(text) : null;
  const topic = marker ? parseTopicName(marker[1]) : undefined;
  return marker && topic ? { text: text.slice(marker[0].length), topic } : { text };
}

export function topicPrompt(text: string, topic: TopicName | undefined): string {
  return topic ? `[topic: ${topic}]\n${decodePrompt(text, [], 'root').text}` : text;
}

export function bashCommand(text: string): { command: string; excludeFromContext: boolean; prefixLength: 1 | 2 } | undefined {
  if (!text.startsWith('!')) return;
  const prefixLength = text.startsWith('!!') ? 2 : 1;
  return { command: text.slice(prefixLength).trimStart(), excludeFromContext: prefixLength === 2, prefixLength };
}

