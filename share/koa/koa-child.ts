import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { accessSync, constants, statSync } from 'node:fs';
import { readFile, realpath } from 'node:fs/promises';
import { delimiter, dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import timers from 'node:timers/promises';
import { errorText, isRecord } from './text.ts';

export function which(name: string, path: string): string | undefined {
  const candidates = name.includes('/') ? [name] : path.split(delimiter).map(dir => join(dir, name));
  return candidates.map(candidate => resolve(candidate)).find(candidate => { try { accessSync(candidate, constants.X_OK); return statSync(candidate).isFile(); } catch { return false; } });
}

export async function piPackage(executable: string, path: string): Promise<string | undefined> {
  const found = which(executable, path);
  if (!found) return;
  const file = await realpath(found);
  for (let dir = dirname(file); ; dir = dirname(dir)) {
    try { if (JSON.parse(await readFile(join(dir, 'package.json'), 'utf8')).name === '@earendil-works/pi-coding-agent') return dir; } catch {}
    if (dirname(dir) === dir) break;
  }
  const homebrew = resolve(dirname(file), '../libexec/lib/node_modules/@earendil-works/pi-coding-agent');
  try { if (JSON.parse(await readFile(join(homebrew, 'package.json'), 'utf8')).name === '@earendil-works/pi-coding-agent') return homebrew; } catch {}
}

async function helper<T>(executable: string, args: string[], extension: string, kind: 'startup' | 'picker', readyMs: number, consume: (first: unknown, next: () => Promise<IteratorResult<unknown>>) => Promise<T>): Promise<T> {
  const picker = kind === 'picker', label = picker ? 'session picker' : 'startup helper';
  const child = spawn(executable, ['--mode', 'rpc', '--no-session', '--no-extensions', '--extension', extension], { env: { ...process.env, [picker ? 'KOA_RESUME_ARGS' : 'KOA_STARTUP_ARGS']: JSON.stringify(args) }, stdio: picker ? ['inherit', 'inherit', 'inherit', 'pipe'] : ['ignore', 'ignore', 'pipe', 'pipe'] });
  let failure: Error | undefined, stderr = '';
  const exited = new Promise<void>(resolve => { child.once('exit', () => resolve()); child.once('error', error => { failure = error; resolve(); }); });
  child.stderr?.on('data', bytes => { stderr = (stderr + bytes).slice(-8192); });
  let interrupt: (error: Error) => void = () => {};
  const interrupted = new Promise<never>((_resolve, reject) => { interrupt = reject; });
  const signals = (['SIGTERM', 'SIGHUP', 'SIGINT'] as const).map(signal => {
    const handler = () => { child.kill(signal); interrupt(Error(`${label} interrupted by ${signal}`)); };
    process.on(signal, handler); return { signal, handler };
  });
  const controller = new AbortController(), pipe = child.stdio[3];
  try {
    if (!(pipe instanceof Readable)) throw Error(`${label} has no result pipe`);
    const lines = (async function* () {
      let buffer = '';
      for await (const bytes of pipe.setEncoding('utf8')) {
        buffer += bytes;
        if (buffer.length > 1024 * 1024) throw Error(`${label} result is too large`);
        let end: number;
        while ((end = buffer.indexOf('\n')) >= 0) { const value: unknown = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1); yield value; }
      }
    })();
    const next = () => Promise.race([lines.next(), interrupted]);
    const first = await Promise.race([next(), timers.setTimeout(readyMs, undefined, { signal: controller.signal }).then(() => { throw Error(`${label} did not become ready`); })]);
    controller.abort();
    if (first.done) { await exited; throw failure ?? Error(stderr.trim() || `${label} exited without a result`); }
    const result = await consume(first.value, next);
    await Promise.race([exited, interrupted, timers.setTimeout(1000, undefined, { ref: false }).then(() => { throw Error(`${label} did not exit after selection`); })]);
    if (failure) throw failure;
    if (picker && child.exitCode !== 0) throw Error('session picker failed');
    return result;
  } finally {
    controller.abort(); child.kill('SIGTERM');
    await Promise.race([exited, timers.setTimeout(1000, undefined, { ref: false })]);
    child.kill('SIGKILL'); pipe?.destroy();
    for (const { signal, handler } of signals) process.off(signal, handler);
  }
}

export function startup(executable: string, args: string[], extension: string): Promise<{ packageRoot: string; messages: string[]; resume: boolean } | { error: string }> {
  return helper(executable, args, extension, 'startup', 10000, async value => {
    if (isRecord(value) && typeof value.error === 'string') return { error: value.error };
    if (!isRecord(value) || typeof value.packageRoot !== 'string' || typeof value.resume !== 'boolean' || !Array.isArray(value.messages) || !value.messages.every(message => typeof message === 'string')) throw Error('invalid startup helper result');
    return { packageRoot: value.packageRoot, messages: value.messages, resume: value.resume };
  });
}

export function signalChild(child: ChildProcess, signal: NodeJS.Signals): void {
  if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if (!(error instanceof Error && 'code' in error && (error.code === 'ESRCH' || error.code === 'EPERM'))) process.stderr.write(`koa: ${signal}: ${errorText(error)}\n`);
  }
}

export async function pickSession(executable: string, args: string[], extension: string, readyMs: number): Promise<{ type: 'skip' } | { type: 'cancel' } | { type: 'selected'; path: string }> {
  try {
    return await helper(executable, args, extension, 'picker', readyMs, async (first, next) => {
      if (!isRecord(first)) throw Error('invalid session picker result');
      if (first.type === 'skip') return { type: 'skip' };
      if (first.type !== 'ready') throw Error('invalid session picker result');
      if (!process.stdin.isTTY || !process.stdout.isTTY) throw Error('resume requires a terminal');
      const result = await next();
      if (result.done) throw Error('session picker exited without a result');
      if (!isRecord(result.value)) throw Error('invalid session picker result');
      if (result.value.type === 'cancel') return { type: 'cancel' };
      if (result.value.type === 'selected' && typeof result.value.path === 'string' && result.value.path) return { type: 'selected', path: result.value.path };
      throw Error('invalid session picker result');
    });
  } catch (error) {
    const version = await new Promise<string>(resolve => execFile(executable, ['--version'], { timeout: 2000 }, (error, stdout) => resolve(error ? 'version unavailable' : stdout.trim())));
    throw Error(`${executable} (${version}): ${errorText(error)}`);
  }
}
