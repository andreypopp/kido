/**
 * kido-status — report this pi session's live status to kido, and accept
 * prompts delivered from outside the session.
 *
 * kido is a tmux sidebar that shows the live status of coding agents. This
 * extension makes a pi session visible in that sidebar by shelling out to:
 *
 *   kido agent-status --agent pi --session <id> --status running|waiting|compacting|idle
 *                     [--title <text>] [--activity <text>] [--model <name>]
 *                     [--instance <id>] [--parent-pid <pid>] [--parent-instance <id>]
 *                     [--depth <n>] [--ended] [--remove]
 *                     [--inbox <path>] [--protocol <n>]
 *
 * kido reads $TMUX_PANE from the environment, so the command must be spawned
 * from inside the pi process (which lives in the tmux pane).
 *
 * --instance is a random id generated once for this process (module scope,
 * not per session) and reported on every call, so a parent edge survives a
 * session id change under /resume or /reload. --parent-pid and
 * --parent-instance, when set, name the process that spawned this one -
 * read once from KIDO_AGENT_PARENT_PID and KIDO_AGENT_PARENT_INSTANCE,
 * which `kido spawn` sets in a subagent's environment (see
 * docs/subagents-plan.md); absent for a root session.
 *
 * Behaviour:
 *   - If `kido` is not on PATH, or pi is not running inside tmux, the extension
 *     does nothing at all, quietly.
 *   - Every invocation is fire-and-forget (detached, stdio ignored). Failures
 *     never propagate into pi and never print to the TUI.
 *   - Status changes are coalesced: kido is only invoked when the reported
 *     status/title/activity actually differs from what was last sent.
 *
 * Tools:
 *   `list_agents()`, `set_status(activity)`, `message_agent(to, message,
 *   replyTo?)`, `ask_agent(to, question, timeoutMs?)` and `spawn_subagent(task,
 *   name?, model?, tools?)` all shell out to kido (`kido agents --json`,
 *   `kido agent-status --activity`, `kido message [--kind K] [--reply-to]
 *   [--id] <to>`, `kido spawn ...`) the same way status reporting does,
 *   asynchronously so a slow or hung kido cannot block this process's
 *   event loop - notably its own inbox, which must stay able to accept a
 *   connection while a tool call is in flight. They register
 *   unconditionally at factory time - before session_start has resolved
 *   kido or a session id - and simply no-op at call time until those are
 *   known, since pi may run the factory in invocations that never start a
 *   session. What message_agent accepts and how kido resolves it is in
 *   pi/README.md.
 *
 *   spawn_subagent writes its task to a temp file and returns as soon as
 *   `kido spawn` has created the child's window - it does not wait for the
 *   child to start, let alone finish. The child reads its task file (named
 *   in $KIDO_AGENT_TASK_FILE) on session_start, delivers it as its first
 *   message, and unlinks it; when it eventually shuts down it tells its
 *   parent with a `notice` envelope, dropped silently if the parent is
 *   gone. See docs/subagents-plan.md's Spawning section.
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
 * Inbox:
 *   On session start the extension asks kido where to bind — `kido inbox-path
 *   <pid>` prints an absolute socket path, creating its directory, and fails if
 *   the path would be too long — binds a unix STREAM socket there and reports
 *   the path once, with `--inbox <path> --protocol <n>` on the first status
 *   report; kido carries both values forward. A client writes a prompt as
 *   UTF-8 with no framing, half-closes its write half, reads `ok\n` (or
 *   `refused\n` for an ask this session has declined - see the Cycles note
 *   on handleInboundAsk) and closes. The payload is either raw v0 text or a
 *   v1 JSON envelope (kido's own inbox protocol - see internal/msg and
 *   AGENTS.md); either way the text ends up delivered as a real user
 *   message, dispatched by envelope kind (see handleInbound). Any failure
 *   here is silent and leaves status reporting working.
 *
 * Install:
 *   mkdir -p ~/.pi/agent/extensions
 *   cp kido-status.ts ~/.pi/agent/extensions/
 *
 * Or, for a one-off run:  pi -e /path/to/kido-status.ts
 */

import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, constants, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { delimiter, isAbsolute, join } from "node:path";
import { Type } from "typebox";

// Generated once per process, not per session: it identifies this pi
// process to kido (see state.Session.Instance), and a session switch or
// /reload must not change it out from under a child that already recorded
// it as a ParentInstance.
const INSTANCE = randomUUID();

// A subagent's kido-status runs as a plain pi process spawned by `kido
// spawn` (see docs/subagents-plan.md), which sets these in its environment.
// Absent for a root session.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_INSTANCE = process.env.KIDO_AGENT_PARENT_INSTANCE || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// The task text `kido spawn` left for us to deliver as our first message
// (see docs/subagents-plan.md's Spawning section). Read once, in
// session_start, and unlinked there - a /reload re-runs session_start, and
// by then the file is already gone, so it is never delivered twice.
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
// once at module scope and freshKidoStatus() in the test suite reimports
// the module to pick up a fresh value.
const SPAWN_TIMEOUT_MS = Number(process.env.KIDO_SPAWN_TIMEOUT_MS) || 5000;

// Cap for set_status's free text. The JSON schema says 256 too, but a
// model is free to ignore it, and the sidebar has one row to draw this in.
const MAX_ACTIVITY_BYTES = 256;

// Cut on a code-point boundary, never mid-sequence: decoding a buffer that
// splits one leaves a U+FFFD behind, which is both mojibake and *three*
// bytes, so a naive byte slice can come back longer than the cap it was
// enforcing (258 bytes for a cap of 256, given three-byte characters).
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

type Status = "running" | "waiting" | "compacting" | "idle";

// RunKidoResult's error branch carries timedOut so a caller can tell a
// definite failure (kido ran and said so, or never started) apart from a
// run that was still in flight when this process gave up waiting on it.
type RunKidoResult = { out: string } | { error: string; timedOut?: boolean };

// Anything larger than this is dropped rather than buffered.
const MAX_PROMPT_BYTES = 1024 * 1024;

// The inbox envelope version this extension speaks (see internal/msg and
// AGENTS.md's note on the protocol). Reported with --protocol alongside
// --inbox so kido only ever sends an envelope to a receiver that has said
// it understands one.
const PROTOCOL_VERSION = 1;

// ask_agent's default wait, if the caller does not give timeoutMs: long
// enough that a target mid-task has a real chance to finish its turn and
// reply (see the plan's "expect one full turn of latency, not a
// round-trip").
const DEFAULT_ASK_TIMEOUT_MS = 5 * 60 * 1000;

type EnvelopeKind = "message" | "ask" | "reply" | "notice";

interface Envelope {
  v: number;
  kind: EnvelopeKind;
  id: string;
  from: { session: string; name?: string; pane?: string };
  replyTo?: string;
  text: string;
}

// AgentInfo mirrors cmd/kido/agents.go's AgentInfo, what `kido agents
// --json` and list_agents print. Only the fields ask_agent needs to
// resolve and check a target are read here.
interface AgentInfo {
  id: string;
  name: string;
  parent: string;
  self: boolean;
  canMessage: boolean;
  window: string;
}

// parseEnvelope mirrors internal/msg.Parse: a payload counts as a v1
// envelope only if it parses as a JSON object and carries both "v" and
// "kind" - not just "looks like JSON". Anything else, including a JSON
// object missing one of those keys, is v0 raw prompt text, so a user
// prompt that happens to be a JSON object is never swallowed as a control
// message.
export function parseEnvelope(text: string): Envelope | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  const obj = parsed as Record<string, unknown>;
  if (!("v" in obj) || !("kind" in obj)) return null;
  // Text is coerced rather than required, so that what counts as an
  // envelope stays exactly what msg.Parse counts as one: Go reads a
  // missing "text" as the zero string, and a cast here would instead hand
  // pi.sendUserMessage an undefined it is not typed to take. An envelope
  // with nothing to say is dropped at the delivery site.
  const body = typeof obj.text === "string" ? obj.text : "";
  return { ...obj, text: body } as unknown as Envelope;
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
    } catch {
      // keep looking
    }
  }
  return null;
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
  let kido: string | null = null;
  let sessionId: string | null = null;
  let title: string | undefined;
  let activity = "";
  let model: string | undefined;
  let lastKey: string | null = null;
  let current: Status = "idle";
  let beforeCompact: Status = "idle";

  let inbox: Server | null = null;
  let inboxPath: string | null = null;
  let inboxReported = false;

  // parentPollTimer is the parent-liveness poll started by
  // startParentLivenessPoll below; null when this is a root session, or
  // once stopParentLivenessPoll has run.
  let parentPollTimer: NodeJS.Timeout | null = null;

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
  // Deliberately not called from stopInbox itself. Only stopInbox's
  // callers know whether the inbox is coming back: session_start's
  // /reload path tears it down and immediately rebinds at the same
  // pid-named path, and a wait genuinely survives that, so abandoning
  // there would throw away an ask that was about to be answered.
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

  const deliver = (text: string): void => {
    // Unconditionally "followUp", idle or not. The docs say of sendUserMessage
    // that "When not streaming, the message is sent immediately and triggers a
    // new turn" — `deliverAs` is only consulted while streaming, where
    // "followUp" "[w]aits for agent to finish all tools". That is exactly what
    // an externally injected prompt should do: queue behind work the user is
    // watching, rather than redirect the running turn the way "steer" would.
    // One call covers both cases and leaves no window between a check and a
    // send in which a turn could start.
    pi.sendUserMessage(text, { deliverAs: "followUp" });
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

  // handleInbound dispatches one inbox payload by envelope kind and
  // returns the wire answer: "ok" for everything except a refused ask.
  // Every branch delivers something to the model rather than dropping it -
  // the plan is explicit that a message must never be lost, even one whose
  // kind nobody recognises, since a typo'd kind is exactly the case where
  // silence would be most misleading.
  const handleInbound = (prompt: string): "ok" | "refused" => {
    const env = parseEnvelope(prompt);
    if (!env) {
      // v0 raw text: delivered exactly as it always has been.
      if (prompt) deliver(prompt);
      return "ok";
    }
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
    // The client half-closes after writing; "end" is the whole message.
    sock.on("end", () => {
      if (dropped) return;
      // Concatenate before decoding: a multi-byte char can straddle chunks.
      const text = Buffer.concat(chunks).toString("utf8");
      const prompt = text.trim();
      // Decided (and any delivery or refusal done) before the socket is
      // closed: the caller's kido message reads the answer to tell a
      // refusal from an ordinary delivery.
      const response = prompt ? handleInbound(prompt) : "ok";
      try {
        sock.end(response + "\n");
      } catch {
        // client may already be gone
      }
    });
  };

  const stopInbox = (): void => {
    const server = inbox;
    const path = inboxPath;
    inbox = null;
    inboxPath = null;
    inboxReported = false;
    if (server) {
      try {
        server.close();
      } catch {
        // already closed
      }
    }
    if (path) {
      try {
        unlinkSync(path);
      } catch {
        // already gone
      }
    }
  };

  const startInbox = async (): Promise<void> => {
    // Where to bind is kido's decision, not ours: it owns the
    // state-directory precedence and the sun_path length budget, and exits
    // non-zero when the path would not fit or the name is bad - then we
    // simply run without an inbox. The name is this process's pid, which
    // is unique among live processes by construction: a leftover file at
    // that path cannot belong to a running listener, so it is always safe
    // to remove — no liveness probe needed.
    const asked = await runKido(["inbox-path", String(process.pid)], { timeoutMs: 2000 });
    if ("error" in asked) return;
    const path = asked.out;
    if (!path || !isAbsolute(path)) return;
    try {
      unlinkSync(path);
    } catch {
      // nothing there
    }
    const server = createServer({ allowHalfOpen: true }, onConnection);
    server.on("error", () => {});
    const bound = await new Promise<boolean>((resolve) => {
      server.once("error", () => resolve(false));
      server.listen(path, () => resolve(true));
    });
    if (!bound) return; // never publish a path we are not listening on
    server.unref(); // never hold pi's event loop open
    inbox = server;
    inboxPath = path;
    inboxReported = false;
  };

  // spawnDetached runs one fire-and-forget child: detached and
  // stdio-ignored, so a Ctrl+C on pi's process group does not kill it and
  // it outlives this process entirely - which is what a status report
  // racing pi's exit and a linger helper that must sleep past it both
  // need. Both failure paths are swallowed, the synchronous throw and the
  // async "error" event; the latter is not optional, an unhandled one is
  // an uncaught exception on this process rather than a failed spawn.
  const spawnDetached = (cmd: string, args: string[]): void => {
    try {
      const child = spawn(cmd, args, { stdio: "ignore", detached: true });
      child.on("error", () => {});
      child.unref();
    } catch {
      // never let a spawn failure reach pi
    }
  };

  // Fire-and-forget. Coalesced: identical consecutive reports are dropped.
  const send = (
    status: Status,
    opts: { ended?: boolean; remove?: boolean } = {},
  ): void => {
    if (!kido || !sessionId) return;

    // activity and model join the key: without them, set_status or a
    // model switch that leaves the status unchanged would look like an
    // identical report and be dropped, and the sidebar would never see it.
    const key = [status, title ?? "", activity, model ?? "", opts.ended ? 1 : 0, opts.remove ? 1 : 0].join("|");
    // The one report that carries --inbox must never be coalesced away:
    // session_start awaits the socket bind, and another handler can send an
    // equivalent "idle" report inside that window, which would make the
    // session_start report look like a duplicate — and kido would never learn
    // the socket path. So bypass coalescing while the path is unreported;
    // afterwards identical statuses coalesce exactly as before.
    const pendingInbox = inboxPath !== null && !inboxReported;
    if (!pendingInbox && key === lastKey) return;
    lastKey = key;
    current = status;

    const args = [
      "agent-status",
      "--agent",
      "pi",
      "--session",
      sessionId,
      "--status",
      status,
      // Always sent, so that set_status("") reaches kido as the explicit
      // empty value that clears it rather than as an omission kido would
      // carry the old text forward across.
      "--activity",
      activity,
      // Reported fresh on every call, from this process's own identity and
      // environment - not carried forward, unlike --title and --activity.
      "--instance",
      INSTANCE,
    ];
    if (title) args.push("--title", title);
    if (model) args.push("--model", model);
    if (PARENT_PID !== undefined) args.push("--parent-pid", String(PARENT_PID));
    if (PARENT_INSTANCE) args.push("--parent-instance", PARENT_INSTANCE);
    if (DEPTH !== undefined) args.push("--depth", String(DEPTH));
    if (opts.ended) args.push("--ended");
    if (opts.remove) args.push("--remove");
    // Reported once, alongside --protocol; kido carries both forward
    // across later reports. Protocol only means anything with an inbox to
    // receive an envelope on, so the two are reported together.
    if (pendingInbox && inboxPath) {
      args.push("--inbox", inboxPath, "--protocol", String(PROTOCOL_VERSION));
      inboxReported = true;
    }

    spawnDetached(kido, args);
  };

  // runKido is how every tool shells out: via spawn, awaited but never
  // blocking the event loop. It used to run execFileSync, which parks the
  // whole process for as long as kido takes - up to 5s for a slow ask or
  // message - and while parked this process's own inbox listener cannot
  // accept a connection at all. Composed with the 2s inboxTimeout on the
  // sending side (cmd/kido/inbox.go), a peer's `kido message` arriving in
  // that window would connect, write, and then hit its own read deadline
  // with the message never acknowledged - lost, not merely delayed. See
  // AGENTS.md and docs/subagents-plan.md's Spawning section, which is what
  // multiplies inbox traffic and made this worth fixing now.
  //
  // kido resolves both the caller (via $TMUX_PANE) and its tmux session
  // from the inherited environment. On failure it yields the line kido
  // printed on stderr rather than node's "Command failed", because that
  // line - "no agent session matches ...", "ask refused" - is the only
  // part a model can act on. Every outcome is a value, so no tool can leak
  // an exception into pi.
  //
  // Making this non-blocking reopens a window the cycle-refusal bookkeeping
  // used to rely on being closed: see pendingOutbound's own comment and
  // hasAskOutstandingTo above for why an inbound ask dispatched while an
  // outbound send is still in flight is still handled correctly.
  const runKido = (args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult> => {
    if (!kido) return Promise.resolve({ error: "kido is not on PATH" });
    return new Promise((resolve) => {
      const child = spawn(kido as string, args, { stdio: ["pipe", "pipe", "pipe"] });
      // Whoever gets there first wins, and the losers are no-ops: the
      // timeout branch kills the child, so "close" fires after it and
      // calls this again. Both halves are already idempotent - clearing a
      // cleared timer does nothing, and a settled promise ignores a second
      // resolve - so no "settled" flag is needed to keep them that way.
      const finish = (result: RunKidoResult): void => {
        clearTimeout(timer);
        resolve(result);
      };
      const timer = setTimeout(() => {
        child.kill();
        // timedOut: true marks this outcome as unknown, not failed - kido
        // may have already done its work (created a window, sent a
        // message) and simply not answered in time. A caller that treats
        // this the same as a definite failure (an exit code, ENOENT) can
        // end up cleaning up after something that actually succeeded -
        // see spawn_subagent's task-file handling.
        finish({ error: `kido ${args[0]} timed out after ${opts.timeoutMs}ms`, timedOut: true });
      }, opts.timeoutMs);
      timer.unref(); // a hung kido must never hold pi's event loop open

      const stdout: Buffer[] = [];
      const stderr: Buffer[] = [];
      child.stdout?.on("data", (c: Buffer) => stdout.push(c));
      child.stderr?.on("data", (c: Buffer) => stderr.push(c));
      child.on("error", (err) => finish({ error: err instanceof Error ? err.message : String(err) }));
      child.on("close", (code) => {
        if (code === 0) {
          finish({ out: Buffer.concat(stdout).toString("utf8").trim() });
        } else {
          const errText = Buffer.concat(stderr).toString("utf8").trim();
          finish({ error: errText || `kido ${args[0]} exited with code ${code}` });
        }
      });
      // A child that exits before reading all of stdin (or exits and closes
      // its end early) turns the write into EPIPE; unhandled, that is an
      // uncaught exception on this process, not just a failed tool call.
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input ?? "");
    });
  };

  // Both list_agents and ask_agent need the same list, read the same way -
  // and kido printing something unparseable is the same kind of failure to
  // them as kido not running at all, so it comes back as one.
  const fetchAgents = async (): Promise<{ agents: AgentInfo[] } | { error: string }> => {
    const res = await runKido(["agents", "--json"], { timeoutMs: 2000 });
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
      activity = capBytes(params.activity, MAX_ACTIVITY_BYTES);
      send(current);
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
      if (!kido) {
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
      const res = await runKido(args, { input: params.message, timeoutMs: 5000 });
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
      if (!kido) {
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

      // inbox may have gone null - session_shutdown, or a /reload whose
      // rebind failed - while the fetchAgents() call above was still in
      // flight: that fetch is now async, so this function can be suspended
      // right through a teardown that runs its own abandonPending (which
      // can only abandon waiters already in pendingOutbound) before
      // resuming here. Checked synchronously, with no await between the
      // check and pendingOutbound.set below, so there is no further gap
      // for abandonPending to miss: either this runs before that
      // teardown's synchronous prefix (inbox nulled, abandonPending
      // called) and the waiter it registers is caught by that
      // abandonPending call, or it runs after and sees the null inbox
      // already in place. A null inbox is the whole test: a shutdown nulls
      // it before its first await, so there is no moment at which this
      // session is on its way out but still looks open. A momentarily-null
      // inbox during a reload that goes on to rebind successfully is
      // refused the same conservative way - nothing here knows the rebind
      // will succeed, and it is safer to refuse an ask than to register a
      // waiter that might sit past a shutdown nobody told it about.
      if (!inbox) {
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
      const sent = await runKido(["message", "--kind", "ask", "--id", id, "--", target.id], {
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
      if (!kido) {
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

      // The task is model-authored, arbitrary text - never a command-line
      // argument, for the same reason kido spawn itself insists on a file
      // (see AGENTS.md and docs/subagents-plan.md's Spawning section).
      let taskFile: string;
      try {
        taskFile = join(tmpdir(), `kido-task-${process.pid}-${randomUUID()}.txt`);
        writeFileSync(taskFile, params.task, { mode: 0o600 });
      } catch (err) {
        return {
          content: [{ type: "text", text: `could not write task file: ${err instanceof Error ? err.message : String(err)}` }],
          details: {},
        };
      }

      const child = ["pi", "--name", name];
      if (params.model) child.push("--model", params.model);
      if (params.tools && params.tools.length > 0) child.push("--tools", params.tools.join(","));

      const res = await runKido(
        [
          "spawn",
          "--parent-pid",
          String(process.pid),
          "--parent-instance",
          INSTANCE,
          "--depth",
          String(depth),
          "--name",
          name,
          "--task-file",
          taskFile,
          "--",
          ...child,
        ],
        { timeoutMs: SPAWN_TIMEOUT_MS },
      );
      if ("error" in res) {
        // A definite failure (kido ran and said no, or never ran at all)
        // means nothing was created, and the file is now nobody's to
        // read - leaving it behind would just be a stray temp file with
        // the task's own text in it. A timeout is not definite: kido may
        // have finished creating the window just after this process gave
        // up waiting, in which case a real child is about to read this
        // file for its first task. Unlinking then would starve a live
        // subagent with no way for anyone to notice; leaking the file is
        // the smaller failure.
        if (!res.timedOut) {
          try {
            unlinkSync(taskFile);
          } catch {
            // already gone
          }
        }
        return { content: [{ type: "text", text: `could not spawn subagent: ${res.error}` }], details: {} };
      }
      const [windowID, paneID] = res.out.split(/\s+/);
      return {
        content: [{ type: "text", text: `spawned ${name} (window ${windowID}, pane ${paneID})` }],
        details: { name, window: windowID, pane: paneID },
      };
    },
  };

  pi.registerTool(listAgentsTool);
  pi.registerTool(setStatusTool);
  pi.registerTool(messageAgentTool);
  pi.registerTool(askAgentTool);
  pi.registerTool(spawnSubagentTool);

  pi.on("session_start", async (_event, ctx) => {
    // Resource lookup belongs here, not in the factory: the factory may run in
    // invocations that never start a session.
    kido = process.env.TMUX_PANE ? findKido() : null;
    if (!kido) return;
    sessionId = ctx.sessionManager.getSessionId() ?? null;
    title = ctx.sessionManager.getSessionName() || undefined;
    model = ctx.model?.id;
    lastKey = null;
    // A session switch or /reload re-runs this: drop the old inbox first.
    stopInbox();
    try {
      await startInbox();
    } catch {
      // no inbox; status reporting carries on regardless
    }
    // A rebind that succeeded lands on the same pid-named path, so any
    // ask still waiting can still be answered there and is left alone.
    // One that failed leaves no inbox at all, and a waiter kept past that
    // would block on an answer that has nowhere to arrive.
    if (!inbox) abandonPending();

    // A session switch or /reload re-runs this too; started fresh so a
    // /reload never leaves two timers running (see startParentLivenessPoll).
    startParentLivenessPoll(ctx.shutdown);

    // Deliver the task kido spawn left us, the same way an inbox prompt
    // is delivered - a subagent's first turn should read exactly like one
    // handed to it by another agent, not like a special case. A /reload
    // re-runs session_start, but by then the file is already unlinked, so
    // this only ever fires once. A missing or unreadable file (no task,
    // wrong permissions, someone already cleaned it up) is silently
    // nothing to deliver, never a reason to fail startup.
    //
    // The unlink runs whether or not the read worked. Nothing ever reads
    // this file again - session_start is the only reader and a /reload
    // finds it gone - so a file left behind after a failed read is not a
    // retry, just a stray temp file with a task's text in it that nobody
    // will ever clean up. Unlinking needs write permission on the
    // directory, not on the file, so the one case that actually leaks
    // (a task file whose mode was cleared) is removable even though it
    // was not readable.
    if (TASK_FILE) {
      let task = "";
      try {
        task = readFileSync(TASK_FILE, "utf8");
      } catch {
        // no task file, or it could not be read - nothing to deliver
      }
      try {
        unlinkSync(TASK_FILE);
      } catch {
        // already gone, or not ours to remove
      }
      if (task.trim()) deliver(task);
    }

    // Awaited before the first report so that report can carry --inbox.
    send("idle");
  });

  pi.on("session_info_changed", (event) => {
    title = event.name || undefined;
    send(current);
  });

  pi.on("model_select", (event) => {
    model = event.model.id;
    send(current);
  });

  const running = () => send("running");
  pi.on("agent_start", running);
  pi.on("turn_start", running);
  pi.on("tool_execution_start", running);
  pi.on("tool_call", running);

  // Blocking extension UI prompts: pi is waiting for the user, not working.
  pi.on("ui_prompt_start", () => send("waiting"));
  // A prompt can also be raised while pi is idle (an extension command calling
  // ctx.ui.select(), say); reporting "running" then would stick forever.
  pi.on("ui_prompt_end", (_event, ctx) => {
    send(ctx.isIdle() ? "idle" : "running");
  });

  pi.on("session_before_compact", () => {
    beforeCompact = current;
    send("compacting");
  });
  // Restore whatever we reported before compaction started: a manual /compact
  // can happen while idle, and agent_settled would not fire afterwards to
  // correct a blind "running".
  const restoreBeforeCompact = () => send(beforeCompact);
  pi.on("session_compact", restoreBeforeCompact);
  pi.on("session_compact_failed", restoreBeforeCompact);

  // The true idle signal: no retry, compaction, or follow-up left.
  pi.on("agent_settled", (_event, ctx) => {
    if (!ctx.isIdle()) return;
    send("idle", { ended: true });
  });

  // scheduleWindowLinger spawns the detached helper
  // docs/subagents-plan.md's Lifecycle section describes: sleep, then
  // `kido close-window`, run as its own process so it survives this one's
  // exit - this process's own event loop is gone by the time the sleep
  // would otherwise have to fire. windowID and kido's own path are passed
  // as sh's $0/$1 rather than interpolated into the script text, so
  // neither needs shell-quoting.
  const scheduleWindowLinger = (windowID: string): void => {
    if (!kido) return;
    spawnDetached("sh", ["-c", `sleep ${LINGER_SECONDS} && exec "$0" close-window "$1"`, kido, windowID]);
  };

  // sendCompletionNotice tells this session's parent, if it has one and
  // kido still knows where it is, that this subagent is finishing, and
  // schedules its own window's linger close. Only ever called from
  // session_shutdown, before the removal report below: list_agents/kido
  // agents must still resolve this session's own parent edge (self.parent)
  // and its own window while it does, which needs this session's own
  // record to still exist.
  //
  // The linger is scheduled whenever this is a subagent at all, whether or
  // not its parent edge still resolves - an orphaned subagent's window
  // still deserves the same 30s read window as one whose parent is still
  // there to be told. A dead or unreachable parent for the notice itself -
  // kido message failing however it fails, errInboxUnavailable or
  // otherwise - is exactly the case docs/subagents-plan.md means by
  // "nobody to tell": there is no distinct handling for it, the result is
  // simply dropped, same as any other runKido failure here. Nothing in
  // this function may throw past its own await, or a subagent's shutdown
  // would fail on account of a parent that already exited.
  const sendCompletionNotice = async (): Promise<void> => {
    if (!kido || PARENT_INSTANCE === undefined) return; // not a subagent
    const listed = await fetchAgents();
    if ("error" in listed) return;
    const self = listed.agents.find((a) => a.self);
    if (self?.window) scheduleWindowLinger(self.window);
    if (!self || !self.parent) return; // kido no longer has a parent edge for this session
    const text = `${title || "subagent"} finished` + (activity ? `: ${activity}` : "") + ` (${current})`;
    await runKido(["message", "--kind", "notice", "--", self.parent], { input: text, timeoutMs: 3000 });
  };

  pi.on("session_shutdown", async () => {
    // Both of these run before this handler's first await, so nothing else
    // can run in between - which is what lets ask_agent's `!inbox` check
    // stand in for "this session is shutting down".
    stopInbox();
    stopParentLivenessPoll();
    // Nothing is coming back this time, so no ask may be left waiting on
    // it - a tool call blocked on a five-minute timer is the last thing a
    // session on its way out should be holding.
    abandonPending();
    await sendCompletionNotice();
    send("idle", { remove: true });
  });
}
