import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename } from "node:path";
import timers from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { RpcCommand, RpcResponse, JsonAgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { transcript, respond, readBody, promptBody, errorText, replaceControlCharacters, utf8Prefix } from "../pi/transcript.ts";
import { webview } from "../webview/index.ts";

const RPC_RESPONSE_MS = 10000;
const FLUSH_MS = 50;
const QUIT_REPLY_MS = 1000;

type Assistant = Extract<AgentMessage, { role: "assistant" }>;
type Exit = { exited: number } | { signal: string } | { failed: string };
type State = { working: boolean; since?: number; aborted: boolean; name: string; model?: string; thinking?: string; levels: string[]; context?: { tokens: number | null; window: number; percent: number | null }; cwd: string; branch?: string; dirty?: boolean; queue: { steering: readonly string[]; followUp: readonly string[] }; pi?: Exit; dialogs: [] };
type Root = { value: "idle" | "working" | "done" | "error"; message: string };

function signalPi(child: ChildProcessWithoutNullStreams, signal: NodeJS.Signals): void {
  if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error;
  }
}

function rpc(child: ChildProcessWithoutNullStreams) {
  let serial = 0;
  let writes = Promise.resolve();
  let events: (record: RpcResponse | JsonAgentSessionEvent) => void = () => {};
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
  const command = (value: RpcCommand, apply?: (response: RpcResponse) => void): Promise<RpcResponse> => {
    if (child.exitCode !== null || child.signalCode !== null || child.stdin.destroyed) return Promise.reject(new Error("pi is not running"));
    const id = String(++serial);
    const result = new Promise<RpcResponse>((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`pi ${value.type} response timed out`)); }, RPC_RESPONSE_MS);
      pending.set(id, {
        resolve: response => {
          clearTimeout(timer);
          try { apply?.(response); resolve(response); } catch (error) { reject(error); }
        },
        reject: error => { clearTimeout(timer); reject(error); },
      });
    });
    writes = writes.then(async () => {
      if (!pending.has(id)) return;
      if (!child.stdin.write(JSON.stringify({ ...value, id }) + "\n")) await once(child.stdin, "drain");
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
      let record: RpcResponse | JsonAgentSessionEvent;
      try { record = JSON.parse(line); } catch { process.stderr.write(`koa: pi stdout: ${line}\n`); continue; }
      if (!record || typeof record !== "object" || !("type" in record)) { process.stderr.write(`koa: invalid pi record: ${line}\n`); continue; }
      if (record.type === "response" && record.id) { pending.get(record.id)?.resolve(record); pending.delete(record.id); }
      events(record);
    }
    if (start < chunk.length) { const tail = chunk.subarray(start); chunks.push(tail); size += tail.length; }
  });
  return { command, events(listener: typeof events) { events = listener; }, exited };
}

async function main(): Promise<void> {
  const location = pathToFileURL(process.argv[1] ?? "");
  const args = process.argv.slice(2);
  let browser = false;
  let executable = "pi";
  const pass: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--browser") browser = true;
    else if (arg === "--pi") {
      const path = args[++i];
      if (!path) throw new Error("--pi requires a path");
      executable = path;
    } else if (arg !== undefined) pass.push(arg);
  }
  const configured = Number(process.env.KOA_PI_EXIT_MS ?? 5000);
  const exitMs = Number.isFinite(configured) && configured > 0 ? configured : 5000;
  const page = await readFile(new URL("../pi/ko-pi-page.html", location), "utf8");
  const view = await webview({ target: browser ? "browser" : "pane" });
  if (!view) throw new Error("koa requires a Kido pane or --browser");
  const feed = transcript({ flushMs: FLUSH_MS });
  const state: State = { working: false, aborted: false, name: "pi", levels: [], cwd: process.cwd(), queue: { steering: [], followUp: [] }, dialogs: [] };
  let stopping = false;
  let root: Root = { value: "idle", message: state.name };
  const publish = () => feed.state(state);
  const status = (value: Root["value"] | "clear", message = state.name) => {
    if (value !== "clear") root = { value, message };
    const encoded = Buffer.from(utf8Prefix(replaceControlCharacters(message).replace(/\s+/g, " ").trim(), 2048)).toString("base64");
    process.stdout.write(`\x1b]7501;state=${value}${value === "clear" ? "" : `:app=pi:msg=${encoded}`}\x1b\\`);
  };
  const title = () => process.stdout.write(`\x1b]0;${utf8Prefix(replaceControlCharacters(`koa - ${state.name} - ${basename(state.cwd)}`), 2048)}\x1b\\`);
  const child = spawn(executable, ["--mode", "rpc", "--extension", fileURLToPath(new URL("../pi/ko-pi.ts", location)), ...pass], { detached: true, stdio: "pipe" });
  const link = rpc(child);
  const background = (work: Promise<unknown>) => { void work.catch(error => { if (state.pi === undefined && !stopping) process.stderr.write(`koa: ${errorText(error)}\n`); }); };
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (text: string) => { stderr = (stderr + text).split("\n").slice(-20).join("\n"); process.stderr.write(text); });
  background(link.exited.then(exit => {
    state.pi = exit; state.working = false; delete state.since;
    if ("failed" in exit) process.stderr.write(`koa: ${exit.failed}\n`);
    status("clear"); publish();
    return timers.setTimeout(exitMs, undefined, { ref: false }).then(() => { child.stdout.destroy(); child.stderr.destroy(); });
  }));
  const git = async (args: string[]): Promise<string | undefined> => {
    const proc = spawn("git", args, { cwd: state.cwd, stdio: ["ignore", "pipe", "ignore"], timeout: 2000 });
    let output = "";
    proc.stdout.on("data", bytes => { output += bytes; });
    return new Promise(resolve => { proc.once("error", () => resolve(undefined)); proc.once("close", code => resolve(code === 0 ? output.trim() : undefined)); });
  };
  const branch = async (notify = true) => {
    const cwd = state.cwd;
    const [name, changes] = await Promise.all([git(["symbolic-ref", "--short", "HEAD"]), git(["status", "--porcelain", "--untracked-files=no"])]);
    if (state.cwd !== cwd || stopping) return;
    state.branch = name; state.dirty = changes === undefined ? undefined : changes.length > 0;
    if (notify) publish();
  };
  const stats = async (notify = true) => {
    await link.command({ type: "get_session_stats" }, response => {
      if (response.success && response.command === "get_session_stats") {
        const usage = response.data.contextUsage;
        state.context = usage && { tokens: usage.tokens, window: usage.contextWindow, percent: usage.percent };
        if (notify) publish();
      }
    });
  };
  const rebuild = () => link.command({ type: "get_messages" }, response => {
    if (response.success && response.command === "get_messages") feed.rebuild(response.data.messages);
  });
  const refresh = async () => {
    const response = await link.command({ type: "get_state" }, response => {
      if (response.success && response.command === "get_state") {
        state.name = response.data.sessionName ?? "pi";
        state.model = response.data.model?.id; state.thinking = response.data.thinkingLevel;
      }
    });
    if (response.success && response.command === "get_state" && response.data.sessionFile) {
      try {
        const header = JSON.parse((await readFile(response.data.sessionFile, "utf8")).split("\n")[0] ?? "{}");
        if (typeof header.cwd === "string") state.cwd = header.cwd;
      } catch (error) { process.stderr.write(`koa: session header: ${errorText(error)}\n`); }
    }
    title();
    await Promise.all([rebuild(), link.command({ type: "get_available_thinking_levels" }, response => {
      if (response.success && response.command === "get_available_thinking_levels") state.levels = response.data.levels;
    }), stats(false), branch(false)]);
    publish();
  };
  let partial: Assistant | undefined;
  let outcome: { type: "done" } | { type: "error"; message: string } = { type: "done" };
  let compaction: { root: Root; working: boolean; since?: number } | undefined;
  const argumentsText = new Map<number, string>();
  let argumentTimer: NodeJS.Timeout | undefined;
  const applyArguments = () => {
    argumentTimer = undefined;
    if (!partial) return;
    for (const [index, text] of argumentsText) {
      const block = partial.content[index];
      if (block?.type === "toolCall") { try { block.arguments = JSON.parse(text); } catch {} }
    }
    feed.message(partial, "update");
  };
  const event = (event: JsonAgentSessionEvent, state: State): void => {
    if (state.pi !== undefined || stopping) return;
    switch (event.type) {
      case "message_start":
        if (event.message.role === "assistant") { clearTimeout(argumentTimer); argumentTimer = undefined; partial = event.message; argumentsText.clear(); }
        feed.message(event.message, "start"); break;
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
        feed.message(partial, "update"); break;
      }
      case "message_end":
        feed.message(event.message, "end");
        if (event.message.role === "assistant") {
          clearTimeout(argumentTimer); argumentTimer = undefined; argumentsText.clear(); partial = undefined;
          outcome = event.message.stopReason === "error" ? { type: "error", message: (event.message.errorMessage ?? "").split("\n")[0] ?? "" } : { type: "done" };
        }
        break;
      case "tool_execution_start": feed.toolRunning(event.toolCallId, Date.now()); break;
      case "tool_execution_update": feed.toolPartial(event.toolCallId, event.partialResult.content); break;
      case "tool_execution_end": feed.toolDone(event.toolCallId, event.result.content, event.isError, Date.now(), event.durationMs); break;
      case "agent_start": state.working = true; state.since = Date.now(); state.aborted = false; outcome = { type: "done" }; status("working"); publish(); break;
      case "compaction_start": compaction = { root, working: state.working, since: state.since }; state.working = true; state.since ??= Date.now(); status("working"); publish(); break;
      case "agent_settled": state.working = false; delete state.since; state.aborted = event.aborted; status(event.aborted ? "idle" : outcome.type, outcome.type === "error" ? outcome.message : state.name); publish(); background(stats()); background(branch()); break;
      case "queue_update": state.queue = { steering: event.steering, followUp: event.followUp }; publish(); break;
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
  link.events(record => {
    if (record.type === "response") {
      if (record.success && ["new_session", "switch_session", "fork", "clone"].includes(record.command)) background(refresh());
    } else event(record, state);
  });
  const waitExit = async (): Promise<boolean> => {
    const controller = new AbortController();
    try { return await Promise.race([link.exited.then(() => true), timers.setTimeout(exitMs, false, { signal: controller.signal })]); }
    finally { controller.abort(); }
  };
  const shutdown = async () => {
    if (stopping) return;
    stopping = true; clearTimeout(argumentTimer); feed.close();
    try { await view.hide(); } catch (error) { process.stderr.write(`koa: hide: ${errorText(error)}\n`); }
    try { await view.close(); } catch (error) { process.stderr.write(`koa: close: ${errorText(error)}\n`); }
    server.close(); server.closeAllConnections(); child.stdin.end();
    if (!await waitExit()) { signalPi(child, "SIGTERM"); if (!await waitExit()) { signalPi(child, "SIGKILL"); await link.exited; } }
    child.stdout.destroy(); child.stderr.destroy();
  };
  const handle = async (request: IncomingMessage, response: ServerResponse, state: State) => {
    try {
      if (feed.handle(request, response)) return;
      if (request.method === "GET" && request.url === "/") { respond(response, 200, page, "text/html; charset=utf-8"); return; }
      if (request.method !== "POST" || !["/prompt", "/abort", "/quit"].includes(request.url ?? "")) { respond(response, 404, "{}"); return; }
      const bytes = await readBody(request, 1 << 20);
      if (bytes === undefined) { respond(response, 413, "{}"); return; }
      let value: unknown;
      try { value = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, JSON.stringify(promptBody(undefined))); return; }
      if (request.url === "/quit") {
        response.setHeader("Connection", "close");
        const timer = setTimeout(() => background(shutdown()), QUIT_REPLY_MS);
        response.once("finish", () => { clearTimeout(timer); background(shutdown()); });
        respond(response, 200, "{}"); return;
      }
      let command: RpcCommand;
      if (request.url === "/abort") command = { type: "abort" };
      else {
        const prompt = promptBody(value);
        if ("error" in prompt) { respond(response, 400, JSON.stringify(prompt)); return; }
        command = { type: "prompt", message: prompt.text, ...(state.working ? { streamingBehavior: prompt.mode === "follow_up" ? "followUp" : "steer" } : {}) };
      }
      if (stopping || state.pi !== undefined) throw new Error("pi is not running");
      const result = await link.command(command);
      respond(response, result.success ? 200 : 409, JSON.stringify(result.success ? result.command === "prompt" ? result.data : {} : { error: result.error }));
    } catch (error) { respond(response, 409, JSON.stringify({ error: errorText(error) })); }
  };
  const server = createServer((request, response) => { background(handle(request, response, state)); });
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, () => background(shutdown()));
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(view.socketPath, resolve); });
  if (state.pi === undefined) { status("idle"); background(refresh()); }
  title(); publish();
  const show = (supported: boolean) => { if (stopping) return; if (supported) background(view.show()); else process.stdout.write("koa: this client does not show webviews; the page is still served\n"); };
  view.on("supported", show); show(view.supported);
  if (view.url) process.stderr.write(`koa: ${view.url}\n`);
}

main().catch(error => { process.stderr.write(`koa: ${errorText(error)}\n`); process.exitCode = 1; });
