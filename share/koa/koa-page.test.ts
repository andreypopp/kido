import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { Script } from "node:vm";
import { Marked } from "marked";
import remend from "remend";

import { assemblePage } from "./koa-assemble.ts";
import { markdown } from "./page/markdown.ts";
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
  const page = await assemblePage(location);
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

test("an earlier edit regenerates consumed HTML in the later blocks", () => {
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
    assert.deepEqual(Object.keys(blocks[0]), ['streaming']);
  }
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
