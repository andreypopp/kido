import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { Readable } from "node:stream";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { pollUntil, ofType, sse, selfPane, agentPane, exited } from "./koa-agent-fixture.ts";
import { realFixture, writeSession } from "./koa-program-fixture.ts";

type App = Awaited<ReturnType<typeof realFixture>>;
const send = (app: App, text: string, mode = "prompt") => app.post("prompt", { text, mode, attachments: [] });
const note = (text: string) => ofType("item", record => record.item.kind === "notify" && record.item.text.text.includes(text));
const state = (app: App) => {
  const found = app.records().filter(ofType("state")).at(-1);
  assert.ok(found);
  return found;
};
const fresh = async (app: App, t: { after(fn: () => void): void }) => {
  const controller = new AbortController();
  t.after(() => controller.abort());
  return sse(Readable.from((await fetch(app.base + "events", { signal: controller.signal })).body ?? []));
};

test("a cancelled switch leaves the old session; a switch and a new session refresh the state; a stale body is refused", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [],
    extensions: { "cancel.ts": `export default function (pi) { pi.on("session_before_switch", (event) => event.reason === "resume" ? { cancel: true } : undefined); }\n` },
    setup: async ({ cwd, sessions }) => { await writeSession(cwd, sessions, 1, "other"); },
  });
  const before = state(app);
  const rows = await (await app.post("sessions/list", { scope: "current" })).json();
  assert.equal(rows.rows.length, 1);
  assert.deepEqual(await (await app.post("sessions/switch", { path: rows.rows[0].path })).json(), { cancelled: true });
  assert.equal(state(app).sessionId, before.sessionId);
  assert.equal(state(app).pi.type, "ready");
  const stale = before.sessionId;
  assert.equal((await app.post("sessions/new")).status, 200);
  await app.until(note("new session"));
  assert.notEqual(state(app).sessionId, stale);
  assert.equal((await app.post("prompt", { sessionId: stale, text: "late", mode: "prompt", attachments: [] })).status, 409);
});

test("a switch that fails after teardown ends in the failed state and Start again recovers", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [], args: ["--provider", "fake", "--model", "fake-model"], setup: async ({ cwd, sessions }) => { await writeSession(cwd, sessions, 1, "other"); } });
  const rows = (await (await app.post("sessions/list", { scope: "current" })).json()).rows;
  const models = join(app.agentDir, "models.json"), good = await readFile(models, "utf8");
  await writeFile(models, JSON.stringify({ providers: {} }));
  const switched = await app.post("sessions/switch", { path: rows[0].path });
  assert.equal(switched.status, 409, await switched.text());
  const failed = await app.until(ofType("state", record => record.pi.type === "failed")).catch(error => { throw new Error("no failed state: " + String(error) + app.stderr()); });
  assert.match(JSON.stringify(failed.pi), /model/i);
  await writeFile(models, good);
  const start = await app.post("agent/start");
  assert.equal(start.status, 200, await start.text() + app.stderr());
  await pollUntil(() => state(app).pi.type === "ready", 5000, "ready after Start again: " + JSON.stringify(state(app).pi) + app.stderr());
});

test("startup UI of an extension survives /new", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [], extensions: { "ui.ts": `export default function (pi) { pi.on("session_start", (_e, ctx) => { ctx.ui.notify("hello startup", "info"); ctx.ui.setStatus("probe", "ready"); }); }\n` } });
  await app.until(note("hello startup"));
  const cursor = app.count();
  await app.post("sessions/new");
  await app.until(note("hello startup"), cursor);
  assert.equal(state(app).statuses.probe, "ready");
});

test("/name sets and reports the session name; an empty /name only reports", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  await send(app, "/name");
  await app.until(note("Usage: /name"));
  await send(app, "/name  renamed ");
  await app.until(note("Session name set: renamed"));
  assert.equal(state(app).name, "renamed");
  await send(app, "/name");
  await app.until(note("Session name: renamed"));
});

test("a queued steer and follow-up are removed one at a time, kept in order, and cleared", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [{ gate: "turn", text: "first answer" }, { text: "second" }, { text: "third" }] });
  await send(app, "start");
  await app.until(ofType("state", record => record.working === true));
  for (const [text, mode] of [["steer one", "steer"], ["steer two", "steer"], ["later", "follow_up"]] as const) assert.equal((await send(app, text, mode)).status, 200);
  await app.until(ofType("state", record => record.queue.steering.length === 2 && record.queue.followUp.length === 1));
  assert.equal((await app.post("queue/remove", { kind: "steer", index: 0, text: "steer one" })).status, 200);
  await app.until(ofType("state", record => record.queue.steering.length === 1 && record.queue.steering[0].text === "steer two" && record.queue.followUp[0]?.text === "later"));
  const cleared = await (await app.post("queue/clear")).json();
  assert.deepEqual([cleared.steering.map((entry: { text: string }) => entry.text), cleared.followUp.map((entry: { text: string }) => entry.text)], [["steer two"], ["later"]]);
  await app.until(ofType("state", record => record.queue.steering.length === 0 && record.queue.followUp.length === 0));
  assert.equal((await app.post("queue/remove", { kind: "steer", index: 0, text: "gone" })).status, 409);
});

test("reply annotations reach events live and on a rebuild", { timeout: 30000 }, async t => {
  const entry = { reply: { at: 0, block: 0, length: 17 }, annotations: [{ type: "question", kind: "yes_no", range: [0, 17], options: [] }] };
  const app = await realFixture(t, { replies: [], setup: async ({ cwd, sessions }) => {
    const manager = SessionManager.create(cwd, sessions);
    manager.appendMessage({ role: "user", content: "ask", timestamp: 1 });
    const message = { role: "assistant" as const, content: [{ type: "text" as const, text: "Should I proceed?" }], api: "openai-completions", provider: "fake", model: "fake-model", usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop" as const, timestamp: 42 };
    manager.appendMessage(message);
    manager.appendCustomEntry("reply-annotations", { ...entry, reply: { at: 42, block: 0, length: 17 } });
    return ["--session", manager.getSessionFile() ?? ""];
  } });
  const replay = await (await fresh(app, t)).until(ofType("reset", record => record.items.some(item => item.kind === "annotations")));
  assert.equal(replay.items.filter(item => item.kind === "annotations").length, 1);
});

test("a bang command with huge output is capped and the transcript keeps the cap", { timeout: 30000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  await send(app, "!head -c 3000000 /dev/zero | tr '\\0' 'x'");
  const done = await app.until(ofType("state", record => record.bash.some(item => item.phase === "completed")));
  const bash = done.bash.find(item => item.phase === "completed");
  assert.ok(bash && bash.phase === "completed");
  assert.ok(bash.result.truncated || bash.result.output.cut > 0);
  assert.ok(bash.result.output.text.length < 3000000);
});

test("completion lists extension commands, prompt templates and skills, and not the built-ins twice", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [], resources: true,
    extensions: { "cmd.ts": `export default function (pi) { pi.registerCommand("zzcmd", { description: "extension command", handler: async () => {} }); }\n` },
    setup: async ({ dir }) => {
      const agent = join(dir, "agent");
      await mkdir(join(agent, "prompts"), { recursive: true }); await mkdir(join(agent, "skills", "zzskill"), { recursive: true });
      await writeFile(join(agent, "prompts", "zztemplate.md"), "---\ndescription: a template\n---\nDo $1\n");
      await writeFile(join(agent, "skills", "zzskill", "SKILL.md"), "---\nname: zzskill\ndescription: a skill\n---\nSkill body\n");
    },
  });
  const options: { label: string; source: string }[] = (await (await app.post("complete", { text: "/zz", pos: 3 })).json()).options;
  assert.deepEqual(options.map(option => [option.label, option.source]).sort(), [["/skill:zzskill", "skill"], ["/zzcmd", "extension"], ["/zztemplate", "prompt"]].sort());
  const labels: string[] = (await (await app.post("complete", { text: "/", pos: 1 })).json()).options.map((option: { label: string }) => option.label);
  assert.equal(labels.filter(label => label === "/model").length, 1);
});

test("an extension command runs while a turn is busy and a template expands before the provider", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [{ gate: "turn", text: "slow" }, { text: "templated" }], resources: true,
    extensions: { "cmd.ts": `export default function (pi) { pi.registerCommand("ping", { description: "ping", handler: async (_a, ctx) => { ctx.ui.notify("pong", "info"); } }); }\n` },
    setup: async ({ dir }) => { await mkdir(join(dir, "agent", "prompts"), { recursive: true }); await writeFile(join(dir, "agent", "prompts", "greet.md"), "---\ndescription: g\n---\nGreet $1 warmly\n"); },
  });
  await send(app, "work");
  await app.until(ofType("state", record => record.working === true));
  assert.equal((await send(app, "/ping")).status, 200);
  await app.until(note("pong"));
  assert.equal(app.provider.requests.length, 1);
  app.provider.release("turn");
  await app.until(ofType("state", record => record.working === false), app.count());
  await send(app, "/greet bob");
  await pollUntil(() => app.provider.requests.length === 2, 10000, "the template prompt");
  assert.match(JSON.stringify(app.provider.requests[1]?.body.messages.at(-1)), /Greet bob warmly/);
});

test("project trust: the startup context has no UI; an untrusted project does not load, a granted one does", { timeout: 40000 }, async t => {
  for (const decision of ["undecided", "yes"]) {
    const app = await realFixture(t, {
      replies: [], discover: true,
      extensions: { "trust.ts": `import { appendFileSync } from "node:fs"; export default function (pi) {
        pi.on("project_trust", (_e, ctx) => { appendFileSync(process.env.TRUST_LOG, JSON.stringify({ event: "trust", mode: ctx.mode, hasUI: ctx.hasUI }) + "\\n"); return { trusted: ${JSON.stringify(decision)} }; });
        pi.on("session_start", (_e, ctx) => { appendFileSync(process.env.TRUST_LOG, JSON.stringify({ event: "start", hasUI: ctx.hasUI }) + "\\n"); });
      }\n` },
      setup: async ({ dir, cwd }) => {
        await mkdir(join(cwd, ".pi", "extensions"), { recursive: true });
        await writeFile(join(cwd, ".pi", "extensions", "local.ts"), `export default function (pi) { pi.registerCommand("localcmd", { description: "local", handler: async () => {} }); }\n`);
        await writeFile(join(dir, "trust.log"), "");
      },
      env: { TRUST_LOG: `/tmp/koa-trust-${process.pid}-${decision}.log` },
    });
    const lines = (await readFile(`/tmp/koa-trust-${process.pid}-${decision}.log`, "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    assert.deepEqual(lines.find(line => line.event === "trust"), { event: "trust", mode: "rpc", hasUI: false });
    assert.equal(lines.find(line => line.event === "start")?.hasUI, true);
    const labels: string[] = (await (await app.post("complete", { text: "/local", pos: 6 })).json()).options.map((option: { label: string }) => option.label);
    assert.equal(labels.includes("/localcmd"), decision === "yes");
  }
});



test("a turn that an extension starts at session_start survives /new", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [{ gate: "turn", text: "started reply" }],
    extensions: { "start.ts": `export default function (pi) { pi.on("session_start", (event) => { if (event.reason === "new") pi.sendUserMessage("hello from start"); }); }\n` },
  });
  const cursor = app.count();
  await app.post("sessions/new");
  await app.until(ofType("state", record => record.working === true && record.pi.type === "ready"), cursor);
  await pollUntil(() => app.provider.requests.length === 1, 10000, "the startup turn request");
  app.provider.release("turn");
  await app.until(ofType("item", record => record.item.kind === "assistant" && JSON.stringify(record.item.blocks).includes("started reply")), cursor);
  await app.until(ofType("state", record => record.working === false), app.count() - 1);
});

test("a prompt queued behind a slow input hook does not reach the session that replaced its own", { timeout: 40000 }, async t => {
  const gate = `/tmp/koa-input-gate-${process.pid}`;
  const app = await realFixture(t, {
    replies: [{ text: "never" }],
    extensions: { "slow.ts": `import { existsSync, appendFileSync } from "node:fs"; export default function (pi) { pi.on("input", async (event) => { if (event.text !== "slow") return; appendFileSync(${JSON.stringify(gate + ".entered")}, "x"); for (let i = 0; i < 500 && !existsSync(${JSON.stringify(gate)}); i++) await new Promise(resolve => setTimeout(resolve, 20)); }); }\n` },
  });
  const slow = send(app, "slow");
  await pollUntil(() => readFile(gate + ".entered", "utf8").then(() => true, () => false), 10000, "the slow hook");
  const second = send(app, "second");
  await app.post("complete", { text: "x", pos: 1 });
  assert.equal((await app.post("sessions/new")).status, 200);
  await writeFile(gate, "");
  assert.equal((await second).status, 409);
  await slow.catch(() => undefined);
  assert.ok(!app.provider.requests.some(request => JSON.stringify(request.body.messages).includes("second")));
});

test("an extension's ctx.newSession() resets and refreshes the page like /new", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [],
    extensions: { "cmd.ts": `export default function (pi) { pi.registerCommand("newsess", { description: "new", handler: async (_a, ctx) => { await ctx.newSession(); } }); }\n` },
    setup: async ({ cwd, sessions }) => ["--session", await writeSession(cwd, sessions, 1, "old")],
  });
  const before = state(app);
  assert.ok(before.sessionFile);
  await send(app, "/newsess");
  await pollUntil(() => state(app).sessionId !== before.sessionId && state(app).pi.type === "ready", 10000, "the new session");
  assert.notEqual(state(app).sessionFile, before.sessionFile);
  const replay = await (await fresh(app, t)).until(ofType("reset"));
  assert.equal(replay.items.filter(item => item.kind === "user" || item.kind === "assistant").length, 0);
});

test("an extension's ctx.navigateTree() rebuilds the transcript and puts the entry's text in the composer", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [],
    extensions: { "tree.ts": `export default function (pi) { pi.registerCommand("back", { description: "back", handler: async (_a, ctx) => { const first = ctx.sessionManager.getEntries().find(entry => entry.type === "message" && entry.message.role === "user"); await ctx.navigateTree(first.id); } }); }\n` },
    setup: async ({ cwd, sessions }) => ["--session", await writeSession(cwd, sessions, 2, "tree")],
  });
  await send(app, "/back");
  await pollUntil(() => state(app).editor?.text === "tree 0", 10000, "the editor text of the first entry");
  const replay = await (await fresh(app, t)).until(ofType("reset"));
  assert.equal(replay.items.filter(item => item.kind === "assistant").length, 0);
});


test("a held switch shows the switching phase, then the old session answers ready again", { timeout: 30000 }, async t => {
  const gate = join(await mkdtemp(join(tmpdir(), "koa-switch-gate-")), "gate");
  t.after(() => rm(dirname(gate), { recursive: true, force: true }));
  const app = await realFixture(t, {
    replies: [], env: { KOA_GATE: gate },
    extensions: { "hold.ts": `import { existsSync } from "node:fs";\nexport default function (pi) { pi.on("session_before_switch", async () => { while (!existsSync(process.env.KOA_GATE)) await new Promise(resolve => setTimeout(resolve, 5)); }); }\n` },
    setup: async ({ cwd, sessions }) => { await writeSession(cwd, sessions, 1, "other"); },
  });
  const before = state(app).sessionId;
  const rows = (await (await app.post("sessions/list", { scope: "current" })).json()).rows;
  const switched = app.post("sessions/switch", { path: rows[0].path });
  await app.until(ofType("state", record => record.pi.type === "switching"));
  assert.equal(state(app).sessionId, before);
  await writeFile(gate, "");
  assert.equal((await switched).status, 200);
  await pollUntil(() => state(app).pi.type === "ready" && state(app).sessionId !== before, 5000, "the switched session ready");
});

test("an extension dialog expires at its timeout, and only a valid answer closes one", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [],
    extensions: { "ask.ts": `export default function (pi) {
  pi.registerCommand("ask", { description: "ask", handler: async (_args, ctx) => { ctx.ui.notify("answer:" + await ctx.ui.select("Pick", ["a", "b"], { timeout: 300 }), "info"); } });
  pi.registerCommand("pick", { description: "pick", handler: async (_args, ctx) => { ctx.ui.notify("picked:" + await ctx.ui.select("Pick", ["a", "b"]), "info"); ctx.ui.notify("confirmed:" + await ctx.ui.confirm("Sure", "really?"), "info"); } });
}\n` },
  });
  void send(app, "/ask");
  const shown = await app.until(ofType("state", record => record.dialogs.length === 1));
  assert.equal(shown.dialogs[0]?.method === "select" && shown.dialogs[0].timeout, 300);
  assert.equal(typeof shown.dialogs[0]?.expires, "number");
  await app.until(note("answer:undefined"));
  assert.deepEqual(state(app).dialogs, []);
  const cursor = app.count();
  void send(app, "/pick");
  const select = (await app.until(ofType("state", record => record.dialogs.length === 1), cursor)).dialogs[0];
  assert.ok(select);
  const answer = async (body: object) => app.post("dialog", { id: select.id, ...body });
  assert.equal((await app.post("dialog", { id: "missing", value: "a" })).status, 409);
  assert.equal((await answer({ value: "zzz" })).status, 409);
  assert.equal((await answer({ confirmed: true })).status, 409);
  assert.deepEqual(state(app).dialogs.map(dialog => dialog.id), [select.id]);
  assert.equal((await answer({ value: "b" })).status, 200);
  await app.until(note("picked:b"));
  const confirm = (await app.until(ofType("state", record => record.dialogs.some(dialog => dialog.method === "confirm")), cursor)).dialogs[0];
  assert.ok(confirm);
  assert.equal((await app.post("dialog", { id: confirm.id, value: "yes" })).status, 409);
  assert.equal((await app.post("dialog", { id: confirm.id, confirmed: false })).status, 200);
  await app.until(note("confirmed:false"));
});

test("@ completion lists the named running agents of this ko session, not koa's own pane", { timeout: 30000 }, async t => {
  const app = await realFixture(t, {
    replies: [],
    panes: [
      selfPane(),
      agentPane({ pane: "pane_2", session: "alpha-session", name: "alpha" }),
      agentPane({ pane: "pane_3", session: "unnamed-session" }),
      agentPane({ pane: "pane_4", session: "beta-session", name: "beta", koSession: "session_2" }),
      agentPane({ pane: "pane_5", session: "gone-session", name: "gone", dead: exited(0) }),
    ],
  });
  const labels = async () => {
    const body: { options: { kind: string; label: string }[] } = await (await app.post("complete", { text: "@", pos: 1 })).json();
    return body.options.filter(option => option.kind === "agent").map(option => option.label);
  };
  await pollUntil(async () => (await labels()).length > 0, 5000, "agent discovery");
  assert.deepEqual(await labels(), ["@alpha"]);
});
