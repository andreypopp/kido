import type { TestContext } from 'node:test';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { EditorState, StateEffect, StateField } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType, showTooltip, tooltips } from '@codemirror/view';
import { acceptCompletion, autocompletion, closeCompletion, completionStatus, moveCompletionSelection, pickedCompletion, selectedCompletion, startCompletion, currentCompletions } from '@codemirror/autocomplete';
import { syntaxTree } from '@codemirror/language';
import { fileToken, slashToken } from '../token.ts';
import { bashCommand } from '../prompt.ts';

export class Fake {
  className = ''; textContent = ''; nodeName = 'DIV'; id = ''; children: Fake[] = []; attributes = new Map<string, string>(); parent?: Fake; list?: Fake; onmousedown?: unknown; dataset = {};
  append(...nodes: Fake[]) { for (const node of nodes) { node.remove(); node.parent = this; this.children.push(node); } }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = undefined; }
  setAttribute(name: string, value: string) { this.attributes.set(name, value); }
  appendChild(node: Fake) { this.append(node); return node; }
  addEventListener() {}
  hasAttribute(name: string) { return this.attributes.has(name); }
  removeAttribute(name: string) { this.attributes.delete(name); }
  classList = {
    add: (name: string) => { if (!this.classList.contains(name)) this.className += ' ' + name; },
    remove: (name: string) => { this.className = this.className.split(' ').filter(value => value !== name).join(' '); },
    contains: (name: string) => this.className.split(' ').includes(name),
    toggle: (name: string, force: boolean) => { if (force) this.classList.add(name); else this.classList.remove(name); },
  };
  get firstChild() { return this.children[0]; }
  get nextSibling(): Fake | undefined { return this.parent?.children[(this.parent.children.indexOf(this) ?? -1) + 1]; }
  animate() { return {}; }
  getBoundingClientRect() { return { left: 0, right: 0, top: 0, width: 0 }; }
  get lastElementChild() { return this.children.at(-1); }
  querySelector(selector: string): Fake | undefined {
    if (selector === '.koa-complete > ul') return this.list ?? this.children.find(node => node.classList.contains('koa-complete'))?.children.find(node => node.nodeName === 'UL');
    const names = selector.slice(1).split('.');
    return this.children.find(child => names.every(name => child.className.split(' ').includes(name)));
  }
}

export async function feedbackFixture(t: TestContext, menus = false) {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const read = async (name: string) => stripTypeScriptTypes(await readFile(new URL('../' + name, import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const body = new Fake(), replies: ((value: unknown) => void)[] = [], popup = { open: false }, capture: { config?: Parameters<typeof autocompletion>[0] } = {};
  const context = {
    StateEffect, StateField, EditorState, Decoration, showTooltip, tooltips, ViewPlugin, EditorView, WidgetType, capture, currentCompletions: menus ? currentCompletions : () => popup.open ? [{}] : [], autocompletion: (config: Parameters<typeof autocompletion>[0]) => { capture.config = config; return autocompletion(config); }, acceptCompletion, closeCompletion, completionStatus, moveCompletionSelection, pickedCompletion, selectedCompletion, startCompletion, syntaxTree, fileToken, slashToken, bashCommand,
    menus,
    withDocument: (run: () => unknown) => {
      const before = Object.getOwnPropertyDescriptor(globalThis, 'document');
      Object.defineProperty(globalThis, 'document', { configurable: true, value: context.document });
      try { return run(); } finally { if (before) Object.defineProperty(globalThis, 'document', before); else Reflect.deleteProperty(globalThis, 'document'); }
    },
    document: { createElement: (tag: string) => Object.assign(new Fake(), { nodeName: tag.toUpperCase() }), createTextNode: (text: string) => Object.assign(new Fake(), { nodeName: '#text', textContent: text }), body, querySelector: () => undefined, timeline: { currentTime: 0 } },
    matchMedia: () => ({ matches: false }), window: { innerHeight: 100 }, console, AbortController, Date,
    setTimeout: (...args: Parameters<typeof setTimeout>) => setTimeout(...args), clearTimeout: (id?: Parameters<typeof clearTimeout>[0]) => clearTimeout(id),
    fetch: () => new Promise(resolve => replies.push(value => resolve({ ok: true, json: async () => value }))),
  };
  const fixture = runInNewContext(await read('page/working.ts') + await read('page/complete.ts') + `
    const host = { parentElement: { getBoundingClientRect: () => ({ left: 0, right: 0, top: 0, width: 0 }) } };
    const mode = StateField.define({ create: state => bashCommand(state.doc.toString()), update: (value, transaction) => transaction.docChanged ? bashCommand(transaction.newDoc.toString()) : value });
    const completions = completion(host, () => {}, mode);
    const plugins = [], rendered = new Map();
    const view = {
      composing: false,
      state: EditorState.create({ doc: '!ls', selection: { anchor: 3 }, extensions: [mode, completions.extension] }),
      dispatch(spec) {
        const transaction = view.state.update(spec);
        view.state = transaction.state;
        const update = { docChanged: transaction.docChanged, selectionSet: !!transaction.selection, state: view.state, startState: transaction.startState, transactions: [transaction], view };
        for (const plugin of plugins) plugin.update?.(update);
        if (menus) withDocument(() => {
          const tips = view.state.facet(showTooltip).filter(Boolean);
          for (const [create, tooltip] of rendered) if (!tips.some(tip => tip.create === create)) { tooltip.destroy?.(); tooltip.dom.remove(); rendered.delete(create); }
          for (const tip of tips) {
            let tooltip = rendered.get(tip.create);
            if (tooltip) tooltip.update?.(update);
            else { tooltip = tip.create(view); rendered.set(tip.create, tooltip); document.body.children[0].append(tooltip.dom); tooltip.mount?.(); }
          }
        });
        for (const listener of view.state.facet(EditorView.updateListener)) listener(update);
      },
    };
    for (const extension of completions.extension.flat(Infinity)) if (extension instanceof ViewPlugin && (menus || plugins.length === 0)) plugins.push(extension.create(view));
    ({
      view,
      key: name => completions.keys.find(binding => binding.key === name).run(view),
      widgets: () => view.state.facet(EditorView.decorations).flatMap(source => {
        const found = [];
        for (const cursor = (typeof source === 'function' ? source(view) : source).iter(); cursor.value; cursor.next()) { const dom = cursor.value.spec.widget.toDOM(); found.push({ from: cursor.from, side: cursor.value.spec.side, className: dom.className, label: dom.attributes.get('aria-label') }); }
        return found;
      }),
      prompt: () => { const aborts = []; capture.config.override[0]({ state: view.state, pos: view.state.doc.length, explicit: false, aborted: false, addEventListener: (type, listener) => aborts.push(listener) }); return () => aborts.forEach(listener => listener()); },
      tooltips: () => view.state.facet(showTooltip).flatMap(tooltip => { if (!tooltip) return []; const { dom } = tooltip.create(view); return [{ className: dom.className, text: dom.textContent }]; }),
    })
  `, context);
  const layer = body.children[0];
  const plain = (value: unknown) => JSON.parse(JSON.stringify(value));
  return {
    key: (name: string): unknown => fixture.key(name),
    widgets: () => plain(fixture.widgets()),
    tooltips: () => plain(fixture.tooltips()),
    dispatch: (spec: object) => fixture.view.dispatch(spec),
    prompt: (): (() => void) => fixture.prompt(), open: (value: boolean) => { popup.open = value; },
    layer, replies,
    start: () => startCompletion(fixture.view),
    selected: () => selectedCompletion(fixture.view.state)?.label,
    state: (): EditorState => fixture.view.state,
  };
}
export const settle = () => new Promise<void>(resolve => setImmediate(resolve));
export const shellReply = (options: { label: string; insert: string }[]) => ({ type: 'shell', from: 3, to: 3, options, common: '', more: 0 });

