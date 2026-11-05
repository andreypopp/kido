import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, statSync, existsSync, realpathSync, symlinkSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { makeFixture, selfPane, startSession, customMessages, notices, pollUntil, text, gatedCommand, jobRegistry as registry, logHas, processGone, withEnv } from "./ko-pi-fixture.ts";
import { splitLines, newSplit, streamBatch } from "./ko-pi.ts";

const list = async (s: Awaited<ReturnType<typeof startSession>>) => JSON.parse(text(await s.tools.get("list_async_bash").execute("l", {})));

test("a local job uses the call cwd and environment, logs both streams, and announces its exact exit", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const shellUsed = join(fx.dir, "shell-used");
    const shell = join(fx.binDir, "job-shell");
    writeFileSync(shell, `#!/bin/sh\nprintf configured > '${shellUsed}'\nexec /bin/sh "$@"\n`, { mode: 0o700 });
    s.pi.settings.shellPath = shell;
    const command = `printf '%s\\n' "$PWD" "$KO_PANE"; ${gatedCommand(gate, "stdout\n", "stderr\n", 3)}`;
    const abort = new AbortController();
    const result = await s.tools.get("async_bash").execute("c", { command, name: "build" }, abort.signal, undefined, { cwd: fx.dir });
    const { job, log } = result.details;
    assert.match(job, /^j[a-z0-9]{7}$/);
    await pollUntil(() => logHas(log, "stdout\n"));
    assert.equal(readFileSync(log, "utf8"), `${realpathSync(fx.dir)}\npane_1\nstdout\n`);
    assert.equal(statSync(log).mode & 0o777, 0o600);
    assert.equal(readFileSync(shellUsed, "utf8"), "configured");
    abort.abort();
    assert.equal((await list(s))[0].state, "running");
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    assert.match(notices(s)[0]!, new RegExp(`job "build" \\(${job}\\) exit 3`));
    assert.ok(notices(s)[0]!.includes("stdout\nstderr"));
    assert.ok(notices(s)[0]!.endsWith(`log: ${log}`));
    assert.equal(readFileSync(log, "utf8"), `${realpathSync(fx.dir)}\npane_1\nstdout\nstderr\n`);
    const [{ startedAt, ...row }] = await list(s);
    assert.ok(Number.isFinite(Date.parse(startedAt)));
    assert.deepEqual(row, { job, name: "build", command, state: "ended", end: "exit 3", log });
  } finally { await fx.restore(); }
});

test("async_bash prepends pi's managed bin directory to its default environment", async () => {
  const fx = makeFixture();
  try {
    await withEnv({ PI_CODING_AGENT_DIR: join(fx.dir, "agent") }, async () => {
      const bin = join(fx.dir, "agent", "bin");
      mkdirSync(bin, { recursive: true });
      writeFileSync(join(bin, "ko-job-env-probe"), "#!/bin/sh\nprintf agent-bin\n", { mode: 0o700 });
      fx.setPanes([selfPane()]);
      const s = await startSession(fx);
      await s.tools.get("async_bash").execute("a", { command: "exec ko-job-env-probe", name: "env" });
      await pollUntil(() => notices(s).length === 1);
      assert.match(notices(s)[0]!, /exit 0/);
      assert.match(notices(s)[0]!, /agent-bin/);
    });
  } finally { await fx.restore(); }
});

test("running jobs and children reserve names, endings release them, and stop prefers the running match", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const tool = s.tools.get("async_bash");
    const command = gatedCommand(join(fx.dir, "gate"));
    const twins = await Promise.all([tool.execute("a", { command, name: "twin" }), tool.execute("b", { command, name: "TWIN" })]);
    assert.equal(twins.filter((r) => text(r).startsWith("started job")).length, 1);
    assert.match(text(twins.find((r) => !text(r).startsWith("started job"))), /already taken/);
    s.entries.push({ type: "custom", customType: "ko-pi.child", data: { owner: "self-session", name: "kid", session: "kid-session", model: "m", fork: false, cwd: "/tmp", pane: { instance: "a".repeat(32), pane: "pane_5" } } });
    assert.match(text(await tool.execute("c", { command, name: "KID" })), /already taken/);
    assert.match(text(await tool.execute("c", { command, name: "" })), /name is required/);
    writeFileSync(join(fx.dir, "gate"), "");
    await pollUntil(() => notices(s).length === 1);
    const again = await tool.execute("again", { command: gatedCommand(join(fx.dir, "again")), name: "TWIN" });
    assert.match(text(again), /started job/);
    assert.equal((await list(s)).filter((row: any) => row.name.toLowerCase() === "twin").length, 2);
    const stop = s.tools.get("stop_async_bash");
    assert.match(text(await stop.execute("s", { job: "twin" })), new RegExp(`stopped job ${again.details.job}`));
    await pollUntil(async () => (await list(s)).find((row: any) => row.job === again.details.job).state === "ended");
    assert.match(text(await stop.execute("s", { job: "twin" })), new RegExp(`job ${again.details.job} .*had already ended: stopped`));
  } finally { await fx.restore(); }
});

test("stream batches strip escapes, spend a budget and flush the partial line before the notice", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_STREAM_BUDGET_BYTES = "1";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await s.emit("agent_start");
    const gate = join(fx.dir, "gate");
    const result = await s.tools.get("async_bash").execute("c", { command: gatedCommand(gate, "\x1b[32mgreen\x1b[0m\n", "partial"), name: "stream", stream: true });
    await pollUntil(() => logHas(result.details.log, "green"));
    await s.emit("turn_end", { toolResults: [{}] });
    assert.ok(customMessages(s, "ko-stream")[0]!.message.content.endsWith("\ngreen"));
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    const messages = s.messages.map((m) => m.message.content);
    assert.match(messages.at(-2), /output budget spent; the log has the rest/);
    assert.match(messages.at(-1), /partial/);
    assert.ok(readFileSync(result.details.log, "utf8").includes("\x1b[32m"));
  } finally { await fx.restore(); }
});

test("idle stream batches arrive and a final partial line precedes the ending notice", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    process.env.KO_STREAM_FLUSH_MS = "5";
    const gate = join(fx.dir, "gate");
    await s.tools.get("async_bash").execute("c", { command: gatedCommand(gate, "first\n", "final"), name: "partial", stream: true });
    await pollUntil(() => customMessages(s, "ko-stream").length === 1);
    assert.match(customMessages(s, "ko-stream")[0]!.message.content, /\nfirst$/);
    assert.deepEqual(customMessages(s, "ko-stream")[0]!.opts, { deliverAs: "steer", triggerTurn: true });
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    assert.match(s.messages.at(-2)!.message.content, /\nfinal$/);
    assert.equal(s.messages.at(-1)!.message.customType, "ko-notice");
  } finally { await fx.restore(); }
});

test("stop by name and id stops owned groups, sends no notice, and handles ended and unknown jobs", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    for (const address of ["name", "id"]) {
      const marker = `ko-pi-job-${fx.dir.split("/").at(-1)}-${address}`;
      const ready = join(fx.dir, `ready-${address}`);
      const sleeper = join(fx.dir, marker);
      symlinkSync("/bin/sleep", sleeper);
      const command = `'${sleeper}' 30 & echo ready > '${ready}'; wait`;
      const result = await s.tools.get("async_bash").execute("c", { command, name: address });
      await pollUntil(() => existsSync(ready));
      await s.tools.get("stop_async_bash").execute("s", { job: address === "name" ? "NAME" : result.details.job });
      assert.equal((await list(s)).find((row: any) => row.job === result.details.job).end, "stopped");
      await pollUntil(() => processGone(marker));    }
    assert.deepEqual(notices(s), []);
    assert.match(text(await s.tools.get("stop_async_bash").execute("s", { job: "name" })), /had already ended: stopped/);
    assert.equal((await s.tools.get("stop_async_bash").execute("s", { job: "missing" })).isError, true);
  } finally { await fx.restore(); }
});

test("stop_async_bash refuses to signal an exited leader", async (t) => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const result = await s.tools.get("async_bash").execute("c", { command: "true", name: "ended" });
    await pollUntil(() => notices(s).length === 1);
    const job = registry().jobs.get(result.details.job);
    const ended = job.state;
    const kill = t.mock.method(process, "kill", () => true);
    try {
      job.state = { type: "running" };
      assert.equal(job.where.child.exitCode, 0);
      const stopped = await s.tools.get("stop_async_bash").execute("s", { job: result.details.job });
      assert.match(text(stopped), /stopped job/);
      assert.equal(kill.mock.callCount(), 0);
    } finally {
      if (job.stopping) clearTimeout(job.stopping.timer);
      job.stopping = null;
      job.state = ended;
      kill.mock.restore();
    }
  } finally { await fx.restore(); }
});

test("list keeps only the newest 20 ended jobs", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    for (let i = 0; i < 22; i++) {
      await s.tools.get("async_bash").execute("c", { command: "true", name: `job-${i}` });
      await pollUntil(() => notices(s).length === i + 1);
    }
    const rows = await list(s);
    assert.equal(rows.length, 20);
    assert.equal(rows[0].name, "job-21");
    assert.equal(rows.at(-1).name, "job-2");
  } finally { await fx.restore(); }
});

for (const reason of ["quit", "new", "resume", "fork", "reload"]) {
  test(`${reason} ${reason === "reload" ? "keeps" : "stops"} jobs`, async () => {
    const fx = makeFixture();
    try {
      fx.setPanes([selfPane()]);
      const s = await startSession(fx);
      const gate = join(fx.dir, "gate");
      const result = await s.tools.get("async_bash").execute("c", { command: gatedCommand(gate), name: "live" });
      const owner = registry();
      await pollUntil(async () => !(await processGone(gate)));
      await s.emit("session_shutdown", { reason });
      if (reason === "reload") {
        assert.equal(registry(), owner);
        assert.equal((await list(s)).find((row: any) => row.job === result.details.job).state, "running");
        assert.equal(owner.owner, null);
      } else {
        assert.equal(registry(), undefined);
        assert.deepEqual(await list(s), []);
        await pollUntil(() => processGone(gate));
      }
      assert.deepEqual(notices(s), []);
    } finally { await fx.restore(); }
  });
}

test("splitLines drops escape sequences and keeps the last state of a progress line", () => {
  const state = newSplit();
  const lines = [
    ...splitLines(state, "\x1b[32mgreen\x1b[0m text\r\n"),
    ...splitLines(state, "10%\r50%\r100%\n"),
    ...splitLines(state, "\x1b]0;a title\x07\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\\n"),
    ...splitLines(state, "\x1bP1$rdcs\x1b\\after dcs\n\x1b_Gi=1;OK\x1b\\apc gone\n\x1b(Bcharset\n"),
    ...splitLines(state, "split \x1b[3"),
    ...splitLines(state, "1mred\x1b[0m\ttab\n"),
    ...splitLines(state, "a\r"),
    ...splitLines(state, "\nb\n"),
  ];
  assert.deepEqual(lines, ["green text", "100%", "link", "after dcs", "apc gone", "charset", "split red\ttab", "a", "b"]);
  assert.equal(state.line, "");
});

test("streamBatch bounds batches and names the output log", () => {
  const batch = streamBatch(Array.from({ length: 300 }, (_, i) => `line ${i}`), 5).split("\n");
  assert.equal(batch[0], "... 105 lines omitted (the log has them)");
  assert.equal(batch.at(-1), "line 299");
});

test("held streams bound long complete and partial lines while the log stays complete", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await s.emit("agent_start");
    const gate = join(fx.dir, "gate");
    const size = 1024 * 1024;
    const fill = `head -c ${size} /dev/zero | tr '\\000' x`;
    const command = `${fill}; printf '\\n'; ${fill}; ${gatedCommand(gate)}`;
    const result = await s.tools.get("async_bash").execute("c", { command, name: "large", stream: true });
    const { job, log } = result.details;
    await pollUntil(() => existsSync(log) && statSync(log).size === size * 2 + 1);
    const held = registry().jobs.get(job);
    const stream = held.mode.stream;
    const bytes = stream.lines.reduce((total: number, line: string) => total + Buffer.byteLength(line) + 1, 0) + Buffer.byteLength(stream.split.line) + stream.carry.length;
    assert.ok(bytes <= 65536, `held ${bytes} stream bytes`);
    assert.equal(stream.held, bytes);
    assert.ok(held.tail.length <= 65536);
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    assert.match(customMessages(s, "ko-stream")[0]!.message.content, /truncated.*log has/);
    assert.equal(readFileSync(log, "utf8"), "x".repeat(size) + "\n" + "x".repeat(size));
  } finally { await fx.restore(); }
});
