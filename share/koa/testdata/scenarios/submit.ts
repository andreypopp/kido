import type { PageRecord } from "../../koa-records.ts";
import type { Scenarios } from "../scenario.ts";

const stamp = 1700000000000;
const question = Array(12).fill("Keep the cache?").join("\n\n");
const open: PageRecord[] = [
  { type: "reset", epoch: "e1", more: false, items: [
    { seq: 0, revision: 0, at: stamp - 1, final: true, kind: "user", text: Array(80).fill("Earlier message").join("\n\n"), images: [], attachments: [] },
    { seq: 1, revision: 0, at: stamp, final: true, kind: "assistant", blocks: [{ type: "text", text: question }], stop: "stop", error: "" },
    { seq: 2, revision: 0, at: stamp + 1, final: true, kind: "annotations", reply: { seq: 1, block: 0 }, annotations: [{ type: "question", kind: "yes_no", range: [0, question.length] }] },
  ] },
  { type: "state", compaction: "idle", view: { id: "s1", path: [{ id: "s1", name: "ko" }] }, agents: [], bash: [], working: false, aborted: false, name: "trace", levels: [], cwd: "/work", home: "/home", sessionId: "s1", queue: { steering: [], followUp: [] }, dialogs: [], statuses: {}, life: { type: "ready" } },
];

export const scenarios: Scenarios = {
  testKoaWebviewSubmitFollowsClampedBottom: () => ({ open, steps: [], files: {} }),
};
