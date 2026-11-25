import type { PageRecord } from "../../koa-records.ts";
import type { Scenarios } from "../scenario.ts";

const stamp = 1700000000000;
const open: PageRecord[] = [
  { type: "reset", epoch: "e1", more: false, items: [
    { seq: 0, revision: 0, at: stamp, final: true, kind: "user", text: "Read the sweep", images: [], attachments: [] },
  ] },
  { type: "state", pathEditor: false, compaction: "idle", view: { id: "s1", path: [{ id: "s1", name: "ko", type: "agent" }], type: 'root' }, topics: [], agents: [], bash: [], life: { type: "ready" }, working: false, aborted: false, name: "dots", levels: [], cwd: "/work", home: "/home", sessionId: "s1", statuses: {}, queue: { steering: [], followUp: [], classifying: [] }, dialogs: [] },
];

const initial = () => ({ open, steps: [], files: {} });
export const scenarios: Scenarios = {
  testKoaWebviewDots: initial,
  RevealTail: initial,
  ThinkingCaret: initial,
  UnreadGap: initial,
  BangTail: initial,
  EndingRow: initial,
  WorkedRun: initial,
};
