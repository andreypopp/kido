import { test } from "node:test";
import assert from "node:assert/strict";
import { ChildProcess, spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { resolve } from 'node:path';
import { signalChild, piPackage, which } from './koa-child.ts';

test('pi package resolution follows an executable found through PATH', async () => {
  const root = resolve('../pi/node_modules/@earendil-works/pi-coding-agent');
  assert.equal(which('cli.js', root + '/dist'), root + '/dist/cli.js');
  assert.equal(await piPackage('cli.js', root + '/dist'), root);
});

test("signal errors are reported without throwing", t => {
  const child = new ChildProcess();
  Object.defineProperty(child, "pid", { value: 123 });
  const kill = process.kill;
  let output = "";
  const stderr = t.mock.method(process.stderr, "write", (text: string | Uint8Array) => { output += text; return true; });
  try {
    process.kill = () => { throw Object.assign(new Error("invalid signal"), { code: "EINVAL" }); };
    assert.doesNotThrow(() => signalChild(child, "SIGTERM"));
    assert.equal(output, "koa: SIGTERM: invalid signal\n");
  } finally { process.kill = kill; stderr.mock.restore(); }
});

test("signalling an unreaped child does not throw", async () => {
  const child = spawn("/usr/bin/true", [], { detached: true, stdio: "ignore" });
  const closed = once(child, "close");
  try {
    const deadline = Date.now() + 2000;
    let state = "";
    while (Date.now() < deadline) {
      state = spawnSync("/bin/ps", ["-o", "stat=", "-p", String(child.pid)], { encoding: "utf8", timeout: 1000 }).stdout.trim();
      if (state.startsWith("Z")) break;
    }
    assert.match(state, /^Z/);
    assert.equal(child.exitCode, null);
    assert.doesNotThrow(() => signalChild(child, "SIGKILL"));
  } finally { await closed; }
});
