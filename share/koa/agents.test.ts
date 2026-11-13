import { test } from "node:test";
import assert from "node:assert/strict";
import type { components } from "./ko-api.d.ts";
import { agentCompletionItems, parsePanes, relationships, type AgentCompletionRow, type PaneInfo } from "./agents.ts";

test("completion ranks names before words and inserts unique session prefixes", () => {
  const row = (id: string, name: string, relationship: AgentCompletionRow["relationship"] = "peer"): AgentCompletionRow => ({ id, where: { type: "pane", pane: id, window: "window_1" }, name, named: true, self: false, status: "working", activity: "reading", parent: "", state: "running", relationship });
  const parent = row("11111111aaaa", "manager");
  const word = { ...row("22222222aaaa", "fix-sidebar"), parent: parent.id };
  const prefix = row("22222222bbbb", "sidebar");
  const others = [parent, word, prefix, { ...row("self", "sidebar-self"), self: true }, row("other", "sidebar-other", "other")];
  assert.deepEqual(agentCompletionItems(others, others, "side"), [
    { value: "@sidebar (session 22222222b)", label: "@sidebar", description: "working - reading" },
    { value: "@fix-sidebar (session 22222222a)", label: "@fix-sidebar", description: "working - reading, subagent of manager" },
  ]);
});

test("layout relationships follow parent chains and the session boundary", () => {
  const panes: PaneInfo[] = [["pane_1", "pane_parent"], ["pane_parent", ""], ["pane_peer", "pane_parent"], ["pane_child", "pane_1"], ["pane_other", ""]].map(([pane, parent]) => ({
    pane, parent, session: pane === "pane_other" ? "session_else" : "session_1", window: "window_1", sessionVar: pane, kind: null, name: pane, activity: "", cwd: "/tmp", runtime: "", dead: null, root: null, title: "", inbox: false, task: undefined,
  }));
  assert.deepEqual([...relationships(panes, panes[0])], [["pane_parent", "parent"], ["pane_peer", "peer"], ["pane_child", "own"]]);
});

test("a pane's task comes from its koa.task variable", () => {
  const task = { text: "build it", from: { session: "boss-session" } };
  const row = (vars: Record<string, unknown>): components["schemas"]["Listing"] => ({ id: "pane_1", vars, command: [], cwd: "/tmp", title: "", dead: null, started: 0 });
  const [withTask, withOld] = parsePanes({ layout: { sessions: [] }, panes: [row({ "koa.task": task }), row({ "ko-pi.task": task })], revision: 0 });
  assert.deepEqual(withTask.task, task);
  assert.equal(withOld.task, undefined);
});
