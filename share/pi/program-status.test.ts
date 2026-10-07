import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import programStatus from "./program-status.ts";

function fixture(t: TestContext) {
  const writes: string[] = [];
  t.mock.method(process.stdout, "write", (chunk: string) => { writes.push(chunk); return true; });
  const tty = Object.getOwnPropertyDescriptor(process.stdout, "isTTY");
  Object.defineProperty(process.stdout, "isTTY", { value: true, writable: true, configurable: true });
  t.after(() => {
    if (tty) Object.defineProperty(process.stdout, "isTTY", tty);
    else Reflect.deleteProperty(process.stdout, "isTTY");
  });
  const handlers = new Map<string, (event: any, ctx: ExtensionContext) => unknown>();
  programStatus({ on: (name: string, handler: any) => handlers.set(name, handler) } as unknown as ExtensionAPI);
  let name = "Café";
  let idle = false;
  const ctx = {
    mode: "tui",
    isIdle: () => idle,
    sessionManager: { getSessionName: () => name },
  } as ExtensionContext;
  return {
    writes, ctx,
    name: (value: string) => { name = value; },
    idle: (value: boolean) => { idle = value; },
    emit: (event: string, data: object = {}) => handlers.get(event)!({ type: event, ...data }, ctx),
  };
}

test("root reports lifecycle transitions in exact OSC 7501 bytes", (t) => {
  const f = fixture(t);
  f.emit("session_start");
  f.emit("agent_start");
  f.emit("ui_prompt_start", { kind: "confirm", title: "Proceed?" });
  f.emit("ui_prompt_end");
  f.emit("session_before_compact");
  f.emit("session_compact");
  f.emit("agent_before_settle", { outcome: "completed" });
  f.emit("agent_settled");
  assert.equal(f.writes.length, 6);
  f.idle(true);
  f.emit("agent_settled");
  f.emit("agent_start");
  f.emit("agent_before_settle", { outcome: "error" });
  f.emit("agent_settled");
  f.emit("agent_start");
  f.emit("agent_before_settle", { outcome: "aborted" });
  f.emit("agent_settled");
  assert.deepEqual(f.writes, [
    "\x1b]7501;state=idle:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=blocked:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=:msg=Q29tcGFjdGluZyBjb250ZXh0\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=done:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=error:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=idle:app=pi:title=Q2Fmw6k=\x1b\\",
  ]);
});

test("idle UI prompts and manual compaction restore rest, including compaction failure", (t) => {
  const f = fixture(t);
  f.idle(true);
  f.emit("session_start");
  f.emit("ui_prompt_start");
  f.emit("ui_prompt_end");
  f.emit("session_before_compact");
  f.emit("session_compact_failed");
  assert.deepEqual(f.writes, [
    "\x1b]7501;state=idle:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=blocked:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=idle:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=:msg=Q29tcGFjdGluZyBjb250ZXh0\x1b\\",
    "\x1b]7501;state=idle:app=pi:title=Q2Fmw6k=\x1b\\",
  ]);
});

test("only TUI on a tty writes; suppressed reports do not suppress later writes", (t) => {
  const f = fixture(t);
  for (const mode of ["rpc", "json", "print"] as const) {
    f.ctx.mode = mode;
    f.emit("agent_start");
  }
  f.ctx.mode = "tui";
  process.stdout.isTTY = false;
  f.emit("agent_start");
  assert.deepEqual(f.writes, []);
  process.stdout.isTTY = true;
  f.emit("agent_start");
  assert.deepEqual(f.writes, ["\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\"]);
});

test("unchanged reports coalesce, renamed and new sessions report", (t) => {
  const f = fixture(t);
  f.emit("agent_start");
  f.emit("agent_start");
  f.emit("session_info_changed");
  f.name("new");
  f.emit("session_info_changed");
  f.emit("session_start");
  f.emit("session_start");
  assert.deepEqual(f.writes, [
    "\x1b]7501;state=working:app=pi:title=Q2Fmw6k=\x1b\\",
    "\x1b]7501;state=working:app=pi:title=bmV3\x1b\\",
    "\x1b]7501;state=idle:app=pi:title=bmV3\x1b\\",
    "\x1b]7501;state=idle:app=pi:title=bmV3\x1b\\",
  ]);
});

test("title obeys encoded and decoded limits without splitting UTF-8 or emitting controls", (t) => {
  const f = fixture(t);
  for (const title of ["a".repeat(192), "a".repeat(191) + "é", "🙂".repeat(49), "a\x00\x1b\x7f\u0085b"]) {
    f.name(title);
    f.emit("agent_start");
  }
  assert.deepEqual(f.writes, ["a".repeat(192), "a".repeat(191), "🙂".repeat(48), "ab"].map(
    (title) => `\x1b]7501;state=working:app=pi:title=${Buffer.from(title).toString("base64")}\x1b\\`,
  ));
  for (const sequence of f.writes) {
    const encoded = sequence.split("title=")[1].slice(0, -2);
    assert.ok(encoded.length <= 256);
    assert.ok(Buffer.from(encoded, "base64").length <= 192);
    assert.ok(Buffer.byteLength(sequence) <= 4096);
  }
});
