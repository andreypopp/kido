import { next, expect, same, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord, WireItem } from "../../koa-records.ts";
import { textTheSessionVerified, textReadAndChange, stateIdleFourth, assistantVerifiedEveryStageSeq1Rev0 } from "../scenario-parts.ts";

const recordsFromResetOf2Items = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq1Rev0], more: false },
  stateIdleFourth(dir),
]);

const promptStep: Step = expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/copy", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
    { type: "item", item: { seq: 2, revision: 1, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } } },
  ] });

const promptStepSecond = (dir: string): Step => (expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: `/export ${dir}/home/export.html`, mode: "prompt", attachments: [] }) }, before: [
    { type: "item", item: { seq: 3, revision: 1, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: `${dir}/home/export.html` } } },
  ], reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } } }));

const promptStepThird: Step = expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/settings", mode: "prompt", attachments: [] }) }, before: [
    { type: "item", item: { seq: 4, revision: 1, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } } },
  ], reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } } });

const promptStepFourth = (dir: string): Step => (expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/compact", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
    { type: "item", item: { seq: 6, revision: 1, at: 1794330720000, final: false, kind: "command", result: { type: "compaction", state: { type: "running" } } } },
    { ...stateIdleFourth(dir), compaction: "running", working: true, since: 1794330720000 },
  ] }));

const commandCompactionFourth: PageRecord = { type: "item", item: { seq: 6, revision: 2, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "done", before: 84000, after: 105, summary: textTheSessionVerified } } } };

const commandCompaction: WireItem = { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "done", before: 84000, after: 105, summary: textTheSessionVerified } } };

const assistantVerifiedEveryStageSeq7Rev0: WireItem = { seq: 7, revision: 0, at: 1794330720000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Verified: every stage passes. The snapshots that changed are the twelve of SidebarTests." }], stop: "stop", error: "" };

const commandSession = (dir: string): WireItem => ({ seq: 5, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "session", stats: { sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000001.jsonl`, sessionId: "00000000-0000-7000-8000-000000000001", userMessages: 7, assistantMessages: 16, toolCalls: 9, toolResults: 8, totalMessages: 31, tokens: { input: 1343840, output: 160, cacheRead: 0, cacheWrite: 0, total: 1344000 }, cost: 0, contextUsage: { tokens: 84000, contextWindow: 200000, percent: 42 } }, name: "sidebar-right", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high" } });

const commandCompactionSecond: WireItem = { seq: 6, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "done", before: 84000, after: 105, summary: textTheSessionVerified } } };

const promptStepFifth = (dir: string): Step => (expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/compact", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
    { type: "item", item: { seq: 7, revision: 1, at: 1794330720000, final: false, kind: "command", result: { type: "compaction", state: { type: "running" } } } },
    { ...stateIdleFourth(dir), compaction: "running", working: true, context: { tokens: null, window: 200000, percent: null }, since: 1794330720000 },
  ] }));

const commandCompactionFifth: PageRecord = { type: "item", item: { seq: 7, revision: 2, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "cancelled" } } } };

const itemsFromUserVerifyTheSidebar = (dir: string): WireItem[] => ([
  { seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] },
  assistantVerifiedEveryStageSeq1Rev0,
  { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } },
  { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: `${dir}/home/export.html` } },
  { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } },
  commandSession(dir),
  commandCompactionSecond,
  { seq: 7, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "cancelled" } } },
]);

const commandCompactionSixth: PageRecord = { type: "item", item: { seq: 8, revision: 1, at: 1794330720000, final: false, kind: "command", result: { type: "compaction", state: { type: "running" } } } };

const commandCompactionSeventh: PageRecord = { type: "item", item: { seq: 8, revision: 2, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "failed", message: "Compaction failed: Summarization failed: 500: {\"message\":\"scripted 500\"}" } } } };

const commandCompactionThird: WireItem = { seq: 8, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "failed", message: "Compaction failed: Summarization failed: 500: {\"message\":\"scripted 500\"}" } } };

const completeStep: Step = expect({ on: { method: "POST", path: "/complete", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/", pos: 1 }) }, reply: { status: 200, json: { type: "prompt", from: 0, to: 1, options: [{ label: "/model", detail: "Select model (opens selector UI)", insert: "/model ", kind: "command", source: "builtin", matched: [] }, { label: "/thinking", detail: "Set thinking level", insert: "/thinking ", kind: "command", source: "builtin", matched: [] }, { label: "/compact", detail: "Manually compact the session context", insert: "/compact ", kind: "command", source: "builtin", matched: [] }, { label: "/session", detail: "Show session info and stats", insert: "/session ", kind: "command", source: "builtin", matched: [] }, { label: "/copy", detail: "Copy last agent message to clipboard", insert: "/copy ", kind: "command", source: "builtin", matched: [] }, { label: "/export", detail: "Export session as HTML", insert: "/export ", kind: "command", source: "builtin", matched: [] }, { label: "/name", detail: "Set session display name", insert: "/name ", kind: "command", source: "builtin", matched: [] }, { label: "/resume", detail: "Resume another session", insert: "/resume ", kind: "command", source: "builtin", matched: [] }, { label: "/new", detail: "Start a new session", insert: "/new ", kind: "command", source: "builtin", matched: [] }, { label: "/quit", detail: "Quit pi", insert: "/quit ", kind: "command", source: "builtin", matched: [] }, { label: "/reload", detail: "Reload extensions, settings and koa", insert: "/reload ", kind: "command", source: "builtin", matched: [] }, { label: "/restart", detail: "Restart koa on this session", insert: "/restart ", kind: "command", source: "builtin", matched: [] }, { label: "/vstep", detail: "Run one step of a visual test", insert: "/vstep ", kind: "command", source: "extension", matched: [] }, { label: "/release", detail: "Release Kido.app first, then ko", insert: "/release ", kind: "command", source: "extension", matched: [] }, { label: "/skill:ko", detail: textReadAndChange, insert: "/skill:ko ", kind: "command", source: "skill", matched: [] }] } } });

const commandExport: WireItem = { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: "pi-session-2026-11-13T17-10-38-067Z_01a1d5e3-caf3-71be-9f36-2bc3bb39b961.html" } };

const commandSessionSecond: WireItem = { seq: 5, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "session", stats: { sessionFile: "/tmp/ko-vt-Z1hVhg/sessions/2026-11-13T17-10-38-067Z_01a1d5e3-caf3-71be-9f36-2bc3bb39b961.jsonl", sessionId: "01a1d5e3-caf3-71be-9f36-2bc3bb39b961", userMessages: 7, assistantMessages: 16, toolCalls: 9, toolResults: 8, totalMessages: 31, tokens: { input: 1343840, output: 160, cacheRead: 0, cacheWrite: 0, total: 1344000 }, cost: 0, contextUsage: { tokens: 84000, contextWindow: 200000, percent: 42 } }, name: "sidebar-right", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high" } };

const itemsFromUserVerifyTheSidebarSecond: WireItem[] = [
  { seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] },
  assistantVerifiedEveryStageSeq1Rev0,
  { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } },
  commandExport,
  { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } },
  commandSessionSecond,
  commandCompactionSecond,
  { seq: 7, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "cancelled" } } },
];

export const scenarios: Scenarios = {
  testKoaWebviewCommandsWide: dir => ({
    open: recordsFromResetOf2Items(dir),
    steps: [
      promptStep,
      promptStepSecond(dir),
      promptStepThird,
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/session", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          { type: "item", item: { seq: 5, revision: 1, at: 1794330720000, final: true, kind: "command", result: { type: "session", stats: { sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000001.jsonl`, sessionId: "00000000-0000-7000-8000-000000000001", userMessages: 7, assistantMessages: 16, toolCalls: 9, toolResults: 8, totalMessages: 31, tokens: { input: 1343840, output: 160, cacheRead: 0, cacheWrite: 0, total: 1344000 }, cost: 0, contextUsage: { tokens: 84000, contextWindow: 200000, percent: 42 } }, name: "sidebar-right", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high" } } },
        ] }),
      promptStepFourth(dir),
      next([
        commandCompactionFourth,
        stateIdleFourth(dir),
        { type: "reset", epoch: "epoch2", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } }, { seq: 1, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: `${dir}/home/export.html` } }, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } }, { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "session", stats: { sessionFile: `${dir}/home/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000001.jsonl`, sessionId: "00000000-0000-7000-8000-000000000001", userMessages: 7, assistantMessages: 16, toolCalls: 9, toolResults: 8, totalMessages: 31, tokens: { input: 1343840, output: 160, cacheRead: 0, cacheWrite: 0, total: 1344000 }, cost: 0, contextUsage: { tokens: 84000, contextWindow: 200000, percent: 42 } }, name: "sidebar-right", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high" } }, commandCompaction, { seq: 5, revision: 0, at: 1794591900000, final: true, kind: "summary", source: "compaction", text: textTheSessionVerified }, { seq: 6, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq7Rev0], more: false },
        { ...stateIdleFourth(dir), context: { tokens: null, window: 200000, percent: null } },
      ]),
      next([
        { type: "reset", epoch: "epoch3", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq1Rev0, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } }, { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: `${dir}/home/export.html` } }, { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } }, commandSession(dir), commandCompactionSecond], more: false },
        { ...stateIdleFourth(dir), context: { tokens: null, window: 200000, percent: null } },
      ]),
      promptStepFifth(dir),
      expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, reply: { status: 200, json: {} }, after: [
          commandCompactionFifth,
          { ...stateIdleFourth(dir), context: { tokens: null, window: 200000, percent: null } },
          { type: "reset", epoch: "epoch4", items: itemsFromUserVerifyTheSidebar(dir), more: false },
          stateIdleFourth(dir),
        ] }),
      next([
        { type: "reset", epoch: "epoch5", items: itemsFromUserVerifyTheSidebar(dir), more: false },
        stateIdleFourth(dir),
      ]),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/compact", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          commandCompactionSixth,
          { ...stateIdleFourth(dir), compaction: "running", working: true, since: 1794330720000 },
          commandCompactionSeventh,
          stateIdleFourth(dir),
          { type: "reset", epoch: "epoch6", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq1Rev0, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } }, { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: `${dir}/home/export.html` } }, { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } }, commandSession(dir), commandCompactionSecond, { seq: 7, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "cancelled" } } }, commandCompactionThird], more: false },
          stateIdleFourth(dir),
        ] }),
      completeStep,
    ],
    files: {},
  }),
  testKoaWebviewCommandsNarrow: dir => ({
    open: recordsFromResetOf2Items(dir),
    steps: [
      promptStep,
      promptStepSecond(dir),
      next([
        { type: "item", item: { seq: 3, revision: 2, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: "pi-session-2026-11-13T17-10-38-067Z_01a1d5e3-caf3-71be-9f36-2bc3bb39b961.html" } } },
      ]),
      promptStepThird,
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/session", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          { type: "item", item: { seq: 5, revision: 1, at: 1794330720000, final: true, kind: "command", result: { type: "session", stats: { sessionFile: "/tmp/ko-vt-Z1hVhg/sessions/2026-11-13T17-10-38-067Z_01a1d5e3-caf3-71be-9f36-2bc3bb39b961.jsonl", sessionId: "01a1d5e3-caf3-71be-9f36-2bc3bb39b961", userMessages: 7, assistantMessages: 16, toolCalls: 9, toolResults: 8, totalMessages: 31, tokens: { input: 1343840, output: 160, cacheRead: 0, cacheWrite: 0, total: 1344000 }, cost: 0, contextUsage: { tokens: 84000, contextWindow: 200000, percent: 42 } }, name: "sidebar-right", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high" } } },
        ] }),
      promptStepFourth(dir),
      next([
        commandCompactionFourth,
        stateIdleFourth(dir),
        { type: "reset", epoch: "epoch2", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } }, { seq: 1, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "export", path: "pi-session-2026-11-13T17-10-38-067Z_01a1d5e3-caf3-71be-9f36-2bc3bb39b961.html" } }, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } }, { seq: 3, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "session", stats: { sessionFile: "/tmp/ko-vt-Z1hVhg/sessions/2026-11-13T17-10-38-067Z_01a1d5e3-caf3-71be-9f36-2bc3bb39b961.jsonl", sessionId: "01a1d5e3-caf3-71be-9f36-2bc3bb39b961", userMessages: 7, assistantMessages: 16, toolCalls: 9, toolResults: 8, totalMessages: 31, tokens: { input: 1343840, output: 160, cacheRead: 0, cacheWrite: 0, total: 1344000 }, cost: 0, contextUsage: { tokens: 84000, contextWindow: 200000, percent: 42 } }, name: "sidebar-right", model: { provider: "anthropic", id: "claude-opus-5-5" }, thinking: "high" } }, commandCompaction, { seq: 5, revision: 0, at: 1794589840000, final: true, kind: "summary", source: "compaction", text: textTheSessionVerified }, { seq: 6, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq7Rev0], more: false },
        { ...stateIdleFourth(dir), context: { tokens: null, window: 200000, percent: null } },
      ]),
      next([
        { type: "reset", epoch: "epoch3", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq1Rev0, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } }, commandExport, { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } }, commandSessionSecond, commandCompactionSecond], more: false },
        { ...stateIdleFourth(dir), context: { tokens: null, window: 200000, percent: null } },
      ]),
      promptStepFifth(dir),
      expect({ on: { method: "POST", path: "/abort", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, reply: { status: 200, json: {} }, after: [
          commandCompactionFifth,
          { ...stateIdleFourth(dir), context: { tokens: null, window: 200000, percent: null } },
          { type: "reset", epoch: "epoch4", items: itemsFromUserVerifyTheSidebarSecond, more: false },
          stateIdleFourth(dir),
        ] }),
      next([
        { type: "reset", epoch: "epoch5", items: itemsFromUserVerifyTheSidebarSecond, more: false },
        stateIdleFourth(dir),
      ]),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "/compact", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "handled", action: { type: "none" } } }, after: [
          commandCompactionSixth,
          { ...stateIdleFourth(dir), compaction: "running", working: true, since: 1794330720000 },
          commandCompactionSeventh,
          stateIdleFourth(dir),
          { type: "reset", epoch: "epoch6", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, assistantVerifiedEveryStageSeq1Rev0, { seq: 2, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "copy", characters: 88 } }, commandExport, { seq: 4, revision: 0, at: 1794330720000, final: true, kind: "notify", level: "warning", text: { text: "/settings is not available in koa", cut: 0 } }, commandSessionSecond, commandCompactionSecond, { seq: 7, revision: 0, at: 1794330720000, final: true, kind: "command", result: { type: "compaction", state: { type: "cancelled" } } }, commandCompactionThird], more: false },
          stateIdleFourth(dir),
        ] }),
      completeStep,
    ],
    files: {},
  }),
};
