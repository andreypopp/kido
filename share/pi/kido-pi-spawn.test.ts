import { test } from "node:test";

import assert from "node:assert/strict";

import { appendFileSync, existsSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import {
  makeFixture,
  selfPane,
  agentPane,
  startNamedSession,
  startSession,
  asSubagent,
  withEnv,
  pollUntil,
  customMessages,
  agentJson,
  argAfter,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

function writeOutput(fx: Fixture, text: string): string {
  const path = join(fx.stateDir, "runs", "fake-run-id", "output");
  mkdirSync(join(fx.stateDir, "runs", "fake-run-id"), { recursive: true });
  writeFileSync(path, text);
  return path;
}

function lastNotice(s: { messages: Array<{ message: { customType?: string; content: unknown }; opts: unknown }> }): string {
  return String(customMessages(s, "kido-notice").at(-1)?.message.content ?? "");
}

function waitNotice(s: { messages: Array<{ message: { customType?: string; content: unknown }; opts: unknown }> }, includes: string): Promise<void> {
  return pollUntil(() => lastNotice(s).includes(includes), 3000, `a notice naming ${JSON.stringify(includes)}`);
}

test("spawn_subagent starts kido-pi as a run-child, writes the child's directory first, and returns its identity", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const result = await s.tools.get("spawn_subagent").execute("c", { task: "do the thing", name: "kid" });

    assert.match(result.content[0].text, /^spawned kid \(window @9, pane %9, run fake-run-id\); its result arrives as a notice/);
    const argv = fx.runCalls()[0]!;
    const childSession = argAfter(argv, "--session-id")!;
    assert.match(childSession, /^[0-9a-f]{32}$/, "the parent mints the child's pi session id");
    assert.deepEqual(argv, [
      "run-child", "%1", "--name", "kid",
      "--env", `KIDO_AGENT_PARENT_SESSION=${SELF}`,
      "--env", `KIDO_AGENT_DIR=${join(fx.stateDir, "agents", SELF, "kid")}`,
      "--", "kido-pi", "--session-id", childSession, "--name", "kid",
    ]);
    assert.deepEqual(agentJson(fx, SELF, "kid"), { session: childSession, run: "fake-run-id", model: "", tools: [], fork: false });
    assert.equal(readFileSync(join(fx.agentDir(SELF, "kid"), "task"), "utf8"), "do the thing");
    assert.equal(result.details?.run, "fake-run-id");
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent carries the model, the tool ceiling and the fork", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setPi("#!/bin/sh\ncase \"$*\" in *--list-models*) printf 'PROVIDER\\tMODEL\\nacme\\tclaude-sonnet-5\\n' ;; esac\nexit 0\n");
    const s = await startNamedSession(fx, "Self");
    const result = await s.tools.get("spawn_subagent").execute("c", {
      task: "judge",
      name: "kid",
      model: "acme/claude-sonnet-5:low",
      tools: ["read", "bash"],
      fork: true,
    });
    assert.match(result.content[0].text, /forked from this session's context/);
    const argv = fx.runCalls()[0]!;
    assert.equal(argAfter(argv, "--model"), "acme/claude-sonnet-5:low");
    assert.equal(argAfter(argv, "--fork"), SELF);
    assert.equal(argAfter(argv, "--tools"), "read,bash");
    assert.deepEqual(agentJson(fx, SELF, "kid").tools, ["read", "bash"]);
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent refuses a bare model alias, an unknown thinking level, and a replayed name", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setPi("#!/bin/sh\ncase \"$*\" in *--list-models*) printf 'PROVIDER\\tMODEL\\nacme\\tclaude-sonnet-5\\nacme  claude-opus-5\\nother\\tgemini-pro\\n' ;; esac\nexit 0\n");
    const s = await startNamedSession(fx, "Self");
    const spawn = s.tools.get("spawn_subagent");

    assert.match(
      (await spawn.execute("c", { task: "x", name: "kid", model: "sonnet" })).content[0].text,
      /could not spawn subagent: model "sonnet" is not a model of a configured provider; configured: acme\/\{claude-sonnet-5,claude-opus-5\}, other\/\{gemini-pro\}/,
    );
    assert.match(
      (await spawn.execute("c", { task: "x", name: "kid", model: "acme/claude-sonnet-5:nope" })).content[0].text,
      /unknown thinking level "nope"/,
    );
    assert.equal(fx.runCalls().length, 0, "a refused model creates no window");

    await spawn.execute("c", { task: "x", name: "kid" });
    assert.match(
      (await spawn.execute("c", { task: "x", name: "kid" })).content[0].text,
      /the name "kid" is already taken by one of this session's runs; message it instead/,
    );
    assert.equal(fx.runCalls().length, 1);
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent refuses depth 3, a missing name, and a task over the cap", async () => {
  const fx = makeFixture();
  try {
    fx.writeAgent("root", "mid", { session: "mid" });
    fx.writeAgent("mid", "kid", { session: "kid" });
    fx.setPanes([agentPane({ pane: "%1", session: "kid", name: "kid" })]);
    await asSubagent(
      fx,
      "kid",
      async () => {
        const s = await startNamedSession(fx, "kid", "kid");
        const spawn = s.tools.get("spawn_subagent");
        assert.equal(
          (await spawn.execute("c", { task: "x", name: "grandkid" })).content[0].text,
          "could not spawn subagent: refusing to spawn at depth 3: maximum nesting is 2 (root 0, subagent 1, subagent 2)",
        );
        assert.equal((await spawn.execute("c", { task: "x", name: "" })).content[0].text, "could not spawn subagent: --name is required");
        assert.match(
          (await spawn.execute("c", { task: "x".repeat(1024 * 1024 + 1), name: "big" })).content[0].text,
          /the task is over the 1048576 byte task limit/,
        );
        assert.equal(fx.runCalls().length, 0);
      },
      { parent: "mid", name: "kid" },
    );
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent and async_bash refuse a name that is not one safe path component, before any write", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    for (const name of ["../other", "a/b", ".", ".."]) {
      const message = (await s.tools.get("spawn_subagent").execute("c", { task: "x", name })).content[0].text;
      assert.match(message, /^could not spawn subagent: refusing window name/, `${JSON.stringify(name)} was not refused: ${message}`);
      assert.equal(existsSync(join(fx.stateDir, "agents", SELF, name)), false, `${JSON.stringify(name)} wrote a directory`);
      const bash = (await s.tools.get("async_bash").execute("c", { command: "true", name })).content[0].text;
      assert.match(bash, /^could not start background command: refusing window name/);
    }
    assert.equal(fx.runCalls().length, 0, "no refused name started a run");
  } finally {
    await fx.restore();
  }
});

test("async_bash tees the whole command, so every line and the exit status survive", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    await withEnv({ KIDO_FAKE_RUN_EXEC: "1" }, async () => {
      for (const [id, command, expected, result, text] of [
        ["run-lines", "echo first; echo last", "first\nlast\n", "completed", ""],
        ["run-and", "echo make-output && echo run-output", "make-output\nrun-output\n", "completed", ""],
        ["run-exit", "echo before; exit 7", "before\n", "failed", "exit 7"],
      ] as const) {
        await withEnv({ KIDO_FAKE_RUN_ID: id }, async () => {
          await s.tools.get("async_bash").execute("c", { command, name: id });
          assert.equal(readFileSync(join(fx.stateDir, "runs", id, "output"), "utf8"), expected, `${command} lost output`);
          const row = JSON.parse(readFileSync(fx.runsFile, "utf8")).find((r: { id: string }) => r.id === id);
          assert.equal(row.outcome.result, result, `${command} recorded the wrong result`);
          assert.equal(row.outcome.text, text, `${command} recorded the wrong status`);
        });
      }
    });
  } finally {
    await fx.restore();
  }
});

test("async_bash requires a name, runs through bash with the tee line, and returns the run and output", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const asyncBash = s.tools.get("async_bash");

    assert.equal((await asyncBash.execute("c", { command: "make", name: "" })).content[0].text, "could not start background command: --name is required");
    const result = await asyncBash.execute("c", { command: "make -j8", name: "build" });
    assert.match(result.content[0].text, /^started run fake-run-id \(build\) in window @9;/);
    const argv = fx.runCalls()[0]!;
    assert.deepEqual(argv, ["run-child", "%1", "--name", "build", "--", "bash", "-o", "pipefail", "-c", '{\nmake -j8\n} 2>&1 | tee "$KIDO_RUN_OUTPUT"']);
    assert.match(result.content[0].text, /read .*runs\/fake-run-id\/output with the read tool/);
    assert.match(
      (await asyncBash.execute("c", { command: "make", name: "build" })).content[0].text,
      /the name "build" is already taken by one of this session's runs; choose another name/,
    );
  } finally {
    await fx.restore();
  }
});

test("a bash run's ending notice carries the result, the output path and the tail of the file", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "failed", text: "exit status 3" }) }, async () => {
      const s = await startNamedSession(fx, "Self");
      await s.tools.get("async_bash").execute("c", { command: "make", name: "build" });
      await pollUntil(() => fx.runWaitCalls().length === 1, 3000, "run-wait to start");
      const output = writeOutput(fx, "out\nerr\n");
      writeFileSync(gate, "");
      await waitNotice(s, "exit status 3");
      assert.equal(
        lastNotice(s),
        `notice from build (a subagent or background run's report, not the user):\nasync run "build" failed: exit status 3\nrun: fake-run-id\noutput: ${output}\n--- output ---\nout\nerr\n`,
      );
      assert.deepEqual(fx.runWaitCalls()[0], ["run-wait", "fake-run-id", "--json"]);
    });
  } finally {
    await fx.restore();
  }
});

test("a subagent's ending notice says it never reported when there is no report, and message it", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) }, async () => {
      const s = await startNamedSession(fx, "Self");
      await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
      await pollUntil(() => fx.runWaitCalls().length === 1, 3000, "run-wait to start");
      writeFileSync(gate, "");
      await waitNotice(s, "without a report");
      assert.equal(
        lastNotice(s),
        `notice from kid (a subagent or background run's report, not the user):\nsubagent "kid" completed without a report: none of its turns ended in a report, so this is the whole account of it\nrun: fake-run-id\nmessage it to continue it, or stop_run to end it\n`,
      );
      assert.doesNotMatch(lastNotice(s), /resume/);
    });
  } finally {
    await fx.restore();
  }
});

test("a subagent's ending notice says it reported plainly, and names the earlier report when its last work went unreported", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) }, async () => {
      const s = await startNamedSession(fx, "Self");
      await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
      await pollUntil(() => fx.runWaitCalls().length === 1, 3000, "the first run-wait to start");
      await withEnv({ KIDO_FAKE_RUN_ID: "fake-run-id-2" }, () => s.tools.get("spawn_subagent").execute("c", { task: "y", name: "kid2" }));
      await pollUntil(() => fx.runWaitCalls().length === 2, 3000, "the second run-wait to start");
      writeFileSync(join(fx.agentDir(SELF, "kid"), "report"), "done");
      const report = join(fx.agentDir(SELF, "kid2"), "report");
      writeFileSync(report, "first account");
      const past = new Date(Date.now() - 2000);
      utimesSync(report, past, past);
      writeFileSync(join(fx.agentDir(SELF, "kid2"), "work"), "");
      writeFileSync(gate, "");
      await pollUntil(() => customMessages(s, "kido-notice").length === 2, 3000, "both ending notices");
      const notices = customMessages(s, "kido-notice").map((m) => String(m.message.content));
      const plain = notices.find((n) => n.includes(`subagent "kid"`))!;
      assert.ok(!plain.includes("without a report"), "a report on the last work is a plain ending");
      assert.ok(!plain.includes("message it"), "a reported child gets no continue hint");
      const earlier = notices.find((n) => n.includes(`subagent "kid2"`))!;
      assert.equal(
        earlier,
        `notice from kid2 (a subagent or background run's report, not the user):\nsubagent "kid2" completed without reporting on its last work: its earlier report is ${report}\nrun: fake-run-id-2\nmessage it to continue it, or stop_run to end it\n`,
      );
      assert.ok(!earlier.includes("no turn of it settled"));
    });
  } finally {
    await fx.restore();
  }
});

test("a stream run's output arrives in batches, capped, before the ending notice", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    await withEnv(
      { KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }), KIDO_STREAM_POLL_MS: "20", KIDO_STREAM_FLUSH_MS: "20", KIDO_STREAM_MAX_WAIT_MS: "60" },
      async () => {
        const s = await startNamedSession(fx, "Self");
        await s.tools.get("async_bash").execute("c", { command: "make", name: "build", stream: true });
        const output = writeOutput(fx, "line 1\nline 2\n");
        await pollUntil(() => customMessages(s, "kido-stream").length > 0, 3000, "a stream batch");
        const firstBatch = customMessages(s, "kido-stream")[0]!;
        assert.equal(firstBatch.message.content, `async run "build" output (run fake-run-id)\nline 1\nline 2`);
        assert.deepEqual(firstBatch.opts, { deliverAs: "steer", triggerTurn: true }, "a batch steers without costing a turn of its own");

        appendFileSync(output, Array.from({ length: 300 }, (_, i) => `line ${i}`).join("\n") + "\n");
        await pollUntil(() => customMessages(s, "kido-stream").some((m) => String(m.message.content).includes("lines omitted")), 3000, "a capped batch");
        const capped = String(customMessages(s, "kido-stream").at(-1)!.message.content);
        const omitted = capped.match(/^.*\.\.\. (\d+) lines omitted \(see (.*)\)$/m)!;
        assert.ok(Number(omitted[1]) > 0);
        assert.equal(omitted[2], output);
        assert.ok(capped.split("\n").length <= 202, "a batch keeps at most 200 lines plus its header and omission line");
        assert.ok(capped.includes("line 299"), "the newest lines are the ones kept");

        appendFileSync(output, "final line");
        writeFileSync(gate, "");
        await waitNotice(s, "completed");
        const kinds = s.messages.map((m) => m.message.customType);
        const notice = kinds.lastIndexOf("kido-notice");
        assert.equal(kinds[notice - 1], "kido-stream", "the held output is delivered before the ending");
        assert.match(String(s.messages[notice - 1]!.message.content), /final line/);
      },
    );
  } finally {
    await fx.restore();
  }
});

test("a stream batch rides a tool boundary, and a run's spent output budget says the rest is only in the file", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    const output = join(fx.stateDir, "runs", "fake-run-id", "output");
    await withEnv(
      {
        KIDO_FAKE_RUN_WAIT_GATE: gate,
        KIDO_STREAM_POLL_MS: "20",
        KIDO_STREAM_FLUSH_MS: "5000",
        KIDO_STREAM_MAX_WAIT_MS: "5000",
        KIDO_STREAM_BUDGET_BYTES: "1",
      },
      async () => {
        const s = await startNamedSession(fx, "Self");
        await s.tools.get("async_bash").execute("c", { command: "make", name: "build", stream: true });
        appendFileSync(output, "from a tool\n");
        await pollUntil(async () => {
          await s.emit("turn_end", { toolResults: [{}] });
          return customMessages(s, "kido-stream").some((m) => String(m.message.content).includes("from a tool"));
        }, 3000, "a tool boundary to carry the held batch");
        appendFileSync(output, "after the budget\n");
        await pollUntil(async () => {
          await s.emit("turn_end", { toolResults: [{}] });
          return customMessages(s, "kido-stream").some((m) => String(m.message.content).includes("output budget spent"));
        }, 3000, "the budget line");
        assert.equal(readFileSync(output, "utf8").includes("from a tool"), true, "the output file still has everything");
      },
    );
  } finally {
    await fx.restore();
  }
});

test("a working agent holds stream lines past the idle deadline, and agent_end starts the schedule", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    const output = join(fx.stateDir, "runs", "fake-run-id", "output");
    await withEnv(
      { KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_STREAM_POLL_MS: "20", KIDO_STREAM_FLUSH_MS: "50", KIDO_STREAM_MAX_WAIT_MS: "200" },
      async () => {
        const s = await startNamedSession(fx, "Self");
        await s.tools.get("async_bash").execute("c", { command: "make", name: "build", stream: true });
        await s.emit("turn_start");
        appendFileSync(output, "held while working\n");
        await new Promise((resolve) => setTimeout(resolve, 150));
        assert.equal(customMessages(s, "kido-stream").length, 0, "the idle schedule must not run while the agent works");
        await s.emit("agent_end", { messages: [] });
        await pollUntil(() => customMessages(s, "kido-stream").some((m) => String(m.message.content).includes("held while working")), 2000, "the held batch after agent_end");
      },
    );
  } finally {
    await fx.restore();
  }
});

test("concurrent spawn_subagent calls with one name launch one child and refuse the other", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "runs-gate");
    await withEnv({ KIDO_FAKE_RUNS_GATE: gate, KIDO_FAKE_RUN_ID: "fake-run-id" }, async () => {
      const s = await startNamedSession(fx, "Self");
      const spawn = s.tools.get("spawn_subagent");
      const first = spawn.execute("a", { task: "first task", name: "kid" });
      const second = spawn.execute("b", { task: "second task", name: "kid" });
      await pollUntil(() => fx.runsCalls().length >= 1, 3000, "the first name check");
      await new Promise((resolve) => setImmediate(resolve));
      writeFileSync(gate, "");
      const results = await Promise.all([first, second]);
      const texts = results.map((r) => r.content[0].text);
      assert.equal(texts.filter((t) => t.startsWith("spawned")).length, 1, "one spawn wins");
      assert.equal(texts.filter((t) => t.includes("already taken")).length, 1, "the other is refused by name");
      assert.equal(fx.runCalls().filter((argv) => argv[0] === "run-child").length, 1, "one run-child");
      const task = readFileSync(join(fx.agentDir(SELF, "kid"), "task"), "utf8");
      const winner = texts[0]!.startsWith("spawned") ? "first task" : "second task";
      assert.equal(task, winner, "the surviving task is the winner's task");
      assert.equal(agentJson(fx, SELF, "kid").run, "fake-run-id", "the surviving agent.json names the live run");
    });
  } finally {
    await fx.restore();
  }
});

test("stop_run refuses this session's own name, session id and run id", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(
      fx,
      "worker-session",
      async () => {
        const inbox = await fx.startInbox();
        fx.setPanes([agentPane({ pane: "%1", session: "worker-session", name: "worker", inbox: inbox.path })]);
        const s = await startNamedSession(fx, "worker", "worker-session");
        for (const to of ["worker", "worker-session", "worker-run"]) {
          assert.match((await s.tools.get("stop_run").execute("c", { to })).content[0].text, /^no run matches/, to);
        }
        assert.equal(fx.runOutcomeCalls().length, 0, "self is not recorded");
        assert.equal(fx.runStopCalls().length, 0, "self is not stopped");
      },
      { parent: "boss-session", name: "worker", run: "worker-run" },
    );
  } finally {
    await fx.restore();
  }
});

test("idle stream backoff grows across idle turns and resets at a tool boundary", async (t) => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "gate");
    const output = join(fx.stateDir, "runs", "fake-run-id", "output");
    await withEnv(
      { KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_STREAM_POLL_MS: "10", KIDO_STREAM_FLUSH_MS: "100", KIDO_STREAM_MAX_WAIT_MS: "1000" },
      async () => {
        const s = await startNamedSession(fx, "Self");
        await s.tools.get("async_bash").execute("c", { command: "make", name: "build", stream: true });
        t.mock.timers.enable({ apis: ["setTimeout"] });
        const io = async (ms = 40): Promise<void> => {
          const end = performance.now() + ms;
          while (performance.now() < end) await new Promise((resolve) => setImmediate(resolve));
        };
        const batches = (): number => customMessages(s, "kido-stream").length;
        const idleTurn = async (): Promise<void> => {
          await s.emit("agent_start");
          await s.emit("turn_end", { toolResults: [] });
          await s.emit("agent_end", { messages: [] });
          await s.emit("agent_settled", {}, { isIdle: () => true });
        };

        appendFileSync(output, "one\n");
        await io();
        t.mock.timers.tick(100);
        assert.equal(batches(), 1, "the base delay sends the first batch");

        await idleTurn();
        appendFileSync(output, "two\n");
        await io();
        t.mock.timers.tick(199);
        assert.equal(batches(), 1, "the second idle wait has doubled");
        t.mock.timers.tick(1);
        assert.equal(batches(), 2, "the doubled delay sends the second batch");

        await idleTurn();
        appendFileSync(output, "three\n");
        await io();
        t.mock.timers.tick(399);
        assert.equal(batches(), 2, "the third idle wait doubled again");
        t.mock.timers.tick(1);
        assert.equal(batches(), 3, "the quadrupled delay sends the third batch");

        await s.emit("turn_end", { toolResults: [{}] });
        appendFileSync(output, "four\n");
        await io();
        t.mock.timers.tick(100);
        assert.equal(batches(), 4, "a tool boundary resets the delay to the base");
      },
    );
  } finally {
    await fx.restore();
  }
});

test("stop_run stops a bash run with run-stop, and a subagent with a stop request then run-stop --wait 5", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    await s.tools.get("async_bash").execute("c", { command: "make", name: "build" });
    assert.equal((await s.tools.get("stop_run").execute("c", { to: "build" })).content[0].text, "stopped run fake-run-id; killed its pane");
    assert.deepEqual(fx.runStopCalls()[0], ["run-stop", "fake-run-id"]);
  } finally {
    await fx.restore();
  }
});

test("stop_run asks a subagent to stop first, then records completed only when it reported since its last work", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
    const child = agentJson(fx, SELF, "kid");
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: child.session, name: "kid", inbox: inbox.path })]);
    const rows = [{ id: "fake-run-id", name: "kid", parent: "%1", pane: "%2", session: child.session }];
    fx.setRuns(rows);
    const report = join(fx.agentDir(SELF, "kid"), "report");
    const work = join(fx.agentDir(SELF, "kid"), "work");
    writeFileSync(report, "done");

    const result = await s.tools.get("stop_run").execute("c", { to: "kid" });
    assert.match(result.content[0].text, /^stopped kid; /);
    assert.deepEqual(fx.runOutcomeCalls()[0], ["run-outcome", "fake-run-id", "--result", "completed"], "the ending is recorded before the child is asked to shut down");
    assert.equal(JSON.parse(inbox.received()[0]!).kind, "stop", "the child is asked to shut down over its inbox");
    assert.deepEqual(fx.runStopCalls()[0], ["run-stop", "fake-run-id", "--wait", "5"]);

    writeFileSync(work, "");
    const past = new Date(Date.now() - 2000);
    utimesSync(report, past, past);
    fx.setRuns(rows);
    await s.tools.get("stop_run").execute("c", { to: "kid" });
    assert.deepEqual(fx.runOutcomeCalls()[1], ["run-outcome", "fake-run-id", "--result", "stopped"], "a child at work on unreported work is stopped");

    const tied = new Date();
    utimesSync(report, tied, tied);
    utimesSync(work, tied, tied);
    fx.setRuns(rows);
    await s.tools.get("stop_run").execute("c", { to: "kid" });
    assert.deepEqual(fx.runOutcomeCalls()[2], ["run-outcome", "fake-run-id", "--result", "stopped"], "a report tied with the work is not newer, so it is stopped");
  } finally {
    await fx.restore();
  }
});

test("stop_run with force skips the request, and a subagent with no inbox needs force", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
    const child = agentJson(fx, SELF, "kid");
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: child.session, name: "kid", inbox: inbox.path })]);
    fx.setRuns([{ id: "fake-run-id", name: "kid", parent: "%1", pane: "%2", session: child.session }]);

    await s.tools.get("stop_run").execute("c", { to: "kid", force: true });
    assert.equal(inbox.received().length, 0, "force skips the stop request");
    assert.deepEqual(fx.runOutcomeCalls()[0], ["run-outcome", "fake-run-id", "--result", "stopped"]);
    assert.deepEqual(fx.runStopCalls()[0], ["run-stop", "fake-run-id", "--wait", "5"]);

    fx.setRuns([{ id: "fake-run-id", name: "kid", parent: "%1", pane: "%2", session: child.session }]);
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: child.session, name: "kid" })]);
    assert.equal(
      (await s.tools.get("stop_run").execute("c", { to: "kid" })).content[0].text,
      "subagent kid has no inbox for a stop request; pass --force to kill its window instead",
    );
    assert.equal(fx.runStopCalls().length, 1, "a refused stop records nothing");
    await s.tools.get("stop_run").execute("c", { to: "kid", force: true });
    assert.equal(fx.runStopCalls().length, 2);
  } finally {
    await fx.restore();
  }
});

test("the stop wrapper's deadline outlives run-stop's wait and escalation", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "stop-gate");
    await withEnv({ KIDO_FAKE_RUN_STOP_GATE: gate, KIDO_STOP_ESCALATION_MS: "50" }, async () => {
      const s = await startNamedSession(fx, "Self");
      await s.tools.get("async_bash").execute("c", { command: "make", name: "build" });
      const stopped = s.tools.get("stop_run").execute("c", { to: "build" });
      await pollUntil(() => fx.runStopCalls().length === 1, 2000, "run-stop to start");
      writeFileSync(gate, "");
      assert.equal((await stopped).content[0].text, "stopped run fake-run-id; killed its pane");
    });
  } finally {
    await fx.restore();
  }
});

test("stop_run refuses an unrelated run and resolves a unique prefix of at least eight characters", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setRuns([{ id: "abcdef0123456789", name: "job", parent: "%1" }]);
    const s = await startNamedSession(fx, "Self");
    assert.equal((await s.tools.get("stop_run").execute("c", { to: "nope" })).content[0].text, 'no run matches "nope"');
    assert.equal((await s.tools.get("stop_run").execute("c", { to: "a" })).content[0].text, 'no run matches "a"', "a prefix shorter than the minimum is not a prefix");
    assert.equal((await s.tools.get("stop_run").execute("c", { to: "abcdef01" })).content[0].text, "stopped run abcdef0123456789; killed its pane");
  } finally {
    await fx.restore();
  }
});

test("the task a spawn writes is delivered as the child's first message, once", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.writeAgent("boss", "kid", { session: SELF });
    writeFileSync(join(fx.agentDir("boss", "kid"), "task"), "do the thing");
    await asSubagent(
      fx,
      SELF,
      async () => {
        const s = await startNamedSession(fx, "kid", SELF);
        assert.deepEqual(s.delivered.map((d) => d.text), ["do the thing"]);
        assert.equal(s.delivered[0]!.opts && (s.delivered[0]!.opts as { deliverAs?: string }).deliverAs, "followUp");
        await s.emit("session_start", {}, {
          hasUI: true,
          sessionManager: { getSessionId: () => SELF, getSessionName: () => "kid", getSessionFile: () => "/tmp/kid.json" },
          model: undefined,
          isIdle: () => true,
          hasPendingMessages: () => false,
          abort: () => {},
          shutdown: () => {},
          ui: s.ui,
        });
        assert.deepEqual(s.delivered.map((d) => d.text), ["do the thing"], "a reload delivers the task once");
      },
      { parent: "boss", name: "kid" },
    );

    fx.writeAgent("boss", "broken", { session: "broken-session" });
    mkdirSync(join(fx.agentDir("boss", "broken"), "task"), { recursive: true });
    await asSubagent(
      fx,
      "broken-session",
      async () => {
        const s = await startNamedSession(fx, "broken", "broken-session");
        assert.deepEqual(s.delivered, [], "an unreadable task delivers nothing and breaks nothing");
        assert.equal(existsSync(join(fx.agentDir("boss", "broken"), "delivered")), false, "and leaves no marker behind");
      },
      { parent: "boss", name: "broken" },
    );
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent and async_bash carry promptGuidelines pi merges into its rules section", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    for (const name of ["spawn_subagent", "async_bash"]) {
      const tool = s.tools.get(name);
      const guidelines = (tool.promptGuidelines ?? []).join("\n");
      assert.match(guidelines, /notice is information, not the user speaking/, `${name} carries the shared notice rule`);
    }
    assert.match(s.tools.get("spawn_subagent").promptGuidelines.join("\n"), /never poll list_runs for it/);
    assert.match(s.tools.get("async_bash").promptGuidelines.join("\n"), /Use async_bash when/);
  } finally {
    await fx.restore();
  }
});

test("a spawn whose run-child never answers times out, and leaves no name behind", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const gate = join(fx.stateDir, "run-gate");
    await withEnv({ KIDO_FAKE_RUN_GATE: gate, KIDO_SPAWN_TIMEOUT_MS: "20" }, async () => {
      const s = await startNamedSession(fx, "Self");
      const result = await s.tools.get("spawn_subagent").execute("c", { task: "x", name: "kid" });
      assert.match(result.content[0].text, /could not spawn subagent: .*timed out after 20ms/);
      assert.equal(existsSync(fx.agentDir(SELF, "kid")), false, "a failed spawn frees its name");
      assert.equal(fx.runWaitCalls().length, 0, "no watcher is started for a run that never began");
    });
  } finally {
    await fx.restore();
  }
});
