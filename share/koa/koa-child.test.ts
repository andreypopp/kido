import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { signalChild } from "./koa-child.ts";

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
