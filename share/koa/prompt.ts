import type { Attachment } from './koa-records.ts';

export function promptText(text: string, attachments: readonly Attachment[]): string {
  const paths = attachments.filter(file => file.kind === 'file').map(file => file.path).join('\n');
  if (!paths) return text;
  if (text === paths) return '';
  const suffix = '\n' + paths;
  return text.endsWith(suffix) ? text.slice(0, -suffix.length) : text;
}

export function nameCommand(text: string): { type: 'query' } | { type: 'set'; name: string } | undefined {
  const match = /^\/name(?:\s+([\s\S]*))?$/.exec(text.trim());
  if (!match) return;
  const name = (match[1] ?? '').trim();
  return name ? { type: 'set', name } : { type: 'query' };
}

