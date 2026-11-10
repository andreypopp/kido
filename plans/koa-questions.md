# Reply annotations: pi-infer-questions in koa

Status: a design, 2026-11-10. The user's request: the questions that
pi-infer-questions finds in a reply reach koa's page, and a click puts
the quoted question and the answer into the composer, as the
extension's TUI controls do. The user's direction, same day: koa does
not depend on pi-infer-questions. The design is a generic contract: any
pi extension can annotate a reply with spans of a kind and its data, in
a typed custom session entry; koa's transcript attaches the entry to
the reply, live and on replay; the page renders the kinds it knows and
ignores the rest. pi-infer-questions is the first producer. The design
agent `@kido-app-design` mocks the controls before unit B.

Line references: `share/pi/transcript.ts`, `share/pi/records.ts`,
`share/koa/koa.ts`, `share/koa/page/*.ts` at the current worktree;
`extension.ts` of `~/Workspace/pi-infer-questions` at 59ce3f6.

## What pi-infer-questions does today

**Load and platform.** `extension.ts:43-61` resolves the platform
package `@andreypopp/pi-infer-questions-<platform>` (darwin-arm64,
linux-arm64, linux-x64 with glibc; `package.json`
`optionalDependencies`), loads `questions.node` and calls
`start(models)`, which loads the two Core ML or ONNX models on a
background thread (`native/Api.swift:7-18`). On any other platform or a
failed load, the extension registers only a `session_start` handler
that notifies once (`:218-221`) and does nothing else.

**Hook and timing.** `message_end` (`:282-300`): for an assistant
message with `stopReason === "stop"` (not aborted, not an error, not a
message that ends in a tool call), for each `text` content block, it
trims the text and calls `native.questions(markdown)`, which blocks
until the models are loaded and runs the whole pipeline off the
JavaScript thread (`native/Api.swift:33-66`). The reply takes a few
milliseconds (README, "How it works"). A reply with no question appends
nothing; a reply with questions appends one custom entry
`pi-infer-questions` with `{ markdown, questions }` (`:294`), where
`questions: { range: [start, end], kind: "choice" | "yes_no" | "open",
options: [start, end][] }[]` (`:32-40`). Ranges are Unicode code-point
offsets into the trimmed Markdown (docs/design.md, "Decoding": "Ranges
in the result are Unicode code-point offsets into the original
Markdown"; a range grows over every code span it overlaps). Options
exist only for `choice`.

**Rendering in the TUI.** `registerMarkdownTransformer` (`:239-241`)
blanks a completed assistant message whose trimmed text is in `texts`,
the set of every annotated reply of the session (`:243-248`, `:293`).
`registerEntryRenderer` (`:304-364`) draws the entry instead: it splits
the Markdown into blank-line blocks (`blocks`, `:104-125`), inserts the
sentinel characters U+E010 and U+E011 around each option and around
each control label after a question's end (`:321-341`), renders each
block with pi-tui's `Markdown`, and `Interactive` (`:140-215`) finds the
sentinels in the rendered lines to get the clickable cells. The labels
(`:333-336`): `open` gets `Answer`; `yes_no` gets `Yes/No/Other`; a
`choice` gets its options in place, then `Other`, and `Yes/Other` when
it has one option. The quote (`:312-320`): the question's Markdown with
links and images reduced to their text, `` ` ``, `*`, `__` and `~~`
removed, spaces collapsed, lines trimmed and empty lines dropped. The
click (`:348-360`) edits the whole editor text: the block
`> <quote lines>\n\n<answer>` is appended after two newlines, or, when
a block with the same quote exists, its answer is replaced when the
new answer is non-empty or the label is `Other`. `session_start` sets
up the TUI only when `ctx.mode === "tui"` (`:249`): it patches the TUI
for any-motion mouse tracking and the hidden message's spacer
(`:251-279`, docs/design.md, "Rendering in pi").

**The guide.** `before_agent_start` (`:231-237`) pushes five rules into
`systemPromptOptions.promptGuidelines` unless `--no-question-guide`,
and appends one `pi-infer-questions-guide` entry per session. This runs
in every mode and does not change.

**In koa's pi today.** koa spawns `pi --mode rpc --extension ko-pi.ts`
(`koa.ts:155`) without `--no-extensions`, so pi loads the installed
packages, pi-infer-questions among them. In RPC mode `ctx.mode` is
`"rpc"` and `ctx.hasUI` is true (pi's `extensions.md`, "Mode
Behavior"): `session_start` returns before the TUI setup, the guide
applies, and `message_end` analyses each reply and appends the entry.
pi emits `entry_appended` with the entry (pi's `json.md`, "Queue and
state events"), which koa's `event` switch (`koa.ts:234-295`) does not
handle. In a routed runtime (`pi: host`, the default) pi runs on the
host with the host's extensions (docs/design-runtimes.md, "Agents in a
runtime"), so the host's installation serves it. Only a runtime with
`pi: runtime`, and a remote host (`ko ssh`, where koa and pi run
remotely), need the extension installed where pi runs; koa cannot
supply it.

## The contract

One custom session entry, appended with `pi.appendEntry`. A custom
entry never enters the model's context and never renders in pi's TUI
unless an extension registers a renderer for it, so a second producer
costs the model nothing. The contract is a documented `customType` and
JSON shape. It has no version field: a consumer ignores a field it does
not know and drops an annotation that lacks a field it needs. No
compatibility shims on either side.

```
customType: "reply-annotations"
data: {
  reply: { at: number; block: number; length: number };
  annotations: Annotation[];
}
Annotation =
  { type: "question"; range: [number, number];
    kind: "choice" | "yes_no" | "open"; options: [number, number][] }
```

- `reply.at` is the assistant message's `timestamp` (ms), the field
  that pi persists in the message and returns in `get_messages`, and
  that `transcript.ts` already uses as the item's `at`
  (`transcript.ts:346`). `reply.block` is the index of the text block
  in the message's `content`. The producer has both in its
  `message_end` event. pi gives an extension no entry id at
  `message_end`, and `get_messages` carries no entry ids, so the
  message's own fields are the key.
- `reply.length` is the length of the text block in code points, as
  pi stores it, untrimmed. A consumer whose text has another length
  drops the whole entry (a stale or foreign annotation).
- Offsets are Unicode code-point offsets into the text block's
  Markdown source, as pi stores it, untrimmed. Code points, not
  UTF-16 units: the producer is not necessarily JavaScript
  (pi-infer-questions computes them in Swift), and the rule is the one
  the extension already documents. `range` is `[start, end)`. An
  option is inside its question's range. A consumer drops a span that
  is out of range or reversed, and keeps the others.
- An annotation `type` that the consumer does not know is dropped. A
  `question.kind` that it does not know is dropped. `options` are
  ignored for a kind other than `choice`.
- One entry per text block. A second entry for the same `reply`
  replaces the first in the consumer. Nothing else is said about order.

The contract text is `docs/reply-annotations.md` (written; the
consumer defines it, and pi-infer-questions links to it), and the TypeScript
type in `share/pi/records.ts`, which koa and its page import. The
producer repository writes its own literal; the two repositories do not
share code.

## koa's side

**The transcript** (`share/pi/transcript.ts`). An annotation is an item
of its own kind, not a field of the assistant item:

```ts
{ kind: "annotations"; reply: { seq: number; block: number }; annotations: Annotation[] }
```

The reason: the item sequence is the page's cursor and the window. An
annotation arrives after the reply is final, so a field on the final
item would be lost on a reconnect with `after` (`transcript.ts:469`,
the `/events` replay sends only items after the cursor) and would need
a revision. As an item it is in the sequence, the window and the
`/items?before` page like a job notice. The transcript resolves
`reply.at` and `reply.block` to the assistant item's `seq` and the
block index at the edge, checks `length` against the block's text,
drops unknown types and bad spans, and creates no item when nothing
is left. An entry whose reply is not in the items (another branch, a
reply before the window of a compaction) creates no item.

- Live: a new `annotation(entry: unknown, at: number)` method takes the
  `entry_appended` payload. `koa.ts` calls it from the `event` switch
  (`koa.ts:234`) for `entry_appended` with `entry.type === "custom"`
  and the contract's `customType`.
- Replay: `rebuild` (`transcript.ts:386`) takes the custom entries of
  the session beside the messages, interleaved by time as the notices
  are (`:400-403`). `koa.ts`'s `rebuild` (`koa.ts:193`) sends
  `get_entries` with `get_messages` and passes the `custom` entries of
  the contract's type. `get_entries` returns every branch; an entry of
  another branch matches no reply and is dropped, as above.
- The guards follow `agentDetails` and `jobEnd` (`transcript.ts:95-120`):
  shape checks on `unknown`, nothing parsed from text.

**The page** (`share/koa/page/page.ts`). The annotation item has no
view of its own: `put` (`page.ts:349`) records it in a map `reply seq
→ annotation items`, hides its wrapper as `reconcileJobs` hides a
joined job item (`page.ts:114`), and renders the reply's text block
again with the annotations; a reply that arrives after its annotation
(a window cut, `older()`) reads the map when it renders.

*Spans over the rendered Markdown.* The page's Markdown renderer
(`page/markdown.ts`) lexes the source into marked's top-level tokens;
the concatenation of their `raw` is the source (checked on marked
18.1.3), so each token's source offset is the sum of the earlier raws.
The renderer takes a second argument, the marks: a sorted list of
`{ offset, mark }` in UTF-16 units of the block's source (the page
converts the contract's code points once per text block). Before a
token's raw is parsed, the marks inside it are inserted as the
sentinel characters U+E010 (option start), U+E011 (option end) and
U+E012 (question end, with the question's index) at their offsets.
marked passes a private-use character through as text. After the
template parses the HTML, a `TreeWalker` over the text nodes finds the
sentinels, splits the text nodes, wraps the run between an option's
sentinels in `<button class="ann-opt">` and inserts the controls
element after a question's end sentinel. This is the TUI's own
technique (`extension.ts:321-341`, `:174-191`) on the DOM instead of on
rendered lines, so the two renderers share one rule for where a
sentinel can fall: an offset is a kept character of the normalized
text, never inside a delimiter run or a URL, and a range grows over a
code span. The block memo stays: a token renders again only when its
raw or its marks changed, so an annotation renders the blocks it
touches once, and a stream never carries marks (annotations exist only
for a final reply). Question text is not styled, as in the TUI.

*Controls.* The labels follow the TUI (`extension.ts:333-336`): `open`
gets `Answer`; `yes_no` gets `Yes`, `No`, `Other`; `choice` gets its
options in place and `Other`, and `Yes` and `Other` with one option.
Their look, their hover and the spacing after a question are the
design agent's mockup; the page follows it. An option inside a list
item, a table or a heading renders where the text is.

*Click to composer.* A new module `page/answers.ts` holds one pure
function `answer(current: string, quote: string, answer: string,
overwrite: boolean): string`, the TUI's rule (`extension.ts:348-360`):
the quote is the question's Markdown reduced as `extension.ts:312-320`
reduces it, the block is `> ` + each quote line, a blank line and the
answer; a block with the same quote has its answer replaced when the
answer is non-empty or the label is `Other`; else the block is appended
after a blank line. `Yes` and `No` carry their word; `Other` and
`Answer` carry an empty answer and `Other` overwrites. The page calls
`editor.setText` (`page/composer.ts`), which puts the cursor at the
end. The user edits and sends as usual; a click sends nothing.

**Unknown and stale.** The transcript drops what it does not know at
the edge, so the page never sees an unknown annotation or a stale
span; the page's only defensive rule is the map lookup for a missing
reply.

**Cost.** One `get_entries` per rebuild, in parallel with
`get_messages`; one small item per annotated reply; the re-render of
the touched blocks once.

## pi-infer-questions' side

One producer, two renderers: the TUI rendering stays in the extension
and reads the same entry. The changes, proposed here and done in that
repository:

1. `message_end` (`extension.ts:282-300`) analyses the untrimmed block
   text, or adds the trimmed prefix's length to every offset, so the
   offsets are into the text as pi stores it; it appends
   `reply-annotations` with `reply: { at: message.timestamp, block:
   index, length: Array.from(text).length }` and the questions as
   `type: "question"` annotations. The entry no longer carries the
   Markdown.
2. The TUI renderer (`:304`) is registered for `reply-annotations` and
   gets the Markdown from the branch: a `Map<at, markdown>` of the
   assistant text blocks, filled at `session_start` from
   `ctx.sessionManager.getBranch()` and at `message_end`. `texts`
   (`:223`) stays the set of hidden texts for the transformer.
   `collapseHidden` and the mouse patches do not change.
3. A renderer that gets an entry whose `reply` is not in the map, or
   whose `length` differs, renders nothing (the message renders as
   usual, because its text is not in `texts`).
4. The README's "How it works" and docs/design.md "Rendering in pi"
   name the contract and link to Kido's document.
5. `make e2e` gains a check that the session file holds a
   `reply-annotations` entry with the expected shape for the fake
   reply, and one RPC run (`pi --mode rpc` with the fake provider and
   `-e extension.ts`) that sends `ask` and reads `entry_appended` with
   the contract's shape from stdout. The AGENTS.md rule stays: only
   `make smoke` and `make e2e`, no unit tests.

Nothing of the native module or the pipeline changes. The guide and
its entry do not change.

## Failure and absence

- The extension is not installed in koa's pi, or its platform package
  is absent, or the models fail to load: no entry, the page shows the
  reply as today. pi-infer-questions notifies once at `session_start`
  (`:219`), which koa shows as a notice line (`koa.ts:308`).
- The model is still loading when the first reply ends:
  `native.questions` waits, off the JavaScript thread; the entry comes
  when it is done.
- An aborted or failed reply, or a reply that ends in a tool call: no
  entry (`:284`).
- koa's page is open on another session's epoch: a `reset` carries the
  annotation items in the window.

## Units of work

**Unit A, Kido, the contract and the transcript** (small track: one
implementer, one correctness reviewer). `docs/reply-annotations.md`
(the manager writes it); `records.ts`: `Annotation`, the item kind
`annotations`, the entry's TypeScript shape; `transcript.ts`:
`annotation`, the rebuild with entries, the guards; `koa.ts`:
`entry_appended` and `get_entries`; `koa-fake-pi.ts`: `get_entries` in
the `respond` commands. Tests: `transcript.test.ts` (an entry becomes
an item live and on rebuild, in time order; a stale `length`, an
unknown `type`, an unknown `kind` and an out-of-range span are
dropped; an entry with no reply creates no item; a second entry for
the same reply replaces the first), `koa-program.test.ts` (the fake pi
emits `entry_appended` and answers `get_entries`; the item reaches
`/events` and a rebuild).

**Unit B, Kido, the page** (after the mockup; one implementer, the
correctness reviewer and the simplify reviewers). `page/markdown.ts`:
the marks; `page/page.ts`: the annotation map, the sentinel walk, the
controls; `page/answers.ts`; `page.css` from the mockup. Tests:
`koa-dom.test.ts` (the controls appear after the question, an option
click and a `Yes` click set the composer's text, a second click
replaces, `Other` overwrites with an empty answer, an annotation that
arrives before its reply attaches when the reply loads, a reply that
renders again keeps its untouched blocks), a markdown test (marks
inside a paragraph, a list item and a code span land in the right text
node; a mark at a block boundary goes into the right block), an
`answers.ts` test with the TUI's e2e expectations as cases
(`test/e2e.mjs:83-108` of pi-infer-questions), and one `KoaWebviewTests`
snapshot of a reply with a choice, a yes/no and an open question, light
and dark.

**Unit C, pi-infer-questions** (in that repository, after unit A's
document exists): the five changes above and their e2e checks. It can
run in parallel with unit B.

**Deleted.** In pi-infer-questions: the Markdown in the entry
(`Data.markdown`), the `pi-infer-questions` customType, and the
analysis of the trimmed text. In Kido: nothing; `entry_appended` was
not handled, and the `notice` fallback for custom messages stays.

## Decided (user, 2026-11-10)

None open. The user decided:

1. The name `reply-annotations` and its home `docs/reply-annotations.md`
   in Kido.
2. An annotation is an item of its own kind, placed by time, not a
   field of the assistant item: a final item never changes and the
   reconnect cursor is the last final item, so a later change to a
   final assistant item would not reach a page that reconnects after
   it; the item also enters the window and `/items?before` paging
   without a revision field.
3. Offsets in Unicode code points, as the extension documents them, not
   UTF-16 units.
4. The labels and the click rule stay the TUI's (`Yes/No/Other`,
   `Answer`, `Other` overwrites, a block per question, a second click
   replaces). The look comes from `@kido-app-design`, who mocks the
   controls next.
5. One `get_entries` round trip per rebuild: annotations are custom
   entries, not messages, so `get_messages` does not return them; the
   call reads every branch, and an entry of another branch matches no
   reply and is dropped.
6. Only a `pi: runtime` runtime and a remote host need the extension
   installed where pi runs; a routed runtime uses the host's. koa does
   not supply it.
