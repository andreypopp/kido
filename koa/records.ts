import type { components } from "../webview/ko-api.d.ts";

declare const topicName: unique symbol;
export type TopicName = string & { readonly [topicName]: true };
export const TOPIC_NAME_PATTERN = '^[^\\]\\u0000-\\u001f\\u007f-\\u009f]{1,200}$';
const topicNamePattern = new RegExp(TOPIC_NAME_PATTERN, 'u');
const isTopicName = (value: string): value is TopicName => topicNamePattern.test(value);
export const parseTopicName = (value: unknown): TopicName | undefined => {
  const name = typeof value === 'string' ? value.replace(/[^\S\u0000-\u001f\u007f-\u009f]+/gu, ' ').replace(/^ | $/g, '') : undefined;
  return name !== undefined && isTopicName(name) ? name : undefined;
};
export const topicMove = (entry: { type: string; customType?: string; data?: unknown }): { from: TopicName; to: TopicName } | undefined => {
  if (entry.type !== 'custom' || entry.customType !== 'koa.topic-move' || typeof entry.data !== 'object' || entry.data === null) return;
  const from = parseTopicName('from' in entry.data ? entry.data.from : undefined), to = parseTopicName('to' in entry.data ? entry.data.to : undefined);
  return from && to ? { from, to } : undefined;
};
export const topicArchive = (entry: { type: string; customType?: string; data?: unknown }): { name: TopicName; archived: boolean } | undefined => {
  if (entry.type !== 'custom' || entry.customType !== 'koa.topic-archive' || typeof entry.data !== 'object' || entry.data === null) return;
  const name = parseTopicName('name' in entry.data ? entry.data.name : undefined);
  return name && 'archived' in entry.data && typeof entry.data.archived === 'boolean' ? { name, archived: entry.data.archived } : undefined;
};
export const messageTopic = (entry: { type: string; customType?: string; data?: unknown }): { anchor: string; topic: TopicName } | undefined => {
  if (entry.type !== 'custom' || entry.customType !== 'koa.message-topic' || typeof entry.data !== 'object' || entry.data === null) return;
  const data = entry.data, anchor = 'anchor' in data ? data.anchor : undefined;
  const name = parseTopicName('topic' in data ? data.topic : undefined);
  return typeof anchor === 'string' && anchor.length > 0 && name ? { anchor, topic: name } : undefined;
};

export type Relation = components["schemas"]["Relation"];
const relations = new Set<string>(["parent", "child", "sibling", "descendant", "sibling_descendant"] satisfies Relation[]);
export const isRelation = (value: unknown): value is Relation => typeof value === "string" && relations.has(value);
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
export type AgentDetails = { topic?: TopicName; agent: AgentRef; body: string; inbound: Inbound };
export type MessageDetails = AgentDetails & { from?: string; work?: boolean; inbound: Extract<Inbound, { form: 'message' }> };
export type SteerDetails = AgentDetails & { from?: string; work?: boolean; inbound: Extract<Inbound, { form: 'steer' }> };
export type NoticeDetails = ((AgentDetails & { inbound: Extract<Inbound, { form: 'notice' | 'report' }> }) | { kind: 'job'; topic?: TopicName; job: JobRef & { end: JobEnd }; tail: string }) & { from?: string };
export type StreamDetails = { topic?: TopicName; from?: string; job: JobRef; batch: string; omitted: number; cut: boolean };
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

