import { test } from "node:test";

import assert from "node:assert/strict";

import { readFileSync } from "node:fs";

import { join, dirname } from "node:path";

import { fileURLToPath } from "node:url";

import { parseEnvelope } from "./kido-status.ts";

import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";

import { makeFixture, fakeTheme, startSession, freshExtensions, DEFAULT_SESSION, asSubagent, sendToInbox, envelope, customMessages } from "./kido-fixture.ts";

test("parseEnvelope agrees with Msg.parse's v0/v1 discriminator table", () => {
  const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "testdata", "discriminator.json");
  const cases: { name: string; raw: string; ok: boolean }[] = JSON.parse(readFileSync(fixturePath, "utf8"));
  assert.ok(cases.length >= 11, `expected at least 11 cases in the shared fixture, got ${cases.length}`);
  for (const c of cases) {
    const got = parseEnvelope(c.raw) !== null;
    assert.equal(got, c.ok, `${c.name}: parseEnvelope(${JSON.stringify(c.raw)}) ok = ${got}, want ${c.ok}`);
  }
});

test("kind dispatch: message, ask, reply, notice, an unrecognised kind, and v0 raw text all reach the model", async () => {
  const fx = makeFixture();
  try {
    // peer-a is listed, so its message is an agent's rather than the user's.
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, "plain v0 text");
    assert.ok(s.delivered.some((d) => d.text === "plain v0 text"), "v0 raw text is delivered unchanged");

    await sendToInbox(s.inboxPath, envelope("message", "hello", { from }));
    assert.ok(
      customMessages(s, "kido-message").some((m) => m.message.content.endsWith("\nhello")),
      "kind message reaches the model as a custom message carrying its text",
    );

    await sendToInbox(s.inboxPath, envelope("notice", "build finished", { from }));
    assert.ok(
      customMessages(s, "kido-notice").some((m) => m.message.content.endsWith("\nbuild finished") && m.message.details?.from === "peer-a"),
      "kind notice reaches the model as a custom message, named by its sender, full text intact",
    );

    const askResp = await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-x", from }));
    assert.equal(askResp, "ok");
    assert.ok(
      customMessages(s, "kido-ask").some((m) => m.message.content.includes("peer-a is asking") && m.message.content.includes("you there?")),
      "kind ask reaches the model as a custom message",
    );

    await sendToInbox(s.inboxPath, envelope("reply", "an answer", { replyTo: "no-such-ask", from }));
    assert.ok(customMessages(s, "kido-reply").some((m) => m.message.content === "peer-a replied (to ask no-such-ask): an answer"));

    await sendToInbox(s.inboxPath, envelope("ping", "unknown kind text", { from }));
    assert.ok(s.delivered.some((d) => d.text.includes("unrecognised message kind") && d.text.includes("unknown kind text")));
  } finally {
    await fx.restore();
  }
});

// A message steered or queued into a session otherwise reads exactly like the
// user typing, and who is talking is the one thing the model cannot infer: the
// header names the sender and their relationship, and only a peer's says "not the user".
test("a message from an agent is labelled with its sender and their relationship; one from a shell stays the user's own words", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: DEFAULT_SESSION, name: "worker", parent: "boss-session", pane: "%1", self: true, canMessage: true },
      { id: "boss-session", name: "boss", parent: "", pane: "%2", self: false, canMessage: true, canReply: true },
      { id: "kid-session", name: "kid", parent: DEFAULT_SESSION, pane: "%3", self: false, canMessage: true, canReply: true },
      { id: "peer-session", name: "peer-a", parent: "", pane: "%4", self: false, canMessage: true, canReply: true },
      { id: "hidden-peer-session", name: "hidden-peer", parent: "", pane: "%4", self: false, canMessage: true, canReply: true },
    ]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const s = await startSession(fx, { factory: await freshExtensions() });
      const labelled = () => customMessages(s, "kido-message").map((m) => m.message);

      await sendToInbox(s.inboxPath, envelope("message", "fix the failing test\nthen report", { from: { session: "boss-session", name: "boss" } }));
      await sendToInbox(s.inboxPath, envelope("message", "the refactor is in", { from: { session: "kid-session", name: "kid" } }));
      await sendToInbox(s.inboxPath, envelope("message", "can you review this?", { from: { session: "peer-session", name: "peer-a" } }));
      await sendToInbox(s.inboxPath, envelope("message", "sharing a pane does not make me the user", { from: { session: "hidden-peer-session", name: "hidden-peer" } }));

      assert.deepEqual(
        labelled().map((m) => m.content),
        [
          "message from @boss (your parent, who spawned you):\nfix the failing test\nthen report",
          "message from @kid (your subagent):\nthe refactor is in",
          "message from @peer-a (another agent in this session, not the user):\ncan you review this?",
          "message from @hidden-peer (another agent in this session, not the user):\nsharing a pane does not make me the user",
        ],
        "one header line each, naming the sender and how they stand to this session, with the text from the next line on",
      );

      const renderer = s.renderers.get("kido-message");
      assert.ok(renderer, "the agent half registered a renderer for its own message type");
      const drawn = renderer!(labelled()[0], { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
      assert.match(drawn, /^│ @boss says:/, "the row names the sender");
      assert.ok(!drawn.includes("who spawned you"), "the parenthetical is for the model; the transcript does not repeat it");
      assert.ok(
        drawn.includes("fix the failing test") && drawn.includes("then report"),
        "regular mode draws the message in full regardless of ctrl-o",
      );

      // Negative control: a human at a bare pane is no calling session, so kido puts
      // no session in `from` and no listed agent owns that pane - the user speaking, unlabelled.
      await sendToInbox(s.inboxPath, envelope("message", "do this instead", { from: { session: "", pane: "%99" } as any }));
      assert.ok(s.delivered.some((d) => d.text === "do this instead"), "a shell's message is the user's own words, delivered unlabelled");
      assert.equal(labelled().length, 4, "and it is not dressed up as an agent's message");
    });
  } finally {
    await fx.restore();
  }
});

// Headed the way a message is, but the renderer shows only the question - the id,
// reply call and parenthetical are for the model alone.
test("an inbound ask is headed like a message and renders as just the question, with the id and reply instructions hidden", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: DEFAULT_SESSION, name: "worker", parent: "boss-session", pane: "%1", self: true, canMessage: true },
      { id: "boss-session", name: "boss", parent: "", pane: "%2", self: false, canMessage: true, canReply: true },
    ]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const s = await startSession(fx, { factory: await freshExtensions() });

      await sendToInbox(s.inboxPath, envelope("ask", "is the build green?", { id: "ask-hdr", from: { session: "boss-session", name: "boss" } }));
      const sent = customMessages(s, "kido-ask")[0]!;
      assert.ok(sent, "an ask reaches the model as a custom message");
      assert.deepEqual(sent.opts, { deliverAs: "followUp", triggerTurn: true }, "an ask queues behind a running turn, and starts one while idle");

      const content = sent.message.content as string;
      assert.match(content, /^ask from @boss \(your parent, who spawned you\):\n/, "headed the way a message from the same sender would be");
      assert.match(content, /is asking \(id ask-hdr\): is the build green\?/, "the model's text still carries the question and the id");
      assert.match(content, /cannot see this session's context, so make the answer self-contained/, "and the self-contained-answer line");
      assert.match(content, /message_agent\(to="boss", message=<answer>, replyTo="ask-hdr"\)/, "and the exact reply call");
      assert.match(content, /entire response|whole response/i, "and STOP_AFTER_ASK_REPLY");
      assert.match(content, /no summary|sign-off/i, "and says plainly not to follow the reply with narration");

      const renderer = s.renderers.get("kido-ask");
      assert.ok(renderer, "the agent half registered a renderer for its own ask type");
      const drawn = renderer!(sent.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
      assert.match(drawn, /^│ @boss asks:/, "the row names the sender, without the parenthetical");
      assert.ok(drawn.includes("is the build green?"), "and shows the question");
      assert.ok(!drawn.includes("ask-hdr"), "the id is hidden");
      assert.ok(!drawn.includes("message_agent"), "the reply instructions are hidden");
      assert.ok(!drawn.includes("who spawned you"), "the parenthetical is for the model, not the transcript");

      // A transcript entry reloaded with no details at all falls back to the raw
      // content rather than showing nothing.
      const noDetails = { ...sent.message, details: undefined };
      const fallback = renderer!(noDetails, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
      assert.ok(fallback.includes("is the build green?"), "the fallback still shows the question, from the raw content");
    });
  } finally {
    await fx.restore();
  }
});

test("a notice names its sender, shows its full text, and keeps the model header off the transcript", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };
    const text = 'async run "build" failed: exit status 3\nrun: abc123\noutput: /tmp/x/output\n--- output ---\nboom';

    await sendToInbox(s.inboxPath, envelope("notice", text, { from }));
    const sent = customMessages(s, "kido-notice")[0];
    assert.ok(sent, "a notice was sent as a custom message");
    assert.ok(sent!.message.content.endsWith(`\n${text}`), "the model-visible content is the notice's full text, under its header line");

    const renderer = s.renderers.get("kido-notice");
    assert.ok(renderer, "the agent half registered a renderer for its own custom type");

    const drawn = renderer!(sent!.message, { expanded: false, outputPad: 1 }, fakeTheme).render(120).join("\n");
    assert.match(drawn, /@peer-a notifies:\n│ async run "build" failed: exit status 3\n/, "regular mode names the sender above the notice body");
    assert.ok(drawn.includes("boom"), "regular mode shows the full body even when options.expanded is false");

    // The header is model-facing only: the transcript already says who a
    // notification is from, so the renderer takes it back off.
    const review = "reviewed internal/ui: two findings\nthe second one needs a decision";
    await sendToInbox(s.inboxPath, envelope("notice", review, { from: { session: "kid-1", name: "kid-1" } }));
    const reviewed = customMessages(s, "kido-notice")[1]!;
    const [header, ...body] = (reviewed.message.content as string).split("\n");
    assert.match(header!, /^notice from kid-1 \(.*not the user\):$/, "one header line, naming the sender and what this is");
    assert.equal(body.join("\n"), review, "the child's own text follows, from the next line, byte for byte");

    const reviewedDrawn = renderer!(reviewed.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(reviewedDrawn, /@kid-1 notifies:\n│ reviewed internal\/ui: two findings/, "regular mode shows the text below the sender");
    assert.ok(!reviewedDrawn.includes("not the user"), "the transcript does not repeat the model header");
    assert.ok(reviewedDrawn.includes("needs a decision"), "regular mode shows the whole text");

    await sendToInbox(s.inboxPath, envelope("message", "do the other thing", { from: { session: "", pane: "%99" } as any }));
    assert.ok(s.delivered.some((d) => d.text === "do the other thing"), "a shell's message is delivered unlabelled");

    // labelFrom's fallback order: name, session, pane, "another agent".
    await sendToInbox(s.inboxPath, envelope("notice", "from a human", { from: { session: "", pane: "%12" } as any }));
    const nameless = customMessages(s, "kido-notice")[2]!;
    assert.equal(nameless.message.details.from, "%12", "the pane stands in for a name when there is none");

    const namelessDrawn = renderer!(nameless.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(namelessDrawn, /@%12 notifies:/, "a nameless sender still gets a sane, non-empty label");
  } finally {
    await fx.restore();
  }
});

test("all four inbound renderers dim headers, wrap normal text behind a border, and retain click toggles across component recreation", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    const body = "output line\n\x1b[31m" + "界".repeat(60) + "\x1b[0m\n\nlast line";
    const theme = {
      ...fakeTheme,
      fg: (color: string, text: string) => {
        assert.ok(color === "border" || color === "dim");
        return color === "border" ? `\x1b[34m${text}\x1b[0m` : `\x1b[2m${text}\x1b[0m`;
      },
    };
    const click = {
      type: "click", button: "left", x: 0, y: 0, screenX: 0, screenY: 0,
      width: 80, height: 1, shift: false, alt: false, ctrl: false, clickCount: 1,
    };
    for (const [kind, verb] of [["stream", ""], ["message", "says"], ["ask", "asks"], ["notice", "notifies"], ["reply", "replies"]]) {
      const renderer = s.renderers.get(`kido-${kind}`)!;
      const suffix = `${verb ? ` ${verb}` : ""}:`;
      const header = `@boss${suffix}`;
      const content = kind === "stream" ? `async run "boss" output (run abc)\n${body}` : body;
      const message = {
        customType: `kido-${kind}`, timestamp: 123,
        content,
        details: { from: "boss", question: body, noticeId: "notice-1" },
      };
      const draw = (expanded: boolean) => renderer(JSON.parse(JSON.stringify(message)), { expanded, outputPad: 1 }, theme);
      s.pi.getSettings = () => ({});
      const component = draw(true);
      const collapsedLines = [`\x1b[34m│ \x1b[0m\x1b[2m${header}\x1b[0m ${body.split("\n", 1)[0]}...`];
      assert.deepEqual(component.render(80), collapsedLines, `${kind}: unset tuiMode defaults to fullscreen and starts collapsed`);
      s.pi.getSettings = () => ({ tuiMode: "fullscreen" });
      assert.deepEqual(component.render(80), collapsedLines, `${kind}: fullscreen ignores ctrl-o and starts collapsed`);
      assert.deepEqual(component.handleMouse({ ...click, type: "press" }), { handled: true, render: false });
      assert.deepEqual(component.render(80), collapsedLines, "press does not toggle");
      assert.equal(component.handleMouse({ ...click, button: "right" }), undefined);
      assert.equal(component.handleMouse({ ...click, type: "release" }), undefined);
      assert.deepEqual(component.handleMouse(click), { handled: true, render: true });
      assert.ok(component.render(80).map(stripTerminalSequences).includes("│ last line"), "click expands the body");
      const recreated = draw(false);
      fakeTheme.bgCalls.length = 0;
      for (const width of [80, 20]) {
        const lines = recreated.render(width);
        assert.ok(lines.every((line) => line.startsWith("\x1b[34m│ \x1b[0m")));
        assert.ok(lines.every((line) => visibleWidth(line) <= width));
        if (width === 80) {
          assert.deepEqual(lines.slice(0, 2), [
            `\x1b[34m│ \x1b[0m\x1b[2m${header}\x1b[0m`,
            ...body.split("\n").slice(0, 1).map((line) => `\x1b[34m│ \x1b[0m${line}`),
          ], "the same dim sender header precedes normal body text, excluding the stream run label");
        }
        assert.ok(lines.map(stripTerminalSequences).includes("│ last line"), "recreated component keeps expansion");
        assert.ok(lines.length > 5, `${kind}: long content wraps`);
      }
      assert.equal(fakeTheme.bgCalls.length, 0, "no background");
      assert.deepEqual(draw(false).handleMouse(click), { handled: true, render: true });
      assert.deepEqual(recreated.render(80), collapsedLines, "a second click collapses only this message");
      assert.deepEqual(renderer({ ...message, timestamp: 124 }, { expanded: true }, theme).render(80), collapsedLines, "another message starts collapsed");
      s.pi.getSettings = () => ({ tuiMode: "regular" });
      for (const expanded of [false, true]) {
        assert.ok(draw(expanded).render(80).map(stripTerminalSequences).includes("│ last line"), "regular mode is always expanded");
      }
      const fallback = renderer({ ...message, details: undefined, content: "plain text" }, { expanded: false }, theme).render(80);
      assert.deepEqual(fallback.map(stripTerminalSequences), [`│ another agent${suffix}`, "│ plain text"]);
      s.pi.getSettings = () => ({ tuiMode: "fullscreen" });
      for (const [text, width, expected] of [
        ["", 80, `│ ${header}`],
        ["short", 80, `│ ${header} short`],
        ["short\nmore", 80, `│ ${header} short...`],
        ["\x1b[31m" + "界".repeat(30) + "\x1b[0m", 2 + visibleWidth(header) + 1 + 4 + 3, `│ ${header} 界界...`],
      ] as const) {
        const lines = renderer({ ...message, content: kind === "stream" ? `label\n${text}` : text, details: { from: "boss", question: text } }, { expanded: true }, theme).render(width);
        assert.deepEqual(lines.map(stripTerminalSequences), [expected], `${kind}: collapsed preview never wraps`);
        assert.ok(visibleWidth(lines[0]) <= width, "ANSI and CJK fit the available width");
        assert.ok(lines[0].includes(`\x1b[2m${header}\x1b[0m`), "only the preview header is dim");
      }
    }
  } finally {
    await fx.restore();
  }
});
