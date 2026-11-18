export function pathToken(text: string): { path: string; line?: number; col?: number } | undefined {
  if (!text || /[\s\p{Cc}\p{Cf}]/u.test(text) || text.includes('://')) return;
  const match = /^(.*?)(?::([1-9][0-9]*)(?::([1-9][0-9]*))?)?$/.exec(text);
  if (!match) return;
  const path = match[1] ?? '', line = match[2] === undefined ? undefined : Number(match[2]), col = match[3] === undefined ? undefined : Number(match[3]);
  const basename = path.slice(path.lastIndexOf('/') + 1), dot = basename.lastIndexOf('.');
  if (!path || path.includes(':') || !path.includes('/') && !(dot > 0 && dot < basename.length - 1 && basename[dot - 1] !== '.')) return;
  if (line !== undefined && !Number.isSafeInteger(line) || col !== undefined && !Number.isSafeInteger(col)) return;
  return { path, ...(line === undefined ? {} : { line }), ...(col === undefined ? {} : { col }) };
}
