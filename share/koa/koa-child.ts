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

export function signalChild(child: ChildProcess, signal: NodeJS.Signals): void {
  if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if (!(error instanceof Error && 'code' in error && (error.code === 'ESRCH' || error.code === 'EPERM'))) process.stderr.write(`koa: ${signal}: ${errorText(error)}\n`);
  }
}

export async function pickSession(executable: string, args: string[], extension: string, readyMs: number): Promise<{ type: 'skip' } | { type: 'cancel' } | { type: 'selected'; path: string }> {
  const label = 'session picker';
  const child = spawn(executable, ['--mode', 'rpc', '--no-session', '--no-extensions', '--extension', extension], { env: { ...process.env, KOA_RESUME_ARGS: JSON.stringify(args) }, stdio: ['inherit', 'inherit', 'inherit', 'pipe'] });
  let failure: Error | undefined;
  const exited = new Promise<void>(resolve => { child.once('exit', () => resolve()); child.once('error', error => { failure = error; resolve(); }); });
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
    if (first.done) { await exited; throw failure ?? Error(`${label} exited without a result`); }
    if (!isRecord(first.value)) throw Error('invalid session picker result');
    let result: { type: 'skip' } | { type: 'cancel' } | { type: 'selected'; path: string };
    if (first.value.type === 'skip') result = { type: 'skip' };
    else {
      if (first.value.type !== 'ready') throw Error('invalid session picker result');
      if (!process.stdin.isTTY || !process.stdout.isTTY) throw Error('resume requires a terminal');
      const answer = await next();
      if (answer.done) throw Error('session picker exited without a result');
      if (!isRecord(answer.value)) throw Error('invalid session picker result');
      if (answer.value.type === 'cancel') result = { type: 'cancel' };
      else if (answer.value.type === 'selected' && typeof answer.value.path === 'string' && answer.value.path) result = { type: 'selected', path: answer.value.path };
      else throw Error('invalid session picker result');
    }
    await Promise.race([exited, interrupted, timers.setTimeout(1000, undefined, { ref: false }).then(() => { throw Error(`${label} did not exit after selection`); })]);
    if (failure) throw failure;
    if (child.exitCode !== 0) throw Error('session picker failed');
    return result;
  } catch (error) {
    const version = await new Promise<string>(resolve => execFile(executable, ['--version'], { timeout: 2000 }, (error, stdout) => resolve(error ? 'version unavailable' : stdout.trim())));
    throw Error(`${executable} (${version}): ${errorText(error)}`);
  } finally {
    controller.abort(); child.kill('SIGTERM');
    await Promise.race([exited, timers.setTimeout(1000, undefined, { ref: false })]);
    child.kill('SIGKILL'); pipe?.destroy();
    for (const { signal, handler } of signals) process.off(signal, handler);
  }
}
