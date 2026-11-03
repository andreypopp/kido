# ko protocol (appendix to design.md)

Status: design, 2026-10-29, updated 2026-11-03 (K1, K2, K3 and K6). HTTP/1.1 over a unix
socket, with WebSocket (RFC 6455) for the long-lived streams.

**The code is the source of truth for every message shape** (decided
2026-10-31):

- `ko_server/src/protocol.rs`: the HTTP and WebSocket JSON types and
  their codecs, request and response bodies, events, input events,
  markers, ids.
- `ko_server/src/api.rs`: the routes, their methods, paths, query
  parameters with their defaults, bodies, replies and extra statuses.
- `share/ko/openapi.json`, generated from both by `ko api-schema`:
  the authority for shapes outside the code. Each WebSocket route is
  a `GET` operation with a `101` response and an `x-ko-websocket`
  extension that names its send and receive messages.
- `ko_pane_wire/src/frame.rs`: the frame kinds and their codec between
  the coordinator and `ko-pane`.
- `ko_pane_wire/src/ring.rs`: the ring header and record layout.

This document is the authority for behaviour. It gives only what the
code and the schema cannot say: what each route does, the ordering, flow control, resume, snapshot, reconnect
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
across messages. A message from a client is at most 1 MiB. A message
from the server is at most 32 MiB (`MAX_SENT` in `ko_server/src/ws.rs`,
half of a connection's output queue), because a welcome's or layout
event's pane rows carry every variable of their panes (section 7); a
larger message closes the connection. Client to server
frames are masked, as the RFC requires; it costs an XOR over input
bytes and buys standard tooling (`websocat --unix`). The server pings
every 30 s on idle streams and closes a connection without a pong
after 10 s more. A close frame carries the error kind of section 2 as
its reason. The exception is a view's overflow close (section 4),
with code 1013 and the reason `view queue overflow`.

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
side differs from local: no `attach-stdio`, no stdio bridge. The
client finds `<dir>/socket` through the master with `ko server
--print-socket`, which starts nothing; the remote server starts only
when the user runs `ssh host ko server`. OpenSSH reports a refused
forward and a missing socket with the same message, so the client
asks the remote `ko api /version` through the master to tell them
apart. A host that refuses unix-socket forwarding is unsupported.

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
(404), `refused` (409), `precondition_failed` (412, a conditional
delete whose condition does not hold), `gone` (410, a closed client),
`busy` (503),
`io` (500), `unknown` (502, the prompt case: the effect may have
happened, do not retry). The error type is `Error` in
`ko_server/src/protocol.rs`. A route that takes no body refuses a
request with a non-empty body as `invalid` (400), so a client error
does not pass unseen.

## 3. Clients

`GET /client` upgrades to the client connection, one per native window
or terminal client process. The client's first message is its hello:
kind, name, what it currently shows, focus, size and
whether it takes part in sizing. The server answers with the
`Welcome` event, which carries the client's id and the terminal
limits, then the full layout document with every pane's row (section
7), then events
(section 6). Later the client sends a selection, a relative switch, a size, a
focus change or a clipboard answer, all on this connection.
A size has at least one column and row and at most
`MAX_DIMENSION` (`ko_pane_wire/src/frame.rs`) of each; the server refuses
a hello or a size outside that range. A larger grid is never useful,
and one 65535x65535 grid takes gigabytes.

A size can carry `cell_px`, the pixel size of one cell of the client's
font. The window keeps the last `cell_px` that its sizing client sent;
a size without it keeps the earlier one. Each pane of the window gets
its own cell count times that cell size as the pixel size of its pty
(`TIOCSWINSZ`, each side saturated at 65535), and its terminal answers
`CSI 14t`, `16t` and the in-band size reports (mode 2048) with the same
product, not saturated. A window that never got a `cell_px` has 0
pixels in its ptys, and its terminals do not answer `CSI 14t`, `16t`
or the report when mode 2048 is set; the report that libghostty sends
on a later resize has 0 pixels. A change of only `cell_px` resizes every
pane of the window. Kido.app sends the cell size of a shown pane; the
terminal client sends its outer tty's `TIOCGWINSZ` pixels divided by
its columns and rows, or no `cell_px` when the outer terminal reports
0 pixels.

The client exists from the hello to the close. There is no
registration request, no linger and no delete: detach is a close, and
a crash, a network loss or a ping timeout is a close too. On close the
server deletes the client and closes its views; a view or request that
names a closed client gets `gone`. The server keeps the client's
current session, window, pane, size, focus and sizing flag, and prompt
scope uses them. The current pane is per client and is not in the
layout document. Each window's `focus` in the document is the pane
that a client focused most recently in that window; a client that
enters a window where it has no current pane gets that pane
(section 7). When a `switch` or a removal
moves a client, the client gets a `selected` event. A client gets `selected` for each of its own
`select` requests, also for one that names its current pane, and
for a hello that names only a session or a window, because the
server chose the pane; a hello that names the pane gets none.

A client's selection names a session, a window or a pane; a pane
implies its window and session, a window implies its session, and a
session implies the client's last current window in it, else its
first window. A relative switch moves over windows or sessions in
document order, next or previous, and wraps. A client selects only
over its own connection: there is no route that moves another client
(decided 2026-11-03).

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

A snapshot record's body is compressed; a `bytes` record's is not.
The slice header stays raw, and the libghostty-vt bytes after it are
one raw deflate stream (RFC 1951) for each slice. `ko_server::ws`
owns the codec and its limits. There is no negotiation and no
uncompressed form: every client inflates, and a slice that does not
inflate within the limit is a bad record. Rationale: OpenSSH's
channel window counts uncompressed bytes and limits a remote
restore, so `ssh -C` gains nothing and only compression inside ko
helps. Live output stays raw because it is small and latency-bound.
The cost is the coordinator's CPU on a local restore
(plans/ko-stages.md K7 has the measurements).

A snapshot can cut a sequence open: an APC, a kitty image or an OSC
that the pane's terminal held when the snapshot began. The decoded
terminal completes it from the bytes after the snapshot's offset.
`welcome.limits.terminal.continuation_max_bytes` is the server's
limit for such a sequence, the value that the terminals of its panes
use. A client gives this value, unchanged, to the decoder of every
snapshot that it restores. A smaller local limit drops a sequence
that the server kept: a fixed 1 MiB failed on an APC of 1.5 MB (K5,
spike 2). A reconnect takes the value from its new `Welcome`.

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

A snapshot does not wait for its reader. The pane writes it through
the ring at the pane's speed, and the server takes every slice at
once, so a slow link cannot hold the ring or the pane's program. A
view's slices go to its connection's queue in memory, up to the
queue cap. Past the cap, the rest of the view's output goes to its
spill file, an unlinked file in the server state directory, which
the connection drains after the queue as the socket drains. The order
on the wire stays the order of the messages, and live bytes go only
after the spill is drained, under the backpressure rule above: the
view resumes from the ring, or it gets a skip and a `screen`
snapshot. So a snapshot reaches a slow reader whole, and the memory
of each view stays at the cap. Only views spill; the other links
close at the cap. `ko_server/src/config.rs` holds the cap and the
spill limit of each view. When the spill limit is exceeded, or a
spill write or read fails, the server discards the unsent messages
after the one that the socket has in part and closes the view with
close code 1013 (try again later) and the reason `view queue
overflow`. The client treats it as any other view close: a new view
gets a new snapshot. A connection whose output waits and makes no
progress closes, whether a pong or the close frame waits: the ping
timer finds the stall, and the close comes 10 s later. While the
output drains, the pong deadline restarts, because a ping waits
behind the queued messages. Rationale: a close without a frame gave
the client no reason, and a cap without a spill closed every
snapshot that was larger than the cap, again after each reconnect
(plans/ko-stages.md K7).

`GET /panes/pane_N/screen` returns text from the server's formatter
(`format` plain or ansi, `history` rows), for the CLI's `runs` screen
capture and for tests.

## 5. Images

Placements, image metadata, animation frames and the playback state
that `a=a` set live inside the mirror's own kitty state, delivered in
the view stream as the program sends them or in the snapshot. Pixels
are resources, one for each frame:
`GET /panes/pane_N/images/<image_id>/frames/<n>?generation=<g>`
(`ko_server/src/api.rs`, route `Image`). Frame 1 is the image itself;
2 and up are its animation frames, as kitty numbers them. The
generation is the frame's serial that the bytes alone decide (the
fork's counter over graphics commands, plans/ko-stages.md K6), so the
pane and every mirror compute the same value for the same frame
state, and one number keys the server's object and the mirror's
attach. Serial 0 is a frame with no identity, and no fetch completes
it. An image that was evicted, a frame that does not exist and a
generation that moved on are all `not_found`.

Without `Ko-Accept-Shm: 1` the reply is the pixels as an
`application/octet-stream` body, with the format, size, generation,
frame gap and frame count in `ko-image-*` headers. With it, the reply
is a JSON body that names a shared memory object and gives the same
facts with its length (`ko_server/src/protocol.rs`). The
client maps the object read-only and never unlinks it. A body comes
from the coordinator's own read-only mapping of the object through a
pull source on the connection (`Phase::Streaming` in
`ko_server/src/conn.rs`): the connection writes it in pieces as the
socket drains, so a body larger than the queue cap never sits in
memory and the connection serves its next request after it. A fetch
that waits for `ko-pane` is a stored waiter with the connection's
deadline of 10 s, never a thread (section 14's `image` frame).

A client fetches the frames that its mirror holds pending, for the
placements on screen, one connection each, in parallel, and caches by
`(pane, image_id, frame, generation)`. A mirror that received the
pixels inline (`t=d` in the live bytes) fetches nothing.
`images=all`, a snapshot that keeps the payload records for a mirror
that wants them inline, is still refused.

Pixels come from `ko-pane` through shared memory objects, never
through the ring: an image can be larger than the 1 MiB ring, every
client that attaches reads the same pixels again, and a local client
maps the object directly. On a fetch the coordinator mints a name
`/ko-<pid>-<n>` (under 31 bytes, the macOS limit; `<pid>` is the
coordinator's), appends it to the leak record, and only then sends an
`image` frame with the image, frame, generation and that name, so a
crash at any step leaves no object that the record does not name. A
failed record write fails the fetch before any object exists.
`ko-pane` copies that frame's pixels once out of its terminal's
storage (either screen, the active one first) into a POSIX object of
that name with mode 0600, or answers with the object it already made
for that key, and replies with the name and the frame's metadata,
which it reads from the terminal for each reply, or not found. When
the reply names an older object, or is not found, the coordinator
releases the minted line. A reply that comes after the fetch's
deadline is still handled, so its object stays in the record.
`ko-pane` owns the objects' lifetime: after a write that changed the
kitty storage or the active screen, it unlinks every object whose
frame no longer has pixels at that generation (an eviction, an edit
that moved the serial, an `a=d` that removed the frame) and sends
`image_gone` with its name; it unlinks all of them when it exits.
An object lives as long as its frame does, and the kitty storage limit
does not count it: a frame that a client fetched uses its memory twice
until the frame goes (decided 2026-11-03 for K6; a limit for the
objects is open).

The leak record is the coordinator's, because it is the one process
that outlives a pane: `<dir>/shm` holds one line for each minted
object, with the pane, image, frame, generation and name
(`ko_server/src/shm.rs`). The coordinator removes a line on
`image_gone`, unlinks and removes a pane's lines when the pane is
removed or its `ko-pane` dies, unlinks every line at shutdown, and
unlinks every line it finds at start, because macOS cannot enumerate
POSIX shared memory and a crash would leak the objects until reboot.
The file is the only copy. A new name is one appended line; a
release rewrites the file whole through a rename. There is no descriptor passing and no second socket.

`ko-pane` enables the shared memory medium (`t=s`) for programs, and
`KO_KITTY_IMAGES_MAX_BYTES` sets its image storage limit. The
snapshot decoder of a mirror takes the same limit
(`Terminal::decode_limited`), because libghostty-vt's default limit
drops a larger image from a restored snapshot.

## 6. Events

Events arrive on the client connection, one text message per event,
in the order the server produced them. The kinds, as `Protocol`'s
client event type defines them: the whole layout document on every
change, with the rows of the panes that the change adds (section 7);
a window's new `focus` when only the focus changed (section 7); a
pane's title, pwd, foreground, status, variable, death, bell,
notification and progress; a pane's clipboard write and clipboard
read (section 9), a run's outcome (section 10), and this client's
own state when a `switch` or a removal moved it. The OSC 133 steps
and the OSC 7501 records reach a client only through `status`.

The first message after the welcome is the full layout with every
pane's row. There is no event replay; a client that reconnects gets
the state again from its new welcome's layout event and reopens its
views.

There is no feed and no tree snapshot (decided 2026-10-30). The server
computes one `status` per pane and announces a change for that pane
only; a client builds its sidebar tree from the layout document and
the pane rows, whose `run` field names a run pane's run. `PaneStatus` in `ko_server/src/protocol.rs` is
the reference for its shape: tagged enums for the pane kind, the
phase and the agent state (plans/ko-stages.md 4.3), with the rules of
kido's `Pane_status` (s1.md 6).

Pane state and pane events:

- A pane's row (`Listing` in `ko_server/src/protocol.rs`) carries
  its title, pwd, foreground process, death, status, variables,
  progress (OSC 9;4) and, for a run's pane, its run. The status is
  absent until the model has run once for the pane; the progress is
  absent after a `remove` report. `GET /panes` lists every row, `GET
  /panes/pane_N` one; both read the same rows as the layout.
- Each row field that can change has its own event of `ClientEvent`
  in `ko_server/src/protocol.rs`, and none moves the revision. A
  report that changes nothing
  sends no event: an unchanged OSC 7501 record, an equal `PUT` of a
  variable, a `DELETE` of an absent name, an unchanged progress.
- Variables always travel with their pane (decided 2026-11-03): the
  welcome's layout event carries every pane's row, and a later
  `layout` event the rows of the panes that its revision adds, so a
  client never reads `/panes` to follow the server. A pane that a
  `layout` event no longer names is removed, and the client drops its
  row. An event for a pane without a row changes nothing.
- The layout event that adds a pane comes before every other event
  of that pane: the server holds a new pane's own events until it has
  sent that layout event.
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

- `GET /layout` returns the document, its revision and every pane's
  row (section 6), the same body as the welcome's layout event. A
  `PUT` and its `409` carry only the document and its revision.
- `PUT /layout` takes the document with the revision the client read.
  The server refuses a broken structure (`invalid`), fills and
  rescales geometry it can repair, starts every pane marked as new,
  and answers with the normalized document and the new revision. A
  stale revision is `409` with the current document; the client
  reapplies its edit and retries.
- Every change of the document bumps the revision and is sent as a
  layout event on every `/client`, whether a client sent it or the
  server made it: a new pane, a `DELETE`, a split, a move, a resize, a
  name, a size from the window's sizing client. The revision increases
  once for each published change: a change and the sizes and focus
  moves that it causes are one revision and one layout event. A
  change of a pane's row (its title, pwd, foreground, status, death,
  variables or run outcome) never moves the revision, so it never
  makes a concurrent `PUT` stale (decided 2026-11-03); it travels in
  its own event (section 6). A pane whose program exits stays in the
  document, so its death is a row change.
- A `PUT` must keep every live pane: a document that omits one is
  `invalid`. A new session or window has no `id`; the server allocates
  it. A new pane is a leaf or float whose `pane` is `{new: {cwd?,
  command?, env?, vars?}}`; its `vars` have the limits of the pane
  variables below, and a refused one is `invalid` with the document
  unchanged. A pane without `command` runs `ko shell`. Every pane gets
  `SSH_AUTH_SOCK=<dir>/agent.sock` unless its `env` names that
  variable; a client publishes an agent by an atomic replacement of
  that path with a symlink, and the server links it to its own
  inherited agent at start only when the path is absent or a link to
  no socket file (plans/ko-stages.md, K7). If the `ko-pane` process of one cannot start,
  the server stops the others that started and keeps the old
  document, but not its id counters, so an id is never handed out
  twice. A program that fails later, an exec failure included, is a
  pane death as any other. A window grows to
  give each pane at least one cell. The variable limits below apply
  to session and window `vars` too.
- `DELETE /panes/pane_N` removes the pane from its window; an empty
  window or session goes with it. `DELETE /windows/window_N` and
  `DELETE /sessions/session_N` remove a window or a session with all
  its panes as one change: one revision and one layout event, which
  also carries the new sizes that the moved clients' claims give, so a
  `PUT` made from the document before it gets `409` and a pane that
  it creates cannot survive in a half-closed window. A session goes
  with its last window. A `PUT` has no remove list (decided
  2026-11-02). A pane whose `ko-pane` process ends
  leaves the document by itself; a pane whose program exits stays,
  dead, until a `DELETE`. There is no `POST /panes`: a pane is
  created inside a `PUT /layout`. The server starts with an empty
  document, and it keeps running with an empty document when the
  last session goes; a client that finds it empty `PUT`s one new
  session with one new pane.
- Each window's `focus` is read-only: the server sets it and a `PUT`
  ignores it. It names the window's last-focused pane (section 3); a
  new window starts with its first leaf, and when that pane leaves
  the window, the focus goes to the window's next pane in document
  order. The focus is outside the revision (decided 2026-11-02): a
  selection by a client whose terminal has focus does not bump the
  revision and cannot make a concurrent `PUT` stale. It sends a
  `focus` event with the window and the pane on every `/client`.
  When the selection also changes the window's size (the client
  becomes its sizing client), the change is a document change: one
  revision and one layout event, which carries the new focus, and no
  `focus` event. A focus that moves because its pane left the window
  goes in the layout event of that change. The `focus` event has no
  replay: a client that reconnects reads it from `GET /layout`.
- A new window without `name` gets a default from its first pane, as
  tmux names a new window: the basename of the first word of the
  pane's `command`, else of the shell that `ko shell` runs. A new
  window whose first pane moves in from another window takes that
  window's name, because the document does not know a pane's program.
  An existing window without `name` keeps its name; a `name` renames
  it. A session has no default name.
- `POST /panes/pane_N/clear_history` clears the pane's scrollback.
  `ko-pane` puts the clear into the ring at its position in the
  stream (plans/ko-stages.md K2), so every mirror, live or resumed,
  stays equal to the pane's terminal.
Session and window variables are the `vars` objects inside the
document. Pane variables are part of the pane's row (section 6), and
they are written under `/panes/pane_N/vars`: `PUT` one name with one
JSON value, `DELETE` one name. There is no read of one variable: a
client reads them with the row. `DELETE /panes/pane_N/vars` with a body of
`names` and an optional `if` (a name and a value) deletes the names
in one step, with one `var_deleted` event for each name that existed.
When the `if` variable is absent or has another value, it changes
nothing and is `precondition_failed`. A harness that ends uses it to
remove its own variables and no other owner's: the pane can have a
new owner before the old one cleans up. A value is any JSON, at most 1 MiB minus 4 KiB
(1,044,480 bytes) of encoded JSON. The limit dates from a 1 MiB limit
on server messages too, which it fitted with its `var` event; it stays
a constant that does not depend on the name (decided 2026-11-02). One pane holds
at most 8 MiB and 1,024 names. All variables of the server, of panes,
sessions and windows together, are at most 16 MiB of encoded JSON
(`SERVER_MAX_TOTAL` in `ko_server/src/vars.rs`), so a welcome with
every pane's row stays under the 32 MiB limit of a server message
(section 1); a write or a `PUT` over it is refused. A name is UTF-8
without control
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

A program's clipboard write goes as a `clipboard_write` event on
`/client` to every client whose focus is in a window that shows the
pane. Each client applies its own consent.

A clipboard read goes as a `clipboard_read` event to one answerer
(`ko_server/src/clipboard.rs`): the client whose focus is on the
pane, else a focused client of a window that shows it, else the
newest client of such a window. A read for a pane that no attended
window shows is refused at once (decided 2026-11-02), with no wait.
Clipboard contents have one limit for the whole path,
`MAX_CLIPBOARD` in `ko_pane_wire/src/frame.rs`, chosen so that the
base64 and JSON of the client's answer stay under the 1 MiB limit of a
client's message (section 1): `ko-pane` drops a larger write, and a
larger answer (its types, its contents and the `available` types
together) is a refusal, so a clipboard payload never closes
`/client`.

A read names the MIME types that the program asked for, in its
order: `text/plain` alone for OSC 52, and the types of the request
for OSC 5522. An OSC 5522 read that asks which types the clipboard
holds has `list` set. The answerer replies with a `clipboard_answer`
request on the same WebSocket, with contents or without them for a
refusal; the answer to a `list` read also names the types that the
clipboard holds in `available`. The server
takes only the first answer, only from that client; it refuses the
read when the answerer disconnects, and when no answer comes within
8 s (`KO_CLIPBOARD_TIMEOUT_MS` shortens it for tests). Each read
waits on its own timer of the loop.

`ko-pane` serves OSC 52 and OSC 5522 reads. It defers the
terminal's reply (`ghostty_clipboard_read_defer` of the Ghostty
fork) and completes it when the coordinator's answer arrives, so a
read never blocks the pane's other output, and the terminal encodes
the reply itself: OSC 52 data with the request's terminator (BEL or
ST), or the OSC 5522 OK, DATA and DONE packets, with only the
requested types, in the request's order. Every refusal (the answerer's,
a pane that no attended window shows, the timer, a disconnect, an
answer over `MAX_CLIPBOARD`) is an empty OSC 52 reply or an OSC 5522
EPERM. A pane keeps at most 16 reads open; it refuses a 17th at once, and a
read whose types are over `MAX_CLIPBOARD`. A read
that is still open when the pane exits is refused. An OSC 5522 read's
password and name are not forwarded: ko makes no paste events, and the
answerer applies its own consent to every read.

The terminal client (`ko_tui/src/clipboard.rs`) forwards a write to
the outer terminal as OSC 52, and answers a read that asks for
`text/plain` with an OSC 52 query to the outer terminal. It refuses a
`list` read and a read of other types at once, because OSC 52 carries
only text; the reply router of `ko_tui/src/input.rs`
gives the outer terminal's reply back as the `clipboard_answer`.
It keeps the pending reads in arrival order, at most 16; a 17th
drops the oldest, which the server's timer then refuses. The outer
terminal's reply names its clipboard and answers the oldest pending
read of that clipboard. A reply with no pending read is ignored, and a
reconnect clears the queue.

## 10. Runs

`ko_server/src/protocol.rs` and `ko_server/src/runs.rs` define the
bodies; `ko_server/src/state/run_ops.rs` holds the routes' logic. The
server keeps each run in `runs/<id>/` of its own state directory, as
kido's `Run` does: `meta.json`, with the run's argv, written once at
the start, `outcome`, the captured `screen` and the `output` path that
the run's command writes. Every writer of a run is on the server's
loop thread: `State` refuses a second outcome, and the `outcome` file
is a plain atomic write (a temporary file renamed over it). kido
and ko never share a state directory; nothing migrates.

A run request that names a caller sends the header `Ko-Pane: pane_N`.
The run and prompt commands of the CLI send it from `$KO_PANE`; `ko
api` sends none.

- `POST /runs` creates the run and its window as one server-made
  `PUT` of the document: a new window at the end of the caller's
  session, or of the session that the body names. No client switches
  to it. The pane's environment gets `KO_RUN_ID` and `KO_RUN_OUTPUT`,
  and its command is the body's argv with no wrapper. The server ties
  the run to its pane when it creates the pane, and nothing changes
  the tie later: no variable names a run. The run's pane enters the
  document in one layout event whose row carries the `run` field. A
  parent (a run id or `pane_N`) that is unknown is `missing`, one that
  has ended is `gone`.
- `GET /runs` lists runs, newest first: `live` (no outcome),
  `present` (the pane still exists and names the run) or `all`, and
  optionally only the children of one parent. Each entry carries the
  run's argv. `GET /runs/<id>` adds the captured screen. A run whose
  pane is gone stays in this history; an active run is one whose pane
  is in the layout.
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

The sweep runs when one of its inputs changes: a pane's death or
removal, a recorded outcome, the focused panes, a pane's pi evidence,
and at the end of a linger grace. It closes a run's pane when the pane is dead for longer than
`KO_LINGER_SECONDS` (the linger grace, in seconds with an optional
fraction), or when the run's parent has
ended (the orphan rule: a run parent by its outcome; a pane parent
when it is gone, dead or shows neither a pi root nor `pi.session`).
It records the run's outcome (the pane's exit, else `died`; `failed`
"its parent ended" for an orphan), captures the screen and removes the
pane. It never closes a run pane that is focused: shown by a client
whose terminal has focus (section 3); it tries again when the focus
changes. The removal of a window's last pane removes the window in
the same change, as a window delete does (section 7). An empty
session ends.

A pane's row carries its run, if it has one (`RunRow` in
`ko_server/src/protocol.rs`): each run has exactly one pane, and a
pane at most one run. The row's `outcome` is the recorded one, else
the one that a dead pane gives. The `run` event on `/client` carries
the run's row (which names its pane) when an outcome is recorded, and
when the run's pane dies with no recorded outcome, with the outcome
that the death gives; it does not move the revision. A run's start has
no `run` event: its layout event carries the row. The same `RunRow`
is a `GET /runs` entry. The CLI maps the error kinds to kido's exit codes: `missing`
or `gone` of a parent to 2, an unknown run to 3, a refused name to 4
(the CLI checks it before the request), `refused` to 5.

## 11. Search and prompting

`GET /panes/pane_N/search?needle=` upgrades to a stream of match
batches for a needle, oldest first, then a done message and a normal
close. `ko-pane` runs `ghostty_search_*` in steps from its loop, so
a search of a long history does not stop the pane's output, and
sends the matches in batches of 512. Each search is keyed by its
request, so several searches of one pane run at once, each with its
own done and cancel. The normal close is queued behind the queued
messages. Closing the socket sends `search_cancel` to `ko-pane`. A match's row counts from the top of
the history at the time of the search, for display only; a client
jumps to a match by taking a full snapshot and searching its mirror,
since server rows move with output.

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
   focus. The welcome's layout event, with every pane's row and run,
   is the tree's input; the later events keep it current.
2. For each visible pane, open a view with `history=all` and
   `images=none`, and fetch the images with placements on screen in
   parallel.
3. Send input events as text messages on the focused pane's view.
4. On a window switch, close the old views and open the new ones, and
   send the selection on `/client`. On a resize, send the size.
5. On a split, close, drag, zoom or rename, edit the last layout
   received and `PUT` it with its revision; on `409` reapply the edit
   to the body and `PUT` again.
6. On reconnect, send a new hello, take the state from the new
   welcome's layout event, and reopen the views with the last offset seen:
   bytes and markers resume if inside the ring, else a snapshot. An
   offset is reused only when the `Welcome`'s instance equals the one
   the client saw before; a new server restarts pane ids at
   `pane_1`, so an old offset would resume on an unrelated pane. A
   mirror has an offset to resume from only after a full snapshot; a
   mirror inside a snapshot, or with a screen-only snapshot, opens
   again without an offset.

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
`signal`, `exit`, `image` (section 5), `search` and `search_cancel`
(section 11) and `clipboard_answer` (section 9). Later stages add
`option` (a terminal option change) and `master` (the pty master over
`SCM_RIGHTS`, for the per-pane upgrade).

Frames `ko-pane` sends: `ready`, `head`, `full`, `title`, `pwd`, `dead`,
`snapshot_done`, `screen`, `paste_done`, `error`, `prompt`, `record`,
`foreground`, `alternate`, `bell`, `notify`, `progress`, the image
reply and `image_gone` (section 5), the search matches and their done
(section 11), and `clipboard_write` and `clipboard_read` (section 9).
A later stage adds `snapshot_file`.

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
