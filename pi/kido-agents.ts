/**
 * kido-agents — let a pi session see, message and delegate to the other
 * agents in its tmux session.
 *
 * This is the agent-coordination half of kido's pi support; the other half,
 * kido-status.ts, reports this session's status to kido's sidebar and owns
 * the inbox socket. The two are separate extensions because they are
 * separate jobs: a session that only wants to be visible in the sidebar
 * needs nothing here, and everything here needs kido on PATH and a tmux
 * session full of other agents. They meet at the seam kido-status.ts
 * documents - this file publishes its hooks there and reads back the one
 * session's inbox and status report, neither of which may be duplicated.
 * Nothing but types is imported from it, deliberately: pi evaluates each
 * extension separately, so an ordinary import would load a second copy
 * rather than reach the one pi started. Install them together (see
 * pi/README.md); this half alone registers its tools but reports kido as
 * unavailable from all of them.
 *
 * Tools:
 *   `list_agents()`, `set_status(activity)`, `message_agent(to, message,
 *   replyTo?)`, `ask_agent(to, question, timeoutMs?)`, `spawn_subagent(task,
 *   name?, model?, tools?)`, `interrupt_subagent(to)` and `stop_subagent(to,
 *   force?)` all shell out to kido (`kido agents --json`, `kido agent-status
 *   --activity`, `kido message [--kind K] [--reply-to] [--id] <to>`, `kido
 *   spawn ...`, `kido interrupt <to>`, `kido stop <to> [--force]`) the same
 *   way status reporting does, asynchronously so a slow or hung kido cannot
 *   block this process's event loop - notably its own inbox, which must stay
 *   able to accept a connection while a tool call is in flight. They register
 *   unconditionally at factory time - before session_start has resolved
 *   kido or a session id - and simply no-op at call time until those are
 *   known, since pi may run the factory in invocations that never start a
 *   session. What message_agent accepts and how kido resolves it is in
 *   pi/README.md.
 *
 *   interrupt_subagent aborts a descendant's current turn (ctx.abort()) and
 *   stop_subagent ends its session outright, escalating to killing its
 *   window if it does not respond within a few seconds - see
 *   docs/subagents-plan.md's "Interrupting and stopping a subagent"
 *   section. Both are refused for anything but a descendant, enforced both
 *   by kido (before an envelope is ever sent) and again here on receipt,
 *   since `from` is advisory.
 *
 *   spawn_subagent passes its task to `kido spawn` as text on stdin
 *   (--task-file -) and returns the run id as soon as kido has created the
 *   child's window - it does not wait for the child to start, let alone
 *   finish. kido decides the task becomes a file, inside a durable run
 *   record under kido's own state directory (docs/subagents-plan.md's
 *   Phase 8 section); the child reads it (named in $KIDO_AGENT_TASK_FILE)
 *   on session_start and delivers it as its first message. When it
 *   eventually shuts down it records its own outcome (`kido run-outcome`)
 *   and tells its parent with a `notice` envelope, dropped silently if the
 *   parent is gone. See docs/subagents-plan.md's Spawning and Phase 8
 *   sections.
 *
 *   There is deliberately no `kido ask` CLI twin. ask_agent blocks the
 *   calling tool until a reply arrives on this session's own inbox, and
 *   only a long-lived process has an inbox to receive one on - a `kido ask`
 *   subprocess would exit before any answer could reach it. So the wait
 *   lives here, in the extension: ask_agent sends the question with `kido
 *   message --kind ask`, exactly as message_agent sends a message, and then
 *   waits in this process for a matching `reply` envelope (see
 *   handleInboundReply below).
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

// The seam kido-status.ts documents: two slots on globalThis, reached by
// a global-registry symbol, declared identically on both sides. It is
// spelled out again here rather than imported because importing anything
// with a runtime value from kido-status.ts would evaluate a second copy
// of that file - pi gives each extension its own module registry, which
// is exactly the trap this arrangement exists to avoid.
const SEAM = Symbol.for("kido.pi.extension.seam");

function seam(): Seam {
  const g = globalThis as unknown as Record<symbol, Seam | undefined>;
  return (g[SEAM] ??= { host: null, agents: null });
}

// The status half, or null when it is not loaded - reported to the model
// the same way a missing kido binary is. Read at call time, never at
// factory time: pi may run this factory first.
function status(): StatusHost | null {
  return seam().host;
}

// The same three environment values kido-status.ts reads for its status
// report, read again here rather than shared across the seam: they are
// constants of this process, so two readers cannot disagree. The one
// identity that is *generated* rather than read - the instance id - comes
// from the host instead, since a second copy of it would be a second id.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_INSTANCE = process.env.KIDO_AGENT_PARENT_INSTANCE || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// What set_status's schema tells the model. The cap that is actually
// enforced is kido-status.ts's own, applied by setActivity when the text
// arrives - a model is free to ignore a schema.
const MAX_ACTIVITY_BYTES = 256;

// The task text `kido spawn` left for us to deliver as our first message
// (see docs/subagents-plan.md's Spawning section). Read once, in
// sessionStarted below.
const TASK_FILE = process.env.KIDO_AGENT_TASK_FILE || undefined;

// decision 5 in docs/subagents-plan.md: root 0 -> subagent 1 -> subagent
// 2. spawnCmd (cmd/kido/spawn.go) is the actual ceiling; this is only a
// cheap early refusal that skips writing a task file and a subprocess for
// a spawn that kido would refuse anyway.
const MAX_SPAWN_DEPTH = 2;

// LINGER_SECONDS is how long a finished subagent's window stays open
// before the linger helper (see scheduleWindowLinger below) may close it,
// so the user has time to read its last screen
// (docs/subagents-plan.md's Lifecycle section). A package variable, like
// SPAWN_TIMEOUT_MS, set only via the environment since it is read once at
// module scope and a test needs to shorten it rather than wait out a real
// 30s.
//
// kido's own sweep (reap.Grace, internal/reap) reads the same variable,
// and must: the sweep is what closes this window when the helper never
// runs or finds the user reading it, and a sweep with a shorter idea of
// the linger than the helper's would simply close it first.
const LINGER_SECONDS = Number(process.env.KIDO_LINGER_SECONDS) || 30;

// PARENT_LIVENESS_POLL_MS is how often a subagent checks whether its
// parent is still around: its pi is a child of the tmux server, not of
// the parent's own pi, so no OS parent-death signal ever reaches it (see
// docs/subagents-plan.md's Lifecycle section). Also a package variable
// for the same reason as LINGER_SECONDS.
const PARENT_LIVENESS_POLL_MS = Number(process.env.KIDO_PARENT_POLL_MS) || 5000;

// How long spawn_subagent waits for `kido spawn` before treating it as
// hung. A package variable, like inboxTimeout on the Go side, so a test
// can shorten it rather than actually waiting out a real 5s to exercise
// the timeout branch - set only via the environment, since this is read
// once at module scope and the test suite reimports the module to pick up
// a fresh value.
const SPAWN_TIMEOUT_MS = Number(process.env.KIDO_SPAWN_TIMEOUT_MS) || 5000;

// How long stop_subagent waits for `kido stop` before treating it as
// hung. kido stop can itself block for stopEscalation
// (cmd/kido/control.go, default 5s) waiting for a wedged target to go
// before it kills the window, so this must comfortably exceed that
// default rather than race it.
const STOP_TIMEOUT_MS = Number(process.env.KIDO_STOP_TIMEOUT_MS) || 8000;

// ask_agent's default wait, if the caller does not give timeoutMs: long
// enough that a target mid-task has a real chance to finish its turn and
// reply (see the plan's "expect one full turn of latency, not a
// round-trip").
const DEFAULT_ASK_TIMEOUT_MS = 5 * 60 * 1000;

// AgentInfo mirrors cmd/kido/agents.go's AgentInfo, what `kido agents
// --json` and list_agents print. Only the fields ask_agent needs to
// resolve and check a target are read here.
interface AgentInfo {
  id: string;
  name: string;
  parent: string;
  // The tmux pane the session reported itself in. Read only by
  // handleInboundControl, to tell an envelope a person typed from one an
  // agent sent: kido fills `from` from the calling process's own record,
  // so a sender naming no session and sitting in a pane no agent
  // occupies has no record, which is exactly what "a human at the CLI"
  // means on the sending side too (cmd/kido/control.go's isAgent).
  pane: string;
  self: boolean;
  canMessage: boolean;
  window: string;
  // stalled and sinceReport mirror cmd/kido/agents.go's AgentInfo:
  // sinceReport is seconds since the session's last report, and stalled
  // is kido's own derived guess that a session reporting Running has gone
  // quiet long enough to be wedged rather than merely busy
  // (state.Stalled). ask_agent refuses a stalled target immediately
  // rather than waiting out its own timeout against something that is
  // never going to answer.
  stalled: boolean;
  sinceReport: number;
}

// resolveAgent applies the same addressing rules kido message's
// resolveTarget (cmd/kido/message.go) does, over the agents ask_agent
// already fetched: an exact, case-insensitive name, then an exact id, then
// a unique id prefix - each erroring on its own ambiguity rather than
// falling through to guess with a different rule.
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

// isAncestor walks target's ancestor chain (via each agent's reported
// parent id) looking for self, i.e. reports whether self is an ancestor of
// target - the shape ask_agent needs to refuse "to is an ancestor" (decision
// 1 in docs/subagents-plan.md): the parent must stay free to orchestrate,
// so a child may not block it with a question. seen guards a corrupt or
// cyclic parent chain from looping forever; buildAgents (cmd/kido/agents.go)
// has the same concern on the reporting side.
export function isAncestor(agents: AgentInfo[], self: AgentInfo, target: AgentInfo): boolean {
  // Refused outright rather than walked for: a record whose own `parent`
  // named itself would otherwise make this true (the walk starts at
  // target's parent, which would be itself, and the first comparison
  // matches). Nothing writes such a record today - see the matching
  // comment on isAncestor in cmd/kido/agents.go, which this mirrors - so
  // this is a belt-and-braces refusal for corrupted state, not a case
  // kido produces.
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
  // parentPollTimer is the parent-liveness poll started by
  // startParentLivenessPoll below; null when this is a root session, or
  // once stopParentLivenessPoll has run.
  let parentPollTimer: NodeJS.Timeout | null = null;

  // ctxAbort and ctxShutdown are how an inbound "interrupt"/"stop"
  // envelope reaches pi: captured once, in sessionStarting, from the ctx
  // every lifecycle handler already receives (ctx.shutdown is the same
  // reference startParentLivenessPoll below is given). Null until a
  // session has actually started, the same window every other tool call
  // here has to tolerate.
  let ctxAbort: (() => void) | null = null;
  let ctxShutdown: (() => void) | null = null;

  // How a waiting ask_agent ends. Three outcomes rather than two,
  // because "the answer never came" and "there is no longer anywhere for
  // it to come to" are different things to tell a model: only the first
  // is a timeout it might sensibly wait out again, and only the first
  // leaves an id a late reply can still be surfaced against.
  type AskOutcome =
    | { reply: string }
    | { gaveUp: "timeout" | "inbox" | "unsent" };

  // Asks this session has sent and is still waiting on an answer for,
  // keyed by the ask's own id. ask_agent registers a waiter here just
  // before sending and awaits it; whichever comes first - a matching
  // reply, its own timeout, or the inbox going away under it - settles
  // the waiter and drops it, so no two paths can disagree about who
  // cleans up. The id stays meaningful after a timeout: a reply that
  // names it later has nothing to resolve, and per the plan's delivery
  // semantics is surfaced as an ordinary message rather than dropped
  // (see handleInboundReply).
  //
  // This map, not any count kept beside it, is also the cycle-refusal
  // edge set (hasAskOutstandingTo below) - which needs an argument now
  // that runKido no longer blocks the event loop: while `await
  // runKido([...])` is pending in ask_agent below, this process is free to
  // dispatch an inbound ask from the very target that send is addressed
  // to, before the send's own kido subprocess has exited.
  //
  // It is still correct, because the write to this map
  // (`pendingOutbound.set`, in ask_agent below) happens synchronously,
  // before the `await` that starts the send - JS gives that whole
  // synchronous prefix of an async function to run without yielding, so
  // nothing else can observe the waiter as absent once ask_agent has been
  // called. Any inbound ask arriving while the send is still in flight
  // therefore already sees the edge. The reverse race - the outbound
  // send's own "could not deliver" branch calling settle({gaveUp:
  // "unsent"}) after a reply has already raced in and settled the same
  // waiter - is harmless because settle is idempotent: it clears an
  // already-cleared timer, deletes an already-deleted map entry, and
  // resolves an already-resolved promise, all no-ops. See the
  // "interleaving" test in kido-status.test.ts, which exercises the first
  // half of this argument against a real socket rather than just arguing
  // it in prose.
  const pendingOutbound = new Map<string, { targetSession: string; settle: (outcome: AskOutcome) => void }>();

  // abandonPending releases every waiting ask because this session's
  // inbox has gone away: a reply has nowhere left to land, so a waiter
  // left in place would sit out its whole timeout - five minutes, by
  // default - on a socket nobody is listening to, and hold its cycle
  // edge shut for just as long.
  //
  // Deliberately not called from kido-status.ts's own stopInbox. Only its
  // callers know whether the inbox is coming back: session_start's
  // /reload path tears it down and immediately rebinds at the same
  // pid-named path, and a wait genuinely survives that, so abandoning
  // there would throw away an ask that was about to be answered. The
  // inboxLost hook is the case where it is not coming back.
  //
  // Iterated over a copy, since settle deletes from the map it walks.
  const abandonPending = (): void => {
    for (const waiter of [...pendingOutbound.values()]) waiter.settle({ gaveUp: "inbox" });
  };

  // The in-memory cycle-refusal state from AGENTS.md's Cycles section,
  // read off the waiters themselves rather than tallied beside them: an
  // edge to a target exists exactly as long as an ask to it is waiting,
  // so there is no second count that could fall out of step. The rule
  // that a *failed* reply must not release the edge then falls out of
  // dispatch: only a correlated resolve or ask_agent's own timeout drops
  // a waiter, never a reply-shaped envelope that matched nothing (see
  // handleInboundReply).
  const hasAskOutstandingTo = (session: string): boolean => {
    if (!session) return false;
    for (const waiter of pendingOutbound.values()) {
      if (waiter.targetSession === session) return true;
    }
    return false;
  };

  // Delivery to the model goes through the status half, which owns the
  // pi session this text is being injected into: a task, an ask and a
  // plain inbox prompt are all the same kind of arrival, and there is no
  // reason for two extensions to have two ideas of how one is delivered.
  const deliver = (text: string): void => {
    status()?.deliver(text);
  };

  // labelFrom names an envelope's sender for the model to read: its
  // reported name, else its session id, else its pane - the same fallback
  // order targetLabel (cmd/kido/message.go) uses on the sending side.
  const labelFrom = (from: Envelope["from"]): string => from.name || from.session || from.pane || "another agent";

  // handleInboundAsk delivers an ask received from another agent to the
  // model, with an explicit instruction that a reply is expected, unless
  // doing so would close a cycle: if this session is
  // itself holding an ask outstanding to the same sender, answering "ok"
  // here would leave both sides waiting on each other forever, so it is
  // refused on the wire instead (see AGENTS.md's Cycles section). A
  // refusal is not delivered to the model at all - there is nothing for it
  // to act on, and the asker's own kido message reports the refusal.
  const handleInboundAsk = (env: Envelope): "ok" | "refused" => {
    if (hasAskOutstandingTo(env.from.session)) return "refused";
    const from = labelFrom(env.from);
    deliver(
      `${from} is asking (id ${env.id}): ${env.text}\n\n` +
        `Reply with message_agent(to=${JSON.stringify(from)}, message=<answer>, replyTo=${JSON.stringify(env.id)}).`,
    );
    return "ok";
  };

  // handleInboundReply resolves a waiting ask_agent when its id matches a
  // pending outbound ask. If none matches - the asker already gave up and
  // timed out, or the id is stale or foreign - the answer must still reach
  // the model rather than be dropped silently, per the plan's delivery
  // semantics, so it is delivered as an ordinary message instead.
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

  // handleInboundControl answers an "interrupt" or "stop" envelope:
  // aborting the current turn or ending the session outright, but only
  // for a sender this session can verify is one of its own ancestors
  // (isAncestor, walking the same parent chain ask_agent's own ancestor
  // check does, in the opposite direction - a caller may only reach its
  // descendants, see AGENTS.md and docs/subagents-plan.md's Cycles
  // section for the sibling rule this mirrors). Refused on the wire
  // otherwise, the same "refused" answer a cycle refusal already uses:
  // the wire only ever means "read, and deliberately declined", not
  // specifically about asks.
  //
  // This is defence in depth, not the primary guard: kido interrupt/stop
  // (cmd/kido/control.go) already enforce the same rule before an
  // envelope is ever sent, using kido's own view of the spawn tree rather
  // than trusting the sender's own agents list. A session that receives
  // one anyway - through a bypassed CLI, or kido's and this session's
  // views of the tree having briefly diverged - must not act on it just
  // because it arrived.
  const handleInboundControl = async (env: Envelope, kind: "interrupt" | "stop"): Promise<"ok" | "refused"> => {
    const listed = await fetchAgents();
    if ("error" in listed) return "refused";
    const self = listed.agents.find((a) => a.self);
    if (!self) return "refused";
    // A human at the CLI may act on anything (docs/subagents-plan.md's
    // Scope section), and cmd/kido/control.go lets one through on exactly
    // this basis - it has no state record, so there is no descendant rule
    // to apply to it. That caller also has no session id for kido to put
    // in `from`, so without this the two enforcement layers disagree
    // precisely where the plan is most explicit, and a person's `kido
    // stop` is refused by the session it named. Recognised by the pair
    // rather than the empty session alone, so a confused agent has to get
    // two things wrong at once to be mistaken for a person; `from` stays
    // advisory either way, and this is defence in depth, not a boundary.
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
  // the wire answer: "ok" for everything except a refused ask or control
  // message. Every branch delivers something to the model rather than
  // dropping it - the plan is explicit that a message must never be lost,
  // even one whose kind nobody recognises, since a typo'd kind is exactly
  // the case where silence would be most misleading. Raw v0 text never
  // gets here: kido-status.ts delivers that itself.
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
        if (env.text) deliver(`[notice from ${labelFrom(env.from)}] ${env.text}`);
        return "ok";
      case "interrupt":
      case "stop":
        return handleInboundControl(env, env.kind);
      default:
        // An unrecognised kind (a future kido, or a typo) still reaches
        // the model, marked as such, rather than being read as an
        // ordinary message with no sign anything was off.
        if (env.text) {
          deliver(`[unrecognised message kind ${JSON.stringify(env.kind)} from ${labelFrom(env.from)}] ${env.text}`);
        }
        return "ok";
    }
  };

  // Both list_agents and ask_agent need the same list, read the same way -
  // and kido printing something unparseable is the same kind of failure to
  // them as kido not running at all, so it comes back as one.
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

  // parentIsAlive answers the parent-liveness poll's one question. A raw
  // kill(pid, 0) is checked first: ESRCH is a definite "gone", answered
  // without a kido subprocess. Anything else - the call succeeding, or
  // throwing EPERM for a pid owned by someone else - is not proof of life
  // by itself: state.Alive (internal/state, see AGENTS.md) reports EPERM
  // as alive for the same reason, and a pid can be reused by an unrelated
  // process either way. What actually tells a live parent from a process
  // that merely reused its pid is the Instance match `kido agents --json`
  // already computes for list_agents' own `parent` field (parentID,
  // cmd/kido/agents.go): if this session's own entry there still resolves
  // a parent at all, some live record in scope reports
  // KIDO_AGENT_PARENT_INSTANCE as its own Instance, which a recycled pid
  // cannot fake.
  const parentIsAlive = async (): Promise<boolean> => {
    if (PARENT_PID === undefined) return true; // a root session has no parent to lose
    try {
      process.kill(PARENT_PID, 0);
    } catch (err) {
      if ((err as NodeJS.ErrnoException)?.code === "ESRCH") return false;
      // EPERM or anything else is not proof of death; fall through to the
      // Instance check below.
    }
    const listed = await fetchAgents();
    if ("error" in listed) return true; // kido being unavailable is not evidence of anything; never shut down on a guess
    const self = listed.agents.find((a) => a.self);
    return !!self?.parent;
  };

  // startParentLivenessPoll begins the poll (docs/subagents-plan.md's
  // Lifecycle section) for a subagent; a root session (no PARENT_PID) is
  // never polled. Idempotent: a /reload re-runs session_start, and the
  // old timer is stopped first rather than left to pile up a second one.
  // The timer is unref'd so a hung or slow parent check never holds this
  // process's event loop open on its own.
  const startParentLivenessPoll = (shutdown: () => void): void => {
    if (PARENT_PID === undefined) return;
    stopParentLivenessPoll();
    parentPollTimer = setInterval(() => {
      parentIsAlive().then((alive) => {
        if (alive) return;
        // Stop first: the verdict cannot change back, and a shutdown that
        // takes longer than one interval would otherwise be asked for
        // again on every tick until the process actually goes.
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
      // Any failure reads as an empty session rather than an error: there
      // is nothing the model can do about it, and "[]" is honest about
      // what it now knows.
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
      // The activity belongs to the status report - it joins the
      // coalescing key and is carried forward by kido - so setting it is
      // one call into the status half, which caps it and re-reports.
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
      // replyTo answers a pending ask, so it must travel as kind "reply" -
      // that is what a receiver's handleInboundReply correlates on, not
      // the presence of --reply-to alone (kido message rejects --reply-to
      // on any other kind).
      if (params.replyTo) args.push("--kind", "reply", "--reply-to", params.replyTo);
      // "--" first: to is model-authored, and one beginning with a dash
      // would otherwise be parsed as a kido flag and reported as "flag
      // provided but not defined" rather than as no such agent.
      args.push("--", params.to);
      const res = await host.runKido(args, { input: params.message, timeoutMs: 5000 });
      if ("error" in res) {
        return { content: [{ type: "text", text: `could not message ${params.to}: ${res.error}` }], details: {} };
      }
      // kido message prints one line saying what actually happened -
      // delivered by inbox, or pasted into the target's pane - which is
      // exactly what the model needs to know, not just "ok".
      return {
        content: [{ type: "text", text: res.out || `message delivered to ${params.to}` }],
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

      // "not in the session" needs no separate check: kido agents --json is
      // already scoped to this tmux session, so a target outside it simply
      // does not resolve here.
      const { agent: target, error } = resolveAgent(agents, params.to);
      if (!target) {
        return { content: [{ type: "text", text: `could not ask ${params.to}: ${error}` }], details: {} };
      }
      if (target.id === self.id) {
        return { content: [{ type: "text", text: "cannot ask yourself" }], details: {} };
      }
      if (isAncestor(agents, self, target)) {
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
      // Fail fast rather than wait out the default five-minute timeout
      // against a target that is never going to answer: kido has already
      // computed this from how long it has been since the target's last
      // status report (state.Stalled), so it costs nothing extra here.
      if (target.stalled) {
        return {
          content: [{
            type: "text",
            text: `${target.name || target.id} has been quiet for ${target.sinceReport}s while reporting running; likely stalled, refusing to wait for a reply`,
          }],
          details: {},
        };
      }

      // The inbox may have gone away - session_shutdown, or a /reload whose
      // rebind failed - while the fetchAgents() call above was still in
      // flight: that fetch is now async, so this function can be suspended
      // right through a teardown that runs its own abandonPending (which
      // can only abandon waiters already in pendingOutbound) before
      // resuming here. Checked synchronously, with no await between the
      // check and pendingOutbound.set below, so there is no further gap
      // for abandonPending to miss: either this runs before that
      // teardown's synchronous prefix (inbox closed, abandonPending
      // called) and the waiter it registers is caught by that
      // abandonPending call, or it runs after and sees the closed inbox
      // already in place. A closed inbox is the whole test: a shutdown
      // closes it before its first await, so there is no moment at which
      // this session is on its way out but still looks open. A
      // momentarily-closed inbox during a reload that goes on to rebind
      // successfully is refused the same conservative way - nothing here
      // knows the rebind will succeed, and it is safer to refuse an ask
      // than to register a waiter that might sit past a shutdown nobody
      // told it about.
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

      // One waiter, settled by whoever gets there first: the correlated
      // reply with its text, the timer, a send that never got off the
      // ground, or abandonPending when the inbox goes away underneath it.
      // settle drops the waiter and cancels the timer itself, so no path
      // carries cleanup of its own to forget, and dropping the waiter is
      // also what releases this session's cycle edge to the target (see
      // hasAskOutstandingTo). Registered before the send, so a reply
      // cannot race past it.
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

      // target.id, not params.to: resolveAgent already resolved to, and a
      // second resolution inside kido message runs a different rule
      // (matchTarget in cmd/kido/message.go) that can disagree with this
      // one, per AGENTS.md's addressing-mismatch defect. Passing the id
      // already settled on removes the second resolution instead of
      // hoping the two rules keep agreeing.
      const sent = await host.runKido(["message", "--kind", "ask", "--id", id, "--", target.id], {
        input: params.question,
        timeoutMs: 5000,
      });
      if ("error" in sent) {
        settle({ gaveUp: "unsent" }); // nothing is coming; do not hold the edge or the timer
        return { content: [{ type: "text", text: `could not ask ${params.to}: ${sent.error}` }], details: {} };
      }

      const outcome = await reply;
      if ("reply" in outcome) {
        return { content: [{ type: "text", text: outcome.reply }], details: {} };
      }
      if (outcome.gaveUp === "inbox") {
        // The inbox this answer would have arrived on is gone, so unlike a
        // timeout there is no later delivery to promise: say so rather
        // than report a wait that never actually ran out.
        return {
          content: [{
            type: "text",
            text: `this session's inbox closed before ${params.to} answered (ask id ${id}); no reply can reach it now, so ask again if the answer still matters`,
          }],
          details: {},
        };
      }
      // Gave up waiting, but the id stays a valid correlation: with no
      // waiter left, a reply that eventually names it is surfaced as a
      // plain message instead of resolving anything (handleInboundReply).
      return {
        content: [{
          type: "text",
          text: `no reply from ${params.to} within ${timeoutMs}ms (ask id ${id}); a later reply naming this id will still arrive as a message`,
        }],
        details: {},
      };
    },
  };

  // safeSubagentName generates a name when spawn_subagent's caller does
  // not give one: spawnCmd (cmd/kido/spawn.go) puts it on a tmux command
  // line, so it must avoid the same characters tmuxConfUnsafe rejects
  // there - trivially true of hex, but stated so nobody "improves" this
  // into something that reads better and stops being safe.
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

      // The same two flags twice over, deliberately spelled once: pi's own
      // --model/--tools are what actually constrain the child, and kido
      // spawn's identically named pair is what puts them in the run record
      // for `kido runs` to show. They must not be able to disagree.
      const modelAndTools = [
        ...(params.model ? ["--model", params.model] : []),
        ...(params.tools && params.tools.length > 0 ? ["--tools", params.tools.join(",")] : []),
      ];
      const child = ["pi", "--name", name, ...modelAndTools];

      // The task is model-authored, arbitrary text - never a command-line
      // argument, for the same reason kido spawn itself insists on a file
      // (see AGENTS.md and docs/subagents-plan.md's Spawning section). It
      // used to be this tool's own job to put it in one (a temp file it
      // then had to clean up on every exit path); now it is handed to kido
      // spawn as text on stdin (--task-file -), and kido decides it becomes
      // a file, inside the run's own directory - the file-vs-content
      // decision the plan's "Deferred: subagents off this machine" section
      // says belongs to kido, not to this tool, so another backend can put
      // it somewhere else entirely.
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

  pi.registerTool(listAgentsTool);
  pi.registerTool(setStatusTool);
  pi.registerTool(messageAgentTool);
  pi.registerTool(askAgentTool);
  pi.registerTool(spawnSubagentTool);
  pi.registerTool(interruptSubagentTool);
  pi.registerTool(stopSubagentTool);

  // deliverTask hands the model the task kido spawn left for us, the same
  // way an inbox prompt is delivered - a subagent's first turn should read
  // exactly like one handed to it by another agent, not like a special
  // case. A missing or unreadable file (no task, wrong permissions,
  // someone already cleaned it up) is silently nothing to deliver, never a
  // reason to fail startup.
  //
  // A /reload re-runs session_start, and this must not deliver the task a
  // second time - but the file itself is no longer the signal that decides
  // that (docs/subagents-plan.md's Phase 8 section): it now lives in the
  // run's own directory (kido runs <run-id> reads it back later), so
  // unlinking it after delivery, as an earlier version did, would destroy
  // the one copy of what this run was asked to do. A sibling "delivered"
  // marker file is the signal instead - written only once the read has
  // actually succeeded, so a task that failed to read (permissions, a race
  // with something still writing it) is still eligible on the next /reload
  // rather than being marked delivered and then never shown to the model
  // at all.
  const deliverTask = (): void => {
    if (!TASK_FILE) return;
    const marker = join(dirname(TASK_FILE), "delivered");
    if (existsSync(marker)) return;
    let task = "";
    try {
      task = readFileSync(TASK_FILE, "utf8");
      writeFileSync(marker, "");
    } catch {
      // no task file, or it could not be read - nothing to deliver,
      // and no marker written, so a later /reload gets another try
    }
    if (task.trim()) deliver(task);
  };

  // scheduleWindowLinger spawns the detached helper
  // docs/subagents-plan.md's Lifecycle section describes: sleep, then
  // `kido close-window`, run as its own process so it survives this one's
  // exit - this process's own event loop is gone by the time the sleep
  // would otherwise have to fire. windowID and kido's own path are passed
  // as sh's $0/$1 rather than interpolated into the script text, so
  // neither needs shell-quoting.
  const scheduleWindowLinger = (windowID: string): void => {
    const host = status();
    const kido = host?.kidoPath();
    if (!host || !kido) return;
    host.spawnDetached("sh", ["-c", `sleep ${LINGER_SECONDS} && exec "$0" close-window "$1"`, kido, windowID]);
  };

  // isRunEnding tells a shutdown that actually ends the run apart from
  // one that merely tears the extension runtime down and immediately
  // rebuilds it in the same process, agent still on screen and still in
  // kido agents. pi fires session_shutdown for five different reasons
  // ("quit", "reload", "new", "resume", "fork"); only "quit" is this run
  // ending. An absent reason is treated as a quit, since that is what
  // every pi too old to send one meant by it - a fake session_shutdown in
  // this file's own tests carries no reason, and so does every pi release
  // this was written against before reason existed.
  const isRunEnding = (reason?: string): boolean => reason === undefined || reason === "quit";

  // recordOwnOutcome tells kido how this run ended, the same moment - and
  // gated the same way - sendCompletionNotice tells the parent. The
  // session id is the run id verbatim (cmd/kido/spawn.go passes
  // --session-id <run-id> when it launches a "pi" command), so there is
  // nothing to look up. "idle" is the only status a normally finished turn
  // ends on (agent_settled's own check, in kido-status.ts); anything else
  // at shutdown - waiting, compacting, still running - means this session
  // did not get to finish on its own terms, so it is recorded as failed
  // rather than guessed at more finely than kido can actually tell from
  // the outside.
  //
  // A /reload recording "completed" would be wrong twice over - it
  // reports a live run as finished, and because RecordOutcome is O_EXCL
  // and first-writer-wins permanently (internal/subrun), the run's real
  // ending could then never be recorded at all: a kido stop an hour later
  // would be silently discarded.
  const recordOwnOutcome = async (reason?: string): Promise<void> => {
    const host = status();
    const sessionId = host?.sessionId();
    if (!host?.kidoPath() || !sessionId || PARENT_INSTANCE === undefined) return; // not a subagent
    if (!isRunEnding(reason)) return; // a reload or a session replacement, not an ending
    const result = host.status() === "idle" ? "completed" : "failed";
    await host.runKido(["run-outcome", "--result", result, "--", sessionId], { timeoutMs: 3000 });
  };

  // sendCompletionNotice tells this session's parent, if it has one and
  // kido still knows where it is, that this subagent is finishing, and
  // schedules its own window's linger close. Only ever called from the
  // sessionEnding hook, before kido-status.ts's removal report:
  // list_agents/kido agents must still resolve this session's own parent
  // edge (self.parent) and its own window while it does, which needs this
  // session's own record to still exist.
  //
  // Gated on isRunEnding the same way recordOwnOutcome is: a /reload is
  // not this subagent finishing, so it must neither tell the parent it
  // did nor schedule its own window to be closed out from under it 30s
  // later. Measured against a real pi 0.85.1 subagent: an ungated
  // /reload left a live subagent's window closed and its parent told the
  // child had finished, and left an orphaned `sh -c sleep ...` helper
  // behind for every reload on top of the one from the real ending.
  //
  // Once past that gate, the linger is scheduled whenever this is a
  // subagent at all, whether or not its parent edge still resolves - an
  // orphaned subagent's window still deserves the same 30s read window as
  // one whose parent is still there to be told. A dead or unreachable
  // parent for the notice itself - kido message failing however it
  // fails, errInboxUnavailable or otherwise - is exactly the case
  // docs/subagents-plan.md means by "nobody to tell": there is no
  // distinct handling for it, the result is simply dropped, same as any
  // other runKido failure here. Nothing in this function may throw past
  // its own await, or a subagent's shutdown would fail on account of a
  // parent that already exited.
  const sendCompletionNotice = async (reason?: string): Promise<void> => {
    const host = status();
    if (!host?.kidoPath() || PARENT_INSTANCE === undefined) return; // not a subagent
    if (!isRunEnding(reason)) return; // a reload or a session replacement, not this subagent finishing
    const listed = await fetchAgents();
    if ("error" in listed) return;
    const self = listed.agents.find((a) => a.self);
    if (self?.window) scheduleWindowLinger(self.window);
    if (!self || !self.parent) return; // kido no longer has a parent edge for this session
    const title = host.title();
    const activity = host.activity();
    const text = `${title || "subagent"} finished` + (activity ? `: ${activity}` : "") + ` (${host.status()})`;
    await host.runKido(["message", "--kind", "notice", "--", self.parent], { input: text, timeoutMs: 3000 });
  };

  // The handshake with kido-status.ts (see the seam note there). Published
  // at factory time, with nothing read back until an event fires, so it
  // does not matter which of the two extensions pi loads first.
  const hooks: AgentHooks = {
    sessionStarting(ctx: SessionContext) {
      // A /reload re-runs session_start with a fresh ctx, and the old
      // reference must not survive it.
      ctxAbort = () => ctx.abort();
      ctxShutdown = () => ctx.shutdown();
    },
    async sessionStarted(ctx: SessionContext) {
      // A session switch or /reload re-runs this; started fresh so a
      // /reload never leaves two timers running (see
      // startParentLivenessPoll).
      startParentLivenessPoll(ctx.shutdown);
      deliverTask();
    },
    inboxLost: abandonPending,
    async sessionEnding(reason?: string) {
      // This prefix runs before the first await, so it happens in the
      // same uninterrupted stretch as the status half's own stopInbox -
      // which is what lets ask_agent's inboxOpen() check stand in for
      // "this session is shutting down".
      stopParentLivenessPoll();
      // Nothing is coming back this time, so no ask may be left waiting on
      // it - a tool call blocked on a five-minute timer is the last thing a
      // session on its way out should be holding. This runs on every reason,
      // reload included: a reload still tears the inbox down, so a pending
      // ask must still be released even though the run itself is not ending.
      abandonPending();
      await recordOwnOutcome(reason);
      await sendCompletionNotice(reason);
    },
    handleEnvelope,
  };
  seam().agents = hooks;
}
