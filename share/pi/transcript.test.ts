import assert from "node:assert/strict";
import { IncomingMessage, ServerResponse, createServer } from "node:http";
import { Socket } from "node:net";
import { test, type TestContext } from "node:test";
import { mkdtempSync, rmSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { transcript } from "./transcript.ts";
import type { WireItem } from "./records.ts";

function directory(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "koa-transcript-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function request(view: ReturnType<typeof transcript>, path: string) {
  const request = new IncomingMessage(new Socket());
  request.method = "GET";
  request.url = path;
  const response = new ServerResponse(request);
  const lines: string[] = [];
  response.write = (chunk: string) => { lines.push(chunk); return true; };
  response.end = (chunk?: unknown) => { if (typeof chunk === "string") lines.push(chunk); return response; };
  assert.equal(view.handle(request, response), true);
  return lines;
}

function record(line: string) {
  assert.match(line, /^data: [^\r\n]*\n\n$/);
  return JSON.parse(line.slice(6, -2));
}

function assistant(text: string, stopReason: "stop" | "error" = "stop"): Extract<AgentMessage, { role: "assistant" }> {
  return { role: "assistant", content: [{ type: "text", text }], api: "openai-responses", provider: "openai", model: "test", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason, timestamp: 123 };
}

test('structured agent and job details render identically live and on rebuild', t => {
  const view = transcript({ dir: directory(t), flushMs: 1 });
  const messages: AgentMessage[] = [
    { role: 'custom', customType: 'ko-message', display: true, timestamp: 1, content: 'Do not parse this header', details: { agent: { name: 'boss', session: 'boss-id', pane: 'pane_2' }, body: 'Review the module', inbound: { form: 'message', relation: 'parent', runtime: 'dev' } } },
    { role: 'custom', customType: 'ko-stream', display: true, timestamp: 2, content: 'Do not parse this output', details: { job: { id: 'j1', name: 'build', service: false, log: '/tmp/build.log' }, batch: 'compiled', omitted: 2, cut: true } },
    { role: 'custom', customType: 'other-extension', display: true, timestamp: 3, content: 'plain notice', details: {} },
  ];
  for (const message of messages) view.message(message, 'end');
  const live = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(live[0], { seq: 0, at: 1, final: true, kind: 'agent', direction: 'in', from: { name: 'boss', session: 'boss-id', pane: 'pane_2' }, text: { text: 'Review the module', cut: 0 }, inbound: { form: 'message', relation: 'parent', runtime: 'dev' } });
  assert.deepEqual(live[1], { seq: 1, at: 2, final: true, kind: 'job', job: { id: 'j1', name: 'build', service: false, log: '/tmp/build.log' }, event: { type: 'stream', batch: { text: 'compiled', cut: 0 }, omitted: 2, cut: true } });
  assert.equal(live[2].kind, 'notice'); view.rebuild(messages);
  assert.deepEqual(JSON.parse(request(view, '/items?before=100').join('')).items, live); view.close();
});

test('agent forms and every job ending use typed details, capped bodies and strict shape checks', t => {
  const view = transcript({ dir: directory(t), flushMs: 1 }), agent = { name: 'worker' }, job = { id: 'j', name: 'build', service: false, log: '/tmp/log' };
  const forms = [
    { customType: 'ko-steer', details: { agent, body: 'redirect', inbound: { form: 'steer' } }, inbound: { form: 'steer' } },
    { customType: 'ko-notice', details: { agent, inbound: { form: 'report' }, body: 'x'.repeat(20000) }, inbound: { form: 'report' } },
    { customType: 'ko-notice', details: { agent, inbound: { form: 'notice' }, body: 'notice' }, inbound: { form: 'notice' } },
    { customType: 'ko-notice', details: { agent, inbound: { form: 'ended', reported: false }, body: 'ended' }, inbound: { form: 'ended', reported: false } },
  ];
  for (const [index, value] of forms.entries()) view.message({ role: 'custom', display: true, timestamp: index, customType: value.customType, content: 'Do not read me', details: value.details }, 'end');
  const ends = [{ type: 'exit', code: 0 }, { type: 'exit', code: 1 }, { type: 'signal', signal: 'SIGKILL' }, { type: 'failed', message: 'could not start' }, { type: 'timeout', seconds: 600 }, { type: 'stopped' }];
  for (const end of ends) view.message({ role: 'custom', display: true, timestamp: 5, customType: 'ko-notice', content: 'wrong', details: { kind: 'job', job: { ...job, end }, tail: 'tail' } }, 'end');
  view.message({ role: 'custom', display: true, timestamp: 6, customType: 'ko-notice', content: 'unknown', details: { agent, inbound: { form: 'ended' }, body: 'not a typed ending' } }, 'end');
  const items = JSON.parse(request(view, '/items?before=100').join('')).items;
  assert.deepEqual(items.slice(0, forms.length).map((item: { inbound: unknown }) => item.inbound), forms.map(value => value.inbound));
  assert.deepEqual(items[1].text, { text: 'x'.repeat(16384), cut: 3616 });
  assert.deepEqual(items.slice(forms.length, forms.length + ends.length).map((item: { event: { end: unknown } }) => item.event.end), ends);
  assert.equal(items.at(-1).kind, 'notice'); view.close();
});

test('agent tool cards keep full capped arguments and typed outcomes on live and replay paths', t => {
  const view = transcript({ dir: directory(t), flushMs: 1 }), message = assistant('');
  message.content = [
    { type: 'toolCall', id: 'spawn', name: 'spawn_agent', arguments: { name: 'worker', task: 'x'.repeat(20000), model: 'provider/model' } },
    { type: 'toolCall', id: 'send', name: 'message_agent', arguments: { to: 'worker', message: 'Review', mode: 'steer' } },
    { type: 'toolCall', id: 'job', name: 'async_bash', arguments: { command: 'make', name: 'build' } },
  ];
  view.message(message, 'start');
  const before = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks;
  assert.deepEqual(before[0].agent.text, { text: 'x'.repeat(16384), cut: 3616 }); assert.equal(before[0].agent.outcome, undefined);
  const results: Extract<AgentMessage, { role: 'toolResult' }>[] = [
    { role: 'toolResult', toolCallId: 'spawn', toolName: 'spawn_agent', content: [{ type: 'text', text: 'do not parse this result' }], isError: false, timestamp: 200, details: { name: 'worker', session: 'worker-id', pane: 'pane_2', outcome: { ok: true } } },
    { role: 'toolResult', toolCallId: 'send', toolName: 'message_agent', content: [], isError: false, timestamp: 201, details: { to: 'worker', outcome: { ok: false, failure: 'refused', message: 'Not now' } } },
    { role: 'toolResult', toolCallId: 'job', toolName: 'async_bash', content: [], isError: false, timestamp: 202, details: { job: { id: 'j1', name: 'build', log: '/tmp/build.log', service: true }, stream: false } },
  ];
  for (const result of results) view.toolDone(result.toolCallId, result.content, result.isError, result.timestamp, undefined, undefined, result.details);
  const live = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks;
  assert.deepEqual(live[0].agent.to, { name: 'worker', session: 'worker-id', pane: 'pane_2' });
  assert.deepEqual(live[1].agent.outcome, { ok: false, failure: 'refused', message: 'Not now' }); assert.equal(live[1].agent.text.text, 'Review');
  assert.deepEqual(live[2].job, { id: 'j1', name: 'build', log: '/tmp/build.log', service: true });
  view.rebuild([message, ...results]); const replay = JSON.parse(request(view, '/items?before=100').join('')).items[0].blocks;
  assert.deepEqual(replay.map((block: { agent?: unknown; job?: unknown }) => [block.agent, block.job]), live.map((block: { agent?: unknown; job?: unknown }) => [block.agent, block.job])); view.close();
});

test("events use SSE framing", t => {
  const view = transcript({ dir: directory(t), flushMs: 10 });
  const lines = request(view, "/events");
  assert.ok(lines.length > 0);
  for (const line of lines) {
    assert.match(line, /^data: .*\n\n$/);
    assert.equal(JSON.parse(line.slice(6)).type, "reset");
  }
  view.close();
});

test("caps preserve UTF-8 and windows retain the newest forty items", t => {
  const view = transcript({ dir: directory(t), flushMs: 1 });
  view.message({ role: "bashExecution", command: "test", output: "a".repeat(16383) + "😀", exitCode: 0, cancelled: false, truncated: false, timestamp: 12 }, "end");
  const item = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(item.kind, "bash");
  if (item.kind !== "bash") return;
  assert.deepEqual(item.output, { text: "a".repeat(16383), cut: 4 });
  assert.equal(item.at, 12);
  for (let i = 0; i < 45; i++) view.message({ role: "user", content: `message ${i}`, timestamp: i }, "end");
  const page = JSON.parse(request(view, "/items?before=46").join(""));
  assert.equal(page.items.length, 40);
  assert.equal(page.items[0].text, "message 5");
  assert.equal(page.items.at(-1).text, "message 44");
  assert.equal(page.more, true);
  view.rebuild([
    { role: "user", content: "x".repeat(200000), timestamp: 1 },
    { role: "user", content: "y".repeat(200000), timestamp: 2 },
  ]);
  const bounded = JSON.parse(request(view, "/items?before=2").join(""));
  assert.equal(bounded.items.length, 1);
  assert.equal(bounded.items[0].at, 2);
  assert.equal(bounded.more, true);
  view.close();
});

test("patches append only unchanged text prefixes and replace changed blocks", t => {
  const view = transcript({ dir: directory(t), flushMs: 1000 });
  const lines = request(view, "/events");
  view.message(assistant("hello"), "start");
  view.message(assistant("hello world"), "update");
  request(view, "/events");
  assert.deepEqual(record(lines.findLast(line => line.includes('"type":"patch"'))!).blocks, [{ index: 0, suffix: " world" }]);
  view.message(assistant("replacement"), "update");
  request(view, "/events");
  assert.deepEqual(record(lines.findLast(line => line.includes('"type":"patch"'))!).blocks, [{ index: 0, block: { type: "text", text: "replacement" } }]);
  view.message(assistant("replacement", "error"), "end");
  const patch = record(lines.findLast(line => line.includes('"type":"patch"'))!);
  assert.equal(patch.stop, "error");
  assert.equal(patch.final, true);
  assert.deepEqual(patch.blocks, []);
  assert.equal(JSON.parse(request(view, "/items?before=100").join("")).items[0].at, 123);
  const thinking = assistant("");
  thinking.content = [{ type: "thinking", thinking: "hidden", redacted: false }];
  view.message(thinking, "start");
  thinking.content = [{ type: "thinking", thinking: "hidden", redacted: true }];
  view.message(thinking, "update");
  request(view, "/events");
  assert.deepEqual(record(lines.findLast(line => line.includes('"type":"patch"'))!).blocks, [{ index: 0, block: { type: "thinking", text: "hidden", redacted: true } }]);
  view.close();
});

test("tool timing survives assistant updates and reaches patches", t => {
  const view = transcript({ dir: directory(t), flushMs: 1000 });
  const message = assistant("");
  message.content = [{ type: "toolCall", id: "call", name: "read", arguments: { path: "file" } }];
  const lines = request(view, "/events");
  view.message(message, "start");
  view.toolRunning("call", 200);
  view.toolPartial("call", [{ type: "text", text: "partial" }]);
  view.toolDone("call", [{ type: "text", text: "done" }], false, 250, 49);
  view.message(message, "end");
  const item = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(item.kind, "assistant");
  if (item.kind !== "assistant") return;
  assert.deepEqual(item.blocks[0], { type: "tool", id: "call", name: "read", args: { text: '{"path":"file"}', cut: 0 }, state: { type: "done", result: { text: "done", cut: 0, images: [] }, error: false }, started: 200, ended: 250, durationMs: 49 });
  assert.equal(lines.some(line => line.includes('"started":200') && line.includes('"ended":250') && line.includes('"durationMs":49')), true);
  assert.equal(lines.some(line => line.includes('"text":"partial"')), false);
  view.rebuild([message, { role: "toolResult", toolCallId: "call", toolName: "read", content: [{ type: "text", text: "saved" }], isError: false, timestamp: 300 }]);
  const restored = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(restored.kind, "assistant");
  if (restored.kind === "assistant" && restored.blocks[0].type === "tool") assert.deepEqual({ started: restored.blocks[0].started, ended: restored.blocks[0].ended }, { started: 123, ended: 300 });
  else assert.fail("The restored tool is missing");
  view.close();
});

test("bash exit codes come from structured results or the status footer", t => {
  const view = transcript({ dir: directory(t), flushMs: 1000 });
  const message = assistant("");
  message.content = [{ type: "toolCall", id: "call", name: "bash", arguments: { command: "make verify" } }];
  const block = () => JSON.parse(request(view, "/items?before=100").join("")).items[0].blocks[0];
  view.message(message, "start");
  view.toolDone("call", [{ type: "text", text: "failed\n\nCommand exited with code 101" }], true, 250, 49, { exit_code: 101 });
  assert.equal(block().exit, 101);
  assert.equal(block().state.result.text, "failed");
  view.rebuild([message, { role: "toolResult", toolCallId: "call", toolName: "bash", content: [{ type: "text", text: "saved\n\nCommand exited with code 7" }], isError: true, timestamp: 300 }]);
  assert.equal(block().exit, 7);
  assert.equal(block().state.result.text, "saved");
  view.close();
});

test("delivered attachment paths are data and a rebuild never guesses them", t => {
  const view = transcript({ dir: directory(t), flushMs: 1 });
  const lines = request(view, "/events");
  const file = { id: "upload", name: "data.txt", size: 4, path: "/tmp/copy/data.txt", origin: "upload" as const, kind: "file" as const };
  const message = { role: "user" as const, timestamp: 1, content: "Inspect\n" + file.path };
  view.message(message, "start");
  view.message(message, "end", undefined, [file]);
  const item = lines.map(record).filter(record => record.type === "item").at(-1)?.item;
  assert.equal(item?.text, "Inspect");
  assert.deepEqual(item?.attachments, [file]);
  lines.length = 0;
  view.rebuild([message]);
  const rebuilt = lines.map(record).find(record => record.type === "reset")?.items[0];
  assert.equal(rebuilt?.text, message.content);
  assert.deepEqual(rebuilt?.attachments, []);
  view.close();
});

test("identical image partials emit no patch and changed bytes advance the wire revision", t => {
  const view = transcript({ dir: directory(t), flushMs: 1000 });
  const lines = request(view, "/events");
  view.message({ ...assistant(""), content: [{ type: "toolCall", id: "image", name: "read", arguments: {} }] }, "start");
  const image = { type: "image" as const, mimeType: "image/png", data: Buffer.from("old").toString("base64") }, old = [image];
  view.toolPartial("image", old); request(view, "/events");
  const before = lines.length;
  view.toolPartial("image", old); request(view, "/events");
  assert.equal(lines.length, before);
  const next = [{ ...image, data: Buffer.from("new").toString("base64") }];
  view.toolPartial("image", next); request(view, "/events");
  assert.equal(lines.length, before + 1);
  const patch = record(lines.at(-1)!);
  assert.equal(patch.type, "patch");
  assert.deepEqual(patch.blocks[0].block.state.result.images, [{ id: "0.0.0", revision: 1, mimeType: "application/octet-stream", bytes: 3 }]);
  view.close();
});

test("rebuild sends reset then exactly one caller-supplied state and keeps the epoch format", t => {
  const view = transcript({ dir: directory(t), flushMs: 1000 });
  const state = { working: false, name: "before", model: { provider: "test", id: "test" }, aborted: false, levels: [], cwd: "/tmp", home: "/tmp", dialogs: [], statuses: {}, queue: { steering: [], followUp: [] }, pi: { type: "ready" as const } };
  view.state(state);
  const lines = request(view, "/events");
  const firstEpoch = record(lines[0]).epoch;
  assert.match(firstEpoch, /^[A-Za-z0-9_-]{22}$/);
  lines.length = 0;
  view.rebuild([{ role: "user", content: "restored", timestamp: 456 }]);
  view.state({ ...state, working: true, name: "after" });
  const records = lines.map(record);
  assert.deepEqual(records.map(record => record.type), ["reset", "state"]);
  assert.deepEqual(records[0].items, [{ seq: 0, at: 456, final: true, kind: "user", text: "restored", images: [], attachments: [] }]);
  assert.match(records[0].epoch, /^[A-Za-z0-9_-]{22}$/);
  assert.notEqual(records[0].epoch, firstEpoch);
  assert.deepEqual(records[1], { ...state, type: "state", working: true, name: "after" });
  view.close();
});

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==", "base64");

test("image references keep disk bytes beyond the feed window and serve missing and unknown images", async t => {
  const dir = directory(t);
  const view = transcript({ dir, flushMs: 1 });
  const server = createServer((request, response) => { if (!view.handle(request, response)) { response.writeHead(404); response.end(); } });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise<void>(resolve => { view.close(); server.closeAllConnections(); server.close(() => resolve()); }));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const url = `http://127.0.0.1:${address.port}`;
  const user = { role: "user" as const, timestamp: 1, content: [{ type: "text" as const, text: "Compare this" }, { type: "image" as const, mimeType: "image/png", data: png.toString("base64") }] };
  view.message(user, "end");
  const page: { items: WireItem[] } = await (await fetch(url + "/items?before=1")).json();
  const item = page.items[0];
  assert.equal(item?.kind, "user");
  if (item?.kind !== "user") return;
  assert.ok(Array.isArray(item.images));
  assert.equal(item.images.length, 1);
  const image = item.images[0];
  assert.ok(image);
  assert.deepEqual(image, { id: image.id, revision: 0, mimeType: "image/png", bytes: png.length, width: 1, height: 1 });
  assert.deepEqual(readFileSync(join(dir, "images", image.id)), png);
  const call: Extract<AgentMessage, { role: "assistant" }> = { role: "assistant", timestamp: 2, api: "openai-responses", provider: "openai", model: "test", stopReason: "toolUse", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, content: [{ type: "toolCall", id: "a", name: "read", arguments: {} }, { type: "toolCall", id: "b", name: "read", arguments: {} }] };
  view.message(call, "start");
  const imageContent = { type: "image" as const, data: png.toString("base64"), mimeType: "image/png" }, content = [imageContent];
  view.toolPartial("a", content); view.toolRunning("b", 3);
  const path = join(dir, "images", "1.0.0"), inode = statSync(path).ino;
  view.toolPartial("a", content); view.toolRunning("b", 4);
  assert.equal(statSync(path).ino, inode, "an identical partial result must not rewrite its image");
  const changed = Buffer.from(png); changed.writeUInt8(changed.readUInt8(changed.length - 1) ^ 1, changed.length - 1);
  const replacement = [{ ...imageContent, data: changed.toString("base64") }];
  view.toolPartial("a", replacement); view.toolRunning("b", 5);
  const current: { items: WireItem[] } = await (await fetch(url + "/items?before=2")).json();
  const block = current.items[1]?.kind === "assistant" ? current.items[1].blocks[0] : undefined;
  assert.ok(block?.type === "tool" && "result" in block.state && block.state.result);
  assert.equal(block.state.result.images[0]?.revision, 1);
  assert.deepEqual(Buffer.from(await (await fetch(url + "/images/1.0.0?r=1")).arrayBuffer()), changed);
  view.toolDone("b", content, false, 6);
  view.toolDone("a", [], false, 7);
  assert.equal((await fetch(url + "/images/1.0.0")).status, 404);
  assert.equal((await fetch(url + "/images/1.1.0")).status, 200, "another tool block keeps its image");
  for (let i = 0; i < 45; i++) view.message({ role: "user", timestamp: i + 2, content: "later" }, "end");
  const response = await fetch(url + "/images/" + image.id);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(response.headers.get("content-length"), String(png.length));
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
  rmSync(join(dir, "images", image.id));
  assert.equal((await fetch(url + "/images/" + image.id)).status, 410);
  assert.equal((await fetch(url + "/images/unknown")).status, 404);
  view.rebuild([user]);
  assert.deepEqual(readFileSync(join(dir, "images", image.id)), png);
  view.rebuild([]);
  assert.equal((await fetch(url + "/images/" + image.id)).status, 404);
  for (const [mimeType, data] of [["text/html", "<!doctype html><script>globalThis.pwned=true</script>"], ["image/svg+xml", '<svg xmlns="http://www.w3.org/2000/svg"><script>globalThis.pwned=true</script></svg>']]) {
    view.rebuild([{ role: "user", timestamp: 1, content: [{ type: "image", mimeType: mimeType!, data: Buffer.from(data!).toString("base64") }] }]);
    const response = await fetch(url + "/images/0.0");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/octet-stream");
    assert.equal(response.headers.get("x-content-type-options"), "nosniff");
    assert.equal(response.headers.get("content-security-policy"), "sandbox; default-src 'none'");
    assert.equal(await response.text(), data);
  }
});
