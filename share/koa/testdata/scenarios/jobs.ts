import type { Scenario, Scenarios } from "../scenario.ts";
import { stateIdle } from "../scenario-parts.ts";
import type { PageRecord } from "../../koa-records.ts";
import type { JobSnapshot } from "../../records.ts";

const root = { id: "00000000-0000-7000-8000-000000000001", name: "ko" };
const sidebar = { id: "00000000-0000-7000-8000-0000000000a1", name: "sidebar-right" };
const now = 1794177132000;
const at = (hours: number, minutes: number) => new Date(new Date(now).setHours(hours, minutes, 0, 0)).getTime();
const esc = (code: string, text: string) => `\x1b[${code}m${text}\x1b[0m`;
const base64 = (text: string) => Buffer.from(text).toString("base64");

const running = [
  "\x1b[2m$ scripts/quiet-limit 60 -- make verify STAGES=unit,e2e\x1b[0m",
  `${esc("34", "fmt")} ........................ ${esc("32", "PASS")}  (1.2s)`,
  `${esc("34", "clippy")} ..................... ${esc("32", "PASS")}  (41.0s)`,
  `${esc("34", "lint")} ....................... ${esc("32", "PASS")}  (3.8s)`,
  esc("34", "unit"),
  "   Compiling ko_server v0.1.0 (/Users/andrepopp/Workspace/kido/ko_server)",
  "   Compiling ko_client v0.1.0",
  "    Finished test profile [unoptimized + debuginfo] target(s) in 38.21s",
  "     Running unittests src/lib.rs",
  `test sweep::keeps_a_start_failure ... ${esc("32", "ok")}`,
  `test sweep::removes_an_exited_pane ... ${esc("32", "ok")}`,
  `test layout::float_dock_right ... ${esc("32", "ok")}`,
  `test result: ${esc("32", "ok")}. 212 passed; 0 failed; 0 ignored`,
  esc("34", "e2e"),
  "     Running tests/client.rs",
  `test client_attach_detach ... ${esc("32", "ok")}`,
  `test client_reconnect_keeps_scroll ... ${esc("32", "ok")}`,
  `test sidebar_breadcrumb_on_linux ... ${esc("33", "running")}`,
].join("\n") + "\n";
const failed = [
  `test lint::docs_references ... ${esc("32", "ok")}`,
  `test lint::crates_txt ... ${esc("32", "ok")}`,
  `${esc("31", "error")}: unused import: \`std::io::Write\``,
  "  --> ko_server/src/pane_proc.rs:14:5",
  "   |",
  "14 | use std::io::Write;",
  `   |     ${esc("31", "^^^^^^^^^^^^^^")}`,
  "   |",
  "   = note: `-D unused-imports` implied by `-D warnings`",
  `${esc("31", "error")}: could not compile \`ko_server\` (lib) due to 1 previous error`,
  "make: *** [lint] Error 1",
].join("\n") + "\n";
const service = [
  `${esc("2", "14:31:02")} main at 7e9769b4 · 0 behind`,
  `${esc("2", "14:36:02")} main at 7e9769b4 · 0 behind`,
  `${esc("2", "14:41:03")} main at 999414ae · ${esc("32", "1 new")}: Floats raise on focus`,
  `${esc("2", "14:46:02")} main at 999414ae · 0 behind`,
  `${esc("2", "14:51:02")} main at e192f5f1 · ${esc("32", "1 new")}: Job rows open a log float`,
  `${esc("2", "14:56:03")} main at e192f5f1 · 0 behind`,
].join("\n") + "\n";

const job = (dir: string, owners: { id: string; name: string }[], id: string, snapshot: JobSnapshot): PageRecord => ({
  ...stateIdle(dir),
  view: { id, path: [...owners.map(owner => ({ ...owner, type: "agent" as const })), { id, name: snapshot.name, type: "job" }], type: "job", job: snapshot },
  sessionId: owners.at(-1)?.id,
  type: "state",
});
const open = (view: string, text: string, start = 0): PageRecord => ({ type: "job-reset", view, epoch: "job-epoch", start, end: start + Buffer.byteLength(text), data: base64(text) });

const runningScenario = (dir: string): Scenario => ({
  open: [
    job(dir, [root], "j7a1", { name: "make-verify", command: "scripts/quiet-limit 60 -- make verify STAGES=unit,e2e", service: false, startedAt: at(14, 31), place: { type: "mac" }, log: "/tmp/ko-pi/01a10d51-…-jwrz3x4s.log", state: { type: "running" } }),
    open("j7a1", running),
  ],
  steps: [],
  files: {},
});
const endedScenario = (dir: string): Scenario => ({
  open: [
    job(dir, [root], "j7p2", { name: "lint", command: "make lint", service: false, startedAt: at(14, 28), place: { type: "mac" }, log: "/tmp/ko-pi/01a10d51-…-j7p2qe1x.log", state: { type: "ended", end: { type: "exit", code: 1 }, at: at(14, 28) + 130000 } }),
    open("j7p2", "g::partial_line ... ok\n" + failed, 1300000),
  ],
  steps: [],
  files: {},
});
const serviceScenario = (dir: string): Scenario => ({
  open: [
    job(dir, [root, sidebar], "jm4w", { name: "main-watch", command: "scripts/main-watch.sh --stream", service: true, startedAt: at(14, 31), place: { type: "runtime", name: "devbox" }, log: "/tmp/ko-pi/01a10d51-…-jm4w1t0c.log", state: { type: "running" } }),
    open("jm4w", service.repeat(8)),
  ],
  steps: [],
  files: {},
});

export const scenarios: Scenarios = {
  testKoaWebviewJobRunning: runningScenario,
  testKoaWebviewJobEnded: endedScenario,
  testKoaWebviewJobService: serviceScenario,
  testKoaWebviewJobNarrow: runningScenario,
};
