import type { ChildProcess } from "node:child_process";
import type { components } from "./ko-api.d.ts";
import { isRelation, type AgentRef, type InProcessMessage } from "./records.ts";
import { lineReader, openStream } from "./runtime-exec.ts";
import { isRecord, isString } from "./text.ts";
import { later } from "./koa-timer.ts";

type Api = components["schemas"];

export type Inbox = { close(): void };

type Dispatch = {
  message(target: string | undefined, message: InProcessMessage): Promise<"ack" | "refuse">;
  select(record: string): void;
  stop(): void;
};

const RECEIVED_RING = 4096;
const reconnectBackoff = (previous: number): number => Math.min(previous ? previous * 2 : Number(process.env.KO_RECEIVER_BACKOFF_MS) || 200, 5000);

function isSender(value: unknown): value is Api["Sender"] {
  return isRecord(value) && (value.type === "user" || (value.type === "pane" && isString(value.pane)));
}

const MESSAGE_KINDS = ["message", "steer", "interrupt", "stop", "notice", "select", "user"];

function isMessage(value: unknown): value is Api["Message"] {
  if (!isRecord(value) || typeof value.seq !== "number" || !isString(value.id) || !isSender(value.from)) return false;
  if (value.from.type === "pane" && !isRelation(value.relation)) return false;
  return isString(value.kind) && MESSAGE_KINDS.includes(value.kind) && isString(value.text);
}

type Data = { to?: string; from?: { session: string; name: string }; runtime?: string };

function decodeData(data: unknown): Data | undefined {
  if (data === undefined || data === null) return {};
  if (!isRecord(data)) return undefined;
  const out: Data = {};
  if (data.to !== undefined) { if (typeof data.to !== "string" || !data.to) return undefined; out.to = data.to; }
  if (data.runtime !== undefined) { if (typeof data.runtime !== "string") return undefined; out.runtime = data.runtime; }
  if (data.from !== undefined) {
    if (!isRecord(data.from) || typeof data.from.session !== "string" || !data.from.session || typeof data.from.name !== "string" || !data.from.name) return undefined;
    out.from = { session: data.from.session, name: data.from.name };
  }
  return out;
}

const label = (from: Api["Sender"]): string => (from.type === "pane" ? from.name || from.session || from.pane : "the user");

function senderOf(m: Api["Message"], data: Data): { agent: AgentRef; returnTo?: { session: string; pane: string } } {
  if (m.from.type !== "pane") return { agent: { name: label(m.from) } };
  if (data.from) return { agent: { name: data.from.name, session: data.from.session, pane: m.from.pane }, returnTo: { session: data.from.session, pane: m.from.pane } };
  return { agent: { name: label(m.from), ...(m.from.session ? { session: m.from.session } : {}), pane: m.from.pane } };
}

export async function handleMessage(m: Api["Message"], dispatch: Dispatch): Promise<"ack" | "refuse"> {
  const data = decodeData(m.data);
  if (!data) return "refuse";
  switch (m.kind) {
    case "user": return m.text ? dispatch.message(data.to, { kind: "user", text: m.text }) : "ack";
    case "message": case "steer": case "interrupt": {
      const sender = senderOf(m, data);
      const runtime = data.runtime;
      return dispatch.message(data.to, { kind: m.kind, text: m.text, agent: sender.agent, relation: m.relation, ...(runtime ? { runtime } : {}), ...(sender.returnTo && m.from.type === "pane" ? { returnTo: sender.returnTo } : {}) });
    }
    case "notice": return m.text ? dispatch.message(data.to, { kind: "notice", text: m.text, agent: senderOf(m, data).agent }) : "ack";
    case "stop":
      if (data.to !== undefined) return "refuse";
      dispatch.stop();
      return "ack";
    case "select":
      if (m.from.type === "user") dispatch.select(m.text);
      return "ack";
    default: return "refuse";
  }
}

export function openInbox(ko: string, pane: string, dispatch: Dispatch, gate: () => Promise<void>): Inbox {
  const ring: string[] = [];
  let child: ChildProcess | undefined;
  let timer: NodeJS.Timeout | undefined;
  let backoff = 0;
  let active = true;
  let queue: Promise<void> = Promise.resolve();
  const answer = (id: string, type: "ack" | "refuse"): void => {
    child?.stdin?.write(JSON.stringify({ type, id } satisfies Api["StreamRequest"]) + "\n");
  };
  const onLine = (line: string): void => {
    let decoded: unknown;
    try { decoded = JSON.parse(line); } catch { return; }
    if (!isMessage(decoded)) {
      if (isRecord(decoded) && typeof decoded.id === "string") answer(decoded.id, "refuse");
      return;
    }
    const message = decoded;
    queue = queue.then(async () => {
      if (ring.includes(message.id)) { answer(message.id, "ack"); return; }
      let verdict: "ack" | "refuse";
      try { await gate(); verdict = await handleMessage(message, dispatch); } catch { verdict = "refuse"; }
      if (verdict === "ack") {
        ring.push(message.id);
        if (ring.length > RECEIVED_RING) ring.splice(0, ring.length - RECEIVED_RING);
      }
      answer(message.id, verdict);
    });
  };
  const open = (): void => {
    timer = undefined;
    if (!active) return;
    const next = openStream(ko, `/panes/${pane}/messages`);
    child = next;
    next.stdout?.on("data", lineReader({ partial: Buffer.alloc(0) }, line => { backoff = 0; onLine(line); }));
    const exited = (): void => {
      if (child === next) child = undefined;
      if (!active || timer) return;
      backoff = reconnectBackoff(backoff);
      timer = later(open, backoff);
      timer.unref();
    };
    next.once("exit", exited);
    next.once("error", exited);
  };
  open();
  return { close() { active = false; clearTimeout(timer); child?.kill(); child = undefined; } };
}
