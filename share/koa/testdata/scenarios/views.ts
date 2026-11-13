import { expect, next, same, type Scenario, type Scenarios, type Step } from "../scenario.ts";
import { stateIdle } from "../scenario-parts.ts";
import type { PageRecord, State, WireItem } from "../../koa-records.ts";

type Node = { id: string; name: string };
const at = 1794330720000;
const root: Node = { id: "00000000-0000-7000-8000-000000000001", name: "ko" };
const reviewer: Node = { id: "00000000-0000-7000-8000-0000000000a1", name: "reviewer" };
const checker: Node = { id: "00000000-0000-7000-8000-0000000000a2", name: "checker" };
const deep: Node[] = [root, ...["sidebar-reviewer", "layout-geometry-checker", "snapshot-recorder-agent", "geometry-verifier-agent", "contrast-auditor-agent", "documentation-reader", "final-verification-pass"].map((name, index) => ({ id: `00000000-0000-7000-8000-0000000000b${index + 1}`, name }))];

const text = (value: string) => ({ text: value, cut: 0 });
const user = (seq: number, value: string): WireItem => ({ seq, revision: 0, at, final: true, kind: "user", text: value, images: [], attachments: [] });
const assistant = (seq: number, value: string): WireItem => ({ seq, revision: 0, at, final: true, kind: "assistant", blocks: [{ type: "text", text: value }], stop: "stop", error: "" });
const reset = (epoch: string, items: WireItem[]): PageRecord => ({ type: "reset", epoch, more: false, items });
const rootItems = [user(0, "Review the sidebar change with two agents"), assistant(1, "@reviewer reads the diff and asks @checker for the geometry. I wait for their reports.")];
const reviewerItems = [user(0, "Review the diff of the sidebar change and report what is wrong"), assistant(1, "The diff touches `SidebarRow.swift`. I ask @checker to measure the right column.")];
const checkerItems = [user(0, "Measure the right column of the sidebar rows at 200pt"), assistant(1, "The right column is 22pt wide at 200pt and 18pt at 160pt.")];

const links = (...nodes: Node[]): State["agents"] => nodes.map(node => ({ name: node.name, target: { type: "view", id: node.id } }));
const viewState = (dir: string, path: Node[], extra: Partial<State> = {}): PageRecord => {
  const viewed = path[path.length - 1];
  return { ...stateIdle(dir), view: { id: viewed.id, path }, sessionId: viewed.id, name: viewed === root ? "koa reference" : viewed.name, ...extra, type: "state" };
};
const switchTo = (dir: string, from: Node, to: Node, path: Node[], epoch: string, items: WireItem[], extra: Partial<State> = {}): Step => expect({
  on: { method: "POST", path: "/view", body: value => same(value, { sessionId: from.id, id: to.id }) },
  reply: { status: 200, json: {} },
  after: [viewState(dir, path, extra), reset(epoch, items)],
});

const subagent = (dir: string): Scenario => ({
  open: [viewState(dir, [root], { agents: links(reviewer) }), reset("epoch1", rootItems)],
  steps: [
    switchTo(dir, root, reviewer, [root, reviewer], "epoch2", reviewerItems, { agents: links(checker), model: { provider: "anthropic", id: "claude-sonnet-5-5" }, context: { tokens: 31000, window: 200000, percent: 15.5 } }),
    next([viewState(dir, [root, reviewer], { agents: links(checker), working: true, since: at, model: { provider: "anthropic", id: "claude-sonnet-5-5" }, context: { tokens: 31000, window: 200000, percent: 15.5 } })]),
    next([viewState(dir, [root, reviewer], { agents: links(checker), model: { provider: "anthropic", id: "claude-sonnet-5-5" }, context: { tokens: 31000, window: 200000, percent: 15.5 } })]),
    expect({
      on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: reviewer.id, text: "/new", mode: "prompt", attachments: [] }) },
      reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } },
      after: [{ type: "item", item: { seq: 2, revision: 0, at, final: true, kind: "notify", level: "warning", text: text("/new: only in @ko's view") } }],
    }),
    switchTo(dir, reviewer, checker, [root, reviewer, checker], "epoch3", checkerItems),
    switchTo(dir, checker, reviewer, [root, reviewer], "epoch4", reviewerItems, { agents: links(checker) }),
    switchTo(dir, reviewer, root, [root], "epoch5", rootItems, { agents: links(reviewer) }),
  ],
  files: {},
});

const bar = (dir: string): Scenario => ({
  open: [viewState(dir, deep), reset("epoch1", checkerItems)],
  steps: [switchTo(dir, deep[7], deep[2], deep.slice(0, 3), "epoch2", reviewerItems)],
  files: {},
});

export const scenarios: Scenarios = {
  testKoaWebviewSubagentViewWide: subagent,
  testKoaWebviewSubagentViewNarrow: subagent,
  testKoaWebviewViewBarWide: bar,
  testKoaWebviewViewBarNarrow: bar,
};
