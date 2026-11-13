import { type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";
import { stateIdle, userMakeTheSweep } from "../scenario-parts.ts";

const recordsFromResetOf2ItemsThird = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [userMakeTheSweep, { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "thinking", text: "# Check the close policy\n\nKeep **start failures** visible and use `close` for the exit rule.\n\n- Read the pane state\n- Keep the focus rule\n\n```swift\nif pane.close == .exit {\n    remove(pane)\n}\n```", redacted: false }], stop: "stop", error: "" }], more: false },
  stateIdle(dir),
]);

export const scenarios: Scenarios = {
  testKoaWebviewThinkingMarkdownNarrow: dir => ({
    open: recordsFromResetOf2ItemsThird(dir),
    steps: [

    ],
    files: {},
  }),
  testKoaWebviewThinkingMarkdownWide: dir => ({
    open: recordsFromResetOf2ItemsThird(dir),
    steps: [

    ],
    files: {},
  }),
};
