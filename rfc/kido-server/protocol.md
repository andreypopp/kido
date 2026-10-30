# ko protocol (appendix to design.md)

Status: design, 2026-10-29. HTTP/1.1 over a unix socket, with
WebSocket (RFC 6455) for the long-lived streams. Resource and
field lists are the intent, not a frozen schema. The first
implementation writes the OpenAPI-style schema and the recorded
request and response fixtures that the OCaml server, the Swift client
and the Go e2e client are tested against.

## 1. Transport

The server listens on `<dir>/socket`. Every connection is HTTP/1.1 with
keep-alive. The long-lived streams upgrade to WebSocket: `/client`,
`/feed`, `/panes/pane_N/view` and `/panes/pane_N/search`. Everything
request-shaped stays plain HTTP. A client opens as many connections as
it has concurrent streams: typically one for `/client`, one for
`/feed`, one per open view, a pool for control requests, and one per
image fetch in flight. There is no multiplexing of streams inside one
connection, so a flood on one never delays another.

WebSocket rules: binary messages carry bytes and snapshot slices, text
messages carry JSON. One message is one record; nothing is split
across messages, and a message is at most 1 MiB. Client to server
frames are masked, as the RFC requires; it costs an XOR over input
bytes and buys standard tooling (`websocat --unix`). The server pings
every 30 s on idle streams and closes a connection without a pong
after 10 s more. Close frames carry the error kinds of section 2 as
their reason.

Backpressure is the connection's own: the server writes with
non-blocking writes and never blocks on a client. A stream that cannot
be written is handled per resource (section 4 for views).

Remote: the client asks its SSH ControlMaster for a unix socket
forward, `ssh -O forward -L <local>:<dir>/socket host`, and connects to
`<local>` as if the server were local. Each connection is one
`direct-streamlocal` channel with SSH's per-channel window as the
remote backpressure. These channels are not sessions, so sshd's
`MaxSessions` does not cap the number of views. Nothing on the remote
side differs from local: no `attach-stdio`, no stdio bridge.

Authentication is the socket's mode (0700 directory) and the peer uid
check on accept. Forwarded connections arrive from sshd as the user, so
they pass. There is no token and no TLS.

A request that carries an `Origin` header is refused (409, `refused`).
A unix-socket server has no origin of its own. No native client sends
one; a browser always does. This closes cross-site WebSocket hijacking before any TCP
listener exists.

Encoding: control bodies are JSON. Streams are WebSocket messages
(section 4 for views, section 6 for events). `Content-Encoding:
deflate` is negotiated with `Accept-Encoding` on history and image
responses; the `permessage-deflate` extension is negotiated on
`/client`, `/feed` and `/search`, never on views, because their
latency matters and the bytes compress poorly.

Ids are `session_N`, `window_N`, `pane_N` and `client_N` in paths
and bodies: a lowercase kind, an underscore and a decimal, so a path
needs no encoding and a log line shows the kind. Times are
integer nanoseconds of the server's monotonic clock, plus unix
nanoseconds where a wall time is needed.

## 2. Versions

    GET /version
      {protocol: "1.0", vt: "<libghostty-vt revision>",
       server: {started_at, pid, build},
       terminal: {scrollback_max_bytes, scrollback_max_lines, apc_max_bytes,
                  kitty_image_storage_limit, media: [...],
                  continuation_max_bytes}}

`scrollback_max_lines` is null when the line count is unlimited.

`terminal` is the mirror contract (design.md 4.3): a client applies
these options to every mirror before it opens a view. The shape of
`/version` is frozen across minors, because it is what a client reads
before it knows the server's version.

Every request except `GET /version` carries `Ko-Protocol: 1.0` and
`Ko-Vt: <revision>`; a request without them is refused as a mismatch.
A major mismatch is `426 Upgrade Required`, a `vt` mismatch is
`409 Conflict`, both with the body `{kind: refused, message, protocol,
vt}`. The minor of the server may
be higher: it appends fields and resources and never removes them. The
launcher and Kido.app discovery compare these three values instead of
the server stamp.

Errors are `{kind, message}` with kinds `invalid` (400), `not_found`
(404), `refused` (409), `gone` (410, a closed client), `busy` (503),
`io` (500), `unknown` (502, the
prompt case: the effect may have happened, do not retry).

## 3. Clients

A client is one open WebSocket, one per native window or terminal
client process:

    GET /client   Upgrade: websocket

    client -> server, first message:
      {hello: {kind: app|terminal, name, features: [...],
               session?, window?, pane?, focused,
               size: {cols, rows, cell_w_px, cell_h_px},
               ignore_size?}}
    server -> client:
      {welcome: {client: "client_17"}}, then {topology}, then events
      (section 6)

    client -> server, later:
      {select: {session?, window?, pane?}}      jump
      {switch: "next" | "prev"}
      {size: {cols, rows, cell_w_px, cell_h_px}}
      {focused: true | false}
      {clipboard_answer: ...}                    section 9

The client exists from the hello to the close. There is no
registration request, no linger and no delete: detach is a close, and
a crash, a network loss or a ping timeout (section 1) is a close too.
On close the server deletes the client and closes its views; a view or
request that names a closed client gets `gone` (410). The server keeps
the client's current session, window, size, focus and sizing flag, and
prompt scope uses them. A reconnecting client sends a new hello with
the state it shows and gets a new id; the client owns that state, not
the server. Messages on one client connection are applied in order.

Requests that act as a client send `Ko-Client: client_17`. The CLI uses
no client id for a one-shot read; for a write that needs scope (`prompt`), it passes the
pane it runs in with `Ko-Pane`, as `kido prompt` does with `TMUX_PANE`
today.

## 4. Views: terminal content

    GET /panes/pane_N/view?offset=&history=none|all&images=none|all
      Upgrade: websocket

A view is one WebSocket. Server to client, each message is one record:

    binary  kind u8 (1 bytes, 2 snapshot), offset u64, payload
    text    JSON {offset, marker: {...}} | {offset, skipped: {from, to}}
            | {paste: {id, pasted, unsafe}}

- `bytes`: raw pty bytes. Consecutive records have consecutive offsets.
- `marker`: `{resize: {cols, rows, cell_w_px, cell_h_px}} | {reset}
  | {option: {name, value}} | {dead: {status, signal, at}}`, applied to
  the mirror at that offset.
- `snapshot`: a slice of a libghostty-vt snapshot stream. The first
  slice of a snapshot has flag byte 1 as the first payload byte, the
  last slice flag byte 2, and a `kind` byte after the flag: `full`
  (records to FINISH) or `screen` (records to READY only). The client
  feeds slices to one decoder on a thread whose reader blocks on the
  WebSocket (the decoder pulls and treats a zero-byte read as EOF),
  calls `ready` once READY is in, swaps the surface's terminal to the
  decoded one, and keeps reading until the last slice. Bytes after the
  snapshot's offset apply to the decoded terminal. A new snapshot that
  begins while one is decoding abandons the old decoder. A local client
  may instead receive `{offset, snapshot_file: {path, kind}}` naming a
  server-written 0600 file, which it decodes with a file reader and
  unlinks.
- `skipped`: always followed by a snapshot.

Client to server, each text message is one input event of section 8,
applied in order, or a request:

    {resync: {history: none|all, images: none|all}}   a new snapshot

Input for the shown pane therefore travels on its view with no request
overhead; `POST /input` exists for a pane with no view open.

A view is **full** after a `history=all` snapshot and until a `skipped`;
otherwise **partial**. A full mirror holds the server's history and
applies resize markers itself. A partial mirror gets a `screen` snapshot
after every resize, because reflow depends on the history each side
holds. There is no history paging: a partial mirror that wants history
sends `resync {history: all}` and swaps terminals.

Opening: without `offset`, or with an `offset` outside the pane's ring,
the view begins with a snapshot of the requested kinds (`history`
default `none`, `images` default `none`: placements and metadata are in
the records either way, `images=all` adds the pixel payload records).
With an `offset` inside the ring, and either a full mirror or no resize
marker in the range, the view begins with the bytes and markers since
that offset and no snapshot. This is the reconnect path and costs
nothing.

Backpressure: when a view's write would block, the server stops writing
it and counts. When the connection drains, if the unsent bytes are below
`resume_threshold` (64 KiB) it writes them and their markers from the
ring, under the same resize rule as opening; otherwise it writes
`skipped` and a `screen` snapshot at the current offset. The ring is
1 MiB per pane and stores markers at their offsets. The server
coalesces a pane's output into one record per 2 ms while output
continues. The client sets `SO_RCVBUF` and the server `SO_SNDBUF` to
1 MiB on a view connection; on macOS the sender's buffer is the one
that counts (measured in P1.0). The record's `offset` is
little-endian, as everywhere in this protocol.

    GET /panes/pane_N/screen?format=plain|ansi&history=<rows>
      text from the server's formatter, for the CLI's `runs` screen
      capture and tests

## 5. Images

Placements and image metadata live inside the mirror. Pixels are
resources:

    GET /panes/pane_N/images/<image_id>?generation=<g>
      200  Content-Type: image/x-ko-pixels; headers Ko-Format,
           Ko-Width, Ko-Height, Ko-Generation; body: the pixels,
           deflate-negotiable
      200  Content-Type: application/json {shm: "<name>", offset, length,
           format, width, height}   when the client sent
           Ko-Accept-Shm: 1 and the server is local
      404  the image was evicted or the generation moved on

A client requests the images that have placements on screen, one
connection each, in parallel, and caches by `(pane, image_id,
generation)`. A placement that appears live names an image the mirror
already stores if the program sent pixels inline; the client fetches
only when its store lacks the pixels (`t=s`, a snapshot with
`images=meta`, or a remote client).

Shared memory on the local server: a `t=s` upload is mapped by the
server and copied once into a server-owned object `/ko-<pid>-<n>`
(under 31 bytes, the macOS limit) with
mode 0600. The response names it; the client maps it and unlinks
nothing. The server unlinks it on eviction, records every live name in
`<dir>/shm` and unlinks the names it finds there at start, because
macOS cannot enumerate POSIX shared-memory objects and a crash would
leak them until reboot. This removes descriptor passing entirely; there
is no second socket.

Animation frames and playback state are part of the mirror's own kitty
state, delivered inside the view stream as the program sends them or
in the snapshot. Frame pixels are images with their own ids.

## 6. Events

Events arrive on the client connection (section 3), one text message
per event:

    {topology: {...}}                      the full tree, on every change
    {pane: "pane_N", title: "..."}
    {pane, pwd}
    {pane, prompt: {step: prompt_start|input_start|output_start|command_end,
                    exit?, command?, at}}
    {pane, records: {serial, records: [...]}}     OSC 7501
    {pane, dead: {status, signal, at}}
    {pane, bell} | {pane, notify: {title, body}} | {pane, progress: {...}}
    {pane, clipboard_write: {selector, mime, data_base64}}
    {pane, clipboard_read: {request, selector, mimes, kind}}
    {client: {session, window, size}}      this client's state changed
                                           (another connection moved it)

The first message after `welcome` is a full `topology`. There is no
event replay; a client that reconnects reads the current state and
reopens its views.

    GET /feed     Upgrade: websocket; one text message per typed model
                  snapshot of share/rpc/contract.md, with nanosecond
                  times and server-wide serials; the first at once

`/feed` is separate from `/client` so that the app's sidebar and the
CLI's `kido rpc` replacement read one thing, and an event flood in a
busy pane does not sit between two model snapshots.

## 7. Topology

    GET  /topology                      {sessions: [...], clients: [...]}
    POST /sessions {name?, cwd?, env?}  -> {session, window, pane}
    PATCH /sessions/session_N {name?, rank?: {relative_to, before|after}}
    DELETE /sessions/session_N
    POST /sessions/session_N/windows {after, cwd?, command?, env?, detached?,
                               run?: {id, name, parent?, output}}
                                        -> {window, pane}
    PATCH /windows/window_N {name?, session?: {to, after}, after?, zoom?}
    DELETE /windows/window_N
    POST /panes/pane_N/split {dir, before?, size?, cwd?, command?, env?}
    POST /windows/window_N/floats {x, y, cols, rows, cwd?, command?, env?,
                             border?, title?}
    PATCH /panes/pane_N {move?: {target, dir} | {swap} | {float: {x, y}},
                     size?: {cols, rows}, place?: {x, y, z},
                     agent?: {session, name, inbox, activity},
                     ssh?: {dest, args}}
    POST /panes/pane_N/respawn {command, env?}
    DELETE /panes/pane_N
    POST /clients/client_17/select {session?, window?, pane?}
                  for another process that moves a connected client;
                  the client itself sends `select` on its connection

Shapes of `session`, `window`, `layout`, `float`, `pane` and
`client_info` are design.md's, as JSON. Validation rules are the RPC
contract's where one exists today.

## 8. Input

An input event is a JSON object, sent as a text message on the pane's
view WebSocket, or as the body of `POST /panes/pane_N/input` when the
sender has no view open (the CLI's prompt delivery):

      {key: {action, key, mods, unshifted_codepoint, text, composing}}
      {text: "<bytes base64>"}
      {paste: {text, check_safe, id?}}
      {mouse: {action, button, col, row, mods}}
      {focus: true|false}

`key` and `mods` are libghostty-vt's values, which the app's surface
produces. `unshifted_codepoint` is required (0 when the key has none):
libghostty-vt's encoder finds the kitty keyboard code of a printable
key only through it, and without it `Ctrl+A` encodes as plain `a`
instead of `CSI 97;5u` (P1.1, `src/input/key_encode.zig`). The server
does not guess it from a keyboard layout. The server encodes with the pane's current modes and writes
the pty. Events from one connection are applied in order. A `paste`
with an `id` gets a text message back on the view, `{paste: {id,
pasted, unsafe}}`; the `POST` form gets it as the response body.

## 9. Clipboard

The server sends `clipboard_read` on `/client` to one client
(design.md 4.8) and waits 8 s. The client answers on the same
WebSocket:

    {clipboard_answer: {request, data: [{mime, base64}]}}
    {clipboard_answer: {request, refused: true}}

## 10. Runs

    POST /runs {name, cwd, session, env, command, parent?}
                            -> {id, window, pane, output}
    GET  /runs?all=&parent= -> [run_row]
    GET  /runs/<id>         -> run_row + screen (with ?screen=1)
    POST /runs/<id>/outcome {result, text}   -> {recorded}
    GET  /runs/<id>/wait    a long poll: the response body arrives when
                            the run ends
    POST /runs/<id>/stop {wait_s, result}    -> {result}

The CLI maps error kinds to its exit codes as today (2, 3, 4, 5).

## 11. Search and prompting

    GET /panes/pane_N/search?needle=&max=
      Upgrade: websocket; text messages {matches: [{row, col, len, text}]}
      then {done}; closing cancels. `row` counts from the top of the
      history at the time of the search, for display only; a client
      jumps to a match by taking a full snapshot and searching its
      mirror, since server rows move with output.
    GET  /prompt/resolve?pane=pane_N        -> candidates, as the RPC contract
    POST /prompt {pane, target, text}   -> {via: inbox|paste}

## 12. Flow of an app window

    GET /client  hello {window, size, focused}     the client, a WebSocket
    GET /feed                                      a WebSocket
    for each visible pane:
        GET /panes/pane_N/view?history=all&images=none   WebSocket
        GET /panes/pane_N/images/<id>  for each placement on screen, parallel
    input events as text messages on the focused pane's view
    on window switch: close the old views, open the new ones
    on window switch or resize: {select} or {size} on /client
    on reconnect: a new /client hello, reopen /feed, reopen views with
                  ?offset=<last seen>; bytes and markers resume if
                  inside the ring, else a snapshot

## 13. Versioning rules

- MAJOR: a field removed or changed in meaning, a resource removed, a
  record format change.
- MINOR: a field appended, a new resource, a new event or marker kind,
  a new feature string.
- `vt`: the libghostty-vt revision; any change is a refusal. kido and
  Kido.app bump it together.

Recorded fixtures under `rfc/kido-server/fixtures/` (later
`share/protocol/`) hold request and response pairs and view message
sequences. Each implementation replays them.

## 14. The pane protocol: coordinator to `ko-pane`

One anonymous shared mapping and one control socket per pane, both
created by the coordinator before it forks `ko-pane`. The control
socket is `ko-pane`'s stdin and stdout: one end of a `socketpair`,
dup'd onto fd 0 and fd 1, because a pipe cannot carry a descriptor
and the per-pane upgrade passes the pty master with `SCM_RIGHTS`.
stderr goes to the coordinator's log. The mapping is fd 3. The mapping is a ring of
records, written only by `ko-pane` and read only by the coordinator:

    ring header   u64 capacity; u64 head (written by ko-pane);
                  u64 tail (written by the coordinator: the oldest
                  record a view may still need); u64 read (written by
                  the coordinator: the end of what it has scanned);
                  sequentially consistent atomics, because each side
                  stores its own index and then loads the other's to
                  decide on a wakeup
    record        kind u8 (bytes 1 | marker 2 | snapshot 3 | pad 4),
                  len u32, offset u64, payload; a record never wraps:
                  a `pad` record fills the end of the ring instead
    marker        u8 1 (resize) and cols, rows, cell_w_px, cell_h_px u16;
                  or u8 2 (dead) and status i32, signal i32, at u64
                  (monotonic ns)
    snapshot      flag u8 (1 first, 2 last, 0 between), kind u8 (0 full,
                  1 screen), then the encoder's bytes

`ko-pane` reads the pty straight into the free space at `head`, parses
it in place, then publishes the record. It blocks when `head - tail`
would exceed the capacity, with no deadline. The coordinator writes
views from the mapping with non-blocking `writev` and never leaves a
pending write that references the ring; it moves `tail` past regions
that no view can resume from or still has to send, snapshot slices
included. A `head` frame goes only to an idle coordinator (`read`
equal to the head before the commit), which scans and writes the views
at once; while output continues, the coordinator scans on its 2 ms
timer. `tail` cannot mark idleness, because it stays behind the head
by the bytes that views may resume (P1.1). A blocked
`ko-pane` sends `full {tail}` and the coordinator answers with a
`tail` frame once the tail moved past it. Otherwise both sides read
and store the indices in the mapping. Snapshot slices and markers are ring records, so one
offset order covers everything.

The control socket carries control frames in both directions:

    len   u32   length of what follows
    kind  u8
    body

Little-endian. Strings are `u32 len, bytes`. The `kind` numbers are in
`ko_pane/protocol.h`. The first frame from the
coordinator is `init`; `ko-pane` answers `ready` or exits with status 2
and a message on stderr, which the coordinator logs.

Coordinator to `ko-pane`:

    init      {version u16 (2); cols, rows, cell_w_px, cell_h_px u16;
               options: scrollback_max_bytes u64,
               scrollback_max_lines u64 (0 for unlimited), apc_max_bytes u64,
               kitty_image_storage_limit u64, media u8 bits,
               continuation_max_bytes u64; cwd, argv[], env[] strings;
               pane_id string}
    tail      {offset u64}                       acknowledgement
    resize    {cols, rows, cell_w_px, cell_h_px}
    key       {action u8, key u16, mods u16, unshifted_codepoint u32,
               text string, composing u8}
    text      {bytes}
    paste     {id u32, text, check_safe u8}
    mouse     {action, button u8, col, row u16, mods u16}
    focus     {focused u8}
    snapshot  {req u32, kind u8 full|screen, images u8 none|all,
               to_file string (empty: into the ring)}
    screen    {req, format u8 plain|ansi, history u32}
    search    {req, needle string, max u32}; search_cancel {req}
    clipboard_answer {req, refused u8, mimes[] {mime, bytes}}
    option    {name string, value string}        a terminal option change
    signal    {signo u8}                         to the program
    master    {}  -> ko-pane sends its pty master fd with SCM_RIGHTS
                     (used only by the per-pane upgrade)
    exit      {}

`ko-pane` to coordinator:

    ready     {pid u32 of the program}
    head      {offset u64}                       records published, to an idle coordinator
    full      {tail u64}                         ring full; wake me when tail moves past this
    title     {string}; pwd {string}
    prompt    {step u8, has_exit u8, exit i32, command string}
    record    {serial u32, record bytes}          OSC 7501, parsed shape
    bell      {}; notify {title, body}; progress {state u8, value u8}
    clipboard_write {selector u8, mime, bytes}
    clipboard_read  {req u32, selector u8, kind u8, mimes[]}
    dead      {status i32, signal i32}
    snapshot_done {req}        the slices are in the ring, in order
    snapshot_file {req, path}
    screen    {req, last u8, text}
    search    {req, done u8, matches[] {row u32, col, len u16, text}}
    paste_done {id, pasted u8, unsafe u8}
    error     {message}                           a failure that ko-pane survives

Rules: `bytes` offsets are consecutive from zero; a `resize` is applied
by `ko-pane` between two `bytes` records and written as a `marker`
record at that offset, so the coordinator never infers a position. Input frames are
applied in arrival order and written to the pty at once, queued on
`EAGAIN`, never dropped. `ko-pane` reaps its program on `SIGCHLD`,
sends `dead`, keeps the terminal and the pty master, and answers
`snapshot` and `screen` for a dead pane. On EOF or an error on stdin
it sends `SIGHUP` to the program, waits 500 ms, sends `SIGKILL`, and
exits. A `version` the coordinator does not know is a
refusal at `init`; the coordinator then restarts the pane with a
snapshot as in design.md 4.12.
