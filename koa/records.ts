import type { components } from "../webview/ko-api.d.ts";

declare const threadName: unique symbol;
export type ThreadName = string & { readonly [threadName]: true };
export const THREAD_NAME_PATTERN = '^[^\\]\\u0000-\\u001f\\u007f-\\u009f]{1,200}$';
const threadNamePattern = new RegExp(THREAD_NAME_PATTERN, 'u');
const isThreadName = (value: string): value is ThreadName => threadNamePattern.test(value);
export const parseThreadName = (value: unknown): ThreadName | undefined => {
  const name = typeof value === 'string' ? value.replace(/[^\S\u0000-\u001f\u007f-\u009f]+/gu, ' ').replace(/^ | $/g, '') : undefined;
  return name !== undefined && isThreadName(name) ? name : undefined;
};
export const threadMove = (entry: { type: string; customType?: string; data?: unknown }): { from: ThreadName; to: ThreadName } | undefined => {
  if (entry.type !== 'custom' || entry.customType !== 'koa.thread-move' || typeof entry.data !== 'object' || entry.data === null) return;
  const from = parseThreadName('from' in entry.data ? entry.data.from : undefined), to = parseThreadName('to' in entry.data ? entry.data.to : undefined);
  return from && to ? { from, to } : undefined;
};
export const messageThread = (entry: { type: string; customType?: string; data?: unknown }): { entries: string[]; thread: ThreadName } | undefined => {
  if (entry.type !== 'custom' || entry.customType !== 'koa.message-thread' || typeof entry.data !== 'object' || entry.data === null) return;
  const data = entry.data, entries = 'entries' in data ? data.entries : undefined;
  const name = parseThreadName('thread' in data ? data.thread : undefined);
  return Array.isArray(entries) && entries.length > 0 && entries.every((id): id is string => typeof id === 'string' && id.length > 0) && new Set(entries).size === entries.length && name ? { entries, thread: name } : undefined;
};

export type Relation = components["schemas"]["Relation"];
const relations = new Set<string>(["parent", "child", "sibling", "descendant", "sibling_descendant"] satisfies Relation[]);
export const isRelation = (value: unknown): value is Relation => typeof value === "string" && relations.has(value);
export type RestartState = { type: 'ready' } | { type: 'blocked'; jobs: number; children: number };
export type AgentEnd = 'stopped' | 'koa restarted' | 'its session ended on an error';
export type AgentRef = { name: string; session?: string; pane?: string };
export type AgentOutcome = { ok: true } | { ok: false; failure: 'refused' | 'not_found' | 'ambiguous' | 'not_running' | 'gone' | 'error'; message: string };
const failures = new Set<string>(['refused', 'not_found', 'ambiguous', 'not_running', 'gone', 'error'] satisfies Extract<AgentOutcome, { ok: false }>['failure'][]);
export const isAgentFailure = (value: unknown): value is Extract<AgentOutcome, { ok: false }>['failure'] => typeof value === 'string' && failures.has(value);
export type Inbound = { form: 'message'; relation: Relation; runtime?: string } | { form: 'notice' } | { form: 'steer'; relation?: Relation } | { form: 'report'; relation?: Relation };
export type JobEnd = { type: 'exit'; code: number } | { type: 'signal'; signal: string } | { type: 'failed'; message: string } | { type: 'stopped' } | { type: 'timeout'; seconds: number };
export type JobPlace = { type: 'runtime'; name: string } | { type: 'mac' } | { type: 'machine' } | { type: 'remote'; host: string };
export type JobSnapshot = { name: string; command: string; service: boolean; startedAt: number; place: JobPlace; log: string; state: { type: 'running' } | { type: 'ended'; end: JobEnd; at: number } | { type: 'cleared' } };
export type JobRef = { id: string; name: string; service: boolean; log: string; command: string; startedAt: number; place: JobPlace };
export type AgentDetails = { thread?: ThreadName; agent: AgentRef; body: string; inbound: Inbound };
export type MessageDetails = AgentDetails & { from?: string; work?: boolean; inbound: Extract<Inbound, { form: 'message' }> };
export type SteerDetails = AgentDetails & { from?: string; work?: boolean; inbound: Extract<Inbound, { form: 'steer' }> };
export type NoticeDetails = ((AgentDetails & { inbound: Extract<Inbound, { form: 'notice' | 'report' }> }) | { kind: 'job'; thread?: ThreadName; job: JobRef & { end: JobEnd }; tail: string }) & { from?: string };
export type StreamDetails = { thread?: ThreadName; from?: string; job: JobRef; batch: string; omitted: number; cut: boolean };
export function jobEndText(end: JobEnd): string {
  switch (end.type) {
    case 'exit': return `exit ${end.code}`;
    case 'signal': return `signal ${end.signal}`;
    case 'failed': return `failed: ${end.message}`;
    case 'stopped': return 'stopped';
    case 'timeout': return `timed out after ${end.seconds} s`;
  }
}

export type InProcessMessage =
  | { kind: "user"; text: string }
  | { kind: "message" | "steer" | "interrupt"; text: string; agent: AgentRef; relation: Relation | undefined; runtime?: string; returnTo?: { session: string; pane: string } }
  | { kind: "notice"; text: string; agent: AgentRef }
  | { kind: "system"; text: string };

