import { test } from "node:test";

import type { Fixture } from "./kido-fixture.ts";

import assert from "node:assert/strict";

import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";

import { join, dirname } from "node:path";

import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";

import { makeFixture, commandWork, fakeTheme, fakeCtx, startSessionCore, startSession, freshExtensions, DEFAULT_SESSION, asSubagent, withEnv, pollUntil, pollForStable, sendToInbox, envelope, settlesWithin } from "./kido-fixture.ts";

// Driven from the same fixture lib/test/test_msg.ml's own discriminator table test
// drives, so the two suites cannot drift apart by someone editing only one list.
test("user asks register only for top-level sessions, including inherited child environments", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(DEFAULT_SESSION, async () => {
      const child = await startSession(fx, { factory: await freshExtensions() });
      assert.equal(child.tools.has("set_asks"), false);
      await pollUntil(() => fx.parentAliveCalls().length > 0, 2000, "the child's parent poll to start");
      await child.emit("session_shutdown", { reason: "new" });
      const nested = await startSession(fx, { factory: await freshExtensions(), sessionId: "nested-root" });
      assert.equal(nested.tools.has("set_asks"), true);
      fx.setParentAlive("gone");
      const readings = fx.parentAliveCalls().length;
      assert.equal(await pollForStable(() => fx.parentAliveCalls().length, 200, 2000, "no child poll after replacement"), readings);
    }, { KIDO_PARENT_POLL_MS: "20" });
  } finally {
    await fx.restore();
  }
});

test("user ask widgets collapse, expand one ask, insert ids and preserve only live expansion", async () => {
  const fx = makeFixture();
  try {
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    const file = join(dirname(fx.runsDir), "asks.json");
    const asks = [
      { id: "A1", session: "self-session", text: "Ship now?\nOr wait for review?" },
      { id: "A2", session: "self-session", text: "A very long question about what to do next\nSecond decision" },
    ];
    writeFileSync(file, JSON.stringify(asks));
    const s = await startSession(fx, { factory: await freshExtensions() });
    s.pi.getSettings = () => ({});
    await pollUntil(() => !!s.widgets.get("kido-asks")?.content, 2000, "the initial ask widget");
    const draw = () => s.widgets.get("kido-asks")!.content!(null, fakeTheme);
    const click = { type: "click", button: "left", x: 12, y: 0 };
    let widget = draw();
    assert.deepEqual(widget.render(25).map(stripTerminalSequences), ["│ x A1: Ship now?...", "│ x A2: A very long qu..."]);
    for (const width of [0, 1, 2, 10]) {
      assert.ok(widget.render(width).every((line) => visibleWidth(line) <= width));
    }
    widget.render(80);
    assert.deepEqual(widget.handleMouse!({ ...click, type: "press" }), { handled: true, render: false });
    assert.equal(widget.handleMouse!({ ...click, button: "right" }), undefined);
    assert.equal(widget.handleMouse!({ ...click, type: "release" }), undefined);
    assert.deepEqual(widget.handleMouse!(click), { handled: true, render: true });
    assert.deepEqual(widget.render(80), ["│ x A1: Ship now?", "│ Or wait for review?", "│ x A2: A very long question about what to do next..."]);
    widget.handleMouse!({ ...click, y: 2 });
    assert.deepEqual(widget.render(80), ["│ x A1: Ship now?...", "│ x A2: A very long question about what to do next", "│ Second decision"]);
    widget.handleMouse!({ ...click, y: 1 });
    const collapsed = widget.render(80);
    assert.equal(collapsed.length, 2);
    assert.deepEqual(widget.handleMouse!({ ...click, x: 4 }), { handled: true, render: true });
    assert.equal(s.ui.getEditorText(), "A1: ");
    assert.deepEqual(widget.render(80), collapsed);
    s.ui.setEditorText("Existing text");
    widget.handleMouse!({ ...click, x: 5, y: 1 });
    assert.equal(s.ui.getEditorText(), "A2: Existing text");
    assert.deepEqual(widget.render(80), collapsed);
    widget.handleMouse!({ ...click, y: 1 });
    assert.match(widget.render(80).join("\n"), /Second decision/);
    const refresh = async (items: typeof asks) => {
      const previous = s.widgets.get("kido-asks")!.content;
      writeFileSync(file, JSON.stringify(items));
      assert.equal(await sendToInbox(s.inboxPath, envelope("asks", "")), "ok");
      await pollUntil(() => s.widgets.get("kido-asks")!.content !== previous, 2000, "the ask widget refresh");
      widget = draw();
    };
    await refresh(asks);
    assert.match(widget.render(80).join("\n"), /Second decision/);
    await refresh([asks[0]]);
    assert.deepEqual(widget.render(80), ["│ x A1: Ship now?..."]);
    await refresh(asks);
    assert.deepEqual(widget.render(80), collapsed);
    s.pi.getSettings = () => ({ tuiMode: "regular" });
    assert.deepEqual(widget.render(80), ["│ A1 asks you: Ship now?", "│ Or wait for review?", "│ A2 asks you: A very long question about what to do next", "│ Second decision"]);
  } finally {
    await fx.restore();
  }
});

test("clicking an ask's x removes it as the user and receives the sidebar note through the inbox", async () => {
  const fx = makeFixture();
  try {
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    const file = join(dirname(fx.runsDir), "asks.json");
    writeFileSync(file, JSON.stringify([
      { id: "A1", session: "self-session", text: "Ship now?\nOr wait for review?" },
      { id: "A2", session: "self-session", text: "Keep this ask\nStill collapsed" },
    ]));
    const s = await startSession(fx, { factory: await freshExtensions() });
    s.pi.getSettings = () => ({});
    await pollUntil(() => !!s.widgets.get("kido-asks")?.content, 2000, "the ask widget");
    const widget = s.widgets.get("kido-asks")!.content!(null, fakeTheme);
    const collapsed = widget.render(80);
    s.ui.setEditorText("Existing text");
    const messages = s.messages.length;
    const delivered = s.delivered.length;
    assert.deepEqual(widget.handleMouse!({ type: "click", button: "left", x: 2, y: 0 }), { handled: true, render: true });
    assert.deepEqual(widget.render(80), collapsed);
    await pollUntil(() => existsSync(file + ".removed"), 2000, "the user removal command");
    assert.deepEqual(JSON.parse(readFileSync(file + ".removed", "utf8")), ["remove-ask", "--", "A1"]);
    assert.equal(s.messages.length, messages);
    assert.equal(await sendToInbox(s.inboxPath, envelope("asks", "The user removed ask A1: Ship now?", {
      from: { session: "", name: "kido", pane: "" },
    })), "ok");
    await pollUntil(() => s.messages.length === messages + 1 && !s.widgets.get("kido-asks")!.content!(null, fakeTheme).render(80).join("\n").includes("A1"), 2000, "the dismissed ask refresh");
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).map((a: any) => a.id), ["A2"]);
    assert.equal(s.ui.getEditorText(), "Existing text");
    assert.deepEqual(s.widgets.get("kido-asks")!.content!(null, fakeTheme).render(80), ["│ x A2: Keep this ask..."]);
    assert.deepEqual(s.messages.at(-1)!.message, {
      customType: "kido-notice", content: "The user removed ask A1: Ship now?", display: false, details: { from: "kido" },
    });
    assert.deepEqual(s.messages.at(-1)!.opts, { deliverAs: "nextTurn" });
    assert.equal(s.delivered.length, delivered);
  } finally {
    await fx.restore();
  }
});

test("user ask widgets refresh from kido on actions, session startup and reload", async () => {
  const fx = makeFixture();
  try {
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    writeFileSync(join(dirname(fx.runsDir), "asks.json"), JSON.stringify([{ id: "A8", session: "other", text: "Other session's question" }]));
    const s = await startSession(fx, { factory: await freshExtensions() });
    const render = (host: typeof s) => host.widgets.get("kido-asks")?.content?.(null, fakeTheme).render(35).join("\n") ?? "";
    assert.equal(render(s), "");
    const ask = s.tools.get("set_asks");
    const result = await ask.execute("ask1", { asks: [{ text: "Ship now?\nOr wait for review?" }] }, undefined, undefined, fakeCtx());
    assert.equal(result.content[0].text, "A7: Ship now?");
    assert.match(render(s), /A7 asks you: Ship now\?/);
    assert.match(render(s), /Or wait for review\?/);
    assert.deepEqual(s.widgets.get("kido-asks")?.options, { placement: "aboveEditor" });
    for (const width of [0, 1, 2, 35]) {
      const lines = s.widgets.get("kido-asks")!.content!(null, fakeTheme).render(width);
      assert.ok(lines.every((line) => visibleWidth(line) <= width), `ask widget overflowed width ${width}`);
    }
    const call = ask.renderCall({ asks: [{ id: "A7", text: "Ship now?" }, { text: "Which version?" }] }, fakeTheme).render(80).join("\n");
    assert.match(call, /│ asks you \(A7\): Ship now\?/);
    assert.match(call, /│ asks you: Which version\?/);
    await ask.execute("ask2", { asks: [{ id: "A7", text: "Wait until Monday?" }] }, undefined, undefined, fakeCtx());
    assert.match(render(s), /Monday/);
    assert.doesNotMatch(render(s), /Ship/);
    await s.emit("session_shutdown", { reason: "reload" });
    const reloaded = await startSession(fx, { factory: await freshExtensions() });
    await pollUntil(() => /A7 asks you: Wait until/.test(render(reloaded)), 2000, "the ask widget refresh");
    const file = join(dirname(fx.runsDir), "asks.json");
    const persisted = JSON.parse(readFileSync(file, "utf8"));
    assert.equal(persisted.find((a: any) => a.id === "A7").session, DEFAULT_SESSION);
    const delivered = reloaded.delivered.length;
    const messages = reloaded.messages.length;
    writeFileSync(file, JSON.stringify(persisted.map((a: any) => a.id === "A7" ? { ...a, text: "Changed by the sidebar" } : a)));
    assert.equal(await sendToInbox(reloaded.inboxPath, envelope("asks", "")), "ok");
    await pollUntil(() => /Changed by the\n│ sidebar/.test(render(reloaded)), 2000, "the ask widget refresh");
    assert.equal(reloaded.delivered.length, delivered);
    assert.equal(reloaded.messages.length, messages);
    writeFileSync(file, JSON.stringify(persisted.filter((a: any) => a.id !== "A7")));
    assert.equal(await sendToInbox(reloaded.inboxPath, envelope("asks", "")), "ok");
    await pollUntil(() => render(reloaded) === "", 2000, "the removed ask widget");
    const multiple = await reloaded.tools.get("set_asks").execute("ask3", { asks: [{ text: "Another question\nDetails" }, { text: "Second question" }] }, undefined, undefined, fakeCtx());
    assert.equal(multiple.content[0].text, "A7: Another question\nA8: Second question");
    const cleared = await reloaded.tools.get("set_asks").execute("clear", { asks: [] }, undefined, undefined, fakeCtx());
    assert.equal(cleared.content[0].text, "no open asks");
    assert.equal(render(reloaded), "");
    assert.equal(reloaded.messages.length, messages, "own removal produces no note");
    const other = await startSession(fx, { factory: await freshExtensions(), sessionId: "other" });
    await pollUntil(() => /Other session's\n│ question/.test(render(other)), 2000, "the ask widget refresh");
    assert.doesNotMatch(render(other), /A7/);
    assert.deepEqual(s.notifications, []);
    assert.deepEqual(reloaded.notifications, []);
  } finally {
    await fx.restore();
  }
});

test("external ask removals queue a notice for the next turn without waking or interrupting", async () => {
  const fx = makeFixture();
  try {
    for (const idle of [true, false]) {
      const s = await startSession(fx, { idle: () => idle, factory: await freshExtensions() });
      const delivered = s.delivered.length;
      const messages = s.messages.length;
      assert.equal(await sendToInbox(s.inboxPath, envelope("asks", "The user removed ask A99b9ccb7: Ship?")), "ok");
      assert.equal(s.messages.length, messages + 1);
      const sent = s.messages.at(-1)!;
      assert.equal(sent.message.customType, "kido-notice");
      assert.equal(sent.message.content, "The user removed ask A99b9ccb7: Ship?");
      assert.equal(sent.message.display, false);
      assert.deepEqual(sent.opts, { deliverAs: "nextTurn" });
      assert.equal(s.delivered.length, delivered, "no turn trigger");
      await s.emit("session_shutdown", { reason: "reload" });
    }
  } finally {
    await fx.restore();
  }
});

test("user ask refreshes do not delay startup or inbox acknowledgement", async () => {
  const fx = makeFixture();
  try {
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    const file = join(dirname(fx.runsDir), "asks.json");
    writeFileSync(file, JSON.stringify([{ id: "A7", session: DEFAULT_SESSION, text: "Question" }]));
    await withEnv({ KIDO_FAKE_ASKS_DELAY_MS: "400" }, async () => {
      const s = await settlesWithin(startSession(fx, { factory: await freshExtensions() }), 200);
      const render = () => s.widgets.get("kido-asks")?.content?.(null, fakeTheme).render(80).join("\n") ?? "";
      assert.equal(render(), "");
      await pollUntil(() => render().includes("Question"), 3000, "the initial ask widget");
      writeFileSync(file, JSON.stringify([{ id: "A7", session: DEFAULT_SESSION, text: "Changed" }]));
      assert.equal(await settlesWithin(sendToInbox(s.inboxPath, envelope("asks", "")), 200), "ok");
      assert.doesNotMatch(render(), /Changed/);
      await pollUntil(() => render().includes("Changed"), 3000, "the invalidated ask widget");
    });
  } finally {
    await fx.restore();
  }
});

test("user ask widgets discard an old instance's pending refresh across reload", async () => {
  const fx = makeFixture();
  try {
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    const old = await startSession(fx, { factory: await freshExtensions() });
    await pollUntil(() => old.widgets.has("kido-asks"), 2000, "the initial refresh to finish");
    const file = join(dirname(fx.runsDir), "asks.json");
    await withEnv({ KIDO_FAKE_ASKS_DELAY_MS: "150" }, async () => {
      writeFileSync(file, JSON.stringify([{ id: "A7", session: DEFAULT_SESSION, text: "Old question" }]));
      const pending = sendToInbox(old.inboxPath, envelope("asks", ""));
      await pollUntil(() => readFileSync(file + ".read", "utf8").includes("Old question"), 2000, "the old instance's snapshot to be read");
      await old.emit("session_shutdown", { reason: "reload" });
      process.env.KIDO_FAKE_ASKS_DELAY_MS = "0";
      writeFileSync(file, JSON.stringify([{ id: "A7", session: DEFAULT_SESSION, text: "New question" }]));
      await startSessionCore(fx, await freshExtensions(), () => fakeCtx(DEFAULT_SESSION, old.ui));
      await pollUntil(() => /New question/.test(old.widgets.get("kido-asks")?.content?.(null, fakeTheme).render(80).join("\n") ?? ""), 2000, "the ask widget refresh");
      assert.equal(await pending, "ok");
      await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the stale refresh to finish");
      assert.match(old.widgets.get("kido-asks")?.content?.(null, fakeTheme).render(80).join("\n") ?? "", /New question/);
    });
  } finally {
    await fx.restore();
  }
});

test("asks fallback applies text-only branch decisions and queues a notice", async () => {
  const fx = makeFixture();
  try {
    const branch: any[] = [
      { id: "old", type: "message", message: { role: "user", content: "old context" } },
      { id: "set", type: "message", message: { role: "toolResult", toolName: "set_asks", isError: false, content: [{ type: "text", text: "tool output" }] } },
      { id: "user", type: "message", message: { role: "user", content: "Ship Monday." } },
      { id: "stray", type: "custom", customType: "kido-asks-set", data: { through: "not-on-branch" } },
      { id: "notice", type: "custom_message", content: "Review complete", details: { from: "reviewer" } },
      { id: "assistant", type: "message", message: { role: "assistant", content: [{ type: "thinking", thinking: "secret" }, { type: "toolCall", name: "bash" }, { type: "text", text: "Which colour?" }] } },
    ];
    const file = join(dirname(fx.runsDir), "asks.json");
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    writeFileSync(file, JSON.stringify([{ id: "A1", text: "Ship now?", session: DEFAULT_SESSION }]));
    let input: any;
    let ctx: any;
    const s = await startSessionCore(fx, await freshExtensions(), (c) => {
      c.pi.appendEntry = (customType, data) => { branch.push({ id: "marker", type: "custom", customType, data }); };
      ctx = { ...fakeCtx(DEFAULT_SESSION, c.ui), sessionManager: { ...fakeCtx().sessionManager, getBranch: () => branch, getLeafId: () => branch.at(-1)?.id }, modelRegistry: {
        find: (provider: string, id: string) => { assert.equal(`${provider}/${id}`, "claude-bridge/claude-haiku-5-5"); return {}; },
        hasConfiguredAuth: () => true,
        complete: async (_model: unknown, context: any, options: any) => { input = JSON.parse(context.messages[0].content); assert.ok(options.signal instanceof AbortSignal); return { content: [{ type: "text", text: '```json\n[{"text":"Which colour?"},{"id":"foreign","text":"Bad"}]\n```' }] }; },
      } };
      return ctx;
    });
    await s.emit("agent_start", {}, ctx);
    await s.emit("agent_end", { messages: [] }, ctx);
    await pollUntil(() => s.messages.length === 1, 2000, "fallback notice");
    assert.deepEqual(input, { asks: [{ id: "A1", text: "Ship now?" }], messages: "user: Ship Monday.\n\nuser (reviewer): Review complete\n\nassistant: Which colour?" });
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).map(({ id, text }: any) => ({ id, text })), [{ id: "A7", text: "Which colour?" }]);
    assert.deepEqual(s.messages[0].opts, { deliverAs: "nextTurn" });
    assert.match(s.messages[0].message.content, /kido updated your open asks: A7: Which colour/);
    assert.equal(s.messages[0].message.display, false);
    assert.equal(branch.at(-1).data.through, "assistant");
  } finally { await fx.restore(); }
});

test("asks fallback reads persisted branch boundaries and keeps the recent 16 KB", async () => {
  const fx = makeFixture();
  try {
    const branch: any[] = [
      { id: "old", type: "message", message: { role: "user", content: "before the set" } },
      { id: "boundary", type: "message", message: { role: "assistant", content: [{ type: "text", text: "old reply" }] } },
      { id: "marker", type: "custom", customType: "kido-asks-set", data: { through: "boundary" } },
      { id: "new", type: "message", message: { role: "user", content: "cut this old end " + "é".repeat(10000) + " recent answer" } },
      { id: "failed", type: "message", message: { role: "toolResult", toolName: "set_asks", isError: true, content: [{ type: "text", text: "failed tool output" }] } },
    ];
    let input: any;
    let ctx: any;
    const s = await startSessionCore(fx, await freshExtensions(), (c) => {
      ctx = { ...fakeCtx(DEFAULT_SESSION, c.ui), sessionManager: { ...fakeCtx().sessionManager, getBranch: () => branch, getLeafId: () => "failed" }, modelRegistry: {
        find: () => ({}), hasConfiguredAuth: () => true,
        complete: async (_model: unknown, context: any) => { input = JSON.parse(context.messages[0].content); return { content: [{ type: "text", text: "[]" }] }; },
      } };
      return ctx;
    });
    await s.emit("agent_end", { messages: [] }, ctx);
    await pollUntil(() => input !== undefined, 2000, "branch model input");
    assert.deepEqual(input.asks, []);
    assert.ok(Buffer.byteLength(input.messages) <= 16384);
    assert.match(input.messages, /recent answer$/);
    assert.doesNotMatch(input.messages, /before the set|old reply|cut this old end|failed tool output|�/);
  } finally { await fx.restore(); }
});

for (const mode of ["called", "disabled", "unchanged", "in-flight"] as const) {
  test(`asks fallback ${mode}`, async () => {
    const fx = makeFixture();
    try {
      await withEnv({ KIDO_ASKS_MODEL: mode === "disabled" ? "" : "fake/model" }, async () => {
        let calls = 0;
        let finish: (value: any) => void = () => {};
        let completed = false;
        let writes = 0;
        const file = join(dirname(fx.runsDir), "asks.json");
        const existing = [{ id: "A1", text: "First?", session: DEFAULT_SESSION }, { id: "A2", text: "Second?", session: DEFAULT_SESSION }];
        if (mode === "unchanged") {
          mkdirSync(dirname(file), { recursive: true });
          writeFileSync(file, JSON.stringify(existing));
        }
        let ctx: any;
        const s = await startSessionCore(fx, await freshExtensions(), (c) => {
          c.pi.appendEntry = () => { writes++; };
          const branch = [{ id: "user", type: "message", message: { role: "user", content: "Done?" } }];
          ctx = { ...fakeCtx(DEFAULT_SESSION, c.ui), sessionManager: { ...fakeCtx().sessionManager, getBranch: () => branch, getLeafId: () => branch.at(-1)?.id ?? null }, modelRegistry: {
            find: () => ({}), hasConfiguredAuth: () => true,
            complete: async () => { calls++; const result = mode === "in-flight" ? await new Promise((resolve) => { finish = resolve; }) : { content: [{ type: "text", text: JSON.stringify(existing.toReversed().map(({ id, text }) => ({ id, text }))) }] }; completed = true; return result; },
          } };
          return ctx;
        });
        await s.emit("agent_start", {}, ctx);
        if (mode === "called") await s.tools.get("set_asks").execute("set", { asks: [] }, undefined, undefined, ctx);
        await s.emit("agent_end", { messages: [] }, ctx);
        if (mode === "in-flight") {
          await pollUntil(() => calls === 1, 2000, "in-flight model call");
          await s.emit("agent_end", { messages: [] }, ctx);
          assert.equal(calls, 1, "only one fallback runs");
          await s.tools.get("set_asks").execute("set", { asks: [{ text: "New decision?" }] }, undefined, undefined, ctx);
          finish({ content: [{ type: "text", text: '[{"text":"Stale decision?"}]' }] });
          await pollUntil(() => completed, 2000, "model result");
        }
        await pollUntil(() => completed || [...commandWork.values()].every((work) => work.size === 0), 2000, "the fallback decision to settle");
        assert.equal(calls, ["unchanged", "in-flight"].includes(mode) ? 1 : 0);
        assert.equal(writes, ["called", "in-flight", "unchanged"].includes(mode) ? 1 : 0);
        if (mode === "in-flight") assert.equal(JSON.parse(readFileSync(file, "utf8"))[0].text, "New decision?", "an in-flight fallback must not overwrite set_asks");
        else if (mode === "unchanged") assert.equal(readFileSync(file, "utf8"), JSON.stringify(existing));
        else if (mode !== "called") assert.equal(existsSync(file), false, "skipped fallback writes nothing");
        assert.equal(s.messages.length, 0);
      });
    } finally { await fx.restore(); }
  });
}

// The four guard clauses share one "nothing happens" assertion: no model
// call, no write, no file. One fixture drives all four.
test("asks fallback guard clauses do nothing", async () => {
  const fx = makeFixture();
  try {
    const file = join(dirname(fx.runsDir), "asks.json");
    let calls = 0;
    let writes = 0;
    const branch = [{ id: "user", type: "message", message: { role: "user", content: "Done?" } }];
    for (const mode of ["missing-model", "no-auth", "no-text", "headless"]) {
      let ctx: any;
      const s = await startSessionCore(fx, await freshExtensions(), (c) => {
        c.pi.appendEntry = () => { writes++; };
        ctx = {
          ...fakeCtx(DEFAULT_SESSION, c.ui),
          hasUI: mode !== "headless",
          sessionManager: { ...fakeCtx().sessionManager, getBranch: () => mode === "no-text" ? [] : branch, getLeafId: () => branch.at(-1)?.id ?? null },
          modelRegistry: {
            find: () => mode === "missing-model" ? undefined : {},
            hasConfiguredAuth: () => mode !== "no-auth",
            complete: async () => { calls++; return { content: [{ type: "text", text: "[]" }] }; },
          },
        };
        return ctx;
      });
      await s.emit("agent_start", {}, ctx);
      await s.emit("agent_end", { messages: [] }, ctx);
      await s.emit("session_shutdown", { reason: "new" });
    }
    await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the guard clauses to finish");
    assert.equal(calls, 0, "no guard clause calls the model");
    assert.equal(writes, 0, "and none writes a fallback");
    assert.equal(existsSync(file), false, "none creates the asks file");
  } finally { await fx.restore(); }
});

test("a new run discards the previous run's pending asks fallback", async () => {
  const fx = makeFixture();
  try {
    const { s, ctx, replies, marks, file } = await startDeferredFallback(fx);
    await s.emit("agent_start", {}, ctx);
    await s.emit("agent_end", { messages: [] }, ctx);
    await pollUntil(() => replies.length === 1, 2000, "the first run's model call");
    await s.emit("agent_start", {}, ctx);
    await s.emit("agent_end", { messages: [] }, ctx);
    await pollUntil(() => replies.length === 2, 2000, "the second run's model call");
    replies[0]('[{"text":"Stale decision?"}]');
    replies[1]('[{"text":"Current decision?"}]');
    await pollUntil(() => s.messages.length === 1, 2000, "the second run's notice");
    await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the fallback write to finish");
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).map((a: any) => a.text), ["Current decision?"]);
    assert.equal(marks.length, 1);
  } finally { await fx.restore(); }
});

test("asks fallback drops a write that a session switch overtakes", async () => {
  const fx = makeFixture();
  try {
    await withEnv({ KIDO_FAKE_SET_DELAY_MS: "150" }, async () => {
      const { s, ctx, replies, marks, file } = await startDeferredFallback(fx);
      await s.emit("agent_end", { messages: [] }, ctx);
      await pollUntil(() => replies.length === 1, 2000, "the model call");
      replies[0]('[{"text":"Old session decision?"}]');
      await pollUntil(() => existsSync(file + ".setting"), 2000, "the fallback write to start");
      await s.emit("session_start", {}, fakeCtx("other-session", s.ui));
      await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the overtaken fallback write to finish");
      assert.deepEqual(marks, []);
      assert.equal(s.messages.length, 0);
    });
  } finally { await fx.restore(); }
});

test("asks fallback drops its result when the stored asks changed during the request", async () => {
  const fx = makeFixture();
  try {
    const { s, ctx, replies, marks, file } = await startDeferredFallback(fx);
    await s.emit("agent_end", { messages: [] }, ctx);
    await pollUntil(() => replies.length === 1, 2000, "the model call");
    const external = JSON.stringify([{ id: "A9", text: "Set from bash?", session: DEFAULT_SESSION }]);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, external);
    replies[0]('[{"text":"Stale decision?"}]');
    await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the stale fallback write to finish");
    assert.equal(readFileSync(file, "utf8"), external);
    assert.deepEqual(marks, []);
    assert.equal(s.messages.length, 0);
  } finally { await fx.restore(); }
});

test("user ask tools follow root child root identity changes in one runtime", async () => {
  const fx = makeFixture();
  try {
    await asSubagent(DEFAULT_SESSION, async () => {
      const s = await startSession(fx, { factory: await freshExtensions(), sessionId: "nested-root" });
      assert.equal(s.tools.get("set_asks").exposure, "direct");
      const rootAsk = s.tools.get("set_asks");
      await s.emit("session_start", {}, fakeCtx(DEFAULT_SESSION, s.ui));
      assert.equal(s.tools.get("set_asks").exposure, "hidden");
      await assert.rejects(rootAsk.execute("ask", { asks: [{ text: "Question" }] }, undefined, undefined, fakeCtx()), /top-level agents only/);
      await s.emit("session_start", {}, fakeCtx("nested-root", s.ui));
      assert.equal(s.tools.get("set_asks").exposure, "direct");
      const result = await s.tools.get("set_asks").execute("ask", { asks: [{ text: "Root question" }] }, undefined, undefined, fakeCtx("nested-root"));
      assert.equal(result.content[0].text, "A7: Root question");
      await s.tools.get("set_asks").execute("clear", { asks: [] }, undefined, undefined, fakeCtx("nested-root"));
    });
  } finally {
    await fx.restore();
  }
});

test("user ask widget keeps the latest refresh when inbox invalidations overlap", async () => {
  const fx = makeFixture();
  try {
    mkdirSync(dirname(fx.runsDir), { recursive: true });
    const s = await startSession(fx, { factory: await freshExtensions() });
    await pollUntil(() => s.widgets.has("kido-asks"), 2000, "the initial refresh to finish");
    const file = join(dirname(fx.runsDir), "asks.json");
    await withEnv({ KIDO_FAKE_ASKS_DELAY_MS: "150" }, async () => {
      writeFileSync(file, JSON.stringify([{ id: "A7", session: DEFAULT_SESSION, text: "Old question" }]));
      const first = sendToInbox(s.inboxPath, envelope("asks", ""));
      await pollUntil(() => readFileSync(file + ".read", "utf8").includes("Old question"), 2000, "the older snapshot to be read");
      process.env.KIDO_FAKE_ASKS_DELAY_MS = "0";
      writeFileSync(file, JSON.stringify([{ id: "A7", session: DEFAULT_SESSION, text: "New question" }]));
      assert.equal(await sendToInbox(s.inboxPath, envelope("asks", "")), "ok");
      await pollUntil(() => /New question/.test(s.widgets.get("kido-asks")?.content?.(null, fakeTheme).render(80).join("\n") ?? ""), 2000, "the ask widget refresh");
      assert.equal(await first, "ok");
      await pollUntil(() => [...commandWork.values()].every((work) => work.size === 0), 2000, "the overlapping refresh to finish");
      assert.match(s.widgets.get("kido-asks")?.content?.(null, fakeTheme).render(80).join("\n") ?? "", /New question/);
    });
    assert.equal(s.messages.length, 0);
    assert.equal(s.delivered.length, 0);
  } finally {
    await fx.restore();
  }
});

async function startDeferredFallback(fx: Fixture) {
  const replies: Array<(text: string) => void> = [];
  const marks: unknown[] = [];
  const branch = [{ id: "user", type: "message", message: { role: "user", content: "Ship Monday." } }];
  let ctx: any;
  const s = await startSessionCore(fx, await freshExtensions(), (c) => {
    c.pi.appendEntry = (_customType: string, data: unknown) => { marks.push(data); };
    ctx = { ...fakeCtx(DEFAULT_SESSION, c.ui), sessionManager: { ...fakeCtx().sessionManager, getBranch: () => branch, getLeafId: () => "user" }, modelRegistry: {
      find: () => ({}), hasConfiguredAuth: () => true,
      complete: () => new Promise((resolve) => replies.push((text) => resolve({ content: [{ type: "text", text }] }))),
    } };
    return ctx;
  });
  return { s, ctx, replies, marks, file: join(dirname(fx.runsDir), "asks.json") };
}
