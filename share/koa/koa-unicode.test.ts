import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { complete } from "./koa-complete.ts";

test("matched indices address the label when lowercase expands a character", async () => {
  const result = await complete("/x", 2, { cwd: "/tmp", fd: undefined, signal: new AbortController().signal, commands: async () => [{ name: "İx", source: "extension" }] });
  assert.deepEqual(result.options.map(item => "matched" in item ? item.matched : []), [[2]]);
});

test("fd paths keep multibyte characters across stdout chunks", async t => {
  const dir = await mkdtemp("/tmp/koa-utf8-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  const prefix = Array(120).fill("測、試測試測試測試測").join("/");
  const paths = Array.from({ length: 100 }, (_, i) => prefix + "/" + String(i).padStart(3, "0") + ".ts");
  const fd = dir + "/fd";
  await writeFile(fd, "#!/usr/bin/env node\nif(!process.argv.includes('--max-depth'))process.stdout.write(" + JSON.stringify(paths.join("\n")) + ");\n", { mode: 0o700 });
  const result = await complete("@測", 2, { cwd: dir, fd, signal: new AbortController().signal, commands: async () => [] });
  assert.deepEqual(result.options.map((item, index) => item.label === paths[index]), Array(20).fill(true));
  assert.deepEqual(result.options.map(item => item.insert.startsWith('@"') && item.insert.endsWith('" ')), Array(20).fill(true));
});
