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
 *   `list_agents()`, `set_status(activity)` and `message_agent(to, message,
 *   replyTo?)` all shell out to kido (`kido agents --json`, `kido
 *   agent-status --activity`, `kido message [--reply-to] <to>`) the same
 *   way status reporting does. They register unconditionally at factory
 *   time - before session_start has resolved kido or a session id - and
 *   simply no-op at call time until those are known, since pi may run the
 *   factory in invocations that never start a session. What message_agent
 *   accepts and how kido resolves it is in pi/README.md.
 *
 * Inbox:
 *   On session start the extension asks kido where to bind — `kido inbox-path
 *   <pid>` prints an absolute socket path, creating its directory, and fails if
 *   the path would be too long — binds a unix STREAM socket there and reports
 *   the path once, with `--inbox <path> --protocol <n>` on the first status
 *   report; kido carries both values forward. A client writes a prompt as
 *   UTF-8 with no framing, half-closes its write half, reads `ok\n` and
 *   closes. The payload is either raw v0 text or a v1 JSON envelope (kido's
 *   own inbox protocol - see internal/msg and AGENTS.md); either way the
 *   text ends up delivered as a real user message. Any failure here is
 *   silent and leaves status reporting working.
 *
 * Install:
 *   mkdir -p ~/.pi/agent/extensions
 *   cp kido-status.ts ~/.pi/agent/extensions/
 *
 * Or, for a one-off run:  pi -e /path/to/kido-status.ts
 */

import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, constants, unlinkSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
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

// Anything larger than this is dropped rather than buffered.
const MAX_PROMPT_BYTES = 1024 * 1024;

// The inbox envelope version this extension speaks (see internal/msg and
// AGENTS.md's note on the protocol). Reported with --protocol alongside
// --inbox so kido only ever sends an envelope to a receiver that has said
// it understands one.
const PROTOCOL_VERSION = 1;

type EnvelopeKind = "message" | "ask" | "reply" | "notice";

interface Envelope {
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
function parseEnvelope(text: string): Envelope | null {
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

// Where to bind is kido's decision, not ours: it owns the state-directory
// precedence and the sun_path length budget. It exits non-zero (printing
// nothing) when the path would not fit or the name is bad; then we simply run
// without an inbox. Run synchronously: one fast subprocess, once per session
// start.
function askInboxPath(kido: string, name: string): string | null {
  try {
    const out = execFileSync(kido, ["inbox-path", name], {
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
      timeout: 2000, // a hung kido must not stall session start
    }).trim();
    return out && isAbsolute(out) ? out : null;
  } catch {
    return null; // no such subcommand, non-zero exit, timeout — no inbox
  }
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
      try {
        sock.end("ok\n");
      } catch {
        // client may already be gone
      }
      const prompt = text.trim();
      if (!prompt) return;
      // kind is only ever "message" today - kido message is the only
      // sender - so any v1 envelope is delivered as its text. ask/reply
      // threading and notices are later phases.
      const env = parseEnvelope(prompt);
      const body = env ? env.text : prompt;
      if (!body) return;
      deliver(body);
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

  const startInbox = async (bin: string): Promise<void> => {
    // Named after this process's pid, which is unique among live processes by
    // construction: a leftover file at that path cannot belong to a running
    // listener, so it is always safe to remove — no liveness probe needed.
    const path = askInboxPath(bin, String(process.pid));
    if (!path) return;
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

    try {
      const child = spawn(kido, args, { stdio: "ignore", detached: true });
      // Mandatory: an unhandled spawn error would be an uncaught exception.
      child.on("error", () => {});
      // Detached so that Ctrl+C on pi's process group does not kill the report.
      child.unref();
    } catch {
      // never let a spawn failure reach pi
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
      if (!kido) {
        return { content: [{ type: "text", text: "[]" }], details: [] };
      }
      try {
        // kido resolves the session from $TMUX_PANE, inherited by execFileSync.
        const out = execFileSync(kido, ["agents", "--json"], {
          stdio: ["ignore", "pipe", "ignore"],
          encoding: "utf8",
          timeout: 2000,
        });
        const agents = out.trim() ? JSON.parse(out) : [];
        return { content: [{ type: "text", text: JSON.stringify(agents) }], details: agents };
      } catch {
        return { content: [{ type: "text", text: "[]" }], details: [] };
      }
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
      if (params.replyTo) args.push("--reply-to", params.replyTo);
      // "--" first: to is model-authored, and one beginning with a dash
      // would otherwise be parsed as a kido flag and reported as "flag
      // provided but not defined" rather than as no such agent.
      args.push("--", params.to);
      try {
        // kido resolves both the caller (via $TMUX_PANE) and the target's
        // tmux session from execFileSync's inherited environment.
        const out = execFileSync(kido, args, {
          input: params.message,
          stdio: ["pipe", "pipe", "pipe"],
          encoding: "utf8",
          timeout: 5000,
        });
        // kido message prints one line saying what actually happened -
        // delivered by inbox, or pasted into the target's pane - which is
        // exactly what the model needs to know, not just "ok".
        const text = out.trim() || `message delivered to ${params.to}`;
        return { content: [{ type: "text", text }], details: {} };
      } catch (err) {
        const stderr = (err as { stderr?: Buffer | string })?.stderr;
        const detail = stderr ? stderr.toString().trim() : err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `could not message ${params.to}: ${detail}` }],
          details: {},
        };
      }
    },
  };

  pi.registerTool(listAgentsTool);
  pi.registerTool(setStatusTool);
  pi.registerTool(messageAgentTool);

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
      await startInbox(kido);
    } catch {
      // no inbox; status reporting carries on regardless
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

  pi.on("session_shutdown", () => {
    stopInbox();
    send("idle", { remove: true });
  });
}
