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
 *   force?)` and `notify_parent(summary)` all shell out to a kido
 *   subcommand, asynchronously. They register unconditionally at factory
 *   time and no-op at call time until session_start has resolved kido and a
 *   session id, since pi may run the factory in invocations that never
 *   start a session. ask_agent waits here, in the extension, because only a
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
import type { AgentHooks, Envelope, Seam, SessionContext, StatusHost } from "./kido-status.ts";

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
// generated, comes from the host instead.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_INSTANCE = process.env.KIDO_AGENT_PARENT_INSTANCE || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// What set_status's schema tells the model; the enforced cap is
// kido-status.ts's own.
const MAX_ACTIVITY_BYTES = 256;

// notify_parent's own cap, matching kido-status.ts's former MAX_RESULT_BYTES
// (the automatic notice's own bound, before this tool replaced it): bigger
// than the activity cap, since this is a work product and not a UI label,
// but far smaller than MAX_PROMPT_BYTES, since it is spliced whole into the
// parent's next turn as a followUp message. Enforced here, not just in the
// schema, the same way set_status enforces MAX_ACTIVITY_BYTES itself: a
// model is free to ignore what the schema merely asks for.
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

// The task text `kido spawn` left for us to deliver as our first message.
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
// plumbed through as KIDO_AGENT_KEEP_ALIVE by kido spawn --keep-alive).
const KEEP_ALIVE = process.env.KIDO_AGENT_KEEP_ALIVE === "1";

// How long spawn_subagent waits for `kido spawn` before treating it as hung.
const SPAWN_TIMEOUT_MS = Number(process.env.KIDO_SPAWN_TIMEOUT_MS) || 5000;

// How long stop_subagent waits for `kido stop`. kido stop can itself
// block for stopEscalation (cmd/kido/control.go, default 5s), so this
// must comfortably exceed that.
const STOP_TIMEOUT_MS = Number(process.env.KIDO_STOP_TIMEOUT_MS) || 8000;

// ask_agent's default wait: a full turn of the target's latency, not a
// round-trip.
const DEFAULT_ASK_TIMEOUT_MS = 5 * 60 * 1000;

// The custom message type an inbound notice is delivered as, matched by
// registerMessageRenderer below.
const NOTICE_CUSTOM_TYPE = "kido-notice";

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

// AgentInfo mirrors cmd/kido/agents.go's AgentInfo, what `kido agents
// --json` prints. Only the fields read here are declared.
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
}

// resolveAgent applies the same addressing rules kido message's
// resolveTarget (cmd/kido/message.go) does: an exact, case-insensitive
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

export default function (pi: ExtensionAPI) {
  let parentPollTimer: NodeJS.Timeout | null = null;

  // How an inbound "interrupt"/"stop" envelope reaches pi: captured in
  // sessionStarting, null until a session has started.
  let ctxAbort: (() => void) | null = null;
  let ctxShutdown: (() => void) | null = null;

  // How a waiting ask_agent ends. "The answer never came" and "there is
  // no longer anywhere for it to come to" are different things to tell a
  // model: only the first leaves an id a late reply can be surfaced
  // against.
  type AskOutcome =
    | { reply: string }
    | { gaveUp: "timeout" | "inbox" | "unsent" };

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
  // inbox prompt are all the same kind of arrival.
  const deliver = (text: string): void => {
    status()?.deliver(text);
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
  // when it ran `kido message --kind notice` instead of the default
  // `--kind message`, and `from` is advisory anyway (docs/design.md, the
  // inbox), so nothing here does a lookup to decide. deliverAs is
  // unconditionally "followUp" and triggerTurn is true for the same
  // reason kido-status.ts's own deliver() sends every prompt as a
  // followUp: an idle parent must still be woken by a notice exactly as
  // it was when this arrived as a plain user message.
  const deliverNotice = (text: string, from: string): void => {
    clearIdleExit();
    pi.sendMessage(
      { customType: NOTICE_CUSTOM_TYPE, content: text, display: true, details: { from } },
      { deliverAs: "followUp", triggerTurn: true },
    );
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
  // while every pane is already in `kido agents --json`. Entries are
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

  // handleInboundControl answers an "interrupt" or "stop" envelope, but
  // only for a sender that is one of this session's ancestors or a human
  // at the CLI. Defence in depth: kido enforces the same rule before
  // sending, but `from` is advisory (docs/design.md, "Interrupt and
  // stop").
  const handleInboundControl = async (env: Envelope, kind: "interrupt" | "stop"): Promise<"ok" | "refused"> => {
    const listed = await fetchAgents();
    if ("error" in listed) return "refused";
    const self = listed.agents.find((a) => a.self);
    if (!self) return "refused";
    // A human has no state record, so kido puts no session in `from`;
    // recognised by the pair, so an agent has to get two things wrong at
    // once to be mistaken for one.
    const fromIsHuman = !env.from.session && !listed.agents.some((a) => a.pane === env.from.pane);
    if (!fromIsHuman) {
      const from = listed.agents.find((a) => a.id === env.from.session);
      if (!from || !isAncestor(listed.agents, from, self)) return "refused";
    }
    if (kind === "interrupt") {
      ctxAbort?.();
    } else {
      ctxShutdown?.();
    }
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
        if (env.text) deliverNotice(env.text, labelFrom(env.from));
        return "ok";
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
    const res = await host.runKido(["agents", "--json"], { timeoutMs: 2000 });
    if ("error" in res) return res;
    try {
      return { agents: res.out ? JSON.parse(res.out) : [] };
    } catch (err) {
      return { error: err instanceof Error ? err.message : String(err) };
    }
  };

  // missedParentPolls counts consecutive polls where the pid check was
  // ambiguous (kill(pid, 0) succeeded or came back EPERM - a live pid
  // proves nothing by itself, since a pid can be recycled by an unrelated
  // process) and the registry, successfully queried, found no live record
  // for this session's own parent. The primary fix for the actual incident
  // this guards against - a /reload's record briefly disappearing and
  // reappearing - lives on the parent side (kido-status.ts's
  // session_shutdown no longer removes the record on "reload", and its
  // INSTANCE now survives a reload instead of being regenerated); this
  // debounce is defence in depth on top of that fix, not a substitute for
  // it, for any other momentary gap in the parent's own record that isn't
  // a reload. It is deliberately small: two consecutive misses, ~10s at
  // the default poll interval, is enough to absorb a single missed read
  // without meaningfully delaying a real orphan's cleanup.
  let missedParentPolls = 0;
  const CONSECUTIVE_MISSES_REQUIRED = 2;

  // parentIsAlive: kill(pid, 0) first, where ESRCH is a definite "gone" -
  // answered without a subprocess, and never debounced, so keepAlive gives
  // no protection against a genuinely dead parent. Success or EPERM is not
  // proof of life (a pid can be recycled), so anything else defers to
  // whether this session's own `parent` still resolves in kido agents,
  // and only after CONSECUTIVE_MISSES_REQUIRED polls in a row agree there
  // is none - a single missed poll is inconclusive, not evidence.
  const parentIsAlive = async (): Promise<boolean> => {
    if (PARENT_PID === undefined) return true;
    try {
      process.kill(PARENT_PID, 0);
    } catch (err) {
      if ((err as NodeJS.ErrnoException)?.code === "ESRCH") return false;
    }
    const listed = await fetchAgents();
    if ("error" in listed) return true; // kido being unavailable is not evidence; never shut down on a guess, and not a miss either
    const self = listed.agents.find((a) => a.self);
    if (self?.parent) {
      missedParentPolls = 0;
      return true;
    }
    missedParentPolls++;
    return missedParentPolls < CONSECUTIVE_MISSES_REQUIRED;
  };

  // Idempotent: a /reload re-runs session_start and must not pile up a
  // second timer. Unref'd so it never holds the event loop open.
  // pollInFlight stops a tick from starting a second parentIsAlive() call
  // while the previous one is still awaiting its subprocess round trip:
  // setInterval fires on schedule regardless of whether its callback's own
  // async work has finished, so a poll slower than PARENT_LIVENESS_POLL_MS
  // (a loaded machine, a slow kido invocation) could otherwise overlap two
  // or more calls into one real gap - each completing and incrementing
  // missedParentPolls on its own, which would let a single transient gap
  // reach the two-poll threshold faster than the debounce is meant to
  // allow. Skipping the tick instead just delays the next real reading;
  // it never suppresses one.
  let pollInFlight = false;

  const startParentLivenessPoll = (shutdown: () => void): void => {
    if (PARENT_PID === undefined) return;
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
    missedParentPolls = 0;
    pollInFlight = false;
  };

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
  // than fetchAgents, since kido agents --json carries no focus field.
  const windowFocused = async (windowID: string): Promise<boolean> => {
    const host = status();
    if (!host?.kidoPath()) return false; // no kido, no way to check; do not block on a guess either way
    const res = await host.runKido(["window-focused", windowID], { timeoutMs: 2000 });
    return "out" in res && res.out.trim() === "true";
  };

  // armIdleExit starts (or restarts) the idle-to-self-shutdown clock. Only
  // a child arms it (PARENT_INSTANCE set, exactly as notify_parent's own
  // refusal check), and only when it has not opted out with keepAlive. Unref'd so
  // it can never hold the process alive on its own, the same as the
  // parent-liveness poll.
  const armIdleExit = (shutdown: () => void): void => {
    if (PARENT_INSTANCE === undefined || KEEP_ALIVE) return;
    clearIdleExit();
    idleExitTimer = setTimeout(async () => {
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
      activity: Type.String({
        description: 'What you are doing right now ("refactoring internal/ui"), or "" to clear it. Capped at 256 bytes.',
        maxLength: MAX_ACTIVITY_BYTES,
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
    description:
      "Send a message to another agent in this tmux session, addressed by name, session id, or a unique id prefix.",
    promptSnippet: "message_agent(to, message, replyTo?) - send a message to another agent in this tmux session",
    parameters: messageAgentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot message other agents" }], details: {} };
      }
      const args = ["message"];
      // A reply is correlated on kind "reply", not on --reply-to alone.
      if (params.replyTo) args.push("--kind", "reply", "--reply-to", params.replyTo);
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
      // kido message says whether it delivered by inbox or pasted.
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
      "Ask another agent a question and block until it replies. Refused for an ancestor, a target outside this tmux session, one with no inbox, or yourself.",
    promptSnippet: "ask_agent(to, question, timeoutMs?) - ask another agent a question and wait for its reply",
    parameters: askAgentParams,
    async execute(_toolCallId, params) {
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

      // kido agents --json is already scoped to this tmux session, so a
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
      const reply = new Promise<AskOutcome>((resolve) => {
        deliverReply = resolve;
      });
      const settle = (outcome: AskOutcome): void => {
        clearTimeout(timer);
        pendingOutbound.delete(id);
        deliverReply(outcome);
      };
      const timer = setTimeout(() => settle({ gaveUp: "timeout" }), timeoutMs);
      timer.unref(); // a wait must never hold pi's event loop open
      pendingOutbound.set(id, { targetSession: target.id, settle });

      // target.id, not params.to: passing the resolved id removes a second
      // resolution inside kido message that could disagree with this one.
      const sent = await host.runKido(["message", "--kind", "ask", "--id", id, "--", target.id], {
        input: params.question,
        timeoutMs: 5000,
      });
      if ("error" in sent) {
        settle({ gaveUp: "unsent" });
        return { content: [{ type: "text", text: `could not ask ${params.to}: ${sent.error}` }], details: {} };
      }

      const outcome = await reply;
      if ("reply" in outcome) {
        return { content: [{ type: "text", text: outcome.reply }], details: {} };
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
      task: Type.String({ description: "The task to give the new subagent, delivered as its first message." }),
      name: Type.Optional(
        Type.String({ description: "A name for the subagent's window and session; a name is generated when omitted." }),
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
    },
    { additionalProperties: false },
  );
  const spawnSubagentTool: ToolDefinition<typeof spawnSubagentParams> = {
    name: "spawn_subagent",
    label: "Spawn Subagent",
    description:
      "Create a subagent in its own tmux window with a task. Returns its identity immediately without waiting for it to finish.",
    promptSnippet: "spawn_subagent(task, name?, model?, tools?) - delegate a task to a new subagent in its own window",
    parameters: spawnSubagentParams,
    async execute(_toolCallId, params) {
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot spawn a subagent" }], details: {} };
      }
      const depth = (DEPTH ?? 0) + 1;
      if (depth > MAX_SPAWN_DEPTH) {
        return {
          content: [{ type: "text", text: `already at the maximum subagent nesting depth (${MAX_SPAWN_DEPTH}); cannot spawn another` }],
          details: {},
        };
      }
      const name = params.name || safeSubagentName();

      // Spelled once for both: pi's own --model/--tools constrain the
      // child, kido spawn's identically named pair goes in the run record.
      const modelAndTools = [
        ...(params.model ? ["--model", params.model] : []),
        ...(params.tools && params.tools.length > 0 ? ["--tools", params.tools.join(",")] : []),
      ];
      const child = ["pi", "--name", name, ...modelAndTools];
      const keepAliveArgs = params.keepAlive ? ["--keep-alive"] : [];

      // The task goes to kido spawn as text on stdin; kido decides it
      // becomes a file.
      const res = await host.runKido(
        [
          "spawn",
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
          "--",
          ...child,
        ],
        { input: params.task, timeoutMs: SPAWN_TIMEOUT_MS },
      );
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not spawn subagent: ${res.error}` }], details: {} };
      }
      const [windowID, paneID, runID] = res.out.split(/\s+/);
      return {
        content: [{ type: "text", text: `spawned ${name} (window ${windowID}, pane ${paneID}, run ${runID})` }],
        details: { name, window: windowID, pane: paneID, run: runID },
      };
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
      const res = await host.runKido(["interrupt", "--", params.to], { timeoutMs: 5000 });
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
      const args = ["stop"];
      if (params.force) args.push("--force");
      args.push("--", params.to);
      const res = await host.runKido(args, { timeoutMs: STOP_TIMEOUT_MS });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not stop ${params.to}: ${res.error}` }], details: {} };
      }
      return { content: [{ type: "text", text: res.out || `stopped ${params.to}` }], details: {} };
    },
  };

  const notifyParentParams = Type.Object(
    {
      summary: Type.String({
        description: `A short summary of the finished work to send to your parent. Capped at ${MAX_NOTICE_BYTES} bytes.`,
        maxLength: MAX_NOTICE_BYTES,
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
      // a root session (a human's own interactive pi) has no parent to
      // tell, ever, so this must read as a clear refusal rather than the
      // same silent no-op every other tool gives an unavailable kido.
      if (PARENT_INSTANCE === undefined) {
        return { content: [{ type: "text", text: "this session has no parent (it was not spawned as a subagent); notify_parent has nobody to tell" }], details: {} };
      }
      const host = status();
      if (!host?.kidoPath()) {
        return { content: [{ type: "text", text: "kido is not available; cannot notify the parent" }], details: {} };
      }
      const listed = await fetchAgents();
      if ("error" in listed) {
        return { content: [{ type: "text", text: `could not list agents: ${listed.error}` }], details: {} };
      }
      const self = listed.agents.find((a) => a.self);
      if (!self || !self.parent) {
        return { content: [{ type: "text", text: "could not resolve this session's parent; nothing sent" }], details: {} };
      }
      const text = capBytes(params.summary, MAX_NOTICE_BYTES);
      const res = await host.runKido(["message", "--kind", "notice", "--", self.parent], { input: text, timeoutMs: 5000 });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not notify parent: ${res.error}` }], details: {} };
      }
      return { content: [{ type: "text", text: res.out || "notified parent" }], details: {} };
    },
  };

  pi.registerTool(listAgentsTool);
  pi.registerTool(setStatusTool);
  pi.registerTool(messageAgentTool);
  pi.registerTool(askAgentTool);
  pi.registerTool(spawnSubagentTool);
  pi.registerTool(interruptSubagentTool);
  pi.registerTool(stopSubagentTool);
  pi.registerTool(notifyParentTool);

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
    if (!options.expanded) {
      const line = theme.fg("dim", `notification from ${from} — ctrl-o to expand`);
      return { render: () => [line] };
    }
    const content = typeof message.content === "string" ? message.content : "";
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
    if (PARENT_INSTANCE === undefined) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${NOTIFY_PARENT_INSTRUCTION}` };
  });

  // deliverTask hands the model the task kido spawn left for us, the same
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

  // recordOwnOutcome tells kido how this run ended: the session id is the
  // run id verbatim, "idle" is the only status a turn finishes on, and
  // anything else at shutdown is failed. Gated on isRunEnding: an outcome
  // is O_EXCL, so a reload recording "completed" would leave the run's
  // real ending unrecordable.
  const recordOwnOutcome = async (reason?: string): Promise<void> => {
    const host = status();
    const sessionId = host?.sessionId();
    if (!host?.kidoPath() || !sessionId || PARENT_INSTANCE === undefined) return; // not a subagent
    if (!isRunEnding(reason)) return;
    const result = host.status() === "idle" ? "completed" : "failed";
    await host.runKido(["run-outcome", "--result", result, "--", sessionId], { timeoutMs: 3000 });
  };

  // scheduleCompletionLinger schedules this session's own window's
  // linger once the run has actually ended. Gated on isRunEnding like
  // recordOwnOutcome: an ungated /reload, measured against pi 0.85.1,
  // closed a live subagent's window out from under it. Renamed from
  // sendCompletionNotice - the run's ending is no longer automatically
  // reported to the parent at all (docs/design.md, "Notifying the
  // parent"; a subagent calls notify_parent itself, on its own
  // judgement), so only the window-lifecycle half of that function's job
  // remains here.
  const scheduleCompletionLinger = async (reason?: string): Promise<void> => {
    const host = status();
    if (!host?.kidoPath() || PARENT_INSTANCE === undefined) return; // not a subagent
    if (!isRunEnding(reason)) return;
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
      abandonPending();
      await recordOwnOutcome(reason);
      await scheduleCompletionLinger(reason);
    },
    turnEnded() {
      armIdleExit(() => ctxShutdown?.());
    },
    workStarted: clearIdleExit,
    handleEnvelope,
  };
  seam().agents = hooks;
}
