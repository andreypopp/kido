import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { blocksGitWrite } from "./policy.ts";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event) => {
    if (event.toolName === "bash" && typeof event.input.command === "string" &&
        blocksGitWrite(event.input.command, process.env.KIDO_AGENT_PARENT_SESSION)) {
      return { block: true, reason: "No git writes in this repo; the top-level session commits. Leave your changes uncommitted." };
    }
    return undefined;
  });
}
