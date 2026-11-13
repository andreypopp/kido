import { next, expect, same, anything, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord, Block } from "../../koa-records.ts";
import { stateIdle } from "../scenario-parts.ts";

const stateIdleSecond = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), context: { tokens: 84007, window: 200000, percent: 42.0035 } });

const recordsFromResetOf1Items = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Here is what I have so far", images: [], attachments: [] }], more: false },
  stateIdleSecond(dir),
]);

const nextResetOf1Items = (dir: string): Step => (next([
  { type: "reset", epoch: "epoch2", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Release 0.32", images: [], attachments: [] }], more: false },
  stateIdleSecond(dir),
  { ...stateIdleSecond(dir), working: true, since: 1794330720000 },
  { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
  { type: "item", item: { seq: 1, revision: 2, at: 1794330720000, final: false, kind: "assistant", blocks: [{ type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794330720000 } },
  { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [{ index: 0, block: { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "running" }, started: 1794330720000 } }], final: false, stop: "toolUse", error: "", ended: 1794330720000 },
]));

const stateWithWorkingAndSince = (dir: string): PageRecord => ({ ...stateIdleSecond(dir), working: true, since: 1794330720000, queue: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }], followUp: [] } });

const patchSeq1Rev4: PageRecord = { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "running", result: { text: "", cut: 0, images: [] } }, started: 1794330720000 } }], final: false, stop: "toolUse", error: "", ended: 1794330720000 };

const toolBashMakeVerify: Block = { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "done", result: { text: "Command aborted", cut: 0, images: [] }, error: true }, started: 1794330720000, ended: 1794330720000, durationMs: 178 };

const assistantEmptySeq2Rev1: PageRecord = { type: "item", item: { seq: 2, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "aborted", error: "This operation was aborted" } };

const patchSeq2Rev2: PageRecord = { type: "patch", seq: 2, baseRevision: 1, revision: 2, blocks: [], final: true, stop: "aborted", error: "This operation was aborted", ended: 1794330720000 };

const assistantReadSeq1Rev2: PageRecord = { type: "item", item: { seq: 1, revision: 2, at: 1794330720000, final: false, kind: "assistant", blocks: [{ type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"notes.md\"}", cut: 0 }, state: { type: "pending" } }], stop: "toolUse", error: "", ended: 1794330720000 } };

const patchSeq1Rev3: PageRecord = { type: "patch", seq: 1, baseRevision: 2, revision: 3, blocks: [{ index: 0, block: { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"notes.md\"}", cut: 0 }, state: { type: "running" }, started: 1794330720000 } }], final: false, stop: "toolUse", error: "", ended: 1794330720000 };

const toolReadNotesMd: Block = { type: "tool", id: "call_2_0", name: "read", args: { text: "{\"path\":\"notes.md\"}", cut: 0 }, state: { type: "done", result: { text: "notes\n", cut: 0, images: [] }, error: false }, started: 1794330720000, ended: 1794330720000, durationMs: 2 };

const patchSeq1Rev4Second: PageRecord = { type: "patch", seq: 1, baseRevision: 3, revision: 4, blocks: [{ index: 0, block: toolReadNotesMd }], final: true, stop: "toolUse", error: "", ended: 1794330720000 };

const assistantReadSeq1Rev5: PageRecord = { type: "item", item: { seq: 1, revision: 5, at: 1794330720000, final: true, kind: "assistant", blocks: [toolReadNotesMd], stop: "toolUse", error: "", ended: 1794330720000 } };

const toolBashMakeVerifySecond: Block = { type: "tool", id: "call_1_0", name: "bash", args: { text: "{\"command\":\"make verify\"}", cut: 0 }, state: { type: "done", result: { text: "Command aborted", cut: 0, images: [] }, error: true }, started: 1794330720000, ended: 1794330720000, durationMs: 207 };

export const scenarios: Scenarios = {
  testKoaWebviewAttachmentsNarrow: dir => ({
    open: recordsFromResetOf1Items(dir),
    steps: [
      nextResetOf1Items(dir),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "skip the Linux check, I'll run it in CI", mode: "prompt", attachments: [] }) }, reply: { status: 200, json: { disposition: "queued" } }, after: [
          stateWithWorkingAndSince(dir),
          patchSeq1Rev4,
        ] }),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "then compare with these two renders", mode: "follow_up", attachments: [anything, anything] }) }, before: ({ attachments }) => [
          { ...stateIdleSecond(dir), working: true, since: 1794330720000, queue: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }], followUp: [{ text: "then compare with these two renders", attachments: [attachments[0], attachments[1]] }] } },
        ], reply: { status: 200, json: { disposition: "queued" } } }),
      expect({ on: { method: "POST", path: "/queue/clear", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, reply: { status: 200, json: ({ attachments }) => ({ steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }], followUp: [{ text: "then compare with these two renders", attachments: [attachments[0], attachments[1]] }] }) } }),
      next([
        { ...stateIdleSecond(dir), working: true, since: 1794330720000 },
        { ...stateIdleSecond(dir), working: true, since: 1794330720000 },
        { type: "patch", seq: 1, baseRevision: 4, revision: 5, blocks: [{ index: 0, block: toolBashMakeVerify }], final: true, stop: "toolUse", error: "", ended: 1794330720000 },
        { type: "item", item: { seq: 1, revision: 6, at: 1794330720000, final: true, kind: "assistant", blocks: [toolBashMakeVerify], stop: "toolUse", error: "", ended: 1794330720000 } },
        { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
        assistantEmptySeq2Rev1,
        patchSeq2Rev2,
        { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
        { ...stateIdleSecond(dir), aborted: true, context: { tokens: 84004, window: 200000, percent: 42.002 } },
        { ...stateIdleSecond(dir), aborted: true, context: { tokens: 84004, window: 200000, percent: 42.002 } },
        { type: "reset", epoch: "epoch3", items: [], more: false },
        { ...stateIdleSecond(dir), aborted: true, context: { tokens: 84004, window: 200000, percent: 42.002 } },
      ]),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "Attach these to the review", mode: "prompt", attachments: [anything, anything, anything] }) }, reply: { status: 200, json: { disposition: "started" } }, after: ({ attachments }) => [
          { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
          { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
          { type: "item", item: { seq: 0, revision: 1, at: 1794330720000, final: true, kind: "user", text: "Attach these to the review", images: [{ id: "0.0", revision: 0, bytes: 2516582, mimeType: "image/png", width: 1440, height: 900 }], attachments: [attachments[0], attachments[1], attachments[2]] } },
          { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
          assistantReadSeq1Rev2,
          patchSeq1Rev3,
          patchSeq1Rev4Second,
          assistantReadSeq1Rev5,
          { ...stateIdleSecond(dir), working: true, context: { tokens: 84002, window: 200000, percent: 42.001 }, since: 1794330720000 },
        ] }),
    ],
    files: {
      "/images/0.0?e=epoch3&r=0": `${dir}/shot.png`,
    },
  }),
  testKoaWebviewAttachmentsWide: dir => ({
    open: recordsFromResetOf1Items(dir),
    steps: [
      nextResetOf1Items(dir),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "skip the Linux check, I'll run it in CI", mode: "prompt", attachments: [] }) }, before: [
          stateWithWorkingAndSince(dir),
        ], reply: { status: 200, json: { disposition: "queued" } }, after: [
          patchSeq1Rev4,
        ] }),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "then compare with these two renders", mode: "follow_up", attachments: [anything, anything] }) }, reply: { status: 200, json: { disposition: "queued" } }, after: ({ attachments }) => [
          { ...stateIdleSecond(dir), working: true, since: 1794330720000, queue: { steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }], followUp: [{ text: "then compare with these two renders", attachments: [attachments[0], attachments[1]] }] } },
        ] }),
      expect({ on: { method: "POST", path: "/queue/clear", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001" }) }, reply: { status: 200, json: ({ attachments }) => ({ steering: [{ text: "skip the Linux check, I'll run it in CI", attachments: [] }], followUp: [{ text: "then compare with these two renders", attachments: [attachments[0], attachments[1]] }] }) } }),
      next([
        { ...stateIdleSecond(dir), working: true, since: 1794330720000 },
        { ...stateIdleSecond(dir), working: true, since: 1794330720000 },
        { type: "patch", seq: 1, baseRevision: 4, revision: 5, blocks: [{ index: 0, block: toolBashMakeVerifySecond }], final: true, stop: "toolUse", error: "", ended: 1794330720000 },
        { type: "item", item: { seq: 1, revision: 6, at: 1794330720000, final: true, kind: "assistant", blocks: [toolBashMakeVerifySecond], stop: "toolUse", error: "", ended: 1794330720000 } },
        { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
        assistantEmptySeq2Rev1,
        patchSeq2Rev2,
        { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
        { ...stateIdleSecond(dir), aborted: true, context: { tokens: 84004, window: 200000, percent: 42.002 } },
        { ...stateIdleSecond(dir), aborted: true, context: { tokens: 84004, window: 200000, percent: 42.002 } },
        { type: "reset", epoch: "epoch3", items: [], more: false },
        { ...stateIdleSecond(dir), aborted: true, context: { tokens: 84004, window: 200000, percent: 42.002 } },
      ]),
      expect({ on: { method: "POST", path: "/prompt", body: value => same(value, { sessionId: "00000000-0000-7000-8000-000000000001", text: "Attach these to the review", mode: "prompt", attachments: [anything, anything, anything] }) }, reply: { status: 200, json: { disposition: "started" } }, after: ({ attachments }) => [
          { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
          { ...stateIdleSecond(dir), working: true, context: { tokens: 84004, window: 200000, percent: 42.002 }, since: 1794330720000 },
          { type: "item", item: { seq: 0, revision: 1, at: 1794330720000, final: true, kind: "user", text: "Attach these to the review", images: [{ id: "0.0", revision: 0, bytes: 2516582, mimeType: "image/png", width: 1440, height: 900 }], attachments: [attachments[0], attachments[1], attachments[2]] } },
          { type: "item", item: { seq: 1, revision: 1, at: 1794330720000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
          assistantReadSeq1Rev2,
          patchSeq1Rev3,
          patchSeq1Rev4Second,
          assistantReadSeq1Rev5,
          { ...stateIdleSecond(dir), working: true, context: { tokens: 84002, window: 200000, percent: 42.001 }, since: 1794330720000 },
        ] }),
    ],
    files: {
      "/images/0.0?e=epoch3&r=0": `${dir}/shot.png`,
    },
  }),
};
