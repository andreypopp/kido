import { ATTACHMENT_LIMITS, type Attachment, type PromptMode } from '../pi/records.ts';

export function promptBody(value: unknown): { text: string; mode: PromptMode | "steer"; attachments: string[] } | { error: string } {
  if (value && typeof value === "object" && "text" in value && typeof value.text === "string" && "attachments" in value && Array.isArray(value.attachments) && value.attachments.length <= ATTACHMENT_LIMITS.files && value.attachments.every(id => typeof id === "string") && (value.text.trim() || value.attachments.length) && "mode" in value && (value.mode === "prompt" || value.mode === "steer" || value.mode === "follow_up")) return { text: value.text, mode: value.mode, attachments: value.attachments };
  return { error: "Text or attachments and prompt, steer or follow_up mode are required" };
}


export function promptText(text: string, attachments: readonly Attachment[]): string {
  const paths = attachments.filter(file => file.kind === 'file').map(file => file.path).join('\n');
  if (!paths) return text;
  if (text === paths) return '';
  const suffix = '\n' + paths;
  return text.endsWith(suffix) ? text.slice(0, -suffix.length) : text;
}

export function nameCommand(text: string): { type: 'query' } | { type: 'set'; name: string } | undefined {
  const match = /^\/name(?:\s+([\s\S]*))?$/.exec(text.trim());
  if (!match) return;
  const name = (match[1] ?? '').trim();
  return name ? { type: 'set', name } : { type: 'query' };
}

