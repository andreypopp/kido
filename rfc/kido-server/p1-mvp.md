# P1: the MVP, server and thin terminal client

Status: plan, 2026-10-29. P1 precedes every stage of
[migration.md](migration.md). It proves the server core and the
mirror design on the smallest product that a person can use all day:
a flat list of panes, one on screen, a sidebar to switch.

## 1. Scope

In:

- `ko`, the server, and `ko`, the thin terminal client, in one binary.
- A **flat list of panes**. No sessions, no windows, no splits, no
  tabs, no floats, no zoom. Pane ids are `pane_N` and client
  ids `client_N`, allocated once per server life.
- The client shows **one pane at a time**, full screen, and a
  **sidebar** that lists every pane and switches between them.
- `ko` with no arguments attaches to the running server of the default
  state directory, or starts one and attaches.
- The protocol subset of section 4, over HTTP/1.1 on the unix socket.
- Performance work: throughput, latency and memory, measured against
  tmux on the same machine (section 6).

Out, until later stages:

- Every kido-specific feature: runs, the model and feed, agent fields,
  OSC 7501 handling, OSC 133 beyond what libghostty-vt does by itself,
  ssh marks, prompt delivery, the pi extension, Kido.app.
- Images on screen, clipboard routing, search, remote attach,
  upgrade in place, `ko.conf` beyond the few
  settings in 3.4.
- Copy mode. Instead: mouse wheel scrolling of the mirror, and
  Ctrl+Shift+E to open the scrollback in `$PAGER`.

## 2. Layout

    ko_pane/      the pane process `ko-pane`, in C: pty, libghostty-vt,
                  the frame codec of protocol.md section 14; built by a
                  dune rule with the same flags as the library, with
                  `-fsanitize=address,undefined` in the test build and
                  libFuzzer targets for frame sizes and frame bodies
    ko_vt/        the libghostty-vt binding for the client's mirror:
                  terminal, snapshot decoder, render state, scroll,
                  formatter
    ko_server/    the coordinator library: Loop, Pane_proc, Pane, Panes,
                  Client, View, Input, Http (the router), Connection
                  (the socket and its queued `writev` output), State
                  (the registry of clients and views), Protocol (the
                  wire JSON types), Ws (WebSocket frames), Uv (luv and
                  OS conversions), Pid (the only signal calls), Config
    ko_server/fuzz/  the QCheck fuzz properties, a test-only library
    ko_tui/       the thin terminal client library: Mosaic for the
                  sidebar and input, a direct cell differ for the screen
    bin/ko.ml     the entry point: `ko` (attach or start and attach),
                  `ko server` (foreground), `ko kill-server`,
                  `ko version`, `ko api`; `ko-pane` is found beside
                  the executable
    third_party/ghostty   submodule, built by zig into libghostty-vt.a
                  through a dune rule; the terminfo for xterm-ghostty
                  installed beside the binary
    bench/        the benchmark scripts and their recorded streams, and
                  the P1.0 probes `coordinator.exe` and `wait_master.exe`
    test_e2e_ko/  the Go protocol suite of section 7

The code rules of AGENTS.md apply: `.mli` for every module, inline
ppx_expect tests, `-open Containers`, library code returns and the
CLI reports. kido's `lib/` is not touched in P1 and nothing in `lib/`
depends on the new directories.

## 3. The server in P1

### 3.1 Lifecycle

- `ko server --server DIR` runs in the foreground and listens on
  `DIR/socket`. `DIR` is `$KO_STATE_DIR`, else `$XDG_STATE_HOME/ko`,
  else `~/.local/state/ko`, with the mode, owner and 103-byte checks
  of kido's `Server_dir`. This is the one rule for every stage;
  design.md and migration.md refer to it. The config file, when a later
  stage adds it, is `$XDG_CONFIG_HOME/ko/ko.conf`.
- `ko` connects. On no socket, or on `ECONNREFUSED` (the one condition
  under which the socket file is stale and removed; a connect timeout
  means a busy server, never a stale one, zmx 11a12cc), it starts
  `ko server` detached (`setsid`, stdio to `DIR/log`), waits for the
  socket with a deadline of 5 s, then connects.
- The server runs until `ko kill-server`. The last pane exiting does
  not stop it. `ko kill-server` sends no HTTP request: it connects to
  the socket, reads the server's pid and uid from the peer credentials
  (`LOCAL_PEERPID` on macOS, `SO_PEERCRED` on Linux), refuses a uid
  other than its own (`server belongs to another user`), sends
  `SIGTERM` and waits 5 s for the process to exit and the socket to go
  (`server did not stop within 5 s`). Errors exit 1. So it stops a
  server of any build, even one whose HTTP side does not answer. A client detaching does not stop it.
- `ko api [--server DIR] [--method M | -X M] [--input FILE]
  [--include | -i] PATH` sends one HTTP request to the server, as
  `gh api` does. `PATH` starts with `/`; a query string passes
  through. The method is GET, or POST with `--input`, which sends the
  file (`-` for stdin) as the body. It prints the body unchanged, and
  with `--include` the status line and headers first. It exits 0 on a
  2xx status; on another status it prints the body, writes
  `ko api: HTTP <code>` to stderr and exits 1. With no server it
  writes `ko api: no server at DIR` and exits 1; it never starts one.
  It refuses the WebSocket endpoints (`/client`,
  `/panes/ID/view`) with exit 2.
- `SIGTERM` to the server sends `SIGHUP` to every pane process, waits
  500 ms, sends `SIGKILL` to the survivors (shells ignore `SIGTERM`),
  and exits. `ko-pane` itself, on shutdown or on EOF of its control
  socket, sends `SIGHUP` to its program's process group and `SIGKILL`
  when the program exits or after 250 ms, ahead of the coordinator's
  500 ms. `ko-pane` owns
  the program's group: it forked the program and knows its pid. The
  coordinator signals `ko-pane` only through the pid of its own
  spawn. Every signal goes through `Pid`: its pid type cannot hold
  1 or less, the coordinator's pid or its group, and its group type
  exists only for a verified child. When a pane process fails or exits without its dead marker,
  the coordinator also kills the program's group, so a program that
  ignores `SIGHUP` outlives neither a crashed `ko-pane` nor a crashed
  coordinator. It does this only for the child that it verified at
  `ready` (protocol.md section 14), and only if the process still has
  the recorded start time and leads its group. While `ko-pane` lives,
  it keeps its reaped program as a zombie until its own final group
  kill, so the pid and group id cannot be reused under either signal.
  After `ko-pane` died, a small race remains between the coordinator's
  check and its signal; the pid would have to exit, be reused and lead
  a new group in that interval. If the leader has exited, the
  coordinator does not kill the rest of its group. Only both dying at once leaves the program. `ko-pane` reaps its program with `WNOHANG` from a
  `SIGCHLD` self-pipe and keeps the master of a dead pane open for its
  screen. P1.0 verified on macOS: the program is reaped with the master
  open, and the dead pane still snapshots; a writer blocked on a full
  pty is not reaped until the master is read, so `ko-pane` reads the
  master to EOF before it sends `dead`. The status travels in the
  ring's dead marker and the `dead` frame on the control socket, two
  channels; the server makes the pane dead (row and event) only on the
  control frame, so a client always sees the pane's last title and
  pwd before `dead`.

### 3.2 Panes

A pane is a `ko-pane` child over a shared ring and a control
socket (its stdio), holding the pty, the program and the libghostty-vt
terminal, as design.md 4.1 and 4.3
describe, with these options active: `WRITE_PTY`,
`CONTINUATION_MAX_BYTES`, `TITLE_CHANGED`, `PWD_CHANGED`,
`SCROLLBACK_MAX_BYTES`, `SCROLLBACK_MAX_LINES`. The rest is left at
defaults in P1.

Scrollback compression is always on; no option turns it off (decided
2026-10-30). After writes, `ko-pane` reads
`ghostty_terminal_compression_activity`; when the token stays
unchanged for an idle period, it calls
`ghostty_terminal_compress(..., INCREMENTAL)` from its poll loop until
the call returns `COMPLETE`. After 2 s of continuous activity with no
idle period, it runs one incremental step every 10 ms until an idle
period returns, so output that changes the history more often than the
idle period (a busy `tail -f`) still gets compressed (decided
2026-10-30). The client mirror runs the same steps, and its snapshot decoder compresses history pages while it
restores them (section 5).

A pane's size is set by its sizing client, as design.md 4.4 defines:
the client whose focus is on the pane, or the one that last switched
to it. A resize from another client never claims the pane. The client
learns its focus from the outer terminal's focus events (mode 1004)
and sends `{focused}`. A pane whose sizing client disconnects, or that
no client shows, keeps its last size.

A pane whose process exits stays in the list as dead with its status
and signal until a client removes it. This is the behaviour the run
rules need later; P1 only keeps the state. A client that shows a pane
when it dies keeps showing it, with the exit status in the sidebar row
and the pane's last screen; it switches nothing on its own.

The default command is the user's login shell from `$SHELL`, as a
login shell, in the client's cwd at creation. `TERM=xterm-ghostty`,
`TERM_PROGRAM=ko`, `TERM_PROGRAM_VERSION` (the build id that
`ko version` prints as `build`), `KO_SOCKET` and `KO_PANE` (the pane's
id, `pane_N`) are set in the pane's environment, over any inherited
value, as tmux does: a pane must not claim the launcher's terminal.

### 3.3 Streams and backpressure

As design.md 4.4 and 4.6: output sequence numbers, a 1 MiB ring per
pane, 2 ms coalescing, views as streaming responses, snapshots on
open, after resize, and after a skip. The server sets `SO_SNDBUF` and
the client `SO_RCVBUF` to 1 MiB on view connections. The server's pty
write path writes at once, queues on `EAGAIN`, never drops, and
processes a client's close after its queued input. A pane's output is
read until `EAGAIN` on each wakeup, because Linux returns at most 4 KiB
per pty read and macOS 1 KiB (P1.0: 99.8 percent of macOS reads are
exactly 1024 bytes, then `EAGAIN`). Every pane's output is parsed from the moment the pane
starts, with or without a client; modes a program sets before the
first view opens are in the first snapshot (zmx #246, #264).

### 3.4 Config

No config file is read in P1. The server takes these options on its
command line, with Ghostty 1.4's names and defaults (decided
2026-10-30):

- `--scrollback-bytes BYTES|unlimited`, default 50 MB (50_000_000), mapped to
  `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` (`unlimited` passes NULL). At about 708 bytes per
  row at 80 columns (P1.0) this keeps about 70k rows.
- `--scrollback-lines N|unlimited`, default unlimited, mapped to
  `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`. Both take positive values only.
- `--no-scrollback`, which keeps no scrollback (bytes 0). It conflicts with
  the two options above.
- `--shell PATH`.

The first scrollback limit reached applies. The byte limit counts
uncompressed pages, so compression lowers resident memory, not the
history kept. The client mirror uses the same limits as the server's
terminal, which `/version` reports (the mirrored-terminal contract).
The 100k-line rows of section 6 run with a byte limit large enough to
keep all 100k lines. The launcher passes nothing. `ko.conf` arrives in
a later stage.

## 4. Protocol subset

From [protocol.md](protocol.md), with sessions and windows removed:

    GET    /version
    GET    /client                                    WebSocket: the client.
                                                      Out first: {hello: {kind:
                                                      terminal, name, pane?,
                                                      focused, size}}; in:
                                                      {welcome: {client}},
                                                      then events (below).
                                                      Out later: {select:
                                                      {pane}}, {size},
                                                      {focused}. Detach is
                                                      the close.
    GET    /panes                                     [{id, pid, command,
                                                        cwd, title, dead}]
    POST   /panes {cwd?, command?, env?}              -> {pane}
    DELETE /panes/pane_N
    GET    /panes/pane_N/view?offset=&history=none|all   WebSocket: records out,
                                                      input events and
                                                      resync requests in
    GET    /panes/pane_N/screen?format=plain&history=all  text for the pager
    POST   /panes/pane_N/input                            the same events for a
                                                      sender with no view
    events on /client                                 {topology: {panes: [...]}}
                                                      on every list change,
                                                      {pane, title},
                                                      {pane, pwd},
                                                      {pane, dead}

`images` on a view is fixed to `none` in P1: the mirror still stores
inline kitty payloads that arrive in the bytes, and the client draws
nothing for them. The view's snapshot carries no pixel payload records.
`GET /version` includes the `limits` options of the mirror contract,
and the client applies them to its mirror.

## 5. The client in P1, `ko_tui`

The client draws two regions, the pane and the sidebar, and one
optional warning row at the bottom. One writer draws the screen: a
direct cell differ writes the composed cells of both regions. Mosaic
parses the input and runs the loop, and draws nothing; the client
draws the sidebar and warning into its own cells only when the layout
changes (6.2, 6.4, 6.5).

- **The pane.** A libghostty-vt mirror of the shown pane, opened with
  `history=all` so the wheel can scroll, fed by the view stream on a
  background thread that also runs the snapshot decoder. The client's
  receive buffer is consumed by offset, never by erasing its front
  (zmx #273 spent minutes at full CPU on that). Each frame reads the
  render state's cells and cursor. A pane frame of another size (a
  pane sized by another client) is clipped or padded to the local
  region. The mirror's viewport is what scrolls: the wheel moves it
  with libghostty-vt's scroll API, 3 rows a notch, and any output or
  key returns it to the bottom, as a terminal does.
- **A dead pane.** While the shown pane is dead, the bottom row of the
  pane region shows `[exited N — Ctrl+D to remove]`, or
  `[killed by SIGNAME — Ctrl+D to remove]` for a signal (`signal N`
  for a number without a name), in reverse video across the pane
  width. The mirror's rows are drawn one row up, its top row hidden,
  so its last row stays visible above the line; no resize goes to the
  server. The cursor is hidden. The wheel still scrolls. The line goes
  when the pane is removed or another pane is shown.
- **Frames.** Input that changes the screen (a key, a click, a wheel, a switch)
  draws the next frame at once; continuous output is drawn at most
  once per 8 ms. Each frame is one `write`, bracketed by
  `CSI ? 2026 h` and `l`, with the modes, the changed cells and the
  cursor. While the pane holds synchronized output (mode 2026) the
  frame is held, for at most 150 ms.
- **The sidebar.** One row per pane: `N title`, and ` †status` for a
  dead pane; an empty title falls back to the command's basename,
  then to the pane id. It has no colours or styles; the current pane's
  row is in reverse video across the full width, and while Up and
  Down choose, the reverse row follows the choice. A `│` in the
  terminal's default colour fills one column between the sidebar and
  the pane on every row of the pane region; the pane region, and the
  size sent to the server, exclude it, and a click on it does nothing.
  The warning row is reverse video too, with no colour. Up and Down move, Enter switches, a click switches;
  key releases do not move. `Ctrl+Shift+S` toggles it. Width is
  fixed at 24 columns in P1, and the pane starts at column 25. It is hidden by default when the
  terminal is narrower than 100 columns, and always shown while the
  warning row is shown.
- **Keys.** Every key goes to the pane as a `key` message on its view
  except these,
  which the client takes first:
  - `Ctrl+Shift+S`: toggle the sidebar.
  - `Ctrl+Shift+E`: fetch `/screen?history=all`, stream it to a 0600
    file under `$TMPDIR` (as large as the pane's scrollback), suspend Mosaic (`Matrix.suspend`), run `$PAGER`
    (default `less -R +G -+F`) on the tty, unlink the file, resume and
    redraw. `+G` starts at the end; `-+F` keeps less open when the
    scrollback fits one screen, which a user's `LESS=-F` would
    otherwise end at once. The user's other `LESS` flags stay. A set
    `$PAGER` is used as is.
  - `Ctrl+Shift+N`: new pane.
  - `Ctrl+D` (legacy `0x04` or CSI u) on a dead pane removes it, then
    switches to the first remaining pane, or creates a new pane if
    none remain. On a live pane `Ctrl+D` goes to the pane. Other keys
    on a dead pane do what they did before.
  - `Ctrl+Shift+Up`, `Ctrl+Shift+Down`: previous and next pane.
  - `Ctrl+Shift+Q`: detach.

  Ctrl+Shift chords exist only under the kitty keyboard protocol or
  xterm's `modifyOtherKeys`; a legacy terminal reports `Ctrl+Shift+E`
  as `Ctrl+E`. The client pushes kitty keyboard flag 1 on the outer
  terminal itself (Mosaic's own push is off) and queries the
  capability. Until the reply or the first Ctrl+Shift chord arrives,
  it shows a one-line warning and the sidebar for mouse switching.
  Ghostty, kitty, WezTerm, foot and Kido.app answer the query;
  Terminal.app does not, and tmux does not even with `extended-keys
  on`, though it passes the chords (6.4). libghostty-vt ships a key
  encoder, not a decoder: Mosaic decodes the outer terminal's CSI u
  and legacy sequences into key events, and the client encodes them
  again for the pane through the server. `unshifted_codepoint` is the
  key's base character: lowercase for an ASCII or Latin-1 letter, the
  US base key for shifted punctuation, else the character itself; 0
  for a key with no character. A shifted key carries its shifted text:
  the outer terminal's associated text if it sent one, else its
  shifted key, else the US or Latin-1 shifted form; this applies with
  Alt too, not with Ctrl or Super. A terminal under flag 1 sends a
  shifted printable key as plain text (`A`, `:`); the client still
  accepts the CSI u forms (`CSI 97;2u`). The e2e tests under an outer tmux send the CSI u byte sequences with
  `send-keys -l`. A terminal without extended keys gets no prefix
  fallback (section 10).
- **Replies from the outer terminal.** The client queries its outer
  terminal (modes, kitty keyboard, later images), so replies arrive on
  its stdin among keystrokes, possibly split across reads. The input
  decoder swallows every private-marker CSI (`?`, `>`, `=`, `<`), APC
  `_G` replies and focus events as non-keys, and passes focus and
  bracketed paste on as typed events. A test feeds XTVERSION, kitty
  flags and DA1 in one read and asserts no key event (zmx #266, #291).
- **Outer terminal modes.** At start the client reads the outer
  terminal's modes with DECRQM, ended by a DA1 reply (150 ms
  deadline). While a pane frame is shown, it keeps mouse 1000 with
  1006, focus 1004, bracketed paste 2004 and kitty flag 1 on, because
  it needs the wheel, sidebar clicks, focus and the chords; the pane's
  requests extend them (1002, 1003, more kitty flags). It sets one of
  1000, 1002 and 1003 with `h`, and resets a different one with `l`
  only if it was on, and before the `h`: Ghostty turns all mouse
  reporting off on a reset of any of the three, and tmux on 1002 or
  1003 reset, so a reset after the set leaves no mouse. On detach,
  SIGHUP, SIGTERM and before the pager it undoes them: it restores
  each mode it read (resets before sets, by the same rule), a mode
  with no answer to off and cursor
  visibility (25) to on, pops each kitty keyboard flag it pushed with
  `CSI < u`, sends `DECSCUSR 0`, and never sends RIS or clears the
  screen (zmx #26, #157, #168, #222, #263). Mosaic's own signal
  handlers are off; the client's cleanup runs on every exit path.
- **Colours.** The client emits indexed SGR for indexed cells and RGB
  only for cells whose colour is an RGB override, so the outer
  terminal's own palette applies (zmx #7).
- **Mouse.** Wheel over the pane scrolls the mirror. Click, drag and
  wheel inside a program that tracks the mouse go to the pane as
  `mouse` messages, in pane coordinates. The client decides from the
  mirror's mouse tracking mode, which the render state reports. Events
  on the warning row and outside the pane and sidebar rectangles go
  nowhere.
- **Resize.** On `SIGWINCH` the client computes the pane region and
  sends `{size}` on `/client`. The server resizes the pane
  and the view stream carries the marker; the full mirror applies it
  itself and needs no snapshot. A marker or bytes that arrive while a
  snapshot decodes are queued and applied after it; a new first slice
  abandons the old decoder.
- **Attach.** `ko` connects to `DIR/socket`; on no socket or
  `ECONNREFUSED` it takes `DIR/launch.lock`, checks again, removes a
  refused socket, starts `ko server --server DIR` under `setsid` with
  stdio to `DIR/log` (0600) and waits for the socket for 5 s. Two `ko`
  started at once start one server. It opens `/client` with a hello;
  the `welcome` and the first `topology` follow. If the list is empty,
  `POST /panes`; send `{select}` for the first pane and open its view.
  Switching a pane is `{select}` and a new view. Detach, closing the
  outer window and a crash all close `/client`; the server then
  deletes the client and closes its views. A new `ko` is a new hello:
  it selects the first pane and opens its view with a full snapshot;
  P1 keeps no selection or offsets across processes.

## 6. Performance

The goals follow kitty's (decided 2026-10-30): latency while typing,
smooth scrolling and CPU use, balanced against each other; raw
throughput is not first. kitty's defaults add `input_delay` 3 ms and a
repaint delay to save CPU; its low-latency settings are `input_delay 0`,
`repaint_delay 2`, `sync_to_monitor no`.

Targets on an M-series Mac and a Linux box (Linux is not measured in
P1; decided 2026-10-30), local only, measured by
`bench/` scripts that start a private server on a scratch socket and
print one table:

| metric | target | baseline |
|---|---|---|
| ingest throughput, one pane, `cat` of a 1 GiB recorded stream | within 10 percent of the same pty read with `vt_write` in the reader and no ring (6.2, row 2); `ko-pane` plus the coordinator under 1.3 cores; coordinator allocation bounded per write call, none per byte | tmux and kitty on the same stream, and `kitten __benchmark__` in ko-pane, tmux and kitty |
| end-to-end, `yes` for 5 s in a shown pane | the client keeps the screen current through skips; the client's CPU under 1 core; no growth of the ring beyond 1 MiB | tmux attached |
| keystroke echo latency, quiet pane | p50 under 1 ms and p99 under 3 ms added over a raw pty, including the ring and control hops | tmux |
| attach to a pane with 100k lines of history | the screen visible under 50 ms; history fully loaded under 500 ms | tmux attach plus a `capture-pane -S -` of the history, which is what a client that wants the history pays under tmux |
| resize of a pane with 100k lines | under 100 ms to the new READY | tmux |
| server memory | coordinator under 15 MiB idle with no panes; each idle `ko-pane` under 2 MiB plus its scrollback bytes | tmux |
| client memory | under 40 MiB with a 100k-line mirror | tmux's client |

Tooling: `bench/stream.ml` plays a recorded stream into a pty at full
speed; `bench/echo.ml` measures round trips through the client's tty
with an outer pty; `/usr/bin/time -l` and `ps` for memory; `perf` on
Linux and `sample` on macOS for profiles. Recorded streams are checked
in under `bench/streams/` (a build log, a `cat` of a large text file,
`yes`, a TUI session with alternate screen and colours).

What the numbers decide:

- Whether the coordinator's single thread keeps up with fan-out. The
  parsing runs in the pane processes, one core each, so the
  coordinator only copies frames to views. If it holds above about 70
  percent of a core under twenty flooding panes, the coalescing window
  grows before anything else changes. Domains are not planned.
- Whether Mosaic draws the pane (5).
- The 2 ms coalescing and the 64 KiB resume threshold, which are
  guesses until measured.
- Whether a large snapshot to a local client goes through the socket
  or through a server-written file (design.md 4.6), decided by the
  100k-line attach row.

### 6.1 Spikes inside P1

Before the server and client are written in full:

1. `ko-pane` and throughput (design.md 8.1), extended with the ring
   and one view connection writing to `/dev/null`; a `ReleaseFast` build
   and a fuzz of resizes over a scrollback dense with OSC 8 hyperlinks
   (zmx #182, #215); the decoder fed a stream with its payload records
   filtered out; `waitpid WNOHANG` on macOS with the master open; and
   the pty master under luv as `Pipe` first (macOS kqueue has no pty
   support, so libuv falls back to its select thread, which `Poll`
   lacks).
2. Mirror determinism (design.md 8.3).
3. Mosaic full-screen cell rendering at 60 Hz with every cell
   changing, and its input latency; against a direct differ.
4. httpun and httpun-ws on luv: 50 WebSocket views with backpressure,
   and a Go client over the unix socket reading them.

### 6.2 P1.0 results

Measured 2026-10-30 on an M5 Max under macOS, with other load on the
machine (load average about 4). Linux is not measured yet. The spike
code is in `ko_pane/`, `ko_vt/` and `bench/`; `spikes/` was removed
when production code replaced it.

Throughput, the 1 GiB mixed stream of `bench/streams/` (build log, text,
`ls`, `git log`, `yes`, a TUI, dense OSC 8, a shell with OSC 133),
same producer, same pty:

| row | MB/s | CPU |
|---|---|---|
| 1. raw pty, read until `EAGAIN` and discard | 182.6 | 0.62 core |
| 2. pty, `vt_write` in the reader, no ring | 86.2 | 0.92 core |
| 3. `ko-pane` and the ring, a C tail-acker | 81.0 | 0.97 core |
| 4. the full path: `ko-pane`, the coordinator, a view socket, a drain | 82.4 | 1.01 cores (coordinator 0.92 s of 13.2 s) |
| 5. control: pty copier, socketpair, drain | 161.8 | 0.68 core |
| tmux 3.8, private detached server | 24.2 | 1.0 core |
| kitty 0.49.2 window, defaults, rendering on | 50.8 | |
| kitty, low-latency settings | 59.0 | |
| `vt_write` alone, in process, no pty | 135 (text 1092, `ls` 558, `git log` 542, TUI 428, shell 242, `yes` 150, OSC 8 38) | 1 core |

The gap from 135 MB/s to 82 MB/s is between rows 1 and 2: the pty read
and the parse share one thread, and every 1 KiB read waits for the
parse of the one before (3.6 s of reading plus 1 GiB at 135 MB/s). The
ring costs 6 percent (rows 2 to 3) and the coordinator hop nothing
measurable (rows 3 to 4), so no profile was needed. Callbacks cost 2 to
9 percent end to end, all from the shell stream's event frames.

`kitten __benchmark__` (500 repetitions, rendering suppressed), MB/s:

| row | ASCII | Unicode | multi-codepoint | CSI | long escapes | images | mean |
|---|---|---|---|---|---|---|---|
| `ko-pane` | 166.6 | 166.7 | 135.3 | 152.3 | 167.0 | 175.2 | 160.5 |
| tmux 3.8 | 42.3 | 11.1 | 8.4 | 26.9 | 105.1 | 70.8 | 44.1 |
| kitty, defaults | 170.0 | 166.4 | 58.3 | 57.6 | 167.8 | 151.2 | 128.6 |
| kitty, low-latency settings | 352.0 | 346.5 | 65.4 | 109.6 | 120.1 | 101.5 | 182.5 |

The rest of spike 1 and spike 2:

| metric | target | measured |
|---|---|---|
| hop latency, pty byte to the coordinator's socket write | p50 under 1 ms, p99 under 3 ms (echo, added) | `writev` stub: p50 33 us, p99 109 us, max 1.3 ms |
| coordinator minor words per record, 2 ms coalescing | none per byte | `writev` stub 6.9 (0.4 without event frames); `Luv.Stream.write` 154; writing on each head 26 |
| snapshot, 10k lines, through the ring | screen under 50 ms | full 1.27 MB in 0.65 ms; screen 70 KB in 0.08 ms |
| snapshot, 100k lines written (47,402 rows kept by 32 MiB) | screen under 50 ms, history under 500 ms | full 6.0 MB in 1.65 ms, decoded in 6.7 ms; screen 16 KB in 0.06 ms |
| resize to READY, 100k lines written | under 100 ms | 2.34 ms, a 61 KB screen snapshot |
| resize fuzz over dense OSC 8 scrollback | no abort | 1000 resizes, no abort |
| mirror determinism, 2000 random resizes over 63 MB | no divergence | full mirror: none; partial mirror resizing itself: 18 (reflow needs the history); decoded terminals: an OSC 8 close at a row end only |
| decode with payload records filtered out, a kitty image | decodes | decodes; the image stays pending |

Spike 3, drawing a 200x60 and a 400x120 screen with every cell and
colour changing at 60 Hz; key to frame is measured to the last cell of
the frame; all three write the same bytes (136 KB and 545 KB a frame):

| renderer | fps | CPU per frame | key to frame p50 / p99 |
|---|---|---|---|
| direct cell differ, 200x60 | 65.9 | 1.29 ms | 2.5 / 4.7 ms |
| Matrix, 200x60 | 51.3 | 3.12 ms | 12.2 / 21.3 ms (4.5 / 7.9 with immediate redraw) |
| Mosaic canvas, 200x60 | 47.2 | 4.08 ms | 12.4 / 27.5 ms |
| direct cell differ, 400x120 | 64.2 | 2.92 ms | 7.3 / 12.4 ms |
| Mosaic canvas, 400x120 | 52.0 | 9.28 ms | 11.4 / 30.7 ms |

Matrix's parser decodes Ctrl+Shift+S, E, N, W, Q, Up and Down as CSI u
chords, SGR 1006 wheel and clicks, and swallows XTVERSION, the kitty
flags reply, DA1, an APC `_G` reply and focus in one read or split
across reads.

Spike 4, 50 WebSocket views on httpun-ws and luv for 10 s, 10 of them
stalling 300 ms every 1000 ms:

| | 8 MB/s a pane, 1 MiB buffers | 33 MB/s a pane, 1 MiB | 8 MB/s a pane, 8 KiB |
|---|---|---|---|
| aggregate | 324 MB/s | 4028 MB/s | 333 MB/s |
| coordinator CPU | 9.6% | 31.7% | 20.3% |
| skips, live / stalled views | 0 / 100 | 0 / 151 | 0 / 100 |
| echo p50 / p99, quiet pane | 0.07 / 0.55 ms | 0.06 / 1.34 ms | 0.04 / 0.49 ms |
| echo p50 / p99, flooded pane | 0.18 / 0.66 ms | 0.59 / 1.71 ms | 0.22 / 0.71 ms |
| pane writer blocked by an in-flight write, p99 | 7 ms | 283 ms | 162 ms |

No offset gap appeared without a skip. The 2 ms libuv timer fires at
about 2.5 ms. httpun-ws needs a SHA-1; the spike carries its own, and
P1.1 locks a package or keeps it. The peer uid check works through
`Luv.Handle.fileno` and `LOCAL_PEERCRED`.

Decisions the numbers force:

- **The pane region is drawn by the direct cell differ**, between
  Mosaic frames. Mosaic keeps the sidebar and input; its parser handles
  the chords and replies. Mosaic costs about three times the CPU a
  frame and adds up to a frame of key latency.
- **Coalescing stays at 2 ms.** It cuts the coordinator from 4.2 s to
  0.94 s per GiB and the allocation from 26 to 7 words a record, and
  the hop p99 stays at 109 us.
- **The resume threshold stays at 64 KiB, counted only on the backlog
  after a blocked write.** A single 2 ms record reaches 64 KiB above
  32 MB/s a pane, so a threshold on every record would skip a live view.
  With 1 MiB `SO_SNDBUF`, live views never skipped.
- **The view write is a non-blocking `writev` stub with `Luv.Poll`**,
  never `Luv.Stream.write` on the ring (design.md 4.6). The stub path is
  as fast and allocates 22 times less.
- **The coordinator has no luv handle for the pty**: `ko-pane` reads it
  in C. For the record, `Luv.Pipe.open_` works on a macOS pty master and
  also gets 1 KiB a read.
- **Snapshots go over the socket.** 6 MB of history encodes in 1.65 ms
  and decodes in 6.7 ms; `snapshot_file` is not needed in P1.
- **Throughput is judged against the parser, tmux and kitty**, not 400
  MB/s (section 6). `ko-pane` is 3.4 times tmux on the mixed stream and
  ahead of kitty's defaults in `kitten __benchmark__`.

Open for P1.3: a reader thread in `ko-pane` that runs ahead of the
parser would hide most of the 3.6 s of reading (about 30 percent); and
kitty's ASCII rate of 352 MB/s with low-latency settings is twice the
raw macOS pty ceiling that `ko-pane` sees, so kitty gets more than 1 KiB
a wakeup or its writer differs. Neither is explained yet.

To run them again: `bench/run.sh`, `bench/baselines.sh` and
`bench/kitten.sh` (the kitty rows open windows);
`_build/default/bench/coordinator.exe throughput|latency|snapshot|pty-pipe|allocation`;
`_build/default/bench/wait_master.exe`;
`python3 bench/client.py` for the client's key-to-frame latency and CPU
(6.4). The spike 3 driver was removed with `spikes/mosaic/` in P1.2.
The spike 4 driver (`spikes/http/`) was removed with the spike server
in P1.1; P1.3 measures the same table against `ko server`. Since P1.1
`bench/coordinator.exe` runs the production `Pane_proc` and
`Connection` with 2 ms coalescing only; the `Luv.Stream.write` and
zero-coalescing comparison rows are gone, and its callback rows
counted only the title and pwd callbacks that P1 registered (the
`--no-callbacks` switch that produced the without-callbacks row was
removed after the measurement).

### 6.3 What P1.1 settled

The server of P1.1 follows sections 3 and 4 and protocol.md. These
points were open or wrong in the plan:

- **Key events carry `unshifted_codepoint`** (protocol.md 8 and 14).
  libghostty-vt's encoder finds the kitty keyboard code of a printable
  key only through it.
- **The view's writer uses a duplicate of the connection's fd.** A
  `Luv.Poll` on the same fd that `Luv.Pipe.read_start` watches gets a
  synchronous error callback, which re-entered the writer. The
  coordinator `dup`s the accepted fd for `Luv.Poll` and `writev`, and
  luv reads the original.
- **The ring header has a `read` index** (protocol.md 14). The plan
  woke an idle coordinator when `tail` equalled the head, but `tail`
  stays behind by the bytes that views may resume, so after the first
  output no `head` frame was sent and every echo waited for the timer
  (p50 1.29 ms in review). The coordinator stores `read` after each
  scan; a `head` frame scans and writes the views at once. The 2 ms
  timer runs only while output continues, and the coordinator reaps
  `ko-pane` from a SIGCHLD watcher, not from the timer.
- **A snapshot is never restarted or downgraded** from full to screen
  because the view's socket blocked. Slices that the socket does not
  take at once are copied into the view's own queue and sent on
  writable, so a snapshot never holds the ring's tail and a stalled
  view never blocks the pane. The copy is bounded by the snapshot's
  size (6 MB for 100k lines in P1.0).
- **A partial `writev` copies the rest of its frame** out of the ring,
  so no pending write references the ring (design.md 4.6).
- **`GET /version` needs no version headers**, because a client reads
  it before it knows the server's version. Every other request without
  `Ko-Protocol` and `Ko-Vt` is refused as a mismatch. A refusal body is
  `{kind: refused, message, protocol, vt}`.
- **Every `Origin` header is refused.** A unix-socket server has no
  origin of its own.
- **`pwd` events carry the terminal's raw value**, which is an OSC 7
  `file://` URI when the shell sends one.
- **Terminal defaults**: scrollback 32 MiB (`--scrollback` takes K, M
  and G suffixes; replaced in P1.3 by `--scrollback-bytes` and
  `--scrollback-lines`, 3.4), APC and continuation limits 65 MiB, kitty image
  storage 10,000,000 bytes, every kitty medium off.
- **The libghostty-vt revision** in `/version` and `Ko-Vt` is the
  `third_party/ghostty` submodule pin, read by a dune rule.
- **SHA-1** for the WebSocket handshake stays the spike's own module
  with the FIPS test vectors, not a new locked package.
- **Terminfo**: a dune rule generates `xterm-ghostty` from Ghostty's
  Zig source, compiles it with `tic` and installs it as
  `share/ko/terminfo/x/xterm-ghostty`. A pane gets `TERMINFO_DIRS`
  with that directory first.
- **Build**: zig from `PATH` (CI installs Zig 0.17.0) builds
  `libghostty-vt.a` in `ReleaseFast`. The libFuzzer targets of
  `ko-pane` build only under `--profile fuzz` (`KO_FUZZ_CC` names the
  compiler), because Apple's clang ships no
  `libclang_rt.fuzzer_osx.a`. Their sanitizer drivers run in
  `dune test`.

### 6.4 What P1.2 settled

The client of P1.2 follows section 5. These points were open or wrong
in the plan:

- **One writer for the screen.** The plan drew the pane with a differ
  "between Mosaic frames". Two writers each kept their own idea of the
  cells, so a sidebar toggle left one region's old cells in the
  other's columns. A custom Matrix backend (`ko_tui/tty.ml`) now keeps
  Mosaic's parser, loop and grid and discards its output;
  `ko_tui/renderer.ml` composes the grid and the mirror into one cell
  array for the differ, and caches the unchanged sidebar cells.
- **Output wakes the loop, input skips the pacing.** The reader
  threads set an atomic flag and wake the loop through the backend's
  self-pipe; `Matrix.request_redraw` from another thread does not wake
  a loop that waits for input. Matrix's 60 fps pacing is off: with it,
  an echo that arrived just after the key's own frame waited for the
  next 16.6 ms slot (review measured p50 21.6 ms).
- **Server: queued WebSocket frames.** httpun-ws can complete frames
  that are already buffered inside `next_read_operation` without
  reading new bytes. `Connection.consume` continued only when it read
  bytes, so the second and later input frames of one socket read waited
  for the next read: a typed line stopped after a few characters until
  the next key. The reader now continues while a frame completes, and
  consumes its buffer by offset. `TestViewInputFramesInOneWrite` and
  `TestViewInputFrameSplitAcrossWrites` cover it.
- **The parse releases the runtime.** `Ko_vt.write` copies the bytes
  out and runs `ghostty_terminal_vt_write` outside the OCaml runtime
  lock, in chunks of at most 16 KiB, within a budget of 4 ms of
  parsing per 8 ms. Holding the runtime starved the main thread during
  a flood (a `sample` of `yes`: the main thread waited for the runtime
  in 1815 of 1860 samples).
- **tmux and the kitty query.** tmux (the pinned fork, `next-3.9`)
  with `extended-keys on` answers XTVERSION and DA1 but not
  `CSI ? u`, so a client inside tmux starts with the warning and the
  sidebar and removes the warning at the first chord (section 5,
  Keys). Accepted by the user on 2026-10-30.
- **Outer mouse reporting stays on** while a pane frame is shown, not
  only while the mirror tracks: the wheel and the sidebar need it.
  Selecting text in the outer terminal therefore needs its override
  modifier (Shift in most terminals), as with tmux's `mouse on`.
  Accepted by the user on 2026-10-30.
- **`TERM_PROGRAM`.** Panes inherited the launcher's `TERM_PROGRAM`.
  ko now sets `TERM_PROGRAM=ko` and `TERM_PROGRAM_VERSION` in every
  pane (section 3.2). `ko version` prints the build id as `build`
  (dune-build-info, `unknown` in an unstamped build). The `-ne` that a
  `/bin/sh` pane printed at each prompt was not from `TERM_PROGRAM`:
  the launcher's environment exported
  `PROMPT_COMMAND=echo -ne "\033]0;$PWD\007"`, and macOS `/bin/sh`
  (bash in POSIX mode) prints `-ne` literally. Panes inherit the
  launcher's environment in P1.
- **Snapshots.** FINISH can arrive before a separate empty last slice,
  so the decoder drains to the last slice. At READY the client shows a
  screen terminal decoded from the bytes so far while the full decode
  continues. After a `skipped` the mirror stays partial; the first
  wheel scroll sends `{resync: {history: all}}` and applies the
  pending scroll when the full snapshot is in.
- **`Ko_vt` exposes typed values** (colour, attributes, cursor shape,
  mouse tracking), and the differ uses Mosaic's `Ansi.Style`.
- **Install.** `ko-pane` installs into `bin` beside `ko`. macOS's
  system ncurses looks up terminfo in hexadecimal directories, so
  `xterm-ghostty` installs as both `x/` and `78/`. The terminfo is
  found only in the installed layout, so the tests and
  `bench/client.py` run `_build/install/default/bin/ko`.
- **Tests.** The client tests run `ko` under an outer kido-tmux on a
  private socket, resolved through the fork's build key as kido's
  e2e does. They poll the outer screen through persistent control
  clients.
- **Shifted keys into a kitty pane.** P1.2 tested a shifted key only
  in a pane at kitty flags 31, where the encoder never takes its
  plain-text path, so it missed that a pane at flags 1 or 3 got `:`
  as `CSI 59;2u` and nvim's normal mode ignored it (protocol.md 8).
  The test now reads the pane's bytes at flags 3, as nvim pushes, and
  at 31.

Measured on an M5 Max, 120x30, private pty (`bench/client.py`): key
to frame in a quiet pane p50 0.94 ms, p99 1.31 ms (200 samples); `yes`
shown for 5 s, client CPU 0.80 core, RSS 25 MiB; with a 100k-line
mirror, RSS 87 MiB, against the 40 MiB target of section 6. The mirror
holds the full history eagerly; P1.3 measured it again with
compression (6.5). The `test_e2e_ko` suite, 33
tests: 5.4 s wall, 4.7 s user and 7.1 s system CPU.

### 6.5 What P1.3 settled

Measured 2026-10-30 on an M5 Max under macOS, load average 3 to 5
(other agents at work), with compression on. Linux is not measured.
`sh bench/table.sh` prints every row; `python3 bench/client.py
latency|busy|yes|attach|resize|memory|scroll` prints one, with
`$KIDO_TMUX` naming the fork that `table.sh` resolves. tmux is the
pinned fork `kido-tmux` on a private socket, kitty 0.49.2. Both sides
run the same producer, pane size (95x30; ko's outer terminal is 120x30
with the sidebar), 100k lines and a warm server.
Memory is RSS and macOS `phys_footprint`.

| metric | target | ko | tmux | kitty | met |
|---|---|---|---|---|---|
| ingest, 1 GiB mixed stream, timed to the last byte parsed | within 10 percent of row 2 (84.2 MB/s); under 1.3 cores | 79.1 MB/s, 1.17 cores (`ko-pane` and ring alone 78.7 MB/s, 0.97 core) | 28.3 MB/s, 1.0 core | 48.8 (defaults), 52.2 (low latency), first run, timed to the producer's exit | yes |
| `kitten __benchmark__` mean | none | 226.9 MB/s | 46.0 | 180.9, 194.0 | – |
| `yes` 5 s, shown | client under 1 core, ring at 1 MiB | client 0.71, `ko-pane` 1.00, coordinator 0.24 core | server 1.00 core | | yes |
| key to frame, quiet pane, p50 / p99 | under 1 / 3 ms added over a raw pty (0.02 / 0.04) | 0.41 / 1.09 ms through the client; 0.09 / 0.17 ms view only | 0.06 / 0.16 ms | | yes |
| attach, 100k lines | screen under 50 ms, history under 500 ms | screen 14 ms, history in the mirror 39 ms (the last slice at 6 ms) | screen 10 ms, then `capture-pane -S -` 58 ms | | yes |
| resize, 100k lines, to READY | under 100 ms | 5.7 ms (p99 6.8) | 14 ms | | yes |
| coordinator, idle, no panes | under 15 MiB | RSS 13.7, footprint 8.5 MiB | | | yes |
| `ko-pane`, idle | under 2 MiB | RSS 2.3, footprint 1.5 MiB | | | yes (footprint) |
| `ko-pane`, 100k lines | none | after 3 s idle RSS 83.6, footprint 4.4 MiB (77.9 before compression) | server RSS 61.2, footprint 60.1 MiB | | – |
| client, 100k-line mirror | under 40 MiB | RSS 102, footprint 18.0 MiB (91.7 without compression) | client RSS 3.5, footprint 2.2 MiB | | yes (footprint) |
| wheel scroll, one notch, to first output | none | p50 0.24 / p99 0.84 ms; 240 notches/s give 240 frames/s at 0.11 core | copy mode 1.25 / 5.3 ms, server 0.27 core | | – |

These points were open or wrong in the plan:

- **Compression** is always on in `ko-pane` and the mirror
  (3.2). One state machine, `ko_pane/compress.h`, serves both: the
  idle period is 250 ms after the last change of the activity token,
  well above the 2 ms coalescing and short enough that memory comes
  back at once. Output that changes no history (a spinner, a progress
  bar on one line) does not change the token and does not delay
  compression. `ko-pane` ticks it when poll times out, after a read or
  a control frame, and while work is pending, one incremental step per
  poll turn, so pty input and control frames are served between steps.
  The mirror runs it on a thread of its own: steps for about 1 ms per
  hold of the mirror lock while work is pending, else it waits on a
  condition that new bytes, scrolling and close signal. Under history
  that changes more often than the idle period, the limit of 3.2 (one
  step every 10 ms after 2 s) compresses anyway: a pane that adds a
  line every 100 ms falls from 13.9 MB to 0.71 MB resident in the
  library's figure, and its footprint after 5 s is 4.7 MiB, the same as
  a quiet pane. Echo under that load is unchanged (`client.py busy`,
  on battery: p50 0.91 / p99 3.33 ms loaded, 1.28 / 3.38 ms quiet).
- **On battery the latency row is about 2.5 times slower for all
  three:** raw pty 0.05 / 0.10 ms, tmux 0.15 / 0.27 ms, ko 0.96 /
  3.14 ms, which is 3.04 ms added at p99, just over the target. The
  table's run had a raw pty at 0.02 / 0.04 ms. 100k lines took 225 steps, the slowest
  0.10 ms; libghostty-vt's resident figure fell from 78.5 to 1.8 MiB
  (200 of 201 pages). Throughput (77.7 against 77.3 MB/s) and echo
  (0.39 against 0.41 ms) are the same with compression off. The
  compressing decode adds about 13 ms to a 100k-line attach.
- **macOS RSS does not show compression.** libghostty-vt frees
  compressed pages to the OS, which takes them back lazily, so RSS stays
  at its peak while `phys_footprint` (Activity Monitor's figure) falls.
  The memory rows are met by footprint and missed by RSS. On macOS the
  memory targets are judged by footprint (decided 2026-10-30).
- **The lazy history and bigarray cells** deferred from P1.2 are not
  needed: with compression the client's 100k-line footprint is 18 MiB,
  and an empty client is 12 MiB.
- **Mosaic draws nothing.** Its render pass took about 600 us of each
  1 ms echo. The client now draws the sidebar and warning into its own
  cells only when the layout changes, and Mosaic's view is empty. Echo
  p50 fell from 1.06 to 0.40 ms, wheel scroll first output from 0.74 to
  0.24 ms and scroll CPU from 0.18 to 0.10 core.
- **Key to frame is 6 times tmux's**, inside the target: 0.08 ms is
  the server path, the rest is the client's frame.
- **Screen visible at attach is 73 ms** on an outer terminal that
  does not answer Matrix's explicit-width (OSC 66) probe, such as
  tmux, because Matrix waits a 50 ms grace period. The 17 ms row is
  for a terminal that answers. Matrix's probe stays (decided
  2026-10-30).
- **The `ko-pane` init frame is version 3** (each scrollback limit has a
  present flag, protocol.md 14). A server older than its
  `ko-pane` fails to start panes and must restart.
- **Benchmark fairness.** Both servers write the 100k-line history at
  the same 95x30 pane size, checked with `stty size`; tmux and kitty
  throughput stop at a DA1 reply after the stream (an ST first, since
  the stream ends inside a string), the ko rows when `ko-pane` has
  parsed the stream; history-loaded is the time an older line shows
  after a wheel event, read from a rebuilt outer screen.
- **Coordinator allocation** is 124 words per ring record (57
  measured with the title and pwd callbacks off, a switch since
  removed), against 6.9 in the P1.0 spike. A record
  is one 1 KiB pty read, so nothing is allocated per byte. A record
  stays one read (decided 2026-10-30).

## 7. Tests

- Inline ppx_expect tests for the pure parts: the ring, offsets,
  resume decisions, record encoding, the sidebar's rows, key
  translation. For `ko-pane`: a C test binary that drives it over a
  stdio and ring with recorded streams and asserts the frames, run under
  the sanitizers.
- Fuzzing (AGENTS.md, "Fuzzing ko"). Four invariants: a mirror fed
  through the view protocol equals the pane's terminal (screen,
  history, modes) under resizes, snapshots, resumes and reconnects;
  each view gets the exact byte sequence, or a snapshot or skip by
  the contract, and no view blocks `ko-pane`; a bad control frame on
  either side fails the pane and reads nothing outside the frame;
  any client input gets a status or a close, and other clients are
  unaffected. `dune test` replays fixed seeds; `make fuzz` runs one
  target for a fixed time.
- A Go e2e suite in `test_e2e_ko/` that starts `ko server` on a
  scratch socket and drives the protocol with `net/http` and a
  WebSocket package over a unix dialer: pane creation and exit, view open with snapshot, resume by
  offset, skip after a stalled reader, resize marker and READY,
  input encoding under bracketed paste and the kitty keyboard flags
  (observed through a pane that runs `cat -v` or a tiny recorder).
  Also: a snapshot taken while a program holds synchronized output
  decodes with mode 2026 off; and a detach and reattach to a pane whose
  program enabled the kitty keyboard protocol keeps that program's
  input working, with no bytes replayed to the pty (zmx's known
  issue).
- The client under an outer tmux pty, as kido's harness does today:
  attach, switch, sidebar toggle, pager round trip, wheel scroll,
  detach, and `ko` starting a server when none runs. The outer tmux
  is test scaffolding only. From zmx's suite: `seq 300`, detach,
  reattach, count the lines; `top` open at reattach, quit, history
  present; a `trap WINCH` counter that shows one signal per real size
  change and none on a same-size reattach; DA1 answered by the server
  while no client is attached; modes 1, 1000, 1002, 1004, 1006, 2004
  and `CSI = 3;1 u` set before the first view opens are in the mirror
  after it opens; and the outer terminal's modes restored exactly
  after detach.
- `make verify` runs all of them, the Go suite as its stage `e2e-ko`
  (`make e2e-ko`, `E2E_KO=TestFoo` to limit it); `bench/` runs on
  demand.

## 8. Order of work and effort

| step | delivers | agent-days |
|---|---|---|
| P1.0 | the four spikes, with numbers | 5 to 7 |
| P1.1 | `ko_pane` with the shared ring, `ko_vt` and `ko_server` with the protocol subset, the Go e2e suite, `ko server` and `ko kill-server` | 9 to 13 |
| P1.2 | `ko_tui` and `ko` attach-or-start, the outer-tmux tests | 6 to 9 |
| P1.3 | `bench/`, profiles, tuning to the targets | 3 to 5 |

Total: 23 to 34 agent-days of implementation, plus review and
verification. Each step is one unit of work under one manager, with
the spike numbers in the P1.0 report deciding the P1.2 drawing path.

## 10. Decisions taken on 2026-10-30

1. A terminal without extended keys (Terminal.app, an outer tmux
   without `extended-keys`) gets no Ctrl+Shift chords and no prefix
   fallback: a warning line, and the sidebar's mouse for switching.
   Closing the window detaches.
2. The shared binding lives in `ko_vt/`.

## 9. What P1 proves, and what it does not

Proves: the binding, the mirror and snapshot design, the view stream
and its backpressure, the HTTP transport on luv, the client as a
mirror, and the performance envelope, all with real shells and real
programs.

Does not prove: Kido.app's restore-from-snapshot surface (design.md
8.2, which runs in the app's repo in parallel), images, remote, the
model and runs. Those are the stages of migration.md, which begin from
the P1 code.
