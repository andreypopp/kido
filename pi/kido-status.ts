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
 * Inbox:
 *   On session start the extension asks kido where to bind — `kido inbox-path
 *   <pid>` prints an absolute socket path, creating its directory, and fails if
 *   the path would be too long — binds a unix STREAM socket there and reports
 *   the path once, with `--inbox <path> --protocol <n>` on the first status
 *   report; kido carries both values forward. A client writes a prompt as
 *   UTF-8 with no framing, half-closes its write half, reads `ok\n` (or
 *   `refused\n` for a message the session declines - see kido-agents.ts) and
 *   closes. The payload is either raw v0 text or a v1 JSON envelope (kido's
 *   own inbox protocol - see internal/msg and AGENTS.md); plain v0 text is
 *   delivered as a user message here, and an envelope is handed to the agent
 *   half (see handleInbound). Any failure here is silent and leaves status
 *   reporting working.
 *
 * The agent half:
 *   Agent coordination - the tools, envelope dispatch, spawning, subagent
 *   lifecycle - lives in its companion extension, kido-agents.ts, which
 *   attaches to this one through the seam below. The inbox is here because
 *   it predates all of that: it exists so `kido prompt` can hand a prompt to
 *   a session nobody is typing into, which is status-side work.
 *
 * Install:
 *   mkdir -p ~/.pi/agent/extensions
 *   cp kido-status.ts kido-agents.ts ~/.pi/agent/extensions/
 *
 * Or, for a one-off run:
 *   pi -e /path/to/kido-status.ts -e /path/to/kido-agents.ts
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, constants, unlinkSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { delimiter, isAbsolute, join } from "node:path";

// Generated once per process, not per session: it identifies this pi
// process to kido (see state.Session.Instance), and a session switch or
// /reload must not change it out from under a child that already recorded
// it as a ParentInstance. Read by kido-agents.ts through the seam below
// (StatusHost.instance), never by importing it: a second evaluation of
// this file would generate a second id, and a subagent would then name a
// parent instance nobody reports.
const INSTANCE = randomUUID();

// A subagent's kido-status runs as a plain pi process spawned by `kido
// spawn` (see docs/subagents-plan.md), which sets these in its environment.
// Absent for a root session. kido-agents.ts reads the same three from the
// same environment rather than sharing them: they are constants of this
// process either way, so two readers cannot disagree - unlike INSTANCE,
// which is generated and therefore travels across the seam.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_INSTANCE = process.env.KIDO_AGENT_PARENT_INSTANCE || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// HEARTBEAT_MS is how often a session re-sends its current status while
// that status is "running". send() below coalesces away a report whose
// key (status/title/activity/model/ended/remove) matches the last one
// sent - and agent_start, turn_start, tool_execution_start and tool_call
// all send exactly the same "running" key, so in a real pi only the first
// of them ever reaches kido. A turn has no upper bound, so without a
// heartbeat a healthy session mid-turn is indistinguishable from a wedged
// one the moment state.StallThreshold elapses. A package variable, set
// only via the environment since it is read once at module scope and a
// test reimports the module to pick up a fresh value.
const HEARTBEAT_MS = Number(process.env.KIDO_HEARTBEAT_MS) || 30000;

// Cap for the free-text activity. The JSON schema on kido-agents.ts's
// set_status tool says 256 too, but a model is free to ignore it, and the
// sidebar has one row to draw this in - so the cap that counts is this
// one, applied on the way in.
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

export type Status = "running" | "waiting" | "compacting" | "idle";

// RunKidoResult's error branch carries timedOut so a caller can tell a
// definite failure (kido ran and said so, or never started) apart from a
// run that was still in flight when this process gave up waiting on it.
export type RunKidoResult = { out: string } | { error: string; timedOut?: boolean };

// Anything larger than this is dropped rather than buffered.
const MAX_PROMPT_BYTES = 1024 * 1024;

// The inbox envelope version this extension speaks (see internal/msg and
// AGENTS.md's note on the protocol). Reported with --protocol alongside
// --inbox so kido only ever sends an envelope to a receiver that has said
// it understands one.
const PROTOCOL_VERSION = 1;

export type EnvelopeKind = "message" | "ask" | "reply" | "notice" | "interrupt" | "stop";

export interface Envelope {
  v: number;
  kind: EnvelopeKind;
  id: string;
  from: { session: string; name?: string; pane?: string };
  replyTo?: string;
  text: string;
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

// spawnDetached runs one fire-and-forget child: detached and
// stdio-ignored, so a Ctrl+C on pi's process group does not kill it and
// it outlives this process entirely - which is what a status report
// racing pi's exit and a linger helper that must sleep past it both
// need. Both failure paths are swallowed, the synchronous throw and the
// async "error" event; the latter is not optional, an unhandled one is
// an uncaught exception on this process rather than a failed spawn.
function spawnDetached(cmd: string, args: string[]): void {
  try {
    const child = spawn(cmd, args, { stdio: "ignore", detached: true });
    child.on("error", () => {});
    child.unref();
  } catch {
    // never let a spawn failure reach pi
  }
}

// ---------------------------------------------------------------------
// The seam between the two extensions.
//
// kido-agents.ts needs this session's inbox - to dispatch an envelope
// that arrives on it, and to refuse an ask when there is none to receive
// the answer - plus the one status report both halves share. None of that
// is safe to duplicate: there is one socket, one coalescing key and one
// last-reported status per session.
//
// So the two halves meet at a pair of slots on globalThis, reached
// through a global-registry symbol, and kido-agents.ts imports nothing
// from this file but types (which type-stripping erases, so it never
// loads a second copy of this one).
//
// That is not ceremony over the ordinary "ES modules are singletons per
// resolved path" argument - that argument does not hold here. Measured
// against pi 0.85.1: an extension is evaluated in a registry of its own,
// so kido-agents.ts's `import ... from "./kido-status.ts"` produced a
// *second* evaluation of this file, under the identical file URL, with
// its own module scope. Two module-scope slots meant each half held a
// reference to a copy of the other that no session had ever started, and
// list_agents in a real pi answered "[]". globalThis is shared across
// those evaluations (also measured), so it is what the two halves can
// actually meet on.
//
// The load-order assumption is that there is none. pi discovers extensions
// in a directory and runs their factories in whatever order it finds them,
// and every factory runs before any session_start. Neither slot is read at
// factory time: this factory publishes a host and then only ever reads
// `agents` from inside an event, and kido-agents.ts registers its hooks
// and then only ever reads the host from inside a tool call or a hook. So
// either order leaves both slots filled long before anything looks at
// them, and an extension loaded on its own simply finds the other slot
// empty and degrades (this half delivers an envelope's text as plain
// prompt; that half's tools report kido as unavailable).
// ---------------------------------------------------------------------

// SessionContext is the part of pi's session ctx the agent half uses: how
// it answers an inbound interrupt or stop, and how the parent-liveness
// poll ends a session whose parent is gone.
export interface SessionContext {
  abort(): void;
  shutdown(): void;
}

// StatusHost is what this half lends the agent half: this session's inbox
// and the status report, as accessors rather than shared variables, so
// there is exactly one owner of each.
export interface StatusHost {
  // The resolved kido binary, or null until session_start has found one -
  // the "kido is not available" condition every tool checks.
  kidoPath(): string | null;
  // This process's own generated instance id, exactly as reported to kido
  // with --instance: what a child must name as its parent instance.
  instance(): string;
  sessionId(): string | null;
  title(): string | undefined;
  activity(): string;
  status(): Status;
  // Whether this session is listening on an inbox right now. Synchronous
  // on purpose: ask_agent checks it with no await between the check and
  // registering its waiter.
  inboxOpen(): boolean;
  setActivity(text: string): void;
  deliver(text: string): void;
  runKido(args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult>;
  // One fire-and-forget child, for the subagent window linger. Shared
  // rather than reimplemented next to its caller: both failure paths have
  // to be swallowed and the handle unref'd, and a second copy of that
  // would drift.
  spawnDetached(cmd: string, args: string[]): void;
}

// AgentHooks is the reverse: the points in this half's lifecycle where
// agent coordination has something to do. They exist rather than the
// agent half registering its own pi.on handlers because the order within
// a session_start and a session_shutdown is load-bearing - the inbox must
// be bound before the first report carries its path, and the parent must
// be told this subagent finished while kido still has a record of it -
// and nothing says pi runs two extensions' handlers in any given order.
export interface AgentHooks {
  // Called first thing in session_start, before the kido lookup, the way
  // the ctx capture always was: a /reload brings a fresh ctx and the old
  // reference must not survive it even in a session with no kido.
  sessionStarting(ctx: SessionContext): void;
  // Called once the inbox is bound and before the first status report.
  sessionStarted(ctx: SessionContext): Promise<void>;
  // The inbox has gone away and is not coming back (a /reload whose
  // rebind failed); anything waiting for a reply on it must be released.
  inboxLost(): void;
  // Called from session_shutdown after the inbox is down and before the
  // removal report, so kido still resolves this session's parent edge and
  // window while it runs.
  sessionEnding(reason?: string): Promise<void>;
  // Dispatch one v1 envelope, answering the wire.
  handleEnvelope(env: Envelope): Promise<"ok" | "refused">;
}

// Seam is the shared pair of slots. Either may be null: an extension
// loaded without its companion finds the other empty. Last writer wins,
// which is what a /reload - which re-runs both factories - wants: the
// newest pair is the live one. kido-agents.ts declares the same two lines
// against the same symbol; they are two views of one object, which is the
// whole point.
export interface Seam {
  host: StatusHost | null;
  agents: AgentHooks | null;
}

const SEAM = Symbol.for("kido.pi.extension.seam");

function seam(): Seam {
  const g = globalThis as unknown as Record<symbol, Seam | undefined>;
  return (g[SEAM] ??= { host: null, agents: null });
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

  // heartbeatTimer is the running-status heartbeat started by
  // startHeartbeat below; null whenever the last reported status was not
  // "running", so it never fires for an idle or waiting session.
  let heartbeatTimer: NodeJS.Timeout | null = null;

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

  // handleInbound dispatches one inbox payload and returns the wire
  // answer. Plain v0 text is this half's own business - the inbox exists
  // so `kido prompt` can hand a session a prompt - and anything that
  // parses as a v1 envelope belongs to the agent half. With no agent half
  // loaded an envelope still reaches the model as its own text rather
  // than being dropped: there is nothing here that could act on its kind,
  // but losing a message silently is the one outcome the plan rules out.
  const handleInbound = async (prompt: string): Promise<"ok" | "refused"> => {
    const env = parseEnvelope(prompt);
    if (!env) {
      // v0 raw text: delivered exactly as it always has been.
      if (prompt) deliver(prompt);
      return "ok";
    }
    const agents = seam().agents;
    if (agents) return agents.handleEnvelope(env);
    if (env.text) deliver(env.text);
    return "ok";
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
    sock.on("end", async () => {
      if (dropped) return;
      // Concatenate before decoding: a multi-byte char can straddle chunks.
      const text = Buffer.concat(chunks).toString("utf8");
      const prompt = text.trim();
      // Decided (and any delivery or refusal done) before the socket is
      // closed: the caller's kido message reads the answer to tell a
      // refusal from an ordinary delivery.
      const response = prompt ? await handleInbound(prompt) : "ok";
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

  // startHeartbeat/stopHeartbeat manage heartbeatTimer to match the
  // status send() just reported: running gets a periodic re-send, so kido
  // sees a fresh Session.TS every HEARTBEAT_MS even though the coalescing
  // key below never changes; anything else has no timer at all. Both are
  // idempotent, so calling either from every send() - whatever the
  // previous state was - is simpler than tracking the transition.
  const startHeartbeat = (): void => {
    if (heartbeatTimer) return;
    heartbeatTimer = setInterval(() => send(current, { heartbeat: true }), HEARTBEAT_MS);
    heartbeatTimer.unref(); // a hung kido must never hold pi's event loop open
  };
  const stopHeartbeat = (): void => {
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  };

  // Fire-and-forget. Coalesced: identical consecutive reports are dropped,
  // except a heartbeat re-send, which must reach kido precisely because
  // nothing about it changed (see HEARTBEAT_MS above).
  const send = (
    status: Status,
    opts: { ended?: boolean; remove?: boolean; heartbeat?: boolean } = {},
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
    if (!pendingInbox && !opts.heartbeat && key === lastKey) return;
    if (!opts.heartbeat) lastKey = key;
    current = status;
    if (status === "running") startHeartbeat();
    else stopHeartbeat();

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

  // runKido is how this half asks kido where to bind, and how every tool
  // in kido-agents.ts shells out: via spawn, awaited but never blocking
  // the event loop. It used to run execFileSync, which parks the whole
  // process for as long as kido takes - up to 5s for a slow ask or
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
  // in kido-agents.ts used to rely on being closed: see pendingOutbound's
  // own comment there for why an inbound ask dispatched while an outbound
  // send is still in flight is still handled correctly.
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

  // Published before any handler can run, so the agent half finds this
  // session however early it asks. Nothing here depends on its own
  // factory having run first (see the seam note above).
  seam().host = {
    kidoPath: () => kido,
    instance: () => INSTANCE,
    sessionId: () => sessionId,
    title: () => title,
    activity: () => activity,
    status: () => current,
    inboxOpen: () => inbox !== null,
    setActivity: (text: string) => {
      activity = capBytes(text, MAX_ACTIVITY_BYTES);
      send(current);
    },
    deliver,
    runKido,
    spawnDetached,
  };

  pi.on("session_start", async (_event, ctx) => {
    // Called unconditionally, before the kido-on-PATH check below: a
    // /reload re-runs this handler with a fresh ctx, and the old
    // reference the agent half captured must not survive it.
    seam().agents?.sessionStarting(ctx);
    // Resource lookup belongs here, not in the factory: the factory may run in
    // invocations that never start a session.
    kido = process.env.TMUX_PANE ? findKido() : null;
    if (!kido) return;
    sessionId = ctx.sessionManager.getSessionId() ?? null;
    title = ctx.sessionManager.getSessionName() || undefined;
    model = ctx.model?.id;
    lastKey = null;
    // A /reload re-runs this handler mid-turn; the old timer must not
    // survive it, since send("idle") below - not a heartbeat report - is
    // what starts a fresh one if the restored session is still running.
    stopHeartbeat();
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
    if (!inbox) seam().agents?.inboxLost();

    // The agent half's own start: the parent-liveness poll and the task
    // `kido spawn` left for a subagent to deliver. After the inbox, so a
    // task's first turn can already be answered; before the first report,
    // which is what carries --inbox.
    await seam().agents?.sessionStarted(ctx);

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

  pi.on("session_shutdown", async (event?: { reason?: string }) => {
    // stopInbox and the synchronous prefix of sessionEnding (which stops
    // the parent poll and releases every waiting ask) both run before this
    // handler's first await, so nothing else can run in between - which is
    // what lets ask_agent's `!inbox` check stand in for "this session is
    // shutting down".
    stopInbox();
    stopHeartbeat();
    // Everything the agent half does on the way out - releasing waiting
    // asks, recording this run's outcome, telling the parent - runs before
    // the removal report below: kido must still have a record of this
    // session while it resolves its own parent edge and window.
    await seam().agents?.sessionEnding(event?.reason);
    send("idle", { remove: true });
  });
}
