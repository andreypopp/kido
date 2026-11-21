import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { createServer } from "node:http";
import net from "node:net";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { webview, type Webview } from "../webview/index.ts";
import { makeFixture, pollUntil } from "./koa-agent-fixture.ts";

function urlOf(view: Webview): string {
  assert.ok(view.url);
  return view.url;
}

test("bridge readiness expires and removes its directory", { timeout: 5000 }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "webview-ready-"));
  const ko = join(dir, "ko");
  writeFileSync(ko, `#!/bin/sh\nprintf '%s' "$4" > '${dir}/socket'\nexec /bin/cat\n`, { mode: 0o700 });
  try {
    await assert.rejects(webview(createServer(), { ko, timeoutMs: 1000 }), /timed out/);
    const socket = readFileSync(join(dir, "socket"), "utf8");
    assert.equal(existsSync(dirname(socket)), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("browser checks every request origin", { timeout: 5000 }, async () => {
  let calls = 0;
  const app = createServer((_req, res) => { calls++; res.end("ok"); });
  app.on("upgrade", (_req, socket) => { calls++; socket.destroy(); });
  const view = await webview(app, { target: "browser" });
  const url = new URL(urlOf(view));
  const raw = (request: string) => new Promise<string>((resolve, reject) => {
    const socket = net.connect(Number(url.port), "127.0.0.1", () => socket.end(request));
    let data = "";
    socket.on("data", bytes => { data += bytes; }); socket.on("end", () => resolve(data)); socket.on("error", reject);
  });
  try {
    for (const origin of ["null", "https://foreign.example", `http://localhost:${url.port}`, `${url.origin}/`, `${url.origin}\r\nOrigin: ${url.origin}`]) {
      assert.equal((await fetch(urlOf(view), { method: "POST", headers: { Origin: origin.includes("\r") ? "null" : origin }, body: "bad" })).status, 403);
      assert.match(await raw(`GET / HTTP/1.1\r\nHost: ${url.host}\r\nOrigin: ${origin}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`), /403/);
    }
    assert.equal(calls, 0);
    const pipelined = await raw(`GET / HTTP/1.1\r\nHost: ${url.host}\r\nOrigin: null\r\n\r\nPOST / HTTP/1.1\r\nHost: ${url.host}\r\nOrigin: null\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    assert.match(pipelined, /403/); assert.equal(calls, 0);
    const second = await raw(`GET / HTTP/1.1\r\nHost: ${url.host}\r\n\r\nPOST / HTTP/1.1\r\nHost: ${url.host}\r\nOrigin: null\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    assert.match(second, /200 OK/); assert.match(second, /403 Forbidden/); assert.equal(calls, 1);
    assert.equal((await fetch(urlOf(view), { headers: { Origin: url.origin } })).status, 200);
    assert.equal((await fetch(urlOf(view))).status, 200);
    assert.equal(calls, 3);
  } finally { await view.close(); }
});

test("browser preserves a write-side EOF and handles an absent app", { timeout: 15000 }, async () => {
  let received = "";
  const app = createServer((request, response) => {
    request.on("data", bytes => { received += bytes; });
    request.on("end", () => response.end("after EOF ok"));
  });
  const wv = await webview(app, { target: "browser" });
  const url = new URL(urlOf(wv));
  const expected = `POST /eof HTTP/1.1\r\nHost: 127.0.0.1:${url.port}\r\nContent-Length: 4\r\n\r\nbody`;
  try {
    const response = await new Promise<string>((resolve, reject) => {
      const socket = net.connect(Number(url.port), "127.0.0.1", () => socket.end(expected));
      let bytes = "";
      socket.on("data", chunk => { bytes += chunk; });
      socket.on("end", () => resolve(bytes));
      socket.on("error", reject);
    });
    assert.equal(received, "body");
    assert.match(response, /after EOF ok$/);
    await new Promise<void>(resolve => app.close(() => resolve()));
    await new Promise<void>((resolve, reject) => {
      const socket = net.connect(Number(url.port), "127.0.0.1", () => socket.write(`GET / HTTP/1.1\r\nHost: localhost:${url.port}\r\n\r\n`));
      socket.on("data", () => reject(new Error("absent app sent data")));
      socket.on("error", error => { if (Reflect.get(error, "code") !== "ECONNRESET") reject(error); });
      socket.on("close", () => resolve());
    });
  } finally {
    await wv.close();
    if (app.listening) await new Promise<void>(resolve => app.close(() => resolve()));
  }
});

test("browser forwards a complete large Connection close response", { timeout: 5000 }, async () => {
  const body = "0123456789abcdef".repeat(256 * 1024);
  const server = createServer((_req, response) => {
    response.writeHead(200, { "Connection": "close", "Content-Length": Buffer.byteLength(body) });
    response.end(body);
  });
  const wv = await webview(server, { target: "browser" });
  try {
    assert.equal(await (await fetch(urlOf(wv))).text(), body);
  } finally {
    await wv.close();
  }
});

test("browser close drains an in-flight response to a slow reader", { timeout: 5000 }, async () => {
  const body = "0123456789abcdef".repeat(256 * 1024);
  let started: () => void = () => {};
  const requested = new Promise<void>(resolve => { started = resolve; });
  const server = createServer((_req, response) => { response.end(body); started(); });
  const wv = await webview(server, { target: "browser" });
  const url = new URL(urlOf(wv));
  const socket = net.connect(Number(url.port), "127.0.0.1", () => socket.write(`GET / HTTP/1.1\r\nHost: localhost:${url.port}\r\n\r\n`));
  socket.pause();
  let received = "";
  const ended = new Promise<void>((resolve, reject) => {
    socket.on("data", bytes => { received += bytes; });
    socket.on("end", resolve);
    socket.on("error", reject);
    socket.on("close", () => resolve());
  });
  try {
    await requested;
    const closing = wv.close();
    socket.resume();
    await ended;
    await closing;
    assert.equal(received.slice(received.indexOf("\r\n\r\n") + 4), body);
  } finally {
    socket.destroy();
    await wv.close();
  }
});

test("browser close does not wait for an opener", { timeout: 15000 }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "webview-blocked-open-"));
  const gate = join(dir, "gate");
  writeFileSync(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), `#!${process.execPath}\nconst { connect } = require("node:net"); const socket = connect(process.env.OPEN_GATE); socket.on("data", () => socket.end());\n`, { mode: 0o700 });
  const script = `
    import assert from "node:assert/strict";
    import { existsSync } from "node:fs";
    import { dirname } from "node:path";
    import { createServer, connect } from "node:net";
    import { webview } from ${JSON.stringify(new URL("../webview/index.ts", import.meta.url).href)};
    const gate = createServer();
    await new Promise(resolve => gate.listen(process.env.OPEN_GATE, resolve));
    const started = new Promise(resolve => gate.once("connection", resolve));
    const app = (await import("node:http")).createServer();
    const wv = await webview(app, { target: "browser" });
    const socketPath = app.address();
    const port = Number(new URL(wv.url).port);
    const forwarded = connect(port, "127.0.0.1");
    await new Promise(resolve => forwarded.once("connect", resolve));
    const disconnected = new Promise(resolve => forwarded.once("close", resolve));
    const showing = assert.rejects(wv.show(), /closed/);
    const opener = await started;
    try {
      await wv.close();
      await disconnected;
      assert.equal(existsSync(dirname(socketPath)), false);
      await assert.rejects(fetch(wv.url));
      assert.equal(wv.shown, false);
    } finally { opener.end("release"); }
    await showing;
    assert.equal(wv.shown, false);
    await assert.rejects(wv.show(), /closed/);
    await new Promise(resolve => gate.close(resolve));
  `;
  try {
    await new Promise<void>((resolve, reject) => {
      const child = spawn(process.execPath, ["--input-type=module", "-e", script], { env: { ...process.env, PATH: dir, OPEN_GATE: gate }, stdio: ["ignore", "ignore", "pipe"] });
      let error = "";
      child.stderr.on("data", bytes => { error += bytes; });
      child.once("error", reject);
      child.once("close", code => code === 0 ? resolve() : reject(new Error(error)));
    });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("webview SDK support events, TTY, arguments, restart and close", async () => {
  const fx = makeFixture();
  const tty = process.stdout.isTTY;
  let wv: Webview | null = null;
  const app = createServer();
  try {
    delete process.env.KO_PANE;
    assert.equal(await webview(app), null);
    assert.match(readFileSync(join(fx.dir, "ko.jsonl"), "utf8"), /"webview","serve","--socket"/);
    process.env.KO_PANE = "pane_1";
    assert.equal(await webview(app, { ko: join(fx.dir, "missing") }), null);
    const refused = join(fx.dir, "refused");
    writeFileSync(refused, "#!/bin/sh\nprintf 'bridge refused\\n' >&2\nexit 1\n", { mode: 0o700 });
    await assert.rejects(webview(app, { ko: refused }), /bridge refused/);
    wv = await webview(app, { ko: join(fx.binDir, "ko") });
    assert.ok(wv);
    assert.equal(wv.supported, false);
    const privateSocket = app.address(); assert.ok(typeof privateSocket === "string");
    assert.equal(statSync(dirname(privateSocket)).mode & 0o777, 0o700);
    const changes: boolean[] = [];
    const listener = (value: boolean) => { changes.push(value); };
    wv.on("supported", listener);
    fx.serve({ type: "supported", supported: true });
    await pollUntil(() => changes.length === 1);
    assert.equal(wv.supported, true);
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: false });
    await assert.rejects(wv.show(), /TTY/);
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: true });
    assert.equal(wv.shown, false);
    await wv.hide();
    await Promise.all([wv.show("/page?q=1"), wv.show("/page?q=1")]);
    assert.equal(wv.shown, true);
    await wv.show("/a");
    await wv.show("/b");
    assert.equal(fx.webviewActions().length, 3);
    await wv.show("/b");
    assert.equal(fx.webviewActions().length, 3);
    await Promise.all([wv.hide(), wv.hide()]);
    assert.equal(wv.shown, false);
    await wv.show("/b");
    await wv.show();
    await wv.show();
    assert.deepEqual(fx.webviewActions(), ["enter", "enter", "enter", "leave", "enter", "enter"]);
    const args = readFileSync(join(fx.dir, "ko.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    assert.deepEqual(args.filter(argv => argv[0] === "webview" && argv[1] === "enter"), [
      ["webview", "enter", "--path", "/page?q=1"],
      ["webview", "enter", "--path", "/a"],
      ["webview", "enter", "--path", "/b"],
      ["webview", "enter", "--path", "/b"],
      ["webview", "enter"],
    ]);
    process.env.KO_FAKE_SERVE_DROP = join(fx.dir, "serve-drop");
    const closingView = wv;
    let shutdownNotifications = 0;
    wv.on("supported", value => { if (!value) { shutdownNotifications++; void closingView.hide(); } });
    assert.equal(wv.supported, true);
    await wv.close();
    assert.equal(shutdownNotifications, 0);
    assert.equal(wv.shown, false);
    wv = await webview(app, { ko: join(fx.binDir, "ko") });
    assert.ok(wv);
    wv.on("supported", listener);
    changes.length = 0;
    writeFileSync(process.env.KO_FAKE_SERVE_DROP, "");
    await pollUntil(() => changes.includes(false) && changes.at(-1) === true);
    const socket = app.address(); assert.ok(typeof socket === "string");
    wv.off("supported", listener);
    await wv.close();
    assert.equal(existsSync(dirname(socket)), false);
    assert.equal(fx.webviewActions().at(-1), "leave");
    await wv.close();
  } finally {
    await wv?.close();
    Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: tty });
    await fx.restore();
  }
});
