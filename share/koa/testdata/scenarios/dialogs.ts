import { next, expect, same, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord, WireItem, Block, Text } from "../../koa-records.ts";
import { stateIdle, nextStateWithWorkingAndSince, nextAssistantEmptySeq1Rev1, nextPatchSeq1Rev3Second, userMakeTheSweep, resetOf1ItemsSecond, assistantTheSweepNeedsSeq1Rev2Second, thinkingTheSweepNeedsSecond, toolBashMakeCargoARGS, thinkingTheSweepNeedsThird, patchSeq1Rev4Fourth, patchSeq1Rev5, patchSeq1Rev7, toolEdit, toolBashMakeCargoARGSSecond, nextPatchSeq1Rev4, toolStateDone, toolStateDoneSecond, assistantDoneDueNowSeq2Rev2, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0, resetOf6Items, nextResetOf5ItemsSecond, toolReadKoServerSrcSecond, patchSeq1Rev9Second, nextStateWithWorkingAndSinceThird, nextStateWithWorkingAndSinceFourth } from "../scenario-parts.ts";

const textKoServerSrcSecond: Text = { text: "{\"path\":\"ko_server/src/sweep.rs\",\"newText\":\"    fn due(&self, now: Instant) -> bool {\\n        match self.close {\\n            Close::Exit => self.exited && !self.failed,\\n            Close::OnExit => self.dead_since.is_some_and(|t| now - t > self.linger),\\n        }\\n    }\",\"oldText\":\"    fn due(&self, now: Instant) -> bool {\\n        self.exited && self.close == Close::Exit\\n    }\"}", cut: 0 };

const assistantTheSweepNeedsSeq1Rev3Second: PageRecord = { type: "item", item: { seq: 1, revision: 3, at: 1794177120000, final: false, kind: "assistant", blocks: [thinkingTheSweepNeedsSecond, { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_2_1", name: "edit", args: textKoServerSrcSecond, state: { type: "pending" } }, toolBashMakeCargoARGS], stop: "toolUse", error: "" } };

const patchSeq1Rev6Second: PageRecord = { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 2, block: { type: "tool", id: "call_2_1", name: "edit", args: textKoServerSrcSecond, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

const toolEditSecond: Block = { type: "tool", id: "call_2_1", name: "edit", args: textKoServerSrcSecond, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 2 };

const patchSeq1Rev8Second: PageRecord = { type: "patch", seq: 1, baseRevision: 7, revision: 8, blocks: [{ index: 2, block: toolEditSecond }, { index: 3, block: toolBashMakeCargoARGSSecond }], final: false, stop: "toolUse", error: "", ended: 1794177120000 };

const toolBashMakeCargoARGSFifth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 320 };

const blocksThird: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEditSecond,
  toolBashMakeCargoARGSFifth,
];

const assistantEditSeq3Rev0Second: WireItem = { seq: 3, revision: 0, at: 1794177126100, final: true, kind: "assistant", blocks: [{ type: "tool", id: "edit", name: "edit", args: textKoServerSrcSecond, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177126100, ended: 1794177126300 }], stop: "toolUse", error: "" };

const resetOf6ItemsSecond: PageRecord = { type: "reset", epoch: "epoch3", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Second, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0], more: false };

const nextResetOf5ItemsThird = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch4", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Second, assistantBashSeq4Rev0], more: false },
  stateIdle(dir),
]));

const toolReadScriptsReleaseSh: Block = { type: "tool", id: "call_5_0", name: "read", args: { text: "{\"path\":\"scripts/release.sh\"}", cut: 0 }, state: { type: "done", result: { text: "#!/bin/sh\necho release\n", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 1 };

const nextResetOf1ItemsFourth = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch6", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Release 0.32 and write the notes", images: [], attachments: [] }], more: false },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
  { type: "item", item: { seq: 1, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "tool", id: "call_5_0", name: "read", args: { text: "{\"path\":\"scripts/release.sh\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_5_1", name: "release", args: { text: "{}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794177120000 } },
  { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [{ index: 0, block: { type: "tool", id: "call_5_0", name: "read", args: { text: "{\"path\":\"scripts/release.sh\"}", cut: 0 }, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
  { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [{ index: 1, block: { type: "tool", id: "call_5_1", name: "release", args: { text: "{}", cut: 0 }, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, dialogs: [{ id: "00000000-0000-4000-8000-000000000001", title: "Which tap revision?", method: "select", options: ["0.31.1 · 20857320", "0.31.0 · 6153fce8", "custom…"], timeout: 20000, expires: 1794177140000 }], context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { ...stateIdle(dir), working: true, dialogs: [{ id: "00000000-0000-4000-8000-000000000001", title: "Which tap revision?", method: "select", options: ["0.31.1 · 20857320", "0.31.0 · 6153fce8", "custom…"], timeout: 20000, expires: 1794177140000 }, { id: "00000000-0000-4000-8000-000000000002", title: "Force-push main?", method: "confirm", message: "origin/main moves from 20857320 to 88bdb070. Other clones need a reset." }], context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { type: "patch", seq: 1, baseRevision: 4, revision: 5, blocks: [{ index: 0, block: toolReadScriptsReleaseSh }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
]));

const dialogStep = (dir: string): Step => (expect({ on: { method: "POST", path: "/dialog", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", id: "00000000-0000-4000-8000-000000000001", value: "0.31.1 · 20857320" }) }, before: [
    { ...stateIdle(dir), working: true, dialogs: [{ id: "00000000-0000-4000-8000-000000000002", title: "Force-push main?", method: "confirm", message: "origin/main moves from 20857320 to 88bdb070. Other clones need a reset." }], context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  ], reply: { status: 200, json: {} } }));

const dialogStepSecond = (dir: string): Step => (expect({ on: { method: "POST", path: "/dialog", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", id: "00000000-0000-4000-8000-000000000002", confirmed: true }) }, reply: { status: 200, json: {} }, after: [
    { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
    { ...stateIdle(dir), working: true, dialogs: [{ id: "00000000-0000-4000-8000-000000000003", title: "Version for the tap", method: "input", placeholder: "0.32.0", timeout: 49000, expires: 1794177169000 }], context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  ] }));

const dialogStepThird = (dir: string): Step => (expect({ on: { method: "POST", path: "/dialog", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", id: "00000000-0000-4000-8000-000000000003", value: "0.32.0" }) }, reply: { status: 200, json: {} }, after: [
    { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
    { ...stateIdle(dir), working: true, dialogs: [{ id: "00000000-0000-4000-8000-000000000004", title: "Release notes", method: "editor", prefill: "## 0.32\n\n- The sidebar shows status at the right and folds children\n- A program can show a webview page in its pane" }], context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  ] }));

const toolRelease: Block = { type: "tool", id: "call_5_1", name: "release", args: { text: "{}", cut: 0 }, state: { type: "done", result: { text: "Released", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 231 };

const blocksFourth: Block[] = [
  toolReadScriptsReleaseSh,
  toolRelease,
];

const toolReadKoServerSrcThird: Block = { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: toolStateDone, started: 1794177120000, ended: 1794177120000, durationMs: 6 };

const toolBashMakeCargoARGSSixth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 349 };

const blocksFifth: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcThird,
  toolEditSecond,
  toolBashMakeCargoARGSSixth,
];

const toolReleaseSecond: Block = { type: "tool", id: "call_5_1", name: "release", args: { text: "{}", cut: 0 }, state: { type: "done", result: { text: "Released", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 302 };

const blocksSixth: Block[] = [
  toolReadScriptsReleaseSh,
  toolReleaseSecond,
];

const toolBashMakeCargoARGSSeventh: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 115 };

const blocksSeventh: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEdit,
  toolBashMakeCargoARGSSeventh,
];

export const scenarios: Scenarios = {
  testKoaWebviewDialogFields: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [
      nextStateWithWorkingAndSince(dir),
      nextAssistantEmptySeq1Rev1,
      nextPatchSeq1Rev3Second,
      next([
        { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [], final: true, stop: "stop", error: "", ended: 1794177120000 },
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        resetOf1ItemsSecond,
        stateIdle(dir),
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantTheSweepNeedsSeq1Rev2Second,
        assistantTheSweepNeedsSeq1Rev3Second,
        patchSeq1Rev4Fourth,
        patchSeq1Rev5,
        patchSeq1Rev6Second,
        patchSeq1Rev7,
        patchSeq1Rev8Second,
        patchSeq1Rev9Second,
      ]),
      next([
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSFifth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksThird, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksThird, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksThird, stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84483, window: 200000, percent: 42.2415 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneDueNowSeq2Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        resetOf6ItemsSecond,
        stateIdle(dir),
      ]),
      nextResetOf5ItemsThird(dir),
      nextStateWithWorkingAndSinceThird(dir),
      nextResetOf1ItemsFourth(dir),
      dialogStep(dir),
      dialogStepSecond(dir),
      dialogStepThird(dir),
      expect({ on: { method: "POST", path: "/dialog", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", id: "00000000-0000-4000-8000-000000000004", value: "## 0.32\n\n- The sidebar shows status at the right and folds children\n- A program can show a webview page in its pane" }) }, reply: { status: 200, json: {} }, after: [
          { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
          { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 1, block: toolRelease }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
          { type: "item", item: { seq: 1, revision: 7, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFourth, stop: "toolUse", error: "", ended: 1794177120000 } },
          { type: "item", item: { seq: 1, revision: 8, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFourth, stop: "toolUse", error: "", ended: 1794177120000 } },
          { ...stateIdle(dir), working: true, context: { tokens: 84008, window: 200000, percent: 42.004000000000005 }, since: 1794177120000 },
          { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
          { type: "item", item: { seq: 2, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Released 0.32." }], stop: "stop", error: "", ended: 1794177120000 } },
          { ...stateIdle(dir), working: true, since: 1794177120000 },
          stateIdle(dir),
          stateIdle(dir),
        ] }),
    ],
    files: {},
  }),
  testKoaWebviewDialogs: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [
      nextStateWithWorkingAndSince(dir),
      nextAssistantEmptySeq1Rev1,
      nextPatchSeq1Rev3Second,
      next([
        { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [], final: true, stop: "stop", error: "", ended: 1794177120000 },
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        resetOf1ItemsSecond,
        stateIdle(dir),
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantTheSweepNeedsSeq1Rev2Second,
        assistantTheSweepNeedsSeq1Rev3Second,
        patchSeq1Rev4Fourth,
        patchSeq1Rev5,
        patchSeq1Rev6Second,
        patchSeq1Rev7,
        patchSeq1Rev8Second,
      ]),
      next([
        { type: "patch", seq: 1, baseRevision: 8, revision: 9, blocks: [{ index: 1, block: toolReadKoServerSrcThird }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSSixth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFifth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFifth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFifth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84483, window: 200000, percent: 42.2415 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneDueNowSeq2Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        resetOf6ItemsSecond,
        stateIdle(dir),
      ]),
      nextResetOf5ItemsThird(dir),
      nextStateWithWorkingAndSinceFourth(dir),
      nextResetOf1ItemsFourth(dir),
      dialogStep(dir),
      dialogStepSecond(dir),
      dialogStepThird(dir),
      expect({ on: { method: "POST", path: "/dialog", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", id: "00000000-0000-4000-8000-000000000004", value: "## 0.32\n\n- The sidebar shows status at the right and folds children\n- A program can show a webview page in its pane" }) }, reply: { status: 200, json: {} }, after: [
          { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
          { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 1, block: toolReleaseSecond }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
          { type: "item", item: { seq: 1, revision: 7, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSixth, stop: "toolUse", error: "", ended: 1794177120000 } },
          { type: "item", item: { seq: 1, revision: 8, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSixth, stop: "toolUse", error: "", ended: 1794177120000 } },
          { ...stateIdle(dir), working: true, context: { tokens: 84008, window: 200000, percent: 42.004000000000005 }, since: 1794177120000 },
        ] }),
    ],
    files: {},
  }),
  testKoaWebviewFocusBorderDialog: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [
      nextStateWithWorkingAndSince(dir),
      nextAssistantEmptySeq1Rev1,
      nextPatchSeq1Rev3Second,
      nextPatchSeq1Rev4(dir),
      next([
        patchSeq1Rev9Second,
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSSeventh }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSeventh, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSeventh, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSeventh, stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84483, window: 200000, percent: 42.2415 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneDueNowSeq2Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        resetOf6Items,
        stateIdle(dir),
      ]),
      nextResetOf5ItemsSecond(dir),
      nextStateWithWorkingAndSinceFourth(dir),
      nextResetOf1ItemsFourth(dir),
      dialogStep(dir),
      dialogStepSecond(dir),
    ],
    files: {},
  }),
};
