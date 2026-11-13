import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { blocksGitWrite, blocksSignal, blocksSleep, parentSession } from "./policy.ts";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event) => {
    if (event.toolName !== "bash" || typeof event.input.command !== "string") return undefined;
    if (blocksGitWrite(event.input.command, parentSession(process.env))) {
      return { block: true, reason: "No git writes in this repo; the top-level session commits. Leave your changes uncommitted." };
    }
    if (blocksSleep(event.input.command)) {
      return { block: true, reason: "No sleep: wait for the event. Run long commands with async_bash under scripts/quiet-limit; its notice wakes you." };
    }
    if (blocksSignal(event.input.command)) {
      return { block: true, reason: "No pkill, killall or kill: an agent's `pkill -f koa/koa.ts` once killed every koa process on the machine, including the user's agent. Stop a background job with stop_async_bash, an agent with stop_agent; a test's processes end through their own deadline (scripts/quiet-limit)." };
    }
    return undefined;
  });
}
