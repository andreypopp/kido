import { test } from "node:test";

import assert from "node:assert/strict";

import { writeFileSync } from "node:fs";

import { join } from "node:path";

import {
  makeFixture,
  selfPane,
  agentPane,
  startNamedSession,
  asSubagent,
  withEnv,
  pollUntil,
  type Fixture,
} from "./kido-pi-fixture.ts";

type Row = {
  id: string;
  name: string;
  kind: string;
  relationship: string;
  state: string;
  task?: string;
  report?: string;
  outcome?: { result: string };
};

type ListTool = { execute: (id: string, params: object) => Promise<{ content: { text: string }[] }> };

function rows(s: { tools: Map<string, unknown> }): Promise<Row[]> {
  const tool = s.tools.get("list_runs") as ListTool;
  return tool.execute("c", {}).then((r) => JSON.parse(r.content[0].text) as Row[]);
}

function run(fx: Fixture, options: { edge: boolean }): void {
  fx.writeAgent("boss-session", "mid", { session: "mid", run: "mid-run" });
  fx.writeAgent("boss-session", "peer", { session: "peer" });
  fx.writeAgent("other-parent", "stranger", { session: "stranger" });
  fx.writeAgent("mid", "kid", { session: "kid-session", run: "kid-run" });
  writeFileSync(join(fx.agentDir("mid", "kid"), "task"), "do the thing");
  writeFileSync(join(fx.agentDir("mid", "kid"), "report"), "did the thing");
  fx.setPanes([
    agentPane({ pane: "%1", session: "mid", name: "mid" }),
    agentPane({ pane: "%2", session: "boss-session", name: "boss" }),
    agentPane({ pane: "%3", session: "peer", name: "peer" }),
    agentPane({ pane: "%4", session: "stranger", name: "stranger" }),
    agentPane({ pane: "%5", session: "kid-session", name: "kid" }),
  ]);
  void options;
}

test("list_runs joins my runs with my parent, same-parent peers, and a subagent's task and report", async () => {
  const fx = makeFixture();
  try {
    run(fx, { edge: true });
    fx.setRuns([
      { id: "kid-run", name: "kid", parent: "mid-run", pane: "%5", session: "kid-session", startedAt: "2023-11-14T22:00:02Z" },
      { id: "job", name: "job", parent: "mid-run", startedAt: "2023-11-14T22:00:01Z" },
    ]);
    await asSubagent(
      fx,
      "mid",
      async () => {
        const s = await startNamedSession(fx, "mid", "mid");
        const listed = await rows(s);
        assert.deepEqual(
          listed.map((r) => `${r.id}:${r.relationship}:${r.kind}`),
          ["boss-session:parent:agent", "peer:peer:subagent", "kid-session:own:subagent", "job:own:bash"],
          "my parent, a same-parent peer, my subagent and my bash run; never myself or another parent's child",
        );
        const kid = listed.find((r) => r.id === "kid-session")!;
        assert.equal(kid.task, "do the thing");
        assert.equal(kid.report, join(fx.agentDir("mid", "kid"), "report"));
        assert.equal(kid.state, "running");
        const boss = listed.find((r) => r.id === "boss-session")!;
        assert.equal(boss.name, "boss");

        const raw = (await (s.tools.get("list_runs") as ListTool).execute("c", {})).content[0].text;
        assert.deepEqual(Object.keys((JSON.parse(raw) as Array<Record<string, unknown>>)[0]!), [
          "id", "name", "named", "pane", "window", "status", "activity", "parent", "depth",
          "self", "cwd", "canMessage", "canReply", "model", "kind", "relationship", "run", "state",
        ]);
      },
      { parent: "boss-session", name: "mid", run: "mid-run" },
    );
  } finally {
    await fx.restore();
  }
});

test("list_runs keeps every running run and the newest twenty ended ones", async () => {
  const fx = makeFixture();
  try {
    run(fx, { edge: true });
    const ended = Array.from({ length: 24 }, (_, i) => ({
      id: `ended-${String(i).padStart(2, "0")}`,
      name: `ended-${i}`,
      
      parent: "mid-run",
      startedAt: `2023-11-14T21:${String(i).padStart(2, "0")}:00Z`,
      outcome: { result: "completed", text: "done" },
    }));
    fx.setRuns([
      { id: "live-a", name: "live-a", parent: "mid-run" },
      { id: "live-b", name: "live-b", parent: "mid-run" },
      ...ended,
    ]);
    await asSubagent(
      fx,
      "mid",
      async () => {
        const s = await startNamedSession(fx, "mid", "mid");
        const listed = await rows(s);
        const own = listed.filter((r) => r.relationship === "own");
        assert.equal(own.length, 22, "two running and twenty ended");
        assert.deepEqual(own.slice(0, 2).map((r) => r.id), ["live-a", "live-b"]);
        assert.deepEqual(own.slice(2).map((r) => r.id), ended.slice(0, 20).map((r) => r.id), "newest first");
        assert.equal(own[2]!.state, "ended");
        assert.deepEqual(own[2]!.outcome, { result: "completed", text: "done" });
      },
      { parent: "boss-session", name: "mid", run: "mid-run" },
    );
  } finally {
    await fx.restore();
  }
});

test("a live grandchild carries its agent entry's run id, so stop_run names its run", async () => {
  const fx = makeFixture();
  try {
    fx.writeAgent("root", "mid", { session: "mid-session", run: "mid-run" });
    fx.writeAgent("mid-session", "grand", { session: "grand-session", run: "grand-run" });
    fx.setPanes([selfPane(), agentPane({ pane: "%3", session: "grand-session", name: "grand" })]);
    fx.setRuns([{ id: "grand-run", name: "grand", parent: "mid-run", pane: "%3", session: "grand-session" }]);
    await asSubagent(
      fx,
      "mid-session",
      async () => {
        const s = await startNamedSession(fx, "mid", "mid-session");
        await s.tools.get("stop_run").execute("c", { to: "grand", force: true });
        assert.ok(fx.runStopCalls()[0]?.includes("grand-run"), "stop_run passes the descendant's run id, not its session id");
      },
      { parent: "root", name: "mid", run: "mid-run" },
    );
  } finally {
    await fx.restore();
  }
});

test("a top-level pi lists the run-child %N children it started", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    fx.setRuns([{ id: "child-run", name: "child", parent: "%1", startedAt: "2023-11-14T22:00:00Z" }]);
    const s = await startNamedSession(fx, "Self");
    const listed = await rows(s);
    assert.deepEqual(
      listed.map((r) => `${r.id}:${r.relationship}:${r.kind}`),
      ["child-run:own:bash"],
      "a run-child of the top-level pi's own pane is one of its runs",
    );
  } finally {
    await fx.restore();
  }
});

test("a stale @kido_session on a pane without a pi root is no agent", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([
      selfPane(),
      // A shell pane left behind by a crashed pi: the option says pi, the root does not.
      { ...agentPane({ pane: "%2", session: "ghost", name: "ghost" }), pane_program_status: JSON.stringify({ serial: 1, records: [{ id: "", state: "idle" }] }) },
    ]);
    const s = await startNamedSession(fx, "Self");
    assert.deepEqual(await rows(s), [], "no agent row and no address");
    assert.equal(
      (await s.tools.get("message_agent").execute("c", { to: "ghost", message: "x" })).content[0].text,
      'could not message ghost: no agent session matches "ghost"',
    );
  } finally {
    await fx.restore();
  }
});

// The editor gets whatever the last list returned, stale or empty, while a
// refresh runs behind it.
test("@ completion offers this session's agents first and still returns the built-in provider's file items", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "worker-session", name: "worker-2", state: "idle" })]);
    const s = await startNamedSession(fx, "Self");
    assert.equal(s.autocompleteFactories.length, 1, "a completion provider is registered");
    const current = {
      triggerCharacters: ["@"],
      async getSuggestions() {
        return { items: [{ value: "@worker-2.ts", label: "worker-2.ts" }], prefix: "@wo" };
      },
      applyCompletion: () => ({ lines: [], cursorLine: 0, cursorCol: 0 }),
    };
    const provider = s.autocompleteFactories[0](current);
    const suggest = () => provider.getSuggestions(["@wo"], 0, 3, { signal: new AbortController().signal });
    let out = await suggest();
    await pollUntil(async () => {
      out = await suggest();
      return out?.items.some((i: { value: string }) => i.value === "@worker-2") ?? false;
    }, 2000, "the agent list to load");
    assert.deepEqual(out!.items.map((i: { value: string }) => i.value), ["@worker-2", "@worker-2.ts"], "agents first, then the files for the same token");
    assert.equal(out!.prefix, "@wo");
  } finally {
    await fx.restore();
  }
});

test("@ completion excludes unnamed agents and non-live runs, matches a word inside a name, and inserts an id prefix when the name cannot be typed", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "titled-session", title: "π - a title" }),
      agentPane({ pane: "%3", session: "two-words-session", name: "two words" }),
      agentPane({ pane: "%4", session: "worker-session", name: "worker-two" }),
    ]);
    fx.setRuns([
      { id: "bash-run", name: "build", parent: "%1", },
      { id: "ended-run", name: "finished", parent: "%1", outcome: { result: "completed" } },
    ]);
    const s = await startNamedSession(fx, "Self");
    const current = {
      triggerCharacters: ["@"],
      async getSuggestions() {
        return null;
      },
      applyCompletion: () => ({ lines: [], cursorLine: 0, cursorCol: 0 }),
    };
    const provider = s.autocompleteFactories[0](current);
    const suggest = (token: string) => provider.getSuggestions([`@${token}`], 0, token.length + 1, { signal: new AbortController().signal });
    let out = await suggest("two");
    await pollUntil(async () => ((out = await suggest("two"))?.items.length ?? 0) >= 2, 2000, "the agent list to load");
    const items = out!.items as Array<{ value: string; label: string }>;
    assert.deepEqual(items.map((i) => i.label).sort(), ["@two words", "@worker-two"], "a word inside a name matches too");
    const twoWords = items.find((i) => i.label === "@two words")!;
    assert.match(twoWords.value, /^@two-word/, "a name with whitespace is inserted as an id prefix");
    assert.equal(items.find((i) => i.label === "@worker-two")!.value, "@worker-two");
    await pollUntil(async () => ((out = await suggest("a title"))?.items.length ?? 0) === 0, 2000, "the unnamed agent to stay out");
    await pollUntil(async () => ((out = await suggest("build"))?.items.length ?? 0) === 0, 2000, "the bash run to stay out");
    await pollUntil(async () => ((out = await suggest("finished"))?.items.length ?? 0) === 0, 2000, "the ended run to stay out");

    let handed = 0;
    const wrapped = s.autocompleteFactories[0]({
      ...current,
      async getSuggestions() {
        handed++;
        return { items: [], prefix: "plain" };
      },
    });
    assert.deepEqual(await wrapped.getSuggestions(["plain"], 0, 5, { signal: new AbortController().signal }), { items: [], prefix: "plain" });
    assert.equal(handed, 1, "a token that is not an @ reference is handed to the built-in provider untouched");
  } finally {
    await fx.restore();
  }
});

test("@ completion serves the last agent list without waiting for the subprocess behind it", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "worker-session", name: "worker-2" })]);
    const s = await startNamedSession(fx, "Self");
    const current = {
      triggerCharacters: ["@"],
      async getSuggestions() {
        return null;
      },
      applyCompletion: () => ({ lines: [], cursorLine: 0, cursorCol: 0 }),
    };
    const provider = s.autocompleteFactories[0](current);
    const suggest = () => provider.getSuggestions(["@wo"], 0, 3, { signal: new AbortController().signal });
    await withEnv({ KIDO_AGENT_LIST_TTL_MS: "60000" }, async () => {
      await pollUntil(async () => ((await suggest())?.items.length ?? 0) > 0, 2000, "the first list");
      fx.setPanes([selfPane(), agentPane({ pane: "%2", session: "worker-session", name: "worker-three" })]);
      const second = await suggest();
      assert.deepEqual(second!.items.map((i: { value: string }) => i.value), ["@worker-2"], "the cached list answers at once");
    });
  } finally {
    await fx.restore();
  }
});
