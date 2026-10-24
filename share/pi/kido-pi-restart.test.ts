import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, mkdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import {
  makeFixture,
  selfPane,
  agentPane,
  startNamedSession,
  asSubagent,
  withEnv,
  pollUntil,
  customMessages,
  agentJson,
  argAfter,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

type Started = Awaited<ReturnType<typeof startNamedSession>>;

// A spawned child whose first run has ended: the pane is gone and the run has an
// outcome, exactly what a restart resolves.
async function endedChild(fx: Fixture, options: { sessionFile?: boolean; outcome?: string } = {}): Promise<{ s: Started; child: { session: string; run: string } }> {
  fx.setPanes([selfPane()]);
  const s = await startNamedSession(fx, "Self");
  await s.tools.get("spawn_subagent").execute("c", { task: "do the thing", name: "kid" });
  const child = agentJson(fx, SELF, "kid");
  fx.setRuns([
    {
      id: "fake-run-id", name: "kid", parent: "%1", pane: "%9", session: child.session,
      startedAt: "2023-11-14T22:00:00Z", outcome: { result: options.outcome ?? "completed", text: "" },
    },
  ]);
  if (options.sessionFile) writeFileSync(join(fx.agentDir(SELF, "kid"), "session-file"), "/tmp/kid.json");
  return { s, child };
}

async function childSettlesSilently(fx: Fixture, childSession: string, expected: string): Promise<void> {
  const parentInbox = await fx.startInbox();
  fx.setPanes([
    agentPane({ pane: "%1", session: childSession, name: "kid" }),
    agentPane({ pane: "%2", session: SELF, name: "Self", inbox: parentInbox.path }),
  ]);
  await asSubagent(
    fx,
    childSession,
    async () => {
      const c = await startNamedSession(fx, "kid", childSession);
      await c.emit("agent_end", { messages: [{ role: "assistant", stopReason: "stop" }] });
      await c.emit("agent_settled", {}, { isIdle: () => true });
      assert.equal(parentInbox.received().length, 0, expected);
    },
    { parent: SELF, name: "kid" },
  );
}

test("a message to an ended child restarts it with the message as pi's first prompt when a session file exists", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx, { sessionFile: true });
    const result = await withEnv<{ content: { text: string }[] }>({ KIDO_FAKE_RUN_ID: "restarted-run" }, () => s.tools.get("message_agent").execute("c", { to: "kid", message: "carry on" }));

    assert.match(result.content[0].text, /^restarted kid as run restarted-run; its result arrives as a notice/);
    const argv = fx.runCalls()[1]!;
    assert.deepEqual(argv, [
      "run-child", "%1", "--name", "kid",
      "--env", `KIDO_AGENT_PARENT_SESSION=${SELF}`,
      "--env", `KIDO_AGENT_DIR=${join(fx.stateDir, "agents", SELF, "kid")}`,
      "--", "kido-pi", "--session", "/tmp/kid.json", "--name", "kid", "carry on",
    ]);
    assert.equal(agentJson(fx, SELF, "kid").run, "restarted-run", "agent.json names the new run");
    assert.equal(agentJson(fx, SELF, "kid").session, child.session, "the pi session is the same");
    await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("restarted-run")), 2000, "a run-wait for the new run");
  } finally {
    await fx.restore();
  }
});

test("a report the restarted child writes before its launch returns is not made stale by the restart", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx, { sessionFile: true });
    const dir = fx.agentDir(SELF, "kid");
    const report = join(dir, "report");
    const gate = join(fx.stateDir, "restart-gate");
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run", KIDO_FAKE_RUN_GATE: gate }, async () => {
      const sent = s.tools.get("message_agent").execute("c", { to: "kid", message: "carry on" });
      await pollUntil(() => fx.runCalls().length === 2, 3000, "the restart to reach run-child");
      writeFileSync(report, "carried on");
      const past = new Date(Date.now() - 2000);
      utimesSync(report, past, past);
      writeFileSync(gate, "");
      await sent;
      assert.equal(readFileSync(report, "utf8"), "carried on", "the early report stays readable");
      await childSettlesSilently(fx, child.session, "the early report covers the delivered work");
    });
  } finally {
    await fx.restore();
  }
});

test("without a session file the restart mints a new session under the stored id, delivers the stored task, and messages over the inbox", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx);
    const inbox = await fx.startInboxAt(fx.inboxPath(child.session));
    const result = await withEnv<{ content: { text: string }[] }>({ KIDO_FAKE_RUN_ID: "restarted-run" }, () => s.tools.get("message_agent").execute("c", { to: "kid", message: "carry on" }));

    assert.match(result.content[0].text, /^restarted kid as run restarted-run and delivered to kid by inbox/);
    const argv = fx.runCalls()[1]!;
    assert.equal(argAfter(argv, "--session-id"), child.session);
    assert.equal(argv.includes("carry on"), false, "the message is not a pi prompt here");
    assert.equal(existsSync(join(fx.agentDir(SELF, "kid"), "delivered")), false, "the stored task will be delivered again");
    const sent = JSON.parse(inbox.received()[0]!);
    assert.equal(sent.kind, "message");
    assert.equal(sent.text, "carry on");
  } finally {
    await fx.restore();
  }
});

test("a second message while the restart's inbox is not yet bound waits for it and never restarts twice", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx, { sessionFile: true });
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run" }, async () => {
      await s.tools.get("message_agent").execute("c", { to: "kid", message: "first" });
      const report = join(fx.agentDir(SELF, "kid"), "report");
      writeFileSync(report, "earlier");
      const past = new Date(Date.now() - 2000);
      utimesSync(report, past, past);
      const second = s.tools.get("message_agent").execute("c", { to: "kid", message: "second" });
      await pollUntil(() => fx.runsCalls().length >= 2, 2000, "the second message's run lookup");
      const inbox = await fx.startInboxAt(fx.inboxPath(child.session));
      assert.equal((await second).content[0].text, "delivered to kid by inbox");
      assert.equal(fx.runCalls().length, 2, "the spawn and one restart, no second run");
      assert.equal(JSON.parse(inbox.received()[0]!).text, "second");
      const work = join(fx.agentDir(SELF, "kid"), "work");
      assert.ok(existsSync(work), "a delivery on the restart path marks new work");
      assert.ok(statSync(work).mtimeMs > statSync(report).mtimeMs, "the marker is newer than the earlier report");
      assert.equal(readFileSync(report, "utf8"), "earlier");
    });
  } finally {
    await fx.restore();
  }
});

test("only the parent restarts: another parent's ended child is not found", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.writeAgent("other", "pal", { session: "pal-session" });
    const s = await startNamedSession(fx, "Self");
    assert.equal(
      (await s.tools.get("message_agent").execute("c", { to: "pal", message: "x" })).content[0].text,
      'could not message pal: no agent session matches "pal"',
    );
    assert.equal(fx.runCalls().length, 0);
  } finally {
    await fx.restore();
  }
});

test("an async_bash run cannot be messaged", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setRuns([{ id: "job-id", name: "job", parent: "%1" }]);
    const s = await startNamedSession(fx, "Self");
    assert.equal(
      (await s.tools.get("message_agent").execute("c", { to: "job", message: "x" })).content[0].text,
      "could not message job: job is a background command, not an agent; it cannot be messaged",
    );
  } finally {
    await fx.restore();
  }
});

test("a stopped child restarts on a message, because stopped is not finished", async () => {
  const fx = makeFixture();
  try {
    const { s } = await endedChild(fx, { sessionFile: true, outcome: "stopped" });
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run" }, () => s.tools.get("message_agent").execute("c", { to: "kid", message: "again" }));
    assert.equal(fx.runCalls().length, 2);
  } finally {
    await fx.restore();
  }
});



test("a restarted parent starts one run-wait per live child on its first turn", async () => {
  const fx = makeFixture();
  try {
    const gate = join(fx.stateDir, "gate");
    fx.writeAgent(SELF, "child", { session: "child-session", run: "live-child" });
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "child-session", name: "child" })]);
    // kido records every run-child as kind bash; the agent map is the only source
    // that says this run is an agent.
    fx.setRuns([{ id: "live-child", name: "child", parent: "%1", pane: "%2", session: "child-session", startedAt: "2023-11-14T22:00:00Z", output: join(fx.stateDir, "runs", "live-child", "output") }]);
    mkdirSync(join(fx.stateDir, "runs", "live-child"), { recursive: true });
    writeFileSync(join(fx.stateDir, "runs", "live-child", "output"), "line\n");
    await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "completed", text: "" }) }, async () => {
      const s = await startNamedSession(fx, "Self");
      assert.equal(fx.runWaitCalls().length, 0, "nothing is watched before the first turn");
      await s.emit("agent_start");
      await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("live-child")), 3000, "the live child to be watched");
      await s.emit("turn_start");
      assert.equal(fx.runWaitCalls().filter((call) => call.includes("live-child")).length, 1, "one run-wait per live child");
      writeFileSync(gate, "");
      await pollUntil(() => customMessages(s, "kido-notice").some((m) => String(m.message.content).includes("subagent \"child\"")), 3000, "the ending notice");
    });
  } finally {
    await fx.restore();
  }
});

test("a restarted parent watches a live bash run as a bash ending, with the output from the run row", async () => {
  const fx = makeFixture();
  try {
    const gate = join(fx.stateDir, "gate");
    const output = join(fx.stateDir, "runs", "live-bash", "output");
    mkdirSync(join(fx.stateDir, "runs", "live-bash"), { recursive: true });
    writeFileSync(output, "boom\n");
    fx.setPanes([selfPane()]);
    fx.setRuns([{ id: "live-bash", name: "build", parent: "%1", startedAt: "2023-11-14T22:00:00Z", output }]);
    await withEnv({ KIDO_FAKE_RUN_WAIT_GATE: gate, KIDO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "failed", text: "exit status 3" }) }, async () => {
      const s = await startNamedSession(fx, "Self");
      await s.emit("agent_start");
      await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("live-bash")), 3000, "the bash run to be watched");
      writeFileSync(gate, "");
      await pollUntil(() => customMessages(s, "kido-notice").length > 0, 3000, "the bash ending notice");
      const notice = String(customMessages(s, "kido-notice")[0]!.message.content);
      assert.match(notice, /async run "build" failed: exit status 3/);
      assert.ok(notice.includes(output));
      assert.match(notice, /--- output ---\nboom/);
    });
  } finally {
    await fx.restore();
  }
});

test("a child writes its pi session file into its agent directory at session_start", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    await asSubagent(fx, SELF, async () => {
      await startNamedSession(fx, "worker", SELF);
      assert.equal(readFileSync(join(fx.agentDir("boss-session", "worker"), "session-file"), "utf8"), `/tmp/${SELF}.json`);
    });
  } finally {
    await fx.restore();
  }
});

// A restarted child's old run must stay history: the live pane and its current
// run are the address, whatever order the run list comes back in.
test("after a restart the live child stays the address and its old run stays history", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx, { sessionFile: true });
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run" }, () => s.tools.get("message_agent").execute("c", { to: "kid", message: "carry on" }));
    const output = join(fx.stateDir, "runs", "restarted-run", "output");
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: child.session, name: "kid", inbox: fx.inboxPath(child.session) })]);
    fx.setRuns([
      { id: "restarted-run", name: "kid", parent: "%1", pane: "%2", session: child.session, startedAt: "2023-11-14T22:01:00Z", output },
      { id: "fake-run-id", name: "kid", parent: "%1", pane: "%2", session: child.session, startedAt: "2023-11-14T22:00:00Z", outcome: { result: "completed", text: "" } },
    ]);
    const listed = JSON.parse((await s.tools.get("list_runs").execute("c", {})).content[0].text) as Array<{ id: string; name: string; run: string; state: string }>;
    const live = listed.find((row) => row.id === child.session);
    assert.ok(live, "the live child is listed");
    assert.equal(live.state, "running", "the live child is running");
    assert.equal(live.run, "restarted-run", "the live child names its current run, not its ended one");
    const old = listed.find((row) => row.id === "fake-run-id");
    assert.equal(old?.state, "ended", "the old run stays as history");
  } finally {
    await fx.restore();
  }
});

// Two callers that both see an ended child must not restart it twice: discovery,
// restart and publication are one serialized step per child.
test("concurrent messages to an ended child restart it once", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx, { sessionFile: true });
    const gate = join(fx.stateDir, "restart-gate");
    const inbox = await fx.startInboxAt(fx.inboxPath(child.session));
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run", KIDO_FAKE_RUN_GATE: gate }, async () => {
      const first = s.tools.get("message_agent").execute("c", { to: "kid", message: "first" });
      await pollUntil(() => fx.runCalls().length === 2, 3000, "the first restart to reach run-child");
      const before = fx.runsCalls().length;
      const second = s.tools.get("message_agent").execute("c", { to: "kid", message: "second" });
      await pollUntil(() => fx.runsCalls().length > before, 2000, "the second caller's discovery before the lock");
      writeFileSync(gate, "");
      await first;
      assert.equal((await second).content[0].text, "delivered to kid by inbox");
      assert.equal(fx.runCalls().length, 2, "one restart, not two");
      assert.deepEqual(inbox.received().map((payload) => JSON.parse(payload).text), ["second"]);
    });
  } finally {
    await fx.restore();
  }
});

// A request that stalls after the receiver accepted it is uncertain, never
// retryable: a retry duplicates the message the receiver already has.
test("an inbox answer that stalls after the request was sent is not retried", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx);
    const inbox = await fx.startInboxAt(fx.inboxPath(child.session));
    const release = inbox.hold();
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run" }, async () => {
      const result = s.tools.get("message_agent").execute("c", { to: "kid", message: "once" });
      await pollUntil(() => inbox.received().length >= 1, 4000, "the request to reach the inbox");
      const text = (await result).content[0].text;
      release();
      assert.equal(inbox.received().length, 1, "the request was delivered once, not retried");
      assert.match(text, /timed out|may have arrived/, "the answer says delivery is uncertain");
    });
  } finally {
    await fx.restore();
  }
});

test("controls refuse ended reported children without creating new work or restarting", async () => {
  const fx = makeFixture();
  try {
    const { s } = await endedChild(fx);
    const dir = fx.agentDir(SELF, "kid");
    writeFileSync(join(dir, "report"), "done");
    const before = fx.runCalls().length;
    for (const mode of ["steer", "interrupt-and-steer"]) {
      const result = await s.tools.get("message_agent").execute("c", { to: "kid", message: "new work", mode });
      assert.match(result.content[0].text, /could not message kid:/);
      assert.equal(existsSync(join(dir, "work")), false, "a refused control leaves the report current");
      assert.equal(readFileSync(join(dir, "report"), "utf8"), "done");
      assert.equal(fx.runCalls().length, before, "controls never restart an ended child");
    }
  } finally {
    await fx.restore();
  }
});
