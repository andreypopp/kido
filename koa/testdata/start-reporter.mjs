import { writeSync } from "node:fs";

const QUIET_MS = 90000;

export default async function* (source) {
  const files = new Map();
  let last = Date.now();
  const timer = setInterval(() => {
    if (Date.now() - last < QUIET_MS) return;
    const rows = [...files].map(([file, state]) => `  ${file}: ${state.open.size} open [${[...state.open].join("; ")}], last event ${Math.round((Date.now() - state.at) / 1000)} s ago`);
    writeSync(1, `STALLED no test event for ${QUIET_MS / 1000} s; files that ran tests:\n${rows.join("\n")}\n`);
    process.exit(1);
  }, 5000);
  timer.unref();
  for await (const { type, data } of source) {
    last = Date.now();
    const file = data?.file?.split("/").at(-1) ?? "?";
    const state = files.get(file) ?? { open: new Set(), at: last };
    state.at = last;
    files.set(file, state);
    if (data?.nesting !== 0) continue;
    if (type === "test:dequeue") {
      state.open.add(data.name);
      yield `START ${file} ${data.name}\n`;
    } else if (type === "test:complete") {
      state.open.delete(data.name);
      yield `END ${data.details.passed ? "ok" : "FAIL"} ${file} ${data.name}\n`;
      if (!data.details.passed) yield `FAILED ${file} ${data.name}: ${data.details?.error?.stack ?? data.details?.error ?? ""}\n`;
    }
  }
  clearInterval(timer);
}
