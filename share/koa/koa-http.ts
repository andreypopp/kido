import type { IncomingMessage, ServerResponse } from 'node:http';
import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { basename } from 'node:path';
import { imageInfo } from './koa-image.ts';
import { ATTACHMENT_LIMITS } from './koa-records.ts';

export async function readBody(request: IncomingMessage, limit: number): Promise<Buffer | undefined> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size <= limit) chunks.push(chunk);
  }
  return size <= limit ? Buffer.concat(chunks) : undefined;
}

const isChunkRoute = (path: string) => /^\/attachments\/[^/]+\/\d+$/.test(path);
export const wrongPostType = (request: IncomingMessage) => request.method === "POST" && request.headers["content-type"]?.split(";")[0]?.trim().toLowerCase() !== (isChunkRoute(new URL(request.url ?? "/", "http://koa").pathname) ? "application/octet-stream" : "application/json");

export function respond(response: ServerResponse, status: number, text: string, contentType = "application/json"): void {
  response.writeHead(status, { "Content-Type": contentType });
  response.end(text);
}

function fileDisposition(name: string): string {
  const file = basename(name);
  return 'inline; filename="' + file.replace(/[^\x20-\x21\x23-\x5b\x5d-\x7e]/g, '_') + '"; filename*=UTF-8\'\'' + encodeURIComponent(file);
}

export class FileError extends Error {
  readonly kind: 'too_large' | 'unreadable';
  get status(): number { return this.kind === 'too_large' ? 413 : this.cause instanceof Error && 'code' in this.cause && this.cause.code === 'ENOENT' ? 404 : 403; }
  constructor(kind: 'too_large' | 'unreadable', cause?: unknown) {
    super(kind === 'too_large' ? 'over ' + ATTACHMENT_LIMITS.fileBytes / 1048576 + ' MB' : 'not readable', { cause }); this.kind = kind;
  }
}

export async function openFile(path: string) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK).catch(error => { throw new FileError('unreadable', error); });
  try {
    const stat = await file.stat();
    if (!stat.isFile()) throw new FileError('unreadable');
    if (stat.size > ATTACHMENT_LIMITS.fileBytes) throw new FileError('too_large');
    const header = Buffer.alloc(Math.min(stat.size, 65536));
    const { bytesRead } = await file.read(header, 0, header.length, 0);
    return { file, size: stat.size, image: imageInfo(header.subarray(0, bytesRead)) };
  } catch (error) { await file.close(); throw error instanceof FileError ? error : new FileError('unreadable', error); }
}


export async function serveFile(response: ServerResponse, path: string, name: string, missing: 404 | 410): Promise<void> {
  response.setHeader('X-Content-Type-Options', 'nosniff'); response.setHeader('Content-Security-Policy', "sandbox; default-src 'none'"); response.setHeader('Cache-Control', 'no-store');
  try {
    const source = await openFile(path);
    try {
      if (response.destroyed) { await source.file.close(); return; }
      response.writeHead(200, { 'Content-Type': source.image?.mimeType ?? 'application/octet-stream', 'Content-Disposition': fileDisposition(name), 'Content-Length': source.size });
      if (!source.size) { await source.file.close(); response.end(); return; }
      const stream = source.file.createReadStream({ start: 0, end: source.size - 1 });
      stream.once('error', () => response.destroy()); response.once('close', () => stream.destroy()); stream.pipe(response);
    } catch (error) { await source.file.close(); throw error; }
  } catch (error) {
    if (response.headersSent) { response.destroy(); return; }
    const status = error instanceof FileError ? error.status : 403;
    respond(response, status === 404 ? missing : status, '{}');
  }
}
