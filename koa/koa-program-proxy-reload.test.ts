import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { createServer } from "node:net";
import { request } from "node:http";
import { mkdtemp, mkdir, readFile, writeFile, rm, cp, symlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pollUntil, sse, ofType } from "./koa-agent-fixture.ts";
import { startProvider, writeAgentDir } from "./koa-fake-provider.ts";
import { realPi, stopChild, writeSession } from "./koa-program-fixture.ts";

test("reload and restart publish a ready document through the real pane proxy", { timeout: 30000 }, async t => {
  const cleanup: (() => unknown)[] = [];
  t.after(async () => {
    let first: unknown;
    for (const close of cleanup.reverse()) try { await close(); } catch (error) { first ??= error; }
    if (first) throw first;
  });
  const dir = await mkdtemp("/tmp/koa-proxy-reload-");
  cleanup.push(() => rm(dir, { recursive: true, force: true }));
  const ko = resolve("../build/ko/bin/ko");
  await cp(resolve('../build/koa/share/koa/koa'), join(dir, 'koa'), { recursive: true });
  await symlink(resolve('../build/koa/share/koa/webview'), join(dir, 'webview'));
  const program = join(dir, 'koa/koa.ts');
  const version = JSON.parse((await promisify(execFile)(ko, ['version'])).stdout);
  const env = { PATH: `${resolve('../build/ko/bin')}:${process.env.PATH}`, HOME: dir, LANG: "en_US.UTF-8" };
  const server = spawn(ko, ["--server", dir, "server"], { env, stdio: "pipe" });
  let serverLog = ''; server.stderr.on('data', bytes => { serverLog += bytes; });
  const serverClosed = once(server, "close");
  cleanup.push(async () => {
    try { await promisify(execFile)(ko, ['--server', dir, 'kill-server'], { env, timeout: 5000 }); }
    finally { await stopChild(server, serverClosed); }
  });
  const call = (path: string, body?: object, client?: string) => new Promise<import("node:http").IncomingMessage>((resolve, reject) => {
    const req = request({ socketPath: join(dir, "socket"), path, method: body ? "POST" : "GET", headers: { "Ko-Protocol": version.protocol, "Ko-Vt": version.vt, ...(body ? { "Content-Type": "application/json" } : {}), ...(client ? { "Ko-Client": client } : {}) } }, resolve);
    req.on("error", reject); req.setTimeout(5000, () => req.destroy(new Error(`proxy timed out: ${path}`))); req.end(body ? JSON.stringify(body) : undefined);
  });
  const json = async (path: string, body?: object) => {
    const response = await call(path, body); let text = "";
    for await (const bytes of response) text += bytes;
    assert.ok(response.statusCode && response.statusCode >= 200 && response.statusCode < 300, text); return JSON.parse(text);
  };
  await pollUntil(async () => { if (server.exitCode !== null) throw Error(serverLog); try { await json('/panes'); return true; } catch (error) { serverLog = String(error); return false; } }, 5000, "private ko server").catch(error => { throw Error(`${error}: ${serverLog}`); });
  const peer = spawn(ko, ["--server", dir, "api", "--stream", "/client"], { env, stdio: "pipe" });
  const peerClosed = once(peer, "close"); cleanup.push(() => stopChild(peer, peerClosed));
  const lines = createInterface({ input: peer.stdout });
  const welcome = once(lines, "line", { signal: AbortSignal.timeout(5000) });
  peer.stdin.write(JSON.stringify({ type: "hello", name: "koa-proxy-test", webview: true, focused: false, sizing: { type: "disabled" } }) + "\n");
  const greeting = JSON.parse((await welcome)[0]);
  assert.equal(greeting.type, 'welcome', JSON.stringify(greeting));
  const client = greeting.client;
  assert.equal(typeof client, 'string', JSON.stringify(greeting));
  const provider = await startProvider([]); cleanup.push(() => provider.close());
  const agentDir = join(dir, "agent"), sessions = join(dir, "sessions"), cwd = join(dir, "project");
  await Promise.all([mkdir(sessions), mkdir(cwd)]); await writeAgentDir(agentDir, provider.baseUrl);
  const session = await writeSession(cwd, sessions, 1, "proxy restart");
  const preload = join(dir, "listen-gate.mjs"), gatePath = join(dir, "gate");
  await writeFile(preload, `import {Server} from 'node:http';import {connect} from 'node:net';if(process.env.KOA_RELOAD!==undefined){const listen=Server.prototype.listen;Server.prototype.listen=function(...args){const server=this;const gate=connect(process.env.KOA_LISTEN_GATE);const timer=setTimeout(()=>{throw Error('listen gate timed out')},10000);gate.once('data',()=>{clearTimeout(timer);gate.end();listen.apply(server,args)});return server;};}`);
  const gated = new Set<import('node:net').Socket>();
  const gate = createServer(socket => { gated.add(socket); socket.on('close', () => gated.delete(socket)); }); await new Promise<void>(resolve => gate.listen(gatePath, resolve));
  cleanup.push(() => { for (const socket of gated) socket.destroy(); return new Promise<void>(resolve => gate.close(() => resolve())); });
  const pane = (await json('/panes', { cwd, command: { type: "argv", argv: [process.execPath, "--import", preload, program, "--pi", realPi, "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--session", session] }, env: Object.entries({ PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", KOA_LISTEN_GATE: gatePath }).map(([name, value]) => ({ name, value })) })).pane;
  const proxy = `/panes/${pane}/webview/`;
  const row = async () => (await json('/panes')).find((row: { id: string }) => row.id === pane);
  await pollUntil(async () => { const webview = (await row())?.webview; return webview?.serving === true && !!webview.page; }, 10000, "initial serving pane").catch(async error => { throw Error(`${error}: ${JSON.stringify(await json(`/panes/${pane}/screen`))}`); });
  const state = async () => {
    const response = await call(proxy + 'events', undefined, client);
    if (response.statusCode !== 200) { let error = ''; for await (const bytes of response) error += bytes; assert.fail(error); }
    const stream = sse(response);
    try { return await stream.until(ofType('state', state => state.life?.type === 'ready')); }
    finally { response.destroy(); }
  };
  const original = await state();
  for (const command of ["/reload", "/restart"]) {
    if (command === '/reload') await writeFile(join(dir, 'koa/page.html'), (await readFile(join(dir, 'koa/page.html'), 'utf8')).replace('<title>koa</title>', '<title>RELOADED-MARKER</title>'));
    const entered = once(gate, 'connection', { signal: AbortSignal.timeout(10000) });
    const response = await call(proxy + 'prompt', { sessionId: original.sessionId, text: command, mode: 'prompt', attachments: [] }, client);
    response.resume(); assert.equal(response.statusCode, 200);
    const [replacement] = await entered;
    try {
      if ((await row())?.webview?.serving) {
        const document = await call(proxy, undefined, client); let body = '';
        for await (const bytes of document) body += bytes;
        assert.equal(document.statusCode, 200, body);
      }
    } finally { replacement.end('release'); }
    await pollUntil(async () => (await row())?.webview?.serving === true, 10000, 'replacement serving pane');
    const document = await call(proxy, undefined, client); let html = '';
    for await (const bytes of document) html += bytes;
    assert.equal(document.statusCode, 200, html); assert.match(html, /<title>RELOADED-MARKER<\/title>/);
    assert.equal((await state()).sessionId, original.sessionId);
  }
});
