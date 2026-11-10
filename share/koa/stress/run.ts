import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import http from 'node:http';
import { scripts, workloads, pageWorkloads } from './workloads.ts';

const configured = process.env.KOA_STRESS_OUTPUT;
if (!configured) throw Error('KOA_STRESS_OUTPUT is required; use stress/run.sh');
const output = resolve(configured);
const selected = process.argv.slice(2).map(Number);
const ids = selected.length ? selected : pageWorkloads;
assert.ok(ids.every(id => pageWorkloads.includes(id)), 'Unknown page workload');
await writeFile(join(output, 'page-manifest.json'), JSON.stringify({ target: 'page', ids }), { flag: 'wx' });
await scripts(join(output, 'scripts'));
const root = resolve(new URL('../../..', import.meta.url).pathname);
type Reply = { id?: number; method?: string; params?: { chunk?: string }; error?: unknown; result?: { result?: { value?: unknown }; exceptionDetails?: unknown; usedSize?: number } };
for (const id of ids) {
  let directory: string | undefined;
  let socket: WebSocket | undefined;
  let stalled: http.IncomingMessage | undefined;
  const resources: { child: ChildProcess; closed: Promise<void> }[] = [];
  const timersToClear = new Set<NodeJS.Timeout>();
  let stopping = false;
  let fail: (error: Error) => void = () => {};
  const failed = new Promise<never>((_, reject) => { fail = reject; });
  void failed.catch(() => {});
  const startChild = (command: string, args: string[], env = process.env) => {
    const child = spawn(command, args, { env, stdio: ['pipe', 'ignore', 'pipe'] });
    const closed = new Promise<void>(resolve => child.once('close', code => { resolve(); if (!stopping) fail(Error(command + ' exited: ' + code)); }));
    child.once('error', fail);
    resources.push({ child, closed });
    return child;
  };
  const address = (child: ChildProcess, pattern: RegExp, label: string) => Promise.race([failed, new Promise<string>((resolve, reject) => {
    let text = '';
    const timer = setTimeout(() => finish(Error(label + ' startup deadline')), 20000); timersToClear.add(timer);
    const ended = () => finish(Error(label + ' exited: ' + text));
    const data = (bytes: Buffer) => { text += bytes; const match = text.match(pattern); if (match?.[0]) finish(undefined, match[0]); };
    const finish = (error?: Error, value = '') => { clearTimeout(timer); timersToClear.delete(timer); child.stderr?.off('data', data); child.off('close', ended); if (error) reject(error); else resolve(value); };
    child.stderr?.on('data', data); child.once('close', ended);
  })]);
  try {
    directory = await mkdtemp(join(tmpdir(), 'koa-stress-'));
    for (const opener of ['open', 'xdg-open']) await writeFile(join(directory, opener), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const file = join(output, `page-${id}.jsonl`);
    const koa = startChild(process.execPath, [join(root, 'build/ko/share/ko/koa/koa.ts'), '--browser', '--pi', join(root, 'share/koa/koa-fake-pi.ts'), '--metrics', file, '--metrics-mode', 'frame'], { ...process.env, KO_SOCKET: '', KO_PANE: '', KO_PANE_TOKEN: '', PATH: `${directory}:${process.env.PATH}`, KOA_FAKE_SCRIPT: join(output, `scripts/${id}.jsonl`) });
    const url = await address(koa, /http:\/\/127\.0\.0\.1:\d+\//, 'koa');
    koa.stderr?.resume();
    const chrome = startChild(process.env.KOA_CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--remote-debugging-port=0', `--user-data-dir=${directory}/chrome`, 'about:blank']);
    const debuggerURL = await address(chrome, /ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[\w-]+/, 'Chrome');
    chrome.stderr?.resume();
    const port = new URL(debuggerURL).port;
    const target: { webSocketDebuggerUrl: string } = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT', signal: AbortSignal.timeout(5000) })).json();
    socket = new WebSocket(target.webSocketDebuggerUrl);
    const ws = socket;
    await Promise.race([failed, new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => finish(Error('CDP connect deadline')), 10000); timersToClear.add(timer);
      const opened = () => finish();
      const errored = () => finish(Error('CDP connect failed'));
      const finish = (error?: Error) => { clearTimeout(timer); timersToClear.delete(timer); ws.removeEventListener('open', opened); ws.removeEventListener('error', errored); ws.removeEventListener('close', errored); if (error) reject(error); else resolve(); };
      ws.addEventListener('open', opened); ws.addEventListener('error', errored); ws.addEventListener('close', errored);
    })]);
    let serial = 0;
    const events = new EventEmitter();
    const pending = new Map<number, (reply: Reply) => void>();
    ws.addEventListener('message', event => { const reply: Reply = JSON.parse(String(event.data)); if (reply.id !== undefined) pending.get(reply.id)?.(reply); if (reply.method) events.emit(reply.method, reply.params); });
    ws.addEventListener('close', () => fail(Error('CDP disconnected')));
    const call = (method: string, params: object = {}) => Promise.race([failed, new Promise<NonNullable<Reply['result']>>((resolve, reject) => {
      const id = ++serial;
      const timer = setTimeout(() => { timersToClear.delete(timer); pending.delete(id); reject(Error(method + ' deadline')); }, 120000); timersToClear.add(timer);
      pending.set(id, reply => { clearTimeout(timer); timersToClear.delete(timer); pending.delete(id); if (reply.error) reject(Error(JSON.stringify(reply.error))); else resolve(reply.result ?? {}); });
      ws.send(JSON.stringify({ id, method, params }));
    })]);
    const evaluate = async (expression: string) => {
      const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
      return result.result?.value;
    };
    const until = (condition: string, ms = 60000) => evaluate(`new Promise((resolve,reject)=>{const observer=new MutationObserver(check);const timer=setTimeout(()=>{clean();reject(Error('Condition deadline: '+${JSON.stringify(condition)}))},${ms});function clean(){observer.disconnect();clearTimeout(timer)}function check(){if(${condition}){clean();resolve(true)}}observer.observe(document,{attributes:true,childList:true,characterData:true,subtree:true});check()})`);
    await call('Page.enable'); await call('Runtime.enable');
    const load = async (reload = false) => {
      const loaded = once(events, 'Page.loadEventFired', { signal: AbortSignal.timeout(20000) });
      await call(reload ? 'Page.reload' : 'Page.navigate', reload ? {} : { url });
      await Promise.race([loaded, failed]);
      await until('!!document.querySelector("#prompt")', 10000);
      await until('document.querySelector("#status").textContent === "idle" || document.querySelector("#status").textContent.startsWith("working")', 10000);
    };
    await load();
    const snapshot = async (phase: string) => {
      if (!process.env.KOA_STRESS_HEAP) return;
      const chunks: string[] = [];
      const chunk = (params: { chunk: string }) => chunks.push(params.chunk);
      events.on('HeapProfiler.addHeapSnapshotChunk', chunk);
      try {
        await call('HeapProfiler.takeHeapSnapshot');
        await writeFile(join(output, `page-${id}-${phase}.heapsnapshot`), chunks.join(''));
      } finally { events.off('HeapProfiler.addHeapSnapshotChunk', chunk); }
    };
    await snapshot('before');
    const started = performance.now();
    const observations: Record<string, unknown> = {};
    const prompt = (size: number) => evaluate(`fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:'p'.repeat(${size}),mode:'prompt',attachments:[]})}).then(r=>r.status)`);
    if (id === 10) {
      stalled = await new Promise<http.IncomingMessage>((resolve, reject) => {
        const request = http.get(new URL('events', url), { agent: false }, response => { request.setTimeout(0); response.pause(); resolve(response); });
        request.setTimeout(10000, () => request.destroy(Error('Stalled subscriber deadline')));
        request.once('error', reject);
      });
    }
    assert.equal(await prompt(id === 4 ? 900 * 1024 : 2), 200, 'Prompt was not accepted');
    if (id === 4) {
      assert.equal(await prompt(1.5 * 1024 * 1024), 413);
      await evaluate(`(()=>{window.composer.setText('p'.repeat(1.5*1024*1024));document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));return true})()`);
      await until('!!document.querySelector("#error").textContent', 5000);
      observations.composer = await evaluate(`({error:document.querySelector('#error').textContent,retained:window.composer.text().length})`);
    }
    if (id === 1) {
      const pages = await evaluate(`(async()=>{let before=2000,count=0;while(before>0&&count<100){const r=await(await fetch('/items?before='+before)).json();if(!r.items.length)throw Error('Empty history');before=r.items[0].seq;count++}if(before!==0)throw Error('History incomplete');return count})()`);
      assert.equal(pages, 50); observations.paging = pages;
    }
    if (id === 5) {
      for (let n = 0; n < 200; n++) await load(true);
      await evaluate(`(async()=>{
        const open=(url,accept)=>new Promise((resolve,reject)=>{
          const source=new EventSource(url);
          const finish=(error,record)=>{clearTimeout(timer);source.close();error?reject(error):resolve(record)};
          const timer=setTimeout(()=>finish(Error('EventSource deadline')),10000);
          source.onerror=()=>finish(Error('EventSource failed'));
          source.onmessage=event=>{try{const record=JSON.parse(event.data);if(accept(record))finish(null,record)}catch(error){finish(error)}};
        });
        const reset=await open('/events',record=>record.type==='reset');
        for(let n=0;n<200;n++)await open('/events?epoch='+encodeURIComponent(reset.epoch)+'&after=-1',()=>true);
        return true;
      })()`);
    }
    if (id === 8) observations.themeFrame = await evaluate(`(async()=>{const times=[];for(let n=0;n<50;n++){const t=performance.now();document.documentElement.style.setProperty('--ko-bg',n%2?'#fff':'#111');dispatchEvent(new Event('ko-theme'));await new Promise(requestAnimationFrame);times.push(performance.now()-t)}return times})()`);
    if (id === 9) assert.deepEqual(await evaluate(`Promise.all(Array.from({length:8},()=>fetch('/items?before=0').then(r=>r.status)))`), Array(8).fill(200));
    if (id === 11) assert.deepEqual(await evaluate(`Promise.all([new Blob([JSON.stringify({text:'body-kind probe',mode:'prompt',attachments:[]})]),new FormData()].map(body=>fetch('/prompt',{method:'POST',body}).then(r=>r.status)))`), [415, 415]);
    await until(`document.querySelector('#status').textContent==='idle'&&document.querySelector('#items').textContent.includes('STRESS DONE ${id}')`, 120000);
    if ([2, 5, 8, 9].includes(id)) {
      await evaluate(`(()=>{if(document.querySelector('#items').textContent.length<400000&&!document.querySelector('#older').hidden)document.querySelector('#older').click();return true})()`);
      await until(`document.querySelectorAll('#items .msg.assistant p').length===20000&&Array.from(document.querySelectorAll('#items .msg.assistant p')).every(p=>p.textContent==='abcdefghijklmnopqr')`);
    }
    if (id === 1) assert.equal(await evaluate(`document.querySelector('#items').textContent.includes('Paragraph 1998')`), true);
    if (id === 3) assert.equal(await evaluate(`document.querySelector('#items').textContent.includes('bash')`), true);
    if (id === 10) {
      assert.equal(await evaluate('window.koaMetrics.after'), 1024, 'Incomplete cursor recovery');
      assert.ok(stalled);
      const ended = once(stalled, 'end', { signal: AbortSignal.timeout(10000) });
      stalled.resume();
      await ended;
    }
    await evaluate('window.koaMetrics.flush().then(()=>true)');
    const seconds = (performance.now() - started) / 1000;
    await snapshot('after');
    await call('HeapProfiler.collectGarbage');
    const heap = await call('Runtime.getHeapUsage');
    const records: { samples: { frame: number }[]; caps: number; opens: number; subscribers: number }[] = (await readFile(file, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
    assert.ok(records.flatMap(record => record.samples).length > 0, 'No frame samples');
    const last = records.at(-1); assert.ok(last); assert.equal(last.subscribers, 1);
    if (id === 10) { assert.ok(last.caps > 0, 'Stalled reader did not reach the output cap'); assert.ok(last.opens > 1, 'No independent stalled subscriber'); }
    const summary = { target: 'page', id, name: workloads[id - 1]?.name, timing: 'frame', status: 'ok', seconds, metrics: [file], heap: heap.usedSize, observations };
    await writeFile(join(output, `page-${id}-summary.json`), JSON.stringify(summary));
    console.log(JSON.stringify(summary));
  } catch (error) {
    await writeFile(join(output, `page-${id}-summary.json`), JSON.stringify({ target: 'page', timing: 'frame', id, status: 'failed', error: String(error) }));
    throw error;
  } finally {
    stopping = true;
    for (const timer of timersToClear) clearTimeout(timer);
    socket?.close();
    stalled?.destroy();
    for (const { child } of resources) if (child.pid && child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    const stop = setTimeout(() => { for (const { child } of resources) if (child.pid && child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); }, 12000);
    await Promise.all(resources.map(resource => resource.closed)); clearTimeout(stop);
    if (directory) await rm(directory, { recursive: true, force: true });
  }
}
