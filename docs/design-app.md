# Kido.app

Open gaps and accepted limits are tracked in [Known issues](known-issues-app.md).

Kido.app (`app/`) is a native macOS view of the kido server: a tmux
control-mode client that renders every pane with libghostty, beside a
native sidebar fed by `kido rpc`. Sessions, windows and panes
live in tmux; the app holds none of them. tmux is always the source of
truth for pane content, including history and its line wrapping, and
for geometry. Ghostty's reflow during a resize is provisional, replaced
by a tmux capture once the gesture ends. The app never retains
Ghostty-derived content that disagrees with tmux. Purely client/UI state
(scroll position, selection, find, sidebar UI, gestures, fonts and themes)
belongs to Kido.app, not tmux.

## One control client

Each native window attaches one control client (`kido-tmux -u -S <socket>
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
server is started only by `kido server --server DIR`, on explicit connection
or the banner's Start button.
The directory is `$XDG_STATE_HOME/kido-app`, else `~/.local/state/kido-app`;
the JSON endpoint supplies its `DIR/socket` path. Helpers never set
`KIDO_STATE_DIR`: panes resolve the server directory from `$TMUX`. A
`%exit detached ...` is a deliberate detach and is not redialed; any
other ending is. A reconnect is a full reset, since ids mean something
only to the server that issued them. Every connection close, redial
and quit is one line on stderr, with its reason or trigger.
Build identity is checked only at discovery and confirmed restart; automatic
redial only re-attaches, so a different kido manually started in that directory
is rejected at the next discovery.

## Remote hosts

On macOS Tahoe, the Shortcuts action **Connect to Remote Host in Kido**
has a required Host string in its parameter summary. It works only in
team-signed builds: Linkd rejects ad-hoc bundles with `requiresValidatedBundle`.
Spotlight does not list the action directly. The cold-launch gate passed on
screen through Shortcuts with a team-signed build.

The unsigned alternative is `kido-app://<host>`: in Shortcuts use
**Ask for Input** with prompt **Host**, then **Open URLs** with
`kido-app://<Provided Input>`. It needs no signing. The percent-decoded
authority is the SSH destination: `kido-app://localhost` or
`kido-app://user@myhost`. An empty path or `/` connects to the default
session; non-empty paths are reserved for future session selection and rejected
for now. Ports, passwords, queries, fragments, empty hosts, whitespace,
controls, SSH options and shell syntax are rejected with one stderr line.
URL delivery and the App Intent share Host validation and window routing. Each request
creates a new native window, including repeated requests for one alias.
Host is trimmed and accepts an SSH alias or user@hostname, not options,
whitespace, controls or shell syntax. Ports and jump hosts belong in SSH
config. There is no host picker, recent-connections store or remote restore.
Local keeps `SessionModel.title` (session and current window); remote prefixes
it with resolved `user@host / `. The original dialing alias is the window
content's tooltip. Offline titles drop the session/window name.

`AppDelegate` owns shared Ghostty configuration, app lifecycle and menus.
Each `WindowOwner` owns its immutable Host, generation, transport, Connection,
Feed, model and SessionView/surface cache. Main menu actions target the key
owner; source-pane actions stay with that pane's owner. Configuration changes
broadcast to live owners. Late discovery, command, feed and control callbacks
check liveness/generation; dead-master callbacks cannot publish channel results.
Surface disposal cancels find/gestures, denies pending paste exactly once,
rejects deferred actions/input, and retains parser-quiescent main-thread freeing.
Closing a window stops only its channels/master, never remote sessions. Closed
owners stay retained until their transport cleanup completes; quit replies
after asynchronous process-reaping completion, including retiring transports.
The terminate-later reply is a common-mode main RunLoop block, not a main
DispatchQueue block: AppKit's nested termination event loop cannot re-enter a
main-dispatch callback that called terminate. A bounded off-screen quit probe
reproduced that wait in `NSApplication._shouldTerminate` before the reply fix.
Closing the last window leaves the app available for another intent.

Launch bootstrap initializes shared resources and drains queued Host requests;
it does not open Local. Ordinary AppKit untitled/reopen delivery opens Local
only when no live window exists; reopening with a live window focuses it.
There is no timer, debounce or compensating close of a Local window. Off-screen
routing tests prove queued cold and warm behavior. The launch gate requires
`launchIsDefaultUserInfoKey == true` and an initial `oapp` (if available);
non-default launches discard queued Local requests and suppress ordinary-open
until the requested remote arrives. Apple's
[launch key](https://developer.apple.com/documentation/appkit/nsapplication/launchisdefaultuserinfokey)
defines non-default launches as false. URL launch is a non-default `GURL`
request, handled by
[application(_:open:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)).
This uses the same gate without timers, whether URL delivery precedes or
follows launch completion. Actual URL-launch notification/event ordering is
not measured by off-screen routing tests; the user retests it on screen.

### Transport and discovery

System `/usr/bin/ssh` supplies one retained foreground `-M -N -T` master per
native remote window. Its unique `/tmp/ka-…/c` ControlPath directory is 0700.
Bounded `-O check` readiness precedes discovery. BatchMode, strict pretrusted
host keys, ConnectTimeout=10, one attempt and keepalive=15×3 apply to all
channels. Agent/X11/inherited forwarding, tty, RemoteCommand, ControlPersist,
fork-after-authentication, null stdin, LocalCommand, SendEnv and host-key
updates are disabled. User/account/port/identity/ProxyJump and configured
known_hosts remain OpenSSH's responsibility; local SSH_AUTH_SOCK can authenticate
but is not forwarded. Authentication/trust failures stop automatic setup and
ask the user to establish trust/unlock keys with ordinary ssh in Terminal.
No passwords, credentials, interactive shell sourcing or automatic installation.

Discovery runs a fixed `/bin/sh` probe remotely: absolute `command -v kido`
and `${XDG_STATE_HOME:-$HOME/.local/state}/kido-app`. Missing kido gives an
install/noninteractive-PATH banner; there are no guessed installation locations.
Relative/control-containing paths or noisy/malformed stdout are errors. Explicit
Connect may call that kido's `server --server DIR`; JSON tmux/socket paths are
opaque remote values, not local files. The returned socket must end in `/socket`;
its parent is retained for feed/navigation. Local retains bundled-tmux validation.
Discovery decodes the server's protocol stamp, not its build ID. The required
protocol is 1.0: the major must match and the minor must be at least 0.
Local mismatches, including unstamped servers, offer Restart with confirmation
that all sessions and panes will end. Remote mismatches offer only Reconnect,
which repeats discovery after the user upgrades kido and restarts its server.
There is no compatibility waiver or remote restart. The bundle's captured
BUILD-ID detects an app replaced on disk and requires relaunch independently
of the server protocol.

Control attach and duplex RPC (including switch-window) share the owned master,
with `ControlMaster=no`. One audited POSIX single-quote function quotes every
remote argv element after `exec`; Host is never interpolated into shell text.
Remote HOME/PATH/XDG are resolved there, not forwarded from the Mac. Only
VISUAL/STRESS test injection supplies private remote HOME/XDG/PATH. The tested
login shell is zsh; the fixed probe uses /bin/sh. Protocol stdout and bounded
16KiB stderr are separate. One-shots have deadlines and cancellation; channels
terminate then escalate to SIGKILL rather than relying on stdin EOF. Channels
are stopped before the master (1.5s grace), which is reaped before removing
its private directory. Initial topology plus a valid v2 feed snapshot must
arrive within 20s of attach to dismiss the connection banner.

Unexpected control loss redials with capped backoff and a full surface/model
reset. It recreates the master and attaches the **remembered** socket using
`-N`, never running start-capable discovery. A missing server leaves the explicit
**Start remote server** action. Deliberate `%exit detached` stays down. Feed-only
failure restarts the feed on healthy control; master loss invalidates both and
cancels commands together. OpenSSH can fall back to a direct connection after
a master dies: launches refuse a known-dead/stopped master, and the owner rejects
old-generation/dead-master completions rather than accepting fallback as recovery.

Two native windows on the same server/session share tmux's current window and
pane grid, sized by its latest elected client. This coupling is accepted; there
are no grouped sessions. Models, client names, feeds, surface caches, find and
scroll state remain disjoint even when both endpoints issue `$0/@0/%0`.
Authoritative external layouts are clipped, not resized into independent grids.
HTTP/HTTPS links from remote panes open on the Mac; remote file paths and other
schemes are refused with a diagnostic. No implicit port forwarding/file transfer.
Mac clipboard/paste and unsafe-paste sheets remain local; the full OSC52/auth/URL
matrix is still unverified (see known issues).

### Prepared localhost and manual entry-point check

The user may add this **only for noninteractive SSH** to `~/.zshenv` (no startup
stdout); it does not shadow Homebrew kido in ordinary terminals or interactive SSH:

```zsh
if [[ -n ${SSH_CONNECTION-} && ! -o interactive ]]; then
  path=("$HOME/Workspace/kido-app/app/build/xcode.noindex/derived-remote/Build/Products/Debug/Kido.app/Contents/Resources/kido/bin" $path)
fi
```

Check `ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes localhost
'command -v kido; kido --version'`. Keep the bundle's bin directory together so
its kido finds its matching sibling fork/resources. The app connects to the
account's kido-app server, not the normal Homebrew kido server. Tests do not
change startup/SSH files and always inject private `/tmp` HOME/XDG and explicit
server/socket paths over localhost.

Before shipping, the user/parent must prepare a **distinct app identity**, not
register the default derived Kido.app over the running installed app:

```sh
make -C app all DERIVED=build/xcode.noindex/derived-remote XCODE_SETTINGS='PRODUCT_BUNDLE_IDENTIFIER=com.andreypopp.kido.remote-test INFOPLIST_KEY_CFBundleDisplayName=KidoRemoteTest CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=LC2633WWXE'
```

The output is `app/build/xcode.noindex/derived-remote/Build/Products/Debug/Kido.app`,
displayed as KidoRemoteTest. Xcode defaults live under `app/build/xcode.noindex/`
to keep built apps out of Spotlight; private builds should use
`DERIVED=build/xcode.noindex/derived-<name>`. Explicit DERIVED paths are honored.
Non-app caches such as GhosttyKit remain outside that directory.
Check its Metadata.appintents and `codesign --verify --deep --strict` before
registration; use a clean build if an incremental metadata addition invalidates
the signature. Register only that absolute bundle path with
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f`.
A distinct bundle ID isolates **app routing, not server state**: these user-driven
checks attach the account's real kido-app server. They require deliberate user
approval for that attachment, must never Restart/kill it, and are not agent-run
private-state tests. Shell-exported HOME/XDG around lsregister does not prove
Spotlight inherits them.

Quit only KidoRemoteTest, then run a saved Shortcuts workflow containing that
team-signed test app's **Connect to Remote Host in Kido** action and Host=localhost.
Stop if the action's identity is ambiguous. Verify exactly one remote native
window and **no Local window** on cold launch. Repeat while running: another
remote window must appear, not replace the first. This cold-launch check passed
on screen; Spotlight does not list the action directly. Also retest the URL
recipe above cold and warm; it works with ad-hoc builds too.
Separately quit only the test app and plain-open it with
`open -b com.andreypopp.kido.remote-test`: one Local window must appear. Warm
intent delivery then adds remote without replacing Local; reopening with a live
remote window must not create Local. Finally quit only the test app, unregister
only its absolute bundle path with lsregister `-u`, and remove only the user's
test workflow. If URL ordering fails, record the lifecycle. OS-delivery steps
are user-run, never part of the off-screen implementation checks.

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

Every restore captures the newest 10,000 physical history rows plus
screen, pending parser bytes and mode state in one command batch, then
resets and replays the surface. Initial sync, reconnect, resize and showing
a content-dirty pane share that path. History uses styled `-e -J` and
plain `-F -L -T -N` companions; a plain screen companion joins the same
logical rows across the history/screen seam. The oldest partial logical
line is omitted. A line spanning the entire interval is omitted rather
than expanding the restore. Extra history loaded earlier is deliberately
dropped.

Wheel and thumb cover only Ghostty's retained rows. They never capture
history or expose unloaded blank space. One native Load more pill appears
near the loaded top when tmux has older rows. A click loads the next
10,000-row chunk, aligned to whole logical lines, through the shared
loader. Explicit loads can expand a chunk for a long line, bounded by
tmux's total. Empty or malformed captures stop without pretending to be
memory pressure. A refused nonempty insertion leaves the same pill;
another click raises that surface's byte budget and retries. Refusal
survives metadata refreshes. There is no idle trim.

`ghostty_surface_prepend_history` snapshots the primary grid and page
identity under the renderer mutex, parses a scratch terminal outside it,
then validates and clones the pages under the mutex. Existing pins and
selections stay attached to their content. The chunk is accepted whole
or not at all, without evicting newer rows. Kido defaults to a 512 MiB
scrollback budget; configuration can override it. Raised limits survive
appearance/config updates but not surface destruction or reconnect.
Ghostty's normal byte-budget eviction and the app's surface LRU remain.

Connection keeps tmux's sampled history total separate from retained
Ghostty rows. Output invalidates metadata/exhaustion but never loads
older history. Restore/load/search requests read metadata; wheel and
scroller requests reaching the loaded top also refresh it without loading
history. Hidden panes refresh on show. There is no history timer, and
renderer notifications do not query tmux. A fresh shrink/clear invalidates navigation and repairs content
through the common restore, joining an active gesture's final repair.
tmux has no universal history-content generation: arbitrary same-sized
external replacement between samples is not immediately observable.

A resize captures the viewport's logical count and text once at its first
intent. Intermediate accepted grids are installed and confirmed inline;
Ghostty's local reflow is provisional. Capture waits for gesture end and
the final client-size or floating-command/layout drain. A newer gesture
invalidates an in-flight snapshot even if its dimensions end unchanged.
There is at most one snapshot in flight and one coalesced successor;
already-sent obsolete transactions drain without publishing. Move-only
or unchanged-cell gestures need no new content capture unless a prior
restore obligation or content invalidation remains.

The anchor resolves only inside that snapshot, with nearest matching text
within ±32 logical lines, ties toward newer rows, and an in-range count
fallback. An anchor outside the capture or actual budget-shortened
retention goes to the live bottom. It never pages or clamps to the oldest
loaded row. Scrolling, typing, paste and find cancel the old viewport
intent without canceling required content repair.

Retained hidden panes install accepted grid changes too, so subsequent
output is parsed at tmux's width. Dirty epochs survive A→B→A and equal
dimensions; only a current authoritative restore clears them. Showing a
dirty pane repairs it. Possible font/scale/config reflow follows the same
invalidation and confirmed-grid path; color-only changes remain local.

Each pane draws one thin overlay scroller, shown during scrolling or
hovering and fading afterwards. The scroller track spans the expanded content while its thumb and targets count whole grid rows. Ghostty's own scrollbar is disabled. The
thumb uses the loaded history rows plus the screen, with a native-style
minimum knob size. Every precise wheel event adds its delta 1:1 to the
fractional target, including nonzero ended packets. At most one apply is
pending on the pane's serial scroll worker; it starts immediately and reads
the latest output-adjusted target when it runs. Its main callback coalesces
presentation, then applies a changed target.
Ghostty schedules rendering;
the app adds no display link, deferred packet, easing or momentum filter.
Ghostty's mouse-scroll-multiplier precision setting remains the user's speed
override; precision 2 restores the previous speed. Discrete wheel notches
are unchanged. An active selection gesture uses integral wheel steps.
Thumb drags replace the target; a thumb press snaps once and suppresses
old momentum. Snaps apply the integral viewport directly on main before the
triggering input reaches Ghostty. A short viewport lock excludes worker applies
from that operation; pending applies retain their slot and read the aligned
target, while their obsolete presentation is rejected by the revision.
The pixel-scroll API returns geometry and signed whole-row viewport movement
from the same renderer lock as revision validation and mutation. A failed
attempt publishes neither; a committed move remains successful even if its
render wake fails. Snaps record only the successful attempt's movement, never
a separately sampled before/after difference.
Clicks, selection, typing, paste, IME, find, resize, font
changes and focus loss also snap and suppress momentum. Main publishes only the worker's successfully applied distance and
geometry to the thumb and presentation, not the requested target.
If all three revision attempts fail, presentation stays at the last success
and the target waits for another event or geometry update, with no idle retry.
Capture publication
updates loaded geometry and requests presentation, never moving the viewport
itself; unchanged geometry and memory-limit state do not request another
apply. Snapshot replay invalidates applied viewport revisions at both its
start and end, then asynchronously reapplies the latest preserved target even
when capture metadata is unchanged. Replay cannot complete a final render;
revision validation and acknowledgement commit share the scroll-intent lock.
Main snaps and resets stamp the revision captured before their apply, so replay
cannot make an older apply appear current. Replay never enters live-output
pin-delta accounting.
Live output shares the serial worker and pins a scrolled viewport,
adjusting its distance from the bottom; a zero target follows the bottom.
Hidden and occluded panes retain their renderer rules and do no idle
scrolling work.
`KIDO_APP_DEBUG=1` logs wheel timestamps, phases and deltas, and each applied
target's row and fractional pixel offset.
The thumb's range and size use loaded geometry. Colours resolve in the current
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
match list. An unloaded match submits a tokened coverage goal to the same
10k loader as the pill, automatically raising the surface budget on
refusal. Later navigation replaces that goal, including cancellation when
a loaded match is selected. Query changes, output and resize cancel it;
a post-restore scan does not automatically reload a canceled old goal. Ghostty
search supplies the highlights and loaded-match selection; it is restarted
after prepending history. Each restart ends the previous Ghostty lifetime.
Ghostty tags totals and selected indices with that lifetime's immutable
generation and rejects queued events after it ends. The surface's delivery
epoch advances on each new search and both public stop operations, including
stops with no active search. Nonempty edits in a live search keep its epoch.
The runtime captures the main-only epoch getter when accepting an action,
then checks it again inside the weak, asynchronous PaneView delivery.
Clearing or invalidating without restarting therefore rejects already accepted
actions too. A replaced search cannot
inherit an old count or selection. End-search also captures the find-view
identity on main, so its queued close cannot close an empty reopened bar,
which has not issued a new Ghostty lifetime yet. Nonempty needle changes without stopping remain in one lifetime;
these generations are not per-query tokens for arbitrary Ghostty clients.
Budget retries and chunk expansion are bounded; genuine resource or capture
failure reports a failed search without evicting newer rows. Command-G and Shift-Command-G (also Return
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
free. A hidden surface is occluded and its renderer released. Shown surfaces
follow the app window's occlusion during resize too. Provisional Ghostty reflow
remains visible while the authoritative capture is in flight. After replay and
the successful restored viewport apply, an asynchronous tokened render fences
completion, not visibility. Its acknowledgement must match the pane's epoch,
backing dimensions, inset and viewport revision/target. Superseded requests
coalesce; a current discarded request gets one asynchronous retry. Backend
failure remains incomplete and diagnostic, without a visibility hold. tmux sends no `%output` for panes outside the client's session,
so a window that left it is synced again when next shown. Surfaces of closed windows and sessions are freed.

tmux's layout is authoritative: every Ghostty surface is exactly its
pane's grid, and `PaneLayout` maps cells to points. On each axis a
pane's two inner paddings sum to one cell minus one device pixel, split
floor/ceil in physical pixels so surfaces and dividers stay on the pixel
grid. tmux's border cell between two panes is then exactly their
paddings plus the one-pixel divider, so any tree, however asymmetric,
lines up with no surplus. Around the whole terminal area only, the
horizontal remainder is balanced over a 4pt minimum. Client rows are
floor((height - 40pt - 12pt) / cell height), reserving a 12pt bottom grid gap.
The tiled grid bottom is 12pt above the terminal area bottom, rounded upward
onto a whole device pixel if necessary: the gap is at least 12pt and less
than 12pt plus one device pixel. Left, right and bottom edge panes extend their chrome to the terminal
area bounds, owning the side margins and bottom gap as padding. Background,
dimming and padding input reach those edges; toolbar hot zones and scroller
strips follow the new pane boundary, with the knob still 4pt inward. The
content, chrome and divider tops respect the 44pt titlebar margin plus the separator's device pixel. Client rows reserve both, with device-pixel rounding. Below the fixed 44pt
`PaneLayout.topMargin`, the global vertical subcell remainder sits above the
whole tiled tree. Only outer-top tiled panes expand upward into it, rendering
the bottom slice of their preceding history row through Ghostty's top render
inset in backing pixels. Every inner tiled top and bottom expands through its
vertical padding to the horizontal divider: the top uses the floor half and
the bottom the ceil half of a cell minus one device pixel. Following rows
and history are clipped at the divider, not the grid's padding edge; the
line remains above both panes and its hit/cursor zone wins over band input.
Outer-bottom tiled panes expand down to the window
content bottom through the bottom render inset, showing following rows when
scrolled up, clipped only at the window edge. At the live bottom there are no
following rows, so the band is plain background below the fully visible last
row. Empty history shows background. Alternate-screen panes keep their
unexpanded grid view and zero insets, leaving background in both bands. Zoom uses the same rule. Each top band runs from the grid top to the separator or split divider, possibly spanning several history rows. The full-width one-device-pixel separator sits at 44pt; outer-top vertical dividers meet its bottom edge. Dividers stay behind tiled panes and floats. During a stale-root shrink, terminal content is clipped below the separator without changing its grid. Committed and free floating chrome frames are bounded below the separator too.

PaneLayout returns the grid, expanded content, clipped chrome and paired render insets
for each tiled pane. Chrome uses the content rect for hit testing;
window-edge drops and their previews use the union of the visible tiled chrome.
Top and bottom band clicks only focus/select the pane once: no terminal mouse press or selection
starts there. Entering either band clears Ghostty's hover position. Band wheels
scroll primary history without sending application mouse reports.
Mouse and IME coordinates use the grid origin below the strip. Render insets
never enter set_size or set_grid_size, scroll distances, snaps, output pinning
or resize anchors; the live bottom remains distance zero. Floats stay inset-free
in the same shifted grid coordinate space, with the point-to-cell inverse and
pixel-exact free frames unchanged. Floating bounds end at the same pixel-aligned 12pt bottom margin,
so a float's existing bottom padding remains above that margin. Dividers have
six-point hit areas; unfocused panes are dimmed by a theme-background overlay; a
pane shows the window’s shared glass toolbar only in its top-right hot
zone: the toolbar frame plus 24pt to its left and below, clipped to the
pane. It splits, zooms and closes through the same commands as the menus.
The toolbar's grip drags a tiled pane: the target's outer quarters dock
left, right, above or below; its centre swaps. A 22pt
band inside the tiled area's outer edges takes precedence, docking across the whole
window with `move-pane -f`. Window edges preview the resulting half-window;
centre drops preview the whole target for a swap. Pane edges show a 4pt
insertion bar, not a predicted size: tmux splits the target before removing
the source and redistributes its space (`third_party/tmux/cmd-join-pane.c`,
`cmd_join_pane_exec`), so predicting that size would duplicate its layout code.
Window-edge drops let
tmux handle already-spanning panes; one tiled pane has no drop targets.
The accent highlight follows
the effective appearance. A drop sends one `move-pane` or `swap-pane`, and
only tmux's layout notification moves the views. A click, Escape, a drop
on the source or a floating pane cancels. Dragging is disabled while zoomed.
Floating grips and padding share one move gesture, starting after 4pt of
movement; resize edges follow the pointer immediately. A press without movement
raises a covered float with `move-pane -z 0`. Draggable padding is inside the
drawn frame but outside the Ghostty grid, including the fractional right/bottom
remainder. The 5pt resize edges and corners, toolbar and scroller strip take
precedence; terminal clicks remain Ghostty's. Padding cursor rects show an open
hand. A moving or resizing float holds its gesture cursor, with the window's
cursor rects disabled until release or cancellation. Disconnect, removal from the
window, window resignation or closing, and app deactivation cancel the gesture.
Placement requests no cursor invalidation during that gesture; release enables
and invalidates the acquired window's rects once, so overlapping floats use their
current frames immediately. Tiled padding
still only selects. WindowView keeps a view-only free frame
per float after release. Coalesced, one-in-flight command batches send its
rounded cell geometry to tmux with the border-dependent position and size
semantics. Nested command batches finish at a private marker on a separate
input line: tmux gives nested replies the same control flag as direct ones,
and a failed batch drops the remainder of its line. Ordinary command batches
still pair by count, with no marker or extra round trip. PaneLayout owns the point-to-cell inverse and floating bounds.
Layout installs and placement validate free frames against that same conversion;
presentation validates hidden windows too. A changed placement cancels an active
gesture and drains only the already-sent commands. Zoom, removal, layer changes
and reconnect also clear free frames. Nothing is persisted. Ghostty remains exactly tmux's whole-cell grid,
with the fractional size remainder in the right and bottom padding. Chrome,
mask, shadow and hit areas use the drawn frame; pixel clamping keeps it inside
the window grid. Resizing clamps only the dragged edges, preserving their
opposite edges; a right or bottom resize never moves the origin. Each pointer
update places only that float, its backing and toolbar, and unchanged clamped
frames do no placement or cursor invalidation. Full placement assigns each
pane's final frame once. Placement skips unchanged backing, toolbar and scroller
frames and retains an installed mask rather than assigning it again. In-flight gestures retain their pixel frame until a follow-up
command reply has drained the final batch's layout notifications, then keep it
only if it matches tmux. Escape stops further commands,
not changes tmux has already applied. Pane command errors appear in a sheet.
Sidebar drops are not supported.

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
serializing live output with asynchronous viewport applies. Main must never
wait for that queue: parsing can fill Ghostty's app mailbox, whose surface
messages are drained by `ghostty_app_tick` on main. Ghostty's stream handler
releases the renderer mutex before waiting for mailbox capacity, so main can
still take that mutex through the thread-safe pixel-scroll API to snap before
handling input. The viewport lock serializes snaps with worker applies, but
is never held across output parsing. Its cumulative snap adjustment removes
snap-induced offset changes from feed's before/after output-pinning delta:
`D1 - D0 - sum(snap movements)`. The ledger is cumulative across feed intervals
and is not reset while one can be active. It distinguishes multiple snaps
from concurrent output, even when history grows between a read and an apply.
A zero target still follows the bottom. Lock order is viewport then target
or renderer, with neither held while waiting for viewport. MANUAL_MIRROR
applies grid resizes inline in Termio, not on a debounced IO-thread callback;
grid confirmation reads the actual grid under the renderer mutex.
Only feed synchronizes with the scroll queue, from the client queue, never
main or a Ghostty callback. Snapshot/prepend admission validates the content
epoch under a short app lock, which is released before parsing. While a
mutation is admitted, main coalesces the latest accepted grid/reflow rather
than waiting for the worker. Completion installs and confirms that grid.
If output was dropped while a grid was unconfirmed, incremental feed stays
suspended until a current reset-and-replay commits; a provisional parse
cannot clear a newer dirty epoch. Renderer
callbacks publish asynchronously to main; runtime wakeups coalesce main ticks.
Ghostty requests IO/process termination, marks search stopping and joins it,
then joins IO while the renderer still drains. Only after both producers have
stopped does it stop and join the renderer and release shared resources.
Search and PTY IO surface-message sends retry in 10ms intervals, checking their
stopping flag between attempts, so a full app mailbox cannot prevent these
joins on main. Canceled owning parser messages are freed. Renderer messages,
including ordinary end-search highlight clears, remain ordered and delivered;
blocking batches wake their consumer before enqueueing. Manual-output callers
must already be quiesced before destruction; joining Ghostty IO does not stop
an external parser caller.
Search input uses a mutex-protected growable FIFO. Producers append, release
the mutex and wake; the consumer detaches one batch and processes it outside
the mutex, freeing unprocessed needles on stop or failure. Main never waits
for search-input capacity, including navigation bursts while search is waiting
for main's app mailbox. Pending growth under an indefinite producer is the
tradeoff for preserving command order. Other main-to-renderer blocking sends
are not removed by this change.
A pane leaving the layout is held on main until the queue has
dropped it, so its
surface is freed on main. A layout reaches main synchronously. Unless a
parser/prepend mutation is admitted, its grid is installed and verified through
Ghostty's mutex-protected actual metrics before layout installation returns.
During an admitted mutation the latest desired layout is recorded instead;
unconfirmed geometry suspends feed until installation/readback and a current
authoritative restore. A failed setter or mismatched
grid rejects feed and prepend, logs a diagnostic and closes the control
client through its ordinary redial lifecycle; failure is never confirmation. Main never waits on the
reader queue.

## Sidebar

The sidebar runs the bundled `kido rpc --server DIR --client NAME` with
the app's own client name, so kido's rules follow what the app shows. The
in-repo [RPC contract](../share/rpc/contract.md) is authoritative. The first line
must be a compatible hello; a server mismatch stops the feed and uses the same
banner as discovery, without automatic retry. Filters are JSON requests and
window navigation uses numbered RPC requests. Replies can interleave with
snapshots and arrive out of order; pending callbacks live on the feed reader
queue and complete once, including failure when the connection ends or restarts.
The app decodes unknown enum values as unknown and v2 snapshots only:
sessions are source-list sections,
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

`make visual` runs hosted SnapshotTesting tests against a private tmux
socket, never ordering or activating a window. Menlo 13 and the built-in
light/dark themes isolate terminal-area image and compact layout references:
single panes at three heights, splits, floats, zoom, fractional history,
alternate screen, settled resize and the Load more pill. A test-only
`KIDO_VISUAL` build condition exposes an occlusion bypass through
`@testable`; normal builds retain their occlusion policy. Each image waits
for a tokened Ghostty presented-frame callback, not a timed delay. Native fixture
windows use Display P3, matching the references rather than the attached
monitor's calibrated profile. The off-screen floating-sidebar fill takes its
rounded corners from the sidebar layer; the transparent corners show the
underlying window/terminal, not a cached opaque material rectangle.
`make visual` also launches a private, background copy and sends SIGTERM to its
main-dispatch handler, checking natural exit after asynchronous quit completion.
Liquid Glass (sidebar and pane toolbar) and animation/scroll smoothness are
not covered. Re-record with `make visual RECORD=1` after intentional visual
changes, a macOS update or a different backing scale, and review the images
and layout diffs. References live in `app/VisualTests/__Snapshots__`.


`make tsan` and `make asan` build Debug with ReleaseSafe GhosttyKit into
`build/xcode.noindex/derived-{tsan,asan}`. ASan defaults to `use_sigaltstack=0` because Zig
threads replace its alternate signal stack with thread-local storage.

The Main Thread Checker needs no rebuild: launch a Debug build with
`DYLD_INSERT_LIBRARIES=$DEVELOPER_DIR/usr/lib/libMainThreadChecker.dylib`
and `MTC_RESET_INSERT_LIBRARIES=1`, which keeps it out of the feed and
tmux. Leaks are checked with `MallocStackLogging=1` and `leaks`,
`footprint` and `heap` on the pid, compared after attaching, after
switching past the surface budget, and after closing all but one window.

`KIDO_APP_SERVER` (a private 0700 directory) and `KIDO_APP_TMUX` point the app at a private
server; `KIDO_APP_FEED` names a stand-in feed. `KIDO_APP_BACKGROUND=1`
keeps a test launch off screen: it never activates, never takes focus
and keeps no preferences. `KIDO_APP_DEBUG=1` logs each switch, eviction
and free to stderr with its timing.

### Stress harness

`make stress SEED=N DURATION=S [FIND=0]` builds the app with the
`KIDO_STRESS` compilation condition into `build/xcode.noindex/derived-stress` and runs it
for S seconds against a private tmux server; `make tsan-stress` and
`make asan-stress` do the same with the sanitizers (own derived dirs). The
condition is set only by these targets: `App/Stress.swift` holds only a typealias in every
other build and `main.swift` has one `#if KIDO_STRESS` call site.

`scripts/stress.py` (stdlib Python) builds the demo-like layout, including
1M- and 100k-line history panes, with `scrollback-limit = 8 MiB`, and every 0.4s
applies a tmux action chosen from `SEED` (switches, splits, kills, zoom,
resizes, move-pane, client resizes, feed kills, server restarts at 40% and
80%). In the app `Stress` does the same on the main queue, also seeded: wheel,
scroller drags, scroll requests, find and next, resync, window resize
bursts, load-more, pane grip drags (some killed mid-drag), edge resizes,
detach and reconnect, appearance. It writes one JSON line per action to
stderr (`build/stress/<target>-<seed>/stderr.log`; `actions.jsonl` is the tmux
side; `summary.json` the counts). `FIND=0` swaps the find actions for scroll
requests. A run fails, exits 1 and prints its replay command on a sanitizer
report, panic, non-zero exit, an app that did not finish, a new
`Kido*.ips`, or a step that saw the window visible, key, main or active.
A seed is a best-effort reproduction: choices also depend on the observed
tmux topology, and timing against live output is not reproducible.
`actions.jsonl` records the tmux actions actually taken.

Off-screen rule: the window is never ordered in (`KIDO_APP_BACKGROUND=1`),
is a `StressWindow` that refuses key and main, and input is only
`NSWindow.sendEvent` with `NSEvent.mouseEvent`/`keyEvent` or a direct call.
App-local `NSApp.postEvent` queuing is allowed and needed by button tracking;
system-wide or pid-targeted CGEvent posting is forbidden. Nothing activates.
Every step logs `visible`, `key`, `main`, `active` and the number of this
process's windows in the on-screen window list. Wheel events do not reach a
view through `sendEvent` off screen, so the wheel action calls
`PaneView.scrollWheel` with an NSEvent made from a scroll CGEvent. Grip actions
expose the chosen chrome's toolbar through `mouseMoved`, then invoke that
enabled grip's existing `press` closure for down, drag, up and Escape.
Scroller drags and floating edge resizes call their own mouse entry points:
off-screen `sendEvent` does not reliably reach them. This covers the drag
logic, not AppKit event delivery or hover. Stress pane-command failures are
logged instead of opening an error sheet. Only a “can't find pane” error for
a pane tmux reported gone or either harness side logged as killed is expected
(`killed_race`); every other
pane-command error fails the run.

`KIDO_ALT_VERIFY=1` on a stress build runs a bounded deterministic mailbox
pressure probe instead of random actions. It seeds numbered history, applies
a fractional viewport and immediately double-clicks through PaneView to check
the selected row after snapping. A background feed then enters/exits alternate
screen around 20000 title changes and output rows. Main holds mailbox draining until 65 app wakeups from the parser thread
establish pressure against the 64-entry app mailbox, then snaps during that
feed; both main and worker must complete. Renderer-thread wakeups do not count.
`KIDO_INPUT_VERIFY=1` uses that same barrier, waits for the search sender at the
full app mailbox, and submits 256 alternating navigation commands plus needle
changes before stopping without a main drain. `KIDO_SNAP_VERIFY=1` rendezvouses
output between main's snap preparation and apply, checking one and two snaps,
bottom following, a rejected revision followed by success, and pinned numbered
rows after the pending worker apply. `KIDO_FIND_VERIFY=1` checks deferred stale
actions, real current navigation/selection, history prepend, and close/reopen.
The Zig counterpart checks that current selection enqueues a renderer highlight;
together these are two halves, not an end-to-end rendered-highlight observation.
`scripts/concurrency-probes.py <absolute-app-path> <KIDO_*_VERIFY> <log-name>`
launches each off screen against its own private socket with a 25-second process
deadline, killing only that launched pid on timeout. Every probe records the
same invisibility/focus checks as random stress. No Swift Task spins a run loop.
`KIDO_RESIZE_VERIFY=1` enables rendering only for unordered test surfaces,
checks a rejected unrealized final frame, compares stopped-output IOSurface
pixels against a fresh replay with identical geometry and a 19px inset,
asserts red/blue fixture content, and checks stability and failed-grid feed
rejection. `KIDO_GRID_VERIFY=1` isolates the failed-setter assertion.
`KIDO_REPLAY_VERIFY=1` establishes a new scroll target's successful apply before
snapshot replay, then checks its restored viewport, reference pixels and final
acknowledgement with unchanged metadata. `KIDO_REPLAY_FENCE_VERIFY=1` adds an
app-validator fixtures: a replay reset between a snap's apply and publication
must invalidate that apply, and a synthetic old presentation callback delivered
during barrier-held replay must not acknowledge it. Normal replay completion must then
produce the current viewport, pixels and real render acknowledgement.
`KIDO_VIEWPORT_VERIFY=1`
rejects a final frame when a same-target viewport revision failed all three
apply attempts. These
probes do not establish Metal's late GPU-completion ordering; the bounded
same-queue handler gate probe could not advance past its older handler.
Set `KIDO_MTC_VERIFY=1` with `DEVELOPER_DIR` for Main Thread Checker: the runner
injects it only into Kido and verifies its mapped image in that PID. Injecting
it into the Python launcher with `MTC_RESET_INSERT_LIBRARIES=1` removes the
injection variable before Kido starts, so does not check Kido.

To cover a new feature, add a case to `Stress.Action` and its weighted array,
and an exhaustive branch in `Stress.perform` driving existing internal API; add tmux
actions in `scripts/stress.py` if the feature reacts to server state.
