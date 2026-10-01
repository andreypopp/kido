// One suite covers kido-status.ts and kido-agents.ts together, since that pair is
// what a real pi host loads and every case here needs both the status half's
// inbox and the agent half's dispatch. It drives the extensions only through what
// a real pi host and peer agent would use: registered tools, registered lifecycle
// events, and a real unix socket speaking the inbox wire protocol - never by
// reaching into either module's closures.
//
// A fake `kido` executable stands in for the real binary on PATH; a "reply" is
// never actually delivered anywhere, but injected directly onto the extension's
// own inbox socket, exactly as a real peer's `kido tool message_agent` would arrive.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Value } from "typebox/value";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdtempSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter, dirname } from "node:path";
import net from "node:net";
import { fileURLToPath, pathToFileURL } from "node:url";
import kidoStatus, { parseEnvelope } from "./kido-status.ts";
import { AgentSession } from "@earendil-works/pi-coding-agent";
import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
import kidoAgents, { isAncestor, streamBatch } from "./kido-agents.ts";

// Written to disk once per fixture as a file literally named "kido": findKido()
// joins a PATH entry with that name and checks it is executable, nothing fancier.
const FAKE_KIDO = `#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

function readStdin() {
  try { return fs.readFileSync(0, "utf8"); } catch { return ""; }
}

const argv = process.argv.slice(2);
const args = argv[0] === "tool" ? argv.slice(1) : argv;
if ([
  "list_agents", "message_agent", "ask_agent", "notify_parent", "steer_subagent",
  "interrupt_subagent", "stop_subagent", "set_status", "spawn_subagent", "async_bash",
].includes(args[0]) && argv[0] !== "tool") process.exit(1);
switch (args[0]) {
  case "get-inbox": {
    if (process.env.KIDO_FAKE_INBOX_FAIL === "1") process.exit(1);
    const dir = process.env.KIDO_FAKE_INBOX_DIR;
    process.stdout.write(JSON.stringify({ path: path.join(dir, args[1] + ".sock") }) + "\\n");
    process.exit(0);
  }
  case "list_agents": {
    const file = process.env.KIDO_FAKE_AGENTS_FILE;
    const callLog = process.env.KIDO_FAKE_AGENTS_CALL_LOG;
    if (callLog) fs.appendFileSync(callLog, "1\\n");
    const respond = () => {
      process.stdout.write(file && fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "[]");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_AGENTS_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "get-agent": {
    if (args.includes("--children")) {
      const logFile = process.env.KIDO_FAKE_CHILDREN_ALIVE_LOG;
      if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
      const mode = process.env.KIDO_FAKE_CHILDREN_ALIVE;
      if (mode === "fail") process.exit(1);
      const respond = () => {
        process.stdout.write(JSON.stringify({ id: args[1], alive: true, childrenAlive: mode === "1" }) + "\\n");
        process.exit(0);
      };
      if (mode === "timeout") setTimeout(respond, 10000); else respond();
      break;
    }
    const logFile = process.env.KIDO_FAKE_PARENT_ALIVE_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    // Named sessions answer "false" whatever the global mode says, so a test can
    // kill one mid-run while an asker is already waiting on it.
    const deadFile = process.env.KIDO_FAKE_DEAD_FILE;
    if (deadFile && fs.existsSync(deadFile)) {
      const dead = fs.readFileSync(deadFile, "utf8").split("\\n").filter(Boolean);
      if (dead.includes(args[1])) {
        process.stdout.write(JSON.stringify({ id: args[1], alive: false }) + "\\n");
        process.exit(0);
      }
    }
    const mode = process.env.KIDO_FAKE_PARENT_ALIVE ?? "1";
    const respond = () => {
      if (mode === "fail") {
        process.stderr.write("kido get-agent: nope\\n");
        process.exit(1);
      }
      process.stdout.write(JSON.stringify({ id: args[1], alive: mode === "1" }) + "\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "agent-status": {
    const logFile = process.env.KIDO_FAKE_STATUS_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    // Logged first, so a test can tell "the claim was attempted and refused" from
    // "nothing was ever sent".
    if (process.env.KIDO_FAKE_SESSION_HELD) {
      process.stderr.write("session " + args[args.indexOf("--session") + 1] +
        " is already open in pane %9 (pid 4242); this process is not tracked\\n");
      process.exit(6);
    }
    process.exit(0);
  }
  case "set_status": {
    const logFile = process.env.KIDO_FAKE_SET_STATUS_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    process.exit(0);
  }
  // Share one log, keyed by the kind each implies, since what every test here asks
  // is what went out on the wire. notify_parent's target is not an argument: the
  // real command reads it out of its own environment, so the fake does too.
  case "message_agent":
  case "ask_agent":
  case "steer_subagent":
  case "notify_parent": {
    let replyTo = "", id = "", to = null;
    for (let i = 1; i < args.length; i++) {
      if (args[i] === "--reply-to") replyTo = args[++i];
      else if (args[i] === "--id") id = args[++i];
      else if (args[i] === "--") { to = args[i + 1]; break; }
    }
    let kind = "message";
    if (args[0] === "ask_agent") kind = "ask";
    else if (args[0] === "steer_subagent") kind = "steer";
    else if (args[0] === "notify_parent") {
      kind = "notice";
      to = process.env.KIDO_AGENT_PARENT_SESSION ?? null;
    } else if (replyTo) kind = "reply";
    const text = readStdin();
    const respond = () => {
      const failed = !!(process.env.KIDO_FAKE_MESSAGE_FAIL_TO && to === process.env.KIDO_FAKE_MESSAGE_FAIL_TO);
      // Logged either way: a test asserting a dropped delivery still needs to see
      // the attempt was made, with the right kind and target.
      const logFile = process.env.KIDO_FAKE_LOG;
      if (logFile) fs.appendFileSync(logFile, JSON.stringify({ kind, replyTo, id, to, text, failed }) + "\\n");
      if (failed) {
        process.stderr.write("kido tool " + args[0] + ": no agent listening on the inbox\\n");
        process.exit(1);
      }
      process.stdout.write("delivered to " + to + " by inbox\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_MESSAGE_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "spawn_subagent": {
    const logFile = process.env.KIDO_FAKE_SPAWN_LOG;
    const task = readStdin();
    if (logFile) fs.appendFileSync(logFile, JSON.stringify({ args: argv, task }) + "\\n");
    const respond = () => {
      process.stdout.write("@9 %9 fake-run-id\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_SPAWN_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "run-outcome": {
    const logFile = process.env.KIDO_FAKE_RUN_OUTCOME_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    process.exit(0);
  }
  case "close-run": {
    const logFile = process.env.KIDO_FAKE_CLOSE_RUN_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    process.exit(0);
  }
  case "get-window": {
    const logFile = process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    process.stdout.write(JSON.stringify({ id: args[1], focused: process.env.KIDO_FAKE_WINDOW_FOCUSED === "1" }) + "\\n");
    process.exit(0);
  }
  case "interrupt_subagent":
  case "stop_subagent": {
    const logFile = process.env.KIDO_FAKE_CONTROL_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    process.stdout.write((args[0] === "interrupt_subagent" ? "interrupted " : "stopped ") + args[args.length - 1] + "\\n");
    process.exit(0);
  }
  case "async_bash": {
    const logFile = process.env.KIDO_FAKE_ASYNC_BASH_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(argv) + "\\n");
    // Four fields, the last the run's output file, exactly as
    // Spawn_subagent.create_run_window writes them for a bash run.
    const runID = "fake-async-run-id";
    const output = process.env.KIDO_FAKE_STATE_DIR + "/runs/" + runID + "/output";
    process.stdout.write("@9 %9 " + runID + " " + output + "\\n");
    process.exit(0);
  }
  default:
    process.exit(1);
}
`;

interface Fixture {
  agentsFile: string;
  logFile: string;
  inboxDir: string;
  setAgents(agents: unknown[]): void;
  setParentAlive(mode: "alive" | "gone" | "fail"): void;
  killSession(session: string): void;
  setParentAliveDelay(ms: number): void;
  parentAliveCalls(): string[][];
  setInboxFail(fail: boolean): void;
  setMessageFailTo(to: string | undefined): void;
  setWindowFocused(focused: boolean): void;
  windowFocusedCallCount(): number;
  setChildrenAlive(alive: boolean): void;
  childrenAliveCalls(): string[][];
  selfInboxPath(): string;
  lastLogFor(to: string, kind?: string): { id: string; replyTo: string; to: string; text: string; failed?: boolean } | undefined;
  lastSpawnArgs(): string[] | undefined;
  lastSpawnTask(): string | undefined;
  lastRunOutcomeArgs(): string[] | undefined;
  lastAsyncBashArgs(): string[] | undefined;
  runsDir: string;
  waitForCloseRun(ms?: number): Promise<string[]>;
  lastStatusArgs(): string[] | undefined;
  setStatusCalls(): string[][];
  statusReportsWith(status: string): string[][];
  statusReportCount(): number;
  statusReportsWithRemove(): string[][];
  agentsCallCount(): number;
  lastControlArgs(): string[] | undefined;
  waitForLog(to: string, kind?: string, ms?: number): Promise<{ id: string; replyTo: string; to: string; text: string; failed?: boolean }>;
  restore(): void;
}

function jsonLines(file: string): any[] {
  return readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function last<T>(items: T[]): T | undefined {
  return items[items.length - 1];
}

function makeFixture(): Fixture {
  const dir = mkdtempSync(join(tmpdir(), "kido-status-test-"));
  const binDir = join(dir, "bin");
  mkdirSync(binDir);
  writeFileSync(join(binDir, "kido"), FAKE_KIDO, { mode: 0o755 });
  const inboxDir = join(dir, "inbox");
  const agentsFile = join(dir, "agents.json");
  const logFile = join(dir, "log.jsonl");
  const spawnLogFile = join(dir, "spawn.jsonl");
  const closeRunLogFile = join(dir, "close-run.jsonl");
  const statusLogFile = join(dir, "status.jsonl");
  const setStatusLogFile = join(dir, "set-status.jsonl");
  const controlLogFile = join(dir, "control.jsonl");
  const runOutcomeLogFile = join(dir, "run-outcome.jsonl");
  const asyncBashLogFile = join(dir, "async-bash.jsonl");
  const agentsCallLogFile = join(dir, "agents-calls.jsonl");
  const parentAliveLogFile = join(dir, "parent-alive.jsonl");
  const stateDir = join(dir, "state");
  const deadSessionsFile = join(dir, "dead-sessions");
  writeFileSync(deadSessionsFile, "");
  writeFileSync(agentsFile, "[]");
  writeFileSync(logFile, "");
  writeFileSync(spawnLogFile, "");
  writeFileSync(closeRunLogFile, "");
  writeFileSync(statusLogFile, "");
  writeFileSync(setStatusLogFile, "");
  writeFileSync(controlLogFile, "");
  writeFileSync(runOutcomeLogFile, "");
  writeFileSync(asyncBashLogFile, "");
  writeFileSync(agentsCallLogFile, "");
  writeFileSync(parentAliveLogFile, "");
  const windowFocusedLogFile = join(dir, "get-window.jsonl");
  writeFileSync(windowFocusedLogFile, "");
  const childrenAliveLogFile = join(dir, "get-agent --children.jsonl");
  writeFileSync(childrenAliveLogFile, "");

  const saved = {
    PATH: process.env.PATH,
    TMUX_PANE: process.env.TMUX_PANE,
    KIDO_FAKE_AGENTS_FILE: process.env.KIDO_FAKE_AGENTS_FILE,
    KIDO_FAKE_LOG: process.env.KIDO_FAKE_LOG,
    KIDO_FAKE_SPAWN_LOG: process.env.KIDO_FAKE_SPAWN_LOG,
    KIDO_FAKE_CLOSE_WINDOW_LOG: process.env.KIDO_FAKE_CLOSE_WINDOW_LOG,
    KIDO_FAKE_STATUS_LOG: process.env.KIDO_FAKE_STATUS_LOG,
    KIDO_FAKE_SET_STATUS_LOG: process.env.KIDO_FAKE_SET_STATUS_LOG,
    KIDO_FAKE_CONTROL_LOG: process.env.KIDO_FAKE_CONTROL_LOG,
    KIDO_FAKE_RUN_OUTCOME_LOG: process.env.KIDO_FAKE_RUN_OUTCOME_LOG,
    KIDO_FAKE_ASYNC_BASH_LOG: process.env.KIDO_FAKE_ASYNC_BASH_LOG,
    KIDO_FAKE_STATE_DIR: process.env.KIDO_FAKE_STATE_DIR,
    KIDO_FAKE_AGENTS_CALL_LOG: process.env.KIDO_FAKE_AGENTS_CALL_LOG,
    KIDO_FAKE_PARENT_ALIVE_LOG: process.env.KIDO_FAKE_PARENT_ALIVE_LOG,
    KIDO_FAKE_PARENT_ALIVE: process.env.KIDO_FAKE_PARENT_ALIVE,
    KIDO_FAKE_PARENT_ALIVE_DELAY_MS: process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS,
    KIDO_FAKE_DEAD_FILE: process.env.KIDO_FAKE_DEAD_FILE,
    KIDO_FAKE_WINDOW_FOCUSED_LOG: process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG,
    KIDO_FAKE_WINDOW_FOCUSED: process.env.KIDO_FAKE_WINDOW_FOCUSED,
    KIDO_FAKE_CHILDREN_ALIVE_LOG: process.env.KIDO_FAKE_CHILDREN_ALIVE_LOG,
    KIDO_FAKE_CHILDREN_ALIVE: process.env.KIDO_FAKE_CHILDREN_ALIVE,
    KIDO_FAKE_INBOX_DIR: process.env.KIDO_FAKE_INBOX_DIR,
    KIDO_FAKE_INBOX_FAIL: process.env.KIDO_FAKE_INBOX_FAIL,
    KIDO_FAKE_MESSAGE_FAIL_TO: process.env.KIDO_FAKE_MESSAGE_FAIL_TO,
    KIDO_FAKE_MESSAGE_DELAY_MS: process.env.KIDO_FAKE_MESSAGE_DELAY_MS,
    KIDO_FAKE_AGENTS_DELAY_MS: process.env.KIDO_FAKE_AGENTS_DELAY_MS,
  };
  process.env.PATH = binDir + delimiter + (saved.PATH ?? "");
  process.env.TMUX_PANE = "%1";
  process.env.KIDO_FAKE_AGENTS_FILE = agentsFile;
  process.env.KIDO_FAKE_LOG = logFile;
  process.env.KIDO_FAKE_SPAWN_LOG = spawnLogFile;
  process.env.KIDO_FAKE_CLOSE_RUN_LOG = closeRunLogFile;
  process.env.KIDO_FAKE_STATUS_LOG = statusLogFile;
  process.env.KIDO_FAKE_SET_STATUS_LOG = setStatusLogFile;
  process.env.KIDO_FAKE_CONTROL_LOG = controlLogFile;
  process.env.KIDO_FAKE_RUN_OUTCOME_LOG = runOutcomeLogFile;
  process.env.KIDO_FAKE_ASYNC_BASH_LOG = asyncBashLogFile;
  process.env.KIDO_FAKE_STATE_DIR = stateDir;
  process.env.KIDO_FAKE_AGENTS_CALL_LOG = agentsCallLogFile;
  process.env.KIDO_FAKE_PARENT_ALIVE_LOG = parentAliveLogFile;
  process.env.KIDO_FAKE_DEAD_FILE = deadSessionsFile;
  delete process.env.KIDO_FAKE_PARENT_ALIVE; // default: the parent is alive
  delete process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS;
  process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG = windowFocusedLogFile;
  delete process.env.KIDO_FAKE_WINDOW_FOCUSED; // default: not focused
  process.env.KIDO_FAKE_CHILDREN_ALIVE_LOG = childrenAliveLogFile;
  delete process.env.KIDO_FAKE_CHILDREN_ALIVE; // default: this session started nothing
  process.env.KIDO_FAKE_INBOX_DIR = inboxDir;
  delete process.env.KIDO_FAKE_INBOX_FAIL;
  delete process.env.KIDO_FAKE_MESSAGE_FAIL_TO;
  delete process.env.KIDO_FAKE_MESSAGE_DELAY_MS;
  delete process.env.KIDO_FAKE_AGENTS_DELAY_MS;
  delete process.env.KIDO_FAKE_SESSION_HELD;

  return {
    agentsFile,
    logFile,
    inboxDir,
    setAgents(agents) {
      writeFileSync(agentsFile, JSON.stringify(agents));
    },
    setParentAlive(mode) {
      if (mode === "alive") delete process.env.KIDO_FAKE_PARENT_ALIVE;
      else process.env.KIDO_FAKE_PARENT_ALIVE = mode === "gone" ? "0" : "fail";
    },
    killSession(session) {
      appendFileSync(deadSessionsFile, session + "\n");
    },
    setParentAliveDelay(ms) {
      if (ms > 0) process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS = String(ms);
      else delete process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS;
    },
    parentAliveCalls() {
      return jsonLines(parentAliveLogFile);
    },
    setInboxFail(fail) {
      if (fail) process.env.KIDO_FAKE_INBOX_FAIL = "1";
      else delete process.env.KIDO_FAKE_INBOX_FAIL;
    },
    setMessageFailTo(to) {
      if (to) process.env.KIDO_FAKE_MESSAGE_FAIL_TO = to;
      else delete process.env.KIDO_FAKE_MESSAGE_FAIL_TO;
    },
    setWindowFocused(focused) {
      if (focused) process.env.KIDO_FAKE_WINDOW_FOCUSED = "1";
      else delete process.env.KIDO_FAKE_WINDOW_FOCUSED;
    },
    windowFocusedCallCount() {
      return jsonLines(windowFocusedLogFile).length;
    },
    setChildrenAlive(alive) {
      if (alive) process.env.KIDO_FAKE_CHILDREN_ALIVE = "1";
      else delete process.env.KIDO_FAKE_CHILDREN_ALIVE;
    },
    childrenAliveCalls() {
      return jsonLines(childrenAliveLogFile);
    },
    lastSpawnArgs() {
      return last(jsonLines(spawnLogFile))?.args;
    },
    lastSpawnTask() {
      return last(jsonLines(spawnLogFile))?.task;
    },
    lastRunOutcomeArgs() {
      return last(jsonLines(runOutcomeLogFile));
    },
    lastAsyncBashArgs() {
      return last(jsonLines(asyncBashLogFile));
    },
    runsDir: join(stateDir, "runs"),
    async waitForCloseRun(ms = 2000) {
      let found: string[] | undefined;
      await pollUntil(() => (found = last(jsonLines(closeRunLogFile))) !== undefined, ms, "a kido close-run call");
      return found!;
    },
    lastStatusArgs() {
      return last(jsonLines(statusLogFile));
    },
    setStatusCalls() {
      return jsonLines(setStatusLogFile);
    },
    statusReportsWith(status) {
      return jsonLines(statusLogFile).filter((args: string[]) => {
        const i = args.indexOf("--status");
        return i >= 0 && args[i + 1] === status;
      });
    },
    statusReportsWithRemove() {
      return jsonLines(statusLogFile).filter((args: string[]) => args.includes("--remove"));
    },
    // Unfiltered by status, unlike statusReportsWith: a heartbeat firing after idle
    // reports the now-current status ("idle"), which a check scoped to one status would miss.
    statusReportCount() {
      return jsonLines(statusLogFile).length;
    },
    agentsCallCount() {
      return jsonLines(agentsCallLogFile).length;
    },
    lastControlArgs() {
      return last(jsonLines(controlLogFile));
    },
    // Named after this test process's own pid, exactly as startInbox asks kido for.
    selfInboxPath() {
      return join(inboxDir, String(process.pid) + ".sock");
    },
    lastLogFor(to, kind) {
      return last(jsonLines(logFile).filter((l) => l.to === to && (!kind || l.kind === kind)));
    },
    async waitForLog(to, kind, ms = 2000) {
      let found: any;
      await pollUntil(() => (found = this.lastLogFor(to, kind)) !== undefined, ms, `a log entry for ${JSON.stringify({ to, kind })}`);
      return found;
    },
    restore() {
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete process.env[k];
        else process.env[k] = v;
      }
      // maxRetries/retryDelay: a liveness or send poll's real subprocess can still be
      // writing its log line after a test's own assertions are done, which a bare
      // rmSync reads as ENOTEMPTY rather than retrying past.
      rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    },
  };
}

function createFakePi() {
  const tools = new Map<string, any>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  // One counter across both recorders: a wake is two calls whose order is
  // load-bearing, and two arrays cannot be compared without it.
  let seq = 0;
  const delivered: Array<{ text: string; opts: unknown; seq: number }> = [];
  const messages: Array<{ message: any; opts: unknown; seq: number }> = [];
  const renderers = new Map<string, (message: any, options: any, theme: any) => { render(width: number): string[]; handleMouse(event: any): unknown }>();
  // Keyed the same way the real UI keys a widget: content undefined means "cleared".
  const widgets = new Map<string, { content: ((tui: unknown, theme: any) => { render(width: number): string[] }) | undefined; options?: unknown }>();
  // What the host does with a user message: in pi, start a turn for it when the
  // session is idle. Wired by startSessionCore; a case wanting the gap between the
  // two held open replaces it.
  let onUserMessage: (() => unknown) | null = null;
  const pi = {
    getSettings: () => ({ tuiMode: "regular" }),
    registerTool(tool: any) {
      tools.set(tool.name, tool);
    },
    on(event: string, handler: (...args: any[]) => unknown) {
      (handlers.get(event) ?? handlers.set(event, []).get(event)!).push(handler);
    },
    sendUserMessage(text: string, opts: unknown) {
      delivered.push({ text, opts, seq: seq++ });
      // Returned, not discarded: pi's own sendUserMessage is prompt() and rejects
      // when the turn cannot start, which kido reads.
      return onUserMessage?.();
    },
    sendMessage(message: any, opts: unknown) {
      messages.push({ message, opts, seq: seq++ });
    },
    registerMessageRenderer(customType: string, renderer: Parameters<typeof renderers.set>[1]) {
      renderers.set(customType, renderer);
    },
  };
  async function emit(event: string, ...args: unknown[]): Promise<unknown[]> {
    const results: unknown[] = [];
    for (const h of handlers.get(event) ?? []) results.push(await h(...args));
    return results;
  }
  const autocompleteFactories: Array<(current: any) => any> = [];
  const notifications: Array<{ message: string; type?: string }> = [];
  const ui = {
    setWidget(key: string, content: ((tui: unknown, theme: any) => { render(width: number): string[] }) | undefined, options?: unknown) {
      widgets.set(key, { content, options });
    },
    notify(message: string, type?: string) {
      notifications.push({ message, type });
    },
    addAutocompleteProvider(factory: (current: any) => any) {
      autocompleteFactories.push(factory);
    },
  };
  return {
    pi,
    tools,
    handlers,
    delivered,
    messages,
    renderers,
    widgets,
    notifications,
    autocompleteFactories,
    ui,
    emit,
    setOnUserMessage(f: (() => unknown) | null) {
      onUserMessage = f;
    },
  };
}

const fakeTheme = {
  fg: (_color: string, text: string) => text,
  bgCalls: [] as Array<{ color: string; text: string }>,
  bg(color: string, text: string) {
    this.bgCalls.push({ color, text });
    return text;
  },
} as any;

// abort()/shutdown() are not decoration: the extensions find each other through
// one global slot, so a session_start here rebinds the ctx of whichever agents
// module owns the seam - including a stale one from an earlier case whose
// idle-exit or liveness timer is still armed. A ctx missing shutdown() crashes
// the run when that timer later fires. idle is a function, not a boolean,
// because pi's own ctx.isIdle() is one and a case watching a turn start has to
// answer differently on the next call.
function fakeCtx(sessionId = "self-session", ui?: unknown, idle: () => boolean = () => true) {
  return {
    sessionManager: { getSessionId: () => sessionId, getSessionName: () => undefined },
    model: undefined,
    isIdle: idle,
    hasPendingMessages: () => false,
    abort: () => {},
    shutdown: () => {},
    ui,
  };
}

// The shape every session-starting helper below shares: build a fake pi, run one
// or more extension factories against it, emit session_start with a ctx buildCtx
// assembles from the fake pi's own bundle.
async function startSessionCore(fx: Fixture, factory: (pi: unknown) => void, buildCtx: (created: ReturnType<typeof createFakePi>) => unknown) {
  const created = createFakePi();
  factory(created.pi);
  const ctx = buildCtx(created) as { isIdle?: () => boolean };
  // pi's prompt() starts a turn when idle and queues otherwise; nothing else in this
  // fake fires turn_start, and kido waits for it before letting a second arrival
  // through, so without this a case delivering twice reads a session pi abandoned.
  created.setOnUserMessage(() => {
    if (ctx.isIdle?.()) void created.emit("turn_start", {});
  });
  await created.emit("session_start", {}, ctx);
  return { ...created, inboxPath: fx.selfInboxPath() };
}

async function startSession(
  fx: Fixture,
  { factory = loadExtensions, sessionId, idle }: { factory?: (pi: unknown) => void; sessionId?: string; idle?: () => boolean } = {},
) {
  return startSessionCore(fx, factory, (c) => fakeCtx(sessionId, c.ui, idle));
}

// Order is deliberately agents-last here and asserted both ways in its own test
// below: neither extension may depend on the other's factory having run first,
// since pi discovers a directory and picks its own order.
function loadExtensions(pi: unknown): void {
  (kidoStatus as (pi: unknown) => void)(pi);
  (kidoAgents as (pi: unknown) => void)(pi);
}

// Reimports both extensions under a cache-busting specifier, so the module-scope
// constants each reads from the environment are recomputed. Both, with the same
// counter: the two find each other through globalThis rather than an import, so a
// fresh half and a cached half would silently pair up.
let freshImportCounter = 0;
async function freshExtensions(order: "status-first" | "agents-first" = "status-first"): Promise<(pi: unknown) => void> {
  const fresh = `?fresh=${process.pid}-${freshImportCounter++}`;
  const status = await import(`./kido-status.ts${fresh}`);
  const agents = await import(`./kido-agents.ts${fresh}`);
  const factories = [status.default, agents.default] as Array<(pi: unknown) => void>;
  if (order === "agents-first") factories.reverse();
  return (pi: unknown) => {
    for (const factory of factories) factory(pi);
  };
}

// A subagent's session id is its run id, so a case playing one has to keep the two in step.
const DEFAULT_SESSION = "self-session";

// Sets the parent edge and the run id equal to the session id the case then
// starts: an inherited parent edge alone does not make a subagent
// (kido-agents.ts, ownRunID). extra carries whatever else a case needs in the
// same save/restore; the extensions read all of it once at module scope, so each
// case still goes through freshExtensions() to pick it up.
async function asSubagent<T>(sessionId: string, fn: () => Promise<T>, extra: Record<string, string> = {}): Promise<T> {
  return withEnv({ KIDO_AGENT_PARENT_SESSION: "boss-session", KIDO_AGENT_RUN_ID: sessionId, ...extra }, fn);
}

// Restores whatever was there. The extensions read their knobs once at module
// scope, so a case that sets one has to go through freshExtensions() inside this.
async function withEnv<T>(vars: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// Negative control: the file that claimed the slot still registers everything
// when run again (what a /reload does) - a guard refusing every second factory
// call would pass the first half and leave a reloaded session with no tools.
test("a second copy of the extensions at another path registers nothing, and a reload of the first still does", async () => {
  const first = createFakePi();
  loadExtensions(first.pi);
  assert.ok(first.tools.size > 0 && first.handlers.size > 0, "the extensions registered nothing at all");

  const here = dirname(fileURLToPath(import.meta.url));
  const dir = mkdtempSync(join(here, ".copy-"));
  try {
    for (const name of ["kido-status.ts", "kido-agents.ts"]) copyFileSync(join(here, name), join(dir, name));
    const status = await import(pathToFileURL(join(dir, "kido-status.ts")).href);
    const agents = await import(pathToFileURL(join(dir, "kido-agents.ts")).href);
    const copy = createFakePi();
    status.default(copy.pi);
    agents.default(copy.pi);
    assert.deepEqual([...copy.tools.keys()], [], "the copy registered tools");
    assert.deepEqual([...copy.handlers.keys()], [], "the copy registered handlers");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  const reloaded = createFakePi();
  loadExtensions(reloaded.pi);
  assert.deepEqual([...reloaded.tools.keys()].sort(), [...first.tools.keys()].sort());
  assert.deepEqual([...reloaded.handlers.keys()].sort(), [...first.handlers.keys()].sort());
});

// pi discovers extensions in a directory and picks its own order: loaded agents
// first, the pair must still wire up whole, dispatching an envelope by kind
// rather than falling back to the plain-text path.
test("either load order wires the pair up: agents first, status second", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const factory = await freshExtensions("agents-first");
    const s = await startSession(fx, { factory });
    assert.ok(s.tools.get("ask_agent"), "the agent half registered its tools");
    assert.equal(statSync(fx.inboxDir).mode & 0o777, 0o700, "the extension creates the uid-private inbox directory");
    const resp = await sendToInbox(s.inboxPath, envelope("notice", "loaded either way", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      customMessages(s, "kido-notice").some((m) => m.message.content.endsWith("\nloaded either way")),
      "the envelope was dispatched by the agent half, not delivered as plain text",
    );
  } finally {
    fx.restore();
  }
});

// Polls rather than listening for anything: several assertions below observe
// fire-and-forget or real-subprocess work with no promise to await and no event
// to subscribe to, only a file on disk to keep checking.
async function pollUntil(cond: () => boolean | Promise<boolean>, ms = 2000, what = "a condition"): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

// Waits for `read()` to stop changing for a full `quietMs` window, not merely two
// samples some fixed delay apart: a late-arriving in-flight call can land at any
// point on a loaded runner. A source that never goes quiet times out rather than
// returning a false-stable reading.
async function pollForStable(read: () => number, quietMs: number, timeoutMs: number, what: string): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  let last = read();
  let lastChange = Date.now();
  for (;;) {
    await new Promise((r) => setTimeout(r, 20));
    const cur = read();
    if (cur !== last) {
      last = cur;
      lastChange = Date.now();
    } else if (Date.now() - lastChange >= quietMs) {
      return last;
    }
    if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs}ms waiting for ${what} to stabilise (stuck growing, last count ${last})`);
  }
}

// sendToInbox plays a peer's half of the wire protocol: connect, write the
// payload, half-close, and read back "ok\n" or "refused\n".
function sendToInbox(path: string, payload: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(path);
    let out = "";
    sock.on("connect", () => sock.end(payload));
    sock.on("data", (c) => (out += c.toString("utf8")));
    sock.on("end", () => resolve(out.trim()));
    sock.on("error", reject);
  });
}

function envelope(kind: string, text: string, extra: { id?: string; replyTo?: string; from?: { session: string; name?: string; pane?: string } } = {}): string {
  return JSON.stringify({
    v: 1,
    kind,
    id: extra.id ?? "env-" + Math.random().toString(36).slice(2),
    from: extra.from ?? { session: "peer-x", name: "peer-x" },
    replyTo: extra.replyTo,
    text,
  });
}

// customMessages returns every message of one kido custom type a session
// recorded, the shared lookup every kido-ask/kido-notice/kido-message site
// below filters through.
function customMessages(s: Pick<ReturnType<typeof createFakePi>, "messages">, customType: string) {
  return s.messages.filter((m) => m.message.customType === customType);
}

// askSent finds the kido-ask message a handleInboundAsk call handed to
// sendMessage, matching by a substring of its full content (the model's
// text, not the renderer's trimmed-down question).
function askSent(s: Pick<ReturnType<typeof createFakePi>, "messages">, includes: string) {
  return customMessages(s, "kido-ask").find((m) => m.message.content.includes(includes));
}

// pendingState races a promise against a short timer, purely to observe
// that it has *not yet* settled - it must never be used to prove the
// opposite, since a promise that "settles" 1ms after the window closes
// would still read as pending.
function pendingState(p: Promise<unknown>, ms = 30): Promise<"pending" | "settled"> {
  const timeout = Symbol();
  return Promise.race([p.then(() => "settled" as const), new Promise((r) => setTimeout(() => r(timeout), ms))]).then(
    (v) => (v === timeout ? "pending" : (v as "settled")),
  );
}

// settlesWithin asserts a promise resolves before ms elapse - the
// "promptly" half of the abandonPending contract - by racing it against a
// timer that throws.
function settlesWithin<T = { content: Array<{ text: string }> }>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`did not settle within ${ms}ms`)), ms)),
  ]);
}

const twoPeers = [
  { id: "self", name: "self", parent: "", self: true, canMessage: true },
  { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
  { id: "peer-b", name: "peer-b", parent: "", self: false, canMessage: true, canReply: true },
];

test("reply correlation: a foreign replyTo settles nothing and is surfaced; the right id settles only that ask", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
    const ask1 = await fx.waitForLog("peer-a", "ask");
    assert.ok(ask1?.id, "ask 1 was sent with an id");

    const p2 = ask.execute("c2", { to: "peer-b", question: "q2" });
    const ask2 = await fx.waitForLog("peer-b", "ask");
    assert.ok(ask2?.id && ask2.id !== ask1!.id, "ask 2 has its own id");

    const foreign = await sendToInbox(s.inboxPath, envelope("reply", "stray answer", { replyTo: "nope", from: { session: "someone-else" } }));
    assert.equal(foreign, "ok");
    assert.ok(customMessages(s, "kido-reply").some((m) => m.message.content.includes("stray answer")), "an unmatched reply is surfaced to the model");
    assert.equal(await pendingState(p1), "pending");
    assert.equal(await pendingState(p2), "pending");

    const r1 = await sendToInbox(s.inboxPath, envelope("reply", "answer 1", { replyTo: ask1!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(r1, "ok");
    assert.equal((await p1).content[0].text, "answer 1");
    assert.equal(await pendingState(p2), "pending", "ask 2 is unaffected by ask 1's reply");

    const r2 = await sendToInbox(s.inboxPath, envelope("reply", "answer 2", { replyTo: ask2!.id, from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(r2, "ok");
    assert.equal((await p2).content[0].text, "answer 2");
  } finally {
    fx.restore();
  }
});

test("a timed-out ask names its id in the error", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    const result = await ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 20 });
    const sent = fx.lastLogFor("peer-a", "ask");
    assert.match(result.content[0].text, /no reply/);
    assert.ok(result.content[0].text.includes(sent!.id), "the timeout error names the ask id");
  } finally {
    fx.restore();
  }
});

test("a reply arriving after its ask timed out is still surfaced, never dropped", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    await ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 20 });
    const sent = fx.lastLogFor("peer-a", "ask");

    const resp = await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    const late = customMessages(s, "kido-reply");
    assert.equal(late.length, 1, "a late reply is delivered as a kido-reply custom message");
    assert.equal(late[0]!.message.content, `peer-a replied (to ask ${sent!.id}): late answer`, "the model reads the same text, naming the ask it answered");
    assert.equal((late[0]!.opts as any).deliverAs, "nextTurn", "an idle session queues it behind the wake trigger");
    assert.equal(triggers(s)[0]?.text, "(kido: a reply arrived; it follows)");
  } finally {
    fx.restore();
  }
});

test("cycle refusal: an inbound ask from a session we're already asking is refused on the wire and not shown; others are ok", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");
    const p1 = ask.execute("c1", { to: "peer-a", question: "outbound q" }); // holds an edge to peer-a
    await fx.waitForLog("peer-a", "ask");

    const refused = await sendToInbox(s.inboxPath, envelope("ask", "are you free?", { id: "inbound-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(refused, "refused");
    assert.ok(!askSent(s, "are you free?"), "a refused ask is not shown to the model");

    const ok = await sendToInbox(s.inboxPath, envelope("ask", "another question", { id: "inbound-2", from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(ok, "ok");
    assert.ok(askSent(s, "another question"), "an ask from anyone else is shown");

    const sent = fx.lastLogFor("peer-a", "ask");
    await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent!.id, from: { session: "peer-a" } }));
    await p1;
  } finally {
    fx.restore();
  }
});

test("the cycle edge is released by a correlated reply or a timeout, but not by an uncorrelated reply", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
    const sent1 = await fx.waitForLog("peer-a", "ask");
    await sendToInbox(s.inboxPath, envelope("reply", "not it", { replyTo: "wrong-id", from: { session: "peer-a" } }));
    assert.equal(
      await sendToInbox(s.inboxPath, envelope("ask", "still holding?", { id: "in-1", from: { session: "peer-a" } })),
      "refused",
      "an uncorrelated reply does not release the edge",
    );

    await sendToInbox(s.inboxPath, envelope("reply", "here", { replyTo: sent1!.id, from: { session: "peer-a" } }));
    await p1;
    assert.equal(
      await sendToInbox(s.inboxPath, envelope("ask", "free now?", { id: "in-2", from: { session: "peer-a" } })),
      "ok",
      "a correlated reply releases the edge",
    );

    const p2 = ask.execute("c2", { to: "peer-a", question: "q2", timeoutMs: 20 });
    await p2;
    assert.equal(
      await sendToInbox(s.inboxPath, envelope("ask", "free again?", { id: "in-3", from: { session: "peer-a" } })),
      "ok",
      "a timeout releases the edge",
    );
  } finally {
    fx.restore();
  }
});

// A /reload changes a session's id while leaving its pane untouched; message_agent
// must re-resolve the reply against the sender's current session, found by pane,
// not the stale one the model was told about when the ask arrived.
test("a reply to an unnamed asker still reaches it after the asker reloads and its session id changes", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-old", name: "", pane: "%42", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);

    const resp = await sendToInbox(
      s.inboxPath,
      envelope("ask", "still there?", { id: "ask-reload-1", from: { session: "peer-a-old", pane: "%42" } }),
    );
    assert.equal(resp, "ok");
    const asked = askSent(s, "is asking");
    assert.ok(asked, "the ask was delivered to the model");
    assert.match(asked!.message.content, /message_agent\(to="peer-a-old"/, "an unnamed asker's fallback label is its session id");

    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-new", name: "", pane: "%42", parent: "", self: false, canMessage: true, canReply: true },
    ]);

    const reply = await s.tools.get("message_agent").execute("c1", { to: "peer-a-old", message: "still here", replyTo: "ask-reload-1" });
    assert.doesNotMatch(reply.content[0].text, /could not message/, "the reply must not fail just because the asker reloaded");

    const sent = fx.lastLogFor("peer-a-new");
    assert.ok(sent, "the reply was actually addressed to the asker's current session, not its stale one");
    assert.equal(fx.lastLogFor("peer-a-old"), undefined, "the stale session id was never dialled");
  } finally {
    fx.restore();
  }
});

// The stop-after instruction belongs only when replyTo genuinely answers an ask
// this session has pending; a reply to a notice, or a stale/unknown id, must not gain it.
test("message_agent's result says to stop after replying to a pending ask, but not after any other send", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", pane: "%2", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);

    // pendingInboundAsks is keyed by pane, so the envelope must carry one.
    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-z", from: { session: "peer-a", name: "peer-a", pane: "%2" } }));
    const toAsk = await s.tools.get("message_agent").execute("c1", { to: "peer-a", message: "yes", replyTo: "ask-z" });
    assert.match(toAsk.content[0].text, /entire response|whole response/i, "a reply to a pending ask carries the stop-after instruction");

    const plain = await s.tools.get("message_agent").execute("c2", { to: "peer-a", message: "unprompted" });
    assert.doesNotMatch(plain.content[0].text, /entire response|whole response/i, "an unprompted message carries no such instruction");

    const staleReplyTo = await s.tools.get("message_agent").execute("c3", { to: "peer-a", message: "late", replyTo: "no-such-ask" });
    assert.doesNotMatch(
      staleReplyTo.content[0].text,
      /entire response|whole response/i,
      "a replyTo naming no ask this session has pending carries no such instruction either",
    );
  } finally {
    fx.restore();
  }
});

test("abandonPending: session_shutdown and a failed rebind settle a waiting ask promptly; a successful rebind stays answerable", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a

    // session_shutdown: nothing is coming back, so the wait must not run out its
    // own (5-minute default) timeout.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      await s.emit("session_shutdown");
      const out = await settlesWithin(p, 500);
      assert.match(out.content[0].text, /inbox closed|inbox is unavailable/);
      assert.doesNotMatch(out.content[0].text, /will still arrive/, "must not promise a reply that can no longer land");
    }

    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      fx.setInboxFail(true);
      await s.emit("session_start", {}, fakeCtx());
      const out = await settlesWithin(p, 500);
      assert.match(out.content[0].text, /inbox closed|inbox is unavailable/);
      fx.setInboxFail(false);
    }

    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      const sent = await fx.waitForLog("peer-a", "ask");
      await s.emit("session_start", {}, fakeCtx());
      const resp = await sendToInbox(s.inboxPath, envelope("reply", "still here", { replyTo: sent!.id, from: { session: "peer-a" } }));
      assert.equal(resp, "ok");
      const out = await settlesWithin(p, 500);
      assert.equal(out.content[0].text, "still here");
    }
  } finally {
    fx.restore();
  }
});

function noticesIn(s: Pick<ReturnType<typeof createFakePi>, "messages">, text: string) {
  return customMessages(s, "kido-notice").filter((m) => m.message.content.includes(text));
}

test("a notice sent across a /reload is delivered to the reloaded session exactly once", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s1 = await startSession(fx, { factory: await freshExtensions() });
    await s1.emit("session_shutdown", { reason: "reload" });

    const sent = sendToInbox(s1.inboxPath, envelope("notice", "ci run finished", { from: { session: "peer-a", name: "peer-a" } }));

    const s2 = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(await settlesWithin(sent, 2000), "ok");
    await pollUntil(() => noticesIn(s2, "ci run finished").length > 0, 2000, "the notice to reach the reloaded session");
    assert.equal(noticesIn(s2, "ci run finished").length, 1, "the reloaded session was told more than once");
    assert.equal(noticesIn(s1, "ci run finished").length, 0, "the module that shut down must not deliver it too");
  } finally {
    fx.restore();
  }
});

// A shutdown module must still refuse to wait for a reply: the inbox it was
// serving is gone even though the socket is not.
test("an envelope that arrives in the /reload gap is held, then answered and delivered once", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s1 = await startSession(fx, { factory: await freshExtensions() });
    await s1.emit("session_shutdown", { reason: "reload" });

    const sent = sendToInbox(s1.inboxPath, envelope("message", "in the gap", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(await pendingState(sent, 100), "pending", "the gap must hold the connection, not answer it");

    const refused = await s1.tools.get("ask_agent").execute("c1", { to: "peer-b", question: "q" });
    assert.match(refused.content[0].text, /inbox is unavailable/, "a shut-down module must still refuse to wait for a reply");

    const s2 = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(await settlesWithin(sent, 2000), "ok");
    const inGap = (s: { delivered: Array<{ text: string }>; messages: Array<{ message: any }> }) =>
      s.delivered.filter((d) => d.text.includes("in the gap")).length +
      s.messages.filter((m) => String(m.message.content).includes("in the gap")).length;
    await pollUntil(() => inGap(s2) > 0, 2000, "the held message to reach the reloaded session");
    assert.equal(inGap(s2), 1, "the held message was delivered more than once");
    assert.equal(inGap(s1), 0, "the module that shut down must not deliver it too");
  } finally {
    fx.restore();
  }
});

// Negative control: every other reason still closes and unlinks.
test("a session_shutdown that is not a reload still closes the inbox", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(await sendToInbox(s.inboxPath, envelope("message", "before", { from: { session: "peer-a", name: "peer-a" } })), "ok");

    await s.emit("session_shutdown", { reason: "quit" });
    assert.equal(existsSync(s.inboxPath), false, "the socket file is still there after a quit");
    await assert.rejects(
      () => sendToInbox(s.inboxPath, envelope("message", "after", { from: { session: "peer-a", name: "peer-a" } })),
      /ENOENT|ECONNREFUSED/,
    );
  } finally {
    fx.restore();
  }
});

// The inode is what tells "handed forward" from "torn down and replaced": a
// rebind unlinks and creates a new one.
test("a /reload leaves exactly one listener, on the same socket", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s1 = await startSession(fx, { factory: await freshExtensions() });
    const before = statSync(s1.inboxPath).ino;

    await s1.emit("session_shutdown", { reason: "reload" });
    const s2 = await startSession(fx, { factory: await freshExtensions() });
    assert.equal(statSync(s2.inboxPath).ino, before, "the reload rebound the socket instead of keeping it");

    for (const text of ["after one", "after two"]) {
      assert.equal(await sendToInbox(s2.inboxPath, envelope("notice", text, { from: { session: "peer-a", name: "peer-a" } })), "ok");
      await pollUntil(() => noticesIn(s2, text).length === 1, 2000, `the notice ${JSON.stringify(text)} to arrive exactly once`);
    }
    assert.equal(noticesIn(s1, "after one").length + noticesIn(s1, "after two").length, 0, "a second listener still pointing at the old module");
  } finally {
    fx.restore();
  }
});

// This half asserts the registered tools are exactly the names in
// share/pi/testdata/tools.json; lib/test/test_tool_parity.ml asserts
// every name in that file is a kido subcommand, so a tool added here fails until
// both are updated.
test("the registered tools are exactly the shared list both suites check subcommand parity against", async () => {
  const fx = makeFixture();
  try {
    const s = await startSession(fx);
    const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "testdata", "tools.json");
    const expected: string[] = JSON.parse(readFileSync(fixturePath, "utf8"));
    const registered = [...s.tools.keys()];

    const missing = expected.filter((name) => !registered.includes(name));
    const extra = registered.filter((name) => !expected.includes(name));
    assert.deepEqual(
      missing,
      [],
      `share/pi/testdata/tools.json names ${JSON.stringify(missing)}, but no tool registers ${missing.length === 1 ? "it" : "them"}`,
    );
    assert.deepEqual(
      extra,
      [],
      `${JSON.stringify(extra)} ${extra.length === 1 ? "is" : "are"} registered but not in share/pi/testdata/tools.json, ` +
        "so nothing checks that a kido subcommand of that name exists - add it to the fixture and give it a subcommand",
    );
  } finally {
    fx.restore();
  }
});

// Driven from the same fixture lib/test/test_msg.ml's own discriminator table test
// drives, so the two suites cannot drift apart by someone editing only one list.
test("parseEnvelope agrees with Msg.parse's v0/v1 discriminator table", () => {
  const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "testdata", "discriminator.json");
  const cases: { name: string; raw: string; ok: boolean }[] = JSON.parse(readFileSync(fixturePath, "utf8"));
  assert.ok(cases.length >= 11, `expected at least 11 cases in the shared fixture, got ${cases.length}`);
  for (const c of cases) {
    const got = parseEnvelope(c.raw) !== null;
    assert.equal(got, c.ok, `${c.name}: parseEnvelope(${JSON.stringify(c.raw)}) ok = ${got}, want ${c.ok}`);
  }
});

// The asker already has its answer and no user is waiting on a report in this
// session, so trailing narration after the message_agent call reaches nobody.
test("an inbound ask's delivered text says the message_agent reply is the whole response, with no summary after it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-y", from: { session: "peer-a", name: "peer-a" } }));
    const delivered = askSent(s, "is asking")?.message.content ?? "";
    assert.match(delivered, /message_agent/, "names the tool that actually reaches the asker");
    assert.match(delivered, /entire response|whole response/i, "says the reply call is the whole response, not just how to send it");
    assert.match(delivered, /no summary|sign-off/i, "says plainly not to follow the reply with narration");
    assert.match(delivered, /self-contained/i, "still tells the model the asker cannot see this session's context");
  } finally {
    fx.restore();
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
    fx.restore();
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
    ]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const s = await startSession(fx, { factory: await freshExtensions() });
      const labelled = () => customMessages(s, "kido-message").map((m) => m.message);

      await sendToInbox(s.inboxPath, envelope("message", "fix the failing test\nthen report", { from: { session: "boss-session", name: "boss" } }));
      await sendToInbox(s.inboxPath, envelope("message", "the refactor is in", { from: { session: "kid-session", name: "kid" } }));
      await sendToInbox(s.inboxPath, envelope("message", "can you review this?", { from: { session: "peer-session", name: "peer-a" } }));

      assert.deepEqual(
        labelled().map((m) => m.content),
        [
          "message from @boss (your parent, who spawned you):\nfix the failing test\nthen report",
          "message from @kid (your subagent):\nthe refactor is in",
          "message from @peer-a (another agent in this session, not the user):\ncan you review this?",
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

      // Negative control: a human at a bare pane has no state record, so kido puts
      // no session in `from` and no listed agent owns that pane - the user speaking, unlabelled.
      await sendToInbox(s.inboxPath, envelope("message", "do this instead", { from: { session: "", pane: "%99" } as any }));
      assert.ok(s.delivered.some((d) => d.text === "do this instead"), "a shell's message is the user's own words, delivered unlabelled");
      assert.equal(labelled().length, 3, "and it is not dressed up as an agent's message");
    });
  } finally {
    fx.restore();
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
      assert.equal((sent.opts as any).deliverAs, "nextTurn", "an idle session's ask rides the turn kido's own trigger starts (see the wake cases)");

      const content = sent.message.content as string;
      assert.match(content, /^ask from @boss \(your parent, who spawned you\):\n/, "headed the way a message from the same sender would be");
      assert.match(content, /is asking \(id ask-hdr\): is the build green\?/, "the model's text still carries the question and the id");
      assert.match(content, /cannot see this session's context, so make the answer self-contained/, "and the self-contained-answer line");
      assert.match(content, /message_agent\(to="boss", message=<answer>, replyTo="ask-hdr"\)/, "and the exact reply call");
      assert.match(content, /entire response|whole response/i, "and STOP_AFTER_ASK_REPLY");

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
    fx.restore();
  }
});

test("an inbound notice names the sender and always shows its full text in regular mode", async () => {
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
  } finally {
    fx.restore();
  }
});

// The header is model-facing only: the transcript already says who a
// notification is from, so the renderer takes it back off.
test("a notice reaches the model under a header naming what it is, and the header is not what the TUI shows", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const text = "reviewed internal/ui: two findings\nthe second one needs a decision";

    await sendToInbox(s.inboxPath, envelope("notice", text, { from: { session: "kid-1", name: "kid-1" } }));
    const sent = customMessages(s, "kido-notice")[0]!;
    const [header, ...body] = (sent.message.content as string).split("\n");
    assert.match(header!, /^notice from kid-1 \(.*not the user\):$/, "one header line, naming the sender and what this is");
    assert.equal(body.join("\n"), text, "the child's own text follows, from the next line, byte for byte");

    const renderer = s.renderers.get("kido-notice")!;
    const drawn = renderer(sent.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(drawn, /@kid-1 notifies:\n│ reviewed internal\/ui: two findings/, "regular mode shows the text below the sender");
    assert.ok(!drawn.includes("not the user"), "the transcript does not repeat the model header");
    assert.ok(drawn.includes("needs a decision"), "regular mode shows the whole text");

    await sendToInbox(s.inboxPath, envelope("message", "do the other thing", { from: { session: "", pane: "%99" } as any }));
    assert.ok(s.delivered.some((d) => d.text === "do the other thing"), "a shell's message is delivered unlabelled");
  } finally {
    fx.restore();
  }
});

test("a notice from a nameless sender still renders sanely in regular mode", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // labelFrom's fallback order: name, session, pane, "another agent".
    await sendToInbox(s.inboxPath, envelope("notice", "from a human", { from: { session: "", pane: "%12" } as any }));
    const sent = customMessages(s, "kido-notice")[0];
    assert.equal(sent!.message.details.from, "%12", "the pane stands in for a name when there is none");

    const renderer = s.renderers.get("kido-notice")!;
    const drawn = renderer(sent!.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(drawn, /@%12 notifies:/, "a nameless sender still gets a sane, non-empty label");
  } finally {
    fx.restore();
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
      s.pi.getSettings = () => ({ tuiMode: "fullscreen" });
      const component = draw(true);
      const collapsedLines = [`\x1b[34m│ \x1b[0m\x1b[2m${header}\x1b[0m ${body.split("\n", 1)[0]}...`];
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
    fx.restore();
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
  // A session the user never named: `kido tool list_agents` falls back to the
  // pane title, which is a phrase with spaces in it (a Claude Code title
  // here) rather than a handle. Its id shares eight characters with the
  // next agent's, so the prefix that identifies it has to be longer than
  // the floor.
  { id: "01a0d843-7f2e-4b5a-9c31-8de0f1a2b3c4", name: "Tmux config", parent: "", self: false, canMessage: true, canReply: true, status: "running" },
  { id: "01a0d843-ffff-4b5a-9c31-8de0f1a2b3c4", name: "scribe", parent: "", self: false, canMessage: true, canReply: true, status: "idle" },
  { id: "k9", name: "config-linter", parent: "", self: false, canMessage: true, canReply: true, status: "idle" },
];

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
    fx.restore();
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
    fx.restore();
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
    fx.restore();
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
    fx.restore();
  }
});

// Pins a real bug: the render path and the model path are different code paths,
// and two subagents' notices sat invisible for minutes, appearing only when the
// parent's turn happened to end.
test("an inbound notice renders a widget the instant it is received, not when it is later delivered", async () => {
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

    const sent = customMessages(s, "kido-notice")[0];
    assert.ok(sent, "the notice was also handed to sendMessage, unconditionally");
  } finally {
    fx.restore();
  }
});

// A parent whose own turn runs long must not sit on a finished child's report
// until its turn ends. Negative control: plain messages and asks stay on followUp, unchanged.
test("a notice is delivered by steer, not followUp; plain messages and asks are unaffected", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx, { idle: () => false });
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("notice", "build finished", { from }));
    const sent = customMessages(s, "kido-notice")[0];
    assert.ok(sent, "the notice reached sendMessage");
    assert.equal((sent!.opts as any).deliverAs, "steer", "a notice steers into the running turn rather than waiting for it to end");

    await sendToInbox(s.inboxPath, envelope("message", "a plain message", { from }));
    const message = customMessages(s, "kido-message")[0];
    assert.ok(message, "the message reached sendMessage");
    assert.equal((message!.opts as any).deliverAs, "followUp", "a message still queues behind the running turn rather than joining it");

    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-y", from }));
    const askMsg = customMessages(s, "kido-ask").find((m) => m.message.content.includes("you there?"));
    assert.ok(askMsg, "an ask still reaches the model as a custom message, unaffected by the notice-only steer change");
    assert.equal((askMsg!.opts as any).deliverAs, "followUp", "an ask still queues behind the running turn rather than joining it");
    assert.equal(triggers(s).length, 0, "a streaming session needs no trigger: pi prepares the next turn itself");
  } finally {
    fx.restore();
  }
});

// Every wake trigger a session typed as the user, matched by the shared prefix.
function triggers(s: { delivered: Array<{ text: string; opts: unknown; seq: number }> }) {
  return s.delivered.filter((d) => d.text.startsWith("(kido:"));
}

// pi 0.87.1's sendCustomMessage({triggerTurn: true}) skips prompt()'s
// before_agent_start emit and system-prompt diff; waking through
// sendUserMessage is the one way in that runs both. Either half alone passes a
// half-applied fix: a nextTurn message with no trigger delivers nothing until the
// user types, and a trigger beside a triggerTurn message is two turns for one arrival.
test("an idle session is woken through prompt(): the arrival is queued as nextTurn and a user trigger starts the turn", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    const cases: Array<{ kind: string; customType: string; trigger: string; deliverAs: string }> = [
      { kind: "message", customType: "kido-message", trigger: "(kido: a message arrived; it follows)", deliverAs: "followUp" },
      { kind: "notice", customType: "kido-notice", trigger: "(kido: a notification arrived; it follows)", deliverAs: "steer" },
      { kind: "ask", customType: "kido-ask", trigger: "(kido: a question arrived; it follows)", deliverAs: "followUp" },
      { kind: "reply", customType: "kido-reply", trigger: "(kido: a reply arrived; it follows)", deliverAs: "followUp" },
    ];
    for (const c of cases) {
      await sendToInbox(s.inboxPath, envelope(c.kind, `${c.kind} text`, { id: `env-${c.kind}`, from }));
      const sent = customMessages(s, c.customType)[0];
      assert.ok(sent, `the ${c.kind} reached sendMessage`);
      assert.equal((sent!.opts as any).deliverAs, "nextTurn", `an idle session's ${c.kind} rides the turn the trigger starts`);
      assert.ok(!(sent!.opts as any).triggerTurn, `and must not also ask pi to start a turn of its own for the ${c.kind}`);

      const trigger = s.delivered.find((d) => d.text === c.trigger);
      assert.ok(trigger, `the ${c.kind} was triggered by a user message: ${JSON.stringify(s.delivered.map((d) => d.text))}`);
      assert.ok(trigger!.seq > sent!.seq, "the arrival must be queued before the trigger, which is what drains the queue");
      assert.equal((trigger!.opts as any).deliverAs, c.deliverAs, "the trigger carries the kind's own mode, for the race where a turn starts under it");
      assert.equal((trigger!.opts as any).expandPromptTemplates, false, "a trigger is text the model reads, never a command to dispatch");
    }
    assert.equal(triggers(s).length, cases.length, "one trigger per arrival, no more");
  } finally {
    fx.restore();
  }
});

// The trigger only starts the turn: pi's own run, wrapped by kido, must never record or send
// it, while everything prompt() prepared alongside it goes through. Runs the pinned pi's
// _runAgentPrompt, so a pi that renames it or changes what it takes fails here.
test("pi's run drops a wake trigger and keeps the rest of the turn", async () => {
  const user = (text: string) => ({ role: "user", content: [{ type: "text", text }], timestamp: 0 });
  const arrival = { role: "custom", customType: "kido-notice", content: "notice text", display: true, timestamp: 0 };
  const prompted: unknown[] = [];
  const noop = async () => false;
  const session = {
    _recordSelection() {},
    _handlePostAgentRun: noop,
    _runBeforeSettleBoundary: noop,
    _flushPendingBashMessages() {},
    _flushPendingCustomMessages() {},
    _emitAgentSettled: noop,
    agent: { prompt: async (messages: unknown) => void prompted.push(messages) },
  };
  const run = (messages: unknown) => (AgentSession.prototype as any)._runAgentPrompt.call(session, messages);
  await run([user("(kido: a notification arrived; it follows)"), arrival]);
  await run([user("(kido: a notification arrived; it follows) and more"), arrival]);
  await run(arrival);
  assert.deepEqual(prompted, [[arrival], [user("(kido: a notification arrived; it follows) and more"), arrival], arrival]);
});

test("pi's clearQueue restores only editor text and preserves both custom queues in order across reload", async () => {
  assert.equal(typeof globalThis.__kidoPiExtensionClearQueue, "function", "pi must expose clearQueue");
  const piDist = new URL("./", import.meta.resolve("@earendil-works/pi-coding-agent"));
  const { Agent } = await import(new URL("../node_modules/@earendil-works/pi-agent-core/dist/agent.js", piDist).href);
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
  const { Agent } = await import(new URL("../node_modules/@earendil-works/pi-agent-core/dist/agent.js", piDist).href);
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

// A held batch is the fourth kind that wakes an idle session, and the one that
// can be flushed with no turn in sight at all - its debounce fires on kido's own timer.
test("a stream batch flushed while the session is idle wakes it the same way", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);

    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 1")), "ok");
    await pollUntil(() => streamMessages(s.messages).length === 1, 3000, "the debounce to flush the batch");
    assert.equal((streamMessages(s.messages)[0].opts as any).deliverAs, "nextTurn", "an idle flush rides the turn its trigger starts");
    const trigger = s.delivered.find((d) => d.text === "(kido: a background run's output follows)");
    assert.ok(trigger, `the batch was triggered by a user message: ${JSON.stringify(s.delivered.map((d) => d.text))}`);
    assert.equal((trigger!.opts as any).deliverAs, "steer", "and the trigger carries a batch's own mode");
  } finally {
    fx.restore();
  }
});

// Two arrivals racing in the window pi leaves open: the trigger has been
// handed over and the turn it will start has not begun, so the session
// still reads as idle. The second arrival must queue for the turn already
// on its way and ask for no turn of its own - one trigger is one turn, and
// a second would buy a whole extra turn for a message the first one
// already carries. Two asks sharing that turn is accepted: each carries
// its own id and is answered with replyTo, so neither reply can be
// misattributed.
//
// The assertion with teeth is the trigger count. Both asks reaching the
// model is what pi does with a pending nextTurn message anyway, so a wake
// that triggered once per arrival would deliver both and still be wrong.
test("two asks arriving while idle ride one turn: one trigger, both delivered", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
      { id: "peer-b", name: "peer-b", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx, { idle: () => true });
    s.setOnUserMessage(null); // pi's gap, held open: no turn starts under either ask

    await sendToInbox(s.inboxPath, envelope("ask", "first question", { id: "ask-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(triggers(s).length, 1, "the first ask starts a turn");

    await sendToInbox(s.inboxPath, envelope("ask", "second question", { id: "ask-2", from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(triggers(s).length, 1, "the second rides that turn rather than buying one of its own");

    for (const [question, id] of [["first question", "ask-1"], ["second question", "ask-2"]]) {
      const sent = askSent(s, question);
      assert.ok(sent, `${question} reached the model, neither lost nor held back`);
      assert.equal((sent!.opts as any).deliverAs, "nextTurn", "both are injected into the turn the one trigger starts");
      assert.ok(!(sent!.opts as any).triggerTurn, "and neither asks pi to start a turn for it");
      assert.match(sent!.message.content as string, new RegExp(`\\(id ${id}\\)`), "each carries its own id, which is what makes sharing a turn safe");
    }
  } finally {
    fx.restore();
  }
});

// A rejected sendUserMessage - prompt() itself - is the only word kido gets that
// a turn is not coming; without clearing the flag too, one failed trigger leaves
// every later arrival queued behind it for the life of the session.
test("a trigger whose turn never starts does not hold the next arrival back", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx, { idle: () => true });
    s.setOnUserMessage(() => Promise.reject(new Error("Cannot submit a prompt while compaction is in progress")));
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("ask", "first question", { id: "ask-1", from }));
    assert.equal(triggers(s).length, 1, "the first ask asked for its turn");

    await sendToInbox(s.inboxPath, envelope("ask", "second question", { id: "ask-2", from }));
    await pollUntil(() => triggers(s).length === 2, 2000, "the next arrival to wake the session itself");
    assert.ok(askSent(s, "second question"), "and it reached the model");
  } finally {
    fx.restore();
  }
});

test("a notice reaches the model exactly once, and its widget row is removed once delivery actually happens", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("notice", "the whole result", { from }));
    const noticeMessages = customMessages(s, "kido-notice");
    assert.equal(noticeMessages.length, 1, "the notice's text was sent to the model exactly once");
    const sent = noticeMessages[0]!.message;
    assert.ok(sent.content.endsWith("\nthe whole result"), "the model-visible text is the notice's full text, unchanged under its header line");
    const noticeId = sent.details?.noticeId;
    assert.ok(noticeId, "the message carries an id the widget half can be matched against");

    assert.ok(s.widgets.get("kido-notice-pending")?.content, "the widget is still up before delivery actually happens");

    await s.emit("message_start", { message: { ...sent, role: "custom" } });

    assert.equal(s.widgets.get("kido-notice-pending")?.content, undefined, "the widget is cleared once the real entry has taken over");

    await s.emit("message_start", { message: { role: "custom", customType: "some-other-type" } });
    assert.equal(s.widgets.get("kido-notice-pending")?.content, undefined, "an unrelated message_start leaves the cleared widget alone");
  } finally {
    fx.restore();
  }
});

// Fires on every prompt, not just the child's first: a task delivered once via
// deliverTask is the wrong lifetime for a standing rule.
// The handler must not return `systemPrompt` (or set forceSystemPrompt): pi
// 0.87.1's docs/extensions.md warns that replaces the whole prompt, which broke
// pi-claude-bridge's prompt-capture. The instruction goes in
// systemPromptOptions.promptGuidelines instead, added exactly once per call, never
// accumulated - the second emit here is what would catch a handler mutating
// something shared.
test("a subagent's before_agent_start hook adds the notify_parent instruction to systemPromptOptions rather than forcing a whole prompt; a root session's does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });

      const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
      const results = await s.emit("before_agent_start", event);
      assert.ok(results.every((r) => r === undefined), "the handler must not force a whole-prompt replacement");
      assert.equal(event.systemPromptOptions.promptGuidelines.length, 2, "the never-sleep rule and the notify_parent instruction are each added as one guideline");
      assert.match(event.systemPromptOptions.promptGuidelines[0], /sleep/, "the always-on never-sleep rule rides first");
      assert.match(event.systemPromptOptions.promptGuidelines[1], /notify_parent/, "names the tool the model must call");
      assert.match(
        event.systemPromptOptions.promptGuidelines[1],
        /entire response|whole response/i,
        "also carries the stop-after-replying instruction",
      );

      const event2: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
      await s.emit("before_agent_start", event2);
      assert.equal(event2.systemPromptOptions.promptGuidelines.length, 2, "a second turn's own fresh options get the instructions once, not accumulated onto the first turn's");
    });
  } finally {
    fx.restore();
  }

  const rootFx = makeFixture();
  try {
    rootFx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(rootFx); // root session
    const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
    const results = await s.emit("before_agent_start", event);
    assert.ok(results.every((r) => r === undefined), "a root session's system prompt is left alone");
    assert.equal(event.systemPromptOptions.promptGuidelines.length, 1, "the never-sleep rule still applies to a root session; the notify_parent instruction does not");
    assert.match(event.systemPromptOptions.promptGuidelines[0], /sleep/, "the always-on never-sleep rule");
  } finally {
    rootFx.restore();
  }
});

test("interrupt_subagent runs kido tool interrupt_subagent with the target, and stop_subagent runs kido tool stop_subagent, passing --force through", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);

    const interruptRes = await s.tools.get("interrupt_subagent").execute("c1", { to: "peer-a" });
    assert.match(interruptRes.content[0].text, /interrupted peer-a/);
    assert.deepEqual(fx.lastControlArgs(), ["tool", "interrupt_subagent", "--", "peer-a"]);

    const stopRes = await s.tools.get("stop_subagent").execute("c2", { to: "peer-b" });
    assert.match(stopRes.content[0].text, /stopped peer-b/);
    assert.deepEqual(fx.lastControlArgs(), ["tool", "stop_subagent", "--", "peer-b"]);

    await s.tools.get("stop_subagent").execute("c3", { to: "peer-b", force: true });
    assert.deepEqual(fx.lastControlArgs(), ["tool", "stop_subagent", "--force", "--", "peer-b"]);
  } finally {
    fx.restore();
  }
});

function argAfter(args: string[] | undefined, flag: string): string | undefined {
  if (!args) return undefined;
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

// A bare alias like "sonnet" reaching pi's own --model unresolved fails silently
// after thirty seconds; the schema is the only place the expected shape is read.
test("spawn_subagent's model parameter documents the provider/model-id format", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");
    const description = (spawn.parameters as any).properties.model.description as string;
    assert.match(description, /provider\/model-id/, "names the expected shape");
    assert.match(description, /claude-bridge\/claude-sonnet-5/, "gives a concrete example");
  } finally {
    fx.restore();
  }
});

// Pins the incident these descriptions prevent: a parent spawned reviewers with
// no message_agent tool, then ask_agent'd each for its result and blocked.
test("spawn_subagent and ask_agent's descriptions teach the notify_parent pattern, not ask_agent for a child's result", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    assert.match(
      s.tools.get("spawn_subagent").description!,
      /Its result arrives as a notice when it calls notify_parent; do not ask_agent a child for its result\./,
    );
    assert.match(
      s.tools.get("ask_agent").description!,
      /Not for collecting a subagent's result: that arrives on its own as a notice when the child finishes, and an ask blocks this turn until the target answers, so the notice cannot be read until the ask returns\./,
    );
  } finally {
    fx.restore();
  }
});

// Same incident, from the launch result: read at the one moment the model has a
// child and no result from it, which is when it invents one or blocks.
test("a spawn and a resume both end by saying the result arrives as a notice and must not be waited on, reported or predicted", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");

    for (const [what, params] of [["a spawn", { task: "t" }], ["a resume", { resume: "run-abc" }]] as const) {
      const text = (await spawn.execute("c1", params)).content[0].text as string;
      assert.match(text, /arrives as a notice when it calls notify_parent/, `${what}: names how the result actually arrives`);
      assert.match(text, /do not report, assume or predict it/, `${what}: forbids inventing the result it does not have`);
      assert.match(text, /do not ask it for its result/, `${what}: forbids the ask that blocks the turn the notice would land in`);
      assert.match(text, /continue other work or answer the user meanwhile/, `${what}: says what to do with the turn instead`);
      assert.match(text, /if nothing else is left, end your turn - the notice wakes you/, `${what}: says to end the turn when there is nothing else to do`);
    }
  } finally {
    fx.restore();
  }
});

// pi quirk: promptGuidelines strings become rules-section bullets, merged by
// buildRules (system-prompt.js); the shape assertions mirror
// _normalizePromptGuidelines (agent-session.js), which trims, drops empty and de-duplicates.
test("spawn_subagent and async_bash carry promptGuidelines pi will merge into its rules section", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawnRules = s.tools.get("spawn_subagent").promptGuidelines as string[];
    const bashRules = s.tools.get("async_bash").promptGuidelines as string[];

    for (const [name, rules] of [["spawn_subagent", spawnRules], ["async_bash", bashRules]] as const) {
      assert.ok(Array.isArray(rules) && rules.length > 0, `${name} registers guidelines`);
      for (const rule of rules) {
        assert.equal(typeof rule, "string", `${name}: every guideline is a string`);
        assert.equal(rule, rule.trim(), `${name}: survives the normalizer's trim unchanged`);
        assert.ok(rule.length > 0, `${name}: no empty guideline, which the normalizer would drop`);
      }
      assert.equal(new Set(rules).size, rules.length, `${name}: no duplicate the normalizer would collapse`);
    }

    assert.ok(
      spawnRules.some((r) => /arrives on its own as a notice/.test(r) && /never ask a child for its result/.test(r) && /poll list_agents/.test(r)),
      "spawn_subagent: the result arrives on its own; neither ask nor poll for it",
    );
    assert.ok(
      spawnRules.some((r) => /Trust but verify/.test(r) && /check the diff/.test(r)),
      "spawn_subagent: a child's report is what it meant to do, so the diff is what to check before relaying success",
    );
    assert.ok(
      bashRules.some((r) => /before continuing/.test(r) && /end your turn/.test(r) && /never run `sleep`/.test(r)),
      "async_bash: a needed result runs in foreground bash, and end the turn rather than wait for its notice",
    );

    // buildRules de-duplicates by exact text, so the shared rule is one bullet.
    const shared = spawnRules.filter((r) => bashRules.includes(r));
    assert.equal(shared.length, 1, "exactly one rule is shared between the two tools");
    assert.match(shared[0]!, /not the user speaking/, "the shared rule is the one about what a notice is");
    assert.match(shared[0]!, /do not thank or answer it/, "and says what not to do with it");
  } finally {
    fx.restore();
  }
});

test("spawn_subagent's task parameter tells the model how to write the prompt a context-free child will read", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const task = (s.tools.get("spawn_subagent").parameters as any).properties.task.description as string;
    assert.match(task, /no context beyond this text/, "says the child starts blank");
    assert.match(task, /fork/, "names the one exception");
    assert.match(task, /files, the lines and the specific change/, "says what a usable task names");
    assert.match(task, /report back/, "says to ask for a report");
    assert.match(task, /write code or only research/, "says to state which of the two the child is for");
    assert.match(task, /based on your findings/, "and names the phrase that hands the parent's own synthesis to the child");
  } finally {
    fx.restore();
  }
});

test("spawn_subagent passes its task as text on stdin and calls kido tool spawn_subagent with its own identity, without waiting for the child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // Fire-and-forget: nothing to await but the file it eventually writes.
    await pollUntil(() => fx.lastStatusArgs() !== undefined);
    const own = argAfter(fx.lastStatusArgs(), "--session");
    assert.equal(own, DEFAULT_SESSION, "session_start reported under its own session id");

    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
    assert.match(result.content[0].text, /kid-1/);
    assert.equal(result.details.run, "fake-run-id", "the run id kido tool spawn_subagent printed is returned so the model can refer to it later");

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido tool spawn_subagent was invoked");
    assert.equal(argAfter(spawnArgs, "--parent-pid"), String(process.pid), "passes its own pid as --parent-pid");
    assert.equal(argAfter(spawnArgs, "--parent-session"), own, "passes its own session id as --parent-session");
    assert.equal(argAfter(spawnArgs, "--name"), "kid-1");
    assert.equal(argAfter(spawnArgs, "--task-file"), "-", "the task is passed as text on stdin, not as a file this tool manages");
    assert.equal(fx.lastSpawnTask(), "go do the thing", "the task's own text goes on stdin, not on the command line");

    const sepIndex = spawnArgs!.indexOf("--");
    assert.ok(sepIndex >= 0, "the child command follows --");
    assert.deepEqual(spawnArgs!.slice(sepIndex + 1), ["pi", "--name", "kid-1"]);
  } finally {
    fx.restore();
  }
});

test("spawn_subagent passes --model and --tools through to the child's pi invocation, and generates a safe name when omitted", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { task: "t", model: "anthropic/sonnet", tools: ["read", "bash"] });

    const spawnArgs = fx.lastSpawnArgs()!;
    const command = spawnArgs.slice(spawnArgs.indexOf("--") + 1);
    assert.equal(command[0], "pi");
    assert.equal(argAfter(command, "--model"), "anthropic/sonnet");
    assert.equal(argAfter(command, "--tools"), "read,bash", "--tools is the capability ceiling handed to the child, comma-joined");

    const name = argAfter(spawnArgs, "--name");
    assert.ok(name, "a name was generated");
    assert.doesNotMatch(name!, /['"$#`\n\r]/, "a generated name avoids the characters tmux's own parsing cannot survive");
    assert.match(result.content[0].text, new RegExp(name!.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  } finally {
    fx.restore();
  }
});

test("spawn_subagent(resume) calls kido tool spawn_subagent --resume with its own identity, and no task file", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await pollUntil(() => fx.lastStatusArgs() !== undefined);
    const own = argAfter(fx.lastStatusArgs(), "--session");

    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { resume: "run-abc" });
    assert.match(result.content[0].text, /run-abc|fake-run-id/, "the run id is named in the result");

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido tool spawn_subagent was invoked");
    assert.equal(argAfter(spawnArgs, "--resume"), "run-abc");
    assert.equal(argAfter(spawnArgs, "--parent-pid"), String(process.pid), "carries its own identity through exactly as a fresh spawn does");
    assert.equal(argAfter(spawnArgs, "--parent-session"), own);
    assert.ok(!spawnArgs!.includes("--task-file"), "a resume keeps its own original task; no task file is written for it");
    assert.ok(!spawnArgs!.includes("--name"), "a resume keeps its own original window name");
    assert.deepEqual(spawnArgs!.slice(spawnArgs!.indexOf("--") + 1), ["pi"], "no command override is sent when neither model nor tools is given");
  } finally {
    fx.restore();
  }
});

test("spawn_subagent(resume) with model/tools overrides them in the resumed pi's own command", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");
    await spawn.execute("c1", { resume: "run-abc", model: "claude-opus-5", tools: ["read"] });

    const spawnArgs = fx.lastSpawnArgs()!;
    const sepIndex = spawnArgs.indexOf("--");
    assert.ok(sepIndex >= 0, "a command override follows -- when model/tools are given");
    const command = spawnArgs.slice(sepIndex + 1);
    assert.equal(command[0], "pi");
    assert.equal(argAfter(command, "--model"), "claude-opus-5");
    assert.equal(argAfter(command, "--tools"), "read");
  } finally {
    fx.restore();
  }
});

// A resume brings a run back idle: it keeps its original task, which it has
// already been given, so nothing is delivered to it and it waits - the result
// text must say so, or a parent resuming a killed run waits on a child that is waiting on it.
test("spawn_subagent(resume) tells the caller the run is idle and needs a message", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const result = await s.tools.get("spawn_subagent").execute("c1", { resume: "run-abc" });
    const text = result.content[0].text;
    assert.match(text, /idle/i, "the resumed run is idle, not working");
    assert.match(text, /message/i, "and says what moves it: a message from whoever resumed it");
    assert.match(text, /fake-run-id/, "still naming the run it brought back");
  } finally {
    fx.restore();
  }
});

// The assertion with teeth: the id on the command line is this session's own,
// not a plausible-looking value the model supplied.
test("spawn_subagent(fork) passes --fork with this session's own id, and nothing at all without it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");

    await spawn.execute("c1", { task: "decide", name: "kid-plain" });
    assert.ok(!fx.lastSpawnArgs()!.includes("--fork"), "an ordinary spawn must not fork anything");

    const result = await spawn.execute("c2", { task: "decide", name: "kid-fork", fork: true });
    const spawnArgs = fx.lastSpawnArgs()!;
    assert.equal(argAfter(spawnArgs, "--fork"), DEFAULT_SESSION, "the caller's own session id is what is forked, not anything the model named");
    assert.equal(argAfter(spawnArgs, "--task-file"), "-", "a forked child is still given its task the ordinary way");
    assert.equal(fx.lastSpawnTask(), "decide");
    assert.match(result.content[0].text, /forked from this session/, "the model is told the child holds its context");
    const command = spawnArgs.slice(spawnArgs.indexOf("--") + 1);
    assert.deepEqual(command, ["pi", "--name", "kid-fork"], "the child command is untouched: --fork is kido's to place");
  } finally {
    fx.restore();
  }
});

// kido tool spawn_subagent (lib/spawn_subagent.ml) refuses these combinations;
// the tool forwards what it was given rather than deciding a second time.
test("spawn_subagent forwards resume alongside task, name or fork, and a call with neither, for kido to refuse", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");

    await spawn.execute("c1", { resume: "run-abc", task: "a new task" });
    assert.equal(argAfter(fx.lastSpawnArgs(), "--resume"), "run-abc");
    assert.equal(argAfter(fx.lastSpawnArgs(), "--task-file"), "-");
    assert.equal(fx.lastSpawnTask(), "a new task");

    await spawn.execute("c2", { resume: "run-abc", name: "kid-1" });
    assert.equal(argAfter(fx.lastSpawnArgs(), "--resume"), "run-abc");
    assert.equal(argAfter(fx.lastSpawnArgs(), "--name"), "kid-1");

    await spawn.execute("c3", { resume: "run-abc", fork: true });
    assert.equal(argAfter(fx.lastSpawnArgs(), "--resume"), "run-abc");
    assert.equal(argAfter(fx.lastSpawnArgs(), "--fork"), DEFAULT_SESSION);

    await spawn.execute("c4", {});
    assert.ok(!fx.lastSpawnArgs()!.includes("--resume"), "no resume to forward");
    assert.ok(!fx.lastSpawnArgs()!.includes("--task-file"), "no task to forward, which kido refuses");
  } finally {
    fx.restore();
  }
});

test("spawn_subagent reports a kido tool spawn_subagent timeout as a timeout, not a generic failure", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const savedTimeout = process.env.KIDO_SPAWN_TIMEOUT_MS;
    process.env.KIDO_SPAWN_TIMEOUT_MS = "300";
    process.env.KIDO_FAKE_SPAWN_DELAY_MS = "2000"; // longer than the timeout: in-flight, not failed
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
      assert.match(result.content[0].text, /timed out/);
      assert.ok(fx.lastSpawnArgs(), "kido tool spawn_subagent was invoked before the timeout fired");
    } finally {
      delete process.env.KIDO_FAKE_SPAWN_DELAY_MS;
      if (savedTimeout === undefined) delete process.env.KIDO_SPAWN_TIMEOUT_MS;
      else process.env.KIDO_SPAWN_TIMEOUT_MS = savedTimeout;
    }
  } finally {
    fx.restore();
  }
});

test("a child started with KIDO_AGENT_TASK_FILE delivers its task as the first message, keeps the file, and marks it delivered", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "task.txt");
    writeFileSync(taskFile, "do the important thing");

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      assert.ok(
        s.delivered.some((d) => d.text === "do the important thing"),
        "the task reached the model as a user message, the same way an inbox prompt is delivered",
      );
      // Kept, not unlinked: read back later by `kido runs <run-id>`. A sibling marker
      // is what stops a later /reload from delivering it again.
      assert.equal(existsSync(taskFile), true, "the task file survives delivery");
      assert.equal(existsSync(join(dirname(taskFile), "delivered")), true, "a delivered marker is written");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

test("a /reload does not deliver an already-delivered task a second time", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "reload-task.txt");
    writeFileSync(taskFile, "do the important thing");

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      assert.equal(s.delivered.filter((d) => d.text === "do the important thing").length, 1);

      // A /reload re-runs session_start with a fresh ctx, not the factory, so the
      // delivered marker must be what stops a second delivery, not module state.
      await s.emit("session_start", {}, fakeCtx());
      assert.equal(
        s.delivered.filter((d) => d.text === "do the important thing").length,
        1,
        "the task must not be delivered again once its marker exists",
      );
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

test("an unreadable KIDO_AGENT_TASK_FILE delivers nothing, breaks nothing, and leaves nothing behind", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const taskFile = join(fx.inboxDir, "..", "unreadable-task.txt");
    writeFileSync(taskFile, "a task nobody can read");
    chmodSync(taskFile, 0o000);

    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = taskFile;
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing is delivered from a file that could not be read");
      assert.equal(existsSync(join(dirname(taskFile), "delivered")), false, "no marker is written for a read that failed, so a later /reload gets another try");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
      if (existsSync(taskFile)) chmodSync(taskFile, 0o600);
    }
  } finally {
    fx.restore();
  }
});

test("a missing KIDO_AGENT_TASK_FILE does not break session_start", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_TASK_FILE;
    process.env.KIDO_AGENT_TASK_FILE = join(fx.inboxDir, "..", "no-such-task.txt");
    try {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing spurious is delivered when the task file is absent");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

// Pins a real incident: a child whose pi could not start a model at all never ran
// a turn, so the old settled-turn-only idle-exit armed nothing and it ran forever,
// indistinguishable to its parent from a child hard at work. The clock is now
// armed from the task's own delivery instead.
test("a child whose task is delivered but whose first turn never starts self-exits and records that no turn ever ran", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    const taskFile = join(fx.inboxDir, "..", "never-started-task.txt");
    writeFileSync(taskFile, "do the important thing");
    await asSubagent(
      "never-started-run",
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory, "never-started-run");
        assert.ok(s.delivered.some((d) => d.text === "do the important thing"), "the task was delivered, as it was in the incident");

        await pollUntil(() => s.shutdowns() > 0, 2000, "the idle self-exit to fire for a child that never started a turn");

        await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
        const args = fx.lastRunOutcomeArgs();
        assert.ok(args, "an outcome is recorded for a run that ended this way");
        assert.deepEqual(args!.slice(0, 3), ["run-outcome", "--result", "failed"], "a child that never worked did not complete");
        assert.ok(args!.includes("--unreported"), "and its parent is owed the one notice its silence earns");
        assert.match(argAfter(args!, "--text") ?? "", /no turn/i, "the notice's detail tells a parent 'never started' from 'ended mid-work'");
        assert.equal(args![args!.length - 1], "never-started-run", "recorded against this run");
      },
      {
        KIDO_AGENT_TASK_FILE: taskFile,
        KIDO_AGENT_PARENT_PID: String(process.pid), // alive: the parent poll must not end this session
        KIDO_PARENT_POLL_MS: "5000",
        KIDO_IDLE_EXIT_SECONDS: "0.05",
        KIDO_LINGER_SECONDS: "0.05",
      },
    );
  } finally {
    fx.restore();
  }
});

// Negative control: a child whose task does start a turn is unaffected.
test("a child whose task starts a turn is untouched by the startup clock", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    const taskFile = join(fx.inboxDir, "..", "working-task.txt");
    writeFileSync(taskFile, "do the important thing");
    await asSubagent(
      "working-run",
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory, "working-run");
        await s.emit("agent_start", {});

        await new Promise((r) => setTimeout(r, 300)); // six idle windows
        assert.equal(s.shutdowns(), 0, "a child whose first turn started is never shut down out from under its own work");

        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => s.shutdowns() > 0, 2000, "the ordinary idle self-exit still fires after a settled turn");
        await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
        assert.deepEqual(
          fx.lastRunOutcomeArgs(),
          ["run-outcome", "--result", "completed", "--unreported", "--", "working-run"],
          "the outcome a working child has always got, detail and all",
        );
      },
      {
        KIDO_AGENT_TASK_FILE: taskFile,
        KIDO_AGENT_PARENT_PID: String(process.pid),
        KIDO_PARENT_POLL_MS: "5000",
        KIDO_IDLE_EXIT_SECONDS: "0.05",
        KIDO_LINGER_SECONDS: "0.05",
      },
    );
  } finally {
    fx.restore();
  }
});

// A settled turn and a plain shutdown must not tell the parent anything on their
// own; a subagent that wants that calls notify_parent itself.
test("a settled turn sends no automatic notice, and neither does a plain shutdown", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await new Promise((r) => setTimeout(r, 200));
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "a settle must send no notice on its own");
      await s.emit("session_shutdown");
      await new Promise((r) => setTimeout(r, 200));
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "a plain shutdown must send no notice either");
    });
  } finally {
    fx.restore();
  }
});

test("async_bash passes -- and the command unchanged, with --name only when given", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const asyncBash = s.tools.get("async_bash");

    await asyncBash.execute("c1", { command: "true" });
    let args = fx.lastAsyncBashArgs();
    assert.deepEqual(args, ["tool", "async_bash", "--", "true"], "a one-word command is passed through unchanged, with no --name");

    await asyncBash.execute("c2", { command: "make -j8 && ./run", name: "build" });
    args = fx.lastAsyncBashArgs();
    assert.deepEqual(
      args,
      ["tool", "async_bash", "--name", "build", "--", "make -j8 && ./run"],
      "a multi-word command line still travels as one argument after --, unchanged; kido's own commandArgv decides bash -c vs argv",
    );
  } finally {
    fx.restore();
  }
});

test("async_bash asks for --stream only when the model did", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const asyncBash = s.tools.get("async_bash");

    await asyncBash.execute("c1", { command: "make", name: "build" });
    assert.deepEqual(fx.lastAsyncBashArgs(), ["tool", "async_bash", "--name", "build", "--", "make"], "streaming is off by default");

    await asyncBash.execute("c2", { command: "make", name: "build", stream: true });
    assert.deepEqual(fx.lastAsyncBashArgs(), ["tool", "async_bash", "--name", "build", "--stream", "--", "make"]);
  } finally {
    fx.restore();
  }
});

test("async_bash's result carries the run id and the output path kido printed, and tells the model to read it meanwhile", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const asyncBash = s.tools.get("async_bash");

    const result = await asyncBash.execute("c1", { command: "npm test", name: "tests" });
    assert.equal(result.details.run, "fake-async-run-id", "the run id kido tool async_bash printed is returned");
    const wantOutput = join(fx.runsDir, "fake-async-run-id", "output");
    assert.equal(result.details.output, wantOutput, "the output path is the fourth field of the line kido printed, not one rebuilt here");
    assert.match(result.content[0].text, /fake-async-run-id/, "the result text names the run");
    assert.match(result.content[0].text, new RegExp(wantOutput.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), "the result text names the output path");
    assert.match(result.content[0].text, /notice/, "the result text says a notice arrives on completion");
    assert.match(result.content[0].text, /read/, "the result text says the output file can be read meanwhile");
  } finally {
    fx.restore();
  }
});

// A "stream" envelope is buffered on arrival and reaches the model only when
// flushStreams runs, so every case below asserts on pi.sendMessage calls, never on
// what arrived on the wire.
const streamMessages = (messages: ReturnType<typeof createFakePi>["messages"]) =>
  messages.filter((m) => m.message.customType === "kido-stream");

function streamEnvelope(text: string, run = "run-1", output = "/state/runs/run-1/output"): string {
  return JSON.stringify({ v: 1, kind: "stream", id: "env-" + Math.random().toString(36).slice(2), from: { session: "", name: "chatty" }, text, run, output });
}

// Negative control (second half): the same chunks after a turn with no tool calls
// must produce nothing until the debounce fires - flushing on every turn_end
// would buy an endless run of empty turns.
test("a batch rides a turn that ran tools, and a turn that ran none leaves it held for the debounce (TestStreamBatchRidesAToolTurn)", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, { idle: () => false });

    for (const text of ["line 1\nline 2", "line 3", "line 4\nline 5"]) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(text)), "ok");
    }
    assert.equal(streamMessages(s.messages).length, 0, "a chunk on the wire reaches the model on nobody's schedule but flushStreams'");

    await s.emit("turn_end", { turnIndex: 0, toolResults: [{ role: "toolResult" }] });
    const sent = streamMessages(s.messages);
    assert.equal(sent.length, 1, "three chunks during one turn are one message, not three");
    assert.match(sent[0].message.content, /line 1[\s\S]*line 5/, "the one message carries every line that arrived");
    assert.equal((sent[0].opts as any).deliverAs, "steer", "a batch is steered, so the turn already committed to is the one that carries it");

    for (const text of ["line 6", "line 7"]) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(text)), "ok");
    }
    await s.emit("turn_end", { turnIndex: 1, toolResults: [] });
    assert.equal(streamMessages(s.messages).length, 1, "a turn with no tool calls was the agent stopping: flushing there would buy a turn, and another");

    await pollUntil(() => streamMessages(s.messages).length === 2, 3000, "the held batch to be flushed by the debounce");
    assert.match(streamMessages(s.messages)[1].message.content, /line 6[\s\S]*line 7/, "the held lines arrive on the debounce instead");
  } finally {
    fx.restore();
  }
});

test("a chunk flushes after 1s of quiet, and a chunk inside that second restarts it: one delivery with both (TestStreamDebounce)", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);

    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 1")), "ok");
    await new Promise((r) => setTimeout(r, 600));
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 2")), "ok");
    await new Promise((r) => setTimeout(r, 600));
    assert.equal(streamMessages(s.messages).length, 0, "1.2s after the first chunk, but only 0.6s after the last: still held");

    await pollUntil(() => streamMessages(s.messages).length === 1, 3000, "the debounce to flush after the quiet second");
    assert.match(streamMessages(s.messages)[0].message.content, /line 1[\s\S]*line 2/, "both chunks arrive in the one message");
    await new Promise((r) => setTimeout(r, 1300));
    assert.equal(streamMessages(s.messages).length, 1, "and nothing else follows");
  } finally {
    fx.restore();
  }
});

// The cap lives in the receiver, since it is what spends the parent's context;
// tail, not head, since what a failure has to say, it says last.
test("a batch is the tail, with one line saying how many it left out and where they are (TestBatchTailAndOmittedCount)", async () => {
  const thousand = Array.from({ length: 1000 }, (_, i) => `line ${i + 1}`);
  const batch = streamBatch(thousand, "/state/runs/run-1/output").split("\n");
  assert.equal(batch[0], "... 800 lines omitted (see /state/runs/run-1/output)", "the first line of a capped batch says what is missing and where to read it");
  assert.equal(batch.length, 201, "200 lines and the one that accounts for the rest");
  assert.equal(batch[1], "line 801", "the tail, not the head");
  assert.equal(batch[200], "line 1000");

  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(thousand.join("\n"))), "ok");
    await s.emit("turn_end", { turnIndex: 0, toolResults: [{ role: "toolResult" }] });

    const sent = streamMessages(s.messages);
    assert.equal(sent.length, 1);
    const lines = sent[0].message.content.split("\n");
    assert.match(lines[0], /^async run "chatty" output \(run run-1\)$/, "the header names the run, which is all the collapsed row shows");
    assert.equal(lines[1], "... 800 lines omitted (see /state/runs/run-1/output)");
    assert.equal(lines[lines.length - 1], "line 1000");
  } finally {
    fx.restore();
  }
});

// A run's completion notice must never reach the model before the output it is
// the ending of; lib/async_run.ml sends the last chunk first, and this is
// the receiving half, where a held batch is flushed by the notice's own arrival.
test("a completion notice flushes whatever output was still held, and arrives after it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 1\nline 2")), "ok");
    assert.equal(streamMessages(s.messages).length, 0, "nothing is flushed on arrival");

    assert.equal(
      await sendToInbox(s.inboxPath, envelope("notice", 'async run "chatty" completed: exit status 0', { from: { session: "", name: "chatty" } })),
      "ok",
    );
    const kinds = s.messages.map((m) => m.message.customType);
    assert.deepEqual(kinds, ["kido-stream", "kido-notice"], "the held batch goes first; the ending follows the output it is the ending of");
  } finally {
    fx.restore();
  }
});

// notify_parent is sent via runKido and awaited, since a deliberate tool call has
// no reason to race this process's own exit.
//
// The agent list says this session's parent is "parent-x"; the environment says
// "boss-session", which is what `kido tool notify_parent` reads and what the notice
// must be addressed to - asserting the latter, and that nothing was listed, pins that.
test("notify_parent sends a notice to the parent in its environment, carrying the given summary, without listing agents", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const listedBefore = fx.agentsCallCount();
      const tool = s.tools.get("notify_parent");
      const result = await tool.execute("call-1", { summary: "the answer is 42" });
      assert.ok(result.content[0].text.length > 0, "the tool reports what happened");
      const sent = await fx.waitForLog("boss-session", "notice");
      assert.equal(sent!.text, "the answer is 42", "the notice carries the summary verbatim");
      assert.equal(fx.lastLogFor("parent-x", "notice"), undefined, "the agent list's idea of the parent is not what was addressed");
      assert.equal(fx.agentsCallCount(), listedBefore, "and no agent list was fetched to find it");
    });
  } finally {
    fx.restore();
  }
});

// The cap is `kido tool notify_parent`'s alone: the schema must not reject a long call,
// and the tool must pass the summary on whole, byte for byte, rather than cutting it.
test("notify_parent's schema accepts a summary over the byte cap, and execute() hands the whole of it to kido rather than cutting it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const tool = s.tools.get("notify_parent");
      const longSummary = "x".repeat(4500);

      assert.ok(
        Value.Check(tool.parameters, { summary: longSummary }),
        "the schema itself no longer rejects a call over 4000 characters - the bound is kido tool notify_parent's, and it splits rather than rejects",
      );

      const result = await tool.execute("call-1", { summary: longSummary });
      assert.ok(result.content[0].text.length > 0, "the call succeeds rather than failing schema validation");
      const sent = await fx.waitForLog("boss-session", "notice");
      assert.equal(sent!.text, longSummary, "the whole report reaches kido untouched; where it is split, and what is kept, is the command's own business");
    });
  } finally {
    fx.restore();
  }
});

// The cap that matters is kido's own (Reporting.one_line, lib/reporting.ml); only the
// schema wrongly rejected past 256 characters. The report is still checked since
// the local copy setActivity keeps is what every later report carries.
test("set_status's schema accepts an activity over the byte cap, and setActivity sends it whole as kido tool set_status", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const tool = s.tools.get("set_status");
    const longActivity = "y".repeat(500);

    assert.ok(
      Value.Check(tool.parameters, { activity: longActivity }),
      "the schema no longer rejects a call over 256 characters",
    );

    await tool.execute("call-1", { activity: longActivity });
    let call: string[] | undefined;
    await pollUntil(() => (call = last(fx.setStatusCalls())) !== undefined, 2000, "a kido tool set_status call");
    assert.equal(call![0], "tool");
    assert.equal(call![1], "set_status");
    assert.equal(call![2], "--", "the activity is positional, behind --, so one beginning with a dash is still an activity");
    assert.equal(call![3], longActivity, "the extension no longer truncates; kido's own cap is what enforces the bound");

    await s.emit("agent_settled", {}, { isIdle: () => true });
    let report: string[] | undefined;
    await pollUntil(() => {
      report = fx.statusReportsWith("idle").find((args) => {
        const i = args.indexOf("--activity");
        return i >= 0 && args[i + 1] !== "";
      });
      return report !== undefined;
    }, 2000, "a status report reflecting the activity");
    const i = report!.indexOf("--activity");
    assert.equal(report![i + 1], longActivity, "the report carries the same untruncated activity");
  } finally {
    fx.restore();
  }
});

test("notify_parent from a session with no parent refuses clearly, and sends nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx); // root session: no KIDO_AGENT_PARENT_SESSION
    const tool = s.tools.get("notify_parent");
    const result = await tool.execute("call-1", { summary: "nobody to tell" });
    assert.match(result.content[0].text, /no parent/i, "the refusal names the reason rather than reading as a silent no-op");
    assert.equal(jsonLines(fx.logFile).length, 0, "nothing was sent");
  } finally {
    fx.restore();
  }
});

// Pins a real bug: a turn ending with a provider error left a child idle until
// the idle-exit clock ended it, so the parent's only notice was "completed
// without reporting" - the error itself never reached it.
test("a subagent's errored turn notifies the parent at once, naming the error and how to continue", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-errored", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-errored" });
      await s.emit("agent_end", {
        messages: [{ role: "assistant", stopReason: "error", errorMessage: "prompt-capture: no capture for this system prompt" }],
      });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      const sent = await fx.waitForLog("boss-session", "notice");
      assert.match(sent!.text, /stopped on an error/i);
      assert.match(sent!.text, /prompt-capture: no capture for this system prompt/);
      assert.match(sent!.text, /run-errored/, "names the run id so the parent can act on it");
      assert.match(sent!.text, /resume|retry/i, "says how to continue it");
    });
  } finally {
    fx.restore();
  }
});

// The negative control: an interrupt is not a failure, and nothing about
// it should read as one.
test("an aborted turn sends no error notice", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-aborted", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-aborted" });
      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "aborted" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await new Promise((r) => setTimeout(r, 30));
      assert.equal(jsonLines(fx.logFile).length, 0, "an interrupt is not an error and sends nothing");
    });
  } finally {
    fx.restore();
  }
});

test("a top-level session's errored turn sends no notice: it has nobody to tell", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx); // root session: no KIDO_AGENT_PARENT_SESSION
    await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "boom" }] });
    await s.emit("agent_settled", {}, { isIdle: () => true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(jsonLines(fx.logFile).length, 0);
  } finally {
    fx.restore();
  }
});

// Once per error, not per retry: pi 0.87.1 can fire agent_end more than
// agent_end fires once per retry but agent_settled only once retries are
// exhausted, so a redundant settle must not repeat the notice, and a genuinely new failure must.
test("once per error: a redundant settle does not resend, and a later fresh failure does", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-retry", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-retry" });

      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "first failure" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await fx.waitForLog("boss-session", "notice");
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 1);

      await s.emit("agent_settled", {}, { isIdle: () => true });
      await new Promise((r) => setTimeout(r, 30));
      assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 1, "no duplicate for the same error");

      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "second failure" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await pollUntil(() => jsonLines(fx.logFile).filter((l) => l.kind === "notice").length >= 2, 2000, "a second notice");
      const notices = jsonLines(fx.logFile).filter((l) => l.kind === "notice");
      assert.equal(notices.length, 2, "a later, genuinely new failure notifies again");
      assert.match(notices[1].text, /second failure/);
    });
  } finally {
    fx.restore();
  }
});

// The backstop: even with no immediate notice, the idle-exit ending notice a
// silent child gets must carry the last turn's own error.
test("the idle-exit ending's outcome text carries the last turn's error when the child never reported", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-error-idle", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-error-idle" });
      await s.emit("agent_end", { messages: [{ role: "assistant", stopReason: "error", errorMessage: "prompt-capture: no capture" }] });
      await s.emit("agent_settled", {}, { isIdle: () => true });
      await fx.waitForLog("boss-session", "notice");
      await s.emit("session_shutdown");
      const args = fx.lastRunOutcomeArgs();
      assert.deepEqual(args?.slice(0, 4), ["run-outcome", "--result", "completed", "--unreported"]);
      const i = args!.indexOf("--text");
      assert.ok(i >= 0, "the ending outcome carries a --text detail");
      assert.match(args![i + 1], /last turn failed/);
      assert.match(args![i + 1], /prompt-capture: no capture/);
    });
  } finally {
    fx.restore();
  }
});

test("session_shutdown schedules the window linger helper for a subagent", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);

    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      await s.emit("session_shutdown");
      const args = await fx.waitForCloseRun();
      assert.deepEqual(args, ["close-run", "@7"], "the linger helper closes this session's own window");
    }, { KIDO_LINGER_SECONDS: "0.05" });
  } finally {
    fx.restore();
  }
});

test("session_shutdown records this run's own outcome as completed when it ends idle, or failed otherwise", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-completed", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-completed" });
      await s.emit("session_shutdown");
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--unreported", "--", "run-completed"]);
    });
  } finally {
    fx.restore();
  }

  const fx2 = makeFixture();
  try {
    fx2.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-failed", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx2, { factory, sessionId: "run-failed" });
      await s.emit("ui_prompt_start"); // leaves current = "waiting"
      await s.emit("session_shutdown");
      assert.deepEqual(fx2.lastRunOutcomeArgs(), ["run-outcome", "--result", "failed", "--unreported", "--", "run-failed"]);
    });
  } finally {
    fx2.restore();
  }
});

// A reload (reason "reload") carries the session straight on in the same
// process; recording an outcome there would report a live run as finished, and
// since RecordOutcome refuses to overwrite the real ending could never be recorded after.
test("a session_shutdown that is a reload or a session replacement records no outcome", async () => {
  for (const reason of ["reload", "new", "resume", "fork"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
      await asSubagent(`run-${reason}`, async () => {
        const factory = await freshExtensions();
        const s = await startSession(fx, { factory, sessionId: `run-${reason}` });
        await s.emit("session_shutdown", { type: "session_shutdown", reason });
        assert.equal(fx.lastRunOutcomeArgs(), undefined, `a "${reason}" shutdown does not end the run`);
      });
    } finally {
      fx.restore();
    }
  }

  // Negative control: an explicit "quit" still records.
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-quit", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-quit" });
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--unreported", "--", "run-quit"]);
    });
  } finally {
    fx.restore();
  }
});

// A /reload delivers reason "reload" and keeps the same session id
// (measured against pi 0.85.1), while "new", "resume" and "fork" each hand back a
// different one in the same process - so those three must still remove the old
// record, or it is a live-pid file that nothing ever cleans up, claiming this pane alongside
// the fresh one under the new id.
test("session_shutdown removes the record for every reason except a reload", async () => {
  for (const reason of ["new", "resume", "fork", "quit", undefined]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
      const s = await startSession(fx, { sessionId: `sess-${reason}` });
      await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
      await s.emit("session_shutdown", reason === undefined ? undefined : { type: "session_shutdown", reason });
      await pollUntil(() => fx.statusReportsWithRemove().length >= 1, 2000, `a "${reason}" shutdown to report --remove`);
    } finally {
      fx.restore();
    }
  }

  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, { sessionId: "sess-reload" });
    await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
    await s.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });
    // No event to wait on: the reload branch returns before ever calling send().
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(fx.statusReportsWithRemove().length, 0, "a reload must never report --remove");
  } finally {
    fx.restore();
  }
});

test("session_shutdown never records an outcome for a root session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, { sessionId: "root-session" });
    await s.emit("session_shutdown");
    assert.equal(fx.lastRunOutcomeArgs(), undefined, "a root session has no run record to write into");
  } finally {
    fx.restore();
  }
});

// The same reload gate that keeps recordOwnOutcome from recording a live run as
// finished must also keep the linger from closing the child's window under it.
test("a reload shutdown schedules no linger; a quit does", async () => {
  const reload = makeFixture();
  try {
    reload.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@9" }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(reload, { factory });
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });
      const closeRunLog = await reload
        .waitForCloseRun(50)
        .then(() => "called")
        .catch(() => "not called");
      assert.equal(closeRunLog, "not called", "a reload must not schedule this session's own window to close");
    }, { KIDO_LINGER_SECONDS: "0.05" });
  } finally {
    reload.restore();
  }

  // Negative control: an actual quit still schedules the linger.
  const quit = makeFixture();
  try {
    quit.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@9" }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSession(quit, { factory });
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      const args = await quit.waitForCloseRun();
      assert.deepEqual(args, ["close-run", "@9"], "a quit still schedules this session's own window to close");
    }, { KIDO_LINGER_SECONDS: "0.05" });
  } finally {
    quit.restore();
  }
});

test("session_shutdown never schedules a window linger for a root session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@7" }]);
    process.env.KIDO_LINGER_SECONDS = "0.05";
    try {
      const s = await startSession(fx);
      await s.emit("session_shutdown");
      const closeRunLog = await fx
        .waitForCloseRun(50)
        .then(() => "called")
        .catch(() => "not called");
      assert.equal(closeRunLog, "not called", "a root session's window must never be scheduled for close");
    } finally {
      delete process.env.KIDO_LINGER_SECONDS;
    }
  } finally {
    fx.restore();
  }
});

// Pins a real incident: every KIDO_AGENT_* variable is inherited by anything an
// agent's process starts, so a nested pi run (a human debugging, a tool shelling
// out) arrives with a child's entire environment. Trusting it killed two live
// agents. What tells the two apart: the real child's pi session id is the run id,
// a nested pi mints its own.
test("a process that merely inherited a subagent's environment is not a subagent", async () => {
  const fx = makeFixture();
  try {
    // What the pane lookup finds: the REAL agent's record, window and all.
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    await asSubagent(
      "the-real-childs-run",
      async () => {
        const factory = await freshExtensions();
        // This process's own session id: minted by pi, not the run id.
        const s = await startWithShutdownSpy(fx, factory, "a-nested-pis-own-session");

        const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
        const results = await s.emit("before_agent_start", event);
        assert.ok(results.every((r) => r === undefined), "it is told nothing about a parent it does not have");

        const result = await s.tools.get("notify_parent").execute("call-1", { summary: "not mine to send" });
        assert.match(result.content[0].text, /no parent/i, "notify_parent refuses rather than reporting to the real child's parent");
        assert.equal(jsonLines(fx.logFile).filter((l) => l.kind === "notice").length, 0, "and sends nothing");

        // Several times over both the 50ms idle interval and the 20ms
        // parent poll, whose pid is dead: neither clock belongs to this
        // process, so neither may end it.
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300));
        assert.equal(s.shutdowns(), 0, "it never self-exits on a child's idle timer or a child's parent poll");

        await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
        const closeRunLog = await fx
          .waitForCloseRun(200)
          .then(() => "called")
          .catch(() => "not called");
        assert.equal(closeRunLog, "not called", "the real agent's window is never scheduled to close");
        assert.equal(fx.lastRunOutcomeArgs(), undefined, "and the real child's run is never given an outcome");
      },
      {
        KIDO_AGENT_PARENT_PID: String(deadPid()),
        KIDO_PARENT_POLL_MS: "20",
        KIDO_IDLE_EXIT_SECONDS: "0.05",
        KIDO_LINGER_SECONDS: "0.05",
      },
    );
  } finally {
    fx.restore();
  }
});

// Negative control for the test above: a fresh spawn (`pi --session-id
// <run-id>`) and a resume (`pi --session <run-id>`) both give the child's own
// session id as the run id.
test("a real subagent, fresh or resumed, is still a subagent in every respect", async () => {
  for (const runID of ["fresh-spawn-run", "resumed-run"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
      await asSubagent(
        runID,
        async () => {
          const factory = await freshExtensions();
          const s = await startWithShutdownSpy(fx, factory, runID);

          const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
          await s.emit("before_agent_start", event);
          assert.match(event.systemPromptOptions.promptGuidelines.join("\n"), /notify_parent/, `${runID}: the standing instruction still rides on every turn`);

          const result = await s.tools.get("notify_parent").execute("call-1", { summary: "done" });
          assert.ok(result.content[0].text.length > 0, `${runID}: notify_parent still runs`);
          const sent = await fx.waitForLog("boss-session", "notice");
          assert.equal(sent!.text, "done", `${runID}: the notice reaches the parent`);

          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => s.shutdowns() > 0, 2000, `${runID}: idle self-exit still fires`);

          await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
          assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", runID], `${runID}: the outcome is recorded against the run`);
          assert.deepEqual(await fx.waitForCloseRun(), ["close-run", "@7"], `${runID}: its own window is still lingered`);
        },
        {
          KIDO_AGENT_PARENT_PID: String(process.pid), // alive: the poll must not end this session
          KIDO_PARENT_POLL_MS: "5000",
          KIDO_IDLE_EXIT_SECONDS: "0.05",
          KIDO_LINGER_SECONDS: "0.05",
        },
      );
    } finally {
      fx.restore();
    }
  }
});

// A session id not yet known - null until session_start resolves one, and
// forever outside tmux or with no kido on PATH - reads as "not a subagent", not
// "probably one". Driven by taking TMUX_PANE away, which leaves the id
// unresolved while the rest of a child's environment is in place.
test("an unresolved session id is not a subagent, whatever the environment claims", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    delete process.env.TMUX_PANE; // fx.restore() puts it back
    await asSubagent(
      DEFAULT_SESSION, // would match the session id, had one ever been resolved
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);

        const event: any = { systemPrompt: "base prompt", systemPromptOptions: { promptGuidelines: [] } };
        const results = await s.emit("before_agent_start", event);
        assert.ok(results.every((r) => r === undefined), "no standing instruction for a session that may not be a child at all");
        assert.equal(event.systemPromptOptions.promptGuidelines.length, 1, "the always-on never-sleep rule still applies");

        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300));
        assert.equal(s.shutdowns(), 0, "and no idle self-exit armed on an unverified claim");

        const result = await s.tools.get("notify_parent").execute("call-1", { summary: "nobody to tell" });
        assert.match(result.content[0].text, /no parent/i, "notify_parent refuses rather than guessing");
      },
      { KIDO_IDLE_EXIT_SECONDS: "0.05" },
    );
  } finally {
    fx.restore();
  }
});

test("interleaving: an inbound ask from the same target is refused even while the outbound send to it is still in flight", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a
    fx.setMessageFailTo(undefined);
    process.env.KIDO_FAKE_MESSAGE_DELAY_MS = "800";
    try {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");

      // Held for 800ms by the fake kido: this only races because runKido shells
      // out via spawn rather than execFileSync, which could never let an inbound
      // connection be dispatched before the send finished.
      const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });

      // The load-bearing assertion: "refused" alone is true whether or not the
      // send is still running (the waiter is not dropped until a reply or
      // timeout), so `inFlight` - the fake kido's log entry not yet written - is
      // the only evidence the send really had not finished yet.
      let inFlight = false;
      let n = 0;
      await pollUntil(async () => {
        inFlight = fx.lastLogFor("peer-a", "ask") === undefined;
        const resp = await sendToInbox(s.inboxPath, envelope("ask", "sneaky", { id: `race-${n++}`, from: { session: "peer-a" } }));
        return resp === "refused";
      }, 2000, "an inbound ask from the target to be refused");
      assert.ok(inFlight, "the outbound send must still be in flight when the inbound ask is refused, or this pins nothing");

      const sent = await fx.waitForLog("peer-a", "ask");
      await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent.id, from: { session: "peer-a" } }));
      const outcome = await p1;
      assert.equal(outcome.content[0].text, "done");
    } finally {
      delete process.env.KIDO_FAKE_MESSAGE_DELAY_MS;
    }
  } finally {
    fx.restore();
  }
});

// Guaranteed to belong to no process by the time the caller uses it (the same
// trick lib/test/fixture.ml's dead_pid uses on the OCaml side).
function deadPid(): number {
  const r = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  return r.pid!;
}

test("a stream that never goes quiet for 1s is still delivered 30s after its first chunk (TestStreamMaxWait)", async (t) => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);

    t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
    for (let i = 0; i < 59; i++) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(`line ${i}`)), "ok");
      t.mock.timers.tick(500);
    }
    assert.equal(streamMessages(s.messages).length, 0, "29.5s of chunks 0.5s apart: the debounce never fires");
    assert.equal(await sendToInbox(s.inboxPath, streamEnvelope("line 59")), "ok");
    t.mock.timers.tick(500);
    assert.equal(streamMessages(s.messages).length, 1, "30s after the first chunk the held batch goes anyway");
    assert.match(streamMessages(s.messages)[0].message.content, /line 59/);
  } finally {
    t.mock.timers.reset();
    fx.restore();
  }
});

async function withParentEnv<T>(pid: number, session: string, pollMs: number, fn: () => Promise<T>): Promise<T> {
  const vars = { KIDO_AGENT_PARENT_PID: String(pid), KIDO_AGENT_PARENT_SESSION: session, KIDO_PARENT_POLL_MS: String(pollMs) };
  return withEnv({ ...vars, KIDO_AGENT_RUN_ID: DEFAULT_SESSION }, fn);
}

async function startWithShutdownSpy(fx: Fixture, factory: (pi: unknown) => void, sessionId?: string) {
  let shutdowns = 0;
  const s = await startSessionCore(fx, factory, () => ({ ...fakeCtx(sessionId), shutdown: () => { shutdowns++; } }));
  return { ...s, shutdowns: () => shutdowns };
}

test("parent-liveness poll: shuts the session down when the parent's process is gone", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(deadPid(), "boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a dead parent pid");
      assert.equal(fx.parentAliveCalls().length, 0, "ESRCH is definite, and answered without spawning anything");
      await s.emit("session_shutdown"); // stop the poll, as a real shutdown would
    });
  } finally {
    fx.restore();
  }
});

// Also pins what the poll asks: `kido get-agent` naming its own parent
// session, never `kido tool list_agents`, whose per-pane view is the wrong source for a liveness fact.
test("parent-liveness poll: does not shut down while the parent is alive, and asks get-agent about its own parent session", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("alive");
    await withParentEnv(process.pid, "boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      const agentsBefore = fx.agentsCallCount();
      await pollUntil(() => fx.parentAliveCalls().length >= 3, 2000, "several get-agent polls");
      assert.equal(s.shutdowns(), 0, "a live, correctly-matched parent must never trigger a shutdown");
      assert.deepEqual(
        fx.parentAliveCalls()[0],
        ["get-agent", "boss-session"],
        "the poll asks about its own parent session, by session id and nothing else",
      );
      assert.equal(
        fx.agentsCallCount(),
        agentsBefore,
        "and never through kido tool list_agents, whose per-pane view can lose the parent's record",
      );
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// A kido that cannot answer has said nothing about the parent, so it must never
// be read as a dead one.
test("parent-liveness poll: a kido that cannot answer is not evidence, and never ends the child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("fail");
    await withParentEnv(process.pid, "boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      await pollUntil(() => fx.parentAliveCalls().length >= 4, 2000, "several failed get-agent polls");
      assert.equal(s.shutdowns(), 0, "a failing query says nothing; it must not be read as a dead parent");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// kill(pid, 0) success is not proof: this process's own pid is alive, but no
// live record holds the parent session, as if the real parent exited and
// something else now holds its old pid. Pins the absence of a debounce: one
// "false" reading ends the session, within about one poll interval.
test("parent-liveness poll: a recycled pid with no live record of the session counts as gone, on the first reading", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("gone");
    await withParentEnv(process.pid, "boss-session", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a recycled pid with no live record of the session");
      assert.equal(fx.parentAliveCalls().length, 1, "one reading is conclusive; nothing waits for a second");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// setInterval fires on schedule whether or not the previous callback finished,
// so a reading slower than the interval would have every tick spawn another
// process on top of those already waiting; pollInFlight guards against that pile-up.
test("parent-liveness poll: a slow reply does not let ticks pile up concurrent readings", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    const delayMs = 100;
    const pollMs = 10;
    fx.setParentAlive("alive");
    fx.setParentAliveDelay(delayMs);
    await withParentEnv(process.pid, "boss-session", pollMs, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(fx, factory);
      const started = Date.now();
      await new Promise((r) => setTimeout(r, 500));
      const elapsed = Date.now() - started;
      const calls = fx.parentAliveCalls().length;
      const sequential = Math.ceil(elapsed / delayMs) + 1; // +1: the reading in flight right now
      assert.ok(calls >= 2, `only ${calls} readings in ${elapsed}ms - the poll stopped running, so this proves nothing`);
      assert.ok(
        calls <= sequential,
        `${calls} readings in ${elapsed}ms, want at most ${sequential} - ticks every ${pollMs}ms are piling up concurrent ${delayMs}ms calls`,
      );
      assert.equal(s.shutdowns(), 0, "and a slow but affirmative answer is still an affirmative answer");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// withHeartbeatEnv sets KIDO_HEARTBEAT_MS, restoring whatever was there
// before - kido-status.ts reads it once at module scope, so a case using
// it goes through freshExtensions() to pick it up (see withParentEnv).
async function withHeartbeatEnv<T>(ms: number, fn: () => Promise<T>): Promise<T> {
  return withEnv({ KIDO_HEARTBEAT_MS: String(ms) }, fn);
}

// The second incident: two pi processes on one session id. kido refuses
// the newcomer's claim (exit 6, State.record), and what this
// pins is everything that must then NOT happen - no second report, no
// heartbeat, no removal report on the way out, all of which would be
// writes to a record that belongs to the process still running. The
// notify is the only thing the user gets, and it names where the other
// one is.
//
// The claim is the session's first report, awaited: every assertion here
// is about what came after it, so the one status call in the log is the
// claim itself and its presence is what distinguishes a refusal from a
// pi that simply never spoke to kido at all.
test("a second pi on one session id claims nothing, reports nothing, and says so once", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    process.env.KIDO_FAKE_SESSION_HELD = "1";
    const s = await startSession(fx);

    assert.equal(fx.statusReportCount(), 1, "the claim was attempted exactly once");
    assert.equal(argAfter(fx.lastStatusArgs(), "--session"), DEFAULT_SESSION);

    const notified = s.notifications;
    assert.equal(notified.length, 1, `want one notification, got ${JSON.stringify(notified)}`);
    assert.match(notified[0].message, /already open in pane %9 \(pid 4242\)/, "names where the holder is");
    assert.equal(notified[0].type, "warning");

    await s.emit("turn_start");
    await s.emit("tool_call");
    await s.emit("agent_settled", {}, { isIdle: () => true });
    await s.emit("session_shutdown", { reason: "quit" });
    // Watched over a span, not sampled once: a report is a detached subprocess
    // appending to a file, so "nothing yet" and "nothing ever" read the same at any single instant.
    const until = Date.now() + 300;
    while (Date.now() < until) {
      assert.equal(fx.statusReportCount(), 1, "an untracked pi reports nothing after the refusal");
      assert.equal(fx.statusReportsWithRemove().length, 0, "and never removes the holder's record");
      await new Promise((r) => setTimeout(r, 20));
    }
  } finally {
    fx.restore();
  }
});

// Negative control: a gate that refused every session would pass the tests above too.
test("the first pi on a session id is tracked and goes on reporting", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await s.emit("turn_start");
    await pollUntil(() => fx.statusReportsWith("running").length >= 1, 2000, "a running report from a tracked session");
    assert.deepEqual(s.notifications, [], "nothing to tell the user about");
    await s.emit("session_shutdown", { reason: "quit" });
  } finally {
    fx.restore();
  }
});

test("a running session re-sends its status on a heartbeat, bypassing the coalescing key that would otherwise drop a repeat", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    // Long enough that no heartbeat fires before the coalescing check, even on a loaded runner.
    await withHeartbeatEnv(1000, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      await s.emit("turn_start");
      await s.emit("tool_execution_start");
      await s.emit("tool_call");
      await pollUntil(() => fx.statusReportsWith("running").length >= 1, 2000, "the first running report");
      assert.equal(fx.statusReportsWith("running").length, 1, "coalescing must still drop the identical follow-ups");

      await pollUntil(() => fx.statusReportsWith("running").length >= 2, 5000, "a heartbeat re-report past KIDO_HEARTBEAT_MS");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

test("the heartbeat stops once the session is no longer running", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    await withHeartbeatEnv(15, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      await s.emit("turn_start");
      // Wait for a heartbeat to have actually fired, not merely the first report.
      await pollUntil(() => fx.statusReportsWith("running").length >= 2, 2000, "a heartbeat re-report");
      await s.emit("agent_settled", {}, { isIdle: () => true });
      // Polled for a window with no growth, rather than sampled twice: a fixed
      // "sleep, then sleep again" lets a late arrival land in the second window
      // instead of the first on a loaded runner. Counted regardless of status,
      // not just "running": a heartbeat that failed to stop keeps resending "idle".
      await pollForStable(
        () => fx.statusReportCount(),
        200,
        3000,
        "the status report count",
      );
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

async function startWithControlSpies(fx: Fixture, idle?: () => boolean) {
  let aborts = 0;
  let shutdowns = 0;
  const s = await startSessionCore(fx, loadExtensions, () => ({
    ...fakeCtx(undefined, undefined, idle),
    abort: () => { aborts++; },
    shutdown: () => { shutdowns++; },
  }));
  return { ...s, aborts: () => aborts, shutdowns: () => shutdowns };
}

const controlTree = [
  { id: "self", name: "self", parent: "root-1", pane: "%1", self: true, canMessage: true },
  { id: "root-1", name: "root-1", parent: "", pane: "%2", self: false, canMessage: true, canReply: true },
  { id: "peer-x", name: "peer-x", parent: "", pane: "%3", self: false, canMessage: true, canReply: true },
];

// TestIsAncestorRefusesSelfEdge's TS twin: a corrupted record whose "parent"
// names itself must not make isAncestor(agents, X, X) true.
test("isAncestor refuses a self-edge, even with a corrupted self-parent record", () => {
  const self = { id: "x", name: "x", parent: "x", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self], self, self), false);
});

// Without the `seen` set, a genuine cycle among records none of which is self
// would loop forever instead of returning false.
test("isAncestor terminates on a parent cycle that never reaches self", () => {
  const a = { id: "a", name: "a", parent: "b", pane: "%1", self: false, canMessage: true, canReply: true, window: "@1", stalled: false, sinceReport: 0 };
  const b = { id: "b", name: "b", parent: "a", pane: "%2", self: false, canMessage: true, canReply: true, window: "@2", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%3", self: true, canMessage: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, a, b], self, a), false);
  assert.equal(isAncestor([self, a, b], self, b), false);
});

// A dangling parent id (a race between a spawn and an exit can leave one) must
// end the walk rather than loop on `cur` never changing.
test("isAncestor terminates when a parent names nobody in the list", () => {
  const orphan = { id: "orphan", name: "orphan", parent: "ghost-parent", pane: "%1", self: false, canMessage: true, canReply: true, window: "@1", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%2", self: true, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, orphan], self, orphan), false);
});

test("isAncestor finds a two-level ancestor", () => {
  const grand = { id: "grand", name: "grand", parent: "", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const mid = { id: "mid", name: "mid", parent: "grand", pane: "%2", self: false, canMessage: true, canReply: true, window: "@2", stalled: false, sinceReport: 0 };
  const child = { id: "child", name: "child", parent: "mid", pane: "%3", self: false, canMessage: true, canReply: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([grand, mid, child], grand, child), true);
});

test("an interrupt envelope from an ancestor calls ctx.abort() and does not shut the session down", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1, "ctx.abort() must be called exactly once");
    assert.equal(s.shutdowns(), 0, "an interrupt must never shut the session down");
  } finally {
    fx.restore();
  }
});

test("a stop envelope from an ancestor shuts the session down", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const resp = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.shutdowns(), 1, "ctx.shutdown() must be called exactly once");
    assert.equal(s.aborts(), 0, "a stop must not also abort");
  } finally {
    fx.restore();
  }
});

test("interrupt and stop are both refused, and neither abort nor shutdown is called, when the sender is not an ancestor", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const interruptResp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "peer-x", name: "peer-x" } }));
    assert.equal(interruptResp, "refused");

    const stopResp = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "peer-x", name: "peer-x" } }));
    assert.equal(stopResp, "refused");

    assert.equal(s.aborts(), 0);
    assert.equal(s.shutdowns(), 0);
  } finally {
    fx.restore();
  }
});

// An id not in kido's agents list at all - not a peer, not a descendant, just
// unknown - must be refused the same way a peer is.
test("interrupt and stop are refused when the sender's id matches no agent kido knows about", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "no-such-id", name: "ghost" } }));
    assert.equal(resp, "refused");
    assert.equal(s.aborts(), 0);
  } finally {
    fx.restore();
  }
});

// An interrupt leaves the session alive and able to take a following message -
// more than "shutdown was not called", the inbox itself must still answer.
test("an interrupt of an idle agent is harmless, and the session still answers a following message", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1);
    assert.equal(s.shutdowns(), 0);

    const followUp = await sendToInbox(s.inboxPath, envelope("message", "still there?", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(followUp, "ok");
    assert.ok(
      customMessages(s, "kido-message").some((m) => m.message.content.endsWith("\nstill there?")),
      "the session must still accept a message after an interrupt",
    );
  } finally {
    fx.restore();
  }
});

// ctx.abort() settles only after delayMs, the shape pi's own AgentSession.abort()
// takes while it waits out a live run (agent-session.js: `await this.waitForIdle()`).
async function startWithDelayedAbort(fx: Fixture, delayMs: number) {
  let aborts = 0;
  let abortSettledAt = 0;
  const s = await startSessionCore(fx, loadExtensions, () => ({
    ...fakeCtx(),
    abort: () =>
      new Promise<void>((resolve) => {
        setTimeout(() => {
          aborts++;
          abortSettledAt = Date.now();
          resolve();
        }, delayMs);
      }),
  }));
  return { ...s, aborts: () => aborts, abortSettledAt: () => abortSettledAt };
}

// The bug this pins: an unawaited ctxAbort?.() let the interrupt's inbox reply -
// and any envelope handled after it - race pi's own abort still settling. A
// message sent right after an interrupt (kido tool interrupt_subagent then
// message_agent) would land while pi still thought it was streaming, routing it
// into pi's low-level followUp queue instead of the run-starting path, which
// nothing ever drained. Pre-fix, this failed on the second assertion: the reply
// came back in a handful of ms while ctx.abort() was
// still 150ms from settling.
test("an interrupt does not answer until ctx.abort() settles, so a message sent right after is not orphaned", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithDelayedAbort(fx, 150);

    const before = Date.now();
    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    const answeredAt = Date.now();
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1);
    assert.ok(
      answeredAt - before >= 150,
      `the interrupt reply must not arrive before ctx.abort() settles (answered after ${answeredAt - before}ms)`,
    );
    assert.ok(
      s.abortSettledAt() > 0 && s.abortSettledAt() <= answeredAt,
      "ctx.abort() must have already settled by the time the reply is sent",
    );

    const msgResp = await sendToInbox(s.inboxPath, envelope("message", "still there?", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(msgResp, "ok");
    assert.ok(
      customMessages(s, "kido-message").some((m) => m.message.content.endsWith("\nstill there?")),
      "the message sent right after the interrupt must reach pi.sendMessage",
    );
  } finally {
    fx.restore();
  }
});

// Negative control: an already-idle abort() settles at once, so the fix must
// not have added a fixed wait of its own.
test("an interrupt to an idle session still answers promptly", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithDelayedAbort(fx, 0);

    const before = Date.now();
    const resp = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "root-1", name: "root-1" } }));
    assert.equal(resp, "ok");
    assert.equal(s.aborts(), 1);
    assert.ok(Date.now() - before < 150, `an interrupt to an idle session must not be held up (answered after ${Date.now() - before}ms)`);
  } finally {
    fx.restore();
  }
});

// A human running `kido tool interrupt_subagent` by hand has no session id for `from`;
// recognised by the empty session *and* a pane no agent occupies, so an agent
// that simply omits its session id is still held to the descendant rule.
test("a control envelope from a human at the CLI is honoured; one merely missing a session id is not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);

    const human = await sendToInbox(s.inboxPath, envelope("interrupt", "", { from: { session: "", name: "", pane: "%99" } }));
    assert.equal(human, "ok", "a human at the CLI may interrupt anything");
    assert.equal(s.aborts(), 1);

    const impostor = await sendToInbox(s.inboxPath, envelope("stop", "", { from: { session: "", name: "", pane: "%3" } }));
    assert.equal(impostor, "refused", "a pane an agent occupies is an agent, whatever `from` says");
    assert.equal(s.shutdowns(), 0);
  } finally {
    fx.restore();
  }
});

// grand -> mid -> child; which of self/target is the caller decides which one
// gets marked self:true per case below.
const askTree = [
  { id: "grand", name: "grand", parent: "", self: false, canMessage: true, canReply: true },
  { id: "mid", name: "mid", parent: "grand", self: false, canMessage: true, canReply: true },
  { id: "child", name: "child", parent: "mid", self: false, canMessage: true, canReply: true },
];

// Worth pinning: a model-authored `to` beginning with a dash would otherwise be
// read as a kido flag.
test("steer_subagent runs kido tool steer_subagent with the target behind -- and the message on stdin", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const res = await s.tools.get("steer_subagent").execute("c1", { to: "peer-a", message: "drop that, do X" });
    assert.match(res.content[0].text, /peer-a/);
    const sent = await fx.waitForLog("peer-a", "steer");
    assert.equal(sent.text, "drop that, do X", "the message goes on stdin, verbatim");
  } finally {
    fx.restore();
  }
});

// Asserts the mode, not merely that something arrived: a steer delivered as
// followUp would wait for the agent to decide to stop, exactly what steering
// exists to skip. Negative control: an ask must stay followUp - it carries a
// reply-correlation id, so two interleaved asks risk an answer reaching the wrong asker.
test("an inbound steer is delivered as steer; a message and an ask stay followUp", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx, () => false);
    const from = { session: "root-1", name: "root-1", pane: "%2" };

    assert.equal(await sendToInbox(s.inboxPath, envelope("steer", "drop that, do X", { from })), "ok");
    const steered = s.delivered.find((d) => d.text.includes("drop that, do X"));
    assert.ok(steered, "the steer reached the model");
    assert.equal((steered!.opts as any).deliverAs, "steer", "a steer joins the running turn rather than queueing behind it");
    assert.match(steered!.text, /root-1/, "and says who is redirecting the work, arriving mid-task as it does");

    assert.equal(await sendToInbox(s.inboxPath, envelope("message", "when you get a moment", { from })), "ok");
    const queued = customMessages(s, "kido-message")[0];
    assert.ok(queued, "the message reached the model");
    assert.equal((queued!.opts as any).deliverAs, "followUp", "a message still waits for the current turn to end");

    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "are you done?", { from })), "ok");
    const asked = askSent(s, "are you done?");
    assert.ok(asked, "the ask reached the model");
    assert.equal((asked!.opts as any).deliverAs, "followUp", "an ask must never steer: a correlated reply has to be answered one at a time");
  } finally {
    fx.restore();
  }
});

test("an inbound steer from a non-ancestor is refused and delivers nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const resp = await sendToInbox(s.inboxPath, envelope("steer", "do my bidding", { from: { session: "peer-x", name: "peer-x", pane: "%3" } }));
    assert.equal(resp, "refused");
    assert.equal(s.delivered.filter((d) => d.text.includes("do my bidding")).length, 0, "and nothing reached the model");
  } finally {
    fx.restore();
  }
});

test("ask_agent allows a parent asking its own child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "mid" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "child", question: "status?", timeoutMs: 50 });
    assert.doesNotMatch(result.content[0].text, /ancestor/, "a parent asking its own child must not be refused as an ancestor violation");
    assert.ok(await fx.waitForLog("child", "ask"), "the ask was actually sent to the child");
  } finally {
    fx.restore();
  }
});

test("ask_agent refuses a child asking its parent", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "child" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "mid", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /ancestor/, "a child asking its parent must be refused");
    assert.equal(fx.lastLogFor("mid", "ask"), undefined, "nothing must actually be sent to the parent");
  } finally {
    fx.restore();
  }
});

test("ask_agent refuses a child asking its grandparent, two levels up", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "child" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "grand", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /ancestor/, "a child asking its grandparent must be refused");
    assert.equal(fx.lastLogFor("grand", "ask"), undefined, "nothing must actually be sent to the grandparent");
  } finally {
    fx.restore();
  }
});

test("ask_agent still allows a peer asking a peer, unaffected by the ancestor guard", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers.slice(0, 2)); // self, peer-a - unrelated parents
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "status?", timeoutMs: 50 });
    assert.doesNotMatch(result.content[0].text, /ancestor/);
    assert.ok(await fx.waitForLog("peer-a", "ask"), "the ask was actually sent to the peer");
  } finally {
    fx.restore();
  }
});

test("ask_agent still refuses asking yourself", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(askTree.map((a) => (a.id === "mid" ? { ...a, self: true } : a)));
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "mid", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /cannot ask yourself/);
    assert.equal(fx.lastLogFor("mid", "ask"), undefined);
  } finally {
    fx.restore();
  }
});

test("ask_agent refuses a stalled target immediately, without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true, stalled: true, sinceReport: 245 },
    ]);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const result = await settlesWithin(ask.execute("c1", { to: "peer-a", question: "q" }), 500);
    assert.match(result.content[0].text, /stalled/);
    assert.match(result.content[0].text, /245/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a stalled target must never actually be asked");
  } finally {
    fx.restore();
  }
});

// The assertion with teeth: timeoutMs 600000 against settlesWithin(..., 500) -
// a version missing the liveness check would still answer correctly, only 600000ms later.
test("ask_agent refuses a target that is not alive, promptly and without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    fx.setParentAlive("gone");
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const result = await settlesWithin(ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }), 500);
    assert.match(result.content[0].text, /no longer running/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a dead target must never actually be asked");
    assert.ok(
      fx.parentAliveCalls().some((args) => args.includes("peer-a")),
      "the resolved target's own session id was queried",
    );
  } finally {
    fx.restore();
  }
});

// canReply is a run record's fact, not canMessage's: a target with an inbox but
// no message_agent tool has somewhere to send a reply, and still cannot send one.
test("ask_agent refuses a target spawned without the message_agent tool, without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: false },
    ]);
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "status?", timeoutMs: 50 });
    assert.match(result.content[0].text, /message_agent/);
    assert.match(result.content[0].text, /notify_parent/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a target that cannot reply must never actually be asked");
  } finally {
    fx.restore();
  }
});

test("ask_agent still sends to a target with canReply true", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    const s = await startSession(fx);
    const result = await s.tools.get("ask_agent").execute("c1", { to: "peer-a", question: "status?", timeoutMs: 50 });
    assert.doesNotMatch(result.content[0].text, /message_agent tool/);
    assert.ok(await fx.waitForLog("peer-a", "ask"), "the ask was actually sent to a target that can reply");
  } finally {
    fx.restore();
  }
});

// withAskPollEnv sets the interval a waiting ask re-reads its target's
// liveness on. It is read once at module scope, so every case using it
// goes through freshExtensions() to pick it up (see withParentEnv).
async function withAskPollEnv<T>(pollMs: number, fn: () => Promise<T>): Promise<T> {
  return withEnv({ KIDO_ASK_POLL_MS: String(pollMs) }, fn);
}

// The three cases below are about one thing: an ask that will never be
// answered has to end anyway, and end *promptly*. Each asserts settling
// well inside a timeoutMs generous enough that reaching it would be the
// bug - the failure being fixed is not a wrong message, it is no
// resolution arriving at all.
test("ask_agent releases its waiter when the target dies mid-wait, long before the timeout", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const ask = s.tools.get("ask_agent");

      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 });
      // The target was alive at the precheck: the ask really went out.
      const sent = await fx.waitForLog("peer-a", "ask");
      assert.equal(await pendingState(p), "pending", "a live target is still being waited for");

      fx.killSession("peer-a");
      const result = await settlesWithin(p, 3000);
      assert.match(result.content[0].text, /stopped running before answering/);
      assert.ok(result.content[0].text.includes(sent!.id), "the error names the ask id");
    });
  } finally {
    fx.restore();
  }
});

test("a waiting ask honours pi's abort signal, so the turn can be interrupted", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const ac = new AbortController();
    const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
    const sent = await fx.waitForLog("peer-a", "ask");
    assert.equal(await pendingState(p), "pending", "nothing has interrupted it yet");

    ac.abort();
    const result = await settlesWithin(p, 1000);
    assert.match(result.content[0].text, /interrupted/);

    const resp = await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      customMessages(s, "kido-reply").some((m) => m.message.content.includes("late answer")),
      "an abandoned ask leaves no waiter behind for a later reply to settle",
    );
  } finally {
    fx.restore();
  }
});

// The one ordering where the wait is over before the liveness watch is armed:
// an interval started after its own settle is one nothing will ever clear.
test("an ask aborted while its send is in flight leaves no liveness watch running", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    process.env.KIDO_FAKE_MESSAGE_DELAY_MS = "400";
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const ask = s.tools.get("ask_agent");

      const ac = new AbortController();
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
      await new Promise((r) => setTimeout(r, 100)); // still inside the send
      ac.abort();
      // Not instant: execute cannot return before the send it is awaiting does,
      // capped at 5s by runKido's own timeoutMs, a real subprocess spawn.
      const result = await settlesWithin(p, 9000);
      assert.match(result.content[0].text, /interrupted/);

      const readings = () => fx.parentAliveCalls().filter((args) => args.includes("peer-a")).length;
      await pollForStable(readings, 400, 6000, "the liveness readings for an abandoned ask to stop");
    });
  } finally {
    fx.restore();
  }
});

// Negative control: giving up on a healthy target that is merely slow would be
// worse than the hang.
test("a live target that takes its time is still waited for, and its reply is what arrives", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, canReply: true },
    ]);
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory });
      const ask = s.tools.get("ask_agent");

      const ac = new AbortController();
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
      const sent = await fx.waitForLog("peer-a", "ask");

      const readings = () => fx.parentAliveCalls().filter((args) => args.includes("peer-a")).length;
      await pollUntil(() => readings() >= 3, 6000, "several liveness readings that came back alive");
      assert.equal(await pendingState(p), "pending", "a slow but live target must still be waited for");

      const resp = await sendToInbox(s.inboxPath, envelope("reply", "the slow answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
      assert.equal(resp, "ok");
      assert.equal((await settlesWithin(p, 2000)).content[0].text, "the slow answer");
    });
  } finally {
    fx.restore();
  }
});

async function withIdleExitEnv<T>(seconds: number, keepAlive: boolean, fn: () => Promise<T>): Promise<T> {
  return withEnv({ KIDO_IDLE_EXIT_SECONDS: String(seconds), KIDO_AGENT_KEEP_ALIVE: keepAlive ? "1" : undefined }, fn);
}

test("idle self-exit: a settled turn with no further work shuts the session down after the configured idle interval, measured", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "boss-session", 5000, async () => {
      await withIdleExitEnv(0.1, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        const t0 = Date.now();
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() after the idle interval");
        const elapsed = Date.now() - t0;
        assert.ok(elapsed >= 100, `shut down after ${elapsed}ms, want at least the configured 100ms idle interval`);
        assert.ok(elapsed < 1500, `shut down after ${elapsed}ms, want well under 1500ms - it must not wait on the heartbeat or the parent poll`);
      });
    });
  } finally {
    fx.restore();
  }
});

test("idle self-exit: new work resets the timer instead of letting it fire mid-turn", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "boss-session", 5000, async () => {
      await withIdleExitEnv(0.15, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        await s.emit("agent_settled", {}, { isIdle: () => true }); // arms the 150ms timer
        await new Promise((r) => setTimeout(r, 80)); // well under it
        await s.emit("turn_start"); // new work: must cancel the pending shutdown
        await new Promise((r) => setTimeout(r, 100)); // would have fired by 150ms from the settle, had it not reset
        assert.equal(s.shutdowns(), 0, "new work must cancel the pending idle self-exit");
        await s.emit("agent_settled", {}, { isIdle: () => true }); // the follow-up turn settles too
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once idle again after the follow-up");
      });
    });
  } finally {
    fx.restore();
  }
});

test("idle self-exit: a root session (no parent) never arms the timer", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    const saved = process.env.KIDO_AGENT_PARENT_SESSION;
    delete process.env.KIDO_AGENT_PARENT_SESSION;
    try {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300)); // several times the configured interval
        assert.equal(s.shutdowns(), 0, "a root session must never self-reap");
      });
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_SESSION;
      else process.env.KIDO_AGENT_PARENT_SESSION = saved;
    }
  } finally {
    fx.restore();
  }
});

test("idle self-exit: keepAlive opts a child out entirely", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "boss-session", 5000, async () => {
      await withIdleExitEnv(0.05, true, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300));
        assert.equal(s.shutdowns(), 0, "keepAlive must prevent the idle timer from ever arming");
      });
    });
  } finally {
    fx.restore();
  }
});

test("idle self-exit: a focused window re-arms instead of shutting down, then exits once unfocused", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setWindowFocused(true);
    await withParentEnv(process.pid, "boss-session", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 600));
        assert.equal(s.shutdowns(), 0, "a focused window must not be closed out from under the user");
        assert.ok(
          fx.windowFocusedCallCount() >= 2,
          `get-window was checked ${fx.windowFocusedCallCount()} times, want re-arming to have checked more than once`,
        );

        fx.setWindowFocused(false);
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once the window is no longer focused");
      });
    });
  } finally {
    fx.restore();
  }
});

// Pins a real incident: a parent spawned a child, settled its own turn to wait
// for the report - indistinguishable from a finished session - and the orphan
// rule closed the child's window mid-work 30s later.
test("idle self-exit: a live child run re-arms the clock, and the session exits once that child has ended", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setChildrenAlive(true);
    await withParentEnv(process.pid, "boss-session", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 600));
        assert.equal(s.shutdowns(), 0, "a session waiting on a child it spawned is not idle");
        assert.ok(
          fx.childrenAliveCalls().length >= 2,
          `get-agent --children was asked ${fx.childrenAliveCalls().length} times, want re-arming to have asked more than once`,
        );

        // Negative control: the last child ends and the clock resumes.
        fx.setChildrenAlive(false);
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once the child has ended");
      });
    });
  } finally {
    fx.restore();
  }
});

for (const mode of ["fail", "timeout"]) {
  test(`idle self-exit: a ${mode} children check re-arms until it definitely answers false`, { timeout: 15000 }, async () => {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
      process.env.KIDO_FAKE_CHILDREN_ALIVE = mode;
      await withParentEnv(process.pid, "boss-session", 5000, async () => {
        await withIdleExitEnv(0.05, false, async () => {
          const factory = await freshExtensions();
          const s = await startWithShutdownSpy(fx, factory);
          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => fx.childrenAliveCalls().length >= 2 || s.shutdowns() > 0, 6000, "another children check or shutdown");
          if (mode === "timeout") await new Promise((resolve) => setTimeout(resolve, 2500));
          assert.equal(s.shutdowns(), 0, "an inconclusive children check must not shut down the session");
          assert.ok(fx.childrenAliveCalls().length >= 2, "the children check must re-arm");
          fx.setChildrenAlive(false);
          await pollUntil(() => s.shutdowns() > 0, 5000, "shutdown after a definite no-live-children answer");
        });
      });
    } finally {
      fx.restore();
    }
  });
}

// pi may decline a shutdown request while mid-compaction; the clock must not
// take ctx.shutdown() at its word, and re-arms so a declined request is asked for again.
test("idle self-exit: a shutdown pi declined is asked for again", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "boss-session", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(fx, factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await pollUntil(() => s.shutdowns() > 0, 2000, "the first ctx.shutdown() attempt");
        await s.emit("session_before_compact");
        await s.emit("session_compact");
        await pollUntil(
          () => s.shutdowns() > 1,
          2000,
          "a second ctx.shutdown() after the declined attempt's idle window",
        );
      });
    });
  } finally {
    fx.restore();
  }
});

test("a child that never called notify_parent flags its silence as it ends, and one that did does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-silent", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx, { factory, sessionId: "run-silent" });
      await s.emit("session_shutdown");
      assert.deepEqual(fx.lastRunOutcomeArgs(), [
        "run-outcome", "--result", "completed", "--unreported", "--", "run-silent",
      ], "a silent child asks kido to speak for it");
    });
  } finally {
    fx.restore();
  }

  // Negative control: a child that reported must not get a second notice too.
  const fx2 = makeFixture();
  try {
    fx2.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-spoke", async () => {
      const factory = await freshExtensions();
      const s = await startSession(fx2, { factory, sessionId: "run-spoke" });
      const res = await s.tools.get("notify_parent").execute("c1", { summary: "done: the tty fix landed" });
      assert.match(res.content[0].text, /delivered/, "the report itself has to have gone out");
      await s.emit("session_shutdown");
      assert.deepEqual(fx2.lastRunOutcomeArgs(), [
        "run-outcome", "--result", "completed", "--", "run-spoke",
      ], "a child that reported must not have a second ending sent for it");
    });
  } finally {
    fx2.restore();
  }
});

test("spawn_subagent passes --keep-alive through only when keepAlive is set", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");

    await spawn.execute("c1", { task: "a", name: "kid-a" });
    assert.ok(!fx.lastSpawnArgs()!.includes("--keep-alive"), "omitted keepAlive must not pass --keep-alive");

    await spawn.execute("c2", { task: "b", name: "kid-b", keepAlive: true });
    assert.ok(fx.lastSpawnArgs()!.includes("--keep-alive"), "keepAlive: true must pass --keep-alive");
  } finally {
    fx.restore();
  }
});
