import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { NotifyLevel } from "./koa-records.ts";
import { createFloat, type FloatEnd } from "./koa-float.ts";
import { findKo } from "./runtime-exec.ts";
import { errorText, isRecord } from "./text.ts";

type Open = { dir: string; file: string; text: string; session: string | undefined; editor: string };

type Notice = { text: string; level: NotifyLevel };
const warning = (text: string): Notice => ({ text, level: "warning" });
const REMOVED: Notice = { text: "editor closed · the draft is as before", level: "info" };

function setting(path: string): string | undefined {
  try {
    const value: unknown = JSON.parse(readFileSync(path, "utf8"));
    return isRecord(value) && typeof value.externalEditor === "string" && value.externalEditor.trim() !== "" ? value.externalEditor : undefined;
  } catch { return undefined; }
}

export function editorCommand(agentDir: string, cwd: string, env: NodeJS.ProcessEnv): string[] {
  const command = setting(join(cwd, ".pi", "settings.json")) ?? setting(join(agentDir, "settings.json")) ?? (env.VISUAL || env.EDITOR || "nano");
  return command.split(" ");
}

const clean = (text: string) => text.replace(/^\uFEFF/, "").replace(/\n$/, "");

export function koaEditor(options: { agentDir: string; cwd: () => string; session: () => string | undefined; name: () => string; replace(text: string): void; notify(text: string, level: NotifyLevel): void; changed(): void }) {
  let current: Open | undefined;
  let opening: Promise<unknown> = Promise.resolve();
  let preparing: { cancelled: boolean } | undefined;
  const float = createFloat({ label: "Editor", notify: options.notify, changed: options.changed });
  const outcome = async (open: Open, end: FloatEnd): Promise<{ notice?: Notice; text?: string }> => {
    switch (end.type) {
      case "removed": return { notice: REMOVED };
      case "lost": return { notice: warning("Editor link lost; draft kept") };
      case "cancelled": return {};
      case "dead": {
        const cause = end.cause;
        if (cause.type === "exited" && cause.code === 0) {
          try {
            const edited = clean(await readFile(open.file, "utf8"));
            return edited !== clean(open.text) ? { text: edited } : {};
          } catch (error) { return { notice: warning(`Editor result unreadable: ${errorText(error)}; draft kept`) }; }
        }
        return { notice: warning(cause.type === "exited" ? `Editor exited ${cause.code}; draft kept` : cause.type === "signaled" ? `Editor ended by signal ${cause.signal}; draft kept` : `Editor failed to start: ${cause.message}; draft kept`) };
      }
    }
  };
  const ended = (open: Open) => async (end: FloatEnd): Promise<void> => {
    const result = await outcome(open, end);
    current = undefined;
    if (result.text !== undefined && open.session === options.session()) options.replace(result.text);
    if (result.notice) options.notify(result.notice.text, result.notice.level);
    try { await rm(open.dir, { recursive: true, force: true }); } catch (error) { options.notify(`Editor cleanup failed: ${errorText(error)}`, "warning"); }
  };
  const start = async (text: string, self: string, ko: string, argv: string[]): Promise<{ pane: string } | { error: string }> => {
    const session = options.session();
    const prep = { cancelled: false };
    preparing = prep;
    let dir: string | undefined;
    try {
      dir = await mkdtemp(join(tmpdir(), "koa-editor-"));
      const file = join(dir, `koa-draft-${self}.md`);
      await writeFile(file, text, { mode: 0o600, flag: "wx" });
      if (prep.cancelled) throw new Error("The editor was cancelled");
      const open: Open = { dir, file, text, session, editor: basename(argv[0] ?? "nano") };
      current = open;
      const placed = await float.open(self, { command: { type: "argv", argv: [ko, "shell", "--", ...argv, file] }, cwd: options.cwd(), parent: self, close: "on_exit", fixed_title: `Draft for @${options.name()}`, close_confirm: "never" }, ended(open));
      if ("error" in placed) throw new Error(placed.error);
      return placed;
    } catch (error) {
      current = undefined;
      if (dir) await rm(dir, { recursive: true, force: true }).catch(() => {});
      return { error: errorText(error) };
    } finally { preparing = undefined; }
  };
  return {
    view: (): { pane: string; editor: string } | undefined => { const pane = float.view(); return pane && current ? { pane, editor: current.editor } : undefined; },
    open(text: string): Promise<{ pane: string } | { error: string }> {
      const pane = float.view();
      if (pane) return Promise.resolve({ pane });
      if (float.busy() || current || preparing) return Promise.resolve({ error: "The editor is busy" });
      const self = process.env.KO_PANE;
      if (!self) return Promise.resolve({ error: "C-g needs a ko pane" });
      if (process.env.KO_RUNTIME) return Promise.resolve({ error: "C-g cannot open an editor from inside a runtime" });
      const ko = findKo();
      if (!ko) return Promise.resolve({ error: "ko is not on PATH" });
      const work = start(text, self, ko, editorCommand(options.agentDir, options.cwd(), process.env));
      opening = work;
      return work;
    },
    busy: () => float.busy() || current !== undefined || preparing !== undefined,
    async cancel(): Promise<void> { if (preparing) preparing.cancelled = true; await float.cancel(); await opening; },
  };
}
