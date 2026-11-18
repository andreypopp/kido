import { homedir } from "node:os";
import { resolve } from "node:path";
import { getAgentDir, SettingsManager } from "@earendil-works/pi-coding-agent";

export function sessionDir(args: { sessionDir?: string }, cwd: string): string | undefined {
  const configured = args.sessionDir || process.env.PI_CODING_AGENT_SESSION_DIR;
  return configured ? resolve(configured.replace(/^~(?=\/|$)/, homedir())) : SettingsManager.create(cwd, getAgentDir()).getSessionDir();
}
