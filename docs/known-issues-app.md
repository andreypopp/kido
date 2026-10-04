# Correctness gaps

## Resync loses the pen, charset and pending wrap

A pane can show wrong colours, links or `qqqq` instead of box lines after
resize, window switching or reconnect. `app/Packages/TmuxControl/Sources/TmuxControl/PaneSync.swift:62-71`
resets SGR and positions the cursor without restoring the current pen,
G0/G1 designation, SI/SO selection or pending-wrap latch.
The pen (fg/bg/attr/us/link) and charset live in tmux's private
`input_ctx.cell` (`third_party/tmux/input.c:79`); no requested format exposes them.
Styled capture describes cells, not the current pen or charset; `-P -C`
returns unfinished parser bytes, not that state.
This is display-only and pane-local, chiefly for incremental curses output
(htop, vim, mc). It heals when the program restates the missing state;
another resync is not a guaranteed cure. Resize often prompts a full redraw.
An app-only wrap repair can use `cursor_x == pane_width` and reprint the last
glyph in its captured style, starting earlier for wide glyphs (small change).
Fork formats `pane_pen` using `grid_string_cells_code` (roughly 40–60 LOC)
and `pane_charset` (roughly 25 LOC), plus app replay, would restore the rest;
the tmux fork belongs to the CLI side. Status: parked until a visible glitch.

## Alternate-screen option disagrees with raw output

With tmux's `alternate-screen` option off, raw 1049 sequences still reach
Ghostty and switch its screen. Live output is replayed without filtering;
see [Panes](design-app.md#panes).
Only programs using those sequences under that option hit this pane-local
display mismatch; an exit sequence or authoritative resync can heal it.
Filtering needs a stateful stream parser, or an embedding mode that mirrors
tmux's option (medium change). Status: parked, low priority.

## Main can still wait on renderer mailboxes

A full renderer mailbox can block main; this is not a reproduced universal
UI deadlock. `.forever` sends remain, for example in
`app/third_party/ghostty/src/Surface.zig:2573` and `src/termio/Termio.zig:712`.
Search-input capacity does not block main, but that guarantee does not cover
all Ghostty sends; see [Threads](design-app.md#threads).
It affects responsiveness under renderer pressure and ordinarily heals when
the consumer drains. Audit main-callable sends and use ordered nonblocking
queues/coalescing where appropriate (large cross-cutting change).
Status: parked; a blanket no-mailbox-waits guarantee is unverified.

# Unverified

## Late GPU completion after resize

An older GPU frame might overwrite a newer resized frame. Presentation tokens
reject stale acknowledgements, but do not prove Metal completion ordering;
see [Stress harness](design-app.md#stress-harness).
There is no reproduction or proof of this pane-local visual race, nor a
confirmed healing bound. A bounded GPU-order probe is medium work; fixing
ordering/fencing depends on its result. Status: unverified.

## Never-focused pane frame rate

The renderer's unfocused pacer targets about 30 fps
(`app/third_party/ghostty/src/renderer/Thread.zig:25`). The reported off-screen
measurement is about 44 fps; the on-screen rate is unmeasured.
Code inspection cannot establish that measurement or its present validity.
The possible cost is excess rendering for unfocused visible panes, not lost
content. Measure on screen first (small investigation), then tune scheduling
if needed (medium). Status: unverified.

## Stale tiled-content clip on screen

A stale-root shrink could expose terminal pixels above the titlebar separator.
`app/App/WindowView.swift:330-334` installs a tiled-content mask for this case.
Visual tests cover settled resize and a top float, not a deliberately held
stale-root shrink; they do not establish the on-screen clipping result.
The suspected glitch is local to a resize transition and should end with the
current layout. Add a forced-stale pixel fixture and inspect a real window
(small-to-medium work). Status: unverified.

# Test coverage gaps

## Liquid Glass is absent from visual coverage

`make visual` covers terminal images, not the sidebar or pane toolbar's
Liquid Glass; see [Testing](design-app.md#testing).
Chrome regressions can therefore reach all users without a snapshot failure;
there is no automatic repair. Add an on-screen chrome check or a suitable
compositor capture harness (medium). Status: untested.

## Smoothness, event routing and embedding internals

Neither visual snapshots nor off-screen stress establishes smoothness, frame
rate, real AppKit wheel routing or display-link rendering. Stress calls the
wheel entry point directly; see [Stress harness](design-app.md#stress-harness).
A cancelled momentum phase is mapped in `app/App/PaneView.swift:1144`, but
cannot be synthesized by the harness; state assertions are not event coverage.
The app harnesses also do not establish GhosttyKit's internal correctness;
targeted Zig tests cover selected internals, not the whole embedding boundary.
These gaps affect interactive users and can hide persistent input/rendering
regressions. Add bounded on-screen measurements and event tests (large), with
targeted internal tests for individual contracts (small each). Status: untested.

## Off-screen presses bypass AppKit delivery

Off-screen `sendEvent` does not reliably deliver grip, scroller or floating
edge-resize presses. Stress invokes their existing entry points instead;
see [Stress harness](design-app.md#stress-harness).
Gesture logic is exercised, but hit testing and real delivery can still fail
for users without a stress failure. An on-screen event harness is medium-to-large
work; a manual smoke test is small. Status: untested.

## App checks do not run in CI

`.github/workflows/ci.yml` builds and tests the CLI, not Kido.app.
Swift, embedding and visual regressions can merge without automated app checks
and need not heal. Add a macOS app job after resolving dependency cost
(medium infrastructure work). Status: untested in CI.

## Visual references depend on the machine

Snapshot rasterization depends on macOS and backing scale, so another setup
can report false failures. See [Testing](design-app.md#testing).
This affects developers, not shipped pane content; re-recording and reviewing
references repairs the mismatch. Re-record after OS/scale changes (small), or
pin the runner environment (medium). Status: accepted coverage limitation.

# Accepted limitations

## Reflow row counts can disagree

During resize, Ghostty's provisional rows need not equal tmux's `history_size`:
tmux counts physical rows at its own width. Total greater than loaded alone
is not evidence of missing content; see [Panes](design-app.md#panes).
Resize users can see transient count differences; authoritative replay repairs
the content. Comparing logical coverage rather than raw counts would require
medium work where a decision needs it. Status: accepted.

## History metadata is sampled

History-limit trimming can leave metadata stale until restore, Load more,
find or the next wheel/scroller request reaching the loaded top. There is
no history poll. A sampled shrink or clear repairs content through restore.
The scroller thumb uses loaded Ghostty geometry, not the tmux total.
The visible effect is chiefly stale Load more availability until refresh;
hidden panes refresh on show. An exact content invalidation protocol is
fork-level work. Status: accepted.

## Tmux prefix bindings do not fire

App input is pane input, not tmux client key-table input;
see [Panes](design-app.md#panes).
Prefix users must use app menus/actions or another client. This is permanent,
not a transient failure. Add explicit key-table integration (large) or keep
the current actions. Status: accepted.

## Resize anchors cover only the newest capture

A resize preserves position only inside the newest 10k physical history rows
and actual retained budget; older anchors fall to the live bottom.
See [Panes](design-app.md#panes).
Deep-history readers lose their position, with no automatic return.
Capture around an old anchor or reload its coverage (medium-to-large).
Status: accepted.

## Extra loaded history is dropped on resize

History loaded by the pill or find is outside the common reset-and-replay
capture and is discarded; see [Panes](design-app.md#panes).
Deep readers must load it again; find does not automatically restore a
cancelled coverage goal. Preserve/reload extra coverage (medium-to-large),
or keep the bounded restore. Status: accepted.

## Top floats leave a sub-cell gap

A top float can leave background between its whole-cell frame and the
titlebar separator; floats do not use tiled render insets.
See [Panes](design-app.md#panes).
This is cosmetic and persists at that geometry. Extending float chrome or
changing its coordinate contract is small-to-medium work. Status: accepted.

## Selecting a dying pane can show an error sheet

A click can race pane removal: the command fails before topology catches up,
and `app/App/WindowView.swift:520` reports it as “Pane command failed”.
Users hitting that narrow race must dismiss the sheet; subsequent topology
removes the pane. Suppress only confirmed gone-pane errors (small change),
without hiding real failures. Status: accepted.

## Scroller strip overlaps terminal content

The 12pt scroller hit strip sits inside pane chrome
(`app/App/WindowView.swift:339`); non-rightmost panes lack the outer margin
that can absorb it, so it overlaps the last terminal column.
Hover/drag users can hit the strip instead of terminal content; last-column
drag selection is untested. Reserve space or narrow/condition hit testing
(small-to-medium). Status: accepted overlap; selection impact untested.

## Feed restart loses done-until-visited attention

The feed's in-memory tracking does not survive process restart.
This affects sidebar attention, not agent state or pane content; a restart
can lose an unvisited completion indication without restoring it later.
See [The sidebar's model, and the feed](design.md#the-sidebars-model-and-the-feed)
for the CLI-side ownership.
Persisting that transient tracking is medium cross-component work.
Status: accepted.

## Only one native window

`app/App/main.swift:6` owns one native window and one control-client view.
Users cannot open independent native views; this does not heal itself.
Multi-window support is phase-3 scope, not implemented (large architectural
work). Status: accepted.

## Restore latency

The reported Release baseline is roughly 20ms for 10k lines, dominated by
tmux serializing `capture-pane`; current code still uses capture batches
(`app/Packages/TmuxControl/Sources/TmuxControl/PaneSync.swift:28`).
That timing is a measurement to recheck, not a code guarantee. Switching or
repairing panes can expose latency; it ends when replay completes.
Optimizing capture serialization is medium-to-large fork work. Float-move
micro-optimizations are not required without profiling evidence (small
investigation first). Status: accepted cost; current timing unverified.

# Dev/tooling

## Control clients cannot display tmux popups

`third_party/tmux/cmd-display-menu.c:425` makes `display-popup` a no-op for
control clients. Floating terminals must be real tmux panes instead;
the app harness creates them with `new-pane`.
Popup-dependent workflows need a different action; there is no automatic
native popup. App-owned popup rendering would be large work.
Status: accepted.

## Xcode output can be misleading

Reported successful visual runs can print xcodebuild “failed with exit code 0”,
and Xcode can emit “IDERunDestination: Supported platforms … is empty”.
The visual recipe invokes xcodebuild directly (`app/Makefile:41`); code alone
cannot reproduce these diagnostics or prove the latter cannot be silenced.
These affect developer logs, not app output; check exit status and test results.
Investigate settings or narrowly filter verified noise (small work).
Status: unverified diagnostics, not evidence of a failing visual suite.

## Embedding fork rebases carry risk

The Ghostty pin is an andreypopp fork on the manaflow-ai embedding lineage;
the upstream embedding API is internal, not a stable compatibility contract.
See `app/third_party/ghostty/include/ghostty.h` and `.gitmodules`.
Rebases can break app builds or behavior for developers and users; nothing
heals until integration is repaired. Audit each rebase with targeted tests
(medium recurring work), or own a narrower embedding boundary (large).
Status: accepted dependency risk.

## Ghostty clone cost before CI

The Ghostty submodule is a substantial additional source checkout; CLI CI
currently avoids app builds. Fetch/build cost needs measuring before adding
an app job, rather than assuming an acceptable CI budget.
This affects CI startup and developer setup, not running panes. Cache the
pinned checkout/artifact or use a suitable shallow fetch (medium tooling
work). Status: parked pending app CI; cost unverified here.
