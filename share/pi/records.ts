import type { components } from "./ko-api.d.ts";

export const ATTACHMENT_LIMITS = { files: 16, fileBytes: 64 * 1024 * 1024, chunkBytes: 768 * 1024, pendingBytes: 256 * 1024 * 1024 };

export type CompletionCommand = { name: string; description?: string; source: "extension" | "prompt" | "skill" };
export type CompletionOption = { label: string; detail?: string; insert: string; cursor?: number } & ({ kind: "command"; source: CompletionCommand["source"]; matched: number[] } | { kind: "agent"; matched: number[] } | { kind: "file" | "directory" });
export type CompletionQuery = { text: string; pos: number };
export type CompletionResult = { from: number; to: number; options: CompletionOption[] };
export type PromptMode = "prompt" | "follow_up";
export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type DialogMethod = Dialog["method"];
export type Text = { text: string; cut: number };
export type Attachment = { id: string; name: string; size: number; path: string; origin: "path" | "upload" } & ({ kind: "image"; mimeType: string; width?: number; height?: number } | { kind: "file" });
export type UploadProgress = { received: number; attachment?: Attachment };
export type QueuedPrompt = { text: string; attachments: Attachment[] };

export type ImageRef = { id: string; revision: number; mimeType: string; bytes: number; width?: number; height?: number };
export type Relation = components["schemas"]["Relation"];
const relations = new Set<string>(["parent", "child", "sibling", "descendant", "sibling_descendant"] satisfies Relation[]);
export const isRelation = (value: unknown): value is Relation => typeof value === "string" && relations.has(value);
export type AgentRef = { name: string; session?: string; pane?: string };
export type AgentOutcome = { ok: true } | { ok: false; failure: 'refused' | 'not_found' | 'ambiguous' | 'not_running' | 'gone' | 'error'; message: string };
const failures = new Set<string>(['refused', 'not_found', 'ambiguous', 'not_running', 'gone', 'error'] satisfies Extract<AgentOutcome, { ok: false }>['failure'][]);
export const isAgentFailure = (value: unknown): value is Extract<AgentOutcome, { ok: false }>['failure'] => typeof value === 'string' && failures.has(value);
export type Inbound = { form: 'message'; relation: Relation; runtime?: string } | { form: 'notice' } | { form: 'steer'; relation?: Relation } | { form: 'report'; relation?: Relation } | { form: 'ended'; reported: boolean; relation?: Relation };
export type AgentCall = { direction: 'out'; to: AgentRef; text: Text; call: { tool: 'spawn'; model?: string; fork: boolean; runtime?: string } | { tool: 'message'; mode: 'message' | 'steer' | 'interrupt-and-steer' }; outcome?: AgentOutcome };
export type JobEnd = { type: 'exit'; code: number } | { type: 'signal'; signal: string } | { type: 'failed'; message: string } | { type: 'stopped' } | { type: 'timeout'; seconds: number };
export type JobRef = { id: string; name: string; service: boolean; log: string };
export type AgentDetails = { agent: AgentRef; body: string; inbound: Inbound };
export type MessageDetails = AgentDetails & { from?: string; work?: boolean; inbound: Extract<Inbound, { form: 'message' }> };
export type SteerDetails = AgentDetails & { from?: string; work?: boolean; inbound: Extract<Inbound, { form: 'steer' }> };
export type NoticeDetails = ((AgentDetails & { inbound: Extract<Inbound, { form: 'notice' | 'report' | 'ended' }> }) | { kind: 'job'; job: JobRef & { end: JobEnd }; tail: string }) & { from?: string; noticeId?: string };
export type StreamDetails = { from?: string; job: JobRef; batch: string; omitted: number; cut: boolean };
export function jobEndText(end: JobEnd): string {
  switch (end.type) {
    case 'exit': return `exit ${end.code}`;
    case 'signal': return `signal ${end.signal}`;
    case 'failed': return `failed: ${end.message}`;
    case 'stopped': return 'stopped';
    case 'timeout': return `timed out after ${end.seconds} s`;
  }
}

type ToolResult = Text & { images: ImageRef[] };
type ToolState = { type: "pending" } | { type: "running"; result?: ToolResult } | { type: "done"; result: ToolResult; error: boolean } | { type: "not_run" };
export type Block = (({ type: "text" } | { type: "thinking" }) & { text: string; redacted?: boolean; started?: number; ended?: number }) | { type: "tool"; id: string; name: string; args: Text; state: ToolState; started?: number; ended?: number; durationMs?: number; exit?: number; agent?: AgentCall; job?: JobRef };
export type Item = { seq: number; at: number; final: boolean } & (
  { kind: "user"; text: string; images: ImageRef[]; attachments: Attachment[] } |
  { kind: "assistant"; blocks: Block[]; stop: string; error: string; ended?: number; lifecycle: "streaming" | "ended" } |
  { kind: 'agent'; direction: 'in'; from: AgentRef; text: Text; inbound: Inbound } |
  { kind: 'job'; job: JobRef; event: { type: 'ended'; end: JobEnd; tail: Text } | { type: 'stream'; batch: Text; omitted: number; cut: boolean } } |
  { kind: "notice"; customType: string; from: string; text: string } |
  { kind: "bash"; command: string; output: Text; exit?: number } |
  { kind: "summary"; text: string }
);
export type Assistant = Extract<Item, { kind: "assistant" }>;
export type WireAssistant = Omit<Assistant, "lifecycle">;
export type WireItem = Exclude<Item, Assistant> | WireAssistant;
export type Exit = { exited: number } | { signal: string } | { failed: string };
export type Pi = { type: "starting" } | { type: "ready" } | ({ type: "exited"; at: number; stderr: string } & Exit);
export type Dialog = { type: "extension_ui_request"; id: string; title: string; expires?: number } & (
  { method: "select"; options: string[]; timeout?: number } |
  { method: "confirm"; message: string; timeout?: number } |
  { method: "input"; placeholder?: string; timeout?: number } |
  { method: "editor"; prefill?: string }
);
export type State = { working: boolean; since?: number; aborted: boolean; name: string; model?: { provider: string; id: string }; thinking?: ThinkingLevel; levels: ThinkingLevel[]; context?: { tokens: number | null; window: number; percent: number | null }; cwd: string; home: string; sessionFile?: string; queue: { steering: readonly QueuedPrompt[]; followUp: readonly QueuedPrompt[] }; dialogs: Dialog[]; statuses: Record<string, string>; editor?: { id: string; text: string }; pi: Pi };
export function pathArg(block: Block | undefined): string | undefined {
  if (block?.type !== 'tool' || !['read', 'edit', 'write'].includes(block.name)) return;
  try { const value = JSON.parse(block.args.text); return value && typeof value.path === 'string' && value.path && !/[\p{Cc}]/u.test(value.path) ? value.path : undefined; } catch { return; }
}

export type Patch = { type: "patch"; seq: number; blocks: ({ index: number; block: Block } | { index: number; suffix: string })[]; final: boolean; stop: string; error: string; ended?: number };
export type PageRecord = { type: "reset"; epoch: string; more: boolean; items: WireItem[] } | { type: "item"; item: WireItem } | Patch | ({ type: "state" } & State) | { type: "notify"; message: string; level: "info" | "warning" | "error" } | { type: "flush"; bytes: number; t: number };
