import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFile, writeFile } from "node:fs/promises";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { AgentSession, AgentSessionEvent, SlashCommandSource } from "@earendil-works/pi-coding-agent";
import { transcript, bashResult, appendBashOutput } from "./koa-transcript.ts";
import { later } from "./koa-timer.ts";
import { respond, readBody } from "./koa-http.ts";
import { isRecord, errorText, replaceControlCharacters, utf8Prefix, contentText } from "./text.ts";
import { webview } from "../webview/index.ts";
import { assemblePage } from "./koa-assemble.ts";
import { complete, findFd, agentDiscovery } from "./koa-complete.ts";
import { pickSession, piPackage } from "./koa-child.ts";
import { loadSdk } from "./koa-sdk.ts";
import { restartArgs, startupResult } from "./koa-args.ts";
import { shellComplete } from "./koa-shell.ts";
import { attachments, stepFile, UPLOAD_IDLE_MS, isChunkRoute } from "./koa-attach.ts";
import { commandCatalog, parseCommand, dispatchCommand, deferralText, type Deferral } from './koa-commands.ts';
import { installedIdentity } from './koa-identity.ts';
import { bashCommand } from "./prompt.ts";
import { prompts } from "./koa-queue.ts";
import { koaEditor } from "./koa-editor.ts";
import { findKo, apiArgs } from "./runtime-exec.ts";
import type { AgentHost, Dialogs } from "./koa-agents.ts";
import { ATTACHMENT_LIMITS, type PromptMode, type PageRecord, type Pi, type State, type ThinkingLevel, type Dialog, type CompletionCommand, type Attachment, type CompletionQuery, type SessionStats, type CommandResult, type Bash } from "./koa-records.ts";

function completeBody(value: unknown): CompletionQuery | { error: string } {
  return isRecord(value) && typeof value.text === "string" && typeof value.pos === "number" && Number.isSafeInteger(value.pos) && value.pos >= 0 && value.pos <= value.text.length ? { text: value.text, pos: value.pos } : { error: "Completion requires text and a cursor offset in that text" };
}

function idBody(value: unknown): { id: string } | { error: string } {
  return isRecord(value) && typeof value.id === "string" ? { id: value.id } : { error: "An id is required" };
}

function modelBody(value: unknown): { provider: string; modelId: string } | { error: string } {
  return isRecord(value) && typeof value.provider === "string" && typeof value.modelId === "string" ? { provider: value.provider, modelId: value.modelId } : { error: "A provider and modelId are required" };
}

function thinkingBody(value: unknown, levels: readonly ThinkingLevel[]): { level: ThinkingLevel } | { error: string } {
  const available = (level: unknown): level is ThinkingLevel => levels.some(value => value === level);
  return isRecord(value) && available(value.level) ? { level: value.level } : { error: "An available thinking level is required" };
}

type DialogAnswer = { cancelled: true } | { confirmed: boolean } | { value: string };
function dialogBody(value: unknown, dialog: Dialog): DialogAnswer | { error: string } {
  if (isRecord(value)) {
    if (value.cancelled === true) return { cancelled: true };
    if (dialog.method === "confirm" && typeof value.confirmed === "boolean") return { confirmed: value.confirmed };
    if (dialog.method !== "confirm" && typeof value.value === "string" && (dialog.method !== "select" || dialog.options.includes(value.value))) return { value: value.value };
  }
  return { error: "A valid dialog answer is required" };
}

function promptBody(value: unknown): { text: string; mode: PromptMode | "steer"; attachments: string[] } | { error: string } {
  if (isRecord(value) && typeof value.text === "string" && Array.isArray(value.attachments) && value.attachments.length <= ATTACHMENT_LIMITS.files && value.attachments.every(id => typeof id === "string") && (value.text.trim() || value.attachments.length) && (value.mode === "prompt" || value.mode === "steer" || value.mode === "follow_up")) return { text: value.text, mode: value.mode, attachments: value.attachments };
  return { error: "Text or attachments and prompt, steer or follow_up mode are required" };
}

type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const thinkingLevelsMatch: Same<ThinkingLevel, import("@earendil-works/pi-agent-core").ThinkingLevel> = true;
const statsMatch: Same<SessionStats, ReturnType<AgentSession['getSessionStats']>> = true;
const commandSourcesMatch: Same<Exclude<CompletionCommand["source"], 'builtin'>, SlashCommandSource> = true;
void [thinkingLevelsMatch, commandSourcesMatch, statsMatch];

const MAX_PENDING_BASH = 16;
const FLUSH_MS = 50;
const QUIT_REPLY_MS = 1000;
const HOST_STOP_MS = 5000;

type Access = "ready" | "session" | "alive" | "dialog" | "failed" | "any";

type Root = { value: "idle" | "working" | "done" | "error"; message: string };

async function withRequestSignal(response: ServerResponse, lifetime: AbortSignal, work: (signal: AbortSignal) => Promise<void>) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  response.once("close", abort);
  const signal = AbortSignal.any([controller.signal, lifetime]);
  try { await work(signal); }
  catch (error) { if (!signal.aborted) throw error; }
  finally { response.off("close", abort); }
}

async function main(): Promise<void> {
  process.stderr.on("error", () => {});
  process.stdout.on("error", () => {});
  const pane = process.env.KO_PANE, ko = findKo();
  let crashed = false;
  process.on("uncaughtException", error => {
    if (crashed) return;
    crashed = true;
    process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
    if (pane && ko) { try { spawnSync(ko, apiArgs("PATCH", `/panes/${pane}`, { close: "keep" }), { input: JSON.stringify({ close: "keep" }), timeout: 2000, stdio: ["pipe", "ignore", "ignore"] }); } catch {} }
    process.exit(1);
  });
  const reloaded = process.env.KOA_RELOAD === '1';
  delete process.env.KOA_RELOAD;
  const location = pathToFileURL(process.argv[1] ?? "");
  const args = process.argv.slice(2);
  const endOptions = args.indexOf('--');
  const options = args.slice(0, endOptions < 0 ? args.length : endOptions);
  if (options.some(arg => arg === '--help' || arg === '-h')) {
    process.stdout.write("Usage: koa [options] [pi arguments]\n\nOptions:\n  --help                 Show this help\n  --browser              Open the page in a browser\n  --pi PATH              Use this pi executable\n  --metrics PATH         Write rendering metrics\n  --metrics-mode MODE    Select applied or frame metrics\n\nOther arguments go to pi.\n");
    return;
  }
  let browser = false;
  let metricsFile: string | undefined;
  let metricsMode: "applied" | "frame" | undefined;
  let executable = "pi";
  const pass: string[] = [], own: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i], first = i;
    if (arg === '--') { pass.push(...args.slice(i)); break; }
    if (arg === "--browser") browser = true;
    else if (arg === "--metrics") {
      metricsFile = args[++i];
      if (!metricsFile) throw new Error("--metrics requires a path");
    } else if (arg === "--metrics-mode") {
      const mode = args[++i];
      if (mode !== "applied" && mode !== "frame") throw new Error("--metrics-mode requires applied or frame");
      metricsMode = mode;
    } else if (arg === "--pi") {
      const path = args[++i];
      if (!path) throw new Error("--pi requires a path");
      executable = path;
    } else if (arg !== undefined) { pass.push(arg); continue; }
    own.push(...args.slice(first, i + 1));
  }
  if (metricsMode && !metricsFile) throw new Error("--metrics-mode requires --metrics");
  const reloadPage = process.env.KOA_PAGE_RELOAD === '1';
  const page = reloadPage ? undefined : await assemblePage(location);
  const identity = await installedIdentity(location).catch(() => undefined);
  const uploadIdleMs = Number(process.env.KOA_UPLOAD_IDLE_MS ?? UPLOAD_IDLE_MS);
  if (!Number.isFinite(uploadIdleMs) || uploadIdleMs <= 0) throw Error("KOA_UPLOAD_IDLE_MS must be positive");
  const packageRoot = await piPackage(executable, process.env.PATH ?? '');
  if (!packageRoot) throw Error(`cannot find pi's package from ${executable}`);
  const sdk = await loadSdk(packageRoot);
  const checked = startupResult(sdk.pi.parseArgs(pass));
  if ('error' in checked) throw Error(checked.error);
  let initialMessages: string[] = reloaded ? [] : checked.messages;
  const resume = !reloaded && checked.resume;
  const koaAgents = await import('./koa-agents.ts');
  const agentDir = sdk.pi.getAgentDir();
  const { catalog, completion } = await commandCatalog(packageRoot);
  if (resume) {
    const configured = Number(process.env.KOA_RESUME_READY_MS ?? 10000);
    const readyMs = Number.isFinite(configured) && configured > 0 ? configured : 10000;
    const result = await pickSession(executable, pass, fileURLToPath(new URL("./koa-resume.ts", location)), readyMs);
    if (result.type === "cancel") { process.stderr.write("No session selected\n"); return; }
    if (result.type === "selected") {
      const end = pass.indexOf("--");
      pass.splice(end < 0 ? pass.length : end, 0, "--session", result.path);
    }
  }
  if (metricsFile) await writeFile(metricsFile, "");
  const view = await webview({ target: browser ? "browser" : "pane" });
  if (!view) throw new Error("koa requires a Kido pane or --browser");
  let reloading = false;
  const teardown: (() => void | Promise<void>)[] = [() => view.close(!reloading).catch(error => { process.stderr.write(`koa: close: ${errorText(error)}\n`); })];
  let shutdownPromise: Promise<void> | undefined;
  let stopHost: (() => Promise<void>) | undefined;
  const shutdown = () => shutdownPromise ??= (async () => {
    const stopped = Promise.resolve(stopHost?.()).catch(error => { process.stderr.write(`koa: ${errorText(error)}\n`); });
    await Promise.race([stopped, new Promise<void>(resolve => { later(resolve, HOST_STOP_MS).unref(); })]);
    await Promise.allSettled(teardown.reverse().map(async close => close()));
  })();
  const flushed = () => Promise.all([process.stdout, process.stderr].map(stream => new Promise<void>(resolve => { const timer = later(resolve, QUIT_REPLY_MS); stream.write("", () => { clearTimeout(timer); resolve(); }); })));
  const quit = () => shutdown().then(flushed).then(() => process.exit(process.exitCode ?? 0));
  const start = async () => {
    let metricsWrites: Promise<void> | undefined;
    const dir = mkdtempSync(join(tmpdir(), `koa-${process.pid}-`));
    const removeDir = () => { try { rmSync(dir, { recursive: true, force: true }); } catch (error) { process.stderr.write(`koa: ${errorText(error)}\n`); } };
    process.once("exit", removeDir);
    teardown.push(() => { removeDir(); process.off("exit", removeDir); });
    const feed = transcript({ dir, flushMs: FLUSH_MS, metrics: metricsFile !== undefined });
    teardown.push(() => feed.close());
    const attached = attachments(join(dir, "attachments"), uploadIdleMs);
    teardown.push(() => attached.close());
    const pendingPrompts = prompts();
    const fd = findFd(process.env.KOA_FD, agentDir, process.env.PATH ?? "");
    if (!fd) process.stderr.write("koa: fd not found; file completion is unavailable\n");
    const lifetime = new AbortController();
    teardown.push(() => lifetime.abort());
    const agents = agentDiscovery(process.env.KO_PANE ?? "", process.env.KO_AGENT_LIST_TTL_MS, lifetime.signal);
    let compaction: { root: Root; working: boolean; since?: number } | undefined;
    let compactRequest: { ended: boolean } | undefined;
    let settled: (() => void) | undefined;
    const state: Omit<State, "pi" | "queue"> = { get edit() { return edits.view(); }, agents: [], bash: [], get compaction() { return compaction ? 'running' : 'idle'; }, working: false, aborted: false, name: "pi", levels: [], cwd: process.cwd(), home: homedir(), dialogs: [], statuses: {} };
    let stopping = false;
    teardown.push(() => { stopping = true; });
    stopHost = async () => { stopping = true; cancelDialogs(); if (started) await host.dispose(); };
    const edits = koaEditor({
      agentDir, cwd: () => state.cwd, session: () => state.sessionId, name: () => state.name,
      replace: text => { state.editor = { id: randomUUID(), text }; publish(); },
      notify: (text, level) => feed.notify(text, level), changed: () => publish(),
    });
    teardown.push(() => edits.cancel());
    let pi: Pi = { type: "starting" };
    const running = () => !stopping && pi.type === "ready";
    let root: Root = { value: "idle", message: state.name };
    const publish = (dialogsChanged = false) => { if (pi.type !== "starting" || dialogsChanged) feed.state({ ...state, queue: pendingPrompts.view(), pi }); };
    const refreshAgents = () => void agents.live().then(rows => {
      const next = rows.filter(row => !row.self && row.named).map(({ name, pane }) => ({ name, pane }));
      if (JSON.stringify(next) !== JSON.stringify(state.agents)) { state.agents = next; publish(); }
    });
    refreshAgents();
    const status = (value: Root["value"] | "clear", message = state.name) => {
      if (value !== "clear") root = { value, message };
      const dialog = state.dialogs[0];
      const encoded = Buffer.from(utf8Prefix(replaceControlCharacters(dialog?.title ?? message).replace(/\s+/g, " ").trim(), 2048)).toString("base64");
      process.stdout.write(`\x1b]7501;state=${value === "clear" ? value : dialog ? "blocked" : value}${value === "clear" ? "" : `:app=pi${dialog ? ":kind=question" : ""}:msg=${encoded}`}\x1b\\`);
    };
    const title = () => process.stdout.write(`\x1b]0;${utf8Prefix(replaceControlCharacters(`koa - ${state.name} - ${basename(state.cwd)}`), 2048)}\x1b\\`);
    const unstarted = (): never => { throw new Error("the agent is not started"); };
    let started = false;
    let host: AgentHost = { get facts() { return unstarted(); }, get runtime() { return unstarted(); }, get session() { return unstarted(); }, slots: {}, browser, extension: undefined, notify: unstarted, list: unstarted, start: unstarted, usable: unstarted, newSession: unstarted, switchSession: unstarted, dispose: unstarted };
    let sessionStop = new AbortController();
    const newSessionScope = () => { sessionStop.abort(); sessionStop = new AbortController(); };
    teardown.push(() => sessionStop.abort());
    const pending = new Map<string, (answer: DialogAnswer) => void>();
    const dialogTimers = new Map<string, NodeJS.Timeout>();
    const cancelDialogs = () => {
      for (const timer of dialogTimers.values()) clearTimeout(timer);
      dialogTimers.clear();
      state.dialogs = [];
      for (const resolve of pending.values()) resolve({ cancelled: true });
      pending.clear();
    };
    teardown.push(cancelDialogs);
    const background = (work: Promise<unknown>) => { void work.catch(error => { if (!stopping) process.stderr.write(`koa: ${errorText(error)}\n`); }); };
    const finishCompaction = (result: Extract<CommandResult, { type: 'compaction' }>['state'], willRetry = false) => {
      if (compactRequest) compactRequest.ended = true;
      feed.command({ type: 'compaction', state: result });
      if (compaction && !willRetry) {
        state.working = compaction.working; state.since = compaction.since;
        if (result.type === 'failed') status('error', result.message.split('\n')[0]);
        else status(compaction.root.value, compaction.root.message);
      }
      compaction = undefined;
      publish();
    };
    const fail = (error: unknown) => {
      cancelDialogs();
      pi = { type: "failed", at: Date.now(), message: errorText(error) };
      state.working = false; delete state.since; state.statuses = {}; dropBash();
      process.stderr.write(`koa: ${pi.message}\n`);
      status("clear"); publish(true);
    };
    const stats = (notify = true) => {
      const result = host.session.getSessionStats();
      const usage = result.contextUsage;
      state.context = usage && { tokens: usage.tokens, window: usage.contextWindow, percent: usage.percent };
      if (notify) publish();
      return result.totalMessages;
    };
    const levels = (notify = true) => { state.levels = host.session.getAvailableThinkingLevels(); if (notify) publish(); };
    const rebuild = () => {
      const completed: Bash[] = state.working ? [] : state.bash.filter(item => item.phase === 'completed');
      const previous = state.bash;
      state.bash = previous.filter(item => !completed.includes(item));
      if (state.bash.length !== previous.length) publish();
      try { feed.rebuild(host.session.messages, state.sessionId, host.session.sessionManager.getEntries(), host.session.sessionManager.getLeafId()); }
      catch (error) { state.bash = previous; publish(); throw error; }
    };
    const refresh = () => {
      if (pi.type === "failed" || stopping) return;
      if (pi.type !== "switching" && pi.type !== "reloading") pi = { type: "starting" };
      const session = host.session;
      state.sessionId = session.sessionId; state.name = session.sessionName ?? "pi";
      state.model = session.model; state.thinking = session.thinkingLevel; state.sessionFile = session.sessionFile;
      rebuild(); levels(false);
      const count = stats(false);
      state.cwd = host.runtime.cwd;
      title();
      if (pi.type === "starting" || pi.type === "switching" || pi.type === "reloading") { pi = { type: "ready" }; publish(); }
      return count;
    };
    let bashTimer: NodeJS.Timeout | undefined;
    const dropBash = () => { clearTimeout(bashTimer); bashTimer = undefined; state.bash = []; };
    teardown.push(dropBash);
    let bashSerial = 0;
    const settleBash = () => {
      if (state.working || !state.bash.length || state.bash.some(item => item.phase !== 'completed')) return;
      rebuild();
    };
    let userAttachments: Attachment[] = [];
    let outcome: { type: "done" } | { type: "error"; message: string } = { type: "done" };
    const event = (event: AgentSessionEvent): void => {
      if (pi.type === "failed" || stopping) return;
      switch (event.type) {
        case 'bash_execution_update':
          const execution = state.bash.find(item => item.id === event.id);
          if (execution && execution.phase !== 'completed') {
            execution.output = appendBashOutput(execution.output, event.delta);
            bashTimer ??= later(() => { bashTimer = undefined; publish(); }, FLUSH_MS);
          }
          break;
        case 'entry_appended': feed.annotation(event.entry); break;
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
          if (event.message.role === "custom" && event.message.display) refreshAgents();
          feed.message(event.message, "end", event.message.role === "assistant" ? Date.now() : undefined, event.message.role === "user" ? userAttachments : []);
          if (event.message.role === "user") userAttachments = [];
          if (event.message.role === "assistant") {
            outcome = event.message.stopReason === "error" ? { type: "error", message: (event.message.errorMessage ?? "").split("\n")[0] ?? "" } : { type: "done" };
          }
          break;
        case "tool_execution_start": feed.toolRunning(event.toolCallId, Date.now()); break;
        case "tool_execution_update": feed.toolPartial(event.toolCallId, event.partialResult.content); break;
        case "tool_execution_end": if (event.toolName === "spawn_agent" || event.toolName === "message_agent" || event.toolName === "list_agents" || event.toolName === "stop_agent") refreshAgents(); feed.toolDone(event.toolCallId, event.result.content, event.isError, Date.now(), event.durationMs, event.result.structuredContent, event.result.details); break;
        case "agent_start": state.working = true; state.since = Date.now(); state.aborted = false; outcome = { type: "done" }; status("working"); publish(); break;
        case 'compaction_start': compaction ??= { root, working: state.working, since: state.since }; feed.command({ type: 'compaction', state: { type: 'running' } }); state.working = true; state.since ??= Date.now(); status('working'); publish(); break;
        case "agent_settled": settled?.(); settled = undefined; state.working = false; delete state.since; state.aborted = event.aborted; status(event.aborted ? "idle" : outcome.type, outcome.type === "error" ? outcome.message : state.name); publish(); stats(); settleBash(); break;
        case "queue_update": pendingPrompts.update({ steering: event.steering, followUp: event.followUp }); publish(); break;
        case "thinking_level_changed": state.thinking = event.level; publish(); break;
        case "session_info_changed": state.name = event.name ?? "pi"; title(); publish(); break;
        case 'compaction_end':
          if (!compaction) { rebuild(); stats(); break; }
          if (event.result) finishCompaction({ type: 'done', before: event.result.tokensBefore, after: event.result.estimatedTokensAfter, summary: event.result.summary }, event.willRetry);
          else if (event.errorMessage) finishCompaction({ type: 'failed', message: event.errorMessage }, event.willRetry);
          else finishCompaction({ type: 'cancelled' }, event.willRetry);
          rebuild(); stats(); break;
        case "turn_end": stats(); break;
      }
    };
    const resetSession = () => {
      state.working = false; state.aborted = false; delete state.since; delete state.editor; delete state.context;
      void edits.cancel(); dropBash(); pendingPrompts.reset(); userAttachments = []; attached.reset();
      compaction = undefined; outcome = { type: "done" }; state.statuses = {};
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
      if (opts?.signal?.aborted || stopping) { resolve(map({ cancelled: true })); return; }
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
      select: (title, options, opts) => dialog((id, timing) => ({ id, title, method: "select", options, ...timing }), opts, text),
      input: (title, placeholder, opts) => dialog((id, timing) => ({ id, title, method: "input", placeholder, ...timing }), opts, text),
      confirm: (title, message, opts) => dialog((id, timing) => ({ id, title, method: "confirm", message, ...timing }), opts, answer => "confirmed" in answer && answer.confirmed),
      editor: (title, prefill) => dialog(id => ({ id, title, method: "editor", prefill }), undefined, text),
      notify: (message, type) => ui(() => feed.notify(message, type ?? "info")),
      setStatus: (key, value) => ui(() => { if (!value) delete state.statuses[key]; else state.statuses[key] = value; publish(); }),
      setEditorText: value => ui(() => { state.editor = { id: randomUUID(), text: value }; publish(); }),
    };
    const setModel = async (model: Parameters<typeof host.session.setModel>[0]) => { await host.session.setModel(model); state.model = model; levels(false); publish(); };
    const announce = () => feed.notify(`model: ${state.model?.id ?? ''} · thinking ${state.thinking ?? 'off'}`, 'info');
    const replaySwitching = () => { const buffered = switchingUI; switchingUI = undefined; for (const run of buffered ?? []) run(); };
    const replaced = (kind: "new" | "resume" | "fork" | undefined) => {
      if (kind) {
        try {
          const count = refresh();
          feed.notify(kind === "new" ? "new session" : `session: ${state.name} · ${count ?? 0} messages`, "info");
        } catch (error) {
          feed.rebuild([], state.sessionId); feed.notify(errorText(error), "error");
          pi = { type: "ready" }; title(); publish();
        }
      } else { pi = { type: "ready" }; publish(); }
      replaySwitching();
    };
    const switchSession = async (file: string | undefined, response: ServerResponse) => {
      try { respond(response, 200, JSON.stringify(await (file ? host.switchSession(file) : host.newSession()))); }
      catch (error) { if (pi.type !== "failed") throw error; respond(response, 409, JSON.stringify({ error: errorText(error) })); }
    };
    const checkSession = (value: unknown) => { if (!isRecord(value) || value.sessionId !== state.sessionId) throw new Error("pi session changed"); };
    const access = (mode: Access, value?: unknown) => {
      switch (mode) {
        case "session":
          checkSession(value);
          if (!running()) throw new Error(pi.type === "starting" ? "pi is starting" : "pi is not ready");
          break;
        case "dialog":
          checkSession(value);
          if (stopping || pi.type === "failed") throw new Error("pi is not running");
          break;
        case "ready": if (!running()) throw new Error(pi.type === "starting" ? "pi is starting" : "pi is not ready"); break;
        case "alive": if (stopping || pi.type === "failed" || pi.type === "switching" || pi.type === "reloading") throw new Error("pi is not running"); break;
        case "failed": if (stopping || pi.type !== "failed") throw new Error("the agent is already running"); break;
        case "any": break;
        default: { const unexpected: never = mode; throw new Error(unexpected); }
      }
    };
    const instance = randomUUID();
    const restartKoa = (response: ServerResponse) => {
      response.setHeader("Connection", "close");
      const restart = () => {
        if (reloading) return;
        reloading = true;
        void shutdown().then(() => Promise.all([process.stdout, process.stderr].map(stream => new Promise<void>(resolve => { const timer = later(resolve, QUIT_REPLY_MS); stream.write("", () => { clearTimeout(timer); resolve(); }); })))).then(() => { if (!process.execve) throw Error("this node has no process.execve"); process.execve(process.execPath, [process.execPath, ...process.execArgv, process.argv[1] ?? "", ...own, ...restartArgs(pass, state.sessionFile)], { ...process.env, KOA_RELOAD: "1" }); }).catch(error => { process.stderr.write(`koa: reload: ${errorText(error)}\n`); process.exitCode = 1; });
      };
      const timer = later(restart, QUIT_REPLY_MS);
      response.once("finish", () => { clearTimeout(timer); restart(); });
      respond(response, 200, JSON.stringify({ disposition: "handled", action: { type: "reload" } }));
    };
    const reloadBusy = () => !running() || state.working || compaction || compactRequest && !compactRequest.ended || state.bash.some(item => item.phase !== 'completed') || pendingPrompts.view().steering.length || pendingPrompts.view().followUp.length || state.dialogs.length || edits.busy();
    const deferred = (): Deferral | undefined => {
      const restart = host.extension?.restartState();
      return restart?.type === "blocked" ? restart.jobs ? { type: "jobs", count: restart.jobs } : { type: "children", count: restart.children } : !state.sessionFile ? { type: "no_session" } : undefined;
    };
    const createHost = async () => {
      pi = { type: "starting" }; resetSession(); newSessionScope(); publish(true);
      try {
        host = await koaAgents.createRootHost({
          sdk, args: sdk.pi.parseArgs(restartArgs(pass, state.sessionFile)), cwd: process.cwd(), agentDir, facts: koaAgents.hostFacts(process.env), browser, ui: koaAgents.uiContext(sdk, dialogApi),
          onEvent: event,
          rebind: session => {
            cancelDialogs(); newSessionScope(); resetSession();
            state.sessionId = session.sessionId; state.cwd = session.sessionManager.getCwd(); state.name = "pi";
            delete state.sessionFile; delete state.model; delete state.thinking; state.levels = [];
          },
          replacing: () => { cancelDialogs(); newSessionScope(); switchingUI = []; pi = { type: "switching" }; publish(); },
          replaced,
          replaceFailed: (error, torn) => { replaySwitching(); if (torn) fail(error); else { pi = { type: "ready" }; publish(); } },
          treeNavigated: editorText => { rebuild(); if (editorText) state.editor = { id: randomUUID(), text: editorText }; publish(); },
          notify: (message, level) => feed.notify(message, level),
          shutdown: () => background(quit()),
        });
        started = true;
        await host.start();
        await refresh();
        return true;
      } catch (error) { fail(error); return false; }
    };
    const reload = async (response: ServerResponse) => {
      cancelDialogs(); newSessionScope(); switchingUI = []; pi = { type: "reloading" }; state.statuses = {}; publish();
      let failure: unknown;
      try {
        await host.session.reload();
        await refresh();
      } catch (error) { failure = error ?? Error("reload failed"); }
      if (pi.type === "reloading") { pi = { type: "ready" }; publish(); }
      replaySwitching();
      const answer = () => respond(response, 200, JSON.stringify({ disposition: "handled", action: { type: "none" } }));
      if (failure !== undefined) { feed.notify(errorText(failure), "error"); answer(); return; }
      const now = await installedIdentity(location).catch(() => undefined);
      if (identity === undefined || now === undefined || now === identity) { feed.notify("reloaded", "info"); answer(); return; }
      const deferral = deferred();
      if (deferral) feed.notify(deferralText(deferral), "info");
      else if (reloadBusy()) feed.notify("reloaded", "info");
      else { restartKoa(response); return; }
      answer();
    };
    let queueChain: Promise<unknown> = Promise.resolve();
    const serial = <T>(run: () => Promise<T>): Promise<T> => {
      const next = queueChain.then(run, run);
      queueChain = next.catch(() => undefined);
      return next;
    };
    const owned = (owner: AgentSession) => { if (host.session !== owner || !host.usable(owner)) throw new Error("pi session changed"); };
    const queuePrompt = async (session: AgentSession, text: string, requested: PromptMode | "steer", files: Awaited<ReturnType<typeof attached.prepare>>) => {
      const message = [text, ...files.paths].filter(Boolean).join("\n");
      const mode = state.working ? requested === "follow_up" ? "followUp" : "steer" : "prompt";
      const entry = pendingPrompts.add(message, mode, files.files);
      try {
        const disposition = await koaAgents.submitPrompt(host, session, message, { ...(files.images.length ? { images: files.images } : {}), ...(mode !== "prompt" ? { streamingBehavior: mode } : {}) });
        return { entry, disposition };
      } catch (error) { pendingPrompts.reject(entry); throw error; }
    };
    const routes: Record<string, { method: "GET" | "POST"; access: Access; handle(value: unknown, response: ServerResponse): void | Promise<void> }> = {
      "/complete": { method: "POST", access: "alive", handle: async (value, response) => {
        const query = completeBody(value);
        if ("error" in query) { respond(response, 400, JSON.stringify(query)); return; }
        checkSession(value);
        await withRequestSignal(response, lifetime.signal, async requestSignal => {
          const bang = bashCommand(query.text), owner = host.session, ownerSession = state.sessionId;
          const signal = AbortSignal.any([requestSignal, sessionStop.signal, ...(bang ? [AbortSignal.timeout(2000)] : [])]);
          const result = bang ? await shellComplete(query.text, query.pos, await (host.extension?.completionContext(signal) ?? Promise.resolve({ type: 'unavailable' as const })), 'ko', signal, bang) : await complete(query.text, query.pos, { cwd: state.cwd, fd, signal, agents, commands: async () => {
            if (pi.type !== "ready") return [];
            return [...completion, ...koaAgents.commandList(host.session).filter(value => !catalog.some(builtin => builtin.name === value.name))];
          } });
          if (!requestSignal.aborted) respond(response, signal.aborted || owner !== host.session || ownerSession !== state.sessionId ? 409 : 200, JSON.stringify(result));
        });
      } },
      "/sessions/list": { method: "POST", access: "ready", handle: async (value, response) => {
        if (!isRecord(value) || (value.scope !== "current" && value.scope !== "all")) { respond(response, 400, "{}"); return; }
        const scope = value.scope;
        await withRequestSignal(response, lifetime.signal, async signal => {
          const rows = await host.list(scope, signal);
          if (!signal.aborted) respond(response, 200, JSON.stringify({ rows }));
        });
      } },
      "/sessions/switch": { method: "POST", access: "session", handle: (value, response) => {
        if (!isRecord(value) || typeof value.path !== "string" || !value.path) { respond(response, 400, "{}"); return; }
        return switchSession(value.path, response);
      } },
      "/sessions/new": { method: "POST", access: "session", handle: (_value, response) => switchSession(undefined, response) },
      "/models": { method: "GET", access: "ready", handle: (_value, response) => respond(response, 200, JSON.stringify({ models: host.session.modelRuntime.getAvailableSnapshot() })) },
      "/prompt": { method: "POST", access: "session", handle: async (value, response) => {
        const builtin = isRecord(value) && typeof value.text === 'string' ? parseCommand(value.text, catalog) : undefined;
        const prompt = promptBody(builtin && isRecord(value) ? { ...value, attachments: [] } : value);
        if ("error" in prompt) { respond(response, 400, JSON.stringify(prompt)); return; }
        const bash = bashCommand(prompt.text);
        if (bash) {
          const refusal = prompt.attachments.length ? 'a command takes no attachments' : state.bash.some(item => item.phase !== 'completed') ? 'a command is already running' : state.bash.length >= MAX_PENDING_BASH ? 'too many commands wait for the turn to end' : !bash.command.trim() ? 'a command is required' : undefined;
          if (refusal) { respond(response, 409, JSON.stringify({ error: refusal })); return; }
          const { command: shellCommand, excludeFromContext } = bash;
          const owner = host.session, ownerSession = state.sessionId;
          let running: (Bash & { phase: 'running' | 'cancelling' }) | undefined;
          background((async () => {
            try {
              const id = String(++bashSerial);
              running = { id, command: shellCommand, excludeFromContext, phase: 'running', started: Date.now(), output: { text: '', cut: 0 } };
              state.bash.push(running); publish();
              const result = await koaAgents.runBash(owner, shellCommand, excludeFromContext, id);
              if (owner !== host.session || ownerSession !== state.sessionId || !running || !state.bash.includes(running)) return;
              const completed: Bash = { id: running.id, command: shellCommand, excludeFromContext, phase: 'completed', started: running.started, ended: Date.now(), result: bashResult(result) };
              state.bash = state.bash.map(item => item === running ? completed : item);
              clearTimeout(bashTimer); bashTimer = undefined; publish();
              settleBash();
            } catch (error) {
              if (running && state.bash.includes(running)) { state.bash = state.bash.filter(item => item !== running); publish(); feed.notify(errorText(error), 'error'); }
              else if (owner === host.session && ownerSession === state.sessionId) throw error;
            }
          })());
          respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return;
        }
        if (builtin) {
          const action = await dispatchCommand(builtin, {
            packageRoot, session: host.session, notify: feed.notify, outcome: feed.command,
            stats: () => feed.command({ type: 'session', stats: host.session.getSessionStats(), name: state.name, model: state.model, thinking: state.thinking }),
            thinking: async level => {
              const parsed = thinkingBody({ level: level.toLowerCase() }, state.levels);
              if ('error' in parsed) { feed.notify(`Unknown thinking level: ${level}`, 'warning'); return; }
              host.session.setThinkingLevel(parsed.level); announce();
            },
            setModel: async model => { await setModel(model); announce(); },
            compact: instructions => {
              if (compaction || compactRequest && !compactRequest.ended) return;
              const request = { ended: false }; compactRequest = request;
              background(host.session.compact(instructions).catch(error => { if (!request.ended) finishCompaction({ type: 'failed', message: errorText(error) }); }).finally(() => { if (compactRequest === request) compactRequest = undefined; }));
            },
            reloadBusy: () => !!reloadBusy(),
          });
          if (action.type === 'quit') { await routes['/quit']?.handle({}, response); return; }
          if (action.type === 'reload') { await reload(response); return; }
          if (action.type === 'restart') { restartKoa(response); return; }
          respond(response, 200, JSON.stringify({ disposition: 'handled', action })); return;
        }
        access("session", value);
        const owner = host.session;
        const files = await attached.prepare(prompt.attachments);
        const { entry, disposition } = await serial(async () => { owned(owner); return queuePrompt(owner, prompt.text, prompt.mode, files); });
        if (disposition === 'handled') { pendingPrompts.reject(entry); respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return; }
        attached.consume(prompt.attachments, disposition === "queued" ? "queued" : "used");
        respond(response, 200, JSON.stringify({ disposition }));
      } },
      "/abort": { method: "POST", access: "session", handle: (_value, response) => {
        const running = state.bash.find(item => item.phase === 'running');
        if (running) { running.phase = 'cancelling'; publish(); }
        if (running) host.session.abortBash(); else return host.session.abort().then(() => respond(response, 200, "{}"));
        respond(response, 200, "{}");
      } },
      "/queue/clear": { method: "POST", access: "session", handle: (_value, response) => { const owner = host.session; return serial(async () => {
        owned(owner);
        pendingPrompts.beginClear();
        try {
          const restored = pendingPrompts.takeBack(owner.clearQueue());
          attached.restore([...restored.steering, ...restored.followUp].flatMap(entry => entry.attachments.map(file => file.id)));
          publish(); respond(response, 200, JSON.stringify(restored));
        } finally { pendingPrompts.endClear(); }
      }); } },
      "/queue/remove": { method: "POST", access: "session", handle: (value, response) => { const owner = host.session; return serial(async () => {
        owned(owner);
        if (!isRecord(value) || value.kind !== "steer" && value.kind !== "follow-up" || typeof value.index !== "number" || !Number.isSafeInteger(value.index) || value.index < 0 || typeof value.text !== "string") { respond(response, 400, JSON.stringify({ error: "A queue kind, index and text are required" })); return; }
        const { kind, index, text } = value;
        const shown = pendingPrompts.view();
        if ((kind === "steer" ? shown.steering : shown.followUp)[index]?.text !== text) { respond(response, 409, JSON.stringify({ error: "The queue changed" })); return; }
        pendingPrompts.beginClear();
        try {
          const restored = pendingPrompts.takeBack(owner.clearQueue());
          const all = [...restored.steering.map(entry => ({ entry, behavior: "steer" as const })), ...restored.followUp.map(entry => ({ entry, behavior: "follow_up" as const }))];
          attached.restore(all.flatMap(({ entry }) => entry.attachments.map(file => file.id)));
          const list = kind === "steer" ? restored.steering : restored.followUp;
          const stale = list[index]?.text !== text;
          const keep = all.filter(({ entry }) => stale || entry !== list[index]);
          for (const [done, { entry, behavior }] of keep.entries()) {
            const ids = entry.attachments.map(file => file.id);
            let failure: string | undefined;
            try {
              owned(owner);
              const sent = await queuePrompt(owner, entry.text, behavior, await attached.prepare(ids));
              if (sent.disposition === "handled") pendingPrompts.reject(sent.entry); else attached.consume(ids, "queued");
            } catch (error) { failure = errorText(error); }
            if (failure !== undefined) {
              const unsent = keep.slice(done);
              publish();
              respond(response, 409, JSON.stringify({ error: failure, unsent: { steering: unsent.filter(item => item.behavior === "steer").map(item => item.entry), followUp: unsent.filter(item => item.behavior === "follow_up").map(item => item.entry) } }));
              return;
            }
          }
          publish();
          respond(response, stale ? 409 : 200, JSON.stringify(stale ? { error: "The queue changed" } : {}));
        } finally { pendingPrompts.endClear(); }
      }); } },
      "/model": { method: "POST", access: "session", handle: (value, response) => {
        const model = modelBody(value);
        if ("error" in model) throw new Error(model.error);
        const found = host.session.modelRuntime.getAvailableSnapshot().find(entry => entry.provider === model.provider && entry.id === model.modelId);
        if (!found) throw new Error(`Model not found: ${model.provider}/${model.modelId}`);
        return setModel(found).then(() => respond(response, 200, JSON.stringify(found)));
      } },
      "/thinking": { method: "POST", access: "session", handle: (value, response) => {
        const thinking = thinkingBody(value, state.levels);
        if ("error" in thinking) throw new Error(thinking.error);
        host.session.setThinkingLevel(thinking.level);
        respond(response, 200, "{}");
      } },
      "/dialog": { method: "POST", access: "dialog", handle: async (value, response) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        const dialog = state.dialogs.find(dialog => dialog.id === id.id);
        if (!dialog) throw new Error("Dialog is not open");
        const answer = dialogBody(value, dialog);
        if ("error" in answer) throw new Error(answer.error);
        removeDialog(dialog.id, answer); respond(response, 200, "{}");
      } },
      "/editor/open": { method: "POST", access: "session", handle: async (value, response) => {
        if (!isRecord(value) || typeof value.text !== "string") { respond(response, 400, JSON.stringify({ error: "A draft text is required" })); return; }
        const result = await edits.open(value.text);
        respond(response, "error" in result ? 409 : 200, JSON.stringify(result));
      } },
      "/editor/ack": { method: "POST", access: "session", handle: (value, response) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        if (state.editor?.id === id.id) { delete state.editor; publish(); }
        respond(response, 200, "{}");
      } },
      "/agent/start": { method: "POST", access: "failed", handle: async (_value, response) => {
        await createHost(); respond(response, 200, "{}");
      } },
      "/quit": { method: "POST", access: "any", handle: (_value, response) => {
        response.setHeader("Connection", "close");
        const timer = later(() => background(quit()), QUIT_REPLY_MS);
        response.once("finish", () => { clearTimeout(timer); background(quit()); });
        respond(response, 200, "{}");
      } },
    };
    const handle = async (request: IncomingMessage, response: ServerResponse) => {
      try {
        if (request.method === "POST" && request.headers["content-type"]?.split(";")[0]?.trim().toLowerCase() !== (isChunkRoute(new URL(request.url ?? "/", "http://koa").pathname) ? "application/octet-stream" : "application/json")) { respond(response, 415, "{}"); return; }
        if (metricsFile && request.method === "POST" && request.url === "/metrics") {
          const bytes = await readBody(request, 1 << 20);
          if (!bytes) { respond(response, 413, "{}"); return; }
          let samples: unknown;
          try { samples = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, "{}"); return; }
          if (!Array.isArray(samples) || samples.length > 50 || !samples.every(sample => sample && typeof sample === "object" && Number.isFinite(sample.t) && (Number.isFinite(sample.frame) || Number.isFinite(sample.applied)) && Number.isFinite(sample.clockError) && Number.isSafeInteger(sample.bytes) && sample.bytes >= 0)) { respond(response, 400, "{}"); return; }
          const line = JSON.stringify({ type: "metrics", at: Date.now(), samples, ...feed.metrics }) + "\n";
          const file = metricsFile;
          const write = (metricsWrites ?? Promise.resolve()).then(() => appendFile(file, line));
          metricsWrites = write.catch(() => {});
          try { await write; } catch (error) { respond(response, 500, JSON.stringify({ error: errorText(error) })); return; }
          respond(response, 200, "{}"); return;
        }
        if (request.method === "GET") {
          const url = new URL(request.url ?? "/", "http://koa");
          const stale = url.pathname === "/events" && url.searchParams.has("koa") && url.searchParams.get("koa") !== instance;
          if (stale) { const record: PageRecord = { type: "reload" }; respond(response, 200, `data: ${JSON.stringify(record)}\n\n`, "text/event-stream"); return; }
        }
        if (await attached.handle(request, response, () => access("alive"))) return;
        if (await stepFile(request, response, feed.itemFile, state.cwd, state.home, () => access("alive"))) return;
        if (feed.handle(request, response)) return;
        if (request.method === "GET" && request.url === "/") {
          try {
            const document = page ?? await assemblePage(location);
            const html = document.replace("<head>", `<head><meta name="koa-instance" content="${instance}">${metricsFile ? `<meta name="koa-metrics" content="${metricsMode ?? "frame"}">` : ""}`);
            respond(response, 200, html, "text/html; charset=utf-8");
          } catch (error) { respond(response, 500, errorText(error), "text/plain; charset=utf-8"); }
          return;
        }
        const route = routes[request.url ?? ""];
        if (!route || route.method !== request.method) { respond(response, 404, "{}"); return; }
        let value: unknown;
        if (request.method === "POST") {
          const bytes = await readBody(request, 1 << 20);
          if (bytes === undefined) { respond(response, 413, "{}"); return; }
          try { value = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, JSON.stringify({ error: "A JSON body is required" })); return; }
        }
        access(route.access, value);
        await route.handle(value, response);
      } catch (error) { respond(response, 409, JSON.stringify({ error: errorText(error) })); }
    };
    const server = createServer((request, response) => { background(handle(request, response)); });
    teardown.push(() => { server.close(); server.closeAllConnections(); });
    const onSignal = () => background(quit());
    process.stdout.on("error", onSignal);
    teardown.push(() => { for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.off(signal, onSignal); });
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(signal, onSignal);
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(view.socketPath, resolve); });
    if (!stopping) {
      status('idle');
      background((async () => {
        if (!await createHost()) return;
        if (reloaded) feed.notify("reloaded", "info");
        const messages = initialMessages; initialMessages = [];
        for (const message of messages) {
          if (!running()) break;
          const done = new Promise<void>(resolve => { settled = resolve; });
          if (await koaAgents.submitPrompt(host, host.session, message, {}) === 'handled') settled = undefined;
          else await done;
        }
      })());
    }
    title();
    const show = (supported: boolean) => { if (stopping) return; if (supported) background(view.show()); else process.stdout.write("koa: this client does not show webviews; the page is still served\n"); };
    view.on("supported", show); show(view.supported);
    if (view.url) process.stderr.write(`koa: ${view.url}\n`);
  };
  try { await start(); } catch (error) { await shutdown(); throw error; }
}

main().catch(error => { process.stderr.write(`koa: ${errorText(error)}\n`); process.exitCode = 1; });
