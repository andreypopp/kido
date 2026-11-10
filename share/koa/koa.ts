import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { appendFile, writeFile } from "node:fs/promises";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, join } from "node:path";
import { homedir, tmpdir } from "node:os";
import timers from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { RpcCommand, RpcResponse, JsonAgentSessionEvent, RpcExtensionUIRequest, RpcExtensionUIResponse, SlashCommandSource } from "@earendil-works/pi-coding-agent";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { transcript, bashResult, appendBashOutput } from "./koa-transcript.ts";
import { later } from "./koa-timer.ts";
import { respond, readBody } from "./koa-http.ts";
import { isRecord, errorText, replaceControlCharacters, utf8Prefix, contentText } from "../pi/text.ts";
import { webview } from "../webview/index.ts";
import { assemblePage } from "./koa-assemble.ts";
import { complete, findFd, agentDiscovery } from "./koa-complete.ts";
import { startup, pickSession, signalChild, piPackage } from "./koa-child.ts";
import { koaChannel } from "./koa-channel.ts";
import { shellComplete } from "./koa-shell.ts";
import { attachments, stepFile, UPLOAD_IDLE_MS, isChunkRoute } from "./koa-attach.ts";
import { commandCatalog, parseCommand, dispatchCommand } from './koa-commands.ts';
import { bashCommand } from "./prompt.ts";
import { prompts } from "./koa-queue.ts";
import { ATTACHMENT_LIMITS, type PromptMode, type Exit, type Pi, type State, type ThinkingLevel, type DialogMethod, type CompletionCommand, type Attachment, type CompletionQuery, type SessionStats, type CommandResult, type Bash } from "./koa-records.ts";

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

function dialogBody(value: unknown, dialog: Extract<RpcExtensionUIRequest, { method: "select" | "confirm" | "input" | "editor" }>): RpcExtensionUIResponse | { error: string } {
  if (isRecord(value)) {
    if (value.cancelled === true) return { type: "extension_ui_response", id: dialog.id, cancelled: true };
    if (dialog.method === "confirm" && typeof value.confirmed === "boolean") return { type: "extension_ui_response", id: dialog.id, confirmed: value.confirmed };
    if (dialog.method !== "confirm" && typeof value.value === "string" && (dialog.method !== "select" || dialog.options.includes(value.value))) return { type: "extension_ui_response", id: dialog.id, value: value.value };
  }
  return { error: "A valid dialog answer is required" };
}

function promptBody(value: unknown): { text: string; mode: PromptMode | "steer"; attachments: string[] } | { error: string } {
  if (isRecord(value) && typeof value.text === "string" && Array.isArray(value.attachments) && value.attachments.length <= ATTACHMENT_LIMITS.files && value.attachments.every(id => typeof id === "string") && (value.text.trim() || value.attachments.length) && (value.mode === "prompt" || value.mode === "steer" || value.mode === "follow_up")) return { text: value.text, mode: value.mode, attachments: value.attachments };
  return { error: "Text or attachments and prompt, steer or follow_up mode are required" };
}


type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const thinkingLevelsMatch: Same<ThinkingLevel, import("@earendil-works/pi-agent-core").ThinkingLevel> = true;
const dialogMethodsMatch: Same<DialogMethod, Extract<RpcExtensionUIRequest, { method: DialogMethod }>["method"]> = true;
const statsMatch: Same<SessionStats, Extract<RpcResponse, { command: 'get_session_stats'; success: true }>['data']> = true;
const commandSourcesMatch: Same<Exclude<CompletionCommand["source"], 'builtin'>, SlashCommandSource> = true;
void [thinkingLevelsMatch, dialogMethodsMatch, commandSourcesMatch, statsMatch];

class RpcTimeout extends Error {
  constructor(command: RpcCommand['type']) { super(`pi ${command} response timed out`); }
}

const RPC_RESPONSE_MS = 10000;
const MAX_PENDING_BASH = 16;
const FLUSH_MS = 50;
const QUIT_REPLY_MS = 1000;

type Assistant = Extract<AgentMessage, { role: "assistant" }>;
type Access = "ready" | "session" | "alive" | "dialog" | "exited" | "any";

type Root = { value: "idle" | "working" | "done" | "error"; message: string };

function rpc(child: ChildProcessWithoutNullStreams) {
  let serial = 0;
  let writes = Promise.resolve();
  let events: (record: RpcResponse | JsonAgentSessionEvent | RpcExtensionUIRequest) => void = () => {};
  const pending = new Map<string, { resolve: (value: RpcResponse) => void; reject: (error: Error) => void }>();
  const rejectPending = (error: Error) => { for (const entry of pending.values()) entry.reject(error); pending.clear(); };
  child.stdin.on("error", rejectPending);
  const exited = new Promise<Exit>(resolve => {
    const finish = (exit: Exit) => {
      rejectPending(new Error("failed" in exit ? exit.failed : "pi exited"));
      child.stdin.destroy(new Error("pi exited"));
      resolve(exit);
    };
    child.once("exit", (code, signal) => finish(signal ? { signal } : code !== null ? { exited: code } : { failed: "pi ended without an exit status" }));
    child.once("error", error => finish({ failed: errorText(error) }));
  });
  const write = async (line: string) => { if (!child.stdin.write(line + "\n")) await once(child.stdin, "drain"); };
  const command = (value: RpcCommand, options: { apply?: (response: RpcResponse) => void; signal?: AbortSignal; deadline?: number | 'none'; onId?: (id: string) => void } = {}): Promise<RpcResponse> => {
    const { apply, signal } = options;
    if (signal?.aborted) return Promise.reject(new Error("pi command aborted"));
    if (child.exitCode !== null || child.signalCode !== null || child.stdin.destroyed) return Promise.reject(new Error("pi is not running"));
    const id = String(++serial);
    const result = new Promise<RpcResponse>((resolve, reject) => {
      const fail = (error: Error) => { pending.get(id)?.reject(error); pending.delete(id); };
      const abort = () => fail(new Error("pi command aborted"));
      const timer = options.deadline === 'none' ? undefined : later(() => fail(new RpcTimeout(value.type)), options.deadline ?? RPC_RESPONSE_MS);
      const clear = () => { clearTimeout(timer); signal?.removeEventListener("abort", abort); };
      signal?.addEventListener("abort", abort, { once: true });
      pending.set(id, {
        resolve: response => {
          clear();
          try { apply?.(response); resolve(response); } catch (error) { reject(error); }
        },
        reject: error => { clear(); reject(error); },
      });
      options.onId?.(id);
    });
    writes = writes.then(async () => {
      if (!pending.has(id)) return;
      await write(JSON.stringify({ ...value, id }));
    }).catch(error => { pending.get(id)?.reject(error); pending.delete(id); });
    return result;
  };
  let chunks: Buffer[] = [];
  let size = 0;
  child.stdout.on("error", error => { process.stderr.write(`koa: pi stdout: ${errorText(error)}\n`); });
  child.stdout.on("data", (chunk: Buffer) => {
    let start = 0;
    for (let end = chunk.indexOf(10); end >= 0; end = chunk.indexOf(10, start)) {
      const tail = chunk.subarray(start, end);
      const line = (chunks.length ? Buffer.concat([...chunks, tail], size + tail.length) : tail).toString("utf8").replace(/\r$/, "");
      chunks = []; size = 0; start = end + 1;
      let record: RpcResponse | JsonAgentSessionEvent | RpcExtensionUIRequest;
      try { record = JSON.parse(line); } catch { process.stderr.write(`koa: pi stdout: ${line}\n`); continue; }
      if (!record || typeof record !== "object" || !("type" in record)) { process.stderr.write(`koa: invalid pi record: ${line}\n`); continue; }
      try {
        if (record.type === "response" && record.id) { pending.get(record.id)?.resolve(record); pending.delete(record.id); }
        events(record);
      } catch (error) { process.stderr.write(`koa: pi record ${record.type}: ${errorText(error)}\n`); }
    }
    if (start < chunk.length) { const tail = chunk.subarray(start); chunks.push(tail); size += tail.length; }
  });
  const answer = (value: RpcExtensionUIResponse) => {
    writes = writes.then(() => write(JSON.stringify(value)));
    return writes;
  };
  return { command, answer, invalidate() { rejectPending(new Error("Session changed")); }, events(listener: typeof events) { events = listener; }, close() { rejectPending(new Error("pi is closed")); events = () => {}; }, exited };
}

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
  const pass: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
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
    } else if (arg !== undefined) pass.push(arg);
  }
  if (metricsMode && !metricsFile) throw new Error("--metrics-mode requires --metrics");
  const configured = Number(process.env.KOA_PI_EXIT_MS ?? 5000);
  const exitMs = Number.isFinite(configured) && configured > 0 ? configured : 5000;
  const uploadIdleMs = Number(process.env.KOA_UPLOAD_IDLE_MS ?? UPLOAD_IDLE_MS);
  if (!Number.isFinite(uploadIdleMs) || uploadIdleMs <= 0) throw Error("KOA_UPLOAD_IDLE_MS must be positive");
  let packageRoot = await piPackage(executable, process.env.PATH ?? '');
  let initialMessages: string[] = [], resume = false;
  if (pass.length || !packageRoot) {
    let result: Awaited<ReturnType<typeof startup>>;
    try { result = await startup(executable, pass, fileURLToPath(new URL('./koa-startup.ts', location))); }
    catch (error) { if (!packageRoot) throw Error(`cannot find pi's package from ${executable}`); throw error; }
    if ('error' in result) throw Error(result.error);
    initialMessages = result.messages; resume = result.resume;
    packageRoot ??= result.packageRoot;
  }
  if (!packageRoot) throw Error(`cannot find pi's package from ${executable}`);
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
  const teardown: (() => void | Promise<void>)[] = [() => view.close().catch(error => { process.stderr.write(`koa: close: ${errorText(error)}\n`); })];
  let shutdownPromise: Promise<void> | undefined;
  const shutdown = () => shutdownPromise ??= Promise.allSettled(teardown.reverse().map(async close => close())).then(() => {});
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
    const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi/agent");
    const fd = findFd(process.env.KOA_FD, agentDir.replace(/^~(?=\/|$)/, homedir()), process.env.PATH ?? "");
    if (!fd) process.stderr.write("koa: fd not found; file completion is unavailable\n");
    const lifetime = new AbortController();
    teardown.push(() => lifetime.abort());
    const agents = agentDiscovery(process.env.KO_PANE ?? "", process.env.KO_AGENT_LIST_TTL_MS, lifetime.signal);
    let compaction: { root: Root; working: boolean; since?: number } | undefined;
    let compactRequest: { ended: boolean } | undefined;
    let settled: (() => void) | undefined;
    const state: Omit<State, "pi" | "queue"> = { bash: [], get compaction() { return compaction ? 'running' : 'idle'; }, working: false, aborted: false, name: "pi", levels: [], cwd: process.cwd(), home: homedir(), dialogs: [], statuses: {} };
    let stopping = false;
    teardown.push(() => { stopping = true; });
    let pi: Pi = { type: "starting" };
    const running = () => !stopping && pi.type === "ready";
    let root: Root = { value: "idle", message: state.name };
    const publish = (dialogsChanged = false) => { if (pi.type !== "starting" || dialogsChanged) feed.state({ ...state, queue: pendingPrompts.view(), pi }); };
    const status = (value: Root["value"] | "clear", message = state.name) => {
      if (value !== "clear") root = { value, message };
      const dialog = state.dialogs[0];
      const encoded = Buffer.from(utf8Prefix(replaceControlCharacters(dialog?.title ?? message).replace(/\s+/g, " ").trim(), 2048)).toString("base64");
      process.stdout.write(`\x1b]7501;state=${value === "clear" ? value : dialog ? "blocked" : value}${value === "clear" ? "" : `:app=pi${dialog ? ":kind=question" : ""}:msg=${encoded}`}\x1b\\`);
    };
    const title = () => process.stdout.write(`\x1b]0;${utf8Prefix(replaceControlCharacters(`koa - ${state.name} - ${basename(state.cwd)}`), 2048)}\x1b\\`);
    const spawnPi = (args: string[]) => spawn(executable, ["--mode", "rpc", "--extension", fileURLToPath(new URL("../pi/ko-pi.ts", location)), "--extension", fileURLToPath(new URL("./koa-sessions.ts", location)), "--harness", browser ? "koa-browser" : "koa", ...args], { detached: true, stdio: ["pipe", "pipe", "pipe", "pipe"] });
    let child = spawnPi(pass);
    let sessions = koaChannel(child.stdio[3]);
    teardown.push(() => sessions.close());
    let link = rpc(child);
    const waitExit = async (): Promise<boolean> => {
      const controller = new AbortController();
      try { return await Promise.race([link.exited.then(() => true), timers.setTimeout(exitMs, false, { signal: controller.signal })]); }
      finally { controller.abort(); }
    };
    teardown.push(async () => {
      child.stdin.end();
      try {
        if (!await waitExit()) { signalChild(child, "SIGTERM"); if (!await waitExit()) { signalChild(child, "SIGKILL"); await waitExit(); } }
      } finally { link.close(); child.unref(); child.stdin.destroy(); child.stdout.destroy(); child.stderr.destroy(); }
    });
    const dialogTimers = new Map<string, NodeJS.Timeout>();
    teardown.push(() => { for (const timer of dialogTimers.values()) clearTimeout(timer); dialogTimers.clear(); });
    const background = (work: Promise<unknown>) => { void work.catch(error => { if (pi.type !== "exited" && !stopping) process.stderr.write(`koa: ${errorText(error)}\n`); }); };
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
    const watch = (child: ChildProcessWithoutNullStreams, link: ReturnType<typeof rpc>) => {
      let stderr = "";
      child.stderr.on("error", error => { process.stderr.write(`koa: pi stderr: ${errorText(error)}\n`); });
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (text: string) => { stderr = (stderr + text).split(/\n(?=.)/s).slice(-5).join("\n"); process.stderr.write(text); });
      background(link.exited.then(async exit => {
        if (compaction) finishCompaction({ type: 'failed', message: 'failed' in exit ? exit.failed : 'signal' in exit ? 'pi exited by ' + exit.signal : 'pi exited with code ' + exit.exited });
        settled?.(); settled = undefined;
        if ("exited" in exit && exit.exited === 0) {
          await shutdown();
          return;
        }
        pi = { type: "exited", ...exit, at: Date.now(), stderr: stderr.trimEnd() }; state.working = false; delete state.since;
        state.dialogs = []; state.statuses = {}; dropBash();
        link.events(() => {});
        for (const timer of dialogTimers.values()) clearTimeout(timer);
        dialogTimers.clear();
        if ("failed" in exit) process.stderr.write(`koa: ${exit.failed}\n`);
        status("clear"); publish();
        return timers.setTimeout(exitMs, undefined, { ref: false }).then(() => { child.stdout.destroy(); child.stderr.destroy(); });
      }));
    };
    watch(child, link);
    const stats = async (notify = true) => {
      const result = await link.command({ type: "get_session_stats" }, { apply: response => {
        if (!response.success) throw new Error(response.error);
        if (response.success && response.command === "get_session_stats") {
          const usage = response.data.contextUsage;
          state.context = usage && { tokens: usage.tokens, window: usage.contextWindow, percent: usage.percent };
          if (notify) publish();
        }
      } });
      return result.success && result.command === "get_session_stats" ? result.data.totalMessages : 0;
    };
    const levels = (notify = true) => link.command({ type: "get_available_thinking_levels" }, { apply: response => {
      if (!response.success) throw new Error(response.error);
      if (response.success && response.command === "get_available_thinking_levels") { state.levels = response.data.levels; if (notify) publish(); }
    } });
    let rebuildWork: Promise<RpcResponse[]> | undefined;
    const rebuild = () => {
      const owner = link, ownerSession = state.sessionId;
      const work: Promise<RpcResponse[]> = (rebuildWork?.catch(() => {}) ?? Promise.resolve()).then<RpcResponse[]>(() => {
        if (owner !== link || ownerSession !== state.sessionId) return [];
        const completed: Bash[] = state.working ? [] : state.bash.filter(item => item.phase === 'completed');
        let entries: Extract<RpcResponse, { command: 'get_entries'; success: true }>['data'] | undefined;
        return Promise.all([
          owner.command({ type: 'get_entries' }, { apply: response => { if (response.success && response.command === 'get_entries') entries = response.data; } }),
          owner.command({ type: 'get_messages' }, { apply: response => {
            if (response.success && response.command === 'get_messages' && entries && owner === link && ownerSession === state.sessionId) {
              const previous = state.bash;
              state.bash = previous.filter(item => !completed.includes(item));
              if (state.bash.length !== previous.length) publish();
              try { feed.rebuild(response.data.messages, state.sessionId, entries.entries, entries.leafId); }
              catch (error) { state.bash = previous; publish(); throw error; }
            }
          } }),
        ]).then(results => {
          const failed = results.find(result => !result.success);
          if (failed && !failed.success) throw new Error(failed.error);
          return results;
        });
      }).finally(() => { if (rebuildWork === work) rebuildWork = undefined; });
      rebuildWork = work;
      return work;
    };
    const refresh = async (afterGeneration = 0) => {
      if (pi.type === "exited" || stopping) return;
      const switching = pi.type === "switching";
      if (!switching) pi = { type: "starting" };
      const response = await link.command({ type: "get_state" }, { apply: response => {
        if (response.success && response.command === "get_state") {
          state.sessionId = response.data.sessionId;
          state.name = response.data.sessionName ?? "pi";
          state.model = response.data.model; state.thinking = response.data.thinkingLevel; state.sessionFile = response.data.sessionFile;
        }
      } });
      if (!response.success) throw new Error(response.error);
      const [metadata, , , count] = await Promise.all([sessions.current(state.sessionId, afterGeneration), rebuild(), levels(false), stats(false)]);
      state.cwd = metadata.cwd;
      title();
      if (pi.type === "starting" || pi.type === "switching") { pi = { type: "ready" }; publish(); }
      return count;
    };
    let bashTimer: NodeJS.Timeout | undefined;
    const dropBash = () => { clearTimeout(bashTimer); bashTimer = undefined; state.bash = []; };
    teardown.push(dropBash);
    const settleBash = () => {
      if (state.working || !state.bash.length || state.bash.some(item => item.phase !== 'completed')) return Promise.resolve();
      return rebuild();
    };
    let userAttachments: Attachment[] = [];
    let partial: Assistant | undefined;
    let outcome: { type: "done" } | { type: "error"; message: string } = { type: "done" };
    const argumentsText = new Map<number, string>();
    let argumentTimer: NodeJS.Timeout | undefined;
    teardown.push(() => clearTimeout(argumentTimer));
    const applyArguments = () => {
      argumentTimer = undefined;
      if (!partial) return;
      for (const [index, text] of argumentsText) {
        const block = partial.content[index];
        if (block?.type === "toolCall") { try { block.arguments = JSON.parse(text); } catch {} }
      }
      feed.message(partial, "update");
    };
    const event = (event: JsonAgentSessionEvent, state: Omit<State, "pi" | "queue">): void => {
      if (pi.type === "exited" || pi.type === "switching" || stopping) return;
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
          if (event.message.role === "assistant") { clearTimeout(argumentTimer); argumentTimer = undefined; partial = event.message; argumentsText.clear(); }
          if (event.message.role === "user") { userAttachments = pendingPrompts.start(contentText(event.message.content)); attached.consume(userAttachments.map(file => file.id), "used"); }
          feed.message(event.message, "start");
          if (event.message.role === "user") publish();
          break;
        }
        case "message_update": {
          if (!partial) break;
          const delta = event.assistantMessageEvent;
          partial.usage = event.usage;
          if ("contentIndex" in delta) {
            const index = delta.contentIndex;
            const block = partial.content[index];
            switch (delta.type) {
              case "text_start": partial.content[index] = { type: "text", text: "" }; break;
              case "thinking_start": partial.content[index] = { type: "thinking", thinking: "" }; break;
              case "text_delta": if (block?.type === "text") block.text += delta.delta; break;
              case "thinking_delta": if (block?.type === "thinking") block.thinking += delta.delta; break;
              case "text_end": partial.content[index] = { type: "text", text: delta.content }; break;
              case "thinking_end": partial.content[index] = { type: "thinking", thinking: delta.content }; break;
              case "toolcall_start": partial.content[index] = { type: "toolCall", id: delta.id, name: delta.toolName, arguments: {} }; argumentsText.set(index, ""); break;
              case "toolcall_delta": argumentsText.set(index, (argumentsText.get(index) ?? "") + delta.delta); argumentTimer ??= later(applyArguments, FLUSH_MS); break;
              case "toolcall_end": partial.content[index] = delta.toolCall; argumentsText.delete(index); break;
            }
          }
          feed.message(partial, "update");
          if (delta.type === "thinking_start" || delta.type === "thinking_end") feed.thinking(delta.contentIndex, delta.type === "thinking_start" ? "started" : "ended", Date.now());
          break;
        }
        case "message_end":
          feed.message(event.message, "end", event.message.role === "assistant" ? Date.now() : undefined, event.message.role === "user" ? userAttachments : []);
          if (event.message.role === "user") userAttachments = [];
          if (event.message.role === "assistant") {
            clearTimeout(argumentTimer); argumentTimer = undefined; argumentsText.clear(); partial = undefined;
            outcome = event.message.stopReason === "error" ? { type: "error", message: (event.message.errorMessage ?? "").split("\n")[0] ?? "" } : { type: "done" };
          }
          break;
        case "tool_execution_start": feed.toolRunning(event.toolCallId, Date.now()); break;
        case "tool_execution_update": feed.toolPartial(event.toolCallId, event.partialResult.content); break;
        case "tool_execution_end": feed.toolDone(event.toolCallId, event.result.content, event.isError, Date.now(), event.durationMs, event.result.structuredContent, event.result.details); break;
        case "agent_start": state.working = true; state.since = Date.now(); state.aborted = false; outcome = { type: "done" }; status("working"); publish(); break;
        case 'compaction_start': compaction ??= { root, working: state.working, since: state.since }; feed.command({ type: 'compaction', state: { type: 'running' } }); state.working = true; state.since ??= Date.now(); status('working'); publish(); break;
        case "agent_settled": settled?.(); settled = undefined; state.working = false; delete state.since; state.aborted = event.aborted; status(event.aborted ? "idle" : outcome.type, outcome.type === "error" ? outcome.message : state.name); publish(); background(stats()); background(settleBash()); break;
        case "queue_update": pendingPrompts.update({ steering: event.steering, followUp: event.followUp }); publish(); break;
        case "thinking_level_changed": state.thinking = event.level; publish(); break;
        case "session_info_changed": state.name = event.name ?? "pi"; title(); publish(); break;
        case 'compaction_end':
          if (!compaction) { background(rebuild()); background(stats()); break; }
          if (event.result) finishCompaction({ type: 'done', before: event.result.tokensBefore, after: event.result.estimatedTokensAfter, summary: event.result.summary }, event.willRetry);
          else if (event.errorMessage) finishCompaction({ type: 'failed', message: event.errorMessage }, event.willRetry);
          else finishCompaction({ type: 'cancelled' }, event.willRetry);
          background(rebuild()); background(stats()); break;
        case "turn_end": background(stats()); break;
      }
    };
    const resetSession = () => {
      state.working = false; state.aborted = false; delete state.since; delete state.editor; delete state.context;
      dropBash(); pendingPrompts.reset(); userAttachments = []; attached.reset();
      clearTimeout(argumentTimer); argumentTimer = undefined; argumentsText.clear(); partial = undefined;
      compaction = undefined; outcome = { type: "done" }; state.dialogs = []; state.statuses = {};
      for (const timer of dialogTimers.values()) clearTimeout(timer);
      dialogTimers.clear(); status("idle");
    };
    let switchingUI: RpcExtensionUIRequest[] | undefined;
    const records = (record: RpcResponse | JsonAgentSessionEvent | RpcExtensionUIRequest) => {
      if (pi.type === "switching" && record.type !== "extension_ui_request") return;
      if (record.type === "extension_ui_request") {
        if (switchingUI && ["notify", "set_editor_text", "setStatus"].includes(record.method)) { switchingUI.push(record); return; }
        switch (record.method) {
          case "select": case "confirm": case "input": case "editor":
            state.dialogs.push({ ...record, ...("timeout" in record && record.timeout !== undefined ? { expires: Date.now() + record.timeout } : {}) });
            if ("timeout" in record && record.timeout !== undefined) dialogTimers.set(record.id, later(() => removeDialog(record.id), record.timeout));
            status(root.value, root.message); publish(true); break;
          case "notify": feed.notify(record.message, record.notifyType ?? "info"); break;
          case "set_editor_text": state.editor = { id: record.id, text: record.text }; publish(); break;
          case "setStatus":
            if (!record.statusText) delete state.statuses[record.statusKey];
            else state.statuses[record.statusKey] = record.statusText;
            publish(); break;
          case "setWidget": case "setTitle": break;
        }
      } else if (record.type === "response") {
        if (record.success && ["new_session", "switch_session", "fork", "clone"].includes(record.command) && !("data" in record && record.data && "cancelled" in record.data && record.data.cancelled)) {
          resetSession(); background(refresh());
        }
      } else event(record, state);
    };
    const removeDialog = (id: string) => {
      clearTimeout(dialogTimers.get(id)); dialogTimers.delete(id);
      state.dialogs = state.dialogs.filter(dialog => dialog.id !== id);
      status(root.value, root.message); publish(true);
    };
    link.events(records);
    const reply = (response: ServerResponse, result: RpcResponse) => respond(response, result.success ? 200 : 409, JSON.stringify(result.success ? "data" in result ? result.data : {} : { error: result.error }));
    const invoke = async (value: RpcCommand, announce = false) => {
      const result = await link.command(value);
      if (result.success && result.command === 'set_model') { state.model = result.data; await levels(false); publish(); }
      if (announce && result.success && (result.command === 'set_model' || result.command === 'set_thinking_level')) feed.notify(`model: ${state.model?.id ?? ''} · thinking ${state.thinking ?? 'off'}`, 'info');
      return result;
    };
    const command = async (value: RpcCommand, response: ServerResponse) => reply(response, await invoke(value));
    const switchSession = async (value: Extract<RpcCommand, { type: "new_session" | "switch_session" }>, response: ServerResponse) => {
      const generation = sessions.generation;
      link.invalidate(); sessions.cancel(); switchingUI = []; pi = { type: "switching" }; publish();
      const replayUI = () => { const buffered = switchingUI; switchingUI = undefined; for (const record of buffered ?? []) records(record); };
      let result: RpcResponse;
      try { result = await link.command(value); }
      catch (error) { if (pi.type === "switching") { pi = { type: "ready" }; publish(); } replayUI(); throw error; }
      if (result.success && (result.command === "new_session" || result.command === "switch_session") && !result.data.cancelled) {
        resetSession();
        state.name = "pi"; delete state.sessionFile; delete state.model; delete state.thinking; state.levels = [];
        try {
          const count = await refresh(generation);
          feed.notify(value.type === "new_session" ? "new session" : `session: ${state.name} · ${count ?? 0} messages`, "info");
        } catch (error) {
          delete state.sessionId;
          try { const metadata = await sessions.current(undefined, generation); state.sessionId = metadata.id; state.cwd = metadata.cwd; }
          catch (metadataError) { feed.notify(errorText(metadataError), "error"); }
          feed.rebuild([], state.sessionId); feed.notify(errorText(error), "error");
          pi = { type: "ready" }; title(); publish();
        }
      } else { pi = { type: "ready" }; publish(); }
      replayUI();
      reply(response, result);
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
          if (stopping || pi.type === "exited") throw new Error("pi is not running");
          break;
        case "ready": if (!running()) throw new Error(pi.type === "starting" ? "pi is starting" : "pi is not ready"); break;
        case "alive": if (stopping || pi.type === "exited" || pi.type === "switching") throw new Error("pi is not running"); break;
        case "exited": if (stopping || pi.type !== "exited") throw new Error("pi is already running"); break;
        case "any": break;
        default: { const unexpected: never = mode; throw new Error(unexpected); }
      }
    };
    const routes: Record<string, { method: "GET" | "POST"; access: Access; handle(value: unknown, response: ServerResponse): void | Promise<void> }> = {
      "/complete": { method: "POST", access: "alive", handle: async (value, response) => {
        const query = completeBody(value);
        if ("error" in query) { respond(response, 400, JSON.stringify(query)); return; }
        checkSession(value);
        await withRequestSignal(response, lifetime.signal, async requestSignal => {
          const bang = bashCommand(query.text), owner = child, ownerSession = state.sessionId;
          const signal = AbortSignal.any([requestSignal, sessions.signal(), ...(bang ? [AbortSignal.timeout(2000)] : [])]);
          const result = bang ? await shellComplete(query.text, query.pos, await sessions.completionContext(signal), 'ko', signal, bang) : await complete(query.text, query.pos, { cwd: state.cwd, fd, signal, agents, commands: async () => {
            if (pi.type !== "ready") return [];
            const result = await link.command({ type: "get_commands" }, { signal });
            return [...completion, ...(result.success && result.command === 'get_commands' ? result.data.commands.filter(value => !catalog.some(builtin => builtin.name === value.name)) : [])];
          } });
          if (!requestSignal.aborted) respond(response, signal.aborted || owner !== child || ownerSession !== state.sessionId ? 409 : 200, JSON.stringify(result));
        });
      } },
      "/sessions/list": { method: "POST", access: "ready", handle: async (value, response) => {
        if (!isRecord(value) || (value.scope !== "current" && value.scope !== "all")) { respond(response, 400, "{}"); return; }
        const scope = value.scope;
        await withRequestSignal(response, lifetime.signal, async signal => {
          const rows = await sessions.list(scope, signal);
          if (!signal.aborted) respond(response, 200, JSON.stringify({ rows }));
        });
      } },
      "/sessions/switch": { method: "POST", access: "session", handle: (value, response) => {
        if (!isRecord(value) || typeof value.path !== "string" || !value.path) { respond(response, 400, "{}"); return; }
        return switchSession({ type: "switch_session", sessionPath: value.path }, response);
      } },
      "/sessions/new": { method: "POST", access: "session", handle: (_value, response) => switchSession({ type: "new_session" }, response) },
      "/models": { method: "GET", access: "ready", handle: (_value, response) => command({ type: "get_available_models" }, response) },
      "/prompt": { method: "POST", access: "session", handle: async (value, response) => {
        const builtin = isRecord(value) && typeof value.text === 'string' ? parseCommand(value.text, catalog) : undefined;
        const prompt = promptBody(builtin && isRecord(value) ? { ...value, attachments: [] } : value);
        if ("error" in prompt) { respond(response, 400, JSON.stringify(prompt)); return; }
        const bash = bashCommand(prompt.text);
        if (bash) {
          while (rebuildWork) await rebuildWork;
          const refusal = prompt.attachments.length ? 'a command takes no attachments' : state.bash.some(item => item.phase !== 'completed') ? 'a command is already running' : state.bash.length >= MAX_PENDING_BASH ? 'too many commands wait for the turn to end' : !bash.command.trim() ? 'a command is required' : undefined;
          if (refusal) { respond(response, 409, JSON.stringify({ error: refusal })); return; }
          const { command: shellCommand, excludeFromContext } = bash;
          const owner = link, ownerSession = state.sessionId;
          let running: (Bash & { phase: 'running' | 'cancelling' }) | undefined;
          background((async () => {
            try {
              const result = await owner.command({ type: 'bash', command: shellCommand, excludeFromContext }, { deadline: 'none', onId: id => {
                running = { id, command: shellCommand, excludeFromContext, phase: 'running', started: Date.now(), output: { text: '', cut: 0 } };
                state.bash.push(running); publish();
              } });
              if (owner !== link || ownerSession !== state.sessionId || !running || !state.bash.includes(running)) return;
              if (!result.success) throw new Error(result.error);
              if (result.command !== 'bash') throw new Error('unexpected command response');
              const completed: Bash = { id: running.id, command: shellCommand, excludeFromContext, phase: 'completed', started: running.started, ended: Date.now(), result: bashResult(result.data) };
              state.bash = state.bash.map(item => item === running ? completed : item);
              clearTimeout(bashTimer); bashTimer = undefined; publish();
              await settleBash();
            } catch (error) {
              if (running && state.bash.includes(running)) { state.bash = state.bash.filter(item => item !== running); publish(); feed.notify(errorText(error), 'error'); }
              else if (owner === link && ownerSession === state.sessionId) throw error;
            }
          })());
          respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return;
        }
        if (builtin) {
          const action = await dispatchCommand(builtin, {
            packageRoot, command: value => invoke(value, true), notify: feed.notify, outcome: feed.command,
            stats: stats => feed.command({ type: 'session', stats, name: state.name, model: state.model, thinking: state.thinking }),
            thinking: async level => {
              const parsed = thinkingBody({ level: level.toLowerCase() }, state.levels);
              if ('error' in parsed) { feed.notify(`Unknown thinking level: ${level}`, 'warning'); return; }
              const result = await invoke({ type: 'set_thinking_level', ...parsed }, true);
              if (!result.success) throw Error(result.error);
            },
            compact: instructions => {
              if (compaction || compactRequest && !compactRequest.ended) return;
              const request = { ended: false }; compactRequest = request;
              background(link.command({ type: 'compact', ...(instructions ? { customInstructions: instructions } : {}) }).then(result => {
                if (!result.success && !request.ended) finishCompaction({ type: 'failed', message: result.error });
              }).catch(error => { const message = errorText(error); if (!request.ended && (!compaction || !(error instanceof RpcTimeout))) finishCompaction({ type: 'failed', message }); }).finally(() => { if (compactRequest === request) compactRequest = undefined; }));
            },
            get name() { return state.name; },
          });
          if (action.type === 'quit') { await routes['/quit']?.handle({}, response); return; }
          respond(response, 200, JSON.stringify({ disposition: 'handled', action })); return;
        }
        const files = await attached.prepare(prompt.attachments);
        access("session", value);
        const message = [prompt.text, ...files.paths].filter(Boolean).join("\n");
        const mode = state.working ? prompt.mode === "follow_up" ? "followUp" : "steer" : "prompt";
        const entry = pendingPrompts.add(message, mode, files.files);
        const result = await link.command({ type: "prompt", message, ...(files.images.length ? { images: files.images } : {}), ...(mode !== "prompt" ? { streamingBehavior: mode } : {}) });
        if (result.success && result.command === 'prompt' && result.data.disposition === 'handled') {
          pendingPrompts.reject(entry); respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return;
        }
        if (result.success) attached.consume(prompt.attachments, result.command === "prompt" && result.data.disposition === "queued" ? "queued" : "used"); else pendingPrompts.reject(entry);
        reply(response, result);
      } },
      "/abort": { method: "POST", access: "session", handle: (_value, response) => {
        const running = state.bash.find(item => item.phase === 'running');
        if (running) { running.phase = 'cancelling'; publish(); }
        return command({ type: running ? 'abort_bash' : 'abort' }, response);
      } },
      "/queue/clear": { method: "POST", access: "session", handle: async (_value, response) => {
        pendingPrompts.beginClear();
        try {
          const result = await link.command({ type: "clear_queue" });
          if (result.success && result.command === "clear_queue") {
            const restored = pendingPrompts.takeBack(result.data);
            attached.restore([...restored.steering, ...restored.followUp].flatMap(entry => entry.attachments.map(file => file.id)));
            publish(); respond(response, 200, JSON.stringify(restored));
          } else reply(response, result);
        } finally { pendingPrompts.endClear(); }
      } },
      "/model": { method: "POST", access: "session", handle: (value, response) => {
        const model = modelBody(value);
        if ("error" in model) throw new Error(model.error);
        return command({ type: "set_model", ...model }, response);
      } },
      "/thinking": { method: "POST", access: "session", handle: (value, response) => {
        const thinking = thinkingBody(value, state.levels);
        if ("error" in thinking) throw new Error(thinking.error);
        return command({ type: "set_thinking_level", ...thinking }, response);
      } },
      "/dialog": { method: "POST", access: "dialog", handle: async (value, response) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        const dialog = state.dialogs.find(dialog => dialog.id === id.id);
        if (!dialog) throw new Error("Dialog is not open");
        const answer = dialogBody(value, dialog);
        if ("error" in answer) throw new Error(answer.error);
        removeDialog(dialog.id);
        await link.answer(answer); respond(response, 200, "{}");
      } },
      "/editor/ack": { method: "POST", access: "session", handle: (value, response) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        if (state.editor?.id === id.id) { delete state.editor; publish(); }
        respond(response, 200, "{}");
      } },
      "/pi/start": { method: "POST", access: "exited", handle: async (_value, response) => {
        const args: string[] = [];
        for (let i = 0; i < pass.length; i++) {
          const arg = pass[i];
          if (arg === "--") { args.push(...pass.slice(i)); break; }
          if (state.sessionFile && ["--session", "--session-id", "--fork", "--model", "--thinking"].includes(arg ?? "")) { i++; continue; }
          if (state.sessionFile && ["--continue", "-c", "--no-session"].includes(arg ?? "")) continue;
          if (arg !== undefined) args.push(arg);
        }
        if (state.sessionFile) {
          const end = args.indexOf("--");
          args.splice(end < 0 ? args.length : end, 0, "--session", state.sessionFile);
        }
        if (compaction) finishCompaction({ type: 'failed', message: 'pi restarted during compaction' });
        compactRequest = undefined;
        sessions.close(); child = spawnPi(args); link = rpc(child); sessions = koaChannel(child.stdio[3]);
        pi = { type: "starting" }; resetSession();
        watch(child, link); link.events(records);
        await refresh(); respond(response, 200, "{}");
      } },
      "/quit": { method: "POST", access: "any", handle: (_value, response) => {
        response.setHeader("Connection", "close");
        const timer = later(() => background(shutdown()), QUIT_REPLY_MS);
        response.once("finish", () => { clearTimeout(timer); background(shutdown()); });
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
        if (await attached.handle(request, response, () => access("alive"))) return;
        if (await stepFile(request, response, feed.itemFile, state.cwd, state.home, () => access("alive"))) return;
        if (feed.handle(request, response)) return;
        if (request.method === "GET" && request.url === "/") {
          try {
            const document = await assemblePage(location);
            const page = metricsFile ? document.replace("<head>", `<head><meta name="koa-metrics" content="${metricsMode ?? "frame"}">`) : document;
            respond(response, 200, page, "text/html; charset=utf-8");
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
    const onSignal = () => background(shutdown());
    process.stdout.on("error", onSignal);
    teardown.push(() => { for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.off(signal, onSignal); });
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(signal, onSignal);
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(view.socketPath, resolve); });
    if (!stopping) {
      status('idle');
      background((async () => {
        await refresh();
        const messages = initialMessages; initialMessages = [];
        for (const message of messages) {
          if (!running()) break;
          const done = new Promise<void>(resolve => { settled = resolve; });
          const result = await link.command({ type: 'prompt', message });
          if (!result.success) throw Error(result.error);
          if (result.command === 'prompt' && result.data.disposition === 'handled') settled = undefined;
          else await Promise.race([done, link.exited]);
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
