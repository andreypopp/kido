import {
  AgentSession,
  SessionManager,
  parseSessionEntries,
  type BashOperations,
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  type ExtensionAPI,
  type ExtensionContext,
  type ExtensionToolContext,
  type FindOperations,
  type GrepToolDetails,
  type GrepToolInput,
  type LsOperations,
  type MessageRenderer,
  type ReadOperations,
  type Theme,
  type ToolDefinition,
  type WriteOperations,
  createBashToolDefinition,
  createEditTool,
  createEditToolDefinition,
  createFindTool,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsTool,
  createLsToolDefinition,
  createReadTool,
  createReadToolDefinition,
  createWriteTool,
  createWriteToolDefinition,
  formatSize,
  getAgentDir,
  getShellConfig,
  rawKeyHint,
  truncateHead,
  truncateTail,
  truncateLine,
} from "@earendil-works/pi-coding-agent";
import { Key, matchesKey, type AutocompleteProvider, type TuiMouseEvent, truncateToWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { type WriteStream, accessSync, constants, createWriteStream, mkdirSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import os from "node:os";
import { setCompletionContext } from "./completion-context.ts";
import { runtimeExec, lineReader, openStream, type ExecOptions, type ExecResult } from "./runtime-exec.ts";
import { contentText, mintId, utf8Prefix, utf8Suffix, errorText, replaceControlCharacters, isRecord, isString, str } from "./text.ts";
import { dirname, delimiter, extname, join, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import type { components } from "./ko-api.d.ts";
import { atToken } from "./token.ts";
import { isRelation, isAgentFailure, jobEndText, type Relation, type AgentRef, type AgentOutcome, type MessageDetails, type SteerDetails, type NoticeDetails, type StreamDetails, type JobRef, type JobEnd } from "./records.ts";
import { parsePanes, placesOf, piAgent, peerPanes, ancestorsOf, runningRows, agentCache, MIN_ID_PREFIX, VAR_SESSION, VAR_NAME, VAR_ACTIVITY, VAR_TASK, VAR_RUNTIME, type PaneInfo, type AgentCompletionRow } from "./agents.ts";

type Api = components["schemas"];

const KO_TIMEOUT_MS = 5000;
const PEER_RESULT_RULE = "independent peer; no report or ending notice";
const reconnectBackoff = (previous: number): number => Math.min(previous ? previous * 2 : envMs("KO_RECEIVER_BACKOFF_MS", 200), 5000);

const VAR_KO_RUNTIME = "ko.runtime";
const VAR_KEYS = [VAR_SESSION, VAR_NAME, VAR_ACTIVITY];

const ENTRY_AGENT = "ko-pi.agent";
const ENTRY_WORK = "ko-pi.work";
const ENTRY_REPORT = "ko-pi.report";
const ENTRY_ENDED = "ko-pi.ended";
const ENTRY_SENT = "ko-pi.sent";

type SendKind = Api["SendKind"];
type Dead = Api["Dead"];

type RunResult = { ok: true; out: string; raw: string } | { ok: false; error: string; code?: number; out: string; err: string };

function findKo(): string | null {
  const path = process.env.PATH;
  if (!path) return null;
  for (const dir of path.split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, "ko");
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {}
  }
  return null;
}

async function runCommand(command: string, args: string[], opts: { timeoutMs: number; env?: NodeJS.ProcessEnv; input?: string } = { timeoutMs: KO_TIMEOUT_MS }): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: [opts.input === undefined ? "ignore" : "pipe", "pipe", "pipe"], env: opts.env ?? process.env });
    if (opts.input !== undefined) {
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input);
    }
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const finish = (result: RunResult): void => {
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish({ ok: false, error: `${command} timed out after ${opts.timeoutMs}ms`, out: "", err: "" });
    }, opts.timeoutMs);
    timer.unref();
    child.stdout?.on("data", (c: Buffer) => stdout.push(c));
    child.stderr?.on("data", (c: Buffer) => stderr.push(c));
    child.on("error", (err) => finish({ ok: false, error: errorText(err), out: "", err: "" }));
    child.on("close", (code) => {
      const out = Buffer.concat(stdout).toString("utf8");
      const err = Buffer.concat(stderr).toString("utf8");
      if (code === 0) finish({ ok: true, out: out.trim(), raw: out });
      else finish({ ok: false, error: err.trim() || `${command} exited with code ${code}`, ...(code === null ? {} : { code }), out, err });
    });
  });
}

type Reply = { status: number; body: string } | { error: string };

const apiArgs = (method: string, path: string, body: unknown): string[] => [
  "api",
  ...(method === "GET" ? [] : ["-X", method]),
  ...(body === undefined ? [] : ["--input", "-"]),
  path,
];

async function apiCall(method: string, path: string, body?: unknown, timeoutMs = KO_TIMEOUT_MS): Promise<Reply> {
  const res = await runCommand("ko", apiArgs(method, path, body), { timeoutMs, input: body === undefined ? undefined : JSON.stringify(body) });
  if (res.ok) return { status: 200, body: res.raw };
  const status = /ko api: HTTP (\d+)/.exec(res.err)?.[1];
  return status ? { status: Number(status), body: res.out.trim() } : { error: res.error };
}

const apiCallSync = (method: string, path: string, body: unknown): void => {
  spawnSync("ko", apiArgs(method, path, body), { timeout: 1000, input: JSON.stringify(body), stdio: ["pipe", "ignore", "ignore"] });
};

const apiBody = (reply: Reply): string | undefined => ("error" in reply || reply.status !== 200 ? undefined : reply.body);

const apiJson = (reply: Reply): unknown => {
  const body = apiBody(reply);
  if (body === undefined) return undefined;
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
};

// The server's error body: its kind and message; a transport failure has the kind io.
const apiError = (reply: Reply): { kind: Api["Error"]["kind"]; message: string } => {
  if ("error" in reply) return { kind: "io", message: reply.error };
  try {
    const failure: unknown = JSON.parse(reply.body);
    if (isRecord(failure) && typeof failure.message === "string" && isErrorKind(failure.kind)) return { kind: failure.kind, message: failure.message };
  } catch {}
  return { kind: "io", message: `HTTP ${reply.status}` };
};

function isRuntimeInfo(value: unknown): value is Api["RuntimeInfo"] {
  return isRecord(value) && typeof value.name === "string" && Array.isArray(value.paths) && (value.pi === "host" || value.pi === "runtime") && isRecord(value.state);
}

async function fetchRuntime(name: string): Promise<Api["RuntimeInfo"] | { error: string }> {
  const answer = await apiCall("GET", `/runtimes/${name}`);
  const info = apiJson(answer);
  return isRuntimeInfo(info) ? info : { error: apiError(answer).message };
}

const ERROR_KINDS = ["invalid", "refused", "gone", "io", "precondition_failed", "not_found", "protocol_mismatch", "vt_mismatch"];

function isErrorKind(value: unknown): value is Api["Error"]["kind"] {
  return typeof value === "string" && ERROR_KINDS.includes(value);
}

async function listPanesResult(timeoutMs = KO_TIMEOUT_MS): Promise<{ ok: boolean; panes: PaneInfo[] }> {
  const body = apiBody(await apiCall("GET", "/layout", undefined, timeoutMs));
  if (body === undefined) return { ok: false, panes: [] };
  try {
    const layout: Api["LayoutPanes"] = JSON.parse(body);
    return { ok: true, panes: parsePanes(layout) };
  } catch {
    return { ok: false, panes: [] };
  }
}

const SIGNALS: Record<number, string> = { 1: "HUP", 2: "INT", 3: "QUIT", 6: "ABRT", 9: "KILL", 11: "SEGV", 13: "PIPE", 14: "ALRM", 15: "TERM" };

const causeText = (dead: Dead): string => {
  const cause = dead.cause;
  if (cause.type === "exited") return `exit ${cause.code}`;
  if (cause.type === "signaled") return `signal ${SIGNALS[cause.signal] ?? cause.signal}`;
  return `failed: ${cause.message}`;
};

const NOTICE_CUSTOM_TYPE = "ko-notice";

export const noticeHeader = (from: string): string => `notice from ${from} (a subagent or background job's report, not the user):`;

const MESSAGE_CUSTOM_TYPE = "ko-message";

const STEER_CUSTOM_TYPE = "ko-steer";

export const RELATION_TEXT: Record<Relation, string> = {
  parent: "your parent, who spawned you",
  child: "your subagent",
  sibling: "another agent in this session, not the user",
  descendant: "a subagent of your subagent",
  sibling_descendant: "a subagent of another agent in this session",
};

export const senderHeader = (from: string, relation: Relation, runtime?: string): string =>
  `message from @${from} (${RELATION_TEXT[relation]}${runtime ? `, in runtime ${runtime}` : ""}):`;

const steerHeader = (from: string): string => `${from} is redirecting this work: `;

const inboundHeader = (sender: string | undefined, verb: string | undefined): string =>
  `${sender && sender !== "another agent" ? `@${sender}` : "another agent"}${verb ? ` ${verb}` : ""}:`;

const MAX_NOTICE_BYTES = 4000;
const MAX_JOB_TITLE_BYTES = 192;
const MAX_JOB_MESSAGE_BYTES = 2048;

const MAX_REPORT_BYTES = 1000;

const MAX_TASK_BYTES = 1044480;

const MAX_MESSAGE_BYTES = 1000000;

const MAX_DEPTH = 2;

// How long a stop waits for the pane to end by itself, and the cap of the whole call: that wait, the
// server's escalation and a margin.
const STOP_WAIT_MS = 5000;

const STOP_CALL_MS = STOP_WAIT_MS + 5000 + 1500;

const RECEIVED_RING = 4096;

const RESEND_TRIES = 3;

const STREAM_CUSTOM_TYPE = "ko-stream";

export const PARENT_GUIDANCE =
  "\n\nThe child stays alive after it reports. End it with stop_agent when you need nothing more from it. To continue it, use message_agent.";

const envMs = (key: string, fallback: number): number => Number(process.env[key]) || fallback;

const reply = (text: string, details: unknown = {}) => ({ content: [{ type: "text" as const, text }], details });

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

type AgentRow = AgentCompletionRow & {
  window: string; depth: number; cwd: string; runtime?: string; canMessage: boolean;
  kind: "agent" | "subagent"; ended?: string; model?: string; reported?: boolean; report?: string;
};

type ChildRuntime = { name: string; mode: "routed" | "inside" };

type PeerData = { role: "peer"; name: string; session: string; cwd: string };
type AgentData = ChildData | PeerData;

type ChildData = {
  role: "subagent";
  owner: string;
  name: string;
  session: string;
  model: string;
  fork: boolean;
  cwd: string;
  runtime?: ChildRuntime;
  pane: { instance: string; pane: string };
};

const handleClick = (event: TuiMouseEvent, click: () => void) => {
  if (event.button !== "left") return;
  if (event.type === "press") return { handled: true, render: false };
  if (event.type !== "click") return;
  click();
  return { handled: true, render: true };
};

type Paint = (color: "border" | "dim" | undefined, text: string) => string;

const collapsedInbound = (width: number, header: string, body: string, paint: Paint): string => {
  if (width <= 2) return paint("border", "│ ".slice(0, width));
  const preview = body ? ` ${body.split("\n", 1)[0]}${body.includes("\n") ? "..." : ""}` : "";
  return paint("border", "│ ") + truncateToWidth(paint("dim", header) + paint(undefined, preview), width - 2);
};

function isMessageQueue(queue: unknown): queue is { messages: AgentSession["messages"] } {
  return typeof queue === "object" && queue !== null && "messages" in queue && Array.isArray(queue.messages);
}

// pi's core/agent-session.js clearQueue() discards custom messages alongside editor text.
const clearQueue = (globalThis.__koPiExtensionClearQueue ??= AgentSession.prototype.clearQueue);
AgentSession.prototype.clearQueue = function () {
  const agent: object = this.agent;
  if (!("steeringQueue" in agent) || !("followUpQueue" in agent)
    || !isMessageQueue(agent.steeringQueue) || !isMessageQueue(agent.followUpQueue)) return clearQueue.call(this);
  const steering = agent.steeringQueue.messages.filter((m) => m.role === "custom");
  const followUp = agent.followUpQueue.messages.filter((m) => m.role === "custom");
  const cleared = clearQueue.call(this);
  for (const message of steering) this.agent.steer(message);
  for (const message of followUp) this.agent.followUp(message);
  return cleared;
};

const NEVER_SLEEP_RULE =
  "Never run `sleep` in bash to wait for anything - an async job, a subagent, a message, or another agent's work settling. What you are waiting for arrives as a notice or message that wakes you after you end your turn; if a build breaks because of another agent's half-done work, report that rather than sleeping until it clears. Ending your turn while you wait is always safe: a running async job or subagent of yours keeps you alive, and its notice starts your next turn.";

const NOT_THE_USER_RULE =
  "A notice is information, not the user speaking: act on it, do not thank or answer it. A message from another agent says in its first line who sent it and how they stand to you.";

export const SPAWN_RESULT_RULE =
  "its result arrives as a notice when it ends a turn with no unfinished work of its own (service jobs do not count) - you know nothing about it until then, so do not report, assume or predict it, continue other work or answer the user meanwhile, and if nothing else is left, end your turn - the notice wakes you; list_agents lists this agent and stop_agent stops it";

export const SUBAGENT_RESULT_RULE =
  "; ending your turn now sends no report to your parent: your report is the last message of a turn that ends when no non-service job of yours is running and no subagent of yours owes you a report";

const SUBAGENT_INSTRUCTION =
  "While a non-service async job of yours is running, or a subagent of yours still owes you a report, ending your turn sends nothing to your parent. You were spawned as a subagent: your report is the last message of a turn that ends after all of them finish, once for each piece of work your parent gives you. Your parent is not watching this session and reads nothing else. End your work with a message that stands on its own: what you did, what failed, and what you left undone. " +
  "If you must stop to wait for another agent or for the user, say so in that message; when the work completes later, tell your parent with message_agent. " +
  "Reporting does not end this session: it stays alive until your parent ends it with stop_agent, and the parent can continue it with message_agent.";

type ShutdownReason = "quit" | "reload" | "new" | "resume" | "fork";

// pi /reload keeps the process, its message stream and its received-id ring.
type ReceiverHold = { child: ChildProcess; partial: Buffer };

type JobCall = {
  forward(bytes: Buffer): void;
  resolve(result: { exitCode: number | null }): void;
  reject(error: unknown): void;
  abort: { signal: AbortSignal; listener: () => void } | null;
};
type JobOutput = {
  type: "job";
  name: string;
  origin: { type: "async_bash"; stream: boolean; service: boolean } | { type: "bash"; move: "timeout" | "key" | "reload" };
  log: string;
  output: WriteStream;
  logClosed: Promise<void>;
  stream: { held: number; lines: string[]; dropped: number; cut: boolean; split: SplitState; carry: Buffer; timer: NodeJS.Timeout | null; lastBatch: number };
};
type Job = {
  id: string;
  command: string;
  startedAt: string;
  where: { type: "local"; child: ChildProcess } | { type: "routed"; runtime: string; child: ChildProcess };
  tail: Buffer;
  producedBytes: number;
  mode: { type: "foreground"; call: JobCall | null } | JobOutput;
  state: { type: "running" } | { type: "ended"; end: JobEnd; announced: boolean };
  deadline: NodeJS.Timeout | null;
  stopping: { end: JobEnd; timer: NodeJS.Timeout } | null;
  closed: Promise<void>;
};
type BackgroundJob = Job & { mode: JobOutput };
const isBackgroundJob = (job: Job): job is BackgroundJob => job.mode.type === "job";
const serviceJob = (job: BackgroundJob): boolean => job.mode.origin.type === "async_bash" && job.mode.origin.service;
const jobReference = (job: BackgroundJob): JobRef => ({ id: job.id, name: job.mode.name, service: serviceJob(job), log: job.mode.log });
const jobRecordState = (job: BackgroundJob): "idle" | "working" => serviceJob(job) ? "idle" : "working";
const streams = (job: BackgroundJob): boolean => job.mode.origin.type === "async_bash" && job.mode.origin.stream;
const TAIL_BYTES = 4000;
const HELD_BYTES = 64 * 1024;
type JobOperations = {
  exec(command: string, cwd: string, options: Parameters<BashOperations["exec"]>[2] & { onStart?(job: Job): void }): ReturnType<BashOperations["exec"]>;
};
class MovedToJob extends Error {
  readonly job: BackgroundJob;
  readonly reason: "timeout" | "key" | "reload";

  constructor(job: BackgroundJob, reason: MovedToJob["reason"]) {
    super("moved to job");
    this.job = job;
    this.reason = reason;
  }
}
type JobRegistry = {
  shape: number;
  session: string;
  stopAll(): string[];
  jobs: Map<string, Job>;
  owner: { onStart(job: BackgroundJob): void; onLines(job: BackgroundJob): void; onEnd(job: BackgroundJob): void; clearRecords(): void } | null;
  exit: () => void;
  keys: () => void;
};
const JOBS = Symbol.for("ko-pi.jobs");
const JOB_SHAPE = 3;
function isJobRegistry(value: unknown): value is JobRegistry {
  return isRecord(value) && typeof value.shape === "number" && typeof value.session === "string"
    && value.jobs instanceof Map && typeof value.stopAll === "function" && typeof value.exit === "function" && typeof value.keys === "function";
}

function jobRunning(job: Job): boolean {
  return job.state.type !== "ended" && job.where.child.exitCode === null && job.where.child.signalCode === null;
}

function signalJob(job: Job, signal: NodeJS.Signals): boolean {
  const child = job.where.child;
  if (!jobRunning(job) || !child.pid) return false;
  try {
    if (job.where.type === "local") process.kill(-child.pid, signal);
    else child.kill();
    return true;
  } catch (error) {
    if (isRecord(error) && (error.code === "ESRCH" || (job.where.type === "local" && error.code === "EPERM"))) return false;
    throw error;
  }
}


function execCode(end: JobEnd, where: Job["where"]["type"]): number | null {
  if (end.type === "exit") return end.code;
  if (end.type !== "signal") return null;
  const signal = Object.entries(where === "local" ? os.constants.signals : SIGNAL_NUMBERS).find(([name]) => (where === "local" ? name : `SIG${name}`) === end.signal)?.[1];
  return signal === undefined ? null : 128 + signal;
}

function validateJobTimeout(timeout: number | undefined): void {
  if (timeout !== undefined && (!Number.isFinite(timeout) || timeout <= 0 || timeout * 1000 > 2147483647)) throw new Error("Invalid timeout: must be a finite positive number of seconds within the timer limit");
}

const jobKillMs = (): number => envMs("KO_JOB_KILL_MS", 5000);

function armJobDeadline(job: Job, seconds: number, at = performance.now() + seconds * 1000): void {
  if (job.deadline) clearTimeout(job.deadline);
  job.deadline = setTimeout(() => stopJob(job, { type: "timeout", seconds }), Math.max(0, Math.ceil(at - performance.now())));
  job.deadline.unref();
}

function detachJob(job: BackgroundJob): void {
  if (job.mode.stream.timer) clearTimeout(job.mode.stream.timer);
  job.mode.stream.timer = null;
}

function detachKeys(registry: JobRegistry): void {
  const detach = registry.keys;
  registry.keys = () => {};
  detach();
}

function stopJob(job: Job, end: JobEnd = { type: "stopped" }): void {
  if (job.state.type === "ended" || job.stopping) return;
  if (job.deadline) clearTimeout(job.deadline);
  job.deadline = null;
  signalJob(job, "SIGTERM");
  const timer = setTimeout(() => signalJob(job, "SIGKILL"), jobKillMs());
  timer.unref();
  job.stopping = { end, timer };
}

async function waitJobs(jobs: Job[]): Promise<void> {
  await Promise.race([Promise.all(jobs.map((job) => job.closed)), sleep(jobKillMs())]);
}

function pruneJobs(registry: JobRegistry): void {
  let retained = [...registry.jobs.values()].filter((job) => job.state.type === "ended" && job.state.announced).length;
  for (const job of registry.jobs.values()) {
    if (retained <= 20) break;
    if (job.state.type === "ended" && job.state.announced) {
      registry.jobs.delete(job.id);
      retained--;
    }
  }
}

function createJobRegistry(session: string): JobRegistry {
  const jobs = new Map<string, Job>();
  const registry: JobRegistry = {
    shape: JOB_SHAPE, session, jobs, owner: null, keys: () => {},
    stopAll() {
      registry.owner = null;
      const live = [...jobs.values()].filter((job) => job.state.type !== "ended");
      for (const job of live) {
        if (isBackgroundJob(job)) detachJob(job);
        stopJob(job);
      }
      void Promise.all([...jobs.values()].map((job) => job.closed)).then(() => process.removeListener("exit", registry.exit));
      return live.filter(isBackgroundJob).map((job) => job.mode.name);
    },
    exit() {
      registry.owner?.clearRecords();
      for (const job of jobs.values()) {
        if (job.where.type === "local") try { signalJob(job, "SIGKILL"); } catch {}
      }
    },
  };
  process.on("exit", registry.exit);
  return registry;
}

function writeJobOutput(job: BackgroundJob, bytes: Buffer): void {
  const output = job.mode.output;
  if (output.destroyed || output.write(bytes)) return;
  const child = job.where.child;
  child.stdout?.pause();
  child.stderr?.pause();
  const resume = (): void => {
    output.removeListener("drain", resume);
    output.removeListener("error", resume);
    child.stdout?.resume();
    child.stderr?.resume();
  };
  output.once("drain", resume);
  output.once("error", resume);
}

function trimStream(job: BackgroundJob): void {
  const stream = job.mode.stream;
  let removed = 0;
  while (stream.lines.length - removed > DEFAULT_MAX_LINES || (stream.held > HELD_BYTES && stream.lines.length > removed)) {
    if (stream.lines.length - removed === 1 && !stream.split.line) {
      const old = stream.lines[removed] ?? "";
      stream.lines[removed] = utf8Suffix(old, HELD_BYTES - stream.carry.length - 1);
      stream.held -= Buffer.byteLength(old) - Buffer.byteLength(stream.lines[removed] ?? "");
      stream.cut = true;
      break;
    }
    stream.held -= Buffer.byteLength(stream.lines[removed] ?? "") + 1;
    removed++;
  }
  if (removed) {
    stream.lines = stream.lines.slice(removed);
    stream.dropped += removed;
  }
  if (stream.held > HELD_BYTES) {
    const before = Buffer.byteLength(stream.split.line);
    stream.split.line = utf8Suffix(stream.split.line, HELD_BYTES - stream.carry.length);
    stream.held -= before - Buffer.byteLength(stream.split.line);
    stream.cut = true;
  }
}

function jobData(registry: JobRegistry, job: Job, bytes: Buffer): void {
  job.tail = Buffer.concat([job.tail.subarray(Math.max(0, job.tail.length + bytes.length - HELD_BYTES)), bytes.subarray(-HELD_BYTES)]);
  job.producedBytes += bytes.length;
  if (!isBackgroundJob(job)) {
    if (job.mode.type === "foreground") job.mode.call?.forward(bytes);
    return;
  }
  writeJobOutput(job, bytes);
  if (!streams(job) || job.stopping?.end.type === "stopped") return;
  const stream = job.mode.stream;
  const before = Buffer.byteLength(stream.split.line) + stream.carry.length;
  const decoded = utf8Complete(stream.carry, bytes);
  const lines = splitLines(stream.split, decoded.text);
  stream.lines.push(...lines);
  stream.held += lines.reduce((bytes, line) => bytes + Buffer.byteLength(line) + 1, 0) + Buffer.byteLength(stream.split.line) + decoded.carry.length - before;
  stream.carry = decoded.carry;
  trimStream(job);
  registry.owner?.onLines(job);
}

function jobTail(job: Job): string {
  return utf8Suffix(splitLines(newSplit(), job.tail.subarray(-4 * TAIL_BYTES).toString("utf8") + "\n").join("\n"), TAIL_BYTES);
}

function detachCall(job: Job): JobCall | null {
  if (job.mode.type !== "foreground") return null;
  const call = job.mode.call;
  job.mode.call = null;
  if (call?.abort) call.abort.signal.removeEventListener("abort", call.abort.listener);
  return call;
}

async function finishJob(registry: JobRegistry, job: Job, result: ExecResult): Promise<void> {
  if (job.deadline) clearTimeout(job.deadline);
  if (isBackgroundJob(job)) {
    if (streams(job)) {
      if (job.mode.stream.split.line) {
        job.mode.stream.lines.push(job.mode.stream.split.line);
        job.mode.stream.held++;
      }
      job.mode.stream.split.line = "";
      trimStream(job);
    }
    job.mode.output.end();
    await job.mode.logClosed;
  }
  if (job.stopping) clearTimeout(job.stopping.timer);
  job.state = { type: "ended", end: job.stopping?.end ?? result.end, announced: false };
  if (isBackgroundJob(job)) {
    registry.jobs.delete(job.id);
    registry.jobs.set(job.id, job);
    try { registry.owner?.onEnd(job); } catch {}
    pruneJobs(registry);
  } else {
    const call = detachCall(job);
    registry.jobs.delete(job.id);
    if (call?.abort?.signal.aborted) call.reject(new Error("aborted"));
    else if (job.state.end.type === "failed") call?.reject(new Error(job.state.end.message));
    else if (job.state.end.type === "timeout") call?.reject(new Error(`timeout:${job.state.end.seconds}`));
    else call?.resolve({ exitCode: execCode(result.end, job.where.type) });
  }
}

function failJob(registry: JobRegistry, job: Job, error: unknown): Promise<void> {
  return finishJob(registry, job, { end: { type: "failed", message: errorText(error) } });
}

function observeJob(registry: JobRegistry, where: Job["where"], command: string, options: Parameters<JobOperations["exec"]>[2], completion: Promise<ExecResult>) {
  let id: string;
  do { id = "j" + randomBytes(6).readUIntBE(0, 6).toString(36).padStart(7, "0").slice(-7); } while (registry.jobs.has(id));
  const job: Job = {
    id, command, startedAt: new Date().toISOString(), where, tail: Buffer.alloc(0), producedBytes: 0,
    mode: { type: "foreground", call: null }, state: { type: "running" }, deadline: null, stopping: null, closed: Promise.resolve(),
  };
  registry.jobs.set(id, job);
  const result = new Promise<{ exitCode: number | null }>((resolve, reject) => {
    const listener = stopJob.bind(null, job, { type: "stopped" });
    job.mode = { type: "foreground", call: { forward: options.onData, resolve, reject, abort: options.signal ? { signal: options.signal, listener } : null } };
    options.signal?.addEventListener("abort", listener, { once: true });
    if (options.signal?.aborted) listener();
  });
  job.closed = completion.then(finishJob.bind(null, registry, job), failJob.bind(null, registry, job));
  if (options.timeout !== undefined) armJobDeadline(job, options.timeout);
  try { options.onStart?.(job); }
  catch (error) { detachCall(job)?.reject(error); stopJob(job); }
  return { job, result };
}

function promoteJob(registry: JobRegistry, job: Job, origin: JobOutput["origin"], name = job.id): BackgroundJob {
  if (isBackgroundJob(job)) return job;
  const dir = join(os.tmpdir(), "ko-pi");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const log = join(dir, `${registry.session}-${job.id}.log`);
  const output = createWriteStream(log, { flags: "wx", mode: 0o600 });
  const logClosed = new Promise<void>((done) => { output.once("finish", done); output.once("error", () => done()); });
  output.on("error", (error) => stopJob(job, { type: "failed", message: error.message }));
  const call = detachCall(job);
  const mode: JobOutput = {
    type: "job", name, origin, log, output, logClosed,
    stream: { held: 0, lines: [], dropped: 0, cut: false, split: newSplit(), carry: Buffer.alloc(0), timer: null, lastBatch: performance.now() },
  };
  const moved = Object.assign(job, { mode });
  if (job.producedBytes > job.tail.length) writeJobOutput(moved, Buffer.from(`--- earlier output is cut; this log starts with the last ${HELD_BYTES / 1024} KiB before the move ---\n`));
  writeJobOutput(moved, job.tail);
  call?.resolve({ exitCode: null });
  registry.owner?.onStart(moved);
  return moved;
}

function getShellEnv(): NodeJS.ProcessEnv {
  const bin = join(getAgentDir(), "bin");
  const key = Object.keys(process.env).find((key) => key.toLowerCase() === "path") ?? "PATH";
  const path = process.env[key] ?? "";
  return { ...process.env, [key]: path.split(delimiter).filter(Boolean).includes(bin) ? path : [bin, path].filter(Boolean).join(delimiter) };
}

function localCompletion(child: ChildProcess): Promise<ExecResult> {
  return new Promise((resolve) => {
    let failure: string | undefined;
    child.on("error", (error) => { failure = error.message; });
    child.on("close", (code, signal) => resolve({ end: failure ? { type: "failed", message: failure } : signal ? { type: "signal", signal } : { type: "exit", code: code ?? 1 } }));
  });
}

function localJob(registry: JobRegistry, shell: ReturnType<typeof getShellConfig>, command: string, cwd: string, options: Parameters<JobOperations["exec"]>[2]): ReturnType<BashOperations["exec"]> {
  if (options.signal?.aborted) return Promise.reject(new Error("aborted"));
  const stdin = shell.commandTransport === "stdin";
  const child = spawn(shell.shell, stdin ? shell.args : [...shell.args, command], { cwd, env: options.env ?? getShellEnv(), detached: true, stdio: [stdin ? "pipe" : "ignore", "pipe", "pipe"] });
  if (stdin) { child.stdin?.on("error", () => {}); child.stdin?.end(command); }
  const observed = observeJob(registry, { type: "local", child }, command, options, localCompletion(child));
  const data = jobData.bind(null, registry, observed.job);
  child.stdout?.on("data", data);
  child.stderr?.on("data", data);
  return observed.result;
}

async function routedJob(registry: JobRegistry, r: Routed, command: string, cwd: string, options: Parameters<JobOperations["exec"]>[2]): ReturnType<BashOperations["exec"]> {
  const shell = (await abortable(r.facts(), options.signal)).programs.get("bash") ?? "sh";
  if (options.signal?.aborted) throw new Error("aborted");
  const runtime = r.name;
  let start: Parameters<JobOperations["exec"]>[2] | null = options;
  let observed: ReturnType<typeof observeJob> | undefined;
  void runtimeExec(r.ko, runtime, {
    argv: [shell, "-lc", command], cwd: toRuntime(r, cwd),
    onSpawn(child, completion) {
      if (start) observed = observeJob(registry, { type: "routed", runtime, child }, command, start, completion);
      start = null;
    },
    onStdout: (data) => { if (observed) jobData(registry, observed.job, data); },
    onStderr: (data) => { if (observed) jobData(registry, observed.job, data); },
  });
  if (!observed) throw new Error("the runtime exec did not start");
  return observed.result;
}

declare global {
  var __koPiExtensionReceiver: ReceiverHold | undefined;
  var __koPiExtensionReceived: string[] | undefined;
  var __koPiExtensionCopy: string | undefined;
  var __koPiExtensionClearQueue: AgentSession["clearQueue"] | undefined;
  var __koPiExtensionExit: (() => void) | undefined;
}

const extensionPath = fileURLToPath(import.meta.url);
const KO_SKILL_RULE = "The user runs the ko terminal multiplexer, and this pi runs in one of its panes. When the user talks about windows, tabs, panes, sessions, splits, floats or the sidebar, read the ko skill first.";

// One copy per process: pi dedupes extensions by real path only, so a second
// copy at another path must register nothing. A /reload runs the same file again
// and finds it already its own.
function isFirstCopy(): boolean {
  return (globalThis.__koPiExtensionCopy ??= extensionPath) === extensionPath;
}

function normalizeAddress(to: string): { wanted: string; mention: boolean } {
  const raw = to.replace(/^@/, "");
  const id = raw.match(/^(?:.* )?\(session ([^\s()]+)\)$/)?.[1];
  return { wanted: id ?? raw, mention: id !== undefined };
}

type Held = { from: Api["Sender"]; relation?: Relation; text: string; runtime?: string };

const runtimeOf = (data: unknown): string | undefined => (isRecord(data) && typeof data.runtime === "string" ? data.runtime : undefined);



function isCause(value: unknown): value is Dead["cause"] {
  if (!isRecord(value)) return false;
  return (value.type === "exited" && typeof value.code === "number")
    || (value.type === "signaled" && typeof value.signal === "number")
    || (value.type === "failed" && isString(value.message));
}

function isEnd(value: unknown): value is Api["End"] {
  return isRecord(value) && (value.type === "gone" || (value.type === "dead" && typeof value.at === "number" && isCause(value.cause)));
}

function isSender(value: unknown): value is Api["Sender"] {
  return isRecord(value) && (value.type === "user" || (value.type === "pane" && isString(value.pane)));
}

const MESSAGE_KINDS = ["message", "steer", "interrupt", "stop", "notice", "user"];

// A message has its shape or it is refused: a pane sender always comes with its relation.
function isMessage(value: unknown): value is Api["Message"] {
  if (!isRecord(value) || typeof value.seq !== "number" || !isString(value.id) || !isSender(value.from)) return false;
  if (value.from.type === "pane" && !isRelation(value.relation)) return false;
  if (value.kind === "ended") return isEnd(value.end);
  return isString(value.kind) && MESSAGE_KINDS.includes(value.kind) && isString(value.text);
}

function isPlacement(value: unknown): value is Api["Placement"] {
  return isRecord(value) && isString(value.pane) && isString(value.session) && isString(value.window);
}

// The complete UTF-8 of the carry and the bytes, and the incomplete tail that waits for the next bytes.
function utf8Complete(carry: Buffer, bytes: Buffer): { text: string; carry: Buffer } {
  const all = Buffer.concat([carry, bytes]);
  let end = all.length;
  for (let i = all.length - 1; i >= Math.max(0, all.length - 3); i--) {
    const byte = all[i] ?? 0;
    if ((byte & 0xc0) === 0x80) continue;
    const need = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : byte >= 0xc0 ? 2 : 1;
    if (all.length - i < need) end = i;
    break;
  }
  return { text: all.subarray(0, end).toString("utf8"), carry: Buffer.from(all.subarray(end)) };
}

type Addressable = { id: string; pane: string; name: string; named: boolean; state: "running" | "ended" };

function isPosted(value: unknown): value is Api["Posted"] {
  return isRecord(value) && typeof value.seq === "number" && (value.state === "queued" || value.state === "delivered" || value.state === "acked");
}

function matchesId(row: { id: string; pane: string }, wanted: string, prefix = false): boolean {
  return prefix ? wanted.length >= MIN_ID_PREFIX && row.id.startsWith(wanted) : row.id === wanted || (row.pane !== "" && row.pane === wanted);
}

// Go-style %q: escapes quotes, backslashes and control characters but keeps
// non-ASCII agent names readable.
function quote(s: string): string {
  let out = '"';
  for (const ch of s) {
    const code = ch.codePointAt(0) ?? 0;
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\t") out += "\\t";
    else if (code < 0x20 || code === 0x7f) out += "\\x" + code.toString(16).padStart(2, "0");
    else out += ch;
  }
  return out + '"';
}

// Output text for the model: escape sequences gone; a carriage return that is
// not followed by a line feed starts the line over.
type SplitState = {
  mode: "text" | "esc" | "intermediate" | "csi" | "string" | "string-esc";
  line: string;
  cr: boolean;
};

export const newSplit = (): SplitState => ({ mode: "text", line: "", cr: false });

export function splitLines(state: SplitState, text: string): string[] {
  const lines: string[] = [];
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0;
    switch (state.mode) {
      case "esc":
        if (ch === "[") state.mode = "csi";
        else if (ch === "]" || ch === "P" || ch === "X" || ch === "^" || ch === "_") state.mode = "string";
        else if (code >= 0x20 && code <= 0x2f) state.mode = "intermediate";
        else state.mode = "text";
        continue;
      case "intermediate":
        if (code < 0x20 || code > 0x2f) state.mode = "text";
        continue;
      case "csi":
        if (code >= 0x40 && code <= 0x7e) state.mode = "text";
        continue;
      case "string":
        if (ch === "\x07" || ch === "\x9c") state.mode = "text";
        else if (ch === "\x1b") state.mode = "string-esc";
        continue;
      case "string-esc":
        state.mode = ch === "\\" ? "text" : "string";
        continue;
      case "text":
        break;
    }
    if (ch === "\x1b") {
      state.mode = "esc";
      continue;
    }
    if (ch === "\x9b") {
      state.mode = "csi";
      continue;
    }
    if (state.cr) {
      state.cr = false;
      if (ch !== "\n") state.line = "";
    }
    if (ch === "\r") state.cr = true;
    else if (ch === "\n") {
      lines.push(state.line);
      state.line = "";
    } else if (ch === "\t" || code >= 0x20) state.line += ch;
  }
  return lines;
}

export function streamBatch(lines: string[], log: string, alreadyDropped = 0, cut = false) {
  const tail = truncateTail(lines.join("\n"));
  const omitted = tail.totalLines - tail.outputLines + alreadyDropped;
  const notes: string[] = [];
  if (omitted > 0) notes.push(`... ${omitted} lines omitted (log: ${log})`);
  if (cut || tail.lastLinePartial) notes.push(`... long lines were truncated (log: ${log})`);
  return { content: [...notes, tail.content].join("\n"), batch: tail.content, omitted, cut: cut || tail.lastLinePartial };
}

function checkName(name: string): string | null {
  if (name === "" || name === "." || name === ".." || name.includes("/")) {
    return `refusing window name ${quote(name)}: it must be one path-safe name, not an empty, dot or slashed path`;
  }
  return null;
}

// pi --list-models prints a header, then one row per model: provider, model id.
type ModelRow = { provider: string; model: string };

function modelRows(out: string): ModelRow[] {
  const rows: ModelRow[] = [];
  for (const line of out.split("\n").slice(1)) {
    const fields = line.trim().split(/\s+/);
    if (fields.length >= 2 && fields[0] && fields[1]) rows.push({ provider: fields[0], model: fields[1] });
  }
  return rows;
}

function validateModelRows(argument: string, rows: ModelRow[]): string | null {
  const configured = (id: string): boolean => rows.some((r) => `${r.provider}/${r.model}` === id);
  if (configured(argument)) return null;
  const levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
  let model = argument;
  const at = argument.lastIndexOf(":");
  if (at >= 0) {
    const level = argument.slice(at + 1);
    if (!levels.includes(level)) return `unknown thinking level ${quote(level)}; valid levels: ${levels.join(", ")}`;
    model = argument.slice(0, at);
  }
  if (configured(model)) return null;
  const providers: string[] = [];
  for (const row of rows) if (!providers.includes(row.provider)) providers.push(row.provider);
  const configuredList = providers
    .map((p) => `${p}/{${rows.filter((r) => r.provider === p).map((r) => r.model).join(",")}}`)
    .join(", ");
  return `model ${quote(argument)} is not a model of a configured provider; configured: ${configuredList}`;
}

async function gitCommonDir(cwd: string): Promise<string | undefined> {
  const env = { ...process.env };
  delete env.GIT_DIR;
  delete env.GIT_COMMON_DIR;
  delete env.GIT_WORK_TREE;
  const result = await runCommand("git", ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], { timeoutMs: 1000, env });
  if (!result.ok) return undefined;
  try { return realpathSync(result.out.trim()); } catch { return undefined; }
}

function realpathOf(path: string): string | undefined {
  try { return realpathSync(path); } catch { return undefined; }
}

// ---- the routed mode: pi on the host, its built-in tools in a runtime ----

const GREP_MAX_LINE_LENGTH = 500;

const GREP_DEFAULT_LIMIT = 100;

const CONTEXT_FILE_NAMES = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"];

const IMAGE_TYPES: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" };

// The Linux numbers: an exec session reports a signal by name.
const SIGNAL_NUMBERS: Record<Exclude<Api["ExitSignal"], "OTHER">, number> = { HUP: 1, INT: 2, QUIT: 3, ILL: 4, TRAP: 5, ABRT: 6, BUS: 7, FPE: 8, KILL: 9, USR1: 10, SEGV: 11, USR2: 12, PIPE: 13, ALRM: 14, TERM: 15 };

type PathMap = Api["PathMap"];

type Routed = {
  name: string;
  ko: string;
  hostCwd: string;
  paths: PathMap[];
  cwd: string;
  contextFiles: Array<{ path: string; content: string }>;
  facts: () => Promise<Facts>;
  ready: (signal?: AbortSignal) => Promise<void>;
};

type Facts = { programs: Map<string, string>; home: string };

type Run = { out: Buffer; err: Buffer; exitCode: number | null };

// Resolves or rejects as the signal aborts, without ending the work it waits for.
function abortable<T>(work: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("aborted"));
      return;
    }
    const onAbort = (): void => reject(new Error("aborted"));
    signal?.addEventListener("abort", onAbort, { once: true });
    work.then(resolve, reject).finally(() => signal?.removeEventListener("abort", onAbort));
  });
}

async function execRun(r: Pick<Routed, "ko" | "name">, opts: ExecOptions): Promise<Run> {
  const out: Buffer[] = [];
  const err: Buffer[] = [];
  const { end } = await runtimeExec(r.ko, r.name, {
    ...opts,
    onStdout: (data) => {
      out.push(data);
      opts.onStdout?.(data);
    },
    onStderr: (data) => {
      err.push(data);
      opts.onStderr?.(data);
    },
  });
  return { out: Buffer.concat(out), err: Buffer.concat(err), exitCode: execCode(end, "routed") };
}

const commandFailure = (run: Pick<Run, "err" | "exitCode">, program: string): Error => new Error(run.err.toString("utf8").trim() || `${program} exited with ${run.exitCode}`);

async function execChecked(r: Pick<Routed, "ko" | "name">, opts: ExecOptions): Promise<Run> {
  const run = await execRun(r, opts);
  if (run.exitCode !== 0) throw commandFailure(run, opts.argv[0] ?? "command");
  return run;
}

// The runtime directory of the longest host prefix of `paths` that holds `path`, whole components only.
export function mapHostPath(paths: PathMap[], path: string): string | undefined {
  let best: { base: string; runtime: string } | undefined;
  for (const entry of paths) {
    const base = entry.host.replace(/\/+$/, "");
    if ((path === base || path.startsWith(base + "/")) && (!best || base.length > best.base.length)) best = { base, runtime: entry.runtime };
  }
  return best && posix.join(best.runtime, path.slice(best.base.length));
}

const toRuntime = (r: Pick<Routed, "paths">, path: string): string => mapHostPath(r.paths, path) ?? path;

// Prints the directory, then the nearest-first context file of each directory up to the root, as
// path NUL content NUL records.
const CONTEXT_SCRIPT = `d=\${1:-$(pwd)}
printf '%s\\0' "$d"
while :; do
  for f in ${CONTEXT_FILE_NAMES.join(" ")}; do
    if [ -f "$d/$f" ] && [ -r "$d/$f" ]; then printf '%s\\0' "$d/$f"; cat "$d/$f"; printf '\\0'; break; fi
  done
  [ "$d" = / ] || [ "$d" = . ] && break
  d=$(dirname -- "$d")
done`;

async function readRuntimeContext(ko: string, name: string, cwd: string | undefined): Promise<{ cwd: string; contextFiles: Routed["contextFiles"] }> {
  const run = await execChecked({ ko, name }, { argv: ["sh", "-c", CONTEXT_SCRIPT, "sh", ...(cwd === undefined ? [] : [cwd])], ...(cwd === undefined ? {} : { cwd }) });
  const [dir = "", ...records] = run.out.toString("utf8").split("\0");
  const contextFiles: Routed["contextFiles"] = [];
  for (let at = 0; at + 1 < records.length; at += 2) contextFiles.unshift({ path: records[at] ?? "", content: (records[at + 1] ?? "").replace(/^\uFEFF/, "") });
  return { cwd: dir, contextFiles };
}

async function probeFacts(ko: string, name: string): Promise<Facts> {
  const run = await execRun({ ko, name }, { argv: ["sh", "-c", 'printf "%s\\n" "$HOME"; for p in bash fd rg; do command -v "$p" 2>/dev/null; done'] }).catch(() => undefined);
  const [home = "", ...found] = (run?.out.toString("utf8") ?? "").split("\n");
  return { home, programs: new Map(found.filter((line) => line.startsWith("/")).map((path) => [posix.basename(path), path])) };
}

async function homed<T extends string | undefined>(r: Routed, path: T, signal: AbortSignal | undefined): Promise<T | string> {
  if (path === undefined || (path !== "~" && !path.startsWith("~/"))) return path;
  const { home } = await abortable(r.facts(), signal);
  return home ? home + path.slice(1) : path;
}

const ROUTED_TOOLS = ["bash", "read", "write", "edit", "ls", "find", "grep", "async_bash"];

const readOperations = (r: Routed): ReadOperations => ({
  readFile: async (path) => (await execChecked(r, { argv: ["cat", toRuntime(r, path)] })).out,
  access: async () => {},
  detectImageMimeType: async (path) => IMAGE_TYPES[extname(path).toLowerCase()] ?? null,
});

const writeOperations = (r: Routed): WriteOperations => ({
  mkdir: async () => {},
  writeFile: async (path, content) => {
    await execChecked(r, { argv: ["sh", "-c", 'mkdir -p -- "$(dirname -- "$1")" && cat > "$1"', "sh", toRuntime(r, path)], input: Buffer.from(content, "utf8") });
  },
});

// One `ls -1Ap` answers exists, stat and readdir of a directory and the stat of each of its entries.
const lsOperations = (r: Routed): LsOperations => {
  const script = 'if [ ! -e "$1" ]; then exit 2; elif [ ! -d "$1" ]; then exit 3; fi; exec ls -1Ap -- "$1"';
  const entries = new Map<string, boolean>();
  const listed = new Map<string, Promise<Run>>();
  const list = (path: string): Promise<Run> => {
    let run = listed.get(path);
    if (!run) {
      run = execRun(r, { argv: ["sh", "-c", script, "sh", toRuntime(r, path)] }).then((found) => {
        for (const line of found.exitCode === 0 ? found.out.toString("utf8").split("\n").filter(Boolean) : []) {
          entries.set(posix.join(path, line.replace(/\/$/, "")), line.endsWith("/"));
        }
        return found;
      });
      listed.set(path, run);
    }
    return run;
  };
  return {
    exists: async (path) => (await list(path)).exitCode !== 2,
    stat: async (path) => {
      const known = entries.get(path);
      if (known !== undefined) return { isDirectory: () => known };
      const { exitCode } = await list(path);
      if (exitCode === 0 || exitCode === 3) return { isDirectory: () => exitCode === 0 };
      throw new Error(`Path not found: ${path}`);
    },
    readdir: async (path) => {
      const run = await list(path);
      if (run.exitCode !== 0) throw commandFailure(run, "ls");
      return run.out.toString("utf8").split("\n").filter(Boolean).map((line) => line.replace(/\/$/, ""));
    },
  };
};

const findOperations = (r: Routed): FindOperations => ({
  exists: async (path) => (await execRun(r, { argv: ["test", "-e", toRuntime(r, path)] })).exitCode === 0,
  glob: async (pattern, cwd, { limit }) => {
    const root = toRuntime(r, cwd);
    const fd = (await r.facts()).programs.get("fd");
    const argv = fd
      ? [fd, "--glob", "--color=never", "--hidden", "--no-require-git", "--exclude", ".git", "--exclude", "node_modules", "--max-results", String(limit), ...(pattern.includes("/") ? ["--full-path"] : []), "--", pattern.includes("/") && !pattern.startsWith("/") && !pattern.startsWith("**/") ? `**/${pattern}` : pattern, root]
      : ["find", root, "(", "-name", ".git", "-o", "-name", "node_modules", ")", "-prune", "-o", ...(pattern.includes("/") ? ["-path", pattern.startsWith("/") ? pattern : `*/${pattern.replace(/^\*\*\//, "")}`] : ["-name", pattern]), "-print"];
    const found: string[] = [];
    const stderr: Buffer[] = [];
    const stop = new AbortController();
    const onLine = lineReader({ partial: Buffer.alloc(0) }, (line) => {
      if (found.length < limit) found.push(line);
      if (found.length >= limit) stop.abort();
    });
    const ended = await runtimeExec(r.ko, r.name, { argv, signal: stop.signal, onStdout: onLine, onStderr: (data) => stderr.push(data) }).catch((error: unknown) => {
      if (stop.signal.aborted) return undefined;
      throw error;
    });
    const exitCode = ended ? execCode(ended.end, "routed") : null;
    if (ended && exitCode !== 0 && found.length === 0 && stderr.length > 0) throw commandFailure({ err: Buffer.concat(stderr), exitCode }, argv[0] ?? "find");
    return found.filter((path) => path !== root).map((path) => (path.startsWith(root) ? cwd + path.slice(root.length) : path));
  },
});

type GrepHit = { file: string; line: number; text: string; match: boolean };

function ripgrepHit(line: string): GrepHit | undefined {
  let event: unknown;
  try {
    event = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (!isRecord(event) || (event.type !== "match" && event.type !== "context") || !isRecord(event.data)) return undefined;
  const field = (value: unknown): string | undefined => (isRecord(value) ? (typeof value.text === "string" ? value.text : typeof value.bytes === "string" ? Buffer.from(value.bytes, "base64").toString("utf8") : undefined) : undefined);
  const file = field(event.data.path);
  const text = field(event.data.lines);
  if (file === undefined || text === undefined || typeof event.data.line_number !== "number") return undefined;
  return { file, line: event.data.line_number, text: text.replace(/\r?\n$/, ""), match: event.type === "match" };
}

function grepHit(line: string): GrepHit | undefined {
  const at = line.indexOf("\0");
  const found = at < 0 ? null : /^(\d+)([:-])(.*)$/s.exec(line.slice(at + 1));
  return found ? { file: line.slice(0, at), line: Number(found[1]), text: found[3] ?? "", match: found[2] === ":" } : undefined;
}

async function routedGrep(r: Routed, params: GrepToolInput, signal: AbortSignal | undefined): Promise<{ content: Array<{ type: "text"; text: string }>; details: GrepToolDetails | undefined }> {
  const given = (params.path ?? ".").replace(/^@/, "");
  const root = given.startsWith("/") ? toRuntime(r, given) : posix.resolve(r.cwd, given);
  const limit = Math.max(1, params.limit ?? GREP_DEFAULT_LIMIT);
  const context = params.context && params.context > 0 ? params.context : 0;
  const rg = (await abortable(r.facts(), signal)).programs.get("rg");
  const argv = rg
    ? [rg, "--no-config", "--json", "--hidden", "--color=never", ...(params.ignoreCase ? ["--ignore-case"] : []), ...(params.literal ? ["--fixed-strings"] : []), ...(params.glob ? ["--glob", params.glob] : []), ...(context ? ["--context", String(context)] : []), "--", params.pattern, root]
    : ["grep", "-rnHI", "--null", "--color=never", "--exclude-dir=.git", "--exclude-dir=node_modules", ...(params.ignoreCase ? ["-i"] : []), ...(params.literal ? ["-F"] : ["-E"]), ...(params.glob ? [`--include=${params.glob.replace(/^\*\*\//, "")}`] : []), ...(context ? ["-C", String(context)] : []), "-e", params.pattern, "--", root];
  const stop = new AbortController();
  const onAbort = (): void => stop.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  const hits: GrepHit[] = [];
  const stderr: Buffer[] = [];
  const state = { matches: 0, limitReached: false, linesTruncated: false };
  const onLine = lineReader({ partial: Buffer.alloc(0) }, (line) => {
    const hit = state.limitReached ? undefined : rg ? ripgrepHit(line) : grepHit(line);
    if (!hit) return;
    const { text, wasTruncated } = truncateLine(hit.text.replace(/\r/g, ""), GREP_MAX_LINE_LENGTH);
    if (wasTruncated) state.linesTruncated = true;
    hits.push({ ...hit, text });
    if (hit.match && ++state.matches >= limit) {
      state.limitReached = true;
      stop.abort();
    }
  });
  let exitCode: number | null = 0;
  try {
    exitCode = execCode((await runtimeExec(r.ko, r.name, { argv, signal: stop.signal, onStdout: onLine, onStderr: (data) => stderr.push(data) })).end, "routed");
  } catch (error) {
    if (signal?.aborted || !state.limitReached) throw error;
  } finally {
    signal?.removeEventListener("abort", onAbort);
  }
  if (exitCode !== 0 && exitCode !== 1 && hits.length === 0) throw commandFailure({ err: Buffer.concat(stderr), exitCode }, argv[0] ?? "grep");
  if (state.matches === 0) return { content: [{ type: "text", text: "No matches found" }], details: undefined };
  const prefix = root.endsWith("/") ? root : `${root}/`;
  const output = hits.map((hit) => {
    const name = hit.file.startsWith(prefix) ? hit.file.slice(prefix.length) : posix.basename(hit.file);
    const separator = hit.match ? ":" : "-";
    return `${name}${separator}${hit.line}${separator} ${hit.text}`;
  });
  const truncation = truncateHead(output.join("\n"), { maxLines: Number.MAX_SAFE_INTEGER });
  const details: GrepToolDetails = {};
  const notices: string[] = [];
  if (state.limitReached) {
    notices.push(`${limit} matches limit reached. Use limit=${limit * 2} for more, or refine pattern`);
    details.matchLimitReached = limit;
  }
  if (truncation.truncated) {
    notices.push(`${formatSize(DEFAULT_MAX_BYTES)} limit reached`);
    details.truncation = truncation;
  }
  if (state.linesTruncated) {
    notices.push(`Some lines truncated to ${GREP_MAX_LINE_LENGTH} chars. Use read tool to see full lines`);
    details.linesTruncated = true;
  }
  return { content: [{ type: "text", text: truncation.content + (notices.length ? `\n\n[${notices.join(". ")}]` : "") }], details: Object.keys(details).length ? details : undefined };
}

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
  pi.registerFlag("harness", { description: "Use the koa harness for child agents", type: "string" });
  pi.registerFlag("runtime", { description: "Run the built-in tools and ! commands in a configured runtime or an ad-hoc runtime of this session by name", type: "string" });
  pi.on("project_trust", async (event) => {
    const trusted = process.env.KO_AGENT_TRUSTED_CWD;
    const want = trusted ? realpathOf(trusted) : undefined;
    if (want !== undefined && realpathOf(event.cwd) === want) return { trusted: "yes" };
    return { trusted: "undecided" };
  });
  let ko: string | null = null;
  let session: ExtensionContext | null = null;
  let ownSessionId: string | null = null;
  let edge: { parent: string } | null = null;
  let pane: string | null = null;
  let active = false;
  let instance = "";
  let leaving: "control" | null = null;
  let routed: Routed | { refusal: string } | null = null;
  const liveRunRule = (rule: string): string => rule + (edge ? SUBAGENT_RESULT_RULE : "");

  const written = new Map<string, string>();

  let completion: ReturnType<typeof agentCache> | undefined;

  const insideKo = (): boolean => !!process.env.KO_SOCKET && findKo() !== null;
  const offersSkill = (): boolean => insideKo() && !routed;

  const varsPath = (): string => `/panes/${pane}/vars`;

  const varPath = (key: string): string => `${varsPath()}/${key}`;

  const writeVars = async (entries: Array<[string, unknown]>): Promise<void> => {
    if (!pane) return;
    const fresh = entries.filter(([key, value]) => written.get(key) !== JSON.stringify(value));
    for (const [key, value] of fresh) {
      written.set(key, JSON.stringify(value));
      await apiCall("PUT", varPath(key), value, 2000);
    }
  };

  const varKeys = (): string[] => (routed && !("refusal" in routed) ? [...VAR_KEYS, VAR_RUNTIME, VAR_KO_RUNTIME] : VAR_KEYS);

  // The server deletes the names only while pi.session still holds this
  // session's id (412 otherwise), so a new owner of the pane keeps its variables.
  const unsetVarsBody = (): Api["DeleteVars"] => ({ names: varKeys(), if: { name: VAR_SESSION, value: ownSessionId } });

  const unsetVars = async (): Promise<void> => {
    if (!pane || !ownSessionId) return;
    for (const key of varKeys()) written.delete(key);
    await apiCall("DELETE", varsPath(), unsetVarsBody(), 2000);
  };

  // An uncaught crash exits without session_shutdown, so this runs at exit and
  // leaves a killed process (SIGKILL, SIGTERM) with the variables still set.
  const unsetVarsSync = (): void => {
    if (!pane || !ownSessionId) return;
    apiCallSync("DELETE", varsPath(), unsetVarsBody());
  };

  // ---- the registry: custom entries of the own session ----

  type Entry = { index: number; customType: string; data: Record<string, unknown> };

  const entries = (): Entry[] => {
    const out: Entry[] = [];
    const branch: unknown[] = session?.sessionManager.getBranch() ?? [];
    branch.forEach((entry, index) => {
      if (!isRecord(entry) || entry.type !== "custom" || typeof entry.customType !== "string" || !entry.customType.startsWith("ko-pi.")) return;
      if (isRecord(entry.data) && entry.data.owner === ownSessionId) out.push({ index, customType: entry.customType, data: entry.data });
    });
    return out;
  };

  const append = (customType: string, data: Record<string, unknown>): void => {
    pi.appendEntry(customType, { owner: ownSessionId, at: Date.now(), ...data });
  };

  const lastIndex = (all: Entry[], customType: string, match: (data: Record<string, unknown>) => boolean): number =>
    all.findLast((entry) => entry.customType === customType && match(entry.data))?.index ?? -1;

  const agentOf = (data: Record<string, unknown>): AgentData | undefined => {
    const { name, session: id, cwd } = data;
    if (typeof name !== "string" || typeof id !== "string" || typeof cwd !== "string") return undefined;
    switch (data.role) {
      case "peer": return { role: "peer", name, session: id, cwd };
      case "subagent": {
        const { model, pane: where, runtime: recorded } = data;
        if (typeof model !== "string" || !isRecord(where)) return undefined;
        const runtime = isRecord(recorded) && typeof recorded.name === "string" && (recorded.mode === "routed" || recorded.mode === "inside") ? { runtime: { name: recorded.name, mode: recorded.mode === "routed" ? ("routed" as const) : ("inside" as const) } } : {};
        return { role: "subagent", owner: ownSessionId ?? "", name, session: id, model, fork: data.fork === true, cwd, ...runtime, pane: { instance: str(where.instance), pane: str(where.pane) } };
      }
      default: return undefined;
    }
  };

  const agents = (all = entries()): AgentData[] => {
    const current = new Map<string, AgentData>();
    for (const { customType, data } of all) {
      if (customType !== ENTRY_AGENT) continue;
      const agent = agentOf(data);
      if (agent) current.set(`${agent.role}:${agent.role === "peer" ? agent.session : agent.name}`, agent);
    }
    return [...current.values()];
  };
  const children = (all = entries()): ChildData[] => agents(all).filter((agent): agent is ChildData => agent.role === "subagent");
  const peers = (all = entries()): PeerData[] => agents(all).filter((agent): agent is PeerData => agent.role === "peer");
  const pendingPeers = new Map<string, string>();
  let recordsPeers = false;

  let peerClient: ChildProcess | undefined;
  let peerRetry: NodeJS.Timeout | undefined;
  let peerStopped = true;
  const stopPeerClient = (): void => {
    peerStopped = true;
    clearTimeout(peerRetry);
    peerRetry = undefined;
    peerClient?.kill();
    peerClient = undefined;
  };
  const startPeerClient = (): void => {
    if (!ko || !recordsPeers) return;
    peerStopped = false;
    let delay = 0;
    const connect = (): void => {
      if (peerStopped || !ko) return;
      let layout: Api["LayoutPanes"] | undefined;
      let welcomed = false;
      let refused = false;

      const recordPeers = (): void => {
        if (!layout) return;
        const panes = parsePanes(layout);
        const me = panes.find((p) => p.pane === pane);
        if (!me) return;
        const recorded = new Map(peers().map((peer) => [peer.session, peer]));
        for (const p of peerPanes(panes, me)) {
          const id = piAgent(p.kind)?.session;
          if (p.parent || p.dead || !id || id === ownSessionId) continue;
          const facts: PeerData = { role: "peer", name: p.name || p.title, session: id, cwd: p.cwd };
          const previous = recorded.get(id);
          if (previous?.name === facts.name && previous.cwd === facts.cwd) continue;
          append(ENTRY_AGENT, facts);
        }
      };
      const receive = (event: Api["ClientEvent"]): void => {
        if (peerStopped) return;
        if (event.type === "welcome") { welcomed = true; layout = undefined; delay = 0; }
        else if (event.type === "refused") { refused = !welcomed; }
        else if (event.type === "layout" && welcomed) {
          const rows = new Map(layout?.panes.map((row) => [row.id, row]));
          for (const row of event.panes) rows.set(row.id, row);
          const placed = placesOf(event);
          layout = { ...event, panes: [...rows.values()].filter((row) => placed.has(row.id)) };
          recordPeers();
        }
        else if (layout && "pane" in event) {
          const row = layout.panes.find((p) => p.id === event.pane);
          if (!row) return;
          switch (event.type) {
            case "status": row.status = event.status; break;
            case "pwd": row.cwd = event.pwd; break;
            case "dead": row.dead = event.dead; break;
            case "var": row.vars[event.name] = event.value; break;
            case "var_deleted": delete row.vars[event.name]; break;
            default: return;
          }
          recordPeers();
        }
      };
      const child = openStream(ko, "/client");
      peerClient = child;
      const hello: Api["ClientRequest"] = { type: "hello", name: "ko-pi", webview: false, focused: false, sizing: { type: "disabled" } };
      child.stdin?.write(JSON.stringify(hello) + "\n");
      child.stdout?.on("data", lineReader({ partial: Buffer.alloc(0) }, (line) => {
        try { receive(JSON.parse(line)); } catch {}
      }));
      child.on("close", () => {
        if (peerClient === child) peerClient = undefined;
        if (peerStopped || refused) return;
        delay = reconnectBackoff(delay);
        peerRetry = setTimeout(connect, delay);
        peerRetry.unref();
      });
    };
    connect();
  };

  const childReports = (child: ChildData): Array<{ text: string; at: number }> =>
    entries()
      .filter((entry) => entry.customType === ENTRY_REPORT && entry.data.child === child.session)
      .map((entry) => ({ text: str(entry.data.text), at: Number(entry.data.at) || 0 }));

  type Marks = Map<string, { work: number; report: number; text?: string }>;

  // Where in the branch each child last got work and last reported, in one pass.
  const childMarks = (all = entries()): Marks => {
    const marks: Marks = new Map();
    for (const entry of all) {
      const child = entry.data.child;
      if (typeof child !== "string" || (entry.customType !== ENTRY_WORK && entry.customType !== ENTRY_REPORT)) continue;
      const mark = marks.get(child) ?? { work: -1, report: -1 };
      if (entry.customType === ENTRY_WORK) mark.work = entry.index;
      else {
        mark.report = entry.index;
        mark.text = str(entry.data.text);
      }
      marks.set(child, mark);
    }
    return marks;
  };

  // The parent's rule: the child's last report is later than the last work it was given, or it was given none.
  const childReported = (child: ChildData, marks = childMarks()): boolean => {
    const mark = marks.get(child.session);
    return !mark || mark.work === -1 || mark.report > mark.work;
  };

  const markChildWork = (child: ChildData): void => append(ENTRY_WORK, { child: child.session });

  // The child's rule, about itself.
  const ownReported = (): boolean => {
    const all = entries();
    const work = lastIndex(all, ENTRY_WORK, (data) => data.child === undefined);
    return work === -1 || lastIndex(all, ENTRY_REPORT, (data) => data.child === undefined) > work;
  };

  const markOwnWork = (): void => append(ENTRY_WORK, {});

  const endedAfter = (child: ChildData): boolean => {
    const all = entries();
    const spawned = lastIndex(all, ENTRY_AGENT, (data) => data.role === "subagent" && data.name === child.name);
    return lastIndex(all, ENTRY_ENDED, (data) => data.child === child.session) > spawned;
  };

  // True for the one caller that gets to announce this ending.
  const claimEnding = (child: ChildData): boolean => {
    if (endedAfter(child)) return false;
    append(ENTRY_ENDED, { child: child.session, pane: child.pane.pane });
    return true;
  };

  // ---- the panes ----

  const readInstance = async (): Promise<string> => {
    if (!instance) {
      const version = apiJson(await apiCall("GET", "/version"));
      if (isRecord(version)) instance = str(version.instance);
    }
    return instance;
  };

  type Snapshot = { rows: AgentRow[]; all: AgentRow[]; elsewhere: AgentRow[]; panes: PaneInfo[]; ok: boolean; me: PaneInfo | undefined; depth: number; ancestors: string[] };

  const discovery = async (): Promise<Snapshot> => {
    const [{ ok, panes }] = await Promise.all([listPanesResult(), readInstance()]);
    const byPane = new Map(panes.map((p) => [p.pane, p]));
    const me = panes.find((p) => p.pane === pane);
    const mySession = me?.session ?? "";
    const branch = entries();
    const marks = childMarks(branch);
    const registry = children(branch);
    const registryPeers = peers(branch);
    const pending = new Map<string, PeerData>();
    for (const [id, paneId] of pendingPeers) {
      const row = byPane.get(paneId);
      if (!row || row.dead || piAgent(row.kind)?.session === id) pendingPeers.delete(id);
      else {
        const peer = registryPeers.find((peer) => peer.session === id);
        if (peer) pending.set(paneId, peer);
      }
    }
    const alive = new Map(registry.filter((c) => c.pane.instance === instance).map((c) => [c.pane.pane, c]));
    const reportOf = (child: ChildData): string | undefined => marks.get(child.session)?.text;
    const all: AgentRow[] = [];
    const elsewhere: AgentRow[] = [];
    for (const { pane: p, row: running } of runningRows(panes, me)) {
      const child = alive.get(p.pane);
      const peer = pending.get(p.pane);
      const agent = piAgent(p.kind);
      if (!(agent || peer || (child && p.parent === pane))) continue;
      const parentPane = byPane.get(p.parent);
      const row: AgentRow = {
        ...running,
        id: agent?.session || child?.session || peer?.session || p.pane,
        name: p.name || child?.name || peer?.name || p.title,
        named: p.name !== "" || !!child || !!peer,
        pane: p.pane,
        window: p.window,
        parent: parentPane ? running.parent : (p.parent === pane ? ownSessionId ?? "" : ""),
        depth: ancestorsOf(byPane, p).length,
        cwd: p.cwd,
        ...(p.runtime ? { runtime: p.runtime } : {}),
        canMessage: p.inbox,
        kind: parentPane && (piAgent(parentPane.kind) || parentPane.pane === pane) ? "subagent" : "agent",
      };
      if (child) {
        row.model = child.model;
        row.reported = childReported(child, marks);
        const report = reportOf(child);
        if (report !== undefined) row.report = utf8Prefix(report, MAX_REPORT_BYTES);
      }
      (p.session === mySession ? all : elsewhere).push(row);
    }
    for (const child of registry) {
      const lingering = child.pane.instance === instance ? byPane.get(child.pane.pane) : undefined;
      if (lingering && !lingering.dead) continue;
      const report = reportOf(child);
      all.push({
        id: child.session,
        name: child.name,
        named: true,
        pane: lingering?.pane ?? "",
        window: lingering?.window ?? "",
        status: "ended",
        activity: "",
        parent: ownSessionId ?? "",
        depth: (me ? ancestorsOf(byPane, me).length : 0) + 1,
        self: false,
        cwd: child.cwd,
        ...(child.runtime ? { runtime: child.runtime.name } : {}),
        canMessage: false,
        kind: "subagent",
        relationship: "own",
        state: "ended",
        ended: lingering?.dead ? causeText(lingering.dead) : "its pane is gone",
        model: child.model,
        reported: childReported(child, marks),
        ...(report === undefined ? {} : { report: utf8Prefix(report, MAX_REPORT_BYTES) }),
      });
    }
    const liveSessions = new Set(all.concat(elsewhere).filter((row) => row.state === "running").map((row) => row.id));
    const savedSessions = new Set(registryPeers.length ? sessionFiles(session?.sessionManager.getSessionDir()).map((file) => file.id) : []);
    for (const peer of registryPeers) {
      if (liveSessions.has(peer.session)) continue;
      if (!savedSessions.has(peer.session)) continue;
      all.push({ id: peer.session, name: peer.name, named: true, pane: "", window: "", status: "ended", activity: "", parent: "", depth: 0, self: false, cwd: peer.cwd, canMessage: false, kind: "agent", relationship: "peer", state: "ended", ended: "its pane is gone" });
    }
    const rows = all.filter((a) => !a.self && a.relationship !== "other");
    const ancestors = me ? ancestorsOf(byPane, me) : [];
    return { rows, all, elsewhere, panes, ok, me, depth: ancestors.length, ancestors: ancestors.map((a) => piAgent(a.kind)?.session).filter((session): session is string => !!session) };
  };

  const toolRow = (a: AgentRow) => {
    const { named: _named, self: _self, ...rest } = a;
    return rest;
  };

  const agentName = (a: AgentRow): string => a.name || a.id;

  type Resolution<T extends Addressable = AgentRow> = { agent: T } | { error: string; failure: Extract<AgentOutcome, { ok: false }>['failure'] };

  const decide = <T extends Addressable>(candidates: T[], wanted: string, by: "name" | "id"): Resolution<T> | null => {
    const only = candidates[0];
    if (candidates.length === 1 && only) return { agent: only };
    if (candidates.length > 1) {
      const list = candidates
        .map((a) => `${a.id} (${a.name || a.id})`)
        .sort()
        .join(", ");
      return { error: `"${wanted}" matches several by ${by}: ${list}`, failure: "ambiguous" };
    }
    return null;
  };

  const matchAddress = <T extends Addressable>(rows: T[], { wanted, mention }: ReturnType<typeof normalizeAddress>): Resolution<T> | null => {
    const live = rows.filter((a) => a.state !== "ended");
    const either = <R>(f: (group: T[]) => R | null): R | null => f(live) ?? f(rows);
    const named = either((group) => decide(group.filter((a) => a.named && a.name && a.name.toLowerCase() === wanted.toLowerCase()), wanted, "name"));
    if (!mention && named) return named;
    const exact = either((group) => decide(group.filter((a) => matchesId(a, wanted)), wanted, "id"));
    if (exact) return exact;
    return either((group) => decide(group.filter((a) => matchesId(a, wanted, true)), wanted, "id"));
  };

  const resolveIn = (snapshot: Snapshot, address: ReturnType<typeof normalizeAddress>): Resolution => {
    const { wanted, mention } = address;
    const known = [...snapshot.all, ...snapshot.elsewhere];
    if (wanted.length < MIN_ID_PREFIX &&
        !known.some((a) => matchesId(a, wanted) || (!mention && a.named && a.name.toLowerCase() === wanted.toLowerCase())) &&
        known.some((a) => a.id.startsWith(wanted))) {
      return { error: `id prefixes need at least ${MIN_ID_PREFIX} characters`, failure: "error" };
    }
    const first = matchAddress(snapshot.all, address);
    if (first) return first;
    const second = matchAddress(snapshot.elsewhere, address);
    if (second && "agent" in second) return { error: `${wanted} (${second.agent.id}) is in another session, not this one`, failure: "not_found" };
    if (second) return { error: `${second.error}, none in this session`, failure: second.failure };
    return { error: `no agent session matches "${wanted}"`, failure: "not_found" };
  };

  // ---- sending ----

  // The answer of a post: the state of the message, or why there is none (a transport failure is io).
  type SendOutcome = Api["Posted"] | { state: Api["Error"]["kind"]; message: string };

  const postOnce = async (target: string, kind: SendKind, text: string, id: string, data?: unknown): Promise<SendOutcome> => {
    const body: Api["SendMessage"] = { id, kind, text, ...(data === undefined ? {} : { data }) };
    const answer = await apiCall("POST", `/panes/${target}/messages`, body);
    const posted = apiJson(answer);
    if (isPosted(posted)) return posted;
    const failure = apiError(answer);
    return { state: failure.kind, message: "error" in answer || answer.status !== 200 ? failure.message : "ko answered with no state" };
  };

  // One id for one intent: a delivered or io answer sends the same id again, so the pane reads it once.
  const sendIntent = async (target: string, kind: SendKind, text: string, opts: { id?: string; data?: unknown; once?: boolean } = {}): Promise<SendOutcome> => {
    const id = opts.id ?? mintId();
    let last = await postOnce(target, kind, text, id, opts.data);
    for (let again = 1; !opts.once && again < RESEND_TRIES && (last.state === "delivered" || last.state === "io"); again++) {
      await sleep(envMs("KO_RESEND_MS", 1000));
      last = await postOnce(target, kind, text, id, opts.data);
    }
    return last;
  };

  const deliveryText = (name: string, kind: string, result: SendOutcome, working = false, steerable = false): { ok: boolean; text: string } => {
    switch (result.state) {
      case "queued":
        return { ok: true, text: `queued for ${name}: it is not receiving messages now and reads this when its message stream returns` };
      case "delivered":
        return { ok: true, text: `sent to ${name}: written to its message stream, not yet confirmed` };
      case "acked":
        return kind === "message" && working
          ? { ok: true, text: `queued for ${name}: it is running and reads this when its current turn ends${steerable ? "; to reach it now, use message_agent with mode steer" : ""}` }
          : { ok: true, text: `delivered to ${name}` };
      case "refused":
        return { ok: false, text: `${name} refused the ${kind}: ${result.message}` };
      case "gone":
        return { ok: false, text: `${name} is dead: ${result.message}` };
      default:
        return { ok: false, text: result.message };
    }
  };

  // ---- delivering to this agent ----

  let settled = true;
  let turnEndedByControl = false;
  let workGeneration = 0;

  type Ending =
    | { kind: "awaiting-first-turn" }
    | { kind: "aborted" }
    | { kind: "error"; text: string; notified: boolean; id: string }
    | { kind: "ended"; text: string };
  let ending: Ending = { kind: "ended", text: "" };

  const beginWork = (): void => {
    settled = false;
    if (ending.kind === "awaiting-first-turn") ending = { kind: "ended", text: "" };
  };

  const workStarted = (): void => {
    turnEndedByControl = false;
    workGeneration++;
    beginWork();
  };

  const trimErrorMessage = (msg: string): string => (msg.length > 400 ? `${msg.slice(0, 400)}…` : msg);

  const deliver = (text: string): void => {
    workStarted();
    pi.sendUserMessage(text, { deliverAs: "followUp" });
  };

  const pendingNotices = new Map<string, { from: string; text: string }>();

  const NOTICE_WIDGET_KEY = "ko-notice-pending";

  const renderNoticeWidget = (): void => {
    const ui = session?.ui;
    if (!ui) return;
    if (pendingNotices.size === 0) {
      ui.setWidget(NOTICE_WIDGET_KEY, undefined);
      return;
    }
    const entries = [...pendingNotices.values()];
    ui.setWidget(NOTICE_WIDGET_KEY, (_tui, theme) => ({
      render: (width: number): string[] =>
        entries.map(({ from, text }) => collapsedInbound(width, inboundHeader(from, "notifies"), text, (_color, t) => theme.fg("dim", t))),
      invalidate: () => {},
    }));
  };

  const deliverNotice = (text: string, details: NoticeDetails): void => {
    const from = 'job' in details ? details.job.name : details.agent.name;
    const noticeId = mintId();
    pendingNotices.set(noticeId, { from, text });
    renderNoticeWidget();
    pi.sendMessage({ customType: NOTICE_CUSTOM_TYPE, content: `${noticeHeader(from)}\n${text}`, display: true, details: { from, noticeId, ...details } satisfies NoticeDetails }, { deliverAs: "steer", triggerTurn: true });
  };

  const labelOf = (from: Api["Sender"]): string => (from.type === "pane" ? from.name || from.session || from.pane : "the user");

  const childRef = (child: ChildData): AgentRef => ({ name: child.name, session: child.session, pane: child.pane.pane });

  const refOf = (from: Api['Sender']): AgentRef => ({ name: labelOf(from), ...(from.type === 'pane' ? { session: from.session, pane: from.pane } : {}) });

  const deliverAgentMessage = (agent: AgentRef, relation: Relation, text: string, work: boolean, runtime?: string): void => {
    const from = agent.name, header = senderHeader(from, relation, runtime);
    pi.sendMessage(
      { customType: MESSAGE_CUSTOM_TYPE, content: `${header}\n${text}`, display: true, details: { from, work, agent, body: text, inbound: { form: 'message', relation, ...(runtime ? { runtime } : {}) } } satisfies MessageDetails },
      { deliverAs: "followUp", triggerTurn: true },
    );
  };

  // A message from a pane that has a pi identity gets the sender header; any other is plain text.
  const deliverMessage = (held: Held): void => {
    if (!held.text) return;
    const { from, relation } = held;
    if (from.type !== "pane" || !relation || !(from.name || from.session)) {
      deliver(held.text);
      return;
    }
    deliverAgentMessage(refOf(from), relation, held.text, relation === "parent", held.runtime);
  };

  const interrupted: Held[] = [];

  const reportNotice = (child: ChildData, text: string): string => {
    const budget = MAX_NOTICE_BYTES - Buffer.byteLength(PARENT_GUIDANCE, "utf8");
    if (Buffer.byteLength(text, "utf8") <= budget) return text + PARENT_GUIDANCE;
    const suffix = `\n\nfull report: read_report(${JSON.stringify(child.name)})`;
    return utf8Prefix(text, budget - Buffer.byteLength(suffix, "utf8")) + suffix + PARENT_GUIDANCE;
  };

  const currentChild = (sessionId: string, paneId: string): ChildData | undefined =>
    children().find((c) => (sessionId !== "" && c.session === sessionId) || (paneId !== "" && c.pane.pane === paneId));

  const handleNotice = (id: string, from: Api["Sender"], text: string, data: unknown): void => {
    const report = isRecord(data) && data.report === true;
    const child = from.type === "pane" ? currentChild(from.session ?? "", from.pane) : undefined;
    if (!report || !child) {
      if (text) deliverNotice(text, { inbound: { form: 'notice' }, agent: refOf(from), body: text });
      return;
    }
    if (entries().some((entry) => entry.customType === ENTRY_REPORT && entry.data.id === id)) return;
    append(ENTRY_REPORT, { child: child.session, name: child.name, text, id });
    deliverNotice(reportNotice(child, text), { inbound: { form: 'report', relation: 'child' }, agent: childRef(child), body: text });
  };

  const screenTail = async (route: string): Promise<string | undefined> => {
    const body = apiBody(await apiCall("GET", route));
    return body === undefined ? undefined : utf8Suffix(body, TAIL_BYTES);
  };

  const announceEnding = async (child: ChildData, end: Api["End"] | { type: "missing" }): Promise<void> => {
    if (!claimEnding(child)) return;
    const reported = childReported(child);
    const how = end.type === "dead" ? causeText(end) : end.type === "gone" ? "its pane was removed" : "its pane is gone";
    let body = `subagent ${quote(child.name)} ended: ${how}; it had ${reported ? "reported" : "not reported on its last work"}`;
    if (!reported) {
      const tail = end.type === "dead" ? await screenTail(`/panes/${child.pane.pane}/screen?history=all`) : undefined;
      if (tail !== undefined) body += `\n--- last ${TAIL_BYTES} bytes of its screen ---\n${tail}`;
      body += "\nmessage it to continue it, or stop_agent to end it";
    }
    deliverNotice(body, { inbound: { form: 'ended', relation: 'child', reported }, agent: childRef(child), body });
  };

  const handleEnded = async (source: string, end: Api["End"]): Promise<void> => {
    await readInstance();
    const target = children().find((c) => c.pane.pane === source && c.pane.instance === instance);
    if (target) await announceEnding(target, end);
  };

  const handleIncoming = async (m: Api["Message"]): Promise<"ack" | "refuse"> => {
    switch (m.kind) {
      case "user":
        if (m.text) deliver(m.text);
        return "ack";
      case "message":
        deliverMessage({ from: m.from, relation: m.relation, text: m.text, runtime: runtimeOf(m.data) });
        return "ack";
      case "steer": {
        if (!m.text) return "ack";
        const from = labelOf(m.from);
        workStarted();
        // pi drains followUp only once the agent has decided to stop; steer joins the run under way.
        pi.sendMessage(
          { customType: STEER_CUSTOM_TYPE, content: steerHeader(from) + m.text, display: true, details: { from, work: m.relation === "parent", agent: refOf(m.from), body: m.text, inbound: { form: 'steer', ...(m.relation ? { relation: m.relation } : {}) } } satisfies SteerDetails },
          { deliverAs: "steer", triggerTurn: true },
        );
        return "ack";
      }
      case "interrupt": {
        turnEndedByControl = true;
        const busy = !settled;
        // pi's extension abort returns void before the active tool and run end.
        session?.abort();
        const held = { from: m.from, relation: m.relation, text: m.text, runtime: runtimeOf(m.data) };
        if (busy) interrupted.push(held);
        else deliverMessage(held);
        return "ack";
      }
      case "stop":
        interrupted.length = 0;
        turnEndedByControl = true;
        leaving = "control";
        return "ack";
      case "notice":
        try {
          handleNotice(m.id, m.from, m.text, m.data);
        } catch {
          return "refuse";
        }
        return "ack";
      case "ended":
        if (m.from.type === "pane") await handleEnded(m.from.pane, m.end);
        return "ack";
    }
  };

  // ---- the message stream: ko api --stream /panes/$KO_PANE/messages ----

  const received = (): string[] => (globalThis.__koPiExtensionReceived ??= []);

  let queue: Promise<void> = Promise.resolve();

  const answerStream = (id: string, type: "ack" | "refuse"): void => {
    receiver.write(JSON.stringify({ type, id } satisfies Api["StreamRequest"]) + "\n");
  };

  const onStreamLine = (line: string): void => {
    let decoded: unknown;
    try {
      decoded = JSON.parse(line);
    } catch {
      return;
    }
    if (!isMessage(decoded)) {
      if (isRecord(decoded) && typeof decoded.id === "string") answerStream(decoded.id, "refuse");
      return;
    }
    const message = decoded;
    queue = queue.then(async () => {
      if (received().includes(message.id)) {
        answerStream(message.id, "ack");
        return;
      }
      let verdict: "ack" | "refuse";
      try {
        verdict = await handleIncoming(message);
      } catch {
        verdict = "refuse";
      }
      if (verdict === "ack") {
        const ring = received();
        ring.push(message.id);
        if (ring.length > RECEIVED_RING) ring.splice(0, ring.length - RECEIVED_RING);
      }
      answerStream(message.id, verdict);
      if (verdict === "ack" && message.kind === "stop") session?.shutdown();
    });
  };

  let receiverHold: ReceiverHold | null = null;
  let receiverData: ((chunk: Buffer) => void) | null = null;
  let receiverTimer: NodeJS.Timeout | null = null;
  let receiverBackoff = 0;
  let receiverActive = false;
  const receiverExit = (): void => {
    receiverDetach();
    receiverHold = null;
    if (!receiverActive) return;
    receiverBackoff = reconnectBackoff(receiverBackoff);
    receiverTimer = setTimeout(receiverOpen, receiverBackoff);
    receiverTimer.unref();
  };
  const receiverDetach = (): void => {
    if (!receiverHold) return;
    if (receiverData) receiverHold.child.stdout?.removeListener("data", receiverData);
    receiverHold.child.stdout?.pause();
    receiverHold.child.removeListener("exit", receiverExit);
    receiverHold.child.removeListener("error", receiverExit);
  };
  const receiverAttach = (next: ReceiverHold): void => {
    receiverHold = next;
    receiverData = lineReader(next, (line) => { receiverBackoff = 0; onStreamLine(line); });
    next.child.stdout?.on("data", receiverData);
    next.child.stdout?.resume();
    next.child.once("exit", receiverExit);
    next.child.once("error", receiverExit);
  };
  function receiverOpen(): void {
    receiverTimer = null;
    const target = pane ? `/panes/${pane}/messages` : null;
    if (receiverActive && ko && target) receiverAttach({ child: openStream(ko, target), partial: Buffer.alloc(0) });
  }
  const receiver = {
    start(): void {
      receiverActive = true;
      const held = globalThis.__koPiExtensionReceiver;
      globalThis.__koPiExtensionReceiver = undefined;
      if (held && held.child.exitCode === null && held.child.signalCode === null) receiverAttach(held);
      else receiverOpen();
    },
    stop(park: boolean): void {
      receiverActive = false;
      if (receiverTimer) clearTimeout(receiverTimer);
      receiverTimer = null;
      const held = receiverHold;
      receiverDetach();
      receiverHold = null;
      if (!held) return;
      if (park) globalThis.__koPiExtensionReceiver = held;
      else held.child.kill();
    },
    write(line: string): void { receiverHold?.child.stdin?.write(line); },
  };

  const jobRecords = new Map<string, { type: "running" } | { type: "finished"; timer: NodeJS.Timeout }>();
  let jobRecordQueue = Promise.resolve();
  const writeJobRecord = (id: string | undefined, state: "idle" | "working" | "done" | "error" | "clear", title?: string, message?: string): boolean => {
    if (!active) return false;
    const clean = (text: string, bytes: number): string => utf8Prefix(replaceControlCharacters(text).replace(/\s+/g, " ").trim(), bytes);
    const recordId = id === undefined ? "job" : `job/${id}`;
    const cleanedTitle = title === undefined ? undefined : clean(title, MAX_JOB_TITLE_BYTES);
    const cleanedMessage = message === undefined ? undefined : clean(message, MAX_JOB_MESSAGE_BYTES);
    const report: Api["StatusReport"] = state === "clear" ? { type: "clear", id: recordId } : {
      type: "set", id: recordId, state,
      ...(cleanedTitle ? { title: cleanedTitle } : {}),
      ...(cleanedMessage ? { msg: cleanedMessage } : {}),
    };
    const path = `/panes/${pane}/status`;
    jobRecordQueue = jobRecordQueue.then(async () => { await apiCall("POST", path, report); }).catch(() => {});
    return true;
  };
  const clearJobRecord = (id: string): void => {
    const record = jobRecords.get(id);
    if (record?.type === "finished") clearTimeout(record.timer);
    jobRecords.delete(id);
    writeJobRecord(id, "clear");
  };
  const detachJobRecords = (): void => {
    for (const record of jobRecords.values()) if (record.type === "finished") clearTimeout(record.timer);
    jobRecords.clear();
  };
  const clearJobRecords = (): void => {
    detachJobRecords();
    writeJobRecord(undefined, "clear");
  };
  const reportJob = (job: BackgroundJob): void => {
    const id = job.id;
    if (!jobRecords.has(id)) {
      if (jobRecords.size >= 32) {
        const oldestFinished = [...jobRecords].find(([, record]) => record.type === "finished");
        if (!oldestFinished) return;
        clearJobRecord(oldestFinished[0]);
      }
    }
    if (job.state.type === "running") {
      if (writeJobRecord(id, jobRecordState(job), job.mode.name, job.command)) jobRecords.set(id, { type: "running" });
    }
    else {
      if (!writeJobRecord(id, job.state.end.type === "exit" && job.state.end.code === 0 ? "done" : "error", job.mode.name, jobEndText(job.state.end))) return;
      const timer = setTimeout(() => clearJobRecord(id), envMs("KO_JOB_RECORD_LINGER_MS", 5000));
      timer.unref();
      jobRecords.delete(id);
      jobRecords.set(id, { type: "finished", timer });
    }
  };
  const refreshJobRecords = (): void => {
    for (const [id, record] of jobRecords) {
      if (record.type !== "running") continue;
      const job = registry?.jobs.get(id);
      if (job && isBackgroundJob(job)) writeJobRecord(id, jobRecordState(job), job.mode.name, job.command);
    }
  };
  const savedJobs: unknown = Reflect.get(globalThis, JOBS);
  let registry = isJobRegistry(savedJobs) ? savedJobs : undefined;
  const jobRegistry = (): JobRegistry => {
    if (!registry) {
      registry = createJobRegistry(ownSessionId ?? "");
      Reflect.set(globalThis, JOBS, registry);
    }
    return registry;
  };
  const streamInterval = (): number => envMs("KO_STREAM_INTERVAL_MS", 5000);
  const untilDue = (stream: BackgroundJob["mode"]["stream"]): number => stream.lastBatch + streamInterval() - performance.now();
  let agentWorking = false;
  const sendStream = (job: BackgroundJob, body: ReturnType<typeof streamBatch>): void => {
    pi.sendMessage({
      customType: STREAM_CUSTOM_TYPE,
      content: `job ${JSON.stringify(job.mode.name)} output (job ${job.id})\n${body.content}`,
      display: true,
      details: { from: job.mode.name, job: jobReference(job), batch: body.batch, omitted: body.omitted, cut: body.cut } satisfies StreamDetails,
    }, { deliverAs: "steer", triggerTurn: true });
  };
  const flushJob = (job: BackgroundJob): void => {
    const stream = job.mode.stream;
    if (!stream.lines.length) return;
    const batch = streamBatch(stream.lines, job.mode.log, stream.dropped, stream.cut);
    stream.lastBatch = performance.now();
    sendStream(job, batch);
    stream.lines = [];
    stream.dropped = 0;
    stream.cut = false;
    stream.held = Buffer.byteLength(stream.split.line) + stream.carry.length;
  };
  const scheduleFlush = (job: BackgroundJob): void => {
    const stream = job.mode.stream;
    if (agentWorking || !stream.lines.length || stream.timer || !registry?.owner) return;
    stream.timer = setTimeout(() => {
      stream.timer = null;
      if (agentWorking) return;
      try { flushJob(job); } catch { scheduleFlush(job); }
    }, Math.max(0, untilDue(stream)));
    stream.timer.unref();
  };
  const backgroundJobs = (): BackgroundJob[] => [...registry?.jobs.values() ?? []].filter(isBackgroundJob);
  const jobNamed = (wanted: string): BackgroundJob | undefined => {
    const matches = backgroundJobs().reverse().filter((job) => job.mode.name.toLowerCase() === wanted.toLowerCase());
    return matches.find((job) => job.state.type === "running") ?? matches[0];
  };
  const finishWorking = (): void => {
    agentWorking = false;
    for (const job of backgroundJobs()) if (streams(job)) scheduleFlush(job);
  };
  const flushStreams = (): void => {
    for (const job of backgroundJobs()) {
      if (!streams(job)) continue;
      detachJob(job);
      if (untilDue(job.mode.stream) <= 0) flushJob(job);
    }
  };
  const localExec: JobOperations = {
    async exec(command, cwd, options) {
      return localJob(jobRegistry(), getShellConfig(pi.getSettings().shellPath), command, cwd, options);
    },
  };
  const bashOperations = (r: Routed): JobOperations => ({
    exec: (command, cwd, options) => routedJob(jobRegistry(), r, command, cwd, options),
  });
  const adoptJobs = (): void => {
    let stopped: string[] | undefined;
    if (registry && (registry.shape !== JOB_SHAPE || registry.session !== (ownSessionId ?? ""))) {
      detachKeys(registry);
      stopped = registry.stopAll();
      registry = undefined;
      Reflect.deleteProperty(globalThis, JOBS);
    }
    const owner = jobRegistry();
    clearJobRecords();
    owner.owner = {
      onStart: reportJob,
      clearRecords: () => {
        if (active) apiCallSync("POST", `/panes/${pane}/status`, { type: "clear", id: "job" } satisfies Api["StatusReport"]);
      },
      onLines(job) { if (streams(job)) scheduleFlush(job); },
      onEnd(job) {
        if (jobRecords.has(job.id)) reportJob(job);
        detachJob(job);
        if (job.state.type !== "ended" || job.state.announced) return;
        if (job.state.end.type !== "stopped") {
          if (streams(job)) flushJob(job);
          const tail = jobTail(job);
          deliverNotice(`job ${quote(job.mode.name)} (${job.id}) ${jobEndText(job.state.end)}\n--- last ${TAIL_BYTES} bytes of its output ---\n${tail}\nlog: ${job.mode.log}`, { kind: "job", job: { ...jobReference(job), end: job.state.end }, tail });
        }
        job.state.announced = true;
        job.tail = Buffer.alloc(0);
        pruneJobs(owner);
      },
    };
    for (const job of backgroundJobs()) {
      if (job.state.type === "running") reportJob(job);
      if (job.state.type === "ended" && !job.state.announced) {
        try { owner.owner?.onEnd(job); } catch {}
      } else if (job.state.type !== "ended" && streams(job)) scheduleFlush(job);
    }
    if (stopped) {
      const text = `${stopped.length} async_bash jobs of the previous ko-pi version were stopped at /reload: ${stopped.join(", ")}`;
      try { deliverNotice(text, { inbound: { form: "notice" }, agent: { name: "ko-pi" }, body: text }); } catch {}
    }
  };
  type BashCall = { type: "bash"; hint: "waiting" | "shown"; cancel(reason?: ShutdownReason): void; move(reason: "timeout" | "key" | "reload"): boolean };
  type PendingCall = BashCall | { type: "async_bash"; cancel(reason?: ShutdownReason): void };
  const calls = new Set<PendingCall>();
  const updateHint = (): void => {
    if (session?.hasUI) session.ui.setWidget("ko-job-hint", [...calls].some((call) => call.type === "bash" && call.hint === "shown") ? [rawKeyHint("ctrl+b", "moves this command to a job")] : undefined);
  };
  const handoff = (ops: JobOperations): BashOperations => ({
    exec(command, cwd, options) {
      validateJobTimeout(options.timeout);
      const started = performance.now();
      const moveMs = envMs("KO_JOB_MOVE_MS", 60000);
      const controller = new AbortController();
      const abort = (): void => controller.abort();
      options.signal?.addEventListener("abort", abort, { once: true });
      if (options.signal?.aborted) abort();
      return new Promise((resolve, reject) => {
        let job: Job | undefined;
        let pendingReload = false;
        let moveTimer: NodeJS.Timeout | undefined;
        let hintTimer: NodeJS.Timeout | undefined;
        const cleanup = (): void => {
          clearTimeout(moveTimer);
          clearTimeout(hintTimer);
          options.signal?.removeEventListener("abort", abort);
          if (calls.delete(call)) updateHint();
        };
        const call: BashCall = {
          type: "bash", hint: "waiting", cancel: abort,
          move(reason: "timeout" | "key" | "reload"): boolean {
            if (!job && reason === "reload") { pendingReload = true; cleanup(); }
            if (!job || isBackgroundJob(job) || job.state.type === "ended" || controller.signal.aborted) return false;
            try {
              const moved = promoteJob(jobRegistry(), job, { type: "bash", move: reason });
              if (options.timeout !== undefined && !job.deadline) armJobDeadline(job, options.timeout, started + options.timeout * 1000);
              cleanup();
              reject(new MovedToJob(moved, reason));
              return true;
            } catch (error) {
              cleanup();
              controller.abort();
              reject(error);
              return false;
            }
          },
        };
        calls.add(call);
        void ops.exec(command, cwd, {
          ...options, signal: controller.signal,
          timeout: options.timeout !== undefined && options.timeout * 1000 < moveMs ? options.timeout : undefined,
          onStart(startedJob) {
            job = startedJob;
            if (pendingReload) { call.move("reload"); return; }
            hintTimer = setTimeout(() => { call.hint = "shown"; updateHint(); }, Math.max(0, Math.ceil(started + envMs("KO_JOB_HINT_MS", 3000) - performance.now())));
            hintTimer.unref();
            if (options.timeout === undefined || options.timeout * 1000 >= moveMs) {
              moveTimer = setTimeout(() => call.move("timeout"), Math.max(0, Math.ceil(started + moveMs - performance.now())));
              moveTimer.unref();
            }
          },
        }).then(resolve, reject).finally(cleanup);
      });
    },
  });
  const executeBash = async (definition: ReturnType<typeof createBashToolDefinition>, ...args: Parameters<ReturnType<typeof createBashToolDefinition>["execute"]>) => {
    try {
      return await definition.execute(...args);
    } catch (error) {
      if (!(error instanceof MovedToJob)) throw error;
      const why = error.reason === "timeout" ? `still running after ${envMs("KO_JOB_MOVE_MS", 60000) / 1000} s` : "still running";
      return { content: [{ type: "text" as const, text: `${why}; it continues as job ${error.job.id}; a notice arrives when it ends; output so far:\n${jobTail(error.job)}\nlog: ${error.job.mode.log}` }], details: undefined };
    }
  };
  const registerLocalBash = (ctx: ExtensionContext): boolean => {
    if (routed || !pi.getAllTools().some((tool) => tool.name === "bash" && tool.sourceInfo.path.startsWith("builtin:"))) return false;
    const definition = createBashToolDefinition(ctx.cwd);
    pi.registerTool({
      ...definition,
      async execute(id, params, signal, onUpdate, context) {
        const settings = pi.getSettings();
        return executeBash(createBashToolDefinition(context.cwd, {
          operations: handoff(localExec), shellPath: settings.shellPath, commandPrefix: settings.shellCommandPrefix,
        }), id, params, signal, onUpdate, context);
      },
    });
    return true;
  };

  // ---- the parent: reports, the watch, the exit notice ----

  let parentPane = "";
  let tick: NodeJS.Timeout | null = null;
  let ticking = false;

  const leave = (): void => {
    leaving = "control";
    turnEndedByControl = true;
    session?.shutdown();
  };

  // One id for one notice: every attempt at it carries the same id.
  const statusNotice = async (text: string, id: string): Promise<boolean> => {
    if (!parentPane) return false;
    const result = await sendIntent(parentPane, "notice", utf8Prefix(text, MAX_NOTICE_BYTES), { id });
    return result.state === "acked" || result.state === "queued";
  };

  let exitNoticeId = "";

  type OwnReport = { id: string; text: string };

  // Every report that has no sent mark yet, oldest first.
  const pendingReports = (): OwnReport[] => {
    const all = entries();
    const sent = new Set(all.filter((entry) => entry.customType === ENTRY_SENT).map((entry) => entry.data.id));
    return all
      .filter((entry) => entry.customType === ENTRY_REPORT && entry.data.child === undefined && !sent.has(entry.data.id))
      .map((entry) => ({ id: str(entry.data.id), text: str(entry.data.text) }));
  };

  const sendingReports = new Set<string>();

  const sendReport = async (report: OwnReport, once: boolean): Promise<void> => {
    if (!parentPane || sendingReports.has(report.id)) return;
    if (entries().some((entry) => entry.customType === ENTRY_SENT && entry.data.id === report.id)) return;
    sendingReports.add(report.id);
    try {
      const result = await sendIntent(parentPane, "notice", report.text, { id: report.id, data: { report: true }, once });
      if (result.state === "acked") append(ENTRY_SENT, { id: report.id });
      else if (result.state === "refused") append(ENTRY_SENT, { id: report.id, refused: true });
    } finally {
      sendingReports.delete(report.id);
    }
  };

  const watchParent = async (): Promise<void> => {
    if (!edge) return;
    const { ok, panes } = await listPanesResult(2000);
    if (!ok) return;
    const me = panes.find((p) => p.pane === pane);
    if (!me?.parent) return;
    parentPane = me.parent;
    const parent = panes.find((p) => p.pane === me.parent);
    if (parent && !parent.dead && parent.sessionVar === edge.parent) return;
    stopTick();
    leave();
  };

  const stopTick = (): void => {
    if (tick) clearInterval(tick);
    tick = null;
  };

  const startTick = (): void => {
    if (!edge) return;
    stopTick();
    tick = setInterval(() => {
      if (ticking) return;
      ticking = true;
      void (async () => {
        try {
          await watchParent();
          for (const report of pendingReports()) await sendReport(report, true);
        } finally {
          ticking = false;
        }
      })();
    }, envMs("KO_PARENT_POLL_MS", 5000));
    tick.unref();
  };

  const ownLiveWork = async (): Promise<boolean | undefined> => {
    if (backgroundJobs().some((job) => !serviceJob(job) && job.state.type !== "ended")) return true;
    const snapshot = await listPanesResult();
    if (!snapshot.ok) return undefined;
    await readInstance();
    const marks = childMarks();
    return children().some((child) => {
      const row = child.pane.instance === instance ? snapshot.panes.find((p) => p.pane === child.pane.pane) : undefined;
      return !!row && !row.dead && !childReported(child, marks);
    });
  };

  const exitNoticeText = (): string | undefined => {
    const name = quote(pi.getSessionName() ?? "");
    if (ownReported()) return undefined;
    if (ending.kind === "awaiting-first-turn") return `subagent ${name} is exiting before its first turn ran`;
    if (ending.kind === "error" && !ending.notified) {
      return `subagent ${name} is exiting without a report on its last work: its last turn failed: ${trimErrorMessage(ending.text)}`;
    }
    return `subagent ${name} is exiting without a report on its last work`;
  };

  // ---- spawning ----

  const validateModel = async (model: string | undefined): Promise<string | null> => {
    if (!model) return null;
    const res = await runCommand("pi", ["--list-models"], { timeoutMs: 10000 });
    if (!res.ok) return `could not validate model ${quote(model)}: pi --list-models: ${res.error}`;
    return validateModelRows(model, modelRows(res.out));
  };

  const nameClaims = new Set<string>();
  const claimName = (name: string): boolean => {
    const key = name.toLowerCase();
    if (nameClaims.has(key)) return false;
    nameClaims.add(key);
    return true;
  };
  const releaseName = (name: string): void => {
    nameClaims.delete(name.toLowerCase());
  };

  const restartLocks = new Map<string, Promise<unknown>>();

  const withRestartLock = <T>(key: string, fn: () => Promise<T>): Promise<T> => {
    const previous = restartLocks.get(key) ?? Promise.resolve();
    const run = previous.then(fn, fn);
    restartLocks.set(
      key,
      run.then(
        () => undefined,
        () => undefined,
      ),
    );
    return run;
  };

  const trustedCwd = async (cwd: string): Promise<string | undefined> => {
    if (!session?.isProjectTrusted()) return undefined;
    const [mine, theirs] = await Promise.all([gitCommonDir(session.cwd), gitCommonDir(cwd)]);
    return mine !== undefined && mine === theirs ? cwd : undefined;
  };

  type Plan = {
    name: string;
    session: string;
    model: string;
    cwd: string;
    runtime?: ChildRuntime;
    runtimeInfo?: Api["RuntimeInfo"];
    task: string;
    mode: { kind: "fresh" } | { kind: "continue"; file: string } | { kind: "copy"; file: string };
    toplevel: boolean;
    koSession: string;
  };

  const taskVar = (task: string): unknown => ({ text: task, from: { session: ownSessionId, name: pi.getSessionName() ?? "", pane } });

  const taskTooLarge = (task: string): boolean => Buffer.byteLength(JSON.stringify(taskVar(task)), "utf8") > MAX_TASK_BYTES;

  const sessionFiles = (sessionDir?: string): { id: string; path: string }[] => {
    const directories = new Set(sessionDir ? [sessionDir] : []);
    const roots = [join(getAgentDir(), "sessions"), join(getAgentDir(), "ko-subagents"), ...(sessionDir ? [dirname(sessionDir)] : [])];
    for (const root of new Set(roots)) {
      try {
        for (const entry of readdirSync(root, { withFileTypes: true })) {
          if (entry.isDirectory() || entry.isSymbolicLink()) directories.add(join(root, entry.name));
        }
      } catch {}
    }
    const files: { id: string; path: string }[] = [];
    for (const directory of directories) {
      try {
        for (const file of readdirSync(directory)) {
          const id = /_([^_]+)\.jsonl$/.exec(file)?.[1];
          if (id) files.push({ id, path: join(directory, file) });
        }
      } catch {}
    }
    return files;
  };

  const formatModel = (provider: string, id: string, thinking?: string): string => `${provider}/${id}${thinking === undefined ? "" : `:${thinking}`}`;
  const callerModel = (ctx: ExtensionContext): string | undefined => ctx.model ? formatModel(ctx.model.provider, ctx.model.id, pi.getThinkingLevel()) : undefined;

  const readSavedSession = (file: { id: string; path: string }, registry: ExtensionContext["modelRegistry"]): { cwd: string; model: string | undefined } | { error: string } => {
    let content: string;
    try { content = readFileSync(file.path, "utf8"); }
    catch (error) { return { error: `could not read session file ${file.path}: ${error instanceof Error ? error.message : String(error)}` }; }
    let header: unknown;
    try { header = JSON.parse(content.split("\n", 1)[0] ?? ""); }
    catch { return { error: `invalid session header: ${file.path}` }; }
    if (!isRecord(header) || header.type !== "session" || header.id !== file.id || typeof header.cwd !== "string") return { error: `invalid session header: ${file.path}` };
    try {
      const entries = parseSessionEntries(content);
      const branch = SessionManager.inMemory(header.cwd, undefined, entries).getBranch();
      const change = branch.findLast((entry) => entry.type === "model_change" && typeof entry.provider === "string" && typeof entry.modelId === "string");
      // pi 1.5.0 does not export getBranchSelection from core/virtual-models.js.
      const virtual = change?.type === "model_change" && registry.find(change.provider, change.modelId)?.api === "pi-virtual";
      let model: { provider: string; modelId: string } | undefined;
      let thinking: string | undefined;
      for (const entry of branch) {
        if (entry.type === "thinking_level_change") thinking = entry.thinkingLevel;
        if (entry.type === "model_change" && typeof entry.provider === "string" && typeof entry.modelId === "string") model = entry;
        if (entry.type === "message" && entry.message.role === "assistant" && entry.message.api !== "pi-virtual" && typeof entry.message.provider === "string" && typeof entry.message.model === "string") {
          model = virtual && change?.type === "model_change" ? change : { provider: entry.message.provider, modelId: entry.message.model };
        }
      }
      return { cwd: header.cwd, model: model ? formatModel(model.provider, model.modelId, thinking) : undefined };
    } catch { return { error: `invalid session file: ${file.path}` }; }
  };

  const createPane = async (plan: Plan): Promise<{ placement: Api["Placement"] } | { error: string }> => {
    const inside = plan.runtime?.mode === "inside";
    if (!ko) return { error: "ko is not on PATH" };
    let trusted = await trustedCwd(plan.cwd);
    if (trusted && inside && plan.runtime) {
      const info = plan.runtimeInfo ?? (await fetchRuntime(plan.runtime.name));
      trusted = "error" in info ? undefined : mapHostPath(info.paths, trusted) ?? info.cwd;
    }
    const argv = [
      inside ? "ko" : ko, "shell", "--", pi.getFlag("harness") === undefined ? "ko-pi" : "koa",
      ...(pi.getFlag("harness") === "koa-browser" ? ["--browser"] : []),
      ...(plan.runtime?.mode === "routed" ? ["--runtime", plan.runtime.name] : []),
      ...(plan.mode.kind === "continue" ? ["--session", plan.mode.file] : ["--session-id", plan.session]),
      "--name", plan.name,
      "--model", plan.model,
      // Copies pi's unexported getDefaultSessionDirPath in core/session-manager.js.
      ...(plan.toplevel || inside ? [] : ["--session-dir", join(getAgentDir(), "ko-subagents", `--${resolve(plan.cwd).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`)]),
      ...(plan.mode.kind === "copy" ? ["--fork", plan.mode.file] : []),
    ];
    const env: Api["Variable"][] = [
      { name: "KO_AGENT_SESSION", value: plan.session },
      ...(plan.toplevel ? [] : [{ name: "KO_AGENT_PARENT_SESSION", value: ownSessionId ?? "" }]),
      ...(trusted ? [{ name: "KO_AGENT_TRUSTED_CWD", value: trusted }] : []),
    ];
    const body: Api["NewWindow"] = {
      name: plan.name,
      cwd: plan.cwd,
      ...(inside && plan.runtime ? { runtime: plan.runtime.name } : {}),
      command: { type: "argv", argv },
      env,
      ...(plan.toplevel ? { session: plan.koSession } : { parent: pane ?? undefined, close: "on_exit" as const }),
      ...(plan.task ? { vars: { [VAR_TASK]: taskVar(plan.task) } } : {}),
    };
    const answer = await apiCall("POST", "/panes", body, envMs("KO_SPAWN_TIMEOUT_MS", 5000));
    const placement = apiJson(answer);
    return isPlacement(placement) ? { placement } : { error: apiError(answer).message };
  };

  const recordAgent = (plan: Plan, placement: Api["Placement"]): void => {
    if (plan.toplevel) {
      if (recordsPeers) {
        append(ENTRY_AGENT, { role: "peer", name: plan.name, session: plan.session, cwd: plan.cwd });
        pendingPeers.set(plan.session, placement.pane);
      }
      return;
    }
    append(ENTRY_AGENT, {
      role: "subagent",
      name: plan.name,
      session: plan.session,
      model: plan.model,
      fork: plan.mode.kind === "copy",
      cwd: plan.cwd,
      ...(plan.runtime ? { runtime: plan.runtime } : {}),
      pane: { instance, pane: placement.pane },
    });
    if (plan.task) append(ENTRY_WORK, { child: plan.session });
  };

  const restartAgent = (child: AgentData, task: string): Promise<{ placement: Api["Placement"] } | { running: AgentRow } | { error: string }> =>
    withRestartLock(child.session, async () => {
      const snapshot = await discovery();
      if (!snapshot.ok) return { error: "could not read the layout" };
      const row = snapshot.all.find((a) => a.id === child.session);
      if (row && row.state === "running") return { running: row };
      const files = sessionFiles(session?.sessionManager.getSessionDir()).filter((file) => file.id === child.session);
      if (files.length > 1) return { error: `several session files have id ${child.session}` };
      const file = files[0];
      if (!session) return { error: "no active session" };
      const saved = file ? readSavedSession(file, session.modelRegistry) : undefined;
      if (saved && "error" in saved) return saved;
      if (child.role === "peer" && !file) return { error: `session file is missing for ${child.session}` };
      let role: Pick<Plan, "toplevel" | "cwd" | "runtime"> & { model: string | undefined };
      switch (child.role) {
        case "peer": role = { toplevel: true, cwd: saved?.cwd ?? child.cwd, model: saved?.model ?? callerModel(session) }; break;
        case "subagent": role = { toplevel: false, cwd: child.cwd, runtime: child.runtime, model: saved?.model ?? child.model }; break;
      }
      if (!role.model) return { error: "caller has no model; specify model" };
      const plan: Plan = { name: child.name, session: child.session, ...role, model: role.model, task, mode: file ? { kind: "continue", file: file.path } : { kind: "fresh" }, koSession: snapshot.me?.session ?? "" };
      const made = await createPane(plan);
      if ("error" in made) return made;
      recordAgent(plan, made.placement);
      return made;
    });

  // ---- the task and the endings that happened while this agent was away ----

  const deliverTask = async (): Promise<void> => {
    if (!pane) return;
    const { ok, panes } = await listPanesResult();
    if (startupCancelled || !ok) return;
    const me = panes.find((p) => p.pane === pane);
    if (me?.parent) parentPane = me.parent;
    const task = me?.task;
    if (!isRecord(task)) return;
    const text = str(task.text);
    const from = isRecord(task.from) ? task.from : {};
    if (text.trim()) {
      if (edge && from.session === edge.parent) {
        markOwnWork();
        deliver(text);
        ending = { kind: "awaiting-first-turn" };
      } else {
        deliverAgentMessage({ name: str(from.name) || str(from.session) || "another agent", ...(typeof from.session === "string" ? { session: from.session } : {}), ...(typeof from.pane === "string" ? { pane: from.pane } : {}) }, "sibling", text, false);
      }
    }
    if (!startupCancelled) await apiCall("DELETE", varPath(VAR_TASK));
  };

  const reconcileChildren = async (): Promise<void> => {
    const { ok, panes } = await listPanesResult();
    if (startupCancelled || !ok) return;
    await readInstance();
    for (const child of children()) {
      if (startupCancelled) return;
      if (endedAfter(child)) continue;
      const row = child.pane.instance === instance ? panes.find((p) => p.pane === child.pane.pane) : undefined;
      if (row && !row.dead) continue;
      await announceEnding(child, row?.dead ? { type: "dead", ...row.dead } : { type: "missing" });
    }
  };

  // ---- rendering ----

  const inboundExpanded = new Map<string, boolean>();

  const renderInbound = (message: Parameters<MessageRenderer>[0], theme: Pick<Theme, "fg">, sender: string | undefined, verb: string | undefined, body: string | undefined) => {
    if (body === undefined) return { render: (width: number) => wrapTextWithAnsi(contentText(message.content), width), invalidate: () => {} };
    const key = JSON.stringify([message.customType, message.timestamp, message.details]);
    const expanded = () => pi.getSettings().tuiMode === "regular" || (inboundExpanded.get(key) ?? false);
    const paint: Paint = (color, text) => (color ? theme.fg(color, text) : text);
    return {
      handleMouse: (event: TuiMouseEvent) => handleClick(event, () => inboundExpanded.set(key, !expanded())),
      render: (width: number): string[] => {
        const header = inboundHeader(sender, verb);
        if (!expanded() || width <= 2) return [collapsedInbound(width, header, body, paint)];
        return wrapTextWithAnsi(`${paint("dim", header)}\n${body}`, width - 2).map((line) => paint("border", "│ ") + line);
      },
      invalidate: () => {},
    };
  };

  pi.registerMessageRenderer<MessageDetails>(MESSAGE_CUSTOM_TYPE, (message, _options, theme) =>
    renderInbound(message, theme, message.details?.agent?.name, "says", message.details?.body));

  pi.registerMessageRenderer<SteerDetails>(STEER_CUSTOM_TYPE, (message, _options, theme) =>
    renderInbound(message, theme, message.details?.agent?.name, "redirects", message.details?.body));

  pi.registerMessageRenderer<NoticeDetails>(NOTICE_CUSTOM_TYPE, (message, _options, theme) => {
    const details = message.details;
    const from = details && 'job' in details ? details.job.name : details?.agent?.name;
    const content = details && 'job' in details ? `${jobEndText(details.job.end)}\n${details.tail}\nlog: ${details.job.log}` : details?.body;
    return renderInbound(message, theme, from, "notifies", content);
  });

  pi.registerMessageRenderer<StreamDetails>(STREAM_CUSTOM_TYPE, (message, _options, theme) => {
    const details = message.details, content = contentText(message.content);
    return renderInbound(message, theme, details?.job?.name, undefined, typeof details?.batch === 'string' ? content.slice(content.indexOf('\n') + 1) : undefined);
  });

  pi.on("message_start", (event) => {
    const m = event?.message;
    const details = isRecord(m) && isRecord(m.details) ? m.details : undefined;
    if (edge && details?.work === true) markOwnWork();
    if (m?.role !== "custom" || m.customType !== NOTICE_CUSTOM_TYPE) return;
    const noticeId = details?.noticeId;
    if (typeof noticeId !== "string" || !noticeId || !pendingNotices.has(noticeId)) return;
    pendingNotices.delete(noticeId);
    renderNoticeWidget();
  });

  // ---- tools ----

  const rowsOf = (snapshot: Snapshot, which: "all" | "peers" | "subagents"): AgentRow[] =>
    snapshot.rows.filter((row) => which === "all" || (which === "peers" ? row.relationship === "peer" : row.relationship === "own"));

  pi.registerTool({
    name: "list_agents",
    label: "List Agents",
    description:
      "List the agents you can message: your subagents, your peers, each ancestor and its peers, in this session. Recorded peers with a session file also list after they end. which selects all (default), peers or subagents. An own subagent's row says whether it has reported on its last work and starts its last report; read_report gives the whole text. Bash jobs are in list_async_bash.",
    promptSnippet: "list_agents(which?) - discover the agents you can message, and your own subagents to stop with stop_agent",
    parameters: Type.Object(
      {
        which: Type.Optional(Type.Union([Type.Literal("all"), Type.Literal("peers"), Type.Literal("subagents")], { description: "all (default), peers, or subagents (your own)." })),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const listed = rowsOf(await discovery(), params.which ?? "all").map(toolRow);
      return reply(JSON.stringify(listed), listed);
    },
  });

  pi.registerTool({
    name: "read_report",
    label: "Read Report",
    description: "The whole last report of one of your subagents, or all of its reports in order, as they reached you.",
    promptSnippet: "read_report(agent, which?) - the whole report of one of your subagents",
    parameters: Type.Object(
      {
        agent: Type.String({ description: "A subagent of yours: its exact name, session id, a unique id prefix of at least eight characters, or an @-mention." }),
        which: Type.Optional(Type.Union([Type.Literal("last"), Type.Literal("all")], { description: "last (default) or all of its reports, in order." })),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const snapshot = await discovery();
      const mine: Snapshot = { ...snapshot, all: snapshot.all.filter((a) => a.relationship === "own" && !a.self), elsewhere: [] };
      const resolved = resolveIn(mine, normalizeAddress(params.agent));
      if ("error" in resolved) return reply(`could not read a report of ${params.agent}: ${resolved.error}`);
      const child = children().find((c) => c.session === resolved.agent.id);
      if (!child) return reply(`could not read a report of ${params.agent}: it is not a subagent of this session`);
      const reports = childReports(child);
      if (reports.length === 0) return reply(`${child.name} has not reported`);
      if (params.which !== "all") return reply(reports.at(-1)?.text ?? "");
      return reply(reports.map((r, i) => `--- report ${i + 1} of ${reports.length}, ${new Date(r.at).toISOString()} ---\n${r.text}`).join("\n\n"));
    },
  });

  pi.registerTool({
    name: "list_async_bash",
    label: "List Async Bash",
    description:
      "List your own async_bash jobs: all running, all with an undelivered ending notice, and the newest 20 announced endings, newest first, with the job id that stop_async_bash takes and the log that holds the output.",
    promptSnippet: "list_async_bash() - your own async_bash jobs, with their output logs",
    parameters: Type.Object({}, { additionalProperties: false }),
    async execute() {
      const listed = backgroundJobs().reverse().map((job) => ({
        job: job.id, name: job.mode.name, ...(serviceJob(job) ? { service: true } : {}), command: job.command, state: job.state.type === "ended" ? "ended" : jobRunning(job) ? "running" : "ending",
        ...(job.state.type === "ended" ? { end: jobEndText(job.state.end) } : {}),
        startedAt: job.startedAt, log: job.mode.log,
        ...(job.where.type === "routed" ? { runtime: job.where.runtime } : {}),
      }));
      return reply(JSON.stringify(listed), listed);
    },
  });

  pi.registerTool({
    name: "message_agent",
    label: "Message Agent",
    description:
      "Send text to an agent by name, session id, or unique id prefix. message (default) queues for any agent until its current turn ends; to an ended subagent of yours or a recorded peer it resumes that agent in its own session, with its history and its last model and thinking level, and the message is its next turn. A peer stays independent. steer joins the current turn of any agent in your scope. interrupt-and-steer aborts the current turn of any agent in your scope, then starts a new turn with the text.",
    promptSnippet: "message_agent(to, message, mode?) - send a message to another agent in this session",
    parameters: Type.Object(
      {
        to: Type.String({
          description: `Who to message: an agent's exact name, session id, a unique id prefix of at least ${MIN_ID_PREFIX} characters, or an @-mention from the prompt such as @impl (session 9702ddd1).`,
        }),
        message: Type.String({ description: "The message text to deliver." }),
        mode: Type.Optional(Type.Union([Type.Literal("message"), Type.Literal("steer"), Type.Literal("interrupt-and-steer")], {
          description: "message queues until the turn ends, and resumes an ended subagent of yours or a recorded peer with its history (default). steer joins the current turn of any agent in your scope. interrupt-and-steer aborts its current turn, then starts a new turn with the text.",
        })),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const refuse = (message: string, failure: Extract<AgentOutcome, { ok: false }>['failure'] = 'error', to = params.to) => reply(`could not message ${params.to}: ${message}`, { to, outcome: { ok: false, failure, message } satisfies AgentOutcome });
      if (!params.message) return refuse('the message is empty; nothing sent');
      if (!params.message.isWellFormed()) return refuse('the message is not valid UTF-8');
      if (Buffer.byteLength(params.message, "utf8") > MAX_MESSAGE_BYTES) return refuse(`the message is over ${MAX_MESSAGE_BYTES} bytes`);
      const mode = params.mode ?? "message";
      const snapshot = await discovery();
      if (!snapshot.ok) return refuse('could not read the layout');
      const resolved = resolveIn(snapshot, normalizeAddress(params.to));
      if ("error" in resolved) return refuse(resolved.error, resolved.failure);
      let target = resolved.agent;
      const name = agentName(target);
      if (target.self) return reply(`${name} is this agent`, { to: name, outcome: { ok: false, failure: 'error', message: `${name} is this agent` } satisfies AgentOutcome });
      const child = agents().find((c) => c.session === target.id);
      if (target.state === "ended") {
        if (!child || mode !== "message") return refuse(`${name} is no longer running`, 'not_running', name);
        const restarted = await restartAgent(child, params.message);
        if ("error" in restarted) return refuse(restarted.error, 'error', name);
        if ("placement" in restarted) return reply(`restarted ${name} in pane ${restarted.placement.pane}; ${child.role === "peer" ? PEER_RESULT_RULE : liveRunRule(SPAWN_RESULT_RULE)}`, { to: name, outcome: { ok: true } satisfies AgentOutcome });
        target = restarted.running;
      }
      if (child?.role === "subagent") markChildWork(child);
      const kind: SendKind = mode === "interrupt-and-steer" ? "interrupt" : mode;
      const result = await sendIntent(target.pane, kind, params.message, routed && !("refusal" in routed) ? { data: { runtime: routed.name } } : {});
      const sent = deliveryText(name, mode, result, target.status === "working", true);
      const outcome: AgentOutcome = sent.ok ? { ok: true } : { ok: false, failure: isAgentFailure(result.state) ? result.state : 'error', message: 'message' in result ? result.message : sent.text };
      return reply(sent.ok ? sent.text : `could not message ${params.to}: ${sent.text}`, { to: name, outcome });
    },
  });

  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn Agent",
    description:
      "Start an agent in a new window. Resume a saved session or fork a copy of it; fork alone copies this session. Returns the pi session id for later resume_from. Children report by notice and stay alive. A toplevel agent is an independent peer: no report, notice, depth limit or descendant controls; fork is allowed, but an existing child cannot become a peer.",
    promptSnippet:
      "spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?, runtime?) - start, resume or copy an agent in a new window; returns its pi session id; toplevel starts an independent peer, not a child; runtime works in a configured runtime or an ad-hoc runtime of this session",
    promptGuidelines: [
      "A subagent's result arrives on its own as a notice when it finishes; never poll list_agents for it; list_agents lists the agent and stop_agent stops it.",
      "Trust but verify: a child's report says what it intended to do, not what it did - check the diff before relaying success.",
      NOT_THE_USER_RULE,
    ],
    parameters: Type.Object(
      {
        task: Type.String({
          description:
            "First task. State the files, changes and required result. Empty only when resuming without fork: starts no turn and owes no report.",
        }),
        name: Type.String({ description: "Window and session name. Unique among this caller's children; for toplevel, unique among live agents in the session. Resume an ended child with its existing name. A recorded peer stays a peer when resumed." }),
        model: Type.Optional(
          Type.String({
            description:
              'Model as provider/model-id[:thinking]. Default: saved session’s last model and thinking level with resume_from, else caller’s current model and thinking level. A saved session with no model uses the caller’s. Required if neither has a model. Bare aliases are refused; see pi --list-models.',
          }),
        ),
        cwd: Type.Optional(Type.String({ description: "Existing working directory. Default: saved session's directory with resume_from, else caller's. Continue requires its recorded directory; fork can copy into another directory." })),
        resume_from: Type.Optional(Type.String({ description: "Pi session id or unique prefix of at least eight characters. Continuing a live session is refused; fork copies it." })),
        toplevel: Type.Optional(Type.Boolean({ description: "Start an independent peer, with no parent, reports or notices. Depth does not apply. Fork is allowed; an existing child cannot become a peer." })),
        fork: Type.Optional(
          Type.Boolean({
            description:
              "Copy resume_from, or this session when omitted. A copy requires a task. Defaults to false.",
          }),
        ),
        runtime: Type.Optional(
          Type.String({
            description:
              "Run the agent's tools in a configured runtime or an ad-hoc runtime of this session by name. Its pi runs here, so resume_from and fork work; a runtime that runs pi itself refuses them. Omitted: the runtime of the caller.",
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const refuse = (text: string) => reply(`could not spawn agent: ${text}`, { outcome: { ok: false, failure: "error", message: text } satisfies AgentOutcome });
      if (!ko) return refuse("ko is not on PATH");
      if (!ownSessionId) return refuse("this session has no id");
      if (!pane) return refuse("this session has no pane");
      const name = params.name;
      if (!name) return refuse("name is required");
      const nameError = checkName(name);
      if (nameError) return refuse(nameError);
      const task = params.task.trim().length > 0 ? params.task : "";
      if (taskTooLarge(task)) return refuse(`the task does not fit the ${MAX_TASK_BYTES} byte limit of a pane variable`);
      if (!task && (!params.resume_from || params.fork)) return refuse("task is required unless resuming without fork");
      let childRuntime: ChildRuntime | undefined;
      let runtimeInfo: Api["RuntimeInfo"] | undefined;
      if (params.runtime && process.env.KO_RUNTIME) {
        if (params.runtime !== process.env.KO_RUNTIME) return refuse(`this agent runs inside runtime ${process.env.KO_RUNTIME}; its children run there too`);
      } else if (params.runtime) {
        const info = await fetchRuntime(params.runtime);
        if ("error" in info) return refuse(info.error);
        runtimeInfo = info;
        childRuntime = { name: info.name, mode: info.pi === "runtime" ? "inside" : "routed" };
      } else if (routed) {
        if ("refusal" in routed) return refuse(routed.refusal);
        childRuntime = { name: routed.name, mode: "routed" };
      }
      if (childRuntime?.mode === "inside" && (params.resume_from || params.fork)) return refuse("a saved session is a file of this filesystem: resume_from and fork need a runtime whose pi runs on the host");
      if (params.model) {
        const error = await validateModel(params.model);
        if (error) return refuse(error);
      }
      let source: { id: string; path: string; cwd: string; model: string | undefined } | undefined;
      if (params.resume_from) {
        const wanted = params.resume_from;
        const files = sessionFiles(ctx.sessionManager.getSessionDir());
        const exact = files.filter((file) => file.id === wanted);
        if (!exact.length && wanted.length < MIN_ID_PREFIX) return refuse(`session prefixes need at least ${MIN_ID_PREFIX} characters`);
        const matches = exact.length ? exact : files.filter((file) => file.id.startsWith(wanted));
        if (matches.length !== 1) return refuse(matches.length
          ? `${quote(wanted)} matches several sessions by id: ${matches.slice(0, 5).map((file) => file.id).sort().join(", ")}`
          : `unknown session ${quote(wanted)}`);
        const file = matches[0];
        if (!file) return refuse(`unknown session ${quote(wanted)}`);
        const saved = readSavedSession(file, ctx.modelRegistry);
        if ("error" in saved) return refuse(saved.error);
        source = { ...file, ...saved };
      }
      const model = params.model ?? source?.model ?? callerModel(ctx);
      if (!model) return refuse("caller has no model; specify model");
      const forkFile = params.fork ? source?.path ?? ctx.sessionManager.getSessionFile() : undefined;
      if (params.fork && !forkFile) return refuse("caller has no session file to copy");
      const mode: Plan["mode"] = forkFile ? { kind: "copy", file: forkFile } : source ? { kind: "continue", file: source.path } : { kind: "fresh" };
      const recordedPeer = mode.kind === "continue" && source ? peers().find((p) => p.session === source.id) : undefined;
      const toplevel = !!params.toplevel || !!recordedPeer;
      const cwd = resolve(ctx.cwd, params.cwd ?? source?.cwd ?? ctx.cwd);
      if (mode.kind === "continue" && source && cwd !== resolve(source.cwd)) return refuse(`a continued session runs in its recorded directory ${source.cwd}; fork copies it into another`);
      let directoryExists = false;
      try { directoryExists = statSync(cwd).isDirectory(); } catch {}
      if (!directoryExists) return refuse(`cwd is not a directory: ${cwd}`);
      const childSession = mode.kind === "continue" && source ? source.id : randomBytes(16).toString("hex");
      const taken = () => refuse(`the name ${quote(name)} is already taken by ${toplevel ? "a live agent in this session" : "one of this session's agents; message it instead"}`);
      return withRestartLock(childSession, async () => {
        const snapshot = await discovery();
        if (!snapshot.ok || !snapshot.me) return refuse("could not read the layout");
        if (mode.kind === "continue" && !toplevel && snapshot.ancestors.includes(childSession)) return refuse(`session ${childSession} is an ancestor of this session`);
        if (mode.kind === "continue" && (snapshot.panes.some((p) => p.sessionVar === childSession && !p.dead) || snapshot.all.some((a) => a.id === childSession && a.state === "running"))) return refuse(`session ${childSession} is live in a pane`);
        const existing = mode.kind === "continue" ? children().find((c) => c.session === childSession) : undefined;
        if (existing && (toplevel || existing.name !== name)) return refuse("resume this child with its existing name and without toplevel");
        if (!claimName(name)) return taken();
        try {
          const wanted = name.toLowerCase();
          const holds = toplevel
            ? [...snapshot.all].some((a) => a.state === "running" && a.name.toLowerCase() === wanted)
            : !existing && ([...children()].some((c) => c.name.toLowerCase() === wanted) || snapshot.all.some((a) => a.relationship === "own" && a.name.toLowerCase() === wanted));
          if (holds || jobNamed(wanted)?.state.type === "running") return taken();
          if (!toplevel && snapshot.depth + 1 > MAX_DEPTH) return refuse(`refusing to spawn at depth ${snapshot.depth + 1}: maximum nesting is ${MAX_DEPTH} (root 0, subagent 1, subagent 2)`);
          const plan: Plan = {
            name,
            session: childSession,
            model,
            cwd,
            runtime: childRuntime,
            runtimeInfo,
            task,
            mode,
            toplevel,
            koSession: snapshot.me.session,
          };
          const made = await createPane(plan);
          if ("error" in made) return refuse(made.error);
          recordAgent(plan, made.placement);
          const { window, pane: childPane } = made.placement;
          const inRuntime = childRuntime?.name ?? process.env.KO_RUNTIME;
          return reply(
            `spawned ${name} (session ${childSession}, window ${window}, pane ${childPane}${inRuntime ? `, in runtime ${inRuntime}` : ""})${mode.kind === "copy" ? `, forked from session ${source?.id ?? ownSessionId}` : ""}; session id is what resume_from takes later; ${toplevel ? PEER_RESULT_RULE : task ? liveRunRule(SPAWN_RESULT_RULE) : SPAWN_RESULT_RULE}`,
            { session: childSession, name, window, pane: childPane, fork: mode.kind === "copy", outcome: { ok: true } satisfies AgentOutcome },
          );
        } finally { releaseName(name); }
      });
    },
  });

  pi.registerTool({
    name: "stop_agent",
    label: "Stop Agent",
    description:
      "Stop one agent in your scope: a subagent, a peer, an ancestor or a pi the user started. It asks the agent to shut down and then kills its pane. force kills an agent that is not receiving messages. The result is the only signal: a subagent you stop sends no ending notice. Stopping an ancestor ends you with it.",
    promptSnippet: "stop_agent(agent, force?) - end one agent in your scope",
    parameters: Type.Object(
      {
        agent: Type.String({
          description: `An address: session id, unique id prefix of at least ${MIN_ID_PREFIX} characters, name, or an @-mention such as @impl (session 9702ddd1).`,
        }),
        force: Type.Optional(
          Type.Boolean({
            description: "For an agent that is not receiving messages, kill its pane without asking it first. Destructive and irreversible.",
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const snapshot = await discovery();
      if (!snapshot.ok) return reply("could not stop: could not read the layout");
      const resolved = resolveIn(snapshot, normalizeAddress(params.agent));
      if ("error" in resolved) return { ...reply(`${quote(params.agent)}: error: ${resolved.error}`), isError: true };
      const target = resolved.agent;
      const name = agentName(target);
      if (target.self) return { ...reply(`refusing to stop ${name}: it is this agent`), isError: true };
      const child = target.relationship === "own" ? children().find((c) => c.session === target.id) : undefined;
      const reportedText = child ? (childReported(child) ? "; it had reported" : "; it had not reported on its last work") : "";
      if (target.state === "ended") {
        if (child) claimEnding(child);
        return reply(`${name} had already ended: ${target.ended ?? "its pane is gone"}`);
      }
      if (!params.force && !target.canMessage) {
        return { ...reply(`${name} is not receiving messages; pass force to kill its pane`), isError: true };
      }
      if (child) claimEnding(child);
      let requestFailure = "";
      if (!params.force) {
        const request = await sendIntent(target.pane, "stop", "");
        if (request.state !== "acked" && request.state !== "refused") requestFailure = "message" in request ? request.message : request.state;
      }
      const stopped = await apiCall("POST", `/panes/${target.pane}/stop`, { wait_ms: params.force ? 0 : STOP_WAIT_MS } satisfies Api["StopPane"], STOP_CALL_MS);
      if ("error" in stopped || stopped.status !== 200) {
        const failure = apiError(stopped);
        if (failure.kind === "not_found") return reply(`${name} had already ended: its pane was removed`);
        return { ...reply(`could not stop ${name}: ${failure.message}`), isError: true };
      }
      return reply(`stopped ${name}${reportedText}${requestFailure ? `; the stop request failed: ${requestFailure}` : ""}`);
    },
  });

  pi.registerTool({
    name: "async_bash",
    label: "Async Bash",
    description:
      "Run a shell command in the background, for a command whose result you do not need for your next step - this session keeps working while it runs. Exactly one notice arrives when the command ends, carrying its exit status and a tail of its output. Use service=true for a server that keeps running. Its full output is in the log file; read it meanwhile. With stream=true the new lines arrive in batches. list_async_bash lists it and stop_async_bash stops it. If your next step needs the result and you have nothing else to do meanwhile, use bash with a timeout instead.",
    promptSnippet:
      "async_bash(command, name, stream?, service?) - run a command in the background; a notice with its exit status arrives when it ends, read its output log meanwhile; list_async_bash lists it and stop_async_bash stops it",
    promptGuidelines: [
      "Use async_bash when you can do other work while a command runs, when someone (the user, your parent or a child) may need an answer from you meanwhile, when you start several independent jobs at once, or for a server that keeps running. Once a command is in async_bash, its notice is the only way you learn that it ended: never run `sleep` in bash to wait for it, and never loop over its log. If you have nothing else to do, end your turn; the notice wakes you.",
      "Use async_bash instead of background bash jobs (`nohup`, a trailing `&`, `setsid`, `disown`).",
      "list_async_bash lists an async_bash job and stop_async_bash stops it by its job id.",
      NOT_THE_USER_RULE,
    ],
    parameters: Type.Object(
      {
        command: Type.String({
          description:
            'The command to run in the background, as a shell command line (e.g. "make -j8 && ./run"), run through the configured pi shell.',
        }),
        name: Type.String({ description: "A name for the job; it must be unused by this session's running jobs and children. An ended job releases its name." }),
        service: Type.Optional(Type.Boolean({ description: "A process meant to keep running, such as a server; not a build or a test. Does not hold your report. Off by default." })),
        stream: Type.Optional(
          Type.Boolean({
            description:
              "Send the command's output to this session in batches while it runs, instead of only at the end. Off by default.",
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params, _signal, _update, ctx) {
      if (routed && "refusal" in routed) return reply(`could not start background command: ${routed.refusal}`);
      if (!params.name) return reply("could not start background command: --name is required");
      const nameError = checkName(params.name);
      if (nameError) return reply(`could not start background command: ${nameError}`);
      const taken = `could not start background command: the name ${quote(params.name)} is already taken by one of this session's running jobs or children; choose another name`;
      if (!claimName(params.name)) return reply(taken);
      const controller = new AbortController();
      const abort = (): void => controller.abort(new Error("the tool call"));
      const pending: PendingCall = { type: "async_bash", cancel(reason) { controller.abort(new Error(`session ${reason ?? "shutdown"}`)); } };
      calls.add(pending);
      _signal?.addEventListener("abort", abort, { once: true });
      if (_signal?.aborted) abort();
      const cleanup = (): void => {
        calls.delete(pending);
        _signal?.removeEventListener("abort", abort);
      };
      try {
        const wanted = params.name.toLowerCase();
        if (jobNamed(wanted)?.state.type === "running" || children().some((child) => child.name.toLowerCase() === wanted)) return reply(taken);
        const runtime = routed ? await liveRouted(controller.signal) : undefined;
        const operations = runtime ? bashOperations(runtime) : localExec;
        const job = await new Promise<BackgroundJob>((resolve, reject) => {
          void operations.exec(params.command, runtime?.cwd ?? ctx.cwd, {
            signal: controller.signal, onData: () => {},
            onStart(job) {
              cleanup();
              resolve(promoteJob(jobRegistry(), job, { type: "async_bash", stream: !!params.stream, service: !!params.service }, params.name));
            },
          }).catch(reject);
        });
        const progress = params.stream ? "batches of its new lines arrive meanwhile, capped; the log holds its whole output" : "read the log to check its output meanwhile";
        const lifecycle = serviceJob(job)
          ? "it does not hold your report; a notice with its exit status still arrives when it ends"
          : liveRunRule("a notice with its exit status and an output tail arrives when it ends and starts your next turn; you stay alive while it runs, so ending your turn now is safe - do not sleep or poll for it, and end your turn if nothing else is left");
        return reply(`started job ${job.id} (${job.mode.name}); list_async_bash lists it and stop_async_bash stops it; ${lifecycle}; ${progress}; log: ${job.mode.log}`, { job: jobReference(job), stream: !!params.stream });
      } catch (error) {
        const message = controller.signal.aborted ? `start cancelled by ${errorText(controller.signal.reason)}; no job was started` : errorText(error);
        return { ...reply(`could not start background command: ${message}`), isError: true };
      } finally { cleanup(); releaseName(params.name); }
    },
  });

  pi.registerTool({
    name: "stop_async_bash",
    label: "Stop Async Bash",
    description: "Stop one of your async_bash jobs by job id or name. A name selects a running job, or the newest ended job. Its output stays in its log.",
    promptSnippet: "stop_async_bash(job) - stop one of your async_bash jobs",
    parameters: Type.Object({ job: Type.String({ description: "A job id from list_async_bash or its name." }) }, { additionalProperties: false }),
    async execute(_toolCallId, params) {
      const jobs = backgroundJobs();
      const job = jobs.find((job) => job.id === params.job) ?? jobNamed(params.job);
      if (!job) return { ...reply(`${quote(params.job)}: error: no async_bash job matches`), isError: true };
      if (job.state.type === "ended") return reply(`job ${job.id} (${job.mode.name}) had already ended: ${jobEndText(job.state.end)}; log: ${job.mode.log}`);
      stopJob(job);
      detachJob(job);
      await waitJobs([job]);
      return reply(`stopped job ${job.id} (${job.mode.name}); log: ${job.mode.log}`);
    },
  });

  const liveRouted = async (signal: AbortSignal | undefined): Promise<Routed> => {
    if (!routed) throw new Error("this session routes no tools");
    if ("refusal" in routed) throw new Error(routed.refusal);
    await routed.ready(signal);
    return routed;
  };

  const route = <D extends Pick<ToolDefinition, "name" | "label" | "description" | "parameters"> & { execute: (...args: never[]) => Promise<unknown> }>(
    local: D,
    execute: (r: Routed, id: string, params: Parameters<D["execute"]>[1], signal: AbortSignal | undefined, onUpdate: Parameters<D["execute"]>[3], context: ExtensionToolContext) => ReturnType<D["execute"]>,
  ): void =>
    pi.registerTool({
      ...local,
      async execute(id: string, params: Parameters<D["execute"]>[1], signal: AbortSignal | undefined, onUpdate: Parameters<D["execute"]>[3], context: ExtensionToolContext) {
        return execute(await liveRouted(signal), id, params, signal, onUpdate, context);
      },
    });

  const registerRouted = (): void => {
    const cwd = process.cwd();
    route(createBashToolDefinition(cwd), (r, id, params, signal, onUpdate, context) => executeBash(createBashToolDefinition(r.cwd, { operations: handoff(bashOperations(r)), exposeSessionEnvironment: false }), id, params, signal, onUpdate, { ...context, cwd: r.cwd }));
    route(createReadToolDefinition(cwd), async (r, id, params, signal, onUpdate) => createReadTool(r.cwd, { operations: readOperations(r) }).execute(id, { ...params, path: await homed(r, params.path, signal) }, signal, onUpdate));
    route(createWriteToolDefinition(cwd), async (r, id, params, signal, onUpdate) => createWriteTool(r.cwd, { operations: writeOperations(r) }).execute(id, { ...params, path: await homed(r, params.path, signal) }, signal, onUpdate));
    route(createEditToolDefinition(cwd), async (r, id, params, signal, onUpdate) =>
      createEditTool(r.cwd, { operations: { readFile: readOperations(r).readFile, writeFile: writeOperations(r).writeFile, access: async () => {} } }).execute(id, { ...params, path: await homed(r, params.path, signal) }, signal, onUpdate),
    );
    route(createLsToolDefinition(cwd), async (r, id, params, signal, onUpdate) => createLsTool(r.cwd, { operations: lsOperations(r) }).execute(id, { ...params, path: await homed(r, params.path, signal) }, signal, onUpdate));
    route(createFindToolDefinition(cwd), async (r, id, params, signal, onUpdate) => createFindTool(r.cwd, { operations: findOperations(r) }).execute(id, { ...params, path: await homed(r, params.path, signal) }, signal, onUpdate));
    route(createGrepToolDefinition(cwd), async (r, _id, params, signal) => routedGrep(r, { ...params, path: await homed(r, params.path, signal) }, signal));
  };

  pi.on("user_bash", async () => {
    if (!routed) return undefined;
    const r = await liveRouted(undefined);
    const operations = bashOperations(r);
    return { operations: { exec: (command, _hostCwd, options) => operations.exec(command, r.cwd, options) } };
  });

  const runtimeText = (r: Routed): string => {
    const others = pi.getAllTools().map((tool) => tool.name).filter((name) => !ROUTED_TOOLS.includes(name));
    return `The tools ${ROUTED_TOOLS.join(", ")} and the user's ! commands run in runtime ${r.name}, at ${r.cwd}. Every other tool${others.length ? ` (${others.join(", ")})` : ""} runs on the host, at ${r.hostCwd}, not in the runtime.`;
  };

  pi.on("resources_discover", () => {
    if (offersSkill()) return { skillPaths: [join(dirname(extensionPath), "skills")] };
  });

  pi.on("before_agent_start", async (event) => {
    event.systemPromptOptions.promptGuidelines.push(NEVER_SLEEP_RULE);
    if (offersSkill()) event.systemPromptOptions.promptGuidelines.push(KO_SKILL_RULE);
    if (edge) event.systemPromptOptions.promptGuidelines.push(SUBAGENT_INSTRUCTION);
    if (!routed || "refusal" in routed) return;
    const r = routed;
    try {
      await r.ready();
    } catch (error) {
      session?.ui?.notify(errorText(error), "error");
      return;
    }
    const options = event.systemPromptOptions;
    options.cwd = r.cwd;
    options.contextFiles = [...options.contextFiles.filter((file) => resolve(dirname(file.path)) === resolve(getAgentDir())), ...r.contextFiles];
    options.sections.runtime = runtimeText(r);
  });

  const startRouted = async (ctx: ExtensionContext): Promise<void> => {
    routed = null;
    const flag = pi.getFlag("runtime");
    const name = !process.env.KO_RUNTIME && typeof flag === "string" ? flag : "";
    if (!name) return;
    registerRouted();
    const refuse = (message: string): void => {
      routed = { refusal: message };
      ctx.ui?.notify(message, "error");
    };
    if (!ko) return refuse(`runtime ${name}: ko is not on PATH`);
    const info = await fetchRuntime(name);
    if ("error" in info) return refuse(info.error);
    if (info.pi === "runtime") return refuse(`runtime ${name} runs pi inside it: start ko-pi in a pane of that runtime`);
    const found = mapHostPath(info.paths, ctx.cwd) ?? info.cwd;
    const program = ko;
    let facts: Promise<Facts> | undefined;
    let attempt: Promise<void> | undefined;
    const r: Routed = { name, ko: program, hostCwd: ctx.cwd, paths: info.paths, facts: () => (facts ??= probeFacts(program, name)), cwd: found ?? "", contextFiles: [], ready: (signal) => abortable((attempt ??= load()), signal) };
    const announce = (): void => ctx.ui?.notify(runtimeText(r), "info");
    const load = async (): Promise<void> => {
      try {
        const started = await readRuntimeContext(program, name, found);
        r.cwd = started.cwd;
        r.contextFiles = started.contextFiles;
        if (found === undefined) {
          announce();
          await markRouted();
        }
      } catch (error) {
        const message = `runtime ${name}: ${errorText(error)}`;
        if (found === undefined) {
          attempt = undefined;
          throw new Error(message);
        }
        ctx.ui?.notify(`${message}; its context files are not read`, "warning");
      }
    };
    routed = r;
    if (found !== undefined) announce();
    void r.ready().catch((error: unknown) => ctx.ui?.notify(errorText(error), "error"));
  };

  const markRouted = async (): Promise<void> => {
    if (active && routed && !("refusal" in routed) && routed.cwd) await writeVars([[VAR_RUNTIME, { name: routed.name, cwd: routed.cwd }], [VAR_KO_RUNTIME, routed.name]]);
  };

  // ---- the session ----

  let startup: NodeJS.Immediate | undefined;
  let starting: Promise<void> | undefined;
  let startupCancelled = false;

  pi.on("session_start", async (_event, ctx) => {
    const flag = pi.getFlag("harness");
    if (flag !== undefined && flag !== "koa" && flag !== "koa-browser") throw new Error("--harness must be koa or koa-browser");
    let completionReady = false;
    if (flag) setCompletionContext(async signal => {
      const current = session;
      if (!completionReady || !current || current !== ctx || signal.aborted) return { type: "unavailable" };
      const r = routed ? await liveRouted(signal) : undefined;
      if (signal.aborted || session !== current) return { type: "unavailable" };
      return r ? { type: "runtime", name: r.name, cwd: toRuntime(r, r.cwd) } : { type: "host", cwd: current.cwd };
    });
    ko = insideKo() ? findKo() : null;
    session = ctx;
    ownSessionId = ctx.sessionManager.getSessionId() || null;
    pane = process.env.KO_PANE || null;
    const parent = process.env.KO_AGENT_PARENT_SESSION;
    edge = ownSessionId && parent && process.env.KO_AGENT_SESSION === ownSessionId ? { parent } : null;
    recordsPeers = !edge && !process.env.KO_RUNTIME;
    const previousExit = globalThis.__koPiExtensionExit;
    if (previousExit) process.removeListener("exit", previousExit);
    globalThis.__koPiExtensionExit = unsetVarsSync;
    process.on("exit", unsetVarsSync);
    pendingNotices.clear();
    written.clear();
    ending = { kind: "ended", text: "" };
    settled = true;
    turnEndedByControl = false;
    leaving = null;
    parentPane = "";

    // A headless session has no ui, and an older pi has one without this method:
    // both simply get no `@name` completion.
    const ui = ctx.ui;
    if (ui?.addAutocompleteProvider && !completion) {
      const cache = agentCache(discovery, process.env.KO_AGENT_LIST_TTL_MS);
      completion = cache;
      ui.addAutocompleteProvider((current: AutocompleteProvider): AutocompleteProvider => ({
        triggerCharacters: current.triggerCharacters,
        async getSuggestions(lines, cursorLine, cursorCol, options) {
          const token = atToken((lines[cursorLine] ?? "").slice(0, cursorCol));
          if (token === undefined) return current.getSuggestions(lines, cursorLine, cursorCol, options);
          const items = cache(token);
          const files = await current.getSuggestions(lines, cursorLine, cursorCol, options);
          if (items.length === 0) return files;
          const prefix = `@${token}`;
          const fileItems = files && files.prefix === prefix ? files.items : [];
          return { items: [...items, ...fileItems], prefix };
        },
        applyCompletion: current.applyCompletion.bind(current),
        shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
          return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
        },
      }));
    }

    await startRouted(ctx);
    completionReady = true;
    active = !!(ctx.hasUI && ownSessionId && ko && pane);
    if (active) {
      receiver.start();
      await writeVars([
        [VAR_SESSION, ownSessionId ?? ""],
        [VAR_NAME, pi.getSessionName() ?? ""],
      ]);
      await markRouted();
      await readInstance();
      startPeerClient();
    }
    adoptJobs();
    const wrapsBash = registerLocalBash(ctx) || !!(routed && !("refusal" in routed));
    if (wrapsBash && ctx.hasUI) {
      const owner = jobRegistry();
      detachKeys(owner);
      owner.keys = ctx.ui.onTerminalInput((data) => {
        if (!matchesKey(data, Key.ctrl("b"))) return;
        let moved = false;
        for (const call of [...calls]) if (call.type === "bash") moved = call.move("key") || moved;
        if (moved) return { consume: true };
      });
    }
    if (!active) return;
    // Pi 1.5.0 subscribes interactive status after session_start returns.
    startup = setImmediate(() => {
      startup = undefined;
      starting = (async () => {
        await deliverTask();
        if (startupCancelled) return;
        await reconcileChildren();
        if (!startupCancelled) startTick();
      })().catch((error: unknown) => ctx.ui.notify(errorText(error), "error"));
    });
  });

  pi.on("session_info_changed", async () => {
    await writeVars([[VAR_NAME, pi.getSessionName() ?? ""]]);
  });

  const running = (): void => {
    agentWorking = true;
    beginWork();
  };
  pi.on("input", () => { refreshJobRecords(); });
  pi.on("agent_start", () => {
    refreshJobRecords();
    workStarted();
    running();
  });
  pi.on("turn_start", running);
  pi.on("tool_execution_start", running);
  pi.on("tool_call", running);
  pi.on("turn_end", (event: { toolResults?: unknown[] }) => {
    if (event?.toolResults?.length) flushStreams();
  });

  pi.on("agent_end", (event) => {
    finishWorking();
    const assistants = (event?.messages ?? []).filter((m) => m?.role === "assistant");
    const last = assistants[assistants.length - 1];
    if (!last) {
      ending = { kind: "ended", text: "" };
      return;
    }
    const text = contentText(last.content, "");
    ending =
      last.stopReason === "error"
        ? { kind: "error", text: last.errorMessage || "no error message given", notified: false, id: mintId() }
        : last.stopReason === "aborted"
          ? { kind: "aborted" }
          : { kind: "ended", text };
  });

  pi.on("agent_settled", async (event: { aborted?: boolean }, ctx: { isIdle(): boolean }) => {
    if (!ctx.isIdle()) return;
    finishWorking();
    settled = true;
    for (const held of interrupted.splice(0)) deliverMessage(held);
    if (!edge) return;
    if (event?.aborted) return;
    if (turnEndedByControl) return;
    if (ending.kind === "aborted") return;
    if (ending.kind === "error") {
      if (ending.notified) return;
      ending.notified = true;
      const sent = await statusNotice(`subagent stopped on an error: ${trimErrorMessage(ending.text)}\nmessage it to retry, or stop_agent to end it`, ending.id);
      if (!sent && ending.kind === "error") ending.notified = false;
      return;
    }
    if (ownReported()) return;
    const generation = workGeneration;
    if ((await ownLiveWork()) !== false) return;
    if (turnEndedByControl || generation !== workGeneration || ownReported()) return;
    const name = quote(pi.getSessionName() ?? "");
    const last = ending.kind === "ended" ? ending.text : "";
    const text = utf8Prefix(last || `subagent ${name} ended its turn with no message`, MAX_MESSAGE_BYTES);
    const report = { id: mintId(), text };
    append(ENTRY_REPORT, { text, id: report.id, sent: false });
    await sendReport(report, false);
  });

  pi.on("session_shutdown", async (event?: { reason?: ShutdownReason }) => {
    if (pi.getFlag("harness")) setCompletionContext();
    startupCancelled = true;
    stopPeerClient();
    pendingPeers.clear();
    clearImmediate(startup);
    await starting;
    const reason = event?.reason;
    if (registry) detachKeys(registry);
    if (reason === "reload") for (const call of [...calls]) {
      if (call.type === "bash") call.move("reload");
      else call.cancel(reason);
    }
    if (session?.hasUI) session.ui.setWidget("ko-job-hint", undefined);
    stopTick();
    if (reason === "reload") {
      receiver.stop(true);
      if (registry) registry.owner = null;
      detachJobRecords();
      for (const job of backgroundJobs()) detachJob(job);
    } else {
      clearJobRecords();
      for (const call of calls) call.cancel(reason);
      if (reason === "quit" && edge && leaving === null && active) {
        const text = exitNoticeText();
        exitNoticeId ||= mintId();
        if (text) await statusNotice(text, exitNoticeId);
      }
      if (registry) {
        registry.stopAll();
        await waitJobs([...registry.jobs.values()]);
        Reflect.deleteProperty(globalThis, JOBS);
        registry = undefined;
      }
      receiver.stop(false);
      if (active) await unsetVars();
      if (globalThis.__koPiExtensionExit === unsetVarsSync) {
        process.removeListener("exit", unsetVarsSync);
        globalThis.__koPiExtensionExit = undefined;
      }
    }
    await jobRecordQueue;
    active = false;
    session = null;
  });
}
