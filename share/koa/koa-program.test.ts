import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir, cp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { createServer, connect } from "node:net";
import timers from "node:timers/promises";
import { Readable } from "node:stream";
import { assistant, sse } from "../pi/ko-pi-fixture.ts";

test("--help prints usage without starting pi or a webview", { timeout: 5000 }, async () => {
  const child = spawn(process.execPath, [resolve('../koa/koa.ts'), '--help', '--pi', '/does-not-exist'], { env: { PATH: '' }, stdio: 'pipe' });
  let stdout = '', stderr = '';
  child.stdout.on('data', bytes => { stdout += bytes; });
  child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'close');
  assert.equal(code, 0, stderr);
  assert.equal(stderr, '');
  assert.match(stdout, /Usage: koa/);
  assert.match(stdout, /--browser/);
  assert.match(stdout, /Other arguments go to pi/);
});

async function fixture(t: TestContext, steps: object[], env: NodeJS.ProcessEnv = {}, pi?: string, startup = true, args: string[] = [], program = resolve("../koa/koa.ts")) {
  const dir = await mkdtemp(join(tmpdir(), "koa-test-"));
  const script = join(dir, "script");
  const log = join(dir, "log");
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  await writeFile(script, steps.map(value => JSON.stringify(value)).join("\n"));
  const child = spawn(process.execPath, [program, "--browser", "--pi", pi ?? resolve("../koa/koa-fake-pi.ts"), "--no-session", ...args], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, OPEN_LOG: join(dir, "urls"), KOA_FAKE_SCRIPT: script, KOA_FAKE_LOG: log, KOA_PI_EXIT_MS: "30", ...env }, stdio: "pipe" });
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
  const { state: stream, until } = sse(Readable.from(response.body));
  const post = (path: string, body: object = {}) => fetch(base + path, { method: "POST", body: JSON.stringify(body) });
  if (startup) await until(record => record.type === "state" && (pi ? record.pi?.type === "exited" : Array.isArray(record.levels) && record.levels.length === 3));
  return { post, until, records: () => stream.records, count: () => stream.records.length, close, stdout: () => stdout, stderr: () => stderr, log: async () => (await readFile(log, "utf8")).trim().split("\n").map(line => JSON.parse(line)), base };
}
test("document loads read the current page files and recover after a failed read", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-page-reload-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../koa"), dir, { recursive: true });
  const program = join(dir, "koa.ts");
  await writeFile(program, `import ${JSON.stringify(resolve("../koa/koa.ts"))};`);
  const app = await fixture(t, [], {}, undefined, true, [], program);
  for (const name of ["koa-page.html", "koa-page.css", "koa-page.js", "koa-markdown.js"]) {
    const file = join(dir, name), marker = `reload-${name}`;
    assert.doesNotMatch(await (await fetch(app.base)).text(), new RegExp(marker));
    const original = await readFile(file, "utf8");
    await writeFile(file, original + `\n/* ${marker} */`);
    assert.match(await (await fetch(app.base)).text(), new RegExp(marker));
  }
  const file = join(dir, "koa-page.css"), style = await readFile(file, "utf8");
  await rm(file);
  const failed = await fetch(app.base);
  assert.equal(failed.status, 500);
  assert.match(await failed.text(), /ENOENT.*koa-page\.css/);
  await writeFile(file, style);
  const restored = await fetch(app.base);
  assert.equal(restored.status, 200);
  assert.match(await restored.text(), /reload-koa-page\.css/);
});

test("metrics are opt-in and record frame samples with stream counters", { timeout: 10000 }, async t => {
  const off = await fixture(t, []);
  assert.equal((await off.post("metrics", [])).status, 404);
  assert.equal(off.records().some(record => record.type === "flush"), false);
  assert.doesNotMatch(await (await fetch(off.base)).text(), /<meta name="koa-metrics"/);
  const dir = await mkdtemp(join(tmpdir(), "koa-metrics-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, "metrics.jsonl");
  const on = await fixture(t, [], {}, undefined, true, ["--metrics", file, "--metrics-mode", "frame"]);
  const flush = await on.until(record => record.type === "flush");
  assert.equal(typeof flush.t, "number");
  assert.ok(flush.bytes > 0);
  assert.match(await (await fetch(on.base)).text(), /<meta name="koa-metrics" content="frame">/);
  const samples = [{ t: flush.t, frame: flush.t + 12, bytes: 100, clockError: 0 }];
  assert.equal((await on.post("metrics", samples)).status, 200);
  const record = JSON.parse((await readFile(file, "utf8")).trim());
  assert.deepEqual(record.samples, samples);
  assert.equal(record.type, "metrics");
  assert.equal(record.opens, 1); assert.equal(record.resets, 1); assert.equal(record.cursors, 0);
  assert.equal(record.caps, 0); assert.equal(record.subscribers, 1);
  assert.ok(record.bytes > 0); assert.ok(record.highWater > 0);
  assert.equal((await on.post("metrics", [{ t: flush.t, applied: flush.t + 1, bytes: 100, clockError: 0 }])).status, 200);
  assert.equal((await on.post("metrics", [{ t: "bad" }])).status, 400);
  await rm(file); await mkdir(file);
  assert.equal((await on.post("metrics", samples)).status, 500);
  await rm(file, { recursive: true }); await writeFile(file, "");
  assert.equal((await on.post("metrics", samples)).status, 200);
  assert.deepEqual(JSON.parse((await readFile(file, "utf8")).trim()).samples, samples);
});

test("metrics mode is explicit and requires metrics", { timeout: 10000 }, async () => {
  for (const args of [["--metrics-mode", "frame"], ["--metrics-mode", "invalid"]]) {
    const child = spawn(process.execPath, [resolve("../koa/koa.ts"), ...args], { timeout: 5000 });
    let error = "";
    child.stderr.on("data", bytes => { error += bytes; });
    const [code] = await once(child, "close");
    assert.equal(code, 1);
    assert.match(error, args[1] === "frame" ? /--metrics-mode requires --metrics/ : /--metrics-mode requires applied or frame/);
  }
});

test("startup refuses prompts until the snapshot response is applied", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-startup-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const gate = join(dir, "gate");
  const server = createServer();
  await new Promise<void>(resolve => server.listen(gate, resolve));
  t.after(() => server.close());
  const connected = once(server, "connection");
  const pi = join(dir, "pi.mjs");
  await writeFile(pi, `#!/usr/bin/env node
import { connect } from 'node:net';
let buffer = '', snapshot, answered = false, released = false;
const complete = () => { if (snapshot && answered && released) { send(snapshot, {messages:[{role:'user',content:'snapshot',timestamp:1}]}); snapshot = undefined; } };
const send = (v, data) => process.stdout.write(JSON.stringify({type:'response',command:v.type,id:v.id,success:true,data})+'\\n');
process.stdin.on('data', bytes => {
  buffer += bytes;
  let end;
  while ((end = buffer.indexOf('\\n')) >= 0) {
    const v = JSON.parse(buffer.slice(0,end)); buffer = buffer.slice(end+1);
    if (v.type === 'get_messages') {
      snapshot = v;
      process.stdout.write(JSON.stringify({type:'extension_ui_request',method:'select',id:'startup-dialog',title:'Continue?',options:['Yes','No']})+'\\n');
      const socket = connect(process.env.KOA_STARTUP_GATE);
      socket.on('data', () => { released = true; complete(); socket.end(); });
    } else if (v.type === 'extension_ui_response') { answered = v.id === 'startup-dialog' && v.value === 'Yes'; complete(); }
    else send(v, v.type === 'get_available_thinking_levels' ? {levels:['off','low','high']} : {});
  }
});
process.stdin.on('end', () => process.exit(0));
`, { mode: 0o700 });
  const app = await fixture(t, [], { KOA_STARTUP_GATE: gate }, pi, false);
  const [socket] = await connected;
  t.after(() => socket.destroy());
  const early = await app.post("prompt", { text: "too early", mode: "prompt" });
  assert.equal(early.status, 409);
  assert.match((await early.json()).error, /starting/);
  for (const [route, body] of [["model", {provider:"test",modelId:"early"}], ["thinking", {level:"high"}], ["queue/clear", {}], ["abort", {}], ["editor/ack", {id:"early"}]] as const) {
    const result = await app.post(route, body);
    assert.equal(result.status, 409, route);
    assert.match((await result.json()).error, /starting/, route);
  }
  const models = await fetch(app.base + "models");
  assert.equal(models.status, 409);
  assert.match((await models.json()).error, /starting/);
  const startup = await app.until(record => record.type === "state" && record.dialogs?.[0]?.id === "startup-dialog");
  assert.equal(startup.pi.type, "starting");
  const afterDialog = app.count();
  assert.equal((await app.post("dialog", {id:"startup-dialog",value:"Yes"})).status, 200);
  assert.equal((await app.post("prompt", {text:"still starting",mode:"prompt"})).status, 409);
  socket.write("ready");
  const ready = await app.until(record => record.type === "state" && record.pi?.type === "ready", afterDialog);
  assert.equal(ready.dialogs.length, 0);
  const page = await (await fetch(app.base + "items?before=99")).json();
  assert.equal(page.items[0].text, "snapshot");
  assert.equal((await app.post("prompt", { text: "ready", mode: "prompt" })).status, 200);
});

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
  const timed = await (await fetch(app.base + "items?before=99")).json();
  const thinking = timed.items[0].blocks[0];
  assert.equal(thinking.type, "thinking");
  assert.equal(typeof thinking.started, "number");
  assert.equal(typeof thinking.ended, "number");
  assert.ok(thinking.ended >= thinking.started);
  assert.equal(typeof timed.items[0].ended, "number");
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

test("queue, model, thinking and dialog routes carry RPC state", { timeout: 10000 }, async t => {
  const dialog = { type: "extension_ui_request", method: "select", id: "dialog-1", title: "Pick", options: ["Yes", "No"] };
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "agent_start" },
      { type: "queue_update", steering: ["steer"], followUp: ["later"] },
      dialog,
      { ...dialog, id: "dialog-2", method: "confirm", message: "Really?" },
      { type: "extension_ui_request", method: "notify", id: "notify", message: "Notice", notifyType: "warning" },
      { type: "extension_ui_request", method: "setStatus", id: "status", statusKey: "check", statusText: "Checking" },
      { type: "extension_ui_request", method: "set_editor_text", id: "editor", text: "Draft" },
    ] },
    { type: "wait", command: "clear_queue", data: { steering: ["steer"], followUp: ["later"] } },
    { type: "wait", command: "get_available_models", data: { models: [{ id: "new", provider: "test" }] } },
    { type: "wait", command: "set_model", data: { id: "new", provider: "test" } },
    { type: "wait", command: "set_thinking_level", events: [{ type: "thinking_level_changed", level: "high" }] },
    { type: "wait", command: "extension_ui_response" },
    { type: "wait", command: "extension_ui_response", events: [{ ...dialog, id: "dialog-3", method: "input" }] },
    { type: "wait", command: "extension_ui_response", events: [{ ...dialog, id: "dialog-4", method: "editor" }] },
    { type: "wait", command: "extension_ui_response" },

  ]);
  assert.equal((await app.post("prompt", { text: "go", mode: "prompt" })).status, 200);
  const state = await app.until(record => record.type === "state" && record.dialogs?.length === 2);
  assert.deepEqual(state.dialogs, [dialog, { ...dialog, id: "dialog-2", method: "confirm", message: "Really?" }]);
  await app.until(record => record.type === "notify" && record.message === "Notice" && record.level === "warning");
  await app.until(record => record.type === "state" && record.editor?.text === "Draft");
  await app.until(record => record.type === "state" && record.statuses?.check === "Checking");
  assert.match(app.stdout(), /state=blocked:app=pi:kind=question/);
  const controller = new AbortController();
  const reloaded = await fetch(app.base + "events", { signal: controller.signal });
  assert.ok(reloaded.body);
  const reload = sse(Readable.from(reloaded.body));
  const reloadedState = await reload.until(record => record.type === "state");
  assert.deepEqual(reloadedState.dialogs, state.dialogs);
  assert.deepEqual(reloadedState.editor, { id: "editor", text: "Draft" });
  controller.abort();
  assert.equal((await app.post("editor/ack", { id: "old" })).status, 200);
  const editorAfter = app.count();
  assert.equal((await app.post("editor/ack", { id: "editor" })).status, 200);
  await app.until(record => record.type === "state" && !record.editor, editorAfter);
  assert.deepEqual(await (await app.post("queue/clear")).json(), { steering: ["steer"], followUp: ["later"] });
  assert.deepEqual(await (await fetch(app.base + "models")).json(), { models: [{ id: "new", provider: "test" }] });
  assert.equal((await app.post("model", { provider: "test", modelId: "new" })).status, 200);
  await app.until(record => record.type === "state" && record.model?.provider === "test" && record.model.id === "new");
  assert.equal((await app.post("thinking", { level: "max" })).status, 409);
  assert.equal((await app.post("thinking", { level: "high" })).status, 200);
  assert.equal((await app.post("dialog", { id: "dialog-1", value: "Yes" })).status, 200);
  assert.equal((await app.post("dialog", { id: "dialog-1", value: "Yes" })).status, 409);
  assert.equal((await app.post("dialog", { id: "dialog-2", confirmed: true })).status, 200);
  await app.until(record => record.type === "state" && record.dialogs[0]?.id === "dialog-3");
  assert.equal((await app.post("dialog", { id: "dialog-3", value: "typed" })).status, 200);
  await app.until(record => record.type === "state" && record.dialogs[0]?.id === "dialog-4");
  assert.equal((await app.post("dialog", { id: "dialog-4", cancelled: true })).status, 200);
  const commands = await app.log();
  assert.deepEqual(commands.find(record => record.type === "set_model"), { type: "set_model", provider: "test", modelId: "new", id: commands.find(record => record.type === "set_model").id });
  assert.deepEqual(commands.filter(record => record.type === "extension_ui_response").map(({ id, value, confirmed }) => ({ id, value, confirmed })), [{ id: "dialog-1", value: "Yes", confirmed: undefined }, { id: "dialog-2", value: undefined, confirmed: true }, { id: "dialog-3", value: "typed", confirmed: undefined }, { id: "dialog-4", value: undefined, confirmed: undefined }]);
});

test("session headers keep the startup cwd for a missing file and report invalid files", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-session-header-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const invalid = join(dir, "invalid.jsonl");
  await writeFile(invalid, "not json\n");
  for (const [sessionFile, reports] of [[join(dir, "missing.jsonl"), false], [invalid, true], [dir, true]] as const) {
    const app = await fixture(t, [{ type: "respond", command: "get_state", data: { sessionFile } }]);
    const state = await app.until(record => record.type === "state" && record.pi?.type === "ready");
    assert.equal(state.cwd, process.cwd());
    assert.equal(app.stderr().includes("koa: session header:"), reports, app.stderr());
  }
});

test("restart keeps the saved picker selection, harness and runtime", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-restart-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const session = join(dir, "last.jsonl");
  await writeFile(session, JSON.stringify({ cwd: dir }) + "\n");
  const selection = join(dir, "selection");
  await writeFile(selection, JSON.stringify({}));
  const app = await fixture(t, [
    { type: "respond", command: "get_state", data: { sessionFile: session } },
    { type: "wait", command: "set_model", data: { provider: "test", id: "picked" } },
    { type: "wait", command: "set_thinking_level", events: [{ type: "thinking_level_changed", level: "high" }] },
    { type: "wait", command: "prompt" }, { type: "exit", code: 7 },
  ], { KOA_FAKE_SELECTION_FILE: selection }, undefined, true, ["--runtime", "remote", "--session", "old.jsonl", "--fork", "source.jsonl", "--model", "test/original", "--thinking", "low"]);
  assert.equal((await app.post("pi/start")).status, 409);
  assert.equal((await app.post("model", { provider: "test", modelId: "picked" })).status, 200);
  assert.equal((await app.post("thinking", { level: "high" })).status, 200);
  await app.post("prompt", { text: "exit", mode: "prompt" });
  await app.until(record => record.type === "state" && record.pi?.type === "exited");
  const after = app.count();
  assert.equal((await app.post("pi/start")).status, 200);
  const restarted = await app.until(record => record.type === "state" && record.pi?.type === "ready" && record.levels?.length === 3, after);
  assert.deepEqual(restarted.model, {provider:"test",id:"picked"});
  assert.equal(restarted.thinking, "high");
  const argv = (await app.log()).filter(record => record.type === "argv").map(record => record.args);
  assert.equal(argv.length, 2);
  assert.deepEqual(argv[1], ["--mode", "rpc", "--extension", resolve("ko-pi.ts"), "--harness", "koa-browser", "--runtime", "remote", "--session", session]);
});

test("spawn failure is distinct from an exit code", { timeout: 10000 }, async t => {
  const app = await fixture(t, [], {}, "/koa-no-such-pi");
  const state = await app.until(record => record.type === "state" && record.pi?.type === "exited");
  assert.match(state.pi.failed, /ENOENT/);
  assert.equal("exited" in state.pi, false);
  assert.equal((await app.post("abort")).status, 409);
});

test("pi crash keeps koa serving its transcript and exit state", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "wait", command: "prompt" }, { type: "raw", text: "not json\r\n" }, { type: "stderr", text: "old1\nold2\na\nb\nc\npar" }, { type: "stderr", text: "tial\nlast\n" }, { type: "exit", code: 7 }]);
  await app.post("prompt", { text: "go", mode: "prompt" });
  const state = await app.until(record => record.type === "state" && record.pi?.type === "exited");
  assert.equal(state.pi.exited, 7);
  assert.equal(typeof state.pi.at, "number");
  assert.equal(state.pi.stderr, "a\nb\nc\npartial\nlast");
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
