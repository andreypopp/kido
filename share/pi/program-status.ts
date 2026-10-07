import type { AgentActivityOutcome, ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Status = { state: "idle" | "working" | "blocked" | "done" | "error"; msg?: string };

export default function (pi: ExtensionAPI) {
  let current: Status = { state: "idle" };
  let beforeCompact: Status | undefined;
  let outcome: AgentActivityOutcome = "aborted";
  let lastReport: string | undefined;

  function report(status: Status, ctx: ExtensionContext) {
    current = status;
    if (ctx.mode !== "tui" || !process.stdout.isTTY) return;
    let title = "";
    let bytes = 0;
    for (const ch of (ctx.sessionManager.getSessionName() ?? "").replace(/[\u0000-\u001f\u007f-\u009f]/g, "")) {
      const size = Buffer.byteLength(ch);
      if (bytes + size > 192) break;
      title += ch;
      bytes += size;
    }
    const sequence = `\x1b]7501;state=${status.state}:app=pi:title=${Buffer.from(title).toString("base64")}${status.msg ? `:msg=${Buffer.from(status.msg).toString("base64")}` : ""}\x1b\\`;
    if (sequence === lastReport) return;
    process.stdout.write(sequence);
    lastReport = sequence;
  }

  pi.on("session_start", (_event, ctx) => {
    lastReport = undefined;
    outcome = "aborted";
    beforeCompact = undefined;
    report({ state: "idle" }, ctx);
  });
  pi.on("session_info_changed", (_event, ctx) => report(current, ctx));
  pi.on("agent_start", (_event, ctx) => {
    outcome = "aborted";
    report({ state: "working" }, ctx);
  });
  pi.on("ui_prompt_start", (_event, ctx) => report({ state: "blocked" }, ctx));
  pi.on("ui_prompt_end", (_event, ctx) => report({ state: ctx.isIdle() ? "idle" : "working" }, ctx));
  pi.on("session_before_compact", (_event, ctx) => {
    beforeCompact = current;
    report({ state: "working", msg: "Compacting context" }, ctx);
  });
  function compactEnded(_event: unknown, ctx: ExtensionContext) {
    const saved = beforeCompact;
    beforeCompact = undefined;
    if (saved) report(saved, ctx);
  }
  pi.on("session_compact", compactEnded);
  pi.on("session_compact_failed", compactEnded);
  pi.on("agent_before_settle", (event) => { outcome = event.outcome; });
  pi.on("agent_settled", (_event, ctx) => {
    if (ctx.isIdle()) report({ state: outcome === "error" ? "error" : outcome === "aborted" ? "idle" : "done" }, ctx);
  });
}
