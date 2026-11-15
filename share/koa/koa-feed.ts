import type { ServerResponse } from "node:http";
import type { PageRecord } from "./koa-records.ts";

const MAX_OUTPUT_BYTES = 1 << 20;

export type ViewAddress = { type: "selected" } | { type: "named"; id: string };

// The feed that holds a page now: the close of a page that moved between feeds reads it here.
const owners = new WeakMap<ServerResponse, { set: Set<ServerResponse>; address: ViewAddress; empty: () => void }>();

type FeedCounters = { bytes: number; highWater: number; caps: number };

export const frame = (record: object): string => "data: " + JSON.stringify(record) + "\n\n";

export function follow(set: Set<ServerResponse>, response: ServerResponse, address: ViewAddress, empty: () => void = () => {}): void {
  set.add(response);
  owners.set(response, { set, address, empty });
}

export const forget = (response: ServerResponse): void => {
  const owner = owners.get(response);
  if (owner?.set.delete(response) && owner.set.size === 0) owner.empty();
};

export function take(set: Set<ServerResponse>): Set<ServerResponse> {
  const held = new Set<ServerResponse>();
  for (const response of set) if (owners.get(response)?.address.type === "selected") { set.delete(response); held.add(response); }
  return held;
}

export function expire(set: Set<ServerResponse>, parent: string): void {
  for (const response of [...set]) {
    const address = owners.get(response)?.address;
    if (address?.type === "named") send(response, frame({ type: "view_gone", view: address.id, parent } satisfies PageRecord), false);
  }
}

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
