import { createInterface } from 'node:readline';
import { Duplex, type Stream } from 'node:stream';
import type { SessionRow, SessionScope } from './koa-records.ts';
import { later } from './koa-timer.ts';

export type SessionQuery = { type: 'list'; id: string; scope: SessionScope } | { type: 'cancel'; id: string };
export type SessionReply = { type: 'list'; id: string; rows: SessionRow[] } | { type: 'error'; id: string; error: string } | { type: 'session'; id: string; generation: number; cwd: string };
const RESPONSE_MS = 10000;

export function sessionChannel(stream: Stream | null | undefined) {
  if (!(stream instanceof Duplex)) throw new Error('Session channel requires a duplex stream');
  let serial = 0;
  let metadata: Extract<SessionReply, { type: 'session' }> | undefined;
  const waiting = new Map<string | undefined, { after: number; resolve(value: Extract<SessionReply, { type: 'session' }>): void; reject(error: Error): void }>();
  const pending = new Map<string, { resolve(rows: SessionRow[]): void; reject(error: Error): void }>();
  const lines = createInterface({ input: stream });
  const abort = (id: string) => {
    stream.write(JSON.stringify({ type: 'cancel', id }) + '\n');
    pending.get(id)?.reject(new Error('Session scan cancelled')); pending.delete(id);
  };
  const close = () => {
    for (const entry of pending.values()) entry.reject(new Error('Session channel closed'));
    pending.clear();
    for (const entry of waiting.values()) entry.reject(new Error('Session channel closed'));
    waiting.clear(); lines.close();
  };
  stream.on('error', close); stream.once('close', close);
  lines.on('line', line => {
    let reply: SessionReply;
    try { reply = JSON.parse(line); } catch { return; }
    if (reply.type === 'session') {
      metadata = reply;
      for (const [id, entry] of waiting) if ((id === undefined || id === reply.id) && reply.generation > entry.after) { entry.resolve(reply); waiting.delete(id); }
    } else {
      const entry = pending.get(reply.id); pending.delete(reply.id);
      if (reply.type === 'error') entry?.reject(new Error(reply.error)); else entry?.resolve(reply.rows);
    }
  });
  return {
    cancel() { for (const id of pending.keys()) abort(id); },
    get generation() { return metadata?.generation ?? 0; },
    current(id: string | undefined, after = 0): Promise<Extract<SessionReply, { type: 'session' }>> {
      if (metadata && (id === undefined || metadata.id === id) && metadata.generation > after) return Promise.resolve(metadata);
      return new Promise((resolve, reject) => {
        const timer = later(() => { waiting.delete(id); reject(new Error('Session metadata timed out')); }, RESPONSE_MS);
        waiting.set(id, { after, resolve(value) { clearTimeout(timer); resolve(value); }, reject(error) { clearTimeout(timer); reject(error); } });
      });
    },
    list(scope: SessionScope, signal: AbortSignal): Promise<SessionRow[]> {
      const id = String(++serial);
      return new Promise((resolve, reject) => {
        const cancel = () => abort(id);
        const timer = later(cancel, RESPONSE_MS);
        const clear = () => { clearTimeout(timer); signal.removeEventListener('abort', cancel); };
        pending.set(id, { resolve(rows) { clear(); resolve(rows); }, reject(error) { clear(); reject(error); } });
        signal.addEventListener('abort', cancel, { once: true });
        if (signal.aborted) cancel();
        else stream.write(JSON.stringify({ type: 'list', id, scope }) + '\n');
      });
    },
    close,
  };
}
