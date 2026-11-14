import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { AgentSession } from '@earendil-works/pi-coding-agent';
import type { CompletionCommand, CommandAction, CommandResult } from './koa-records.ts';

const SUPPORTED = ['model', 'thinking', 'compact', 'session', 'copy', 'export', 'name', 'resume', 'new', 'quit', 'reload', 'restart'] as const;
type Action = typeof SUPPORTED[number] | 'refuse';
type Builtin = CompletionCommand & { action: Action };
type Model = ReturnType<AgentSession['modelRuntime']['getAvailableSnapshot']>[number];
export async function commandCatalog(root: string) {
  const { BUILTIN_SLASH_COMMANDS }: { BUILTIN_SLASH_COMMANDS: { name: string; description: string }[] } = await import(pathToFileURL(join(root, 'dist/core/slash-commands.js')).href);
  const entries = [...BUILTIN_SLASH_COMMANDS, ...['debug', 'arminsayshi', 'dementedelves'].map(name => ({ name, description: 'Not available in koa' }))];
  const catalog: Builtin[] = [...SUPPORTED.flatMap(name => name === 'restart' ? [{ name, description: 'Restart koa on this session' }] : entries.filter(value => value.name === name)), ...entries.filter(value => !SUPPORTED.some(name => name === value.name))].map(value => ({ ...value, description: value.name === 'export' ? 'Export session as HTML' : value.name === 'reload' ? 'Reload extensions, settings and koa' : value.description, source: 'builtin', action: SUPPORTED.find(name => name === value.name) ?? 'refuse' }));
  return { catalog, completion: catalog.filter(value => value.action !== 'refuse') };
}

export type Deferral = { type: 'jobs'; count: number } | { type: 'children'; count: number } | { type: 'no_session' };
const plural = (count: number, noun: string) => `${count} ${noun}${count === 1 ? '' : 's'}`;
export function deferralText(deferral: Deferral): string {
  const subject = 'reloaded · a newer koa';
  switch (deferral.type) {
    case 'jobs': return `${subject} waits for ${plural(deferral.count, 'job')}`;
    case 'children': return `${subject} waits for ${plural(deferral.count, 'subagent')} to report`;
    case 'no_session': return `${subject} needs a saved session`;
  }
}

export function parseCommand(text: string, catalog: readonly Builtin[]): { command: Builtin; args: string } | undefined {
  const match = /^\/(\S+)(?:\s+([\s\S]*))?$/.exec(text.trim());
  const command = match && catalog.find(value => value.name === match[1]);
  return command ? { command, args: match?.[2]?.trim() ?? '' } : undefined;
}

export async function dispatchCommand(input: NonNullable<ReturnType<typeof parseCommand>>, host: {
  packageRoot: string;
  session: AgentSession;
  notify(text: string, level: 'info' | 'warning' | 'error'): void;
  stats(): void;
  outcome(result: CommandResult): void;
  compact(instructions?: string): void;
  thinking(level: string): Promise<void>;
  setModel(model: Model): Promise<void>;
  reloadBusy(): boolean;
}): Promise<CommandAction | { type: 'restart' }> {
  const { command, args } = input;
  const { session } = host;
  switch (command.action) {
    case 'refuse': host.notify(`/${command.name} is not available in koa`, 'warning'); break;
    case 'model': {
      if (args) {
        const { findExactModelReferenceMatch }: { findExactModelReferenceMatch(reference: string, models: readonly Model[]): Model | undefined } = await import(pathToFileURL(join(host.packageRoot, 'dist/core/model-resolver.js')).href);
        const model = findExactModelReferenceMatch(args, session.modelRuntime.getAvailableSnapshot());
        if (model) { await host.setModel(model); break; }
      }
      return { type: 'picker', kind: 'model', search: args };
    }
    case 'thinking':
      if (!args) return { type: 'picker', kind: 'thinking', search: '' };
      await host.thinking(args); break;
    case 'compact': host.compact(args || undefined); break;
    case 'session': host.stats(); break;
    case 'copy': {
      const text = session.getLastAssistantText();
      if (text) {
        process.stdout.write(`\x1b]52;c;${Buffer.from(text).toString('base64')}\x1b\\`);
        host.outcome({ type: 'copy', characters: text.length });
      } else host.notify('No assistant response to copy.', 'warning');
      break;
    }
    case 'export': {
      if (/\.jsonl$/i.test(args)) { host.notify('/export supports HTML only in koa.', 'warning'); break; }
      host.outcome({ type: 'export', path: await session.exportToHtml(args || undefined) });
      break;
    }
    case 'name': {
      if (args) { session.setSessionName(args); host.notify('Session name set: ' + session.sessionName, 'info'); }
      else host.notify(session.sessionName ? 'Session name: ' + session.sessionName : 'Usage: /name <name>', session.sessionName ? 'info' : 'warning');
      break;
    }
    case 'resume': case 'new': return { type: 'session', kind: command.action };
    case 'quit': return { type: 'quit' };
    case 'reload':
      if (!host.reloadBusy()) return { type: 'reload' };
      host.notify('reload: not while a turn, a command, a queue, a dialog or an editor is open', 'warning');
      break;
    case 'restart':
      return { type: 'restart' };
  }
  return { type: 'none' };
}
