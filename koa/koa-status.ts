import { spawnSync } from "node:child_process";
import type { components } from "../webview/ko-api.d.ts";
import type { Agent, Selection } from "./koa-agents.ts";
import { apiArgs, apiCall, type Reply } from "./runtime-exec.ts";
import { cleanLine, errorText, utf8Prefix } from "./text.ts";
import { jobEndText } from "./records.ts";

type Api = components["schemas"];
type Replacement = Extract<Api["StatusReport"], { type: "replace_subtrees" }>;
export const agentPath = (agent: Agent): string => agent.parent ? `${agentPath(agent.parent)}${agent.parent.parent ? "/" : ""}agents/${agent.name}` : "";
export const jobsPath = (agent: Agent): string => `${agentPath(agent)}${agent.parent ? "/" : ""}jobs`;
export const jobRecord = (agent: Agent, id: string): string => `${jobsPath(agent)}/${id}`;

export function deriveRecords(root: Agent, selection: Selection, budget: number): Replacement {
  const agents: { agent: Agent; record: Api["StatusRecord"] }[] = [];
  const jobs: { owner: Agent; record: Api["StatusRecord"]; finished: number | undefined }[] = [];
  const walk = (agent: Agent): void => {
    if (agent.stopping) return;
    if (agent.parent) {
      const dialog = agent.view.state.dialogs[0]?.title;
      const failed = agent.view.life.type === "failed" ? agent.view.life.message : undefined;
      const msg = cleanLine(dialog ?? failed ?? agent.view.root.message, 2048);
      agents.push({ agent, record: { id: agentPath(agent), title: utf8Prefix(agent.name, 192), selection: selection.type === "agent" && selection.agent === agent ? "selected" : "offered", closeable: true, promptable: true, ...(msg ? { msg } : {}), ...(dialog ? { state: "blocked", kind: "question" } : { state: failed === undefined ? agent.view.root.value : "error" }) } });
    }
    for (const job of agent.host.jobs.registry.jobs.values()) {
      if (job.mode.type !== "job" || job.mode.retention.type === "dismissed") continue;
      const ended = job.state.type === "ended" ? job.state : undefined;
      const service = job.mode.origin.type === "async_bash" && job.mode.origin.service;
      const title = cleanLine(job.mode.name, 192), msg = cleanLine(ended ? jobEndText(ended.end) : job.command, 2048);
      jobs.push({ owner: agent, record: { id: jobRecord(agent, job.id), state: ended ? ended.end.type === "exit" && ended.end.code === 0 ? "done" : "error" : service ? "idle" : "working", ...(title ? { title } : {}), ...(msg ? { msg } : {}), ...(agent.host.jobs.selectable ? { selection: selection.type === "job" && selection.job === job ? "selected" as const : "offered" as const, closeable: true } : {}) }, finished: ended && job.mode.retention.type === "lingering" ? ended.at : undefined });
    }
    for (const child of agent.children) walk(child);
  };
  walk(root);
  const allowance = Math.max(0, Math.floor(budget));
  const removed = new Set<string>();
  let size = agents.length + jobs.length;
  for (const job of jobs.flatMap(job => job.finished === undefined ? [] : [{ ...job, finished: job.finished }]).sort((a, b) => a.finished - b.finished || (a.record.id < b.record.id ? -1 : a.record.id > b.record.id ? 1 : 0))) {
    if (size <= allowance) break;
    removed.add(job.record.id); size--;
  }
  let records: Api["StatusRecord"][];
  if (size <= allowance) records = [...agents.map(entry => entry.record), ...jobs.filter(job => !removed.has(job.record.id)).map(job => job.record)];
  else {
    records = [];
    const admitted = new Set<Agent>(root.stopping ? [] : [root]);
    for (const entry of agents) {
      if (records.length >= allowance || !entry.agent.parent || !admitted.has(entry.agent.parent)) continue;
      admitted.add(entry.agent); records.push(entry.record);
    }
    for (const job of jobs) {
      if (records.length >= allowance) break;
      if (admitted.has(job.owner) && !removed.has(job.record.id)) records.push(job.record);
    }
  }
  records.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  return { type: "replace_subtrees", roots: ["agents", "jobs"], records };
}

type Publication =
  | { type: "idle" }
  | { type: "sending" }
  | { type: "retry"; timer: NodeJS.Timeout }
  | { type: "failed"; revision: number }
  | { type: "closed" };

export function createPublisher(options: {
  active: boolean;
  pane: string;
  derive(budget: number): Replacement;
  transport?(method: string, path: string, body?: Replacement, timeoutMs?: number): Promise<Reply>;
  retry?(ms: number): Promise<void>;
  log?(message: string): void;
}) {
  const transport = options.transport ?? apiCall;
  const log = options.log ?? (message => { process.stderr.write(`koa: ${message}\n`); });
  let state: Publication = { type: "idle" };
  let revision = 0, acknowledged = 0;
  let last: string | undefined;
  let forced = 0, scheduled = false, running = false;
  let limit: number | undefined;
  let budget: number | undefined;
  let wake: (() => void) | undefined;
  const waiters: ((success: boolean) => void)[] = [];
  const settle = (success: boolean) => { for (const resolve of waiters.splice(0)) resolve(success); };
  const closed = () => state.type === "closed";
  const request = async (method: string, path: string, body?: Replacement): Promise<string> => {
    const reply = await transport(method, path, body, 1000);
    if ("error" in reply) throw new Error(reply.error);
    if (reply.status !== 200) throw new Error(`HTTP ${reply.status}: ${reply.body}`);
    return reply.body;
  };
  const run = async (): Promise<void> => {
    scheduled = false;
    if (running || closed() || !options.active) return;
    running = true;
    try {
      while (!closed() && acknowledged < revision) {
        const current = revision;
        let success = false;
        for (let attempt = 1; attempt <= 3 && !closed(); attempt++) {
          state = { type: "sending" };
          try {
            if (budget !== undefined && forced <= acknowledged && last !== undefined && JSON.stringify(options.derive(budget)) === last) {
              acknowledged = current; success = true;
              break;
            }
            if (limit === undefined) {
              const version: Api["ServerVersion"] = JSON.parse(await request("GET", "/version"));
              if (!Number.isSafeInteger(version.status_record_limit) || version.status_record_limit < 1) throw new Error("invalid status record limit");
              limit = version.status_record_limit;
            }
            if (closed()) break;
            const pane: Api["Listing"] = JSON.parse(await request("GET", `/panes/${options.pane}`));
            if (closed()) break;
            if (current !== revision) break;
            const outside = (pane.status?.program_status.records ?? []).filter(record => record.id !== "" && !["agents", "jobs"].some(root => record.id === root || record.id.startsWith(`${root}/`))).length;
            budget = Math.max(0, limit - 1 - outside);
            const body = options.derive(budget);
            const canonical = JSON.stringify(body);
            if (forced > acknowledged || last !== canonical) {
              last = undefined;
              await request("POST", `/panes/${options.pane}/status`, body);
            }
            if (closed()) break;
            last = canonical; acknowledged = current; success = true;
            break;
          } catch (error) {
            if (closed()) break;
            log(`status revision ${current} attempt ${attempt}: ${errorText(error)}`);
            if (current !== revision) break;
            if (attempt === 3) break;
            await new Promise<void>(resolve => {
              const done = () => { if (state.type === "retry" && state.timer === timer) clearTimeout(timer); if (wake === done) wake = undefined; resolve(); };
              const timer = setTimeout(done, options.retry ? 2147483647 : attempt === 1 ? 100 : 500);
              state = { type: "retry", timer };
              wake = done;
              if (options.retry) void options.retry(attempt === 1 ? 100 : 500).then(done, done);
            });
            if (current !== revision) break;
          }
        }
        if (closed()) break;
        if (current !== revision) continue;
        if (!success) {
          state = { type: "failed", revision: current };
          log(`status revision ${current} abandoned after 3 attempts`);
          settle(false); return;
        }
      }
      if (!closed()) state = { type: "idle" };
      settle(true);
    } finally { running = false; }
  };
  const changed = (force = false): void => {
    if (closed() || !options.active) return;
    revision++; if (force) forced = revision;
    wake?.();
    if (!running && !scheduled) { scheduled = true; queueMicrotask(() => { void run(); }); }
  };
  const close = (): void => {
    if (state.type === "retry") clearTimeout(state.timer);
    state = { type: "closed" }; wake?.(); settle(true);
  };
  return {
    active: options.active,
    changed,
    drain(): Promise<boolean> {
      if (!options.active || closed() || acknowledged === revision) return Promise.resolve(true);
      if (state.type === "failed" && state.revision === revision) return Promise.resolve(false);
      return new Promise(resolve => waiters.push(resolve));
    },
    close,
    exit(ko: string): void {
      if (closed()) return;
      close();
      if (!options.active) return;
      const body: Replacement = { type: "replace_subtrees", roots: ["agents", "jobs"], records: [] };
      const result = spawnSync(ko, apiArgs("POST", `/panes/${options.pane}/status`, body), { timeout: 1000, input: JSON.stringify(body), encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
      if (result.error || result.status !== 0) log(`status exit cleanup failed: ${result.error ? errorText(result.error) : result.stderr.trim()}`);
    },
  };
}
