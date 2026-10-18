import { test } from "node:test";

import assert from "node:assert/strict";

import { startSession, makeFixture, withEnv } from "./kido-pi-fixture.ts";

const activity = (fx: ReturnType<typeof makeFixture>) =>
  fx
    .optionWrites()
    .filter((w) => w.key === "@kido_activity")
    .at(-1)?.value;

test("set_status writes one sanitised line as the pane's activity option", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    const setStatus = s.tools.get("set_status");

    const result = await setStatus.execute("c1", { activity: "refactoring internal/ui" });
    assert.equal(result.content[0].text, "ok");
    assert.equal(activity(fx), "refactoring internal/ui");

    await setStatus.execute("c2", { activity: "two\nlines\tand more" });
    assert.equal(activity(fx), "two lines and more", "control bytes become spaces: an option is one line");

    await setStatus.execute("c3", { activity: "" });
    assert.equal(activity(fx), "", "the empty activity clears it");
  } finally {
    await fx.restore();
  }
});

test("set_status cuts an activity over the 256-byte cap on a rune boundary", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    const setStatus = s.tools.get("set_status");

    await setStatus.execute("c1", { activity: "x".repeat(300) });
    assert.equal(activity(fx), "x".repeat(256), "the option holds at most 256 bytes");

    await setStatus.execute("c2", { activity: "界".repeat(100) });
    const value = activity(fx)!;
    assert.equal(Buffer.byteLength(value, "utf8"), 255, "a 3-byte rune is never split");
    assert.equal(value, "界".repeat(85));
  } finally {
    await fx.restore();
  }
});

test("the activity is coalesced and follows the pane option, not a second store", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    const setStatus = s.tools.get("set_status");
    await setStatus.execute("c1", { activity: "build" });
    const writes = () => fx.optionWrites().filter((w) => w.key === "@kido_activity").length;
    const before = writes();
    await setStatus.execute("c2", { activity: "build" });
    assert.equal(writes(), before, "the same activity is not written twice");
    await setStatus.execute("c3", { activity: "test" });
    assert.equal(writes(), before + 1);
  } finally {
    await fx.restore();
  }
});

test("set_status still answers ok with no pane to write to", async () => {
  const fx = makeFixture();
  try {
    await withEnv({ TMUX_PANE: undefined }, async () => {
      const s = await startSession(fx);
      const result = await s.tools.get("set_status").execute("c1", { activity: "busy" });
      assert.equal(result.content[0].text, "ok");
      assert.equal(fx.optionWrites().filter((w) => w.key === "@kido_activity").length, 0, "no pane, no activity option");
    });
  } finally {
    await fx.restore();
  }
});
