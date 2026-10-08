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

## App Intent signing and URL-launch ordering

The cold-launch gate passed on screen through Shortcuts with a team-signed
build: one remote window, no Local. Spotlight does not list the action directly.
The action fails in ad-hoc releases because Linkd requires a validated bundle
(`requiresValidatedBundle`). Use the unsigned
`kido-app://<host>` Shortcuts recipe in
[Remote hosts](design-app.md#remote-hosts) instead.
Internal URL parsing and queued-cold/warm routing are off-screen tested;
actual URL-launch notification/event ordering still needs the user's on-screen
retest. No timer guesses are used. Status: App Intent signing limitation;
URL OS-delivery unverified.

## Remote clipboard, URL and authentication matrix

Private real localhost SSH tests cover control/feed/navigation, two remote plus
Local windows, quoting, missing kido, protocol refusal and rediscovery, master SIGKILL/recovery,
detach, generation rejection and cancellation. They use the existing prepared
account and trusted host keys, not an isolated sshd or changed account settings.

| Behavior | Current evidence / remaining check |
|---|---|
| Mac copy/paste and unsafe paste | Existing surface path retained; disposal denies pending confirmation once. Real remote unsafe-paste/clipboard end-to-end remains untested. |
| OSC52 write/query | Named-pasteboard tests cover raw control transport, consent, selector replies and restore suppression locally. The complete remote/provider matrix remains unverified. |
| HTTP/HTTPS | Remote action routes to the Mac opener, without forwarding. User-clicked browser launch/localhost-port semantics unverified off screen. |
| file: / other schemes | Remote opener refuses them with a diagnostic instead of selecting same-named Mac files. Real Ghostty click/action delivery remains unverified. |
| Unknown/changed host keys | StrictHostKeyChecking=yes, UpdateHostKeys=no; isolated-key refusal matrix not run. |
| Locked keys/password/challenge | BatchMode and actionable Terminal instructions; locked/unavailable key and keyboard-interactive cases not run. |
| Aliases/ProxyJump/inherited config | OpenSSH settings preserved with transport overrides; config matrix and other login-shell families not certified. |
| WAN interruption/latency | Local master loss covered; 50/150/300ms RTT, throttled bandwidth and WAN smoothness not measured. |

These are phase-2 checks, not evidence that SSH transparency fixes clipboard or
URL semantics. Status: unverified; prepared-host MVP only.

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

## Full-screen header colour coverage

The real full-screen header colour is verified only by authorized on-screen
captures. `make visual` covers a transferred-host stand-in, not AppKit's
`NSToolbarFullScreenWindow`; see [Sidebar](design-app.md#sidebar).
The dark-theme negative control can differ by no more than the 2/255
pixel tolerance, so it cannot reliably detect a missing background cover.
Status: accepted coverage limitation.

## OSC 52 clipboard scope and permission

Clipboard guarantees cover displayed panes only. Hidden hot panes are best
effort; evicted panes and output discarded by tmux pause-after cannot recover
completed OSC operations from captures. Hidden unapproved reads are denied,
not deferred until the pane becomes visible.

Only one clipboard-enabled app may consume a pane. Two attached apps can both
answer raw OSC reads; there is no responder election. While Kido.app is attached, tmux can forward an OSC 52 read to a terminal showing the window while the app also answers, or replies empty for a pane it is not showing. Terminal paste can return empty, or a second reply can arrive as input. The fix is deferred: tmux skips forwarding while a self-answering control client is attached, and the app stops replying empty for panes it does not show.

Always allow is per exact configured host key, including Local. Edit → Reset Clipboard Permissions revokes all grants and connection answers. Retargeting an SSH alias does not revoke its stored grant;
SSH host-key policy remains OpenSSH's. Local grants also cover applications
reached through SSH inside its panes because OSC carries no authenticated
remote identity. Use a remote window for a separate host grant.

Nested tty-mode tmux can expire clipboard requests after 500ms: first-time
human consent is too slow. Grant Always allow beforehand, or let the first
request fail and retry after granting. Empty replies may time out through
versions that discard them. The app's 8s deadline cannot detect an application's
earlier cancellation; a reply granted before that deadline may still be late
for a nested application. Arbitrary nested versions/providers remain untested.
Status: accepted scope.

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

## Sub-row wheel remainder can cross program changes

Ghostty resets pending sub-row wheel remainder only when a wheel packet sees
a different owner. If mouse reporting toggles or one alternate-screen program
replaces another without a wheel packet between them, a carried half-row can
make the next small scroll emit one report or key early. This matches upstream.
Status: accepted.

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

## Outstanding asks have no app UI

RPC 2.0 asks are decoded, including ended and revivable askers, but the app
has no activation or deletion UI. Live waiting rows remain accessible through
normal sidebar navigation; ended askers cannot be revived from Kido.app.
Use kido's ask view instead. Status: accepted migration scope.

## Feed restart loses done-until-visited attention

The feed's in-memory tracking does not survive process restart.
This affects sidebar attention, not agent state or pane content; a restart
can lose an unvisited completion indication without restoring it later.
Program-status completion acknowledgements likewise belong to the RPC model;
the app does not reconstruct them from raw records. The local search query
survives helper restarts independently.
See [The sidebar's model, and the feed](design.md#the-sidebars-model-and-the-feed)
for the CLI-side ownership.
Persisting that transient tracking is medium cross-component work.
Status: accepted.

## Shared remote-session selection and geometry

Each native window owns its own transport/client/feed/surfaces, but tmux has one
current window per session and one grid per pane. Two viewers of the same
server/session are coupled: navigation affects both, and size follows tmux's
latest elected client. Smaller viewers clip authoritative external layouts;
there are no grouped sessions or independent per-view terminal grids. Client-local
find, scroll and surface budgets remain independent. Status: accepted.

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
