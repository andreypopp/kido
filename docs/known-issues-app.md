# Correctness gaps

## Main can wait on renderer mailboxes

A full renderer mailbox can block main. This is not a reproduced universal
UI deadlock. Ghostty pushes to the renderer mailbox with `.forever` in
`third_party/ghostty/src/Surface.zig` and `src/termio/Termio.zig`.
Search-input capacity does not block main, but that guarantee does not cover
all Ghostty sends; see [Threads](design-app.md#threads).
It affects responsiveness under renderer pressure and heals when the
consumer drains. Output volume alone does not cause it: main makes at most one
output hop for each pane at a time ([Threads](design-app.md#threads)). Audit main-callable sends and use ordered nonblocking
queues/coalescing where appropriate (large cross-cutting change).
Status: parked; a blanket no-mailbox-waits guarantee is unverified.

## Inherited Ghostty constructor cleanup leaks

Failed surface construction can retain the renderer's background image: the
renderer keeps the image bytes, and its teardown does not release them when
construction fails before renderer-thread cleanup
(`third_party/ghostty/src/renderer/generic.zig`). Ghostty 1.4.0 frees the
derived configs, the environment and the font-grid reference when renderer or
termio initialization fails (`src/Surface.zig`); stale copies after a
successful initialization are not examined. These are inherited error-path
leaks. Status: parked by decision; not fixed or covered.

# Unverified

## Late GPU completion after resize

An older GPU frame might overwrite a newer resized frame. Presentation tokens
reject stale acknowledgements, but do not prove Metal completion ordering.
There is no reproduction or proof of this pane-local visual race, nor a
confirmed healing bound. A bounded GPU-order probe is medium work; fixing
ordering/fencing depends on its result. Status: unverified.

## Stale row after pi /reload

After `/reload` in pi, a pane can show a stale "Reloading keybindings…"
row above "Reloaded". The pane's own grid holds both rows, so the row
comes from pi's output, not from the app or a restore. A likely cause is
pi-plain patches that survive `/reload` with stale closures. It is not
checked on a ko server. Status: parked by the user.

## Unfocused pane frame rate

The frame rate of an unfocused visible pane is not measured, off screen or
on screen. The renderer thread (`third_party/ghostty/src/renderer/Thread.zig`)
schedules wakeups and animation deadlines; it has no frame-rate target for
unfocused panes. The possible cost is excess rendering for unfocused visible
panes, not lost content. Measure on screen first (small investigation), then
tune scheduling if needed (medium). Status: unmeasured.

## Scroll and idle wakeups on screen

The scroller layer, the fade deadline, the compression timer and the blink
timer are measured off screen only. Off screen, Ghostty sends no SCROLLBAR action,
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

The cold-launch gate passes on screen through Shortcuts with a team-signed
build: one remote window, no Local. Spotlight does not list the action
directly. Release builds use Apple Development (Personal Team) signing,
which supplies the TeamIdentifier that Linkd requires. Ad-hoc Debug and
demo builds fail with `requiresValidatedBundle`; use the unsigned
`kido-app://<host>` Shortcuts recipe in
[Remote hosts](design-app.md#remote-hosts) for those builds.
Internal URL parsing and queued-cold/warm routing are tested off screen;
the actual URL-launch notification/event ordering needs the user's
on-screen test. No timer guesses are used. Status: URL OS-delivery
unverified.

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
Gesture logic is exercised, but hit testing and real delivery can fail
for users without a stress failure. An on-screen event harness is medium-to-large
work; a manual smoke test is small. Status: untested.

## Visual tests do not run in CI

The `app` job of `.github/workflows/ci.yml` builds Kido.app and runs
`make test` and `make ko-test`, but not `make visual`: its references depend
on the display and the backing scale
([Visual references depend on the machine](#visual-references-depend-on-the-machine)).
The job also has no localhost sshd, so the ssh cases of
`KoTests/RemoteTests.swift` skip. A visual regression can merge when the
unit's `scripts/checks.sh` did not select the suite that shows it. Pin a
runner and record its references (medium). Status: untested in CI.

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
fails. Status: environment limit.

## A priority-inversion warning in one test is unexplained

XCTest reports "waiting on a lower QoS thread" at `app.renameSession()`
in `testCloseSessionConfirmsAndKills` (`app/VisualTests/PaletteTests.swift`),
and rarely in other tests. It fires in every fresh-process run. It also
fires in each of these cases: ko_client's I/O, fetch and decoder threads at
user-initiated QoS; no main-thread `ghostty_surface_set_focus`; no pane
view attached, so no decoder thread and no feed. Thus the waiting thread is
on the rename panel's AppKit path, not on ko_client or Ghostty. The
xcresult holds no stacks. Status: open, probably AppKit.

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

## Clipboard scope and permission

The server sends a read to one answerer and refuses a read for a pane that
no attended window shows. An elected client whose window is occluded or
hidden refuses an unapproved read at once; it is not deferred until the
pane becomes visible.

Always allow is per exact configured host key, including Local. Edit →
Reset Clipboard and Upload Permissions revokes all grants and connection
answers. Retargeting an SSH alias does not revoke its stored grant; SSH
host-key policy is OpenSSH's. Local grants also cover applications reached
through SSH inside its panes, because OSC carries no authenticated remote
identity. The app's 8 s deadline cannot detect an application's earlier
cancellation. Status: accepted scope.

## A frame that the server does not find stays blank

A fetched image frame that the server answers with not found (evicted, or
an edit moved its stamp on) stays blank until the program sends it again,
as on the pane. A fetch that fails for another reason (a dropped
connection) retries a bounded number of times; after the last failure the
frame stays blank until the pending generation moves again. Status:
accepted limitation.

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

## The remote agent link dangles during an outage

The forwarded agent socket ends with the master's connection, so
`agent.sock` on the host points at nothing until the recovery loop
publishes again. A pane that uses the agent in that interval fails. The
last publication wins: two windows to one host, or two Macs, link the agent
of the window that connected last, and a window close leaves its link. The
server replaces a dangling link with its own inherited agent only when it
starts. The publisher checks `agent.sock` and then renames over it; a file
that a process of the same user puts there between the two steps can be
replaced. The state directory is 0700, so only that user can do it. Status:
accepted.

## A killed app leaves its remote directory

A SIGKILL of Kido.app leaves the master's `/tmp/ka-<12>` directory with its
control socket and the forward's socket file; the next window makes a new
directory. A sweep of old `ka-*` directories at launch is a follow-up.
Status: accepted.

## A remote shell that prints at start breaks the socket query

`ko server --print-socket --ensure` runs through the remote login shell. A shell
that prints text on a noninteractive start gives a reply that is not a
socket path, and the window shows "Kido could not find the ko socket on
HOST" with the text. `ko HOST` has the same limit. Status: accepted.

## Upload drops keep the kido-app name

Uploads go to `${XDG_STATE_HOME:-~/.local/state}/kido-app/drops` on both
hosts. The app's own paths and knobs keep the Kido name: the server and
its code are `ko`, the app is Kido.app (docs/design-ko.md, "Decisions",
2026-11-03). Status: accepted.

## The remote restore and echo are not measured

`make rtt` (`app/scripts/rtt.py`) is measured only as a 2000-row smoke on
localhost without delay. The 100k-line restore, the echo at 50, 150 and
300 ms and the compression decision wait for ko's delay proxy
(`~/Workspace/kido-app-notes/k7-rtt-plan.md`). Status: open.

# Dev/tooling

## make -j can race on the xcframework

The app's build writes `app/Packages/KoClientKit/build/ko_client.xcframework`
in place (`app/Makefile`). No target starts two builds at once, but `make -j`
with several targets can run two of them on the same xcframework. Status:
accepted; run targets one at a time.

## AppKit warns about the sidebar's theme-frame overlays

`make visual` prints "adding an unknown subview: Kido.FocusEdge" once
for each window. The sidebar's `viewDidLayout` (`app/App/Sidebar.swift`)
adds the focus edge, the separator and the shadow to the window's theme
frame (`contentView.superview`), so they draw over the toolbar region, and
AppKit warns on every subview of the theme frame that it does not know.
The views stay out of the `contentView` (the window has
`.fullSizeContentView`), because there they go under the titlebar
container; `addSubview(_:positioned:relativeTo:)` keeps the warning. The
warning has no other effect. Status: accepted.

## Xcode output can be misleading

Reported successful visual runs can print xcodebuild “failed with exit code 0”,
and Xcode can emit “IDERunDestination: Supported platforms … is empty”.
The recipes invoke xcodebuild directly (`app/Makefile`); code alone
cannot reproduce these diagnostics or prove the latter cannot be silenced.
These affect developer logs, not app output; check exit status and test results.
Status: unverified diagnostics, not evidence of a failing visual suite.

## Embedding fork pin bumps carry risk

The Ghostty pin is the `kido-upstream` branch of `andreypopp/ghostty`, a
linear stack of commits on upstream (`.gitmodules`); the upstream embedding
API (`third_party/ghostty/include/ghostty.h`) is internal, not a stable
compatibility contract. A pin bump can break app builds or behaviour for
developers and users; nothing heals until integration is repaired. Audit
each pin bump with targeted tests (medium recurring work), or own a
narrower embedding boundary (large). Status: accepted dependency risk.

## Ghostty clone cost before CI

The Ghostty submodule is a substantial additional source checkout; the CLI
CI does not build the app. Measure the fetch and build cost before you add
an app job; do not assume an acceptable CI budget.
This affects CI startup and developer setup, not running panes. Cache the
pinned checkout/artifact or use a suitable shallow fetch (medium tooling
work). Status: parked pending app CI; cost unverified here.
