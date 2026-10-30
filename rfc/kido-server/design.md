# ko: a terminal server for kido and Kido.app

Status: design, 2026-10-29. Untracked RFC. No code exists.
The executable is `ko` (decided 2026-10-29); the RFC directory keeps
its name.
Appendices: [protocol.md](protocol.md), [p1-mvp.md](p1-mvp.md) (the
MVP: server and thin terminal client, flat panes, no kido features),
[migration.md](migration.md), [00-reading-notes.md](00-reading-notes.md).

Decisions the user made on 2026-10-29:

- The server is OCaml. libghostty-vt does terminal parsing and holds the
  grid. Everything else is OCaml.
- The other recommendations of the first round stand: a thin terminal
  client, no plain-tmux compatibility, no linked or grouped sessions,
  per-client current window, the server routes clipboard requests,
  upgrade in place without losing panes.

## 1. Why

kido today is an OCaml CLI and a pi extension around a tmux fork.
Kido.app is a tmux control-mode client that mirrors each pane into a
libghostty surface. Two emulators must agree, and the control protocol
was built for a different client. The pain list in the brief holds up
against the docs. In short:

| area | today | cause |
|---|---|---|
| content | pen, charset and pending wrap are lost on resync; reflow, history counts, anchors and image rows drift | tmux's grid is mirrored through a text capture into Ghostty's grid |
| restore | `capture-pane` batches, 10k-row pages, Load more, separate metadata captures, find by chunked captures | the only bulk read is a text dump |
| protocol | `%begin`/`%end` counting, the marker hack, `%layout-change` after the reply, `%pause`, octal `%output`, 64 MiB reply cap | control mode is a line protocol for iTerm2 |
| status | 100 ms polling, whole-second OSC 133, stuck-flag heal, OSC 7501 payload ignored, pane options as metadata | tmux has hooks, not events |
| clients | two app windows share one current window, `window-size latest` fights, a second image-only client per connection | tmux's client model |
| ops | fork rebases, a restart on every fork or config change, 103-byte socket paths, `-u` | tmux |

A purpose-built server removes each cause instead of patching each
symptom.

## 2. Goals and non-goals

Goals, in priority order:

1. **One emulator.** The server holds the authoritative terminal of
   every pane in libghostty-vt. A client never has state that the server
   cannot reproduce exactly.
2. **A client protocol made for Kido.app**: binary, versioned,
   request ids, push events, per-view flow control, snapshot and live
   bytes, history on demand, images by reference, typed input.
3. **Status as events.** OSC 133, OSC 7501, titles, pwd, exits and
   topology arrive as events with the server's clock. The sidebar model
   that `lib/` computes today runs once, in the server.
4. **Several clients that do not fight**: each client has its own
   current session and window. Two viewers of one window still share
   its size, because a pty has one size.
5. **Upgrade without losing panes.** A new server binary takes over the
   running ptys and the terminal state.
6. **Remote** over SSH with the same protocol, with reconnect.
7. **A thin terminal client** for a plain terminal and for the kido side
   column.

Non-goals:

- Compatibility with tmux clients, tmux commands, `.tmux.conf`,
  plugins, `run-shell` bindings, hooks, key tables.
- Linked and grouped sessions.
- Copy mode in the terminal client, in the first version.
- Scripting the server from the shell beyond what the `kido` CLI
  exposes through the protocol.
- Surviving a reboot.
- Replacing `kido ssh` priming, the pi inbox or the agent map. They
  stay as they are. Only their tmux calls change.

Users served: Kido.app first; the `kido` CLI and the pi extension
second; a plain terminal third; an iOS client later, on the same
protocol.

## 3. The one decision that shapes everything: how a client gets content

Three ways were considered.

**A. Bytes to the client, client emulates (today).** Rejected. It is the
cause of the content bugs.

**B. Render state to the client, client only draws.** The server runs
the render-state API and ships rows of cells with styles. The client is
a renderer. This is the purest design. Its cost: Kido.app has no
renderer that takes external rows. Ghostty's Metal renderer reads its
own `Terminal`; the libghostty-vt-renderers research (2026-10-05) put a
usable own renderer at 35 to 70 agent-days before images. It also
moves per-row serialization into the server's hot path, which turns a
fast program's output into cell diffs that are larger than the bytes
that produced them.

**C. Mirrored libghostty-vt, synchronized by snapshots.** Both the server
and the client run libghostty-vt. The server is authoritative. The
client's terminal is a mirror that receives the same bytes, in the same
order, with resizes at the same byte offsets. Whenever the mirror could
diverge, or when a client attaches, the server sends a **snapshot**:
libghostty-vt's binary record stream whose READY prefix restores the
complete renderable state, including the pen, the charset, the pending
wrap, the unfinished parser input, the modes, the images with pending
pixels, and whose later records carry older history pages and image
pixels incrementally.

**Decision: C, with B as a later addition** for clients that cannot run
libghostty-vt (a web client). The reasons:

- Kido.app keeps its Ghostty surface and the renderer it has. The fork
  loses the sync machinery (authoritative grids, prepend history, held
  placements, fill images, restore_output) and gains one entry point:
  restore a surface from a snapshot stream.
- The correctness argument is deterministic emulation: one library, one
  version, the same inputs. Where inputs cannot be identical (history
  depth after a resize, size limits on a phone), the snapshot is the
  escape hatch, and it is cheap: a READY prefix is the size of the
  screen.
- Live bytes are the smallest encoding of what changed. Remote
  bandwidth is what the program wrote, not cell diffs.
- A terminal client and an iOS client are also libghostty-vt mirrors.
  libghostty-vt builds for iOS and is a static C library for OCaml.

What the server's own terminal is for, if clients emulate too:

- It answers every query (`write_pty`). A client's mirror never
  writes to the pty. Replies come from one place by construction.
- It is the source of snapshots.
- It encodes input: keys, mouse, paste and focus are encoded by the
  server with the terminal's current modes (kitty keyboard flags,
  bracketed paste, mouse tracking). A client sends typed events.
- It runs OSC 133, OSC 7501, title, pwd, bell, notification, clipboard
  and resize-request callbacks. These are the status events.
- It owns image storage, so a reattaching client gets pixels from the
  server, not from the program.
- It searches history for a remote client that has not loaded it.
- It is what survives an upgrade.

## 4. Architecture

### 4.1 Processes

The server is two programs (decided 2026-10-30):

- **`ko`, the coordinator**, in OCaml. One per state directory, as
  today. The socket is `<dir>/socket`. The directory rules of
  `Server_dir` stay (0700, owner, no comma, 103-byte path). It owns
  the topology, clients, the HTTP and WebSocket protocol, the ring and
  fan-out to views, skips and snapshots, sizing and focus, the
  clipboard answerer, the model, runs and config. It never calls
  libghostty-vt.
- **`ko-pane`, the pane process**, a small C program, one child
  process per pane, with no policy. It opens the pty (`openpty`,
  `fork`, `setsid`, `TIOCSCTTY`, `execvpe`; after `fork` the child
  only execs or `_exit`s), runs `vt_write` on everything the pty
  produces, answers the program's queries into its own pty through
  `WRITE_PTY`, encodes typed input with the terminal's modes, and
  writes the record stream into a shared ring that it and the
  coordinator map, with its stdio as the control channel (protocol.md
  section 14; decided 2026-10-30). It exits when that channel closes,
  and its shell gets `SIGHUP` with it. It is about two thousand
  lines with fixed-size framing, built with `-fsanitize` in tests and
  fuzzed on its frame parser and pty path.

Why a process per pane: a libghostty-vt abort, which zmx hit twice,
kills one pane and not the server; parsing runs on one core per pane
with no threads or domains anywhere; a coordinator upgrade moves no
terminal state (4.12); and a C process idles near 1 MiB, so fifty panes
cost about 50 MiB more than one process, inside the memory target of
p1-mvp.md. The price is one hop per record, pty to `ko-pane`'s ring to `ko`'s
`writev` to the client, tens of microseconds, and a hot path in C. Zig would reach Ghostty's internal API but would track its
churn, which zmx did eight times in eleven months; the C API is the
stable surface. A coordinator crash still kills the panes, as a tmux
crash does today.

The coordinator is single-threaded over libuv through the opam package
`luv`. luv vendors libuv and dune builds it, so it locks into
`dune.lock` with no system library; it brings `ctypes` and `integers`
with it. The loop, timers, the SIGCHLD watcher, the unix socket
listener, the client connections and the pane control sockets are luv
handles. OCaml 5 domains are not used; parallelism is the pane
processes. Backpressure toward a program is the ring: if the
coordinator falls a whole ring behind, `ko-pane` blocks, stops reading
the pty, and the program blocks, as under tmux.

A pane's exit status comes from `ko-pane`, which reaps its child and
sends a `dead` event; the coordinator reaps `ko-pane` itself on
`SIGCHLD`. A pane whose program exited stays as a dead pane with its
status and signal, which is tmux's `remain-on-exit` with
`pane_dead_status` and `pane_dead_signal`, and its `ko-pane` stays
alive to hold the screen until the pane is removed. The run rules in
design.md keep working unchanged.

The protocol is HTTP/1.1 over the unix socket, with WebSocket for the
long-lived streams (decided 2026-10-29), served by `httpun` and
`httpun-ws`, whose state machines the luv reads and writes drive. Each
stream is its own connection: the client connection, feed, one per
open view (which
also carries that pane's input), one per image fetch, and a pool of
keep-alive connections for control requests. A remote client reaches
the same socket through a unix socket forward on its SSH
ControlMaster. The coordinator checks the peer uid on every accepted
connection (`LOCAL_PEERCRED` on macOS, `SO_PEERCRED` on Linux) with one
`getsockopt` stub on the fd that `Luv.Handle.fileno` returns. There is
no other authentication.

### 4.2 Modules, in OCaml

The server is a new library in the kido repo. Of `lib/` it reuses only
what has no tmux in its types: `Tree`, `Timestamp`, `Fs`. The rules of
`Pane_status`, `Program_status`, `Run`, `Reap`, `Prompt` and `Reap`
move into the server's modules with new inputs (events with nanosecond
times instead of tmux formats; the server's pane instead of
`Tmux.pane_id`; input messages instead of `load-buffer`). Their e2e
tests move with them. `lib_tmux/` and the tmux-reading parts of `State`
and `Sidebar` are deleted at stage 4.

| module | owns |
|---|---|
| `Pane_proc` | one `ko-pane` child: the ring mapping, the control socket, the frame codec, requests and their replies, events |
| `Pane` | one pane: its `Pane_proc`, title, pwd, OSC 133 phase, OSC 7501 records, meta fields, output sequence number, ring, dead state |
| `Window` | panes, layout tree, floats, zoom, active pane, size and cell pixel size |
| `Session` | windows, order rank, name, environment |
| `Topology` | sessions, ids, the walk, events |
| `Client` | a connected client: its `/client` WebSocket, current session and window, size, focus, sizing flag |
| `View` | one streaming response of one pane: sync state, unsent count, pending snapshot |
| `Input` | typed events validated and forwarded to the pane process, which encodes them |
| `Clipboard` | the OSC 52 and 5522 request routing |
| `Images` | image resources: server-owned shm copies locally, pixel bodies remotely |
| `Runs` | run records, outcomes, the sweep, output tailing |
| `Model` | the typed sidebar model: `Pane_status` over panes, the tree, snapshots on change |
| `Upgrade` | write state, exec the new binary with the pane rings and control sockets, read state |
| `Config` | `ko.conf`: default shell, scrollback and image limits, the environment |
| `Http` | httpun and httpun-ws on luv: routing, JSON bodies, WebSocket streams, version headers |
| `Loop` | the luv loop, timers, the tick, the SIGCHLD watcher |

The coordinator's C stubs are the peer-uid `getsockopt`, the ring
mapping and `ko-pane` spawn, the view `writev` (4.6), and `shm_open`
for `Images`. The libghostty-vt binding `ko_vt/` serves the
terminal client's mirror only: terminal, snapshot decoder, render
state, scroll, and the formatter. Its stubs are hand-written, not
ctypes, about 30 functions; callbacks from `vt_write` into OCaml run
nested inside the OCaml call that wrote, and a stub catches an OCaml
exception and returns it after the C call returns.

`ko-pane` holds the server side of libghostty-vt: terminal, options and
callbacks, the snapshot encoder, key, mouse, paste and focus encoders,
kitty graphics storage, the formatter and search.

### 4.3 The pane's terminal

Per pane, one `GhosttyTerminal` inside its `ko-pane`, with these
options set (the values come from the coordinator in the first frame):

- `WRITE_PTY`: the reply path. `ko-pane` writes replies to its pty.
- `CONTINUATION_MAX_BYTES`: nonzero, so snapshots can carry unfinished
  input. The default limit of the decoder (65 MiB) bounds an in-flight
  kitty upload.
- `SEMANTIC_PROMPT`: OSC 133 A, B, C, D become event frames; the
  coordinator turns them into `Pane` phase changes with its monotonic
  clock and the exit code from D. There is no
  whole-second tie and no stuck flag: a new prompt start ends a command
  that never reported D, exactly as the heal rule does today, but once.
- `PROGRAM_STATUS`: OSC 7501 reports become record updates under the
  rules that `Program_status` applies today. libghostty-vt answers the
  `?` query itself, with or without a client attached. The coordinator
  keeps the records, their serial and the eviction order.
- `TITLE_CHANGED`, `PWD_CHANGED`: events.
- `CLIPBOARD_WRITE`, `CLIPBOARD_READ`: routed to a client (section 4.8).
- `BELL`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`: events.
- `RESIZE_WINDOW`: ignored, as tmux ignores it.
- `SCROLLBACK_MAX_BYTES`, `SCROLLBACK_MAX_LINES`,
  `KITTY_IMAGE_STORAGE_LIMIT`, media options: from `ko.conf`.
  Scrollback compression is always on: after an idle period with an
  unchanged `ghostty_terminal_compression_activity` token, `ko-pane`
  runs one incremental `ghostty_terminal_compress` step per loop turn
  until it completes; after 2 s of continuous activity it runs one
  step every 10 ms (p1-mvp.md 3.2). Shared memory is accepted on the local server. A
  remote client never opens an object that a program named; it gets
  pixels from the server.
- `UNKNOWN_SEQUENCE`: records DCS passthrough and other unknown OSC
  for diagnostics; nothing acts on them.
- `TERMINFO_NAME` and the default modes: fixed by the server. `TERM`
  is `xterm-ghostty` in every pane, with the terminfo that Ghostty
  ships installed beside the server. kido owns the whole pane
  environment, so this is not a compatibility question.

Cell pixel size comes from the window (4.5). `ghostty_terminal_resize`
takes columns, rows and the cell size together. `CSI 14t` and `16t` are
answered through the `OPT_SIZE` callback, which the server sets and a
mirror leaves unset.

**The mirror contract.** A mirror is exact only if it is the same
libghostty-vt revision with the same terminal options as the server:
`SCROLLBACK_MAX_*`, `APC_MAX_BYTES*`, `KITTY_IMAGE_STORAGE_LIMIT`, the
media options and `CONTINUATION_MAX_BYTES`, because eviction and
refusal decisions depend on them and a snapshot does not carry them
(the decoder has its own limit option, set to the same value). A mirror
sets no `WRITE_PTY` and no `OPT_SIZE`. The server sends its option
values in `GET /version`, and a client applies them before it opens a
view. Kitty media need care: upstream libghostty-vt refuses a `t=s`,
`t=f` or `t=t` upload when the medium is disabled and stores nothing,
so later placements would fail on a mirror that cannot open the
program's object while the server shows them. The app's fork keeps a
pending image for a refused medium (commit 74f7a52bc and its two
predecessors). kido's ghostty submodule therefore pins the app's fork
revision, and those commits stay in the fork; migration.md's second
open question is closed by this.

Output handling, in `ko-pane`, per wakeup of the pty:

1. Read until `EAGAIN`, directly into the ring at its head, at most
   the free space before the wrap per read (Linux returns at most
   4 KiB per pty read, macOS 1 KiB; P1.0 measured 99.8 percent of
   macOS reads at exactly 1024 bytes). If the ring has no space, stop
   reading until the coordinator acknowledges, with no deadline: the
   coordinator, not `ko-pane`, decides when a pane stops.
2. `vt_write` that region in place. Callbacks fire inside and queue
   event frames. `ghostty_terminal_vt_write` returns `void`: the
   library reports no error, so malformed input is whatever the parser
   makes of it. It is built `ReleaseFast`, so a failed hyperlink
   insert is not an abort (P1.0 fuzzed 1000 resizes over dense OSC 8
   scrollback with no abort).
3. Commit the record: its header carries the pane's **output sequence
   number**. Send the queued event frames, and a `head` frame only if
   the coordinator is idle (its `read` index in the mapping equals the
   head before this commit); a busy coordinator reads the head from
   the mapping on its 2 ms timer, which runs only while output
   continues.

In the coordinator, per head advance: for each attached view, a
non-blocking `writev` of a WebSocket header and the ring region itself
(section 4.6); mark the pane dirty for the model tick. The coordinator
copies nothing. Its allocation is bounded per write call, not per byte:
P1.0 measured 6.9 minor words per record with the `writev` stub and 2 ms
coalescing, the rest from luv's reads of event frames, and 0.4 without
events; `Luv.Stream.write` costs about 150 words per call.

A resize, a reset and a terminal option change are **stream markers**:
the server applies them to its own terminal at a byte offset and sends
the marker to every view at that offset. A mirror applies them in order
and is therefore identical, except for history that it never loaded.

### 4.4 Snapshots

The sync unit is the libghostty-vt snapshot: `"GHOSTSNP"`, versioned,
CRC-protected records, READY after the renderable prefix, then HISTORY
pages newest first and KITTY_IMAGE_PAYLOAD records, then FINISH. The
pane process encodes it with `ghostty_snapshot_encode` into a writer
that places slices into the ring as records, and the coordinator
writes them to the view from the ring, so a 100k-line history is
streamed, not buffered. Encoding happens at a known output offset; the snapshot
carries that offset, so the mirror applies the bytes that follow it.

The encoder has no options: it always writes the whole terminal, the
history newest first and every image payload. The decoder pulls from a
blocking reader, treats a zero-byte read as EOF, and prepends pages
only into the terminal that its own `ready()` produced. The design
therefore has two kinds of snapshot and no page addressing:

- **Full**: every record to FINISH. The mirror then holds the same
  history as the server and is **full**.
- **Screen**: `ko-pane` stops the writer after the READY record. It
  parses the 10-byte record headers of the encoder's output to find
  that point. The mirror has the screen and no history and is
  **partial**.

`ko-pane` also filters records by type on the way out, which is how
`images=none` drops `KITTY_IMAGE_PAYLOAD` records: the decoder keeps
those images pending, and the client fetches pixels as resources.
Spike 1 confirms that a decoder accepts a stream whose payload records
are absent.

A client decodes on a thread whose reader blocks on the view's
WebSocket, calls `ready()`, swaps the surface's terminal to the decoded
one, and keeps calling `next()` until FINISH or until the stream's last
slice. If a new snapshot begins while a decode is in progress, the
client abandons the decoder and starts the new one. This replaces
capture-pane paging, Load more, the history metadata captures, the
image client, `-G`, `-K`, `more TOKEN`, held placements and the fill
generation machinery.

The server sends a snapshot:

- When a view opens: full or screen, as the client asked.
- After a resize, **only to a partial mirror**, as a screen snapshot,
  because reflow depends on the history each side holds. A full mirror
  applies the resize marker to its own terminal and stays exact.
- When a view fell behind and its backlog is larger than a screen
  (4.6): a screen snapshot. A full mirror becomes partial by this; it
  asks for a full one again when it wants history back.
- After reconnect, for every visible pane, unless the offset resumes.
- On the client's request, as a message on the view: a partial mirror
  that wants history (the user scrolled up), or a client that detects
  a divergence.

There is no history paging. A partial mirror that wants history takes
a full snapshot and swaps terminals. Over a slow link this is the cost
of the first scroll-up, and never a cost of attach. A snapshot of a
very large history to a local client may travel as a server-written
0600 file named in one message (4.6); the decoder reads a file reader
as well as a stream.

A snapshot carries the terminal's modes. Synchronized output (DECSET
2026) is a handshake between a program and the terminal that was
attached when it began; a client that restores it set would defer its
rendering until its own timeout. The server clears mode 2026 in every
snapshot it encodes and sets it back afterwards, as zmx does in its
restore (`serializeTerminalState` in zmx's terminal.zig). The kitty
keyboard flags, by contrast, are restored as state: the mirror holds
them, and the client's outer terminal is configured by the client, never
by replaying bytes. zmx's known issue with re-enabling kitty keyboard
mode on reattach does not arise.

Snapshot format version 1 "does not yet carry a binary-compatibility
guarantee". Both sides therefore pin one libghostty-vt revision, and the
protocol version includes it (section 5). A mismatch is refused at
the first request, as the server stamp is today.

### 4.5 Sessions, windows, panes, clients

The model keeps tmux's shape because kido and the app are built on it:

- A **session** has an ordered list of windows, a name, a rank for the
  sidebar order, and an environment. Ids are `session_N`, `window_N`,
  `pane_N` and `client_N` (decided 2026-10-29), allocated once per
  server life, never reused. kido's run records and the app's keys
  take the new spelling; nothing translates `pane_N`.
- A **window** has a layout tree of tiled panes, floating panes with
  position, size, border and z-order, an active pane, a zoom state,
  a size in cells and a cell size in pixels, and a name.
- A **pane** has a process, a terminal, meta fields (4.9), and a dead
  state after exit.
- A **client** is one open `/client` WebSocket (decided 2026-10-30):
  it exists from the hello to the close, with no linger and no
  orphans. It has a current session, a current window, a size in cells
  and pixels per visible window, a focus flag, views, a kind (`app`,
  `terminal`), a name and an id `client_N` that names it only while
  the socket is open. When the socket closes, the server deletes the
  client and closes its views. The client, not the server, owns what
  it shows: a reconnect is a new client whose hello carries its
  current window, pane and size again. The feed and one-shot CLI
  requests are not clients.

Window size: a window is sized by the clients that show it and take
part in sizing. The sizing client is the one whose **input focus** is
on the window, or the one that last switched to it; a size change from
another client never claims the window, because a second app window on
a smaller monitor would otherwise steal the size on every resize of its
own (zmx #44, #267, #299). The server records every client's size, so
the sizing client's size is known the moment it claims. Other viewers
clip. When the sizing client disconnects, the window keeps its size
until another client claims it by focus or by switching to it, so a
short network drop does not resize the pty twice; a reconnecting
client's hello claims it again if it has focus. The app's "two windows on one
session are coupled" limit shrinks to size only; the current window is
per client. A client can opt out of sizing (`ignore_size`). There is no manual window size.

Linked windows and grouped sessions are gone. Per-client current window
is what grouped sessions were for. A window moves between sessions with
the window move request; it has one position.

Modal popups (`display-popup`, `display-menu`) are gone. A floating
pane is a pane. The one-shot picker that `C-s` opens today becomes a
terminal-client feature, drawn by the client (section 4.11).

### 4.6 Views and flow control

A **view** is one client's subscription to one pane's content. A client
opens a view when a pane becomes visible and closes it when it leaves
the screen. Hidden panes have no view, so a client that returns to a
window gets a snapshot, not a replay; the server's terminal is the
state, so nothing is lost.

A view is one WebSocket on its own connection, so its
backpressure is the connection's: the kernel socket buffer locally,
the SSH channel window remotely. The server writes without blocking.
When a view's write would block, the server stops writing it and
counts what it did not send. When the connection drains:

- If the unsent count is below `resume_threshold` (default: one
  screen's worth of bytes, 64 KiB), the server sends the backlog from
  its ring buffer. The ring stores markers at their offsets as well as
  bytes, so a resize inside the backlog replays in order. A partial
  mirror cannot apply a resize marker exactly, so for it a resize in
  the backlog means a screen snapshot instead.
- Otherwise, it sends a `skipped` record and a screen snapshot at the
  current offset and drops the backlog. The client decodes and
  continues live.

The same rule decides a reopen with `?offset=`: bytes and markers
resume if the offset is inside the ring and the mirror is full, or the
range holds no resize marker; otherwise the view opens with a snapshot.

This replaces `%pause` and `pause-after`. The server never stalls a
pane for a slow client beyond a bounded ring buffer per pane (default
1 MiB) and never discards output silently: a skip is a snapshot. A
local connection rarely skips; over a slow link, a flood becomes a
snapshot per screen, which is the right behaviour.

Because each view, the client connection, the feed and input are
separate connections, a flood in one pane never delays a control reply or
another pane. There is no multiplexer, no credit messages and no
priority rule to get right.

Output coalescing: the server writes to a view at most once per 2 ms
per pane; bytes within that window are one record. This bounds syscall
and record overhead at high output rates. It does not bound latency
for keystroke echo in a quiet pane, which goes out at once.

Live bytes to a view are the raw pty bytes with a record header: no
octal escaping, no line protocol.

Performance of HTTP and one connection per stream, compared with a
multiplexed binary connection:

- The hot path is a pty read into the ring and `vt_write` in place in
  `ko-pane`, a `head` frame, then one `writev` per view from the ring
  in the coordinator. A WebSocket frame header is 2 to 10 bytes on top
  of the 9-byte record header, at most one record per 2 ms per view.
  Server to client frames are unmasked. Parsing a request in `httpun`
  is microseconds.
- Writes scale with visible panes: one `write` per busy pane per
  flush instead of one for all. Twenty busy panes are ten thousand
  writes a second, which is far below what luv and the kernel handle.
- Between `ko-pane` and the coordinator there is no copy (decided
  2026-10-30). One anonymous shared mapping per pane, `memfd_create`
  on Linux and `shm_open` with an immediate `shm_unlink` on macOS,
  created by the coordinator before the fork and inherited, holds the
  record stream: `bytes` records, markers and snapshot slices, each
  with its offset. `ko-pane` reads the pty into it and parses in
  place. The coordinator maps it as a `Bigarray` and writes a view's
  payload with a small non-blocking `writev` stub on the view socket's
  fd, the WebSocket header as a separate small iovec, and waits for
  writability with `Luv.Poll` on a `dup` of that fd (a `Luv.Poll` on
  the fd that luv reads gets a synchronous error, p1-mvp.md 6.3). No
  pending write ever references the ring: on `EAGAIN` the view keeps
  only its ring offset, and a partial write copies the rest of its
  frame. P1.0 measured
  why: with `Luv.Stream.write` by reference, an in-flight write pins the
  ring until the kernel takes it, and a reader that stalls 300 ms
  blocked the pane for 283 ms even with a 1 MiB `SO_SNDBUF`. The
  control socket carries `head` wakeups for an idle coordinator, `full`
  from a blocked `ko-pane`, `tail` after a `full`, and the control
  frames; otherwise head and tail are read and stored in the mapping.
  The coordinator advances `tail` past data that no view can still
  resume from; a view whose unsent bytes passed `resume_threshold`
  gets a snapshot anyway, so it never holds the writer. This mapping is the pane's ring of this
  section; there is no second one.
- Socket buffers decide when backpressure engages. On macOS a
  non-blocking writer on a unix stream socket accepts exactly its own
  `SO_SNDBUF` before `EAGAIN`, whatever the reader's `SO_RCVBUF`
  (measured in P1.0; `net.local.stream.sendspace` and `recvspace` are
  both 8 KiB, and both options read back as set). So the server's
  `SO_SNDBUF` is the one that counts. With 8 KiB, 20 ms reader stalls
  skipped; with 1 MiB, stalls of 50 ms every 100 ms did not. The server
  sets `SO_SNDBUF` and the client `SO_RCVBUF` to 1 MiB on view
  connections (Linux not yet measured), and the client reads views off
  its main thread. Over SSH the channel window
  is 2 MiB.
- Input is one masked text frame per event on the pane's view, a few
  dozen bytes with no reply. Locally the write is microseconds; the
  XOR of the mask touches only input bytes. Remotely a keystroke's
  echo is one round trip, as today, and nothing waits for a reply.
- Opening a view costs a connection: negligible locally; two round
  trips remotely (channel open, request), paid once per view and in
  parallel for a window switch, so a window of eight panes shows after
  two round trips, not sixteen. A small pool of pre-opened idle
  connections removes one of them if measured to matter.
- Images skip the socket on a local server (shared memory by name) and
  are fetched in parallel remotely, which is better than pixels inside
  a view stream in both cases. The server does not deflate an image
  that the program uploaded as PNG.
- One message is one record, so the client parses WebSocket frames and
  nothing else. There is no second framing layer to profile.
- Shared memory between server and client is used for images only in
  P1. Two copies touch each record: the kernel's pty into the ring, and
  the kernel's `writev` from the ring into each view's socket. Both
  are unavoidable on a socket transport. `sendfile` and `splice` would
  not remove the second one: a WebSocket header before each payload
  makes `writev` from the mapping the cheapest sequence. The design
  that removes the client-side copy is **the ring mapped by a local
  client**: the pane's ring above is also mapped by the client, and the view
  WebSocket carries wakeups, markers, snapshot slices and the published
  tail for lap detection; a remote client gets `sendfile` from the
  `memfd` on Linux and one copy on macOS. It turns the single-reader
  ring into a multi-reader one that must be correct in Swift too. It
  is taken only if the coordinator's CPU under twenty flooding panes
  with three viewers each demands it, and the protocol admits it
  without a break: a view would advertise `{ring: {name, size}}` in
  its first message. A snapshot of a very
  large history is the one other candidate: if the attach benchmark of
  p1-mvp.md misses its target, a local view may receive
  `{snapshot_file: name}` naming a server-written 0600 file instead of
  binary slices. The decoder reads a file as well as a stream, so this
  is one message kind, not a different design. Render state in shared
  memory (option B of section 3) stays out for the reasons given
  there.

### 4.7 Input

A client sends typed events. The coordinator validates them and
forwards them as frames to the pane process, which encodes them with
its terminal's modes and writes the pty:

- `key`: a key event in libghostty-vt's key terms (physical key,
  modifiers, text, action, composing), encoded by
  `ghostty_key_encoder` with the pane's modes. The client's Ghostty
  surface already produces these.
- `text`: already encoded bytes from a client that has no key events
  (the CLI's prompt delivery, a test). Written as is.
- `paste`: text, encoded by `ghostty_terminal_paste` with bracketed
  paste if the program asked for it, after `ghostty_paste_is_safe`
  if the client asks for the check. This replaces load-buffer,
  paste-buffer and the separate Enter.
- `mouse`: cell position, button, action, modifiers, encoded by
  `ghostty_mouse_encoder` with the pane's tracking mode. A client that
  handles the mouse itself (the app, in copy mode) sends nothing.
- `focus`: in or out, encoded if the program asked for focus events.
  The server also synthesizes them: focus out when the last focused
  client of a pane leaves or closes its views, focus in when one
  returns, only while mode 1004 is set (zmx 7cc6d16).
- `resize`: not input; a client operation (4.5).

Ordering: input messages on one view are applied in order. `POST
/input` and a size change on another connection are not ordered against
them by design; a mouse event that arrives after a resize may fall
outside the new size and is clipped.

The pty write path never drops input: `ko-pane` writes at once, queues
on `EAGAIN` and drains on writable. A `paste` with an `id` is answered
only after the pty accepted every byte. A client's close frame is
processed after its queued input, so a `POST /input` followed by a hang
up loses nothing (zmx #279).

Input goes to the pane that the client names. The active pane of a
window is where a client's focus goes when it does not name one.

### 4.8 Queries, clipboard and consent

Queries from the program are answered by the server's terminal through
`WRITE_PTY`. The client's mirror has no pty and its `WRITE_PTY` discards.
There is nothing to route.

Clipboard is the exception, because the answer lives in a client:

- `CLIPBOARD_WRITE` (OSC 52 write, 5522 write): the server sends a
  `clipboard.write` event to the clients that have an **interactive
  focus** on that pane's window (the app window that shows it, the
  terminal client attached to it). Each client applies its own consent.
- `CLIPBOARD_READ` (OSC 52 read, 5522 read, mode 5522 paste events): the
  server picks **one answerer**: the client whose focus is on the pane,
  else the most recent interactive client of the session, else none. It
  sends `clipboard.read {request_id, selector, mimes}` and waits with a
  deadline (8 s, the app's today). The client answers with data or a
  refusal; the server completes libghostty-vt's reply struct. One
  answerer by construction removes the two-responder problem.
- Consent, grants and "always allow" stay in the client. The server
  never decides.

### 4.9 Metadata: what replaces pane options

tmux user options were the only typed channel kido had. The server has
fields:

| today | server field | writer | trust rule |
|---|---|---|---|
| `@kido_run` | `pane.run : run id option` | `pane.create` from `kido run` | set at creation, never changes |
| `@kido_session` `@kido_name` `@kido_inbox` `@kido_activity` | `pane.agent : {session; name; inbox; activity}` | `kido pane set-agent` from the pi extension | believed only while the root OSC 7501 app is `pi`, as today |
| `@kido_ssh` `@kido_ssh_args` | `pane.ssh : {dest; args}` | `kido ssh` before exec | believed only while the foreground command is `ssh` |
| session `@kido-order` | `session.rank` | the reorder request | none |
| `remain-on-exit` | always on for run panes, off otherwise | `pane.create` | |

The foreground command (`pane_current_command`) is read from the
process group of the pty (`tcgetpgrp` and the process name) as tmux
does. `alternate_on` is `ACTIVE_SCREEN` of the terminal.

### 4.10 Status, runs and the model

`Model` is today's `Sidebar.step` and `Pane_status.observe` without the
poll. It runs when an event marks a pane or the topology dirty, at most
once per 16 ms, and emits a typed snapshot to every `feed` subscriber
when the snapshot differs. The snapshot is the RPC v2 shape of
`share/rpc/contract.md`, as a protocol event, with these changes:

- Times are the server's clock in nanoseconds, not whole seconds.
- Outcome serials are server-wide and stable across clients and
  reconnects, because there is one tracker. The "feed restart can lose
  or re-arm outcomes" and "concurrent feeds give different serials"
  limits go away.
- `server_instance` is the server's start time and pid, and survives an
  in-place upgrade (the pid does not change).

Seen state stays in the client, as today.

Runs move into the server: `Runs` writes `runs/<id>/` as `Run` does
today, the sweep runs in the server's tick once, not once per sidebar,
and `run-wait` is a subscription instead of a poll. The run commands
of the CLI become requests with the same exit codes and JSON.
`kido run-child`'s parent rule, the orphan rule, first-write-wins
outcomes and the screen capture (now `ghostty_formatter` over the dead
pane's terminal) keep their design.

### 4.11 The terminal client

`ko` with no arguments is the terminal client, an OCaml program
(p1-mvp.md sections 5 and 6.4). It is a client like any other: it opens
views for the panes it shows and mirrors them in libghostty-vt. Mosaic
parses its input and runs its loop, and draws nothing; a direct cell
differ writes the whole screen, the mirror's render-state cells and the
client's own sidebar cells together. The mirror compresses its
scrollback when idle, as the pane does (4.3). It draws the
sidebar itself from the feed event, with the rows of `Kido_sidebar`
today. Its keys are Ctrl+Shift chords under the kitty keyboard
protocol, as p1-mvp.md lists them; there is no prefix key and no
separate picker, the sidebar is the picker. Copy mode is not in the
first version; the wheel scrolls the pane's mirror. It passes through
kitty images where the outer terminal supports them, else draws
nothing in their cells.

This replaces `side-status-command`, `TMUX_SIDE_CLIENT`,
`side-status-focus`, the popup picker and tmux's key tables.

### 4.12 Upgrade in place

Terminal state lives in the pane processes, so a coordinator upgrade
moves none of it. `ko upgrade` (sent by the launcher when the binary
differs from the running coordinator, or by the app's Restart) does:

1. The coordinator stops accepting clients and stops reading the pane
   control sockets.
2. It writes `<dir>/upgrade/state.json`: sessions, windows, layouts,
   panes with their ring and control fd numbers, ring tails and
   `ko-pane` pids, meta
   fields, run links, OSC 7501 records, OSC 133 phases, the start
   time (so `server_instance` survives) and the
   shared-memory name counter (the pid stays, so names would collide).
   The ring is not written; views reopen with a snapshot.
3. It clears `CLOEXEC` on the rings, the control sockets and the
   listening socket and
   `execve`s the new binary with `--resume-upgrade <dir>/upgrade`. The
   pid stays, so the pane processes stay children and `waitpid` works;
   connects queue on the inherited listener instead of failing.
4. The new binary reads the state, maps the rings, resumes reading the
   control sockets,
   and clients reconnect: each sends a new hello and reopens its
   views with snapshots. Client connections are not inherited; a client
   is its connection.

A `ko-pane` upgrade (a libghostty-vt bump) is separate and per pane:
the coordinator asks the old process for a full snapshot into a 0600
file, starts a new `ko-pane` on the same pty master (passed over the
control socket with `SCM_RIGHTS`, both processes hold it during the
handoff), which decodes the file with `RETAIN_CONTINUATION`, then
closes the old one. A pane whose snapshot fails to decode (a snapshot
format change) gets an empty terminal with the modes, kitty flags,
title and pwd that the coordinator knows, and keeps its program. The
user loses the screen and scrollback of that pane; input keeps working
because the modes are back. The coordinator does this one pane at a
time, idle panes first, and never for a pane in the alternate screen
unless asked.

A crash of the coordinator still kills the panes, as a tmux crash does
today. A `ko-pane` could survive one if it listened on its own socket
for a new coordinator; that is a daemon, and the user decided against
it (2026-10-30). A crash of one `ko-pane` kills one pane.

## 5. Protocol summary

[protocol.md](protocol.md) specifies the wire. The shape:

- HTTP/1.1 over the unix socket, keep-alive, one connection per
  stream. Control bodies are JSON. Long-lived streams are WebSockets:
  the client connection, feed, search, and views, whose messages are
  binary records
  server to client and JSON input events client to server.
  `curl --unix-socket` reads every plain resource; `websocat --unix`
  reads a stream.
- `GET /version` and the headers `Ko-Protocol` and `Ko-Vt` carry the
  protocol version `MAJOR.MINOR` and the libghostty-vt revision. The
  server refuses a different major (426) or revision (409). Minor
  appends fields and resources.
- `GET /client` is a WebSocket, one per native window or terminal
  client, and the client is that connection. Its hello carries kind,
  name, current window or pane, size and focus; the server answers
  with `client_N`, then sends topology (one full tree on change; it is
  small), pane events (title, pwd, prompt, records, dead, bell),
  clipboard requests, and this client's state changes. The client sends
  `select`, `switch`, `size`, `focused` and clipboard answers on it.
  `Ko-Client` on other requests names it and is valid only while it is
  open. Detach is closing it. `GET /feed`: the
  typed model snapshots, kept separate so a busy pane's events never
  sit between two model snapshots.
- `GET /panes/pane_N/view?offset=&history=&images=`: the record stream
  of bytes, markers, snapshot slices and skips. An `offset` inside the
  ring resumes bytes and markers; otherwise the view opens with a full
  or screen snapshot. A message on the view asks for a new snapshot.
- `GET /panes/pane_N/images/<id>?generation=`: pixels as a body, or on a
  local server the name of a server-owned shared-memory object. The
  client fetches the images with placements on screen, in parallel,
  and caches by id and generation. Nothing else carries pixels.
- Input: key, text, paste, mouse, focus as text messages on the pane's
  view, in order; `POST /panes/pane_N/input` for a sender with no view
  open, such as the CLI.
- Topology writes as REST on `/sessions`, `/windows`, `/panes`,
  `/clients/<id>/select`: the current RPC requests plus split, float,
  move, swap, zoom, resize, kill, rename, with the same validation.
- Runs under `/runs`; `GET /runs/<id>/wait` is a long poll.
- `GET /panes/pane_N/search` is a WebSocket that streams matches from the server's terminal
  for a client that has not loaded the history. A client that has the
  history searches its mirror.
- A clipboard read is answered with a message on `/client`.

## 6. Remote

Transport: a unix socket forward on the app's ControlMaster,
`ssh -O forward -L <local>:<dir>/socket host`, one per app window as
today's channel is. The client then connects to `<local>` exactly as
it connects locally; nothing runs on the remote besides `ko`. Each
connection is a `direct-streamlocal` channel with SSH's own per-channel
window as its backpressure. These channels are not sessions, so sshd's
`MaxSessions` limit of 10 does not cap the number of views. The remote
sshd needs `AllowStreamLocalForwarding` (its default), and the local
`ssh` needs `StreamLocalBindUnlink yes` so a stale local socket does
not block the forward. No tmux and no `kido rpc` process on the
remote.

Reconnect: the client opens `/client` again with a hello that carries
its current window, pane, size and focus, gets a new id, reopens
`/feed`, and reopens each visible view with the last offset it saw.
The WebSocket ping of protocol.md section 1 closes a half-open
connection after sleep within 40 s, so a dead client does not stay
registered. A view inside the ring
resumes with bytes; otherwise it opens with a snapshot. There is no
event replay: every event kind is a state that the next snapshot or
topology carries.

Latency: keystroke echo is one round trip, as with tmux. Connection
setup is one round trip for the channel open plus the WebSocket
handshake; views are long-lived, so this is paid on attach, not per
key. A snapshot READY prefix for an 80x50 pane is about 20 KiB before
compression. History and images negotiate `deflate`, events and feed
`permessage-deflate`; live view streams never compress. Measured numbers are a spike
deliverable.

### 6.1 Web clients

The protocol is `fetch` and `WebSocket` with JSON and binary messages,
which a browser speaks natively. A web client needs, beyond this
design: a TCP or TLS listener (`ko --listen 127.0.0.1:PORT` or a
reverse proxy), a bearer token in place of the peer uid, and the
`Origin` check that protocol.md already requires. For the terminal
itself it has two paths: libghostty-vt compiled to WebAssembly as a
mirror on the view stream with a canvas renderer, which is the same
client model as every other client; or option B of section 3, a
`/panes/pane_N/cells` stream of row diffs from the server's render
state for a client that only paints. Images use the pixel body path,
snapshots the socket slices, and clipboard consent the browser's own.
Browsers cap plain HTTP/1.1 requests at about six per host, which
limits parallel image fetches and nothing else.

## 7. Risks and unknowns

| risk | why it matters | mitigation |
|---|---|---|
| libghostty-vt API and snapshot format move | both sides pin one revision; a bump is a coordinated change | the protocol version includes the snapshot version; refusal on the first request; the app and kido already move in lockstep |
| a libghostty-vt panic | zmx lost sessions to an abort in hyperlink storage (#182) and in reflow (#215) | one `ko-pane` per pane, so an abort kills one pane; `ReleaseFast`, so a failed hyperlink insert is not an abort; P1.0 fuzzed 1000 resizes over dense OSC 8 scrollback with no abort |
| mirror divergence | a client shows what the server does not have | the mirror contract of 4.3; a partial mirror resyncs on every resize; in debug builds both sides hash the formatter's plain dump of the active screen and compare on each marker (a terminal decoded from a snapshot differs from the original only in an OSC 8 close at a row end once OSC 8 rows scroll, an upstream round-trip difference, so the hash is over plain text, cursor and modes); a snapshot on the client's request; spike 3 measures it |
| OCaml and C callbacks in the mirror | a callback that raises, or re-enters `vt_write`, corrupts state | stubs catch exceptions and forbid re-entry |
| coordinator throughput on floods | the OCaml side must issue one `writev` per view per record without allocating | `writev` straight from the mapped ring; 2 ms coalescing; a slow coordinator blocks the program through the ring's tail, never drops; spike 1 measures MB/s and the allocation rate |
| the Ghostty fork needs a restore-from-snapshot surface API | this is the app's side of C | the fork already has restore and prepend machinery to delete; the decoder returns a `Terminal` of the same Zig type; spike 2 |
| per-client current window changes kido's `watched` and reap semantics | rules that read "the client's current window" | the server knows every client's current window; the rules read the set, not one client |
| upgrade in place with inherited fds | fd numbering, `CLOEXEC`, the pid staying the same | spike 4; a failure falls back to a normal restart, which kills the panes |
| the terminal client is a new program | side column, keys, differ | it is in P1; tmux stays for kido's terminals until stage 4 |
| the hot path is in C | memory and framing bugs in `ko-pane` | no policy in it, fixed framing, `-fsanitize` in tests, a fuzzer on the frame parser and the pty path, two thousand lines |
| losing tmux features people rely on silently | `run-shell` bindings, `.tmux.conf`, copy mode | explicit non-goals; the terminal client ships copy mode only if asked for |

## 8. Spikes, before the first stage

Each spike is bounded and produces numbers or a go/no-go.

1. **`ko-pane` and throughput.** Build `libghostty-vt.a` from the
   ghostty submodule with zig, `ReleaseFast`; write the first `ko-pane`
   (pty read into the shared ring, `vt_write` in place, write_pty,
   semantic prompt, program status, snapshot encode into the ring, the
   control frames) and an OCaml coordinator that maps the ring and
   `writev`s from it to a client socket; feed 1 GiB of mixed output
   through one pane. Report MB/s end to end, callback overhead, the
   hop's latency, the coordinator's allocation rate (it must be zero
   per record), and snapshot size and time for 10k and 100k lines.
   Compare against a plain socketpair copy as the control. Also the `ko_vt` decoder side
   for the mirror. 2 to 3 agent-days, low risk.
2. **Restore a Ghostty surface from a snapshot.** Add
   `ghostty_surface_restore_snapshot(reader)` to the app's fork and show
   that the pen, charset and pending-wrap cases of known-issues render
   correctly after restore, where today's capture replay does not.
   2 to 3 agent-days, medium risk; this decides option C.
3. **Mirror determinism.** Record pty byte streams with resizes at
   offsets; run server and client terminals; compare the formatter's
   screen dumps and the cursor, pen and mode data after each marker.
   1 agent-day, low risk.
4. **Exec-in-place upgrade.** A toy coordinator with two `ko-pane`
   children, state file, exec, mapping the rings and reading the control sockets, on macOS
   and Linux; and a `ko-pane` handoff of the pty master over
   `SCM_RIGHTS`. 1 agent-day, low risk.
5. **Shared-memory images by name.** The server copies a `t=s` upload
   into its own 0600 object; Swift maps it by name and renders without
   a copy. Also: `httpun` on luv with 50 concurrent streaming
   responses, and a Swift HTTP/1.1 client over `NWConnection` on a
   unix socket and on an SSH unix forward. 2 agent-days, low risk; the
   image part runs in stage 3, the transport part in P1.0.

Spikes 1 and 3 and the transport parts run inside P1.0 (p1-mvp.md
section 6.1); spikes 2 and 4 run in stage 0, in parallel.

## 9. Effort by stage

[migration.md](migration.md) gives the stages in detail and the changes
to kido, the app, the pi extension and e2e. The summary, in agent-days
with risk:

| stage | delivers | agent-days | risk |
|---|---|---|---|
| P1 | the MVP of p1-mvp.md: `ko` server and terminal client, flat panes, one on screen, sidebar, benchmarks; includes spikes 1, 3 and the transport and Mosaic spikes | 20 to 30 | medium |
| 0 | spikes 2 and 4, in parallel with P1 | 3 to 4 | medium |
| 1 | server core: ptys, terminals, topology, views, snapshots, input, local socket; Kido.app on it for one local window, text only | 25 to 35 | medium |
| 2 | `kido` CLI, runs, model and feed in the server; pi extension on the protocol; e2e on the protocol | 15 to 25 | medium |
| 3 | image resources with shm by name, clipboard routing, the SSH unix forward and reconnect, deflate | 12 to 18 | medium |
| 4 | terminal client with side column and picker; tmux fork retired; launcher simplified | 15 to 25 | medium |
| 5 | coordinator upgrade in place and per-pane `ko-pane` upgrade; iOS client as a libghostty-vt mirror | 6 to 10, then separate | low to medium |

Total to retire the tmux fork: the rows sum to 96 to 147 agent-days of
implementation plus review and verification. The first user-visible
milestone is P1, 20 to 30 agent-days; stage 1 builds on its code.

These are estimates of agent time with the usual manager, implementer
and reviewer structure. They assume frequent on-screen checks by the
user for the app stages.
