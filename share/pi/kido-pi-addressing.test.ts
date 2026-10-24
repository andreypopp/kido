import { test } from "node:test";

import assert from "node:assert/strict";
import { existsSync, rmSync } from "node:fs";
import { join } from "node:path";

import { makeFixture, selfPane, agentPane, startNamedSession, asSubagent } from "./kido-pi-fixture.ts";

const SELF = "self-session";

function json(payload: string): { kind: string; id: string; text: string; from: { session: string; name?: string; pane?: string }; v?: number } {
  return JSON.parse(payload);
}

test("message_agent resolves by name, exact session id and unique prefix, and explains every refusal", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "abc123", name: "Worker-2", inbox: inbox.path }),
      agentPane({ pane: "%3", session: "abd456", title: "π - ", inbox: inbox.path }),
      agentPane({ pane: "%4", session: "worker-x", name: "scout" }),
      agentPane({ pane: "%5", session: "worker-y", name: "scout" }),
      agentPane({ pane: "%6", session: "worker-6", name: "worker-6", inbox: inbox.path }),
      agentPane({ pane: "%7", session: "elsewhere", name: "far-away", tmux: "$2", inbox: inbox.path }),
      agentPane({ pane: "%8", session: "twin-a", name: "Twin", tmux: "$2" }),
      agentPane({ pane: "%9", session: "twin-b", name: "Twin", tmux: "$2" }),
    ]);
    const s = await startNamedSession(fx, "Self");
    const message = s.tools.get("message_agent");
    const deliver = async (to: string) => (await message.execute("c", { to, message: "x" })).content[0].text;

    assert.equal(await deliver("worker-2"), "delivered to Worker-2 by inbox", "a name is caseless");
    assert.equal(await deliver("@worker-2"), "delivered to Worker-2 by inbox", "a leading @ is ignored");
    assert.equal(await deliver("worker-6"), "delivered to worker-6 by inbox");
    assert.equal(await deliver("abc123"), "delivered to Worker-2 by inbox", "an exact session id wins over a prefix");
    assert.equal(await deliver("abd"), "delivered to π -  by inbox", "a unique prefix resolves; an unnamed agent shows its title");
    assert.equal(
      await deliver("ab"),
      'could not message ab: "ab" matches several agents by id: abc123 (Worker-2), abd456 (π - )',
    );
    assert.equal(await deliver("nope"), 'could not message nope: no agent session matches "nope"');
    assert.equal(
      await deliver("scout"),
      'could not message scout: "scout" matches several agents by name: worker-x (scout), worker-y (scout)',
    );
    assert.equal(await deliver("Self"), "Self is this agent");
    assert.equal(await deliver("elsewhere"), "could not message elsewhere: elsewhere (elsewhere) is in another tmux session, not this one");
    assert.equal(
      await deliver("Twin"),
      'could not message Twin: "Twin" matches several agents by name: twin-a (Twin), twin-b (Twin), none in this tmux session',
    );
    assert.equal(
      (await message.execute("c", { to: "Worker-2", message: "bad:\ud800:end" })).content[0].text,
      "could not message Worker-2: the message is not valid UTF-8",
    );
    assert.equal(
      (await message.execute("c", { to: "Worker-2", message: "" })).content[0].text,
      "could not message Worker-2: the message is empty; nothing sent",
    );

    const received = inbox.received().map(json);
    assert.equal(received.length, 5, "the five deliveries reached the inbox; the refusals sent nothing");
    assert.deepEqual(received[0].from, { session: SELF, name: "Self", pane: "%1" });
    assert.equal(received[0].kind, "message");
    assert.equal(received[0].text, "x");
    assert.match(received[0].id, /^[0-9a-f]{32}$/, "a fresh 32-hex id");
  } finally {
    await fx.restore();
  }
});



// A plain message to a running agent waits for its turn to end, so the line
// says so rather than "delivered"; the steer hint goes only to a caller that
// could steer the target.
test("a message to a running agent says it is queued, and only a descendant gets the steer hint", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "%2", session: "busy-peer", name: "busy-peer", inbox: inbox.path, state: "working" }),
      agentPane({ pane: "%3", session: "kid-session", name: "kid", inbox: inbox.path, state: "working" }),
    ]);
    fx.writeAgent(SELF, "kid", { session: "kid-session", run: "kid-run" });
    fx.setRuns([{ id: "kid-run", name: "kid", parent: "%1", pane: "%3", session: "kid-session" }]);
    const s = await startNamedSession(fx, "caller");

    assert.equal(
      (await s.tools.get("message_agent").execute("c", { to: "busy-peer", message: "x" })).content[0].text,
      "queued for busy-peer: it is running and reads this when its current turn ends",
    );
    assert.equal(
      (await s.tools.get("message_agent").execute("c", { to: "kid", message: "x" })).content[0].text,
      "queued for kid: it is running and reads this when its current turn ends; to reach it now, use message_agent with mode steer",
    );
  } finally {
    await fx.restore();
  }
});

// The tree: root (top-level) -> mid (me) -> child -> grandchild, plus a peer
// under root. A steer reaches a descendant however deep; nothing reaches a
// peer, an ancestor or the caller.
test("message_agent modes restrict control to descendants and mark parent work", async () => {
  const fx = makeFixture();
  try {
    const inbox = await fx.startInbox();
    fx.writeAgent("root", "mid", { session: "mid" });
    fx.writeAgent("mid", "child", { session: "child" });
    fx.writeAgent("child", "grandchild", { session: "grandchild" });
    fx.writeAgent("root", "peer", { session: "peer" });
    fx.setPanes(["mid", "child", "grandchild", "peer", "root"].map((session, i) =>
      agentPane({ pane: `%${i + 1}`, session, name: session, inbox: inbox.path })));
    await asSubagent(fx, "mid", async () => {
      const s = await startNamedSession(fx, "mid", "mid");
      const message = s.tools.get("message_agent");
      for (const mode of ["message", "steer", "interrupt-and-steer"]) {
        const work = join(fx.agentDir("mid", "child"), "work");
        rmSync(work, { force: true });
        assert.equal((await message.execute("c", { to: "child", message: "new work", mode })).content[0].text, "delivered to child by inbox");
        assert.ok(existsSync(work), `${mode} marks new parent work`);
        assert.equal((await message.execute("c", { to: "grandchild", message: "deeper", mode })).content[0].text, "delivered to grandchild by inbox");
        for (const to of ["peer", "root"]) {
          const result = (await message.execute("c", { to, message: "x", mode })).content[0].text;
          assert.equal(result, mode === "message" ? `delivered to ${to} by inbox` : `${to} is not this agent's descendant`);
        }
        assert.equal((await message.execute("c", { to: "mid", message: "x", mode })).content[0].text, "mid is this agent");
      }
      assert.deepEqual(inbox.received().map(json).map(e => e.kind), ["message", "message", "message", "message", "steer", "steer", "interrupt-and-steer", "interrupt-and-steer"]);
    });
  } finally {
    await fx.restore();
  }
});

test("a control tool to a target without an inbox refuses and never pastes", async () => {
  const fx = makeFixture();
  try {
    fx.writeAgent("root", "mid", { session: "mid" });
    fx.writeAgent("mid", "mute", { session: "mute" });
    fx.setPanes([
      agentPane({ pane: "%1", session: "mid", name: "mid" }),
      agentPane({ pane: "%2", session: "mute", name: "mute" }),
    ]);
    await asSubagent(fx, "mid", async () => {
      const s = await startNamedSession(fx, "mid", "mid");
      assert.equal(
        (await s.tools.get("message_agent").execute("c", { to: "mute", message: "x", mode: "steer" })).content[0].text,
        "could not message mute: mute has no inbox to reach it on",
      );
      assert.equal(
        (await s.tools.get("message_agent").execute("c", { to: "mute", message: "x", mode: "interrupt-and-steer" })).content[0].text,
        "could not message mute: mute has no inbox to reach it on",
      );
    });
  } finally {
    await fx.restore();
  }
});
