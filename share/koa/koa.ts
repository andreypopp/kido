import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { readFile, appendFile, writeFile } from "node:fs/promises";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, join } from "node:path";
import { homedir, tmpdir } from "node:os";
import timers from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { RpcCommand, RpcResponse, JsonAgentSessionEvent, RpcExtensionUIRequest, RpcExtensionUIResponse, SlashCommandSource } from "@earendil-works/pi-coding-agent";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
type PiThinkingLevel = import("@earendil-works/pi-agent-core").ThinkingLevel;
import { transcript, respond, readBody, completeBody, idBody, modelBody, thinkingBody, dialogBody } from "../pi/transcript.ts";
import { errorText, replaceControlCharacters, utf8Prefix, contentText } from "../pi/text.ts";
import { webview } from "../webview/index.ts";
import { assemblePage } from "./koa-assemble.ts";
import { complete, findFd, agentDiscovery } from "./koa-complete.ts";
import { signalChild } from "./koa-child.ts";
import { attachments, stepFile, UPLOAD_IDLE_MS, isChunkRoute } from "./koa-attach.ts";
import { nameCommand, promptBody } from "./prompt.ts";
import { prompts } from "./koa-queue.ts";
import type { Exit, Pi, State, ThinkingLevel, DialogMethod, CompletionCommand, Attachment } from "../pi/records.ts";

type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const thinkingLevelsMatch: Same<ThinkingLevel, PiThinkingLevel> = true;
const dialogMethodsMatch: Same<DialogMethod, Extract<RpcExtensionUIRequest, { method: DialogMethod }>["method"]> = true;
const commandSourcesMatch: Same<CompletionCommand["source"], SlashCommandSource> = true;
void [thinkingLevelsMatch, dialogMethodsMatch, commandSourcesMatch];

const RPC_RESPONSE_MS = 10000;
const FLUSH_MS = 50;
const QUIT_REPLY_MS = 1000;

type Assistant = Extract<AgentMessage, { role: "assistant" }>;
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
  const command = (value: RpcCommand, apply?: (response: RpcResponse) => void, signal?: AbortSignal): Promise<RpcResponse> => {
    if (signal?.aborted) return Promise.reject(new Error("pi command aborted"));
    if (child.exitCode !== null || child.signalCode !== null || child.stdin.destroyed) return Promise.reject(new Error("pi is not running"));
    const id = String(++serial);
    const result = new Promise<RpcResponse>((resolve, reject) => {
      const fail = (error: Error) => { pending.get(id)?.reject(error); pending.delete(id); };
      const abort = () => fail(new Error("pi command aborted"));
      const timer = setTimeout(() => fail(new Error(`pi ${value.type} response timed out`)), RPC_RESPONSE_MS);
      const clear = () => { clearTimeout(timer); signal?.removeEventListener("abort", abort); };
      signal?.addEventListener("abort", abort, { once: true });
      pending.set(id, {
        resolve: response => {
          clear();
          try { apply?.(response); resolve(response); } catch (error) { reject(error); }
        },
        reject: error => { clear(); reject(error); },
      });
    });
    writes = writes.then(async () => {
      if (!pending.has(id)) return;
      await write(JSON.stringify({ ...value, id }));
    }).catch(error => { pending.get(id)?.reject(error); pending.delete(id); });
    return result;
  };
  let chunks: Buffer[] = [];
  let size = 0;
  child.stdout.on("data", (chunk: Buffer) => {
    let start = 0;
    for (let end = chunk.indexOf(10); end >= 0; end = chunk.indexOf(10, start)) {
      const tail = chunk.subarray(start, end);
      const line = (chunks.length ? Buffer.concat([...chunks, tail], size + tail.length) : tail).toString("utf8").replace(/\r$/, "");
      chunks = []; size = 0; start = end + 1;
      let record: RpcResponse | JsonAgentSessionEvent | RpcExtensionUIRequest;
      try { record = JSON.parse(line); } catch { process.stderr.write(`koa: pi stdout: ${line}\n`); continue; }
      if (!record || typeof record !== "object" || !("type" in record)) { process.stderr.write(`koa: invalid pi record: ${line}\n`); continue; }
      if (record.type === "response" && record.id) { pending.get(record.id)?.resolve(record); pending.delete(record.id); }
      events(record);
    }
    if (start < chunk.length) { const tail = chunk.subarray(start); chunks.push(tail); size += tail.length; }
  });
  const answer = (value: RpcExtensionUIResponse) => {
    writes = writes.then(() => write(JSON.stringify(value)));
    return writes;
  };
  return { command, answer, events(listener: typeof events) { events = listener; }, close() { rejectPending(new Error("pi is closed")); events = () => {}; }, exited };
}

async function main(): Promise<void> {
  const location = pathToFileURL(process.argv[1] ?? "");
  const args = process.argv.slice(2);
  if (args.includes("--help")) {
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
  if (metricsFile) await writeFile(metricsFile, "");
  const view = await webview({ target: browser ? "browser" : "pane" });
  if (!view) throw new Error("koa requires a Kido pane or --browser");
  const teardown: (() => void | Promise<void>)[] = [() => view.close().catch(error => { process.stderr.write(`koa: close: ${errorText(error)}\n`); })];
  let shutdownPromise: Promise<void> | undefined;
  const shutdown = () => shutdownPromise ??= Promise.allSettled(teardown.reverse().map(async close => close())).then(() => {});
  const start = async () => {
    let metricsWrites: Promise<void> | undefined;
    const dir = mkdtempSync(join(tmpdir(), `koa-${process.pid}-`));
    const removeDir = () => rmSync(dir, { recursive: true, force: true });
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
    const state: Omit<State, "pi" | "queue"> = { working: false, aborted: false, name: "pi", levels: [], cwd: process.cwd(), home: homedir(), dialogs: [], statuses: {} };
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
    const spawnPi = (args: string[]) => spawn(executable, ["--mode", "rpc", "--extension", fileURLToPath(new URL("../pi/ko-pi.ts", location)), "--harness", browser ? "koa-browser" : "koa", ...args], { detached: true, stdio: "pipe" });
    let child = spawnPi(pass);
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
    const watch = (child: ChildProcessWithoutNullStreams, link: ReturnType<typeof rpc>) => {
      let stderr = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (text: string) => { stderr = (stderr + text).split(/\n(?=.)/s).slice(-5).join("\n"); process.stderr.write(text); });
      background(link.exited.then(async exit => {
        if ("exited" in exit && exit.exited === 0) {
          await shutdown();
          return;
        }
        pi = { type: "exited", ...exit, at: Date.now(), stderr: stderr.trimEnd() }; state.working = false; delete state.since;
        state.dialogs = []; state.statuses = {};
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
      await link.command({ type: "get_session_stats" }, response => {
        if (response.success && response.command === "get_session_stats") {
          const usage = response.data.contextUsage;
          state.context = usage && { tokens: usage.tokens, window: usage.contextWindow, percent: usage.percent };
          if (notify) publish();
        }
      });
    };
    const levels = (notify = true) => link.command({ type: "get_available_thinking_levels" }, response => {
      if (response.success && response.command === "get_available_thinking_levels") { state.levels = response.data.levels; if (notify) publish(); }
    });
    let session: string | undefined;
    const rebuild = () => link.command({ type: "get_messages" }, response => {
      if (response.success && response.command === "get_messages") feed.rebuild(response.data.messages, session);
    });
    const refresh = async () => {
      if (pi.type === "exited" || stopping) return;
      pi = { type: "starting" };
      const response = await link.command({ type: "get_state" }, response => {
        if (response.success && response.command === "get_state") {
          session = response.data.sessionId;
          state.name = response.data.sessionName ?? "pi";
          state.model = response.data.model; state.thinking = response.data.thinkingLevel; state.sessionFile = response.data.sessionFile;
        }
      });
      if (response.success && response.command === "get_state" && response.data.sessionFile) {
        try {
          const header = JSON.parse((await readFile(response.data.sessionFile, "utf8")).split("\n")[0] ?? "{}");
          if (typeof header.cwd === "string") state.cwd = header.cwd;
        } catch (error) {
          if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) process.stderr.write(`koa: session header: ${errorText(error)}\n`);
        }
      }
      if (!response.success) throw new Error(response.error);
      title();
      await Promise.all([rebuild(), levels(false), stats(false)]);
      if (pi.type === "starting") { pi = { type: "ready" }; publish(); }
    };
    let userAttachments: Attachment[] = [];
    let partial: Assistant | undefined;
    let outcome: { type: "done" } | { type: "error"; message: string } = { type: "done" };
    let compaction: { root: Root; working: boolean; since?: number } | undefined;
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
      if (pi.type === "exited" || stopping) return;
      switch (event.type) {
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
              case "toolcall_delta": argumentsText.set(index, (argumentsText.get(index) ?? "") + delta.delta); argumentTimer ??= setTimeout(applyArguments, FLUSH_MS); break;
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
        case "compaction_start": compaction = { root, working: state.working, since: state.since }; state.working = true; state.since ??= Date.now(); status("working"); publish(); break;
        case "agent_settled": state.working = false; delete state.since; state.aborted = event.aborted; status(event.aborted ? "idle" : outcome.type, outcome.type === "error" ? outcome.message : state.name); publish(); background(stats()); break;
        case "queue_update": pendingPrompts.update({ steering: event.steering, followUp: event.followUp }); publish(); break;
        case "thinking_level_changed": state.thinking = event.level; publish(); break;
        case "session_info_changed": state.name = event.name ?? "pi"; title(); publish(); break;
        case "compaction_end":
          if (!event.willRetry && compaction) {
            state.working = compaction.working; state.since = compaction.since;
            if (event.errorMessage) status("error", event.errorMessage.split("\n")[0]);
            else status(compaction.root.value, compaction.root.message);
            publish();
          }
          compaction = undefined;
          background(rebuild()); background(stats()); break;
        case "turn_end": background(stats()); break;
      }
    };
    const records = (record: RpcResponse | JsonAgentSessionEvent | RpcExtensionUIRequest) => {
      if (record.type === "extension_ui_request") {
        switch (record.method) {
          case "select": case "confirm": case "input": case "editor":
            state.dialogs.push({ ...record, ...("timeout" in record && record.timeout !== undefined ? { expires: Date.now() + record.timeout } : {}) });
            if ("timeout" in record && record.timeout !== undefined) dialogTimers.set(record.id, setTimeout(() => removeDialog(record.id), record.timeout));
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
          state.working = false; state.aborted = false; delete state.since; pendingPrompts.reset(); userAttachments = []; attached.reset();
          status("idle"); background(refresh());
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
    const command = async (value: RpcCommand, response: ServerResponse) => {
      const result = await link.command(value);
      if (result.success && result.command === "set_model") { state.model = result.data; await levels(false); publish(); }
      reply(response, result);
    };
    const routes: Record<string, { method: "GET" | "POST"; access: "ready" | "alive" | "exited" | "any"; handle(value: unknown, response: ServerResponse): void | Promise<void> }> = {
      "/complete": { method: "POST", access: "alive", handle: async (value, response) => {
        const query = completeBody(value);
        if ("error" in query) { respond(response, 400, JSON.stringify(query)); return; }
        const controller = new AbortController();
        const signal = AbortSignal.any([controller.signal, lifetime.signal]);
        const abort = () => controller.abort();
        response.once("close", abort);
        try {
          const result = await complete(query.text, query.pos, { cwd: state.cwd, fd, signal, agents, commands: async () => {
            if (pi.type !== "ready") return [];
            const result = await link.command({ type: "get_commands" }, undefined, signal);
            return result.success && result.command === "get_commands" ? result.data.commands : [];
          } });
          if (!controller.signal.aborted) respond(response, 200, JSON.stringify(result));
        } catch (error) { if (!controller.signal.aborted) throw error; }
        finally { response.removeListener("close", abort); }
      } },
      "/models": { method: "GET", access: "ready", handle: (_value, response) => command({ type: "get_available_models" }, response) },
      "/prompt": { method: "POST", access: "ready", handle: async (value, response) => {
        const prompt = promptBody(value);
        if ("error" in prompt) { respond(response, 400, JSON.stringify(prompt)); return; }
        const name = nameCommand(prompt.text);
        if (name) {
          if (name.type === "query") {
            const result = await link.command({ type: "get_state" });
            if (!result.success || result.command !== "get_state") { reply(response, result); return; }
            feed.notify(result.data.sessionName ? "Session name: " + result.data.sessionName : "Usage: /name <name>", result.data.sessionName ? "info" : "warning");
          } else {
            const result = await link.command({ type: "set_session_name", name: name.name });
            if (!result.success) { reply(response, result); return; }
            feed.notify("Session name set: " + state.name, "info");
          }
          respond(response, 200, JSON.stringify({ disposition: "handled" })); return;
        }
        const files = await attached.prepare(prompt.attachments);
        const message = [prompt.text, ...files.paths].filter(Boolean).join("\n");
        const mode = state.working ? prompt.mode === "follow_up" ? "followUp" : "steer" : "prompt";
        const entry = pendingPrompts.add(message, mode, files.files);
        const result = await link.command({ type: "prompt", message, ...(files.images.length ? { images: files.images } : {}), ...(mode !== "prompt" ? { streamingBehavior: mode } : {}) });
        if (result.success) attached.consume(prompt.attachments, result.command === "prompt" && result.data.disposition === "queued" ? "queued" : "used"); else pendingPrompts.reject(entry);
        reply(response, result);
      } },
      "/abort": { method: "POST", access: "ready", handle: (_value, response) => command({ type: "abort" }, response) },
      "/queue/clear": { method: "POST", access: "ready", handle: async (_value, response) => {
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
      "/model": { method: "POST", access: "ready", handle: (value, response) => {
        const model = modelBody(value);
        if ("error" in model) throw new Error(model.error);
        return command({ type: "set_model", ...model }, response);
      } },
      "/thinking": { method: "POST", access: "ready", handle: (value, response) => {
        const thinking = thinkingBody(value, state.levels);
        if ("error" in thinking) throw new Error(thinking.error);
        return command({ type: "set_thinking_level", ...thinking }, response);
      } },
      "/dialog": { method: "POST", access: "alive", handle: async (value, response) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        const dialog = state.dialogs.find(dialog => dialog.id === id.id);
        if (!dialog) throw new Error("Dialog is not open");
        const answer = dialogBody(value, dialog);
        if ("error" in answer) throw new Error(answer.error);
        removeDialog(dialog.id);
        await link.answer(answer); respond(response, 200, "{}");
      } },
      "/editor/ack": { method: "POST", access: "ready", handle: (value, response) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        if (state.editor?.id === id.id) { delete state.editor; publish(); }
        respond(response, 200, "{}");
      } },
      "/pi/start": { method: "POST", access: "exited", handle: async (_value, response) => {
        const args: string[] = [];
        for (let i = 0; i < pass.length; i++) {
          const arg = pass[i];
          if (state.sessionFile && ["--session", "--session-id", "--fork", "--model", "--thinking"].includes(arg ?? "")) { i++; continue; }
          if (state.sessionFile && ["--continue", "-c", "--no-session"].includes(arg ?? "")) continue;
          if (arg !== undefined) args.push(arg);
        }
        child = spawnPi([...args, ...(state.sessionFile ? ["--session", state.sessionFile] : [])]); link = rpc(child);
        pi = { type: "starting" }; state.aborted = false; pendingPrompts.reset(); userAttachments = []; attached.reset();
        partial = undefined; argumentsText.clear(); outcome = { type: "done" };
        watch(child, link); link.events(records); status("idle");
        await refresh(); respond(response, 200, "{}");
      } },
      "/quit": { method: "POST", access: "any", handle: (_value, response) => {
        response.setHeader("Connection", "close");
        const timer = setTimeout(() => background(shutdown()), QUIT_REPLY_MS);
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
        if (await attached.handle(request, response, !stopping && pi.type !== "exited")) return;
        if (await stepFile(request, response, feed.stepPath, state.cwd, state.home)) return;
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
        switch (route.access) {
          case "ready": if (!running()) throw new Error(pi.type === "starting" ? "pi is starting" : "pi is not running"); break;
          case "alive": if (stopping || pi.type === "exited") throw new Error("pi is not running"); break;
          case "exited": if (stopping || pi.type !== "exited") throw new Error("pi is already running"); break;
          case "any": break;
          default: { const access: never = route.access; throw new Error(access); }
        }
        let value: unknown;
        if (request.method === "POST") {
          const bytes = await readBody(request, 1 << 20);
          if (bytes === undefined) { respond(response, 413, "{}"); return; }
          try { value = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, JSON.stringify({ error: "A JSON body is required" })); return; }
        }
        await route.handle(value, response);
      } catch (error) { respond(response, 409, JSON.stringify({ error: errorText(error) })); }
    };
    const server = createServer((request, response) => { background(handle(request, response)); });
    teardown.push(() => { server.close(); server.closeAllConnections(); });
    const onSignal = () => background(shutdown());
    teardown.push(() => { for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.off(signal, onSignal); });
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(signal, onSignal);
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(view.socketPath, resolve); });
    if (!stopping) { status("idle"); background(refresh()); }
    title();
    const show = (supported: boolean) => { if (stopping) return; if (supported) background(view.show()); else process.stdout.write("koa: this client does not show webviews; the page is still served\n"); };
    view.on("supported", show); show(view.supported);
    if (view.url) process.stderr.write(`koa: ${view.url}\n`);
  };
  try { await start(); } catch (error) { await shutdown(); throw error; }
}

main().catch(error => { process.stderr.write(`koa: ${errorText(error)}\n`); process.exitCode = 1; });
