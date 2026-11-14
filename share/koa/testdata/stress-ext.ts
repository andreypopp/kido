const schema = (properties: object) => ({ type: "object", properties });

export default function (pi: any) {
  pi.on("agent_end", (_event: unknown, ctx: any) => { ctx.ui.notify("STRESS DONE " + process.env.KOA_STRESS_ID, "info"); });
  pi.registerTool({
    name: "big", label: "big", description: "A tool with a large argument and a large result", parameters: schema({ data: { type: "string" } }),
    async execute() { return { content: [{ type: "text", text: "r".repeat(16 * 1024 * 1024) }], details: {} }; },
  });
  pi.registerTool({
    name: "pay", label: "pay", description: "A tool with a result of 64 KiB", parameters: schema({}),
    async execute() { return { content: [{ type: "text", text: "slow reader payload ".repeat(3277) }], details: {} }; },
  });
}
