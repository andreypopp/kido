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

A pane is synced by one command line: its captures, pending parser
bytes and mode state. tmux queues `%output` ahead of the reply, so
output before the reply is wiped by the restore and output after it is
fed live. The same resync follows a `%pause`.

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

tmux's layout is authoritative: each surface is sized to exactly its
pane's cells, and the client size is the content area's cells.

## Threads

Client callbacks run on the client's reader queue, and the pane map is
touched only there, so a surface is fed on one queue. A pane leaving
the layout is held on main until the queue has dropped it, so its
surface is freed on main. A layout reaches main synchronously, and a
pane's first feed after a resize waits until Ghostty confirms the new
grid, so output never lands in the old one. Main never waits on the
reader queue.

## Sidebar

The sidebar runs `kido sidebar-feed --socket --client` with the kido
the server names in `side-status-command`, so the feed matches the
server, and the app's own client name, so kido's rules follow what the
app shows. The contract is in the feed's help and in kido's tests; the
app decodes v1 only. The search field is the one store of the filter:
each feed process is sent it on start and on every edit.

## Testing

`KIDO_APP_SOCKET` and `KIDO_APP_TMUX` point the app at a private
server; `KIDO_APP_FEED` names a stand-in feed. `KIDO_APP_BACKGROUND=1`
keeps a test launch off screen: it never activates, never takes focus
and keeps no preferences. `KIDO_APP_DEBUG=1` logs each switch, eviction
and free to stderr with its timing.
