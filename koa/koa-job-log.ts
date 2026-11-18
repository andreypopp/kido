import { constants } from "node:fs";
import { open } from "node:fs/promises";
import type { LogChunk } from "./koa-records.ts";

export const LOG_CHUNK = 256 * 1024;

export async function readLog(path: string, start: number, end: number, signal: AbortSignal): Promise<LogChunk> {
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end - start > LOG_CHUNK) throw new RangeError("the log range is not valid");
  signal.throwIfAborted();
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const bytes = Buffer.alloc(end - start);
    for (let done = 0; done < bytes.length;) {
      signal.throwIfAborted();
      const { bytesRead } = await file.read(bytes, done, bytes.length - done, start + done);
      if (bytesRead === 0) throw new Error("unexpected end of file in the log");
      done += bytesRead;
    }
    return { start, end, data: bytes.toString("base64") };
  } finally { await file.close(); }
}
