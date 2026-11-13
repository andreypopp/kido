import type { parseArgs } from '@earendil-works/pi-coding-agent';

export function restartArgs(pass: readonly string[], sessionFile: string | undefined): string[] {
  const args: string[] = [];
  for (let i = 0; i < pass.length; i++) {
    const arg = pass[i];
    if (arg === '--') { args.push(...pass.slice(i)); break; }
    if (sessionFile && ['--session', '--session-id', '--fork', '--provider', '--model', '--thinking'].includes(arg ?? '')) { i++; continue; }
    if (sessionFile && ['--continue', '-c', '--no-session'].includes(arg ?? '')) continue;
    if (arg !== undefined) args.push(arg);
  }
  if (sessionFile) {
    const end = args.indexOf('--');
    args.splice(end < 0 ? args.length : end, 0, '--session', sessionFile);
  }
  return args;
}

export function startupResult(args: ReturnType<typeof parseArgs>): { error: string } | { messages: string[]; resume: boolean } {
  const refused: [string, boolean, string][] = [
    ['--mode', (args.mode ?? args.unknownFlags.get('mode') ?? 'rpc') !== 'rpc', 'requires rpc'],
    ['--print', !!args.print, 'use the page to send prompts'],
    ['--export', args.export !== undefined, 'use /export in the page'],
    ['--list-models', args.listModels !== undefined, 'use /model in the page'],
    ['--version', !!args.version, 'run pi --version'],
    ['--tui-mode', args.tuiMode !== undefined, 'not available in koa'],
    ['--theme', args.themes !== undefined, 'koa uses the page theme'],
    ['--use-theme', args.useTheme !== undefined, 'koa uses the page theme'],
    ['--no-themes', !!args.noThemes, 'koa uses the page theme'],
  ];
  const refusal = refused.find(([flag, active]) => active || flag !== '--mode' && args.unknownFlags.has(flag.slice(2)));
  const diagnostic = args.diagnostics.find(value => value.type === 'error');
  const error = refusal ? `${refusal[0]}: ${refusal[2]}` : diagnostic ? diagnostic.message : args.fileArgs.length ? '@file: use the page\'s attachments' : undefined;
  return error ? { error } : { messages: args.messages, resume: !!args.resume };
}
