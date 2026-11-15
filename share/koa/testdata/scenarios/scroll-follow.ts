import type { PageRecord } from "../../koa-records.ts";
import { expect, type Scenarios } from "../scenario.ts";

const stamp = 1700000000000;
const open: PageRecord[] = [
  { type: "reset", epoch: "e1", more: false, items: [
    { seq: 0, revision: 0, at: stamp, final: true, kind: "user", text: Array(80).fill("Earlier message").join("\n\n"), images: [], attachments: [] },
    { seq: 1, revision: 0, at: stamp + 1, final: true, kind: "assistant", blocks: [{ type: "text", text: Array(40).fill("Earlier reply").join("\n\n") }], stop: "stop", error: "" },
  ] },
  { type: "state", compaction: "idle", view: { id: "s1", path: [{ id: "s1", name: "ko", type: "agent" }], type: "agent" }, agents: [], bash: [], working: false, aborted: false, name: "trace", levels: [], cwd: "/work", home: "/home", sessionId: "s1", queue: { steering: [], followUp: [] }, dialogs: [], statuses: {}, life: { type: "ready" } },
];
const sent = expect({ on: { method: "POST", path: "/prompt" }, reply: { status: 200, json: { disposition: "started" } } });

const older = expect({ on: { method: "GET", path: "/items" }, reply: { status: 200, json: { epoch: "e1", more: false, items: [
  { seq: 8, revision: 0, at: stamp - 2, final: true, kind: "user", text: Array(60).fill("Oldest message").join("\n\n"), images: [], attachments: [] },
  { seq: 9, revision: 0, at: stamp - 1, final: true, kind: "assistant", blocks: [{ type: "text", text: Array(30).fill("Oldest reply").join("\n\n") }], stop: "stop", error: "" },
] } } });

export const scenarios: Scenarios = {
  testKoaWebviewRevealKeepsFollowing: () => ({ open, steps: [], files: {} }),
  testKoaWebviewStreamingNeverStepsUp: () => ({ open, steps: [], files: {} }),
  testKoaWebviewOlderHistoryKeepsTheReaderAnchor: () => ({ open: open.map(record => record.type === "reset" ? { ...record, more: true, items: record.items.map(item => ({ ...item, seq: item.seq + 10 })) } : record), steps: [older], files: {} }),
  testKoaWebviewViewSwitchRestoresTheReaderAndJobViewFollows: () => ({ open, steps: [], files: {} }),
  testKoaWebviewSendKeepsFollowing: () => ({ open, steps: [sent, sent], files: {} }),
};
