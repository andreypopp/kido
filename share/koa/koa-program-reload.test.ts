import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, cp, symlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pollUntil, ofType } from "./koa-agent-fixture.ts";
import { realFixture, writeSession } from "./koa-program-fixture.ts";

type App = Awaited<ReturnType<typeof realFixture>>;
const note = (text: string) => ofType("item", record => record.item.kind === "notify" && record.item.text.text === text);
const reload = (app: App) => app.post("prompt", { text: "/reload", mode: "prompt", attachments: [] });
const urls = (app: App) => (app.stderr().match(/koa: http:\/\/127\.0\.0\.1:\d+\//g) ?? []).length;

async function install(t: TestContext) {
  const dir = await mkdtemp("/tmp/koa-reload-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve("../../build/ko/share/ko/koa"), join(dir, "koa"), { recursive: true });
  await symlink(resolve("../../build/ko/share/ko/webview"), join(dir, "webview"));
  return dir;
}
const update = async (dir: string) => writeFile(join(dir, "koa/page.html"), (await readFile(join(dir, "koa/page.html"), "utf8")).replace("<title>koa</title>", "<title>RELOADED-MARKER</title>"));
const saved = async ({ cwd, sessions }: { cwd: string; sessions: string }) => ["--session", await writeSession(cwd, sessions, 1, "saved")];

test("/reload with an unchanged install reloads in place and keeps koa", { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, { replies: [], program: join(dir, "koa/koa.ts"), setup: saved });
  await reload(app);
  await app.until(note("reloaded"));
  assert.equal(urls(app), 1);
});

test("/reload restarts koa in place on the same session when only the install changed", { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, { replies: [], program: join(dir, "koa/koa.ts"), setup: saved });
  await update(dir);
  await reload(app);
  await pollUntil(() => urls(app) === 2, 10000, "the new koa incarnation");
});

test("a newer koa needs a saved session, and the agent still reloads", { timeout: 30000 }, async t => {
  const dir = await install(t);
  const app = await realFixture(t, { replies: [], program: join(dir, "koa/koa.ts"), args: ["--no-session"] });
  await update(dir);
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
  await update(dir);
  await reload(app);
  await app.until(note("reloaded · a newer koa waits for 1 job"));
  assert.equal(urls(app), 1);
  await app.post("prompt", { text: "/restart", mode: "prompt", attachments: [] });
  await pollUntil(() => urls(app) === 2, 10000, "the restart with a running job");
});
