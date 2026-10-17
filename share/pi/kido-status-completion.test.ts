import { test } from "node:test";

import type { Fixture } from "./kido-fixture.ts";

import assert from "node:assert/strict";

import { AgentSession } from "@earendil-works/pi-coding-agent";

import { visibleWidth } from "@earendil-works/pi-tui";

import { makeFixture, fakeTheme, startSession, freshExtensions, pollUntil, sendToInbox, envelope, customMessages } from "./kido-fixture.ts";

test("@ completion offers this session's agents first and still returns the built-in provider's file items", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(completionAgents);
    const s = await startSession(fx);
    const { provider, calls } = stackOver(s.autocompleteFactories, [{ value: "@helpers/readme.md", label: "helpers/readme.md" }]);

    const suggestions = await suggestOnceListed(provider, "@hel");

    assert.equal(suggestions.prefix, "@hel", "one prefix for both halves of the list, the token pi itself would cut");
    const values = suggestions.items.map((i: any) => i.value);
    assert.deepEqual(
      values,
      ["@helm", "@helper-one", "@helpers/readme.md"],
      "matching agents first, then the files pi found for the same token; a non-matching agent is left out",
    );

    const child = suggestions.items.find((i: any) => i.value === "@helper-one");
    assert.match(child.description, /running/, "a row says what the agent is doing");
    assert.match(child.description, /refactoring internal\/ui/, "including whatever set_status last put there");
    assert.match(child.description, /subagent of helm/, "and names a subagent's parent by name, not by the id the list carries");
    assert.ok(!values.includes("@self"), "this session is not offered to itself");

    assert.ok(calls.length > 0, "the built-in provider was asked too, so @src/... keeps completing files");

    // Accepting an agent inserts `@name` through pi's own applyCompletion,
    // not a second implementation of it here.
    const applied = provider.applyCompletion(["@hel"], 0, 4, suggestions.items[0], "@hel");
    assert.equal(applied.lines[0], "@helm ", "the accepted item replaces the token with @name");
  } finally {
    await fx.restore();
  }
});

// Seen live: a session nobody named is called after its pane title, and
// typing the word that identifies it offered nothing at all - a
// whole-name startsWith can never match a word in the middle, and a name
// with a space can never be typed as one `@` token either, so there is
// nothing for the editor to insert. Matching any word of the name finds
// it; inserting the agent's unique id prefix is what makes accepting it
// mean something, since resolveAgent takes an id prefix as readily as a
// name.
test("@ completion excludes unnamed pi even when its pane title looks like a name", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "named", name: "helper", named: true, self: false, parent: "", canMessage: true },
      { id: "unnamed-id", name: "helper - kido", named: false, self: false, parent: "", canMessage: true },
    ]);
    const s = await startSession(fx);
    const { provider } = stackOver(s.autocompleteFactories, []);
    const suggestions = await suggestOnceListed(provider, "@hel");
    assert.deepEqual(suggestions.items.map((i: any) => i.label), ["@helper"]);
  } finally {
    await fx.restore();
  }
});

test("@ completion uses list_runs' live agent rows, not bash or ended runs", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "12345678-agent", run: "12345678-agent", name: "helper", kind: "subagent", state: "running", relationship: "own", parent: "self" },
      { id: "bash-run", run: "bash-run", name: "helper-job", kind: "bash", state: "running", relationship: "own" },
      { id: "ended-run", run: "ended-run", name: "helper-ended", kind: "subagent", state: "ended", relationship: "own" },
    ]);
    const s = await startSession(fx);
    const { provider } = stackOver(s.autocompleteFactories, []);
    const suggestions = await suggestOnceListed(provider, "@hel");
    assert.deepEqual(suggestions.items.map((i: any) => i.value), ["@12345678"]);
    assert.equal(suggestions.items[0].label, "@helper");
  } finally {
    await fx.restore();
  }
});

test("@ completion matches a word inside an agent's name, and inserts an id prefix when the name cannot be typed as a token", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(completionAgents);
    const s = await startSession(fx);
    const { provider } = stackOver(s.autocompleteFactories);

    const suggestions = await suggestOnceListed(provider, "@config");
    const labels = suggestions.items.map((i: any) => i.label);
    assert.deepEqual(
      labels,
      ["@config-linter", "@Tmux config"],
      "both are offered, case-insensitively, and the whole-name match is ranked ahead of the word match",
    );

    const unnamed = suggestions.items.find((i: any) => i.label === "@Tmux config");
    assert.equal(
      unnamed.value,
      "@01a0d843-7",
      "a name with whitespace inserts the shortest id prefix of at least eight characters that is unique in the list",
    );
    assert.match(unnamed.description, /01a0d843-7/, "and the row says what accepting it will actually insert");
    const applied = provider.applyCompletion(["@config"], 0, 7, unnamed, "@config");
    assert.equal(applied.lines[0], "@01a0d843-7 ", "accepting it leaves an address kido can resolve, not an untypeable name");

    // Negative control: an id prefix everywhere would pass the assertions above too.
    const spaceless = suggestions.items.find((i: any) => i.label === "@config-linter");
    assert.equal(spaceless.value, "@config-linter", "a spaceless name inserts the name");
  } finally {
    await fx.restore();
  }
});

test("a token that is not an @ reference is handed to the built-in provider untouched", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(completionAgents);
    const s = await startSession(fx);
    const { provider, calls } = stackOver(s.autocompleteFactories, [{ value: "src/main.ts", label: "src/main.ts" }]);

    const suggestions = await suggest(provider, "look at src/ma");
    assert.equal(calls.length, 1, "the built-in provider was asked");
    assert.deepEqual(suggestions.items.map((i: any) => i.value), ["src/main.ts"], "and its answer is returned as it came");

    const files = await suggest(provider, "@src/ma");
    assert.deepEqual(files.items.map((i: any) => i.value), ["src/main.ts"], "@src/... still completes files");
  } finally {
    await fx.restore();
  }
});

// The assertion with teeth: the slow call happened at all - a provider that
// never refreshed would satisfy the deadline and go stale forever.
test("@ completion serves the last agent list without waiting for the subprocess behind it", async () => {
  const fx = makeFixture();
  const savedTTL = process.env.KIDO_AGENT_LIST_TTL_MS;
  try {
    fx.setAgents(completionAgents);
    process.env.KIDO_AGENT_LIST_TTL_MS = "50";
    const s = await startSession(fx, { factory: await freshExtensions() });
    const { provider } = stackOver(s.autocompleteFactories);

    await suggestOnceListed(provider, "@hel");

    process.env.KIDO_FAKE_AGENTS_DELAY_MS = "400";
    const callsBefore = fx.agentsCallCount();
    await new Promise((r) => setTimeout(r, 60)); // past the TTL

    const started = Date.now();
    const suggestions = await suggest(provider, "@hel");
    const elapsed = Date.now() - started;
    assert.ok(elapsed < 200, `the completion returned in ${elapsed}ms, without waiting out the 400ms lookup`);
    assert.equal(suggestions.items[0].value, "@helm", "and served the list it already had");

    await pollUntil(() => fx.agentsCallCount() > callsBefore, 2000, "the background refresh to run");
  } finally {
    if (savedTTL === undefined) delete process.env.KIDO_AGENT_LIST_TTL_MS;
    else process.env.KIDO_AGENT_LIST_TTL_MS = savedTTL;
    await fx.restore();
  }
});

// Pins a real bug: the render path and the model path are different code paths,
// and two subagents' notices sat invisible for minutes, appearing only when the
// parent's turn happened to end. The widget's whole life is one fixture.
test("an inbound notice renders a widget at once and clears it once the model entry takes over", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("notice", "build finished", { from }));

    const widget = s.widgets.get("kido-notice-pending");
    assert.ok(widget, "a widget was set for the pending notice");
    assert.ok(widget!.content, "the widget has content, not a clear");
    const dimTheme = { fg: (color: string, text: string) => `<${color}>${text}</${color}>` };
    assert.deepEqual(
      widget!.content!(undefined, dimTheme).render(80),
      ["<dim>│ </dim><dim>@peer-a notifies:</dim><dim> build finished</dim>"],
      "the pending row is the notice's collapsed line, border, header and body all dim",
    );
    assert.ok(visibleWidth(widget!.content!(undefined, fakeTheme).render(14)[0]!) <= 14, "and it fits");

    const noticeMessages = customMessages(s, "kido-notice");
    assert.equal(noticeMessages.length, 1, "the notice's text was sent to the model exactly once");
    const sent = noticeMessages[0]!.message;
    assert.ok(sent.content.endsWith("\nbuild finished"), "the model-visible text is the notice's full text, unchanged under its header line");
    const noticeId = sent.details?.noticeId;
    assert.ok(noticeId, "the message carries an id the widget half can be matched against");

    assert.ok(s.widgets.get("kido-notice-pending")?.content, "the widget is still up before delivery actually happens");

    await s.emit("message_start", { message: { ...sent, role: "custom" } });

    assert.equal(s.widgets.get("kido-notice-pending")?.content, undefined, "the widget is cleared once the real entry has taken over");

    await s.emit("message_start", { message: { role: "custom", customType: "some-other-type" } });
    assert.equal(s.widgets.get("kido-notice-pending")?.content, undefined, "an unrelated message_start leaves the cleared widget alone");
  } finally {
    await fx.restore();
  }
});

// pi 1.2.0's sendMessage(triggerTurn) on an idle session runs the same setup as a
// prompt: before_agent_start, the run's prompt options, the pending nextTurn
// messages. So an arrival needs nothing but its own custom message: no user-role
// text that the model reads and the session history keeps.
test("an idle session's arrival starts pi's run as itself, with kido's prompt guidelines and no user message", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startPinnedPiSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    const cases: Array<{ kind: string; customType: string; deliverAs: string }> = [
      { kind: "message", customType: "kido-message", deliverAs: "followUp" },
      { kind: "notice", customType: "kido-notice", deliverAs: "steer" },
      { kind: "ask", customType: "kido-ask", deliverAs: "followUp" },
      { kind: "reply", customType: "kido-reply", deliverAs: "followUp" },
    ];
    for (const [i, c] of cases.entries()) {
      await sendToInbox(s.inboxPath, envelope(c.kind, `${c.kind} text`, { id: `env-${c.kind}`, from }));
      const sent = customMessages(s, c.customType)[0];
      assert.ok(sent, `the ${c.kind} reached sendMessage`);
      assert.deepEqual(sent!.opts, { deliverAs: c.deliverAs, triggerTurn: true }, `the ${c.kind} asks pi for its turn itself`);
      await pollUntil(() => s.runs.length === i + 1, 2000, `pi's run for the ${c.kind}`);
      const run = s.runs[i]!;
      assert.equal(run.messages.length, 1, `the ${c.kind}'s run starts with it alone: ${JSON.stringify(run.messages)}`);
      assert.equal(run.messages[0].role, "custom");
      assert.equal(run.messages[0].customType, c.customType, "the arrival keeps its custom type, header and renderer");
      assert.equal(run.messages[0].content, sent!.message.content);
      assert.ok(run.guidelines.some((g) => /sleep/.test(g)), `the ${c.kind}'s run carries kido's prompt guidelines`);
    }
    assert.deepEqual(s.delivered, [], "no user message goes into the history");
    assert.deepEqual(s.errors, []);
  } finally {
    await fx.restore();
  }
});

// pi 1.2.0 counts a run as busy from its start, before before_agent_start ends. An
// arrival during a slow startup hook must join that run, once, rather than start a
// second run or a second turn request of its own.
test("an arrival during a slow before_agent_start joins the run that is starting", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
      { id: "peer-b", name: "peer-b", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startPinnedPiSession(fx);
    s.holdStartup();

    await sendToInbox(s.inboxPath, envelope("ask", "first question", { id: "ask-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(s.session.isIdle, false, "the run counts as busy while it starts");
    await sendToInbox(s.inboxPath, envelope("ask", "second question", { id: "ask-2", from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(s.runs.length, 0, "the startup hook still holds the first run");
    s.releaseStartup();
    await pollUntil(() => s.runs.length === 1, 2000, "the first run to start");

    assert.match(s.runs[0]!.messages[0].content, /\(id ask-1\)/, "the first ask starts the run");
    assert.equal(s.runs[0]!.messages.length, 1);
    assert.equal(s.queued.length, 1, "the second ask is queued into that run, once");
    assert.equal(s.queued[0]!.mode, "followUp");
    assert.match(s.queued[0]!.message.content, /\(id ask-2\)/);
    assert.equal(s.runs.length, 1, "no second run");
    assert.deepEqual(s.delivered, [], "and no user message");
    assert.deepEqual(s.errors, []);
  } finally {
    await fx.restore();
  }
});

test("pi's clearQueue restores only editor text and preserves both custom queues in order across reload", async () => {
  assert.equal(typeof globalThis.__kidoPiExtensionClearQueue, "function", "pi must expose clearQueue");
  const { Agent } = await import(import.meta.resolve("@earendil-works/pi-agent-core"));
  const agent = new Agent();
  const custom = ["kido-message", "kido-ask", "kido-notice", "kido-stream", "kido-reply"].map((customType) => ({
    role: "custom", customType, content: customType, display: true, timestamp: 0,
  }));
  const user = { role: "user", content: "editor text", timestamp: 0 };
  for (const message of [custom[0], user, ...custom.slice(1)]) {
    agent.steer(message);
    agent.followUp(message);
  }
  const session = Object.assign(Object.create(AgentSession.prototype), {
    agent, _steeringMessages: ["steering text"], _followUpMessages: ["follow-up text"], _emitQueueUpdate() {},
  });
  await freshExtensions();
  assert.deepEqual(session.clearQueue(), { steering: ["steering text"], followUp: ["follow-up text"] });
  assert.deepEqual(session.clearQueue(), { steering: [], followUp: [] });
  assert.deepEqual(agent.steeringQueue.messages, custom);
  assert.deepEqual(agent.followUpQueue.messages, custom);
  let cleared = false;
  Object.assign(session, {
    agent: { clearAllQueues() { cleared = true; } },
    _steeringMessages: ["steering text"], _followUpMessages: ["follow-up text"],
  });
  assert.deepEqual(session.clearQueue(), { steering: ["steering text"], followUp: ["follow-up text"] });
  assert.equal(cleared, true, "missing core queues must leave the original clearQueue intact");
});

test("a queued custom follow-up survives Escape during a tool call", { timeout: 5000 }, async (t) => {
  const piDist = new URL("./", import.meta.resolve("@earendil-works/pi-coding-agent"));
  const { Agent } = await import(import.meta.resolve("@earendil-works/pi-agent-core"));
  const { InteractiveMode } = await import(new URL("modes/interactive/interactive-mode.js", piDist).href);
  for (const escape of [false, true]) {
    await t.test(escape ? "Escape restores the editor and aborts" : "abort alone preserves the queue", async () => {
      let started!: () => void;
      const toolStarted = new Promise<void>((resolve) => { started = resolve; });
      let requests = 0;
      const agent = new Agent({
        streamFn: async (_model: unknown, _context: unknown, options: any) => {
          const message = {
            role: "assistant", api: "test", provider: "test", model: "test", timestamp: 0,
            content: requests++ === 0 ? [{ type: "toolCall", id: "blocked", name: "wait", arguments: {} }] : [],
            stopReason: options.signal.aborted ? "aborted" : requests === 1 ? "toolUse" : "stop",
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
          };
          return {
            async *[Symbol.asyncIterator]() { yield { type: "done", message }; },
            result: async () => message,
          };
        },
        initialState: { tools: [{
          name: "wait", label: "Wait", description: "Wait for interruption", parameters: { type: "object", properties: {} },
          execute: async (_id: string, _args: unknown, signal: AbortSignal) => {
            started();
            await new Promise<void>((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
            return { content: [{ type: "text", text: "Command aborted" }], details: {} };
          },
        }] },
      });
      const session = Object.assign(Object.create(AgentSession.prototype), {
        agent, _isAgentRunActive: true, _steeringMessages: [], _followUpMessages: [], _emitQueueUpdate() {},
        abortRetry() {}, abortCompaction() {}, abortBranchSummary() {},
        waitForIdle: () => agent.waitForIdle(),
      });
      const run = agent.prompt("start");
      await toolStarted;
      await session.sendCustomMessage({ customType: "kido-message", content: "peer evidence", display: true }, { deliverAs: "followUp", triggerTurn: true });
      assert.equal(agent.hasQueuedMessages(), true);
      assert.deepEqual(session.getFollowUpMessages(), [], "custom entries have no editor text");
      let aborted: Promise<void> | undefined;
      if (escape) {
        const interactive = Object.assign(Object.create(InteractiveMode.prototype), {
          runtimeHost: { session }, compactionQueuedMessages: [], updatePendingMessagesDisplay() {},
          editor: { getText: () => "", setText() { assert.fail("custom message must not become editor text"); } },
        });
        const abort = session.abort.bind(session);
        session.abort = () => (aborted = abort());
        interactive.restoreQueuedMessagesToEditor({ abort: true });
      } else aborted = session.abort();
      await aborted;
      await run;
      assert.equal(agent.state.messages.some((m: any) => m.role === "custom"), false, "not consumed during the aborted turn");
      await agent.prompt("next user turn");
      assert.equal(agent.state.messages.filter((m: any) => m.role === "custom" && m.content === "peer evidence").length, 1,
        "acknowledged kido follow-up must reach the next turn exactly once");
    });
  }
});

// pi stacks an extension's provider over its own built-in one
// (ctx.ui.addAutocompleteProvider, pi 0.87.1); this builds that stack, with a
// stand-in for the built-in half answering the same `@token` prefix pi's own
// CombinedAutocompleteProvider returns.
function stackOver(
  factories: Array<(current: any) => any>,
  files: Array<{ value: string; label: string }> = [],
) {
  const calls: Array<{ lines: string[]; cursorLine: number; cursorCol: number }> = [];
  const builtIn = {
    triggerCharacters: ["@"],
    async getSuggestions(lines: string[], cursorLine: number, cursorCol: number) {
      calls.push({ lines, cursorLine, cursorCol });
      if (files.length === 0) return null;
      const before = (lines[cursorLine] ?? "").slice(0, cursorCol);
      return { items: files, prefix: before.slice(before.lastIndexOf("@")) };
    },
    applyCompletion(lines: string[], cursorLine: number, _cursorCol: number, item: any, prefix: string) {
      const line = lines[cursorLine] ?? "";
      const applied = line.slice(0, line.length - prefix.length) + item.value + " ";
      return { lines: [applied], cursorLine, cursorCol: applied.length };
    },
    shouldTriggerFileCompletion: () => true,
  };
  assert.equal(factories.length, 1, "exactly one provider was registered");
  return { provider: factories[0]!(builtIn), builtIn, calls };
}

const suggest = (provider: any, line: string, cursorCol = line.length) =>
  provider.getSuggestions([line], 0, cursorCol, { signal: new AbortController().signal });

// Nothing is fetched until the first `@`, and that first keystroke is served
// before its own refresh lands - the editor never waits on a subprocess - so
// every assertion polls keystrokes rather than sleeping a guess at the subprocess's time.
async function suggestOnceListed(provider: any, line: string, ms = 2000) {
  let suggestions: any;
  await pollUntil(
    async () => {
      suggestions = await suggest(provider, line);
      return !!suggestions?.items?.some((i: any) => i.value.startsWith("@") && !i.value.includes("/"));
    },
    ms,
    `the agent list behind "${line}"`,
  );
  return suggestions;
}

const completionAgents = [
  { id: "self", name: "self", parent: "", self: true, canMessage: true, status: "running" },
  { id: "p1", name: "helm", parent: "", self: false, canMessage: true, canReply: true, status: "idle" },
  { id: "c1", name: "helper-one", parent: "p1", self: false, canMessage: true, canReply: true, status: "running", activity: "refactoring internal/ui" },
  { id: "c2", name: "builder", parent: "p1", self: false, canMessage: true, canReply: true, status: "waiting" },
  // A session the user never named: `kido tool list_runs` falls back to the
  // pane title, which is a phrase with spaces in it (a Claude Code title
  // here) rather than a handle. Its id shares eight characters with the
  // next agent's, so the prefix that identifies it has to be longer than
  // the floor.
  { id: "01a0d843-7f2e-4b5a-9c31-8de0f1a2b3c4", name: "Tmux config", parent: "", self: false, canMessage: true, canReply: true, status: "running" },
  { id: "01a0d843-ffff-4b5a-9c31-8de0f1a2b3c4", name: "scribe", parent: "", self: false, canMessage: true, canReply: true, status: "idle" },
  { id: "k9", name: "config-linter", parent: "", self: false, canMessage: true, canReply: true, status: "idle" },
];

// Drives the fake pi's sendMessage into the pinned pi's own sendCustomMessage and
// _startRun, with stubs only below the run's setup: before_agent_start goes to the
// session's own handlers, and each run records its starting messages and the prompt
// guidelines it was prepared with. A pi that changes this path fails here.
async function startPinnedPiSession(fx: Fixture) {
  const runs: Array<{ messages: any[]; guidelines: string[] }> = [];
  const queued: Array<{ mode: "steer" | "followUp"; message: any }> = [];
  const errors: unknown[] = [];
  let guidelines: string[] = [];
  let release: () => void = () => {};
  let startup: Promise<void> = Promise.resolve();
  const session = Object.assign(Object.create(AgentSession.prototype), {
    _isAgentRunActive: false,
    _isEmittingAgentSettled: false,
    _agentRunAbortRequested: false,
    _pendingNextTurnMessages: [],
    _pendingCustomMessages: [],
    _pendingToolNames: new Set(),
    _baseSystemPromptOptions: { selectedTools: [], promptGuidelines: [] },
    agent: {
      state: { messages: [] },
      prompt: async (messages: any[]) => void runs.push({ messages, guidelines }),
      steer: (message: unknown) => void queued.push({ mode: "steer", message }),
      followUp: (message: unknown) => void queued.push({ mode: "followUp", message }),
    },
    _extensionRunner: {
      async emitBeforeAgentStart(trigger: object, base: object) {
        await startup;
        const systemPromptOptions = structuredClone(base);
        await s.emit("before_agent_start", { ...trigger, type: "before_agent_start", systemPromptOptions });
        return { messages: [], systemPromptOptions };
      },
    },
    getActiveToolNames: () => [],
    _preparePromptAndToolLoadout(options: { promptGuidelines: string[] }) {
      guidelines = [...options.promptGuidelines];
      return undefined;
    },
    _flushPendingBashMessages() {},
    _resolveIdleWaitIfIdle() {},
    _recordSelection() {},
    _handlePostAgentRun: async () => false,
    _runBeforeSettleBoundary: async () => false,
    async _emitAgentSettled(this: { _isAgentRunActive: boolean }) {
      this._isAgentRunActive = false;
    },
  });
  const s = await startSession(fx, { idle: () => session.isIdle });
  const record = s.pi.sendMessage;
  s.pi.sendMessage = (message: any, opts: unknown) => {
    record(message, opts);
    session.sendCustomMessage(message, opts).catch((err: unknown) => void errors.push(err));
  };
  return {
    ...s,
    session,
    runs,
    queued,
    errors,
    holdStartup() {
      startup = new Promise<void>((resolve) => { release = resolve; });
    },
    releaseStartup: () => release(),
  };
}
