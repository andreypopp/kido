import type { StateField } from '@codemirror/state';
import { bashCommand } from '../prompt.ts';
import { autocompletion, acceptCompletion, closeCompletion, completionStatus, moveCompletionSelection, pickedCompletion, selectedCompletion, startCompletion, type Completion, type CompletionContext } from '@codemirror/autocomplete';
import { tooltips, ViewPlugin, EditorView, type Command } from '@codemirror/view';
import { syntaxTree } from '@codemirror/language';
import { fileToken, slashToken } from '../token.ts';
import type { CompletionOption, CompletionResult, ShellCompletion, CompletionQuery } from '../koa-records.ts';

export function completion(host: HTMLElement, send: () => void, mode: StateField<ReturnType<typeof bashCommand>>, changed: () => void) {
  const field = host.parentElement;
  if (!field) throw new Error('The composer host must have a parent');
  const layer = document.createElement('div');
  layer.className = 'completion-layer';
  const options = new WeakMap<Completion, CompletionOption>();
  const active = (command: Command): Command => view => completionStatus(view.state) === 'active' && command(view);
  let editor: EditorView | undefined;
  const query = async (text: string, pos: number, signal: AbortSignal): Promise<CompletionResult | undefined> => {
    const response = await fetch('/complete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionId: document.body.dataset.sessionId || undefined, ...({ text, pos } satisfies CompletionQuery) }), signal });
    return response.ok ? response.json() : undefined;
  };
  let shell: { type: 'idle' } | { type: 'pending'; controller: AbortController } | { type: 'none' } | { type: 'list'; result: ShellCompletion; to: number } = { type: 'idle' };
  let pendingTimer: ReturnType<typeof setTimeout> | undefined, noneTimer: ReturnType<typeof setTimeout> | undefined;
  let pendingVisible = false, applying = false;
  const reset = () => { if (shell.type === 'pending') shell.controller.abort(); clearTimeout(pendingTimer); clearTimeout(noneTimer); pendingVisible = false; shell = { type: 'idle' }; if (editor) closeCompletion(editor); changed(); };
  const shellTab: Command = view => {
    if (!view.state.field(mode)) return false;
    if (shell.type === 'pending') return true;
    if (shell.type === 'list' && completionStatus(view.state) === 'active') return moveCompletionSelection(true)(view);
    reset();
    const controller = new AbortController(), doc = view.state.doc, pos = view.state.selection.main.head;
    shell = { type: 'pending', controller };
    pendingTimer = setTimeout(() => { pendingVisible = true; changed(); }, 150);
    void (async () => {
      try {
        const result = await query(doc.toString(), pos, controller.signal);
        if (controller.signal.aborted || view.state.doc !== doc || view.state.selection.main.head !== pos) return;
        if (result?.type !== 'shell') { reset(); return; }
        clearTimeout(pendingTimer); pendingVisible = false;
        if (!result.options.length) { shell = { type: 'none' }; changed(); noneTimer = setTimeout(reset, 1500); return; }
        applying = true;
        try {
          if (result.options.length === 1 && !result.more) {
            const item = result.options[0];
            view.dispatch({ changes: { from: result.from, to: result.to, insert: item.insert }, selection: { anchor: result.from + item.insert.length }, userEvent: 'input.complete' });
            reset(); return;
          }
          const current = view.state.doc.sliceString(result.from, pos);
          let to = result.to;
          if (result.common.length > current.length) {
            view.dispatch({ changes: { from: result.from, to: result.to, insert: result.common }, selection: { anchor: result.from + result.common.length }, userEvent: 'input.complete' });
            to = result.from + result.common.length;
          }
          shell = { type: 'list', result, to }; startCompletion(view); changed();
        } finally { applying = false; }
      } catch (error) { if (!controller.signal.aborted) { reset(); console.error(error); } }
    })();
    return true;
  };
  const source = async (context: CompletionContext) => {
    const bang = context.state.field(mode), text = context.state.doc.toString();
    if (bang) {
      if (shell.type !== 'list' || !context.explicit) return null;
      const result = shell.result;
      return { from: result.from, to: shell.to, filter: false, options: result.options.map(item => ({ label: item.label, apply(view, completion, from, to) {
        applying = true;
        try { view.dispatch({ changes: { from, to, insert: item.insert }, selection: { anchor: from + item.insert.length }, annotations: pickedCompletion.of(completion), userEvent: 'input.complete' }); reset(); }
        finally { applying = false; }
      } } satisfies Completion)) };
    }
    for (let node: ReturnType<typeof syntaxTree>['topNode'] | null = syntaxTree(context.state).resolveInner(context.pos, -1); node; node = node.parent) {
      if (node.name === 'InlineCode' || node.name === 'FencedCode' || node.name === 'CodeBlock') return null;
    }
    const line = context.state.doc.lineAt(context.pos), before = line.text.slice(0, context.pos - line.from);
    if (!bang && fileToken(before) === undefined && slashToken(text, context.pos) === undefined) return null;
    const controller = new AbortController();
    context.addEventListener('abort', () => controller.abort(), { onDocChange: true });
    try {
      const result = await query(text, context.pos, controller.signal);
      if (result?.type !== 'prompt' || !result.options.length || context.aborted) return null;
      return {
        from: result.from, to: result.to, filter: false,
        options: result.options.map(item => {
          const completion: Completion = { label: item.label, detail: item.detail, displayLabel: item.kind === 'directory' ? item.label.slice(0, -1) : item.label, apply(view, completion, from, to) {
            view.dispatch({ changes: { from, to, insert: item.insert }, selection: { anchor: from + (item.cursor ?? item.insert.length) }, annotations: pickedCompletion.of(completion), userEvent: 'input.complete', scrollIntoView: true });
          } };
          options.set(completion, item);
          return completion;
        }),
        getMatch(completion: Completion) {
          const item = options.get(completion);
          if (!item || (item.kind !== 'command' && item.kind !== 'agent')) return [];
          const ranges: number[] = [];
          for (const index of item.matched) { if (ranges.at(-1) === index) ranges[ranges.length - 1] = index + 1; else ranges.push(index, index + 1); }
          return ranges;
        },
      };
    } catch (error) { if (!controller.signal.aborted) console.error(error); return null; }
  };
  return {
    status: () => shell.type === 'none' ? 'none' : pendingVisible ? 'pending' : 'idle',
    reset,
    extension: [
      ViewPlugin.define(view => {
        editor = view; document.body.append(layer);
        return { destroy() { editor = undefined; reset(); layer.remove(); } };
      }),
      EditorView.updateListener.of(update => {
        if (!applying && shell.type !== 'idle' && (update.docChanged || update.selectionSet)) reset();
        if (shell.type !== 'list' || !shell.result.more) return;
        const tooltip = layer.querySelector('.koa-complete');
        if (!tooltip || tooltip.querySelector('.row.more')) return;
        const more = document.createElement('div');
        more.className = 'row more'; more.textContent = `… ${shell.result.more} more, type to narrow`;
        more.setAttribute('role', 'presentation'); more.onmousedown = event => event.preventDefault();
        tooltip.querySelector('ul')?.append(more);
      }),
      tooltips({ position: 'absolute', parent: layer, tooltipSpace() {
        const bounds = field.getBoundingClientRect();
        const top = Math.min(bounds.top, document.querySelector('#dock')?.getBoundingClientRect().top ?? bounds.top);
        layer.style.setProperty('--complete-top', `${top}px`);
        layer.style.setProperty('--complete-left', `${bounds.left + 12}px`);
        layer.style.setProperty('--complete-width', `${bounds.width}px`);
        return { left: bounds.left + 9, right: bounds.right + 9, top: 0, bottom: window.innerHeight };
      } }),
      autocompletion({ override: [source], defaultKeymap: false, icons: false, aboveCursor: true, activateOnTypingDelay: 20, interactionDelay: 0, maxRenderedOptions: 200, tooltipClass: () => 'koa-complete' + (shell.type === 'list' ? ' sh' : ''), optionClass: completion => { const item = options.get(completion); return item ? 'cm-completion-' + item.kind : ''; }, addToOptions: [{ position: 90, render(completion) {
        const item = options.get(completion);
        if (!item || (item.kind !== 'command' && item.kind !== 'agent')) return null;
        const tag = document.createElement('span');
        tag.className = 'cm-completionKind';
        tag.textContent = item.kind === 'command' ? item.source === 'prompt' ? 'template' : item.source === 'builtin' ? 'built-in' : item.source : item.kind === 'agent' ? 'agent' : '';
        return tag;
      } }] }),
    ],
    keys: [
      { key: 'ArrowDown', run: active(moveCompletionSelection(true)) },
      { key: 'ArrowUp', run: active(moveCompletionSelection(false)) },
      { key: 'Tab', run: (view: EditorView) => { if (view.state.field(mode)) shellTab(view); else active(acceptCompletion)(view); return true; } },
      { key: 'Shift-Tab', run: () => true },
      { key: 'Enter', run: active(view => { const selected = selectedCompletion(view.state); if (!selected || !acceptCompletion(view)) return false; if (options.get(selected)?.kind === 'command') send(); return true; }) },
      { key: 'Escape', run: (view: EditorView) => { const open = shell.type !== 'idle' || completionStatus(view.state) !== null; reset(); return open; } },
    ],
  };
}
