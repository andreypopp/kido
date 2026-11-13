import { join, resolve } from "node:path";
import type { ImageContent } from "@earendil-works/pi-ai";
import type { AgentSession, AgentSessionEvent, AgentSessionRuntime, Args, ExtensionUIContext, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Sdk } from "./koa-sdk.ts";
import { agentExtension, type Slots, type Extension } from "./koa-agent.ts";
import { sessionDir } from "./koa-session-dir.ts";
import type { SessionRow, SessionScope } from "./koa-records.ts";
import { errorText } from "./text.ts";
import { findKo } from "./runtime-exec.ts";

export type Dialogs = Pick<ExtensionUIContext, "select" | "input" | "confirm" | "editor" | "notify" | "setStatus" | "setEditorText">;

export function uiContext(sdk: Sdk, dialogs: Dialogs): ExtensionUIContext {
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

type HostOptions = {
  sdk: Sdk;
  args: Args;
  cwd: string;
  agentDir: string;
  browser: boolean;
  facts: HostFacts;
  ui: ExtensionUIContext;
  onEvent(event: AgentSessionEvent): void;
  rebind(session: AgentSession): void;
  replacing(): void;
  replaced(kind: "new" | "resume" | "fork" | undefined): void;
  replaceFailed(error: unknown, torn: boolean): void;
  treeNavigated(editorText: string | undefined): void;
  notify(message: string, level: "info" | "warning" | "error"): void;
  shutdown(): void;
};

type HostFacts = { pane: string | null; ko: string | null; insideKo: boolean; runtime: string | undefined; trustedCwd: string | undefined; session: string | undefined; parent: string | undefined };

export function hostFacts(env: NodeJS.ProcessEnv): HostFacts {
  const ko = findKo(env.PATH);
  return { pane: env.KO_PANE || null, ko, insideKo: !!env.KO_SOCKET && ko !== null, runtime: env.KO_RUNTIME || undefined, trustedCwd: env.KO_AGENT_TRUSTED_CWD || undefined, session: env.KO_AGENT_SESSION || undefined, parent: env.KO_AGENT_PARENT_SESSION || undefined };
}

export type AgentHost = {
  readonly facts: HostFacts;
  readonly runtime: AgentSessionRuntime;
  readonly session: AgentSession;
  readonly slots: Slots;
  readonly browser: boolean;
  notify(message: string, level?: "info" | "warning" | "error"): void;
  extension: Extension | undefined;
  start(): Promise<void>;
  newSession(): Promise<{ cancelled: boolean }>;
  switchSession(file: string): Promise<{ cancelled: boolean }>;
  usable(session: AgentSession): boolean;
  list(scope: SessionScope, signal: AbortSignal): Promise<SessionRow[]>;
  dispose(): Promise<void>;
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

export async function createRootHost(options: HostOptions): Promise<AgentHost> {
  const { sdk, args: parsed } = options;
  const { pi } = sdk;
  keepCustomMessagesOnClear(pi.AgentSession);
  if (parsed.offline || process.env.PI_OFFLINE) { process.env.PI_OFFLINE = "1"; process.env.PI_SKIP_VERSION_CHECK = "1"; }
  const { agentDir } = options;
  const dir = sessionDir(parsed, options.cwd);
  const sessionManager = await sessionManagerFor(sdk, parsed, options.cwd, dir);
  if (parsed.name !== undefined) {
    const name = parsed.name.trim();
    if (!name) throw Error("--name requires a non-empty value");
    sessionManager.appendSessionInfo(name);
  }
  const modelRuntime = await pi.ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json"), signal: AbortSignal.timeout(15_000) });
  const trustStore = new pi.ProjectTrustStore(agentDir);
  const trustByCwd = new Map<string, boolean>();
  const startupSettings: SettingsManager = pi.SettingsManager.create(sessionManager.getCwd(), agentDir, { projectTrusted: false });
  const paths = (values: string[] | undefined) => values?.map(value => sdk.isLocalPath(value) ? sdk.resolvePath(value, options.cwd) : value);
  const host: AgentHost = {
    get runtime() { return runtime; },
    get session() { return runtime.session; },
    slots: {},
    browser: options.browser,
    facts: options.facts,
    extension: undefined,
    list: async (scope, signal) => {
      const cwd = runtime.session.sessionManager.getCwd();
      const rows = await (scope === "current" ? pi.SessionManager.list(cwd, dir, undefined, signal) : pi.SessionManager.listAll(dir, undefined, signal));
      return rows.map(row => ({ path: row.path, id: row.id, cwd: row.cwd, name: row.name, firstMessage: (row.firstMessage.split(/\r?\n/, 1)[0] ?? "").slice(0, 200), modified: row.modified.getTime(), messageCount: row.messageCount }));
    },
    start: () => bind(runtime.session),
    newSession: () => replace("new", () => runtime.newSession()),
    switchSession: file => replace("resume", () => runtime.switchSession(file)),
    usable: session => !torn.has(session),
    notify: options.notify,
    dispose: () => runtime.dispose(),
  };
  const torn = new WeakSet<AgentSession>();
  const factory = agentExtension(host);
  const create: Parameters<typeof pi.createAgentSessionRuntime>[0] = async ({ cwd, agentDir, sessionManager, sessionStartEvent, projectTrustContext }) => {
    const diagnostics: { type: "info" | "warning" | "error"; message: string }[] = [];
    const cached = trustByCwd.get(cwd);
    const needsTrust = pi.hasTrustRequiringProjectResources(cwd);
    const resolveTrust = parsed.projectTrustOverride === undefined && cached === undefined && needsTrust;
    const projectTrusted = resolveTrust ? false : cached ?? parsed.projectTrustOverride ?? trustStore.get(cwd) ?? !needsTrust;
    const services = await pi.createAgentSessionServices({
      cwd, agentDir, modelRuntime,
      settingsManager: pi.SettingsManager.create(cwd, agentDir, { projectTrusted }),
      extensionFlagValues: parsed.unknownFlags,
      resourceLoaderReloadOptions: resolveTrust ? {
        resolveProjectTrust: async ({ extensionsResult }: { extensionsResult: unknown }) => {
          const trusted = await sdk.resolveProjectTrusted({
            cwd, trustStore, trustOverride: parsed.projectTrustOverride, defaultProjectTrust: startupSettings.getDefaultProjectTrust(), extensionsResult,
            projectTrustContext: projectTrustContext ?? sdk.createProjectTrustContext({ cwd, mode: "rpc", settingsManager: startupSettings, hasUI: false }),
            onExtensionError: (message: string) => diagnostics.push({ type: "warning", message }),
          });
          trustByCwd.set(cwd, trusted);
          return trusted;
        },
      } : undefined,
      resourceLoaderOptions: {
        additionalExtensionPaths: paths(parsed.extensions),
        additionalSkillPaths: paths(parsed.skills),
        additionalPromptTemplatePaths: paths(parsed.promptTemplates),
        noExtensions: parsed.noExtensions,
        disabledBuiltinExtensions: parsed.noMcp ? ["mcp"] : undefined,
        noSkills: parsed.noSkills, noPromptTemplates: parsed.noPromptTemplates, noContextFiles: parsed.noContextFiles,
        systemPrompt: parsed.systemPrompt, appendSystemPrompt: parsed.appendSystemPrompt,
        extensionFactories: [...sdk.builtInExtensions, { name: "koa", hidden: true, factory }],
      },
    });
    const { settingsManager, resourceLoader } = services;
    diagnostics.push(...services.diagnostics, ...resourceLoader.getExtensions().errors.map(({ path, error }) => ({ type: "error" as const, message: `Failed to load extension "${path}": ${error}` })));
    let model: ReturnType<typeof modelRuntime.getModel>;
    let thinkingLevel = parsed.thinking;
    if (parsed.model) {
      const resolved = pi.resolveCliModel({ cliProvider: parsed.provider, cliModel: parsed.model, cliThinking: parsed.thinking, inlineApiKey: Boolean(parsed.apiKey), modelRuntime });
      if (resolved.error) throw Error(resolved.error);
      if (resolved.warning) diagnostics.push({ type: "warning", message: resolved.warning });
      model = resolved.model;
      if (!thinkingLevel && resolved.thinkingLevel) thinkingLevel = resolved.thinkingLevel;
    } else if (parsed.provider) throw Error(`--provider requires --model (for example: --provider ${parsed.provider} --model <pattern>)`);
    if (parsed.apiKey && model) await modelRuntime.setRuntimeApiKey(model.provider, parsed.apiKey);
    const patterns = parsed.models ?? settingsManager.getEnabledModels();
    const scoped = patterns && patterns.length > 0 ? (await pi.resolveModelScopeWithDiagnostics(patterns, modelRuntime, { signal: AbortSignal.timeout(15_000) })).scopedModels : [];
    const created = await pi.createAgentSessionFromServices({
      services, sessionManager, sessionStartEvent, model, thinkingLevel,
      scopedModels: scoped.length > 0 ? scoped.map(entry => ({ model: entry.model, thinkingLevel: entry.thinkingLevel })) : undefined,
      tools: parsed.tools ? [...parsed.tools] : undefined,
      excludeTools: parsed.excludeTools ? [...parsed.excludeTools] : undefined,
      noTools: parsed.noTools ? "all" : parsed.noBuiltinTools ? "builtin" : undefined,
    });
    if (created.session.model && (parsed.thinking !== undefined || thinkingLevel !== undefined)) created.session.setThinkingLevel(created.session.thinkingLevel);
    for (const diagnostic of diagnostics) options.notify(diagnostic.message, diagnostic.type);
    return { ...created, services, diagnostics };
  };
  let unsubscribe: (() => void) | undefined;
  const replace = async <T extends { cancelled: boolean }>(kind: "new" | "resume" | "fork", run: () => Promise<T>): Promise<T> => {
    const before = runtime.session;
    options.replacing();
    try {
      const result = await run();
      options.replaced(result.cancelled ? undefined : kind);
      return result;
    } catch (error) { options.replaceFailed(error, torn.has(before)); throw error; }
  };
  const bind = async (session: AgentSession) => {
    unsubscribe?.();
    options.rebind(session);
    unsubscribe = session.subscribe(options.onEvent);
    await session.bindExtensions({
      uiContext: options.ui,
      mode: "rpc",
      commandContextActions: {
        waitForIdle: () => session.agent.waitForIdle(),
        newSession: opts => replace("new", () => runtime.newSession(opts)),
        fork: async (entryId, opts) => ({ cancelled: (await replace("fork", () => runtime.fork(entryId, opts))).cancelled }),
        navigateTree: async (targetId, opts) => {
          const result = await session.navigateTree(targetId, opts);
          if (!result.cancelled) options.treeNavigated(result.editorText);
          return { cancelled: result.cancelled };
        },
        switchSession: (file, opts) => replace("resume", () => runtime.switchSession(file, opts)),
        reload: () => session.reload(),
      },
      shutdownHandler: () => { setImmediate(options.shutdown); },
      onError: error => options.notify(`extension ${error.extensionPath}: ${error.event}: ${error.error}`, "error"),
    });
  };
  const runtime = await pi.createAgentSessionRuntime(create, { cwd: sessionManager.getCwd(), agentDir, sessionManager });
  runtime.setRebindSession(bind);
  runtime.setBeforeSessionInvalidate(() => torn.add(runtime.session));
  return host;
}

export function submitPrompt(host: AgentHost, session: AgentSession, message: string, options: { images?: ImageContent[]; streamingBehavior?: "steer" | "followUp" }): Promise<"started" | "queued" | "handled"> {
  return new Promise((resolve, reject) => {
    let accepted = false;
    session.prompt(message, { ...options, source: "rpc", preflightResult: disposition => { accepted = true; resolve(disposition); } })
      .catch(error => { if (accepted) host.notify(errorText(error), "error"); else reject(error); });
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
