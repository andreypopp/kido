import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { accessSync, constants, unlinkSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { delimiter, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

// Set by `kido spawn_subagent` in a subagent's environment; absent for a root session.
const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_SESSION = process.env.KIDO_AGENT_PARENT_SESSION || undefined;
const DEPTH = process.env.KIDO_AGENT_DEPTH ? Number(process.env.KIDO_AGENT_DEPTH) : undefined;

// Read once at module scope; a test re-imports the module to change it.
const HEARTBEAT_MS = Number(process.env.KIDO_HEARTBEAT_MS) || 30000;

// A timeout here is not a refusal: State.record's write path (lib/state.ml) is what actually decides who holds the id.
const CLAIM_TIMEOUT_MS = 5000;

export type Status = "running" | "waiting" | "compacting" | "idle";

export type RunKidoResult = { ok: true; out: string } | { ok: false; error: string; code?: number };

// lib/reporting.ml's exit code when another live process already holds this session id.
const EXIT_SESSION_HELD = 6;

const MAX_PROMPT_BYTES = 1024 * 1024;

export type DeliverAs = "followUp" | "steer";

export type Sender =
  | { kind: "agent"; session: string; name?: string; pane?: string }
  | { kind: "kido"; name: string }
  | { kind: "human"; pane: string };

export type Envelope = { id: string; from: Sender; text: string } & (
  | { kind: "message" | "ask" | "notice" | "steer" | "interrupt" | "stop" }
  | { kind: "reply"; replyTo: string }
  | { kind: "stream"; run: string; output: string }
  | { kind: "unrecognised"; claimed: string }
);

// Mirrors Msg.parse (lib/msg.ml): a payload is a v1 envelope only if it parses as a
// JSON object carrying both "v" and "kind"; anything else is v0 raw prompt text.
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
  // Coerced rather than required, to match Msg.parse, which reads a missing string field as "".
  const str = (v: unknown): string => (typeof v === "string" ? v : "");
  const from = (typeof obj.from === "object" && obj.from !== null ? obj.from : {}) as Record<string, unknown>;
  const [session, name, pane] = [str(from.session), str(from.name), str(from.pane)];
  const sender: Sender = session
    ? { kind: "agent", session, name: name || undefined, pane: pane || undefined }
    : name
      ? { kind: "kido", name }
      : { kind: "human", pane };
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
    case "stream":
      return { ...base, kind, run: str(obj.run), output: str(obj.output) };
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

// Detached and stdio-ignored, so a Ctrl+C on pi's process group does not kill it.
// Both failure paths are swallowed - the synchronous throw and the async "error"
// event - since an unhandled "error" event is an uncaught exception on this process.
function spawnDetached(cmd: string, args: string[]): void {
  try {
    const child = spawn(cmd, args, { stdio: "ignore", detached: true });
    child.on("error", () => {});
    child.unref();
  } catch {}
}

// The seam between the two extensions is a pair of slots on globalThis, reached
// through a global-registry symbol rather than module scope or an import: pi
// (measured against 0.85.1) evaluates each extension in a module registry of its
// own, so importing this file from kido-agents.ts would evaluate it a second time
// with its own scope and state. kido-agents.ts therefore imports only types from here.
export interface SessionContext {
  abort(): void;
  shutdown(): void;
  // Read live, per arriving envelope: only an idle session has to be woken through a prompt.
  isIdle(): boolean;
  // Absent in a headless session.
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
  setWidget(key: string, content: string[] | undefined, options?: { placement?: "aboveEditor" | "belowEditor" }): void;
  notify?(message: string, type?: string): void;
  // Missing before pi 0.87.1.
  addAutocompleteProvider?(factory: (current: CompletionProvider) => CompletionProvider): void;
}

export type ShutdownReason = "quit" | "reload" | "new" | "resume" | "fork";

// Accessors, not shared variables, so there is exactly one owner of each.
export interface StatusHost {
  kidoPath(): string | null;
  // Null until session_start has resolved one, and forever in a pi with no kido or
  // no tmux. kido-agents.ts checks it against KIDO_AGENT_RUN_ID to tell a real
  // subagent from a process that merely inherited one's environment.
  sessionId(): string | null;
  status(): Status;
  // Synchronous on purpose: ask_agent checks it with no await between the check and
  // registering its waiter.
  inboxOpen(): boolean;
  setActivity(text: string): void;
  deliver(text: string, deliverAs?: DeliverAs): void;
  runKido(args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult>;
  spawnDetached(cmd: string, args: string[]): void;
}

// Hooks rather than the agent half's own pi.on handlers, because the order
// within session_start and session_shutdown is load-bearing and nothing says
// pi runs two extensions' handlers in any given order.
export interface AgentHooks {
  // Before the kido lookup: a /reload brings a fresh ctx and the old reference
  // must not survive it even in a session with no kido.
  sessionStarting(ctx: SessionContext): void;
  // Called once the inbox is bound and before the first status report.
  sessionStarted(): Promise<void>;
  inboxLost(): void;
  // Called after the inbox is down and before the removal report.
  sessionEnding(reason?: ShutdownReason): Promise<void>;
  // Resets the idle self-exit timer on every signal kido-status.ts already
  // treats as "this session has work to do", so it never fires mid-turn.
  workStarted(): void;
  handleEnvelope(env: Envelope): Promise<"ok" | "refused">;
}

// Either slot may be null: an extension loaded without its companion finds the
// other empty. Last writer wins, which is what a /reload wants.
export interface Seam {
  host: StatusHost | null;
  agents: AgentHooks | null;
}

// Held on globalThis, not module scope: a /reload re-evaluates this file but keeps
// the process and the pid-keyed socket path. In the gap between a reload's shutdown
// and the reloaded module's session_start the hold is "parked", and connections
// wait rather than being refused.
type InboxHold = { server: Server; path: string } &
  ({ state: "owned"; handler: (sock: Socket) => void } | { state: "parked"; waiting: Socket[] });

const INBOX_SLOT = Symbol.for("kido.pi.extension.inbox");

function heldInbox(): InboxHold | null {
  return (globalThis as unknown as Record<symbol, InboxHold | undefined>)[INBOX_SLOT] ?? null;
}

function setHeldInbox(hold: InboxHold | null): void {
  (globalThis as unknown as Record<symbol, InboxHold | undefined>)[INBOX_SLOT] = hold ?? undefined;
}

// Outlives every module that owns the inbox: reads the slot per connection rather
// than closing over a handler, so a parked socket (no data listener attached yet)
// loses nothing across a /reload.
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

const SEAM = Symbol.for("kido.pi.extension.seam");

function seam(): Seam {
  const g = globalThis as unknown as Record<symbol, Seam | undefined>;
  return (g[SEAM] ??= { host: null, agents: null });
}

// One copy of each extension per process: pi dedupes extensions by real path only
// (resource-loader.js mergePaths, measured against 0.87.1), so kido's --extension
// copy and one an earlier kido left in ~/.pi/agent/extensions are two extensions to
// it, and the second copy's tools would fail to load as conflicts. The first copy
// pi runs keeps the slot; a /reload runs the same file again and finds it already its own.
const COPY_SLOT = Symbol.for("kido.pi.extension.status.copy");

function isFirstCopy(): boolean {
  const path = fileURLToPath(import.meta.url);
  const g = globalThis as unknown as Record<symbol, string | undefined>;
  return (g[COPY_SLOT] ??= path) === path;
}

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
  let kido: string | null = null;
  // Null with no kido or no tmux, and once kido has answered that another live
  // process holds this session id - this pi is then not tracked, and must neither
  // report nor bind an inbox for the rest of the session.
  let reporter: { kido: string; sessionId: string } | null = null;
  let title: string | undefined;
  let activity = "";
  let model: string | undefined;
  let lastKey: string | null = null;
  let current: Status = "idle";
  let beforeCompact: Status = "idle";

  let heartbeatTimer: NodeJS.Timeout | null = null;

  // pi drains followUp only once the agent has decided to stop; "steer" is drained
  // inside the loop and joins the run already under way. deliverAs is only consulted
  // while streaming: pi sends immediately when the session is idle.
  const deliver = (text: string, deliverAs: DeliverAs = "followUp"): void => {
    // Must run before pi.sendUserMessage: the idle self-exit timer must not fire in
    // the gap between this call and pi's own turn_start.
    seam().agents?.workStarted();
    pi.sendUserMessage(text, { deliverAs });
  };

  // With no agent half loaded, an envelope still reaches the model as its own text
  // rather than being dropped.
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
      } catch {}
    });
  };

  // keepListening is the /reload case: the socket stays bound and the server is
  // handed to the reloaded module through the slot. Either way this module's own
  // handler goes null synchronously, which is what inboxOpen() reads as
  // "this session is shutting down".
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

  // Picks up a listener a reload handed forward: same socket, no rebind, and
  // whatever arrived in the gap is handled now, answer included.
  const adoptInbox = (): boolean => {
    const hold = heldInbox();
    if (hold?.state !== "parked") return false;
    setHeldInbox({ server: hold.server, path: hold.path, state: "owned", handler: onConnection });
    for (const sock of hold.waiting.splice(0)) onConnection(sock);
    return true;
  };

  // kido dials the path only a live handler answers; a reload's gap or a torn-down
  // session must read as closed even though the socket file may still exist.
  const inboxOpen = (): boolean => {
    const hold = heldInbox();
    return hold?.state === "owned" && hold.handler === onConnection;
  };

  const startInbox = async (): Promise<void> => {
    // A refusal from kido means no inbox. The path is named after this process's
    // pid, so a leftover file there cannot belong to a running listener.
    const asked = await runKido(["inbox-path", String(process.pid)], { timeoutMs: 2000 });
    if (!asked.ok) return;
    const path = asked.out;
    if (!path || !isAbsolute(path)) return;
    try {
      unlinkSync(path);
    } catch {}
    const server = createServer({ allowHalfOpen: true }, dispatchInbox);
    server.on("error", () => {});
    const bound = await new Promise<boolean>((resolve) => {
      server.once("error", () => resolve(false));
      server.listen(path, () => resolve(true));
    });
    if (!bound) return; // never publish a path we are not listening on
    server.unref(); // never hold pi's event loop open
    setHeldInbox({ server, path, state: "owned", handler: onConnection });
  };

  const startHeartbeat = (): void => {
    if (heartbeatTimer) return;
    heartbeatTimer = setInterval(() => report({ kind: "heartbeat" }), HEARTBEAT_MS);
    heartbeatTimer.unref(); // a hung kido must never hold pi's event loop open
  };
  const stopHeartbeat = (): void => {
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  };

  // Shared by report() and by the claim session_start makes with it, awaited rather
  // than fired and forgotten there. Every report is whole: title, model and inbox
  // ride on every call, empty when there is none, since kido carries no field
  // forward between reports.
  const statusArgs = (sessionId: string, status: Status, opts: { ended?: boolean; remove?: boolean; inbox: string } = { inbox: "" }): string[] => {
    const args = [
      "agent-status",
      "--agent",
      "pi",
      "--session",
      sessionId,
      "--status",
      status,
      "--activity",
      activity,
      "--title",
      title ?? "",
      "--model",
      model ?? "",
      "--inbox",
      opts.inbox,
    ];
    if (PARENT_PID !== undefined) args.push("--parent-pid", String(PARENT_PID));
    if (PARENT_SESSION) args.push("--parent-session", PARENT_SESSION);
    if (DEPTH !== undefined) args.push("--depth", String(DEPTH));
    if (opts.ended) args.push("--ended");
    if (opts.remove) args.push("--remove");
    return args;
  };

  // "settled" and "removed" are always idle, so their status is not a separate
  // thing that could disagree with them.
  type Report = { kind: "status"; status: Status } | { kind: "heartbeat" } | { kind: "settled" } | { kind: "removed" };

  // Fire-and-forget. Coalesced: identical consecutive reports are dropped, except a
  // heartbeat re-send. The inbox path joins the coalescing key, so the report that
  // first carries a freshly bound one is never dropped as a duplicate of an idle
  // report already sent without it.
  const report = (r: Report): void => {
    if (!reporter) return;
    const status = r.kind === "heartbeat" ? current : r.kind === "status" ? r.status : "idle";
    const ended = r.kind === "settled";
    const remove = r.kind === "removed";
    const inboxPath = inboxOpen() ? (heldInbox()?.path ?? "") : "";

    const key = [status, title ?? "", activity, model ?? "", inboxPath, ended ? 1 : 0, remove ? 1 : 0].join("|");
    if (r.kind !== "heartbeat" && key === lastKey) return;
    if (r.kind !== "heartbeat") lastKey = key;
    current = status;
    if (status === "running") startHeartbeat();
    else stopHeartbeat();

    spawnDetached(reporter.kido, statusArgs(reporter.sessionId, status, { ended, remove, inbox: inboxPath }));
  };

  // Awaited but never blocking the event loop: a blocked process cannot accept an
  // inbox connection. On failure it yields the line kido printed on stderr, the
  // only part a model can act on.
  const runKido = (args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult> => {
    if (!kido) return Promise.resolve({ ok: false, error: "kido is not on PATH" });
    return new Promise((resolve) => {
      const child = spawn(kido as string, args, { stdio: ["pipe", "pipe", "pipe"] });
      const finish = (result: RunKidoResult): void => {
        clearTimeout(timer);
        resolve(result);
      };
      const timer = setTimeout(() => {
        child.kill();
        // Unknown, not failed: kido may already have done its work.
        finish({ ok: false, error: `kido ${args[0]} timed out after ${opts.timeoutMs}ms` });
      }, opts.timeoutMs);
      timer.unref(); // a hung kido must never hold pi's event loop open

      const stdout: Buffer[] = [];
      const stderr: Buffer[] = [];
      child.stdout?.on("data", (c: Buffer) => stdout.push(c));
      child.stderr?.on("data", (c: Buffer) => stderr.push(c));
      child.on("error", (err) => finish({ ok: false, error: err instanceof Error ? err.message : String(err) }));
      child.on("close", (code) => {
        if (code === 0) {
          finish({ ok: true, out: Buffer.concat(stdout).toString("utf8").trim() });
        } else {
          const errText = Buffer.concat(stderr).toString("utf8").trim();
          finish({ ok: false, error: errText || `kido ${args[0]} exited with code ${code}`, code: code ?? undefined });
        }
      });
      // A child exiting before reading all of stdin turns the write into an EPIPE,
      // an uncaught exception here if unhandled.
      child.stdin?.on("error", () => {});
      child.stdin?.end(opts.input ?? "");
    });
  };

  seam().host = {
    kidoPath: () => kido,
    sessionId: () => reporter?.sessionId ?? null,
    status: () => current,
    inboxOpen,
    setActivity: (text: string) => {
      // Two writes of one fact: `kido set_status` updates the record without
      // disturbing anything else on it, and the local variable is what every later
      // `kido agent-status` report carries - leaving it stale would have the next
      // report clear the activity this one just set.
      activity = text;
      if (kido) spawnDetached(kido, ["set_status", "--", activity]);
    },
    deliver,
    runKido,
    spawnDetached,
  };

  pi.on("session_start", async (_event, ctx) => {
    // Before the kido-on-PATH check: a /reload brings a fresh ctx.
    seam().agents?.sessionStarting(ctx);
    kido = process.env.TMUX_PANE ? findKido() : null;
    reporter = null;
    if (!kido) return;
    const sessionId = ctx.sessionManager.getSessionId();
    title = ctx.sessionManager.getSessionName() || undefined;
    model = ctx.model?.id;
    lastKey = null;
    stopHeartbeat();

    // The claim is this same first report, awaited so an EXIT_SESSION_HELD refusal
    // can be read: a session id another live process holds is not this one's to
    // report under, and every later report is fire-and-forget precisely because
    // this one settled the question.
    if (sessionId) {
      const claim = await runKido(statusArgs(sessionId, "idle"), { timeoutMs: CLAIM_TIMEOUT_MS });
      if (!claim.ok && claim.code === EXIT_SESSION_HELD) {
        try {
          ctx.ui?.notify?.(`kido: ${claim.error}`, "warning");
        } catch {}
        return;
      }
      lastKey = null; // the claim is not a report the coalescing may match against
      reporter = { kido, sessionId };
    }

    // A /reload re-runs this handler: take over the listener it handed forward.
    // Anything else binds afresh.
    if (!adoptInbox()) {
      stopInbox();
      try {
        await startInbox();
      } catch {}
    }
    if (!inboxOpen()) seam().agents?.inboxLost();

    // After the inbox, before the first report (which carries --inbox).
    await seam().agents?.sessionStarted();

    report({ kind: "status", status: "idle" });
  });

  pi.on("session_info_changed", (event) => {
    title = event.name || undefined;
    report({ kind: "status", status: current });
  });

  pi.on("model_select", (event) => {
    model = event.model.id;
    report({ kind: "status", status: current });
  });

  const running = () => {
    seam().agents?.workStarted();
    report({ kind: "status", status: "running" });
  };
  pi.on("agent_start", running);
  pi.on("turn_start", running);
  pi.on("tool_execution_start", running);
  pi.on("tool_call", running);

  // Blocking extension UI prompts: pi is waiting for the user, not working.
  pi.on("ui_prompt_start", () => report({ kind: "status", status: "waiting" }));
  // A prompt can also be raised while pi is idle (an extension command calling
  // ctx.ui.select(), say); reporting "running" would then stick forever.
  pi.on("ui_prompt_end", (_event, ctx) => {
    report({ kind: "status", status: ctx.isIdle() ? "idle" : "running" });
  });

  pi.on("session_before_compact", () => {
    beforeCompact = current;
    report({ kind: "status", status: "compacting" });
  });
  // Restore whatever we reported before compaction started: a manual /compact
  // can happen while idle, and agent_settled would not fire afterwards to
  // correct a blind "running".
  const restoreBeforeCompact = () => report({ kind: "status", status: beforeCompact });
  pi.on("session_compact", restoreBeforeCompact);
  pi.on("session_compact_failed", restoreBeforeCompact);

  // The true idle signal: no retry, compaction, or follow-up left.
  pi.on("agent_settled", (_event, ctx) => {
    if (!ctx.isIdle()) return;
    report({ kind: "settled" });
  });

  pi.on("session_shutdown", async (event?: { reason?: ShutdownReason }) => {
    // Both run synchronously before this handler's first await, which is what lets
    // ask_agent's inboxOpen() check stand in for "this session is shutting down".
    stopInbox({ keepListening: event?.reason === "reload" });
    stopHeartbeat();
    // Before the removal report: kido must still have a record of this session while
    // the agent half resolves its parent edge and window.
    await seam().agents?.sessionEnding(event?.reason);
    // "reload" (measured against pi 0.85.1) keeps this same process and session id -
    // removing the record there would vanish the parent's own sidebar row. "quit",
    // "new", "resume" and "fork" all end or move this process to a new session id, so
    // the old record must still be removed.
    if (event?.reason === "reload") return;
    report({ kind: "removed" });
  });
}
