# ko protocol (appendix to design.md)

Status: design, 2026-10-29, updated 2026-11-02 (K1, K2 and K3). HTTP/1.1 over a unix
socket, with WebSocket (RFC 6455) for the long-lived streams.

**The code is the source of truth for every message shape** (decided
2026-10-31):

- `ko_server/src/protocol.rs`: the HTTP and WebSocket JSON types and
  their codecs, request and response bodies, events, input events,
  markers, ids.
- `ko_pane_wire/src/frame.rs`: the frame kinds and their codec between
  the coordinator and `ko-pane`.
- `ko_pane_wire/src/ring.rs`: the ring header and record layout.

This document gives only what the code cannot say: the routes and what
each does, the ordering, flow control, resume, snapshot, reconnect
and security rules, the rationale, and the decisions. It repeats no
field list, JSON example, byte layout or enum table. A message that a
later stage adds is specified in that stage's plan ([s1.md](s1.md),
[migration.md](migration.md) 3) until its code exists, then the code
is the reference. The section numbers below are stable; other
documents cite them.

## 1. Transport and security

The server listens on `<dir>/socket`. Every connection is HTTP/1.1
with keep-alive. The long-lived streams upgrade to WebSocket: the
client connection, a pane's view, a pane's search. Everything
request-shaped stays plain HTTP. A client opens as many connections as
it has concurrent streams: one for `/client`, one per open view, a
pool for control requests, one per image fetch in flight. There is no
multiplexing of streams inside one connection, so a flood on one never
delays another.

WebSocket rules: binary messages carry bytes and snapshot slices, text
messages carry JSON. One message is one record; nothing is split
across messages, and a message is at most 1 MiB. Client to server
frames are masked, as the RFC requires; it costs an XOR over input
bytes and buys standard tooling (`websocat --unix`). The server pings
every 30 s on idle streams and closes a connection without a pong
after 10 s more. A close frame carries the error kind of section 2 as
its reason.

Backpressure is the connection's own: the server writes with
non-blocking writes and never blocks on a client. A stream that cannot
be written is handled per resource (section 4 for views). The server
stops reading a connection while its HTTP or WebSocket runtime cannot
take more bytes, and reads again when the runtime asks for them; the
client's unread bytes wait in the socket.

A request head (the request line, the headers and the empty line) is
at most 16 KiB, the size of the connection's read buffer and Node's
default. This one limit also bounds the URI, the query and the header
count. A longer head gets `431 Request Header Fields Too Large` and
the connection closes. Each request on a keep-alive connection gets
the full limit; bodies and WebSocket frames do not count. A body needs
`Content-Length`: a chunked request gets `411 Length Required` and the
connection closes. Without the limit, httpun keeps every header line
it has parsed until the head ends, so an endless head grows memory.

Remote: the client asks its SSH ControlMaster for a unix socket
forward, `ssh -O forward -L <local>:<dir>/socket host`, and connects to
`<local>` as if the server were local. Each connection is one
`direct-streamlocal` channel with SSH's per-channel window as the
remote backpressure. These channels are not sessions, so sshd's
`MaxSessions` does not cap the number of views. Nothing on the remote
side differs from local: no `attach-stdio`, no stdio bridge.

Authentication is the socket's mode (0700 directory) and the peer uid
check on accept. Forwarded connections arrive from sshd as the user,
so they pass. There is no token and no TLS.

A request that carries an `Origin` header is refused (`refused`). A
unix-socket server has no origin of its own. No native client sends
one; a browser always does. This closes cross-site WebSocket
hijacking before any TCP listener exists.

Encoding: control bodies are JSON. `Content-Encoding: deflate` is
negotiated with `Accept-Encoding` on history and image responses; the
`permessage-deflate` extension is negotiated on `/client` and
`/search`, never on views, because their latency matters and the
bytes compress poorly.

JSON shape: every message is one object. A type with several
kinds is tagged by its `type` field (the error body by `kind`), and
the kind's fields are beside the tag, so a reader dispatches on one
key; a payload that is a value and not a record gets one named
field. A type whose kinds carry no data is a string.

Ids are a lowercase kind, an underscore and a decimal (`pane_N`,
`client_N`), so a path needs no encoding and a log line shows the
kind. Sessions and windows exist only inside the layout document
(section 7); only panes and clients have paths. Times are integer
nanoseconds of the server's monotonic clock, plus unix nanoseconds
where a wall time is needed.

## 2. Versions and errors

`GET /version` is the one request without version headers, because a
client reads it before it knows the server's version. Its shape is
frozen across minors. It carries only the protocol version, the
libghostty-vt revision and the build (decided 2026-10-31). The
terminal limits that form the mirror contract (design.md 4.3) arrive
with the `Welcome` event on `/client`; a client applies them to every
mirror before it opens a view. The `Welcome` event also carries
`instance`, the identity of the server process: 128 random bits from
the OS, made once at server start. Two server starts never share an
instance, and every client of one server gets the same one. The
value is opaque to a client, which only compares it for equality
(section 12). An upgrade in place (K9) will keep it, because the
panes and their offsets survive.

Every other request carries the `Ko-Protocol` and `Ko-Vt` headers; a
request without them is refused as a mismatch. The protocol version
changes only with a release (section 13). A major mismatch is
`426 Upgrade Required`, a `vt` mismatch
is `409 Conflict`, with a `protocol_mismatch` or `vt_mismatch` body
that names the server's values beside `kind` and `message`. Those two
fields have the same place in every major, so a client of any major
reads the refusal. The minor of the
server may be higher: it appends fields and resources and never
removes them. The launcher and Kido.app discovery compare these
values instead of a server stamp.

Times in status values (a status's `since`, a command's start and
end) are nanoseconds of the server's monotonic clock (`Mono`), which
has no meaning on another machine. The `Welcome` event and every
`status` event carry `now`, the server's `Mono` time when it sent the
message. A client keeps the latest `now` with its own local monotonic
time of arrival, and estimates the server's current time from that
pair. Thus it shows an elapsed time without a shared wall clock, and
each `status` event anchors the estimate again, for example after the
client's machine sleeps. A reader of `GET /panes` alone has no
anchor; it compares times with each other only. The decision is the
manager's of K1 (2026-11-02): wall-clock times would depend on the
clocks of two machines agreeing, which remote panes (K7) do not
promise.

Error kinds and their status codes: `invalid` (400), `not_found`
(404), `refused` (409), `gone` (410, a closed client), `busy` (503),
`io` (500), `unknown` (502, the prompt case: the effect may have
happened, do not retry). The error type is `Error` in
`ko_server/src/protocol.rs`.

## 3. Clients

`GET /client` upgrades to the client connection, one per native window
or terminal client process. The client's first message is its hello:
kind, name, what it currently shows, focus, size and
whether it takes part in sizing. The server answers with the
`Welcome` event, which carries the client's id and the terminal
limits, then the full layout document (section 7), then events
(section 6). Later the client sends a selection, a relative switch, a size, a
focus change or a clipboard answer, all on this connection.
A size has at least one column and row and at most
`MAX_DIMENSION` (`ko_pane_wire/src/frame.rs`) of each; the server refuses
a hello or a size outside that range. A larger grid is never useful,
and one 65535x65535 grid takes gigabytes.

The client exists from the hello to the close. There is no
registration request, no linger and no delete: detach is a close, and
a crash, a network loss or a ping timeout is a close too. On close the
server deletes the client and closes its views; a view or request that
names a closed client gets `gone`. The server keeps the client's
current session, window, pane, size, focus and sizing flag, and prompt
scope uses them. The current pane is per client and is not in the
layout document; a client that enters a window where it has no
current pane gets the pane that a client focused most recently in
that window (migration.md 3.2). When a `switch`, another
connection's select or a removal moves a client, the client gets a
`selected` event. A client also gets `selected` when its own hello
or `select` names only a session or a window, because the server
chose the pane; it gets none when it named the pane.

A client's selection names a session, a window or a pane; a pane
implies its window and session, a window implies its session, and a
session implies the client's last current window in it, else its
first window. A relative switch moves over windows or sessions in
document order, next or previous, and wraps. `POST
/clients/client_N/select` takes the same selection for another
client: `not_found` for an unknown client, `invalid` for an empty or
unknown target.

The input focus of a pane is derived, not sent as input: a pane is
focused while at least one client whose `focused` is true has it as
its current pane. On a change the server sends focus in or out to the
pane (CSI I, CSI O under mode 1004), so a pane that two focused
clients show sees no transition when one of them leaves.

The window that a client shows is sized by the client that claims it
(design.md 4.5). A terminal client claims only a window with one leaf
and no floats; a pane in a split keeps its leaf size and the terminal
client clips or pads it. A reconnecting client sends a new hello with the
state it shows and gets a new id; the client owns that state, not the
server. Messages on one client connection are applied in order.

Requests that act as a client send `Ko-Client`. The CLI uses no client
id for a one-shot read; for a write that needs scope (`prompt`), it
passes the pane it runs in with `Ko-Pane`.

## 4. Views: terminal content, resume, backpressure

`GET /panes/pane_N/view` upgrades to a view, with the query parameters
`offset`, `history` (`none` or `all`) and `images` (`none` or `all`).
Server to client, each message is one record: a binary `bytes` or
`snapshot` record with its offset, or a text message with a marker, a
skip or a paste result.

- `bytes` are raw pty bytes. Consecutive records have consecutive
  offsets.
- A marker (a resize, a reset, a terminal option change, the pane's
  death) is applied to the mirror at its offset.
- A snapshot is a slice of a libghostty-vt snapshot stream; the
  first and last slices are flagged, and the snapshot is `full`
  (records to FINISH) or `screen` (records to READY only). The client
  feeds slices to one decoder on a thread whose reader blocks on the
  WebSocket (the decoder pulls and treats a zero-byte read as EOF),
  calls `ready` once READY is in, swaps the surface's terminal to the
  decoded one, and keeps reading until the last slice. Bytes after
  the snapshot's offset apply to the decoded terminal. A new snapshot
  that begins while one is decoding abandons the old decoder. A
  local client may instead receive the path of a server-written 0600
  snapshot file, which it decodes with a file reader and unlinks.
- A skip is always followed by a snapshot.

Client to server, each text message is one input event of section 8,
applied in order, or a resync request for a new snapshot of the given
kinds. Input for the shown pane therefore travels on its view with no
request overhead; `POST /panes/pane_N/input` exists for a pane with no
view open.

A view is **full** after a `history=all` snapshot and until a skip;
otherwise **partial**. A full mirror holds the server's history and
applies resize markers itself. A partial mirror gets a `screen`
snapshot after every resize, because reflow depends on the history
each side holds. There is no history paging: a partial mirror that
wants history resyncs with `history=all` and swaps terminals.

Opening: without `offset`, or with an `offset` outside the pane's
ring, the view begins with a snapshot of the requested kinds
(`history` and `images` default to `none`; placements and metadata are
in the records either way, `images=all` adds the pixel payload
records). With an `offset` inside the ring, and either a full mirror
or no resize marker in the range, the view begins with the bytes and
markers since that offset and no snapshot. This is the reconnect path
and costs nothing.

Backpressure: when a view's write would block, the server stops
writing it and counts. When the connection drains, if the unsent
bytes are below `resume_threshold` (64 KiB) it writes them and their
markers from the ring, under the same resize rule as opening;
otherwise it writes a skip and a `screen` snapshot at the current
offset. The ring is 1 MiB per pane and stores markers at their
offsets. The server coalesces a pane's output into one record per
2 ms while output continues. The client sets `SO_RCVBUF` and the
server `SO_SNDBUF` to 1 MiB on a view connection; on macOS the
sender's buffer is the one that counts (measured in P1.0).

`GET /panes/pane_N/screen` returns text from the server's formatter
(`format` plain or ansi, `history` rows), for the CLI's `runs` screen
capture and for tests.

## 5. Images

Placements and image metadata live inside the mirror. Pixels are
resources: `GET /panes/pane_N/images/<image_id>` with a `generation`
query. The response is the pixels as a body with their format and
size in headers, deflate-negotiable; or, when the client sent
`Ko-Accept-Shm: 1` and the server is local, a JSON body that names a
shared-memory object and the pixels' offset, length, format and size.
An evicted image or a moved generation is `not_found`.

A client requests the images that have placements on screen, one
connection each, in parallel, and caches by `(pane, image_id,
generation)`. A placement that appears live names an image the mirror
already stores if the program sent pixels inline; the client fetches
only when its store lacks the pixels (`t=s`, a snapshot with
`images=none`, or a remote client).

Pixels come from `ko-pane` through per-image shared-memory objects
(decided 2026-10-30), never through the ring: an image can be larger
than the 1 MiB ring, the same pixels are read again by every client
that attaches, and a local client maps the object directly. On a
request the coordinator sends an `image` frame (section 14).
`ko-pane` copies the pixels once out of its terminal's storage into a
POSIX object `/ko-<pid>-<n>` (under 31 bytes, the macOS limit;
`<pid>` is `ko-pane`'s) with mode 0600, or answers from the object it
already made for that id and generation, and replies with the name and
geometry, or not found. `ko-pane` owns the objects' lifetime: it
unlinks one when the image is evicted, when its generation moves on,
and all of them when it exits. A local client that sent
`Ko-Accept-Shm: 1` gets the name; it maps the object and unlinks
nothing. For any other client the coordinator maps the object itself,
streams the pixels as the body, and unmaps.

The leak record stays with the coordinator, because it is the one
process that outlives a pane: it appends every name that `ko-pane`
reports to `<dir>/shm`, removes the entry on `ko-pane`'s `image_gone`
frame or the pane's exit, unlinks a crashed `ko-pane`'s names itself,
and unlinks every name it finds in the file at start, because macOS
cannot enumerate POSIX shared-memory objects and a crash would leak
them until reboot. This removes descriptor passing entirely; there is
no second socket.

Animation frames and playback state are part of the mirror's own
kitty state, delivered inside the view stream as the program sends
them or in the snapshot. In kitty's protocol a frame is a number
inside one image, not an image with its own id: the snapshot numbers
payloads 1 for the image and 2 and up for its frames, and the
pinned libghostty-vt exposes only the current frame's pixels through
its image API and has no call that attaches fetched pixels to a
pending frame. So the pixel resource needs a frame number, and
whether a mirror opened with `images=none` can play an animation from
fetched frames at all depends on the fork; migration.md S6 opens with
that check and fixes the resource's shape and the shm objects'
naming and lifetime (per image, frame and generation) from its
result.

## 6. Events

Events arrive on the client connection, one text message per event,
in the order the server produced them. The kinds, as `Protocol`'s
client event type defines them: the whole layout document on every
change (section 7); a pane's title, pwd, status, variable, death,
bell, notification and progress; later a pane's clipboard write and
clipboard read (K6), a run's start or outcome (section 10), and this client's
own state when another connection moved it (K2). The OSC 133 steps
and the OSC 7501 records reach a client only through `status`.

The first message after the welcome is the full layout. There is no
event replay; a client that reconnects reads `/layout`, `/panes` and
`/runs` and reopens its views.

There is no feed and no tree snapshot (decided 2026-10-30). The server
computes one `status` per pane and announces a change for that pane
only; a client builds its sidebar tree from the layout document, the
panes and the runs. `PaneStatus` in `ko_server/src/protocol.rs` is
the reference for its shape: tagged enums for the pane kind, the
phase and the agent state (plans/ko-stages.md 4.3), with the rules of
kido's `Pane_status` (s1.md 6).

Pane state and pane events:

- A `GET /panes` row carries the pane's foreground process, its
  status, its variables and its progress (OSC 9;4). The status is
  absent until the model has run once for the pane; the progress is
  absent after a `remove` report.
- A `status`, `var`, `var_deleted` or `progress` event announces a
  change of that state. A report that changes nothing sends no event:
  an unchanged OSC 7501 record, an equal `PUT` of a variable, a
  `DELETE` of an absent name, an unchanged progress.
- Only a `GET /panes` row carries a pane's variables. A `layout`
  event carries the document and no pane rows, because one pane can
  hold 8 MiB of variables and a client would get them again on every
  change of the document. A client reads the rows once from `GET
  /panes` after its `Welcome`, and again when a `layout` event names
  a pane set that differs from its rows; then it applies `var` and
  `var_deleted`. The read blocks, and the events that arrive on
  `/client` before its answer stay queued; the client applies them
  over the read's result in their order. Some of them can be older
  than the read, so the client keeps variables without the server's
  limits, and the last event gives the server's value. The client
  drops a row whose pane the layout no longer has, and an event for
  a pane without a row changes nothing.
- `bell` and `notify` (OSC 9 and OSC 777) are events only, with no
  row field and no replay: a client that is not connected when a
  program rings or notifies does not see it (decided 2026-11-02).
  Progress is pane state, so a client that connects late sees it on
  the row (decided 2026-11-02).

## 7. The layout document and pane variables

The layout is one JSON document for the whole server (decided
2026-10-30). migration.md 3 gives its schema and invariants until the
`Layout` module exists; now `ko_server/src/layout.rs` and the
document types of `ko_server/src/protocol.rs` are the reference.

- `GET /layout` returns the document and its revision.
- `PUT /layout` takes the document with the revision the client read.
  The server refuses a broken structure (`invalid`), fills and
  rescales geometry it can repair, starts every pane marked as new,
  and answers with the normalized document and the new revision. A
  stale revision is `409` with the current document; the client
  reapplies its edit and retries.
- Every change bumps the revision and is sent as a layout event on
  every `/client`, whether a client sent it or the server made it: a
  new pane, a `DELETE`, a pane's death, a size from the window's
  sizing client.
- A `PUT` must keep every live pane: a document that omits one is
  `invalid`. A new session or window has no `id`; the server allocates
  it. A new pane is a leaf or float whose `pane` is `{new: {cwd?,
  command?, env?, vars?}}`; its `vars` have the limits of the pane
  variables below, and a refused one is `invalid` with the document
  unchanged. A pane without `command` runs `ko shell`. If the `ko-pane` process of one cannot start,
  the server stops the others that started and keeps the old
  document, but not its id counters, so an id is never handed out
  twice. A program that fails later, an exec failure included, is a
  pane death as any other. A window grows to
  give each pane at least one cell. The variable limits below apply
  to session and window `vars` too.
- `DELETE /panes/pane_N` removes the pane from its window; an empty
  window or session goes with it. A pane whose `ko-pane` process ends
  leaves the document by itself; a pane whose program exits stays,
  dead, until a `DELETE`. There is no `POST /panes`: a pane is
  created inside a `PUT /layout`. The server starts with an empty
  document; a client that finds it empty `PUT`s one new session with
  one new pane.
- `POST /panes/pane_N/clear_history` clears the pane's scrollback.
  Every open view of the pane then gets a full snapshot through the
  same path as a client's resync, so every mirror stays equal to the
  pane's terminal; the snapshot is small because the history is
  empty.
- `POST /clients/client_N/select` moves another connected client; the
  client itself sends its selection on its own connection.

Session and window variables are the `vars` objects inside the
document. Pane variables are resources under `/panes/pane_N/vars`:
`GET` the set or one name, `PUT` one name with one JSON value,
`DELETE` one name. A value is any JSON, at most 1 MiB minus 4 KiB
(1,044,480 bytes) of encoded JSON, so that its `var` event, with a
name of 256 bytes escaped and any pane id, fits in one WebSocket
message of 1 MiB (section 1). The rule "a message is at most 1 MiB"
holds in both directions, and the value limit is a constant that does
not depend on the name (decided 2026-11-02). One pane holds
at most 8 MiB and 1,024 names; a name is UTF-8 without control
characters, at most 256 bytes, percent-decoded from the path. A dead
pane keeps its variables until it is removed. The server stores and announces
variables and reads only the `pi.*` and `ssh.*` names under kido's
trust rules (s1.md 6.1). `ko ssh` sets `ssh.dest` and `ssh.args`
before it execs ssh, and the model believes them only while the
pane's foreground process is `ssh`.

## 8. Input

An input event is one JSON message, as `Protocol.input` defines
it: a key, already-encoded text, a paste or a mouse event. Focus is
not input; the server derives it from the clients (section 3). It is sent as a text message on the pane's view, or as the
body of `POST /panes/pane_N/input` when the sender has no view open
(the CLI's prompt delivery).

Keys and modifiers are libghostty-vt's values, which the app's surface
produces. `unshifted_codepoint` is required (0 when the key has
none): libghostty-vt's encoder finds the kitty keyboard code of a
printable key only through it, and without it `Ctrl+A` encodes as
plain `a` instead of `CSI 97;5u` (P1.1, `src/input/key_encode.zig`).
The server does not guess it from a keyboard layout. The event carries
no consumed modifiers: the server treats Shift as consumed when the
text is one character other than the unshifted codepoint and no Ctrl,
Alt or Super is held. Without that, a pane under kitty flags 1 or 3
(nvim pushes 3) gets `:` as `CSI 59;2u`, which nvim's normal mode does
not map; with it, the pane gets `:`, and Shift+Space stays
`CSI 32;2u`. The encoder treats macOS Option as Alt: the client's
terminal already decided what Option means, so an Alt in the
modifiers is Alt. The server encodes with the pane's current modes and
writes the pty. Events from one connection are applied in order. A
paste with an id is answered after the pty accepted every byte, as a
text message on the view, or as the response body of the `POST` form.

## 9. Clipboard

The server sends a clipboard read request on `/client` to one client
(design.md 4.8) and waits 8 s. The client answers on the same
WebSocket with data or a refusal.

## 10. Runs

`ko_server/src/protocol.rs` and `ko_server/src/runs.rs` define the
bodies; `ko_server/src/state/run_ops.rs` holds the routes' logic. The
server keeps each run in `runs/<id>/` of its own state directory, as
kido's `Run` does: `meta.json` and `command` written once at the
start, `outcome` with first-write-wins (`create_new`), the captured
`screen` and the `output` path that the run's command writes. kido
and ko never share a state directory; nothing migrates.

A run request that names a caller sends the header `Ko-Pane: pane_N`.
The run and prompt commands of the CLI send it from `$KO_PANE`; `ko
api` sends none.

- `POST /runs` creates the run and its window as one server-made
  `PUT` of the document: a new window at the end of the caller's
  session, or of the session that the body names. No client switches
  to it. The pane's environment gets `KO_RUN_ID` and `KO_RUN_OUTPUT`,
  its variable `ko.run` is set at its creation, and its command is
  the body's argv with no wrapper. A parent (a run id or `pane_N`)
  that is unknown is `missing`, one that has ended is `gone`.
- `GET /runs` lists runs, newest first: `live` (no outcome),
  `present` (the pane still exists and names the run) or `all`, and
  optionally only the children of one parent. `GET /runs/<id>` adds
  the captured screen.
- `GET /runs/<id>/wait` is a long poll (plans/ko-stages.md 4.4): the
  server answers at once when the run has ended or the timeout is 0,
  else when the run ends or at the deadline. A waiting connection
  makes no work for the server until one of the two. A timeout, and
  a stop's `wait_ms`, over one hour is `invalid`.
- `POST /runs/<id>/outcome` records an outcome. A second write is
  `refused`. A `failed` outcome of a run whose pane exists first
  captures the pane's screen.
- `POST /runs/<id>/stop` records `stopped` (or `completed`), then
  waits up to its `wait_ms` for the pane to die and removes it. The
  removal hangs up the program (`ko-pane` sends `SIGHUP`, then
  `SIGKILL` 250 ms later); if the removed pane still lives after
  `KO_STOP_ESCALATION_MS`, the coordinator kills it. A run that has
  already ended is `refused`.
- `POST /runs/reap` runs one sweep at once, for tests.

The sweep runs when one of its inputs changes: a pane's death or
removal, a recorded outcome, the focused panes, a pane's `ko.run` or
pi evidence, and at the end of a linger grace. It closes a run's pane when the pane is dead for longer than
`KO_LINGER_SECONDS` (the linger grace, in seconds with an optional
fraction), or when the run's parent has
ended (the orphan rule: a run parent by its outcome; a pane parent
when it is gone, dead or shows neither a pi root nor `pi.session`).
It records the run's outcome (the pane's exit, else `died`; `failed`
"its parent ended" for an orphan), captures the screen and removes the
pane. It never closes a run pane that is focused: shown by a client
whose terminal has focus (section 3); it tries again when the focus
changes. An empty session ends.

The `run` event on `/client` carries a run's row when it starts and
when an outcome is written. A run that ends because its pane dies
gets no `run` event; a client reads that from the pane's `dead`
event. The CLI maps the error kinds to kido's exit codes: `missing`
or `gone` of a parent to 2, an unknown run to 3, a refused name to 4
(the CLI checks it before the request), `refused` to 5.

## 11. Search and prompting

`GET /panes/pane_N/search` upgrades to a stream of matches for a
needle, then a done message; closing cancels. A match's row counts
from the top of the history at the time of the search, for display
only; a client jumps to a match by taking a full snapshot and
searching its mirror, since server rows move with output.

`GET /prompt/resolve` lists the candidate agent panes for the caller
of the `Ko-Pane` header, with kido's scope rule applied in the server:
the candidates of the caller's window, else, when that window has
none, those of the other windows of its session. With `window=true`
it never widens. Run windows and terminal panes are not candidates. `POST /prompt` sends text to one candidate
and reports whether it went over the inbox or as a paste
(`ko_server/src/state/prompt.rs`):

- A pane whose trusted `pi.inbox` names an inbox gets the text over
  that socket (`ko_server/src/msg.rs`, the protocol of
  `share/pi/README.md`), with a 2 s deadline as a stored send in the
  loop. An inbox that cannot be reached is `refused`; a timeout or
  another failure after the connect is `io`. Neither falls back to a
  paste.
- Any other candidate gets one `paste` input and one Enter key through
  its `ko-pane`; the pane's bracketed paste mode decides the wrapping.

`ko prompt` keeps kido's exit codes (0 sent, 1 empty text or an
error, 4 no agent in scope, 5 several); its `--window` sends
`window=true`.

## 12. Flow of an app window

1. Open `/client` with a hello that carries the window, size and
   focus. Read `/layout`, `/panes` and `/runs` once; they are the
   tree's inputs.
2. For each visible pane, open a view with `history=all` and
   `images=none`, and fetch the images with placements on screen in
   parallel.
3. Send input events as text messages on the focused pane's view.
4. On a window switch, close the old views and open the new ones, and
   send the selection on `/client`. On a resize, send the size.
5. On a split, close, drag, zoom or rename, edit the last layout
   received and `PUT` it with its revision; on `409` reapply the edit
   to the body and `PUT` again.
6. On reconnect, send a new hello, read `/layout`, `/panes` and
   `/runs` again, and reopen the views with the last offset seen:
   bytes and markers resume if inside the ring, else a snapshot. An
   offset is reused only when the `Welcome`'s instance equals the one
   the client saw before; a new server restarts pane ids at
   `pane_1`, so an old offset would resume on an unrelated pane.

## 13. Versioning rules

The version changes only with a release. Between releases, a change
of shape changes this document and both clients in the same commit,
and the version stays the same (decided 2026-11-02). The rules below
decide how a release changes the version, from the shapes of the
last release.

- MAJOR: a field removed or changed in meaning or encoding, a
  resource removed, a record format change.
- MINOR: a field appended, a new resource, a new event or marker kind,
  a new feature string.
- `vt`: the libghostty-vt revision; any change is a refusal. kido and
  Kido.app bump it together.

Recorded fixtures under `share/protocol/` will hold request and
response pairs and view message sequences; each implementation
replays them. Until then `ko_e2e/`, whose client side is its own
byte-level code and not ko's, is the only independent check of the
wire.

## 14. The pane protocol: coordinator to `ko-pane`

One anonymous shared mapping and one control socket per pane, both
created by the coordinator before it forks `ko-pane`. The control
socket is `ko-pane`'s stdin and stdout: one end of a `socketpair`,
dup'd onto fd 0 and fd 1, because a pipe cannot carry a descriptor
and the per-pane upgrade passes the pty master with `SCM_RIGHTS`.
stderr goes to the coordinator's log. The mapping is fd 3.

The mapping is a ring of records, written only by `ko-pane` and read
only by the coordinator. Its header, the record kinds and the marker
and snapshot slice layouts are `ko_pane_wire/src/ring.rs` and
`ko_pane_wire/src/frame.rs`. The header's indices are sequentially consistent
atomics, because each side stores its own index and then loads the
other's to decide on a wakeup. A record never wraps: a `pad` record
fills the end of the ring instead.

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
by the bytes that views may resume (P1.1). A blocked `ko-pane` sends
`full` and the coordinator answers with `tail` once the tail moved
past it. Otherwise both sides read and store the indices in the
mapping. Snapshot slices and markers are ring records, so one offset
order covers everything.

The control socket carries length-prefixed frames in both directions;
the kinds and the codec are `ko_pane_wire/src/frame.rs`. The first
frame from the coordinator is `init`; `ko-pane` answers `ready` or
exits with status 2 and a message on stderr, which the coordinator
logs. The `ready` pid is a claim, not a fact: the coordinator
signals no pid that it takes from another process without proof. It
accepts the pid only if the OS reports that the process is a child of
the `ko-pane` that the coordinator spawned and leads its own process
group and session, and it is not 0, 1, the coordinator's pid or its
group. It records the start time of the process. `Pid.Group.verify`
is this check and the only constructor of the group that the
coordinator can signal. A pid that fails
this check fails the pane as an invalid frame. A pid with no process
(the program exited and `ko-pane` reaped it) records no child and is
not an error. A second `ready` is invalid. A `version` the coordinator does not know is a refusal at
`init`; the coordinator then restarts the pane with a snapshot as in
design.md 4.12.

Frames the coordinator sends: `init`, `tail`, `resize`, the input
frames (`key`, `text`, `paste`, `mouse`, `focus`), `snapshot`, `screen`,
`signal`, `exit`. Later stages add `image` (section 5), `search` and
`search_cancel` (section 11), `clipboard_answer` (section 9), `option`
(a terminal option change) and `master` (the pty master over
`SCM_RIGHTS`, for the per-pane upgrade).

Frames `ko-pane` sends: `ready`, `head`, `full`, `title`, `pwd`, `dead`,
`snapshot_done`, `screen`, `paste_done`, `error`, `prompt`, `record`,
`foreground`, `alternate`, `bell`, `notify` and `progress`. Later
stages add `image` and `image_gone` (section 5), `search`,
`clipboard_write`, `clipboard_read` and `snapshot_file`.

The libghostty-vt callbacks of the reports only record; `ko-pane`
sends one frame for each recorded report after the write that carried
it, so a report frame follows the ring record of its bytes. `ko-pane`
forwards OSC 133 `A` (primary prompts only), `C` and `D`; `B` and
the other prompt kinds have no reader and stay in `ko-pane`. The
coordinator keeps the OSC 7501 record set and applies its rules
(s1.md 5); `ko-pane` parses nothing that libghostty-vt has
validated. An OSC 7501 report has no flag for an absent title or
message, so an empty string is absent. RIS needs no frame of its own:
libghostty-vt reports a `clear` of every record and a progress
`remove` before its reset, so `ko-pane` does not register the
`RESET` callback.

Rules: `bytes` offsets are consecutive from zero; a `resize` is
applied by `ko-pane` between two `bytes` records and written as a
marker record at that offset, so the coordinator never infers a
position. Input frames are applied in arrival order and written to
the pty at once, queued on `EAGAIN`, never dropped. `ko-pane` reaps
its program on `SIGCHLD`, sends `dead`, keeps the terminal and the pty
master, and answers `snapshot` and `screen` for a dead pane. On EOF
or an error on stdin it sends `SIGHUP` to the program's group, waits
for the program to exit for at most 250 ms, sends `SIGKILL` to the
group, and exits. `ko-pane` sends `ready` only after
the program has called `setsid` and `exec` (a close-on-exec pipe), and
not if it already exited. It collects the program's status with
`WNOWAIT` and keeps the zombie until its final group kill, so the pid
and group id cannot be reused while `ko-pane` lives; if the program
is already a zombie, it sends `SIGKILL` to the group at once.

The foreground check runs only on events (decided 2026-10-30, s1.md
4): at `ready`, after OSC 133 `A`, `C` and `D`, and on pty output at
most once per 100 ms. The output throttle is leading and trailing:
output after the window has ended checks at once, and output inside
the window arms one deadline at the window's end in `ko-pane`'s loop,
which only new output arms again. Thus a program that prints once and
then waits (an ssh password question) is seen, and an idle pane never
wakes. `A` and the trailing deadline are the top-level session's
decisions within the user's rule, not separate user decisions. There
is no recheck on a timer after `C`. The known limit: a shell sends
`C` before it forks, so the check at `C` usually sees the shell, and
a program that prints nothing shows the shell as the foreground until
its first output or its `D`. This is accepted, because the case that
matters, ssh, prints almost at once (a prompt, a banner, a host key
or password question). `ko-pane` sends a `foreground` frame only when
the pid or the name changed, and an `alternate` frame when the
active screen changed after a write.
