import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, cp, symlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { Readable } from "node:stream";
import { pollUntil, ofType, sse } from "./koa-agent-fixture.ts";
import { realFixture, writeSession } from "./koa-program-fixture.ts";

type App = Awaited<ReturnType<typeof realFixture>>;
const note = (text: string) => ofType("item", record => record.item.kind === "notify" && record.item.text.text === text);
const reload = (app: App) => app.post("prompt", { text: "/reload", mode: "prompt", attachments: [] });
const urls = (app: App) => (app.stderr().match(/koa: http:\/\/127\.0\.0\.1:\d+\//g) ?? []).length;

async function install(t: TestContext) {
  const dir = await mkdtemp("/tmp/koa-reload-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../build/koa/share/koa/koa"), join(dir, "koa"), { recursive: true });
  await symlink(resolve("../build/koa/share/koa/webview"), join(dir, "webview"));
  return dir;
}
const updatePage = async (dir: string) => writeFile(join(dir, "koa/page.html"), (await readFile(join(dir, "koa/page.html"), "utf8")).replace("<title>koa</title>", "<title>RELOADED-MARKER</title>"));
const updateProgram = async (dir: string) => writeFile(join(dir, "koa/koa-identity.ts"), (await readFile(join(dir, "koa/koa-identity.ts"), "utf8")) + "\n// program change\n");
const saved = async ({ cwd, sessions }: { cwd: string; sessions: string }) => ["--session", await writeSession(cwd, sessions, 1, "saved")];

const instanceOf = (html: string) => html.match(/name="koa-instance" content="([^"]+)"/)?.[1] ?? "";
async function pageStream(t: TestContext, app: App, instance: string) {
  const controller = new AbortController();
  t.after(() => controller.abort());
  const response = await fetch(app.base + "events?koa=" + instance, { signal: controller.signal });
  assert.ok(response.body);
  return sse(Readable.from(response.body));
}

for (const mode of ["saved", "job", "no-session", "turn"] as const) test(`a page change swaps the document with ${mode}`, { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, {
    replies: mode === "job" ? [{ tools: [{ name: "async_bash", args: { command: "sleep 30", name: "bg" } }] }, { text: "started" }] : mode === "turn" ? [{ gate: "finish", text: "done" }] : [],
    program: join(dir, "koa/koa.ts"), ...(mode === "no-session" ? { args: ["--no-session"] } : { setup: saved }),
  });
  if (mode === "job" || mode === "turn") {
    await app.post("prompt", { text: "start", mode: "prompt", attachments: [] });
    await pollUntil(() => app.provider.requests.length >= (mode === "job" ? 2 : 1), 10000, "the model request");
    if (mode === "job") {
      await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("started")));
      await pollUntil(() => app.records().filter(ofType("state")).at(-1)?.working === false, 5000, "the turn to end");
    }
  }
  const before = await (await fetch(app.base)).text(), instance = instanceOf(before);
  assert.ok(instance);
  const stream = await pageStream(t, app, instance);
  await stream.until(ofType("state"));
  await updatePage(dir);
  const response = await reload(app);
  assert.deepEqual((await response.json()).action, { type: "none" });
  const after = await (await fetch(app.base)).text();
  assert.ok(after.includes("RELOADED-MARKER"), "the served document has the page marker");
  assert.notEqual(instanceOf(after), instance);
  await stream.until(ofType("reload"));
  await pollUntil(() => stream.state.ended, 5000, "the old document stream to end");
  await (await pageStream(t, app, instance)).until(ofType("reload"));
  await app.until(note(mode === "turn" ? "new page · agents not reloaded: a turn, a command, a queue, a dialog or an editor is open" : "reloaded · new page"));
  assert.equal(urls(app), 1);
  assert.equal(app.records().some(ofType("item", record => record.item.kind === "notify" && record.item.text.text.includes("a newer koa"))), false);
  if (mode === "turn") app.provider.release("finish");
});

test("an unreadable page keeps the old document", { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, { replies: [], program: join(dir, "koa/koa.ts"), setup: saved });
  const before = await (await fetch(app.base)).text();
  await rm(join(dir, "koa/page.js"));
  await reload(app);
  assert.equal(await (await fetch(app.base)).text(), before);
  await app.until(ofType("item", record => record.item.kind === "notify" && record.item.level === "warning" && record.item.text.text.includes("page could not be read")));
});

test("/reload restarts koa in place on the same session when only the install changed", { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, { replies: [], program: join(dir, "koa/koa.ts"), setup: saved });
  await updateProgram(dir);
  await reload(app);
  await pollUntil(() => urls(app) === 2, 10000, "the new koa incarnation");
});

test("a newer koa needs a saved session, and the agent still reloads", { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, { replies: [], program: join(dir, "koa/koa.ts"), args: ["--no-session"] });
  await updateProgram(dir);
  await reload(app);
  await app.until(note("reloaded · a newer koa needs a saved session"));
  assert.equal(urls(app), 1);
});

test("a newer koa waits while a job runs, and /restart restarts anyway", { timeout: 40000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, {
    replies: [{ tools: [{ name: "async_bash", args: { command: "sleep 30", name: "bg" } }] }, { text: "started" }],
    program: join(dir, "koa/koa.ts"), setup: saved,
  });
  await app.post("prompt", { text: "run a job", mode: "prompt", attachments: [] });
  await pollUntil(() => app.provider.requests.length === 2, 10000, "the tool result request");
  await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("started")));
  await pollUntil(() => app.records().filter(ofType("state")).at(-1)?.working === false, 5000, "the turn to end");
  await updateProgram(dir);
  await updatePage(dir);
  await reload(app);
  await app.until(note("reloaded · a newer koa waits for 1 job"));
  assert.doesNotMatch(await (await fetch(app.base)).text(), /RELOADED-MARKER/);
  assert.equal(urls(app), 1);
  await app.post("prompt", { text: "/restart", mode: "prompt", attachments: [] });
  await pollUntil(() => urls(app) === 2, 10000, "the restart with a running job");
});
