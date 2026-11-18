import { test } from "node:test";
import assert from "node:assert/strict";
import { makeFixture, selfPane, pollUntil } from "./koa-agent-fixture.ts";
import { handleMessage, openInbox } from "./koa-inbox.ts";
import type { InProcessMessage } from "./records.ts";

type Api = Parameters<typeof handleMessage>[0];
const pane = { type: "pane", pane: "pane_2", session: "boss-session", name: "boss" } as const;
const api = (value: object): Api => Object.assign(Object.create(null), value);
const message = (extra: object): Api => api({ seq: 1, id: "message-id-1", kind: "message", text: "hello", from: pane, relation: "sibling", ...extra });

function recorder() {
  const log: Array<{ to: string | undefined; message: InProcessMessage }> = [];
  const selects: string[] = [];
  const closes: string[] = [];
  let stops = 0;
  return {
    log, selects, closes, stops: () => stops,
    dispatch: { message: async (to: string | undefined, m: InProcessMessage) => { log.push({ to, message: m }); return to === "gone" ? "refuse" as const : "ack" as const; }, select: (record: string) => { selects.push(record); }, close: (record: string) => { closes.push(record); }, stop: () => { stops++; } },
  };
}

test("data.to picks the agent, data.from names the sender with its return address, and a malformed address is refused", async () => {
  const r = recorder();
  assert.equal(await handleMessage(message({}), r.dispatch), "ack");
  assert.equal(await handleMessage(message({ data: { to: "kid-session", from: { session: "0123456789abcdef", name: "reviewer" }, runtime: "dev" } }), r.dispatch), "ack");
  assert.equal(await handleMessage(message({ data: { to: "gone" } }), r.dispatch), "refuse");
  assert.equal(await handleMessage(message({ data: { to: 7 } }), r.dispatch), "refuse");
  assert.equal(await handleMessage(message({ data: { from: { session: "x" } } }), r.dispatch), "refuse");
  assert.deepEqual(r.log.map(entry => entry.to), [undefined, "kid-session", "gone"]);
  assert.deepEqual(r.log[0]?.message, { kind: "message", text: "hello", agent: { name: "boss", session: "boss-session", pane: "pane_2" }, relation: "sibling" });
  assert.deepEqual(r.log[1]?.message, { kind: "message", text: "hello", agent: { name: "reviewer", session: "0123456789abcdef", pane: "pane_2" }, relation: "sibling", runtime: "dev", returnTo: { session: "0123456789abcdef", pane: "pane_2" } });
});

test("a user text is plain, a select and a close act only for the user, and a stop with a target is refused", async () => {
  const r = recorder();
  const user = { type: "user" } as const;
  assert.equal(await handleMessage(api({ seq: 1, id: "user-id-0001", kind: "user", text: "typed", from: user }), r.dispatch), "ack");
  assert.deepEqual(r.log[0]?.message, { kind: "user", text: "typed" });
  assert.equal(await handleMessage(api({ seq: 2, id: "select-id-01", kind: "select", text: "agents/kid", from: user }), r.dispatch), "ack");
  assert.equal(await handleMessage(api({ seq: 3, id: "select-id-02", kind: "select", text: "agents/kid", from: pane, relation: "sibling" }), r.dispatch), "ack");
  assert.deepEqual(r.selects, ["agents/kid"]);
  assert.equal(await handleMessage(api({ seq: 6, id: "close-id-001", kind: "close", text: "agents/kid", from: user }), r.dispatch), "ack");
  assert.equal(await handleMessage(api({ seq: 7, id: "close-id-002", kind: "close", text: "agents/kid", from: pane, relation: "sibling" }), r.dispatch), "ack");
  assert.deepEqual(r.closes, ["agents/kid"]);
  assert.equal(await handleMessage(api({ seq: 4, id: "stop-id-0001", kind: "stop", text: "", from: user, data: { to: "kid" } }), r.dispatch), "refuse");
  assert.equal(r.stops(), 0);
  assert.equal(await handleMessage(api({ seq: 5, id: "stop-id-0002", kind: "stop", text: "", from: user }), r.dispatch), "ack");
  assert.equal(r.stops(), 1);
});

test("the stream acks what it delivered once, acks a repeat without delivering it, and survives a dropped stream", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    const r = recorder();
    const inbox = openInbox("ko", "pane_1", r.dispatch, async () => {});
    await pollUntil(() => fx.streamOpens("/panes/pane_1/messages") === 1, 2000, "the stream");
    fx.feed({ id: "once-0001", kind: "user", text: "hello", from: { type: "user" } });
    await pollUntil(() => fx.acks().length === 1, 2000, "the ack");
    assert.deepEqual(fx.acks(), [{ type: "ack", id: "once-0001" }]);
    fx.feedRaw({ id: "weird-0001", kind: "weird", text: "?", relation: "sibling" });
    await pollUntil(() => fx.acks().length === 2, 2000, "the refusal");
    assert.deepEqual(fx.acks().at(-1), { type: "refuse", id: "weird-0001" });
    fx.forgetAcks();
    fx.dropStream();
    await pollUntil(() => fx.streamOpens("/panes/pane_1/messages") === 2, 2000, "the stream to open again");
    await pollUntil(() => fx.acks().some(ack => ack.id === "once-0001"), 2000, "the repeat to be acked");
    assert.deepEqual(r.log.map(entry => entry.message.kind), ["user"], "a repeat is acked and not delivered again");
    inbox.close();
  } finally {
    await fx.restore();
  }
});
