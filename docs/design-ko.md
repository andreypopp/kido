# ko, the terminal server

ko is the terminal server of Kido. It holds the terminal of every pane
in libghostty-vt, serves Kido.app and the `ko` terminal client over one
protocol ([protocol.md](protocol.md)), and runs the agent features of
[design.md](design.md) in the server. This document records the design
as built and the reasons for it. Its last section lists the decisions
with their dates.

## 1. Why

Kido's first implementation ran on a terminal multiplexer and read its
state through a control protocol made for another client. Two
emulators had to agree, content was mirrored through text captures,
status came from polling with whole-second times, two app windows
shared one current window, and every change of the multiplexer's
configuration restarted the server. A purpose-built server removes
each cause instead of patching each symptom.

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
7. **A thin terminal client** for a plain terminal: one pane at a
   time, a list grouped by session.

Non-goals:

- Compatibility with any multiplexer's clients, commands, configuration
  files, plugins, hooks or key tables. ko has no configuration file.
- Linked and grouped sessions. Per-client current window is what they
  were for.
- Copy mode, splits, tabs or windows in the terminal client.
- Scripting the server from the shell beyond the `ko` CLI and `ko api`.
- Surviving a reboot.

## 3. How a client gets content

Three ways were considered:

- **Bytes to the client, the client emulates.** The first
  implementation. Rejected: it is the cause of the content bugs.
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

The third is built. The reasons:

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
  clipboard answerer, the status model, the runs and the prompt. It
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
the identity itself), and `state/run_ops.rs` the
runs, the sweep and the screen capture. `view.rs`, `tail.rs` (the raw
output stream) and `delivery.rs` are the verified stream path
(AGENTS.md, "Verus"); `conn.rs`, `ws.rs`, `http.rs` and `deflate.rs`
the connection, the framing and the slice codec; `api.rs`, `route.rs`,
`router.rs`, `protocol.rs` and `schema.rs` the routes, the wire types
and the OpenAPI document. The status model is `telemetry.rs`,
`program_status.rs`, `pane_kind.rs`, `pane_status.rs` and `model.rs`
([design-program-status.md](design-program-status.md)); `vars.rs`,
`runs.rs`, `msg.rs`, `clipboard.rs`, `shm.rs` and `agent.rs` own the
variables, the runs, the inbox send, the clipboard answerer, the
shared-memory leak record and the `agent.sock` link; `config.rs` the
state directory, the options and the knobs.

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
- The scrollback limits from the server's command line, and the kitty
  image storage limit from `KO_KITTY_IMAGES_MAX_BYTES`. Scrollback
  compression is always on (`ko_vt/src/compress.rs`): after 250 ms
  with an unchanged activity token, `ko-pane` runs one incremental
  step for each loop turn until the library reports completion; after
  2 s of continuous activity it runs one step every 10 ms. The mirror
  runs the same steps on a thread of its own.
- `TERM` is `xterm-ghostty` in every pane, with the terminfo that
  `make build-ko` compiles from Ghostty's source beside the server
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
continues. The coordinator copies nothing: for each attached view it
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
Normalization was chosen over an exact rule so that one engine does
every split, resize, equalize and scale computation and a `409` retry
never has to recompute every size.

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

The server starts with an empty document and keeps running with an
empty one when the last session goes; a client that finds it empty
`PUT`s one session with one pane. A run's window and the sweep's
removals are server-made changes of the same document.

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

Measured in the first build: on macOS a non-blocking writer on a unix
stream socket accepts exactly its own `SO_SNDBUF` before it blocks,
whatever the reader's buffer, so the server sets `SO_SNDBUF` and the
client `SO_RCVBUF` to 1 MiB on view connections. With 8 KiB, reader
stalls of 20 ms skipped; with 1 MiB, stalls of 50 ms every 100 ms did
not. The 2 ms coalescing cut the coordinator's work by about four
times and kept the hop's p99 near 100 us, and a single 2 ms record
reaches 64 KiB only above 32 MB/s for one pane, so the threshold counts
only the backlog after a blocked write, never every record.

Snapshot slices are deflated (`miniz_oxide`, level 1) and live bytes
are raw (protocol.md, section 4). The reason is in "Remote" below.

The raw output stream (protocol.md, section 4, "The output stream") is
the second consumer of a pane's `Delivery`. Its `Tail` keeps a cursor
in the ring, as a view does, and never holds the tail of the ring: a
reader that falls behind gets a `skip`, not a snapshot, and continues
from the oldest byte. A tail writes only while its connection's queue
is empty, so it has no threshold and no spill. A pane's death is the
pane process's state, not the ring's death marker, because a failed
`ko-pane` writes no marker; the tail sends `dead` only after it has
sent every byte up to the ring's head, and the server pumps the tails
of a pane when it dies, before it removes the pane.

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
| `pi.session`, `pi.name`, `pi.inbox`, `pi.activity` | the pi harness through `ko api` | believed only while the pane's root OSC 7501 app is `pi` |
| `ssh.dest`, `ssh.args` | `ko ssh` before it execs ssh | believed only while the pane's foreground process is `ssh` |

A run's pane is tied to its run when the server creates the pane; no
variable names a run. Session and window variables live inside the
layout document.

### 4.10 Status, runs and the model

The model (`ko_server/src/model.rs`) runs when an event marks a pane
dirty, at most once per 16 ms, and never otherwise: a dirty mark arms
one timer, and an idle server with idle panes arms none. It writes
the pane's `status` and sends a `status` event for that pane only.
Times are the server's monotonic clock in nanoseconds. The server
builds no tree: a client builds its own from the layout document, the
pane rows and their runs (`ko_client/src/model.rs`).

Runs are in the server (protocol.md, section 10): the run records on
disk, the sweep over the pane rows on each event that can end a pane,
and `run-wait` as a
long poll.
design.md gives the rules that the runs keep from the first
implementation.

**The loop rule.** Coordinator state changes only on the loop thread.
A long poll or a deadline is a stored waiter in the state plus a loop
timer, never a thread. A thread is permitted only for blocking work
that touches no coordinator state. An endpoint that does not fit this
rule needs a recorded decision before it is built.

### 4.11 The terminal client

`ko` with no arguments is the terminal client (`ko_tui`). It shows one
pane at a time and lists every pane in a sidebar grouped by session,
with a subagent's pane one column deeper than its parent's. It never
shows splits, tabs or windows; a pane in a split is shown clipped or
padded at its size. It is a client like any other: it opens a view for
the pane it shows and mirrors it in libghostty-vt.

One writer draws the screen: a direct cell differ (`ko_tui/src/differ.rs`)
writes the composed cells of the pane region, the sidebar and one
optional warning row. Input that changes the screen draws the next
frame at once; continuous output is drawn at most once per 8 ms, in
one write bracketed by synchronized output. The client emits indexed
SGR for indexed cells, so the outer terminal's palette applies. The
wheel scrolls the mirror; after a skip the first scroll-up resyncs with
history.

Its keys (`ko_tui/src/input.rs`) are Ctrl+Shift chords under the kitty
keyboard protocol: `S` toggles the sidebar, `E` opens the scrollback in
`$PAGER` (default `less -R +G -+F`), `N` adds a window to the shown
pane's session, `Up` and `Down` show the previous and next pane across
sessions, `Q` detaches. `Ctrl+D` on a dead pane removes it. Every
other key goes to the pane. The client pushes kitty keyboard flag 1 on
the outer terminal and queries the capability; a terminal that does
not answer gets a warning row and the sidebar for mouse switching, with
no prefix key fallback (decided 2026-10-30). Outer mouse reporting
stays on while a pane is shown, so selecting text in the outer
terminal needs its override modifier.

The client restores the outer terminal's modes exactly on every exit
path, and never sends RIS or clears the screen. It queries the outer
terminal at start, so replies arrive on stdin among keystrokes; the
input decoder (vte, then `ko_tui/src/input.rs`) routes them.

The status column shows one mark for each pane row with the glyphs and
colours of the first implementation (`ko_tui/src/renderer.rs`): a
running agent or command, a waiting agent, an unseen success, an
unseen failure. The seen rule is in `ko_client/src/status.rs`, shared
with Kido.app: a visit acknowledges an outcome or exit, and a later
one with a new serial shows again.

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
POSIX shared memory. Animation was done properly from the start, with
no fallback: the Ghostty fork reads frame `n` and attaches fetched
pixels to a pending frame outside the snapshot decoder
(`ko_vt/src/frames.rs`).

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
waits 5 s. `SIGTERM`, `SIGINT` and `SIGHUP` stop the server: it hangs
up every pane, waits 500 ms, kills the survivors and exits.

`ko api` sends one HTTP request, as `gh api` does, and never starts a
server. With `--stream`, it upgrades a WebSocket route and prints each
text message as one line, for a script or a harness that reads the
output stream. `ko panes`, `ko layout` and `ko layout put` or `edit` are
readers and writers of the document from the shell. The signal rules
of AGENTS.md ("Signals") apply to every kill.

`ko server --help` lists the server's options; `ko_server/src/config.rs`
reads its environment knobs, and `ko_server/src/panes.rs` sets the
variables of every pane, `SSH_AUTH_SOCK=<dir>/agent.sock` among them,
which a pane's `env` can replace. `--bin-dir` is the shim directory put
first on every pane's PATH (design.md, "The bin directory"); `--shell`
reaches every pane as `KO_SHELL`.
At start the server links `agent.sock` to its own inherited agent only
when the path is absent or a link to no socket file
(`ko_server/src/agent.rs`), so Kido.app's publication wins.

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
slices, so N views that attach at once cost N times the deflate.
Before the spill file of protocol.md, section 4, a compressed
snapshot over the 64 MiB queue cap closed its view with a bare EOF;
now it reaches the client whole. Measured through Kido.app at 50,
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

The reference is the Rust ko at the commit that the last bench run
names (relative, because absolute figures drift with the machine and
its load). A later run
builds that commit in a scratch worktree with `make build-ko` and
measures it first, in the same session, on AC power, at a load average
under 2. A change that moves a row past its rule names the new
reference commit with the reason.

What the first build measured on an M5 Max, which fixed the design:
the pty read and the parse share one thread in `ko-pane`, and each
1 KiB read waits for the parse of the one before, so ingest is bound
by the parser and the ring and the coordinator hop cost nothing
measurable; a 100k-line history encodes in a few milliseconds and
decodes in under ten, so snapshots go over the socket and no file path
is needed; the hop from a pty byte to the coordinator's socket write
is tens of microseconds; the coordinator idles under 15 MiB and an
idle `ko-pane` under 2 MiB of footprint; and on macOS the memory rows
are judged by `phys_footprint`, because libghostty-vt frees compressed
pages to the OS, which takes them back lazily, so RSS stays at its
peak.

## 7. Decisions

Each decision names its date. The code states the rest.

2026-10-29:

- The executable is `ko`. The server is a thin terminal client's and
  Kido.app's server, with no compatibility with the first
  implementation's multiplexer, no linked or grouped sessions, a
  per-client current window, clipboard requests routed by the server,
  and upgrade in place as a goal.

2026-10-30:

- Kido's first implementation ends and ko replaces it. The terminal
  client shows one pane at a time from a list grouped by session,
  never splits, tabs or windows. Kido.app keeps sessions, windows,
  splits, floats, zoom and its sidebar.
- The layout is one server-validated JSON document, changed by a
  whole-document `PUT` with a revision check. Panes carry arbitrary
  client-set JSON variables in place of a multiplexer's user options.
- The server is two programs: the coordinator and one `ko-pane` for
  each pane, with a shared ring and no copy between them, and the
  control channel on `ko-pane`'s stdio.
- Every pane runs `TERM=xterm-ghostty`. Scrollback compression is
  always on. The pane's foreground process is read only on events.
- A terminal without extended keys gets no chords and no prefix
  fallback. The outer mouse reporting stays on while a pane is shown.
- No `ko.conf`. No daemon that survives a coordinator crash. The
  status glyphs and colours of the first implementation stay in the
  terminal client; its 0.5 s hold of a finished command's row is
  dropped, because events arrive at once.
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
  ko has had no release, so the version is 1.0.
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
- The cut-over deletes the first implementation and its build system;
  the repo is a cargo workspace with `share/` and the TypeScript
  harness. A `ko_shell` crate holds the shell priming. The cut-over
  comes after remote. Linux lands before remote.
- ko-pi's state directory starts empty; nothing migrates.

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
  the client, "transfer" the first to last snapshot slice; miniz was a
  scratch build that deflated snapshot slices only:

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
  and gains nothing. The shipped level 1, measured again in the same
  cell: history loaded 4.90 s against 8.69 s, transfer 2.38 s against
  6.19 s, wire bytes 29.7 MB against 77.4 MB; the local floor rose
  from 0.33 s to 0.59 s and the server's CPU from 0.01 s to 0.26 s.
  Through Kido.app (`app/scripts/rtt.py`, one run for each cell, the
  same proxy, a 81.6 MB snapshot over 30.4 MB on the wire): attach
  0.9 s at 50 ms, 2.5 s at 150 ms and 4.3 s at 300 ms RTT, with and
  without compression; echo p50 under 1 ms over the RTT in every cell;
  the mixed restore 1.0 s, 2.9 s and 5.7 s at unlimited bandwidth,
  2.6 s, 3.0 s and 5.7 s at 100 Mbit/s, and about 25 s at 10 Mbit/s.
  Before compression every mixed restore in the app stalled after
  about 1.9 MB, because the per-view queue cap closed the view with a
  bare EOF that the client missed (the spill file and the close frame
  of protocol.md, section 4, fixed that).
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
- Kido.app and ko ship from `main`; the first ko release is the tap
  formula `ko`, version 0.1.0, built from source with the pinned
  toolchains.
