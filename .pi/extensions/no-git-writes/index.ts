import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { blocksGitWrite, parentSession } from "./policy.ts";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event) => {
    if (event.toolName === "bash" && typeof event.input.command === "string" &&
        blocksGitWrite(event.input.command, parentSession(process.env))) {
      return { block: true, reason: "No git writes in this repo; the top-level session commits. Leave your changes uncommitted." };
    }
    return undefined;
  });
}
