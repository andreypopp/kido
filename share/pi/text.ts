import { randomBytes } from "node:crypto";

export const mintId = (): string => randomBytes(16).toString("base64url");

export const errorText = (error: unknown): string => error instanceof Error ? error.message : String(error);

export const replaceControlCharacters = (text: string): string => text.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ");

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

export type Content = string | readonly { type: string; text?: string }[];
