# High-performance transcript rendering for koa's page

Status: plan. Base: `origin/main` 545a7c929. Line numbers below are
of that revision. The page is `share/koa/page/page.ts`,
`markdown.ts`, `working.ts` and `page.css`; the rules it follows are
in docs/design-koa.md ("The page and koa", "The reveal", "The
working mark") and app/design/koa/NOTES.md (item 9, "Running: one
indicator", "Auto-scroll").

## 1. What the code does today, and what it costs

One frame of a streaming answer runs these steps, all on the main
thread of the WebContent process:

- **Intake renders.** `source.onmessage` (page.ts:1309) parses the
  record and calls `apply` at once; `applyPatch` (1088) calls `put`
  (728), which rebuilds the item's children, re-runs
  `reconcileRuns` (646), `reconcileWorking` (611) and `settle` (383).
  `schedule(true)` (1314) only coalesces the reveal's frame. koa
  flushes every 50 ms (`FLUSH_MS`, koa-view.ts:12), so the page
  renders 20 times a second outside the frame loop, and a frame
  that follows must lay out what intake wrote.
- **The lexer sees the whole message.** `markdown.ts:74` lexes the
  full source on each call. The memo keeps finished blocks' HTML, so
  the DOM work is per block, but the lexing is O(message) per patch.
  `linkNames` then runs a regex over each rebuilt block's HTML.
- **The reveal measures by writes and reads.** `revealStep` (420)
  writes the tail's HTML into an off-screen `measurer` and reads its
  height, twice, then `sliceEnd` (markdown.ts:42) binary-searches the
  word breaks with one write and read per probe. Each probe is a
  `remend` + lex + `innerHTML` + forced layout of the whole tail
  block: about 2 + log2(breaks) forced layouts, around 12 for a
  1000-word paragraph, each a full layout of that paragraph.
- **Other forced layouts.** `show` reads the scroll after it removes
  nodes (228). `tick` reads the height of every grown block right
  after the reveal wrote (289), then `layoutChanged` reads the
  scroll again, then the `ResizeObserver` (1549) does the same work
  after layout. `sync` (366) reads a rect for every fresh view.
  `settle` (383) walks the subtree of every fresh and waiting view
  (`visible`, 377) each frame.
- **The grow animates layout.** `.grow` (page.css:9) animates
  `max-height` and margins for 220 ms: a layout and a scroll
  correction on every one of its 13 frames, on the main thread.
- **The run rebuilds.** `reconcileRuns` serializes every step's block
  to JSON on each patch and, when the signature differs, replaces the
  run view (`replaceChildren(run(steps))`). `reconcileWorking` then
  re-places the dots, which detaches and reinserts the dots node.

The dots stutter because of the last item. In WebKit a `transform`
and `opacity` Web Animation runs in the remote layer tree (threaded
animations, WebKit 306475@main), so a busy main thread does not
stop it. A detached element has no renderer and no layer; on
reinsertion WebKit builds a new `RenderLayerBacking` and attaches the
accelerated effect again. Every patch during a tool call does this,
so the frame loop's cost sets the bounce's visible frame rate.

## 2. Prior art

- **Block memoization and tail healing** is the industry pattern:
  Streamdown memoizes per block and heals the tail with `remend`
  ([streamdown.ai/docs/memoization](https://streamdown.ai/docs/memoization),
  [vercel changelog](https://vercel.com/changelog/new-npm-package-for-automatic-recovery-of-broken-streaming-markdown));
  Incremark caches finished blocks and re-parses only the pending
  one, on marked, and reports 3.6 to 16x over Streamdown on long
  documents ([dev.to](https://dev.to/kingshuaishuai/from-on2-to-on-building-a-streaming-markdown-renderer-for-the-ai-era-3k0f));
  streaming-markdown is an optimistic state machine that only
  appends to the DOM, 3 kB, but WIP, with no setext headings or
  reference links ([github](https://github.com/thetarnav/streaming-markdown)).
  koa's memo already is Streamdown's design; it lacks the O(tail)
  lex.
- **Render per frame, not per chunk.** The benchmark
  [kocgo/how-to-handle-llm-responses](https://github.com/kocgo/how-to-handle-llm-responses)
  names rAF batching the single biggest gain, then `contain`,
  lightweight markdown while streaming, and virtualization over
  1000 words. VS Code's chat renderer is "rAF-batched, append-only":
  a `WordBuffer` reveals words at the model's implied rate (40 to
  2000 words/s, 80 words/s drain after the end) and an
  `IncrementalDOMMorpher` patches the DOM when the new markdown is a
  pure append, else re-renders
  ([wordBuffer.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/browser/widget/chatContentParts/chatIncrementalRendering/buffers/wordBuffer.ts),
  [chatIncrementalRendering.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/chat/browser/widget/chatContentParts/chatIncrementalRendering/chatIncrementalRendering.ts)).
  xterm.js parses its write buffer per event-loop turn under a 16 ms
  budget ([flow control](https://xtermjs.org/docs/guides/flowcontrol/)).
- **Measure-free text layout.** Pretext (`@chenglou/pretext`)
  predicts line breaks from canvas `measureText` without the DOM,
  but its README calls `-apple-system` unsafe on macOS and excludes
  `font-variant-numeric` and `text-wrap` variants
  ([github](https://github.com/chenglou/pretext)); koa's prose font
  is `-apple-system`. `Range.getClientRects` gives the real line
  boxes and is free when layout is clean, that is when nothing wrote
  the DOM since the last frame.
- **Containment.** `content-visibility: auto` with
  `contain-intrinsic-size: auto <estimate>` skips layout and paint
  of off-screen items, keeps them in the DOM, selectable, focusable
  and available to find-in-page, and remembers the last rendered
  size; Safari 18+ ([MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/content-visibility)).
  Chat virtualizers (TanStack Virtual's `anchorTo: 'end'`, Virtuoso's
  `followOutput`) own the anchor math and turn off
  `overflow-anchor`, as koa already does
  ([tanstack chat](https://tanstack.com/virtual/latest/docs/chat)).
- **WebKit specifics.** Only `transform`, `opacity` and some filters
  animate off the main thread; a detached or `display: none` element
  has no accelerated effect. Safari has no Long Tasks API, no
  `requestIdleCallback`, no `scheduler.yield`, no `DOMParser` in a
  worker; it has `lh`, `overflow: clip`, `OffscreenCanvas` and
  `contentvisibilityautostatechange`
  ([caniuse longtasks](https://caniuse.com/wf-longtasks),
  [Safari 18 features](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/)).
  So the harness measures with the page's own clock, not with
  observers that WebKit lacks.

## 3. Goals and budgets

- **Frames.** While an answer streams at a typical rate (100 to
  300 tokens/s, patches every 50 ms) into a 10 000-word message, with
  a loaded history of 100 000 rendered lines, the page's frame time
  p99 is under 16.7 ms and no frame is over 50 ms, in Kido.app
  (WKWebView, visible) and in headless Chrome.
- **Forced layouts.** Zero synchronous layouts in a streaming frame:
  every geometry read happens before the frame's first DOM write.
- **The dots** keep one node, one layer and the same three
  `Animation` objects for the whole turn: zero detachments while
  text streams, one move per call start or end.
- **Typing-to-paint** of the composer stays at the baseline: a key
  event paints in the next frame while an answer streams.
- **Memory.** JS heap after a 20 000-token answer stays at the
  baseline (16 MB in docs/design-koa.md); the 100 000-line history
  stays within the stress report's per-page memory budget.
- **No visible change** of the design: NOTES.md item 9, the one
  working mark, the auto-scroll states.

## 4. Unit 1: the measurement harness, and a baseline

Before any product change, one unit adds the measurements. Nothing
here is a product path; the page's metrics mode (`koa-metrics` meta,
page.ts:1276) already exists and grows.

- **A streaming stress workload** in `share/koa/stress/workloads.ts`:
  a seeded session whose items render to about 100 000 lines (the
  `long-session` generator with mixed prose, lists, fences and
  tables), then one reply of 10 000 words with the same mix,
  streamed through the fake provider at 200 tokens/s with 20 tool
  calls on the way so the dots move between spots. It runs in Chrome
  (`stress/run.ts`) and in Kido's visible mode
  (`KoaStressTests`, `KOA_STRESS_VISIBLE=1`).
- **Page-side counters** in metrics mode, flushed through
  `/metrics` as today's samples are: for each frame the duration of
  the render task and of the frame gap (`performance.now()` between
  consecutive ticks while a frame is scheduled), the count of
  geometry reads outside the read phase (the page's one read helper
  counts; in metrics mode the getters `getBoundingClientRect`,
  `getClientRects`, `clientWidth`, `scrollTop`, `scrollHeight` are
  wrapped to count a read after a write in the same task), the lex
  time per patch, dots detachments (a `MutationObserver` on `#items`
  whose removed nodes contain the dots node or an ancestor), and the
  composer's key-to-frame latency.
- **Engine-side checks in Chrome**: `Performance.getMetrics`
  (`LayoutCount`, `LayoutDuration`, `RecalcStyleCount`,
  `TaskDuration`, `JSHeapUsedSize`, `Nodes`) sampled per second,
  which validates the page's read counter; `LayerTree` events to
  confirm the dots' layer id does not change during the stream.
- **The report** (`stress/report.ts`) prints p50, p95, p99 and the
  count of frames over 16.7 ms and over 50 ms, the stray reads, the
  forced layouts, the detachments, the key latency and the heap, and
  fails above a budget once the budgets are set.
- **Acceptance.** The workload runs in both engines; the baseline
  table is appended to this plan under "Baseline", before unit 2.

## 5. Target architecture

One rule for each part. Every part fits the existing records:
`items`, `views`, `texts`, the `ScrollState` owner and `working`.

### 5.1 Intake applies, the frame renders

- `source.onmessage` parses the record and applies it to the model
  only: `items`, revisions, `after`, the annotation map. It adds the
  item's `seq` to a `dirty: Set<number>` and calls `schedule()`. It
  writes no DOM. `state` records keep their synchronous path: they
  are rare and drive focus and the composer.
- `tick` has three phases in this order: **read** (scroll geometry,
  the tail's line boxes, the grown blocks' heights, see 5.3 and
  5.5), **render** (`put` for each dirty seq in order, the reveal's
  clip, the working mark, the grow classes), **write scroll**. A read
  never follows a write in the same task. The `ResizeObserver` stays
  the one post-layout corrector for changes that are not the frame's
  own (an image that loaded, the dock, a fold, a resize).
- A hidden page gets no frames. It renders in one `setTimeout` task
  at the flush cadence, so the DOM is current when the page shows
  and the `applied` metrics of hidden Kido windows keep a meaning:
  "applied" is the model, "rendered" the DOM.
- The render phase has a budget: when a reset or an `older()` load
  brings more items than fit in 8 ms, the frame renders the newest
  screenful first and the rest in later frames, oldest last, with
  the anchor correction of 5.5 between (xterm.js's rule).

### 5.2 Markdown: lex only from the last unstable token

`markdown()` keeps its memo shape (blocks, raw, links). It gains the
offset from which the source may differ: `put` passes the old
length for a suffix patch and 0 for a replaced block.

- The lexer runs on `source.slice(start)` where `start` is the start
  of the token two before the token that contains the change: the
  containing token can grow, and the one before it can absorb it (a
  paragraph's lazy continuation, a list's next item after a blank
  `space` token, a setext underline). The slice's lexer is seeded
  with the memo's `links`; new definitions merge into it, and a
  changed definition set invalidates all blocks as today.
- The first re-lexed token must equal the kept token's `raw`; else
  the memo lexes the whole source once and counts the fallback in
  metrics. So correctness never depends on the slack.
- The tail's `html(end)` is gone with the measurer (5.3); the tail
  renders once per frame, healed by `remend`, as a whole.
- A property test in `koa-page.test.ts` feeds every fixture in
  random chunk sizes with random replaced blocks and compares the
  incremental result with a fresh render after each step, as the
  existing patch test does.

No worker: the tail's lex is far under a millisecond after this
change, `DOMParser` is not in a worker, and the HTML would still
parse on the main thread after a one-frame `postMessage` delay.
Revisit only if unit 3's numbers show lexing above 4 ms a frame.

### 5.3 The reveal clips at unit bottoms, with no measurer

The rules of NOTES.md item 9 stay: a finished block appears whole and
grows in; the tail shows by whole units (a paragraph's wrapped
lines, a fence's lines, a table's rows, a list's items); nested
blocks appear whole; the height cap at 40 % of the viewport and the
time cap at 1.5 s decide when. The mechanism changes:

- The tail block renders whole into the live DOM, inside a wrapper
  with `overflow: clip` and a `max-height` that is the bottom of the
  last revealed unit relative to the wrapper's top (0 before the
  first reveal, so the dots row stands under the revealed part).
- The read phase of each frame reads the unit boxes of the tail:
  `Range.getClientRects` over a paragraph's or a code's contents
  (grouped by line, so an inline `code` or link that splits a line
  into several rects is one unit), the children's rects for list
  items and table rows. Rects report clipped geometry, so the full
  height is the last unit's bottom. One read set, no write before
  it, no forced layout.
- A pure function `revealHeight(units, shown, cap, waitedTooLong)`
  returns the new `max-height` or none; koa-dom's reveal tests drive
  it with unit lists instead of the height model, and the tests of
  `sliceEnd` go.
- The decision lags the write by one frame: frame N writes new tail
  text under the old clip, frame N+1 reads the units and raises the
  clip. The caps already delay the reveal by far more, so the lag
  is invisible, and the `reveal` snapshot scenario, which drives the
  clock and the frame by hand, still produces a deterministic
  mid-reveal frame.
- The caret and the final render are unchanged: when the block
  completes, the wrapper goes and the block grows in as today.

The hidden part exists in the DOM for at most one time cap: a find
hit in it shows when its line reveals, and a drag selection may take
hidden text for that time. The plan accepts this one difference.

### 5.4 The grow costs no forced layout

The grow stays a layout animation (the chosen look, NOTES.md item 9).
Its height read moves to the read phase: a block that completes gets
`max-height: 0; overflow: hidden` in the render phase, the next
frame reads its `scrollHeight` (the content height under the clip)
and starts the animation with `--h`. Zero forced layouts; one
incremental layout per animated frame remains. If unit 4's numbers
show the grow's frames over budget, the fallback is a compositor
entrance (`opacity` and a 4 px `translateY`, the layout jump at
once): the user decides, because it changes the look.

### 5.5 The scroll owner reads once and writes once per frame

- The read phase takes `scrollTop`, `scrollHeight`, `clientHeight`
  and, in `reader`, the anchor row's top. The write phase sets
  `scrollTop` once. `layoutChanged` at the end of `tick` goes: the
  frame's own writes reach the `ResizeObserver`, which runs after
  layout, reads nothing that forces one, and corrects once.
- `readScroll()` after node removal (page.ts:228) goes. The clamp
  rule (docs/design-koa.md, "Reader input and clamps") moves to the
  observer: removals happen in the render phase, the next scroll
  event or observer call sees the clamped position and compares it
  with `accepted` and the new maximum, which is the same decision one
  layout later.
- `captureAnchor` runs only on reader input and on a view switch, on
  clean layout.
- `sync`'s "N new" count stops reading a rect per fresh view: an
  `IntersectionObserver` with `#scroll` as root tracks which fresh
  views are below the viewport, and the label updates in its
  callback.

### 5.6 The dots are never detached

- Rule: **a node that hosts a compositor animation is never
  detached by a rebuild.** `run()` builds a run view once; later
  patches update it in place: the summary's names and error class,
  the time, a step's outcome and time, new step rows appended, the
  `live` flags. The `RunMarks` record keeps the nodes to patch. The
  dots move only when their spot changes (a call starts or ends), by
  one `insertBefore`.
- `reconcileRuns` keys a run by its first step and decides "changed"
  from the items' revisions, not from a JSON signature of every
  block. The rescan over the assistant sequence stays, it is O(items
  of one turn).
- The working row and the indicator keep today's record `working`.
  Nothing else changes in `reconcileWorking`.

### 5.7 Off-screen items are contained; virtualization waits

- Every item row gets `content-visibility: auto` and
  `contain-intrinsic-size: auto <estimate>`, with the estimate from
  the item's data (its line count times `1lh`; a folded run one
  `lh`). A rendered item then remembers its size, so the scrollbar
  does not jump after a scroll through history.
- Reader anchors are rows, which keep their boxes when skipped;
  `captureAnchor` and `restoreAnchor` are unchanged. Quick Look's
  handlers sit on nodes that stay in the DOM. Find-in-page reaches
  skipped content by the spec; a `KoaWebviewTests` test finds a word
  in an item ten screens up and checks that the view scrolls to it
  and renders it, in WebKit. If WebKit fails that test, the fallback
  is `contain: layout paint` on rows without skipping, and this plan
  reopens virtualization.
- Virtualization of the DOM (a window of rows, as Virtuoso and
  TanStack do) is not in this plan: the history window caps already
  bound the loaded items, containment bounds their layout, and a
  window would remove the rows that find, selection, anchors and
  Quick Look use. It becomes a unit only if unit 5 misses the
  100 000-line budget with containment.

### 5.8 New-item accounting from data

`arrive` decides from the item whether it is new (an assistant item
with text or a shown step, NOTES.md "New items"), at `put` time, not
from a subtree walk. `settle`'s `visible` walk and the `waiting` map
go; the divider's placement stays a render-phase write.

## 6. What to delete

- `measurer`, `.measure` (page.css:11), `Reveal.measured`,
  `sliceEnd`, `Tail.html`, the `html(end)` re-lex path and the
  binary search in `revealStep`.
- `readScroll()` after removals in `show`; `layoutChanged()` at the
  end of `tick`; the `--h` read in `tick` (moves to the read phase).
- `visible`, `waiting`, `settle`'s walk; the rect loop in `sync`.
- The JSON signature in `reconcileRuns`; the full rebuild of a run
  on each patch.
- `schedule(true)` in `onmessage` (intake only marks dirty).
- The `koa-dom.test.ts` test "applies SSE synchronously" changes to
  "applies the model synchronously and renders in the frame"; the
  reveal tests move from the height model to unit lists; the fake
  document gains `getClientRects` and `scrollHeight`.

## 7. Dependencies: none new

| Candidate | What it would give | Cost and the hand-written alternative |
|---|---|---|
| `@chenglou/pretext` | Line breaks without the DOM | Unsafe with `-apple-system`; no `font-variant-numeric`; a second layout engine to keep equal to WebKit's. 5.3 reads the real line boxes for free. |
| `streaming-markdown` | Append-only DOM tail, 3 kB | WIP; no setext headings, reference links or table alignment; a second renderer beside marked for user text and `markdownLine`. 5.2 is about 40 lines on marked. |
| Incremark | O(n) blocks on marked | Vue, React and Svelte components; koa has no framework. |

`marked` and `remend` stay.

## 8. Risks

- WebKit's find-in-page over `content-visibility: auto` is tested in
  unit 5; the fallback is named in 5.7.
- The clipped tail is in the DOM for up to one time cap (5.3).
- The incremental lex trusts marked's block starts at token
  boundaries; the equality check of the first re-lexed token and the
  property test guard it, and a mismatch costs one full lex.
- The one-frame lag of the reveal and of the grow's height read
  changes which frame a test sees; the replay scenarios drive the
  clock and the frames, so they stay deterministic, but the `reveal`
  snapshots may need one recording.
- `KoaStressTests` hidden workloads wait on `#items` text; the
  hidden-page render keeps it current within a flush.
- A skipped row has its estimated box until it renders; the anchor
  correction runs after layout and tolerates it, and the scrollbar
  moves by the estimate's error once per row.

## 9. Units and acceptance

Each unit is a product change with a manager, a planner and one
implementer, except unit 1, which is tooling plus page metrics.
Each unit runs the stress workload before and after and reports the
table.

1. **Harness and baseline** (section 4). Done when both engines
   produce the report and the baseline is in this plan.
2. **Intake per frame, read and write phases, dots never detached**
   (5.1, 5.5, 5.6). Done when, over the workload: stray reads are 0
   in streaming frames except those that unit 4 moves (the grown
   blocks' heights and the notices' fits after writes outside a
   frame), dots detachments are 0 between call transitions, Chrome's
   layouts per frame during streaming drop (7.4 before; 4.2 after),
   and key-to-frame latency equals the baseline. Done.
3. **Incremental lex** (5.2). Done when the lex time per patch at
   10 000 words is under 1 ms in both engines and the property test
   passes over every fixture. Open finding from unit 2: Kido's
   flush-to-frame p99 is 254 ms with no apply and no frame over
   16.7 ms; find its cause. Done: see "Unit 3" under "Baseline"; the
   cause is in WebKit, and the proposed fix is unit 5's.
4. **Reveal by clipping, grow without a forced read** (5.3, 5.4).
   Done when forced layouts per streaming frame are 0 in Chrome's
   metrics, the `reveal` and `dots` snapshots show the same look,
   and frame p99 is under 16.7 ms with the 10 000-word reply alone.
5. **Containment and data-driven new items** (5.7, 5.8). Done when
   Kido's flush-to-frame p99 is under 100 ms and its request-to-rAF
   max under 250 ms over the stress workload (unit 3 traced the tail
   to WebKit rebuilding style and layout for the whole history after
   a memory-pressure release), and when frame p99 is under 16.7 ms with the 100 000-line history, the
   WebKit find test passes, the reader-anchor tests pass, and memory
   is within the report's budget.
6. **Time-sliced history render** (5.1, last point). Done when no
   frame of a reset or an `older()` load is over 50 ms with the
   100 000-line history. It merges into unit 5 if unit 1's baseline
   shows the load under budget already.
7. **Optional: append-only tail DOM** (VS Code's morph). Only if unit
   4's numbers show the tail's re-layout as the top cost: patch the
   tail's last text node when the new HTML is a pure append of the
   old. Done when the tail's render time per frame halves.

Docs that move when the units land: docs/design-koa.md "The reveal"
(slices by clip, the read phase), "The page and koa" (intake and the
frame, containment), "Measurement" (the counters); NOTES.md item 9's
sentence about the raw-text slice. The plan is deleted then.

## Baseline

Unit 1, on `origin/main` 08cfda34a, macOS 27.0, Mac17,6 (Apple M5
Max), `share/koa/stress/run.sh stream`, run `run-DGOt4w`. The machine
ran other agents: the load average was 28.4/27.0/24.6 at the start
of the Kido leg and 39.3/20.8/19.4 at its end, so the Kido numbers
are noisy. Timings come from the `frame` pass, counts from the
`probe` pass. WebKit's clock is coarse, so Kido's values are whole
milliseconds.

| metric | headless Chrome | Kido, visible |
|---|---|---|
| frames | 764 | 710 |
| frame task ms p50 / p95 / p99 | 0.9 / 2.8 / 4.0 | 11 / 15 / 22 |
| frame task, probe pass, p50 / p95 / p99 | 1.5 / 3.0 / 3.8 | 14 / 31 / 39.5 |
| frames over 16.7 / 50 ms | 0 / 0 | 24 / 0 |
| frame gap ms p50 / p95 / p99 | 24.5 / 25.3 / 25.4 | none: no tick chained |
| apply ms p50 / p95 / p99 | 0.3 / 4.8 / 5.7 | 0 / 1 / 7 |
| applies over 16.7 / 50 ms | 0 / 0 | 3 / 3 |
| flush to frame ms p50 / p95 / p99 | 17.8 / 48.9 / 76.7 | 33 / 80 / 421 |
| lex ms, whole stream | 65 | 205 |
| key to frame ms p50 / p99 | 8.9 / 28.2 (CDP keys) | 6 / 38 (synthetic) |
| stray reads in frame / apply / other | 2464 / 1561 / 1655 | 2407 / 718 / 3064 |
| stray reads per frame | 3.2 | 3.7 |
| dots removals at calls / while text / at end | 40 / 43 / 1 | 40 / 43 / 1 |
| Chrome layouts, total / per frame | 5658 / 7.4 | n/a |
| Chrome layout s / style recalcs / task s (of 53 s) | 6.1 / 5905 / 51.6 | n/a |
| heap max / per-page memory MiB | 52.6 / 25.7 | n/a / 1509.6 |
| DOM nodes at end | 350 252 | n/a |

Findings that shape the next units:

- Chrome's main thread is busy for almost the whole stream (51.6 s
  of task time in 53 s), but the page's frame task is short: the
  cost is style, layout and the intake outside the frame, and the
  frames chain at about 40 per second, not 60.
- In Kido no tick schedules the next one: every frame comes from an
  intake, 27 to 125 ms apart, and the flush-to-frame p99 is 421 ms.
- The working mark is removed 43 times while text streams, in both
  engines, against the goal of zero.
- The stray-read counter sees about 3 reads per frame against
  Chrome's 7.4 layouts per frame, of which about one is the frame's
  own layout.
- Headless Chrome does not composite the dots, so the layer-id check
  has no layer to follow there; the dots' detachments are the
  measure in both engines.

Unit 2, on `origin/main` 358c8ecaf with unit 2's change, the same
machine, `share/koa/stress/run.sh stream`. Before: Chrome is the
unit 1 column above (the Chrome leg of the before-run ran against a
stale page build, which `run.sh` now rebuilds first); Kido is run
`run-hEHt9m` on 358c8ecaf. After: run `run-34ykXJ`. Load average
about 7 during both runs.

| metric | Chrome before | Chrome after | Kido before | Kido after |
|---|---|---|---|---|
| frames | 764 | 1466 | 760 | 1356 |
| frame task ms p50 / p95 / p99 | 0.9 / 2.8 / 4.0 | 1.8 / 2.6 / 3.0 | 10 / 13 / 16 | 6 / 9 / 10 |
| chained ticks | 2 | 737 | 0 | 739 |
| frame gap ms p50 / p95 / p99 | 24.5 / 25.3 / 25.4 (n=2) | 16.8 / 20.4 / 24.1 | none | 32 / 41 / 48.2 |
| applies over 16.7 ms | 0 | 0 | 1 | 0 |
| flush to frame ms p50 / p95 / p99 | 17.8 / 48.9 / 76.7 | 14.8 / 45.6 / 60.0 | 35 / 89 / 431 | 22 / 58 / 254 |
| key to frame ms p50 / p99 | 8.9 / 28.2 | 10.7 / 20.2 | 9 / 74.9 | 6 / 20 |
| stray reads in frame / apply / other | 2464 / 1561 / 1655 | 57 / 0 / 1078 | 2629 / 724 / 3958 | 80 / 0 / 758 |
| reveal probe reads in frame | counted as stray | 1448 | counted as stray | 1388 |
| dots removals at calls / while text / at end | 40 / 43 / 1 | 0 / 0 / 1 | 40 / 23 / 1 | 0 / 0 / 1 |
| Chrome layouts total / per frame / per flush | 5658 / 7.4 / n/a | 6184 / 4.2 / 7.5 | n/a | n/a |
| per-page memory MiB | 25.7 | 25.6 | 1485.8 | 756.3 |

- The dots' removals while text streams came from new item rows:
  `put` appended a new row after the working row, and
  `reconcileWorking` then appended the working row again, which
  detached the dots. A new row now goes in before the working row.
- The 57 and 80 stray reads that remain in frames follow writes
  outside the frame, by source: the composer's keys, `state`
  records and unlabelled writers. They are the reads of the grown
  blocks' heights and of the notices' fits; unit 4 (5.4) moves the
  height read.
- Chrome's layouts per frame drop from 7.4 to 4.2. Per flush they
  stay at about 7.5, because the frames now chain at the display
  rate and each lays out; so unit 2's target is per frame. The
  reveal's probes are about 1.7 per flush.
- Kido chained no tick before because the reveal re-dirties only
  when a slice is revealed; most frames came from intake. Its
  flush-to-frame tail came from apply tasks of 424 to 470 ms, which
  intake no longer has. The remaining tail (p99 254 ms) has no
  apply over 16.7 ms and no frame over 16.7 ms; the cause is not
  attributed, and unit 3 takes it as an open finding.

Unit 3, on `origin/main` 7febbc263 with unit 3's change, the same
machine, `share/koa/stress/run.sh stream`. Before: run `run-YIDPCd`
(load average 20 to 25). After: run `run-IDNzmm` (load average 7 to
11). The workload now ends with one reply of 10 000 words after the
21 short replies, so the after-run streams twice as long and its
totals do not compare with the before-run; the rates and
percentiles do. The before-run has no per-render lex counter; its
row comes from the same reply rendered under Node with the old and
the new `markdown.ts`, patch by patch, at 9 000 words or more.

| metric | Chrome before | Chrome after | Kido before | Kido after |
|---|---|---|---|---|
| lex ms per patch at 9 000+ words, mean / p99 / max | Node: 1.53 / 4.49 / 7.08 | 0.0 / 0.1 / 0.2 (n=74); Node: 0.012 / 0.031 / 0.037 | n/a | 0.1 / 1 / 1 (n=74; 67 at 0 ms, 7 at 1 ms of WebKit's 1 ms clock) |
| incremental lex fallbacks | n/a | 0 | n/a | 0 |
| frame task ms p50 / p95 / p99 | 2.1 / 3.1 / 3.8 | 2.4 / 3.5 / 4.3 | 8 / 16 / 38.7 | 8 / 11 / 13 |
| frames over 16.7 / 50 ms | 1 / 0 | 1 / 0 | 52 / 8 | 2 / 0 |
| flush to frame ms p50 / p95 / p99 | 17.3 / 49.7 / 73.3 | 18.9 / 58.4 / 81.3 | 32 / 228 / 599 | 28 / 67 / 197 |
| flush write to receive ms mean / p99 / max | n/a | 18.0 / 74.3 / 142 | n/a | 22.6 / 135 / 502 |
| frame request to rAF ms mean / p99 / max | n/a | 4.2 / 26.0 / 107 | n/a | 27.5 / 480 / 571 |
| rAF to tick done ms mean / p99 / max | n/a | 2.3 / 5.0 / 21.1 | n/a | 8.0 / 14 / 19 |
| key to frame ms p50 / p99 | 9.7 / 25.2 | 10.5 / 27.1 | 13 / 171 | 12 / 26 |
| dots removals at calls / while text / at end | 0 / 0 / 1 | 0 / 0 / 1 | 0 / 0 / 1 | 0 / 0 / 1 |

- The lexer now sees only the end of the message: under Node, the
  lex per patch at 10 000 words drops from 1.5 ms to 0.012 ms on
  average. Both engines are under 1 ms; WebKit's clock reads whole
  milliseconds, so its mean is the useful figure.
- The flush-to-frame tail in Kido is not the page. Each flush
  marker now has an id, and the page stamps its receipt and the
  request and start of the frame. Kido's long markers come in
  bursts: a requested rAF does not fire for 450 to 990 ms, no
  `onmessage` runs in that time, and then the queued flushes arrive
  together. The page runs no task in that time. Stack samples of
  WebContent (`spindump`, two runs) over a 542 ms stall and a
  523 ms stall show `Document::resolveStyle` in 49 of 55 and 46 of
  53 samples, and `LocalFrameViewLayoutContext::performLayout` in 31
  and 29: a style and layout of the whole history's render tree.
  Each stall comes immediately after a sample in
  `MemoryPressureHandler::measurementTimerFired` → `releaseMemory`
  (with `LayoutIntegration::LineLayout::releaseCaches`), while
  WebContent's footprint was near 1.9 GB, and it drops to about
  1.3 GB after it. The app's main thread is idle in `mach_msg` during
  the stall, and no sync IPC waits; the test's synthetic keys are
  asynchronous. So WebKit releases its layout caches under memory
  pressure, and the next rendering update rebuilds style and layout
  for the 350 000-node document. The fix is unit 5: containment and
  keeping off-screen history out of the render tree lower both the
  footprint that causes the release and the cost of the rebuild.
  A proposal for the user: unit 5's acceptance adds Kido's
  flush-to-frame p99 and request-to-rAF max.

