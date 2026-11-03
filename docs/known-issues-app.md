# Correctness gaps

## Main can still wait on renderer mailboxes

A full renderer mailbox can block main; this is not a reproduced universal
UI deadlock. `.forever` sends remain, for example in
`third_party/ghostty/src/Surface.zig:2573` and `src/termio/Termio.zig:712`.
Search-input capacity does not block main, but that guarantee does not cover
all Ghostty sends; see [Threads](design-app.md#threads).
It affects responsiveness under renderer pressure and ordinarily heals when
the consumer drains. Audit main-callable sends and use ordered nonblocking
queues/coalescing where appropriate (large cross-cutting change).
Status: parked; a blanket no-mailbox-waits guarantee is unverified.

## Main still writes a surface's size on a font or scale change

The decoder thread sizes the grid, but a font, backing-scale or inset
change on main still runs Ghostty's own resize of the surface
(`setCellSize`, then the size update) while the decoder can resize it
from a restore or a `KO_FEED_RESIZE`. The two writes of the surface's
size are not serialized. The server's next resize marker brings the grid
back to the server's size. Status: open; step 6 (`PaneGeometry`, the
fork's cleanup) owns the surface's geometry.

## Inherited Ghostty constructor cleanup leaks

Failed surface construction can retain the renderer's background image: the
renderer keeps the image bytes, and its teardown does not release them when
construction fails before renderer-thread cleanup
(`third_party/ghostty/src/renderer/generic.zig`). Ghostty 1.4.0 frees the
derived configs, the environment and the font-grid reference when renderer or
termio initialization fails (`src/Surface.zig`); stale copies after a
successful initialization are not examined. These inherited error-path leaks
are outside the renderer-thread ownership fix. Status: parked by decision; not
fixed or covered.

## Restored images are blank until K6

A restore brings back the text under a kitty image, not its pixels: the
view's snapshot carries no image data until ko K6. Live images draw. An
image that was on screen before a reconnect or a copy-mode resync shows
as the text under it. Status: planned (K6).

# Unverified

## A stress jump can miss its selection deadline

One `make stress` run on 2026-11-03 failed the `jump-selects` check: the
sidebar jump's selection did not reach the model within the 5 s of
`afterSelection`, 15.7 s into the run, before any mid-run server restart.
The same seed passed on the rerun, and the failed run's logs were
overwritten. Probable cause: the `selected` event waits on a main queue
that the output flood keeps busy. Status: seen once.

## Late GPU completion after resize

An older GPU frame might overwrite a newer resized frame. Presentation tokens
reject stale acknowledgements, but do not prove Metal completion ordering.
There is no reproduction or proof of this pane-local visual race, nor a
confirmed healing bound. A bounded GPU-order probe is medium work; fixing
ordering/fencing depends on its result. Status: unverified.

## Stale row after pi /reload

Before step 4, after `/reload` in pi, a tmux-backed pane showed a stale
"Reloading keybindings…" row above "Reloaded". tmux's own grid held both
rows, so the row came from pi's output, not from the app or a restore. A
likely cause is pi-plain patches that survive `/reload` with stale
closures. It is not checked on a ko server. Status: parked by the user.

## Never-focused pane frame rate

The renderer's unfocused pacer targets about 30 fps
(`third_party/ghostty/src/renderer/Thread.zig:25`). The reported off-screen
measurement is about 44 fps; the on-screen rate is unmeasured.
Code inspection cannot establish that measurement or its present validity.
The possible cost is excess rendering for unfocused visible panes, not lost
content. Measure on screen first (small investigation), then tune scheduling
if needed (medium). Status: unverified.

## Scroll and idle wakeups on screen

The scroller layer, fade deadline, compression timer and blink timer changes
were measured off screen only. Off screen, Ghostty sends no SCROLLBAR action,
so the skipped scroller refresh has tests but no measured effect. The 120 Hz
effect is unmeasured. Measure with the profile recipe on a 120 Hz display (small
investigation). Status: unverified.

## Stale tiled-content clip on screen

A stale-root shrink could expose terminal pixels above the titlebar separator.
`app/App/WindowView.swift` installs a tiled-content mask for this case.
Visual tests cover settled resize and a top float, not a deliberately held
stale-root shrink; they do not establish the on-screen clipping result.
The suspected glitch is local to a resize transition and should end with the
current layout. Add a forced-stale pixel fixture and inspect a real window
(small-to-medium work). Status: unverified.

## App Intent signing and URL-launch ordering

The cold-launch gate passed on screen through Shortcuts with a team-signed
build: one remote window, no Local. Spotlight does not list the action directly.
Release builds use Apple Development (Personal Team) signing, supplying the
TeamIdentifier Linkd requires. Ad-hoc Debug/demo builds still fail with
`requiresValidatedBundle`; use the unsigned `kido-app://<host>` Shortcuts
recipe in [Remote hosts](design-app.md#remote-hosts) for those builds.
Internal URL parsing and queued-cold/warm routing are off-screen tested;
actual URL-launch notification/event ordering still needs the user's on-screen
retest. No timer guesses are used. Status: URL OS-delivery unverified.

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
A cancelled momentum phase is mapped in `PaneView.scrollWheel`, but
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

## Live sidebar-resize frames are not tested

`testPaneFocusTreatment` checks the paper in an inactive pane's padding
after the sidebar collapses and expands, and it fails with a wrong padding
fill. Visual snapshots repaint the chrome off screen, so the test cannot
show the frames of a live sidebar animation or a live window resize; see
[Focus treatment](design-app.md#focus-treatment). A defect that leaves old
paper in those frames is found only by hand. Check by hand after a change
to pane backings (small). Status: accepted coverage limitation.

## Visual references depend on the machine

Snapshot rasterization depends on macOS and backing scale, so another setup
can report false failures. See [Testing](design-app.md#testing).
This affects developers, not shipped pane content; re-recording and reviewing
references repairs the mismatch. Re-record after OS/scale changes (small), or
pin the runner environment (medium). Status: accepted coverage limitation.

## The display-link test needs an active display

`RendererTests.testWindowDisplayIDReachesNativeLink` times out in a
session without an active display: Ghostty logs `error creating display
link … CreationFailed`, because `CVDisplayLinkCreateWithActiveCGDisplays`
fails. The test is unchanged by step 4. Status: environment limit.

## A priority-inversion warning in one test is unexplained

XCTest reports "waiting on a lower QoS thread" now and then at
`app.renameSession()` in `testCloseSessionConfirmsAndKills`, and it was
seen once in two other tests. It fires in 9 of 9 fresh-process runs.
It still fires in 9 of 9 runs in each of these cases: ko_client's I/O,
fetch and decoder threads at user-initiated QoS; no main-thread
`ghostty_surface_set_focus`; no pane view attached, so no decoder thread
and no feed. Thus the waiting thread is on the rename panel's AppKit path,
not on ko_client or Ghostty. The xcresult holds no stacks. Status: open,
probably AppKit.

# Accepted limitations

## Full-screen header colour coverage

The real full-screen header colour is verified only by authorized on-screen
captures. `make visual` covers a transferred-host stand-in, not AppKit's
`NSToolbarFullScreenWindow`; see [Sidebar](design-app.md#sidebar).
The dark-theme negative control can differ by no more than the 2/255
pixel tolerance, so it cannot reliably detect a missing background cover.
Status: accepted coverage limitation.

## Transparent paper changes glyph edges

Tiled panes draw on transparent Ghostty paper over an opaque app layer
([Focus treatment](design-app.md#focus-treatment)). Ghostty's native alpha
blending then gives antialias edge pixels that differ from opaque
rendering by at most 27/255 on kido-light and 17/255 on kido-dark. Glyph
interiors and the paper match within 2/255, and the difference is not
visible at normal size. A Ghostty-side paper colour would remove it, but it
needs a fork change (medium). Status: accepted limitation.

## OSC 52 clipboard scope and permission

Clipboard guarantees cover displayed panes only. Hidden hot panes are best
effort; output that a frozen or evicted pane does not parse cannot perform
its OSC operations later. Hidden unapproved reads are denied, not deferred
until the pane becomes visible.

Only one clipboard-enabled app may consume a pane. Two attached apps can
both answer raw OSC reads; there is no responder election.

Always allow is per exact configured host key, including Local. Edit → Reset Clipboard Permissions revokes all grants and connection answers. Retargeting an SSH alias does not revoke its stored grant;
SSH host-key policy remains OpenSSH's. Local grants also cover applications
reached through SSH inside its panes because OSC carries no authenticated
remote identity. The app's 8s deadline cannot detect an application's
earlier cancellation. Status: accepted scope.

## Sub-row wheel remainder can cross program changes

Ghostty resets pending sub-row wheel remainder only when a wheel packet sees
a different owner. If mouse reporting toggles or one alternate-screen program
replaces another without a wheel packet between them, a carried half-row can
make the next small scroll emit one report or key early. This matches upstream.
Status: accepted.

## Edit items can take a custom Ghostty binding

A pane offers a key whose Ghostty binding is consumed, and neither `all` nor
`performable`, to the main menu first. The pane performs Select All, Copy and
Paste itself through Ghostty's `select_all`, `copy_to_clipboard` and
`paste_from_clipboard`. It does not perform Undo, Redo or Cut, so these items
are disabled in a pane. Ghostty's default ⌘Z is performable and does not go
through the menu. A user binding on ⌘Z, ⇧⌘Z or ⌘X that is neither `all` nor
`performable` goes to the disabled item, which consumes the key without
Ghostty. Likewise, a user binding that moves ⌘A, ⌘C
or ⌘V to another action is replaced by the fixed action of the menu item.
Status: accepted.

## Top floats leave a sub-cell gap

A top float can leave background between its whole-cell frame and the
titlebar separator; floats do not use tiled render insets.
See [Panes](design-app.md#panes).
This is cosmetic and persists at that geometry. Extending float chrome or
changing its coordinate contract is small-to-medium work. Status: accepted.

## Closing a dying pane can show an error sheet

A close can race pane removal: the delete fails before the layout catches
up, and `WindowOwner.confirmClose` reports it as “Pane command failed”.
Users hitting that narrow race must dismiss the sheet; the next layout
removes the pane. A pane click is a select and shows no sheet. Status:
accepted.

## Scroller strip overlaps terminal content

The 12pt scroller hit strip sits inside pane chrome
(`app/App/WindowView.swift`); non-rightmost panes lack the outer margin
that can absorb it, so it overlaps the last terminal column.
Hover/drag users can hit the strip instead of terminal content; last-column
drag selection is untested. Reserve space or narrow/condition hit testing
(small-to-medium). Status: accepted overlap; selection impact untested.

## Copy-mode mouse and context menu are verified off screen

Visual tests call the mouse handlers and `menu(for:)` directly. The
Shift-press tests send synthesized events through `NSWindow.sendEvent`, not
through the window server. Real AppKit delivery of clicks, drags, autoscroll
and the context menu, on screen, is untested. The beep for ⌘O, `p` and
Prompt with Selection… without an agent is not asserted. A user `right-click-action` other than `context-menu` consumes
the right-click in Ghostty outside copy mode, and no menu opens. The prompt path
is tested against a private ko server (`OwnerModelTests`) and through the
visual-only `testPrompt` hook (`PaletteTests`). Status: untested.

## Notifications can repeat across windows

Notification entries are per window, not per host. Two Kido.app windows on
one server each post for a pane that waits or fails out of sight, so one
event can arrive twice, once per window; withdrawal and the badge count
follow each entry. Sharing entries would need one notifier entry per host
pane across owners. Status: accepted.

## Dev builds re-prompt for notification permission

Release builds are team-signed, so the notification grant survives upgrades.
Dev builds are ad-hoc signed and macOS keys the grant to the code hash, so
every rebuild is a new app to TCC: KidoDev asks for permission again after
each rebuild and stale entries accumulate in System Settings. Status:
accepted for development.

## Notification delivery is verified by hand

Off-screen tests use the recording poster and never touch Notification
Center, so a real banner, a click from Notification Center (including a
click that launches the app) and the Dock badge are checked only by the
user on screen before a release. Status: accepted.

## Windows on one server share pane grids

Each native window is its own ko client with its own selection, but the
server has one grid per pane. Two windows that show the same window share
its size, which follows the server's rule for clients that size windows.
Client-local find, scroll and surface budgets remain independent. Status:
accepted.

# Dev/tooling

## make -j can race on the xcframework

`make` writes `app/build/ko_client.xcframework` in place. No target starts
two builds at once, but `make -j` with several targets can run two of them
on the same xcframework. Status: accepted; run targets one at a time.

## AppKit warns about the sidebar's theme-frame overlays

`make visual` prints "adding an unknown subview: Kido.FocusEdge" once
for each window. The sidebar's `viewDidLayout` adds the focus edge, the
separator and the shadow to the window's theme frame
(`contentView.superview`), so they draw over the toolbar region, and
AppKit warns on every subview of the theme frame that it does not know.
Moving them into the `contentView` (the window has
`.fullSizeContentView`) puts them under the titlebar container and
changed 56 snapshots; `addSubview(_:positioned:relativeTo:)` keeps the
warning. The warning has no other effect. Status: accepted.

## Xcode output can be misleading

Reported successful visual runs can print xcodebuild “failed with exit code 0”,
and Xcode can emit “IDERunDestination: Supported platforms … is empty”.
The recipes invoke xcodebuild directly (`app/Makefile`); code alone
cannot reproduce these diagnostics or prove the latter cannot be silenced.
These affect developer logs, not app output; check exit status and test results.
Status: unverified diagnostics, not evidence of a failing visual suite.

## Embedding fork rebases carry risk

The Ghostty pin is an andreypopp fork on the manaflow-ai embedding lineage;
the upstream embedding API is internal, not a stable compatibility contract.
See `third_party/ghostty/include/ghostty.h` and `.gitmodules`.
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
