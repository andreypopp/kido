import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { shellComplete } from './koa-shell.ts';

test('shell completion quotes words, preserves mid-line spans, and rejects substitutions', async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'koa-complete-'));
  try {
    await writeFile(path.join(cwd, 'hello world'), '');
    await mkdir(path.join(cwd, 'hello directory'));
    const context = { type: 'host' as const, cwd };
    const command = await shellComplete('prin', 4, context, 'ko', new AbortController().signal);
    assert.ok(command.options.some(item => item.label === 'printf'));
    const result = await shellComplete('cat hel tail', 7, context, 'ko', new AbortController().signal);
    assert.equal(result.from, 4); assert.equal(result.to, 7);
    assert.ok(result.options.some(item => item.insert === "\'hello world\' "));
    assert.ok(result.options.some(item => item.insert === "\'hello directory/\'"));
    assert.equal((await shellComplete('cat $(touch owned)', 17, context, 'ko', new AbortController().signal)).options.length, 0);
    assert.equal((await shellComplete('cat `touch owned`', 16, context, 'ko', new AbortController().signal)).options.length, 0);
    await assert.rejects(readFile(path.join(cwd, 'owned')), { code: 'ENOENT' });
    await writeFile(path.join(cwd, 'line\nbreak'), '');
    const newline = await shellComplete('cat li', 6, context, 'ko', new AbortController().signal);
    assert.deepEqual(newline.options, [{ label: 'line\nbreak', insert: "'line\nbreak' " }]);
    await mkdir(path.join(cwd, 'é-dir'));
    await writeFile(path.join(cwd, 'é-dir/inner'), '');
    const directory = await shellComplete('cat é', 5, context, 'ko', new AbortController().signal);
    assert.equal(directory.options[0]?.insert, "'é-dir/'");
    const secondLine = 'cat ' + directory.options[0]?.insert + 'in';
    const second = await shellComplete(secondLine, secondLine.length, context, 'ko', new AbortController().signal);
    assert.equal(second.options[0]?.insert, "'é-dir/inner' ");
    await writeFile(path.join(cwd, "it's"), '');
    const apostrophe = await shellComplete('cat it', 6, context, 'ko', new AbortController().signal);
    assert.equal(apostrophe.options[0]?.insert, "'it'\\''s' ");
    const middle = await shellComplete('cat hello tail', 7, context, 'ko', new AbortController().signal);
    assert.equal(middle.to, 9);
  } finally { await rm(cwd, { recursive: true, force: true }); }
});

test('registered Bash functions control quoting, nospace, empty answers, separators and Unicode', async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'koa-complete-'));
  try {
    const data = path.join(cwd, 'data'); await mkdir(path.join(data, 'bash-completion'), { recursive: true });
    await writeFile(path.join(cwd, 'hello world'), '');
    await mkdir(path.join(cwd, 'hello directory'));
    await writeFile(path.join(data, 'bash-completion/bash_completion'), `_koa_test() { compopt -o nospace; COMPREPLY=(\"hello world\"); }; complete -F _koa_test widget\n_koa_empty() { COMPREPLY=(); }; complete -F _koa_empty empty\n_koa_dir() { compopt -o filenames; COMPREPLY=(\"hello directory\"); }; complete -F _koa_dir directory\n_koa_unicode() { [[ $COMP_POINT == 15 && $COMP_CWORD == 2 && $COMP_LINE == 'unicode 😀 he' ]] && COMPREPLY=(hello); }; complete -F _koa_unicode unicode\n`);
    const code = `import { shellComplete } from ${JSON.stringify(new URL('./koa-shell.ts', import.meta.url).href)};const context={type:'host',cwd:${JSON.stringify(cwd)}};const signal=new AbortController().signal;const results=[];for(const line of ['widget he','widget \"he','cat x; widget he','empty hel','unicode 😀 he','directory he','cat ~/hel'])results.push(await shellComplete(line,line.length,context,'ko',signal));process.stdout.write(JSON.stringify(results));`;
    const { stdout } = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', code], { env: { ...process.env, XDG_DATA_HOME: data, HOME: cwd }, timeout: 5000 });
    const results = JSON.parse(stdout);
    assert.equal(results[0].options[0]?.insert, "\'hello world\'");
    assert.equal(results[1].from, 7); assert.equal(results[1].options[0]?.insert, "\'hello world\'");
    assert.equal(results[2].from, 14); assert.equal(results[2].options[0]?.insert, "\'hello world\'");
    assert.deepEqual(results[3].options, []);
    assert.equal(results[4].from, 11); assert.equal(results[4].options[0]?.insert, 'hello ');
    assert.equal(results[5].options[0]?.insert, "\'hello directory/\'");
    assert.ok(results[6].options.some((item: { insert: string }) => item.insert === "~/\'hello directory/\'"));
  } finally { await rm(cwd, { recursive: true, force: true }); }
});

test('function completion metadata, retry, command prefixes and UTF-8 common prefixes', async t => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'koa-complete-'));
  try {
    const data = path.join(cwd, 'data'); await mkdir(path.join(data, 'bash-completion'), { recursive: true });
    await writeFile(path.join(cwd, 'hello-file'), ''); await mkdir(path.join(cwd, 'hello-dir'));
    await writeFile(path.join(data, 'bash-completion/bash_completion'), `
_git_fixture() { COMPREPLY=('checkout ' 'cherry-pick ' 'cherry '); }; complete -o nospace -F _git_fixture gitfixture
_utf() { COMPREPLY=(éclair êclair); }; complete -F _utf utf
_empty() { COMPREPLY=(); }; complete -o default -F _empty defaults; complete -o bashdefault -F _empty bashdefaults; complete -o dirnames -F _empty dirs
_dynamic() { compopt -o default; COMPREPLY=(); }; complete -F _dynamic dynamic
_plus() { COMPREPLY=(hello-target); }; complete -o plusdirs -F _plus plus
_after() { COMPREPLY=(loaded); }; _lazy() { complete -F _after lazy; return 124; }; complete -F _lazy lazy
_meta() { [[ $1 == widget && $COMP_CWORD == 1 && \${COMP_WORDS[0]} == widget && ( $2 == wo || $2 == work ) ]] && COMPREPLY=(worked); }; complete -F _meta widget
_filename() { compopt -o filenames -o nospace; COMPREPLY=('file '); }; complete -F _filename filename
complete -o plusdirs -F _empty plus-empty
_loop() { COMPREPLY=(wrong); return 124; }; complete -F _loop retry-loop
_unset() { compopt +o default; COMPREPLY=(); }; complete -o default -F _unset unsetdefault
_utfvalid() { COMPREPLY=(préé préê); }; complete -F _utfvalid utfvalid
`);
    const lines = ['gitfixture ch', 'utf ', 'defaults hel', 'bashdefaults hel', 'dirs hel', 'dynamic hel', 'plus hel', 'lazy lo', 'FOO=x widget wo', '>out widget wo', '2>out widget wo', 'widget >out wo', 'widget wo\\\nrk', 'filename fi', 'plus-empty hel', 'retry-loop wo', 'unsetdefault hel', 'utfvalid pr'];
    const code = `import { shellComplete } from ${JSON.stringify(new URL('./koa-shell.ts', import.meta.url).href)};const results=[];for(const line of ${JSON.stringify(lines)})results.push(await shellComplete(line,line.length,{type:'host',cwd:${JSON.stringify(cwd)}},'ko',new AbortController().signal));process.stdout.write(JSON.stringify(results));`;
    const { stdout } = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', code], { env: { ...process.env, XDG_DATA_HOME: data, HOME: cwd }, timeout: 5000 });
    const results = JSON.parse(stdout);
    await t.test('Git-style acceptance suffix', () => { assert.equal(results[0].options[0]?.insert, 'checkout '); assert.equal(results[0].common, 'che'); });
    await t.test('UTF-8 boundary', () => assert.equal(results[1].common, ''));
    for (const i of [2, 3, 5]) await t.test(lines[i] ?? String(i), () => assert.ok(results[i].options.some((item: { label: string }) => item.label === 'hello-file')));
    await t.test('dirnames', () => assert.deepEqual(results[4].options.map((item: { label: string }) => item.label), ['hello-dir/']));
    await t.test('plusdirs', () => assert.deepEqual(results[6].options.map((item: { label: string }) => item.label), ['hello-target', 'hello-dir/']));
    await t.test('retry 124', () => assert.equal(results[7].options[0]?.insert, 'loaded '));
    for (let i = 8; i <= 12; i++) await t.test(JSON.stringify(lines[i]), () => assert.equal(results[i].options[0]?.insert, 'worked '));
    await t.test('filename trailing space is data', () => assert.equal(results[13].options[0]?.insert, "\'file \'"));
    await t.test('empty plusdirs', () => assert.deepEqual(results[14].options.map((item: { label: string }) => item.label), ['hello-dir/']));
    await t.test('bounded retry', () => assert.deepEqual(results[15].options, []));
    await t.test('compopt removes default', () => assert.deepEqual(results[16].options, []));
    await t.test('UTF-8 valid prefix is retained', () => assert.equal(results[17].common, "'pré'"));
  } finally { await rm(cwd, { recursive: true, force: true }); }
});

test('runtime completion sends the mapped cwd without host environment and never falls back locally', async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'koa-complete-'));
  try {
    const ko = path.join(cwd, 'ko');
    await writeFile(ko, `#!${process.execPath}\nlet input='';process.stdin.on('data',chunk=>input+=chunk);process.stdin.on('end',()=>{const value=JSON.parse(input.trim());if(process.argv.slice(2).join(' ')!=='api --stream /runtimes/dev/exec'||value.cwd!=='/mapped'||'env' in value||value.argv[0]!=='sh'||value.argv[1]!=='-c'||!value.argv[2].includes('command -v bash')||!value.argv[4].startsWith('cd -- \"$4\"')||value.argv.at(-1)!=='/mapped')process.exit(91);process.stdout.write(JSON.stringify({type:'stdout',data:Buffer.from('4\\0'+'6\\0'+'remote\\0'+'1\\0'+'remote\\0'+'remote \\0').toString('base64')})+'\\n'+JSON.stringify({type:'exit',status:0})+'\\n')});`, { mode: 0o700 });
    const result = await shellComplete('cat re', 6, { type: 'runtime', name: 'dev', cwd: '/mapped' }, ko, new AbortController().signal);
    assert.equal(result.options[0]?.insert, 'remote ');
    assert.deepEqual((await shellComplete('echo h', 6, { type: 'runtime', name: 'missing', cwd }, ko, new AbortController().signal)).options, []);
    assert.deepEqual((await shellComplete('echo h', 6, { type: 'unavailable' }, ko, new AbortController().signal)).options, []);
  } finally { await rm(cwd, { recursive: true, force: true }); }
});

test('malformed shell records are refused and cancellation during helper read starts no exec', async t => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'koa-complete-'));
  try {
    const ko = path.join(cwd, 'ko'), marker = path.join(cwd, 'started');
    const records = { outofbounds: ['0', '999', 'a', '1', 'a', 'a', ''], partial: ['0', '7', 'a', '2', 'a', 'a', ''], unsafe: ['0', '6', 'a', '9007199254740992', 'a', 'a', ''], extra: ['0', '5', 'a', '0', 'a', 'a', ''], negative: ['-1', '8', 'a', '1', 'a', 'a', ''], decimal: ['0.0', '7', 'a', '1', 'a', 'a', ''], unterminated: ['0', '12', 'a', '1', 'a', 'a'], '😀': ['1', '4', 'a', '1', 'a', 'a', ''] };
    await writeFile(ko, `#!${process.execPath}\nimport fs from 'node:fs';fs.writeFileSync(${JSON.stringify(marker)},'started');let input='';process.stdin.on('data',c=>input+=c);process.stdin.on('end',()=>{const line=JSON.parse(input.trim()).argv.at(-3),records=${JSON.stringify(records)},data=Buffer.from((records[line]??[]).join('\\0'));process.stdout.write(JSON.stringify({type:'stdout',data:data.toString('base64')})+'\\n'+JSON.stringify({type:'exit',status:0})+'\\n')});`, { mode: 0o700 });
    const context = { type: 'runtime' as const, name: 'dev', cwd };
    for (const line of Object.keys(records)) await t.test(line, async () => assert.deepEqual((await shellComplete(line, line.length, context, ko, new AbortController().signal)).options, []));
    await rm(marker, { force: true });
    const controller = new AbortController();
    const pending = shellComplete('cancel', 6, context, ko, controller.signal); controller.abort();
    assert.deepEqual((await pending).options, []);
    await assert.rejects(readFile(marker), { code: 'ENOENT' });
  } finally { await rm(cwd, { recursive: true, force: true }); }
});

test('shell completion caps output but computes common prefix over all matches', async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), 'koa-complete-'));
  try {
    await Promise.all(Array.from({ length: 205 }, (_, i) => writeFile(path.join(cwd, `prefix${i}`), '')));
    await writeFile(path.join(cwd, 'prezz'), '');
    const result = await shellComplete('cat pre', 7, { type: 'host', cwd }, 'ko', new AbortController().signal);
    assert.equal(result.options.length, 200); assert.equal(result.more, 6); assert.equal(result.common, 'pre');
  } finally { await rm(cwd, { recursive: true, force: true }); }
});
