import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { stripVTControlCharacters } from "node:util";
import { makeFixture, selfPane, startSession, notices, pollUntil, text, gatedCommand, movedId, logHas } from "./ko-pi-fixture.ts";

const listed = async (s: Awaited<ReturnType<typeof startSession>>) => JSON.parse(text(await s.tools.get("list_async_bash").execute("l", {})));
const capture = (updates: string[]) => (result: any) => updates.push(result.content.map((part: any) => part.text ?? "").join(""));

test("bash without a timeout moves at the limit, keeps running, and announces the exit", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "50";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const result = await s.tools.get("bash").execute("b", { command: `printf 'before\\n'; ${gatedCommand(gate, "", "after\n", 3)}` });
    const id = movedId(result);
    assert.match(text(result), /still running after 0\.05 s/);
    assert.match(text(result), /output so far:/);
    const rows = await listed(s);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].job, id);
    assert.equal(rows[0].name, id);
    assert.equal(rows[0].state, "running");
    await pollUntil(() => logHas(rows[0].log, "before\n"));
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    assert.match(notices(s)[0]!, /exit 3/);
    assert.match(notices(s)[0]!, /before\nafter/);
  } finally { await fx.restore(); }
});

test("a short timeout stops bash without moving it, while a longer timeout becomes the job deadline", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "50";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    await assert.rejects(s.tools.get("bash").execute("short", { command: gatedCommand(join(fx.dir, "short")), timeout: 0.02 }), /Command timed out after 0\.02 seconds/);
    assert.deepEqual(await listed(s), []);
    assert.deepEqual(notices(s), []);
    const result = await s.tools.get("bash").execute("long", { command: gatedCommand(join(fx.dir, "long")), timeout: 0.5 });
    const id = movedId(result);
    await pollUntil(() => notices(s).length === 1);
    assert.match(notices(s)[0]!, /timed out after 0\.5 s/);
    assert.equal((await listed(s)).find((row: any) => row.job === id).end, "timed out after 0.5 s");
    const equal = await s.tools.get("bash").execute("equal", { command: gatedCommand(join(fx.dir, "equal")), timeout: 0.05 });
    movedId(equal);
    await pollUntil(() => notices(s).length === 2);
    assert.match(notices(s)[1]!, /timed out after 0\.05 s/);
  } finally { await fx.restore(); }
});

test("ctrl+b moves all running calls, removes the hint and disconnects the turn abort", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "10000";
    process.env.KO_JOB_HINT_MS = "5";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    assert.equal(s.terminalListeners.size, 1);
    assert.deepEqual(s.terminalInput("\x02"), [undefined]);
    const controller = new AbortController();
    const updates: string[] = [];
    const gates = [join(fx.dir, "a"), join(fx.dir, "b")];
    const work = gates.map((gate, i) => s.tools.get("bash").execute(`b${i}`, { command: `printf 'ready-${i}\\n'; ${gatedCommand(gate)}` }, controller.signal, capture(updates)));
    await pollUntil(() => updates.some((u) => u?.includes("ready-0")) && updates.some((u) => u?.includes("ready-1")));
    await pollUntil(() => s.widgets.get("ko-job-hint")?.content !== undefined);
    const hint = s.widgets.get("ko-job-hint")?.content;
    assert.ok(Array.isArray(hint));
    assert.match(stripVTControlCharacters(hint.join("")), /ctrl\+b.*moves this command to a job/);
    assert.deepEqual(await listed(s), [], "foreground commands have no job rows");
    assert.deepEqual(notices(s), [], "foreground commands have no notices");
    assert.deepEqual(s.terminalInput("x"), [undefined]);
    assert.deepEqual(s.terminalInput("\x02"), [{ consume: true }]);
    const results = await Promise.all(work);
    for (const [i, result] of results.entries()) {
      const id = movedId(result);
      const row = (await listed(s)).find((row: any) => row.job === id);
      assert.match(text(result), new RegExp(`ready-${i}`));
      assert.match(text(result), /still running; it continues as job/);
      assert.equal(row.name, id);
    }
    assert.equal(s.widgets.get("ko-job-hint")?.content, undefined);
    assert.deepEqual(s.terminalInput("\x02"), [undefined]);
    controller.abort();
    assert.equal((await listed(s)).filter((row: any) => row.state === "running").length, 2);
    for (const gate of gates) writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 2);
    assert.ok(notices(s).every((notice) => notice.includes("exit 0")));
    await s.emit("session_shutdown", { reason: "new" });
    assert.equal(s.terminalListeners.size, 0);
  } finally { await fx.restore(); }
});

test("foreground bash keeps pi's settings, cwd, environment and exit result and leaves no registry row", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const used = join(fx.dir, "shell-used");
    const shell = join(fx.binDir, "custom-shell");
    writeFileSync(shell, `#!/bin/sh\nprintf used > '${used}'\nexec /bin/sh "$@"\n`, { mode: 0o700 });
    s.pi.settings.shellPath = shell;
    s.pi.settings.shellCommandPrefix = "export KO_PREFIX=prefix";
    const result = await s.tools.get("bash").execute("b", { command: "printf '%s|%s|%s' \"$KO_PREFIX\" \"$PI_SESSION_ID\" \"$PWD\"; exit 7" }, undefined, undefined, { cwd: fx.dir, sessionManager: { getSessionId: () => "call-session", getSessionFile: () => undefined } });
    assert.equal(result.isError, true);
    assert.equal(result.structuredContent.exit_code, 7);
    assert.ok(text(result).startsWith(`prefix|call-session|${realpathSync(fx.dir)}`));
    assert.equal(readFileSync(used, "utf8"), "used");
    assert.deepEqual(await listed(s), []);
    assert.deepEqual(notices(s), []);
    assert.equal(s.widgets.get("ko-job-hint")?.content, undefined);
  } finally { await fx.restore(); }
});

test("another extension's bash is not replaced and async_bash still works", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { bashSource: "/extensions/other.ts" });
    assert.equal(s.tools.has("bash"), false);
    assert.equal(s.pi.getAllTools().find((tool) => tool.name === "bash")?.sourceInfo.path, "/extensions/other.ts");
    assert.equal(s.terminalListeners.size, 0);
    await s.tools.get("async_bash").execute("a", { command: "printf async", name: "still-available" });
    await pollUntil(() => notices(s).length === 1);
    assert.match(notices(s)[0]!, /async/);
  } finally { await fx.restore(); }
});

test("a reload moves a running bash call and preserves its output without an old-instance notice", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "10000";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const updates: string[] = [];
    const work = s.tools.get("bash").execute("b", { command: `printf 'before\\n'; ${gatedCommand(gate, "", "after\n")}` }, undefined, capture(updates));
    await pollUntil(() => updates.some((u) => u?.includes("before")));
    await s.emit("session_shutdown", { reason: "reload" });
    const id = movedId(await work);
    const row = (await listed(s)).find((row: any) => row.job === id);
    assert.equal(s.terminalListeners.size, 0);
    writeFileSync(gate, "");
    await pollUntil(async () => (await listed(s)).find((row: any) => row.job === id).state === "ended");
    assert.equal(readFileSync(row.log, "utf8"), "before\nafter\n");
    assert.deepEqual(notices(s), []);
  } finally { await fx.restore(); }
});

test("a moved log starts with only the held 64 KiB and marks the earlier cut", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "10000";
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    const gate = join(fx.dir, "gate");
    const before = "x".repeat(70000) + "\nTAIL\n";
    const updates: string[] = [];
    const work = s.tools.get("bash").execute("b", { command: gatedCommand(gate, before, "done\n") }, undefined, capture(updates));
    await pollUntil(() => updates.some((u) => u?.includes("TAIL")));
    assert.deepEqual(s.terminalInput("\x02"), [{ consume: true }]);
    const result = await work;
    const row = (await listed(s)).find((row: any) => row.job === movedId(result));
    const marker = "--- earlier output is cut; this log starts with the last 64 KiB before the move ---\n";
    await pollUntil(() => existsSync(row.log) && readFileSync(row.log).length >= marker.length + 65536);
    assert.equal(readFileSync(row.log, "utf8"), marker + before.slice(-65536));
    assert.match(text(result), /TAIL/);
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    assert.ok(readFileSync(row.log, "utf8").endsWith("TAIL\ndone\n"));
  } finally { await fx.restore(); }
});

test("invalid timeouts do not spawn a foreground command", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startSession(fx);
    for (const timeout of [0, -1, NaN, Infinity]) await assert.rejects(s.tools.get("bash").execute("b", { command: "true", timeout }), /Invalid timeout/);
    assert.deepEqual(notices(s), []);
  } finally { await fx.restore(); }
});
