import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir, cp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { createServer } from "node:net";
import { Readable } from "node:stream";
import { sse, selfPane, agentPane, pollUntil } from "../pi/ko-pi-fixture.ts";
import { linkFakeKo, fixture, assistantMessage } from "./koa-program-fixture.ts";
test('completion limits active searches and kills expired children', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-search-limit-'); t.after(() => rm(dir, { recursive: true, force: true }));
  const gate = join(dir, 'gate'), fd = join(dir, 'fd');
  await writeFile(fd, `#!${process.execPath}\nrequire('node:net').connect(${JSON.stringify(gate)}).on('connect',function(){this.write('ready')});\n`, { mode: 0o700 });
  const sockets = new Set<import('node:net').Socket>(); let accepted = 0;
  const server = createServer(socket => { accepted++; sockets.add(socket); socket.on('data', () => {}); socket.once('close', () => sockets.delete(socket)); });
  server.listen(gate); await once(server, 'listening'); t.after(() => { for (const socket of sockets) socket.destroy(); server.close(); });
  const app = await fixture(t, [], { KOA_FD: fd }, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  const controller = new AbortController();
  const first = fetch(app.base + 'complete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionId: 'fake', text: '@', pos: 1 }), signal: controller.signal });
  const rejected = assert.rejects(first, { name: 'AbortError' });
  let secondEnded = false;
  const second = app.post('complete', { text: '@', pos: 1 }).then(response => { secondEnded = true; return response; });
  await pollUntil(() => sockets.size === 4, 1500, 'four fd children');
  const capped = await app.post('complete', { text: '@', pos: 1 });
  assert.equal(capped.status, 200); assert.deepEqual((await capped.json()).options, []); assert.equal(accepted, 4);
  controller.abort(); await rejected;
  await pollUntil(() => sockets.size === 2, 1000, 'disconnect releases children');
  const replacements: Promise<Response>[] = [];
  let retry = true;
  await pollUntil(() => {
    if (accepted > 4) return true;
    if (retry) {
      retry = false;
      const replacement = app.post('complete', { text: '@', pos: 1 });
      replacements.push(replacement);
      void replacement.then(() => { retry = true; });
    }
    return false;
  }, 1000, 'disconnect releases capacity');
  assert.equal(secondEnded, false);
  assert.deepEqual((await (await second).json()).options, []);
  for (const replacement of replacements) assert.deepEqual((await (await replacement).json()).options, []);
  await pollUntil(() => sockets.size === 0, 1000, 'expired children ended');
});

test("completion reads pi commands on every request and validates offsets", { timeout: 10000 }, async t => {
  const app = await fixture(t, [{ type: "respond", command: "get_commands", data: { commands: [{ name: "find", description: "Find a file", source: "extension" }] } }]);
  for (let i = 0; i < 2; i++) {
    const response = await app.post("complete", { text: "/fi", pos: 3 });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { type: 'prompt', from: 0, to: 3, options: [{ label: "/find", detail: "Find a file", insert: "/find ", kind: "command", source: "extension", matched: [1, 2] }] });
  }
  assert.equal((await app.log()).filter(record => record.type === "get_commands").length, 2);
  for (const body of [{ text: "@", pos: -1 }, { text: "@", pos: 2 }, { text: "@", pos: 0.5 }, { text: 1, pos: 0 }]) assert.equal((await app.post("complete", body)).status, 400);
});

test("completion serves files and live agents during startup and cancels its fd child", { timeout: 10000 }, async t => {
  const dir = await mkdtemp("/tmp/koa-completion-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  const layout = join(dir, "panes.json"), gate = join(dir, "gate"), fd = join(dir, "fd");
  await linkFakeKo(dir);
  await writeFile(layout, JSON.stringify([selfPane(), agentPane({ pane: "pane_2", session: "22222222aaaa", name: "sidebar" }), agentPane({ pane: "pane_3", session: "22222222bbbb", name: "fix-sidebar" }), agentPane({ pane: "pane_4", session: "elsewhere", name: "sidebar-elsewhere", koSession: "session_2" }), agentPane({ pane: "pane_5", session: "other", name: "sidebar-other", parent: "pane_99" })]));
  await writeFile(fd, `#!/usr/bin/env node
const fs=require('node:fs'),net=require('node:net'),path=${JSON.stringify(dir)},args=process.argv.slice(2);
if(args[0]!=='--base-directory'||!args.includes('--hidden')||!args.includes('--follow')||!args.includes('.git/**'))process.exit(91);
if(fs.existsSync(path+'/block')){fs.writeFileSync(path+'/pid',String(process.pid));net.connect(path+'/gate',function(){this.write('fd')})}else if(new RegExp(args.at(-1)).test('sidebar.txt'))console.log('sidebar.txt');
`, { mode: 0o700 });
  const server = createServer();
  server.listen(gate); await once(server, "listening");
  t.after(() => server.close());
  const starting = once(server, "connection");
  const app = await fixture(t, [{ type: "respond", command: "get_commands", data: { commands: [{ name: "find", source: "extension" }] } }], { KO_PANE: "pane_1", KO_SOCKET: "", KO_PANE_TOKEN: "", KO_FAKE_PANES: layout, KO_FAKE_API_LOG: join(dir, "ko-log"), KOA_FD: fd, KOA_FAKE_STARTUP_GATE: gate, PATH: dir + ":" + process.env.PATH, KO_AGENT_LIST_TTL_MS: "1000" }, undefined, false);
  const [startup] = await starting;
  t.after(() => startup.destroy());
  assert.deepEqual((await (await app.post("complete", { text: "/fi", pos: 3 })).json()).options, []);
  assert.equal((await app.log()).some(record => record.type === "get_commands"), false);
  let items: { kind: string; insert: string }[] = [];
  await pollUntil(async () => { items = (await (await app.post("complete", { text: "@si", pos: 3 })).json()).options; return items.some(item => item.kind === "agent"); }, 5000, "agent completion refresh").catch(async error => { throw new Error(String(error) + "\n" + app.stderr() + "\n" + JSON.stringify(items) + "\n" + await readFile(join(dir, "ko-log"), "utf8").catch(() => "no ko calls")); });
  assert.deepEqual(items.map(item => item.insert), ["@sidebar (session 22222222a) ", "@fix-sidebar (session 22222222b) ", "@sidebar.txt "]);
  startup.write("ready");
  await app.until(record => record.type === "state" && record.pi?.type === "ready");
  assert.equal((await (await app.post("complete", { text: "/fi", pos: 3 })).json()).options[0].insert, "/find ");
  await writeFile(join(dir, "block"), "");
  const connected = once(server, "connection"), controller = new AbortController();
  const request = fetch(app.base + "complete", { method: "POST", headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionId: 'fake', text: "@si", pos: 3 }), signal: controller.signal });
  const [socket] = await connected;
  t.after(() => socket.destroy());
  await once(socket, "data");
  assert.match(await readFile(join(dir, "pid"), "utf8"), /^[1-9]\d+$/);
  const closed = once(socket, "close");
  controller.abort();
  await assert.rejects(request, { name: "AbortError" });
  await closed;
});

test("document loads read the current page files and recover after a failed read", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-page-reload-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../../build/ko/share/ko/koa"), dir, { recursive: true });
  const program = join(dir, "koa.ts");
  await writeFile(program, `import ${JSON.stringify(resolve('../../build/ko/share/ko/koa/koa.ts'))};`);
  const app = await fixture(t, [], { KOA_PAGE_RELOAD: '1' }, undefined, true, [], program);
  for (const name of ["page.html", "page.css", "page.js"]) {
    const file = join(dir, name), marker = `reload-${name}`;
    assert.doesNotMatch(await (await fetch(app.base)).text(), new RegExp(marker));
    const original = await readFile(file, "utf8");
    await writeFile(file, original + `\n/* ${marker} */`);
    assert.match(await (await fetch(app.base)).text(), new RegExp(marker));
  }
  const file = join(dir, "page.css"), style = await readFile(file, "utf8");
  await rm(file);
  const failed = await fetch(app.base);
  assert.equal(failed.status, 500);
  assert.match(await failed.text(), /ENOENT.*page\.css/);
  await writeFile(file, style);
  const restored = await fetch(app.base);
  assert.equal(restored.status, 200);
  assert.match(await restored.text(), /reload-page\.css/);
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
    const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), ...args], { env: { ...process.env, PATH: '' }, timeout: 5000 });
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
if (process.env.KOA_STARTUP_ARGS) { const {writeSync}=await import('node:fs'); writeSync(3,JSON.stringify({packageRoot:${JSON.stringify(resolve('node_modules/@earendil-works/pi-coding-agent'))},messages:[],resume:false})+'\\n'); process.exit(0); }
const { writeSync } = await import('node:fs');
writeSync(3, JSON.stringify({type:'session',id:'fake',generation:1,cwd:process.cwd()})+'\\n');
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
  const early = await app.post("prompt", { text: "too early", mode: "prompt", attachments: [] });
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
  assert.equal((await app.post("prompt", {text:"still starting",mode: "prompt", attachments: []})).status, 409);
  socket.write("ready");
  const ready = await app.until(record => record.type === "state" && record.pi?.type === "ready", afterDialog);
  assert.equal(ready.dialogs.length, 0);
  const page = await (await fetch(app.base + "items?before=99")).json();
  assert.equal(page.items[0].text, "snapshot");
  assert.equal((await app.post("prompt", { text: "ready", mode: "prompt", attachments: [] })).status, 200);
});

test('reply annotations reach events live and on get_entries rebuild', { timeout: 10000 }, async t => {
  const message = { ...assistantMessage, content: [{ type: 'text', text: 'Should I proceed?' }] };
  const entry = { type: 'custom', id: 'annotation', parentId: null, customType: 'reply-annotations', timestamp: new Date(43).toISOString(), data: { reply: { at: 42, block: 0, length: 17 }, annotations: [{ type: 'question', kind: 'yes_no', range: [0, 17], options: [] }] } };
  const app = await fixture(t, [
    { type: 'wait', command: 'prompt', events: [{ type: 'message_start', message }, { type: 'message_end', message }, { type: 'entry_appended', entry }] },
    { type: 'respond', command: 'get_messages', data: { messages: [message] } },
    { type: 'respond', command: 'get_entries', data: { entries: [entry], leafId: entry.id } },
    { type: 'wait', command: 'prompt', events: [{ type: 'compaction_end' }] },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  await app.post('prompt', { text: 'go', mode: 'prompt', attachments: [] });
  const live = await app.until(record => record.type === 'item' && record.item?.kind === 'annotations');
  assert.deepEqual(live.item.reply, { seq: 0, block: 0 });
  const count = app.count();
  await app.post('prompt', { text: 'rebuild', mode: 'prompt', attachments: [] });
  const replay = await app.until(record => record.type === 'reset' && record.items?.some((item: { kind: string }) => item.kind === 'annotations'), count);
  assert.deepEqual(replay.items.find((item: { kind: string }) => item.kind === 'annotations'), { ...live.item, revision: 0 });
  assert.ok((await app.log()).filter(record => record.type === 'get_entries').length >= 2);
});

test("a malformed held message does not block later transcript entries", { timeout: 5000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "message_start", message: assistantMessage },
      { type: "message_end", message: { ...assistantMessage, content: null } },
      { type: "message_start", message: { ...assistantMessage, timestamp: 999, content: [{ type: "text", text: "After bad held message" }] } },
      { type: "message_end", message: { ...assistantMessage, timestamp: 999, content: [{ type: "text", text: "After bad held message" }] } },
    ], data: { disposition: "started" } },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await app.post("prompt", { text: "go", mode: "prompt", attachments: [] })).status, 200);
  await app.until(record => ["item", "patch"].includes(String(record.type)) && JSON.stringify(record).includes("After bad held message"));
  assert.match(app.stderr(), /koa: transcript: /);
});

test("a malformed pi record does not stop later records", { timeout: 5000 }, async t => {
  const app = await fixture(t, [
    { type: "wait", command: "prompt", events: [
      { type: "message_start", message: assistantMessage },
      { type: "message_update" },
      { type: "session_info_changed", name: "After bad record" },
    ], data: { disposition: "started" } },
  ], {}, undefined, true, [], resolve('../../build/ko/share/ko/koa/koa.ts'));
  assert.equal((await app.post("prompt", { text: "go", mode: "prompt", attachments: [] })).status, 200);
  await app.until(record => record.type === "state" && record.name === "After bad record");
  assert.match(app.stderr(), /koa: pi record message_update: /);
  assert.equal(app.stderr().split("koa: pi record message_update:").length, 2);
});

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
  const started = await app.post("prompt", { text: "go", mode: "steer", attachments: [] });
  assert.equal(started.status, 200);
  assert.deepEqual(await started.json(), { disposition: "started" });
  const item = await app.until(record => ["item", "patch"].includes(String(record.type)) && JSON.stringify(record).includes("hello\u2028world"));
  assert.match(JSON.stringify(item), /hello\\u2028world|hello\u2028world/);
  assert.deepEqual(await (await app.post("prompt", { text: "steering", mode: "steer", attachments: [] })).json(), { disposition: "queued" });
  assert.deepEqual(await (await app.post("prompt", { text: "later", mode: "follow_up", attachments: [] })).json(), { disposition: "handled", action: { type: "none" } });
  assert.equal((await app.post("abort")).status, 200);
  const patch = await app.until(record => record.type === "patch" && JSON.stringify(record).includes("final"));
  assert.match(JSON.stringify(patch), /final/);
  const state = await app.until(record => record.type === "state" && record.thinking === "high");
  assert.deepEqual(state.queue, { steering: [{ text: "next", attachments: [] }], followUp: [] });
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
  await app.post("prompt", { text: "go", mode: "prompt", attachments: [] });
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
  assert.equal((await app.post("prompt", { text: "go", mode: "prompt", attachments: [] })).status, 200);
  const state = await app.until(record => record.type === "state" && record.dialogs?.length === 2);
  assert.deepEqual(state.dialogs, [dialog, { ...dialog, id: "dialog-2", method: "confirm", message: "Really?" }]);
  await app.until(record => record.type === "item" && record.item.kind === "notify" && record.item.text.text === "Notice" && record.item.level === "warning");
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
  assert.deepEqual(await (await app.post("queue/clear")).json(), { steering: [{ text: "steer", attachments: [] }], followUp: [{ text: "later", attachments: [] }] });
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
  await pollUntil(async () => (await app.log()).some(record => record.type === "extension_ui_response" && record.id === "dialog-4"), 1000, "last dialog answer received");
  const commands = await app.log();
  assert.deepEqual(commands.find(record => record.type === "set_model"), { type: "set_model", provider: "test", modelId: "new", id: commands.find(record => record.type === "set_model").id });
  assert.deepEqual(commands.filter(record => record.type === "extension_ui_response").map(({ id, value, confirmed }) => ({ id, value, confirmed })), [{ id: "dialog-1", value: "Yes", confirmed: undefined }, { id: "dialog-2", value: undefined, confirmed: true }, { id: "dialog-3", value: "typed", confirmed: undefined }, { id: "dialog-4", value: undefined, confirmed: undefined }]);
});

test('session metadata supplies cwd before the session has a file', { timeout: 10000 }, async t => {
  const app = await fixture(t, [], { KOA_FAKE_CWD: '/tmp/other-folder' });
  const state = await app.until(record => record.type === 'state' && record.pi?.type === 'ready');
  assert.equal(state.cwd, '/tmp/other-folder');
  assert.equal(state.sessionId, 'fake');
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
    ...Array.from({ length: 3 }, () => ({ type: 'wait', command: 'prompt', after: [{ type: 'agent_settled', aborted: false }] })),
    { type: "wait", command: "set_model", data: { provider: "test", id: "picked" } },
    { type: "wait", command: "set_thinking_level", events: [{ type: "thinking_level_changed", level: "high" }] },
    { type: "wait", command: "prompt" }, { type: "exit", code: 7 },
  ], { KOA_FAKE_SELECTION_FILE: selection }, undefined, true, ["--runtime", "remote", "--resume", "-r", "--session", "old.jsonl", "--fork", "source.jsonl", "--model", "test/original", "--thinking", "low", "--system-prompt", "--resume", "--", "--session", "literal", "--resume"]);
  await pollUntil(async () => (await app.log()).filter(record => record.type === 'prompt').length === 3);
  assert.equal((await app.post("pi/start")).status, 409);
  assert.equal((await app.post("model", { provider: "test", modelId: "picked" })).status, 200);
  assert.equal((await app.post("thinking", { level: "high" })).status, 200);
  await app.post("prompt", { text: "exit", mode: "prompt", attachments: [] });
  await app.until(record => record.type === "state" && record.pi?.type === "exited");
  const after = app.count();
  assert.equal((await app.post("pi/start")).status, 200);
  const restarted = await app.until(record => record.type === "state" && record.pi?.type === "ready" && record.levels?.length === 3, after);
  assert.deepEqual(restarted.model, {provider:"test",id:"picked"});
  assert.equal(restarted.thinking, "high");
  const argv = (await app.log()).filter(record => record.type === "argv").map(record => record.args);
  assert.equal(argv.length, 2);
  assert.deepEqual(argv[1], ["--mode", "rpc", "--extension", resolve("../../build/ko/share/ko/pi/ko-pi.ts"), '--extension', resolve('../../build/ko/share/ko/koa/koa-sessions.ts'), "--koa-browser", "--runtime", "remote", "--resume", "-r", "--system-prompt", "--resume", "--session", session, "--", "--session", "literal", "--resume"]);
});
