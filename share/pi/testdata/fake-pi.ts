import { readFileSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";

const fixture = readFileSync(new URL("kido-pi-session.jsonl", import.meta.url), "utf8").trim().split("\n").map(line => JSON.parse(line));
const model = { id: "fixture", name: "Fixture (no model)", provider: "fake", reasoning: true, contextWindow: 200000, maxTokens: 8192, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const state = { sessionId: "fake-session", sessionFile: "/tmp/kido-pi-fake.jsonl", model, thinkingLevel: "medium", isStreaming: false, isCompacting: false, steeringMode: "all", followUpMode: "all", messageCount: 0, pendingMessageCount: 0 };
let entries: Record<string, any>[] = [], leafId: string | null = null, pending = "", replay: NodeJS.Timeout | undefined, index = 0;
const utf8 = new StringDecoder("utf8");
function emit(value: Record<string, any>) { process.stdout.write(JSON.stringify(value) + "\n"); }
function append(message: Record<string, any>) {
  const id = `entry-${entries.length + 1}`;
  entries.push({ type: "message", id, parentId: leafId, timestamp: new Date(message.timestamp ?? 1700000000000).toISOString(), message });
  leafId = id; state.messageCount = entries.length;
}
function command(value: Record<string, any>) {
  let data: unknown = {};
  if (value.type === "extension_ui_response") { emit({ type: "extension_ui_request", id: "answer-notify", method: "notify", message: `Dialog answered: ${value.confirmed ?? value.cancelled}`, notifyType: "info" }); return; }
  switch (value.type) {
    case "fixture_snapshot":
      for (const event of fixture.filter(event => ["message_start", "message_update", "tool_execution_start", "tool_execution_update", "extension_ui_request"].includes(event.type)).slice(0, 15)) emit(event);
      emit({ type: "extension_ui_request", id: "fixture-confirm", method: "confirm", title: "Apply change?", message: "Keep the greeting change?" });
      emit({ type: "compaction_start", reason: "threshold" });
      break;
    case "get_state": data = state; break;
    case "get_entries": data = { entries: value.since ? entries.slice(entries.findIndex(entry => entry.id === value.since) + 1) : entries, leafId }; break;
    case "get_available_models": data = { models: [model] }; break;
    case "get_available_thinking_levels": data = { levels: ["off", "low", "medium", "high"] }; break;
    case "get_commands": data = { commands: [{ name: "fixture", description: "Replay the fixture", source: "extension" }] }; break;
    case "set_model": state.model = { ...model, id: value.modelId, provider: value.provider }; data = state.model; break;
    case "set_thinking_level": state.thinkingLevel = value.level; data = { level: value.level }; break;
    case "abort": clearInterval(replay); replay = undefined; state.isStreaming = false; emit({ type: "agent_end", messages: [] }); break;
    case "clear_queue": data = { steering: ["Check tests too"], followUp: ["Summarize the changes"] }; emit({ type: "queue_update", steering: [], followUp: [] }); break;
    case "new_session": case "switch_session": case "fork": case "clone": entries = []; leafId = null; data = { cancelled: false }; break;
    case "prompt":
      if (replay) { emit({ type: "queue_update", steering: value.streamingBehavior === "steer" ? [value.message] : [], followUp: value.streamingBehavior === "followUp" ? [value.message] : [] }); break; }
      append({ role: "user", content: value.message, timestamp: 1700000000000 });
      emit({ type: "message_end", message: entries.at(-1)!.message });
      state.isStreaming = true; index = 0;
      replay = setInterval(() => {
        const event = fixture[index++];
        if (event.type === "fixture_entry") {
          const id = `entry-${entries.length + 1}`;
          entries.push({ ...event.entry, id, parentId: leafId }); leafId = id;
          emit({ type: "compaction_end" }); return;
        }
        if (event.type === "message_end") append(event.message);
        if (event.type === "response" && event.command === "bash") append({ role: "bashExecution", command: "printf 'first\\nsecond\\n'", ...event.data, timestamp: 1700000000125 });
        if (event.type === "agent_end") { state.isStreaming = false; clearInterval(replay); replay = undefined; }
        emit(event);
      }, 35);
      break;
    default: emit({ type: "response", id: value.id, command: value.type, success: false, error: "Unsupported fake command" }); return;
  }
  emit({ type: "response", id: value.id, command: value.type, success: true, data });
}
process.stdin.on("data", bytes => {
  pending += utf8.write(bytes);
  let end;
  while ((end = pending.indexOf("\n")) >= 0) { const line = pending.slice(0, end); pending = pending.slice(end + 1); command(JSON.parse(line)); }
});
process.stdin.on("end", () => { clearInterval(replay); process.exit(0); });
