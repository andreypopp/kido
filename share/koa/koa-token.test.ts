import { test } from "node:test";
import assert from "node:assert/strict";
import { atToken, fileToken, slashToken } from "../pi/token.ts";

test("agent and file mentions share boundaries, wrappers and quoted paths", () => {
  const cases: [string, string | undefined, string | undefined][] = [
    ["@", "", "@"], ["Ask @impl", "impl", "@impl"], ["(@impl", "impl", "@impl"], ["[`@impl", "impl", "@impl"],
    ["ask=@impl", "impl", "@impl"], ["问，@impl", "impl", "@impl"], ["email@example", undefined, undefined],
    ['@"a b', undefined, '@"a b'], ['([@"a b', undefined, '@"a b'], ['email@"a b', undefined, undefined],
    ["@impl done", undefined, undefined], ["[slug]@impl", undefined, undefined], ['@"a b"', undefined, undefined],
  ];
  for (const [text, agent, file] of cases) {
    assert.equal(atToken(text), agent, text);
    assert.equal(fileToken(text)?.text, file, text);
  }
});

test("slash commands start on the first line with only blank text before them", () => {
  for (const [text, expected] of [["/", "/"], ["  /re", "/re"], ["\n/re", undefined], ["text /re", undefined], ["/review arg", undefined]] as const) assert.equal(slashToken(text, text.length), expected, text);
  assert.equal(slashToken(" /review\nnext", 4), "/re");
});
