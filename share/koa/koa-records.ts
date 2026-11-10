import type { AgentRef, AgentOutcome, JobRef, JobEnd, Inbound } from '../pi/records.ts';

export const ATTACHMENT_LIMITS = { files: 16, fileBytes: 64 * 1024 * 1024, chunkBytes: 768 * 1024, pendingBytes: 256 * 1024 * 1024 };

export type CompletionCommand = { name: string; description?: string; source: "extension" | "prompt" | "skill" };
export type CompletionOption = { label: string; detail?: string; insert: string; cursor?: number } & ({ kind: "command"; source: CompletionCommand["source"]; matched: number[] } | { kind: "agent"; matched: number[] } | { kind: "file" | "directory" });
export type CompletionQuery = { text: string; pos: number };
export type CompletionResult = { from: number; to: number; options: CompletionOption[] };
export type PromptMode = "prompt" | "follow_up";
export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type DialogMethod = Dialog["method"];
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
export type AgentCall = { direction: 'out'; to: AgentRef; text: Text; call: { tool: 'spawn'; model?: string; fork: boolean; runtime?: string } | { tool: 'message'; mode: 'message' | 'steer' | 'interrupt-and-steer' }; outcome?: AgentOutcome };
type ToolResult = Text & { images: ImageRef[] };
type ToolState = { type: "pending" } | { type: "running"; result?: ToolResult } | { type: "done"; result: ToolResult; error: boolean } | { type: "not_run" };
export type Block = (({ type: "text" } | { type: "thinking" }) & { text: string; redacted?: boolean; started?: number; ended?: number }) | { type: "tool"; id: string; name: string; args: Text; state: ToolState; started?: number; ended?: number; durationMs?: number; exit?: number; agent?: AgentCall; job?: JobRef };
export type Annotation = { type: 'question'; range: [number, number] } & ({ kind: 'choice'; options: [number, number][] } | { kind: 'yes_no' } | { kind: 'open' });
export type Item = { seq: number; at: number; final: boolean } & (
  { kind: "user"; text: string; images: ImageRef[]; attachments: Attachment[] } |
  { kind: "assistant"; blocks: Block[]; stop: string; error: string; ended?: number; lifecycle: "streaming" | "ended" } |
  { kind: 'agent'; direction: 'in'; from: AgentRef; text: Text; inbound: Inbound } |
  { kind: 'job'; job: JobRef; event: { type: 'ended'; end: JobEnd; tail: Text } | { type: 'stream'; batch: Text; omitted: number; cut: boolean } } |
  { kind: 'annotations'; reply: { seq: number; block: number }; annotations: Annotation[] } |
  { kind: "notify"; level: NotifyLevel; text: Text } |
  { kind: "notice"; customType: string; from: string; text: string } |
  { kind: "bash"; command: string; excludeFromContext: boolean; result: BashResult } |
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
export type BashResult = { output: Text; exit?: number; cancelled: boolean; truncated: boolean; fullOutputPath?: string };
export type Bash = { id: string; command: string; excludeFromContext: boolean; started: number } & ({ phase: 'running' | 'cancelling'; output: Text } | { phase: 'completed'; ended: number; result: BashResult });
export type State = { bash: Bash[]; working: boolean; since?: number; aborted: boolean; name: string; model?: { provider: string; id: string }; thinking?: ThinkingLevel; levels: ThinkingLevel[]; context?: { tokens: number | null; window: number; percent: number | null }; cwd: string; home: string; sessionFile?: string; queue: { steering: readonly QueuedPrompt[]; followUp: readonly QueuedPrompt[] }; dialogs: Dialog[]; statuses: Record<string, string>; editor?: { id: string; text: string }; pi: Pi };
export function pathArg(block: Block | undefined): string | undefined {
  if (block?.type !== 'tool' || !['read', 'edit', 'write'].includes(block.name)) return;
  try { const value = JSON.parse(block.args.text); return value && typeof value.path === 'string' && value.path && !/[\p{Cc}]/u.test(value.path) ? value.path : undefined; } catch { return; }
}

export type Patch = { type: "patch"; seq: number; blocks: ({ index: number; block: Block } | { index: number; suffix: string })[]; final: boolean; stop: string; error: string; ended?: number };
export type PageRecord = { type: "reset"; epoch: string; more: boolean; items: WireItem[] } | { type: "item"; item: WireItem } | Patch | ({ type: "state" } & State) | { type: "flush"; bytes: number; t: number };
