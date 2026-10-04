import assert from "node:assert/strict";
import { execFile, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { decoder, frames } from "./kido-pi-wire.ts";

const vectors = JSON.parse(readFileSync(new URL("testdata/kido-pi-frames.json", import.meta.url), "utf8"));
test("golden frames encode raw UTF-8 slices and decode across every byte boundary", () => {
  for (const vector of vectors.cases) {
    const header = vector.frames[0].slice(7).split(";")[0].split(",");
    const direction = vector.direction;
    assert.deepEqual(frames(vector.json, direction, direction === "out" ? Number(header[0]) : 1, direction === "in" ? header[0] : "", direction === "in" ? Number(header[1]) : 1), vector.frames);
    const bytes = Buffer.from(vector.frames.join(""));
    const messages: unknown[] = [];
    const decode = decoder(direction, value => messages.push(value));
    for (const byte of bytes) decode(Buffer.from([byte]));
    assert.deepEqual(messages, [JSON.parse(vector.json)]);
    for (let split = 0; split <= bytes.length; split++) {
      const result: unknown[] = [];
      const receive = decoder(direction, value => result.push(value));
      receive(bytes.subarray(0, split)); receive(bytes.subarray(split));
      assert.deepEqual(result, [JSON.parse(vector.json)]);
    }
  }
});

test("inbound frames are re-acked, deduplicated and interleaved by client; malformed bytes never become keys", () => {
  const messages: unknown[] = [], acks: unknown[] = [], keys: Buffer[] = [];
  const receive = decoder("in", value => messages.push(value), value => acks.push(value), bytes => keys.push(bytes));
  const a = frames(JSON.stringify({ type: "prompt", message: "é".repeat(400) }), "in", 1, "a", 1);
  const b = frames(JSON.stringify({ type: "snapshot" }), "in", 1, "b", 1);
  receive(Buffer.from(a[0])); receive(Buffer.from(b[0])); receive(Buffer.from(a[0]));
  for (const frame of a.slice(1)) receive(Buffer.from(frame));
  for (const frame of a) receive(Buffer.from(frame));
  assert.equal(messages.length, 2); assert.equal(acks.length, a.length * 2 + 2);
  receive(Buffer.from("\x1b]6767;bad;not base64\x07plain"));
  assert.equal(Buffer.concat(keys).toString(), "plain");
  receive(Buffer.from("\x1b")); receive(Buffer.alloc(0));
  assert.equal(Buffer.concat(keys).toString(), "plain\x1b");
});

test("pty bridge streams fake pi, snapshots, dialogs, history and restores its tty", { timeout: 15000 }, async () => {
  const bridge = fileURLToPath(new URL("kido-pi.ts", import.meta.url));
  const fake = fileURLToPath(new URL("testdata/fake-pi.ts", import.meta.url));
  const quote = (text: string) => `'${text.replaceAll("'", "'\\''")}'`;
  const dir = mkdtempSync(join(tmpdir(), "kido-pi-test-"));
  const socket = join(dir, "tmux.sock");
  const revision = execFileSync(fileURLToPath(new URL("../../scripts/install-tmux-fork.sh", import.meta.url)), ["--print-revision"], { timeout: 3000 }).toString().trim();
  const pinned = fileURLToPath(new URL(`../../build/tmux-fork/${revision}/bin/kido-tmux`, import.meta.url));
  const tmux = existsSync(pinned) ? pinned : "tmux";
  const run = (...args: string[]) => promisify(execFile)(tmux, ["-S", socket, ...args], { timeout: 3000 });
  const command = `read go; before=$(stty -g); KIDO_PI_RPC=${quote(JSON.stringify([process.execPath, fake]))} ${quote(process.execPath)} ${quote(bridge)}; after=$(stty -g); [ "$before" = "$after" ] && printf '\\nTTY_RESTORED\\n'; read go`;
  await run("-f", "/dev/null", "new-session", "-d", "-s", "test", `sh -c ${quote(command)}`);
  const child = spawn(tmux, ["-S", socket, "-C", "attach-session", "-t", "test"]);
  const messages: Record<string, any>[] = [];
  let text = "";
  const waits = new Set<() => void>();
  const receive = decoder("out", value => { messages.push(value); for (const check of waits) check(); });
  let control = "", attached = false;
  child.stdout.on("data", bytes => {
    control += bytes.toString();
    let end;
    while ((end = control.indexOf("\n")) >= 0) {
      const line = control.slice(0, end); control = control.slice(end + 1);
      if (line.startsWith("%session-changed ")) attached = true;
      const match = /^%output %\d+ (.*)$/.exec(line);
      if (match) {
        const output = Buffer.from(match[1].replace(/\\([0-7]{3})/g, (_, octal) => String.fromCharCode(parseInt(octal, 8))), "latin1");
        text += output.toString(); receive(output);
      }
    }
    for (const check of waits) check();
  });
  child.stderr.on("data", bytes => { text += bytes.toString(); });
  let msg = 0;
  async function send(value: Record<string, any>) {
    const number = ++msg;
    const chunks = frames(JSON.stringify(value), "in", 1, "test-client", number);
    for (const [index, frame] of chunks.entries()) {
      await run("send-keys", "-t", "test:0.0", "-H", ...[...Buffer.from(frame)].map(byte => byte.toString(16).padStart(2, "0")));
      await wait(() => messages.some(value => value.type === "ack" && value.msg === number && value.index === index));
    }
  }
  function wait(predicate: () => boolean) {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { waits.delete(check); reject(new Error(`pty wait timed out: ${text.slice(-2000)}`)); }, 5000);
      const check = () => { if (predicate()) { clearTimeout(timer); waits.delete(check); resolve(); } };
      waits.add(check); check();
    });
  }
  try {
    await wait(() => attached);
    await run("send-keys", "-t", "test:0.0", "Enter");
    await wait(() => messages.some(value => value.type === "hello"));
    const firstHello = messages.findIndex(value => value.type === "hello");
    assert.equal(messages.slice(0, firstHello).filter(value => value.id?.startsWith("bridge:0:")).length, 5);
    await send({ type: "prompt", id: "test-client:prompt", message: "Replay please" });
    await wait(() => messages.some(value => value.assistantMessageEvent?.type === "text_delta"));
    await send({ type: "snapshot", id: "test-client:partial" });
    await wait(() => messages.some(value => value.id === "test-client:partial"));
    const partial = messages.find(value => value.id === "test-client:partial")?.record.partialAssistant;
    assert.equal(partial.content[0].thinking, "Check the files, then make a small edit.");
    assert.ok(partial.content[1].text.startsWith("Hello! "));
    await wait(() => messages.some(value => value.type === "tool_execution_update"));
    await send({ type: "snapshot", id: "test-client:stream" });
    await wait(() => messages.some(value => value.id === "test-client:stream"));
    const streaming = messages.find(value => value.id === "test-client:stream");
    assert.ok(streaming?.record.tools["bash-1"].partialResult);
    await wait(() => messages.some(value => value.type === "agent_end"));
    await wait(() => messages.filter(value => value.type === "response" && value.command === "get_entries").length >= 5);
    await send({ type: "snapshot", id: "test-client:snapshot" });
    await wait(() => messages.some(value => value.id === "test-client:snapshot"));
    const snapshot = messages.find(value => value.id === "test-client:snapshot");
    assert.equal(snapshot?.generation, 0);
    assert.equal(snapshot?.record.entries.length, 18);
    const start = messages.find(value => value.type === "message_start");
    const end = messages.find(value => value.type === "message_end" && value.message.role === "assistant");
    assert.equal(start?.uiId, end?.uiId);
    assert.equal(snapshot?.record.entries[1].uiId, start?.uiId);
    assert.ok(snapshot?.record.entries.some((entry: any) => entry.type === "compaction"));
    assert.ok(snapshot?.record.entries.some((entry: any) => entry.message?.role === "bashExecution" && entry.uiId === "direct-1"));
    assert.deepEqual(snapshot?.record.bash, {});
    assert.equal(snapshot?.record.partialAssistant, null);
    assert.deepEqual(snapshot?.record.queues.steering, ["Check tests too"]);
    assert.ok(snapshot?.record.entries.some((entry: any) => entry.message.details?.patch));
    assert.ok(snapshot?.record.dialogs["fixture-confirm"]);
    assert.equal(snapshot?.record.models[0].id, "fixture");
    assert.deepEqual(snapshot?.record.thinkingLevels, ["off", "low", "medium", "high"]);
    await send({ type: "history", id: "test-client:history", generation: 0, before: snapshot?.record.leafId, limit: 2 });
    await wait(() => messages.some(value => value.id === "test-client:history"));
    assert.equal(messages.find(value => value.id === "test-client:history")?.entries.length, 2);
    await send({ type: "extension_ui_response", id: "fixture-confirm", confirmed: true });
    await send({ type: "extension_ui_response", id: "fixture-confirm", confirmed: false });
    await wait(() => messages.some(value => value.id === "answer-notify"));
    await send({ type: "snapshot", id: "test-client:answered" });
    await wait(() => messages.some(value => value.id === "test-client:answered"));
    assert.equal(messages.filter(value => value.type === "dialog_closed").length, 1);
    assert.equal(messages.filter(value => value.id === "answer-notify").length, 1);
    assert.deepEqual(messages.find(value => value.id === "test-client:answered")?.record.dialogs, {});
    await send({ type: "new_session", id: "test-client:new" });
    await wait(() => messages.some(value => value.id === "bridge:1:get_entries"));
    await send({ type: "snapshot", id: "test-client:reset" });
    await wait(() => messages.some(value => value.id === "test-client:reset"));
    const reset = messages.find(value => value.id === "test-client:reset");
    assert.equal(reset?.generation, 1);
    assert.deepEqual(reset?.record.entries, []);
    assert.ok(messages.some(value => value.type === "snapshot" && value.id === null && value.generation === 1));
    await send({ type: "fixture_snapshot", id: "test-client:fixture" });
    await wait(() => messages.some(value => value.id === "test-client:fixture"));
    await send({ type: "snapshot", id: "test-client:canonical" });
    await wait(() => messages.some(value => value.id === "test-client:canonical"));
    const canonical = messages.find(value => value.id === "test-client:canonical");
    assert.equal(canonical?.record.compaction.type, "compaction_start");
    const normalize = (value: any) => ({ ...value, id: null, seq: 0, hello: { ...value.hello, instance: "fixture", cwd: "/fixture" } });
    const captured = { completed: normalize(snapshot), streaming: normalize(canonical), reset: normalize(reset) };
    if (process.env.PI_SURFACE_SHOTS) {
      let sequence = 1;
      writeFileSync(join(process.env.PI_SURFACE_SHOTS, "session.bytes"), messages.flatMap(value => { const chunks = frames(JSON.stringify(value), "out", sequence); sequence += chunks.length; return chunks; }).join(""));
    }
    const fixturePath = new URL("testdata/kido-pi-snapshot.json", import.meta.url);
    if (process.env.UPDATE_KIDO_PI_FIXTURES) writeFileSync(fixturePath, JSON.stringify(captured, null, 2) + "\n");
    assert.deepEqual(captured, JSON.parse(readFileSync(fixturePath, "utf8")));
    await run("send-keys", "-t", "test:0.0", "-H", "04");
    await wait(() => text.includes("TTY_RESTORED"));
    assert.ok(messages.some(value => value.type === "bye"));
  } finally {
    await run("kill-session", "-t", "test");
    child.stdin.end(); child.kill("SIGTERM"); rmSync(dir, { recursive: true, force: true });
  }
});
