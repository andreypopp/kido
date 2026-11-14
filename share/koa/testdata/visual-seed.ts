import { readFileSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";

type Item =
  | { kind: "message"; message: { role: string; timestamp: number } & Record<string, unknown> }
  | { kind: "custom"; customType: string; data: unknown; at: number }
  | { kind: "compaction"; summary: string; tokensBefore: number; at: number }
  | { kind: "branch"; summary: string; at: number }
  | { kind: "name"; name: string };
type Spec = { cwd: string; dir: string; sessions: { name: string; cwd?: string; modified?: number; items: Item[]; branches?: { label: string; items: Item[] }[] }[] };

const spec: Spec = JSON.parse(readFileSync(process.argv[2] ?? "", "utf8"));
const paths: Record<string, string> = {};
const ids: Record<string, string> = {};
for (const { name, cwd, modified, items, branches } of spec.sessions) {
  const id = "00000000-0000-7000-8000-" + String(Object.keys(paths).length + 1).padStart(12, "0");
  const manager = SessionManager.create(cwd ?? spec.cwd, spec.dir, { id });
  const times = new Map<string, number>();
  const add = (list: Item[]) => {
    let first: string | undefined;
    for (const item of list) {
      let id: string;
      if (item.kind === "message") {
        const { message } = item;
        if (message.role === "custom") id = manager.appendCustomMessageEntry(String(message.customType), message.content as string, message.display === true, message.details);
        else id = manager.appendMessage(message as never);
        times.set(id, message.timestamp);
        first ??= id;
      } else if (item.kind === "custom") { id = manager.appendCustomEntry(item.customType, item.data); times.set(id, item.at); }
      else if (item.kind === "compaction") { id = manager.appendCompaction(item.summary, first ?? null, item.tokensBefore); times.set(id, item.at); }
      else if (item.kind === "branch") { id = manager.branchWithSummary(manager.getLeafId(), item.summary); times.set(id, item.at); }
      else manager.appendSessionInfo(item.name);
    }
  };
  for (const branch of branches ?? []) {
    manager.resetLeaf();
    add(branch.items);
    ids[branch.label] = manager.appendCustomEntry("visual-leaf", {});
  }
  if (branches?.length) manager.resetLeaf();
  add(items);
  const made = manager.getSessionFile();
  if (!made) throw Error("session has no file");
  const file = join(spec.dir, "2026-11-10T09-00-00-000Z_" + id + ".jsonl");
  rmSync(made, { force: true });
  writeFileSync(file, [{ ...manager.getHeader(), timestamp: "2026-11-10T09:00:00.000Z" }, ...manager.getEntries().map(entry => { const at = times.get(entry.id); return at === undefined ? entry : { ...entry, timestamp: new Date(at).toISOString() }; })].map(line => JSON.stringify(line)).join("\n") + "\n");
  if (modified !== undefined) utimesSync(file, modified / 1000, modified / 1000);
  paths[name] = file;
}
process.stdout.write(JSON.stringify({ paths, ids }) + "\n");
