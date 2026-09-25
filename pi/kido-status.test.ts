// Regression suite for the reply correlation, timeout, cycle refusal and
// inbox teardown logic in kido-status.ts and its companion extension
// kido-agents.ts. One suite covers the pair because the pair is what a pi
// host loads: every case here needs the status half's inbox and the agent
// half's dispatch at once, and splitting them would mean two suites
// sharing one fixture and each loading both files anyway. It drives the
// extensions only through what a real pi host and a real peer agent would
// use: the registered tools, the registered lifecycle events, and a real
// unix socket speaking the inbox wire protocol - never by reaching into
// either module's closures.
//
// A fake `kido` executable stands in for the real binary: it is what
// findKido() discovers on PATH, and every call the extension shells out
// to (list_agents --json, agent-status, message_agent) is answered by it.
// It never actually delivers a message anywhere - the "reply" half of a
// conversation is always injected directly onto the extension's own
// inbox socket, exactly as a real peer's `kido message_agent` would
// arrive.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Value } from "typebox/value";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdtempSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter, dirname } from "node:path";
import net from "node:net";
import { fileURLToPath, pathToFileURL } from "node:url";
import kidoStatus, { parseEnvelope } from "./kido-status.ts";
import kidoAgents, { isAncestor, nextStreamFlushDelay, setAskEdgeListener, streamBatch } from "./kido-agents.ts";

// The fake kido binary. Written to disk once per fixture so it can be
// found on PATH as a file literally named "kido" - findKido() joins a
// PATH entry with that name and checks it is executable, nothing fancier.
const FAKE_KIDO = `#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

function readStdin() {
  try { return fs.readFileSync(0, "utf8"); } catch { return ""; }
}

const args = process.argv.slice(2);
switch (args[0]) {
  case "inbox-path": {
    if (process.env.KIDO_FAKE_INBOX_FAIL === "1") process.exit(1);
    const dir = process.env.KIDO_FAKE_INBOX_DIR;
    fs.mkdirSync(dir, { recursive: true });
    process.stdout.write(path.join(dir, args[1] + ".sock") + "\\n");
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
    // KIDO_FAKE_AGENTS_DELAY_MS: how long this child holds its stdout
    // open before exiting, so a test can make the lookup slower than a
    // fixed wait the caller might otherwise use to guess at it.
    const delay = Number(process.env.KIDO_FAKE_AGENTS_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "agent-alive": {
    // The parent-liveness poll's whole query. KIDO_FAKE_PARENT_ALIVE is
    // "1" (alive, the default so no other case's poll ends its session),
    // "0" (gone), or "fail" for a kido that cannot answer at all.
    const logFile = process.env.KIDO_FAKE_PARENT_ALIVE_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    // Named instances answer "false" whatever the global mode says, and a
    // test can add one mid-run, which is how a target dies while an asker
    // is already waiting on it.
    const deadFile = process.env.KIDO_FAKE_DEAD_FILE;
    if (deadFile && fs.existsSync(deadFile)) {
      const dead = fs.readFileSync(deadFile, "utf8").split("\\n").filter(Boolean);
      if (dead.includes(args[1])) {
        process.stdout.write("false\\n");
        process.exit(0);
      }
    }
    const mode = process.env.KIDO_FAKE_PARENT_ALIVE ?? "1";
    const respond = () => {
      if (mode === "fail") {
        process.stderr.write("kido agent-alive: nope\\n");
        process.exit(1);
      }
      process.stdout.write((mode === "1" ? "true" : "false") + "\\n");
      process.exit(0);
    };
    const delay = Number(process.env.KIDO_FAKE_PARENT_ALIVE_DELAY_MS || 0);
    if (delay > 0) setTimeout(respond, delay); else respond();
    break;
  }
  case "children-alive": {
    // The idle self-exit clock's whole query: has this session got a run
    // of its own that has not ended. KIDO_FAKE_CHILDREN_ALIVE is "1" for
    // a live child, and anything else (the default) for none.
    const logFile = process.env.KIDO_FAKE_CHILDREN_ALIVE_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.stdout.write((process.env.KIDO_FAKE_CHILDREN_ALIVE === "1" ? "true" : "false") + "\\n");
    process.exit(0);
  }
  case "agent-status": {
    const logFile = process.env.KIDO_FAKE_STATUS_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  case "set_status": {
    const logFile = process.env.KIDO_FAKE_SET_STATUS_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  // The three commands that send an envelope. They share one log, keyed
  // by the kind each of them implies, because what every test here asks
  // is what went out on the wire - and the kind is no longer a flag any
  // of them carries. notify_parent's target is the one that is not an
  // argument at all: the real command reads it out of its own
  // environment, so the fake does too.
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
      to = process.env.KIDO_AGENT_PARENT_INSTANCE ?? null;
    } else if (replyTo) kind = "reply";
    const text = readStdin();
    const respond = () => {
      const failed = !!(process.env.KIDO_FAKE_MESSAGE_FAIL_TO && to === process.env.KIDO_FAKE_MESSAGE_FAIL_TO);
      // Logged either way: a test asserting a dropped delivery still needs
      // to see the attempt was made, with the right kind and target.
      const logFile = process.env.KIDO_FAKE_LOG;
      if (logFile) fs.appendFileSync(logFile, JSON.stringify({ kind, replyTo, id, to, text, failed }) + "\\n");
      if (failed) {
        process.stderr.write("kido " + args[0] + ": no agent listening on the inbox\\n");
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
    if (logFile) fs.appendFileSync(logFile, JSON.stringify({ args, task }) + "\\n");
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
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  case "close-run": {
    const logFile = process.env.KIDO_FAKE_CLOSE_RUN_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.exit(0);
  }
  case "window-focused": {
    const logFile = process.env.KIDO_FAKE_WINDOW_FOCUSED_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.stdout.write((process.env.KIDO_FAKE_WINDOW_FOCUSED === "1" ? "true" : "false") + "\\n");
    process.exit(0);
  }
  case "interrupt_subagent":
  case "stop_subagent": {
    const logFile = process.env.KIDO_FAKE_CONTROL_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    process.stdout.write((args[0] === "interrupt_subagent" ? "interrupted " : "stopped ") + args[args.length - 1] + "\\n");
    process.exit(0);
  }
  case "async_bash": {
    const logFile = process.env.KIDO_FAKE_ASYNC_BASH_LOG;
    if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + "\\n");
    // Four fields, the last of them the run's output file, exactly as
    // cmd/kido's printCreated writes them for a bash run.
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
  // killInstance kills one named instance without touching what every
  // other instance answers, and takes effect mid-run: the fake kido reads
  // the file on every call.
  killInstance(instance: string): void;
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
  // waitForLog polls lastLogFor until it has a match (see pollUntil).
  waitForLog(to: string, kind?: string, ms?: number): Promise<{ id: string; replyTo: string; to: string; text: string; failed?: boolean }>;
  restore(): void;
}

// jsonLines reads back one of the fake kido's JSONL logs; an empty file is
// simply no entries. last is the most recent of them, or undefined.
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
  mkdirSync(inboxDir);
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
  const deadInstancesFile = join(dir, "dead-instances");
  writeFileSync(deadInstancesFile, "");
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
  const windowFocusedLogFile = join(dir, "window-focused.jsonl");
  writeFileSync(windowFocusedLogFile, "");
  const childrenAliveLogFile = join(dir, "children-alive.jsonl");
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
  process.env.KIDO_FAKE_DEAD_FILE = deadInstancesFile;
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

  return {
    agentsFile,
    logFile,
    inboxDir,
    setAgents(agents) {
      writeFileSync(agentsFile, JSON.stringify(agents));
    },
    // What `kido agent-alive` answers the parent-liveness poll with. A
    // fixture's parent is alive until a test says otherwise, so no case
    // that merely happens to have a parent in its environment has its
    // session ended by the poll.
    setParentAlive(mode) {
      if (mode === "alive") delete process.env.KIDO_FAKE_PARENT_ALIVE;
      else process.env.KIDO_FAKE_PARENT_ALIVE = mode === "gone" ? "0" : "fail";
    },
    killInstance(instance) {
      appendFileSync(deadInstancesFile, instance + "\n");
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
    // Unfiltered by status, unlike statusReportsWith: a heartbeat that kept
    // firing after idle would report the now-current status ("idle"), not
    // "running", so a check scoped to one status would miss it.
    statusReportCount() {
      return jsonLines(statusLogFile).length;
    },
    agentsCallCount() {
      return jsonLines(agentsCallLogFile).length;
    },
    lastControlArgs() {
      return last(jsonLines(controlLogFile));
    },
    // Named after this test process's own pid, exactly as startInbox asks
    // kido for - the same reason a /reload rebinds at the same path.
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
      // maxRetries/retryDelay, not a bare rmSync: a liveness or send poll's
      // real subprocess can still be writing its log line into dir after a
      // test's own assertions are done with it, which rmSync alone reads
      // as ENOTEMPTY rather than retrying past.
      rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
    },
  };
}

// A fake pi host: enough of ExtensionAPI to register tools and lifecycle
// handlers and to record what the extension tried to say to the model.
function createFakePi() {
  const tools = new Map<string, any>();
  const handlers = new Map<string, Array<(...args: any[]) => unknown>>();
  const delivered: Array<{ text: string; opts: unknown }> = [];
  const messages: Array<{ message: any; opts: unknown }> = [];
  const renderers = new Map<string, (message: any, options: any, theme: any) => unknown>();
  // widgets is setWidget's own record, keyed the same way the real UI
  // keys a widget: content undefined means "cleared", exactly as
  // pi.ExtensionUIContext.setWidget itself treats it.
  const widgets = new Map<string, { content: string[] | undefined; options?: unknown }>();
  const pi = {
    registerTool(tool: any) {
      tools.set(tool.name, tool);
    },
    on(event: string, handler: (...args: any[]) => unknown) {
      (handlers.get(event) ?? handlers.set(event, []).get(event)!).push(handler);
    },
    sendUserMessage(text: string, opts: unknown) {
      delivered.push({ text, opts });
    },
    sendMessage(message: any, opts: unknown) {
      messages.push({ message, opts });
    },
    registerMessageRenderer(customType: string, renderer: (message: any, options: any, theme: any) => unknown) {
      renderers.set(customType, renderer);
    },
  };
  // emit returns each handler's own return value, in registration order,
  // so a test can read what a hook like before_agent_start would hand
  // back to a real pi host - the fake host applies none of it itself.
  async function emit(event: string, ...args: unknown[]): Promise<unknown[]> {
    const results: unknown[] = [];
    for (const h of handlers.get(event) ?? []) results.push(await h(...args));
    return results;
  }
  // Every factory handed to ui.addAutocompleteProvider, in registration
  // order: pi stacks them over its own built-in provider, so a test
  // builds the same stack by calling one with a provider of its own.
  const autocompleteFactories: Array<(current: any) => any> = [];
  const ui = {
    setWidget(key: string, content: string[] | undefined, options?: unknown) {
      widgets.set(key, { content, options });
    },
    addAutocompleteProvider(factory: (current: any) => any) {
      autocompleteFactories.push(factory);
    },
  };
  return { pi, tools, handlers, delivered, messages, renderers, widgets, autocompleteFactories, ui, emit };
}

// fakeTheme is the minimal Theme surface a message renderer reads: fg()
// applied as an identity function, so a rendered line's text is asserted
// on directly rather than through a colour-code-stripping helper.
const fakeTheme = { fg: (_color: string, text: string) => text } as any;

function fakeCtx(sessionId = "self-session", ui?: unknown) {
  return {
    sessionManager: { getSessionId: () => sessionId, getSessionName: () => undefined },
    model: undefined,
    isIdle: () => true,
    ui,
  };
}

async function startSession(fx: Fixture, sessionId?: string) {
  const { pi, tools, delivered, messages, renderers, widgets, autocompleteFactories, ui, emit } = createFakePi();
  loadExtensions(pi);
  await emit("session_start", {}, fakeCtx(sessionId, ui));
  return { tools, delivered, messages, renderers, widgets, autocompleteFactories, emit, inboxPath: fx.selfInboxPath() };
}

// loadExtensions is what a pi host does with the pair: run both factories
// against the same host. The order is deliberately agents-last here and
// asserted both ways in its own test below - neither extension may depend
// on the other's factory having run first (see the seam note in
// kido-status.ts), since pi discovers a directory and picks its own order.
function loadExtensions(pi: unknown): void {
  (kidoStatus as (pi: unknown) => void)(pi);
  (kidoAgents as (pi: unknown) => void)(pi);
}

// startSessionUsing is startSession but for factories that are not the
// modules' static default exports - needed by tests that must vary
// KIDO_AGENT_TASK_FILE or KIDO_AGENT_PARENT_INSTANCE, which the extensions
// read once, at module scope, when they are first imported.
// freshExtensions below reloads both so those module-scope constants are
// recomputed from whatever the environment holds at that moment.
async function startSessionUsing(factory: (pi: unknown) => void, fx: Fixture, sessionId?: string) {
  const { pi, tools, delivered, messages, renderers, widgets, autocompleteFactories, ui, emit } = createFakePi();
  factory(pi);
  await emit("session_start", {}, fakeCtx(sessionId, ui));
  return { tools, delivered, messages, renderers, widgets, autocompleteFactories, emit, inboxPath: fx.selfInboxPath() };
}

// freshExtensions reimports both extensions under a cache-busting
// specifier, so the module-scope constants each reads from the
// environment are recomputed. Both, and with the same counter: they are
// two modules that find each other through globalThis rather than through
// an import (see the seam note in kido-status.ts), so a fresh half and a
// cached half would silently pair up and serve a session neither started.
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

// The session id fakeCtx hands out when a case names none. A subagent's
// session id is its run id (docs/design.md, "The run id is the child's
// session id"), so a case playing one has to keep the two in step.
const DEFAULT_SESSION = "self-session";

// asSubagent makes this process look like the child kido spawned for a
// run: the parent edge, and the run id that must equal the session id the
// case then starts. An inherited parent edge alone no longer makes a
// subagent (kido-agents.ts, ownRunID), which is the whole point of the
// incident this pins - so every case that plays one sets both, here, in
// one place. extra carries whatever else a case needs in the same
// save/restore; the extensions read all of it once at module scope, so
// each case still goes through freshExtensions() to pick it up.
async function asSubagent<T>(
  sessionId: string,
  fn: () => Promise<T>,
  extra: Record<string, string> = {},
): Promise<T> {
  const vars: Record<string, string> = {
    KIDO_AGENT_PARENT_INSTANCE: "parent-inst",
    KIDO_AGENT_RUN_ID: sessionId,
    ...extra,
  };
  const saved: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    saved[k] = process.env[k];
    process.env[k] = v;
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

// A second copy of either file, at another path, registers nothing: pi
// dedupes by real path alone, so the copy kido's bin directory passes
// with --extension and one an earlier kido installed into pi's extensions
// directory both reach a factory. The copy lives under this directory
// only so its own imports resolve against node_modules here. The second
// half is the control the refusal is unsafe without: the file that
// claimed the slot still registers everything when run again, which is
// what a /reload does - a guard that refused every second factory call
// would pass the first half and leave a reloaded session with no tools.
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

// pi discovers extensions in a directory and picks its own order, so
// neither half may read the other at factory time (see the seam note in
// kido-status.ts). Loaded the other way round, the pair must still wire
// up whole: the agent half's tools registered, and an envelope arriving
// on the status half's inbox dispatched by kind rather than falling back
// to the plain-text path. Through freshExtensions only because that is
// what lets a case choose the order; nothing here depends on the
// constants a fresh import recomputes.
test("either load order wires the pair up: agents first, status second", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const factory = await freshExtensions("agents-first");
    const s = await startSessionUsing(factory, fx);
    assert.ok(s.tools.get("ask_agent"), "the agent half registered its tools");
    const resp = await sendToInbox(s.inboxPath, envelope("notice", "loaded either way", { from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      s.messages.some((m) => m.message.customType === "kido-notice" && m.message.content.endsWith("\nloaded either way")),
      "the envelope was dispatched by the agent half, not delivered as plain text",
    );
  } finally {
    fx.restore();
  }
});

// pollUntil waits for a condition to become true, polling rather than
// listening for anything: several assertions below observe work this
// extension does fire-and-forget (a detached, unref'd status report) or
// asynchronously via a real subprocess (runKido shells out via spawn, not
// execFileSync), so there is no promise to await and no event to subscribe
// to - only a file on disk to keep checking. In particular ask_agent's
// execute() can return control to its caller before the fake kido
// subprocess for the outbound send has appended its log entry.
async function pollUntil(cond: () => boolean, ms = 2000, what = "a condition"): Promise<void> {
  const deadline = Date.now() + ms;
  for (;;) {
    if (cond()) return;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

// pollForStable waits for `read()` to stop changing for a full `quietMs`
// window, not merely for two samples some fixed delay apart to happen to
// match - a late-arriving in-flight call can land at any point on a loaded
// runner, so only "nothing changed for a whole quiet window" tells a drain
// apart from a heartbeat that is still running. A source that never goes
// quiet (the negative control this exists for) times out instead of
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
function settlesWithin<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`did not settle within ${ms}ms`)), ms)),
  ]);
}

const twoPeers = [
  { id: "self", name: "self", parent: "", self: true, canMessage: true },
  { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true },
  { id: "peer-b", name: "peer-b", parent: "", self: false, canMessage: true },
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
    assert.ok(s.delivered.some((d) => d.text.includes("stray answer")), "an unmatched reply is surfaced to the model");
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
    assert.ok(
      s.delivered.some((d) => d.text.includes("late answer") && d.text.includes(sent!.id)),
      "a late reply is delivered as a message, naming the ask it answered",
    );
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
    // pendingOutbound.set runs strictly before the send that produces this
    // log entry (see its comment in kido-agents.ts), so waiting for the
    // entry is a safe way to know the edge is already registered.
    await fx.waitForLog("peer-a", "ask");

    const refused = await sendToInbox(s.inboxPath, envelope("ask", "are you free?", { id: "inbound-1", from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(refused, "refused");
    assert.ok(!s.delivered.some((d) => d.text.includes("are you free?")), "a refused ask is not shown to the model");

    const ok = await sendToInbox(s.inboxPath, envelope("ask", "another question", { id: "inbound-2", from: { session: "peer-b", name: "peer-b" } }));
    assert.equal(ok, "ok");
    assert.ok(s.delivered.some((d) => d.text.includes("another question")), "an ask from anyone else is shown");

    // Release the edge so p1 does not dangle past the test.
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

// A pi session with no title falls back to its session id as the reply
// address (labelFrom); a /reload changes that id while leaving the
// sender's pane and instance untouched. message_agent must re-resolve
// the reply against the sender's current session, found by pane, not
// the stale one the model was told about when the ask arrived.
test("a reply to an unnamed asker still reaches it after the asker reloads and its session id changes", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-old", name: "", pane: "%42", parent: "", self: false, canMessage: true },
    ]);
    const s = await startSession(fx);

    const resp = await sendToInbox(
      s.inboxPath,
      envelope("ask", "still there?", { id: "ask-reload-1", from: { session: "peer-a-old", pane: "%42" } }),
    );
    assert.equal(resp, "ok");
    const asked = s.delivered.find((d) => d.text.includes("is asking"));
    assert.ok(asked, "the ask was delivered to the model");
    assert.match(asked!.text, /message_agent\(to="peer-a-old"/, "an unnamed asker's fallback label is its session id");

    // The asker reloads: same pane and agent, a new session id, before
    // this session gets around to replying.
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a-new", name: "", pane: "%42", parent: "", self: false, canMessage: true },
    ]);

    // The model does exactly what it was told: replies to the now-stale
    // "peer-a-old" label.
    const reply = await s.tools.get("message_agent").execute("c1", { to: "peer-a-old", message: "still here", replyTo: "ask-reload-1" });
    assert.doesNotMatch(reply.content[0].text, /could not message/, "the reply must not fail just because the asker reloaded");

    const sent = fx.lastLogFor("peer-a-new");
    assert.ok(sent, "the reply was actually addressed to the asker's current session, not its stale one");
    assert.equal(fx.lastLogFor("peer-a-old"), undefined, "the stale session id was never dialled");
  } finally {
    fx.restore();
  }
});

// message_agent's own returned text is the strongest of the three places
// the stop-after instruction is repeated - the last thing the model reads
// before deciding whether to keep talking - so it must carry it, but only
// when replyTo genuinely answers an ask this session has pending; a
// reply to a notice, or a stale/unknown id, is not that and must not gain
// an instruction that makes no sense attached to it.
test("message_agent's result says to stop after replying to a pending ask, but not after any other send", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", pane: "%2", parent: "", self: false, canMessage: true },
    ]);
    const s = await startSession(fx);

    // pane set: handleInboundAsk only remembers a pending ask when the
    // envelope carries one (pendingInboundAsks is keyed by pane).
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

    // session_shutdown: nothing is coming back, so the wait must not run
    // out its own (5-minute default) timeout.
    {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");
      const p = ask.execute("c1", { to: "peer-a", question: "q" });
      await s.emit("session_shutdown");
      const out = await settlesWithin(p, 500);
      // Which message comes back depends on whether ask_agent had already
      // registered its waiter (fetchAgents is async - see the `!inbox`
      // check in kido-status.ts) by the time
      // session_shutdown ran: either abandonPending caught an
      // already-registered waiter, or the check turned away a
      // registration that had not happened yet. Both are "gave up because
      // of shutdown", never "will try again later".
      assert.match(out.content[0].text, /inbox closed|inbox is unavailable/);
      assert.doesNotMatch(out.content[0].text, /will still arrive/, "must not promise a reply that can no longer land");
    }

    // A /reload whose rebind fails abandons the same way.
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

    // A plain reload whose rebind succeeds must not abandon anything: the
    // waiter survives and a reply on the rebound (same-path) inbox still
    // resolves it.
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

// The extension's end of "each tool gets its own subcommand"
// (docs/design-subagents.md, "The tools, and their commands"). This half
// asserts the registered tools are exactly the names in
// pi/testdata/tools.json; cmd/kido's own
// TestEveryToolHasASubcommandOfItsName asserts every name in that file is
// a kido subcommand. Split that way because the drift worth catching is a
// tool added here - which this test fails until the fixture names it, and
// the Go test then fails until kido has the subcommand. A Go-side list of
// tool names on its own would never notice, since nobody adding a tool to
// this file has a reason to go and edit one.
//
// Registration is unconditional at factory time, so a plain session sees
// every tool; nothing here depends on a session having resolved kido.
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
      `pi/testdata/tools.json names ${JSON.stringify(missing)}, but no tool registers ${missing.length === 1 ? "it" : "them"}`,
    );
    assert.deepEqual(
      extra,
      [],
      `${JSON.stringify(extra)} ${extra.length === 1 ? "is" : "are"} registered but not in pi/testdata/tools.json, ` +
        "so nothing checks that a kido subcommand of that name exists - add it to the fixture and give it a subcommand",
    );
  } finally {
    fx.restore();
  }
});

// parseEnvelope mirrors internal/msg.Parse: the same v0/v1 discriminator
// rule implemented twice, once in Go and once here. A disagreement
// between the two is how a user's prompt gets silently swallowed as a
// control message (or the reverse: a real envelope treated as raw text).
// Driven from internal/msg/testdata/discriminator.json, the fixture
// internal/msg's own discriminator table test drives, so the two suites
// cannot drift apart by someone editing only one list.
test("parseEnvelope agrees with internal/msg.Parse's v0/v1 discriminator table", () => {
  const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "..", "internal", "msg", "testdata", "discriminator.json");
  const cases: { name: string; raw: string; ok: boolean }[] = JSON.parse(readFileSync(fixturePath, "utf8"));
  assert.ok(cases.length >= 11, `expected at least 11 cases in the shared fixture, got ${cases.length}`);
  for (const c of cases) {
    const got = parseEnvelope(c.raw) !== null;
    assert.equal(got, c.ok, `${c.name}: parseEnvelope(${JSON.stringify(c.raw)}) ok = ${got}, want ${c.ok}`);
  }
});

// A model answering an ask correctly calls message_agent - that part
// already worked - and then went on to write a user-facing summary of
// what it had just done, in the same turn. That trailing narration
// reaches nobody: the asker already has its answer, and no user is
// waiting on a report in this session. The delivered text must say the
// message_agent call IS the whole response, not merely how to make it.
test("an inbound ask's delivered text says the message_agent reply is the whole response, with no summary after it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-y", from: { session: "peer-a", name: "peer-a" } }));
    const delivered = s.delivered.find((d) => d.text.includes("is asking"))?.text ?? "";
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
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, "plain v0 text");
    assert.ok(s.delivered.some((d) => d.text === "plain v0 text"), "v0 raw text is delivered unchanged");

    await sendToInbox(s.inboxPath, envelope("message", "hello", { from }));
    assert.ok(s.delivered.some((d) => d.text === "hello"), "kind message delivers its text as-is");

    await sendToInbox(s.inboxPath, envelope("notice", "build finished", { from }));
    assert.ok(
      s.messages.some((m) => m.message.customType === "kido-notice" && m.message.content.endsWith("\nbuild finished") && m.message.details?.from === "peer-a"),
      "kind notice reaches the model as a custom message, named by its sender, full text intact",
    );

    const askResp = await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-x", from }));
    assert.equal(askResp, "ok");
    assert.ok(s.delivered.some((d) => d.text.includes("peer-a is asking") && d.text.includes("you there?")));

    await sendToInbox(s.inboxPath, envelope("reply", "an answer", { replyTo: "no-such-ask", from }));
    assert.ok(s.delivered.some((d) => d.text.includes("replied") && d.text.includes("an answer")));

    await sendToInbox(s.inboxPath, envelope("ping", "unknown kind text", { from }));
    assert.ok(s.delivered.some((d) => d.text.includes("unrecognised message kind") && d.text.includes("unknown kind text")));
  } finally {
    fx.restore();
  }
});

// Part 4 of the notify_parent refactor (docs/design.md, "Notifying the
// parent"): an inbound notice renders collapsed by default and expands
// under pi's own ctrl-o toggle (options.expanded), which this extension
// never binds itself - see kido-agents.ts's registerMessageRenderer call.
// The collapsed line is the notice's own first line (e.g. an async run's
// own `async run "build" failed: exit status 3`), not a generic
// placeholder - kido-agents.ts's registerMessageRenderer takes only that
// much off the notice text, nothing further into whatever body follows.
test("an inbound notice renders collapsed by default, naming the sender and its own first line, and expands to the full text", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };
    const text = 'async run "build" failed: exit status 3\nrun: abc123\noutput: /tmp/x/output\n--- output ---\nboom';

    await sendToInbox(s.inboxPath, envelope("notice", text, { from }));
    const sent = s.messages.find((m) => m.message.customType === "kido-notice");
    assert.ok(sent, "a notice was sent as a custom message");
    assert.ok(sent!.message.content.endsWith(`\n${text}`), "the model-visible content is the notice's full text, under its header line");

    const renderer = s.renderers.get("kido-notice");
    assert.ok(renderer, "the agent half registered a renderer for its own custom type");

    const collapsed = renderer!(sent!.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(
      collapsed,
      /notification from peer-a: async run "build" failed: exit status 3 .*ctrl-o to expand/,
      "the collapsed line names the sender, carries the notice's own first line as its summary, and hints at expansion",
    );
    assert.ok(!collapsed.includes("boom"), "the collapsed line does not leak the body past the first line");

    const expanded = renderer!(sent!.message, { expanded: true, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.ok(expanded.includes("boom"), "expanding shows the full content, tail included");
  } finally {
    fx.restore();
  }
});

// A notice is steered into a running turn, where it reads exactly like
// the user having typed - the confusion Claude Code's "[SYSTEM
// NOTIFICATION - NOT USER INPUT]" header exists to end. The header is
// model-facing only: the transcript already says who a notification is
// from, so the renderer takes it back off, and the collapsed row is still
// the child's own first line rather than a row of identical headers.
test("a notice reaches the model under a header naming what it is, and the header is not what the TUI shows", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const text = "reviewed internal/ui: two findings\nthe second one needs a decision";

    await sendToInbox(s.inboxPath, envelope("notice", text, { from: { session: "kid-1", name: "kid-1" } }));
    const sent = s.messages.find((m) => m.message.customType === "kido-notice")!;
    const [header, ...body] = (sent.message.content as string).split("\n");
    assert.match(header!, /^notice from kid-1 \(.*not the user\):$/, "one header line, naming the sender and what this is");
    assert.equal(body.join("\n"), text, "the child's own text follows, from the next line, byte for byte");

    const renderer = s.renderers.get("kido-notice")!;
    const collapsed = renderer(sent.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(collapsed, /notification from kid-1: reviewed internal\/ui: two findings/, "the collapsed row is the child's first line, not the header");
    const expanded = renderer(sent.message, { expanded: true, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.ok(!expanded.includes("not the user"), "nor does expanding show a header the transcript already carries");
    assert.ok(expanded.includes("needs a decision"), "expanding still shows the whole text");

    // The plain "message" kind deliberately carries no sender label at
    // all (docs/design.md, "The inbox"); nothing here may leak onto it.
    await sendToInbox(s.inboxPath, envelope("message", "do the other thing", { from: { session: "kid-1", name: "kid-1" } }));
    assert.ok(s.delivered.some((d) => d.text === "do the other thing"), "a plain message is still delivered unlabelled");
  } finally {
    fx.restore();
  }
});

test("a notice from a nameless sender still renders sanely, collapsed and expanded", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // No name and no session: what a human running `kido notify_parent`
    // from a bare pane looks like on the wire (labelFrom's own
    // fallback order: name, session, pane, "another agent").
    await sendToInbox(s.inboxPath, envelope("notice", "from a human", { from: { session: "", pane: "%12" } as any }));
    const sent = s.messages.find((m) => m.message.customType === "kido-notice");
    assert.equal(sent!.message.details.from, "%12", "the pane stands in for a name when there is none");

    const renderer = s.renderers.get("kido-notice")!;
    const collapsed = renderer(sent!.message, { expanded: false, outputPad: 1 }, fakeTheme).render(80).join("\n");
    assert.match(collapsed, /notification from %12/, "a nameless sender still gets a sane, non-empty label");
  } finally {
    fx.restore();
  }
});

// `@` completion. pi stacks an extension's provider over its own
// built-in one (ctx.ui.addAutocompleteProvider, pi 0.87.1), which is what
// lets agent names share the trigger `@` already uses for file
// references instead of taking it away: stackOver builds that stack the
// way pi does, with a stand-in for the built-in half that records what it
// was asked and answers the same `@token` prefix pi's own
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

// Nothing is fetched until the first `@`, and that first keystroke is
// served before its own refresh lands - the editor never waits on a
// subprocess. So every assertion about what is offered polls keystrokes
// until the list is there, which is what a typing human does, rather
// than sleeping a guess at how long one subprocess takes.
async function suggestOnceListed(provider: any, line: string, ms = 2000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const suggestions = await suggest(provider, line);
    if (suggestions?.items?.some((i: any) => i.value.startsWith("@") && !i.value.includes("/"))) return suggestions;
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for the agent list behind "${line}"`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

const completionAgents = [
  { id: "self", name: "self", parent: "", self: true, canMessage: true, status: "running" },
  { id: "p1", name: "helm", parent: "", self: false, canMessage: true, status: "idle" },
  { id: "c1", name: "helper-one", parent: "p1", self: false, canMessage: true, status: "running", activity: "refactoring internal/ui" },
  { id: "c2", name: "builder", parent: "p1", self: false, canMessage: true, status: "waiting" },
  // A session the user never named: `kido list_agents` falls back to the
  // pane title, which is a phrase with spaces in it (a Claude Code title
  // here) rather than a handle. Its id shares eight characters with the
  // next agent's, so the prefix that identifies it has to be longer than
  // the floor.
  { id: "01a0d843-7f2e-4b5a-9c31-8de0f1a2b3c4", name: "Tmux config", parent: "", self: false, canMessage: true, status: "running" },
  { id: "01a0d843-ffff-4b5a-9c31-8de0f1a2b3c4", name: "scribe", parent: "", self: false, canMessage: true, status: "idle" },
  { id: "k9", name: "config-linter", parent: "", self: false, canMessage: true, status: "idle" },
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

    // The negative control: a name that survives as a token is still
    // inserted as itself. An id prefix everywhere would pass every
    // assertion above and make every completion unreadable.
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

    // An @ token that matches no agent is the same delegation: the file
    // half's own answer, with nothing added and nothing dropped.
    const files = await suggest(provider, "@src/ma");
    assert.deepEqual(files.items.map((i: any) => i.value), ["src/main.ts"], "@src/... still completes files");
  } finally {
    fx.restore();
  }
});

// A keystroke may never wait on `kido list_agents --json`: the editor is
// offered the list in hand and the refresh runs behind it. The fake kido
// holds its answer for 400ms here, far longer than the completion is
// allowed to take, and the assertion with teeth is that the slow call
// happened at all - a provider that simply never refreshed would satisfy
// the deadline and go stale forever.
test("@ completion serves the last agent list without waiting for the subprocess behind it", async () => {
  const fx = makeFixture();
  const savedTTL = process.env.KIDO_AGENT_LIST_TTL_MS;
  try {
    fx.setAgents(completionAgents);
    process.env.KIDO_AGENT_LIST_TTL_MS = "50";
    const s = await startSessionUsing(await freshExtensions(), fx);
    const { provider } = stackOver(s.autocompleteFactories);

    await suggestOnceListed(provider, "@hel");

    process.env.KIDO_FAKE_AGENTS_DELAY_MS = "400";
    const callsBefore = fx.agentsCallCount();
    await new Promise((r) => setTimeout(r, 60)); // past the TTL: the next keystroke refreshes

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

// The render path and the model path are different code paths (see the
// user's own report: two subagents' notices sat invisible for minutes,
// both appearing only when the parent's turn happened to end). This is
// the render half in isolation: a widget row must appear the instant the
// envelope lands, before pi ever gets around to actually delivering the
// steered message to the model - nothing here waits on a turn ending,
// because the fake host never ends one.
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
    assert.ok(widget!.content!.some((line) => line.includes("peer-a")), "the widget row names the sender");

    // The model-visible message was already handed to sendMessage in the
    // very same call - the widget is in addition to that, not instead of
    // it.
    const sent = s.messages.find((m) => m.message.customType === "kido-notice");
    assert.ok(sent, "the notice was also handed to sendMessage, unconditionally");
  } finally {
    fx.restore();
  }
});

// A notice is the one envelope kind delivered by steer rather than
// followUp (docs/design.md, "The inbox", carries the exception and why):
// a parent whose own turn runs long must not sit on a finished child's
// report until its turn happens to end, since that defeats doing the work
// in a subagent at all. Plain messages and asks are the negative control -
// they must stay on followUp, unchanged.
test("a notice is delivered by steer, not followUp; plain messages and asks are unaffected", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("notice", "build finished", { from }));
    const sent = s.messages.find((m) => m.message.customType === "kido-notice");
    assert.ok(sent, "the notice reached sendMessage");
    assert.equal((sent!.opts as any).deliverAs, "steer", "a notice steers into the running turn rather than waiting for it to end");

    await sendToInbox(s.inboxPath, envelope("message", "a plain message", { from }));
    assert.ok(s.delivered.some((d) => d.text === "a plain message"), "a plain message still goes through sendUserMessage/deliver");

    await sendToInbox(s.inboxPath, envelope("ask", "you there?", { id: "ask-y", from }));
    assert.ok(s.delivered.some((d) => d.text.includes("you there?")), "an ask still goes through the same deliver() path as a plain message, unaffected by the notice-only steer change");
  } finally {
    fx.restore();
  }
});

// The other half of the same defect: once the identical steered message
// actually reaches the model (message_start, matched by the noticeId this
// extension mints), the model has the full text exactly once, and the
// stand-in widget row is removed rather than left to show a notice twice
// over.
test("a notice reaches the model exactly once, and its widget row is removed once delivery actually happens", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const from = { session: "peer-a", name: "peer-a" };

    await sendToInbox(s.inboxPath, envelope("notice", "the whole result", { from }));
    const noticeMessages = s.messages.filter((m) => m.message.customType === "kido-notice");
    assert.equal(noticeMessages.length, 1, "the notice's text was sent to the model exactly once");
    const sent = noticeMessages[0]!.message;
    assert.ok(sent.content.endsWith("\nthe whole result"), "the model-visible text is the notice's full text, unchanged under its header line");
    const noticeId = sent.details?.noticeId;
    assert.ok(noticeId, "the message carries an id the widget half can be matched against");

    assert.ok(s.widgets.get("kido-notice-pending")?.content, "the widget is still up before delivery actually happens");

    // Simulate what a real pi host does once the steered message actually
    // lands in the transcript: fires message_start with the same message
    // this extension handed to sendMessage.
    await s.emit("message_start", { message: { ...sent, role: "custom" } });

    assert.equal(s.widgets.get("kido-notice-pending")?.content, undefined, "the widget is cleared once the real entry has taken over");

    // A second, unrelated message_start (an outbound reply, say) must not
    // resurrect or otherwise disturb an already-cleared widget.
    await s.emit("message_start", { message: { role: "custom", customType: "some-other-type" } });
    assert.equal(s.widgets.get("kido-notice-pending")?.content, undefined, "an unrelated message_start leaves the cleared widget alone");
  } finally {
    fx.restore();
  }
});

// Part 3 of the notify_parent refactor: a spawned child must be told
// reporting is its own job now that nothing does it automatically. Fires
// on every prompt, not just the child's first, since a task delivered
// once via deliverTask is the wrong lifetime for a standing rule (a
// parent's later message_agent call produces a follow-up turn with no
// other memory of it).
test("a subagent's system prompt carries the notify_parent instruction; a root session's does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
      const override = results.find((r: any) => r?.systemPrompt) as { systemPrompt: string } | undefined;
      assert.ok(override, "a subagent's before_agent_start hook returns a replacement system prompt");
      assert.ok(override!.systemPrompt.startsWith("base prompt"), "the base prompt is preserved, not replaced");
      assert.match(override!.systemPrompt, /notify_parent/, "the instruction names the tool the model must call");
      assert.match(
        override!.systemPrompt,
        /entire response|whole response/i,
        "also carries the stop-after-replying instruction, at system-prompt level where it can compete with the host's own",
      );
    });
  } finally {
    fx.restore();
  }

  const rootFx = makeFixture();
  try {
    rootFx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(rootFx); // root session: no KIDO_AGENT_PARENT_INSTANCE
    const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
    assert.ok(results.every((r) => r === undefined), "a root session's system prompt is left alone");
  } finally {
    rootFx.restore();
  }
});

test("interrupt_subagent runs kido interrupt_subagent with the target, and stop_subagent runs kido stop_subagent, passing --force through", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(twoPeers);
    const s = await startSession(fx);

    const interruptRes = await s.tools.get("interrupt_subagent").execute("c1", { to: "peer-a" });
    assert.match(interruptRes.content[0].text, /interrupted peer-a/);
    assert.deepEqual(fx.lastControlArgs(), ["interrupt_subagent", "--", "peer-a"]);

    const stopRes = await s.tools.get("stop_subagent").execute("c2", { to: "peer-b" });
    assert.match(stopRes.content[0].text, /stopped peer-b/);
    assert.deepEqual(fx.lastControlArgs(), ["stop_subagent", "--", "peer-b"]);

    await s.tools.get("stop_subagent").execute("c3", { to: "peer-b", force: true });
    assert.deepEqual(fx.lastControlArgs(), ["stop_subagent", "--force", "--", "peer-b"]);
  } finally {
    fx.restore();
  }
});

// argAfter reads the value following a flag in an argv-shaped array, the
// same way the args a fake kido logged are read back apart.
function argAfter(args: string[] | undefined, flag: string): string | undefined {
  if (!args) return undefined;
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

// A bare alias like "sonnet" (what AGENTS.md files in the wild have told
// orchestrators to pass) used to reach pi's own --model unresolved, where
// it silently matched no provider and ran no turn for thirty seconds
// before failing; kido spawn_subagent now checks it against `pi
// --list-models` up front. The schema is the only place a model-calling
// caller ever reads the expected shape, so it has to say it.
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

// The incident these two descriptions exist to prevent: a parent spawned
// reviewers with no message_agent tool, then ask_agent'd each for its
// result and blocked. Both sentences ride along on every turn, so they
// are pinned here rather than left to the tests above that only exercise
// the behaviour.
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

// The same incident from the other end: the description is read when the
// tool is called, and a launch result is read at the one moment the model
// has a child and no result from it - which is when it invents one, or
// blocks. Claude Code puts the rule in its own launch result for exactly
// that reason; both spawns and resumes carry it here.
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
    }
  } finally {
    fx.restore();
  }
});

// promptGuidelines is pi's own field (core/extensions/types.d.ts): each
// string becomes a bullet in the system prompt's rules section while the
// tool is registered, merged by buildRules in pi's system-prompt.js. It
// is where a rule about the turns *after* a call belongs, a description
// being read only when the tool is called. The shape assertions are
// pi's _normalizePromptGuidelines (agent-session.js), which trims, drops
// the empty and de-duplicates: a guideline that survives it unchanged is
// one the model reads as written.
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
      bashRules.some((r) => /keep working, do not sleep or poll for it/.test(r)),
      "async_bash: the notice comes to the model; waiting for it costs the parallelism the tool is for",
    );

    // One string, not two similar ones: buildRules de-duplicates by exact
    // text, so the shared rule is a single bullet however many of the two
    // tools a session has.
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

test("spawn_subagent passes its task as text on stdin and calls kido spawn_subagent with its own identity and depth+1, without waiting for the child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    // send()'s agent-status report is fire-and-forget (a detached, unref'd
    // subprocess), so there is nothing to await here but the file it
    // eventually writes.
    await pollUntil(() => fx.lastStatusArgs() !== undefined);
    const ownInstance = argAfter(fx.lastStatusArgs(), "--instance");
    assert.ok(ownInstance, "session_start reported its own --instance");

    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
    assert.match(result.content[0].text, /kid-1/);
    assert.equal(result.details.run, "fake-run-id", "the run id kido spawn_subagent printed is returned so the model can refer to it later");

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido spawn_subagent was invoked");
    assert.equal(argAfter(spawnArgs, "--parent-pid"), String(process.pid), "passes its own pid as --parent-pid");
    assert.equal(argAfter(spawnArgs, "--parent-instance"), ownInstance, "passes its own --instance as --parent-instance");
    assert.equal(argAfter(spawnArgs, "--depth"), "1", "a root agent (no KIDO_AGENT_DEPTH) spawns at depth+1 = 1");
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

test("spawn_subagent(resume) calls kido spawn_subagent --resume with its own identity, and no task file", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    await pollUntil(() => fx.lastStatusArgs() !== undefined);
    const ownInstance = argAfter(fx.lastStatusArgs(), "--instance");

    const spawn = s.tools.get("spawn_subagent");
    const result = await spawn.execute("c1", { resume: "run-abc" });
    assert.match(result.content[0].text, /run-abc|fake-run-id/, "the run id is named in the result");

    const spawnArgs = fx.lastSpawnArgs();
    assert.ok(spawnArgs, "kido spawn_subagent was invoked");
    assert.equal(argAfter(spawnArgs, "--resume"), "run-abc");
    assert.equal(argAfter(spawnArgs, "--parent-pid"), String(process.pid), "carries its own identity through exactly as a fresh spawn does");
    assert.equal(argAfter(spawnArgs, "--parent-instance"), ownInstance);
    assert.ok(!spawnArgs!.includes("--task-file"), "a resume keeps its own original task; no task file is written for it");
    assert.ok(!spawnArgs!.includes("--name"), "a resume keeps its own original window name");
    // No model/tools override given: kido spawn_subagent --resume already carries
    // the run's own recorded model forward on its own, so nothing after
    // -- is needed here at all.
    assert.ok(!spawnArgs!.includes("--"), "no command override is sent when neither model nor tools is given");
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

// A resume brings a run back idle: it keeps its original task, which it
// has already been given, so nothing is delivered to it and it waits.
// The result text used to say only that the run was resumed, and a
// parent that resumed a killed run then waited on a child that was
// waiting on it. Clarity only - what the tool does is unchanged.
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

// fork is the one spawn parameter whose value the model never supplies:
// the session to fork is this one, and the tool reads its id from pi
// rather than letting a model name a session. So what is asserted is
// that the id on the command line is this session's own - a tool that
// passed a plausible-looking anything would satisfy "--fork is present".
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
    // The kido flag is the whole of it: the child's own `pi --fork ... 
    // --session-id RUN` command line is kido's to build, so the tool must
    // not be spelling a second, divergent copy of it after "--".
    const command = spawnArgs.slice(spawnArgs.indexOf("--") + 1);
    assert.deepEqual(command, ["pi", "--name", "kid-fork"], "the child command is untouched: --fork is kido's to place");
  } finally {
    fx.restore();
  }
});

test("spawn_subagent refuses resume combined with task or name, and refuses no task without resume, before calling kido", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const spawn = s.tools.get("spawn_subagent");

    let result = await spawn.execute("c1", { resume: "run-abc", task: "a new task" });
    assert.match(result.content[0].text, /resume and task cannot both be given/);

    result = await spawn.execute("c2", { resume: "run-abc", name: "kid-1" });
    assert.match(result.content[0].text, /resume and name cannot both be given/);

    result = await spawn.execute("c3", {});
    assert.match(result.content[0].text, /task is required unless resume is given/);

    result = await spawn.execute("c4", { resume: "run-abc", fork: true });
    assert.match(result.content[0].text, /resume and fork cannot both be given/);

    assert.equal(fx.lastSpawnArgs(), undefined, "kido spawn_subagent must not be invoked for any refused combination");
  } finally {
    fx.restore();
  }
});

test("spawn_subagent is refused at the depth ceiling without writing a task file or calling kido", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const saved = process.env.KIDO_AGENT_DEPTH;
    process.env.KIDO_AGENT_DEPTH = "2"; // already a subagent at the ceiling; +1 would be 3
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "t" });
      assert.match(result.content[0].text, /maximum subagent nesting depth/);
      assert.equal(fx.lastSpawnArgs(), undefined, "kido spawn_subagent must not be invoked for a refused depth");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_DEPTH;
      else process.env.KIDO_AGENT_DEPTH = saved;
    }
  } finally {
    fx.restore();
  }
});

// A timeout is reported as a timeout, not folded into a generic failure:
// kido may already have done its work, and a caller that treats the two
// alike can end up cleaning up after something that succeeded.
test("spawn_subagent reports a kido spawn_subagent timeout as a timeout, not a generic failure", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const savedTimeout = process.env.KIDO_SPAWN_TIMEOUT_MS;
    process.env.KIDO_SPAWN_TIMEOUT_MS = "300";
    process.env.KIDO_FAKE_SPAWN_DELAY_MS = "2000"; // longer than the timeout: an in-flight, not a failed, spawn
    try {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const spawn = s.tools.get("spawn_subagent");
      const result = await spawn.execute("c1", { task: "go do the thing", name: "kid-1" });
      assert.match(result.content[0].text, /timed out/);
      assert.ok(fx.lastSpawnArgs(), "kido spawn_subagent was invoked before the timeout fired");
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
      const s = await startSessionUsing(factory, fx);
      assert.ok(
        s.delivered.some((d) => d.text === "do the important thing"),
        "the task reached the model as a user message, the same way an inbox prompt is delivered",
      );
      // Kept, not unlinked: the task file is the run's own permanent
      // record, read back later by `kido runs <run-id>`. A sibling marker,
      // not the file's absence, is what stops a later /reload from
      // delivering it again.
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
      const s = await startSessionUsing(factory, fx);
      assert.equal(s.delivered.filter((d) => d.text === "do the important thing").length, 1);

      // A /reload re-runs session_start with a fresh ctx, but not the
      // factory: the delivered marker, not the module's own state, is what
      // must stop a second delivery.
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

// An unreadable task file must leave no delivered marker, so a later
// /reload gets another try rather than never showing the task at all.
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
      const s = await startSessionUsing(factory, fx);
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
      const s = await startSessionUsing(factory, fx);
      assert.ok(!s.delivered.some((d) => d.text.length > 0), "nothing spurious is delivered when the task file is absent");
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_TASK_FILE;
      else process.env.KIDO_AGENT_TASK_FILE = saved;
    }
  } finally {
    fx.restore();
  }
});

// The startup failure this pair exists for, observed: a child came up
// with pi unable to start its model at all ("No API key found for
// amazon-bedrock" on its pane) and never ran a turn. The idle self-exit
// was armed from turnEnded alone, so a child that never reached a first
// turn armed nothing, never shut itself down, never recorded an outcome
// and told its parent nothing: `kido runs` showed it running
// indefinitely, and to the parent it was indistinguishable from a child
// hard at work. The clock is armed from the task's own delivery instead
// - the moment a child has everything it needs and nothing has begun -
// and the first sign of work clears it exactly as it always did.
//
// The outcome has to say which of the two endings it was, since
// "failed" alone reads as work that went wrong: what is asserted is the
// --text, not merely the failure.
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
        const s = await startWithShutdownSpy(factory, "never-started-run");
        assert.ok(s.delivered.some((d) => d.text === "do the important thing"), "the task was delivered, as it was in the incident");

        // No agent_start, no turn_start, no agent_settled: pi never got
        // as far as a turn.
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
        KIDO_AGENT_PARENT_PID: String(process.pid), // alive: the parent poll must not be what ends this session
        KIDO_PARENT_POLL_MS: "5000",
        KIDO_IDLE_EXIT_SECONDS: "0.05",
        KIDO_LINGER_SECONDS: "0.05",
      },
    );
  } finally {
    fx.restore();
  }
});

// The negative control, and the whole reason the clock is armed from the
// delivery rather than from session start: a child whose task does start
// a turn must be affected in no way at all. It is held for several times
// the idle window with the turn still running, which is what a child
// doing its work looks like, and then ends the ordinary way - completed,
// with no detail claiming it never ran.
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
        const s = await startWithShutdownSpy(factory, "working-run");
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

// Part 1 of the notify_parent refactor (docs/design.md, "Notifying the
// parent"): a settled turn and a plain shutdown must no longer tell the
// parent anything on their own. A subagent that wants that now calls
// notify_parent itself - see its own tests below.
test("a settled turn sends no automatic notice, and neither does a plain shutdown", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
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

// async_bash: kido async_bash is invoked exactly the way spawn_subagent
// invokes its own subcommand - a single -- separating flags from the
// command text, which travels through unchanged regardless of how many
// words it contains, since kido's own commandArgv is what decides bash -c
// vs argv, not this file (docs/design-subagents.md, "An async bash run").
test("async_bash passes -- and the command unchanged, with --name only when given", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx);
    const asyncBash = s.tools.get("async_bash");

    await asyncBash.execute("c1", { command: "true" });
    let args = fx.lastAsyncBashArgs();
    assert.deepEqual(args, ["async_bash", "--", "true"], "a one-word command is passed through unchanged, with no --name");

    await asyncBash.execute("c2", { command: "make -j8 && ./run", name: "build" });
    args = fx.lastAsyncBashArgs();
    assert.deepEqual(
      args,
      ["async_bash", "--name", "build", "--", "make -j8 && ./run"],
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
    assert.deepEqual(fx.lastAsyncBashArgs(), ["async_bash", "--name", "build", "--", "make"], "streaming is off by default");

    await asyncBash.execute("c2", { command: "make", name: "build", stream: true });
    assert.deepEqual(fx.lastAsyncBashArgs(), ["async_bash", "--name", "build", "--stream", "--", "make"]);
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
    assert.equal(result.details.run, "fake-async-run-id", "the run id kido async_bash printed is returned");
    const wantOutput = join(fx.runsDir, "fake-async-run-id", "output");
    assert.equal(result.details.output, wantOutput, "the output path is the fourth field of the line kido printed, not one rebuilt here");
    assert.match(result.content[0].text, /fake-async-run-id/, "the result text names the run");
    assert.match(result.content[0].text, new RegExp(wantOutput.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), "the result text names the output path");
    assert.match(result.content[0].text, /notice/, "the result text says a notice arrives on completion");
    assert.match(result.content[0].text, /read/, "the result text says the output file can be read meanwhile");
    assert.match(
      result.content[0].text,
      /keep working and do not sleep or poll for it/,
      "and says what to do with the turn it just freed, at the moment the model is most tempted to wait",
    );
  } finally {
    fx.restore();
  }
});

// Streaming a run's output: the receiver half. A "stream" envelope is
// buffered on arrival and reaches the model only when flushStreams runs,
// so every case below asserts on pi.sendMessage calls of the stream
// custom type - what the model would actually be handed - never on what
// arrived on the wire.
const streamMessages = (messages: Array<{ message: any }>) =>
  messages.filter((m) => m.message.customType === "kido-stream");

function streamEnvelope(text: string, run = "run-1", output = "/state/runs/run-1/output"): string {
  return JSON.stringify({ v: 1, kind: "stream", id: "env-" + Math.random().toString(36).slice(2), from: { session: "", name: "chatty" }, text, run, output });
}

// withEnv runs fn with vars set, restoring whatever was there. The
// extensions read their knobs once at module scope, so a case that sets
// one has to go through freshExtensions() inside this.
async function withEnv<T>(vars: Record<string, string>, fn: () => Promise<T>): Promise<T> {
  const saved: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    saved[k] = process.env[k];
    process.env[k] = v;
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

// TestStreamBatchRidesAToolTurn. The negative control is the whole test,
// and it is the second half: the same chunks after a turn with no tool
// calls must produce nothing until the idle timer fires. A receiver that
// flushed on every turn_end passes the first half and reintroduces the
// seizure this feature exists to avoid - flushing after a tool-less turn
// buys a turn, that turn has no tool calls either, more lines arrive
// during it, and the loop ends when the command does.
//
// "From inside the turn_end handler" is asserted by when the message
// appears: nothing before the emit, the batch after it. pi awaits
// extension handlers before polling the steering queue, so a batch that
// is there when the emit resolves rides the LLM call the tool turn had
// already committed to.
test("a batch rides a turn that ran tools, and a turn that ran none leaves it held for the idle schedule (TestStreamBatchRidesAToolTurn)", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const factory = await withEnv({ KIDO_STREAM_FLUSH_MS: "120", KIDO_STREAM_FLUSH_CAP_MS: "400" }, () => freshExtensions());
    const s = await startSessionUsing(factory, fx);

    for (const text of ["line 1\nline 2", "line 3", "line 4\nline 5"]) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(text)), "ok");
    }
    assert.equal(streamMessages(s.messages).length, 0, "a chunk on the wire reaches the model on nobody's schedule but flushStreams'");

    await s.emit("turn_end", { turnIndex: 0, toolResults: [{ role: "toolResult" }] });
    const sent = streamMessages(s.messages);
    assert.equal(sent.length, 1, "three chunks during one turn are one message, not three");
    assert.match(sent[0].message.content, /line 1[\s\S]*line 5/, "the one message carries every line that arrived");
    assert.equal((sent[0].opts as any).deliverAs, "steer", "a batch is steered, so the turn already committed to is the one that carries it");

    // The negative control.
    for (const text of ["line 6", "line 7"]) {
      assert.equal(await sendToInbox(s.inboxPath, streamEnvelope(text)), "ok");
    }
    await s.emit("turn_end", { turnIndex: 1, toolResults: [] });
    assert.equal(streamMessages(s.messages).length, 1, "a turn with no tool calls was the agent stopping: flushing there would buy a turn, and another");

    await pollUntil(() => streamMessages(s.messages).length === 2, 2000, "the held batch to be flushed by the idle schedule");
    assert.match(streamMessages(s.messages)[1].message.content, /line 6[\s\S]*line 7/, "the held lines arrive on the idle schedule instead");
  } finally {
    fx.restore();
  }
});

// TestStreamBackoffDoubles, in the two halves the claim has. The schedule
// itself is a pure function and is checked as one, with no clock at all;
// what a clock could only measure badly is then checked as a count of
// flushes over a fixed window, never as elapsed time.
test("the idle flush schedule doubles up to its cap, and the flushes over a window are the few that implies (TestStreamBackoffDoubles)", async () => {
  assert.equal(nextStreamFlushDelay(10000), 20000, "each idle flush costs a turn, so the next one waits twice as long");
  assert.equal(nextStreamFlushDelay(20000), 40000);
  assert.equal(nextStreamFlushDelay(160000), 300000, "the doubling stops at the cap");
  assert.equal(nextStreamFlushDelay(300000), 300000, "and stays there");

  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const factory = await withEnv({ KIDO_STREAM_FLUSH_MS: "40", KIDO_STREAM_FLUSH_CAP_MS: "120" }, () => freshExtensions());
    const s = await startSessionUsing(factory, fx);

    // Output all the way through the window, and never a turn to ride, so
    // every flush in it is one the schedule chose.
    const window = 600;
    const deadline = Date.now() + window;
    let n = 0;
    while (Date.now() < deadline) {
      await sendToInbox(s.inboxPath, streamEnvelope(`line ${++n}`));
      await new Promise((r) => setTimeout(r, 15));
    }
    const flushes = streamMessages(s.messages).length;
    // Unbacked-off, a 40ms floor over this window is ~15 flushes, i.e. ~15
    // turns; doubling to a 120ms cap is ~5.
    assert.ok(flushes >= 2, `only ${flushes} flushes in ${window}ms: a held batch must still get through`);
    assert.ok(flushes <= 8, `${flushes} flushes in ${window}ms: the schedule is not slowing down`);
  } finally {
    fx.restore();
  }
});

// TestBatchTailAndOmittedCount. The cap lives in the receiver, because
// the receiver is what spends the parent's context. Tail, not head, for
// the reason the completion notice carries one: what a failure has to
// say, it says last. The count is checked against the pure function too,
// where "first line" is a fact about the batch rather than about the
// header the flush puts above it.
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

// The ordering rule, on the receiving side: a run's completion notice
// must never reach the model before the output it is the ending of. The
// wrapper sends the last chunk first (cmd/kido/async_run.go); this is the
// other half, where a batch held for want of a free turn is flushed by
// the notice's own arrival rather than left behind it.
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

// Part 2: notify_parent is the only way a subagent tells its parent
// anything now; unlike the automatic notices it replaced, it is sent via
// runKido and awaited, since a deliberate tool call has no reason to race
// this process's own exit the way session_shutdown's notice used to.
//
// It is also where the parent comes from that is pinned here. The agent
// list says this session's parent is "parent-x"; the environment says
// "parent-inst", which is what `kido notify_parent` reads and what the
// notice must therefore be addressed to. The tool used to take the
// former, through a whole `kido list_agents` call - so asserting the
// latter, and that nothing was listed at all, is what tells the two
// implementations apart.
test("notify_parent sends a notice to the parent in its environment, carrying the given summary, without listing agents", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const listedBefore = fx.agentsCallCount();
      const tool = s.tools.get("notify_parent");
      const result = await tool.execute("call-1", { summary: "the answer is 42" });
      assert.ok(result.content[0].text.length > 0, "the tool reports what happened");
      const sent = await fx.waitForLog("parent-inst", "notice");
      assert.equal(sent!.text, "the answer is 42", "the notice carries the summary verbatim");
      assert.equal(fx.lastLogFor("parent-x", "notice"), undefined, "the agent list's idea of the parent is not what was addressed");
      assert.equal(fx.agentsCallCount(), listedBefore, "and no agent list was fetched to find it");
    });
  } finally {
    fx.restore();
  }
});

// A long report survives two separate ways of being thrown away, and
// this pins both: the schema's own maxLength used to reject the call
// outright (a character count against a byte budget - a model given a
// long report had to redo it), and the tool then cut the summary to the
// cap itself, which lost the rest of it for good. The cap is now `kido
// notify_parent`'s alone, and it keeps what it cannot send, so what the
// tool must do with a long summary is pass it on whole - byte for byte,
// which is the assertion with teeth here.
test("notify_parent's schema accepts a summary over the byte cap, and execute() hands the whole of it to kido rather than cutting it", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const tool = s.tools.get("notify_parent");
      const longSummary = "x".repeat(4500);

      assert.ok(
        Value.Check(tool.parameters, { summary: longSummary }),
        "the schema itself no longer rejects a call over 4000 characters - the bound is kido notify_parent's, and it splits rather than rejects",
      );

      const result = await tool.execute("call-1", { summary: longSummary });
      assert.ok(result.content[0].text.length > 0, "the call succeeds rather than failing schema validation");
      const sent = await fx.waitForLog("parent-inst", "notice");
      assert.equal(sent!.text, longSummary, "the whole report reaches kido untouched; where it is split, and what is kept, is the command's own business");
    });
  } finally {
    fx.restore();
  }
});

// set_status's schema had the identical defect (maxLength counting
// characters against a byte-denominated cap the tool's own description
// promises, and rejecting instead of truncating) - kido-status.ts's own
// setActivity has always truncated via capBytes; only the schema was
// wrong.
//
// The activity now leaves via `kido set_status`, the narrow command
// behind the narrow tool, rather than by re-sending the session's whole
// `kido agent-status` report; this reads that call. The report is still
// checked, because the local copy setActivity keeps is what every later
// report carries, and a version that only shelled out would have the
// next report clear the activity it had just set.
test("set_status's schema accepts an activity over the byte cap, setActivity truncates it and sends it as kido set_status", async () => {
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
    // Fire-and-forget through a detached subprocess, so there is nothing
    // to await but the file it eventually writes.
    let call: string[] | undefined;
    await pollUntil(() => (call = last(fx.setStatusCalls())) !== undefined, 2000, "a kido set_status call");
    assert.equal(call![0], "set_status");
    assert.equal(call![1], "--", "the activity is positional, behind --, so one beginning with a dash is still an activity");
    assert.equal(Buffer.byteLength(call![2], "utf8"), 256, "the activity sent is truncated to the byte cap, not rejected");

    // And the same text rides the session's next ordinary report, which
    // is how it survives one: an implementation that only shelled out
    // would have that report carry the stale (empty) activity and undo
    // this call a turn later.
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
    assert.equal(Buffer.byteLength(report![i + 1], "utf8"), 256, "the report carries the same truncated activity");
  } finally {
    fx.restore();
  }
});

test("notify_parent from a session with no parent refuses clearly, and sends nothing", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx); // root session: no KIDO_AGENT_PARENT_INSTANCE
    const tool = s.tools.get("notify_parent");
    const result = await tool.execute("call-1", { summary: "nobody to tell" });
    assert.match(result.content[0].text, /no parent/i, "the refusal names the reason rather than reading as a silent no-op");
    assert.equal(jsonLines(fx.logFile).length, 0, "nothing was sent");
  } finally {
    fx.restore();
  }
});

test("session_shutdown schedules the window linger helper for a subagent", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);

    // sleep(1) accepts fractional seconds on macOS and Linux
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      await s.emit("session_shutdown");
      const args = await fx.waitForCloseRun();
      assert.deepEqual(args, ["close-run", "@7"], "the linger helper closes this session's own window");
    }, { KIDO_LINGER_SECONDS: "0.05" });
  } finally {
    fx.restore();
  }
});

// --unreported rides both results here because neither of these sessions
// ever called notify_parent; which flag is passed is the other test's
// subject ("a child that never called notify_parent...").
test("session_shutdown records this run's own outcome as completed when it ends idle, or failed otherwise", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-completed", async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx, "run-completed");
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
      const s = await startSessionUsing(factory, fx2, "run-failed");
      await s.emit("ui_prompt_start"); // leaves current = "waiting", not idle
      await s.emit("session_shutdown");
      assert.deepEqual(fx2.lastRunOutcomeArgs(), ["run-outcome", "--result", "failed", "--unreported", "--", "run-failed"]);
    });
  } finally {
    fx2.restore();
  }
});

// pi fires session_shutdown on /reload too (reason "reload"), with the
// session carrying straight on in the same process - so an outcome
// written there reports a live run as finished, and since RecordOutcome
// is O_EXCL the run's real ending can never be recorded afterwards.
// Measured against a real pi 0.85.1 subagent: a /reload left the run
// reading "completed" while it was still in kido list_agents, and a later
// kido stop_subagent was silently discarded.
test("a session_shutdown that is a reload or a session replacement records no outcome", async () => {
  for (const reason of ["reload", "new", "resume", "fork"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
      await asSubagent(`run-${reason}`, async () => {
        const factory = await freshExtensions();
        const s = await startSessionUsing(factory, fx, `run-${reason}`);
        await s.emit("session_shutdown", { type: "session_shutdown", reason });
        assert.equal(fx.lastRunOutcomeArgs(), undefined, `a "${reason}" shutdown does not end the run`);
      });
    } finally {
      fx.restore();
    }
  }

  // The negative control: an explicit "quit" still records, so the guard
  // above cannot pass by never recording anything at all.
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-quit", async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx, "run-quit");
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--unreported", "--", "run-quit"]);
    });
  } finally {
    fx.restore();
  }
});

// The parent-side fix for the incident the child-side poll above used to
// carry a debounce for: session_shutdown used to remove this session's
// own record unconditionally, including on a reload, which is what left
// a gap for a child's poll to land in. It matters more now that the poll
// acts on a single reading: this is what keeps the gap from existing. Measured against a real pi 0.85.1
// session_start/session_shutdown pair: a /reload delivers reason "reload"
// and keeps the same session id (session_start's own
// ctx.sessionManager.getSessionId() call returns it unchanged), while
// "new", "resume" and "fork" each hand back a different one in the same
// process - so those three must still remove the old record, or it is a
// live-pid file that nothing ever cleans up, claiming this pane alongside
// the fresh one under the new id.
test("session_shutdown removes the record for every reason except a reload", async () => {
  for (const reason of ["new", "resume", "fork", "quit", undefined]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
      const s = await startSession(fx, `sess-${reason}`);
      await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
      await s.emit("session_shutdown", reason === undefined ? undefined : { type: "session_shutdown", reason });
      await pollUntil(() => fx.statusReportsWithRemove().length >= 1, 2000, `a "${reason}" shutdown to report --remove`);
    } finally {
      fx.restore();
    }
  }

  // The case under test: a reload must not remove the record at all.
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    const s = await startSession(fx, "sess-reload");
    await pollUntil(() => fx.lastStatusArgs() !== undefined, 2000, "the initial idle report");
    await s.emit("session_shutdown", { type: "session_shutdown", reason: "reload" });
    // No event to wait on for a negative outcome - the reload branch
    // returns before ever calling send(), so there is no spawnDetached
    // call in flight to race against. The grace period is only margin
    // against a regression that makes the call asynchronously instead.
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
    const s = await startSession(fx, "root-session");
    await s.emit("session_shutdown");
    assert.equal(fx.lastRunOutcomeArgs(), undefined, "a root session has no run record to write into");
  } finally {
    fx.restore();
  }
});

// The same reason/reload gate that keeps recordOwnOutcome from
// recording a live run as finished must also keep scheduleCompletionLinger
// from scheduling the child's own window to be closed out from under it
// ~30s later. Measured against a real pi 0.85.1 subagent: typing /reload
// in a live subagent left its window closed, plus an orphaned
// `sh -c sleep ...` helper in `ps` on top of the one the real ending
// later spawns.
test("a reload shutdown schedules no linger; a quit does", async () => {
  const reload = makeFixture();
  try {
    reload.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@9" }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, reload);
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

  // Negative control: an actual quit still schedules the linger, so the
  // assertion above cannot pass by disabling it outright.
  const quit = makeFixture();
  try {
    quit.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@9" }]);
    await asSubagent(DEFAULT_SESSION, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, quit);
      await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
      const args = await quit.waitForCloseRun();
      assert.deepEqual(args, ["close-run", "@9"], "a quit still schedules this session's own window to close");
    }, { KIDO_LINGER_SECONDS: "0.05" });
  } finally {
    quit.restore();
  }
});

// A root session (no KIDO_AGENT_PARENT_INSTANCE) must never get its own
// window auto-closed: PARENT_INSTANCE undefined is what sendCompletionNotice
// already reads as "not a subagent", and the linger is scheduled from
// inside that same early return.
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

// The incident this whole identity check exists for. Every KIDO_AGENT_*
// variable is inherited by anything an agent's process starts, so a pi
// run from inside an agent's pane - a human debugging, a tool shelling
// out, a `pi --print` - arrives with a child's entire environment around
// it. Trusting it made that process believe it was the child: it resolved
// "self" by pane and found the REAL agent's record, so its shutdown
// scheduled `kido close-run` on the real agent's window, it armed idle
// self-exit, and notify_parent would have reported to someone else's
// parent. Two live agents were killed this way. What tells the two apart
// is a fact rather than a claim: the real child runs under the run id as
// its pi session id, and a nested pi mints its own.
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
        const s = await startWithShutdownSpy(factory, "a-nested-pis-own-session");

        const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
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

// The negative control for the test above, and the reason it cannot be
// satisfied by simply never behaving as a subagent. Both spawn paths are
// covered because both are what makes the equality true: a fresh spawn
// runs `pi --session-id <run-id>` and a resume `pi --session <run-id>`,
// so either way the child's own session id is the run id (docs/design.md,
// "The run id is the child's session id").
test("a real subagent, fresh or resumed, is still a subagent in every respect", async () => {
  for (const runID of ["fresh-spawn-run", "resumed-run"]) {
    const fx = makeFixture();
    try {
      fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
      await asSubagent(
        runID,
        async () => {
          const factory = await freshExtensions();
          const s = await startWithShutdownSpy(factory, runID);

          const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
          const override = results.find((r: any) => r?.systemPrompt) as { systemPrompt: string } | undefined;
          assert.match(override!.systemPrompt, /notify_parent/, `${runID}: the standing instruction still rides on every turn`);

          const result = await s.tools.get("notify_parent").execute("call-1", { summary: "done" });
          assert.ok(result.content[0].text.length > 0, `${runID}: notify_parent still runs`);
          const sent = await fx.waitForLog("parent-inst", "notice");
          assert.equal(sent!.text, "done", `${runID}: the notice reaches the parent`);

          await s.emit("agent_settled", {}, { isIdle: () => true });
          await pollUntil(() => s.shutdowns() > 0, 2000, `${runID}: idle self-exit still fires`);

          await s.emit("session_shutdown", { type: "session_shutdown", reason: "quit" });
          assert.deepEqual(fx.lastRunOutcomeArgs(), ["run-outcome", "--result", "completed", "--", runID], `${runID}: the outcome is recorded against the run`);
          assert.deepEqual(await fx.waitForCloseRun(), ["close-run", "@7"], `${runID}: its own window is still lingered`);
        },
        {
          KIDO_AGENT_PARENT_PID: String(process.pid), // alive: the poll must not be what ends this session
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

// The decision about the third case, recorded: a session id that is not
// known yet - null until session_start resolves one, and forever in a pi
// outside tmux or with no kido on PATH - reads as "not a subagent", not
// as "probably one". A real child is unaffected (kido-status.ts resolves
// the id inside session_start, before it calls any hook in the agent half
// and long before any turn or tool call), and the states where it stays
// null are exactly the states where a child could not record an outcome,
// close a window or reach a parent anyway. Driven here by taking TMUX_PANE
// away, which is what leaves the id unresolved while the full child
// environment - a matching run id included - is still in place.
test("an unresolved session id is not a subagent, whatever the environment claims", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@7" }]);
    delete process.env.TMUX_PANE; // fx.restore() puts it back
    await asSubagent(
      DEFAULT_SESSION, // would match the session id, had one ever been resolved
      async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);

        const results = await s.emit("before_agent_start", { systemPrompt: "base prompt" });
        assert.ok(results.every((r) => r === undefined), "no standing instruction for a session that may not be a child at all");

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
    // Slower than any fixed wait a caller might have guessed at, so a
    // test synchronising on wall-clock time instead of the real signal
    // (the cycle edge actually being registered) fails deterministically
    // rather than only on a loaded runner. See setAskEdgeListener.
    process.env.KIDO_FAKE_AGENTS_DELAY_MS = "400";
    try {
      const s = await startSession(fx);
      const ask = s.tools.get("ask_agent");

      // ask_agent's own kido ask_agent send is held for 800ms by the fake
      // kido below - this only races at all because runKido shells out via
      // spawn rather than execFileSync; the old blocking call could never
      // let an inbound connection be dispatched before the send finished.
      let edgeRegistered: (() => void) | undefined;
      const registered = new Promise<void>((resolve) => {
        edgeRegistered = resolve;
      });
      setAskEdgeListener((target) => {
        if (target === "peer-a") edgeRegistered?.();
      });
      const p1 = ask.execute("c1", { to: "peer-a", question: "q1" });
      // The real synchronisation point: the cycle edge (pendingOutbound.set
      // in kido-agents.ts) is registered synchronously, in-process, right
      // after the agents-lookup subprocess's await resolves. There is no
      // honest way to observe that moment from outside the process: the
      // lookup child writes its own log line well before the parent's
      // spawn 'close' event fires at the end of its life, so watching for
      // that write is not a reliable proxy for "the edge exists now". A
      // fixed wait guessing at the lookup's duration is what this
      // replaces, and with the lookup slowed above a 120ms guess is
      // routinely too short.
      await registered;
      setAskEdgeListener(undefined);

      // The load-bearing half of this test. "Refused" alone is true
      // whether or not the send is still running: the waiter is not
      // dropped until a reply or a timeout, so a runKido that blocked the
      // event loop for the whole 800ms would finish the send first and
      // still refuse afterwards - verified by making runKido
      // execFileSync-based again, at which point everything below this
      // line still passed. The fake kido appends its log entry in the same
      // breath as its reply, so an absent entry here is the only available
      // evidence that the send really had not finished yet.
      const inFlight = fx.lastLogFor("peer-a", "ask") === undefined;
      const refused = await sendToInbox(s.inboxPath, envelope("ask", "sneaky", { id: "race-1", from: { session: "peer-a" } }));
      assert.ok(inFlight, "the outbound send must still be in flight when the inbound ask is dispatched, or this pins nothing");
      assert.equal(refused, "refused", "the cycle edge is registered before the send resolves, not after");

      const sent = await fx.waitForLog("peer-a", "ask");
      await sendToInbox(s.inboxPath, envelope("reply", "done", { replyTo: sent.id, from: { session: "peer-a" } }));
      const outcome = await p1;
      assert.equal(outcome.content[0].text, "done");
    } finally {
      setAskEdgeListener(undefined);
      delete process.env.KIDO_FAKE_MESSAGE_DELAY_MS;
      delete process.env.KIDO_FAKE_AGENTS_DELAY_MS;
    }
  } finally {
    fx.restore();
  }
});

// deadPid starts and waits for a trivial child process, returning its pid:
// guaranteed to belong to no process by the time the caller uses it. The
// same trick internal/state/state_test.go uses on the Go side.
function deadPid(): number {
  const r = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  return r.pid!;
}

// withParentEnv sets KIDO_AGENT_PARENT_PID/INSTANCE/RUN_ID and a short
// poll interval, restoring whatever was there before on the way out - the
// extensions read all of them once at module scope, so every case below
// goes through freshExtensions() to pick them up. The run id is the
// default session id these cases start with: the parent poll and the idle
// timer belong to the child of that run, not to whatever else inherited
// its environment (kido-agents.ts, ownRunID).
async function withParentEnv<T>(pid: number, instance: string, pollMs: number, fn: () => Promise<T>): Promise<T> {
  const saved = {
    KIDO_AGENT_PARENT_PID: process.env.KIDO_AGENT_PARENT_PID,
    KIDO_AGENT_PARENT_INSTANCE: process.env.KIDO_AGENT_PARENT_INSTANCE,
    KIDO_AGENT_RUN_ID: process.env.KIDO_AGENT_RUN_ID,
    KIDO_PARENT_POLL_MS: process.env.KIDO_PARENT_POLL_MS,
  };
  process.env.KIDO_AGENT_PARENT_PID = String(pid);
  process.env.KIDO_AGENT_PARENT_INSTANCE = instance;
  process.env.KIDO_AGENT_RUN_ID = DEFAULT_SESSION;
  process.env.KIDO_PARENT_POLL_MS = String(pollMs);
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// startWithShutdownSpy is startSessionUsing but with a ctx.shutdown() the
// test can observe - fakeCtx has no such spy, since no other test needs
// one.
async function startWithShutdownSpy(factory: (pi: unknown) => void, sessionId?: string) {
  const { pi, tools, delivered, emit } = createFakePi();
  let shutdowns = 0;
  const ctx = { ...fakeCtx(sessionId), shutdown: () => { shutdowns++; } };
  factory(pi);
  await emit("session_start", {}, ctx);
  return { tools, delivered, emit, shutdowns: () => shutdowns };
}

test("parent-liveness poll: shuts the session down when the parent's process is gone", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(deadPid(), "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a dead parent pid");
      assert.equal(fx.parentAliveCalls().length, 0, "ESRCH is definite, and answered without spawning anything");
      await s.emit("session_shutdown"); // stop the poll, as a real shutdown would
    });
  } finally {
    fx.restore();
  }
});

// Also pins what the poll asks, and of what: `kido agent-alive` naming
// this session's own parent instance, and never `kido list_agents`. The
// command matters as much as the answer - `kido list_agents` is a display,
// scoped to one tmux session and collapsed to one record per pane, and
// reading a liveness fact out of it is the defect this replaced
// (docs/design.md, "Identity").
test("parent-liveness poll: does not shut down while the parent is alive, and asks agent-alive about its own parent instance", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("alive");
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      const agentsBefore = fx.agentsCallCount();
      // Long enough for several poll ticks at 20ms; still short by test
      // standards, and this is what proves the poll ran and chose not to
      // shut down, not merely that it hadn't fired yet.
      await pollUntil(() => fx.parentAliveCalls().length >= 3, 2000, "several agent-alive polls");
      assert.equal(s.shutdowns(), 0, "a live, correctly-matched parent must never trigger a shutdown");
      assert.deepEqual(
        fx.parentAliveCalls()[0],
        ["agent-alive", "parent-inst"],
        "the poll asks about its own parent instance, by instance and nothing else",
      );
      assert.equal(
        fx.agentsCallCount(),
        agentsBefore,
        "and never through kido list_agents, whose per-pane view can lose the parent's record",
      );
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// The one reading that is still not evidence. Everything else the poll
// can see is now trustworthy on a single look, which is why there is no
// debounce left to absorb anything - but a kido that cannot answer has
// said nothing about the parent, and a child must never end itself on
// that.
test("parent-liveness poll: a kido that cannot answer is not evidence, and never ends the child", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("fail");
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => fx.parentAliveCalls().length >= 4, 2000, "several failed agent-alive polls");
      assert.equal(s.shutdowns(), 0, "a failing query says nothing; it must not be read as a dead parent");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// The other direction, and the one that must not be defanged: an orphan
// outliving its parent forever is worse than a child that exits early.
// kill(pid, 0) succeeds here - this process's own pid is certainly alive
// - but no live record reports the parent instance, exactly as if the
// real parent exited and something else now holds its old pid.
// state.Alive (internal/state) reports EPERM as alive for the same reason
// a pid alone is not proof here (see AGENTS.md).
//
// The timing assertion is what pins the absence of the debounce: one
// "false" reading ends the session, so shutdown lands within about one
// poll interval rather than the two the old missedParentPolls counter
// required. Two intervals of slack keeps it honest on a loaded machine
// while still failing if a counter ever comes back.
test("parent-liveness poll: a recycled pid with a different instance counts as gone, on the first reading", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true, window: "@1" }]);
    fx.setParentAlive("gone");
    await withParentEnv(process.pid, "parent-inst", 20, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() to be called for a recycled pid with no matching instance");
      assert.equal(fx.parentAliveCalls().length, 1, "one reading is conclusive; nothing waits for a second");
      await s.emit("session_shutdown");
    });
  } finally {
    fx.restore();
  }
});

// pollInFlight, on what is left of its merits. It was written to stop
// overlapping ticks each incrementing the debounce counter and reaching
// its threshold off one slow gap; with the counter gone, overlapping
// readings corrupt no verdict, since each is independently trustworthy.
// What it still prevents is a pile-up: setInterval fires on schedule
// whether or not the previous callback's async work has finished, so a
// reading slower than the interval would have every tick spawn another
// process on top of those already waiting. A slow fake kido
// (KIDO_FAKE_PARENT_ALIVE_DELAY_MS well over the poll interval) makes
// that visible - unguarded, the calls track the interval; guarded, they
// can only track the round trip.
test("parent-liveness poll: a slow reply does not let ticks pile up concurrent readings", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    const delayMs = 100;
    const pollMs = 10;
    fx.setParentAlive("alive");
    fx.setParentAliveDelay(delayMs);
    await withParentEnv(process.pid, "parent-inst", pollMs, async () => {
      const factory = await freshExtensions();
      const s = await startWithShutdownSpy(factory);
      // A fixed window rather than a poll on the call count: the thing
      // being measured is how many readings a span of time produces, and
      // stopping at the first few would stop before the pile-up the
      // unguarded version builds is distinguishable from the handful of
      // sequential calls the guarded one makes.
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
  const saved = process.env.KIDO_HEARTBEAT_MS;
  process.env.KIDO_HEARTBEAT_MS = String(ms);
  try {
    return await fn();
  } finally {
    if (saved === undefined) delete process.env.KIDO_HEARTBEAT_MS;
    else process.env.KIDO_HEARTBEAT_MS = saved;
  }
}

test("a running session re-sends its status on a heartbeat, bypassing the coalescing key that would otherwise drop a repeat", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "", self: true, canMessage: true }]);
    await withHeartbeatEnv(20, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      // turn_start, tool_execution_start and tool_call all send the same
      // "running" key: without the heartbeat bypass this is exactly the
      // sequence send()'s coalescing collapses to a single report.
      await s.emit("turn_start");
      await s.emit("tool_execution_start");
      await s.emit("tool_call");
      await pollUntil(() => fx.statusReportsWith("running").length >= 1, 2000, "the first running report");
      assert.equal(fx.statusReportsWith("running").length, 1, "coalescing must still drop the identical follow-ups");

      await pollUntil(() => fx.statusReportsWith("running").length >= 2, 2000, "a heartbeat re-report past KIDO_HEARTBEAT_MS");
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
      const s = await startSessionUsing(factory, fx);
      await s.emit("turn_start");
      // Wait for the heartbeat to have actually fired at least once, not
      // merely the first (turn_start's own) report - otherwise stopping it
      // immediately would prove nothing.
      await pollUntil(() => fx.statusReportsWith("running").length >= 2, 2000, "a heartbeat re-report");
      await s.emit("agent_settled", {}, { isIdle: () => true }); // the true idle signal; see the handler in kido-status.ts
      // Each spawnDetached call already made before the stop still lands in
      // the log asynchronously, so the count can keep growing briefly after
      // this point regardless - a fixed "sleep, then sleep again" window is
      // exactly what a loaded CI runner can beat, by letting a late arrival
      // land in the second window rather than the first. Poll for a window
      // with NO growth at all instead: a stopped heartbeat produces one, an
      // unstopped 15ms one never does, which a fixed pair of samples cannot
      // tell apart from "stopped, but slow to drain". The count is every
      // report regardless of status, not just "running": send() flips
      // `current` to "idle" before stopHeartbeat() runs, so a heartbeat
      // that failed to stop would keep resending "idle" (its opts.heartbeat
      // flag bypasses the coalescing that would otherwise drop an identical
      // repeat) - a check scoped to "running" would not see that at all.
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

// startWithControlSpies is startSession but with ctx.abort()/ctx.shutdown()
// spies the tests below observe - what an inbound "interrupt"/"stop"
// envelope (handleInboundControl) actually calls.
async function startWithControlSpies(fx: Fixture) {
  const { pi, tools, delivered, emit } = createFakePi();
  let aborts = 0;
  let shutdowns = 0;
  const ctx = { ...fakeCtx(), abort: () => { aborts++; }, shutdown: () => { shutdowns++; } };
  loadExtensions(pi);
  await emit("session_start", {}, ctx);
  return { tools, delivered, emit, inboxPath: fx.selfInboxPath(), aborts: () => aborts, shutdowns: () => shutdowns };
}

// controlTree is a self whose parent is "root-1", the shape
// handleInboundControl's ancestor check needs: isAncestor walks self's own
// parent chain looking for the envelope's sender.
const controlTree = [
  { id: "self", name: "self", parent: "root-1", pane: "%1", self: true, canMessage: true },
  { id: "root-1", name: "root-1", parent: "", pane: "%2", self: false, canMessage: true },
  { id: "peer-x", name: "peer-x", parent: "", pane: "%3", self: false, canMessage: true },
];

// TestIsAncestorRefusesSelfEdge's TS twin: without the explicit refusal
// at the top of isAncestor, a record whose own "parent" named itself
// would make isAncestor(agents, X, X) true, and handleInboundControl's
// ancestor check would let a session act on a "stop" or "interrupt" that
// claimed to be from itself. Nothing writes such a record today (see the
// function's own doc); this pins the belt-and-braces refusal anyway.
test("isAncestor refuses a self-edge, even with a corrupted self-parent record", () => {
  const self = { id: "x", name: "x", parent: "x", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self], self, self), false);
});

// isAncestor's `seen` set is what stands between a corrupted parent chain
// and a hang: internal/tree's own cycle safety (AGENTS.md) has a Go twin,
// but nothing here pinned the TS walk directly. Without `seen`, a genuine
// cycle among records none of which is self would loop forever instead of
// eventually returning false.
test("isAncestor terminates on a parent cycle that never reaches self", () => {
  const a = { id: "a", name: "a", parent: "b", pane: "%1", self: false, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const b = { id: "b", name: "b", parent: "a", pane: "%2", self: false, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%3", self: true, canMessage: true, window: "@3", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, a, b], self, a), false);
  assert.equal(isAncestor([self, a, b], self, b), false);
});

// A dangling parent id - one that names no agent in the list at all, the
// shape a race between a spawn and an exit can leave behind - must end
// the walk rather than loop on `cur` never changing.
test("isAncestor terminates when a parent names nobody in the list", () => {
  const orphan = { id: "orphan", name: "orphan", parent: "ghost-parent", pane: "%1", self: false, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const self = { id: "self", name: "self", parent: "", pane: "%2", self: true, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  assert.equal(isAncestor([self, orphan], self, orphan), false);
});

// isAncestor must also find self two levels up, not merely the immediate
// parent - the shape a grandparent's `kido interrupt_subagent grandchild` relies
// on.
test("isAncestor finds a two-level ancestor", () => {
  const grand = { id: "grand", name: "grand", parent: "", pane: "%1", self: true, canMessage: true, window: "@1", stalled: false, sinceReport: 0 };
  const mid = { id: "mid", name: "mid", parent: "grand", pane: "%2", self: false, canMessage: true, window: "@2", stalled: false, sinceReport: 0 };
  const child = { id: "child", name: "child", parent: "mid", pane: "%3", self: false, canMessage: true, window: "@3", stalled: false, sinceReport: 0 };
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

// A control envelope naming a session id that is not in kido's agents
// list at all - not a peer, not a descendant, just unknown - must be
// refused the same way a peer is. isAncestor's `byId.get(cur)?.parent`
// already tolerates a missing sender, but handleInboundControl's own
// `listed.agents.find((a) => a.id === env.from.session)` lookup is a
// second, independent place this could be gotten wrong: nothing stops a
// forged envelope from naming an id that never existed.
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

// An interrupt leaves the session alive and able to take a following
// message, which is more than "shutdown was not
// called" - the inbox itself must still be answering. And an interrupt of
// an idle agent (the shape here: session_start with no turn begun) must
// be harmless, not refused or treated specially just because there was
// nothing to abort.
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
    assert.ok(s.delivered.some((d) => d.text === "still there?"), "the session must still accept a message after an interrupt");
  } finally {
    fx.restore();
  }
});

// A person running `kido interrupt_subagent`/`kido stop_subagent` by hand has no state
// record, so kido has no session id to put in the envelope's `from` - and
// the scope rule deliberately lets that caller reach anything
// (cmd/kido/control.go's isAgent check). Matching only on `from.session`
// would refuse them here, so the two enforcement layers would disagree
// and a human's stop could not stop anything. Recognised by the
// empty session *and* a pane no agent occupies, so an agent that simply
// omits its session id is still held to the descendant rule.
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

// askTree is grand -> mid -> child, three levels, used below to pin
// ask_agent's ancestor guard in both directions: which of self/target is
// the caller decides which one gets marked self:true per case.
const askTree = [
  { id: "grand", name: "grand", parent: "", self: false, canMessage: true },
  { id: "mid", name: "mid", parent: "grand", self: false, canMessage: true },
  { id: "child", name: "child", parent: "mid", self: false, canMessage: true },
];

// isAncestor(agents, self, target) means "self is an ancestor of target"
// (see its own doc above); ask_agent's guard must refuse a child asking
// upward, not a parent asking downward. The inverted check refused the
// ordinary case and let the dangerous one through - a subagent could
// block its own parent for the full ask timeout, exactly the deadlock
// docs/design.md's cycle-edge section exists to prevent - so each case
// below checks not just the refusal text but that nothing was actually
// sent (or was), off the fake kido's own log.
// steer_subagent's own end-to-end pair. The tool shells out like every
// other one; what is worth pinning here is the argument shape, since a
// model-authored `to` beginning with a dash would otherwise be read as a
// kido flag.
test("steer_subagent runs kido steer_subagent with the target behind -- and the message on stdin", async () => {
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

// The mode is the whole point of the kind, so this asserts the mode and
// not merely that something arrived: a steer delivered as "followUp"
// would be drained only after the agent had decided to stop, which is
// exactly the wait steering exists to skip (docs/design.md, "Steer and
// followUp").
//
// The second half is the negative control, and it is the reason this test
// is one test: a later simplification that unified the delivery paths
// would keep every assertion about arrival true. An ask must stay
// followUp in particular - it carries a reply-correlation id, so two asks
// interleaved inside one turn risk an answer reaching the wrong asker.
test("an inbound steer is delivered as steer; a message and an ask stay followUp", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents(controlTree);
    const s = await startWithControlSpies(fx);
    const from = { session: "root-1", name: "root-1", pane: "%2" };

    assert.equal(await sendToInbox(s.inboxPath, envelope("steer", "drop that, do X", { from })), "ok");
    const steered = s.delivered.find((d) => d.text.includes("drop that, do X"));
    assert.ok(steered, "the steer reached the model");
    assert.equal((steered!.opts as any).deliverAs, "steer", "a steer joins the running turn rather than queueing behind it");
    assert.match(steered!.text, /root-1/, "and says who is redirecting the work, arriving mid-task as it does");

    assert.equal(await sendToInbox(s.inboxPath, envelope("message", "when you get a moment", { from })), "ok");
    const queued = s.delivered.find((d) => d.text.includes("when you get a moment"));
    assert.ok(queued, "the message reached the model");
    assert.equal((queued!.opts as any).deliverAs, "followUp", "a plain message still waits for the current turn to end");

    assert.equal(await sendToInbox(s.inboxPath, envelope("ask", "are you done?", { from })), "ok");
    const asked = s.delivered.find((d) => d.text.includes("are you done?"));
    assert.ok(asked, "the ask reached the model");
    assert.equal((asked!.opts as any).deliverAs, "followUp", "an ask must never steer: a correlated reply has to be answered one at a time");
  } finally {
    fx.restore();
  }
});

// Same sender rule as interrupt and stop, checked on arrival because
// `from` is advisory - and refused on the wire, so the sender hears about
// it rather than the text landing silently.
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
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, stalled: true, sinceReport: 245 },
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

// A target that died seconds ago is not stalled - that takes minutes of
// silence - so target.stalled alone lets ask_agent commit to the full
// timeoutMs against a target that will never answer. The timeoutMs of
// 600000 against settlesWithin(..., 500) is the point: a version missing
// the liveness check would still answer correctly, only 600000ms later.
test("ask_agent refuses a target that is not alive, promptly and without sending anything", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, instance: "peer-a-instance" },
    ]);
    fx.setParentAlive("gone");
    const s = await startSession(fx);
    const ask = s.tools.get("ask_agent");

    const result = await settlesWithin(ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }), 500);
    assert.match(result.content[0].text, /no longer running/);
    assert.equal(fx.lastLogFor("peer-a", "ask"), undefined, "a dead target must never actually be asked");
    assert.ok(
      fx.parentAliveCalls().some((args) => args.includes("peer-a-instance")),
      "the resolved target's own instance id was queried, not its session id",
    );
  } finally {
    fx.restore();
  }
});

// canReply is a run record's fact, not canMessage's: a target with an
// inbox but no message_agent tool has somewhere to send a reply, and
// still cannot send one. Checked before any send, the same shape as the
// stalled and not-alive prechecks above.
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
  const saved = process.env.KIDO_ASK_POLL_MS;
  process.env.KIDO_ASK_POLL_MS = String(pollMs);
  try {
    return await fn();
  } finally {
    if (saved === undefined) delete process.env.KIDO_ASK_POLL_MS;
    else process.env.KIDO_ASK_POLL_MS = saved;
  }
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
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, instance: "peer-a-instance" },
    ]);
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const ask = s.tools.get("ask_agent");

      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 });
      // The target was alive at the precheck: the ask really went out.
      const sent = await fx.waitForLog("peer-a", "ask");
      assert.equal(await pendingState(p), "pending", "a live target is still being waited for");

      fx.killInstance("peer-a-instance");
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

    // The waiter is gone, not merely unawaited: a reply naming that id now
    // arrives the way any unmatched reply does, as a message to the model.
    const resp = await sendToInbox(s.inboxPath, envelope("reply", "late answer", { replyTo: sent!.id, from: { session: "peer-a", name: "peer-a" } }));
    assert.equal(resp, "ok");
    assert.ok(
      s.delivered.some((d) => d.text.includes("late answer")),
      "an abandoned ask leaves no waiter behind for a later reply to settle",
    );
  } finally {
    fx.restore();
  }
});

// The abort can also land while the outbound send is still in flight,
// which is the one ordering where the wait is over before the liveness
// watch is armed. An interval started after its own settle is one
// nothing will ever clear: the readings simply never stop.
test("an ask aborted while its send is in flight leaves no liveness watch running", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, instance: "peer-a-instance" },
    ]);
    process.env.KIDO_FAKE_MESSAGE_DELAY_MS = "400";
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const ask = s.tools.get("ask_agent");

      const ac = new AbortController();
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
      await new Promise((r) => setTimeout(r, 100)); // still inside the send
      ac.abort();
      // Not instant, unlike the case above: execute cannot return before
      // the send it is awaiting does, and that await is capped at 5s by
      // runKido's own timeoutMs - a real subprocess spawn, not a mock -
      // so the bound here has to clear 5s with room for a loaded runner's
      // scheduling on top, not merely clear the 400ms delay this send is
      // given in the fast case.
      const result = await settlesWithin(p, 9000);
      assert.match(result.content[0].text, /interrupted/);

      const readings = () => fx.parentAliveCalls().filter((args) => args.includes("peer-a-instance")).length;
      await pollForStable(readings, 400, 6000, "the liveness readings for an abandoned ask to stop");
    });
  } finally {
    fx.restore();
  }
});

// The negative control for both of the above, and the more important half
// of the pair: giving up on a healthy target that is merely slow would be
// worse than the hang. The wait outlives many liveness readings and an
// abort signal that is never fired, and still ends with the target's own
// answer.
test("a live target that takes its time is still waited for, and its reply is what arrives", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([
      { id: "self", name: "self", parent: "", self: true, canMessage: true },
      { id: "peer-a", name: "peer-a", parent: "", self: false, canMessage: true, instance: "peer-a-instance" },
    ]);
    await withAskPollEnv(50, async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx);
      const ask = s.tools.get("ask_agent");

      const ac = new AbortController();
      const p = ask.execute("c1", { to: "peer-a", question: "q", timeoutMs: 600000 }, ac.signal);
      const sent = await fx.waitForLog("peer-a", "ask");

      const readings = () => fx.parentAliveCalls().filter((args) => args.includes("peer-a-instance")).length;
      // Polled for, not slept for a fixed distance: each reading is a real
      // subprocess round trip, so a run-to-run-constant sleep either wastes
      // time on a fast machine or comes up short of 3 on a loaded one -
      // which is exactly how this test was flaky on CI.
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

// withIdleExitEnv sets KIDO_IDLE_EXIT_SECONDS and, optionally,
// KIDO_AGENT_KEEP_ALIVE, restoring whatever was there before - both are
// read once at module scope, so every case below goes through
// freshExtensions() to pick them up (see withParentEnv).
async function withIdleExitEnv<T>(seconds: number, keepAlive: boolean, fn: () => Promise<T>): Promise<T> {
  const saved = {
    KIDO_IDLE_EXIT_SECONDS: process.env.KIDO_IDLE_EXIT_SECONDS,
    KIDO_AGENT_KEEP_ALIVE: process.env.KIDO_AGENT_KEEP_ALIVE,
  };
  process.env.KIDO_IDLE_EXIT_SECONDS = String(seconds);
  if (keepAlive) process.env.KIDO_AGENT_KEEP_ALIVE = "1";
  else delete process.env.KIDO_AGENT_KEEP_ALIVE;
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("idle self-exit: a settled turn with no further work shuts the session down after the configured idle interval, measured", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.1, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
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
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.15, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
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
    const saved = process.env.KIDO_AGENT_PARENT_INSTANCE;
    delete process.env.KIDO_AGENT_PARENT_INSTANCE;
    try {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        await new Promise((r) => setTimeout(r, 300)); // several times the configured interval
        assert.equal(s.shutdowns(), 0, "a root session must never self-reap");
      });
    } finally {
      if (saved === undefined) delete process.env.KIDO_AGENT_PARENT_INSTANCE;
      else process.env.KIDO_AGENT_PARENT_INSTANCE = saved;
    }
  } finally {
    fx.restore();
  }
});

test("idle self-exit: keepAlive opts a child out entirely", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.05, true, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
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
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        // Each re-arm check costs a fake-kido subprocess start (tens of ms),
        // so the wait has to be generous relative to the 50ms interval to
        // actually observe more than one of them.
        await new Promise((r) => setTimeout(r, 600));
        assert.equal(s.shutdowns(), 0, "a focused window must not be closed out from under the user");
        assert.ok(
          fx.windowFocusedCallCount() >= 2,
          `window-focused was checked ${fx.windowFocusedCallCount()} times, want re-arming to have checked more than once`,
        );

        fx.setWindowFocused(false);
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once the window is no longer focused");
      });
    });
  } finally {
    fx.restore();
  }
});

// idle self-exit and live children. The incident: a parent spawned a
// child, said "I'll wait for its report", and settled the turn - which
// is exactly what a finished session looks like. Thirty seconds later it
// exited, and the orphan rule closed the child's window mid-work. The
// clock now asks kido whether any run of this session's own is still
// going, and a session with one is not idle however long it has been
// quiet.
test("idle self-exit: a live child run re-arms the clock, and the session exits once that child has ended", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    fx.setChildrenAlive(true);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        const s = await startWithShutdownSpy(factory);
        await s.emit("agent_settled", {}, { isIdle: () => true });
        // Generous relative to the 50ms interval, since each re-arm costs
        // a fake-kido subprocess start: the point is to observe several.
        await new Promise((r) => setTimeout(r, 600));
        assert.equal(s.shutdowns(), 0, "a session waiting on a child it spawned is not idle");
        assert.ok(
          fx.childrenAliveCalls().length >= 2,
          `children-alive was asked ${fx.childrenAliveCalls().length} times, want re-arming to have asked more than once`,
        );

        // The negative control, and the half that keeps idle self-exit
        // working at all: the last child ends and the clock resumes.
        fx.setChildrenAlive(false);
        await pollUntil(() => s.shutdowns() > 0, 2000, "ctx.shutdown() once the child has ended");
      });
    });
  } finally {
    fx.restore();
  }
});

// pi's interactive-mode shutdown handler only acts on a shutdown request
// once it is not mid-compaction (isIdle), and only re-checks that flag on
// its own next agent_settled - so a shutdown requested while a compaction
// is in flight can be recorded and never acted on. The clock must not
// take ctx.shutdown() at its word: it re-arms after calling it, so a
// declined request is asked for again rather than left as the one attempt
// a child ever gets.
test("idle self-exit: a shutdown pi declined is asked for again", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true, window: "@1" }]);
    await withParentEnv(process.pid, "parent-inst", 5000, async () => {
      await withIdleExitEnv(0.05, false, async () => {
        const factory = await freshExtensions();
        // A shutdown pi declines because it is compacting still returns
        // from ctx.shutdown() - pi just does not end the session. Mirror
        // the real sequence around the first firing without it changing
        // anything: kido-agents.ts does not listen for either event.
        const s = await startWithShutdownSpy(factory);
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

// A child that ends without ever calling notify_parent owes its parent
// one notice saying so - the ending was silent, and a parent that
// dispatched work learnt nothing from a child that idled out. The flag
// is what kido reads; the outcome write decides whether it is acted on.
test("a child that never called notify_parent flags its silence as it ends, and one that did does not", async () => {
  const fx = makeFixture();
  try {
    fx.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-silent", async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx, "run-silent");
      await s.emit("session_shutdown");
      assert.deepEqual(fx.lastRunOutcomeArgs(), [
        "run-outcome", "--result", "completed", "--unreported", "--", "run-silent",
      ], "a silent child asks kido to speak for it");
    });
  } finally {
    fx.restore();
  }

  // The negative control: a child that reported has already said what it
  // had to say, and a second notice on the way out is the parent hearing
  // about one run twice. Nothing differs here but the tool call.
  const fx2 = makeFixture();
  try {
    fx2.setAgents([{ id: "self", name: "self", parent: "parent-x", self: true, canMessage: true }]);
    await asSubagent("run-spoke", async () => {
      const factory = await freshExtensions();
      const s = await startSessionUsing(factory, fx2, "run-spoke");
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
