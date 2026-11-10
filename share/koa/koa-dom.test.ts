import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { stripTypeScriptTypes } from "node:module";
import { markdown } from "./page/markdown.ts";
import { nameCommand } from "./prompt.ts";
import { ATTACHMENT_LIMITS } from "./records.ts";
import type { PromptMode } from "./records.ts";

async function page() {
  const source = stripTypeScriptTypes(await readFile(new URL("page/page.ts", import.meta.url), "utf8"));
  class Node {
    value = ""; private text = ""; className = ""; style = {}; disabled = false; placeholder = ""; scrollHeight = 20; children: Node[] = []; dataset = {};
    get textContent() { return this.text; }
    set textContent(value: unknown) { this.text = String(value); }
    private classes = new Set<string>();
    classList = { toggle: (name: string, force = !this.classes.has(name)) => { if (force) this.classes.add(name); else this.classes.delete(name); }, remove: (name: string) => { this.classes.delete(name); }, add: (name: string) => { this.classes.add(name); }, contains: (name: string) => this.classes.has(name) };
    parent?: Node;
    inert = false;
    contains(node: Node | undefined): boolean { return !!node && (node === this || this.contains(node.parent)); }
    append(...children: Node[]) { children.forEach(child => { if (child instanceof Node) child.parent = this; }); this.children.push(...children); }
    prepend(...children: Node[]) { children.forEach(child => { if (child instanceof Node) child.parent = this; }); this.children.unshift(...children); }
    before(...children: Node[]) { this.append(...children); }
    remove() { if (this.contains(document.activeElement)) document.activeElement = undefined; if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = undefined; }
    replaceChildren(...children: Node[]) { this.children.forEach(child => { if (child instanceof Node) child.parent = undefined; }); this.children = []; this.append(...children); }
    content = { childNodes: [] };
    tagName = 'DIV'; isContentEditable = false; selectionStart = 0; selectionEnd = 0; hidden = true;
    oninput?: () => void;
    onclick?: () => void;
    onkeydown?: (event: unknown) => void;
    attributes = new Map<string, string>();
    setAttribute(name: string, value: string) { this.attributes.set(name, value); } getAttribute(name: string) { return this.attributes.get(name) ?? null; } removeAttribute(name: string) { this.attributes.delete(name); } focus() { for (let node: Node | undefined = this; node; node = node.parent) if (node.inert) return; document.activeElement = this; } setSelectionRange() {} addEventListener() {} scrollIntoView() {} getBoundingClientRect() { return { left: 0 }; }
    closest(selector: string) { return ['INPUT', 'TEXTAREA', 'SELECT', ...(selector.includes('button') ? ['BUTTON'] : [])].includes(this.tagName) || (this.attributes.has('role') && selector.includes(`[role=${this.attributes.get('role')}]`)) ? this : null; }
    setRangeText(text: string) { this.value = this.value.slice(0, this.selectionStart) + text + this.value.slice(this.selectionEnd); }
    dispatchEvent() { this.oninput?.(); }
    querySelector() { return undefined; }
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
  const document = { hasFocus: () => true, get activeElement() { return activeElement; }, set activeElement(node: Node | undefined) { activeElement = node; }, querySelector: () => null, getElementById(id: string) { let node = elements.get(id); if (!node) { node = new Node(); elements.set(id, node); if (id === 'prompt') document.getElementById('field').append(node); } return node; }, createElement: (tag: string) => { const node = new Node(); node.tagName = tag.toUpperCase(); return node; }, createElementNS: () => new Node(), createTextNode: (text: string) => { const node = new Node(); node.tagName = '#text'; node.textContent = text; return node; }, addEventListener(type: string, handler: (event: unknown) => void) { listeners.set(type, handler); }, querySelectorAll: () => [] };
  type Handlers = { input(user: boolean): void; send(mode: PromptMode): void; quit(): void };
  let handlers: Handlers | undefined;
  let text = () => '';
  let prompt: Node | undefined;
  const composer = (host: Node, callbacks: Handlers) => {
    handlers = callbacks;
    const content = host.children[0] ?? new Node(); content.isContentEditable = true; if (!host.children.length) host.append(content);
    prompt = content;
    text = () => content.value;
    return {
      text,
      empty: () => content.value.length === 0,
      setText(text: string) { content.value = text; content.selectionStart = content.selectionEnd = text.length; callbacks.input(false); },
      insert(text: string) { content.setRangeText(text); callbacks.input(true); },
      focus: () => content.focus(),
      hasFocus: () => document.activeElement === content,
      placeholder(text: string) { content.placeholder = text; },
    };
  };
  const context = { composer, nameCommand, ATTACHMENT_LIMITS, AbortController, AbortSignal, CustomEvent: class { type: string; detail?: unknown; constructor(type: string, options?: { detail?: unknown }) { this.type = type; this.detail = options?.detail; } }, Node, Element: Node, HTMLElement: Node, HTMLButtonElement: Node, HTMLImageElement: Node, markdown, document, window: { ko: {}, addEventListener(type: string, handler: (event?: unknown) => void) { windowListeners.set(type, handler); } }, innerWidth: 980, Event: class { type: string; constructor(type: string) { this.type = type; } }, console, setInterval() {}, clearInterval() {}, setTimeout, clearTimeout, requestAnimationFrame() {}, fetch: async () => ({ ok: true, json: async () => ({}) }) };
  const attachSource = stripTypeScriptTypes(await readFile(new URL('page/attach.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const httpSource = stripTypeScriptTypes(await readFile(new URL('page/http.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, { fetchJSON: runInNewContext(httpSource + '\nfetchJSON', context), attach: runInNewContext(attachSource + '\nattach', context) });
  return { context, elements, listeners, windowListeners, handlers: () => handlers, prompt: () => prompt, text: () => text(), run: (code: string) => runInNewContext("{\n" + source.replace(/^import .*;\n/gm, "").replace(/^setInterval\([\s\S]*$/m, "") + "\n" + code + "\n}", context) };
}

test('/name keeps draft attachments for the next prompt', async () => {
  const app = await page(), requests: { text: string; attachments: string[] }[] = [];
  app.context.fetch = async (path?: string, options?: { body?: string }) => { assert.equal(path, '/prompt'); requests.push(JSON.parse(options?.body ?? '{}')); return { ok: true, json: async () => ({ disposition: 'handled' }) }; };
  app.run("state={...state,pi:{type:'ready'}};draft.restore([{id:'file',name:'note.txt',path:'/tmp/note.txt',origin:'path',kind:'file',size:4}]);editor.setText('/name saved')");
  app.handlers()?.send('prompt'); await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(app.elements.get('attachments')?.children.length, 2); assert.equal(app.text(), '');
  const prompt = app.prompt(); assert.ok(prompt); prompt.value = 'Review';
  app.handlers()?.send('prompt'); await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests.map(request => [request.text, request.attachments]), [['/name saved', []], ['Review', ['file']]]);
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

test("native path drops validate all paths, refuse folders and delete removed chips", async () => {
  const app = await page();
  Object.assign(app.context.window.ko, { local: true });
  let expire: () => void = () => assert.fail('The folder notice needs an expiry');
  Object.assign(app.context, { setTimeout(callback: () => void, delay: number) { assert.equal(delay, 4000); expire = callback; return 1; }, clearTimeout() {} });
  const requests: string[] = [];
  app.context.fetch = async (path?: string, options?: { body?: unknown }) => {
    requests.push(path ?? '');
    if (path === '/attachments') { const value = JSON.parse(String(options?.body)); assert.ok(['/tmp/one.txt', '/tmp/two.txt'].includes(value.path)); return { ok: true, json: async () => ({ id: value.path.endsWith('one.txt') ? 'one' : 'two', path: value.path, origin: 'path', name: value.path.slice(5), kind: 'file', size: 4 }) }; }
    assert.equal(path, '/attachments/one/delete'); return { ok: true, json: async () => ({}) };
  };
  app.run("state={...state,pi:{type:'ready'}};refreshComposer();editor.setText('draft')");
  const drop = (detail: unknown) => app.windowListeners.get('ko-drop')?.(new app.context.CustomEvent('ko-drop', { detail }));
  for (const files of [['relative'], ['/tmp/bad\nname'], Array(17).fill('/tmp/one.txt')]) drop({ files, refused: false });
  assert.equal(requests.length, 0);
  drop({ files: ['/tmp/one.txt', '/tmp/two.txt'], refused: true });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(requests.length, 2);
  const host = app.elements.get('attachments'); assert.ok(host);
  assert.equal(host.children.length, 3);
  const notice = host.lastChild; assert.ok(notice);
  assert.equal(notice.textContent, 'Folders are not attached'); assert.equal(notice.hidden, false);
  expire(); assert.equal(notice.hidden, true);
  drop({ files: [], refused: true }); assert.equal(notice.hidden, false);
  let prevented = false;
  app.listeners.get('drop')?.({ dataTransfer: { files: [new File(['x'], 'ignored.txt')], items: [] }, preventDefault() { prevented = true; } });
  assert.equal(prevented, true); assert.equal(requests.length, 2); assert.equal(notice.hidden, false);
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

test("working hint shares the status clock and keeps its spinner across ticks", async () => {
  const app = await page();
  assert.equal(app.run("Date.now=()=>12000;state={...state,pi:{type:'ready'},working:true,since:0};status();refreshComposer();const spinner=element('hint').firstElementChild;const clockMatches=element('hint').children[1].textContent===element('status').textContent+' · '&&element('hint').children[2].textContent==='⎋'&&element('hint').children[3].textContent===' abort';Date.now=()=>25000;composerHint(status());clockMatches&&element('status').textContent==='working 25s'&&element('hint').children[1].textContent==='working 25s · '&&element('hint').firstElementChild===spinner&&spinner.className==='spin'"), true);
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
  key({ key: 'Tab' });
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
  assert.equal(app.windowListeners.has('blur'), false);
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
    const context = { metrics: undefined, epoch: "", after: -1, delay: 200, disconnected: false, EventSource, console, window: { addEventListener(name: string, handler: (event?: { persisted: boolean }) => void) { if (name === "pagehide") teardown = handler; else if (name === "pageshow") restore = handler; } }, apply(record: { type: string; epoch?: string; after?: number }) {
      if (record.type === "bad") throw Error("Apply failed");
      received.push(record);
      if (record.epoch) context.epoch = record.epoch;
      if (record.after !== undefined) context.after = record.after;
    }, element: () => ({}), followBottom() {}, setTimeout(callback: () => void) { retries.push(callback); }, clearTimeout() {} };
    runInNewContext(connect + ";connect()", context);
    sources[0].onopen?.();
    sources[0].onmessage?.({ data: '{"type":"state","epoch":"new","after":3}' });
    assert.equal(received.length, 1, name);
    sources[0].onerror?.();
    assert.equal(sources[0].closed, true);
    retry();
    assert.equal(sources[1].url, "/events?epoch=new&after=3");
    sources[1].onmessage?.({ data: '{"type":"bad"}' });
    assert.equal(sources[1].closed, true);
    retry();
    assert.equal(sources[2].url, "/events?epoch=new&after=3");
    sources[2].onmessage?.({ data: 'not JSON' });
    assert.equal(sources[2].closed, true);
    teardown();
    retry();
    assert.equal(sources.length, 3);
    restore({ persisted: false });
    assert.equal(sources.length, 3);
    restore({ persisted: true });
    assert.equal(sources.length, 4);
    assert.equal(sources[3].url, "/events?epoch=new&after=3");
    restore({ persisted: true });
    assert.equal(sources.length, 4);
    teardown();
    assert.equal(sources[3].closed, true);
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
    runInNewContext(connect + ";connect()", { metrics, EventSource, window: { addEventListener() {} }, epoch: "", after: -1, delay: 200, console, element: () => ({}), followBottom() {}, performance: { timeOrigin: 1000, now: () => 12 }, Date: { now: () => 1012 }, sendMetrics() {}, setTimeout() {}, requestAnimationFrame(callback: () => void) { frames++; callback(); } });
    await Promise.resolve();
    assert.equal(frames, mode === "frame" ? 1 : 0);
    assert.deepEqual(JSON.parse(JSON.stringify(metrics.samples)), [{ t: 1000, [mode]: 1012, bytes: 1234, clockError: 0 }]);
  }
});

test("finished prose and view change checks retain no extra text strings", async () => {
  const app = await page();
  const retained = app.run("const text='payload '.repeat(10000);put({seq:0,kind:'assistant',final:true,blocks:[{type:'text',text}]});({source:texts.get('0:0').source,signature:views.get(0).signature})");
  assert.deepEqual({ source: retained.source?.length ?? 0, signature: retained.signature?.length ?? 0 }, { source: 0, signature: 0 });
  assert.equal(app.run("const initial={seq:1,kind:'assistant',final:false,blocks:[{type:'text',text:'first'}]};put(initial);apply({type:'patch',seq:1,final:false,blocks:[{index:0,suffix:' last'}]});const updated=items.get(1),streaming=texts.get('1:0').source==='first last';apply({type:'patch',seq:1,final:true,blocks:[]});initial!==updated&&initial.blocks!==updated.blocks&&initial.blocks[0]!==updated.blocks[0]&&initial.blocks[0].text==='first'&&streaming&&texts.get('1:0').source===undefined&&views.get(1).item===items.get(1)"), true);
  assert.equal(app.run("const finished={seq:0,kind:'assistant',final:true,blocks:[{type:'text',text:'same'}]};put(finished);const proseView=texts.get('0:0').view;put({...finished,blocks:[{type:'text',text:'same'}]});apply({type:'patch',seq:0,final:true,stop:'stop',ended:42,blocks:[]});texts.get('0:0').view===proseView&&items.get(0).stop==='stop'&&items.get(0).ended===42"), true);
});

test("a run joins adjacent assistant items without replacing their text views", async () => {
  const app = await page();
  assert.equal(app.run("const firstSlot=node('div'),secondSlot=node('div');items.set(0,{seq:0,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'thinking',text:'check'}]});items.set(1,{seq:1,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'tool',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'ok',images:[]}}}]});views.set(0,{slots:new Map([['0:0',firstSlot]])});views.set(1,{slots:new Map([['1:0',secondSlot]])});run=steps=>({count:steps.length});reconcileRuns(1);firstSlot.children[0].count===2&&secondSlot.children.length===0"), true);
});

test("invalid tool arguments do not stop rendering", async () => {
  const app = await page();
  for (const text of ["null", '{"path":"file","oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":"old","newText":"new"}']) {
    assert.doesNotThrow(() => app.run(`run([{key:'0:0',index:0,item:{final:true,stop:'stop',blocks:[]},block:{type:'tool',name:'edit',args:{text:${JSON.stringify(text)}},state:{type:'done',error:false,result:{text:'done',images:[]}}}}])`));
  }
});

test("a running tool takes priority over a later pending step", async () => {
  const app = await page();
  assert.equal(app.run("const item={final:false,stop:'',blocks:[]};const steps=['running','pending'].map((type,index)=>({key:'0:'+index,index,item,block:{type:'tool',name:'bash',args:{text:JSON.stringify({command:type+' command'})},state:{type}}}));run(steps).children[0].children[1].children.some(child=>child?.textContent==='running command')"), true);
});

test("ended thinking is not active while assistant text streams", async () => {
  const app = await page();
  assert.equal(app.run("const block={type:'thinking',text:'done',started:1,ended:2};const item={final:false,blocks:[block,{type:'text',text:'streaming'}]};run([{block,item,index:0,key:'0:0'}]).children[0].children[1].children.some(child=>child?.className==='spin')"), false);
});

test("model picker matches provider and id", async () => {
  const app = await page();
  const selected: object[] = [];
  app.context.fetch = async (_path?: string, options?: {body?: string}) => { if (options?.body) selected.push(JSON.parse(options.body)); return {ok:true,json:async()=>({models:[{id:'same',provider:'one'},{id:'same',provider:'two'}]})}; };
  const result = await app.run("state={...state,pi:{type:'ready'},model:{id:'same',provider:'two'}};picker('model').then(()=>{const host=element('picker');const ticks=host.children.filter(child=>child.className==='row').map(row=>row.children[0].textContent).join(',');host.onkeydown({key:'Enter',preventDefault(){},stopPropagation(){}});return ticks})");
  assert.equal(result, ',✓');
  assert.deepEqual(selected, [{provider:'two',modelId:'same'}]);
});

test("stop and Escape take back queued work before aborting", { timeout: 1000 }, async () => {
  for (const trigger of ["button", "Escape"]) {
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
    const result = app.run("state={...state,working:true,dialogs:[],queue:{steering:[{text:'first queued',attachments:[]}],followUp:[{text:'second queued',attachments:[]}]}};" + (trigger === "button" ? "element('send').onclick()" : "undefined"));
    if (trigger === "Escape") app.listeners.get("keydown")?.({ key: "Escape", preventDefault() {} });
    await done; await result;
    assert.deepEqual(commands, ["clear_queue", "abort"], trigger);
    assert.deepEqual(started, [], trigger);
    assert.equal(app.text(), "first queued\n\nsecond queued", trigger);
  }
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
  assert.equal(app.run("status=()=>{};apply({type:'state',pi:{type:'starting'},dialogs:[{id:'trust',method:'select',title:'Trust project?',options:['Yes','No']}],queue:{steering:[],followUp:[]}});element('composer').hidden===false&&element('field').inert&&element('send').disabled&&element('dialogs').children[0].className==='dialog'"), true);
});

test("a state record preserves a typed dialog answer", async () => {
  const app = await page();
  assert.equal(app.run("state={...state,working:true,dialogs:[{id:'a',method:'input',title:'Question'}]};refreshComposer();dialogs();const form=element('dialogs').children[0];const input=form.children[1];input.value='typed';state={...state,dialogs:[{id:'a',method:'input',title:'Question'}]};dialogs();apply({type:'reset',epoch:'next',more:false,items:[]});element('dialogs').children[0]===form&&input.value==='typed'&&element('prompt').children[0].placeholder==='Message koa…'&&element('send').disabled"), true);
});

test("unchanged state keeps queue controls and status nodes and acknowledges editor once", async () => {
  const app = await page();
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return {ok:true,json:async()=>({})}; };
  assert.equal(app.run("status=()=>{};dialogs=()=>{};exited=()=>{};const record={...state,type:'state',pi:{type:'starting'},queue:{steering:[{text:'queued',attachments:[]}],followUp:[]},statuses:{tests:'ok'},editor:{id:'one',text:'draft'}};apply(record);const deferred=editorId===undefined;record.pi={type:'ready'};apply(record);const back=element('queue').children.at(-1).children.at(-1);apply({...record});deferred&&back===element('queue').children.at(-1).children.at(-1)&&element('notice').children.length===1"), true);
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

test("a patch before an older-items reply is replayed after that reply", async () => {
  const app = await page();
  let release: (value: { ok: boolean; json: () => Promise<object> }) => void = () => {};
  app.context.fetch = () => new Promise(resolve => { release = resolve; });
  const result = app.run("put=item=>items.set(item.seq,item);epoch='e';first=4;more=true;const loading=older();apply({type:'patch',seq:3,final:false,blocks:[{index:0,suffix:' new'}]});loading.then(()=>items.get(3).blocks[0].text)");
  release({ ok: true, json: async () => ({ epoch: "e", more: false, items: [{ seq: 3, kind: "assistant", final: false, blocks: [{ type: "text", text: "old" }] }] }) });
  assert.equal(await result, "old new");
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
    const run=views.get(0).slots.get('0:0').children[0];
    if(count(view)!==0)return false;
    run.children[0].onclick();if(count(view)!==0)return false;
    const step=run.children[1].children[0];step.children[0].onclick();
    if(count(view)!==1)return false;
    step.children[0].onclick();step.children[0].onclick();return count(view)===1;
  })()`), true);
});
