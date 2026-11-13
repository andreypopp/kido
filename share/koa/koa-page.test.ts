import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { Script } from "node:vm";
import { Marked } from "marked";
import remend from "remend";

import { assemblePage } from "./koa-assemble.ts";
import { markdown, markdownLine, sliceEnd, type Mark } from "./page/markdown.ts";
import { answer, current, quote } from "./page/answers.ts";
import { composerLanguage } from "./page/composer.ts";
import { highlightTree, tags } from '@lezer/highlight';
import { HighlightStyle } from '@codemirror/language';

test('Markdown previews strip first-line syntax and use the first fenced code line', () => {
  for (const [source, expected] of [
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
  const location = new URL("../../build/ko/share/ko/koa/koa.ts", import.meta.url);
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
  for (const source of ["First **paragraph**.\n\nSecond `code`.\n\n- one\n- two", "| a | b |\n| - | - |\n| c | d |", "A [reference][id].\n\n[id]: https://example.com", "```ts\nconst x = 1;\n```\n\nDone."]) {
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

test('tail cuts keep whole units and the rest of the lexing path', () => {
  const words = (text: string) => Math.ceil(text.split(/\s+/).filter(Boolean).length / 3);
  const shown = (source: string) => {
    const tail = markdown()(source).at(-1)?.tail;
    assert.ok(tail);
    const end = sliceEnd(tail.token, at => words(source.slice(tail.start, tail.start + at)));
    const html = markdown()(source, false, [], { start: tail.start, end }).map(block => block.html).join('');
    return [tail.token.raw.slice(0, end), html] as const;
  };
  assert.deepEqual(shown('Intro.\n\naa bb cc dd ee ff gg')[0], 'aa bb cc dd ee ff');
  assert.deepEqual(shown('aa bb cc')[0], '');
  assert.deepEqual(shown('```ts\na\nb\nc')[0], '```ts\na\nb\n');
  assert.match(shown('```ts\na\nb\nc')[1], /<code class="language-ts">a\nb\n<\/code>/);
  assert.equal(shown('```ts\nco')[0], '');
  assert.equal(shown('```ts\r\na\r\nb\r\nc')[0], '```ts\na\nb\n');
  assert.equal(shown('| a | b |\n| - | - |\n| 1 | 2 |\n| 3 |')[0], '| a | b |\n| - | - |\n| 1 | 2 |\n');
  assert.doesNotMatch(shown('| a | b |\n| - | - |\n| 1 | 2 |\n| 3 |')[1], /<td>3<\/td>/);
  assert.equal(shown('| a | b |\n| - | - |\n')[0], '');
  assert.equal(shown('- one\n- two\n- thr')[0], '- one\n- two\n');
  assert.equal(shown('- one')[0], '');
  assert.equal(shown('- one\n  ```\n  x\n  ```\n- two')[0], '');
  assert.equal(shown('> q\n> ```\n> x')[0], '');
  assert.equal(shown('- outer\n  - inner\n\n    ```js\n    a\n    b\n    ```\n- last')[0], '');
  assert.equal(shown('### Heading')[0], '');
  assert.match(shown('Intro.\n\n[id]: https://x.test\n\n- [one][id]\n- two\n- th')[1], /<a href="https:\/\/x.test">one<\/a>/);
  const bold = markdown()('**aa bb cc dd**');
  assert.match(bold[0].tail?.html(8) ?? '', /<strong>aa bb<\/strong>/);
  const render = markdown(), list = 'Done.\n\n- one\n- two\n- thr';
  const cutTo = (start: number, end: number) => render(list, false, [], { start, end }).at(-1);
  const first = cutTo(7, 6);
  assert.equal(cutTo(7, 6), first);
  assert.notEqual(cutTo(7, 12), first);
  assert.match(cutTo(7, 12)?.html ?? '', /<li>two<\/li>/);
  assert.equal(cutTo(0, 12)?.html, '');
});
