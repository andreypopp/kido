/**
 * kido-status — report this pi session's live status to kido, and accept
 * prompts delivered from outside the session.
 *
 * kido is a tmux sidebar that shows the live status of coding agents. This
 * extension makes a pi session visible in that sidebar by shelling out to:
 *
 *   kido agent-status --agent pi --session <id> --status running|waiting|compacting|idle
 *                     [--title <text>] [--activity <text>] [--model <name>]
 *                     [--parent-pid <pid>] [--parent-session <id>]
 *                     [--depth <n>] [--ended] [--remove]
 *                     [--inbox <path>] [--protocol <n>]
 *
 * kido reads $TMUX_PANE from the environment, so the command must be spawned
 * from inside the pi process (which lives in the tmux pane).
 *
 * Behaviour:
 *   - If `kido` is not on PATH, or pi is not running inside tmux, the extension
 *     does nothing at all, quietly.
 *   - Every invocation is fire-and-forget (detached, stdio ignored). Failures
 *     never propagate into pi and never print to the TUI.
 *   - Status changes are coalesced: kido is only invoked when the reported
 *     status/title/activity/model actually differs from what was last sent.
 *
 * Inbox:
 *   On session start the extension asks kido where to bind (`kido inbox-path
 *   <pid>`), binds a unix STREAM socket there and reports the path once, with
 *   `--inbox <path> --protocol <n>` on the first status report. Plain v0 text
 *   is delivered as a user message here; a v1 envelope is handed to the agent
 *   half, kido-agents.ts. The protocol, the v0/v1 rule and the seam the two
 *   halves meet at are in docs/design.md.
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
import { accessSync, constants, unlinkSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { delimiter, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

// Set by `kido spawn_subagent` in a subagent's environment; absent for a root
// session. kido-agents.ts reads the same three itself.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_SESSION = process.env.KIDO_AGENT_PARENT_SESSION || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// HEARTBEAT_MS is how often a session re-sends its status while it is
// "running", bypassing send()'s coalescing so kido's staleness check has
// a real last-seen time (docs/design.md, "Heartbeat and staleness").
// Read once at module scope; a test re-imports the module to change it.
const HEARTBEAT_MS = Number(process.env.KIDO_HEARTBEAT_MS) || 30000;

// How long the session claim waits for kido. A timeout is not a refusal:
// the session goes on reporting, and the claim in kido's own write path
// (internal/state.Record) is what actually decides who holds the id.
const CLAIM_TIMEOUT_MS = 5000;

// Cap for the free-text activity, applied on the way in; the tool schema
// says 256 too, but a model is free to ignore it.
const MAX_ACTIVITY_BYTES = 256;

// Cut on a code-point boundary, never mid-sequence: decoding a buffer that
// splits one leaves a U+FFFD behind, which is three bytes, so a naive
// byte slice can come back longer than the cap it was enforcing.
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

// code is the subcommand's exit status, absent when kido could not be
// run at all or was killed on the timeout. Only the session claim reads
// it (EXIT_SESSION_HELD); everything else acts on error alone.
export type RunKidoResult = { out: string } | { error: string; code?: number };

// What `kido agent-status` exits with when another live process holds
// this session id (cmd/kido/main.go). Two pi processes on one session
// file is the case: the second must not report, and says so once.
export const EXIT_SESSION_HELD = 6;

// Anything larger than this is dropped rather than buffered.
const MAX_PROMPT_BYTES = 1024 * 1024;

// The inbox envelope version this extension speaks (see internal/msg),
// reported with --protocol alongside --inbox.
const PROTOCOL_VERSION = 1;

export type EnvelopeKind = "message" | "ask" | "reply" | "notice" | "stream" | "steer" | "interrupt" | "stop";

// How pi is asked to schedule a delivered message: "followUp" waits for
// the session to finish what it is doing, "steer" joins it.
export type DeliverAs = "followUp" | "steer";

export interface Envelope {
  v: number;
  kind: EnvelopeKind;
  id: string;
  from: { session: string; name?: string; pane?: string };
  replyTo?: string;
  text: string;
  // A "stream" envelope's own pair (internal/msg): the async run these
  // lines came from, and the file that has every one of them.
  run?: string;
  output?: string;
}

// parseEnvelope mirrors internal/msg.Parse: a payload is a v1 envelope
// only if it parses as a JSON object carrying both "v" and "kind";
// anything else is v0 raw prompt text.
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
  // Coerced rather than required, to match msg.Parse: Go reads a missing
  // "text" as the zero string.
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
// stdio-ignored (or stdin-piped, when opts.input is given), so a Ctrl+C
// on pi's process group does not kill it and it outlives this process.
// Both failure paths are swallowed, the synchronous throw and the async
// "error" event; an unhandled "error" event is an uncaught exception on
// this process, not a failed spawn.
//
// With opts.input, the write is queued and the child unref'd without
// waiting for it to run at all - proven against a real child process,
// not assumed: a write that fits in the pipe's kernel buffer (every
// caller's payload does; kido's own caps keep it that way) is handed to
// the kernel synchronously, so it survives this process calling
// process.exit() on the very next line. Once the kernel has it, the
// child - detached, its own process group - runs to completion
// regardless of what becomes of this process, which is the whole point:
// a slow or wedged peer on the far end of what that child does (an inbox
// dial, say) costs the child seconds, never this one.
function spawnDetached(cmd: string, args: string[], opts: { input?: string } = {}): void {
  try {
    const child = spawn(cmd, args, {
      stdio: [opts.input !== undefined ? "pipe" : "ignore", "ignore", "ignore"],
      detached: true,
    });
    child.on("error", () => {});
    if (opts.input !== undefined) {
      // EPIPE if the child exits before reading stdin at all.
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input);
    }
    child.unref();
  } catch {
    // never let a spawn failure reach pi
  }
}

// The seam between the two extensions: a pair of slots on globalThis,
// reached through a global-registry symbol. Not module scope, and not an
// import: pi (measured against 0.85.1) evaluates each extension in a
// module registry of its own, so an import of this file from
// kido-agents.ts produced a second evaluation of it with its own scope
// and its own state. kido-agents.ts therefore imports nothing but
// types from here. Neither slot is read at factory time, so load order
// does not matter. docs/design.md, "Two extensions, and the seam
// between them".

// SessionContext is the part of pi's session ctx the agent half uses: how
// it answers an inbound interrupt or stop, and how the parent-liveness
// poll ends a session whose parent is gone.
export interface SessionContext {
  abort(): void;
  shutdown(): void;
}

// StatusHost is what this half lends the agent half, as accessors rather
// than shared variables, so there is exactly one owner of each.
export interface StatusHost {
  // The resolved kido binary, or null until session_start has found one.
  kidoPath(): string | null;
  // Null until session_start has resolved one, and forever in a pi with
  // no kido or no tmux. The agent half checks it against KIDO_AGENT_RUN_ID
  // to tell a real subagent from a process that merely inherited one's
  // environment, so it is a fact about this process, not a claim.
  sessionId(): string | null;
  status(): Status;
  // Whether this session is listening on an inbox right now. Synchronous
  // on purpose: ask_agent checks it with no await between the check and
  // registering its waiter.
  inboxOpen(): boolean;
  setActivity(text: string): void;
  deliver(text: string, deliverAs?: DeliverAs): void;
  runKido(args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult>;
  spawnDetached(cmd: string, args: string[], opts?: { input?: string }): void;
}

// AgentHooks is the reverse: the points in this half's lifecycle where
// agent coordination has something to do. Hooks rather than the agent
// half's own pi.on handlers, because the order within session_start and
// session_shutdown is load-bearing and nothing says pi runs two
// extensions' handlers in any given order.
export interface AgentHooks {
  // Called first thing in session_start, before the kido lookup: a
  // /reload brings a fresh ctx and the old reference must not survive it
  // even in a session with no kido.
  sessionStarting(ctx: SessionContext): void;
  // Called once the inbox is bound and before the first status report.
  sessionStarted(ctx: SessionContext): Promise<void>;
  // The inbox has gone away and is not coming back.
  inboxLost(): void;
  // Called from session_shutdown after the inbox is down and before the
  // removal report.
  sessionEnding(reason?: string): Promise<void>;
  // Called on every agent_settled where ctx.isIdle() is true - this is the
  // idle self-exit timer's only arming signal (docs/design.md, "Idle
  // self-exit").
  turnEnded(): void;
  // Called on every signal kido-status.ts already treats as "this session
  // has work to do" - a running report, or a message about to be handed
  // to the model - so the idle self-exit timer resets rather than firing
  // mid-turn.
  workStarted(): void;
  // Dispatch one v1 envelope, answering the wire.
  handleEnvelope(env: Envelope): Promise<"ok" | "refused">;
}

// Seam is the shared pair of slots. Either may be null: an extension
// loaded without its companion finds the other empty. Last writer wins,
// which is what a /reload wants. kido-agents.ts declares the same shape
// against the same symbol.
export interface Seam {
  host: StatusHost | null;
  agents: AgentHooks | null;
}

// The listening inbox, held on globalThis rather than at module scope: a
// /reload re-evaluates this file but keeps the process, the pid and the
// session id, and the socket path is keyed by pid, so nothing requires the
// listener to go down with the module. handler is whichever module owns
// the inbox now - null in the gap between a reload's shutdown and the
// reloaded module's session_start, during which connections are parked in
// waiting rather than refused. docs/design.md, "The inbox".
interface InboxHold {
  server: Server;
  path: string;
  handler: ((sock: Socket) => void) | null;
  waiting: Socket[];
}

const INBOX_SLOT = Symbol.for("kido.pi.extension.inbox");

function heldInbox(): InboxHold | null {
  return (globalThis as unknown as Record<symbol, InboxHold | undefined>)[INBOX_SLOT] ?? null;
}

function setHeldInbox(hold: InboxHold | null): void {
  (globalThis as unknown as Record<symbol, InboxHold | undefined>)[INBOX_SLOT] = hold ?? undefined;
}

// The server's one connection listener, outliving every module that owns
// the inbox: it reads the slot on each connection rather than closing over
// a handler. A parked socket has had no data listener attached, so it is
// still paused and loses nothing; the reloaded module's handler reads it
// whole.
function dispatchInbox(sock: Socket): void {
  const hold = heldInbox();
  if (!hold) {
    sock.destroy();
    return;
  }
  if (hold.handler) {
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

const SEAM = Symbol.for("kido.pi.extension.seam");

function seam(): Seam {
  const g = globalThis as unknown as Record<symbol, Seam | undefined>;
  return (g[SEAM] ??= { host: null, agents: null });
}

// One copy of each extension per process. pi dedupes the extensions it
// is given by real path and nothing else (resource-loader.js mergePaths,
// measured against 0.87.1), so the copy kido's bin directory passes with
// --extension and one an earlier kido installed into
// ~/.pi/agent/extensions are two extensions to it: both would bind an
// inbox and report, and the second's tools would fail to load as
// conflicts. The first copy pi runs keeps the slot - the --extension one,
// since pi loads those ahead of its own directory - and the other
// registers nothing. A /reload runs the same file again and finds the
// slot its own. Keyed by the file's path, so the test suite's
// cache-busting query on the module URL is still the same copy.
// kido-agents.ts does the same against a slot of its own.
const COPY_SLOT = Symbol.for("kido.pi.extension.status.copy");

function isFirstCopy(): boolean {
  const path = fileURLToPath(import.meta.url);
  const g = globalThis as unknown as Record<symbol, string | undefined>;
  return (g[COPY_SLOT] ??= path) === path;
}

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
  let kido: string | null = null;
  let sessionId: string | null = null;
  let title: string | undefined;
  let activity = "";
  let model: string | undefined;
  let lastKey: string | null = null;
  let current: Status = "idle";
  let beforeCompact: Status = "idle";

  let inbox: Server | null = null;
  let inboxReported = false;

  // false once kido has answered that another live process holds this
  // session id: this pi is not tracked, and must neither report nor bind
  // an inbox for the rest of the session (docs/design.md, "One holder per
  // session id").
  let tracked = true;

  // null whenever the last reported status was not "running".
  let heartbeatTimer: NodeJS.Timeout | null = null;

  // deliver hands text to the model. The default is "followUp" and most
  // callers take it: pi drains followUp only once the agent has decided
  // to stop, so a queued message waits for whatever the session is doing
  // to finish, while "steer" is drained inside the loop and joins the
  // run already under way. Which kinds get which, and why an ask must
  // never steer, is docs/design.md, "Steer and followUp". Either way
  // deliverAs is only consulted while streaming: pi sends immediately
  // when the session is idle, and the message triggers a new turn.
  const deliver = (text: string, deliverAs: DeliverAs = "followUp"): void => {
    // A delivered message is about to produce a turn, so the idle
    // self-exit timer must not fire in the gap between this call and
    // pi's own turn_start.
    seam().agents?.workStarted();
    pi.sendUserMessage(text, { deliverAs });
  };

  // handleInbound dispatches one inbox payload and returns the wire
  // answer. With no agent half loaded an envelope still reaches the model
  // as its own text rather than being dropped.
  const handleInbound = async (prompt: string): Promise<"ok" | "refused"> => {
    const env = parseEnvelope(prompt);
    if (!env) {
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
      const response = prompt ? await handleInbound(prompt) : "ok";
      try {
        sock.end(response + "\n");
      } catch {
        // client may already be gone
      }
    });
  };

  // keepListening is the /reload case: this module stops serving the
  // inbox, but the socket stays bound and the server is handed to the
  // reloaded module through the slot. Either way `inbox` goes null
  // synchronously, which is what ask_agent's inboxOpen() check reads as
  // "this session is shutting down".
  const stopInbox = (opts: { keepListening?: boolean } = {}): void => {
    const hold = heldInbox();
    inbox = null;
    inboxReported = false;
    if (!hold) return;
    hold.handler = null;
    if (opts.keepListening) return;
    setHeldInbox(null);
    for (const sock of hold.waiting.splice(0)) sock.destroy();
    try {
      hold.server.close();
    } catch {
      // already closed
    }
    try {
      unlinkSync(hold.path);
    } catch {
      // already gone
    }
  };

  // adoptInbox picks up a listener a reload handed forward: same socket,
  // no rebind, and whatever arrived in the gap is handled now, answer
  // included.
  const adoptInbox = (): boolean => {
    const hold = heldInbox();
    if (!hold || hold.handler) return false;
    hold.handler = onConnection;
    inbox = hold.server;
    inboxReported = false;
    for (const sock of hold.waiting.splice(0)) onConnection(sock);
    return true;
  };

  const startInbox = async (): Promise<void> => {
    // Where to bind is kido's decision; a refusal means no inbox. The name
    // is this process's pid, so a leftover file at that path cannot belong
    // to a running listener and is always safe to remove.
    const asked = await runKido(["inbox-path", String(process.pid)], { timeoutMs: 2000 });
    if ("error" in asked) return;
    const path = asked.out;
    if (!path || !isAbsolute(path)) return;
    try {
      unlinkSync(path);
    } catch {
      // nothing there
    }
    const server = createServer({ allowHalfOpen: true }, dispatchInbox);
    server.on("error", () => {});
    const bound = await new Promise<boolean>((resolve) => {
      server.once("error", () => resolve(false));
      server.listen(path, () => resolve(true));
    });
    if (!bound) return; // never publish a path we are not listening on
    server.unref(); // never hold pi's event loop open
    setHeldInbox({ server, path, handler: onConnection, waiting: [] });
    inbox = server;
    inboxReported = false;
  };

  // Both idempotent, so every send() calls one of them without tracking
  // the transition.
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
  // except a heartbeat re-send.
  // statusArgs is one report's whole command line, shared by send() and
  // by the claim session_start makes with it: the claim is the first
  // report, awaited rather than fired and forgotten, because its answer
  // is the one thing this extension needs back from kido.
  const statusArgs = (
    status: Status,
    opts: { ended?: boolean; remove?: boolean; inbox?: string | null } = {},
  ): string[] => {
    const args = [
      "agent-status",
      "--agent",
      "pi",
      "--session",
      sessionId as string,
      "--status",
      status,
      // Always sent: an omitted --activity is carried forward by kido, an
      // empty one clears it.
      "--activity",
      activity,
    ];
    if (title) args.push("--title", title);
    if (model) args.push("--model", model);
    if (PARENT_PID !== undefined) args.push("--parent-pid", String(PARENT_PID));
    if (PARENT_SESSION) args.push("--parent-session", PARENT_SESSION);
    if (DEPTH !== undefined) args.push("--depth", String(DEPTH));
    if (opts.ended) args.push("--ended");
    if (opts.remove) args.push("--remove");
    if (opts.inbox) args.push("--inbox", opts.inbox, "--protocol", String(PROTOCOL_VERSION));
    return args;
  };

  const send = (
    status: Status,
    opts: { ended?: boolean; remove?: boolean; heartbeat?: boolean } = {},
  ): void => {
    if (!kido || !sessionId || !tracked) return;

    // activity and model join the key, or a set_status or model switch
    // that leaves the status unchanged would be dropped.
    const key = [status, title ?? "", activity, model ?? "", opts.ended ? 1 : 0, opts.remove ? 1 : 0].join("|");
    // The report that carries --inbox must never be coalesced away:
    // session_start awaits the socket bind, and another handler can send
    // an equivalent "idle" report inside that window.
    const inboxPath = inbox ? (heldInbox()?.path ?? null) : null;
    const pendingInbox = inboxPath !== null && !inboxReported;
    if (!pendingInbox && !opts.heartbeat && key === lastKey) return;
    if (!opts.heartbeat) lastKey = key;
    current = status;
    if (status === "running") startHeartbeat();
    else stopHeartbeat();

    // The inbox is reported once; kido carries it forward.
    const args = statusArgs(status, { ...opts, inbox: pendingInbox ? inboxPath : null });
    if (pendingInbox && inboxPath) inboxReported = true;

    spawnDetached(kido, args);
  };

  // runKido is how every call into kido is made: via spawn, awaited but
  // never blocking the event loop, since a blocked process cannot accept
  // an inbox connection and a peer's message would be lost (docs/design.md,
  // "Two extensions"). On failure it yields the line kido printed on
  // stderr, the only part a model can act on. Every outcome is a value.
  const runKido = (args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult> => {
    if (!kido) return Promise.resolve({ error: "kido is not on PATH" });
    return new Promise((resolve) => {
      const child = spawn(kido as string, args, { stdio: ["pipe", "pipe", "pipe"] });
      // Whoever gets there first wins; clearing a cleared timer and
      // resolving a settled promise are both no-ops.
      const finish = (result: RunKidoResult): void => {
        clearTimeout(timer);
        resolve(result);
      };
      const timer = setTimeout(() => {
        child.kill();
        // Unknown, not failed: kido may already have done its work, which
        // is why the message says "timed out" rather than naming a failure.
        finish({ error: `kido ${args[0]} timed out after ${opts.timeoutMs}ms` });
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
          finish({ error: errText || `kido ${args[0]} exited with code ${code}`, code: code ?? undefined });
        }
      });
      // A child that exits before reading all of stdin turns the write
      // into EPIPE; unhandled, that is an uncaught exception on this
      // process.
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input ?? "");
    });
  };

  seam().host = {
    kidoPath: () => kido,
    sessionId: () => sessionId,
    status: () => current,
    inboxOpen: () => inbox !== null,
    setActivity: (text: string) => {
      // Two writes of one fact, and both are needed. `kido set_status` is
      // the narrow command behind the narrow tool, and it updates the
      // record without disturbing anything else on it; the local variable
      // is what every later `kido agent-status` report carries, and
      // leaving it stale would have the next report clear the activity
      // this one just set. Fire-and-forget, as this has always been: the
      // model is told "ok" before any subprocess could answer.
      activity = capBytes(text, MAX_ACTIVITY_BYTES);
      if (kido) spawnDetached(kido, ["set_status", "--", activity]);
    },
    deliver,
    runKido,
    spawnDetached,
  };

  pi.on("session_start", async (_event, ctx) => {
    // Before the kido-on-PATH check: a /reload brings a fresh ctx.
    seam().agents?.sessionStarting(ctx);
    // Resource lookup belongs here, not in the factory: the factory may run in
    // invocations that never start a session.
    kido = process.env.TMUX_PANE ? findKido() : null;
    if (!kido) return;
    sessionId = ctx.sessionManager.getSessionId() ?? null;
    title = ctx.sessionManager.getSessionName() || undefined;
    model = ctx.model?.id;
    lastKey = null;
    tracked = true;
    stopHeartbeat();

    // The claim, before anything else is done in kido's name: this same
    // first report, awaited, so its refusal can be read. A session id
    // another live process holds is not this one's to report under, and
    // every later report is fire-and-forget precisely because this one
    // settled the question. The inbox is not bound either - its path is
    // named after this pid and would collide with nothing, but nothing
    // could address it, since only a state record publishes one.
    if (sessionId) {
      const claim = await runKido(statusArgs("idle"), { timeoutMs: CLAIM_TIMEOUT_MS });
      if ("error" in claim && claim.code === EXIT_SESSION_HELD) {
        tracked = false;
        try {
          ctx.ui?.notify?.(`kido: ${claim.error}`, "warning");
        } catch {
          // a pi with no UI to notify: the refusal still stands
        }
        return;
      }
      lastKey = null; // the claim is not a report the coalescing may match against
    }

    // A /reload re-runs this handler: take over the listener it handed
    // forward. Anything else binds afresh.
    if (!adoptInbox()) {
      stopInbox();
      try {
        await startInbox();
      } catch {
        // no inbox; status reporting carries on regardless
      }
    }
    // A bind that failed has nowhere for an answer to arrive; an adopted
    // or rebound inbox is the same pid-named path, so a waiting ask is
    // left alone.
    if (!inbox) seam().agents?.inboxLost();

    // After the inbox, before the first report (which carries --inbox).
    await seam().agents?.sessionStarted(ctx);

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

  const running = () => {
    seam().agents?.workStarted();
    send("running");
  };
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

  // The true idle signal: no retry, compaction, or follow-up left. A
  // subagent that wants its parent told about this turn calls
  // notify_parent (kido-agents.ts) itself, on its own judgement; this
  // extension no longer guesses at that on the model's behalf
  // (docs/design.md, "Notifying the parent"), so agent_end's own text is
  // of no further use here and is not read at all.
  pi.on("agent_settled", (_event, ctx) => {
    if (!ctx.isIdle()) return;
    send("idle", { ended: true });
    seam().agents?.turnEnded();
  });

  pi.on("session_shutdown", async (event?: { reason?: string }) => {
    // stopInbox and sessionEnding's synchronous prefix run before this
    // handler's first await, which is what lets ask_agent's inboxOpen()
    // check stand in for "this session is shutting down".
    stopInbox({ keepListening: event?.reason === "reload" });
    stopHeartbeat();
    // Before the removal report: kido must still have a record of this
    // session while the agent half resolves its parent edge and window.
    await seam().agents?.sessionEnding(event?.reason);
    // "reload" is the one reason (measured against pi 0.85.1) that keeps
    // this same process AND this same session id - session_start reruns in
    // the same pi process and ctx.sessionManager.getSessionId() comes back
    // unchanged. Removing the record there is pure loss: the parent's own
    // row would vanish from the sidebar and a child polling for it mid-gap
    // would read a live parent as gone (this is the /reload bug). "quit"
    // ends the record for real, and "new"/"resume"/"fork" each move this
    // process to a NEW session id, so the OLD record must still be removed
    // there or it is a live-pid file Load() never cleans up, permanently
    // claiming this pane alongside the fresh one. This is deliberately not
    // isRunEnding: that gate answers a different question (did the run
    // finish) and already treats "new"/"resume"/"fork" as not run-ending,
    // which is right for an outcome but wrong here, where the record's
    // filename - the session id - is what actually changed.
    if (event?.reason === "reload") return;
    // A session this process never claimed has no record of its own to
    // remove, and the record under that id belongs to somebody still
    // running: send() drops the report for exactly that reason.
    send("idle", { remove: true });
  });
}
