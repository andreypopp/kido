import { Compartment, Prec, Transaction } from '@codemirror/state';
import { EditorView, keymap, placeholder, type Command } from '@codemirror/view';
import { history, historyKeymap, standardKeymap, insertNewline } from '@codemirror/commands';

import type { PromptMode } from '../records.ts';

const outsideComposition = (command: Command): Command => view => !view.compositionStarted && command(view);

export function composer(host: HTMLElement, handlers: { input(user: boolean): void; send(mode: PromptMode): void; quit(): void }) {
  const hint = new Compartment();
  let label = 'Message koa…';
  const empty = () => view.state.doc.length === 0;
  const view = new EditorView({
    parent: host,
    extensions: [
      history(),
      keymap.of([...historyKeymap, ...standardKeymap.filter(binding => binding.key !== 'Enter')]),
      Prec.highest(keymap.of([
        { key: 'Enter', run: outsideComposition(() => { handlers.send('prompt'); return true; }) },
        { key: 'Shift-Enter', run: outsideComposition(insertNewline) },
        { key: 'Alt-Enter', run: outsideComposition(() => { handlers.send('follow_up'); return true; }) },
        { key: 'Ctrl-d', run: () => { if (!empty()) return false; handlers.quit(); return true; } },
      ])),
      EditorView.lineWrapping,
      EditorView.contentAttributes.of({ 'aria-label': 'Message koa' }),
      hint.of(placeholder(label)),
      EditorView.updateListener.of(update => { if (update.docChanged) handlers.input(update.transactions.some(transaction => transaction.annotation(Transaction.userEvent) !== undefined)); }),
    ],
  });
  return {
    empty,
    text: () => view.state.doc.toString(),
    setText(text: string) { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: text.length }, scrollIntoView: true }); },
    insert(text: string) { view.dispatch(view.state.replaceSelection(text), { scrollIntoView: true, userEvent: 'input.type' }); },
    focus: () => view.focus(),
    hasFocus: () => view.hasFocus,
    placeholder(text: string) { if (text !== label) { label = text; view.dispatch({ effects: hint.reconfigure(placeholder(text)) }); } },
  };
}
