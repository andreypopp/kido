import { randomBytes } from "node:crypto";
import { parseThreadName, type ThreadName } from './records.ts';

export const isString = (value: unknown): value is string => typeof value === "string";

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export const str = (value: unknown): string => typeof value === "string" ? value : "";

export const mintId = (): string => randomBytes(16).toString("base64url");

export const errorText = (error: unknown): string => error instanceof Error ? error.message : String(error);

export const replaceControlCharacters = (text: string): string => text.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ");

export const cleanLine = (text: string, bytes: number): string => utf8Prefix(replaceControlCharacters(text).replace(/\s+/g, " ").trim(), bytes);

export function contentText(value: Content, separator = "\n"): string {
  return typeof value === "string" ? value : value.flatMap((block) => block.type === "text" ? [block.text ?? ""] : []).join(separator);
}

export function utf8Prefix(text: string, max: number): string {
  if (Buffer.byteLength(text, "utf8") <= max) return text;
  let out = "";
  let used = 0;
  for (const ch of text) {
    const n = Buffer.byteLength(ch, "utf8");
    if (used + n > max) break;
    out += ch;
    used += n;
  }
  return out;
}

export function utf8Suffix(text: string, max: number): string {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= max) return text;
  let start = bytes.length - max;
  while (start < bytes.length && ((bytes[start] ?? 0) & 0xc0) === 0x80) start++;
  return bytes.subarray(start).toString("utf8");
}

export function threadSections(source: string, ended: boolean): { text: string; start: number; end: number; thread?: ThreadName }[] {
  const sections: { text: string; start: number; end: number; thread?: ThreadName }[] = [];
  let fence: { char: string; length: number } | undefined;
  let thread: ThreadName | undefined;
  let start = 0, offset = 0, points = 0, startPoints = 0;
  const push = (end: number, endPoints: number) => {
    if (end > start || thread !== undefined) sections.push({ text: source.slice(start, end), start: startPoints, end: endPoints, ...(thread === undefined ? {} : { thread }) });
  };
  for (const match of source.matchAll(/[^\n]*(?:\n|$)/g)) {
    const raw = match[0];
    if (!raw) break;
    const line = raw.replace(/\r?\n$/, '');
    const length = Array.from(raw).length;
    const last = offset + raw.length === source.length && !raw.endsWith('\n');
    const marker = !fence && /^\[thread: ([^\]]*)\]$/.exec(line);
    const name = marker && (!last || ended) ? parseThreadName(marker[1]) : undefined;
    const partial = !fence && last && !ended ? /^\[thread: ([^\]]*)\]?\r?$/.exec(line)?.[1].replace(/\r$/, '') : undefined;
    if (name) {
      push(offset, points);
      thread = name;
      start = offset + raw.length; startPoints = points + length;
    } else if (!fence && last && !ended && (partial === '' || parseThreadName(partial) || '[thread: '.startsWith(line))) {
      push(offset, points);
      return sections;
    } else {
      const run = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
      if (run) {
        if (!fence && (run[1][0] !== '`' || !run[2].includes('`'))) fence = { char: run[1][0], length: run[1].length };
        else if (fence && run[1][0] === fence.char && run[1].length >= fence.length && !run[2].trim()) fence = undefined;
      }
    }
    offset += raw.length; points += length;
  }
  push(offset, points);
  return sections;
}

export type Content = string | readonly ({ type: "text" | "thinking" | "toolCall"; text?: string } | { type: "image"; data: string; mimeType: string })[];
