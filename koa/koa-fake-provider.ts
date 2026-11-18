import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const providerName = "fake";
export const modelId = "fake-model";
export const apiKey = "koa-test-key";

export type Reply = {
  when?: string;
  reasoning?: string;
  text?: string;
  tools?: { name: string; args: object; pieces?: number }[];
  status?: number;
  gate?: string;
  midGate?: string;
  chunks?: string[];
  delayMs?: number;
  stages?: { gate: string; chunks: string[] }[];
  tokens?: { prompt: number; completion: number };
};
export type Part = { type: string; text?: string; image_url?: { url: string } };
const isPart = (value: unknown): value is Part => typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
export type Request = { body: { model: string; messages: { role: string; content: unknown; tool_calls?: unknown[]; tool_call_id?: string }[]; tools?: { function: { name: string } }[] }; aborted: boolean };


export type Model = { provider: string; id: string; name?: string; contextWindow?: number };

export async function startProvider(script: Reply[], deadlineMs = 10000, accepted: string[] = [modelId]) {
  const requests: Request[] = [];
  const violations: string[] = [];
  const gates = new Map<string, { open: boolean; waiters: (() => void)[] }>();
  const gate = (name: string) => { let found = gates.get(name); if (!found) { found = { open: false, waiters: [] }; gates.set(name, found); } return found; };
  const wait = (name: string) => new Promise<void>((resolve, reject) => {
    const g = gate(name);
    if (g.open) return resolve();
    const timer = setTimeout(() => reject(Error(`gate ${name} was not released within ${deadlineMs} ms`)), deadlineMs);
    timer.unref();
    g.waiters.push(() => { clearTimeout(timer); resolve(); });
  });
  let next = 0;
  const used = new Set<number>();
  const lastUser = (body: Request["body"]): string => {
    const content = body.messages.filter(message => message.role === "user").at(-1)?.content;
    return typeof content === "string" ? content : Array.isArray(content) ? content.filter(isPart).map(part => part.text ?? "").join("") : "";
  };
  const sockets = new Set<import("node:net").Socket>();
  const reject = (response: ServerResponse, status: number, message: string) => {
    violations.push(message);
    response.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify({ error: { message } }));
  };
  const read = (request: IncomingMessage) => new Promise<string>((resolve, fail) => {
    let text = ""; request.setEncoding("utf8");
    request.on("data", bytes => { text += bytes; }); request.on("end", () => resolve(text)); request.on("error", fail);
  });
  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== "/v1/chat/completions") return reject(response, 404, `unexpected ${request.method} ${request.url}`);
    if (request.headers.authorization !== `Bearer ${apiKey}`) return reject(response, 401, `unexpected authorization ${request.headers.authorization}`);
    const entry: Request = { body: JSON.parse(await read(request)), aborted: false };
    if (!accepted.includes(entry.body.model)) return reject(response, 400, `unexpected model ${entry.body.model}`);
    const wanted = lastUser(entry.body);
    const index = script.findIndex((reply, at) => !used.has(at) && (reply.when === undefined || wanted.includes(reply.when)));
    const step = script[index];
    if (!step) return reject(response, 500, `unexpected request ${next + 1} (${wanted.slice(0, 60)}): no unused reply of the script of ${script.length} matches`);
    used.add(index);
    next++;
    requests.push(entry);
    response.on("close", () => { if (!response.writableEnded) entry.aborted = true; });
    try {
      if (step.gate) await wait(step.gate);
      if (step.status) return void response.writeHead(step.status, { "content-type": "application/json" }).end(JSON.stringify({ error: { message: `scripted ${step.status}` } }));
      response.writeHead(200, { "content-type": "text/event-stream" });
      const send = (delta: object, finish: string | null = null, usage?: object) => response.write(`data: ${JSON.stringify({ id: "chatcmpl-1", object: "chat.completion.chunk", created: 1, model: modelId, choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`);
      send({ role: "assistant", content: "" });
      if (step.reasoning) send({ reasoning_content: step.reasoning });
      for (const piece of step.chunks ?? (step.text ? [step.text] : [])) { send({ content: piece }); if (step.delayMs) await new Promise(resolve => setTimeout(resolve, step.delayMs)); }
      for (const stage of step.stages ?? []) { await wait(stage.gate); for (const piece of stage.chunks) send({ content: piece }); }
      if (step.midGate) { await wait(step.midGate); }
      (step.tools ?? []).forEach((tool, index) => {
        const json = JSON.stringify(tool.args), count = Math.max(1, tool.pieces ?? 1), size = Math.ceil(json.length / count);
        send({ tool_calls: [{ index, id: `call_${next}_${index}`, type: "function", function: { name: tool.name, arguments: "" } }] });
        for (let at = 0; at < json.length; at += size) send({ tool_calls: [{ index, function: { arguments: json.slice(at, at + size) } }] });
      });
      const tokens = step.tokens ?? { prompt: 10, completion: 5 };
      send({}, step.tools?.length ? "tool_calls" : "stop", { prompt_tokens: tokens.prompt, completion_tokens: tokens.completion, total_tokens: tokens.prompt + tokens.completion });
      response.end("data: [DONE]\n\n");
    } catch (error) {
      violations.push(String(error));
      response.destroy();
    }
  });
  server.on("connection", socket => { sockets.add(socket); socket.once("close", () => sockets.delete(socket)); });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw Error("provider has no port");
  const baseUrl = `http://127.0.0.1:${address.port}/v1`;
  return {
    baseUrl, requests, violations,
    release(name: string) { const g = gate(name); g.open = true; for (const waiter of g.waiters.splice(0)) waiter(); },
    async close() { for (const name of gates.keys()) this.release(name); for (const socket of sockets) socket.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); },
  };
}

export async function writeAgentDir(dir: string, baseUrl: string, settings: object = {}, models: Model[] = [{ provider: providerName, id: modelId, name: "Fake model" }]) {
  await mkdir(dir, { recursive: true });
  const grouped = new Map<string, object[]>();
  for (const { provider, id, name, contextWindow } of models) {
    const model = { id, name: name ?? id, reasoning: true, input: ["text", "image"], contextWindow: contextWindow ?? 100000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
    grouped.set(provider, [...grouped.get(provider) ?? [], model]);
  }
  const providers = Object.fromEntries([...grouped].map(([name, models]) => [name, { baseUrl, api: "openai-completions", apiKey, compat: { supportsDeveloperRole: false }, models }]));
  const first = models[0];
  await writeFile(join(dir, "models.json"), JSON.stringify({ providers }));
  await writeFile(join(dir, "settings.json"), JSON.stringify({ defaultProvider: first?.provider, defaultModel: first?.id, quietStartup: true, ...settings }));
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [source = "[]", agentDir, settings = "{}", modelList = "[]", registeredBy] = process.argv.slice(2);
  const parsed: Reply[] | { replies: Reply[] } = JSON.parse(source.startsWith("@") ? await readFile(source.slice(1), "utf8") : source);
  const script = Array.isArray(parsed) ? parsed : parsed.replies;
  const models: Model[] = JSON.parse(modelList);
  const provider = await startProvider(script, 10000, models.length ? models.map(model => model.id) : [modelId]);
  if (agentDir) await writeAgentDir(agentDir, provider.baseUrl, JSON.parse(settings), registeredBy === "extension" ? [] : models.length ? models : undefined);
  process.stdout.write(JSON.stringify({ baseUrl: provider.baseUrl }) + "\n");
  createInterface({ input: process.stdin }).on("line", line => { const [command, name] = line.split(" "); if (command === "release" && name) provider.release(name); }).on("close", () => { void provider.close().then(() => process.exit(0)); });
}

export const userParts = (request: Request | undefined): Part[] => {
  const content = request?.body.messages.filter(message => message.role === "user").at(-1)?.content;
  return Array.isArray(content) ? content.filter(isPart) : [];
};
