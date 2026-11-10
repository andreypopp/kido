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
type ToolResult = Text & { images: ImageRef[] };
type ToolState = { type: "pending" } | { type: "running"; result?: ToolResult } | { type: "done"; result: ToolResult; error: boolean } | { type: "not_run" };
export type Block = (({ type: "text" } | { type: "thinking" }) & { text: string; redacted?: boolean; started?: number; ended?: number }) | { type: "tool"; id: string; name: string; args: Text; state: ToolState; started?: number; ended?: number; durationMs?: number; exit?: number };
export type Item = { seq: number; at: number; final: boolean } & (
  { kind: "user"; text: string; images: ImageRef[]; attachments: Attachment[] } |
  { kind: "assistant"; blocks: Block[]; stop: string; error: string; ended?: number; lifecycle: "streaming" | "ended" } |
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
export type Patch = { type: "patch"; seq: number; blocks: ({ index: number; block: Block } | { index: number; suffix: string })[]; final: boolean; stop: string; error: string; ended?: number };
export type PageRecord = { type: "reset"; epoch: string; more: boolean; items: WireItem[] } | { type: "item"; item: WireItem } | Patch | ({ type: "state" } & State) | { type: "notify"; message: string; level: "info" | "warning" | "error" } | { type: "flush"; bytes: number; t: number };
