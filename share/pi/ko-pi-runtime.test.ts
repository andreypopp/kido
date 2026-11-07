import { test } from "node:test";

import assert from "node:assert/strict";

import { spawn, spawnSync } from "node:child_process";

import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";

import { delimiter, dirname, join } from "node:path";

import { fileURLToPath } from "node:url";

import { getAgentDir } from "@earendil-works/pi-coding-agent";

import { makeFixture, agentPane, selfPane, startSession, text, entriesOf, customMessages, notices, gatedCommand, pollUntil, withEnv, freshExtension, movedId, logHas, captureStatusRecords, jobRecords, type Fixture, type Started } from "./ko-pi-fixture.ts";

import { mapHostPath, senderHeader } from "./ko-pi.ts";

type Body = Record<string, any>;

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");

function tree(fx: Fixture) {
  const root = realpathSync(mkdtempSync(join(fx.dir, "tree-")));
  const rt = join(root, "rt");
  const host = join(root, "host");
  mkdirSync(join(rt, "proj", "sub"), { recursive: true });
  mkdirSync(join(rt, "fallback"));
  writeFileSync(join(rt, "CLAUDE.md"), "outer claude");
  writeFileSync(join(rt, "proj", "AGENTS.md"), "inner agents");
  writeFileSync(join(rt, "proj", "CLAUDE.md"), "shadowed");
  return { root, rt, host, hostCwd: join(host, "proj") };
}

function dev(t: ReturnType<typeof tree>, extra: Record<string, unknown> = {}) {
  return { cwd: join(t.rt, "fallback"), paths: [{ host: t.host, runtime: t.rt }], pi: "host", source: { type: "session", id: "session_3" }, ...extra };
}

async function routed(fx: Fixture, t: ReturnType<typeof tree>, opts: { runtimes?: Record<string, Record<string, unknown>>; cwd?: string } = {}): Promise<Started> {
  fx.setRuntimes(opts.runtimes ?? { dev: dev(t) });
  return startSession(fx, { flags: { runtime: "dev" }, ctx: { cwd: opts.cwd ?? t.hostCwd } });
}


const run = (s: Started, tool: string, params: Record<string, unknown>, signal?: AbortSignal): Promise<any> => s.tools.get(tool).execute("c", params, signal, () => {});

test("a host path maps by its longest prefix of whole components", () => {
  const paths = [
    { host: "/h", runtime: "/r" },
    { host: "/h/deep", runtime: "/other" },
    { host: "/", runtime: "/everything" },
  ];
  assert.equal(mapHostPath(paths, "/h/a/b"), "/r/a/b");
  assert.equal(mapHostPath(paths, "/h"), "/r");
  assert.equal(mapHostPath(paths, "/h/deep/x"), "/other/x");
  assert.equal(mapHostPath(paths, "/hx/a"), "/everything/hx/a");
  assert.equal(mapHostPath(paths.slice(0, 2), "/hx/a"), undefined);
});

test("the runtime cwd is the longest paths match, else the configured cwd, else the pwd of an exec", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const bare = { paths: [{ host: t.host, runtime: t.rt }], pi: "host" };
    const cases: Array<[Record<string, Record<string, unknown>>, string, string]> = [
      [{ dev: dev(t) }, t.hostCwd, join(t.rt, "proj")],
      [{ dev: dev(t) }, "/elsewhere", join(t.rt, "fallback")],
      [{ dev: bare }, "/elsewhere", realpathSync(process.cwd())],
    ];
    for (const [runtimes, cwd, want] of cases) {
      const s = await routed(fx, t, { runtimes, cwd });
      assert.equal(text(await run(s, "bash", { command: "pwd" })).trim(), want);
    }
  } finally {
    await fx.restore();
  }
});

test("the prompt gets the runtime cwd, the runtime's context files after the global one, a runtime section, and the user gets the same notice", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    const event = {
      systemPromptOptions: {
        cwd: t.hostCwd,
        promptGuidelines: [] as string[],
        sections: {} as Record<string, string>,
        contextFiles: [
          { path: join(getAgentDir(), "AGENTS.md"), content: "global" },
          { path: join(t.hostCwd, "AGENTS.md"), content: "host project" },
        ],
      },
    };
    await s.emit("before_agent_start", event);
    assert.deepEqual(await s.emit("resources_discover"), [undefined]);
    assert.ok(!event.systemPromptOptions.promptGuidelines.some((rule) => rule.includes("read the ko skill first")));
    assert.equal(event.systemPromptOptions.cwd, join(t.rt, "proj"));
    assert.deepEqual(event.systemPromptOptions.contextFiles, [
      { path: join(getAgentDir(), "AGENTS.md"), content: "global" },
      { path: join(t.rt, "CLAUDE.md"), content: "outer claude" },
      { path: join(t.rt, "proj", "AGENTS.md"), content: "inner agents" },
    ]);
    const section = event.systemPromptOptions.sections.runtime!;
    assert.match(section, new RegExp(`^The tools bash, read, write, edit, ls, find, grep, async_bash and the user's ! commands run in runtime dev, at ${join(t.rt, "proj")}\\.`));
    assert.match(section, new RegExp(`Every other tool \\(list_agents, read_report, .*spawn_agent.*\\) runs on the host, at ${t.hostCwd}, not in the runtime\\.$`));
    assert.doesNotMatch(section, /\(.*\b(?:bash|async_bash)\b.*\)/);
    assert.deepEqual(s.notifications, [{ message: section, type: "info" }]);
  } finally {
    await fx.restore();
  }
});

test("bash runs in the runtime with no host environment, reports a failure's status and a signal as 128 plus its number", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    const reply = await withEnv({ HOST_SECRET: "leak" }, async () => run(s, "bash", { command: "env; echo err >&2" }));
    const output = text(reply);
    assert.match(output, /KO_RUNTIME=dev/);
    assert.match(output, /err/);
    assert.doesNotMatch(output, /HOST_SECRET|KO_PANE|KO_SOCKET/);
    const [exec] = fx.execLog().slice(-1);
    assert.equal(exec!.runtime, "dev");
    assert.equal(exec!.request.env, undefined);
    assert.equal(exec!.request.cwd, join(t.rt, "proj"));

    assert.match(text(await run(s, "bash", { command: "echo out; exit 3" })), /out[\s\S]*exited with code 3/);
    assert.match(text(await run(s, "bash", { command: "kill -9 $$" })), /exited with code 137/);
  } finally {
    await fx.restore();
  }
});

test("a cancelled bash ends its exec process, and a timeout ends it with pi's timeout error", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    await run(s, "bash", { command: "true" });
    const baseline = fx.running();
    const controller = new AbortController();
    const running = run(s, "bash", { command: "echo started; exec sleep 30" }, controller.signal);
    await pollUntil(() => fx.execLog().some((exec) => JSON.stringify(exec.request.argv).includes("sleep 30")), 5000, "the command to reach the runtime");
    assert.equal(fx.running(), baseline + 1);
    controller.abort();
    await assert.rejects(running, /aborted/);
    await pollUntil(() => fx.running() === baseline, 5000, "the exec process to end");

    const [shell] = await s.emit("user_bash", { command: "x", cwd: t.hostCwd, excludeFromContext: false }) as Array<{ operations: any }>;
    await assert.rejects(shell!.operations.exec("exec sleep 30", t.hostCwd, { onData: () => {}, timeout: 0.05 }), /timeout:0.05/);
    await pollUntil(() => fx.running() === baseline, 5000, "the timed out exec process to end");
  } finally {
    await fx.restore();
  }
});

test("! commands run in the runtime at its cwd through user_bash", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    const [result] = await s.emit("user_bash", { command: "pwd", cwd: t.hostCwd, excludeFromContext: false }) as Array<{ operations: any }>;
    let output = "";
    const done = await result!.operations.exec("pwd; exit 4", t.hostCwd, { onData: (data: Buffer) => (output += data.toString()) });
    assert.deepEqual([output.trim(), done.exitCode], [join(t.rt, "proj"), 4]);
  } finally {
    await fx.restore();
  }
});

test("read, write, edit, ls and find keep bytes and names intact, and map an absolute host path under paths", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    const awkward = `it's "a" file $x.txt`;
    writeFileSync(join(t.rt, "proj", awkward), Buffer.from([0x68, 0x69, 0xff, 0xfe, 0x0a, 0x74, 0x61, 0x69, 0x6c]));
    writeFileSync(join(t.rt, "proj", "pic.png"), PNG);
    const outside = join(t.root, "outside");
    mkdirSync(outside);
    writeFileSync(join(outside, "o.txt"), "outside runtime path");

    const read = (path: string) => run(s, "read", { path });
    const bytes = text(await read(awkward));
    assert.ok(bytes.startsWith("hi") && bytes.endsWith("\ntail"), bytes);
    assert.equal(text(await read(join(t.hostCwd, "AGENTS.md"))), "inner agents", "a host path under a paths prefix maps");
    assert.equal(text(await read(join(outside, "o.txt"))), "outside runtime path", "any other absolute path is a runtime path");
    assert.ok((await read("pic.png")).content.some((block: { type: string }) => block.type === "image"), "an image file reaches the model as an image");
    await assert.rejects(read("missing.txt"), /No such file/);

    const big = Array.from({ length: 5000 }, (_, line) => `line ${line} é ${"x".repeat(40)}`).join("\n");
    assert.ok(Buffer.byteLength(big) > 3 * 64 * 1024);
    await run(s, "write", { path: `new dir/${awkward}`, content: big });
    assert.equal(readFileSync(join(t.rt, "proj", "new dir", awkward), "utf8"), big, "a file of several chunks arrives whole in a new directory");
    await run(s, "write", { path: "empty.txt", content: "" });
    assert.equal(readFileSync(join(t.rt, "proj", "empty.txt"), "utf8"), "");

    await run(s, "edit", { path: `new dir/${awkward}`, edits: [{ oldText: "line 7 é", newText: "line seven é" }] });
    assert.equal(readFileSync(join(t.rt, "proj", "new dir", awkward), "utf8"), big.replace("line 7 é", "line seven é"));

    mkdirSync(join(t.rt, "proj", "node_modules"));
    writeFileSync(join(t.rt, "proj", "node_modules", "skipped.txt"), "x");
    const listing = text(await run(s, "ls", {})).split("\n");
    assert.deepEqual(listing.filter((entry) => ["new dir/", "sub/", "node_modules/", awkward].includes(entry)).sort(), ["new dir/", "node_modules/", "sub/", awkward].sort());
    await assert.rejects(run(s, "ls", { path: awkward }), /Not a directory/);
    await assert.rejects(run(s, "ls", { path: "nope" }), /Path not found/);

    const found = text(await run(s, "find", { pattern: "*.txt" })).split("\n");
    assert.ok(found.includes(awkward) && found.includes(`new dir/${awkward}`), found.join("|"));
    assert.ok(!found.some((path) => path.includes("node_modules")));
    assert.deepEqual(text(await run(s, "find", { pattern: "new dir/*.txt" })).split("\n"), [`new dir/${awkward}`]);
    assert.equal(text(await run(s, "find", { pattern: "*.nothing" })), "No files found matching pattern");
  } finally {
    await fx.restore();
  }
});

test("grep finds lines with context, treats no match as a result and skips binary files", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    const grep = (params: Record<string, unknown>) => s.tools.get("grep").execute("c", params, undefined, () => {}).then(text);
    writeFileSync(join(t.rt, "proj", "a b.txt"), "alpha\nneedle one\nomega\n");
    writeFileSync(join(t.rt, "proj", "sub", "c.log"), "NEEDLE two\n");
    writeFileSync(join(t.rt, "proj", "blob.bin"), Buffer.from([0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65, 0x00, 0x01, 0x0a]));

    assert.equal(await grep({ pattern: "needle", ignoreCase: true, glob: "*.txt" }), "a b.txt:2: needle one");
    assert.deepEqual((await grep({ pattern: "needle", ignoreCase: true })).split("\n").sort(), ["a b.txt:2: needle one", "sub/c.log:1: NEEDLE two"], "blob.bin is a binary file and is not searched");
    assert.equal(await grep({ pattern: "needle", path: "a b.txt", context: 1 }), "a b.txt-1- alpha\na b.txt:2: needle one\na b.txt-3- omega");
    assert.equal(await grep({ pattern: "n.edle", literal: true }), "No matches found");
    assert.equal(await grep({ pattern: "absent-from-everything" }), "No matches found");
    assert.match(await grep({ pattern: "needle", ignoreCase: true, limit: 1 }), /matches limit reached/);
    await assert.rejects(grep({ pattern: "x", path: "nowhere" }), /No such file/);
    await assert.rejects(grep({ pattern: "(" }), /./);
  } finally {
    await fx.restore();
  }
});

test("grep names a file unambiguously when its name looks like a line number", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    writeFileSync(join(t.rt, "proj", "part:12:name.txt"), "x\nneedle\ny\n");
    writeFileSync(join(t.rt, "proj", "a-3-b.txt"), "a\nneedle\nb\n");
    const grep = async (params: Record<string, unknown>) => text(await run(s, "grep", params)).split("\n").sort();
    assert.deepEqual(await grep({ pattern: "needle" }), ["a-3-b.txt:2: needle", "part:12:name.txt:2: needle"]);
    assert.deepEqual(await grep({ pattern: "needle", context: 1 }), ["a-3-b.txt-1- a", "a-3-b.txt-3- b", "a-3-b.txt:2: needle", "part:12:name.txt-1- x", "part:12:name.txt-3- y", "part:12:name.txt:2: needle"]);
  } finally {
    await fx.restore();
  }
});

test("a path that starts with ~ is the runtime's home, not the host's", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const home = join(t.rt, "home");
    mkdirSync(home);
    writeFileSync(join(home, "n.txt"), "needle at home");
    const s = await routed(fx, t, { runtimes: { dev: dev(t, { env: { HOME: home } }) } });
    assert.equal(text(await run(s, "read", { path: "~/n.txt" })), "needle at home");
    assert.equal(text(await run(s, "ls", { path: "~" })), "n.txt");
    assert.equal(text(await run(s, "grep", { pattern: "needle", path: "~" })), "n.txt:1: needle at home");
    assert.equal(text(await run(s, "find", { pattern: "*.txt", path: "~/" })), "n.txt");
    await run(s, "write", { path: "~/w.txt", content: "written" });
    assert.equal(readFileSync(join(home, "w.txt"), "utf8"), "written");
  } finally {
    await fx.restore();
  }
});

test("an abort while the runtime starts ends the call and the command never runs", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const gate = join(fx.dir, "gate");
    process.env.KO_FAKE_EXEC_GATE = gate;
    const s = await routed(fx, t);
    const controller = new AbortController();
    const running = run(s, "bash", { command: "echo ran" }, controller.signal);
    await pollUntil(() => fx.execLog().length === 1, 5000, "the context read to reach the runtime");
    controller.abort();
    await assert.rejects(running, /aborted/);
    writeFileSync(gate, "");
    assert.equal(text(await run(s, "bash", { command: "echo after" })).trim(), "after");
    assert.ok(!JSON.stringify(fx.execLog()).includes("echo ran"), "the aborted command reached the runtime");
  } finally {
    await fx.restore();
  }
});

test("a context read that fails with no known cwd is retried by the next call and the next prompt", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    fx.setPanes([selfPane()]);
    const failed = { paths: [], pi: "host", state: { type: "failed", message: "the image is gone" } };
    const s = await routed(fx, t, { runtimes: { dev: failed }, cwd: "/elsewhere" });
    await pollUntil(() => s.notifications.length === 1, 5000, "the failure notice");
    assert.equal(s.notifications[0]!.type, "error");
    await assert.rejects(run(s, "bash", { command: "pwd" }), /the image is gone/);
    const event = { systemPromptOptions: { cwd: "/host", promptGuidelines: [] as string[], sections: {} as Record<string, string>, contextFiles: [] } };
    await s.emit("before_agent_start", event);
    assert.equal(event.systemPromptOptions.cwd, "/host", "no runtime cwd is known yet");
    assert.equal(fx.row("pane_1")?.vars?.["pi.runtime"], undefined);

    fx.setRuntimes({ dev: { paths: [], pi: "host" } });
    await s.emit("before_agent_start", event);
    assert.equal(event.systemPromptOptions.cwd, realpathSync(process.cwd()));
    assert.equal(text(await run(s, "bash", { command: "pwd" })).trim(), realpathSync(process.cwd()));
    assert.deepEqual(fx.row("pane_1")?.vars?.["pi.runtime"], { name: "dev", cwd: realpathSync(process.cwd()) });
  } finally {
    await fx.restore();
  }
});

test("a host session wraps bash alone, and a routed one registers all seven tools even when it refuses", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const seven = ["bash", "read", "write", "edit", "ls", "find", "grep"];
    const host = await startSession(fx);
    assert.deepEqual(seven.filter((name) => host.tools.has(name)), ["bash"]);
    const refusing = await routed(fx, t, { runtimes: {} });
    assert.deepEqual(seven.filter((name) => refusing.tools.has(name)), seven);
    const live = await routed(fx, t);
    assert.deepEqual(seven.filter((name) => live.tools.has(name)), seven);
  } finally {
    await fx.restore();
  }
});

test("find and grep use fd and rg when the runtime has them, and read rg's JSON including bytes", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const bin = join(t.root, "bin");
    mkdirSync(bin);
    const record = join(t.root, "argv.txt");
    const script = (body: string) => `#!/bin/sh\nprintf '%s\\n' "$*" >> ${record}\n${body}\n`;
    const rgJson = [
      { type: "match", data: { path: { text: join(t.rt, "proj", "x.ts") }, lines: { text: "const a = 1;\n" }, line_number: 3 } },
      { type: "context", data: { path: { bytes: Buffer.from(join(t.rt, "proj", "sub", "y.ts")).toString("base64") }, lines: { bytes: Buffer.from("next line\n").toString("base64") }, line_number: 4 } },
    ];
    writeFileSync(join(bin, "rg"), script(`cat <<'EOF'\n${rgJson.map((event) => JSON.stringify(event)).join("\n")}\nEOF`));
    writeFileSync(join(bin, "fd"), script(`echo ${join(t.rt, "proj", "found.ts")}`));
    chmodSync(join(bin, "rg"), 0o755);
    chmodSync(join(bin, "fd"), 0o755);
    const s = await routed(fx, t, { runtimes: { dev: dev(t, { env: { PATH: `${bin}${delimiter}/usr/bin${delimiter}/bin` } }) } });

    assert.equal(text(await run(s, "grep", { pattern: "a", glob: "*.ts", ignoreCase: true, context: 1 })), "x.ts:3: const a = 1;\nsub/y.ts-4- next line");
    assert.equal(text(await run(s, "find", { pattern: "*.ts" })), "found.ts");
    const seen = readFileSync(record, "utf8");
    assert.match(seen, /--no-config --json --hidden --color=never --ignore-case --glob \*\.ts --context 1 -- a /);
    assert.match(seen, /--glob --color=never --hidden --no-require-git --exclude \.git --exclude node_modules --max-results 1000 -- \*\.ts /);
  } finally {
    await fx.restore();
  }
});

test("a runtime that is missing or runs pi itself refuses every routed tool and ! with a notice, and keeps pi running", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    fx.setPanes([selfPane()]);
    const cases: Array<[Record<string, Record<string, unknown>>, RegExp]> = [
      [{}, /no runtime dev in the fake$/],
      [{ dev: { not_found: "no runtime dev in session_3 or in /config.yaml" } }, /no runtime dev in session_3 or in \/config.yaml$/],
      [{ dev: dev(t, { pi: "runtime" }) }, /runtime dev runs pi inside it/],
    ];
    for (const [runtimes, refusal] of cases) {
      const s = await routed(fx, t, { runtimes });
      assert.deepEqual(await s.emit("resources_discover"), [undefined]);
      assert.equal(s.notifications.length, 1);
      assert.match(s.notifications[0]!.message, refusal);
      assert.equal(s.notifications[0]!.type, "error");
      for (const [tool, params] of [["bash", { command: "pwd" }], ["read", { path: "x" }], ["write", { path: "x", content: "y" }], ["edit", { path: "x", edits: [] }], ["ls", {}], ["find", { pattern: "*" }], ["grep", { pattern: "x" }]] as const) {
        await assert.rejects(run(s, tool, params), refusal, tool);
      }
      await assert.rejects(async () => s.handlers.get("user_bash")![0]!({ command: "pwd", cwd: t.hostCwd, excludeFromContext: false }), refusal);
      assert.match(text(await run(s, "async_bash", { command: "true", name: "x" })), refusal);
      assert.equal(fx.row("pane_1")?.vars?.["pi.runtime"], undefined);
      assert.equal(fx.execLog().length, 0, "nothing reached the runtime");
      const event = { systemPromptOptions: { promptGuidelines: [] as string[], sections: {}, contextFiles: [], cwd: "/host" } };
      await s.emit("before_agent_start", event);
      assert.ok(!event.systemPromptOptions.promptGuidelines.some((rule) => rule.includes("read the ko skill first")));
      assert.deepEqual(event.systemPromptOptions, { promptGuidelines: [event.systemPromptOptions.promptGuidelines[0]], sections: {}, contextFiles: [], cwd: "/host" });
    }
    assert.equal(fx.apiCalls().filter((call) => call.path.endsWith("/exec")).length, 0);
  } finally {
    await fx.restore();
  }
});

test("session_start does not wait for the runtime; the first prompt waits for the context read", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    fx.setPanes([selfPane()]);
    const gate = join(fx.dir, "gate");
    process.env.KO_FAKE_EXEC_GATE = gate;
    const s = await routed(fx, t);
    assert.deepEqual(fx.row("pane_1")?.vars?.["pi.runtime"], { name: "dev", cwd: join(t.rt, "proj") }, "the cwd came from paths: the pane is marked at once");
    assert.equal(s.notifications.length, 1);
    const event = { systemPromptOptions: { cwd: t.hostCwd, promptGuidelines: [] as string[], sections: {}, contextFiles: [] as Array<{ path: string; content: string }> } };
    let prompted = false;
    const prompt = s.emit("before_agent_start", event).then(() => (prompted = true));
    await pollUntil(() => fx.execLog().length === 1, 5000, "the context read to reach the runtime");
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(prompted, false);
    writeFileSync(gate, "");
    await prompt;
    assert.deepEqual(event.systemPromptOptions.contextFiles.map((file) => file.content), ["outer claude", "inner agents"]);
  } finally {
    await fx.restore();
  }
});

test("a failed runtime is no refusal: a tool reaches it and gets the start's error", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t, { runtimes: { dev: dev(t, { state: { type: "failed", message: "the image is gone" } }) } });
    await assert.rejects(run(s, "bash", { command: "pwd" }), /the image is gone/);
    assert.deepEqual(s.notifications.map((note) => note.type), ["info", "warning"]);
    assert.match(s.notifications[1]!.message, /the image is gone; its context files are not read$/);
  } finally {
    await fx.restore();
  }
});

test("a routed async_bash is an exec session with a host log, a notice, and cancellation by closing its ko child", async (ctx) => {
  const output = captureStatusRecords(ctx);
  const fx = makeFixture();
  try {
    const t = tree(fx);
    fx.setPanes([selfPane()]);
    const s = await routed(fx, t);
    assert.deepEqual(fx.row("pane_1")?.vars?.["pi.runtime"], { name: "dev", cwd: join(t.rt, "proj") });
    assert.equal(fx.row("pane_1")?.vars?.["ko.runtime"], "dev");
    await run(s, "bash", { command: "true" });
    const baseline = fx.running();
    const gate = join(t.rt, "gate");
    const command = `env; printf 'before\\n'; ${gatedCommand(gate, "", "after\n", 3)}`;
    const result = await withEnv({ HOST_SECRET: "host-only" }, () => run(s, "async_bash", { command, name: "build", stream: true }));
    assert.equal(fx.running(), baseline + 1);
    const records = () => jobRecords(output, result.details.job);
    assert.ok(records()[0]?.includes("state=working:"));
    await pollUntil(() => fx.execLog().at(-1)?.request.argv?.[2] === command);
    const exec = fx.execLog().at(-1)!;
    assert.equal(exec.runtime, "dev");
    assert.match(exec.request.argv[0], /\/(bash|sh)$/);
    assert.deepEqual(exec.request.argv.slice(1), ["-lc", command]);
    assert.equal(exec.request.cwd, join(t.rt, "proj"));
    assert.equal(exec.request.env, undefined);
    assert.equal(exec.request.stdin, false);
    await pollUntil(() => logHas(result.details.log, "before"));
    assert.match(readFileSync(result.details.log, "utf8"), /KO_RUNTIME=dev/);
    assert.doesNotMatch(readFileSync(result.details.log, "utf8"), /HOST_SECRET|KO_PANE|KO_SOCKET/);
    const rows = JSON.parse(text(await run(s, "list_async_bash", {})));
    assert.equal(rows[0].runtime, "dev");
    assert.equal(rows[0].log, result.details.log);
    writeFileSync(gate, "");
    await pollUntil(() => notices(s).length === 1);
    assert.match(notices(s)[0]!, /exit 3/);
    assert.ok(records().at(-1)?.includes("state=error:"));
    assert.ok(records().at(-1)?.endsWith(":msg=ZXhpdCAz\x1b\\"));
    assert.match(notices(s)[0]!, /before\nafter/);
    await pollUntil(() => fx.running() === baseline);
    const service = await run(s, "async_bash", { command: `printf 'ready\\n'; ${gatedCommand(join(t.rt, "service"))}`, name: "service" });
    await pollUntil(() => logHas(service.details.log, "ready"));
    await run(s, "stop_async_bash", { job: service.details.job });
    await pollUntil(() => fx.running() === baseline);
    assert.equal(notices(s).length, 1, "a stopped job sends no notice");
    await s.emit("session_shutdown", { reason: "quit" });
    assert.equal(fx.row("pane_1")?.vars?.["pi.runtime"], undefined);
    assert.equal(fx.row("pane_1")?.vars?.["ko.runtime"], undefined);
    assert.equal(fx.row("pane_1")?.vars?.["pi.session"], undefined);
  } finally { await fx.restore(); }
});

test("a routed bash moves to one exec-session job by timer or ctrl+b and stop closes that exec child", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const s = await routed(fx, t);
    await run(s, "bash", { command: "true" });
    const baseline = fx.running();
    for (const move of ["timeout", "key"]) {
      process.env.KO_JOB_MOVE_MS = move === "timeout" ? "50" : "10000";
      const ready = join(t.rt, `ready-${move}`);
      const command = `printf ready > '${ready}'; ${gatedCommand(join(t.rt, `gate-${move}`))}`;
      const count = fx.execLog().length;
      const work = run(s, "bash", { command });
      await pollUntil(() => existsSync(ready));
      if (move === "key") assert.deepEqual(s.terminalInput("\x02"), [{ consume: true }]);
      const result = await work;
      assert.notEqual(result.isError, true);
      const id = movedId(result);
      const row = JSON.parse(text(await run(s, "list_async_bash", {})))[0];
      assert.equal(row.job, id);
      assert.equal(row.runtime, "dev");
      assert.equal(row.state, "running");
      assert.equal(fx.execLog().length, count + 1);
      assert.equal(fx.execLog().at(-1)?.request.argv[2], command);
      await run(s, "stop_async_bash", { job: id });
      await pollUntil(() => fx.running() === baseline);
    }
    assert.deepEqual(notices(s), []);
  } finally { await fx.restore(); }
});

test("reload during a routed startup moves the eventual child without restoring old hooks", async () => {
  const fx = makeFixture();
  try {
    process.env.KO_JOB_MOVE_MS = "10000";
    process.env.KO_JOB_HINT_MS = "1";
    const t = tree(fx);
    const first = await routed(fx, t);
    await first.emit("before_agent_start", { systemPromptOptions: { promptGuidelines: [], contextFiles: [], sections: {} } });
    const startupGate = join(fx.dir, "startup-gate");
    const jobGate = join(t.rt, "job-gate");
    process.env.KO_FAKE_EXEC_GATE = startupGate;
    const count = fx.execLog().length;
    const abort = new AbortController();
    const work = run(first, "bash", { command: gatedCommand(jobGate, "running\n", "finished\n") }, abort.signal);
    await pollUntil(() => fx.execLog().length > count);
    await first.emit("session_shutdown", { reason: "reload" });
    abort.abort();
    delete process.env.KO_FAKE_EXEC_GATE;
    const second = await startSession(fx, { factory: await freshExtension(), flags: { runtime: "dev" }, ctx: { cwd: t.hostCwd } });
    writeFileSync(startupGate, "");
    const id = movedId(await work);
    const [row] = JSON.parse(text(await run(second, "list_async_bash", {})));
    assert.equal(row.job, id);
    assert.equal(row.runtime, "dev");
    assert.equal(first.terminalListeners.size, 0);
    assert.equal(first.widgets.get("ko-job-hint")?.content, undefined);
    await pollUntil(() => logHas(row.log, "running"));
    writeFileSync(jobGate, "");
    await pollUntil(() => notices(second).length === 1);
    assert.match(notices(second)[0]!, /running\nfinished/);
    assert.deepEqual(first.messages, []);
    assert.equal(first.widgets.get("ko-job-hint")?.content, undefined);
  } finally { await fx.restore(); }
});

test("new cancels a routed call still probing its shell before it can start a job", { timeout: 5000 }, async () => {
  const fx = makeFixture();
  const startupGate = join(fx.dir, "startup-gate");
  const jobGate = join(fx.dir, "job-gate");
  try {
    const t = tree(fx);
    const first = await routed(fx, t);
    await first.emit("before_agent_start", { systemPromptOptions: { promptGuidelines: [], contextFiles: [], sections: {} } });
    process.env.KO_FAKE_EXEC_GATE = startupGate;
    const count = fx.execLog().length;
    const work = run(first, "bash", { command: gatedCommand(jobGate, "should-not-start") });
    const rejected = assert.rejects(work, /aborted/);
    await pollUntil(() => fx.execLog().length > count);
    await first.emit("session_shutdown", { reason: "new" });
    await rejected;
    writeFileSync(startupGate, "");
    await pollUntil(() => fx.running() === 0);
    assert.ok(fx.execLog().every((entry) => !JSON.stringify(entry.request.argv).includes("should-not-start")));
    assert.deepEqual(JSON.parse(text(await run(first, "list_async_bash", {}))), []);
  } finally {
    writeFileSync(startupGate, "");
    writeFileSync(jobGate, "");
    await fx.restore();
  }
});

for (const reason of ["quit", "new", "resume", "fork", "reload"]) {
  test(`${reason} refuses a routed async_bash start held at its shell probe`, { timeout: 5000 }, async () => {
    const fx = makeFixture();
    const factsGate = join(fx.dir, "facts-gate");
    const jobGate = join(fx.dir, "job-gate");
    try {
      const t = tree(fx);
      const first = await routed(fx, t);
      await first.emit("before_agent_start", { systemPromptOptions: { promptGuidelines: [], contextFiles: [], sections: {} } });
      process.env.KO_FAKE_EXEC_GATE = factsGate;
      const count = fx.execLog().length;
      const command = gatedCommand(jobGate, `must-not-run-${reason}`);
      let settled = false;
      const work = run(first, "async_bash", { command, name: "monitor" }).then((result) => { settled = true; return result; });
      await pollUntil(() => fx.execLog().length > count);
      await first.emit("session_shutdown", { reason });
      delete process.env.KO_FAKE_EXEC_GATE;
      const second = reason === "reload" ? await startSession(fx, { factory: await freshExtension(), flags: { runtime: "dev" }, ctx: { cwd: t.hostCwd } }) : undefined;
      if (second) {
        const result = await run(second, "async_bash", { command: gatedCommand(jobGate), name: "monitor" });
        assert.match(text(result), /started job/);
      }
      await pollUntil(() => settled, 2000, "the pending start to return its refusal before its probe is released");
      const result = await work;
      writeFileSync(factsGate, "");
      await pollUntil(() => fx.running() === (second ? 2 : 0));
      if (second) {
        const rows = JSON.parse(text(await run(second, "list_async_bash", {})));
        assert.equal(rows.filter((row: any) => row.name === "monitor").length, 1, "the old start must not create a second job with the same name");
      }
      assert.equal(result.isError, true, "shutdown must refuse a start that has no job yet");
      assert.match(text(result), new RegExp(`start cancelled.*${reason}`));
      assert.ok(fx.execLog().every((entry) => !JSON.stringify(entry.request.argv).includes(`must-not-run-${reason}`)));
    } finally {
      writeFileSync(factsGate, "");
      writeFileSync(jobGate, "");
      await fx.restore();
    }
  });
}

test("spawn_agent with a runtime starts a routed child, or an inside child by the runtime's pi", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    const repo = process.cwd();
    fx.setRuntimes({
      dev: dev(t),
      inner: { pi: "runtime", source: { type: "session", id: "session_3" }, paths: [{ host: repo, runtime: "/work" }] },
      lost: { pi: "runtime" },
      fall: { pi: "runtime", cwd: "/fallback" },
    });
    fx.setPanes([selfPane()]);
    const s = await startSession(fx, { name: "Self", ctx: { isProjectTrusted: () => true } });
    const spawnAgent = (params: Record<string, unknown>) => s.tools.get("spawn_agent").execute("c", { task: "go", ...params });
    const env = (body: Body, name: string) => (body.env as Array<{ name: string; value: string }>).find((v) => v.name === name)?.value;

    const routedChild = text(await spawnAgent({ name: "viahost", runtime: "dev" }));
    const [first] = fx.posts("/panes") as Body[];
    assert.equal(first!.runtime, undefined, "a routed child is a host pane");
    assert.ok(first!.command.argv.includes("--session-dir"));
    assert.deepEqual(first!.command.argv.slice(1, 6), ["shell", "--", "ko-pi", "--runtime", "dev"]);
    assert.equal(first!.cwd, repo);
    assert.equal(env(first!, "KO_AGENT_TRUSTED_CWD"), repo, "the host cwd, unmapped");
    assert.match(routedChild, /^spawned viahost \(session [0-9a-f]{32}, window window_10, pane pane_10, in runtime dev\);/);
    const [entry] = entriesOf(s, "ko-pi.agent");
    assert.deepEqual(entry!.runtime, { name: "dev", mode: "routed" });

    const insideChild = text(await spawnAgent({ name: "inside", runtime: "inner" }));
    const [, second] = fx.posts("/panes") as Body[];
    assert.equal(second!.runtime, "inner");
    assert.deepEqual(second!.command.argv.slice(0, 4), ["ko", "shell", "--", "ko-pi"]);
    assert.ok(!second!.command.argv.includes("--runtime"));
    assert.ok(!second!.command.argv.includes("--session-dir"));
    assert.equal(second!.cwd, repo, "the host path, which the server maps");
    assert.equal(env(second!, "KO_AGENT_TRUSTED_CWD"), "/work", "the path the child sees");
    assert.match(insideChild, /pane pane_11, in runtime inner\);/);

    await spawnAgent({ name: "unmapped", runtime: "lost" });
    const [, , third] = fx.posts("/panes") as Body[];
    assert.equal(env(third!, "KO_AGENT_TRUSTED_CWD"), undefined, "an unmapped cwd gives no trust");

    await spawnAgent({ name: "fallen", runtime: "fall" });
    const [, , , fifth] = fx.posts("/panes") as Body[];
    assert.equal(env(fifth!, "KO_AGENT_TRUSTED_CWD"), "/fallback", "an unmapped cwd falls back to the runtime's cwd, as the server maps it");

    for (const extra of [{ resume_from: "x".repeat(8) }, { fork: true }]) {
      assert.equal(text(await spawnAgent({ name: "nope", runtime: "inner", ...extra })), "could not spawn agent: a saved session is a file of this filesystem: resume_from and fork need a runtime whose pi runs on the host");
    }
    assert.equal(text(await spawnAgent({ name: "ghost", runtime: "ghost" })), "could not spawn agent: no runtime ghost in the fake");
    assert.equal(fx.posts("/panes").length, 4);

    fx.setPanes([selfPane()]);
    const restarted = text(await s.tools.get("message_agent").execute("c", { to: "viahost", message: "again" }));
    assert.match(restarted, /^restarted viahost in pane/);
    const [, , , , fourth] = fx.posts("/panes") as Body[];
    assert.deepEqual(fourth!.command.argv.slice(4, 6), ["--runtime", "dev"], "a restart starts the child as it was started");
  } finally {
    await fx.restore();
  }
});

test("a routed spawner's child is routed in the same runtime; an inside spawner's child is in its runtime by the server", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    fx.setPanes([selfPane()]);
    const s = await routed(fx, t);
    const reply = text(await s.tools.get("spawn_agent").execute("c", { name: "kid", task: "go" }));
    const [body] = fx.posts("/panes") as Body[];
    assert.deepEqual(body!.command.argv.slice(4, 6), ["--runtime", "dev"]);
    assert.equal(body!.cwd, process.cwd(), "the child starts in the caller's host cwd and maps it itself");
    assert.match(reply, /in runtime dev\);/);
    await s.tools.get("spawn_agent").execute("c2", { name: "kid2", task: "go", runtime: "dev" });
    const [, second] = fx.posts("/panes") as Body[];
    assert.deepEqual(second!.command.argv.slice(4, 6), ["--runtime", "dev"]);
    assert.ok(fx.apiCalls().some((call) => call.path === "/runtimes/dev"));
  } finally {
    await fx.restore();
  }
  const inside = makeFixture();
  try {
    inside.setPanes([selfPane()]);
    await withEnv({ KO_RUNTIME: "box" }, async () => {
      const s = await startSession(inside, { flags: { runtime: "ignored" } });
      const spawnAgent = (params: Record<string, unknown>) => s.tools.get("spawn_agent").execute("c", { task: "go", ...params });
      const reply = text(await spawnAgent({ name: "kid" }));
      const [body] = inside.posts("/panes") as Body[];
      assert.equal(body!.runtime, undefined);
      assert.ok(!body!.command.argv.includes("--runtime"));
      assert.match(reply, /pane pane_10, in runtime box\);/);
      assert.match(text(await spawnAgent({ name: "other", runtime: "else" })), /runs inside runtime box; its children run there too/);
      assert.equal(inside.apiCalls().some((call) => call.path.startsWith("/runtimes")), false, "an inside agent reads no /runtimes route");
      assert.deepEqual(await s.emit("user_bash", {}), [undefined], "the inside mode routes nothing");
      assert.equal(inside.row("pane_1")?.vars?.["pi.runtime"], undefined);
    });
  } finally {
    await inside.restore();
  }
});

test("list_agents shows the runtime of a row or of a routed agent's pi.runtime, and its runtime cwd; messages name the sender's runtime", async () => {
  const fx = makeFixture();
  try {
    const t = tree(fx);
    fx.setPanes([
      selfPane(),
      agentPane({ pane: "pane_2", session: "s-routed", name: "Routed", cwd: "/host/proj", vars: { "pi.runtime": { name: "dev", cwd: "/work/proj" } } }),
      { ...agentPane({ pane: "pane_3", session: "s-inside", name: "Inside", cwd: "/work" }), runtime: "inner" } as never,
      agentPane({ pane: "pane_4", session: "s-host", name: "Host", cwd: "/host" }),
    ]);
    const s = await routed(fx, t);
    const rows = JSON.parse(text(await s.tools.get("list_agents").execute("c", {}))) as Array<Record<string, any>>;
    const by = Object.fromEntries(rows.map((row) => [row.name, row]));
    assert.deepEqual([by.Routed.runtime, by.Routed.cwd], ["dev", "/work/proj"]);
    assert.deepEqual([by.Inside.runtime, by.Inside.cwd], ["inner", "/work"]);
    assert.deepEqual([by.Host.runtime, by.Host.cwd], [undefined, "/host"]);

    await s.tools.get("message_agent").execute("c", { to: "Host", message: "hello" });
    assert.deepEqual((fx.posts("/panes/pane_4/messages")[0] as Body).data, { runtime: "dev" });

    fx.feed({ id: "from-routed-1", kind: "message", text: "hi", relation: "sibling", data: { runtime: "dev" }, from: { type: "pane", pane: "pane_2", session: "s-routed", name: "Routed" } });
    await pollUntil(() => customMessages(s, "ko-message").length === 1, 3000, "the message");
    assert.equal(customMessages(s, "ko-message")[0]!.message.content, `${senderHeader("Routed", "sibling", "dev")}\nhi`);
    assert.equal(senderHeader("Routed", "sibling", "dev"), "message from @Routed (another agent in this session, not the user, in runtime dev):");
  } finally {
    await fx.restore();
  }
});

test("the exec client drives a real ko server with a command-kind runtime the way it drives the fake", async (context) => {
  const repo = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
  const bin = join(repo, "build", "ko", "bin");
  if (!existsSync(join(bin, "ko"))) {
    if (process.env.KO_TS_TEST_REQUIRED === "1") assert.fail("build/ko/bin/ko is missing: run make build");
    context.skip("build/ko/bin/ko is missing");
    return;
  }
  const fx = makeFixture();
  const t = tree(fx);
  const state = realpathSync(mkdtempSync("/tmp/ko-pi-real-"));
  writeFileSync(join(state, "config.yaml"), `runtimes:
  dev:
    command: {}
    env:
      HOME: /var/empty
    cwd: ${join(t.rt, "fallback")}
    paths:
      - host: ${t.host}
        runtime: ${t.rt}
`);
  const server = spawn(join(bin, "ko"), ["server", "--server", state, "--config", join(state, "config.yaml")], {
    env: { PATH: "/usr/bin:/bin", HOME: state, SHELL: "/bin/sh", KO_RUNTIME_COMMAND_KIND: "1" },
    stdio: "ignore",
  });
  try {
    await pollUntil(() => spawnSync(join(bin, "ko"), ["api", "/runtimes"], { env: { PATH: "/usr/bin:/bin", KO_STATE_DIR: state } }).status === 0, 10000, "the server to answer a request");
    const real = { PATH: `${bin}${delimiter}/usr/bin${delimiter}/bin`, KO_STATE_DIR: state, KO_SOCKET: join(state, "socket"), KO_PANE: undefined };
    await withEnv(real, async () => {
      const s = await startSession(fx, { flags: { runtime: "dev" }, ctx: { cwd: t.hostCwd } });
      assert.equal(s.notifications.length, 1);
      assert.equal(text(await run(s, "bash", { command: "pwd; echo \"$KO_RUNTIME\"" })).trim(), `${join(t.rt, "proj")}\ndev`);
      assert.match(text(await run(s, "bash", { command: "exit 5" })), /exited with code 5/);
      const job = await run(s, "async_bash", { command: "printf real-runtime-job; exit 3", name: "real-job" });
      assert.match(text(job), /^started job j[a-z0-9]{7}/);
      await pollUntil(() => notices(s).length === 1, 5000, "the real runtime job notice");
      assert.match(notices(s)[0]!, /exit 3/);
      assert.match(notices(s)[0]!, /real-runtime-job/);
      assert.equal(readFileSync(job.details.log, "utf8"), "real-runtime-job");
      assert.match(text(await run(s, "bash", { command: "kill -9 $$" })), /exited with code 137/);
      const awkward = `it's "a" file.txt`;
      const big = Array.from({ length: 4000 }, (_, line) => `line ${line} é ${"y".repeat(60)}`).join("\n");
      await run(s, "write", { path: `a b/${awkward}`, content: big });
      assert.equal(readFileSync(join(t.rt, "proj", "a b", awkward), "utf8"), big);
      assert.match(text(await run(s, "read", { path: `${t.hostCwd}/a b/${awkward}`, limit: 2 })), /^line 0 é/);
      assert.ok(text(await run(s, "ls", { path: "a b" })).includes(awkward));
      await assert.rejects(run(s, "read", { path: "missing" }), /No such file/);
    });
  } finally {
    spawnSync(join(bin, "ko"), ["kill-server", "--server", state]);
    await pollUntil(() => server.exitCode !== null || server.signalCode !== null, 5000, "the test server to exit");
    rmSync(state, { recursive: true, force: true });
    await fx.restore();
  }
});
