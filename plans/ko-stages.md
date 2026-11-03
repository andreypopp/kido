# ko stages on the Rust base

Status: plan, 2026-11-02. Written against `ko-rust` at 476db906 (the
RW and RV4 merge) and the ko-rust handover report of the same day.
RL (Linux and CI) is done. Decided 2026-11-03: `ko-rust`
is closed, and `kido-app-ko` is the one development branch of ko and
Kido.app until K8. Units work in worktrees under
`~/Workspace/kido-<unit>`. Only the top-level session merges into
`kido-app-ko` and pushes (AGENTS.md, "Working here as a spawned
agent"). This plan replaces the stage
list of `rfc/kido-server/migration.md` section 5 (in
`~/Workspace/kido-rust`), which was written for the OCaml base. Sections 2, 3, 6, 7,
8, 9 and 10 of migration.md stay valid unless this plan says otherwise.

The user's goal: ko is the foundation of Kido.app. Kido.app keeps all
of its functionality. The terminal client stays minimal. This plan
covers the server and its protocol first, and the app's stages as a
dependency chain.

## 1. What the Rust ko has today

From the code at 476db906, not from the RFCs.

| part | state |
|---|---|
| processes | `ko` (CLI: attach, `server`, `api`, `kill-server`, `version`), `ko-pane` (one per pane, Rust), `ko_tui` (one pane at a time, flat sidebar) |
| routes (`protocol::Route`) | `GET /version`, `GET /panes`, `POST /panes`, `DELETE /panes/pane_N`, `POST /panes/pane_N/input`, `GET /panes/pane_N/screen`, `GET /panes/pane_N/view` (WebSocket), `GET /client` (WebSocket) |
| client requests | `hello {kind, name, pane?, focused, size, ignore_size}`, `select {pane}`, `size`, `focused` |
| client events | `welcome {client, limits}`, `topology {panes}`, `title`, `pwd`, `dead` |
| view events | `marked {offset, marker: resize or dead}`, `skipped`, `pasted`; binary `bytes` and `snapshot` records |
| input | `key`, `mouse`, `paste`, `text` (base64), `focus` |
| view options | `history=none/all`, `images=none` only |
| `ko-pane` callbacks | `WRITE_PTY`, `TITLE_CHANGED`, `PWD_CHANGED`; media options; scrollback, APC, kitty storage and continuation limits |
| frames `ko-pane` to coordinator | `ready`, `head`, `title`, `pwd`, `dead`, `snapshot_done`, `paste_done`, `screen`, `error`, `full` |
| frames coordinator to `ko-pane` | `init`, `tail`, `resize`, `text`, `snapshot`, `exit`, `key`, `mouse`, `paste`, `focus`, `screen` |
| pane row | `id, pid, command, cwd, title, dead` |
| sizing | per pane: `Pane.sizer`, `client::claims` (focused client, else first unfocused, never `ignore_size`) |
| proofs | Verus on `ko_pane_wire::ring`, `ko_server::delivery`, `ko_server::view`, `conn::Batch`; loom on the ring handshake |
| tests | `ko_e2e` (28 tests, the test process is the outer terminal), unit and proptest modules, the view harness, 10 fuzz targets, Miri |
| platform | macOS and Linux |
| protocol | serde internal tagging, `kind`-flattened errors |
| crates | `libc`, `httparse`, `tungstenite` (`handshake`), `serde`, `serde_json`, `vte`, `clap`, `vstd` |

Facts that change the earlier plan:

- `tungstenite` 0.30 has no `permessage-deflate` feature, and no crate
  in the set inflates or deflates. Compression on the remote path
  needs a new crate (section 4.6).
- The ghostty pin (`da3eff4c`, the app's fork branch) exposed only
  the current frame's pixels (`GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR`,
  `kitty_graphics.h`). K6's first task settles the frame question of
  migration.md S6: the fork reads frame `n` and attaches pixels to a
  pending frame.
- `ko_vt::cut` already filters `KITTY_IMAGE_PAYLOAD` records out of a
  snapshot (`a_snapshot_drops_kitty_payloads`). `images=all` is the
  missing path, not `images=none`.
- `ko_sys::mapping::mmap` opens shared memory with `shm_open` and
  unlinks at once. A named, kept object for images is a small
  addition inside the one crate that permits `unsafe`.
- The Rust e2e suite is its own outer terminal. The S4 scaffold work
  is done, except the Linux rows, which RL and K4 cover.
- `panes.rs` already forces `KO_SOCKET` and `KO_PANE` into every pane.
  The harness contract of migration.md section 4 needs no server
  change for those.
- The coordinator builds a client event only while a client is
  registered (plan decision 73). The status model must still compute
  for `GET /panes` readers with no client.
- `Phase::Handling` keeps a connection waiting for `ko-pane` with its
  read interest off. A long poll reuses this phase with a timer.

## 2. Gap analysis

For each row of migration.md section 2. "Rust ko today" names what the
code has; "missing" names the work; "stage" names the stage below.

| Kido.app capability | Rust ko today | missing | stage |
|---|---|---|---|
| sessions and windows (list, create, kill, rename, select, switch, events) | flat pane set; `topology` event | the layout document, `GET`/`PUT /layout`, revision and `409`, the `layout` event, per-client current session and window, `select` and `switch` with session and window, `POST /clients/client_N/select` (removed in K2c) | K2 |
| the split tree (split, kill, move, swap, resize, equalize, layout events) | none | `tree` per window with normalization, pane creation inside a `PUT` (`{new}`), `DELETE` that gives cells to the sibling | K2 |
| floats (`new-pane -x/-y`, raise, geometry) | none | `floats` per window with `x, y, cols, rows, z, border, title`, clamped into the window | K2 |
| active pane | `select {pane}` per client | the current session, window and pane per client; the last focused pane per window in the coordinator | K2 |
| window size and cell pixels | per-pane sizer, `size` on `/client` with `cell_px` | the sizing client per window, the tree scaled to the window, pty sizes from leaves | K2 |
| pane content (output, input, pause, resume) | views, snapshots, skips, input events, resume by offset | nothing | done |
| restore and Load more | full and screen snapshots, `/screen` | nothing | done |
| find | none | `GET /panes/pane_N/search` (WebSocket) over `ghostty_search_*` in `ko-pane`, for a partial mirror; the app searches a full mirror itself | K6 |
| `clear-history` | none | a `clear_history` request on the pane (one frame, one route) | K2 |
| images (`-G`, `-K`, `image-shm`, pixel size) | `images=none`; media options in `init`; placements travel in the bytes | `images=all`; `GET /panes/pane_N/images/<id>`, shm by name, `Ko-Accept-Shm`, the leak record, `image`, `image_gone` frames; frame `n` and attach calls in the Ghostty fork, so an `images=none` mirror plays animations from fetched frames | K6 |
| clipboard (OSC 52 write and read) | none; `CLIPBOARD_*` callbacks not set | `clipboard_write` and `clipboard_read` events, `clipboard_answer` on `/client`, one answerer by focus, the 8 s deadline | K6 |
| the feed (status, tree, switch, prompt) | `title`, `pwd`, `dead` events | `status` per pane and its event; OSC 133 and OSC 7501 frames and the record set; the foreground and alternate frames; pane variables and their events; `run` events; `/prompt/resolve`, `POST /prompt` | K1, K3 |
| `#{pane_current_path}` | `cwd` and `pwd` on the row | nothing | done |
| `@kido_ssh_args` and the other pane options | none | pane variables under `/panes/pane_N/vars`, `ko ssh`, `ko shell` | K1 |
| discovery, stamp, kill-server, detach | `/version` with headers, `ko kill-server`, close is detach | the reconnect gate on `instance` | K0 (`instance`), K2 (gate) |
| the pi harness (`set-option -p`, `list-panes -a`) | `KO_PANE` and `KO_SOCKET` in every pane, `ko api` | pane variables (K1); `ko run*`, `ko prompt`, `ko-pi.ts` (K3) | K1, K3 |
| remote hosts over SSH | nothing on the client side; the server is transport-neutral | `ko HOST` (master, `-O forward`), the app's forward, reconnect by offset gated on `instance`, Linux (RL) | K7 |
| SSH agent for remote panes (the app's `agent.sock` publication) | panes inherit the server's environment | nothing in the protocol; every pane gets `<dir>/agent.sock`, which the server links to its inherited agent and the app replaces with its publication | K7 (app) |
| notifications (OSC 9, 777), bell, progress (OSC 9;4) | none | `bell`, `notify`, `progress` frames and events; cheap once K1 adds the callback plumbing | K1 |
| upgrade in place | none | K9 | K9 |

Kido.app features that need no server work beyond the rows above:
tabs (a projection of the document), the command palette, prompt mode
(`POST /prompt`), theme mode, the sidebar seen state (client side),
consent and grants (client side).

## 3. The terminal client: what minimal means

Decided (2026-10-30): one pane at a time, a list grouped by session,
no splits, tabs or windows, no copy mode. The user asks to keep the
client minimal and to grow it only for what the server features need
for testing and basic use. The recommendation, by stage:

| stage | the client gains | why |
|---|---|---|
| K1 | one status column before the title (kido's glyphs and colours) | basic use: a user must see that an agent waits; it is the one visible check of the status model |
| K2 | session header rows; `Ctrl+Shift+Up` and `Down` cross sessions; `Ctrl+Shift+N` adds a window to the shown pane's session; a pane in a split is shown clipped or padded at its size | the grouped list is decision 2; a window per `Ctrl+Shift+N` keeps the key |
| K3 | a subagent's row follows its parent's row, indented one column | the tree is the one visible check of the run rules |
| K6 | OSC 52 writes forwarded to the outer terminal; clipboard reads answered through an OSC 52 query to the outer terminal | a paste from an agent pane is basic use; it also exercises the one-answerer rule |
| K7 | `ko HOST` attaches through an SSH forward | the remote server's one client without Kido.app |

Not added, now or later, unless asked: kitty image drawing or
passthrough in the client (the e2e suite fetches the image resources
directly; the app is the image client), the message and progress text
in rows, find, a new-session key, mouse drag, copy mode, splits. The
client ignores layout geometry. This drops the "kitty passthrough"
part of migration.md S6's terminal client item; it saves about two
agent-days and keeps the client's renderer as it is. Section 7,
question 1, asks the user to confirm this list.

## 4. Decisions revisited on the Rust base

Each earlier decision, what the Rust base changes, and the answer.

### 4.1 The layout document with server normalization

Keep. The document's types are serde derives in `protocol.rs`, so the
schema and its codec exist once. The normalization engine is new code
in either language (`ko_server/src/layout.rs`, about 1,000 lines with
tests). proptest fits it: a generator of trees and edits, with the
invariants as properties (every live pane once, sizes sum to the
window minus dividers, every leaf at least one cell, a `PUT` of the
normalized document is a fixed point). The fixtures stay the app's
recorded tmux layout trees, converted once by a test helper.

One change in the server's state: `Pane.sizer` becomes the window's
sizer. `client::claims` keeps its rule, over the window the client
shows. `Client::Active` gains `session` and `window`. `protocol::decode`
walks one `serde_json::Value` for a body that contains `[`; a `PUT
/layout` always does, which is fine on the control path.

Semantic risks for Kido.app (kido-app-notes/ko-api-gap.md 2.3, recorded
2026-11-02; K5 handles them):

- One `PUT` for each gesture step with a `409` retry: the app writes
  each edit as a function of the current document, as
  `ko_client::layout::edit` does, and keeps one `PUT` in flight with
  one coalesced successor, or a drag loses concurrent server changes.
- The server normalizes geometry: a dock beside a pane fills sizes
  proportionally, not by tmux's join-pane rule, so the app's split
  snapshots move.
- Previous and next window are the client's: the app computes the
  target from its K3 tree (it skips run windows, steps among nested
  siblings, wraps across sessions) and sends `select`; the terminal
  client's `switch` walks the document order. They disagree, which
  is accepted.
- Whole-history mirrors: a restore is one `full` snapshot, about 6 MB
  for 100k lines (4.6), and the app's 32-surface budget now holds
  whole histories; the local memory ceiling is not measured.
- `Ko-Vt` coupling: the server refuses a `vt` difference with `409
  vt_mismatch`, so every Ghostty fork bump in either repo is a
  coordinated app release; the mismatch sheet needs the new headers.
- Times: status times are `Mono` nanoseconds anchored by `now` on
  `welcome` and on each `status` event, a run's start is wall time;
  the app's clocks, seen keys and notification identities use
  `Model.server_now`, and a remote anchor drifts across sleep until
  the next event.
- The sizing claim: the focused client, else the client that last
  switched to the window, holds the size; the app's sidebar-focus and
  palette states must send `focused` correctly, or the claim flips.
- SSH remotes: the remote server is `ko` on Linux (RL), started
  explicitly; the forward replaces the stdio bridge, and until K7 a
  remote window has no ko path.

### 4.2 Pane variables

Keep, with the limits of migration.md 3.3. A value is arbitrary JSON,
so a variable body decodes as `serde_json::Value` and skips the
array-shape check, which exists for records only. The value limit
is 1 MiB minus 4 KiB (1,044,480 bytes) of encoded JSON, below the
1 MiB body cap of `conn.rs`: a value's `var` event must fit in one
WebSocket message of 1 MiB, and 4 KiB covers the envelope with a
256-byte name and any pane id (decided 2026-11-02, after review found
that a 1 MiB value disconnected every client).
The store is a `BTreeMap<String, Value>` per pane with its encoded
size.

### 4.3 Status in `/panes` and `/client` events, no tree

Keep. The model tick is a `Poll` timer (16 ms, armed by a dirty mark,
never periodic), as plan decision 19 requires. The model runs whether
or not a client is registered, because `GET /panes` and `POST /prompt`
read `status` with no client; only the event's JSON is built for a
registered client (decision 73). The `status.kind` JSON takes
the protocol's form: `#[serde(tag = "type")]` enums for the pane kind
and for each status, not kido's `["Terminal", {...}]` arrays that
s1.md 6.4 still shows (the handover flagged s1.md:325). Kido.app
decodes the new form in K5, so nothing depends on the old one.

### 4.4 Runs in the server, and the loop rule for every new endpoint

Keep. `GET /runs/<id>/wait` is a connection in `Phase::Handling` with
its read interest off and one deadline timer, registered in a waiter
list keyed by run id in `State`. The run's end or the timer answers it
through `router::finish`, as `/screen` does. No thread. `State`
refuses a second outcome, and `outcome` is a plain atomic write
(K2c).

The rule, for this endpoint and for every other wait that the stages
add (the prompt's inbox send, the image request, the clipboard
answer's 8 s deadline, the search stream): coordinator state changes
only on the loop thread. A long poll or a deadline is a stored waiter
in `State` plus a `Poll` timer, never a thread. A thread is permitted
only for blocking work that touches no coordinator state; it returns
its result to the loop through the wakeup pipe, and the loop thread
applies the result. A new endpoint that does not fit this rule needs a
recorded decision before it is built.

### 4.5 Images as separate shm resources

Keep, and do animation properly from the start (decided 2026-11-02,
no fallback). The pin confirms the gap: the headers expose the
current frame's pixels only, and nothing attaches fetched pixels to a
pending frame outside the snapshot decoder. ko pins the app's Ghostty
fork, which the user owns, so K6 adds both calls to the fork first
(K6 scope). Then the image resource takes a frame number, a shared
memory object is per image, frame and generation, and an `images=none`
mirror plays an animation from the separate resources. `images=all`
stays for a mirror that wants every pixel in the snapshot. The Rust
specifics: a named kept object is a new constructor in
`ko_sys::mapping`; the coordinator streams a pixel body from its own
mapping through the connection's queue, and a body larger than the
queue cap (64 MiB) needs a pull source that the connection drains in
pieces, a small change in `conn.rs` outside its verified `Batch`.

### 4.6 SSH unix-socket forwarding, no stdio

Keep. `ko HOST` is `ssh -M -N -T` with a private `ControlPath`, then
`ssh -O forward -L <local>:<dir>/socket`, then the local attach path.
Compression: `tungstenite` has no `permessage-deflate`. After K7's
RTT table, the user chose `miniz_oxide` (pure Rust, its one
dependency `adler2`) at level 1 for snapshot slices only (section 7,
question 2; protocol.md section 4).

Linux moves onto the remote path: Kido.app's remote hosts are Linux
servers, so RL is a dependency of K7's acceptance, not an optional
last stage.

### 4.7 The protocol's shapes and versions

The protocol version changes only with a release. Between releases,
a change of shape changes the docs and both clients in the same
commit, and the version stays the same. ko has had no release, so
the version is 1.0 (decided 2026-11-02).

### 4.8 The Verus boundary

New on the Rust base. A change to `ko_pane_wire::ring`,
`ko_server::delivery` or `ko_server::view` needs proof work, and
`make verus` must stay under 120 s. By stage:

- K1, K2, K3: none. New frames, routes, state and the model live in
  `pane_proc.rs`'s event enum, `state.rs`, new modules and
  `protocol.rs`, all unverified. The frame codec's bounds are lints,
  the `frame` and `frames` fuzz targets and Miri, as today.
- K6: `images=all` changes `ko_vt::cut`'s filter in `ko-pane`
  (unverified). The view's option is data that `View::new` carries.
  No proof changes. The pixel body path is in `conn.rs` beside
  `Batch`, not inside it.
- K9: the inherited ring breaks `Backend::mint_reader`'s assumption
  that the reader created a zero-filled mapping. K9 adds one trusted
  constructor that adopts a ring at a recorded tail, with its
  `// Assumes:` line, and nothing else in the proofs changes.

### 4.10 A shared Rust client core, `ko_client`

Decided 2026-11-02 (question 3). Both clients share one Rust crate,
`ko_client`, a workspace member:

- Contents: the transport (HTTP/1.1 and WebSocket over the unix
  socket, and the SSH forward from K7), the protocol types (today
  `ko_server::protocol`, which moves here so the server depends on
  the client crate's types or both on a `ko_protocol` module of this
  crate), the `/client` event stream with reconnect gated on
  `instance`, the client model (the layout document, the panes with
  status and variables, the runs, the subagent tree, and the seen
  record: one `Seen` for each host, observed with the set of shown
  panes and an attendance flag, decided 2026-11-02), and view
  streams that hand bytes, markers and snapshot slices to the caller.
  It contains no terminal: `ko_client` never links `ko_vt` or
  libghostty-vt.
- `ko_tui` keeps its `ko_vt` mirror, renderer, differ, input and tty
  outside `ko_client` (or behind a cargo feature of `ko_tui`, not of
  `ko_client`). `wire.rs`, `api.rs`, the event handling of
  `client.rs` and the model that K1 to K3 would have put into
  `ko_tui` move into `ko_client`.
- Kido.app links it as a static library in an `.xcframework` (arm64
  only) through a hand-written C ABI: a header and a module
  map, no UniFFI and no swift-bridge. The core runs its own I/O
  thread on `ko_sys::event`; callbacks are delivered for the main
  queue; data crosses as small C structs or owned buffers that the
  caller frees through the ABI. One cargo build phase in Xcode on the
  pinned toolchain. The app's own Ghostty fork is the only
  libghostty-vt in the process, so the view feed gives bytes and
  snapshots to the Ghostty surface, and two static copies never meet.
- The core gets the fuzz and proptest coverage once for both clients:
  the `client` fuzz target (the response and upgrade readers) moves
  with `wire.rs`, and the model gains a proptest over recorded event
  sequences (layout, status, var, run) against the tree's invariants.
  The `ko_e2e` client tests keep driving `ko_tui`; the app's tests
  drive the ABI through the `.xcframework`.

The C ABI is the one surface that the Rust rules do not cover today:
`unsafe` is needed for the exported `extern "C"` functions, so
`ko_client::ffi` is a module that permits it, with the same
`// SAFETY:` rule as `ko_sys`, and every pointer that crosses is
owned by one side by construction.

### 4.9 Deletion at the cut-over

New consequence. After K1 and K3, no OCaml of ko's remains, and the
TypeScript suite's fake `kido` (an OCaml executable) becomes a fake
`ko` (K3). At K8, kido's whole OCaml side goes with the tmux fork:
`dune-project`, `dune.lock`, `dune-workspace`, `lib/`, `lib_tmux/`,
`bin/`, the dune parts of the Makefile, `scripts/verify.sh`'s dune
stages and the ocamlformat tooling. The repo becomes the cargo
workspace, `share/` and the TypeScript harness. migration.md S8 kept
`lib/fs.ml`, `timestamp.ml` and `bin_dir.ml`; that no longer applies.

## 5. Stages

Each stage is one unit of work under one manager, with the review
structure of AGENTS.md. Each ends with `make verify-ko` green (`make
verify` when it touches the Makefile, `scripts/` or kido's side) and
an on-screen check by the user. The yardstick is 350 lines of new
code with tests per agent-day, plus 20 percent on logic that ports
from OCaml (the handover's figure). Names in code are ko's names from
the start (`KO_*`, `ko_*`, `share/ko`).

### K0. The `ko_client` crate and `instance` (done)

Added by the top-level session before K1 and K2, so that both start
on the crate. The workspace crate `ko_client` holds the launcher, the
wire layer, the API client and the `/client` event handling that were in
`ko_tui`; `ko_tui` depends on it. The protocol types stay in
`ko_server::protocol` until a later stage moves them (4.10). The
`welcome` event carries `instance`, the server process's identity,
and `ko_client` keeps it beside the client id.

### K1. Status, pane variables, `ko shell`, `ko ssh` (done)

Depends on nothing. Runs beside K2. s1.md is the specification, with
these changes for the Rust base and the shapes of 4.3.

Scope:

- `ko-pane` registers `SEMANTIC_PROMPT`, `PROGRAM_STATUS`, `BELL`,
  `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT` and `RESET`. Callbacks
  only record (plan decision 63); after the write, `ko-pane` sends
  one frame per recorded report. New `FromPane` kinds in
  `ko_pane_wire::frame`: `prompt`, `record`, `foreground`,
  `alternate`, `bell`, `notify`, `progress`. The foreground check runs
  only on events (s1.md 4); on Linux it reads `/proc/<pid>/comm` (RL
  supplies the process layer).
- `ko_server`: `program_status.rs` (the record set: 64 records, the
  unchanged-report rule, the clear rules, `root`, `app`, `forest`),
  `pane_status.rs` and `pane_kind.rs` (ports of `lib/pane_status.ml`
  and `lib/pane_kind.ml` over nanosecond times), `model.rs` (the
  16 ms tick, dirty marks, the 200 ms promotion timer), `vars.rs`
  (the store and limits). `Pane` gains the fields of s1.md 3.
  `protocol.rs`: the row fields `foreground`, `status`, `vars`; the
  events `status`, `var`, `var_deleted`, `bell`, `notify`,
  `progress`; the routes under `/panes/pane_N/vars`.
- A new workspace crate `ko_shell`: `prime.rs`, `shell.rs`, `ssh.rs`,
  `bin_dir.rs`, ports of `lib/prime.ml`, `shell.ml`, `ssh.ml` and
  `bin_dir.ml`, with the shell integrations and shims embedded with
  `include_str!` from `share/ko/`. `ko shell [-- CMD]` and `ko ssh`
  in `ko/src/main.rs` over it. `ko server --bin-dir`. The default pane
  command becomes `ko shell`. (Section 7, question 6.)
- `ko_client` (4.10): the `status`, `var`, `var_deleted`, `bell`,
  `notify` and `progress` events applied to the model's panes, and
  the pane kind and status types. `ko_tui`: the status column and the
  seen rule (s1.md 10), over the model.

Tests that close it (`ko_e2e`, snake case of s1.md 11): the status
event sequences for an agent, the record set rules, child records,
the shell phases under zsh and bash, the heal rule, the alternate
screen, the foreground on events, no idle wakeups with primed panes,
the variable limits and events, the pi variables gate, the ssh mark
and arguments, the host-ssh tests under `KO_E2E_HOST_SSH=1`, the
shims, dotfile isolation, the login command, the sidebar mark column.
The fake agent of kido's Go suite is not needed: a pane that runs
`stty raw -echo; exec cat` echoes the OSC 7501 and OSC 133 bytes that
a test sends as `text` input, and libghostty-vt parses them.

Risk: low. The rules exist and are tested; the port is mechanical.
The one new mechanism is the model tick on the loop.

Built (2026-11-02). The differences from s1.md, with
their decisions:

- The foreground check also runs at OSC 133 `A`, and its output
  throttle is leading plus one trailing deadline (protocol.md 14).
  There is no recheck on a timer after `C`. A silent program shows
  the shell until its first output or `D`: a known limit, accepted
  by the user, because ssh prints at once.
- Status times are `Mono` nanoseconds; `welcome` and every `status`
  event carry the server's `now` (protocol.md 2).
- A `layout` event has no pane rows and so no variables; a client
  reads them from `GET /panes` (protocol.md 6). A variable value is at most
  1,044,480 bytes, so its event fits in one 1 MiB message (4.2).
- The seen rule, the mark choice and the row title rule are in
  `ko_client`, for both clients; `ko_tui` draws the glyphs and
  colours.
- `bell` and `notify` are events only; progress is pane state on the
  row and an event (decided 2026-11-02).
- `ko-pane` forwards only primary `A`, `C` and `D`. A record has no
  `title_set` or `msg_set`, because libghostty-vt's report has no
  such flags: an empty string is absent. `RESET` is not registered,
  because RIS already reports a `clear` and a progress `remove`.
- `ko ssh` sets the mark to the destination as typed, as kido does
  (docs/design-program-status.md, "The ssh mark"). It unsets the mark
  when the arguments do not parse, and runs ssh unchanged and unmarked
  when an argument is not UTF-8.
- The row title: the status title for an agent, an ssh pane and a
  running command with no report; else the OSC 2 title, then the
  status title, then the command's basename.
- `TestForegroundOnEvents` reads `foreground` on `GET /panes`; there
  is no frame counter. The idle test watches 2 s, not 5 s.
- The macOS path_helper case is a `.zprofile` that moves the bin
  directory down PATH, on both platforms.

The coordinator does not build the `forest` of s1.md 5: no server
reader needs it. A client builds it from the published records when
Kido.app needs it (K5, in `ko_client`).

Open after K1: the done criteria of s1.md 12 that are measurements
(a flood of reports from 20 panes against the event count, and the
20 ms status latency through `bench/client.py`), and the host-shell
probes of the ssh bootstrap against an unconfigured zsh and bash,
which the host-ssh e2e tests cover only with `KO_E2E_HOST_SSH=1`.

### K2. The layout document (8 to 11 agent-days, built)

Depends on nothing. Runs beside K1. migration.md section 3 is the
specification.

Scope:

- `ko_server/src/layout.rs`: the document, validation, normalization
  (ports of tmux `layout.c`'s arithmetic as a pure function), the
  revision, `PUT` with `409`, pane creation inside a `PUT`, removal
  with cell inheritance, scaling on the sizing client's `size`,
  session and window `vars`. `protocol.rs`: the document types,
  `GET`/`PUT /layout`, the `layout` event, `hello {session?, window?,
  pane?}`, `select`, `switch`, `POST /clients/client_N/select` (removed
  in K2c),
  the `clear_history` request. `POST /panes` and `topology` go.
- Sizing per window: `Pane.sizer` moves to the window; a leaf's pty
  size follows its cell geometry; a window with no sizing client keeps
  its last size, 80x24 at creation.
- `ko_client`: the document types, the `layout` event applied to the
  model, the read-edit-`PUT`-retry loop as one call, the reconnect
  gate on `instance`, the per-client current session and window.
  `ko_tui`: the grouped list (section 3), `Ctrl+Shift+N` adds a
  window to the shown pane's session, `Ctrl+D` on a dead pane is
  `DELETE /panes/pane_N`, clipped or padded display of a pane whose
  leaf is smaller or larger than the pane region.
- CLI: `ko panes [--json]`, `ko layout`, `ko layout put FILE` with
  the retry.

Shapes decided by the user for K2 (2026-11-02):

- The document has no `active`. Each client keeps its current
  session, window and pane on the server. `select {session?, window?,
  pane?}` on `/client` changes only that client: a pane implies its
  window and session; a window implies its session; a session implies
  this client's last current window in it, else its first window. It
  never changes the document or its revision.
- The coordinator keeps, per window and outside the document, the pane
  that a client focused most recently in it. A client that enters a
  window where it has no current pane gets that pane. A new window
  starts with its first leaf; when that pane goes, the window's next
  pane in document order. A client focuses a pane when its terminal
  has focus and the pane becomes its current pane, or when its
  terminal gains focus on its current pane; a selection by a client
  without focus does not count.
- A pane is focused for its program (focus reporting) while at least
  one client with a focused terminal shows it as its current pane.
  Derived from the clients, not stored.
- `switch {over: "session" | "window", direction: "next" |
  "previous"}` moves the client in document order and wraps.
  `POST /clients/client_N/select` (removed in K2c) takes the `select` body and answers
  `{}`, `not_found` for an unknown client. The event `selected
  {session?, window?, pane?}` goes to a client only when something
  other than its own `select` moved it: its `switch`, a `POST` from
  another connection, or the removal of its current pane or window.
- A session or window without `id` in a `PUT` is new; the server
  allocates its id. A new pane is `{new: {cwd?, command?, env?,
  vars?}}`; K3 adds `run`.
- `POST /panes/pane_N/clear_history` answers `{}`. Every mirror of
  the pane stays equal to the pane's terminal after it, also a mirror
  that resumes at an offset from before the clear.
- A float's `cols` x `rows` is its pty size; with `border` the
  rectangle and one cell on each side are clamped into the window.
  `zoom` gives that pane the window's size; the other leaves keep
  theirs.
- The server starts with an empty document. A client that finds it
  empty (the terminal client, Kido.app) `PUT`s one new session with
  one new pane.

Built on `ko-k2` (2026-11-02), for the K1 merge and later stages:

- `clear_history` is a `ko-pane` frame. `ko-pane` feeds `CSI 3 J`
  to the pane's own terminal and puts the same bytes in the ring as
  a `Bytes` record, in one step. Thus every mirror, live or resumed,
  and every replay applies the clear at its true position in the
  stream. A clear that came with less ring room than its bytes waits
  for room; pty bytes read meanwhile go before it in the terminal and
  in the ring. The pending clear is a flag, so clears that wait
  together become one. With no room, `ko-pane` announces `Full`; with
  less room than the clear, it pads to the end of the ring. Each loop
  turn tries the pending clear, so a silent program does not keep it
  waiting. The coordinator sends no snapshot for it. An earlier
  design wrote nothing into the ring and gave the live views a
  snapshot: a view that closed before the clear and resumed later
  replayed the ring without it, and its mirror kept the old history
  (a stale ZWJ cell in the view harness). No verified module changed.
- `ko layout put FILE` (`-` is standard input) sends the file's
  `revision`, else the current one; on `409` it sends the file's
  layout again with the current revision, at most 8 times. The file
  is a whole document, so the last writer wins; a document that omits
  a pane that a concurrent `PUT` created is `invalid`.
  `ko_client::layout::edit` is the read-edit-`PUT` loop with the same
  bound for a client that edits the document.
- `ko_client::Model::rejoin` is the reconnect gate: the same
  `instance` resumes, another one starts fresh. The terminal client
  does not reconnect, so only Kido.app (K5) will call it.
Merged with K1 (2026-11-02):

- One `Vars` type (`ko_server/src/vars.rs`) validates on decode with
  the limits of the vars route. Pane variables, a new pane's `vars`
  and session and window `vars` use it.
- `ko_client::Model` owns the `GET /panes` read. K1's event buffer
  went: the read blocks, so the events queued on `/client` during it
  are applied after it in order (protocol.md 6). The model keeps
  variables without limits, because an older event applied over the
  read can pass through a state over a limit. It drops a row that the
  layout no longer has. A `layout` event whose pane set differs from
  the rows starts a new read.
- The grouped list shows K1's mark column on pane rows; a session
  header has no mark.
- The `ko-pane` frame `clear_history` has kind 28, because K1's
  `foreground` took 23.
- A refused `vars` inside a `PUT` is `invalid`, and its message names
  the refusal, as on the vars route.
- The fuzz corpora still carry the shapes before K2 (`POST /panes`, a hello
  with `pane`, view `focus`); they replay as error paths. A corpus
  migration waits for the next change that needs new inputs.

Tests that close it: every edit of migration.md section 2's table
through `ko layout put` and the Rust client, with the normalized
document and each pane's size by `stty size`; a stale revision gets
`409` and the current document, and the retry lands; a server-made
change reaches a second client; two clients on one window with
different sizes; removal of the last pane of a window and of a
session; a tree scaled down to one column per pane and back; the
proptest properties of 4.1; the client's grouped list with three
sessions.

Risk: medium. The engine must agree with the app's expectations of
tmux's arithmetic; the recorded trees are the check.

### K3. Runs, subagents, prompt, the harness (12 to 17 agent-days, built)

Depends on K1 (the trust rule reads the pi root) and K2 (a run is a
window). migration.md S3 is the specification, with the long poll of
4.4.

Scope:

- `ko_server/src/runs.rs`: `runs/<id>/` on disk with serde JSON
  `meta`, the `command` file, `outcome` with `create_new`, the screen
  capture through the dead pane's `/screen`, the sweep in the model
  tick with the linger grace and stop escalation as server options
  (`KO_LINGER_SECONDS`, `KO_STOP_ESCALATION_MS`), the orphan rule over
  the server's own panes. `POST /runs` makes the run and its window
  as one server-made layout change, detached. `GET /runs`,
  `/runs/<id>`, `/runs/<id>/wait` (the long poll), `/runs/<id>/outcome`,
  `/runs/<id>/stop`. The `run` event on `/client`.
- `GET /prompt/resolve` and `POST /prompt`: scope from the caller's
  `Ko-Pane` and the document; the paste path is one `paste` input and
  one `key` Enter through `pane_proc`; the inbox path is `msg.rs` in
  `ko/` (a port of `lib/msg.ml`). Exit codes 0, 1, 4, 5.
- CLI: `ko run`, `run-child`, `runs`, `run-wait`, `run-stop`,
  `run-outcome`, `reap`, `prompt`, with kido's flags, exit codes and
  JSON. `KO_RUN_ID` and `KO_RUN_OUTPUT` in the pane's environment.
- The harness `share/pi/ko-pi.ts`: the tmux call sites become `ko
  api` requests on `/panes/$KO_PANE/vars/<name>` and `GET /panes`;
  `TMUX_PANE` becomes `KO_PANE`; descriptions say "session". The fake
  `kido` of the TypeScript suite becomes a fake `ko`, a small Rust
  binary (a workspace member outside `default-members`, built by
  `scripts/test-ts.sh` through make) with the same `KO_FAKE_*` gates.
  The fake `tmux` goes.
- `ko_client`: `tree.rs` (a port of `lib/tree.ml`), the `run` event
  applied to the model, the `/runs` and `/prompt` requests. `ko_tui`:
  a run's pane follows
  its parent's pane, indented one column.

Tests that close it: the run suites of kido's `test_e2e/` rewritten
in `ko_e2e` (`run_commands`, `run_creation`, `runs`, `reap`, `agent`,
`async_bash`, `inbox`, `msg`, `prompt`, `pi_name_ending`,
`subagent_elapsed`, `spawn_model`, `watchdog`, `refusal`); a
`/runs/<id>/wait` that answers at the run's end and at its deadline,
with the server idle in between (no wakeup); the TypeScript suite on
the fake `ko`; a spawn tree of depth 2 under `ko` that reports, is
stopped and is swept.

Risk: medium. Mostly moving tested logic. The long poll on the
`Handling` phase is new, and the sweep as a layout change.

Built (2026-11-02):

- The run's pane carries `ko.run` as a variable of the new pane in
  the server-made `PUT`; the new pane needs no `run` field. (K2c
  replaced the variable: the pane record holds its run.)
- The inbox send is in `ko_server` (`msg.rs`), because the server
  delivers: a non-blocking connect and a stored send with a 2 s
  timer, no thread. A `/runs/<id>/wait` uses the connection's own
  timer.
- `ko-pane` hangs up a removed pane's program with `SIGHUP`, then
  `SIGKILL` after 250 ms, so a stop has no `SIGTERM` stage.
  `KO_STOP_ESCALATION_MS` is the coordinator's last kill of a removed
  run pane that still lives.
- The sweep keeps kido's guard over ko's focus: it never closes a run
  pane that a client with terminal focus shows (protocol.md 3), and a
  focus change is one of its inputs. The last-window refusal went; an
  empty session ends.
- The sweep removes the run's pane; a window that loses its last pane
  goes with it in the same change. K2b found that this is already
  the atomic close that the window delete gives, so the sweep keeps
  the pane delete.
- `share/pi/ko-pi.ts` is a copy of `kido-pi.ts`; K8 deletes
  `kido-pi.ts` and its suite. ko-pi reads the panes' sessions and
  windows by joining `GET /panes` with `GET /layout`; a `/panes` row
  does not repeat the document. Its state directory is `ko-pi`, which
  starts empty: nothing migrates from `kido-pi` (decided 2026-11-02).
- The run ids are 32 lowercase hex characters, so no id looks like
  `pane_N`.

### K2b. Layout follow-ups (2 to 3 agent-days, after K3, before K5 step 4)

Depends on K2 and K3. kido-app-notes/ko-api-gap.md 2.1 and the
decisions of 2026-11-02 (section 7, questions 9 to 15).

Scope:

- `DELETE /windows/window_N` and `DELETE /sessions/session_N`, each
  one atomic change of the document: a pane created during it cannot
  survive in a half-closed window. A `PUT` has no remove list. K3's
  sweep closes a run window with the window delete.
- A read-only `focus` field on each `Window` in `GET /layout` and the
  `layout` event: the window's last-focused pane. The server sets it
  and ignores it on `PUT`.
- The empty document: when the last session goes, the server keeps
  running with an empty document; a test pins it.
- A default name for a new window, derived from its first pane as
  tmux does; a client can rename the window.
- A proptest that equalizes an existing tree by omitting its sizes,
  with the normalization's invariants as properties.

Tests that close it: both deletes with a concurrent pane creation;
the `focus` field after a focus change and its absence of effect on
`PUT`; the last session's removal leaves a running server; a new
window's name from its pane and after a rename; the equalize
proptest.

Risk: low.

Built (2026-11-02), with two additions of the top-level session:

- The window's focus lives only in the document (`Window.focus`,
  always present); the coordinator's separate per-window store went.
  The focus is outside the revision (decided 2026-11-02, after K2b
  first bumped it): a selection by a focused client sends a `focus`
  event, not a `layout` event, so it cannot make a `PUT` stale.
  The document's steps only mark it changed, and the coordinator
  increases the revision once, when it publishes the change.
- `DraftWindow.name` is optional. The default rule and its limits are
  in protocol.md 7. A `PUT` whose new window has no name and no
  derivable one is `invalid`.
- C7, the ko-pi cleanup race: `DELETE /panes/pane_N/vars` with
  `names` and `if` deletes atomically and answers `412
  precondition_failed` on a mismatch. ko-pi's `unsetVars` and
  `unsetVarsSync` send one such delete on `pi.session` equal to their
  own session, and nothing without one. `kido-pi.ts` keeps its
  per-name unset, because kido's tmux options have no conditional
  delete; the race stays in kido until K8 deletes it.
- A delete and the sizing claims of the clients that it moves are one
  revision and one layout event.
- `KO_STOP_ESCALATION_MS` has an e2e test: `ko-pane` hangs up and
  kills its program itself, so only a `ko-pane` that cannot act
  (stopped) reaches the coordinator's last kill.

### K2c. Panes travel with the layout (after K5 step 5 and K6's server part)

Decided 2026-11-03. The client reads the layout, its panes and their
variables from one source, so `ko_client` loses its separate `/panes`
and `/runs` reads (`Model::fetch`, `refresh`, `stale`, `install`) and
the app engine's fetch thread.

- `GET /layout` and the welcome carry every pane's row with its
  variables. Variables always travel with their pane.
- A `/client` layout event carries the rows and variables of the panes
  that this revision adds; a removed pane is one that the layout no
  longer names. Changes to existing panes keep their own events, and
  every row field that can change has one.
- The revision moves only when the layout itself changes (a pane added
  or removed, a split, a move, a resize, a name). A change to a pane's
  row (title, cwd, status, death) or a variable write never moves it,
  so it never makes a concurrent layout PUT stale (409); those changes
  travel in their own events.
- The layout event with a pane's row comes before the first other event
  of that pane (a test checks it).
- Server-to-client WebSocket messages get a much larger limit than the
  1 MiB of client-to-server messages, so a layout event or welcome with
  large variables fits.
- `ko_client` reads panes only through `GET /layout` and `/client`.
  For consistency the pane resource keeps its reads: `GET /panes`
  (every pane, as in the layout) and a new `GET /panes/{id}` (one pane),
  both with the variables. The variable reads `GET /panes/{id}/vars`
  (`Vars`) and `GET /panes/{id}/vars/{name}` (`Var`) are removed. The
  writes (`SetVar`, `DeleteVar`, the conditional `DeleteVars`) stay.
- A pane's row carries its run, if it has one: an optional `run` field
  with the run id, parent, argv, start time and, once ended, its
  outcome. Each run has exactly one pane and a pane at most one run, so
  an active run is a run whose pane is in the layout. A run's start puts
  its pane, with the `run` field, into the layout in one layout event;
  its outcome travels in the existing run event without moving the
  revision. `ko_client` then drops its `/runs` read too. Runs whose
  pane is gone stay history: `GET /runs` and `ko runs` serve them.
- `POST /clients/{id}/select` is removed: both clients select over
  their own `/client` socket. `stress.py` and the e2e cases use the
  socket. `ClientRequest::Select` stays.
- A run's command becomes readable: `ko runs ID` (and `GET /runs/{id}`)
  shows the argv, so an agent can look up an old run from the CLI. The
  argv moves into `meta.json`, and the separate `command` file goes.
- A run's outcome is written once by `State`, which refuses a second
  outcome; the file is a plain atomic write, without kido's
  first-write-wins `create_new` (every writer is on the server thread).
- `ko prompt` stays: the user's nvim plugin calls it.
- `POST /runs/reap`, `ko reap` and their client call are removed: the
  server sweeps by itself on each event that can end a run. The reap
  e2e tests wait for the sweep's effect (the outcome event or the pane's
  removal) with a short grace from the server's environment.

Done: `GET /layout` and every `/client` layout event are the document,
its revision and the rows of its panes (`LayoutPanes`); a later event
lists only the panes that its revision adds. The server withholds a
new pane's own events in `State` until its layout event has gone out,
whatever their source. The new `foreground` event covers the last row
field without one. Server-to-client messages are at most 32 MiB, and
all variables of the server at most 16 MiB, so a welcome fits. A
pane's run is fixed at its creation; the `ko.run` variable is gone.
One `RunRow` (the run's `Meta` and its outcome) is the row's `run`,
the `run` event and a `GET /runs` entry; a run pane's death without
an outcome sends the `run` event with the derived outcome. The
run event is sent only when an outcome is recorded. `Model::join` and `rejoin`
take no socket and no timeout, and `ffi::engine` has no fetch thread;
the exported C functions did not change.

### K4. Linux measurements (1 to 2 agent-days, after RL)

RL made the Rust ko build, test and verify on Linux in CI. K4 is what remains of migration.md S4:
`bench/table.sh` and `bench/client.py` on a Linux box, the rows
recorded beside the macOS rows in p1-mvp.md 6.5, and a check of
`SO_SNDBUF` behaviour and the 4 KiB pty read. A row that misses its
target gets a tuning task. The scaffold part of S4 is done.

### K5. Kido.app on the shared client core, text only (16 to 24 agent-days)

Depends on K1 (status) and K2 (layout) for their `ko_client` parts.
Steps 1 and 2 can start at once. migration.md S5 is the
specification, with the shared core of 4.10 in place of a Swift
`KoClient`:

1. **The probe** (1 to 2 agent-days, in the kido repo and the app
   repo): build `ko_client` as a static library into an
   `.xcframework` for arm64 (macOS 26.0 or later) with a header and module map,
   link it into a scratch app target through one cargo build phase on
   the pinned toolchain, connect to a local server, and receive
   `welcome` and `layout` events as main-queue callbacks in Swift.
   The probe shows that the app's Ghostty fork and the core link
   without a duplicate symbol, and it fixes the ABI conventions
   (ownership of buffers, the callback thread, error reporting).
   Done: `make ko-client-xcframework` and `ko_client::ffi`. The core
   copies the socket path; an event is valid only during its
   callback; callbacks run through `dispatch_async_f` on the
   caller's serial queue; after close, no new callback starts, and a
   callback on another thread has ended (a callback that calls close
   ends normally).
   `ld -r` with the export list and an `nm` check hide the clash of
   Zig's `compiler_rt` with Rust's `compiler_builtins`. `ko_client`
   does not link `ko_vt`.
2. Spike 2: `restore_snapshot` on a Ghostty surface in the app's
   fork, shown on the pen, charset and pending-wrap cases of
   known-issues-app.md. Done: pen, charset and pending wrap restore
   exactly, and sequences cut by the snapshot complete. 100k mixed
   lines give a 78 MB snapshot: encoded in 19 ms, READY in 0.08 ms,
   history in 197 ms, and the longest hold of the renderer lock is
   1.3 ms.
3. The `ffi` module of `ko_client` (4.10): connect and reconnect,
   the model as read-only snapshots across the ABI (the layout
   document, the panes with status and variables, the runs, the
   tree), the layout edit call with its retry, view open and close
   with the byte and snapshot feed, input events, `/prompt`, `/runs`,
   the seen record (4.10: one `Seen` for each host over the set of
   shown panes and the attendance flag, the one implementation for
   both clients), and in K6 the image, clipboard and search calls.
   Kido.app's Swift side holds no protocol decoding and no reconnect
   logic. Rules from steps 1 and 2:
   - The terminal size equals the snapshot size. The server's size
     is authoritative.
   - The ffi streams a snapshot to one decoder thread for each
     surface, not the main queue and not the core's I/O thread. It
     never buffers a whole snapshot.
   - Ownership, cancellation and generations: a new snapshot cancels
     the blocked reads of the old one, and a swap or a close waits
     for the old restore to end.
   - The server tells the client its continuation limit (a small
     protocol addition). A fixed 1 MiB failed on an APC of 1.5 MB.
   - `HISTORY_INCOMPLETE` makes the client ask for a resync.
   - The event loop of 4.10 on `ko_sys` with a wake replaces the
     thread-local `launch::Cancel`.
   - When the app must keep data, the ABI gives an owned buffer with
     a free call.
   Done: `ko_client::ffi` with `ffi::engine` (the I/O thread, the
   reconnect, the views' links) and `ffi::view` (one decoder thread
   for each view), `ko_client/include/ko_client.h` and the export
   list. A restore gets the `continuation_max_bytes` of the
   `Welcome` (protocol.md, section 4). The image, clipboard and search calls
   stay with K6. Risks that step 4 takes over, from the app's review:
   - Layout edits cross as a whole JSON document, and on
     `KO_ERR_CONFLICT` the app applies its edit again to the newer
     document. Typed edit operations, with the re-apply on conflict
     in the core, would move that logic out of Swift.
   - The model reaches Swift as untyped JSON (`ko_client_model`), so
     Swift decodes it and a field change is not seen at compile time.
   - The surface's `set_grid_size` runs on the decoder thread for a
     restore and on the main queue for a local resize; step 4 must
     show that the two cannot interleave badly.
   - The error codes are coarse: seven `ko_code` values, and the
     cause of a failure is only in the text of the buffer or of the
     `FAILED` event.
   - The x86_64 slice of the xcframework is gone: Kido.app supports only
     Apple Silicon and macOS 26 or later, so no slice stays untested.
4. The layout from the model; every gesture one edit call, coalesced
   per gesture step. Tabs, the sidebar tree, seen state and
   notifications read the model's snapshots. After K2b: a tab of a
   window that is not current takes its title from the window's
   `focus` pane, and selecting the window lands on that pane; tabs
   show the server's default window name until a rename; an empty
   document shows the app's banner and its start flow opens a new
   session (the server keeps running). Step 4 also includes a minimal
   content bridge: `PaneView` gets its bytes and snapshots from a
   view and sends input as `KO_INPUT_TEXT`. Step 4 deletes the tmux
   pieces and does not keep them compiled: the control client with
   its marker hack, the `kido rpc` subprocess, the stamp discovery,
   pause recovery, the image client, the `-G`/`-K` fill, `PaneSync`,
   `HistoryCapture`, `SearchCapture`, `ScrollAnchor`, and the tmux
   paths of `PaneView` (Load more, chunk search, anchors, the replay
   fence, the `verify` probes). Find uses the Ghostty search over the
   mirror.
5. The design of `PaneView` on the view feed: the scroller from the
   mirror, find over the full mirror, and `KO_INPUT_TEXT` against
   `KO_INPUT_KEY` with a measurement of the kitty keyboard cases.
   Done: the app keeps Ghostty's encoding, and `ko_view_input` takes
   bytes; the key, mouse and paste kinds left the ABI and stay in the
   protocol. The two encoders agree on the measured kitty cases under
   flags 0, 1 and 3, the SGR click, release events and the flag stack
   across a copy-mode resync; they differ on Shift+Space, where the
   app is right, and only the app can send SGR pixel mouse. The
   server's size wins: a restore adopts the snapshot's size in the
   app's Ghostty fork, `SIZE_MISMATCH` is gone from `ghostty.h` and
   `ko_client.h`, only the decoder thread sizes a grid, and the
   terminal draws at the grid's size while the frame differs. The
   core nests a run window's split under the run's parent. The
   stress harness reaps its servers, so `kill-server` stops in time.
   The priority-inversion warning is not in ko_client or Ghostty
   (known-issues-app.md).
6. Done: `PaneGeometry`, and `SurfaceGeometry` in `PaneView`. The
   fork lost prepend history, the scrollback raise, the viewport
   anchor, `restore_output`, the image fill, its recovery enum and
   `take_unread_images`. Manual IO, `set_grid_size` and the reply
   suppression stay: the decoder sizes the grid through them, and a
   mirror must not answer a query a second time. The pending-image
   state stays for the frame API. A cell change under manual IO keeps
   the grid, and one size lock orders main and the decoder.

The estimate falls from 20 to 30 because the transport, the protocol
types, the event stream, the reconnect and the model exist once in
Rust with their tests, and the Swift part is the UI and the surface
feed. The ABI and the build integration add about 3 agent-days of
new work.

Tests that close it: the probe's end-to-end event in Swift; the ABI's
unit tests in `ko_client` (every exported function on a socketpair
server; a freed buffer is not read again; a callback after close is
not delivered); migration.md S5's list for the app: the pen, charset,
wrap and reflow cases, resize and 100k-line restore timings, two
windows with independent current windows and the sizing rule, the
stress harness on layout edits, the off-screen sidebar, tabs, prompt
and notification tests on recorded event sequences, now replayed
through the core's model. Risk: medium; the largest refactor, the
one spike that has not run, and a new build integration.

### K6. Images with animation, clipboard and search, both clients (12 to 17 agent-days)

The server and terminal client part depends on K1 (the callback
plumbing); the app part on K5. Decided 2026-11-02: animation is done
properly from the start, with no fallback (4.5).

**The server and terminal client part is built** (2026-11-03): the
image, clipboard and search behaviour is in
rfc/kido-server/protocol.md sections 5, 9, 11 and 14. The protocol
version stays 1.0 (the user's decision), so the "protocol minor"
below does not apply. Where the build differs from the scope below
(the coordinator mints each object name and records it before
`ko-pane` creates the object; the leak record is
`ko_server/src/shm.rs`), protocol.md is the reference. Open:
`images=all` is still refused.

**Kido.app's part is built** (2026-11-03): docs/design-app.md
("Images", "Clipboard", "Threads") is the reference. Where it differs
from the scope below: the mirror accepts only `t=d` on both hosts, and
the app fetches every pending frame, not only the frames of on-screen
placements, which it lists with one surface wrapper in the fork
(`ghostty_surface_kitty_pending_frames`); the surface's image limit is
the server's `kitty_images_max_bytes`; OSC 52 and OSC 5522 reads and
writes travel only as the server's clipboard events, with the mirror's
own handling off by config, no fork change; the app does not use
`/search`, because its mirrors are full (K7 decides for a partial
remote mirror).

**Follow-up: a Ghostty fork change for clipboard reads** (built in
the server; the fork commit waits for its pin bump). The request of
`GhosttyClipboardRead` names its protocol, and
`ghostty_clipboard_read_defer` gives a handle that
`ghostty_clipboard_read_complete` answers after the callback
returns, so the terminal encodes OSC 52 (with the request's
terminator) and OSC 5522 replies itself. `ko-pane` forwards OSC
5522 reads with `mimes` and `list` (protocol.md 9). What remains is
the app's part: pass `mimes` and `list` through, answer with
`available` for a `list` read, and turn 5522 reads on again at the
mirror, with `ClipboardTests`' 5522 cases as the acceptance.

**First task: the Ghostty fork** (built; the fork commit "Read and
complete Kitty image frames through the C API"). The header is `include/ghostty/vt/kitty_graphics.h`
(`ghostty_kitty_graphics_frame_get`, `_frame_attach`,
`_frame_adopt`, `_screen_image`, the animation keys of `image_get`)
and the terminal key `KITTY_PENDING_GENERATION`; the app's surface
wrappers are in `include/ghostty.h`. `ko_vt/src/frames.rs` wraps the
read and the copying attach. Decisions that the code does not state
(reviewed by the app's side, 2026-11-02 and 2026-11-03):

- A frame's generation is a serial that the bytes alone decide, so
  the pane and every mirror compute the same value for the same frame
  state, and `?generation=` keys the server's objects and the mirror's
  attach with one number. A counter over graphics commands moves
  once for each command that stores pixels or numbers frames
  (transmission, `a=f`, `a=c`, `a=d d=f`), before the image lookup
  and whatever the local outcome, so an eviction, a refused medium or
  image storage that is off in one terminal does not move it apart.
  One counter serves both screens. A chunked command moves it
  at its last chunk. `a=a`, `a=p`, queries, ticks and restore input
  never move it. A serial never repeats in a terminal, also across a
  reset. Serial 0 is a frame without an identity (a frame that restore
  input created), and no fetch completes it. The snapshot carries the counter and each frame's serial,
  and a payload record carries its frame's serial, so a payload for a
  frame that an edit stamped again is dropped.
- A frame that this terminal cannot fill becomes pending with the
  command's serial: a refused or unreadable `t=s`, an edit of a pending
  frame, and an `a=f` or `a=c` whose source is pending here. A fetch
  at that serial then gets the pane's composed pixels. This closes the
  race in which a mirror attaches post-edit pixels under the old
  serial and then composes the edit a second time.
- A live transmission with the id of a pending image replaces it, as
  upstream's `loadAndAddImage` replaces any image: its placements go,
  and the frame API's commit gives the new image a new serial, so an
  attach at the old serial is refused. Nothing fills a pending image
  in place except an attach or an adopt.
- An animation with a pending frame does not play; the last attach
  restarts its frame timer.
- Adopt takes the mapping that `mmap` returned (`map_len` is the mmap
  length) and owns it on success; a frame of any number can be a
  mapping, copied only before an in-place edit.
- The vt calls take no lock. The surface wrappers take the renderer
  lock and wake the renderer; they are the app's apprt and stay in the
  fork. The vt calls and the snapshot fields are candidates for
  upstream Ghostty.
- The snapshot bytes changed (the payload record and the storage
  record), so the app's decoder and ko's must come from the same pin.

The original task text follows. Two additions to the libghostty-vt C
API, in one fork commit:

- Read frame `n` of an image: a frame iterator or an indexed query
  beside `GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR`, which gives the pixels,
  format, size, compression and the per-frame generation of frame
  `n`, and the image's frame count, gap and the playback state that
  `a=a` set. The snapshot encoder already walks every frame
  (`KITTY_IMAGE_PAYLOAD` numbered 1 for the image and 2 and up for
  the frames), so the storage holds them; the API exposes what the
  encoder reads.
- Attach fetched pixels to a pending image's frame `n` outside the
  snapshot decoder: a call that takes the image id, frame number,
  generation and a pixel buffer or a mapping, completes that frame
  as the decoder's `KITTY_IMAGE_PAYLOAD` path does, and refuses a
  generation that moved on. An animation with pending frames does
  not play, as the app's fork already rules for its fill.

The commit carries an upstreaming note: both calls are
renderer-neutral additions to the public API with no app policy in
them, so they are candidates for upstream Ghostty, as the fork's
`t=s` and refused-media commits are. The top-level session moves the
pin (AGENTS.md, "One Ghostty"). The pin bump regenerates
`ko_vt_sys/src/bindings.rs` and bumps `Ko-Vt`. `ko_vt` gains the two
safe wrappers with unit tests over a two-frame upload.

Scope after the fork:

- `ko-pane`: the `image` request names an image, a frame and a
  generation; `ko-pane` copies that frame's pixels once into a named
  0600 object `/ko-<pid>-<n>` (under 31 bytes) and answers with the
  name, geometry, format and frame metadata, or not found;
  `image_gone` on eviction, on a generation move of that frame, on a
  frame removal by the program (`a=d`) and at exit. Placements and
  the `a=a` playback control still travel in the view bytes, so an
  `images=none` mirror knows which frames exist and what plays, and
  fetches the pixels. `images=all` keeps the payload records in the
  snapshot (`ko_vt::cut`) for a mirror that wants them inline.
  `clipboard_write` and `clipboard_read` frames from the callbacks;
  `search` and `search_cancel` over `ghostty_search_*`, with matches
  as frames.
- `ko_server`: `images.rs`: `GET /panes/pane_N/images/<id>/frames/<n>?generation=`
  (frame 1 is the image itself), `Ko-Accept-Shm` for the name, else
  the pixel body from the coordinator's own mapping through a pull
  source on the connection; the `<dir>/shm` leak record keyed by
  image, frame and generation, cleaned at start and after a `ko-pane`
  crash. `clipboard.rs` (one answerer by focus, the 8 s timer,
  `clipboard_answer` on `/client`). A clipboard read for a pane that
  no attended window shows is refused at once, as the app does today;
  it does not wait 8 s for an answerer (decided 2026-11-02). `GET /panes/pane_N/search` as a
  WebSocket with the match stream and `done`. `ko_sys::mapping`: a
  named kept object. Protocol minor.
- `ko_tui`: OSC 52 writes forwarded to the outer terminal; reads
  answered through an OSC 52 query to the outer terminal and the
  reply router of `input.rs`. No image drawing (section 3).
- Kido.app: an `images=none` mirror; for each placement on screen the
  app fetches the frames that the mirror holds pending, in parallel,
  one connection each, and attaches them with the new fork call; the
  zero-copy path maps the object for an uncompressed frame; pixel
  bodies remotely; `ghostty_kitty_graphics_animation_tick` plays the
  restored animation from the frame and state that the bytes or the
  snapshot carried; consent and grants unchanged; `/search` for a
  partial remote mirror.

Tests that close it: the fork's two calls on a two-frame upload in
`ko_vt` (frame 2's pixels and generation; an attach with a stale
generation is refused); a `t=s` image fetched by name by a local
client and as a body by a client without `Ko-Accept-Shm`; a
three-frame animation fetched frame by frame into an `images=none`
mirror in the view harness, which then matches the pane's terminal
frame for frame under `animation_tick`; a frame edit (`a=f` on frame
1) moves that frame's generation, makes the old object 404 and gone,
and the new fetch lands; a placement and its animation survive detach
and reattach; an evicted image is 404 and its objects are gone; a
killed `ko-pane` leaves no object after the coordinator's cleanup,
and a killed coordinator none after the next start; one clipboard
read gets exactly one answer with two clients attached, and an
unanswered read ends at 8 s; an OSC 52 write reaches the outer
terminal from the terminal client; a search streams its matches and
stops on close; a 100 MiB frame body streams without closing the
connection. In the app: a two-frame animation plays after attach and
after reconnect, with no copy for an uncompressed `t=s` frame.

Risk: medium to high. The fork work is Zig inside libghostty-vt's
kitty storage, where the app's fork already changed frame restore;
the API shape must satisfy both the server's copy and the app's
zero-copy attach, so the fork task ends with a review of its header
before the Rust and Swift sides start. Shared memory by name is spike
5, not yet run. A fork change bumps `Ko-Vt`, which ties K6 to a
coordinated app release, as every pin bump does.

### K7. Remote over SSH (5 to 8 agent-days)

Depends on RL (the remote host is Linux), on K2 (the reconnect gate), and on
K5 for the app part.

Scope:

- `ko HOST`: `ko_client/src/launch.rs` starts `ssh -M -N -T` with a
  private `ControlPath` under a 0700 directory, waits with `-O check`,
  asks `-O forward -L <local>:<remote dir>/socket`, and attaches to
  `<local>` as to a local server. `ko api --host`. Nothing runs on the
  remote besides `ko`; the remote server starts only on an explicit
  `ssh HOST ko server`.
- Reconnect by offset, gated on `instance`.
- Kido.app: the forward on the master it already owns; discovery
  reads `/version` through the forward.
- `SSH_AUTH_SOCK`: `ko server` sets it to `<dir>/agent.sock` by
  default, so every pane gets the app's agent publication, also on a
  server that `ko` started before the first app window. There is no
  server-environment route (decided 2026-11-02).
- Measured: attach, 100k-line restore and echo at 50, 150 and 300 ms
  RTT with a throttled link, including an attach of 100k mixed lines
  (a 78 MB snapshot, spike 2 of K5; 4.6 assumed about 6 MB from
  plain lines), with and without a compression crate in
  a scratch build. The result decides question 2 of section 7.

Tests that close it: a localhost sshd (`KO_E2E_HOST_SSH=1`) with the
forward, attach, detach and reconnect; master loss and recovery; the
RTT table.

Risk: low to medium. The transport is standard; the app's lifecycle
code exists for a stdio transport and changes shape.

Built (the server and terminal-client part, without the app part, the
RTT measurements and compression):

- `ko HOST`, `ko api --host HOST PATH` and `ko server
  --print-socket` (ko/src/main.rs, ko_client/src/remote.rs). The
  private directory is `<state>/remote-XXXXXXXX`, mode 0700, or
  `/tmp/ko-remote-<uid>-XXXXXXXX` when the state path is too long for
  ssh's temporary ControlPath name in `sun_path`. The master runs as
  a child of `ko`; a guard stops it and removes the directory on
  every exit and on SIGINT, SIGTERM and SIGHUP. The errors are
  separate for a missing remote `ko`, no server (the message names
  `ssh HOST ko server`) and a refused forward.
- Reconnect, for a remote attach only: a lost link, the master's
  SIGCHLD, or an error in a step when a `/version` probe also fails
  starts it. One outage deadline of 60 s runs until the view is
  restored; attempts are loop timers with a backoff of 100 ms to 2 s,
  and each blocking step gets only the time that is left. The ssh
  steps (the master, the socket query, the forward) are stages of
  `Remote::advance` that the loop reaps on SIGCHLD; a ControlPath that
  exists means the master is ready. An attempt starts the master and
  the forward again when they are gone, sends a new hello and calls
  `Model::rejoin`, which carries the seen record: the same `instance`
  reopens the view at its offset (`wire::Resume`, shared with the
  app's views), another `instance` drops the mirror and starts the
  model again. While the pager runs, attempts wait, and the deadline
  starts again when the pager ends. A remote attach sends no `cwd`
  when it creates a pane. A local attach does not reconnect.
- `ko server` gives every pane `SSH_AUTH_SOCK=<dir>/agent.sock`
  (ko_server/src/panes.rs); a pane request's `env` replaces it. At
  start, before it binds its socket, the server links that path to
  the agent of its own environment (ko_server/src/agent.rs), so a
  server without the app keeps the user's agent. The rule: the
  inherited value must be an absolute path to a socket, other than
  `agent.sock` itself (a nested ko, or the app's remote start); the
  server makes the link only when `agent.sock` is absent or a symlink
  whose target is not a socket file. A symlink to an existing socket
  file stays, so the app's publication wins over a later server
  start, and a link whose target a reboot or a closed forward removed
  gets the inherited agent. The check reads the file type and does
  not connect: an agent that exited but left its socket file keeps
  its link. Anything that is not a symlink stays. The link is made
  under a temporary name in the directory and renamed over
  `agent.sock`, as the app's attach script does. A failure is a
  warning; the server starts. No marker records who made a link: the
  file-type check needs none, and a marker would keep a dead link of
  the app. Limit: no lock is shared with the app, so a publication
  between the server's check and its rename is lost; the app
  publishes at attach, after the server started.

Limits: the handshake and the welcome of an attempt block the
loop for at most the time left, the error probe for at most 3 s, and
the refused-or-no-server check (`ko api /version` on the host) for
at most 20 s. The first master start can wait 60 s for a password
prompt. A SIGKILL of `ko` leaves the master and the private
directory. The 60 s limit has no test.

RTT table (measured 2026-11-03, macOS, cut short by the user: no
50 ms or 10 Mbit/s cells and no review). Method: a localhost private
sshd (the recipe of `ko_e2e`'s remote tests) behind
`bench/rtt_proxy.py` as ssh's `ProxyCommand`, which delays each
direction by RTT/2, caps the bandwidth with a token bucket and counts
the wire bytes; `bench/rtt.sh` drives `bench/client.py`'s `Remote`
target. "History loaded" is from the spawn of `ko HOST` to the last
history row in the client, so it includes the ssh setup that "screen"
shows; "transfer" is a protocol view's first to last snapshot slice.
The mixed history is `bench/produce.c`'s mixed lines (SGR runs, wide
cells, emoji, combining marks, OSC 8), 77.3 MB of snapshot; plain is
6.9 MB. miniz is a scratch build (not in the tree) that deflates only
snapshot slices. Medians of 3; 1-minute load averages were 2.5 to
6.6, one run at 10.1, whose result agrees with the unlimited cell.

| 150 ms, 100 Mbit/s | none | `ssh -C` | miniz l1 | miniz l6 |
|---|---|---|---|---|
| attach, empty pane | 2.22 s | 2.19 s | 2.21 s | 2.19 s |
| plain, history loaded | 2.75 s | 2.67 s | 2.26 s | 2.23 s |
| mixed, history loaded | 8.74 s | 8.35 s | 4.87 s | 5.01 s |
| mixed, transfer | 6.19 s | 5.80 s | 2.38 s | 2.52 s |
| mixed, wire bytes down | 77.4 MB | 24.8 MB | 29.7 MB | 25.1 MB |
| mixed, server deflate CPU | - | - | 0.29 s | 2.4 s |
| echo over RTT, p50 / p99 | 0.6 / 0.8 ms | 0.6 / 2.1 ms | 0.6 / 4.1 ms | 0.8 / 11 ms |

At 300 ms the mixed history loads in 15.9 s (none), 16.0 s
(`ssh -C`), 8.8 s (l1) and 8.2 s (l6); attach is 4.1 s. The local
floor is 20 ms attach and 0.35 s mixed. Unlimited bandwidth gives the
same times as 100 Mbit/s: OpenSSH's 2 MiB channel window, which counts
uncompressed bytes, limits the transfer, so `ssh -C` sends a third of
the bytes and gains nothing, and only compression inside ko helps.

The decision rule: (1) fails, the mixed history needs 8.7 s, not 3 s;
(2) fails, `ssh -C` is 1.7 times slower than miniz; (3) fails
narrowly on history loaded, l1 is 1.71 times faster than `ssh -C`
(1.82 at 300 ms) where the rule needs 2. Its CPU is in bounds
(0.29 s per 77 MB), and l6's is not. Thus the rule gives no crate. On
the transfer alone, l1 is 2.4 times faster, and the rule would add it:
the fixed ~2.2 s of ssh setup decides the result. The decision is the
user's (section 7, question 2). The scratch patch and the raw runs are
kept outside the tree.

Built (the app part, docs/design-app.md "Remote hosts"): Swift owns
the master, the forward and the agent publication; the ko client
connects to the forward's local socket as to a local server, and its
engine reconnects and resumes by offset gated on `instance`.
`ko_client` gained `ko_client_probe` (the engine's version check,
shared), and `ko_remote_socket` and `ko_remote_unreachable`, which give
the app the classification and the texts of `ko HOST`. A refused
forward and a missing remote socket both exit 0 and give EOF, so the
probe comes first and `ko api /version` on the host second. After a
master loss the app starts a new master at the same ControlPath and the
same forward, with no outage deadline (backoff 1 s to 30 s, a sleeping
Mac comes back at wake). A killed master leaves its control socket, and
ssh then starts a master without one; the app removes it first. Remote
image fetches are bodies, at most 4 at once, retried after a welcome.
The remote setup (the master, the query, the forward, the agent link) is
administrative and may write in the server's state directory; client
actions only connect to `<dir>/socket` (decided 2026-11-03), so local
uploads moved out of the server directory. Tests: `app/KoTests/RemoteTests.swift`
under `KO_E2E_HOST_SSH=1` with a private sshd for each test. The RTT
harness (`make rtt`, `app/scripts/rtt.py`, `KIDO_APP_TIMING=1`) uses ko's delay
proxy.

Decided 2026-11-03 (question 2 of section 7): the server deflates
every snapshot slice with `miniz_oxide` at level 1, with no
negotiation; live output stays raw (protocol.md section 4). The
cell measured again on the shipped build (150 ms, 100 Mbit/s, mixed,
medians of 3, 1-minute load 1.8 to 2.6):

| 150 ms, 100 Mbit/s, mixed | none | shipped l1 |
|---|---|---|
| history loaded | 8.69 s | 4.90 s |
| transfer | 6.19 s | 2.38 s |
| wire bytes down | 77.4 MB | 29.7 MB |
| local floor, history loaded | 0.33 s | 0.59 s |
| local floor, server CPU | 0.01 s | 0.26 s |

The `none` column is 20cc9449 with its per-view queue raised to
1 GiB: unchanged, it times out on all 3 runs, because the 77 MB
uncompressed snapshot is over the 64 MiB queue cap and the server
closes the view. The shipped build keeps the 64 MiB cap; its 29.7 MB
fit, but a history whose compressed snapshot is over 64 MiB still
loses its view until the queue drains in pieces (4.5).
The coordinator's one thread deflates each view's slices: N views
that attach at once cost N times the deflate (about 0.26 s for each
77 MB history).

Open: the app rows of the RTT table (attach, the 100k-row restore and
echo through the app), measured before and after compression.

### K8. The cut-over (6 to 9 agent-days)

Depends on K3, K5, K6 and K7. One unit of work that merges
`kido-app-ko` into `main`. Thus, `main` also takes `app/`, and the
separate `kido-app` branch ends: Kido.app builds and releases from
`main` (AGENTS.md, "Releasing", changes to match).

- Delete as migration.md S8 lists, plus everything of 4.9: dune and
  every OCaml file. `go.mod` goes with `test_e2e/`.
- Rename: `kido-pi` to `ko-pi`, `share/kido` to `share/ko`, every
  `KIDO_*` to `KO_*` (migration.md section 7), the pi state directory
  to `ko-pi`.
- `make install`, `scripts/release.sh` and the Homebrew tap ship `ko`.
  `make preview-pi` targets `ko-pi.ts`.
- Docs: migration.md section 8; `rfc/kido-server/` moves into `docs/`
  as ko's design; the plans and RFCs are deleted as plans.
- Naming (decided 2026-11-03): the server, the CLI and the code are
  `ko`; the product brand stays Kido, and the app stays Kido.app. The
  rename above covers identifiers, paths and variables, not the brand.
- The website describes Kido, with `ko` as its server and CLI. Kido.app's
  release follows with the ko client as its only transport.

Tests that close it: `make verify` with no tmux and no dune on PATH;
`scripts/lint.sh` on the new docs; the TypeScript suite; a fresh
install from the tap on a clean machine attaching to a new server.

Risk: low in code, high in omissions.

### K9. Upgrade in place (7 to 10 agent-days, after K8)

design.md 4.12 with the Verus item of 4.8: the state file (serde),
`CLOEXEC` cleared on the rings, control sockets and listener,
`execve` with `--resume-upgrade`, the adopted-ring constructor in
`ring/backend.rs` with its assumption line, the per-pane `ko-pane`
handoff over `SCM_RIGHTS` (`sendmsg` and `recvmsg` in `ko_sys::sock`).
Spike 4 first (1 agent-day). Until K9, an upgrade restarts the server
and ends its panes.

### Totals and critical path

| stage | agent-days | depends on | maps to |
|---|---|---|---|
| K1 status, variables, `ko shell`, `ko ssh` | 10 to 14 | none | S1 |
| K2 layout document, reconnect gate | 8 to 11 | none (beside K1) | S2 |
| K3 runs, prompt, harness | 12 to 17 | K1, K2 | S3 |
| K2b layout follow-ups | 2 to 3 | K2, K3 | none |
| K4 Linux measurements | 1 to 2 | RL | S4 (rest) |
| K5 Kido.app on `ko_client`, text | 16 to 24 | K1, K2 (steps 1 and 2 at once); K2b before step 4 | S5 |
| K6 images with animation (fork first), clipboard, search | 12 to 17 | K1; K5 for the app part | S6 |
| K7 remote | 5 to 8 | RL, K2; K5 for the app part | S7 |
| K8 cut-over | 6 to 9 | K3, K5, K6, K7 | S8 |
| K9 upgrade in place | 7 to 10 | K8 | S9 |

To the cut-over: 72 to 105 agent-days of implementation, plus review
and verification. K0 did the `ko_client` split before K1 and K2. The critical path is K2, K5, K6 (app part), K7 (app
part), K8, with K3 and K2b before K5 step 4. K1, K4 and the server
parts of K6 and K7 run beside K5. RL must land before K7's acceptance. The earlier total was 67 to
102; the Rust base adds the port surcharge on K1 and K3 and removes
most of S4.

## 6. What stays decided

These items of migration.md and s1.md stay as decided, with the
reasons above where the base changed the mechanism but not the
answer: kido ends and `ko` replaces it; the terminal client shows one
pane at a time from a list grouped by session; the agent features move
into ko; Kido.app keeps all of its functionality; the layout is one
document with whole-document `PUT` and a revision check; panes carry
arbitrary JSON variables; remote is a unix-socket forward for both
clients, with `ko ssh` beside it; images and clipboard in both
clients (the terminal client gets clipboard, not image drawing,
section 3); Linux measurements are a step; `kill-server` by peer pid;
the client is its `/client` WebSocket; no `ko pane` commands; the
status glyphs and colours in the terminal client; the record set in
the coordinator; the 0.5 s green hold dropped; no `ko.conf`.

One flagged change: the status `kind` JSON shape (4.3) follows
the protocol's tagging, not the kido RPC shape that s1.md 6.4 names.
The decision of 2026-10-31 that the code is the source of every
message shape covers this.

## 7. Questions and the user's decisions (2026-11-02)

Decided:

1. **The minimal terminal client.** Section 3's list: a status
   column (K1), session headers and cross-session navigation (K2),
   indented subagent rows (K3), OSC 52 forwarding (K6), `ko HOST`
   (K7); no image drawing, no messages, no find, no copy mode. It
   drops the kitty passthrough of migration.md S6 for the terminal
   client. Decided: yes.
2. **Compression on the remote path.** K7 ships without a
   compression crate, measures the RTT table with and without a
   scratch build of `miniz_oxide`, and the crate is decided on the
   measurement. Decided: yes. Decided 2026-11-03 on the table:
   `miniz_oxide` level 1 on snapshot slices (K7).
4. **Animation delivery.** Done properly from the start, no fallback:
   K6 adds the two calls to the Ghostty fork first (read frame `n`
   with its generation; attach fetched pixels to a pending frame `n`
   outside the snapshot decoder), the image resource takes a frame
   number, shared memory is per image, frame and generation, and an
   `images=none` mirror plays animations from the separate resources
   (4.5, K6). Decided.
5. **The cut-over deletes dune.** At K8, every OCaml file and the
   dune toolchain go (4.9); the repo is a cargo workspace with
   `share/` and the TypeScript harness; the fake `ko` for the
   TypeScript suite is a Rust binary from K3 on. Decided: yes.
6. **A `ko_shell` workspace crate** for `prime`, `shell`, `ssh` and
   `bin_dir`, used by the `ko` binary and read by `ko server` for
   `--bin-dir`. Decided: yes.
7. **Cut-over timing.** After K7. Decided: yes.
8. **Linux before remote.** RL lands as planned, then K4's
   measurements, before K7 starts. Decided: yes.

3. **The status JSON shape and the client core.** Tagged serde enums
   (4.3), and both clients share the Rust crate `ko_client` (4.10):
   transport, protocol types, the event stream with reconnect, the
   model and the view feed; Kido.app links it as a static library in
   an `.xcframework` through a hand-written C ABI, with no
   libghostty-vt inside the core; `ko_tui` keeps its mirror outside
   the core; K5 starts with the probe. Decided.

Decided 2026-11-02, from Kido.app's review of ko
(kido-app-notes/ko-api-gap.md section 3):

9. **Window and session deletion.** `DELETE /windows/window_N` and
   `DELETE /sessions/session_N`, each atomic; no remove list in `PUT`
   (K2b).
10. **The window's last-focused pane.** A read-only `focus` field on
    `Window` in `GET /layout` and the `layout` event; the server sets
    it and ignores it on `PUT`; the app keeps no copy (K2b, K5 step 4).
11. **Seen state.** It moves into `ko_client` (4.10) with a set of
    shown panes and an attendance flag; both clients use this one
    implementation, with one `Seen` for each host (K5 step 3).
12. **`SSH_AUTH_SOCK`.** `ko server` sets it to `<dir>/agent.sock` by
    default; there is no server-environment route. The server links
    that path to its own inherited agent only when the path is absent
    or a link to no socket file, so the app's publication wins (K7).
13. **Clipboard reads for a pane that no attended window shows.**
    Refused at once, today's rule; no 8 s wait for an answerer (K6).
14. **The empty document.** When the last session goes, the server
    keeps running with an empty document, and the app opens a new
    session (K2b for the server, K5 step 4 for the app).
15. **Window names.** The server gives a new window a default name,
    derived from its first pane as tmux does; clients can rename it
    (K2b, K5 step 4).
