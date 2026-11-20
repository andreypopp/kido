import assert from "node:assert/strict";
import { test, type TestContext } from "node:test";
import { readFile } from "node:fs/promises";
import { Script, runInNewContext } from "node:vm";
import { Lexer, Marked } from "marked";
import remend from "remend";

import { assemblePage } from "./koa-assemble.ts";
import { markdown, type Mark } from "./page/markdown.ts";
import { markdownLine } from "./markdown-line.ts";
import { revealHeight, type Unit } from "./page/reveal.ts";
import { estimateExtent, windowOf, runOwner, invalidateRuns, type RunContext } from "./page/extent.ts";
import type { Block, WireItem } from "./koa-records.ts";
import type { JobRef } from "./records.ts";
import { answer, current, quote } from "./page/answers.ts";
import { composerLanguage } from "./page/composer.ts";
import { highlightTree, tags } from '@lezer/highlight';
import { EditorState, StateEffect, StateField } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType, showTooltip, tooltips } from '@codemirror/view';
import { acceptCompletion, autocompletion, closeCompletion, completionStatus, moveCompletionSelection, pickedCompletion, selectedCompletion, startCompletion } from '@codemirror/autocomplete';
import { fileToken, slashToken } from './token.ts';
import { stripTypeScriptTypes } from 'node:module';
import { bashCommand } from './prompt.ts';
import { HighlightStyle, syntaxTree } from '@codemirror/language';

test('Markdown previews strip first-line syntax and use the first fenced code line', () => {
  for (const [source, expected] of [
    ['**bold**', 'bold'],
    ['`code`', 'code'],
    ['[link](https://example.com)', 'link'],
    ['# Heading', 'Heading'],
    ['- Bullet', 'Bullet'],
    ['> Quote', 'Quote'],
    ['2) Numbered', 'Numbered'],
    ['## **Ready** with `code`, _emphasis_ and ~~old~~ [link](https://example.com).\nNot shown', 'Ready with code, emphasis and old link.'],
    ['> - [ ] Review ![the image](https://example.com/image.png)  now', 'Review the image now'],
    ['1. __First__\r\nSecond', 'First'],
    ['```ts\nconst x = a * b;\n```', 'const x = a * b;'],
    ['_x_ __bold__ snake_case file_name.ts `a*b` and `file_name.ts`', 'x bold snake_case file_name.ts a*b and file_name.ts'],
    ['[nested](https://example.com/a_(b)) and [reference][id]\n\n[id]: https://example.com', 'nested and reference'],
    ['~~~\n  first   code line\n~~~', 'first code line'],
    ['```ts', ''],
    ['```inline```', 'inline'],
    ['```\n```', ''],
    ['>foo', 'foo'],
    ['>> foo', 'foo'],
    ['> > foo', 'foo'],
    ['', ''],
  ]) assert.equal(markdownLine(source), expected);
});

test('question answers follow the TUI quote, append, replace and empty-answer rules', () => {
  let overlapping = answer('', 'First\nSecond', 'long answer', false);
  overlapping = answer(overlapping, 'First', 'one', false);
  overlapping = answer(overlapping, 'First', 'two', false);
  assert.equal(overlapping, '> First\n> Second\nlong answer\n\n> First\ntwo');
  assert.equal(current(overlapping, 'First'), 'two');
  const database = quote('Which database should we use: **PostgreSQL**, SQLite or MySQL?');
  const migration = 'Should I continue with the migration?';
  let text = answer('', database, 'SQLite', false);
  assert.equal(text, '> Which database should we use: PostgreSQL, SQLite or MySQL?\nSQLite');
  text = answer(text, migration, 'Yes', false);
  assert.equal(text, '> Which database should we use: PostgreSQL, SQLite or MySQL?\nSQLite\n\n> Should I continue with the migration?\nYes');
  text = answer(text, migration, 'No', false);
  assert.equal(text, '> Which database should we use: PostgreSQL, SQLite or MySQL?\nSQLite\n\n> Should I continue with the migration?\nNo');
  assert.equal(answer(text, database, 'MySQL', false), '> Which database should we use: PostgreSQL, SQLite or MySQL?\nMySQL\n\n> Should I continue with the migration?\nNo');
  assert.equal(answer(text, migration, '', true), '> Which database should we use: PostgreSQL, SQLite or MySQL?\nSQLite\n\n> Should I continue with the migration?\n');
  assert.equal(current('> Shorter\nold', 'Short'), undefined);
  assert.equal(current('> First\n> Second\nedited\nanswer', 'First\nSecond'), 'edited\nanswer');
  assert.equal(answer('> Short\nold\nanswer\n\n> Next\nyes', 'Short', 'new', false), '> Short\nnew\n\n> Next\nyes');
  assert.equal(current('> Short\n> More\nold', 'Short'), undefined);
  assert.equal(current('> Short\nuser edit\nsecond line', 'Short'), 'user edit\nsecond line');
  assert.equal(answer('> Short\nuser edit\nsecond line', 'Short', 'new', true), '> Short\nnew');
  const open = 'What should the new service be called?';
  const empty = answer('', open, '', false);
  assert.equal(empty, '> What should the new service be called?\n');
  assert.equal(answer(empty + 'Food', open, '', false), empty + 'Food');
  assert.equal(quote('  Is dropping the `cache` **acceptable**, or is it too risky?\n\n  2. __Plan__: Is there a [plan](https://example.com) to ship the ~~docs~~ next week?  '), 'Is dropping the cache acceptable, or is it too risky?\n2. Plan: Is there a plan to ship the docs next week?');
  assert.equal(answer('draft', open, '', false), 'draft\n\n' + empty);
  assert.equal(current('not a boundary ' + empty + 'old', open), undefined);
  assert.equal(current(empty + 'Food', open), 'Food');
  assert.equal(current(empty, open), '');
  assert.equal(current('draft\n\n' + empty + 'Food\n\n> Next\nYes', open), 'Food');
  assert.equal(answer('not a boundary ' + empty + 'old', open, 'new', false), 'not a boundary ' + empty + 'old\n\n' + empty + 'new');
});

const full = (source: string, final = false) => {
  const parser = new Marked();
  parser.use({ renderer: { link(token) { return /^(https?:\/\/[^/\s]+|mailto:.+)/.test(token.href) ? false : parser.Parser.parseInline(token.tokens, parser.defaults); } } });
  const tokens = parser.lexer(source);
  const tail = tokens.at(-1);
  if (!final && tail) tokens.splice(-1, 1, ...parser.lexer(remend(tail.raw)));
  return parser.parser(tokens);
};

test("page assembly inlines the built document, style and module once", async () => {
  const location = new URL("../build/koa/share/koa/koa/koa.ts", import.meta.url);
  const page = (await assemblePage(location, "instance")).replace(/<meta name="koa-instance"[^>]*>/, "");
  assert.equal(page.match(/<script type="module">/g)?.length, 1);
  const [document, style, bundle] = await Promise.all(["page.html", "page.css", "page.js"].map(name => readFile(new URL(name, location), "utf8")));
  for (const part of document.split(/<!-- (?:style|script) -->/)) assert.equal(page.split(part).length - 1, 1);
  assert.equal(page.split(style).length - 1, 1);
  assert.equal(page.split(bundle.replace(/<\/script/gi, "<\\/script")).length - 1, 1);
  const script = page.split('<script type="module">')[1]?.split('</script>')[0] ?? "";
  assert.doesNotMatch(script, /\bimport\s|\bexport\s/);
  new Script(script);
});

test("incremental markdown matches a fresh render after each patch and preserves finished blocks", () => {
  for (const source of fixtures.slice(0, 4)) {
    const update = markdown();
    for (let end = 1; end <= source.length; end++) {
      const part = source.slice(0, end);
      assert.equal(update(part).map(block => block.html).join(''), full(part), part);
    }
    assert.equal(update(source, true).map(block => block.html).join(''), full(source, true));
  }
  const update = markdown();
  const first = update('Finished.\n\nTail');
  assert.equal(update('Finished.\n\nTail grows')[0], first[0]);
  const edited = 'Edited **earlier**.\n\nTail grows';
  assert.equal(update(edited).map(block => block.html).join(''), full(edited));
});

test("an earlier edit regenerates consumed HTML in later blocks", () => {
  const update = markdown();
  const first = update('First.\n\nKept.\n\nTail');
  for (const block of first) if (!block.streaming) delete block.html;
  const edited = 'Changed.\n\nKept.\n\nTail';
  assert.equal(update(edited).map(block => block.html).join(''), full(edited));
});

test("finished markdown blocks do not retain slices of earlier message versions", () => {
  const update = markdown();
  const first = update('Finished paragraph.\n\nTail');
  delete first[0].html;
  for (let length = 1; length <= 50; length++) {
    const blocks = update('Finished paragraph.\n\n' + 'tail '.repeat(length));
    assert.equal(blocks[0], first[0]);
    assert.deepEqual(Object.keys(blocks[0]), ['streaming', 'marks']);
  }
});

test('markdown marks use source UTF-16 offsets, token boundaries, CRLF and safe literal sentinels', () => {
  const render = markdown(), source = '😀 Choose `one`?\n\n- Pick **two**?\n\nTail';
  const first = render(source, true);
  const marks: Mark[] = [
    { offset: source.indexOf('`'), side: 'open', mark: '\uE0100\uE010' },
    { offset: source.indexOf('`?') + 1, side: 'close', mark: '\uE011' },
    { offset: source.indexOf('**'), side: 'open', mark: '\uE0101\uE010' },
    { offset: source.indexOf('**?') + 2, side: 'close', mark: '\uE011' },
    { offset: source.indexOf('Tail'), side: 'open', mark: '\uE0102\uE010' },
    { offset: source.indexOf('**?') + 3, side: 'close', mark: '\uE0121\uE012' },
  ];
  const next = render(source, true, marks), html = next.map(block => block.html).join('');
  assert.match(html, /😀 Choose \uE0100\uE010<code>one<\/code>\uE011/);
  assert.match(html, /<li>Pick \uE0101\uE010<strong>two<\/strong>\uE011/);
  assert.match(html, /<p>\uE0102\uE010Tail<\/p>/);
  assert.match(html, /two<\/strong>\uE011\?\uE0121\uE012<\/li>/);
  assert.notEqual(next[1], first[1]);
  assert.deepEqual(render(source, true, marks), next);
  const reference = 'Use [one][id]?\n\n[id]: https://example.com';
  const linked = markdown()(reference, true, [{ offset: 4, side: 'open', mark: '\uE0100\uE010' }, { offset: 13, side: 'close', mark: '\uE011' }]);
  assert.match(linked.map(block => block.html).join(''), /<a href="https:\/\/example.com">one<\/a>/);
  const crlf = 'First.\r\n\r\nPick one?';
  const normalized = markdown()(crlf, true, [
    { offset: crlf.indexOf('one'), side: 'open', mark: '\uE0100\uE010' },
    { offset: crlf.indexOf('?'), side: 'close', mark: '\uE011' },
    { offset: crlf.length, side: 'close', mark: '\uE0120\uE012' },
  ]).map(block => block.html).join('');
  assert.equal(normalized, '<p>First.</p>\n<p>Pick \uE0100\uE010one\uE011?\uE0120\uE012</p>\n');
  assert.equal(markdown()('Literal \uE012999;x\uE012 and \uE0100;x\uE010 forged\uE011.', true).map(block => block.html).join(''), '<p>Literal �999;x� and �0;x� forged�.</p>\n');
});

test("streaming tails heal emphasis, inline code, links and fences; raw HTML stays text", () => {
  const render = (source: string, final = false) => markdown()(source, final).map(block => block.html).join('');
  assert.match(render('**bold'), /<strong>bold<\/strong>/);
  assert.match(render('`code'), /<code>code<\/code>/);
  assert.doesNotMatch(render('[link]('), /\[link\]\(/);
  assert.match(render('```js\nconst x'), /<pre><code class="language-js">const x/);
  assert.match(render('<script>alert(1)</script>', true), /&lt;script&gt;/);
  assert.match(render('hello <img src=x onerror=alert(1)>', true), /&lt;img/);
  assert.doesNotMatch(render('[bad](javascript:alert%281%29)', true), /href=/);
  assert.match(render('[good](https://example.com)', true), /href="https:\/\/example.com"/);
  assert.doesNotMatch(render('[relative](/queue/clear)', true), /href=/);
});

test('composer answers have no quote highlighting', () => {
  const text = '> q\nanswer\nsecond line\n\n> next\nYes', spans: [number, number, string][] = [];
  highlightTree(composerLanguage.parser.parse(text), HighlightStyle.define([{ tag: tags.quote, class: 'cm-quote' }]), (from, to, classes) => spans.push([from, to, classes]));
  assert.ok(spans.some(([from, to, classes]) => from <= 2 && to > 2 && classes.includes('cm-quote')));
  for (const at of [4, 11, text.lastIndexOf('Yes')]) assert.ok(!spans.some(([from, to, classes]) => from <= at && to > at && classes.includes('cm-quote')), JSON.stringify(spans));
});

test('user quotes end before answers; assistant quotes keep lazy continuation', () => {
  const render = (user: boolean, source = '> q\nanswer') => markdown(user)(source, true).map(block => block.html).join('');
  assert.equal(render(true), '<blockquote>\n<p>q</p>\n</blockquote>\n<p>answer</p>\n');
  assert.equal(render(false), '<blockquote>\n<p>q\nanswer</p>\n</blockquote>\n');
  assert.equal(render(true, '> q\n  answer'), '<blockquote>\n<p>q</p>\n</blockquote>\n<p>  answer</p>\n');
  assert.match(render(true, '[link][id]\n\n[id]: https://example.com'), /href="https:\/\/example.com"/);
  for (const source of ['- ```\n  > q\n  answer\n  ```', '    ```\n\n> q\nanswer', '```invalid`opener\n> q\nanswer']) {
    if (source.startsWith('- ')) assert.equal(render(true, source), render(false, source));
    else assert.match(render(true, source), /<\/blockquote>\n<p>answer<\/p>/);
  }
  assert.equal(render(true, '```\n> q\nanswer\n```'), '<pre><code>&gt; q\nanswer\n</code></pre>\n');
});

test('the tail is the whole last token with its start, healed in one piece', () => {
  const tail = markdown()('Intro.\n\n**aa bb').at(-1);
  assert.equal(tail?.tail?.start, 8);
  assert.equal(tail?.tail?.token.raw, '**aa bb');
  assert.match(tail?.html ?? '', /<strong>aa bb<\/strong>/);
  assert.equal(markdown()('Intro.\n\ndone', true).at(-1)?.tail, undefined);
});

test('revealHeight shows the last complete unit above the clip once the hidden height or the time asks for it', () => {
  const unit = (bottom: number, complete = true): Unit => ({ bottom, complete });
  const lines = [unit(20), unit(40), unit(60), unit(80, false)];
  assert.equal(revealHeight(lines, 0, 100, false), undefined, 'the hidden height is under the cap');
  assert.equal(revealHeight(lines, 0, 80, false), 60, 'the cap reserves the unfinished last unit');
  assert.equal(revealHeight(lines, 0, 1000, true), 60, 'the time reveals the same units');
  assert.equal(revealHeight(lines, 60, 1000, true), undefined, 'nothing complete lies above the clip');
  assert.equal(revealHeight(lines, 20, 50, false), 60, 'the hidden height counts from the clip');
  assert.equal(revealHeight([unit(20, false)], 0, 10, true), undefined, 'a lone unfinished unit never shows');
  assert.equal(revealHeight([], 0, 0, true), undefined);
  assert.equal(revealHeight([unit(18), unit(50), unit(53)], 0, 40, false), 53, 'unequal heights');
  assert.equal(revealHeight([unit(20), unit(40)], 0, 30, false), 40, 'complete trailing code lines show whole');
  assert.equal(revealHeight([unit(20), unit(40, false)], 60, 1000, false), 20, 'a widened paragraph snaps the clip down to its last whole line');
  assert.equal(revealHeight([unit(20), unit(40), unit(60, false)], 45, 1000, false), 40, 'a patch that rewraps snaps the clip to a line boundary');
  assert.equal(revealHeight([unit(20), unit(40), unit(60, false)], 40.2, 1000, false), undefined, 'a clip on a boundary stays');
  assert.equal(revealHeight([unit(20, false)], 20, 1000, false), 0, 'no whole line left');
});

test('an append re-lexes only the tail of a long document', () => {
  const lex = Lexer.prototype.lex, inputs: number[] = [];
  Lexer.prototype.lex = function (this: Lexer, source: string) { inputs.push(source.length); return lex.call(this, source); };
  try {
    const render = markdown(), prefix = Array.from({ length: 200 }, (_, index) => `Paragraph ${index} with **bold** words.`).join('\n\n') + '\n\n';
    const first = render(prefix + 'Tail');
    inputs.length = 0;
    const grown = prefix + 'Tail grows';
    const blocks = render(grown, false, [], prefix.length + 4), html = blocks.map(block => block.html).join('');
    assert.equal(blocks[0], first[0]);
    assert.ok(Math.max(...inputs) < 500, `document lex input of ${Math.max(...inputs)} code units`);
    assert.equal(html, markdown()(grown).map(block => block.html).join(''));
  } finally { Lexer.prototype.lex = lex; }
});

test('a nested reference definition in the re-lexed suffix does not keep a stale URL', () => {
  const old = '[x][id]\n\nA\n\nB\n\nC\n\n> [id]: https://a', render = markdown();
  render(old);
  const grown = old + 'b\n';
  assert.equal(render(grown, false, [], old.length).map(block => block.html).join(''), markdown()(grown).map(block => block.html).join(''));
});

const fixtures = [
  'First **paragraph**.\n\nSecond `code`.\n\n- one\n- two', '| a | b |\n| - | - |\n| c | d |', 'A [reference][id].\n\n[id]: https://example.com', '```ts\nconst x = 1;\n```\n\nDone.',
  '😀 Choose `one`?\n\n- Pick **two**?\n\nTail', 'Use [one][id]?\n\n[id]: https://example.com', 'First.\r\n\r\nPick one?\r\n\r\nLast\r\n', 'Literal 999;x and 0;x forged.',
  '> q\nanswer', '> q\n  answer', '[link][id]\n\n[id]: https://example.com', '- ```\n  > q\n  answer\n  ```', '    ```\n\n> q\nanswer', '```invalid`opener\n> q\nanswer', '```\n> q\nanswer\n```',
  'Intro.\n\naa bb cc dd ee ff gg', '```ts\r\na\r\nb\r\nc', '| a | b |\n| - | - |\n| 1 | 2 |\n| 3 |', '- one\n  ```\n  x\n  ```\n- two', '> q\n> ```\n> x', '- outer\n  - inner\n\n    ```js\n    a\n    b\n    ```\n- last',
  '### Heading\n\nSetext\n===\n\n---', 'Intro.\n\n[id]: https://x.test\n\n- [one][id]\n- two\n- th', '**aa bb cc dd**', 'Done.\n\n- one\n- two\n- thr', '[x][id]\n\nA\n\nB\n\nC\n\n> [id]: https://a\n\nD\n\nE', '1. a\n2. b\n\n3. c\n\n<div>html</div>\n\ntrailing\r',
];

test('incremental markdown matches a fresh render after random chunks, replacements and cuts', () => {
  let seed = 12345;
  const random = (max: number) => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % max; };
  const html = (blocks: { html?: string }[]) => blocks.map(block => block.html).join('');
  for (const user of [false, true]) {
    const render = markdown(user);
    for (const [index, fixture] of fixtures.entries()) for (const round of [0, 1]) {
      let source = '';
      const lengths = [0], context = () => JSON.stringify({ user, index, round, source });
      const step = (next: string, changed: number, final = false) => {
        source = next;
        const marks: Mark[] = random(3) ? [] : [{ offset: random(source.length + 1), side: 'open', mark: '0' }, { offset: source.length, side: 'close', mark: '' }];
        marks.sort((a, b) => a.offset - b.offset);
        const blocks = render(source, final, marks, changed);
        assert.equal(html(blocks), html(markdown(user)(source, final, marks)), context());
        return blocks;
      };
      while (source.length < fixture.length) {
        const end = Math.min(fixture.length, source.length + 1 + random(round ? 25 : 4));
        step(fixture.slice(0, end), random(3) ? lengths.at(-1) ?? 0 : lengths[random(lengths.length)]);
        lengths.push(source.length);
      }
      const other = fixtures[random(fixtures.length)], keep = random(source.length + 1);
      step(source.slice(0, keep) + other.slice(random(other.length)), keep);
      step(source, 0, true);
      step(fixture, 0);
      step(fixture + '\n\nmore', fixture.length);
      step('', 0, true);
    }
  }
  const split = markdown(), before = 'A\r\n\r\nB\r\n\r\nC\r\n\r\nD\r';
  split(before);
  assert.equal(html(split(before + '\nE', false, [], before.length)), html(markdown()(before + '\nE')));
});

test('the composer foot keeps the optional thread before the model and has no agent status cell', async () => {
  const html = await readFile(new URL('page/page.html', import.meta.url), 'utf8');
  const css = await readFile(new URL('page/page.css', import.meta.url), 'utf8');
  assert.match(html, /<div class="foot"><span id="model-cell"/);
  assert.doesNotMatch(html, /id="(status|dot)"/);
  assert.match(html, /id="jobfoot"[^]*id="job-dot"[^]*id="job-word"/);
  assert.doesNotMatch(css, /\.foot \.(st|dot)\b/);
});

test('the page keeps no content-visibility rule and no estimate property', async () => {
  const css = await readFile(new URL('page/page.css', import.meta.url), 'utf8');
  assert.doesNotMatch(css, /content-visibility|--estimate/);
});

const base = { seq: 0, revision: 0, at: 1, final: true };
const body = { text: 'x', cut: 0 };
const text = (value: string): Block => ({ type: 'text', text: value });
const step = (name: string): Extract<Block, { type: 'tool' }> => ({ type: 'tool', id: name, name, args: body, state: { type: 'pending' } });
const card = (): Block => ({ ...step('message'), agent: { direction: 'out', to: { name: 'a' }, text: body, call: { tool: 'message', mode: 'message' } } });
const assistant = (blocks: Block[], error = ''): WireItem => ({ ...base, kind: 'assistant', blocks, stop: '', error });
const job: JobRef = { id: 'j', name: 'j', service: false, log: '', command: '', startedAt: 0, place: { type: 'mac' } };

test('estimateExtent follows the rule of every item kind', () => {
  const lh = 20, line = lh + 16;
  const cases: [string, WireItem, number][] = [
    ['user', { ...base, kind: 'user', text: 'a\nb\nc', images: [], attachments: [] }, 3 * lh + 30],
    ['annotations', { ...base, kind: 'annotations', reply: { seq: 0, block: 0 }, annotations: [] }, 0],
    ['assistant text', assistant([text('one\ntwo')]), 2 * lh],
    ['assistant empty text', assistant([text(' \n ')]), 0],
    ['assistant run', assistant([step('read'), { type: 'thinking', text: 'x' }, step('bash')]), line],
    ['assistant text between runs', assistant([step('read'), text('hi'), step('bash')]), line + lh + line],
    ['assistant agent step joins a run', assistant([step('read'), card(), step('bash')]), line],
    ['assistant error', assistant([text('x')], 'boom'), lh + line],
    ['assistant joined run', { ...assistant([step('read'), text('x')]), seq: 1 }, lh],
    ['agent', { ...base, kind: 'agent', direction: 'in', from: { name: 'a' }, text: body, inbound: { form: 'notice' } }, line],
    ['job', { ...base, kind: 'job', job, event: { type: 'stream', batch: body, omitted: 0, cut: false } }, line],
    ['joined agent', { ...base, seq: 1, kind: 'agent', direction: 'in', from: { name: 'a' }, text: body, inbound: { form: 'notice' } }, 0],
    ['joined job', { ...base, seq: 1, kind: 'job', job, event: { type: 'stream', batch: body, omitted: 0, cut: false } }, 0],
    ['notify', { ...base, kind: 'notify', level: 'info', text: body }, line],
    ['command', { ...base, kind: 'command', result: { type: 'copy', characters: 1 } }, line],
    ['notice', { ...base, kind: 'notice', customType: '', from: '', text: 'x' }, line],
    ['bash', { ...base, kind: 'bash', command: 'ls', excludeFromContext: false, result: { output: body, cancelled: false, truncated: false } }, line],
    ['summary', { ...base, kind: 'summary', source: 'branch', text: 'x' }, line],
  ];
  for (const [name, item, expected] of cases) {
    const sources = new Map<number, WireItem>([[0, assistant([step('before')])], [item.seq, item]]);
    const context = { raw: (seq: number) => sources.get(seq), shown: (seq: number) => sources.get(seq), owners: new Map() };
    assert.equal(estimateExtent(item, lh, context), expected, name);
  }
});

test('run ownership scans a cold item once and keeps owners beyond a stable boundary', () => {
  const blocks = Array.from({ length: 200 }, (_, index) => step(String(index)));
  const sources = new Map<number, WireItem>([
    [0, assistant(blocks)],
    [1, { ...assistant([text('boundary'), step('next')]), seq: 1 }],
    [2, { ...assistant([step('follower')]), seq: 2 }],
  ]);
  let reads = 0;
  const context: RunContext = { raw: seq => { reads++; return sources.get(seq); }, shown: seq => sources.get(seq), owners: new Map() };
  for (let index = 0; index < blocks.length; index++) assert.deepEqual(runOwner(context, { kind: 'block', seq: 0, index }), { kind: 'block', seq: 0, index: 0 });
  assert.equal(reads, 1, 'the cold item is enumerated once, not once per block');
  assert.deepEqual(runOwner(context, { kind: 'block', seq: 2, index: 0 }), { kind: 'block', seq: 1, index: 1 });
  const retained = context.owners.get(2);
  sources.set(0, assistant([text('new boundary'), ...blocks]));
  assert.equal(invalidateRuns(context, 0), 1);
  assert.equal(context.owners.get(2), retained, 'the stable boundary retains the following cached item');
  assert.deepEqual(runOwner(context, { kind: 'block', seq: 0, index: 200 }), { kind: 'block', seq: 0, index: 1 });
});

test('ownership invalidation crosses an uncached transparent item', () => {
  const sources = new Map<number, WireItem>([
    [0, assistant([step('first')])],
    [1, { ...base, seq: 1, kind: 'annotations', reply: { seq: 0, block: 0 }, annotations: [] }],
    [2, { ...assistant([step('last')]), seq: 2 }],
  ]);
  const context: RunContext = { raw: seq => sources.get(seq), shown: seq => sources.get(seq), owners: new Map() };
  assert.deepEqual(runOwner(context, { kind: 'block', seq: 2, index: 0 }), { kind: 'block', seq: 0, index: 0 });
  context.owners.delete(1);
  sources.set(0, assistant([text('boundary'), step('first')]));
  assert.equal(invalidateRuns(context, 0), 2);
  assert.deepEqual(runOwner(context, { kind: 'block', seq: 2, index: 0 }), { kind: 'block', seq: 0, index: 1 });
});

const prefix = (order: number[], px: Map<number, number>) => order.reduce((sums, seq) => [...sums, sums[sums.length - 1] + (px.get(seq) ?? 0)], [0]);

test('windowOf covers the viewport and its overscan, and closes over a group', () => {
  const order = [0, 1, 2, 4, 5, 6, 7, 8], px = new Map([[0, 50], [1, 0], [2, 50], [4, 50], [5, 50], [6, 50], [7, 50], [8, 50]]);
  const of = (top: number, viewport: number, overscan: number, groups: { from: number; to: number }[] = []) => windowOf(order, prefix(order, px), top, viewport, overscan, groups);
  assert.equal(windowOf([], [0], 0, 100, 100, []), undefined);
  assert.deepEqual(of(50, 0, 0), { from: 0, to: 2 }, 'every item that shares the edge touches, a zero extent too');
  assert.deepEqual(of(0, 10, 0), { from: 0, to: 0 });
  assert.deepEqual(of(100, 50, 0), { from: 2, to: 5 }, 'inclusive edges touch both neighbours');
  assert.deepEqual(of(110, 20, 0), { from: 4, to: 4 });
  assert.deepEqual(of(110, 20, 40), { from: 2, to: 5 }, 'the overscan widens both ends over a seq gap');
  assert.deepEqual(of(9999, 100, 100), { from: 8, to: 8 }, 'beyond the end is the last item');
  assert.deepEqual(of(-500, 10, 0), { from: 0, to: 0 });
  assert.deepEqual(of(110, 20, 0, [{ from: 2, to: 6 }]), { from: 2, to: 6 }, 'a group that the range touches is whole');
  assert.deepEqual(of(150, 20, 0, [{ from: 2, to: 4 }, { from: 5, to: 7 }]), { from: 2, to: 7 }, 'a range that touches two groups takes both');
  assert.deepEqual(of(110, 20, 0, [{ from: 7, to: 8 }]), { from: 4, to: 4 }, 'a group out of range stays out');
});

test('windowOf includes every item that the clamped range touches and no other', () => {
  let seed = 7;
  const random = (limit: number) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % limit; };
  for (let round = 0; round < 200; round++) {
    const order: number[] = [], px = new Map<number, number>();
    for (let seq = 0, at = 0; at < 1 + random(30); seq += 1 + random(3), at++) { order.push(seq); px.set(seq, random(4) * 25); }
    const top = random(1500) - 200, viewport = random(200), overscan = random(150);
    const result = windowOf(order, prefix(order, px), top, viewport, overscan, []);
    assert.ok(result);
    const total = order.reduce((sum, seq) => sum + (px.get(seq) ?? 0), 0), low = Math.min(total, Math.max(0, top - overscan)), high = Math.min(total, Math.max(0, top + viewport + overscan));
    let start = 0;
    for (const seq of order) {
      const end = start + (px.get(seq) ?? 0), touches = end >= low && start <= high;
      if (touches) assert.ok(seq >= result.from && seq <= result.to, 'item ' + seq + ' touches [' + low + ',' + high + ']');
      start = end;
    }
    assert.ok(order.includes(result.from) && order.includes(result.to));
  }
});

class Fake {
  className = ''; textContent = ''; children: Fake[] = []; attributes = new Map<string, string>(); parent?: Fake; list?: Fake; onmousedown?: unknown; dataset = {};
  append(...nodes: Fake[]) { for (const node of nodes) { node.remove(); node.parent = this; this.children.push(node); } }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = undefined; }
  setAttribute(name: string, value: string) { this.attributes.set(name, value); }
  animate() { return {}; }
  getBoundingClientRect() { return { left: 0, right: 0, top: 0, width: 0 }; }
  get lastElementChild() { return this.children.at(-1); }
  querySelector(selector: string): Fake | undefined {
    if (selector === '.koa-complete > ul') return this.list;
    const names = selector.slice(1).split('.');
    return this.children.find(child => names.every(name => child.className.split(' ').includes(name)));
  }
}

async function feedbackFixture(t: TestContext) {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const read = async (name: string) => stripTypeScriptTypes(await readFile(new URL(name, import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  const body = new Fake(), replies: ((value: unknown) => void)[] = [], popup = { open: false }, capture: { config?: Parameters<typeof autocompletion>[0] } = {};
  const context = {
    StateEffect, StateField, EditorState, Decoration, showTooltip, tooltips, ViewPlugin, EditorView, WidgetType, capture, currentCompletions: () => popup.open ? [{}] : [], autocompletion: (config: Parameters<typeof autocompletion>[0]) => { capture.config = config; return autocompletion(config); }, acceptCompletion, closeCompletion, completionStatus, moveCompletionSelection, pickedCompletion, selectedCompletion, startCompletion, syntaxTree, fileToken, slashToken, bashCommand,
    document: { createElement: () => new Fake(), body, querySelector: () => undefined, timeline: { currentTime: 0 } },
    matchMedia: () => ({ matches: false }), window: { innerHeight: 100 }, console, AbortController, Date,
    setTimeout: (...args: Parameters<typeof setTimeout>) => setTimeout(...args), clearTimeout: (id?: Parameters<typeof clearTimeout>[0]) => clearTimeout(id),
    fetch: () => new Promise(resolve => replies.push(value => resolve({ ok: true, json: async () => value }))),
  };
  const fixture = runInNewContext(await read('page/working.ts') + await read('page/complete.ts') + `
    const host = { parentElement: { getBoundingClientRect: () => ({ left: 0, right: 0, top: 0, width: 0 }) } };
    const mode = StateField.define({ create: state => bashCommand(state.doc.toString()), update: (value, transaction) => transaction.docChanged ? bashCommand(transaction.newDoc.toString()) : value });
    const completions = completion(host, () => {}, mode);
    const view = {
      state: EditorState.create({ doc: '!ls', selection: { anchor: 3 }, extensions: [mode, completions.extension] }),
      dispatch(spec) {
        const transaction = view.state.update(spec);
        view.state = transaction.state;
        for (const listener of view.state.facet(EditorView.updateListener)) listener({ docChanged: transaction.docChanged, selectionSet: !!transaction.selection, state: view.state });
      },
    };
    completions.extension.find(extension => extension instanceof ViewPlugin).create(view);
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
  };
}
const settle = () => new Promise<void>(resolve => setImmediate(resolve));
const shellReply = (options: { label: string; insert: string }[]) => ({ type: 'shell', from: 3, to: 3, options, common: '', more: 0 });

test('shell Tab shows the dots after the caret once the wait passes 150 ms and drops them with the reply', async t => {
  const f = await feedbackFixture(t);
  f.key('Tab');
  t.mock.timers.tick(149);
  assert.deepEqual(f.widgets(), []);
  t.mock.timers.tick(1);
  assert.deepEqual(f.widgets(), [{ from: 3, side: 1, className: 'dots', label: 'working' }]);
  f.replies[0](shellReply([{ label: 'a', insert: 'a' }, { label: 'b', insert: 'b' }]));
  await settle();
  assert.deepEqual(f.widgets(), []);
});

test('a pending request in an open popup is the last row of the list, not an inline mark', async t => {
  const f = await feedbackFixture(t);
  const list = new Fake(), more = new Fake();
  more.className = 'row more'; list.append(more);
  if (f.layer) f.layer.list = list;
  f.open(true);
  f.key('Tab');
  t.mock.timers.tick(150);
  assert.deepEqual(f.widgets(), []);
  assert.deepEqual(list.children.map(child => child.className), ['row more', 'row pending']);
  assert.equal(list.children.at(-1)?.attributes.get('role'), 'presentation');
  assert.equal(list.children.at(-1)?.children[0]?.className, 'dots');
  f.key('Escape');
  assert.deepEqual(list.children.map(child => child.className), ['row more']);
});

test('no completions shows in a tooltip from the reply until 1500 ms and goes with a caret move or Escape', async t => {
  const f = await feedbackFixture(t);
  const empty = async () => { f.key('Tab'); f.replies.at(-1)?.(shellReply([])); await settle(); };
  await empty();
  assert.deepEqual(f.tooltips(), [{ className: 'cm-tooltip-autocomplete koa-complete empty', text: 'no completions' }]);
  assert.deepEqual(f.widgets(), []);
  t.mock.timers.tick(1499);
  assert.equal(f.tooltips().length, 1);
  t.mock.timers.tick(1);
  assert.deepEqual(f.tooltips(), []);
  await empty();
  assert.equal(f.tooltips().length, 1);
  f.dispatch({ selection: { anchor: 1 } });
  assert.deepEqual(f.tooltips(), []);
  f.dispatch({ selection: { anchor: 3 } });
  await empty();
  f.key('Escape');
  assert.deepEqual(f.tooltips(), []);
});

test('a cancelled request leaves no feedback when its reply arrives late', async t => {
  const f = await feedbackFixture(t);
  f.key('Tab');
  t.mock.timers.tick(150);
  assert.equal(f.widgets().length, 1);
  f.key('Escape');
  assert.deepEqual(f.widgets(), []);
  f.replies[0](shellReply([]));
  await settle();
  assert.deepEqual(f.widgets(), []);
  assert.deepEqual(f.tooltips(), []);
  f.key('Tab');
  t.mock.timers.tick(150);
  f.dispatch({ changes: { from: 3, insert: 'x' }, selection: { anchor: 4 } });
  assert.deepEqual(f.widgets(), []);
});

test('prose Tab consumes the key without an open completion', async t => {
  const f = await feedbackFixture(t);
  f.dispatch({ changes: { from: 0, to: 3, insert: 'ls' } });
  assert.equal(f.key('Tab'), true);
  assert.equal(f.key('Shift-Tab'), true);
});

test('a prompt request shows the dots after 150 ms and an aborted one leaves none', async t => {
  const f = await feedbackFixture(t);
  f.dispatch({ changes: { from: 0, to: 3, insert: '@a' } });
  const cancel = f.prompt();
  t.mock.timers.tick(149);
  assert.deepEqual(f.widgets(), []);
  t.mock.timers.tick(1);
  assert.equal(f.widgets().length, 1);
  cancel();
  f.dispatch({ changes: { from: 2, insert: 'b' }, selection: { anchor: 3 } });
  assert.deepEqual(f.widgets(), []);
  const aborted = f.prompt();
  t.mock.timers.tick(100);
  aborted();
  f.dispatch({ changes: { from: 3, insert: 'c' }, selection: { anchor: 4 } });
  t.mock.timers.tick(100);
  assert.deepEqual(f.widgets(), []);
});
