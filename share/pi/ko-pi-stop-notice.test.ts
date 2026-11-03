import { test } from "node:test";

import assert from "node:assert/strict";

import { existsSync, readFileSync, writeFileSync } from "node:fs";

import { join } from "node:path";

import { makeFixture, selfPane, agentPane, startNamedSession, withEnv, pollUntil, notices, agentJson, type Fixture } from "./ko-pi-fixture.ts";

type Session = Awaited<ReturnType<typeof startNamedSession>>;

const STOPPED = JSON.stringify({ result: "stopped", text: "" });

// Starts a run whose run-wait prints its answer only once release is called.
// closed resolves after the waiter process is gone and its close event ran.
async function startRun(
  fx: Fixture,
  s: Session,
  kind: "bash" | "agent",
  name: string,
  extra: Record<string, string> = {},
): Promise<{ run: string; output: string; release: () => void; closed: () => Promise<void> }> {
  const run = `run-0123456-${name}`;
  const gate = join(fx.stateDir, `gate-${name}`);
  const ready = join(fx.stateDir, `ready-${name}`);
  await withEnv({ KO_FAKE_RUN_ID: run, KO_FAKE_RUN_WAIT_GATE: gate, KO_FAKE_RUN_WAIT_READY: ready, ...extra }, () =>
    kind === "bash" ? s.tools.get("async_bash").execute("c", { command: "make", name }) : s.tools.get("spawn_agent").execute("c", { task: "x", name }),
  );
  await pollUntil(() => fx.runWaitCalls().some((call) => call.includes(run)), 3000, `run-wait of ${run}`);
  return {
    run,
    output: join(fx.stateDir, "runs", run, "output"),
    release: () => writeFileSync(gate, ""),
    closed: async () => {
      await pollUntil(() => existsSync(ready), 3000, `run-wait of ${run} to answer`);
      const pid = Number(readFileSync(ready, "utf8"));
      await pollUntil(() => {
        try {
          process.kill(pid, 0);
          return false;
        } catch {
          return true;
        }
      }, 3000, `run-wait of ${run} to exit`);
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

test("a caller's own stop of async_bash runs sends no ending notice, in every address form; a run that stopped another way still does", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const byId = await startRun(fx, s, "bash", "byid");
    const byName = await startRun(fx, s, "bash", "byname");
    const byMention = await startRun(fx, s, "bash", "bymention");
    const byPrefix = await startRun(fx, s, "bash", "byprefix");
    const other = await startRun(fx, s, "bash", "other", { KO_FAKE_RUN_WAIT_OUTCOME: STOPPED });

    const single = await s.tools.get("stop_run").execute("c", { to: byId.run });
    assert.equal(single.content[0].text, `stopped run ${byId.run}; killed its pane; output: ${byId.output}`);
    const many = await s.tools.get("stop_run").execute("c", { to: ["byname", `@bymention (run ${byMention.run})`, byPrefix.run.slice(0, -1), byPrefix.run] });
    assert.deepEqual(many.content[0].text.split("\n"), [
      `stopped run ${byName.run}; killed its pane; output: ${byName.output}`,
      `stopped run ${byMention.run}; killed its pane; output: ${byMention.output}`,
      `stopped run ${byPrefix.run}; killed its pane; output: ${byPrefix.output}`,
      `stopped run ${byPrefix.run}; killed its pane; output: ${byPrefix.output}`,
    ]);
    assert.equal(fx.runStopCalls().length, 4, "a duplicate address stops its run once");

    for (const run of [byId, byName, byMention, byPrefix]) {
      run.release();
      await run.closed();
    }
    assert.deepEqual(notices(s), [], "no stopped run sent a notice");
    other.release();
    await pollUntil(() => notices(s).length === 1, 3000, "the other run's ending notice");
    assert.match(notices(s)[0]!, /\nasync run "other" stopped/);
  } finally {
    await fx.restore();
  }
});

test("a caller's own stop of subagent runs sends no ending notice and the result gives each outcome and report path", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const first = await startRun(fx, s, "agent", "kid1");
    const second = await startRun(fx, s, "agent", "kid2");
    const third = await startRun(fx, s, "agent", "kid3");
    const other = await startRun(fx, s, "agent", "kid4", { KO_FAKE_RUN_WAIT_OUTCOME: STOPPED });
    const report = join(fx.agentDir("self-session", "kid2"), "report");
    writeFileSync(report, "done");
    const session = agentJson(fx, "self-session", "kid3").session;
    fx.setPanes([selfPane(), agentPane({ pane: "pane_9", session, name: "kid3", inbox: inbox.path })]);

    const single = await s.tools.get("stop_run").execute("c", { to: first.run, force: true });
    assert.equal(single.content[0].text, `stopped kid1; stopped run ${first.run}; killed its pane`);
    const viaInbox = await s.tools.get("stop_run").execute("c", { to: session });
    assert.equal(viaInbox.content[0].text, `stopped kid3; stopped run ${third.run}; killed its pane`);
    assert.equal(JSON.parse(inbox.received()[0]!).kind, "stop", "a stop without force asks over the inbox");
    const many = await s.tools.get("stop_run").execute("c", { to: ["kid2", second.run], force: true });
    assert.deepEqual(many.content[0].text.split("\n"), [
      `completed kid2; stopped run ${second.run}; killed its pane; report: ${report}`,
      `completed kid2; stopped run ${second.run}; killed its pane; report: ${report}`,
    ]);

    for (const run of [first, second, third]) {
      run.release();
      await run.closed();
    }
    assert.deepEqual(notices(s), [], "no stopped subagent sent a notice");
    other.release();
    await pollUntil(() => notices(s).length === 1, 3000, "the other subagent's ending notice");
    assert.match(notices(s)[0]!, /\nsubagent "kid4" stopped/);
  } finally {
    await fx.restore();
  }
});

test("a run that ended on its own before stop_run: the result reports it and the pending notice is not also sent", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const bash = await startRun(fx, s, "bash", "build");
    const agent = await startRun(fx, s, "agent", "kid");
    const report = join(fx.agentDir("self-session", "kid"), "report");
    writeFileSync(report, "done");
    fx.setRuns([
      { id: bash.run, name: "build", parent: "pane_1", output: bash.output, outcome: { result: "failed", text: "exit status 3" } },
      { id: agent.run, name: "kid", parent: "pane_1", session: agentJson(fx, "self-session", "kid").session, outcome: { result: "completed", text: "" } },
    ]);

    const result = await s.tools.get("stop_run").execute("c", { to: [bash.run, agent.run] });
    assert.equal(result.isError, true);
    assert.deepEqual(result.content[0].text.split("\n"), [
      `"${bash.run}": error: run ${bash.run} has already ended failed: exit status 3; output: ${bash.output}`,
      `"${agent.run}": error: run ${agent.run} has already ended completed; report: ${report}`,
    ]);
    assert.deepEqual(fx.runStopCalls(), []);

    for (const run of [bash, agent]) {
      run.release();
      await run.closed();
    }
    assert.deepEqual(notices(s), [], "the result was the one signal");
  } finally {
    await fx.restore();
  }
});

test("a run whose notice came before stop_run is reported ended by the result without a second notice", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const bash = await startRun(fx, s, "bash", "build", { KO_FAKE_RUN_WAIT_OUTCOME: JSON.stringify({ result: "failed", text: "exit status 3" }) });
    fx.setRuns([{ id: bash.run, name: "build", parent: "pane_1", output: bash.output, outcome: { result: "failed", text: "exit status 3" } }]);
    bash.release();
    await pollUntil(() => notices(s).length === 1, 3000, "the ending notice");

    const result = await s.tools.get("stop_run").execute("c", { to: bash.run });
    assert.equal(result.content[0].text, `"${bash.run}": error: run ${bash.run} has already ended failed: exit status 3; output: ${bash.output}`);
    assert.equal(notices(s).length, 1);
  } finally {
    await fx.restore();
  }
});

test("a run that ends on its own while stop_run is stopping it: the result reports the real outcome and no notice follows", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const bash = await startRun(fx, s, "bash", "build");
    const agent = await startRun(fx, s, "agent", "kid");
    const stopGate = join(fx.stateDir, "stop-gate");
    const outcomeGate = join(fx.stateDir, "outcome-gate");
    const report = join(fx.agentDir("self-session", "kid"), "report");
    writeFileSync(report, "done");

    const stopped = await withEnv({ KO_FAKE_RUN_STOP_GATE: stopGate, KO_FAKE_RUN_OUTCOME_GATE: outcomeGate }, async () => {
      const pending = s.tools.get("stop_run").execute("c", { to: ["build", "kid"], force: true });
      await pollUntil(() => fx.runStopCalls().length === 1 && fx.runOutcomeCalls().length === 1, 3000, "both stops to be under way");
      fx.setRuns([
        { id: bash.run, name: "build", parent: "pane_1", output: bash.output, dead: true, outcome: { result: "completed", text: "" } },
        { id: agent.run, name: "kid", parent: "pane_1", session: agentJson(fx, "self-session", "kid").session, outcome: { result: "failed", text: "exit 2" } },
      ]);
      writeFileSync(stopGate, "");
      writeFileSync(outcomeGate, "");
      return pending;
    });
    assert.equal(stopped.isError, true);
    assert.deepEqual(stopped.content[0].text.split("\n"), [
      `"build": error: run ${bash.run} has already ended completed; output: ${bash.output}`,
      `"kid": error: run ${agent.run} has already ended failed: exit 2; report: ${report}`,
    ]);

    for (const run of [bash, agent]) {
      run.release();
      await run.closed();
    }
    assert.deepEqual(notices(s), [], "the result was the one signal");
  } finally {
    await fx.restore();
  }
});

test("a stop that fails after the run ended reports the ending in its line; one that fails before the ending leaves the notice", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const ending = JSON.stringify({ result: "failed", text: "exit status 2" });
    const closed = await startRun(fx, s, "bash", "closed", { KO_FAKE_RUN_WAIT_OUTCOME: ending });
    const open = await startRun(fx, s, "bash", "open", { KO_FAKE_RUN_WAIT_OUTCOME: ending });
    const stopGate = join(fx.stateDir, "stop-gate");

    const first = await withEnv({ KO_FAKE_RUN_STOP_GATE: stopGate }, async () => {
      const pending = s.tools.get("stop_run").execute("c", { to: closed.run });
      await pollUntil(() => fx.runStopCalls().length === 1, 3000, "the stop to be under way");
      fx.setRuns([]);
      closed.release();
      await closed.closed();
      writeFileSync(stopGate, "");
      return pending;
    });
    assert.equal(first.content[0].text, `"${closed.run}": error: run ${closed.run}: no such run; run ${closed.run} has already ended failed: exit status 2; output: ${closed.output}`);
    assert.deepEqual(notices(s), [], "the failed stop carried the ending");

    const stopGate2 = join(fx.stateDir, "stop-gate-2");
    fx.setRuns([{ id: open.run, name: "open", parent: "pane_1", output: open.output }]);
    const second = await withEnv({ KO_FAKE_RUN_STOP_GATE: stopGate2 }, async () => {
      const pending = s.tools.get("stop_run").execute("c", { to: open.run });
      await pollUntil(() => fx.runStopCalls().length === 2, 3000, "the second stop to be under way");
      fx.setRuns([]);
      writeFileSync(stopGate2, "");
      return pending;
    });
    assert.equal(second.content[0].text, `"${open.run}": error: run ${open.run}: no such run`);
    open.release();
    await pollUntil(() => notices(s).length === 1, 3000, "the notice of the run whose stop failed");
    assert.match(notices(s)[0]!, /\nasync run "open" failed: exit status 2/);
  } finally {
    await fx.restore();
  }
});
