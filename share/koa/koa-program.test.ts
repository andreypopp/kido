import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { createServer, connect } from "node:net";
import timers from "node:timers/promises";
import { Readable } from "node:stream";
import { assistant, ndjson } from "../pi/ko-pi-fixture.ts";

async function fixture(t: TestContext, steps: object[], env: NodeJS.ProcessEnv = {}, pi?: string) {
  const dir = await mkdtemp(join(tmpdir(), "koa-test-"));
  const script = join(dir, "script");
  const log = join(dir, "log");
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  await writeFile(script, steps.map(value => JSON.stringify(value)).join("\n"));
  const child = spawn(process.execPath, [resolve("../koa/koa.ts"), "--browser", "--pi", pi ?? resolve("../koa/koa-fake-pi.ts"), "--no-session"], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, OPEN_LOG: join(dir, "urls"), KOA_FAKE_SCRIPT: script, KOA_FAKE_LOG: log, KOA_PI_EXIT_MS: "30", ...env }, stdio: "pipe" });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", bytes => { stdout += bytes; });
  let ready: (url: string) => void = () => {};
  const url = new Promise<string>(resolve => { ready = resolve; });
  child.stderr.on("data", bytes => { stderr += bytes; const match = stderr.match(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/); if (match?.[1]) ready(match[1]); });
  const close = once(child, "close");
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM"); await close; await rm(dir, { recursive: true, force: true }); });
  const base = await url;
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(base + "events", { signal: controller.signal });
  assert.ok(response.body);
  const { state: stream, until } = ndjson(Readable.from(response.body));
  const post = (path: string, body: object = {}) => fetch(base + path, { method: "POST", body: JSON.stringify(body) });
  await until(record => record.type === "state" && (pi ? !!record.pi : Array.isArray(record.levels) && record.levels.length === 3));
  return { post, until, count: () => stream.records.length, close, stdout: () => stdout, stderr: () => stderr, log: async () => (await readFile(log, "utf8")).trim().split("\n").map(line => JSON.parse(line)), base };
}
const assistantMessage = { ...assistant("stop"), api: "test", provider: "test", model: "test", usage: {}, timestamp: 42 };

test("RPC deltas, authoritative ends, tools, state, status and command correlation", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "agent_start" },
      { type: "message_start", message: assistantMessage },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "text_start", contentIndex: 0 } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "hello\u2028world" } },
      { type: "queue_update", steering: ["next"], followUp: [] },
    ], data: { disposition: "started" } },
    { type: "wait", command: "prompt", data: { disposition: "queued" } },
    { type: "wait", command: "prompt", data: { disposition: "handled" } },
    { type: "wait", command: "abort", events: [
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "authoritative" } },
      { type: "message_end", message: { ...assistantMessage, content: [{ type: "text", text: "final" }], stopReason: "error", errorMessage: "failure\nsecret" } },
      { type: "agent_settled", aborted: false },
      { type: "thinking_level_changed", level: "high" },
      { type: "session_info_changed", name: "Renamed" },
    ] },
  ]);
  const started = await app.post("prompt", { text: "go", mode: "steer" });
  assert.equal(started.status, 200);
  assert.deepEqual(await started.json(), { disposition: "started" });
  const item = await app.until(record => ["item", "patch"].includes(String(record.type)) && JSON.stringify(record).includes("hello\u2028world"));
  assert.match(JSON.stringify(item), /hello\\u2028world|hello\u2028world/);
  assert.deepEqual(await (await app.post("prompt", { text: "steering", mode: "steer" })).json(), { disposition: "queued" });
  assert.deepEqual(await (await app.post("prompt", { text: "later", mode: "follow_up" })).json(), { disposition: "handled" });
  assert.equal((await app.post("abort")).status, 200);
  const patch = await app.until(record => record.type === "patch" && JSON.stringify(record).includes("final"));
  assert.match(JSON.stringify(patch), /final/);
  const state = await app.until(record => record.type === "state" && record.thinking === "high");
  assert.deepEqual(state.queue, { steering: ["next"], followUp: [] });
  assert.deepEqual(state.context, { tokens: 123, window: 1000, percent: 12.3 });
  await app.until(record => record.type === "state" && record.name === "Renamed");
  assert.match(app.stdout(), /\x1b\]7501;state=working:app=pi/);
  assert.match(app.stdout(), /\x1b\]7501;state=error:app=pi:msg=ZmFpbHVyZQ==/);
  assert.match(app.stdout(), /\x1b\]0;koa - Renamed - /);
  const commands = (await app.log()).filter(record => record.id);
  assert.equal(new Set(commands.map(record => record.id)).size, commands.length);
  assert.deepEqual(commands.filter(record => ["prompt", "abort"].includes(record.type)).map(record => record.type), ["prompt", "prompt", "prompt", "abort"]);
  assert.deepEqual(commands.filter(record => record.type === "prompt").map(record => record.streamingBehavior), [undefined, "steer", "followUp"]);
  assert.equal((await fetch(app.base)).status, 200);
  assert.equal((await app.post("quit")).status, 200);
  await app.close;
});

test("tool deltas, end replacement, timing and compaction rebuild", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "agent_start" },
      { type: "message_start", message: assistantMessage },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "thinking_start", contentIndex: 0 } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "thought" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "thinking_end", contentIndex: 0, content: "replaced thought" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_start", contentIndex: 1, id: "tool", toolName: "read" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_delta", contentIndex: 1, delta: "{\"path\":\"a\"}" } },
      { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_end", contentIndex: 1, toolCall: { type: "toolCall", id: "tool", name: "read", arguments: { path: "b" } } } },
      { type: "tool_execution_start", toolCallId: "tool" },
      { type: "tool_execution_update", toolCallId: "tool", partialResult: { content: [{ type: "text", text: "partial" }] } },
      { type: "tool_execution_end", toolCallId: "tool", result: { content: [{ type: "text", text: "result" }] }, isError: false, durationMs: 17 },
      { type: "message_end", message: { ...assistantMessage, content: [{ type: "thinking", thinking: "final thought" }, { type: "toolCall", id: "tool", name: "read", arguments: { path: "b" } }] } },
      { type: "agent_settled", aborted: false },
    ] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end" }] },
    { type: "wait", command: "get_messages", data: { messages: [{ role: "user", content: "rebuilt", timestamp: 99 }] } },
  ]);
  await app.post("prompt", { text: "go", mode: "prompt" });
  const record = await app.until(record => record.type === "patch" && JSON.stringify(record).includes('"durationMs":17'));
  const text = JSON.stringify(record);
  assert.match(text, /result/);
  assert.match(text, /durationMs":17/);
  assert.match(text, /started":\d+/);
  assert.match(text, /ended":\d+/);
  await app.until(record => record.type === "patch" && JSON.stringify(record).includes("final thought"));
  await app.until(record => record.type === "state" && record.working === false && record.aborted === false);
  assert.match(app.stdout(), /\x1b\]7501;state=done:app=pi/);
  await app.post("abort");
  const reset = await app.until(record => record.type === "reset" && JSON.stringify(record).includes("rebuilt"));
  assert.match(JSON.stringify(reset), /"at":99/);
});

test("a rebuild response is applied before later records in the same byte chunk", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "get_messages", data: { messages: [{ role: "user", content: "before", timestamp: 1 }] }, after: [{ type: "message_end", message: { role: "user", content: "after", timestamp: 2 } }] }]);
  const page = await (await fetch(app.base + "items?before=99")).json();
  assert.deepEqual(page.items.map((item: { text: string }) => item.text), ["before", "after"]);
});

test("spawn failure is distinct from an exit code", { timeout: 10000 }, async t => {
  const app = await fixture(t, [], {}, "/koa-no-such-pi");
  const state = await app.until(record => record.type === "state" && !!record.pi);
  assert.match(state.pi.failed, /ENOENT/);
  assert.equal("exited" in state.pi, false);
  assert.equal((await app.post("abort")).status, 409);
});

test("pi crash keeps koa serving its transcript and exit state", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "raw", text: "not json\r\n" }, { type: "exit", code: 7 }]);
  await app.post("prompt", { text: "go", mode: "prompt" });
  const state = await app.until(record => record.type === "state" && !!record.pi);
  assert.deepEqual(state.pi, { exited: 7 });
  assert.match(app.stdout(), /\x1b\]7501;state=clear\x1b\\/);
  assert.match(app.stderr(), /koa: pi stdout: not json/);
  assert.equal((await app.post("abort")).status, 409);
  assert.equal((await fetch(app.base)).status, 200);
});

test("concurrent large commands cross pipe back-pressure without lost ids or bytes", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-pressure-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "pressure.mjs");
  const pressureLog = join(dir, "writes");
  await writeFile(hook, `import { ChildProcess } from "node:child_process";
    import { appendFileSync } from "node:fs";
    const spawn = ChildProcess.prototype.spawn;
    ChildProcess.prototype.spawn = function(...args) {
      const result = spawn.apply(this, args);
      if (this.spawnargs.includes("rpc") && this.stdin) {
        const input = this.stdin;
        const write = input.write;
        let blocked = false;
        input.on("drain", () => { blocked = false; });
        input.write = function(...args) {
          if (blocked) throw Error("command written before drain");
          const ready = write.apply(this, args);
          if (!ready) { blocked = true; appendFileSync(process.env.KOA_PRESSURE_LOG, "blocked\\n"); }
          return ready;
        };
      }
      return result;
    };`);
  const app = await fixture(t, [], { NODE_OPTIONS: `--import=${hook}`, KOA_PRESSURE_LOG: pressureLog });
  const texts = ["a", "b", "c"].map(prefix => prefix.repeat(900 * 1024));
  const responses = await Promise.all(texts.map(text => app.post("prompt", { text, mode: "prompt" })));
  assert.deepEqual(responses.map(response => response.status), [200, 200, 200]);
  assert.equal((await app.post("abort")).status, 200);
  assert.equal((await app.post("prompt", { text: "x".repeat(1500 * 1024), mode: "prompt" })).status, 413);
  const invalid = await app.post("prompt", { text: "", mode: "prompt" });
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: "A non-empty text and prompt, steer or follow_up mode are required" });
  const commands = await app.log();
  const prompts = commands.filter(command => command.type === "prompt");
  assert.deepEqual(prompts.map(command => command.message).sort(), texts.sort());
  const ids = commands.filter(command => command.id).map(command => command.id);
  assert.equal(new Set(ids).size, ids.length);
  assert.ok((await readFile(pressureLog, "utf8")).split("\n").filter(Boolean).length >= 3);
});

test("tool argument JSON is parsed once per flush, not per delta", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-json-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "json.mjs");
  const log = join(dir, "parses");
  await writeFile(hook, `import { appendFileSync } from "node:fs";
    const parse = JSON.parse;
    JSON.parse = function(text, ...args) {
      if (text.startsWith('{"instrumented":')) appendFileSync(process.env.KOA_PARSE_LOG, "parse\\n");
      return parse.call(this, text, ...args);
    };`);
  const app = await fixture(t, [{ type: "wait", command: "prompt", events: [
    { type: "message_start", message: assistantMessage },
    { type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_start", contentIndex: 0, id: "args", toolName: "read" } },
    ...['{"instrumented":', ...Array.from({ length: 98 }, () => " "), "1}"].map(delta => ({ type: "message_update", usage: {}, assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta } })),
  ] }], { NODE_OPTIONS: `--import=${hook}`, KOA_PARSE_LOG: log });
  await app.post("prompt", { text: "go", mode: "prompt" });
  await app.until(record => record.type === "patch" && JSON.stringify(record).includes("instrumented"));
  assert.equal(await readFile(log, "utf8"), "parse\n");
});

test("HTTP UTF-8 chunks reach pi without replacement characters", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-body-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "chunks.mjs");
  await writeFile(hook, `import { IncomingMessage } from "node:http";
    const read = IncomingMessage.prototype[Symbol.asyncIterator];
    IncomingMessage.prototype[Symbol.asyncIterator] = async function* () {
      for await (const bytes of read.call(this)) for (let i = 0; i < bytes.length; i++) yield bytes.subarray(i, i + 1);
    };`);
  const app = await fixture(t, [], { NODE_OPTIONS: `--import=${hook}` });
  const text = "héllo 🌎";
  assert.equal((await app.post("prompt", { text, mode: "prompt" })).status, 200);
  assert.equal((await app.log()).find(record => record.type === "prompt").message, text);
});

test("manual compaction restores status and retries stay working", { timeout: 10000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [{ type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: false, willRetry: false }] },
    { type: "wait", command: "prompt", events: [{ type: "agent_start" }, { type: "agent_settled", aborted: false }, { type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: true, willRetry: false }] },
    { type: "wait", command: "prompt", events: [{ type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: false, willRetry: false, errorMessage: "compact failed\nmore" }] },
    { type: "wait", command: "prompt", events: [{ type: "compaction_start", reason: "manual" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "manual", aborted: false, willRetry: false }] },
    { type: "wait", command: "prompt", events: [{ type: "agent_start" }, { type: "compaction_start", reason: "overflow" }] },
    { type: "wait", command: "abort", events: [{ type: "compaction_end", reason: "overflow", aborted: false, willRetry: true }, { type: "queue_update", steering: ["retry"], followUp: [] }] },
  ]);
  for (const expected of ["idle", "done", "error", "error"]) {
    let after = app.count();
    assert.equal((await app.post("prompt", { text: "compact", mode: "prompt" })).status, 200);
    await app.until(record => record.type === "state" && record.working === true, after);
    after = app.count();
    assert.equal((await app.post("abort")).status, 200);
    await app.until(record => record.type === "state" && record.working === false, after);
    assert.match(app.stdout().split("\x1b]7501;").at(-1) ?? "", new RegExp(`^state=${expected}:`));
  }
  assert.equal((await app.post("prompt", { text: "retry", mode: "prompt" })).status, 200);
  await app.post("abort");
  const state = await app.until(record => record.type === "state" && JSON.stringify(record.queue).includes("retry"));
  assert.equal(state.working, true);
  assert.match(app.stdout().split("\x1b]7501;").at(-1) ?? "", /^state=working:/);
});

test("pi exit does not wait for a descendant that holds its pipes", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-pipes-"));
  const gate = join(dir, "gate");
  const server = createServer();
  await new Promise<void>(resolve => server.listen(gate, resolve));
  const connected = once(server, "connection");
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "exit", code: 7 }], { KOA_FAKE_KEEP_PIPES: gate });
  await app.post("prompt", { text: "exit", mode: "prompt" });
  const [peer] = await connected;
  try {
    await app.post("quit");
    assert.equal(await Promise.race([app.close.then(() => true), timers.setTimeout(500, false)]), true);
  } finally {
    peer.end("release");
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test("quit exits at its deadline when the reply stalls and the client never reads", { timeout: 6000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-quit-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "stall.mjs");
  await writeFile(hook, `import { ServerResponse } from "node:http";
    const end = ServerResponse.prototype.end;
    ServerResponse.prototype.end = function(...args) {
      return this.req.url === "/quit" ? this : end.apply(this, args);
    };`);
  const app = await fixture(t, [], { NODE_OPTIONS: `--import=${hook}` });
  const url = new URL(app.base);
  const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`POST /quit HTTP/1.1\r\nHost: ${url.host}\r\nContent-Length: 2\r\n\r\n{}`));
  socket.pause();
  socket.on("error", () => {});
  t.after(() => socket.destroy());
  assert.equal(await Promise.race([app.close.then(() => true), timers.setTimeout(3000, false, { ref: false })]), true);
});

test("shutdown closes stdin before group TERM and KILL", { timeout: 10000 }, async t => {
  const app = await fixture(t, [], { KOA_FAKE_STUBBORN: "1" });
  assert.equal((await app.post("quit")).status, 200);
  await app.close;
  const log = await app.log();
  const eof = log.findIndex(record => record.type === "stdin_end");
  const term = log.findIndex(record => record.type === "signal");
  assert.ok(eof >= 0 && term > eof);
});
