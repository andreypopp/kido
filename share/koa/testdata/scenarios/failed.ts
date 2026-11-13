import { type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";

const stateFailedSecond = (dir: string): Extract<PageRecord, { type: "state" }> => ({ view: { id: "00000000-0000-7000-8000-000000000001", path: [{ id: "00000000-0000-7000-8000-000000000001", name: "ko" }] }, agents: [], bash: [], compaction: "idle", working: false, aborted: false, name: "pi", levels: [], cwd: `/private${dir}/home/Workspace/kido`, home: `${dir}/home`, dialogs: [], statuses: {}, queue: { steering: [], followUp: [] }, life: { type: "failed", at: 1794177660000, message: "Unknown provider \"nope\". Use --list-models to see available providers/models." }, type: "state" });

export const scenarios: Scenarios = {
  testKoaWebviewFailed: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateFailedSecond(dir),
    ],
    steps: [

    ],
    files: {},
  }),
  testKoaWebviewNarrowExit: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateFailedSecond(dir),
    ],
    steps: [

    ],
    files: {},
  }),
};
