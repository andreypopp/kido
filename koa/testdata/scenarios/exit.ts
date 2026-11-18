import { next, type Scenarios } from "../scenario.ts";
import type { WireItem, Block, Text } from "../../koa-records.ts";
import { stateIdle, nextStateWithWorkingAndSince, nextAssistantEmptySeq1Rev1, nextPatchSeq1Rev3Second, userMakeTheSweep, resetOf1ItemsSecond, assistantTheSweepNeedsSeq1Rev2Second, thinkingTheSweepNeedsSecond, toolBashMakeCargoARGS, thinkingTheSweepNeedsThird, patchSeq1Rev4Fourth, patchSeq1Rev5, patchSeq1Rev7, toolBashMakeCargoARGSSecond, toolStateDone, toolStateDoneSecond, assistantDoneDueNowSeq2Rev2, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0, toolReadKoServerSrcSecond, patchSeq1Rev9Second, nextStateWithWorkingAndSinceFourth } from "../scenario-parts.ts";

const textFnDueSelf: Text = { text: "{\"oldText\":\"    fn due(&self, now: Instant) -> bool {\\n        self.exited && self.close == Close::Exit\\n    }\",\"path\":\"ko_server/src/sweep.rs\",\"newText\":\"    fn due(&self, now: Instant) -> bool {\\n        match self.close {\\n            Close::Exit => self.exited && !self.failed,\\n            Close::OnExit => self.dead_since.is_some_and(|t| now - t > self.linger),\\n        }\\n    }\"}", cut: 0 };

const toolEditThird: Block = { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelf, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177120000, ended: 1794177120000, durationMs: 2 };

const toolBashMakeCargoARGSEighth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 70 };

const blocksEighth: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEditThird,
  toolBashMakeCargoARGSEighth,
];

const assistantEditSeq3Rev0Third: WireItem = { seq: 3, revision: 0, at: 1794177126100, final: true, kind: "assistant", blocks: [{ type: "tool", id: "edit", name: "edit", args: textFnDueSelf, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177126100, ended: 1794177126300 }], stop: "toolUse", error: "" };

const toolEditFourth: Block = { type: "tool", id: "call_5_1", name: "edit", args: textFnDueSelf, state: { type: "done", result: { text: "Edit applied", cut: 0, images: [] }, error: false }, started: 1794177126000, ended: 1794177126000, durationMs: 1 };

const toolReadKoServerSrcFourth: Block = { type: "tool", id: "call_5_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: toolStateDone, started: 1794177126000, ended: 1794177126000, durationMs: 2 };

const toolBashMakeCargoARGSNinth: Block = { type: "tool", id: "call_5_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "done", result: { text: "Command aborted", cut: 0, images: [] }, error: true }, started: 1794177126000, ended: 1794177157000, durationMs: 8 };

const blocksFromThinkingWhereTheRule: Block[] = [
  { type: "thinking", text: "where the rule belongs", redacted: false, started: 1794177126000, ended: 1794177126000 },
  toolReadKoServerSrcFourth,
  toolEditFourth,
  toolBashMakeCargoARGSNinth,
];

export const scenarios: Scenarios = {
  testKoaWebviewExit: dir => ({
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
        { type: "item", item: { seq: 1, revision: 3, at: 1794177120000, final: false, kind: "assistant", blocks: [thinkingTheSweepNeedsSecond, { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelf, state: { type: "pending" } }, toolBashMakeCargoARGS], stop: "toolUse", error: "" } },
        patchSeq1Rev4Fourth,
        patchSeq1Rev5,
        { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 2, block: { type: "tool", id: "call_2_1", name: "edit", args: textFnDueSelf, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
        patchSeq1Rev7,
        { type: "patch", seq: 1, baseRevision: 7, revision: 8, blocks: [{ index: 2, block: toolEditThird }, { index: 3, block: toolBashMakeCargoARGSSecond }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
      ]),
      next([
        patchSeq1Rev9Second,
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSEighth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksEighth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksEighth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksEighth, stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84483, window: 200000, percent: 42.2415 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneDueNowSeq2Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        { type: "reset", epoch: "epoch3", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Third, assistantBashSeq4Rev0, assistantDoneDueNowSeq5Rev0], more: false },
        stateIdle(dir),
      ]),
      next([
        { type: "reset", epoch: "epoch4", items: [userMakeTheSweep, assistantTheSweepNeedsSeq1Rev0, assistantReadSeq2Rev0, assistantEditSeq3Rev0Third, assistantBashSeq4Rev0], more: false },
        stateIdle(dir),
      ]),
      nextStateWithWorkingAndSinceFourth(dir),
      next([
        { type: "reset", epoch: "epoch6", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Make the sweep keep a start failure, then run the whole unit stage", images: [], attachments: [] }], more: false },
        { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
      ]),
      next([
        { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        { type: "item", item: { seq: 1, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "thinking", text: "where the rule belongs", redacted: false }, { type: "tool", id: "call_5_0", name: "read", args: { text: "{}", cut: 0 }, state: { type: "pending" } }], stop: "pending", error: "" } },
        { type: "item", item: { seq: 1, revision: 3, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "thinking", text: "where the rule belongs", redacted: false, started: 1794177126000 }, { type: "tool", id: "call_5_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "pending" } }, { type: "tool", id: "call_5_1", name: "edit", args: textFnDueSelf, state: { type: "pending" } }, { type: "tool", id: "call_5_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "" } },
        { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: { type: "thinking", text: "where the rule belongs", redacted: false, started: 1794177126000, ended: 1794177126000 } }], final: false, stop: "toolUse", error: "", ended: 1794177126000 },
        { type: "patch", seq: 1, baseRevision: 4, revision: 5, blocks: [{ index: 1, block: { type: "tool", id: "call_5_0", name: "read", args: { text: "{\"path\":\"ko_server/src/sweep.rs\"}", cut: 0 }, state: { type: "running" }, started: 1794177126000 } }], final: false, stop: "toolUse", error: "", ended: 1794177126000 },
        { type: "patch", seq: 1, baseRevision: 5, revision: 6, blocks: [{ index: 2, block: { type: "tool", id: "call_5_1", name: "edit", args: textFnDueSelf, state: { type: "running" }, started: 1794177126000 } }], final: false, stop: "toolUse", error: "", ended: 1794177126000 },
        { type: "patch", seq: 1, baseRevision: 6, revision: 7, blocks: [{ index: 3, block: { type: "tool", id: "call_5_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "running" }, started: 1794177126000 } }], final: false, stop: "toolUse", error: "", ended: 1794177126000 },
        { type: "patch", seq: 1, baseRevision: 7, revision: 8, blocks: [{ index: 2, block: toolEditFourth }, { index: 3, block: { type: "tool", id: "call_5_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: { type: "running", result: { text: "", cut: 0, images: [] } }, started: 1794177126000 } }], final: false, stop: "toolUse", error: "", ended: 1794177126000 },
        { type: "patch", seq: 1, baseRevision: 8, revision: 9, blocks: [{ index: 1, block: toolReadKoServerSrcFourth }], final: false, stop: "toolUse", error: "", ended: 1794177126000 },
      ]),
      next([]),
      next([]),
      next([]),
      next([]),
      next([]),
      next([
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSNinth }], final: true, stop: "toolUse", error: "", ended: 1794177126000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFromThinkingWhereTheRule, stop: "toolUse", error: "", ended: 1794177126000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFromThinkingWhereTheRule, stop: "toolUse", error: "", ended: 1794177126000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksFromThinkingWhereTheRule, stop: "toolUse", error: "", ended: 1794177126000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84431, window: 200000, percent: 42.2155 }, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177157000, final: false, kind: "assistant", blocks: [], stop: "aborted", error: "This operation was aborted" } },
        { type: "patch", seq: 2, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "This operation was aborted", ended: 1794177157000 },
        { ...stateIdle(dir), working: true, context: { tokens: 84431, window: 200000, percent: 42.2155 }, since: 1794177120000 },
        { ...stateIdle(dir), aborted: true, context: { tokens: 84431, window: 200000, percent: 42.2155 } },
        { ...stateIdle(dir), aborted: true, context: { tokens: 84431, window: 200000, percent: 42.2155 } },
      ]),
    ],
    files: {},
  }),
};
