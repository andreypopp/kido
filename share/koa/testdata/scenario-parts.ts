import type { PageRecord, WireItem, Block, Text } from "../koa-records.ts";
import { next, expect, type Step } from "./scenario.ts";

export const textImplementTheSidebar = "Implement the **sidebar** indicators with `SidebarRow.swift`; see [the reference](https://example.com/sidebar).\n\n- Keep the **status** at the right.\n- Update `SidebarView.swift`.\n\nRules from the approved mockup (app/design/sidebar/mockup.html, NOTES.md \"Indicator on the right\"):\n1. status and the hover-close × share one 12pt trailing slot centred 18pt from the row's right edge;\n2. title, activity and folded circles start at 12pt;\n3. nesting stays 15pt per level;\n4. the session + aligns with the rightmost indicator;\n5. idle indicators are muted gray at 50% on every row.\n\nAdd snapshot tests for every state of the mockup (light and dark, docked and floating). Run the app's make test; report the pre-fix failures and the diff summary. Do not commit.";

export const textTheSessionVerified = "The session verified the sidebar-right unit (right-side indicators, chevrons, folded clusters) and fixed two snapshot tests; the user approved the dividers-and-fill grouping and the breadcrumb pill. Open: the +N overflow on rows under 215pt. Files touched: SidebarRow.swift, SidebarView.swift, Rows.swift.";

export const textBuiltTheRight = "Built the **right-side** indicators with `SidebarRow.swift`; see [the reference](https://example.com/sidebar). Pre-fix failures: 6 snapshot tests (SidebarTests.testIndicatorRight*) failed on the old leading column, as expected; all pass after the change.\n\n- **SidebarRow.swift**: the trailing slot, 12pt, centred 18pt from the edge; the title inset.\n- `SidebarView.swift`: the session + alignment.\n- Rows.swift: the fold-state key for record rows.\n\nNot done: the \"+N\" overflow of the folded circles on rows narrower than 215pt; the measurement in the mockup assumed 6 circles fit, which they do not at 200pt. Needs a decision.\n\nSnapshots: `app/Tests/__Snapshots__/SidebarTests/` (12 new).";

export const textReadAndChange = "Read and change the user's ko terminal layout - sessions, windows (tabs), panes, splits, floats, focus and the sidebar's pane rows (title, status, cwd, runtime, program) - with `ko api`. Use when the user talks about their windows, tabs, panes, sessions, splits, floats or the sidebar, asks what runs where, or asks to open, split, rename or close one.";

export const stateIdle = (dir: string): Extract<PageRecord, { type: "state" }> => ({ view: { id: "00000000-0000-7000-8000-000000000001", path: [{ id: "00000000-0000-7000-8000-000000000001", name: "ko" }] }, agents: [], bash: [], compaction: "idle", working: false, aborted: false, name: "koa reference", levels: ["off", "minimal", "low", "medium", "high", "xhigh"], cwd: `${dir}/home/Workspace/kido`, home: `${dir}/home`, dialogs: [], statuses: {}, sessionId: "00000000-0000-7000-8000-000000000001", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000001.jsonl`, context: { tokens: 84000, window: 200000, percent: 42 }, queue: { steering: [], followUp: [] }, life: { type: "ready" }, type: "state" });

export const stateIdleThird = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), context: { tokens: 84006, window: 200000, percent: 42.003 } });

export const stateIdleFourth = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), name: "sidebar-right" });

export const assistantVerifiedEveryStageSeq1Rev0: WireItem = { seq: 1, revision: 0, at: 1794330720000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Verified: every stage passes. The snapshots that changed are the twelve of SidebarTests." }], stop: "stop", error: "" };

export const modelsStep: Step = expect({ on: { method: "GET", path: "/models" }, reply: { status: 200, json: { models: [{ id: "claude-opus-5-5", provider: "anthropic" }, { id: "claude-sonnet-5-5", provider: "anthropic" }, { id: "gpt-6.1-sol", provider: "openai-codex" }, { id: "gpt-6-astra", provider: "openai-codex" }, { id: "claude-fable-5-1", provider: "claude-bridge" }] } } });

export const userExplainHowThe: PageRecord = { type: "item", item: { seq: 0, revision: 1, at: 1794177120000, final: true, kind: "user", text: "Explain how the sweep decides what to remove, with a table", images: [], attachments: [] } };

export const nextStateWithWorkingAndSince = (dir: string): Step => (next([
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  userExplainHowThe,
]));

export const assistantWhatTheSweepSeq1Rev2: PageRecord = { type: "item", item: { seq: 1, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "text", text: "## What the sweep does\n\nThe sweep reads the pane rows, never a process. It removes a pane with the default `close: exit` as soon as its program exits, and keeps three other kinds for a while:\n\n- a start failure, so the error stays readable;\n- a `close: on_exit` pane, for the linger grace;\n- a pane whose parent is gone, until no focused client shows it.\n\n| Cause | Removed | Keeps descendants |\n| --- | --- | --- |\n| exit | at once | no |\n| failed | linger grace | no |\n| parent gone | when unfocused | cascade |\n\nThe cascade is the server's: every removal takes the pane's descendants in the same change.\n\n```rust\nfn sweep(&mut self, now: Instant) -> Vec<PaneId> {\n    let gone = self.rows.iter()\n        .filter(|row| row.due(now))\n        .map(|row| row.id)\n        .collect::<Vec<_>>();\n    gone.iter().for_each(|id| self.remove(*id));\n    gone\n}\n```\n\nNext I would check how `linger` interacts with a focused client that is itself" }], stop: "pending", error: "" } };

export const nextAssistantEmptySeq1Rev1: Step = next([
  { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
  assistantWhatTheSweepSeq1Rev2,
]);

export const nextPatchSeq1Rev3Second: Step = next([
  { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [{ index: 0, suffix: "\n\nThe patch keeps the earlier selection.\n\n" }], final: false, stop: "pending", error: "" },
]);

export const userMakeTheSweep: WireItem = { seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] };

export const resetOf1ItemsSecond: PageRecord = { type: "reset", epoch: "epoch2", items: [userMakeTheSweep], more: false };

const thinkingTheSweepNeeds: Block = { type: "thinking", text: "The sweep needs to distinguish a start failure from a program exit. Check the close policy and preserve the focus rule.", redacted: false };

export const assistantTheSweepNeedsSeq1Rev2Second: PageRecord = { type: "item", item: { seq: 1, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [thinkingTheSweepNeeds, { type: "tool", id: "call_2_0", name: "read", args: { text: "{}", cut: 0 }, state: { type: "pending" } }], stop: "pending", error: "" } };

export const thinkingTheSweepNeedsSecond: Block = { type: "thinking", text: "The sweep needs to distinguish a start failure from a program exit. Check the close policy and preserve the focus rule.", redacted: false, started: 1794177120000 };

const textKoServerSrc: Text = { text: "{\"path\":\"ko_server/src/sweep.rs\",\"oldText\":\"    fn due(&self, now: Instant) -> bool {\\n        self.exited && self.close == Close::Exit\\n    }\",\"newText\":\"    fn due(&self, now: Instant) -> bool {\\n        match self.close {\\n            Close::Exit => self.exited && !self.failed,\\n            Close::OnExit => self.dead_since.is_some_and(|t| now - t > self.linger),\\n        }\\n    }\"}", cut: 0 };

export const toolBashMakeCargoARGS: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "pending" } };

export const assistantTheSweepNeedsSeq1Rev3: PageRecord = { type: "item", item: { seq: 1, revision: 3, at: 1794177120000, final: false, kind: "assistant", blocks: [thinkingTheSweepNeedsSecond, { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_2_1", name: "edit", args: textKoServerSrc, state: { type: "pending" } }, toolBashMakeCargoARGS], stop: "toolUse", error: "" } };

export const thinkingTheSweepNeedsThird: Block = { type: "thinking", text: "The sweep needs to distinguish a start failure from a program exit. Check the close policy and preserve the focus rule.", redacted: false, started: 1794177120000, ended: 1794177120000 };

export const patchSeq1Rev4Fourth: PageRecord = { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: thinkingTheSweepNeedsThird }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const patchSeq1Rev5: PageRecord = { type: "patch", seq: 1, baseRevision: 4, revision: 5, blocks: [{ index: 1, block: { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const patchSeq1Rev6: PageRecord = { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 2, block: { type: "tool", id: "call_2_1", name: "edit", args: textKoServerSrc, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const patchSeq1Rev7: PageRecord = { type: "patch", seq: 1, baseRevision: 6, revision: 7, blocks: [{ index: 3, block: { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const toolEdit: Block = { type: "tool", id: "call_2_1", name: "edit", args: textKoServerSrc, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 2 };

export const toolBashMakeCargoARGSSecond: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "running", result: { text: "", cut: 0, images: [] } }, started: 1794177120000 };

export const patchSeq1Rev8: PageRecord = { type: "patch", seq: 1, baseRevision: 7, revision: 8, blocks: [{ index: 2, block: toolEdit }, { index: 3, block: toolBashMakeCargoARGSSecond }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const nextPatchSeq1Rev4 = (dir: string): Step => (next([
  { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [], final: true, stop: "stop", error: "", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  stateIdle(dir),
  stateIdle(dir),
  resetOf1ItemsSecond,
  stateIdle(dir),
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
  assistantTheSweepNeedsSeq1Rev2Second,
  assistantTheSweepNeedsSeq1Rev3,
  patchSeq1Rev4Fourth,
  patchSeq1Rev5,
  patchSeq1Rev6,
  patchSeq1Rev7,
  patchSeq1Rev8,
]));

export const toolStateDone: Extract<Block, { type: "tool" }>["state"] = { type: "done", result: { text: "    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row\n    row", cut: 0, images: [] }, error: false };

export const toolReadKoServerSrc: Block = { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: toolStateDone, started: 1794177120000, ended: 1794177120000, durationMs: 15 };

export const patchSeq1Rev9: PageRecord = { type: "patch", seq: 1, baseRevision: 8, revision: 9, blocks: [{ index: 1, block: toolReadKoServerSrc }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const toolStateDoneSecond: Extract<Block, { type: "tool" }>["state"] = { type: "done", result: { text: "running 3 tests\ntest sweep::tests::removes_on_exit ... ok\ntest sweep::tests::keeps_a_start_failure ... ok\ntest sweep::tests::linger_waits_for_focus ... ok\n\ntest result: ok. 3 passed; 0 failed; 0 ignored; finished in 0.41s", cut: 0, images: [] }, error: false };

export const assistantDoneDueNowSeq2Rev2: PageRecord = { type: "item", item: { seq: 2, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Done. `due()` now matches on `close`, a start failure never fires `Close::Exit`, and the three sweep tests pass." }], stop: "stop", error: "", ended: 1794177120000 } };

export const assistantTheSweepNeedsSeq1Rev0: WireItem = { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [thinkingTheSweepNeeds], stop: "stop", error: "" };

export const assistantReadSeq2Rev0: WireItem = { seq: 2, revision: 0, at: 1794177126000, final: true, kind: "assistant", blocks: [{ type: "tool", id: "read", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: toolStateDone, started: 1794177126000, ended: 1794177126100 }], stop: "toolUse", error: "" };

const assistantEditSeq3Rev0: WireItem = { seq: 3, revision: 0, at: 1794177126100, final: true, kind: "assistant", blocks: [{ type: "tool", id: "edit", name: "edit", args: textKoServerSrc, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177126100, ended: 1794177126300 }], stop: "toolUse", error: "" };

export const assistantBashSeq4Rev0: WireItem = { seq: 4, revision: 0, at: 1794177126800, final: true, kind: "assistant", blocks: [{ type: "tool", id: "bash", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177126800, ended: 1794177130000 }], stop: "toolUse", error: "" };

export const assistantDoneDueNowSeq5Rev0: WireItem = { seq: 5, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Done. `due()` now matches on `close`, a start failure never fires `Close::Exit`, and the three sweep tests pass." }], stop: "stop", error: "" };

export const resetOf6Items: PageRecord = { type: "reset", epoch: "epoch3", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0], more: false };

export const nextResetOf5ItemsSecond = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch4", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0, assistantBashSeq4Rev0], more: false },
  stateIdle(dir),
]));

export const assistantEmptySeq5Rev1: PageRecord = { type: "item", item: { seq: 5, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "aborted", error: "Request aborted" } };

export const assistantReadSeq1Rev0Second: WireItem = { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "tool", id: "failed-read", name: "read", args: { text: "{\"path\":\"Makefile\"}", cut: 0 }, state: { type: "done", result: { text: "    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target\n    target", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120100 }], stop: "toolUse", error: "" };

export const assistantBashSeq2Rev0Second: WireItem = { seq: 2, revision: 0, at: 1794177121000, final: true, kind: "assistant", blocks: [{ type: "tool", id: "bad", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "done", result: { text: "test sweep::tests::linger_waits_for_focus ... FAILED\n\nfailures:\n---- sweep::tests::linger_waits_for_focus stdout ----\nassertion `left == right` failed\n  left: Some(%7)\n right: None\n\nFAIL unit 40.2s", cut: 0, images: [] }, error: true }, started: 1794177121000, exit: 101, ended: 1794177161000 }], stop: "toolUse", error: "" };

export const assistantTheLingerTestSeq3Rev0: WireItem = { seq: 3, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "The linger test fails because `dead_since` is set before the focus check. Looking at the order in `sweep()`." }], stop: "stop", error: "" };

export const nextStateWithWorkingAndSinceSecond = (dir: string): Step => (next([
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  assistantEmptySeq5Rev1,
  { type: "patch", seq: 5, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "Request aborted", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { type: "reset", epoch: "epoch5", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Run the whole unit stage", images: [], attachments: [] }, assistantReadSeq1Rev0Second, assistantBashSeq2Rev0Second, assistantTheLingerTestSeq3Rev0, { seq: 4, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "thinking", text: "the order in sweep()", redacted: false }, { type: "tool", id: "abort", name: "edit", args: { text: "{\"path\":\"ko_server/src/sweep.rs\",\"oldText\":\"\",\"newText\":\"\"}", cut: 0 }, state: { type: "not_run" }, started: 1794177120000 }], stop: "aborted", error: "" }], more: false },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
]));

export const toolReadKoServerSrcSecond: Block = { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: toolStateDone, started: 1794177120000, ended: 1794177120000, durationMs: 5 };

export const patchSeq1Rev9Second: PageRecord = { type: "patch", seq: 1, baseRevision: 8, revision: 9, blocks: [{ index: 1, block: toolReadKoServerSrcSecond }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

export const nextStateWithWorkingAndSinceThird = (dir: string): Step => (next([
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  assistantEmptySeq5Rev1,
  { type: "patch", seq: 5, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "Request aborted", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { type: "reset", epoch: "epoch5", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Run the whole unit stage", images: [], attachments: [] }, assistantReadSeq1Rev0Second, assistantBashSeq2Rev0Second, assistantTheLingerTestSeq3Rev0, { seq: 4, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "thinking", text: "the order in sweep()", redacted: false }, { type: "tool", id: "abort", name: "edit", args: { text: "{\"newText\":\"\",\"oldText\":\"\",\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "not_run" }, started: 1794177120000 }], stop: "aborted", error: "" }], more: false },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
]));

export const nextStateWithWorkingAndSinceFourth = (dir: string): Step => (next([
  { ...stateIdle(dir), working: true, since: 1794177120000 },
  assistantEmptySeq5Rev1,
  { type: "patch", seq: 5, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "Request aborted", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { type: "reset", epoch: "epoch5", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Run the whole unit stage", images: [], attachments: [] }, assistantReadSeq1Rev0Second, assistantBashSeq2Rev0Second, assistantTheLingerTestSeq3Rev0, { seq: 4, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "thinking", text: "the order in sweep()", redacted: false }, { type: "tool", id: "abort", name: "edit", args: { text: "{\"oldText\":\"\",\"newText\":\"\",\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "not_run" }, started: 1794177120000 }], stop: "aborted", error: "" }], more: false },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
]));

export const nextResetOf5ItemsFourth = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch2", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Look at the two screenshots in /tmp/koa-shots and tell me what differs", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794330720000, final: true, kind: "assistant", blocks: [{ type: "tool", id: "light", name: "read", args: { text: "{\"path\":\"/tmp/koa-shots/complete-at-agents-light-wide.png\"}", cut: 0 }, state: { type: "done", result: { text: "Read image file [image/png]", cut: 0, images: [{ id: "1.0.0", revision: 0, bytes: 693145, mimeType: "image/png", width: 1440, height: 900 }] }, error: false }, started: 1794330720000, ended: 1794330720200 }], stop: "toolUse", error: "" }, { seq: 2, revision: 0, at: 1794330720200, final: true, kind: "assistant", blocks: [{ type: "tool", id: "dark", name: "read", args: { text: "{\"path\":\"/tmp/koa-shots/complete-at-agents-dark-wide.png\"}", cut: 0 }, state: { type: "done", result: { text: "Read image file [image/png]", cut: 0, images: [{ id: "2.0.0", revision: 0, bytes: 693145, mimeType: "image/png", width: 1440, height: 900 }] }, error: false }, started: 1794330720200, ended: 1794330720400 }], stop: "toolUse", error: "" }, { seq: 3, revision: 0, at: 1794330727900, final: true, kind: "assistant", blocks: [{ type: "tool", id: "images", name: "codemode", args: { text: "{\"code\":\"image() x2\"}", cut: 0 }, state: { type: "done", result: { text: "sidebar rows: 28 vs 32pt", cut: 0, images: [{ id: "3.0.0", revision: 0, bytes: 263613, mimeType: "image/png", width: 1200, height: 500 }, { id: "3.0.1", revision: 0, bytes: 357617, mimeType: "image/png", width: 800, height: 800 }] }, error: false }, started: 1794330727900, ended: 1794330729000 }], stop: "toolUse", error: "" }, { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "assistant", blocks: [{ type: "text", text: "The light render has the kind tags; the dark one lost them to the ellipsis. Two things differ…" }], stop: "stop", error: "" }], more: false },
  stateIdle(dir),
]));
