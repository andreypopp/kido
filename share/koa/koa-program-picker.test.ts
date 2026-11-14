import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer, type Socket } from "node:net";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import { Readable } from "node:stream";
import { pollUntil, sse, ofType } from "./koa-agent-fixture.ts";
import { realPi, realPiPackage, stopChild, writeSession } from "./koa-program-fixture.ts";
import { writeAgentDir } from "./koa-fake-provider.ts";

const koa = resolve("../../build/ko/share/ko/koa/koa.ts");

test("resume selects before the browser, cancels, and reports a broken picker", { timeout: 80000 }, async t => {
  const dir = await mkdtemp("/tmp/koa-resume-");
  const log = join(dir, "log"), urls = join(dir, "urls"), cwd = join(dir, "project"), sessions = join(dir, "sessions"), agent = join(dir, "agent");
  const server = createServer();
  const sockets = new Set<Socket>();
  server.on("connection", socket => { sockets.add(socket); socket.on("error", (error: NodeJS.ErrnoException) => { if (error.code !== "ECONNRESET") throw error; }); socket.once("close", () => sockets.delete(socket)); });
  t.after(async () => { for (const socket of sockets) socket.destroy(); server.close(); await rm(dir, { recursive: true, force: true }); });
  server.listen(join(dir, "gate")); await once(server, "listening");
  await Promise.all([mkdir(join(dir, "bin")), mkdir(cwd), mkdir(sessions), mkdir(join(dir, "home"))]);
  const chosen = await writeSession(realpathSync(cwd), sessions, 1, "chosen");
  await writeAgentDir(agent, "http://127.0.0.1:9/v1");
  await mkdir(join(dir, "libexec/lib/node_modules/@earendil-works"), { recursive: true });
  await symlink(realPiPackage, join(dir, "libexec/lib/node_modules/@earendil-works/pi-coding-agent"));
  const wrapper = join(dir, "bin", "pi");
  await writeFile(wrapper, `#!/bin/sh\ncase "$*" in *koa-resume.ts*) exec ${process.execPath} ${resolve("./koa-fake-picker.ts")} "$@";; *--version*) echo fake-pi-resume-1;; *) exec ${realPi} "$@";; esac\n`);
  await chmod(wrapper, 0o755);
  await writeFile(join(dir, process.platform === "darwin" ? "open" : "xdg-open"), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$OPEN_LOG"\n', { mode: 0o700 });
  const readLog = async () => (await readFile(log, "utf8")).trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  for (const item of [
    { gate: JSON.stringify({ type: "selected", path: chosen }), code: 0, output: /koa: http:/ },
    { gate: '{"type":"cancel"}', code: 0, output: /No session selected/ },
    { gate: "exit", code: 1, output: /fake-pi-resume-1.*session picker exited without a result/ },
    { gate: "rpc", code: 1, output: /fake-pi-resume-1.*session picker did not become ready/ },
    { gate: "eof", code: 1, output: /fake-pi-resume-1.*session picker exited without a result/ },
    { gate: "signal", code: 1, output: /session picker interrupted by SIGTERM/ },
    { gate: "skip", code: 0, output: /koa: http:/ },
  ]) await t.test(item.gate.startsWith("{") ? (item.gate.includes("selected") ? "selected" : "cancel") : item.gate, { timeout: 15000 }, async c => {
    await writeFile(log, ""); await rm(urls, { force: true });
    const connected = once(server, "connection");
    const pass = item.gate === "skip" ? ["--resume", "--session", chosen] : ["--resume", "-r", "--session-dir", sessions];
    const child = spawn(process.execPath, ["--import", resolve("./koa-fake-tty.ts"), koa, "--browser", "--pi", wrapper, ...pass], { stdio: "pipe", cwd, env: { ...process.env, HOME: join(dir, "home"), PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", KO_PANE: "", KOA_FAKE_LOG: log, KOA_FAKE_PICKER_GATE: join(dir, "gate"), KOA_RESUME_READY_MS: "1000", OPEN_LOG: urls, PATH: `${join(dir, "bin")}:${dir}:${process.env.PATH}` } });
    const closed = once(child, "close");
    const events = new AbortController();
    c.after(async () => { events.abort(); for (const socket of sockets) socket.destroy(); await stopChild(child, closed); });
    let output = ""; child.stdout.on("data", bytes => { output += bytes; }); child.stderr.on("data", bytes => { output += bytes; });
    const [gate] = await Promise.race([connected, closed.then(() => { throw new Error(output); }), new Promise<never>((_, reject) => { setTimeout(reject, 8000, new Error("no picker connection: " + output)).unref(); })]);
    assert.deepEqual((await readLog()).map(record => record.type), ["picker"]);
    assert.doesNotMatch(output, /koa: http:/);
    await assert.rejects(readFile(urls), { code: "ENOENT" });
    gate.end(item.gate);
    if (item.gate === "signal") child.kill("SIGTERM");
    if (item.gate === "skip" || item.gate.startsWith('{"type":"selected"')) {
      await pollUntil(() => /koa: http:/.test(output), 8000, "the koa URL");
      const base = output.match(/koa: (http:\/\/127\.0\.0\.1:\d+\/)/)?.[1]; assert.ok(base, output);
      const stream = await fetch(base + "events", { signal: events.signal });
      assert.ok(stream.body);
      const ready = await sse(Readable.from(stream.body)).until(ofType("state", record => record.pi?.type === "ready"));
      assert.equal(ready.sessionFile, chosen);
      assert.equal((await fetch(base + "quit", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 200);
    }
    assert.equal((await closed)[0], item.code, output);
    assert.match(output, item.output);
    if (item.gate === "signal") {
      assert.ok((await readLog()).some(record => record.type === "picker_signal" && record.signal === "SIGTERM"));
      assert.ok((await readLog()).some(record => record.type === "picker_exit"));
    }
  });
});
