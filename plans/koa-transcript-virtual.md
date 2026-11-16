# Virtualizing koa's transcript DOM

Status: plan. Base: `origin/main` 223361541. Line numbers below are
of that revision. The page is `share/koa/page/page.ts` and
`page.css`; the rules it follows are in docs/design-koa.md ("The
page and koa", "Frames", "Scroll") and app/design/koa/NOTES.md
("Auto-scroll, the "new messages" divider and "↓ Latest""). The
evidence is plans/koa-transcript-perf.md ("Baseline", units 1 to 5).

## 1. Why

After unit 5 (containment) the page misses its targets on workload
13 (a 100 000-line history and one streamed reply): flush→frame p99
135 ms against 100, request→rAF max 432 ms against 250, 1.2 GB per
page. Unit 3 traced the tail to WebKit: under memory pressure it
releases its layout caches and the next rendering update resolves
style and lays out the whole 350 000-node document. Small against
big session (workloads 14 and 13): request→rAF p99 18 → 119 ms
while the page's own render task stays at 1 ms; Chrome's layout
time 0.96 → 10.6 s for the same layout count. So the cost of each
style and layout pass grows with the retained DOM, and containment
does not cut it: a skipped box keeps its nodes, its style and its
memory. The only lever left is the size of the DOM: keep in it only
what the viewport can show.

## 2. Prior art, only what changes the design

- **The measurement cache and the keyed anchor.** TanStack Virtual
  (`anchorTo: 'end'`) and react-virtuoso (`followOutput`) keep a
  size cache keyed by item, estimate unmeasured items, and correct
  the scroll from a keyed item's position after each change. koa
  already has the keyed anchor (`Anchor`, page.ts:64) and the
  correction after layout (`layoutChanged`, page.ts:397); the cache
  is new.
- **The streaming tail stays in the DOM.** VS Code's chat list
  unmounts finished turns and keeps the live one mounted. koa's rule
  "a node that hosts a compositor animation is never detached"
  (perf plan 5.6) becomes "a live row is never unmounted".
- **Find runs over the model.** VS Code intercepts Cmd-F in its chat
  pane, searches its turns in memory, reveals the item, then
  highlights in the mounted DOM. Zed searches its text buffer. Slack
  and Discord leave the browser's Cmd-F limited to mounted rows and
  offer app search. koa takes VS Code's way: the page finds, WebKit
  highlights (section 4).
- **Selection.** No chat virtualizer makes a selection across
  unmounted rows work; they bound the selection to what is mounted.
  koa does the same, with one addition (section 5).

## 3. The window

### 3.1 The model is the source of truth; the DOM is a window

Today `items` (page.ts:41) holds every loaded item and `views`
(page.ts:42) holds one rendered row for each of them, forever.
`renderItem` (page.ts:841) appends a new row at its sequence
position (page.ts:891-892). After the change:

- `items` is unchanged. `views` holds only the **mounted** rows.
  `rowOf` (page.ts:357) returns `undefined` for an item that is
  loaded but not mounted; every caller that today reads "row gone"
  from it is listed in 3.5.
- A new record, the **position table**, is the one place that knows
  where each loaded row stands:

      type Extent = { kind: 'measured'; width: number; px: number } | { kind: 'estimated'; px: number };
      const extents = new Map<number, Extent>();   // by seq; the divider has its own entry (3.6)

  An item's **extent** is the distance from its row's top to the
  next row's top: its border box plus the margin that collapses
  between the two rows. It does not depend on the row's own
  `margin-top`, so it is the same mid-list and as the first child.
  The last mounted row before a spacer uses its border box.
- The mounted set is **one contiguous range of sequence numbers**,
  the window, plus the **live tail** (3.3). `#items` holds, in
  order: `padding-top` for the absent rows above the window, the
  window's rows, one `.gap` element for the absent rows between the
  window and the live tail (hidden when the two are adjacent or
  merged), the live tail's rows, and `padding-bottom` for the absent
  rows below (none while the tail is the end). Padding, not spacer
  rows, above and below: a margin never collapses through padding,
  and the existing rule `#items>:first-child{margin-top:0}`
  (page.css:173) then zeroes the first mounted row's margin, which
  the extent arithmetic needs. The `.gap` is one box with no
  margins; the first tail row's `margin-top` stands under it, so
  the tail sits one collapsed margin (14 px) below its true
  position while the gap exists. The reader never sees it: the gap
  exists only while the tail is out of the viewport, and when the
  window grows into the tail the gap goes and the anchor correction
  (3.4) absorbs the 14 px below the anchor, which by NOTES.md's rule
  moves nothing.

### 3.2 Heights: measured once, estimated before

- **Measured.** Every mounted row is observed by `layoutObserver`
  (page.ts:1647) with a new `Watch` case `{ type: 'row'; seq }`
  (the union at page.ts:47). In `resized` (page.ts:1648), after
  layout and before any write, the callback reads `offsetTop` of
  each mounted row once, in order, and stores the differences as
  measured extents with the current width of `#items`. These reads
  force no layout: the observer runs on clean layout. An unmounted
  row keeps its last measured extent. So the scrollbar does not move
  when a row that was shown scrolls out and in again.
- **Estimated.** A row that was never measured at this width gets
  `estimateExtent(item, lh)`: a pure function of the item's data in
  a new module `share/koa/page/extent.ts`. The rule is today's
  `estimate` (page.ts:224-229) with the margins added: an assistant
  text block `lines × lh`, a user row `lines × lh + 16 + 14`, a run,
  a notice, an agent line or a job line `lh + 2 + 14`, an annotations
  item 0 (its row is hidden, page.ts:881). `lh` is the computed line
  height of `#items`, read in the observer callback with the width.
  `estimateExtent` is unit-tested in `koa-page.test.ts`; the DOM
  write of `--estimate` goes.
- **Width.** The `#items` entry of the observer carries the new
  width. A new width marks every measured extent as stale (its
  `width` differs); mounted rows arrive in the same callback with
  their new sizes and are measured again at once; unmounted rows
  fall back to their estimate until they mount. A font change
  (`ko-theme`, WebviewPaneView.swift:493) changes `lh` and the width
  of the text, so it takes the same path through the observer.
- **Images, folds, grows.** They change a mounted row's size; the
  row's own observer entry re-measures it. The special `fit` and
  `hold` watches stay as they are (page.ts:1655-1656).

### 3.3 Which rows are mounted

A pure function in `extent.ts`:

    windowOf(order: number[], extents, top: number, viewport: number, overscan: number): { from: number; to: number }

walks the table from the top and returns the first and last seq
whose span touches `[top − overscan, top + viewport + overscan]`.
The overscan is one viewport. The frame recomputes the window only
when the viewport's edge comes within half an overscan of the
window's edge (a `windowDirty` flag that the scroll handler at
page.ts:1640 sets from the table, no DOM read), on a reset, on an
Older load, on a view switch and on a width change.

The **live tail** is the range from the first item that holds a live
mark (`liveMarks`, page.ts:53), a reveal (`revealing`, page.ts:56),
a held or growing block (`growing`, `measuredHolds`, page.ts:61) or
the working row, to the last loaded item. A live row is never
unmounted: the dots keep their node and their layer (perf plan 5.6),
the reveal keeps its wrapper and its observer, the grow finishes.
When the turn ends the tail set empties and those rows become
ordinary window candidates.

A **job group** (`JobGroup`, page.ts:18; `reconcileJobs`,
page.ts:174) renders all its items into the first item's row; the
later items are empty rows with extent 0. `windowOf` extends a range
whose edge falls inside a group to the group's first item, so a
group is mounted whole or not at all.

**Mount** is `renderItem` from `items`: the row, its prose memo, its
handlers. The `texts` memo of a finished item (page.ts:49) is
dropped on unmount: the memos are the retained DOM. Two pieces of
per-row state that today live in the memo move to keyed maps so a
fold survives a remount: `memo.open` (the opened fences,
page.ts:48, 285-289) becomes `openFences: Set<string>` keyed
`seq:index.ordinal`; `folds` (page.ts:44) already is keyed. A run's
`RunMarks` (page.ts:51-53) are rebuilt by `reconcileRuns` on
remount; `liveMarks` holds only live runs, which are never
unmounted. A mount in a frame has the render budget of perf plan
5.1: 8 ms, the rows nearest the viewport first, the rest in the next
frame with the correction between.

**Unmount** removes the row, deletes it from `views`, unobserves it,
keeps its extent. A row that is inside a non-collapsed selection is
not unmounted (section 5).

### 3.4 The scroll owner and the window

The window follows the scroll owner (`ScrollState`, page.ts:66),
never the raw scroll position:

- **Following.** The window is the end: `windowOf` with `top =
  total − viewport`. The tail is mounted by construction. The frame
  writes the bottom before the paint as today (`stick`, `writeTop`,
  page.ts:315, 350), so following stays instant: a mount above the
  viewport changes `padding-top` and the mounted height by amounts
  the table already knows, and the observer's correction
  (`layoutChanged`, page.ts:1665) fixes a measured-against-estimated
  difference after layout, before paint.
- **Reader.** The anchor is an item and an offset (page.ts:64). The
  viewport's top in table coordinates is `pos(anchor.item) −
  anchor.offset`; `windowOf` runs from there. **The anchor is always
  a mounted row.** When a scroll lands in absent rows (a scrollbar
  drag of ten screens), `readScroll` (page.ts:387) still calls
  `captureAnchor` (page.ts:358), which finds the first mounted row
  below the viewport, a geometrically correct but far anchor; the
  frame's window step then mounts the rows at the table's position
  of the viewport top and re-anchors to the mounted row that
  contains it, from the table, with no DOM read. As those rows
  measure, `restoreAnchor` (page.ts:373) keeps the anchored row
  fixed, so the scrollbar's position may move by the estimate's
  error, once per row, as TanStack's does.
- **Restoring.** `restore` (page.ts:1252) loads older pages until
  the anchor's item is **loaded** (`items.has`, not `rowOf`,
  page.ts:1260), sets `reader` and requests the correction; the
  frame's window step mounts around the anchor at its table
  position; the correction applies the offset. The view-switch save
  (`leaveView`, page.ts:1239-1249) is unchanged.
- **"↓ Latest"** (`travelFrame`, page.ts:472) animates `scrollTop`
  toward `geo.max`, which includes the padding; while it travels the
  window follows the moving viewport top like a reader's scroll.
- **Older.** `older()` (page.ts:1440) prepends loaded items as
  estimated entries of the table, which grows `padding-top`; the
  reader's anchor holds through the same correction as today. The
  trigger `scrollTop < 80` (page.ts:1640) is unchanged: `scrollTop`
  is the real position.

`captureAnchor`'s binary search over `#items` children (page.ts:358-
372) skips the `.gap` as it skips the divider: `itemOf`
(page.ts:356) returns `undefined` for both.

### 3.5 Callers that read "no row" today

- `restoreAnchor` (page.ts:376-383): a missing row means "removed"
  and moves the anchor to the next row. It now distinguishes
  `items.has(seq)`: loaded but unmounted sets `windowDirty` and
  returns; removed keeps today's rule.
- `restore` (page.ts:1260): `items.has`.
- `arrive` (page.ts:449-459) and `settle` (page.ts:443-448) use
  `views.get(seq)?.view` for the divider's placement; they use the
  table instead (3.6).
- `restore`'s arrivals loop (page.ts:1263) iterates `views`; it
  iterates `items`.
- `rescopeImages` (page.ts:1266) walks mounted thumbnails; an
  unmounted row re-renders with the current session on mount.
- `refreshAgentCards` (page.ts:147) re-renders mounted cards; an
  unmounted card renders fresh on mount.

### 3.6 The divider and the "N new" count

The divider (page.ts:71, `.newmsgs`) is one entry of the position
table with a fixed extent (`lh + 28`), placed before the lowest
fresh seq (`fresh`, page.ts:72). It mounts with the row it precedes
and unmounts with it. `settle` places it from the table; `arrive`'s
`insertBefore` (page.ts:456) runs only when that row is mounted.

The `IntersectionObserver` of `tracking` (page.ts:414-423, `tracked`
and `below` at page.ts:73-74, `tracker` at page.ts:74) goes: an
unmounted row cannot be observed. `sync` (page.ts:424) counts the
fresh items whose table position is below the viewport's bottom
minus the dock's height (`dockHeight`, page.ts:74), a pure
computation over the table in the frame. The label and the button
are unchanged.

## 4. Find-in-page

WebKit's find sees only mounted rows, so a match in absent history
is unreachable, and `WKWebView.find` has no way to ask the page.
Decision: **the page finds in its model; WebKit shows the match.**
The rules are in app/design/koa/NOTES.md, "Find and selection on a
virtualized transcript"; this section gives the mechanism.

- koa's page exposes `window.__koFind(query: string, backwards:
  boolean): Promise<{ index: number; count: number; loading:
  boolean }>`. The matches are over the **find text** of each loaded
  item, in sequence order, within an item in block order: a user
  row's text, an assistant text block's rendered plain text (the
  markdown's tokens to text, not the source, so `**` and `#` do not
  match), a run line's and a step line's labels, a step's detail, a
  thinking step's rendered text, a folded fence's hidden lines, a
  notice's, an agent line's and a job line's text. A match in a
  collapsed run, step or fence counts. The find text is computed
  lazily on the first find after an item's revision changed and
  cached by `(seq, revision)`; a 100 000-line history costs one
  pass of the lexer, about the cost of unit 3's full lex, once.
  Case-insensitive, as `WKFindConfiguration` is
  (WebviewPaneView.swift:460-463). `count` is of the whole loaded
  model; `loading` is true while an `older()` request is in flight
  (`historyRequest`, page.ts:78), which the bar shows as
  "Searching…"; the count grows as pages load.
- The page keeps a cursor over the matches. A call moves it (with
  wrap), sets `scrolling` to `reader` with the match's item as the
  anchor at offset `viewport / 3`, mounts the window around it in
  the next frame, opens the fold that holds the match (`folds`,
  page.ts:44; `openFences`, 3.3; a thinking step's expand, which
  renders its markdown) and leaves it open, and after that frame
  collapses the DOM selection at the start of the matched block, or
  just before it for a backward search. A fold that holds a
  non-current match is not opened. The promise resolves after that
  frame, so the count, the status and the highlight change together.
- Kido.app then calls `WKWebView.find` as today
  (WebviewPaneView.swift:459): WebKit searches from the selection,
  lands on the mounted match and draws its own highlight. So the
  highlight and the scroll into view stay WebKit's. `PaneFind.search`
  and `move` (PaneFind.swift:99-116) gain one step for a web view:
  evaluate `typeof window.__koFind === 'function' ?
  window.__koFind(q, backwards) : null`; `null` is a page without
  the hook (a webview pane that is not koa's) and falls through to
  the native call alone, with today's "Match" and "No matches". With
  a result, the bar keeps its last status until the native call
  returns, then shows `.matches` with "index of count"
  (PaneFind.swift:62-67, the terminal pane's form), "No matches" for
  zero, "Searching…" while `loading`. `window.__koFind` is a page
  capability of koa's page, like `window.__koDrop`
  (WebviewPaneView.swift:543).
- Browser mode (`window.ko` absent): no change and no page bar. The
  browser's find sees the mounted rows, one viewport of overscan on
  each side.

## 5. Selection and copy

Decisions, from the same NOTES.md section:

- **A row inside an active selection is never unmounted.** On
  `selectionchange` the page records the rows of the selection's
  anchor and focus; the window step treats the range between them
  as pinned, like the live tail, until the selection collapses. A
  drag to the viewport's edge auto-scrolls, the window mounts rows
  ahead of the drag (the overscan), the rows behind stay pinned, so
  a drag across unmounted rows mounts them as it goes.
- **Select All selects the model.** The page's keydown delegate
  (page.ts:1637, the one that routes printable keys) sees ⌘A outside
  a control, lets WebKit select the mounted rows for the visible
  highlight and sets a flag `wholeTranscript`. A document `copy`
  listener then writes the whole transcript's text from the model,
  in item order, with one blank line between items: the markdown
  source for text blocks and the find text of section 4 for the
  rest. Any other selection change clears the flag, and copy is
  WebKit's. No visible cue: the highlight covers the mounted rows.
- A find highlight is WebKit's selection on the mounted match.

The whole last reply stays the `copy` command (page.ts:804).

## 6. What survives unchanged

- **Quick Look and links.** `previewFile` (page.ts:194) and
  `thumbnails` (page.ts:489) attach their handlers in `renderItem`,
  so a remounted row has them; the `who` link handler is a document
  delegate (page.ts:1620-1627). The lightbox and `preview.ts` are
  untouched.
- **Images.** A thumbnail reloads from the cache on mount; its row's
  observer entry measures the loaded height.
- **The reveal and the grow.** The tail is live, so `show`
  (page.ts:230), `revealStep` (page.ts:478), the `hold` and `grow`
  path (page.ts:322-328, 334) and `reveal.ts` do not change.
- **The working mark.** `reconcileWorking` (page.ts:700) places the
  dots in live rows, which are mounted; one node, one layer, as
  unit 2 left it.
- **The history window caps.** `MAX_WEBVIEW_WINDOW_ITEMS` and
  `MAX_WEBVIEW_WINDOW_BYTES` (koa-transcript.ts:26-27) still bound
  each page of `/items`; the model's size is what the user loaded.
- **The job view** (`job.ts`) keeps its own rows, bounded by its
  loaded chunks; it is not virtualized here.
- **Intake, the frame's phases, the incremental lex, the dots'
  placement** (perf plan units 2 to 4).

## 7. What is deleted

- The containment rule and its intrinsic size (page.css:194) and the
  inline padding taken back by a negative margin (page.css:195) with
  the `.reveal.dormant{left:4px;right:4px}` override (page.css:198):
  `.reveal.dormant` keeps its `left:0;right:0` (page.css:11).
- The margin rules that replaced the collapse through a contained
  block: the six-level `margin-top:0` chain and the heading offsets
  (page.css:199-207), the trailing-block `margin-bottom` offsets
  (page.css:208) and the six-level `margin-bottom:0` chain
  (page.css:209). Rows collapse their margins as before unit 5. The
  rule at page.css:210 (`.run.open` details, `.cmdrun .ft`, the
  bodies) predates containment and stays.
- `estimate`'s DOM write (page.ts:224-229) and its callers
  (page.ts:221, 872); the logic moves into `estimateExtent`.
- `tracking`, `intersected`, `tracked`, `below`, `tracker`
  (page.ts:73-74, 414-423) and `sync`'s observer bookkeeping
  (page.ts:427-429).
- `memo.open` (page.ts:48, 285, 289) in favour of the keyed set.
- The test "a transcript block skips its layout off screen"
  (koa-page.test.ts:297-302).
- `AppWindowCase.contentVisible` and the
  `contentvisibilityautostatechange` wait (AppWindowCase.swift:273-
  285): a capture shows the viewport, and the viewport's rows are
  mounted.
- `testKoaWebviewFindSkippedHistory` (KoaWebviewTests.swift:284-322)
  is rewritten (unit 3), not deleted.
- In docs/design-koa.md: the containment paragraph ("Off-screen
  content is skipped …", docs/design-koa.md:1000-1022) and the
  sentence at docs/design-koa.md:985-986 about find reaching the
  clipped tail (still true, kept). plans/koa-transcript-perf.md 5.7
  and its unit 5 findings move into this plan's results.

The block observer (`layoutObserver`) stays: it is the one
post-layout reader, and the row watches join it.

## 8. The measurement to run first: the dots under a stall

Before unit 1, one cheap measurement decides what "dots smooth"
means. In WebKit a `transform` and `opacity` animation runs in the
UI process's layer tree, so a stalled WebContent main thread should
not stop it. If it does stop under WKWebView, the dots cannot be
smoother than the main thread, and the dots criterion equals the
stall criterion.

- **How.** A one-off test in `KoaStressTests`, run in the VM guest's
  visible session with `KOA_STRESS_VISIBLE=1`
  (KoaStressTests.swift:17), as the stress harness's Kido leg runs;
  never on the host, where it opens windows on the user's desktop.
  It opens a koa page
  with the working row and its dots (`dots`, working.ts:9), then
  evaluates a script that spins the main thread for 2 s
  (`const t = performance.now(); while (performance.now() - t <
  2000);`). From the app's side, the test captures the pane's window
  every 50 ms with `CGWindowListCreateImage` for those 2 s (the UI
  process reads the compositor's output; a `WKWebView` snapshot or a
  page-side `Animation.currentTime` would wait on the stalled
  process) and crops to the dots' rectangle (its `DOMRect` read
  before the spin). It reports the number of distinct crops and the
  longest run of identical crops.
- **Reading it.** The bounce cycle is 1100 ms with a 180 ms stagger
  (working.ts:1): over 2 s at least 20 of 40 crops differ if the
  animation runs. Fewer than 5 distinct crops, or an identical run
  longer than 300 ms, means the animation froze with the main
  thread.
- **What each outcome changes.** Frozen: the dots criterion of unit
  2 is the stall criterion (no request→rAF sample over 100 ms, one
  tenth of a cycle). Moving: the stalls the user sees as jumpy dots
  come through the layer tree commit, not the animation; unit 2
  keeps the same criterion and adds the layer-id check of the dots
  node in Chrome (stress `run.ts:139-169`) as the second measure.

## 9. Units and acceptance

Each product unit has a manager, a planner and one implementer, and
runs `share/koa/stress/run.sh stream` before and after.

1. **The stall measurement** (section 8) and two metrics: the DOM
   node count sampled once a second in metrics mode (Chrome's
   `Nodes` exists; Kido counts `document.getElementsByTagName('*')`
   in `metrics.ts`), and the request→rAF samples over 100 ms as a
   reported line of `streamTable` (report.ts:37). Tooling: one
   agent, no reviewers. Done when the table in this plan has the
   stall result.
2. **The position table and the window** (section 3, 6, 7). Tests
   that must fail first, in `koa-dom.test.ts` on the `revealPage`
   fixture (koa-dom.test.ts:1076), whose fake layout gives each row
   a height, so the extents are deterministic under Node:
   - a reset of 300 items at a 100 px viewport mounts under 40 rows,
     and `padding-top` equals the sum of the absent extents;
   - a scroll to the top mounts the first rows, unmounts the end,
     and holds the anchor row at its offset through the correction;
   - with the reader at the top and a streaming tail, the working
     row and the revealing block stay mounted (the dots metric of
     `metrics.ts:132-135` counts zero removals while text streams);
   - a view switch and return to an item outside the window loads
     older pages until it is loaded, mounts it and applies the
     saved offset;
   - the "N new" count counts fresh items below the viewport from
     the table, with no `IntersectionObserver` in the fixture;
   - a width change marks the measured extents stale and the next
     observer callback re-measures the mounted rows;
   - `estimateExtent` and `windowOf` property tests in
     `koa-page.test.ts`: the sum of extents equals the total height
     of a fully mounted list within one margin, and `windowOf`
     always covers the viewport plus the overscan and extends over a
     job group.
   In `KoaWebviewTests` (on-screen in the VM, so frames and the
   observer run): `testKoaWebviewOlderHistoryKeepsTheReaderAnchor`
   (KoaWebviewTests.swift:268) and
   `testKoaWebviewViewSwitchRestoresTheReaderAndJobViewFollows`
   (KoaWebviewTests.swift:323) pass unchanged; a new test scrolls
   40 screens up by a scrollbar jump and checks that the rows under
   the viewport are mounted and the DOM holds under 60 rows.
   Visual: the `reveal`, `dots` and the scroll snapshots record once
   at the end; a snapshot shows the viewport, which is mounted, so
   the capture hack goes.
   Acceptance on workload 13 in Kido, visible: flush→frame p99 under
   100 ms; request→rAF max under 250 ms and no sample over 100 ms;
   frame p99 under 16.7 ms; history load max frame under 50 ms;
   per-page memory under 400 MiB (from 1228; workload 14 is 434
   and is the comparison, not the budget); DOM nodes at the end
   under 20 000 (from 350 252). These become `limit` budgets in
   `streamBudgets` (statistics.ts:74-82) and the memory limits of
   workloads 13 and 14 in `workloads.ts` replace the placeholders.
   Chrome: the same budgets as reported lines.
3. **Find** (section 4). Tests that must fail first, in
   `koa-dom.test.ts`: `__koFind('zyxwvq')` on a 40-item history
   mounts item 5, sets the reader anchor on it, collapses the
   selection at its block's start and resolves `{ index: 1, count:
   1, loading: false }`; forward and backward steps visit the
   matches in sequence order and wrap, and `count` is over every
   loaded item, mounted or not; a match in markdown syntax (`**`)
   is not a match; a match in a collapsed step opens that step when
   it becomes current and the step stays open after the cursor
   moves on, while a step that holds a non-current match stays
   closed; a match in a collapsed thinking step counts and its
   markdown renders when current; `loading` is true while an
   `older()` request is in flight and the count grows when its page
   arrives. In `KoaWebviewTests`, `testKoaWebviewFindSkippedHistory`
   drives `PaneFind` (not `webviewView.find` directly), asserts the
   bar's "1 of 1", the selection's word, its visible rect and the
   scroll ten screens up, as the skipped test does today
   (KoaWebviewTests.swift:309-321), and that the bar keeps its last
   status between the page's answer and the native result. A
   non-koa webview page keeps "Match" and "No matches"
   (`WebviewPaneTests`). Done when the tests pass in the VM.
4. **Selection** (section 5): a small unit. Tests that must fail
   first, in `koa-dom.test.ts`: with a selection spanning rows 10
   to 12 at a 100 px viewport, a scroll that would unmount them
   keeps them mounted, and collapsing the selection releases them at
   the next window step; ⌘A then `copy` writes every loaded item's
   text from the model to the clipboard data, including items that
   are not mounted, and a click that collapses the selection makes
   the next copy WebKit's. The docs gain the rules.

Docs that move when the units land: docs/design-koa.md "Frames"
(the window, the table, the extents), "Scroll" (the anchor is a
mounted row), "Keys, focus, copy, find" in docs/design-webview.md
and "Find" in docs/design-app.md (the two-step find), NOTES.md "Find and selection on a virtualized transcript" (the docs cite it) and its
Auto-scroll section (the count from positions). The plan is deleted
then, and plans/koa-transcript-perf.md with it.

## 10. Risks

- **Margin arithmetic.** The extents assume rows collapse margins
  as siblings; a row whose first child is a heading or a list has a
  different collapsed margin, which the measurement captures and the
  estimate does not. The error is one margin per unmeasured row and
  goes when the row measures.
- **Scrollbar drag into estimates.** The thumb moves by the
  estimate error as rows measure; the anchor holds, the thumb does
  not. TanStack has the same; a reader who drags sees the thumb
  settle.
- **Hidden pages.** A hidden page renders in a timer task and reads
  no geometry (perf plan 5.1); the window step uses the last known
  geometry, and the first frame after the page shows re-windows.
- **The find text's cost.** The first find in a 100 000-line history
  lexes every loaded item once, about the before-run's lex total
  (65 ms in Chrome, 205 ms in Kido at perf plan unit 1); it runs in
  the find's task, not a frame. If that is felt, the cache fills
  lazily per page of history as the user navigates.
- **WebKit's find from a collapsed selection.** The two-step relies
  on `WKWebView.find` searching from the current selection, as
  `window.find` does. Unit 3's VM test is the check; if WebKit
  starts from the top instead, the page selects the match itself
  with a `Range`, and the bar's status comes from `__koFind` alone.
- **A visual test that needs a row outside the viewport** must
  scroll there first; none does today.

## Baseline

Unit 1 results, before any window code. Stream run
`share/koa/stress/run.sh stream` (run `run-b8AFwT`), Kido legs in the
visual VM. Frame ms is the render task. Kido's node count is
`getElementsByTagName('*')` (elements only); Chrome's is the CDP
`Nodes` metric (it also counts text nodes), so the two do not compare.

| Metric [frame pass] | Chrome 13 | Kido 13 | Chrome 14 | Kido 14 |
| --- | --- | --- | --- | --- |
| frame ms p50 / p95 / p99 | 0.4 / 1.1 / 1.4 | 12.0 / 15.0 / 17.0 | 0.3 / 0.9 / 1.2 | 1.0 / 1.0 / 2.0 |
| frames over 16.7 / 50 ms | 0 / 0 | 38 / 0 | 0 / 0 | 0 / 0 |
| request→rAF ms mean / p95 / p99 / max | 9.3 / 16.6 / 18.2 / 21.5 | 38.1 / 53.0 / 363.0 / 391.0 | 9.2 / 16.2 / 17.3 / 18.3 | 15.6 / 19.0 / 19.2 / 66.0 |
| request→rAF samples over 100 ms | 0 of 1442 | 22 of 1501 | 0 of 1492 | 0 of 1485 |
| key→frame ms p50 / p99 | 8.8 / 17.3 | 18.0 / 37.7 | 8.6 / 17.7 | 11.0 / 19.0 |
| DOM nodes at end / max | 334535 / 334685 | 127173 / 127173 | 10680 / 12971 | 3998 / 3998 |

Workload 13 is the 20000-paragraph history with a stream; workload 14
streams with a short history. The 22 samples over 100 ms in Kido 13
are the stalls that the dots criterion of unit 2 counts.

**The dots under a main-thread stall.** `testDotsUnderStall`
(`KoaStressTests.swift`), in the visual VM's visible session: a koa
page held in the working state (dots, no streaming text), the dots'
`DOMRect` read after the layout settled, a 2 s main-thread spin in
the page, and `CGWindowListCreateImage` of the pane's window every
50 ms, cropped to the dots. 40 captures wanted; the loop made 37 and
38.

| Run | Captures | Distinct crops | Longest identical run |
| --- | --- | --- | --- |
| Control, no spin | 37 | 29 | 103 ms |
| 2 s spin | 38 | 30 | 102 ms |

The control shows that the capture sees the motion. The dots keep
moving while the WebContent main thread is stalled: they do not freeze
in WKWebView. So, per section 8, the stalls that the user sees as
jumpy dots come through the layer tree commit, not the animation. Unit
2 keeps the request→rAF criterion and adds the layer-id check of the
dots node in Chrome as the second measure.

Two traps of the measurement: a capture taken within about 2 s of the
first paint shows a stale window (1 distinct crop even in the control),
and a rect read when the dots first appear is wrong because the layout
still moves.
