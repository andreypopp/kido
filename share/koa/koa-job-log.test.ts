import { test } from "node:test";
import assert from "node:assert/strict";
import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LOG_CHUNK, readLog } from "./koa-job-log.ts";

async function logFile(t: { after(hook: () => unknown): void }, bytes: Buffer): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "koa-job-log-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "job.log");
  await writeFile(path, bytes);
  return path;
}

const pattern = (size: number) => Buffer.from(Array.from({ length: size }, (_, i) => (i * 7 + 3) & 255));
const decode = (chunk: { data: string }) => Buffer.from(chunk.data, "base64");

test("a range reads exactly its half-open bytes as base64", async t => {
  const bytes = pattern(1000);
  const path = await logFile(t, bytes);
  const chunk = await readLog(path, 10, 500, new AbortController().signal);
  assert.deepEqual({ start: chunk.start, end: chunk.end }, { start: 10, end: 500 });
  assert.deepEqual(decode(chunk), bytes.subarray(10, 500));
  assert.deepEqual(await readLog(path, 7, 7, new AbortController().signal), { start: 7, end: 7, data: "" });
});

test("backward steps of the chunk size join to the exact file, with a short last prefix", async t => {
  const bytes = pattern(LOG_CHUNK * 2 + 4321);
  const path = await logFile(t, bytes);
  const parts: Buffer[] = [];
  for (let before = bytes.length; before > 0;) {
    const chunk = await readLog(path, Math.max(0, before - LOG_CHUNK), before, new AbortController().signal);
    assert.ok(chunk.end - chunk.start <= LOG_CHUNK);
    parts.unshift(decode(chunk));
    before = chunk.start;
  }
  assert.equal(parts.length, 3);
  assert.equal(parts[0]?.length, 4321);
  assert.deepEqual(Buffer.concat(parts), bytes);
});

test("a range over the limit, negative, unsafe or reversed is refused", async t => {
  const path = await logFile(t, pattern(LOG_CHUNK + 10));
  const signal = new AbortController().signal;
  await assert.rejects(readLog(path, 0, LOG_CHUNK + 1, signal), /range/);
  await assert.doesNotReject(readLog(path, 0, LOG_CHUNK, signal));
  await assert.rejects(readLog(path, -1, 5, signal), /range/);
  await assert.rejects(readLog(path, 5, 4, signal), /range/);
  await assert.rejects(readLog(path, 0, Number.MAX_SAFE_INTEGER + 2, signal), /range/);
  await assert.rejects(readLog(path, 0.5, 3, signal), /range/);
});

test("a range past the end of the file reports it, and a missing file rejects", async t => {
  const path = await logFile(t, pattern(100));
  await assert.rejects(readLog(path, 50, 200, new AbortController().signal), /end of file/);
  await assert.rejects(readLog(path + ".gone", 0, 1, new AbortController().signal), (error: NodeJS.ErrnoException) => error.code === "ENOENT");
});

test("an aborted read rejects, and bytes appended meanwhile do not change a bounded range", async t => {
  const path = await logFile(t, pattern(100));
  const controller = new AbortController();
  controller.abort(new Error("gone"));
  await assert.rejects(readLog(path, 0, 10, controller.signal), /gone/);
  const pending = readLog(path, 0, 100, new AbortController().signal);
  await appendFile(path, "tail");
  assert.deepEqual(decode(await pending), pattern(100));
});
