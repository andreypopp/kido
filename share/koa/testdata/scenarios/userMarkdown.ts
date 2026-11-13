import { next, type Step, type Scenarios } from "../scenario.ts";
import type { PageRecord } from "../../koa-records.ts";
import { stateIdleThird } from "../scenario-parts.ts";

const recordsFromResetOf3ItemsSecond = (dir: string): PageRecord[] => ([
  { type: "reset", epoch: "epoch1", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Use `inline` and the same Markdown rules, see [the reference](https://example.com/ref).\n\n> Keep the quoted instruction clear on the tint.\n\n- First item\n- Second item\n\n```js\nconst x = 1;\n```\n\n<b>raw HTML stays text</b>", images: [], attachments: [] }, { seq: 1, revision: 0, at: 1794177120000, final: true, kind: "assistant", blocks: [{ type: "text", text: "The text column is the same width." }], stop: "stop", error: "" }, { seq: 2, revision: 0, at: 1794177120001, final: true, kind: "user", text: "A plain one-line message", images: [], attachments: [] }], more: false },
  stateIdleThird(dir),
]);

const stepsFromNextResetOf1Items = (dir: string): Step[] => ([
  next([
    { type: "reset", epoch: "epoch2", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "> The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.\nYes", images: [], attachments: [] }], more: false },
    stateIdleThird(dir),
  ]),
  next([
    { type: "reset", epoch: "epoch3", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "> error[E0599]: no method named `place` found for struct `Model`\n>   --> ko_client/src/model.rs:412:18\nWhy does this appear only on the musl target? The method is `pub(crate)`.\n\n> Should I push now, or wait for CI on the rebase?\nwait for CI", images: [], attachments: [] }], more: false },
    stateIdleThird(dir),
  ]),
  next([
    { type: "reset", epoch: "epoch4", items: [{ seq: 0, revision: 0, at: 1794177120000, final: true, kind: "user", text: "Use this as the fixture:\n\n```json\n{ \"reply\": { \"at\": 1762764720000, \"block\": 0, \"length\": 212 },\n  \"annotations\": [ { \"type\": \"question\", \"range\": [96, 142],\n    \"kind\": \"choice\", \"options\": [[106, 114], [119, 130]] } ] }\n```\n\nand make the test read it from a `file`.", images: [], attachments: [] }], more: false },
    stateIdleThird(dir),
  ]),
]);

export const scenarios: Scenarios = {
  testKoaWebviewUserMarkdownNarrow: dir => ({
    open: recordsFromResetOf3ItemsSecond(dir),
    steps: stepsFromNextResetOf1Items(dir),
    files: {},
  }),
  testKoaWebviewUserMarkdownWide: dir => ({
    open: recordsFromResetOf3ItemsSecond(dir),
    steps: stepsFromNextResetOf1Items(dir),
    files: {},
  }),
};
