import { autocompletion, acceptCompletion, closeCompletion, completionStatus, moveCompletionSelection, pickedCompletion, selectedCompletion, type Completion, type CompletionContext } from '@codemirror/autocomplete';
import { tooltips, type Command } from '@codemirror/view';
import { syntaxTree } from '@codemirror/language';
import { fileToken, slashToken } from '../../pi/token.ts';
import type { CompletionOption, CompletionResult, CompletionQuery } from '../records.ts';

export function completion(host: HTMLElement, send: () => void) {
  const field = host.parentElement;
  if (!field) throw new Error('The composer host must have a parent');
  const options = new WeakMap<Completion, CompletionOption>();
  const active = (command: Command): Command => view => completionStatus(view.state) === 'active' && command(view);
  const source = async (context: CompletionContext) => {
    for (let node: ReturnType<typeof syntaxTree>['topNode'] | null = syntaxTree(context.state).resolveInner(context.pos, -1); node; node = node.parent) {
      if (node.name === 'InlineCode' || node.name === 'FencedCode' || node.name === 'CodeBlock') return null;
    }
    const line = context.state.doc.lineAt(context.pos), before = line.text.slice(0, context.pos - line.from);
    if (fileToken(before) === undefined && slashToken(context.state.doc.toString(), context.pos) === undefined) return null;
    const controller = new AbortController();
    context.addEventListener('abort', () => controller.abort(), { onDocChange: true });
    try {
      const response = await fetch('/complete', { method: 'POST', body: JSON.stringify({ text: context.state.doc.toString(), pos: context.pos } satisfies CompletionQuery), signal: controller.signal });
      if (!response.ok || context.aborted) return null;
      const result: CompletionResult = await response.json();
      if (!result.options.length || context.aborted) return null;
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
    extension: [
      tooltips({ position: 'absolute', parent: field, tooltipSpace() {
        const bounds = field.getBoundingClientRect();
        return { left: bounds.left + 9, right: bounds.right + 9, top: 0, bottom: window.innerHeight };
      } }),
      autocompletion({ override: [source], defaultKeymap: false, icons: false, aboveCursor: true, activateOnTypingDelay: 20, interactionDelay: 0, maxRenderedOptions: 20, tooltipClass: () => 'koa-complete', optionClass: completion => { const item = options.get(completion); return item ? 'cm-completion-' + item.kind : ''; }, addToOptions: [{ position: 90, render(completion) {
        const item = options.get(completion);
        if (!item || (item.kind !== 'command' && item.kind !== 'agent')) return null;
        const tag = document.createElement('span');
        tag.className = 'cm-completionKind';
        tag.textContent = item.kind === 'command' ? item.source === 'prompt' ? 'template' : item.source : item.kind === 'agent' ? 'agent' : '';
        return tag;
      } }] }),
    ],
    keys: [
      { key: 'ArrowDown', run: active(moveCompletionSelection(true)) },
      { key: 'ArrowUp', run: active(moveCompletionSelection(false)) },
      { key: 'Tab', run: active(acceptCompletion) },
      { key: 'Enter', run: active(view => { const selected = selectedCompletion(view.state); if (!selected || !acceptCompletion(view)) return false; if (options.get(selected)?.kind === 'command') send(); return true; }) },
      { key: 'Escape', run: closeCompletion },
    ],
  };
}
