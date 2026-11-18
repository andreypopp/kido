import { parseArgs, type ParseArgsConfig } from 'node:util';
import type { Args } from '@earendil-works/pi-coding-agent';

const options = {
  continue: { type: 'boolean', short: 'c' }, resume: { type: 'boolean', short: 'r' },
  session: { type: 'string' }, 'session-id': { type: 'string' }, fork: { type: 'string' },
  'no-session': { type: 'boolean' }, 'session-dir': { type: 'string' },
  name: { type: 'string', short: 'n' }, model: { type: 'string' }, provider: { type: 'string' },
  thinking: { type: 'string' }, models: { type: 'string' },
  tools: { type: 'string', short: 't' }, 'exclude-tools': { type: 'string' },
  'no-tools': { type: 'boolean' }, 'no-builtin-tools': { type: 'boolean' },
  extension: { type: 'string', short: 'e', multiple: true }, 'no-extensions': { type: 'boolean' },
  skill: { type: 'string', multiple: true }, 'no-skills': { type: 'boolean' },
  'prompt-template': { type: 'string', multiple: true }, 'no-prompt-templates': { type: 'boolean' },
  'no-context-files': { type: 'boolean' }, 'no-mcp': { type: 'boolean' },
  'system-prompt': { type: 'string' }, 'append-system-prompt': { type: 'string', multiple: true },
  approve: { type: 'boolean', short: 'a' }, 'no-approve': { type: 'boolean' }, offline: { type: 'boolean' },
  help: { type: 'boolean', short: 'h' }, browser: { type: 'boolean' }, pi: { type: 'string' },
  metrics: { type: 'string' }, 'metrics-mode': { type: 'string' }, runtime: { type: 'string' },
} as const satisfies NonNullable<ParseArgsConfig['options']>;

export function parseKoaArgs(args: string[]) {
  const parsed = parseArgs({ args, options, strict: true, allowPositionals: true });
  if (parsed.values.approve && parsed.values['no-approve']) throw new Error('--approve and --no-approve conflict');
  return parsed;
}

export function restartArgs(parsed: ReturnType<typeof parseKoaArgs>, sessionFile: string | undefined, includeOwn = false): string[] {
  const args: string[] = [];
  for (const [name, value] of Object.entries(parsed.values)) {
    if (!includeOwn && ['help', 'browser', 'pi', 'metrics', 'metrics-mode'].includes(name)) continue;
    if (sessionFile && ['session', 'session-id', 'fork', 'continue', 'no-session', 'provider', 'model', 'thinking'].includes(name)) continue;
    for (const item of Array.isArray(value) ? value : [value]) {
      if (item === true) args.push(`--${name}`);
      else if (typeof item === 'string') args.push(...(includeOwn || name === 'runtime' ? [`--${name}=${item}`] : [`--${name}`, item]));
    }
  }
  if (sessionFile) args.push(...(includeOwn ? [`--session=${sessionFile}`] : ['--session', sessionFile]));
  if (parsed.positionals.length) args.push('--', ...parsed.positionals);
  return args;
}

export function startupResult(args: Args): { error: string } | { messages: string[]; resume: boolean } {
  const diagnostic = args.diagnostics.find(value => value.type === 'error');
  const error = diagnostic ? diagnostic.message : args.fileArgs.length ? '@file: use the page\'s attachments' : undefined;
  return error ? { error } : { messages: args.messages, resume: !!args.resume };
}
