import assert from "node:assert/strict";
import { followMonitor, type FollowSample } from './testdata/follow-monitor.ts';
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';
import { sessionEntryToContextMessages } from '@earendil-works/pi-coding-agent';
import { transcript } from './koa-transcript.ts';
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { stripTypeScriptTypes } from "node:module";
import { markdown, markdownPlain } from "./page/markdown.ts";
import { markdownLine } from "./markdown-line.ts";
import { bashCommand } from "./prompt.ts";
import { answer, current } from "./page/answers.ts";
import { feedbackFixture, settle, shellReply } from "./testdata/completion-fixture.ts";
import { pathToken } from './path-token.ts';
import { promptHistory } from './page/history.ts';
import { ATTACHMENT_LIMITS, pathArg } from "./koa-records.ts";
import { topicTurn } from './topic-turn.ts';
import { realFixture } from './koa-program-fixture.ts';
import { ofType } from './koa-agent-fixture.ts';
import { jobEndText, parseTopicName } from "./records.ts";
import type { PromptMode } from "./koa-records.ts";
import { scrollInitial, scrollMemory, scrollStored, reduce, place, scrollWindow } from "./page/scroll.ts";

async function pageMarkup() {
  const html = await readFile(new URL('page/page.html', import.meta.url), 'utf8');
  type Element = { tag: string; id: string; classes: string[]; children: Element[] };
  const root: Element = { tag: '', id: '', classes: [], children: [] };
  const stack = [root];
  const elements: Element[] = [];
  for (const token of html.matchAll(/<\/?([a-z][\w-]*)\b([^>]*)>/gi)) {
    if (token[0].startsWith('</')) { stack.pop(); continue; }
    const node: Element = { tag: token[1], id: token[2].match(/\bid="([^"]*)"/)?.[1] ?? '', classes: (token[2].match(/\bclass="([^"]*)"/)?.[1] ?? '').split(/\s+/), children: [] };
    const parent = stack.at(-1);
    assert.ok(parent);
    parent.children.push(node);
    elements.push(node);
    if (!['meta', 'link', 'img', 'input', 'br', 'hr'].includes(node.tag)) stack.push(node);
  }
  return { root, elements };
}

test('composer puts queue before attachments and field; footer contains its three facts and no legacy controls', async () => {
  const { elements } = await pageMarkup();
  const composer = elements.find(node => node.id === 'composer');
  assert.ok(composer);
  assert.deepEqual(composer.children.map(node => node.id), ['queue', 'attachments', 'field', 'error']);
  const foot = elements.find(node => node.classes.includes('foot'));
  assert.ok(foot);
  assert.deepEqual(foot.children.filter(node => node.classes.includes('cell')).map(node => node.id || node.classes[0]), ['model-cell', 'ctxc', 'cwd']);
  const model = elements.find(node => node.id === 'model-cell');
  assert.ok(model);
  assert.deepEqual(model.children.map(node => node.id), ['model', 'thinking']);
  assert.equal(elements.some(node => ['send', 'notice'].includes(node.id) || node.tag === 'footer' && node.classes.includes('status')), false);
});

test('completion variants retain selection and suppress empty/pending menus', async t => {
  const f = await feedbackFixture(t, true);
  f.key('Tab');
  t.mock.timers.tick(150);
  assert.equal(f.layer?.querySelector('.koa-complete > ul'), undefined);
  assert.equal(f.widgets().length, 1);
  f.key('Escape');
  f.replies[0](shellReply([{ label: 'late', insert: 'late' }]));
  await settle();
  assert.deepEqual(f.widgets(), []);
  assert.equal(f.layer?.querySelector('.koa-complete > ul'), undefined);
  assert.equal(f.state().doc.toString(), '!ls');
  f.key('Tab');
  f.replies[1]({ ...shellReply([{ label: 'one', insert: 'one' }, { label: 'two', insert: 'two' }]), more: 37 });
  await settle();
  t.mock.timers.tick(50);
  await settle();
  const list = f.layer?.querySelector('.koa-complete > ul');
  assert.ok(list);
  assert.equal(list.children.at(-1)?.textContent, '… 37 more, type to narrow');
  f.key('ArrowDown');
  assert.equal(f.selected(), 'two');
  const selected = list.children.find(row => row.hasAttribute('aria-selected'));
  assert.ok(selected);
  f.dispatch({});
  assert.equal(f.selected(), 'two');
  assert.equal(list.children.find(row => row.hasAttribute('aria-selected')), selected);
  f.dispatch({ changes: { from: 0, to: 3, insert: 'read @fi tail' }, selection: { anchor: 8 } });
  f.start();
  t.mock.timers.tick(50);
  f.replies[2]({ type: 'prompt', from: 5, to: 8, options: [{ kind: 'file', label: 'file.ts', insert: '@file.ts ', cursor: 9 }] });
  await settle();
  assert.equal(f.selected(), 'file.ts');
  f.key('Tab');
  assert.equal(f.state().doc.toString(), 'read @file.ts  tail');
  assert.equal(f.state().selection.main.head, 14);
  f.dispatch({ changes: { from: 0, to: f.state().doc.length, insert: '@missing' }, selection: { anchor: 8 } });
  f.start();
  t.mock.timers.tick(50);
  f.replies[3]({ type: 'prompt', from: 0, to: 8, options: [] });
  await settle();
  assert.equal(f.layer?.querySelector('.koa-complete > ul'), undefined);
});

test('question answers replace quotes and preserve selected options', async () => {
  const app = await page();
  const question = '😀 Pick one or two?';
  let draft = answer('', question, 'one', false);
  draft = answer(draft, 'Push now?', 'No', false);
  draft = answer(draft, question, 'two', false);
  assert.equal(draft, '> 😀 Pick one or two?\ntwo\n\n> Push now?\nNo');
  assert.equal(current(draft, question), 'two');
  assert.equal(answer(draft, question, '', false), draft);
  assert.equal(answer(draft, question, '', true), '> 😀 Pick one or two?\n\n\n> Push now?\nNo');
  const options = ['one', 'two'].map(value => {
    const node = app.context.document.createElement('span');
    Object.assign(node.dataset, { quote: question, answer: value }); return node;
  });
  app.context.document.querySelectorAll = () => options;
  Reflect.get(app.context, 'update')(draft);
  assert.deepEqual(options.map(node => node.classList.contains('sel')), [false, true]);
  Reflect.get(app.context, 'update')(answer(draft, 'Push now?', 'Yes', false));
  assert.deepEqual(options.map(node => node.classList.contains('sel')), [false, true]);
});

test('footer states retain facts and page order', async () => {
  const app = await page(), evaluate = app.repl(), { elements } = await pageMarkup();
  const markup = elements.find(node => node.classes.includes('foot'));
  assert.ok(markup);
  const mount = (source: typeof markup): InstanceType<typeof app.context.Node> => {
    const node = source.id ? app.context.document.getElementById(source.id) : app.context.document.createElement(source.tag);
    Object.assign(node, { id: source.id });
    node.className = source.classes.join(' ');
    node.replaceChildren(...source.children.map(mount));
    return node;
  };
  const foot = mount(markup);
  app.context.document.getElementById('field').append(foot);
  evaluate("window.footerState={...state,life:{type:'ready'},model:{provider:'anthropic',id:'claude-opus-5-5'},thinking:'high',context:{tokens:88000,window:200000,percent:44},home:'/home/test',cwd:'/home/test/project'}");
  for (const change of ["working:false", "working:true", "edit:{editor:'vim'}", "compaction:'running'"]) {
    evaluate('state={...window.footerState,' + change + '};refreshComposer()');
    assert.deepEqual(foot.children.filter(node => node.classList.contains('cell')).map(node => Reflect.get(node, 'id') || node.className.split(' ')[0]), ['model-cell', 'ctxc', 'cwd']);
    assert.deepEqual(['model-name', 'thinking', 'tokens', 'percent'].map(id => app.elements.get(id)?.textContent), ['claude-opus-5-5', '· high', '88k / 200k', '44%']);
    assert.deepEqual(app.elements.get('cwd')?.children.map(node => node.textContent), ['~/', 'project']);
  }
});

test('attachment queue restores chips and separates sent paths', async () => {
  const app = await page(), evaluate = app.repl(), requests: { path: string; body: unknown }[] = [];
  const file = { id: 'note', name: 'notes.md', path: '/tmp/uploads/notes.md', kind: 'file', size: 12 };
  app.context.fetch = async (path = '', options?: { body?: string }) => {
    requests.push({ path, body: options?.body ? JSON.parse(options.body) : undefined });
    return { ok: true, json: async () => path === '/queue/clear' ? { steering: [{ text: 'Review', attachments: [file] }], followUp: [] } : { disposition: 'started' } };
  };
  evaluate('state={...state,sessionId:"s",life:{type:"ready"},queue:{steering:[{text:"Review",attachments:[' + JSON.stringify(file) + ']}],followUp:[],classifying:[]}};refreshComposer();queue()');
  assert.equal(evaluate("element('queue').children[0].querySelector('.att').children.at(-1).textContent"), '1');
  await evaluate('takeBack()');
  assert.equal(app.text(), 'Review');
  assert.equal(evaluate("draft.count"), 1);
  assert.equal(evaluate("element('attachments').querySelector('.attach-name').textContent"), 'notes.md');
  await evaluate('send()');
  assert.deepEqual(requests.at(-1), { path: '/prompt', body: { sessionId: 's', text: 'Review', mode: 'prompt', attachments: ['note'] } });
  assert.equal(evaluate('draft.count'), 0);
  evaluate('put({kind:"user",seq:0,at:1,revision:0,final:true,text:"Review",images:[],attachments:[' + JSON.stringify(file) + ']})');
  assert.equal(evaluate("views.get(0).view.querySelector('.attach-chip')===undefined"), true);
  assert.equal(evaluate("views.get(0).view.querySelector('.paths').textContent"), '/tmp/uploads/notes.md');
});

const pageSources = new Map<string, string>();
function pageSource(name: string): string {
  let source = pageSources.get(name);
  if (source === undefined) {
    source = stripTypeScriptTypes(readFileSync(new URL(name, import.meta.url), 'utf8'));
    pageSources.set(name, source);
  }
  return source;
}

async function page() {
  const source = pageSource('page/page.ts');
  class Node {
    value = ""; private text = ""; style: Record<string, unknown> = { setProperty: (name: string, value: string) => { this.style[name] = value; }, getPropertyValue: (name: string) => this.style[name] ?? '', removeProperty: (name: string) => { delete this.style[name]; } }; innerHTML = ''; clientWidth = 320; scrollTop = 0; scrollWidth = 0; clientHeight = 100; offsetHeight = 20; disabled = false; placeholder = ""; scrollHeight = 20; children: Node[] = []; dataset = {}; rects: { top: number; bottom: number }[] = [];
    get textContent() { return this.text; }
    set textContent(value: unknown) { this.text = String(value); this.children = []; }
    private classes = new Set<string>();
    get className() { return [...this.classes].join(' '); }
    set className(value: string) { this.classes = new Set(value.split(/\s+/).filter(Boolean)); }
    classList = { toggle: (name: string, force = !this.classes.has(name)) => { if (force) this.classes.add(name); else this.classes.delete(name); }, remove: (name: string) => { this.classes.delete(name); }, add: (name: string) => { this.classes.add(name); }, contains: (name: string) => this.classes.has(name) };
    parent?: Node;
    get parentElement() { return this.parent; }
    inert = false;
    contains(node: Node | undefined): boolean { return !!node && (node === this || this.contains(node.parent)); }
    append(...children: Node[]) { children.forEach(child => { if (child instanceof Node) { child.remove(); child.parent = this; } }); this.children.push(...children); }
    prepend(...children: Node[]) { children.forEach(child => { if (child instanceof Node) { child.remove(); child.parent = this; } }); this.children.unshift(...children); }
    before(...children: Node[]) { const parent = this.parent; if (!parent) return; children.forEach(child => { if (child instanceof Node) { child.remove(); child.parent = parent; } }); parent.children.splice(parent.children.indexOf(this), 0, ...children); }
    remove() { if (this.contains(document.activeElement)) document.activeElement = undefined; if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = undefined; }
    select() { this.selectionStart = 0; this.selectionEnd = this.value.length; }
    replaceWith(next: Node) { this.before(next); this.remove(); }
    replaceChildren(...children: Node[]) { this.children.forEach(child => { if (child instanceof Node) child.parent = undefined; }); this.children = []; this.append(...children); }
    content: { childNodes: Node[]; querySelectorAll(): Node[] } = { childNodes: [], querySelectorAll: () => [] };
    tagName = 'DIV'; isContentEditable = false; readOnly = false; selectionStart = 0; selectionEnd = 0; hidden = true;
    oninput?: () => void;
    onscroll?: () => void;
    onclick?: () => void;
    onkeydown?: (event: unknown) => void;
    animations: { currentTime: number; playState: string; pause(): void }[] = [];
    getAnimations() { return this.animations; }
    shadowRoot?: Node;
    attachShadow() { return this.shadowRoot = new Node(); }
    cloneNode(deep = false): Node {
      const clone = new Node(); clone.tagName = this.tagName; clone.hidden = this.hidden; clone.textContent = this.textContent;
      clone.attributes = new Map(this.attributes); clone.classes = new Set(this.classes); clone.dataset = { ...this.dataset };
      clone.animations = this.animations.map(() => ({ currentTime: 0, playState: 'running', pause() { this.playState = 'paused'; } }));
      if (deep) clone.append(...this.childNodes.map(child => child.cloneNode(true)));
      return clone;
    }
    attributes = new Map<string, string>();
    setAttribute(name: string, value: string) { this.attributes.set(name, value); } getAttribute(name: string) { return this.attributes.get(name) ?? null; } removeAttribute(name: string) { this.attributes.delete(name); } focus() { for (let node: Node | undefined = this; node; node = node.parent) if (node.inert) return; document.activeElement = this; } setSelectionRange() {} handlers = new Map<string, (event?: unknown) => void>(); addEventListener(type: string, handler: (event?: unknown) => void) { this.handlers.set(type, handler); } scrollIntoView() {} getBoundingClientRect(): { left?: number; top: number; bottom?: number; height?: number; width?: number } { return { left: 0, top: this.offsetTop, bottom: this.offsetTop + this.offsetHeight, height: this.offsetHeight, width: this.classes.has('topic-capsule') || this.classes.has('topic-open') ? this.clientWidth : undefined }; } getClientRects() { return this.rects; }
    closest(selector: string): Node | null { if (selector === 'a') return this.tagName === 'A' ? this : this.parent?.closest(selector) ?? null; return ['INPUT', 'TEXTAREA', 'SELECT', ...(selector.includes('button') ? ['BUTTON'] : [])].includes(this.tagName) || (this.attributes.has('role') && selector.includes(`[role=${this.attributes.get('role')}]`)) ? this : null; }
    setRangeText(text: string) { this.value = this.value.slice(0, this.selectionStart) + text + this.value.slice(this.selectionEnd); }
    dispatchEvent() { this.oninput?.(); }
    querySelector(selector: string): Node | undefined { const match = selector.match(/^\.([\w-]+)(?::not\(\.([\w-]+)\))?$/); if (!match) return undefined; const find = (node: Node): Node | undefined => { for (const child of node.children) { if (!(child instanceof Node)) continue; if (child.classes.has(match[1]) && !(match[2] && child.classes.has(match[2]))) return child; const found = find(child); if (found) return found; } }; return find(this); }
    matches(selector: string) { return [...selector.matchAll(/\.([\w-]+)/g)].some(match => this.classes.has(match[1])); }
    querySelectorAll(selector = ''): Node[] {
      if (selector === '*') return this.children.flatMap(child => child instanceof Node ? [child, ...child.querySelectorAll('*')] : []);
      return selector.split(/,(?![^(]*\))/).flatMap(part => part.replace(':scope>', '').split('>').reduce<Node[]>((nodes, step) => nodes.flatMap(node => node.children.filter((child): child is Node => child instanceof Node && (/^[a-z][\w-]*$/.test(step) ? child.tagName === step.toUpperCase() : [...step.matchAll(/\.([\w-]+)/g)].some(match => child.classes.has(match[1]))))), [this]));
    }
    get isConnected(): boolean { return this === document.body || this === document.documentElement || [...elements.values()].includes(this) || this.parent?.isConnected === true; }
    get childNodes(): Node[] { return this.children.map(child => typeof child === 'string' ? Object.assign(new Node(), { tagName: '#text', textContent: child }) : child); }
    removeChild(child: Node) { this.children = this.children.filter(other => other !== child); if (child instanceof Node) child.parent = undefined; return child; }
    hasAttribute(name: string) { return this.attributes.has(name); } getAttributeNames() { return [...this.attributes.keys()]; }
    insertBefore(child: Node, next: Node | null) { if (child === next) return; if (child instanceof Node) child.remove(); const index = next ? this.children.indexOf(next) : this.children.length; this.children.splice(index < 0 ? this.children.length : index, 0, child); if (child instanceof Node) child.parent = this; }
    get offsetTop() { return (this.parent?.children.indexOf(this) ?? 0) * 100; }
    get firstElementChild() { return this.children[0]; }
    get nextElementSibling(): Node | undefined { const index = this.parent?.children.indexOf(this) ?? -1; return index >= 0 ? this.parent?.children[index + 1] : undefined; }
    get previousElementSibling(): Node | undefined { const index = this.parent?.children.indexOf(this) ?? -1; return index > 0 ? this.parent?.children[index - 1] : undefined; }
    get lastElementChild() { return this.children.at(-1); }
    get lastChild() { return this.children.at(-1); }
    sizeOf?: () => number; seen?: number;
    get depth(): number { return this.parent ? this.parent.depth + 1 : 0; }
    get firstChild() { return this.children[0] ?? null; }
    get parentNode(): Node | null { return this.parent ?? null; }
    get nextSibling(): Node | null { return this.parent?.children[this.parent.children.indexOf(this) + 1] ?? null; }
  }
  const elements = new Map<string, Node>();
  const observers: { callback: (entries: unknown[]) => void; targets: Set<Node>; fresh: Set<Node> }[] = [];
  class ResizeObserver { private state: (typeof observers)[number]; constructor(callback: (entries: unknown[]) => void) { this.state = { callback, targets: new Set(), fresh: new Set() }; observers.push(this.state); } observe(target: Node) { if (!this.state.targets.has(target)) { this.state.targets.add(target); this.state.fresh.add(target); } } unobserve(target: Node) { this.state.targets.delete(target); this.state.fresh.delete(target); } }
  const listeners = new Map<string, (event: unknown) => void>(), captures = new Map<string, (event: unknown) => void>();
  const windowListeners = new Map<string, (event?: unknown) => void>();
  let activeElement: Node | undefined;
  const document = { timeline: { currentTime: 100000 }, hidden: false, visibilityState: 'visible', documentElement: new Node(), body: new Node(), hasFocus: () => true, get activeElement() { return activeElement; }, set activeElement(node: Node | undefined) { if (activeElement === node) return; const previous = activeElement; activeElement = node; if (previous) listeners.get('focusout')?.({ target: previous }); if (node) listeners.get('focusin')?.({ target: node }); }, querySelector: (selector?: string): Node | null => selector === '.cm-content' ? document.getElementById('prompt').children[0] ?? null : selector === '.lightbox' ? document.body.children.find(node => node.classList.contains('lightbox')) ?? null : null, getElementById(id: string) { let node = elements.get(id); if (!node) { node = new Node(); elements.set(id, node); if (id === 'prompt') document.getElementById('field').append(node); if (id === 'composer') node.hidden = false; } return node; }, createElement: (tag: string) => { const node = new Node(); node.hidden = false; node.tagName = tag.toUpperCase(); return node; }, createElementNS: () => new Node(), createTextNode: (text: string) => { const node = new Node(); node.tagName = '#text'; node.textContent = text; return node; }, addEventListener(type: string, handler: (event: unknown) => void, options?: { capture?: boolean }) { (options?.capture ? captures : listeners).set(type, handler); }, querySelectorAll: (): Node[] => [] };
  type Handlers = { input(user: boolean): void; send(mode: PromptMode): void; quit(): void };
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
  const history: { state: unknown; replaceState(state: unknown): void } = { state: null, replaceState(state) { this.state = state; } };
  const context = { history, topicTurn, parseTopicName, ResizeObserver, matchMedia: () => ({ matches: false, addEventListener() {} }), Date: class extends Date { constructor(value: string | number = 1700000012000) { super(value); } static now() { return 1700000012000; } }, getComputedStyle: (node?: { tagName?: string }, pseudo?: string) => ({ top: pseudo === '::before' ? '-7.5px' : 'auto', [Symbol.iterator]: function* () {}, display: 'block', lineHeight: '20px', fontFamily: 'sans-serif', fontSize: '13px', getPropertyValue: () => '', marginBottom: node?.tagName === 'P' ? '10px' : '0px' }), composer, bashCommand, pathToken, ATTACHMENT_LIMITS, pathArg, jobEndText, AbortController, AbortSignal, CustomEvent: class { type: string; detail?: unknown; constructor(type: string, options?: { detail?: unknown }) { this.type = type; this.detail = options?.detail; } }, Node, Element: Node, HTMLElement: class { static [Symbol.hasInstance](value: unknown) { return value instanceof Node && value.tagName !== '#text'; } }, HTMLButtonElement: Node, HTMLImageElement: Node, HTMLInputElement: class {}, HTMLTextAreaElement: class {}, markdown, markdownLine, document, window: { ko: {}, getSelection: () => null, addEventListener(type: string, handler: (event?: unknown) => void) { windowListeners.set(type, handler); } }, innerWidth: 980, innerHeight: 560, Event: class { type: string; constructor(type: string) { this.type = type; } }, console, setInterval() {}, clearInterval() {}, setTimeout, clearTimeout, requestAnimationFrame() {}, cancelAnimationFrame() {}, performance: { now: () => 0 }, fetch: async () => ({ ok: true, json: async () => ({}) }) };
  const answersSource = pageSource('page/answers.ts').replace(/^export /gm, '');
  const annotationsSource = pageSource('page/annotations.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(answersSource + '\n' + annotationsSource + '\n({annotations,update,head,quote})', context));
  document.getElementById('scroll').clientHeight = 100000;
  document.getElementById('items').hidden = false;
  Object.assign(document, { createTreeWalker: () => ({ nextNode: () => false }), createRange: () => { let target: Node | undefined; return { selectNodeContents(node: Node) { target = node; }, getClientRects: () => target?.rects ?? [] }; } });
  Object.assign(context, { NodeFilter: { SHOW_TEXT: 4 }, getSelection: () => context.window.getSelection() });
  const attachSource = pageSource('page/attach.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const httpSource = pageSource('page/http.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const previewSource = pageSource('page/preview.ts').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(previewSource + '\n({preview,previewKey,closeLightbox})', context));
  Object.assign(context, { ...runInNewContext(httpSource + '\n({fetchJSON,scoped})', context), attach: runInNewContext(attachSource + '\nattach', context) });
  const jobSource = ['page/job-output.ts', 'page/job.ts'].map(name => pageSource(name).replace(/^import .*;\n/gm, '').replace(/^export /gm, '')).join('\n');
  Object.assign(context, runInNewContext(jobSource + '\n({createJobPage})', { ...context, atob, TextDecoder, Uint8Array }));
  const revealSource = pageSource('page/reveal.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(revealSource + '\n({revealHeight,unitsOf})', context));
  const runSource = pageSource('topic-run.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(runSource + '\n({runParts,runOwner,runOf,invalidateRuns,sourceKey,visibleText,projectTopic,countedMessage})', context));
  const extentSource = pageSource('page/extent.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(extentSource + '\n({estimateExtent,windowOf,groupAt,rowKey,sameRow})', context));
  const stepsSource = pageSource('page/steps.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(stepsSource + '\n({stepInfo,stepParts,toolArgs,agentBody,noticeOf,noticeText,sessionFields})', context));
  const findSource = pageSource('page/find.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  Object.assign(context, { markdownPlain }, runInNewContext(findSource + '\n({findSegments,matchesIn})', context));
  for (const [name, exports] of [['topics', 'createTopics,topicsMemory'], ['transcript-history', 'createTranscriptHistory']]) {
    const moduleSource = pageSource('page/' + name + '.ts').replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
    const marker = name === 'topics' ? 'return {\n    update' : 'return { get more()';
    assert.equal(moduleSource.split(marker).length, 2, name + ' factory return marker');
    const injected = name === 'topics'
      ? `return { debug: {
        scopes, scopeData, interaction, setTopic, setComposerTopic,
        clickTopic, moveTopic, topicChip, topicMode, topicAge,
        renameTopic, dragTopic, updateTopicFilter, toggleTopics, fitTopics, topicColour,
        newTopicChip, startTopicNaming, finishTopicNaming,
        get topicDragged() { return topicDragged; },
      }, update`
      : `return { debug: {
        get request() { return request; }, set request(value) { request = value; },
        get before() { return before; }, set before(value) { before = value; },
        get more() { return more; }, set more(value) { more = value; },
      }, get more()`;
    const debugSource = moduleSource.replace(marker, injected);
    Object.assign(context, runInNewContext(debugSource + '\n({' + exports + '})', context));
  }
  const workingSource = pageSource('page/working.ts').replace(/^export /gm, '');
  Object.assign(context, runInNewContext(workingSource + '\n({dots})', context));
  Object.assign(context, { scrollInitial, scrollMemory, scrollStored, reduce, place, scrollWindow });
  Object.assign(document, { fonts: { ready: { then(resolve: () => void) { resolve(); } } } });
  const body = source.replace(/^import .*;\n/gm, "").replace('refreshComposer(); focusComposer(); void connect();', '') + "\nfunction dispatch(event, measurement) { const original = measure; measure = () => ({ ...original(), ...measurement }); try { decide(event); } finally { measure = original; } }\nfunction frame(measurement) { const original = measure; if (measurement) { lastMeasurement = undefined; measure = () => lastMeasurement = ({ ...original(), ...measurement }); } try { tick(); } finally { measure = original; } }\nfunction put(item) { if(item.kind==='assistant')item.blocks.forEach((block,index)=>{if((block.type==='text'||block.type==='thinking')&&!items.get(item.seq)?.blocks?.[index])textBirths.add(item.seq+':'+index)}); accept(item); renderDirty(); return views.get(item.seq)?.view; }\nlet agentTestSeq=10000;function agentStep(card,at,key,slots=new Map()){let seq=slots.get(key);if(seq===undefined){seq=agentTestSeq++;slots.set(key,seq)}const base={seq,revision:0,at,final:true};accept(card.direction==='in'?{...base,kind:'agent',...card}:{...base,kind:'assistant',stop:'stop',error:'',blocks:[{type:'tool',id:key,name:'spawn_agent',args:{text:'{}'},state:{type:'done',error:false,result:{text:'',images:[]}},agent:card}]});live.add(seq);renderDirty();live.delete(seq);const owner=runOwner(runContext(),card.direction==='in'?{kind:'item',seq}:{kind:'block',seq,index:0});return openers.get(sourceKey(card.direction==='in'?{kind:'item',seq}:{kind:'block',seq,index:0})).view;}";
  return { observers, repl: (): ((code: string) => unknown) => runInNewContext("(() => {\n" + body + "\nreturn code => eval(code);\n})()", context), context, elements, listeners, captures, windowListeners, completionResets: () => completionResets, handlers: () => handlers, prompt: () => prompt, text: () => text(), run: (code: string) => runInNewContext("{\n" + body + "\n" + code + "\n}", context) };
}

test('filtered history renders the same mixed-topic run and notices as the live feed', async t => {
  const fixture = await realFixture(t, {
    replies: [{ tools: [{ name: 'probe', args: { topic: 'one' } }] }, { tools: [{ name: 'probe', args: { topic: 'two' } }] }, { text: '[topic: two]\nOther-topic prose' }],
    extensions: { 'probe.ts': `export default function(pi) { pi.registerTool({ name: 'probe', label: 'probe', description: 'probe', parameters: { type: 'object', properties: { topic: { type: 'string' } }, required: ['topic'] }, async execute(_id, args, _signal, _update, ctx) { if (args.topic === 'two') ctx.ui.notify('Joined notice', 'info'); return { content: [{ type: 'text', text: args.topic }], details: { topic: args.topic } }; } }); }` },
  });
  const from = fixture.count();
  assert.equal((await fixture.post('prompt', { text: '[topic: one]\nWork', mode: 'prompt', attachments: [] })).status, 200);
  await fixture.until(ofType('state', record => record.working === true), from);
  await fixture.until(ofType('state', record => record.working === false), from);
  const records = fixture.records();
  assert.doesNotMatch(JSON.stringify(records), /Tool probe not found/, fixture.stderr());
  const response = await fetch(fixture.url('items?before=100000&topic=one'));
  assert.equal(response.status, 200);
  const history = await response.json();
  const live = (await page()).repl(), loaded = (await page()).repl();
  for (const evaluate of [live, loaded]) evaluate("state={...state,view:{id:'root',type:'root',path:[]}};topics.debug.scopeData(topics.scope()).filter='one';");
  for (const record of records) if (['reset', 'item', 'patch', 'flush'].includes(record.type)) live(`apply(${JSON.stringify(record)});`);
  loaded(`apply(${JSON.stringify({ type: 'reset', ...history })});`);
  const snapshot = `refreshTopicItems();renderDirty();JSON.stringify(order.map(seq=>({seq,rows:unitRows(seq,'visible'),item:visible(seq)})))`;
  const expected = String(live(snapshot));
  assert.match(expected, /Joined notice/);
  assert.equal((expected.match(/"name":"probe"/g) ?? []).length, 2);
  assert.doesNotMatch(expected, /Other-topic prose/);
  assert.equal(String(loaded(snapshot)), expected);
  const runs = `[...openers.entries()].filter(([key])=>key.startsWith('run:')).forEach(([,opener])=>opener.open());JSON.stringify([...views.values()].flatMap(entry=>[...entry.slots.values()].filter(slot=>slot.type==='run'&&slot.view.firstElementChild).map(slot=>{const marks=runMarks.get(slot.view.firstElementChild);return marks.steps.map(step=>[step.current.kind,step.current.kind==='block'?step.current.block.topic:undefined,step.label.textContent]);})))`;
  const steps = JSON.parse(String(live(runs)));
  assert.equal(steps.length, 1);
  assert.deepEqual(steps[0].map((step: unknown[]) => step.slice(0, 2)), [['block', 'one'], ['block', 'two'], ['notice', null]]);
  assert.match(steps[0][2][2], /Joined notice/);
  assert.equal(String(loaded(runs)), JSON.stringify(steps));
});

test('quota history keeps the complete leading run like the live feed', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'koa-run-window-'));
  const view = transcript({ dir, flushMs: 1, kind: 'root', branch: () => [], sessionEntryToContextMessages });
  t.after(() => { view.close(); rmSync(dir, { recursive: true, force: true }); });
  const request = (path: string) => {
    const req = new IncomingMessage(new Socket()); req.method = 'GET'; req.url = path;
    const response = new ServerResponse(req), chunks: string[] = [];
    response.write = (chunk: string) => { chunks.push(chunk); return true; };
    response.end = (chunk?: unknown) => { if (typeof chunk === 'string') chunks.push(chunk); return response; };
    assert.equal(view.handle(req, response, { type: 'selected' }), true);
    return chunks;
  };
  const feed = request('/events');
  const tool = (id: string) => ({ type: 'toolCall' as const, id, name: 'read', arguments: { path: id } });
  const reply = { role: 'assistant' as const, api: 'openai-completions' as const, provider: 'fake', model: 'fake-model', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
  view.message({ role: 'user', content: '[topic: two]\nStart', timestamp: 1 }, 'end');
  view.message({ ...reply, content: [tool('earlier')], stopReason: 'toolUse', timestamp: 2 }, 'end');
  view.notify('Joined earlier notice', 'info');
  view.message({ ...reply, stopReason: 'stop', content: [tool('cutoff'), { type: 'text', text: '[topic: one]\nCutoff prose' }], timestamp: 3 }, 'end');
  view.toolDone('cutoff', [{ type: 'text', text: 'done' }], false, 3, undefined, undefined, { topic: 'one' });
  for (let index = 0; index < 99; index++) view.message({ role: 'user', content: '[topic: one]\nLater ' + index, timestamp: 4 + index }, 'end');
  request('/events');
  const live = (await page()).repl(), historyPage = await page(), loaded = historyPage.repl();
  for (const evaluate of [live, loaded]) evaluate("state={...state,view:{id:'root',type:'root',path:[]}};topics.debug.scopeData(topics.scope()).filter='one';");
  for (const line of feed) live(`apply(${line.slice(6, -2)});`);
  const newest = JSON.parse(request('/items?before=100000&topic=one').join(''));
  loaded(`apply(${JSON.stringify({ type: 'reset', ...newest })});renderDirty();`);
  const snapshot = "renderDirty();JSON.stringify(order.filter(seq=>visible(seq)?.kind!=='topics').map(seq=>({seq,item:visible(seq),rows:unitRows(seq)})))";
  assert.equal(String(loaded(snapshot)), String(live(snapshot)), 'quota page must keep the earlier run owner');
});

test('row identities keep block order and distinguish item sources', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate(`items.set(0,{kind:'assistant',seq:0,blocks:[{type:'thinking',text:'work'},{type:'text',text:'answer'},{type:'thinking',text:'more'}]});
    items.set(1,{kind:'agent',seq:1});`);
  assert.equal(evaluate(`JSON.stringify(unitRows(0,'all'))`), JSON.stringify([
    { kind: 'run', source: { kind: 'block', seq: 0, index: 0 } },
    { kind: 'text', source: { kind: 'block', seq: 0, index: 1 } },
    { kind: 'run', source: { kind: 'block', seq: 0, index: 2 } },
  ]));
  assert.equal(evaluate(`JSON.stringify(unitRows(1,'all'))`), '[]');
  evaluate(`items.set(2,{kind:'user',seq:2});items.set(3,{kind:'agent',seq:3});`);
  assert.equal(evaluate(`JSON.stringify(unitRows(3,'all'))`), JSON.stringify([{ kind: 'run', source: { kind: 'item', seq: 3 } }]));
  assert.equal(evaluate(`sameRow(unitRows(3,'all')[0], JSON.parse(JSON.stringify(unitRows(3,'all')[0])))`), true);
});

test('unfiltered row ownership reads grow linearly across a tool-only run', async () => {
  const app = await page(), evaluate = app.repl();
  const reads = evaluate(`
    for(let seq=0;seq<200;seq++) items.set(seq,{kind:'assistant',seq,revision:0,at:0,final:true,stop:'stop',error:'',blocks:[{type:'thinking',text:'work'}]});
    let reads=0; const get=items.get.bind(items); items.get=seq=>{reads++;return get(seq)};
    for(let seq=0;seq<200;seq++) unitRows(seq,'all');
    reads;
  `);
  assert.equal(typeof reads, 'number');
  assert.ok(typeof reads === 'number' && reads <= 200 * 8, `expected at most 1600 item reads, got ${reads}`);
});

test('quoteSelection appends transcript quotes, preserves composer selections and follows the view', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'}};
    window.getSelection=()=>({anchorNode:element('items'),focusNode:element('items'),isCollapsed:false,toString:()=>'**First** line\\n\\n[Second](url)',removeAllRanges(){window.cleared=true}});`);
  evaluate('window.__koComposer=value=>{window.composerState=value};reportComposer()');
  assert.equal(evaluate('window.composerState.type'), 'quote');
  evaluate('window.__koQuoteSelection()');
  assert.equal(app.text(), '> First line\n> Second\n');
  assert.equal(evaluate('window.cleared'), true);
  assert.equal(app.context.document.activeElement, app.prompt());
  for (const ending of ['Answer', 'Answer\n', 'Answer\n\n']) {
    evaluate(`editor.setText(${JSON.stringify(ending)});quoteSelection()`);
    assert.equal(app.text(), 'Answer\n\n> First line\n> Second\n');
    assert.equal(app.prompt()?.selectionStart, app.text().length);
  }
  evaluate("window.getSelection=()=>null;document.activeElement=element('items');quoteSelection();reportComposer()");
  assert.equal(evaluate('window.composerState.type'), 'focus');
  assert.equal(app.context.document.activeElement, app.prompt());
  const before = app.text();
  evaluate("window.getSelection=()=>({anchorNode:element('prompt'),focusNode:element('prompt'),isCollapsed:false,toString:()=> 'selected draft'});quoteSelection()");
  assert.equal(app.text(), before);
  evaluate("state={...state,view:{type:'job',id:'job',path:[]}};document.activeElement=element('items');quoteSelection();reportComposer()");
  assert.equal(evaluate('window.composerState.type'), 'prompt');
  assert.equal(app.text(), before);
  assert.notEqual(app.context.document.activeElement, app.prompt());
  evaluate("state={...state,view:{type:'subagent',id:'child',path:[]}};editor.setText('Child draft');window.getSelection=()=>({anchorNode:element('items'),focusNode:element('items'),isCollapsed:false,toString:()=> 'Child quote',removeAllRanges(){}});quoteSelection()");
  assert.equal(app.text(), 'Child draft\n\n> Child quote\n');
  evaluate("leaveView('root');state={...state,view:{type:'root',id:'root',path:[]}};editor.setText('Root draft');leaveView('child');state={...state,view:{type:'subagent',id:'child',path:[]}}");
  assert.equal(app.text(), 'Child draft\n\n> Child quote\n');
  evaluate("leaveView('root')");
  assert.equal(app.text(), 'Root draft');
});

test('job quoteSelection reports its record and returns the raw selection for the palette', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate("state={...state,view:{type:'job',id:'j1',record:'agents/reviewer/jobs/j1',path:[]}};window.__koComposer=value=>{window.composerState=value};window.getSelection=()=>null;reportComposer()");
  assert.equal(evaluate('JSON.stringify(window.composerState)'), '{"type":"prompt","record":"agents/reviewer/jobs/j1"}');
  assert.equal(evaluate('JSON.stringify(window.__koQuoteSelection())'), '{"record":"agents/reviewer/jobs/j1"}');
  evaluate("window.getSelection=()=>({anchorNode:element('jobv'),focusNode:element('jobv'),isCollapsed:false,toString:()=> '  error: **raw**\\nnext line'});reportComposer()");
  assert.equal(evaluate('window.composerState.type'), 'prompt_quote');
  assert.equal(evaluate('window.__koQuoteSelection().quote'), '  error: **raw**\nnext line');
  evaluate('window.ko=undefined');
  assert.equal(evaluate('quoteSelection()'), undefined);
  assert.equal(app.text(), '');
});

test('quoteSelection restores composer focus from a collapsed composer caret', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate("state={...state,life:{type:'ready'}};editor.setText('Keep the draft');window.getSelection=()=>({anchorNode:element('prompt'),focusNode:element('prompt'),isCollapsed:true});document.activeElement=element('model');quoteSelection()");
  assert.equal(app.context.document.activeElement, app.prompt());
  assert.equal(app.text(), 'Keep the draft');
});

test('a quote edit resets the Escape sequence like typing', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate("state={...state,life:{type:'ready'}};editor.setText('Keep the draft');window.getSelection=()=>({anchorNode:element('items'),focusNode:element('items'),isCollapsed:false,toString:()=> 'Keep this quote',removeAllRanges(){}})");
  const escape = () => app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  escape();
  evaluate('quoteSelection()');
  escape();
  assert.equal(app.text(), 'Keep the draft\n\n> Keep this quote\n');
});

test('browser quote shortcut prevents the default on each modifier platform', async () => {
  for (const platform of ['MacIntel', 'Linux x86_64']) {
    const app = await page();
    Object.assign(app.context, { navigator: { platform } });
    const evaluate = app.repl();
    evaluate("window.ko=undefined;window.getSelection=()=>null;state={...state,life:{type:'ready'}}");
    let prevented = false;
    app.listeners.get('keydown')?.({ key: 'o', metaKey: platform === 'MacIntel', ctrlKey: platform !== 'MacIntel', preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
    assert.equal(app.context.document.activeElement, app.prompt());
  }
});

test('an open picker follows the field after the dock resizes', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate("state={...state,life:{type:'ready'},levels:['off','low']};element('model-cell').offsetParent=null;element('field').getBoundingClientRect=()=>({left:20,top:300})");
  await evaluate("picker('thinking')");
  assert.equal(evaluate("element('picker').style.bottom"), '268px');
  evaluate("element('field').getBoundingClientRect=()=>({left:30,top:400});resized([{target:element('dock'),borderBoxSize:[{blockSize:160}]}])");
  assert.equal(evaluate("element('picker').style.bottom"), '168px');
  assert.equal(evaluate("element('picker').style.left"), '24px');
  assert.equal(evaluate("element('picker').style.maxHeight"), '384px');
});

test('Tab outside the composer returns focus without changing dialog keys', async () => {
  const app = await page();
  app.run("state={...state,life:{type:'ready'}};document.body.focus()");
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
    state={...state,life:{type:'ready'}};
    editor.setText('!!echo hi');
    if (!element('field').classList.contains('bash-mode')) throw Error('missing bang font');
    state.bash=[{id:'run',phase:'running',command:'echo hi',excludeFromContext:true,started:1000,output:{text:'live',cut:0}}];
    editor.setText(''); refreshBash(); refreshComposer();
    if (element('prompt').children[0].placeholder !== 'running… ⎋ cancels') throw Error('missing running placeholder');
    const card=pendingBash.get('run'),pre=card.view.lastElementChild.firstElementChild,time=card.view.firstElementChild.lastElementChild.lastElementChild;
    if (time.textContent!=='3s') throw Error('missing running duration');
    if (!card.view.classList.contains('open')) throw Error('live output folded');
    state.bash[0].output={text:'more',cut:0}; refreshBash();
    if (pendingBash.get('run')!==card||card.view.lastElementChild.firstElementChild!==pre||pre.textContent!=='more') throw Error('live nodes replaced');
    apply({type:'reset',epoch:'rebuilt',items:[],more:false});
    if (!element('items').contains(card.view)) throw Error('rebuild removed running command');
    editor.setText('!next');
    if (canSend('!next')) throw Error('second command accepted');
    (()=>{card.update(state.bash[0]);return time.textContent});
  `);
  clock = 5000;
  assert.equal(tick(), '4s');
  assert.equal(fixture.elements.has('status'), false);
  assert.equal(fixture.elements.has('dot'), false);
});

test('bang attachments stay in the draft, turn red with a notice and new file drops are refused', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const app = await page();
  const notice = 'a command takes no attachments';
  const leave = app.run(`
    state={...state,life:{type:'ready'}};
    draft.restore([{id:'keep',name:'notes.md',path:'/tmp/notes.md',kind:'file',mimeType:'text/markdown',size:1}]);
    const chips=element('attachments');
    if (chips.children[0].classList.contains('refused')) throw Error('chip refused outside a command');
    editor.setText('!echo hi');
    if (canSend(editor.text()) || draft.count!==1) throw Error('attachment was sent or removed');
    if (!chips.children[0].classList.contains('refused')) throw Error('chip not refused');
    if (chips.children[0].children[0].children[2].classList.contains('reason')) throw Error('command-mode detail keyed red');
    const line=chips.children.at(-1);
    if (line.className!=='attach-notice'||line.hidden||line.textContent!=='${notice}') throw Error('missing notice: '+line.textContent);
    (()=>{editor.setText('normal');return [chips.children[0].classList.contains('refused'),line.hidden]});
  `);
  let prevented = false;
  app.listeners.get('drop')?.({ defaultPrevented: false, dataTransfer: { files: [{}], items: [] }, preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.equal(app.elements.get('error')?.textContent ?? '', '');
  assert.deepEqual(JSON.parse(JSON.stringify(leave())), [false, true]);
  assert.equal(app.elements.get('error')?.textContent ?? '', '');
});

test('Escape cancels a command before taking back and aborting a concurrent turn', async () => {
  const app = await page(), requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({ steering: [], followUp: [] }) }; };
  const cancelling = app.run(`state={...state,life:{type:'ready'},working:true,bash:[{id:'run',phase:'running',command:'echo',excludeFromContext:false,started:1,output:{text:'',cut:0}}]};(()=>{state.bash[0].phase='cancelling'})`);
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
    state={...state,life:{type:'ready'},levels:['low','high']};
    draft.restore([{id:'file',name:'notes',path:'/tmp/notes',size:2,kind:'file'}]);
    editor.setText('/thinking');
    fetchJSON=async()=>({disposition:'handled',action:{type:'picker',kind:'thinking',search:''}});
    send().then(()=>[draft.count,editor.text(),element('picker').hidden]);
  `);
  assert.deepEqual(Array.from(result), [1, '', false]);
});

test('a reload action blocks the composer and keeps its text through a lost stream', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,life:{type:'ready'}};
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
    state={...state,life:{type:'ready'}}; editor.setText('draft');
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
    state={...state,life:{type:'ready'}};
    draft.restore([{id:'file',name:'notes',path:'/tmp/notes',size:2,kind:'file'}]);
    editor.setText('/custom');fetchJSON=async()=>({disposition:'handled',action:{type:'none'}});
    send().then(()=>[draft.count,editor.text(),element('error').textContent]);
  `);
  assert.deepEqual(Array.from(result), [1, '', '']);
});

test('Return during compaction keeps the draft and attachments without a request', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,life:{type:'ready'},working:true,compaction:'running'};
    draft.restore([{id:'file',name:'notes',path:'/tmp/notes',size:2,kind:'file'}]);
    editor.setText('keep this draft'); let calls=0;fetchJSON=async()=>{calls++;return {}};
    refreshComposer();send().then(()=>[calls,editor.text(),draft.count]);
  `);
  assert.deepEqual(Array.from(result), [0, 'keep this draft', 1]);
  assert.equal(f.prompt()?.placeholder, 'Message koa…');
});

test('Escape aborts compaction after the slash command has returned', async () => {
  const f = await page();
  const result = await f.run(`
    state={...state,life:{type:'ready'}};editor.setText('/compact');const requests=[];
    fetchJSON=async path=>{requests.push(path);return path==='/prompt'?{disposition:'handled',action:{type:'none'}}:path==='/queue/clear'?{steering:[],followUp:[]}:{}};
    send().then(async()=>{state={...state,working:true,compaction:'running'};await stop();return requests.join(',')});
  `);
  assert.equal(result, '/prompt,/queue/clear,/abort');
});

test('cancelled compaction is a muted notice', async () => {
  const f = await page();
  const result = f.run(`
    put({kind:'command',seq:0,at:1,final:true,result:{type:'compaction',state:{type:'cancelled'}}});
    [views.get(0).view.children[0].className,views.get(0).view.children[0].children[0].children[0].textContent];
  `);
  assert.deepEqual(Array.from(result), ['nrow', 'compaction cancelled']);
});

test('command results use notice lines and expandable session information', async () => {
  const f = await page();
  const result = f.run(`
    put({kind:'command',seq:0,at:1,final:true,result:{type:'copy',characters:2100}});
    put({kind:'command',seq:1,at:1,final:false,result:{type:'compaction',state:{type:'running'}}});
    put({kind:'command',seq:2,at:1,final:true,result:{type:'session',name:'session',stats:{sessionId:'id',totalMessages:212,tokens:{input:1,output:2,cacheRead:3,cacheWrite:4},cost:1.42}}});
    const info=views.get(2).view.children[0];info.children[0].onclick({});
    [views.get(0).view.children[0].children[0].children[0].textContent,views.get(1).view.children[0].className,info.className];
  `);
  assert.deepEqual(Array.from(result), ['copied the last reply · 2.1k characters', 'nrow', 'nrow more open']);
});

test('session picker filters locally and keeps the draft on a switch', async () => {
  const fixture = await page();
  const result = await fixture.run(`(async()=>{
    state={...state,life:{type:'ready'},sessionId:'old'};
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
  const saved = app.run("state={...state,life:{type:'ready'},working:true};draft.restore([{id:'draft',name:'note',path:'/tmp/note',size:1,kind:'file'}]);editor.setText('/resume');void send();({files:()=>draft.files})");
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
    app.run(`state={...state,life:{type:'ready'},working:${working},bash:[{id:'run',phase:'running',command:'echo hi',excludeFromContext:false,started:1,output:{text:'',cut:0}}]};void sessionCommand('resume')`);
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
    state={...state,life:{type:'ready'},sessionId:'old'};
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
  const saved = app.run("state={...state,life:{type:'ready'},working:true,sessionId:'old'};void sessionCommand('new');({press:key=>sessionHost.onkeydown({key,preventDefault(){},stopPropagation(){}}),closed:()=>sessionPicker==='closed'})");
  saved.press('Enter'); saved.press('Enter'); saved.press('Escape'); release();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(calls, ['/abort']); assert.equal(saved.closed(), true);
});
test('topic rename selects the name and commits Enter and blur but cancels Escape', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const app = await page(), calls: { path: string; body: { from: string; to: string } }[] = [];
  app.context.fetch = async (path?: string, options?: { body: string }) => { calls.push({ path: path ?? '', body: JSON.parse(options?.body ?? '{}') }); return { ok: true, json: async () => ({}) }; };
  const controls = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one',last:{summary:'Summary',at:1}},{name:'two',last:{summary:'Older',at:0}}]};topics.render();
    const row=()=>element('topics').querySelector('.topic-entry');
    const open=()=>{row().onclick({detail:1});row().onclick({detail:2});return element('topics').querySelector('.topic-rename')};
    const input=open();
    return {selection:[input.selectionStart,input.selectionEnd],filter:()=>topics.filter(),key:(value,key)=>{const field=element('topics').querySelector('.topic-rename')??open();field.value=value;field.onkeydown({key,preventDefault(){},stopPropagation(){}})},blur:value=>{const field=open();field.value=value;field.onblur()},open};
  })()`);
  assert.deepEqual([...controls.selection], [0, 3]); t.mock.timers.tick(250); assert.equal(controls.filter(), undefined);
  controls.key('cancelled', 'Escape'); assert.equal(calls.length, 0);
  controls.key('two', 'Enter'); await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(calls.map(call => [call.path, call.body.from, call.body.to]), [['/topics/move', 'one', 'two']]);
  const valid = calls.length; controls.blur('x'.repeat(201)); await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(calls.length, valid);
  const before = calls.length; controls.blur('one'); controls.blur(' '); assert.equal(calls.length, before);
});

test('topic interactions cancel on scope changes and resets without committing', async () => {
  const app = await page(), calls: string[] = [];
  app.context.fetch = async (path?: string) => { calls.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  for (const transition of ["apply({...state,type:'state',sessionId:'other'});apply({type:'reset',epoch:'other',items:[],more:false})", "apply({type:'reset',epoch:'new',items:[],more:false})"]) {
    const result = app.run(`(()=>{
      state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};topics.render();
      topics.debug.renameTopic(element('topics').querySelector('.topic-entry'),'one');
      const input=element('topics').querySelector('.topic-rename');input.value='changed';
      const plus=topics.debug.newTopicChip({kind:'composer'});element('field').append(plus);topics.debug.startTopicNaming(plus,{kind:'composer'});topics.debug.interaction.naming.input.value='named';
      const handlers=new Map();document.addEventListener=(key,handler)=>handlers.set(key,handler);document.removeEventListener=key=>handlers.delete(key);
      const source=node('div'), target=node('div');target.dataset.topic='two';target.style.removeProperty=()=>{};
      element('scroll').getBoundingClientRect=()=>({left:0,right:100,top:0,bottom:100});element('scroll').scrollBy=()=>{};
      document.elementFromPoint=()=>({closest:selector=>selector.startsWith('.topic-entry')?target:null});
      topics.debug.dragTopic({button:0,isPrimary:true,clientX:0,clientY:0},source,'one');handlers.get('pointermove')({clientX:10,clientY:50,preventDefault(){}});
      const drop=handlers.get('pointerup');
      ${transition};
      const removed=!element('topics').querySelector('.topic-rename')&&!topics.debug.interaction.naming&&!topics.debug.interaction.drag?.cancel&&!source.classList.contains('dragging');input.onblur();drop({type:'pointerup'});
      return removed;
    })()`);
    assert.equal(result, true);
  }
  assert.deepEqual(calls, []);
});

test('topic drag selects the whole turn in sequence order after older history arrives', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};
    const handlers=new Map();document.addEventListener=(key,handler)=>handlers.set(key,handler);document.removeEventListener=key=>handlers.delete(key);
    element('scroll').getBoundingClientRect=()=>({left:0,right:100,top:0,bottom:100});element('scroll').scrollBy=()=>{};
    const source=node('div'), message=node('div');message.dataset.seq='0';message.style.removeProperty=()=>{};
    document.elementFromPoint=()=>({closest:selector=>selector.startsWith('#items')?message:null});
    items.clear();
    accept({kind:'user',seq:10,revision:1,at:1,final:true,text:'next',topic:'one'});
    accept({kind:'user',seq:0,revision:1,at:1,final:true,text:'first',topic:'one'});
    accept({kind:'assistant',seq:1,revision:1,at:1,final:true,blocks:[{type:'text',text:'reply',topic:'two'}],stop:'stop',error:''});
    const eligible=seq=>{message.dataset.seq=String(seq);topics.debug.dragTopic({button:0,isPrimary:true,clientX:0,clientY:0},source,'one');handlers.get('pointermove')({clientX:10,clientY:50,preventDefault(){}});const marked=message.classList.contains('drop-target');handlers.get('pointercancel')();return marked;};
    const user=eligible(0), reply=eligible(1);items.set(1,{...items.get(1),final:false});
    const unfinished=eligible(0);items.delete(1);topics.debug.updateTopicFilter('one');
    return [user,reply,unfinished,eligible(0)];
  })()`);
  assert.deepEqual(Array.from(result), [true, true, true, true]);
});

test('an unedited astral topic rename preserves the name and naming accepts the same length', async () => {
  const app = await page(), calls: string[] = [];
  app.context.fetch = async (path?: string) => { calls.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  const limit = app.run(`(()=>{
    const name='😀'.repeat(101);state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name}]};topics.render();
    topics.debug.renameTopic(element('topics').querySelector('.topic-entry'),name);element('topics').querySelector('.topic-rename').onblur();
    const plus=topics.debug.newTopicChip({kind:'composer'});element('field').append(plus);topics.debug.startTopicNaming(plus,{kind:'composer'});
    const limit=topics.debug.interaction.naming.input.maxLength;topics.debug.interaction.naming.input.value=name;topics.debug.finishTopicNaming(true);
    return [limit,topics.composer()];
  })()`);
  assert.deepEqual(calls, []);
  assert.notEqual(limit[0], 200);
  assert.equal(limit[1], '😀'.repeat(101));
});

test('scope restoration and state reconciliation keep the scroll filter in agreement', async () => {
  const app = await page();
  const result = await app.run(`(async()=>{
    rendered=async()=>{};fetch=async()=>({ok:true,json:async()=>({epoch,items:[],more:false})});
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};
    topics.debug.updateTopicFilter('one');apply({...state,type:'state',sessionId:'other'});apply({type:'reset',epoch:'other',items:[],more:false});scrollEvents.length=0;
    apply({...state,type:'state',sessionId:'s'});apply({type:'reset',epoch:'s',items:[],more:false});
    await transcriptHistory.debug.request?.done;tick();
    const restored=scrolling.unread.filtered;
    scrollEvents.length=0;apply({...state,type:'state',topics:[]});
    await transcriptHistory.debug.request?.done;
    tick();
    return [restored,topics.filter(),!scrolling.unread.filtered];
  })()`);
  assert.deepEqual(Array.from(result), [true, undefined, true]);
});

test('a stale destination filter does not erase the outgoing reader anchor', async () => {
  const app = await page();
  const saved = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[]};
    scrolling={...scrollInitial({view:'root',sessionId:'s'}),mode:{kind:'reader',anchor:{item:{kind:'message',seq:7},offset:13,edge:'row'}}};
    topics.debug.scopeData('destination:s').filter='stale';
    apply({...state,type:'state',view:{id:'destination',path:[],type:'root'}});apply({type:'reset',epoch:'destination',items:[],more:false});
    return scrolling.saved.get(JSON.stringify(['root',null]))?.anchor;
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(saved ?? null)), { item: { kind: 'message', seq: 7 }, offset: 13, edge: 'row' });
});

test('a reconciled destination filter reloads history once per scope transition', async () => {
  const app = await page(), calls: string[] = [];
  app.context.fetch = async (path?: string) => { calls.push(path ?? ''); return new Promise(() => {}); };
  app.run(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[]};epoch='loaded';
    topics.debug.scopeData('destination:s').filter='stale';topics.debug.scopeData('destination:s').move={from:'stale',to:'one'};
    apply({...state,type:'state',view:{id:'destination',path:[],type:'root'},topics:[{name:'one'}]});apply({type:'reset',epoch:'destination',items:[],more:false});`);
  assert.equal(calls.filter(path => path.startsWith('/items?')).length, 1);
});

test('pending prompts show mode and working dots without a remove control', async () => {
  const app = await page();
  const result = app.run(`(()=>{state={...state,queue:{steering:[],followUp:[],classifying:[{text:'Pending',attachments:[],mode:'followUp'}]}};queue();return [element('queue').querySelector('.kind').textContent,element('queue').querySelectorAll('button').length,!!element('queue').querySelector('.dots')]})()`);
  assert.deepEqual([...result], ['follow-up', 0, true]);
});

test('topic filters project blocks without changing their addresses and apply newest late labels', async () => {
  const app = await page();
  const result = app.run(`
    state = {...state, life:{type:'ready'},view:{id:'root',path:[],type:'root'},sessionId:'session',topics:[{name:'one',last:{summary:'**First**',at:1}},{name:'two'}]};
    topics.render();
    const user={kind:'user',seq:0,revision:1,at:1,final:true,text:'request',images:[],attachments:[]};
    accept(user);
    accept({kind:'assistant',seq:1,revision:1,at:2,final:true,blocks:[{type:'text',text:'visible one',topic:'one'},{type:'text',text:'hidden two',topic:'two'}],stop:'stop',error:''});
    topics.debug.setTopic('one');
    const hiddenUser=!visible(0), indexes=visible(1).blocks.map(block=>block.text), copied=transcriptText();
    accept({kind:'topics',target:0,topics:['one'],seq:2,revision:1,at:3,final:true});
    const labelled=!!visible(0);
    accept({kind:'topics',target:0,topics:['two'],seq:3,revision:1,at:4,final:true});
    const newest=!visible(0), original=items.get(1).blocks[1].text;
    const buttons=element('topics').children.length;
    apply({...state,type:'state',topics:[{name:'two'}]});
    const cleared=topics.filter()===undefined&&order.includes(0)&&visible(1).blocks[1].text==='hidden two';
    [hiddenUser,indexes,copied,labelled,newest,original,buttons,cleared];
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [true, ['visible one', ''], 'visible one', true, true, 'hidden two', 2, true]);
});

test('merge and message corrections fill gaps inside loaded filtered history', async () => {
  for (const kind of ['assistant', 'user']) {
    const app = await page();
    const result = app.run(`
      state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'A'},{name:'B'}]};
      accept({kind:'user',seq:10,revision:1,at:1,final:true,text:'start',topic:'B'});
      accept({kind:'user',seq:20,revision:1,at:1,final:true,text:'end',topic:'B'});
      topics.debug.setTopic('B');transcriptHistory.debug.request=undefined;transcriptHistory.debug.before=10;after=20;
      element('scroll').scrollTop=300;
      const moved=${JSON.stringify(kind)}==='assistant'
        ? {kind:'assistant',seq:15,revision:2,at:1,final:true,blocks:[{type:'text',text:'merged reply',topic:'B'}],stop:'stop',error:''}
        : {kind:'user',seq:15,revision:2,at:1,final:true,text:'moved message',topic:'B'};
      apply({type:'item',item:moved});
      apply({type:'item',item:{kind:'topics',seq:16,revision:2,at:1,final:true,target:15,topics:['B']}});
      const entered=!!visible(15),metadata=topicItems.get(15)?.topics[0];
      apply({type:'item',item:${JSON.stringify(kind)}==='assistant'?{...moved,revision:3,blocks:[{type:'text',text:'merged reply',topic:'A'}]}:{...moved,revision:3,topic:'A'}});
      apply({type:'item',item:{kind:'topics',seq:16,revision:3,at:1,final:true,target:15,topics:['A']}});
      [entered,metadata,!visible(15),topics.filter(),element('scroll').scrollTop,transcriptHistory.debug.before];
    `);
    assert.deepEqual(JSON.parse(JSON.stringify(result)), [true, 'B', true, 'B', 300, 10], kind);
  }
});

test('same-seq topic corrections update inferred prompt visibility', async () => {
  const app = await page();
  const result = app.run(`
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'A'},{name:'B'}]};
    accept({kind:'user',seq:10,revision:1,at:1,final:true,text:'inferred prompt'});
    accept({kind:'topics',seq:12,revision:1,at:1,final:true,target:10,topics:['A']});
    topics.debug.setTopic('B');transcriptHistory.debug.request=undefined;transcriptHistory.debug.before=10;
    const hidden=!visible(10);
    apply({type:'item',item:{kind:'topics',seq:12,revision:2,at:1,final:true,target:10,topics:['B']}});
    [hidden,topicItems.get(10).topics,topicItems.get(10).revision,!!visible(10),order.includes(10)];
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [true, ['B'], 2, true, true]);
});

test('filtered run boundaries keep both tools reachable across hidden prose', async () => {
  const app = await page();
  const result = app.run(`
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};
    const tool=(id)=>({type:'tool',id,name:'bash',topic:'one',args:{text:'{"command":"'+id+'"}',cut:0},state:{type:'done',error:false,result:{text:id,cut:0,images:[]}}});
    accept({kind:'assistant',seq:0,revision:1,at:1,final:true,stop:'stop',error:'',blocks:[tool('first'),{type:'text',topic:'two',text:'hidden'},tool('second')]});
    topics.debug.setTopic('one');renderItem(visible(0));reconcileRuns();
    [...views.get(0).slots.values()].filter(slot=>slot.type==='run').flatMap(slot=>runMarks.get(slot.view.firstElementChild)?.steps.map(step=>step.key)??[]);
  `);
  assert.deepEqual(Array.from(result), ['0:0','0:2']);
});

test('find keeps mixed-topic steps and late labels in one run', async () => {
  const app = await page();
  const result = app.run(`
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};
    const tool=(id,topic)=>({type:'tool',id,name:'bash',...(topic?{topic}:{}),args:{text:'{}',cut:0},state:{type:'done',error:false,result:{text:id,cut:0,images:[]}}});
    const reply=(seq,blocks)=>({kind:'assistant',seq,revision:1,at:1,final:true,stop:'stop',error:'',blocks});
    accept(reply(0,[tool('first','one'),tool('second','two')]));
    accept(reply(1,[tool('late')]));accept({kind:'topics',seq:2,revision:1,at:1,final:true,target:1,topics:['one']});
    accept(reply(3,[tool('last','two')]));
    const context={items:visible,fold:5,cwd:'',owners:new Map()};
    const keys=[findSegments(visible(0),context).find(segment=>segment.text==='second').folds[0],findSegments(visible(1),context).find(segment=>segment.text==='late').folds[0],findSegments(visible(3),context).find(segment=>segment.text==='last').folds[0]];
    renderItem(visible(0));renderItem(visible(1));reconcileRuns();
    openers.get(keys[0]).open();
    [...keys,openers.has('run:0:1'),openers.get('run:0:0').view.classList.contains('open')];
  `);
  assert.deepEqual(Array.from(result), ['run:0:0','run:0:0','run:0:0',false,true]);
});

test('an open topic panel keeps its scroll through state updates and closes by Escape or outside click', async () => {
  const app = await page();
  const ui = app.run(`
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:Array.from({length:20},(_,index)=>({name:'topic-'+index,last:{summary:'Before',at:1}}))};
    topics.render();topics.debug.toggleTopics();element('topics').querySelector('.topic-panel').scrollTop=80;
    apply({...state,type:'state',topics:state.topics.map((topic,index)=>index===0?{...topic,last:{summary:'After',at:2}}:topic)});
    ({values:[!element('topics').querySelector('.topic-panel').hidden,element('topics').querySelector('.topic-panel').scrollTop,element('topics').querySelector('.topic-summary').textContent],panel:()=>element('topics').querySelector('.topic-panel'),toggle:topics.debug.toggleTopics});
  `);
  assert.deepEqual(Array.from(ui.values), [true,80,'After']);
  app.listeners.get('keydown')?.({ key:'Escape',target:app.context.document.body,preventDefault(){} });
  assert.equal(ui.panel().hidden, true);
  ui.toggle();
  app.listeners.get('pointerdown')?.({ target:app.context.document.body });
  assert.equal(ui.panel().hidden, true);
});

test('new-message counts and topic badges exclude run steps and count messages once', async () => {
  const app = await page();
  const values = app.run(`
    state={...state,sessionId:'s',topics:[{name:'one'}]};
    scrolling={...scrolling,mode:{kind:'reader'}};
    window.koaFocused=false;const measurement={...measure(),focused:false,visible:true,top:0,dock:100,max:1000,lookup:item=>({kind:'unmounted',row:{item,top:800,bottom:900}})};
    const base={revision:0,at:1,final:true,topic:'one'};
    const tool={type:'tool',id:'t',name:'bash',topic:'one',args:{text:'{}'},state:{type:'done',error:false,result:{text:'output',images:[]}}};
    const incoming=[
      {...base,seq:1,kind:'user',text:'Remote request',images:[],attachments:[]},
      {...base,seq:2,kind:'assistant',blocks:[{type:'text',text:'First',topic:'one'},tool,{type:'text',text:'Second',topic:'one'},{type:'text',text:'Third',topic:'one'}]},
      {...base,seq:3,kind:'assistant',blocks:[tool]},
      {...base,seq:4,kind:'agent',direction:'in',from:{name:'worker'},inbound:{form:'report'},text:{text:'Report',cut:0}},
      {...base,seq:5,kind:'job',job:{id:'j',name:'build',log:'/tmp/build.log',service:false},event:{type:'stream',batch:{text:'log',cut:0},omitted:0,cut:false}},
    ];
    for(const item of incoming) accept(item);
    scrollEvents.length=0;
    for(const item of incoming) changedItem(item.seq,true);
    frame(measurement);
    const before=[scrollDecision.latest.count,topicUnread().get('one'),scrollDecision.divider?.seq];
    dispatch({type:'submit'},measurement);frame(measurement);
    accept({...base,seq:6,kind:'user',text:'Own request',images:[],attachments:[]});
    changedItem(6,true);frame(measurement);
    frame(measurement);
    const own=[scrolling.mode.kind,scrolling.unread.candidates.has(6),topicUnread().get('one')??0];
    state={...state,topics:[{name:'one'},{name:'two'}]};
    shownFilter='one';
    dispatch({type:'scope',filtered:true,scope:{...scrolling.scope,topic:'one'}},measurement);frame(measurement);
    scrolling={...scrolling,mode:{kind:'reader'}};
    accept({...base,seq:7,kind:'user',topic:'two',text:'',images:[],attachments:[{kind:'file',path:'/tmp/input'}]});
    accept({...base,seq:8,kind:'assistant',blocks:[{type:'text',text:'Only in one',topic:'one'},{...tool,topic:'two'}]});
    changedItem(7,true);changedItem(8,true);frame(measurement);
    const hidden=[topicUnread().get('one'),topicUnread().get('two'),scrollDecision.latest.count];
    shownFilter='two';projections.clear();
    dispatch({type:'scope',filtered:true,scope:{...scrolling.scope,topic:'two'}},measurement);frame(measurement);
    changedItem(7,false);changedItem(8,false);frame(measurement);
    [before,own,hidden,[scrollDecision.latest.count,scrollDecision.divider?.seq,topicUnread().get('two')]];
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(values)), [[2,2,1],['following',true,0],[1,1,1],[1,7,1]]);
});

test('topic badges count an unread reply once per topic and clear across filters', async () => {
  const app = await page();
  const values = app.run(`
    state={...state,sessionId:'s',topics:[{name:'one'},{name:'two',archived:true}]};
    window.koaFocused=false;const measurement={...measure(),focused:false,visible:true};
    put({seq:1,revision:0,at:1,kind:'assistant',final:false,blocks:[{type:'text',text:'One',topic:'one'},{type:'text',text:'Two',topic:'two'}]});
    scrollEvents.length=0; changedItem(1,true); frame(measurement);
    const counts=()=>Array.from(topicUnread().values());
    const before=counts(), badges=element('topics').querySelectorAll('.topic-panel>.topic-entry>.topic-age>.topic-unread').length;
    put({...items.get(1),revision:1,blocks:[...items.get(1).blocks,{type:'text',text:'More',topic:'one'}]});
    frame(measurement); const grown=counts();
    topics.debug.scopeData(topics.scope()).filter='one'; topics.render();
    const active=element('topics').querySelector('.topic-panel').children.find(row=>row.dataset.topic==='one').querySelector('.topic-age').children.filter(child=>child.classList.contains('topic-unread')).length;
    dispatch({type:'latest'},{...measurement,focused:true});frame({...measurement,focused:true});
    [before,badges,grown,active,counts()];
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(values)), [[1,1],2,[1,1],0,[]]);
  const restored = await app.run(`(async()=>{
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};
    topics.debug.scopeData(topics.scope()).filter='one';
    const scope={view:'root',sessionId:'s',topic:'one'};
    scrolling=scrollInitial({view:'',sessionId:undefined},[{scope,anchor:{item:{kind:'message',seq:2},offset:0,edge:'row'},last:5}]);
    decide({type:'scope',scope,filtered:true});
    const reply=(seq,topic)=>({kind:'assistant',seq,revision:1,at:1,final:true,stop:'stop',error:'',blocks:[{type:'text',topic,text:'Reply '+seq}]});
    rendered=async()=>{frame({...measure(),focused:false,lookup:()=>({kind:'mounted',row:{item:{kind:'message',seq:2},top:0,bottom:20}})});};
    fetch=async url=>{
      const pages={
        '/items?before=9007199254740991&topic=one&sessionId=s':{more:false,items:[reply(2,'one')]},
        '/items?before=20&sessionId=s':{more:true,items:[reply(8,'two')]},
        '/items?before=8&sessionId=s':{more:false,items:[reply(4,'two')]},
      };
      const result=pages[String(url)];if(!result)throw Error('Unexpected history URL: '+url);
      return {ok:true,json:async()=>({type:'reset',epoch:'restore',...result})};
    };
    const catchUp=transcriptHistory.catchUp;let caught;
    transcriptHistory.catchUp=last=>(caught=catchUp(last));
    apply({type:'reset',epoch:'restore',more:true,items:[reply(20,'one')]});
    await transcriptHistory.reload();
    await caught;
    await rendered();
    await rendered();
    return [topicUnread().get('two')??0,scrolling.unread.candidates.get(4)?.values().next().value?.status === 'unread',scrolling.mode.kind];
  })()`);
  assert.deepEqual(Array.from(restored), [1,false,'reader']);
  const filtered = await app.run(`(async()=>{
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};
    const scope={view:'root',sessionId:'s',topic:'one'};
    scrolling=scrollInitial({view:'root',sessionId:'s'},[{scope,anchor:{item:{kind:'message',seq:2},offset:0,edge:'row'},last:5}]);
    const reply=(seq,topic)=>({kind:'assistant',seq,revision:1,at:1,final:true,stop:'stop',error:'',blocks:[{type:'text',topic,text:'Reply '+seq}]});
    rendered=async()=>{frame({...measure(),focused:false,lookup:()=>({kind:'mounted',row:{item:{kind:'message',seq:2},top:0,bottom:20}})});};
    fetch=async url=>{
      const pages={
        '/items?before=9007199254740991&topic=one&sessionId=s':{more:false,items:[reply(2,'one')]},
        '/items?before=20&sessionId=s':{more:true,items:[reply(8,'two')]},
        '/items?before=8&sessionId=s':{more:false,items:[reply(4,'two')]},
      };
      const result=pages[String(url)];if(!result)throw Error('Unexpected history URL: '+url);
      return {ok:true,json:async()=>({type:'reset',epoch:'filter-restore',...result})};
    };
    const catchUp=transcriptHistory.catchUp;let caught;
    transcriptHistory.catchUp=last=>(caught=catchUp(last));
    apply({type:'reset',epoch:'filter-restore',more:true,items:[reply(20,'one')]});
    await rendered();
    topics.debug.scopeData(topics.scope()).filter='one';
    await transcriptHistory.reload('filter');
    await rendered();
    await caught;
    await rendered();
    await rendered();
    return [topicUnread().get('two')??0,scrolling.unread.candidates.get(4)?.values().next().value?.status === 'unread',scrolling.mode.kind];
  })()`);
  assert.deepEqual(Array.from(filtered), [1,false,'reader']);
});

test('reply sections carry interactive topic chips or a plain time with no marks or edges', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const at=Date.now(),reply=(seq,blocks)=>({seq,at,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks});
    state={...state,working:true,view:{id:'root',path:[],type:'root'},sessionId:'headers',topics:[{name:'one'},{name:'two'}]};
    put(reply(0,[{type:'text',text:'First',topic:'one'},{type:'text',text:'Second',topic:'two'}]));
    put(reply(1,[{type:'text',text:'Plain'}]));
    const all=node=>[node,...node.children.filter(child=>child instanceof HTMLElement).flatMap(all)];
    const headers=all(views.get(0).view).filter(node=>node.classList.contains('message-header')),plain=all(views.get(1).view).find(node=>node.classList.contains('message-header'));
    const labels=headers.map(header=>[header.querySelector('.topic-name')?.children[1].textContent,header.children.find(node=>node.tagName==='TIME')?.textContent,header.querySelector('.topic-chip')?.getAttribute('role')??null,typeof header.querySelector('.topic-chip')?.onclick==='function']);
    const plainInfo=[plain?.children.find(node=>node.tagName==='TIME')?.textContent,plain?.getAttribute('role'),typeof plain?.onclick==='function'];
    const noMarks=all(views.get(0).view).every(node=>!node.classList.contains('topic-mark')&&!node.classList.contains('topic-edge'));
    headers[0]?.querySelector('.topic-chip')?.onclick?.();
    const selected=[topics.composer(),topics.filter()];topics.debug.setTopic('one');renderDirty();
    put({seq:2,at,kind:'user',revision:0,final:true,text:'pending',images:[],attachments:[]});
    const pending=all(views.get(2).view).some(node=>node.classList.contains('topic-waiting')||node.classList.contains('topic-pending'));
    const filtered=all(views.get(0).view).filter(node=>node.classList.contains('message-header')).map(header=>[header.children.find(node=>node.tagName==='TIME')?.textContent,!!header.querySelector('.topic-name'),header.querySelector('.topic-name')?.parentNode?.getAttribute('role')??null,typeof header.querySelector('.topic-name')?.parentNode?.onclick==='function']);
    return [labels,plainInfo,noMarks,topics.filter(),pending,timestamp(at),filtered,selected];
  })()`);
  const value=JSON.parse(JSON.stringify(result));
  assert.deepEqual(value.slice(0,5), [[['one',value[5],'button',true],['two',null,'button',true]],[value[5],null,false],true,'one',false]);
  assert.deepEqual(value[6], [[value[5],false,null,false]]);
  assert.deepEqual(value[7], ['one',null]);
});

test('message headers exclude runs and notices and the composer clear preserves the filter', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},view:{id:'root',path:[],type:'root'},sessionId:'headers',topics:[{name:'one'}]};
    const base={at:1,revision:0,final:true};
    const count=(root,name)=>root.children.reduce((sum,child)=>sum+(child instanceof HTMLElement?Number(child.classList.contains(name)&&!(name==='topic-chip'&&child.classList.contains('topic-new')))+count(child,name):0),0);
    put({...base,seq:0,kind:'user',text:'Question',topic:'one',images:[],attachments:[]});
    put({...base,seq:1,kind:'assistant',blocks:[{type:'text',text:'Answer',topic:'one'}],stop:'stop',error:''});
    put({...base,seq:2,kind:'assistant',blocks:[{type:'tool',id:'t',name:'bash',args:{text:'{}'},state:{type:'done',error:false,result:{text:'ok',images:[]}}}],stop:'stop',error:''});
    put({...base,seq:3,kind:'notice',customType:'note',from:'worker',text:'Note'});
    put({...base,seq:4,kind:'agent',direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    put({...base,seq:5,kind:'job',job:{id:'j',name:'build',log:'/tmp/build.log'},event:{type:'stream',batch:{text:'output',cut:0},omitted:0,cut:false}});
    state={...state,queue:{steering:[{text:'Steer',attachments:[],topic:'one'}],followUp:[{text:'Later',attachments:[],topic:'one'}],classifying:[{text:'Pending',attachments:[],mode:'followUp'}]}};queue();
    const queueCounts=[count(element('queue'),'message-header'),count(element('queue'),'topic-chip')];
    for (const seq of [6,8,10]) put({...base,seq,kind:'user',text:'Implicit',images:[],attachments:[]});
    put({...base,seq:7,kind:'topics',target:6,topics:['one']});
    put({...base,seq:9,kind:'topics',target:8,topics:['one','two']});
    const implicit=[6,8,10].map(seq=>[count(views.get(seq).view,'message-header'),count(views.get(seq).view,'topic-chip')]);
    const counts=[0,1,2,3,4,5].map(seq=>[count(views.get(seq).view,'message-header'),count(views.get(seq).view,'topic-chip')]);
    views.get(0).view.querySelector('.topic-chip').onclick();
    topics.debug.setTopic('one');renderDirty();
    const filtered=[topics.filter(),!!element('field').querySelector('.composer-topic')?.querySelector('.topic-chip'),!!element('topics').querySelector('.topic-clear'),count(views.get(0).view,'topic-chip'),count(views.get(1).view,'topic-chip')];
    element('field').querySelector('.topic-clear').onclick();
    const dropped=[topics.composer(),topics.filter(),!!element('field').querySelector('.topic-new')];
    element('topics').querySelector('.topic-clear').onclick();
    return [counts,filtered,topics.filter(),!!element('field').querySelector('.composer-topic'),queueCounts,implicit,dropped];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[[1,1],[1,1],[0,0],[0,0],[0,0],[0,0]],['one',true,true,0,0],null,true,[0,0],[[1,1],[1,0],[1,0]],[null,'one',true]]);
});

test('find ignores message header names and times and export contains only prose', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const at=Date.now(),results=[];
    for(const text of ['one',timestamp(at)]){
      const row=node('div'),header=topics.header('one',at),paragraph=node('p'),leaf=document.createTextNode(text); paragraph.append(leaf);row.append(header,paragraph);
      const found=locate(row,[{text,lowered:text,folds:[],fences:[]}],{seq:0,segment:0,start:0},text.length);
      results.push(found?.start.node===leaf&&found?.end.node===leaf);
    }
    put({kind:'assistant',seq:0,at,revision:0,final:true,blocks:[{type:'text',topic:'one',text:'Only the reply'}],stop:'stop',error:''});
    return [results,transcriptText()];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[true,true],'Only the reply']);
});

test('whole transcript selection starts at prose rather than an unselectable message header', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const row=node('div'),header=topics.header('one',Date.now()),first=document.createTextNode('First'),last=document.createTextNode('Last');
    row.append(header,first,last);element('items').replaceChildren(row);order.push(0);
    getSelection=()=>({rangeCount:1,isCollapsed:false,getRangeAt:()=>({startContainer:first,startOffset:0,endContainer:last,endOffset:4}),containsNode:()=>false});
    return wholeSelection();
  })()`);
  assert.equal(result,true);
});

test('a message chip labels submissions and stays after send without filtering', async () => {
  const app = await page();
  const result = await app.run(`(async()=>{
    state={...state,life:{type:'ready'},working:true,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};
    accept({kind:'user',seq:0,revision:1,at:1,final:true,text:'pending',images:[],attachments:[]});
    const mark=topics.debug.topicChip('one'),clickable=typeof mark.onclick==='function';mark.onclick?.();renderItem(visible(0));
    const waiting=views.get(0).view.querySelector('.topic-waiting');
    const text=node=>node.textContent+node.children.map(text).join('');
    topics.render();const capsule=text(element('topics').querySelector('.topic-capsule'));
    let sent;rendered=async()=>{};fetchJSON=async(path,body)=>{sent=body;return {disposition:'queued'}};
    editor.setText('continue');await send();
    return [mark.tagName,mark.getAttribute('role'),clickable,topics.filter(),capsule,sent.topic,waiting?.tagName,typeof waiting?.onclick==='function',topics.composer()];
  })()`);
  assert.deepEqual(Array.from(result),['SPAN','button',true,undefined,'#one…','one',undefined,false,'one']);
});

test('filtering selects the composer topic but dropping it submits unlabelled with the filter intact', async () => {
  const app = await page();
  const result = await app.run(`(async()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};refreshComposer();
    const initial=!!element('field').querySelector('.topic-new');
    const sent=[];rendered=async()=>{};fetchJSON=async(path,body)=>{sent.push(body);return {disposition:'queued'}};
    topics.debug.setTopic('one');const selected=[topics.composer(),topics.filter()];
    editor.setText('first');await send();const sticky=topics.composer();
    topics.debug.setComposerTopic('two');editor.setText('second');await send();
    element('field').querySelector('.topic-clear').onclick();
    editor.setText('classify this');await send();const filterAfterDrop=topics.filter();
    topics.debug.setTopic('two');element('topics').querySelector('.topic-clear').onclick();
    return [initial,selected,sticky,sent.map(body=>body.topic),filterAfterDrop,topics.filter(),topics.composer(),!!element('field').querySelector('.composer-topic')];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [true,['one','one'],'one',['one','two',null],'one',null,null,true]);
});

test('composer topics stay with their root draft across reload and do not enter child or job views', async () => {
  const app = await page();
  const evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};topics.debug.setComposerTopic('two');editor.setText('draft');topics.debug.updateTopicFilter('one');topics.debug.setComposerTopic('one');editor.setText('preparing draft');`);
  app.windowListeners.get('pagehide')?.();
  evaluate("element('field').replaceChildren()");
  const restored = app.repl();
  const result = restored(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'}};refreshComposer();
    const root=[topics.filter(),topics.composer(),drafts.get('root')];
    const rows=[];
    for(const type of ['agent','job']){state={...state,view:{id:'child',path:[],type}};refreshComposer();rows.push([!!element('field').querySelector('.composer-topic'),topics.composer()]);}
    state={...state,sessionId:'other',view:{id:'root',path:[],type:'root'}};refreshComposer();
    return [root,rows,topics.composer(),!!element('field').querySelector('.topic-new')];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['one','two','draft'],[[false,null],[false,null]],null,true]);
});

test('clearing a widget filter drops its matching composer topic but keeps an independent choice', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};
    const results=[];
    for(const control of ['capsule','all','active']) for(const choice of ['same','other','following']) {
      topics.debug.setTopic('one');
      if(choice==='other') topics.debug.topicChip('two').onclick();
      if(choice==='following') delete topics.debug.scopeData(topics.scope()).composer;
      if(control==='capsule') element('topics').querySelector('.topic-clear').onclick();
      else if(control==='all') element('topics').querySelector('.topic-all').onclick();
      else element('topics').querySelector('.current').onclick({detail:0});
      results.push([topics.filter(),topics.composer()]);
    }
    return results;
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), Array.from({length:3}, () => [[null,null],[null,'two'],[null,null]]).flat());
});

test('a restored filter supplies only an unset composer topic and preserves an explicit drop', async () => {
  const app = await page(), evaluate = app.repl();
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate(`(()=>{state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'}};topics.debug.scopeData(topics.scope()).filter='one';const derived=topics.composer();topics.debug.setComposerTopic('two');const chosen=topics.composer();topics.debug.setComposerTopic(undefined);return [derived,chosen,topics.composer()]})()`))), ['one','two',null]);
  app.windowListeners.get('pagehide')?.();
  const restored = app.repl();
  assert.equal(restored(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'}};topics.composer()`), undefined);
  assert.equal(restored('topics.filter()'), 'one');
});

test('a delayed topic click cannot select a filter after a scope switch or a newer filter action', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const app = await page(), evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};topics.debug.clickTopic({detail:1},node('div'),'one');state={...state,sessionId:'other'};`);
  t.mock.timers.tick(250);
  assert.equal(evaluate('topics.filter()'), undefined);
  evaluate(`topics.debug.clickTopic({detail:1},node('div'),'one');topics.debug.setTopic('two');`);
  t.mock.timers.tick(250);
  assert.equal(evaluate('topics.filter()'), 'two');
});

test('a pending topic move updates only its original scope and does not replace a newer filter', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'A'},{name:'B'},{name:'C'}]};topics.debug.setTopic('A');fetchJSON=()=>new Promise(resolve=>window.finishMove=resolve);window.moving=topics.debug.moveTopic('A','B',topics.scope(),state.sessionId);state={...state,sessionId:'other'};topics.debug.setTopic('C');window.finishMove({});`);
  await evaluate('window.moving');
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate(`[topics.filter(),topics.composer(),topics.debug.scopes.get('root:s')?.filter,topics.debug.scopes.get('root:s')?.composer]`))), ['C','C','B',{type:'topic',name:'B'}]);
  evaluate(`topics.debug.setTopic('A');window.moving=topics.debug.moveTopic('A','B',topics.scope(),state.sessionId);topics.debug.setTopic('C');window.finishMove({});`);
  await evaluate('window.moving');
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate('[topics.filter(),topics.composer()]'))), ['C','C']);
});

test('a topic move follows its target when state arrives before the response', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'A'},{name:'B'}]};topics.debug.setTopic('A');fetchJSON=()=>new Promise(resolve=>window.finishMove=resolve);window.moving=topics.debug.moveTopic('A','B',topics.scope(),state.sessionId);apply({...state,type:'state',topics:[{name:'B'}]});window.finishMove({});`);
  await evaluate('window.moving');
  assert.equal(evaluate('topics.filter()'), 'B');
});

test('moving a topic updates its composer chip without replacing an independent composer topic', async () => {
  const app = await page();
  const result = await app.run(`(async()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'A'},{name:'B'},{name:'C'}]};
    fetchJSON=async()=>({});
    topics.debug.topicChip('A').onclick();await topics.debug.moveTopic('A','B',topics.scope(),state.sessionId);
    const renamed=[topics.filter(),topics.composer(),element('field').querySelector('.topic-name').title];
    topics.debug.setTopic('A');topics.debug.topicChip('C').onclick();await topics.debug.moveTopic('A','B',topics.scope(),state.sessionId);
    return [renamed,[topics.filter(),topics.composer(),element('field').querySelector('.topic-name').title]];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[null,'B','B'],['B','C','C']]);
});

test('composer naming commits with Enter or Tab, keeps its input on refresh and cancels without filtering', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'existing'}]};refreshComposer();
    const key=value=>({key:value,preventDefault(){},stopPropagation(){}}),open=()=>{element('field').querySelector('.topic-new').onclick();return element('field').querySelector('.topic-input')};
    let input=open();const initial=[input.placeholder,input.style.width,topics.debug.interaction.naming.chip.style['--topic-color']];input.value='existing';input.oninput();const existing=topics.debug.interaction.naming.chip.style['--topic-color'];refreshComposer();const retained=element('field').querySelector('.topic-input')===input&&document.activeElement===input;
    input.onkeydown(key('Tab'));const committed=[topics.composer(),topics.filter(),editor.hasFocus()];
    element('field').querySelector('.topic-clear').onclick();input=open();input.value='New topic';input.onkeydown(key('Enter'));const named=[topics.composer(),editor.hasFocus()];
    element('field').querySelector('.topic-clear').onclick();input=open();input.value='Cancelled';input.onkeydown(key('Escape'));const escaped=[topics.composer(),!!element('field').querySelector('.topic-new')];
    input=open();element('field').querySelector('.topic-clear').onclick();
    return [initial,existing,retained,committed,named,escaped,topics.composer(),!!element('field').querySelector('.topic-new')];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['topic name','10ch','var(--topic-1)'],'var(--topic-0)',true,['existing',null,true],['New topic',true],[null,true],null,true]);
});

test('a late topic label cancels reply naming and removes its naming control', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};
    put({seq:0,at:1,revision:0,kind:'assistant',final:true,blocks:[{type:'text',text:'Reply'}]});
    views.get(0).view.querySelector('.topic-new').onclick();
    put({kind:'topics',target:0,topics:['one'],seq:1,revision:0,at:2,final:true});renderDirty();
    return [topics.debug.interaction.naming,!!views.get(0).view.querySelector('.topic-new'),!!views.get(0).view.querySelector('.topic-input'),views.get(0).view.querySelector('.topic-name')?.title];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [null,false,false,'one']);
});

test('messages with a topic omit the naming control, including mixed reply sections', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};
    put({seq:0,at:1,revision:0,kind:'user',final:true,text:'With a topic',topic:'one',images:[],attachments:[]});
    put({seq:1,at:1,revision:0,kind:'user',final:true,text:'Without a topic',images:[],attachments:[]});
    put({seq:2,at:1,revision:0,kind:'assistant',final:true,blocks:[{type:'text',text:'First'},{type:'text',text:'Second',topic:'one'}]});
    return [0,1,2].map(seq=>!!views.get(seq).view.querySelector('.topic-new'));
  })()`);
  assert.deepEqual(Array.from(result), [false,true,false]);
});

test('message naming keeps focus and text through updates and ignores composing Enter and Escape', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'old'}]};
    const requests=[];fetchJSON=async(path,body)=>{requests.push(body);return {}};
    const results=[];
    for(const kind of ['user','assistant']){
      const seq=kind==='user'?0:1,item=kind==='user'?{seq,at:1,revision:0,kind,final:true,text:'Question',images:[],attachments:[]}:{seq,at:1,revision:0,kind,final:false,blocks:[{type:'text',text:'Reply'}]};
      put(item);views.get(seq).view.querySelector('.topic-new').onclick();const input=views.get(seq).view.querySelector('.topic-input');input.value='New topic';
      const key=(key,isComposing)=>({key,isComposing,preventDefault(){},stopPropagation(){}});
      input.onkeydown(key('Enter',true));input.onkeydown(key('Escape',true));
      put({...item,revision:1,...(kind==='user'?{text:'Updated'}:{blocks:[{type:'text',text:'Reply grows'}]})});renderDirty();
      results.push([document.activeElement===input,input.value,views.get(seq).view.querySelector('.topic-input')===input,requests.length]);input.onkeydown(key('Enter',false));
    }
    refreshComposer();element('field').querySelector('.topic-new').onclick();const input=element('field').querySelector('.topic-input');input.value='Composer';input.onkeydown({key:'Enter',isComposing:true,stopPropagation(){}});const composing=topics.composer();input.onkeydown({key:'Enter',isComposing:false,stopPropagation(){},preventDefault(){}});
    return [results,requests,composing,topics.composer()];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[[true,'New topic',true,0],[true,'New topic',true,1]],[{sessionId:'s',seq:0,topic:'New topic'},{sessionId:'s',seq:1,topic:'New topic'}],null,'Composer']);
});

test('assigned user topic chips edit on double click without changing the reply topic', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'reply'}]};put({seq:0,at:1,revision:0,kind:'user',final:true,text:'Question',topic:'one',images:[],attachments:[]});window.requests=[];fetchJSON=async(path,body)=>{window.requests.push([path,body]);return {}};window.key=value=>({key:value,preventDefault(){},stopPropagation(){}});window.openAssigned=()=>{const chip=views.get(0).view.querySelector('.topic-chip');chip.onclick({detail:1});chip.onclick({detail:2});chip.ondblclick({preventDefault(){},stopPropagation(){}});return views.get(0).view.querySelector('.topic-input')};topics.debug.setComposerTopic('reply');`);
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate(`(()=>{const input=window.openAssigned();return [input.value,input.selectionStart,input.selectionEnd,topics.composer()]})()`))), ['one',0,3,'reply']);
  evaluate(`views.get(0).view.querySelector('.topic-input').onkeydown(window.key('Escape'))`);
  assert.equal(evaluate(`views.get(0).view.querySelector('.topic-chip').dataset.topic`), 'one');
  evaluate(`window.openAssigned().onkeydown(window.key('Enter'))`);
  assert.equal(evaluate('window.requests.length'), 0);
  evaluate(`const input=window.openAssigned();input.value='new';input.onkeydown(window.key('Enter'));`);
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate('window.requests'))), [['/messages/topic',{sessionId:'s',seq:0,topic:'new'}]]);
  evaluate(`put({...items.get(0),revision:1,topic:'new'});renderDirty()`);
  assert.equal(evaluate(`views.get(0).view.querySelector('.topic-chip').dataset.topic`), 'new');
  evaluate(`views.get(0).view.querySelector('.topic-chip').onclick({detail:1})`);
  assert.equal(evaluate('topics.composer()'), 'new');
  evaluate(`window.openAssigned();views.get(0).view.querySelector('.topic-clear').onclick()`);
  assert.equal(evaluate(`views.get(0).view.querySelector('.topic-chip').dataset.topic`), 'new');
  evaluate(`topics.debug.scopeData(topics.scope()).filter='new';refreshTopicItems();resetting=true;renderDirty()`);
  assert.equal(evaluate(`!!views.get(0).view.querySelector('.topic-chip')`), false);
});

test('message naming sends its turn identity and cancels on Escape, outside click or session change', async () => {
  const app = await page(), evaluate = app.repl();
  evaluate(`state={...state,life:{type:'ready'},sessionId:'origin',view:{id:'root',path:[],type:'root'},topics:[{name:'old'}]};put({seq:0,at:1,revision:0,kind:'user',final:true,text:'Question',images:[],attachments:[]});window.requests=[];fetchJSON=async(path,body)=>{window.requests.push([path,body]);return {}};window.openName=()=>{views.get(0).view.querySelector('.topic-new').onclick();return views.get(0).view.querySelector('.topic-input')};window.key=value=>({key:value,preventDefault(){},stopPropagation(){}});`);
  assert.equal(evaluate(`(()=>{const input=window.openName();input.value='New topic';input.onkeydown(window.key('Enter'));return !!views.get(0).view.querySelector('.topic-name')})()`), false);
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate('window.requests'))), [['/messages/topic',{sessionId:'origin',seq:0,topic:'New topic'}]]);
  evaluate(`window.openName().onkeydown(window.key('Escape'));window.openName();views.get(0).view.querySelector('.topic-clear').onclick();window.openName()`);
  app.listeners.get('pointerdown')?.({ target:app.context.document.body });
  assert.equal(evaluate("!!views.get(0).view.querySelector('.topic-input')"), false);
  evaluate(`window.openName();topics.render();element('topics').querySelector('.topic-panel').querySelector('.topic-entry').querySelector('.topic-archive').onpointerdown({stopPropagation(){}})`);
  assert.equal(evaluate("!!views.get(0).view.querySelector('.topic-input')"), false);
  evaluate(`window.openName();state={...state,sessionId:'replacement'};refreshComposer()`);
  assert.deepEqual(JSON.parse(JSON.stringify(evaluate('[window.requests.length,topics.debug.interaction.naming,topics.composer(),topics.filter()]'))), [1,null,null,null]);
});

test('archive controls do not filter or drag and archived rows follow live rows without entering the capsule counts', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'archived',archived:true,last:{summary:'Old',at:30}},{name:'live',last:{summary:'Live',at:20}},{name:'older',archived:true,last:{summary:'Older',at:10}}]};topics.render();
    const text=root=>root.textContent+root.children.map(text).join(''),panel=element('topics').querySelector('.topic-panel'),rows=panel.querySelectorAll('.topic-entry'),order=rows.map(row=>row.dataset.topic),capsule=text(element('topics').querySelector('.topic-capsule'));
    const requests=[];let stopped=0;fetchJSON=async(path,body)=>{requests.push([path,body]);return {}};
    const action=rows[0].querySelector('.topic-archive');action.onpointerdown({stopPropagation(){stopped++}});action.onclick({stopPropagation(){stopped++}});
    rows[1].querySelector('.topic-archive').onclick({stopPropagation(){stopped++}});
    const actions=[rows[0].tagName,action.tagName,action.textContent,rows[1].querySelector('.topic-archive').textContent,stopped,topics.filter(),topics.debug.topicDragged,!!topics.debug.interaction.rename];
    topics.debug.setTopic('archived');const selected=element('topics').querySelector('.topic-capsule').querySelector('.topic-name').classList.contains('archived');
    topics.debug.setTopic(undefined);state={...state,topics:state.topics.map(topic=>({...topic,archived:true}))};topics.render();const empty=text(element('topics').querySelector('.topic-capsule'));
    return [order,capsule,requests,actions,selected,empty];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['live','archived','older'],'#live…',[['/topics/archive',{sessionId:'s',name:'live',archived:true}],['/topics/archive',{sessionId:'s',name:'archived',archived:false}]],['DIV','BUTTON','×','↺',3,null,false,false],true,'…']);
});

test('block topic updates preserve the scrolled panel position', async () => {
  const app=await page();
  const result=app.run(`(()=>{topics.measure.getBoundingClientRect=()=>({width:8});element('transcript').getBoundingClientRect=()=>({width:720});document.documentElement.clientWidth=1100;state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:Array.from({length:32},(_,index)=>({name:'topic-'+index,last:{summary:'Before',at:index}}))};topics.render();element('topics').querySelector('.topic-panel').scrollTop=140;apply({...state,type:'state',topics:state.topics.map(topic=>({...topic,last:{...topic.last,summary:'After'}}))});return element('topics').querySelector('.topic-panel').scrollTop})()`);
  assert.equal(result,140);
});

test('divider decoration movement and removal leave rhythm unchanged across rows and reply sections', async () => {
  const app=await page();
  const result=app.run(`(()=>{const list=element('items');list.hidden=false;const previous=node('div'),outside=node('div',undefined,'nrow'),root=node('div'),section=node('div',undefined,'reply-section'),a=node('div'),b=node('div'),first=node('div',undefined,'run'),second=node('div',undefined,'run');previous.dataset.seq='0';root.dataset.seq='1';previous.append(outside);a.append(first);b.append(second);section.append(a,b);root.append(section);list.replaceChildren(previous,root);views.set(0,{view:previous});views.set(1,{view:root});unitRows=seq=>{if(seq===0)return [{kind:'run',source:{kind:'block',seq:0,index:0}}];if(seq===1)return [0,2].map(index=>({kind:'run',source:{kind:'block',seq:1,index}}));throw Error('Unexpected row')};openers.set('run:1:2',{view:second});rhythm([previous,root]);const flags=()=>[outside.dataset.rhythm,first.dataset.rhythm],states=[flags()];applyScroll({...scrollDecision,divider:{seq:1,row:{kind:'run',source:{kind:'block',seq:1,index:2}}}},measure());states.push(flags());applyScroll({...scrollDecision,divider:{seq:1,row:{kind:'run',source:{kind:'block',seq:1,index:0}}}},measure());states.push(flags());applyScroll({...scrollDecision,divider:undefined},measure());states.push(flags());return states})()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)),[['compact','compact'],['compact','compact'],['compact','compact'],['compact','compact']]);
});

test('streamed prose in a run follower updates only its preceding rhythm neighbour', async () => {
  const app=await page();
  const result=app.run(`(()=>{element('items').hidden=false;state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]};topics.debug.setTopic('one');const tool={type:'tool',topic:'one',id:'tool',name:'bash',args:{text:'{}'},state:{type:'done',error:false,result:{text:'',cut:0,images:[]}}};const reply=(seq,blocks,revision=0)=>({seq,revision,at:1,kind:'assistant',final:true,blocks,stop:'stop',error:''});put({seq:0,revision:0,at:1,kind:'agent',final:true,topic:'one',direction:'in',from:{name:'helper'},inbound:{form:'report',relation:'child'},text:{text:'ready',cut:0}});put(reply(1,[tool]));put(reply(2,[{type:'text',topic:'two',text:'hidden boundary'}]));put(reply(3,[tool]));const previous=views.get(0).view.querySelector('.run'),next=views.get(3).view.querySelector('.run'),before=previous.dataset.rhythm;Object.defineProperty(next.dataset,'rhythm',{get:()=> 'ending',set:()=>{throw Error('Untouched row was rewritten')}});put(reply(1,[tool,{type:'text',topic:'one',text:'Streamed prose'}],1));return [before,previous.dataset.rhythm]})()`);
  assert.deepEqual(Array.from(result),['compact','block']);
});

test('topic modes switch at thirty measured cells and resize across the threshold', async () => {
  const app = await page();
  assert.deepEqual(Array.from(app.run(`[topics.debug.topicMode(720+28+29.9*8,720,8),topics.debug.topicMode(720+28+30*8,720,8)]`)),['line','block']);
  const result=app.run(`(()=>{topics.measure.getBoundingClientRect=()=>({width:8});element('transcript').getBoundingClientRect=()=>({width:720});state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};const modes=[];for(const width of [987.2,988,987.2]){document.documentElement.clientWidth=width;topics.render();resized([{target:element('scroll'),borderBoxSize:[{blockSize:560}]}]);modes.push(element('topics').dataset.mode)}return modes})()`);
  assert.deepEqual(Array.from(result),['line','block','line']);
});

test('the permanent topic block does not consume Escape', async () => {
  const app=await page();
  const result=app.run(`(()=>{topics.measure.getBoundingClientRect=()=>({width:8});element('transcript').getBoundingClientRect=()=>({width:720});document.documentElement.clientWidth=1100;state={...state,working:true,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};let stopped=0;stop=async()=>{stopped++};topics.render();return {get stopped(){return stopped},get hidden(){return element('topics').querySelector('.topic-panel').hidden}}})()`);
  app.listeners.get('keydown')?.({key:'Escape',target:app.context.document.body,preventDefault(){}});
  assert.equal(result.stopped,1);
  assert.equal(result.hidden,false);
});

test('line topic names apply their filter directly', async () => {
  const app=await page();
  const result=app.run(`state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};topics.render();element('topics').querySelector('.topic-capsule').querySelector('.topic-name').onclick?.();topics.filter()`);
  assert.equal(result,'one');
});

test('topic block rows toggle filters and line names filter without opening the panel', async () => {
  const app=await page();
  const result=app.run(`(()=>{topics.measure.getBoundingClientRect=()=>({width:8});element('transcript').getBoundingClientRect=()=>({width:720});document.documentElement.clientWidth=1100;state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one',last:{summary:'Last message',at:1}}]};topics.render();const block=[element('topics').dataset.mode,!element('topics').querySelector('.topic-capsule'),element('topics').querySelector('.topic-panel').hidden];element('topics').querySelector('.topic-entry').onclick({detail:0});block.push(topics.filter(),element('topics').querySelector('.topic-entry').classList.contains('current'));element('topics').querySelector('.topic-entry').onclick({detail:0});block.push(topics.filter());topics.debug.setTopic('one');element('topics').querySelector('.topic-all').onclick();block.push(topics.filter());document.documentElement.clientWidth=600;topics.render();const capsule=element('topics').querySelector('.topic-capsule');capsule.querySelector('.topic-name').onclick();const line=[topics.filter(),element('topics').querySelector('.topic-panel').hidden];topics.debug.setTopic(undefined);element('topics').querySelector('.topic-overflow').onclick();line.push(element('topics').querySelector('.topic-panel').hidden);return [block,line]})()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)),[['block',true,false,'one',true,null,null],['one',true,false]]);
});

test('the capsule shows every name when all measured names fit', async () => {
  const app = await page();
  const result = app.run(`
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:['one','two','three'].map((name,index)=>({name,last:{summary:name,at:3-index}}))};
    topics.render();
    element('topics').querySelector('.topic-open').children.filter(node=>node.classList.contains('topic-name')).map(node=>node.dataset.topic);
  `);
  assert.deepEqual(Array.from(result),['one','two','three']);
});

test('measured capsule overflow and resize keep whole names and skip unchanged streaming state', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},topics:['one','two','three'].map((name,index)=>({name,last:{summary:name,at:3-index}}))};topics.render();
    const capsule=element('topics').querySelector('.topic-capsule'),button=capsule.querySelector('.topic-open');
    capsule.getBoundingClientRect=()=>({width:100});button.getBoundingClientRect=()=>({width:80});
    const nameWidths={one:80,two:90,three:100};
    const widthOf=child=>{if(child.classList.contains('topic-name'))return nameWidths[child.dataset.topic];if(child.classList.contains('topic-separator'))return 10;if(child.classList.contains('topic-more'))return 25;if(child.classList.contains('topic-overflow'))return 10;throw Error('Unexpected capsule child')};
    const rect=Node.prototype.getBoundingClientRect,style=getComputedStyle;
    Node.prototype.getBoundingClientRect=function(){if(this.parent!==button)return rect.call(this);const before=button.children.slice(0,button.children.indexOf(this));return {width:widthOf(this),right:before.reduce((sum,child)=>sum+widthOf(child)+5,0)+widthOf(this)}};
    getComputedStyle=node=>({...style(node),columnGap:'5px'});
    let reads=0;
    Object.defineProperty(button,'scrollWidth',{get(){reads++;return Math.round(button.children.reduce((sum,child)=>sum+widthOf(child),5*(button.children.length-1)))}});
    const snapshot=()=>[button.children.filter(child=>child.classList.contains('topic-name')).map(child=>child.dataset.topic),button.querySelector('.topic-more')?.textContent??''];
    topics.debug.fitTopics(500);const all=snapshot();
    document.documentElement.clientWidth=300;resized([{target:element('scroll'),borderBoxSize:[{blockSize:560}]}]);const overflow=snapshot();
    document.documentElement.clientWidth=200;resized([{target:element('scroll'),borderBoxSize:[{blockSize:560}]}]);const smaller=snapshot();
    document.documentElement.clientWidth=400;resized([{target:element('scroll'),borderBoxSize:[{blockSize:560}]}]);const larger=snapshot();
    const before=reads;apply({...state,type:'state',topics:state.topics.map(topic=>({...topic,last:{...topic.last,summary:'Streaming'}}))});const unchanged=reads===before;
    document.documentElement.clientWidth=120;resized([{target:element('scroll'),borderBoxSize:[{blockSize:560}]}]);
    const smallest=snapshot(),single=button.classList.contains('single');
    Object.assign(nameWidths,{one:80.2,two:90.2,three:100.2});topics.debug.fitTopics(286);const fractionalFit=snapshot();
    Object.assign(nameWidths,{one:80.1,two:90.2,three:100.1});topics.debug.fitTopics(285.95);const fractionalOverflow=snapshot();
    return [all,overflow,smaller,larger,unchanged,smallest,single,fractionalFit,fractionalOverflow];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)),[[['one','two','three'],''],[['one','two'],'+1'],[['one'],'+2'],[['one','two','three'],''],true,[['one'],'+2'],true,[['one','two'],'+1'],[['one'],'+2']]);
  assert.equal(app.observers.length,1);
});

test('topic ages use now, minutes, hours and days', async () => {
  const app = await page();
  assert.deepEqual(Array.from(app.run(`[topics.debug.topicAge(0,59000),topics.debug.topicAge(0,60000),topics.debug.topicAge(0,3600000),topics.debug.topicAge(0,86400000)]`)), ['now','1m','1h','1d']);
});

test('topic capsules sort activity, keep palette identity and show the filter controls', async () => {
  const app = await page();
  const result = app.run(`
    const text=node=>node.textContent+node.children.map(text).join('');
    state={...state,name:'pi',life:{type:'ready'},view:{id:'root',path:[],type:'root'},sessionId:'s',topics:[{name:'one',last:{summary:'**First**',at:1}},{name:'two',last:{summary:'Second',at:2}}]};
    topics.render();const two=text(element('topics').querySelector('.topic-capsule'));
    state={...state,topics:[state.topics[0]]};topics.render();const one=text(element('topics').querySelector('.topic-capsule'));
    state={...state,topics:['one','two','three','four','five','six','seven'].map((name,index)=>({name,last:{summary:name,at:index+1}}))};
    topics.render();const many=text(element('topics').querySelector('.topic-capsule'));
    const colours=[topics.debug.topicColour('one'),topics.debug.topicColour('two'),topics.debug.topicColour('seven')];
    state={...state,topics:[...state.topics,{name:'pending-old'},{name:'pending-new'}]};topics.render();const pendingNames=element('topics').querySelector('.topic-open').children.filter(node=>node.classList.contains('topic-name')).slice(0,2).map(node=>node.dataset.topic);
    topics.debug.setTopic('two');topics.render();refreshComposer();
    const filtered=text(element('topics').querySelector('.topic-capsule')),foot=!!element('field').querySelector('.topic-cell'),placeholder=element('prompt').children[0].placeholder;
    topics.debug.toggleTopics();const panel=!element('topics').querySelector('.topic-panel').hidden;
    [one,two,many,colours,filtered,foot,placeholder,panel,pendingNames];
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), ['#one…','#two·#one…','#seven·#six·#five·#four·#three·#two·#one…',['var(--topic-0)','var(--topic-1)','var(--topic-0)'],'#two×',false,'Message koa…',true,['pending-new','pending-old']]);
});

test('unfiltered roots keep the original foot and wrap replies without a topic', async () => {
  const app = await page();
  const html = await readFile(new URL('page/page.html', import.meta.url), 'utf8');
  const first = html.match(/<div class="foot"><span id="([^"]+)"/)?.[1];
  assert.ok(first);
  const result = app.run(`(()=>{
    const foot=node('div'),model=element('model-cell'),initial=element(${JSON.stringify(first)});model.id='model-cell';initial.id=${JSON.stringify(first)};foot.append(initial);if(initial!==model)foot.append(model);
    const cases=[];
    for(const names of [[],[{name:'work'}]]){
      state={...state,life:{type:'ready'},view:{id:'root',path:[],type:'root'},sessionId:'old-dom',topics:names};topics.render();
      const item={kind:'assistant',seq:0,revision:1,at:1,final:true,blocks:[{type:'text',text:'plain reply'}],stop:'stop',error:''};accept(item);renderItem(visible(0));
      const reply=views.get(0).view;cases.push([foot.children[0].id,foot.children.some(child=>child.className.includes('topic-')),reply.children.map(child=>child.className),reply.querySelectorAll('.topic-section,.topic-mark,.topic-name').length]);
    }
    return cases;
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['model-cell',false,['reply-section'],0],['model-cell',false,['reply-section'],0]]);
});

test('a filtered composer keeps the working and compaction verbs', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,name:'ko',life:{type:'ready'},view:{id:'root',path:[],type:'root'},sessionId:'verb',topics:[{name:'work'}]};topics.debug.setTopic('work');
    const hints=[];
    for(const [working,compaction] of [[true,'idle'],[true,'running'],[false,'idle']]){state={...state,working,compaction};refreshComposer();hints.push(element('prompt').children[0].placeholder)}
    return hints;
  })()`);
  assert.deepEqual(Array.from(result), ['Steer koa…','Message koa…','Message koa…']);
});

test('reply sections never draw a topic edge', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,life:{type:'ready'},view:{id:'root',path:[],type:'root'},sessionId:'edges',topics:[{name:'work'}]};
    for(let seq=0;seq<3;seq++)accept({kind:'assistant',seq,revision:1,at:1,final:true,blocks:[{type:'text',text:'part',topic:'work'}],stop:'stop',error:''});
    accept({kind:'user',seq:3,revision:1,at:1,final:true,text:'break',images:[],attachments:[]});
    accept({kind:'assistant',seq:4,revision:1,at:1,final:true,blocks:[{type:'text',text:'after',topic:'work'}],stop:'stop',error:''});
    renderDirty();
    const sections=[0,1,2,4].map(seq=>views.get(seq).view.children[0]);
    sections.forEach((section,index)=>section.getBoundingClientRect=()=>({top:[10,40,75,120][index],bottom:[30,60,100,150][index],height:30,width:100,left:0,right:100}));
    renderDirty();
    return sections.map(section=>[section.classList.contains('topic-edge'),section.style.getPropertyValue('--topic-edge-height')||null]);
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[false,null],[false,null],[false,null],[false,null]]);
});

test('only pending implicit users show under a filter and chips stay on reply sections', async () => {
  const app = await page();
  const result = app.run(`
    state={...state,working:true,view:{id:'root',path:[],type:'root'},sessionId:'s',topics:[{name:'one'},{name:'two'}]};
    const user=seq=>({kind:'user',seq,revision:1,at:1,final:true,text:'request',images:[],attachments:[]});
    const reply=(seq,blocks)=>({kind:'assistant',seq,revision:1,at:2,final:true,blocks,stop:'stop',error:''});
    accept(user(0));topics.debug.setTopic('one');const waits=!!visible(0);
    if(visible(0))renderItem(visible(0));const waiting=views.get(0)?.view.querySelector('.topic-waiting')?.textContent;
    accept({kind:'topics',seq:1,revision:1,at:2,final:true,target:0,topics:['two']});const removed=!visible(0);
    accept(user(2));accept({kind:'topics',seq:3,revision:1,at:2,final:true,target:2,topics:['one']});const stayed=!!visible(2);
    accept(user(4));const waitingAgain=!!visible(4);apply({...state,type:'state',working:false});const settled=!visible(4);
    topics.debug.setTopic(undefined);
    accept(reply(5,[{type:'text',topic:'one',text:'First'}]));
    accept(user(6));accept(reply(7,[{type:'text',topic:'one',text:'Same'},{type:'text',text:'Without a topic'},{type:'text',topic:'two',text:'Other'}]));
    renderItem(visible(5));renderItem(visible(6));renderItem(visible(7));
    const marks=seq=>views.get(seq).view.querySelectorAll('.reply-section>.msg>.message-header>.topic-chip').map(mark=>mark.dataset.topic).filter(Boolean);
    accept({kind:'agent',seq:8,revision:1,at:2,final:true,topic:'two',direction:'in',from:{name:'worker'},inbound:{form:'report',relation:'child'},text:{text:'done',cut:0}});renderItem(visible(8));renderItem(visible(7));
    accept({kind:'job',seq:9,revision:1,at:2,final:true,topic:'one',job:{id:'j',name:'verify',service:false,command:'true',log:'/tmp/job',place:{type:'mac'},startedAt:1},event:{type:'ended',end:{type:'exit',code:0},tail:{text:'',cut:0}}});renderItem(visible(9));reconcileRuns();
    [waits,waiting,removed,stayed,waitingAgain,settled,marks(5),marks(6),marks(7),marks(8),marks(9)];
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(result)),[true,null,true,true,true,true,['one'],[],['one','two'],[],[]]);
});

test('a resumed session publishes its scope before reset and commits after ready', async () => {
  const app = await page();
  const result = app.run(`
    state={...state,sessionId:'old',view:{id:'root',path:[],type:'root'},topics:[{name:'one'}]};
    fetch=async()=>({ok:true,json:async()=>({epoch:'new',more:false,items:[]})});
    topics.debug.setTopic('one');
    apply({...state,type:'state',sessionId:'new',life:{type:'switching'},topics:[{name:'two'}]});
    apply({type:'reset',epoch:'new',more:false,items:[{kind:'user',seq:0,revision:1,at:1,final:true,topic:'two',text:'new session',images:[],attachments:[]}]});
    for(let frame=0;frame<4;frame++)tick();
    const waiting=transition?.phase.kind==='state';
    apply({...state,type:'state',life:{type:'ready'}});
    for(let frame=0;frame<8;frame++)tick();
    [waiting,order.includes(0),transcriptHistory.debug.request?.topic===undefined,!transition];
  `);
  assert.deepEqual(Array.from(result), [true,true,true,true]);
});

test('a saved target filter survives preparation until the ready state reconciles topics', async () => {
  for (const life of ['starting', 'reloading', 'switching']) {
    const app = await page();
    app.context.history.replaceState({ scroll: [], drafts: [], filters: [['root:new', 'target']], composerTopics: [] });
    const result = await app.run(`(async()=>{
      if('${life}'!=='starting')state={...state,life:{type:'ready'},sessionId:'old',view:{id:'root',path:[],type:'root'},topics:[{name:'old-topic'}]};
      rendered=async()=>{};fetch=async()=>({ok:true,json:async()=>({epoch:'new',items:[],more:false})});
      apply({...state,type:'state',view:{id:'root',path:[],type:'root'},sessionId:'new',life:{type:'${life}'},topics:[]});
      apply({type:'reset',epoch:'new',items:[],more:false});
      const preparing=topics.filter();
      apply({...state,type:'state',life:{type:'ready'},topics:[{name:'target'}]});
      await transcriptHistory.debug.request?.done;
      return [preparing,topics.filter()];
    })()`);
    assert.deepEqual(Array.from(result), ['target', 'target'], life);
  }
});

test('topic changes discard in-flight history and composer sends only the active root filter', async () => {
  const app = await page();
  const result = await app.run(`(async()=>{
    state={...state,sessionId:'s',view:{id:'root',path:[],type:'root'},life:{type:'ready'},topics:[{name:'one'},{name:'two'}]};
    epoch='e';const held=[];rendered=async()=>{};fetch=async()=>new Promise(resolve=>{held.push(resolve)});
    topics.debug.setTopic('one');const previous=transcriptHistory.debug.request;
    topics.debug.setTopic('two');const current=transcriptHistory.debug.request;
    held[1]({ok:true,json:async()=>({epoch:'e',more:false,items:[{kind:'user',seq:2,revision:1,at:1,final:true,topic:'two',text:'two',images:[],attachments:[]}]})});
    await current.done;
    held[0]({ok:true,json:async()=>({epoch:'e',more:false,items:[{kind:'user',seq:0,revision:1,at:1,final:true,topic:'one',text:'stale',images:[],attachments:[]}]})});
    await previous.done;
    const dropped=!items.has(0);
    for(let frame=0;frame<8;frame++)tick();
    const filterCommitted=!transition;
    let sent;fetchJSON=async(path,body)=>{sent=body;return {disposition:'started'}};
    editor.setText('hello');await send();
    const two=sent.topic;
    const {topics:unused,...childState}=state;
    apply({...childState,type:'state',sessionId:'child',view:{id:'child',path:[],type:'subagent'}});apply({type:'reset',epoch:'child',items:[],more:false});
    for(let frame=0;frame<8;frame++)tick();
    const childCommitted=!transition;
    editor.setText('child');await send();
    const child=sent.topic;
    apply({...state,type:'state',sessionId:'s',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]});apply({type:'reset',epoch:'root',items:[],more:false});
    return [previous!==current,dropped,two,child===undefined,topics.filter(),transcriptHistory.debug.before,filterCommitted,childCommitted];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [true, true, 'two', true, 'two', null, true, true]);
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
  app.run("state={...state,life:{type:'ready'}};draft.restore([{id:'file',name:'note.txt',path:'/tmp/note.txt',kind:'file',size:4}]);editor.setText('/name saved')");
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

test("file drops attach bytes without inserting text and send their ids", async () => {
  const app = await page();
  app.run("state={...state,life:{type:'ready'}};refreshComposer();editor.setText('draft')");
  assert.equal(typeof app.listeners.get('drop'), 'function');
  const requests: { path: string; body: unknown }[] = [];
  let uploaded: () => void = () => {};
  const complete = new Promise<void>(resolve => { uploaded = resolve; });
  app.context.fetch = async (path?: string, options?: { body?: unknown }) => {
    const body = typeof options?.body === 'string' ? JSON.parse(options.body) : options?.body;
    requests.push({ path: path ?? '', body });
    if (path === '/attachments') { assert.deepEqual(body, { name: 'note.txt', type: 'text/plain', size: 4 }); return { ok: true, json: async () => ({ id: 'copy', path: '/tmp/attachments/copy/note.txt' }) }; }
    if (path === '/attachments/copy/0') { assert.ok(ArrayBuffer.isView(body)); assert.equal(Buffer.from(body.buffer, body.byteOffset, body.byteLength).toString(), 'note'); uploaded(); return { ok: true, json: async () => ({ received: 4, attachment: { id: 'copy', path: '/tmp/attachments/copy/note.txt', name: 'note.txt', size: 4, kind: 'file' } }) }; }
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
  app.run("state={...state,life:{type:'ready'}};refreshComposer();editor.setText('draft')");
  app.handlers()?.send('follow_up');
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, [{ path: '/prompt', body: { text: 'draft', mode: 'follow_up', attachments: [] } }]);
  app.handlers()?.quit();
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(requests[1]?.path, '/quit');
});

async function connectSource(name: string) {
  const source = stripTypeScriptTypes(await readFile(new URL(name, import.meta.url), "utf8"));
  return source.slice(source.indexOf("let source"), source.indexOf("const sessionHost"));
}

test("starting and switching show a placeholder over an inert field and no status cell", async () => {
  const app = await page();
  const result = app.run(`
    const hint=()=>element('prompt').children[0].placeholder, seen=[];
    state={...state,life:{type:'starting'}};refreshComposer();seen.push([hint(),element('field').inert]);
    state={...state,life:{type:'switching'}};refreshComposer();seen.push([hint(),element('field').inert]);
    state={...state,life:{type:'ready'},working:true,since:0};refreshComposer();seen.push([element('field').inert]);
    seen;
  `);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['Starting pi…', true], ['Loading…', true], [false]]);
  assert.equal(app.elements.has('status'), false);
  assert.equal(app.elements.has('dot'), false);
});

test("printable transcript keys cannot change the draft during startup", async () => {
  const app = await page();
  app.run("refreshComposer()");
  app.listeners.get('keydown')?.({ key: 'z', target: app.context.document.createElement('div'), preventDefault() {} });
  assert.equal(app.text(), '');
});

test("composer gains focus when delayed pi readiness removes inert", async () => {
  const app = await page();
  app.run("state={...state,life:{type:'starting'}};refreshComposer();focusComposer()");
  app.windowListeners.get('load')?.();
  assert.equal(app.context.document.activeElement, undefined);
  app.run("state.life={type:'ready'};refreshComposer()");
  assert.equal(app.context.document.activeElement, app.prompt());
});

test("async send and dialog completion preserve focus while the document lacks focus", async t => {
  for (const action of ['send', 'dialog', 'picker']) await t.test(action, async () => {
    const app = await page();
    app.context.document.hasFocus = () => false;
    let release: () => void = () => {};
    app.context.fetch = async () => { await new Promise<void>(resolve => { release = resolve; }); return { ok: true, json: async () => ({}) }; };
    const pending = action === 'send' ? app.run("state={...state,life:{type:'ready'}};editor.setText('draft');send()") : undefined;
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
  const controls = app.run(`state={...state,life:{type:'ready'}};refreshComposer();focusComposer();({
    picker(){state.levels=['off','low'];return picker('thinking')},
    working(){closePicker();state.working=true;refreshComposer()},
    dialog(method){state.dialogs=[{id:method,method,title:'Question',options:['One'],message:'Proceed?'}];refreshComposer();dialogs()},
    clear(){state.dialogs=[];document.body.focus();refreshComposer();dialogs()},
    preview(){preview('/images/0',element('model'),'image',composerFocus)},
    closePreview(){previewKey({key:'Escape',preventDefault(){},stopPropagation(){}})},
    exit(){state.life={type:'failed',at:1,message:''};refreshComposer();exited()}
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
  app.run("state={...state,life:{type:'ready'}};refreshComposer();focusComposer()");
  assert.equal(app.context.document.activeElement, undefined);
  app.windowListeners.get('load')?.();
  assert.equal(app.context.document.activeElement, undefined);
  focused = true;
  app.windowListeners.get('focus')?.();
  assert.equal(app.context.document.activeElement, app.prompt());
});

test("pane focus selects the composer without taking page controls or dialog fields", async () => {
  const app = await page();
  app.run("state={...state,life:{type:'ready'},dialogs:[]};element('model').tagName='BUTTON';editor.focus()");
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

test('C-g from the transcript opens the editor but not from a dialog', async () => {
  const app = await page();
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({ pane: 'pane_10' }) }; };
  app.run("state={...state,life:{type:'ready'},sessionId:'s1'};refreshComposer();element('messages').focus()");
  let prevented = 0;
  const key = () => app.listeners.get('keydown')?.({ key: 'g', ctrlKey: true, target: app.context.document.activeElement, preventDefault() { prevented++; } });
  key();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(requests, ['/editor/open']);
  assert.equal(prevented, 1);
  app.run("state.dialogs=[{id:'q',method:'input',title:'Question'}];dialogs()");
  key();
  assert.deepEqual(requests, ['/editor/open']);
  assert.equal(prevented, 1);
});

test("printable transcript keys reach the composer but native shortcuts and fields keep their keys", async () => {
  const app = await page();
  app.run("state={...state,life:{type:'ready'},dialogs:[]}");
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
  const { view, line } = app.run("state={...state,life:{type:'ready'},dialogs:[]};const view=node('div'),line=node('div');fold(view,'fold',line,node('div'));line.focus();({view,line})");
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
    await app.run("state={...state,life:{type:'ready'},dialogs:[],levels:['off','low'],thinking:'off'};picker('thinking')");
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

test("the transcript page hands each SSE record to apply at intake and reconnects with the applied cursor", async () => {
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
    const context = { metrics: undefined, probe: undefined, koaInstance: "i1", reloading: false, epoch: "", after: -1, delay: 200, disconnected: false, EventSource, Error, console: { error() {} }, window: { addEventListener(name: string, handler: (event?: { persisted: boolean }) => void) { if (name === "pagehide") teardown = handler; else if (name === "pageshow") restore = handler; } }, apply(record: { type: string; epoch?: string; after?: number }) {
      if (record.type === "bad") throw Error("Apply failed");
      received.push(record);
      if (record.epoch) context.epoch = record.epoch;
      if (record.after !== undefined) context.after = record.after;
    }, element: () => error, schedule() {}, setTimeout(callback: () => void) { retries.push(callback); }, clearTimeout() {} };
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
    const waiting: (() => void)[] = [], metrics = { mode, bytes: 0, pending: [], samples: [], frames: new Set(), timer: undefined, waiting };
    class EventSource {
      onmessage?: (event: { data: string }) => void;
      constructor() { queueMicrotask(() => this.onmessage?.({ data: '{"type":"flush","id":7,"t":1000,"bytes":1234}' })); }
    }
    runInNewContext(connect + ";connect()", { metrics, probe: undefined, document: { hidden: false }, koaInstance: "i1", EventSource, window: { addEventListener() {} }, epoch: "", after: -1, delay: 200, console, element: () => ({}), schedule() {}, performance: { timeOrigin: 1000, now: () => 12 }, Date: { now: () => 1012 }, sendMetrics() {}, setTimeout() {} });
    await Promise.resolve();
    assert.equal(metrics.waiting.length, mode === "frame" ? 1 : 0);
    for (const waiter of metrics.waiting.splice(0)) waiter();
    assert.deepEqual(JSON.parse(JSON.stringify(metrics.samples)), [{ t: 1000, [mode]: 1012, bytes: 1234, clockError: 0, ...mode === "frame" && { stages: { id: 7, received: 1012, visibility: "visible" } } }]);
  }
});

test("finished prose and view change checks retain no extra text strings", async () => {
  const app = await page();
  const retained = app.run("const text='payload '.repeat(10000);put({seq:0,kind:'assistant',final:true,blocks:[{type:'text',text}]});({source:texts.get('0:0').source,signature:views.get(0).signature})");
  assert.deepEqual({ source: retained.source?.length ?? 0, signature: retained.signature?.length ?? 0 }, { source: 0, signature: 0 });
  assert.equal(app.run("const initial={seq:1,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:'first'}]};put(initial);apply({type:'patch',baseRevision:0,revision:1,seq:1,final:false,blocks:[{index:0,suffix:' last'}]});renderDirty();const updated=items.get(1),streaming=texts.get('1:0').source==='first last';apply({type:'patch',baseRevision:1,revision:2,seq:1,final:true,stop:'',error:'',blocks:[]});renderDirty();initial!==updated&&initial.blocks!==updated.blocks&&initial.blocks[0]!==updated.blocks[0]&&initial.blocks[0].text==='first'&&streaming&&texts.get('1:0').source===undefined&&views.get(1).item===items.get(1)"), true);
  assert.equal(app.run("const finished={seq:0,revision:0,kind:'assistant',final:true,blocks:[{type:'text',text:'same'}]};put(finished);const proseView=texts.get('0:0').view;put({...finished,blocks:[{type:'text',text:'same'}]});apply({type:'patch',baseRevision:0,revision:1,seq:0,final:true,stop:'stop',ended:42,blocks:[]});renderDirty();texts.get('0:0').view===proseView&&items.get(0).stop==='stop'&&items.get(0).ended===42"), true);
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
    if (stepInfo({kind:'block',index:0,block:item.blocks[0],item,args:{}}).detail!=='Plan') throw Error('Markdown syntax in summary');
    const view=run([{kind:'block',block:item.blocks[0],item,index:0,key:'0:0'}]);
    const step=view.children[1].children[0];
    if (step.children[1].children.length) throw Error('Collapsed details have children');
    step.children[0].onclick();
    if (texts.get('0:0').view.className!=='think prose') throw Error('Missing Markdown class');
    apply({type:'patch',baseRevision:0,revision:1,seq:0,final:false,blocks:[{index:0,suffix:' and **more'}]});renderDirty();
    if (texts.get('0:0').source!=='**Plan**\\n\\n- Use \`code\` and **more') throw Error('Stale thinking');
    folds.set('0:0',false);
    apply({type:'patch',baseRevision:1,revision:2,seq:0,final:false,blocks:[{index:0,suffix:' words**'}]});renderDirty();
    if (texts.get('0:0').source!=='**Plan**\\n\\n- Use \`code\` and **more') throw Error('Collapsed thinking updated');
    folds.set('0:0',true);apply({type:'patch',baseRevision:2,revision:3,seq:0,final:true,blocks:[]});renderDirty();
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
    const view=run([{kind:'block',block,item,index:0,key:'0:0'}]);
    const detail=view.children[1].children[0].children[1].children[0];
    return detail.className==='think redacted'&&detail.textContent===(text||'Redacted thinking')&&detail.children.length===0&&stepInfo({kind:'block',index:0,block,item,args:{}}).detail==='redacted';
  })`), true);
});

test("a run joins adjacent assistant items without replacing their text views", async () => {
  const app = await page();
  assert.equal(app.run("const firstSlot=node('div'),secondSlot=node('div');items.set(0,{seq:0,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'thinking',text:'check'}]});items.set(1,{seq:1,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'tool',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'ok',images:[]}}}]});views.set(0,{slots:new Map([['0:0',{type:'run',view:firstSlot}]])});views.set(1,{slots:new Map([['1:0',{type:'run',view:secondSlot}]])});run=steps=>({count:steps.length});reconcileRuns();firstSlot.children[0].count===2&&secondSlot.children.length===0"), true);
});

test("invalid tool arguments do not stop rendering", async () => {
  const app = await page();
  for (const text of ["null", '{"path":"file","oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":"old","newText":"new"}']) {
    assert.doesNotThrow(() => app.run(`run([{kind:'block',key:'0:0',index:0,item:{final:true,stop:'stop',blocks:[]},block:{type:'tool',name:'edit',args:{text:${JSON.stringify(text)}},state:{type:'done',error:false,result:{text:'done',images:[]}}}}])`));
  }
});

test("a pending tool shows its name until its label arguments arrive", async () => {
  const app = await page();
  const labels = app.run(`
    put({seq:1,revision:0,at:0,kind:'assistant',final:false,blocks:[{type:'tool',id:'call',name:'bash',args:{text:'{}'},state:{type:'pending'}}]});
    const label=()=>{const item=items.get(1);return run([{kind:'block',key:'1:0',index:0,item,block:item.blocks[0]}]).children[1].children[0].children[0].children[1].children.map(c=>c.textContent).join('').trim();};
    const before=label();
    apply({type:'patch',baseRevision:0,revision:1,seq:1,final:false,blocks:[{index:0,block:{type:'tool',id:'call',name:'bash',args:{text:JSON.stringify({command:'make verify'})},state:{type:'pending'}}}]});
    [before,label()];
  `);
  assert.deepEqual(Array.from(labels), ['bashbash', 'bashmake verify']);
  assert.equal(app.run(`['bash','read','edit','write','custom'].every(name=>{
    const block={type:'tool',name,args:{text:'{}'},state:{type:'pending'}};
    return stepInfo({kind:'block',index:0,block,item:{final:false},args:{}}).label===name;
  })`), true);
  assert.equal(app.run(`['pending','running','done','not_run'].every(type=>{
    const block={type:'tool',name:'bash',args:{text:'{}'},state:{type}};
    return stepInfo({kind:'block',index:0,block,item:{final:true},args:{}}).label==='bash {}';
  })`), true);
});

test("ended thinking is not active while assistant text streams", async () => {
  const app = await page();
  assert.equal(app.run("const block={type:'thinking',text:'done',started:1,ended:2};const item={final:false,blocks:[block,{type:'text',text:'streaming'}]};run([{kind:'block',block,item,index:0,key:'0:0'}]).children[0].children[0].children.some(child=>child?.className==='dots')"), false);
});

test("model picker matches provider and id", async () => {
  const app = await page();
  const selected: object[] = [];
  app.context.fetch = async (_path?: string, options?: {body?: string}) => { if (options?.body) selected.push(JSON.parse(options.body)); return {ok:true,json:async()=>({models:[{id:'same',provider:'one'},{id:'same',provider:'two'}]})}; };
  const result = await app.run("state={...state,life:{type:'ready'},model:{id:'same',provider:'two'}};picker('model').then(()=>{const host=element('picker');const ticks=host.children.filter(child=>child.classList.contains('row')).map(row=>row.children[0].textContent).join(',');host.onkeydown({key:'Enter',preventDefault(){},stopPropagation(){}});return ticks})");
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
  app.run("state={...state,life:{type:'ready'},working:true,dialogs:[],queue:{steering:[{text:'first queued',attachments:[]}],followUp:[{text:'second queued',attachments:[]}],classifying:[]}}");
  app.listeners.get("keydown")?.({ key: "Escape", preventDefault() {} });
  await done;
  assert.deepEqual(commands, ["clear_queue", "abort"]);
  assert.deepEqual(started, []);
  assert.equal(app.text(), "first queued\n\nsecond queued");
});

test("editor acknowledgment keeps the second Escape clear action", async () => {
  const app = await page();
  const control = app.run("state={...state,life:{type:'ready'}};refreshComposer();editor.setText('draft');({ack:()=>apply({...state,type:'state',editor:{id:'one',text:'replacement'}}),escaped:()=>escaped})");
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
  assert.equal(app.run("apply({type:'state',view:{id:'v',path:[]},bash:[],cwd:'',home:'',life:{type:'starting'},dialogs:[{id:'trust',method:'select',title:'Trust project?',options:['Yes','No']}],queue:{steering:[],followUp:[],classifying:[]}});!element('composer').hidden&&element('field').inert&&element('dialogs').children[0].className==='dialog'"), true);
});

test("a state record preserves a typed dialog answer", async () => {
  const app = await page();
  assert.equal(app.run("state={...state,life:{type:'ready'},working:true,dialogs:[{id:'a',method:'input',title:'Question'}]};refreshComposer();dialogs();const form=element('dialogs').children[0];const input=form.children[1];input.value='typed';state={...state,dialogs:[{id:'a',method:'input',title:'Question'}]};dialogs();apply({type:'reset',epoch:'next',more:false,items:[]});element('dialogs').children[0]===form&&input.value==='typed'&&element('prompt').children[0].placeholder==='Message koa…'&&element('field').inert"), true);
});

test("a queued block's × removes that entry only and leaves the draft alone", async () => {
  const app = await page();
  const requests: { path: string; body: unknown }[] = [];
  app.context.fetch = async (path?: string, options?: { body?: string }) => { requests.push({ path: path ?? '', body: JSON.parse(options?.body ?? '{}') }); return { ok: true, json: async () => ({}) }; };
  app.run("dialogs=()=>{};exited=()=>{};editor.setText('draft');apply({...state,type:'state',sessionId:'s1',life:{type:'ready'},queue:{steering:[{text:'a',attachments:[]},{text:'b',attachments:[]}],followUp:[{text:'c',attachments:[]}],classifying:[]}})");
  assert.deepEqual(app.run("element('queue').children.map(row=>row.dataset.kind+':'+row.children[1].textContent)"), ['steer:steer', 'steer:steer', 'follow-up:follow-up']);
  assert.deepEqual(JSON.parse(String(app.run("apply({...state,type:'state',queue:{steering:[{text:'**bold** first\\nsecond',attachments:[{id:'a',kind:'file'},{id:'b',kind:'file'}]}],followUp:[],classifying:[]}});const row=element('queue').children[0];JSON.stringify([row.children.map(c=>c.className),row.children[0].textContent,row.children[1].children.at(-1).textContent])"))), [['t', 'att', 'kind'], 'bold first', '2']);
  app.run("apply({...state,type:'state',sessionId:'s1',queue:{steering:[{text:'a',attachments:[]},{text:'b',attachments:[]}],followUp:[{text:'c',attachments:[]}],classifying:[]}})");
  app.run("element('queue').children[2].querySelector('.attach-remove').onclick()");
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(requests, [{ path: '/queue/remove', body: { sessionId: 's1', kind: 'follow-up', index: 0, text: 'c' } }]);
  assert.equal(app.text(), 'draft');
});

test('a dock that grows or shrinks keeps a bottom view at the bottom and a scrolled-up view in place', async () => {
  const page = await flowPage();
  page.pad.value = 400;
  page.deliver({ type: 'item', item: page.text(0) });
  page.settle(60);
  page.evaluate('dockResized(170)');
  page.pad.value += 40;
  page.settle(60);
  assert.equal(page.top(), page.bottom());
  page.reader(123);
  page.pad.value += 20;
  page.evaluate('dockResized(190)');
  page.settle(60);
  assert.equal(page.top(), 123);
});

test('a remove that leaves unsent entries puts them into the draft and reports the error', async () => {
  const app = await page();
  app.context.fetch = async () => ({ ok: false, json: async () => ({ error: 'refused', unsent: { steering: [{ text: 'first', attachments: [] }], followUp: [{ text: 'later', attachments: [] }] } }) });
  app.run("dialogs=()=>{};exited=()=>{};editor.setText('draft');apply({...state,type:'state',sessionId:'s1',life:{type:'ready'},queue:{steering:[{text:'x',attachments:[]}],followUp:[],classifying:[]}});element('queue').children[0].querySelector('.attach-remove').onclick()");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.text(), 'draft\n\nfirst\n\nlater');
  assert.equal(app.run("element('error').textContent"), 'refused');
});

test("unchanged state keeps queue controls and status nodes and acknowledges editor once", async () => {
  const app = await page();
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return {ok:true,json:async()=>({})}; };
  assert.equal(app.run("dialogs=()=>{};exited=()=>{};const record={...state,type:'state',life:{type:'starting'},queue:{steering:[{text:'queued',attachments:[]}],followUp:[],classifying:[]},statuses:{tests:'ok'},editor:{id:'one',text:'draft'}};apply(record);const deferred=editorId===undefined;record.life={type:'ready'};apply(record);const back=element('queue').children[0].querySelector('.attach-remove');apply({...record});deferred&&back===element('queue').children[0].querySelector('.attach-remove')&&back.title==='Remove from the queue'&&element('queue').children[0].dataset.kind==='steer'&&element('queue').children[0].className==='qmsg user'&&element('status-extras').children.length===1"), true);
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

test("the failure card names a fresh start only without a saved session", async () => {
  const app = await page();
  assert.equal(app.run("state={...state,life:{type:'failed',at:0,message:'x'}};exited();element('exited').children[0].children.some(child=>child.className==='fresh'&&child.textContent.includes('fresh session'))"), true);
  assert.equal(app.run("state={...state,sessionFile:'saved.jsonl',life:{type:'failed',at:1,message:'x'}};exited();element('exited').children[0].children.some(child=>child.className==='fresh')"), false);
});

test("thinking and aborted steps use live times without inventing replay times", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const contents=value=>typeof value==='string'?value:value.textContent+value.children.map(contents).join('');
    const thinking={type:'thinking',text:'which stages',started:10000,ended:14000};
    const bash={type:'tool',name:'bash',args:{text:'{}'},started:14000,state:{type:'not_run'}};
    const item={at:10000,ended:37000,final:true,stop:'aborted',blocks:[thinking,bash]};
    const live=run(item.blocks.map((block,index)=>({kind:'block',block,index,key:'a'+index,item})));
    delete thinking.started;delete thinking.ended;delete bash.started;delete item.ended;
    const replay=run(item.blocks.map((block,index)=>({kind:'block',block,index,key:'b'+index,item})));
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
  const hooks: { read?: (name: string, self: { className?: string }) => void; layout?: () => void; wrote?: () => void; delivered?: () => void; frame?: () => void } = {};
  const create = app.context.document.createElement;
  const rects = (count: number) => Array.from({ length: count }, (_, line) => ({ top: line * 20 + 2, bottom: line * 20 + 18 }));
  app.context.document.createElement = (tag: string) => {
    const node = create(tag);
    node.getBoundingClientRect = () => { hooks.read?.('rect', node); layout.flush(); const position = (node.className.includes('reveal') ? 0 : node.offsetTop - top), height = node.rects.at(-1)?.bottom ? Number(node.rects.at(-1)?.bottom) + 2 : node.offsetHeight; return { left: 0, top: position, bottom: position + height, height }; };
    if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) {
      html.push(value);
      const child = create(value.startsWith('<pre') ? 'pre' : 'p'), text = value.replace(/<[^>]*>/g, '').replace(/\n$/, '');
      Object.assign(child, { textContent: text, after: (bar: typeof child) => bars.push(bar), getBoundingClientRect: () => ({ top: 0, bottom: 20 * (child.rects.length) + 2, height: 0 }) });
      if (child.tagName === 'PRE') {
        const code = create('code');
        code.rects = rects(text.split('\n').length);
        child.querySelector = () => code;
        pres.push(child);
      } else child.rects = rects(Math.ceil(text.split(/\s+/).filter(Boolean).length / 3));
      const pieces = value.replace(/<\/?p>/g, '').replace(/\n$/, '').split(/<\/?(?:strong|em|code|a)[^>]*>/);
      if (child.tagName === 'P' && pieces.length > 1) { child.textContent = ''; child.append(...pieces.filter(Boolean).map(piece => Object.assign(create('span'), { textContent: piece }))); }
      node.content = { childNodes: value.trim() ? [child] : [], querySelectorAll: () => child.tagName === 'PRE' ? [child] : [] };
    } });
    return node;
  };
  Object.assign(app.context, { performance: { now: () => clock }, requestAnimationFrame: (callback: () => void) => { queued.set(++id, callback); return id; }, cancelAnimationFrame: (frame: number) => queued.delete(frame), setTimeout: (callback: () => void, delay: number) => { timers.set(++id, { at: clock + delay, callback }); return id; }, clearTimeout: (timer: number) => timers.delete(timer) });
  let top = 0, height = 20, client = clientHeight, moved = false;
  const evaluate = app.repl();
  const box = app.context.document.getElementById('scroll');
  const layout: { height?: () => number; elastic?: boolean; dock?: number; flush: () => void } = { flush: () => {} };
  const natural = () => layout.height?.() ?? height;
  Object.defineProperty(app.context.document.getElementById('transcript'), 'offsetHeight', { get: natural });
  const total = natural;
  layout.flush = () => { if (layout.elastic) return; const next = Math.min(Math.max(0, total() - client), top); if (next !== top) { top = next; moved = true; } };
  Object.defineProperties(box, {
    scrollTop: { get: () => (hooks.read?.('scrollTop', box), layout.flush(), top), set: (value: number) => { layout.flush(); const before = top; top = Math.max(0, Number(value)); layout.flush(); hooks.wrote?.(); if (top !== before) moved = true; } },
    scrollHeight: { get: () => (hooks.read?.('scrollHeight', box), layout.flush(), total()), set: (value: number) => { layout.flush(); height = value; layout.flush(); } },
    clientHeight: { get: () => (hooks.read?.('clientHeight', box), client), set: (value: number) => { client = value; layout.flush(); } },
  });
  const sources: { onmessage?: (event: { data: string }) => void }[] = [];
  Object.assign(app.context, { EventSource: class { onmessage?: (event: { data: string }) => void; onerror = null; onopen = null; constructor() { sources.push(this); } close() {} } });
  let seen = '';
  const step = (ms: number) => {
    clock += ms;
    if (moved) { moved = false; box.onscroll?.(); }
    for (const [timer, { at, callback }] of [...timers]) if (at <= clock) { timers.delete(timer); callback(); }
    for (const [frame, callback] of [...queued]) { queued.delete(frame); callback(); }
    layout.flush();
    const size = total() + '/' + client, resized = size !== seen;
    seen = size;
    hooks.layout?.();
    for (const { callback, targets, fresh } of app.observers) {
      const unseen = () => [...targets].filter(target => target.sizeOf && target.sizeOf() !== target.seen);
      let changed = [...new Set([...resized ? targets : fresh, ...unseen()])];
      fresh.clear();
      while (changed.length) {
        const shallowest = Math.min(...changed.map(target => target.depth));
        for (const target of changed) if (target.sizeOf) target.seen = target.sizeOf();
        callback(changed.map(target => ({ target, borderBoxSize: [{ blockSize: layout.dock ?? 96 }] })));
        hooks.delivered?.();
        changed = unseen().filter(target => target.depth > shallowest);
      }
    }
    hooks.frame?.();
  };
  const patch = (revision: number, suffix: string, final = false) => evaluate(`apply({type:'patch',seq:0,baseRevision:${revision - 1},revision:${revision},final:${final},stop:'',error:'',blocks:[{index:0,suffix:${JSON.stringify(suffix)}}]})`);
  const put = (text: string) => evaluate(`put({seq:0,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:${JSON.stringify(text)}}]})`);
  const deliver = (record: object) => { if (!sources.length) evaluate('connect()'); sources.at(-1)?.onmessage?.({ data: JSON.stringify(record) }); };
  step(0); step(0);
  return { app, evaluate, html, bars, pres, queued, timers, step, patch, put, layout, deliver, hooks };
}

const tailOf = (fixture: Awaited<ReturnType<typeof revealPage>>) => ({
  shown: fixture.evaluate("texts.get('0:0').reveal.tail?.shown"),
  clip: fixture.evaluate("texts.get('0:0').reveal.tail?.view.style.maxHeight"),
  text: fixture.evaluate("texts.get('0:0').reveal.tail?.view.children[0].textContent"),
});

test('the tail renders whole under a clip that opens at whole lines once the cap or the time asks', async () => {
  const fixture = await revealPage(200);
  fixture.evaluate("state={...state,working:true,since:1700000000000}");
  fixture.put('Intro.\n\none two three four five six');
  assert.deepEqual(tailOf(fixture), { shown: 0, clip: '0px', text: 'one two three four five six' });
  assert.equal(fixture.evaluate("texts.get('0:0').reveal.tail.view.className"), 'reveal dormant', 'a clip of zero keeps the wrapper out of the flow');
  assert.equal(fixture.evaluate("texts.get('0:0').view.children.some(child => child.className === 'caret' || child.className === 'dots')"), false);
  fixture.step(0);
  fixture.step(0);
  assert.equal(tailOf(fixture).shown, 0, 'two lines are under the cap of 80 px');
  fixture.step(220);
  fixture.step(0);
  assert.deepEqual([fixture.queued.size, fixture.timers.size], [0, 1]);
  fixture.step(1500);
  fixture.step(0);
  assert.deepEqual(tailOf(fixture), { shown: 20, clip: '20px', text: 'one two three four five six' });
  assert.equal(fixture.evaluate("texts.get('0:0').reveal.tail.view.className"), 'reveal', 'a clip above zero puts the wrapper in the flow');
  fixture.patch(1, ' seven eight nine ten eleven twelve thirteen fourteen');
  fixture.step(16);
  assert.equal(tailOf(fixture).clip, '80px', 'the rendering transaction updates the clip at the cap');
  assert.equal(tailOf(fixture).text, 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen');
  fixture.step(16);
  assert.equal(tailOf(fixture).clip, '80px', 'the hidden height reached the cap: the clip stops before the unfinished line');
  fixture.patch(2, ' more', true);
  fixture.step(0);
  assert.equal(fixture.evaluate("texts.get('0:0').view.children.some(child => child.className.includes('reveal'))"), false);
  assert.deepEqual([fixture.evaluate("revealing.size"), fixture.evaluate("element('tail-slot').lastChild?.className.includes('working')")], [0, true]);
});

test('a duplicate revision repeats nothing and a same-type replacement retains its reveal memo and maximum', async () => {
  const fixture = await revealPage(200);
  fixture.put('Intro.\n\none two three four five six');
  fixture.patch(1, ' seven');
  fixture.step(0);fixture.step(1500);
  const shown = fixture.html.length, maximum = Number(tailOf(fixture).shown);
  fixture.patch(1, ' seven');
  fixture.evaluate("apply({type:'patch',seq:0,baseRevision:1,revision:1,final:false,stop:'',error:'',blocks:[{index:0,suffix:' dup'}]})");
  fixture.step(0);
  assert.equal(fixture.html.length, shown);
  const old = fixture.evaluate("texts.get('0:0')");
  fixture.evaluate("apply({type:'patch',seq:0,baseRevision:1,revision:2,final:false,stop:'',error:'',blocks:[{index:0,block:{type:'text',text:'Fresh.\\n\\nnew tail words here'}}]})");
  fixture.step(0);
  assert.deepEqual(fixture.html.slice(shown), ['<p>Fresh.</p>\n', '', '<p>new tail words here</p>\n']);
  assert.deepEqual([fixture.evaluate("revealing.size"), fixture.evaluate("revealing.has(texts.get('0:0'))"), fixture.evaluate("texts.get('0:0')") === old, tailOf(fixture).shown], [1, true, true, maximum]);
  assert.ok(maximum > 0);
});

test('a hidden page renders in one timer task, never in a frame, and a shown page moves that work to a frame', async () => {
  const fixture = await revealPage();
  fixture.app.context.document.hidden = true;
  fixture.deliver({ type: 'item', item: assistant(0, 'Intro.\n\nwaiting tail') });
  assert.deepEqual([fixture.queued.size, fixture.timers.size, fixture.evaluate('views.has(0)')], [0, 1, false]);
  fixture.step(50);
  assert.deepEqual([fixture.queued.size, fixture.evaluate('views.has(0)')], [0, true]);
  fixture.deliver(patchOf(0, 1, ' more'));
  assert.deepEqual([fixture.queued.size, fixture.timers.size], [0, 1]);
  fixture.app.context.document.hidden = false;
  fixture.app.listeners.get('visibilitychange')?.({});
  assert.equal(fixture.queued.size, 1);
  fixture.app.listeners.get('visibilitychange')?.({});
  assert.equal(fixture.queued.size, 1);
  fixture.app.windowListeners.get('pagehide')?.();
  assert.equal(fixture.queued.size, 0);
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
  assert.deepEqual(fixture.bars.map(bar => bar.textContent), ['Show 5 more lines']);
  assert.equal(fixture.pres.at(-1)?.classList.contains('folded'), true);
  fixture.patch(1, '\n' + code(5));
  fixture.step(16);
  assert.equal(fixture.bars.at(-1)?.textContent, 'Show 10 more lines');
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
    const result = app.run(`let connects=0;connect=()=>{connects++};accept=item=>items.set(item.seq,item);rendered=()=>Promise.resolve();epoch='e';first=4;transcriptHistory.debug.more=true;${setup};const loading=transcriptHistory.earlier();const patch=(seq,baseRevision,revision,suffix)=>apply({type:'patch',seq,baseRevision,revision,final:false,stop:'',error:'',blocks:[{index:0,suffix}]});${buffered};loading.then(()=>[items.get(3).blocks[0].text,items.get(2)?.blocks[0].text,connects])`);
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
    accept=item=>items.set(item.seq,item);rendered=()=>Promise.resolve();epoch='e';first=4;transcriptHistory.debug.more=true;
    const one=transcriptHistory.earlier();
    apply({type:'reset',epoch:'f',more:true,items:[{seq:7,revision:0,kind:'assistant',final:true,blocks:[]}]});first=7;
    const two=transcriptHistory.earlier(), started=count();
    release(0,'f',3);await one;transcriptHistory.earlier();
    const stale=[items.has(3),count()];
    release(1,'e',5);await two;
    const wrong=[items.has(5),transcriptHistory.more];
    const third=transcriptHistory.earlier();release(2,'f',6);await third;
    return {started,stale,wrong,added:[count(),items.has(6)]};
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { started: 2, stale: [false, 2], wrong: [false, true], added: [3, true] });
});

test("a duplicate patch is skipped and a gap or non-assistant target reconnects from a reset", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    let connects=0;connect=()=>{connects++};accept=item=>items.set(item.seq,item);rendered=()=>Promise.resolve();epoch='e';
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
    const failed=run(failedItem.blocks.map((block,index)=>({kind:'block',block,index,key:'f'+index,item:failedItem})));
    const thinking={type:'thinking',text:'the order in sweep()'};
    const edit={type:'tool',name:'edit',args:{text:JSON.stringify({path:'ko_server/src/sweep.rs',oldText:'',newText:''})},state:{type:'not_run'}};
    const abortedItem={at:0,final:true,stop:'aborted',blocks:[thinking,edit]};
    const aborted=run(abortedItem.blocks.map((block,index)=>({kind:'block',block,index,key:'a'+index,item:abortedItem})));
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
  app.run("state.life={type:'ready'};const trigger=element('model'),child=node('span','model');trigger.append(child);pickerButton=trigger;element('picker').hidden=false");
  app.listeners.get('pointerdown')?.({ target: app.elements.get('model')?.children[0] });
  assert.equal(app.elements.get('picker')?.hidden, false);
  app.elements.get('model')?.onclick?.();
  assert.equal(app.elements.get('picker')?.hidden, true);
});

test('every notice is one nrow that opens only when it has more than its line', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const row=seq=>views.get(seq).view.children[0], hd=r=>r.children[0], tx=r=>hd(r).children[0];
    const out={},fit=()=>{element('items').clientWidth++;resized([{target:element('items'),borderBoxSize:[{blockSize:0}]}]);tick()};
    put({seq:0,at:0,final:true,kind:'notify',level:'warning',text:{text:'Notice stays',cut:0}});apply({...state,type:'state'});
    const a=row(0);
    out.warning=[views.get(0).view.className,a.className,tx(a).textContent,hd(a).children[1].tagName,hd(a).children.length];
    tx(a).scrollWidth=500;fit(a);out.overflow=[a.classList.contains('more'),a.children[1].textContent];
    tx(a).scrollWidth=100;out.kept=a.classList.contains('more');tx(a).clientWidth=300;fit(a);out.fits=a.classList.contains('more');
    put({seq:8,at:0,final:true,kind:'command',result:{type:'export',path:'/very/long/export.html'}});
    const x=row(8);tx(x).children[1].scrollWidth=0;x.children[0].children[0].scrollWidth=900;fit(x);out.export=[x.classList.contains('more'),x.children[1].children.map(c=>c.textContent)];
    put({seq:1,at:0,final:true,kind:'notify',level:'info',text:{text:'one\\ntwo',cut:0}});
    const b=row(1);out.multi=[b.className,tx(b).textContent,b.children[1].textContent];
    hd(b).onclick({});out.opened=b.classList.contains('open');
    hd(b).onkeydown({key:' ',preventDefault(){}});out.closed=b.classList.contains('open');
    hd(b).onkeydown({key:'Enter',preventDefault(){}});out.entered=b.classList.contains('open');
    const stats={sessionId:'id',sessionFile:'/f',totalMessages:3,userMessages:1,assistantMessages:1,toolResults:1,cost:1.5,tokens:{input:1,output:2,cacheRead:3,cacheWrite:4}};
    put({seq:2,at:0,final:true,kind:'command',result:{type:'session',stats,name:'Release'}});
    const c=row(2);out.session=[c.className,tx(c).textContent];
    hd(c).onclick({});out.sessionOpen=c.classList.contains('open');
    put({seq:3,at:0,final:true,kind:'summary',source:'branch',text:'first line\\n\\nsecond'});
    const d=row(3);out.summary=[d.className,tx(d).children.map(x=>x.className+':'+x.textContent),hd(d).children.length];
    put({seq:4,at:0,final:true,kind:'summary',source:'compaction',text:'text'});out.compaction=tx(row(4)).children[0].textContent;
    put({seq:5,at:0,final:true,kind:'command',result:{type:'compaction',state:{type:'failed',message:'pi restarted'}}});
    const e=row(5);out.failed=[e.className,tx(e).textContent];
    put({seq:6,at:0,final:true,kind:'command',result:{type:'compaction',state:{type:'running'}}});
    out.running=[row(6).className,tx(row(6)).children.map(x=>x.className)];
    put({seq:7,at:5,final:true,kind:'assistant',stop:'stop',error:'provider down',blocks:[{type:'text',text:'Done'}]});
    const reply=views.get(7).view,last=reply.children.at(-1);
    out.error=[reply.children.length,last.className,tx(last).textContent,hd(last).children[1].tagName];
    return out;
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    warning: ['', 'nrow warning', 'Notice stays', 'TIME', 2], overflow: [true, 'Notice stays'], kept: true, fits: false, export: [true, ['exported ', '/very/long/export.html']],
    multi: ['nrow more', 'one', 'two'], opened: true, closed: false, entered: true,
    session: ['nrow more', 'Release · 3 messages · $1.50'], sessionOpen: true,
    summary: ['nrow more', ['lead:branch', 'prev: · first line'], 2], compaction: 'compacted',
    failed: ['nrow error', 'compaction · pi restarted'], running: ['nrow', ['', 'dots']],
    error: [2, 'nrow error', 'provider down', 'TIME'],
  });
});

test('event-only run summaries show the last moment as later agent and job steps join', async () => {
  const app = await page(), morning = new Date(1700000012000); morning.setHours(9, 0, 0, 0);
  const result = app.run(`(()=>{
    const at=${morning.getTime()},report=(seq,at)=>({seq,at,revision:0,final:true,kind:'agent',direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    put(report(0,at));const row=openers.get('run:0:item').view,time=()=>row.firstElementChild.querySelector('.time').textContent,first=time();
    put({seq:1,at:at+300000,revision:0,final:true,kind:'job',job:{id:'j',name:'build',log:'/tmp/build.log',service:false},event:{type:'ended',end:{type:'exit',code:0},tail:{text:'PASS',cut:0}}});const second=time();
    put(report(2,at+600000));
    return [first,second,time(),openers.get('run:0:item').view===row];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), ['09:00','09:05','09:10',true]);
});

test('mixed run durations ignore moments and outgoing calls show their tool duration', async () => {
  const app = await page(), morning = new Date(1700000012000); morning.setHours(9, 0, 0, 0);
  const result = app.run(`(()=>{
    const at=${morning.getTime()},report=(seq,at)=>({seq,at,revision:0,final:true,kind:'agent',direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    const tool=(id,started,ended)=>({type:'tool',id,name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'done',images:[]}},started,ended});
    const reply=(seq,block)=>({seq,at,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks:[block]});
    put(report(0,at));put(reply(1,tool('read',at+1000,at+5000)));
    const time=()=>openers.get('run:0:item').view.firstElementChild.querySelector('.time').textContent,first=time();
    put({seq:2,at:at+600000,revision:0,final:true,kind:'job',job:{id:'j',name:'build',log:'/tmp/build.log',service:false},event:{type:'ended',end:{type:'exit',code:0},tail:{text:'PASS',cut:0}}});const afterJob=time();
    put(reply(3,{...tool('call',at+6000,at+7500),name:'message_agent',agent:{direction:'out',to:{name:'worker'},text:{text:'Message',cut:0},call:{tool:'message',mode:'message'},outcome:{ok:true}}}));
    const outgoing=openers.get('3:0').view.querySelector('.time').textContent,afterCall=time();put(report(4,at+1200000));
    return [first,afterJob,outgoing,afterCall,time()];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), ['4s','4s','1.5s','6.5s','6.5s']);
});

test('an active tool keeps the run duration live when a later outgoing call is complete', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    put({seq:0,revision:0,at:1700000000000,final:false,kind:'assistant',stop:'',error:'',blocks:[{type:'tool',id:'bash',name:'bash',args:{text:'{}'},state:{type:'running'},started:1700000000000},{type:'tool',id:'message',name:'message_agent',args:{text:'{}'},state:{type:'done',error:false,result:{text:'done',images:[]}},started:1700000001000,ended:1700000002000,agent:{direction:'out',to:{name:'worker'},text:{text:'Message',cut:0},call:{tool:'message',mode:'message'},outcome:{ok:true}}}]});
    const time=()=>openers.get('run:0:0').view.firstElementChild.querySelector('.time').textContent,first=time(),outgoing=openers.get('0:1').view.querySelector('.time').textContent;
    Date=class extends Date{static now(){return 1700000014000}};
    const current=items.get(0);put({...current,revision:1,blocks:current.blocks.map((block,index)=>index?block:{...block,args:{text:'{"command":"still running"}'}})});
    return [first,outgoing,time()];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), ['12s','1s','14s']);
});

test('failed tool times retain the error class without colouring successful agent or job times', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool=(id,error)=>({type:'tool',id,name:'bash',args:{text:'{}'},state:{type:'done',error,result:{text:'done',images:[]}},started:0,ended:1000});
    put({seq:0,revision:0,at:0,final:true,kind:'assistant',stop:'stop',error:'',blocks:[tool('ok',false),tool('bad',true),{...tool('agent',true),agent:{direction:'out',to:{name:'worker'},text:{text:'Refused',cut:0},call:{tool:'message',mode:'message'},outcome:{ok:false,failure:'refused',message:'Refused'}}}]});
    put({seq:1,revision:0,at:1000,final:true,kind:'job',job:{id:'j',name:'build',log:'/tmp/build.log',service:false},event:{type:'ended',end:{type:'exit',code:1},tail:{text:'FAIL',cut:0}}});
    return ['0:0','0:1','0:2','1:item'].map(key=>openers.get(key).view.querySelector('.time').className);
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), ['time','time err','time','time']);
});

test('a run keeps its source timestamp when leading thinking has no block timestamp', async () => {
  const app = await page();
  const elapsed = app.run(`(()=>{
    put({seq:0,revision:0,at:0,final:true,kind:'assistant',stop:'stop',error:'',blocks:[{type:'thinking',text:'Thought'},{type:'tool',id:'r',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'done',images:[]}},started:6000,ended:10000}]});
    return openers.get('run:0:0').view.firstElementChild.querySelector('.time').textContent;
  })()`);
  assert.equal(elapsed, '10s');
});

test('text suffixes and another tool patch retain completed agent and tool DOM', async () => {
  const page = await latestPage();
  page.evaluate("state={...state,agents:[{name:'worker',target:{type:'pane',pane:'p1'}}]}");
  const tool = { type: 'tool', id: 'read', name: 'read', args: { text: '{}' }, state: { type: 'done', error: false, result: { text: 'old output', images: [] } } };
  const agent = { ...tool, id: 'message', name: 'message_agent', agent: { direction: 'out', to: { name: 'worker' }, text: { text: '**Report**', cut: 0 }, call: { tool: 'message', mode: 'message' }, outcome: { ok: true } } };
  page.add({ seq: 0, revision: 0, at: 0, final: false, kind: 'assistant', stop: '', error: '', blocks: [tool, agent, { type: 'text', text: 'Answer' }] });
  const details = () => page.evaluate("runMarks.get(views.get(0).slots.get('0:0').view.firstElementChild).steps.map(step=>step.detail.firstChild)");
  const link = () => page.evaluate("openers.get('0:1').view.querySelector('.who')");
  const before = details(), name = link();
  assert.ok(Array.isArray(before));
  page.deliver({ type: 'patch', seq: 0, baseRevision: 0, revision: 1, final: false, stop: '', error: '', blocks: [{ index: 2, suffix: ' grows' }] }); page.step(16);
  assert.deepEqual(details(), before);
  assert.equal(link(), name);
  page.deliver({ type: 'patch', seq: 0, baseRevision: 1, revision: 2, final: false, stop: '', error: '', blocks: [{ index: 0, block: { ...tool, state: { ...tool.state, result: { text: 'new output', images: [] } } } }] }); page.step(16);
  const after = details();
  assert.ok(Array.isArray(after));
  assert.notEqual(after[0], before[0]);
  assert.equal(after[1], before[1]);
  assert.equal(link(), name);
});

test('empty topic labels and whitespace are transparent to one mixed run', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const topic='koa-design',thinking=()=>({type:'thinking',text:'Plan',topic}),bash=id=>({type:'tool',id,name:'bash',topic,args:{text:'{}'},state:{type:'done',error:false,result:{text:'ok',images:[]}}}),reply=(seq,blocks)=>({seq,at:seq,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks});
    put(reply(0,[thinking()]));
    put(reply(1,[{type:'text',text:'',topic},bash('one')]));
    put(reply(2,[bash('two'),thinking()]));
    put(reply(3,[bash('three'),thinking()]));
    put(reply(4,[{type:'text',text:' \\n\\t ',topic},bash('four'),{...bash('message'),name:'message_agent',agent:{direction:'out',to:{name:'worker'},text:{text:'Check this',cut:0},call:{tool:'message',mode:'message'},outcome:{ok:true}}}]));
    const owner=views.get(0).slots.get('0:0').view.firstElementChild,marks=runMarks.get(owner),one=[...openers.keys()].filter(key=>key.startsWith('run:'));
    const stepKeys=marks.steps.map(step=>step.key),findOwner=findSegments(visible(4),findContext()).find(segment=>segment.text==='Check this').folds[0];
    put(reply(5,[{type:'text',text:'Visible prose',topic},bash('after')]));
    put(reply(6,[{type:'text',text:'   ',topic}]));
    put(reply(7,[bash('last')]));
    const runs=[...views.values()].flatMap(entry=>[...entry.slots.values()].filter(slot=>slot.type==='run'&&slot.view.firstElementChild));
    return [one.length,stepKeys,findOwner,runs.length,runMarks.get(views.get(5).slots.get('5:1').view.firstElementChild).steps.length];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [1,['0:0','1:1','2:0','2:1','3:0','3:1','4:1','4:2'],'run:0:0',2,2]);
});

test('assistant steps without a topic and a job with a topic share one run without step topic marks', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool=name=>({type:'tool',id:name,name,args:{text:'{}'},state:{type:'pending'}}),reply=(seq,blocks)=>({seq,at:seq,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks});
    put(reply(0,[{type:'thinking',text:'Before'},tool('bash')]));
    put({seq:1,at:1,kind:'job',topic:'topics',final:true,job:{id:'j',name:'koaproxy',service:true,log:''},event:{type:'stream',batch:{text:'Output',cut:0},omitted:0,cut:false}});
    put(reply(2,[{type:'thinking',text:'After'},tool('codemode')]));
    put({seq:3,at:3,kind:'agent',topic:'other',final:true,direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    put({seq:4,at:4,kind:'notice',final:true,customType:'notice',from:'worker',text:'Notice'});
    const unfiltered=[[...openers.keys()].filter(key=>key.startsWith('run:')), [1,3,4].map(seq=>views.get(seq).view.querySelectorAll('.topic-mark,.topic-name').length)];
    topics.debug.scopeData(topics.scope()).filter='topics'; refreshTopicItems(); renderDirty();
    const filtered=[visible(0)?.blocks.length,!!visible(1),visible(2)?.blocks.length,!!visible(3)];
    topics.debug.scopeData(topics.scope()).filter='other'; refreshTopicItems();
    const other=[0,1,2,3].map(seq=>!!visible(seq));
    delete topics.debug.scopeData(topics.scope()).filter; refreshTopicItems();
    put(reply(5,[{type:'text',text:'Boundary'}])); put(reply(6,[tool('read')]));
    topics.debug.scopeData(topics.scope()).filter='topics'; refreshTopicItems();
    return [unfiltered,filtered,other,!!visible(6)];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[['run:0:0'], [0,0,0]], [2,true,2,true], [false,false,false,false], false]);
});

test('notices join an open run but do not open one after prose', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool=id=>({type:'tool',id,name:'bash',args:{text:'{}'},state:{type:'pending'}}),reply=(seq,blocks,error='')=>({seq,at:seq,revision:0,final:true,kind:'assistant',stop:'stop',error,blocks});
    put(reply(0,[{...tool('first'),topic:'one'}]));
    put({seq:1,at:1,kind:'notify',final:true,level:'warning',text:{text:'Careful\\nDetails',cut:0}});
    put(reply(2,[tool('second')],'Reply failed'));
    const owner=views.get(0).slots.get('0:0').view.firstElementChild, marks=runMarks.get(owner);
    const steps=marks.steps.map(mark=>[mark.current.kind,mark.label.className,mark.label.textContent]);
    const find=findSegments(visible(1),findContext()).find(segment=>segment.text==='Careful');
    const body=findSegments(visible(1),findContext()).find(segment=>segment.text==='Details');
    const copied=transcriptText();
    put(reply(3,[{type:'text',text:'Done'}]));
    put({seq:4,at:4,kind:'notice',final:true,customType:'note',from:'worker',text:'Lone notice'});
    put(reply(5,[tool('third')]));
    const standalone=!!views.get(4).view.querySelector('.nrow'), next=runOwner(runContext(),{kind:'block',seq:5,index:0});
    topics.debug.scopeData(topics.scope()).filter='one'; refreshTopicItems();
    return [steps,marks.names.children.map(child=>child.textContent).join(', '),find.folds,find.step,copied.includes('Careful'),standalone,next,!!visible(1),visible(2)?.error,body.folds];
  })()`);
  const value = JSON.parse(JSON.stringify(result));
  assert.deepEqual(value[0].map((step: string[]) => step[0]), ['block','notice','block','notice']);
  assert.deepEqual(value[0].filter((step: string[]) => step[0] === 'notice').map((step: string[]) => step.slice(1)), [['notice warning','Careful'],['notice error','Reply failed']]);
  assert.match(value[1], /notify/); assert.match(value[1], /error/);
  assert.deepEqual(value.slice(2), [['run:0:0'],'1:item',true,true,{kind:'block',seq:5,index:0},true,'Reply failed',['run:0:0','1:item']]);
});

test('each prose reply repeats its topic chip across intervening runs', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const reply=(seq,blocks)=>({seq,at:seq,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks}),prose=(seq,topic)=>reply(seq,[{type:'text',text:'Prose '+seq,topic}]),steps=(seq,topic)=>reply(seq,[{type:'thinking',text:'Plan',topic}]);
    put(prose(0,'one')); put(steps(1,'two')); put(prose(2,'two'));
    put(steps(3,'one')); put(prose(4,'two'));
    put(prose(5,'one')); put(steps(6,'two')); put(prose(7,'one'));
    return [0,1,2,3,4,5,6,7].map(seq=>views.get(seq).view.querySelectorAll('.reply-section>.msg>.message-header>.topic-chip').map(mark=>mark.dataset.topic).filter(Boolean));
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['one'],[],['two'],[],['two'],['one'],[],['one']]);
});

test('joined notice find uses rendered Markdown and command detail text', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    put({seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'thinking',text:'Plan'}]});
    put({seq:1,at:1,kind:'notice',final:true,customType:'note',from:'worker',text:'**Headline**\\n**Body**'});
    const stats={sessionId:'id',sessionFile:'/f',totalMessages:3,userMessages:1,assistantMessages:1,toolResults:1,cost:1.5,tokens:{input:1,output:2,cacheRead:3,cacheWrite:4}};
    put({seq:2,at:2,kind:'command',final:true,result:{type:'session',name:'session',stats}});
    const note=findSegments(visible(1),findContext()), details=findSegments(visible(2),findContext());
    return [note.map(segment=>segment.text),note.find(segment=>segment.text==='Body').folds,details.find(segment=>segment.text==='file /f').folds,transcriptText().includes('**')];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['Headline','Body'],['run:0:0','1:item'],['run:0:0','2:item'],false]);
});

test('a filtered bang row keeps the runs on either side separate', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool=id=>({type:'tool',id,name:'read',topic:'one',args:{text:'{}'},state:{type:'pending'}}),reply=(seq)=>({seq,at:seq,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks:[tool(String(seq))]});
    put(reply(0)); put({seq:1,at:1,kind:'bash',final:true,command:'true',excludeFromContext:false,result:{output:{text:'',cut:0},cancelled:false,truncated:false}}); put(reply(2));
    topics.debug.scopeData(topics.scope()).filter='one'; refreshTopicItems();
    return runOwner(runContext(),{kind:'block',seq:2,index:0});
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), {kind:'block',seq:2,index:0});
});

test('notice rendering follows ownership when a history gap is filled and replaced', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const notice={seq:1,at:1,kind:'notice',final:true,customType:'note',from:'worker',text:'Note'},reply=blocks=>({seq:0,at:0,revision:0,final:true,kind:'assistant',stop:'stop',error:'',blocks});
    put(notice); const before=!!views.get(1).view.querySelector('.nrow');
    put(reply([{type:'thinking',text:'Plan'}])); const joined=!views.get(1).view.querySelector('.nrow')&&!!views.get(1).slots.get('1:item');
    put(reply([{type:'text',text:'Done'}])); const after=!!views.get(1).view.querySelector('.nrow');
    return [before,joined,after];
  })()`);
  assert.deepEqual(Array.from(result), [true,true,true]);
});

test('changing a step into a notice invalidates followers without an earlier run', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const report=seq=>({seq,at:seq,kind:'agent',final:true,direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    put(report(0)); put(report(1));
    put({seq:0,at:0,kind:'notice',final:true,customType:'note',from:'worker',text:'Note'});
    return [runOf(runContext(),{kind:'item',seq:0}),runOwner(runContext(),{kind:'item',seq:1})];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [null,{kind:'item',seq:1}]);
});

test('step-only replies never render a topic mark and streaming keeps active find', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const reply=(seq,topic,text)=>({seq,at:seq,revision:0,final:false,kind:'assistant',stop:'',error:'',blocks:[{type:'thinking',topic,text}]});
    put(reply(0,'one','Before')); put(reply(1,undefined,'Late'));
    put({seq:2,at:2,kind:'topics',final:true,target:1,topics:['one']});
    const marks=[0,1].map(seq=>views.get(seq).view.querySelectorAll('.topic-section>.topic-mark').length);
    topics.debug.scopeData(topics.scope()).filter='one'; refreshTopicItems();
    const active={query:'Before',backwards:false,started:true}; find=active;
    put(reply(0,'one','Before and after'));
    return [marks,find===active];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[0,0],true]);
});

test('mixed run find keeps hidden prose as a boundary under a topic filter', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool={type:'tool',id:'r',name:'read',topic:'one',args:{text:'{}'},state:{type:'done',error:false,result:{text:'read output',images:[]}}};
    state={...state,view:{id:'root',type:'root',path:[]},topics:[{name:'one'},{name:'two'}]};
    put({seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[tool]});
    put({seq:1,at:1,kind:'agent',topic:'one',final:true,direction:'in',from:{name:'worker'},text:{text:'**Unique report**',cut:0},inbound:{form:'report'}});
    const job={id:'j',name:'build',service:false,log:'/tmp/build.log'};
    put({seq:2,at:2,kind:'job',topic:'one',final:true,job,event:{type:'stream',batch:{text:'Unique output',cut:0},omitted:0,cut:false}});
    const agent=segmentsOf(1).find(segment=>segment.text.includes('Unique report')), output=segmentsOf(2).find(segment=>segment.text==='Unique output');
    const copied=transcriptText();
    agent.folds.forEach(key=>openers.get(key).open());
    put({seq:3,at:3,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'Hidden prose',topic:'two'}]});
    put({seq:4,at:4,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{...tool,id:'after'}]});
    topics.debug.scopeData(topics.scope()).filter='one'; refreshTopicItems();
    const after=findSegments(visible(4),findContext()).find(segment=>segment.text==='read output');
    return [agent.folds,output.folds,(copied.match(/Unique report/g)||[]).length,copied.includes('Unique output'),after.folds[0]];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['run:0:0','1:item'],['run:0:0','2:item'],1,true,'run:4:0']);
});

test('mixed run window groups include metadata and change owner after a history prepend', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const report=seq=>({seq,at:seq,kind:'agent',final:true,direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    put(report(1));
    put({seq:2,at:2,kind:'annotations',final:true,reply:{seq:1,block:0},annotations:[]});
    put(report(3));
    const first=ensureTable().groups.map(group=>[group.from,group.to]);
    put({seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'thinking',text:'Earlier'}]});
    const second=ensureTable().groups.map(group=>[group.from,group.to]);
    const folds=findSegments(visible(3),findContext()).find(segment=>segment.text==='Report').folds;
    return [first,second,folds,runMarks.get(views.get(0).slots.get('0:0').view.firstElementChild).steps.length];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[[1,3]],[[0,3]],['run:0:0','3:item'],3]);
});

test('parallel completion and abort retain the run row until reset', async () => {
  const fixture = await revealPage(200), ev = fixture.evaluate;
  ev("state={...state,working:true,since:1699999990000}; reconcileWorking()");
  let row: unknown;
  const tool = (id: string, type: string) => ({type:'tool',id,name:'bash',args:{text:'{}'},state:{type,...type==='done'?{error:false,result:{text:'',images:[]}}:{}}});
  const show = (blocks: object[], stop = '') => ev('put('+JSON.stringify({seq:0,at:0,kind:'assistant',revision:0,final:false,stop,error:'',blocks})+')');
  show([tool('a','running'),tool('b','running')]);
  row = ev("views.get(0).slots.get('0:0').view.firstElementChild");
  assert.equal(ev("views.get(0).slots.get('0:0').view.firstElementChild"), row);
  assert.equal(ev(dotsCount), 1);
  show([tool('a','done'),tool('b','running')]);
  assert.equal(ev("views.get(0).slots.get('0:0').view.firstElementChild"), row);
  show([tool('a','done'),tool('b','running')], 'aborted');
  assert.equal(ev(dotsCount), 1);
  ev("resetting=true; dirty.add(0); renderDirty()");
  assert.notEqual(ev("views.get(0).slots.get('0:0').view.firstElementChild"), row);
  row = ev("views.get(0).slots.get('0:0').view.firstElementChild");
  show([tool('a','done'),tool('b','running'),{type:'text',text:'Reply'}], 'aborted');
  assert.equal(ev("views.get(0).slots.get('0:0').view.firstElementChild"), row);
  assert.equal(ev("working.place.kind"), 'bare');
  ev("apply({...state,type:'state',working:false})");
  assert.equal(ev(dotsCount), 0);
});

test('a trailing run replaces the bare ending slot', async () => {
  const fixture = await revealPage(200), ev = fixture.evaluate;
  ev("state={...state,working:true,since:1699999990000}; reconcileWorking()");
  const row = ev("element('tail-slot').lastChild"), line = ev("element('tail-slot').lastChild.firstElementChild");
  ev("put({seq:1,revision:0,at:0,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'text',text:'Reading'}]})");
  assert.equal(ev("element('tail-slot').lastChild"), row, 'text grows before the same bare row');
  ev("put({seq:1,revision:0,at:0,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'text',text:'Reading'},{type:'thinking',text:'Checking',started:1}]})");
  assert.notEqual(ev("views.get(1).slots.get('1:1').view.firstElementChild"), row, 'a run has its own row');
  assert.notEqual(ev("views.get(1).slots.get('1:1').view.firstElementChild.firstElementChild"), line, 'a run has its own line');
  assert.equal(ev("element('tail-slot').hidden"), true);
});

test('mixed idle steps join without unread growth', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool={type:'tool',id:'read',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'',images:[]}}};
    put({seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[tool]});
    const owner=views.get(0).slots.get('0:0').view.firstElementChild;
    put({seq:1,at:1,kind:'agent',final:true,direction:'in',from:{name:'worker',session:'worker-id'},text:{text:'Report',cut:0},inbound:{form:'report'}});
    const job={id:'j',name:'build',service:false,log:'/tmp/build.log'};
    put({seq:2,at:2,kind:'job',final:true,job,event:{type:'stream',batch:{text:'output',cut:0},omitted:0,cut:false}});
    put({seq:3,at:3,kind:'job',final:true,job,event:{type:'ended',end:{type:'exit',code:0},tail:{text:'done',cut:0}}});
    put({seq:4,at:4,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{...tool,id:'next'}]});
    return [views.get(0).slots.get('0:0').view.firstElementChild===owner,runMarks.get(owner).steps.length];
  })()`);
  assert.deepEqual(Array.from(result), [true, 5]);
});

test('consecutive job batches are separate steps and retain earlier output', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const job={id:'j',name:'build',service:false,log:'/tmp/build.log'},batch=(seq,text)=>({seq,at:seq*60000,final:true,kind:'job',job,event:{type:'stream',batch:{text,cut:0},omitted:0,cut:false}});
    put(batch(0,'first'));
    const owner=[...views.get(0).slots.values()].find(slot=>slot.type==='run').view.firstElementChild, marks=runMarks.get(owner), first=marks.steps[0];
    put(batch(1,'second'));
    put({seq:2,at:120000,final:true,kind:'job',job,event:{type:'ended',end:{type:'exit',code:1},tail:{text:'last tail',cut:0}}});
    return [marks.steps.length,marks.steps[0]===first,marks.steps.map(step=>step.tailKey)];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [3, true, ['1 lines', '1 lines', 'exit 1']]);
});

test('agent body changes render fresh final Markdown without a retained prose memo', async () => {
  const app = await page(), html: string[] = [];
  const create = app.context.document.createElement;
  app.context.document.createElement = tag => { const node = create(tag); if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) { html.push(value); } }); return node; };
  const result = app.run(`
    const card={direction:'out',to:{name:'worker'},text:{text:'**Review**',cut:0},call:{tool:'spawn',fork:false}};
    const slots=new Map();
    const view=agentStep(card,0,'agent:0',slots);
    const header=view.children[0];
    header.onclick({});
    const link=document.createElement('a'), label=document.createElement('strong'); link.append(label); header.append(link);
    header.onclick({target:label});
    const clicked=view.classList.contains('open');
    header.onkeydown({target:label,key:'Enter',preventDefault(){throw Error('Link Enter was intercepted');}});
    const entered=view.classList.contains('open');
    agentStep({...card,text:{text:'Use \`code\`',cut:0},outcome:{ok:false,failure:'refused',message:'No'}},0,'agent:0',slots);
    const fallback=put({seq:1,at:0,kind:'notice',final:true,customType:'other',from:'',text:'## **Ready**\\nSecond line'});
    [clicked,entered,texts.size,fallback.children[0].className,fallback.children[0].children[0].children[0].textContent,fallback.children[0].children[0].children[1].tagName];
  `);
  assert.match(html.join(''), /<strong>Review<\/strong>/);
  assert.match(html.join(''), /<code>code<\/code>/);
  assert.deepEqual(Array.from(result), [true, true, 0, 'nrow more', 'Ready', 'TIME']);
});

test('agent steps join runs and keep their final Markdown body without success metadata', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const tool=name=>({type:'tool',id:name,name,args:{text:'{}'},state:{type:'done',error:false,result:{text:'',images:[]}}});
    const card={...tool('spawn_agent'),agent:{direction:'out',to:{name:'worker',session:'worker-id'},text:{text:'Check the module\\nReturn findings',cut:0},call:{tool:'spawn',fork:false},outcome:{ok:true}}};
    put({seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[tool('read'),card,tool('bash')]});
    const owner=views.get(0).slots.get('0:0').view.firstElementChild,marks=runMarks.get(owner);
    return [views.get(0).view.children.length,marks.steps.length,marks.steps[1].tailKey,marks.steps[1].detail.children.length];
  })()`);
  assert.deepEqual(Array.from(result), [1, 3, 'Check the module', 1]);
});

test('agent names link to live agents, a gone name is plain, a click focuses the pane and keeps the line closed', async () => {
  const app = await page();
  const names = Array.from(app.run(`(()=>{
    state={...state,agents:[{name:'worker',target:{type:'pane',pane:'p7'}}]};
    const card=name=>({direction:'out',to:{name},text:{text:'Hello',cut:0},call:{tool:'message',mode:'message'}});
    const live=agentStep(card('worker'),0,'a',new Map()), gone=agentStep(card('ghost'),0,'b',new Map());
    const link=live.children[0].children[1].children[0].children[1], ended=gone.children[0].children[1].children[0].children[1];
    window.testLink=link; window.testLine=live;
    return [link.tagName,link.className,link.href,link.title,link.textContent,ended.tagName,ended.className,ended.title,ended.textContent];
  })()`));
  assert.deepEqual(names, ['A', 'who', '#pane:worker', 'Focus the pane of @worker', '@worker', 'SPAN', 'who gone', 'ended', '@ghost']);
  const focused: string[] = [];
  const ko: { focus?: (pane: string) => void } = { focus: pane => { focused.push(pane); } }; app.context.window.ko = ko;
  let prevented = false;
  const target = app.run(`window.testLink`);
  app.run(`state={...state,agents:[{name:'worker',target:{type:'pane',pane:'p7'}}]}`);
  app.listeners.get('click')?.({ target, preventDefault() { prevented = true; } });
  assert.deepEqual(focused, ['p7']);
  assert.equal(prevented, true);
  assert.equal(app.run(`window.testLine.classList.contains('open')`), false);
  delete ko.focus;
  app.listeners.get('click')?.({ target, preventDefault() {} });
  assert.deepEqual(focused, ['p7']);
});

test('failed agent summaries mark live and gone names as errors', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,agents:[{name:'worker',target:{type:'pane',pane:'p1'}}]};
    const card=name=>({direction:'out',to:{name},text:{text:'Refused',cut:0},call:{tool:'message',mode:'message'},outcome:{ok:false,failure:'refused',message:'Refused'}});
    agentStep(card('worker'),0,'live');agentStep(card('ghost'),0,'gone');
    const view=openers.get('run:10000:0').view,marks=runMarks.get(view);
    return marks.names.children.filter(child=>child?.classList?.contains('err')).map(name=>[name.className,name.children.find(child=>child?.classList?.contains('who')).className]);
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [['err','who'],['err','who gone']]);
  const css = await readFile(new URL('page/page.css', import.meta.url), 'utf8');
  assert.match(css, /\.run \.names \.err \.who\{color:var\(--ko-color-1\)\}/);
});

test('prose links only live agent names outside code and links, and a membership change re-renders agent lines', async () => {
  const app = await page(), html: string[] = [];
  const create = app.context.document.createElement;
  app.context.document.createElement = tag => { const node = create(tag); if (tag === 'template') Object.defineProperty(node, 'innerHTML', { set(value: string) { html.push(value); } }); return node; };
  app.run(`state={...state,agents:[{name:'sidebar',target:{type:'pane',pane:'p1'}},{name:'sidebar-right',target:{type:'pane',pane:'p2'}}]};prose(undefined,'Ask @sidebar-right and @sidebar, not @nobody or me@sidebar; \`@sidebar\` and [@sidebar](https://x.test)',true)`);
  const who = (name: string, pane: string) => `<a class="who" href="#pane:${name}" data-pane="${pane}" title="Focus the pane of @${name}">@${name}</a>`;
  assert.equal(html.join(''), `<p>Ask ${who('sidebar-right', 'p2')} and ${who('sidebar', 'p1')}, not @nobody or me@sidebar; <code>@sidebar</code> and <a href="https://x.test">@sidebar</a></p>\n`);
  assert.deepEqual(Array.from(app.run(`(()=>{
    state={...state,agents:[{name:'sidebar',target:{type:'pane',pane:'p1'}}]};
    const slots=new Map(),view=agentStep({direction:'out',to:{name:'sidebar'},text:{text:'x',cut:0},call:{tool:'message',mode:'message'}},0,'k',slots);
    const before=view.children[0].children[1].children[0].children[1].className;

    apply({...state,type:'state',agents:[]});renderDirty();
    return [before,view.children[0].children[1].children[0].children[1].className]
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
    [incoming({ form: 'notice' }), 'notice from @worker', false],
    [incoming({ form: 'message', relation: 'child' }), 'message from @worker subagent', false],
    [incoming({ form: 'message', relation: 'descendant' }), 'message from @worker subagent', false],
    [incoming({ form: 'message', relation: 'parent' }), 'message from @worker parent', false],
    [incoming({ form: 'message', relation: 'sibling' }), 'message from @worker peer', false],
    [incoming({ form: 'message', relation: 'sibling_descendant' }), 'message from @worker peer', false],
    [incoming({ form: 'steer', relation: 'parent' }), 'steer from @worker parent', false],
    [incoming({ form: 'report', relation: 'child' }), 'report from @worker subagent', false],
    [outgoing({ tool: 'spawn', fork: false }, { ok: false, failure: 'error', message: 'Cannot start' }), 'refused to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'refused', message: 'Refused' }), 'refused to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'gone', message: 'Gone' }), 'gone to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'not_found', message: 'no agent named worker' }), 'no agent named worker to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'ambiguous', message: 'several agents named worker' }), 'several agents named worker to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'not_running', message: 'worker is not running' }), 'worker is not running to @worker', true],
    [outgoing({ tool: 'message', mode: 'message' }, { ok: false, failure: 'error', message: 'send failed' }), 'send failed to @worker', true],
  ];
  for (const [card, phrase, failed] of cases) {
    const result = app.run(`(()=>{const view=agentStep(${JSON.stringify(card)},0,'card',new Map());const header=view.children[0],lead=header.children[1].children[0];return {phrase:lead.children.map(child=>child.textContent??child).join(''),classes:header.children.map(child=>child.className),time:header.children.at(-1).children.at(-1).tagName,failed:lead.classList.contains('err')}})()`);
    assert.equal(result.phrase, phrase);
    assert.deepEqual(Array.from(result.classes), ['chev', 'sum', 'outcome']);
    assert.equal(result.failed, failed);
    assert.equal(result.time, 'SPAN');
  }
});

test('step previews require exactly Shift-Command and a stationary press', async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{const urls=[];window.ko={preview:url=>urls.push(url)};const block={type:'tool',name:'read',args:{text:JSON.stringify({path:'file.txt'})},state:{type:'done',error:false,result:{text:'ok',images:[]}}};const item={seq:7,at:0,final:true,stop:'stop',blocks:[block]};const tree=run([{kind:'block',key:'7:2',index:2,item,block,slots:new Map()}]);const row=tree.children[1].children[0].children[0],label=row.children[1].children.find(node=>node?.classList?.contains('preview-file'));label.getBoundingClientRect=()=>({x:0,y:0,width:30,height:20});const event={button:0,clientX:2,clientY:3,shiftKey:true,metaKey:true,altKey:false,ctrlKey:false,preventDefault(){},stopPropagation(){}};label.onmousedown(event);label.onclick(event);for(const changes of [{shiftKey:false},{altKey:true},{ctrlKey:true}]){label.onmousedown({...event,...changes});label.onclick({...event,...changes})}label.onmousedown(event);label.onclick({...event,shiftKey:false,metaKey:false});if(urls.length!==2)return false;label.onmousedown(event);label.onclick({...event,clientX:5});return urls.length===2&&urls[0]==='/steps/7/2/file'})()`), true);
});

test('browser lightbox Escape closes before abort and keeps the draft', async () => {
  const app = await page();
  const requests: string[] = []; app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  assert.equal(app.run(`(()=>{state.life={type:'ready'};state.working=true;editor.setText('draft');const target=node('button');preview('/images/0',target,'image',composerFocus);return document.querySelector('.lightbox')!==null})()`), true);
  let prevented = false;
  app.listeners.get('keydown')?.({ key: 'Escape', preventDefault() { prevented = true; }, stopPropagation() {} });
  assert.equal(prevented, true); assert.equal(app.context.document.querySelector('.lightbox'), null); assert.equal(app.text(), 'draft');
  assert.deepEqual(requests.filter(path => ['/abort', '/queue/clear', '/clear_queue'].includes(path)), []);
  assert.equal(app.context.document.activeElement, app.prompt());
});

test('path links keep code paths interactive and literal text plain', async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{const fragment=document.createElement('div'),codes=['koa/koa.ts:120','koa.ts','git add koa.ts'].map(text=>{const code=document.createElement('code');code.textContent=text;fragment.append(code);return code});decoratePaths(fragment);return JSON.stringify(codes.map(code=>code.classList.contains('path-open')))})()`), '[true,true,false]');
});

test('thumbnails call native preview with their resource and rectangle', async () => {
  const app = await page();
  assert.equal(app.run(`(()=>{window.ko={preview:(url,rect)=>{window.lastPreview={url,rect}}};const images=thumbnails([{id:'0.0',revision:0,mimeType:'image/png',bytes:10}],()=>new Map());images.load();const button=images.view.children[0];button.getBoundingClientRect=()=>({x:1,y:2,width:30,height:40});button.onclick();return window.lastPreview.url==='/images/0.0?e=&r=0'&&window.lastPreview.rect.width===30})()`), true);
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
  app.run("state={...state,life:{type:'ready'},sessionId:'s1'};refreshComposer();editor.setText('draft')");
  app.listeners.get('keydown')?.({ key: 'g', ctrlKey: true, preventDefault() {} });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, [{ path: '/editor/open', body: { sessionId: 's1', text: 'draft' } }]);
  assert.deepEqual(focused, ['pane_10']);
  refuse = true;
  app.listeners.get('keydown')?.({ key: 'g', ctrlKey: true, preventDefault() {} });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(app.run("element('error').textContent"), 'C-g needs a ko pane');
});

test('while an editor is open the draft is read-only, sending and Escape do nothing and the composer names the editor', async () => {
  const app = await page(), requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  const result = app.run(`
    state={...state,life:{type:'ready'},working:true,sessionId:'s1',edit:{pane:'pane_10',editor:'nano'}};
    editor.setText('draft');refreshComposer();
    const open={title:element('composer').getAttribute('title'),send:canSend('draft')};
    [open,()=>{apply({type:'state',...state,edit:undefined});return element('composer').getAttribute('title')}];
  `);
  assert.equal(app.prompt()?.readOnly, true);
  assert.deepEqual(JSON.parse(JSON.stringify(result[0])), { title: 'Editing in nano', send: false });
  app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  app.listeners.get('keydown')?.({ key: 'Escape', target: app.prompt(), preventDefault() {} });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.deepEqual(requests, []);
  assert.equal(app.text(), 'draft');
  assert.equal(result[1](), null);
  assert.equal(app.prompt()?.readOnly, false);
});

test('the draft is locked from the first C-g until the editor request answers', async () => {
  const app = await page();
  let answer: (value: object) => void = () => {};
  app.context.fetch = async () => new Promise(resolve => { answer = value => resolve({ ok: true, json: async () => value }); });
  const result = app.run(`
    state={...state,life:{type:'ready'},sessionId:'s1'};editor.setText('draft');
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
    state={...state,life:{type:'ready'},sessionId:'s1',edit:{pane:'pane_10',editor:'nano'}};
    refreshComposer();document.activeElement=undefined;
    () => { apply({type:'state',...state,edit:undefined}); };
  `);
  assert.notEqual(app.context.document.activeElement, app.prompt());
  end();
  assert.equal(app.context.document.activeElement, app.prompt());
});

test('while an editor is open the composer is dimmed, a click focuses the editor pane and Enter does nothing', async () => {
  const app = await page(), requests: string[] = [], focused: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  app.context.window.ko = { focus: (pane: string) => { focused.push(pane); } };
  const field = app.elements.get('field') ?? app.context.document.getElementById('field');
  const end = app.run(`
    state={...state,life:{type:'ready'},sessionId:'s1',edit:{pane:'pane_10',editor:'nano'}};
    editor.setText('draft');refreshComposer();
    () => { apply({type:'state',...state,edit:undefined}); };
  `);
  assert.equal(field.inert, true);
  assert.equal(field.classList.contains('editing'), true);
  const target = app.context.document.getElementById('model');
  app.context.document.getElementById('composer').append(target);
  let down = false, click = false;
  app.listeners.get('mousedown')?.({ target, preventDefault() { down = true; } });
  app.listeners.get('click')?.({ target, preventDefault() { click = true; } });
  assert.deepEqual([down, click, focused], [true, true, ['pane_10']]);
  app.listeners.get('keydown')?.({ key: 'Enter', target: app.prompt(), preventDefault() {} });
  assert.deepEqual(requests, []);
  assert.equal(app.text(), 'draft');
  end();
  assert.equal(field.classList.contains('editing'), false);
  app.listeners.get('click')?.({ target, preventDefault() {} });
  assert.deepEqual(focused, ['pane_10']);
});

test('while an editor is open a drop attaches nothing and shows no drop target', async () => {
  const app = await page(), requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  app.run("state={...state,life:{type:'ready'},sessionId:'s1',edit:{pane:'pane_10',editor:'nano'}};refreshComposer()");
  let prevented = false;
  app.listeners.get('dragenter')?.({ dataTransfer: { types: ['Files'] } });
  assert.equal(app.elements.get('field')?.classList.contains('drop'), false);
  app.listeners.get('drop')?.({ dataTransfer: { files: [new File(['x'], 'a.txt')], items: [] }, preventDefault() { prevented = true; } });
  await new Promise<void>(resolve => setImmediate(resolve));
  assert.equal(prevented, true);
  assert.deepEqual(requests, []);
  assert.equal(app.run('draft.count'), 0);
});

async function latestPage() {
  const fixture = await revealPage();
  const { app, evaluate } = fixture, doc = app.context.document;
  Object.assign(app.context, { matchMedia: () => ({ matches: false }) });
  const create = doc.createElement;
  doc.createElement = tag => {
    const node = create(tag), rect = node.getBoundingClientRect;
    node.getBoundingClientRect = () => {
      let row = node;
      while (row.parent && row.parent !== doc.getElementById('items')) row = row.parent;
      if (row === node || row.parent !== doc.getElementById('items')) return rect();
      const outer = row.getBoundingClientRect(), own = rect();
      return { ...own, top: outer.top + node.offsetTop, bottom: outer.top + node.offsetTop + (own.height ?? node.offsetHeight) };
    };
    return node;
  };
  const text = (seq: number) => ({ seq, revision: 0, kind: 'assistant', final: true, blocks: [{ type: 'text', text: 'reply ' + seq }] });
  const own = (seq: number) => ({ seq, revision: 0, at: 1, kind: 'user', text: 'mine', images: [], attachments: [] });
  const add = (item: object) => { evaluate(`apply({type:'item',item:${JSON.stringify(item)}})`); fixture.step(0); };
  const scroll = (top: number, height = 1000) => { evaluate(`Object.assign(element('scroll'),{scrollHeight:${height},clientHeight:100});decide({type:'input',direction:${top}<element('scroll').scrollHeight-element('scroll').clientHeight?'up':'down'});element('scroll').scrollTop=${top};element('scroll').onscroll();frame()`); };
  const dividers = () => String(evaluate("element('items').children.flatMap(node => node.classList.contains('unread-first') && !node.classList.contains('unread-clearing') ? ['divider', node.dataset.seq] : [node.dataset.seq]).join()"));
  const latest = () => String(evaluate("[element('latest').textContent, element('latest').classList.contains('show')].join()"));
  const focus = (value: boolean) => { doc.hasFocus = () => value; app.windowListeners.get(value ? 'focus' : 'blur')?.(); evaluate('frame()'); };
  const go = (id: string, session = id === 'r' ? 's' : 'c') => evaluate(`apply({...state,type:'state',sessionId:'${session}',view:{id:'${id}',path:[{id:'r',name:'ko'}${id === 'r' ? '' : ",{id:'" + id + "',name:'x'}"}]},life:{type:'ready'}})`);
  evaluate("apply({type:'reset',epoch:'a',more:false,items:[]});element('dock').getBoundingClientRect=()=>({top:100})");
  fixture.step(16); fixture.step(0);
  return { ...fixture, text, own, add, scroll, dividers, latest, focus, go, doc };
}


const think = (seq: number, text = 'hmm') => ({ seq, revision: 0, kind: 'assistant', final: false, blocks: [{ type: 'thinking', text, redacted: false }] });

test('an assistant item with nothing to show gets no divider and no count', async () => {
  const page = await latestPage();
  page.add(page.text(0)); page.add(page.own(1));
  page.scroll(0);
  page.add({ ...page.text(2), blocks: [] });
  page.add({ ...page.text(3), blocks: [{ type: 'text', text: '' }] });
  assert.equal(page.dividers(), '0,1,2');
  assert.equal(page.latest(), '↓ Latest,true');
});

test('steps that join a run create no unread divider', async () => {
  const page = await latestPage();
  page.add(page.text(0)); page.add(page.own(1));
  page.scroll(0);
  page.add(think(2));
  assert.equal(page.dividers(), '0,1,2');
  page.add(think(3));
  assert.equal(page.dividers(), '0,1,2,3');
  assert.equal(page.latest(), '↓ Latest,true');
});

test('mixed idle steps create no unread messages or divider', async () => {
  const page = await latestPage();
  page.add(page.text(0)); page.scroll(0); page.add(think(1));
  const report = (seq: number) => ({seq,revision:0,at:seq,kind:'agent',final:true,direction:'in',from:{name:'worker'},text:{text:'Report',cut:0},inbound:{form:'report'}});
  page.add(report(2));
  page.add({seq:3,revision:0,at:3,kind:'job',final:true,job:{id:'j',name:'build',service:false,log:'/tmp/build.log'},event:{type:'ended',end:{type:'exit',code:0},tail:{text:'PASS',cut:0}}});
  page.add(think(4));
  assert.equal(page.latest(), '↓ Latest,true');
  assert.equal(page.evaluate('scrollDecision.divider'), undefined);
  page.add(page.text(5));
  const divider = page.evaluate('divider');
  page.add(report(6));
  assert.equal(page.latest(), '↓ 1 new,true');
  assert.equal(page.evaluate('divider'), divider);
});

test('a patch that empties the item of the divider moves or removes it, and that item no longer counts', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(0);
  page.add(page.text(1)); page.add(page.text(2));
  assert.equal(page.dividers(), '0,divider,1,2');
  page.add({ ...page.text(1), revision: 1, blocks: [] });
  assert.equal(page.dividers(), '0,1,divider,2');
  assert.equal(page.latest(), '↓ 1 new,true');
  page.add({ ...page.text(2), revision: 1, blocks: [] });
  assert.equal(page.dividers(), '0,1,2');
  assert.equal(page.latest(), '↓ Latest,true');
});

test('an item that gets its content later is new once, and streaming growth is not new', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(0);
  page.add({ ...page.text(1), blocks: [] });
  assert.equal(page.dividers(), '0,1');
  page.add({ ...page.text(1), revision: 1 });
  assert.equal(page.dividers(), '0,divider,1');
  assert.equal(page.latest(), '↓ 1 new,true');
  page.add({ ...page.text(1), revision: 2, blocks: [{ type: 'text', text: 'reply 1 and more' }] });
  assert.equal(page.latest(), '↓ 1 new,true');
});

test('the divider stands above the first new item in the transcript order, not in the order that they became visible', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(0);
  page.add({ ...page.text(1), blocks: [] });
  page.add(page.text(2));
  assert.equal(page.dividers(), '0,1,divider,2');
  page.add({ ...page.text(1), revision: 1 });
  assert.equal(page.dividers(), '0,divider,1,2');
  assert.equal(page.latest(), '↓ 2 new,true');
});

test('an empty item that arrived while following and gets its first content after the reader scrolled up is counted once', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.add({ ...page.text(1), blocks: [] });
  page.step(16);
  page.scroll(0);
  page.add({ ...page.text(1), revision: 1 });
  assert.equal(page.dividers(), '0,divider,1');
  assert.equal(page.latest(), '↓ 1 new,true');
});

const card = (seq: number) => ({ seq, revision: 0, kind: 'assistant', final: true, blocks: [{ type: 'tool', id: 'c' + seq, name: 'spawn_agent', args: { text: '{}' }, state: { type: 'done', error: false, result: { text: '', images: [] } }, agent: { direction: 'out', to: { name: 'worker', session: 'w' }, text: { text: 'Check the module', cut: 0 }, call: { tool: 'spawn', fork: false }, outcome: { ok: true } } }] });

test('an agent run, error notice and blank text do not count', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(0);
  page.add(card(1));
  page.add({ ...page.text(2), blocks: [], stop: 'error', error: 'boom' });
  page.add({ ...page.text(3), blocks: [{ type: 'text', text: ' \n ' }] });
  assert.equal(page.dividers(), '0,1,2');
  assert.equal(page.latest(), '↓ Latest,true');
  page.add({ ...page.text(4), blocks: [{ type: 'text', text: ' ' }, { type: 'text', text: 'words' }] });
  assert.equal(page.evaluate('scrollDecision.divider.seq'), 4);
  assert.equal(page.latest(), '↓ 1 new,true');
});

test('nonblank text counts as new while its reveal is still closed, and a card item that gains text arrives once', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(0);
  page.add({ seq: 1, revision: 0, kind: 'assistant', final: false, blocks: [{ type: 'text', text: 'Intro.\n\nwaiting tail words' }] });
  assert.equal(page.dividers(), '0,divider,1');
  page.add(card(2));
  assert.equal(page.dividers(), '0,divider,1,2');
  page.add({ ...card(2), revision: 1, blocks: [...card(2).blocks, { type: 'text', text: 'done' }] });
  assert.equal(page.dividers(), '0,divider,1,2');
  assert.equal(page.latest(), '↓ 2 new,true');
});

test('taking over a run does not make a step item unread', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(0);
  page.add(think(2));
  page.add(think(1));
  assert.equal(page.dividers(), '0,1,2');
  assert.equal(page.latest(), '↓ Latest,true');
});













async function blockPage(position: number) {
  const page = await latestPage(), rounds = { count: 0, relevant: false, real: 600, late: 0 };
  let block: InstanceType<typeof page.app.context.Node> | undefined;
  const find = (node: InstanceType<typeof page.app.context.Node>): InstanceType<typeof page.app.context.Node> | undefined => node.classList.contains('msg') ? node : node.children.map(find).find(Boolean);
  const found = () => {
    const row = page.app.context.document.getElementById('items').children.find((child: { dataset?: { seq?: string } }) => child.dataset?.seq === '1');
    if (!block && row && (block = find(row))) block.sizeOf = () => rounds.relevant ? rounds.real + rounds.late : 100;
    return block;
  };
  page.add(page.text(0));
  page.scroll(position);
  page.layout.height = () => 1000 + (found()?.sizeOf?.() ?? 0);
  page.hooks.delivered = () => { rounds.relevant = true; rounds.count++; };
  const gap = () => Number(page.evaluate("element('scroll').scrollHeight - element('scroll').clientHeight - element('scroll').scrollTop"));
  return { ...page, gap, rounds };
}

test('an animation frame preserves physical elastic overscroll during Latest travel', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(100);
  page.evaluate("decide({type:'latest'});frame()");
  assert.equal(page.evaluate("scrolling.mode.kind==='travel'"), true);
  page.layout.elastic = true;
  page.evaluate("element('scroll').scrollTop=940;element('scroll').onscroll()");
  assert.equal(page.evaluate("element('scroll').scrollTop"), 940);
  let writes = 0;
  page.hooks.wrote = () => { writes++; };
  page.step(16);
  assert.equal(writes, 0);
  assert.equal(page.evaluate("element('scroll').scrollTop"), 940);
});

test('a correction frame writes the bottom that the layout has now, not the one that the last delivery read', async () => {
  const page = await blockPage(900);
  page.add(page.text(1));
  page.rounds.late = 300;
  for (const [frame, callback] of [...page.queued]) { page.queued.delete(frame); callback(); }
  assert.equal(page.gap(), 0);
});

test('a block that grows below a reader leaves the reader where they are', async () => {
  const page = await blockPage(10);
  page.add(page.text(1));
  assert.equal(page.evaluate("[element('scroll').scrollTop, scrolling.mode.kind].join()"), '10,reader');
});

test('a delivery of only a reveal child still scrolls a following pane to the grown bottom', async () => {
  const page = await latestPage();
  page.add(page.text(0));
  page.scroll(900);
  page.evaluate("element('scroll').scrollHeight=1200;const child=document.createElement('div');element('items').append(child);resized([{target:child,borderBoxSize:[{blockSize:0}]}]);frame()");
  assert.equal(page.evaluate("element('scroll').scrollTop"), 1100);
});















async function flowPage(margin = 0) {
  const page = await latestPage(), { app, evaluate, layout } = page, doc = app.context.document;
  const pad = { value: 0 }, extra = new Map<number, number>(), origin = { value: 0 };
  const seqs = (): number[] => JSON.parse(String(evaluate("JSON.stringify([...views.keys()].sort((a,b)=>a-b))")));
  const starts = new Map<unknown, number>(), now = () => Number(app.context.performance.now());
  const grown = (node: { className: string }) => { if (node.className.includes('hold')) return 0; if (!node.className.includes('grow')) return 1; if (!starts.has(node)) starts.set(node, now()); return Math.min(1, (now() - Number(starts.get(node))) / 220); };
  type Box = { tagName: string; className: string; children: Box[]; parent?: Box; style: Record<string, string>; dataset: Record<string, string>; rects?: { top: number; bottom: number }[] };
  const count = (node: Box): number => {
    const classes = (node.className ?? '').split(' '), open = classes.includes('open');
    const own = node.tagName === 'P' || node.tagName === 'PRE' && !node.parent?.className.includes('out') ? 100 * grown(node) : node.tagName === 'PRE' ? Math.min(12, String(Reflect.get(node, 'textContent') ?? '').split('\n').length) * 20 : classes.some(name => name === 'run' || name === 'cmdrun') ? 33 : 0;
    const content = own + (node.children ?? []).reduce((total, child) => total + (!open && (child.className ?? '').split(' ').some(name => ['detail', 'steps', 'bd', 'out'].includes(name)) ? 0 : count(child)), 0);
    return classes.includes('reveal') ? Math.max(parseFloat(node.style?.minHeight ?? '') || 0, Math.min(content, parseFloat(node.style?.maxHeight ?? '') || 0)) : Math.max(Math.min(parseFloat(String(node.style?.minHeight).replace(/^min\(/,'')) || 0, node.parent?.className.includes('out') ? 240 : Infinity), content);
  };
  const isBox = (value: unknown): value is Box => typeof value === 'object' && value !== null && 'children' in value;
  const size = (seq: number) => { const view = evaluate(`views.get(${seq}).view`); assert.ok(isBox(view)); return count(view) + (extra.get(seq) ?? 0); };
  const list = doc.getElementById('items'), slot = doc.getElementById('tail-slot');
  slot.offsetHeight = 33;
  assert.ok(isBox(list));
  Object.defineProperty(list, 'offsetTop', { get: () => origin.value });
  const px = (value: unknown) => parseFloat(String(value ?? '')) || 0;
  const flow = (until?: number | Box) => {
    let y = origin.value + px(list.style.paddingTop);
    for (const child of list.children) {
      if (child === until) return y;
      if (child.dataset.seq !== undefined) { if (Number(child.dataset.seq) === until) return y; y += size(Number(child.dataset.seq)) + (child.hidden ? 0 : margin); }
      else if (child.className.includes('gap')) y += px(child.style.height);
      else if (child.className.includes('cmdrun')) y += count(child) + margin;
    }
    return until === undefined ? y + px(list.style.paddingBottom) + pad.value + (slot.hidden ? 0 : slot.offsetHeight) : y;
  };
  const above = (seq: number) => flow(seq);
  layout.height = flow;
  const computed = app.context.getComputedStyle;
  app.context.getComputedStyle = (node?: { tagName?: string; dataset?: Record<string, string> }, pseudo?: string) => node?.dataset?.seq !== undefined ? { ...computed(node, pseudo), marginBottom: margin + 'px' } : computed(node, pseudo);
  const create = doc.createElement;
  doc.createElement = (tag: string) => {
    const node = create(tag), own = node.getBoundingClientRect.bind(node);
    Object.defineProperties(node, { offsetTop: { get: () => { const seq = Reflect.get(Reflect.get(node, 'dataset') ?? {}, 'seq'); return seq !== undefined ? above(Number(seq)) : node.className.includes('newmsgs') && isBox(node) ? flow(node) : 0; } }, offsetHeight: { get: () => { const seq = Reflect.get(Reflect.get(node, 'dataset') ?? {}, 'seq'); return seq === undefined ? 0 : size(Number(seq)); } } });
    return Object.assign(node, { getBoundingClientRect: () => {
      const seq = Reflect.get(Reflect.get(node, 'dataset') ?? {}, 'seq');
      if (seq === undefined) return own();
      const top = above(Number(seq)) - Number(evaluate("element('scroll').scrollTop"));
      return { left: 0, top, bottom: top + size(Number(seq)), height: size(Number(seq)) };
    } });
  };
  evaluate("element('scroll').getBoundingClientRect=()=>({top:0})");
  const reveal = (seq: number, text: string) => ({ type: 'item', item: { seq, revision: 0, kind: 'assistant', final: false, blocks: [{ type: 'text', text }], stop: '', error: '' } });
  const suffix = (seq: number, revision: number, text: string, final = false) => ({ type: 'patch', seq, baseRevision: revision - 1, revision, final, stop: '', error: '', blocks: [{ index: 0, suffix: text }] });
  const top = () => Number(evaluate("element('scroll').scrollTop"));
  const bottom = () => Math.max(0, Number(evaluate("element('scroll').scrollHeight - element('scroll').clientHeight")));
  const settle = (frames = 120) => { for (let frame = 0; frame < frames; frame++) page.step(16); };
  const reader = (value: number) => evaluate(`decide({type:'input',direction:${value}<element('scroll').scrollHeight-element('scroll').clientHeight?'up':'down'});element('scroll').scrollTop=${value};element('scroll').onscroll();frame()`);
  const offset = (seq: number) => Number(evaluate(`views.get(${seq}).view.getBoundingClientRect().top`));
  const open = (items: object[], more = false) => { evaluate(`apply({type:'reset',epoch:'a',more:${more},items:${JSON.stringify(items)}})`); page.step(0); };
  const gate = (items: object[]) => { let release = () => {}; Object.assign(app.context, { fetch: () => new Promise(resolve => { release = () => resolve({ ok: true, json: async () => ({ type: 'reset', epoch: 'a', more: false, items }) }); }) }); return () => release(); };
  const settled = () => new Promise<void>(resolve => setImmediate(resolve));
  const checkFollowing = followMonitor(), monitor: { exemption?: FollowSample['exemption']; enabled: boolean; samples: FollowSample[] } = { enabled: true, samples: [] };
  let priorFolds = '', priorLive = '';
  page.hooks.frame = () => {
    const snapshot: FollowSample & { folds: string; live: string } = JSON.parse(String(evaluate(`JSON.stringify({scope:JSON.stringify([state.sessionId,scrolling.scope.view,scrolling.scope.topic]),viewport:element('scroll').clientHeight,width:element('scroll').clientWidth,dock:element('scroll').clientHeight-dockHeight,following:scrolling.mode.kind==='following'&&(window.koaFocused??document.hasFocus()),covered:!!transition,max:Math.max(0,element('scroll').scrollHeight-element('scroll').clientHeight),folds:JSON.stringify([...folds]),live:JSON.stringify([...live]),rows:[...views].flatMap(([seq,{view}])=>unitRows(seq).map(row=>({key:rowKey(row),top:view.getBoundingClientRect().top,bottom:view.getBoundingClientRect().bottom})))})`)));
    snapshot.bottomSpace = snapshot.dock - (flow() - top());
    const beforeFolds: [string, boolean][] = priorFolds ? JSON.parse(priorFolds) : [], afterFolds: [string, boolean][] = JSON.parse(snapshot.folds);
    const beforeLive: number[] = priorLive ? JSON.parse(priorLive) : [], afterLive: number[] = JSON.parse(snapshot.live);
    snapshot.exemption = monitor.exemption ?? (beforeFolds.some(([key, value]) => afterFolds.some(([next, open]) => next === key && open !== value)) ? 'fold' : beforeLive.some(seq => !afterLive.includes(seq)) ? 'completion' : undefined);
    priorFolds = snapshot.folds; priorLive = snapshot.live;
    monitor.exemption = undefined;
    monitor.samples.push(snapshot);
    if (monitor.enabled) checkFollowing(snapshot);
  };
  const trace = (frames: number) => { const tops: number[] = [], gaps: number[] = []; for (let frame = 0; frame < frames; frame++) { page.step(16); tops.push(top()); gaps.push(bottom() - top()); } return { tops, gaps }; };
  const wheel = (deltaY: number) => evaluate(`element('scroll').handlers.get('wheel')?.({deltaY:${deltaY},deltaX:0})`);
  return { ...page, pad, extra, origin, seqs, reveal, suffix, top, bottom, settle, reader, wheel, offset, open, gate, settled, trace, monitor };
}

test('a following dock can grow for a dialog and shrink without retaining its peak height', async () => {
  const page=await flowPage();page.pad.value=96;page.evaluate("element('scroll').clientHeight=400");
  page.open(Array.from({length:40},(_,seq)=>page.text(seq)));page.settle(8);
  const before=page.monitor.samples.at(-1)?.bottomSpace;
  page.pad.value=220;page.layout.dock=220;page.evaluate("dockHeight=220;decide({type:'layout',cause:'layout'})");page.settle(3);
  page.pad.value=96;page.layout.dock=96;page.evaluate("dockHeight=96;decide({type:'layout',cause:'layout'})");page.settle(3);
  assert.equal(page.top(),page.bottom());
  assert.equal(page.monitor.samples.at(-1)?.bottomSpace,before);
});

test('a folded-fence reset leaves the same bottom space as a fresh short transcript', async () => {
  const page=await flowPage();page.pad.value=96;page.evaluate("element('scroll').clientHeight=400");
  page.extra.set(0,200);
  for(const seq of [1,2,3])page.extra.set(seq,-80);
  page.go('r');
  page.open([{seq:0,at:0,revision:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'```\n'+Array(300).fill('fenced line').join('\n')+'\n```'}]},page.text(1)]);
  page.settle(12);
  assert.ok(page.bottom()>0,'the measured folded fence makes the initial transcript scroll');
  const short=[page.text(2),page.text(3)];
  const bottomSpace=()=>Number(page.evaluate("element('scroll').clientHeight-dockHeight-element('transcript').offsetHeight"))+page.pad.value+page.top();
  page.open(short);page.settle(12);
  const resetSpace=bottomSpace();
  page.go('fresh');page.open(short);page.settle(12);
  assert.equal(resetSpace,bottomSpace(),'a measured folded fence cannot leave extra space after a short reset');
  assert.equal(page.top(),0,'the short reference transcript fits without scrolling');
});

test('a topic projection followed by blur before its frame lands at the new bottom', async () => {
  const page=await flowPage();page.pad.value=96;page.evaluate("element('scroll').clientHeight=400");page.go('r');
  page.evaluate("state={...state,topics:[{name:'one'},{name:'two'}]}");
  page.open(Array.from({length:100},(_,seq)=>({...page.text(seq),blocks:[{type:'text',topic:seq<95?'one':'two',text:'row '+seq}]})));page.settle(12);
  page.evaluate("topics.debug.scopeData(topics.scope()).filter='two';refreshTopicItems();for(const seq of order)changedItem(seq,false)");
  page.focus(false);page.settle(12);
  assert.equal(page.top(),page.bottom(),'blur cannot retain the old projection height');
  const usable=Number(page.evaluate("element('scroll').clientHeight-dockHeight")),endingBottom=Number(page.evaluate("element('transcript').offsetHeight"))-page.pad.value-page.top();
  assert.equal(endingBottom,usable,'the short topic ends at the dock');
});

test('a first subagent landing with many folded runs never commits an empty viewport after estimate corrections', async () => {
  const page=await flowPage();
  page.pad.value=96;page.evaluate("element('scroll').clientHeight=400");
  page.go('r');page.open(Array.from({length:100},(_,seq)=>page.text(seq)));page.settle(12);
  page.evaluate("windowStep=(step=>function(geo,rendered){let spent=0;const now=performance.now;performance.now=()=>now()+spent++*4;try{return step(geo,rendered)}finally{performance.now=now}})(windowStep)");
  const rows=Array.from({length:160},(_,seq)=>seq%2?{seq,at:seq,revision:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'thinking',text:'Checking '+seq,started:1,ended:2}]}:{seq,at:seq,revision:0,kind:'user',final:true,text:'Next request',images:[],attachments:[]});
  page.go('first-child');page.open(rows);
  let mounting=0;for(let frame=0;frame<80;frame++){page.step(16);if(page.evaluate('windowDirty'))mounting++;}
  assert.ok(mounting>1,'the deterministic budget spreads mounting over several frames');
  assert.equal(page.evaluate('!!transition'),false,'the cover has committed');
  const usable=Number(page.evaluate("element('scroll').clientHeight-dockHeight"));
  const visible=page.seqs().filter(seq=>page.offset(seq)<usable&&Number(page.evaluate(`views.get(${seq}).view.getBoundingClientRect().bottom`))>0);
  assert.ok(visible.length>0,'a committed subagent view contains a message or run in the usable viewport');
  assert.equal(page.top(),page.bottom(),'the subagent follower is at the actual bottom');
  const endingBottom=Number(page.evaluate("element('transcript').offsetHeight"))-page.pad.value-page.top();
  assert.equal(endingBottom,usable,'the ending row reaches the dock without a blank reserve');
});

test('a completed following view has the same visible rows and ending space after a view or topic round trip', async () => {
  for (const destination of ['view','topic']) {
    const page = await flowPage();
    const rows = Array.from({length: 30}, (_, seq) => ({...page.text(seq),at:seq,blocks:[{type:'text',topic:'one',text:'row '+seq}]}));
    page.go('r'); page.open(rows); page.evaluate("state={...state,topics:[{name:'one'},{name:'two'}]}"); page.settle(8);
    const sample = () => { const state=page.monitor.samples.at(-1); assert.ok(state); return {rows:state.rows.filter(row=>row.bottom>0&&row.top<state.dock),bottomSpace:state.bottomSpace}; };
    const before=sample();
    if(destination==='view') { page.go('a');page.open([page.text(100)]);page.settle(5);page.go('r');page.open(rows); }
    else {
      page.evaluate("topics.debug.scopeData(topics.scope()).filter='two';refreshTopicItems()");page.settle(5);
      page.evaluate("topics.debug.scopeData(topics.scope()).filter=undefined;refreshTopicItems()");
    }
    page.settle(8);
    assert.deepEqual(sample(),before,destination);
  }
});

test('the following monitor covers inline syntax and structural tail decisions in each frame', async () => {
  for (const parts of [
    ['one two **hello', ' world** and more', '\n\nDone'],
    ['one two `hello', ' world` and more', '\n\nDone'],
    ['one two [**hello', '**](https://example.com) and more', '\n\nDone'],
    ['```\nalpha\n', '``', '`\n', '\nDone'],
    ['| a | b |\n', '| - | - |\n', '| c | d |\n', '\nDone'],
    ['Heading', '\n===', '\n\nDone'],
  ]) {
    const page = await flowPage();
    page.open(Array.from({length: 20}, (_, seq) => ({seq,at:seq,revision:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'row '+seq}]})));
    page.settle(6);
    page.deliver({type:'item',item:{seq:20,at:20,revision:0,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'text',text:parts[0]}]}});
    page.step(0); page.step(1500);
    for (let index=1;index<parts.length;index++) { page.deliver(page.suffix(20,index,parts[index])); page.step(16); page.step(1500); }
    assert.equal(page.top(), page.bottom(), parts.join(''));
    assert.ok(page.monitor.samples.some(sample => sample.following && sample.max > 1));
  }
});

test('following keeps the ending row at the dock when a measured row above it shrinks', async () => {
  const page = await flowPage();
  page.pad.value=96;page.evaluate("element('scroll').clientHeight=400");
  const rows = Array.from({length: 40}, (_, seq) => ({seq,at:seq,revision:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'row '+seq}]}));
  for(const row of rows)page.extra.set(row.seq,-80);
  page.open(rows); page.settle(8);
  page.extra.set(24, 0); page.evaluate("dirtyExtent(views.get(24).view)"); page.settle(3);
  assert.ok(Number(page.evaluate("views.get(24).view.getBoundingClientRect().bottom"))<=0,'the shrinking row is above the usable viewport');
  const visible=()=>{const sample=page.monitor.samples.at(-1);assert.ok(sample);return sample.rows.filter(row=>row.bottom>0&&row.top<sample.dock).map(row=>[row.key,row.top]);};
  const before = page.monitor.samples.at(-1)?.bottomSpace, positions=visible();
  assert.ok(positions.length>0);
  page.extra.set(24, -80); page.evaluate("dirtyExtent(views.get(24).view)"); page.settle(3);
  assert.equal(page.top(), page.bottom());
  assert.equal(page.monitor.samples.at(-1)?.bottomSpace, before);
  assert.deepEqual(visible(),positions);
});

test('returning to a streaming view reveals no fewer complete units and places prior rows no lower', async () => {
  const page=await flowPage();page.evaluate("element('scroll').clientHeight=400");page.go('r');
  const rows=Array.from({length:100},(_,seq)=>page.text(seq)),tail={seq:100,at:100,revision:0,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'text',text:'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen'}]};
  page.open(rows);page.settle(8);page.deliver({type:'item',item:tail});page.settle(2);
  const shown=Number(page.evaluate("texts.get('100:0').reveal.tail.shown")),position=page.offset(99);
  assert.equal(shown,0,'the live tail is still behind its cap and wait');
  page.go('a');page.open([page.text(200)]);page.settle(5);page.go('r');page.open([...rows,tail]);page.settle(8);
  assert.ok(Number(page.evaluate("texts.get('100:0').reveal.tail.shown"))>shown,'the landing exposes all complete units on its first measurement');
  assert.ok(page.offset(99)<=position,'the prior content is at the same or a higher screen position');
  assert.equal(page.top(),page.bottom());
});

test('a full replacement of the same text block retains its reveal memo and largest extent', async () => {
  const page=await revealPage(200);page.put('one two three four five six seven eight nine');page.step(0);page.step(1500);
  const memo=page.evaluate("texts.get('0:0')");
  page.deliver({type:'patch',seq:0,baseRevision:0,revision:1,final:false,stop:'',error:'',blocks:[{index:0,block:{type:'text',text:'one two three four five six'}}]});page.step(0);
  assert.equal(page.evaluate("texts.get('0:0')"),memo);
  assert.deepEqual(JSON.parse(String(page.evaluate("JSON.stringify([texts.get('0:0').reveal.tail.shown,texts.get('0:0').reveal.tail.view.style.minHeight,texts.get('0:0').reveal.tail.view.style.maxHeight])"))),[40,'40px','20px']);
});

test('a revised reveal holds its largest extent while the replacement unit is unfinished', async () => {
  const page=await revealPage(200);page.put('one two three four five six seven eight nine');page.step(0);page.step(1500);
  page.evaluate("const memo=texts.get('0:0'),tail=memo.reveal.tail;tail.shown=tail.clip=40;tail.units=[{bottom:20,complete:true},{bottom:50,complete:true},{bottom:70,complete:false}];revealStep(memo,performance.now(),200)");
  assert.deepEqual(JSON.parse(String(page.evaluate("JSON.stringify([texts.get('0:0').reveal.tail.shown,texts.get('0:0').reveal.tail.view.style.maxHeight])"))),[50,'50px']);
  page.evaluate("const memo=texts.get('0:0');memo.reveal.tail.units=[{bottom:20,complete:true},{bottom:70,complete:false}];revealStep(memo,performance.now(),200)");
  assert.deepEqual(JSON.parse(String(page.evaluate("JSON.stringify([texts.get('0:0').reveal.tail.shown,texts.get('0:0').reveal.tail.view.style.minHeight,texts.get('0:0').reveal.tail.view.style.maxHeight])"))),[50,'50px','20px']);
  assert.match(String(page.evaluate("texts.get('0:0').reveal.tail.view.style.clipPath")),/100% - 20px/);
});

test('a landing reveals every complete tail unit immediately without entry animation', async () => {
  const page = await revealPage(200);
  page.evaluate("apply({type:'reset',epoch:'landing',more:false,items:[{seq:0,at:0,revision:0,kind:'assistant',final:false,blocks:[{type:'text',text:'one two three four five six seven eight nine ten eleven twelve'}],stop:'',error:''}]})");
  page.step(0);
  assert.equal(tailOf(page).shown, 60);
  assert.equal(page.evaluate("!!element('items').querySelector('.hold,.grow')"), false);
});

test('finished command cards and rows have the same outcome without a duration', async () => {
  const page=await revealPage();
  const headers=page.evaluate(`(()=>{return [{exit:0},{exit:2},{cancelled:true}].map(result=>{
    const value={command:'make',excludeFromContext:false,result:{output:{text:'output',cut:0},...result}};
    const card=commandRun({...value,id:'card',phase:'completed',started:0,ended:12000},'card-'+JSON.stringify(result));
    const row=commandRun({...value,seq:1,at:12000,kind:'bash',revision:0,final:true},'row-'+JSON.stringify(result));
    const header=view=>view.firstElementChild.lastElementChild.children.map(child=>child.textContent).join('');
    return [header(card.view),header(row.view)];
  })})()`);
  assert.deepEqual(JSON.parse(JSON.stringify(headers)),[['',''],['exit 2','exit 2'],['cancelled','cancelled']]);
});

test('new transcript rows stay before pending command cards without changing their order', async () => {
  const page=await revealPage();
  const order=page.evaluate(`(()=>{
    state.bash=['A','B'].map(id=>({id,phase:'running',command:id,excludeFromContext:false,started:0,output:{text:'output',cut:0}}));refreshBash();
    for(const seq of [0,1])put({seq,at:seq,revision:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'row '+seq}]});
    return element('items').children.map(view=>view.dataset.seq??(view===pendingBash.get('A').view?'A':'B'));
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(order)),['0','1','A','B']);
});

test('a reset replaces a completed command card with its finished row in one rendering frame', async () => {
  const page=await revealPage();
  page.evaluate("state={...state,working:false,bash:[{id:'handoff',phase:'completed',command:'pwd',excludeFromContext:false,started:1,ended:2,result:{exit:0,cancelled:false,truncated:false,output:{text:'/work',cut:0}}},{id:'B',phase:'running',command:'make',excludeFromContext:false,started:3,output:{text:'running',cut:0}}]};refreshBash()");page.step(0);
  assert.equal(page.evaluate('pendingBash.size'),2);
  page.deliver({type:'reset',epoch:'handoff',more:false,items:[{seq:0,at:2,revision:0,kind:'bash',final:true,command:'pwd',excludeFromContext:false,result:{exit:0,cancelled:false,truncated:false,output:{text:'/work',cut:0}}}]});page.step(0);
  assert.equal(page.evaluate("pendingBash.size===1&&pendingBash.has('B')"),true,'the reset rendering frame removes only the completed live card');
  assert.equal(page.evaluate("element('items').querySelectorAll('*').filter(node=>node.classList.contains('cmdrun')).length"),2,'the same frame has the finished row and the running command');
});

test('two command output patches before one frame retain following until a user scrolls', async () => {
  const page=await revealPage();
  page.evaluate(`state.bash=[{id:'command',phase:'running',command:'make',excludeFromContext:false,started:0,output:{text:Array(20).fill('line').join('\\n'),cut:0}}];refreshBash();window.commandPre=pendingBash.get('command').view.lastElementChild.firstElementChild;
    {const pre=window.commandPre;let top=0;Object.defineProperties(pre,{scrollHeight:{get:()=>pre.textContent.split('\\n').length*20},clientHeight:{get:()=>100},offsetHeight:{get:()=>100},scrollTop:{get:()=>top,set:value=>top=Math.max(0,Math.min(value,pre.scrollHeight-pre.clientHeight))}})}`);
  page.step(0);
  page.evaluate("for(const count of [30,40]){state.bash[0].output.text=Array(count).fill('line').join('\\n');refreshBash()}");page.step(0);
  assert.equal(page.evaluate('window.commandPre.scrollTop'),700);
  page.evaluate("for(const count of [50,60]){state.bash[0].output.text=Array(count).fill('line').join('\\n');refreshBash()}window.commandPre.scrollTop=40;window.commandPre.onscroll()");page.step(0);
  assert.equal(page.evaluate('window.commandPre.scrollTop'),40);
  page.evaluate("window.commandPre.scrollTop=window.commandPre.scrollHeight;window.commandPre.onscroll();state.bash[0].output.text=Array(70).fill('line').join('\\n');refreshBash();window.commandPre.onscroll()");page.step(0);
  assert.equal(page.evaluate('window.commandPre.scrollTop'),1300,'a delayed scroll event from returning to the bottom cannot cancel the next output patch');
});

test('a command opens finished output at the tail and preserves an inner reader during patches', async () => {
  const page = await revealPage();
  page.evaluate("state.bash=[{id:'command',phase:'running',command:'make',excludeFromContext:false,started:0,output:{text:'first',cut:0}}];refreshBash()");
  page.evaluate("window.commandPre=pendingBash.get('command').view.lastElementChild.firstElementChild;Object.assign(window.commandPre,{scrollHeight:400,clientHeight:100,scrollTop:300,offsetHeight:100})");
  page.evaluate("state.bash[0].output.text='second';refreshBash()"); page.step(0);
  assert.equal(page.evaluate('window.commandPre.scrollTop'), 400);
  page.evaluate('window.commandPre.scrollTop=40');
  page.evaluate("state.bash[0].output.text='third';refreshBash()"); page.step(0);
  assert.equal(page.evaluate('window.commandPre.scrollTop'), 40);
  assert.equal(page.evaluate('window.commandPre.style.minHeight'), 'min(100px, 18em)');
  page.evaluate('window.commandPre.scrollTop=300');
  page.evaluate("state.bash[0].output.text='fourth';refreshBash()"); page.step(0);
  assert.equal(page.evaluate('window.commandPre.scrollTop'), 400);
  assert.equal(page.evaluate("pendingBash.get('command').view.classList.contains('open')"), true);
  page.evaluate("put({seq:1,at:1,kind:'bash',final:true,revision:0,command:'done',excludeFromContext:false,result:{exit:0,output:{text:'finished',cut:0}}})"); page.step(0);
  assert.equal(page.evaluate("views.get(1).view.querySelector('.cmdrun').classList.contains('open')"), true);
});

test('the ending slot is occupied by a finished run and a filtered run with hidden prose', async () => {
  const page = await flowPage();
  page.evaluate("state={...state,sessionId:'ending',view:{id:'root',path:[],type:'root'},topics:[{name:'one'},{name:'two'}]}");
  page.open([{seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'thinking',text:'Checking',topic:'one',started:1,ended:2}]}]);
  assert.equal(page.evaluate("element('tail-slot').hidden"), true, 'a finished run occupies the ending row');
  page.evaluate("put({seq:1,at:1,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'Other topic',topic:'two'}]});topics.debug.scopeData(topics.scope()).filter='one';refreshTopicItems();resetting=true;renderDirty()");
  assert.equal(page.evaluate("element('tail-slot').hidden"), true, 'hidden prose leaves the run occupying the ending row');
  page.evaluate("state={...state,working:true,since:100};reconcileWorking()");
  assert.equal(page.evaluate("working.place.kind"),'run','hidden prose leaves the working dots on the last visible run');
  page.evaluate("state={...state,working:false};reconcileWorking()");
  assert.equal(page.evaluate("element('tail-slot').hidden"),true);
  page.evaluate("topics.debug.scopeData(topics.scope()).filter=undefined;refreshTopicItems();resetting=true;renderDirty()");
  assert.equal(page.evaluate("element('tail-slot').hidden"), false);
  page.evaluate("topics.debug.scopeData(topics.scope()).filter='one';refreshTopicItems();resetting=true;renderDirty()");
  assert.equal(page.evaluate("element('tail-slot').hidden"), true);
});

test('the ending slot is occupied when dots move to a run and when a turn ends', async () => {
  const fixture = await flowPage(), { evaluate } = fixture;
  fixture.open([{seq:0,at:0,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'text',text:'Reply'}]}]);
  evaluate("state={...state,working:true,since:1700000000000};reconcileWorking()");
  const slot = evaluate("element('tail-slot')");
  const before = evaluate("element('scroll').scrollHeight");
  evaluate("put({seq:1,at:1,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'thinking',text:'Checking',started:1}]})");
  assert.equal(evaluate("element('scroll').scrollHeight"), before, 'dots becoming a folded run cannot grow the transcript');
  assert.equal(evaluate("working.place.kind==='run'&&element('tail-slot').hidden"), true);
  const height = evaluate("element('transcript').offsetHeight");
  evaluate("state={...state,working:false};reconcileWorking()");
  assert.equal(evaluate("element('tail-slot')"), slot);
  assert.equal(evaluate("element('tail-slot').hidden"), true);
  assert.equal(evaluate("element('transcript').offsetHeight"), height);
});

test('every transcript fold holds the clicked header in following and reader windows', async () => {
  const cards = [
    `agentStep({direction:'out',to:{name:'worker'},text:{text:'task',cut:0},call:{tool:'spawn',fork:false}},0,'toggle',new Map())`,
    ...['message', 'report'].map(form => `agentStep({direction:'in',from:{name:'worker'},inbound:{form:'${form}',relation:'child'},text:{text:'reply',cut:0}},0,'toggle',new Map())`),
    `noticeRow({key:'toggle',at:0,content:{type:'text',text:'head\\nbody'}})`,
    `commandRun({command:'echo ok',result:{output:{text:'ok',cut:0},exit:0}},'toggle').view`,
    `(()=>{const item={kind:'job',seq:0,at:0,final:true,job:{id:'job',name:'job',log:'/tmp/job'},event:{type:'stream',batch:{text:'echo ok',cut:0},omitted:0,cut:false}},view=run([{kind:'job',key:'toggle',item,slots:new Map()}]);return runMarks.get(view).steps[0].child})()`,
    ...['step', 'run'].map(kind => `(()=>{const block={type:'tool',id:'read',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'output',images:[]}}};const step={kind:'block',key:'toggle',block,item:{seq:0,at:0,final:true,blocks:[block]},index:0,slots:new Map()};return ${kind === 'step' ? 'stepMarks(step).child' : 'run([step])'}})()`),
  ];
  for (const card of cards) for (const mode of ['following', 'reader', 'overscan', 'keyboard']) {
    const page = await flowPage();
    page.open(Array.from({ length: 30 }, (_, seq) => page.text(seq)));
    page.settle();
    if (mode === 'reader' || mode === 'overscan') { page.reader(mode === 'overscan' ? page.bottom() / 2 : page.bottom() - 30); page.step(0); }
    const seq = mode === 'overscan' ? page.seqs().find(seq => page.offset(seq) >= 100) : page.seqs().at(-1);
    assert.ok(seq !== undefined);
    page.evaluate(`folds.set('toggle',false);globalThis.toggleCard=${card};globalThis.toggleRow=views.get(${seq}).view;toggleRow.append(toggleCard);globalThis.toggleHeader=toggleCard.children[0];toggleHeader.getBoundingClientRect=()=>({top:toggleRow.getBoundingClientRect().top+20});dirtyExtent(toggleRow)`);
    const get = page.extra.get.bind(page.extra);
    page.extra.get = key => (get(key) ?? 0) + (key === seq && page.evaluate("toggleCard.classList.contains('open')") ? 200 : 0);
    page.layout.flush();
    page.step(0); page.settle();
    const before = page.evaluate('toggleHeader.getBoundingClientRect().top');
    page.evaluate(mode === 'keyboard' ? "toggleHeader.onkeydown({key:'Enter',preventDefault(){}})" : 'toggleHeader.onclick({})');
    page.layout.flush(); page.step(0);
    assert.equal(page.evaluate('toggleHeader.getBoundingClientRect().top'), before, card + ' ' + mode + ' expand');
    assert.equal(page.evaluate('scrolling.mode.kind'), 'reader');
    assert.equal(page.evaluate('scrollDecision.divider?.seq'), undefined);
    page.evaluate('toggleHeader.onclick({})');
    page.layout.flush(); page.step(0);
    assert.equal(page.evaluate('toggleHeader.getBoundingClientRect().top'), before, card + ' ' + mode + ' collapse');
    assert.equal(page.evaluate('scrolling.mode.kind'), mode === 'following' || mode === 'keyboard' ? 'following' : 'reader');
    assert.equal(page.evaluate('scrollDecision.divider?.seq'), undefined);
  }
});

test('a folded fence expands at its clicked bar without following or a divider', async () => {
  for (const reader of [false, true]) {
    const page = await flowPage();
    page.open(Array.from({ length: 30 }, (_, seq) => page.text(seq)));
    page.settle();
    if (reader) page.reader(page.bottom() - 30);
    const seq = page.seqs().at(-1);
    assert.ok(seq !== undefined);
    page.evaluate(`globalThis.fence=node('pre');fence.textContent=Array(20).fill('line').join('\\n');views.get(${seq}).view.append(fence);fence.after=bar=>{globalThis.fenceBar=bar;views.get(${seq}).view.append(bar)};foldFence(fence,'toggle');fenceBar.getBoundingClientRect=()=>({top:views.get(${seq}).view.getBoundingClientRect().top+20})`);
    const get = page.extra.get.bind(page.extra);
    page.extra.get = key => (get(key) ?? 0) + (key === seq && page.evaluate("openFences.has('toggle')") ? 200 : 0);
    const before = page.evaluate('fenceBar.getBoundingClientRect().top');
    page.evaluate('fenceBar.onclick()');
    page.step(0);
    assert.equal(page.evaluate('fenceBar.getBoundingClientRect().top'), before);
    assert.equal(page.evaluate("fence.classList.contains('folded')"), false);
    assert.equal(page.evaluate("element('items').contains(fenceBar)"), false);
    assert.equal(page.evaluate('scrolling.mode.kind'), 'reader');
    assert.equal(page.evaluate('scrollDecision.divider?.seq'), undefined);
  }
});

test('a visible reply that shrinks and regrows under a following pane keeps following', async () => {
  const page = await flowPage();
  page.evaluate("element('scroll').clientHeight=200");
  page.pad.value = 800;
  page.deliver(page.reveal(0, 'Intro.\n\none two three four five six'));
  page.step(1000); page.step(500);
  page.settle(60);
  page.reader(page.bottom());
  page.deliver(page.suffix(0, 1, ' seven eight'));
  page.settle(60);
  assert.equal(page.top(), page.bottom());
  page.deliver({ type: 'item', item: page.text(1) });
  page.settle(60);
  assert.equal(page.top(), page.bottom());
});

function climbs(pre: number, tops: number[]) {
  assert.deepEqual(tops.filter((value, index) => value < Math.max(pre, ...tops.slice(0, index))), []);
}

async function streamingPage() {
  const page = await flowPage();
  page.evaluate("element('scroll').clientHeight=200");
  page.pad.value = 600;
  page.evaluate("state={...state,working:true,since:1700000000000}");
  page.deliver(page.reveal(0, 'Intro.\n\none two three four five six'));
  page.step(1000); page.step(500);
  page.settle(60);
  page.reader(page.bottom());
  return page;
}

test('a reveal that replaces its streaming tail never paints the following pane above where it was', async () => {
  const page = await streamingPage(), pre = page.top();
  page.deliver(page.suffix(0, 1, '\n\nsecond block\n\nthird'));
  const { tops } = page.trace(30);
  climbs(pre, tops);
  page.settle();
  assert.equal(page.top(), page.bottom());
});

test('an older page keeps the reader where they are now, also after they moved while it loaded', async () => {
  const page = await flowPage();
  page.open([10, 11, 12, 13, 14].map(page.text), true);
  const diagnostic = () => String(page.evaluate("JSON.stringify({kind:scrolling.mode.kind,anchor:scrolling.mode.anchor,top:element('scroll').scrollTop,max:element('scroll').scrollHeight-element('scroll').clientHeight,rows:[...views.keys()]})"));
  const states = [diagnostic()];
  page.reader(200);
  states.push(diagnostic());
  const release = page.gate([5, 6, 7, 8, 9].map(page.text));
  void page.evaluate('transcriptHistory.earlier()');
  page.reader(300);
  states.push(diagnostic());
  release();
  await page.settled();
  page.step(16);
  assert.equal(page.offset(10), -300, [...states, diagnostic()].join('\n'));
  assert.equal(page.offset(13), 0);
});

test('a restored position survives the entry animation of an unfinished reply', async () => {
  const page = await flowPage();
  const image = { seq: 1, revision: 0, at: 1, kind: 'user', text: 'look', images: [{ id: 'i1', revision: 0, mimeType: 'image/png', bytes: 1, width: 10, height: 10 }], attachments: [] };
  const items = [page.reveal(0, 'Intro.\n\nwaiting tail').item, image, ...[2, 3, 4, 5, 6, 7, 8, 9].map(page.text)];
  page.go('r'); page.open(items);
  page.settle();
  page.reader(650);
  const anchor = page.offset(6);
  page.go('a'); page.open([page.text(10)]);
  page.go('r'); page.open(items);
  page.settle();
  assert.equal(page.offset(6), anchor);
});

test('replacing a running compaction with its summary keeps the reader anchor offset', async () => {
  const page = await flowPage();
  page.extra.set(1, 40);
  page.open([page.text(0), { seq: 1, revision: 1, at: 1, final: false, kind: 'command', result: { type: 'compaction', state: { type: 'running' } } }, ...Array.from({ length: 9 }, (_, index) => page.text(index + 2))]);
  page.settle();
  const anchorSeq = 5;
  page.evaluate("decide({type:'navigate',anchor:{item:{kind:'message',seq:5,row:unitRows(5)[0]},offset:-30,edge:'row'}});frame()");
  page.settle();
  const anchor = page.offset(anchorSeq);
  const get = page.extra.get.bind(page.extra);
  page.extra.get = seq => (get(seq) ?? 0) + (seq === 1 && page.evaluate("items.get(1).kind === 'summary'") ? 150 : 0);
  page.deliver({ type: 'item', item: { seq: 1, revision: 2, at: 11, final: true, kind: 'summary', source: 'compaction', text: 'Saved context' } });
  page.settle();
  assert.equal(page.offset(anchorSeq), anchor);
});

test('a reload restores reader memory when reset arrives before state and accepts later scrolling', async () => {
  const page = await flowPage();
  const items = Array.from({ length: 10 }, (_, seq) => page.text(seq));
  page.go('r'); page.open(items); page.settle();
  page.reader(250); page.settle(3);
  const anchor = page.offset(2);
  page.evaluate("scrolling=scrollInitial({view:'',sessionId:undefined},scrollMemory(scrolling));state={...state,sessionId:undefined,view:{id:'',path:[]}};");
  page.open(items);
  page.go('r'); page.settle();
  assert.equal(page.evaluate('scrolling.mode.kind'), 'reader');
  assert.equal(page.offset(2), anchor);
  page.reader(350); page.settle(3);
  assert.equal(page.evaluate('scrolling.mode.anchor.item.seq'), 3);
  page.reader(page.bottom()); page.settle();
  assert.equal(page.evaluate('scrolling.mode.kind'), 'following');
});

test('a reload restores an unloaded reader anchor after reset arrives before state', async () => {
  const page = await flowPage();
  page.go('r'); page.open(Array.from({ length: 10 }, (_, seq) => page.text(seq))); page.settle();
  page.reader(250); page.settle(3);
  const anchor = page.offset(2);
  page.evaluate("scrolling=scrollInitial({view:'',sessionId:undefined},scrollMemory(scrolling));state={...state,sessionId:undefined,view:{id:'',path:[]}};");
  const requests: string[] = [], held: ((value: unknown) => void)[] = [];
  Object.assign(page.app.context, { fetch: (path: string) => { requests.push(path); return new Promise(resolve => held.push(resolve)); } });
  page.open([page.text(20)], true);
  page.go('r'); page.settle(3);
  assert.ok(requests.length > 0);
  assert.ok(requests.every(path => path.includes('sessionId=s')), JSON.stringify(requests));
  assert.equal(page.evaluate('scrolling.mode.kind'), 'landing');
  for (const release of held) release({ ok: true, json: async () => ({ epoch: 'a', more: false, items: Array.from({ length: 18 }, (_, seq) => page.text(seq + 2)) }) });
  await page.settled(); page.settle(); await page.settled(); page.settle();
  assert.equal(page.evaluate('scrolling.mode.kind'), 'reader');
  assert.equal(page.offset(2), anchor);
});

test('a reset replaces an in-flight anchor load without accepting its late result', async () => {
  const page = await flowPage();
  page.go('r'); page.open(Array.from({ length: 20 }, (_, seq) => page.text(seq))); page.settle();
  page.reader(550); page.settle(3);
  page.go('a'); page.open([page.text(30)]);
  const held: ((value: unknown) => void)[] = [];
  Object.assign(page.app.context, { fetch: () => new Promise(resolve => held.push(resolve)) });
  page.go('r'); page.open([page.text(20)], true); page.settle(3);
  assert.equal(held.length, 1);
  page.open([page.text(20)], true); page.settle(3);
  assert.equal(held.length, 2, 'the new snapshot starts its own anchor load');
  held[0]?.({ ok: true, json: async () => ({ epoch: 'old', more: false, items: [] }) });
  await page.settled(); page.settle(3);
  assert.equal(page.evaluate('scrolling.mode.kind'), 'landing', 'the old load must not follow');
  held[1]?.({ ok: true, json: async () => ({ epoch: 'a', more: false, items: Array.from({ length: 16 }, (_, seq) => page.text(seq + 5)) }) });
  await page.settled(); page.settle(); await page.settled(); page.settle();
  assert.equal(page.evaluate('scrolling.mode.kind'), 'reader', String(page.evaluate('JSON.stringify({scrolling,pending:transcriptHistory.pending,generation:scrolling.generation,first,request:scrollDecision.request,events:scrollEvents})')));
  assert.equal(page.evaluate('transition === undefined'), true, String(page.evaluate('JSON.stringify({transition,pending:transcriptHistory.pending,scrolling,decision:scrollDecision,windowDirty,resetting,dirty:dirty.size,extentDirty:extentDirty.size,fits:fitPending.size,reveal:revealPreparation.size,growing:growing.length,holds:measuredHolds.size})')));
});

test('a reset that is shorter than the pane keeps a restoring view from following while its older pages load', async () => {
  const page = await flowPage();
  page.go('r'); page.open([0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(page.text));
  page.settle();
  page.reader(550);
  page.settle(3);
  const anchor = page.offset(5);
  page.go('a'); page.open([page.text(10)]);
  const release = page.gate([5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19].map(page.text));
  page.go('r'); page.open([page.text(20)], true);
  page.step(16);
  page.extra.set(21, 800);
  page.deliver({ type: 'item', item: page.text(21) });
  page.settle();
  assert.equal(page.top(), 0);
  release();
  await page.settled();
  page.settle();
  await page.settled();
  page.settle();
  assert.equal(page.offset(5), anchor);
});

test('a patch that changes nothing visible does not scroll a reader who is near the bottom', async () => {
  const page = await flowPage();
  page.extra.set(0, 900);
  page.deliver(page.reveal(0, 'Intro.\n\nwaiting tail'));
  page.settle();
  page.reader(page.bottom() - 30);
  const before = page.top();
  page.deliver(page.suffix(0, 1, ' x'));
  page.settle(2);
  assert.equal(page.top(), before);
});



const views = `const root={id:'r',name:'ko'},a={id:'a',name:'reviewer'},b={id:'b',name:'checker'};
  element('transcript').getBoundingClientRect=()=>({left:130,width:720});
  const calls=[];fetchJSON=async(path,body)=>{calls.push([path,body]);return {};};
  const show=(...path)=>{apply({...state,type:'state',sessionId:path.at(-1).id,view:{id:path.at(-1).id,path},life:{type:'ready'}});apply({type:'reset',epoch:'view',items:[],more:false});for(let frame=0;frame<4;frame++)tick();};
  const bar=element('bar'),texts=()=>bar.children.map(child=>child.textContent),placeholder=()=>element('prompt').children[0].placeholder;`;

test('the view bar names the path, goes to an ancestor through /view and is gone in the root view', async () => {
  const app = await page();
  const result = JSON.parse(await app.run(`(async()=>{${views}
    show(root);
    const rootView=[bar.hidden,document.body.classList.contains('viewing'),placeholder()];
    show(root,a);
    const child=[bar.hidden,document.body.classList.contains('viewing'),texts(),placeholder()];
    state.working=true;refreshComposer();const steer=placeholder();
    show(root,a,b);
    const grandchild=texts();
    bar.children[0].onclick();bar.children[1].onclick();bar.children[3].onclick();
    const sent=calls.splice(0);
    fetchJSON=async()=>{throw Object.assign(Error('stale'),{status:409})};
    bar.children[0].onclick();await Promise.resolve();await Promise.resolve();await Promise.resolve();
    const stale=element('error').textContent;
    show(root);
    return JSON.stringify({rootView,child,steer,grandchild,sent,stale,after:[bar.hidden,document.body.classList.contains('viewing')]});
  })()`));
  assert.deepEqual(result.rootView, [true, false, 'Message koa…']);
  assert.deepEqual(result.child, [false, true, ['‹', '@ko', '›', '@reviewer'], 'Message @reviewer…']);
  assert.equal(result.steer, 'Steer @reviewer…');
  assert.deepEqual(result.grandchild, ['‹', '@ko', '›', '@reviewer', '›', '@checker']);
  assert.deepEqual(result.sent, [['/view', { sessionId: 'b', id: 'a' }], ['/view', { sessionId: 'b', id: 'r' }], ['/view', { sessionId: 'b', id: 'a' }]]);
  assert.equal(result.stale, '');
  assert.deepEqual(result.after, [true, false]);
});

test('a path with middle ancestors that does not fit shrinks to a menu of the hidden ones', async () => {
  const app = await page();
  const result = JSON.parse(await app.run(`(async()=>{${views}
    const path=['r','a','b','c','d'].map((id,index)=>({id,name:index?'agent-'+id:'ko'}));
    bar.scrollWidth=400;bar.clientWidth=300;
    show(...path);
    const collapsed=texts();
    const more=bar.children.find(child=>child.className==='ellipsis');
    more.onclick();
    const menu=element('bar-menu'),rows=[menu.hidden,menu.children.map(row=>row.textContent)];
    menu.children[1].onclick();
    return JSON.stringify({collapsed,rows,menuHidden:menu.hidden,calls,capped:bar.className});
  })()`));
  assert.deepEqual(result.collapsed, ['‹', '@ko', '›', '…', '›', '@agent-c', '›', '@agent-d']);
  assert.deepEqual(result.rows, [false, ['@agent-a', '@agent-b']]);
  assert.equal(result.menuHidden, true);
  assert.deepEqual(result.calls, [['/view', { sessionId: 'd', id: 'b' }]]);
  assert.match(result.capped, /\bcap\b/);
});

test('a view change keeps each view its own draft and closes what belongs to the old one', async () => {
  const app = await page();
  const result = JSON.parse(await app.run(`(async()=>{${views}
    const file={id:'f',name:'note',path:'/tmp/note',size:1,kind:'file'};
    show(root);
    editor.setText('root draft');draft.restore([file]);decide({type:'input',direction:'up'});frame();
    element('picker').hidden=false;element('error').textContent='old error';
    show(root,a);
    const child=[editor.text(),draft.count,element('picker').hidden,element('error').textContent,scrolling.mode.kind==='following'];
    editor.setText('child draft');
    show(root,a);
    const same=editor.text();
    show(root);
    return JSON.stringify({child,same,back:[editor.text(),draft.count],again:(show(root,a),[editor.text(),draft.count])});
  })()`));
  assert.deepEqual(result.child, ['', 0, true, '', true]);
  assert.equal(result.same, 'child draft');
  assert.deepEqual(result.back, ['root draft', 1]);
  assert.deepEqual(result.again, ['child draft', 0]);
});


test('a following pane is at the bottom after every frame of a new reply, with no frame above where it was', async () => {
  const page = await streamingPage(), pre = page.top();
  page.deliver({ type: 'item', item: page.reveal(1, 'Next.\n\nwaiting tail words').item });
  const { tops, gaps } = page.trace(30);
  climbs(pre, tops);
  assert.deepEqual(gaps.filter(gap => gap !== 0), []);
});

test('a card that grows moves the following pane to the new bottom in the same frame', async () => {
  const page = await streamingPage();
  const image = { seq: 1, revision: 0, at: 1, kind: 'user', text: 'look', images: [{ id: 'i1', revision: 0, mimeType: 'image/png', bytes: 1, width: 10, height: 10 }], attachments: [] };
  page.deliver({ type: 'item', item: image });
  page.settle();
  page.pad.value += 60;
  page.evaluate("dirtyExtent(views.get(1).view)");
  page.step(16);
  assert.equal(page.bottom() - page.top(), 0);
});

test('a turn ending removes its dots in one frame but retains the ending row and follower position', async () => {
  const page = await streamingPage();
  page.step(1600);
  page.settle(30);
  page.deliver(page.suffix(0, 1, '', true));
  page.step(16);
  const settled = page.top(), slot = page.evaluate("element('tail-slot')");
  page.evaluate("apply({...state,type:'state',working:false})");
  page.step(16);
  assert.equal(page.evaluate("!!element('tail-slot').lastChild?.className.includes('working')"), false);
  assert.equal(page.evaluate("element('tail-slot')"), slot);
  assert.equal(page.evaluate("element('tail-slot').hidden"), false);
  assert.deepEqual([page.top(), page.top() - page.bottom()], [settled, 0]);
});

test('a reveal moves a following pane to the bottom in its first frame and never pulls a reader who scrolled up', async () => {
  const fixture = await revealPage();
  fixture.evaluate("Object.assign(element('scroll'),{scrollHeight:1000,clientHeight:200,scrollTop:0})");
  fixture.put('Intro.\n\nwaiting tail');
  fixture.step(16);
  assert.equal(fixture.evaluate("element('scroll').scrollTop"), 800);
  fixture.evaluate("decide({type:'input',direction:'up'});element('scroll').scrollTop=100;element('scroll').onscroll()");
  fixture.patch(1, '\n\nsecond block\n\nthird');
  fixture.step(16); fixture.step(16);
  assert.equal(fixture.evaluate("element('scroll').scrollTop"), 100);
  assert.equal(fixture.evaluate("scrolling.mode.kind"), 'reader');
});





test('scroll inputs translate keys, wheel and touch without reading scroll mode in the adapter', async () => {
  const page = await flowPage();
  page.pad.value = 900;
  for (let seq = 0; seq < 4; seq++) page.deliver({ type: 'item', item: page.text(seq) });
  page.settle();
  page.evaluate("globalThis.inputs=[];{const original=decide;decide=(event,...rest)=>{if(event?.type==='input')globalThis.inputs.push(event.direction);return original(event,...rest)}}");
  const key = (key: string, shiftKey = false) => page.app.listeners.get('keydown')?.({ key, shiftKey, target: page.doc.body, preventDefault() {} });
  key('ArrowUp');
  page.evaluate("element('scroll').scrollTop=100;element('scroll').onscroll()");
  key('ArrowDown');
  page.evaluate("element('scroll').scrollTop=200;element('scroll').onscroll();frame()");
  assert.equal(page.evaluate('scrolling.mode.anchor.item.seq'), 2);
  key('End');
  page.evaluate("element('scroll').scrollTop=element('scroll').scrollHeight-element('scroll').clientHeight;element('scroll').onscroll();frame()");
  assert.equal(page.evaluate('scrolling.mode.kind'), 'following');
  page.wheel(-30); page.wheel(30);
  page.evaluate("element('scroll').handlers.get('touchstart')({touches:[{clientY:100}]});element('scroll').handlers.get('touchmove')({touches:[{clientY:120}]});element('scroll').handlers.get('touchmove')({touches:[{clientY:90}]})");
  assert.equal(page.evaluate('globalThis.inputs.join()'), 'up,down,down,up,down,up,down');
});

test('a reader sub-pixel scroll through the page is never written back', async () => {
  const page = await flowPage();
  page.open([0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(page.text));
  page.settle();
  page.reader(300);
  const tops: number[] = [];
  let writes = 0;
  for (const top of [300.4, 300.8, 301.2, 301.6, 302]) {
    page.evaluate(`element('scroll').scrollTop=${top}`);
    page.hooks.wrote = () => { writes++; };
    page.evaluate("element('scroll').onscroll()");
    page.step(16);
    page.hooks.wrote = undefined;
    tops.push(page.top());
  }
  assert.deepEqual([writes, tops], [0, [300.4, 300.8, 301.2, 301.6, 302]]);
});

test('wheel up without scroll range keeps following and adds no unread divider', async () => {
  const page = await flowPage();
  page.evaluate("element('scroll').clientHeight=300");
  page.open([page.text(0)]);
  page.settle();
  assert.equal(page.bottom(), 0);
  page.wheel(-1);
  page.deliver({ type: 'item', item: page.text(1) });
  page.settle();
  assert.deepEqual([page.evaluate('scrolling.mode.kind'), page.dividers()], ['following', '0,1']);
});

test('a slow wheel up from the bottom leaves following and never snaps back', async () => {
  const page = await flowPage();
  page.open([0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(page.text));
  page.settle();
  const bottom = page.bottom(), tops: number[] = [];
  for (const step of [1, 2, 3, 4, 5]) {
    page.wheel(-0.5);
    page.evaluate(`element('scroll').scrollTop=${bottom - step * 0.4};element('scroll').onscroll()`);
    page.step(16);
    tops.push(page.top());
  }
  assert.deepEqual([page.evaluate('scrolling.mode.kind'), tops], ['reader', [1, 2, 3, 4, 5].map(step => bottom - step * 0.4)]);
});

test('the pane focus override includes visibility for an off-screen webview', async () => {
  const page = await flowPage();
  page.pad.value = 900;
  page.deliver({ type: 'item', item: page.text(0) });
  page.settle();
  page.evaluate("window.koaFocused=true;document.hidden=true;document.visibilityState='hidden'");
  page.deliver({ type: 'item', item: page.text(1) });
  page.settle(5);
  assert.deepEqual([page.evaluate('scrolling.mode.kind'), page.top() - page.bottom(), page.dividers()], ['following', 0, '0,1']);
});

test('Enter follows after unfocused growth changes following to reader before the user item', async () => {
  const page = await flowPage();
  page.pad.value = 900;
  page.deliver({ type: 'item', item: page.text(0) });
  page.settle();
  page.evaluate("fetchJSON=async()=>({disposition:'started'});editor.setText('go');state={...state,life:{type:'ready'}}");
  await page.evaluate('send()');
  page.focus(false);
  page.pad.value += 100;
  page.deliver({ type: 'item', item: { ...page.text(0), revision: 1 } });
  page.settle(3);
  assert.equal(page.evaluate('scrolling.mode.kind'), 'landing');
  assert.equal(page.top(), page.bottom());
  page.pad.value += 200;
  page.deliver({ type: 'item', item: page.own(1) });
  page.settle(3);
  assert.equal(page.top() - page.bottom(), 0, String(page.evaluate("JSON.stringify({kind:scrolling.mode.kind,pendingSend:scrolling.unread.pendingSend,last:scrolling.seen,events:scrollEvents,rows:[...views].map(([seq,{view}])=>({seq,rect:view.getBoundingClientRect()}))})")));
  assert.equal(page.evaluate('scrolling.mode.kind'), 'following');
});

test('Enter follows after composer shrink clamps and a delayed scroll arrives after the user item', async () => {
  const page = await flowPage();
  page.pad.value = 900;
  page.deliver({ type: 'item', item: page.text(0) });
  page.settle();
  page.evaluate("fetchJSON=async()=>({disposition:'started'});editor.setText('go');state={...state,life:{type:'ready'}}");
  await page.evaluate('send()');
  page.pad.value -= 100;
  page.evaluate("element('scroll').scrollTop=element('scroll').scrollHeight-element('scroll').clientHeight");
  page.pad.value += 200;
  page.deliver({ type: 'item', item: page.own(1) });
  page.evaluate("element('scroll').onscroll()");
  page.settle(3);
  assert.equal(page.top() - page.bottom(), 0);
});








test('a name link opens the view of its agent, and a pane link still focuses the pane', async () => {
  const app = await page();
  const link = app.run(`(()=>{${views}
    state={...state,sessionId:'r',agents:[{name:'worker',target:{type:'view',id:'v1'}},{name:'peer',target:{type:'pane',pane:'p3'}}]};
    const card=ref=>agentStep({direction:'out',to:ref,text:{text:'Hello',cut:0},call:{tool:'message',mode:'message'}},0,ref.name,new Map()).children[0].children[1].children[0].children[1];
    window.calls=calls;
    return {view:card({name:'worker',session:'v1'}),twin:card({name:'worker',session:'other'}),pane:card({name:'peer'})};
  })()`);
  const focused: string[] = [];
  app.context.window.ko = { focus: (pane: string) => { focused.push(pane); } };
  for (const target of [link.view, link.pane]) app.listeners.get('click')?.({ target, preventDefault() {} });
  assert.deepEqual(JSON.parse(app.run('JSON.stringify(window.calls)')), [['/view', { sessionId: 'r', id: 'v1' }]]);
  assert.deepEqual(focused, ['p3']);
  assert.equal(link.twin.className, 'who');
  assert.equal(link.twin.getAttribute('data-view'), 'v1');
});

test('reads of a view carry the session that they were made for', async () => {
  const app = await page();
  const urls: string[] = [];
  app.context.fetch = async (url?: string) => { urls.push(url ?? ""); return { ok: true, json: async () => ({}) }; };
  await app.run("state={...state,life:{type:'ready'},sessionId:'s9'};picker('model')");
  assert.deepEqual(urls, ['/models?sessionId=s9']);
});

test('a stop whose take-back ends after a view change aborts nothing in the new view', async () => {
  const app = await page();
  const result = JSON.parse(await app.run(`(async()=>{${views}
    show(root,a);
    let release;const held=new Promise(resolve=>{release=resolve});
    fetchJSON=async(path,body)=>{calls.push([path,body]);if(path==='/queue/clear')await held;return {steering:[],followUp:[]};};
    const stopping=stop();
    show(root);
    release();await stopping;
    return JSON.stringify(calls.map(call=>call[0]));
  })()`));
  assert.deepEqual(result, ['/queue/clear']);
});

async function jobPage() {
  const page = await latestPage(), requests: { path: string; body: string }[] = [], create = page.app.context.document.createElement;
  page.app.context.document.createElement = (tag: string) => {
    const node = create(tag), own = node.getBoundingClientRect.bind(node);
    return Object.assign(node, { getBoundingClientRect: () => {
      const rect = own(), top = Number(Reflect.get(rect, 'top'));
      return Reflect.get(Reflect.get(node, 'dataset') ?? {}, 'byte') === undefined ? rect : { ...rect, bottom: top + 100 };
    } });
  };
  page.evaluate("element('scroll').getBoundingClientRect=()=>({top:0})");
  const held: ((chunk: object) => void)[] = [], failed: (() => void)[] = [];
  Object.assign(page.app.context, { fetch: (path: string, init: { body: string }) => {
    requests.push({ path, body: init.body });
    if (path === '/job/earlier') return new Promise(resolve => { held.push(chunk => resolve({ ok: true, json: async () => chunk })); failed.push(() => resolve({ ok: false, status: 404, json: async () => ({ error: 'gone' }) })); });
    return Promise.resolve({ ok: true, json: async () => ({}) });
  } });
  const b64 = (text: string) => Buffer.from(text).toString('base64');
  const job = (id: string, state: object = { type: 'running' }) => ({ name: 'build', command: 'make', service: false, startedAt: 1700000000000, place: { type: 'mac' }, log: '/tmp/koa/' + id + '.log', state });
  const open = (id: string, state?: object, extra = '') => page.evaluate(`apply({...state,type:'state',sessionId:'s',life:{type:'ready'},view:{id:'${id}',type:'job',path:[{id:'r',name:'ko',type:'agent'},{id:'${id}',name:'build',type:'job'}],job:${JSON.stringify(job(id, state))}}});${extra}`);
  const reset = (id: string, text: string, start = 0) => page.evaluate(`apply({type:'job-reset',view:'${id}',epoch:'e${id}',start:${start},end:${start + Buffer.byteLength(text)},data:'${b64(text)}'})`);
  const append = (id: string, start: number, text: string) => page.evaluate(`apply({type:'job-append',view:'${id}',epoch:'e${id}',start:${start},data:'${b64(text)}'})`);
  const lines = () => page.evaluate("element('jobv').children[2].children.map(row => row.children.map(span => span.textContent).join(''))");
  const flush = () => new Promise<void>(resolve => setImmediate(resolve));
  return { ...page, requests, held, failed, job, open, reset, append, lines, flush, b64 };
}

test('a job snapshot commits its prepared presentation', async () => {
  const f = await jobPage();
  f.evaluate("apply({...state,type:'state',sessionId:'s',life:{type:'ready'},view:{id:'root',path:[],type:'root'}})");
  f.open('j1'); f.reset('j1', 'ready\n');
  for (let frame = 0; frame < 12; frame++) f.step(16);
  assert.equal(f.evaluate('transition === undefined'), true, 'the job presentation commits');
});

test('a presentation copy preserves and pauses the source animation time', async () => {
  const app = await page();
  const result = app.run(`(()=>{const row=node('div',undefined,'grow');document.body.append(row);row.animations=[{currentTime:127,playState:'running',pause(){this.playState='paused'}}];beginTransition();const copy=document.body.children.find(child=>child.id==='presentation').shadowRoot.querySelector('.grow');return [copy.getAnimations()[0].currentTime,copy.getAnimations()[0].playState]})()`);
  assert.deepEqual(Array.from(result), [127, 'paused']);
});

test('covered file input starts no upload and changes no draft', async () => {
  const app = await page(), evaluate = app.repl(), uploads: string[] = [];
  evaluate("state={...state,life:{type:'ready'},sessionId:'s',view:{id:'root',path:[],type:'root'}};editor.setText('committed');beginTransition({...state,sessionId:'next'})");
  app.context.fetch = async (path?: string) => { uploads.push(path ?? ''); return { ok: true, json: async () => ({}) }; };
  for (const type of ['drop', 'paste']) {
    let stopped = false;
    const transfer = { files: [new File(['x'], 'a.txt')], items: [] };
    const event = { dataTransfer: transfer, clipboardData: transfer, composedPath: () => [], preventDefault() {}, stopImmediatePropagation() { stopped = true; } };
    app.captures.get(type)?.(event);
    if (!stopped) app.listeners.get(type)?.(event);
    assert.equal(stopped, true, type + ' is blocked');
  }
  assert.deepEqual(uploads, []);
  assert.equal(evaluate("JSON.stringify([editor.text(),draft.count])"), JSON.stringify(['committed', 0]));
});

test('a job view renders the log, follows live output, and shows Latest with no count and no divider while the reader is above', async () => {
  const f = await jobPage();
  f.open('j1');
  const first = 'one\n\x1b[31mtwo\x1b[0m\n', size = Buffer.byteLength(first);
  f.reset('j1', first);
  assert.deepEqual(f.lines(), ['one', 'two']);
  assert.equal(f.evaluate("document.body.classList.contains('jobmode')"), true);
  assert.equal(f.evaluate('[epoch, after].join()'), 'ej1,' + size);
  f.scroll(0);
  f.append('j1', size, 'three\n');
  assert.deepEqual(f.lines(), ['one', 'two', 'three']);
  assert.equal(f.evaluate('after'), size + 6);
  assert.equal(f.latest(), '↓ Latest,true');
  assert.equal(f.dividers(), '');
  f.append('j1', size + 20, 'gap\n');
  assert.deepEqual(f.lines(), ['one', 'two', 'three'], 'a gap in the byte range is not painted');
});

test('the job foot acts on the job: Stop while it runs, Clear after it ends', async () => {
  const f = await jobPage();
  f.open('j1');
  assert.equal(f.evaluate("element('job-act').textContent"), 'Stop');
  f.evaluate("element('job-act').onclick()");
  f.open('j1', { type: 'ended', end: { type: 'exit', code: 1 }, at: 1700000130000 });
  assert.equal(f.evaluate("element('job-act').textContent"), 'Clear');
  assert.equal(f.evaluate("element('job-word').textContent"), 'exit 1');
  assert.equal(f.evaluate("element('jobv').children[3].hidden"), false);
  assert.equal(f.evaluate("[element('jobv').children[3].children[0].textContent, element('jobv').children[3].children[0].className, String(element('jobv').children[3].children[1]).startsWith(' · ')].join()"), 'exit 1,err,true');
  f.evaluate("element('job-act').onclick()");
  await f.flush();
  assert.deepEqual(f.requests.map(request => [request.path, JSON.parse(request.body)]), [['/job/stop', { sessionId: 's', id: 'j1' }], ['/job/clear', { sessionId: 's', id: 'j1' }]]);
});

test('a job view gives no key to the composer and Escape sends no abort', async () => {
  const f = await jobPage();
  f.open('j1');
  assert.equal(f.evaluate("element('field').inert"), true);
  f.app.listeners.get('keydown')?.({ key: 'a', target: f.doc.body, preventDefault() {} });
  f.app.listeners.get('keydown')?.({ key: 'Escape', target: f.doc.body, preventDefault() {} });
  await f.flush();
  assert.equal(f.app.text(), '');
  assert.deepEqual(f.requests, []);
});

test('earlier output prepends once, drops the old partial line, and a response for a view that was left is ignored', async () => {
  const f = await jobPage();
  f.open('j1');
  f.reset('j1', 'cut\nlive\n', 100);
  assert.deepEqual(f.lines(), ['live']);
  assert.equal(f.evaluate("element('jobv').children[0].hidden"), false);
  f.evaluate("element('jobv').children[0].onclick()");
  f.evaluate("element('jobv').children[0].onclick()");
  assert.equal(f.requests.length, 1, 'one request at a time');
  assert.deepEqual(JSON.parse(f.requests[0]?.body ?? '{}'), { sessionId: 's', id: 'j1', epoch: 'ej1', before: 100 });
  f.held[0]?.({ start: 89, end: 100, data: f.b64('tail\nolder\n') });
  await f.flush();
  assert.deepEqual(f.lines(), ['older', 'cut', 'live']);
  assert.equal(f.evaluate("element('jobv').children[0].hidden"), false);
  f.evaluate("element('jobv').children[0].onclick()");
  f.open('j2');
  f.reset('j2', 'other\n');
  f.held[1]?.({ start: 0, end: 89, data: f.b64('x'.repeat(89)) });
  await f.flush();
  assert.deepEqual(f.lines(), ['other']);
});

test('a job reader keeps their line when earlier output prepends, and a followed job goes to the bottom of live output', async () => {
  const f = await jobPage();
  f.open('j1');
  f.reset('j1', 'cut\nlive\nmore\n', 100);
  f.evaluate("Object.assign(element('scroll'),{scrollHeight:1000,clientHeight:100,scrollTop:900});element('scroll').onscroll()");
  f.evaluate("element('scroll').scrollHeight=1100");
  f.append('j1', 114, 'next\n');
  f.step(16);
  assert.deepEqual([f.evaluate("element('scroll').scrollTop"), f.evaluate('scrolling.mode.kind')], [1000, 'following']);
  f.evaluate("decide({type:'input',direction:'up'});element('scroll').scrollTop=100;element('scroll').onscroll();frame()");
  assert.equal(f.evaluate("scrolling.mode.anchor.item.byte"), 109);
  f.evaluate("element('jobv').children[0].onclick()");
  f.held[0]?.({ start: 89, end: 100, data: f.b64('tail\nolder\n') });
  await f.flush();
  assert.deepEqual(f.lines(), ['older', 'cut', 'live', 'more', 'next']);
  f.step(16);
  assert.equal(f.evaluate("element('scroll').scrollTop"), 300);
});

test('a job restore whose older request fails ends in the fallback after one request', async () => {
  const f = await jobPage();
  let earlier = 0;
  Object.assign(f.app.context, { fetch: async (path: string) => { if (path === '/job/earlier') { earlier++; return { ok: false, status: 500, json: async () => ({ error: 'broken' }) }; } return { ok: true, json: async () => ({}) }; } });
  f.evaluate("scrolling.saved.set('j1',{scope:{view:'j1',sessionId:'s'},anchor:{item:{kind:'job',byte:50},offset:0,edge:'row'},last:0})");
  f.open('j1');
  assert.equal(f.evaluate('scrolling.mode.kind'), 'landing');
  f.reset('j1', 'cut\nlive\n', 100);
  f.step(16);
  await f.flush(); await f.flush();
  f.step(16);
  assert.deepEqual([earlier, f.evaluate('scrolling.mode.kind')], [1, 'following']);
});

test('a following job that grows while the pane is in the background is a reader on return and does not jump', async () => {
  const f = await jobPage();
  f.open('j1');
  f.reset('j1', 'one\ntwo\n');
  f.evaluate("Object.assign(element('scroll'),{scrollHeight:1000,clientHeight:100,scrollTop:900});element('scroll').onscroll()");
  f.focus(false);
  f.evaluate("element('scroll').scrollHeight=1100");
  f.append('j1', 8, 'three\n');
  f.step(16);
  f.focus(true);
  f.step(16);
  assert.deepEqual([f.evaluate("element('scroll').scrollTop"), f.evaluate('scrolling.mode.kind'), f.latest().split(',')[1]], [900, 'reader', 'true']);
});

test('a following reply that grows while the pane is in the background is a reader on return and does not jump', async () => {
  const page = await flowPage();
  page.pad.value = 900;
  page.deliver(page.reveal(0, 'Intro.\n\nwaiting tail'));
  page.settle();
  const before = page.top();
  page.focus(false);
  page.pad.value += 200;
  page.deliver(page.suffix(0, 1, '\n\nsecond block\n\nthird'));
  page.step(16);
  page.focus(true);
  page.settle(3);
  assert.deepEqual([page.top(), page.evaluate('scrolling.mode.kind'), page.latest().split(',')[1]], [before, 'reader', 'true']);
});

test('a view left after a clamp keeps the reader anchor from before the clamp', async () => {
  const page = await flowPage();
  const items = [0, 1, 2, 3, 4, 5].map(page.text);
  page.go('r'); page.open(items);
  page.settle(3);
  page.reader(250);
  page.settle(3);
  const anchor = page.offset(2);
  page.extra.set(5, -300);
  page.step(16);
  page.go('a'); page.open([page.text(10)]);
  page.extra.set(5, 0);
  page.go('r'); page.open(items);
  page.settle(3);
  assert.deepEqual([page.offset(2), page.evaluate('scrolling.mode.kind')], [anchor, 'reader']);
});

test('a job link on a card opens the job view by its id', async () => {
  const f = await jobPage();
  f.evaluate("jobOpen({id:'j9',name:'x',service:false,log:'/tmp/x.log'}).onclick({preventDefault(){},stopPropagation(){}})");
  await f.flush();
  assert.deepEqual(f.requests.map(request => request.path), ['/view']);
  assert.equal(JSON.parse(f.requests[0]?.body ?? '{}').id, 'j9');
});

test('a failed earlier-output request for a job that was left does not mark the new job as gone', async () => {
  const f = await jobPage();
  f.open('j1');
  f.reset('j1', 'cut\nlive\n', 100);
  f.evaluate("element('jobv').children[0].onclick()");
  f.open('j2');
  f.reset('j2', 'other\n');
  f.failed[0]?.();
  await f.flush();
  assert.deepEqual(f.lines(), ['other']);
});

const FIND_DOTS = "(function find(n){return n.className==='dots'?n:n.children.map(c=>c.children?find(c):undefined).find(Boolean)})({children:[element('items'),element('tail-slot')]})";
const dotsCount = "(function f(n){return (n.className==='dots'?1:0)+n.children.reduce((t,c)=>t+(c.children?f(c):0),0)})({children:[element('items'),element('tail-slot')]})";
test('working dots: the dots in the page keep their node through patches, reveal, replacements, rebuilds and hide', async () => {
  const fixture = await revealPage(200), ev = fixture.evaluate;
  ev("state={...state,working:true,since:1699999990000}");
  fixture.put('Intro.\n\none two three four five six');
  const first = ev(FIND_DOTS);
  assert.equal(Number(ev(dotsCount)), 1);
  ev("Date = class extends Date { static now() { return 1700000030000; } }");
  const stay = (label: string) => assert.deepEqual([ev(FIND_DOTS) === first, Number(ev(dotsCount))], [true, 1], label);
  for (let revision = 1; revision <= 12; revision++) { fixture.patch(revision, ' word' + revision + '\n\nblock ' + revision); fixture.step(16); stay('patch ' + revision); }
  fixture.step(1000); fixture.step(500); stay('reveal');
  ev("apply({type:'patch',seq:0,baseRevision:12,revision:13,final:false,stop:'',error:'',blocks:[{index:0,block:{type:'text',text:'replaced'}}]})");
  fixture.step(16); stay('replacement');
  ev("put({seq:1,revision:0,at:0,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'tool',id:'a',name:'bash',args:{text:'{}'},state:{type:'running'}}]})");
  stay('tool starts');
  ev("put({seq:1,revision:0,at:0,kind:'assistant',final:false,stop:'',error:'',blocks:[{type:'tool',id:'a',name:'bash',args:{text:'{}'},state:{type:'running'}},{type:'thinking',text:'x',started:1,ended:2}]})");
  stay('run rebuild');
  ev("document.hidden = true");
  fixture.app.listeners.get('visibilitychange')?.({});
  ev("document.hidden = false");
  fixture.app.listeners.get('visibilitychange')?.({});
  stay('show');
  ev("state={...state,view:{id:'other',path:[],type:'agent'}}; reconcileWorking()");
  ev("state={...state,view:{id:'',path:[],type:'agent'}}; reconcileWorking()");
  const back = ev(FIND_DOTS);
  assert.deepEqual([back === first, Number(ev(dotsCount))], [false, 1], 'view return creates a new mark');
});

test('working dots: one indicator in every frame, a bare row or a running mark, never both and never neither', async () => {
  const fixture = await revealPage(200), ev = fixture.evaluate;
  const marks = () => Number(ev(dotsCount));
  const bare = () => Boolean(ev("!!element('tail-slot').lastChild?.className.includes('working')"));
  const tool = (id: string, state: string) => ({ type: 'tool', id, name: 'bash', args: { text: '{}' }, state: { type: state, ...(state === 'done' ? { error: false, result: { text: 'ok', images: [] } } : {}) } });
  const show = (blocks: object[], final = false, stop = '') => ev('put(' + JSON.stringify({ seq: 1, revision: 0, at: 0, kind: 'assistant', final, stop, error: '', blocks }) + ')');
  const where = () => String(ev("(function(){const d=" + FIND_DOTS + ";return d.parent.className+'|'+d.parent.parent.parent.className})()"));
  const toggle = () => ev("views.get(1).slots.get('1:1').view.firstElementChild.children[0].onclick({})");
  const summary = () => String(ev("views.get(1).slots.get('1:1').view.firstElementChild.children[0].children[0].children[0].children.map(c => c.textContent).join('')"));
  ev("state={...state,working:true,since:1699999990000}");
  show([{ type: 'text', text: 'hello' }]);
  assert.deepEqual([bare(), marks()], [true, 1]);
  show([{ type: 'text', text: 'hello' }, tool('a', 'running')]);
  assert.deepEqual([bare(), marks(), where().startsWith('sum|run')], [false, 1, true]);
  show([{ type: 'text', text: 'hello' }, tool('a', 'running')], false, 'toolUse');
  assert.deepEqual([bare(), marks(), where().startsWith('sum|run')], [false, 1, true], 'the stop reason toolUse does not end the call');
  show([{ type: 'text', text: 'hello' }, tool('a', 'done')]);
  assert.deepEqual([bare(), marks(), where().startsWith('sum|run')], [false, 1, true], 'a finished run last carries the dots after its summary');
  show([{ type: 'text', text: 'hello' }, tool('a', 'done'), tool('b', 'running')]);
  assert.deepEqual([bare(), marks(), summary()], [false, 1, 'bash x2'], 'the folded summary keeps the counts');
  show([{ type: 'text', text: 'hello' }, tool('a', 'done'), tool('b', 'done'), tool('c', 'running')]);
  assert.deepEqual([bare(), marks()], [false, 1], 'one call finishes and the next starts in one patch');
  show([{ type: 'text', text: 'hello' }, tool('a', 'running'), tool('b', 'running')]);
  assert.deepEqual([bare(), marks()], [false, 1], 'folded: only the summary has dots');
  toggle();
  assert.deepEqual([bare(), marks(), where().startsWith('sum|step')], [false, 2, true], 'open: only the running steps');
  toggle();
  assert.deepEqual([bare(), marks()], [false, 1]);
  show([{ type: 'text', text: 'hello' }, tool('a', 'running')], false, 'aborted');
  assert.deepEqual([bare(), marks(), where().startsWith('sum|run')], [false, 1, true], 'an aborted call is no running call: the dots stay on the run');
  ev("apply({...state,type:'state',working:false})");
  assert.deepEqual([bare(), marks()], [false, 0], 'the end takes every mark in one update');
});

test('working dots: the mark sits in the last visible element, a run row or a bare row, and moves in the frame the last element changes', async () => {
  const fixture = await revealPage(200), ev = fixture.evaluate;
  const marks = () => Number(ev(dotsCount));
  const rows = () => Number(ev("element('items').children.length"));
  const bare = () => Boolean(ev("element('tail-slot').children.some(c=>c.className.includes('working'))"));
  const node = () => ev(FIND_DOTS);
  const tool = (id: string, state: string) => ({ type: 'tool', id, name: 'bash', args: { text: '{}' }, state: { type: state, ...(state === 'done' ? { error: false, result: { text: 'ok', images: [] } } : {}) } });
  const show = (seq: number, blocks: object[], final = false, stop = '') => ev('put(' + JSON.stringify({ seq, revision: 0, at: 0, kind: 'assistant', final, stop, error: '', blocks }) + ')');
  const where = () => String(ev("(function(){const d=" + FIND_DOTS + ";return d.parent.className+'|'+d.parent.parent.className+'|'+d.parent.parent.parent.className})()"));
  const toggle = () => ev("runMarks.get(views.get(1).slots.get('1:0').view.firstElementChild).summary.parent.onclick({})");
  const headerDots = () => Number(ev("runMarks.get(views.get(1).slots.get('1:0').view.firstElementChild).summary.children.filter(c=>c===working.primary||[...working.extra.values()].includes(c)).length"));
  ev("state={...state,working:true,since:1699999990000}");
  show(1, [{ type: 'thinking', text: 'x', started: 1, ended: 2 }, tool('a', 'done')]);
  const first = node();
  assert.deepEqual([bare(), marks(), where().startsWith('sum|line|run')], [false, 1, true], 'finished run last, folded');
  toggle();
  assert.deepEqual([bare(), marks(), where().startsWith('sum|line|run'), node() === first], [false, 1, true, true], 'finished run last, open');
  show(1, [{ type: 'thinking', text: 'x', started: 1, ended: 2 }, tool('a', 'done'), tool('b', 'running')]);
  assert.deepEqual([bare(), marks(), where().startsWith('sum|line|step'), headerDots(), node() === first], [false, 1, true, 0, true], 'running step, open: on the step line, header none');
  toggle();
  assert.deepEqual([bare(), marks(), where().startsWith('sum|line|run'), node() === first], [false, 1, true, true], 'running step, folded: after the summary');
  toggle();
  const before = rows();
  show(1, [{ type: 'thinking', text: 'x', started: 1, ended: 2 }, tool('a', 'done'), tool('b', 'done')]);
  assert.deepEqual([bare(), marks(), where().startsWith('sum|line|run')], [false, 1, true], 'call ends: back on the header');
  show(1, [{ type: 'thinking', text: 'x', started: 1, ended: 2 }, tool('a', 'done'), tool('b', 'done'), tool('c', 'running')]);
  assert.deepEqual([bare(), marks(), where().startsWith('sum|line|step'), rows() === before, node() === first], [false, 1, true, true, true], 'a new call joins: the same mark moves to the step');
  show(1, [{ type: 'thinking', text: 'x', started: 1, ended: 2 }, tool('a', 'done'), tool('b', 'done'), tool('c', 'done')]);
  show(2, [{ type: 'text', text: 'reply' }]);
  assert.deepEqual([bare(), marks(), node() === first, ev("element('tail-slot').lastChild?.className.includes('working')")], [true, 1, true, true], 'text starts after the run: the same mark is the bare row under it');
  show(2, [{ type: 'text', text: 'reply' }], true);
  show(3, [tool('d', 'done')]);
  assert.deepEqual([bare(), marks(), node() === first, where().startsWith('sum|line|run')], [false, 1, true, true], 'a run after final text takes the mark');
  show(3, [tool('d', 'running')]);
  assert.deepEqual([bare(), marks(), node() === first], [false, 1, true]);
  ev("apply({...state,type:'state',working:false})");
  assert.deepEqual([bare(), marks()], [false, 0], 'the end removes the mark');
  ev("state={...state,working:true,since:1699999990000}; reconcileWorking()");
  show(3, [tool('d', 'running')], false, 'aborted');
  ev("apply({...state,type:'state',working:false})");
  assert.deepEqual([bare(), marks()], [false, 0], 'abort: no dots');
});

test('working dots: active thinking is a live step, the mark follows it and the next call', async () => {
  const fixture = await revealPage(200), ev = fixture.evaluate;
  const done = { type: 'tool', id: 'a', name: 'bash', args: { text: '{}' }, state: { type: 'done', error: false, result: { text: 'ok', images: [] } } };
  const next = { type: 'tool', id: 'b', name: 'bash', args: { text: '{}' }, state: { type: 'running' } };
  const show = (blocks: object[]) => ev('put(' + JSON.stringify({ seq: 1, revision: 0, at: 0, kind: 'assistant', final: false, stop: '', error: '', blocks }) + ')');
  const where = () => String(ev("(function(){const d=" + FIND_DOTS + ";return d.parent.className+'|'+d.parent.parent.className+'|'+d.parent.parent.parent.className})()"));
  const count = () => Number(ev(dotsCount));
  ev("state={...state,working:true,since:1699999990000}");
  ev("folds.set('run:1:0', true)");
  show([done]);
  const first = ev(FIND_DOTS);
  show([done, { type: 'thinking', text: 'hm', started: 1 }]);
  assert.deepEqual([count(), where(), ev(FIND_DOTS) === first], [1, 'sum|line|step', true], 'active thinking: on its step line');
  show([done, { type: 'thinking', text: 'hm', started: 1, ended: 2 }]);
  assert.deepEqual([count(), where(), ev(FIND_DOTS) === first], [1, 'sum|line|run open', true], 'thinking ended: back on the header');
  show([done, { type: 'thinking', text: 'hm', started: 1 }]);
  show([done, { type: 'thinking', text: 'hm', started: 1, ended: 2 }, next]);
  assert.deepEqual([count(), where(), ev(FIND_DOTS) === first], [1, 'sum|line|step', true], 'the next call: on its step line');
});

async function dotsWatch() {
  const page = await latestPage(), watch = frameWatch(page);

  const attached = () => page.evaluate("(()=>{for(let node=working?.primary;node;node=node.parent)if(node===element('items')||node===element('tail-slot'))return true;return false})()") === true;
  page.evaluate("state={...state,life:{type:'ready'},working:true,since:1700000000000}");
  return { page, removals: () => watch.counts.removals, attached, reset: () => { watch.counts.removals = 0; } };
}
const bash = (id: string, command: string, state: object) => ({ type: 'tool', id, name: 'bash', args: { text: JSON.stringify({ command }) }, state });
const running = { type: 'running', output: { text: '', cut: 0 } };
const finished = { type: 'done', error: false, result: { text: '', images: [] } };

test('the working dots are never detached while a turn runs, and move once when a call starts or ends', async () => {
  const { page, removals, attached, reset } = await dotsWatch();
  const patch = (seq: number, revision: number, blocks: object[]) => page.evaluate(`apply({type:'patch',seq:${seq},baseRevision:${revision - 1},revision:${revision},final:false,stop:'',error:'',blocks:${JSON.stringify(blocks)}})`);
  const item = (seq: number, blocks: object[]) => ({ seq, revision: 0, at: 0, kind: 'assistant', final: false, stop: '', error: '', blocks });
  page.add(item(0, [{ type: 'text', text: 'Reading.' }]));
  page.step(16);
  assert.equal(attached(), true);
  reset();
  for (let revision = 1; revision <= 50; revision++) { patch(0, revision, [{ index: 0, suffix: ' word' }]); page.step(16); }
  assert.equal(removals(), 0);
  page.evaluate("folds.set('1:0',true)");
  page.add(item(1, [{ type: 'thinking', text: 'deep thought', started: 1, ended: 2 }, bash('call', 'make', running)]));
  page.step(16);
  assert.ok(removals() <= 1, `start: ${removals()}`);
  assert.equal(page.evaluate("[...liveMarks.values()].every(marks=>marks.summary.children.includes(working.primary))"), true);
  patch(1, 1, [{ index: 1, block: bash('call', 'make', running) }]);
  const thinking = page.evaluate("(()=>{const find=n=>n.children.filter(c=>typeof c==='object').flatMap(c=>c.className.includes('think')?[c]:find(c));return find(element('items'))[0]})()");
  assert.ok(thinking);
  reset();
  for (let revision = 2; revision <= 51; revision++) {
    patch(1, revision, [{ index: 1, block: bash('call', 'make ' + revision, running) }]);
    page.step(16);
    patch(0, 50 + revision, [{ index: 0, suffix: ' more' }]);
    page.step(16);
  }
  assert.equal(removals(), 0);
  assert.equal(String(page.evaluate("JSON.stringify(element('items').children.map(function text(n){return typeof n==='object'?[n.textContent,...n.children.map(text)]:n}))")).includes('make 51'), true);
  assert.equal(page.evaluate("[...liveMarks.values()].every(marks=>marks.summary.children.includes(working.primary))"), true);
  assert.equal(page.evaluate("(()=>{const find=n=>n.children.filter(c=>typeof c==='object').flatMap(c=>c.className.includes('think')?[c]:find(c));return find(element('items')).length})()"), 1);
  patch(1, 52, [{ index: 1, block: bash('call', 'make 51', finished) }]);
  page.step(16);
  assert.ok(removals() <= 1, `end: ${removals()}`);
  assert.equal(page.evaluate("liveMarks.size"), 0);
  assert.equal(page.evaluate("!!element('tail-slot').lastChild?.className.includes('working')"), false);
  assert.equal(page.evaluate("(()=>{const run=views.get(1).slots.get('1:0').view.firstElementChild;return runMarks.get(run).summary.children.includes(working.primary)})()"), true);
});

test('ending run merging and its last visible step disappearing preserve the ending line', async () => {
  const page = await flowPage();
  page.evaluate("state={...state,working:true,since:100}");
  const reply = (seq: number, blocks: object[], revision = 0) => page.evaluate(`put({seq:${seq},revision:${revision},at:1,kind:'assistant',final:false,stop:'',error:'',blocks:${JSON.stringify(blocks)}})`);
  page.open([]);
  const height = () => page.evaluate("element('scroll').scrollHeight");
  const before = height();
  reply(0, [bash('a', 'one', running)]);
  assert.equal(height(), before);
  const run = page.evaluate('lastRun()');
  reply(1, [bash('b', 'two', running)]);
  assert.equal(page.evaluate('lastRun()'), run, 'adjacent tools retain the earlier run owner');
  assert.equal(height(), before, 'merging another tool adds no row');
  reply(1, [], 1);
  assert.equal(height(), before);
  reply(0, [], 1);
  assert.equal(page.evaluate("element('tail-slot').hidden"), false, 'the last step disappearing restores the empty ending line');
  assert.equal(height(), before);
  assert.equal(page.evaluate("element('tail-slot').contains(working.primary)"), true);
  reply(2, [bash('c', 'three', running)]);
  assert.equal(height(), before);
  page.evaluate("put({seq:3,revision:0,at:3,kind:'user',final:true,text:'Continue',images:[],attachments:[]})");
  assert.equal(page.evaluate("element('tail-slot').hidden"), false, 'a following user message restores the ending line');
  assert.ok(Number(height()) > Number(before), 'the earlier run stays above the new ending line');
});

test('ending folded parallel calls keep one summary indicator', async () => {
  const page = await flowPage();
  page.evaluate("state={...state,working:true,since:100}");
  page.open([{seq:0,at:0,kind:'user',revision:0,final:true,text:'Go',images:[],attachments:[]}]);
  const height = () => page.evaluate("element('scroll').scrollHeight");
  const before = height();
  const put = (blocks: object[], revision: number, stop = '') => page.evaluate(`put({seq:1,revision:${revision},at:1,kind:'assistant',final:${!!stop},stop:${JSON.stringify(stop)},error:'',blocks:${JSON.stringify(blocks)}})`);
  put([bash('a', 'one', running), bash('b', 'two', running)], 0);
  assert.equal(page.evaluate(dotsCount), 1, 'a folded parallel run has only its summary dots');
  assert.equal(height(), before, 'parallel tools replace the bare ending line');
  put([bash('a', 'one', finished), bash('b', 'two', running), bash('c', 'three', running)], 1);
  assert.equal(height(), before, 'more tools change only the summary');
  assert.equal(page.evaluate(dotsCount), 1);
  put([bash('a', 'one', finished), bash('b', 'two', finished), bash('c', 'three', finished)], 2, 'aborted');
  page.evaluate("state={...state,working:false};reconcileWorking()");
  assert.equal(height(), before, 'abort keeps the run in the ending line');
  assert.equal(page.evaluate("element('tail-slot').hidden"), true);
  put([bash('a', 'one', finished), {type:'text',text:'Reply'}], 3, 'stop');
  assert.equal(page.evaluate("element('tail-slot').hidden"), false, 'prose restores the empty ending line');
  assert.ok(Number(height()) >= Number(before), 'prose adds space');
});

test('with parallel calls the ended call loses its dots and the other keeps its own', async () => {
  const { page, removals, reset } = await dotsWatch();
  page.add({ seq: 1, revision: 0, at: 0, kind: 'assistant', final: false, stop: '', error: '', blocks: [bash('a', 'one', running), bash('b', 'two', running)] });
  page.evaluate("folds.set([...liveMarks.keys()][0],true);reconcileWorking()");
  page.step(16);
  const marks = () => String(page.evaluate("JSON.stringify([...liveMarks.values()].flatMap(m=>m.steps.map(s=>[s.live,s.sum.children.some(c=>c===working.primary||[...working.extra.values()].includes(c))])))"));
  assert.equal(marks(), '[[true,true],[true,true]]');
  const patch = (revision: number, index: number, block: object) => page.evaluate(`apply({type:'patch',seq:1,baseRevision:${revision - 1},revision:${revision},final:false,stop:'',error:'',blocks:[{index:${index},block:${JSON.stringify(block)}}]})`);
  patch(1, 0, bash('a', 'one', finished));
  page.step(16);
  assert.equal(marks(), '[[false,false],[true,true]]');
  reset();
  for (let revision = 2; revision <= 30; revision++) { patch(revision, 1, bash('b', 'two ' + revision, running)); page.step(16); }
  assert.equal(removals(), 0);
  assert.equal(marks(), '[[false,false],[true,true]]');
});

function frameWatch(page: Awaited<ReturnType<typeof latestPage>>) {
  const proto = page.app.context.Node.prototype, counts = { reads: 0, removals: 0 };
  let dirty = false, depth = 0, inFrame = false;
  const dots = () => page.evaluate('working?.primary');
  const parentOf = (node: unknown): unknown => typeof node === 'object' && node ? Reflect.get(node, 'parent') : undefined;
  const holds = (node: unknown) => { for (let at = dots(); at; at = parentOf(at)) if (at === node) return true; return false; };
  const write = (name: string, removed: (self: unknown, args: unknown[]) => unknown[]) => {
    const original = Reflect.get(proto, name);
    Reflect.set(proto, name, function (this: unknown, ...args: unknown[]) {
      dirty ||= inFrame;
      if (depth++) { try { return original.apply(this, args); } finally { depth--; } }
      for (const node of removed(this, args)) if (holds(node)) counts.removals++;
      try { return original.apply(this, args); } finally { depth--; }
    });
  };
  const kids = (self: unknown): unknown[] => { const list = typeof self === 'object' && self ? Reflect.get(self, 'children') : []; return Array.isArray(list) ? [...list] : []; };
  const moved = (_: unknown, args: unknown[]) => args.filter(arg => !!parentOf(arg));
  const movedFirst = (_: unknown, args: unknown[]) => moved(_, args.slice(0, 1));
  write('remove', self => [self]);
  write('removeChild', (_, args) => [args[0]]);
  write('replaceChildren', self => kids(self));
  for (const name of ['append', 'prepend', 'before']) write(name, moved);
  write('insertBefore', movedFirst);
  const text = Reflect.getOwnPropertyDescriptor(proto, 'textContent');
  Reflect.defineProperty(proto, 'textContent', { ...text, set(this: unknown, value: unknown) { dirty ||= inFrame; text?.set?.call(this, value); } });
  page.hooks.read = () => {
    if (dirty) counts.reads++;
    dirty = false;
  };
  page.hooks.layout = () => { dirty = false; };
  // WebKit's Element::setScrollTop updates the layout before it scrolls, so a read after the write forces no layout.
  page.hooks.wrote = () => { dirty = false; };
  return { counts, frame: (ms = 16) => { counts.reads = 0; dirty = false; inFrame = true; try { page.step(ms); } finally { inFrame = false; } } };
}

const assistant = (seq: number, text: string, final = false) => ({ seq, revision: 0, at: 0, kind: 'assistant', final, stop: '', error: '', blocks: [{ type: 'text', text }] });
const patchOf = (seq: number, revision: number, suffix: string) => ({ type: 'patch', seq, baseRevision: revision - 1, revision, final: false, stop: '', error: '', blocks: [{ index: 0, suffix }] });

test('a record reaches the model at once and the DOM only in the next frame', async () => {
  const page = await latestPage();
  page.deliver({ type: 'item', item: assistant(0, 'first words') });
  assert.deepEqual([page.evaluate('items.has(0)'), page.evaluate('views.has(0)'), page.evaluate("element('items').children.length")], [true, false, 0]);
  page.deliver(patchOf(0, 1, ' and more'));
  assert.deepEqual([page.evaluate('items.get(0).blocks[0].text'), page.evaluate('views.has(0)')], ['first words and more', false]);
  page.step(16);
  assert.deepEqual([page.evaluate('views.has(0)'), page.evaluate("element('items').children.length")], [true, 1]);
});

test('patches between two frames render once', async () => {
  const page = await latestPage();
  page.deliver({ type: 'item', item: assistant(0, 'Intro.\n\nbody') });
  page.step(16);
  page.evaluate("globalThis.renders = 0; { const original = renderItem; renderItem = item => { globalThis.renders++; return original(item); }; }");
  for (let revision = 1; revision <= 5; revision++) page.deliver(patchOf(0, revision, ' w' + revision));
  assert.equal(page.evaluate('globalThis.renders'), 0);
  page.step(16);
  assert.equal(page.evaluate('globalThis.renders'), 1);
  assert.equal(page.evaluate('items.get(0).blocks[0].text'), 'Intro.\n\nbody w1 w2 w3 w4 w5');
});

test('a streaming frame measures its dirty row and corrects once only when its height changes', async () => {
  const page = await latestPage();
  Object.assign(page.app.context, { matchMedia: () => ({ matches: true }) });
  page.add(assistant(0, 'Earlier.', true)); page.add(assistant(1, 'Earlier too.', true)); page.add(assistant(2, 'a'));
  page.step(16);
  page.evaluate(`
    Object.assign(globalThis,{afterWrite:false,postMeasures:0,height:20,reads:[]});
    for(const [seq,{view}] of views)Object.defineProperty(view,'offsetHeight',{get(){if(afterWrite)reads.push(seq);return seq===2?height:20}});
    const originalRender=renderItem,originalMeasure=measure,originalTick=tick;
    renderItem=item=>{const result=originalRender(item);if(result)afterWrite=true;return result};
    measure=()=>{if(afterWrite)postMeasures++;return originalMeasure()};
    tick=()=>{afterWrite=false;try{return originalTick()}finally{afterWrite=false}};
  `);
  page.deliver(patchOf(2, 1, ' b')); page.step(16);
  assert.deepEqual(JSON.parse(String(page.evaluate('JSON.stringify({reads,postMeasures})'))), { reads: [2], postMeasures: 0 });
  page.evaluate('reads=[];postMeasures=0;height=40');
  page.deliver(patchOf(2, 2, ' more words')); page.step(16);
  const grown = JSON.parse(String(page.evaluate('JSON.stringify({reads,postMeasures})')));
  assert.equal(grown.postMeasures, 1);
  assert.equal(grown.reads.filter((seq: number) => seq === 2).length, 2);
  assert.ok(grown.reads.filter((seq: number) => seq !== 2).length <= 2);
});

test('assistant items and text patches in one turn never take the dots out of the page', async () => {
  const page = await latestPage(), watch = frameWatch(page);
  page.evaluate("state={...state,life:{type:'ready'},working:true,since:1700000000000}");
  page.deliver({ type: 'item', item: assistant(0, 'Reading.') });
  page.step(16);
  watch.counts.removals = 0;
  for (let seq = 1; seq <= 4; seq++) {
    page.deliver({ type: 'item', item: assistant(seq, 'Part ' + seq) });
    page.step(16);
    for (let revision = 1; revision <= 3; revision++) { page.deliver(patchOf(seq, revision, ' more ' + revision)); page.step(16); }
  }
  assert.equal(watch.counts.removals, 0);
  assert.equal(page.evaluate("element('tail-slot').lastChild?.className.includes('working')"), true);
});

test('a new reveal tail is prepared in its rendering frame', async () => {
  const page = await latestPage(), watch = frameWatch(page);
  page.deliver({ type: 'item', item: assistant(0, 'Intro.\n\none two three four five six') });
  page.evaluate("node('div').append(node('i'))");
  assert.equal(page.evaluate('texts.has("0:0")'), false);
  watch.frame(16);
  assert.deepEqual([page.evaluate("texts.get('0:0').reveal.tail.units.map(unit => [unit.bottom, unit.complete]).join('|')"), page.evaluate('revealPreparation.size'), page.evaluate('revealDirty')], ['20,true|40,false', 0, false]);
});

test('a fresh row that jumps from below the view to above it leaves the count', async () => {
  const page = await latestPage();
  page.add(page.text(0)); page.add(page.own(1));
  page.scroll(0);
  page.add(page.text(2)); page.add(page.text(3));
  assert.equal(page.latest(), '↓ 2 new,true');
  page.evaluate("element('scroll').scrollTop=900;element('scroll').onscroll();frame()");
  assert.equal(page.latest().split(',')[0], '↓ Latest');
});

test('a new block holds, is measured after layout, grows with its measured height, and ends with neither class', async () => {
  const page = await revealPage();
  page.evaluate("let content=template.content;Object.defineProperty(template,'content',{get:()=>content,set(value){content=value;for(const child of value.childNodes)Object.assign(child,{scrollHeight:66,offsetHeight:2,clientHeight:0})}})");
  page.deliver({ type: 'item', item: assistant(0, 'First.\n\nSecond.') });
  const classes = () => String(page.evaluate("texts.get('0:0').view.children.filter(block => !block.classList.contains('message-header')).map(block => block.className).join('|')"));
  const height = () => page.evaluate("texts.get('0:0').view.children.find(block => !block.classList.contains('message-header')).style['--h']");
  page.step(16);
  assert.deepEqual([classes(), height(), page.evaluate('measuredHolds.size')], ['hold|reveal dormant', undefined, 1]);
  page.step(16);
  assert.deepEqual([classes(), height(), page.evaluate('measuredHolds.size')], ['grow|reveal dormant', '68px', 0]);
  page.evaluate("texts.get('0:0').view.children.forEach(block => block.handlers.get('animationend')?.())");
  assert.equal(classes(), '|reveal dormant');
});

test('reduced motion shows a completed block at full height in its first frame without a grow', async () => {
  const page = await revealPage();
  Object.assign(page.app.context, { matchMedia: () => ({ matches: true }) });
  page.deliver({ type: 'item', item: assistant(0, 'First.\n\nSecond.') });
  page.step(16);
  assert.equal(page.evaluate("texts.get('0:0').view.children.find(block => !block.classList.contains('message-header')).className"), '');
  assert.equal(page.evaluate('growing.length + measuredHolds.size'), 0);
  assert.equal(page.evaluate('animating.size'), 0);
});

test('unit geometry groups inline fragments by line, closes complete code and skips what never reveals partially', async () => {
  const app = await page(), { document } = app.context;
  const box = (tag: string, rects: { top: number; bottom: number }[] = [], children: InstanceType<typeof app.context.Node>[] = []) => { const node = document.createElement(tag); node.rects = rects; node.getBoundingClientRect = () => ({ top: 0, bottom: rects.at(-1)?.bottom ?? 0 }); node.append(...children); return node; };
  const wrap = (child: InstanceType<typeof app.context.Node>) => { const wrapper = box('div'); wrapper.append(child); return wrapper; };
  const unitsOf: (wrapper: object, token: unknown, frontier: unknown) => { bottom: number; complete: boolean }[] = Reflect.get(app.context, 'unitsOf');
  const units = (wrapper: object, raw: string) => { const tail = markdown()(raw).at(-1)?.tail; assert.ok(tail); return JSON.stringify(unitsOf(wrapper, tail.token, tail.frontier).map(unit => [unit.bottom, unit.complete])); };
  const paragraph = box('p', [{ top: 2, bottom: 18 }, { top: 4, bottom: 16 }, { top: 22, bottom: 38 }, { top: 42, bottom: 58 }]);
  assert.equal(units(wrap(paragraph), 'aa `bb` cc dd ee'), '[[20,true],[40,true],[60,false]]');
  const spaced = box('p', [{ top: 6, bottom: 22 }, { top: 26, bottom: 42 }]);
  spaced.getBoundingClientRect = () => ({ top: 4, bottom: 42 });
  assert.equal(units(wrap(spaced), 'aa bb cc dd'), '[[20,true],[40,false]]', 'a margin inside the dormant wrapper does not shift the units');
  const code = box('code', [{ top: 2, bottom: 18 }, { top: 22, bottom: 38 }, { top: 42, bottom: 58 }]), pre = box('pre', [], [code]);
  pre.querySelector = () => code;
  pre.getBoundingClientRect = () => ({ top: 0, bottom: 70 });
  assert.equal(units(wrap(pre), '```js\na\nb\nc'), '[[20,true],[40,true],[60,false]]');
  const closed = box('code', [{ top: 2, bottom: 18 }, { top: 22, bottom: 38 }]), shut = box('pre', [], [closed]);
  shut.querySelector = () => closed;
  shut.getBoundingClientRect = () => ({ top: 0, bottom: 60 });
  assert.equal(units(wrap(shut), '```js\na\nb\n'), '[[20,true],[60,true]]');
  const bold = box('p', [{ top: 2, bottom: 18 }, { top: 22, bottom: 38 }, { top: 2, bottom: 18 }, { top: 22, bottom: 38 }, { top: 2, bottom: 18 }]);
  assert.equal(units(wrap(bold), 'aa **bb cc** dd'), '[[20,true],[40,false]]', 'duplicated and out-of-order fragments of a wrapped element');
  const item = (bottom: number) => { const node = box('li'); node.getBoundingClientRect = () => ({ top: 0, bottom }); return node; };
  assert.equal(units(wrap(box('ul', [], [item(20), item(40), item(60)])), '- a\n- b\n- c'), '[[20,true],[40,true],[60,false]]');
  assert.equal(units(wrap(box('ul', [], [item(20), item(40)])), '- a\n  ```\n  x\n  ```\n- b'), '[]');
  assert.equal(units(wrap(paragraph), '### Heading'), '[]');
  assert.equal(units(wrap(paragraph), '> quote'), '[]');
  const row = (bottom: number) => { const node = box('tr'); node.getBoundingClientRect = () => ({ top: 0, bottom }); return node; };
  const table = box('table');
  table.querySelectorAll = () => [row(20), row(40), row(60)];
  assert.equal(units(wrap(table), '| a | b |\n| - | - |\n| 1 | 2 |\n| 3 |'), '[]');
  assert.equal(units(wrap(table), '| a | b |\n| - | - |\n'), '[]');
});

test('a width change re-reads the tail geometry, and a replaced tail completes its preparation', async () => {
  const fixture = await revealPage(200);
  const code = Array.from({ length: 20 }, (_, index) => 'line ' + index).join('\n');
  fixture.put('Intro.\n\n```js\n' + code);
  fixture.step(0);
  const units = () => fixture.evaluate("texts.get('0:0').reveal.tail.units.length");
  assert.equal(units(), 21);
  fixture.bars.at(-1)?.onclick?.();
  fixture.evaluate("texts.get('0:0').reveal.tail.view.children[0].querySelector('code').rects.push({ top: 422, bottom: 438 })");
  fixture.evaluate('invalidateExtents()');
  assert.equal(units(), 22);
  fixture.patch(1, '\nmore');
  fixture.step(0);
  assert.equal(fixture.evaluate('revealPreparation.size'), 0);
  assert.equal(units(), 22);
});

test('a clip that reflow leaves inside a line snaps down to the last whole line and puts the wrapper out of the flow at zero', async () => {
  const fixture = await revealPage(200);
  fixture.put('Intro.\n\none two three four five six');
  fixture.step(0);
  fixture.step(1500);
  fixture.step(0);
  assert.equal(tailOf(fixture).shown, 20);
  fixture.evaluate("texts.get('0:0').reveal.tail.view.children[0].rects = [{ top: 2, bottom: 18 }];element('items').clientWidth++;resized([{ target: element('items'), borderBoxSize: [{ blockSize: 0 }] }])");
  fixture.step(16);
  assert.deepEqual([tailOf(fixture).shown, tailOf(fixture).clip, fixture.evaluate("texts.get('0:0').reveal.tail.view.className")], [0, '0px', 'reveal dormant']);
});

test('a view left while following reopens at the end, whatever the other view did to the scroll box', async () => {
  const f = await jobPage();
  const text = (seq: number) => ({ seq, revision: 0, kind: 'assistant', final: true, blocks: [{ type: 'text', text: 'reply ' + seq }] });
  f.evaluate(`apply({type:'item',item:${JSON.stringify(text(0))}})`); f.step(0);
  f.scroll(900);
  assert.equal(f.evaluate('scrolling.mode.kind'), 'following');
  f.open('j1');
  f.reset('j1', 'one\n');
  f.evaluate("Object.assign(element('scroll'),{scrollHeight:300,scrollTop:0})");
  f.evaluate("apply({...state,type:'state',sessionId:'s',life:{type:'ready'},view:{id:'r',type:'agent',path:[{id:'r',name:'ko',type:'agent'}]}})");
  f.evaluate(`apply({type:'reset',epoch:'a',more:false,items:${JSON.stringify([text(0)])}})`);
  f.evaluate("element('scroll').scrollHeight=1200");
  f.step(16);
  assert.equal(f.evaluate('scrolling.mode.kind'), 'following');
  assert.equal(f.evaluate("element('scroll').scrollTop"), 1100);
  assert.equal(f.latest().endsWith('false'), true);
});

async function windowPage(margin = 0) {
  const page = await flowPage(margin);
  page.evaluate("element('items').hidden=false");
  const rows = (from: number, to: number) => Array.from({ length: to - from }, (_, index) => (from + index) % 2 ? page.text(from + index) : page.own(from + index));
  const px = (value: unknown) => parseFloat(String(value ?? '')) || 0;
  const padding = () => px(page.evaluate("element('items').style.paddingTop"));
  const extents = (): [number, { kind: string; width?: number; px: number }][] => JSON.parse(String(page.evaluate("JSON.stringify([...extents])")));
  const guess = (seq: number) => seq % 2 ? 20 : 50;
  return { ...page, rows, padding, extents, guess };
}

test('a reset mounts only the end window and pads the absent rows by their extents', async () => {
  const page = await windowPage(), shown = new Set<number>();
  page.evaluate(`apply({type:'reset',epoch:'a',more:false,items:${JSON.stringify(page.rows(0, 300))}})`);
  for (let frame = 0; frame < 8; frame++) { page.step(16); for (const seq of page.seqs()) shown.add(seq); }
  const mounted = page.seqs(), first = mounted[0];
  assert.ok(mounted.length > 0 && mounted.length < 40, 'mounted ' + mounted.length);
  assert.deepEqual(mounted, Array.from({ length: 300 - first }, (_, index) => first + index), 'the window is one range that ends at the end');
  let absent = 0;
  for (let seq = 0; seq < first; seq++) absent += shown.has(seq) ? 100 : page.guess(seq);
  assert.equal(page.padding(), absent, 'a row that was mounted keeps its measured extent, the others their estimate');
  assert.ok(shown.size < 80, 'the window never mounted the history: ' + shown.size);
  assert.equal(page.top(), page.bottom());
  assert.equal(page.evaluate('scrolling.mode.kind'), 'following');
});

test('a scrollbar jump mounts the reader and preserves its offset', async () => {
  const page = await windowPage();
  page.open(page.rows(0, 300));
  page.settle(8);
  page.reader(0);
  page.settle(8);
  assert.deepEqual([page.seqs()[0], page.seqs().includes(299), page.seqs().length < 40], [0, false, true], 'the first rows are mounted and the end rows are not');
  page.reader(4000);
  page.settle(8);
  const mounted = page.seqs(), anchor = Number(page.evaluate('scrolling.mode.anchor.item.seq'));
  assert.ok(mounted.length < 40 && mounted.includes(anchor) && !mounted.includes(0) && !mounted.includes(299));
  const before = page.offset(anchor);
  page.extra.set(mounted[0], 60);
  page.settle(4);
  assert.equal(page.offset(anchor), before);
  assert.equal(page.padding() > 0, true);
});

test('a finished ending run keeps its slot hidden while unmounted', async () => {
  const page = await windowPage();
  page.open([...page.rows(0, 300), {seq:300,revision:0,at:300,kind:'assistant',final:true,stop:'stop',error:'',blocks:[{type:'thinking',text:'Done',started:1,ended:2}]}]);
  page.evaluate("for(const seq of order)extents.set(seq,{kind:'estimated',px:seq===300?33:100});table=undefined;frame()");
  page.settle(8);
  const height = page.evaluate("element('scroll').scrollHeight");
  assert.equal(page.evaluate("element('tail-slot').hidden"), true);
  page.reader(0); page.settle(8);
  assert.equal(page.seqs().includes(300), false, 'the finished tail unmounts');
  assert.equal(page.evaluate("element('tail-slot').hidden"), true, 'slot visibility does not depend on mounting');
  assert.equal(page.evaluate("element('scroll').scrollHeight"), height);
  page.reader(Number(height)); page.settle(8);
  assert.equal(page.seqs().includes(300), true);
  assert.equal(page.evaluate("element('tail-slot').hidden"), true);
  assert.equal(page.evaluate("element('scroll').scrollHeight"), height);
});

test('a reader window keeps the live tail connected', async () => {
  const page = await windowPage();
  page.evaluate("state={...state,working:true,since:1700000000000}");
  page.open(page.rows(0, 300));
  page.deliver(page.reveal(300, 'Intro.\n\nwaiting tail'));
  page.settle(8);
  const memo = page.evaluate("texts.get('300:0')"), row = page.evaluate('views.get(300).view'), dots = page.evaluate('working.primary');
  page.reader(0);
  page.settle(8);
  assert.deepEqual([page.seqs()[0], page.seqs().at(-1), page.seqs().length < 60], [0, 300, true]);
  for (let revision = 1; revision < 6; revision++) {
    page.deliver(page.suffix(300, revision, ' more ' + revision));
    page.settle(4);
    assert.equal(page.evaluate("texts.get('300:0')"), memo);
    assert.equal(page.evaluate('views.get(300).view'), row);
    assert.equal(page.evaluate('working.primary'), dots);
    assert.deepEqual([page.evaluate("element('items').contains(texts.get('300:0').reveal.tail.view)"), page.evaluate("element('tail-slot').contains(working.primary)"), page.evaluate("element('items').contains(views.get(300).view)")], [true, true, true]);
  }
  assert.ok(page.seqs().length < 60 && page.seqs()[0] === 0);
});

test('new items below the dock are counted without DOM rows', async () => {
  const page = await windowPage();
  page.pad.value = 96;
  page.evaluate("element('scroll').clientHeight=400");
  page.open(page.rows(0, 300));
  page.settle(8);
  page.reader(0);
  page.settle(8);
  for (let seq = 301; seq <= 305; seq += 2) page.deliver({ type: 'item', item: page.text(seq) });
  page.deliver({ type: 'item', item: page.text(300) });
  page.settle(4);
  assert.equal(page.latest(), '↓ 4 new,true');
  assert.deepEqual([...page.seqs()].filter(seq => seq >= 300), [], 'no row for an item that nobody can see');
  page.deliver(page.suffix(305, 1, ' more'));
  page.settle(4);
  assert.equal(page.latest(), '↓ 4 new,true');
  const toward = (top: number) => { page.reader(top); page.settle(8); };
  toward(page.bottom() - 60);
  const fresh: number[] = JSON.parse(String(page.evaluate("JSON.stringify([...scrolling.unread.candidates].flatMap(([seq,rows])=>[...rows.values()].filter(candidate=>candidate.status === 'unread').map(()=>seq)))"))), below = fresh.filter(seq => page.seqs().includes(seq) && page.offset(seq) >= Number(page.evaluate('measure().dock'))).length;
  assert.equal(page.latest().split(',')[0], below ? '↓ ' + below + ' new' : '↓ Latest', String(page.evaluate("JSON.stringify({top:geometry().top,dock:measure().dock,candidates:[...scrolling.unread.candidates].flatMap(([seq,rows])=>[...rows.values()].filter(candidate=>candidate.status === 'unread').map(candidate=>({...candidate,seq,lookup:measure().lookup({kind:'message',seq,row:candidate.row}),rect:views.get(seq)?.view.getBoundingClientRect()})))})")));
  assert.ok(below < 4, 'scrolling toward the new items counted some of them as seen');
});

test('a width change replaces mounted measurements and invalidates absent ones', async () => {
  const page = await windowPage();
  page.open(page.rows(0, 300));
  page.settle(8);
  const mounted = page.seqs(), measured = () => page.extents().filter(([, extent]) => extent.kind === 'measured');
  assert.ok(measured().length >= mounted.length && measured().every(([, extent]) => extent.width === 320), 'a row that scrolled out keeps its measurement');
  page.evaluate("element('items').clientWidth=200;resized([{target:element('items'),borderBoxSize:[{blockSize:1}]}]);flushExtents();ensureTable()");
  assert.deepEqual(measured().map(([seq]) => seq), mounted, 'only the mounted rows are measured again');
  assert.ok(measured().every(([, extent]) => extent.width === 200), 'every measurement is at the new width');
  assert.deepEqual(page.extents().find(([seq]) => seq === 285)?.[1], { kind: 'estimated', px: page.guess(285) });
});

test('a run or job group is mounted whole or not at all, and a folded fence stays open through a remount', async () => {
  const page = await windowPage();
  const think = (seq: number) => ({ seq, revision: 0, kind: 'assistant', final: true, blocks: [{ type: 'thinking', text: 'hmm', redacted: false }] });
  const fence = { seq: 1, revision: 0, kind: 'assistant', final: true, blocks: [{ type: 'text', text: '```\n' + Array.from({ length: 20 }, (_, line) => 'line ' + line).join('\n') + '\n```' }] };
  const job = { id: 'j', name: 'j', service: false, log: '/l', command: 'c', startedAt: 0, place: { type: 'mac' } };
  const stream = (seq: number) => ({ seq, revision: 0, at: 1, final: true, kind: 'job', job, event: { type: 'stream', batch: { text: 'out ' + seq, cut: 0 }, omitted: 0, cut: false } });
  const jobs = [stream(200), stream(201), stream(202), stream(203), { seq: 204, revision: 0, at: 1, final: true, kind: 'job', job, event: { type: 'ended', end: { type: 'exit', code: 0 }, tail: { text: '', cut: 0 } } }];
  const items = [...page.rows(0, 1), fence, ...page.rows(2, 150), ...[150, 151, 152, 153, 154, 155].map(think), ...page.rows(156, 200), ...jobs, ...page.rows(205, 300)];
  page.open(items);
  page.settle(8);
  const group = [150, 151, 152, 153, 154, 155];
  const boundaries = [150, 200].flatMap(seq => {
    page.reader(Number(page.evaluate(`ensureTable().starts[ensureTable().index.get(${seq})]`)));
    page.settle(8);
    return [
      { seq, edge: 'enter', delta: -1, present: false }, { seq, edge: 'enter', delta: 1, present: true },
      { seq, edge: 'leave', delta: -1, present: true }, { seq, edge: 'leave', delta: 1, present: false },
    ];
  });
  for (const { seq, edge, delta, present } of boundaries) {
    const end = seq === 150 ? 155 : 204;
    const boundary = Number(page.evaluate(edge === 'enter'
      ? `ensureTable().starts[ensureTable().index.get(${seq})]-2*geometry().viewport`
      : `ensureTable().starts[ensureTable().index.get(${end})+1]+geometry().viewport`));
    const top = boundary + delta;
    page.reader(top);
    page.settle(6);
    assert.equal(page.seqs().includes(seq), present, `${seq} ${edge} ${delta}`);
    const mounted = group.filter(seq => page.seqs().includes(seq)).length;
    assert.ok(mounted === 0 || mounted === group.length, 'the run is split at ' + top);
    const members = [200, 201, 202, 203, 204].filter(seq => page.seqs().includes(seq)).length;
    assert.ok(members === 0 || members === 5, 'the job group is split at ' + top);
    if (members) assert.deepEqual([page.evaluate('views.get(200).view.children.length'), page.evaluate('views.get(201).view.children[0].children.length===0')], [1, true], 'the run is in the first row and follower slots are empty');
  }
  page.reader(0);
  page.settle(8);
  assert.ok(page.seqs().includes(1));
  const bars = page.bars.length;
  assert.ok(bars > 0, 'the long fence is folded');
  page.bars.at(-1)?.onclick?.();
  page.reader(page.bottom());
  page.settle(8);
  assert.ok(!page.seqs().includes(1));
  page.reader(0);
  page.settle(8);
  assert.ok(page.seqs().includes(1));
  assert.equal(page.bars.length, bars, 'a remounted fence that was opened gets no new fold bar');
});

test('a short reset fills the viewport from older pages and stops at the end or a failure', async () => {
  for (const outcome of ['filled', 'end', 'failed', 'throws', 'already filled']) {
    const page = await windowPage(), requests: number[] = [];
    page.evaluate("element('scroll').clientHeight=1000");
    Object.assign(page.app.context, { fetch: async (path: string) => {
      const before = Number(path.match(/before=(\d+)/)?.[1]); requests.push(before);
      if (outcome === 'throws') throw Error('offline');
      return { ok: outcome !== 'failed', json: async () => ({ type: 'reset', epoch: 'a', more: outcome !== 'end', items: page.rows(outcome === 'filled' ? 0 : before - 1, before) }) };
    } });
    page.open(page.rows(20, outcome === 'already filled' ? 100 : 21), true);
    for (let turn = 0; turn < 6; turn++) { page.settle(4); await page.settled(); }
    assert.deepEqual(requests, outcome === 'already filled' ? [] : [20], outcome);
    assert.equal(page.evaluate('scrolling.mode.kind'), 'following', outcome);
  }
});

test('a reset followed by its initial state still fills short history', async () => {
  const page = await windowPage(), requests: string[] = [];
  page.evaluate("element('scroll').clientHeight=1000");
  Object.assign(page.app.context, { fetch: async (path: string) => {
    requests.push(path);
    return { ok: true, json: async () => ({ type: 'reset', epoch: 'a', more: false, items: page.rows(0, 20) }) };
  } });
  page.evaluate(`apply({type:'reset',epoch:'a',more:true,items:${JSON.stringify(page.rows(20, 21))}});apply({...state,type:'state',sessionId:'initial',view:{id:'initial',type:'root',path:[]}})`);
  for (let turn = 0; turn < 6; turn++) { page.settle(4); await page.settled(); }
  assert.equal(requests.length, 1);
  assert.equal(page.evaluate('transcriptHistory.more'), false);
});

test('a short reset continues through multiple older pages', async () => {
  const page = await windowPage(), requests: number[] = [];
  page.evaluate("element('scroll').clientHeight=1000");
  Object.assign(page.app.context, { fetch: async (path: string) => {
    const before = Number(path.match(/before=(\d+)/)?.[1]); requests.push(before);
    return { ok: true, json: async () => ({ type: 'reset', epoch: 'a', more: before > 19, items: page.rows(before - 1, before) }) };
  } });
  page.open(page.rows(20, 21), true);
  for (let turn = 0; turn < 8; turn++) { page.settle(4); await page.settled(); }
  assert.deepEqual(requests, [20, 19]);
});

test('returning to an absent anchor loads older pages until it is loaded, mounts it and restores the offset', async () => {
  const page = await windowPage();
  const requests: number[] = [];
  Object.assign(page.app.context, { fetch: async (path: string) => {
    const before = Number(path.match(/before=(\d+)/)?.[1]), from = Math.max(0, before - 60);
    requests.push(before);
    return { ok: true, json: async () => ({ type: 'reset', epoch: 'a', more: from > 0, items: page.rows(from, before) }) };
  } });
  page.go('r'); page.open(page.rows(100, 300), true);
  page.settle(8);
  page.reader(2000);
  page.settle(8);
  const anchor = Number(page.evaluate('scrolling.mode.anchor.item.seq')), offset = page.offset(anchor);
  assert.ok(anchor > 100 && anchor < 280);
  page.go('a'); page.open([page.text(1000)]);
  page.go('r'); page.open(page.rows(280, 300), true);
  page.deliver({ type: 'item', item: page.text(301) });
  page.deliver({ type: 'item', item: page.text(303) });
  for (let turn = 0; turn < 6; turn++) { await page.settled(); page.settle(4); }
  assert.deepEqual(requests, [280, 220, 160].slice(0, requests.length));
  assert.ok(requests.length >= 1 && (requests.at(-1) ?? Infinity) <= anchor + 60, 'the requests stop once the anchor is loaded: ' + requests);
  assert.equal(page.evaluate('scrolling.mode.kind'), 'reader', String(page.evaluate('JSON.stringify({scrolling,pending:transcriptHistory.pending,generation:scrolling.generation,first,request:scrollDecision.request,events:scrollEvents})')));
  assert.ok(page.seqs().includes(anchor) && page.seqs().length < 40);
  assert.equal(page.offset(anchor), offset);
  assert.equal(page.latest(), '↓ 2 new,true');
  assert.equal(page.evaluate('transition === undefined'), true, 'the restored presentation commits without a timer');
});

test('a history of text-only assistant items mounts a window at the end and after a jump', async () => {
  const page = await windowPage();
  page.open(Array.from({ length: 400 }, (_, seq) => page.text(seq)));
  page.settle(8);
  assert.ok(page.seqs().length < 60, 'the end window holds ' + page.seqs().length);
  page.reader(page.bottom() / 2);
  page.settle(8);
  assert.ok(page.seqs().length < 60 && page.seqs().length > 0, 'the jumped window holds ' + page.seqs().length);
});

test('a patch of one item updates its table entry in place', async () => {
  const page = await windowPage();
  page.open(page.rows(0, 300));
  page.deliver(page.reveal(300, 'Intro.'));
  page.settle(8);
  const before = page.evaluate('table'), total = Number(page.evaluate('table.starts[order.length]'));
  page.deliver(page.suffix(300, 1, '\n\nmore\n\nlines\n\nhere'));
  page.settle(4);
  assert.equal(page.evaluate('table'), before, 'the table is not rebuilt');
  assert.deepEqual([page.evaluate('table.starts[order.length]') !== total, page.evaluate('table.starts.length')], [true, 302]);
});

test('a reconcile across an unmounted text item keeps the two runs apart', async () => {
  const page = await windowPage();
  const step = (seq: number, blocks: object[]) => ({ seq, revision: 0, kind: 'assistant', final: true, blocks });
  const tool = { type: 'tool', id: 't', name: 'read', args: { text: '{}' }, state: { type: 'done', error: false, result: { text: '', images: [] } } };
  page.open([step(0, [tool]), step(1, [{ type: 'text', text: 'between' }]), step(2, [{ ...tool, id: 'u' }])]);
  page.settle(4);
  page.evaluate('unmountRow(1); reconcileRuns()');
  assert.equal(page.evaluate("runMarks.get(views.get(0).slots.get('0:0').view.firstElementChild).steps.length"), 1, 'the first run keeps its own step');
  assert.equal(page.evaluate("views.get(2).slots.get('2:0').view.children.length"), 1, 'the last step owns its run');
});

test('a job view that is idle schedules no frame', async () => {
  const page = await windowPage();
  page.open(page.rows(0, 20));
  page.settle(4);
  page.evaluate("apply({...state,type:'state',view:{...state.view,type:'job',id:'job',job:{name:'build',command:'make',service:false,startedAt:1,place:{type:'mac'},log:'/tmp/job',state:{type:'running'}}}})");
  page.step(16); page.step(16);
  assert.deepEqual([page.queued.size, page.timers.size], [0, 0]);
});

test('the table total includes row margins with a divider and a reader window', async () => {
  const page = await windowPage(14);
  page.origin.value = 30;
  page.open(page.rows(0, 300));
  page.settle(8);
  const total = () => [page.evaluate("element('scroll').scrollHeight"), page.evaluate("table.starts[order.length] + geometry().origin + (element('tail-slot').hidden ? 0 : element('tail-slot').offsetHeight)")];
  page.reader(3000);
  page.settle(8);
  assert.ok(page.padding() > 0 && page.seqs().length < 40);
  const [dom, model] = total();
  assert.equal(model, dom, 'the window at a reader position');
  for (let seq = 300; seq < 303; seq++) page.deliver({ type: 'item', item: page.text(seq) });
  page.settle(8);
  page.reader(page.bottom() - 150);
  page.settle(8);
  assert.ok(page.evaluate("!!divider"));
  const [after, expected] = total();
  assert.equal(expected, after, 'with the divider mounted');
});

test('an appended item extends the table and its last group in place', async () => {
  const page = await windowPage();
  const tool = { type: 'tool', id: 't', name: 'read', args: { text: '{}' }, state: { type: 'done', error: false, result: { text: '', images: [] } } };
  page.open([{ seq: 0, revision: 0, kind: 'assistant', final: true, blocks: [tool] }]);
  page.settle(4);
  const before = page.evaluate('table');
  for (const seq of [1, 2]) page.deliver({ type: 'item', item: { seq, revision: 0, kind: 'assistant', final: true, blocks: [{ ...tool, id: 'u' + seq }] } });
  page.settle(4);
  assert.equal(page.evaluate('table'), before, 'an append does not rebuild');
  assert.deepEqual(page.evaluate('JSON.stringify([table.groups, table.starts.length, table.index.size])'), JSON.stringify([[{ from: 0, to: 2 }], 4, 3]));
});

async function findPage() {
  const page = await windowPage();
  const { app, evaluate } = page, doc = app.context.document;
  const selection: { node?: unknown; offset: number; collapses: number } = { offset: -1, collapses: 0 };
  type Leaf = { nodeType: number; textContent: string; parentNode: unknown };
  type Tree = { children?: Tree[]; textContent?: string };
  const leaves = (root: Tree): Leaf[] => (root.children ?? []).flatMap(child => (child.children?.length ?? 0) ? leaves(child) : child.textContent ? [{ nodeType: 3, textContent: child.textContent, parentNode: child }] : []);
  Object.assign(doc, { createTreeWalker: (root: Tree) => { const list = leaves(root); let at = 0; return { nextNode: () => list[at++] ?? null }; } });
  Object.assign(app.context, { getSelection: () => ({ collapse(node: unknown, offset: number) { const length = typeof node === 'object' && node !== null ? String(Reflect.get(node, 'textContent') ?? '').length : -1; if (!(offset >= 0 && offset <= length)) throw new RangeError('offset ' + offset + ' is outside a node of ' + length); selection.node = node; selection.offset = offset; selection.collapses++; } }) });
  const find = (query: string, backwards = false): Promise<unknown> => Promise.resolve(evaluate(`window.__koFind(${JSON.stringify(query)}, ${backwards})`));
  const answer = async (query: string, backwards = false): Promise<{ index: number; count: number; loading: boolean } | null> => { const pending = find(query, backwards).then(value => ({ value }), (error: unknown) => ({ error })); for (let turn = 0; turn < 20; turn++) { page.step(16); await page.settled(); } const result = await pending; if ('error' in result) throw new Error(String(Reflect.get(Object(result.error), 'message'))); return JSON.parse(JSON.stringify(result.value)); };
  const history = (words: Record<number, string>, count = 40): Record<string, unknown>[] => Array.from({ length: count }, (_, seq) => ({ seq, revision: 0, at: 1, final: true, kind: 'assistant', blocks: [{ type: 'text', text: words[seq] ?? 'filler ' + seq }], stop: 'stop', error: '' }));
  const where = () => ({ text: typeof selection.node === 'object' && selection.node !== null ? Reflect.get(selection.node, 'textContent') : undefined, offset: selection.offset });
  return { ...page, selection, answer, find, history, where };
}

test('a find on an absent item mounts it, anchors it and collapses the selection at the occurrence', async () => {
  const page = await findPage();
  page.open(page.history({ 5: 'before zyxwvq after' }));
  page.settle(8);
  assert.ok(!page.seqs().includes(5));
  assert.deepEqual(await page.answer('zyxwvq'), { index: 1, count: 1, loading: false });
  assert.ok(page.seqs().includes(5));
  assert.deepEqual([page.evaluate('scrolling.mode.kind'), page.evaluate('scrolling.mode.anchor.item.seq')], ['reader', 5]);
  assert.deepEqual([page.where().offset, page.where().text], [7, 'before zyxwvq after']);
});

test('two occurrences in one block are visited forward and backward, and a repeat of the query steps', async () => {
  const page = await findPage();
  page.open(page.history({ 3: 'alpha beta alpha', 9: 'one alpha' }));
  page.settle(8);
  const run = async (backwards: boolean) => { const result = await page.answer('alpha', backwards); return [result, page.where().offset]; };
  assert.deepEqual(await run(false), [{ index: 1, count: 3, loading: false }, 0]);
  assert.deepEqual(await run(false), [{ index: 2, count: 3, loading: false }, 11]);
  assert.deepEqual(await run(false), [{ index: 3, count: 3, loading: false }, 4]);
  assert.deepEqual(await run(false), [{ index: 1, count: 3, loading: false }, 0], 'wraps forward');
  assert.deepEqual(await run(true), [{ index: 3, count: 3, loading: false }, 9], 'wraps backward and collapses at the end');
  assert.deepEqual(await run(true), [{ index: 2, count: 3, loading: false }, 16]);
});

test('the count is over every loaded item and markdown syntax does not match', async () => {
  const page = await findPage();
  page.open(page.history({ 2: 'say **bold** and `code`', 30: 'bold again' }));
  page.settle(8);
  assert.equal((await page.answer('bold'))?.count, 2);
  assert.equal((await page.answer('**'))?.count, 0);
  assert.equal((await page.answer('`'))?.count, 0);
});

test('find selects agent and job bodies in their earlier run owner DOM', async () => {
  const page = await findPage();
  const base = { revision: 0, at: 1, final: true };
  page.open([
    { ...base, seq: 0, kind: 'assistant', stop: 'stop', error: '', blocks: [{ type: 'thinking', text: 'Plan' }] },
    { ...base, seq: 1, kind: 'agent', direction: 'in', from: { name: 'worker' }, inbound: { form: 'report' }, text: { text: '**uniquereport**', cut: 0 } },
    { ...base, seq: 2, kind: 'job', job: { id: 'j', name: 'build', log: '/tmp/build.log', service: false }, event: { type: 'stream', batch: { text: 'uniquelog', cut: 0 }, omitted: 0, cut: false } },
  ]);
  page.settle(8);
  for (const [needle, key, seq] of [['uniquereport', '1:item', 1], ['uniquelog', '2:item', 2]] as const) {
    assert.deepEqual(await page.answer(needle), { index: 1, count: 1, loading: false });
    assert.equal(page.where().text, needle);
    Object.assign(page.app.context, { selectedNode: page.selection.node });
    assert.equal(page.evaluate(`views.get(0).view.contains(selectedNode)&&!views.get(${seq}).view.contains(selectedNode)&&openers.get('${key}').view.querySelector('.detail').contains(selectedNode)`), true);
    assert.equal(page.evaluate(`folds.get('run:0:0')&&folds.get('${key}')`), true);
  }
});

test('a match in a collapsed step opens it when current and keeps it open, and a non-current match stays closed', async () => {
  const page = await findPage();
  const tool = (id: string, result: string) => ({ type: 'tool', id, name: 'read', args: { text: '{"path":"/a"}' }, state: { type: 'done', error: false, result: { text: result, images: [] } } });
  const items = page.history({});
  items[4] = { ...items[4], blocks: [tool('a', 'needle one'), tool('b', 'needle two')] };
  page.open(items);
  page.settle(8);
  await page.answer('needle');
  const open = () => page.evaluate("JSON.stringify([folds.get('4:0'), folds.get('4:1'), folds.get('run:4:0')])");
  assert.equal(open(), '[true,null,true]');
  await page.answer('needle');
  assert.equal(open(), '[true,true,true]', 'the first step stays open after the cursor moved on');
});

test('a collapsed thinking step counts and renders its markdown when current', async () => {
  const page = await findPage();
  const items = page.history({});
  items[6] = { ...items[6], blocks: [{ type: 'thinking', text: 'deep **thought** here', redacted: false }] };
  page.open(items);
  page.settle(8);
  assert.deepEqual(await page.answer('thought'), { index: 1, count: 1, loading: false }, 'a thinking step counts once, in its body');
  assert.deepEqual([page.evaluate("folds.get('run:6:0')"), page.evaluate("folds.get('6:0')")], [true, true], 'the match opens the step and selects it in the body');
});

test('while history remains the answer is loading, and the count grows as older pages arrive', async () => {
  const page = await findPage();
  const requests: number[] = [];
  Object.assign(page.app.context, { fetch: async (path: string) => { const before = Number(path.match(/before=(\d+)/)?.[1]); requests.push(before); const from = Math.max(0, before - 20); return { ok: true, json: async () => ({ type: 'reset', epoch: 'a', more: from > 0, items: page.history({ [from + 2]: 'zyx hit' }, before).slice(from) }) }; } });
  page.open(page.history({}, 100).slice(60), true);
  page.settle(8);
  const first = await page.answer('zyx');
  assert.equal(first?.loading, true);
  for (let turn = 0; turn < 30 && (await page.answer('zyx'))?.loading; turn++) await page.settled();
  const done = await page.answer('zyx');
  assert.deepEqual([done?.loading, (done?.count ?? 0) > 0], [false, true]);
  assert.ok(requests.length >= 2);
});

test('an older request that makes no progress ends the find as an error and a job view has no hook answer', async () => {
  const page = await findPage();
  Object.assign(page.app.context, { fetch: async () => ({ ok: true, json: async () => ({ type: 'reset', epoch: 'a', more: true, items: [] }) }) });
  page.open(page.history({}, 100).slice(60), true);
  page.settle(8);
  assert.equal((await page.answer('zyx'))?.loading, true);
  await assert.rejects(page.answer('zyx'), /Could not load earlier messages/);
  page.evaluate("state={...state,view:{...state.view,type:'job'}}");
  assert.equal(await page.answer('zyx'), null);
});

test('a match across bold text is located in the nodes that hold it, forward and backward', async () => {
  const page = await findPage();
  page.open(page.history({ 3: 'say bo**ld** now' }));
  page.settle(8);
  await page.answer('bold');
  assert.deepEqual([page.where().text, page.where().offset], ['say bo', 4]);
  await page.answer('bold', true);
  assert.deepEqual([page.where().text, page.where().offset], ['ld', 2]);
});

test('a match after a character that lowercases to two units lands on the right offset', async () => {
  const page = await findPage();
  page.open(page.history({ 3: 'İx' }));
  page.settle(8);
  await page.answer('x');
  assert.deepEqual([page.where().text, page.where().offset], ['İx', 1]);
  await page.answer('x', true);
  assert.equal(page.where().offset, 2);
});

test('a match in a live thinking step and a live fence opens them in the DOM', async () => {
  const page = await findPage();
  const items = page.history({});
  items[39] = { ...items[39], final: false, blocks: [{ type: 'thinking', text: 'first\nsecond\nthird **uniqueword**', redacted: false }, { type: 'text', text: '```\n' + Array.from({ length: 20 }, (_, line) => 'line ' + line).join('\n') + '\n```' }] };
  page.open(items);
  page.settle(8);
  await page.answer('uniqueword');
  const run = "views.get(39).view.children[0].children[0]", step = run + ".children[1].children[0]";
  assert.deepEqual([page.evaluate(run + ".classList.contains('open')"), page.evaluate(step + ".classList.contains('open')"), page.evaluate(step + ".children[1].children.length > 0")], [true, true, true], 'the run, the step and its markdown are open');
  await page.answer('line 18');
  assert.equal(page.evaluate("[...views.get(39).view.children].some(child => child.className.includes('folded'))"), false);
  assert.equal(page.pres.at(-1)?.classList.contains('folded'), false, 'the fence of the live row is open');
});

test('an obsolete find never collapses the selection and answers cancelled', async () => {
  const page = await findPage();
  page.open(page.history({ 3: 'alpha here', 9: 'zeta there' }));
  page.settle(8);
  const first = page.find('alpha').then(value => value);
  const second = page.answer('zeta');
  const stale = JSON.parse(JSON.stringify(await first));
  assert.deepEqual(stale, { cancelled: true });
  assert.deepEqual(await second, { index: 1, count: 1, loading: false });
  assert.equal(page.selection.collapses, 1);
  const third = page.find('alpha');
  page.evaluate('window.__koFindCancel()');
  for (let turn = 0; turn < 10; turn++) { page.step(16); await page.settled(); }
  assert.deepEqual(JSON.parse(JSON.stringify(await third)), { cancelled: true });
  assert.equal(page.selection.collapses, 1, 'a closed bar leaves the selection');
  const reset = page.find('alpha');
  page.evaluate("apply({type:'reset',epoch:'b',more:false,items:[]})");
  for (let turn = 0; turn < 10; turn++) { page.step(16); await page.settled(); }
  assert.deepEqual(JSON.parse(JSON.stringify(await reset)), { cancelled: true });
});

async function selectionPage() {
  const page = await findPage();
  const { app, evaluate } = page;
  type Pick = { rangeCount: number; isCollapsed: boolean; whole: boolean; startContainer?: unknown; endContainer?: unknown };
  const selection: Pick & { containsNode(node: unknown): boolean; getRangeAt(): { startContainer: unknown; endContainer: unknown } } = { rangeCount: 0, isCollapsed: true, whole: false, containsNode() { return this.whole; }, getRangeAt() { return { startContainer: this.startContainer, endContainer: this.endContainer }; } };
  Object.assign(app.context, { getSelection: () => selection });
  const list = app.context.document.getElementById('items');
  Object.assign(list, { compareDocumentPosition: (other: unknown) => other instanceof app.context.Node && list.contains(other) ? 20 : 4 });
  const leaf = (seq: number) => evaluate(`views.get(${seq}).view.children[0].children[0] ?? views.get(${seq}).view.children[0]`);
  const fire = () => app.listeners.get('selectionchange')?.({});
  const set = (start: unknown, end: unknown, whole = false) => { Object.assign(selection, { rangeCount: 1, isCollapsed: false, whole, startContainer: start, endContainer: end }); fire(); };
  const select = (from: number, to: number) => set(leaf(from), leaf(to));
  const selectAll = () => set(leaf(page.seqs()[0]), leaf(page.seqs().at(-1) ?? 0), true);
  const collapse = () => { Object.assign(selection, { rangeCount: 1, isCollapsed: true }); fire(); };
  const copy = () => { const written: Record<string, string> = {}; let prevented = false; app.listeners.get('copy')?.({ preventDefault() { prevented = true; }, clipboardData: { setData(type: string, value: string) { written[type] = value; } } }); return { written, prevented }; };
  return { ...page, selection, select, selectAll, set, leaf, collapse, copy };
}

test('a row inside a selection stays mounted when the window moves, and a collapse releases it', async () => {
  const page = await selectionPage();
  page.open(page.rows(0, 300));
  page.settle(8);
  page.reader(1500);
  page.settle(8);
  const near = page.seqs();
  const [low, high] = [near[1], near[3]];
  page.select(low, high);
  page.reader(0);
  page.settle(8);
  const kept = page.seqs();
  for (let seq = low; seq <= high; seq++) assert.ok(kept.includes(seq), 'row ' + seq + ' is pinned');
  assert.ok(kept.includes(0), 'and the viewport rows are mounted');
  page.collapse();
  page.settle(8);
  assert.ok(!page.seqs().includes(low) && !page.seqs().includes(high), 'a collapse releases the rows');
});

test('a pinned selection, the window and the live tail are three ranges with a gap each', async () => {
  const page = await selectionPage();
  page.evaluate("state={...state,working:true,since:1700000000000}");
  page.open(page.rows(0, 300));
  page.deliver(page.reveal(300, 'tail'));
  page.settle(8);
  page.reader(1500);
  page.settle(8);
  const near = page.seqs();
  page.select(near[1], near[2]);
  page.reader(0);
  page.settle(8);
  assert.equal(page.evaluate("element('items').children.filter(child => child.className.includes('gap')).length"), 2);
  assert.ok(page.seqs().includes(300) && page.seqs().includes(0) && page.seqs().includes(near[1]));
  assert.equal(page.evaluate("table.starts[order.length] + geometry().origin + (element('tail-slot').hidden ? 0 : element('tail-slot').offsetHeight)"), page.evaluate("element('scroll').scrollHeight"), 'the table and the layout agree');
});

test('Select All never pins the rows between the window and a distant tail', async () => {
  const page = await selectionPage();
  page.evaluate("state={...state,working:true,since:1700000000000}");
  page.open(page.rows(0, 300));
  page.deliver(page.reveal(300, 'tail'));
  page.settle(8);
  page.reader(0);
  page.settle(8);
  page.selectAll();
  page.settle(8);
  assert.ok(page.seqs().length < 60, 'mounted ' + page.seqs().length);
});

test('a selection that leaves the transcript pins the rows where it meets it, and one inside the composer pins nothing', async () => {
  const page = await selectionPage();
  page.open(page.rows(0, 300));
  page.settle(8);
  page.reader(1500);
  page.settle(8);
  const near = page.seqs();
  page.set(page.leaf(near[1]), page.app.prompt());
  page.reader(0);
  page.settle(8);
  for (const seq of [near[1], near[2], near[near.length - 1]]) assert.ok(page.seqs().includes(seq), 'row ' + seq + ' stays between the start and the last row that was mounted');
  page.collapse();
  page.settle(8);
  page.set(page.app.prompt(), page.app.prompt());
  page.settle(8);
  assert.ok(page.seqs().length < 40 && !page.seqs().includes(near[1]), 'a composer selection pins nothing');
});

test('Select All is derived from the selection at copy time, in the menu and the key alike', async () => {
  const page = await selectionPage();
  page.open(page.history({ 3: 'bold **word** here' }, 60));
  page.settle(8);
  assert.equal(page.copy().prevented, false, 'no selection, native copy');
  page.selectAll();
  const whole = page.copy();
  assert.equal(whole.prevented, true);
  const text = whole.written['text/plain'] ?? '';
  assert.deepEqual([text.startsWith('filler 0\n\nfiller 1'), text.includes('bold **word** here'), text.includes('filler 59'), text.split('\n\n').length], [true, true, true, 60]);
  page.set(page.leaf(page.seqs()[1]), page.leaf(page.seqs().at(-1) ?? 0));
  assert.equal(page.copy().prevented, false, 'a keyboard adjustment that drops the first row is a native copy');
  page.collapse();
  assert.equal(page.copy().prevented, false);
});

test('item corrections keep loaded history and ignore unloaded older rows', async () => {
  const page = await windowPage();
  page.open(page.rows(20, 80), true);
  page.evaluate("element('scroll').scrollTop=300");
  const before = page.evaluate("({ seqs: [...items.keys()], top: element('scroll').scrollTop, epoch })");
  page.evaluate("apply({type:'item',item:{kind:'user',seq:3,revision:2,at:1,final:true,text:'unloaded',topic:'renamed'}})");
  page.evaluate("apply({type:'item',item:{...items.get(25),revision:2,text:'corrected',topic:'renamed'}})");
  assert.deepEqual(page.evaluate("({ seqs: [...items.keys()], top: element('scroll').scrollTop, epoch })"), before);
  assert.equal(page.evaluate("items.get(25).topic"), 'renamed');
});

test('a topic switch keeps its presentation until history arrives and lands once', async () => {
  const page = await windowPage();
  page.evaluate("element('scroll').clientHeight=500");
  const initial = page.rows(300, 400).map(row => ({ ...row, topic: row.seq >= 398 ? 'one' : 'two' }));
  const older = page.rows(100, 200).map(row => ({ ...row, topic: 'one' }));
  page.evaluate("state={...state,sessionId:'s',topics:[{name:'one'},{name:'two'}]}");
  page.open(initial); page.settle(12);
  const release = page.gate([...older, ...initial.slice(-2)]);
  const sample = () => { const first = page.seqs().find(seq => page.offset(seq) + 100 > 0); return { top: page.top(), first, offset: first === undefined ? undefined : page.offset(first), mode: page.evaluate('scrolling.mode.kind') }; };
  const initialPosition = sample();
  page.evaluate("topics.debug.updateTopicFilter('one'); apply({type:'item',item:{...items.get(395),revision:1}})");
  const before = []; for (let frame = 0; frame < 12; frame++) { page.step(16); before.push(sample()); }
  assert.deepEqual(before.map(({ first, offset }) => ({ first, offset })), before.map(() => ({ first: initialPosition.first, offset: initialPosition.offset })));
  assert.equal(page.evaluate('visible(395)?.seq'), 395);
  release();
  const after = []; for (let turn=0;turn<20;turn++) { await page.settled(); page.step(16); after.push(sample()); }
  assert.deepEqual(after.map(({ first, offset }) => ({ first, offset })), after.map(() => ({ first: 192, offset: -Number(page.evaluate("element('tail-slot').offsetHeight")) })));
});

test('a reset during a topic switch saves the replacement topic position', async () => {
  const page = await windowPage();
  page.evaluate("element('scroll').clientHeight=500; state={...state,sessionId:'s',topics:[{name:'one'},{name:'two'}]}");
  const rows = page.rows(100, 200).map(row => ({ ...row, topic: 'one' }));
  page.open(page.rows(300, 400)); page.settle(12);
  const release = page.gate(rows);
  page.evaluate("topics.debug.updateTopicFilter('one')");
  page.evaluate(`apply({type:'reset',epoch:'a',more:false,items:${JSON.stringify(rows)}})`);
  release();
  for (let turn = 0; turn < 20; turn++) { await page.settled(); page.step(16); }
  assert.equal(page.top(), page.bottom());
  assert.equal(page.evaluate('scrollMemory(scrolling).find(saved=>saved.scope.topic===\'one\')?.scope.topic'), 'one');
});

test('the first topic frame mounts the saved landing window', async () => {
  const page = await windowPage();
  page.evaluate("element('scroll').clientHeight=500; state={...state,sessionId:'s',topics:[{name:'one'}]}");
  page.open(page.rows(300, 500)); page.settle(12);
  page.evaluate("element('scroll').scrollTop=10000; decide({type:'input',direction:'up'});frame(); decide({type:'scroll'});frame(); scrolling.saved.set(JSON.stringify(['', 'one']),{scope:{view:'',sessionId:'s',topic:'one'},anchor:{item:{kind:'message',seq:100},offset:0,edge:'row'},last:199})");
  const release = page.gate(page.rows(100, 200).map(row => ({ ...row, topic: 'one' })));
  page.evaluate("topics.debug.updateTopicFilter('one')");
  release(); await page.settled(); page.step(16);
  assert.ok(page.seqs().includes(100), 'first mounted rows: ' + page.seqs().join(','));
});

test('filtered history installs 400 summary rows with a linear topic index', async () => {
  const page = await windowPage();
  page.open([], false);
  page.evaluate("topics.debug.scopeData(topics.scope()).filter='one'; globalThis.indexVisits=0; topicContext.items={get:seq=>items.get(seq),keys:function*(){for(const seq of items.keys()){globalThis.indexVisits++;yield seq}}}");
  Object.assign(page.app.context, { fetch: async () => ({ ok: true, json: async () => ({ epoch: 'a', more: false, items: Array.from({ length: 400 }, (_, seq) => ({ seq, revision: 0, at: 1, final: true, kind: 'summary', source: 'compaction', text: 'Summary ' + seq })) }) }) });
  const loaded = page.evaluate('transcriptHistory.reload()');
  for (let turn = 0; turn < 4; turn++) { await page.settled(); page.settle(4); }
  await loaded;
  assert.equal(page.evaluate('items.size'), 400);
  const visits = Number(page.evaluate('indexVisits'));
  assert.ok(visits < 4000, 'topic index visited ' + visits + ' items');
  page.evaluate("topics.debug.scopeData(topics.scope()).filter=undefined;refreshTopicItems();put({kind:'assistant',seq:500,revision:0,at:1,final:true,stop:'stop',error:'',blocks:[{type:'text',text:'Pick one?'}]})");
  page.settle(4);
  Object.assign(page.app.context, { fetch: async () => ({ ok: true, json: async () => ({ epoch: 'a', more: false, items: [{ kind: 'annotations', seq: 501, revision: 0, at: 2, final: true, reply: { seq: 500, block: 0 }, annotations: [{ type: 'question', range: [0, 9], kind: 'open' }] }] }) }) });
  const annotated = page.evaluate('transcriptHistory.reload()');
  for (let turn = 0; turn < 4; turn++) { await page.settled(); page.settle(4); }
  await annotated;
  assert.equal(page.evaluate("texts.get('500:0')?.annotationItem?.seq"), 501);
});

test('metadata-only history advances the cursor and stops requesting after the last page', async () => {
  const page = await windowPage(), requests: number[] = [];
  page.evaluate("element('scroll').clientHeight=1000");
  Object.assign(page.app.context, { fetch: async (path: string) => {
    const before = Number(path.match(/before=(\d+)/)?.[1]); requests.push(before);
    return { ok: true, json: async () => ({ epoch: 'a', more: before === 20, items: before === 20 ? [17, 18, 19].map(seq => ({ seq, revision: 0, at: 1, final: true, kind: 'topics', target: seq - 3, topics: ['general'] })) : page.rows(0, 17) }) };
  } });
  page.open(page.rows(20, 21), true);
  for (let turn = 0; turn < 8; turn++) { page.settle(4); await page.settled(); }
  const auto = [...requests];
  void page.evaluate('transcriptHistory.earlier()');
  for (let turn = 0; turn < 4; turn++) { page.settle(4); await page.settled(); }
  assert.deepEqual({ auto, afterClick: requests }, { auto: [20, 17], afterClick: [20, 17] });
});

test('topic badges refresh during rename without replacing the draft', async () => {
  const app = await page();
  const result = app.run(`(()=>{
    state={...state,sessionId:'s',topics:[{name:'one',last:{summary:'One',at:1}},{name:'two',last:{summary:'Two',at:1}}]};topics.render();
    topics.debug.renameTopic(element('topics').querySelector('.topic-panel').children.find(entry=>entry.dataset.topic==='one'),'one');
    const input=element('topics').querySelector('.topic-rename');input.value='draft';input.selectionStart=1;input.selectionEnd=3;
    scrolling={...scrolling,mode:{kind:'reader'}};
    window.koaFocused=false;const measurement={...measure(),focused:false,visible:true};
    put({seq:1,revision:0,at:1,kind:'assistant',final:false,blocks:[{type:'text',text:'One',topic:'one'},{type:'text',text:'Two',topic:'two'}]});
    scrollEvents.length=0;changedItem(1,true);frame(measurement);
    const badges=()=>element('topics').querySelectorAll('.topic-panel>.topic-entry>.topic-age>.topic-unread').length;
    const capsuleBadges=()=>element('topics').querySelectorAll('.topic-capsule>.topic-open>.topic-name>.topic-unread').length;
    const before=[badges(),capsuleBadges()];dispatch({type:'latest'},{...measurement,focused:true,reducedMotion:true});frame({...measurement,focused:true,reducedMotion:true});
    return [before,[badges(),capsuleBadges()],element('topics').querySelector('.topic-rename')===input,input.value,input.selectionStart,input.selectionEnd,element('topics').querySelectorAll('.topic-panel>.topic-entry>.topic-age>time').length];
  })()`);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [[1,2],[0,0],true,'draft',1,3,1]);
});
