import { next, expect, same, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord, WireItem } from "../../koa-records.ts";
import { stateIdleThird } from "../scenario-parts.ts";

const recordsFromResetOf1ItemsSecond = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }], more: false },
  stateIdleThird(dir),
]);

const recordsFromResetOf1ItemsThird = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }], more: false },
  stateIdleThird(dir),
]);

const bashMakeChecksDRY: WireItem = { seq: 1, revision: 0, at: 1794177120001, final: true, kind: "bash", command: "make checks DRY=1", excludeFromContext: false, result: { output: { text: "plan: lint-sh unit(ko_client) app visual(SidebarTests)\nunit: cargo test -p ko_client\napp: make -C app test\nvisual: make -C app visual VISUAL_ONLY=SidebarTests", cut: 0 }, cancelled: false, truncated: false, exit: 0 } };

const nextResetOf6Items = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch2", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, bashMakeChecksDRY, { seq: 2, revision: 0, at: 1794177120002, final: true, kind: "bash", command: "git status --short", excludeFromContext: true, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: false, truncated: false, exit: 0 } }, { seq: 3, revision: 0, at: 1794177120003, final: true, kind: "bash", command: "make verify STAGES=unit", excludeFromContext: false, result: { output: { text: "test result: FAILED. 1 failed; 212 passed\n---- model::place stays on the host pane ----\nassertion `left == right` failed\n  left: Some(Runtime(\"tools\"))\n right: None\nmake: *** [verify] Error 2", cut: 0 }, cancelled: false, truncated: false, exit: 2 } }, { seq: 4, revision: 0, at: 1794177120004, final: true, kind: "bash", command: "make e2e", excludeFromContext: false, result: { output: { text: "running 64 tests\n......................", cut: 0 }, cancelled: true, truncated: false, exit: 0 } }, { seq: 5, revision: 0, at: 1794177120005, final: true, kind: "bash", command: "find . -type f", excludeFromContext: false, result: { output: { text: "./AGENTS.md\n./Cargo.toml\n./Makefile\n./README.md", cut: 0 }, cancelled: false, truncated: true, exit: 0, fullOutputPath: "/tmp/pi-bash-abc123.log" } }], more: false },
  stateIdleThird(dir),
]));

const nextResetOf2ItemsSecond = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch3", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, bashMakeChecksDRY], more: false },
  stateIdleThird(dir),
]));

const nextResetOf2ItemsThird = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch4", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120003, final: true, kind: "bash", command: "make verify STAGES=unit", excludeFromContext: false, result: { output: { text: "test result: FAILED. 1 failed; 212 passed\n---- model::place stays on the host pane ----\nassertion `left == right` failed\n  left: Some(Runtime(\"tools\"))\n right: None\nmake: *** [verify] Error 2", cut: 0 }, cancelled: false, truncated: false, exit: 2 } }], more: false },
  stateIdleThird(dir),
]));

const nextResetOf2ItemsFourth = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch5", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120004, final: true, kind: "bash", command: "make e2e", excludeFromContext: false, result: { output: { text: "running 64 tests\n......................", cut: 0 }, cancelled: true, truncated: false, exit: 0 } }], more: false },
  stateIdleThird(dir),
]));

const nextResetOf2ItemsFifth = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch6", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120005, final: true, kind: "bash", command: "find . -type f", excludeFromContext: false, result: { output: { text: "./AGENTS.md\n./Cargo.toml\n./Makefile\n./README.md", cut: 0 }, cancelled: false, truncated: true, exit: 0, fullOutputPath: "/tmp/pi-bash-abc123.log" } }], more: false },
  stateIdleThird(dir),
]));

const nextResetOf2ItemsSixth = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch7", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120002, final: true, kind: "bash", command: "git status --short", excludeFromContext: true, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: false, truncated: false, exit: 0 } }], more: false },
  stateIdleThird(dir),
]));

const nextResetOf1ItemsSecond = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch8", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }], more: false },
  stateIdleThird(dir),
]));

const stateWithBash = (dir: string): PageRecord => ({ ...stateIdleThird(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "running", started: 1794177129000, output: { text: "", cut: 0 } }] });

const stateWithBashSecond = (dir: string): PageRecord => ({ ...stateIdleThird(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "running", started: 1794177129000, output: { text: "running 212 tests\ntest model::place_stays_on_host ... ok\ntest model::runtime_name ... ok\n......................", cut: 0 } }] });

const abortStep = (dir: string): Step => (expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, before: [
    { ...stateIdleThird(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "cancelling", started: 1794177129000, output: { text: "running 212 tests\ntest model::place_stays_on_host ... ok\ntest model::runtime_name ... ok\n......................", cut: 0 } }] },
  ], reply: { status: 200, json: {} }, after: [
    { ...stateIdleThird(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "completed", started: 1794177129000, ended: 1794177129000, result: { output: { text: "running 212 tests\ntest model::place_stays_on_host ... ok\ntest model::runtime_name ... ok\n......................", cut: 0 }, cancelled: true, truncated: false } }] },
    stateIdleThird(dir),
    { type: "reset", epoch: "epoch9", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177129000, final: true, kind: "bash", command: "make verify STAGES=unit", excludeFromContext: false, result: { output: { text: "running 212 tests\ntest model::place_stays_on_host ... ok\ntest model::runtime_name ... ok\n......................", cut: 0 }, cancelled: true, truncated: false } }], more: false },
  ] }));

const nextResetOf1ItemsThird = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch10", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }], more: false },
  stateIdleThird(dir),
  { ...stateIdleThird(dir), working: true, since: 1794177120000 },
]));

const assistantTheSweepNeedsSeq1Rev2: PageRecord = { type: "item", item: { seq: 1, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "text", text: "The sweep needs to distinguish a start failure from a program exit. Checking the close policy." }], stop: "pending", error: "" } };

const stateWithBashAndWorking = (dir: string): PageRecord => ({ ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "running", started: 1794177133000, output: { text: "", cut: 0 } }], working: true, since: 1794177120000 });

const stateWithBashAndWorkingSecond = (dir: string): PageRecord => ({ ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "running", started: 1794177133000, output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 } }], working: true, since: 1794177120000 });

const abortStepSecond = (dir: string): Step => (expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, before: [
    { ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "cancelling", started: 1794177133000, output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 } }], working: true, since: 1794177120000 },
  ], reply: { status: 200, json: {} }, after: [
    { ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "completed", started: 1794177133000, ended: 1794177134000, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: true, truncated: false } }], working: true, since: 1794177120000 },
  ] }));

const nextPatchSeq1Rev3 = (dir: string): Step => (next([
  { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [], final: true, stop: "stop", error: "", ended: 1794177134000 },
  { ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "completed", started: 1794177133000, ended: 1794177134000, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: true, truncated: false } }], working: true, context: { tokens: 84000, window: 200000, percent: 42 }, since: 1794177120000 },
  { ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "completed", started: 1794177133000, ended: 1794177134000, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: true, truncated: false } }], context: { tokens: 84000, window: 200000, percent: 42 } },
  { ...stateIdleThird(dir), bash: [{ id: "2", command: "git status --short", excludeFromContext: false, phase: "completed", started: 1794177133000, ended: 1794177134000, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: true, truncated: false } }], context: { tokens: 84028, window: 200000, percent: 42.014 } },
  { ...stateIdleThird(dir), context: { tokens: 84028, window: 200000, percent: 42.014 } },
  { type: "reset", epoch: "epoch11", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "The sweep needs to distinguish a start failure from a program exit. Checking the close policy." }], stop: "stop", error: "" }, { seq: 2, revision: 0, at: 1794177134000, final: true, kind: "bash", command: "git status --short", excludeFromContext: false, result: { output: { text: " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", cut: 0 }, cancelled: true, truncated: false } }], more: false },
]));

export const scenarios: Scenarios = {
  testKoaWebviewBangCompletionNarrow: dir => ({
    open: recordsFromResetOf1ItemsSecond(dir),
    steps: [

    ],
    files: {},
  }),
  testKoaWebviewBangCompletionWide: dir => ({
    open: recordsFromResetOf1ItemsSecond(dir),
    steps: [

    ],
    files: {},
  }),
  testKoaWebviewBangNarrow: dir => ({
    open: recordsFromResetOf1ItemsThird(dir),
    steps: [
      nextResetOf6Items(dir),
      nextResetOf2ItemsSecond(dir),
      nextResetOf2ItemsThird(dir),
      nextResetOf2ItemsFourth(dir),
      nextResetOf2ItemsFifth(dir),
      nextResetOf2ItemsSixth(dir),
      nextResetOf1ItemsSecond(dir),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "!make verify STAGES=unit", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          stateWithBash(dir),
          stateWithBashSecond(dir),
        ] }),
      abortStep(dir),
      nextResetOf1ItemsThird(dir),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "!git status --short", mode: "prompt", attachments: [] }) }, before: [
          { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
          assistantTheSweepNeedsSeq1Rev2,
          stateWithBashAndWorking(dir),
        ], reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          stateWithBashAndWorkingSecond(dir),
        ] }),
      abortStepSecond(dir),
      nextPatchSeq1Rev3(dir),
    ],
    files: {},
  }),
  testKoaWebviewBangWide: dir => ({
    open: recordsFromResetOf1ItemsThird(dir),
    steps: [
      nextResetOf6Items(dir),
      nextResetOf2ItemsSecond(dir),
      nextResetOf2ItemsThird(dir),
      nextResetOf2ItemsFourth(dir),
      nextResetOf2ItemsFifth(dir),
      nextResetOf2ItemsSixth(dir),
      nextResetOf1ItemsSecond(dir),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "!make verify STAGES=unit", mode: "prompt", attachments: [] }) }, before: [
          stateWithBash(dir),
        ], reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          stateWithBashSecond(dir),
        ] }),
      abortStep(dir),
      nextResetOf1ItemsThird(dir),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "!git status --short", mode: "prompt", attachments: [] }) }, before: [
          { type: "item", item: { seq: 1, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
          assistantTheSweepNeedsSeq1Rev2,
        ], reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          stateWithBashAndWorking(dir),
          stateWithBashAndWorkingSecond(dir),
        ] }),
      abortStepSecond(dir),
      nextPatchSeq1Rev3(dir),
    ],
    files: {},
  }),
};
