import { test } from "node:test";

import assert from "node:assert/strict";

import { chmodSync, writeFileSync, existsSync } from "node:fs";

import { join, dirname } from "node:path";

import { jsonLines, commandWork, makeFixture, createFakePi, loadExtensions, fakeCtx, startSession, freshExtensions, DEFAULT_SESSION, asSubagent, pollUntil, sendToInbox, twoPeers, argAfter, streamMessages, streamEnvelope, startWithShutdownSpy } from "./kido-fixture.ts";

// pi quirk: promptGuidelines strings become rules-section bullets, merged by
// buildRules (system-prompt.js); the shape assertions mirror
// _normalizePromptGuidelines (agent-session.js), which trims, drops empty and de-duplicates.
// The tools register in the factory, so this needs no fixture.
test("spawn_subagent and async_bash carry promptGuidelines pi will merge into its rules section", () => {
  const fixtures = createFakePi();
  loadExtensions(fixtures.pi);
  const spawnRules = fixtures.tools.get("spawn_subagent").promptGuidelines as string[];
  const bashRules = fixtures.tools.get("async_bash").promptGuidelines as string[];

  for (const [name, rules] of [["spawn_subagent", spawnRules], ["async_bash", bashRules]] as const) {
    assert.ok(Array.isArray(rules) && rules.length > 0, `${name} registers guidelines`);
    for (const rule of rules) {
      assert.equal(typeof rule, "string", `${name}: every guideline is a string`);
      assert.equal(rule, rule.trim(), `${name}: survives the normalizer's trim unchanged`);
      assert.ok(rule.length > 0, `${name}: no empty guideline, which the normalizer would drop`);
    }
    assert.equal(new Set(rules).size, rules.length, `${name}: no duplicate the normalizer would collapse`);
  }

  // buildRules de-duplicates by exact text, so the shared rule is one bullet.
  const shared = spawnRules.filter((r) => bashRules.includes(r));
  assert.equal(shared.length, 1, "exactly one rule is shared between the two tools");
});

// A held batch can be flushed with no turn in sight at all: its debounce fires on
// kido's own timer.
test("a stream batch flushed while the session is idle starts a turn the same way", { timeout: 10000 }, async (t) => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    t.mock.timers.enable({ apis: ["setTimeout", "Date"] });

    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 1")), "ok");
    t.mock.timers.tick(1000);
    assert.equal(streamMessages(s.messages).length, 1, "the debounce flushes the batch");
    assert.deepEqual(streamMessages(s.messages)[0].opts, { deliverAs: "steer", triggerTurn: true }, "pi starts the batch's turn itself");
    assert.deepEqual(s.delivered, [], "and no user message goes with it");
  } finally {
    t.mock.timers.reset();
    await fx.restore();
  }
});

// Fires on every prompt, not just the child's first: a task delivered once via
// deliverTask is the wrong lifetime for a standing rule.
// The handler must not return `systemPrompt` (or set forceSystemPrompt): pi
// 0.87.1's docs/extensions.md warns that replaces the whole prompt, which broke
// pi-claude-bridge's prompt-capture. The instruction goes in
// systemPromptOptions.promptGuidelines instead, added exactly once per call, never
// accumulated - the second emit here is what would catch a handler mutating
// something shared.
test("a subagent's before_agent_start hook adds the notify_parent instruction to systemPromptOptions rather than forcing a whole prompt; a root session's does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });

      const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
      const results = await s.emit("before_agent_start", event);
      assert.ok(results.every((r) => r === undefined), "the handler must not force a whole-prompt replacement");
      assert.equal(event.systemPromptOptions.promptGuidelines.length, 2, "the never-sleep rule and the notify_parent instruction are each added as one guideline");
      assert.match(event.systemPromptOptions.promptGuidelines[0], /sleep/, "the always-on never-sleep rule rides first");
      assert.match(event.systemPromptOptions.promptGuidelines[1], /notify_parent/, "names the tool the model must call");
      assert.match(
        event.systemPromptOptions.promptGuidelines[1],
        /entire response|whole response/i,
        "also carries the stop-after-replying instruction",
      );

      const event2: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
      await s.emit("before_agent_start", event2);
      assert.equal(event2.systemPromptOptions.promptGuidelines.length, 2, "a second turn's own fresh options get the instructions once, not accumulated onto the first turn's");
    });
  } finally {
    await fx.restore();
  }

  const rootFx = makeFixture();
  try {
    rootFx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(rootFx); // root session
    const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
    const results = await s.emit("before_agent_start", event);
    assert.ok(results.every((r) => r === undefined), "a root session's system prompt is left alone");
    assert.equal(event.systemPromptOptions.promptGuidelines.length, 1, "the never-sleep rule still applies to a root session; the notify_parent instruction does not");
    assert.match(event.systemPromptOptions.promptGuidelines[0], /sleep/, "the always-on never-sleep rule");
  } finally {
    await rootFx.restore();
  }
});

test("interrupt_subagent runs kido tool interrupt_subagent with the target, and stop_run runs kido tool stop_run, passing --force through", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);

    const interruptRes = await s.tools.get("interrupt_subagent").execute("c1", { to: "peer-a" });
    assert.match(interruptRes.content[0].text, /interrupted peer-a/);
    assert.deepEqual(fx.lastControlArgs(), ["tool", "interrupt_subagent", "--", "peer-a"]);

    const stopRes = await s.tools.get("stop_run").execute("c2", { to: "peer-b" });
    assert.match(stopRes.content[0].text, /stopped peer-b/);
    assert.deepEqual(fx.lastControlArgs(), ["tool", "stop_run", "--", "peer-b"]);

    await s.tools.get("stop_run").execute("c3", { to: "peer-b", force: true });
    assert.deepEqual(fx.lastControlArgs(), ["tool", "stop_run", "--force", "--", "peer-b"]);
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent passes the task, tools, model, resume, fork and refusal cases through kido's argv", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // Fire-and-forget: nothing to await but the file it eventually writes.
    await pollUntil(() => fx.lastStatusArgs() !== undefined);
    const own = argAfter(fx.lastStatusArgs(), "--caller");
    assert.equal(own, DEFAULT_SESSION, "session_start reported under its own session id");

    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
    assert.match(result.content[0].text, /kid-1/);
    assert.equal(result.details.run, "fake-run-id", "the run id kido tool spawn_subagent printed is returned so the model can refer to it later");

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido tool spawn_subagent was invoked");
    assert.equal(fx.lastSpawnCaller(), own, "kido names its own session as the caller through PI_SESSION_ID");
    assert.equal(argAfter(spawnArgs, "--name"), "kid-1");
    assert.equal(argAfter(spawnArgs, "--task-file"), "-", "the task is passed as text on stdin, not as a file this tool manages");
    assert.equal(fx.lastSpawnTask(), "go do the thing", "the task's own text goes on stdin, not on the command line");

    const sepIndex = spawnArgs!.indexOf("--");
    assert.ok(sepIndex >= 0, "the child command follows --");
    assert.deepEqual(spawnArgs!.slice(sepIndex + 1), ["pi", "--name", "kid-1"]);

    const withTools = await spawn.execute("c2", { task: "t", model: "anthropic/sonnet", tools: ["read", "bash"] });
    const toolsArgs = fx.lastSpawnArgs()!;
    const toolsCommand = toolsArgs.slice(toolsArgs.indexOf("--") + 1);
    assert.equal(toolsCommand[0], "pi");
    assert.equal(argAfter(toolsCommand, "--model"), "anthropic/sonnet");
    assert.equal(argAfter(toolsArgs.slice(0, toolsArgs.indexOf("--")), "--tools"), "read,bash");
    assert.ok(!toolsCommand.includes("--tools"));

    const name = argAfter(toolsArgs, "--name");
    assert.ok(name, "a name was generated");
    assert.doesNotMatch(name!, /['"$#`\n\r]/, "a generated name avoids the characters tmux's own parsing cannot survive");
    assert.match(withTools.content[0].text, new RegExp(name!.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));

    const resumed = await spawn.execute("c3", { resume: "run-abc" });
    assert.match(resumed.content[0].text, /run-abc|fake-run-id/, "the run id is named in the result");
    const resumeArgs = fx.lastSpawnArgs()!;
    assert.equal(argAfter(resumeArgs, "--resume"), "run-abc");
    assert.equal(fx.lastSpawnCaller(), own, "carries its own identity through exactly as a fresh spawn does");
    assert.ok(!resumeArgs.includes("--task-file"), "a resume keeps its own original task; no task file is written for it");
    assert.ok(!resumeArgs.includes("--name"), "a resume keeps its own original window name");
    assert.deepEqual(resumeArgs.slice(resumeArgs.indexOf("--") + 1), ["pi"], "no command override is sent when neither model nor tools is given");

    await spawn.execute("c4", { resume: "run-abc", model: "claude-opus-5", tools: ["read"] });
    const resumeToolsArgs = fx.lastSpawnArgs()!;
    const resumeSep = resumeToolsArgs.indexOf("--");
    assert.ok(resumeSep >= 0, "a command override follows -- when model/tools are given");
    const resumeCommand = resumeToolsArgs.slice(resumeSep + 1);
    assert.equal(resumeCommand[0], "pi");
    assert.equal(argAfter(resumeCommand, "--model"), "claude-opus-5");
    assert.equal(argAfter(resumeToolsArgs.slice(0, resumeSep), "--tools"), "read");
    assert.ok(!resumeCommand.includes("--tools"));

    await spawn.execute("c5", { task: "decide", name: "kid-plain" });
    assert.ok(!fx.lastSpawnArgs()!.includes("--fork"), "an ordinary spawn must not fork anything");

    const forked = await spawn.execute("c6", { task: "decide", name: "kid-fork", fork: true });
    const forkArgs = fx.lastSpawnArgs()!;
    assert.equal(argAfter(forkArgs, "--fork"), DEFAULT_SESSION, "the caller's own session id is what is forked, not anything the model named");
    assert.equal(argAfter(forkArgs, "--task-file"), "-", "a forked child is still given its task the ordinary way");
    assert.equal(fx.lastSpawnTask(), "decide");
    assert.match(forked.content[0].text, /forked from this session/, "the model is told the child holds its context");
    const forkCommand = forkArgs.slice(forkArgs.indexOf("--") + 1);
    assert.deepEqual(forkCommand, ["pi", "--name", "kid-fork"], "the child command is untouched: --fork is kido's to place");

    await spawn.execute("c7", { resume: "run-abc", task: "a new task" });
    assert.equal(argAfter(fx.lastSpawnArgs(), "--resume"), "run-abc");
    assert.equal(argAfter(fx.lastSpawnArgs(), "--task-file"), "-");
    assert.equal(fx.lastSpawnTask(), "a new task");

    await spawn.execute("c8", { resume: "run-abc", name: "kid-1" });
    assert.equal(argAfter(fx.lastSpawnArgs(), "--resume"), "run-abc");
    assert.equal(argAfter(fx.lastSpawnArgs(), "--name"), "kid-1");

    await spawn.execute("c9", { resume: "run-abc", fork: true });
    assert.equal(argAfter(fx.lastSpawnArgs(), "--resume"), "run-abc");
    assert.equal(argAfter(fx.lastSpawnArgs(), "--fork"), DEFAULT_SESSION);

    await spawn.execute("c10", {});
    assert.ok(!fx.lastSpawnArgs()!.includes("--resume"), "no resume to forward");
    assert.ok(!fx.lastSpawnArgs()!.includes("--task-file"), "no task to forward, which kido refuses");
  } finally {
    await fx.restore();
  }
});

test("spawn_subagent reports a kido tool spawn_subagent timeout as a timeout, not a generic failure", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const savedTimeout = process.env.KIDO_SPAWN_TIMEOUT_MS;
    process.env.KIDO_SPAWN_TIMEOUT_MS = "300";
    process.env.KIDO_FAKE_SPAWN_DELAY_MS = "2000"; // longer than the timeout: in-flight, not failed
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
      assert.match(result.content[0].text, /timed out/);
      assert.ok(fx.lastSpawnArgs(), "kido tool spawn_subagent was invoked before the timeout fired");
    } finally {
      delete process.env.KIDO_FAKE_SPAWN_DELAY_MS;
      if (savedTimeout === undefined) delete process.env.KIDO_SPAWN_TIMEOUT_MS;
      else process.env.KIDO_SPAWN_TIMEOUT_MS = savedTimeout;
    }
  } finally {
    await fx.restore();
  }
});

test("a child started with KIDO_AGENT_TASK_FILE delivers its task as the first message, keeps the file, and marks it delivered", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "task.txt");
    writeFileSync(taskFile, "do the important thing");

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      assert.ok(
        s.delivered.some((d) => d.text === "do the important thing"),
        "the task reached the model as a user message, the same way an inbox prompt is delivered",
      );
      // Kept, not unlinked: read back later by `kido runs <run-id>`. A sibling marker
      // is what stops a later /reload from delivering it again.
      assert.equal(existsSync(taskFile), true, "the task file survives delivery");
      assert.equal(existsSync(join(dirname(taskFile), "delivered")), true, "a delivered marker is written");

      // A /reload re-runs session_start with a fresh ctx, not the factory, so the
      // delivered marker must be what stops a second delivery, not module state.
      await s.emit("session_start", {}, fakeCtx());
      assert.equal(
        s.delivered.filter((d) => d.text === "do the important thing").length,
        1,
        "the task must not be delivered again once its marker exists",
      );
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    await fx.restore();
  }
});

test("an unreadable KIDO_AGENT_TASK_FILE delivers nothing, breaks nothing, and leaves nothing behind", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "unreadable-task.txt");
    writeFileSync(taskFile, "a task nobody can read");
    chmodSync(taskFile, 0o000);

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing is delivered from a file that could not be read");
      assert.equal(existsSync(join(dirname(taskFile), "delivered")), false, "no marker is written for a read that failed, so a later /reload gets another try");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
      if (existsSync(taskFile)) chmodSync(taskFile, 0o600);
    }
  } finally {
    await fx.restore();
  }
});

// A child whose pi could not start a model at all never ran a turn; when it
// ends, the ending says so, so the parent can tell it from one that ended mid-work.
test("a child whose first turn never starts records that no turn ever ran when it ends", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    const taskFile = join(fx.inboxDir, "..", "never-started-task.txt");
    writeFileSync(taskFile, "do the important thing");
    await asSubagent(
      "never-started-run",
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory, "never-started-run");
        assert.ok(s.delivered.some((d) => d.text === "do the important thing"), "the task was delivered, as it was in the incident");

        await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
        const args = fx.lastRunOutcomeArgs();
        assert.ok(args, "an outcome is recorded for a run that ended this way");
        assert.deepEqual(args!.slice(0, 3), ["run-outcome", "--result", "failed"], "a child that never worked did not complete");
        assert.match(argAfter(args!, "--text") ?? "", /no turn/i, "the outcome's detail tells a parent 'never started' from 'ended mid-work'");
        assert.equal(args!.at(-1), "never-started-run", "recorded against this run");
      },
      { KIDO_AGENT_TASK_FILE: taskFile, KIDO_PARENT_POLL_MS: "5000" },
    );
  } finally {
    await fx.restore();
  }
});

// Negative control: a child whose task starts a turn gets the ordinary ending.
test("a child whose task starts a turn ends as completed", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    const taskFile = join(fx.inboxDir, "..", "working-task.txt");
    writeFileSync(taskFile, "do the important thing");
    await asSubagent(
      "working-run",
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory, "working-run");
        await s.emit("agent_start", {});
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
        assert.deepEqual(
          fx.lastRunOutcomeArgs(),
          ["run-outcome", "--result", "completed", "--", "working-run"],
          "the outcome a working child has always got, detail and all",
        );
      },
      { KIDO_AGENT_TASK_FILE: taskFile, KIDO_PARENT_POLL_MS: "5000" },
    );
  } finally {
    await fx.restore();
  }
});

// A settled turn with no report would leave the parent waiting forever now
// that nothing ends the child; say once per turn that it is idle and unreported.
test("a settled turn without a report tells the parent once that the child is idle; a reported one does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("idle-run", async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory, "idle-run");
      await s.emit("agent_start", {});
      await s.emit("agent_settled", {}, { isIdle: () => true });
      const first = await fx.waitForLog("boss-session", "notice");
      assert.match(first!.text, /idle without reporting/, "the notice says the child is idle and did not report");
      assert.match(first!.text, /stop_run/, "it tells the parent how to end the child");
      assert.match(first!.text, /message_agent/, "and how to continue it");
      assert.ok(jsonLines(fx.logFile)[0].args.includes("--status"), "the idle notice is a status, not a report");

      await s.emit("agent_settled", {}, { isIdle: () => true });
      await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the idle notice's detached send");
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 1, "one notice per settled turn, not repeats");
      assert.equal(s.shutdowns(), 0, "the child stays alive until its parent decides");
    });
  } finally {
    await fx.restore();
  }

  const fx2 = makeFixture();
  try {
    fx2.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("reported-run", async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx2, factory, "reported-run");
      const res = await s.tools.get("notify_parent").execute("c1", { summary: "done" });
      assert.match(res.content[0].text, /delivered/, "the report went out");
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the report's detached send");
      assert.equal(jsonLines(fx2.logFile).filter((l) => l.kind === "notice").length, 1, "only the child's own report: a reported turn needs no idle notice");
    });
  } finally {
    await fx2.restore();
  }
});

test("async_bash passes the command, name and stream flags, and returns the printed run id and output path", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const asyncBash = s.tools.get("async_bash");

    await asyncBash.execute("c1", { command: "true" });
    assert.deepEqual(fx.lastAsyncBashArgs(), ["tool", "async_bash", "--", "true"], "a one-word command is passed through unchanged, with no --name");

    await asyncBash.execute("c2", { command: "make -j8 && ./run", name: "build" });
    assert.deepEqual(
      fx.lastAsyncBashArgs(),
      ["tool", "async_bash", "--name", "build", "--", "make -j8 && ./run"],
      "a multi-word command line still travels as one argument after --, unchanged; kido's own commandArgv decides bash -c vs argv",
    );

    await asyncBash.execute("c3", { command: "make", name: "build" });
    assert.deepEqual(fx.lastAsyncBashArgs(), ["tool", "async_bash", "--name", "build", "--", "make"], "streaming is off by default");

    await asyncBash.execute("c4", { command: "make", name: "build", stream: true });
    assert.deepEqual(fx.lastAsyncBashArgs(), ["tool", "async_bash", "--name", "build", "--stream", "--", "make"]);

    const result = await asyncBash.execute("c5", { command: "npm test", name: "tests" });
    assert.equal(result.details.run, "fake-async-run-id", "the run id kido tool async_bash printed is returned");
    const wantOutput = join(fx.runsDir, "fake-async-run-id", "output");
    assert.equal(result.details.output, wantOutput, "the output path is the fourth field of the line kido printed, not one rebuilt here");
    assert.match(result.content[0].text, /fake-async-run-id/, "the result text names the run");
    assert.match(result.content[0].text, new RegExp(wantOutput.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), "the result text names the output path");
    assert.match(result.content[0].text, /notice/, "the result text says a notice arrives on completion");
    assert.match(result.content[0].text, /read/, "the result text says the output file can be read meanwhile");
  } finally {
    await fx.restore();
  }
});
