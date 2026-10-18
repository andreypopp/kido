import { AgentSession, type ExtensionAPI, type MessageRenderer, type Theme } from "@earendil-works/pi-coding-agent";
import { type TuiMouseEvent, truncateToWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { type ChildProcess, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, closeSync, constants, mkdirSync, openSync, readFileSync, readdirSync, readSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";

const SOCKET_PATH_MAX = 103;

const MAX_PROMPT_BYTES = 1024 * 1024;

const KIDO_TIMEOUT_MS = 5000;

const OPTION_SESSION = "@kido_session";
const OPTION_NAME = "@kido_name";
const OPTION_INBOX = "@kido_inbox";
const OPTION_ACTIVITY = "@kido_activity";
const OPTION_KEYS = [OPTION_SESSION, OPTION_NAME, OPTION_INBOX, OPTION_ACTIVITY];

const PANE_FORMAT = [
  "#{pane_id}",
  "#{session_id}",
  "#{window_id}",
  "#{@kido_session}",
  "#{@kido_name}",
  "#{@kido_inbox}",
  "#{@kido_activity}",
  "#{pane_current_path}",
  "#{pane_program_status}",
  "#{pane_title}",
].join("\x1f");

const PANE_SEPARATOR = "\x1f";

export type DeliverAs = "followUp" | "steer";

export type Sender = { session: string; name?: string; pane?: string };

export type Envelope = { id: string; from: Sender; text: string } & (
  | { kind: "message" | "ask" | "notice" | "steer" | "interrupt" | "stop" }
  | { kind: "reply"; replyTo: string }
  | { kind: "unrecognised"; claimed: string }
);

type RunResult = { ok: true; out: string } | { ok: false; error: string; code?: number };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function parseEnvelope(text: string): Envelope | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isRecord(parsed) || Array.isArray(parsed)) return null;
  const obj = parsed;
  if (!("v" in obj) || !("kind" in obj)) return null;
  const str = (v: unknown): string => (typeof v === "string" ? v : "");
  const from = isRecord(obj.from) ? obj.from : {};
  const [session, name, pane] = [str(from.session), str(from.name), str(from.pane)];
  const sender: Sender = { session, name: name || undefined, pane: pane || undefined };
  const base = { id: str(obj.id), from: sender, text: str(obj.text) };
  const kind = str(obj.kind);
  switch (kind) {
    case "message":
    case "ask":
    case "notice":
    case "steer":
    case "interrupt":
    case "stop":
      return { ...base, kind };
    case "reply":
      return { ...base, kind, replyTo: str(obj.replyTo) };
    default:
      return { ...base, kind: "unrecognised", claimed: kind };
  }
}

function findKido(): string | null {
  const path = process.env.PATH;
  if (!path) return null;
  for (const dir of path.split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, "kido");
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {}
  }
  return null;
}

export function stateDir(env: NodeJS.ProcessEnv = process.env): string {
  if (env.KIDO_PI_STATE_DIR) return env.KIDO_PI_STATE_DIR;
  if (env.XDG_STATE_HOME) return join(env.XDG_STATE_HOME, "kido-pi");
  return join(homedir(), ".local", "state", "kido-pi");
}

function inboxPath(dir: string, session: string): string | null {
  const path = join(dir, "inbox", session + ".sock");
  if (session.includes("/") || session.includes("..")) return null;
  if (Buffer.byteLength(path, "utf8") > SOCKET_PATH_MAX) return null;
  return path;
}

type AgentRecord = { session: string; run: string; model: string; tools: string[]; fork: boolean };

type AgentEntry = AgentRecord & { name: string; parent: string; dir: string };

function readAgentRecord(dir: string): AgentRecord | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(join(dir, "agent.json"), "utf8"));
    if (!isRecord(parsed) || typeof parsed.session !== "string" || typeof parsed.run !== "string") return null;
    const list = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
    return {
      session: parsed.session,
      run: parsed.run,
      model: typeof parsed.model === "string" ? parsed.model : "",
      tools: list(parsed.tools),
      fork: parsed.fork === true,
    };
  } catch {
    return null;
  }
}

function childEntries(root: string, parent: string): AgentEntry[] {
  let names: string[];
  try {
    names = readdirSync(join(root, parent));
  } catch {
    return [];
  }
  const entries: AgentEntry[] = [];
  for (const name of names) {
    const dir = join(root, parent, name);
    const record = readAgentRecord(dir);
    if (record) entries.push({ ...record, name, parent, dir });
  }
  return entries;
}

function agentEntries(dir: string): AgentEntry[] {
  const root = join(dir, "agents");
  let parents: string[];
  try {
    parents = readdirSync(root);
  } catch {
    return [];
  }
  return parents.flatMap((parent) => childEntries(root, parent));
}

function ownEntries(dir: string, parent: string): AgentEntry[] {
  return childEntries(join(dir, "agents"), parent);
}

function canReply(entry: AgentEntry | undefined, inbox: string): boolean {
  return inbox !== "" && (entry === undefined || entry.tools.length === 0 || entry.tools.includes("message_agent"));
}

const cannotReply = (name: string): string =>
  `${name} was spawned without the message_agent tool and cannot reply; use message_agent, or wait for its notify_parent notice`;

function chain(bySession: Map<string, AgentEntry>, start: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  let cur = start;
  while (cur && !seen.has(cur)) {
    seen.add(cur);
    out.push(cur);
    cur = bySession.get(cur)?.parent ?? "";
  }
  return out;
}

async function runCommand(command: string, args: string[], opts: { timeoutMs: number } = { timeoutMs: KIDO_TIMEOUT_MS }): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], env: process.env });
    const finish = (result: RunResult): void => {
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish({ ok: false, error: `${command} timed out after ${opts.timeoutMs}ms` });
    }, opts.timeoutMs);
    timer.unref();
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout?.on("data", (c: Buffer) => stdout.push(c));
    child.stderr?.on("data", (c: Buffer) => stderr.push(c));
    child.on("error", (err) => finish({ ok: false, error: err instanceof Error ? err.message : String(err) }));
    child.on("close", (code) => {
      if (code === 0) finish({ ok: true, out: Buffer.concat(stdout).toString("utf8").trim() });
      else finish({ ok: false, error: Buffer.concat(stderr).toString("utf8").trim() || `${command} exited with code ${code}`, ...(code === null ? {} : { code }) });
    });
  });
}

export type PaneInfo = {
  pane: string;
  session: string;
  window: string;
  agentSession: string;
  name: string;
  inbox: string;
  activity: string;
  cwd: string;
  programStatus: string;
  title: string;
};

function rootRecord(programStatus: string): { app: string; state: string } | null {
  if (!programStatus) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(programStatus);
  } catch {
    return null;
  }
  if (!isRecord(parsed) || !Array.isArray(parsed.records)) return null;
  const root = parsed.records.find((r: unknown) => isRecord(r) && r.id === "");
  if (!isRecord(root)) return null;
  return {
    app: typeof root.app === "string" ? root.app : "",
    state: typeof root.state === "string" ? root.state : "unknown",
  };
}

function isAgentPane(pane: PaneInfo): boolean {
  return pane.agentSession !== "" && rootRecord(pane.programStatus)?.app === "pi";
}

function parsePanes(out: string): PaneInfo[] {
  const panes: PaneInfo[] = [];
  for (const line of out.split("\n")) {
    const fields = line ? line.split(PANE_SEPARATOR) : [];
    if (fields.length !== 10) continue;
    panes.push({
      pane: fields[0],
      session: fields[1],
      window: fields[2],
      agentSession: fields[3],
      name: fields[4],
      inbox: fields[5],
      activity: fields[6],
      cwd: fields[7],
      programStatus: fields[8],
      title: fields[9],
    });
  }
  return panes;
}

async function listPanesResult(timeoutMs = KIDO_TIMEOUT_MS): Promise<{ ok: boolean; panes: PaneInfo[] }> {
  const res = await runCommand("tmux", ["list-panes", "-a", "-F", PANE_FORMAT], { timeoutMs });
  return res.ok ? { ok: true, panes: parsePanes(res.out) } : { ok: false, panes: [] };
}

async function listPanes(timeoutMs = KIDO_TIMEOUT_MS): Promise<PaneInfo[]> {
  return (await listPanesResult(timeoutMs)).panes;
}

const NOTICE_CUSTOM_TYPE = "kido-notice";

const noticeHeader = (from: string): string => `notice from ${from} (a subagent or background run's report, not the user):`;

const MESSAGE_CUSTOM_TYPE = "kido-message";

const RELATIONS = ["parent", "child", "peer"] as const;
type SenderRelation = (typeof RELATIONS)[number];

const MESSAGE_RELATION: Record<SenderRelation, string> = {
  parent: "your parent, who spawned you",
  child: "your subagent",
  peer: "another agent in this session, not the user",
};

const senderHeader = (kind: "message" | "ask", from: string, relation: SenderRelation): string =>
  `${kind} from @${from} (${MESSAGE_RELATION[relation]}):`;

const ASK_CUSTOM_TYPE = "kido-ask";

const REPLY_CUSTOM_TYPE = "kido-reply";

const replyHeader = (from: string, replyTo: string): string => `${from} replied (to ask ${replyTo}): `;

const inboundHeader = (sender: string | undefined, verb: string | undefined): string =>
  `${sender && sender !== "another agent" ? `@${sender}` : "another agent"}${verb ? ` ${verb}` : ""}:`;

const NAME_WORD_SEPARATORS = /[\s\-_/]+/;

const MIN_ID_PREFIX = 8;

const MAX_AGENT_COMPLETIONS = 10;

const MAX_NOTICE_BYTES = 4000;

const DEFAULT_ASK_TIMEOUT_MS = 5 * 60 * 1000;

const MAX_TASK_BYTES = 1024 * 1024;

const MAX_DEPTH = 2;

const MAX_NAME_BYTES = 64;

const STREAM_CUSTOM_TYPE = "kido-stream";

const STREAM_BATCH_LINES = 200;

const STREAM_BATCH_BYTES = 16 * 1024;

const STREAM_BUFFER_LINES = 5000;

const PARENT_GUIDANCE =
  "\n\nThe child stays alive after it reports. End it with stop_run when you need nothing more from it. To continue it, use message_agent.";

const envMs = (key: string, fallback: number): number => Number(process.env[key]) || fallback;

const reply = (text: string, details: unknown = {}) => ({ content: [{ type: "text" as const, text }], details });

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));


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
  canReply: boolean;
  model: string;
  kind: "agent" | "subagent" | "bash";
  relationship: "parent" | "peer" | "own" | "other";
  run: string;
  state: "running" | "ended";
  tmux: string;
  inbox: string;
  startedAt?: string;
  outcome?: { result: string; text?: string };
  task?: string;
  report?: string;
};

type RunRow = {
  id: string;
  name?: string;
  parent?: string;
  pane?: string;
  cwd?: string;
  startedAt?: string;
  session?: string;
  output?: string;
  outcome?: { result: string; text?: string };
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
const clearQueue = (globalThis.__kidoPiExtensionClearQueue ??= AgentSession.prototype.clearQueue);
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

const SPAWN_RESULT_RULE =
  "its result arrives as a notice when it calls notify_parent - you know nothing about it until then, so do not report, assume or predict it, and do not ask it for its result; continue other work or answer the user meanwhile, and if nothing else is left, end your turn - the notice wakes you; list_runs lists this run and stop_run stops it with the returned run id";

const NOTIFY_PARENT_INSTRUCTION =
  "You were spawned as a subagent. When your work is done, or you are blocked and cannot make further progress, call notify_parent with a short summary - your parent is not watching this session and will learn nothing otherwise. " +
  "Reporting does not end this session: it stays alive until your parent ends it with stop_run, and the parent can continue it with message_agent. " +
  "When you reply to another agent's question with message_agent, that call is the entire response - end the turn there, with no summary or sign-off after it.";

export interface SessionContext {
  abort(): void;
  shutdown(): void;
  ui?: SessionUI;
}

export interface CompletionItem {
  value: string;
  label: string;
  description?: string;
}

export interface CompletionProvider {
  triggerCharacters?: string[];
  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    options: { signal: AbortSignal; force?: boolean },
  ): Promise<{ items: CompletionItem[]; prefix: string } | null>;
  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: CompletionItem,
    prefix: string,
  ): { lines: string[]; cursorLine: number; cursorCol: number };
  shouldTriggerFileCompletion?(lines: string[], cursorLine: number, cursorCol: number): boolean;
}

interface SessionUI {
  setWidget(key: string, content: ((tui: unknown, theme: Theme) => { render(width: number): string[]; invalidate(): void }) | undefined, options?: { placement: "aboveEditor" | "belowEditor" }): void;
  notify?(message: string, type?: string): void;
  addAutocompleteProvider?(factory: (current: CompletionProvider) => CompletionProvider): void;
}

export type ShutdownReason = "quit" | "reload" | "new" | "resume" | "fork";

// Held on globalThis, not module scope: a /reload re-evaluates this file but
// keeps the process and the session's socket path.
type InboxHold = { server: Server; path: string } &
  ({ state: "owned"; handler: (sock: Socket) => void } | { state: "parked"; waiting: Socket[] });

type WatchData = {
  run: string;
  name: string;
  output: string;
  target: { kind: "agent"; entry: AgentEntry } | { kind: "bash"; stream: boolean };
  offset: number;
  lines: string[];
  dropped: number;
  partial: string;
  budget: number;
  budgetTold: boolean;
  idleDelay: number;
};

declare global {
  var __kidoPiExtensionInbox: InboxHold | undefined;
  var __kidoPiExtensionWatches: WatchData[] | undefined;
  var __kidoPiExtensionCopy: string | undefined;
  var __kidoPiExtensionClearQueue: AgentSession["clearQueue"] | undefined;
}

// A live listener answers; a stale file from a killed process does not, and only
// then may it be unlinked. Two pis on one session id share the socket, so the
// second binds nothing.
function answered(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const sock = createConnection(path);
    const finish = (live: boolean): void => {
      clearTimeout(timer);
      sock.destroy();
      resolve(live);
    };
    const timer = setTimeout(() => finish(false), 200);
    timer.unref();
    sock.on("error", () => finish(false));
    sock.on("connect", () => finish(true));
  });
}

function heldInbox(): InboxHold | null {
  return globalThis.__kidoPiExtensionInbox ?? null;
}

function setHeldInbox(hold: InboxHold | null): void {
  globalThis.__kidoPiExtensionInbox = hold ?? undefined;
}

// Outlives every module that owns the inbox: reads the slot per connection rather
// than closing over a handler, so a parked socket loses nothing across a /reload.
function dispatchInbox(sock: Socket): void {
  const hold = heldInbox();
  if (!hold) {
    sock.destroy();
    return;
  }
  if (hold.state === "owned") {
    hold.handler(sock);
    return;
  }
  sock.on("error", () => {});
  sock.once("close", () => {
    const i = hold.waiting.indexOf(sock);
    if (i >= 0) hold.waiting.splice(i, 1);
  });
  hold.waiting.push(sock);
}

// One copy per process: pi dedupes extensions by real path only, so a second
// copy at another path must register nothing. A /reload runs the same file again
// and finds it already its own.
function isFirstCopy(): boolean {
  const path = fileURLToPath(import.meta.url);
  return (globalThis.__kidoPiExtensionCopy ??= path) === path;
}

export function oneLine(text: string, max: number): string {
  const clean = [...text]
    .map((ch) => {
      const code = ch.codePointAt(0) ?? 0;
      return code < 0x20 || (code >= 0x7f && code <= 0x9f) || code === 0xfffd ? " " : ch;
    })
    .join("");
  return utf8Prefix(clean, max).replace(/ +$/, "");
}

// Must agree with pi's own CombinedAutocompleteProvider (extractAtPrefix), since
// the merged list carries one prefix for the agents and the files both.
function atToken(textBeforeCursor: string): string | undefined {
  const m = textBeforeCursor.match(/(?:^|\s)@([^\s@]*)$/);
  return m ? m[1] : undefined;
}

function completionValue(agents: AgentRow[], agent: AgentRow): string {
  if (agent.relationship !== "own" && !/\s/.test(agent.name)) return `@${agent.name}`;
  const others = agents.filter((a) => a.id !== agent.id);
  for (let n = MIN_ID_PREFIX; n <= agent.id.length; n++) {
    const prefix = agent.id.slice(0, n);
    if (!others.some((a) => a.id.startsWith(prefix))) return `@${prefix}`;
  }
  return `@${agent.id}`;
}

function agentCompletionItems(agents: AgentRow[], token: string): CompletionItem[] {
  const nameByID = new Map<string, string>();
  for (const a of agents) {
    nameByID.set(a.id, a.name);
    if (a.run) nameByID.set(a.run, a.name);
  }
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
    const value = completionValue(agents, a);
    const description = [
      a.activity ? `${a.status || "agent"} - ${a.activity}` : a.status || "agent",
      parent ? `subagent of ${parent}` : "",
      value === `@${a.name}` ? "" : `inserts ${value}`,
    ].filter(Boolean).join(", ");
    return { value, label: `@${a.name}`, description };
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

// Go-style %q: OCaml's %S would escape non-ASCII
// agent names kido deliberately keeps readable.
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

export function streamBatch(lines: string[], output: string, alreadyDropped = 0): string {
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
  if (omitted === 0) return kept.join("\n");
  return [`... ${omitted} lines omitted (see ${output})`, ...kept].join("\n");
}

function checkName(name: string): string | null {
  if (name === "" || name === "." || name === ".." || name.includes("/")) {
    return `refusing window name ${quote(name)}: it must be one path-safe name, not an empty, dot or slashed path`;
  }
  const bad = ["'", '"', "$", "#", "\\", "`", "\n", "\r"].find((c) => name.includes(c));
  if (bad) return `refusing window name ${quote(name)}: it contains ${quote(bad)}, which cannot survive tmux's own command-line parsing`;
  if (Buffer.byteLength(name, "utf8") > MAX_NAME_BYTES) {
    return `refusing window name ${quote(name)}: ${Buffer.byteLength(name, "utf8")} bytes is over the ${MAX_NAME_BYTES} byte limit`;
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

type ParentEdge = { parent: string; run: string; dir: string };

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
  let kido: string | null = null;
  let session: SessionContext | null = null;
  let ownSessionId: string | null = null;
  let edge: ParentEdge | null = null;
  let pane: string | null = null;
  let dir: string | null = null;
  let active = false;

  const written = new Map<string, string>();

  let completion: { rows: AgentRow[]; at: number; refreshing: Promise<void> | null } | null = null;

  const insideKido = (): boolean =>
    !!process.env.KIDO_RUN_ID || (!!process.env.TMUX && findKido() !== null);

  const writeOptions = async (entries: Array<[string, string]>): Promise<void> => {
    if (!pane) return;
    const fresh = entries.filter(([key, value]) => written.get(key) !== value);
    if (fresh.length === 0) return;
    const args: string[] = [];
    for (const [key, value] of fresh) {
      if (args.length) args.push(";");
      args.push("set-option", "-p", "-t", pane, key, value);
      written.set(key, value);
    }
    await runCommand("tmux", args, { timeoutMs: 2000 });
  };

  const unsetOptions = async (): Promise<void> => {
    if (!pane) return;
    for (const key of OPTION_KEYS) written.delete(key);
    const args: string[] = [];
    for (const key of OPTION_KEYS) {
      if (args.length) args.push(";");
      args.push("set-option", "-pu", "-t", pane, key);
    }
    await runCommand("tmux", args, { timeoutMs: 2000 });
  };

  // pi drains followUp only once the agent has decided to stop; "steer" is drained
  // inside the loop and joins the run already under way.
  const deliver = (text: string, deliverAs: DeliverAs = "followUp"): void => {
    workStarted();
    pi.sendUserMessage(text, { deliverAs });
  };

  const labelFrom = (from: Sender): string => from.name || from.session || from.pane || "another agent";

  const messageSender = (from: Sender): { name: string; relation: SenderRelation } | null => {
    if (!from.session) return null;
    const entries = dir ? agentEntries(dir) : [];
    const sender = entries.find((a) => a.session === from.session);
    const isParent = !!edge && from.session === edge.parent;
    const isChild = !!ownSessionId && !!sender && sender.parent === ownSessionId;
    return { name: sender?.name || labelFrom(from), relation: isParent ? "parent" : isChild ? "child" : "peer" };
  };

  const handleInboundMessage = async (env: Envelope): Promise<void> => {
    if (!env.text) return;
    const sender = messageSender(env.from);
    if (!sender) {
      deliver(env.text);
      return;
    }
    pi.sendMessage(
      {
        customType: MESSAGE_CUSTOM_TYPE,
        content: `${senderHeader("message", sender.name, sender.relation)}\n${env.text}`,
        display: true,
        details: { from: sender.name, relation: sender.relation },
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
  };

  const pendingNotices = new Map<string, { from: string; text: string }>();

  const NOTICE_WIDGET_KEY = "kido-notice-pending";

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
    const noticeId = randomUUID();
    pendingNotices.set(noticeId, { from, text });
    renderNoticeWidget();
    pi.sendMessage({ customType: NOTICE_CUSTOM_TYPE, content: `${noticeHeader(from)}\n${text}`, display: true, details: { from, noticeId } }, { deliverAs: "steer", triggerTurn: true });
  };

  const pendingInboundAsks = new Map<string, string>();

  type GaveUp = "timeout" | "inbox" | "unsent" | "gone" | "aborted";
  type AskOutcome = { reply: string } | { gaveUp: GaveUp };

  const pendingOutbound = new Map<string, { targetSession: string; settle: (outcome: AskOutcome) => void }>();

  const abandonPending = (): void => {
    for (const waiter of [...pendingOutbound.values()]) waiter.settle({ gaveUp: "inbox" });
  };

  const STOP_AFTER_ASK_REPLY =
    "That message_agent call is the entire response - end the turn there, with no summary or sign-off after it.";

  const handleInboundAsk = async (env: Envelope): Promise<"ok" | "refused"> => {
    const asker = env.from;
    if ([...pendingOutbound.values()].some((w) => w.targetSession === asker.session)) return "refused";
    const sender = messageSender(asker);
    const from = sender?.name ?? labelFrom(asker);
    const relation = sender?.relation ?? "peer";
    if (env.from.pane) pendingInboundAsks.set(env.id, env.from.pane);
    pi.sendMessage(
      {
        customType: ASK_CUSTOM_TYPE,
        content:
          `${senderHeader("ask", from, relation)}\n${from} is asking (id ${env.id}): ${env.text}\n\n` +
          `${from} cannot see this session's context, so make the answer self-contained. ` +
          `Reply with message_agent(to=${JSON.stringify(from)}, message=<answer>, replyTo=${JSON.stringify(env.id)}). ${STOP_AFTER_ASK_REPLY}`,
        display: true,
        details: { from, relation, id: env.id, question: env.text },
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
    return "ok";
  };

  const handleInboundReply = (env: Envelope & { kind: "reply" }): void => {
    const waiter = pendingOutbound.get(env.replyTo);
    if (waiter) {
      waiter.settle({ reply: env.text });
      return;
    }
    if (!env.text) return;
    const from = labelFrom(env.from);
    pi.sendMessage(
      {
        customType: REPLY_CUSTOM_TYPE,
        content: replyHeader(from, env.replyTo) + env.text,
        display: true,
        details: { from, replyTo: env.replyTo },
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
  };

  const bySessionOf = (entries: AgentEntry[]): Map<string, AgentEntry> => new Map(entries.map((e) => [e.session, e]));

  const isAncestor = (entries: AgentEntry[], selfSession: string, target: AgentEntry): boolean =>
    selfSession !== target.session && chain(bySessionOf(entries), target.session).includes(selfSession);

  const senderIsAncestor = (env: Envelope): boolean => {
    const sender = env.from;
    if (!sender.session || sender.session === ownSessionId) return false;
    if (edge && sender.session === edge.parent) return true;
    if (!dir || !ownSessionId) return false;
    const entries = agentEntries(dir);
    return chain(bySessionOf(entries), ownSessionId).includes(sender.session);
  };

  const handleInboundControl = async (env: Envelope, kind: "interrupt" | "stop"): Promise<"ok" | "refused"> => {
    if (!senderIsAncestor(env)) return "refused";
    if (kind === "interrupt") {
      await session?.abort();
    } else {
      session?.shutdown();
    }
    return "ok";
  };

  const handleInboundSteer = async (env: Envelope): Promise<"ok" | "refused"> => {
    if (!senderIsAncestor(env)) return "refused";
    if (env.text) deliver(`${labelFrom(env.from)} is redirecting this work: ${env.text}`, "steer");
    return "ok";
  };

  const handleEnvelope = async (env: Envelope): Promise<"ok" | "refused"> => {
    switch (env.kind) {
      case "message":
        await handleInboundMessage(env);
        return "ok";
      case "ask":
        return await handleInboundAsk(env);
      case "reply":
        handleInboundReply(env);
        return "ok";
      case "notice":
        if (env.text) deliverNotice(env.text, labelFrom(env.from));
        return "ok";
      case "steer":
        return handleInboundSteer(env);
      case "interrupt":
      case "stop":
        return handleInboundControl(env, env.kind);
      case "unrecognised":
        if (env.text) {
          deliver(`[unrecognised message kind ${JSON.stringify(env.claimed)} from ${labelFrom(env.from)}] ${env.text}`);
        }
        return "ok";
    }
  };


  const readTextFile = (path: string): string | undefined => {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return undefined;
    }
  };

  const exists = (path: string): boolean => {
    try {
      accessSync(path, constants.F_OK);
      return true;
    } catch {
      return false;
    }
  };

  const agentRun = (run: RunRow, byRun: Map<string, AgentEntry>, bySession: Map<string, AgentEntry>): AgentEntry | undefined =>
    byRun.get(run.id) ?? (run.session ? bySession.get(run.session) : undefined);

  const depthOfSession = (session: string, bySession: Map<string, AgentEntry>): number => chain(bySession, session).length - 1;

  const runRow = (value: unknown): RunRow | null => {
    if (!isRecord(value) || typeof value.id !== "string") return null;
    const str = (v: unknown): string => (typeof v === "string" ? v : "");
    const outcome = isRecord(value.outcome) && typeof value.outcome.result === "string" ? { result: value.outcome.result, text: str(value.outcome.text) } : undefined;
    return {
      id: value.id,
      name: str(value.name),
      parent: str(value.parent),
      pane: str(value.pane),
      cwd: str(value.cwd),
      startedAt: str(value.startedAt),
      session: str(value.session),
      output: str(value.output),
      outcome,
    };
  };

  const myRuns = async (): Promise<RunRow[]> => {
    const key = edge ? edge.run : pane;
    const command = kido;
    if (!key || !command) return [];
    const res = await runCommand(command, ["runs", "--json", "--parent", key], { timeoutMs: 2000 });
    if (!res.ok) return [];
    let parsed: unknown;
    try {
      parsed = JSON.parse(res.out);
    } catch {
      return [];
    }
    if (!Array.isArray(parsed)) return [];
    const rows: RunRow[] = [];
    for (const value of parsed) {
      const row = runRow(value);
      if (row) rows.push(row);
    }
    return rows;
  };

  type Snapshot = { rows: AgentRow[]; all: AgentRow[]; mySession: string; entries: AgentEntry[]; runs: RunRow[] };

  const discovery = async (): Promise<Snapshot> => {
    const [panes, runs] = await Promise.all([listPanes(), myRuns()]);
    const entries = dir ? agentEntries(dir) : [];
    const own = dir && ownSessionId ? ownEntries(dir, ownSessionId) : [];
    const bySession = bySessionOf(entries);
    const ownBySession = bySessionOf(own);
    const ownByRun = new Map(own.map((e) => [e.run, e]));
    const mySession = panes.find((p) => p.pane === pane)?.session ?? "";
    const all: AgentRow[] = [];

    for (const p of panes) {
      if (!isAgentPane(p)) continue;
      const entry = bySession.get(p.agentSession);
      const self = p.agentSession === ownSessionId;
      const isParent = !!edge && p.agentSession === edge.parent;
      const isPeer = (entry?.parent ?? "") === (edge?.parent ?? "");
      all.push({
        id: p.agentSession,
        name: p.name || p.title,
        named: p.name !== "",
        pane: p.pane,
        window: p.window,
        status: rootRecord(p.programStatus)?.state ?? "unknown",
        activity: p.activity,
        parent: entry?.parent ?? "",
        depth: depthOfSession(p.agentSession, bySession),
        self,
        cwd: p.cwd,
        canMessage: p.inbox !== "",
        canReply: canReply(entry, p.inbox),
        model: entry?.model ?? "",
        kind: entry?.parent ? "subagent" : "agent",
        relationship: self ? "own" : isParent ? "parent" : isPeer ? "peer" : "other",
        run: entry?.run ?? "",
        state: "running",
        tmux: p.session,
        inbox: p.inbox,
      });
    }

    const myDepth = ownSessionId ? depthOfSession(ownSessionId, bySession) : 0;
    let ended = 0;
    for (const r of runs) {
      if (r.outcome) {
        ended++;
        if (ended > 20) continue;
      }
      const entry = agentRun(r, ownByRun, ownBySession);
      const current = !entry || entry.run === r.id;
      const paneInfo = r.pane ? panes.find((p) => p.pane === r.pane) : undefined;
      const live = current && !!paneInfo && isAgentPane(paneInfo) && (!entry || paneInfo.agentSession === entry.session);
      const livePane = live ? paneInfo : undefined;
      const name = entry?.name || r.name || "";
      const task = entry ? readTextFile(join(entry.dir, "task")) : undefined;
      const reportPath = entry ? join(entry.dir, "report") : "";
      const liveRow = entry && livePane ? all.find((a) => a.id === livePane.agentSession) : undefined;
      if (liveRow) {
        liveRow.relationship = "own";
        liveRow.run = r.id;
        liveRow.state = r.outcome ? "ended" : "running";
        liveRow.startedAt = r.startedAt;
        liveRow.outcome = r.outcome;
        liveRow.task = task;
        liveRow.report = reportPath && exists(reportPath) ? reportPath : undefined;
        continue;
      }
      all.push({
        id: r.id,
        name,
        named: current && name !== "",
        pane: r.pane ?? "",
        window: livePane?.window ?? "",
        status: livePane ? (rootRecord(livePane.programStatus)?.state ?? "unknown") : "unknown",
        activity: livePane?.activity ?? "",
        parent: r.parent ?? "",
        depth: myDepth + 1,
        self: false,
        cwd: r.cwd ?? "",
        canMessage: !!entry && !!livePane && livePane.inbox !== "",
        canReply: !!entry && canReply(entry, livePane?.inbox ?? ""),
        model: entry?.model ?? "",
        kind: entry ? "subagent" : "bash",
        relationship: "own",
        run: r.id,
        state: r.outcome ? "ended" : "running",
        tmux: livePane?.session ?? mySession,
        inbox: livePane?.inbox ?? "",
        outcome: r.outcome,
        startedAt: r.startedAt,
        task,
        report: reportPath && exists(reportPath) ? reportPath : undefined,
      });
    }
    const rows = all.filter((a) => !a.self && a.relationship !== "other");
    return { rows, all, mySession, entries, runs };
  };

  const toolRow = (a: AgentRow) => {
    const { tmux: _tmux, inbox: _inbox, ...rest } = a;
    return rest;
  };

  const agentName = (a: AgentRow): string => a.name || a.id;

  type Address = { agent: AgentRow } | { error: string };

  const decide = (candidates: AgentRow[], wanted: string, by: "name" | "id"): Address | null => {
    const only = candidates[0];
    if (candidates.length === 1 && only) return { agent: only };
    if (candidates.length > 1) {
      const list = candidates
        .map((a) => `${a.id} (${agentName(a)})`)
        .sort()
        .join(", ");
      return { error: `"${wanted}" matches several agents by ${by}: ${list}` };
    }
    return null;
  };

  const matchAddress = (rows: AgentRow[], wanted: string): Address | null => {
    const live = rows.filter((a) => a.state !== "ended");
    const either = <T>(f: (group: AgentRow[]) => T | null): T | null => f(live) ?? f(rows);
    const named = either((group) => decide(group.filter((a) => a.named && a.name && a.name.toLowerCase() === wanted.toLowerCase()), wanted, "name"));
    if (named) return named;
    const exact = either((group) => group.find((a) => a.id === wanted) ?? null);
    if (exact) return { agent: exact };
    return either((group) => decide(group.filter((a) => a.id.startsWith(wanted)), wanted, "id"));
  };

  type Resolution = { snapshot: Snapshot } & ({ agent: AgentRow } | { error: string; agent?: undefined });

  const resolveIn = (snapshot: Snapshot, to: string): Resolution => {
    const wanted = to.replace(/^@/, "");
    const mine = snapshot.mySession ? snapshot.all.filter((a) => a.tmux === snapshot.mySession) : [];
    const first = matchAddress(mine, wanted);
    if (first) return { snapshot, ...first };
    const second = matchAddress(snapshot.all, wanted);
    if (second && "agent" in second) {
      if (second.agent.tmux !== snapshot.mySession) return { snapshot, error: `${wanted} (${second.agent.id}) is in another tmux session, not this one` };
      return { snapshot, ...second };
    }
    if (second && "error" in second) return { snapshot, error: `${second.error}, none in this tmux session` };
    return { snapshot, error: `no agent session matches "${wanted}"` };
  };

  const resolveAgent = async (to: string): Promise<Resolution> => resolveIn(await discovery(), to);

  const resolutionError = (resolution: Resolution): string =>
    "error" in resolution ? resolution.error : "no agent session matches";

  const isMyself = (target: AgentRow): boolean => target.self || target.id === ownSessionId || (!!edge && target.id === edge.run);

  const parentKey = (): string | null => (edge ? edge.run : pane);

  const windowOf = (paneId: string): string => {
    const cut = paneId.lastIndexOf(".");
    return cut >= 0 ? paneId.slice(0, cut) : "";
  };

  const createdRun = (out: string): { id: string; pane: string; output: string } | null => {
    try {
      const parsed: unknown = JSON.parse(out);
      if (!isRecord(parsed) || typeof parsed.id !== "string" || typeof parsed.pane !== "string" || typeof parsed.output !== "string") return null;
      return { id: parsed.id, pane: parsed.pane, output: parsed.output };
    } catch {
      return null;
    }
  };

  const runChildArgs = (parent: string, name: string, agentDir: string | null, command: string[]): string[] => [
    "run-child", parent, "--name", name,
    ...(agentDir === null ? [] : ["--env", `KIDO_AGENT_PARENT_SESSION=${ownSessionId}`, "--env", `KIDO_AGENT_DIR=${agentDir}`]),
    "--", ...command,
  ];

  type Started = { created: { id: string; pane: string; output: string } } | { error: string };

  const startChild = async (parent: string, name: string, agentDir: string | null, command: string[]): Promise<Started> => {
    const executable = kido;
    if (!executable) return { error: "kido is not on PATH" };
    const res = await runCommand(executable, runChildArgs(parent, name, agentDir, command), { timeoutMs: envMs("KIDO_SPAWN_TIMEOUT_MS", 5000) });
    if (!res.ok) return { error: res.error };
    const created = createdRun(res.out);
    return created ? { created } : { error: "kido run-child printed no run" };
  };

  const writeAgentJson = (agentDir: string, record: AgentRecord): void => {
    writeFileSync(join(agentDir, "agent.json"), JSON.stringify(record));
  };

  type SendResult = { ok: true } | { ok: false; kind: "unavailable" | "refused" | "failed"; message: string };

  const newId = (): string => randomUUID().replace(/-/g, "");

  const sendEnvelope = (path: string, spec: { kind: string; id?: string; replyTo?: string }, text: string): Promise<SendResult> =>
    new Promise((resolve) => {
      if (!path) {
        resolve({ ok: false, kind: "unavailable", message: "no inbox" });
        return;
      }
      const from: { session: string; name?: string; pane?: string } = { session: ownSessionId ?? "" };
      const name = pi.getSessionName() ?? "";
      if (name) from.name = name;
      if (pane) from.pane = pane;
      const envelope: Record<string, unknown> = { v: 1, kind: spec.kind, id: spec.id ?? newId(), from, text };
      if (spec.replyTo) envelope.replyTo = spec.replyTo;
      const payload = JSON.stringify(envelope);
      const sock = createConnection(path);
      let out = "";
      let finished = false;
      let sent = false;
      const failure = (detail: string): SendResult =>
        sent
          ? { ok: false, kind: "failed", message: `inbox ${path}: ${detail} after the request was sent; it may have arrived` }
          : { ok: false, kind: "unavailable", message: `inbox ${path}: ${detail}` };
      const finish = (result: SendResult): void => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        sock.destroy();
        resolve(result);
      };
      const timer = setTimeout(() => finish(failure("timed out")), 2000);
      timer.unref();
      sock.on("connect", () => {
        sent = true;
        sock.end(payload);
      });
      sock.on("data", (chunk: Buffer) => {
        out += chunk.toString("utf8");
      });
      sock.on("end", () => {
        const reply = out.trim();
        if (reply === "ok") finish({ ok: true });
        else if (reply === "refused") finish({ ok: false, kind: "refused", message: `inbox ${path}: refused` });
        else finish({ ok: false, kind: "failed", message: `inbox ${path}: answered ${JSON.stringify(reply)}, want "ok"` });
      });
      sock.on("error", (err) => finish(failure(err.message)));
    });

  const notAccepting = (name: string): string => `${name} is not accepting messages`;

  const deliveryText = (name: string, kind: string, result: SendResult, working = false, steerable = false): { ok: boolean; text: string } => {
    if (!result.ok) {
      if (result.kind === "refused") return { ok: false, text: `${name} refused the ${kind}` };
      if (result.kind === "unavailable") return { ok: false, text: notAccepting(name) };
      return { ok: false, text: result.message };
    }
    if (kind === "message" && working) {
      return {
        ok: true,
        text: `queued for ${name}: it is running and reads this when its current turn ends${steerable ? "; to reach it now, use steer_subagent" : ""}`,
      };
    }
    return { ok: true, text: `delivered to ${name} by inbox` };
  };

  const sendText = (target: AgentRow, kind: string, result: SendResult, entries: AgentEntry[]): { ok: boolean; text: string } =>
    deliveryText(agentName(target), kind, result, target.status === "working", isDescendant(target, entries));

  const isDescendant = (target: AgentRow, entries: AgentEntry[]): boolean => {
    if (!ownSessionId) return false;
    const entry = entries.find((e) => e.session === target.id) ?? entries.find((e) => e.run === target.id);
    return !!entry && isAncestor(entries, ownSessionId, entry);
  };

  const ancestorOfMe = (session: string, entries: AgentEntry[]): boolean =>
    !!edge && chain(bySessionOf(entries), edge.parent).includes(session);

  const reportNotice = (text: string, path: string): string => {
    const budget = MAX_NOTICE_BYTES - Buffer.byteLength(PARENT_GUIDANCE, "utf8");
    if (Buffer.byteLength(text, "utf8") <= budget) return text + PARENT_GUIDANCE;
    const suffix = `\n\nfull report: ${path}`;
    return utf8Prefix(text, budget - Buffer.byteLength(suffix, "utf8")) + suffix + PARENT_GUIDANCE;
  };

  const notifyParent = async (text: string, status: boolean): Promise<{ ok: boolean; text: string }> => {
    if (!edge) return { ok: false, text: "this session has no parent (it was not spawned as a subagent); notify_parent has nobody to tell" };
    const parentSession = edge.parent;
    const agentDir = edge.dir;
    const panes = await listPanes();
    const parentPane = panes.find((p) => isAgentPane(p) && p.agentSession === parentSession);
    if (!parentPane) return { ok: false, text: `no live process holds session "${parentSession}"; the parent is gone, nothing sent` };
    if (!parentPane.inbox) return { ok: false, text: `session ${parentSession} has no inbox` };
    const path = join(agentDir, "report");
    const body = status ? utf8Prefix(text, MAX_NOTICE_BYTES) : reportNotice(text, path);
    if (!status) {
      try {
        writeFileSync(path, text);
      } catch {}
    }
    return deliveryText(parentPane.name || parentSession, "notice", await sendEnvelope(parentPane.inbox, { kind: "notice" }, body));
  };

  type Watch = WatchData & {
    timer: NodeJS.Timeout | null;
    flushTimer: NodeJS.Timeout | null;
    waiter: ChildProcess | null;
    detach: (() => void) | null;
  };

  const watches = new Map<string, Watch>();

  const watchData = (run: string, name: string, output: string, agent: AgentEntry | null, stream: boolean): WatchData => ({
    run,
    name,
    output,
    target: agent ? { kind: "agent", entry: agent } : { kind: "bash", stream },
    offset: 0,
    lines: [],
    dropped: 0,
    partial: "",
    budget: envMs("KIDO_STREAM_BUDGET_BYTES", 256 * 1024),
    budgetTold: false,
    idleDelay: envMs("KIDO_STREAM_FLUSH_MS", 1000),
  });

  type TailRead = { data: Buffer; skipped: number; end: number } | { error: string };

  const readTail = (path: string, from: number, max: number): TailRead => {
    try {
      const size = statSync(path).size;
      if (size <= from) return { data: Buffer.alloc(0), skipped: 0, end: from };
      const start = Math.max(from, size - max);
      const buffer = Buffer.alloc(size - start);
      const fd = openSync(path, "r");
      try {
        readSync(fd, buffer, 0, buffer.length, start);
      } finally {
        closeSync(fd);
      }
      return { data: buffer, skipped: start - from, end: size };
    } catch (err) {
      return { error: err instanceof Error ? err.message : String(err) };
    }
  };

  const sendStream = (watch: Watch, body: string): void => {
    pi.sendMessage(
      {
        customType: STREAM_CUSTOM_TYPE,
        content: `async run ${JSON.stringify(watch.name)} output (run ${watch.run})\n${body}`,
        display: true,
        details: { from: watch.name, run: watch.run, output: watch.output },
      },
      { deliverAs: "steer", triggerTurn: true },
    );
  };

  const flushWatch = (watch: Watch): boolean => {
    if (watch.lines.length === 0) return false;
    if (watch.budget <= 0) {
      watch.lines = [];
      watch.dropped = 0;
      if (watch.timer) clearInterval(watch.timer);
      watch.timer = null;
      if (!watch.budgetTold) {
        watch.budgetTold = true;
        sendStream(watch, `... output budget spent; the rest is only in ${watch.output}`);
      }
      return true;
    }
    const batch = streamBatch(watch.lines, watch.output, watch.dropped);
    watch.lines = [];
    watch.dropped = 0;
    watch.budget -= Buffer.byteLength(batch, "utf8");
    sendStream(watch, batch);
    return true;
  };

  const clearFlush = (watch: Watch): void => {
    if (watch.flushTimer) clearTimeout(watch.flushTimer);
    watch.flushTimer = null;
  };

  const streamBase = (): number => envMs("KIDO_STREAM_FLUSH_MS", 1000);
  const streamCap = (): number => envMs("KIDO_STREAM_MAX_WAIT_MS", 30000);

  let agentWorking = false;

  const scheduleFlush = (watch: Watch): void => {
    if (agentWorking || watch.lines.length === 0 || watch.flushTimer || !watch.timer) return;
    watch.idleDelay = Math.min(watch.idleDelay, streamCap());
    watch.flushTimer = setTimeout(() => {
      watch.flushTimer = null;
      if (flushWatch(watch)) watch.idleDelay = Math.min(watch.idleDelay * 2, streamCap());
    }, watch.idleDelay);
    watch.flushTimer.unref();
  };

  const scheduleIdleStreams = (): void => {
    for (const watch of watches.values()) {
      if (watch.target.kind !== "bash" || !watch.target.stream) continue;
      watch.idleDelay = streamBase();
      scheduleFlush(watch);
    }
  };

  const flushStreams = (): void => {
    for (const watch of watches.values()) {
      if (watch.target.kind !== "bash" || !watch.target.stream) continue;
      clearFlush(watch);
      watch.idleDelay = streamBase();
      flushWatch(watch);
    }
  };

  const tailWatch = (watch: Watch, final: boolean): void => {
    const read = readTail(watch.output, watch.offset, 256 * 1024);
    if ("error" in read) return;
    watch.offset = read.end;
    let text = watch.partial;
    if (read.skipped > 0) {
      if (text) watch.lines.push(text);
      watch.partial = "";
      watch.dropped += 1;
      const newline = read.data.indexOf(0x0a);
      text = newline >= 0 ? read.data.subarray(newline + 1).toString("utf8") : "";
    } else {
      text += read.data.toString("utf8");
    }
    const parts = text.split("\n");
    watch.partial = final ? "" : (parts.pop() ?? "");
    for (const line of parts) watch.lines.push(line);
    if (watch.lines.length > STREAM_BUFFER_LINES) {
      watch.dropped += watch.lines.length - STREAM_BUFFER_LINES;
      watch.lines = watch.lines.slice(watch.lines.length - STREAM_BUFFER_LINES);
    }
    if (final) {
      clearFlush(watch);
      flushWatch(watch);
    } else if (!agentWorking) {
      scheduleFlush(watch);
    }
  };

  const lastOutput = (path: string): { tail: string; omitted: number } | { error: string } => {
    const read = readTail(path, 0, MAX_NOTICE_BYTES);
    if ("error" in read) return read;
    let start = 0;
    while (start < read.data.length && ((read.data.at(start) ?? 0) & 0xc0) === 0x80) start++;
    return { tail: read.data.subarray(start).toString("utf8"), omitted: read.skipped + start };
  };

  const endingBody = (watch: Watch, outcome: { result: string; text: string }): string => {
    let body = "";
    if (watch.target.kind === "bash") {
      body += `async run ${quote(watch.name)} ${outcome.result}: ${outcome.text}\nrun: ${watch.run}\noutput: ${watch.output}\n`;
      const tail = lastOutput(watch.output);
      if ("error" in tail) body += `--- output unreadable: ${tail.error} ---`;
      else if (!tail.tail) body += "--- no output ---";
      else if (tail.omitted > 0) {
        body += `--- last ${Buffer.byteLength(tail.tail, "utf8")} bytes of output (${tail.omitted} omitted) ---\n${tail.tail}`;
      } else body += `--- output ---\n${tail.tail}`;
      return body;
    }
    const report = join(watch.target.entry.dir, "report");
    body += exists(report)
      ? `subagent ${quote(watch.name)} ${outcome.result}\n`
      : `subagent ${quote(watch.name)} ${outcome.result} without reporting: it never called notify_parent, so this is the whole account of it\n`;
    if (outcome.text) body += `detail: ${outcome.text}\n`;
    body += `run: ${watch.run}\n`;
    if (!exists(report)) body += "message it to continue it, or stop_run to end it\n";
    return body;
  };

  const watch = (data: WatchData): void => {
    const command = kido;
    if (!command || watches.has(data.run)) return;
    const entry: Watch = { ...data, timer: null, flushTimer: null, waiter: null, detach: null };
    watches.set(data.run, entry);
    if (entry.target.kind === "bash" && entry.target.stream) {
      entry.timer = setInterval(() => tailWatch(entry, false), envMs("KIDO_STREAM_POLL_MS", 1000));
      entry.timer.unref();
      if (entry.lines.length > 0) scheduleFlush(entry);
    }
    const waiter = spawn(command, ["run-wait", entry.run, "--json"], { stdio: ["ignore", "pipe", "ignore"], env: process.env });
    entry.waiter = waiter;
    const chunks: Buffer[] = [];
    const onData = (chunk: Buffer): void => {
      chunks.push(chunk);
    };
    const onError = (): void => {};
    const onClose = (): void => {
      if (entry.timer) clearInterval(entry.timer);
      clearFlush(entry);
      watches.delete(entry.run);
      let outcome: { result: string; text: string } | null = null;
      try {
        const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8").trim());
        if (isRecord(parsed) && typeof parsed.result === "string") {
          outcome = { result: parsed.result, text: typeof parsed.text === "string" ? parsed.text : "" };
        }
      } catch {}
      if (!outcome) return;
      if (entry.target.kind === "bash" && entry.target.stream) tailWatch(entry, true);
      deliverNotice(endingBody(entry, outcome), entry.name);
    };
    waiter.stdout?.on("data", onData);
    waiter.on("error", onError);
    waiter.on("close", onClose);
    entry.detach = () => {
      waiter.stdout?.removeListener("data", onData);
      waiter.removeListener("close", onClose);
      waiter.removeListener("error", onError);
    };
  };

  let parentPane: string | null = null;
  let parentTimer: NodeJS.Timeout | null = null;
  let parentReading = false;

  const stopParentWatch = (): void => {
    if (parentTimer) {
      clearInterval(parentTimer);
      parentTimer = null;
    }
    parentReading = false;
  };

  type PaneReading = { ok: true; session: string; programStatus: string } | { ok: false };

  const paneReading = async (target: string): Promise<PaneReading> => {
    const res = await runCommand("tmux", ["display-message", "-p", "-t", target, "-F", "#{@kido_session}\x1f#{pane_program_status}"], { timeoutMs: 2000 });
    if (!res.ok || !res.out) return { ok: false };
    const [session = "", programStatus = ""] = res.out.split("\x1f");
    return { ok: true, session, programStatus };
  };

  // The parent is a pi pane; kido writes nothing for it. A failed tmux read is
  // not evidence, so it never ends the child.
  const startParentWatch = (): void => {
    if (!edge) return;
    const parentSession = edge.parent;
    stopParentWatch();
    parentTimer = setInterval(() => {
      if (parentReading) return;
      parentReading = true;
      void (async () => {
        try {
          if (parentPane) {
            const reading = await paneReading(parentPane);
            if (reading.ok && reading.session === parentSession && rootRecord(reading.programStatus)?.app === "pi") return;
          }
          const { ok, panes } = await listPanesResult();
          if (!ok) return;
          const found = panes.find((p) => isAgentPane(p) && p.agentSession === parentSession);
          if (found) {
            parentPane = found.pane;
            return;
          }
          stopParentWatch();
          session?.shutdown();
        } finally {
          parentReading = false;
        }
      })();
    }, envMs("KIDO_PARENT_POLL_MS", 5000));
    parentTimer.unref();
  };

  let parentToldThisTurn = false;
  let settled = true;

  const NO_FIRST_TURN_TEXT =
    "no turn ever ran: the task was delivered and the session never started work on it (the pane's own screen, kept with the run, is the only account of why)";

  type Ending =
    | { kind: "awaiting-first-turn" }
    | { kind: "aborted" }
    | { kind: "error"; text: string; notified: boolean }
    | { kind: "other" };
  let ending: Ending = { kind: "other" };

  const workStarted = (): void => {
    settled = false;
    parentToldThisTurn = false;
    if (ending.kind === "awaiting-first-turn") ending = { kind: "other" };
  };

  const trimErrorMessage = (msg: string): string => (msg.length > 400 ? `${msg.slice(0, 400)}…` : msg);

  // Records how this process's own run ended. Gated on a real ending, not a
  // /reload: an outcome is first-write-wins, so a reload's would hide the real one.
  const endOwnRun = async (reason?: ShutdownReason): Promise<void> => {
    const run = edge?.run;
    const command = kido;
    if (!run || !command || (reason !== undefined && reason !== "quit")) return;
    const [result, text] =
      ending.kind === "awaiting-first-turn"
        ? ["failed", NO_FIRST_TURN_TEXT]
        : [settled ? "completed" : "failed", ending.kind === "error" ? `its last turn failed: ${trimErrorMessage(ending.text)}` : ""];
    const args = ["run-outcome", "--result", result];
    if (text) args.push("--text", text);
    await runCommand(command, [...args, "--", run], { timeoutMs: 3000 });
  };

  const sessionFileOf = (entry: AgentEntry): string => readTextFile(join(entry.dir, "session-file"))?.trim() ?? "";

  const childInbox = (entry: AgentEntry): string => (dir ? inboxPath(dir, entry.session) ?? "" : "");

  const entryRow = (entry: AgentEntry): AgentRow => ({
    id: entry.session,
    name: entry.name,
    named: true,
    pane: "",
    window: "",
    status: "unknown",
    activity: "",
    parent: entry.parent,
    depth: 0,
    self: false,
    cwd: "",
    canMessage: true,
    canReply: canReply(entry, childInbox(entry)),
    model: entry.model,
    kind: "subagent",
    relationship: "own",
    run: entry.run,
    state: "running",
    tmux: "",
    inbox: childInbox(entry),
  });

  const childStarting = (entry: AgentEntry, runs: RunRow[]): boolean => entry.run !== "" && runs.some((r) => r.id === entry.run && !r.outcome);

  const endedChild = (to: string, own: AgentEntry[], live: Set<string>, runs: RunRow[]): AgentEntry | null => {
    const raw = to.replace(/^@/, "");
    const wanted = raw.toLowerCase();
    const matches = own.filter(
      (e) =>
        !live.has(e.session) &&
        (e.name.toLowerCase() === wanted ||
          e.session === raw ||
          (raw.length >= MIN_ID_PREFIX && (e.session.startsWith(raw) || (e.run !== "" && e.run.startsWith(raw))))),
    );
    if (matches.length <= 1) return matches[0] ?? null;
    const startedAt = (e: AgentEntry): string => runs.find((r) => r.id === e.run)?.startedAt ?? "";
    return matches.sort((a, b) => startedAt(b).localeCompare(startedAt(a))).at(0) ?? null;
  };

  const endedTarget = (to: string, resolved: Resolution): { entry: AgentEntry; starting: boolean } | null => {
    const own = dir && ownSessionId ? ownEntries(dir, ownSessionId) : [];
    const live = new Set(resolved.snapshot.all.filter((a) => a.state === "running").map((a) => a.id));
    const row = resolved.agent;
    let entry: AgentEntry | undefined;
    if (row && row.relationship === "own" && row.kind === "subagent" && !row.canMessage) {
      entry = own.find((e) => e.session === row.id || (row.run !== "" && e.run === row.run));
    } else if (!row) {
      entry = endedChild(to, own, live, resolved.snapshot.runs) ?? undefined;
    }
    return entry ? { entry, starting: childStarting(entry, resolved.snapshot.runs) } : null;
  };

  const restartChild = async (entry: AgentEntry, firstPrompt: string | null): Promise<string | null> => {
    const parent = parentKey();
    if (!parent) return null;
    const sessionFile = sessionFileOf(entry);
    if (!sessionFile) rmSync(join(entry.dir, "delivered"), { force: true });
    rmSync(join(entry.dir, "report"), { force: true });
    const command = ["kido-pi"];
    if (sessionFile) command.push("--session", sessionFile);
    else command.push("--session-id", entry.session);
    command.push("--name", entry.name);
    if (entry.model) command.push("--model", entry.model);
    if (entry.tools.length) command.push("--tools", entry.tools.join(","));
    if (firstPrompt !== null) command.push(firstPrompt);
    const started = await startChild(parent, entry.name, entry.dir, command);
    if ("error" in started) return null;
    writeAgentJson(entry.dir, { session: entry.session, run: started.created.id, model: entry.model, tools: entry.tools, fork: entry.fork });
    watch(watchData(started.created.id, entry.name, started.created.output, { ...entry, run: started.created.id }, false));
    return started.created.id;
  };

  const restartLocks = new Map<string, Promise<unknown>>();

  const withRestartLock = <T>(session: string, fn: () => Promise<T>): Promise<T> => {
    const previous = restartLocks.get(session) ?? Promise.resolve();
    const run = previous.then(fn, fn);
    restartLocks.set(
      session,
      run.then(
        () => undefined,
        () => undefined,
      ),
    );
    return run;
  };

  type RestartPrep =
    | { error: string }
    | { snapshot: Snapshot; entry: AgentEntry | null; restartedRun: string | null; firstPrompt: string | null };

  const prepareRestart = async (
    address: string,
    message: string | null,
    initial: Snapshot,
    refuse: (entry: AgentEntry) => string | null,
  ): Promise<RestartPrep> => {
    const first = endedTarget(address, resolveIn(initial, address));
    if (!first) return { snapshot: initial, entry: null, restartedRun: null, firstPrompt: null };
    return withRestartLock(first.entry.session, async () => {
      const snapshot = await discovery();
      const ended = endedTarget(address, resolveIn(snapshot, address));
      if (!ended) return { snapshot, entry: null, restartedRun: null, firstPrompt: null };
      const refusal = refuse(ended.entry);
      if (refusal) return { error: refusal };
      if (ended.starting) return { snapshot, entry: ended.entry, restartedRun: null, firstPrompt: null };
      const firstPrompt = message !== null && sessionFileOf(ended.entry) ? message : null;
      const run = await restartChild(ended.entry, firstPrompt);
      if (!run) return { error: "could not restart it" };
      return { snapshot, entry: ended.entry, restartedRun: run, firstPrompt };
    });
  };

  const sendWhenBound = async (path: string, spec: { kind: string; id?: string; replyTo?: string }, text: string, deadline: number): Promise<SendResult> => {
    for (;;) {
      const result = await sendEnvelope(path, spec, text);
      if (result.ok || result.kind !== "unavailable" || Date.now() > deadline) return result;
      await sleep(50);
    }
  };

  const restartedReply = (name: string, run: string): string => `restarted ${name} as run ${run}; ${SPAWN_RESULT_RULE}`;

  const validateModel = async (model: string | undefined): Promise<string | null> => {
    if (!model) return null;
    const res = await runCommand("pi", ["--list-models"], { timeoutMs: 10000 });
    if (!res.ok) return `could not validate model ${quote(model)}: pi --list-models: ${res.error}`;
    return validateModelRows(model, modelRows(res.out));
  };

  const nameTaken = async (name: string): Promise<boolean> => {
    const own = dir && ownSessionId ? ownEntries(dir, ownSessionId) : [];
    if (own.some((e) => e.name === name)) return true;
    const wanted = name.toLowerCase();
    return (await myRuns()).some((r) => (r.name ?? "").toLowerCase() === wanted);
  };

  let liveWatchStarted = false;

  const watchLiveChildren = async (): Promise<void> => {
    if (liveWatchStarted) return;
    liveWatchStarted = true;
    const entries = dir && ownSessionId ? ownEntries(dir, ownSessionId) : [];
    const bySession = bySessionOf(entries);
    const byRun = new Map(entries.map((e) => [e.run, e]));
    for (const run of await myRuns()) {
      if (run.outcome || watches.has(run.id) || !run.output) continue;
      const entry = agentRun(run, byRun, bySession);
      watch(watchData(run.id, entry?.name || run.name || run.id, run.output, entry ?? null, false));
    }
  };

  const handleInbound = async (prompt: string): Promise<"ok" | "refused"> => {
    const env = parseEnvelope(prompt);
    if (!env) {
      if (prompt) deliver(prompt);
      return "ok";
    }
    return handleEnvelope(env);
  };

  const onConnection = (sock: Socket): void => {
    const chunks: Buffer[] = [];
    let total = 0;
    let dropped = false;
    sock.on("error", () => {});
    sock.on("data", (chunk: Buffer) => {
      if (dropped) return;
      total += chunk.length;
      if (total > MAX_PROMPT_BYTES) {
        dropped = true;
        chunks.length = 0;
        sock.destroy();
        return;
      }
      chunks.push(chunk);
    });
    sock.on("end", async () => {
      if (dropped) return;
      const text = Buffer.concat(chunks).toString("utf8");
      const prompt = text.trim();
      const response = prompt ? await handleInbound(prompt) : "ok";
      try {
        sock.end(response + "\n");
      } catch {}
    });
  };

  const stopInbox = (opts: { keepListening?: boolean } = {}): void => {
    const hold = heldInbox();
    if (!hold) return;
    if (opts.keepListening) {
      if (hold.state === "owned") setHeldInbox({ server: hold.server, path: hold.path, state: "parked", waiting: [] });
      return;
    }
    setHeldInbox(null);
    if (hold.state === "parked") for (const sock of hold.waiting.splice(0)) sock.destroy();
    try {
      hold.server.close();
    } catch {}
    try {
      unlinkSync(hold.path);
    } catch {}
  };

  const adoptInbox = (): boolean => {
    const hold = heldInbox();
    if (hold?.state !== "parked") return false;
    setHeldInbox({ server: hold.server, path: hold.path, state: "owned", handler: onConnection });
    for (const sock of hold.waiting.splice(0)) onConnection(sock);
    return true;
  };

  const inboxOpen = (): boolean => {
    const hold = heldInbox();
    return hold?.state === "owned" && hold.handler === onConnection;
  };

  const startInbox = async (sessionId: string, base: string): Promise<void> => {
    const path = inboxPath(base, sessionId);
    if (!path) return;
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    } catch (err) {
      if (!(err instanceof Error && "code" in err && err.code === "EEXIST")) return;
    }
    if (await answered(path)) return;
    try {
      unlinkSync(path);
    } catch {}
    const server = createServer({ allowHalfOpen: true }, dispatchInbox);
    server.on("error", () => {});
    const bound = await new Promise<boolean>((resolve) => {
      server.once("error", () => resolve(false));
      server.listen(path, () => resolve(true));
    });
    if (!bound) return;
    server.unref();
    setHeldInbox({ server, path, state: "owned", handler: onConnection });
  };

  // The child trusts the parent edge only when its own directory records its own
  // session id: a pi that an agent's bash starts inherits the environment but
  // mints a different session.
  const readEdge = (sessionId: string): ParentEdge | null => {
    const agentDir = process.env.KIDO_AGENT_DIR;
    if (!agentDir) return null;
    const record = readAgentRecord(agentDir);
    if (!record || record.session !== sessionId) return null;
    return { parent: dirname(agentDir).split("/").at(-1) ?? "", run: process.env.KIDO_RUN_ID ?? record.run, dir: agentDir };
  };

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

  pi.registerMessageRenderer<{ from: string }>(MESSAGE_CUSTOM_TYPE, (message, _options, theme) => {
    const from = message.details?.from || "another agent";
    const raw = typeof message.content === "string" ? message.content : "";
    const header = RELATIONS
      .map((relation) => `${senderHeader("message", from, relation)}\n`)
      .find((line) => raw.startsWith(line));
    const content = header ? raw.slice(header.length) : raw;
    return renderInbound(message, theme, message.details?.from, "says", content);
  });

  pi.registerMessageRenderer<{ from: string; question: string }>(ASK_CUSTOM_TYPE, (message, _options, theme) => {
    const question = message.details?.question ?? (typeof message.content === "string" ? message.content : "");
    return renderInbound(message, theme, message.details?.from, "asks", question);
  });

  pi.registerMessageRenderer<{ from: string; replyTo: string }>(REPLY_CUSTOM_TYPE, (message, _options, theme) => {
    const raw = typeof message.content === "string" ? message.content : "";
    const header = replyHeader(message.details?.from ?? "", message.details?.replyTo ?? "");
    return renderInbound(message, theme, message.details?.from, "replies", raw.startsWith(header) ? raw.slice(header.length) : raw);
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
    if (m?.role !== "custom" || m.customType !== NOTICE_CUSTOM_TYPE) return;
    const details = m.details;
    if (typeof details !== "object" || details === null || !("noticeId" in details)) return;
    const noticeId = details.noticeId;
    if (typeof noticeId !== "string" || !noticeId || !pendingNotices.has(noticeId)) return;
    pendingNotices.delete(noticeId);
    renderNoticeWidget();
  });

  pi.registerTool({
    name: "set_status",
    label: "Set Status",
    description:
      "Set the free-text activity shown next to you in kido's tmux sidebar. Separate from your running/waiting/idle status.",
    promptSnippet: "set_status(activity) - tell everyone else what you are doing, visible in list_runs()",
    parameters: Type.Object(
      {
        activity: Type.String({
          description: 'What you are doing right now ("refactoring internal/ui"), or "" to clear it. Capped at 256 bytes.',
        }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      await writeOptions([[OPTION_ACTIVITY, oneLine(params.activity, 256)]]);
      return reply("ok");
    },
  });


  pi.registerTool({
    name: "list_runs",
    label: "List Runs",
    description:
      "List same-parent peers and your parent in this tmux session, plus your own subagents and async_bash jobs: all running and the newest 20 ended, newest first. Use message_agent for agents and stop_run with a run id to stop your runs.",
    promptSnippet: "list_runs() - find same-parent peers and your parent to message, and your own subagents and jobs to stop with stop_run",
    parameters: Type.Object({}, { additionalProperties: false }),
    async execute() {
      const { rows } = await discovery();
      const listed = rows.map(toolRow);
      return reply(JSON.stringify(listed), listed);
    },
  });

  pi.registerTool({
    name: "message_agent",
    label: "Message Agent",
    description:
      "Send a message to another agent in this tmux session, addressed by name, session id, or a unique id prefix. It waits for the receiver to finish its current turn, and a running descendant's turn is usually its whole task: to give one new information, evidence, scope or a correction, use steer_subagent. message_agent is for what can wait until the receiver finishes.",
    promptSnippet: "message_agent(to, message, replyTo?) - send a message to another agent in this tmux session",
    parameters: Type.Object(
      {
        to: Type.String({
          description: "Who to message: an agent's exact name, exact session id, or a unique prefix of its session id.",
        }),
        message: Type.String({ description: "The message text to deliver." }),
        replyTo: Type.Optional(
          Type.String({ description: "The id of an earlier ask this message answers, if any." }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      if (!params.message) return reply(`could not message ${params.to}: the message is empty; nothing sent`);
      if (!params.message.isWellFormed()) return reply(`could not message ${params.to}: the message is not valid UTF-8`);
      const askerPane = params.replyTo ? pendingInboundAsks.get(params.replyTo) : undefined;
      if (askerPane && params.replyTo) pendingInboundAsks.delete(params.replyTo);
      const kind = params.replyTo ? "reply" : "message";
      const spec = params.replyTo ? { kind, replyTo: params.replyTo } : { kind };
      const snapshot = await discovery();
      const address = askerPane ? snapshot.all.find((a) => a.pane === askerPane)?.id ?? params.to : params.to;
      const prep = await prepareRestart(address, params.message, snapshot, () => null);
      if ("error" in prep) return reply(`could not message ${params.to}: ${prep.error}`);
      const bound = Date.now() + 5000;
      if (prep.entry) {
        if (prep.firstPrompt !== null) return reply(restartedReply(prep.entry.name, prep.restartedRun ?? ""));
        const row = entryRow(prep.entry);
        const sent = sendText(row, kind, await sendWhenBound(row.inbox, spec, params.message, bound), prep.snapshot.entries);
        if (!sent.ok) return reply(`could not message ${params.to}: ${sent.text}`);
        return reply(prep.restartedRun ? `restarted ${prep.entry.name} as run ${prep.restartedRun} and ${sent.text}` : sent.text);
      }
      const resolved = resolveIn(prep.snapshot, address);
      const target = resolved.agent;
      if (!target) return reply(`could not message ${params.to}: ${resolutionError(resolved)}`);
      if (isMyself(target)) return reply(`${agentName(target)} is this agent`);
      if (target.kind === "bash") return reply(`could not message ${params.to}: ${agentName(target)} is a background command, not an agent; it cannot be messaged`);
      if (!target.canMessage) return reply(`could not message ${params.to}: ${agentName(target)} has no inbox to reach it on`);
      const sent = sendText(target, kind, await sendEnvelope(target.inbox, spec, params.message), prep.snapshot.entries);
      if (!sent.ok) return reply(`could not message ${params.to}: ${sent.text}`);
      return reply(askerPane ? `${sent.text} ${STOP_AFTER_ASK_REPLY}` : sent.text);
    },
  });

  pi.registerTool({
    name: "ask_agent",
    label: "Ask Agent",
    description:
      "Ask another agent a question and block until it replies - one full turn of the target's latency, not a round-trip, since a busy target does not see the question until it would otherwise have stopped. Refused for an ancestor, a target outside this tmux session, one with no inbox or no message_agent tool, or yourself. Not for collecting a subagent's result: that arrives on its own as a notice when the child finishes, and an ask blocks this turn until the target answers, so the notice cannot be read until the ask returns.",
    promptSnippet:
      "ask_agent(to, question, timeoutMs?) - ask another agent a question and wait for its reply (DO NOT use to get subagent results, wait for notification instead)",
    parameters: Type.Object(
      {
        to: Type.String({
          description: "Who to ask: an agent's exact name, exact session id, or a unique prefix of its session id.",
        }),
        question: Type.String({ description: "The question to ask." }),
        timeoutMs: Type.Optional(
          Type.Integer({
            description: `How long to wait for a reply, in milliseconds. Defaults to ${DEFAULT_ASK_TIMEOUT_MS} (5 minutes) - expect a full turn of the target's latency, not a round-trip.`,
            minimum: 1,
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params, signal) {
      if (!params.question.isWellFormed()) return reply(`could not ask ${params.to}: the question is not valid UTF-8`);
      const startedAt = Date.now();
      const timeoutMs = params.timeoutMs ?? DEFAULT_ASK_TIMEOUT_MS;
      const deadline = startedAt + timeoutMs;
      const first = await discovery();
      const prepared = await prepareRestart(params.to, null, first, (entry) =>
        canReply(entry, childInbox(entry)) ? null : cannotReply(entry.name),
      );
      if ("error" in prepared) {
        return reply(prepared.error.startsWith("could not restart") ? `could not ask ${params.to}: ${prepared.error}` : prepared.error);
      }
      const snapshot = prepared.snapshot;
      const resolved = resolveIn(snapshot, params.to);
      const target = prepared.entry ? entryRow(prepared.entry) : resolved.agent;
      const restartInbox = prepared.entry ? childInbox(prepared.entry) : "";
      const restarted = prepared.entry !== null;
      if (!target) return reply(`could not ask ${params.to}: ${resolutionError(resolved)}`);
      const who = agentName(target);
      if (isMyself(target)) return reply("cannot ask yourself");
      if (ancestorOfMe(target.id, snapshot.entries)) {
        return reply(`${who} is an ancestor; the parent stays free to orchestrate, so it cannot be asked`);
      }
      if (target.kind === "bash") return reply(`${who} is not an agent; an ask cannot work over a run`);
      if (!target.canMessage) {
        return reply(`${who} has no inbox; an ask cannot work over a paste, there is no way back`);
      }
      if (!target.canReply) return reply(cannotReply(who));
      if (target.state === "ended") return reply(`${who} is no longer running; refusing to wait for a reply`);
      // Checked synchronously, with no await before pendingOutbound.set below.
      if (!inboxOpen()) {
        return reply(`this session's inbox is unavailable; no reply from ${params.to} can be waited for`);
      }

      const id = newId();

      let settleReply: (outcome: AskOutcome) => void = () => {};
      let watch: NodeJS.Timeout | null = null;
      let settled = false;
      const answered = new Promise<AskOutcome>((resolve) => {
        settleReply = resolve;
      });
      const onAbort = () => settle({ gaveUp: "aborted" });
      const settle = (outcome: AskOutcome): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (watch) clearInterval(watch);
        signal?.removeEventListener("abort", onAbort);
        pendingOutbound.delete(id);
        settleReply(outcome);
      };
      const timer = setTimeout(() => settle({ gaveUp: "timeout" }), Math.max(1, deadline - Date.now()));
      timer.unref();
      pendingOutbound.set(id, { targetSession: target.id, settle });
      if (signal?.aborted) onAbort();
      else signal?.addEventListener("abort", onAbort, { once: true });

      const sent = restarted
        ? await sendWhenBound(restartInbox, { kind: "ask", id }, params.question, deadline)
        : await sendEnvelope(target.inbox, { kind: "ask", id }, params.question);
      if (!sent.ok) settle({ gaveUp: "unsent" });

      if (!settled) {
        let reading = false;
        const t = target;
        watch = setInterval(() => {
          if (reading) return;
          reading = true;
          const gone = t.pane
            ? paneReading(t.pane).then((r) => r.ok && !(r.session === t.id && rootRecord(r.programStatus)?.app === "pi"))
            : listPanesResult().then((r) => r.ok && !r.panes.some((p) => isAgentPane(p) && p.agentSession === t.id));
          void gone.then((absent) => {
            reading = false;
            if (absent) settle({ gaveUp: "gone" });
          });
        }, envMs("KIDO_ASK_POLL_MS", 5000));
        watch.unref();
      }

      const outcome = await answered;
      if ("reply" in outcome) return reply(outcome.reply);
      const gaveUpText: Record<GaveUp, string> = {
        unsent: `could not ask ${params.to}: ${sent.ok ? "" : sent.message}`,
        aborted: `the ask to ${params.to} was interrupted (ask id ${id}); a later reply naming this id will still arrive as a message`,
        gone: `${who} stopped running before answering (ask id ${id}); no reply can come from it now`,
        inbox: `this session's inbox closed before ${params.to} answered (ask id ${id}); no reply can reach it now, so ask again if the answer still matters`,
        timeout: `no reply from ${params.to} within ${timeoutMs}ms (ask id ${id}); a later reply naming this id will still arrive as a message`,
      };
      return reply(gaveUpText[outcome.gaveUp]);
    },
  });

  pi.registerTool({
    name: "notify_parent",
    label: "Notify Parent",
    description:
      "Tell your parent your work is done, carrying a short summary. Call this once, when you have an answer or have given up - nothing else reports it. You stay alive after this report: the parent ends you with stop_run, or continues you with message_agent. Only meaningful for a subagent; refused for a session with no parent.",
    promptSnippet: "notify_parent(summary) - tell your parent your work is done, once it actually is",
    parameters: Type.Object(
      {
        summary: Type.String({
          description:
            `A short summary of the finished work to send to your parent. Your parent reads the first ${MAX_NOTICE_BYTES} bytes; ` +
            `anything longer is kept in full in your agent directory and the notice names it, so nothing is lost.`,
        }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      if (!params.summary.isWellFormed()) return reply("could not notify parent: the summary is not valid UTF-8");
      const sent = await notifyParent(params.summary, false);
      if (!sent.ok) return reply(`could not notify parent: ${sent.text}`);
      parentToldThisTurn = true;
      return reply(sent.text);
    },
  });

  const controlSend = async (kind: "steer" | "interrupt", to: string, text: string): Promise<string> => {
    const resolved = await resolveAgent(to);
    if (!resolved.agent) return `could not ${kind} ${to}: ${resolutionError(resolved)}`;
    const target = resolved.agent;
    const name = agentName(target);
    if (isMyself(target)) return `${name} is this agent`;
    if (!isDescendant(target, resolved.snapshot.entries)) return `${name} is not this agent's descendant`;
    const result = await sendEnvelope(target.inbox, { kind }, text);
    if (!result.ok) return `could not ${kind} ${to}: ${deliveryText(name, kind, result).text}`;
    return kind === "steer" ? `delivered to ${name} by inbox` : `interrupted ${name}`;
  };

  pi.registerTool({
    name: "steer_subagent",
    label: "Steer Subagent",
    description:
      "Redirect a descendant that is already working, without aborting its turn: the message joins the run it is in rather than waiting for it to finish. For anything a running descendant needs before it finishes: new evidence, a change of scope, a correction or a warning. Refused for anything but a descendant. Use message_agent when the message can wait for the current turn to end; use stop_run to end a run.",
    promptSnippet: "steer_subagent(to, message) - redirect a descendant mid-task without aborting; stop_run ends a run",
    parameters: Type.Object(
      {
        to: Type.String({
          description: "Who to steer: a descendant's exact name, exact session id, or a unique prefix of its session id.",
        }),
        message: Type.String({ description: "The course correction to deliver." }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      if (!params.message.isWellFormed()) return reply(`could not steer ${params.to}: the message is not valid UTF-8`);
      return reply(await controlSend("steer", params.to, params.message));
    },
  });

  pi.registerTool({
    name: "interrupt_subagent",
    label: "Interrupt Subagent",
    description:
      "Abort a descendant's current turn without ending its session - it stays alive and idle, ready for a corrected instruction. Refused for anything but a descendant; use stop_run to end a run.",
    promptSnippet: "interrupt_subagent(to) - abort a descendant's turn without ending its session; stop_run ends a run",
    parameters: Type.Object(
      {
        to: Type.String({
          description: "Who to interrupt: an agent's exact name, exact session id, or a unique prefix of its session id.",
        }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      return reply(await controlSend("interrupt", params.to, ""));
    },
  });



  const stopRun = async (to: string, force: boolean): Promise<string> => {
    const command = kido;
    if (!command) return "could not stop: kido is not on PATH";
    const resolved = await resolveAgent(to);
    const { all, entries } = resolved.snapshot;
    const wanted = to.replace(/^@/, "");
    const candidates = all.filter((a) => a.relationship === "own" || isDescendant(a, entries));
    let matches = candidates.filter((a) => a.id === wanted || a.run === wanted);
    if (!matches.length) {
      matches = wanted.length >= MIN_ID_PREFIX
        ? candidates.filter((a) => a.id.startsWith(wanted) || (a.run !== "" && a.run.startsWith(wanted)))
        : [];
    }
    if (!matches.length) {
      matches = candidates.filter((a) => a.named && a.name.toLowerCase() === wanted.toLowerCase() && a.state === "running");
    }
    if (!matches.length) return `no run matches ${quote(to)}`;
    if (matches.length > 1) {
      return `${quote(to)} matches several runs: ${matches.map((a) => a.run || a.id).sort().join(", ")}`;
    }
    const target = matches.at(0);
    if (!target) return `no run matches ${quote(to)}`;
    const run = target.run || target.id;
    const stopWait = 5;
    const stopDeadline = (wait: number): number => wait * 1000 + envMs("KIDO_STOP_ESCALATION_MS", 5000) + 1500;
    if (target.kind === "bash") {
      const res = await runCommand(command, ["run-stop", run], { timeoutMs: stopDeadline(0) });
      return res.ok ? res.out : res.error;
    }
    const name = target.name || target.id;
    const entry = entries.find((e) => e.session === target.id) ?? entries.find((e) => e.run === target.run);
    if (!force && !target.inbox) return `subagent ${name} has no inbox to ask nicely over; pass --force to kill its window instead`;
    const recordArgs = ["run-stop", run, "--record-only", ...(entry && exists(join(entry.dir, "report")) ? ["--result", "completed"] : [])];
    const recorded = await runCommand(command, recordArgs, { timeoutMs: stopDeadline(stopWait) });
    if (!recorded.ok && recorded.code !== 5) return recorded.error;
    let requestFailure = "";
    if (!force && target.inbox) {
      const request = await sendEnvelope(target.inbox, { kind: "stop" }, "");
      if (!request.ok && request.kind !== "refused") requestFailure = request.message;
    }
    const res = await runCommand(command, ["run-stop", run, "--cleanup", "--wait", String(stopWait)], { timeoutMs: stopDeadline(stopWait) });
    if (res.ok) return requestFailure ? `stopped ${name}; ${res.out}; the stop request failed: ${requestFailure}` : `stopped ${name}; ${res.out}`;
    return requestFailure ? `${res.error}; the stop request failed: ${requestFailure}` : res.error;
  };

  pi.registerTool({
    name: "spawn_subagent",
    label: "Spawn Subagent",
    description:
      "Create a subagent in its own tmux window with a task. With fork: true it starts holding this session's context, for a judgement step that has to know what was already decided. Returns its identity immediately without waiting for it to finish. Its result arrives as a notice when it calls notify_parent; do not ask_agent a child for its result; it stays alive after it reports, so end it with stop_run when you need nothing more from it, or message it to continue.",
    promptSnippet:
      "spawn_subagent(task, name, model?, tools?, fork?) - delegate a task to a new subagent, optionally forked from your own context, in its own window; list_runs lists it and stop_run stops it with the returned run id",
    promptGuidelines: [
      "A subagent's result arrives on its own as a notice when it finishes; never ask a child for its result and never poll list_runs for it; list_runs lists the run and stop_run stops it with the returned run id.",
      "Trust but verify: a child's report says what it intended to do, not what it did - check the diff before relaying success.",
      NOT_THE_USER_RULE,
    ],
    parameters: Type.Object(
      {
        task: Type.String({
          description:
            "The task to give the new subagent, delivered as its first message. " +
            "The subagent starts with no context beyond this text (a fork excepted), so name the files, the lines and the specific change, say what it must report back, and say whether it is to write code or only research. " +
            "Synthesize what you already know into the task rather than writing \"based on your findings\".",
        }),
        name: Type.String({ description: "A name for the subagent's window and session; it must be unique among this session's children, and a reused name is refused - message the live agent instead." }),
        model: Type.Optional(
          Type.String({
            description:
              'Model for the subagent to run, as "provider/model-id" (e.g. claude-bridge/claude-sonnet-5), optionally suffixed :<thinking>, e.g. claude-bridge/claude-sonnet-5:low - see `pi --list-models`. A bare alias like "sonnet" is refused, not resolved.',
          }),
        ),
        tools: Type.Optional(
          Type.Array(Type.String(), {
            description: "Tool names the subagent may use - its capability ceiling. notify_parent is always included. Omit to leave it at pi's default set.",
          }),
        ),
        fork: Type.Optional(
          Type.Boolean({
            description:
              "Start the subagent holding this session's context: it is forked from this conversation and then given the task. For a short judgement or merge step that has to know what was already decided - the whole context is replayed on every one of its turns, so it is a poor choice for a long worker. Defaults to false.",
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      const command = kido;
      if (!command) return reply("could not spawn subagent: kido is not on PATH");
      if (!ownSessionId) return reply("could not spawn subagent: this session has no id of its own to parent a subagent with");
      if (!pane) return reply("could not spawn subagent: this session has no pane to parent a subagent from");
      const name = params.name;
      if (!name) return reply("could not spawn subagent: --name is required");
      const nameError = checkName(name);
      if (nameError) return reply(`could not spawn subagent: ${nameError}`);
      if (Buffer.byteLength(params.task, "utf8") > MAX_TASK_BYTES) {
        return reply(`could not spawn subagent: the task is over the ${MAX_TASK_BYTES} byte task limit`);
      }
      if (await nameTaken(name)) {
        return reply(`could not spawn subagent: the name ${quote(name)} is already taken by one of this session's runs; message it instead`);
      }
      const entries = dir ? agentEntries(dir) : [];
      const depth = (ownSessionId ? depthOfSession(ownSessionId, new Map(entries.map((e) => [e.session, e]))) : 0) + 1;
      if (depth > MAX_DEPTH) {
        return reply(`could not spawn subagent: refusing to spawn at depth ${depth}: maximum nesting is ${MAX_DEPTH} (root 0, subagent 1, subagent 2)`);
      }
      const modelError = await validateModel(params.model);
      if (modelError) return reply(`could not spawn subagent: ${modelError}`);

      const selected = params.tools ? [...params.tools] : [];
      const tools = selected.length && !selected.includes("notify_parent") ? [...selected, "notify_parent"] : selected;
      const childSession = newId();
      const childDir = join(dir ?? "", "agents", ownSessionId, name);
      mkdirSync(childDir, { recursive: true, mode: 0o700 });
      writeFileSync(join(childDir, "task"), params.task);
      const record = { session: childSession, run: "", model: params.model ?? "", tools, fork: !!params.fork };
      writeAgentJson(childDir, record);

      const piCommand = ["kido-pi", "--session-id", childSession, "--name", name];
      if (params.model) piCommand.push("--model", params.model);
      if (params.fork) piCommand.push("--fork", ownSessionId);
      if (tools.length) piCommand.push("--tools", tools.join(","));
      const parent = parentKey();
      if (!parent) return reply("could not spawn subagent: this session has no run or pane to parent a subagent from");
      const started = await startChild(parent, name, childDir, piCommand);
      if ("error" in started) {
        rmSync(childDir, { recursive: true, force: true });
        return reply(`could not spawn subagent: ${started.error}`);
      }
      const created = started.created;
      writeAgentJson(childDir, { ...record, run: created.id });
      watch(watchData(created.id, name, created.output, { ...record, run: created.id, name, parent: ownSessionId, dir: childDir }, false));
      const window = windowOf(created.pane);
      return reply(
        `spawned ${name} (window ${window}, pane ${created.pane}, run ${created.id})${params.fork ? ", forked from this session's context" : ""}; ${SPAWN_RESULT_RULE}`,
        { name, window, pane: created.pane, run: created.id, fork: !!params.fork },
      );
    },
  });

  pi.registerTool({
    name: "async_bash",
    label: "Async Bash",
    description:
      "Run a shell command in the background, for a command whose result you do not need for your next step - this session keeps working while it runs. Exactly one notice arrives when the command ends, carrying its exit status and a tail of its output; read the output file with the ordinary read tool at any time before then to check on progress. With stream=true the output also arrives in batches as it runs - between your own tool calls while you are working, on a slowing schedule when you are idle, capped per batch and per run, so some lines are only ever in the file, which always has all of them. If your next step needs the result and you have nothing else to do meanwhile, use bash with a timeout instead; list_runs lists its run and stop_run stops it with the returned run id.",
    promptSnippet:
      "async_bash(command, name, stream?) - run a command in the background; a notice with its exit status arrives when it ends, read the output file meanwhile; list_runs lists it and stop_run stops it with its run id",
    promptGuidelines: [
      "A command whose result you need before continuing (tests, a build, anything you will act on) runs in foreground bash, however long it takes - length alone is never a reason to use async_bash. Once a command is in async_bash, its notice is the only way you learn that it ended: never run `sleep` in bash to wait for it, and never loop over its output file. If you have nothing else to do, end your turn; the notice wakes you.",
      "list_runs lists an async_bash run and stop_run stops it with the returned run id.",
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
      const command = kido;
      if (!command) return reply("could not start background command: kido is not on PATH");
      if (!params.name) return reply("could not start background command: --name is required");
      const nameError = checkName(params.name);
      if (nameError) return reply(`could not start background command: ${nameError}`);
      if (await nameTaken(params.name)) {
        return reply(`could not start background command: the name ${quote(params.name)} is already taken by one of this session's runs; choose another name`);
      }
      const parent = parentKey();
      if (!parent) return reply("could not start background command: this session has no pane to parent a run from");
      const line = `{\n${params.command}\n} 2>&1 | tee "$KIDO_RUN_OUTPUT"`;
      const started = await startChild(parent, params.name, null, ["bash", "-o", "pipefail", "-c", line]);
      if ("error" in started) return reply(`could not start background command: ${started.error}`);
      const created = started.created;
      watch(watchData(created.id, params.name, created.output, null, !!params.stream));
      const window = windowOf(created.pane);
      return reply(
        `started run ${created.id}${params.name ? ` (${params.name})` : ""} in window ${window}; list_runs lists it and stop_run("${created.id}") stops it; ` +
          `a notice with its exit status and a tail of its output arrives when it ends and starts your next turn; you stay alive while it runs, so ending your turn now is safe - do not sleep or poll for it, and end your turn if nothing else is left - ` +
          (params.stream
            ? `batches of its output arrive meanwhile, capped, with anything they leave out in ${created.output}`
            : `read ${created.output} with the read tool to check on it meanwhile`),
        { name: params.name, window, pane: created.pane, run: created.id, output: created.output, stream: !!params.stream },
      );
    },
  });

  pi.registerTool({
    name: "stop_run",
    label: "Stop Run",
    description:
      "Stop a descendant subagent or async_bash run found in list_runs. Asks a subagent to shut down, killing its pane if needed; sends TERM to a bash run's process group. A child that already reported ends as completed; one stopped before it reported ends as stopped.",
    promptSnippet: "stop_run(to, force?) - end a descendant subagent or bash run found in list_runs",
    parameters: Type.Object(
      {
        to: Type.String({
          description:
            "Run id, unique prefix of at least 8 characters, or unambiguous run name; one leading @ is ignored.",
        }),
        force: Type.Optional(
          Type.Boolean({
            description:
              "For a subagent with no usable inbox, allow killing its pane instead. Not needed for bash runs. Destructive and irreversible.",
          }),
        ),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      return reply(await stopRun(params.to, !!params.force));
    },
  });

  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.promptGuidelines.push(NEVER_SLEEP_RULE);
    if (edge) event.systemPromptOptions.promptGuidelines.push(NOTIFY_PARENT_INSTRUCTION);
  });

  pi.on("session_start", async (_event, ctx) => {
    kido = insideKido() ? findKido() : null;
    session = ctx;
    ownSessionId = ctx.sessionManager.getSessionId() || null;
    dir = stateDir();
    pane = process.env.TMUX_PANE || null;
    edge = ownSessionId ? readEdge(ownSessionId) : null;
    pendingNotices.clear();
    written.clear();
    ending = { kind: "other" };
    settled = true;
    parentToldThisTurn = false;
    liveWatchStarted = false;

    // A headless session has no ui, and an older pi has one without this method:
    // both simply get no `@name` completion.
    const ui = ctx.ui;
    if (ui?.addAutocompleteProvider && !completion) {
      const cache: { rows: AgentRow[]; at: number; refreshing: Promise<void> | null } = { rows: [], at: 0, refreshing: null };
      completion = cache;
      ui.addAutocompleteProvider((current: CompletionProvider): CompletionProvider => ({
        triggerCharacters: current.triggerCharacters,
        async getSuggestions(lines, cursorLine, cursorCol, options) {
          const token = atToken((lines[cursorLine] ?? "").slice(0, cursorCol));
          if (token === undefined) return current.getSuggestions(lines, cursorLine, cursorCol, options);
          if (!cache.refreshing && Date.now() - cache.at >= envMs("KIDO_AGENT_LIST_TTL_MS", 1000)) {
            cache.refreshing = discovery()
              .then(({ rows }) => {
                cache.rows = rows.filter((a) => a.kind !== "bash" && a.state !== "ended");
                cache.at = Date.now();
              })
              .catch(() => {})
              .finally(() => {
                cache.refreshing = null;
              });
          }
          const items = agentCompletionItems(cache.rows, token);
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
    if (!ctx.hasUI || !ownSessionId || !kido) return;
    active = true;

    if (!adoptInbox()) {
      stopInbox();
      try {
        await startInbox(ownSessionId, dir);
      } catch {}
    }
    const hold = inboxOpen() ? heldInbox() : null;
    const options: Array<[string, string]> = [
      [OPTION_SESSION, ownSessionId],
      [OPTION_NAME, pi.getSessionName() ?? ""],
    ];
    if (hold) options.push([OPTION_INBOX, hold.path]);
    await writeOptions(options);

    // The task file is the run's record; the sibling "delivered" marker, written
    // only after a successful read, stops a /reload from delivering it twice.
    if (edge) {
      const sessionFile = ctx.sessionManager.getSessionFile();
      if (sessionFile) {
        try {
          writeFileSync(join(edge.dir, "session-file"), sessionFile);
        } catch {}
      }
      const marker = join(edge.dir, "delivered");
      if (!exists(marker)) {
        const task = readTextFile(join(edge.dir, "task"));
        if (task !== undefined) {
          try {
            writeFileSync(marker, "");
          } catch {}
          if (task.trim()) {
            deliver(task);
            ending = { kind: "awaiting-first-turn" };
          }
        }
      }
    }
    const parked = globalThis.__kidoPiExtensionWatches;
    globalThis.__kidoPiExtensionWatches = undefined;
    if (parked) {
      for (const data of parked) watch(data);
    }
    startParentWatch();
  });

  pi.on("session_info_changed", async () => {
    await writeOptions([[OPTION_NAME, pi.getSessionName() ?? ""]]);
  });

  const running = (): void => {
    agentWorking = true;
    workStarted();
    void watchLiveChildren();
  };
  pi.on("agent_start", running);
  pi.on("turn_start", running);
  pi.on("tool_execution_start", running);
  pi.on("tool_call", running);
  pi.on("turn_end", (event: { toolResults?: unknown[] }) => {
    if (event?.toolResults?.length) flushStreams();
  });

  pi.on("agent_end", (event: { messages?: { role?: string; stopReason?: string; errorMessage?: string }[] }) => {
    agentWorking = false;
    scheduleIdleStreams();
    const assistants = (event?.messages ?? []).filter((m) => m?.role === "assistant");
    const last = assistants[assistants.length - 1];
    if (!last) return;
    ending =
      last.stopReason === "error"
        ? { kind: "error", text: last.errorMessage || "no error message given", notified: false }
        : last.stopReason === "aborted"
          ? { kind: "aborted" }
          : { kind: "other" };
  });

  pi.on("agent_settled", async (_event: unknown, ctx: { isIdle(): boolean }) => {
    if (!ctx.isIdle()) return;
    agentWorking = false;
    scheduleIdleStreams();
    settled = true;
    if (!edge) return;
    if (ending.kind === "aborted") return;
    if (ending.kind === "error" && !ending.notified) {
      ending.notified = true;
      parentToldThisTurn = true;
      await notifyParent(
        `subagent stopped on an error: ${trimErrorMessage(ending.text)}\nrun: ${edge.run}\nmessage it to retry, or stop_run to end it`,
        true,
      );
      return;
    }
    if (parentToldThisTurn) return;
    parentToldThisTurn = true;
    await notifyParent(
      `subagent ${edge.run} is idle without reporting: its last turn ended and it did not call notify_parent. Continue it with message_agent, or end it with stop_run.`,
      true,
    );
  });

  pi.on("session_shutdown", async (event?: { reason?: ShutdownReason }) => {
    const reload = event?.reason === "reload";
    stopInbox({ keepListening: reload });
    abandonPending();
    stopParentWatch();
    if (reload) {
      globalThis.__kidoPiExtensionWatches = [...watches.values()].map(
        (entry): WatchData => ({
          run: entry.run,
          name: entry.name,
          output: entry.output,
          target: entry.target,
          offset: entry.offset,
          lines: entry.lines,
          dropped: entry.dropped,
          partial: entry.partial,
          budget: entry.budget,
          budgetTold: entry.budgetTold,
          idleDelay: entry.idleDelay,
        }),
      );
    } else {
      globalThis.__kidoPiExtensionWatches = undefined;
    }
    for (const entry of watches.values()) {
      if (entry.timer) clearInterval(entry.timer);
      clearFlush(entry);
      if (reload) entry.detach?.();
      entry.waiter?.kill();
    }
    watches.clear();
    await endOwnRun(event?.reason);
    if (active && !reload) await unsetOptions();
    active = false;
    session = null;
  });
}

