import type { AgentRef, AgentOutcome, JobRef, JobEnd, JobSnapshot, Inbound } from "./records.ts";

export const ATTACHMENT_LIMITS = { files: 16, fileBytes: 64 * 1024 * 1024, chunkBytes: 768 * 1024, pendingBytes: 256 * 1024 * 1024 };

export type CompletionCommand = { name: string; description?: string; source: "extension" | "prompt" | "skill" | "builtin" };
export type CompletionOption = { label: string; detail?: string; insert: string; cursor?: number } & ({ kind: "command"; source: CompletionCommand["source"]; matched: number[] } | { kind: "agent"; matched: number[] } | { kind: "file" | "directory" });
export type CompletionQuery = { text: string; pos: number };
export type PromptCompletion = { type: 'prompt'; from: number; to: number; options: CompletionOption[] };
export type ShellCompletion = { type: 'shell'; from: number; to: number; options: { label: string; insert: string }[]; common: string; more: number };
export type CompletionResult = PromptCompletion | ShellCompletion;
export type CommandAction = { type: 'none' } | { type: 'picker'; kind: 'model' | 'thinking'; search: string } | { type: 'session'; kind: 'resume' | 'new' } | { type: 'quit' } | { type: 'reload' };
export type PromptResult = { disposition: 'handled'; action: CommandAction } | { disposition: 'started' | 'queued' };
export type CommandResult = { type: 'copy'; characters: number } | { type: 'export'; path: string } | { type: 'session'; stats: SessionStats; name: string; model?: { provider: string; id: string }; thinking?: ThinkingLevel } | { type: 'compaction'; state: { type: 'running' } | { type: 'done'; before: number; after?: number; summary: string } | { type: 'failed'; message: string } | { type: 'cancelled' } };
export type SessionStats = { sessionFile: string | undefined; sessionId: string; userMessages: number; assistantMessages: number; toolCalls: number; toolResults: number; totalMessages: number; tokens: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number }; cost: number; contextUsage?: { tokens: number | null; contextWindow: number; percent: number | null } };
export type SessionScope = "current" | "all";
export type SessionRow = { path: string; id: string; cwd: string; name?: string; firstMessage: string; modified: number; messageCount: number };
export type PromptMode = "prompt" | "follow_up";
export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type Text = { text: string; cut: number };
export type NotifyLevel = "info" | "warning" | "error";
export function isAttachment(value: unknown): value is Attachment {
  if (!value || typeof value !== "object") return false;
  return "id" in value && typeof value.id === "string" && "name" in value && typeof value.name === "string" && "path" in value && typeof value.path === "string" && "size" in value && typeof value.size === "number" && Number.isSafeInteger(value.size) && value.size >= 0 && "origin" in value && (value.origin === "path" || value.origin === "upload") && "kind" in value && (value.kind === "file" || value.kind === "image" && "mimeType" in value && typeof value.mimeType === "string");
}
export type Attachment = { id: string; name: string; size: number; path: string; origin: "path" | "upload" } & ({ kind: "image"; mimeType: string; width?: number; height?: number } | { kind: "file" });
export type UploadProgress = { received: number; attachment?: Attachment };
export type QueuedPrompt = { text: string; attachments: Attachment[] };

export type ImageRef = { id: string; revision: number; mimeType: string; bytes: number; width?: number; height?: number };
export type AgentCall = { direction: "out"; to: AgentRef; text: Text; call: { tool: "spawn"; model?: string; fork: boolean; runtime?: string } | { tool: "message"; mode: "message" | "steer" | "interrupt-and-steer" }; outcome?: AgentOutcome };
type ToolResult = Text & { images: ImageRef[] };
type ToolState = { type: "pending" } | { type: "running"; result?: ToolResult } | { type: "done"; result: ToolResult; error: boolean } | { type: "not_run" };
export type Block = (({ type: "text" } | { type: "thinking" }) & { text: string; redacted?: boolean; started?: number; ended?: number }) | { type: "tool"; id: string; name: string; args: Text; state: ToolState; started?: number; ended?: number; durationMs?: number; exit?: number; agent?: AgentCall; job?: WireJob };
export type Annotation = { type: "question"; range: [number, number] } & ({ kind: "choice"; options: [number, number][] } | { kind: "yes_no" } | { kind: "open" });
export type Item = { seq: number; revision: number; at: number; final: boolean } & (
  { kind: "user"; text: string; images: ImageRef[]; attachments: Attachment[] } |
  { kind: "assistant"; blocks: Block[]; stop: string; error: string; ended?: number; lifecycle: "streaming" | "ended" } |
  { kind: "agent"; direction: "in"; from: AgentRef; text: Text; inbound: Inbound } |
  { kind: "job"; job: WireJob; event: { type: "ended"; end: JobEnd; tail: Text } | { type: "stream"; batch: Text; omitted: number; cut: boolean } } |
  { kind: "annotations"; reply: { seq: number; block: number }; annotations: Annotation[] } |
  { kind: "notify"; level: NotifyLevel; text: Text } |
  { kind: 'command'; result: CommandResult } |
  { kind: "notice"; customType: string; from: string; text: string } |
  { kind: "bash"; command: string; excludeFromContext: boolean; result: BashResult } |
  { kind: "summary"; source: "branch" | "compaction"; text: string }
);
export type Assistant = Extract<Item, { kind: "assistant" }>;
export type WireAssistant = Omit<Assistant, "lifecycle">;
export type WireItem = Exclude<Item, Assistant> | WireAssistant;
export type Life = { type: "starting" } | { type: "ready" } | { type: "switching" } | { type: "reloading" } | { type: "failed"; at: number; message: string };
export type Dialog = { id: string; title: string; expires?: number } & (
  { method: "select"; options: string[]; timeout?: number } |
  { method: "confirm"; message: string; timeout?: number } |
  { method: "input"; placeholder?: string; timeout?: number } |
  { method: "editor"; prefill?: string }
);
export type BashResult = { output: Text; exit?: number; cancelled: boolean; truncated: boolean; fullOutputPath?: string };
export type Bash = { id: string; command: string; excludeFromContext: boolean; started: number } & ({ phase: 'running' | 'cancelling'; output: Text } | { phase: 'completed'; ended: number; result: BashResult });
export type WireJob = JobRef & { gone?: true };
export type LogChunk = { start: number; end: number; data: string };
type ViewEntry = { id: string; name: string; type: "agent" | "job" };
export type View = { id: string; path: ViewEntry[] } & ({ type: "agent" } | { type: "job"; job: JobSnapshot });
export type State = { compaction: 'idle' | 'running'; view: View; agents: { name: string; target: { type: "view"; id: string } | { type: "pane"; pane: string } }[]; bash: Bash[]; working: boolean; since?: number; aborted: boolean; name: string; model?: { provider: string; id: string }; thinking?: ThinkingLevel; levels: ThinkingLevel[]; context?: { tokens: number | null; window: number; percent: number | null }; cwd: string; home: string; sessionId?: string; sessionFile?: string; queue: { steering: readonly QueuedPrompt[]; followUp: readonly QueuedPrompt[] }; dialogs: Dialog[]; statuses: Record<string, string>; editor?: { id: string; text: string }; edit?: { pane: string; editor: string }; life: Life };
export function pathArg(block: Block | undefined): string | undefined {
  if (block?.type !== "tool" || !["read", "edit", "write"].includes(block.name)) return;
  try { const value = JSON.parse(block.args.text); return value && typeof value.path === "string" && value.path && !/[\p{Cc}]/u.test(value.path) ? value.path : undefined; } catch { return; }
}

export type Patch = { type: "patch"; seq: number; baseRevision: number; revision: number; blocks: ({ index: number; block: Block } | { index: number; suffix: string })[]; final: boolean; stop: string; error: string; ended?: number };
export type PageRecord = { type: "reset"; epoch: string; more: boolean; items: WireItem[] } | { type: "item"; item: WireItem } | Patch | ({ type: "state" } & State) | { type: "flush"; id: number; bytes: number; t: number } | { type: "reload" } | { type: "job-reset"; view: string; epoch: string; start: number; end: number; data: string } | { type: "job-append"; view: string; epoch: string; start: number; data: string } | { type: "job-gone"; view: string } | { type: "view_gone"; view: string; parent: string };
export type ViewRequest = { view?: string };
export type ViewGone = { kind: "view_gone"; view: string; error: string };

const recordTypes: Record<PageRecord["type"], true> = { reset: true, item: true, patch: true, state: true, flush: true, reload: true, "job-reset": true, "job-gone": true, "job-append": true, view_gone: true };
const pageSources = { frame: true, key: true, scroll: true, pointer: true, animationend: true, ResizeObserver: true, IntersectionObserver: true, other: true };
export type WriteSource = keyof typeof pageSources | `apply:${PageRecord["type"]}`;
const isRecordType = (value: unknown): value is PageRecord["type"] => typeof value === "string" && Object.hasOwn(recordTypes, value);
const isWriteSource = (value: unknown): value is WriteSource => typeof value === "string" && (Object.hasOwn(pageSources, value) || value.startsWith("apply:") && isRecordType(value.slice(6)));
export type MetricsMode = "applied" | "frame" | "probe";
export type Stages = { id: number; received: number; visibility: "visible" | "hidden"; request?: { at: number; fired: number } };
export type MetricsSample = { t: number; bytes: number; clockError: number; applied?: number; frame?: number; stages?: Stages };
export type Observation =
  | { type: "frame"; at: number; duration: number; gap?: number; lex: number; strays: number; probes: number; by: Partial<Record<WriteSource, number>> }
  | { type: "apply"; at: number; duration: number; record: PageRecord["type"]; lex: number; strays: number; probes: number; by: Partial<Record<WriteSource, number>> }
  | { type: "markdown"; at: number; words: number; lex: number; fallbacks: number }
  | { type: "stray"; at: number; source: WriteSource }
  | { type: "probe"; at: number }
  | { type: "key"; at: number; latency: number }
  | { type: "dots"; at: number; phase: "call" | "text" | "end"; count: number };
export type MetricsRequest = { samples: MetricsSample[]; observations: Observation[] };
const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
const record = (value: unknown): value is { [key: string]: unknown } => typeof value === "object" && value !== null && !Array.isArray(value);
const validBy = (value: unknown) => record(value) && Object.entries(value).every(([source, count]) => isWriteSource(source) && Number.isSafeInteger(count));
const validStages = (value: unknown) => value === undefined || record(value) && Number.isSafeInteger(value.id) && finite(value.received) && (value.visibility === "visible" || value.visibility === "hidden") && (value.request === undefined || record(value.request) && finite(value.request.at) && finite(value.request.fired));
function validObservation(entry: unknown): entry is Observation {
  if (!record(entry) || !finite(entry.at)) return false;
  switch (entry.type) {
    case "frame": return finite(entry.duration) && finite(entry.lex) && Number.isSafeInteger(entry.strays) && Number.isSafeInteger(entry.probes) && validBy(entry.by) && (entry.gap === undefined || finite(entry.gap));
    case "apply": return finite(entry.duration) && finite(entry.lex) && Number.isSafeInteger(entry.strays) && Number.isSafeInteger(entry.probes) && validBy(entry.by) && isRecordType(entry.record);
    case "markdown": return Number.isSafeInteger(entry.words) && finite(entry.lex) && Number.isSafeInteger(entry.fallbacks);
    case "stray": return isWriteSource(entry.source);
    case "probe": return true;
    case "key": return finite(entry.latency);
    case "dots": return (entry.phase === "call" || entry.phase === "text" || entry.phase === "end") && Number.isSafeInteger(entry.count);
    default: return false;
  }
}
export function metricsRequest(body: unknown): MetricsRequest | undefined {
  if (!record(body)) return;
  const { samples, observations } = body;
  if (!Array.isArray(samples) || samples.length > 50 || !samples.every(sample => record(sample) && finite(sample.t) && (finite(sample.frame) || finite(sample.applied)) && finite(sample.clockError) && validStages(sample.stages) && typeof sample.bytes === "number" && Number.isSafeInteger(sample.bytes) && sample.bytes >= 0)) return;
  if (!Array.isArray(observations) || observations.length > 200 || !observations.every(validObservation)) return;
  return { samples, observations };
}
