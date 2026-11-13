import { appendFileSync, writeSync, closeSync } from "node:fs";
import { once } from "node:events";
import { connect } from "node:net";

const log = (value: object) => { if (process.env.KOA_FAKE_LOG) appendFileSync(process.env.KOA_FAKE_LOG, JSON.stringify(value) + "\n"); };
const args: string[] = JSON.parse(process.env.KOA_RESUME_ARGS ?? "[]");
log({ type: "picker", args });
process.once("exit", code => log({ type: "picker_exit", code }));
process.once("SIGTERM", () => { log({ type: "picker_signal", signal: "SIGTERM" }); process.exit(1); });
const skipping = args.some(arg => ["--session", "--fork", "--no-session"].includes(arg));
let result = skipping ? "skip" : '{"type":"cancel"}';
if (process.env.KOA_FAKE_PICKER_GATE) {
  const gate = connect(process.env.KOA_FAKE_PICKER_GATE);
  const [bytes] = await once(gate, "data"); gate.end();
  result = String(bytes);
}
if (result === "skip") {
  if (!skipping) process.exit(2);
  writeSync(3, '{"type":"skip"}\n');
} else {
  if (result !== "rpc") writeSync(3, '{"type":"ready"}\n');
  if (result === "eof") closeSync(3);
  if (["rpc", "signal", "eof"].includes(result)) { process.stdin.resume(); await once(process.stdin, "end"); }
  else if (result !== "exit") writeSync(3, result + "\n");
}
process.exit(0);
