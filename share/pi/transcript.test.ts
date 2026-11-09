import assert from "node:assert/strict";
import { IncomingMessage, ServerResponse } from "node:http";
import { Socket } from "node:net";
import { test } from "node:test";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { transcript } from "./transcript.ts";

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

test("events use SSE framing", () => {
  const view = transcript({ flushMs: 10 });
  const lines = request(view, "/events");
  assert.ok(lines.length > 0);
  for (const line of lines) {
    assert.match(line, /^data: .*\n\n$/);
    assert.equal(JSON.parse(line.slice(6)).type, "reset");
  }
  view.close();
});

test("caps preserve UTF-8 and windows retain the newest forty items", () => {
  const view = transcript({ flushMs: 1 });
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

test("patches append only unchanged text prefixes and replace changed blocks", () => {
  const view = transcript({ flushMs: 1000 });
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

test("tool timing survives assistant updates and reaches patches", () => {
  const view = transcript({ flushMs: 1000 });
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
  assert.deepEqual(item.blocks[0], { type: "tool", id: "call", name: "read", args: { text: '{"path":"file"}', cut: 0 }, state: { type: "done", result: { text: "done", cut: 0 }, error: false }, started: 200, ended: 250, durationMs: 49 });
  assert.equal(lines.some(line => line.includes('"started":200') && line.includes('"ended":250') && line.includes('"durationMs":49')), true);
  assert.equal(lines.some(line => line.includes('"text":"partial"')), false);
  view.rebuild([message, { role: "toolResult", toolCallId: "call", toolName: "read", content: [{ type: "text", text: "saved" }], isError: false, timestamp: 300 }]);
  const restored = JSON.parse(request(view, "/items?before=100").join("")).items[0];
  assert.equal(restored.kind, "assistant");
  if (restored.kind === "assistant" && restored.blocks[0].type === "tool") assert.deepEqual({ started: restored.blocks[0].started, ended: restored.blocks[0].ended }, { started: 123, ended: 300 });
  else assert.fail("The restored tool is missing");
  view.close();
});

test("bash exit codes come from structured results or the status footer", () => {
  const view = transcript({ flushMs: 1000 });
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

test("rebuild sends reset then exactly one caller-supplied state and keeps the epoch format", () => {
  const view = transcript({ flushMs: 1000 });
  view.state({ working: false, name: "before", model: "test" });
  const lines = request(view, "/events");
  const firstEpoch = record(lines[0]).epoch;
  assert.match(firstEpoch, /^[A-Za-z0-9_-]{22}$/);
  lines.length = 0;
  view.rebuild([{ role: "user", content: "restored", timestamp: 456 }]);
  view.state({ working: true, name: "after", model: "test" });
  const records = lines.map(record);
  assert.deepEqual(records.map(record => record.type), ["reset", "state"]);
  assert.deepEqual(records[0].items, [{ seq: 0, at: 456, final: true, kind: "user", text: "restored", images: 0 }]);
  assert.match(records[0].epoch, /^[A-Za-z0-9_-]{22}$/);
  assert.notEqual(records[0].epoch, firstEpoch);
  assert.deepEqual(records[1], { type: "state", working: true, name: "after", model: "test" });
  view.close();
});
