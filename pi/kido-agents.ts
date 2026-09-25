/**
 * kido-agents — let a pi session see, message and delegate to the other
 * agents in its tmux session.
 *
 * This is the agent-coordination half of kido's pi support; the other half,
 * kido-status.ts, reports this session's status and owns the inbox socket.
 * They meet at the seam kido-status.ts declares; nothing but types is
 * imported from it. Install them together (see pi/README.md); this half
 * alone registers its tools but reports kido as unavailable from all of
 * them.
 *
 * Tools:
 *   `list_agents()`, `set_status(activity)`, `message_agent(to, message,
 *   replyTo?)`, `ask_agent(to, question, timeoutMs?)`, `spawn_subagent(task,
 *   name?, model?, tools?)`, `interrupt_subagent(to)`, `stop_subagent(to,
 *   force?)`, `async_bash(command, name?)` and `notify_parent(summary)` all
 *   shell out to a kido subcommand, asynchronously. They register
 *   unconditionally at factory time and no-op at call time until
 *   session_start has resolved kido and a session id, since pi may run
 *   the factory in invocations that never start a session. ask_agent
 *   waits here, in the extension, because only a
 *   long-lived process has an inbox for the reply to arrive on. A subagent
 *   is told to call notify_parent by a standing instruction appended to its
 *   own system prompt (before_agent_start), since nothing calls it for the
 *   model. The rules behind each tool are in docs/design.md.
 *
 * Inbox dispatch:
 *   Everything arriving on kido-status.ts's inbox socket that parses as a
 *   v1 envelope is handed to handleEnvelope below and dispatched by kind;
 *   plain v0 prompt text never reaches this file at all.
 *
 * Install:
 *   mkdir -p ~/.pi/agent/extensions
 *   cp kido-status.ts kido-agents.ts ~/.pi/agent/extensions/
 *
 * Or, for a one-off run:
 *   pi -e /path/to/kido-status.ts -e /path/to/kido-agents.ts
 */

import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import type { AgentHooks, DeliverAs, Envelope, Seam, SessionContext, StatusHost } from "./kido-status.ts";

// The seam kido-status.ts declares, spelled out again rather than
// imported: importing a runtime value from kido-status.ts would evaluate
// a second copy of that file.
const SEAM = Symbol.for("kido.pi.extension.seam");

function seam(): Seam {
  const g = globalThis as unknown as Record<symbol, Seam | undefined>;
  return (g[SEAM] ??= { host: null, agents: null });
}

// The status half, or null when it is not loaded. Read at call time,
// never at factory time: pi may run this factory first.
function status(): StatusHost | null {
  return seam().host;
}

// Read again here rather than shared across the seam: constants of this
// process, so two readers cannot disagree. The instance id, which is
// generated, comes from the host instead. What kido spawn_subagent set for a child
// is not the same as what this process is - see ownRunID below.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_INSTANCE = process.env.KIDO_AGENT_PARENT_INSTANCE || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;
const RUN_ID = process.env.KIDO_AGENT_RUN_ID || undefined;

// ownRunID answers the only question every subagent-specific behaviour
// below actually means: is THIS process the child of that run, or
// something that merely inherited a child's environment? It returns the
// run id when it is ours, and null otherwise.
//
// The environment alone cannot answer it. Every KIDO_AGENT_* variable is
// inherited by anything an agent's process starts - a human running `pi`
// or `pi --print` in an agent's pane, a tool shelling out to one - so a
// parent edge is a claim any descendant can make, and this file used to
// take it. A nested pi then resolved "self" by pane, found the real
// agent's record, scheduled `kido close-run` on the real agent's
// window on its way out, and would have offered someone else's parent a
// report. Two live agents were killed that way.
//
// So the claim is checked against a fact about this process instead. By
// design the run id IS the child's pi session id (docs/design.md, "The
// run id is the child's session id"): a fresh spawn runs
// `pi --session-id <run-id>` and a resume `pi --session <run-id>`. A
// nested pi inherits the run id but mints a session id of its own, so it
// can never satisfy the equality, while the real child satisfies it on
// both paths. The one thing this gives up is a child spawned as some
// wrapper command that itself execs pi: that pi is a session of its own,
// not the run, and is now treated as the root session it is.
//
// A session id that is not known yet reads as "not a subagent". That is
// the safe direction - the damage in the incident was all in acting - and
// it costs a real child nothing: kido-status.ts resolves the id inside
// session_start, before it calls any hook here and long before any turn
// or tool call, so every caller below already has it. The states where it
// stays null are the ones where pi is outside tmux or kido is off PATH,
// where a child could not report an outcome, close a window or reach a
// parent anyway.
function ownRunID(): string | null {
  if (PARENT_INSTANCE === undefined || RUN_ID === undefined) return null;
  return status()?.sessionId() === RUN_ID ? RUN_ID : null;
}

const isSubagent = (): boolean => ownRunID() !== null;

// What set_status's schema tells the model; the enforced cap is
// kido-status.ts's own.
const MAX_ACTIVITY_BYTES = 256;

// What notify_parent's schema tells the model, and nothing more. The bound
// is `kido notify_parent`'s own: a report over it is written to the run's
// directory whole and the parent is sent its head plus that path.
// Enforcing it here too would be the tool throwing away what the command
// exists to keep.
const MAX_NOTICE_BYTES = 4000;

// capBytes cuts on a code-point boundary, never mid-sequence, mirroring
// kido-status.ts's own (a naive byte slice can split a multi-byte
// character and come back longer than the cap it was enforcing).
function capBytes(text: string, max: number): string {
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

// The task text `kido spawn_subagent` left for us to deliver as our first message.
const TASK_FILE = process.env.KIDO_AGENT_TASK_FILE || undefined;

// spawnCmd (cmd/kido/spawn.go) is the actual ceiling; this is only a cheap
// early refusal that skips a subprocess.
const MAX_SPAWN_DEPTH = 2;

// The knobs below are read once at module scope, so they are set only via
// the environment and a test re-imports the module to change them.

// LINGER_SECONDS is how long a finished subagent's window stays open
// before the linger helper may close it. kido's sweep (internal/reap)
// reads the same variable, and must, or one side closes it first.
const LINGER_SECONDS = Number(process.env.KIDO_LINGER_SECONDS) || 30;

// A subagent's pi is a child of the tmux server, not of the parent's pi,
// so no OS parent-death signal reaches it; it polls instead.
const PARENT_LIVENESS_POLL_MS = Number(process.env.KIDO_PARENT_POLL_MS) || 5000;

// IDLE_EXIT_MS is how long a subagent sits idle after a settled turn
// before it shuts itself down (docs/design.md, "Idle self-exit"). Not the
// same figure as LINGER_SECONDS above, even though both default to 30:
// this one is idle-to-self-shutdown, entirely inside the child's own
// process, and only once it fires does scheduleCompletionLinger's own
// scheduleWindowLinger start the second, independent 30s window-linger
// clock. The two stack; nothing here may fold them into one number.
const IDLE_EXIT_MS = (Number(process.env.KIDO_IDLE_EXIT_SECONDS) || 30) * 1000;

// KEEP_ALIVE opts a child out of idle self-exit entirely, for a
// deliberately long-lived helper (spawn_subagent's keepAlive argument,
// plumbed through as KIDO_AGENT_KEEP_ALIVE by kido spawn_subagent --keep-alive).
const KEEP_ALIVE = process.env.KIDO_AGENT_KEEP_ALIVE === "1";

// How long spawn_subagent waits for `kido spawn_subagent` before treating it as hung.
const SPAWN_TIMEOUT_MS = Number(process.env.KIDO_SPAWN_TIMEOUT_MS) || 5000;

// How long stop_subagent waits for `kido stop_subagent`, which can itself
// block for stopEscalation (cmd/kido/control.go, default 5s), so this
// must comfortably exceed that.
const STOP_TIMEOUT_MS = Number(process.env.KIDO_STOP_TIMEOUT_MS) || 8000;

// ask_agent's default wait: a full turn of the target's latency, not a
// round-trip.
const DEFAULT_ASK_TIMEOUT_MS = 5 * 60 * 1000;

// How often a waiting ask re-reads whether its target is still running.
// Nothing pushes a death at the asker, and an answer can only come from a
// process that still exists, so this is the one thing standing between a
// target dying mid-wait and the asker sitting out its whole timeoutMs.
const ASK_LIVENESS_POLL_MS = Number(process.env.KIDO_ASK_POLL_MS) || 5000;

// How stale the `@name` completion's agent list may get before a
// keystroke kicks a background refresh. Never waited on: the list in hand
// is what the editor is offered, however old it is.
const AGENT_LIST_TTL_MS = Number(process.env.KIDO_AGENT_LIST_TTL_MS) || 1000;

// The most agents `@` offers at once, ahead of whatever files the
// built-in provider found for the same token.
const MAX_AGENT_COMPLETIONS = 10;

// pi's autocomplete shapes (@earendil-works/pi-tui's AutocompleteItem,
// AutocompleteSuggestions and AutocompleteProvider), declared here for
// the same reason the notice renderer's component is: pi's own runtime
// always resolves that package, this one's test suite does not install
// it, and the surface used is this small.
interface CompletionItem {
  value: string;
  label: string;
  description?: string;
}

interface CompletionSuggestions {
  items: CompletionItem[];
  prefix: string;
}

interface CompletionProvider {
  triggerCharacters?: string[];
  getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    options: { signal: AbortSignal; force?: boolean },
  ): Promise<CompletionSuggestions | null>;
  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: CompletionItem,
    prefix: string,
  ): { lines: string[]; cursorLine: number; cursorCol: number };
  shouldTriggerFileCompletion?(lines: string[], cursorLine: number, cursorCol: number): boolean;
}

// atToken reads the `@`-token the cursor sits in, or undefined for a
// cursor that is not in one. It must agree with pi's own
// CombinedAutocompleteProvider (extractAtPrefix: the token back to the
// last delimiter, when it starts with "@"), since the merged list below
// carries one prefix for the agents and the files both.
export function atToken(textBeforeCursor: string): string | undefined {
  const m = textBeforeCursor.match(/(?:^|\s)@([^\s@]*)$/);
  return m ? m[1] : undefined;
}

// The custom message type an inbound notice is delivered as, matched by
// registerMessageRenderer below.
const NOTICE_CUSTOM_TYPE = "kido-notice";

// noticeHeader is the one line prefixed to a notice's own text before the
// model sees it: a notice arrives in the middle of a turn and otherwise
// reads exactly like the user having typed it. The renderer below takes
// this same line back off, since the transcript already says who a
// notification is from. The plain "message" kind deliberately carries no
// such label (docs/design.md, "The inbox").
const noticeHeader = (from: string): string => `notice from ${from} (a subagent or background run's report, not the user):`;

// The custom message type an inbound plain message from another agent is
// delivered as, matched by registerMessageRenderer below. A message with
// no agent behind it is the user speaking and is not one of these.
const MESSAGE_CUSTOM_TYPE = "kido-message";

// How a message's sender stands to this session. The three are not
// interchangeable: a parent is the nearest thing a child has to the user,
// so its instructions carry that weight and the header says so rather
// than disclaiming it; a child's message is a report from work this
// session started; anything else is a peer, whose message is neither.
type SenderRelation = "parent" | "child" | "peer";

const MESSAGE_RELATION: Record<SenderRelation, string> = {
  parent: "your parent, who spawned you",
  child: "your subagent",
  peer: "another agent in this session, not the user",
};

// messageHeader is the one line prefixed to an agent's message before the
// model sees it, for the reason noticeHeader exists: delivered as a user
// message, it otherwise reads exactly like the user typing, and who is
// talking is the one thing the model cannot infer from the text. The
// renderer below takes the line back off and leaves the sender, since a
// human reading the transcript has the sidebar's tree beside it.
const messageHeader = (from: string, relation: SenderRelation): string =>
  `message from @${from} (${MESSAGE_RELATION[relation]}):`;

// The custom message type an inbound ask is delivered as, matched by
// registerMessageRenderer below - the same treatment deliverAgentMessage
// gives a plain message, so the id and reply instructions the model needs
// do not also land in a human's transcript.
const ASK_CUSTOM_TYPE = "kido-ask";

// askHeader mirrors messageHeader; an ask is headed the same way a
// message is, since who is asking and how they stand to this session is
// the same question either kind raises.
const askHeader = (from: string, relation: SenderRelation): string => `ask from @${from} (${MESSAGE_RELATION[relation]}):`;

// The custom message type a batch of a streaming run's output is
// delivered as, rendered collapsed exactly as a notice is.
const STREAM_CUSTOM_TYPE = "kido-stream";

// STREAM_FLUSH_MS and STREAM_FLUSH_CAP_MS are the idle flush schedule: a
// batch held because no turn was free is flushed after the first, then
// after twice that, capped at the second. Each one of those costs a turn,
// which is why it slows down; the doubling and the cap are the whole
// bound on what a long-running build costs an idle agent
// (docs/design-subagents.md, "Streaming a run's output").
const STREAM_FLUSH_MS = Number(process.env.KIDO_STREAM_FLUSH_MS) || 10000;
const STREAM_FLUSH_CAP_MS = Number(process.env.KIDO_STREAM_FLUSH_CAP_MS) || 300000;

// nextStreamFlushDelay is the idle schedule, as a function of nothing but
// the last delay: double it, stop at the cap.
export function nextStreamFlushDelay(prev: number): number {
  return Math.min(prev * 2, STREAM_FLUSH_CAP_MS);
}

// What one batch may carry: the last of it, for the reason the completion
// notice carries a tail rather than a head. Everything cut is still in
// the run's output file, which the batch names.
const STREAM_BATCH_LINES = 200;
const STREAM_BATCH_BYTES = 16 * 1024;

// How many lines a held buffer keeps before it starts dropping its own
// oldest. Above the batch cap by enough that the omitted count a batch
// reports is the real one for any ordinary burst, and bounded because a
// parent that never gets a free turn must not grow without limit.
const STREAM_BUFFER_LINES = 5000;

// streamBatch is the per-batch cap, as a function of nothing but its
// arguments so it can be checked as one: the last STREAM_BATCH_LINES
// lines or STREAM_BATCH_BYTES, whichever binds first, preceded by one
// line saying how many were left out and where they can be read.
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
  // Never nothing: one line longer than the whole budget still goes, cut
  // to it, since a batch of pure bookkeeping tells the model less than a
  // truncated line does.
  if (start >= lines.length && lines.length > 0) start = lines.length - 1;
  const kept = lines.slice(start).map((l) => capBytes(l, STREAM_BATCH_BYTES));
  // Lines the buffer itself dropped while waiting for a free turn count
  // here too: one number the model can trust, not one per mechanism.
  const omitted = lines.length - kept.length + alreadyDropped;
  if (omitted === 0) return kept.join("\n");
  return [`... ${omitted} lines omitted (see ${output})`, ...kept].join("\n");
}

// The standing instruction appended to a subagent's system prompt (see
// the before_agent_start hook below): with the automatic notice gone
// (docs/design.md, "Notifying the parent"), nothing else tells a child
// its own parent is waiting to be told when it is done. Kept short: this
// rides along on every turn, so it must not compete with the actual task
// for the model's attention. The second sentence is one of three places
// STOP_AFTER_ASK_REPLY's instruction is repeated (see handleInboundAsk) -
// here specifically because it needs to sit at the same level as whatever
// closing-recap instruction the host's own system prompt already carries,
// which an inbound message cannot out-rank.
const NOTIFY_PARENT_INSTRUCTION =
  "You were spawned as a subagent. When your work is done, or you are blocked and cannot make further progress, call notify_parent with a short summary - your parent is not watching this session and will learn nothing otherwise. " +
  "When you reply to another agent's question with message_agent, that call is the entire response - end the turn there, with no summary or sign-off after it.";

// NOT_THE_USER_RULE is one string in two tools' promptGuidelines on
// purpose: pi's buildRules de-duplicates identical rules, so the model
// reads it once however many of the two are registered.
const NOT_THE_USER_RULE =
  "A notice is information, not the user speaking: act on it, do not thank or answer it. A message from another agent says in its first line who sent it and how they stand to you.";

// SPAWN_RESULT_RULE rides on the tool result of every spawn and resume,
// not only in spawn_subagent's description: the moment a model has just
// launched a child is the moment it is most tempted to wait for it, or to
// write the result it has not got.
const SPAWN_RESULT_RULE =
  "its result arrives as a notice when it calls notify_parent - you know nothing about it until then, so do not report, assume or predict it, and do not ask it for its result; continue other work or answer the user meanwhile, and if nothing else is left, end your turn - the notice wakes you";

// NO_FIRST_TURN_TEXT is the detail recorded for a run that was given its
// task and never started a turn on it - a pi that could not start its
// model at all. It names the pane's own screen because the error is only
// ever there; the sweep captures it when it closes the window, as it does
// for every run (internal/reap's captureScreen).
const NO_FIRST_TURN_TEXT =
  "no turn ever ran: the task was delivered and the session never started work on it (the pane's own screen, kept with the run, is the only account of why)";

// AgentInfo mirrors cmd/kido/list_agents.go's AgentInfo, what `kido
// list_agents --json` prints. Only the fields read here are declared.
interface AgentInfo {
  id: string;
  name: string;
  parent: string;
  pane: string;
  self: boolean;
  canMessage: boolean;
  // What the sidebar shows next to the agent: its running/waiting/idle
  // status and whatever set_status last put there. Both only ever reach
  // a human, in an `@name` completion's description line.
  status?: string;
  activity?: string;
  // canReply is whether the target could send the message_agent reply an
  // ask waits for: false only when it was spawned with a tools allowlist
  // that excludes message_agent. Missing (older test doubles, never a real
  // kido) reads as true, since a target that cannot reply at all is
  // already caught by canMessage.
  canReply?: boolean;
  window: string;
  stalled: boolean;
  sinceReport: number;
  // Instance is what `kido agent-alive` matches on; empty for an agent
  // that never reported one, which canMessage rules out.
  instance?: string;
}

// What a name is split into for matching. A session nobody named is
// called after its pane title, which is a phrase rather than a handle
// ("Tmux config"), so the word a human would think to type is not at the
// front of the name and matching the whole name alone offers nothing.
const NAME_WORD_SEPARATORS = /[\s\-_/]+/;

// The floor on an inserted id prefix: short enough to type and read,
// long enough that it stays unique as agents come and go, since the list
// it was checked against is only the one on screen at the time.
const MIN_ID_PREFIX = 8;

// completionValue is what accepting a row inserts. A name carrying
// whitespace cannot survive as one `@` token - the editor's own token
// ends at the space, and so does atToken - so that agent is addressed by
// the shortest prefix of its id that is at least MIN_ID_PREFIX long and
// unique among the agents listed, which resolveAgent accepts exactly as
// it accepts a name. Every other name inserts itself.
function completionValue(agents: AgentInfo[], agent: AgentInfo): string {
  if (!/\s/.test(agent.name)) return `@${agent.name}`;
  const others = agents.filter((a) => a.id !== agent.id);
  for (let n = MIN_ID_PREFIX; n <= agent.id.length; n++) {
    const prefix = agent.id.slice(0, n);
    if (!others.some((a) => a.id.startsWith(prefix))) return `@${prefix}`;
  }
  return `@${agent.id}`;
}

// agentCompletionItems is the `@name` half of the editor's completion
// list: every agent in this tmux session whose name, or any word of it,
// starts with the token - this session itself excluded (nobody addresses
// themselves) - with the whole-name matches first, a subagent's row
// naming the parent it belongs to. `parent` is the parent's session id
// (cmd/kido/list_agents.go's parentID), so the name is looked up in the
// same list and the id stands in when the parent is not in it.
function agentCompletionItems(agents: AgentInfo[], token: string): CompletionItem[] {
  const nameByID = new Map(agents.map((a) => [a.id, a.name]));
  const wanted = token.toLowerCase();
  const matched: Array<{ agent: AgentInfo; rank: number }> = [];
  for (const a of agents) {
    if (a.self || !a.name) continue;
    const name = a.name.toLowerCase();
    if (name.startsWith(wanted)) matched.push({ agent: a, rank: 0 });
    else if (name.split(NAME_WORD_SEPARATORS).some((word) => word.startsWith(wanted))) matched.push({ agent: a, rank: 1 });
  }
  // A stable sort, so agents matching equally well keep the order kido
  // listed them in.
  matched.sort((x, y) => x.rank - y.rank);
  return matched
    .slice(0, MAX_AGENT_COMPLETIONS)
    .map(({ agent: a }) => {
      const parent = a.parent ? nameByID.get(a.parent) || a.parent : "";
      const value = completionValue(agents, a);
      const description = [
        a.activity ? `${a.status || "agent"} - ${a.activity}` : a.status || "agent",
        parent ? `subagent of ${parent}` : "",
        // Only worth saying when the label and the insertion differ; a
        // row that reads `@Tmux config` and types an id otherwise does
        // it without warning.
        value === `@${a.name}` ? "" : `inserts ${value}`,
      ].filter(Boolean).join(", ");
      return { value, label: `@${a.name}`, description };
    });
}

// resolveAgent applies the same addressing rules kido message_agent's
// resolveTarget (cmd/kido/message_agent.go) does: an exact, case-insensitive
// name, then an exact id, then a unique id prefix, each erroring on its
// own ambiguity rather than falling through.
export function resolveAgent(agents: AgentInfo[], to: string): { agent?: AgentInfo; error?: string } {
  const byName = agents.filter((a) => a.name && a.name.toLowerCase() === to.toLowerCase());
  if (byName.length === 1) return { agent: byName[0] };
  if (byName.length > 1) return { error: `"${to}" matches several agents by name` };

  const byId = agents.find((a) => a.id === to);
  if (byId) return { agent: byId };

  const byPrefix = agents.filter((a) => a.id.startsWith(to));
  if (byPrefix.length === 1) return { agent: byPrefix[0] };
  if (byPrefix.length > 1) return { error: `"${to}" matches several agents by id` };

  return { error: `no agent matches "${to}"` };
}

// isAncestor reports whether self is an ancestor of target, walking
// target's parent chain; cmd/kido/agents.go's isAncestor is the same walk
// and the two are kept in step. seen guards a cyclic parent chain.
export function isAncestor(agents: AgentInfo[], self: AgentInfo, target: AgentInfo): boolean {
  // Refused outright: a corrupt record naming itself as its parent would
  // otherwise match on the first comparison.
  if (self.id === target.id) return false;
  const byId = new Map(agents.map((a) => [a.id, a]));
  const seen = new Set<string>();
  let cur = target.parent;
  while (cur && !seen.has(cur)) {
    if (cur === self.id) return true;
    seen.add(cur);
    cur = byId.get(cur)?.parent ?? "";
  }
  return false;
}

// onAskEdgeRegistered fires synchronously the instant an outbound ask's
// cycle edge is registered (pendingOutbound.set below, docs/design.md's
// "The cycle edge") - a test seam only, since nothing about that moment
// is otherwise observable from outside the process: the agents-lookup
// subprocess it follows writes its own log line well before the parent's
// await on it resolves, so watching for that write is not a reliable
// proxy for "the edge exists now".
let onAskEdgeRegistered: ((target: string) => void) | undefined;
export function setAskEdgeListener(fn: ((target: string) => void) | undefined): void {
  onAskEdgeRegistered = fn;
}

// One copy per process, for the reason kido-status.ts gives beside its
// own slot; spelled out again rather than imported, as the seam is.
const COPY_SLOT = Symbol.for("kido.pi.extension.agents.copy");

function isFirstCopy(): boolean {
  const path = fileURLToPath(import.meta.url);
  const g = globalThis as unknown as Record<symbol, string | undefined>;
  return (g[COPY_SLOT] ??= path) === path;
}

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
  let parentPollTimer: NodeJS.Timeout | null = null;

  // How an inbound "interrupt"/"stop" envelope reaches pi: captured in
  // sessionStarting, null until a session has started.
  let ctxAbort: (() => Promise<void>) | null = null;
  let ctxShutdown: (() => void) | null = null;

  // widgetUi is the raw pi.on("session_start") ctx.ui, captured directly
  // (not through the seam's SessionContext, which is deliberately narrower
  // - kido-status.ts's own use never needed a widget). Null until a
  // session_start has fired, and re-captured on every one - a /reload
  // hands out a fresh ctx and pi itself tears down the previous widgets
  // (resetExtensionUI's own clearExtensionWidgets), so holding on to a
  // stale ui would call setWidget on a UI nobody is drawing any more.
  let widgetUi: { setWidget(key: string, content: string[] | undefined, options?: { placement?: "aboveEditor" | "belowEditor" }): void } | null = null;

  // pendingNotices is the visual half of an inbound notice, kept separate
  // from model delivery on purpose (see deliverNotice below): an id minted
  // per envelope, live from the moment it arrives until the identical
  // followUp message actually lands in the transcript (message_start
  // fires with the same id in details.noticeId), at which point pi's own
  // registerMessageRenderer takes over showing it and this entry is
  // removed - the widget is a stand-in for the wait, not a second copy.
  const pendingNotices = new Map<string, string>(); // notice id -> sender label

  const NOTICE_WIDGET_KEY = "kido-notice-pending";

  const renderNoticeWidget = (): void => {
    if (!widgetUi) return;
    if (pendingNotices.size === 0) {
      widgetUi.setWidget(NOTICE_WIDGET_KEY, undefined);
      return;
    }
    const lines = [...pendingNotices.values()].map((from) => `notification from ${from}`);
    widgetUi.setWidget(NOTICE_WIDGET_KEY, lines);
  };

  // How a waiting ask_agent ends. "The answer never came" and "there is
  // no longer anywhere for it to come to" are different things to tell a
  // model: only the first leaves an id a late reply can be surfaced
  // against.
  type AskOutcome =
    | { reply: string }
    | { gaveUp: "timeout" | "inbox" | "unsent" | "gone" | "aborted" };

  // Asks this session has sent and is still waiting on, keyed by the
  // ask's own id. Whichever comes first (a matching reply, the timeout,
  // the inbox going away) settles the waiter and drops it. This map is
  // also the cycle-refusal edge set (hasAskOutstandingTo): the write
  // happens synchronously before the await that starts the send, so an
  // inbound ask dispatched while the send is in flight already sees the
  // edge, and settle is idempotent, so a late "unsent" after a reply is a
  // no-op. docs/design.md, "The cycle edge".
  const pendingOutbound = new Map<string, { targetSession: string; settle: (outcome: AskOutcome) => void }>();

  // abandonPending releases every waiting ask because this session's
  // inbox has gone away and is not coming back (a /reload that rebinds
  // at the same path is not that). Iterated over a copy, since settle
  // deletes from the map it walks.
  const abandonPending = (): void => {
    for (const waiter of [...pendingOutbound.values()]) waiter.settle({ gaveUp: "inbox" });
  };

  // The cycle-refusal edge set, read off the waiters themselves: an edge
  // to a target exists exactly as long as an ask to it is waiting, and a
  // reply-shaped envelope that matched nothing drops no waiter.
  const hasAskOutstandingTo = (session: string): boolean => {
    if (!session) return false;
    for (const waiter of pendingOutbound.values()) {
      if (waiter.targetSession === session) return true;
    }
    return false;
  };

  // Delivery goes through the status half: a task, an ask and a plain
  // inbox prompt are all the same kind of arrival. deliverAs is how the
  // one arrival that is not - a steer, which joins the turn already
  // running instead of queueing behind it - says so; everything else
  // takes the default (docs/design.md, "Steer and followUp").
  const deliver = (text: string, deliverAs?: DeliverAs): void => {
    status()?.deliver(text, deliverAs);
  };

  // labelFrom names an envelope's sender for the model to read, in the
  // same fallback order targetLabel (cmd/kido/message.go) uses. It is a
  // label only, shown to the model, never the address a reply actually
  // resolves against - see pendingInboundAsks below for why.
  const labelFrom = (from: Envelope["from"]): string => from.name || from.session || from.pane || "another agent";

  // deliverNotice hands an inbound notice to the model as a custom
  // message rather than an ordinary user message, so the TUI can render
  // it collapsed (registerMessageRenderer(NOTICE_CUSTOM_TYPE, ...) below)
  // while the model still sees the notice's full text - collapsing is a
  // transcript-display concern only. Every notice collapses the same way
  // regardless of who sent it: kind, not identity, is what a sender chose
  // when it ran `kido notify_parent` instead of `kido message_agent`,
  // and `from` is advisory anyway (docs/design.md, the inbox), so
  // nothing here does a lookup to decide.
  //
  // The two halves of "deliver a notice" run on purpose different
  // schedules. Visual arrival is immediate: renderNoticeWidget puts a
  // "notification from X" row up above the editor the instant this
  // function runs, before anything is awaited, so a human watching sees
  // it the moment the envelope lands rather than whenever the current
  // turn happens to end.
  //
  // Model delivery changed, deliberately, from what every other envelope
  // kind still uses: deliverAs is "steer", not "followUp". A notice is
  // the one kind where a parent not knowing a child is done defeats the
  // reason the child was spawned at all - the point of doing work in a
  // subagent is to keep going in parallel, and a parent whose own turn
  // runs long (its own tool calls, orchestrating other children) could
  // otherwise sit on a finished child's report for however long that
  // takes: measured live, two subagents' notices both sat invisible for
  // several minutes and then landed together the instant the parent's
  // turn happened to end, which is the followUp queueing this replaces.
  // Steer does not knock the running turn off course the way an abort
  // would: measured against pi 0.85.1's agent loop
  // (@earendil-works/pi-agent-core's agent-loop.js), a steering message is
  // only ever drained between a completed turn's tool results and the
  // next model call (getSteeringMessages is polled at turn_end and at the
  // top of the next iteration, never mid-tool-call), so it can never land
  // between an assistant's tool call and that call's own result. The
  // model decides whether to act on it now or keep going - the judgement
  // an orchestrator is meant to make, just with the information in front
  // of it instead of withheld until its own turn happens to end. Plain
  // messages and asks stay on followUp: an ask is answered synchronously
  // by a `message_agent` call the model makes on its own schedule
  // regardless, and a plain message has no analogous "the sender is now
  // blocked waiting to hear back" urgency. docs/design.md's "The inbox"
  // section describes followUp as universal; this is the one documented
  // exception.
  //
  // The two halves meet exactly once each: the widget's entry is removed
  // when (and only when) the identical steered message actually reaches
  // the transcript (the message_start listener below, matched by
  // noticeId - fired identically whether the message arrived by steer or
  // followUp, so nothing else here needed to change), so the model text
  // is sent through sendMessage here and nowhere else - one wire call,
  // one entry, one widget row that hands off to it rather than a second
  // rendering of the same notice.
  // messageSender answers who an inbound plain message is from and how
  // they stand to this session, or null for "no agent at all" - which is
  // the user speaking, and is delivered as their own words, unlabelled.
  //
  // A human running `kido message_agent` from a bare pane has no state
  // record, so kido puts no session in `from` and only a pane (senderOf,
  // cmd/kido/message_agent.go), and no listed agent owns that pane: the
  // same pair senderIsAncestor reads to recognise a human, so an agent
  // would have to get two things wrong at once to be mistaken for one.
  //
  // The relationship is read from the list rather than from `from`: a
  // parent is the instance that spawned this run (and only for a real
  // child of it - the environment alone is a claim any descendant
  // inherits, see ownRunID), and a child is an agent whose own parent edge
  // points at this session.
  const messageSender = async (from: Envelope["from"]): Promise<{ name: string; relation: SenderRelation } | null> => {
    const listed = await fetchAgents();
    // No list to check against: a `from` carrying a session is an agent's,
    // since a human's never does. Labelling it as a peer beats falling
    // back to the unlabelled delivery this replaced, which would tell the
    // model the sender was the user.
    if ("error" in listed) return from.session ? { name: labelFrom(from), relation: "peer" } : null;
    const sender = listed.agents.find((a) => (from.session ? a.id === from.session : !!from.pane && a.pane === from.pane));
    if (!sender) return null;
    const self = listed.agents.find((a) => a.self);
    const isParent = isSubagent() && !!PARENT_INSTANCE && sender.instance === PARENT_INSTANCE;
    const isChild = !!self && !!sender.parent && sender.parent === self.id;
    return { name: sender.name || labelFrom(from), relation: isParent ? "parent" : isChild ? "child" : "peer" };
  };

  // deliverAgentMessage hands an agent's message to the model as a custom
  // message, for the reason deliverNotice does: the TUI can then draw it
  // with its sender while the model reads the header. Queued (`followUp`)
  // and turn-triggering exactly as the unlabelled delivery it replaces -
  // only the labelling changed, not when a message arrives.
  const deliverAgentMessage = (text: string, from: string, relation: SenderRelation): void => {
    workStarted();
    pi.sendMessage(
      {
        customType: MESSAGE_CUSTOM_TYPE,
        content: `${messageHeader(from, relation)}\n${text}`,
        display: true,
        details: { from, relation },
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
  };

  const handleInboundMessage = async (env: Envelope): Promise<void> => {
    if (!env.text) return;
    const sender = await messageSender(env.from);
    if (!sender) {
      deliver(env.text);
      return;
    }
    deliverAgentMessage(env.text, sender.name, sender.relation);
  };

  const deliverNotice = (text: string, from: string): void => {
    clearIdleExit();
    const noticeId = randomUUID();
    pendingNotices.set(noticeId, from);
    renderNoticeWidget();
    pi.sendMessage(
      { customType: NOTICE_CUSTOM_TYPE, content: `${noticeHeader(from)}\n${text}`, display: true, details: { from, noticeId } },
      { deliverAs: "steer", triggerTurn: true },
    );
  };

  // streamBuffers holds, per async run, the lines that have arrived and
  // not yet been handed to the model. A "stream" envelope never reaches
  // the model on arrival, which is the whole feature: pi drains one
  // steering message per poll, so one message per chunk would be one LLM
  // turn per chunk. Flushed as one message at the moments flushStreams
  // is called from, and nowhere else.
  const streamBuffers = new Map<string, { name: string; output: string; lines: string[]; dropped: number }>();

  // The idle flush schedule: one timer for the session, and the delay it
  // was last armed with. Both are reset when a run completes, since the
  // next run's first lines deserve the floor rather than whatever the
  // last one escalated to.
  let streamTimer: NodeJS.Timeout | null = null;
  let streamDelay = STREAM_FLUSH_MS;

  const clearStreamTimer = (): void => {
    if (streamTimer) {
      clearTimeout(streamTimer);
      streamTimer = null;
    }
  };

  // armStreamFlush schedules the next idle flush, doubling the delay each
  // time up to the cap. Only ever one timer: a second run's lines ride
  // the one already ticking rather than buying a turn of their own.
  const armStreamFlush = (): void => {
    if (streamTimer) return;
    const delay = streamDelay;
    streamTimer = setTimeout(() => {
      streamTimer = null;
      streamDelay = nextStreamFlushDelay(streamDelay);
      flushStreams();
    }, delay);
    streamTimer.unref?.(); // a held batch must never hold pi's event loop open
  };

  // handleInboundStream buffers one chunk. Nothing is delivered here.
  const handleInboundStream = (env: Envelope): void => {
    const run = env.run || env.from.name || env.from.session || "run";
    const entry = streamBuffers.get(run) ?? {
      name: env.from.name || run,
      output: env.output || "the run's output file",
      lines: [],
      dropped: 0,
    };
    for (const line of env.text.split("\n")) entry.lines.push(line);
    if (entry.lines.length > STREAM_BUFFER_LINES) {
      entry.dropped += entry.lines.length - STREAM_BUFFER_LINES;
      entry.lines = entry.lines.slice(entry.lines.length - STREAM_BUFFER_LINES);
    }
    streamBuffers.set(run, entry);
    armStreamFlush();
  };

  // flushStreams hands every held batch to the model, one collapsed
  // custom message per run, and is the only place a stream chunk is
  // delivered. Its callers are the schedule: a turn that had tool calls
  // (free - the next LLM call is already committed), the idle timer
  // above, and a run's own completion notice, which must not arrive
  // before the output it is the ending of.
  const flushStreams = (): void => {
    if (streamBuffers.size === 0) return;
    clearStreamTimer();
    clearIdleExit();
    for (const [run, entry] of [...streamBuffers]) {
      streamBuffers.delete(run);
      if (entry.lines.length === 0) continue;
      const header = `async run ${JSON.stringify(entry.name)} output (run ${run})`;
      pi.sendMessage(
        {
          customType: STREAM_CUSTOM_TYPE,
          content: `${header}\n${streamBatch(entry.lines, entry.output, entry.dropped)}`,
          display: true,
          details: { from: entry.name, run, output: entry.output },
        },
        { deliverAs: "steer", triggerTurn: true },
      );
    }
  };

  // pendingInboundAsks remembers, for an ask still awaiting our reply,
  // the asker's pane - the one part of `from` a `/reload` cannot change.
  // labelFrom's own fallback (session id, absent a name) is exactly what
  // a `/reload` invalidates: pi mints a fresh session id, so the address
  // an unnamed asker was told to reply to at ask-delivery time can go
  // stale before this session's model gets around to answering. Rather
  // than trying to keep that label fresh, message_agent re-resolves the
  // target from this pane at the moment a reply is actually sent (see
  // resolveReplyTarget) - the instance id is the other value a reload
  // cannot change, but kido's addressing has nothing that resolves one,
  // while every pane is already in `kido list_agents --json`. Entries are
  // removed once a reply consumes them; a never-answered ask leaves one
  // behind for this session's lifetime, the same bound as an unanswered
  // ask's own wire round trip already accepts.
  const pendingInboundAsks = new Map<string, string>(); // ask id -> asker's pane

  // resolveReplyTarget re-resolves a reply's destination from the
  // asker's pane, freshly, rather than trusting the label the model was
  // given when the ask arrived (see pendingInboundAsks). Falls back to
  // the model's own `to` when there is no pending ask to re-resolve from
  // (an unprompted message_agent call, or a replyTo this session never
  // saw an ask for, including a second reply to one already answered) or
  // when the pane no longer resolves to anyone (the asker really is
  // gone, and the caller's own `to` will fail exactly as it would have
  // without this).
  const resolveReplyTarget = async (to: string, replyTo: string | undefined): Promise<string> => {
    const pane = replyTo ? pendingInboundAsks.get(replyTo) : undefined;
    if (!pane) return to;
    pendingInboundAsks.delete(replyTo!);
    const listed = await fetchAgents();
    if ("error" in listed) return to;
    const current = listed.agents.find((a) => a.pane === pane);
    return current?.id ?? to;
  };

  // handleInboundAsk delivers an ask to the model with an explicit
  // instruction that a reply is expected, unless answering would close a
  // cycle, in which case it is refused on the wire and not delivered at
  // all. A model replying to an ask routinely called message_agent
  // correctly and then went on to write a user-facing summary of what it
  // had just done - wasted, since the asker already has the answer
  // (delivered by message_agent, not by this session's own output) and no
  // user is waiting on a report in this session. STOP_AFTER_ASK_REPLY below
  // targets exactly that trailing narration, not "how to reply" (the
  // existing tool-call line already gets that right). It is the weakest of
  // three places this same instruction is repeated (see
  // NOTIFY_PARENT_INSTRUCTION and messageAgentTool's own result text) - a
  // prompt instruction competes with whatever system prompt the host
  // already set and does not reliably win, so this reduces the sign-off
  // rather than eliminating it; the other two are closer to where the
  // model actually decides whether to keep talking.
  const STOP_AFTER_ASK_REPLY =
    "That message_agent call is the entire response - end the turn there, with no summary or sign-off after it.";
  const handleInboundAsk = async (env: Envelope): Promise<"ok" | "refused"> => {
    if (hasAskOutstandingTo(env.from.session)) return "refused";
    const sender = await messageSender(env.from);
    const from = sender?.name ?? labelFrom(env.from);
    const relation = sender?.relation ?? "peer";
    if (env.from.pane) pendingInboundAsks.set(env.id, env.from.pane);
    workStarted();
    pi.sendMessage(
      {
        customType: ASK_CUSTOM_TYPE,
        content:
          `${askHeader(from, relation)}\n${from} is asking (id ${env.id}): ${env.text}\n\n` +
          `${from} cannot see this session's context, so make the answer self-contained. ` +
          `Reply with message_agent(to=${JSON.stringify(from)}, message=<answer>, replyTo=${JSON.stringify(env.id)}). ${STOP_AFTER_ASK_REPLY}`,
        display: true,
        details: { from, relation, id: env.id, question: env.text },
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
    return "ok";
  };

  // handleInboundReply resolves a waiting ask_agent when its id matches a
  // pending outbound ask; otherwise the answer is delivered as an
  // ordinary message rather than dropped.
  const handleInboundReply = (env: Envelope): void => {
    const waiter = env.replyTo ? pendingOutbound.get(env.replyTo) : undefined;
    if (waiter) {
      waiter.settle({ reply: env.text });
      return;
    }
    if (env.text) {
      deliver(`${labelFrom(env.from)} replied (to ask ${env.replyTo || "?"}): ${env.text}`);
    }
  };

  // senderIsAncestor answers the question every _subagent kind asks on
  // arrival: did this come from someone entitled to act on this session -
  // one of its ancestors, or a human at the CLI. One predicate for steer,
  // interrupt and stop, mirroring descendantTarget (cmd/kido/control.go),
  // which asks it of the same tree from the other end.
  //
  // Checked here as well as by kido because `from` is advisory, and for
  // coherence rather than for protection: a process that can write this
  // socket can claim to be anyone (docs/design.md, the inbox).
  const senderIsAncestor = async (env: Envelope): Promise<boolean> => {
    const listed = await fetchAgents();
    if ("error" in listed) return false;
    const self = listed.agents.find((a) => a.self);
    if (!self) return false;
    // A human has no state record, so kido puts no session in `from`;
    // recognised by the pair, so an agent has to get two things wrong at
    // once to be mistaken for one.
    if (!env.from.session && !listed.agents.some((a) => a.pane === env.from.pane)) return true;
    const from = listed.agents.find((a) => a.id === env.from.session);
    return !!from && isAncestor(listed.agents, from, self);
  };

  // handleInboundControl answers an "interrupt" or "stop" envelope, but
  // only for a sender senderIsAncestor accepts (docs/design.md, "Steer,
  // interrupt and stop").
  const handleInboundControl = async (env: Envelope, kind: "interrupt" | "stop"): Promise<"ok" | "refused"> => {
    if (!(await senderIsAncestor(env))) return "refused";
    if (kind === "interrupt") {
      // Awaited, so a message sent after the reply finds the turn ended
      // rather than in a queue the abort skips.
      await ctxAbort?.();
    } else {
      ctxShutdown?.();
    }
    return "ok";
  };

  // handleInboundSteer delivers a course correction into the turn already
  // running, rather than queueing it for the end of one like every other
  // text-carrying kind (docs/design.md, "Steer and followUp"). Same
  // sender rule as interrupt and stop: steering redirects work under way,
  // which is the same authority with less force, and a steer anyone could
  // send while an interrupt is a descendant's alone would be incoherent.
  //
  // Labelled with its sender because it arrives mid-task, where an
  // unattributed instruction reads as if the session had told itself.
  const handleInboundSteer = async (env: Envelope): Promise<"ok" | "refused"> => {
    if (!(await senderIsAncestor(env))) return "refused";
    if (env.text) deliver(`${labelFrom(env.from)} is redirecting this work: ${env.text}`, "steer");
    return "ok";
  };

  // handleEnvelope dispatches one v1 envelope off the inbox and returns
  // the wire answer. Every branch delivers something to the model rather
  // than dropping it, an unrecognised kind included.
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
        // Before the notice itself, never after: a run's ending must not
        // reach the model ahead of the output tail it refers to. The
        // schedule starts over too - this run is done escalating.
        flushStreams();
        streamDelay = STREAM_FLUSH_MS;
        if (env.text) deliverNotice(env.text, labelFrom(env.from));
        return "ok";
      case "stream":
        if (env.text) handleInboundStream(env);
        return "ok";
      case "steer":
        return handleInboundSteer(env);
      case "interrupt":
      case "stop":
        return handleInboundControl(env, env.kind);
      default:
        if (env.text) {
          deliver(`[unrecognised message kind ${JSON.stringify(env.kind)} from ${labelFrom(env.from)}] ${env.text}`);
        }
        return "ok";
    }
  };

  const fetchAgents = async (): Promise<{ agents: AgentInfo[] } | { error: string }> => {
    const host = status();
    if (!host) return { error: "kido-status.ts is not loaded" };
    const res = await host.runKido(["list_agents", "--json"], { timeoutMs: 2000 });
    if ("error" in res) return res;
    try {
      return { agents: res.out ? JSON.parse(res.out) : [] };
    } catch (err) {
      return { error: err instanceof Error ? err.message : String(err) };
    }
  };

  // The list the `@name` completion is served from, and nothing else: a
  // keystroke must never wait on `kido list_agents --json`, so the editor
  // gets whatever the last call returned - stale, or empty before the
  // first one lands - while a refresh runs behind it. A failed lookup
  // still stamps the clock, so a kido that cannot answer is asked once a
  // TTL rather than once a keystroke.
  let completionRegistered = false;
  let completionAgents: AgentInfo[] = [];
  let completionAgentsAt = 0;
  let completionRefresh: Promise<void> | null = null;

  const refreshCompletionAgents = (): void => {
    if (completionRefresh || Date.now() - completionAgentsAt < AGENT_LIST_TTL_MS) return;
    completionRefresh = (async () => {
      const listed = await fetchAgents();
      if ("agents" in listed) completionAgents = listed.agents;
      completionAgentsAt = Date.now();
    })()
      .catch(() => {})
      .finally(() => {
        completionRefresh = null;
      });
  };

  // `@` is pi's own file-reference trigger, so this wraps the built-in
  // provider rather than replacing it: matching agents first, then
  // whatever files pi found for the same token, under the one prefix both
  // halves share. `@src/...` therefore still completes files, and a token
  // matching no agent is the built-in's answer untouched. The await here
  // is pi's own file lookup, unchanged; kido's half of the list is never
  // awaited (see refreshCompletionAgents).
  const createAgentCompletionProvider = (current: CompletionProvider): CompletionProvider => ({
    triggerCharacters: current.triggerCharacters,
    async getSuggestions(lines, cursorLine, cursorCol, options) {
      const token = atToken((lines[cursorLine] ?? "").slice(0, cursorCol));
      if (token === undefined) return current.getSuggestions(lines, cursorLine, cursorCol, options);
      refreshCompletionAgents();
      const items = agentCompletionItems(completionAgents, token);
      const files = await current.getSuggestions(lines, cursorLine, cursorCol, options);
      if (items.length === 0) return files;
      const prefix = `@${token}`;
      // Only a file half that answered the same token can be merged: pi
      // returns the prefix its own items are to replace, and two prefixes
      // in one list would have the editor cut the wrong text.
      const fileItems = files && files.prefix === prefix ? files.items : [];
      return { items: [...items, ...fileItems], prefix };
    },
    // An agent item's value is `@name`, which is what pi's own
    // applyCompletion inserts for any `@` prefix - so the insertion, the
    // trailing space and the cursor are pi's, not a second implementation
    // of them here.
    applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
      return current.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
    },
    shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
      return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
    },
  });

  // parentInRegistry asks kido whether PARENT_INSTANCE is still running:
  // true, false, or null for "no answer", which is not evidence either
  // way. `kido agent-alive` reads every live state record and answers
  // that one bit. It is deliberately not `kido list_agents --json`, which the
  // poll used to read: that is a display command, and it both scopes
  // itself to the caller's tmux session and collapses its result to one
  // record per pane. A `pi --print` started inside the parent's pane
  // inherits TMUX_PANE and wins that pane, which dropped the parent's
  // record out of the answer entirely and made a healthy parent look
  // gone. A debounce here used to absorb that, treating a wrong answer as
  // a slow one; asking a question no pane collision can disturb removes
  // the need for it (docs/design.md, "Identity"). It also costs one
  // process and no tmux round trip, on a timer that never stops.
  const parentInRegistry = async (): Promise<boolean | null> => {
    const host = status();
    if (!host || PARENT_INSTANCE === undefined) return null;
    const res = await host.runKido(["agent-alive", PARENT_INSTANCE], { timeoutMs: 2000 });
    if ("error" in res) return null;
    if (res.out === "true") return true;
    if (res.out === "false") return false;
    return null; // some kido that does not know this subcommand; say nothing
  };

  // parentIsAlive: kill(pid, 0) first, where ESRCH is a definite "gone" -
  // answered without a subprocess, so keepAlive gives no protection
  // against a genuinely dead parent. Success or EPERM is not proof of life
  // (a pid can be recycled), so anything else defers to the registry, on
  // one reading: with the collision above gone there is no known way for a
  // live parent's record to be missing from it. An unreachable kido stays
  // the one inconclusive case - never shut down on a guess.
  const parentIsAlive = async (): Promise<boolean> => {
    if (PARENT_PID === undefined) return true;
    try {
      process.kill(PARENT_PID, 0);
    } catch (err) {
      if ((err as NodeJS.ErrnoException)?.code === "ESRCH") return false;
    }
    return (await parentInRegistry()) ?? true;
  };

  // Idempotent: a /reload re-runs session_start and must not pile up a
  // second timer. Unref'd so it never holds the event loop open.
  // pollInFlight stops a tick from starting a second parentIsAlive() call
  // while the previous one is still awaiting its subprocess round trip.
  // It outlives the debounce it was first written for, on its own merits:
  // setInterval fires on schedule regardless of whether its callback's own
  // async work has finished, so a reading slower than
  // PARENT_LIVENESS_POLL_MS - a loaded machine, a slow kido - would have
  // every tick spawn another process on top of the ones already waiting,
  // which is a pile-up on exactly the machine least able to afford it.
  // Overlapping readings no longer corrupt a verdict, since each is now
  // independently trustworthy; they are simply waste. Skipping the tick
  // delays the next real reading and never suppresses one.
  let pollInFlight = false;

  const startParentLivenessPoll = (shutdown: () => void): void => {
    // Only the child of the run watches the parent that spawned it: a
    // process that merely inherited the pid would end itself over a death
    // that says nothing about it (see ownRunID).
    if (PARENT_PID === undefined || !isSubagent()) return;
    stopParentLivenessPoll();
    parentPollTimer = setInterval(() => {
      if (pollInFlight) return;
      pollInFlight = true;
      parentIsAlive().then((alive) => {
        pollInFlight = false;
        if (alive) return;
        // Stop first, or a slow shutdown is asked for again every tick.
        stopParentLivenessPoll();
        shutdown();
      });
    }, PARENT_LIVENESS_POLL_MS);
    parentPollTimer.unref();
  };

  const stopParentLivenessPoll = (): void => {
    if (parentPollTimer) {
      clearInterval(parentPollTimer);
      parentPollTimer = null;
    }
    pollInFlight = false;
  };

  // reportedToParent records that this run has spoken for itself, which
  // is what its ending is judged against: a child that never called the
  // tool has its silence reported for it (see endOwnRun). Module state
  // rather than a fact on disk because it is a fact about this process's
  // own conversation, and it survives a /reload for the same reason the
  // run does - the session carries straight on in the same process.
  let reportedToParent = false;

  // lastTurnError is the errorMessage of the last turn when it stopped on
  // "error"; an abort is not an error. errorNoticeSent keeps one notice per
  // failure, since agent_settled can fire again with nothing new.
  let lastTurnError: string | undefined;
  let errorNoticeSent = false;

  // idleExitTimer is the idle self-exit clock: armed on every settled turn
  // (turnEnded) and on the delivery of the task a child was spawned with
  // (deliverTask), cleared by any sign of new work (workStarted). Only a
  // child arms it at all (see armIdleExit's own gate).
  let idleExitTimer: NodeJS.Timeout | null = null;

  // awaitingFirstWork is true between the task being handed to the model
  // and the first sign that anything began. A child whose pi cannot start
  // its model at all - no API key for it, the failure this came from -
  // settles at startup looking exactly like an idle child, so its ending
  // has to be told apart from one that worked and stopped: this is what
  // makes the outcome a failure rather than a completion, and what puts
  // "no turn ever ran" in the notice its parent gets.
  let awaitingFirstWork = false;

  const clearIdleExit = (): void => {
    if (idleExitTimer) {
      clearTimeout(idleExitTimer);
      idleExitTimer = null;
    }
  };

  // What every arrival that is about to produce a turn does, whether it
  // came through the status half's deliver() or was sent from here as a
  // custom message: the idle self-exit timer must not fire in the gap
  // before pi's own turn_start, and a child that has been given work is no
  // longer waiting for its first.
  const workStarted = (): void => {
    awaitingFirstWork = false;
    clearIdleExit();
  };

  // windowFocused asks kido whether this session's own window is the one
  // some client is currently looking at - the same test close-run and
  // the sweep (internal/reap) use, via a dedicated kido subcommand rather
  // than fetchAgents, since kido list_agents --json carries no focus field.
  const windowFocused = async (windowID: string): Promise<boolean> => {
    const host = status();
    if (!host?.kidoPath()) return false; // no kido, no way to check; do not block on a guess either way
    const res = await host.runKido(["window-focused", windowID], { timeoutMs: 2000 });
    return "out" in res && res.out.trim() === "true";
  };

  // hasLiveChildren asks kido whether any run this session started is
  // still going. The reading is of the run records, not of anything this
  // process remembers: a child outlives the turn that spawned it and a
  // /reload forgets everything in memory, while the record carries the
  // parent edge and the outcome for as long as the run exists. An
  // unreachable kido answers false, the same direction every other
  // unavailable-kido path takes - the idle clock is the behaviour this
  // session had before there was a query at all.
  const hasLiveChildren = async (): Promise<boolean> => {
    const host = status();
    if (!host?.kidoPath()) return false;
    const res = await host.runKido(["children-alive", host.instance()], { timeoutMs: 2000 });
    return "out" in res && res.out.trim() === "true";
  };

  // armIdleExit starts (or restarts) the idle-to-self-shutdown clock. Only
  // a child arms it (isSubagent, exactly as notify_parent's own refusal
  // check), and only when it has not opted out with keepAlive. Unref'd so
  // it can never hold the process alive on its own, the same as the
  // parent-liveness poll.
  const armIdleExit = (shutdown: () => void): void => {
    if (!isSubagent() || KEEP_ALIVE) return;
    clearIdleExit();
    idleExitTimer = setTimeout(async () => {
      // A session with a child of its own still running is not idle,
      // however quiet it has been: "I have spawned it and I am waiting for
      // its report" settles a turn exactly as finished work does, and
      // exiting there orphans the child, which the sweep then closes
      // mid-work. The clock re-arms, so the last child ending resumes it -
      // as does the child's notice, which is new work like any other.
      if (await hasLiveChildren()) {
        armIdleExit(shutdown);
        return;
      }
      const listed = await fetchAgents();
      const self = "agents" in listed ? listed.agents.find((a) => a.self) : undefined;
      // A window a client is currently looking at is not reaped out from
      // under them; the timer re-arms instead of giving up, so the window
      // is collected once the user looks away (docs/design.md, "Idle
      // self-exit").
      if (self?.window && (await windowFocused(self.window))) {
        armIdleExit(shutdown);
        return;
      }
      // pi's own shutdown handler only ends the session once it is not
      // mid-compaction, and only re-checks that on its own next
      // agent_settled - so a request made here while pi is compacting can
      // be recorded and never acted on. Re-arming costs nothing once the
      // session does end: sessionEnding clears the timer first.
      shutdown();
      armIdleExit(shutdown);
    }, IDLE_EXIT_MS);
    idleExitTimer.unref();
  };

  const listAgentsParams = Type.Object({}, { additionalProperties: false });
  const listAgentsTool: ToolDefinition<typeof listAgentsParams> = {
    name: "list_agents",
    label: "List Agents",
    description: "List every agent visible in this tmux session, including yourself.",
    promptSnippet: "list_agents() - see every agent in this tmux session",
    parameters: listAgentsParams,
    async execute() {
      const res = await fetchAgents();
      // Any failure reads as an empty session: nothing the model can do.
      if ("error" in res) {
        return { content: [{ type: "text", text: "[]" }], details: [] };
      }
      return { content: [{ type: "text", text: JSON.stringify(res.agents) }], details: res.agents };
    },
  };

  const setStatusParams = Type.Object(
    {
      // No maxLength here: it would count UTF-16 code units against a
      // byte budget and reject a call the tool would otherwise happily
      // truncate - status()?.setActivity (kido-status.ts) already enforces
      // MAX_ACTIVITY_BYTES itself, in bytes, by truncating rather than
      // refusing. The schema states the cap for the model to read; only
      // one place enforces it.
      activity: Type.String({
        description: 'What you are doing right now ("refactoring internal/ui"), or "" to clear it. Capped at 256 bytes.',
      }),
    },
    { additionalProperties: false },
  );
  const setStatusTool: ToolDefinition<typeof setStatusParams> = {
    name: "set_status",
    label: "Set Status",
    description:
      "Set the free-text activity shown next to you in kido's tmux sidebar. Separate from your running/waiting/idle status.",
    promptSnippet: "set_status(activity) - tell everyone else what you are doing, visible in list_agents()",
    parameters: setStatusParams,
    async execute(_toolCallId, params) {
      status()?.setActivity(params.activity);
      return { content: [{ type: "text", text: "ok" }], details: {} };
    },
  };

  const messageAgentParams = Type.Object(
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
  );
  const messageAgentTool: ToolDefinition<typeof messageAgentParams> = {
    name: "message_agent",
    label: "Message Agent",
    // The waiting clause is the cost a caller needs at the moment it
    // chooses, which is here and not in the system prompt: a model
    // reaching for "send my subagent a correction" reads this as the
    // general-purpose choice, with nothing saying the message sits queued
    // until the work it meant to redirect is already done. steer's own
    // description names this one for the same reason, the other way round.
    description:
      "Send a message to another agent in this tmux session, addressed by name, session id, or a unique id prefix. It waits for the receiver to finish its current turn; use steer_subagent for a correction that is useless once the work is done.",
    promptSnippet: "message_agent(to, message, replyTo?) - send a message to another agent in this tmux session",
    parameters: messageAgentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot message other agents" }], details: {} };
      }
      const args = ["message_agent"];
      // --reply-to alone makes it a reply; kido derives the kind the wire
      // correlates on from the flag, since nothing else it could mean.
      if (params.replyTo) args.push("--reply-to", params.replyTo);
      // Captured before resolveReplyTarget consumes the entry: this is the
      // tool result's own chance to say STOP_AFTER_ASK_REPLY, and the
      // strongest of the three places it is repeated (see
      // handleInboundAsk) - a tool result is the last thing the model reads
      // before deciding whether to keep talking, closer to that decision
      // than either system prompt it competes with. Only for a reply to an
      // ask this session actually has pending, not every replyTo: a reply
      // to a notice, or a stale id, has nothing to stop after.
      const wasPendingAsk = !!params.replyTo && pendingInboundAsks.has(params.replyTo);
      // Re-resolved from the asker's pane when this is a reply to a
      // still-remembered ask, since the model's own `to` was handed to it
      // when the ask arrived and a `/reload` since then can have moved the
      // asker to a new session id (docs/design.md's addressing rules have
      // nothing that survives that; the pane does).
      const to = await resolveReplyTarget(params.to, params.replyTo);
      // "--" first: a model-authored `to` beginning with a dash would
      // otherwise be parsed as a kido flag.
      args.push("--", to);
      const res = await host.runKido(args, { input: params.message, timeoutMs: 5000 });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not message ${params.to}: ${res.error}` }], details: {} };
      }
      // kido message_agent says whether it delivered by inbox or pasted.
      const delivered = res.out || `message delivered to ${params.to}`;
      return {
        content: [{ type: "text", text: wasPendingAsk ? `${delivered} ${STOP_AFTER_ASK_REPLY}` : delivered }],
        details: {},
      };
    },
  };

  const askAgentParams = Type.Object(
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
  );
  const askAgentTool: ToolDefinition<typeof askAgentParams> = {
    name: "ask_agent",
    label: "Ask Agent",
    description:
      "Ask another agent a question and block until it replies - one full turn of the target's latency, not a round-trip, since a busy target does not see the question until it would otherwise have stopped. Refused for an ancestor, a target outside this tmux session, one with no inbox or no message_agent tool, or yourself. Not for collecting a subagent's result: that arrives on its own as a notice when the child finishes, and an ask blocks this turn until the target answers, so the notice cannot be read until the ask returns.",
    promptSnippet:
      "ask_agent(to, question, timeoutMs?) - ask another agent a question and wait for its reply (DO NOT use to get subagent results, wait for notification instead)",
    parameters: askAgentParams,
    async execute(_toolCallId, params, signal) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot ask other agents" }], details: {} };
      }

      const listed = await fetchAgents();
      if ("error" in listed) {
        return { content: [{ type: "text", text: `could not list agents: ${listed.error}` }], details: {} };
      }
      const agents = listed.agents;

      const self = agents.find((a) => a.self);
      if (!self) {
        return { content: [{ type: "text", text: "could not find this agent among kido's agents; cannot ask" }], details: {} };
      }

      // kido list_agents --json is already scoped to this tmux session, so a
      // target outside it simply does not resolve here.
      const { agent: target, error } = resolveAgent(agents, params.to);
      if (!target) {
        return { content: [{ type: "text", text: `could not ask ${params.to}: ${error}` }], details: {} };
      }
      if (target.id === self.id) {
        return { content: [{ type: "text", text: "cannot ask yourself" }], details: {} };
      }
      // isAncestor(agents, target, self): is the TARGET an ancestor of ME?
      // A child asking its parent (or any ancestor) is what this refuses;
      // a parent asking its own child is the ordinary case and must fall
      // through.
      if (isAncestor(agents, target, self)) {
        return {
          content: [{ type: "text", text: `${target.name || target.id} is an ancestor; the parent stays free to orchestrate, so it cannot be asked` }],
          details: {},
        };
      }
      if (!target.canMessage) {
        return {
          content: [{ type: "text", text: `${target.name || target.id} has no inbox; an ask cannot work over a paste, there is no way back` }],
          details: {},
        };
      }
      if (target.canReply === false) {
        return {
          content: [{
            type: "text",
            text: `${target.name || target.id} was spawned without the message_agent tool and cannot reply; use message_agent, or wait for its notify_parent notice`,
          }],
          details: {},
        };
      }
      // Fail fast rather than wait out the timeout against a target that
      // is never going to answer.
      if (target.stalled) {
        return {
          content: [{
            type: "text",
            text: `${target.name || target.id} has been quiet for ${target.sinceReport}s while reporting running; likely stalled, refusing to wait for a reply`,
          }],
          details: {},
        };
      }
      // Same fail-fast reasoning, for the case stalled cannot catch: a
      // target that died seconds ago is not stalled (that takes minutes
      // of silence), and canMessage guarantees an instance to ask about.
      // An inconclusive answer (no instance, an error, or a kido too old
      // to know the subcommand) is never treated as "dead".
      if (target.instance) {
        const alive = await host.runKido(["agent-alive", target.instance], { timeoutMs: 2000 });
        if (!("error" in alive) && alive.out === "false") {
          return {
            content: [{
              type: "text",
              text: `${target.name || target.id} is no longer running; refusing to wait for a reply`,
            }],
            details: {},
          };
        }
      }

      // The inbox may have gone away while fetchAgents() was in flight.
      // Checked synchronously, with no await between here and
      // pendingOutbound.set below, so a teardown either already caught
      // this waiter with abandonPending or closed the inbox before this
      // check (docs/design.md, "When the inbox goes away").
      if (!host.inboxOpen()) {
        return {
          content: [{
            type: "text",
            text: `this session's inbox is unavailable; no reply from ${params.to} can be waited for`,
          }],
          details: {},
        };
      }

      const id = randomUUID();
      const timeoutMs = params.timeoutMs ?? DEFAULT_ASK_TIMEOUT_MS;

      // One waiter, settled by whoever gets there first; settle drops it
      // and cancels the timer itself. Registered before the send, so a
      // reply cannot race past it.
      let deliverReply: (outcome: AskOutcome) => void = () => {};
      let watch: NodeJS.Timeout | null = null;
      const reply = new Promise<AskOutcome>((resolve) => {
        deliverReply = resolve;
      });
      let settled = false;
      const onAbort = () => settle({ gaveUp: "aborted" });
      const settle = (outcome: AskOutcome): void => {
        settled = true;
        clearTimeout(timer);
        if (watch) clearInterval(watch);
        signal?.removeEventListener("abort", onAbort);
        pendingOutbound.delete(id);
        deliverReply(outcome);
      };
      const timer = setTimeout(() => settle({ gaveUp: "timeout" }), timeoutMs);
      timer.unref(); // a wait must never hold pi's event loop open
      pendingOutbound.set(id, { targetSession: target.id, settle });
      onAskEdgeRegistered?.(target.id);
      // pi hands every tool the turn's AbortSignal, and Esc aborts it. A
      // wait that ignores it is a turn the human cannot end, since pi's
      // own abort path waits for the tool call to return. addEventListener
      // on an already-aborted signal never fires - true of the signal pi
      // hands in, but not of this one any more: the prechecks above this
      // point are themselves awaits, and an abort landing during one of
      // them reaches this line already aborted. Checked explicitly rather
      // than relied on to have already fired, since "pi does not call a
      // tool whose signal is already aborted" is a fact about the call,
      // not about every await inside it.
      if (signal?.aborted) onAbort();
      else signal?.addEventListener("abort", onAbort, { once: true });

      // target.id, not params.to: passing the resolved id removes a second
      // resolution inside kido ask_agent that could disagree with this one.
      const sent = await host.runKido(["ask_agent", "--id", id, "--", target.id], {
        input: params.question,
        timeoutMs: 5000,
      });
      if ("error" in sent) {
        settle({ gaveUp: "unsent" });
        return { content: [{ type: "text", text: `could not ask ${params.to}: ${sent.error}` }], details: {} };
      }

      // The precheck above only rules out a target that was already gone.
      // One that dies while this waits - the ordinary case of a child that
      // finishes and exits without replying - leaves nothing to release
      // the waiter, since the answer could only have come from that
      // process. Same reading as the precheck: a definite "false" settles,
      // an unanswerable kido never does. Unref'd, so a wait still never
      // holds pi's event loop open, and guarded against a reading that
      // outlives its own tick, since setInterval fires whether or not the
      // last callback finished.
      // Not started once the wait is already over: an abort or a timeout
      // during the send settles before this point is reached, and an
      // interval armed after its own settle is one nothing will ever
      // clear.
      if (target.instance && !settled) {
        const instance = target.instance;
        let reading = false;
        watch = setInterval(() => {
          if (reading) return;
          reading = true;
          host.runKido(["agent-alive", instance], { timeoutMs: 2000 }).then((res) => {
            reading = false;
            if (!("error" in res) && res.out === "false") settle({ gaveUp: "gone" });
          });
        }, ASK_LIVENESS_POLL_MS);
        watch.unref();
      }

      const outcome = await reply;
      if ("reply" in outcome) {
        return { content: [{ type: "text", text: outcome.reply }], details: {} };
      }
      if (outcome.gaveUp === "aborted") {
        return {
          content: [{
            type: "text",
            text: `the ask to ${params.to} was interrupted (ask id ${id}); a later reply naming this id will still arrive as a message`,
          }],
          details: {},
        };
      }
      if (outcome.gaveUp === "gone") {
        return {
          content: [{
            type: "text",
            text: `${target.name || target.id} stopped running before answering (ask id ${id}); no reply can come from it now`,
          }],
          details: {},
        };
      }
      if (outcome.gaveUp === "inbox") {
        return {
          content: [{
            type: "text",
            text: `this session's inbox closed before ${params.to} answered (ask id ${id}); no reply can reach it now, so ask again if the answer still matters`,
          }],
          details: {},
        };
      }
      return {
        content: [{
          type: "text",
          text: `no reply from ${params.to} within ${timeoutMs}ms (ask id ${id}); a later reply naming this id will still arrive as a message`,
        }],
        details: {},
      };
    },
  };

  // safeSubagentName generates a name when the caller gives none. It goes
  // on a tmux command line, so it must avoid the characters tmuxConfUnsafe
  // rejects; hex does, and a name that reads better might not.
  const safeSubagentName = (): string => `sub-${randomUUID().slice(0, 8)}`;

  const spawnSubagentParams = Type.Object(
    {
      task: Type.Optional(
        Type.String({
          description:
            "The task to give the new subagent, delivered as its first message. Required unless resume is given - a resumed run keeps its own original task and refuses a new one. " +
            "The subagent starts with no context beyond this text (a fork excepted), so name the files, the lines and the specific change, say what it must report back, and say whether it is to write code or only research. " +
            "Synthesize what you already know into the task rather than writing \"based on your findings\".",
        }),
      ),
      name: Type.Optional(
        Type.String({
          description:
            "A name for the subagent's window and session; a name is generated when omitted. Refused together with resume - a resumed run keeps its original window name.",
        }),
      ),
      // "provider/model-id" (e.g. claude-bridge/claude-sonnet-5), never a
      // bare alias like "sonnet" - kido spawn_subagent checks it against
      // `pi --list-models` and refuses up front rather than letting pi
      // accept it, print "Use /login ..." and exit having run no turn.
      model: Type.Optional(
        Type.String({
          description:
            'Model for the subagent to run, as "provider/model-id" (e.g. claude-bridge/claude-sonnet-5) - see `pi --list-models`. A bare alias like "sonnet" is refused, not resolved.',
        }),
      ),
      tools: Type.Optional(
        Type.Array(Type.String(), {
          description: "Tool names the subagent may use - its capability ceiling. Omit to leave it at pi's default set.",
        }),
      ),
      keepAlive: Type.Optional(
        Type.Boolean({
          description:
            "Keep the subagent alive after it goes idle instead of letting it self-reap after a short timeout. For a deliberately long-lived helper; defaults to false.",
        }),
      ),
      resume: Type.Optional(
        Type.String({
          description:
            "Resume a dead or finished subagent by its own run id (from this tool's earlier result, or `kido runs`) instead of starting a new one, in its own new window. Refused together with task or name.",
        }),
      ),
      fork: Type.Optional(
        Type.Boolean({
          description:
            "Start the subagent holding this session's context: it is forked from this conversation and then given the task. For a short judgement or merge step that has to know what was already decided - the whole context is replayed on every one of its turns, so it is a poor choice for a long worker. Refused together with resume; defaults to false.",
        }),
      ),
    },
    { additionalProperties: false },
  );
  const spawnSubagentTool: ToolDefinition<typeof spawnSubagentParams> = {
    name: "spawn_subagent",
    label: "Spawn Subagent",
    description:
      "Create a subagent in its own tmux window with a task, or resume a dead or finished one by its run id. With fork: true it starts holding this session's context, for a judgement step that has to know what was already decided. Returns its identity immediately without waiting for it to finish. Its result arrives as a notice when it calls notify_parent; do not ask_agent a child for its result.",
    promptSnippet:
      "spawn_subagent(task, name?, model?, tools?, keepAlive?, fork?) or spawn_subagent(resume, model?, tools?, keepAlive?) - delegate a task to a new subagent, optionally forked from your own context, or resume a dead one, in its own window",
    // pi merges these into the rules section of the system prompt while
    // the tool is registered (buildRules in pi's system-prompt.js), which
    // is where a standing rule about waiting belongs: a description is
    // read when the tool is called, and these are about the turns after.
    // NOT_THE_USER_RULE is the identical string in async_bash's list, so
    // buildRules' own de-duplication keeps it to one bullet.
    promptGuidelines: [
      "A subagent's result arrives on its own as a notice when it finishes; never ask a child for its result and never poll list_agents for it.",
      "Trust but verify: a child's report says what it intended to do, not what it did - check the diff before relaying success.",
      NOT_THE_USER_RULE,
    ],
    parameters: spawnSubagentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot spawn a subagent" }], details: {} };
      }
      // resume keeps the run's own original task and window name - the same
      // pair `kido spawn_subagent --resume` itself refuses alongside --task-file and
      // --name - so a call naming both is ambiguous about which one the
      // model actually wants and is refused rather than silently picking
      // one.
      if (params.resume) {
        if (params.task) {
          return {
            content: [{ type: "text", text: "resume and task cannot both be given: a resumed run keeps its own original task" }],
            details: {},
          };
        }
        if (params.name) {
          return {
            content: [{ type: "text", text: "resume and name cannot both be given: a resumed run keeps its own original window name" }],
            details: {},
          };
        }
        if (params.fork) {
          return {
            content: [{ type: "text", text: "resume and fork cannot both be given: a resumed run continues its own session, a fork starts a new one from this session's context" }],
            details: {},
          };
        }
      } else if (!params.task) {
        return { content: [{ type: "text", text: "task is required unless resume is given" }], details: {} };
      }
      const depth = (DEPTH ?? 0) + 1;
      if (depth > MAX_SPAWN_DEPTH) {
        return {
          content: [{ type: "text", text: `already at the maximum subagent nesting depth (${MAX_SPAWN_DEPTH}); cannot spawn another` }],
          details: {},
        };
      }

      // Spelled once for both spawn and resume: pi's own --model/--tools
      // constrain the child, kido spawn_subagent's identically named pair
      // goes in the run record (spawn only - --resume has no top-level
      // --tools of its own, and only defaults --model from the run's own
      // meta when neither this nor an explicit command overrides it).
      const modelAndTools = [
        ...(params.model ? ["--model", params.model] : []),
        ...(params.tools && params.tools.length > 0 ? ["--tools", params.tools.join(",")] : []),
      ];
      const keepAliveArgs = params.keepAlive ? ["--keep-alive"] : [];

      if (params.resume) {
        const args = [
          "spawn_subagent",
          "--resume",
          params.resume,
          "--parent-pid",
          String(process.pid),
          "--parent-instance",
          host.instance(),
          ...keepAliveArgs,
        ];
        // Only named after "--" if there is something to override - an
        // absent --model already gets the run's own recorded one back from
        // kido spawn_subagent --resume itself.
        if (modelAndTools.length > 0) args.push("--", "pi", ...modelAndTools);
        const res = await host.runKido(args, { timeoutMs: SPAWN_TIMEOUT_MS });
        if ("error" in res) {
          return { content: [{ type: "text", text: `could not resume ${params.resume}: ${res.error}` }], details: {} };
        }
        const [windowID, paneID, runID] = res.out.split(/\s+/);
        // A resumed run keeps its original task, which it was already
        // given, so nothing is delivered to it and it comes back idle.
        // Saying so is the whole of this line's job: a parent that
        // resumed a run and then waited for it waited on a child that was
        // waiting on it.
        return {
          content: [{
            type: "text",
            text: `resumed ${runID} (window ${windowID}, pane ${paneID}); it is back with its context and idle - send it a message to continue, since it is waiting for one; ${SPAWN_RESULT_RULE}`,
          }],
          details: { window: windowID, pane: paneID, run: runID },
        };
      }

      // The session to fork is this one, and the extension is told what it
      // is (kido-status.ts's sessionId) rather than kido guessing from a
      // pane: `pi --fork` resolves a session by id and there is exactly one
      // right answer here. A session with no id at all - pi outside a
      // session file - has nothing to fork from, and saying so beats
      // spawning a child that silently holds no context.
      const forkArgs: string[] = [];
      if (params.fork) {
        const sessionID = status()?.sessionId();
        if (!sessionID) {
          return { content: [{ type: "text", text: "this session has no id of its own to fork from; spawn without fork" }], details: {} };
        }
        forkArgs.push("--fork", sessionID);
      }

      const name = params.name || safeSubagentName();
      const child = ["pi", "--name", name, ...modelAndTools];

      // The task goes to kido spawn_subagent as text on stdin; kido decides it
      // becomes a file.
      const res = await host.runKido(
        [
          "spawn_subagent",
          "--parent-pid",
          String(process.pid),
          "--parent-instance",
          host.instance(),
          "--depth",
          String(depth),
          "--name",
          name,
          "--task-file",
          "-",
          ...modelAndTools,
          ...keepAliveArgs,
          ...forkArgs,
          "--",
          ...child,
        ],
        { input: params.task!, timeoutMs: SPAWN_TIMEOUT_MS },
      );
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not spawn subagent: ${res.error}` }], details: {} };
      }
      const [windowID, paneID, runID] = res.out.split(/\s+/);
      return {
        content: [{
          type: "text",
          text:
            `spawned ${name} (window ${windowID}, pane ${paneID}, run ${runID})${params.fork ? ", forked from this session's context" : ""}; ` +
            SPAWN_RESULT_RULE,
        }],
        details: { name, window: windowID, pane: paneID, run: runID, fork: !!params.fork },
      };
    },
  };

  const steerSubagentParams = Type.Object(
    {
      to: Type.String({
        description: "Who to steer: a descendant's exact name, exact session id, or a unique prefix of its session id.",
      }),
      message: Type.String({ description: "The course correction to deliver." }),
    },
    { additionalProperties: false },
  );
  const steerSubagentTool: ToolDefinition<typeof steerSubagentParams> = {
    name: "steer_subagent",
    label: "Steer Subagent",
    description:
      "Redirect a descendant that is already working, without aborting its turn: the message joins the run it is in rather than waiting for it to finish. For a correction that is useless once the work is done. Refused for anything but a descendant. Use message_agent when the message can wait for the current turn to end.",
    promptSnippet: "steer_subagent(to, message) - redirect a descendant mid-task, without aborting its turn",
    parameters: steerSubagentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot steer other agents" }], details: {} };
      }
      const res = await host.runKido(["steer_subagent", "--", params.to], { input: params.message, timeoutMs: 5000 });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not steer ${params.to}: ${res.error}` }], details: {} };
      }
      return { content: [{ type: "text", text: res.out || `steered ${params.to}` }], details: {} };
    },
  };

  const interruptSubagentParams = Type.Object(
    {
      to: Type.String({
        description: "Who to interrupt: an agent's exact name, exact session id, or a unique prefix of its session id.",
      }),
    },
    { additionalProperties: false },
  );
  const interruptSubagentTool: ToolDefinition<typeof interruptSubagentParams> = {
    name: "interrupt_subagent",
    label: "Interrupt Subagent",
    description:
      "Abort a descendant's current turn without ending its session - it stays alive and idle, ready for a corrected instruction. Refused for anything but a descendant.",
    promptSnippet: "interrupt_subagent(to) - abort a descendant's current turn, without ending its session",
    parameters: interruptSubagentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot interrupt other agents" }], details: {} };
      }
      const res = await host.runKido(["interrupt_subagent", "--", params.to], { timeoutMs: 5000 });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not interrupt ${params.to}: ${res.error}` }], details: {} };
      }
      return { content: [{ type: "text", text: res.out || `interrupted ${params.to}` }], details: {} };
    },
  };

  const stopSubagentParams = Type.Object(
    {
      to: Type.String({
        description: "Who to stop: an agent's exact name, exact session id, or a unique prefix of its session id.",
      }),
      force: Type.Optional(
        Type.Boolean({
          description:
            "Kill the target's window directly if it has no inbox to ask nicely over. Destructive and irreversible - only set this when you mean it.",
        }),
      ),
    },
    { additionalProperties: false },
  );
  const stopSubagentTool: ToolDefinition<typeof stopSubagentParams> = {
    name: "stop_subagent",
    label: "Stop Subagent",
    description:
      "End a descendant's session. Asks it to shut down over its inbox and, if it does not within a few seconds, kills its window instead. Refused for anything but a descendant.",
    promptSnippet: "stop_subagent(to, force?) - end a descendant's session, killing its window if it does not respond",
    parameters: stopSubagentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot stop other agents" }], details: {} };
      }
      const args = ["stop_subagent"];
      if (params.force) args.push("--force");
      args.push("--", params.to);
      const res = await host.runKido(args, { timeoutMs: STOP_TIMEOUT_MS });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not stop ${params.to}: ${res.error}` }], details: {} };
      }
      return { content: [{ type: "text", text: res.out || `stopped ${params.to}` }], details: {} };
    },
  };

  const asyncBashParams = Type.Object(
    {
      command: Type.String({
        description:
          'The command to run in the background, as a shell command line (e.g. "make -j8 && ./run"), run under bash -c.',
      }),
      name: Type.Optional(
        Type.String({
          description: "A name for the run and its window; derived from the command's first word when omitted.",
        }),
      ),
      stream: Type.Optional(
        Type.Boolean({
          description:
            "Send the command's output to this session in batches while it runs, instead of only at the end. Off by default.",
        }),
      ),
    },
    { additionalProperties: false },
  );
  const asyncBashTool: ToolDefinition<typeof asyncBashParams> = {
    name: "async_bash",
    label: "Async Bash",
    description:
      "Run a shell command in the background - for a command whose result you do not need for your next step, so this session can keep working while it runs. A command you need before continuing, such as tests you are about to act on or a build you are about to read, belongs in bash, in the foreground, not here. This replaces polling: exactly one notice arrives when the command ends, carrying its exit status and a tail of its output. Read the output file with the ordinary read tool at any time before then to check on progress; if you have nothing else to do, end your turn instead - the notice wakes you. With stream=true the output also arrives in batches as it runs - between your own tool calls while you are working, on a slowing schedule when you are idle, capped per batch and per run, so some lines are only ever in the file, which always has all of them.",
    promptSnippet:
      "async_bash(command, name?) - run a command in the background; a notice with its exit status arrives when it ends, read the output file meanwhile",
    promptGuidelines: [
      "Use async_bash only for a command whose result you do not need next; if you need it before continuing, run it in bash instead. A notice arrives when a background command ends - if you have nothing else to do, end your turn rather than sleep or poll for it.",
      NOT_THE_USER_RULE,
    ],
    parameters: asyncBashParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot run a background command" }], details: {} };
      }
      const args = ["async_bash"];
      if (params.name) args.push("--name", params.name);
      if (params.stream) args.push("--stream");
      args.push("--", params.command);
      const res = await host.runKido(args, { timeoutMs: SPAWN_TIMEOUT_MS });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not start background command: ${res.error}` }], details: {} };
      }
      // Four fields for a bash run, the last of them where the output is
      // being written; kido says where that is (cmd/kido's printCreated).
      const [windowID, paneID, runID, outputPath] = res.out.split(/\s+/);
      return {
        content: [{
          type: "text",
          text:
            `started run ${runID}${params.name ? ` (${params.name})` : ""} in window ${windowID}; ` +
            `a notice with its exit status and a tail of its output arrives when it ends - if you have nothing else to do, end your turn now, since the notice wakes you; never sleep or poll for it - ` +
            (params.stream
              ? `batches of its output arrive meanwhile, capped, with anything they leave out in ${outputPath}`
              : `read ${outputPath} with the read tool to check on it meanwhile`),
        }],
        details: { name: params.name, window: windowID, pane: paneID, run: runID, output: outputPath, stream: !!params.stream },
      };
    },
  };

  const notifyParentParams = Type.Object(
    {
      // No maxLength here, for the same reason set_status's schema has
      // none: it is a character count checked against a byte budget, and
      // typebox rejects the whole call on it rather than truncating -
      // measured live, a model given a long report had to redo the call
      // after "summary must not have more than N characters".
      summary: Type.String({
        description:
          `A short summary of the finished work to send to your parent. Your parent reads the first ${MAX_NOTICE_BYTES} bytes; ` +
          `anything longer is kept in full in this run's directory and the notice says where, so nothing is lost.`,
      }),
    },
    { additionalProperties: false },
  );
  const notifyParentTool: ToolDefinition<typeof notifyParentParams> = {
    name: "notify_parent",
    label: "Notify Parent",
    description:
      "Tell your parent your work is done, carrying a short summary. Call this once, when you have an answer or have given up - nothing else reports it. Only meaningful for a subagent; refused for a session with no parent.",
    promptSnippet: "notify_parent(summary) - tell your parent your work is done, once it actually is",
    parameters: notifyParentParams,
    async execute(_toolCallId, params) {
      // The one refusal that has nothing to do with kido being reachable:
      // a session that is not itself a spawned child (a human's own
      // interactive pi, or one started from inside an agent's pane with
      // that agent's environment around it) has no parent of its own to
      // tell, so this must read as a clear refusal rather than the same
      // silent no-op every other tool gives an unavailable kido.
      if (!isSubagent()) {
        return { content: [{ type: "text", text: "this session has no parent (it was not spawned as a subagent); notify_parent has nobody to tell" }], details: {} };
      }
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot notify the parent" }], details: {} };
      }
      // No target, and nothing listed to find one: `kido notify_parent`
      // reads the parent edge out of KIDO_AGENT_PARENT_INSTANCE, the same
      // environment this file's own PARENT_INSTANCE comes from. This used
      // to fetch every agent, find its own row and read `parent` off it -
      // a whole subprocess and a tmux pane listing to recover something
      // kido had handed the process at spawn.
      // The summary goes through untouched: what a report over the cap
      // costs is decided by `kido notify_parent`, which keeps the whole of
      // it in the run's directory and sends the parent its head and that
      // path. This tool used to cut it to the cap here, and the rest of a
      // long report was simply gone.
      const res = await host.runKido(["notify_parent"], { input: params.summary, timeoutMs: 5000 });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not notify parent: ${res.error}` }], details: {} };
      }
      reportedToParent = true;
      return { content: [{ type: "text", text: res.out || "notified parent" }], details: {} };
    },
  };

  pi.registerTool(listAgentsTool);
  pi.registerTool(setStatusTool);
  pi.registerTool(messageAgentTool);
  pi.registerTool(askAgentTool);
  pi.registerTool(spawnSubagentTool);
  pi.registerTool(steerSubagentTool);
  pi.registerTool(interruptSubagentTool);
  pi.registerTool(stopSubagentTool);
  pi.registerTool(asyncBashTool);
  pi.registerTool(notifyParentTool);

  // Captured directly from pi, not through the seam: kido-status.ts's
  // SessionContext deliberately does not carry ui (it never needed one),
  // and a /reload fires session_start again with a fresh ctx, so this is
  // re-captured exactly like ctxAbort/ctxShutdown above rather than read
  // once. Registering a second "session_start" listener here is fine -
  // pi calls every extension's registration for a given event, and this
  // one only ever reads ctx, never races kido-status.ts's own.
  pi.on("session_start", (_event: unknown, ctx: { ui?: (NonNullable<typeof widgetUi> & { addAutocompleteProvider?: (factory: (current: CompletionProvider) => CompletionProvider) => void }) | null }) => {
    widgetUi = ctx.ui ?? null;
    // A headless session has no ui at all, and a pi older than 0.87.1 has
    // one without this method; both simply get no `@name` completion.
    // Registered once: session_start fires again on a /reload, and a
    // second wrapper would ask kido for the same list twice per keystroke.
    if (!ctx.ui?.addAutocompleteProvider || completionRegistered) return;
    completionRegistered = true;
    // Nothing is fetched here: a session that never types `@` never asks
    // kido for a list, and the first `@` keystroke kicks the refresh that
    // the keystroke after it is served from.
    ctx.ui.addAutocompleteProvider((current) => createAgentCompletionProvider(current));
  });

  // The other end of deliverNotice's hand-off: once the identical
  // followUp message actually reaches the transcript (matched by the
  // noticeId minted there), pi's own registerMessageRenderer above is
  // now showing it, so the stand-in widget row for that one notice is
  // done its job. Filtered to our own custom type and a noticeId we
  // actually minted, since message_start fires for every message this
  // session sends or receives, ours included (an outbound message_agent
  // reply, for one).
  pi.on("message_start", (event: { message?: { role?: string; customType?: string; details?: { noticeId?: string } } }) => {
    const m = event?.message;
    if (m?.role !== "custom" || m.customType !== NOTICE_CUSTOM_TYPE) return;
    const noticeId = m.details?.noticeId;
    if (!noticeId || !pendingNotices.has(noticeId)) return;
    pendingNotices.delete(noticeId);
    renderNoticeWidget();
  });

  // The free flush, and the guard that is the whole of why streaming is
  // affordable. pi awaits this handler before it polls the steering queue
  // (measured against pi 0.85.1's agent-loop.js), so a batch sent from
  // here is drained by the very next poll. A turn that ran tools has its
  // next LLM call already committed and the batch costs nothing; a turn
  // that ran none was the agent stopping, and flushing there buys a turn
  // whose own turn_end has no tool calls either - which, with output
  // still arriving, is a loop that ends when the command does. Those
  // batches wait for the idle schedule instead.
  pi.on("turn_end", (event: { toolResults?: unknown[] }) => {
    if (!event?.toolResults?.length) return;
    flushStreams();
  });

  // A streamed batch collapses the way a notice does, and for the same
  // reason: it is bulk the model reads and a human only wants one line of.
  // Its own first line names the run, so the collapsed row does not repeat
  // a sender the way a notice's does.
  pi.registerMessageRenderer<{ from: string }>(STREAM_CUSTOM_TYPE, (message, options, theme) => {
    const content = typeof message.content === "string" ? message.content : "";
    const [firstLine, ...rest] = content.split("\n");
    if (!options.expanded) {
      return { render: () => [theme.fg("dim", `${firstLine} — ctrl-o to expand`)] };
    }
    return { render: () => [theme.fg("dim", firstLine), ...rest] };
  });

  // A message is never collapsed, which is the one way this renderer
  // differs from the notice's: a notice is a report a human wants one line
  // of, and a message is something another agent wrote to be read. What
  // the row drops is the header's parenthetical - it tells the model what
  // it is reading, while a human has the sidebar's tree beside the
  // transcript. Any of the three headers is recognised, so a transcript
  // reloaded without details still shows the message rather than its
  // framing.
  pi.registerMessageRenderer<{ from: string }>(MESSAGE_CUSTOM_TYPE, (message, _options, theme) => {
    const from = message.details?.from || "another agent";
    const raw = typeof message.content === "string" ? message.content : "";
    const header = (Object.keys(MESSAGE_RELATION) as SenderRelation[])
      .map((relation) => `${messageHeader(from, relation)}\n`)
      .find((line) => raw.startsWith(line));
    const content = header ? raw.slice(header.length) : raw;
    const lines = [theme.fg("dim", `message from @${from}:`), ...content.split("\n")];
    return { render: () => lines };
  });

  // An ask shows only the question, never the id or the reply
  // instructions the model needs but a human reading the transcript does
  // not - those live in message.details.question, put there by
  // handleInboundAsk, not parsed back out of the full content. A
  // transcript entry reloaded with no details at all falls back to the
  // raw content, id and instructions included, being the best available.
  pi.registerMessageRenderer<{ from: string; question: string }>(ASK_CUSTOM_TYPE, (message, _options, theme) => {
    const from = message.details?.from || "another agent";
    const question = message.details?.question ?? (typeof message.content === "string" ? message.content : "");
    const lines = [theme.fg("dim", `ask from @${from}:`), ...question.split("\n")];
    return { render: () => lines };
  });

  // Every notice, whatever kind of sender wrote it, collapses to one line
  // by default; ctrl-o expansion is pi's own built-in toggle
  // (options.expanded), not a keybinding registered here, so this does not
  // fight another extension (pi-plain.ts) that reads the same toggle. The
  // component below satisfies pi-tui's Component interface (render(width):
  // string[]) without importing @earendil-works/pi-tui: pi's own runtime
  // always resolves it (a dependency of pi-coding-agent itself), but this
  // package's own test suite does not install it, and the interface is one
  // method wide.
  pi.registerMessageRenderer<{ from: string }>(NOTICE_CUSTOM_TYPE, (message, options, theme) => {
    const from = message.details?.from || "another agent";
    const raw = typeof message.content === "string" ? message.content : "";
    const header = `${noticeHeader(from)}\n`;
    const content = raw.startsWith(header) ? raw.slice(header.length) : raw;
    if (!options.expanded) {
      // The collapsed row is the notice's own first line - true today of
      // every sender (an async run's "async run NAME result: status", a
      // subagent's own one-sentence report) - and nothing past it: a
      // sender that wants a better collapsed summary writes it as line
      // one, rather than this file parsing further into text it did not
      // produce.
      const firstLine = content.split("\n", 1)[0];
      const summary = firstLine ? `: ${firstLine}` : "";
      const line = theme.fg("dim", `notification from ${from}${summary} — ctrl-o to expand`);
      return { render: () => [line] };
    }
    const lines = [theme.fg("dim", `notification from ${from}:`), ...content.split("\n")];
    return { render: () => lines };
  });

  const ERROR_NOTICE_LIMIT = 400;
  const trimErrorMessage = (msg: string): string => (msg.length > ERROR_NOTICE_LIMIT ? `${msg.slice(0, ERROR_NOTICE_LIMIT)}…` : msg);

  // The instruction goes in as a guideline, not a returned systemPrompt:
  // a forced prompt is opaque to pi-claude-bridge, whose prompt capture
  // then fails the turn. pi hands every call fresh options, so it is
  // pushed on every turn and never accumulates.
  pi.on("before_agent_start", (event) => {
    if (!isSubagent()) return;
    event.systemPromptOptions.promptGuidelines.push(NOTIFY_PARENT_INSTRUCTION);
  });

  // agent_end fires once per attempt, retries included, and agent_settled
  // once after them, so the last agent_end before a settle is the turn's
  // outcome and only agent_settled speaks.
  pi.on("agent_end", (event: { messages?: { role?: string; stopReason?: string; errorMessage?: string }[] }) => {
    const assistants = (event?.messages ?? []).filter((m) => m?.role === "assistant");
    const last = assistants[assistants.length - 1];
    if (!last) return;
    if (last.stopReason === "error") {
      lastTurnError = last.errorMessage || "no error message given";
      errorNoticeSent = false;
    } else {
      lastTurnError = undefined;
    }
  });

  // A failed turn is told to the parent at once. reportedToParent stays
  // as it was: the child has still said nothing about its work.
  pi.on("agent_settled", async (_event: unknown, ctx: { isIdle(): boolean }) => {
    if (!ctx.isIdle() || !isSubagent() || !lastTurnError || errorNoticeSent) return;
    errorNoticeSent = true;
    const host = status();
    if (!host?.kidoPath()) return;
    const runID = ownRunID();
    const text =
      `subagent stopped on an error: ${trimErrorMessage(lastTurnError)}\n` +
      `run: ${runID}\n` +
      `message it to retry, or spawn_subagent(resume: "${runID}") once it has exited`;
    await host.runKido(["notify_parent"], { input: text, timeoutMs: 5000 });
  });

  // deliverTask hands the model the task kido spawn_subagent left for us, the same
  // way an inbox prompt is delivered. A missing or unreadable file is
  // nothing to deliver, never a reason to fail startup. The task file is
  // never unlinked (it is the run's record); the sibling "delivered"
  // marker, written only after a successful read, is what stops a /reload
  // from delivering it twice.
  const deliverTask = (): void => {
    if (!TASK_FILE) return;
    const marker = join(dirname(TASK_FILE), "delivered");
    if (existsSync(marker)) return;
    let task = "";
    try {
      task = readFileSync(TASK_FILE, "utf8");
      writeFileSync(marker, "");
    } catch {
      // no marker written, so a later /reload gets another try
    }
    if (!task.trim()) return;
    deliver(task);
    // deliver() is not work beginning: it hands pi a message and returns,
    // and everything that follows is pi's. So the clock goes on here,
    // after deliver's own workStarted has cleared it - a child that gets
    // as far as a turn clears it again within milliseconds (agent_start),
    // and one that never does is collected by the shutdown path every
    // other ending already takes.
    awaitingFirstWork = true;
    armIdleExit(() => ctxShutdown?.());
  };

  // scheduleWindowLinger spawns the detached linger helper: sleep, then
  // `kido close-run`, as its own process since this one's event loop is
  // gone by the time the sleep fires. The helper is given this session's
  // window and collects the run's own pane in it, closing the window when
  // that pane is all it has. windowID and kido's path are passed as sh's
  // $0/$1 so neither needs shell-quoting.
  const scheduleWindowLinger = (windowID: string): void => {
    const host = status();
    const kido = host?.kidoPath();
    if (!host || !kido) return;
    host.spawnDetached("sh", ["-c", `sleep ${LINGER_SECONDS} && exec "$0" close-run "$1"`, kido, windowID]);
  };

  // isRunEnding tells a shutdown that ends the run apart from one that
  // rebuilds the extension runtime in the same process. pi fires
  // session_shutdown for five reasons ("quit", "reload", "new", "resume",
  // "fork"); only "quit" ends the run. An absent reason is a quit: that
  // is what every pi too old to send one meant by it.
  const isRunEnding = (reason?: string): boolean => reason === undefined || reason === "quit";

  // endOwnRun does the two things that happen exactly once, when this
  // process's own run actually ends: record how it ended, and schedule
  // its window's linger. One function because they share one gate, asked
  // once here rather than twice - is this process the run's own child
  // (ownRunID), can kido be reached at all, and is this shutdown the run
  // ending rather than a /reload rebuilding the extension runtime in the
  // same process. The last part is not pedantry: an outcome is O_EXCL, so
  // a reload recording "completed" leaves the run's real ending
  // unrecordable, and an ungated linger, measured against pi 0.85.1,
  // closed a live subagent's window out from under it ~30s after a
  // /reload. What this session has to say about its work is still
  // notify_parent's alone, on the model's own judgement (docs/design.md,
  // "Notifying the parent"); --unreported claims nothing about the work
  // and only asks kido to tell the parent that the run ended with nothing
  // said about it, which is what an idle self-exit or a crash used to
  // leave a waiting parent to guess at.
  const endOwnRun = async (reason?: string): Promise<void> => {
    const host = status();
    const runID = ownRunID();
    if (!runID || !host?.kidoPath() || !isRunEnding(reason)) return;
    // The run id is this session's id verbatim; "idle" is the only status
    // a turn finishes on, so anything else at shutdown is a failure - and
    // so is a session still waiting for its first turn, which reports
    // idle and has done nothing at all.
    const result = host.status() === "idle" && !awaitingFirstWork ? "completed" : "failed";
    const args = ["run-outcome", "--result", result];
    if (!reportedToParent) args.push("--unreported");
    if (awaitingFirstWork) args.push("--text", NO_FIRST_TURN_TEXT);
    else if (lastTurnError) args.push("--text", `its last turn failed: ${trimErrorMessage(lastTurnError)}`);
    await host.runKido([...args, "--", runID], { timeoutMs: 3000 });
    const listed = await fetchAgents();
    if ("error" in listed) return;
    const self = listed.agents.find((a) => a.self);
    if (self?.window) scheduleWindowLinger(self.window);
  };

  // Published at factory time, with nothing read back until an event
  // fires, so load order does not matter.
  const hooks: AgentHooks = {
    sessionStarting(ctx: SessionContext) {
      ctxAbort = async () => {
        await ctx.abort();
      };
      ctxShutdown = () => ctx.shutdown();
      // A /reload's fresh ctx has already had pi clear the previous
      // widgets out from under it (resetExtensionUI); drop our own record
      // of what was pending so a later renderNoticeWidget call does not
      // resurrect rows for notices this session no longer remembers.
      pendingNotices.clear();
      clearStreamTimer();
      streamBuffers.clear();
      streamDelay = STREAM_FLUSH_MS;
    },
    async sessionStarted(ctx: SessionContext) {
      startParentLivenessPoll(ctx.shutdown);
      deliverTask();
    },
    inboxLost: abandonPending,
    async sessionEnding(reason?: string) {
      // This prefix runs before the first await, in the same uninterrupted
      // stretch as the status half's stopInbox (see ask_agent's inboxOpen
      // check). abandonPending runs on every reason, reload included: a
      // reload still tears the inbox down.
      stopParentLivenessPoll();
      clearIdleExit();
      clearStreamTimer();
      abandonPending();
      await endOwnRun(reason);
    },
    turnEnded() {
      armIdleExit(() => ctxShutdown?.());
    },
    // Any sign of work stops the clock and settles what this session's
    // ending will be called: it got as far as working. clearIdleExit
    // alone does not, since a shutdown clears the timer too and must
    // leave that judgement as it found it.
    workStarted,
    handleEnvelope,
  };
  seam().agents = hooks;
}
