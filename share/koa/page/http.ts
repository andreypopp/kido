import type { Attachment, QueuedPrompt, UploadProgress } from '../../pi/records.ts';

export async function fetchJSON(path: '/models', body: undefined, method: 'GET'): Promise<{ models: { id: string; provider: string }[] }>;
export async function fetchJSON(path: '/queue/clear'): Promise<{ steering: QueuedPrompt[]; followUp: QueuedPrompt[] }>;
export async function fetchJSON(path: '/attachments', body: { path: string }): Promise<Attachment>;
export async function fetchJSON(path: '/attachments', body: { name: string; type: string; size: number }): Promise<{ id: string; path: string }>;
export async function fetchJSON(path: `/attachments/${string}/${number}`, body: Uint8Array<ArrayBuffer>, method: 'POST', signal: AbortSignal): Promise<UploadProgress>;
export async function fetchJSON(path: string, body?: object | Uint8Array<ArrayBuffer>, method?: string, signal?: AbortSignal): Promise<object>;
export async function fetchJSON(path: string, body: object | Uint8Array<ArrayBuffer> = {}, method = 'POST', signal?: AbortSignal) {
  const deadline = AbortSignal.timeout(30000);
  const response = await fetch(path, { method, signal: signal ? AbortSignal.any([signal, deadline]) : deadline, ...(method === 'GET' ? {} : body instanceof Uint8Array ? { body } : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }) });
  const result = await response.json();
  if (!response.ok) throw Error(result.error || 'Request failed');
  return result;
}
