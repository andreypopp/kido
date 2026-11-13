import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { createServer, connect } from "node:net";
import timers from "node:timers/promises";
import { fixture, assistantMessage } from "./koa-program-fixture.ts";
import { get, ofType } from "./koa-agent-fixture.ts";
test('a missing pi fails package discovery before the webview', { timeout: 5000 }, async () => {
  const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), '--browser', '--pi', '/koa-no-such-pi']);
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  assert.equal((await once(child, 'close'))[0], 1);
  assert.match(stderr, /koa: cannot find pi's package from \/koa-no-such-pi/);
  assert.doesNotMatch(stderr, /koa: http:/);
});

test("clean pi exit closes koa", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "exit", code: 0 }]);
  await app.post("prompt", { text: "quit", mode: "prompt", attachments: [] });
  const result = await Promise.race([app.close, timers.setTimeout(1000, "still running", { ref: false })]);
  assert.deepEqual(result, [0, null]);
  await assert.rejects(fetch(app.base));
});

test("pi crash keeps koa serving its transcript and exit state", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "raw", text: "not json\r\n" }, { type: "stderr", text: "old1\nold2\na\nb\nc\npar" }, { type: "stderr", text: "tial\nlast\n" }, { type: "exit", code: 7 }]);
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
  const state = await app.until(ofType("state", record => record.pi?.type === "exited"));
  assert.equal(get(state.pi, "exited"), 7);
  assert.equal(typeof get(state.pi, "at"), "number");
  assert.equal(get(state.pi, "stderr"), "a\nb\nc\npartial\nlast");
  assert.match(app.stdout(), /\x1b\]7501;state=clear\x1b\\/);
  assert.match(app.stderr(), /koa: pi stdout: not json/);
  assert.equal((await app.post("abort")).status, 409);
  assert.equal((await fetch(app.base)).status, 200);
  assert.equal(state.sessionFile, undefined);
  assert.equal((await app.post("pi/start")).status, 200);
  const args = (await app.log()).filter(record => record.type === "argv").map(record => record.args);
  assert.deepEqual(args[1], args[0]);
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
  const responses = await Promise.all(texts.map(text => app.post("prompt", { text, mode: "prompt", attachments: [] })));
  assert.deepEqual(responses.map(response => response.status), [200, 200, 200]);
  assert.equal((await app.post("abort")).status, 200);
  assert.equal((await app.post("prompt", { text: "x".repeat(1500 * 1024), mode: "prompt", attachments: [] })).status, 413);
  const invalid = await app.post("prompt", { text: "", mode: "prompt", attachments: [] });
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: "Text or attachments and prompt, steer or follow_up mode are required" });
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
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
  await app.until(ofType("patch", record => JSON.stringify(record).includes("instrumented")));
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
  assert.equal((await app.post("prompt", { text, mode: "prompt", attachments: [] })).status, 200);
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
    assert.equal((await app.post("prompt", { text: "compact", mode: "prompt", attachments: [] })).status, 200);
    await app.until(ofType("state", record => record.working === true), after);
    after = app.count();
    assert.equal((await app.post("abort")).status, 200);
    await app.until(ofType("state", record => record.working === false), after);
    assert.match(app.stdout().split("\x1b]7501;").at(-1) ?? "", new RegExp(`^state=${expected}:`));
  }
  assert.equal((await app.post("prompt", { text: "retry", mode: "prompt", attachments: [] })).status, 200);
  await app.post("abort");
  const state = await app.until(ofType("state", record => JSON.stringify(record.queue).includes("retry")));
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
  await app.post("prompt", { text: "exit", mode: "prompt", attachments: [] });
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
  const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`POST /quit HTTP/1.1\r\nHost: ${url.host}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}`));
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
