import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { refusal } from "./policy.ts";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event) => {
    const reason = refusal(event.toolName, event.input, process.env);
    return reason === undefined ? undefined : { block: true, reason };
  });
}
