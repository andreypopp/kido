import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { randomUUID } from "node:crypto";
import { webview } from "../../webview/index.ts";
import { assemblePage } from "../koa-assemble.ts";
import { attachments, stepFile } from "../koa-attach.ts";
import { readBody, respond, serveFile, wrongPostType } from "../koa-http.ts";
import { pathArg, type Attachment, type PageRecord, type WireItem } from "../koa-records.ts";
import { findKo } from "../runtime-exec.ts";
import { errorText, isRecord } from "../text.ts";
import type { Batch, Input, Scenarios } from "./scenario.ts";

const argv = process.argv.slice(2);
const browser = argv[0] === "--browser";
const [module, method, dir] = browser ? argv.slice(1) : argv;
if (!module || !method || !dir || argv.length !== (browser ? 4 : 3)) throw Error("usage: replay.ts [--browser] <module> <test-method> <asset-dir>");
const loaded: { scenarios: Scenarios } = await import(new URL(`./scenarios/${module}.ts`, import.meta.url).href);
const build = loaded.scenarios[method];
if (!build) throw Error(`${module} has no scenario ${method}`);
const { open, steps, files } = build(dir);

const instance = randomUUID();
const page = await assemblePage(new URL("../../../build/ko/share/ko/koa/koa.ts", import.meta.url), instance);
const store = mkdtempSync(join(tmpdir(), `koa-replay-${process.pid}-`));
const attached = attachments(store);
const view = await webview({ target: browser ? "browser" : "pane", ...(browser ? {} : { ko: findKo() ?? undefined }) });
if (!view) throw Error("replay requires a Kido pane or --browser");

let index = 0, mismatches = 0, last: string | undefined;
const waiting = new Set<() => void>();
const advanced = () => { for (const wake of waiting) wake(); waiting.clear(); };
let tail: Promise<unknown> = Promise.resolve();
const serial = <T>(run: () => Promise<T>): Promise<T> => { const result = tail.then(run); tail = result.catch(() => {}); return result; };
const changed = (ms: number) => new Promise<void>(resolve => { const timer = setTimeout(resolve, ms); waiting.add(() => { clearTimeout(timer); resolve(); }); });
const held = new Map<string, () => void>();
const subscribers = new Set<ServerResponse>();
const items = new Map<number, WireItem>();
const queued = { steer: [] as Attachment[][], followUp: [] as Attachment[][] };

const push = (records: PageRecord[]) => {
  for (const record of records) {
    if (record.type === "reset") { items.clear(); for (const item of record.items) items.set(item.seq, item); }
    else if (record.type === "item") items.set(record.item.seq, record.item);
    else if (record.type === "patch") {
      const item = items.get(record.seq);
      if (item?.kind === "assistant") {
        const blocks = [...item.blocks];
        for (const change of record.blocks) {
          const block = blocks[change.index];
          if ("block" in change) blocks[change.index] = change.block;
          else if (block && block.type !== "tool") blocks[change.index] = { ...block, text: block.text + change.suffix };
        }
        items.set(record.seq, { ...item, blocks });
      }
    }
    const line = `data: ${JSON.stringify(record)}\n\n`;
    for (const response of subscribers) response.write(line);
  }
};
const pathAt = (seq: number, block: number) => {
  const item = items.get(seq);
  if (item?.kind === "assistant") return pathArg(item.blocks[block]);
  if (item?.kind === "command" && item.result.type === "export" && block === 0) return item.result.path;
};
const resolve = (batch: Batch | undefined, input: Input) => typeof batch === "function" ? batch(input) : batch ?? [];
const mismatch = (response: ServerResponse, text: string) => { mismatches++; last = text; respond(response, 409, JSON.stringify({ error: text })); };

push(open);

const events = (url: URL, response: ServerResponse) => {
  if (url.searchParams.has("koa") && url.searchParams.get("koa") !== instance) { respond(response, 200, `data: ${JSON.stringify({ type: "reload" } satisfies PageRecord)}\n\n`, "text/event-stream"); return; }
  response.writeHead(200, { "Content-Type": "text/event-stream" });
  if (url.searchParams.get("epoch")) response.write(":\n\n");
  else for (const record of open) response.write(`data: ${JSON.stringify(record)}\n\n`);
  response.once("close", () => subscribers.delete(response));
  subscribers.add(response);
};

const control = async (request: IncomingMessage, response: ServerResponse, path: string) => {
  if (path === "/replay/status" && request.method === "GET") { respond(response, 200, JSON.stringify({ step: index, total: steps.length, mismatches, ...(last === undefined ? {} : { last }), pending: [...held.keys()] })); return; }
  const bytes = request.method === "POST" ? await readBody(request, 1 << 20) : undefined;
  if (path === "/replay/next" && bytes) {
    const until = Date.now() + 5000;
    for (;;) {
      const outcome = await serial(async () => {
        const step = steps[index];
        if (step?.on === "next") { index++; push(step.records); advanced(); return "done" as const; }
        if (typeof step?.on === "object" && Date.now() < until) return { wait: changed(until - Date.now()) };
        mismatch(response, `${step ? "expected " + describe(step) : "no step left"}, got /replay/next`);
        return "failed" as const;
      });
      if (outcome === "failed") return;
      if (outcome === "done") { respond(response, 200, "{}"); return; }
      await outcome.wait;
    }
  }
  if (path === "/replay/release" && bytes) {
    const value: unknown = JSON.parse(bytes.toString("utf8"));
    const name = isRecord(value) && typeof value.name === "string" ? value.name : undefined;
    const release = name === undefined ? undefined : held.get(name);
    if (!release) { mismatch(response, `no held reply named ${String(name)}`); return; }
    release(); respond(response, 200, "{}"); return;
  }
  respond(response, 404, "{}");
};

const describe = (step: (typeof steps)[number]) => step.on === "next" ? "/replay/next" : `${step.on.method} ${step.on.path}`;

const handle = async (request: IncomingMessage, response: ServerResponse) => {
  const url = new URL(request.url ?? "/", "http://replay");
  if (wrongPostType(request)) { respond(response, 415, "{}"); return; }
  if (request.method === "GET" && url.pathname === "/events") { events(url, response); return; }
  if (url.pathname.startsWith("/replay/")) { await control(request, response, url.pathname); return; }
  if (await attached.handle(request, response, () => {})) return;
  if (await stepFile(request, response, pathAt, dir, dir, () => {})) return;
  if (request.method === "GET" && url.pathname.startsWith("/images/")) {
    url.searchParams.delete("sessionId");
    const file = files[url.pathname + url.search];
    if (file) await serveFile(response, file, basename(file), 410); else respond(response, 410, "{}");
    return;
  }
  if (request.method === "GET" && url.pathname === "/") { respond(response, 200, page, "text/html; charset=utf-8"); return; }
  let value: unknown = Object.fromEntries(url.searchParams);
  if (request.method === "POST") {
    const bytes = await readBody(request, 1 << 20);
    if (!bytes) { respond(response, 413, "{}"); return; }
    try { value = JSON.parse(bytes.toString("utf8")); } catch { respond(response, 400, JSON.stringify({ error: "A JSON body is required" })); return; }
  }
  await serial(async () => {
    const step = steps[index], actual = `${request.method} ${url.pathname}`;
    if (!step || step.on === "next" || step.on.method !== request.method || step.on.path !== url.pathname || step.on.body && !step.on.body(value)) { mismatch(response, `expected ${step ? describe(step) : "no request"}, got ${actual} ${JSON.stringify(value)}`); return; }
    const mode = isRecord(value) && value.mode === "follow_up" ? queued.followUp : queued.steer;
    const ids = isRecord(value) && Array.isArray(value.attachments) ? value.attachments.filter(id => typeof id === "string") : [];
    let uploads: Attachment[] = [];
    if (step.on.path === "/prompt") {
      try { uploads = (await attached.prepare(ids)).files; } catch (error) { mismatch(response, `${actual}: ${errorText(error)}`); return; }
    } else if (step.on.path === "/queue/clear") uploads = [...queued.steer, ...queued.followUp].flat();
    else if (step.on.path === "/queue/remove" && isRecord(value) && typeof value.index === "number") uploads = (value.kind === "steer" ? queued.steer : queued.followUp)[value.index] ?? [];
    const input: Input = { body: value, attachments: uploads };
    push(resolve(step.before, input));
    const send = () => {
      const ok = step.reply.status === 200;
      const json = typeof step.reply.json === "function" ? step.reply.json(input) : step.reply.json;
      if (ok && step.on.path === "/prompt" && "disposition" in json && json.disposition !== "handled") {
        attached.consume(ids, json.disposition === "queued" ? "queued" : "used");
        if (json.disposition === "queued") mode.push(uploads);
      } else if (ok && step.on.path === "/queue/clear") { attached.restore(uploads.map(file => file.id)); queued.steer.length = queued.followUp.length = 0; }
      else if (ok && step.on.path === "/queue/remove" && isRecord(value) && typeof value.index === "number") {
        attached.restore(uploads.map(file => file.id));
        (value.kind === "steer" ? queued.steer : queued.followUp).splice(value.index, 1);
      }
      if (!response.destroyed) respond(response, step.reply.status, JSON.stringify(json));
      push(resolve(step.after, input));
    };
    const name = step.reply.hold;
    if (name === undefined) send();
    else held.set(name, () => { held.delete(name); send(); });
    index++;
    advanced();
  });
};

const server = createServer((request, response) => { handle(request, response).catch(error => { process.stderr.write(`replay: ${errorText(error)}\n`); if (!response.headersSent) respond(response, 500, JSON.stringify({ error: errorText(error) })); }); });
const quit = () => {
  server.close(); server.closeAllConnections(); attached.close();
  void view.close(true).catch(() => {}).finally(() => { rmSync(store, { recursive: true, force: true }); process.exit(0); });
};
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(signal, quit);
await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(view.socketPath, resolve); });
const show = (supported: boolean) => { if (supported) void view.show(); };
view.on("supported", show); show(view.supported);
if (view.url) process.stderr.write(`replay: ${view.url}\n`);
