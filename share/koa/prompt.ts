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

export function shellPathToken(text: string, pos: number, bang = bashCommand(text)): { from: number; to: number; query: string } | undefined {
  if (!bang || pos < text.length && !/\s/.test(text[pos])) return;
  const before = text.slice(bang.prefixLength, pos);
  if (/["'`\\$]/.test(before)) return;
  const query = /(?:^|\s)((?:\.\.?\/|~\/|\/)[^\s;&|<>()@*?\[\]{}]*)$/.exec(before)?.[1];
  if (query === undefined) return;
  return { from: pos - query.length, to: pos, query };
}

export function shellQuote(path: string): string {
  const home = path.startsWith('~/'), rest = home ? path.slice(2) : path;
  return (home ? '~/' : '') + (/^[\w./+-]+$/.test(rest) ? rest : "'" + rest.replace(/'/g, "'\\''") + "'");
}

