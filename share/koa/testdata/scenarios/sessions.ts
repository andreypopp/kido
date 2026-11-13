import { next, expect, same, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord, WireItem } from "../../koa-records.ts";
import { stateIdleFourth, assistantVerifiedEveryStageSeq1Rev0 } from "../scenario-parts.ts";

const recordsFromResetOf2ItemsSecond = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330719000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq1Rev0], more: false },
  stateIdleFourth(dir),
]);

const promptStepSixth: Step = expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/resume", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "session", kind: "resume" } } } });

const sessionsListStep = (dir: string): Step => (expect({ on: { method: "POST", path: "/sessions/list", body: value => same(value, { scope: "current" }) }, reply: { status: 200, json: { rows: [{ path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000001.jsonl`, id: "00000000-0000-7000-8000-000000000001", cwd: `${dir}/home/Workspace/kido`, name: "sidebar-right", firstMessage: "Hand the sidebar unit to an implementer and tell the reviewer when it builds", modified: 1794330720000, messageCount: 212 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl`, id: "00000000-0000-7000-8000-000000000002", cwd: `${dir}/home/Workspace/kido`, name: "koa-md", firstMessage: "Agent cards render Markdown; the queue goes above the field", modified: 1794327240000, messageCount: 96 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000003.jsonl`, id: "00000000-0000-7000-8000-000000000003", cwd: `${dir}/home/Workspace/kido`, firstMessage: "Why does ko_client::Model::place fail on the musl target only?", modified: 1794157920000, messageCount: 14 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000004.jsonl`, id: "00000000-0000-7000-8000-000000000004", cwd: `${dir}/home/Workspace/kido`, name: "runtimes-u4", firstMessage: "Design the runtime indicator for Kido.app and ko_tui", modified: 1794071520000, messageCount: 341 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000005.jsonl`, id: "00000000-0000-7000-8000-000000000005", cwd: `${dir}/home/Workspace/kido`, name: "release-0.31", firstMessage: "Release 0.31: Kido.app first, then ko", modified: 1793985120000, messageCount: 58 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000006.jsonl`, id: "00000000-0000-7000-8000-000000000006", cwd: `${dir}/home/Workspace/kido`, firstMessage: "Explain the view write path in ko_server::conn", modified: 1793898720000, messageCount: 9 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000007.jsonl`, id: "00000000-0000-7000-8000-000000000007", cwd: `${dir}/home/Workspace/kido`, name: "notices", firstMessage: "Redesign the sidebar errors as notices", modified: 1793812320000, messageCount: 187 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000008.jsonl`, id: "00000000-0000-7000-8000-000000000008", cwd: `${dir}/home/Workspace/kido`, name: "html-mockups", firstMessage: "koa webview mockups: streaming, runs, composer", modified: 1793725920000, messageCount: 402 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000009.jsonl`, id: "00000000-0000-7000-8000-000000000009", cwd: `${dir}/home/Workspace/kido`, name: "bench", firstMessage: "Why does allocations/record rise after the deflate change?", modified: 1793639520000, messageCount: 27 }] } } }));

const sessionsListStepSecond = (dir: string): Step => (expect({ on: { method: "POST", path: "/sessions/list", body: value => same(value, { scope: "all" }) }, reply: { status: 200, json: { rows: [{ path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000001.jsonl`, id: "00000000-0000-7000-8000-000000000001", cwd: `${dir}/home/Workspace/kido`, name: "sidebar-right", firstMessage: "Hand the sidebar unit to an implementer and tell the reviewer when it builds", modified: 1794330720000, messageCount: 212 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000010.jsonl`, id: "00000000-0000-7000-8000-000000000010", cwd: `${dir}/home/Workspace/pi-infer-questions`, name: "pi-infer-questions", firstMessage: "Train the option tagger on the new corpus", modified: 1794328920000, messageCount: 77 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl`, id: "00000000-0000-7000-8000-000000000002", cwd: `${dir}/home/Workspace/kido`, name: "koa-md", firstMessage: "Agent cards render Markdown; the queue goes above the field", modified: 1794327240000, messageCount: 96 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000003.jsonl`, id: "00000000-0000-7000-8000-000000000003", cwd: `${dir}/home/Workspace/kido`, firstMessage: "Why does ko_client::Model::place fail on the musl target only?", modified: 1794157920000, messageCount: 14 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000004.jsonl`, id: "00000000-0000-7000-8000-000000000004", cwd: `${dir}/home/Workspace/kido`, name: "runtimes-u4", firstMessage: "Design the runtime indicator for Kido.app and ko_tui", modified: 1794071520000, messageCount: 341 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000005.jsonl`, id: "00000000-0000-7000-8000-000000000005", cwd: `${dir}/home/Workspace/kido`, name: "release-0.31", firstMessage: "Release 0.31: Kido.app first, then ko", modified: 1793985120000, messageCount: 58 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000006.jsonl`, id: "00000000-0000-7000-8000-000000000006", cwd: `${dir}/home/Workspace/kido`, firstMessage: "Explain the view write path in ko_server::conn", modified: 1793898720000, messageCount: 9 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000007.jsonl`, id: "00000000-0000-7000-8000-000000000007", cwd: `${dir}/home/Workspace/kido`, name: "notices", firstMessage: "Redesign the sidebar errors as notices", modified: 1793812320000, messageCount: 187 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000008.jsonl`, id: "00000000-0000-7000-8000-000000000008", cwd: `${dir}/home/Workspace/kido`, name: "html-mockups", firstMessage: "koa webview mockups: streaming, runs, composer", modified: 1793725920000, messageCount: 402 }, { path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000009.jsonl`, id: "00000000-0000-7000-8000-000000000009", cwd: `${dir}/home/Workspace/kido`, name: "bench", firstMessage: "Why does allocations/record rise after the deflate change?", modified: 1793639520000, messageCount: 27 }] } } }));

const userAgentCardsRender: WireItem = { seq: 0, revision: 0, at: 1794327239000, final: true, kind: "user", text: "Agent cards render Markdown; the queue goes above the field", images: [], attachments: [] };

const assistantDoneTheCardsSeq1Rev0: WireItem = { seq: 1, revision: 0, at: 1794327240000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Done: the cards render through the reply's Markdown renderer, collapsed to one plain line." }], stop: "stop", error: "" };

const stateWithNameAndSessionId = (dir: string): PageRecord => ({ ...stateIdleFourth(dir), name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl` });

const sessionsSwitchStep = (dir: string): Step => (expect({ on: { method: "POST", path: "/sessions/switch", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", path: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl` }) }, before: [
    { ...stateIdleFourth(dir), pi: { type: "switching" } },
  ], reply: { status: 200, json: { cancelled: false }, hold: "session-switch" }, after: [
    { type: "reset", epoch: "epoch2", items: [userAgentCardsRender, assistantDoneTheCardsSeq1Rev0], more: false },
    stateWithNameAndSessionId(dir),
    { type: "item", item: { seq: 2, revision: 1, at: 1794330720000, final: true, kind: "notify", level: "info", text: { text: "session: koa-md · 96 messages", cut: 0 } } },
  ] }));

const promptStepSeventh = (dir: string): Step => (expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002", text: "!make verify STAGES=unit", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
    { ...stateIdleFourth(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "running", started: 1794330720000, output: { text: "", cut: 0 } }], name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl` },
    { ...stateIdleFourth(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "running", started: 1794330720000, output: { text: "running 212 tests", cut: 0 } }], name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl` },
  ] }));

const promptStepEighth: Step = expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002", text: "/resume", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "session", kind: "resume" } } } });

const abortStepThird = (dir: string): Step => (expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002" }) }, reply: { status: 200, json: {} }, after: [
    { ...stateIdleFourth(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "cancelling", started: 1794330720000, output: { text: "running 212 tests", cut: 0 } }], name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl` },
    { ...stateIdleFourth(dir), bash: [{ id: "1", command: "make verify STAGES=unit", excludeFromContext: false, phase: "completed", started: 1794330720000, ended: 1794330720000, result: { output: { text: "running 212 tests", cut: 0 }, cancelled: true, truncated: false } }], name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl` },
    stateWithNameAndSessionId(dir),
  ] }));

const stateWithWorkingAndName = (dir: string): PageRecord => ({ ...stateIdleFourth(dir), working: true, name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl`, since: 1794330720000 });

const nextResetOf4Items = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch3", items: [userAgentCardsRender, assistantDoneTheCardsSeq1Rev0, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "bash", command: "make verify STAGES=unit", excludeFromContext: false, result: { output: { text: "running 212 tests", cut: 0 }, cancelled: true, truncated: false } }, { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "info", text: { text: "session: koa-md · 96 messages", cut: 0 } }], more: false },
  stateWithWorkingAndName(dir),
  stateWithWorkingAndName(dir),
  { type: "item", item: { seq: 4, revision: 1, at: 1794330720000, final: true, kind: "user", text: "Explain how the sweep decides what to remove, with a table", images: [], attachments: [] } },
]));

const stateWithAbortedAndName = (dir: string): PageRecord => ({ ...stateIdleFourth(dir), aborted: true, name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl`, context: { tokens: 87940, window: 200000, percent: 43.97 } });

const recordsFromAssistantEmptySeq5Rev1 = (dir: string): PageRecord[] => ([
  { type: "item", item: { seq: 5, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "aborted", error: "Request aborted" } },
  { type: "patch", seq: 5, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "Request aborted", ended: 1794330720000 },
  { ...stateIdleFourth(dir), working: true, name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl`, context: { tokens: 87940, window: 200000, percent: 43.97 }, since: 1794330720000 },
  stateWithAbortedAndName(dir),
  stateWithAbortedAndName(dir),
]);

const promptStepNinth: Step = expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002", text: "/new", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "session", kind: "new" } } } });

const stateWithAbortedAndNameSecond = (dir: string): PageRecord => ({ ...stateIdleFourth(dir), aborted: true, name: "koa-md", sessionId: "00000000-0000-7000-8000-000000000002", sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl`, context: { tokens: 87940, window: 200000, percent: 43.97 }, pi: { type: "switching" } });

export const scenarios: Scenarios = {
  testKoaWebviewSessionsNarrow: dir => ({
    open: recordsFromResetOf2ItemsSecond(dir),
    steps: [
      promptStepSixth,
      sessionsListStep(dir),
      sessionsListStepSecond(dir),
      promptStepSixth,
      expect({ on: { method: "POST", path: "/sessions/list", body: value => same(value, { scope: "current" }) }, reply: { status: 200, json: { rows: [] } } }),
      sessionsSwitchStep(dir),
      promptStepSeventh(dir),
      promptStepEighth,
      abortStepThird(dir),
      nextResetOf4Items(dir),
      promptStepEighth,
      expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002" }) }, reply: { status: 200, json: {} }, after: recordsFromAssistantEmptySeq5Rev1(dir) }),
      promptStepNinth,
      expect({ on: { method: "POST", path: "/sessions/new", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002" }) }, before: [
          stateWithAbortedAndNameSecond(dir),
          { type: "reset", epoch: "epoch4", items: [], more: false },
          { ...stateIdleFourth(dir), name: "pi", sessionId: "01a1c671-f700-7441-a6d6-ea626b87c178", sessionFile: `${dir}/home/sessions/2026-11-10T17-12-00-000Z_01a1c671-f700-7441-a6d6-ea626b87c178.jsonl`, context: { tokens: 0, window: 200000, percent: 0 } },
          { type: "item", item: { seq: 0, revision: 1, at: 1794330720000, final: true, kind: "notify", level: "info", text: { text: "new session", cut: 0 } } },
        ], reply: { status: 200, json: { cancelled: false } } }),
    ],
    files: {},
  }),
  testKoaWebviewSessionsWide: dir => ({
    open: recordsFromResetOf2ItemsSecond(dir),
    steps: [
      promptStepSixth,
      sessionsListStep(dir),
      sessionsListStepSecond(dir),
      promptStepSixth,
      expect({ on: { method: "POST", path: "/sessions/list", body: value => same(value, { scope: "current" }) }, reply: { status: 200, json: { rows: [] } } }),
      sessionsSwitchStep(dir),
      promptStepSeventh(dir),
      promptStepEighth,
      abortStepThird(dir),
      nextResetOf4Items(dir),
      promptStepEighth,
      expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002" }) }, before: recordsFromAssistantEmptySeq5Rev1(dir), reply: { status: 200, json: {} } }),
      promptStepNinth,
      expect({ on: { method: "POST", path: "/sessions/new", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000002" }) }, before: [
          stateWithAbortedAndNameSecond(dir),
        ], reply: { status: 200, json: { cancelled: false } }, after: [
          { type: "reset", epoch: "epoch4", items: [], more: false },
          { ...stateIdleFourth(dir), name: "pi", sessionId: "01a1c671-f700-74e1-b629-76b5af5a18dd", sessionFile: `${dir}/home/sessions/2026-11-10T17-12-00-000Z_01a1c671-f700-74e1-b629-76b5af5a18dd.jsonl`, context: { tokens: 0, window: 200000, percent: 0 } },
          { type: "item", item: { seq: 0, revision: 1, at: 1794330720000, final: true, kind: "notify", level: "info", text: { text: "new session", cut: 0 } } },
        ] }),
    ],
    files: {},
  }),
};
