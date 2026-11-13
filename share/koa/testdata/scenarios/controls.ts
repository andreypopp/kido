import { next, expect, same, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord, Block } from "../../koa-records.ts";
import { stateIdle, modelsStep, nextStateWithWorkingAndSince, nextAssistantEmptySeq1Rev1, nextPatchSeq1Rev3Second, thinkingTheSweepNeedsThird, toolEdit, nextPatchSeq1Rev4, toolReadKoServerSrc, patchSeq1Rev9, toolStateDoneSecond, assistantDoneDueNowSeq2Rev2, resetOf6Items, nextResetOf5ItemsSecond, nextStateWithWorkingAndSinceSecond, toolReadKoServerSrcSecond, patchSeq1Rev9Second, nextStateWithWorkingAndSinceThird } from "../scenario-parts.ts";

const toolBashMakeCargoARGSThird: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 499 };

const blocks: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrc,
  toolEdit,
  toolBashMakeCargoARGSThird,
];

const nextResetOf2ItemsSeventh = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch6", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Release 0.32", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177070000, final: true, kind: "assistant", blocks: [{ type: "tool", id: "queue-read", name: "read", args: { text: "{\"path\":\"Makefile\"}", cut: 0 }, state: { type: "done", result: { text: "Read", cut: 0, images: [] }, error: false }, started: 1794177070000, ended: 1794177070100 }, { type: "tool", id: "queue-check", name: "bash", args: { text: "{\"command\":\"git status\"}", cut: 0 }, state: { type: "done", result: { text: "Clean", cut: 0, images: [] }, error: false }, started: 1794177070000, ended: 1794177071000 }], stop: "toolUse", error: "" }], more: false },
  { ...stateIdle(dir), aborted: true, context: { tokens: 87972, window: 200000, percent: 43.986 } },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
  { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
  { type: "item", item: { seq: 2, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "tool", id: "call_5_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794177120000 } },
  { type: "patch", seq: 2, baseRevision: 2, revision: 3, blocks: [{ index: 0, block: { type: "tool", id: "call_5_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "running" }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000, queue: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }], followUp: [] } },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000, queue: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }, { text: "use the tap's revision from the last release, not HEAD", attachments: [] }], followUp: [] } },
  { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000, queue: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }, { text: "use the tap's revision from the last release, not HEAD", attachments: [] }], followUp: [{ text: "then draft the release notes from the commits since 0.31", attachments: [] }] } },
  { type: "patch", seq: 2, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: { type: "tool", id: "call_5_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "running", result: { text: "", cut: 0, images: [] } }, started: 1794177120000 } }], final: false, stop: "toolUse", error: "", ended: 1794177120000 },
]));

const toolBashMakeVerifyThird: Block = { type: "tool", id: "call_5_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "done", result: { text: "Passed", cut: 0, images: [] }, error: false }, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 149 };

const assistantDoneSeq3Rev2: PageRecord = { type: "item", item: { seq: 3, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Done." }], stop: "stop", error: "", ended: 1794177120000 } };

const nextStateWithStatuses = (dir: string): Step => (next([
  { ...stateIdle(dir), statuses: { git: "↑2" } },
  { ...stateIdle(dir), statuses: { git: "↑2", tests: "3 failing" } },
  { type: "item", item: { seq: 0, revision: 1, at: 1794177120000, final: true, kind: "notify", level: "info", text: { text: "Worktree ~/Workspace/kido-release created", cut: 0 } } },
]));

const nextStateWithStatusesSecond = (dir: string): Step => (next([
  { ...stateIdle(dir), statuses: { git: "↑2" } },
  { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: true, kind: "notify", level: "warning", text: { text: "Context at 78%, compaction soon", cut: 0 } } },
  { ...stateIdle(dir), working: true, statuses: { git: "↑2" }, since: 1794177120000 },
]));

const nextAssistantEmptySeq2Rev1 = (dir: string): Step => (next([
  { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
  { type: "patch", seq: 2, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "stop", error: "", ended: 1794177120000 },
  { ...stateIdle(dir), working: true, statuses: { git: "↑2" }, since: 1794177120000 },
  { ...stateIdle(dir), statuses: { git: "↑2" } },
  { ...stateIdle(dir), statuses: { git: "↑2" } },
  stateIdle(dir),
  { type: "item", item: { seq: 3, revision: 1, at: 1794177120000, final: true, kind: "notify", level: "error", text: { text: "extension release: tap checkout is dirty, refusing to commit", cut: 0 } } },
]));

const toolBashMakeCargoARGSFourth: Block = { type: "tool", id: "call_2_2", name: "bash", args: { text: "{\"command\":\"make cargo ARGS='test -p ko_server sweep'\"}", cut: 0 }, state: toolStateDoneSecond, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 125 };

const blocksSecond: Block[] = [
  thinkingTheSweepNeedsThird,
  toolReadKoServerSrcSecond,
  toolEdit,
  toolBashMakeCargoARGSFourth,
];

const toolBashMakeVerifyFourth: Block = { type: "tool", id: "call_5_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "done", result: { text: "Passed", cut: 0, images: [] }, error: false }, started: 1794177120000, exit: 0, ended: 1794177120000, durationMs: 143 };

export const scenarios: Scenarios = {
  testKoaWebviewControls: dir => ({
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
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSThird }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocks, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocks, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocks, stop: "toolUse", error: "", ended: 1794177120000 } },
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
      nextResetOf2ItemsSeventh(dir),
      expect({ on: { method: "POST", path: "/queue/clear", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, reply: { status: 200, json: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }, { text: "use the tap's revision from the last release, not HEAD", attachments: [] }], followUp: [{ text: "then draft the release notes from the commits since 0.31", attachments: [] }] } }, after: [
          { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
          { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
        ] }),
      next([
        { type: "patch", seq: 2, baseRevision: 4, revision: 5, blocks: [{ index: 0, block: toolBashMakeVerifyThird }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 6, at: 1794177120000, final: true, kind: "assistant", blocks: [toolBashMakeVerifyThird], stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84002, window: 200000, percent: 42.001 }, since: 1794177120000 },
        { type: "item", item: { seq: 3, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneSeq3Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        { type: "reset", epoch: "epoch7", items: [], more: false },
        stateIdle(dir),
      ]),
      modelsStep,
      nextStateWithStatuses(dir),
      nextStateWithStatusesSecond(dir),
      nextAssistantEmptySeq2Rev1(dir),
    ],
    files: {},
  }),
  testKoaWebviewNarrowControls: dir => ({
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
        { type: "patch", seq: 1, baseRevision: 9, revision: 10, blocks: [{ index: 3, block: toolBashMakeCargoARGSFourth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 1, revision: 11, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSecond, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 12, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSecond, stop: "toolUse", error: "", ended: 1794177120000 } },
        { type: "item", item: { seq: 1, revision: 13, at: 1794177120000, final: true, kind: "assistant", blocks: blocksSecond, stop: "toolUse", error: "", ended: 1794177120000 } },
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
      nextStateWithWorkingAndSinceThird(dir),
      nextResetOf2ItemsSeventh(dir),
      expect({ on: { method: "POST", path: "/queue/clear", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, before: [
          { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
        ], reply: { status: 200, json: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }, { text: "use the tap's revision from the last release, not HEAD", attachments: [] }], followUp: [{ text: "then draft the release notes from the commits since 0.31", attachments: [] }] } }, after: [
          { ...stateIdle(dir), working: true, context: { tokens: 87972, window: 200000, percent: 43.986 }, since: 1794177120000 },
        ] }),
      next([
        { type: "patch", seq: 2, baseRevision: 4, revision: 5, blocks: [{ index: 0, block: toolBashMakeVerifyFourth }], final: true, stop: "toolUse", error: "", ended: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 6, at: 1794177120000, final: true, kind: "assistant", blocks: [toolBashMakeVerifyFourth], stop: "toolUse", error: "", ended: 1794177120000 } },
        { ...stateIdle(dir), working: true, context: { tokens: 84002, window: 200000, percent: 42.001 }, since: 1794177120000 },
        { type: "item", item: { seq: 3, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantDoneSeq3Rev2,
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        stateIdle(dir),
        stateIdle(dir),
        { type: "reset", epoch: "epoch7", items: [], more: false },
        stateIdle(dir),
      ]),
      modelsStep,
      nextStateWithStatuses(dir),
      nextStateWithStatusesSecond(dir),
      nextAssistantEmptySeq2Rev1(dir),
    ],
    files: {},
  }),
};
