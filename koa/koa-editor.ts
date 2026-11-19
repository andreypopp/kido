import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import type { NotifyLevel } from "./koa-records.ts";
import { createFloat, placeFloat, type FloatEnd } from "./koa-float.ts";
import { findKo, KO_TIMEOUT_MS, runtimeExec } from "./runtime-exec.ts";
import type { Routes } from "./page/http.ts";
import type { CompletionContext } from "./completion-context.ts";
import { pathToken } from "./path-token.ts";
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

export function resolvePath(path: string, cwd: string, home: string): string {
  return path === '~' ? home : path.startsWith('~/') ? resolve(home, path.slice(2)) : resolve(cwd, path);
}

export function pathEditorCommand(argv: string[], path: string, line?: number): string[] {
  return [...argv, ...line !== undefined && ['vi', 'vim', 'nvim', 'nano', 'emacs', 'micro'].includes(basename(argv[0] ?? '')) ? ['+' + line] : [], path];
}

const keepFailedPath = 's=$?; if [ "$s" -ne 0 ] && [ "$s" -le 128 ]; then printf \'{"close":"keep"}\' | "$k" api -X PATCH --input - "/panes/$KO_PANE" >/dev/null; fi; exit "$s"';

export async function openPathEditor(text: string, context: CompletionContext, agentDir: string, self: string, valid: () => boolean): Promise<Routes['/editor/path']['response']> {
  const warn = (reason: string) => ({ type: 'warning' as const, text: `${text}: ${reason}` });
  const token = pathToken(text), ko = findKo();
  if (!token || !ko) return warn('cannot open the editor');
  let argv: string[], cwd: string, runtime: string | undefined;
  switch (context.type) {
    case 'unavailable': return warn('the runtime is not up');
    case 'host': {
      cwd = context.cwd;
      const path = resolvePath(token.path, cwd, homedir());
      try { await stat(path); } catch (error) { return warn(isRecord(error) && error.code === 'ENOENT' ? 'no such file' : errorText(error)); }
      if (!valid()) return warn('the session changed');
      argv = [ko, 'shell', '--', 'sh', '-c', 'k=$1; shift; "$@"; ' + keepFailedPath, 'sh', ko, ...pathEditorCommand(editorCommand(agentDir, cwd, process.env), path, token.line)];
      break;
    }
    case 'runtime': {
      cwd = context.cwd; runtime = context.name;
      const chunks: Buffer[] = [], stop = new AbortController();
      let bytes = 0;
      try {
        const result = await runtimeExec(ko, runtime, {
          argv: ['sh', '-lc', 'cd -- "$2" || exit 2; p=$1; case "$p" in "~") p=$HOME;; "~/"*) p=$HOME/${p#??};; esac; case "$p" in /*) ;; *) p=$PWD/$p;; esac; printf "%s\\000%s\\000" "${EDITOR:-vi}" "$p"; test -e "$p"', 'sh', token.path, cwd],
          signal: AbortSignal.any([AbortSignal.timeout(KO_TIMEOUT_MS), stop.signal]),
          onStdout(data) { bytes += data.length; if (bytes > 65536) stop.abort(); else chunks.push(data); },
        });
        if (!valid()) return warn('the session changed');
        if (result.end.type !== 'exit' || ![0, 1].includes(result.end.code)) return warn('the runtime is not up');
        if (result.end.code === 1) return warn('no such file');
        const [editor, path] = Buffer.concat(chunks).toString('utf8').split('\0');
        if (!editor || !path) return warn('the runtime is not up');
        const command = editor.split(' ');
        argv = ['sh', '-c', 's=$1; shift; exec sh -lc "$s" sh "$(command -v ko)" "$@"', 'sh', 'k=$1; cd -- "$2" && { shift 2; ${EDITOR:-vi} "$@"; }; ' + keepFailedPath, cwd, ...pathEditorCommand(command, path, token.line).slice(command.length)];
      } catch { return warn('the runtime is not up'); }
      break;
    }
  }
  if (!valid()) return warn('the session changed');
  const placed = await placeFloat({ command: { type: 'argv', argv }, ...(runtime ? { runtime } : { cwd }), parent: self, fixed_title: text, close_confirm: 'never' }, self, valid);
  return 'error' in placed ? warn(placed.error) : { type: 'opened', pane: placed.pane };
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
