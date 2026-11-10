import { Compartment, EditorState, Prec, Transaction, StateField } from '@codemirror/state';
import { Decoration, EditorView, drawSelection, keymap, placeholder, type Command } from '@codemirror/view';
import { history, historyKeymap, standardKeymap, insertNewline } from '@codemirror/commands';
import { markdownLanguage, insertNewlineContinueMarkup, deleteMarkupBackward } from '@codemirror/lang-markdown';
import { Language, languageDataProp, syntaxHighlighting, HighlightStyle } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { parser, GFM, Subscript, Superscript, Emoji } from '@lezer/markdown';

import { bashCommand } from '../prompt.ts';
import { completion } from './complete.ts';
import type { PromptMode } from '../koa-records.ts';

export const composerLanguage = new Language(markdownLanguage.data, parser.configure([GFM, Subscript, Superscript, Emoji, {
  props: [languageDataProp.add({ Document: markdownLanguage.data })],
  parseBlock: [{
    name: 'QuoteAnswer',
    endLeaf: (context, line) => context.parentType().name === 'Blockquote' && !/^ {0,3}>/.test(line.text),
  }],
}]), [], 'markdown');

const outsideComposition = (command: Command): Command => view => !view.compositionStarted && command(view);

export function composer(host: HTMLElement, handlers: { input(user: boolean): void; send(mode: PromptMode): void; quit(): void; drop(event: DragEvent): boolean; paste(event: ClipboardEvent): boolean }) {
  const hint = new Compartment(), language = new Compartment();
  let label = 'Message koa…', running = false;
  const mode = StateField.define<ReturnType<typeof bashCommand>>({
    create: () => undefined,
    update(value, transaction) { return !transaction.docChanged ? value : transaction.newDoc.sliceString(0, 1) === '!' ? bashCommand(transaction.newDoc.toString()) : undefined; },
  });
  const completions = completion(host, () => handlers.send('prompt'), mode);
  const refreshMode = () => host.parentElement?.classList.toggle('bash-mode', !!view.state.field(mode) || running && empty());
  const empty = () => view.state.doc.length === 0;
  const view = new EditorView({
    parent: host,
    extensions: [
      history(),
      EditorView.domEventHandlers({ drop: event => handlers.drop(event), paste: event => handlers.paste(event) }),
      language.of(composerLanguage),
      EditorState.transactionExtender.of(transaction => {
        if (!transaction.docChanged) return null;
        const before = !!transaction.startState.field(mode), after = !!transaction.state.field(mode);
        return before === after ? null : { effects: language.reconfigure(after ? [] : composerLanguage) };
      }),
      mode,
      EditorView.decorations.compute([mode], state => {
        const bang = state.field(mode);
        return bang ? Decoration.set([Decoration.mark({ class: 'cm-bang' + (bang.excludeFromContext ? ' quiet' : '') }).range(0, bang.prefixLength)]) : Decoration.none;
      }),
      syntaxHighlighting(HighlightStyle.define([
        { tag: [tags.processingInstruction, tags.meta, tags.url, tags.atom], class: 'cm-markup' },
        { tag: [tags.strong, tags.heading], class: 'cm-strong' },
        { tag: tags.emphasis, class: 'cm-emphasis' },
        { tag: tags.quote, class: 'cm-quote' },
        { tag: tags.strikethrough, class: 'cm-strikethrough' },
        { tag: tags.monospace, class: 'cm-monospace' },
        { tag: tags.labelName, class: 'cm-markup cm-monospace' },
      ])),
      completions.extension,
      keymap.of([...historyKeymap, ...standardKeymap.filter(binding => binding.key !== 'Enter')]),
      Prec.highest(keymap.of([
        ...completions.keys.map(binding => ({ ...binding, run: outsideComposition(binding.run) })),
        { key: 'Enter', run: outsideComposition(() => { handlers.send('prompt'); return true; }) },
        { key: 'Shift-Enter', run: outsideComposition(view => !view.state.field(mode) && insertNewlineContinueMarkup(view)) },
        { key: 'Shift-Enter', run: outsideComposition(insertNewline) },
        { key: 'Backspace', run: outsideComposition(view => !view.state.field(mode) && deleteMarkupBackward(view)) },
        { key: 'Alt-Enter', run: outsideComposition(() => { handlers.send('follow_up'); return true; }) },
        { key: 'Ctrl-d', run: () => { if (!empty()) return false; handlers.quit(); return true; } },
      ])),
      EditorView.lineWrapping,
      drawSelection(),
      EditorView.contentAttributes.of({ 'aria-label': 'Message koa' }),
      hint.of(placeholder(label)),
      EditorView.updateListener.of(update => { if (update.docChanged) { refreshMode(); handlers.input(update.transactions.some(transaction => transaction.annotation(Transaction.userEvent) !== undefined)); } }),
    ],
  });
  return {
    empty,
    bash: () => view.state.field(mode),
    running(value: boolean) { running = value; refreshMode(); },
    text: () => view.state.doc.toString(),
    setText(text: string) { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: text.length }, scrollIntoView: true }); },
    insert(text: string) { view.dispatch(view.state.replaceSelection(text), { scrollIntoView: true, userEvent: 'input.type' }); },
    focus: () => view.focus(),
    hasFocus: () => view.hasFocus,
    placeholder(text: string) { if (text !== label) { label = text; view.dispatch({ effects: hint.reconfigure(placeholder(text)) }); } },
  };
}
