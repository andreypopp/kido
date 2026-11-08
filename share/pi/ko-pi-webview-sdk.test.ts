import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { createServer } from "node:http";
import { connect, createServer as createNetServer } from "node:net";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { webview, type Webview } from "../webview/index.ts";
import { makeFixture, pollUntil } from "./ko-pi-fixture.ts";

test("browser Host guard and show/hide rules", { timeout: 15000 }, async () => {
  const wv = await webview({ target: "browser" });
  assert.ok(wv);
  let requests = 0;
  let finishStream: (() => void) | undefined;
  const server = createServer((req, res) => {
    requests++;
    if (req.url === "/stream") {
      res.write("first");
      finishStream = () => res.end("last");
    } else if (req.method === "POST") {
      let body = "";
      req.on("data", bytes => { body += bytes; });
      req.on("end", () => res.end(JSON.stringify({ method: req.method, path: req.url, body })));
    } else res.end(req.url === "/" ? "app body" : req.url);
  });
  server.on("upgrade", (req, socket) => {
    const accept = createHash("sha1").update(`${req.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    let buffered = Buffer.alloc(0);
    socket.on("data", bytes => {
      buffered = Buffer.concat([buffered, bytes]);
      if (buffered.length < 6) return;
      const length = buffered[1]! & 127;
      if (buffered.length < 6 + length) return;
      const payload = Buffer.from(buffered.subarray(6, 6 + length));
      for (let i = 0; i < length; i++) payload[i] = payload[i]! ^ buffered[2 + i % 4]!;
      socket.write(Buffer.concat([Buffer.from([0x81, length]), payload]));
      buffered = buffered.subarray(6 + length);
    });
    socket.on("error", () => socket.destroy());
    socket.on("end", () => socket.destroy());
  });
  await new Promise<void>(resolve => server.listen(wv.socketPath, resolve));
  try {
    const url = new URL(wv.url!);
    const response = await new Promise<string>((resolve, reject) => {
      const socket = connect(Number(url.port), "127.0.0.1", () => socket.end(`GET / HTTP/1.1\r\nHost: evil.example:${url.port}\r\n\r\n`));
      let data = "";
      socket.on("data", bytes => { data += bytes; });
      socket.on("end", () => resolve(data));
      socket.on("error", reject);
    });
    assert.match(response, /421 Misdirected Request/);
    assert.equal(requests, 0);
    assert.equal(await (await fetch(wv.url!)).text(), "app body");
    const post = await fetch(`${wv.url}submit?q=1`, { method: "POST", body: "hello body" });
    assert.deepEqual(await post.json(), { method: "POST", path: "/submit?q=1", body: "hello body" });
    const pipelined = await new Promise<string>((resolve, reject) => {
      const socket = connect(Number(url.port), "127.0.0.1", () => {
        socket.write("GET /first HTTP/1.1\r\nHo", () => {
          socket.write(`st: localhost:${url.port}\r\n\r\nGET /second HTTP/1.1\r\nHost: localhost:${url.port}\r\nConnection: close\r\n\r\n`);
        });
      });
      let data = "";
      socket.on("data", bytes => { data += bytes; });
      socket.on("end", () => resolve(data));
      socket.on("error", reject);
    });
    assert.equal((pipelined.match(/HTTP\/1.1 200 OK/g) ?? []).length, 2);
    assert.ok(pipelined.indexOf("/first") > 0);
    assert.ok(pipelined.indexOf("/second") > pipelined.indexOf("/first"));
    const stream = await fetch(`${wv.url}stream`);
    const reader = stream.body!.getReader();
    assert.equal(new TextDecoder().decode((await reader.read()).value), "first");
    finishStream!();
    assert.equal(new TextDecoder().decode((await reader.read()).value), "last");
    assert.equal((await reader.read()).done, true);
    await new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(wv.url!.replace("http:", "ws:"));
      ws.onopen = () => ws.send("hello");
      ws.onerror = () => reject(new Error("WebSocket failed"));
      ws.onmessage = event => { try { assert.equal(event.data, "hello"); resolve(); } catch (error) { reject(error); } finally { ws.close(); } };
    });
  } finally {
    await wv.close();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
  assert.equal(existsSync(dirname(wv.socketPath)), false);
  await assert.rejects(fetch(wv.url!));
  const dir = mkdtempSync(join(tmpdir(), "webview-open-"));
  const log = join(dir, "urls");
  writeFileSync(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  try {
    const script = `import { webview } from ${JSON.stringify(new URL("../webview/index.ts", import.meta.url).href)};
      const wv = await webview({ target: "browser" });
      const assert = (await import("node:assert/strict")).default;
      try {
        await assert.rejects(wv.show("page"), /must start/);
        await assert.rejects(wv.show("@example.com/"), /must start/);
        await wv.show(); await wv.show(); await wv.show("/b"); await wv.hide(); await wv.show("/b");
        await wv.show("/a?b#c");
      } finally { await wv.close(); }`;
    await new Promise<void>((resolve, reject) => {
      const child = spawn(process.execPath, ["--input-type=module", "-e", script], { env: { ...process.env, PATH: dir, OPEN_LOG: log }, stdio: ["ignore", "ignore", "pipe"] });
      let error = "";
      child.stderr.on("data", bytes => { error += bytes; });
      child.once("error", reject);
      child.once("close", code => code === 0 ? resolve() : reject(new Error(error)));
    });
    const urls = readFileSync(log, "utf8").trim().split("\n");
    assert.equal(urls.length, 3);
    assert.match(urls[0], /^http:\/\/127\.0\.0\.1:\d+\/$/);
    assert.equal(urls[1], `${urls[0]}b`);
    assert.equal(urls[2], `${urls[0]}a?b#c`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test("browser preserves a write-side EOF and handles an absent app", { timeout: 15000 }, async () => {
  const wv = await webview({ target: "browser" });
  const url = new URL(wv.url!);
  const expected = `POST /eof HTTP/1.1\r\nHost: 127.0.0.1:${url.port}\r\nContent-Length: 4\r\n\r\nbody`;
  let received = "";
  const app = createNetServer({ allowHalfOpen: true }, socket => {
    socket.on("data", bytes => { received += bytes; });
    socket.on("end", () => socket.end("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nafter EOF ok"));
  });
  try {
    await new Promise<void>(resolve => app.listen(wv.socketPath, resolve));
    const response = await new Promise<string>((resolve, reject) => {
      const socket = connect(Number(url.port), "127.0.0.1", () => socket.end(expected));
      let bytes = "";
      socket.on("data", chunk => { bytes += chunk; });
      socket.on("end", () => resolve(bytes));
      socket.on("error", reject);
    });
    assert.equal(received, expected);
    assert.equal(response, "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nafter EOF ok");
    await new Promise<void>(resolve => app.close(() => resolve()));
    await new Promise<void>((resolve, reject) => {
      const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`GET / HTTP/1.1\r\nHost: localhost:${url.port}\r\n\r\n`));
      socket.on("data", () => reject(new Error("absent app sent data")));
      socket.on("error", error => { if ((error as NodeJS.ErrnoException).code !== "ECONNRESET") reject(error); });
      socket.on("close", () => resolve());
    });
  } finally {
    await wv.close();
    if (app.listening) await new Promise<void>(resolve => app.close(() => resolve()));
  }
});

test("browser forwards a complete large Connection close response", { timeout: 5000 }, async () => {
  const wv = await webview({ target: "browser" });
  const body = "0123456789abcdef".repeat(256 * 1024);
  const server = createServer((_req, response) => {
    response.writeHead(200, { "Connection": "close", "Content-Length": Buffer.byteLength(body) });
    response.end(body);
  });
  await new Promise<void>(resolve => server.listen(wv.socketPath, resolve));
  try {
    assert.equal(await (await fetch(wv.url!)).text(), body);
  } finally {
    await wv.close();
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});

test("browser close drains an in-flight response to a slow reader", { timeout: 5000 }, async () => {
  const wv = await webview({ target: "browser" });
  const body = "0123456789abcdef".repeat(256 * 1024);
  let started: () => void = () => {};
  const requested = new Promise<void>(resolve => { started = resolve; });
  const server = createServer((_req, response) => { response.end(body); started(); });
  await new Promise<void>(resolve => server.listen(wv.socketPath, resolve));
  const url = new URL(wv.url!);
  const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`GET / HTTP/1.1\r\nHost: localhost:${url.port}\r\n\r\n`));
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
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});

test("browser close ends an unresponsive forward at its deadline", { timeout: 4000 }, async () => {
  const wv = await webview({ target: "browser" });
  let requested: () => void = () => {};
  const ready = new Promise<void>(resolve => { requested = resolve; });
  let eof = false;
  const peers = new Set<import("node:net").Socket>();
  const server = createNetServer({ allowHalfOpen: true }, socket => {
    peers.add(socket);
    socket.on("data", requested);
    socket.on("end", () => { eof = true; });
    socket.on("close", () => peers.delete(socket));
  });
  await new Promise<void>(resolve => server.listen(wv.socketPath, resolve));
  const url = new URL(wv.url!);
  const socket = connect(Number(url.port), "127.0.0.1", () => socket.write(`GET / HTTP/1.1\r\nHost: localhost:${url.port}\r\n\r\n`));
  const closed = new Promise<void>(resolve => { socket.on("close", resolve); socket.on("error", () => {}); });
  try {
    await ready;
    await wv.close();
    await closed;
    assert.equal(eof, true);
    await assert.rejects(fetch(wv.url!));
  } finally {
    socket.destroy();
    for (const peer of peers) peer.destroy();
    await wv.close();
    await new Promise<void>(resolve => server.close(() => resolve()));
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
    const wv = await webview({ target: "browser" });
    const port = Number(new URL(wv.url).port);
    const forwarded = connect(port, "127.0.0.1");
    await new Promise(resolve => forwarded.once("connect", resolve));
    const disconnected = new Promise(resolve => forwarded.once("close", resolve));
    const showing = wv.show();
    const opener = await started;
    try {
      await wv.close();
      await disconnected;
      assert.equal(existsSync(dirname(wv.socketPath)), false);
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
  try {
    delete process.env.KO_PANE;
    assert.equal(await webview(), null);
    assert.match(readFileSync(join(fx.dir, "ko.jsonl"), "utf8"), /"webview","serve","--socket"/);
    process.env.KO_PANE = "pane_1";
    assert.equal(await webview({ ko: join(fx.dir, "missing") }), null);
    const refused = join(fx.dir, "refused");
    writeFileSync(refused, "#!/bin/sh\nprintf 'bridge refused\\n' >&2\nexit 1\n", { mode: 0o700 });
    await assert.rejects(webview({ ko: refused }), /bridge refused/);
    wv = await webview({ ko: join(fx.binDir, "ko") });
    assert.ok(wv);
    assert.equal(wv.supported, false);
    assert.equal(statSync(dirname(wv.socketPath)).mode & 0o777, 0o700);
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
    wv = await webview({ ko: join(fx.binDir, "ko") });
    assert.ok(wv);
    wv.on("supported", listener);
    changes.length = 0;
    writeFileSync(process.env.KO_FAKE_SERVE_DROP, "");
    await pollUntil(() => changes.includes(false) && changes.at(-1) === true);
    const socket = wv.socketPath;
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
