import { type Scenarios } from "../scenario.ts";
import { stateIdle } from "../scenario-parts.ts";

export const scenarios: Scenarios = {
  testKoaWebviewComposerMarkdown: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [

    ],
    files: {},
  }),
};
