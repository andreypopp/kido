import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parentSession, refusal } from "./policy.ts";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event, ctx) => {
    const reason = refusal(event.toolName, event.input, parentSession(ctx.sessionManager.getBranch(), ctx.sessionManager.getSessionId()));
    return reason === undefined ? undefined : { block: true, reason };
  });
}
