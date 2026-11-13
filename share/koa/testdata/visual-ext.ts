import { readFileSync } from "node:fs";

const models: { provider: string; id: string; contextWindow: number }[] = JSON.parse(readFileSync(process.env.KOA_VISUAL ?? "", "utf8"));

export default function (pi: any) {
  const providers = new Map<string, object[]>();
  for (const { provider, id, contextWindow } of models) providers.set(provider, [...providers.get(provider) ?? [], { id, name: id, reasoning: true, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow, maxTokens: 4096, thinkingLevelMap: { xhigh: "high" } }]);
  for (const [name, list] of providers) pi.registerProvider(name, { baseUrl: process.env.KOA_PROVIDER_URL, apiKey: "koa-test-key", api: "openai-completions", compat: { supportsDeveloperRole: false }, models: list });
}
