import type { Attachment } from './koa-records.ts';

export function promptText(text: string, attachments: readonly Attachment[]): string {
  const paths = attachments.filter(file => file.kind === 'file').map(file => file.path).join('\n');
  if (!paths) return text;
  if (text === paths) return '';
  const suffix = '\n' + paths;
  return text.endsWith(suffix) ? text.slice(0, -suffix.length) : text;
}

export function bashCommand(text: string): { command: string; excludeFromContext: boolean; prefixLength: 1 | 2 } | undefined {
  if (!text.startsWith('!')) return;
  const prefixLength = text.startsWith('!!') ? 2 : 1;
  return { command: text.slice(prefixLength).trimStart(), excludeFromContext: prefixLength === 2, prefixLength };
}

