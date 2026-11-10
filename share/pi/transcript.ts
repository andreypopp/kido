import type { IncomingMessage, ServerResponse, OutgoingHttpHeaders } from "node:http";
import { createHash } from "node:crypto";
import { constants, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, basename } from "node:path";
import { open } from "node:fs/promises";
import { imageInfo, imageExtensions } from "./image.ts";
import { pathArg, isRelation, isAgentFailure } from "./records.ts";
import { promptText } from "../koa/prompt.ts";
import type { Text, Block, Item, Assistant, WireItem, State, PageRecord, CompletionQuery, ImageRef, Attachment, AgentRef, AgentCall, AgentOutcome, JobRef, JobEnd, Inbound, AgentDetails, NoticeDetails, StreamDetails } from "./records.ts";
import { mintId, contentText, utf8Prefix, isRecord, type Content } from "./text.ts";
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

const sameText = (a: Text | undefined, b: Text | undefined): boolean => a?.text === b?.text && a?.cut === b?.cut;
const sameTiming = (a: Block, b: Block): boolean => a.started === b.started && a.ended === b.ended;

function cap(text: string, limit: number): Text {
  const bytes = Buffer.byteLength(text);
  const prefix = utf8Prefix(text, limit);
  return { text: prefix, cut: bytes - Buffer.byteLength(prefix) };
}

function agentRef(value: unknown): AgentRef | undefined {
  if (!isRecord(value) || typeof value.name !== 'string' || !value.name || value.session !== undefined && typeof value.session !== 'string' || value.pane !== undefined && typeof value.pane !== 'string') return;
  return { name: value.name, ...(typeof value.session === 'string' ? { session: value.session } : {}), ...(typeof value.pane === 'string' ? { pane: value.pane } : {}) };
}
function jobRef(value: unknown): JobRef | undefined {
  if (!isRecord(value) || typeof value.id !== 'string' || !value.id || typeof value.name !== 'string' || typeof value.log !== 'string' || typeof value.service !== 'boolean') return;
  return { id: value.id, name: value.name, log: value.log, service: value.service };
}
function outcome(value: unknown): AgentOutcome | undefined {
  if (!isRecord(value)) return;
  if (value.ok === true) return { ok: true };
  if (value.ok === false && typeof value.message === 'string' && isAgentFailure(value.failure)) return { ok: false, failure: value.failure, message: cap(value.message, MAX_WEBVIEW_RESULT_BYTES).text };
}
function jobEnd(value: unknown): JobEnd | undefined {
  if (!isRecord(value)) return;
  switch (value.type) {
    case 'exit': return typeof value.code === 'number' && Number.isInteger(value.code) ? { type: 'exit', code: value.code } : undefined;
    case 'signal': return typeof value.signal === 'string' ? { type: 'signal', signal: value.signal } : undefined;
    case 'failed': return typeof value.message === 'string' ? { type: 'failed', message: cap(value.message, MAX_WEBVIEW_RESULT_BYTES).text } : undefined;
    case 'stopped': return { type: 'stopped' };
    case 'timeout': return typeof value.seconds === 'number' && Number.isFinite(value.seconds) && value.seconds >= 0 ? { type: 'timeout', seconds: value.seconds } : undefined;
    default: return;
  }
}
function inbound(value: unknown): Inbound | undefined {
  if (!isRecord(value) || value.relation !== undefined && !isRelation(value.relation)) return;
  const related = isRelation(value.relation) ? { relation: value.relation } : {};
  switch (value.form) {
    case 'message': return isRelation(value.relation) && (value.runtime === undefined || typeof value.runtime === 'string') ? { form: 'message', relation: value.relation, ...(typeof value.runtime === 'string' ? { runtime: value.runtime } : {}) } : undefined;
    case 'steer': return { form: 'steer', ...related };
    case 'report': return { form: 'report', ...related };
    case 'notice': return { form: 'notice' };
    case 'ended': return typeof value.reported === 'boolean' ? { form: 'ended', reported: value.reported, ...related } : undefined;
    default: return;
  }
}
function agentDetails(value: unknown): AgentDetails | undefined {
  if (!isRecord(value) || typeof value.body !== 'string') return;
  const agent = agentRef(value.agent), form = inbound(value.inbound);
  return agent && form ? { agent, body: value.body, inbound: form } : undefined;
}
function noticeDetails(value: unknown): Extract<NoticeDetails, { kind: 'job' }> | undefined {
  if (!isRecord(value)) return;
  const job = jobRef(value.job), end = isRecord(value.job) ? jobEnd(value.job.end) : undefined;
  return value.kind === 'job' && job && end && typeof value.tail === 'string' ? { kind: 'job', job: { ...job, end }, tail: value.tail } : undefined;
}
function streamDetails(value: unknown): StreamDetails | undefined {
  if (!isRecord(value)) return;
  const job = jobRef(value.job);
  return job && typeof value.batch === 'string' && typeof value.omitted === 'number' && Number.isSafeInteger(value.omitted) && value.omitted >= 0 && typeof value.cut === 'boolean' ? { job, batch: value.batch, omitted: value.omitted, cut: value.cut } : undefined;
}
function sameJob(a: JobRef | undefined, b: JobRef | undefined): boolean {
  return a === b || !!a && !!b && a.id === b.id && a.name === b.name && a.service === b.service && a.log === b.log;
}

function agentCall(name: string, value: unknown): AgentCall | undefined {
  if (!isRecord(value)) return;
  if (name === 'spawn_agent' && typeof value.name === 'string') return { direction: 'out', to: { name: value.name }, text: cap(typeof value.task === 'string' ? value.task : '', MAX_WEBVIEW_RESULT_BYTES), call: { tool: 'spawn', fork: value.fork === true, ...(typeof value.model === 'string' ? { model: value.model } : {}), ...(typeof value.runtime === 'string' ? { runtime: value.runtime } : {}) } };
  if (name !== 'message_agent' || typeof value.to !== 'string' || typeof value.message !== 'string') return;
  const mode = value.mode ?? 'message';
  if (mode !== 'message' && mode !== 'steer' && mode !== 'interrupt-and-steer') return;
  return { direction: 'out', to: { name: value.to.replace(/^@/, '') }, text: cap(value.message, MAX_WEBVIEW_RESULT_BYTES), call: { tool: 'message', mode } };
}
function sameAgent(a: AgentCall | undefined, b: AgentCall | undefined): boolean {
  return a === b || !!a && !!b && a.to.name === b.to.name && a.to.session === b.to.session && a.to.pane === b.to.pane && sameText(a.text, b.text)
    && (a.call.tool === 'spawn' && b.call.tool === 'spawn' ? a.call.model === b.call.model && a.call.fork === b.call.fork && a.call.runtime === b.call.runtime : a.call.tool === 'message' && b.call.tool === 'message' && a.call.mode === b.call.mode)
    && (a.outcome === b.outcome || !!a.outcome && !!b.outcome && a.outcome.ok === b.outcome.ok && (a.outcome.ok || !b.outcome.ok && a.outcome.failure === b.outcome.failure && a.outcome.message === b.outcome.message));
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

export function fileDisposition(name: string): string {
  const file = basename(name);
  return 'inline; filename="' + file.replace(/[^\x20-\x21\x23-\x5b\x5d-\x7e]/g, '_') + '"; filename*=UTF-8\'\'' + encodeURIComponent(file);
}

async function serveFile(response: ServerResponse, path: string, headers: OutgoingHttpHeaders): Promise<void> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    if (!stat.isFile()) throw Error("not readable");
    response.writeHead(200, { ...headers, "Content-Length": stat.size });
    const stream = file.createReadStream();
    stream.once("error", () => response.destroy()); response.once("close", () => stream.destroy()); stream.pipe(response);
  } catch (error) { await file.close(); throw error; }
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
  const pendingTools = new Map<string, { type: "running"; content: Content } | { type: "done"; content: Content; error: boolean; at?: number; durationMs?: number; structuredContent?: unknown; details?: unknown }>();
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
      const card = existing && existing.state.type !== 'pending' ? existing.agent : agentCall(block.name, block.arguments);
      if (card) next.agent = sameAgent(existing?.agent, card) ? existing?.agent : card;
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
  const sameBlock = (a: Block, b: Block): boolean => {
    if (a.type !== b.type) return false;
    if (a.type !== "tool" && b.type !== "tool") return a.text === b.text && a.redacted === b.redacted && (a.type !== "thinking" || sameTiming(a, b));
    if (a.type !== "tool" || b.type !== "tool") return false;
    const left = "result" in a.state ? a.state.result?.images : undefined, right = "result" in b.state ? b.state.result?.images : undefined;
    return sameTiming(a, b) && a.durationMs === b.durationMs && a.exit === b.exit && a.id === b.id && a.name === b.name && sameAgent(a.agent, b.agent) && sameJob(a.job, b.job) && sameText(a.args, b.args) && a.state.type === b.state.type
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
      if (held.type === 'done') {
        const details = isRecord(held.details) ? held.details : undefined;
        const done = outcome(details?.outcome), card = found.block.agent;
        if (card && done) {
          const to = card.call.tool === 'spawn' ? agentRef(details) ?? card.to : { ...card.to, ...(typeof details?.to === 'string' ? { name: details.to } : {}) };
          found.block.agent = { ...card, to, text: !done.ok && (card.call.tool === 'spawn' || !card.text.text) ? cap(done.message, MAX_WEBVIEW_RESULT_BYTES) : card.text, outcome: done };
        } else if (card) delete found.block.agent;
        if (found.block.name === 'async_bash' && details) { const job = jobRef(details.job); if (job) found.block.job = job; }
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
  const applyMessage = (message: AgentMessage, phase: "start" | "update" | "end" | "branch", ended?: number, attachments: Attachment[] = []): void => {
    const branch = phase === "branch";
    if (message.role === "toolResult") {
      if (phase === "end" || branch) {
        pendingTools.set(message.toolCallId, { type: "done", content: message.content, error: message.isError, details: message.details, ...(branch ? { at: message.timestamp } : {}) });
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
      case "user": {
        const files = phase === "branch" ? [] : attachments;
        item = { seq, at: message.timestamp, final: true, kind: "user", text: promptText(contentText(message.content), files), images: saveImages(String(seq), message.content), attachments: files }; break;
      }
      case 'custom': {
        if (!message.display) return;
        const details = isRecord(message.details) ? message.details : undefined;
        const agent = agentDetails(details), notice = agent ? undefined : noticeDetails(details), stream = agent || notice ? undefined : streamDetails(details);
        if (agent) item = { seq, at: message.timestamp, final: true, kind: 'agent', direction: 'in', from: agent.agent, text: cap(agent.body, MAX_WEBVIEW_RESULT_BYTES), inbound: agent.inbound };
        else if (notice) { const { end, ...job } = notice.job; item = { seq, at: message.timestamp, final: true, kind: 'job', job, event: { type: 'ended', end, tail: cap(notice.tail, MAX_WEBVIEW_RESULT_BYTES) } }; }
        else if (stream) item = { seq, at: message.timestamp, final: true, kind: 'job', job: stream.job, event: { type: 'stream', batch: cap(stream.batch, MAX_WEBVIEW_RESULT_BYTES), omitted: stream.omitted, cut: stream.cut } };
        else item = { seq, at: message.timestamp, final: true, kind: 'notice', customType: message.customType, from: typeof details?.from === 'string' ? details.from : '', text: contentText(message.content) };
        break;
      }
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

  const message: (message: AgentMessage, phase: "start" | "update" | "end", ended?: number, attachments?: Attachment[]) => void = applyMessage;
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
  const toolDone = (id: string, content: Content, error: boolean, at: number, durationMs?: number, structuredContent?: unknown, details?: unknown): void => {
    pendingTools.set(id, { type: "done", content, error, at, durationMs, structuredContent, details }); flush();
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
      void serveFile(req, image.path, { "Content-Type": image.ref.mimeType, "Content-Disposition": fileDisposition(image.ref.id + "." + (imageExtensions[image.ref.mimeType] ?? "bin")) }).catch(error => {
        if (req.headersSent) req.destroy();
        else respond(req, error instanceof Error && "code" in error && error.code === "ENOENT" ? 410 : 500, "{}");
      });
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
  const stepPath = (seq: number, index: number): string | undefined => {
    const item = items[seq], block = item?.kind === 'assistant' ? item.blocks[index] : undefined;
    return pathArg(block);
  };
  return { stepPath, message, thinking, rebuild, toolRunning, toolPartial, toolDone, state, send: (record: Extract<PageRecord, { type: "notify" }>) => broadcast(record), handle, close, get metrics() { return counters && { ...counters, subscribers: subscribers.size }; } };
}
