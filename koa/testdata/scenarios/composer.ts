import { next, expect, same, sequence, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";
import { stateIdle, modelsStep } from "../scenario-parts.ts";

const stateIdleSixth = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), context: { tokens: 84005, window: 200000, percent: 42.0025 } });

const stateIdleSeventh = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), context: { tokens: 84003, window: 200000, percent: 42.0015 } });

const stateFailed = (dir: string): Extract<PageRecord, { type: "state" }> => ({ pathEditor: false, view: { id: "00000000-0000-7000-8000-000000000001", path: [{ id: "00000000-0000-7000-8000-000000000001", name: "ko", type: "agent" }], type: 'root' }, threads: [], agents: [], bash: [], compaction: "idle", working: false, aborted: false, name: "pi", levels: [], cwd: `/private${dir}/home/Workspace/kido`, home: `${dir}/home`, dialogs: [], statuses: {}, queue: { steering: [], followUp: [] }, life: { type: "failed", at: 1794330720000, message: "Unknown provider \"nope\". Use --list-models to see available providers/models." }, type: "state" });

const stateIdleEighth = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), context: { tokens: 84008, window: 200000, percent: 42.004000000000005 } });

const stateIdleNinth = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), context: { tokens: 156003, window: 200000, percent: 78.00150000000001 } });

const recordsFromResetOf1ItemsFourth = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Run the unit stage", images: [], attachments: [] }], more: false },
  stateIdleSixth(dir),
]);

const resetOf1Items: PageRecord = { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Release 0.32", images: [], attachments: [] }], more: false };

const records = (dir: string): PageRecord[] => ([
  resetOf1Items,
  stateIdleSeventh(dir),
]);

const stepsFromNextNotifyExtensionReleaseTap = (dir: string): Step[] => ([
  next([
    { type: "item", item: { seq: 1, revision: 1, at: 1794330840000, final: true, kind: "notify", level: "error", text: { text: "extension release: tap checkout is dirty, refusing to commit", cut: 0 } } },
    { ...stateIdleSeventh(dir), working: true, since: 1794330840000 },
    { type: "item", item: { seq: 2, revision: 1, at: 1794330840000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    { type: "item", item: { seq: 2, revision: 2, at: 1794330840000, final: false, kind: "assistant", blocks: [{ type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794330840000 } },
    { type: "patch", seq: 2, baseRevision: 2, revision: 3, blocks: [{ index: 0, block: { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "running" }, started: 1794330840000 } }], final: false, stop: "toolUse", error: "", ended: 1794330840000 },
  ]),
  next([
    { type: "patch", seq: 2, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "running", result: { text: "", cut: 0, images: [] } }, started: 1794330840000 } }], final: false, stop: "toolUse", error: "", ended: 1794330840000 },
  ]),
]);

const assistantBashSeq1Rev2: PageRecord = { type: "item", item: { seq: 1, revision: 2, at: 1794330720000, final: false, kind: "assistant", blocks: [{ type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794330720000 } };

const patchSeq1Rev3Second: PageRecord = { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [{ index: 0, block: { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "running" }, started: 1794330720000 } }], final: false, stop: "toolUse", error: "", ended: 1794330720000 };

const patchSeq1Rev4Third: PageRecord = { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify STAGES=unit\"}", cut: 0 }, state: { type: "running", result: { text: "", cut: 0, images: [] } }, started: 1794330720000 } }], final: false, stop: "toolUse", error: "", ended: 1794330720000 };

const stepsFromNextStateWithWorkingAndSince = (dir: string): Step[] => ([
  next([
    { ...stateIdleSixth(dir), working: true, since: 1794330720000 },
    { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    assistantBashSeq1Rev2,
    patchSeq1Rev3Second,
  ]),
  next([
    patchSeq1Rev4Third,
  ]),
]);

const recordsFromResetOf1ItemsFifth = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Use Sonnet for the rest of this", images: [], attachments: [] }], more: false },
  stateIdleEighth(dir),
]);

const stepsFromNextNotifySwitchedToClaude: Step[] = [
  next([
    { type: "item", item: { seq: 1, revision: 1, at: 1794330780000, final: true, kind: "notify", level: "info", text: { text: "Switched to claude-sonnet-5-5 · thinking medium", cut: 0 } } },
  ]),
];

const stepsFromNextNothing: Step[] = [
  next([]),
  modelsStep,
];

const recordsSecond = (dir: string): PageRecord[] => ([
  resetOf1Items,
  stateIdleNinth(dir),
]);

const stepsFromNextStateWithWorkingAndSinceSecond = (dir: string): Step[] => ([
  next([
    { ...stateIdleNinth(dir), working: true, since: 1794330720000 },
    { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    { type: "item", item: { seq: 1, revision: 2, at: 1794330720000, final: false, kind: "assistant", blocks: [{ type: "text", text: "Which tap revision? (see the dialog)" }, { type: "tool", id: "call_1_0", name: "ask", args: { text: "{}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794330720000 } },
    { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [{ index: 1, block: { type: "tool", id: "call_1_0", name: "ask", args: { text: "{}", cut: 0 }, state: { type: "running" }, started: 1794330720000 } }], final: false, stop: "toolUse", error: "", ended: 1794330720000 },
    { ...stateIdleNinth(dir), working: true, dialogs: [{ id: "00000000-0000-4000-8000-000000000001", title: "Which tap revision?", method: "input" }], since: 1794330720000 },
  ]),
]);

const stepsFromNextStateWithWorkingAndSinceThird = (dir: string): Step[] => ([
  next([
    { ...stateIdleSixth(dir), working: true, since: 1794330720000 },
    { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    assistantBashSeq1Rev2,
    patchSeq1Rev3Second,
    patchSeq1Rev4Third,
  ]),
]);

const phases = {
  ComposerFootEditing: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: [
      next([]),
    ],
    files: {},
  }),
  ComposerFootErrorNotice: dir => ({
    open: records(dir),
    steps: stepsFromNextNotifyExtensionReleaseTap(dir),
    files: {},
  }),
  ComposerFootExited: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateFailed(dir),
    ],
    steps: [

    ],
    files: {},
  }),
  ComposerFootIdle: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: [
      next([]),
    ],
    files: {},
  }),
  ComposerFootLongWorking: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: stepsFromNextStateWithWorkingAndSince(dir),
    files: {},
  }),
  ComposerFootNotice: dir => ({
    open: recordsFromResetOf1ItemsFifth(dir),
    steps: stepsFromNextNotifySwitchedToClaude,
    files: {},
  }),
  ComposerFootPicker: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: stepsFromNextNothing,
    files: {},
  }),
  testKoaWebviewComposerFootResponsive: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: [
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/model", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "picker", kind: "model", search: "" } } } }),
      expect({ on: { method: "GET", path: "/models" }, reply: { status: 200, json: { models: [{ id: "claude-opus-5-5", provider: "anthropic" }] } } }),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/thinking", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "picker", kind: "thinking", search: "" } } } }),
      next([
        { ...stateIdleSixth(dir), working: true, since: 1794330720000 },
      ]),
      next([
        { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        assistantBashSeq1Rev2,
        patchSeq1Rev3Second,
        patchSeq1Rev4Third,
      ]),
    ],
    files: {},
  }),
  ComposerFootStatuses: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: [
      next([
        { ...stateIdleSixth(dir), statuses: { git: "↑2" } },
        { ...stateIdleSixth(dir), statuses: { git: "↑2", tests: "3 failing" } },
      ]),
    ],
    files: {},
  }),
  ComposerFootWaiting: dir => ({
    open: recordsSecond(dir),
    steps: stepsFromNextStateWithWorkingAndSinceSecond(dir),
    files: {},
  }),
  ComposerFootWorking: dir => ({
    open: recordsFromResetOf1ItemsFourth(dir),
    steps: stepsFromNextStateWithWorkingAndSinceThird(dir),
    files: {},
  }),
} satisfies Scenarios;

const order: (keyof typeof phases)[] = ["ComposerFootIdle", "ComposerFootWorking", "ComposerFootEditing", "ComposerFootPicker", "ComposerFootNotice", "ComposerFootErrorNotice", "ComposerFootLongWorking", "ComposerFootStatuses", "ComposerFootWaiting", "ComposerFootExited"];

export const scenarios: Scenarios = {
  ComposerFootStates: dir => sequence(order.map(key => phases[key](dir))),
  testKoaWebviewComposerFootResponsive: phases.testKoaWebviewComposerFootResponsive,
};
