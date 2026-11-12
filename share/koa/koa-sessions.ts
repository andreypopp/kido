import { Socket } from 'node:net';
import { createInterface } from 'node:readline';
import { parseArgs, SessionManager, type ExtensionAPI } from '@earendil-works/pi-coding-agent';
import type { KoaQuery, KoaReply } from './koa-channel.ts';
import { sessionDir } from './koa-session-dir.ts';
import { errorText } from './text.ts';
import { resolveCompletionContext } from './completion-context.ts';
import { RESTART_STATE_CHANNEL, type RestartState } from './records.ts';
import { RELOAD_COMMAND } from './koa-records.ts';

const RESTART_STATE_MS = 1000;

// Pi reloads this module on a cross-folder switch (dist/core/extensions/loader.js:94-104,481).
declare global {
  var koaSessionsConnection: { channel: Socket; lines: ReturnType<typeof createInterface>; generation: number } | undefined;
}
if (!globalThis.koaSessionsConnection) {
  const channel = new Socket({ fd: 3, readable: true, writable: true });
  const lines = createInterface({ input: channel });
  channel.on('error', () => lines.close());
  process.once('exit', () => channel.destroy());
  globalThis.koaSessionsConnection = { channel, lines, generation: 0 };
}
const connection = globalThis.koaSessionsConnection;
const { channel, lines } = connection;

export default function (pi: ExtensionAPI) {
  const scans = new Map<string, AbortController>();
  const args = parseArgs(process.argv.slice(2));
  let cwd = process.cwd();
  pi.registerCommand(RELOAD_COMMAND, { description: 'Reload pi', handler: async (_args, ctx) => { await ctx.reload(); } });
  const send = (reply: KoaReply) => channel.write(JSON.stringify(reply) + '\n');
  pi.on('session_shutdown', () => { for (const scan of scans.values()) scan.abort(); scans.clear(); send({ type: 'reset' }); lines.off('line', receive); });
  pi.on('session_start', (_event, ctx) => {
    cwd = ctx.sessionManager.getCwd();
    send({ type: 'session', id: ctx.sessionManager.getSessionId(), generation: ++connection.generation, cwd });
  });
  const receive = (line: string) => {
    let query: KoaQuery;
    try { query = JSON.parse(line); } catch { return; }
    if (query.type === 'cancel') { scans.get(query.id)?.abort(); scans.delete(query.id); return; }
    const controller = new AbortController();
    scans.set(query.id, controller);
    if (query.type === 'completion_context') {
      void resolveCompletionContext(controller.signal).then(context => {
        if (!controller.signal.aborted) send({ type: 'completion_context', id: query.id, context });
      }).finally(() => scans.delete(query.id));
      return;
    }
    if (query.type === 'restart_state') {
      void new Promise<RestartState | undefined>(resolve => {
        const timer = setTimeout(resolve, RESTART_STATE_MS, undefined);
        pi.events.emit(RESTART_STATE_CHANNEL, { reply: (state: RestartState) => { clearTimeout(timer); resolve(state); } });
      }).then(state => {
        if (controller.signal.aborted) return;
        send(state ? { type: 'restart_state', id: query.id, state } : { type: 'error', id: query.id, error: 'the extension did not answer' });
      }).finally(() => scans.delete(query.id));
      return;
    }
    const dir = sessionDir(args, cwd);
    void (query.scope === 'current' ? SessionManager.list(cwd, dir, undefined, controller.signal) : SessionManager.listAll(dir, undefined, controller.signal)).then(rows => {
      if (!controller.signal.aborted) send({ type: 'list', id: query.id, rows: rows.map(row => ({ path: row.path, id: row.id, cwd: row.cwd, name: row.name, firstMessage: (row.firstMessage.split(/\r?\n/, 1)[0] ?? '').slice(0, 200), modified: row.modified.getTime(), messageCount: row.messageCount })) });
    }, error => { if (!controller.signal.aborted) send({ type: 'error', id: query.id, error: errorText(error) }); }).finally(() => scans.delete(query.id));
  };
  lines.on('line', receive);
}
