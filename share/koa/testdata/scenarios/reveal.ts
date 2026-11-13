import { next, type Scenarios } from "../scenario.ts";
import { stateIdle, userMakeTheSweep } from "../scenario-parts.ts";

export const scenarios: Scenarios = {
  testKoaWebviewReveal: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [userMakeTheSweep, { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "The sweep keeps this helper:\n\n```swift\n    let value1 = 1\n    let value2 = 2\n    let value3 = 3\n    let value4 = 4\n    let value5 = 5\n    let value6 = 6\n    let value7 = 7\n    let value8 = 8\n    let value9 = 9\n    let value10 = 10\n    let value11 = 11\n    let value12 = 12\n    let value13 = 13\n    let value14 = 14\n    let value15 = 15\n    let value16 = 16\n    let value17 = 17\n    let value18 = 18\n    let value19 = 19\n    let value20 = 20\n```\n\nIt reads each row once." }], stop: "stop", error: "" }], more: false },
      stateIdle(dir),
    ],
    steps: [
      next([]),
      next([
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        { ...stateIdle(dir), working: true, since: 1794177120000 },
        { type: "item", item: { seq: 2, revision: 1, at: 1794177120000, final: true, kind: "user", text: "Explain how the sweep decides what to remove, with a table", images: [], attachments: [] } },
        { type: "item", item: { seq: 3, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
        { type: "item", item: { seq: 3, revision: 2, at: 1794177120000, final: false, kind: "assistant", blocks: [{ type: "text", text: "First the rows are read.\n\n- one\n- two\n\n```swift\nlet a = 1\nlet b = 2\nlet c" }], stop: "pending", error: "" } },
      ]),
    ],
    files: {},
  }),
};
