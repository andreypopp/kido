import { createInterface } from 'node:readline';
import { Duplex, type Stream } from 'node:stream';
import type { SessionRow, SessionScope } from './koa-records.ts';
import type { CompletionContext } from '../pi/completion-context.ts';
import type { RestartState } from '../pi/records.ts';
import { later } from './koa-timer.ts';

export type KoaQuery = { type: 'list'; id: string; scope: SessionScope } | { type: 'completion_context'; id: string } | { type: 'restart_state'; id: string } | { type: 'cancel'; id: string };
export type KoaReply = { type: 'list'; id: string; rows: SessionRow[] } | { type: 'completion_context'; id: string; context: CompletionContext } | { type: 'restart_state'; id: string; state: RestartState } | { type: 'error'; id: string; error: string } | { type: 'session'; id: string; generation: number; cwd: string } | { type: 'reset' };
const RESPONSE_MS = 10000;

export function koaChannel(stream: Stream | null | undefined) {
  if (!(stream instanceof Duplex)) throw new Error('Koa channel requires a duplex stream');
  let serial = 0, stop = new AbortController();
  let metadata: Extract<KoaReply, { type: 'session' }> | undefined;
  const waiting = new Map<string | undefined, { after: number; resolve(value: Extract<KoaReply, { type: 'session' }>): void; reject(error: Error): void }>();
  const pending = new Map<string, { resolve(reply: Extract<KoaReply, { type: 'list' | 'completion_context' | 'restart_state' }>): void; reject(error: Error): void }>();
  const lines = createInterface({ input: stream });
  const abort = (id: string) => {
    stream.write(JSON.stringify({ type: 'cancel', id } satisfies KoaQuery) + '\n');
    pending.get(id)?.reject(new Error('Koa request cancelled')); pending.delete(id);
  };
  const reset = () => {
    stop.abort(); stop = new AbortController();
    for (const entry of pending.values()) entry.reject(new Error('Pi session changed'));
    pending.clear();
  };
  const close = () => {
    reset(); stop.abort();
    for (const entry of waiting.values()) entry.reject(new Error('Koa channel closed'));
    waiting.clear(); lines.close();
  };
  stream.on('error', close); stream.once('close', close);
  lines.on('line', line => {
    let reply: KoaReply;
    try { reply = JSON.parse(line); } catch { return; }
    if (reply.type === 'reset') { reset(); return; }
    if (reply.type === 'session') {
      metadata = reply;
      for (const [id, entry] of waiting) if ((id === undefined || id === reply.id) && reply.generation > entry.after) { entry.resolve(reply); waiting.delete(id); }
    } else {
      const entry = pending.get(reply.id); pending.delete(reply.id);
      if (reply.type === 'error') entry?.reject(new Error(reply.error)); else entry?.resolve(reply);
    }
  });
  const request = (query: { type: 'list'; scope: SessionScope } | { type: 'completion_context' } | { type: 'restart_state' }, signal: AbortSignal): Promise<Extract<KoaReply, { type: 'list' | 'completion_context' | 'restart_state' }>> => {
    const id = String(++serial);
    return new Promise((resolve, reject) => {
      const cancel = () => abort(id);
      const timer = later(cancel, RESPONSE_MS);
      const clear = () => { clearTimeout(timer); signal.removeEventListener('abort', cancel); };
      pending.set(id, { resolve(reply) { clear(); resolve(reply); }, reject(error) { clear(); reject(error); } });
      signal.addEventListener('abort', cancel, { once: true });
      if (signal.aborted || stream.destroyed) cancel();
      else stream.write(JSON.stringify({ ...query, id } satisfies KoaQuery) + '\n');
    });
  };
  return {
    cancel() { stop.abort(); stop = new AbortController(); for (const id of pending.keys()) abort(id); },
    signal: () => stop.signal,
    get generation() { return metadata?.generation ?? 0; },
    current(id: string | undefined, after = 0): Promise<Extract<KoaReply, { type: 'session' }>> {
      if (metadata && (id === undefined || metadata.id === id) && metadata.generation > after) return Promise.resolve(metadata);
      return new Promise((resolve, reject) => {
        const timer = later(() => { waiting.delete(id); reject(new Error('Session metadata timed out')); }, RESPONSE_MS);
        waiting.set(id, { after, resolve(value) { clearTimeout(timer); resolve(value); }, reject(error) { clearTimeout(timer); reject(error); } });
      });
    },
    async list(scope: SessionScope, signal: AbortSignal): Promise<SessionRow[]> {
      const reply = await request({ type: 'list', scope }, signal);
      if (reply.type !== 'list') throw new Error('Invalid session list reply');
      return reply.rows;
    },
    async completionContext(signal: AbortSignal): Promise<CompletionContext> {
      try {
        const reply = await request({ type: 'completion_context' }, signal);
        return reply.type === 'completion_context' ? reply.context : { type: 'unavailable' };
      } catch { return { type: 'unavailable' }; }
    },
    async restartState(signal: AbortSignal): Promise<RestartState | undefined> {
      try {
        const reply = await request({ type: 'restart_state' }, signal);
        return reply.type === 'restart_state' ? reply.state : undefined;
      } catch { return undefined; }
    },
    close,
  };
}
