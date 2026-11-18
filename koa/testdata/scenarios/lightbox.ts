import { type Scenarios } from "../scenario.ts";
import { stateIdle, nextResetOf5ItemsFourth } from "../scenario-parts.ts";

export const scenarios: Scenarios = {
  testKoaWebviewLightbox: dir => ({
    open: [
      { type: "reset", epoch: "epoch1", items: [], more: false },
      stateIdle(dir),
    ],
    steps: [
      nextResetOf5ItemsFourth(dir),
    ],
    files: {
      "/images/1.0.0?e=epoch2&r=0": `${dir}/shot.png`,
      "/images/2.0.0?e=epoch2&r=0": `${dir}/shot.png`,
      "/images/3.0.0?e=epoch2&r=0": `${dir}/sidebar.png`,
      "/images/3.0.1?e=epoch2&r=0": `${dir}/diagram.png`,
    },
  }),
};
