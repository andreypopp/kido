import { next, type Step, type Scenarios } from "../scenario.ts";
import { stateIdle, nextResetOf5ItemsFourth } from "../scenario-parts.ts";

const stepsFromNextResetOf5ItemsFourth = (dir: string): Step[] => ([
  nextResetOf5ItemsFourth(dir),
  next([
    { type: "reset", epoch: "epoch3", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Make the sidebar look like this", images: [{ id: "0.0", revision: 0, bytes: 263613, mimeType: "image/png", width: 1200, height: 500 }, { id: "0.1", revision: 0, bytes: 357617, mimeType: "image/png", width: 800, height: 800 }], attachments: [] }, { seq: 1, revision: 0, at: 1794330720000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Reading both fixtures." }], stop: "stop", error: "" }], more: false },
    stateIdle(dir),
  ]),
  next([
    { type: "reset", epoch: "epoch4", items: [{ seq: 0, revision: 0, at: 1794330720000, final: true, kind: "user", text: "Compare with the earlier screenshot", images: [{ id: "0.0", revision: 0, bytes: 693145, mimeType: "image/png", width: 1440, height: 900 }, { id: "0.1", revision: 0, bytes: 693145, mimeType: "image/png", width: 1440, height: 900 }], attachments: [] }, { seq: 1, revision: 0, at: 1794330720000, final: true, kind: "assistant", blocks: [{ type: "text", text: "I can see the second one; the first is no longer available in this session." }], stop: "stop", error: "" }], more: false },
    stateIdle(dir),
  ]),
]);

export const scenarios: Scenarios = {
  testKoaWebviewMediaNarrow: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: stepsFromNextResetOf5ItemsFourth(dir),
    files: {
      "/images/1.0.0?e=epoch2&r=0": `${dir}/shot.png`,
      "/images/2.0.0?e=epoch2&r=0": `${dir}/shot.png`,
      "/images/3.0.0?e=epoch2&r=0": `${dir}/sidebar.png`,
      "/images/3.0.1?e=epoch2&r=0": `${dir}/diagram.png`,
      "/images/0.0?e=epoch3&r=0": `${dir}/sidebar.png`,
      "/images/0.1?e=epoch3&r=0": `${dir}/diagram.png`,
      "/images/0.0?e=epoch4&r=0": `${dir}/gone.png`,
      "/images/0.1?e=epoch4&r=0": `${dir}/shot.png`,
    },
  }),
  testKoaWebviewMediaWide: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: stepsFromNextResetOf5ItemsFourth(dir),
    files: {
      "/images/1.0.0?e=epoch2&r=0": `${dir}/shot.png`,
      "/images/2.0.0?e=epoch2&r=0": `${dir}/shot.png`,
      "/images/3.0.0?e=epoch2&r=0": `${dir}/sidebar.png`,
      "/images/3.0.1?e=epoch2&r=0": `${dir}/diagram.png`,
      "/images/0.0?e=epoch3&r=0": `${dir}/sidebar.png`,
      "/images/0.1?e=epoch3&r=0": `${dir}/diagram.png`,
      "/images/0.0?e=epoch4&r=0": `${dir}/gone.png`,
      "/images/0.1?e=epoch4&r=0": `${dir}/shot.png`,
    },
  }),
};
