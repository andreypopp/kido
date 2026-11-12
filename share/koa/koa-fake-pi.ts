#!/usr/bin/env node
import { readFileSync, appendFileSync, writeFileSync, writeSync, closeSync, existsSync, watch } from "node:fs";
import { once } from "node:events";
import { fileURLToPath } from 'node:url';
import { setTimeout } from "node:timers/promises";
import { spawn } from "node:child_process";
import { connect, Socket } from "node:net";
import { createInterface } from 'node:readline';
import type { RpcCommand } from "@earendil-works/pi-coding-agent";

if (process.argv.some(arg => arg.endsWith('/koa-startup.ts'))) {
  const { startupResult } = await import('./koa-args.ts');
  const { parseArgs } = await import('./node_modules/@earendil-works/pi-coding-agent/dist/cli/args.js');
  const result = startupResult(parseArgs(JSON.parse(process.env.KOA_STARTUP_ARGS ?? '[]')));
  writeSync(3, JSON.stringify({ ...result, packageRoot: fileURLToPath(new URL('./node_modules/@earendil-works/pi-coding-agent', import.meta.url)) }) + '\n');
  process.exit('error' in result ? 1 : 0);
}

if (process.argv.includes('--version')) { process.stdout.write('fake-pi-resume-1\n'); process.exit(0); }
if (process.argv.some(arg => arg.endsWith('/koa-resume.ts'))) {
  const log = (value: object) => { if (process.env.KOA_FAKE_LOG) appendFileSync(process.env.KOA_FAKE_LOG, JSON.stringify(value) + '\n'); };
  log({ type: 'picker', args: JSON.parse(process.env.KOA_RESUME_ARGS ?? '[]') });
  process.once('exit', code => log({ type: 'picker_exit', code }));
  process.once('SIGTERM', () => { log({ type: 'picker_signal', signal: 'SIGTERM' }); process.exit(1); });
  const args: string[] = JSON.parse(process.env.KOA_RESUME_ARGS ?? '[]');
  let result = args.some(arg => ['--session', '--fork', '--no-session'].includes(arg)) ? 'skip' : '{"type":"cancel"}';
  if (process.env.KOA_FAKE_PICKER_GATE) {
    const gate = connect(process.env.KOA_FAKE_PICKER_GATE);
    const [bytes] = await once(gate, 'data'); gate.end();
    result = String(bytes);
  }
  if (result === 'skip') {
    if (!args.some(arg => ['--session', '--fork', '--no-session'].includes(arg))) process.exit(2);
    writeSync(3, '{"type":"skip"}\n');
  } else {
    if (result !== 'rpc') writeSync(3, '{"type":"ready"}\n');
    if (result === 'eof') closeSync(3);
    if (['rpc', 'signal', 'eof'].includes(result)) { process.stdin.resume(); await once(process.stdin, 'end'); }
    else if (result !== 'exit') writeSync(3, result + '\n');
  }
  process.exit(0);
}

type Step = { type: "respond"; command: "get_state" | "get_entries" | "get_messages" | "get_session_stats" | "get_available_thinking_levels" | "get_commands"; data: object; after?: object[] } | { type: "emit"; event: object } | { type: "raw"; text: string } | { type: "stderr"; text: string } | { type: "wait"; command: string; events?: object[]; after?: object[]; data?: object; error?: string; echo?: boolean; gate?: boolean | string; defer?: boolean } | { type: "exit"; code: number } | { type: "repeat"; count: number; events: object[]; delayMs?: number };
const script: Step[] = process.env.KOA_FAKE_SCRIPT ? readFileSync(process.env.KOA_FAKE_SCRIPT, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line)) : [];
let next = 0;
let working = false;
let bash: { id: string; cancel(): Promise<void> } | undefined;
const bashMessages: object[] = [];
const turnMessages: object[] = [];
let startupGate = process.env.KOA_FAKE_STARTUP_GATE;
const selectionFile = process.env.KOA_FAKE_SELECTION_FILE;
const selection: { model?: { id: string; provider: string }; thinkingLevel?: string } = selectionFile ? JSON.parse(readFileSync(selectionFile, "utf8")) : {};
if (selectionFile) {
  const model = process.argv[process.argv.indexOf("--model") + 1];
  const thinking = process.argv[process.argv.indexOf("--thinking") + 1];
  if (process.argv.includes("--model") && model) { const slash = model.indexOf("/"); selection.model = { provider: model.slice(0, slash), id: model.slice(slash + 1) }; }
  if (process.argv.includes("--thinking") && thinking) selection.thinkingLevel = thinking;
}
const responses = new Map<string, { data: object; after?: object[] }>();
let output = Promise.resolve();
const write = (text: string) => {
  output = output.then(async () => { if (!process.stdout.write(text)) await once(process.stdout, "drain"); });
  return output;
};
const emit = (event: object) => {
  if ("type" in event && event.type === "agent_start") working = true;
  if ("type" in event && event.type === "agent_settled") working = false;
  return write(JSON.stringify(event) + "\n");
};
const log = (value: object) => { if (process.env.KOA_FAKE_LOG) appendFileSync(process.env.KOA_FAKE_LOG, JSON.stringify(value) + "\n"); };
async function advance(): Promise<void> {
  while (next < script.length) {
    const step = script[next];
    if (!step || step.type === "wait") return;
    next++;
    if (step.type === "respond") responses.set(step.command, { data: step.data, after: step.after });
    else if (step.type === "emit") await emit(step.event);
    else if (step.type === "raw") await write(step.text);
    else if (step.type === "stderr") process.stderr.write(step.text);
    else if (step.type === "repeat") { for (let i = 0; i < step.count; i++) { for (const event of step.events) await emit(event); if (step.delayMs) await setTimeout(step.delayMs); } }
    else { await output; process.exit(step.code); }
  }
}
async function command(value: { type: string; id: string; sessionPath?: string; message?: string; images?: Extract<RpcCommand, { type: "prompt" }>["images"]; streamingBehavior?: string; provider?: string; modelId?: string; level?: string; command?: string; excludeFromContext?: boolean }): Promise<void> {
  log(value);
  if (value.type === 'switch_session' || value.type === 'new_session') sessionSocket?.write(JSON.stringify({ type: 'reset' }) + '\n');
  if (value.type === 'switch_session') {
    const rows: { path: string }[] = JSON.parse(process.env.KOA_FAKE_SESSIONS_FILE ? readFileSync(process.env.KOA_FAKE_SESSIONS_FILE, 'utf8') : process.env.KOA_FAKE_SESSIONS ?? '[]');
    if (!rows.some(row => row.path === value.sessionPath)) { await emit({ type: 'response', command: value.type, id: value.id, success: false, error: 'Unknown session path' }); return; }
  }
  if (value.type === "get_state" && startupGate) {
    const gate = connect(startupGate);
    startupGate = undefined;
    await once(gate, "data"); gate.end();
  }
  if ((value.type === 'switch_session' || value.type === 'new_session') && process.env.KOA_FAKE_SESSION_FILE_GATE && existsSync(process.env.KOA_FAKE_SESSION_FILE_GATE)) {
    const watcher = watch(process.env.KOA_FAKE_SESSION_FILE_GATE);
    try { await once(watcher, 'change'); } finally { watcher.close(); }
  }
  if ((value.type === 'switch_session' || value.type === 'new_session') && process.env.KOA_FAKE_SESSION_GATE) {
    const gate = connect(process.env.KOA_FAKE_SESSION_GATE);
    await once(gate, 'data'); gate.end();
  }
  if (value.type === "prompt" && value.message === "/koa-reload") {
    sessionSocket?.write(JSON.stringify({ type: "reset" }) + "\n");
    sessionSocket?.write(JSON.stringify({ type: "session", id: sessionId, generation: ++sessionGeneration, cwd: sessionCwd }) + "\n");
    if (process.env.KOA_FAKE_RELOAD_TURN) {
      const message = { role: "user", timestamp: Date.now(), content: [{ type: "text", text: "queued before reload" }] };
      turnMessages.push(message);
      await emit({ type: "agent_start" }); await emit({ type: "message_start", message }); await emit({ type: "message_end", message });
    }
    await write(JSON.stringify({ type: "response", command: "prompt", id: value.id, success: true, data: { disposition: "handled" } }) + "\n");
    return;
  }
  if (value.type === "prompt" && working && !["steer", "followUp"].includes(value.streamingBehavior ?? "")) {
    await emit({ type: "response", command: value.type, id: value.id, success: false, error: "prompt requires streamingBehavior while working" });
    return;
  }
  let data: object = {};
  if (value.type === "prompt") data = { disposition: working ? "queued" : "started" };
  else if (value.type === "get_commands") data = { commands: [] };
  else if (value.type === "get_state") data = { sessionName: "Fake pi", thinkingLevel: "low", sessionId: "fake", isStreaming: working };
  else if (value.type === "get_entries") data = { entries: [], leafId: null };
  else if (value.type === "get_messages") data = { messages: working ? turnMessages : bashMessages };
  else if (value.type === "get_available_thinking_levels") data = { levels: ["off", "low", "high"] };
  else if (value.type === "get_session_stats") data = { contextUsage: { tokens: 123, contextWindow: 1000, percent: 12.3 } };
  const configured = responses.get(value.type);
  if (configured) data = value.type === 'get_state' ? { sessionId: 'fake', ...configured.data } : configured.data;
  if (selectionFile) {
    if (value.type === "get_state") data = { ...data, ...selection };
    if (value.type === "set_model" && value.provider && value.modelId) { selection.model = { provider: value.provider, id: value.modelId }; writeFileSync(selectionFile, JSON.stringify(selection)); }
    if (value.type === "set_thinking_level" && value.level) { selection.thinkingLevel = value.level; writeFileSync(selectionFile, JSON.stringify(selection)); }
  }
  if (value.type === 'abort_bash' && bash) {
    await bash.cancel();
    await emit({ type: 'response', command: 'abort_bash', id: value.id, success: true });
    return;
  }
  if (value.type === 'get_state' && sessionSocket) {
    if (!('sessionId' in data) || typeof data.sessionId !== 'string') throw Error('get_state needs a session id');
    let cwd = process.env.KOA_FAKE_CWD ?? process.cwd();
    if ('sessionFile' in data && typeof data.sessionFile === 'string') { try { cwd = JSON.parse(readFileSync(data.sessionFile, 'utf8').split('\n')[0] ?? '{}').cwd ?? cwd; } catch {} }
    sessionCwd = cwd; sessionId = data.sessionId;
    sessionSocket.write(JSON.stringify({ type: 'session', id: data.sessionId, generation: ++sessionGeneration, cwd }) + '\n');
  }
  const step = script[next];
  if (step?.type === "wait" && step.command === value.type) {
    next++;
    if (step.echo) {
      if (value.type !== "prompt" || typeof value.message !== "string") throw Error("An echoed prompt needs a message");
      const message = { role: "user", timestamp: Date.now(), content: [{ type: "text", text: value.message }, ...(value.images ?? [])] };
      await emit({ type: "message_start", message }); await emit({ type: "message_end", message });
    }
    for (const event of step.events ?? []) await emit(value.type === 'bash' ? { ...event, id: value.id } : event);
    const respond = (response: object) => write([response, ...step.after ?? []].map(record => JSON.stringify(record) + '\n').join(''));
    if (value.type === 'bash') {
      const result = step.data ?? data;
      let cancelling = false;
      const finish = async (cancelled = cancelling) => {
        if (bash?.id !== value.id) return;
        bash = undefined;
        const final = { ...result, ...(cancelled ? { cancelled: true } : {}) };
        bashMessages.push({ role: 'bashExecution', command: value.command, timestamp: Date.now(), excludeFromContext: value.excludeFromContext, ...final });
        await respond({ type: 'response', command: 'bash', id: value.id, success: !step.error, ...(step.error ? { error: step.error } : { data: final }) });
      };
      bash = { id: value.id, cancel: async () => { if (typeof step.gate === 'string') cancelling = true; else await finish(true); } };
      if (typeof step.gate === 'string') { const gate = connect(step.gate); gate.once('data', () => { gate.end(); void finish(); }); }
      else if (!step.gate) await finish();
      await advance(); return;
    }
    if (value.type === 'prompt' && typeof step.gate === 'string') { const gate = connect(step.gate); await once(gate, 'data'); gate.end(); }
    if (step.defer) { await advance(); return; }
    const response = { type: "response", command: value.type, id: value.id, success: !step.error, ...(step.error ? { error: step.error } : { data: step.data ?? data }) };
    await respond(response);
    await advance();
  } else {
    const introspection = ["get_state", "get_entries", "get_messages", "get_available_thinking_levels", "get_session_stats", "get_commands"].includes(value.type);
    if (!introspection && (step?.type === "wait" || !["prompt", "abort", "steer", "follow_up"].includes(value.type))) {
      await emit({ type: "response", command: value.type, id: value.id, success: false, error: step?.type === "wait" ? `expected ${step.command}` : `unsupported command ${value.type}` });
    } else {
      await write([{ type: "response", command: value.type, id: value.id, success: true, data }, ...configured?.after ?? []].map(record => JSON.stringify(record) + "\n").join(""));
      if (configured) delete configured.after;
    }
  }
}
log({ type: "argv", args: process.argv.slice(2) });
let sessionSocket: Socket | undefined;
let sessionCwd = process.cwd();
let sessionId = "fake";
let sessionGeneration = 0;
if (process.argv.some(arg => arg.endsWith('/koa-sessions.ts'))) {
  const channel = new Socket({ fd: 3, readable: true, writable: true }); sessionSocket = channel;
  channel.on('error', () => {});
  const lines = createInterface({ input: channel });
  lines.on('line', line => {
    const query = JSON.parse(line); log({ type: 'session_query', ...query });
    if (query.type === 'completion_context') {
      channel.write(JSON.stringify({ type: 'completion_context', id: query.id, context: process.env.KOA_FAKE_COMPLETION_CONTEXT ? JSON.parse(process.env.KOA_FAKE_COMPLETION_CONTEXT) : { type: 'host', cwd: sessionCwd } }) + '\n');
    } else if (query.type === 'restart_state') {
      const file = process.env.KOA_FAKE_RESTART_FILE;
      channel.write(JSON.stringify({ type: 'restart_state', id: query.id, state: file && existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : { type: 'ready' } }) + '\n');
    } else if (query.type === 'list') {
      const rows = JSON.parse(process.env.KOA_FAKE_SESSIONS_FILE ? readFileSync(process.env.KOA_FAKE_SESSIONS_FILE, 'utf8') : process.env.KOA_FAKE_SESSIONS ?? '[]');
      rows.sort((a: { modified: number }, b: { modified: number }) => b.modified - a.modified);
      channel.write(JSON.stringify({ type: 'list', id: query.id, rows: query.scope === 'all' ? rows : rows.filter((row: { cwd: string }) => row.cwd === sessionCwd) }) + '\n');
    }
  });
}
if (process.env.KOA_FAKE_KEEP_PIPES) spawn(process.execPath, ["-e", 'const socket = require("node:net").connect(process.env.KOA_FAKE_KEEP_PIPES); socket.on("data", () => socket.end());'], { stdio: ["ignore", process.stdout, process.stderr] }).unref();
if (process.env.KOA_FAKE_STUBBORN) process.on("SIGTERM", () => log({ type: "signal", signal: "SIGTERM" }));
let buffer = Buffer.alloc(0);
let commands = advance();
process.stdin.on("data", (chunk: Buffer) => {
  buffer = Buffer.concat([buffer, chunk]);
  let end: number;
  while ((end = buffer.indexOf(10)) >= 0) {
    const line = buffer.subarray(0, end).toString().replace(/\r$/, "");
    buffer = buffer.subarray(end + 1);
    commands = commands.then(() => command(JSON.parse(line))).catch(error => { process.stderr.write(String(error)); process.exitCode = 1; });
  }
});
process.stdin.on("end", () => {
  log({ type: "stdin_end" });
  if (process.env.KOA_FAKE_STUBBORN) setInterval(() => {}, 1000);
  else void commands.then(() => output).then(() => process.exit(0));
});
