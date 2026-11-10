import type { IncomingMessage, ServerResponse } from 'node:http';
import { constants, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { imageInfo } from '../pi/image.ts';
import { mintId } from '../pi/text.ts';
import { readBody, respond, serveFile } from '../pi/transcript.ts';
import { ATTACHMENT_LIMITS, type Attachment, type UploadProgress } from './records.ts';
import type { RpcCommand } from '@earendil-works/pi-coding-agent';

export const UPLOAD_IDLE_MS = 30000;
type Entry = { type: 'uploading'; path: string; name: string; size: number; received: number; timer: ReturnType<typeof setTimeout>; request?: IncomingMessage } | { type: 'ready' | 'queued' | 'used'; info: Attachment };

class FileError extends Error {
  readonly kind: 'too_large' | 'unreadable';
  constructor(kind: 'too_large' | 'unreadable', cause?: unknown) {
    super(kind === 'too_large' ? 'over ' + ATTACHMENT_LIMITS.fileBytes / 1048576 + ' MB' : 'not readable', { cause }); this.kind = kind;
  }
}

async function openFile(path: string) {
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

export function attachments(dir: string, idleMs = UPLOAD_IDLE_MS) {
  const entries = new Map<string, Entry>();
  const data = (entry: Entry) => entry.type === 'uploading' ? { path: entry.path, name: entry.name, size: entry.size, origin: 'upload' as const } : entry.info;
  const remove = (id: string) => {
    const entry = entries.get(id); if (!entry) return;
    entries.delete(id);
    if (entry.type === 'uploading') { clearTimeout(entry.timer); entry.request?.destroy(); }
    const file = data(entry);
    if (file.origin === 'upload') rmSync(dirname(file.path), { recursive: true, force: true });
  };
  const renew = (id: string, entry: Extract<Entry, { type: 'uploading' }>) => { clearTimeout(entry.timer); entry.timer = setTimeout(() => remove(id), idleMs).unref(); };
  const info = (id: string, base: Pick<Attachment, 'name' | 'origin' | 'path'>, file: Awaited<ReturnType<typeof openFile>>): Attachment => {
    const common = { id, name: base.name, path: base.path, origin: base.origin, size: file.size };
    return file.image ? { ...common, kind: 'image', ...file.image } : { ...common, kind: 'file' };
  };
  return {
    async handle(request: IncomingMessage, response: ServerResponse, alive: boolean) {
      const url = new URL(request.url ?? '/', 'http://koa');
      if (url.pathname !== '/attachments' && !url.pathname.startsWith('/attachments/')) return false;
      response.setHeader('X-Content-Type-Options', 'nosniff'); response.setHeader('Content-Security-Policy', "sandbox; default-src 'none'");
      const reply = (status: number, value: object) => { respond(response, status, JSON.stringify(value)); return true; };
      if (!alive) return reply(409, { error: 'pi is not running' });
      try {
        if (url.pathname === '/attachments' && request.method === 'POST') {
          const bytes = await readBody(request, 1 << 20);
          if (!bytes) return reply(413, { error: 'Request too large' });
          let value: unknown;
          try { value = JSON.parse(bytes.toString('utf8')); } catch { return reply(400, { error: 'A JSON body is required' }); }
          if (!value || typeof value !== 'object') return reply(400, { error: 'An attachment is required' });
          let entry: Entry;
          const id = mintId();
          if ('path' in value) {
            if (typeof value.path !== 'string' || !isAbsolute(value.path) || /\p{Cc}/u.test(value.path)) return reply(400, { error: 'An absolute file path is required' });
            const file = await openFile(value.path);
            try { entry = { type: 'ready', info: info(id, { path: value.path, name: basename(value.path), origin: 'path' }, file) }; }
            finally { await file.file.close(); }
          } else {
            if (!('name' in value) || typeof value.name !== 'string' || !('type' in value) || typeof value.type !== 'string' || !('size' in value) || typeof value.size !== 'number' || !Number.isSafeInteger(value.size) || value.size < 0) return reply(400, { error: 'A file name, type and size are required' });
            if (value.size > ATTACHMENT_LIMITS.fileBytes) throw new FileError('too_large');
            const name = value.name.replace(/[\/\\\p{Cc}]/gu, '_');
            const safe = !name || name === '.' || name === '..' ? 'attachment' : name;
            entry = { path: join(dir, id, safe), type: 'uploading', name: safe, size: value.size, received: 0, timer: setTimeout(() => remove(id), idleMs).unref() };
          }
          const pending = [...entries.values()].filter(entry => entry.type === 'uploading' || entry.type === 'ready');
          if (pending.length >= ATTACHMENT_LIMITS.files || pending.reduce((total, item) => total + data(item).size, data(entry).size) > ATTACHMENT_LIMITS.pendingBytes) {
            if (entry.type === 'uploading') clearTimeout(entry.timer);
            return reply(409, { error: pending.length >= ATTACHMENT_LIMITS.files ? 'too many' : 'over ' + ATTACHMENT_LIMITS.pendingBytes / 1048576 + ' MB pending' });
          }
          if (entry.type === 'uploading') { mkdirSync(dirname(entry.path), { recursive: true, mode: 0o700 }); writeFileSync(entry.path, Buffer.alloc(0), { mode: 0o600 }); }
          entries.set(id, entry);
          return reply(200, entry.type === 'uploading' ? { id, path: entry.path } : entry.info);
        }
        const match = /^\/attachments\/([^/]+)(?:\/(delete|\d+))?$/.exec(url.pathname), id = match?.[1], operation = match?.[2];
        const entry = id ? entries.get(id) : undefined;
        if (!id || !entry) return reply(404, {});
        if (request.method === 'POST' && operation === 'delete') {
          if (entry.type === 'queued' || entry.type === 'used') return reply(409, { error: 'This attachment was sent' });
          remove(id); return reply(200, {});
        }
        if (request.method === 'POST' && operation !== undefined) {
          const offset = Number(operation);
          if (entry.type !== 'uploading' || entry.request || !Number.isSafeInteger(offset) || offset !== entry.received) return reply(409, { error: 'Upload offset does not match' });
          entry.request = request; renew(id, entry);
          const aborted = () => remove(id); request.once('aborted', aborted);
          let bytes: Buffer | undefined;
          try { bytes = await readBody(request, ATTACHMENT_LIMITS.chunkBytes); }
          finally { request.removeListener('aborted', aborted); delete entry.request; }
          if (request.aborted) return true;
          if (entries.get(id) !== entry) return reply(409, { error: 'Upload expired' });
          if (!bytes) return reply(413, { error: 'Chunk over ' + ATTACHMENT_LIMITS.chunkBytes / 1024 + ' KiB' });
          if (!bytes.length && entry.size > offset) return reply(400, { error: 'A byte body is required' });
          if (offset + bytes.length > entry.size) return reply(409, { error: 'Upload exceeds its declared size' });
          writeFileSync(entry.path, bytes, { flag: 'a' }); entry.received += bytes.length; renew(id, entry);
          if (entry.received < entry.size) return reply(200, { received: entry.received });
          const file = await openFile(entry.path);
          try {
            if (entries.get(id) !== entry) return reply(409, { error: 'Upload expired' });
            const attachment = info(id, data(entry), file); clearTimeout(entry.timer); entries.set(id, { type: 'ready', info: attachment });
            const progress: UploadProgress = { received: entry.size, attachment }; return reply(200, progress);
          } finally { await file.file.close(); }
        }
        if (request.method === 'GET' && operation === undefined && entry.type !== 'uploading') {
          const file = await openFile(entry.info.path); await file.file.close();
          try { await serveFile(response, entry.info.path, { 'Content-Type': file.image?.mimeType ?? 'application/octet-stream', 'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(entry.info.name)}`, 'Cache-Control': 'no-store' }); }
          catch (error) { throw new FileError('unreadable', error); }
          return true;
        }
        return reply(404, {});
      } catch (error) {
        if (request.aborted || response.destroyed) return true;
        if (error instanceof FileError) {
          const missing = error.cause instanceof Error && 'code' in error.cause && error.cause.code === 'ENOENT';
          return reply(error.kind === 'too_large' ? 413 : missing ? 404 : 403, { error: error.message });
        }
        return reply(500, { error: 'Attachment request failed' });
      }
    },
    async prepare(ids: readonly string[]) {
      if (ids.length > ATTACHMENT_LIMITS.files || new Set(ids).size !== ids.length) throw Error('too many or duplicate attachments');
      const images: NonNullable<Extract<RpcCommand, { type: 'prompt' }>['images']> = [], paths: string[] = [], files: Attachment[] = [];
      for (const id of ids) {
        const entry = entries.get(id);
        if (!entry || entry.type === 'uploading') throw Error('Attachment is not ready');
        const file = await openFile(entry.info.path);
        try {
          const current = info(id, entry.info, file);
          if (current.kind === 'image') {
            const bytes = Buffer.alloc(file.size); let length = 0;
            while (length < bytes.length) { const { bytesRead } = await file.file.read(bytes, length, bytes.length - length, length); if (!bytesRead) break; length += bytesRead; }
            images.push({ type: 'image', mimeType: current.mimeType, data: bytes.subarray(0, length).toString('base64') });
          } else paths.push(current.path);
          if (entries.get(id) !== entry) throw new FileError('unreadable');
          entries.set(id, { type: entry.type, info: current }); files.push(current);
        } finally { await file.file.close(); }
      }
      return { images, paths, files };
    },
    consume(ids: readonly string[], type: 'queued' | 'used') { for (const id of ids) { const entry = entries.get(id); if (entry && entry.type !== 'uploading' && entry.type !== 'used') entries.set(id, { type, info: entry.info }); } },
    restore(ids: readonly string[]) { for (const id of ids) { const entry = entries.get(id); if (entry?.type === 'queued') entries.set(id, { type: 'ready', info: entry.info }); } },
    reset() { for (const [id, entry] of entries) if (entry.type !== 'used') remove(id); },
    close() { for (const entry of entries.values()) if (entry.type === 'uploading') clearTimeout(entry.timer); },
  };
}
