import { next, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";
import { stateIdle } from "../scenario-parts.ts";

const recordsFromResetOf3Items = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Verify the sidebar unit and tell me what is left", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "The sidebar unit is verified: fmt, clippy, lint, unit, e2e and the TypeScript suite pass. Two things before I push.\n\n- Should I push now, or wait for CI on the rebase?\n- The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.\n\nDo you want the Linux check at all? It costs 4 minutes of CI, and the user-facing change is macOS only.\n\nI could also fold the two commits into one before the push.\n\nWhat should the release be called?" }], stop: "stop", error: "" }, { kind: "annotations", seq: 2, revision: 0, at: 1794177120001, final: true, reply: { seq: 1, block: 0 }, annotations: [{ type: "question", kind: "choice", range: [119, 167], options: [[128, 136], [141, 152]] }, { type: "question", kind: "yes_no", range: [170, 250] }, { type: "question", kind: "yes_no", range: [252, 287] }, { type: "question", kind: "choice", range: [357, 416], options: [[370, 399]] }, { type: "question", kind: "open", range: [418, 452] }] }], more: false },
  stateIdle(dir),
]);

const stepsFromNextStateWithWorkingAndSinceFifth = (dir: string): Step[] => ([
  next([
    { ...stateIdle(dir), working: true, since: 1794177120000 },
    { type: "item", item: { seq: 3, revision: 1, at: 1794177120000, final: false, kind: "assistant", blocks: [], stop: "pending", error: "" } },
    { type: "item", item: { seq: 3, revision: 2, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "Which should I do?\n\n1. Rebase the branch onto main and rerun the full verification before the push, including the application tests and all checks for the changed files.\n2. Push the branch as it is now and let CI check the combination on main, including the application tests and all checks for the changed files.\n\n😀 Pick `one` or **two**?\r\n\r\n- Keep the cache?\r\n\r\n## Use alpha or beta?\r\n\r\n| Choice |\r\n| --- |\r\n| Use red or blue? |\r\n\r\nLiteral 999;x" }], stop: "stop", error: "", ended: 1794177120000 } },
    { ...stateIdle(dir), working: true, since: 1794177120000 },
    stateIdle(dir),
    stateIdle(dir),
    { type: "item", item: { kind: "annotations", seq: 4, revision: 1, at: 1794177120000, final: true, reply: { seq: 3, block: 0 }, annotations: [{ type: "question", kind: "choice", range: [0, 313], options: [[23, 168], [173, 312]] }, { type: "question", kind: "choice", range: [315, 339], options: [[322, 327], [331, 338]] }, { type: "question", kind: "yes_no", range: [345, 360] }, { type: "question", kind: "choice", range: [367, 385], options: [[371, 376], [380, 384]] }, { type: "question", kind: "choice", range: [412, 428], options: [[416, 419], [423, 427]] }] } },
  ]),
]);

export const scenarios: Scenarios = {
  testKoaWebviewQuestionsNarrow: dir => ({
    open: recordsFromResetOf3Items(dir),
    steps: stepsFromNextStateWithWorkingAndSinceFifth(dir),
    files: {},
  }),
  testKoaWebviewQuestionsWide: dir => ({
    open: recordsFromResetOf3Items(dir),
    steps: stepsFromNextStateWithWorkingAndSinceFifth(dir),
    files: {},
  }),
};
