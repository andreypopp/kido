import type { ServerResponse } from "node:http";

const MAX_OUTPUT_BYTES = 1 << 20;

// The feed that holds a page now: the close of a page that moved between feeds reads it here.
const owners = new WeakMap<ServerResponse, Set<ServerResponse>>();

type FeedCounters = { bytes: number; highWater: number; caps: number };

export const frame = (record: object): string => "data: " + JSON.stringify(record) + "\n\n";

export function follow(set: Set<ServerResponse>, response: ServerResponse): void {
  set.add(response);
  owners.set(response, set);
}

export const forget = (response: ServerResponse): void => { owners.get(response)?.delete(response); };

export function send(response: ServerResponse, text: string, more: boolean, counters?: FeedCounters): void {
  if (response.destroyed || response.writableEnded) return;
  if (text) {
    response.write(text);
    if (counters) { counters.bytes += Buffer.byteLength(text); counters.highWater = Math.max(counters.highWater, response.writableLength); }
  }
  if (!more || response.writableLength > MAX_OUTPUT_BYTES) {
    if (counters && response.writableLength > MAX_OUTPUT_BYTES) counters.caps++;
    response.end();
    forget(response);
  }
}
