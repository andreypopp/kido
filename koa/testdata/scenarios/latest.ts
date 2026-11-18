import { next, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";
import { stateIdleFourth } from "../scenario-parts.ts";

const recordsFromResetOf12Items = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794177121000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177121500, final: true, kind: "assistant", blocks: [{ type: "text", text: "Step 1 is done. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change." }], stop: "stop", error: "" }, { seq: 2, revision: 0, at: 1794177122000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] }, { seq: 3, revision: 0, at: 1794177122500, final: true, kind: "assistant", blocks: [{ type: "text", text: "Step 2 is done. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change." }], stop: "stop", error: "" }, { seq: 4, revision: 0, at: 1794177123000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] }, { seq: 5, revision: 0, at: 1794177123500, final: true, kind: "assistant", blocks: [{ type: "text", text: "Step 3 is done. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change." }], stop: "stop", error: "" }, { seq: 6, revision: 0, at: 1794177124000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] }, { seq: 7, revision: 0, at: 1794177124500, final: true, kind: "assistant", blocks: [{ type: "text", text: "Step 4 is done. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change." }], stop: "stop", error: "" }, { seq: 8, revision: 0, at: 1794177125000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] }, { seq: 9, revision: 0, at: 1794177125500, final: true, kind: "assistant", blocks: [{ type: "text", text: "Step 5 is done. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change." }], stop: "stop", error: "" }, { seq: 10, revision: 0, at: 1794177126000, final: true, kind: "user", text: "Make the sweep keep a start failure for the linger grace, then test it", images: [], attachments: [] }, { seq: 11, revision: 0, at: 1794177126500, final: true, kind: "assistant", blocks: [{ type: "text", text: "Step 6 is done. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change." }], stop: "stop", error: "" }], more: false },
  stateIdleFourth(dir),
]);

const stepsFromNextStateWithWorkingAndSinceFourth = (dir: string): Step[] => ([
  next([
    { ...stateIdleFourth(dir), working: true, since: 1794177120000 },
    { type: "item", item: { seq: 12, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    { type: "item", item: { seq: 12, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Arrival 1. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change. The cascade is the server's, so a child pane never outlives its parent.\n\nThe linger collection waits while a focused client shows the pane, and a start failure stays readable until the grace ends." }], stop: "stop", error: "", ended: 1794177120000 } },
    { ...stateIdleFourth(dir), working: true, since: 1794177120000 },
    { type: "item", item: { seq: 13, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    { type: "item", item: { seq: 13, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Arrival 2. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change. The cascade is the server's, so a child pane never outlives its parent.\n\nThe linger collection waits while a focused client shows the pane, and a start failure stays readable until the grace ends." }], stop: "stop", error: "", ended: 1794177120000 } },
    { ...stateIdleFourth(dir), working: true, since: 1794177120000 },
    { type: "item", item: { seq: 14, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    { type: "item", item: { seq: 14, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Arrival 3. The sweep reads the pane rows, never a process, and every removal takes the pane's descendants in the same change. The cascade is the server's, so a child pane never outlives its parent.\n\nThe linger collection waits while a focused client shows the pane, and a start failure stays readable until the grace ends." }], stop: "stop", error: "", ended: 1794177120000 } },
    { ...stateIdleFourth(dir), working: true, since: 1794177120000 },
    stateIdleFourth(dir),
    stateIdleFourth(dir),
  ]),
]);

export const scenarios: Scenarios = {
  testKoaWebviewLatestNarrow: dir => ({
    open: recordsFromResetOf12Items(dir),
    steps: stepsFromNextStateWithWorkingAndSinceFourth(dir),
    files: {},
  }),
  testKoaWebviewLatestWide: dir => ({
    open: recordsFromResetOf12Items(dir),
    steps: stepsFromNextStateWithWorkingAndSinceFourth(dir),
    files: {},
  }),
};
