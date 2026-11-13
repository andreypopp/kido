import type { CompletionQuery, CompletionResult, PromptMode, PromptResult, QueuedPrompt, SessionRow, SessionScope, ThinkingLevel, UploadProgress, WireItem } from '../koa-records.ts';

type Session = { sessionId: string | undefined };
type Empty = Record<string, never>;

export type Routes = {
  '/prompt': { request: Session & { text: string; mode: PromptMode | 'steer'; attachments: string[] }; response: PromptResult };
  '/complete': { request: Session & CompletionQuery; response: CompletionResult };
  '/history': { request: undefined; response: { entries: string[] } };
  '/items': { request: Session & { before: number }; response: { epoch: string; more: boolean; items: WireItem[] } };
  '/sessions/list': { request: Session & { scope: SessionScope }; response: { rows: SessionRow[] } };
  '/sessions/switch': { request: Session & { path: string }; response: { cancelled: boolean } };
  '/sessions/new': { request: Session; response: { cancelled: boolean } };
  '/models': { request: undefined; response: { models: { id: string; provider: string }[] } };
  '/model': { request: Session & { provider: string; modelId: string }; response: { id: string; provider: string } };
  '/thinking': { request: Session & { level: ThinkingLevel }; response: Empty };
  '/abort': { request: Session; response: Empty };
  '/dialog': { request: Session & { id: string } & ({ cancelled: true } | { confirmed: true } | { value: string | undefined }); response: Empty };
  '/editor/open': { request: Session & { text: string }; response: { pane: string } };
  '/editor/ack': { request: Session & { id: string }; response: Empty };
  '/queue/clear': { request: Session; response: { steering: QueuedPrompt[]; followUp: QueuedPrompt[] } };
  '/queue/remove': { request: Session & { kind: 'steer' | 'follow-up'; index: number; text: string }; response: Empty };
  '/agent/start': { request: Session; response: Empty };
  '/quit': { request: Session; response: Empty };
  '/view': { request: Session & { id: string }; response: Empty };
  '/attachments': { request: { name: string; type: string; size: number }; response: { id: string; path: string } };
  [path: `/attachments/${string}/${number}`]: { request: Uint8Array<ArrayBuffer>; response: UploadProgress };
  [path: `/attachments/${string}/delete`]: { request: undefined; response: Empty };
};

type Call<P extends keyof Routes> = Routes[P]['request'] extends undefined | Uint8Array<ArrayBuffer>
  ? [body?: Routes[P]['request'], method?: 'GET' | 'POST', signal?: AbortSignal, sessionId?: string]
  : [body: Routes[P]['request'], method?: 'POST', signal?: AbortSignal];

export const scoped = (path: string, sessionId: string | undefined) => sessionId === undefined ? path : path + (path.includes('?') ? '&' : '?') + 'sessionId=' + encodeURIComponent(sessionId);

export async function fetchJSON<P extends keyof Routes>(path: P, ...[body, method = 'POST', signal, sessionId]: Call<P>): Promise<Routes[P]['response']> {
  const deadline = AbortSignal.timeout(30000);
  const response = await fetch(scoped(path, sessionId), { method, signal: signal ? AbortSignal.any([signal, deadline]) : deadline, ...(method === 'GET' ? {} : body instanceof Uint8Array ? { headers: { 'Content-Type': 'application/octet-stream' }, body } : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) }) });
  const result = await response.json();
  if (!response.ok) throw Object.assign(Error(result.error || 'Request failed'), { body: result, status: response.status });
  return result;
}
