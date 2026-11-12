import { readFile } from 'node:fs/promises';
import { runtimeExec } from './runtime-exec.ts';
import type { CompletionContext } from './completion-context.ts';
import type { ShellCompletion } from './koa-records.ts';
import type { bashCommand } from './prompt.ts';
import { output } from './koa-complete.ts';

const script = await readFile(new URL('./koa-shell.sh', import.meta.url), 'utf8');

export async function shellComplete(text: string, caret: number, context: CompletionContext, ko: string, signal: AbortSignal, bang?: ReturnType<typeof bashCommand>): Promise<ShellCompletion> {
  const empty: ShellCompletion = { type: 'shell', from: caret, to: caret, options: [], common: '', more: 0 };
  const prefix = bang?.prefixLength ?? 0, line = text.slice(prefix), pos = caret - prefix;
  if (context.type === 'unavailable' || signal.aborted || line.length > 65536 || !Number.isInteger(pos) || pos < 0 || pos > line.length) return empty;
  if (line.charCodeAt(pos - 1) >= 0xd800 && line.charCodeAt(pos - 1) <= 0xdbff && line.charCodeAt(pos) >= 0xdc00 && line.charCodeAt(pos) <= 0xdfff) return empty;
  const args = [script, line, String(Buffer.byteLength(line.slice(0, pos)))];
  try {
    let body: Buffer | undefined;
    if (context.type === 'runtime') {
      const stop = new AbortController(), chunks: Buffer[] = [];
      let size = 0;
      const result = await runtimeExec(ko, context.name, {
        argv: ['sh', '-c', 'shell=$(command -v bash 2>/dev/null) || shell=sh; script=$1; shift; exec "$shell" -lc "$script" koa-complete "$@"', 'koa-complete', 'cd -- "$4" || exit 1; exec sh -c "$1" koa-complete "$1" "$2" "$3"', ...args, context.cwd],
        cwd: context.cwd, signal: AbortSignal.any([signal, stop.signal]),
        onStdout(data) { size += data.length; if (size > 1024 * 1024) stop.abort(); else chunks.push(data); },
      });
      if (stop.signal.aborted || result.end.type !== 'exit' || result.end.code !== 0) return empty;
      body = Buffer.concat(chunks);
    } else body = await output('/bin/sh', ['-c', script, 'koa-complete', ...args], signal, context.cwd);
    if (!body || signal.aborted) return empty;
    const fields = new TextDecoder('utf-8', { fatal: true }).decode(body).split('\0');
    if (![fields[0], fields[1], fields[3]].every(value => /^(0|[1-9][0-9]*)$/.test(value ?? ''))) return empty;
    const from = Number(fields[0]), to = Number(fields[1]), common = fields[2] ?? '', count = Number(fields[3]);
    const bytes = Buffer.from(line), point = Buffer.byteLength(line.slice(0, pos));
    if (![from, to, count].every(Number.isSafeInteger) || from > point || point > to || to > bytes.length || fields.length !== 5 + 2 * Math.min(200, count) || fields.at(-1) !== '') return empty;
    if (((bytes[from] ?? 0) & 0xc0) === 0x80 || ((bytes[to] ?? 0) & 0xc0) === 0x80) return empty;
    const offset = (n: number) => prefix + bytes.subarray(0, n).toString('utf8').length;
    const options = [];
    for (let at = 4; at + 1 < fields.length && options.length < Math.min(200, count); at += 2) {
      const label = fields[at], insert = fields[at + 1];
      if (!label || !insert) return empty;
      options.push({ label, insert });
    }
    return { type: 'shell', from: offset(from), to: offset(to), common, more: count - options.length, options };
  } catch { return empty; }
}
