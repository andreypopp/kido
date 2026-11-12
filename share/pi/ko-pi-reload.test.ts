import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, freshExtension, notices, customMessages, pollUntil, gatedCommand, text, jobRegistry as registry, logHas, movedId } from "./ko-pi-fixture.ts";


test("a live job is adopted by the second instance, which alone announces its end", async () => {
  const fx = makeFixture();
  const exits = process.listenerCount("exit");
  try {
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const result = await first.tools.get("async_bash").execute("a", { command: gatedCommand(gate, "before\n", "after\n", 3), name: "build" });
    const owner = registry();
    const job = owner.jobs.get(result.details.job.id);
    await pollUntil(() => logHas(result.details.job.log, "before"));
    await first.emit("session_shutdown", { reason: "reload" });
    assert.equal(owner.owner, null);
    const second = await startSession(fx, { factory: await freshExtension() });
    assert.equal(registry(), owner);
    assert.equal(process.listeners("exit").filter((listener) => listener === owner.exit).length, 1);
    assert.equal(process.listenerCount("exit"), exits + 2);
    assert.equal(typeof owner.owner.onEnd, "function");
    writeFileSync(gate, "");
    await pollUntil(() => notices(second).length === 1);
    assert.deepEqual(notices(first), []);
    assert.match(notices(second)[0]!, /job "build" .* exit 3/);
    assert.match(notices(second)[0]!, /before\nafter/);
    assert.equal(job.tail.length, 0);
    await second.emit("session_shutdown", { reason: "reload" });
    const third = await startSession(fx, { factory: await freshExtension() });
    assert.deepEqual(notices(third), [], "an announced end is not repeated");
    assert.equal(process.listenerCount("exit"), exits + 2);
  } finally { await fx.restore(); }
  assert.equal(process.listenerCount("exit"), exits);
});

test("a job that ends between instances is announced at adopt, before the startup task", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const result = await first.tools.get("async_bash").execute("a", { command: gatedCommand(gate, "", "gap-output\n"), name: "gap" });
    const job = registry().jobs.get(result.details.job.id);
    await first.emit("session_shutdown", { reason: "reload" });
    writeFileSync(gate, "");
    await pollUntil(() => job.state.type === "ended");
    assert.equal(job.state.announced, false);
    assert.deepEqual(notices(first), []);
    fx.setPanes([selfPane({ vars: { "pi.session": "old-holder", "ko-pi.task": { text: "startup-task", from: { session: "peer-session", name: "peer" } } } })]);
    const factory = await freshExtension();
    const order: string[] = [];
    const second = await startSession(fx, {
      factory(pi) {
        factory(pi);
        const host: any = pi;
        const sendMessage = host.sendMessage;
        host.sendMessage = (...args: any[]) => {
          if (args[0].customType === "ko-notice") assert.equal(fx.row("pane_1")?.vars?.["pi.session"], "self-session");
          order.push(args[0].customType);
          sendMessage(...args);
        };
      },
    });
    assert.equal(notices(second).length, 1);
    assert.match(notices(second)[0]!, /gap-output/);
    assert.deepEqual(order, ["ko-notice", "ko-message"]);
    assert.equal(fx.row("pane_1")?.vars?.["pi.session"], "self-session");
  } finally { await fx.restore(); }
});

for (const changed of ["shape", "session"]) {
  test(`another registry ${changed} is stopped through its old closures and replaced`, async () => {
    const fx = makeFixture();
    const exits = process.listenerCount("exit");
    try {
      fx.setPanes([selfPane()]);
      const first = await startSession(fx);
      const result = await first.tools.get("async_bash").execute("a", { command: gatedCommand(join(fx.dir, "gate")), name: "old-build" });
      const old = registry();
      const job = old.jobs.get(result.details.job.id);
      await first.emit("session_shutdown", { reason: "reload" });
      old[changed] = changed === "shape" ? old.shape + 1 : "another-session";
      let stops = 0;
      const stopAll = old.stopAll;
      old.stopAll = () => { stops++; return stopAll(); };
      const second = await startSession(fx, { factory: await freshExtension() });
      const owner = registry();
      assert.notEqual(owner, old);
      assert.equal(stops, 1);
      assert.equal(owner.shape, 3);
      assert.equal(owner.session, "self-session");
      assert.equal(owner.jobs.size, 0);
      await pollUntil(() => job.state.type === "ended" && !process.listeners("exit").includes(old.exit));
      assert.equal(process.listeners("exit").filter((listener) => listener === owner.exit).length, 1);
      assert.equal(notices(second).length, 1);
      assert.ok(notices(second)[0]!.endsWith("1 async_bash jobs of the previous ko-pi version were stopped at /reload: old-build"));
      await pollUntil(() => job.state.type === "ended");
      assert.equal(job.state.end.type, "stopped");
      assert.deepEqual(notices(first), []);
    } finally { await fx.restore(); }
    assert.equal(process.listenerCount("exit"), exits);
  });
}

test("a replaced registry keeps its exit handler until a stopped job closes", async () => {
  const fx = makeFixture();
  const gate = join(fx.dir, "gate");
  try {
    process.env.KO_JOB_KILL_MS = "1000";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const ready = join(fx.dir, "ready");
    const command = `trap '' TERM; printf ready > '${ready}'; ${gatedCommand(gate)}`;
    const result = await first.tools.get("async_bash").execute("a", { command, name: "slow-stop" });
    const old = registry();
    const job = old.jobs.get(result.details.job.id);
    await pollUntil(() => existsSync(ready));
    await first.emit("session_shutdown", { reason: "reload" });
    old.shape++;
    await startSession(fx, { factory: await freshExtension() });
    assert.equal(job.state.type, "running");
    assert.ok(process.listeners("exit").includes(old.exit));
    old.exit();
    await pollUntil(() => job.state.type === "ended" && !process.listeners("exit").includes(old.exit));
    assert.equal(job.where.child.signalCode, "SIGKILL");
  } finally { writeFileSync(gate, ""); await fx.restore(); }
});

test("a shutdown wait timeout keeps exit coverage until the retained pipes close", async () => {
  const fx = makeFixture();
  const gate = join(fx.dir, "gate");
  let oldExit: (() => void) | undefined;
  try {
    process.env.KO_JOB_KILL_MS = "20";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const result = await first.tools.get("async_bash").execute("a", { command: `${gatedCommand(gate)} & exit 0`, name: "pipes" });
    const old = registry();
    oldExit = old.exit;
    const job = old.jobs.get(result.details.job.id);
    await pollUntil(() => job.where.child.exitCode === 0);
    await first.emit("session_shutdown", { reason: "new" });
    assert.equal(registry(), undefined);
    assert.equal(job.state.type, "running");
    assert.ok(process.listeners("exit").includes(old.exit));
    writeFileSync(gate, "");
    await pollUntil(() => job.state.type === "ended" && !process.listeners("exit").includes(old.exit));
  } finally {
    writeFileSync(gate, "");
    await fx.restore();
    await pollUntil(() => !oldExit || !process.listeners("exit").includes(oldExit));
  }
});

test("held stream lines and a UTF-8 carry cross the reload and flush once from the new instance", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_STREAM_INTERVAL_MS = "10000";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    await first.emit("agent_start");
    const gate = join(fx.dir, "gate");
    const wait = gatedCommand(gate).replace(/^exec /, "");
    const result = await first.tools.get("async_bash").execute("a", { command: `printf 'held-before\\n\\303'; ${wait}; printf '\\251\\nafter\\npartial'`, name: "stream", stream: true });
    const job = registry().jobs.get(result.details.job.id);
    await pollUntil(() => job.mode.stream.lines.includes("held-before") && job.mode.stream.carry.length === 1);
    assert.deepEqual(customMessages(first, "ko-stream"), []);
    await first.emit("session_shutdown", { reason: "reload" });
    assert.equal(job.mode.stream.timer, null);
    process.env.KO_STREAM_INTERVAL_MS = "5";
    const second = await startSession(fx, { factory: await freshExtension() });
    await pollUntil(() => customMessages(second, "ko-stream").length === 1);
    assert.ok(customMessages(second, "ko-stream")[0]!.message.content.endsWith("\nheld-before"));
    writeFileSync(gate, "");
    await pollUntil(() => notices(second).length === 1);
    const streams = customMessages(second, "ko-stream").map((message) => String(message.message.content));
    assert.equal(streams.flatMap((stream) => stream.split("\n").slice(1)).join("\n"), "held-before\né\nafter\npartial");
    assert.equal(streams.join("\n").split("held-before").length - 1, 1);
    assert.deepEqual(first.messages, []);
    assert.equal(second.messages.at(-1)!.message.customType, "ko-notice");
    assert.equal(readFileSync(result.details.job.log, "utf8"), "held-before\né\nafter\npartial");
  } finally { await fx.restore(); }
});

test("a moved call keeps its deadline across reload without an old-instance notice", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "50";
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const moved = await first.tools.get("bash").execute("b", { command: gatedCommand(join(fx.dir, "gate")), timeout: 0.5 });
    movedId(moved);
    await first.emit("session_shutdown", { reason: "reload" });
    const second = await startSession(fx, { factory: await freshExtension() });
    await pollUntil(() => notices(second).length === 1);
    assert.match(notices(second)[0]!, /timed out after 0\.5 s/);
    assert.deepEqual(notices(first), []);
  } finally { await fx.restore(); }
});

test("all unannounced endings survive a reload gap before announced history is capped", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const gate = join(fx.dir, "gate");
    for (let i = 0; i < 22; i++) await first.tools.get("async_bash").execute("a", { command: gatedCommand(gate), name: `gap-${i}` });
    await first.emit("session_shutdown", { reason: "reload" });
    writeFileSync(gate, "");
    const rows = async () => JSON.parse(text(await first.tools.get("list_async_bash").execute("l", {})));
    await pollUntil(async () => (await rows()).every((row: any) => row.state === "ended"));
    assert.equal((await rows()).length, 22);
    assert.deepEqual(notices(first), []);
    const second = await startSession(fx, { factory: await freshExtension() });
    assert.equal(notices(second).length, 22);
    for (let i = 0; i < 22; i++) assert.equal(notices(second).filter((notice) => notice.includes(`job "gap-${i}"`)).length, 1);
    assert.equal(JSON.parse(text(await second.tools.get("list_async_bash").execute("l", {}))).length, 20);
    await second.emit("session_shutdown", { reason: "reload" });
    const third = await startSession(fx, { factory: await freshExtension() });
    assert.deepEqual(notices(third), []);
  } finally { await fx.restore(); }
});

test("stream and ending-notice failures retry independently at adoption", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const first = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const result = await first.tools.get("async_bash").execute("a", { command: gatedCommand(gate, "held-line\n"), name: "retry", stream: true });
    const job = registry().jobs.get(result.details.job.id);
    await first.emit("session_shutdown", { reason: "reload" });
    writeFileSync(gate, "");
    await pollUntil(() => job.state.type === "ended");
    const factory = await freshExtension();
    let attempts = 0;
    const second = await startSession(fx, { factory(pi) { factory(pi); const host: any = pi; host.sendMessage = () => { attempts++; throw new Error("cannot send in this instance"); }; } });
    assert.equal(attempts, 1);
    assert.equal(job.state.announced, false);
    await second.emit("session_shutdown", { reason: "reload" });
    const thirdFactory = await freshExtension();
    const third = await startSession(fx, { factory(pi) {
      thirdFactory(pi);
      const host: any = pi;
      const send = host.sendMessage;
      host.sendMessage = (...args: any[]) => {
        if (args[0].customType === "ko-notice") throw new Error("cannot send the ending notice");
        send(...args);
      };
    } });
    assert.match(customMessages(third, "ko-stream")[0]!.message.content, /\nheld-line$/);
    assert.deepEqual(notices(third), []);
    await third.emit("session_shutdown", { reason: "reload" });
    const fourth = await startSession(fx, { factory: await freshExtension() });
    assert.equal(notices(fourth).length, 1);
    assert.deepEqual(customMessages(fourth, "ko-stream"), []);
    assert.equal(readFileSync(result.details.job.log, "utf8"), "held-line\n");
    assert.deepEqual(notices(first), []);
    assert.deepEqual(notices(second), []);
  } finally { await fx.restore(); }
});
