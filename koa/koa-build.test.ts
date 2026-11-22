import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

test('the shipped sources include every reachable root module', () => {
  const root = fileURLToPath(new URL('.', import.meta.url));
  const shipped = new Set(execFileSync('make', ['-s', '-f', 'Makefile', '-f', '-', 'print-sources'], { cwd: root, encoding: 'utf8', input: 'print-sources:;@echo $(KOA_SRC)\n' }).trim().split(/\s+/));
  const visited = new Set<string>();
  const visit = (path: string) => {
    if (visited.has(path)) return;
    visited.add(path);
    const name = relative(root, path);
    if (!name.includes('/')) assert.ok(shipped.has(name), 'Missing shipped module: ' + name);
    const source = readFileSync(path, 'utf8');
    for (const match of source.matchAll(/(?:from\s*|import\s*\(?)['"](\.[^'"]+\.ts)['"]/g)) {
      const next = resolve(dirname(path), match[1]);
      if (next.startsWith(root)) visit(next);
    }
  };
  for (const entry of ['koa.ts', 'koa-agent.ts', 'page/page.ts']) visit(resolve(root, entry));
});
