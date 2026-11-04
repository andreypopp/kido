import { test } from "node:test";

import assert from "node:assert/strict";

import { join } from "node:path";

import { writeFileSync } from "node:fs";

import { makeFixture, selfPane, startSession, customMessages, notices, pollUntil, freshExtension, text, type Fixture } from "./ko-pi-fixture.ts";

import { splitLines, newSplit, streamBatch } from "./ko-pi.ts";

const bytes = (offset: number, data: string) => ({ type: "bytes", offset, data: Buffer.from(data).toString("base64") });

function fakeRun(fx: Fixture, id = "run-1"): void {
  process.env.KO_FAKE_RUN_ID = id;
  process.env.KO_FAKE_RUN_PANE = "pane_9";
  fx.setPanes([selfPane()]);
}

test("async_bash runs the command in a child pane of its own with no wrapper and ends with a notice that carries the screen", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    const gate = join(fx.dir, "gate");
    process.env.KO_FAKE_RUN_WAIT_GATE = gate;
    process.env.KO_FAKE_RUN_WAIT_OUTCOME = JSON.stringify({ result: "failed", text: "exit 3" });
    const s = await startSession(fx);
    const result = await s.tools.get("async_bash").execute("c", { command: "make -j8 && ./run", name: "build" });
    assert.deepEqual(fx.runCalls(), [["run-child", "pane_1", "--name", "build", "--", "bash", "-o", "pipefail", "-c", "make -j8 && ./run"]]);
    assert.equal(
      text(result).split("; ").slice(0, 2).join("; "),
      "started run run-1 (build) in window window_9, pane pane_9; list_async_bash lists it and stop_async_bash stops it",
    );
    assert.match(text(result), /read it with ko api '\/panes\/pane_9\/screen\?history=all'/);
    assert.deepEqual(notices(s), []);

    fx.setScreen("pane_9", "compiling\nerror: boom\n");
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1, 2000, "the ending notice");
    assert.equal(
      notices(s)[0],
      'notice from build (a subagent or background run\'s report, not the user):\nasync run "build" failed: exit 3\npane: pane_9\n--- last 4000 bytes of its screen ---\ncompiling\nerror: boom\n',
    );
    assert.deepEqual(fx.runWaitCalls(), [["run-wait", "run-1", "--json"]]);
  } finally {
    await fx.restore();
  }
});

test("the ending falls back to the run's captured screen once the pane is gone, and says when there is none", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    const s = await startSession(fx);
    const start = (name: string, id: string) => {
      process.env.KO_FAKE_RUN_ID = id;
      return s.tools.get("async_bash").execute("c", { command: "x", name });
    };
    fx.setScreen("run-run-a", "captured");
    await start("a", "run-a");
    await pollUntil(() => notices(s).length === 1, 2000, "the first ending");
    assert.ok(notices(s)[0]!.endsWith("--- last 4000 bytes of its screen ---\ncaptured"));
    await start("b", "run-b");
    await pollUntil(() => notices(s).length === 2, 2000, "the second ending");
    assert.ok(notices(s)[1]!.endsWith("--- its screen is gone ---"));
    assert.ok(notices(s)[1]!.startsWith('notice from b (a subagent or background run\'s report, not the user):\nasync run "b" completed\npane: pane_9\n'));
  } finally {
    await fx.restore();
  }
});

test("a name that one of the session's runs or children holds is refused, and so is a second start at once", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    fx.setRuns([{ id: "old", name: "taken", parent: "pane_1", pane: "pane_8", startedAt: "t", outcome: { result: "completed", text: "" } }]);
    const s = await startSession(fx);
    const tool = s.tools.get("async_bash");
    const taken = `could not start background command: the name "taken" is already taken by one of this session's runs; choose another name`;
    assert.equal(text(await tool.execute("c", { command: "x", name: "taken" })), taken);
    const twin = await Promise.all([tool.execute("c", { command: "x", name: "twin" }), tool.execute("c", { command: "x", name: "twin" })]);
    assert.equal(twin.filter((r) => text(r).startsWith("started run")).length, 1);
    assert.equal(text(await tool.execute("c", { command: "x", name: "" })), "could not start background command: --name is required");
  } finally {
    await fx.restore();
  }
});

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

test("streamBatch keeps the end of a long batch and says what the pane's screen has", () => {
  assert.equal(streamBatch(["a", "b"]), "a\nb");
  const many = Array.from({ length: 300 }, (_, i) => `line ${i}`);
  const batch = streamBatch(many, 5, 1234).split("\n");
  assert.equal(batch[0], "... 105 lines omitted (the pane's screen has them)");
  assert.equal(batch[1], "... 1234 bytes omitted (the pane's screen has them)");
  assert.equal(batch.at(-1), "line 299");
  assert.equal(batch.length, 2 + 200);
});

test("stream=true reads the pane's output from offset 0, strips escapes, notes a skip, and flushes the partial line at the end", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    const gate = join(fx.dir, "gate");
    process.env.KO_FAKE_RUN_WAIT_GATE = gate;
    process.env.KO_STREAM_FLUSH_MS = "10";
    const s = await startSession(fx);
    await s.tools.get("async_bash").execute("c", { command: "build", name: "build", stream: true });
    await pollUntil(() => fx.streamOpens("/panes/pane_9/output?offset=0") === 1, 2000, "the output stream");
    const first = "\x1b[1mone\x1b[0m\ntw";
    const second = "o\n3%\r";
    fx.output(bytes(0, first));
    fx.output(bytes(first.length, second));
    await pollUntil(() => customMessages(s, "ko-stream").length >= 1, 2000, "the first batch");
    const joined = () => customMessages(s, "ko-stream").map((m) => String(m.message.content).split("\n").slice(1).join("\n")).join("\n");
    await pollUntil(() => joined().includes("two"), 2000, "all lines");
    assert.equal(joined(), "one\ntwo");
    assert.equal(String(customMessages(s, "ko-stream")[0]!.message.content).split("\n")[0], 'async run "build" output (run run-1)');
    assert.deepEqual(customMessages(s, "ko-stream")[0]!.opts, { deliverAs: "steer", triggerTurn: true });

    const end = first.length + second.length;
    fx.output({ type: "skip", from: end, to: end + 1000 });
    fx.output(bytes(end + 1000, "after the gap\nlast, no newline"));
    await pollUntil(() => joined().includes("after the gap"), 2000, "the batch after the skip");
    assert.ok(joined().includes("... 1000 bytes omitted (the pane's screen has them)"));
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1, 2000, "the ending");
    assert.ok(joined().endsWith("last, no newline"), "the partial line is flushed before the ending");
    assert.ok(!joined().includes("3%"), "a carriage return starts the line over, and the skip came before the line ended");
  } finally {
    await fx.restore();
  }
});

test("a skip inside an escape sequence or in the middle of a character does not swallow what follows", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    process.env.KO_STREAM_FLUSH_MS = "10";
    const s = await startSession(fx);
    await s.tools.get("async_bash").execute("c", { command: "build", name: "build", stream: true });
    const title = Buffer.from("\x1b]0;a title that never ends");
    fx.output({ type: "bytes", offset: 0, data: title.toString("base64") });
    fx.output({ type: "skip", from: title.length, to: title.length + 100 });
    const cafe = Buffer.concat([Buffer.from("caf"), Buffer.from([0xc3])]);
    fx.output({ type: "bytes", offset: title.length + 100, data: cafe.toString("base64") });
    fx.output({ type: "bytes", offset: title.length + 100 + cafe.length, data: Buffer.from([0xa9, 0x0a]).toString("base64") });
    const joined = () => customMessages(s, "ko-stream").map((m) => String(m.message.content).split("\n").slice(1).join("\n")).join("\n");
    await pollUntil(() => joined().includes("caf"), 2000, "the line after the gap");
    assert.ok(joined().includes("café"), joined());
    assert.ok(joined().includes("... 100 bytes omitted"));
  } finally {
    await fx.restore();
  }
});

test("a /reload parks the output stream at its offset and reopens it there", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    process.env.KO_STREAM_FLUSH_MS = "10";
    process.env.KO_FAKE_RUN_WAIT_GATE = join(fx.dir, "never");
    const first = await startSession(fx, { factory: await freshExtension() });
    await first.tools.get("async_bash").execute("c", { command: "build", name: "build", stream: true });
    fx.output(bytes(0, "before\n"));
    const joined = (s: typeof first) => customMessages(s, "ko-stream").map((m) => String(m.message.content)).join("\n");
    await pollUntil(() => joined(first).includes("before"), 2000, "the first lines");
    await first.emit("session_shutdown", { reason: "reload" });

    fx.output(bytes(7, "in the gap\n"));
    const second = await startSession(fx, { factory: await freshExtension() });
    await pollUntil(() => fx.streamOpens("/panes/pane_9/output?offset=7") === 1, 2000, "the stream to reopen at offset 7");
    await pollUntil(() => joined(second).includes("in the gap"), 2000, "the line of the gap");
    assert.ok(!joined(second).includes("before"), "nothing is read twice");
    assert.equal(fx.runWaitCalls().length, 2, "the watch for the ending is back too");
  } finally {
    await fx.restore();
  }
});

test("list_async_bash lists every running job and the newest 20 ended; stop_async_bash stops one by name and silences it", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    const rows = [
      { id: "run-live", name: "server", parent: "pane_1", pane: "pane_20", startedAt: "2023-11-14T22:00:00Z" },
      ...Array.from({ length: 22 }, (_, i) => ({
        id: `run-end-${String(i).padStart(2, "0")}`,
        name: `job${i}`,
        parent: "pane_1",
        pane: `pane_${30 + i}`,
        startedAt: `2023-11-15T00:${String(i).padStart(2, "0")}:00Z`,
        outcome: { result: "completed", text: "" },
      })),
    ];
    fx.setRuns(rows);
    process.env.KO_FAKE_RUN_WAIT_GATE = join(fx.dir, "never");
    const s = await startSession(fx);
    const listed = JSON.parse(text(await s.tools.get("list_async_bash").execute("c", {}))) as Array<Record<string, any>>;
    assert.equal(listed.length, 21, "one running and the newest 20 ended");
    assert.deepEqual(listed.slice(0, 2).map((r) => [r.run, r.state]), [["run-end-21", "ended"], ["run-end-20", "ended"]], "newest first");
    assert.equal(listed.at(-2)!.run, "run-end-02", "the oldest of the 20 ended");
    assert.equal(listed.at(-1)!.run, "run-live", "a running job lists wherever it started");
    assert.deepEqual(listed.find((r) => r.name === "server"), { run: "run-live", name: "server", state: "running", startedAt: "2023-11-14T22:00:00Z", pane: "pane_20", screen: "ko api '/panes/pane_20/screen?history=all'" });
    assert.deepEqual(fx.runsCalls().at(-1), ["runs", "--json", "--all", "--parent", "pane_1"]);

    await pollUntil(() => fx.runWaitCalls().some((call) => call[1] === "run-live"), 2000, "the watch of the live run");
    const stopped = await s.tools.get("stop_async_bash").execute("c", { run: "server" });
    assert.equal(stopped.isError, undefined);
    assert.match(text(stopped), /^stopped run run-live; killed its pane; pane pane_20; its output: ko api '\/panes\/pane_20\/screen\?history=all'/);
    assert.deepEqual(fx.runStopCalls(), [["run-stop", "run-live"]]);
    assert.deepEqual(notices(s), [], "a run that was stopped sends no ending notice");

    const unknown = await s.tools.get("stop_async_bash").execute("c", { run: "nothing" });
    assert.equal(unknown.isError, true);
    assert.match(text(unknown), /no async_bash job matches/);
    const ended = await s.tools.get("stop_async_bash").execute("c", { run: "run-end-05" });
    assert.match(text(ended), /^run run-end-05 \(job5\) had already ended: completed; its output:/, "an ended run is nothing to stop");
  } finally {
    await fx.restore();
  }
});

test("quitting stops the live runs of the session, and a reload does not", async () => {
  const fx = makeFixture();
  try {
    fakeRun(fx);
    fx.setRuns([
      { id: "run-live", name: "server", parent: "pane_1", pane: "pane_20", startedAt: "t" },
      { id: "run-done", name: "done", parent: "pane_1", pane: "pane_21", startedAt: "t", outcome: { result: "completed", text: "" } },
    ]);
    process.env.KO_FAKE_RUN_WAIT_GATE = join(fx.dir, "never");
    const s = await startSession(fx);
    await s.emit("session_shutdown", { reason: "reload" });
    assert.deepEqual(fx.runStopCalls(), []);
    const again = await startSession(fx);
    await again.emit("session_shutdown", { reason: "quit" });
    assert.deepEqual(fx.runStopCalls(), [["run-stop", "run-live"]]);
    assert.equal(fx.apiCalls().filter((c) => c.method === "DELETE" && c.path === "/panes/pane_1/vars").length, 1, "and the variables go");
  } finally {
    await fx.restore();
  }
});
