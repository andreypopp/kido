import { test } from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile, mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { sse, ofType, selfPane, pollUntil } from "./koa-agent-fixture.ts";
import type { PageRecord } from "./koa-records.ts";
import { realFixture } from "./koa-program-fixture.ts";

type App = Awaited<ReturnType<typeof realFixture>>;
type Listing = { agents: { name: string; target: { type: string; id?: string } }[] };
const send = (app: App, text: string) => app.post("prompt", { text, mode: "prompt", attachments: [] });
const state = (app: App) => {
  const found = app.records().filter(ofType("state")).at(-1);
  assert.ok(found);
  return found;
};
const viewOf = (record: Listing, name: string): string => {
  const found = record.agents.find(agent => agent.name === name)?.target;
  assert.ok(found?.type === "view" && found.id !== undefined);
  return found.id;
};
const listed = (name: string) => ofType("state", record => record.agents.some(agent => agent.name === name));
const items = (record: { items: object[] }) => JSON.stringify(record.items);
const spawn = (name: string, task: string) => ({ tools: [{ name: "spawn_agent", args: { name, task } }], when: "spawn" });
const kidScript = [spawn("kid", "work"), { when: "spawn", text: "spawned" }, { when: "work", text: "kid done" }, { when: "notice from kid", text: "noted" }];
const posted = async (app: App) => (await app.apiCalls()).filter(call => call.method === "POST" && call.path === "/panes");

test("an ordinary spawn is an agent of koa's own process: no pane, a view of its own, a report to the parent", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { panes: [selfPane()], replies: kidScript });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  assert.deepEqual(await posted(app), []);
  const rootId = state(app).view.id;
  const [directory] = await readdir(join(app.agentDir, "ko-subagents"));
  const file = (await readdir(join(app.agentDir, "ko-subagents", directory ?? ""))).find(name => name.endsWith(`${kid}.jsonl`));
  assert.ok(file, "the child's session lives outside pi's own tree");
  const edges = (await readFile(join(app.agentDir, "ko-subagents", directory ?? "", file ?? ""), "utf8")).split("\n").filter(line => line.includes('"koa.edge"')).map(line => JSON.parse(line).data);
  assert.deepEqual(edges.map(edge => [edge.owner, edge.parent]), [[kid, rootId]]);
  assert.deepEqual(state(app).view.path.map(node => node.id), [rootId]);
  await app.until(ofType("item", record => record.item.kind === "agent" && record.item.inbound.form === "report"));
  assert.match(JSON.stringify(app.provider.requests.find(request => request.body.messages.at(-1)?.role === "tool")?.body.messages.at(-1)), /spawned kid \(session [0-9a-f]{32}\)/);
  const cursor = app.count();
  assert.equal((await app.post("view", { id: kid })).status, 200);
  const switched = await app.until(ofType("state", record => record.view.id === kid), cursor);
  assert.deepEqual(switched.view.path.map(node => node.name), ["pi", "kid"]);
  const reset = await app.until(ofType("reset", record => items(record).includes("kid done")), cursor);
  assert.ok(!items(reset).includes("spawn one"));
  const back = app.count();
  assert.equal((await app.post("view", { id: rootId })).status, 200);
  await app.until(ofType("reset", record => items(record).includes("spawn one")), back);
  assert.deepEqual(app.provider.violations, []);
});

test("a request of the old view is refused after a switch, and a fresh page follows the selection", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: kidScript });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  await app.until(ofType("item", record => record.item.kind === "agent" && record.item.inbound.form === "report"));
  const rootSession = state(app).sessionId;
  assert.equal((await app.post("view", { id: kid })).status, 200);
  await app.until(ofType("state", record => record.view.id === kid));
  const late = await fetch(app.base + "abort", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sessionId: rootSession }) });
  assert.equal(late.status, 409);
  const controller = new AbortController();
  t.after(() => controller.abort());
  const fresh = await sse(Readable.from((await fetch(app.base + "events", { signal: controller.signal })).body ?? [])).until(ofType("state"));
  assert.equal(fresh.view.id, kid);
  assert.equal((await fetch(app.base + "history?sessionId=" + rootSession)).status, 409);
  assert.equal((await fetch(app.base + "history?sessionId=" + fresh.sessionId)).status, 200);
});

test("root-only commands are refused in a subagent's view with a warning line", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: kidScript });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  await app.post("view", { id: kid });
  await app.until(ofType("state", record => record.view.id === kid));
  assert.equal((await send(app, "/new")).status, 200);
  await app.until(ofType("item", record => record.item.kind === "notify" && record.item.text.text === "/new: only in @pi's view"));
  assert.equal((await app.post("sessions/new")).status, 409);
  assert.equal((await app.post("quit")).status, 409);
});

const acked = (app: App, id: string) => app.acks().then(list => list.filter(entry => entry.id === id).map(entry => entry.type));

test("the pane's one queue reaches the agent that data.to names; a select switches only for the user and a known record", { timeout: 30000 }, async t => {
  const replies = [...kidScript, { when: "hello kid", text: "hi" }, { when: "message from @external", text: "reply" }];
  const app = await realFixture(t, { panes: [selfPane()], replies });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  const rootId = state(app).view.id;
  const view = () => state(app).view.id;
  await app.feed({ id: "select-user-1", kind: "select", text: "agents/kid" });
  await pollUntil(() => view() === kid, 5000, "the select of the kid");
  const posts = await statusPosts(app);
  await app.feed({ id: "select-user-2", kind: "select", text: "" });
  await pollUntil(() => view() === rootId, 5000, "the select of the root");
  await pollUntil(async () => (await statusPosts(app)).slice(posts.length).some(post => post.id === "agents/kid" && post.selection === "offered"), 5000, "the former child record to be offered again");
  await app.feed({ id: "select-pane-3", kind: "select", text: "agents/kid", from: { type: "pane", pane: "pane_2", session: "other", name: "other" } });
  await app.feed({ id: "select-none-4", kind: "select", text: "agents/nobody" });
  await pollUntil(async () => (await acked(app, "select-none-4")).length > 0, 5000, "the last select ack");
  assert.equal(view(), rootId);
  assert.deepEqual(await acked(app, "select-pane-3"), ["ack"]);
  await app.feed({ id: "user-to-kid-5", kind: "user", text: "hello kid", data: { to: kid } });
  await app.feed({ id: "message-kid-6", kind: "message", text: "ping", data: { to: kid, from: { session: "0123456789abcdef", name: "external" } }, from: { type: "pane", pane: "pane_2", session: "other", name: "root-of-pane-2" } });
  await app.feed({ id: "unknown-to-7", kind: "message", text: "lost", data: { to: "no-such-session" }, from: { type: "pane", pane: "pane_2", session: "other", name: "x" } });
  await app.feed({ id: "stop-to-8", kind: "stop", text: "", data: { to: kid } });
  await pollUntil(async () => (await app.acks()).length >= 8, 5000, "all acks");
  assert.deepEqual(await acked(app, "unknown-to-7"), ["refuse"]);
  assert.deepEqual(await acked(app, "stop-to-8"), ["refuse"]);
  assert.deepEqual(await acked(app, "user-to-kid-5"), ["ack"]);
  const headers = () => app.provider.requests.map(request => JSON.stringify(request.body.messages.at(-1)));
  await pollUntil(() => headers().some(text => text.includes("message from @external")), 5000, "the message that names its sender");
  assert.ok(headers().some(text => text.includes("message from @external (session 0123456789abcdef in pane_2; another agent in this session, not the user):")), headers().join("\n"));
  assert.ok(!headers().some(text => text.includes("lost")));
});

test("a close of a record stops that subagent for the user only, with a notice to its parent", { timeout: 30000 }, async t => {
  const replies = [...kidScript, { when: "the user stopped subagent @kid", text: "close noted" }];
  const app = await realFixture(t, { panes: [selfPane()], replies });
  await send(app, "spawn one");
  await app.until(listed("kid"));
  await pollUntil(async () => (await statusPosts(app)).some(post => post.id === "agents/kid" && post.closeable === true), 10000, "the closeable record");
  await app.feed({ id: "close-pane-1", kind: "close", text: "agents/kid", from: { type: "pane", pane: "pane_2", session: "other", name: "other" } });
  await app.feed({ id: "close-none-2", kind: "close", text: "agents/nobody" });
  await app.feed({ id: "close-root-3", kind: "close", text: "" });
  await pollUntil(async () => (await app.acks()).length >= 3, 5000, "the first acks");
  assert.deepEqual(await acked(app, "close-pane-1"), ["ack"]);
  assert.ok(state(app).agents.some(agent => agent.name === "kid"));
  await app.feed({ id: "close-user-4", kind: "close", text: "agents/kid" });
  await pollUntil(() => !state(app).agents.some(agent => agent.name === "kid"), 10000, "the kid to go");
  await pollUntil(async () => (await statusPosts(app)).some(post => post.type === "clear" && post.id === "agents/kid"), 5000, "the clear of the kid's record");
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("the user stopped subagent @kid")), 10000, "the notice to the parent");
  assert.deepEqual(await acked(app, "close-user-4"), ["ack"]);
});

const tool = (name: string, args: object) => ({ name, args });
const statusPosts = async (app: App) => (await app.apiCalls()).filter(call => call.method === "POST" && call.path === "/panes/pane_1/status").map(call => JSON.parse(call.body));

test("a tree of three levels refuses a fourth, writes a record for each agent with its selection, and a stop takes the subtree", { timeout: 40000 }, async t => {
  const app = await realFixture(t, {
    panes: [selfPane()],
    replies: [
      { when: "spawn one", tools: [tool("spawn_agent", { name: "kid", task: "kidwork" })] },
      { when: "spawn one", text: "spawned" },
      { when: "kidwork", tools: [tool("spawn_agent", { name: "gk", task: "gkwork" })] },
      { when: "kidwork", text: "kid waits" },
      { when: "gkwork", tools: [tool("spawn_agent", { name: "deep", task: "deepwork" })] },
      { when: "gkwork", text: "gk done" },
      { when: "notice from gk", text: "kid got it" },
      { when: "notice from kid", text: "root noted" },
      { when: "stop it", tools: [tool("stop_agent", { agent: "kid" })] },
      { when: "stop it", text: "stopped" },
    ],
  });
  await send(app, "spawn one");
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("root noted")) || app.provider.requests.length >= 8, 15000, "the whole tree to settle");
  await pollUntil(async () => (await statusPosts(app)).some(post => post.id === "agents/kid" && post.state === "done"), 10000, "the kid's record to settle");
  const posts = await statusPosts(app);
  assert.ok(posts.some(post => post.id === "agents/kid/agents/gk" && post.title === "gk"));
  assert.ok(posts.every(post => post.type === "clear" || post.selection === "offered"), "no record is selected while the root is viewed");
  assert.ok(app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("refusing to spawn at depth 3: maximum nesting is 2")));
  const kid = viewOf(state(app), "kid");
  const before = (await statusPosts(app)).length;
  await app.feed({ id: "select-user-1", kind: "select", text: "agents/kid" });
  await pollUntil(() => state(app).view.id === kid, 5000, "the select");
  await pollUntil(async () => (await statusPosts(app)).slice(before).some(post => post.id === "agents/kid" && post.selection === "selected"), 5000, "the selected record");
  await app.feed({ id: "user-stop-2", kind: "user", text: "stop it" });
  await pollUntil(() => state(app).view.path.length === 1 && !state(app).agents.some(agent => agent.name === "kid"), 10000, "the stop to select the root and drop the kid");
  await pollUntil(async () => (await statusPosts(app)).some(post => post.type === "clear" && post.id === "agents/kid"), 5000, "the subtree clear");
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("stopped kid")), 5000, "the stop_agent result to reach the model");
  assert.deepEqual(app.provider.violations, []);
});

test("after an execve restart the children list as ended with 'koa restarted' and a message resumes one under its name, with its history", { timeout: 40000 }, async t => {
  const app = await realFixture(t, {
    replies: [
      { when: "spawn one", tools: [tool("spawn_agent", { name: "kid", task: "kidwork" })] },
      { when: "spawn one", text: "spawned" },
      { when: "kidwork", text: "kid done" },
      { when: "notice from kid", text: "root noted" },
      { when: "list them", tools: [tool("list_agents", {})] },
      { when: "list them", text: "listed" },
      { when: "continue kid", tools: [tool("message_agent", { to: "kid", message: "carry on" })] },
      { when: "continue kid", text: "sent" },
      { when: "carry on", text: "kid again" },
      { when: "notice from kid", text: "noted again" },
    ],
  });
  await send(app, "spawn one");
  await app.until(ofType("item", record => record.item.kind === "agent" && record.item.inbound.form === "report"));
  const urls = () => [...app.stderr().matchAll(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/g)].map(match => match[1] ?? "");
  assert.equal((await send(app, "/restart")).status, 200);
  await pollUntil(() => urls().length === 2, 15000, "the new koa incarnation");
  const base = urls()[1] ?? "";
  const controller = new AbortController();
  t.after(() => controller.abort());
  const page = sse(Readable.from((await fetch(base + "events", { signal: controller.signal })).body ?? []));
  const ready = await page.until(ofType("state", record => record.life.type === "ready"));
  assert.deepEqual(ready.agents, [], "no agent lives after the restart");
  const prompt = (text: string) => fetch(base + "prompt", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sessionId: ready.sessionId, text, mode: "prompt", attachments: [] }) });
  assert.equal((await prompt("list them")).status, 200);
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("koa restarted")), 10000, "the list result");
  assert.equal((await prompt("continue kid")).status, 200);
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("carry on")), 10000, "the resumed child's turn");
  const resumed = app.provider.requests.findLast(request => JSON.stringify(request.body.messages.at(-1)).includes("carry on"));
  assert.ok(JSON.stringify(resumed?.body.messages).includes("kid done"), "the child continues its own saved history");
  await page.until(listed("kid"));
  assert.deepEqual(app.provider.violations, []);
});

test("a request whose body arrives after a view switch is refused", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: kidScript });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  await app.until(ofType("item", record => record.item.kind === "agent" && record.item.inbound.form === "report"));
  const rootSession = state(app).sessionId;
  const url = new URL(app.base);
  const body = JSON.stringify({ sessionId: rootSession });
  const socket = connect(Number(url.port), "127.0.0.1");
  t.after(() => socket.destroy());
  let answer = "";
  socket.on("data", bytes => { answer += bytes; });
  socket.write(`POST /abort HTTP/1.1\r\nHost: ${url.host}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n`);
  assert.equal((await app.post("view", { id: kid })).status, 200);
  await app.until(ofType("state", record => record.view.id === kid));
  socket.write(body);
  await pollUntil(() => answer.includes("\r\n\r\n"), 5000, "the answer");
  assert.match(answer, /^HTTP\/1\.1 409/);
});

// Children discover extensions as any pi does, from the agent directory; the root of these tests loads none.
const inChildren = (source: string) => async ({ dir }: { dir: string }) => { await mkdir(join(dir, "agent", "extensions"), { recursive: true }); await writeFile(join(dir, "agent", "extensions", "probe.ts"), source); };
const holdsThird = (gate: string) => `export default async function () {
  const n = globalThis.__loads = (globalThis.__loads ?? 0) + 1;
  if (n === 2) while (!(await import("node:fs")).existsSync(${JSON.stringify(gate)})) await new Promise(resolve => setTimeout(resolve, 10));
}\n`;
const failsFirstStart = `export default function (pi) {
  pi.on("resources_discover", () => {
    if (globalThis.__failed) return undefined;
    globalThis.__failed = true;
    return { skillPaths: [123] };
  });
}\n`;

test("a creation that is pending while its parent is stopped does not survive the stop", { timeout: 40000 }, async t => {
  const gate = join(await mkdtemp(join(tmpdir(), "koa-gate-")), "gate");
  const app = await realFixture(t, {
    panes: [selfPane()],
    setup: inChildren(holdsThird(gate)),
    replies: [
      { when: "spawn one", tools: [tool("spawn_agent", { name: "kid", task: "kidwork" })] },
      { when: "spawn one", text: "spawned" },
      { when: "kidwork", tools: [tool("spawn_agent", { name: "gk", task: "gkwork" })] },
      { when: "kidwork", text: "kid ends" },
      { when: "stop it", tools: [tool("stop_agent", { agent: "kid" })] },
      { when: "stop it", text: "stopped" },
    ],
  });
  await send(app, "spawn one");
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("spawned kid")), 10000, "the kid");
  await app.feed({ id: "user-stop-1", kind: "user", text: "stop it" });
  await pollUntil(() => app.provider.requests.length >= 4, 10000, "the stop request and the gated creation");
  await writeFile(gate, "");
  await pollUntil(() => app.provider.requests.some(request => JSON.stringify(request.body.messages.at(-1)).includes("stopped kid")), 15000, "the stop to finish");
  await pollUntil(() => state(app).agents.length === 0, 5000, "the kid to leave the list");
  assert.ok(!(await statusPosts(app)).some(post => post.type === "set" && post.id === "agents/kid/agents/gk"), "the pending child was never published");
});

test("a child whose start failed starts again alone, from its saved session", { timeout: 40000 }, async t => {
  const app = await realFixture(t, {
    setup: inChildren(failsFirstStart),
    replies: [spawn("kid", "kidwork"), { when: "spawn", text: "spawned" }, { when: "kidwork", text: "kid done" }, { when: "notice from kid", text: "noted" }],
  });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  assert.equal((await app.post("view", { id: kid })).status, 200);
  const failed = await app.until(ofType("state", record => record.view.id === kid && record.life.type === "failed"));
  assert.equal(failed.life.type, "failed");
  assert.equal((await app.post("agent/start")).status, 200);
  await app.until(ofType("state", record => record.view.id === kid && record.life.type === "ready"), app.count() - 1);
  assert.equal(state(app).view.id, kid);
});

const pingScript = [...kidScript, { when: "ping kid", text: "pong" }];
const seen = (records: object[], text: string) => JSON.stringify(records).includes(text);

test("a named view streams and serves its own agent, and no request of it moves the pane's selection", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { panes: [selfPane()], replies: pingScript });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  await app.until(ofType("item", record => record.item.kind === "agent" && record.item.inbound.form === "report"));
  const rootId = state(app).view.id;
  const rootView = await app.subscribe(rootId), kidView = await app.subscribe(kid);
  assert.deepEqual([rootView.status, kidView.status], [200, 200]);
  const kidReset = await kidView.until(ofType("reset", record => items(record).includes("kid done")));
  assert.ok(!items(kidReset).includes("spawn one"));
  assert.ok(items(await rootView.until(ofType("reset"))).includes("spawn one"));
  assert.equal((await kidView.until(ofType("state"))).view.id, kid);
  assert.equal((await rootView.until(ofType("state"))).view.id, rootId);
  const before = app.count();
  assert.equal((await kidView.post("prompt", { text: "ping kid", mode: "prompt", attachments: [] })).status, 200);
  await pollUntil(() => seen(kidView.records(), "pong"), 10000, "the reply in the kid's view");
  assert.ok(!seen(rootView.records(), "ping kid"));
  assert.ok(!seen(app.records().slice(before), "ping kid"));
  assert.equal(state(app).view.id, rootId);
  const kidHistory: { entries: string[] } = await (await kidView.get("history")).json();
  const rootHistory: { entries: string[] } = await (await rootView.get("history")).json();
  assert.ok(kidHistory.entries.includes("ping kid") && !rootHistory.entries.includes("ping kid"));
  const kidItems: { items: object[] } = await (await kidView.get("items?before=100")).json();
  assert.ok(seen(kidItems.items, "pong"));
  const mark = rootView.records().length;
  assert.equal((await app.post("view", { id: kid })).status, 200);
  await app.until(ofType("state", record => record.view.id === kid));
  assert.equal((await app.post("view", { id: rootId })).status, 200);
  await app.until(ofType("state", record => record.view.id === rootId), app.count() - 1);
  await pollUntil(() => rootView.records().length > mark, 5000, "a state after the switch");
  assert.deepEqual(rootView.records().slice(mark).filter(record => record.type === "reset"), []);
  assert.equal(kidView.records().filter(ofType("state")).at(-1)?.view.id, kid);
  assert.equal(kidView.records().filter(record => record.type === "state" && "edit" in record).length, 0);
});

test("a named subagent view refuses root-only routes, and a stopped subtree ends its streams and its requests with view_gone", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { panes: [selfPane()], replies: kidScript });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  const rootId = state(app).view.id;
  const kidView = await app.subscribe(kid);
  await kidView.until(ofType("state"));
  for (const [path, body] of [["sessions/new", {}], ["sessions/list", { scope: "current" }], ["sessions/switch", { path: "/x" }], ["quit", {}]] as const) {
    const refused = await kidView.post(path, body);
    assert.equal(refused.status, 409, path);
    assert.match((await refused.json()).error, /only in @/);
  }
  assert.equal((await kidView.get("models")).status, 200);
  await pollUntil(async () => (await statusPosts(app)).some(post => post.id === "agents/kid" && post.closeable === true), 10000, "the closeable record");
  await app.feed({ id: "close-user-1", kind: "close", text: "agents/kid" });
  const gone = await kidView.until(ofType("view_gone"));
  assert.deepEqual([gone.view, gone.parent], [kid, rootId]);
  await pollUntil(() => kidView.ended(), 5000, "the end of the stream");
  const reopened = await app.subscribe(kid);
  assert.deepEqual([reopened.status, reopened.error?.kind, reopened.error?.view], [404, "view_gone", kid]);
  const late = await kidView.post("prompt", { text: "late", mode: "prompt", attachments: [] });
  assert.equal(late.status, 404);
  assert.equal((await late.json()).kind, "view_gone");
  assert.equal((await kidView.get("history")).status, 404);
});

const jobIdIn = (records: PageRecord[]): string | undefined => {
  for (const record of records) {
    const blocks = record.type === "patch" ? record.blocks.flatMap(entry => "block" in entry ? [entry.block] : []) : (record.type === "reset" ? record.items : record.type === "item" ? [record.item] : []).flatMap(item => item.kind === "assistant" ? item.blocks : []);
    for (const block of blocks) if (block.type === "tool" && block.job) return block.job.id;
  }
};

test("stopping an agent ends the named streams of its grandchild and its job with view_gone naming the surviving parent", { timeout: 40000 }, async t => {
  const app = await realFixture(t, { panes: [selfPane()], replies: [
    { when: "spawn one", tools: [tool("spawn_agent", { name: "kid", task: "kidwork" })] },
    { when: "spawn one", text: "spawned" },
    { when: "kidwork", tools: [tool("spawn_agent", { name: "gk", task: "gkwork" })] },
    { when: "kidwork", tools: [tool("async_bash", { command: "sleep 30", name: "nap" })] },
    { when: "kidwork", text: "kid waits" },
    { when: "gkwork", text: "gk done" },
    { when: "notice from gk", text: "kid got it" },
    { when: "notice from kid", text: "root noted" },
  ] });
  await send(app, "spawn one");
  const kid = viewOf(await app.until(listed("kid")), "kid");
  const rootId = state(app).view.id;
  const kidView = await app.subscribe(kid);
  const gk = viewOf(await kidView.until(listed("gk")), "gk");
  await pollUntil(() => jobIdIn(kidView.records()) !== undefined, 15000, "the kid's job");
  const job = jobIdIn(kidView.records()) ?? "";
  const gkView = await app.subscribe(gk), jobStream = await app.subscribe(job);
  assert.deepEqual([gkView.status, jobStream.status], [200, 200]);
  await jobStream.until(ofType("job-reset"));
  await pollUntil(async () => (await statusPosts(app)).some(post => post.id === "agents/kid" && post.closeable === true), 10000, "the closeable record");
  await app.feed({ id: "close-user-1", kind: "close", text: "agents/kid" });
  for (const [stream, id] of [[kidView, kid], [gkView, gk], [jobStream, job]] as const) {
    const gone = await stream.until(ofType("view_gone"));
    assert.deepEqual([gone.view, gone.parent], [id, rootId]);
    await pollUntil(() => stream.ended(), 5000, "the end of the stream");
  }
});
