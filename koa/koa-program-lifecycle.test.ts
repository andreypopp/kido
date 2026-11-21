import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pollUntil } from "./koa-agent-fixture.ts";
import { realFixture, realPi } from "./koa-program-fixture.ts";
import { userParts } from "./koa-fake-provider.ts";

const koa = resolve("../build/koa/share/koa/koa/koa.ts");
const send = (app: { post(path: string, body?: object): Promise<Response> }, text: string) => app.post("prompt", { text, mode: "prompt", attachments: [] });

test("--help prints usage without starting pi or a webview", { timeout: 5000 }, async () => {
  const child = spawn(process.execPath, [koa, "--help", "--pi", "/does-not-exist"], { env: { PATH: "" }, stdio: "pipe" });
  let stdout = "", stderr = "";
  child.stdout.on("data", bytes => { stdout += bytes; });
  child.stderr.on("data", bytes => { stderr += bytes; });
  const [code] = await once(child, "close");
  assert.equal(code, 0, stderr);
  assert.equal(stderr, "");
  assert.match(stdout, /Usage: koa/);
});

test("resume requires a terminal before starting a webview", { timeout: 20000 }, async t => {
  const child = spawn(process.execPath, [koa, "--browser", "--resume", "--pi", realPi], { stdio: "pipe" });
  t.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
  let stderr = ""; child.stderr.on("data", bytes => { stderr += bytes; });
  const [code] = await once(child, "close");
  assert.equal(code, 1);
  assert.match(stderr, /resume requires a terminal/);
  assert.doesNotMatch(stderr, /koa: http:/);
});

test("startup messages run separately after readiness without a page connection", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: "one" }, { text: "two" }], args: ["--", "first", "--help"] });
  await pollUntil(() => app.provider.requests.length === 2, 10000, "both startup prompts");
  const users = app.provider.requests.map(request => JSON.stringify(request.body.messages.filter(message => message.role === "user").at(-1)?.content));
  assert.match(users[0] ?? "", /first/);
  assert.match(users[1] ?? "", /--help/);
});

test("UTF-8 prompt text reaches the provider without replacement characters", { timeout: 20000 }, async t => {
  const app = await realFixture(t, { replies: [{ text: "ok" }] });
  const text = "héllo ✓ 😀 " + "ü".repeat(100000);
  assert.equal((await send(app, text)).status, 200);
  await pollUntil(() => app.provider.requests.length === 1, 10000, "the prompt");
  assert.equal(userParts(app.provider.requests[0])[0]?.text, text);
});

test("quit emits the session shutdown once and exits 0", { timeout: 20000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-quit-log-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const log = join(dir, "log");
  const app = await realFixture(t, { replies: [], extensions: { "shutdown.ts": `import { appendFileSync } from "node:fs"; export default function (pi) { pi.on("session_shutdown", (event) => { appendFileSync(${JSON.stringify(log)}, event.reason + "\\n"); }); }\n` } });
  assert.equal((await app.post("quit")).status, 200);
  assert.equal((await app.close)[0], 0);
  assert.equal(await readFile(log, "utf8"), "quit\n");
});

