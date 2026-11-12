import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, gatedCommand, get } from "./koa-agent-fixture.ts";

test("the restart state counts running jobs, services included, and unreported subagents, and stops receiving queries at shutdown", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    const ask = async () => get(await s.channel.ask({ type: "restart_state" }), "state");
    assert.deepEqual(await ask(), { type: "ready" });
    const gate = join(fx.dir, "gate");
    await s.tool("async_bash").execute("a", { command: gatedCommand(gate, "x\n", "y\n", 0), name: "build" });
    await s.tool("async_bash").execute("b", { command: gatedCommand(join(fx.dir, "service-gate"), "x\n", "y\n", 0), name: "server", service: true });
    assert.deepEqual(await ask(), { type: "blocked", jobs: 2, children: 0 });
    await s.tool("spawn_agent").execute("c", { name: "worker", task: "build it", model: undefined });
    assert.deepEqual(await ask(), { type: "blocked", jobs: 2, children: 1 });
    await s.emit("session_shutdown", { reason: "reload" });
    assert.equal(s.channel.receivers(), 0, "a shut down session answers no queries");
  } finally { await fx.restore(); }
});
