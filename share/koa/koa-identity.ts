import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';

async function files(dir: URL, prefix: string, keep: (name: string) => boolean): Promise<[string, URL][]> {
  return (await readdir(dir, { withFileTypes: true })).filter(entry => entry.isFile() && keep(entry.name)).map(entry => [prefix + entry.name, new URL(entry.name, dir)]);
}

export async function installedIdentity(location: URL): Promise<string> {
  const koa = new URL('./', location), root = new URL('../', location);
  const all = [
    ...await files(koa, 'koa/', name => !name.endsWith('.test.ts') && name !== 'koa-agent.ts'),
    ...await files(new URL('webview/', root), 'webview/', name => !name.endsWith('.md')),
  ].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  const hash = createHash('sha256');
  for (const [name, url] of all) hash.update(name + '\0').update(await readFile(url)).update('\0');
  return hash.digest('hex');
}
