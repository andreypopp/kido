import { Compartment, EditorState, Prec, Transaction, StateField } from '@codemirror/state';
import { Decoration, EditorView, drawSelection, keymap, placeholder, type Command } from '@codemirror/view';
import { history, historyKeymap, standardKeymap, insertNewline } from '@codemirror/commands';
import { markdownLanguage, insertNewlineContinueMarkup, deleteMarkupBackward } from '@codemirror/lang-markdown';
import { Language, languageDataProp, syntaxHighlighting, HighlightStyle } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { parser, GFM, Subscript, Superscript, Emoji } from '@lezer/markdown';

import { bashCommand } from '../prompt.ts';
import { completion } from './complete.ts';
import { promptHistory } from './history.ts';
import type { PromptMode } from '../koa-records.ts';

export const composerLanguage = new Language(markdownLanguage.data, parser.configure([GFM, Subscript, Superscript, Emoji, {
  props: [languageDataProp.add({ Document: markdownLanguage.data })],
  parseBlock: [{
    name: 'QuoteAnswer',
    endLeaf: (context, line) => context.parentType().name === 'Blockquote' && !/^ {0,3}>/.test(line.text),
  }],
}]), [], 'markdown');

const outsideComposition = (command: Command): Command => view => !view.compositionStarted && command(view);

export function composer(host: HTMLElement, handlers: { input(user: boolean): void; send(mode: PromptMode): void; quit(): void; edit(): void; takeBack(): void; drop(event: DragEvent): boolean; paste(event: ClipboardEvent): boolean }) {
  const hint = new Compartment(), language = new Compartment(), locked = new Compartment();
  let label = 'Message koa…', running = false;
  const mode = StateField.define<ReturnType<typeof bashCommand>>({
    create: () => undefined,
    update(value, transaction) { return !transaction.docChanged ? value : transaction.newDoc.sliceString(0, 1) === '!' ? bashCommand(transaction.newDoc.toString()) : undefined; },
  });
  const completions = completion(host, () => handlers.send('prompt'), mode, () => handlers.input(false));
  const refreshMode = () => host.parentElement?.classList.toggle('bash-mode', !!view.state.field(mode) || running && empty());
  const empty = () => view.state.doc.length === 0;
  const prompts = promptHistory(async () => {
    const response = await fetch('/history');
    if (!response.ok) throw Error('Could not load prompt history');
    const value: unknown = await response.json();
    if (typeof value !== 'object' || value === null || !('entries' in value) || !Array.isArray(value.entries) || !value.entries.every(entry => typeof entry === 'string')) throw Error('Invalid prompt history');
    return value.entries;
  });
  let recalling = false;
  const navigate = (direction: -1 | 1): boolean => {
    const selection = view.state.selection.main;
    if (!selection.empty) return false;
    const visual = view.moveToLineBoundary(selection, direction === 1, true);
    const boundary = direction === -1 ? visual.head === 0 : visual.head === view.state.doc.length;
    if (!boundary) return false;
    const line = view.state.doc.lineAt(selection.head);
    if (direction === -1 ? !prompts.active && !empty() && selection.head !== line.from : !prompts.active) {
      view.dispatch({ selection: { anchor: direction === -1 ? line.from : line.to } });
      return true;
    }
    void prompts.move(direction, { text: view.state.doc.toString(), anchor: selection.anchor, head: selection.head }).then(value => {
      if (!value) return;
      recalling = true;
      try { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: value.text }, selection: { anchor: value.anchor, head: value.head }, scrollIntoView: true }); }
      finally { recalling = false; }
    }).catch(error => { console.error(error); });
    return true;
  };
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
        { key: 'ArrowUp', run: outsideComposition(() => navigate(-1)) },
        { key: 'ArrowDown', run: outsideComposition(() => navigate(1)) },
        { key: 'Alt-ArrowUp', run: outsideComposition(() => { handlers.takeBack(); return true; }) },
        { key: 'Enter', run: outsideComposition(() => { handlers.send('prompt'); return true; }) },
        { key: 'Shift-Enter', run: outsideComposition(view => !view.state.field(mode) && insertNewlineContinueMarkup(view)) },
        { key: 'Shift-Enter', run: outsideComposition(insertNewline) },
        { key: 'Backspace', run: outsideComposition(view => !view.state.field(mode) && deleteMarkupBackward(view)) },
        { key: 'Alt-Enter', run: outsideComposition(() => { handlers.send('follow_up'); return true; }) },
        { key: 'Ctrl-g', run: () => { handlers.edit(); return true; } },
        { key: 'Ctrl-d', run: () => { if (!empty()) return false; handlers.quit(); return true; } },
      ])),
      EditorView.lineWrapping,
      drawSelection(),
      EditorView.contentAttributes.of({ 'aria-label': 'Message koa' }),
      hint.of(placeholder(label)),
      locked.of(EditorState.readOnly.of(false)),
      EditorView.updateListener.of(update => { if (update.docChanged) { refreshMode(); if (!recalling) prompts.reset(); handlers.input(update.transactions.some(transaction => transaction.annotation(Transaction.userEvent) !== undefined)); } }),
    ],
  });
  return {
    empty,
    completionStatus: completions.status,
    resetCompletion: completions.reset,
    bash: () => view.state.field(mode),
    running(value: boolean) { running = value; refreshMode(); },
    text: () => view.state.doc.toString(),
    setText(text: string) { prompts.reset(); view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: text.length }, scrollIntoView: true }); },
    insert(text: string) { view.dispatch(view.state.replaceSelection(text), { scrollIntoView: true, userEvent: 'input.type' }); },
    readonly(value: boolean) { if (value !== view.state.readOnly) view.dispatch({ effects: locked.reconfigure(EditorState.readOnly.of(value)) }); },
    focus: () => view.focus(),
    hasFocus: () => view.hasFocus,
    placeholder(text: string) { if (text !== label) { label = text; view.dispatch({ effects: hint.reconfigure(placeholder(text)) }); } },
  };
}
