# koa scrolling: a tail that only grows, no floor, less state

Status: unit 1 landed (2026-11-24); its behaviour is in
[docs/design-koa.md](../docs/design-koa.md), "Runs, Markdown and
rendering" and "The scroll contract", and the sections below that
describe the floor and the shrink sources are history. Deviations
from D9 in unit 1: pi's bash message has no execution id, so the
finished row replaces the card in the frame of the reset that brings
it (no node adoption), and a finished command shows no duration.
The streaming tail's Markdown is kept a prefix of its final render
(user, 2026-11-24), which narrows C1 to the residuals that
"Runs, Markdown and rendering" lists. Unit 2 is open.

## Recommendation

Do not rewrite scrolling from nothing. Reduce it in place, in two
units. The first makes the rendering of the tail grow-only and
deletes the floor ("The invariants").

- The structure is correct and stays: a pure reducer
  (`koa/page/scroll.ts`), one measurement (`measure`), one write
  (`applyScroll`), all height changes in the frame (`tick`).
  40 reducer tests and about 70 DOM tests hold edge cases that cost
  about ten commits to find (sub-pixel scrolls, write echoes, clamps,
  elastic overscroll). A new design would find them again.
- The blank space has one source: the floor. It exists because the
  tail can shrink. Unit 1 removes the shrinks and the floor
  together.
- The remaining complexity is not the algorithm. It is that one fact,
  "the view is being placed", lives in six stores. Unit 2 makes it
  one mode.

## Review of the current implementation

### Stores

The reducer state (`State`, `koa/page/scroll.ts:11-31`) holds three
kinds and 13 common fields. They are four concerns in one record:

| Concern | Fields |
|---|---|
| Mode | `kind` `following` / `reader` / `restoring`, `anchor`, `travel`, `target` |
| "Being placed" | `positioning`, `settling` (`none`/`render`/`delivery`), `forceItem`, `pendingSend`, `restoring.waiting` (`none`/`snapshot`/`catchup`), local `force`, `instant`, `newInstant` |
| Geometry memory | `last` (five numbers), `written` (`top`, `echo`), `floor`, `threshold` |
| Unread and views | `candidates`, `lastSeq`, `filtered`, `saved`, `scope`, `generation` |

The page (`koa/page/page.ts`) holds more scroll state: the event
queue `scrollEvents` (93), `scrollDecision` and `lastMeasurement`
(217-218), `divider` and `dividerPx`, `dockHeight` (220), the
`transition` record with its three phases and its cover (101-105),
`loadingAnchor`, `readerCatchup`, `windowDirty`, the position table
(`extents`, `table`, `patched`, `mountedSpans`, `gaps`) and the
saved memory in `history.state` (2317-2323).

"Being placed" is thus decided in six places: `positioning`,
`settling`, `force`/`forceItem`, `restoring.waiting`, the page's
`transition.phase` with `commitTransition`'s predicate (151), and
`loadingAnchor`/`readerCatchup`.

### Events

`ScrollEvent` (`scroll.ts:33-47`) has 18 types. Their sources:
`wheel`, `touchmove` and keys give `input` (2379, 2391, 2397);
`onscroll` gives `scroll` (2385); the frame gives `frame` and
`layout` (467, 477); the ResizeObserver, the dock and the job log
give `layout` (1854, 1933, 2412); a fold gives `layout` with
`toggle` (739); a record gives `item` (658), `reset` (1759, 1774)
and `switch` (1809); the topic filter gives `filter` (186); history
gives `history` (228, 1852); a restore gives `restore-result` and
`catchup` (670, 1740-1743); the composer gives `submit` and
`send-result` (2270-2288); find gives `navigate` (2030); the button
gives `latest` (2401); the window gives `focus` and `visibility`.

### Writers

`scrollTop` of the live scroller has one writer, `applyScroll`
(`page.ts:625`). Two exceptions: the cover's frozen copy (129), and
`scrollBy` in a topic drag (`koa/page/topics.ts:158`), which the
reducer sees as reader input.

Content height has these writers: row render and revise
(`renderDirty`, `renderItem`), mount and unmount with the padding and
gap boxes (`windowStep`, `layoutWindow`, 1367-1368), reveal steps and
the grow animation (`tick`), folds and fence expansion, rhythm
margins, the unread divider (`applyScroll`, 596-609), the working
marks and the ending row's `hidden` (916), live bash cards (1485,
outside the position table), the `older` button, the top padding of
`.viewing` and `.with-topics`, the bottom padding `--dock-h + 8px`
(`page.css:8`, `dockResized` 1929), a width or font change
(`invalidateExtents`), and the floor's `min-height` on
`#transcript-clip` (622).

`applyScroll` runs the reducer a second time inside itself when the
divider changed (610-621), with a patched `positioning`, because the
divider depends on the decision and changes the height that the
decision used.

### Causes of the variable bottom space

The floor is `max` over every `naturalHeight` seen while following
(`scroll.ts:354-356`). `naturalHeight` is `#transcript.offsetHeight`
(`page.ts:471`, 551). It includes the estimated extents of unmounted
rows (the list's padding) and the dock padding. The floor is
therefore a maximum over values that are not the content's height.

1. **A landing sets the floor from estimates. Proven by reading and
   by the reducer; the size in a real session needs a repro.** A
   reset clears the floor and sets it again in the same call, from
   the first frame's height. That frame holds one window of measured
   rows and estimates for the rest. `windowStep` stops mounting after
   8 ms (1348) and the table changes after each measurement, so later
   frames mount more rows. A row whose estimate was too high shrinks
   the transcript, and the floor keeps the difference as blank space.
   `estimateExtent` (`koa/page/extent.ts:12`) counts every line of a
   fenced block, but a fence of more than 15 lines renders folded
   (`REVEAL.fold`, `page.ts:77`), so such rows are estimated far too
   high. The same occurs after a view or filter switch, a reload, a
   reconnect, a resize (`invalidateExtents` makes every row an
   estimate again) and a history page. The space depends on which
   rows were outside the first window: this is the inconsistency. A
   scratch run of the reducer (reset at 9000 px, next frame 8600 px)
   gives `minHeight` 9000 and 400 px of blank space that no later
   frame removes.
2. **A shrink above the view moves the content up. Proven by
   reading.** The follower writes `max(floor, natural) - viewport`
   (321). When a row above the view shrinks, that value does not
   change, so the visible rows move up and the blank space appears at
   the bottom. Without the floor the same shrink is invisible. The
   floor breaks the rule that it exists for.
3. **The dock is in the floor. Proven by reading and by the
   reducer.** The dock's height is the transcript's bottom padding. A
   dock that grows and shrinks again (a dialog, queue rows,
   attachment chips, a multi-line draft, the error line) leaves its
   peak as blank space. The DOM test "a dock that grows or shrinks"
   (`koa/koa-dom.test.ts:2220`) only grows the dock.
4. **The designed reserve. By design.** A folded run's live step
   lines that go, a revised reveal slice, merged rows and the removed
   divider leave their height until growth fills it. When the turn's
   last text is shorter than the reserve, the space stays until the
   next re-landing.
5. **The ending row. By design, constant.** A transcript that ends
   with a message has one blank row more than one that ends with a
   run (`page.ts:916`, `page.css:10`). This is a fixed difference,
   not a fault, but the user can read it as inconsistent.

Row measurement and the dock spacing are not causes by themselves:
the measured extents are correct, and the dock padding is exact. They
become blank space only through the floor.

### A filter switch that lands on an empty transcript

The path: `filterChanged` (`page.ts:172`) starts the cover and
`transcriptHistory.reload('filter')`. The response accepts the
topic's items and calls `projectTopicFilter` (183), which changes
the projection in `refreshTopicItems` (207) and queues `filter` and
one `item` event for each item. The next frame renders
(`tick`, 446), measures, and only then reduces the events (477). The
reducer chooses the saved reader, the first unread row or the bottom
(`scroll.ts:211-241`).

1. **The floor from estimates, at its worst. Proven by reading; the
   reducer run of cause 1 applies.** `refreshTopicItems` clears every
   extent (`page.ts:211`), so each row of the new projection is an
   estimate again, also a row that was measured a moment before. The
   `filter` event clears the floor and sets it from that first frame.
   One fenced block of 300 lines above the window is estimated about
   6000 px too high. When the error is larger than the viewport, the
   follower stands in the blank reserve: the rows are mounted, above
   the view, and the view shows none. The cover goes because the
   geometry is stable. This is cause 1 of the bottom space; an empty
   transcript is its large case.
2. **The first frame mounts the wrong window. Proven by reading.**
   The frame renders before it reduces the `filter` event, so
   `windowStep` (1324) uses the old mode and the old position
   (`geometry()`, 434). After a reader in a long view, the old
   position is past the end of a short topic, and the frame mounts
   only the last rows. The floor is then taken from a frame in which
   the landing window itself is estimated, which makes cause 1
   larger. The next frame mounts the correct window (642).
3. **A reset during the switch loses the `filter` event. Proven by
   reading; its visible effect needs a repro.** A reset (a
   reconnect, a restart) cancels the filter's request
   (`page.ts:1757`). It changes the projection itself and reloads the
   topic with the plain `history` transition (1766), so
   `projectTopicFilter` does not run and the reducer gets `reset`
   but no `filter`. The reducer keeps the old filter's scope, mode
   and anchor for the new projection, and saves the position under
   the wrong topic.
4. **A failed topic load. Proven by reading.** The `finally` of
   `load` (`koa/page/transcript-history.ts:83`) projects the filter
   over the loaded items only. When none belongs to the topic, the
   transcript is empty, with the error line.

5. **The floor from the old projection. Proven by reading; how
   often it occurs needs a repro.** `projectTopicFilter` only queues
   the `filter` event. Every `decide` call reduces the whole queue
   with a measurement of the DOM as it is (`page.ts:634-636`). When a
   call comes before the frame renders (window focus or blur, 2303
   and 2331; a visibility change, 2325; a scroll key, 2379; the
   ResizeObserver, 2412), the DOM is the old one: the hidden rows are
   unmounted, but the list still has the old padding, which
   `layoutWindow` (1367) writes only in the frame. The reducer clears
   the floor and sets it from that old, tall height
   (`scroll.ts:219`, 354-356). The frame then renders the short
   projection under a floor of the old height, and the follower
   writes `floor - viewport`: blank space, with the rows far above.
   In a frame without such a call the floor comes from the new
   projection, so the fault is occasional.

Not causes, as read: a superseded response is dropped without an
effect (`transcript-history.ts:72`, 83); an unread divider target
that is unmounted is requested and mounted, and one that is absent
falls back to the bottom (`scroll.ts:293-303`, 331-339); the ending
row does not depend on the filter. A stale scroll position by itself
is not a cause either: the event clears `last` and `written`, and the
browser clamps the position.

### Contract items that the code does not meet

- "Content never visibly moves when it shrinks": not met for a
  shrink above the view (cause 2), and the floor adds blank space
  that the contract does not name (causes 1 and 3).
- "A successful send resumes following": the code follows at
  `submit`, before the result (`scroll.ts:171`). A failed send
  leaves the view following.
- "A filter switch is atomic": the cover can go over a view with no
  visible row (causes 1 and 2 above), and a reset during the switch
  leaves the reducer on the old filter (cause 3).
- "One scroll owner": the topic drag's `scrollBy` writes outside the
  reducer.

Every other item of the contract agrees with the code as read. The
DOM tests were not run for this review.

## The proposed model

One mode is the source of truth. The bottom is computed from the
content in each frame; nothing is remembered about heights.

```ts
type Mode =
  | { kind: 'following' }
  | { kind: 'reader'; anchor: Anchor }
  | { kind: 'travel'; anchor: Anchor; from: number; start: number }
  | { kind: 'landing'; target: { at: 'end' } | { at: 'unread' } | { at: 'anchor'; saved: Saved } };
type State = {
  mode: Mode;
  seen?: { top: number; max: number };   // the last position: echo, clamp, direction
  latestShown: boolean;                  // the hysteresis bit
  scope: Scope; saved: Map<string, Saved>; generation: number;
  unread: { candidates; lastSeq; filtered; pendingSend?: true };
};
```

- `following`: the position is `max`. Written when focused.
- `reader`: the position is the anchor row's top minus the offset.
  Written only for a layout change or an instant placement.
- `travel`: Latest. Ends as `following`, or as `reader` on input.
- `landing`: the view is being placed. Every frame writes the
  target's position, with or without focus. No arrival makes it a
  reader. Reader input cancels it. It ends in the first frame in
  which the page reports `settled`: `at: 'end'` becomes `following`;
  `at: 'anchor'` and `at: 'unread'` become `reader`, or `following`
  when the target does not exist.
- `settled` is one field of `Measure`. It is the predicate that
  `commitTransition` has now (`page.ts:151`): nothing dirty, no
  history, catch-up or anchor load pending, no own send pending. The
  cover and the landing end on the same fact.

A landing starts at: the page's start, a reset, a view, session or
filter switch, a resize, and the user's send.

The reducer has two steps in a frame. `reduce(state, events)` needs
no row geometry and runs before the render, so the frame mounts the
window of the new mode. `place(state, measure)` runs after the
measurement and gives the one write. Now one call does both after
the render, so the first frame of a switch renders for the old mode.

The projection has one place that changes it, `refreshTopicItems`.
That place starts the landing with the scope that it shows, so a
reset during a filter switch cannot leave the reducer on the old
filter, and `filter` and `switch` become one event.

### What it deletes

- The floor: `floor`, `Decision.minHeight`, `Measure.naturalHeight`,
  the reader's part of the floor, `#transcript-clip` and its
  `min-height`.
- `positioning`, `settling`, `force`, `forceItem`, `instant`,
  `newInstant`: all are `landing`.
- `restoring` and `waiting`, and the events `catchup` and
  `restore-result` with `found: true`: the page's `settled` holds
  them. A failed load stays as one event that changes the target to
  the end.
- `last` as five numbers and `written.echo`: `seen` has two numbers.
  A resize is the page's event, not a comparison of geometry.
- `Decision.frame` `measure`: the frame always measures after its
  writes.
- The second reducer run in `applyScroll`: a divider without height
  cannot change the measurement (unit 1, decision D7).
- `scrollRollback`: a superseded switch starts a new landing.

### How each behaviour maps

| Behaviour | In the model |
|---|---|
| Follow only focused at the bottom | `following` writes `max` when focused; unfocused growth makes `reader` at the current anchor |
| Resume within 1 px, send, Latest | scroll down to `max - top <= 1`; `submit` starts `landing` at the end; `latest` starts `travel` |
| Up input with no range | no change, as now |
| Reader anchor, no write on scroll | a scroll captures `Measure.anchor`; a write needs a layout or instant cause; a clamp (from `seen`) captures nothing |
| Latest travel, hysteresis, count, fade | `travel`; `latestShown`; the count from the candidates; CSS |
| Unread, one owner | `unread` in the same state, in its own function; no rule changes |
| Atomic view and filter switch | `landing` under the cover; both end on `settled`; the landing starts where the projection changes and is reduced before the render |
| Saved views | `saved` as now; `landing` at `anchor`, with the load request as now |
| Reload and restart | the memory as now; the start is a `landing` at the end or the anchor |
| No glide, never moves down, no blank space | no animation; the follower writes the bottom; the tail only grows ("The invariants") |
| Ending row | always there in a transcript view (decision D2) |
| Measure once, images reserve | unchanged |
| Virtualization, find, copy | unchanged; `scrollWindow` reads the mode |
| History auto-load | unchanged |
| Page does not move | unchanged; CSS |
| Reveal is rendering only | unchanged |

## The invariants (user, 2026-11-24)

- **I1.** While following, nothing moves against the direction of the
  output: visible content never moves down, and no blank space
  appears at the bottom.
- **I2.** A fresh render equals the live view: after content is
  added, a switch to another view or topic and back shows the same
  transcript.
- **I3.** The simplest solution.

I2 forbids the floor and every other reserve: its space goes at a
re-landing. I1 forbids to delete the floor while the tail can still
shrink. So the rule is in the rendering, not in the scroll: **the
tail only grows, and each live state is what a fresh render gives.**
The scroll then needs no shrink case: the follower writes the
content's bottom.

A height change above the view (a remeasured row, an estimate that a
measurement replaces, the divider) does not move visible content: the
follower is pinned to the bottom and the reader to its anchor, and
the write is in the frame of the change. That needs no rule in the
rendering.

### Sources of a tail shrink while following

| # | Source | Where | Rule that makes it grow-only and equal to a fresh render |
|---|---|---|---|
| 1 | The reveal clip of the streaming block gets smaller when a later token changes the Markdown of lines that are shown | `revealStep` sets `shown` with no lower bound (`page.ts:677-681`); `revealHeight` gives the last complete unit under `shown` (`koa/page/reveal.ts:8-13`) | The clip of one tail block never decreases: `shown` is a maximum, and it is also the wrapper's minimum height while the block is the tail. See compromise C1 |
| 2 | A fresh render of a streaming item starts its reveal at zero, so the view is shorter after a switch back | `prose` makes a new reveal for a new memo (`page.ts:327`); a block's start resets `shown` (361) | A memo made by a landing, not by a live append, shows every complete unit in its first step, with no cap and no wait. The fresh view then shows the same or more, never less |
| 3 | The ending row goes at the end of a turn in a filtered view whose run is followed by hidden text | `reconcileWorking` hides `#tail-slot` when a run ends the transcript and nothing works (`page.ts:911-916`) | The ending row is always there in a transcript view (decision D2). A run that arrives is a new row above it. The start and the end of a turn change only its content, with no case. Deletes the `endsInRun` scan |
| 4 | The unread divider goes when the follower clears the unread state, and it is in the view when the reader scrolled to the bottom | `applyScroll` removes it (`page.ts:596-609`); it has 28 px of margin and a line (`page.css:193`) | The divider takes no height: it is drawn in the gap that the rows have (decision D7). Then it cannot move content, and a view with it and a fresh view without it have the same heights. Deletes `dividerPx`, the table's divider, `Row.leading` and the second reducer run in `applyScroll` |
| 5 | A `!` command's live card is open and shows its output; its final row is folded, and the card and the row come in two records | the card opens itself (`page.ts:1456`); `refreshBash` removes it on a state record (1478-1486); the item makes a new row (1206) | One shape for a running and a finished command: open, with the output in its bounded box, and the row of the same command takes the card's node. A fresh render of a finished command shows the same open row. Only the user folds it (D9) |
| 6 | The caret of a streaming text without a reveal stands on a line of its own after a list, a table or a fence, and goes when the text is final | `show` appends it to the view when the last child is not a paragraph (`page.ts:384-387`) and removes it (347) | The caret is always inside the last element that holds text, so it adds no line. In practice this is an open thinking step |
| 7 | A fence of more than 15 lines folds | `foldFence` (`page.ts:399-409`) runs at each render of the block, live and fresh, on the same text | No change. The fold only adds the bar when line 16 arrives. Not a shrink |
| 8 | A run that takes the place of the bare working row, rows that merge into a run, the rhythm margin | `run` adopts the row (`page.ts:887-895`); `reconcileRuns` empties a follower's slot (974-983); `rhythm` (1378-1407) | No change for items that arrive in order: a step joins its run at its first render, and the smaller margin comes with a new row that is larger. With rule 3 the adoption has no height to keep |
| 9 | Image and thumbnail boxes | reserved before insertion (`thumbnails`, `page.ts:686`) | No change |
| 10 | The dock gets smaller (a dialog closes, the draft is sent) | `--dock-h` is the transcript's bottom padding (`page.css:8`) | Not a content shrink: the last row stays at the dock and moves with it, as in a resize. No blank space |

Not examined to the end, to be checked by the planner of unit 1: the
row of a running compaction that its summary replaces
(`page.ts:1029`), the topic chip that a classification adds to a
message header, and the detail of a step in a run that the user
opened (`stepDetail`, `page.ts:770-803`, closes a step that loses its
detail).

### Compromises that the invariants cannot remove

- **C1. Markdown that shortens shown text.** A token can make lines
  that the user saw shorter (a link whose address arrives, a closing
  emphasis mark). Rule 1 holds the clip, and the text that follows in
  the same block normally fills it. When the block ends shorter than
  the clip, the content moves down once by the difference, some
  pixels to one line. No rule can keep I1 and I2 there: the content
  did get shorter.
- **C2. A row that leaves the view.** A pending user message that is
  classified to another topic leaves a filtered view (`visible`,
  `page.ts:201`); a topic move, an archive and a revised item do the
  same. The rows above move down by its height.
- **C3. The scrollbar's length.** Unmounted rows are estimates, so
  the scroll height after a fresh landing can differ from the live
  one. The visible rows, their positions and the bottom space are
  equal. I2 is tested on those, and on the scroll height only for a
  transcript that is mounted whole.
- **C4. Folds that the user opened.** A reset forgets them
  (`page.ts:1424`, 1757), so a view with an opened run returns
  folded. I2 is about added content, not about the user's folds;
  to keep them needs a store for each view (decision D8).

## Decisions for the user

Decided by the user, 2026-11-24:

- **D1.** No floor and no reserve; the rendering rules above.
- **D2.** The ending row is always there in a transcript view, also
  under a run.
- **D3.** Following starts at the submit, not at the success. The
  contract says so.
- **D5.** The topic drag's `scrollBy` stays outside the reducer; it
  is reader input.
- **D6.** A failed topic load keeps the filter over the loaded
  items, with the error line.
- **D7.** The divider takes no height; it is drawn in the gap
  between two rows.
- **D8.** Compromises C1 to C4 are accepted.
- **D4.** Unit 2 follows unit 1 at once. Unit 1 gives I1 and I2 and
  repairs the blank space and the empty transcript; unit 2 repairs
  the wrong first window and the reset during a filter switch, and
  makes the state simple.
- **D9.** A `!` row is open by default, running or finished, and its
  output box has a fixed maximum height (260 px now, `page.css:16`;
  the design can choose a smaller bound). The box shows the end of
  the output. A fresh render of a finished command shows the open
  row with its output. Code: the default fold of a `!` row is open,
  the self-opening of the live card goes (`page.ts:1456`), and the
  row takes the card's node. Each finished command in the history
  keeps up to the box's height; a fold by the user is forgotten at a
  reset (C4). A finished output that is shorter than the live one (a
  cut result, a cancel) makes the row shorter once, as in C1.

The visual details of D2 and D7 (the row under a run, the divider in
the 14 px gap) and the bound of D9's output box go to
`@kido-app-design` before unit 1 implements them. This is a
prerequisite of unit 1.

No decision is open.

When a unit lands, its behaviour moves from this plan into
`docs/design-koa.md`, which until then describes the code on `main`.

## Units, in order

Each unit is a koa unit (`docs/dev-koa.md`), complete by itself, and
merges into `main` when it passes. `main` stays installable: no unit
leaves a half state, and no branch is necessary. The floor and the
shrink sources go in one unit, so `main` never has a state without
the floor in which the tail can shrink.

1. **The tail only grows, and the floor goes** (prerequisite: the
   design of D2, D7 and D9 from `@kido-app-design`; planner first; the
   planner checks the three sources that this plan did not examine
   to the end).
   - Rendering, in `page.ts`, `page.css` and `page.html`: rules 1 to
     6 of the table.
   - Scroll, in `scroll.ts`: the follower writes `m.max`; `floor`,
     `minHeight` and `naturalHeight` go, and the reader's part of the
     floor.
   - Page: the `min-height` write (`page.ts:622`) and
     `#transcript-clip`, if nothing else needs its clip; with D7 the
     divider's extent code and the second reducer run
     (`page.ts:610-621`, 643).
   - Docs: the contract's shrink rule, the ending row in "Runs,
     Markdown and rendering", and "The ending row" and "The tail
     reserve" in `app/design/koa/NOTES.md`.
   - Snapshots: recorded once, at the end.
2. **One `landing` mode** (planner first). The model above:
   `landing` and `settled` replace the six stores; `seen` replaces
   `last` and `written`; the reducer runs in two steps; the
   projection change starts the landing. Unread moves to its own
   function in `scroll.ts`.

## Tests that must fail first

Unit 1 adds one monitor to the DOM test page
(`koa/koa-dom.test.ts`). While the view follows with focus and the
viewport and the dock do not change, it compares each frame with the
one before: (a) no row that is in both frames has a larger screen
position; (b) the space between the last content and the dock is
the same. A test turns it on for its scenario.

**I1**, each with the monitor:

- A reveal whose shown slice is revised to fewer lines (the scenario
  of the tests at 3585 and 3617). With the floor this passes now, so
  the test is written with the floor's deletion: it fails on the
  deletion alone and passes with rule 1.
- A filtered view whose turn ends after a run with hidden text. Fails
  on the deletion alone; passes with rule 3.
- A reader with a divider in the view who scrolls to the bottom.
  Passes with rule 4.
- A `!` command with output that ends. Fails now (the open card
  against the folded row); passes with rule 5. The I2 test of its
  end state shows the open row with its output after the switch.
- An open thinking step that ends in a list and becomes final. Passes
  with rule 6.
- A row above the view whose measurement is smaller than its
  estimate, and one that shrinks: (a) holds. Fails now: the rows move
  up and (b) fails.
- A dock that grows by a dialog and shrinks again: (b) holds. Fails
  now with the dialog's height. It replaces the body of the test at
  2220.

**I2**, each as: record the visible rows with their screen positions
and the bottom space, switch to another view (and, in a second test,
to another topic) and back, and compare.

- After each I1 scenario's end state. The reveal scenario fails now:
  the floor's space is there before the switch and not after it.
- During a stream, with the reveal behind the text: the fresh view
  shows the same rows at the same or a higher position, and no row
  less. Fails now: the tail block starts at zero. Passes with rule 2.
- A transcript that is mounted whole: also the same scroll height.
- A reset whose rows above the first window include a fenced block
  of more than 15 lines: after it settles, the bottom space is that
  of a short transcript. Fails now with the estimate's error.
- The empty transcript: an All topics view, left as a reader far
  from the top, and a topic not visited before whose rows above the
  last window include a fenced block with an estimate error larger
  than the viewport. After the cover goes, at least one row
  intersects the viewport and the last row is at the dock. Fails now:
  no row is in the view.
- The old projection's floor: a following All topics view much
  taller than the topic; the test delivers the topic's history and
  dispatches a window `blur` before it runs the frame. Fails now: the
  minimum height is the old view's height and no row is in the view.

The DOM test page has a model of layout, not CSS. The heights that
CSS gives (the caret's line, the divider in the gap, the ending row
under a run) are checked in the page's visual driver
(`koa/visual/driver.ts`) with the same monitor, on the host.

In `koa/koa-scroll.test.ts`: "following reserves transient tail
shrink" (34) becomes "a follower is at the content's bottom", and the
non-decreasing assertion of the test at 257 goes: the rendering
gives that property, not the reducer.

Unit 2 has one failing test: a reset that arrives while a filter
switch waits for its history. After it settles, the memory that
`scrollMemory` gives has the position under the new topic, and the
view is at the bottom. Fails now: the scope is the old topic. A
second DOM test records the rows that the first frame after the
switch mounts: they are the landing window, not the end of the list
for the old position. Fails now after a reader. Otherwise unit 2
changes no behaviour: the DOM tests pass without change, and each
reducer test keeps its assertions. One new reducer test: an unfocused
landing ends as `following` at `settled`, and growth after it makes a
reader.

## Risks

- **A shrink source that this plan did not find.** The monitor is the
  guard: unit 1 turns it on in every DOM test that follows a stream,
  not only in the new ones, and each failure is a source to remove,
  not to compensate.
- **Rule 1 and a clipped line.** A clip that does not decrease can
  cut a line in the middle after the Markdown changed. The planner
  checks whether the clip must then go up to the next unit.
- **Rules 3, 4 and 5 are visible changes.** They need the design
  from `@kido-app-design` and new snapshots.
- **Echo and clamp with two numbers.** The echo test, the clamp test
  and the downward test must work from `seen`. The reducer tests at
  269, 317, 328, 337 and 347 are the guard; unit 2 must keep them.
- **`settled` in a hidden page.** A hidden page runs on a 50 ms
  timer, and a turn that streams never makes the page idle. `settled`
  must not wait for the turn (the cover's predicate does not), or an
  unfocused landing never ends and the view follows without focus.
- **A send whose item never arrives.** The landing must end on
  `send-result` `handled` or `failed`, as `pendingSend` does now.
- The model is not prototyped. Unit 2's planner checks it against
  each reducer test before the implementer starts.

## Size

| Unit | `scroll.ts` | `page.ts` and page files | Tests |
|---|---|---|---|
| 1 | -25 | -60, +35 | -60, +160 |
| 2 | -95, +50 | -45, +20 | about 170 changed |

`scroll.ts` goes from 397 to about 325 lines; the state goes from 13
common fields and 3 kinds with 5 fields to 6 fields and 4 kinds; the
events from 18 to 15. No dependency is added.
