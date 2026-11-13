import { type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";
import { stateIdle } from "../scenario-parts.ts";

const stateIdleTenth = (dir: string): Extract<PageRecord, { type: "state" }> => ({ ...stateIdle(dir), name: "sidebar-right", context: { tokens: null, window: 200000, percent: null } });

const recordsFromResetOf5Items = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794177180000, final: true, kind: "summary", source: "compaction", text: "The session verified the sidebar-right unit and fixed two snapshot tests.\n\nOpen: the +N overflow on rows under 215pt, and the tap revision for the release notes." }, { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit", images: [], attachments: [] }, { seq: 2, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Verified: every stage passes." }], stop: "error", error: "provider down: 529 overloaded, retry in a minute or switch the model with /model" }, { seq: 3, revision: 0, at: 1794177240000, final: true, kind: "summary", source: "branch", text: "The abandoned branch tried a fixed row height and dropped it because folded clusters clip." }, { seq: 4, revision: 0, at: 1794177300000, final: true, kind: "notice", customType: "release-check", from: "release", text: "Release check passed\nThe tap is clean.\nThe revision is 20857320." }], more: false },
  stateIdleTenth(dir),
]);

export const scenarios: Scenarios = {
  testKoaWebviewNoticesNarrow: dir => ({
    open: recordsFromResetOf5Items(dir),
    steps: [

    ],
    files: {},
  }),
  testKoaWebviewNoticesWide: dir => ({
    open: recordsFromResetOf5Items(dir),
    steps: [

    ],
    files: {},
  }),
};
