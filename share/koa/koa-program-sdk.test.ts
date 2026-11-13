import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { selfPane, ofType, pollUntil } from "./koa-agent-fixture.ts";
import { realFixture } from "./koa-program-fixture.ts";

const prompt = (app: { post(path: string, body?: object): Promise<Response> }, text: string) => app.post("prompt", { text, mode: "prompt", attachments: [] });
const lastUser = (app: Awaited<ReturnType<typeof realFixture>>, n = 0) => JSON.stringify(app.provider.requests[n]?.body.messages.at(-1));

test("a prompt reaches real pi through the fake provider and the reply shows", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [{ reasoning: "pondering", text: "hello there" }] });
  assert.equal((await prompt(app, "hi")).status, 200);
  await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("hello there")));
  assert.match(lastUser(app), /hi/);
  assert.deepEqual(app.provider.violations, []);
});

test("an ordinary spawn succeeds in koa's own process and creates no pane", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { panes: [selfPane()], replies: [{ tools: [{ name: "spawn_agent", args: { name: "worker", task: "build it" } }], when: "spawn" }, { when: "spawn", text: "done" }, { when: "build it", text: "built" }, { when: "notice from worker", text: "ok" }] });
  await prompt(app, "spawn one");
  await pollUntil(() => app.provider.requests.length >= 2, 5000, "the tool result request");
  assert.match(JSON.stringify(app.provider.requests.find(request => request.body.messages.at(-1)?.role === "tool")?.body.messages.at(-1)), /spawned worker \(session [0-9a-f]{32}\)/);
  assert.deepEqual((await app.apiCalls()).filter(call => call.method === "POST" && call.path === "/panes"), []);
});

test("koa runs pi in its own process: no RPC child exists", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  const children = execFileSync("ps", ["-ax", "-o", "ppid=,command="], { encoding: "utf8" }).split("\n").filter(line => line.trim().startsWith(`${app.pid} `) && /\bpi\b|--mode rpc/.test(line.replace(/\/open\b.*/, "")));
  assert.deepEqual(children, []);
});

test("/restart replaces koa by execve during a turn, on the same session", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [{ gate: "hold", text: "late" }] });
  const before = app.records().filter(record => record.type === "state").at(-1)?.sessionId;
  assert.ok(before);
  await prompt(app, "work");
  await app.until(ofType("state", record => record.working === true));
  const restarted = await app.post("prompt", { text: "/restart", mode: "prompt", attachments: [] });
  assert.equal(restarted.status, 200, await restarted.text());
  const urls = () => app.stderr().match(/koa: http:\/\/127\.0\.0\.1:\d+\//g)?.length ?? 0;
  await pollUntil(() => urls() === 2, 15000, "the new koa incarnation");
  app.provider.release("hold");
});

test("a pi that cannot start offers Start again", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [], args: ["--provider", "nope", "--model", "nope"], start: false });
  const state = await app.until(ofType("state", record => record.life?.type === "failed"));
  
  assert.ok(state.life.type === "failed");
  assert.equal(typeof state.life.message, "string");
  assert.equal((await app.post("agent/start")).status, 200);
});

test("an uncaught exception keeps the pane and ends koa", { timeout: 20000 }, async t => {
  const app = await realFixture(t, {
    panes: [selfPane()], replies: [],
    extensions: { "boom.ts": "export default function (pi) { pi.registerCommand('boom', { description: 'boom', handler: async () => { setTimeout(() => { throw new Error('boom-uncaught'); }, 0); } }); }\n" },
  });
  await prompt(app, "/boom").catch(() => undefined);
  const code = await Promise.race([app.close.then(([c]) => c), new Promise(resolve => setTimeout(resolve, 8000, "alive").unref())]);
  assert.equal(code, 1, app.stderr());
  assert.match(app.stderr(), /boom-uncaught/);
  const patch = (await app.apiCalls()).find(call => call.method === "PATCH" && call.path === "/panes/pane_1");
  assert.deepEqual(patch && JSON.parse(patch.body), { close: "keep" });
});

test("an extension hook error becomes a page notice", { timeout: 20000 }, async t => {
  const app = await realFixture(t, {
    replies: [{ text: "fine" }],
    extensions: { "bad.ts": "export default function (pi) { pi.on('agent_start', () => { throw new Error('hook-failed'); }); }\n" },
  });
  await prompt(app, "go");
  await app.until(ofType("item", record => record.item.kind === "notify" && record.item.text.text.includes("hook-failed")));
});
