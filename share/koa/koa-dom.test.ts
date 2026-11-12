import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { stripTypeScriptTypes } from "node:module";
import { markdown, markdownLine, sliceEnd } from "./page/markdown.ts";
import { bashCommand } from "./prompt.ts";
import { promptHistory } from './page/history.ts';
import { ATTACHMENT_LIMITS, isAttachment, pathArg } from "./koa-records.ts";
import { jobEndText } from "./records.ts";
import type { PromptMode } from "./koa-records.ts";

async function page() {
  const source = stripTypeScriptTypes(await readFile(new URL("page/page.ts", import.meta.url), "utf8"));
  class Node {
    value = ""; private text = ""; style: Record<string, unknown> = { setProperty() {} }; innerHTML = ''; clientWidth = 320; clientHeight = 100; disabled = false; placeholder = ""; scrollHeight = 20; children: Node[] = []; dataset = {};
    get textContent() { return this.text; }
    set textContent(value: unknown) { this.text = String(value); this.children = []; }
    private classes = new Set<string>();
    get className() { return [...this.classes].join(' '); }
    set className(value: string) { this.classes = new Set(value.split(/\s+/).filter(Boolean)); }
    classList = { toggle: (name: string, force = !this.classes.has(name)) => { if (force) this.classes.add(name); else this.classes.delete(name); }, remove: (name: string) => { this.classes.delete(name); }, add: (name: string) => { this.classes.add(name); }, contains: (name: string) => this.classes.has(name) };
    parent?: Node;
    inert = false;
    contains(node: Node | undefined): boolean { return !!node && (node === this || this.contains(node.parent)); }
    append(...children: Node[]) { children.forEach(child => { if (child instanceof Node) child.parent = this; }); this.children.push(...children); }
    prepend(...children: Node[]) { children.forEach(child => { if (child instanceof Node) child.parent = this; }); this.children.unshift(...children); }
    before(...children: Node[]) { this.append(...children); }
    remove() { if (this.contains(document.activeElement)) document.activeElement = undefined; if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = undefined; }
    replaceChildren(...children: Node[]) { this.children.forEach(child => { if (child instanceof Node) child.parent = undefined; }); this.children = []; this.append(...children); }
    content: { childNodes: Node[]; querySelectorAll(): Node[] } = { childNodes: [], querySelectorAll: () => [] };
    tagName = 'DIV'; isContentEditable = false; readOnly = false; selectionStart = 0; selectionEnd = 0; hidden = true;
    oninput?: () => void;
    onclick?: () => void;
    onkeydown?: (event: unknown) => void;
    attributes = new Map<string, string>();
    setAttribute(name: string, value: string) { this.attributes.set(name, value); } getAttribute(name: string) { return this.attributes.get(name) ?? null; } removeAttribute(name: string) { this.attributes.delete(name); } focus() { for (let node: Node | undefined = this; node; node = node.parent) if (node.inert) return; document.activeElement = this; } setSelectionRange() {} addEventListener() {} scrollIntoView() {} getBoundingClientRect() { return { left: 0 }; }
    closest(selector: string): Node | null { if (selector === 'a') return this.tagName === 'A' ? this : this.parent?.closest(selector) ?? null; return ['INPUT', 'TEXTAREA', 'SELECT', ...(selector.includes('button') ? ['BUTTON'] : [])].includes(this.tagName) || (this.attributes.has('role') && selector.includes(`[role=${this.attributes.get('role')}]`)) ? this : null; }
    setRangeText(text: string) { this.value = this.value.slice(0, this.selectionStart) + text + this.value.slice(this.selectionEnd); }
    dispatchEvent() { this.oninput?.(); }
    querySelector() { return undefined; }
    querySelectorAll(): Node[] { return []; }
    get isConnected(): boolean { return this === document.body || this === document.documentElement || this.parent?.isConnected === true; }
    get childNodes() { return this.children; }
    insertBefore(child: Node, next: Node | null) { if (child === next) return; child.remove(); const index = next ? this.children.indexOf(next) : this.children.length; this.children.splice(index < 0 ? this.children.length : index, 0, child); child.parent = this; }
    get firstElementChild() { return this.children[0]; }
    get lastElementChild() { return this.children.at(-1); }
    get lastChild() { return this.children.at(-1); }
  }
  const elements = new Map<string, Node>();
  const listeners = new Map<string, (event: unknown) => void>();
  const windowListeners = new Map<string, (event?: unknown) => void>();
  let activeElement: Node | undefined;
  const document = { hidden: false, documentElement: new Node(), body: new Node(), hasFocus: () => true, get activeElement() { return activeElement; }, set activeElement(node: Node | undefined) { if (activeElement === node) return; const previous = activeElement; activeElement = node; if (previous) listeners.get('focusout')?.({ target: previous }); if (node) listeners.get('focusin')?.({ target: node }); }, querySelector: (selector?: string): Node | null => selector === '.cm-content' ? document.getElementById('prompt').children[0] ?? null : selector === '.lightbox' ? document.body.children.find(node => node.classList.contains('lightbox')) ?? null : null, getElementById(id: string) { let node = elements.get(id); if (!node) { node = new Node(); elements.set(id, node); if (id === 'prompt') document.getElementById('field').append(node); if (id === 'composer') node.hidden = false; } return node; }, createElement: (tag: string) => { const node = new Node(); node.tagName = tag.toUpperCase(); return node; }, createElementNS: () => new Node(), createTextNode: (text: string) => { const node = new Node(); node.tagName = '#text'; node.textContent = text; return node; }, addEventListener(type: string, handler: (event: unknown) => void) { listeners.set(type, handler); }, querySelectorAll: () => [] };
  type Handlers = { input(user: boolean): void; send(mode: PromptMode): void; quit(): void; edit(): void };
  let handlers: Handlers | undefined;
  let text = () => '';
  let prompt: Node | undefined;
  let completionResets = 0;
  const composer = (host: Node, callbacks: Handlers) => {
    handlers = callbacks;
    const content = host.children[0] ?? new Node(); content.isContentEditable = true; if (!host.children.length) host.append(content);
    prompt = content;
    text = () => content.value;
    let running = false;
    const refresh = () => host.parent?.classList.toggle('bash-mode', !!bashCommand(content.value) || running && !content.value.length);
    return {
      text,
      empty: () => content.value.length === 0,
      completionStatus: () => 'idle',
      resetCompletion() { completionResets++; },
      bash: () => bashCommand(content.value),
      running(value: boolean) { running = value; refresh(); },
      setText(text: string) { content.value = text; content.selectionStart = content.selectionEnd = text.length; refresh(); callbacks.input(false); },
      insert(text: string) { content.setRangeText(text); refresh(); callbacks.input(true); },
      readonly(value: boolean) { content.readOnly = value; },
      focus: () => content.focus(),
      hasFocus: () => document.activeElement === content,
      placeholder(text: string) { content.placeholder = text; },
    };
  };
  const context = { Date: class extends Date { constructor(value: string | number = 1700000012000) { super(value); } static now() { return 1700000012000; } }, getComputedStyle: () => ({ display: 'block' }), composer, bashCommand, ATTACHMENT_LIMITS, isAttachment, pathArg, jobEndText, AbortController, AbortSignal, CustomEvent: class { type: string; detail?: unknown; constructor(type: string, options?: { detail?: unknown }) { this.type = type; this.detail = options?.detail; } }, Node, Element: Node, HTMLElement: Node, HTMLButtonElement: Node, HTMLImageElement: Node, markdown, markdownLine, sliceEnd, document, window: { ko: {}, addEventListener(type: string, handler: (event?: unknown) => void) { windowListeners.set(type, handler); } }, innerWidth: 980, innerHeight: 560, Event: class { type: string; constructor(type: string) { this.type = type; } }, console, setInterval() {}, clearInterval() {}, setTimeout, clearTimeout, requestAnimationFrame() {}, cancelAnimationFrame() {}, performance: { now: () => 0 }, fetch: async () => ({ ok: true, json: async () => ({}) }) };
  const answersSource = stripTypeScriptTypes(await readFile(new URL('page/answers.ts', import.meta.url), 'utf8')).replace(/^export /gm, '');
  const annotationsSource = stripTypeScriptTypes(await readFile(new URL('page/annotations.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(answersSource + '\n' + annotationsSource + '\n({annotations,update})', context));
  Object.assign(document, { createTreeWalker: () => ({ nextNode: () => false }) });
  Object.assign(context, { NodeFilter: { SHOW_TEXT: 4 } });
  const attachSource = stripTypeScriptTypes(await readFile(new URL('page/attach.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const httpSource = stripTypeScriptTypes(await readFile(new URL('page/http.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const previewSource = stripTypeScriptTypes(await readFile(new URL('page/preview.ts', import.meta.url), 'utf8')).replace(/^export /gm, '');
  Object.assign(context, runInNewContext(previewSource + '\n({preview,previewKey})', context));
  Object.assign(context, { fetchJSON: runInNewContext(httpSource + '\nfetchJSON', context), attach: runInNewContext(attachSource + '\nattach', context) });
  const body = source.replace(/^import .*;\n/gm, "").replace(/^setInterval\([\s\S]*$/m, "");
  return { repl: (): ((code: string) => unknown) => runInNewContext("(() => {\n" + body + "\nreturn code => eval(code);\n})()", context), context, elements, listeners, windowListeners, completionResets: () => completionResets, handlers: () => handlers, prompt: () => prompt, text: () => text(), run: (code: string) => runInNewContext("{\n" + body + "\n" + code + "\n}", context) };
}

test('Tab outside the composer returns focus without changing dialog keys', async () => {
  const app = await page();
  app.run("state={...state,pi:{type:'ready'}};document.body.focus()");
  for (const shiftKey of [false, true]) {
    let prevented = false;
    app.listeners.get('keydown')?.({ key: 'Tab', shiftKey, target: app.context.document.body, preventDefault() { prevented = true; } });
    assert.equal(prevented, true, 'page Tab must prevent focus navigation');
    assert.equal(app.context.document.activeElement, app.prompt());
  }
  app.run("state={...state,dialogs:[{id:'q',method:'input',title:'Question'}]};dialogs();element('dialogs').children[0].children[1].focus()");
  const input = app.context.document.activeElement;
  let prevented = false;
  app.listeners.get('keydown')?.({ key: 'Tab', target: input, preventDefault() { prevented = true; } });
  assert.equal(prevented, false);
  assert.equal(app.context.document.activeElement, input);
});

test('prose Tab consumes the key without an open completion', async () => {
  const source = stripTypeScriptTypes(await readFile(new URL('page/complete.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const noop = () => ({});
  const result = runInNewContext(source + '\ncompletion(host,()=>{},null,()=>{}).keys', {
    host: { parentElement: {} }, document: { createElement: () => ({}) },
    ViewPlugin: { define: noop }, EditorView: { updateListener: { of: noop } },
    tooltips: noop, autocompletion: noop, moveCompletionSelection: noop,
    completionStatus: () => null, acceptCompletion: () => { throw Error('No completion is open'); },
  });
  for (const key of ['Tab', 'Shift-Tab']) {
    const binding = result.find((binding: { key: string }) => binding.key === key);
    assert.equal(binding?.run({ state: { field: () => null } }), true, `${key} must consume the key`);
  }
});

test('a transcript epoch reset closes completion from the prior session', async () => {
  const fixture = await page();
  fixture.run("apply({type:'reset',epoch:1,items:[],more:false})");
  assert.equal(fixture.completionResets(), 1);
});

test('user messages separate quote answers without changing assistant Markdown', async () => {
  const fixture = await page(), rendered: string[] = [];
  fixture.context.markdown = (user = false) => {
    const render = markdown(user);
    return (...args: Parameters<typeof render>) => {
      const blocks = render(...args);
      rendered.push(blocks.map(block => block.html).join(''));
      return blocks;
    };
  };
  fixture.run(`
    put({kind:'user',seq:0,at:1,text:'> q\\nanswer',images:[],attachments:[]});
    put({kind:'assistant',seq:1,at:2,final:true,stop:'stop',error:'',blocks:[{type:'text',text:'> q\\nanswer'}]});
  `);
  assert.deepEqual(rendered, ['<blockquote>\n<p>q</p>\n</blockquote>\n<p>answer</p>\n', '<blockquote>\n<p>q\nanswer</p>\n</blockquote>\n']);
});

test('bang composer mode and live command render without blocking agent controls', async () => {
  const fixture = await page();
  let clock = 4000;
  Object.assign(fixture.context, { Date: class extends Date { constructor(value: string | number = clock) { super(value); } static now() { return clock; } } });
  const tick = fixture.run(`
    state={...state,pi:{type:'ready'}};
    editor.setText('!!echo hi');
    if (!element('field').classList.contains('bash-mode')) throw Error('missing bang font');
    if (element('status').textContent !== 'run, quiet') throw Error('missing quiet mode');
    state.bash=[{id:'run',phase:'running',command:'echo hi',excludeFromContext:true,started:1000,output:{text:'live',cut:0}}];
    editor.setText(''); refreshBash(); refreshComposer();
    const card=pendingBash.get('run'),pre=card.view.lastElementChild.firstElementChild,time=card.view.firstElementChild.lastElementChild.lastElementChild;
    if (time.textContent!=='3s') throw Error('missing running duration');
    if (!card.view.classList.contains('open')) throw Error('live output folded');
    state.bash[0].output={text:'more',cut:0}; refreshBash();
    if (pendingBash.get('run')!==card||card.view.lastElementChild.firstElementChild!==pre||pre.textContent!=='more') throw Error('live nodes replaced');
    apply({type:'reset',epoch:'rebuilt',items:[],more:false});
    if (!element('items').contains(card.view)) throw Error('rebuild removed running command');
    editor.setText('!next');
    if (canSend('!next')) throw Error('second command accepted');
    if (element('status').textContent !== 'running') throw Error('missing running state');
    (()=>{card.update(state.bash[0]);return time.textContent});
  `);
  clock = 5000;
  assert.equal(tick(), '4s');
});

test('bang attachments stay in the draft and new file drops are refused', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const app = await page();
  const leave = app.run(`
    state={...state,pi:{type:'ready'}};
    draft.restore([{id:'keep',name:'notes.md',path:'/tmp/notes.md',origin:'path',kind:'file',mimeType:'text/markdown',size:1}]);
    editor.setText('!echo hi');
    if (canSend(editor.text()) || draft.count!==1) throw Error('attachment was sent or removed');
    if (!element('status').classList.contains('err') || element('status').title!=='remove the attachments') throw Error('missing attachment refusal');
    (()=>editor.setText('normal'));
  `);
  let prevented = false;
  app.listeners.get('drop')?.({ defaultPrevented: false, dataTransfer: { files: [{}], items: [] }, preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.equal(app.elements.get('error')?.textContent, 'a command takes no attachments');
  t.mock.timers.tick(4000);
  assert.equal(app.elements.get('error')?.textContent, '');
  app.listeners.get('drop')?.({ defaultPrevented: false, dataTransfer: { files: [{}], items: [] }, preventDefault() {} });
  leave();
  assert.equal(app.elements.get('error')?.textContent, '');
});

test('Escape cancels a command before taking back and aborting a concurrent turn', async () => {
  const app = await page(), requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({ steering: [], followUp: [] }) }; };
  const cancelling = app.run(`state={...state,pi:{type:'ready'},working:true,bash:[{id:'run',phase:'running',command:'echo',excludeFromContext:false,started:1,output:{text:'',cut:0}}]};(()=>{state.bash[0].phase='cancelling'})`);
  const escape = () => app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  escape(); await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, ['/abort']);
  cancelling(); escape(); await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, ['/abort', '/queue/clear', '/abort']);
});

test('prompt history restores the draft selection and exits after an edit', async () => {
  let loads = 0;
  const history = promptHistory(async () => { loads++; return ['newest', 'older']; });
  const draft = { text: 'unfinished draft', anchor: 2, head: 6 };
  assert.deepEqual(await history.move(-1, draft), { text: 'newest', anchor: 0, head: 0 });
  assert.deepEqual(await history.move(-1, draft), { text: 'older', anchor: 0, head: 0 });
  assert.deepEqual(await history.move(1, draft), { text: 'newest', anchor: 6, head: 6 });
  assert.deepEqual(await history.move(1, draft), draft);
  await history.move(-1, draft); history.reset();
  assert.equal(await history.move(1, draft), undefined);
  assert.equal(loads, 2);
});

test('built-in results keep attachments and open the requested picker', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,pi:{type:'ready'},levels:['low','high']};
    draft.restore([{id:'file',name:'notes',path:'/tmp/notes',size:2,kind:'file',origin:'path'}]);
    editor.setText('/thinking');
    fetchJSON=async()=>({disposition:'handled',action:{type:'picker',kind:'thinking',search:''}});
    send().then(()=>[draft.count,editor.text(),element('picker').hidden]);
  `);
  assert.deepEqual(Array.from(result), [1, '', false]);
});

test('a reload action blocks the composer and keeps its text through a lost stream', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,pi:{type:'ready'}};
    editor.setText('/reload');fetchJSON=async()=>({disposition:'handled',action:{type:'reload'}});
    send().then(()=>[element('error').textContent,element('field').inert]);
  `);
  assert.deepEqual(Array.from(result), ['Reloading…', true]);
  const connect = await connectSource('page/page.ts');
  const error = { textContent: 'Reloading…' };
  let source: EventSource | undefined;
  class EventSource { onerror?: () => void; onopen?: () => void; constructor() { source = this; } close() {} }
  runInNewContext(connect + ';connect()', { reloading: true, koaInstance: 'i1', EventSource, epoch: '', after: -1, delay: 200, element: () => error, setTimeout() {}, window: { addEventListener() {} } });
  source?.onopen?.(); source?.onerror?.();
  assert.equal(error.textContent, 'Reloading…');
});

test('a reload record reloads the page', async () => {
  const f = await page();
  const reloads: number[] = [];
  Object.assign(f.context, { location: { reload: () => reloads.push(1) } });
  f.run("apply({type:'reload'})");
  assert.deepEqual(reloads, [1]);
});

test('take-back shortcut shares one in-flight request and never aborts', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,pi:{type:'ready'}}; editor.setText('draft');
    const paths=[];let release;
    fetchJSON=path=>{paths.push(path);return new Promise(resolve=>{release=resolve})};
    const requestOne=takeBack(),requestTwo=takeBack();
    release({steering:[{text:'steer',attachments:[]}],followUp:[{text:'later',attachments:[]}]});
    Promise.all([requestOne,requestTwo]).then(()=>[paths.join(','),editor.text()]);
  `);
  assert.deepEqual(Array.from(result), ['/queue/clear', 'draft\n\nsteer\n\nlater']);
});

test('an extension-handled prompt retains its attachments with a none action', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,pi:{type:'ready'}};
    draft.restore([{id:'file',name:'notes',path:'/tmp/notes',size:2,kind:'file',origin:'path'}]);
    editor.setText('/custom');fetchJSON=async()=>({disposition:'handled',action:{type:'none'}});
    send().then(()=>[draft.count,editor.text(),element('error').textContent]);
  `);
  assert.deepEqual(Array.from(result), [1, '', '']);
});

test('Return during compaction keeps the draft and attachments without a request', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,pi:{type:'ready'},working:true,compaction:'running'};
    draft.restore([{id:'file',name:'notes',path:'/tmp/notes',size:2,kind:'file',origin:'path'}]);
    editor.setText('keep this draft'); let calls=0;fetchJSON=async()=>{calls++;return {}};
    refreshComposer();send().then(()=>[calls,editor.text(),draft.count]);
  `);
  assert.deepEqual(Array.from(result), [0, 'keep this draft', 1]);
  assert.equal(f.prompt()?.placeholder, 'Message koa…');
});

test('Escape aborts compaction after the slash command has returned', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,pi:{type:'ready'}};editor.setText('/compact');const requests=[];
    fetchJSON=async path=>{requests.push(path);return path==='/prompt'?{disposition:'handled',action:{type:'none'}}:path==='/queue/clear'?{steering:[],followUp:[]}:{}};
    send().then(async()=>{state={...state,working:true,compaction:'running'};await stop();return requests.join(',')});
  `);
  assert.equal(result, '/prompt,/queue/clear,/abort');
});

test('cancelled compaction is a muted notice', async () => {
  const f = await page();
  const result = f.run(`
    put({kind:'command',seq:0,at:1,final:true,result:{type:'compaction',state:{type:'cancelled'}}});
    [views.get(0).view.className,views.get(0).view.children[0].textContent];
  `);
  assert.deepEqual(Array.from(result), ['note', 'compaction cancelled']);
});

test('command results use notice lines and expandable session information', async () => {
  const f = await page();
  const result = f.run(`
    put({kind:'command',seq:0,at:1,final:true,result:{type:'copy',characters:2100}});
    put({kind:'command',seq:1,at:1,final:false,result:{type:'compaction',state:{type:'running'}}});
    put({kind:'command',seq:2,at:1,final:true,result:{type:'session',name:'session',stats:{sessionId:'id',totalMessages:212,tokens:{input:1,output:2,cacheRead:3,cacheWrite:4},cost:1.42}}});
    const info=views.get(2).view;info.children[0].onclick();
    [views.get(0).view.children[0].textContent,views.get(1).view.className,info.className];
  `);
  assert.deepEqual(Array.from(result), ['copied the last reply · 2.1k characters', 'note', 'info open']);
});

test('session picker filters locally and keeps the draft on a switch', async () => {
  const fixture = await page();
  const result = await fixture.run(`(async()=>{
    state={...state,pi:{type:'ready'},sessionId:'old'};
    editor.setText('keep my draft');
    const calls=[];
    fetchJSON=async(path,body)=>{calls.push([path,body]);return path==='/sessions/list'?{rows:[{id:'one',path:'/tmp/one',cwd:'/work/a',name:'First',firstMessage:'hello',modified:1,messageCount:2},{id:'two',path:'/tmp/two',cwd:'/work/b',firstMessage:'other',modified:2,messageCount:1}]}:{};};
    await openSessions();
    sessionSearch.value='other';sessionSearch.oninput();
    const shown=sessionResults.children.map(row=>row.children[0].textContent);
    await chooseSession({type:'switch',path:'/tmp/two'});
    apply({type:'state',...state,sessionId:'two'});
    return {shown,calls,text:editor.text()};
  })()`);
  assert.deepEqual(Array.from(result.shown), ['other']);
  assert.equal(result.text, 'keep my draft');
  assert.equal(result.calls[0][0], '/sessions/list');
  assert.equal(result.calls[1][0], '/sessions/switch');
});

test('resume consumes only command text and confirms before aborting a turn', async () => {
  const app = await page();
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => path === '/prompt' ? { disposition: 'handled', action: { type: 'session', kind: 'resume' } } : path === '/sessions/list' ? { rows: [] } : {} }; };
  const saved = app.run("state={...state,pi:{type:'ready'},working:true};draft.restore([{id:'draft',name:'note',path:'/tmp/note',size:1,origin:'upload',kind:'file'}]);editor.setText('/resume');void send();({files:()=>draft.files})");
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(app.text(), '');
  assert.deepEqual(requests, ['/prompt']);
  assert.equal(app.elements.get('session-picker')?.children[0].children[0].children[0].textContent, 'Switch session?');
  assert.equal(app.elements.get('field')?.inert, true);
  app.elements.get('session-picker')?.onkeydown?.({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, ['/prompt', '/abort', '/sessions/list']);
  assert.equal(saved.files()[0].id, 'draft');
});

test('session confirmation cancels commands and concurrent turns before opening the picker', async () => {
  for (const working of [false, true]) {
    const app = await page(), requests: string[] = [];
    app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({ rows: [] }) }; };
    app.run(`state={...state,pi:{type:'ready'},working:${working},bash:[{id:'run',phase:'running',command:'echo hi',excludeFromContext:false,started:1,output:{text:'',cut:0}}]};void sessionCommand('resume')`);
    const card = app.elements.get('session-picker')?.children[0];
    assert.equal(card?.children[1].textContent, working ? 'koa is working on a turn; it will be aborted.' : 'a command is running; it will be cancelled.');
    assert.deepEqual(requests, []);
    app.elements.get('session-picker')?.onkeydown?.({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.deepEqual(requests, working ? ['/abort', '/abort', '/sessions/list'] : ['/abort', '/sessions/list']);
  }
});

test('session scope loading has no stale choices and cached scopes do not rescan', async () => {
  const app = await page();
  const result = await app.run(`(async()=>{
    state={...state,pi:{type:'ready'},sessionId:'old'};
    const calls=[];let release;
    fetchJSON=async(path,body)=>{calls.push(path);if(calls.length===1)return {rows:[{id:'one',path:'/tmp/one',cwd:'/work',firstMessage:'keep one',modified:2,messageCount:1},{id:'two',path:'/tmp/two',cwd:'/work',firstMessage:'keep two',modified:1,messageCount:1}]};return new Promise(resolve=>{release=resolve})};
    await openSessions();
    const row=sessionResults.children[0];
    sessionHost.onkeydown({key:'ArrowDown',preventDefault(){},stopPropagation(){}});
    const same=row===sessionResults.children[0];
    const loading=openSessions('all');sessionSearch.value='keep';sessionSearch.oninput();
    sessionHost.onkeydown({key:'Enter',preventDefault(){},stopPropagation(){}});
    const hidden=visibleSessions.length===0&&sessionPicker==='loading';
    release({rows:[]});await loading;await openSessions('current');
    return {same,hidden,calls,rows:visibleSessions.length};
  })()`);
  assert.equal(result.same, true); assert.equal(result.hidden, true);
  assert.equal(result.rows, 2);
  assert.deepEqual(Array.from(result.calls), ['/sessions/list', '/sessions/list']);
});

test('busy confirmation submits once and cancelling a held abort prevents the session action', async () => {
  const app = await page();
  const calls: string[] = [];
  let release: () => void = () => {};
  app.context.fetch = async (path?: string) => {
    calls.push(path ?? '');
    return new Promise<{ ok: boolean; json(): Promise<object> }>(resolve => { release = () => resolve({ ok: true, json: async () => ({}) }); });
  };
  const saved = app.run("state={...state,pi:{type:'ready'},working:true,sessionId:'old'};void sessionCommand('new');({press:key=>sessionHost.onkeydown({key,preventDefault(){},stopPropagation(){}}),closed:()=>sessionPicker==='closed'})");
  saved.press('Enter'); saved.press('Enter'); saved.press('Escape'); release();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(calls, ['/abort']); assert.equal(saved.closed(), true);
});
test('annotation map attaches a late reply, hides items and re-renders final text only for a new annotation item', async () => {
  const fixture = await page();
  const result = fixture.run(`
    const reply={kind:'assistant',seq:0,at:1,final:true,stop:'stop',error:'',blocks:[{type:'text',text:'Pick one?\\n\\nUntouched.'}]};
    const entry={kind:'annotations',seq:1,at:2,final:true,reply:{seq:0,block:0},annotations:[{type:'question',range:[0,9],kind:'open',options:[]}]};
    put(entry); put(reply);
    const memo=texts.get('0:0'), kept=memo.blocks.at(-1).block, touched=memo.blocks[0].block;
    const attached=memo.annotationItem===entry&&views.get(1).view.hidden;
    put({...entry,seq:2,annotations:[{type:'question',range:[0,9],kind:'yes_no',options:[]}]});
    const replaced=memo.annotationItem.seq===2&&memo.blocks.at(-1).block!==kept&&memo.blocks[0].block!==touched&&memo.source===undefined;
    put(entry);
    [attached,replaced,memo.annotationItem.seq===2];
  `);
  assert.deepEqual(Array.from(result), [true, true, true]);
});

test('/name keeps draft attachments for the next prompt', async () => {
  const app = await page(), requests: { text: string; attachments: string[] }[] = [];
  app.context.fetch = async (path?: string, options?: { body?: string }) => { assert.equal(path, '/prompt'); requests.push(JSON.parse(options?.body ?? '{}')); return { ok: true, json: async () => requests.length === 1 ? ({ disposition: 'handled', action: { type: 'none' } }) : ({ disposition: 'started' }) }; };
  app.run("state={...state,pi:{type:'ready'}};draft.restore([{id:'file',name:'note.txt',path:'/tmp/note.txt',origin:'path',kind:'file',size:4}]);editor.setText('/name saved')");
  app.handlers()?.send('prompt'); await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(app.elements.get('attachments')?.children.length, 2); assert.equal(app.text(), '');
  const prompt = app.prompt(); assert.ok(prompt); prompt.value = 'Review';
  app.handlers()?.send('prompt'); await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests.map(request => [request.text, request.attachments]), [['/name saved', ['file']], ['Review', ['file']]]);
  assert.equal(app.elements.get('attachments')?.children.length, 1);
});

test('user messages use the shared Markdown HTML sink and keep plain paragraphs compact', async t => {
  for (const text of ['plain message', 'Use `inline`\n\n- item\n\n```js\nconst x = 1;\n```\n\n<b>raw</b>']) await t.test(text === 'plain message' ? 'plain' : 'Markdown', async () => {
    const app = await page(), html: string[] = [];
    const create = app.context.document.createElement;
    app.context.document.createElement = tag => { const node = create(tag); if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) { html.push(value); } }); return node; };
    app.run('put(' + JSON.stringify({ seq: 0, at: 0, kind: 'user', final: true, text, images: [], attachments: [] }) + ')');
    const result = html.join('');
    if (text === 'plain message') assert.equal(result.trim(), '<p>plain message</p>');
    else { assert.match(result, /<code>inline<\/code>/); assert.match(result, /<ul>[\s\S]*<li>item<\/li>/); assert.match(result, /<pre><code class="language-js">const x = 1;/); assert.match(result, /&lt;b&gt;raw&lt;\/b&gt;/); }
  });
});

test("native drops install ready records without path requests", async () => {
  const app = await page();
  Object.assign(app.context.window.ko, { local: true });
  let expire: () => void = () => assert.fail('The folder notice needs an expiry');
  Object.assign(app.context, { setTimeout(callback: () => void, delay: number) { assert.equal(delay, 4000); expire = callback; return 1; }, clearTimeout() {} });
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => {
    requests.push(path ?? '');
    assert.equal(path, '/attachments/one/delete'); return { ok: true, json: async () => ({}) };
  };
  app.run("state={...state,pi:{type:'ready'}};refreshComposer();editor.setText('draft')");
  const drop = (detail: unknown) => app.windowListeners.get('ko-drop')?.(new app.context.CustomEvent('ko-drop', { detail }));
  for (const files of [['relative'], ['/tmp/bad\nname'], Array(17).fill('/tmp/one.txt')]) drop({ files, refused: false });
  assert.equal(requests.length, 0);
  drop({ files: ['one', 'two'].map(id => ({ id, path: '/tmp/' + id + '.txt', origin: 'path', name: id + '.txt', kind: 'file', size: 4 })), refused: true });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(requests.length, 0);
  const host = app.elements.get('attachments'); assert.ok(host);
  assert.equal(host.children.length, 3);
  const notice = host.lastChild; assert.ok(notice);
  assert.equal(notice.textContent, 'Folders are not attached'); assert.equal(notice.hidden, false);
  expire(); assert.equal(notice.hidden, true);
  drop({ files: [], refused: true }); assert.equal(notice.hidden, false);
  let prevented = false;
  app.listeners.get('drop')?.({ dataTransfer: { files: [new File(['x'], 'ignored.txt')], items: [] }, preventDefault() { prevented = true; } });
  assert.equal(prevented, true); assert.equal(requests.length, 0); assert.equal(notice.hidden, false);
  drop({ files: [], refused: false }); assert.equal(notice.hidden, true);
  const close = host.children[0]?.children[1]; assert.ok(close);
  assert.equal(typeof close.onclick, 'function'); close.onclick?.(); await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(requests.at(-1), '/attachments/one/delete'); assert.equal(host.children.length, 2);
  assert.equal(app.text(), 'draft');
});

test("file drops attach bytes without inserting text and send their ids", async () => {
  const app = await page();
  app.run("state={...state,pi:{type:'ready'}};refreshComposer();editor.setText('draft')");
  assert.equal(typeof app.listeners.get('drop'), 'function');
  const requests: { path: string; body: unknown }[] = [];
  let uploaded: () => void = () => {};
  const complete = new Promise<void>(resolve => { uploaded = resolve; });
  app.context.fetch = async (path?: string, options?: { body?: unknown }) => {
    const body = typeof options?.body === 'string' ? JSON.parse(options.body) : options?.body;
    requests.push({ path: path ?? '', body });
    if (path === '/attachments') { assert.deepEqual(body, { name: 'note.txt', type: 'text/plain', size: 4 }); return { ok: true, json: async () => ({ id: 'copy', path: '/tmp/attachments/copy/note.txt' }) }; }
    if (path === '/attachments/copy/0') { assert.ok(ArrayBuffer.isView(body)); assert.equal(body.byteLength, 4); uploaded(); return { ok: true, json: async () => ({ received: 4, attachment: { id: 'copy', origin: 'upload', path: '/tmp/attachments/copy/note.txt', name: 'note.txt', size: 4, kind: 'file' } }) }; }
    assert.equal(path, '/prompt'); return { ok: true, json: async () => ({}) };
  };
  const file = new File(['note'], 'note.txt', { type: 'text/plain' });
  let prevented = false;
  app.listeners.get('drop')?.({ dataTransfer: { files: [file], items: [] }, preventDefault() { prevented = true; } });
  await complete; await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(prevented, true); assert.equal(app.text(), 'draft');
  app.handlers()?.send('prompt'); await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests.at(-1), { path: '/prompt', body: { text: 'draft', mode: 'prompt', attachments: ['copy'] } });
});

test("composer handlers send the selected mode and quit", async () => {
  const app = await page();
  const requests: { path: string; body: object }[] = [];
  app.context.fetch = async (path?: string, options?: { body?: string }) => { requests.push({ path: path ?? '', body: JSON.parse(options?.body ?? '{}') }); return { ok: true, json: async () => ({}) }; };
  app.run("state={...state,pi:{type:'ready'}};refreshComposer();editor.setText('draft')");
  app.handlers()?.send('follow_up');
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, [{ path: '/prompt', body: { text: 'draft', mode: 'follow_up', attachments: [] } }]);
  app.handlers()?.quit();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(requests[1]?.path, '/quit');
});

async function connectSource(name: string) {
  const source = stripTypeScriptTypes(await readFile(new URL(name, import.meta.url), "utf8"));
  return source.slice(source.indexOf("let source"), source.indexOf("async function older()"));
}

test("working time moves into the state cell and formats minutes", async () => {
  const app = await page();
  assert.equal(app.run("Date.now=()=>9000;state={...state,pi:{type:'ready'},working:true,since:0};refreshComposer();const short=element('status').textContent==='working'&&element('status').children[0].textContent===' 9s'&&element('dot').className==='dot on';Date.now=()=>754000;status();short&&element('status').children.length===1&&element('status').children[0].textContent===' 12m 34s'"), true);
});

test("printable transcript keys cannot change the draft during startup", async () => {
  const app = await page();
  app.run("refreshComposer()");
  app.listeners.get('keydown')?.({ key: 'z', target: app.context.document.createElement('div'), preventDefault() {} });
  assert.equal(app.text(), '');
});

test("composer gains focus when delayed pi readiness removes inert", async () => {
  const app = await page();
  app.run("state={...state,pi:{type:'starting'}};refreshComposer();focusComposer()");
  app.windowListeners.get('load')?.();
  assert.equal(app.context.document.activeElement, undefined);
  app.run("state.pi={type:'ready'};refreshComposer()");
  assert.equal(app.context.document.activeElement, app.prompt());
});

test("async send and dialog completion preserve focus while the document lacks focus", async t => {
  for (const action of ['send', 'dialog', 'picker']) await t.test(action, async () => {
    const app = await page();
    app.context.document.hasFocus = () => false;
    let release: () => void = () => {};
    app.context.fetch = async () => { await new Promise<void>(resolve => { release = resolve; }); return { ok: true, json: async () => ({}) }; };
    const pending = action === 'send' ? app.run("state={...state,pi:{type:'ready'}};editor.setText('draft');send()") : undefined;
    if (action === 'send') { release(); await pending; }
    else if (action === 'dialog') app.run("dialogId='done';state.dialogs=[];dialogs()");
    else app.run("pickerButton=element('model');closePicker()");
    assert.equal(app.context.document.activeElement, undefined, action);
  });
});

test('composer focus border follows key routing, not the active element', async () => {
  const app = await page();
  let focused = true;
  app.context.document.hasFocus = () => focused;
  const controls = app.run(`state={...state,pi:{type:'ready'}};refreshComposer();focusComposer();({
    picker(){state.levels=['off','low'];return picker('thinking')},
    working(){closePicker();state.working=true;refreshComposer()},
    dialog(method){state.dialogs=[{id:method,method,title:'Question',options:['One'],message:'Proceed?'}];refreshComposer();dialogs()},
    clear(){state.dialogs=[];document.body.focus();refreshComposer();dialogs()},
    preview(){preview('/images/0',element('model'),'image',composerFocus)},
    closePreview(){previewKey({key:'Escape',preventDefault(){},stopPropagation(){}})},
    exit(){state.pi={type:'exited',at:1,exited:0,stderr:''};refreshComposer();exited()}
  })`);
  const field = app.elements.get('field'); assert.ok(field);
  const border = () => field.classList.contains('focus');
  assert.equal(border(), true);
  app.context.document.body.focus();
  assert.equal(border(), true);
  const completion = app.context.document.createElement('div'); completion.setAttribute('role', 'listbox'); completion.focus();
  assert.equal(border(), true);
  await controls.picker();
  assert.equal(border(), true);
  controls.working();
  assert.equal(border(), true);
  for (const tag of ['input', 'textarea', 'select']) {
    const input = app.context.document.createElement(tag); input.focus();
    assert.equal(border(), false);
    app.context.document.body.focus(); assert.equal(border(), true);
  }
  const editable = app.context.document.createElement('div'); editable.isContentEditable = true; editable.focus();
  assert.equal(border(), false);
  app.context.document.body.focus();
  for (const method of ['input', 'select', 'confirm']) {
    controls.dialog(method);
    assert.equal(border(), false);
    controls.clear(); assert.equal(border(), true);
  }
  controls.preview();
  assert.equal(border(), false);
  const restore = app.elements.get('model'); assert.ok(restore);
  app.context.document.body.append(restore); restore.focus();
  assert.equal(border(), false);
  controls.closePreview();
  assert.equal(border(), true);
  focused = false; app.windowListeners.get('blur')?.(); assert.equal(border(), false);
  focused = true; app.windowListeners.get('focus')?.(); assert.equal(border(), true);
  controls.exit();
  assert.equal(border(), false);
});

test("composer waits for document focus at startup and load", async () => {
  const app = await page();
  let focused = false;
  app.context.document.hasFocus = () => focused;
  app.run("state={...state,pi:{type:'ready'}};refreshComposer();focusComposer()");
  assert.equal(app.context.document.activeElement, undefined);
  app.windowListeners.get('load')?.();
  assert.equal(app.context.document.activeElement, undefined);
  focused = true;
  app.windowListeners.get('focus')?.();
  assert.equal(app.context.document.activeElement, app.prompt());
});

test("pane focus selects the composer without taking page controls or dialog fields", async () => {
  const app = await page();
  app.run("state={...state,pi:{type:'ready'},dialogs:[]};element('model').tagName='BUTTON';editor.focus()");
  app.context.document.activeElement = undefined;
  app.windowListeners.get('focus')?.();
  assert.equal(app.context.document.activeElement, app.prompt());
  for (const tag of ['INPUT', 'TEXTAREA', 'SELECT', 'BUTTON']) {
    const control = app.elements.get('model');
    assert.ok(control);
    control.tagName = tag; control.focus();
    app.windowListeners.get('focus')?.();
    assert.equal(app.context.document.activeElement, control);
  }
  const editable = app.elements.get('model');
  assert.ok(editable);
  editable.tagName = 'DIV'; editable.isContentEditable = true; editable.focus();
  app.windowListeners.get('focus')?.();
  assert.equal(app.context.document.activeElement, editable);
  app.run("state.dialogs=[{id:'question'}]");
  app.context.document.activeElement = undefined;
  app.windowListeners.get('focus')?.();
  assert.equal(app.context.document.activeElement, undefined);
});

test("printable transcript keys reach the composer but native shortcuts and fields keep their keys", async () => {
  const app = await page();
  app.run("state={...state,pi:{type:'ready'},dialogs:[]}");
  const target = app.context.document.createElement('div');
  let prevented = 0;
  const key = (extra = {}) => app.listeners.get('keydown')?.({ key: 'z', target, preventDefault() { prevented++; }, ...extra });
  for (const modifier of ['metaKey', 'ctrlKey', 'altKey', 'isComposing']) key({ [modifier]: true });
  const button = app.context.document.createElement('div'); button.tagName = 'BUTTON';
  key({ key: ' ', target: button });
  key({ key: 'Enter', target: button });
  assert.equal(prevented, 0);
  assert.equal(app.text(), '');
  key();
  assert.equal(app.text(), 'z');
  assert.equal(app.context.document.activeElement, app.prompt());
  assert.equal(prevented, 1);
  key({ target: app.prompt() });
  const editable = app.context.document.createElement('div'); editable.isContentEditable = true;
  key({ target: editable });
  assert.equal(prevented, 1);
  assert.equal(app.listeners.has('blur'), false);
  assert.equal(app.windowListeners.has('blur'), true);
  app.context.document.documentElement.classList.add('preview-modifiers');
  app.windowListeners.get('blur')?.();
  assert.equal(app.context.document.documentElement.classList.contains('preview-modifiers'), false);
  assert.equal(app.context.document.activeElement, app.prompt());
});

test("Space on a fold control toggles once without typing or losing focus", async () => {
  const app = await page();
  const { view, line } = app.run("state={...state,pi:{type:'ready'},dialogs:[]};const view=node('div'),line=node('div');fold(view,'fold',line,node('div'));line.focus();({view,line})");
  const event = { key: ' ', target: line, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  line.onkeydown(event);
  app.listeners.get('keydown')?.(event);
  assert.equal(view.classList.contains('open'), true);
  assert.equal(line.attributes.get('aria-expanded'), 'true');
  assert.equal(app.text() ?? '', '');
  assert.equal(app.context.document.activeElement, line);
  app.windowListeners.get('focus')?.();
  assert.equal(app.context.document.activeElement, line);
});

test("an open picker keeps letters and window focus and still handles Enter and Escape", async () => {
  for (const key of ['Enter', 'Escape']) {
    const app = await page();
    const requests: string[] = [];
    app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
    await app.run("state={...state,pi:{type:'ready'},dialogs:[],levels:['off','low'],thinking:'off'};picker('thinking')");
    const host = app.elements.get('picker');
    assert.ok(host);
    app.listeners.get('keydown')?.({ key: 'z', target: host, preventDefault() {} });
    assert.equal(app.text() ?? '', '');
    assert.equal(app.context.document.activeElement, host);
    app.windowListeners.get('focus')?.();
    assert.equal(app.context.document.activeElement, host);
    assert.ok(host.onkeydown);
    host.onkeydown({ key, preventDefault() {}, stopPropagation() {} });
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.deepEqual(requests, key === 'Enter' ? ['/thinking'] : []);
    assert.equal(host.hidden, true);
    assert.equal(app.context.document.activeElement, app.prompt());
  }
});

test("closing a picker or a dialog returns focus to the composer", async () => {
  const app = await page();
  app.run("pickerButton=element('model');element('model').focus();closePicker()");
  assert.equal(app.context.document.activeElement, app.prompt());
  app.run("dialogId='question';state.dialogs=[];element('model').focus();dialogs()");
  assert.equal(app.context.document.activeElement, app.prompt());
});

test("the transcript page applies SSE synchronously and reconnects with the applied cursor", async () => {
  for (const name of ["page/page.ts"]) {
    const connect = await connectSource(name);
    const sources: EventSource[] = [];
    class EventSource {
      onopen?: () => void; onerror?: () => void; onmessage?: (event: { data: string }) => void;
      closed = false;
      readonly url: string;
      constructor(url: string) { this.url = url; sources.push(this); }
      close() { this.closed = true; }
    }
    const received: object[] = [];
    const retries: (() => void)[] = [];
    const retry = () => { const callback = retries.shift(); assert.ok(callback); callback(); };
    let teardown: () => void = () => {};
    let restore: (event: { persisted: boolean }) => void = () => {};
    const error = { textContent: '' };
    const context = { metrics: undefined, koaInstance: "i1", reloading: false, epoch: "", after: -1, delay: 200, disconnected: false, EventSource, Error, console: { error() {} }, window: { addEventListener(name: string, handler: (event?: { persisted: boolean }) => void) { if (name === "pagehide") teardown = handler; else if (name === "pageshow") restore = handler; } }, apply(record: { type: string; epoch?: string; after?: number }) {
      if (record.type === "bad") throw Error("Apply failed");
      received.push(record);
      if (record.epoch) context.epoch = record.epoch;
      if (record.after !== undefined) context.after = record.after;
    }, element: () => error, followBottom() {}, setTimeout(callback: () => void) { retries.push(callback); }, clearTimeout() {} };
    runInNewContext(connect + ";connect()", context);
    sources[0].onopen?.();
    sources[0].onmessage?.({ data: '{"type":"state","epoch":"new","after":3}' });
    assert.equal(received.length, 1, name);
    sources[0].onerror?.();
    assert.equal(sources[0].closed, true);
    retry();
    assert.equal(sources[1].url, "/events?epoch=new&after=3&koa=i1");
    teardown();
    assert.equal(sources[1].closed, true);
    restore({ persisted: false });
    assert.equal(sources.length, 2);
    restore({ persisted: true });
    assert.equal(sources.length, 3);
    assert.equal(sources[2].url, "/events?epoch=new&after=3&koa=i1");
    restore({ persisted: true });
    assert.equal(sources.length, 3);
    sources[2].onmessage?.({ data: '{"type":"bad"}' });
    assert.equal(sources[2].closed, true);
    assert.equal(error.textContent, "This page cannot show koa's state: Apply failed. Reload the pane.");
    assert.equal(sources[2].onmessage, null);
    assert.equal(sources[2].onerror, null);
    assert.equal(sources[2].onopen, null);
    assert.equal(retries.length, 0);
    teardown();
    restore({ persisted: true });
    assert.equal(sources.length, 3);
    assert.equal(error.textContent, "This page cannot show koa's state: Apply failed. Reload the pane.");
  }
});

test("stream metrics use the selected mode in a Kido page", async () => {
  const connect = await connectSource("page/page.ts");
  for (const mode of ["applied", "frame"]) {
    const metrics = { mode, bytes: 0, pending: [], samples: [], frames: new Set(), timer: undefined };
    let frames = 0;
    class EventSource {
      onmessage?: (event: { data: string }) => void;
      constructor() { queueMicrotask(() => this.onmessage?.({ data: '{"type":"flush","t":1000,"bytes":1234}' })); }
    }
    runInNewContext(connect + ";connect()", { metrics, koaInstance: "i1", EventSource, window: { addEventListener() {} }, epoch: "", after: -1, delay: 200, console, element: () => ({}), followBottom() {}, performance: { timeOrigin: 1000, now: () => 12 }, Date: { now: () => 1012 }, sendMetrics() {}, setTimeout() {}, requestAnimationFrame(callback: () => void) { frames++; callback(); } });
    await Promise.resolve();
    assert.equal(frames, mode === "frame" ? 1 : 0);
    assert.deepEqual(JSON.parse(JSON.stringify(metrics.samples)), [{ t: 1000, [mode]: 1012, bytes: 1234, clockError: 0 }]);
  }
});

test("finished prose and view change checks retain no extra text strings", async () => {
  const app = await page();
  const retained = app.run("const text='payload '.repeat(10000);put({seq:0,kind:'assistant',final:true,blocks:[{type:'text',text}]});({source:texts.get('0:0').source,signature:views.get(0).signature})");
  assert.deepEqual({ source: retained.source?.length ?? 0, signature: retained.signature?.length ?? 0 }, { source: 0, signature: 0 });
  assert.equal(app.run("const initial={seq:1,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:'first'}]};put(initial);apply({type:'patch',baseRevision:0,revision:1,seq:1,final:false,blocks:[{index:0,suffix:' last'}]});const updated=items.get(1),streaming=texts.get('1:0').source==='first last';apply({type:'patch',baseRevision:1,revision:2,seq:1,final:true,stop:'',error:'',blocks:[]});initial!==updated&&initial.blocks!==updated.blocks&&initial.blocks[0]!==updated.blocks[0]&&initial.blocks[0].text==='first'&&streaming&&texts.get('1:0').source===undefined&&views.get(1).item===items.get(1)"), true);
  assert.equal(app.run("const finished={seq:0,revision:0,kind:'assistant',final:true,blocks:[{type:'text',text:'same'}]};put(finished);const proseView=texts.get('0:0').view;put({...finished,blocks:[{type:'text',text:'same'}]});apply({type:'patch',baseRevision:0,revision:1,seq:0,final:true,stop:'stop',ended:42,blocks:[]});texts.get('0:0').view===proseView&&items.get(0).stop==='stop'&&items.get(0).ended===42"), true);
});

test('thinking Markdown renders only on expand and stays current across streaming rebuilds', async () => {
  const app = await page(), rendered: string[] = [];
  let renderers = 0;
  app.context.markdown = (user = false) => {
    assert.equal(user, false);
    renderers++;
    const render = markdown(user);
    return (...args: Parameters<typeof render>) => {
      const blocks = render(...args);
      rendered.push(blocks.map(block => block.html ?? '').join(''));
      return blocks;
    };
  };
  app.run(`
    put({seq:0,revision:0,at:1,kind:'assistant',final:false,blocks:[{type:'thinking',text:'**Plan**\\n\\n- Use \`code\`'}]});
    if (texts.has('0:0')) throw Error('Collapsed thinking rendered');
    const item=items.get(0);
    if (stepInfo({block:item.blocks[0],item,args:{}}).detail!=='Plan') throw Error('Markdown syntax in summary');
    const view=run([{block:item.blocks[0],item,index:0,key:'0:0'}]);
    const step=view.children[1].children[0];
    if (step.children[1].children.length) throw Error('Collapsed details have children');
    step.children[0].onclick();
    if (texts.get('0:0').view.className!=='think prose') throw Error('Missing Markdown class');
    apply({type:'patch',baseRevision:0,revision:1,seq:0,final:false,blocks:[{index:0,suffix:' and **more'}]});
    if (texts.get('0:0').source!=='**Plan**\\n\\n- Use \`code\` and **more') throw Error('Stale thinking');
    folds.set('0:0',false);
    apply({type:'patch',baseRevision:1,revision:2,seq:0,final:false,blocks:[{index:0,suffix:' words**'}]});
    if (texts.get('0:0').source!=='**Plan**\\n\\n- Use \`code\` and **more') throw Error('Collapsed thinking updated');
    folds.set('0:0',true);apply({type:'patch',baseRevision:2,revision:3,seq:0,final:true,blocks:[]});
  `);
  assert.equal(renderers, 1);
  assert.equal(rendered.length, 3);
  assert.match(rendered[0], /<strong>Plan<\/strong>/);
  assert.match(rendered[0], /<ul>/);
  assert.match(rendered[0], /<code>code<\/code>/);
  assert.match(rendered[1], /<strong>more<\/strong>/);
  assert.match(rendered[2], /<strong>more words<\/strong>/);
});

test('redacted thinking stays plain text when expanded', async () => {
  const app = await page();
  app.context.markdown = () => { throw Error('Redacted thinking rendered Markdown'); };
  assert.equal(app.run(`['', '**secret**'].every(text=>{
    const block={type:'thinking',redacted:true,text},item={final:true,blocks:[block]};
    folds.set('0:0',true);
    const view=run([{block,item,index:0,key:'0:0'}]);
    const detail=view.children[1].children[0].children[1].children[0];
    return detail.className==='think redacted'&&detail.textContent===(text||'Redacted thinking')&&detail.children.length===0&&stepInfo({block,item,args:{}}).detail==='redacted';
  })`), true);
});

test("a run joins adjacent assistant items without replacing their text views", async () => {
  const app = await page();
  assert.equal(app.run("const firstSlot=node('div'),secondSlot=node('div');items.set(0,{seq:0,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'thinking',text:'check'}]});items.set(1,{seq:1,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'tool',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'ok',images:[]}}}]});views.set(0,{slots:new Map([['0:0',{type:'run',view:firstSlot}]])});views.set(1,{slots:new Map([['1:0',{type:'run',view:secondSlot}]])});run=steps=>({count:steps.length});reconcileRuns(1);firstSlot.children[0].count===2&&secondSlot.children.length===0"), true);
});

test("invalid tool arguments do not stop rendering", async () => {
  const app = await page();
  for (const text of ["null", '{"path":"file","oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":"old","newText":"new"}']) {
    assert.doesNotThrow(() => app.run(`run([{key:'0:0',index:0,item:{final:true,stop:'stop',blocks:[]},block:{type:'tool',name:'edit',args:{text:${JSON.stringify(text)}},state:{type:'done',error:false,result:{text:'done',images:[]}}}}])`));
  }
});

test("a pending tool shows its name until its label arguments arrive", async () => {
  const app = await page();
  const labels = app.run(`
    put({seq:1,revision:0,at:0,kind:'assistant',final:false,blocks:[{type:'tool',id:'call',name:'bash',args:{text:'{}'},state:{type:'pending'}}]});
    const label=()=>{const item=items.get(1);return run([{key:'1:0',index:0,item,block:item.blocks[0]}]).children[1].children[0].children[0].children[1].children.map(c=>c.textContent).join('').trim();};
    const before=label();
    apply({type:'patch',baseRevision:0,revision:1,seq:1,final:false,blocks:[{index:0,block:{type:'tool',id:'call',name:'bash',args:{text:JSON.stringify({command:'make verify'})},state:{type:'pending'}}}]});
    [before,label()];
  `);
  assert.deepEqual(Array.from(labels), ['bashbash', 'bashmake verify']);
  assert.equal(app.run(`['bash','read','edit','write','custom'].every(name=>{
    const block={type:'tool',name,args:{text:'{}'},state:{type:'pending'}};
    return stepInfo({block,item:{final:false},args:{}}).label===name;
  })`), true);
  assert.equal(app.run(`['pending','running','done','not_run'].every(type=>{
    const block={type:'tool',name:'bash',args:{text:'{}'},state:{type}};
    return stepInfo({block,item:{final:true},args:{}}).label==='bash {}';
  })`), true);
});

test("a running tool takes priority over a later pending step", async () => {
  const app = await page();
  assert.equal(app.run("const item={final:false,stop:'',blocks:[]};const steps=[['running','read'],['pending','edit']].map(([type,name],index)=>({key:'0:'+index,index,item,block:{type:'tool',name,args:{text:'{}'},state:{type}}}));run(steps).children[0].children[0].children[0].textContent"), 'read');
});

test("ended thinking is not active while assistant text streams", async () => {
  const app = await page();
  assert.equal(app.run("const block={type:'thinking',text:'done',started:1,ended:2};const item={final:false,blocks:[block,{type:'text',text:'streaming'}]};run([{block,item,index:0,key:'0:0'}]).children[0].children[0].children.some(child=>child?.className==='spin')"), false);
});

test("model picker matches provider and id", async () => {
  const app = await page();
  const selected: object[] = [];
  app.context.fetch = async (_path?: string, options?: {body?: string}) => { if (options?.body) selected.push(JSON.parse(options.body)); return {ok:true,json:async()=>({models:[{id:'same',provider:'one'},{id:'same',provider:'two'}]})}; };
  const result = await app.run("state={...state,pi:{type:'ready'},model:{id:'same',provider:'two'}};picker('model').then(()=>{const host=element('picker');const ticks=host.children.filter(child=>child.classList.contains('row')).map(row=>row.children[0].textContent).join(',');host.onkeydown({key:'Enter',preventDefault(){},stopPropagation(){}});return ticks})");
  assert.equal(result, ',✓');
  assert.deepEqual(selected, [{provider:'two',modelId:'same'}]);
});

test("Escape takes back queued work before aborting", { timeout: 1000 }, async () => {
  const app = await page();
  let steering = [{ text: "first queued", attachments: [] }], followUp = [{ text: "second queued", attachments: [] }];
  const commands: string[] = [], started: string[] = [];
  let aborted: () => void = () => {};
  const done = new Promise<void>(resolve => { aborted = resolve; });
  app.context.fetch = async (path?: string) => {
    let data: object = {};
    if (path === "/queue/clear") { commands.push("clear_queue"); data = { steering, followUp }; steering = []; followUp = []; }
    else if (path === "/abort") { commands.push("abort"); started.push(...steering.map(entry => entry.text), ...followUp.map(entry => entry.text)); aborted(); }
    else throw Error("Unexpected request: " + path);
    return { ok: true, json: async () => data };
  };
  app.run("state={...state,pi:{type:'ready'},working:true,dialogs:[],queue:{steering:[{text:'first queued',attachments:[]}],followUp:[{text:'second queued',attachments:[]}]}}");
  app.listeners.get("keydown")?.({ key: "Escape", preventDefault() {} });
  await done;
  assert.deepEqual(commands, ["clear_queue", "abort"]);
  assert.deepEqual(started, []);
  assert.equal(app.text(), "first queued\n\nsecond queued");
});

test("editor acknowledgment keeps the second Escape clear action", async () => {
  const app = await page();
  const control = app.run("state={...state,pi:{type:'ready'}};refreshComposer();editor.setText('draft');({ack:()=>apply({...state,type:'state',editor:{id:'one',text:'replacement'}}),escaped:()=>escaped})");
  const escape = () => app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  escape();
  control.ack();
  assert.equal(control.escaped(), true);
  assert.equal(app.text(), 'replacement');
  escape();
  assert.equal(app.text(), '');
  assert.equal(control.escaped(), true);
  app.handlers()?.input(true);
  assert.equal(control.escaped(), false);
});

test("a held prompt response prevents duplicate draft submissions", async () => {
  const app = await page();
  let count = 0;
  let release: () => void = () => {};
  const held = new Promise<void>(resolve => { release = resolve; });
  app.context.fetch = async () => { count++; await held; return { ok: true, json: async () => ({}) }; };
  const result = app.run("editor.setText('one draft'); Promise.all([send(),send()])");
  assert.equal(count, 1);
  release(); await result;
});

test("a startup dialog is visible with an inert composer", async () => {
  const app = await page();
  assert.equal(app.run("status=()=>{};apply({type:'state',bash:[],pi:{type:'starting'},dialogs:[{id:'trust',method:'select',title:'Trust project?',options:['Yes','No']}],queue:{steering:[],followUp:[]}});!element('composer').hidden&&element('field').inert&&element('dialogs').children[0].className==='dialog'"), true);
});

test("a state record preserves a typed dialog answer", async () => {
  const app = await page();
  assert.equal(app.run("state={...state,working:true,dialogs:[{id:'a',method:'input',title:'Question'}]};refreshComposer();dialogs();const form=element('dialogs').children[0];const input=form.children[1];input.value='typed';state={...state,dialogs:[{id:'a',method:'input',title:'Question'}]};dialogs();apply({type:'reset',epoch:'next',more:false,items:[]});element('dialogs').children[0]===form&&input.value==='typed'&&element('prompt').children[0].placeholder==='Message koa…'&&element('field').inert"), true);
});

test("unchanged state keeps queue controls and status nodes and acknowledges editor once", async () => {
  const app = await page();
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return {ok:true,json:async()=>({})}; };
  assert.equal(app.run("status=()=>{};dialogs=()=>{};exited=()=>{};const record={...state,type:'state',pi:{type:'starting'},queue:{steering:[{text:'queued',attachments:[]}],followUp:[]},statuses:{tests:'ok'},editor:{id:'one',text:'draft'}};apply(record);const deferred=editorId===undefined;record.pi={type:'ready'};apply(record);const back=element('queue').children.at(-1).children.at(-1);apply({...record});deferred&&back===element('queue').children.at(-1).children.at(-1)&&element('status-extras').children.length===1"), true);
  assert.deepEqual(requests, ['/editor/ack']);
});

test("editor dialogs leave native keys alone and submit with Control Enter", async () => {
  const app = await page();
  const requests: object[] = [];
  app.context.fetch = async (_url?: unknown, options?: { body?: string }) => { requests.push(JSON.parse(options?.body ?? "{}")); return { ok: true, json: async () => ({}) }; };
  const result = app.run(`(()=>{
    state={...state,dialogs:[{id:'edit',method:'editor',title:'Draft',prefill:'keep this'}]};dialogs();
    const form=element('dialogs').children[0];let prevented=0;
    const event=(key,extra={})=>({key,target:form,preventDefault(){prevented++},stopPropagation(){},...extra});
    form.onkeydown(event('Enter'));form.onkeydown(event('Enter',{metaKey:true}));form.onkeydown(event('m',{ctrlKey:true}));
    const native=prevented===0;
    form.onkeydown(event('Enter',{ctrlKey:true}));return native;
  })()`);
  assert.equal(result, true);
  assert.deepEqual(requests, [{ id: "edit", value: "keep this" }]);
});

test("the exit card names a fresh start only without a saved session", async () => {
  const app = await page();
  assert.equal(app.run("state={...state,pi:{type:'exited',exited:7,at:0,stderr:''}};exited();element('exited').children[0].children.some(child=>child.className==='fresh'&&child.textContent.includes('fresh session'))"), true);
  assert.equal(app.run("state={...state,sessionFile:'saved.jsonl',pi:{type:'exited',exited:7,at:1,stderr:''}};exited();element('exited').children[0].children.some(child=>child.className==='fresh')"), false);
});

test("thinking and aborted steps use live times without inventing replay times", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const contents=value=>typeof value==='string'?value:value.textContent+value.children.map(contents).join('');
    const thinking={type:'thinking',text:'which stages',started:10000,ended:14000};
    const bash={type:'tool',name:'bash',args:{text:'{}'},started:14000,state:{type:'not_run'}};
    const item={at:10000,ended:37000,final:true,stop:'aborted',blocks:[thinking,bash]};
    const live=run(item.blocks.map((block,index)=>({block,index,key:'a'+index,item})));
    delete thinking.started;delete thinking.ended;delete bash.started;delete item.ended;
    const replay=run(item.blocks.map((block,index)=>({block,index,key:'b'+index,item})));
    return {live:contents(live),replay:contents(replay)};
  })()`);
  assert.match(result.live, /27s/);
  assert.match(result.live, /4s/);
  assert.match(result.live, /aborted 23s/);
  assert.doesNotMatch(result.replay, /27s|4s|23s/);
});

async function revealPage(clientHeight = 100) {
  const app = await page(), html: string[] = [], bars: InstanceType<typeof app.context.Node>[] = [], pres: InstanceType<typeof app.context.Node>[] = [], queued = new Map<number, () => void>(), timers = new Map<number, { at: number; callback: () => void }>();
  let clock = 0, id = 0;
  const create = app.context.document.createElement;
  const lines = (markup: string) => 20 * [...markup.matchAll(/<(p|li|h\d|pre|tr)\b[^>]*>([\s\S]*?)<\/\1>/g)].reduce((total, [, tag, inner]) => {
    const text = inner.replace(/<[^>]*>/g, '');
    return total + (tag === 'pre' ? text.replace(/\n$/, '').split('\n').length : Math.ceil(text.split(/\s+/).filter(Boolean).length / 3));
  }, 0);
  app.context.document.createElement = (tag: string) => {
    const node = create(tag);
    node.getBoundingClientRect = () => ({ left: 0, height: node.className.includes('measure') ? lines(node.innerHTML) : 0 });
    if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) {
      html.push(value);
      const child = create(value.startsWith('<pre') ? 'pre' : 'p');
      Object.assign(child, { textContent: value.replace(/<[^>]*>/g, '').replace(/\n$/, ''), after: (bar: typeof child) => bars.push(bar), getBoundingClientRect: () => ({ height: 0 }) });
      if (child.tagName === 'PRE') pres.push(child);
      node.content = { childNodes: value.trim() ? [child] : [], querySelectorAll: () => child.tagName === 'PRE' ? [child] : [] };
    } });
    return node;
  };
  Object.assign(app.context, { performance: { now: () => clock }, requestAnimationFrame: (callback: () => void) => { queued.set(++id, callback); return id; }, cancelAnimationFrame: (frame: number) => queued.delete(frame), setTimeout: (callback: () => void, delay: number) => { timers.set(++id, { at: clock + delay, callback }); return id; }, clearTimeout: (timer: number) => timers.delete(timer) });
  const evaluate = app.repl();
  evaluate(`Object.assign(element('scroll'),{clientHeight:${clientHeight},scrollTop:0})`);
  const step = (ms: number) => {
    clock += ms;
    for (const [timer, { at, callback }] of [...timers]) if (at <= clock) { timers.delete(timer); callback(); }
    for (const [frame, callback] of [...queued]) { queued.delete(frame); callback(); }
  };
  const patch = (revision: number, suffix: string, final = false) => evaluate(`apply({type:'patch',seq:0,baseRevision:${revision - 1},revision:${revision},final:${final},stop:'',error:'',blocks:[{index:0,suffix:${JSON.stringify(suffix)}}]})`);
  const put = (text: string) => evaluate(`put({seq:0,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:${JSON.stringify(text)}}]})`);
  return { app, evaluate, html, bars, pres, queued, timers, step, patch, put };
}

test('reveal waits for a whole line, caps hidden height and time, and finalizes the rest', async () => {
  const fixture = await revealPage(200);
  fixture.put('Intro.\n\none two three four five six');
  assert.deepEqual(fixture.html, ['<p>Intro.</p>\n', '', '']);
  assert.equal(fixture.evaluate("texts.get('0:0').view.children.at(-1).className"), 'typing');
  fixture.step(1000);
  assert.equal(fixture.html.length, 3);
  assert.deepEqual([fixture.queued.size, fixture.timers.size], [0, 1]);
  fixture.step(500);
  assert.equal(fixture.html.at(-1), '<p>one two three</p>\n');
  fixture.patch(1, ' seven eight nine ten eleven twelve thirteen fourteen');
  fixture.step(16);
  assert.equal(fixture.html.at(-1), '<p>one two three four five six seven eight nine ten eleven twelve</p>\n');
  fixture.patch(2, ' more', true);
  assert.equal(fixture.html.at(-1), '<p>one two three four five six seven eight nine ten eleven twelve thirteen fourteen more</p>\n');
  assert.deepEqual([fixture.evaluate("revealing.size"), fixture.evaluate("texts.get('0:0').view.children.at(-1).className === 'typing'"), fixture.queued.size], [0, false, 1]);
});

test('a duplicate revision repeats nothing and a replaced block restarts its own reveal', async () => {
  const fixture = await revealPage(200);
  fixture.put('Intro.\n\none two three four five six');
  fixture.patch(1, ' seven');
  const shown = fixture.html.length;
  fixture.patch(1, ' seven');
  fixture.evaluate("apply({type:'patch',seq:0,baseRevision:1,revision:1,final:false,stop:'',error:'',blocks:[{index:0,suffix:' dup'}]})");
  assert.equal(fixture.html.length, shown);
  const old = fixture.evaluate("texts.get('0:0')");
  fixture.evaluate("apply({type:'patch',seq:0,baseRevision:1,revision:2,final:false,stop:'',error:'',blocks:[{index:0,block:{type:'text',text:'Fresh.\\n\\nnew tail words here'}}]})");
  assert.deepEqual(fixture.html.slice(shown), ['<p>Fresh.</p>\n', '', '']);
  assert.deepEqual([fixture.evaluate("revealing.size"), fixture.evaluate("revealing.has(texts.get('0:0'))"), fixture.evaluate("texts.get('0:0')") !== old], [1, true, true]);
});

test('a hidden page holds no frames until it is shown again', async () => {
  const fixture = await revealPage();
  fixture.app.context.document.hidden = true;
  fixture.put('Intro.\n\nwaiting tail');
  assert.equal(fixture.queued.size, 0);
  fixture.app.context.document.hidden = false;
  fixture.app.listeners.get('visibilitychange')?.({});
  assert.equal(fixture.queued.size, 1);
  fixture.app.listeners.get('visibilitychange')?.({});
  assert.equal(fixture.queued.size, 1);
  fixture.app.windowListeners.get('pagehide')?.();
  assert.equal(fixture.queued.size, 0);
});

test('a reveal glides to the bottom in one step per frame and never pulls a user who scrolled up', async () => {
  const fixture = await revealPage();
  fixture.evaluate("Object.assign(element('scroll'),{scrollHeight:1000,clientHeight:200,scrollTop:0})");
  fixture.put('Intro.\n\nwaiting tail');
  fixture.step(16);
  const first = Number(fixture.evaluate("element('scroll').scrollTop"));
  assert.ok(first > 20 && first < 400, String(first));
  for (let frame = 0; frame < 80; frame++) fixture.step(16);
  assert.ok(Number(fixture.evaluate("element('scroll').scrollTop")) > 799);
  assert.equal(fixture.queued.size, 0);
  fixture.evaluate("element('scroll').scrollTop=100;element('scroll').onscroll()");
  fixture.patch(1, '\n\nsecond block\n\nthird');
  fixture.step(16); fixture.step(16);
  assert.equal(fixture.evaluate("element('scroll').scrollTop"), 100);
  assert.equal(fixture.evaluate("scrollMode"), undefined);
});

test('finishing a sliced tail glides to the new bottom instead of jumping', async () => {
  const fixture = await revealPage(200);
  fixture.evaluate("Object.assign(element('scroll'),{scrollHeight:1000,clientHeight:200,scrollTop:0})");
  fixture.put('Intro.\n\none two three four five six');
  fixture.step(1000); fixture.step(500);
  for (let frame = 0; frame < 90; frame++) fixture.step(16);
  assert.deepEqual([fixture.evaluate("scrollMode"), fixture.queued.size], [undefined, 0]);
  fixture.evaluate("element('scroll').scrollHeight=1400");
  fixture.patch(1, ' seven', true);
  fixture.evaluate("followBottom()");
  fixture.step(16);
  const moved = Number(fixture.evaluate("element('scroll').scrollTop"));
  assert.ok(moved > 800 && moved < 1000, String(moved));
  assert.equal(fixture.evaluate("scrollMode"), 'glide');
});

test('a text block followed by a later block is complete and shows no dots', async () => {
  const fixture = await revealPage();
  fixture.evaluate("put({seq:0,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:'Hello there.'},{type:'tool',id:'call',name:'bash',args:{text:'{}'},state:{type:'pending'}}]})");
  assert.equal(fixture.html[0], '<p>Hello there.</p>\n');
  assert.deepEqual([fixture.evaluate("texts.get('0:0').reveal"), fixture.evaluate("texts.get('0:0').view.children.some(child => child.className === 'typing')")], [undefined, false]);
});

test('a folded fence counts its lines while streaming and stays open after its bar is clicked', async () => {
  const fixture = await revealPage();
  const code = (count: number) => Array.from({ length: count }, (_, index) => 'line ' + index).join('\n');
  fixture.put('Intro.\n\n```js\n' + code(20));
  fixture.step(16);
  assert.deepEqual(fixture.bars.map(bar => bar.textContent), ['Show 4 more lines']);
  assert.equal(fixture.pres.at(-1)?.classList.contains('folded'), true);
  fixture.patch(1, '\n' + code(5));
  fixture.step(16);
  assert.equal(fixture.bars.at(-1)?.textContent, 'Show 9 more lines');
  fixture.bars.at(-1)?.onclick?.();
  const bars = fixture.bars.length;
  fixture.patch(2, '\nmore\nlines\n');
  fixture.step(16);
  assert.equal(fixture.bars.length, bars);
  assert.equal(fixture.pres.at(-1)?.classList.contains('folded'), false);
});

test("buffered patches drain against the snapshot by revision", async () => {
  const gated = async (setup: string, buffered: string, items: object[]) => {
    const app = await page();
    let release: (value: { ok: boolean; json: () => Promise<object> }) => void = () => {};
    app.context.fetch = () => new Promise(resolve => { release = resolve; });
    const result = app.run(`let connects=0;connect=()=>{connects++};put=item=>items.set(item.seq,item);epoch='e';first=4;more=true;${setup};const loading=older();const patch=(seq,baseRevision,revision,suffix)=>apply({type:'patch',seq,baseRevision,revision,final:false,stop:'',error:'',blocks:[{index:0,suffix}]});${buffered};loading.then(()=>[items.get(3).blocks[0].text,items.get(2)?.blocks[0].text,connects])`);
    release({ ok: true, json: async () => ({ epoch: "e", more: false, items }) });
    return Array.from(await result);
  };
  const text = (seq: number, revision: number, value: string) => ({ seq, revision, kind: "assistant", final: false, blocks: [{ type: "text", text: value }] });
  assert.deepEqual(await gated("", "patch(3,0,1,' world');patch(2,1,2,' world')", [text(2, 1, "Hello"), text(3, 1, "Hello world")]), ["Hello world", "Hello world", 0]);
  assert.deepEqual(await gated("", "patch(3,5,6,' gap');patch(3,0,1,' late')", [text(3, 0, "Hello")]), ["Hello", undefined, 1]);
});

test("a history reply from before an epoch reset is dropped and does not block the next request", async () => {
  const app = await page();
  const releases: ((value: { ok: boolean; json: () => Promise<object> }) => void)[] = [];
  app.context.fetch = () => new Promise(resolve => { releases.push(resolve); });
  Object.assign(app.context, {
    release: (index: number, epoch: string, seq: number) => releases[index]({ ok: true, json: async () => ({ epoch, more: false, items: [{ seq, revision: 0, kind: "assistant", final: true, blocks: [] }] }) }),
    count: () => releases.length,
  });
  const result = await app.run(`(async()=>{
    put=item=>items.set(item.seq,item);epoch='e';first=4;more=true;
    const one=older();
    apply({type:'reset',epoch:'f',more:true,items:[{seq:7,revision:0,kind:'assistant',final:true,blocks:[]}]});first=7;
    const two=older(), started=count();
    release(0,'f',3);await one;older();
    const stale=[items.has(3),count()];
    release(1,'e',5);await two;
    const wrong=[items.has(5),more];
    const third=older();release(2,'f',6);await third;
    return {started,stale,wrong,added:[count(),items.has(6)]};
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { started: 2, stale: [false, 2], wrong: [false, true], added: [3, true] });
});

test("a duplicate patch is skipped and a gap or non-assistant target reconnects from a reset", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    let connects=0;connect=()=>{connects++};put=item=>items.set(item.seq,item);epoch='e';
    items.set(1,{seq:1,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:'a'}]});
    items.set(2,{seq:2,revision:0,kind:'notify'});
    const patch=(seq,baseRevision,revision,suffix)=>apply({type:'patch',seq,baseRevision,revision,final:false,stop:'',error:'',blocks:[{index:0,suffix}]});
    patch(1,0,1,'b');patch(1,0,1,'b');
    const duplicate=items.get(1).blocks[0].text+items.get(1).revision+connects;
    patch(1,2,3,'c');const gap=epoch+'|'+connects;
    epoch='e';patch(2,0,1,'c');
    return [duplicate,gap,epoch+'|'+connects];
  })()`);
  assert.deepEqual(Array.from(result), ["ab10", "|1", "|2"]);
});

test("failed and aborted runs keep their outcomes", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const contents=value=>typeof value==='string'?value:value.textContent+value.children.map(contents).join('');
    const read={type:'tool',name:'read',args:{text:JSON.stringify({path:'Makefile'})},started:0,ended:100,state:{type:'done',error:false,result:{text:'line',images:[]}}};
    const bad={type:'tool',name:'bash',args:{text:JSON.stringify({command:'make verify STAGES=unit'})},started:1000,ended:41000,exit:101,state:{type:'done',error:true,result:{text:'FAIL unit 40.2s',images:[]}}};
    const failedItem={at:0,final:true,stop:'toolUse',blocks:[read,bad]};
    const failed=run(failedItem.blocks.map((block,index)=>({block,index,key:'f'+index,item:failedItem})));
    const thinking={type:'thinking',text:'the order in sweep()'};
    const edit={type:'tool',name:'edit',args:{text:JSON.stringify({path:'ko_server/src/sweep.rs',oldText:'',newText:''})},state:{type:'not_run'}};
    const abortedItem={at:0,final:true,stop:'aborted',blocks:[thinking,edit]};
    const aborted=run(abortedItem.blocks.map((block,index)=>({block,index,key:'a'+index,item:abortedItem})));
    return {failed:contents(failed.children[0]),output:contents(failed.children[1].children[1].children[1]),aborted:contents(aborted.children[0]),outcome:contents(aborted.children[1].children[1].children[0].children[2])};
  })()`);
  assert.match(result.failed, /read, bash41s/);
  assert.match(result.output, /FAIL unit 40.2s/);
  assert.doesNotMatch(result.output, /Command exited/);
  assert.match(result.aborted, /aborted, you pressed Escape/);
  assert.equal(result.outcome, "aborted ");
});

test('a pointer on the active picker trigger child keeps it open until the click toggles it', async () => {
  const app = await page();
  app.run("state.pi={type:'ready'};const trigger=element('model'),child=node('span','model');trigger.append(child);pickerButton=trigger;element('picker').hidden=false");
  app.listeners.get('pointerdown')?.({ target: app.elements.get('model')?.children[0] });
  assert.equal(app.elements.get('picker')?.hidden, false);
  app.elements.get('model')?.onclick?.();
  assert.equal(app.elements.get('picker')?.hidden, true);
});

test('notifications render as persistent coloured transcript lines', async () => {
  const app = await page();
  assert.equal(app.run("const item={seq:0,at:0,final:true,kind:'notify',level:'warning',text:{text:'Notice stays',cut:0}};const view=put(item);apply({...state,type:'state'});view.className==='note warning'&&view.children[0].textContent==='Notice stays'&&view.children[1].tagName==='TIME'&&views.get(0).view===view"), true);
});

test('consecutive job batches join without replacing the open line or earlier output', async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{const job={id:'j',name:'build',service:false,log:'/tmp/build.log'},batch=(seq,text)=>({seq,at:seq*60000,final:true,kind:'job',job,event:{type:'stream',batch:{text,cut:0},omitted:0,cut:false}});put(batch(0,'first'));const root=views.get(0).view.children[0],line=root.children[0];if(root.children[1].children.length)return false;line.onclick();const pre=root.children[1].children[0];put(batch(1,'second'));const stable=root.children[0]===line&&root.children[1].children[0]===pre&&root.classList.contains('open');put({seq:2,at:120000,final:true,kind:'job',job,event:{type:'ended',end:{type:'exit',code:1},tail:{text:'last tail',cut:0}}});return stable&&views.get(1).view.hidden&&views.get(2).view.hidden&&root.classList.contains('err')&&root.children[1].children.some(child=>child.className==='sep')})()`), true);
});

test('agent body changes render fresh final Markdown without a retained prose memo', async () => {
  const app = await page(), html: string[] = [];
  const create = app.context.document.createElement;
  app.context.document.createElement = tag => { const node = create(tag); if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) { html.push(value); } }); return node; };
  const result = app.run(`
    const card={direction:'out',to:{name:'worker'},text:{text:'**Review**',cut:0},call:{tool:'spawn',fork:false}};
    const slots=new Map();
    const view=agentCard(card,0,'agent:0',slots);
    const header=view.children[0];
    header.onclick({});
    const link=document.createElement('a'), label=document.createElement('strong'); link.append(label); header.append(link);
    header.onclick({target:label});
    const clicked=view.classList.contains('open');
    header.onkeydown({target:label,key:'Enter',preventDefault(){throw Error('Link Enter was intercepted');}});
    const entered=view.classList.contains('open');
    agentCard({...card,text:{text:'Use \`code\`',cut:0},outcome:{ok:false,failure:'refused',message:'No'}},0,'agent:0',slots);
    const fallback=put({seq:1,at:0,kind:'notice',final:true,customType:'other',from:'',text:'## **Ready**\\nSecond line'});
    [clicked,entered,texts.size,fallback.className,fallback.children[0].textContent,fallback.children[1].tagName];
  `);
  assert.match(html.join(''), /<strong>Review<\/strong>/);
  assert.match(html.join(''), /<code>code<\/code>/);
  assert.deepEqual(Array.from(result), [true, true, 0, 'note', 'Ready', 'TIME']);
});

test('agent cards split runs and toggle their one-line body without success metadata', async () => {
  const app = await page();
  assert.deepEqual(Array.from(app.run(`(()=>{const tool=name=>({type:'tool',id:name,name,args:{text:'{}'},state:{type:'done',error:false,result:{text:'',images:[]}}});const card={...tool('spawn_agent'),agent:{direction:'out',to:{name:'worker',session:'worker-id'},text:{text:'Check the module\\nReturn findings',cut:0},call:{tool:'spawn',fork:false},outcome:{ok:true}}};const view=put({seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[tool('read'),card,tool('bash')]});const agent=view.children.find(child=>child.classList.contains('aline'));if(!agent||view.children.length!==3)return [];const header=agent.children[0];const closed=!agent.classList.contains('open');header.onclick({});const open=agent.classList.contains('open');const expanded=header.getAttribute('aria-expanded');header.onclick({});return [closed,open,expanded,agent.classList.contains('open'),header.children.map(child=>child.className).join(),header.children[0].children[0],header.children[1].textContent,agent.children[1].className]})()`)), [true, true, 'true', false, 'lead,tx,', 'task to ', 'Check the module', 'bd prose']);
});

test('agent names link to live agents, a gone name is plain, a click focuses the pane and keeps the line closed', async () => {
  const app = await page();
  const names = Array.from(app.run(`(()=>{
    state={...state,agents:[{name:'worker',pane:'p7'}]};
    const card=name=>({direction:'out',to:{name},text:{text:'Hello',cut:0},call:{tool:'message',mode:'message'}});
    const live=agentCard(card('worker'),0,'a',new Map()), gone=agentCard(card('ghost'),0,'b',new Map());
    const link=live.children[0].children[0].children[1], ended=gone.children[0].children[0].children[1];
    window.testLink=link; window.testLine=live;
    return [link.tagName,link.className,link.href,link.title,link.textContent,ended.tagName,ended.className,ended.title,ended.textContent];
  })()`));
  assert.deepEqual(names, ['A', 'who', '#pane:worker', 'Focus the pane of @worker', '@worker', 'SPAN', 'who gone', 'ended', '@ghost']);
  const focused: string[] = [];
  const ko: { focus?: (pane: string) => void } = { focus: pane => { focused.push(pane); } }; app.context.window.ko = ko;
  let prevented = false;
  const target = app.run(`window.testLink`);
  app.run(`state={...state,agents:[{name:'worker',pane:'p7'}]}`);
  app.listeners.get('click')?.({ target, preventDefault() { prevented = true; } });
  assert.deepEqual(focused, ['p7']);
  assert.equal(prevented, true);
  assert.equal(app.run(`window.testLine.classList.contains('open')`), false);
  delete ko.focus;
  app.listeners.get('click')?.({ target, preventDefault() {} });
  assert.deepEqual(focused, ['p7']);
});

test('prose links only live agent names outside code and links, and a membership change re-renders agent lines', async () => {
  const app = await page(), html: string[] = [];
  const create = app.context.document.createElement;
  app.context.document.createElement = tag => { const node = create(tag); if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) { html.push(value); } }); return node; };
  app.run(`state={...state,agents:[{name:'sidebar',pane:'p1'},{name:'sidebar-right',pane:'p2'}]};prose(undefined,'Ask @sidebar-right and @sidebar, not @nobody or me@sidebar; \`@sidebar\` and [@sidebar](https://x.test)',true)`);
  const who = (name: string) => `<a class="who" href="#pane:${name}" title="Focus the pane of @${name}">@${name}</a>`;
  assert.equal(html.join(''), `<p>Ask ${who('sidebar-right')} and ${who('sidebar')}, not @nobody or me@sidebar; <code>@sidebar</code> and <a href="https://x.test">@sidebar</a></p>\n`);
  assert.deepEqual(Array.from(app.run(`(()=>{
    state={...state,agents:[{name:'sidebar',pane:'p1'}]};
    const slots=new Map(),view=agentCard({direction:'out',to:{name:'sidebar'},text:{text:'x',cut:0},call:{tool:'message',mode:'message'}},0,'k',slots);
    const before=view.children[0].children[0].children[1].className;
    views.set(0,{view,item:{},slots});
    apply({...state,type:'state',agents:[]});
    return [before,view.children[0].children[0].children[1].className]
  })()`)), ['who', 'who gone']);
});

test('agent card header phrases preserve kinds, directions, relations and failures', async () => {
  const app = await page();
  const ref = { name: 'worker', session: 'worker-id' }, text = { text: 'Body', cut: 0 };
  const outgoing = (call: object, outcome?: object) => ({ direction: 'out', to: ref, text, call, outcome });
  const incoming = (inbound: object) => ({ direction: 'in', from: ref, text, inbound });
  const cases: [object, string, boolean][] = [
    [outgoing({ tool: 'spawn', fork: false }), 'task to @worker', false],
    [outgoing({ tool: 'message', mode: 'message' }), 'message to @worker', false],
    [outgoing({ tool: 'message', mode: 'steer' }), 'steer to @worker', false],
    [outgoing({ tool: 'message', mode: 'interrupt-and-steer' }), 'interrupt to @worker', false],
    [incoming({ form: 'steer' }), 'steer from @worker', false],
    [incoming({ form: 'report' }), 'report from @worker', false],
    [incoming({ form: 'ended', reported: true }), 'ended from @worker', false],
    [incoming({ form: 'notice' }), 'notice from @worker', false],
    [incoming({ form: 'message', relation: 'child' }), 'message from @worker subagent', false],
    [incoming({ form: 'message', relation: 'descendant' }), 'message from @worker subagent', false],
    [incoming({ form: 'message', relation: 'parent' }), 'message from @worker parent', false],
    [incoming({ form: 'message', relation: 'sibling' }), 'message from @worker peer', false],
    [incoming({ form: 'message', relation: 'sibling_descendant' }), 'message from @worker peer', false],
    [incoming({ form: 'steer', relation: 'parent' }), 'steer from @worker parent', false],
    [incoming({ form: 'report', relation: 'child' }), 'report from @worker subagent', false],
    [incoming({ form: 'ended', reported: false, relation: 'child' }), 'not reported from @worker subagent', true],
    [outgoing({ tool: 'spawn', fork: false }, { ok: false, failure: 'error', message: 'Cannot start' }), 'refused to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'refused', message: 'Refused' }), 'refused to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'gone', message: 'Gone' }), 'gone to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'not_found', message: 'no agent named worker' }), 'no agent named worker to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'ambiguous', message: 'several agents named worker' }), 'several agents named worker to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'not_running', message: 'worker is not running' }), 'worker is not running to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'error', message: 'send failed' }), 'send failed to @worker', true],
  ];
  for (const [card, phrase, failed] of cases) {
    const result = app.run(`(()=>{const view=agentCard(${JSON.stringify(card)},0,'card',new Map());const header=view.children[0],lead=header.children[0];return {phrase:lead.children.map(child=>child.textContent??child).join(''),classes:header.children.map(child=>child.className),time:header.children.at(-1).tagName,view:view.className}})()`);
    assert.equal(result.phrase, phrase);
    assert.deepEqual(Array.from(result.classes), ['lead', 'tx', '']);
    assert.equal(result.view, failed ? 'aline err' : 'aline');
    assert.equal(result.time, 'TIME');
  }
});

test('step previews require exactly Shift-Command and a stationary press', async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{const urls=[];window.ko={preview:url=>urls.push(url)};const block={type:'tool',name:'read',args:{text:JSON.stringify({path:'file.txt'})},state:{type:'done',error:false,result:{text:'ok',images:[]}}};const item={seq:7,at:0,final:true,stop:'stop',blocks:[block]};const tree=run([{key:'7:2',index:2,item,block,slots:new Map()}]);const row=tree.children[1].children[0].children[0],label=row.children[1].children.find(node=>node?.classList?.contains('preview-file'));label.getBoundingClientRect=()=>({x:0,y:0,width:30,height:20});const event={button:0,clientX:2,clientY:3,shiftKey:true,metaKey:true,altKey:false,ctrlKey:false,preventDefault(){},stopPropagation(){}};label.onmousedown(event);label.onclick(event);for(const changes of [{shiftKey:false},{altKey:true},{ctrlKey:true}]){label.onmousedown({...event,...changes});label.onclick({...event,...changes})}label.onmousedown(event);label.onclick({...event,shiftKey:false,metaKey:false});if(urls.length!==2)return false;label.onmousedown(event);label.onclick({...event,clientX:5});return urls.length===2&&urls[0]==='/steps/7/2/file'})()`), true);
});

test('browser lightbox Escape closes before abort and keeps the draft', async () => {
  const app = await page();
  const requests: string[] = []; app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  assert.equal(app.run(`(()=>{state.pi={type:'ready'};state.working=true;editor.setText('draft');const target=node('button');preview('/images/0',target,'image',composerFocus);return document.body.children[0].className==='lightbox'})()`), true);
  let prevented = false;
  app.listeners.get('keydown')?.({ key: 'Escape', preventDefault() { prevented = true; }, stopPropagation() {} });
  assert.equal(prevented, true); assert.equal(app.context.document.body.children.length, 0); assert.equal(app.text(), 'draft');
  assert.deepEqual(requests.filter(path => ['/abort', '/queue/clear', '/clear_queue'].includes(path)), []);
  assert.equal(app.context.document.activeElement, app.prompt());
});

test('thumbnails call native preview with their resource and rectangle', async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{window.ko={preview:(url,rect)=>{window.lastPreview={url,rect}}};const images=thumbnails([{id:'0.0',revision:0,mimeType:'image/png',bytes:10}],new Map());images.load();const button=images.view.children[0];button.getBoundingClientRect=()=>({x:1,y:2,width:30,height:40});button.onclick();return window.lastPreview.url==='/images/0.0?e=&r=0'&&window.lastPreview.rect.width===30})()`), true);
});

test("user thumbnails reuse their image node and a failed image becomes non-interactive", async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{
    const find=root=>root.tagName==='IMG'?root:root.children.flatMap(child=>typeof child==='object'?[find(child)]:[]).find(Boolean);
    const item={seq:0,at:0,final:true,kind:'user',text:'Compare',attachments:[],images:[{id:'0.0',revision:0,mimeType:'image/png',bytes:10,width:1440,height:900}]};
    const first=find(put(item));
    if(!first)return false;
    const second=find(put({...item}));
    if(first!==second)return false;
    const changed=find(put({...item,images:[{...item.images[0],revision:1}]}));
    if(first!==changed||first.getAttribute('src')!=='/images/0.0?e=&r=1')return false;
    const thumb=first.parent;if(thumb.tagName!=='BUTTON'||thumb.type!=='button'||thumb.disabled)return false;
    first.onerror();return thumb.classList.contains('gone')&&thumb.attributes.get('role')==='img'&&thumb.disabled;
  })()`), true);
});

test("a tool creates its image only when its step first opens", async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{
    const count=root=>(root.tagName==='IMG'?1:0)+root.children.reduce((sum,child)=>sum+(typeof child==='object'?count(child):0),0);
    const block={type:'tool',id:'read',name:'read',args:{text:'{}',cut:0},state:{type:'done',error:false,result:{text:'Read image file [image/png]',cut:0,images:[{id:'0.0',revision:0,mimeType:'image/png',bytes:10,width:1440,height:900}]}}};
    const view=put({seq:0,at:0,final:true,kind:'assistant',stop:'toolUse',error:'',blocks:[block]});
    const run=views.get(0).slots.get('0:0').view.children[0];
    if(count(view)!==0)return false;
    run.children[0].onclick();if(count(view)!==0)return false;
    const step=run.children[1].children[0];step.children[0].onclick();
    if(count(view)!==1)return false;
    step.children[0].onclick();step.children[0].onclick();return count(view)===1;
  })()`), true);
});

test('C-g sends the draft to the editor route and focuses the float, and a refusal shows as a notice', async () => {
  const app = await page(), requests: { path: string; body: unknown }[] = [], focused: string[] = [];
  Object.assign(app.context, { focused });
  app.run("window.ko.focus = pane => { focused.push(pane); }");
  let refuse = false;
  app.context.fetch = async (path?: string, init?: { body: string }) => { requests.push({ path: path ?? '', body: JSON.parse(init?.body ?? '') }); return refuse ? { ok: false, json: async () => ({ error: 'C-g needs a ko pane' }) } : { ok: true, json: async () => ({ pane: 'pane_10' }) }; };
  app.run("state={...state,pi:{type:'ready'},sessionId:'s1'};editor.setText('draft')");
  app.handlers()?.edit();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, [{ path: '/editor/open', body: { sessionId: 's1', text: 'draft' } }]);
  assert.deepEqual(focused, ['pane_10']);
  refuse = true;
  app.handlers()?.edit();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(app.run("element('error').textContent"), 'C-g needs a ko pane');
});

test('while an editor is open the draft is read-only, sending and Escape do nothing and the status names the editor', async () => {
  const app = await page(), requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  const result = app.run(`
    state={...state,pi:{type:'ready'},working:true,sessionId:'s1',edit:{pane:'pane_10',editor:'nano'}};
    editor.setText('draft');refreshComposer();
    const open={status:element('status').textContent,send:canSend('draft')};
    [open,()=>{apply({type:'state',...state,edit:undefined})}];
  `);
  assert.equal(app.prompt()?.readOnly, true);
  assert.deepEqual(JSON.parse(JSON.stringify(result[0])), { status: 'Editing in nano…', send: false });
  app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, []);
  assert.equal(app.text(), 'draft');
  result[1]();
  assert.equal(app.prompt()?.readOnly, false);
});

test('the draft is locked from the first C-g until the editor request answers', async () => {
  const app = await page();
  let answer: (value: object) => void = () => {};
  app.context.fetch = async () => new Promise(resolve => { answer = value => resolve({ ok: true, json: async () => value }); });
  const result = app.run(`
    state={...state,pi:{type:'ready'},sessionId:'s1'};editor.setText('draft');
    openEditor();
    const locked={send:canSend('draft')};
    [locked,()=>state];
  `);
  assert.equal(app.prompt()?.readOnly, true);
  assert.equal(JSON.parse(JSON.stringify(result[0])).send, false, JSON.stringify(result[0]));
  answer({ pane: 'pane_10' });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(app.prompt()?.readOnly, false);
});

test('the end of an edit returns focus to the composer', async () => {
  const app = await page();
  const end = app.run(`
    state={...state,pi:{type:'ready'},sessionId:'s1',edit:{pane:'pane_10',editor:'nano'}};
    refreshComposer();document.activeElement=undefined;
    () => { apply({type:'state',...state,edit:undefined}); };
  `);
  assert.notEqual(app.context.document.activeElement, app.prompt());
  end();
  assert.equal(app.context.document.activeElement, app.prompt());
});
