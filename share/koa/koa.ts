import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFile, writeFile } from "node:fs/promises";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { AgentSession, SlashCommandSource } from "@earendil-works/pi-coding-agent";
import { bashResult } from "./koa-transcript.ts";
import { later } from "./koa-timer.ts";
import { respond, readBody, wrongPostType } from "./koa-http.ts";
import { isRecord, errorText, cleanLine, replaceControlCharacters, utf8Prefix } from "./text.ts";
import { webview } from "../webview/index.ts";
import { assemblePage } from "./koa-assemble.ts";
import { complete, findFd } from "./koa-complete.ts";
import { pickSession, piPackage } from "./koa-child.ts";
import { loadSdk } from "./koa-sdk.ts";
import { restartArgs, startupResult } from "./koa-args.ts";
import { shellComplete } from "./koa-shell.ts";
import { attachments, stepFile, UPLOAD_IDLE_MS } from "./koa-attach.ts";
import { commandCatalog, parseCommand, dispatchCommand, deferralText, type Deferral } from './koa-commands.ts';
import { installedIdentity } from './koa-identity.ts';
import { bashCommand } from "./prompt.ts";
import { koaEditor } from "./koa-editor.ts";
import { findKo, apiArgs } from "./runtime-exec.ts";
import type { Agent, Tree } from "./koa-agents.ts";
import { createView, type AgentView, type Own } from "./koa-view.ts";
import { agentCompletionItems, type AgentRow } from "./agents.ts";
import { ATTACHMENT_LIMITS, type PromptMode, type PageRecord, type State, type ThinkingLevel, type Dialog, type CompletionCommand, type CompletionQuery, type SessionStats, type Bash } from "./koa-records.ts";

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
const QUIT_REPLY_MS = 1000;
const HOST_STOP_MS = 5000;

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
  const instance = randomUUID();
  const metrics = metricsFile ? metricsMode ?? "frame" : undefined;
  const page = reloadPage ? undefined : await assemblePage(location, instance, metrics);
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
    const fd = findFd(process.env.KOA_FD, agentDir, process.env.PATH ?? "");
    if (!fd) process.stderr.write("koa: fd not found; file completion is unavailable\n");
    const lifetime = new AbortController();
    teardown.push(() => lifetime.abort());
    let stopping = false;
    teardown.push(() => { stopping = true; });
    const background = (work: Promise<unknown>) => { void work.catch(error => { if (!stopping) process.stderr.write(`koa: ${errorText(error)}\n`); }); };
    const attached = attachments(join(dir, "attachments"), uploadIdleMs);
    teardown.push(() => attached.close());
    const root = () => tree.root;
    let editorOwner: Agent | undefined;
    const edits = koaEditor({
      agentDir, cwd: () => (editorOwner ?? tree.selected()).view.state.cwd, session: () => (editorOwner ?? tree.selected()).view.state.sessionId, name: () => (editorOwner ?? tree.selected()).view.state.name,
      replace: text => { const owner = editorOwner ?? tree.selected(); owner.view.state.editor = { id: randomUUID(), text }; owner.view.publish(); },
      notify: (text, level) => (editorOwner ?? tree.selected()).view.feed.notify(text, level), changed: () => (editorOwner ?? tree.selected()).view.publish(),
    });
    teardown.push(() => edits.cancel());
    const rootName = () => root().view.state.name;
    const nameOf = (agent: Agent) => agent.parent ? agent.name : rootName();
    const chain = (agent: Agent): Agent[] => agent.parent ? [...chain(agent.parent), agent] : [agent];
    const rowsOf = new WeakMap<Agent, AgentRow[]>();
    const selectable = (row: AgentRow) => row.state === "running" && !row.self && row.named && row.relationship !== "other";
    const ttl = Number(process.env.KO_AGENT_LIST_TTL_MS) || 1000;
    const refreshRows = (agent: Agent): void => background((async () => {
      const next = (await agent.extension?.scope(ttl) ?? []).filter(selectable);
      if (JSON.stringify(next) === JSON.stringify(rowsOf.get(agent) ?? [])) return;
      rowsOf.set(agent, next);
      agent.view.publish();
    })());
    const agentsFor = (agent: Agent): State["agents"] => (rowsOf.get(agent) ?? []).map(row => ({ name: row.name, target: row.where.type === "process" ? { type: "view" as const, id: row.id } : { type: "pane" as const, pane: row.where.pane } }));
    const compose = (agent: Agent) => (own: Own): State => ({
      ...own, ...(agent === tree.selected() ? { edit: edits.view() } : {}),
      view: { id: agent.id, path: chain(agent).map(member => ({ id: member.id, name: nameOf(member) })) },
      agents: agentsFor(agent),
    });
    const makeView = (agentRef: () => Agent, parent: Agent | undefined, name: string | undefined, cwd: string): AgentView => {
      const first = !parent;
      return createView({
        dir: join(dir, randomUUID()), metrics: metricsFile !== undefined, attached, name, cwd: first ? process.cwd() : cwd, home: homedir(),
        agent: () => { const agent = agentRef(); if (!agent.runtime) throw new Error("the agent is not started"); return { session: agent.runtime.session, runtime: agent.runtime }; },
        compose: own => compose(agentRef())(own),
        status: (value, message, dialog) => {
          const agent = agentRef();
          if (first) {
            const encoded = Buffer.from(cleanLine(dialog ?? message, 2048)).toString("base64");
            process.stdout.write(`\x1b]7501;state=${value === "clear" ? value : dialog ? "blocked" : value}${value === "clear" ? "" : `:app=pi${dialog ? ":kind=question" : ""}:msg=${encoded}`}\x1b\\`);
          } else {
            tree.writeRecord(agent);
          }
        },
        title: own => { if (first) process.stdout.write(`\x1b]0;${utf8Prefix(replaceControlCharacters(`koa - ${own.name} - ${basename(own.cwd)}`), 2048)}\x1b\\`); },
        closed: () => stopping,
        cancelEditor: () => { if (tree.selected() === agentRef()) void edits.cancel(); },
        shutdown: () => { if (first) background(quit()); },
        agentsChanged: () => refreshRows(agentRef()),
      });
    };
    const switchView = (next: Agent) => {
      const previous = tree.selected();
      if (next === previous || next.stopping || !next.runtime) return;
      void edits.cancel();
      tree.select(next);
      next.view.publish(true);
      refreshRows(next);
      next.view.feed.show(previous.view.feed);
    };
    const tree: Tree = koaAgents.createTree({
      sdk, args: sdk.pi.parseArgs(restartArgs(pass, undefined)), cwd: process.cwd(), agentDir, facts: koaAgents.hostFacts(process.env), browser, makeView,
      beforeStop: agent => { if (chain(tree.selected()).includes(agent)) switchView(agent.parent ?? root()); },
      changed: () => refreshRows(tree.selected()),
      select: (agent, record) => { if (agent && record !== undefined) switchView(agent); },
      shutdown: () => background(quit()),
    });
    teardown.push(() => { for (const agent of tree.all()) agent.view.close(); });
    stopHost = async () => { stopping = true; for (const agent of tree.all()) agent.view.cancelDialogs(); await tree.dispose(); };
    type Access = "ready" | "session" | "alive" | "dialog" | "failed" | "any";
    const ageError = (agent: Agent) => agent.view.life.type === "starting" ? "pi is starting" : "pi is not ready";
    const checkSession = (agent: Agent, id: unknown) => { if (id !== agent.view.state.sessionId) throw new Error("pi session changed"); };
    const access = (agent: Agent, mode: Access, sessionId?: unknown) => {
      const { life } = agent.view;
      const running = agent.view.running() && !agent.stopping;
      switch (mode) {
        case "dialog":
          checkSession(agent, sessionId);
          if (stopping || agent.stopping || life.type === "failed") throw new Error("pi is not running");
          break;
        case "session": case "ready": checkSession(agent, sessionId); if (!running) throw new Error(ageError(agent)); break;
        case "alive": checkSession(agent, sessionId); if (stopping || agent.stopping || life.type === "failed" || life.type === "switching" || life.type === "reloading") throw new Error("pi is not running"); break;
        case "failed": checkSession(agent, sessionId); if (stopping || life.type !== "failed") throw new Error("the agent is already running"); break;
        case "any": checkSession(agent, sessionId); break;
        default: { const unexpected: never = mode; throw new Error(unexpected); }
      }
    };
    const isRoot = (agent: Agent) => agent === root();
    const rootOnly = (agent: Agent, command: string): boolean => {
      if (isRoot(agent)) return false;
      agent.view.hooks.notify(`/${command}: only in @${rootName()}'s view`, "warning");
      return true;
    };
    const restartKoa = (response: ServerResponse) => {
      response.setHeader("Connection", "close");
      const restart = () => {
        if (reloading) return;
        reloading = true;
        void shutdown().then(() => Promise.all([process.stdout, process.stderr].map(stream => new Promise<void>(resolve => { const timer = later(resolve, QUIT_REPLY_MS); stream.write("", () => { clearTimeout(timer); resolve(); }); })))).then(() => { if (!process.execve) throw Error("this node has no process.execve"); process.execve(process.execPath, [process.execPath, ...process.execArgv, process.argv[1] ?? "", ...own, ...restartArgs(pass, root().view.state.sessionFile)], { ...process.env, KOA_RELOAD: "1" }); }).catch(error => { process.stderr.write(`koa: reload: ${errorText(error)}\n`); process.exitCode = 1; });
      };
      const timer = later(restart, QUIT_REPLY_MS);
      response.once("finish", () => { clearTimeout(timer); restart(); });
      respond(response, 200, JSON.stringify({ disposition: "handled", action: { type: "reload" } }));
    };
    const reloadBusy = () => tree.all().some(agent => agent.view.reloadBusy()) || edits.busy();
    const deferred = (): Deferral | undefined => {
      const restart = tree.restartState();
      return restart.type === "blocked" ? restart.jobs ? { type: "jobs", count: restart.jobs } : { type: "children", count: restart.children } : !root().view.state.sessionFile ? { type: "no_session" } : undefined;
    };
    const startRoot = async () => {
      const v = root().view;
      v.life = { type: "starting" }; v.resetSession(); v.newSessionScope(); v.publish(true);
      try {
        await tree.start(sdk.pi.parseArgs(restartArgs(pass, v.state.sessionFile)));
        v.refresh();
        tree.select(root());
        refreshRows(root());
        if (!started) { started = true; tree.openInbox(); }
        return true;
      } catch (error) { v.fail(error); return false; }
    };
    let started = false;
    const reload = async (agent: Agent, response: ServerResponse) => {
      const release = tree.freeze();
      const agents = tree.all();
      for (const member of agents) { member.view.cancelDialogs(); member.view.newSessionScope(); member.view.begin(); member.view.state.statuses = {}; }
      const v = root().view;
      v.life = { type: "reloading" }; v.publish();
      let failure: unknown;
      try {
        for (const member of agents) {
          if (!member.runtime || member.stopping) continue;
          await member.session.reload();
          member.view.refresh();
        }
      } catch (error) { failure = error ?? Error("reload failed"); }
      finally { release(); }
      if (v.life.type === "reloading") { v.life = { type: "ready" }; v.publish(); }
      for (const member of agents) member.view.replaySwitching();
      const answer = () => respond(response, 200, JSON.stringify({ disposition: "handled", action: { type: "none" } }));
      const feed = agent.view.feed;
      if (failure !== undefined) { feed.notify(errorText(failure), "error"); answer(); return; }
      const now = await installedIdentity(location).catch(() => undefined);
      if (identity === undefined || now === undefined || now === identity) { feed.notify("reloaded", "info"); answer(); return; }
      const deferral = deferred();
      if (deferral) feed.notify(deferralText(deferral), "info");
      else if (reloadBusy()) feed.notify("reloaded", "info");
      else { restartKoa(response); return; }
      answer();
    };
    const owned = (agent: Agent, owner: AgentSession) => { if (agent.session !== owner || agent.torn.has(owner) || tree.selected() !== agent) throw new Error("pi session changed"); };
    const queuePrompt = async (agent: Agent, session: AgentSession, text: string, requested: PromptMode | "steer", files: Awaited<ReturnType<AgentView["attached"]["prepare"]>>) => {
      const v = agent.view;
      const message = [text, ...files.paths].filter(Boolean).join("\n");
      const mode = v.state.working ? requested === "follow_up" ? "followUp" : "steer" : "prompt";
      const entry = v.prompts.add(message, mode, files.files);
      try {
        const disposition = await koaAgents.submitPrompt(v.hooks.notify, session, message, { ...(files.images.length ? { images: files.images } : {}), ...(mode !== "prompt" ? { streamingBehavior: mode } : {}) });
        return { entry, disposition };
      } catch (error) { v.prompts.reject(entry); throw error; }
    };
    const routes: Record<string, { method: "GET" | "POST"; access: Access; handle(value: unknown, response: ServerResponse, agent: Agent): void | Promise<void> }> = {
      "/view": { method: "POST", access: "any", handle: (value, response) => {
        const id = idBody(value);
        if ("error" in id) { respond(response, 400, JSON.stringify(id)); return; }
        const next = tree.find(id.id);
        if (!next) { respond(response, 409, JSON.stringify({ error: "that agent is not running" })); return; }
        switchView(next);
        respond(response, 200, "{}");
      } },
      "/complete": { method: "POST", access: "alive", handle: async (value, response, agent) => {
        const query = completeBody(value);
        if ("error" in query) { respond(response, 400, JSON.stringify(query)); return; }
        const v = agent.view;
        await withRequestSignal(response, lifetime.signal, async requestSignal => {
          const bang = bashCommand(query.text), owner = agent.session, ownerSession = v.state.sessionId;
          const signal = AbortSignal.any([requestSignal, v.sessionStop, ...(bang ? [AbortSignal.timeout(2000)] : [])]);
          const result = bang ? await shellComplete(query.text, query.pos, await (agent.extension?.completionContext(signal) ?? Promise.resolve({ type: 'unavailable' as const })), 'ko', signal, bang) : await complete(query.text, query.pos, { cwd: v.state.cwd, fd, signal, agents: token => agentCompletionItems(rowsOf.get(agent) ?? [], rowsOf.get(agent) ?? [], token), commands: async () => {
            if (v.life.type !== "ready") return [];
            return [...completion, ...koaAgents.commandList(agent.session).filter(value => !catalog.some(builtin => builtin.name === value.name))];
          } });
          if (!requestSignal.aborted) respond(response, signal.aborted || owner !== agent.session || ownerSession !== v.state.sessionId || tree.selected() !== agent ? 409 : 200, JSON.stringify(result));
        });
      } },
      "/sessions/list": { method: "POST", access: "ready", handle: async (value, response, agent) => {
        if (!isRecord(value) || (value.scope !== "current" && value.scope !== "all")) { respond(response, 400, "{}"); return; }
        if (!isRoot(agent)) { respond(response, 409, JSON.stringify({ error: `/resume: only in @${rootName()}'s view` })); return; }
        const scope = value.scope;
        await withRequestSignal(response, lifetime.signal, async signal => {
          const rows = await tree.list(scope, signal);
          if (!signal.aborted) respond(response, 200, JSON.stringify({ rows }));
        });
      } },
      "/sessions/switch": { method: "POST", access: "session", handle: (value, response, agent) => {
        if (!isRecord(value) || typeof value.path !== "string" || !value.path) { respond(response, 400, "{}"); return; }
        if (!isRoot(agent)) { respond(response, 409, JSON.stringify({ error: `/resume: only in @${rootName()}'s view` })); return; }
        return switchSession(value.path, response);
      } },
      "/sessions/new": { method: "POST", access: "session", handle: (_value, response, agent) => {
        if (!isRoot(agent)) { respond(response, 409, JSON.stringify({ error: `/new: only in @${rootName()}'s view` })); return; }
        return switchSession(undefined, response);
      } },
      "/models": { method: "GET", access: "ready", handle: (_value, response, agent) => respond(response, 200, JSON.stringify({ models: agent.session.modelRuntime.getAvailableSnapshot() })) },
      "/prompt": { method: "POST", access: "session", handle: async (value, response, agent) => {
        const v = agent.view;
        const builtin = isRecord(value) && typeof value.text === 'string' ? parseCommand(value.text, catalog) : undefined;
        const prompt = promptBody(builtin && isRecord(value) ? { ...value, attachments: [] } : value);
        if ("error" in prompt) { respond(response, 400, JSON.stringify(prompt)); return; }
        const bash = bashCommand(prompt.text);
        if (bash) {
          const refusal = prompt.attachments.length ? 'a command takes no attachments' : v.state.bash.some(item => item.phase !== 'completed') ? 'a command is already running' : v.state.bash.length >= MAX_PENDING_BASH ? 'too many commands wait for the turn to end' : !bash.command.trim() ? 'a command is required' : undefined;
          if (refusal) { respond(response, 409, JSON.stringify({ error: refusal })); return; }
          const { command: shellCommand, excludeFromContext } = bash;
          const owner = agent.session, ownerSession = v.state.sessionId;
          let running: (Bash & { phase: 'running' | 'cancelling' }) | undefined;
          v.background((async () => {
            try {
              const id = v.nextBash();
              running = { id, command: shellCommand, excludeFromContext, phase: 'running', started: Date.now(), output: { text: '', cut: 0 } };
              v.state.bash.push(running); v.publish();
              const result = await koaAgents.runBash(owner, shellCommand, excludeFromContext, id);
              if (owner !== agent.session || ownerSession !== v.state.sessionId || !running || !v.state.bash.includes(running)) return;
              const completed: Bash = { id: running.id, command: shellCommand, excludeFromContext, phase: 'completed', started: running.started, ended: Date.now(), result: bashResult(result) };
              v.state.bash = v.state.bash.map(item => item === running ? completed : item);
              v.clearBashTimer(); v.publish();
              v.settleBash();
            } catch (error) {
              if (running && v.state.bash.includes(running)) { v.state.bash = v.state.bash.filter(item => item !== running); v.publish(); v.feed.notify(errorText(error), 'error'); }
              else if (owner === agent.session && ownerSession === v.state.sessionId) throw error;
            }
          })());
          respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return;
        }
        if (builtin) {
          if (["new", "resume", "reload", "restart", "quit"].includes(builtin.command.name) && rootOnly(agent, builtin.command.name)) { respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return; }
          const action = await dispatchCommand(builtin, {
            packageRoot, session: agent.session, notify: v.feed.notify, outcome: v.feed.command,
            stats: () => v.feed.command({ type: 'session', stats: agent.session.getSessionStats(), name: v.state.name, model: v.state.model, thinking: v.state.thinking }),
            thinking: async level => {
              const parsed = thinkingBody({ level: level.toLowerCase() }, v.state.levels);
              if ('error' in parsed) { v.feed.notify(`Unknown thinking level: ${level}`, 'warning'); return; }
              agent.session.setThinkingLevel(parsed.level); v.announce();
            },
            setModel: async model => { await v.setModel(model); v.announce(); },
            compact: instructions => {
              if (v.compaction || v.compactRequest && !v.compactRequest.ended) return;
              const request = { ended: false }; v.compactRequest = request;
              v.background(agent.session.compact(instructions).catch(error => { if (!request.ended) v.finishCompaction({ type: 'failed', message: errorText(error) }); }).finally(() => { if (v.compactRequest === request) v.compactRequest = undefined; }));
            },
            reloadBusy: () => !!reloadBusy(),
          });
          if (action.type === 'quit') { await routes['/quit']?.handle({}, response, agent); return; }
          if (action.type === 'reload') { await reload(agent, response); return; }
          if (action.type === 'restart') { restartKoa(response); return; }
          respond(response, 200, JSON.stringify({ disposition: 'handled', action })); return;
        }
        const owner = agent.session;
        const files = await v.attached.prepare(prompt.attachments);
        const { entry, disposition } = await v.serial(async () => { owned(agent, owner); return queuePrompt(agent, owner, prompt.text, prompt.mode, files); });
        if (disposition === 'handled') { v.prompts.reject(entry); respond(response, 200, JSON.stringify({ disposition: 'handled', action: { type: 'none' } })); return; }
        v.attached.consume(prompt.attachments, disposition === "queued" ? "queued" : "used");
        respond(response, 200, JSON.stringify({ disposition }));
      } },
      "/abort": { method: "POST", access: "session", handle: (_value, response, agent) => {
        const v = agent.view;
        const running = v.state.bash.find(item => item.phase === 'running');
        if (running) { running.phase = 'cancelling'; v.publish(); }
        if (running) agent.session.abortBash(); else return agent.session.abort().then(() => respond(response, 200, "{}"));
        respond(response, 200, "{}");
      } },
      "/queue/clear": { method: "POST", access: "session", handle: (_value, response, agent) => { const v = agent.view, owner = agent.session; return v.serial(async () => {
        owned(agent, owner);
        v.prompts.beginClear();
        try {
          const restored = v.prompts.takeBack(owner.clearQueue());
          v.attached.restore([...restored.steering, ...restored.followUp].flatMap(entry => entry.attachments.map(file => file.id)));
          v.publish(); respond(response, 200, JSON.stringify(restored));
        } finally { v.prompts.endClear(); }
      }); } },
      "/queue/remove": { method: "POST", access: "session", handle: (value, response, agent) => { const v = agent.view, owner = agent.session; return v.serial(async () => {
        owned(agent, owner);
        if (!isRecord(value) || value.kind !== "steer" && value.kind !== "follow-up" || typeof value.index !== "number" || !Number.isSafeInteger(value.index) || value.index < 0 || typeof value.text !== "string") { respond(response, 400, JSON.stringify({ error: "A queue kind, index and text are required" })); return; }
        const { kind, index, text } = value;
        const shown = v.prompts.view();
        if ((kind === "steer" ? shown.steering : shown.followUp)[index]?.text !== text) { respond(response, 409, JSON.stringify({ error: "The queue changed" })); return; }
        v.prompts.beginClear();
        try {
          const restored = v.prompts.takeBack(owner.clearQueue());
          const all = [...restored.steering.map(entry => ({ entry, behavior: "steer" as const })), ...restored.followUp.map(entry => ({ entry, behavior: "follow_up" as const }))];
          v.attached.restore(all.flatMap(({ entry }) => entry.attachments.map(file => file.id)));
          const list = kind === "steer" ? restored.steering : restored.followUp;
          const stale = list[index]?.text !== text;
          const keep = all.filter(({ entry }) => stale || entry !== list[index]);
          for (const [done, { entry, behavior }] of keep.entries()) {
            const ids = entry.attachments.map(file => file.id);
            let failure: string | undefined;
            try {
              owned(agent, owner);
              const sent = await queuePrompt(agent, owner, entry.text, behavior, await v.attached.prepare(ids));
              if (sent.disposition === "handled") v.prompts.reject(sent.entry); else v.attached.consume(ids, "queued");
            } catch (error) { failure = errorText(error); }
            if (failure !== undefined) {
              const unsent = keep.slice(done);
              v.publish();
              respond(response, 409, JSON.stringify({ error: failure, unsent: { steering: unsent.filter(item => item.behavior === "steer").map(item => item.entry), followUp: unsent.filter(item => item.behavior === "follow_up").map(item => item.entry) } }));
              return;
            }
          }
          v.publish();
          respond(response, stale ? 409 : 200, JSON.stringify(stale ? { error: "The queue changed" } : {}));
        } finally { v.prompts.endClear(); }
      }); } },
      "/model": { method: "POST", access: "session", handle: (value, response, agent) => {
        const model = modelBody(value);
        if ("error" in model) throw new Error(model.error);
        const found = agent.session.modelRuntime.getAvailableSnapshot().find(entry => entry.provider === model.provider && entry.id === model.modelId);
        if (!found) throw new Error(`Model not found: ${model.provider}/${model.modelId}`);
        return agent.view.setModel(found).then(() => respond(response, 200, JSON.stringify(found)));
      } },
      "/thinking": { method: "POST", access: "session", handle: (value, response, agent) => {
        const thinking = thinkingBody(value, agent.view.state.levels);
        if ("error" in thinking) throw new Error(thinking.error);
        agent.session.setThinkingLevel(thinking.level);
        respond(response, 200, "{}");
      } },
      "/dialog": { method: "POST", access: "dialog", handle: async (value, response, agent) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        const dialog = agent.view.state.dialogs.find(dialog => dialog.id === id.id);
        if (!dialog) throw new Error("Dialog is not open");
        const answer = dialogBody(value, dialog);
        if ("error" in answer) throw new Error(answer.error);
        agent.view.removeDialog(dialog.id, answer); respond(response, 200, "{}");
      } },
      "/editor/open": { method: "POST", access: "session", handle: async (value, response, agent) => {
        if (!isRecord(value) || typeof value.text !== "string") { respond(response, 400, JSON.stringify({ error: "A draft text is required" })); return; }
        editorOwner = agent;
        const result = await edits.open(value.text);
        respond(response, "error" in result ? 409 : 200, JSON.stringify(result));
      } },
      "/editor/ack": { method: "POST", access: "session", handle: (value, response, agent) => {
        const id = idBody(value);
        if ("error" in id) throw new Error(id.error);
        if (agent.view.state.editor?.id === id.id) { delete agent.view.state.editor; agent.view.publish(); }
        respond(response, 200, "{}");
      } },
      "/agent/start": { method: "POST", access: "failed", handle: async (_value, response, agent) => {
        if (isRoot(agent)) await startRoot(); else await tree.retry(agent);
        respond(response, 200, "{}");
      } },
      "/quit": { method: "POST", access: "any", handle: (_value, response, agent) => {
        if (!isRoot(agent)) { respond(response, 409, JSON.stringify({ error: `/quit: only in @${rootName()}'s view` })); return; }
        response.setHeader("Connection", "close");
        const timer = later(() => background(quit()), QUIT_REPLY_MS);
        response.once("finish", () => { clearTimeout(timer); background(quit()); });
        respond(response, 200, "{}");
      } },
    };
    const switchSession = async (file: string | undefined, response: ServerResponse) => {
      try { respond(response, 200, JSON.stringify(await (file ? tree.switchSession(file) : tree.newSession()))); }
      catch (error) { if (root().view.life.type !== "failed") throw error; respond(response, 409, JSON.stringify({ error: errorText(error) })); }
    };
    const handle = async (request: IncomingMessage, response: ServerResponse) => {
      try {
        if (wrongPostType(request)) { respond(response, 415, "{}"); return; }
        const url = new URL(request.url ?? "/", "http://koa");
        if (metricsFile && request.method === "POST" && url.pathname === "/metrics") {
          const bytes = await readBody(request, 1 << 20);
          if (!bytes) { respond(response, 413, "{}"); return; }
          let samples: unknown;
          try { samples = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, "{}"); return; }
          if (!Array.isArray(samples) || samples.length > 50 || !samples.every(sample => sample && typeof sample === "object" && Number.isFinite(sample.t) && (Number.isFinite(sample.frame) || Number.isFinite(sample.applied)) && Number.isFinite(sample.clockError) && Number.isSafeInteger(sample.bytes) && sample.bytes >= 0)) { respond(response, 400, "{}"); return; }
          const line = JSON.stringify({ type: "metrics", at: Date.now(), samples, ...tree.selected().view.feed.metrics }) + "\n";
          const file = metricsFile;
          const write = (metricsWrites ?? Promise.resolve()).then(() => appendFile(file, line));
          metricsWrites = write.catch(() => {});
          try { await write; } catch (error) { respond(response, 500, JSON.stringify({ error: errorText(error) })); return; }
          respond(response, 200, "{}"); return;
        }
        if (request.method === "GET") {
          const stale = url.pathname === "/events" && url.searchParams.has("koa") && url.searchParams.get("koa") !== instance;
          if (stale) { const record: PageRecord = { type: "reload" }; respond(response, 200, `data: ${JSON.stringify(record)}\n\n`, "text/event-stream"); return; }
        }
        if (await attached.handle(request, response, () => { if (stopping) throw new Error("koa is stopping"); })) return;
        const agent = tree.selected(), entrySession = agent.view.state.sessionId;
        const accessScoped = () => access(agent, "alive", url.searchParams.get("sessionId") ?? undefined);
        if (await stepFile(request, response, agent.view.feed.itemFile, agent.view.state.cwd, agent.view.state.home, accessScoped)) return;
        if (request.method === "GET" && ["/images/", "/history", "/items"].some(path => url.pathname.startsWith(path))) access(agent, "any", url.searchParams.get("sessionId") ?? undefined);
        if (agent.view.feed.handle(request, response)) return;
        if (request.method === "GET" && url.pathname === "/") {
          try {
            const html = page ?? await assemblePage(location, instance, metrics);
            respond(response, 200, html, "text/html; charset=utf-8");
          } catch (error) { respond(response, 500, errorText(error), "text/plain; charset=utf-8"); }
          return;
        }
        const route = routes[url.pathname];
        if (!route || route.method !== request.method) { respond(response, 404, "{}"); return; }
        let value: unknown;
        if (request.method === "POST") {
          const bytes = await readBody(request, 1 << 20);
          if (bytes === undefined) { respond(response, 413, "{}"); return; }
          try { value = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, JSON.stringify({ error: "A JSON body is required" })); return; }
        } else value = { sessionId: url.searchParams.get("sessionId") ?? undefined };
        if (tree.selected() !== agent || agent.view.state.sessionId !== entrySession) throw new Error("pi session changed");
        access(agent, route.access, isRecord(value) ? value.sessionId : undefined);
        await route.handle(value, response, agent);
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
      root().view.status("idle", rootName());
      background((async () => {
        if (!await startRoot()) return;
        if (reloaded) root().view.feed.notify("reloaded", "info");
        const messages = initialMessages; initialMessages = [];
        for (const message of messages) {
          const v = root().view;
          if (!v.running()) break;
          const done = v.settleWait();
          if (await koaAgents.submitPrompt(v.hooks.notify, root().session, message, {}) === 'handled') v.clearSettleWait();
          else await done;
        }
      })());
    }
    root().view.title();
    const show = (supported: boolean) => { if (stopping) return; if (supported) background(view.show()); else process.stdout.write("koa: this client does not show webviews; the page is still served\n"); };
    view.on("supported", show); show(view.supported);
    if (view.url) process.stderr.write(`koa: ${view.url}\n`);
  };
  try { await start(); } catch (error) { await shutdown(); throw error; }
}

main().catch(error => { process.stderr.write(`koa: ${errorText(error)}\n`); process.exitCode = 1; });
