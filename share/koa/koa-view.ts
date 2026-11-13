import { randomUUID } from "node:crypto";
import { rmSync } from "node:fs";
import type { AgentSession, AgentSessionEvent, AgentSessionRuntime } from "@earendil-works/pi-coding-agent";
import { transcript, appendBashOutput } from "./koa-transcript.ts";
import { attachments } from "./koa-attach.ts";
import { prompts } from "./koa-queue.ts";
import { later } from "./koa-timer.ts";
import { errorText, contentText } from "./text.ts";
import type { Dialogs } from "./koa-agents.ts";
import type { Life, State, Dialog, Bash, CommandResult, Attachment } from "./koa-records.ts";

const FLUSH_MS = 50;

type DialogAnswer = { cancelled: true } | { confirmed: boolean } | { value: string };
type Root = { value: "idle" | "working" | "done" | "error"; message: string };
export type Own = Omit<State, "view" | "agents" | "edit">;
type Replaced = "new" | "resume" | "fork" | undefined;

type ViewOptions = {
  dir: string;
  metrics: boolean;
  attached: ReturnType<typeof attachments>;
  name: string | undefined;
  cwd: string;
  home: string;
  agent(): { session: AgentSession; runtime: AgentSessionRuntime };
  compose(own: Own): State;
  status(value: Root["value"] | "clear", message: string, dialog: string | undefined): void;
  title(own: Own): void;
  closed(): boolean;
  cancelEditor(): void;
  shutdown(): void;
  agentsChanged(): void;
};

export type AgentView = ReturnType<typeof createView>;

export function createView(options: ViewOptions) {
  const feed = transcript({ dir: options.dir, flushMs: FLUSH_MS, metrics: options.metrics });
  const { attached } = options;
  const pendingPrompts = prompts();
  let compaction: { root: Root; working: boolean; since?: number } | undefined;
  let compactRequest: { ended: boolean } | undefined;
  let life: Life = { type: "starting" };
  let closed = false;
  const stopping = () => closed || options.closed();
  const state: Omit<Own, "life" | "queue"> = { bash: [], get compaction() { return compaction ? "running" : "idle"; }, working: false, aborted: false, name: options.name ?? "pi", levels: [], cwd: options.cwd, home: options.home, dialogs: [], statuses: {} };
  const own = (): Own => ({ ...state, queue: pendingPrompts.view(), life });
  let root: Root = { value: "idle", message: options.name ?? "pi" };
  let lastText = "";
  const publish = (dialogsChanged = false) => { if (life.type !== "starting" || dialogsChanged) feed.state(options.compose(own())); };
  const status = (value: Root["value"] | "clear", message = state.name) => {
    if (value !== "clear") root = { value, message };
    options.status(value, message, state.dialogs[0]?.title);
  };
  const background = (work: Promise<unknown>) => { void work.catch(error => { if (!stopping()) process.stderr.write(`koa: ${errorText(error)}\n`); }); };
  let sessionStop = new AbortController();
  const newSessionScope = () => { sessionStop.abort(); sessionStop = new AbortController(); };
  const pending = new Map<string, (answer: DialogAnswer) => void>();
  const dialogTimers = new Map<string, NodeJS.Timeout>();
  const cancelDialogs = () => {
    for (const timer of dialogTimers.values()) clearTimeout(timer);
    dialogTimers.clear();
    state.dialogs = [];
    for (const resolve of pending.values()) resolve({ cancelled: true });
    pending.clear();
  };
  const running = () => !stopping() && life.type === "ready";
  const finishCompaction = (result: Extract<CommandResult, { type: "compaction" }>["state"], willRetry = false) => {
    if (compactRequest) compactRequest.ended = true;
    feed.command({ type: "compaction", state: result });
    if (compaction && !willRetry) {
      state.working = compaction.working; state.since = compaction.since;
      if (result.type === "failed") status("error", result.message.split("\n")[0] ?? "");
      else status(compaction.root.value, compaction.root.message);
    }
    compaction = undefined;
    publish();
  };
  const fail = (error: unknown) => {
    cancelDialogs();
    life = { type: "failed", at: Date.now(), message: errorText(error) };
    state.working = false; delete state.since; state.statuses = {}; dropBash();
    process.stderr.write(`koa: ${life.message}\n`);
    status("clear"); publish(true);
  };
  const stats = (notify = true) => {
    const result = options.agent().session.getSessionStats();
    const usage = result.contextUsage;
    state.context = usage && { tokens: usage.tokens, window: usage.contextWindow, percent: usage.percent };
    if (notify) publish();
    return result.totalMessages;
  };
  const levels = (notify = true) => { state.levels = options.agent().session.getAvailableThinkingLevels(); if (notify) publish(); };
  const rebuild = () => {
    const { session } = options.agent();
    const completed: Bash[] = state.working ? [] : state.bash.filter(item => item.phase === "completed");
    const previous = state.bash;
    state.bash = previous.filter(item => !completed.includes(item));
    if (state.bash.length !== previous.length) publish();
    try { feed.rebuild(session.messages, state.sessionId, session.sessionManager.getEntries(), session.sessionManager.getLeafId()); }
    catch (error) { state.bash = previous; publish(); throw error; }
  };
  const refresh = () => {
    if (life.type === "failed" || stopping()) return;
    if (life.type !== "switching" && life.type !== "reloading") life = { type: "starting" };
    const { session, runtime } = options.agent();
    state.sessionId = session.sessionId; state.name = options.name ?? session.sessionName ?? "pi";
    state.model = session.model; state.thinking = session.thinkingLevel; state.sessionFile = session.sessionFile;
    rebuild(); levels(false);
    const count = stats(false);
    state.cwd = runtime.cwd;
    options.title(own());
    if (life.type === "starting" || life.type === "switching" || life.type === "reloading") { life = { type: "ready" }; publish(); }
    return count;
  };
  let bashTimer: NodeJS.Timeout | undefined;
  const dropBash = () => { clearTimeout(bashTimer); bashTimer = undefined; state.bash = []; };
  let bashSerial = 0;
  const settleBash = () => {
    if (state.working || !state.bash.length || state.bash.some(item => item.phase !== "completed")) return;
    rebuild();
  };
  let userAttachments: Attachment[] = [];
  let outcome: { type: "done" } | { type: "error"; message: string } = { type: "done" };
  const firstLine = (text: string) => text.split("\n").find(line => line.trim())?.trim() ?? "";
  let settleWaiter: (() => void) | undefined;
  const event = (event: AgentSessionEvent): void => {
    if (life.type === "failed" || stopping()) return;
    switch (event.type) {
      case "bash_execution_update": {
        const execution = state.bash.find(item => item.id === event.id);
        if (execution && execution.phase !== "completed") {
          execution.output = appendBashOutput(execution.output, event.delta);
          bashTimer ??= later(() => { bashTimer = undefined; publish(); }, FLUSH_MS);
        }
        break;
      }
      case "entry_appended": feed.annotation(event.entry); break;
      case "message_start": {
        if (event.message.role === "user") { userAttachments = pendingPrompts.start(contentText(event.message.content)); attached.consume(userAttachments.map(file => file.id), "used"); }
        feed.message(event.message, "start");
        if (event.message.role === "user") publish();
        break;
      }
      case "message_update": {
        feed.message(event.message, "update");
        const delta = event.assistantMessageEvent;
        if (delta.type === "thinking_start" || delta.type === "thinking_end") feed.thinking(delta.contentIndex, delta.type === "thinking_start" ? "started" : "ended", Date.now());
        break;
      }
      case "message_end":
        if (event.message.role === "custom" && event.message.display) options.agentsChanged();
        feed.message(event.message, "end", event.message.role === "assistant" ? Date.now() : undefined, event.message.role === "user" ? userAttachments : []);
        if (event.message.role === "user") userAttachments = [];
        if (event.message.role === "assistant") {
          outcome = event.message.stopReason === "error" ? { type: "error", message: firstLine(event.message.errorMessage ?? "") } : { type: "done" };
          lastText = firstLine(contentText(event.message.content));
        }
        break;
      case "tool_execution_start": feed.toolRunning(event.toolCallId, Date.now()); break;
      case "tool_execution_update": feed.toolPartial(event.toolCallId, event.partialResult.content); break;
      case "tool_execution_end": if (["spawn_agent", "message_agent", "list_agents", "stop_agent"].includes(event.toolName)) options.agentsChanged(); feed.toolDone(event.toolCallId, event.result.content, event.isError, Date.now(), event.durationMs, event.result.structuredContent, event.result.details); break;
      case "agent_start": state.working = true; state.since = Date.now(); state.aborted = false; outcome = { type: "done" }; lastText = ""; status("working"); publish(); break;
      case "compaction_start": compaction ??= { root, working: state.working, since: state.since }; feed.command({ type: "compaction", state: { type: "running" } }); state.working = true; state.since ??= Date.now(); status("working"); publish(); break;
      case "agent_settled":
        settleWaiter?.(); settleWaiter = undefined; state.working = false; delete state.since; state.aborted = event.aborted;
        status(event.aborted ? "idle" : outcome.type, outcome.type === "error" ? outcome.message : lastText || state.name); publish(); stats(); settleBash();
        break;
      case "queue_update": pendingPrompts.update({ steering: event.steering, followUp: event.followUp }); publish(); break;
      case "thinking_level_changed": state.thinking = event.level; publish(); break;
      case "session_info_changed": if (options.name === undefined) state.name = event.name ?? "pi"; options.title(own()); publish(); break;
      case "compaction_end":
        if (!compaction) { rebuild(); stats(); break; }
        if (event.result) finishCompaction({ type: "done", before: event.result.tokensBefore, after: event.result.estimatedTokensAfter, summary: event.result.summary }, event.willRetry);
        else if (event.errorMessage) finishCompaction({ type: "failed", message: event.errorMessage }, event.willRetry);
        else finishCompaction({ type: "cancelled" }, event.willRetry);
        rebuild(); stats(); break;
      case "turn_end": stats(); break;
    }
  };
  const resetSession = () => {
    state.working = false; state.aborted = false; delete state.since; delete state.editor; delete state.context;
    options.cancelEditor(); dropBash(); pendingPrompts.reset(); userAttachments = []; attached.reset();
    compaction = undefined; outcome = { type: "done" }; lastText = ""; state.statuses = {};
    status("idle");
  };
  let switchingUI: (() => void)[] | undefined;
  const ui = (run: () => void) => { if (switchingUI) switchingUI.push(run); else run(); };
  const removeDialog = (id: string, answer: DialogAnswer = { cancelled: true }) => {
    clearTimeout(dialogTimers.get(id)); dialogTimers.delete(id);
    state.dialogs = state.dialogs.filter(dialog => dialog.id !== id);
    const resolve = pending.get(id); pending.delete(id); resolve?.(answer);
    status(root.value, root.message); publish(true);
  };
  const dialog = <T,>(build: (id: string, timing: { timeout?: number; expires?: number }) => Dialog, opts: { signal?: AbortSignal; timeout?: number } | undefined, map: (answer: DialogAnswer) => T): Promise<T> => new Promise(resolve => {
    if (opts?.signal?.aborted || stopping()) { resolve(map({ cancelled: true })); return; }
    const id = randomUUID(), timeout = opts?.timeout;
    const abort = () => removeDialog(id);
    pending.set(id, answer => { opts?.signal?.removeEventListener("abort", abort); resolve(map(answer)); });
    opts?.signal?.addEventListener("abort", abort, { once: true });
    state.dialogs.push(build(id, timeout !== undefined ? { timeout, expires: Date.now() + timeout } : {}));
    if (timeout !== undefined) dialogTimers.set(id, later(() => removeDialog(id), timeout));
    status(root.value, root.message); publish(true);
  });
  const text = (answer: DialogAnswer) => "value" in answer ? answer.value : undefined;
  const dialogApi: Dialogs = {
    select: (title, choices, opts) => dialog((id, timing) => ({ id, title, method: "select", options: choices, ...timing }), opts, text),
    input: (title, placeholder, opts) => dialog((id, timing) => ({ id, title, method: "input", placeholder, ...timing }), opts, text),
    confirm: (title, message, opts) => dialog((id, timing) => ({ id, title, method: "confirm", message, ...timing }), opts, answer => "confirmed" in answer && answer.confirmed),
    editor: (title, prefill) => dialog(id => ({ id, title, method: "editor", prefill }), undefined, text),
    notify: (message, type) => ui(() => feed.notify(message, type ?? "info")),
    setStatus: (key, value) => ui(() => { if (!value) delete state.statuses[key]; else state.statuses[key] = value; publish(); }),
    setEditorText: value => ui(() => { state.editor = { id: randomUUID(), text: value }; publish(); }),
  };
  const setModel = async (model: Parameters<AgentSession["setModel"]>[0]) => { await options.agent().session.setModel(model); state.model = model; levels(false); publish(); };
  const announce = () => feed.notify(`model: ${state.model?.id ?? ""} · thinking ${state.thinking ?? "off"}`, "info");
  const replaySwitching = () => { const buffered = switchingUI; switchingUI = undefined; for (const run of buffered ?? []) run(); };
  const replaced = (kind: Replaced) => {
    if (kind) {
      try {
        const count = refresh();
        feed.notify(kind === "new" ? "new session" : `session: ${state.name} · ${count ?? 0} messages`, "info");
      } catch (error) {
        feed.rebuild([], state.sessionId); feed.notify(errorText(error), "error");
        life = { type: "ready" }; options.title(own()); publish();
      }
    } else { life = { type: "ready" }; publish(); }
    replaySwitching();
  };
  let queueChain: Promise<unknown> = Promise.resolve();
  const serial = <T>(run: () => Promise<T>): Promise<T> => {
    const next = queueChain.then(run, run);
    queueChain = next.catch(() => undefined);
    return next;
  };
  const reloadBusy = () => !running() || state.working || compaction || compactRequest && !compactRequest.ended || state.bash.some(item => item.phase !== "completed") || pendingPrompts.view().steering.length || pendingPrompts.view().followUp.length || state.dialogs.length;
  const hooks = {
    ui: dialogApi,
    onEvent: event,
    rebind: (session: AgentSession) => {
      cancelDialogs(); newSessionScope(); resetSession();
      state.sessionId = session.sessionId; state.cwd = session.sessionManager.getCwd(); state.name = options.name ?? "pi";
      delete state.sessionFile; delete state.model; delete state.thinking; state.levels = [];
    },
    replacing: () => { cancelDialogs(); newSessionScope(); switchingUI = []; life = { type: "switching" }; publish(); },
    replaced,
    replaceFailed: (error: unknown, torn: boolean) => { replaySwitching(); if (torn) fail(error); else { life = { type: "ready" }; publish(); } },
    treeNavigated: (editorText: string | undefined) => { rebuild(); if (editorText) state.editor = { id: randomUUID(), text: editorText }; publish(); },
    notify: (message: string, level: "info" | "warning" | "error") => feed.notify(message, level),
    shutdown: () => options.shutdown(),
  };
  return {
    feed, attached, prompts: pendingPrompts, state, hooks, own,
    get life() { return life; },
    set life(next: Life) { life = next; },
    get root() { return root; },
    get sessionStop() { return sessionStop.signal; },
    get compaction() { return compaction; },
    get compactRequest() { return compactRequest; },
    set compactRequest(next: { ended: boolean } | undefined) { compactRequest = next; },
    settleWait: () => new Promise<void>(resolve => { settleWaiter = resolve; }),
    clearSettleWait: () => { settleWaiter = undefined; },
    nextBash: () => String(++bashSerial),
    title: () => options.title(own()),
    publish, status, background, running, stopping, newSessionScope, cancelDialogs, removeDialog, finishCompaction, fail, stats, levels, rebuild, refresh, resetSession,
    replaySwitching, setModel, announce, serial, reloadBusy, settleBash, dropBash,
    clearBashTimer: () => { clearTimeout(bashTimer); bashTimer = undefined; },
    begin: () => { switchingUI = []; },
    close: () => { closed = true; cancelDialogs(); sessionStop.abort(); dropBash(); feed.close(); rmSync(options.dir, { recursive: true, force: true }); },
  };
}

