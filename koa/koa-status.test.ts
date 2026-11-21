import { test } from "node:test";
import assert from "node:assert/strict";
import { createPublisher, deriveRecords } from "./koa-status.ts";
import type { Agent } from "./koa-agents.ts";
import type { BackgroundJob } from "./koa-agent.ts";
import type { Reply } from "./runtime-exec.ts";
import { stubAgent, at } from "./koa-agent-fixture.ts";

test("a failed parent publication never publishes a job alone and a lost response is retried", async () => {
  const revisions: string[][] = [];
  let jobs = false;
  let posts = 0, serial = 0;
  let committed = "";
  const serials: number[] = [];
  const logs: string[] = [];
  const publisher = createPublisher({
    active: true, pane: "pane_1",
    derive: () => ({ type: "replace_subtrees", roots: ["agents", "jobs"], records: [
      { id: "agents/a", state: "working" },
      ...(jobs ? [{ id: "agents/a/jobs/b", state: "working" as const }] : []),
    ] }),
    log: message => logs.push(message),
    retry: async () => { jobs = true; publisher.changed(); },
    transport: async (method, path, body): Promise<Reply> => {
      if (path === "/version") return { status: 200, body: JSON.stringify({ status_record_limit: 64 }) };
      if (method === "GET") return { status: 200, body: JSON.stringify({ status: { program_status: { records: [] } } }) };
      assert.equal(body?.type, "replace_subtrees");
      const ids = body?.records.map(record => record.id) ?? [];
      for (const id of ids) if (id.includes("/jobs/")) assert.ok(ids.includes(id.slice(0, id.indexOf("/jobs/"))));
      posts++;
      if (posts === 1) return { error: "parent write failed" };
      revisions.push(ids);
      const canonical = JSON.stringify(body);
      if (canonical !== committed) { committed = canonical; serial++; }
      serials.push(serial);
      if (posts === 2) return { error: "response lost after apply" };
      return { status: 200, body: "{}" };
    },
  });
  publisher.changed();
  assert.equal(await publisher.drain(), true);
  assert.ok(revisions.length >= 2);
  assert.ok(revisions.every(ids => ids.includes("agents/a")));
  assert.deepEqual(serials, [1, 1]);
  assert.ok(logs.some(message => message.includes("response lost")));
});

test("a lost response cannot suppress a return to the acknowledged empty tree", async () => {
  let live = false;
  let committed: string[] = [];
  const sent: string[][] = [];
  const applied = Promise.withResolvers<void>(), lost = Promise.withResolvers<void>();
  const publisher = createPublisher({ active: true, pane: "pane_1", log: () => {}, derive: () => ({ type: "replace_subtrees", roots: ["agents", "jobs"], records: live ? [{ id: "agents/a", state: "working" }] : [] }), transport: async (method, path, body) => {
    if (path === "/version") return { status: 200, body: JSON.stringify({ status_record_limit: 64 }) };
    if (method === "GET") return { status: 200, body: "{}" };
    committed = body?.records.map(record => record.id) ?? [];
    sent.push(committed);
    if (committed.length) { applied.resolve(); await lost.promise; return { error: "response lost after commit" }; }
    return { status: 200, body: "{}" };
  } });
  publisher.changed(); assert.equal(await publisher.drain(), true);
  live = true; publisher.changed(); await applied.promise;
  live = false; publisher.changed(); lost.resolve();
  assert.equal(await publisher.drain(), true);
  assert.deepEqual(committed, []);
  assert.deepEqual(sent, [[], ["agents/a"], []]);
});

test("changes coalesce while a request is gated and supersede its failed retry", async () => {
  let name = "a";
  const sent: string[] = [];
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  const publisher = createPublisher({ active: true, pane: "pane_1", log: () => {}, derive: () => ({ type: "replace_subtrees", roots: ["agents", "jobs"], records: [{ id: `jobs/${name}`, state: "working" }] }), transport: async (method, path, body) => {
    if (path === "/version") return { status: 200, body: JSON.stringify({ status_record_limit: 64 }) };
    if (method === "GET") return { status: 200, body: "{}" };
    const id = body?.records.at(0)?.id;
    assert.ok(id); sent.push(id);
    if (sent.length === 1) { entered.resolve(); await release.promise; return { error: "lost" }; }
    return { status: 200, body: "{}" };
  } });
  publisher.changed(); await entered.promise;
  name = "b"; publisher.changed(); name = "c"; publisher.changed();
  release.resolve();
  assert.equal(await publisher.drain(), true);
  assert.deepEqual(sent, ["jobs/a", "jobs/c"]);
});

test("capacity refusal refreshes preserved records and inactive mode makes no calls", async () => {
  const budgets: number[] = [];
  let outside = 1, posts = 0, calls = 0;
  let live = false;
  const publisher = createPublisher({ active: true, pane: "pane_1", retry: async () => {}, log: () => {}, derive: budget => { budgets.push(budget); return { type: "replace_subtrees", roots: ["agents", "jobs"], records: live ? [{ id: "jobs/a", state: "working" }] : [] }; }, transport: async (method, path) => {
    calls++;
    if (path === "/version") return { status: 200, body: JSON.stringify({ status_record_limit: 4 }) };
    if (method === "GET") return { status: 200, body: JSON.stringify({ status: { program_status: { records: Array.from({ length: outside }, (_, id) => ({ id: `outside/${id}` })) } } }) };
    posts++;
    if (posts === 1) { outside++; return { status: 409, body: "capacity" }; }
    return { status: 200, body: "{}" };
  } });
  publisher.changed(); assert.equal(await publisher.drain(), true);
  const before = calls;
  publisher.changed(); assert.equal(await publisher.drain(), true);
  assert.equal(calls, before, "an unchanged projection makes no requests");
  outside = 0; live = true; publisher.changed(); assert.equal(await publisher.drain(), true);
  assert.deepEqual(budgets.slice(0, 2), [2, 1]);
  assert.equal(budgets.at(-1), 3, "a changed projection refreshes the preserved capacity");
  const reconciled = calls;
  publisher.changed(true); assert.equal(await publisher.drain(), true);
  assert.equal(calls, reconciled + 2, "forced reconciliation reads and posts an equal body");
  const inactive = createPublisher({ active: false, pane: "", derive: () => { throw Error("inactive derivation"); }, transport: async () => { throw Error("inactive request"); } });
  inactive.changed(); assert.equal(await inactive.drain(), true); inactive.close();
});

function member(name: string, parent?: Agent): Agent {
  const agent = stubAgent({ name, parent, children: [], stopping: false, view: { life: { type: "ready" }, state: { dialogs: [] }, root: { value: "done", message: name } }, host: { jobs: { selectable: true, registry: { jobs: new Map<string, BackgroundJob>() } } } });
  parent?.children.push(agent);
  return agent;
}

function job(agent: Agent, id: string, at?: number, watched = false): void {
  agent.host.jobs.registry.jobs.set(id, Object.assign(Object.create(null), { id, command: id, state: at === undefined ? { type: "running" } : { type: "ended", at, end: { type: "exit", code: 0 } }, mode: { type: "job", name: id, origin: { type: "async_bash", service: false }, retention: { type: watched || at === undefined ? "retained" : "lingering" } } }));
}

function closedTree(ids: string[]): void {
  assert.equal(new Set(ids).size, ids.length);
  assert.ok(!ids.includes(""));
  for (const id of ids) {
    const parts = id.split("/");
    for (let at = 2; at < parts.length; at += 2) assert.ok(ids.includes(parts.slice(0, at).join("/")), id);
  }
}

test("shared budgets omit finished leaves first and keep complete ancestor chains", () => {
  const root = member("");
  const a = member("a", root), nested = member("b", a), c = member("c", root);
  job(a, "old", 1); job(c, "new", 2); job(root, "live"); job(nested, "watched", 3, true);
  const selection = { type: "agent" as const, agent: root };
  const full = deriveRecords(root, selection, 20);
  assert.equal(full.records.length, 7);
  for (let budget = 0; budget <= 7; budget++) {
    const body = deriveRecords(root, selection, budget);
    assert.ok(body.records.length <= budget);
    closedTree(body.records.map(record => record.id));
  }
  assert.ok(!deriveRecords(root, selection, 6).records.some(record => record.id === "agents/a/jobs/old"));
  assert.deepEqual(deriveRecords(root, selection, 2).records.map(record => record.id), ["agents/a", "agents/a/agents/b"]);
  assert.ok(deriveRecords(root, selection, 4).records.some(record => record.id === "jobs/live"));
});

test("stop marking excludes a whole subtree before teardown and late job endings cannot restore it", () => {
  const root = member(""), child = member("a", root), grandchild = member("b", child);
  job(grandchild, "build");
  const selection = { type: "agent" as const, agent: root };
  const revisions = [deriveRecords(root, selection, 20)];
  child.stopping = true;
  revisions.push(deriveRecords(root, selection, 20));
  job(grandchild, "build", 3);
  revisions.push(deriveRecords(root, selection, 20));
  assert.ok(at(revisions, 0).records.some(record => record.id.endsWith("jobs/build")));
  for (const body of revisions.slice(1)) assert.deepEqual(body.records, []);
  for (const body of revisions) closedTree(body.records.map(record => record.id));
});

test("report state does not remove a live member and the next turn changes the same record", () => {
  const root = member(""), child = member("a", root);
  job(child, "build");
  const selection = { type: "agent" as const, agent: root };
  const revisions = [deriveRecords(root, selection, 20)];
  child.view.root.value = "working";
  revisions.push(deriveRecords(root, selection, 20));
  child.view.root.value = "done";
  revisions.push(deriveRecords(root, selection, 20));
  assert.deepEqual(revisions.map(body => body.records.find(record => record.id === "agents/a")?.state), ["done", "working", "done"]);
  for (const body of revisions) closedTree(body.records.map(record => record.id));
});

test("publication exhaustion is bounded and the next change recovers", async () => {
  let fail = true;
  let attempts = 0;
  const publisher = createPublisher({ active: true, pane: "pane_1", derive: () => ({ type: "replace_subtrees", roots: ["agents", "jobs"], records: [] }), log: () => {}, retry: async () => {}, transport: async () => {
    attempts++;
    return fail ? { error: "offline" } : { status: 200, body: JSON.stringify({ status_record_limit: 64, status: { program_status: { records: [] } } }) };
  } });
  publisher.changed();
  assert.equal(await publisher.drain(), false);
  assert.equal(attempts, 3);
  fail = false;
  publisher.changed();
  assert.equal(await publisher.drain(), true);
  publisher.close();
  publisher.changed();
  assert.equal(await publisher.drain(), true);
});
