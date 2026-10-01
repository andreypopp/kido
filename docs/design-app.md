# Kido.app

Kido.app (`app/`) is a native macOS view of the kido server: a tmux
control-mode client that renders every pane with libghostty, beside a
native sidebar fed by `kido sidebar-feed`. Sessions, windows and panes
live in tmux; the app holds none of them.

## One control client

The app attaches one control client per server (`kido-tmux -S <socket>
-N -C attach-session -f pause-after=N,new-layouts,no-detach-on-destroy`)
and behaves like a normal client: showing a window or session is
`select-window` or `switch-client`, and the app then follows tmux's
notifications. So the client's current session, window and pane are
always the ones shown, which kido's `watched`, done-until-visited and
reaping rules depend on. A client per session would mark every session
attached. When its session is destroyed, `no-detach-on-destroy` moves
the client to another session where `detach-on-destroy` would detach
it, and the app follows as it follows any switch.

`-N` keeps a redial from starting a server behind the user's back: a
server is started only by `kido server`, from the banner's button. A
`%exit detached ...` is a deliberate detach and is not redialed; any
other ending is. A reconnect is a full reset, since ids mean something
only to the server that issued them. Every connection close, redial
and quit is one line on stderr, with its reason or trigger.

## Panes

A pane is drawn by a Ghostty surface in manual-IO mode
(`MANUAL_MIRROR`): `%output` is fed in, typed bytes come back out as
`send-keys -H`, and the emulator's own query replies are suppressed
because tmux answers them. tmux prefix bindings therefore do not fire
from the app; its menus and Ghostty's split and tab actions stand in.

Ghostty's configuration is `kido-app.conf` beside `kido.conf`
(`$XDG_CONFIG_HOME/kido/`, else `~/.config/kido/`), in Ghostty's syntax,
and Ghostty's own config files are not read; `config-file =
~/.config/ghostty/config` there shares them. It is read once at launch,
over built-in light and dark themes that follow the macOS appearance
and switch live on existing panes. The file overrides these defaults,
including the theme, background and non-blinking cursor. The window
and pane chrome follow the effective Ghostty background and its light
or dark appearance.

A pane is synced by one command line: its captures, pending parser
bytes and mode state. tmux queues `%output` ahead of the reply, so
output before the reply is wiped by the restore and output after it is
fed live. The same resync follows a `%pause`.

The initial history capture requests the newest 5000 physical rows. Its
upper edge moves down to a whole logical line; if a single line spans the
entire capture, the capture expands until that line fits. Captures use
`-e -J` for VT text and a companion `-F -L -T` capture for physical row
numbers and wrap flags. tmux has no flags-only capture. History, these
captures and `alternate_on` are read on one command line. Whole logical
lines are never split between chunks, including the history/screen join
in the initial restore.

Scrolling within one screen of the loaded top fetches the next 5000 rows,
aligned the same way. The gap is tmux's `history_size` minus Ghostty's
retained history rows, read through its mutex-protected scrollbar snapshot
(`total - len`), not the renderer's asynchronous scrollbar notification.
Offsets count from the bottom; output queued ahead of a capture reply is
already fed before calculating its overlap, and overlapping rows are
excluded. Trimming tmux's oldest history therefore changes the gap, not
the identity of the loaded rows. There is one fetch per pane; sync tokens,
view identity and a grid epoch reject obsolete replies. Every resize
resyncs from the newest 5000 rows. Alternate screens never receive history.

`ghostty_surface_prepend_history` snapshots the primary screen's width and
identity under the renderer mutex, then allocates and parses a scratch
terminal outside it. It locks again to validate the snapshot and clone
pages before the existing first page; a changed grid or history identity
rejects the chunk. The scratch terminal is freed after unlocking. Existing pins and
selections stay attached to their content; a viewport at the old top
becomes pinned there. The renderer is invalidated and publishes the new
scrollbar. The API returns the number of inserted physical rows, or zero
on alternate screens, allocation failure or insufficient scrollback byte
budget. A chunk is accepted whole or not at all, never evicting newer rows
to make room. Kido defaults to a 512 MiB Ghostty scrollback budget; the
user's configuration can override it. Hitting it stops older fetches; the
scroller keeps tmux's full range and thumb size, fading the track above the
loaded top. The thumb and target clamp to that boundary, so dragging or
wheeling beyond it reveals no blank space and makes no history request.
A native pill near the loaded top says "Older history not loaded (memory
limit)" and offers "Load more"; it hides more than a screen away from that
edge. The button doubles only that surface's byte budget under Ghostty's
renderer mutex and resumes fetching at the current target. The budget
survives appearance and config reloads, which do not change PageList's
limit; surface eviction or reconnect returns it to the configured default.
Live output still follows Ghostty's normal byte-budget trimming, recycling
oldest pages when the budget is full.

Each pane draws one thin overlay scroller, shown during scrolling or
hovering and fading afterwards. Ghostty's own scrollbar is disabled. The
thumb uses tmux's full retained history plus the screen, with a native-style
minimum knob size. Wheel events, clicks and drags update a shared target and
thumb immediately, without waiting for the reader or renderer mutex. A
per-pane queue moves Ghostty's viewport independently of capture replies.
Above the loaded top, the terminal's child view is translated down inside
the clipped pane, revealing blank terminal background without changing the
grid. While translated, terminal pointer events are suppressed and an
active selection drag is cancelled; wheel scrolling still works.
As chunks arrive, the viewport moves to the target and the translation
shrinks; the target stays put. A translated layer is explicitly invalidated
when brought back into view. Only the latest target matters: a reply no
longer needed at the loaded top is discarded, and fetching stops when the
target is loaded. Wheel fetching does not depend on Ghostty's scrollbar
notifications, which only change when a draw sees a new scrollbar snapshot.
Already-loaded rows can outlive tmux's history limit until resync; the
scroller clamps to tmux's retained range. Loaded, unchanged scrolling sends
no tmux commands: metadata is cached until output or resync invalidates it,
and is refreshed once when needed. Its colours resolve in the current
effective appearance when drawn.

Command-F opens a pane's native find bar. Each query scans tmux's history
and screen in 5000-row, whole-logical-line chunks on a worker queue,
retaining only match distances from the screen and discarding captured
text. Matching is plain substring, ASCII case-insensitive like Ghostty.
Search uses one `-F -L -T -N` capture per chunk, joining bodies on wrap
flags without trimming their whitespace. Query edits and closing the bar
cancel the scan. Output immediately invalidates results and cancels chunks;
stale results cannot navigate. A new scan starts after 300 ms of quiet,
or at most every two seconds during continuous output. Connection owns
this lifetime: resync invalidates immediately and restarts only after a
successful restore. Alternate screens search only their screen. Next and previous wrap through the newest-first
match list, loading older matches through the scroller's jump path. Ghostty
search supplies the highlights and loaded-match selection; it is restarted
after prepending history. A match beyond the byte budget is reported as out
of reach without evicting rows. Command-G and Shift-Command-G (also Return
and Shift-Return) navigate; Escape closes the bar and clears highlights.

An unsafe paste is asked about in a sheet showing its text, and the
request is completed exactly once: pasted, or refused with an empty
completion on Cancel or when its surface is freed. Other confirmations
are refused.

Surfaces are kept per window, for the most recently shown windows of
any session while their panes total at most 32; the rest have none. A
window gains its surfaces when shown. Showing another window evicts the
least recent past the budget, never the shown one, off the switch path;
surfaces are freed one per main-queue turn and at least a second after
they were created, since a young one takes hundreds of milliseconds to
free. A hidden surface is occluded and its renderer released; the shown
ones follow the app window's occlusion. tmux sends no `%output` for
panes outside the client's session, so a window that left it is synced
again when next shown. Surfaces of closed windows and sessions are freed.

tmux's layout is authoritative: every Ghostty surface is exactly its
pane's grid, and `PaneLayout` maps cells to points. On each axis a
pane's two inner paddings sum to one cell minus one device pixel, split
floor/ceil in physical pixels so surfaces and dividers stay on the pixel
grid. tmux's border cell between two panes is then exactly their
paddings plus the one-pixel divider, so any tree, however asymmetric,
lines up with no surplus. Around the whole terminal area only, the
horizontal remainder is balanced over an 8pt minimum; vertically the
first row is at a fixed 44pt (`PaneLayout.topMargin`) at every height and
in both sidebar states, and all vertical remainder goes to the bottom,
over a 6pt minimum. Zoom uses the same rule. Dividers have six-point hit
areas; unfocused panes are dimmed by a theme-background overlay; a
pane shows the window’s shared glass toolbar only in its top-right hot
zone: the toolbar frame plus 24pt to its left and below, clipped to the
pane. It splits, zooms and closes through the same commands as the menus.
Frame changes place only the shown window; membership and stacking are
reconciled only when tmux’s topology changes. Hidden windows are placed
when shown. Terminal focus survives resizing and sidebar collapse;
showing another window or creating the active pane’s view can move focus.

The standard window buttons are AppKit's: the toolbar re-lays them out
at will, so nothing moves them. The fixed top clears them and the
sidebar toggle, which AppKit keeps in the collapsed titlebar,
so the terminal never moves vertically when the sidebar collapses.

## Threads

Client callbacks run on the client's reader queue, and the pane map is
touched only there. Output is fed synchronously on the pane's scroll queue,
so live output and viewport moves cannot race the target's distance from
the bottom. A pane leaving the layout is held on main until the queue has
dropped it, so its
surface is freed on main. A layout reaches main synchronously, and a
pane's first feed after a resize waits until Ghostty confirms the new
grid, so output never lands in the old one. Main never waits on the
reader queue.

## Sidebar

The sidebar runs `kido sidebar-feed --socket --client` with the kido
the server names in `side-status-command`, so the feed matches the
server, and the app's own client name, so kido's rules follow what the
app shows. The app decodes v2 only: sessions are source-list sections,
window groups contain panes, and pane items can contain arbitrarily deep
hoisted child windows. A node's identity is scoped to its session; linked
windows may appear in several sections.

`Sidebar` is an `NSSplitViewController` with a sidebar item, which
supplies the floating glass, collapse animation and saved width (236pt,
200-360pt). The window has an icon-only unified toolbar only because the
sidebar's glass reaches the top of the window, traffic lights inside it,
when there is one; without it AppKit adds a plain titlebar strip. Title
and toolbar draw nothing over the terminal, and the window, chrome and
terminal share the Ghostty theme background. New Session is a standard
image toolbar item, as is the sidebar toggle, targeting the split view
controller. Both are borderless and the toolbar is not customizable.

`SidebarView` is a flat `NSOutlineView`: session headers with a
new-window button, then one bracket per tmux window at every depth drawn as a guide
line, with no window label. A top-level node is a window; an item's
nested children (hoisted child windows) are subpanes, one guide column
per level. Each row is title, then tail (or a started row's clock),
then a status glyph: red for a real failure, orange for waiting,
stalled or the feed's attention flag, a spinner for running or
compacting, nothing otherwise. Titles keep their width and tails
truncate first. Selection is a quiet pill (a stronger semantic fill with Increase
Contrast), and glyph colours do not change with it. Selection and scroll survive snapshots by
session-scoped node identity. Scroll anchors the first visible identity
and its intra-row offset, falling back to pixels only if that row disappears.

The search and single-line, truncating diagnostic sit above the outline;
the full diagnostic is available in its tooltip. The search field
is the one store of the filter: each feed process receives it on start
and every edit. Jump failures leave the filter and focus intact; a
successful jump clears it and returns focus to the pane. External tmux
switches update selection without taking keyboard focus.

The toolbar and Control-Command-S toggle the sidebar; the View menu's
Show/Hide title follows its collapsed state. Focus Sidebar uses
Control-Command-L. Control-Command-F enters full screen. Control-Command-N (Shift for previous) walks attention;
Control-Command-J/K switches windows; Command-Shift-N creates a session. In the outline, j/k move, n/N jump
to attention, Return jumps, Escape returns to the pane and / searches.
The sidebar is visible by default; it does not automatically collapse
at narrow widths.

## Testing

`make tsan` and `make asan` build Debug with ReleaseSafe GhosttyKit into
`build/derived-{tsan,asan}`. ASan defaults to `use_sigaltstack=0` because Zig
threads replace its alternate signal stack with thread-local storage.

The Main Thread Checker needs no rebuild: launch a Debug build with
`DYLD_INSERT_LIBRARIES=$DEVELOPER_DIR/usr/lib/libMainThreadChecker.dylib`
and `MTC_RESET_INSERT_LIBRARIES=1`, which keeps it out of the feed and
tmux. Leaks are checked with `MallocStackLogging=1` and `leaks`,
`footprint` and `heap` on the pid, compared after attaching, after
switching past the surface budget, and after closing all but one window.

`KIDO_APP_SOCKET` and `KIDO_APP_TMUX` point the app at a private
server; `KIDO_APP_FEED` names a stand-in feed. `KIDO_APP_BACKGROUND=1`
keeps a test launch off screen: it never activates, never takes focus
and keeps no preferences. `KIDO_APP_DEBUG=1` logs each switch, eviction
and free to stderr with its timing.
