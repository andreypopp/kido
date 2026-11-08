import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { Script, runInNewContext } from "node:vm";
import { createRequire } from "node:module";

import { assemblePage } from "./koa-assemble.ts";
import { markdown } from "./koa-markdown.js";

const require = createRequire(import.meta.url);
const { Marked } = require("./vendor/marked.js");
const remend = require("./vendor/remend.js").default;
const full = (source: string, final = false) => {
  const parser = new Marked();
  parser.use({ renderer: { link(token: { href: string; tokens: object[] }) { return /^(https?:\/\/[^/\s]+|mailto:.+)/.test(token.href) ? false : parser.Parser.parseInline(token.tokens, parser.defaults); } } });
  const tokens = parser.lexer(source);
  const tail = tokens.at(-1);
  if (!final && tail) tokens.splice(-1, 1, ...parser.lexer(remend(tail.raw)));
  return parser.parser(tokens);
};

test("page assembly has one module scope, in dependency order", async () => {
  const location = new URL("koa.ts", import.meta.url);
  const page = await assemblePage(location);
  assert.equal(page.match(/<script type="module">/g)?.length, 1);
  assert.equal(page.match(/const markedModule =/g)?.length, 1);
  assert.equal(page.match(/const remendModule =/g)?.length, 1);
  assert.ok(page.indexOf("const markedModule") < page.indexOf("const remendModule"));
  assert.ok(page.indexOf("const remendModule") < page.indexOf("function markdown"));
  assert.ok(page.indexOf("function markdown") < page.indexOf("const items ="));
  const script = page.split('<script type="module">')[1]?.split('</script>')[0] ?? "";
  assert.doesNotMatch(script, /\bimport\s|\bexport\s/);
  new Script(script);
  const modules = script.slice(0, script.indexOf('const koa_pageModule'));
  assert.equal(runInNewContext(modules + '\nkoa_markdownModule.markdown()("**a**", true).map(block=>block.html).join("")'), '<p><strong>a</strong></p>\n');
  for (const name of ["marked", "remend"]) {
    const source = await readFile(new URL(`vendor/${name}.js`, location), "utf8");
    assert.equal(page.split(source.slice(0, 80)).length - 1, 1);
  }
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
