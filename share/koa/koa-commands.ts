import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { RpcCommand, RpcResponse } from '@earendil-works/pi-coding-agent';
import type { CompletionCommand, CommandAction, CommandResult, SessionStats } from './koa-records.ts';

const SUPPORTED = ['model', 'thinking', 'compact', 'session', 'copy', 'export', 'name', 'resume', 'new', 'quit', 'reload'] as const;
type Action = typeof SUPPORTED[number] | 'refuse';
type Builtin = CompletionCommand & { action: Action };
type Model = Extract<RpcResponse, { command: 'get_available_models'; success: true }>['data']['models'][number];
export async function commandCatalog(root: string) {
  const { BUILTIN_SLASH_COMMANDS }: { BUILTIN_SLASH_COMMANDS: { name: string; description: string }[] } = await import(pathToFileURL(join(root, 'dist/core/slash-commands.js')).href);
  const entries = [...BUILTIN_SLASH_COMMANDS, ...['debug', 'arminsayshi', 'dementedelves'].map(name => ({ name, description: 'Not available in koa' }))];
  const catalog: Builtin[] = [...SUPPORTED.flatMap(name => entries.filter(value => value.name === name)), ...entries.filter(value => !SUPPORTED.some(name => name === value.name))].map(value => ({ ...value, description: value.name === 'export' ? 'Export session as HTML' : value.name === 'reload' ? 'Reload extensions, settings and koa' : value.description, source: 'builtin', action: SUPPORTED.find(name => name === value.name) ?? 'refuse' }));
  return { catalog, completion: catalog.filter(value => value.action !== 'refuse') };
}

export type Deferral = { type: 'jobs'; count: number } | { type: 'children'; count: number } | { type: 'no_session' } | { type: 'no_answer' };
const plural = (count: number, noun: string) => `${count} ${noun}${count === 1 ? '' : 's'}`;
export function deferralText(deferral: Deferral): string {
  switch (deferral.type) {
    case 'jobs': return `reloaded · a newer koa waits for ${plural(deferral.count, 'job')}`;
    case 'children': return `reloaded · a newer koa waits for ${plural(deferral.count, 'subagent')} to report`;
    case 'no_session': return 'reloaded · a newer koa needs a saved session';
    case 'no_answer': return 'reloaded · a newer koa waits; the extension did not answer, try /reload again';
  }
}

export function parseCommand(text: string, catalog: readonly Builtin[]): { command: Builtin; args: string } | undefined {
  const match = /^\/(\S+)(?:\s+([\s\S]*))?$/.exec(text.trim());
  const command = match && catalog.find(value => value.name === match[1]);
  return command ? { command, args: match?.[2]?.trim() ?? '' } : undefined;
}

export async function dispatchCommand(input: NonNullable<ReturnType<typeof parseCommand>>, host: {
  packageRoot: string;
  command(value: RpcCommand): Promise<RpcResponse>;
  notify(text: string, level: 'info' | 'warning' | 'error'): void;
  stats(value: SessionStats): void;
  outcome(result: CommandResult): void;
  compact(instructions?: string): void;
  thinking(level: string): Promise<void>;
  reloadBusy(): boolean;
  name: string;
}): Promise<CommandAction> {
  const { command, args } = input;
  const run = async (value: RpcCommand) => { const result = await host.command(value); if (!result.success) throw Error(result.error); return result; };
  switch (command.action) {
    case 'refuse': host.notify(`/${command.name} is not available in koa`, 'warning'); break;
    case 'model': {
      if (args) {
        const result = await run({ type: 'get_available_models' });
        if (result.command === 'get_available_models') {
          const { findExactModelReferenceMatch }: { findExactModelReferenceMatch(reference: string, models: readonly Model[]): Model | undefined } = await import(pathToFileURL(join(host.packageRoot, 'dist/core/model-resolver.js')).href);
          const model = findExactModelReferenceMatch(args, result.data.models);
          if (model) { await run({ type: 'set_model', provider: model.provider, modelId: model.id }); break; }
        }
      }
      return { type: 'picker', kind: 'model', search: args };
    }
    case 'thinking':
      if (!args) return { type: 'picker', kind: 'thinking', search: '' };
      await host.thinking(args); break;
    case 'compact': host.compact(args || undefined); break;
    case 'session': { const result = await run({ type: 'get_session_stats' }); if (result.command === 'get_session_stats') host.stats(result.data); break; }
    case 'copy': {
      const result = await run({ type: 'get_last_assistant_text' });
      if (result.command === 'get_last_assistant_text' && result.data.text) {
        process.stdout.write(`\x1b]52;c;${Buffer.from(result.data.text).toString('base64')}\x1b\\`);
        host.outcome({ type: 'copy', characters: result.data.text.length });
      } else host.notify('No assistant response to copy.', 'warning');
      break;
    }
    case 'export': {
      if (/\.jsonl$/i.test(args)) { host.notify('/export supports HTML only in koa.', 'warning'); break; }
      const result = await run({ type: 'export_html', ...(args ? { outputPath: args } : {}) });
      if (result.command === 'export_html') host.outcome({ type: 'export', path: result.data.path });
      break;
    }
    case 'name': {
      if (args) { await run({ type: 'set_session_name', name: args }); host.notify('Session name set: ' + host.name, 'info'); }
      else { const result = await run({ type: 'get_state' }); if (result.command === 'get_state') host.notify(result.data.sessionName ? 'Session name: ' + result.data.sessionName : 'Usage: /name <name>', result.data.sessionName ? 'info' : 'warning'); }
      break;
    }
    case 'resume': case 'new': return { type: 'session', kind: command.action };
    case 'quit': return { type: 'quit' };
    case 'reload':
      if (!host.reloadBusy()) return { type: 'reload' };
      host.notify('reload: not while a turn, a command, a queue, a dialog or an editor is open', 'warning');
      break;
  }
  return { type: 'none' };
}
