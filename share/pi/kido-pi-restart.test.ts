import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

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
  sendToInbox,
  envelope,
  type Fixture,
} from "./kido-pi-fixture.ts";

const SELF = "self-session";

type Started = Awaited<ReturnType<typeof startNamedSession>>;

function agentJson(fx: Fixture, name: string): { session: string; run: string } {
  return JSON.parse(readFileSync(join(fx.agentDir(SELF, name), "agent.json"), "utf8"));
}

// A spawned child whose first run has ended: the pane is gone and the run has an
// outcome, exactly what a restart resolves.
async function endedChild(fx: Fixture, options: { sessionFile?: boolean; outcome?: string } = {}): Promise<{ s: Started; child: { session: string; run: string } }> {
  fx.setPanes([selfPane()]);
  const s = await startNamedSession(fx, "Self");
  await s.tools.get("spawn_subagent").execute("c", { task: "do the thing", name: "kid" });
  const child = agentJson(fx, "kid");
  fx.setRuns([
    {
      id: "fake-run-id", name: "kid", kind: "agent", parent: "%1", pane: "@9.%9", session: child.session,
      startedAt: "2023-11-14T22:00:00Z", outcome: { result: options.outcome ?? "completed", text: "" },
    },
  ]);
  if (options.sessionFile) writeFileSync(join(fx.agentDir(SELF, "kid"), "session-file"), "/tmp/kid.json");
  return { s, child };
}

function argAfter(args: string[], flag: string): string | undefined {
  const at = args.indexOf(flag);
  return at >= 0 ? args[at + 1] : undefined;
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
    assert.equal(agentJson(fx, "kid").run, "restarted-run", "agent.json names the new run");
    assert.equal(agentJson(fx, "kid").session, child.session, "the pi session is the same");
    await pollUntil(() => fx.runWaitCalls().some((call) => call.includes("restarted-run")), 2000, "a run-wait for the new run");
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
      const second = s.tools.get("message_agent").execute("c", { to: "kid", message: "second" });
      await pollUntil(() => fx.runsCalls().length >= 2, 2000, "the second message's run lookup");
      const inbox = await fx.startInboxAt(fx.inboxPath(child.session));
      assert.equal((await second).content[0].text, "delivered to kid by inbox");
      assert.equal(fx.runCalls().length, 2, "the spawn and one restart, no second run");
      assert.equal(JSON.parse(inbox.received()[0]!).text, "second");
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
    fx.setRuns([{ id: "job-id", name: "job", kind: "bash", parent: "%1" }]);
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

test("ask_agent restarts an ended child, waits for its new inbox, and takes the reply", async () => {
  const fx = makeFixture();
  try {
    const { s, child } = await endedChild(fx);
    const inbox = await fx.startInboxAt(fx.inboxPath(child.session));
    await withEnv({ KIDO_FAKE_RUN_ID: "restarted-run" }, async () => {
      const asked = s.tools.get("ask_agent").execute("c", { to: "kid", question: "status?" });
      await pollUntil(() => inbox.received().length === 1, 3000, "the ask to the restarted child");
      const ask = JSON.parse(inbox.received()[0]!);
      assert.equal(ask.kind, "ask");
      assert.equal(ask.text, "status?");
      assert.equal(argAfter(fx.runCalls()[1]!, "--session-id"), child.session, "ask restarts, then asks over the inbox");
      await sendToInbox(s.inboxPath, envelope("reply", "fine", { replyTo: ask.id, from: ask.from }));
      assert.equal((await asked).content[0].text, "fine");
    });
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
    fx.setRuns([{ id: "live-child", name: "child", kind: "bash", parent: "%1", pane: "%2", session: "child-session", startedAt: "2023-11-14T22:00:00Z", output: join(fx.stateDir, "runs", "live-child", "output") }]);
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
    fx.setRuns([{ id: "live-bash", name: "build", kind: "bash", parent: "%1", startedAt: "2023-11-14T22:00:00Z", output }]);
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

test("the spawn and notify_parent descriptions say message it, never resume", async () => {
  const fx = makeFixture();
  try {
    const s = await startNamedSession(fx, "Self");
    const spawn = s.tools.get("spawn_subagent").description as string;
    const notify = s.tools.get("notify_parent").description as string;
    assert.match(spawn, /message it/);
    assert.doesNotMatch(spawn, /resume/);
    assert.doesNotMatch(notify, /resume/);
    assert.match(notify, /message_agent/);
  } finally {
    await fx.restore();
  }
});
