import { AgentSession, type ExtensionAPI, type MessageRenderer, type Theme } from "@earendil-works/pi-coding-agent";
import { type TuiMouseEvent, truncateToWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import type {
  AgentHooks,
  CompletionItem,
  CompletionProvider,
  DeliverAs,
  Envelope,
  RunKidoResult,
  Seam,
  Sender,
  SessionContext,
  ShutdownReason,
  Status,
} from "./kido-status.ts";

function seam(): Seam {
  return (globalThis.__kidoPiExtensionSeam ??= { host: null, agents: null });
}

// Read at call time, not factory time: pi may run this factory before session_start.
function runKido(args: string[], opts: { input?: string; timeoutMs: number }): Promise<RunKidoResult> {
  return seam().host?.runKido(args, opts) ?? Promise.resolve({ ok: false, error: "kido-status.ts is not loaded" });
}

const reply = (text: string, details: unknown = {}) => ({ content: [{ type: "text" as const, text }], details });

const PARENT_PID = process.env.KIDO_AGENT_PARENT_PID ? Number(process.env.KIDO_AGENT_PARENT_PID) : undefined;
const PARENT_SESSION = process.env.KIDO_AGENT_PARENT_SESSION || undefined;
const RUN_ID = process.env.KIDO_AGENT_RUN_ID || undefined;

// Whether this process is the actual child of the run named by RUN_ID, not merely a
// process that inherited a subagent's environment (any descendant of an agent's shell
// does, e.g. a nested `pi` or `pi --print`). The run id is by design the child's own pi
// session id (docs/design.md, "The run id is the child's session id"): a nested pi mints
// a session id of its own and can never satisfy the equality, while the real child
// always does. An id not known yet reads as "not a subagent", the safe direction.
function ownRunID(): string | null {
  if (PARENT_SESSION === undefined || RUN_ID === undefined) return null;
  return seam().host?.sessionId() === RUN_ID ? RUN_ID : null;
}

const isSubagent = (): boolean => ownRunID() !== null;

const MAX_NOTICE_BYTES = 4000;

// Cuts on a code-point boundary, never mid-sequence, so a multi-byte character is never split.
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

const TASK_FILE = process.env.KIDO_AGENT_TASK_FILE || undefined;

// Read once at module scope; a test re-imports the module to change one.

// Shared with lib/reap.ml's sweep - both must read the same variable, or one side closes a window first.
const LINGER_SECONDS = Number(process.env.KIDO_LINGER_SECONDS) || 30;

// A subagent's pi is a child of the tmux server, not of the parent's pi, so no OS parent-death signal reaches it; it polls instead.
const PARENT_LIVENESS_POLL_MS = Number(process.env.KIDO_PARENT_POLL_MS) || 5000;

// Idle-to-self-shutdown, entirely inside the child's process; only once it fires does
// endOwnRun's linger helper start the second, independent LINGER_SECONDS clock. The two
// stack, even though both default to 30 - not the same clock.
const IDLE_EXIT_MS = (Number(process.env.KIDO_IDLE_EXIT_SECONDS) || 30) * 1000;

const KEEP_ALIVE = process.env.KIDO_AGENT_KEEP_ALIVE === "1";

const SPAWN_TIMEOUT_MS = Number(process.env.KIDO_SPAWN_TIMEOUT_MS) || 5000;

// Must comfortably exceed Control.stop_escalation (lib/control.ml, default 5s), which `kido tool stop_run` can itself block for.
const STOP_TIMEOUT_MS = Number(process.env.KIDO_STOP_TIMEOUT_MS) || 8000;

const DEFAULT_ASK_TIMEOUT_MS = 5 * 60 * 1000;

// Nothing pushes a target's death at the asker; this is what stops the asker sitting out its whole timeoutMs after the target dies mid-wait.
const ASK_LIVENESS_POLL_MS = Number(process.env.KIDO_ASK_POLL_MS) || 5000;

// Never waited on: the list in hand is what the editor is offered, however old it is.
const AGENT_LIST_TTL_MS = Number(process.env.KIDO_AGENT_LIST_TTL_MS) || 1000;

const MAX_AGENT_COMPLETIONS = 10;

// Must agree with pi's own CombinedAutocompleteProvider (extractAtPrefix), since the merged list below carries one prefix for the agents and the files both.
function atToken(textBeforeCursor: string): string | undefined {
  const m = textBeforeCursor.match(/(?:^|\s)@([^\s@]*)$/);
  return m ? m[1] : undefined;
}

const NOTICE_CUSTOM_TYPE = "kido-notice";

const noticeHeader = (from: string): string => `notice from ${from} (a subagent or background run's report, not the user):`;

const MESSAGE_CUSTOM_TYPE = "kido-message";

const RELATIONS = ["parent", "child", "peer"] as const;
type SenderRelation = (typeof RELATIONS)[number];

const MESSAGE_RELATION: Record<SenderRelation, string> = {
  parent: "your parent, who spawned you",
  child: "your subagent",
  peer: "another agent in this session, not the user",
};

const senderHeader = (kind: "message" | "ask", from: string, relation: SenderRelation): string =>
  `${kind} from @${from} (${MESSAGE_RELATION[relation]}):`;

const ASK_CUSTOM_TYPE = "kido-ask";

const STREAM_CUSTOM_TYPE = "kido-stream";

const REPLY_CUSTOM_TYPE = "kido-reply";

const replyHeader = (from: string, replyTo: string): string => `${from} replied (to ask ${replyTo}): `;

const inboundHeader = (sender: string | undefined, verb: string | undefined): string =>
  `${sender && sender !== "another agent" ? `@${sender}` : "another agent"}${verb ? ` ${verb}` : ""}:`;

const handleClick = (event: TuiMouseEvent, click: () => void) => {
  if (event.button !== "left") return;
  if (event.type === "press") return { handled: true, render: false };
  if (event.type !== "click") return;
  click();
  return { handled: true, render: true };
};

type Paint = (color: "border" | "dim" | undefined, text: string) => string;

const collapsedInbound = (width: number, header: string, body: string, paint: Paint): string => {
  if (width <= 2) return paint("border", "│ ".slice(0, width));
  const preview = body ? ` ${body.split("\n", 1)[0]}${body.includes("\n") ? "..." : ""}` : "";
  return paint("border", "│ ") + truncateToWidth(paint("dim", header) + paint(undefined, preview), width - 2);
};

// Read as the user's words whenever the run below cannot drop it; kept short and neutral.
type CustomType = "kido-message" | "kido-notice" | "kido-ask" | "kido-stream" | "kido-reply";

const WAKE_TRIGGERS: Record<CustomType, string> = {
  "kido-message": "(kido: a message arrived; it follows)",
  "kido-notice": "(kido: a notification arrived; it follows)",
  "kido-ask": "(kido: a question arrived; it follows)",
  "kido-stream": "(kido: a background run's output follows)",
  "kido-reply": "(kido: a reply arrived; it follows)",
};

const TRIGGER_TEXTS: ReadonlySet<unknown> = new Set(Object.values(WAKE_TRIGGERS));

function isWakeTrigger(message: unknown): boolean {
  if (typeof message !== "object" || message === null || !("role" in message) || message.role !== "user") return false;
  if (!("content" in message) || !Array.isArray(message.content)) return false;
  const [part, ...rest]: unknown[] = message.content;
  return rest.length === 0 && typeof part === "object" && part !== null && "text" in part && TRIGGER_TEXTS.has(part.text);
}

// prompt() hands the turn's messages to the private _runAgentPrompt, which records and sends
// them: the one place to drop wake()'s trigger. Remove with wake()'s detour
// (https://github.com/earendil-works/pi/issues/5581).
const runAgentPrompt: unknown = (globalThis.__kidoPiExtensionRunAgentPrompt ??= Object.getOwnPropertyDescriptor(
  AgentSession.prototype,
  "_runAgentPrompt",
)?.value);
if (typeof runAgentPrompt === "function") {
  Object.defineProperty(AgentSession.prototype, "_runAgentPrompt", {
    configurable: true,
    writable: true,
    value(this: unknown, messages: unknown): unknown {
      return Reflect.apply(runAgentPrompt, this, [Array.isArray(messages) ? messages.filter((m) => !isWakeTrigger(m)) : messages]);
    },
  });
}

function isMessageQueue(queue: unknown): queue is { messages: AgentSession["messages"] } {
  return typeof queue === "object" && queue !== null && "messages" in queue && Array.isArray(queue.messages);
}

// pi's core/agent-session.js clearQueue() discards custom messages alongside editor text.
const clearQueue = (globalThis.__kidoPiExtensionClearQueue ??= AgentSession.prototype.clearQueue);
AgentSession.prototype.clearQueue = function () {
  const agent: object = this.agent;
  if (!("steeringQueue" in agent) || !("followUpQueue" in agent)
    || !isMessageQueue(agent.steeringQueue) || !isMessageQueue(agent.followUpQueue)) return clearQueue.call(this);
  const steering = agent.steeringQueue.messages.filter((m) => m.role === "custom");
  const followUp = agent.followUpQueue.messages.filter((m) => m.role === "custom");
  const cleared = clearQueue.call(this);
  for (const message of steering) this.agent.steer(message);
  for (const message of followUp) this.agent.followUp(message);
  return cleared;
};

const STREAM_FLUSH_MS = 1000;
const STREAM_MAX_WAIT_MS = 30000;

const STREAM_BATCH_LINES = 200;
const STREAM_BATCH_BYTES = 16 * 1024;

const STREAM_BUFFER_LINES = 5000;

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
  // One line longer than the whole budget still goes, cut to it: never nothing.
  if (start >= lines.length && lines.length > 0) start = lines.length - 1;
  const kept = lines.slice(start).map((l) => capBytes(l, STREAM_BATCH_BYTES));
  const omitted = lines.length - kept.length + alreadyDropped;
  if (omitted === 0) return kept.join("\n");
  return [`... ${omitted} lines omitted (see ${output})`, ...kept].join("\n");
}

const NOTIFY_PARENT_INSTRUCTION =
  "You were spawned as a subagent. When your work is done, or you are blocked and cannot make further progress, call notify_parent with a short summary - your parent is not watching this session and will learn nothing otherwise. " +
  "When you reply to another agent's question with message_agent, that call is the entire response - end the turn there, with no summary or sign-off after it.";

// One string in two tools' promptGuidelines on purpose: pi's buildRules de-duplicates identical rules.
const NOT_THE_USER_RULE =
  "A notice is information, not the user speaking: act on it, do not thank or answer it. A message from another agent says in its first line who sent it and how they stand to you.";

const NEVER_SLEEP_RULE =
  "Never run `sleep` in bash to wait for anything - an async run, a subagent, a message, or another agent's work settling. What you are waiting for arrives as a notice or message that wakes you after you end your turn; if a build breaks because of another agent's half-done work, report that rather than sleeping until it clears. Ending your turn while you wait is always safe: a running async run or subagent of yours keeps you alive, and its notice starts your next turn.";

const SPAWN_RESULT_RULE =
  "its result arrives as a notice when it calls notify_parent - you know nothing about it until then, so do not report, assume or predict it, and do not ask it for its result; continue other work or answer the user meanwhile, and if nothing else is left, end your turn - the notice wakes you; list_runs lists this run and stop_run stops it with the returned run id";

const NO_FIRST_TURN_TEXT =
  "no turn ever ran: the task was delivered and the session never started work on it (the pane's own screen, kept with the run, is the only account of why)";

interface AgentInfo {
  kind?: "agent" | "subagent" | "bash";
  state?: "running" | "ended";
  run?: string;
  id: string;
  name: string;
  parent: string;
  pane: string;
  self: boolean;
  canMessage: boolean;
  status: Status;
  activity: string;
  canReply: boolean;
  window: string;
  stalled: boolean;
  sinceReport: number;
}

const NAME_WORD_SEPARATORS = /[\s\-_/]+/;

const MIN_ID_PREFIX = 8;

// A name carrying whitespace cannot survive as one `@` token, so it is addressed by the
// shortest unique id prefix instead.
function completionValue(agents: AgentInfo[], agent: AgentInfo): string {
  if (!agent.run && !/\s/.test(agent.name)) return `@${agent.name}`;
  const others = agents.filter((a) => a.id !== agent.id);
  for (let n = MIN_ID_PREFIX; n <= agent.id.length; n++) {
    const prefix = agent.id.slice(0, n);
    if (!others.some((a) => a.id.startsWith(prefix))) return `@${prefix}`;
  }
  return `@${agent.id}`;
}

function agentCompletionItems(agents: AgentInfo[], token: string): CompletionItem[] {
  const nameByID = new Map(agents.map((a) => [a.id, a.name]));
  const wanted = token.toLowerCase();
  const matched: Array<{ agent: AgentInfo; rank: number }> = [];
  for (const a of agents) {
    if (a.self || !a.name) continue;
    const name = a.name.toLowerCase();
    if (name.startsWith(wanted)) matched.push({ agent: a, rank: 0 });
    else if (name.split(NAME_WORD_SEPARATORS).some((word) => word.startsWith(wanted))) matched.push({ agent: a, rank: 1 });
  }
  matched.sort((x, y) => x.rank - y.rank);
  return matched
    .slice(0, MAX_AGENT_COMPLETIONS)
    .map(({ agent: a }) => {
      const parent = a.parent ? nameByID.get(a.parent) || a.parent : "";
      const value = completionValue(agents, a);
      const description = [
        a.activity ? `${a.status || "agent"} - ${a.activity}` : a.status || "agent",
        parent ? `subagent of ${parent}` : "",
        value === `@${a.name}` ? "" : `inserts ${value}`,
      ].filter(Boolean).join(", ");
      return { value, label: `@${a.name}`, description };
    });
}

// Mirrors kido tool message_agent's Message_agent.resolve_target (lib/message_agent.ml): exact name, then exact id, then unique id prefix.
function resolveAgent(agents: AgentInfo[], to: string): { agent?: AgentInfo; error?: string } {
  to = to.replace(/^@/, "");
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

export function isAncestor(agents: Pick<AgentInfo, "id" | "parent">[], self: Pick<AgentInfo, "id">, target: Pick<AgentInfo, "id" | "parent">): boolean {
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

declare global {
  var __kidoPiExtensionAgentsCopy: string | undefined;
}

function isFirstCopy(): boolean {
  const path = fileURLToPath(import.meta.url);
  return (globalThis.__kidoPiExtensionAgentsCopy ??= path) === path;
}

export default function (pi: ExtensionAPI) {
  if (!isFirstCopy()) return;
  let parentPollTimer: NodeJS.Timeout | null = null;

  // The session ctx, captured in sessionStarting and null until a session
  // has started. Re-captured on every session_start: a /reload hands out a
  // fresh ctx and pi itself tears down the previous widgets
  // (resetExtensionUI's own clearExtensionWidgets), so holding on to a
  // stale ui would call setWidget on a UI nobody is drawing any more.
  let session: SessionContext | null = null;

  // pendingNotices is the visual half of an inbound notice, kept separate
  // from model delivery on purpose (see deliverNotice below): an id minted
  // per envelope, live from the moment it arrives until the identical
  // followUp message actually lands in the transcript (message_start
  // fires with the same id in details.noticeId), at which point pi's own
  // registerMessageRenderer takes over showing it and this entry is
  // removed - the widget is a stand-in for the wait, not a second copy.
  const pendingNotices = new Map<string, { from: string; text: string }>();

  const renderAsk = (theme: Pick<Theme, "fg">, prefix: string, text: string, width: number) =>
    wrapTextWithAnsi(theme.fg("warning", prefix) + text, Math.max(1, width - 2))
      .map((line) => truncateToWidth(theme.fg("border", "│ ") + line, width));

  let expandedAsk: string | undefined;
  let asksRefresh = 0;
  const refreshAsks = async (): Promise<void> => {
    const refresh = ++asksRefresh;
    const ctx = session;
    const id = seam().host?.sessionId();
    if (!ctx?.ui || !id || isSubagent()) return;
    const res = await runKido(["get-asks", "--session", id], { timeoutMs: 3000 });
    if (!res.ok || ctx !== session || refresh !== asksRefresh) return;
    const asks: { id: string; text: string }[] = JSON.parse(res.out);
    if (!asks.some((a) => a.id === expandedAsk)) expandedAsk = undefined;
    const ui = ctx.ui;
    ui.setWidget("kido-asks", asks.length ? (_tui, theme) => {
      let rows: { ask: typeof asks[number]; first: boolean }[] = [];
      return {
        handleMouse: (event: TuiMouseEvent) => {
          const row = rows[event.y];
          if (!row || pi.getSettings().tuiMode === "regular") return;
          return handleClick(event, () => {
            if (row.first && event.x === 2) {
              void runKido(["tool", "remove_ask", "--", row.ask.id], { timeoutMs: 3000 }).then((res) => {
                if (ctx === session && !res.ok) ui.notify?.(res.error, "error");
              }).catch((err) => ui.notify?.(String(err), "error"));
            } else if (row.first && event.x >= 4 && event.x < 4 + row.ask.id.length) {
              ui.setEditorText(`${row.ask.id}: ${ui.getEditorText()}`);
            } else {
              expandedAsk = expandedAsk === row.ask.id ? undefined : row.ask.id;
            }
          });
        },
        render(width: number) {
          rows = [];
          const regular = pi.getSettings().tuiMode === "regular";
          return asks.flatMap((a) => {
            const prefix = regular ? "" : theme.fg("dim", "x ");
            const lines = regular || expandedAsk === a.id
              ? renderAsk(theme, `${prefix}${a.id}${regular ? " asks you" : ""}: `, a.text, width)
              : [collapsedInbound(width, `${prefix}${a.id}:`, a.text, (color, text) => color ? theme.fg(color === "dim" ? "warning" : color, text) : text)];
            if (!regular) rows.push(...lines.map((_, i) => ({ ask: a, first: i === 0 })));
            return lines;
          });
        },
        invalidate() {},
      };
    } : undefined, { placement: "aboveEditor" });
  };

  const NOTICE_WIDGET_KEY = "kido-notice-pending";

  const renderNoticeWidget = (): void => {
    const ui = session?.ui;
    if (!ui) return;
    if (pendingNotices.size === 0) {
      ui.setWidget(NOTICE_WIDGET_KEY, undefined);
      return;
    }
    const entries = [...pendingNotices.values()];
    ui.setWidget(NOTICE_WIDGET_KEY, (_tui, theme) => ({
      render: (width: number): string[] =>
        entries.map(({ from, text }) => collapsedInbound(width, inboundHeader(from, "notifies"), text, (_color, t) => theme.fg("dim", t))),
      invalidate: () => {},
    }));
  };

  type GaveUp = "timeout" | "inbox" | "unsent" | "gone" | "aborted";
  type AskOutcome = { reply: string } | { gaveUp: GaveUp };

  // Also the cycle-refusal edge set (handleInboundAsk): written synchronously before the
  // send's await, so an inbound ask dispatched while the send is in flight already sees
  // the edge (docs/design.md, "The cycle edge").
  const pendingOutbound = new Map<string, { targetSession: string; settle: (outcome: AskOutcome) => void }>();

  const abandonPending = (): void => {
    for (const waiter of [...pendingOutbound.values()]) waiter.settle({ gaveUp: "inbox" });
  };

  // A trigger already sent whose turn has not started yet; one is enough for any number of
  // arrivals, since prompt() injects every pending "nextTurn" message into the turn it
  // builds. Cleared at pi's turn_start.
  let wakeInFlight = false;

  // pi's sendMessage(triggerTurn) on an idle session skips prompt() - no
  // before_agent_start, and a resumed session's stale system prompt makes
  // pi-claude-bridge refuse the turn. Queueing as "nextTurn" and starting it with
  // sendUserMessage goes through prompt() instead, keeping the arrival's custom type,
  // header and renderer. Remove once pi's own triggerTurn path runs prompt().
  const wake = (
    message: { customType: CustomType; content: string; display: boolean; details?: unknown },
    deliverAs: DeliverAs,
  ): void => {
    let idle = false;
    try {
      idle = !!session?.isIdle();
    } catch {
      // A ctx pi has retired (its assertActive) throws rather than answering: mid-/reload.
      idle = false;
    }
    if (!idle) {
      pi.sendMessage(message, { deliverAs, triggerTurn: true });
      return;
    }
    pi.sendMessage(message, { deliverAs: "nextTurn" });
    if (wakeInFlight) return;
    wakeInFlight = true;
    // expandPromptTemplates is spelled out because the trigger is user-role text and must
    // never be dispatched as a command.
    const trigger = WAKE_TRIGGERS[message.customType];
    const clear = (): void => {
      wakeInFlight = false;
    };
    // prompt() can fail before any turn starts (compaction in progress, unconfigured
    // model); clearing the flag here stops that from blocking every later arrival.
    try {
      void Promise.resolve(pi.sendUserMessage(trigger, { deliverAs, expandPromptTemplates: false })).catch(clear);
    } catch {
      clear();
    }
  };

  pi.on("turn_start", () => {
    wakeInFlight = false;
  });

  // labelFrom names an envelope's sender for the model to read. It is a
  // label only, shown to the model, never the address a reply actually
  // resolves against - see pendingInboundAsks below for why.
  const labelFrom = (from: Sender): string => {
    switch (from.kind) {
      case "agent":
        return from.name || from.session;
      case "kido":
        return from.name;
      case "human":
        return from.pane || "another agent";
    }
  };

  // null means no agent at all: the user speaking, delivered as their own words, unlabelled.
  const messageSender = async (from: Sender): Promise<{ name: string; relation: SenderRelation } | null> => {
    const listed = await fetchAgents();
    if (!listed.ok) return from.kind === "agent" ? { name: labelFrom(from), relation: "peer" } : null;
    const sender = listed.agents.find((a) =>
      from.kind === "agent" ? a.id === from.session : from.kind === "human" && !!from.pane && a.pane === from.pane,
    );
    if (!sender) return null;
    const self = listed.agents.find((a) => a.self);
    const isParent = isSubagent() && !!PARENT_SESSION && sender.id === PARENT_SESSION;
    const isChild = !!self && !!sender.parent && sender.parent === self.id;
    return { name: sender.name || labelFrom(from), relation: isParent ? "parent" : isChild ? "child" : "peer" };
  };

  const handleInboundMessage = async (env: Envelope): Promise<void> => {
    if (!env.text) return;
    const sender = await messageSender(env.from);
    if (!sender) {
      seam().host?.deliver(env.text);
      return;
    }
    workStarted();
    wake(
      {
        customType: MESSAGE_CUSTOM_TYPE,
        content: `${senderHeader("message", sender.name, sender.relation)}\n${env.text}`,
        display: true,
        details: { from: sender.name, relation: sender.relation },
      },
      "followUp",
    );
  };

  const deliverNotice = (text: string, from: string): void => {
    clearIdleExit();
    const noticeId = randomUUID();
    pendingNotices.set(noticeId, { from, text });
    renderNoticeWidget();
    wake({ customType: NOTICE_CUSTOM_TYPE, content: `${noticeHeader(from)}\n${text}`, display: true, details: { from, noticeId } }, "steer");
  };

  // A "stream" envelope never reaches the model on arrival: pi drains one steering message
  // per poll, so one message per chunk would be one LLM turn per chunk.
  const streamBuffers = new Map<string, { name: string; output: string; lines: string[]; dropped: number }>();

  let streamTimer: NodeJS.Timeout | null = null;
  let streamFirstAt = 0;

  const clearStreamTimer = (): void => {
    if (streamTimer) {
      clearTimeout(streamTimer);
      streamTimer = null;
    }
  };

  const handleInboundStream = (env: Envelope & { kind: "stream" }): void => {
    const run = env.run;
    if (streamBuffers.size === 0) streamFirstAt = Date.now();
    const entry = streamBuffers.get(run) ?? {
      name: (env.from.kind !== "human" && env.from.name) || run,
      output: env.output,
      lines: [],
      dropped: 0,
    };
    for (const line of env.text.split("\n")) entry.lines.push(line);
    if (entry.lines.length > STREAM_BUFFER_LINES) {
      entry.dropped += entry.lines.length - STREAM_BUFFER_LINES;
      entry.lines = entry.lines.slice(entry.lines.length - STREAM_BUFFER_LINES);
    }
    streamBuffers.set(run, entry);
    clearStreamTimer();
    streamTimer = setTimeout(flushStreams, Math.max(0, Math.min(STREAM_FLUSH_MS, streamFirstAt + STREAM_MAX_WAIT_MS - Date.now())));
    streamTimer.unref?.(); // a held batch must never hold pi's event loop open
  };

  // The only place a stream chunk is delivered; called from the debounce timer, a turn that
  // ran tools, and a run's own completion notice, which must not arrive before this.
  const flushStreams = (): void => {
    if (streamBuffers.size === 0) return;
    clearStreamTimer();
    clearIdleExit();
    for (const [run, entry] of [...streamBuffers]) {
      streamBuffers.delete(run);
      if (entry.lines.length === 0) continue;
      const header = `async run ${JSON.stringify(entry.name)} output (run ${run})`;
      wake(
        {
          customType: STREAM_CUSTOM_TYPE,
          content: `${header}\n${streamBatch(entry.lines, entry.output, entry.dropped)}`,
          display: true,
          details: { from: entry.name, run, output: entry.output },
        },
        "steer",
      );
    }
  };

  // The asker's pane, the one part of `from` a `/reload` cannot change (it mints a fresh
  // session id): message_agent re-resolves the reply target from this pane rather than a
  // label that can go stale.
  const pendingInboundAsks = new Map<string, string>(); // ask id -> asker's pane

  // Answering would close a cycle is refused on the wire, not delivered at all.
  const STOP_AFTER_ASK_REPLY =
    "That message_agent call is the entire response - end the turn there, with no summary or sign-off after it.";
  const handleInboundAsk = async (env: Envelope): Promise<"ok" | "refused"> => {
    const asker = env.from;
    if (asker.kind === "agent" && [...pendingOutbound.values()].some((w) => w.targetSession === asker.session)) return "refused";
    const sender = await messageSender(asker);
    const from = sender?.name ?? labelFrom(asker);
    const relation = sender?.relation ?? "peer";
    if (env.from.pane) pendingInboundAsks.set(env.id, env.from.pane);
    workStarted();
    wake(
      {
        customType: ASK_CUSTOM_TYPE,
        content:
          `${senderHeader("ask", from, relation)}\n${from} is asking (id ${env.id}): ${env.text}\n\n` +
          `${from} cannot see this session's context, so make the answer self-contained. ` +
          `Reply with message_agent(to=${JSON.stringify(from)}, message=<answer>, replyTo=${JSON.stringify(env.id)}). ${STOP_AFTER_ASK_REPLY}`,
        display: true,
        details: { from, relation, id: env.id, question: env.text },
      },
      "followUp",
    );
    return "ok";
  };

  const handleInboundReply = (env: Envelope & { kind: "reply" }): void => {
    const waiter = pendingOutbound.get(env.replyTo);
    if (waiter) {
      waiter.settle({ reply: env.text });
      return;
    }
    if (!env.text) return;
    const from = labelFrom(env.from);
    workStarted();
    wake(
      {
        customType: REPLY_CUSTOM_TYPE,
        content: replyHeader(from, env.replyTo) + env.text,
        display: true,
        details: { from, replyTo: env.replyTo },
      },
      "followUp",
    );
  };

  // Mirrors Message_agent.resolve's Descendant recipient (lib/message_agent.ml). Checked here too because `from` is
  // advisory: a process that can write this socket can claim to be anyone.
  const senderIsAncestor = async (env: Envelope): Promise<boolean> => {
    const listed = await fetchAgents();
    if (!listed.ok) return false;
    const self = listed.agents.find((a) => a.self);
    if (!self) return false;
    const sender = env.from;
    if (sender.kind === "kido") return true;
    if (sender.kind === "human") return !listed.agents.some((a) => a.pane === sender.pane);
    const from = listed.agents.find((a) => a.id === sender.session);
    return !!from && isAncestor(listed.agents, from, self);
  };

  const handleInboundControl = async (env: Envelope, kind: "interrupt" | "stop"): Promise<"ok" | "refused"> => {
    if (!(await senderIsAncestor(env))) return "refused";
    if (kind === "interrupt") {
      // Awaited, so a message sent after the reply finds the turn ended rather than in a queue the abort skips.
      await session?.abort();
    } else {
      session?.shutdown();
    }
    return "ok";
  };

  // Delivered into the turn already running, not queued for the end of one (docs/design.md, "Steer and followUp").
  const handleInboundSteer = async (env: Envelope): Promise<"ok" | "refused"> => {
    if (!(await senderIsAncestor(env))) return "refused";
    if (env.text) seam().host?.deliver(`${labelFrom(env.from)} is redirecting this work: ${env.text}`, "steer");
    return "ok";
  };

  const handleEnvelope = async (env: Envelope): Promise<"ok" | "refused"> => {
    switch (env.kind) {
      case "asks":
        if (env.text) pi.sendMessage({
          customType: NOTICE_CUSTOM_TYPE,
          content: env.text,
          display: false,
          details: { from: "kido" },
        }, { deliverAs: "nextTurn" });
        void refreshAsks().catch(() => {});
        return "ok";
      case "message":
        await handleInboundMessage(env);
        return "ok";
      case "ask":
        return await handleInboundAsk(env);
      case "reply":
        handleInboundReply(env);
        return "ok";
      case "notice":
        // Before the notice itself: a run's ending must not reach the model ahead of the output tail it refers to.
        flushStreams();
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
      case "unrecognised":
        if (env.text) {
          seam().host?.deliver(`[unrecognised message kind ${JSON.stringify(env.claimed)} from ${labelFrom(env.from)}] ${env.text}`);
        }
        return "ok";
    }
  };

  const fetchAgents = async (source: "context" | "runs" = "context"): Promise<{ ok: true; agents: AgentInfo[] } | { ok: false; error: string }> => {
    const args = source === "runs" ? ["tool", "list_runs", "--json"] : ["get-agent", "--context"];
    const res = await runKido(args, { timeoutMs: 2000 });
    if (!res.ok) return res;
    try {
      return { ok: true, agents: res.out ? JSON.parse(res.out) : [] };
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  };

  // A keystroke must never wait on `kido tool list_runs --json`: the editor gets whatever the
  // last call returned, stale or empty, while a refresh runs behind it. Null until the
  // provider is registered (sessionStarting).
  type CompletionCache = { agents: AgentInfo[]; at: number; refreshing: Promise<void> | null };
  let completion: CompletionCache | null = null;

  // Only a definite false from `kido get-agent` is evidence; anything else - an error, an
  // unreachable kido - is inconclusive and never shuts the session down on a guess. Not
  // `kido tool list_runs --json`: it scopes to the caller's tmux session and collapses to one
  // record per pane, so a `pi --print` started in the parent's pane and inheriting
  // TMUX_PANE would win that pane and make a healthy parent look gone.
  // kill(pid, 0) success or EPERM is not proof of life - a pid can be recycled.
  const lookupBoolean = (res: RunKidoResult, id: string, field: "alive" | "childrenAlive" | "focused"): boolean | undefined => {
    if (!res.ok) return undefined;
    try {
      const value: unknown = JSON.parse(res.out);
      if (!value || typeof value !== "object" || !("id" in value) || value.id !== id) return undefined;
      if (field === "alive" && "alive" in value && typeof value.alive === "boolean") return value.alive;
      if (field === "childrenAlive" && "childrenAlive" in value && typeof value.childrenAlive === "boolean") return value.childrenAlive;
      if (field === "focused" && "focused" in value && typeof value.focused === "boolean") return value.focused;
    } catch {}
    return undefined;
  };

  const parentIsAlive = async (): Promise<boolean> => {
    if (PARENT_PID === undefined || PARENT_SESSION === undefined) return true;
    try {
      process.kill(PARENT_PID, 0);
    } catch (err) {
      if (err instanceof Error && "code" in err && err.code === "ESRCH") return false;
    }
    const res = await runKido(["get-agent", PARENT_SESSION], { timeoutMs: 2000 });
    return lookupBoolean(res, PARENT_SESSION, "alive") !== false;
  };

  // Stops a tick from starting a second parentIsAlive() call while the previous one is
  // still awaiting its subprocess round trip: setInterval fires on schedule regardless of
  // whether the callback's own async work has finished, so a slow reading would otherwise
  // pile up processes.
  let pollInFlight = false;

  const startParentLivenessPoll = (): void => {
    if (PARENT_PID === undefined || !isSubagent()) return;
    stopParentLivenessPoll();
    parentPollTimer = setInterval(() => {
      if (pollInFlight) return;
      pollInFlight = true;
      parentIsAlive().then((alive) => {
        pollInFlight = false;
        if (alive) return;
        stopParentLivenessPoll();
        session?.shutdown();
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

  let reportedToParent = false;

  // "awaiting-first-turn" lasts until the first sign a turn began; a child whose pi could
  // not start its model at all settles at startup looking exactly like an idle child
  // otherwise, which is what puts "no turn ever ran" in its parent's notice. lastError is
  // set only when a turn stopped on "error" (not an abort); notified keeps one notice per
  // failure, since agent_settled can fire again with nothing new.
  type RunPhase = { phase: "awaiting-first-turn" } | { phase: "worked"; lastError?: { text: string; notified: boolean } };
  let phase: RunPhase = { phase: "worked" };

  let idleExitTimer: NodeJS.Timeout | null = null;

  const clearIdleExit = (): void => {
    if (idleExitTimer) {
      clearTimeout(idleExitTimer);
      idleExitTimer = null;
    }
  };

  const workStarted = (): void => {
    if (phase.phase === "awaiting-first-turn") phase = { phase: "worked" };
    clearIdleExit();
  };

  const armIdleExit = (): void => {
    if (!isSubagent() || KEEP_ALIVE) return;
    clearIdleExit();
    idleExitTimer = setTimeout(async () => {
      // A session with a child of its own still running is not idle, however quiet it has
      // been; exiting would orphan the child for the sweep to close mid-work. Read from the
      // run records, not process memory, since a child outlives the turn that spawned it.
      const sessionId = seam().host?.sessionId() ?? "";
      const children = await runKido(["get-agent", sessionId, "--children"], { timeoutMs: 2000 });
      if (lookupBoolean(children, sessionId, "childrenAlive") !== false) {
        armIdleExit();
        return;
      }
      const listed = await fetchAgents();
      const self = listed.ok ? listed.agents.find((a) => a.self) : undefined;
      // A window a client is currently looking at is not reaped out from under them; the
      // timer re-arms instead, so it is collected once the user looks away.
      const focused = self?.window ? await runKido(["get-window", self.window], { timeoutMs: 2000 }) : null;
      if (focused && self?.window && lookupBoolean(focused, self.window, "focused") === true) {
        armIdleExit();
        return;
      }
      // pi's shutdown only ends the session once it is not mid-compaction, re-checked on
      // its next agent_settled; re-arming costs nothing once the session does end.
      session?.shutdown();
      armIdleExit();
    }, IDLE_EXIT_MS);
    idleExitTimer.unref();
  };

  pi.registerTool({
    name: "list_runs",
    label: "List Runs",
    description: "List same-parent peers and your parent in this tmux session, plus your own subagents and async_bash jobs: all running and the newest 20 ended, newest first. Use message_agent for agents and stop_run with a run id to stop your runs.",
    promptSnippet: "list_runs() - find same-parent peers and your parent to message, and your own subagents and jobs to stop with stop_run",
    parameters: Type.Object({}, { additionalProperties: false }),
    async execute() {
      const res = await fetchAgents("runs");
      if (!res.ok) return reply(`could not list runs: ${res.error}`);
      return reply(JSON.stringify(res.agents), res.agents);
    },
  });

  pi.registerTool({
    name: "set_status",
    label: "Set Status",
    description:
      "Set the free-text activity shown next to you in kido's tmux sidebar. Separate from your running/waiting/idle status.",
    promptSnippet: "set_status(activity) - tell everyone else what you are doing, visible in list_runs()",
    parameters: Type.Object(
      {
        // No maxLength here: it would count UTF-16 code units against a
        // byte budget and reject a call kido would otherwise happily
        // truncate, in bytes. The schema states the cap for the model to
        // read; only kido enforces it.
        activity: Type.String({
          description: 'What you are doing right now ("refactoring internal/ui"), or "" to clear it. Capped at 256 bytes.',
        }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      seam().host?.setActivity(params.activity);
      return reply("ok");
    },
  });

  pi.registerTool({
    name: "message_agent",
    label: "Message Agent",
    description:
      "Send a message to another agent in this tmux session, addressed by name, session id, or a unique id prefix. It waits for the receiver to finish its current turn, and a running descendant's turn is usually its whole task: to give one new information, evidence, scope or a correction, use steer_subagent. message_agent is for what can wait until the receiver finishes.",
    promptSnippet: "message_agent(to, message, replyTo?) - send a message to another agent in this tmux session",
    parameters: Type.Object(
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
    ),
    async execute(_toolCallId, params) {
      const args = ["tool", "message_agent"];
      if (params.replyTo) args.push("--reply-to", params.replyTo);
      // Only set for a reply to an ask this session actually has pending: a reply to a
      // notice, or a stale id, has nothing to stop after.
      const askerPane = params.replyTo ? pendingInboundAsks.get(params.replyTo) : undefined;
      // Re-resolved from the asker's pane, not the model's `to`: a `/reload` since the ask
      // arrived can have moved the asker to a new session id, but not its pane.
      let to = params.to;
      if (askerPane && params.replyTo) {
        pendingInboundAsks.delete(params.replyTo);
        const listed = await fetchAgents();
        if (listed.ok) to = listed.agents.find((a) => a.pane === askerPane)?.id ?? to;
      }
      // "--" first: a model-authored `to` beginning with a dash would otherwise be parsed as a kido flag.
      args.push("--", to);
      const res = await runKido(args, { input: params.message, timeoutMs: 5000 });
      if (!res.ok) return reply(`could not message ${params.to}: ${res.error}`);
      const delivered = res.out || `message delivered to ${params.to}`;
      return reply(askerPane ? `${delivered} ${STOP_AFTER_ASK_REPLY}` : delivered);
    },
  });

  pi.registerTool({
    name: "ask_agent",
    label: "Ask Agent",
    description:
      "Ask another agent a question and block until it replies - one full turn of the target's latency, not a round-trip, since a busy target does not see the question until it would otherwise have stopped. Refused for an ancestor, a target outside this tmux session, one with no inbox or no message_agent tool, or yourself. Not for collecting a subagent's result: that arrives on its own as a notice when the child finishes, and an ask blocks this turn until the target answers, so the notice cannot be read until the ask returns.",
    promptSnippet:
      "ask_agent(to, question, timeoutMs?) - ask another agent a question and wait for its reply (DO NOT use to get subagent results, wait for notification instead)",
    parameters: Type.Object(
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
    ),
    async execute(_toolCallId, params, signal) {
      const listed = await fetchAgents();
      if (!listed.ok) return reply(`could not list agents: ${listed.error}`);
      const agents = listed.agents;

      const self = agents.find((a) => a.self);
      if (!self) return reply("could not find this agent among kido's agents; cannot ask");

      const { agent: target, error } = resolveAgent(agents, params.to);
      if (!target) return reply(`could not ask ${params.to}: ${error}`);
      if (target.id === self.id) return reply("cannot ask yourself");
      const who = target.name || target.id;
      // A child asking an ancestor is refused; a parent asking its own child falls through.
      if (isAncestor(agents, target, self)) {
        return reply(`${who} is an ancestor; the parent stays free to orchestrate, so it cannot be asked`);
      }
      if (!target.canMessage) {
        return reply(`${who} has no inbox; an ask cannot work over a paste, there is no way back`);
      }
      if (!target.canReply) {
        return reply(`${who} was spawned without the message_agent tool and cannot reply; use message_agent, or wait for its notify_parent notice`);
      }
      // Fail fast rather than wait out the timeout against a target that is never going to answer.
      if (target.stalled) {
        return reply(`${who} has been quiet for ${target.sinceReport}s while reporting running; likely stalled, refusing to wait for a reply`);
      }
      const alive = await runKido(["get-agent", target.id], { timeoutMs: 2000 });
      if (lookupBoolean(alive, target.id, "alive") === false) return reply(`${who} is no longer running; refusing to wait for a reply`);

      // Checked synchronously, with no await before pendingOutbound.set below, so a teardown
      // either already caught this waiter with abandonPending or closed the inbox first.
      if (!seam().host?.inboxOpen()) {
        return reply(`this session's inbox is unavailable; no reply from ${params.to} can be waited for`);
      }

      const id = randomUUID();
      const timeoutMs = params.timeoutMs ?? DEFAULT_ASK_TIMEOUT_MS;

      // Registered before the send, so a reply cannot race past it.
      let deliverReply: (outcome: AskOutcome) => void = () => {};
      let watch: NodeJS.Timeout | null = null;
      const answered = new Promise<AskOutcome>((resolve) => {
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
      // Esc aborts pi's AbortSignal; checked explicitly rather than relied on to have
      // already fired, since the prechecks above are awaits an abort can land during.
      if (signal?.aborted) onAbort();
      else signal?.addEventListener("abort", onAbort, { once: true });

      // target.id, not params.to: removes a second resolution inside kido tool ask_agent that could disagree with this one.
      const sent = await runKido(["tool", "ask_agent", "--id", id, "--", target.id], {
        input: params.question,
        timeoutMs: 5000,
      });
      if (!sent.ok) settle({ gaveUp: "unsent" });

      // A target that dies while this waits - the ordinary case of a child finishing and
      // exiting without replying - leaves nothing to release the waiter, so this polls too.
      // Not started once the wait is already over (settled by an abort or a send failure).
      if (!settled) {
        const targetID = target.id;
        let reading = false;
        watch = setInterval(() => {
          if (reading) return;
          reading = true;
          runKido(["get-agent", targetID], { timeoutMs: 2000 }).then((res) => {
            reading = false;
            if (lookupBoolean(res, targetID, "alive") === false) settle({ gaveUp: "gone" });
          });
        }, ASK_LIVENESS_POLL_MS);
        watch.unref();
      }

      const outcome = await answered;
      if ("reply" in outcome) return reply(outcome.reply);
      const gaveUpText: Record<GaveUp, string> = {
        unsent: `could not ask ${params.to}: ${sent.ok ? "" : sent.error}`,
        aborted: `the ask to ${params.to} was interrupted (ask id ${id}); a later reply naming this id will still arrive as a message`,
        gone: `${who} stopped running before answering (ask id ${id}); no reply can come from it now`,
        inbox: `this session's inbox closed before ${params.to} answered (ask id ${id}); no reply can reach it now, so ask again if the answer still matters`,
        timeout: `no reply from ${params.to} within ${timeoutMs}ms (ask id ${id}); a later reply naming this id will still arrive as a message`,
      };
      return reply(gaveUpText[outcome.gaveUp]);
    },
  });

  pi.registerTool({
    name: "spawn_subagent",
    label: "Spawn Subagent",
    description:
      "Create a subagent in its own tmux window with a task, or resume a dead or finished one by its run id. With fork: true it starts holding this session's context, for a judgement step that has to know what was already decided. Returns its identity immediately without waiting for it to finish. Its result arrives as a notice when it calls notify_parent; do not ask_agent a child for its result; list_runs lists its run and stop_run stops it with the returned run id.",
    promptSnippet:
      "spawn_subagent(task, name?, model?, tools?, keepAlive?, fork?) or spawn_subagent(resume, model?, tools?, keepAlive?) - delegate a task to a new subagent, optionally forked from your own context, or resume a dead one, in its own window; list_runs lists it and stop_run stops it with its run id",
    // pi's buildRules (system-prompt.js) merges these into the system prompt's rules section;
    // NOT_THE_USER_RULE is the same string in async_bash's list, de-duplicated to one bullet.
    promptGuidelines: [
      "A subagent's result arrives on its own as a notice when it finishes; never ask a child for its result and never poll list_runs for it; list_runs lists the run and stop_run stops it with the returned run id.",
      "Trust but verify: a child's report says what it intended to do, not what it did - check the diff before relaying success.",
      NOT_THE_USER_RULE,
    ],
    parameters: Type.Object(
      {
        task: Type.Optional(
          Type.String({
            description:
              "The task to give the new subagent, delivered as its first message. Required unless resume is given - a resumed run keeps its own original task and refuses a new one. " +
              "The subagent starts with no context beyond this text (a fork excepted), so name the files, the lines and the specific change, say what it must report back, and say whether it is to write code or only research. " +
              "Synthesize what you already know into the task rather than writing \"based on your findings\".",
          }),
        ),
        name: Type.Optional(
          Type.String({
            description:
              "A name for the subagent's window and session; a name is generated when omitted. Refused together with resume - a resumed run keeps its original window name.",
          }),
        ),
        model: Type.Optional(
          Type.String({
            description:
              'Model for the subagent to run, as "provider/model-id" (e.g. claude-bridge/claude-sonnet-5), optionally suffixed :<thinking>, e.g. claude-bridge/claude-sonnet-5:low - see `pi --list-models`. A bare alias like "sonnet" is refused, not resolved.',
          }),
        ),
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
    ),
    async execute(_toolCallId, params) {
      const own = seam().host?.sessionId();
      if (!own) return reply("this session has no id of its own to parent a subagent with; cannot spawn");
      // A generated name goes on a tmux command line, so it must avoid the characters tmuxConfUnsafe rejects; hex does.
      const name = params.name || (params.resume ? "" : `sub-${randomUUID().slice(0, 8)}`);
      const modelAndTools = [
        ...(params.model ? ["--model", params.model] : []),
        ...(params.tools && params.tools.length > 0 ? ["--tools", params.tools.join(",")] : []),
      ];
      const args = ["tool", "spawn_subagent", "--parent-pid", String(process.pid), "--parent-session", own];
      if (params.resume) args.push("--resume", params.resume);
      if (name) args.push("--name", name);
      if (params.task) args.push("--task-file", "-");
      if (params.fork) args.push("--fork", own);
      if (params.keepAlive) args.push("--keep-alive");
      args.push(...modelAndTools, "--", "pi", ...(name ? ["--name", name] : []), ...modelAndTools);
      const res = await runKido(args, { input: params.task, timeoutMs: SPAWN_TIMEOUT_MS });
      if (!res.ok) return reply(params.resume ? `could not resume ${params.resume}: ${res.error}` : `could not spawn subagent: ${res.error}`);
      const [windowID, paneID, runID] = res.out.split(/\s+/);
      if (params.resume) {
        return reply(
          `resumed ${runID} (window ${windowID}, pane ${paneID}); it is back with its context and idle - send it a message to continue, since it is waiting for one; ${SPAWN_RESULT_RULE}`,
          { window: windowID, pane: paneID, run: runID },
        );
      }
      return reply(
        `spawned ${name} (window ${windowID}, pane ${paneID}, run ${runID})${params.fork ? ", forked from this session's context" : ""}; ` +
          SPAWN_RESULT_RULE,
        { name, window: windowID, pane: paneID, run: runID, fork: !!params.fork },
      );
    },
  });

  const controlTools = [
    {
      name: "steer_subagent",
      label: "Steer Subagent",
      description:
        "Redirect a descendant that is already working, without aborting its turn: the message joins the run it is in rather than waiting for it to finish. For anything a running descendant needs before it finishes: new evidence, a change of scope, a correction or a warning. Refused for anything but a descendant. Use message_agent when the message can wait for the current turn to end; use stop_run to end a run.",
      promptSnippet: "steer_subagent(to, message) - redirect a descendant mid-task without aborting; stop_run ends a run",
      parameters: Type.Object(
        {
          to: Type.String({
            description: "Who to steer: a descendant's exact name, exact session id, or a unique prefix of its session id.",
          }),
          message: Type.String({ description: "The course correction to deliver." }),
        },
        { additionalProperties: false },
      ),
      verb: "steer",
      done: "steered",
      timeoutMs: 5000,
    },
    {
      name: "interrupt_subagent",
      label: "Interrupt Subagent",
      description:
        "Abort a descendant's current turn without ending its session - it stays alive and idle, ready for a corrected instruction. Refused for anything but a descendant; use stop_run to end a run.",
      promptSnippet: "interrupt_subagent(to) - abort a descendant's turn without ending its session; stop_run ends a run",
      parameters: Type.Object(
        {
          to: Type.String({
            description: "Who to interrupt: an agent's exact name, exact session id, or a unique prefix of its session id.",
          }),
        },
        { additionalProperties: false },
      ),
      verb: "interrupt",
      done: "interrupted",
      timeoutMs: 5000,
    },
    {
      name: "stop_run",
      label: "Stop Run",
      description:
        "Stop a descendant subagent or async_bash run found in list_runs. Asks a subagent to shut down, killing its pane if needed; sends TERM to a bash wrapper, which forwards it to its command.",
      promptSnippet: "stop_run(to, force?) - end a descendant subagent or bash run found in list_runs",
      parameters: Type.Object(
        {
          to: Type.String({
            description: "Run id, unique prefix of at least 8 characters, or unambiguous run name; one leading @ is ignored.",
          }),
          force: Type.Optional(
            Type.Boolean({
              description:
                "For a subagent with no usable inbox, allow killing its pane. Not needed for bash runs. Destructive and irreversible.",
            }),
          ),
        },
        { additionalProperties: false },
      ),
      verb: "stop",
      done: "stopped",
      timeoutMs: STOP_TIMEOUT_MS,
    },
  ];
  for (const { verb, done, timeoutMs, ...tool } of controlTools) {
    pi.registerTool({
      ...tool,
      async execute(_toolCallId: string, params: { to: string; message?: string; force?: boolean }) {
        const args = ["tool", tool.name];
        if (params.force) args.push("--force");
        args.push("--", params.to);
        const res = await runKido(args, { input: params.message, timeoutMs });
        if (!res.ok) return reply(`could not ${verb} ${params.to}: ${res.error}`);
        return reply(res.out || `${done} ${params.to}`);
      },
    });
  }

  pi.registerTool({
    name: "async_bash",
    label: "Async Bash",
    description:
      "Run a shell command in the background, for a command whose result you do not need for your next step - this session keeps working while it runs. Exactly one notice arrives when the command ends, carrying its exit status and a tail of its output; read the output file with the ordinary read tool at any time before then to check on progress. With stream=true the output also arrives in batches as it runs - between your own tool calls while you are working, on a slowing schedule when you are idle, capped per batch and per run, so some lines are only ever in the file, which always has all of them. If your next step needs the result and you have nothing else to do meanwhile, use bash with a timeout instead; list_runs lists its run and stop_run stops it with the returned run id.",
    promptSnippet:
      "async_bash(command, name?) - run a command in the background; a notice with its exit status arrives when it ends, read the output file meanwhile; list_runs lists it and stop_run stops it with its run id",
    promptGuidelines: [
      "A command whose result you need before continuing (tests, a build, anything you will act on) runs in foreground bash, however long it takes - length alone is never a reason to use async_bash. Once a command is in async_bash, its notice is the only way you learn that it ended: never run `sleep` in bash to wait for it, and never loop over its output file. If you have nothing else to do, end your turn; the notice wakes you.",
      "list_runs lists an async_bash run and stop_run stops it with the returned run id.",
      NOT_THE_USER_RULE,
    ],
    parameters: Type.Object(
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
    ),
    async execute(_toolCallId, params) {
      const args = ["tool", "async_bash"];
      if (params.name) args.push("--name", params.name);
      if (params.stream) args.push("--stream");
      args.push("--", params.command);
      const res = await runKido(args, { timeoutMs: SPAWN_TIMEOUT_MS });
      if (!res.ok) return reply(`could not start background command: ${res.error}`);
      const [windowID, paneID, runID, outputPath] = res.out.split(/\s+/);
      return reply(
        `started run ${runID}${params.name ? ` (${params.name})` : ""} in window ${windowID}; list_runs lists it and stop_run("${runID}") stops it; ` +
          `a notice with its exit status and a tail of its output arrives when it ends and starts your next turn; you stay alive while it runs, so ending your turn now is safe - do not sleep or poll for it, and end your turn if nothing else is left - ` +
          (params.stream
            ? `batches of its output arrive meanwhile, capped, with anything they leave out in ${outputPath}`
            : `read ${outputPath} with the read tool to check on it meanwhile`),
        { name: params.name, window: windowID, pane: paneID, run: runID, output: outputPath, stream: !!params.stream },
      );
    },
  });

  pi.registerTool({
    name: "notify_parent",
    label: "Notify Parent",
    description:
      "Tell your parent your work is done, carrying a short summary. Call this once, when you have an answer or have given up - nothing else reports it. Only meaningful for a subagent; refused for a session with no parent.",
    promptSnippet: "notify_parent(summary) - tell your parent your work is done, once it actually is",
    parameters: Type.Object(
      {
        // No maxLength: typebox rejects the whole call on it rather than truncating, and it
        // counts characters against a byte budget - measured live, forcing a model to redo the call.
        summary: Type.String({
          description:
            `A short summary of the finished work to send to your parent. Your parent reads the first ${MAX_NOTICE_BYTES} bytes; ` +
            `anything longer is kept in full in this run's directory and the notice says where, so nothing is lost.`,
        }),
      },
      { additionalProperties: false },
    ),
    async execute(_toolCallId, params) {
      // The one refusal unrelated to kido being reachable: a session that is not itself a
      // spawned child has no parent to tell, unlike every other tool's silent no-op.
      if (!isSubagent()) {
        return reply("this session has no parent (it was not spawned as a subagent); notify_parent has nobody to tell");
      }
      const res = await runKido(["tool", "notify_parent"], { input: params.summary, timeoutMs: 5000 });
      if (!res.ok) return reply(`could not notify parent: ${res.error}`);
      reportedToParent = true;
      return reply(res.out || "notified parent");
    },
  });

  pi.on("message_start", (event) => {
    const m = event?.message;
    if (m?.role !== "custom" || m.customType !== NOTICE_CUSTOM_TYPE) return;
    const details = m.details;
    if (typeof details !== "object" || details === null || !("noticeId" in details)) return;
    const noticeId = details.noticeId;
    if (typeof noticeId !== "string" || !noticeId || !pendingNotices.has(noticeId)) return;
    pendingNotices.delete(noticeId);
    renderNoticeWidget();
  });

  // pi awaits this handler before it polls the steering queue (measured against pi
  // 0.85.1's agent-loop.js), so a batch sent here is drained by the very next poll. A turn
  // that ran no tools was the agent stopping; flushing there would loop for as long as
  // output keeps arriving, so those batches wait for the debounce instead.
  pi.on("turn_end", (event: { toolResults?: unknown[] }) => {
    if (!event?.toolResults?.length) return;
    flushStreams();
  });

  const inboundExpanded = new Map<string, boolean>();
  const renderInbound = (message: Parameters<MessageRenderer>[0], theme: Pick<Theme, "fg">, sender: string | undefined, verb: string | undefined, body: string) => {
    const key = JSON.stringify([message.customType, message.timestamp, message.details]);
    const expanded = () => pi.getSettings().tuiMode === "regular" || (inboundExpanded.get(key) ?? false);
    const paint: Paint = (color, text) => (color ? theme.fg(color, text) : text);
    return {
      handleMouse: (event: TuiMouseEvent) => handleClick(event, () => inboundExpanded.set(key, !expanded())),
      render: (width: number): string[] => {
        const header = inboundHeader(sender, verb);
        if (!expanded() || width <= 2) return [collapsedInbound(width, header, body, paint)];
        return wrapTextWithAnsi(`${paint("dim", header)}\n${body}`, width - 2).map((line) => paint("border", "│ ") + line);
      },
      invalidate: () => {},
    };
  };

  pi.registerMessageRenderer<{ from: string }>(STREAM_CUSTOM_TYPE, (message, _options, theme) => {
    const content = typeof message.content === "string" ? message.content : "";
    return renderInbound(message, theme, message.details?.from, undefined, content.slice(content.indexOf("\n") + 1));
  });

  pi.registerMessageRenderer<{ from: string }>(MESSAGE_CUSTOM_TYPE, (message, _options, theme) => {
    const from = message.details?.from || "another agent";
    const raw = typeof message.content === "string" ? message.content : "";
    const header = RELATIONS
      .map((relation) => `${senderHeader("message", from, relation)}\n`)
      .find((line) => raw.startsWith(line));
    const content = header ? raw.slice(header.length) : raw;
    return renderInbound(message, theme, message.details?.from, "says", content);
  });

  pi.registerMessageRenderer<{ from: string; question: string }>(ASK_CUSTOM_TYPE, (message, _options, theme) => {
    const question = message.details?.question ?? (typeof message.content === "string" ? message.content : "");
    return renderInbound(message, theme, message.details?.from, "asks", question);
  });

  pi.registerMessageRenderer<{ from: string; replyTo: string }>(REPLY_CUSTOM_TYPE, (message, _options, theme) => {
    const raw = typeof message.content === "string" ? message.content : "";
    const header = replyHeader(message.details?.from ?? "", message.details?.replyTo ?? "");
    return renderInbound(message, theme, message.details?.from, "replies", raw.startsWith(header) ? raw.slice(header.length) : raw);
  });

  pi.registerMessageRenderer<{ from: string }>(NOTICE_CUSTOM_TYPE, (message, _options, theme) => {
    const from = message.details?.from || "another agent";
    const raw = typeof message.content === "string" ? message.content : "";
    const header = `${noticeHeader(from)}\n`;
    const content = raw.startsWith(header) ? raw.slice(header.length) : raw;
    return renderInbound(message, theme, message.details?.from, "notifies", content);
  });

  const trimErrorMessage = (msg: string): string => (msg.length > 400 ? `${msg.slice(0, 400)}…` : msg);

  // As a guideline, not a returned systemPrompt: a forced prompt is opaque to
  // pi-claude-bridge, whose prompt capture then fails the turn.
  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.promptGuidelines.push(NEVER_SLEEP_RULE);
    if (!isSubagent()) return;
    event.systemPromptOptions.promptGuidelines.push(NOTIFY_PARENT_INSTRUCTION);
  });

  // agent_end fires once per attempt, retries included; agent_settled fires once after them and is the only one that speaks.
  pi.on("agent_end", (event: { messages?: { role?: string; stopReason?: string; errorMessage?: string }[] }) => {
    const assistants = (event?.messages ?? []).filter((m) => m?.role === "assistant");
    const last = assistants[assistants.length - 1];
    if (!last) return;
    phase = {
      phase: "worked",
      lastError: last.stopReason === "error" ? { text: last.errorMessage || "no error message given", notified: false } : undefined,
    };
  });

  pi.on("agent_settled", async (_event: unknown, ctx: { isIdle(): boolean }) => {
    if (!ctx.isIdle() || !isSubagent()) return;
    armIdleExit();
    if (phase.phase !== "worked" || !phase.lastError || phase.lastError.notified) return;
    phase.lastError.notified = true;
    const runID = ownRunID();
    const text =
      `subagent stopped on an error: ${trimErrorMessage(phase.lastError.text)}\n` +
      `run: ${runID}\n` +
      `message it to retry, or spawn_subagent(resume: "${runID}") once it has exited`;
    await runKido(["tool", "notify_parent"], { input: text, timeoutMs: 5000 });
  });

  // The task file is never unlinked (it is the run's record); the sibling "delivered"
  // marker, written only after a successful read, is what stops a /reload from delivering it twice.
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
    if (!task.trim()) return;
    seam().host?.deliver(task);
    // deliver() only hands pi a message and returns; the clock goes on here, after
    // deliver's own workStarted has cleared it.
    phase = { phase: "awaiting-first-turn" };
    armIdleExit();
  };

  // The two things that happen exactly once, when this process's own run actually ends:
  // record how it ended, and schedule its window's linger. Gated on it actually being the
  // run's own child (ownRunID) and this being the run ending, not a /reload rebuilding the
  // extension runtime in the same process - an outcome is first-write-wins, so a reload recording
  // "completed" would leave the run's real ending unrecordable.
  const endOwnRun = async (reason?: ShutdownReason): Promise<void> => {
    const host = seam().host;
    const runID = ownRunID();
    // pi fires session_shutdown for five reasons; only "quit" (or an absent reason) ends the run.
    if (!runID || !host || (reason !== undefined && reason !== "quit")) return;
    // "idle" is the only status a turn finishes on, so anything else at shutdown is a
    // failure - and so is a session still waiting for its first turn.
    const [result, text] =
      phase.phase === "awaiting-first-turn"
        ? ["failed", NO_FIRST_TURN_TEXT]
        : [host.status() === "idle" ? "completed" : "failed", phase.lastError && `its last turn failed: ${trimErrorMessage(phase.lastError.text)}`];
    const args = ["run-outcome", "--result", result];
    if (!reportedToParent) args.push("--unreported");
    if (text) args.push("--text", text);
    await runKido([...args, "--", runID], { timeoutMs: 3000 });
    const listed = await fetchAgents();
    const window = listed.ok ? listed.agents.find((a) => a.self)?.window : undefined;
    const kido = host.kidoPath();
    // sleep, then `kido close-run`, as its own process since this one's event loop is gone
    // by the time the sleep fires. windowID and kido's path go as sh's $0/$1 so neither needs shell-quoting.
    if (window && kido) host.spawnDetached("sh", ["-c", `sleep ${LINGER_SECONDS} && exec "$0" close-run "$1"`, kido, window]);
  };

  const hooks: AgentHooks = {
    sessionStarting(ctx: SessionContext) {
      session = ctx;
      // A /reload's fresh ctx has already had pi clear the previous widgets (resetExtensionUI); drop our own record so renderNoticeWidget does not resurrect rows for it.
      pendingNotices.clear();
      clearStreamTimer();
      streamBuffers.clear();
      wakeInFlight = false;
      // A headless session has no ui, and a pi older than 0.87.1 has one without this
      // method; both simply get no `@name` completion. Registered once: session_start fires
      // again on a /reload, and nothing is fetched until the first `@` keystroke.
      if (!ctx.ui?.addAutocompleteProvider || completion) return;
      const cache: CompletionCache = { agents: [], at: 0, refreshing: null };
      completion = cache;
      // `@` is pi's own file-reference trigger; this wraps the built-in provider rather than
      // replacing it, agent matches first then whatever files pi found for the same token.
      ctx.ui.addAutocompleteProvider((current: CompletionProvider): CompletionProvider => ({
        triggerCharacters: current.triggerCharacters,
        async getSuggestions(lines, cursorLine, cursorCol, options) {
          const token = atToken((lines[cursorLine] ?? "").slice(0, cursorCol));
          if (token === undefined) return current.getSuggestions(lines, cursorLine, cursorCol, options);
          if (!cache.refreshing && Date.now() - cache.at >= AGENT_LIST_TTL_MS) {
            cache.refreshing = fetchAgents("runs")
              .then((listed) => {
                if (listed.ok) cache.agents = listed.agents.filter((a) => a.kind !== "bash" && a.state !== "ended");
                cache.at = Date.now();
              })
              .catch(() => {})
              .finally(() => {
                cache.refreshing = null;
              });
          }
          const items = agentCompletionItems(cache.agents, token);
          const files = await current.getSuggestions(lines, cursorLine, cursorCol, options);
          if (items.length === 0) return files;
          const prefix = `@${token}`;
          // Only a file half that answered the same token can be merged: two prefixes in one list would have the editor cut the wrong text.
          const fileItems = files && files.prefix === prefix ? files.items : [];
          return { items: [...items, ...fileItems], prefix };
        },
        applyCompletion: current.applyCompletion.bind(current),
        shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
          return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
        },
      }));
    },
    async sessionStarted() {
      if (!isSubagent() || pi.getAllTools().some((t) => t.name === "ask_user")) {
        pi.registerTool({
          name: "ask_user",
          exposure: isSubagent() ? "hidden" : "direct",
          label: "Ask User",
          description: "Put a question needing the user's decision into kido's tracked asks and return its short id. Call this whenever your reply ends with a decision the user must make. Never announce in your reply that you created, reworded or removed an ask: the user sees asks in the UI. replaces rewords an existing ask, keeping its id; an unknown id is an error. Top-level agents only.",
          promptSnippet: "ask_user(text, replaces?) - track a question that needs the user's decision",
          promptGuidelines: [
            "Use ask_user for each decision that needs the user, one decision per ask, so each can be answered and removed on its own. Status updates, FYIs and 'should I continue?' are not asks.",
            "Write an ask to be read on its own, away from this conversation: name the project or thread, what is being decided, the options, and your recommendation if you have one.",
            "An ask is tracked in addition to your reply, not instead of it: still put the question in your reply text, but never announce that you created, reworded or removed an ask, nor list ask ids; the user sees asks in the UI.",
            "When the user has answered an ask, or it is moot, call remove_ask. Use replaces to reword an existing ask, keeping its id.",
          ],
          parameters: Type.Object({
            text: Type.String({ description: "The question needing the user's decision." }),
            replaces: Type.Optional(Type.String({ description: "An existing ask id to reword, keeping its id." })),
          }, { additionalProperties: false }),
          renderCall(params, theme) {
            return {
              render(width) {
                return renderAsk(theme, `asks you${params.replaces ? ` (${params.replaces})` : ""}: `, params.text ?? "", width);
              },
              invalidate() {},
            };
          },
          async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
            if (isSubagent()) throw new Error("user asks are for top-level agents only");
            const file = ctx.sessionManager.getSessionFile();
            if (!file) throw new Error("this pi session has no session file");
            const args = ["tool", "ask_user", "--session", seam().host?.sessionId() ?? "", "--session-file", file];
            if (params.replaces) args.push("--replaces", params.replaces);
            const res = await runKido(args, { input: params.text, timeoutMs: 3000 });
            if (!res.ok) throw new Error(res.error);
            await refreshAsks();
            return reply(res.out.trim());
          },
        });
        pi.registerTool({
          name: "remove_ask",
          exposure: isSubagent() ? "hidden" : "direct",
          label: "Remove Ask",
          description: "Remove a tracked user ask when it has been answered or is moot. Never announce the removal in your reply. Top-level agents only.",
          promptSnippet: "remove_ask(id) - remove an answered or moot user ask",
          parameters: Type.Object({ id: Type.String({ description: "The ask id to remove." }) }, { additionalProperties: false }),
          async execute(_toolCallId, params) {
            if (isSubagent()) throw new Error("user asks are for top-level agents only");
            const res = await runKido(["tool", "remove_ask", "--session", seam().host?.sessionId() ?? "", "--", params.id], { timeoutMs: 3000 });
            if (!res.ok) throw new Error(res.error);
            await refreshAsks();
            return reply("removed " + params.id);
          },
        });
      }
      void refreshAsks().catch(() => {});
      startParentLivenessPoll();
      deliverTask();
    },
    inboxLost: abandonPending,
    async sessionEnding(reason?: ShutdownReason) {
      ++asksRefresh;
      session = null;
      // abandonPending runs on every reason, reload included: a reload still tears the inbox down.
      stopParentLivenessPoll();
      clearIdleExit();
      clearStreamTimer();
      abandonPending();
      await endOwnRun(reason);
    },
    workStarted,
    handleEnvelope,
  };
  seam().agents = hooks;
}
