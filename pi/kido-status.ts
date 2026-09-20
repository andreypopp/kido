/**
 * kido-status — report this pi session's live status to kido, and accept
 * prompts delivered from outside the session.
 *
 * kido is a tmux sidebar that shows the live status of coding agents. This
 * extension makes a pi session visible in that sidebar by shelling out to:
 *
 *   kido agent-status --agent pi --session <id> --status running|waiting|compacting|idle
 *                     [--title <text>] [--ended] [--remove] [--inbox <path>]
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
 *     status/title actually differs from what was last sent.
 *
 * Inbox:
 *   On session start the extension binds a unix STREAM socket under the kido
 *   state directory and reports its path once, with `--inbox <path>` on the
 *   first status report; kido carries that value forward. A client writes a
 *   prompt as UTF-8 with no framing, half-closes its write half, reads `ok\n`
 *   and closes; the prompt is then delivered as a real user message. Any
 *   failure here is silent and leaves status reporting working.
 *
 * Install:
 *   mkdir -p ~/.pi/agent/extensions
 *   cp kido-status.ts ~/.pi/agent/extensions/
 *
 * Or, for a one-off run:  pi -e /path/to/kido-status.ts
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { accessSync, constants, mkdirSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { connect, createServer, type Server, type Socket } from "node:net";
import { delimiter, join } from "node:path";

type Status = "running" | "waiting" | "compacting" | "idle";

// A unix socket path is limited to ~104 bytes on macOS (sun_path), so the
// bound path has to stay short: a truncated session id, not the full one.
const MAX_SOCKET_PATH = 100;
// Anything larger than this is dropped rather than buffered.
const MAX_PROMPT_BYTES = 1024 * 1024;

function stateDir(): string {
  const explicit = process.env.KIDO_STATE_DIR;
  if (explicit) return explicit;
  const xdg = process.env.XDG_STATE_HOME;
  if (xdg) return join(xdg, "kido");
  return join(homedir(), ".local", "state", "kido");
}

// Resolve to `true` if something is already listening on `path`.
function isLive(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = connect(path);
    const done = (live: boolean) => {
      probe.destroy();
      resolve(live);
    };
    probe.on("connect", () => done(true));
    probe.on("error", () => done(false));
    probe.setTimeout(500, () => done(true)); // unclear: treat as live, don't clobber
  });
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

export default function (pi: ExtensionAPI) {
  let kido: string | null = null;
  let sessionId: string | null = null;
  let title: string | undefined;
  let lastKey: string | null = null;
  let current: Status = "idle";
  let beforeCompact: Status = "idle";

  let inbox: Server | null = null;
  let inboxPath: string | null = null;
  let inboxReported = false;
  // The ctx handed to a handler belongs to the session that is live at that
  // moment; a socket callback has none of its own, so keep the latest.
  let lastCtx: ExtensionContext | null = null;

  const deliver = (text: string): void => {
    // Delivery mode from the session's own state. Idle: a plain send, which
    // triggers a turn immediately. Mid-stream: "followUp", which waits until
    // the agent has no tool calls left — "steer" would redirect the running
    // turn before its next LLM call, hijacking work the user is watching,
    // whereas an externally injected prompt should queue behind it.
    try {
      if (lastCtx?.isIdle() ?? true) {
        pi.sendUserMessage(text);
      } else {
        pi.sendUserMessage(text, { deliverAs: "followUp" });
      }
    } catch {
      // A turn can start between isIdle() and the send, and a plain send while
      // streaming throws. Retry once in the mode that is always legal.
      try {
        pi.sendUserMessage(text, { deliverAs: "followUp" });
      } catch {
        // give up quietly
      }
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
      try {
        sock.end("ok\n");
      } catch {
        // client may already be gone
      }
      const prompt = text.trim();
      if (!prompt) return;
      deliver(prompt);
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

  const startInbox = async (id: string): Promise<void> => {
    const dir = join(stateDir(), "inbox");
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    // Short and unique enough: a session id prefix. If that name is taken by a
    // live listener (a second pi on the same session, or a /reload whose old
    // server is still bound), fall back to the pid and then to the clock.
    const names = [
      `${id.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 8)}.sock`,
      `${process.pid}.sock`,
      `${process.pid}-${Date.now().toString(36).slice(-4)}.sock`,
    ];
    for (const name of names) {
      const path = join(dir, name);
      if (Buffer.byteLength(path) > MAX_SOCKET_PATH) return;
      // A leftover file from a pi that died without cleaning up is safe to
      // remove — but only once we know nothing is listening on it.
      if (await isLive(path)) continue;
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
      if (!bound) continue;
      server.unref(); // never hold pi's event loop open
      inbox = server;
      inboxPath = path;
      inboxReported = false;
      return;
    }
  };

  // Fire-and-forget. Coalesced: identical consecutive reports are dropped.
  const send = (
    status: Status,
    opts: { ended?: boolean; remove?: boolean } = {},
  ): void => {
    if (!kido || !sessionId) return;

    const key = [status, title ?? "", opts.ended ? 1 : 0, opts.remove ? 1 : 0].join("|");
    if (key === lastKey) return;
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
    ];
    if (title) args.push("--title", title);
    if (opts.ended) args.push("--ended");
    if (opts.remove) args.push("--remove");
    // Reported once; kido carries the value forward across later reports.
    if (inboxPath && !inboxReported) {
      args.push("--inbox", inboxPath);
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

  pi.on("session_start", async (_event, ctx) => {
    // Resource lookup belongs here, not in the factory: the factory may run in
    // invocations that never start a session.
    kido = process.env.TMUX_PANE ? findKido() : null;
    if (!kido) return;
    lastCtx = ctx;
    sessionId = ctx.sessionManager.getSessionId() ?? null;
    title = ctx.sessionManager.getSessionName() || undefined;
    lastKey = null;
    // A session switch or /reload re-runs this: drop the old inbox first.
    stopInbox();
    if (sessionId) {
      try {
        await startInbox(sessionId);
      } catch {
        // no inbox; status reporting carries on regardless
      }
    }
    // Awaited before the first report so that report can carry --inbox; a
    // later one would be coalesced away, the status not having changed.
    send("idle");
  });

  pi.on("session_info_changed", (event) => {
    title = event.name || undefined;
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
    lastCtx = ctx;
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
    lastCtx = ctx;
    if (!ctx.isIdle()) return;
    send("idle", { ended: true });
  });

  pi.on("session_shutdown", () => {
    stopInbox();
    send("idle", { remove: true });
  });
}
