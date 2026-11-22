import { topicContext, quotedTopic } from './koa-classify.ts';
import type { QueuedPrompt } from './koa-records.ts';
import { cleanLine } from './text.ts';
import type { IncomingMessage, ServerResponse } from "node:http";
import { later } from "./koa-timer.ts";
import { respond, serveFile } from "./koa-http.ts";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { imageInfo, imageExtensions } from "./koa-image.ts";
import { pathArg, type Annotation } from "./koa-records.ts";
import { isRelation, isAgentFailure, parseTopicName, messageTopic, topicArchive, type TopicName } from "./records.ts";
import { decodePrompt } from "./prompt.ts";
import { topicList, type TopicList } from "./topic-list.ts";
import type { Topic, Text, Block, Item, Assistant, WireItem, State, PageRecord, ImageRef, Attachment, AgentCall, NotifyLevel, CommandResult, BashResult } from "./koa-records.ts";
import { send, forget, follow, take, expire, type ViewAddress } from "./koa-feed.ts";
import type { WireJob } from "./koa-records.ts";
import type { JobPlace, AgentRef, AgentOutcome, JobRef, JobEnd, Inbound, AgentDetails, NoticeDetails, StreamDetails } from "./records.ts";
import { mintId, contentText, utf8Prefix, isRecord, errorText, topicSections, type Content } from "./text.ts";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

function decodeAnnotation(entry: SessionEntry): { at: number; reply: { at: number; block: number; length: number }; annotations: unknown[] } | undefined {
  if (entry.type !== 'custom' || entry.customType !== 'reply-annotations' || !isRecord(entry.data)) return;
  const { reply, annotations } = entry.data, at = Date.parse(entry.timestamp);
  if (!Number.isFinite(at) || !isRecord(reply) || typeof reply.at !== 'number' || !Number.isFinite(reply.at) || typeof reply.block !== 'number' || !Number.isSafeInteger(reply.block) || reply.block < 0 || typeof reply.length !== 'number' || !Number.isSafeInteger(reply.length) || reply.length < 0 || !Array.isArray(annotations)) return;
  return { at, reply: { at: reply.at, block: reply.block, length: reply.length }, annotations };
}

const MAX_WEBVIEW_WINDOW_MESSAGES = 100;
const MAX_WEBVIEW_ARGS_BYTES = 4 * 1024;
const MAX_WEBVIEW_RESULT_BYTES = 16 * 1024;

const sameText = (a: Text | undefined, b: Text | undefined): boolean => a?.text === b?.text && a?.cut === b?.cut;
const sameTiming = (a: Block, b: Block): boolean => a.started === b.started && a.ended === b.ended;

export function appendBashOutput(output: Text, delta: string): Text {
  const bytes = Buffer.from(output.text + delta);
  let start = Math.max(0, bytes.length - MAX_WEBVIEW_RESULT_BYTES);
  while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start++;
  return { text: bytes.toString('utf8', start), cut: output.cut + start };
}

export function bashResult(value: { output: string; exitCode?: number; cancelled: boolean; truncated: boolean; fullOutputPath?: string }): BashResult {
  return { output: cap(value.output, MAX_WEBVIEW_RESULT_BYTES), cancelled: value.cancelled, truncated: value.truncated, ...(value.exitCode === undefined ? {} : { exit: value.exitCode }), ...(value.fullOutputPath === undefined ? {} : { fullOutputPath: value.fullOutputPath }) };
}

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
  const where = value.place;
  const place: JobPlace | undefined = !isRecord(where) ? undefined : where.type === 'runtime' && typeof where.name === 'string' ? { type: 'runtime', name: where.name } : where.type === 'remote' && typeof where.host === 'string' ? { type: 'remote', host: where.host } : where.type === 'mac' || where.type === 'machine' ? { type: where.type } : undefined;
  if (typeof value.command !== 'string' || typeof value.startedAt !== 'number' || !Number.isFinite(value.startedAt) || !place) return;
  return { id: value.id, name: value.name, log: value.log, service: value.service, command: value.command, startedAt: value.startedAt, place };
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
  return a === b || !!a && !!b && a.id === b.id && a.name === b.name && a.service === b.service && a.log === b.log && a.command === b.command && a.startedAt === b.startedAt;
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

const logged = (job: JobRef, seen: Map<string, boolean>): WireJob => {
  let present = seen.get(job.log);
  if (present === undefined) { present = existsSync(job.log); seen.set(job.log, present); }
  return present ? job : { ...job, gone: true };
};
function wireItem(item: Item, seen = new Map<string, boolean>()): WireItem {
  if (item.kind === "job") return { ...item, job: logged(item.job, seen) };
  if (item.kind !== "assistant") return item;
  const { lifecycle, ...wire } = item;
  return { ...wire, blocks: wire.blocks.map(block => block.type === "tool" && block.job ? { ...block, job: logged(block.job, seen) } : block) };
}

function final(item: Assistant): boolean {
  return item.lifecycle === "ended" && item.blocks.every((b) => b.type !== "tool" || b.state.type === "done" || b.state.type === "not_run");
}

function notRun(item: Assistant): void {
  for (const block of item.blocks) if (block.type === "tool" && block.state.type === "pending") block.state = { type: "not_run" };
}

export function transcript({ dir, flushMs, metrics = false, kind = 'subagent', changed, branch, sessionEntryToContextMessages }: { dir: string; flushMs: number; metrics?: boolean; kind?: 'root' | 'subagent'; changed?(): void; branch(): readonly SessionEntry[]; sessionEntryToContextMessages: typeof import('@earendil-works/pi-coding-agent').sessionEntryToContextMessages }) {
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
  let session: { type: 'unbound' } | { type: 'bound'; id: string | undefined } = { type: 'unbound' };
  let assistant: number | undefined;
  let subscribers = new Set<ServerResponse>();
  const tools = new Map<string, { item: Assistant; block: Extract<Block, { type: "tool" }> }>();
  const dirty = new Set<number>();
  const sent = new Map<number, Assistant>();
  const pending = new Map<number, { message: Extract<AgentMessage, { role: "assistant" }>; phase: "update" | "end" }>();
  const pendingTools = new Map<string, { type: "running"; content: Content } | { type: "done"; content: Content; error: boolean; at?: number; durationMs?: number; structuredContent?: unknown; details?: unknown }>();
  let flushTimer: NodeJS.Timeout | null = null;
  const sources = new Map<number, { seed?: TopicName; blocks: { source: number; start: number; end: number; length: number }[] }>();
  const labels = new Map<number, TopicName[]>();
  const messages = new Map<number, { message: AgentMessage; entryId?: string }>();
  let list: { key: string; value: TopicList } | undefined;
  const topics = (entries = branch()): TopicList => {
    const key = entries.length + ':' + (entries.at(-1)?.id ?? '');
    if (list?.key !== key) list = { key, value: topicList(entries) };
    return list.value;
  };
  const entryId = (seq: number, entries = branch()): string | undefined => {
    const source = messages.get(seq);
    if (!source) return;
    source.entryId ??= entries.find(entry => entry.type === 'message' && entry.message === source.message)?.id;
    return source.entryId;
  };
  const projection = () => {
    const entries = branch(), owner = topics(entries);
    const id = (seq: number) => entryId(seq, entries);
    const project = (item: Item): Item => {
      if (kind !== 'root') return item;
      const assignment = (topic: TopicName | undefined) => owner.assignment(id(item.seq), topic);
      if (item.kind === 'assistant') return { ...item, blocks: item.blocks.map(block => ({ ...block, topic: assignment(block.topic) })) };
      if (item.kind === 'user' || item.kind === 'agent' || item.kind === 'job') return { ...item, topic: assignment(item.topic) };
      if (item.kind === 'topics') return { ...item, topics: owner.overridden(id(item.target)) ? [] : [...new Set(item.topics.map(owner.resolve))] };
      return item;
    };
    const latest = items.findLast(item => item.kind === 'assistant');
    const live = latest && id(latest.seq) === undefined ? project(latest) : undefined;
    const names = [...new Set([...owner.names, ...(live?.kind === 'assistant' ? live.blocks.flatMap(block => block.topic ? [block.topic] : []) : [])])];
    return { owner, project, names, id, output: (item: Item, seen?: Map<string, boolean>) => wireItem(project(item), seen) };
  };
  const isTopicRecord = (entry: SessionEntry): boolean => {
    if (kind !== 'root' || entry.type !== 'custom') return false;
    if (entry.customType === 'koa.topic-move' || messageTopic(entry) || topicArchive(entry)) return true;
    return entry.customType === 'koa.topic';
  };
  let currentTopic: TopicName | undefined;
  let implicitUser: number | undefined;
  let replyNames: TopicName[] = [];
  let unlabelled: number[] = [];
  let delivery: { type: 'live' } | { type: 'replay'; labels: Map<number, { names: TopicName[]; at: number }> } = { type: 'live' };
  const emitLabel = (target: number, names: TopicName[], at: number): void => {
    const item: Item = { kind: 'topics', target, topics: [...names], seq: items.length, revision: 0, at, final: true };
    items.push(item); dirty.add(item.seq);
  };
  const flushLabels = (): void => {
    if (delivery.type !== 'replay') return;
    for (const [target, { names, at }] of delivery.labels) emitLabel(target, names, at);
    delivery.labels.clear();
  };
  const label = (target: number, names: TopicName[], at: number): void => {
    const previous = labels.get(target);
    if (previous?.length === names.length && previous.every((name, index) => name === names[index])) return;
    labels.set(target, [...names]);
    if (delivery.type === 'replay') delivery.labels.set(target, { names: [...names], at });
    else emitLabel(target, names, at);
  };
  const boundary = (topic: TopicName | undefined): void => {
    currentTopic = topic; implicitUser = undefined; replyNames = []; unlabelled = [];
  };

  const frame = (json: string): string => "data: " + json + "\n\n";
  const body = (req: ServerResponse, text: string, more = false): void => send(req, text, more, counters);
  const broadcast = (record: PageRecord): void => {
    const line = frame(JSON.stringify(record));
    for (const req of subscribers) body(req, line, true);
  };
  const flushRecord = (bytes: number, id: number): Extract<PageRecord, { type: "flush" }> => ({ type: "flush", id, t: Date.now(), bytes });
  const window = (before: number, topic?: TopicName): string => {
    const { owner, project, output, id } = projection();
    const counted = (item: WireItem, inferred?: TopicName): boolean => item.kind === 'user' || item.kind === 'assistant' && item.blocks.some(block => block.type === 'text' && block.text.trim() !== '' && (!topic || (block.topic ?? inferred) === topic));
    if (topic) {
      const matches = (raw: Item): boolean => {
        const item = project(raw), inferred = owner.overridden(id(item.seq)) ? [] : labels.get(item.seq)?.map(owner.resolve);
        return item.kind === 'assistant' ? item.blocks.some(block => (block.topic ?? inferred?.[0]) === topic) : item.kind === 'user' || item.kind === 'agent' || item.kind === 'job' ? item.topic === topic || inferred?.includes(topic) === true : false;
      };
      const dependencies = new Map<number, Map<string, Item>>();
      for (const extra of items) {
        if (extra.kind !== 'topics' && extra.kind !== 'annotations') continue;
        const target = extra.kind === 'topics' ? extra.target : extra.reply.seq;
        let entries = dependencies.get(target);
        if (!entries) { entries = new Map(); dependencies.set(target, entries); }
        entries.set(extra.kind === 'topics' ? 'topics' : 'annotation:' + extra.reply.block, extra);
      }
      const selected: { seq: number; json: string }[] = [];
      let messages = 0, more = false;
      for (let index = Math.min(before, items.length) - 1; index >= 0; index--) {
        const item = items[index];
        if (!matches(item)) continue;
        if (messages >= MAX_WEBVIEW_WINDOW_MESSAGES) { more = true; break; }
        const bundle = [item, ...(dependencies.get(item.seq)?.values() ?? [])].map(entry => ({ seq: entry.seq, json: JSON.stringify(output(entry)) }));
        selected.push(...bundle);
        if (counted(output(item), owner.overridden(id(item.seq)) ? undefined : labels.get(item.seq)?.map(owner.resolve)[0])) messages++;
      }
      return '"items":[' + selected.sort((a, b) => a.seq - b.seq).map(entry => entry.json).join(',') + '],"more":' + more;
    }
    let start = Math.min(before, items.length);
    const strings: string[] = [];
    let messages = 0;
    const seen = new Map<string, boolean>();
    while (start > 0 && messages < MAX_WEBVIEW_WINDOW_MESSAGES) {
      const item: WireItem = output(items[start - 1], seen);
      const json = JSON.stringify(item);
      strings.push(json);
      if (counted(item)) messages++;
      start--;
    }
    return '"items":[' + strings.reverse().join(",") + '],"more":' + (start > 0);
  };
  const reset = (): string => frame('{"type":"reset","epoch":' + JSON.stringify(epoch) + ',' + window(items.length) + '}');
  const schedule = (): void => {
    if (!flushTimer) flushTimer = later(flush, flushMs);
  };
  const publish = (item: Item): void => { dirty.add(item.seq); };
  const applyAssistant = (item: Assistant, message: Extract<AgentMessage, { role: "assistant" }>, ended: boolean): void => {
    const source = sources.get(item.seq) ?? { seed: currentTopic, blocks: [] };
    const parsed = message.content.map((block): { length: number; sections: ReturnType<typeof topicSections> } | undefined => {
      if (block.type !== 'text') return;
      const length = Array.from(block.text).length;
      return { length, sections: kind === 'root' ? topicSections(block.text, ended) : [{ text: block.text, start: 0, end: length }] };
    });
    const sections = parsed.flatMap(part => part?.sections ?? []);
    sources.set(item.seq, source);
    const previousBlocks = item.blocks;
    const mapped: typeof source.blocks = [];
    let topic = source.seed;
    const first = sections.find(section => section.topic)?.topic;
    if (kind === 'root' && first && !topic) {
      topic = first;
      for (const seq of unlabelled) if (seq !== item.seq) label(seq, [first], message.timestamp);
      unlabelled = [];
    }
    item.blocks = message.content.flatMap((block, index): Block[] => {
      if (block.type === "text") {
        const part = parsed[index];
        return (part?.sections ?? []).map(section => {
          if (section.topic) {
            topic = section.topic;
            if (!replyNames.includes(topic)) replyNames.push(topic);
          }
          mapped.push({ source: index, start: section.start, end: section.end, length: part?.length ?? 0 });
          return { type: 'text', text: section.text, ...(topic ? { topic } : {}) };
        });
      }
      mapped.push({ source: index, start: 0, end: 0, length: 0 });
      if (block.type === "thinking") {
        const previousIndex = source.blocks.findIndex(part => part.source === index);
        const previous = previousBlocks[previousIndex];
        return [{ type: "thinking", text: block.thinking, ...(topic ? { topic } : {}), redacted: !!block.redacted, ...(previous?.type === "thinking" ? { started: previous.started, ended: previous.ended } : {}) }];
      }
      if (block.type !== "toolCall") return [];
      const existing = tools.get(block.id)?.block;
      const next: Extract<Block, { type: "tool" }> = { ...existing, ...(topic ? { topic } : {}), type: "tool", id: block.id, name: block.name, args: existing && existing.state.type !== "pending" ? existing.args : cap(JSON.stringify(block.arguments), MAX_WEBVIEW_ARGS_BYTES), state: existing?.state ?? { type: "pending" } };
      const card = existing && existing.state.type !== 'pending' ? existing.agent : agentCall(block.name, block.arguments);
      if (card) next.agent = sameAgent(existing?.agent, card) ? existing?.agent : card;
      tools.set(block.id, { item, block: next });
      return [next];
    });
    source.blocks = mapped;
    if (kind === 'root') {
      currentTopic = topic;
      if (ended && !topic && item.blocks.length && item.blocks.every(block => block.type !== 'text') && !unlabelled.includes(item.seq)) unlabelled.push(item.seq);
      if (implicitUser !== undefined && replyNames.length) label(implicitUser, replyNames, message.timestamp);
    }
    item.stop = message.stopReason;
    item.error = message.stopReason === "aborted" ? "" : message.errorMessage ?? "";
    item.lifecycle = ended ? "ended" : "streaming";
    if (ended && (message.stopReason === "error" || message.stopReason === "aborted")) {
      notRun(item);
    }
    publish(item);
  };
  const sameBlock = (a: Block, b: Block): boolean => {
    if (a.type !== b.type || a.topic !== b.topic) return false;
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
      pending.delete(seq);
      try {
        const item = items[seq];
        if (item?.kind === "assistant") applyAssistant(item, held.message, held.phase === "end");
      } catch (error) { process.stderr.write(`koa: transcript: ${errorText(error)}\n`); }
    }
    for (const [id, held] of pendingTools) {
      pendingTools.delete(id);
      try {
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
          const topic = kind === 'root' ? parseTopicName(details?.topic) : undefined;
          if (topic) found.block.topic = topic;
          const done = outcome(details?.outcome), card = found.block.agent;
          if (card && done) {
            const to = card.call.tool === 'spawn' ? agentRef(details) ?? card.to : { ...card.to, ...(typeof details?.to === 'string' ? { name: details.to } : {}) };
            found.block.agent = { ...card, to, text: !done.ok && (card.call.tool === 'spawn' || !card.text.text) ? cap(done.message, MAX_WEBVIEW_RESULT_BYTES) : card.text, outcome: done };
          } else if (card) delete found.block.agent;
          if ((found.block.name === 'async_bash' || found.block.name === 'bash') && details) { const job = jobRef(details.job); if (job) found.block.job = job; }
        }
        const previous = "result" in found.block.state ? found.block.state.result?.images : undefined;
        const index = found.item.blocks.indexOf(found.block);
        const source = sources.get(found.item.seq)?.blocks[index]?.source ?? index;
        const result = { ...cap(text, MAX_WEBVIEW_RESULT_BYTES), images: saveImages(found.item.seq + "." + source, held.content, previous) };
        found.block.state = held.type === "done" ? { type: "done", result, error: held.error } : { type: "running", result };
        if (held.type === "done") {
          if (held.at !== undefined) found.block.ended = held.at;
          if (held.durationMs !== undefined) found.block.durationMs = held.durationMs;
        }
        publish(found.item);
      } catch (error) { process.stderr.write(`koa: transcript: ${errorText(error)}\n`); }
    }
    if (!notify) { dirty.clear(); return; }
    const { project, output } = projection();
    for (const seq of dirty) {
      const item = items[seq];
      if (!item) continue;
      const previous = sent.get(seq);
      if (item.kind === "assistant" && previous && item.blocks.length === previous.blocks.length) {
        const blocks = item.blocks.flatMap<{ index: number; suffix: string } | { index: number; block: Block }>((block, index) => {
          const old = previous.blocks[index];
          if (sameBlock(block, old)) return [];
          if (block.type !== "tool" && old.type === block.type && block.topic === old.topic && block.redacted === old.redacted && (block.type !== "thinking" || sameTiming(block, old)) && block.text.startsWith(old.text)) return [{ index, suffix: block.text.slice(old.text.length) }];
          const projected = project(item);
          return [{ index, block: projected.kind === 'assistant' ? projected.blocks[index] : block }];
        });
        if (blocks.length || item.final !== previous.final || item.stop !== previous.stop || item.error !== previous.error || item.ended !== previous.ended) {
          const baseRevision = item.revision++;
          broadcast({ type: "patch", seq, baseRevision, revision: item.revision, blocks, final: item.final, stop: item.stop, error: item.error, ended: item.ended });
        }
      } else { item.revision++; broadcast({ type: "item", item: output(item) }); }
      if (item.kind === "assistant" && !item.final) sent.set(seq, { ...item, blocks: item.blocks.map((block) => ({ ...block })) });
      else sent.delete(seq);
    }
    if (counters && dirty.size) { counters.flushes++; broadcast(flushRecord(counters.bytes, counters.flushes)); }
    const updated = dirty.size > 0;
    dirty.clear();
    if (updated) changed?.();
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
        item = { seq: items.length, revision: 0, at: message.timestamp, get final() { return final(this); }, kind: "assistant", blocks: [], stop: "", error: "", lifecycle: "streaming" };
        items.push(item);
        if (!branch) assistant = item.seq;
      }
      if (item.kind !== "assistant") return;
      messages.set(item.seq, { message });
      if (branch || phase === "start") {
        applyAssistant(item, message, branch);
        if (branch) for (const block of item.blocks) if (block.type === "tool") block.started ??= message.timestamp;
      } else pending.set(item.seq, { message, phase });
      if (phase === "end") { item.ended = ended; assistant = undefined; }
      if (!branch) { if (phase === "update") schedule(); else flush(); }
      return;
    }
    if (phase !== "end" && !branch) return;
    if (!branch) flush();
    else if (kind === 'root' && (message.role === 'user' || message.role === 'custom' && message.display && (agentDetails(message.details) || noticeDetails(message.details) || streamDetails(message.details)))) flushLabels();
    const seq = items.length;
    let item: Item;
    switch (message.role) {
      case "user": {
        const files = phase === "branch" ? [] : attachments;
        const decoded = decodePrompt(contentText(message.content), files, kind);
        const { topic } = decoded;
        if (kind === 'root') { boundary(topic); if (!topic) implicitUser = seq; }
        item = { seq, revision: 0, at: message.timestamp, final: true, kind: "user", ...decoded, images: saveImages(String(seq), message.content), attachments: files }; break;
      }
      case 'custom': {
        if (!message.display) return;
        const details = isRecord(message.details) ? message.details : undefined;
        const topic = kind === 'root' ? parseTopicName(details?.topic) : undefined;
        const agent = agentDetails(details), notice = agent ? undefined : noticeDetails(details), stream = agent || notice ? undefined : streamDetails(details);
        if (agent) item = { seq, revision: 0, at: message.timestamp, final: true, kind: 'agent', ...(topic ? { topic } : {}), direction: 'in', from: agent.agent, text: cap(agent.body, MAX_WEBVIEW_RESULT_BYTES), inbound: agent.inbound };
        else if (notice) { const { end, ...job } = notice.job; item = { seq, revision: 0, at: message.timestamp, final: true, kind: 'job', ...(topic ? { topic } : {}), job, event: { type: 'ended', end, tail: cap(notice.tail, MAX_WEBVIEW_RESULT_BYTES) } }; }
        else if (stream) item = { seq, revision: 0, at: message.timestamp, final: true, kind: 'job', ...(topic ? { topic } : {}), job: stream.job, event: { type: 'stream', batch: cap(stream.batch, MAX_WEBVIEW_RESULT_BYTES), omitted: stream.omitted, cut: stream.cut } };
        else item = { seq, revision: 0, at: message.timestamp, final: true, kind: 'notice', customType: message.customType, from: typeof details?.from === 'string' ? details.from : '', text: contentText(message.content) };
        if (kind === 'root' && (agent || notice || stream)) boundary(topic);
        break;
      }
      case "bashExecution": item = { seq, revision: 0, at: message.timestamp, final: true, kind: "bash", command: message.command, excludeFromContext: message.excludeFromContext ?? false, result: bashResult(message) }; break;
      case "branchSummary": case "compactionSummary": item = { seq, revision: 0, at: message.timestamp, final: true, kind: "summary", source: message.role === "branchSummary" ? "branch" : "compaction", text: message.summary }; break;
      default: return;
    }
    const running = !branch && message.role === 'compactionSummary' ? items.findLast(value => value.kind === 'command' && value.result.type === 'compaction' && value.result.state.type === 'running') : undefined;
    if (running) { item.seq = running.seq; item.revision = running.revision; items[running.seq] = item; }
    else items.push(item);
    messages.set(item.seq, { message });
    if (!branch) { publish(item); flush(); }
  };
  const moveTargets = (seq: number): string[] | undefined => {
    const item = items[seq];
    if (kind !== 'root' || !item || item.kind !== 'user' && item.kind !== 'assistant') return;
    const user = item.kind === 'user' ? item : items.findLast(other => other.kind === 'user' && other.seq < seq);
    const next = items.find(other => other.kind === 'user' && other.seq > seq)?.seq ?? items.length;
    const targets = [...(user ? [user] : []), ...items.filter(other => other.kind === 'assistant' && other.seq > (user?.seq ?? -1) && other.seq < next)];
    if (targets.some(target => target.kind === 'assistant' && target.lifecycle !== 'ended')) return;
    const entries = branch(), ids = targets.map(target => entryId(target.seq, entries));
    return ids.every((id): id is string => id !== undefined) ? ids : undefined;
  };
  const annotation = (entry: SessionEntry, notify = true): void => {
    if (kind === 'root' && topicArchive(entry)) { list = undefined; changed?.(); return; }
    if (kind === 'root' && (entry.type === 'custom' && entry.customType === 'koa.topic-move' || messageTopic(entry))) {
      flush();
      list = undefined;
      epoch = mintId();
      sent.clear();
      const record = reset();
      for (const req of subscribers) body(req, record, true);
      changed?.();
      return;
    }
    if (isTopicRecord(entry)) return;
    const decoded = decodeAnnotation(entry);
    if (!decoded) return;
    flush(notify);
    const { reply, at } = decoded;
    const target = items.findLast(item => item.kind === 'assistant' && item.at === reply.at);
    if (target?.kind !== 'assistant') return;
    const mapping = sources.get(target.seq)?.blocks;
    const source = mapping?.find(part => part.source === reply.block);
    if (!source || source.length !== reply.length || target.blocks[mapping?.indexOf(source) ?? -1]?.type !== 'text') return;
    const span = (value: unknown, start: number, end: number): value is [number, number] => Array.isArray(value) && value.length === 2 && value.every(Number.isSafeInteger) && value[0] >= start && value[0] < value[1] && value[1] <= end;
    const disjoint = <T>(spans: T[], range: (value: T) => [number, number]): T[] => {
      let end = 0;
      return spans.sort((a, b) => range(a)[0] - range(b)[0]).filter(value => {
        const next = range(value);
        if (next[0] < end) return false;
        end = next[1]; return true;
      });
    };
    const annotations = disjoint(decoded.annotations.flatMap((value): Annotation[] => {
      if (!isRecord(value) || value.type !== 'question' || !span(value.range, 0, reply.length)) return [];
      const range = value.range;
      switch (value.kind) {
        case 'choice':
          if (!Array.isArray(value.options)) return [];
          return [{ type: 'question', kind: value.kind, range, options: disjoint(value.options.filter((option): option is [number, number] => span(option, range[0], range[1])), option => option) }];
        case 'yes_no': case 'open': return [{ type: 'question', kind: value.kind, range }];
        default: return [];
      }
    }), value => value.range);
    if (!annotations.length) return;
    for (const [index, part] of (mapping ?? []).entries()) {
      if (part.source !== reply.block) continue;
      const remapped = annotations.flatMap((annotation): Annotation[] => {
        if (annotation.range[0] < part.start || annotation.range[1] > part.end) return [];
        const shift = (range: [number, number]): [number, number] => [range[0] - part.start, range[1] - part.start];
        return [{ ...annotation, range: shift(annotation.range), ...(annotation.kind === 'choice' ? { options: annotation.options.map(shift) } : {}) }];
      });
      if (!remapped.length) continue;
      const item: Item = { kind: 'annotations', seq: items.length, revision: 0, at, final: true, reply: { seq: target.seq, block: index }, annotations: remapped };
      items.push(item);
      if (notify) publish(item);
    }
    if (notify) flush();
  };
  const rebuild = (entries: readonly SessionEntry[] = [], nextSession?: string, leafId: string | null = null): void => {
    const notices = session.type === 'unbound' || session.id === nextSession ? items.filter(item => item.kind === 'notify' || item.kind === 'command').sort((a, b) => a.at - b.at) : [];
    session = { type: 'bound', id: nextSession };
    images.clear(); rmSync(imageDir, { recursive: true, force: true }); mkdirSync(imageDir, { mode: 0o700 });
    epoch = mintId();
    items = [];
    assistant = undefined;
    sent.clear();
    dirty.clear();
    pending.clear();
    pendingTools.clear();
    tools.clear(); sources.clear(); labels.clear(); boundary(undefined);
    const byId = new Map(entries.map(entry => [entry.id, entry]));
    const active: SessionEntry[] = [];
    for (let entry = leafId === null ? undefined : byId.get(leafId); entry; entry = entry.parentId === null ? undefined : byId.get(entry.parentId)) { active.push(entry); byId.delete(entry.id); }
    messages.clear();
    active.reverse();
    const replayMessages = active.flatMap(entry => sessionEntryToContextMessages(entry).map(message => ({ entryId: entry.id, message })));
    const extra = [
      ...notices.map(notice => ({ type: 'notice' as const, at: notice.at, notice })),
      ...active.flatMap(entry => { const decoded = decodeAnnotation(entry); return decoded ? [{ type: 'annotation' as const, at: decoded.at, entry }] : []; }),
    ].sort((a, b) => a.at - b.at);
    let next = 0;
    const replay = replayMessages.flatMap(({ entryId, message }) => {
      const start = next;
      while (next < extra.length && extra[next].at < message.timestamp) next++;
      return [...extra.slice(start, next), { type: 'message' as const, entryId, message }];
    });
    replay.push(...extra.slice(next));
    delivery = { type: 'replay', labels: new Map() };
    try {
      for (const event of replay) {
        switch (event.type) {
          case 'message': {
            const seq = items.length;
            applyMessage(event.message, 'branch');
            if (messages.has(seq)) messages.set(seq, { message: event.message, entryId: event.entryId });
            break;
          }
          case 'notice': items.push({ ...event.notice, seq: items.length, revision: 0 }); break;
          case 'annotation': annotation(event.entry, false); break;
        }
      }
      flushLabels();
    } finally { delivery = { type: 'live' }; }
    flush(false);
    for (const item of items) if (item.kind === "assistant") notRun(item);
    sent.clear();
    const record = reset();
    for (const req of [...subscribers]) body(req, record, true);
  };

  const release = (): Set<ServerResponse> => take(subscribers);
  const show = (previous: { release(): Set<ServerResponse> }): void => {
    const responses = previous.release();
    flush();
    if (!subscribers.size) { sent.clear(); epoch = mintId(); }
    const record = reset(), state = currentState && frame(JSON.stringify(currentState));
    for (const req of responses) { follow(subscribers, req, { type: "selected" }); if (state) body(req, state, true); body(req, record, true); }
  };
  const message: (message: AgentMessage, phase: "start" | "update" | "end", ended?: number, attachments?: Attachment[]) => void = applyMessage;
  const thinking = (index: number, edge: "started" | "ended", at: number): void => {
    flush();
    const item = assistant === undefined ? undefined : items[assistant];
    const block = item?.kind === "assistant" ? item.blocks[sources.get(item.seq)?.blocks.findIndex(part => part.source === index) ?? index] : undefined;
    if (block?.type === "thinking" && item) { block[edge] = at; publish(item); schedule(); }
  };
  const append = (value: { kind: 'notify'; level: NotifyLevel; text: Text } | { kind: 'command'; result: CommandResult }): void => {
    flush();
    const item: Item = { seq: items.length, revision: 0, at: Date.now(), final: !(value.kind === 'command' && value.result.type === 'compaction' && value.result.state.type === 'running'), ...value };
    items.push(item); publish(item); flush();
  };
  const notify = (text: string, level: NotifyLevel): void => append({ kind: 'notify', level, text: cap(text, MAX_WEBVIEW_RESULT_BYTES) });
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
  const handle = (request: IncomingMessage, req: ServerResponse, address: ViewAddress = { type: "selected" }): boolean => {
    const url = new URL(request.url ?? "/", "http://ko");
    const { owner, project, output } = projection();
    if (request.method === "GET" && url.pathname.startsWith("/images/")) {
      const image = images.get(url.pathname.slice(8));
      if (!image) { respond(req, 404, "{}"); return true; }
      void serveFile(req, image.path, image.ref.id + "." + (imageExtensions[image.ref.mimeType] ?? "bin"), 410);
    } else if (request.method === 'GET' && url.pathname === '/history') {
      const history: string[] = [], topic = parseTopicName(url.searchParams.get('topic'));
      for (let index = items.length - 1; index >= 0 && history.length < 100; index--) {
        const item = project(items[index]);
        if (topic && (item.kind !== 'user' || item.topic !== owner.resolve(topic))) continue;
        const text = (item?.kind === 'user' ? item.text : item?.kind === 'bash' ? (item.excludeFromContext ? '!!' : '!') + item.command : '').trim();
        if (text && history.at(-1) !== text) history.push(text);
      }
      respond(req, 200, JSON.stringify({ entries: history }));
    } else if (request.method === "GET" && url.pathname === "/items") {
      flush();
      const before = Number(url.searchParams.get("before"));
      const rawTopic = url.searchParams.get('topic');
      const topic = parseTopicName(rawTopic);
      if (!Number.isSafeInteger(before) || before < 0 || rawTopic !== null && (kind !== 'root' || !topic)) respond(req, 400, "{}");
      else respond(req, 200, '{"epoch":' + JSON.stringify(epoch) + ',' + window(before, topic) + '}');
    } else if (request.method === "GET" && url.pathname === "/events") {
      if (counters) counters.opens++;
      req.once("close", () => forget(req));
      flush();
      req.writeHead(200, { "Content-Type": "text/event-stream" });
      if (url.searchParams.get("epoch") === epoch) {
        if (counters) counters.cursors++;
        const after = Number(url.searchParams.get("after") ?? -1);
        if (!Number.isSafeInteger(after) || after < -1) { body(req, ""); return true; }
        for (const item of items.slice(after + 1)) {
          body(req, frame(JSON.stringify({ type: "item", item: output(item) })), true);
          if (req.writableEnded || req.destroyed) break;
        }
      } else { if (counters) counters.resets++; body(req, reset(), true); }
      if (req.writableEnded || req.destroyed) return true;
      follow(subscribers, req, address, undefined, url.searchParams.has("koa"));
      if (counters) body(req, frame(JSON.stringify(flushRecord(counters.bytes, counters.flushes))), true);
      if (currentState) broadcast(currentState);
    } else return false;
    return true;
  };
  const itemFile = (seq: number, index: number): string | undefined => {
    const item = items[seq];
    if (item?.kind === 'assistant') return pathArg(item.blocks[index]);
    if (item?.kind === 'command' && item.result.type === 'export' && index === 0) return item.result.path;
  };
  const command = (result: CommandResult): void => {
    flush();
    const current = result.type === 'compaction' ? items.findLast(item => item.kind === 'command' && item.result.type === 'compaction' && item.result.state.type === 'running') : undefined;
    if (current?.kind === 'command') { current.result = result; current.final = result.type !== 'compaction' || result.state.type !== 'running'; publish(current); flush(); }
    else append({ kind: 'command', result });
  };
  const jobFacts = (id: string): JobRef | undefined => {
    for (const item of items.toReversed()) {
      if (item.kind === 'job' && item.job.id === id) return item.job;
      if (item.kind === 'assistant') for (const block of item.blocks) if (block.type === 'tool' && block.job?.id === id) return block.job;
    }
  };
  return { topicContext: (queued: readonly QueuedPrompt[]) => {
    const { project, names, owner } = projection();
    return topicContext(items.map(project), names, queued.map(prompt => prompt.topic ? { ...prompt, topic: owner.resolve(prompt.topic) } : prompt), new Set(names.filter(owner.archived)));
  }, resolveTopic: (name: TopicName) => topics().resolve(name), isTopicArchived: (name: TopicName) => topics().archived(name), movable: (from: TopicName, to: TopicName) => topics().movable(from, to), moveTargets, quotedTopic: (text: string) => {
    const { project, names, owner } = projection();
    return quotedTopic(items.map(project), text, new Set(names.filter(owner.archived)));
  }, topics: (): Topic[] => {
    const { project, names, owner } = projection(), remaining = new Set(names);
    const summaries = new Map<TopicName, NonNullable<Topic['last']>>();
    const note = (name: TopicName | undefined, text: string, at: number) => {
      if (!name || !remaining.has(name)) return;
      const line = text.split(/\r?\n/).map(line => line.trim()).find(Boolean);
      if (!line) return;
      summaries.set(name, { summary: cleanLine(line, MAX_WEBVIEW_RESULT_BYTES), at }); remaining.delete(name);
    };
    for (let index = items.length - 1; index >= 0 && remaining.size; index--) {
      const item = project(items[index]);
      if (item.kind === 'user') note(item.topic, item.text, item.at);
      else if (item.kind === 'assistant') for (let block = item.blocks.length - 1; block >= 0; block--) {
        const value = item.blocks[block]; if (value.type === 'text') note(value.topic, value.text, item.at);
      }
    }
    return names.map(name => ({ name, ...(owner.archived(name) ? { archived: true as const } : {}), ...(summaries.has(name) ? { last: summaries.get(name) } : {}) }));
  }, command, jobFacts, itemFile, release, show, expire: (parent: string) => expire(subscribers, parent), message, thinking, annotation, rebuild, toolRunning, toolPartial, toolDone, state, notify, handle, close, get metrics() { return counters && { ...counters, subscribers: subscribers.size }; } };
}
