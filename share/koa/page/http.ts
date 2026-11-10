import type { QueuedPrompt, UploadProgress, PromptResult, SessionRow, SessionScope } from '../koa-records.ts';

export async function fetchJSON(path: '/prompt', body: object): Promise<PromptResult>;
export async function fetchJSON(path: '/sessions/list', body: { scope: SessionScope }, method: 'POST', signal: AbortSignal): Promise<{ rows: SessionRow[] }>;
export async function fetchJSON(path: '/sessions/switch', body: { path: string; sessionId?: string }): Promise<{ cancelled: boolean }>;
export async function fetchJSON(path: '/sessions/new', body: { sessionId?: string }): Promise<{ cancelled: boolean }>;
export async function fetchJSON(path: '/models', body: undefined, method: 'GET'): Promise<{ models: { id: string; provider: string }[] }>;
export async function fetchJSON(path: '/queue/clear', body: { sessionId?: string }): Promise<{ steering: QueuedPrompt[]; followUp: QueuedPrompt[] }>;
export async function fetchJSON(path: '/attachments', body: { name: string; type: string; size: number }): Promise<{ id: string; path: string }>;
export async function fetchJSON(path: `/attachments/${string}/${number}`, body: Uint8Array<ArrayBuffer>, method: 'POST', signal: AbortSignal): Promise<UploadProgress>;
export async function fetchJSON(path: string, body?: object | Uint8Array<ArrayBuffer>, method?: string, signal?: AbortSignal): Promise<object>;
export async function fetchJSON(path: string, body: object | Uint8Array<ArrayBuffer> = {}, method = 'POST', signal?: AbortSignal) {
  const deadline = AbortSignal.timeout(30000);
  const response = await fetch(path, { method, signal: signal ? AbortSignal.any([signal, deadline]) : deadline, ...(method === 'GET' ? {} : body instanceof Uint8Array ? { headers: { 'Content-Type': 'application/octet-stream' }, body } : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }) });
  const result = await response.json();
  if (!response.ok) throw Error(result.error || 'Request failed');
  return result;
}
