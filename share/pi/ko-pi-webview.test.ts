import assert from "node:assert/strict";
import http from "node:http";
import { test } from "node:test";
import { makeFixture, pollUntil, selfPane, startSession, freshExtension } from "./ko-pi-fixture.ts";

function request(path: string, value?: unknown) {
  const socketPath = globalThis.__koPiExtensionWebview!.wv.socketPath;
  const req = http.request({ socketPath, path, method: value === undefined ? "GET" : "POST", agent: false });
  const state = { text: "", records: [] as any[], status: 0, ended: false, response: undefined as http.IncomingMessage | undefined };
  req.on("response", response => {
    state.response = response;
    state.status = response.statusCode!;
    response.setEncoding("utf8");
    let partial = "";
    response.on("data", text => {
      state.text += text;
      partial += text;
      for (let end = partial.indexOf("\n"); end >= 0; end = partial.indexOf("\n")) {
        const line = partial.slice(0, end);
        partial = partial.slice(end + 1);
        try { state.records.push(JSON.parse(line)); } catch {}
      }
    });
    response.on("end", () => { state.ended = true; });
  });
  req.on("error", () => { state.ended = true; });
  req.end(value === undefined ? undefined : JSON.stringify(value));
  return { state, close: () => req.destroy() };
}
function transcript(records: any[]) {
  const items = new Map<number, any>();
  for (const record of records) {
    if (record.type === "reset") { items.clear(); for (const item of record.items) items.set(item.seq, structuredClone(item)); }
    else if (record.type === "item") items.set(record.item.seq, structuredClone(record.item));
    else if (record.type === "patch") {
      const item = items.get(record.seq);
      Object.assign(item, { final: record.final, stop: record.stop, error: record.error, lifecycle: record.lifecycle });
      for (const change of record.blocks) {
        if (change.block) item.blocks[change.index] = structuredClone(change.block);
        else item.blocks[change.index].text += change.suffix;
      }
    }
  }
  return items;
}

test("webview is opt-in, follows support and dialogs, and survives runtime replacement", async () => {
  const fx = makeFixture();
  const tty = process.stdout.isTTY;
  Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: true });
  try {
    fx.setPanes([selfPane()]);
    const plain = await startSession(fx, { mode: "tui", record: false });
    assert.equal(globalThis.__koPiExtensionWebview, undefined);
    await plain.emit("session_shutdown", { reason: "quit" });
    let s = await startSession(fx, { mode: "tui", flags: { webview: true }, record: false });
    const hold = globalThis.__koPiExtensionWebview!;
    assert.equal(hold.wv.supported, false);
    fx.serve({ type: "supported", supported: true });
    await pollUntil(() => fx.webviewActions().length === 1);
    await s.emit("ui_prompt_start");
    await pollUntil(() => fx.webviewActions().length === 2);
    await s.emit("ui_prompt_end");
    await pollUntil(() => fx.webviewActions().length === 3);
    assert.deepEqual(fx.webviewActions(), ["enter", "leave", "enter"]);
    const page = request("/");
    await pollUntil(() => page.state.ended);
    assert.equal(page.state.status, 200);
    assert.match(page.state.text, /<title>pi<\/title>/);
    const terminal = request("/terminal", {});
    await pollUntil(() => terminal.state.ended && fx.webviewActions().at(-1) === "leave");
    await s.emit("agent_start");
    await pollUntil(() => fx.webviewActions().at(-1) === "enter");
    fx.serve({ type: "supported", supported: false });
    await pollUntil(() => fx.webviewActions().at(-1) === "leave");
    fx.serve({ type: "supported", supported: true });
    await pollUntil(() => fx.webviewActions().at(-1) === "enter");
    for (const reason of ["reload", "new", "resume", "fork"]) {
      const events = request("/events");
      await pollUntil(() => events.state.records.some(r => r.type === "state"));
      await s.emit("session_shutdown", { reason });
      await pollUntil(() => events.state.ended);
      s = await startSession(fx, { factory: await freshExtension(), mode: "tui", flags: { webview: true }, record: false });
      assert.equal(globalThis.__koPiExtensionWebview, hold);
      const page = request("/");
      await pollUntil(() => page.state.ended);
      assert.equal(page.state.status, 200);
    }
    await s.emit("session_shutdown", { reason: "quit" });
    assert.equal(fx.webviewActions().at(-1), "leave");
    assert.equal(globalThis.__koPiExtensionWebview, undefined);
  } finally {
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: tty });
    await fx.restore();
  }
});

test("webview HTTP transcript windows, patches, caps, epochs and prompt preflight", async () => {
  const fx = makeFixture();
  let configured = true;
  const streams: Array<ReturnType<typeof request>> = [];
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { mode: "tui", flags: { webview: true }, ctx: { modelRegistry: { hasConfiguredAuth: () => configured } } });
    for (let i = 0; i < 50; i++) await s.emit("message_end", { message: { role: "user", content: "message " + i } });
    const events = request("/events"); streams.push(events);
    await pollUntil(() => events.state.records.some(r => r.type === "state"));
    const reset = events.state.records[0];
    assert.equal(reset.items.length, 40);
    assert.equal(reset.more, true);
    assert.equal(reset.items[0].seq, 10);
    const older = request("/items?before=10");
    await pollUntil(() => older.state.ended);
    assert.deepEqual(JSON.parse(older.state.text).items.map((i: any) => i.seq), Array.from({ length: 10 }, (_, i) => i));
    const message = { role: "assistant", content: [{ type: "text", text: "Hello" }, { type: "toolCall", id: "call", name: "read", arguments: { path: "file" } }] };
    await s.emit("message_start", { message });
    await s.emit("message_update", { message: { ...message, content: [{ type: "text", text: "Hello world" }, message.content[1]] } });
    await pollUntil(() => events.state.records.some(r => r.type === "patch"));
    assert.deepEqual(events.state.records.find(r => r.type === "patch").blocks, [{ index: 0, suffix: " world" }]);
    await s.emit("message_end", { message });
    await s.emit("tool_execution_end", { toolCallId: "call", result: { content: [{ type: "text", text: "é".repeat(20000) }] }, isError: false });
    await pollUntil(() => transcript(events.state.records).get(50)?.final);
    const item = transcript(events.state.records).get(50);
    assert.equal(Buffer.byteLength(item.blocks[1].state.result.text), 16384);
    assert.equal(item.blocks[1].state.result.cut, 40000 - 16384);
    const resumed = request(`/events?epoch=${reset.epoch}&after=49`); streams.push(resumed);
    await pollUntil(() => resumed.state.records.some(r => r.type === "state"));
    assert.deepEqual(resumed.state.records.filter(r => r.type === "item").map(r => r.item.seq), [50]);
    assert.equal(resumed.state.records.some(r => r.type === "reset"), false);
    const post = async (path: string, value: unknown) => { const response = request(path, value); await pollUntil(() => response.state.ended); return response.state; };
    await s.emit("agent_start");
    assert.equal((await post("/prompt", { text: "steer", mode: "steer" })).status, 200);
    assert.deepEqual(s.delivered.at(-1), { text: "steer", opts: { expandPromptTemplates: true, deliverAs: "steer" } });
    await post("/prompt", { text: "later", mode: "follow_up" });
    assert.deepEqual(s.delivered.at(-1)?.opts, { expandPromptTemplates: true, deliverAs: "followUp" });
    configured = false;
    const refused = await post("/prompt", { text: "keep me", mode: "steer" });
    assert.equal(refused.status, 409);
    assert.match(refused.text, /authentication/);
    configured = true;
    await s.emit("session_before_compact");
    assert.equal((await post("/prompt", { text: "keep me", mode: "steer" })).status, 409);
    await s.emit("session_compact_failed");
    assert.equal((await post("/prompt", { text: " ", mode: "steer" })).status, 400);
    assert.equal((await post("/abort", {})).status, 200);
    assert.equal(s.aborts(), 1);
    const unknown = request("/missing"); await pollUntil(() => unknown.state.ended); assert.equal(unknown.state.status, 404);
    await s.emit("session_tree");
    await pollUntil(() => events.state.records.filter(r => r.type === "reset").length === 2);
    assert.notEqual(events.state.records.filter(r => r.type === "reset").at(-1).epoch, reset.epoch);
  } finally { for (const stream of streams) stream.close(); await fx.restore(); }
});

test("webview large unfinished items keep an active reader connected for patches and state", async () => {
  const fx = makeFixture();
  let events: ReturnType<typeof request> | undefined;
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { mode: "tui", flags: { webview: true } });
    const text = "a".repeat(300000);
    const message = { role: "assistant", content: [{ type: "text", text }] };
    await s.emit("message_start", { message });
    events = request("/events");
    const state = events.state;
    await pollUntil(() => state.records.some(r => r.type === "state"));
    assert.equal(state.records[0].items[0].blocks[0].text, text);
    assert.equal(state.records[0].items[0].final, false);
    const suffix = "b".repeat(200000);
    await s.emit("message_update", { message: { ...message, content: [{ type: "text", text: text + suffix }] } });
    await pollUntil(() => state.records.some(r => r.type === "patch"));
    assert.deepEqual(state.records.find(r => r.type === "patch").blocks, [{ index: 0, suffix }]);
    await s.emit("agent_start");
    await pollUntil(() => state.records.some(r => r.type === "state" && r.working));
    assert.equal(state.ended, false);
  } finally { events?.close(); await fx.restore(); }
});

test("webview HTTP cap ends only a stalled reader while another reader continues", async () => {
  const fx = makeFixture();
  const streams: Array<ReturnType<typeof request>> = [];
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { mode: "tui", flags: { webview: true } });
    const events = request("/events"); streams.push(events);
    const active = request("/events"); streams.push(active);
    await pollUntil(() => events.state.records.some(r => r.type === "state") && active.state.records.some(r => r.type === "state"));
    const epoch = events.state.records[0].epoch;
    events.state.response!.pause();
    for (let i = 0; i < 40; i++) {
      await s.emit("message_end", { message: { role: "user", content: "x".repeat(100000) } });
      await pollUntil(() => active.state.records.some(r => r.type === "item" && r.item.seq === i));
    }
    events.state.response!.resume();
    await pollUntil(() => events.state.ended);
    const delivered = events.state.records.filter(r => r.type === "item");
    assert.ok(delivered.length > 0 && delivered.length < 40);
    await s.emit("message_end", { message: { role: "user", content: "still connected" } });
    await pollUntil(() => active.state.records.some(r => r.type === "item" && r.item.seq === 40));
    assert.equal(active.state.ended, false);
    const after = delivered.at(-1).item.seq;
    const resumed = request(`/events?epoch=${epoch}&after=${after}`); streams.push(resumed);
    await pollUntil(() => resumed.state.records.some(r => r.type === "item"));
    assert.equal(resumed.state.records[0].type, "item");
    assert.equal(resumed.state.records[0].item.seq, after + 1);
  } finally { for (const stream of streams) stream.close(); await fx.restore(); }
});
