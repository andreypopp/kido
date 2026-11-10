import { bashCommand, shellPathToken, shellQuote } from './prompt.ts';
import { spawn } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { basename, delimiter, join, resolve } from "node:path";
import { homedir } from "node:os";
import { parsePanes, piAgent, runningRows, agentCache } from "../pi/agents.ts";
import type { components } from "../pi/ko-api.d.ts";
import type { CompletionCommand, CompletionOption, CompletionResult } from "./koa-records.ts";
import { signalChild } from "./koa-child.ts";
import { fileToken, slashToken, pathSeparator } from "../pi/token.ts";

function scorePositions(textLower: string, positions: number[]) {
  let score = 0;
  let lastMatchIndex = -1;
  let consecutiveMatches = 0;
  for (const i of positions) {
    if (lastMatchIndex === i - 1) {
      consecutiveMatches++;
      score -= consecutiveMatches * 5;
    }
    else {
      consecutiveMatches = 0;
      if (lastMatchIndex >= 0) {
        score += (i - lastMatchIndex - 1) * 2;
      }
    }
    if (i === 0 || /[\s\-_./:]/.test(textLower[i - 1])) {
      score -= 10;
    }
    score += i * 0.1;
    lastMatchIndex = i;
  }
  return score;
}
function matchQuery(normalizedQuery: string, textLower: string): { matches: boolean; score: number; positions: number[] } {
  if (!normalizedQuery.length) return { matches: true, score: 0, positions: [] };
  if (normalizedQuery.length > textLower.length) return { matches: false, score: 0, positions: [] };
  const positions: number[] = [];
  let lastMatchIndex = -1;
  for (const character of normalizedQuery.split("")) {
    const index = textLower.indexOf(character, lastMatchIndex + 1);
    if (index < 0) return { matches: false, score: 0, positions: [] };
    positions.push(index); lastMatchIndex = index;
  }
  let score = scorePositions(textLower, positions), best = positions.slice();
  for (let start = textLower.indexOf(normalizedQuery); start !== -1; start = textLower.indexOf(normalizedQuery, start + 1)) {
    for (let index = 0; index < normalizedQuery.length; index++) positions[index] = start + index;
    const candidate = scorePositions(textLower, positions);
    if (candidate < score) { score = candidate; best = positions.slice(); }
  }
  if (normalizedQuery === textLower) score -= 100;
  return { matches: true, score, positions: best };
}
function fuzzyMatch(query: string, text: string) {
  const queryLower = query.toLowerCase();
  const textLower = text.toLowerCase();
  const labelPositions = (match: ReturnType<typeof matchQuery>) => {
    if (textLower.length === text.length) return match;
    const offsets: number[] = [];
    let offset = 0;
    for (const character of text) {
      for (let i = 0; i < character.toLowerCase().length; i++) offsets.push(offset + Math.min(i, character.length - 1));
      offset += character.length;
    }
    return { ...match, positions: [...new Set(match.positions.map(index => offsets[index]))] };
  };
  const primaryMatch = matchQuery(queryLower, textLower);
  if (primaryMatch.matches) {
    return labelPositions(primaryMatch);
  }
  const alphaNumericMatch = queryLower.match(/^(?<letters>[a-z]+)(?<digits>[0-9]+)$/);
  const numericAlphaMatch = queryLower.match(/^(?<digits>[0-9]+)(?<letters>[a-z]+)$/);
  const swappedQuery = alphaNumericMatch
    ? `${alphaNumericMatch.groups?.digits ?? ""}${alphaNumericMatch.groups?.letters ?? ""}`
    : numericAlphaMatch
      ? `${numericAlphaMatch.groups?.letters ?? ""}${numericAlphaMatch.groups?.digits ?? ""}`
      : "";
  if (!swappedQuery) {
    return primaryMatch;
  }
  const swappedMatch = matchQuery(swappedQuery, textLower);
  if (!swappedMatch.matches) {
    return primaryMatch;
  }
  return labelPositions({ matches: true, score: swappedMatch.score + 5, positions: swappedMatch.positions });
}
function fuzzyFilter<T>(items: readonly T[], query: string, getText: (item: T) => string) {
  const tokens = query.trim().split(/[\s/]+/).filter(Boolean), results: { item: T; score: number; matched: number[] }[] = [];
  for (const item of items) {
    const matches = tokens.map(token => fuzzyMatch(token, getText(item)));
    if (matches.every(match => match.matches)) results.push({ item, score: matches.reduce((sum, match) => sum + match.score, 0), matched: [...new Set(matches.flatMap(match => match.positions))].sort((a, b) => a - b) });
  }
  return results.sort((a, b) => a.score - b.score);
}

export function findFd(override: string | undefined, agentDir: string, path: string): string | undefined {
  const candidates = override !== undefined ? [override] : [join(agentDir, "bin/fd"), ...path.split(delimiter).filter(Boolean).map(dir => join(dir, "fd"))];
  return candidates.filter(Boolean).map(candidate => resolve(candidate)).find(candidate => { try { accessSync(candidate, constants.X_OK); return statSync(candidate).isFile(); } catch { return false; } });
}

function output(command: string, args: string[], signal: AbortSignal): Promise<string | undefined> {
  if (signal.aborted) return Promise.resolve(undefined);
  return new Promise(resolve => {
    const child = spawn(command, args, { detached: true, stdio: ["ignore", "pipe", "ignore"] });
    let size = 0, state: "reading" | "aborted" | "ended" = "reading";
    const chunks: Buffer[] = [];
    const finish = (result: string | undefined) => {
      if (state === "ended") return;
      state = "ended"; signal.removeEventListener("abort", abort);
      child.stdout.removeListener("data", data); child.stdout.destroy(); resolve(result);
    };
    const abort = () => { if (state !== "reading") return; state = "aborted"; signalChild(child, "SIGKILL"); };
    const data = (bytes: Buffer) => {
      if (bytes.length > (1 << 20) - size) { abort(); return; }
      size += bytes.length; chunks.push(bytes);
    };
    signal.addEventListener("abort", abort, { once: true });
    child.stdout.on("error", () => finish(undefined));
    child.stdout.on("data", data);
    child.once("error", () => finish(undefined));
    child.once("close", code => finish(code === 0 && state === "reading" && !signal.aborted ? Buffer.concat(chunks).toString("utf8") : undefined));
  });
}

export function agentDiscovery(pane: string, ttl: string | undefined, signal: AbortSignal) {
  return agentCache(async () => {
    const body = pane ? await output("ko", ["api", "/layout"], AbortSignal.any([signal, AbortSignal.timeout(5000)])) : undefined;
    if (body === undefined) return { rows: [], all: [] };
    const layout: components["schemas"]["LayoutPanes"] = JSON.parse(body);
    const panes = parsePanes(layout), me = panes.find(p => p.pane === pane);
    const rows = runningRows(panes, me).filter(({ pane: p }) => me && p.session === me.session && piAgent(p.kind)).map(({ row }) => row);
    return { rows, all: rows };
  }, ttl);
}

let fdProcesses = 0;
async function walk(fd: string, base: string, query: string, signal: AbortSignal, depth?: number): Promise<{ path: string; directory: boolean }[]> {
  const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = query.includes("/") ? query.replace(/^\/+|\/+$/g, "").split("/").filter(Boolean).map(escape).join("[\\\\/]") + (query.endsWith("/") ? "[\\\\/]" : "") : escape(query);
  const args = ["--base-directory", base, "--max-results", "100", "--type", "f", "--type", "d", "--follow", "--hidden", "--exclude", ".git", "--exclude", ".git/*", "--exclude", ".git/**", ...(depth === undefined ? [] : ["--max-depth", String(depth)]), ...(query.includes("/") ? ["--full-path"] : []), ...(query ? ["--", pattern] : [])];
  if (fdProcesses >= 4) return [];
  fdProcesses++;
  let text: string | undefined;
  try { text = await output(fd, args, AbortSignal.any([signal, AbortSignal.timeout(2000)])); }
  finally { fdProcesses--; }
  return text === undefined ? [] : text.trim().split("\n").filter(Boolean).map(path => ({ path: path.replace(/\\/g, "/"), directory: /[\\/]$/.test(path) })).filter(entry => !/(^|\/)\.git(\/|$)/.test(entry.path));
}

async function files(query: string, cwd: string, fd: string | undefined, signal: AbortSignal): Promise<{ display: string; directory: boolean }[]> {
  if (!fd || signal.aborted) return [];
  const normalized = query.replace(/\\/g, "/"), slash = normalized.lastIndexOf("/");
  let base = "", wanted = normalized, directory = cwd;
  if (slash >= 0) {
    const prefix = normalized.slice(0, slash + 1), scoped = prefix.startsWith("~/") ? join(homedir(), prefix.slice(2)) : resolve(cwd, prefix);
    try { if (statSync(scoped).isDirectory()) { base = prefix; wanted = normalized.slice(slash + 1); directory = scoped; } } catch {}
  }
  const [shallow, deep] = await Promise.all([walk(fd, directory, wanted, signal, 1), walk(fd, directory, wanted, signal)]);
  const seen = new Set<string>();
  return [...shallow, ...deep].filter(entry => { if (seen.has(entry.path)) return false; seen.add(entry.path); return true; }).map(entry => {
    const path = entry.directory ? entry.path.slice(0, -1) : entry.path;
    const name = basename(path).toLowerCase(), lower = wanted.toLowerCase();
    let score = wanted ? name === lower ? 100 : name.startsWith(lower) ? 80 : name.includes(lower) ? 50 : path.toLowerCase().includes(lower) ? 30 : 0 : 1;
    if (entry.directory && score > 0 && wanted) score += 10;
    return { ...entry, score };
  }).filter(entry => entry.score > 0).sort((a, b) => b.score - a.score || a.path.split("/").filter(Boolean).length - b.path.split("/").filter(Boolean).length || a.path.length - b.path.length || a.path.localeCompare(b.path)).slice(0, 20).map(entry => {
    return { display: base + entry.path, directory: entry.directory };
  });
}

export async function complete(text: string, pos: number, options: { cwd: string; commands(): Promise<readonly CompletionCommand[]>; fd: string | undefined; signal: AbortSignal; agents?: ReturnType<typeof agentDiscovery> }): Promise<CompletionResult> {
  const result: CompletionResult = { from: pos, to: pos, options: [] };
  if (options.signal.aborted) return result;
  if (bashCommand(text)) {
    const path = shellPathToken(text, pos);
    if (!path) return result;
    return { from: path.from, to: path.to, options: (await files(path.query, options.cwd, options.fd, options.signal)).map(entry => ({ label: entry.display, insert: shellQuote(entry.display) + (entry.directory ? '' : ' '), kind: entry.directory ? 'directory' : 'file' })) };
  }
  const lineStart = text.lastIndexOf("\n", pos - 1) + 1, before = text.slice(lineStart, pos);
  const mention = fileToken(before), command = slashToken(text, pos);
  if (mention !== undefined) {
    result.from = pos - mention.text.length;
    const { quoted, agent: token } = mention;
    if (quoted && text[pos] === '"') result.to++;
    const agents = token === undefined ? [] : options.agents?.(token) ?? [];
    result.options = [...agents.map(item => ({ kind: "agent" as const, label: item.label, detail: item.description, insert: item.value + " ", matched: fuzzyMatch(token ?? "", item.label.slice(1)).positions.map(index => index + 1) })), ...(await files(mention.text.slice(quoted ? 2 : 1), options.cwd, options.fd, options.signal)).map((entry): CompletionOption => {
      const needsQuotes = quoted || pathSeparator.test(entry.display), insert = '@' + (needsQuotes ? '"' + entry.display + '"' : entry.display) + (entry.directory ? '' : ' ');
      return { label: entry.display, insert, kind: entry.directory ? 'directory' : 'file', ...(entry.directory && needsQuotes ? { cursor: insert.length - 1 } : {}) };
    })];
  } else if (command !== undefined) {
    result.from = pos - command.length;
    const commands = await options.commands(), query = command.slice(1);
    const bare = fuzzyFilter(commands, query, item => item.name.startsWith("skill:") ? item.name.slice(6) : item.name);
    const bareItems = new Set(bare.map(match => match.item));
    const full = fuzzyFilter(commands.filter(item => item.name.startsWith("skill:") && !bareItems.has(item)), query, item => item.name);
    result.options = [...bare, ...full].map(({ item, matched }) => ({ label: "/" + item.name, detail: item.description, insert: "/" + item.name + " ", kind: "command", source: item.source, matched: matched.map(index => index + (item.name.startsWith("skill:") && bareItems.has(item) ? 7 : 1)) }));
  }
  return options.signal.aborted ? { ...result, options: [] } : result;
}
