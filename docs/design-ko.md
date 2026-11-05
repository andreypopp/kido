# ko, the terminal server

ko is the terminal server of Kido. It holds the terminal of every pane
in libghostty-vt, serves Kido.app and the `ko` terminal client over one
protocol ([protocol.md](protocol.md)), and runs the agent features of
[design.md](design.md) in the server. This document records the design
as built and the reasons for it. Its last section lists the decisions
with their dates.

## 1. Why

Kido does not run on a terminal multiplexer with a control protocol
made for another client. That design has these costs: two emulators
must agree, content goes through text captures, status comes from
polling with whole-second times, two app windows share one current
window, and each change of the multiplexer's configuration restarts
the server. A purpose-built server removes each cause.

## 2. Goals and non-goals

Goals, in priority order:

1. **One emulator.** The server holds the authoritative terminal of
   every pane in libghostty-vt. A client never has state that the
   server cannot reproduce exactly.
2. **A client protocol made for Kido.app**: versioned, with push
   events, per-view flow control, snapshot and live bytes, history on
   demand, images by reference and typed input.
3. **Status as events.** OSC 133, OSC 7501, titles, pwd, exits and
   topology arrive as events with the server's clock. The status
   model runs once, in the server.
4. **Several clients that do not fight.** Each client has its own
   current session, window and pane. Two viewers of one window still
   share its size, because a pty has one size.
5. **Upgrade without losing panes** (not built; plans/ko-upgrade.md).
6. **Remote** over SSH with the same protocol, with reconnect.
7. **A terminal client in tmux's shape** for a plain terminal: a
   `C-a` prefix, a status line, a list grouped by session and the
   shown window with its splits, zoom and floats, as Kido.app shows
   it, a resize mode and a copy mode.

Non-goals:

- Compatibility with any multiplexer's clients, commands, configuration
  files, plugins, hooks or key tables. ko's one configuration file
  (4.14) holds only what cannot be derived.
- Linked and grouped sessions. A per-client current window covers
  their use.
- Scripting the server from the shell beyond the `ko` CLI and `ko api`.
- Surviving a reboot.

## 3. How a client gets content

Three designs are possible:

- **Bytes to the client, the client emulates.** Rejected: two
  emulators must agree on every byte, and each difference is a
  content bug.
- **Render state to the client, the client only draws.** The purest
  design, but Kido.app has no renderer that takes external rows, and
  it moves per-row serialization into the server's hot path.
- **A mirrored libghostty-vt, synchronized by snapshots.** Both the
  server and the client run libghostty-vt. The server is
  authoritative. The client's terminal is a mirror that receives the
  same bytes, in the same order, with resizes at the same byte
  offsets. Whenever the mirror could diverge, or when a client
  attaches, the server sends a **snapshot**: libghostty-vt's binary
  record stream, whose READY prefix restores the complete renderable
  state (the pen, the charset, the pending wrap, the unfinished parser
  input, the modes, the images with pending pixels), and whose later
  records carry the history pages and the image pixels.

ko uses the third. The reasons:

- Kido.app keeps its Ghostty surface and renderer and gains one entry
  point: restore a surface from a snapshot stream.
- The correctness argument is deterministic emulation: one library,
  one revision, the same inputs. Where inputs cannot be identical
  (history depth after a resize), the snapshot is the escape hatch,
  and a READY prefix is the size of the screen.
- Live bytes are the smallest encoding of what changed.
- The terminal client is a libghostty-vt mirror too.

The server's own terminal answers every query from the program, is the
source of snapshots, encodes typed input with the terminal's current
modes, runs the status callbacks, owns image storage, and searches
history for a client that has not loaded it.

## 4. Architecture

### 4.1 Processes

The server is two programs:

- **`ko`, the coordinator** (`ko_server`), one for each state
  directory. Its socket is `<dir>/socket`. It owns the layout
  document, the clients, the HTTP and WebSocket protocol, the ring and
  the fan-out to views, skips and snapshots, sizing and focus, the
  clipboard answerer, the status model, the sweep and the prompt. It
  never links libghostty-vt.
- **`ko-pane`, the pane process** (`ko_pane`), one child process for
  each pane, with no policy. It opens the pty and spawns the program
  (`ko_sys::pty::spawn`), feeds everything the pty produces to its
  terminal, answers the program's queries into the pty, encodes typed
  input with the terminal's modes, and writes the record stream into
  a shared ring that both processes map. Its stdin and stdout are the
  control channel (protocol.md, section 14). It exits when that
  channel closes, and its program gets `SIGHUP` with it.

Why a process for each pane: a libghostty-vt abort kills one pane and
not the server; parsing runs on one core for each pane with no threads
in the coordinator; a coordinator upgrade moves no terminal state; and
an idle `ko-pane` costs little memory. The price is one hop for each
record, tens of microseconds.

Every ko process is one thread on the readiness loop of
`ko_sys/src/event.rs` (AGENTS.md, "The loop"). Backpressure toward a
program is the ring: if the coordinator falls a whole ring behind,
`ko-pane` blocks, stops reading the pty, and the program blocks.

A pane's exit status comes from `ko-pane`, which reaps its program and
sends a `dead` frame; the coordinator reaps `ko-pane` itself on
`SIGCHLD`. A pane whose program exited stays as a dead pane with its
status and signal, and its `ko-pane` stays alive to hold the screen
until a client removes the pane. The run rules of design.md need this.

The protocol is HTTP/1.1 over the unix socket, with WebSocket for the
long-lived streams. Each stream is its own connection, so a flood in
one pane never delays a control reply or another pane. The coordinator
checks the peer uid on every accepted connection (`ko_sys/src/sock.rs`);
there is no other authentication.

### 4.2 Crates

AGENTS.md, "Layout", names each crate. The coordinator's modules in
`ko_server/src/`:

`server.rs` runs the listener, the signals and the output tick over
the state of `state.rs` and `state/`, which owns the connections, the
panes (`pane.rs`, `panes.rs`, each with its `pane_proc.rs` child), the
clients (`client.rs`), the layout document (`layout.rs`) and the
waiters; `state/pane_ops.rs` holds `POST /panes`, the pane stop with
its escalation and what a pane identity may do (`router.rs` checks
the identity itself), and `state/sweep.rs` the sweep. `view.rs` and `delivery.rs`
are the verified stream path
(AGENTS.md, "Verus"); `conn.rs`, `ws.rs`, `http.rs` and `deflate.rs`
the connection, the framing and the slice codec; `api.rs`, `route.rs`,
`router.rs`, `protocol.rs` and `schema.rs` the routes, the wire types
and the OpenAPI document. The status model is `telemetry.rs`,
`program_status.rs`, `pane_kind.rs`, `pane_status.rs` and `model.rs`
([design-program-status.md](design-program-status.md)); `vars.rs`,
`inbox.rs`, `clipboard.rs`, `shm.rs` and
`agent.rs` own the variables, a pane's
message queue (its routes in `state/messages.rs`), the clipboard answerer, the
shared-memory leak record and the `agent.sock` link; `config.rs` the
state directory, the options and the knobs. `runtime/` holds the
runtimes' registry, links and exec helpers over the configuration of
`ko_config`, with
`state/runtime_ops.rs` and `state/exec_ops.rs` over them
([design-runtimes.md](design-runtimes.md)).

`ko_vt` is the safe binding of libghostty-vt for both processes: the
terminal, the snapshot encoder and decoder, the render state, the
search and the frame API. `ko_pane_wire` is the frame codec and the
ring. `ko_client` is the client core that `ko_tui` and Kido.app share.

### 4.3 The pane's terminal

Each pane has one terminal inside its `ko-pane`. The coordinator sends
the options in the `init` frame; `ko_pane/src/pane.rs` registers the
callbacks:

- The reply path: `ko-pane` writes the terminal's replies to its pty.
  A mirror has no pty, so it never answers.
- OSC 133 (`SEMANTIC_PROMPT`) and OSC 7501 (`PROGRAM_STATUS`): the
  callbacks only record; after the write, `ko-pane` sends one frame
  for each recorded report, so a report frame follows the ring record
  of its bytes. libghostty-vt answers the OSC 7501 query itself.
- Title, pwd, bell, notification, progress, clipboard write and read.
- The continuation limit, so a snapshot can carry an unfinished
  sequence.
- The scrollback limits and the kitty image storage limit of the
  `server:` key of the configuration file (4.14), read when the pane
  is created. Scrollback
  compression is always on (`ko_vt/src/compress.rs`): after 250 ms
  with an unchanged activity token, `ko-pane` runs one incremental
  step for each loop turn until the library reports completion; after
  2 s of continuous activity it runs one step every 10 ms. The mirror
  runs the same steps on a thread of its own.
- `TERM` is `xterm-ghostty` in every pane, with the terminfo that
  `make build` compiles from Ghostty's source beside the server
  (`TERMINFO_DIRS`). ko owns the whole pane environment.

Cell pixel size comes from the window (protocol.md, section 3).

**The mirror contract.** A mirror is exact only if it is the same
libghostty-vt revision with the same terminal limits as the server.
The server sends its limits in the `Welcome` event, and a client
applies them before it opens a view. The Ghostty fork that
`third_party/ghostty` pins is the one libghostty-vt of ko and
Kido.app; the `Ko-Vt` header refuses a different revision.

Output handling in `ko-pane`, for each wakeup of the pty: read until
the read would block, straight into the ring at its head (macOS gives
at most 1 KiB for each pty read); parse that region in place, which
runs the callbacks; publish the record; send the queued frames, and a
`head` frame only if the coordinator is idle. A busy coordinator
scans the ring on its 2 ms output tick, which runs only while output
continues.

A program that writes a few bytes for each `write` (`yes | head`,
which writes each line alone) makes every read small: without a delay,
`ko-pane` reads about 6 bytes each time, a million read attempts and
half a million polls each second, and the syscalls, not the parse, use
its whole core. So `ko-pane` paces its pty reads (`Pace` in
`ko_pane/src/run.rs`, which holds the thresholds): after a few small
reads in a row, close together, it stops watching the pty and reads
again when a 50 µs timer expires, while the reads stay small. A
large read, an empty read, a full ring, typed or control input, a
signal and the program's exit return it to immediate reads. A quiet
pane's first read, thus a keystroke's echo, is never delayed, and
input reaches the pty without waiting for the timer. 50 µs is below
the time that a flood of 3-byte writes takes to fill the macOS pty's
1 KiB (about 250 µs), so the program never blocks on a full pty
because of the delay. Each later read then gets a few hundred bytes.
macOS `poll` takes whole milliseconds, so `ko_sys::event` waits with
`select`, which takes microseconds, for a deadline below 1 ms; Linux
waits with `ppoll`. The coordinator copies nothing: for each attached view it
writes the ring region with one `write_vectored` (AGENTS.md, "The
view write path"), and it allocates nothing on the heap for each
record in steady state.

A resize, a reset and the pane's death are **markers** in the ring at
their byte offset. A mirror applies them in order.

The foreground process of the pty, which the status model reads, comes
from `ko-pane` (`ko_pane/src/foreground.rs`): it reads `tcgetpgrp` only
on events (protocol.md, section 14), never on a periodic timer, so an
idle pane never wakes.

### 4.4 Snapshots

The sync unit is the libghostty-vt snapshot: versioned, CRC-protected
records, READY after the renderable prefix, then history pages newest
first and image payloads, then FINISH. `ko-pane` encodes it into the
ring as slice records, and the coordinator writes the slices to the
view from the ring, so a 100k-line history is streamed, not buffered.
The snapshot carries its output offset, so the mirror applies the
bytes that follow it.

Two kinds exist and there is no page addressing: **full**, every
record to FINISH, after which the mirror is full; and **screen**, the
records to READY only, after which the mirror is partial. `ko-pane`
cuts the stream at the record headers (`ko_vt/src/cut.rs`), which is
also how `images=none` drops the payload records: the decoder keeps
those images pending, and the client fetches the pixels as resources.

A client decodes on a thread whose reader blocks on the view, swaps
its terminal at READY, and keeps reading until the last slice. A new
snapshot abandons a decoder in progress. A partial mirror that wants
history takes a full snapshot and swaps terminals; this is the cost of
the first scroll-up over a slow link, never a cost of attach.

A snapshot carries the terminal's modes, with one exception: the
server clears synchronized output (mode 2026) in every snapshot it
encodes, because a client that restored it set would defer its
rendering until its own timeout. The kitty keyboard flags are restored
as state: the mirror holds them, and the outer terminal is configured
by the client, never by replayed bytes.

### 4.5 The layout document, panes and clients

The layout is one JSON document in the coordinator: sessions in
display order, each with windows, each with a split tree of leaves
with cell geometry, floating panes, a zoom state, a name, a size and
its cell pixel size. It has no active pane: the current pane is for
each client. Ids are `session_N`, `window_N`, `pane_N` and
`client_N`, allocated once for each server life and never reused.

The server validates the document's structure and normalizes its
geometry (`ko_server/src/layout.rs`, a port of the split arithmetic
that Kido.app expects, checked by proptest against the invariants:
every live pane once, sizes that sum to the window, every leaf at
least one cell, a `PUT` of the normalized document is a fixed point).
A client changes it by a whole-document `PUT` with the revision it
read; a stale revision gets `409` with the current document, and the
client reapplies its edit (`ko_client/src/edit.rs` and `layout.rs`).
Normalization, not an exact rule, lets one engine do every split,
resize, equalize and scale computation of an edit, and a `409` retry
never recomputes every size. A client's window size is the exception:
the server applies it to the stored tree with tmux's rule (below).

A **client** is one open `/client` WebSocket: it exists from the hello
to the close, with no linger and no orphans. The client owns what it
shows: a reconnect is a new client whose hello carries its state
again. The window that a client shows is sized by the client that
claims it: the one whose input focus is on the window, or the one
that last switched to it. A size from another client never claims the
window, because a second app window on a smaller monitor would
otherwise steal the size on every resize of its own. When the sizing
client disconnects, the window keeps its size until another client
claims it.
Kido.app and the terminal client follow the same rule for every window,
with splits and floats too. A client sends the size of the area where
it shows the window, never a leaf size, and the server fits the tree
into it with tmux's rule (`layout_resize_adjust`), so a size change
gives the panes the sizes that users of tmux expect: along a split, the change goes one cell at a time to
each child in order, from the first, until it is spent; a shrink
skips a child at its minimum; a split across the axis gives each child
the whole change. So a side-by-side pair shares a sidebar's change,
and a grow followed by the same shrink restores the sizes when no
minimum stopped a child. A client that does not size the window draws it at the
server's geometry, anchored top left, clipped where the window is
larger and blank where it is smaller.

The server starts with an empty document and keeps running with an
empty one when the last session goes; a client that finds it empty
`PUT`s one session with one pane. A `POST /panes` window and the
sweep's removals are server-made changes of the same document.

### 4.6 Views and flow control

A **view** is one client's subscription to one pane's content, one
WebSocket on its own connection, so its backpressure is the
connection's: the kernel socket buffer locally, the SSH channel window
remotely. The server writes without blocking. When a view's write
would block, it stops writing it and counts what it did not send.
When the connection drains: below the resume threshold (64 KiB,
`ko_server/src/view.rs`) it sends the backlog from the ring, markers
included; otherwise it sends a skip and a screen snapshot at the
current offset. The same rule decides a reopen with an offset. The
server never stalls a pane for a slow client beyond the ring, and it
never discards output silently: a skip is a snapshot.

The ring is one anonymous shared mapping for each pane (1 MiB;
`ko_sys/src/mapping.rs`: `memfd_create` with seals on Linux,
`shm_open` with an immediate unlink on macOS), created by the
coordinator before the spawn. Its indices are sequentially consistent
atomics (AGENTS.md, "Proved modules"). The coordinator moves the
tail past data that no view can still resume from; a view whose
unsent bytes passed the threshold gets a snapshot anyway, so it never
holds the writer. No pending write ever references the ring: a partial
write copies the rest of its frame into the connection's queue.

A view's queue has a cap, and output past it goes to an unlinked spill
file (`ko_server/src/spill.rs`) that the connection drains after the
queue, so a snapshot larger than the cap reaches a slow reader whole
and the memory of each view stays at the cap; a spill over its limit
closes the view with a close frame (protocol.md, section 4). The cap
and the spill limit are `KO_VIEW_QUEUE_BYTES` and
`KO_VIEW_SPILL_BYTES`, read by `ko_server/src/config.rs`.

Measurements that fix the design: on macOS a non-blocking writer on a
unix stream socket accepts exactly its own `SO_SNDBUF` before it blocks,
whatever the reader's buffer, so the server sets `SO_SNDBUF` and the
client `SO_RCVBUF` to 1 MiB on view connections. With 8 KiB, reader
stalls of 20 ms skipped; with 1 MiB, stalls of 50 ms every 100 ms did
not. The 2 ms coalescing cut the coordinator's work by about four
times and kept the hop's p99 near 100 us, and a single 2 ms record
reaches 64 KiB only above 32 MB/s for one pane, so the threshold counts
only the backlog after a blocked write, never every record.

Snapshot slices are deflated (`miniz_oxide`, level 1) and live bytes
are raw (protocol.md, section 4). The reason is in "Remote" below.

### 4.7 Input

A client sends typed events (protocol.md, section 8). The coordinator
validates them and forwards them as frames to the pane process, which
encodes them with its terminal's modes: a key through libghostty-vt's
key encoder, a paste with bracketed paste if the program asked for it,
a mouse event with the pane's tracking mode. `text` carries bytes that
a sender without key events already encoded, such as the CLI's prompt
delivery. Focus is not input: the server derives it from the clients
and sends focus in and out to the pane itself.

The pty write path never drops input: `ko-pane` writes at once, queues
when the write would block and drains on writable. A paste with an id
is answered only after the pty accepted every byte.

### 4.8 Queries, clipboard and consent

The server's terminal answers every query from the program. The
clipboard is the exception, because the answer lives in a client:
protocol.md, section 9, gives the one-answerer rule and its deadline.
Consent, grants and "always allow" stay in the client. The server
never decides.

### 4.9 Pane variables

Every pane carries arbitrary client-set JSON variables
(protocol.md, section 7). They live with their pane and never persist
to disk. The server stores and announces variables and reads only
these names:

| variable | writer | trust rule |
|---|---|---|
| `pi.session`, `pi.name`, `pi.activity` | the pi harness through `ko api` | believed only while the pane's root OSC 7501 app is `pi` |
| `ssh.dest`, `ssh.args` | `ko ssh` before it execs ssh | believed only while the pane's foreground process is `ssh` |

Session and window variables live inside the layout document.

### 4.10 Status, runs and the model

The model (`ko_server/src/model.rs`) runs when an event marks a pane
dirty, at most once per 16 ms, and never otherwise: a dirty mark arms
one timer, and an idle server with idle panes arms none. It writes
the pane's `status` and sends a `status` event for that pane only.
Times are the server's monotonic clock in nanoseconds. The server
builds no tree: a client builds its own from the layout document and
the pane rows' `parent` (`ko_client/src/model.rs`).

The sweep (protocol.md, section 10) runs over the pane rows on each
event that can end a pane. design.md, "Window lifecycle", gives its
rules.

**The loop rule.** Coordinator state changes only on the loop thread.
A long poll or a deadline is a stored waiter in the state plus a loop
timer, never a thread. The loop reads a waiting connection for its
hangup, and a waiter whose connection closes is forgotten (a pane
stop then removes its pane at once). A thread is permitted only for blocking work
that touches no coordinator state. An endpoint that does not fit this
rule needs a recorded decision before it is built.

### 4.11 The terminal client

`ko` with no arguments is the terminal client (`ko_tui`). It shows the
client's current window as the layout document draws it, and lists
every pane in a sidebar grouped by session, with a subagent's pane one
column deeper than its parent's. It is a client like any other: it
opens one view for each visible pane, mirrors each in libghostty-vt
and closes the view when the pane leaves the screen.

`ko_tui/src/geometry.rs` walks the window into one rectangle for each
leaf, with one divider cell between the children of a split, as the
document reserves it, and a junction glyph where dividers meet. The
active pane's dividers are green. A zoomed window has one rectangle,
the zoomed pane, and only that pane has a view: closing the hidden
panes' views keeps the server's write work proportional to the screen,
and a snapshot reload on unzoom costs milliseconds. Floats are drawn
after the tree in `z` order, with their border outside the content
and clipped to the pane area. The module is pure, in `ko_tui` and not
in `ko_client`, because it has one user: Kido.app computes its
rectangles in Swift (`PaneGeometry`) and keeps them. A dead pane's
line is the last row of its rectangle. Keys go to the active pane, the client's current pane;
the outer terminal's cursor and modes follow it, except that mouse
tracking is always at least button motion (1002), so that a divider
drag reports its motion; the pane still gets only the events that its
own tracking asks for. A press in another
pane selects that pane; a pane that tracks the mouse gets the press,
drags and release in its own coordinates, and the wheel scrolls the
mirror under the pointer or goes to that pane when it tracks the
mouse. A zoomed window's zoomed pane is the active one, as in
Kido.app: when another client zooms a pane that is not current, the
client selects it, and a jump to a pane that a zoom hides first ends
the zoom with a layout edit.

Each mirror keeps its own compressor thread, so N visible panes are N
views and N threads, each idle without output. A frame is fetched only
when its mirror's generation changed, so a quiet pane costs nothing in
a paint, and the differ writes only the changed cells.

One writer draws the screen: a direct cell differ (`ko_tui/src/differ.rs`)
writes the composed cells of the pane region, the sidebar and the
status line, the last row of the screen. The pane area that the
client sends as its size is the screen without the sidebar and
without that row. Input that changes the screen draws the next
frame at once; continuous output is drawn at most once per 8 ms, in
one write bracketed by synchronized output. The client emits indexed
SGR for indexed cells, so the outer terminal's palette applies. The
wheel scrolls the mirror; after a skip the first scroll-up resyncs with
history.

Its keys follow tmux's default table under the prefix `C-a`, which is
not configurable; README.md lists them. One pure state machine
(`ko_tui/src/keys.rs`) owns every key mode (the pending prefix, the
help overlay, the status-line prompts and the sidebar chooser) and
turns each key into a key for the pane, an action or nothing. `C-a C-a`
sends `C-a` to the pane, so a nested ko_tui or a tmux with `C-a`
takes `C-a C-a` as its prefix. The prefix has no timeout, as in tmux,
and an unbound key after it is discarded. `Ctrl+D` on a dead pane
removes it without the prefix, because a dead pane takes no input.
Every other key goes to the pane. `C-a` arrives as byte `0x01` from
any terminal and as `CSI 97;5u` under the kitty keyboard protocol;
both decode to the same key, so the client works the same in every
terminal. It pushes kitty keyboard flag 1 on the outer terminal for
the panes and requires nothing of it.

Copy mode (`ko_tui/src/copy.rs`) uses vi keys, as Kido.app's copy
mode does: one vocabulary serves both clients, the emacs table needs
`C-Space` and `M-w`, which many terminals do not deliver, and choosing
by `EDITOR` would be configuration by environment. Three keys differ
from tmux's vi table, for vim's and Kido.app's vocabulary: `v` begins
a selection (tmux's `v` toggles a rectangle), `C-v` toggles the
rectangle, and `y` copies beside tmux's `Enter`. Its coordinates are
history rows, counted from the top of the mirror's history, the row
space of `ko_vt::Terminal::total_rows`. On entry the mirror freezes: it
still reads its link, so the server's backpressure does not build, but
it drops the records; on exit a mirror that dropped records asks for a
resync and discards records until the new snapshot begins. So the
history does not move under the cursor, and the position indicator is
exact. The client refuses to enter while the mirror restores a
snapshot or holds synchronized output, because its rows are not yet
the pane's. A line selection takes whole logical lines, across soft
wraps. Only one pane is in copy mode, and the mirror is the one record
of it; selecting another pane, a reconnect or a change of the pane's
size leaves it. In copy mode no mouse event reaches the pane. A copy
goes to the outer terminal as OSC 52 and into the client's one paste
buffer, which lives in the client process, not in the server.

Copy-mode search (`/`, `?`, `n`, `N`) runs on the frozen mirror with
`ko_vt::Terminal::search`, not on the server's `/panes/{id}/search`:
the mirror holds the whole history and its rows do not move, while the
server's rows move with output (protocol.md section 11). The prompt and
the running search are state of `copy::Mode`, the one record of them;
the mirror starts or drops its ghostty `Search` to agree with it. A
paste into an open prompt adds its text without control characters; a
paste into copy mode without a prompt is dropped. A full search of 100k
lines with a match on each takes about 55 ms (52 ms resident, 57 ms
with compressed pages), too long for one turn of the loop, so the
client steps it for at most 2 ms in each turn and polls without a wait
while a search runs; keys between the steps act at once. `Escape`
drops a running search and stays in copy mode; `q` leaves; `/` or `?`
replace the search. One ghostty search tick can take about 6 ms, and
the turn that completes a search also converts every match to a history
row (about 15 ms for 100k matches), in one call, because ghostty's
matches are valid only until the next change of the terminal. `n` and
`N` use the last completed search, never a running one. The compressor
thread does not step while a search is live, because a compression step
changes the terminal under the search; it is the loop that steps the
search, so the compressor still never wakes the loop. Ghostty's search
folds ASCII case only. It reports the end of a match on a wide
character at the character's first cell, and the highlight covers both
cells. In the alternate screen, copy mode and its search see only that
screen. The matches are sorted, and the renderer finds the match of
each visible cell by binary search.

The status line has tmux's default shape and colours: the session and
its windows by position on the left, `*` on the shown window and `-`
on the last one, and on the right the pending prefix, a prompt (a
rename or a kill confirmation) or the reconnect notice. Windows are
numbered from 0, tmux's `base-index`, so the label and the key `C-a 0`
to `9` agree; the sidebar numbers panes from 1. The status line is
always on and has no key to hide it: it carries the prefix indicator
and the modes, which have no other place when the sidebar is hidden.
tmux shows nothing while its prefix is pending; ko shows `C-a`,
because it costs one word and makes a stuck prefix visible. The window
commands go to the server as `ClientRequest::Switch` (next and
previous window or session) or `Select` (a position, the last window
or session); renames are layout edits, and kills are `DELETE` of the
window or pane.

The pane commands (split, zoom, swap, equalize and the resize keys)
are layout edits through `ko_client::layout::edit`, the call of
`ko layout edit`, which applies each edit to the newest document and
retries on a `409`; the layout event that follows redraws the window.
A refused edit (a float cannot be split, the pane is gone) does not
end the client. After a split the client selects the new pane, as
Kido.app does; a split of a zoomed pane ends the zoom, so the new
pane is visible. Selection commands only send `Select`: `o` takes the
next pane in document order, floats after the tree; `;` the pane the
client showed before in that window; a direction the neighbour across
the divider on that side whose span holds the active pane's cursor
row or column, else the one with the largest overlap, with no wrap.
Floats are never neighbours, and a float has none. A direction to a
pane that a zoom hides ends the zoom first. Selection and resize keys
repeat as tmux's `bind -r` does: for 500 ms after one, another
repeatable key acts without the prefix. `C-a l` selects the right
neighbour, the user's choice over tmux's last window, which is
`C-a Tab`. Under the legacy encoding `C-h` and `C-j` arrive as Backspace and
Enter, so directly after the prefix those two keys also select; in
the repeat window they go to the program. Outer mouse reporting stays on while a pane is shown,
so selecting text in the outer terminal needs its override modifier.

`C-a *` is a toggle, not tmux's new floating pane, because it reuses
`Edit::Float` and `Edit::Unfloat` and needs no float geometry keys: a
new float is `C-a %` then `C-a *`. The server places a float with no
geometry, and a float docks on the right of a tiled pane of its
window. `C-a !` is `Edit::BreakPane`, an edit of `ko_client`, so
Kido.app and `ko layout edit` share it: the pane, tiled or a float,
leaves its window and becomes the tree of a new window after it,
which takes the name of the window it leaves. After a break the client selects
the pane, so it shows the new window.

Resize mode (`C-a R`) is a state of the key machine: each key is one
layout edit of the active pane, sent at once, so two fast keys are two
steps, as in Kido.app. A resize of a zoomed pane ends the zoom, which
`Edit::ResizeBy` does. The status line shows `[resize]` and the active
pane's dividers turn yellow instead of green. `C-a` leaves the mode
for the prefix, so `C-a d` works in it; the mode also ends when the
active pane leaves the shown window, or the view closes.

A press on a divider starts a drag. The motions of one read of stdin
become one step, the last position, which goes as one
`Edit::ResizePair` with Kido.app's arguments
(`PaneGeometry/Layout.swift`): the first leaves of the two children
beside the divider, and the position less the first child's origin as
the first size. Where dividers meet, the outer split's divider wins.
A layout change during the drag finds the pair's divider again in the
new geometry, or ends the drag when the pair has none. The drag never
reaches a pane and selects none. It ends at the release, and also at
a focus loss, a motion without its button or a new press, because a
terminal can lose the release outside its window; that new press then
acts as usual. A zoomed window has no dividers, and a float's border
is not one.

The sidebar's separator, the column just left of the pane area, is a
drag target too, under the same rules for its end. Its drag changes
the sidebar's width: the pointer's column becomes the width, so the
separator stays under the pointer, and the pane area that the client
sends as its size follows at once, with no layout edit. A pane
divider is inside the pane area, so a press never has both targets.
The width is at least 10 columns and at most half the terminal's
columns, rounded down; on a terminal of fewer than 20 columns the
half wins. An outer resize clamps it again. The width lives in the
client process for its life, as the paste buffer does: it is not
saved, it is no configuration (the non-goal below), only the pane
area that follows from it goes to the server, and Kido.app has its
own list.

The sidebar is also a place for focus, a mode of the key machine
beside resize mode, which it excludes. Copy mode stays the mirror's
state, and entering the sidebar or resize mode leaves it, so the
three never overlap. A left move (`C-a h`, `C-a C-h`,
`C-a Left`, or one of them in the repeat window) from a pane on the
window's left edge moves focus into the shown sidebar, and does
nothing when the sidebar is hidden, as a move with no neighbour does.
A tiled pane is on the edge when its rectangle in the unzoomed tree
starts at the pane area's first column, so a zoomed pane with a left
neighbour still ends the zoom and selects it; a float is never on
the edge, because a float has no neighbours. Focus in the
sidebar is a cursor on a pane, kept as the pane's id, never a row:
it starts on the active pane, `j` `k` and the vertical arrows move it
over pane rows only, with wrap, as the chooser does, and when a
layout change removes its pane it takes the row at the same position
in the new list, else the last one. `Enter` shows the pane as a click
on its row does, in any window or session and through a zoom, and
returns focus to it. `Escape` and a right move (`C-a l`, `C-a C-l`,
`C-a Right`, or one in the repeat window) return focus to the pane
unchanged. Every other key is swallowed, so nothing reaches a program
while the program cannot be seen to have focus, and a paste is
dropped. The prefix keeps its table, so `C-a d` detaches from the
sidebar, except that `C-a C-a` sends nothing, because no program has
focus. `C-a C-s` never moves focus, except that hiding the sidebar
returns focus to the pane. The cursor's row is drawn in reverse
video, and the status line shows `[sidebar]`. A press in a pane
returns focus to that pane; a click on a sidebar row acts as before.

`C-a R` with focus in the sidebar enters resize mode for the
sidebar's width, the keyboard twin of the separator drag, so the
width needs no mouse. `h` and `Left` narrow it by 1, `l` and `Right`
widen it by 1, `H` `L` and the Shift arrows by 5, under the drag's
clamp, and the width stays the client's as the drag's does. Other
keys and a paste do nothing. `Enter`, `Escape` and `q` leave, and
`C-a` leaves for the prefix, as in pane resize mode, but focus
returns to the sidebar with its cursor, not to the pane. The
separator turns yellow, as a pane's dividers do, the pane's dividers
stay green, and the status line shows `[resize]`. A press in a pane
and hiding the sidebar end the mode and return focus to the pane, and
a reconnect resets it, as they do for sidebar focus.

The client restores the outer terminal's modes exactly on every exit
path, and never sends RIS or clears the screen. It queries the outer
terminal at start, so replies arrive on stdin among keystrokes; the
input decoder (vte, then `ko_tui/src/input.rs`) routes them.

The status column shows one mark for each pane row
(`ko_tui/src/renderer.rs`): a running agent or command, a waiting agent, an unseen success, an
unseen failure. The seen rule is in `ko_client/src/status.rs`, shared
with Kido.app: a visit acknowledges an outcome or exit, and a later
one with a new serial shows again.

`C-a e` opens the pager over the pane's scrollback. Copy mode also
covers the history; the pager costs one row of the table and stays.

**Not built.** The terminal client reads no configuration: the user
asked for zero configuration, and the non-goal of a multiplexer's
configuration files and key tables holds. A `tui:` key of
`config.yaml` (the prefix key, the status line on or off, the
sidebar's width and default visibility, the copy-mode key table) is
not planned. These tmux bindings have no ko equivalent and are not
built:

- The command prompt (`:`), a command language, hooks and key tables:
  the non-goal above.
- Preset layouts (`M-1` to `M-7`, `Space`) and rotate (`C-o`, `M-o`):
  the layout document has no preset shapes.
- Pane marks (`m`, `M`), pane titles (`T`), the clock (`t`) and the
  information popups (`i`, `~`, `q`): no need.
- Window index prompts (`'`, `.`) and the fuzzy chooser (tmux's
  `Tab`): the sidebar chooser is the one list, and ko's `C-a Tab` is
  the last window.
- Buffer lists (`#`, `-`, `=`) and server-side paste buffers: the
  copy buffer is one buffer in the client process.
- Activity markers (`M-n`, `M-p`): the status marks of the sidebar
  cover them.
- Detach another client (`D`): no route moves another client (decided
  2026-11-03).
- Suspend (`C-z`): a signal to the own pid, which `ko_sys::pid`
  refuses.
- Emacs copy-mode keys: the reason in the copy-mode paragraph above.
- Float creation by drag and float move keys (`g`): a float is
  created, focused, read and removed; its geometry changes through
  Kido.app or `ko layout edit`.

### 4.12 Images

Placements, image metadata and animation state travel in the view
stream or the snapshot. Pixels are resources, one for each frame,
fetched by image id, frame number and generation (protocol.md,
section 5). The generation is a serial that the bytes alone decide,
so the pane and every mirror compute the same value for the same
frame state. On a local server the client maps a shared-memory
object by name; remotely it gets the pixels as a body, streamed from
the coordinator's own mapping. `ko-pane` owns the objects; the
coordinator keeps the leak record (`ko_server/src/shm.rs`) because it
is the one process that outlives a pane, and macOS cannot enumerate
POSIX shared memory. Animation has no fallback: the Ghostty fork
reads frame `n` and attaches fetched pixels to a pending frame outside
the snapshot decoder (`ko_vt/src/frames.rs`).

The pane's terminal decodes PNG (`f=100`) to RGBA frames with wuffs.
Upstream's lib-vt artifact leaves the decoder out; the fork keeps it
when kitty graphics is on (`third_party/ghostty/src/terminal/sys.zig`),
because a PNG that the pane refuses lives only in a shown mirror's
live bytes, so a restore or a later view has nothing to show.

### 4.13 Lifecycle and the command line

`ko server --server DIR` runs in the foreground and listens on
`DIR/socket`. `DIR` is `$KO_STATE_DIR`, else `$XDG_STATE_HOME/ko`,
else `~/.local/state/ko` (`ko_server/src/config.rs`), created with
mode 0700. The server refuses a directory with other permissions or
another owner, a path with a comma, and a socket path over 103 bytes,
the macOS limit, on every platform.

`ko` connects. With no socket, or a refused connection (the one case
in which the socket file is stale; a connect timeout means a busy
server), it takes `DIR/launch.lock`, starts `ko server` detached with
its stdio to `DIR/log`, waits for the socket with a deadline of 5 s,
then connects (`ko_client/src/launch.rs`). Two `ko` started at once
start one server. The server runs until `ko kill-server`, which sends
no HTTP request: it reads the server's pid and uid from the socket's
peer credentials, refuses another user's server, sends `SIGTERM` and
waits up to 5 s for that pid to end. `SIGTERM`, `SIGINT` and `SIGHUP` stop the server: it removes
its socket, closes its listener, hangs up every pane, waits 500 ms,
kills the survivors and exits. Because the socket goes first, a server
that starts during the 500 ms keeps its own socket.

The launcher does not compare versions: a server that another ko build
started on the directory is used as it is. When that server refuses the
`/client` upgrade, the terminal client reads `GET /version` and, for
another protocol or terminal revision, fails with both versions and
builds, the command `ko kill-server` that ends every session and pane,
and the advice to start again (`ko_tui/src/client.rs`); for `ko HOST`
the command runs on the host. A server that refuses the hello
(docs/protocol.md, section 3), at the first join or at a reconnect, makes
the terminal client fail at once with the server's own text.

`ko api` sends one HTTP request, as `gh api` does, and never starts a
server. With `--stream`, it upgrades a WebSocket route, prints each
text message as one line and sends each line of its stdin as one text
message, for a script or a harness that answers on its message
stream or runs an exec session. `ko panes`, `ko layout` and `ko layout put` or `edit` are
readers and writers of the document from the shell. The signal rules
of AGENTS.md ("Signals") apply to every kill.

`ko server --help` lists the server's options; `ko_server/src/config.rs`
reads its environment knobs (design.md, "Knobs"), and `ko_server/src/panes.rs` sets the
variables of every pane, `SSH_AUTH_SOCK=<dir>/agent.sock` among them,
which a pane's `env` can replace. `--bin-dir` is the shim directory put
first on every pane's PATH (design.md, "The bin directory"); the
`server: shell` of the configuration file reaches every new pane as
`KO_SHELL`. `--config FILE` names the configuration file (4.14). A runtime's listener is
in `DIR/runtimes/<name>/`; a socket path there that is too long fails
that runtime's start, not the server.
At start the server links `agent.sock` to its own inherited agent only
when the path is absent or a link to no socket file
(`ko_server/src/agent.rs`), so Kido.app's publication wins.

### 4.14 The configuration file

ko has one configuration file, for what cannot be derived:
`$XDG_CONFIG_HOME/ko/config.yaml`, else `~/.config/ko/config.yaml`,
else the file of `ko server --config FILE`. It has one top-level key
for each owner: `server:` and `runtimes:` are the server's, `app:` is
Kido.app's. Each host reads its own copy: a server reads the file of
the host that it runs on, and Kido.app reads `app:` from the Mac's
file, also for a remote window, and never sends it to a server. An
editor checks the file with `share/ko/config-schema.json` through an
optional first line:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/andreypopp/kido/main/share/ko/config-schema.json
server:
  scrollback: {bytes: 100000000, lines: unlimited}
  shell: /bin/zsh
app:
  font: {size: 15, features: [ss13, -ss17]}
  theme: {light: kido-light, dark: kido-dark}
```

The crate `ko_config` owns the file: the types (`config.rs`,
`server.rs`, `app.rs`, `keys.rs`, `runtime.rs`), their newtypes
(`values.rs`), the path rule, the decode, the theme writer
(`theme.rs`) and the JSON schema, which `ko api-schema --config`
prints and `make schemas` regenerates. It depends on no ko crate. The
types and their `///` docs (the schema's descriptions) are the
reference for every key, its default and its range. This section gives
only the rules around them.

**The decode.** serde's derive decodes every type, with
`deny_unknown_fields` on every record, and schemars' derive gives its
schema. A rule that serde cannot state, such as an absolute path, a
name, a range, a connection-only `ssh_args` or an option of
a container engine's `run` that ko owns, is the `TryFrom` of a newtype. Only the
format is written by hand (`ko_config/src/yaml.rs`): saphyr-parser's
events become a tree with positions, and one serde `Deserializer`
reads it. It resolves scalars by the type that asks:

- A string field takes any scalar as its text, so `yes`, `no`, `on`,
  `NO`, `0755`, `1:20` and the `2222` of `ssh_args` stay as written.
  Thus `option_as_alt: on` is the word of an enum, not a bool.
- A bool, an integer or a float field takes only the YAML 1.2 core
  schema's plain forms: `true`/`false` in three cases, decimal, `0o`
  and `0x` integers, and the core floats. No YAML 1.1 forms: `yes` is
  not a bool, `0755` not octal, `1:20` not sexagesimal. A quoted scalar
  is never a bool or a number.
- A plain `~`, `null` or an empty value is null. A key with a null
  value is the same as a missing key, also in a map such as `env`;
  the schema is stricter and does not allow the null.
- `deserialize_any`, which a word-or-value key such as `scrollback`,
  `runtime_idle_seconds` or `theme` asks for, gives a plain core-schema
  integer or float as a number and every other scalar as text. Thus
  `bytes: 0x100` is a count, and a quoted `'600'` is text, not seconds.
  No config type is an untagged or internally tagged serde enum, so no
  string field is buffered through it.

The decode refuses a duplicate key, more than one document, a tag and
a key that is not a scalar. It expands anchors and aliases. While it
builds the tree, it refuses a file, a depth or a node count (aliases
expanded) over the caps of `yaml.rs` and `config.rs`, so a hostile
file costs the server no more than the caps. YAML 1.2 has no merge
key, so `<<` is an unknown field. An error is a `Problem`: the path of
keys and items to the value with its fault, and the value's line and
column. The CLI prints it after the file's path: `runtimes: dev: ssh:
ssh_args: -N is not a connection option; ko owns the rest of the ssh
command at line 5 column 17`. The file is valid or invalid as a
whole: a wrong `app:` key also fails the server's runtime requests,
and a wrong runtime fails the app's load.

**`server:`.** The server reads the file again at each use of a
`server:` key, as it does for `runtimes:` (design-runtimes.md, "The
configuration file"). Thus an edit applies without a restart or a
reload command, and nothing watches the file:

- `shell`, `scrollback` and `kitty_images_max_bytes` when a pane is
  created. A pane keeps the values that it started with. `shell` is
  the pane's `KO_SHELL`, the shell of a `shell` command, and the name
  that a new window gets. Without it, the shell is the `$SHELL` that
  the server had at start, else `/bin/sh`. `scrollback: none` keeps no
  history; each of its `bytes` and `lines` is a positive count or
  `unlimited`.
- The scrollback and image limits of the `Welcome` (protocol.md,
  section 2), when a client says hello.
- `linger_seconds` when the sweep finds a dead `close: on_exit` pane,
  and `runtime_idle_seconds` (or `none`) when a runtime's idle timer
  starts. Both are decimal seconds, so a test can set 0.2.

A file that does not decode gives the `server:` defaults, so a typo
never stops the user from opening a shell to fix it. The runtime
requests fail with the error. Each setting has one source: the shell,
the scrollback, the image limit, the linger and the runtime idle are
`server:` keys and have no option or environment variable. The knobs
that only tests and tuning need are environment variables (design.md,
"Knobs").

**`app:`.** Kido.app's terminal settings: the theme pair, the font,
the keyboard, the mouse, the clipboard, the window shades
and `keys`. This is a closed whitelist that the app maps to the
Ghostty configuration that it generates (design-app.md, "Panes"): each
key has a type, a default, a range and one Ghostty key, and no user file
reaches Ghostty. A Ghostty option joins the whitelist by a decision, one
key at a time. Colours live only in theme files, so the picker can show
every colour that applies; `config-file` includes do not exist; and the
options of windows, tabs, shells, notifications, scrollback and image
storage are the app's or ko's, not Ghostty's. The cursor's style and blink are
not settings: the restore of the server's snapshot replaces the
mirror's defaults with the server's, so the app fixes
`cursor-style-blink = false`. A key
binding maps a `Trigger` (Ghostty's `modifier+key`, kept in one
canonical spelling) to an `Action` of the few that Kido names. A
trigger of the app's own menus (`ko_config::keys::MENU_OWNED`) is
refused, in any spelling. An absent `font.family` is the system's
monospaced font, which the app resolves. The server decodes `app:` and
does not use it.

**The C ABI.** Kido.app reads the file through `ko_client`, because
the app must work without a server. `ko_config_defaults` returns the
default path and the default `Config`, which the app uses at a launch
with a bad file. `ko_config_load` returns the whole
decoded `Config` as JSON, with every default filled in, or the
`Problem` with its line and column. The app decodes the JSON with the
Swift types that `app/scripts/gen-ko-model.py` generates from the
schema. `ko_config_set_theme` is the theme picker's writer. It edits
the lines of `app.theme`: it replaces the block, else adds the block
at the end of `app:`, else appends an `app:` block. It keeps every
other byte, and writes each name as a double-quoted scalar. It decodes
the result before it writes and refuses a result that does not decode
or whose `app.theme` is not the requested pair. Thus a line-based edit
never leaves a broken file: a `theme:` in a flow mapping or a block
scalar is refused, not corrupted. It writes a temporary file beside
the target of a symbolic link. Just before it renames that file over
the target, it reads the target again: a target that changed since the
edit started is a conflict, and nothing is written. An edit between
that read and the rename is lost; the window is one read long. The header `ko_client/include/ko_client.h` gives the
codes and the JSON.

## 5. Remote

Transport: a unix socket forward on an SSH master. `ko HOST`
(`ko_client/src/remote.rs`) starts `ssh -M -N -T` with a private
`ControlPath`, asks for `-O forward -L <local>:<dir>/socket`, and
attaches to `<local>` as to a local server. Each connection is one
`direct-streamlocal` channel with SSH's own window as its
backpressure; these channels are not sessions, so sshd's `MaxSessions`
does not cap the number of views. Nothing runs on the remote besides
`ko`; the remote server starts only on an explicit `ssh HOST ko
server`. OpenSSH reports a refused forward and a missing socket with
the same message, so the client asks the remote `ko api /version`
through the master to tell them apart. Kido.app owns its own master,
forward and agent publication and connects to the forward's local
socket.

Reconnect: a lost link starts attempts with a backoff of 100 ms to
2 s under one outage deadline of 60 s. An attempt sends a new hello,
and the client resumes a view at its offset only when the `Welcome`'s
`instance` equals the one it saw; another instance drops the mirror
and starts the model again. There is no event replay: every event kind
is a state that the next welcome or layout event carries.

Compression (decided 2026-11-03, on a measured table): OpenSSH's 2 MiB
channel window counts uncompressed bytes and limits a remote restore,
so `ssh -C` gains nothing and only compression inside ko helps. With
`miniz_oxide` at level 1 on snapshot slices only, a 77 MB history of
mixed lines loaded in 4.9 s at 150 ms RTT in place of 8.7 s, at about
0.26 s of server CPU for each such history; level 6 saved few bytes
more at ten times the CPU. Live output stays raw because it is small
and latency-bound. The coordinator's one thread deflates each view's
slices, so N views that attach at once cost N times the deflate. A
snapshot over the queue cap reaches the client whole through the
spill file (protocol.md, section 4). Measured through Kido.app at 50,
150 and 300 ms RTT, echo adds under 1 ms over the RTT at p50, and the
100k-line mixed history restores whole in every cell.

## 6. Performance

The goals follow kitty's: latency while typing, smooth scrolling and
CPU use, balanced against each other; raw throughput is not first.
`bench/run.sh`, `bench/flood.sh` and `bench/client.py` start a private
server on a scratch socket and print one table; `bench/rtt.sh` drives
the remote rows through `bench/rtt_proxy.py`. `ko-bench`
(`ko_bench/`) is the measurement binary. The rows and their rules:

| row | rule |
|---|---|
| ingest, 1 GiB mixed stream, one pane | coordinator CPU for each GiB within 5 percent of the reference build; zero heap allocations for each record |
| five flooding panes | coordinator CPU within 10 percent of the reference |
| keystroke echo, quiet pane | p50 and p99 the same or better than the reference |
| attach with 100k lines | screen visible, then history loaded, the same or better |
| resize with 100k lines | to READY, the same or better |
| `yes` for 5 s in the shown pane | client CPU for each MB parsed no more than the reference |
| idle wakeups | no wakeup of the coordinator or a `ko-pane` with idle primed panes |

The reference is ko at the commit that the last bench run
names (relative, because absolute figures drift with the machine and
its load). A later run
builds that commit in a scratch worktree with `make` (its default
goal builds the layout at every commit) and
measures it first, in the same session, on AC power, at a load average
under 2. A change that moves a row past its rule names the new
reference commit with the reason.

Measurements on an M5 Max that fix the design: the pty read and the
parse share one thread in `ko-pane`, and under bulk output (`cat`)
each 1 KiB read waits for the parse of the one before, so ingest is
bound by the parser, and the ring and the coordinator hop cost nothing
measurable; under output of tiny writes, ingest is bound by the
syscalls, which the read pacing of section 4.3 removes; a 100k-line
history encodes in a few milliseconds and decodes in under ten, so
snapshots go over the socket and need no file path; the hop from a pty byte to the coordinator's socket write
is tens of microseconds; the coordinator idles under 15 MiB and an
idle `ko-pane` under 2 MiB of footprint; and on macOS the memory rows
are judged by `phys_footprint`, because libghostty-vt frees compressed
pages to the OS, which takes them back lazily, so RSS stays at its
peak.

The read pacing, measured in a 69x31 pane on a private server, one
run at a time (CPU in seconds; key-to-frame for a quiet pane, and for
a quiet pane beside a `yes` pane, both shown in the terminal client):

| measurement | no pacing | pacing |
|---|---|---|
| `yes \| head -n 20000000`, terminal client, wall | 18.60 s | 15.07 s |
| the same, `ko-pane` / coordinator CPU | 18.52 / 0.63 | 2.92 / 0.14 |
| `cat` of 212 MB, wall | 1.62 s | 1.57 s |
| key-to-frame, quiet pane, p50 / p99 | 0.38 / 1.20 ms | 0.29 / 0.90 ms |
| key-to-frame beside `yes`, p50 / p99 | 8.38 / 9.01 ms | 8.26 / 9.37 ms |

kitty 0.49.2 takes 18.9 s for the same `yes` at about 92 percent CPU
for the whole terminal. A rule that returns to `poll` after each small
read, with no delay, saved CPU but cost 0.8 to 1.5 s of wall time, because
each small write then woke `ko-pane` again.

## 7. Decisions

Each decision names its date. The code states the rest.

2026-10-29:

- The executable is `ko`. The server is a thin terminal client's and
  Kido.app's server, with no compatibility with a terminal
  multiplexer, no linked or grouped sessions, a per-client current
  window, clipboard requests routed by the server, and upgrade in
  place as a goal.

2026-10-30:

- The layout is one server-validated JSON document, changed by a
  whole-document `PUT` with a revision check. Panes carry arbitrary
  client-set JSON variables.
- The server is two programs: the coordinator and one `ko-pane` for
  each pane, with a shared ring and no copy between them, and the
  control channel on `ko-pane`'s stdio.
- Every pane runs `TERM=xterm-ghostty`. Scrollback compression is
  always on. The pane's foreground process is read only on events.
- The outer mouse reporting stays on while a pane is shown.
- No daemon survives a coordinator crash. The terminal client does
  not hold a finished command's row, because events arrive at once.
- There are no `ko pane` commands: variables go through the HTTP API
  only, by hand with `ko api`, and `ko ssh` writes the API directly.
  The OSC 7501 record set lives in the coordinator.
- The memory rows are judged by footprint on macOS.

2026-10-31:

- The code is the source of truth for every message shape. The
  protocol documents carry only behaviour.
- Every CI job and every download has a deadline.
- ko is Rust, with the minimum number of crates: httparse,
  tungstenite, serde and vte do the parsing. The coordinator's loop is
  its own `poll(2)` loop with no async runtime; `ko-pane` is Rust and
  a separate binary; Verus writes the specs; the release profile
  aborts on panic with overflow checks on; the coordinator allocates
  nothing on the heap for each record; the toolchain comes from
  Homebrew's keg-only rustup, pinned with Verus.

2026-11-02:

- The protocol version changes only with a release; between releases
  a change of shape changes the docs and both clients in one commit.
  The version is 1.0 (`ko_server/src/protocol.rs`).
- Tagged serde enums for the status shape; both clients share
  `ko_client`, which Kido.app links through a hand-written C ABI with
  no libghostty-vt inside the core. The seen record lives in the core.
- A long poll is a stored waiter and a loop timer, never a thread
  (the loop rule).
- A variable value is at most 1 MiB minus 4 KiB of encoded JSON, so
  its event fits in one message.
- `bell` and `notify` are events only; progress is pane state.
- `DELETE /windows/window_N` and `DELETE /sessions/session_N`, each
  atomic; a `PUT` has no remove list. The window's `focus` is a
  read-only field outside the revision. The server keeps running with
  an empty document. A new window gets a default name from its first
  pane.
- Animation is done properly from the start, no fallback.
- A clipboard read for a pane that no attended window shows is refused
  at once.
- `SSH_AUTH_SOCK` is `<dir>/agent.sock` in every pane; there is no
  server-environment route.
- The repo is one cargo workspace with `share/` and the TypeScript
  harness. A `ko_shell` crate holds the shell priming.

2026-11-03:

- The server, the CLI and the code are `ko`; the brand stays Kido and
  the app stays Kido.app. Identifiers, paths and variables are ko's;
  the user-facing brand is not.
- A client selects only over its own connection; there is no route
  that moves another client. Variables always travel with their pane,
  and a pane's row change never moves the layout revision.
- The server deflates every snapshot slice with `miniz_oxide` at
  level 1, with no negotiation; live output stays raw. The table that
  decided it, measured on macOS through a localhost sshd behind
  `bench/rtt_proxy.py` at 150 ms RTT and 100 Mbit/s, a 100k-line
  history of mixed lines (a 77 MB snapshot), medians of 3; "history
  loaded" is from the spawn of `ko HOST` to the last history row in
  the client, "transfer" the first to last snapshot slice; the miniz
  columns come from a scratch build that deflated snapshot slices
  only:

  | 150 ms, 100 Mbit/s | none | `ssh -C` | miniz level 1 | level 6 |
  |---|---|---|---|---|
  | attach, empty pane | 2.22 s | 2.19 s | 2.21 s | 2.19 s |
  | mixed, history loaded | 8.74 s | 8.35 s | 4.87 s | 5.01 s |
  | mixed, transfer | 6.19 s | 5.80 s | 2.38 s | 2.52 s |
  | mixed, wire bytes down | 77.4 MB | 24.8 MB | 29.7 MB | 25.1 MB |
  | mixed, server deflate CPU | - | - | 0.29 s | 2.4 s |
  | echo over RTT, p50 / p99 | 0.6 / 0.8 ms | 0.6 / 2.1 ms | 0.6 / 4.1 ms | 0.8 / 11 ms |

  At 300 ms the mixed history loaded in 15.9 s (none), 16.0 s
  (`ssh -C`), 8.8 s (level 1) and 8.2 s (level 6). Unlimited bandwidth
  gave the same times as 100 Mbit/s: OpenSSH's 2 MiB channel window
  counts uncompressed bytes, so `ssh -C` sends a third of the bytes
  and gains nothing. The shipped level 1 in the same cell, with the
  figures of no compression in parentheses: history loaded 4.90 s
  (8.69 s), transfer 2.38 s (6.19 s), wire bytes 29.7 MB (77.4 MB),
  the local floor 0.59 s (0.33 s) and the server's CPU 0.26 s
  (0.01 s).
  Through Kido.app (`app/scripts/rtt.py`, one run for each cell, the
  same proxy, a 81.6 MB snapshot over 30.4 MB on the wire): attach
  0.9 s at 50 ms, 2.5 s at 150 ms and 4.3 s at 300 ms RTT, with and
  without compression; echo p50 under 1 ms over the RTT in every cell;
  the mixed restore 1.0 s, 2.9 s and 5.7 s at unlimited bandwidth,
  2.6 s, 3.0 s and 5.7 s at 100 Mbit/s, and about 25 s at 10 Mbit/s.
- A shared-memory object lives as long as its frame does, outside the
  kitty storage limit; a limit for the objects is open.
- A view's output past the connection's queue cap goes to an unlinked
  spill file, which the connection drains after the queue
  (protocol.md, section 4). The alternative, producing slices only as
  the socket drains, does not work: the ring is 1 MiB, so a waiting
  slice is either overwritten or blocks the pane's program for every
  view.
- Remote setup is administrative and may write in the server's state
  directory; client actions only connect to the socket.
- Kido.app and ko ship from `main`; ko releases as the tap formula
  `ko`, built from source with the pinned toolchains.

2026-11-04:

- The terminal client is tmux-like (4.11): a `C-a` prefix with
  tmux's default bindings, which works in every terminal, and a status
  line. It needs no kitty keyboard protocol. The prefix is not
  configurable, and the client reads no file: zero configuration, the
  user's choice.
- Where the terminal client differs from tmux's defaults: windows are
  numbered from 0 and the status line is always on with the pending
  prefix shown; `C-a l` selects the right neighbour and `C-a Tab` is
  the last window; `C-a h/j/k/l` and `C-a C-h/j/k/l` also select,
  repeatable; `C-a *` toggles a float of the active pane instead of
  creating a new one; `C-a !` is the shared `Edit::BreakPane`; copy
  mode is vi with `v` begin, `C-v` rectangle and `y` copy; its search
  is local on the frozen mirror; the mouse is on, because the sidebar
  needs it; `C-a e` keeps the pager; `C-a C-s` shows or hides the
  sidebar. The reasons are in 4.11.
- The terminal client shows the window's splits, zoom and floats and
  sizes windows by the same rule as Kido.app. The server has no
  client kind in the hello and no size gate for one kind of client.
- Runtimes come from the `runtimes:` key of `config.yaml`, because a
  runtime cannot be derived. The file has one top-level key for each
  owner, and Kido.app's settings are its `app:` key (4.14).
  Everything that can be derived has no file. Runtimes are managed
  through the HTTP API only: a runtime starts with its first pane or
  exec session and stops by the idle rule.
