import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import type { ImageContent } from "@earendil-works/pi-ai";
import type { AgentSession, AgentSessionRuntime, Args, ExtensionUIContext, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { components } from "./ko-api.d.ts";
import type { Sdk } from "./koa-sdk.ts";
import { agentExtension, createJobs, type Jobs, type JobSink } from "./koa-agent.ts";
import { sessionDir } from "./koa-session-dir.ts";
import type { AgentView } from "./koa-view.ts";
import { openInbox, type Inbox } from "./koa-inbox.ts";
import type { SessionRow, SessionScope } from "./koa-records.ts";
import type { AgentEnd, RestartState, InProcessMessage } from "./records.ts";
import type { AgentRow } from "./agents.ts";
import { errorText, cleanLine, utf8Prefix } from "./text.ts";
import { apiArgs, apiCall, findKo } from "./runtime-exec.ts";
import type { CompletionContext } from "./completion-context.ts";

type Api = components["schemas"];

export type Dialogs = Pick<ExtensionUIContext, "select" | "input" | "confirm" | "editor" | "notify" | "setStatus" | "setEditorText">;

function uiContext(sdk: Sdk, dialogs: Dialogs): ExtensionUIContext {
  const nothing = () => {};
  return {
    ...dialogs,
    onTerminalInput: () => nothing,
    setWorkingMessage: nothing, setWorkingVisible: nothing, setWorkingIndicator: nothing, setHiddenThinkingLabel: nothing,
    setWidget: nothing, setFooter: nothing, setHeader: nothing, setTitle: nothing, addAutocompleteProvider: nothing, setEditorComponent: nothing,
    setToolsExpanded: nothing,
    pasteToEditor: text => dialogs.setEditorText(text),
    custom: () => Promise.reject(new Error("custom components are not available in koa")),
    getEditorText: () => "",
    getEditorComponent: () => undefined,
    theme: sdk.theme,
    getAllThemes: () => [],
    getTheme: () => undefined,
    setTheme: () => ({ success: false, error: "Theme switching is not supported in koa" }),
    getToolsExpanded: () => false,
  };
}

type HostFacts = { pane: string | null; ko: string | null; insideKo: boolean; runtime: string | undefined };

export function hostFacts(env: NodeJS.ProcessEnv): HostFacts {
  const ko = findKo(env.PATH);
  return { pane: env.KO_PANE || null, ko, insideKo: !!env.KO_SOCKET && ko !== null, runtime: env.KO_RUNTIME || undefined };
}

const MAX_DEPTH = 2;

export type SpawnPlan = {
  id: string;
  name: string;
  cwd: string;
  model: string;
  runtime: string | undefined;
  trusted: string | undefined;
  mode: { kind: "fresh" } | { kind: "continue"; file: string } | { kind: "copy"; file: string };
};

export type Extension = JobSink & {
  completionContext(signal: AbortSignal): Promise<CompletionContext>;
  restartState(): RestartState;
  receive(message: InProcessMessage): Promise<void>;
  scope(maxAgeMs: number): Promise<AgentRow[]>;
  markWork(child: string): void;
  childState(child: string): { reported: boolean; text?: string };
  receiveReport(child: { session: string; name: string }, text: string): void;
  markEnded(child: string, cause: AgentEnd): void;
};

export type Agent = {
  readonly id: string;
  readonly parent: Agent | undefined;
  readonly children: Agent[];
  readonly view: AgentView;
  readonly host: AgentHost;
  readonly torn: WeakSet<AgentSession>;
  name: string;
  runtime: AgentSessionRuntime | undefined;
  readonly extension: Extension | undefined;
  stopping: boolean;
  unsubscribe: (() => void) | undefined;
  readonly session: AgentSession;
};

type Relationship = "own" | "peer" | "parent" | "relative";
type Scoped = { agent: Agent; relationship: Relationship };

export type Records = { active: boolean; write(report: Api["StatusReport"]): boolean; drain(): Promise<void> };

export type AgentHost = {
  readonly self: Agent;
  readonly facts: HostFacts;
  readonly browser: boolean;
  readonly trusted: string | undefined;
  readonly records: Records;
  readonly jobs: Jobs;
  extension: Extension | undefined;
  notify(message: string, level?: "info" | "warning" | "error"): void;
  scope(): Scoped[];
  find(id: string): Agent | undefined;
  spawn(plan: SpawnPlan): Promise<Agent | { error: string }>;
  stop(agent: Agent): Promise<void>;
  stopDescendants(): Promise<void>;
};

export type Tree = {
  readonly root: Agent;
  readonly records: Records;
  all(): Agent[];
  find(id: string): Agent | undefined;
  byRecord(id: string): Agent | undefined;
  selected(): Agent;
  select(agent: Agent): void;
  writeRecord(agent: Agent): void;
  retry(agent: Agent): Promise<void>;
  stop(agent: Agent, cause: AgentEnd): Promise<void>;
  restartState(): RestartState;
  dispose(): Promise<void>;
  openInbox(): void;
  freeze(): () => void;
  start(args: Args): Promise<void>;
  newSession(): Promise<{ cancelled: boolean }>;
  switchSession(file: string): Promise<{ cancelled: boolean }>;
  list(scope: SessionScope, signal: AbortSignal): Promise<SessionRow[]>;
};

type TreeOptions = {
  sdk: Sdk;
  args: Args;
  cwd: string;
  agentDir: string;
  browser: boolean;
  facts: HostFacts;
  makeView(agent: () => Agent, parent: Agent | undefined, name: string | undefined, cwd: string): AgentView;
  beforeStop(agent: Agent): void;
  changed(): void;
  select(agent: Agent | undefined, record: string): void;
  shutdown(): void;
};

async function sessionManagerFor(sdk: Sdk, parsed: Args, cwd: string, dir: string | undefined): Promise<SessionManager> {
  const { SessionManager } = sdk.pi;
  if (parsed.noSession) return SessionManager.inMemory(cwd, parsed.sessionId !== undefined ? { id: parsed.sessionId } : undefined);
  const find = async (arg: string) => {
    if (arg.includes("/") || arg.endsWith(".jsonl")) return resolve(cwd, arg);
    const rows = await SessionManager.list(cwd, dir);
    const row = rows.find(row => row.id === arg) ?? rows.find(row => row.id.startsWith(arg));
    if (!row) throw Error(`No session found matching '${arg}'`);
    return row.path;
  };
  if (parsed.fork) return SessionManager.forkFrom(await find(parsed.fork), cwd, dir, parsed.sessionId !== undefined ? { id: parsed.sessionId } : undefined);
  if (parsed.session) return SessionManager.open(await find(parsed.session), dir);
  if (parsed.continue) return SessionManager.continueRecent(cwd, dir);
  if (parsed.sessionId) {
    const existing = (await SessionManager.list(cwd, dir)).find(row => row.id === parsed.sessionId);
    if (existing) return SessionManager.open(existing.path, dir);
  }
  return SessionManager.create(cwd, dir, parsed.sessionId !== undefined ? { id: parsed.sessionId } : undefined);
}

let queuePatched = false;
function keepCustomMessagesOnClear(AgentSession: typeof import("@earendil-works/pi-coding-agent").AgentSession) {
  if (queuePatched) return;
  queuePatched = true;
  const isQueue = (queue: unknown): queue is { messages: AgentSession["messages"] } => typeof queue === "object" && queue !== null && "messages" in queue && Array.isArray(queue.messages);
  const clearQueue = AgentSession.prototype.clearQueue;
  // pi's core/agent-session.js clearQueue() discards custom messages alongside editor text.
  AgentSession.prototype.clearQueue = function () {
    const agent: object = this.agent;
    if (!("steeringQueue" in agent) || !("followUpQueue" in agent) || !isQueue(agent.steeringQueue) || !isQueue(agent.followUpQueue)) return clearQueue.call(this);
    const steering = agent.steeringQueue.messages.filter(message => message.role === "custom");
    const followUp = agent.followUpQueue.messages.filter(message => message.role === "custom");
    const cleared = clearQueue.call(this);
    for (const message of steering) this.agent.steer(message);
    for (const message of followUp) this.agent.followUp(message);
    return cleared;
  };
}

function childSessionDir(agentDir: string, cwd: string): string {
  // Copies pi's unexported getDefaultSessionDirPath in core/session-manager.js.
  return join(agentDir, "ko-subagents", `--${resolve(cwd).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`);
}

export function createRecords(facts: HostFacts): Records {
  let queue = Promise.resolve();
  const active = !!facts.pane && facts.insideKo;
  return {
    active,
    write(report) {
      if (!active) return false;
      const path = `/panes/${facts.pane}/status`;
      queue = queue.then(async () => { await apiCall("POST", path, report); }).catch(() => {});
      return true;
    },
    drain: () => queue,
  };
}

const recordPath = (agent: Agent): string => agent.parent ? `${recordPath(agent.parent)}${agent.parent.parent ? "/" : ""}agents/${agent.name}` : "";
const jobsPath = (agent: Agent): string => `${recordPath(agent)}${agent.parent ? "/" : ""}jobs`;

export function createTree(options: TreeOptions): Tree {
  const { sdk, facts } = options;
  let parsed = options.args;
  const { pi } = sdk;
  keepCustomMessagesOnClear(pi.AgentSession);
  if (parsed.offline || process.env.PI_OFFLINE) { process.env.PI_OFFLINE = "1"; process.env.PI_SKIP_VERSION_CHECK = "1"; }
  const { agentDir } = options;
  const dir = sessionDir(parsed, options.cwd);
  const records = createRecords(facts);
  let modelRuntimeCache: Awaited<ReturnType<typeof pi.ModelRuntime.create>> | undefined;
  const getModelRuntime = async () => modelRuntimeCache ??= await pi.ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json"), signal: AbortSignal.timeout(15_000) });
  const trustStore = new pi.ProjectTrustStore(agentDir);
  const trustByCwd = new Map<string, boolean>();
  const startupSettings: SettingsManager = pi.SettingsManager.create(options.cwd, agentDir, { projectTrusted: false });
  const paths = (values: string[] | undefined) => values?.map(value => sdk.isLocalPath(value) ? sdk.resolvePath(value, options.cwd) : value);
  const reserved = new Map<string, Agent>();
  const plans = new WeakMap<Agent, SpawnPlan>();
  let selected: Agent | undefined;
  let ended = false;
  let frozen: Promise<void> | undefined;
  let inbox: Inbox | undefined;
  let ready: () => void = () => {};
  const started = new Promise<void>(resolveStarted => { ready = resolveStarted; });
  const gate = async () => { await started; while (frozen) await frozen; };

  const all = (): Agent[] => {
    const walk = (agent: Agent): Agent[] => [agent, ...agent.children.flatMap(walk)];
    return root ? walk(root) : [];
  };
  const find = (id: string): Agent | undefined => all().find(agent => agent.runtime !== undefined && !agent.stopping && agent.id === id);
  const depth = (agent: Agent): number => agent.parent ? depth(agent.parent) + 1 : 0;
  const scopeOf = (self: Agent): Scoped[] => {
    const rows = new Map<Agent, Relationship>();
    const live = (agents: Agent[]) => agents.filter(agent => agent.runtime !== undefined && !agent.stopping);
    for (const child of live(self.children)) rows.set(child, "own");
    if (self.parent) for (const sibling of live(self.parent.children)) if (sibling !== self) rows.set(sibling, "peer");
    let ancestor = self.parent;
    for (let first = true; ancestor; first = false, ancestor = ancestor.parent) {
      rows.set(ancestor, first ? "parent" : "relative");
      if (ancestor.parent) for (const sibling of live(ancestor.parent.children)) if (!rows.has(sibling) && sibling !== self) rows.set(sibling, "relative");
    }
    return [...rows].map(([agent, relationship]) => ({ agent, relationship }));
  };

  const writeRecord = (agent: Agent): void => {
    if (!agent.parent || agent.stopping) return;
    const { view } = agent;
    const dialog = view.state.dialogs[0]?.title;
    const failed = view.life.type === "failed" ? view.life.message : undefined;
    const text = cleanLine(dialog ?? failed ?? view.root.message, 2048);
    const common = { type: "set" as const, id: recordPath(agent), title: utf8Prefix(agent.name, 192), selection: selected === agent ? "selected" as const : "offered" as const, closeable: true, ...(text ? { msg: text } : {}) };
    records.write(dialog ? { ...common, state: "blocked", kind: "question" } : { ...common, state: failed === undefined ? view.root.value : "error" });
  };
  const select = (agent: Agent): void => {
    const previous = selected;
    selected = agent;
    if (previous && previous !== agent) writeRecord(previous);
    writeRecord(agent);
  };

  const create = (agent: Agent, role: { kind: "root" } | { kind: "child"; plan: SpawnPlan }): Parameters<typeof pi.createAgentSessionRuntime>[0] => async ({ cwd, agentDir, sessionManager, sessionStartEvent, projectTrustContext }) => {
    const modelRuntime = await getModelRuntime();
    const diagnostics: { type: "info" | "warning" | "error"; message: string }[] = [];
    const cached = trustByCwd.get(cwd);
    const needsTrust = pi.hasTrustRequiringProjectResources(cwd);
    const override = role.kind === "root" ? parsed.projectTrustOverride : undefined;
    const resolveTrust = override === undefined && cached === undefined && needsTrust;
    const projectTrusted = resolveTrust ? false : cached ?? override ?? trustStore.get(cwd) ?? !needsTrust;
    const flags = role.kind === "root" ? parsed.unknownFlags : new Map<string, boolean | string>(role.plan.runtime ? [["runtime", role.plan.runtime]] : []);
    const extensionFactory = { name: "koa", hidden: true, factory: agentExtension(agent.host) };
    const services = await pi.createAgentSessionServices({
      cwd, agentDir, modelRuntime,
      settingsManager: pi.SettingsManager.create(cwd, agentDir, { projectTrusted }),
      extensionFlagValues: flags,
      resourceLoaderReloadOptions: resolveTrust ? {
        resolveProjectTrust: async ({ extensionsResult }: { extensionsResult: unknown }) => {
          const trusted = await sdk.resolveProjectTrusted({
            cwd, trustStore, trustOverride: override, defaultProjectTrust: startupSettings.getDefaultProjectTrust(), extensionsResult,
            projectTrustContext: projectTrustContext ?? sdk.createProjectTrustContext({ cwd, mode: "rpc", settingsManager: startupSettings, hasUI: false }),
            onExtensionError: (message: string) => diagnostics.push({ type: "warning", message }),
          });
          trustByCwd.set(cwd, trusted);
          return trusted;
        },
      } : undefined,
      resourceLoaderOptions: role.kind === "root" ? {
        additionalExtensionPaths: paths(parsed.extensions),
        additionalSkillPaths: paths(parsed.skills),
        additionalPromptTemplatePaths: paths(parsed.promptTemplates),
        noExtensions: parsed.noExtensions,
        disabledBuiltinExtensions: parsed.noMcp ? ["mcp"] : undefined,
        noSkills: parsed.noSkills, noPromptTemplates: parsed.noPromptTemplates, noContextFiles: parsed.noContextFiles,
        systemPrompt: parsed.systemPrompt, appendSystemPrompt: parsed.appendSystemPrompt,
        extensionFactories: [...sdk.builtInExtensions, extensionFactory],
      } : { extensionFactories: [...sdk.builtInExtensions, extensionFactory] },
    });
    const { settingsManager, resourceLoader } = services;
    diagnostics.push(...services.diagnostics, ...resourceLoader.getExtensions().errors.map(({ path, error }) => ({ type: "error" as const, message: `Failed to load extension "${path}": ${error}` })));
    let model: ReturnType<typeof modelRuntime.getModel>;
    let thinkingLevel = role.kind === "root" ? parsed.thinking : undefined;
    const modelArg = role.kind === "root" ? parsed.model : role.plan.model;
    if (modelArg) {
      const resolved = pi.resolveCliModel({ cliProvider: role.kind === "root" ? parsed.provider : undefined, cliModel: modelArg, cliThinking: thinkingLevel, inlineApiKey: role.kind === "root" && Boolean(parsed.apiKey), modelRuntime });
      if (resolved.error) throw Error(resolved.error);
      if (resolved.warning) diagnostics.push({ type: "warning", message: resolved.warning });
      model = resolved.model;
      if (!thinkingLevel && resolved.thinkingLevel) thinkingLevel = resolved.thinkingLevel;
    } else if (role.kind === "root" && parsed.provider) throw Error(`--provider requires --model (for example: --provider ${parsed.provider} --model <pattern>)`);
    if (role.kind === "root" && parsed.apiKey && model) await modelRuntime.setRuntimeApiKey(model.provider, parsed.apiKey);
    const patterns = role.kind === "root" ? parsed.models ?? settingsManager.getEnabledModels() : undefined;
    const scoped = patterns && patterns.length > 0 ? (await pi.resolveModelScopeWithDiagnostics(patterns, modelRuntime, { signal: AbortSignal.timeout(15_000) })).scopedModels : [];
    const created = await pi.createAgentSessionFromServices({
      services, sessionManager, sessionStartEvent, model, thinkingLevel,
      scopedModels: scoped.length > 0 ? scoped.map(entry => ({ model: entry.model, thinkingLevel: entry.thinkingLevel })) : undefined,
      ...(role.kind === "root" ? {
        tools: parsed.tools ? [...parsed.tools] : undefined,
        excludeTools: parsed.excludeTools ? [...parsed.excludeTools] : undefined,
        noTools: parsed.noTools ? "all" as const : parsed.noBuiltinTools ? "builtin" as const : undefined,
      } : {}),
    });
    if (role.kind === "root" && created.session.model && (parsed.thinking !== undefined || thinkingLevel !== undefined)) created.session.setThinkingLevel(created.session.thinkingLevel);
    for (const diagnostic of diagnostics) agent.view.hooks.notify(diagnostic.message, diagnostic.type);
    return { ...created, services, diagnostics };
  };

  const replace = async <T extends { cancelled: boolean }>(agent: Agent, kind: "new" | "resume" | "fork", run: () => Promise<T>): Promise<T> => {
    const before = agent.session;
    agent.view.hooks.replacing();
    try {
      const result = await run();
      agent.view.hooks.replaced(result.cancelled ? undefined : kind);
      return result;
    } catch (error) { agent.view.hooks.replaceFailed(error, agent.torn.has(before)); throw error; }
  };

  const bind = async (agent: Agent, session: AgentSession) => {
    const { view } = agent;
    agent.unsubscribe?.();
    view.hooks.rebind(session);
    agent.unsubscribe = session.subscribe(view.hooks.onEvent);
    const runtime = agent.runtime;
    if (!runtime) throw new Error("the agent has no runtime");
    const rootOnly = (what: string) => Promise.reject(new Error(`${what} is not available in a subagent`));
    await session.bindExtensions({
      uiContext: uiContext(sdk, view.hooks.ui),
      mode: "rpc",
      commandContextActions: {
        waitForIdle: () => session.agent.waitForIdle(),
        newSession: opts => agent.parent ? rootOnly("new session") : replace(agent, "new", () => runtime.newSession(opts)),
        fork: async (entryId, opts) => agent.parent ? rootOnly("fork") : { cancelled: (await replace(agent, "fork", () => runtime.fork(entryId, opts))).cancelled },
        navigateTree: async (targetId, opts) => {
          const result = await session.navigateTree(targetId, opts);
          if (!result.cancelled) view.hooks.treeNavigated(result.editorText);
          return { cancelled: result.cancelled };
        },
        switchSession: (file, opts) => agent.parent ? rootOnly("resume") : replace(agent, "resume", () => runtime.switchSession(file, opts)),
        reload: () => session.reload(),
      },
      shutdownHandler: () => { setImmediate(() => { if (agent.parent) void stop(agent, "stopped"); else view.hooks.shutdown(); }); },
      onError: error => view.hooks.notify(`extension ${error.extensionPath}: ${error.event}: ${error.error}`, "error"),
    });
  };

  const makeHost = (agent: () => Agent, trusted: string | undefined): AgentHost => {
    const host: AgentHost = {
      get self() { return agent(); },
      facts, browser: options.browser, trusted, records, jobs: createJobs({ records, path: () => jobsPath(agent()), sink: () => host.extension }), extension: undefined,
      notify: (message, level = "info") => agent().view.hooks.notify(message, level),
      scope: () => scopeOf(agent()),
      find,
      spawn: plan => spawn(agent(), plan),
      stop: target => stop(target, "stopped"),
      stopDescendants: () => stopDescendants(agent()),
    };
    return host;
  };

  const makeAgent = (parent: Agent | undefined, id: string | undefined, name: string, cwd: string, trusted: string | undefined): Agent => {
    const agent: Agent = {
      get id() { return agent.runtime?.session.sessionId ?? id ?? ""; },
      get session() { if (!agent.runtime) throw new Error("the agent is not started"); return agent.runtime.session; },
      parent, children: [], name, runtime: undefined, get extension() { return agent.host.extension; }, stopping: false, unsubscribe: undefined, torn: new WeakSet(),
      view: options.makeView(() => agent, parent, parent ? name : undefined, cwd),
      host: makeHost(() => agent, trusted),
    };
    return agent;
  };

  const instantiate = async (agent: Agent, sessionManager: SessionManager, role: Parameters<typeof create>[1]) => {
    const runtime = await pi.createAgentSessionRuntime(create(agent, role), { cwd: sessionManager.getCwd(), agentDir, sessionManager });
    agent.runtime = runtime;
    runtime.setRebindSession(session => bind(agent, session));
    runtime.setBeforeSessionInvalidate(() => agent.torn.add(runtime.session));
    return runtime;
  };

  const spawn = async (parent: Agent, plan: SpawnPlan): Promise<Agent | { error: string }> => {
    if (ended || parent.stopping) return { error: "this agent is stopping" };
    if (depth(parent) + 1 > MAX_DEPTH) return { error: `refusing to spawn at depth ${depth(parent) + 1}: maximum nesting is ${MAX_DEPTH} (root 0, subagent 1, subagent 2)` };
    if (all().some(agent => agent.id === plan.id) || reserved.has(plan.id)) return { error: `session ${plan.id} is live in this process` };
    const agent = makeAgent(parent, plan.id, plan.name, plan.cwd, plan.trusted);
    reserved.set(plan.id, agent);
    try {
      const { SessionManager } = pi;
      const sessionManager = plan.mode.kind === "continue" ? SessionManager.open(plan.mode.file)
        : plan.mode.kind === "copy" ? SessionManager.forkFrom(plan.mode.file, plan.cwd, childSessionDir(agentDir, plan.cwd), { id: plan.id })
        : SessionManager.create(plan.cwd, childSessionDir(agentDir, plan.cwd), { id: plan.id });
      sessionManager.appendCustomEntry("koa.edge", { owner: plan.id, at: Date.now(), parent: parent.id });
      await instantiate(agent, sessionManager, { kind: "child", plan });
    } catch (error) {
      reserved.delete(plan.id);
      agent.view.close();
      return { error: errorText(error) };
    }
    reserved.delete(plan.id);
    if (ended || parent.stopping) {
      await agent.runtime?.dispose().catch(() => {});
      agent.view.close();
      return { error: "this agent is stopping" };
    }
    plans.set(agent, plan);
    parent.children.push(agent);
    writeRecord(agent);
    options.changed();
    await attach(agent);
    return agent;
  };

  const attach = async (agent: Agent): Promise<void> => {
    try { await bind(agent, agent.session); agent.view.refresh(); }
    catch (error) { agent.view.fail(error); }
  };

  const retry = async (agent: Agent): Promise<void> => {
    const plan = plans.get(agent);
    if (!plan || !agent.parent || agent.stopping) throw new Error("this agent cannot start again");
    const { view } = agent;
    const file = agent.runtime?.session.sessionFile;
    const old = agent.runtime;
    agent.runtime = undefined;
    agent.unsubscribe?.(); agent.unsubscribe = undefined;
    await old?.dispose().catch(() => {});
    const gone = () => agent.stopping || !agent.parent?.children.includes(agent);
    if (gone()) return;
    view.life = { type: "starting" }; view.resetSession(); view.newSessionScope(); view.publish(true);
    try {
      const sessionManager = file ? pi.SessionManager.open(file) : pi.SessionManager.create(plan.cwd, childSessionDir(agentDir, plan.cwd), { id: plan.id });
      const made = await instantiate(agent, sessionManager, { kind: "child", plan });
      if (gone()) {
        agent.runtime = undefined;
        await made.dispose().catch(() => {});
        return;
      }
      await attach(agent);
    } catch (error) { view.fail(error); }
  };

  const stops = new WeakMap<Agent, Promise<void>>();
  const finishOne = async (agent: Agent, cause: AgentEnd): Promise<void> => {
    agent.view.cancelDialogs();
    const runtime = agent.runtime;
    try { await runtime?.dispose(); } catch (error) { process.stderr.write(`koa: ${errorText(error)}\n`); }
    agent.unsubscribe?.(); agent.unsubscribe = undefined;
    if (agent.parent) {
      const at = agent.parent.children.indexOf(agent);
      if (at >= 0) agent.parent.children.splice(at, 1);
      records.write({ type: "clear", id: recordPath(agent) });
      agent.parent.extension?.markEnded(agent.id, cause);
    }
    agent.view.close();
    options.changed();
  };
  const stopOne = (agent: Agent, cause: AgentEnd): Promise<void> => {
    const running = stops.get(agent) ?? finishOne(agent, cause);
    stops.set(agent, running);
    return running;
  };
  const marked = (agent: Agent): Agent[] => [...agent.children.flatMap(marked), agent];
  const stop = async (agent: Agent, cause: AgentEnd): Promise<void> => {
    if (!agent.parent) { agent.stopping = true; options.shutdown(); return; }
    if (agent.stopping) return;
    const subtree = marked(agent);
    for (const member of subtree) member.stopping = true;
    options.beforeStop(agent);
    for (const member of subtree) await stopOne(member, cause);
  };
  const stopDescendants = async (agent: Agent): Promise<void> => {
    for (const child of [...agent.children]) await stop(child, "stopped");
  };

  const root: Agent = makeAgent(undefined, undefined, "", options.cwd, undefined);
  const tree: Tree = {
    root, records, all, find, selected: () => selected ?? root, select, writeRecord, retry, stop,
    byRecord: id => all().find(agent => agent.parent && recordPath(agent) === id),
    openInbox: () => {
      if (!facts.pane || !facts.ko || !facts.insideKo) { ready(); return; }
      inbox = openInbox(facts.ko, facts.pane, {
        message: async (target, message) => {
          const agent = target === undefined ? root : find(target);
          if (!agent || agent.stopping || !agent.extension) return "refuse";
          await agent.extension.receive(message);
          return "ack";
        },
        select: record => options.select(record === "" ? root : tree.byRecord(record), record),
        close: record => {
          const agent = tree.byRecord(record);
          const parent = agent?.parent;
          if (!agent || !parent || agent.stopping) return;
          void stop(agent, "stopped").then(() => parent.extension?.receive({ kind: "notice", text: `the user stopped subagent @${agent.name}`, agent: { name: "the user" } })).catch(() => {});
        },
        stop: () => { setImmediate(options.shutdown); },
      }, gate);
      ready();
    },
    freeze: () => {
      let release: () => void = () => {};
      const mine = new Promise<void>(resolveFrozen => { release = resolveFrozen; });
      const previous = frozen;
      frozen = previous ? previous.then(() => mine) : mine;
      return () => { release(); if (frozen === mine) frozen = undefined; };
    },
    restartState: () => {
      let jobs = 0, children = 0;
      for (const agent of all()) {
        const state = agent.extension?.restartState();
        if (state?.type === "blocked") { jobs += state.jobs; children += state.children; }
      }
      return jobs || children ? { type: "blocked", jobs, children } : { type: "ready" };
    },
    async start(args) {
      parsed = args;
      if (root.runtime) { const old = root.runtime; root.runtime = undefined; await old.dispose().catch(() => {}); }
      await instantiateRoot();
      await bind(root, root.session);
    },
    newSession: () => replace(root, "new", () => root.runtime?.newSession() ?? Promise.reject(new Error("the agent is not started"))),
    switchSession: file => replace(root, "resume", () => root.runtime?.switchSession(file) ?? Promise.reject(new Error("the agent is not started"))),
    list: async (scope, signal) => {
      const cwd = root.session.sessionManager.getCwd();
      const rows = await (scope === "current" ? pi.SessionManager.list(cwd, dir, undefined, signal) : pi.SessionManager.listAll(dir, undefined, signal));
      return rows.map(row => ({ path: row.path, id: row.id, cwd: row.cwd, name: row.name, firstMessage: (row.firstMessage.split(/\r?\n/, 1)[0] ?? "").slice(0, 200), modified: row.modified.getTime(), messageCount: row.messageCount }));
    },
    async dispose() {
      ended = true;
      inbox?.close();
      for (const agent of all().reverse()) {
        agent.stopping = true;
        agent.view.cancelDialogs();
        try { await agent.runtime?.dispose(); } catch (error) { process.stderr.write(`koa: ${errorText(error)}\n`); }
      }
      await records.drain();
    },
  };
  const instantiateRoot = async () => {
    const sessionManager = await sessionManagerFor(sdk, parsed, options.cwd, dir);
    if (parsed.name !== undefined) {
      const name = parsed.name.trim();
      if (!name) throw Error("--name requires a non-empty value");
      sessionManager.appendSessionInfo(name);
    }
    await instantiate(root, sessionManager, { kind: "root" });
  };
  process.on("exit", () => {
    for (const agent of all()) agent.host.jobs.registry.exit();
    const ko = facts.ko;
    if (!facts.pane || !facts.insideKo || !ko) return;
    for (const id of ["jobs", "agents"]) {
      const report: Api["StatusReport"] = { type: "clear", id };
      spawnSync(ko, apiArgs("POST", `/panes/${facts.pane}/status`, report), { timeout: 1000, input: JSON.stringify(report), stdio: ["pipe", "ignore", "ignore"] });
    }
  });
  return tree;
}

export function submitPrompt(notify: (message: string, level: "info" | "warning" | "error") => void, session: AgentSession, message: string, options: { images?: ImageContent[]; streamingBehavior?: "steer" | "followUp" }): Promise<"started" | "queued" | "handled"> {
  return new Promise((resolve, reject) => {
    let accepted = false;
    session.prompt(message, { ...options, source: "rpc", preflightResult: disposition => { accepted = true; resolve(disposition); } })
      .catch(error => { if (accepted) notify(errorText(error), "error"); else reject(error); });
  });
}

export async function runBash(session: AgentSession, command: string, excludeFromContext: boolean, id: string) {
  const event = await session.extensionRunner.emitUserBash({ type: "user_bash", command, excludeFromContext, cwd: session.sessionManager.getCwd() });
  if (event?.result) { session.recordBashResult(command, event.result, { excludeFromContext }); return event.result; }
  return session.executeBash(command, undefined, { excludeFromContext, id, operations: event?.operations });
}

export function commandList(session: AgentSession) {
  return [
    ...session.extensionRunner.getRegisteredCommands().map(entry => ({ name: entry.invocationName, description: entry.description, source: "extension" as const })),
    ...session.promptTemplates.map(template => ({ name: template.name, description: template.description, source: "prompt" as const })),
    ...session.resourceLoader.getSkills().skills.map(skill => ({ name: `skill:${skill.name}`, description: skill.description, source: "skill" as const })),
  ];
}
