import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { StringDecoder } from "node:string_decoder";
import { decoder, frames } from "./kido-pi-wire.ts";

const tty = process.stdin.isTTY;
const saved = tty ? spawnSync("stty", ["-g"], { stdio: [0, "pipe", 2], timeout: 1000 }).stdout.toString().trim() : "";
if (tty) spawnSync("stty", ["raw", "-echo"], { stdio: [0, 1, 2], timeout: 1000 });
const argv: string[] = process.env.KIDO_PI_RPC ? JSON.parse(process.env.KIDO_PI_RPC) : ["pi"];
const child = spawn(argv[0], [...argv.slice(1), "--mode", "rpc", ...process.argv.slice(2)], { stdio: ["pipe", "pipe", "inherit"] });
const instance = randomUUID();
let seq = 0, generation = 0, exiting = false, line = "", rpcLine = "";
const record: Record<string, any> = { entries: [], leafId: null, partialAssistant: null, tools: {}, bash: {}, queues: { steering: [], followUp: [] }, dialogs: {}, status: {}, widgets: {}, notifications: [], title: "", state: {}, models: [], thinkingLevels: [], commands: [] };
const timers = new Map<string, NodeJS.Timeout>();
let liveId: string | null = null, liveCounter = 0;
const ended: { uiId: string; role: string; timestamp: number }[] = [];
let output = Promise.resolve();
function send(value: Record<string, any>) {
  const chunks = frames(JSON.stringify(value), "out", seq + 1);
  seq += chunks.length;
  output = output.then(async () => {
    for (const chunk of chunks) await new Promise<void>((resolve, reject) => process.stdout.write(chunk, error => error ? reject(error) : resolve()));
  });
}
function hello() { return { type: "hello", instance, sessionId: record.state.sessionId ?? null, sessionFile: record.state.sessionFile ?? null, cwd: process.cwd() }; }
function request(type: string) { child.stdin.write(JSON.stringify({ type, id: `bridge:${generation}:${type}`, ...(type === "get_entries" && record.entries.length ? { since: record.entries.at(-1).id } : {}) }) + "\n"); }
const bootstrap = new Set<string>();
function refresh() { for (const type of ["get_state", "get_entries", "get_available_models", "get_available_thinking_levels", "get_commands"]) { bootstrap.add(type); request(type); } }
function closeDialog(id: string) {
  if (!record.dialogs[id]) return false;
  delete record.dialogs[id]; clearTimeout(timers.get(id)); timers.delete(id);
  send({ type: "dialog_closed", generation, id }); return true;
}
function branch() {
  const entries = new Map<string, any>(record.entries.map((entry: any) => [entry.id, entry]));
  const result = []; let id = record.leafId;
  while (id && entries.has(id)) { const entry = entries.get(id); result.push(entry); entries.delete(id); id = entry.parentId; }
  return result.reverse();
}
function command(value: Record<string, any>) {
  if (value.type === "snapshot") { send({ type: "snapshot", id: value.id ?? null, hello: hello(), seq, generation, record: { ...record, entries: branch().slice(-200) } }); return; }
  if (value.type === "history") {
    const active = branch(); const end = active.findIndex(entry => entry.id === value.before);
    const entries = value.generation === generation && end >= 0 ? active.slice(Math.max(0, end - Math.min(200, Math.max(1, value.limit))), end) : [];
    send({ type: "history", id: value.id, generation, entries, before: entries.length && active[0].id !== entries[0].id ? entries[0].id : null }); return;
  }
  if (value.type === "bash") event({ type: "bash_execution_start", id: value.id, command: value.command });
  if (value.type === "extension_ui_response" && !closeDialog(value.id)) return;
  if (value.type === "abort") for (const id of Object.keys(record.dialogs)) closeDialog(id);
  child.stdin.write(JSON.stringify(value) + "\n");
}
function event(value: Record<string, any>) {
  if (value.type === "response" && value.id?.startsWith("bridge:") && Number(value.id.split(":")[1]) !== generation) return;
  if (value.type === "response" && value.success) {
    const data = value.data;
    if (value.command === "get_entries") {
      const known = new Map(record.entries.map((entry: any) => [entry.id, entry]));
      data.entries = data.entries.map((entry: any) => {
        if (known.has(entry.id)) return known.get(entry.id);
        const index = ended.findIndex(message => message.role === (entry.type === "custom_message" ? "custom" : entry.message?.role) && message.timestamp === (entry.type === "custom_message" ? Date.parse(entry.timestamp) : entry.message?.timestamp));
        if (index >= 0) entry.uiId = ended.splice(index, 1)[0].uiId;
        if (entry.message?.role === "bashExecution") {
          const id = Object.keys(record.bash).find(id => record.bash[id].ended && record.bash[id].command === entry.message.command);
          if (id) { entry.uiId = id; delete record.bash[id]; }
        }
        record.entries.push(entry); known.set(entry.id, entry);
        if (entry.message?.role === "toolResult") delete record.tools[entry.message.toolCallId];
        return entry;
      });
      record.leafId = data.leafId;
    }
    if (value.command === "get_state") record.state = data;
    if (value.command === "get_available_models") record.models = data.models;
    if (value.command === "get_available_thinking_levels") record.thinkingLevels = data.levels;
    if (value.command === "get_commands") record.commands = data.commands;
    if (["new_session", "switch_session", "fork", "clone"].includes(value.command) && !data?.cancelled) {
      for (const id of Object.keys(record.dialogs)) closeDialog(id);
      liveId = null; liveCounter = 0; ended.length = 0;
      generation++; record.entries = []; record.leafId = null; record.partialAssistant = null; record.tools = {}; record.bash = {}; record.queues = { steering: [], followUp: [] }; record.state = {}; record.status = {}; record.widgets = {}; record.notifications = []; record.title = ""; record.retry = null; record.compaction = null; refresh();
    } else if (["set_model", "set_thinking_level"].includes(value.command)) refresh();
  }
  if (value.type === "message_start") {
    liveId = `live-${++liveCounter}`; value.uiId = liveId;
    if (value.message.role === "assistant") record.partialAssistant = { ...value.message, uiId: liveId };
  }
  if (value.type === "message_end") {
    value.uiId = liveId ?? `live-${++liveCounter}`;
    ended.push({ uiId: value.uiId, role: value.message.role, timestamp: value.message.timestamp }); liveId = null;
  }
  if (value.type === "message_update") {
    const delta = value.assistantMessageEvent;
    record.partialAssistant ??= { role: "assistant", content: [] };
    const content = record.partialAssistant.content;
    const index = delta.contentIndex;
    if (delta.type.endsWith("_start")) content[index] = delta.type === "toolcall_start" ? { type: "toolCall", id: delta.id, name: delta.toolName, arguments: {}, argumentsText: "" } : { type: delta.type.split("_")[0], [delta.type.split("_")[0]]: "" };
    if (delta.type.endsWith("_delta")) { const key = delta.type === "toolcall_delta" ? "argumentsText" : delta.type.split("_")[0]; content[index] ??= { type: delta.type.split("_")[0], [key]: "" }; content[index][key] += delta.delta; }
    if (delta.type === "text_end") content[index] = { type: "text", text: delta.content };
    if (delta.type === "thinking_start") content[index].active = true;
    if (delta.type === "thinking_end") content[index] = { type: "thinking", thinking: delta.content, active: false };
    if (delta.type === "toolcall_end") content[index] = delta.toolCall;
    record.partialAssistant.usage = value.usage;
  }
  if (value.type === "compaction_end") request("get_entries");
  if (value.type === "message_end") { if (value.message.role === "assistant") { record.partialAssistant = null; const text = value.message.content.filter((x: any) => x.type === "text").map((x: any) => x.text).join("").replace(/[\x00-\x1f\x7f]/g, " "); process.stdout.write(`\r\n${text.slice(-1000)}\r\n> `); } request("get_entries"); }
  if (value.type === "tool_execution_start") record.tools[value.toolCallId] = value;
  if (value.type === "tool_execution_update") record.tools[value.toolCallId] = { ...record.tools[value.toolCallId], partialResult: value.partialResult };
  if (value.type === "tool_execution_end") record.tools[value.toolCallId] = { ...record.tools[value.toolCallId], result: value.result, isError: value.isError, ended: true };
  if (value.type === "bash_execution_start") record.bash[value.id] = { command: value.command, output: "", ended: false };
  if (value.type === "bash_execution_update") { const bash = record.bash[value.id ?? ""] ?? {}; record.bash[value.id ?? ""] = { ...bash, output: (bash.output ?? "") + value.delta }; }
  if (value.type === "response" && value.command === "bash") {
    const id = value.id ?? "";
    record.bash[id] = { ...record.bash[id], ...value.data, ended: true }; request("get_entries");
  }
  if (value.type === "queue_update") record.queues = { steering: value.steering, followUp: value.followUp };
  if (value.type === "agent_start") { record.state.isStreaming = true; process.stdout.write("\r\n[running]\r\n> "); }
  if (value.type === "agent_end") { record.state.isStreaming = false; process.stdout.write("\r\n[idle]\r\n> "); request("get_state"); }
  if (value.type.startsWith("auto_retry_")) record.retry = value.type.endsWith("start") ? value : null;
  if (["compaction_start", "compaction_end"].includes(value.type)) record.compaction = value.type.endsWith("start") ? value : null;
  if (value.type === "extension_ui_request") {
    if (["confirm", "select", "input", "editor"].includes(value.method)) { record.dialogs[value.id] = value; if (value.timeout) timers.set(value.id, setTimeout(() => closeDialog(value.id), value.timeout)); }
    if (value.method === "setStatus") { if (value.statusText === undefined) delete record.status[value.statusKey]; else record.status[value.statusKey] = value.statusText; }
    if (value.method === "setWidget") { if (value.widgetLines === undefined) delete record.widgets[value.widgetKey]; else record.widgets[value.widgetKey] = value; }
    if (value.method === "setTitle") record.title = value.title;
    if (value.method === "notify") record.notifications.push(value);
  }
  send(value);
  if (value.type === "response" && value.id === `bridge:${generation}:${value.command}` && bootstrap.delete(value.command) && !bootstrap.size) {
    send(hello());
    command({ type: "snapshot" });
  }
}
const utf8 = new StringDecoder("utf8");
child.stdout.on("data", bytes => {
  rpcLine += utf8.write(bytes);
  let end;
  while ((end = rpcLine.indexOf("\n")) >= 0) { const text = rpcLine.slice(0, end); rpcLine = rpcLine.slice(end + 1); try { event(JSON.parse(text)); } catch (error) { process.stderr.write(`kido-pi: ${error}\n`); } }
});
let escape: NodeJS.Timeout | undefined;
const inputText = new StringDecoder("utf8");
const input = decoder("in", command, send, bytes => {
  for (const key of inputText.write(bytes)) {
    if (key === "\x03" || key === "\x04") { void finish(0); return; }
    if (key === "\x1b") command({ type: "abort" });
    else if (key === "\r" || key === "\n") { if (line) command({ type: "prompt", message: line, ...(record.state.isStreaming ? { streamingBehavior: "steer" } : {}) }); line = ""; process.stdout.write("\r\n> "); }
    else if (key === "\x7f") line = line.slice(0, -1);
    else if (key >= " ") { line += key; process.stdout.write(key); }
  }
});
process.stdin.on("data", bytes => { clearTimeout(escape); input(bytes); escape = setTimeout(() => input(Buffer.alloc(0)), 40); });
const heartbeat = setInterval(() => { if (!bootstrap.size) send(hello()); }, 2000);
async function finish(code: number) {
  if (exiting) return; exiting = true;
  clearInterval(heartbeat); clearTimeout(escape); for (const timer of timers.values()) clearTimeout(timer);
  const stopped = child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : new Promise<void>(resolve => {
    const kill = setTimeout(() => { child.kill("SIGKILL"); resolve(); }, 500);
    child.once("exit", () => { clearTimeout(kill); resolve(); }); child.kill();
  });
  send({ type: "bye", instance });
  if (saved) spawnSync("stty", [saved], { stdio: [0, 1, 2], timeout: 1000 });
  await Promise.all([stopped, Promise.race([output, new Promise(resolve => setTimeout(resolve, 500))])]);
  process.exit(code);
}
process.on("exit", () => { child.kill("SIGKILL"); if (saved) spawnSync("stty", [saved], { stdio: [0, 1, 2], timeout: 1000 }); });
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, () => void finish(0));
child.on("error", error => { process.stderr.write(`${error.message}\n`); void finish(1); });
child.on("exit", code => void finish(code ?? 1));
child.stdin.on("error", () => {});
process.stdin.on("end", () => void finish(0));
process.stdout.write("kido-pi ready\r\n> "); refresh();
