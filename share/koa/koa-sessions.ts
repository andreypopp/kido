import { Socket } from 'node:net';
import { createInterface } from 'node:readline';
import { parseArgs, SessionManager, type ExtensionAPI } from '@earendil-works/pi-coding-agent';
import type { SessionQuery, SessionReply } from './koa-session-channel.ts';
import { sessionDir } from './koa-session-dir.ts';
import { errorText } from '../pi/text.ts';

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
  const send = (reply: SessionReply) => channel.write(JSON.stringify(reply) + '\n');
  pi.on('session_shutdown', () => { for (const scan of scans.values()) scan.abort(); scans.clear(); lines.off('line', receive); });
  pi.on('session_start', (_event, ctx) => {
    cwd = ctx.sessionManager.getCwd();
    send({ type: 'session', id: ctx.sessionManager.getSessionId(), generation: ++connection.generation, cwd });
  });
  const receive = (line: string) => {
    let query: SessionQuery;
    try { query = JSON.parse(line); } catch { return; }
    if (query.type === 'cancel') { scans.get(query.id)?.abort(); scans.delete(query.id); return; }
    const controller = new AbortController();
    scans.set(query.id, controller);
    const dir = sessionDir(args, cwd);
    void (query.scope === 'current' ? SessionManager.list(cwd, dir, undefined, controller.signal) : SessionManager.listAll(dir, undefined, controller.signal)).then(rows => {
      if (!controller.signal.aborted) send({ type: 'list', id: query.id, rows: rows.map(row => ({ path: row.path, id: row.id, cwd: row.cwd, name: row.name, firstMessage: (row.firstMessage.split(/\r?\n/, 1)[0] ?? '').slice(0, 200), modified: row.modified.getTime(), messageCount: row.messageCount })) });
    }, error => { if (!controller.signal.aborted) send({ type: 'error', id: query.id, error: errorText(error) }); }).finally(() => scans.delete(query.id));
  };
  lines.on('line', receive);
}
