import { writeSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { ProcessTerminal, TuiMainScreen } from "@earendil-works/pi-tui";
import { getAgentDir, initTheme, parseArgs, SessionManager, SessionSelectorComponent, SettingsManager } from "@earendil-works/pi-coding-agent";

export default async function () {
  const ui = new TuiMainScreen(new ProcessTerminal());
  let started = false;
  const stop = () => { if (started) { started = false; ui.stop(); } };
  process.once("exit", stop);
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.once(signal, () => { stop(); process.exit(1); });
  try {
    const args = parseArgs(JSON.parse(process.env.KOA_RESUME_ARGS ?? "[]"));
    if (!args.resume || args.noSession || args.session || args.fork || args.sessionId !== undefined || args.help || args.version || args.export || args.listModels !== undefined || ((args.mode ?? "rpc") === "rpc" && args.fileArgs.length > 0) || args.diagnostics.some(diagnostic => diagnostic.type === "error")) {
      writeSync(3, '{"type":"skip"}\n');
      process.exit(0);
    }
    if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error("resume requires a terminal");
    const cwd = process.cwd();
    const settings = SettingsManager.create(cwd, getAgentDir());
    const expand = (path: string) => path.replace(/^~(?=\/|$)/, homedir());
    const configured = args.sessionDir || process.env.PI_CODING_AGENT_SESSION_DIR;
    const sessionDir = configured ? resolve(expand(configured)) : settings.getSessionDir();
    initTheme(settings.getThemeSetting());
    const result = await new Promise<{ type: "selected"; path: string } | { type: "cancel" }>(resolve => {
      const cancel = () => resolve({ type: "cancel" });
      const selector = new SessionSelectorComponent(
        (progress, signal) => SessionManager.list(cwd, sessionDir, progress, signal),
        (progress, signal) => SessionManager.listAll(sessionDir, progress, signal),
        path => resolve({ type: "selected", path }), cancel, cancel,
        () => ui.requestRender(), { showRenameHint: false },
      );
      ui.addChild(selector);
      ui.setFocus(selector.getSessionList());
      started = true;
      ui.start();
      writeSync(3, '{"type":"ready"}\n');
    });
    stop();
    writeSync(3, JSON.stringify(result) + "\n");
    process.exit(0);
  } catch (error) {
    stop();
    process.stderr.write(`koa: session picker: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }
}
