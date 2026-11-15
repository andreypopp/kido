import { closeSync, existsSync, openSync, readSync, fstatSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { BackgroundJob } from "./koa-agent.ts";
import type { JobRef } from "./records.ts";
import { frame, forget, send, follow, take, expire, type ViewAddress } from "./koa-feed.ts";
import { LOG_CHUNK, readLog } from "./koa-job-log.ts";
import type { LogChunk, PageRecord } from "./koa-records.ts";
import { mintId } from "./text.ts";

const KEEPALIVE_MS = 15000;

type Cursor = { sent: number; busy: boolean; stateDue: boolean };

type Source = { id: string; log: string; logged(): number; tail(): Buffer; flushed(): Promise<void>; missing(): boolean };

export const liveSource = (job: BackgroundJob): Source => ({
  id: job.id, log: job.mode.log, missing: () => !existsSync(job.mode.log),
  logged: () => job.mode.logged,
  tail: () => job.tail,
  flushed: () => job.state.type === "ended" ? job.mode.logClosed : new Promise(done => { try { job.mode.output.write("", () => done()); } catch { done(); } }),
});

export function fileSource(ref: JobRef): Source {
  let size = 0, tail = Buffer.alloc(0), missing = false;
  try {
    const fd = openSync(ref.log, "r");
    try {
      size = fstatSync(fd).size;
      tail = Buffer.alloc(Math.min(size, 64 * 1024));
      readSync(fd, tail, 0, tail.length, size - tail.length);
    } finally { closeSync(fd); }
  } catch { missing = true; }
  return { id: ref.id, log: ref.log, missing: () => missing, logged: () => size, tail: () => tail, flushed: () => Promise.resolve() };
}

export function jobView(source: Source, empty: () => void = () => {}) {
  const epoch = mintId();
  const lifetime = new AbortController();
  const cursors = new WeakMap<ServerResponse, Cursor>();
  const subscribers = new Set<ServerResponse>();
  let currentState: PageRecord | undefined;
  const tailStart = (): number => source.logged() - source.tail().length;
  const flushed = source.flushed;
  const sendState = (response: ServerResponse): void => { if (currentState) send(response, frame(currentState), true); };
  const open = (response: ServerResponse): void => {
    const end = source.logged();
    send(response, frame({ type: "job-reset", view: source.id, epoch, start: tailStart(), end, data: source.tail().toString("base64") }), true);
    cursors.set(response, { sent: end, busy: false, stateDue: false });
    if (source.missing()) send(response, frame({ type: "job-gone", view: source.id }), true);
  };
  const pump = async (response: ServerResponse): Promise<void> => {
    const cursor = cursors.get(response);
    if (!cursor || cursor.busy) return;
    cursor.busy = true;
    const owned = (): boolean => cursors.get(response) === cursor && !lifetime.signal.aborted && !response.destroyed && !response.writableEnded;
    try {
      while (owned() && cursor.sent < source.logged()) {
        const start = cursor.sent, base = tailStart();
        let end: number, data: string;
        if (start >= base) { end = source.logged(); data = source.tail().subarray(start - base).toString("base64"); }
        else {
          await flushed();
          const chunk = await readLog(source.log, start, Math.min(start + LOG_CHUNK, base), lifetime.signal);
          end = chunk.end; data = chunk.data;
        }
        if (!owned()) return;
        send(response, frame({ type: "job-append", view: source.id, epoch, start, data }), true);
        cursor.sent = end;
      }
    } catch { if (owned()) send(response, "", false); }
    finally {
      cursor.busy = false;
      if (owned() && cursor.stateDue) { cursor.stateDue = false; sendState(response); }
    }
  };
  return {
    release(): Set<ServerResponse> {
      const held = take(subscribers);
      for (const response of held) cursors.delete(response);
      return held;
    },
    show(previous: { release(): Set<ServerResponse> }): void {
      for (const response of previous.release()) { follow(subscribers, response, { type: "selected" }, empty); sendState(response); open(response); }
    },
    state(record: Extract<PageRecord, { type: "state" }>): void {
      currentState = record;
      for (const response of subscribers) {
        const cursor = cursors.get(response);
        if (cursor?.busy) cursor.stateDue = true; else sendState(response);
      }
    },
    subscribed: (): boolean => subscribers.size > 0,
    expire: (parent: string): void => expire(subscribers, parent),
    output(): void { for (const response of subscribers) void pump(response); },
    handle(request: IncomingMessage, response: ServerResponse, address: ViewAddress = { type: "selected" }): boolean {
      const url = new URL(request.url ?? "/", "http://koa");
      if (request.method !== "GET" || url.pathname !== "/events") return false;
      const keepalive = setInterval(() => { if (!response.destroyed && !response.writableEnded) response.write(":\n\n"); }, KEEPALIVE_MS);
      keepalive.unref();
      response.once("close", () => { clearInterval(keepalive); forget(response); });
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.flushHeaders();
      follow(subscribers, response, address, empty);
      const after = Number(url.searchParams.get("after") ?? "");
      if (url.searchParams.get("epoch") === epoch && Number.isSafeInteger(after) && after >= 0 && after <= source.logged()) {
        cursors.set(response, { sent: after, busy: false, stateDue: true });
        void pump(response);
      } else { sendState(response); open(response); }
      return true;
    },
    async earlier(requestEpoch: string, before: number, signal: AbortSignal): Promise<LogChunk | undefined> {
      if (requestEpoch !== epoch || !Number.isSafeInteger(before) || before < 0 || before > source.logged()) return undefined;
      await flushed();
      return readLog(source.log, Math.max(0, before - LOG_CHUNK), before, AbortSignal.any([signal, lifetime.signal]));
    },
    close(): void {
      lifetime.abort();
      for (const response of subscribers) response.end();
      subscribers.clear();
    },
  };
}
