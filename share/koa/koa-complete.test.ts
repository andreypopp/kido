import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { complete, findFd } from "./koa-complete.ts";
import type { CompletionCommand } from "../pi/records.ts";

test("command completion follows pi fuzzy order, skill names and command apply", async () => {
  let calls = 0;
  const commands: CompletionCommand[] = [{ name: "release", description: "Ship", source: "prompt" }, { name: "review", source: "extension" }, { name: "skill:review", source: "skill" }, { name: "skill:ko", source: "skill" }];
  const options = { cwd: "/tmp", fd: undefined, signal: new AbortController().signal, commands: async () => { calls++; return commands; } };
  const filtered = await complete("  /re", 5, options);
  assert.deepEqual(filtered.options.map(item => item.insert), ["/release ", "/review ", "/skill:review "]);
  assert.deepEqual(filtered.options.map(item => "matched" in item ? item.matched : []), [[1, 2], [1, 2], [7, 8]]);
  assert.deepEqual((await complete("/skill:k", 8, options)).options.map(item => item.insert), ["/skill:ko "]);
  const first = (await complete("/r", 2, options)).options[0];
  assert.equal(first?.kind, "command");
  assert.equal(first?.kind === "command" ? first.source : undefined, "prompt");
  for (const text of ["text /re", "\n/re", "/review args", "./src/"]) assert.deepEqual((await complete(text, text.length, options)).options, []);
  assert.equal(calls, 3);
});

test("fd completion scopes, quotes, strips wrappers and limits pi-scored rows", async t => {
  const cwd = await mkdtemp(join(tmpdir(), "koa-complete-"));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  await mkdir(join(cwd, "a b"));
  const fd = join(cwd, "fd");
  await writeFile(fd, `#!/usr/bin/env node
const args=process.argv.slice(2),fs=require('node:fs');
if(JSON.stringify(args.slice(2,16))!==JSON.stringify(['--max-results','100','--type','f','--type','d','--follow','--hidden','--exclude','.git','--exclude','.git/*','--exclude','.git/**']))process.exit(91);
if(args[0]!=='--base-directory'||!fs.statSync(args[1]).isDirectory())process.exit(92);
let rest=args.slice(16),shallow=rest[0]==='--max-depth';if(shallow){if(rest[1]!=='1')process.exit(93);rest=rest.slice(2)}
if(rest[0]==='--full-path')rest.shift();if(rest.length&&rest.shift()!=='--')process.exit(95);if(rest.length>1)process.exit(94);let query=new RegExp(rest[0]||'');
let paths=args[1].endsWith('/a b')?['inner.txt','child/']:['a/','a.txt','a b/','a b.txt','a/nested.txt','nested/missing/a.txt','.git/config','--help.txt',...Array.from({length:25},(_,i)=>'z'+String(i).padStart(2,'0')+'.txt')];
console.log(paths.filter(p=>(!shallow||p.replace(/\\/$/,'').split('/').length===1)&&query.test(p)).join('\\n'));
`, { mode: 0o700 });
  const options = { cwd, fd, signal: new AbortController().signal, commands: async () => [] };
  const all = await complete("@", 1, options);
  assert.equal(all.options.length, 20);
  assert.deepEqual(all.options.slice(0, 4).map(item => item.label), ["a/", "a b/", "a.txt", "a b.txt"]);
  assert.equal(all.options.some(item => item.label.startsWith(".git")), false);
  assert.deepEqual((await complete('@"--help', 8, options)).options.map(item => item.insert), ['@"--help.txt" ']);
  assert.deepEqual(await complete('(@"a b', 6, options), { from: 1, to: 6, options: [
    { label: "a b/", kind: "directory", insert: '@"a b/"', cursor: 6 },
    { label: "a b.txt", kind: "file", insert: '@"a b.txt" ' },
  ] });
  const scoped = await complete('@"a b/" tail', 6, options);
  assert.deepEqual((await complete('@missing/a', 10, options)).options.map(item => item.insert), ['@nested/missing/a.txt ']);
  assert.equal(scoped.to, 7);
  assert.deepEqual(scoped.options.map(item => item.insert), ['@"a b/child/"', '@"a b/inner.txt" ']);
  assert.equal(findFd(fd, cwd, ""), fd);
  assert.equal(findFd("", cwd, ""), undefined);
  const aborted = new AbortController(); aborted.abort();
  assert.deepEqual((await complete("@", 1, { ...options, signal: aborted.signal })).options, []);
});
