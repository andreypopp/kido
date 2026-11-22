import type { ServerResponse } from "node:http";
import type { PageRecord } from "./koa-records.ts";

const MAX_OUTPUT_BYTES = 1 << 20;
const resetBytes = new WeakMap<ServerResponse, number>();

export type ViewAddress = { type: "selected" } | { type: "named"; id: string };

// The feed that holds a page now: the close of a page that moved between feeds reads it here.
const owners = new Map<ServerResponse, { set: Set<ServerResponse>; address: ViewAddress; document: boolean; empty: () => void }>();

type FeedCounters = { bytes: number; highWater: number; caps: number };

export const frame = (record: object): string => "data: " + JSON.stringify(record) + "\n\n";

export function follow(set: Set<ServerResponse>, response: ServerResponse, address: ViewAddress, empty: () => void = () => {}, document = owners.get(response)?.document ?? false): void {
  set.add(response);
  owners.set(response, { set, address, document, empty });
}

export const forget = (response: ServerResponse): void => {
  const owner = owners.get(response);
  owners.delete(response);
  if (owner?.set.delete(response) && owner.set.size === 0) owner.empty();
};

export function reloadPages(): void {
  for (const [response, owner] of owners) if (owner.document) send(response, frame({ type: "reload" } satisfies PageRecord), "end");
}

export function take(set: Set<ServerResponse>): Set<ServerResponse> {
  const held = new Set<ServerResponse>();
  for (const response of set) if (owners.get(response)?.address.type === "selected") { set.delete(response); held.add(response); }
  return held;
}

export function expire(set: Set<ServerResponse>, parent: string): void {
  for (const response of [...set]) {
    const address = owners.get(response)?.address;
    if (address?.type === "named") send(response, frame({ type: "view_gone", view: address.id, parent } satisfies PageRecord), "end");
  }
}

export function send(response: ServerResponse, text: string, mode: "live" | "reset" | "end", counters?: FeedCounters): void {
  if (response.destroyed || response.writableEnded) return;
  if (text) {
    response.write(text);
    if (counters) { counters.bytes += Buffer.byteLength(text); counters.highWater = Math.max(counters.highWater, response.writableLength); }
  }
  if (mode === "reset") {
    if (!resetBytes.has(response)) response.once("drain", () => resetBytes.delete(response));
    resetBytes.set(response, (resetBytes.get(response) ?? 0) + Buffer.byteLength(text));
  }
  const capped = response.writableLength > (resetBytes.get(response) ?? 0) + MAX_OUTPUT_BYTES;
  if (mode === "end" || capped) {
    if (counters && capped) counters.caps++;
    response.end();
    forget(response);
  }
}
