import { next, type Step, type Scenarios } from "../scenario.ts";
import type { WireItem, Block, Text } from "../../koa-records.ts";
import { stateIdle, modelsStep, userExplainHowThe, nextStateWithWorkingAndSince, assistantWhatTheSweepSeq1Rev2, nextAssistantEmptySeq1Rev1, nextPatchSeq1Rev3Second, userMakeTheSweep, resetOf1ItemsSecond, assistantTheSweepNeedsSeq1Rev2Second, thinkingTheSweepNeedsSecond, toolBashMakeCargoARGS, assistantTheSweepNeedsSeq1Rev3, thinkingTheSweepNeedsThird, patchSeq1Rev4Fourth, patchSeq1Rev5, patchSeq1Rev6, patchSeq1Rev7, toolEdit, toolBashMakeCargoARGSSecond, patchSeq1Rev8, nextPatchSeq1Rev4, toolReadKoServerSrc, patchSeq1Rev9, toolStateDoneSecond, assistantDoneDueNowSeq2Rev2, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0, resetOf6Items, nextResetOf5ItemsSecond, assistantEmptySeq5Rev1, assistantReadSeq1Rev0Second, assistantBashSeq2Rev0Second, assistantTheLingerTestSeq3Rev0, nextStateWithWorkingAndSinceSecond, toolReadKoServerSrcSecond, patchSeq1Rev9Second, nextStateWithWorkingAndSinceThird, nextStateWithWorkingAndSinceFourth } from "../scenario-parts.ts";

const stepsFromModelsStep: Step[] = [
  modelsStep,
];

const textFnDueSelfSecond: Text = { text: "{\"oldText\":\"    fn due(&self, now: Instant) -> bool {\\n        self.exited && self.close == Close::Exit\\n    }\",\"newText\":\"    fn due(&self, now: Instant) -> bool {\\n        match self.close {\\n            Close::Exit => self.exited && !self.failed,\\n            Close::OnExit => self.dead_since.is_some_and(|t| now - t > self.linger),\\n        }\\n    }\",\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 };

const toolEditFifth: Block = { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelfSecond, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 2 };

const toolBashMakeCargoARGSTenth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 182 };

const blocksNinth: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEditFifth,
  toolBashMakeCargoARGSTenth,
];

const assistantEditSeq3Rev0Fourth: WireItem = { seq: 3, revision: 0, at: 1794177126100, final: true, kind: "assistant", blocks: [{ type: "tool", id: "edit", name: "edit", args: textFnDueSelfSecond, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177126100, ended: 1794177126300 }], stop: "toolUse", error: "" };

const textFnDueSelfThird: Text = { text: "{\"newText\":\"    fn due(&self, now: Instant) -> bool {\\n        match self.close {\\n            Close::Exit => self.exited && !self.failed,\\n            Close::OnExit => self.dead_since.is_some_and(|t| now - t > self.linger),\\n        }\\n    }\",\"path\":\"ko_server/src/sweep.rs\",\"oldText\":\"    fn due(&self, now: Instant) -> bool {\\n        self.exited && self.close == Close::Exit\\n    }\"}", cut: 0 };

const toolEditSixth: Block = { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelfThird, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 2 };

const toolBashMakeCargoARGSEleventh: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 47 };

const blocksTenth: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEditSixth,
  toolBashMakeCargoARGSEleventh,
];

const assistantEditSeq3Rev0Fifth: WireItem = { seq: 3, revision: 0, at: 1794177126100, final: true, kind: "assistant", blocks: [{ type: "tool", id: "edit", name: "edit", args: textFnDueSelfThird, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177126100, ended: 1794177126300 }], stop: "toolUse", error: "" };

const toolBashMakeCargoARGSTwelfth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 52 };

const blocksEleventh: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrc,
  toolEdit,
  toolBashMakeCargoARGSTwelfth,
];

const toolBashMakeCargoARGSThirteenth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 118 };

const blocksTwelfth: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEdit,
  toolBashMakeCargoARGSThirteenth,
];

export const scenarios: Scenarios = {
  testKoaWebviewComposerFocus: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [
      nextStateWithWorkingAndSince(dir),
      nextAssistantEmptySeq1Rev1,
    ],
    files: {},
  }),
  testKoaWebviewComposerStateGeometryNarrow: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: stepsFromModelsStep,
    files: {},
  }),
  testKoaWebviewComposerStateGeometryWide: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: stepsFromModelsStep,
    files: {},
  }),
  testKoaWebviewErrorState: dir => ({
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
        { type: "item", item: { seq: 1, revision: 3, at: 1794177120000, final: false, kind: "assistant", blocks: [thinkingTheSweepNeedsSecond, { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelfSecond, state: { type: "pending" } }, toolBashMakeCargoARGS], stop: "toolUse", error: "" } },
        patchSeq1Rev4Fourth,
        patchSeq1Rev5,
        { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 2, block: { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelfSecond, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
        patchSeq1Rev7,
        { type: "patch", seq: 1, baseRevision: 7, revision: 8, blocks: [{ index: 2, block: toolEditFifth }, { index: 3, block: toolBashMakeCargoARGSSecond }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
      ]),
      next([
        patchSeq1Rev9Second,
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSTenth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksNinth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksNinth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksNinth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84483, window: 200000, percent: 42.2415 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneDueNowSeq2Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        { type: "reset", epoch: "epoch3", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Fourth, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0], more: false },
        stateIdle(dir),
      ]),
      next([
        { type: "reset", epoch: "epoch4", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Fourth, assistantBashSeq4Rev0], more: false },
        stateIdle(dir),
      ]),
      nextStateWithWorkingAndSinceThird(dir),
    ],
    files: {},
  }),
  testKoaWebviewFocusBorderTranscript: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [
      next([]),
      next([
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        userExplainHowThe,
        { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantWhatTheSweepSeq1Rev2,
      ]),
    ],
    files: {},
  }),
  testKoaWebviewMockupStates: dir => ({
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
        { type: "item", item: { seq: 1, revision: 3, at: 1794177120000, final: false, kind: "assistant", blocks: [thinkingTheSweepNeedsSecond, { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelfThird, state: { type: "pending" } }, toolBashMakeCargoARGS], stop: "toolUse", error: "" } },
        patchSeq1Rev4Fourth,
        patchSeq1Rev5,
        { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 2, block: { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelfThird, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
        patchSeq1Rev7,
        { type: "patch", seq: 1, baseRevision: 7, revision: 8, blocks: [{ index: 2, block: toolEditSixth }, { index: 3, block: toolBashMakeCargoARGSSecond }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
      ]),
      next([
        patchSeq1Rev9Second,
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSEleventh }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksTenth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksTenth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksTenth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84483, window: 200000, percent: 42.2415 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneDueNowSeq2Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        { type: "reset", epoch: "epoch3", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Fifth, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0], more: false },
        stateIdle(dir),
      ]),
      next([
        { type: "reset", epoch: "epoch4", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Fifth, assistantBashSeq4Rev0], more: false },
        stateIdle(dir),
      ]),
      nextStateWithWorkingAndSinceFourth(dir),
    ],
    files: {},
  }),
  testKoaWebviewNarrowStates: dir => ({
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
        patchSeq1Rev9,
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSTwelfth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksEleventh, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksEleventh, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksEleventh, stop: "toolUse", error: "", ended: 1794177120000 } },
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
      next([
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        assistantEmptySeq5Rev1,
        { type: "patch", seq: 5, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "Request aborted", ended: 1794177120000 },
        { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
        { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
        { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
        { type: "reset", epoch: "epoch5", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Run the whole unit stage", images: [], attachments: [] }, assistantReadSeq1Rev0Second, assistantBashSeq2Rev0Second, assistantTheLingerTestSeq3Rev0, { seq: 4, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "thinking", text: "the order in sweep()", redacted: false }, { type: "tool", id: "abort", name: "edit", args: { text: "{\"newText\":\"\",\"path\":\"ko_server/src/sweep.rs\",\"oldText\":\"\"}", cut: 0 }, state: { type: "not_run" }, started: 1794177120000 }], stop: "aborted", error: "" }], more: false },
        { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
      ]),
    ],
    files: {},
  }),
  testKoaWebviewShortStates: dir => ({
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
        assistantTheSweepNeedsSeq1Rev3,
        patchSeq1Rev4Fourth,
        patchSeq1Rev5,
        patchSeq1Rev6,
        patchSeq1Rev7,
        patchSeq1Rev8,
        patchSeq1Rev9Second,
      ]),
      next([
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSThirteenth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksTwelfth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksTwelfth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksTwelfth, stop: "toolUse", error: "", ended: 1794177120000 } },
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
      nextStateWithWorkingAndSinceSecond(dir),
    ],
    files: {},
  }),
};
