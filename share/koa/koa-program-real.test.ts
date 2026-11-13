import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFile, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { Readable } from "node:stream";
import { pollUntil, ofType, sse } from "./koa-agent-fixture.ts";
import { realFixture } from "./koa-program-fixture.ts";

type App = Awaited<ReturnType<typeof realFixture>>;
const send = (app: App, text: string) => app.post("prompt", { text, mode: "prompt", attachments: [] });
const note = (text: string) => ofType("item", record => record.item.kind === "notify" && record.item.text.text.includes(text));
const compaction = (state: string) => ofType("item", record => record.item.kind === "command" && record.item.result.type === "compaction" && record.item.result.state.type === state);
const idle = () => ofType("state", record => record.compaction === "idle" && !record.working);
const assistantEntry = (text: string, timestamp: number) => ({ role: "assistant" as const, content: [{ type: "text" as const, text }], api: "openai-completions", provider: "fake", model: "fake-model", usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop" as const, timestamp });
const seeded = (turns: number, extra?: (manager: SessionManager) => void, pad = "") => async ({ cwd, sessions }: { cwd: string; sessions: string }) => {
  const manager = SessionManager.create(cwd, sessions);
  for (let i = 0; i < turns; i++) {
    manager.appendMessage({ role: "user", content: `prompt ${i}${pad}`, timestamp: 2 * i + 1 });
    manager.appendMessage(assistantEntry(`answer ${i}${pad}`, 2 * i + 2));
  }
  extra?.(manager);
  const file = manager.getSessionFile();
  assert.ok(file);
  return ["--session", file];
};

test("history comes from the whole transcript and omits consecutive duplicates", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [], setup: seeded(110, manager => { manager.appendMessage({ role: "user", content: " prompt 109 ", timestamp: 500 }); manager.appendMessage(assistantEntry("x", 501)); }) });
  const result: { entries: string[] } = await (await fetch(app.url("history"))).json();
  assert.equal(result.entries.length, 100);
  assert.equal(result.entries[0], "prompt 109");
  assert.equal(result.entries.at(-1), "prompt 10");
});

test("built-in commands never become prompts", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  for (const text of ["/tree args", "/resume", "/new", "/copy", "/model", "/thinking"]) {
    const response = await send(app, text);
    assert.equal(response.status, 200);
    if (text === "/resume" || text === "/new") assert.deepEqual(await response.json(), { disposition: "handled", action: { type: "session", kind: text.slice(1) } });
  }
  assert.deepEqual(app.provider.requests, []);
  assert.deepEqual((await (await fetch(app.url("history"))).json()).entries, []);
});

test("model, thinking, statistics, copy and export use real pi", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [], setup: seeded(1) });
  assert.equal((await send(app, "/thinking high")).status, 200);
  await app.until(note("thinking high"));
  assert.equal((await send(app, "/model fake/fake-model")).status, 200);
  await app.until(note("model: fake-model"));
  await send(app, "/session");
  const stats = await app.until(ofType("item", record => record.item.kind === "command" && record.item.result.type === "session"));
  assert.match(JSON.stringify(stats.item), /"userMessages":1/);
  await send(app, "/copy");
  await pollUntil(() => app.stdout().includes("\x1b]52;c;" + Buffer.from("answer 0").toString("base64") + "\x1b\\"), 5000, "OSC 52 copy");
  await send(app, "/export");
  const exported = await app.until(ofType("item", record => record.item.kind === "command" && record.item.result.type === "export"));
  assert.match(await (await fetch(app.url("steps/" + exported.item.seq + "/0/file"))).text(), /<html/i);
  assert.equal((await send(app, "/quit")).status, 200);
  assert.equal((await app.close)[0], 0);
});

test("manual compaction ends once as cancelled when aborted, as failed and as done", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [{ gate: "held", text: "never" }, { status: 400 }, { text: "## Goal\nsummary" }], setup: seeded(20, undefined, " " + "lorem ipsum ".repeat(700)) });
  let cursor = app.count();
  await send(app, "/compact");
  await app.until(ofType("state", record => record.compaction === "running"), cursor);
  await pollUntil(() => app.provider.requests.length === 1, 5000, "held compaction request");
  assert.equal((await app.post("abort")).status, 200);
  await app.until(compaction("cancelled"), cursor);
  await app.until(idle(), cursor);
  for (const state of ["failed", "done"]) {
    cursor = app.count();
    assert.equal((await send(app, "/compact")).status, 200);
    await app.until(compaction(state), cursor);
    await app.until(idle(), cursor);
  }
  const count = (state: string) => app.records().filter(record => record.type === "item" && JSON.stringify(record.item).includes(`"type":"compaction","state":{"type":"${state}"`)).length;
  assert.deepEqual([count("cancelled"), count("failed"), count("done")], [1, 1, 1]);
});

test("streamed reasoning, text and fragmented tool arguments reach the transcript", { timeout: 20000 }, async t => {
  const app = await realFixture(t, {
    replies: [{ reasoning: "thinking hard", tools: [{ name: "write", args: { path: "out.txt", content: "héllo ✓ wörld" }, pieces: 7 }] }, { text: "wrote it" }],
  });
  await send(app, "write a file");
  await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("wrote it")));
  const shown = JSON.stringify(app.records());
  assert.match(shown, /thinking hard/);
  assert.match(shown, /héllo ✓ wörld/);
  assert.deepEqual(app.provider.violations, []);
  const result = app.provider.requests[1]?.body.messages.find(message => message.role === "tool");
  assert.match(String(result?.content), /out\.txt/);
});

test("a bang command streams once, is replayed once and stays out of the provider", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  const events = new AbortController();
  t.after(() => events.abort());
  assert.equal((await send(app, "!echo bang-output")).status, 200);
  await app.until(ofType("state", record => record.bash.some(item => item.phase === "completed" && item.result.output.text === "bang-output\n")));
  const fresh = sse(Readable.from((await fetch(app.base + "events", { signal: events.signal })).body ?? []));
  const replay = await fresh.until(ofType("reset"));
  assert.equal(JSON.stringify(replay.items).split("bang-output\\n").length, 2);
  assert.equal(app.provider.requests.length, 0);
});

test("a queued prompt is cleared and the turn aborted", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [{ gate: "turn", text: "late" }] });
  await send(app, "first");
  await app.until(ofType("state", record => record.working === true));
  assert.equal((await app.post("prompt", { text: "second", mode: "steer", attachments: [] })).status, 200);
  await app.until(ofType("state", record => record.queue.steering.length === 1));
  assert.equal((await app.post("queue/clear")).status, 200);
  await app.until(ofType("state", record => record.queue.steering.length === 0));
  assert.equal((await app.post("abort")).status, 200);
  await app.until(ofType("state", record => record.working === false));
  app.provider.release("turn");
});

test("/reload reloads the extensions of the running agent in place", { timeout: 30000 }, async t => {
  const source = (description: string) => `export default function (pi) { pi.registerCommand('probe', { description: '${description}', handler: async () => {} }); }\n`;
  const app = await realFixture(t, { replies: [], extensions: { "probe.ts": source("first") } });
  const detail = async () => (await (await app.post("complete", { text: "/pro", pos: 4 })).json()).options.find((option: { label: string }) => option.label === "/probe")?.detail;
  assert.equal(await detail(), "first");
  await writeFile(join(app.dir, "probe.ts"), source("second"));
  const cursor = app.count();
  await send(app, "/reload");
  await app.until(note("reloaded"), cursor);
  assert.equal(await detail(), "second");
  assert.equal((app.stderr().match(/koa: http:/g) ?? []).length, 1);
});

test("restart keeps the session, the model and the thinking level", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: "ok" }] });
  await send(app, "persist me");
  await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("ok")));
  await send(app, "/thinking high");
  await app.until(ofType("state", record => record.thinking === "high"));
  const before = app.records().filter(record => record.type === "state").at(-1);
  await mkdir(join(app.dir, "keep"), { recursive: true });
  await send(app, "/restart");
  const urls = () => [...app.stderr().matchAll(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/g)].flatMap(match => match[1] ?? []);
  await pollUntil(() => urls().length === 2, 10000, "the new koa incarnation");
  const events = new AbortController();
  t.after(() => events.abort());
  const fresh = sse(Readable.from((await fetch(urls()[1] + "events", { signal: events.signal })).body ?? []));
  const after = await fresh.until(ofType("state", record => record.life?.type === "ready"));
  assert.equal(after.sessionId, before?.sessionId);
  assert.equal(after.thinking, "high");
  assert.equal(after.model?.id, before?.model?.id);
});

test("a tool call in flight shows a running step before its result", { timeout: 30000 }, async t => {
  const gate = join(tmpdir(), `koa-gate-${process.pid}-${Date.now()}`);
  const tool = `import { existsSync } from "node:fs"; export default function (pi) { pi.registerTool({ name: "gated", label: "gated", description: "waits", parameters: { type: "object", properties: {} }, async execute() { while (!existsSync(${JSON.stringify(gate)})) await new Promise(resolve => setTimeout(resolve, 20)); return { content: [{ type: "text", text: "opened" }], details: {} }; } }); }\n`;
  const app = await realFixture(t, { replies: [{ tools: [{ name: "gated", args: {} }] }, { text: "done" }], extensions: { "gated.ts": tool } });
  t.after(() => rm(gate, { force: true }));
  assert.equal((await send(app, "go")).status, 200);
  const running = (record: ReturnType<App["records"]>[number]) => record.type === "patch" && record.blocks.some(entry => "block" in entry && entry.block.type === "tool" && entry.block.name === "gated" && entry.block.state.type === "running");
  await app.until(record => running(record));
  assert.equal(app.records().filter(ofType("state")).at(-1)?.working, true);
  await writeFile(gate, "");
  await app.until(ofType("item", record => record.item.kind === "assistant" && record.item.blocks.some(block => block.type === "tool" && block.state.type === "done")));
});

test("a cancelled bang command keeps the output it wrote before the cancel in the stored item", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  await send(app, "!printf 'one\\ntwo\\n'; sleep 30");
  await app.until(ofType("state", record => record.bash.some(item => item.phase === "running" && item.output.text.includes("two"))));
  assert.equal((await app.post("abort")).status, 200);
  await app.until(ofType("state", record => record.bash.some(item => item.phase === "completed" && item.result.cancelled)));
  const controller = new AbortController();
  t.after(() => controller.abort());
  const replay = await sse(Readable.from((await fetch(app.base + "events", { signal: controller.signal })).body ?? [])).until(ofType("reset", record => record.items.some(item => item.kind === "bash")));
  const stored = replay.items.find(item => item.kind === "bash");
  assert.ok(stored && stored.kind === "bash");
  assert.equal(stored.result.cancelled, true);
  assert.match(stored.result.output.text, /one\ntwo/);
});

test("a turn aborted while the model streams ends as aborted, not as an error", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [{ reasoning: "thinking it over", text: "partial answer", midGate: "hold", tools: [{ name: "read", args: { path: "x" } }] }] });
  await send(app, "go");
  await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("partial answer")));
  assert.equal((await app.post("abort")).status, 200);
  await app.until(ofType("state", record => record.aborted === true && record.working === false));
  const controller = new AbortController();
  t.after(() => controller.abort());
  const replay = await sse(Readable.from((await fetch(app.base + "events", { signal: controller.signal })).body ?? [])).until(ofType("reset"));
  const last = replay.items.filter(item => item.kind === "assistant").at(-1);
  assert.ok(last && last.kind === "assistant");
  assert.equal(last.stop, "aborted");
  assert.equal(last.error, "");
  const live = app.records().flatMap(record => record.type === "patch" && record.stop === "aborted" ? [record.error] : record.type === "item" && record.item.kind === "assistant" && record.item.stop === "aborted" ? [record.item.error] : []);
  assert.ok(live.length > 0 && live.every(error => error === ""));
  assert.deepEqual(replay.items.flatMap(item => item.kind === "notify" && item.level === "error" ? [item.text.text] : []), []);
  assert.deepEqual(app.records().flatMap(record => record.type === "item" && record.item.kind === "notify" && record.item.level === "error" ? [record.item.text.text] : []), []);
});
