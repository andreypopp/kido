import { readFileSync, existsSync } from "node:fs";

type Action =
  | { notify: { message: string; type: "info" | "warning" | "error" }[] }
  | { status: { key: string; text?: string }[] }
  | { send: string; deliverAs?: "steer" | "followUp" }
  | { trigger: string; deliverAs?: "followUp" | "steer" }
  | { annotate: object[] }
  | { abort: true };

const spec: { models?: { provider: string; id: string; contextWindow: number }[]; ids?: Record<string, string>; steps: Record<string, Action[]>; commands?: { name: string; description: string }[]; hold?: string } = JSON.parse(readFileSync(process.env.KOA_VISUAL ?? "", "utf8"));
const empty = { type: "object", properties: {} };

export default function (pi: any) {
  const providers = new Map<string, object[]>();
  for (const { provider, id, contextWindow } of spec.models ?? []) providers.set(provider, [...providers.get(provider) ?? [], { id, name: id, reasoning: true, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow, maxTokens: 4096, thinkingLevelMap: { xhigh: "high" } }]);
  for (const [name, models] of providers) pi.registerProvider(name, { baseUrl: process.env.KOA_PROVIDER_URL, apiKey: "koa-test-key", api: "openai-completions", compat: { supportsDeveloperRole: false }, models });
  pi.registerCommand("vstep", {
    description: "Run one step of a visual test",
    handler: async (name: string, ctx: any) => {
      if (name.startsWith("tree ")) { const target = spec.ids?.[name.slice(5).trim()]; if (!target) throw Error("unknown tree label " + name); await ctx.navigateTree(target, { summarize: false }); return; }
      for (const action of spec.steps[name.trim()] ?? []) {
        if ("notify" in action) for (const note of action.notify) ctx.ui.notify(note.message, note.type);
        else if ("status" in action) for (const { key, text } of action.status) ctx.ui.setStatus(key, text);
        else if ("send" in action) pi.sendUserMessage(action.send, action.deliverAs ? { deliverAs: action.deliverAs } : undefined);
        else if ("trigger" in action) pi.sendMessage({ customType: "visual-trigger", content: action.trigger, display: false }, { triggerTurn: true, ...(action.deliverAs ? { deliverAs: action.deliverAs } : {}) });
        else if ("annotate" in action) {
          const reply = ctx.sessionManager.getBranch().map((entry: any) => entry.message).filter((message: any) => message?.role === "assistant").at(-1);
          const text = reply.content.map((block: any) => block.text ?? "").join("");
          pi.appendEntry("reply-annotations", { reply: { at: reply.timestamp, block: 0, length: [...text].length }, annotations: action.annotate });
        } else if ("abort" in action) ctx.abort();
        else throw Error("unknown step action " + JSON.stringify(action));
      }
    },
  });
  for (const { name, description } of spec.commands ?? []) pi.registerCommand(name, { description, handler: async () => {} });
  if (spec.hold) pi.on("session_before_switch", async () => { const deadline = performance.now() + 30000; while (existsSync(spec.hold ?? "") && performance.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20)); });
  pi.registerTool({
    name: "release", label: "release", description: "Release with dialogs", parameters: empty,
    async execute(_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) {
      const answers = [ctx.ui.select("Which tap revision?", ["0.31.1 · 20857320", "0.31.0 · 6153fce8", "custom…"], { timeout: 20000 }), ctx.ui.confirm("Force-push main?", "origin/main moves from 20857320 to 88bdb070. Other clones need a reset.")];
      await Promise.all(answers);
      await ctx.ui.input("Version for the tap", "0.32.0", { timeout: 49000 });
      await ctx.ui.editor("Release notes", "## 0.32\n\n- The sidebar shows status at the right and folds children\n- A program can show a webview page in its pane");
      return { content: [{ type: "text", text: "Released" }], details: {} };
    },
  });
  pi.registerTool({
    name: "edit", label: "edit", description: "Edit a file",
    parameters: { type: "object", properties: { path: { type: "string" }, oldText: { type: "string" }, newText: { type: "string" } } },
    async execute() { return { content: [{ type: "text", text: "Edit applied" }], details: {} }; },
  });
  pi.registerTool({
    name: "ask", label: "ask", description: "Ask for a value", parameters: empty,
    async execute(_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) {
      await ctx.ui.input("Which tap revision?");
      return { content: [{ type: "text", text: "Asked" }], details: {} };
    },
  });
}
