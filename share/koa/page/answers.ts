export const plain = (text: string): string => text.replace(/[`*]|__|~~/g, '');

export function quote(source: string): string {
  return source.replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1').split('\n').map(line => plain(line).replace(/[ \t]+/g, ' ').trim()).filter(Boolean).join('\n');
}

const head = (quote: string): string => quote.split('\n').map(line => '> ' + line).join('\n') + '\n\n';

export function current(text: string, quote: string): string | undefined {
  const prefix = head(quote), found = text.indexOf(prefix);
  const at = found > 0 && text.slice(found - 2, found) !== '\n\n' ? -1 : found;
  if (at < 0) return;
  const next = text.indexOf('\n\n> ', at + prefix.length);
  return text.slice(at + prefix.length, next < 0 ? undefined : next);
}

export function answer(text: string, quote: string, answer: string, overwrite: boolean): string {
  const prefix = head(quote), block = prefix + answer, at = current(text, quote) === undefined ? -1 : text.indexOf(prefix);
  if (at < 0) return text.trim() ? text + '\n\n' + block : block;
  if (!answer && !overwrite) return text;
  const next = text.indexOf('\n\n> ', at + prefix.length);
  return text.slice(0, at) + block + (next < 0 ? '' : text.slice(next));
}
