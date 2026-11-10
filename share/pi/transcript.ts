import type { IncomingMessage, ServerResponse } from "node:http";
import { createHash } from "node:crypto";
import { createReadStream, mkdirSync, openSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { imageInfo } from "./image.ts";
import type { Text, Block, Item, Assistant, WireItem, State, PageRecord, PromptMode, CompletionQuery, ImageRef } from "../koa/records.ts";
import { mintId, contentText, utf8Prefix, type Content } from "./text.ts";
import type { AgentMessage, ThinkingLevel } from "@earendil-works/pi-agent-core";
import type { RpcExtensionUIRequest, RpcExtensionUIResponse } from "@earendil-works/pi-coding-agent";

const MAX_WEBVIEW_WINDOW_ITEMS = 40;
const MAX_WEBVIEW_WINDOW_BYTES = 256 * 1024;
const MAX_WEBVIEW_ARGS_BYTES = 4 * 1024;
const MAX_WEBVIEW_RESULT_BYTES = 16 * 1024;
const MAX_WEBVIEW_OUTPUT_BYTES = 1 << 20;

export async function readBody(request: IncomingMessage, limit: number): Promise<Buffer | undefined> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size <= limit) chunks.push(chunk);
  }
  return size <= limit ? Buffer.concat(chunks) : undefined;
}

export function promptBody(value: unknown): { text: string; mode: PromptMode | "steer" } | { error: string } {
  if (value && typeof value === "object" && "text" in value && typeof value.text === "string" && value.text.trim() && "mode" in value && (value.mode === "prompt" || value.mode === "steer" || value.mode === "follow_up")) return { text: value.text, mode: value.mode };
  return { error: "A non-empty text and prompt, steer or follow_up mode are required" };
}

export function completeBody(value: unknown): CompletionQuery | { error: string } {
  return value && typeof value === "object" && "text" in value && typeof value.text === "string" && "pos" in value && typeof value.pos === "number" && Number.isSafeInteger(value.pos) && value.pos >= 0 && value.pos <= value.text.length ? { text: value.text, pos: value.pos } : { error: "Completion requires text and a cursor offset in that text" };
}

export function idBody(value: unknown): { id: string } | { error: string } {
  return value && typeof value === "object" && "id" in value && typeof value.id === "string" ? { id: value.id } : { error: "An id is required" };
}

export function modelBody(value: unknown): { provider: string; modelId: string } | { error: string } {
  return value && typeof value === "object" && "provider" in value && typeof value.provider === "string" && "modelId" in value && typeof value.modelId === "string" ? { provider: value.provider, modelId: value.modelId } : { error: "A provider and modelId are required" };
}

export function thinkingBody(value: unknown, levels: readonly ThinkingLevel[]): { level: ThinkingLevel } | { error: string } {
  const available = (level: unknown): level is ThinkingLevel => levels.some(value => value === level);
  return value && typeof value === "object" && "level" in value && available(value.level) ? { level: value.level } : { error: "An available thinking level is required" };
}

export function dialogBody(value: unknown, dialog: Extract<RpcExtensionUIRequest, { method: "select" | "confirm" | "input" | "editor" }>): RpcExtensionUIResponse | { error: string } {
  if (value && typeof value === "object") {
    if ("cancelled" in value && value.cancelled === true) return { type: "extension_ui_response", id: dialog.id, cancelled: true };
    if (dialog.method === "confirm" && "confirmed" in value && typeof value.confirmed === "boolean") return { type: "extension_ui_response", id: dialog.id, confirmed: value.confirmed };
    if (dialog.method !== "confirm" && "value" in value && typeof value.value === "string" && (dialog.method !== "select" || dialog.options.includes(value.value))) return { type: "extension_ui_response", id: dialog.id, value: value.value };
  }
  return { error: "A valid dialog answer is required" };
}

const sameTiming = (a: Block, b: Block): boolean => a.started === b.started && a.ended === b.ended;

function cap(text: string, limit: number): Text {
  const bytes = Buffer.byteLength(text);
  const prefix = utf8Prefix(text, limit);
  return { text: prefix, cut: bytes - Buffer.byteLength(prefix) };
}

function wireItem(item: Item): WireItem {
  if (item.kind !== "assistant") return item;
  const { lifecycle, ...wire } = item;
  return wire;
}

function final(item: Assistant): boolean {
  return item.lifecycle === "ended" && item.blocks.every((b) => b.type !== "tool" || b.state.type === "done" || b.state.type === "not_run");
}

export function respond(response: ServerResponse, status: number, text: string, contentType = "application/json"): void {
  response.writeHead(status, { "Content-Type": contentType });
  response.end(text);
}

function notRun(item: Assistant): void {
  for (const block of item.blocks) if (block.type === "tool" && block.state.type === "pending") block.state = { type: "not_run" };
}

export function transcript({ dir, flushMs, metrics = false }: { dir: string; flushMs: number; metrics?: boolean }) {
  const imageDir = join(dir, "images");
  mkdirSync(imageDir, { recursive: true, mode: 0o700 });
  const images = new Map<string, { ref: ImageRef; path: string; digest: string }>();
  const saveImages = (prefix: string, content: Content, previous: ImageRef[] = []): ImageRef[] => {
    const refs: ImageRef[] = [];
    if (typeof content !== "string") for (const block of content) {
      if (block.type !== "image") continue;
      const bytes = Buffer.from(block.data, "base64"), id = prefix + "." + refs.length;
      const digest = createHash("sha1").update(bytes).digest("hex");
      const old = images.get(id);
      if (old?.digest === digest) { refs.push(old.ref); continue; }
      const path = join(imageDir, id);
      writeFileSync(path + ".tmp", bytes, { mode: 0o600 }); renameSync(path + ".tmp", path);
      const ref: ImageRef = { id, revision: old ? old.ref.revision + 1 : 0, bytes: bytes.length, ...(imageInfo(bytes) ?? { mimeType: "application/octet-stream" }) };
      images.set(id, { ref, path, digest }); refs.push(ref);
    }
    for (const ref of previous.slice(refs.length)) { const saved = images.get(ref.id); if (saved) rmSync(saved.path, { force: true }); images.delete(ref.id); }
    return refs;
  };
  const counters = metrics ? { flushes: 0, bytes: 0, highWater: 0, opens: 0, resets: 0, cursors: 0, caps: 0 } : undefined;
  let currentState: Extract<PageRecord, { type: "state" }> | undefined;
  let epoch = mintId();
  let items: Item[] = [];
  let assistant: number | undefined;
  const subscribers = new Set<ServerResponse>();
  const tools = new Map<string, { item: Assistant; block: Extract<Block, { type: "tool" }> }>();
  const dirty = new Set<number>();
  const sent = new Map<number, Assistant>();
  const pending = new Map<number, { message: Extract<AgentMessage, { role: "assistant" }>; phase: "update" | "end" }>();
  const pendingTools = new Map<string, { type: "running"; content: Content } | { type: "done"; content: Content; error: boolean; at?: number; durationMs?: number; structuredContent?: unknown }>();
  let flushTimer: NodeJS.Timeout | null = null;

  const frame = (json: string): string => "data: " + json + "\n\n";
  const body = (req: ServerResponse, text: string, more = false): void => {
    if (req.destroyed || req.writableEnded) return;
    if (text) {
      req.write(text);
      if (counters) { counters.bytes += Buffer.byteLength(text); counters.highWater = Math.max(counters.highWater, req.writableLength); }
    }
    if (!more || req.writableLength > MAX_WEBVIEW_OUTPUT_BYTES) {
      if (counters && req.writableLength > MAX_WEBVIEW_OUTPUT_BYTES) counters.caps++;
      req.end();
      subscribers.delete(req);
    }
  };
  const broadcast = (record: PageRecord): void => {
    const line = frame(JSON.stringify(record));
    for (const req of subscribers) body(req, line, true);
  };
  const flushRecord = (bytes: number): Extract<PageRecord, { type: "flush" }> => ({ type: "flush", t: Date.now(), bytes });
  const window = (before: number): string => {
    let start = Math.min(before, items.length);
    const strings: string[] = [];
    let bytes = 0;
    while (start > 0 && strings.length < MAX_WEBVIEW_WINDOW_ITEMS) {
      const item: WireItem = wireItem(items[start - 1]);
      const json = JSON.stringify(item);
      const size = Buffer.byteLength(json);
      if (strings.length && bytes + size > MAX_WEBVIEW_WINDOW_BYTES) break;
      bytes += size;
      strings.push(json);
      start--;
    }
    return '"items":[' + strings.reverse().join(",") + '],"more":' + (start > 0);
  };
  const reset = (): string => frame('{"type":"reset","epoch":' + JSON.stringify(epoch) + ',' + window(items.length) + '}');
  const schedule = (): void => {
    if (!flushTimer) flushTimer = setTimeout(flush, flushMs);
  };
  const publish = (item: Item): void => { dirty.add(item.seq); };
  const applyAssistant = (item: Assistant, message: Extract<AgentMessage, { role: "assistant" }>, ended: boolean): void => {
    item.blocks = message.content.flatMap((block, index): Block[] => {
      if (block.type === "text") return [{ type: "text", text: block.text }];
      if (block.type === "thinking") {
        const previous = item.blocks[index];
        return [{ type: "thinking", text: block.thinking, redacted: !!block.redacted, ...(previous?.type === "thinking" ? { started: previous.started, ended: previous.ended } : {}) }];
      }
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
    if (a.type !== "tool" && b.type !== "tool") return a.text === b.text && a.redacted === b.redacted && (a.type !== "thinking" || sameTiming(a, b));
    if (a.type !== "tool" || b.type !== "tool") return false;
    const left = "result" in a.state ? a.state.result?.images : undefined, right = "result" in b.state ? b.state.result?.images : undefined;
    return sameTiming(a, b) && a.durationMs === b.durationMs && a.exit === b.exit && a.id === b.id && a.name === b.name && sameText(a.args, b.args) && a.state.type === b.state.type
      && sameText("result" in a.state ? a.state.result : undefined, "result" in b.state ? b.state.result : undefined)
      && left?.length === right?.length && (left?.every((ref, index) => ref === right?.[index]) ?? true)
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
      let text = contentText(held.content);
      if (held.type === "done" && found.block.name === "bash") {
        const footer = text.match(/\n*Command exited with code (\d+)\s*$/);
        const structured = held.structuredContent;
        const code = structured && typeof structured === "object" && "exit_code" in structured ? structured.exit_code : footer ? Number(footer[1]) : undefined;
        if (typeof code === "number" && Number.isInteger(code) && code >= 0) {
          found.block.exit = code;
          if (footer && code !== 0 && code === Number(footer[1])) text = text.slice(0, footer.index);
        }
      }
      const previous = "result" in found.block.state ? found.block.state.result?.images : undefined;
      const result = { ...cap(text, MAX_WEBVIEW_RESULT_BYTES), images: saveImages(found.item.seq + "." + found.item.blocks.indexOf(found.block), held.content, previous) };
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
          if (block.type !== "tool" && old.type === block.type && block.redacted === old.redacted && (block.type !== "thinking" || sameTiming(block, old)) && block.text.startsWith(old.text)) return [{ index, suffix: block.text.slice(old.text.length) }];
          return [{ index, block }];
        });
        if (blocks.length || item.final !== previous.final || item.stop !== previous.stop || item.error !== previous.error || item.ended !== previous.ended) {
          broadcast({ type: "patch", seq, blocks, final: item.final, stop: item.stop, error: item.error, ended: item.ended });
        }
      } else broadcast({ type: "item", item: wireItem(item) });
      if (item.kind === "assistant" && !item.final) sent.set(seq, { ...item, blocks: item.blocks.map((block) => ({ ...block })) });
      else sent.delete(seq);
    }
    if (counters && dirty.size) { counters.flushes++; broadcast(flushRecord(counters.bytes)); }
    dirty.clear();
  };
  const applyMessage = (message: AgentMessage, phase: "start" | "update" | "end" | "branch", ended?: number): void => {
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
      if (phase === "end") { item.ended = ended; assistant = undefined; }
      if (!branch) { if (phase === "update") schedule(); else flush(); }
      return;
    }
    if (phase !== "end" && !branch) return;
    const seq = items.length;
    let item: Item;
    switch (message.role) {
      case "user": item = { seq, at: message.timestamp, final: true, kind: "user", text: contentText(message.content), images: saveImages(String(seq), message.content) }; break;
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
    images.clear(); rmSync(imageDir, { recursive: true, force: true }); mkdirSync(imageDir, { mode: 0o700 });
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

  const message: (message: AgentMessage, phase: "start" | "update" | "end", ended?: number) => void = applyMessage;
  const thinking = (index: number, edge: "started" | "ended", at: number): void => {
    flush();
    const item = assistant === undefined ? undefined : items[assistant];
    const block = item?.kind === "assistant" ? item.blocks[index] : undefined;
    if (block?.type === "thinking" && item) { block[edge] = at; publish(item); schedule(); }
  };
  const state = (record: State): void => { currentState = { ...record, type: "state" }; broadcast(currentState); };
  const toolRunning = (id: string, at: number): void => {
    flush();
    const found = tools.get(id);
    if (found) { found.block.started = at; found.block.state = { type: "running" }; publish(found.item); flush(); }
  };
  const toolPartial = (id: string, content: Content): void => {
    pendingTools.set(id, { type: "running", content }); schedule();
  };
  const toolDone = (id: string, content: Content, error: boolean, at: number, durationMs?: number, structuredContent?: unknown): void => {
    pendingTools.set(id, { type: "done", content, error, at, durationMs, structuredContent }); flush();
  };
  const close = (): void => {
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = null;
    for (const response of subscribers) response.end();
    subscribers.clear();
  };
  const handle = (request: IncomingMessage, req: ServerResponse): boolean => {
    const url = new URL(request.url ?? "/", "http://ko");
    if (request.method === "GET" && url.pathname.startsWith("/images/")) {
      req.setHeader("Cache-Control", "no-store");
      req.setHeader("X-Content-Type-Options", "nosniff");
      req.setHeader("Content-Security-Policy", "sandbox; default-src 'none'");
      const image = images.get(url.pathname.slice(8));
      if (!image) { respond(req, 404, "{}"); return true; }
      req.setHeader("Content-Type", image.ref.mimeType);
      let fd: number;
      try { fd = openSync(image.path, "r"); }
      catch (error) { respond(req, error instanceof Error && "code" in error && error.code === "ENOENT" ? 410 : 500, "{}"); return true; }
      req.writeHead(200, { "Content-Length": image.ref.bytes });
      const stream = createReadStream(image.path, { fd });
      req.once("close", () => stream.destroy());
      stream.once("error", () => req.destroy()); stream.pipe(req);
    } else if (request.method === "GET" && url.pathname === "/items") {
      const before = Number(url.searchParams.get("before"));
      if (!Number.isSafeInteger(before) || before < 0) respond(req, 400, "{}");
      else respond(req, 200, '{"epoch":' + JSON.stringify(epoch) + ',' + window(before) + '}');
    } else if (request.method === "GET" && url.pathname === "/events") {
      if (counters) counters.opens++;
      req.once("close", () => subscribers.delete(req));
      flush();
      req.writeHead(200, { "Content-Type": "text/event-stream" });
      if (url.searchParams.get("epoch") === epoch) {
        if (counters) counters.cursors++;
        const after = Number(url.searchParams.get("after") ?? -1);
        if (!Number.isSafeInteger(after) || after < -1) { body(req, ""); return true; }
        for (const item of items.slice(after + 1)) {
          body(req, frame(JSON.stringify({ type: "item", item })), true);
          if (req.writableEnded || req.destroyed) break;
        }
      } else { if (counters) counters.resets++; body(req, reset(), true); }
      if (req.writableEnded || req.destroyed) return true;
      subscribers.add(req);
      if (counters) body(req, frame(JSON.stringify(flushRecord(counters.bytes))), true);
      if (currentState) broadcast(currentState);
    } else return false;
    return true;
  };
  return { message, thinking, rebuild, toolRunning, toolPartial, toolDone, state, send: (record: Extract<PageRecord, { type: "notify" }>) => broadcast(record), handle, close, get metrics() { return counters && { ...counters, subscribers: subscribers.size }; } };
}
