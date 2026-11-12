import type { ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { components } from "../pi/ko-api.d.ts";
import { apiCall, KO_TIMEOUT_MS, lineReader, openStream } from "../pi/runtime-exec.ts";
import { errorText, isRecord } from "../pi/text.ts";
import { later } from "./koa-timer.ts";

type Api = components["schemas"];
type Open = { pane: string; dir: string; file: string; text: string; session: string | undefined; editor: string; observer: ChildProcess };
type Run = { cancelled: boolean; lost: boolean; done: Promise<unknown> };
type Stage = { type: "idle" } | { type: "opening"; run: Run } | ({ type: "open" } & Open) | { type: "closing" };

const STALE_RETRIES = 3;

const leaves = (node: Api["LeafNode"]): string[] => "children" in node ? node.children.flatMap(leaves) : [node.pane];
const draftNode = (node: Api["LeafNode"]): Api["DraftLeafNode"] => "children" in node ? { split: node.split, children: node.children.map(draftNode) } : { pane: node.pane, cols: node.cols, rows: node.rows };
const draftWindow = (window: Api["Window"], extra: Api["DraftFloat"][]): Api["DraftWindow"] => ({
  id: window.id, name: window.name, vars: window.vars, cols: window.cols, rows: window.rows,
  ...(window.cell_px ? { cell_px: window.cell_px } : {}), ...(window.zoom ? { zoom: window.zoom } : {}),
  tree: draftNode(window.tree),
  floats: [...window.floats.map(({ pane, x, y, cols, rows, z, border, title }) => ({ pane, x, y, cols, rows, z, border, title })), ...extra],
});

const windowOf = (layout: Api["Layout"], pane: string): Api["Window"] | undefined => layout.sessions.flatMap(session => session.windows).find(window => leaves(window.tree).includes(pane) || window.floats.some(float => float.pane === pane));

const FLOAT_SHARE = 0.8;
const MIN_FLOAT = { cols: 60, rows: 16 };
type Rect = { x: number; y: number; cols: number; rows: number };

// A split puts one separator cell between its children.
function tiledRect(node: Api["LeafNode"], pane: string, x: number, y: number): Rect | undefined {
  if (!("children" in node)) return node.pane === pane ? { x, y, cols: node.cols, rows: node.rows } : undefined;
  let offset = 0;
  for (const child of node.children) {
    const found = tiledRect(child, pane, node.split === "h" ? x + offset : x, node.split === "h" ? y : y + offset);
    if (found) return found;
    const size = leafSize(child);
    offset += (node.split === "h" ? size.cols : size.rows) + 1;
  }
  return undefined;
}

function leafSize(node: Api["LeafNode"]): { cols: number; rows: number } {
  if (!("children" in node)) return node;
  const sizes = node.children.map(leafSize);
  return node.split === "h"
    ? { cols: sizes.reduce((sum, size) => sum + size.cols, sizes.length - 1), rows: Math.max(...sizes.map(size => size.rows)) }
    : { cols: Math.max(...sizes.map(size => size.cols)), rows: sizes.reduce((sum, size) => sum + size.rows, sizes.length - 1) };
}

// The float is centred over koa's pane, 80% of it but not under the minimum; a pane under the minimum gives way
// to the whole window. The server counts a border outside cols and rows, so the float stays one cell inside.
export function floatRect(window: Api["Window"], self: string): Rect {
  const pane = tiledRect(window.tree, self, 0, 0) ?? { x: 0, y: 0, cols: window.cols, rows: window.rows };
  const small = pane.cols < MIN_FLOAT.cols || pane.rows < MIN_FLOAT.rows;
  const over = small ? { x: 0, y: 0, cols: window.cols, rows: window.rows } : pane;
  const fit = (wanted: number, room: number) => Math.max(1, Math.min(wanted, room - 2));
  const cols = fit(small ? MIN_FLOAT.cols : Math.max(MIN_FLOAT.cols, Math.floor(over.cols * FLOAT_SHARE)), window.cols);
  const rows = fit(small ? MIN_FLOAT.rows : Math.max(MIN_FLOAT.rows, Math.floor(over.rows * FLOAT_SHARE)), window.rows);
  const place = (at: number, room: number, size: number, whole: number) => Math.max(1, Math.min(at + Math.floor((room - size) / 2), whole - size - 1));
  return { x: place(over.x, over.cols, cols, window.cols), y: place(over.y, over.rows, rows, window.rows), cols, rows };
}

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

export function koaEditor(options: { agentDir: string; cwd: () => string; session: () => string | undefined; replace(text: string): void; notify(text: string): void; changed(): void }) {
  let stage: Stage = { type: "idle" };
  const observe = (run: Run): Promise<{ child: ChildProcess; deaths: Map<string, Api["Cause"]>; seen: Set<string>; latest: Set<string> }> => new Promise((resolve, reject) => {
    const watch = { child: openStream("ko", "/client", "pipe"), deaths: new Map<string, Api["Cause"]>(), seen: new Set<string>(), latest: new Set<string>() };
    let welcomed = false;
    const timer = later(() => { watch.child.kill(); reject(new Error("ko did not answer the observer")); }, KO_TIMEOUT_MS);
    watch.child.stdin?.write(JSON.stringify({ type: "hello", name: "koa-editor", focused: false, webview: false, sizing: { type: "disabled" } } satisfies Api["ClientRequest"]) + "\n");
    watch.child.stdout?.on("data", lineReader({ partial: Buffer.alloc(0) }, line => {
      let event: Api["ClientEvent"];
      try { event = JSON.parse(line); } catch { return; }
      if (event.type === "welcome" && !welcomed) { welcomed = true; clearTimeout(timer); resolve(watch); }
      else if (event.type === "dead") {
        if (stage.type === "open" && stage.pane === event.pane) void finish(stage, event.dead.cause);
        else if (stage.type === "opening" && stage.run === run) watch.deaths.set(event.pane, event.dead.cause);
      } else if (event.type === "layout") {
        watch.latest = new Set(event.layout.sessions.flatMap(session => session.windows).flatMap(window => [...leaves(window.tree), ...window.floats.map(float => float.pane)]));
        watch.latest.forEach(pane => watch.seen.add(pane));
        if (stage.type === "open" && stage.observer === watch.child && !watch.latest.has(stage.pane)) void cancel("Editor pane closed; draft kept");
      }
    }));
    watch.child.on("error", error => { clearTimeout(timer); reject(error); });
    watch.child.on("close", () => {
      clearTimeout(timer);
      if (!welcomed) reject(new Error("the observer ended before it started"));
      else if (stage.type === "open" && stage.observer === watch.child) void cancel("Editor link lost; draft kept");
      else if (stage.type === "opening" && stage.run === run) run.lost = true;
    });
  });
  const release = async (held: { dir?: string; observer?: ChildProcess; pane?: string }) => {
    held.observer?.stdin?.end(); held.observer?.kill();
    if (held.pane) {
      const reply = await apiCall("DELETE", `/panes/${held.pane}`);
      if ("error" in reply) options.notify(`Editor pane not closed: ${reply.error}`);
      else if (![200, 404, 410].includes(reply.status)) {
        let message = `HTTP ${reply.status}`;
        try { const body: Api["Error"] = JSON.parse(reply.body); message = body.message; } catch {}
        options.notify(`Editor pane not closed: ${message}`);
      }
    }
    if (held.dir) await rm(held.dir, { recursive: true, force: true });
  };
  const close = async (open: Open, notice?: string, text?: string) => {
    stage = { type: "closing" };
    if (text !== undefined && open.session === options.session()) options.replace(text);
    if (notice) options.notify(notice);
    try { await release(open); } catch (error) { options.notify(`Editor cleanup failed: ${errorText(error)}`); }
    stage = { type: "idle" }; options.changed();
  };
  const cancel = async (notice?: string) => {
    if (stage.type === "opening") { stage.run.cancelled = true; await stage.run.done; }
    else if (stage.type === "open") await close(stage, notice);
  };
  const finish = async (open: Open, cause: Api["Cause"]) => {
    if (cause.type === "exited" && cause.code === 0) {
      let edited: string;
      try { edited = clean(await readFile(open.file, "utf8")); } catch (error) { return close(open, `Editor result unreadable: ${errorText(error)}; draft kept`); }
      return close(open, undefined, edited !== clean(open.text) ? edited : undefined);
    }
    return close(open, cause.type === "exited" ? `Editor exited ${cause.code}; draft kept` : cause.type === "signaled" ? `Editor ended by signal ${cause.signal}; draft kept` : `Editor failed to start: ${cause.message}; draft kept`);
  };
  const place = async (pane: Api["CreatePane"], self: string): Promise<{ pane: string } | { error: string }> => {
    for (let attempt = 0; ; attempt++) {
      const read = await apiCall("GET", "/layout");
      if ("error" in read || read.status !== 200) return { error: "could not read the layout" };
      const snapshot: Api["LayoutPanes"] = JSON.parse(read.body);
      const target = windowOf(snapshot.layout, self);
      if (!target) return { error: "the pane is not in the layout" };
      const known = new Set([...leaves(target.tree), ...target.floats.map(float => float.pane)]);
      const float: Api["DraftFloat"] = { pane: { new: pane }, border: true, ...floatRect(target, self) };
      const draft: Api["DraftLayout"] = { sessions: snapshot.layout.sessions.map(session => ({ id: session.id, name: session.name, vars: session.vars, windows: session.windows.map(one => draftWindow(one, one.id === target.id ? [float] : [])) })) };
      const put = await apiCall("PUT", "/layout", { revision: snapshot.revision, layout: draft } satisfies Api["PutLayout"]);
      if ("error" in put) return put;
      if (put.status === 200) {
        const placed: Api["Snapshot"] = JSON.parse(put.body);
        const created = placed.layout.sessions.flatMap(session => session.windows).find(one => one.id === target.id)?.floats.find(float => !known.has(float.pane));
        return created ? { pane: created.pane } : { error: "the layout has no new float" };
      }
      if (put.status !== 409 || attempt >= STALE_RETRIES) return { error: `the layout was refused (${put.status})` };
    }
  };
  const start = async (run: Run, text: string, self: string, argv: string[]): Promise<{ pane: string } | { error: string }> => {
    const session = options.session();
    let dir: string | undefined, observer: ChildProcess | undefined, pane: string | undefined;
    const proceed = () => { if (run.cancelled) throw new Error("The editor was cancelled"); if (run.lost) throw new Error("Editor link lost"); };
    try {
      dir = await mkdtemp(join(tmpdir(), "koa-editor-"));
      const file = join(dir, `koa-draft-${self}.md`);
      await writeFile(file, text, { mode: 0o600, flag: "wx" });
      proceed();
      const watch = await observe(run);
      observer = watch.child;
      proceed();
      const placed = await place({ command: { type: "argv", argv: [...argv, file] }, cwd: options.cwd(), parent: self, close: "on_exit" }, self);
      if ("error" in placed) throw new Error(placed.error);
      pane = placed.pane;
      proceed();
      if (watch.seen.has(pane) && !watch.latest.has(pane)) throw new Error("Editor pane closed");
      const open: Open = { pane, dir, file, text, session, editor: basename(argv[0] ?? "nano"), observer };
      stage = { type: "open", ...open };
      options.changed();
      const cause = watch.deaths.get(pane);
      if (cause) void finish(open, cause);
      return { pane };
    } catch (error) {
      stage = { type: "closing" };
      await release({ dir, observer, pane }).catch(() => {});
      stage = { type: "idle" };
      return { error: errorText(error) };
    }
  };
  return {
    view: (): { pane: string; editor: string } | undefined => stage.type === "open" ? { pane: stage.pane, editor: stage.editor } : undefined,
    open(text: string): Promise<{ pane: string } | { error: string }> {
      if (stage.type === "open") return Promise.resolve({ pane: stage.pane });
      if (stage.type !== "idle") return Promise.resolve({ error: "The editor is busy" });
      const self = process.env.KO_PANE;
      if (!self) return Promise.resolve({ error: "C-g needs a ko pane" });
      if (process.env.KO_RUNTIME) return Promise.resolve({ error: "C-g cannot open an editor from inside a runtime" });
      const run: Run = { cancelled: false, lost: false, done: Promise.resolve() };
      stage = { type: "opening", run };
      const work = start(run, text, self, editorCommand(options.agentDir, options.cwd(), process.env));
      run.done = work;
      return work;
    },
    busy: () => stage.type !== "idle",
    cancel: () => cancel(),
  };
}
