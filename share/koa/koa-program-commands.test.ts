import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm, mkdir, cp, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { pollUntil } from "./koa-agent-fixture.ts";
import { realFixture, realPi } from "./koa-program-fixture.ts";
import { userParts } from "./koa-fake-provider.ts";
test('startup failures release the view before exiting', { timeout: 5000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'koa-startup-failure-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await symlink(process.execPath, join(dir, 'node'));
  for (const args of [[], ['--pi', realPi, '--metrics', '/does-not-exist/metrics']]) {
    const child = spawn(process.execPath, [resolve('../../build/ko/share/ko/koa/koa.ts'), '--browser', ...args], { env: { ...process.env, PATH: dir, ...(args.length ? {} : { KOA_UPLOAD_IDLE_MS: 'bad' }) }, stdio: 'pipe' });
    const close = once(child, 'close'); t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
    let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
    const [code] = await close; assert.equal(code, 1); assert.match(stderr, args.length ? /ENOENT/ : /KOA_UPLOAD_IDLE_MS/);
  }
});

test('page assets stay with the running program', { timeout: 10000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-page-install-');
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../koa'), join(dir, 'koa'), { recursive: true, filter: path => !path.includes('node_modules') });
  await symlink(resolve('../webview'), join(dir, 'webview'));
  await writeFile(join(dir, 'koa/page.html'), '<head><!-- style --></head><body>original<!-- script --></body>');
  await writeFile(join(dir, 'koa/page.css'), 'original-style');
  await writeFile(join(dir, 'koa/page.js'), 'original-script');
  const app = await realFixture(t, {replies: [], env: { KOA_PAGE_RELOAD: '0' }, program: join(dir, 'koa/koa.ts') });
  const original = await (await fetch(app.base)).text();
  assert.match(original, /original-script/);
  await writeFile(join(dir, 'koa/page.html'), '<head><!-- style --></head><body>replacement<!-- script --></body>');
  await writeFile(join(dir, 'koa/page.js'), 'replacement-script');
  assert.equal(await (await fetch(app.base)).text(), original);
});

test('a listen failure closes the acquired view and pi', { timeout: 5000 }, async t => {
  const dir = await mkdtemp('/tmp/koa-listen-failure-'); t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(resolve('../../build/ko/share/ko/koa'), join(dir, 'koa'), { recursive: true });
  await mkdir(join(dir, 'webview'));
  const marker = join(dir, 'socket');
  await writeFile(join(dir, 'webview/index.ts'), `import {webview as real} from ${JSON.stringify(new URL('../webview/index.ts', import.meta.url).href)};import {writeFileSync} from 'node:fs';export async function webview(options){const view=await real(options);writeFileSync(${JSON.stringify(marker)},view.socketPath);writeFileSync(view.socketPath,'occupied');return view;}`);
  const child = spawn(process.execPath, [join(dir, 'koa/koa.ts'), '--browser', '--pi', realPi], { env: { ...process.env }, stdio: 'pipe' });
  t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
  const [code] = await once(child, 'close'); assert.equal(code, 1); assert.match(stderr, /EADDRINUSE/);
  await assert.rejects(readFile(await readFile(marker, 'utf8')), { code: 'ENOENT' });
});

test('mutations refuse simple content types and browser path grants', { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  const before = app.provider.requests.length;
  for (const path of ['abort', 'complete', 'attachments', 'attachments/absent/delete']) {
    assert.equal((await fetch(app.base + path, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
  }
  const grants: Record<string, string>[] = [{ 'Content-Type': 'application/json' }, { 'Content-Type': 'application/json', 'Kido-Native-Drop': '1' }];
  for (const headers of grants) {
    assert.equal((await fetch(app.url('attachments'), { method: 'POST', headers, body: JSON.stringify({ path: '/etc/passwd' }) })).status, 403);
  }
  assert.equal(app.provider.requests.length, before);
});

test("attachments stream chunks into prompts", { timeout: 10000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), "koa-attachments-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const image = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==", "base64");
  const file = join(dir, "original.txt");
  await writeFile(file, "original");
  const app = await realFixture(t, { replies: [{ text: "ok" }, { text: "ok" }] });
  const created = await app.post("attachments", { name: "pixel.png", type: "text/html", size: image.length });
  assert.equal(created.status, 200);
  const uploaded = await created.json();
  const { id } = uploaded;
  const chunk = (offset: number, body: Uint8Array<ArrayBuffer>) => fetch(app.url(`attachments/${id}/${offset}`), { method: "POST", headers: { 'Content-Type': 'application/octet-stream' }, body });
  assert.equal((await chunk(1, image.subarray(0, 10))).status, 409);
  assert.deepEqual(await (await chunk(0, image.subarray(0, 10))).json(), { received: 10 });
  const done = await (await chunk(10, image.subarray(10))).json();
  assert.deepEqual(done, { received: image.length, attachment: { id, path: uploaded.path, origin: "upload", name: "pixel.png", size: image.length, kind: "image", mimeType: "image/png", width: 1, height: 1 } });
  const downloaded = await fetch(app.url(`attachments/${id}`));
  assert.equal(downloaded.headers.get("content-type"), "image/png");
  assert.match(downloaded.headers.get("content-disposition") ?? "", /pixel.png/);
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), image);
  assert.equal((await app.post("attachments", { path: file })).status, 403);
  assert.equal((await app.post("attachments", { name: "large", size: 64 * 1024 * 1024 + 1, type: "" })).status, 413);
  const copy = await (await app.post("attachments", { name: "copied.txt", type: "text/plain", size: 4 })).json();
  await fetch(app.url(`attachments/${copy.id}/0`), { method: "POST", headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(Buffer.from("copy")) });
  assert.equal((await app.post("prompt", { text: "Compare", mode: "prompt", attachments: [id, copy.id] })).status, 200);
  await pollUntil(() => app.provider.requests.length === 1, 5000, "first prompt");
  const content = (n: number) => userParts(app.provider.requests[n]);
  assert.deepEqual(content(0).filter(part => part.type === "image_url").map(part => part.image_url?.url), [`data:image/png;base64,${image.toString("base64")}`]);
  const lines = (content(0).find(part => part.type === "text")?.text ?? "").split("\n");
  assert.equal(lines[0], "Compare");
  assert.equal(await readFile(lines.at(-1) ?? "", "utf8"), "copy");
  assert.equal((await app.post("prompt", { text: "", mode: "prompt", attachments: [id] })).status, 200);
  await pollUntil(() => app.provider.requests.length === 2, 5000, "second prompt");
  assert.deepEqual(content(1).filter(part => part.type === "image_url"), content(0).filter(part => part.type === "image_url"));
  const extra = await (await app.post("attachments", { name: 'extra', type: '', size: 0 })).json();
  assert.equal((await app.post(`attachments/${extra.id}/delete`)).status, 200);
  assert.equal((await fetch(app.url(`attachments/${extra.id}`))).status, 404);
  assert.equal(await readFile(file, 'utf8'), 'original');
  const link = join(dir, 'link'); await symlink(file, link);
  assert.equal((await app.post('attachments', { path: link })).status, 403);
  const unfinished: string[] = [];
  for (let i = 0; i < 16; i++) { const response = await app.post('attachments', { name: 'empty', type: '', size: 0 }); assert.equal(response.status, 200); unfinished.push((await response.json()).id); }
  assert.equal((await app.post('attachments', { name: 'seventeenth', type: '', size: 0 })).status, 409);
  for (const id of unfinished) await app.post(`attachments/${id}/delete`);
  const boundary = await (await app.post('attachments', { name: 'boundary', type: '', size: 768 * 1024 + 1 })).json();
  assert.equal((await fetch(app.url(`attachments/${boundary.id}/0`), { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(768 * 1024 + 1) })).status, 413);
  assert.equal((await fetch(app.url(`attachments/${boundary.id}/0`), { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: new Uint8Array(0) })).status, 400);
  await app.post(`attachments/${boundary.id}/delete`);
  const reserved: string[] = [];
  for (let i = 0; i < 4; i++) { const response = await app.post('attachments', { name: 'reserved', type: '', size: 64 * 1024 * 1024 }); assert.equal(response.status, 200); reserved.push((await response.json()).id); }
  assert.equal((await app.post('attachments', { name: 'over-budget', type: '', size: 1 })).status, 409);
  for (const id of reserved) await app.post(`attachments/${id}/delete`);
  const html = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>globalThis.pwned=true</script></svg>');
  const unsafe = await (await app.post('attachments', { name: 'evil.svg', type: 'image/svg+xml', size: html.length })).json();
  assert.equal((await (await fetch(app.url(`attachments/${unsafe.id}/0`), { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: html })).json()).attachment.kind, 'file');
  const download = await fetch(app.url(`attachments/${unsafe.id}`));
  assert.equal(download.headers.get('content-type'), 'application/octet-stream');
  assert.equal(download.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(download.headers.get('content-security-policy'), "sandbox; default-src 'none'");
  await app.post('quit'); await app.close;
  await assert.rejects(readFile(lines.at(-1) ?? ""), { code: 'ENOENT' });
});

test("the attachment store is the host's: an upload without a session is taken", { timeout: 10000 }, async t => {
  const app = await realFixture(t, { replies: [] });
  const created = await fetch(app.base + "attachments", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "drop.txt", type: "text/plain", size: 4 }) });
  assert.equal(created.status, 200);
  const { id } = await created.json();
  const chunk = await fetch(app.base + `attachments/${id}/0`, { method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: new Uint8Array(Buffer.from("drop")) });
  assert.equal(chunk.status, 200);
});
