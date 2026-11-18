import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pathToken } from './path-token.ts';

test('inline path tokens accept paths and positive safe line and column numbers', () => {
  for (const path of ['koa.ts', 'koa/koa.ts', '/etc/hosts', '~/x.md', './x', '../x']) assert.deepEqual(pathToken(path), { path });
  assert.deepEqual(pathToken('koa.ts:120'), { path: 'koa.ts', line: 120 });
  assert.deepEqual(pathToken('koa.ts:120:3'), { path: 'koa.ts', line: 120, col: 3 });
  for (const text of ['git add koa.ts', 'foo', '.', 'a.', '.gitignore', 'https://x/y', 'a/b:0', 'a/b:-1', 'a/b:2:0', 'a/b:9007199254740992', 'a/b:1:9007199254740992', 'a:b/c', 'a/b\n', 'a/\u0000b', 'a/\u200bb', 'a.ts:1:2:3']) assert.equal(pathToken(text), undefined, text);
});
