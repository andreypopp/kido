import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { agentJson, agentPane, argAfter, asSubagent, customMessages, fakeCtx, idleTurn, makeFixture, pollUntil, savedSession, selfPane, startNamedSession, withEnv } from "./kido-pi-fixture.ts";

const SELF = "self-session";

test("spawn_agent scans saved session names, continues or copies them, and refuses unsafe sources and cwd", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const sessions = join(fx.stateDir, "sessions", "saved");
    const cwd = join(fx.stateDir, "project");
    mkdirSync(cwd);
    const ids = ["abcdef00111111111111111111111111", "abcdef00222222222222222222222222"];
    const paths = ids.map((id) => savedSession(sessions, cwd, id));
    const original = readFileSync(paths[0]!, "utf8");
    fx.writeAgent("old-parent", "old-child", { session: ids[0]! });
    const s = await startNamedSession(fx, "Self");
    const spawn = s.tools.get("spawn_agent");
    const continued = await spawn.execute("c", { name: "continued", task: "", resume_from: ids[0]!.slice(0, 10), cwd });
    assert.equal(continued.details?.session, ids[0]);
    assert.equal(existsSync(join(fx.agentDir("old-parent", "old-child"), "agent.json")), false);
    assert.equal(existsSync(fx.agentDir("old-parent", "old-child")), true);
    const argv = fx.runCalls().at(-1)!;
    assert.equal(argAfter(argv, "--session"), paths[0]);
    assert.equal(argAfter(argv, "--session-id"), undefined);
    assert.equal(argAfter(argv, "--cwd"), cwd);
    assert.equal(argv.at(-1), "acme/caller:high");
    assert.equal(existsSync(join(fx.agentDir(SELF, "continued"), "work")), false);
    assert.equal(readFileSync(join(fx.agentDir(SELF, "continued"), "task"), "utf8"), "");
    assert.equal(readFileSync(join(fx.agentDir(SELF, "continued"), "session-file"), "utf8"), paths[0]);
    fx.setRuns([{ id: "fake-run-id", name: "continued", parent: "%1", outcome: { result: "completed", text: "" } }]);
    await pollUntil(() => customMessages(s, "kido-notice").length > 0, 3000, "the empty resume's ending notice");
    assert.match(String(customMessages(s, "kido-notice")[0]!.message.content), /no report was owed/);
    const copied = await spawn.execute("c", { name: "copy", task: "@review", resume_from: ids[0], fork: true, cwd: fx.stateDir });
    assert.notEqual(copied.details?.session, ids[0]);
    assert.equal(argAfter(fx.runCalls().at(-1)!, "--fork"), paths[0]);
    assert.equal(argAfter(fx.runCalls().at(-1)!, "--cwd"), fx.stateDir);
    assert.equal(readFileSync(paths[0]!, "utf8"), original);
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: ids[1]!, name: "live" })]);
    for (const [resume_from, expected] of [[ids[1], /is live in a pane/], ["missing-session", /unknown session/], ["abcdef00", /(?=.*abcdef001)(?=.*abcdef002).*matches several sessions by id/], ["abcdef0", /prefixes need at least 8 characters/]] as const) {
      assert.match((await spawn.execute("c", { name: "bad", task: "x", resume_from })).content[0].text, expected);
    }
    const before = fx.runCalls().length;
    for (const params of [{ task: "" }, { task: "", resume_from: ids[0], fork: true }, { task: "x", cwd: join(cwd, "missing") }, { task: "x", cwd: paths[0] }]) {
      assert.match((await spawn.execute("c", { name: "bad", ...params })).content[0].text, /task is required|cwd is not a directory/);
    }
    assert.equal(fx.runCalls().length, before);
    const noModel = await spawn.execute("c", { name: "no-model", task: "x" }, undefined, undefined, { ...fakeCtx(), model: undefined });
    assert.match(noModel.content[0].text, /caller has no model; specify model/);
  } finally { await fx.restore(); }
});

test("continuing requires its recorded cwd, while a copy can use another directory", async () => {
  const fx = makeFixture();
  try {
    const cwd = join(fx.stateDir, "recorded");
    mkdirSync(cwd);
    const id = "f00dba5e111111111111111111111111";
    savedSession(join(fx.stateDir, "sessions", "saved"), cwd, id);
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const spawn = s.tools.get("spawn_agent");
    assert.match((await spawn.execute("c", { name: "bad", task: "x", resume_from: id, cwd: fx.stateDir })).content[0].text, /a continued session runs in its recorded directory.*fork copies it into another/);
    assert.equal(fx.runCalls().length, 0);
    const copy = await spawn.execute("c", { name: "copy", task: "x", resume_from: id, fork: true, cwd: fx.stateDir });
    assert.ok(copy.details?.session);
    assert.equal(argAfter(fx.runCalls()[0]!, "--cwd"), fx.stateDir);
    rmSync(cwd, { recursive: true });
    assert.match((await spawn.execute("c", { name: "gone", task: "x", resume_from: id })).content[0].text, /cwd is not a directory/);
    assert.equal(fx.runCalls().length, 1);
  } finally { await fx.restore(); }
});

test("an empty resumed task owes no report, even after a later unrelated turn", async () => {
  const fx = makeFixture();
  try {
    fx.writeAgent("boss", "kid", { session: SELF, run: "child-run" });
    const dir = fx.agentDir("boss", "kid");
    writeFileSync(join(dir, "task"), " \n ");
    writeFileSync(join(dir, "delivered"), "");
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane({ kido_name: "kid" }), agentPane({ pane: "%2", session: "boss", name: "boss", inbox: inbox.path })]);
    await asSubagent(fx, SELF, async () => {
      const s = await startNamedSession(fx, "kid");
      assert.deepEqual(s.delivered, []);
      await idleTurn(s, "unrelated turn");
      assert.equal(existsSync(join(dir, "report")), false, "no work means no report obligation");
      assert.deepEqual(inbox.received(), []);
      await s.emit("message_start", { message: { details: { work: true } } });
      await idleTurn(s, "new work done");
      assert.equal(readFileSync(join(dir, "report"), "utf8"), "new work done");
    }, { parent: "boss", name: "kid", run: "child-run" });
  } finally { await fx.restore(); }
});

test("a resumed ended child uses the restart path and a task file, never pi argv", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const id = "12345678111111111111111111111111";
    const path = savedSession(join(fx.stateDir, "sessions", "saved"), fx.stateDir, id);
    fx.writeAgent(SELF, "kid", { session: id, run: "old-run" });
    const childDir = fx.agentDir(SELF, "kid");
    writeFileSync(join(childDir, "report"), "old result");
    writeFileSync(join(childDir, "work"), "");
    fx.setRuns([{ id: "old-run", name: "kid", parent: "%1", outcome: { result: "completed", text: "" } }]);
    await withEnv({ KIDO_FAKE_RUN_ID: "new-run" }, async () => {
      const s = await startNamedSession(fx, "Self");
      const result = await s.tools.get("spawn_agent").execute("c", { task: "@continue", name: "kid", resume_from: id });
      assert.equal(result.details?.run, "new-run");
      assert.equal(result.details?.pane, "%9");
      assert.equal(result.details?.window, "@9");
      assert.equal(agentJson(fx, SELF, "kid").run, "new-run");
      assert.equal(agentJson(fx, SELF, "kid").model, "acme/caller:high");
      assert.equal(existsSync(join(childDir, "report")), false);
      assert.equal(existsSync(join(childDir, "work")), false);
      assert.equal(existsSync(join(childDir, "delivered")), false);
      assert.equal(readFileSync(join(childDir, "task"), "utf8"), "@continue");
      assert.equal(argAfter(fx.runCalls().at(-1)!, "--session"), path);
      assert.equal(fx.runCalls().at(-1)!.includes("@continue"), false);
      await pollUntil(() => fx.runWaitCalls().some((a) => a.includes("new-run")), 3000, "the restarted run's watcher");
    });
  } finally { await fx.restore(); }
});

test("toplevel holds its name until publication, sends @ tasks by inbox, and stays a peer", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const s = await startNamedSession(fx, "Self");
    const spawned = s.tools.get("spawn_agent").execute("c", { name: "peer", task: "@work", toplevel: true, fork: true, cwd: fx.stateDir });
    let returned = false;
    void spawned.then(() => { returned = true; });
    await pollUntil(() => fx.runCalls().length === 1, 3000, "the independent run");
    assert.equal(returned, false, "wait for the pane to publish its identity and inbox");
    assert.match((await s.tools.get("spawn_agent").execute("c", { name: "PEER", task: "x", toplevel: true })).content[0].text, /taken by a live agent in this tmux session/);
    const argv = fx.runCalls()[0]!;
    const session = argAfter(argv, "--session-id")!;
    const inbox = await fx.startInbox();
    fx.setPanes([selfPane(), agentPane({ pane: "%9", session, name: "peer", inbox: inbox.path })]);
    const result = await spawned;
    assert.match(result.content[0].text, /independent peer; no report or ending notice/);
    assert.equal(argv[0], "run");
    assert.equal(argAfter(argv, "--session"), "$1");
    assert.equal(argAfter(argv, "--cwd"), fx.stateDir);
    assert.equal(argAfter(argv, "--env"), undefined);
    assert.equal(argAfter(argv, "--fork"), `/tmp/${SELF}.json`);
    assert.equal(argv.includes("@work"), false);
    assert.equal(JSON.parse(inbox.received()[0]!).text, "@work");
    assert.equal(existsSync(fx.agentDir(SELF, "peer")), false);
    await s.emit("turn_start");
    assert.deepEqual(fx.runWaitCalls(), []);
    assert.deepEqual(customMessages(s, "kido-notice"), []);
    const listed = JSON.parse((await s.tools.get("list_runs").execute("c", {})).content[0].text);
    assert.equal(listed.some((r: { id: string; relationship: string }) => r.id === session && r.relationship === "peer"), true);
    assert.match((await s.tools.get("stop_run").execute("c", { to: session })).content[0].text, /no run matches/);
    for (const mode of ["steer", "interrupt-and-steer"]) assert.match((await s.tools.get("message_agent").execute("c", { to: session, message: "change", mode })).content[0].text, /descendant/);
    assert.match((await s.tools.get("message_agent").execute("c", { to: "peer", message: "hello" })).content[0].text, /delivered to peer by inbox/);
    assert.match((await s.tools.get("spawn_agent").execute("c", { name: "PEER", task: "x", toplevel: true })).content[0].text, /already taken/);
    assert.equal(fx.runCalls().length, 1);
    await asSubagent(fx, "worker-session", async () => {
      fx.setPanes([agentPane({ pane: "%1", session: "worker-session", name: "worker" }), agentPane({ pane: "%2", session: "boss", name: "boss" }), agentPane({ pane: "%9", session, name: "peer", inbox: inbox.path })]);
      const child = await startNamedSession(fx, "worker", "worker-session");
      const rows = JSON.parse((await child.tools.get("list_runs").execute("c", {})).content[0].text);
      assert.equal(rows.some((r: { id: string }) => r.id === session), false);
      assert.match((await child.tools.get("message_agent").execute("c", { to: session, message: "hello from child" })).content[0].text, /delivered to peer by inbox/);
    }, { parent: "boss", name: "worker" });
    const saved = "deadbeef111111111111111111111111";
    savedSession(join(fx.stateDir, "sessions", "saved"), fx.stateDir, saved);
    fx.writeAgent("old-boss", "saved", { session: saved });
    fx.setPanes([selfPane()]);
    await withEnv({ KIDO_FAKE_RUN_ID: "resumed-top" }, async () => {
      const pending = s.tools.get("spawn_agent").execute("c", { task: "", name: "saved", resume_from: saved, toplevel: true });
      let done = false;
      void pending.then(() => { done = true; });
      await pollUntil(() => fx.runCalls().length === 2, 3000, "the continued independent run");
      assert.equal(done, false, "an empty task also waits for publication");
      fx.setPanes([selfPane(), agentPane({ pane: "%8", session: saved, name: "saved", inbox: inbox.path })]);
      const resumed = await pending;
      assert.equal(resumed.details?.session, saved);
      assert.equal(fx.runCalls().at(-1)![0], "run");
      assert.equal(existsSync(join(fx.agentDir("old-boss", "saved"), "agent.json")), false);
      assert.equal(existsSync(fx.agentDir(SELF, "saved")), false);
    });
  } finally { await fx.restore(); }
});

test("continuing the caller or an ancestor as its child refuses the cycle before any write", async () => {
  const fx = makeFixture();
  try {
    const ancestor = "ancestor-session";
    savedSession(join(fx.stateDir, "sessions", "saved"), fx.stateDir, ancestor);
    savedSession(join(fx.stateDir, "sessions", "saved"), fx.stateDir, SELF);
    fx.setPanes([selfPane()]);
    await asSubagent(fx, SELF, async () => {
      const s = await startNamedSession(fx, "kid");
      for (const resume_from of [ancestor, SELF]) {
        const result = await s.tools.get("spawn_agent").execute("c", { task: "x", name: "cycle", resume_from });
        assert.match(result.content[0].text, /is an ancestor of this session/);
        assert.equal(existsSync(fx.agentDir(SELF, "cycle")), false);
      }
      assert.equal(fx.runCalls().length, 0);
    }, { parent: ancestor, name: "kid" });
  } finally { await fx.restore(); }
});

test("continue refuses a live session with its root cleared, but permits a dead marked pane", async () => {
  const fx = makeFixture();
  try {
    const id = "c1ea4ed0111111111111111111111111";
    savedSession(join(fx.stateDir, "sessions", "saved"), fx.stateDir, id);
    const marked = agentPane({ pane: "%2", session: id, name: "saved", inbox: "/tmp/stale-inbox.sock" });
    fx.setPanes([selfPane(), { ...marked, pane_program_status: "" }]);
    const s = await startNamedSession(fx, "Self");
    const spawn = s.tools.get("spawn_agent");
    const refused = await spawn.execute("c", { task: "x", name: "continued", resume_from: id });
    assert.match(refused.content[0].text, /is live in a pane/);
    assert.equal(fx.runCalls().length, 0);
    fx.writeAgent(SELF, "continued", { session: id, run: "old-run" });
    fx.setRuns([{ id: "old-run", name: "continued", parent: "%1", pane: "%2", outcome: { result: "completed", text: "" } }]);
    fx.setPanes([selfPane(), { ...marked, pane_dead: "1" }]);
    const continued = await spawn.execute("c", { task: "x", name: "continued", resume_from: id });
    assert.equal(continued.details?.session, id, continued.content[0].text);
    assert.equal(fx.runCalls().length, 1);
  } finally { await fx.restore(); }
});
