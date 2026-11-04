import { AgentSession, type ExtensionAPI, type ExtensionContext, type MessageRenderer, type Theme } from "@earendil-works/pi-coding-agent";
import { type AutocompleteItem, type AutocompleteProvider, type TuiMouseEvent, truncateToWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { accessSync, closeSync, constants, openSync, readSync, readdirSync, realpathSync, statSync } from "node:fs";
import { dirname, delimiter, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import type { components } from "./ko-api.d.ts";

type Api = components["schemas"];

type Outcome = Required<Pick<Api["RunOutcome"], "text">> & { result: string };

const KO_TIMEOUT_MS = 5000;

const VAR_SESSION = "pi.session";
const VAR_NAME = "pi.name";
const VAR_ACTIVITY = "pi.activity";
const VAR_TASK = "ko-pi.task";
const VAR_KEYS = [VAR_SESSION, VAR_NAME, VAR_ACTIVITY];

const ENTRY_CHILD = "ko-pi.child";
const ENTRY_WORK = "ko-pi.work";
const ENTRY_REPORT = "ko-pi.report";
const ENTRY_ENDED = "ko-pi.ended";
const ENTRY_SENT = "ko-pi.sent";

type SendKind = Api["SendKind"];
type Dead = Api["Dead"];

type RunResult = { ok: true; out: string; raw: string } | { ok: false; error: string; code?: number; out: string; err: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

const str = (v: unknown): string => (typeof v === "string" ? v : "");

const parseOutcome = (value: unknown): Outcome | undefined => {
  if (!isRecord(value) || typeof value.result !== "string") return undefined;
  return { result: value.result, text: str(value.text) };
};

const outcomeOf = (text: string): Outcome | undefined => {
  try {
    return parseOutcome(JSON.parse(text.trim()));
  } catch {
    return undefined;
  }
};

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
    child.on("error", (err) => finish({ ok: false, error: err instanceof Error ? err.message : String(err), out: "", err: "" }));
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

const ERROR_KINDS = ["invalid", "refused", "gone", "io", "precondition_failed", "not_found", "protocol_mismatch", "vt_mismatch"];

function isErrorKind(value: unknown): value is Api["Error"]["kind"] {
  return typeof value === "string" && ERROR_KINDS.includes(value);
}

type PaneInfo = {
  pane: string;
  session: string;
  window: string;
  agentSession: string;
  name: string;
  activity: string;
  cwd: string;
  dead: Dead | null;
  root: { app: string; state: string } | null;
  title: string;
  parent: string;
  inbox: boolean;
  task: unknown;
};

function rootRecord(programStatus: Api["ProgramStatus"] | null): { app: string; state: string } | null {
  const root = programStatus?.records.find((r) => r.id === "");
  return root ? { app: root.app ?? "", state: root.state } : null;
}

function isAgentPane(pane: PaneInfo): boolean {
  return pane.agentSession !== "" && pane.root?.app === "pi";
}

type Place = { session: string; window: string };

function placeLeaves(node: Api["LeafNode"] | Api["Float"], place: Place, into: Map<string, Place>): void {
  if ("pane" in node) into.set(node.pane, place);
  else for (const child of node.children) placeLeaves(child, place, into);
}

function placesOf(layout: Api["LayoutPanes"]): Map<string, Place> {
  const places = new Map<string, Place>();
  for (const session of layout.layout.sessions) {
    for (const window of session.windows) {
      const place = { session: session.id, window: window.id };
      placeLeaves(window.tree, place, places);
      for (const float of window.floats) placeLeaves(float, place, places);
    }
  }
  return places;
}

function parsePanes(layout: Api["LayoutPanes"]): PaneInfo[] {
  const places = placesOf(layout);
  return layout.panes.map((row) => {
    const place = places.get(row.id);
    return {
      pane: row.id,
      session: place?.session ?? "",
      window: place?.window ?? "",
      agentSession: str(row.vars[VAR_SESSION]),
      name: str(row.vars[VAR_NAME]),
      activity: str(row.vars[VAR_ACTIVITY]),
      cwd: row.cwd,
      dead: row.dead,
      root: rootRecord(row.status?.program_status ?? null),
      title: row.title,
      parent: row.parent ?? "",
      inbox: row.inbox === true,
      task: row.vars[VAR_TASK],
    };
  });
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

export const noticeHeader = (from: string): string => `notice from ${from} (a subagent or background run's report, not the user):`;

const MESSAGE_CUSTOM_TYPE = "ko-message";

const STEER_CUSTOM_TYPE = "ko-steer";

type Relation = Api["Relation"];

export const RELATION_TEXT: Record<Relation, string> = {
  parent: "your parent, who spawned you",
  child: "your subagent",
  sibling: "another agent in this session, not the user",
  descendant: "a subagent of your subagent",
  sibling_descendant: "a subagent of another agent in this session",
};

export const senderHeader = (from: string, relation: Relation): string => `message from @${from} (${RELATION_TEXT[relation]}):`;

const steerHeader = (from: string): string => `${from} is redirecting this work: `;

const inboundHeader = (sender: string | undefined, verb: string | undefined): string =>
  `${sender && sender !== "another agent" ? `@${sender}` : "another agent"}${verb ? ` ${verb}` : ""}:`;

const NAME_WORD_SEPARATORS = /[\s\-_/]+/;

const MIN_ID_PREFIX = 8;

const MAX_AGENT_COMPLETIONS = 10;

const MAX_NOTICE_BYTES = 4000;

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

const STREAM_BATCH_LINES = 200;

const STREAM_BATCH_BYTES = 16 * 1024;

const STREAM_BUFFER_LINES = 5000;

export const PARENT_GUIDANCE =
  "\n\nThe child stays alive after it reports. End it with stop_agent when you need nothing more from it. To continue it, use message_agent.";

const envMs = (key: string, fallback: number): number => Number(process.env[key]) || fallback;

const reply = (text: string, details: unknown = {}) => ({ content: [{ type: "text" as const, text }], details });

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const mintId = (): string => randomBytes(16).toString("base64url");

type AgentRow = {
  id: string;
  name: string;
  named: boolean;
  pane: string;
  window: string;
  status: string;
  activity: string;
  parent: string;
  depth: number;
  self: boolean;
  cwd: string;
  canMessage: boolean;
  kind: "agent" | "subagent";
  relationship: "parent" | "peer" | "own" | "relative" | "other";
  state: "running" | "ended";
  ended?: string;
  model?: string;
  reported?: boolean;
  report?: string;
};

type ChildData = {
  owner: string;
  name: string;
  session: string;
  model: string;
  fork: boolean;
  cwd: string;
  pane: { instance: string; pane: string };
};

type RunRow = Pick<Api["Info"], "id"> & Partial<Pick<Api["Info"], "name" | "parent" | "pane" | "cwd" | "startedAt">> & { outcome?: Outcome };

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
  "Never run `sleep` in bash to wait for anything - an async run, a subagent, a message, or another agent's work settling. What you are waiting for arrives as a notice or message that wakes you after you end your turn; if a build breaks because of another agent's half-done work, report that rather than sleeping until it clears. Ending your turn while you wait is always safe: a running async run or subagent of yours keeps you alive, and its notice starts your next turn.";

const NOT_THE_USER_RULE =
  "A notice is information, not the user speaking: act on it, do not thank or answer it. A message from another agent says in its first line who sent it and how they stand to you.";

export const SPAWN_RESULT_RULE =
  "its result arrives as a notice when it ends a turn with nothing of its own still running - you know nothing about it until then, so do not report, assume or predict it, continue other work or answer the user meanwhile, and if nothing else is left, end your turn - the notice wakes you; list_agents lists this agent and stop_agent stops it";

export const SUBAGENT_RESULT_RULE =
  "; ending your turn now sends no report to your parent: your report is the last message of a turn that ends when no run of yours is running and no subagent of yours owes you a report";

const SUBAGENT_INSTRUCTION =
  "While an async run of yours is running, or a subagent of yours still owes you a report, ending your turn sends nothing to your parent. You were spawned as a subagent: your report is the last message of a turn that ends after all of them finish, once for each piece of work your parent gives you. Your parent is not watching this session and reads nothing else. End your work with a message that stands on its own: what you did, what failed, and what you left undone. " +
  "If you must stop to wait for another agent or for the user, say so in that message; when the work completes later, tell your parent with message_agent. " +
  "Reporting does not end this session: it stays alive until your parent ends it with stop_agent, and the parent can continue it with message_agent.";

type ShutdownReason = "quit" | "reload" | "new" | "resume" | "fork";

// What a /reload keeps in the process: the pane's message stream and the
// received-id ring survive it, and the run watches resume at their offsets.
type ReceiverHold = { child: ChildProcess; partial: Buffer };

type ParkedWatch = {
  run: string;
  name: string;
  pane: string;
  stream: boolean;
  offset: number;
  lines: string[];
  dropped: number;
  skipped: number;
  split: SplitState;
  carry: Buffer;
  budget: number;
  budgetTold: boolean;
};

declare global {
  var __koPiExtensionReceiver: ReceiverHold | undefined;
  var __koPiExtensionReceived: string[] | undefined;
  var __koPiExtensionWatches: ParkedWatch[] | undefined;
  var __koPiExtensionCopy: string | undefined;
  var __koPiExtensionClearQueue: AgentSession["clearQueue"] | undefined;
  var __koPiExtensionExit: (() => void) | undefined;
}

// One copy per process: pi dedupes extensions by real path only, so a second
// copy at another path must register nothing. A /reload runs the same file again
// and finds it already its own.
function isFirstCopy(): boolean {
  const path = fileURLToPath(import.meta.url);
  return (globalThis.__koPiExtensionCopy ??= path) === path;
}

// Must agree with pi's own CombinedAutocompleteProvider (extractAtPrefix), since
// the merged list carries one prefix for the agents and the files both.
function atToken(textBeforeCursor: string): string | undefined {
  const separator = /[\s"'=]|(?=\p{Punctuation})[\p{Script_Extensions=Han}\p{Script_Extensions=Hiragana}\p{Script_Extensions=Katakana}\p{Script_Extensions=Hangul}\p{Script_Extensions=Bopomofo}]|[，．：；！？（）［］｛｝“”‘’…—]/u;
  const wrappers: Record<string, string> = { "(": ")", "[": "]", "{": "}", "<": ">", "`": "`" };
  const quote = textBeforeCursor.lastIndexOf('"');
  if ((textBeforeCursor.match(/"/g)?.length ?? 0) % 2 && textBeforeCursor[quote - 1] === "@") {
    let start = quote - 1;
    while (wrappers[textBeforeCursor[start - 1]]) start--;
    if (start === 0 || separator.test(textBeforeCursor[start - 1])) return undefined;
  }
  let token = textBeforeCursor.split(separator).at(-1) ?? "";
  while (wrappers[token[0]] && !token.includes(wrappers[token[0]], 1)) token = token.slice(1);
  return token.startsWith("@") ? token.slice(1) : undefined;
}

function normalizeAddress(to: string): { wanted: string; mention: boolean } {
  const raw = to.replace(/^@/, "");
  const id = raw.match(/^(?:.* )?\(session ([^\s()]+)\)$/)?.[1];
  return { wanted: id ?? raw, mention: id !== undefined };
}

type Held = { from: Api["Sender"]; relation?: Relation; text: string };

const isString = (value: unknown): value is string => typeof value === "string";

function isRelation(value: unknown): value is Relation {
  return isString(value) && Object.hasOwn(RELATION_TEXT, value);
}

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

function isStarted(value: unknown): value is Api["Started"] {
  return isRecord(value) && isString(value.id) && isString(value.pane) && isString(value.window);
}

function isOutputEvent(value: unknown): value is Api["OutputEvent"] {
  if (!isRecord(value)) return false;
  if (value.type === "bytes") return isString(value.data) && typeof value.offset === "number";
  if (value.type === "skip") return typeof value.from === "number" && typeof value.to === "number";
  return value.type === "dead" && typeof value.at === "number" && isCause(value.cause);
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

// A data handler that hands over each complete line of a process's output.
function lineReader(hold: { partial: Buffer }, onLine: (line: string) => void): (chunk: Buffer) => void {
  return (chunk) => {
    let rest = Buffer.concat([hold.partial, chunk]);
    for (let at = rest.indexOf(0x0a); at >= 0; at = rest.indexOf(0x0a)) {
      const line = rest.subarray(0, at).toString("utf8");
      rest = rest.subarray(at + 1);
      if (line) onLine(line);
    }
    hold.partial = Buffer.from(rest);
  };
}

function openStream(ko: string, path: string, stdin: "pipe" | "ignore"): ChildProcess {
  const child = spawn(ko, ["api", "--stream", path], { stdio: [stdin, "pipe", "ignore"], env: process.env });
  child.on("error", () => {});
  child.stdin?.on("error", () => {});
  return child;
}

type Addressable = { id: string; pane: string; name: string; named: boolean; state: "running" | "ended" };

function isPosted(value: unknown): value is Api["Posted"] {
  return isRecord(value) && typeof value.seq === "number" && (value.state === "queued" || value.state === "delivered" || value.state === "acked");
}

function matchesId(row: { id: string; pane: string }, wanted: string, prefix = false): boolean {
  return prefix ? wanted.length >= MIN_ID_PREFIX && row.id.startsWith(wanted) : row.id === wanted || (row.pane !== "" && row.pane === wanted);
}

function completionValue(ids: AgentRow[], agent: AgentRow): string {
  let n = MIN_ID_PREFIX;
  while (n < agent.id.length && ids.some((other) => other !== agent && other.id.startsWith(agent.id.slice(0, n)))) n++;
  return `@${agent.name} (session ${agent.id.slice(0, n)})`;
}

function agentCompletionItems(agents: AgentRow[], all: AgentRow[], token: string): AutocompleteItem[] {
  const nameByID = new Map(agents.map((a) => [a.id, a.name]));
  const wanted = token.toLowerCase();
  const matched: Array<{ agent: AgentRow; rank: number }> = [];
  for (const a of agents) {
    if (a.self || !a.name || !a.named) continue;
    const name = a.name.toLowerCase();
    if (name.startsWith(wanted)) matched.push({ agent: a, rank: 0 });
    else if (name.split(NAME_WORD_SEPARATORS).some((word) => word.startsWith(wanted))) matched.push({ agent: a, rank: 1 });
  }
  matched.sort((x, y) => x.rank - y.rank);
  return matched.slice(0, MAX_AGENT_COMPLETIONS).map(({ agent: a }) => {
    const parent = a.parent ? nameByID.get(a.parent) || a.parent : "";
    const description = [
      a.activity ? `${a.status || "agent"} - ${a.activity}` : a.status || "agent",
      parent ? `subagent of ${parent}` : "",
    ].filter(Boolean).join(", ");
    return { value: completionValue(all, a), label: `@${a.name}`, description };
  });
}

function utf8Prefix(text: string, max: number): string {
  if (Buffer.byteLength(text, "utf8") <= max) return text;
  let out = "";
  let used = 0;
  for (const ch of text) {
    const n = Buffer.byteLength(ch, "utf8");
    if (used + n > max) break;
    out += ch;
    used += n;
  }
  return out;
}

function utf8Suffix(text: string, max: number): string {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= max) return text;
  let start = bytes.length - max;
  while (start < bytes.length && ((bytes[start] ?? 0) & 0xc0) === 0x80) start++;
  return bytes.subarray(start).toString("utf8");
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

export function streamBatch(lines: string[], alreadyDropped = 0, skippedBytes = 0): string {
  let start = Math.max(0, lines.length - STREAM_BATCH_LINES);
  let bytes = 0;
  for (let i = lines.length - 1; i >= start; i--) {
    bytes += Buffer.byteLength(lines[i], "utf8") + 1;
    if (bytes > STREAM_BATCH_BYTES) {
      start = i + 1;
      break;
    }
  }
  if (start >= lines.length && lines.length > 0) start = lines.length - 1;
  const kept = lines.slice(start).map((line) => utf8Prefix(line, STREAM_BATCH_BYTES));
  const omitted = lines.length - kept.length + alreadyDropped;
  const notes: string[] = [];
  if (omitted > 0) notes.push(`... ${omitted} lines omitted (the pane's screen has them)`);
  if (skippedBytes > 0) notes.push(`... ${skippedBytes} bytes omitted (the pane's screen has them)`);
  return [...notes, ...kept].join("\n");
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

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
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
  const liveRunRule = (rule: string): string => rule + (edge ? SUBAGENT_RESULT_RULE : "");

  const written = new Map<string, string>();

  let completion: { rows: AgentRow[]; all: AgentRow[]; at: number; refreshing: Promise<void> | null } | null = null;

  const insideKo = (): boolean => !!process.env.KO_SOCKET && findKo() !== null;

  const varsPath = (): string => `/panes/${pane}/vars`;

  const varPath = (key: string): string => `${varsPath()}/${key}`;

  const writeVars = async (entries: Array<[string, string]>): Promise<void> => {
    if (!pane) return;
    const fresh = entries.filter(([key, value]) => written.get(key) !== value);
    for (const [key, value] of fresh) {
      written.set(key, value);
      await apiCall("PUT", varPath(key), value, 2000);
    }
  };

  // The server deletes the names only while pi.session still holds this
  // session's id (412 otherwise), so a new owner of the pane keeps its variables.
  const unsetVarsBody = (): Api["DeleteVars"] => ({ names: VAR_KEYS, if: { name: VAR_SESSION, value: ownSessionId } });

  const unsetVars = async (): Promise<void> => {
    if (!pane || !ownSessionId) return;
    for (const key of VAR_KEYS) written.delete(key);
    await apiCall("DELETE", varsPath(), unsetVarsBody(), 2000);
  };

  // An uncaught crash exits without session_shutdown, so this runs at exit and
  // leaves a killed process (SIGKILL, SIGTERM) with the variables still set.
  const unsetVarsSync = (): void => {
    if (!pane || !ownSessionId) return;
    spawnSync("ko", apiArgs("DELETE", varsPath(), unsetVarsBody()), { timeout: 1000, input: JSON.stringify(unsetVarsBody()), stdio: ["pipe", "ignore", "ignore"] });
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

  const childOf = (data: Record<string, unknown>): ChildData | undefined => {
    const { name, session: id, model, cwd, pane: where } = data;
    if (typeof name !== "string" || typeof id !== "string" || typeof model !== "string" || typeof cwd !== "string" || !isRecord(where)) return undefined;
    return { owner: ownSessionId ?? "", name, session: id, model, fork: data.fork === true, cwd, pane: { instance: str(where.instance), pane: str(where.pane) } };
  };

  const children = (all = entries()): ChildData[] => {
    const current = new Map<string, ChildData>();
    for (const entry of all) {
      if (entry.customType !== ENTRY_CHILD) continue;
      const child = childOf(entry.data);
      if (child) current.set(child.name, child);
    }
    return [...current.values()];
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
    const spawned = lastIndex(all, ENTRY_CHILD, (data) => data.name === child.name);
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
    const ancestorsOf = (p: PaneInfo): PaneInfo[] => {
      const chain: PaneInfo[] = [];
      let cur = byPane.get(p.parent);
      while (cur && !chain.includes(cur)) {
        chain.push(cur);
        cur = byPane.get(cur.parent);
      }
      return chain;
    };
    const mySession = me?.session ?? "";
    const relationship = new Map<string, AgentRow["relationship"]>();
    if (me) {
      const ancestors = ancestorsOf(me);
      const peers = (of: PaneInfo): PaneInfo[] => panes.filter((p) => p.session === mySession && p.pane !== of.pane && p.parent === of.parent);
      ancestors.forEach((a, i) => {
        relationship.set(a.pane, i === 0 ? "parent" : "relative");
        for (const peer of peers(a)) if (!relationship.has(peer.pane)) relationship.set(peer.pane, "relative");
      });
      for (const peer of peers(me)) relationship.set(peer.pane, "peer");
      for (const p of panes) if (p.parent === me.pane && p.session === mySession) relationship.set(p.pane, "own");
    }
    const branch = entries();
    const marks = childMarks(branch);
    const registry = children(branch);
    const alive = new Map(registry.filter((c) => c.pane.instance === instance).map((c) => [c.pane.pane, c]));
    const reportOf = (child: ChildData): string | undefined => marks.get(child.session)?.text;
    const all: AgentRow[] = [];
    const elsewhere: AgentRow[] = [];
    for (const p of panes) {
      const child = alive.get(p.pane);
      const self = p.pane === pane;
      if (p.dead || !(isAgentPane(p) || (child && p.parent === pane))) continue;
      const parentPane = byPane.get(p.parent);
      const row: AgentRow = {
        id: p.agentSession || child?.session || p.pane,
        name: p.name || child?.name || p.title,
        named: p.name !== "" || !!child,
        pane: p.pane,
        window: p.window,
        status: p.root?.state ?? "starting",
        activity: p.activity,
        parent: parentPane?.agentSession ?? (p.parent === pane ? ownSessionId ?? "" : ""),
        depth: ancestorsOf(p).length,
        self,
        cwd: p.cwd,
        canMessage: p.inbox,
        kind: parentPane && (isAgentPane(parentPane) || parentPane.pane === pane) ? "subagent" : "agent",
        relationship: self ? "own" : relationship.get(p.pane) ?? "other",
        state: "running",
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
        depth: (me ? ancestorsOf(me).length : 0) + 1,
        self: false,
        cwd: child.cwd,
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
    const rows = all.filter((a) => !a.self && a.relationship !== "other");
    const ancestors = me ? ancestorsOf(me) : [];
    return { rows, all, elsewhere, panes, ok, me, depth: ancestors.length, ancestors: ancestors.map((a) => a.agentSession).filter(Boolean) };
  };

  const toolRow = (a: AgentRow) => {
    const { named: _named, self: _self, ...rest } = a;
    return rest;
  };

  const agentName = (a: AgentRow): string => a.name || a.id;

  type Resolution<T extends Addressable = AgentRow> = { agent: T } | { error: string };

  const decide = <T extends Addressable>(candidates: T[], wanted: string, by: "name" | "id"): Resolution<T> | null => {
    const only = candidates[0];
    if (candidates.length === 1 && only) return { agent: only };
    if (candidates.length > 1) {
      const list = candidates
        .map((a) => `${a.id} (${a.name || a.id})`)
        .sort()
        .join(", ");
      return { error: `"${wanted}" matches several by ${by}: ${list}` };
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
      return { error: `id prefixes need at least ${MIN_ID_PREFIX} characters` };
    }
    const first = matchAddress(snapshot.all, address);
    if (first) return first;
    const second = matchAddress(snapshot.elsewhere, address);
    if (second && "agent" in second) return { error: `${wanted} (${second.agent.id}) is in another session, not this one` };
    if (second) return { error: `${second.error}, none in this session` };
    return { error: `no agent session matches "${wanted}"` };
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

  const deliverNotice = (text: string, from: string): void => {
    const noticeId = mintId();
    pendingNotices.set(noticeId, { from, text });
    renderNoticeWidget();
    pi.sendMessage({ customType: NOTICE_CUSTOM_TYPE, content: `${noticeHeader(from)}\n${text}`, display: true, details: { from, noticeId } }, { deliverAs: "steer", triggerTurn: true });
  };

  const labelOf = (from: Api["Sender"]): string => (from.type === "pane" ? from.name || from.session || from.pane : "the user");

  const deliverAgentMessage = (from: string, relation: Relation, text: string, work: boolean): void => {
    const header = senderHeader(from, relation);
    pi.sendMessage(
      { customType: MESSAGE_CUSTOM_TYPE, content: `${header}\n${text}`, display: true, details: { from, header, relation, work } },
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
    deliverAgentMessage(labelOf(from), relation, held.text, relation === "parent");
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
      if (text) deliverNotice(text, labelOf(from));
      return;
    }
    if (entries().some((entry) => entry.customType === ENTRY_REPORT && entry.data.id === id)) return;
    append(ENTRY_REPORT, { child: child.session, name: child.name, text, id });
    deliverNotice(reportNotice(child, text), child.name);
  };

  const SCREEN_TAIL_BYTES = 4000;

  const screenTail = async (route: string): Promise<string | undefined> => {
    const body = apiBody(await apiCall("GET", route));
    return body === undefined ? undefined : utf8Suffix(body, SCREEN_TAIL_BYTES);
  };

  const announceEnding = async (child: ChildData, end: Api["End"] | { type: "missing" }): Promise<void> => {
    if (!claimEnding(child)) return;
    const reported = childReported(child);
    const how = end.type === "dead" ? causeText(end) : end.type === "gone" ? "its pane was removed" : "its pane is gone";
    let body = `subagent ${quote(child.name)} ended: ${how}; it had ${reported ? "reported" : "not reported on its last work"}`;
    if (!reported) {
      const tail = end.type === "dead" ? await screenTail(`/panes/${child.pane.pane}/screen?history=all`) : undefined;
      if (tail !== undefined) body += `\n--- last ${SCREEN_TAIL_BYTES} bytes of its screen ---\n${tail}`;
      body += "\nmessage it to continue it, or stop_agent to end it";
    }
    deliverNotice(body, child.name);
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
        deliverMessage({ from: m.from, relation: m.relation, text: m.text });
        return "ack";
      case "steer": {
        if (!m.text) return "ack";
        const from = labelOf(m.from);
        workStarted();
        // pi drains followUp only once the agent has decided to stop; steer joins the run under way.
        pi.sendMessage(
          { customType: STEER_CUSTOM_TYPE, content: steerHeader(from) + m.text, display: true, details: { from, work: m.relation === "parent" } },
          { deliverAs: "steer", triggerTurn: true },
        );
        return "ack";
      }
      case "interrupt": {
        turnEndedByControl = true;
        const busy = !settled;
        // pi's extension abort returns void before the active tool and run end.
        session?.abort();
        const held = { from: m.from, relation: m.relation, text: m.text };
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

  let receiver: ReceiverHold | null = null;
  let receiverData: ((chunk: Buffer) => void) | null = null;
  let receiverTimer: NodeJS.Timeout | null = null;
  let receiverBackoff = 0;
  let receiving = false;
  let queue: Promise<void> = Promise.resolve();

  const answerStream = (id: string, type: "ack" | "refuse"): void => {
    receiver?.child.stdin?.write(JSON.stringify({ type, id } satisfies Api["StreamRequest"]) + "\n");
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
    receiverBackoff = 0;
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

  const onStreamExit = (): void => {
    if (!receiving) return;
    receiver = null;
    receiverBackoff = Math.min(receiverBackoff ? receiverBackoff * 2 : envMs("KO_RECEIVER_BACKOFF_MS", 200), 5000);
    receiverTimer = setTimeout(openReceiver, receiverBackoff);
    receiverTimer.unref();
  };

  function attachReceiver(hold: ReceiverHold): void {
    receiver = hold;
    receiverData = lineReader(hold, onStreamLine);
    hold.child.stdout?.on("data", receiverData);
    hold.child.stdout?.resume();
    hold.child.on("exit", onStreamExit);
  }

  function openReceiver(): void {
    receiverTimer = null;
    if (!receiving || !ko || !pane) return;
    attachReceiver({ child: openStream(ko, `/panes/${pane}/messages`, "pipe"), partial: Buffer.alloc(0) });
  }

  const startReceiver = (): void => {
    receiving = true;
    const held = globalThis.__koPiExtensionReceiver;
    globalThis.__koPiExtensionReceiver = undefined;
    if (held && held.child.exitCode === null && held.child.signalCode === null) attachReceiver(held);
    else openReceiver();
  };

  const stopReceiver = (park: boolean): void => {
    receiving = false;
    if (receiverTimer) clearTimeout(receiverTimer);
    receiverTimer = null;
    const hold = receiver;
    receiver = null;
    if (!hold) return;
    if (receiverData) hold.child.stdout?.removeListener("data", receiverData);
    hold.child.stdout?.pause();
    hold.child.removeListener("exit", onStreamExit);
    if (park) globalThis.__koPiExtensionReceiver = hold;
    else hold.child.kill();
  };

  // ---- async_bash runs ----

  type Watch = ParkedWatch & {
    silenced: boolean;
    waiter: ChildProcess | null;
    reader: ChildProcess | null;
    readerClosed: Promise<void>;
    flushTimer: NodeJS.Timeout | null;
    idleDelay: number;
  };

  const watches = new Map<string, Watch>();

  const streamFlushMs = (): number => envMs("KO_STREAM_FLUSH_MS", 1000);
  const streamCap = (): number => envMs("KO_STREAM_MAX_WAIT_MS", 30000);

  let agentWorking = false;

  const sendStream = (watch: Watch, body: string): void => {
    pi.sendMessage(
      {
        customType: STREAM_CUSTOM_TYPE,
        content: `async run ${JSON.stringify(watch.name)} output (run ${watch.run})\n${body}`,
        display: true,
        details: { from: watch.name, run: watch.run, pane: watch.pane },
      },
      { deliverAs: "steer", triggerTurn: true },
    );
  };

  const flushWatch = (watch: Watch): boolean => {
    if (watch.lines.length === 0 && watch.skipped === 0) return false;
    if (watch.budget <= 0) {
      watch.lines = [];
      watch.dropped = 0;
      watch.skipped = 0;
      if (!watch.budgetTold) {
        watch.budgetTold = true;
        sendStream(watch, `... output budget spent; the rest is only on the pane's screen (ko api '/panes/${watch.pane}/screen?history=all')`);
      }
      return true;
    }
    const batch = streamBatch(watch.lines, watch.dropped, watch.skipped);
    watch.lines = [];
    watch.dropped = 0;
    watch.skipped = 0;
    watch.budget -= Buffer.byteLength(batch, "utf8");
    sendStream(watch, batch);
    return true;
  };

  const clearFlush = (watch: Watch): void => {
    if (watch.flushTimer) clearTimeout(watch.flushTimer);
    watch.flushTimer = null;
  };

  const scheduleFlush = (watch: Watch): void => {
    if (agentWorking || (watch.lines.length === 0 && watch.skipped === 0) || watch.flushTimer) return;
    watch.idleDelay = Math.min(watch.idleDelay, streamCap());
    watch.flushTimer = setTimeout(() => {
      watch.flushTimer = null;
      if (flushWatch(watch)) watch.idleDelay = Math.min(watch.idleDelay * 2, streamCap());
    }, watch.idleDelay);
    watch.flushTimer.unref();
  };

  const finishWorking = (): void => {
    agentWorking = false;
    for (const watch of watches.values()) if (watch.stream) scheduleFlush(watch);
  };

  const flushStreams = (): void => {
    for (const watch of watches.values()) {
      if (!watch.stream) continue;
      clearFlush(watch);
      watch.idleDelay = streamFlushMs();
      flushWatch(watch);
    }
  };

  const pushLines = (watch: Watch, lines: string[]): void => {
    if (lines.length === 0) return;
    watch.lines.push(...lines);
    if (watch.lines.length > STREAM_BUFFER_LINES) {
      watch.dropped += watch.lines.length - STREAM_BUFFER_LINES;
      watch.lines = watch.lines.slice(watch.lines.length - STREAM_BUFFER_LINES);
    }
    scheduleFlush(watch);
  };

  const onOutputRecord = (watch: Watch, line: string): void => {
    let record: unknown;
    try {
      record = JSON.parse(line);
    } catch {
      return;
    }
    if (!isOutputEvent(record)) return;
    if (record.type === "bytes") {
      const bytes = Buffer.from(record.data, "base64");
      watch.offset = record.offset + bytes.length;
      const decoded = utf8Complete(watch.carry, bytes);
      watch.carry = decoded.carry;
      pushLines(watch, splitLines(watch.split, decoded.text));
    } else if (record.type === "skip") {
      watch.skipped += record.to - record.from;
      watch.offset = record.to;
      watch.split = newSplit();
      watch.carry = Buffer.alloc(0);
      scheduleFlush(watch);
    }
  };

  const openReader = (watch: Watch): void => {
    if (!ko) return;
    const child = openStream(ko, `/panes/${watch.pane}/output?offset=${watch.offset}`, "ignore");
    watch.reader = child;
    child.stdout?.on("data", lineReader({ partial: Buffer.alloc(0) }, (line) => onOutputRecord(watch, line)));
    watch.readerClosed = new Promise((resolve) => child.on("close", () => resolve()));
  };

  const endingBody = async (watch: Watch, outcome: Outcome): Promise<string> => {
    let body = `async run ${quote(watch.name)} ${outcome.result}${outcome.text ? `: ${outcome.text}` : ""}\npane: ${watch.pane}\n`;
    const tail = (await screenTail(`/panes/${watch.pane}/screen?history=all`)) ?? (await screenTail(`/runs/${watch.run}/screen`));
    if (tail === undefined) body += "--- its screen is gone ---";
    else if (!tail.trim()) body += "--- no output ---";
    else body += `--- last ${SCREEN_TAIL_BYTES} bytes of its screen ---\n${tail}`;
    return body;
  };

  const finishWatch = async (watch: Watch, out: string): Promise<void> => {
    if (watches.get(watch.run) !== watch) return;
    const outcome = outcomeOf(out);
    if (!outcome) {
      watches.delete(watch.run);
      return;
    }
    if (watch.reader) {
      await Promise.race([watch.readerClosed, sleep(envMs("KO_STREAM_DRAIN_MS", 1500))]);
      watch.reader.kill();
    }
    clearFlush(watch);
    watches.delete(watch.run);
    if (watch.silenced) return;
    if (watch.stream) {
      const rest = watch.split.line;
      watch.split.line = "";
      pushLines(watch, rest ? [rest] : []);
      clearFlush(watch);
      flushWatch(watch);
    }
    deliverNotice(await endingBody(watch, outcome), watch.name);
  };

  const watchRun = (data: Pick<Watch, "run" | "name" | "pane" | "stream"> & Partial<ParkedWatch>): void => {
    const command = ko;
    if (!command || watches.has(data.run)) return;
    const watch: Watch = {
      run: data.run,
      name: data.name,
      pane: data.pane,
      stream: data.stream,
      silenced: false,
      waiter: null,
      reader: null,
      readerClosed: Promise.resolve(),
      offset: data.offset ?? 0,
      lines: data.lines ?? [],
      dropped: data.dropped ?? 0,
      skipped: data.skipped ?? 0,
      split: data.split ?? newSplit(),
      carry: data.carry ?? Buffer.alloc(0),
      budget: data.budget ?? envMs("KO_STREAM_BUDGET_BYTES", 256 * 1024),
      budgetTold: data.budgetTold ?? false,
      flushTimer: null,
      idleDelay: streamFlushMs(),
    };
    watches.set(watch.run, watch);
    if (watch.stream) {
      openReader(watch);
      scheduleFlush(watch);
    }
    const waiter = spawn(command, ["run-wait", watch.run, "--json"], { stdio: ["ignore", "pipe", "ignore"], env: process.env });
    watch.waiter = waiter;
    const chunks: Buffer[] = [];
    waiter.stdout?.on("data", (chunk: Buffer) => chunks.push(chunk));
    waiter.on("error", () => {});
    waiter.on("close", () => void finishWatch(watch, Buffer.concat(chunks).toString("utf8")));
  };

  const parkWatches = (): ParkedWatch[] =>
    [...watches.values()].map((watch) => ({
      run: watch.run,
      name: watch.name,
      pane: watch.pane,
      stream: watch.stream,
      offset: watch.offset,
      lines: watch.lines,
      dropped: watch.dropped,
      skipped: watch.skipped,
      split: watch.split,
      carry: watch.carry,
      budget: watch.budget,
      budgetTold: watch.budgetTold,
    }));

  const dropWatches = (): void => {
    const gone = [...watches.values()];
    watches.clear();
    for (const watch of gone) {
      clearFlush(watch);
      watch.reader?.kill();
      watch.waiter?.kill();
    }
  };

  const readRuns = async (args: string[]): Promise<RunRow[] | undefined> => {
    const command = ko;
    if (!command) return undefined;
    const res = await runCommand(command, ["runs", "--json", ...args], { timeoutMs: 2000 });
    if (!res.ok) return undefined;
    try {
      const parsed: unknown = JSON.parse(res.out);
      if (!Array.isArray(parsed)) return undefined;
      return parsed.flatMap((value): RunRow[] =>
        isRecord(value) && typeof value.id === "string"
          ? [{ id: value.id, name: str(value.name), parent: str(value.parent), pane: str(value.pane), cwd: str(value.cwd), startedAt: str(value.startedAt), outcome: parseOutcome(value.outcome) }]
          : [],
      );
    } catch {
      return undefined;
    }
  };

  const ownRuns = async (all: boolean): Promise<RunRow[] | undefined> => (pane ? readRuns([...(all ? ["--all"] : []), "--parent", pane]) : []);

  const adoptLiveRuns = async (): Promise<RunRow[] | undefined> => {
    const live = await ownRuns(false);
    for (const run of live ?? []) {
      if (!run.outcome) watchRun({ run: run.id, name: run.name ?? run.id, pane: run.pane ?? "", stream: false });
    }
    return live;
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

  const sendReport = async (report: OwnReport, once: boolean): Promise<void> => {
    if (!parentPane) return;
    const result = await sendIntent(parentPane, "notice", report.text, { id: report.id, data: { report: true }, once });
    if (result.state === "acked") append(ENTRY_SENT, { id: report.id });
    else if (result.state === "refused") append(ENTRY_SENT, { id: report.id, refused: true });
  };

  const watchParent = async (): Promise<void> => {
    if (!edge) return;
    const { ok, panes } = await listPanesResult(2000);
    if (!ok) return;
    const me = panes.find((p) => p.pane === pane);
    if (!me?.parent) return;
    parentPane = me.parent;
    const parent = panes.find((p) => p.pane === me.parent);
    if (parent && !parent.dead && parent.agentSession === edge.parent) return;
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

  // True while a bash run of this agent lives or a child of it owes a report; undefined when that is unreadable.
  const ownLiveWork = async (): Promise<boolean | undefined> => {
    const live = await adoptLiveRuns();
    if (!live) return undefined;
    if (live.length > 0) return true;
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
    task: string;
    mode: { kind: "fresh" } | { kind: "continue"; file: string } | { kind: "copy"; file: string };
    toplevel: boolean;
    koSession: string;
  };

  const taskVar = (task: string): unknown => ({ text: task, from: { session: ownSessionId, name: pi.getSessionName() ?? "", pane } });

  const taskTooLarge = (task: string): boolean => Buffer.byteLength(JSON.stringify(taskVar(task)), "utf8") > MAX_TASK_BYTES;

  const createPane = async (plan: Plan): Promise<{ placement: Api["Placement"] } | { error: string }> => {
    if (!ko) return { error: "ko is not on PATH" };
    const trusted = await trustedCwd(plan.cwd);
    const argv = [
      ko, "shell", "--", "ko-pi",
      ...(plan.mode.kind === "continue" ? ["--session", plan.mode.file] : ["--session-id", plan.session]),
      "--name", plan.name,
      "--model", plan.model,
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
      command: { type: "argv", argv },
      env,
      ...(plan.toplevel ? { session: plan.koSession } : { parent: pane ?? undefined, close: "on_exit" as const }),
      ...(plan.task ? { vars: { [VAR_TASK]: taskVar(plan.task) } } : {}),
    };
    const answer = await apiCall("POST", "/panes", body, envMs("KO_SPAWN_TIMEOUT_MS", 5000));
    const placement = apiJson(answer);
    return isPlacement(placement) ? { placement } : { error: apiError(answer).message };
  };

  const recordChild = (plan: Plan, placement: Api["Placement"]): void => {
    append(ENTRY_CHILD, {
      name: plan.name,
      session: plan.session,
      model: plan.model,
      fork: plan.mode.kind === "copy",
      cwd: plan.cwd,
      pane: { instance, pane: placement.pane },
    });
    if (plan.task) append(ENTRY_WORK, { child: plan.session });
  };

  const restartChild = (child: ChildData, task: string): Promise<{ placement: Api["Placement"] } | { running: AgentRow } | { error: string }> =>
    withRestartLock(child.session, async () => {
      const snapshot = await discovery();
      if (!snapshot.ok) return { error: "could not read the layout" };
      const row = snapshot.all.find((a) => a.id === child.session);
      if (row && row.state === "running") return { running: row };
      const plan: Plan = { name: child.name, session: child.session, model: child.model, cwd: child.cwd, task, mode: { kind: "fresh" }, toplevel: false, koSession: snapshot.me?.session ?? "" };
      const made = await createPane(plan);
      if ("error" in made) return made;
      recordChild(plan, made.placement);
      return made;
    });

  // ---- the task and the endings that happened while this agent was away ----

  const deliverTask = async (): Promise<void> => {
    if (!pane) return;
    const { ok, panes } = await listPanesResult();
    if (!ok) return;
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
        deliverAgentMessage(str(from.name) || str(from.session) || "another agent", "sibling", text, false);
      }
    }
    await apiCall("DELETE", varPath(VAR_TASK));
  };

  const reconcileChildren = async (): Promise<void> => {
    const { ok, panes } = await listPanesResult();
    if (!ok) return;
    await readInstance();
    for (const child of children()) {
      if (endedAfter(child)) continue;
      const row = child.pane.instance === instance ? panes.find((p) => p.pane === child.pane.pane) : undefined;
      if (row && !row.dead) continue;
      await announceEnding(child, row?.dead ? { type: "dead", ...row.dead } : { type: "missing" });
    }
  };

  const stopOwnRuns = async (): Promise<void> => {
    const command = ko;
    const live = command ? await ownRuns(false) : undefined;
    if (!command || !live) return;
    await Promise.all(live.filter((run) => !run.outcome).map((run) => runCommand(command, ["run-stop", run.id], { timeoutMs: 3000 })));
  };

  // ---- rendering ----

  const inboundExpanded = new Map<string, boolean>();

  const renderInbound = (message: Parameters<MessageRenderer>[0], theme: Pick<Theme, "fg">, sender: string | undefined, verb: string | undefined, body: string) => {
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

  pi.registerMessageRenderer<{ from: string; header?: string }>(MESSAGE_CUSTOM_TYPE, (message, _options, theme) => {
    const raw = typeof message.content === "string" ? message.content : "";
    const header = message.details?.header ? `${message.details.header}\n` : "";
    return renderInbound(message, theme, message.details?.from, "says", header && raw.startsWith(header) ? raw.slice(header.length) : raw);
  });

  pi.registerMessageRenderer<{ from: string }>(STEER_CUSTOM_TYPE, (message, _options, theme) => {
    const raw = typeof message.content === "string" ? message.content : "";
    const header = steerHeader(message.details?.from ?? "");
    return renderInbound(message, theme, message.details?.from, "redirects", raw.startsWith(header) ? raw.slice(header.length) : raw);
  });

  pi.registerMessageRenderer<{ from: string }>(NOTICE_CUSTOM_TYPE, (message, _options, theme) => {
    const from = message.details?.from || "another agent";
    const raw = typeof message.content === "string" ? message.content : "";
    const header = `${noticeHeader(from)}\n`;
    const content = raw.startsWith(header) ? raw.slice(header.length) : raw;
    return renderInbound(message, theme, message.details?.from, "notifies", content);
  });

  pi.registerMessageRenderer<{ from: string }>(STREAM_CUSTOM_TYPE, (message, _options, theme) => {
    const content = typeof message.content === "string" ? message.content : "";
    return renderInbound(message, theme, message.details?.from, undefined, content.slice(content.indexOf("\n") + 1));
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
      "List the agents you can message: your subagents, your peers, each ancestor and its peers, in this session. which selects all (default), peers or subagents. An own subagent's row says whether it has reported on its last work and starts its last report; read_report gives the whole text. Bash jobs are in list_async_bash.",
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
      "List your own async_bash jobs: all running and the newest 20 ended, newest first, with the run id that stop_async_bash takes and the pane whose screen holds the output.",
    promptSnippet: "list_async_bash() - your own async_bash jobs, with the pane whose screen holds the output",
    parameters: Type.Object({}, { additionalProperties: false }),
    async execute() {
      const runs = await ownRuns(true);
      if (!runs) return reply("could not list async_bash jobs: ko runs failed");
      const newest = [...runs].sort((a, b) => (b.startedAt ?? "").localeCompare(a.startedAt ?? ""));
      let ended = 0;
      const listed = newest
        .filter((run) => !run.outcome || ++ended <= 20)
        .map((run) => ({
          run: run.id,
          name: run.name,
          state: run.outcome ? "ended" : "running",
          outcome: run.outcome,
          startedAt: run.startedAt,
          pane: run.pane,
          screen: `ko api '/panes/${run.pane}/screen?history=all'`,
        }));
      return reply(JSON.stringify(listed), listed);
    },
  });

  pi.registerTool({
    name: "message_agent",
    label: "Message Agent",
    description:
      "Send text to an agent by name, session id, or unique id prefix. message (default) queues for any agent until its current turn ends; to an ended subagent of yours it resumes that subagent in its own session, with its history, and the message is its next turn. steer joins the current turn of any agent in your scope. interrupt-and-steer aborts the current turn of any agent in your scope, then starts a new turn with the text.",
    promptSnippet: "message_agent(to, message, mode?) - send a message to another agent in this session",
    parameters: Type.Object(
      {
        to: Type.String({
          description: `Who to message: an agent's exact name, session id, a unique id prefix of at least ${MIN_ID_PREFIX} characters, or an @-mention from the prompt such as @impl (session 9702ddd1).`,
        }),
        message: Type.String({ description: "The message text to deliver." }),
        mode: Type.Optional(Type.Union([Type.Literal("message"), Type.Literal("steer"), Type.Literal("interrupt-and-steer")], {
          description: "message queues until the turn ends, and resumes an ended subagent of yours with its history (default). steer joins the current turn of any agent in your scope. interrupt-and-steer aborts its current turn, then starts a new turn with the text.",
        })),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      if (!params.message) return reply(`could not message ${params.to}: the message is empty; nothing sent`);
      if (!params.message.isWellFormed()) return reply(`could not message ${params.to}: the message is not valid UTF-8`);
      if (Buffer.byteLength(params.message, "utf8") > MAX_MESSAGE_BYTES) return reply(`could not message ${params.to}: the message is over ${MAX_MESSAGE_BYTES} bytes`);
      const mode = params.mode ?? "message";
      const snapshot = await discovery();
      if (!snapshot.ok) return reply(`could not message ${params.to}: could not read the layout`);
      const resolved = resolveIn(snapshot, normalizeAddress(params.to));
      if ("error" in resolved) return reply(`could not message ${params.to}: ${resolved.error}`);
      let target = resolved.agent;
      const name = agentName(target);
      if (target.self) return reply(`${name} is this agent`);
      const child = target.relationship === "own" ? children().find((c) => c.session === target.id) : undefined;
      if (target.state === "ended") {
        if (!child || mode !== "message") return reply(`could not message ${params.to}: ${name} is no longer running`);
        const restarted = await restartChild(child, params.message);
        if ("error" in restarted) return reply(`could not message ${params.to}: ${restarted.error}`);
        if ("placement" in restarted) return reply(`restarted ${name} in pane ${restarted.placement.pane}; ${liveRunRule(SPAWN_RESULT_RULE)}`);
        target = restarted.running;
      }
      if (child) markChildWork(child);
      const kind: SendKind = mode === "interrupt-and-steer" ? "interrupt" : mode;
      const result = await sendIntent(target.pane, kind, params.message);
      const sent = deliveryText(name, mode, result, target.status === "working", true);
      return reply(sent.ok ? sent.text : `could not message ${params.to}: ${sent.text}`);
    },
  });

  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn Agent",
    description:
      "Start an agent in a new window. Resume a saved session or fork a copy of it; fork alone copies this session. Returns the pi session id for later resume_from. Children report by notice and stay alive. A toplevel agent is an independent peer: no report, notice, depth limit or descendant controls; fork is allowed, but an existing child cannot become a peer.",
    promptSnippet:
      "spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?) - start, resume or copy an agent in a new window; returns its pi session id; toplevel starts an independent peer, not a child",
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
        name: Type.String({ description: "Window and session name. Unique among this caller's children; for toplevel, unique among live agents in the session. Resume an ended child with its existing name." }),
        model: Type.Optional(
          Type.String({
            description:
              'Model as provider/model-id[:thinking]. Default: caller’s current model and thinking level. Required if the caller has no model. Bare aliases are refused; see pi --list-models.',
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
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const refuse = (text: string) => reply(`could not spawn agent: ${text}`);
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
      const model = params.model ?? (ctx.model ? `${ctx.model.provider}/${ctx.model.id}:${pi.getThinkingLevel()}` : null);
      if (!model) return refuse("caller has no model; specify model");
      if (params.model) {
        const error = await validateModel(model);
        if (error) return refuse(error);
      }
      let source: { id: string; path: string; cwd: string } | undefined;
      if (params.resume_from) {
        const wanted = params.resume_from;
        const sessionDir = ctx.sessionManager.getSessionDir();
        const directories = new Set([sessionDir]);
        try {
          for (const entry of readdirSync(dirname(sessionDir), { withFileTypes: true })) {
            if (entry.isDirectory() || entry.isSymbolicLink()) directories.add(join(dirname(sessionDir), entry.name));
          }
        } catch {}
        const files: { id: string; path: string }[] = [];
        for (const directory of directories) {
          try {
            for (const file of readdirSync(directory)) {
              const id = /_([^_]+)\.jsonl$/.exec(file)?.[1];
              if (id) files.push({ id, path: join(directory, file) });
            }
          } catch {}
        }
        const exact = files.filter((file) => file.id === wanted);
        if (!exact.length && wanted.length < MIN_ID_PREFIX) return refuse(`session prefixes need at least ${MIN_ID_PREFIX} characters`);
        const matches = exact.length ? exact : files.filter((file) => file.id.startsWith(wanted));
        if (matches.length !== 1) return refuse(matches.length
          ? `${quote(wanted)} matches several sessions by id: ${matches.slice(0, 5).map((file) => file.id).sort().join(", ")}`
          : `unknown session ${quote(wanted)}`);
        const file = matches[0];
        if (!file) return refuse(`unknown session ${quote(wanted)}`);
        const fd = openSync(file.path, "r");
        try {
          const buffer = Buffer.alloc(4096);
          const chunks: Buffer[] = [];
          for (let bytes = 0; bytes < 1024 * 1024;) {
            const count = readSync(fd, buffer, 0, buffer.length, bytes);
            if (!count) break;
            bytes += count;
            const chunk = Buffer.from(buffer.subarray(0, count));
            chunks.push(chunk);
            if (chunk.includes(10)) break;
          }
          const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8").split("\n", 1)[0] ?? "");
          if (!isRecord(parsed) || parsed.type !== "session" || parsed.id !== file.id || typeof parsed.cwd !== "string") return refuse(`invalid session header: ${file.path}`);
          source = { ...file, cwd: parsed.cwd };
        } catch { return refuse(`invalid session header: ${file.path}`); }
        finally { closeSync(fd); }
      }
      const forkFile = params.fork ? source?.path ?? ctx.sessionManager.getSessionFile() : undefined;
      if (params.fork && !forkFile) return refuse("caller has no session file to copy");
      const mode: Plan["mode"] = forkFile ? { kind: "copy", file: forkFile } : source ? { kind: "continue", file: source.path } : { kind: "fresh" };
      const toplevel = !!params.toplevel;
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
        if (mode.kind === "continue" && snapshot.panes.some((p) => p.agentSession === childSession && !p.dead)) return refuse(`session ${childSession} is live in a pane`);
        const existing = mode.kind === "continue" ? children().find((c) => c.session === childSession) : undefined;
        if (existing && (toplevel || existing.name !== name)) return refuse("resume this child with its existing name and without toplevel");
        if (!claimName(name)) return taken();
        try {
          const wanted = name.toLowerCase();
          const holds = toplevel
            ? [...snapshot.all].some((a) => a.state === "running" && a.name.toLowerCase() === wanted)
            : !existing && ([...children()].some((c) => c.name.toLowerCase() === wanted) || snapshot.all.some((a) => a.relationship === "own" && a.name.toLowerCase() === wanted));
          if (holds) return taken();
          if (!toplevel && snapshot.depth + 1 > MAX_DEPTH) return refuse(`refusing to spawn at depth ${snapshot.depth + 1}: maximum nesting is ${MAX_DEPTH} (root 0, subagent 1, subagent 2)`);
          const plan: Plan = {
            name,
            session: childSession,
            model,
            cwd,
            task,
            mode,
            toplevel,
            koSession: snapshot.me.session,
          };
          const made = await createPane(plan);
          if ("error" in made) return refuse(made.error);
          if (!toplevel) recordChild(plan, made.placement);
          const { window, pane: childPane } = made.placement;
          return reply(
            `spawned ${name} (session ${childSession}, window ${window}, pane ${childPane})${mode.kind === "copy" ? `, forked from session ${source?.id ?? ownSessionId}` : ""}; session id is what resume_from takes later; ${toplevel ? "independent peer; no report or ending notice" : task ? liveRunRule(SPAWN_RESULT_RULE) : SPAWN_RESULT_RULE}`,
            { session: childSession, name, window, pane: childPane, fork: mode.kind === "copy" },
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
      "Run a shell command in the background, for a command whose result you do not need for your next step - this session keeps working while it runs. Exactly one notice arrives when the command ends, carrying its exit status and a tail of its output. Its output is the pane's screen: read it with ko api /panes/PANE/screen?history=all meanwhile. With stream=true the new lines arrive in batches. list_async_bash lists it and stop_async_bash stops it. If your next step needs the result and you have nothing else to do meanwhile, use bash with a timeout instead.",
    promptSnippet:
      "async_bash(command, name, stream?) - run a command in the background; a notice with its exit status arrives when it ends, read the pane's screen meanwhile; list_async_bash lists it and stop_async_bash stops it",
    promptGuidelines: [
      "Use async_bash when you can do other work while a command runs, when someone (the user, your parent or a child) may need an answer from you meanwhile, when you start several independent jobs at once, or for a server that keeps running. Once a command is in async_bash, its notice is the only way you learn that it ended: never run `sleep` in bash to wait for it, and never loop over its screen. If you have nothing else to do, end your turn; the notice wakes you.",
      "Use async_bash instead of background bash jobs (`nohup`, a trailing `&`, `setsid`, `disown`).",
      "list_async_bash lists an async_bash job and stop_async_bash stops it by its run id.",
      NOT_THE_USER_RULE,
    ],
    parameters: Type.Object(
      {
        command: Type.String({
          description:
            'The command to run in the background, as a shell command line (e.g. "make -j8 && ./run"), run under bash -c.',
        }),
        name: Type.String({ description: "A name for the run and its window; it must be unique among this session's runs, since a reused name is refused." }),
        stream: Type.Optional(
          Type.Boolean({
            description:
              "Send the command's output to this session in batches while it runs, instead of only at the end. Off by default.",
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const command = ko;
      if (!command) return reply("could not start background command: ko is not on PATH");
      if (!params.name) return reply("could not start background command: --name is required");
      const nameError = checkName(params.name);
      if (nameError) return reply(`could not start background command: ${nameError}`);
      const taken = `could not start background command: the name ${quote(params.name)} is already taken by one of this session's runs; choose another name`;
      if (!claimName(params.name)) return reply(taken);
      try {
        if (!pane) return reply("could not start background command: this session has no pane to parent a run from");
        const wanted = params.name.toLowerCase();
        const runs = (await ownRuns(true)) ?? [];
        if (runs.some((r) => (r.name ?? "").toLowerCase() === wanted) || children().some((c) => c.name.toLowerCase() === wanted)) return reply(taken);
        const res = await runCommand(command, ["run-child", pane, "--name", params.name, "--", "bash", "-o", "pipefail", "-c", params.command], { timeoutMs: envMs("KO_SPAWN_TIMEOUT_MS", 5000) });
        if (!res.ok) return reply(`could not start background command: ${res.error}`);
        let started: unknown;
        try {
          started = JSON.parse(res.out);
        } catch {}
        if (!isStarted(started)) return reply("could not start background command: ko printed no run");
        watchRun({ run: started.id, name: params.name, pane: started.pane, stream: !!params.stream });
        return reply(
          `started run ${started.id} (${params.name}) in window ${started.window}, pane ${started.pane}; list_async_bash lists it and stop_async_bash stops it; ` +
            `a notice with its exit status and a tail of its screen arrives when it ends and starts your next turn; you stay alive while it runs, so ending your turn now is safe - do not sleep or poll for it, and end your turn if nothing else is left - ` +
            liveRunRule(params.stream
              ? `batches of its new lines arrive meanwhile, capped; its whole output is the pane's screen: ko api '/panes/${started.pane}/screen?history=all'`
              : `its output is the pane's screen: read it with ko api '/panes/${started.pane}/screen?history=all' to check on it meanwhile`),
          { name: params.name, window: started.window, pane: started.pane, run: started.id, stream: !!params.stream },
        );
      } finally {
        releaseName(params.name);
      }
    },
  });

  pi.registerTool({
    name: "stop_async_bash",
    label: "Stop Async Bash",
    description:
      "Stop one of your async_bash jobs by run id, name or unique id prefix; its pane is killed and lingers for a while with its last output.",
    promptSnippet: "stop_async_bash(run) - stop one of your async_bash jobs",
    parameters: Type.Object(
      {
        run: Type.String({ description: `A run id of list_async_bash, its name, or a unique id prefix of at least ${MIN_ID_PREFIX} characters.` }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const command = ko;
      if (!command) return reply("could not stop: ko is not on PATH");
      const runs = await ownRuns(true);
      if (!runs) return { ...reply("could not stop: ko runs failed"), isError: true };
      const jobs = runs.map((job) => ({ id: job.id, pane: job.pane ?? "", name: job.name ?? "", named: true, state: job.outcome ? ("ended" as const) : ("running" as const), job }));
      const found = matchAddress(jobs, normalizeAddress(params.run));
      if (!found) return { ...reply(`${quote(params.run)}: error: no async_bash job matches`), isError: true };
      if ("error" in found) return { ...reply(`${quote(params.run)}: error: ${found.error}`), isError: true };
      const run = found.agent.job;
      const screen = `ko api '/panes/${run.pane}/screen?history=all' while the pane lingers, then ko api /runs/${run.id}/screen`;
      const had = `run ${run.id} (${run.name}) had already ended`;
      if (run.outcome) return reply(`${had}: ${run.outcome.result}${run.outcome.text ? `: ${run.outcome.text}` : ""}; its output: ${screen}`);
      const watch = watches.get(run.id);
      if (watch) watch.silenced = true;
      const res = await runCommand(command, ["run-stop", run.id], { timeoutMs: STOP_CALL_MS });
      if (res.ok) return reply(`${res.out}; pane ${run.pane}; its output: ${screen}`);
      if (res.code === 5) return reply(`${had}; its output: ${screen}`);
      if (watch) watch.silenced = false;
      return { ...reply(`could not stop ${run.id}: ${res.error}`), isError: true };
    },
  });

  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.promptGuidelines.push(NEVER_SLEEP_RULE);
    if (edge) event.systemPromptOptions.promptGuidelines.push(SUBAGENT_INSTRUCTION);
  });

  // ---- the session ----

  pi.on("session_start", async (_event, ctx) => {
    ko = insideKo() ? findKo() : null;
    session = ctx;
    ownSessionId = ctx.sessionManager.getSessionId() || null;
    pane = process.env.KO_PANE || null;
    const parent = process.env.KO_AGENT_PARENT_SESSION;
    edge = ownSessionId && parent && process.env.KO_AGENT_SESSION === ownSessionId ? { parent } : null;
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
      const cache: { rows: AgentRow[]; all: AgentRow[]; at: number; refreshing: Promise<void> | null } = { rows: [], all: [], at: 0, refreshing: null };
      completion = cache;
      ui.addAutocompleteProvider((current: AutocompleteProvider): AutocompleteProvider => ({
        triggerCharacters: current.triggerCharacters,
        async getSuggestions(lines, cursorLine, cursorCol, options) {
          const token = atToken((lines[cursorLine] ?? "").slice(0, cursorCol));
          if (token === undefined) return current.getSuggestions(lines, cursorLine, cursorCol, options);
          if (!cache.refreshing && Date.now() - cache.at >= envMs("KO_AGENT_LIST_TTL_MS", 1000)) {
            cache.refreshing = discovery()
              .then(({ rows, all }) => {
                cache.all = all;
                cache.rows = rows.filter((a) => a.state !== "ended");
                cache.at = Date.now();
              })
              .catch(() => {})
              .finally(() => {
                cache.refreshing = null;
              });
          }
          const items = agentCompletionItems(cache.rows, cache.all, token);
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

    active = false;
    if (!ctx.hasUI || !ownSessionId || !ko || !pane) return;
    active = true;

    startReceiver();
    await writeVars([
      [VAR_SESSION, ownSessionId],
      [VAR_NAME, pi.getSessionName() ?? ""],
    ]);
    await readInstance();
    await deliverTask();
    const parked = globalThis.__koPiExtensionWatches;
    globalThis.__koPiExtensionWatches = undefined;
    for (const data of parked ?? []) watchRun(data);
    await adoptLiveRuns();
    await reconcileChildren();
    startTick();
  });

  pi.on("session_info_changed", async () => {
    await writeVars([[VAR_NAME, pi.getSessionName() ?? ""]]);
  });

  const running = (): void => {
    agentWorking = true;
    beginWork();
  };
  pi.on("agent_start", () => {
    workStarted();
    running();
  });
  pi.on("turn_start", running);
  pi.on("tool_execution_start", running);
  pi.on("tool_call", running);
  pi.on("turn_end", (event: { toolResults?: unknown[] }) => {
    if (event?.toolResults?.length) flushStreams();
  });

  pi.on("agent_end", (event: { messages?: { role?: string; stopReason?: string; errorMessage?: string; content?: unknown }[] }) => {
    finishWorking();
    const assistants = (event?.messages ?? []).filter((m) => m?.role === "assistant");
    const last = assistants[assistants.length - 1];
    if (!last) {
      ending = { kind: "ended", text: "" };
      return;
    }
    const blocks = Array.isArray(last.content) ? last.content : [];
    const text = blocks.flatMap((block) => (isRecord(block) && block.type === "text" && typeof block.text === "string" ? [block.text] : [])).join("");
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
    const reason = event?.reason;
    stopTick();
    if (reason === "reload") {
      stopReceiver(true);
      globalThis.__koPiExtensionWatches = parkWatches();
      dropWatches();
    } else {
      globalThis.__koPiExtensionWatches = undefined;
      if (reason === "quit" && edge && leaving === null && active) {
        const text = exitNoticeText();
        exitNoticeId ||= mintId();
        if (text) await statusNotice(text, exitNoticeId);
      }
      if (active) await stopOwnRuns();
      dropWatches();
      stopReceiver(false);
      if (active) await unsetVars();
      if (globalThis.__koPiExtensionExit === unsetVarsSync) {
        process.removeListener("exit", unsetVarsSync);
        globalThis.__koPiExtensionExit = undefined;
      }
    }
    active = false;
    session = null;
  });
}
