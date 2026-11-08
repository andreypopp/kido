import type { IncomingMessage, ServerResponse } from "node:http";
import { randomBytes } from "node:crypto";
import type { AgentMessage } from "@earendil-works/pi-agent-core";

const MAX_WEBVIEW_WINDOW_ITEMS = 40;
const MAX_WEBVIEW_WINDOW_BYTES = 256 * 1024;
const MAX_WEBVIEW_ARGS_BYTES = 4 * 1024;
const MAX_WEBVIEW_RESULT_BYTES = 16 * 1024;
const MAX_WEBVIEW_OUTPUT_BYTES = 1 << 20;

export const mintId = (): string => randomBytes(16).toString("base64url");
export const errorText = (error: unknown): string => error instanceof Error ? error.message : String(error);
export const replaceControlCharacters = (text: string): string => text.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ");

export async function readBody(request: IncomingMessage, limit: number): Promise<Buffer | undefined> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size <= limit) chunks.push(chunk);
  }
  return size <= limit ? Buffer.concat(chunks) : undefined;
}

export function promptBody(value: unknown): { text: string; mode: "prompt" | "steer" | "follow_up" } | { error: string } {
  if (value && typeof value === "object" && "text" in value && typeof value.text === "string" && value.text.trim() && "mode" in value && (value.mode === "prompt" || value.mode === "steer" || value.mode === "follow_up")) return { text: value.text, mode: value.mode };
  return { error: "A non-empty text and prompt, steer or follow_up mode are required" };
}

type Text = { text: string; cut: number };
type ToolState = { type: "pending" } | { type: "running"; result?: Text } | { type: "done"; result: Text; error: boolean } | { type: "not_run" };
type Block = { type: "text" | "thinking"; text: string; redacted?: boolean } | { type: "tool"; id: string; name: string; args: Text; state: ToolState; started?: number; ended?: number; durationMs?: number };
type Item = { seq: number; at: number; final: boolean } & (
  { kind: "user"; text: string; images: number } |
  { kind: "assistant"; blocks: Block[]; stop: string; error: string; lifecycle: "streaming" | "ended" } |
  { kind: "notice"; customType: string; from: string; text: string } |
  { kind: "bash"; command: string; output: Text; exit?: number } |
  { kind: "summary"; text: string }
);
type Assistant = Extract<Item, { kind: "assistant" }>;

export type Content = string | readonly { type: string; text?: string }[];

export function contentText(value: Content, separator = "\n"): string {
  return typeof value === "string" ? value : value.flatMap((block) => block.type === "text" ? [block.text ?? ""] : []).join(separator);
}

function cap(text: string, limit: number): Text {
  const bytes = Buffer.byteLength(text);
  const prefix = utf8Prefix(text, limit);
  return { text: prefix, cut: bytes - Buffer.byteLength(prefix) };
}

function wireItem(item: Item) {
  if (item.kind !== "assistant") return item;
  const { lifecycle, ...wire } = item;
  return wire;
}

function final(item: Assistant): boolean {
  return item.lifecycle === "ended" && item.blocks.every((b) => b.type !== "tool" || b.state.type === "done" || b.state.type === "not_run");
}

export function utf8Prefix(text: string, max: number): string {
  if (Buffer.byteLength(text, "utf8") <= max) return text;
  let out = "";
  let used = 0;
  for (const ch of text) {
    const n = Buffer.byteLength(ch, "utf8");
    if (used + n > max) break;
    out += ch;
    used += n;
  }
  return out;
}

export function utf8Suffix(text: string, max: number): string {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= max) return text;
  let start = bytes.length - max;
  while (start < bytes.length && ((bytes[start] ?? 0) & 0xc0) === 0x80) start++;
  return bytes.subarray(start).toString("utf8");
}

export function respond(response: ServerResponse, status: number, text: string, contentType = "application/json"): void {
  response.writeHead(status, { "Content-Type": contentType });
  response.end(text);
}

function notRun(item: Assistant): void {
  for (const block of item.blocks) if (block.type === "tool" && block.state.type === "pending") block.state = { type: "not_run" };
}

export function transcript({ flushMs }: { flushMs: number }) {
  let currentState: object = { type: "state" };
  let epoch = mintId();
  let items: Item[] = [];
  let assistant: number | undefined;
  const subscribers = new Set<ServerResponse>();
  const tools = new Map<string, { item: Assistant; block: Extract<Block, { type: "tool" }> }>();
  const dirty = new Set<number>();
  const sent = new Map<number, Assistant>();
  const pending = new Map<number, { message: Extract<AgentMessage, { role: "assistant" }>; phase: "update" | "end" }>();
  const pendingTools = new Map<string, { type: "running"; content: Content } | { type: "done"; content: Content; error: boolean; at?: number; durationMs?: number }>();
  let flushTimer: NodeJS.Timeout | null = null;

  const body = (req: ServerResponse, text: string, more = false): void => {
    if (req.destroyed || req.writableEnded) return;
    if (text) req.write(text);
    if (!more || req.writableLength > MAX_WEBVIEW_OUTPUT_BYTES) {
      req.end();
      subscribers.delete(req);
    }
  };
  const broadcast = (record: unknown): void => {
    const line = JSON.stringify(record) + "\n";
    for (const req of subscribers) body(req, line, true);
  };
  const window = (before: number): string => {
    let start = Math.min(before, items.length);
    const strings: string[] = [];
    let bytes = 0;
    while (start > 0 && strings.length < MAX_WEBVIEW_WINDOW_ITEMS) {
      const item = JSON.stringify(wireItem(items[start - 1]));
      const size = Buffer.byteLength(item);
      if (strings.length && bytes + size > MAX_WEBVIEW_WINDOW_BYTES) break;
      bytes += size;
      strings.push(item);
      start--;
    }
    return '"items":[' + strings.reverse().join(",") + '],"more":' + (start > 0);
  };
  const reset = (): string => '{"type":"reset","epoch":' + JSON.stringify(epoch) + ',' + window(items.length) + '}' + "\n";
  const schedule = (): void => {
    if (!flushTimer) flushTimer = setTimeout(flush, flushMs);
  };
  const publish = (item: Item): void => { dirty.add(item.seq); };
  const applyAssistant = (item: Assistant, message: Extract<AgentMessage, { role: "assistant" }>, ended: boolean): void => {
    item.blocks = message.content.flatMap((block): Block[] => {
      if (block.type === "text") return [{ type: "text", text: block.text }];
      if (block.type === "thinking") return [{ type: "thinking", text: block.thinking, redacted: !!block.redacted }];
      if (block.type !== "toolCall") return [];
      const existing = tools.get(block.id)?.block;
      const next: Extract<Block, { type: "tool" }> = { ...existing, type: "tool", id: block.id, name: block.name, args: existing && existing.state.type !== "pending" ? existing.args : cap(JSON.stringify(block.arguments), MAX_WEBVIEW_ARGS_BYTES), state: existing?.state ?? { type: "pending" } };
      tools.set(block.id, { item, block: next });
      return [next];
    });
    item.stop = message.stopReason;
    item.error = message.errorMessage ?? "";
    item.lifecycle = ended ? "ended" : "streaming";
    if (ended && (message.stopReason === "error" || message.stopReason === "aborted")) {
      notRun(item);
    }
    publish(item);
  };
  const sameText = (a: Text | undefined, b: Text | undefined): boolean => a?.text === b?.text && a?.cut === b?.cut;
  const sameBlock = (a: Block, b: Block): boolean => {
    if (a.type !== b.type) return false;
    if (a.type !== "tool" && b.type !== "tool") return a.text === b.text && a.redacted === b.redacted;
    if (a.type !== "tool" || b.type !== "tool") return false;
    return a.started === b.started && a.ended === b.ended && a.durationMs === b.durationMs && a.id === b.id && a.name === b.name && sameText(a.args, b.args) && a.state.type === b.state.type
      && sameText("result" in a.state ? a.state.result : undefined, "result" in b.state ? b.state.result : undefined)
      && (a.state.type !== "done" || b.state.type === "done" && a.state.error === b.state.error);
  };
  const flush = (notify = true): void => {
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = null;
    for (const [seq, held] of pending) {
      const item = items[seq];
      if (item?.kind === "assistant") applyAssistant(item, held.message, held.phase === "end");
    }
    pending.clear();
    for (const [id, held] of pendingTools) {
      const found = tools.get(id);
      if (!found) continue;
      const result = cap(contentText(held.content), MAX_WEBVIEW_RESULT_BYTES);
      found.block.state = held.type === "done" ? { type: "done", result, error: held.error } : { type: "running", result };
      if (held.type === "done") {
        if (held.at !== undefined) found.block.ended = held.at;
        if (held.durationMs !== undefined) found.block.durationMs = held.durationMs;
      }
      publish(found.item);
    }
    pendingTools.clear();
    if (!notify) { dirty.clear(); return; }
    for (const seq of dirty) {
      const item = items[seq];
      if (!item) continue;
      const previous = sent.get(seq);
      if (item.kind === "assistant" && previous && item.blocks.length === previous.blocks.length) {
        const blocks = item.blocks.flatMap<{ index: number; suffix: string } | { index: number; block: Block }>((block, index) => {
          const old = previous.blocks[index];
          if (sameBlock(block, old)) return [];
          if (block.type !== "tool" && old.type === block.type && block.redacted === old.redacted && block.text.startsWith(old.text)) return [{ index, suffix: block.text.slice(old.text.length) }];
          return [{ index, block }];
        });
        if (blocks.length || item.final !== previous.final || item.stop !== previous.stop || item.error !== previous.error) {
          broadcast({ type: "patch", seq, blocks, final: item.final, stop: item.stop, error: item.error });
        }
      } else broadcast({ type: "item", item: wireItem(item) });
      if (item.kind === "assistant" && !item.final) sent.set(seq, { ...item, blocks: item.blocks.map((block) => ({ ...block })) });
      else sent.delete(seq);
    }
    dirty.clear();
  };
  const applyMessage = (message: AgentMessage, phase: "start" | "update" | "end" | "branch"): void => {
    const branch = phase === "branch";
    if (message.role === "toolResult") {
      if (phase === "end" || branch) {
        pendingTools.set(message.toolCallId, { type: "done", content: message.content, error: message.isError, ...(branch ? { at: message.timestamp } : {}) });
        if (!branch) flush();
      }
      return;
    }
    if (message.role === "assistant") {
      let item = !branch && assistant !== undefined ? items[assistant] : undefined;
      if (phase === "start" || branch || item?.kind !== "assistant") {
        item = { seq: items.length, at: message.timestamp, get final() { return final(this); }, kind: "assistant", blocks: [], stop: "", error: "", lifecycle: "streaming" };
        items.push(item);
        if (!branch) assistant = item.seq;
      }
      if (item.kind !== "assistant") return;
      if (branch || phase === "start") {
        applyAssistant(item, message, branch);
        if (branch) for (const block of item.blocks) if (block.type === "tool") block.started ??= message.timestamp;
      } else pending.set(item.seq, { message, phase });
      if (phase === "end") assistant = undefined;
      if (!branch) { if (phase === "update") schedule(); else flush(); }
      return;
    }
    if (phase !== "end" && !branch) return;
    const seq = items.length;
    let item: Item;
    switch (message.role) {
      case "user": item = { seq, at: message.timestamp, final: true, kind: "user", text: contentText(message.content), images: typeof message.content === "string" ? 0 : message.content.filter(b => b.type === "image").length }; break;
      case "custom":
        if (!message.display) return;
        item = { seq, at: message.timestamp, final: true, kind: "notice", customType: message.customType, from: message.details && typeof message.details === "object" && "from" in message.details && typeof message.details.from === "string" ? message.details.from : "", text: contentText(message.content) }; break;
      case "bashExecution": item = { seq, at: message.timestamp, final: true, kind: "bash", command: message.command, output: cap(message.output, MAX_WEBVIEW_RESULT_BYTES), ...(message.exitCode === undefined ? {} : { exit: message.exitCode }) }; break;
      case "branchSummary": case "compactionSummary": item = { seq, at: message.timestamp, final: true, kind: "summary", text: message.summary }; break;
      default: return;
    }
    items.push(item);
    if (!branch) { publish(item); flush(); }
  };
  const rebuild = (messages: readonly AgentMessage[] = []): void => {
    epoch = mintId();
    items = [];
    assistant = undefined;
    sent.clear();
    dirty.clear();
    pending.clear();
    pendingTools.clear();
    tools.clear();
    for (const message of messages) applyMessage(message, "branch");
    const responses = [...subscribers];
    subscribers.clear();
    flush(false);
    for (const item of items) if (item.kind === "assistant") notRun(item);
    sent.clear();
    const record = reset();
    for (const req of responses) { subscribers.add(req); body(req, record, true); }
  };

  const message: (message: AgentMessage, phase: "start" | "update" | "end") => void = applyMessage;
  const state = (record: object): void => { currentState = { ...record, type: "state" }; broadcast(currentState); };
  const toolRunning = (id: string, at: number): void => {
    flush();
    const found = tools.get(id);
    if (found) { found.block.started = at; found.block.state = { type: "running" }; publish(found.item); flush(); }
  };
  const toolPartial = (id: string, content: Content): void => {
    pendingTools.set(id, { type: "running", content }); schedule();
  };
  const toolDone = (id: string, content: Content, error: boolean, at: number, durationMs?: number): void => {
    pendingTools.set(id, { type: "done", content, error, at, durationMs }); flush();
  };
  const close = (): void => {
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = null;
    for (const response of subscribers) response.end();
    subscribers.clear();
  };
  const handle = (request: IncomingMessage, req: ServerResponse): boolean => {
    const url = new URL(request.url ?? "/", "http://ko");
    if (request.method === "GET" && url.pathname === "/items") {
      const before = Number(url.searchParams.get("before"));
      if (!Number.isSafeInteger(before) || before < 0) respond(req, 400, "{}");
      else respond(req, 200, '{"epoch":' + JSON.stringify(epoch) + ',' + window(before) + '}');
    } else if (request.method === "GET" && url.pathname === "/events") {
      req.once("close", () => subscribers.delete(req));
      flush();
      req.writeHead(200, { "Content-Type": "application/x-ndjson" });
      if (url.searchParams.get("epoch") === epoch) {
        const after = Number(url.searchParams.get("after") ?? -1);
        if (!Number.isSafeInteger(after) || after < -1) { body(req, ""); return true; }
        for (const item of items.slice(after + 1)) {
          body(req, JSON.stringify({ type: "item", item }) + "\n", true);
          if (req.writableEnded || req.destroyed) break;
        }
      } else body(req, reset(), true);
      if (req.writableEnded || req.destroyed) return true;
      subscribers.add(req);
      broadcast(currentState);
    } else return false;
    return true;
  };
  return { message, rebuild, toolRunning, toolPartial, toolDone, state, send: broadcast, handle, close };
}
