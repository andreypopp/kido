import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, gatedCommand } from "./koa-agent-fixture.ts";
import { RESTART_STATE_CHANNEL, type RestartState } from "./records.ts";

test("the restart state counts running jobs, services included, and unreported subagents, and stops answering at shutdown", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self" });
    const ask = () => { let state: RestartState | undefined; s.pi.events.emit(RESTART_STATE_CHANNEL, { reply: (value: RestartState) => { state = value; } }); return state; };
    assert.deepEqual(ask(), { type: "ready" });
    const gate = join(fx.dir, "gate");
    await s.tools.get("async_bash").execute("a", { command: gatedCommand(gate, "x\n", "y\n", 0), name: "build" });
    await s.tools.get("async_bash").execute("b", { command: gatedCommand(join(fx.dir, "service-gate"), "x\n", "y\n", 0), name: "server", service: true });
    assert.deepEqual(ask(), { type: "blocked", jobs: 2, children: 0 });
    await s.tools.get("spawn_agent").execute("c", { name: "worker", task: "build it", model: undefined });
    assert.deepEqual(ask(), { type: "blocked", jobs: 2, children: 1 });
    await s.emit("session_shutdown", { reason: "reload" });
    assert.equal(ask(), undefined);
  } finally { await fx.restore(); }
});
