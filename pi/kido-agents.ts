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
// agent's record, scheduled `kido close-window` on the real agent's
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

// The custom message type an inbound notice is delivered as, matched by
// registerMessageRenderer below.
const NOTICE_CUSTOM_TYPE = "kido-notice";

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

// AgentInfo mirrors cmd/kido/list_agents.go's AgentInfo, what `kido
// list_agents --json` prints. Only the fields read here are declared.
interface AgentInfo {
  id: string;
  name: string;
  parent: string;
  pane: string;
  self: boolean;
  canMessage: boolean;
  window: string;
  stalled: boolean;
  sinceReport: number;
  // Instance is what `kido agent-alive` matches on; empty for an agent
  // that never reported one, which canMessage rules out.
  instance?: string;
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

export default function (pi: ExtensionAPI) {
  let parentPollTimer: NodeJS.Timeout | null = null;

  // How an inbound "interrupt"/"stop" envelope reaches pi: captured in
  // sessionStarting, null until a session has started.
  let ctxAbort: (() => void) | null = null;
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
  const deliverNotice = (text: string, from: string): void => {
    clearIdleExit();
    const noticeId = randomUUID();
    pendingNotices.set(noticeId, from);
    renderNoticeWidget();
    pi.sendMessage(
      { customType: NOTICE_CUSTOM_TYPE, content: text, display: true, details: { from, noticeId } },
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
  const handleInboundAsk = (env: Envelope): "ok" | "refused" => {
    if (hasAskOutstandingTo(env.from.session)) return "refused";
    const from = labelFrom(env.from);
    if (env.from.pane) pendingInboundAsks.set(env.id, env.from.pane);
    deliver(
      `${from} is asking (id ${env.id}): ${env.text}\n\n` +
        `${from} cannot see this session's context, so make the answer self-contained. ` +
        `Reply with message_agent(to=${JSON.stringify(from)}, message=<answer>, replyTo=${JSON.stringify(env.id)}). ${STOP_AFTER_ASK_REPLY}`,
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
      ctxAbort?.();
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
        if (env.text) deliver(env.text);
        return "ok";
      case "ask":
        return handleInboundAsk(env);
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

  // idleExitTimer is the idle self-exit clock: armed on every settled turn
  // (turnEnded), cleared by any sign of new work (workStarted). Only a
  // child arms it at all (see armIdleExit's own gate).
  let idleExitTimer: NodeJS.Timeout | null = null;

  const clearIdleExit = (): void => {
    if (idleExitTimer) {
      clearTimeout(idleExitTimer);
      idleExitTimer = null;
    }
  };

  // windowFocused asks kido whether this session's own window is the one
  // some client is currently looking at - the same test close-window and
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
      shutdown();
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
    promptSnippet: "set_status(activity) - tell kido's sidebar what you are doing",
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
      "Ask another agent a question and block until it replies - one full turn of the target's latency, not a round-trip, since a busy target does not see the question until it would otherwise have stopped. Refused for an ancestor, a target outside this tmux session, one with no inbox, or yourself.",
    promptSnippet: "ask_agent(to, question, timeoutMs?) - ask another agent a question and wait for its reply",
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
            "The task to give the new subagent, delivered as its first message. Required unless resume is given - a resumed run keeps its own original task and refuses a new one.",
        }),
      ),
      name: Type.Optional(
        Type.String({
          description:
            "A name for the subagent's window and session; a name is generated when omitted. Refused together with resume - a resumed run keeps its original window name.",
        }),
      ),
      model: Type.Optional(Type.String({ description: "Model for the subagent to run." })),
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
      "Create a subagent in its own tmux window with a task, or resume a dead or finished one by its run id. With fork: true it starts holding this session's context, for a judgement step that has to know what was already decided. Returns its identity immediately without waiting for it to finish.",
    promptSnippet:
      "spawn_subagent(task, name?, model?, tools?, keepAlive?, fork?) or spawn_subagent(resume, model?, tools?, keepAlive?) - delegate a task to a new subagent, optionally forked from your own context, or resume a dead one, in its own window",
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
        return {
          content: [{ type: "text", text: `resumed ${runID} (window ${windowID}, pane ${paneID})` }],
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
          text: `spawned ${name} (window ${windowID}, pane ${paneID}, run ${runID})${params.fork ? ", forked from this session's context" : ""}`,
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
      "Run a shell command in the background instead of waiting on it, so this session can keep working while it runs. This replaces polling: exactly one notice arrives when the command ends, carrying its exit status and a tail of its output. Read the output file with the ordinary read tool at any time before then to check on progress. With stream=true the output also arrives in batches as it runs - between your own tool calls while you are working, on a slowing schedule when you are idle, capped per batch and per run, so some lines are only ever in the file, which always has all of them.",
    promptSnippet:
      "async_bash(command, name?) - run a command in the background; a notice with its exit status arrives when it ends, read the output file meanwhile",
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
            `a notice with its exit status and a tail of its output arrives when it ends - ` +
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
  pi.on("session_start", (_event: unknown, ctx: { ui?: typeof widgetUi }) => {
    widgetUi = ctx.ui ?? null;
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
    const content = typeof message.content === "string" ? message.content : "";
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

  // notifyParentInstruction rides on every turn, not just the first, since
  // a delivered task is a one-shot user message and a subagent's later
  // follow-up turns (a parent's own message_agent call, say) have no other
  // memory of "tell your parent when you're done". pi resets to the base
  // system prompt whenever no handler returns one, so this must return it
  // on every call, not only once.
  pi.on("before_agent_start", (event) => {
    if (!isSubagent()) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${NOTIFY_PARENT_INSTRUCTION}` };
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
    if (task.trim()) deliver(task);
  };

  // scheduleWindowLinger spawns the detached linger helper: sleep, then
  // `kido close-window`, as its own process since this one's event loop
  // is gone by the time the sleep fires. windowID and kido's path are
  // passed as sh's $0/$1 so neither needs shell-quoting.
  const scheduleWindowLinger = (windowID: string): void => {
    const host = status();
    const kido = host?.kidoPath();
    if (!host || !kido) return;
    host.spawnDetached("sh", ["-c", `sleep ${LINGER_SECONDS} && exec "$0" close-window "$1"`, kido, windowID]);
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
    // a turn finishes on, so anything else at shutdown is a failure.
    const result = host.status() === "idle" ? "completed" : "failed";
    const args = ["run-outcome", "--result", result];
    if (!reportedToParent) args.push("--unreported");
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
      ctxAbort = () => ctx.abort();
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
    workStarted: clearIdleExit,
    handleEnvelope,
  };
  seam().agents = hooks;
}
