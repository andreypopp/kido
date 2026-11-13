import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { connect } from "node:net";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import timers from "node:timers/promises";
import { pollUntil } from "./koa-agent-fixture.ts";
import { realFixture, realPi, stopChild } from "./koa-program-fixture.ts";
import { userParts } from "./koa-fake-provider.ts";

const koa = resolve("../../build/ko/share/ko/koa/koa.ts");
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

test("startup refuses incompatible flags before opening a webview", { timeout: 70000 }, async t => {
  for (const args of [["--mode", "text"], ["-p"], ["--export", "out.html"], ["--list-models"], ["-v"], ["--tui-mode", "fullscreen"], ["--theme", "dark"], ["--use-theme", "dark"], ["--no-themes"], ["@notes.txt"]]) await t.test(args.join(" "), { timeout: 10000 }, async c => {
    const child = spawn(process.execPath, [koa, "--browser", "--pi", realPi, ...args]);
    const closed = once(child, "close");
    c.after(() => stopChild(child, closed));
    let output = ""; child.stderr.on("data", bytes => { output += bytes; });
    const [code] = await closed;
    assert.equal(code, 1, output);
    assert.match(output, /koa: /);
    assert.doesNotMatch(output, /koa: http:/);
  });
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

test("quit exits at its deadline when the reply stalls and the client never reads", { timeout: 20000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-quit-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const hook = join(dir, "stall.mjs");
  await writeFile(hook, `import { ServerResponse } from "node:http";
    const end = ServerResponse.prototype.end;
    ServerResponse.prototype.end = function(...args) {
      return this.req.url === "/quit" ? this : end.apply(this, args);
    };`);
  const app = await realFixture(t, { replies: [], env: { NODE_OPTIONS: `--import=${hook}` } });
  const url = new URL(app.base);
  const body = JSON.stringify({ sessionId: app.records().filter(record => record.type === "state").at(-1)?.sessionId });
  const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`POST /quit HTTP/1.1\r\nHost: ${url.host}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`));
  socket.pause();
  socket.on("error", () => {});
  t.after(() => socket.destroy());
  assert.equal(await Promise.race([app.close.then(() => true), timers.setTimeout(8000, false, { ref: false })]), true);
});

test("a stuck extension shutdown is bounded and koa still exits", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [], extensions: { "stuck.ts": `export default function (pi) { pi.on("session_shutdown", () => new Promise(() => {})); }\n` } });
  assert.equal((await app.post("quit")).status, 200);
  assert.equal(await Promise.race([app.close.then(() => true), timers.setTimeout(15000, false, { ref: false })]), true);
});

