import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, gatedCommand, get, createChannel, stubAgent } from "./koa-agent-fixture.ts";

test("the restart state counts running jobs, services included, and stops receiving queries at shutdown", async () => {
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
    await s.emit("session_shutdown", { reason: "reload" });
    assert.equal(s.channel.receivers(), 0, "a shut down session answers no queries");
  } finally { await fx.restore(); }
});

test("the restart state counts live children that owe a report, and not ended ones or reported ones", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const channel = createChannel();
    Object.assign(channel.host, { find: (id: string) => id === "live-session" || id === "done-session" ? stubAgent({ id }) : undefined });
    const s = await startSession(fx, { name: "Self", channel });
    const child = (name: string, session: string) => s.entries.push({ type: "custom", customType: "koa.agent", data: { role: "subagent", owner: "self-session", name, session, model: "m", fork: false, cwd: "/tmp" } });
    const work = (session: string) => s.entries.push({ type: "custom", customType: "koa.work", data: { owner: "self-session", child: session, at: 1 } });
    child("live", "live-session"); work("live-session");
    child("done", "done-session"); work("done-session");
    s.entries.push({ type: "custom", customType: "koa.report", data: { owner: "self-session", child: "done-session", text: "ok", at: 2 } });
    child("gone", "gone-session"); work("gone-session");
    assert.deepEqual(await s.channel.ask({ type: "restart_state" }), { type: "restart_state", state: { type: "blocked", jobs: 0, children: 1 } });
  } finally { await fx.restore(); }
});
