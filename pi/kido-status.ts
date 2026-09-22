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
import { randomUUID } from "node:crypto";
import { accessSync, constants, unlinkSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { delimiter, isAbsolute, join } from "node:path";

// Generated once per process, not per session, so a /reload does not
// change it under a child that recorded it as a ParentInstance. Read by
// kido-agents.ts through the seam, never by importing it: a second
// evaluation of this file would generate a second id.
const INSTANCE = randomUUID();

// Set by `kido spawn` in a subagent's environment; absent for a root
// session. kido-agents.ts reads the same three itself.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_INSTANCE = process.env.KIDO_AGENT_PARENT_INSTANCE || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// HEARTBEAT_MS is how often a session re-sends its status while it is
// "running", bypassing send()'s coalescing so kido's staleness check has
// a real last-seen time (docs/design.md, "Heartbeat and staleness").
// Read once at module scope; a test re-imports the module to change it.
const HEARTBEAT_MS = Number(process.env.KIDO_HEARTBEAT_MS) || 30000;

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

// RunKidoResult's error branch carries timedOut so a caller can tell a
// definite failure apart from a run that may still have done its work.
export type RunKidoResult = { out: string } | { error: string; timedOut?: boolean };

// Anything larger than this is dropped rather than buffered.
const MAX_PROMPT_BYTES = 1024 * 1024;

// The inbox envelope version this extension speaks (see internal/msg),
// reported with --protocol alongside --inbox.
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
// and its own INSTANCE. kido-agents.ts therefore imports nothing but
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
  // This process's own generated instance id, as reported with --instance.
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

  // null whenever the last reported status was not "running".
  let heartbeatTimer: NodeJS.Timeout | null = null;

  const deliver = (text: string): void => {
    // A delivered message is about to produce a turn, so the idle
    // self-exit timer must not fire in the gap between this call and
    // pi's own turn_start.
    seam().agents?.workStarted();
    // Unconditionally "followUp", idle or not. pi's docs: "When not
    // streaming, the message is sent immediately and triggers a new turn";
    // deliverAs is only consulted while streaming, where "followUp"
    // "[w]aits for agent to finish all tools", as opposed to "steer"
    // redirecting the running turn.
    pi.sendUserMessage(text, { deliverAs: "followUp" });
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
  const send = (
    status: Status,
    opts: { ended?: boolean; remove?: boolean; heartbeat?: boolean } = {},
  ): void => {
    if (!kido || !sessionId) return;

    // activity and model join the key, or a set_status or model switch
    // that leaves the status unchanged would be dropped.
    const key = [status, title ?? "", activity, model ?? "", opts.ended ? 1 : 0, opts.remove ? 1 : 0].join("|");
    // The report that carries --inbox must never be coalesced away:
    // session_start awaits the socket bind, and another handler can send
    // an equivalent "idle" report inside that window.
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
      // Always sent: an omitted --activity is carried forward by kido, an
      // empty one clears it.
      "--activity",
      activity,
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
    // Reported once; kido carries both forward.
    if (pendingInbox && inboxPath) {
      args.push("--inbox", inboxPath, "--protocol", String(PROTOCOL_VERSION));
      inboxReported = true;
    }

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
        // Unknown, not failed: kido may already have done its work.
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
      // A child that exits before reading all of stdin turns the write
      // into EPIPE; unhandled, that is an uncaught exception on this
      // process.
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input ?? "");
    });
  };

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
    // A /reload re-runs this handler: drop the old timer and inbox first.
    stopHeartbeat();
    stopInbox();
    try {
      await startInbox();
    } catch {
      // no inbox; status reporting carries on regardless
    }
    // A rebind that succeeded lands on the same pid-named path, so a
    // waiting ask is left alone; one that failed has nowhere for an
    // answer to arrive.
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
    stopInbox();
    stopHeartbeat();
    // Before the removal report: kido must still have a record of this
    // session while the agent half resolves its parent edge and window.
    await seam().agents?.sessionEnding(event?.reason);
    send("idle", { remove: true });
  });
}
