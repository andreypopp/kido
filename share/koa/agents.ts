import type { components } from "./ko-api.d.ts";
import { isRecord, str } from "./text.ts";
type Api = components["schemas"];
type Dead = Api["Dead"];

export const VAR_SESSION = "pi.session";
export const VAR_NAME = "pi.name";
export const VAR_ACTIVITY = "pi.activity";
export const VAR_TASK = "koa.task";
export const VAR_RUNTIME = "pi.runtime";

export const MIN_ID_PREFIX = 8;
const MAX_AGENT_COMPLETIONS = 10;
const NAME_WORD_SEPARATORS = /[\s\-_/]+/;

export type Where = { type: "process" } | { type: "pane"; pane: string; window: string };

export type AgentCompletionRow = {
  id: string; where: Where; name: string; named: boolean; self: boolean; status: string; activity: string; parent: string;
  state: "running" | "ended"; relationship: "parent" | "peer" | "own" | "relative" | "other";
};

export type AgentRow = AgentCompletionRow & {
  depth: number; cwd: string; runtime?: string; canMessage: boolean;
  kind: "agent" | "subagent"; ended?: string; model?: string; reported?: boolean; report?: string;
};

export type PaneInfo = {
  pane: string;
  session: string;
  window: string;
  sessionVar: string;
  kind: Api["Live"] | null;
  name: string;
  activity: string;
  cwd: string;
  runtime: string;
  dead: Dead | null;
  root: { app: string; state: string } | null;
  title: string;
  parent: string;
  inbox: boolean;
  task: unknown;
};

function rootRecord(programStatus: Api["ProgramStatus"] | null): { app: string; state: string } | null {
  const root = programStatus?.records.find((r) => r.id === "");
  return root ? { app: root.app ?? "", state: root.state } : null;
}

export function piAgent(kind: Api["Live"] | null) {
  return (kind?.type === "host" || kind?.type === "runtime") && kind.pane.type === "pi_agent" ? kind.pane : undefined;
}

export function peerPanes(panes: PaneInfo[], of: PaneInfo): PaneInfo[] {
  return panes.filter((p) => p.session === of.session && p.pane !== of.pane && p.parent === of.parent);
}

type Place = { session: string; window: string };

function placeLeaves(node: Api["LeafNode"] | Api["Float"], place: Place, into: Map<string, Place>): void {
  if ("pane" in node) into.set(node.pane, place);
  else for (const child of node.children) placeLeaves(child, place, into);
}

export function placesOf(layout: Api["LayoutPanes"]): Map<string, Place> {
  const places = new Map<string, Place>();
  for (const session of layout.layout.sessions) {
    for (const window of session.windows) {
      const place = { session: session.id, window: window.id };
      placeLeaves(window.tree, place, places);
      for (const float of window.floats) placeLeaves(float, place, places);
    }
  }
  return places;
}

export function parsePanes(layout: Api["LayoutPanes"]): PaneInfo[] {
  const places = placesOf(layout);
  return layout.panes.map((row) => {
    const place = places.get(row.id);
    const root = rootRecord(row.status?.program_status ?? null);
    const kind = row.status?.kind ?? null;
    const routed = row.vars[VAR_RUNTIME];
    const route = kind?.type === "host" && piAgent(kind) && isRecord(routed) && typeof routed.name === "string" ? { name: routed.name, cwd: str(routed.cwd) } : undefined;
    return {
      pane: row.id,
      session: place?.session ?? "",
      window: place?.window ?? "",
      sessionVar: str(row.vars[VAR_SESSION]),
      kind,
      name: str(row.vars[VAR_NAME]),
      activity: str(row.vars[VAR_ACTIVITY]),
      cwd: route?.cwd || row.cwd,
      runtime: row.runtime ?? route?.name ?? "",
      dead: row.dead,
      root,
      title: row.title,
      parent: row.parent ?? "",
      inbox: row.inbox === true,
      task: row.vars[VAR_TASK],
    };
  });
}

export function ancestorsOf(byPane: Map<string, PaneInfo>, pane: PaneInfo): PaneInfo[] {
  const chain: PaneInfo[] = [];
  let current = byPane.get(pane.parent);
  while (current && !chain.includes(current)) { chain.push(current); current = byPane.get(current.parent); }
  return chain;
}

export function relationships(panes: PaneInfo[], me: PaneInfo | undefined): Map<string, AgentCompletionRow["relationship"]> {
  const result = new Map<string, AgentCompletionRow["relationship"]>();
  if (!me) return result;
  ancestorsOf(new Map(panes.map(p => [p.pane, p])), me).forEach((ancestor, i) => {
    result.set(ancestor.pane, i === 0 ? "parent" : "relative");
    for (const peer of peerPanes(panes, ancestor)) if (!result.has(peer.pane)) result.set(peer.pane, "relative");
  });
  for (const peer of peerPanes(panes, me)) result.set(peer.pane, "peer");
  for (const pane of panes) if (pane.parent === me.pane && pane.session === me.session) result.set(pane.pane, "own");
  return result;
}

export function runningRows(panes: PaneInfo[], me: PaneInfo | undefined): { pane: PaneInfo; row: AgentCompletionRow }[] {
  const byPane = new Map(panes.map(p => [p.pane, p]));
  const related = relationships(panes, me);
  return panes.filter(p => !p.dead).map(p => ({ pane: p, row: {
    id: piAgent(p.kind)?.session ?? p.pane, where: { type: "pane", pane: p.pane, window: p.window }, name: p.name || p.title, named: p.name !== "", self: p.pane === me?.pane,
    status: p.root?.state ?? "starting", activity: p.activity, parent: piAgent(byPane.get(p.parent)?.kind ?? null)?.session ?? "",
    state: "running", relationship: p.pane === me?.pane ? "own" : related.get(p.pane) ?? "other",
  } }));
}

function completionValue(ids: AgentCompletionRow[], agent: AgentCompletionRow): string {
  let n = MIN_ID_PREFIX;
  while (n < agent.id.length && ids.some((other) => other !== agent && other.id.startsWith(agent.id.slice(0, n)))) n++;
  return `@${agent.name} (session ${agent.id.slice(0, n)})`;
}

export function agentCompletionItems(agents: AgentCompletionRow[], all: AgentCompletionRow[], token: string) {
  const nameByID = new Map(agents.map((a) => [a.id, a.name]));
  const wanted = token.toLowerCase();
  const matched: Array<{ agent: AgentCompletionRow; rank: number }> = [];
  for (const a of agents) {
    if (a.self || a.relationship === "other" || (a.state === "ended" && a.relationship !== "peer") || !a.name || !a.named) continue;
    const name = a.name.toLowerCase();
    if (name.startsWith(wanted)) matched.push({ agent: a, rank: 0 });
    else if (name.split(NAME_WORD_SEPARATORS).some((word) => word.startsWith(wanted))) matched.push({ agent: a, rank: 1 });
  }
  matched.sort((x, y) => x.rank - y.rank);
  return matched.slice(0, MAX_AGENT_COMPLETIONS).map(({ agent: a }) => {
    const parent = a.parent ? nameByID.get(a.parent) || a.parent : "";
    const description = a.state === "ended" ? "ended peer" : [
      a.activity ? `${a.status || "agent"} - ${a.activity}` : a.status || "agent",
      parent ? `subagent of ${parent}` : "",
    ].filter(Boolean).join(", ");
    return { value: completionValue(all, a), label: `@${a.name}`, description };
  });
}

