# The RPC protocol

`kido rpc` lets an external client such as Kido.app watch one kido server
and navigate its sessions and windows. It is a subprocess protocol over
stdio, not a socket service: stdin carries requests and stdout carries
newline-delimited JSON events. The client keeps stdin open for the life of
the feed and reads stdout continuously.

[The wire contract](../share/rpc/contract.md) is the source of truth for
exact message shapes, fields, enum values and fork dependencies. Lint and
tests enforce that contract. This document describes the model and its
lifecycle rather than duplicating the schema.

## Selecting a server and client

The invocation is `kido rpc --server DIR --client NAME`. `DIR` selects both
the state directory and its `socket`; `NAME` is the tmux client whose
current location the feed follows. RPC does not create that client or
start a server. It can run outside tmux, without synthesizing `TMUX`; an
external client runs it without `KIDO_AGENT_*` environment variables.

Without `--server`, resolution uses the pane's convention-following tmux
socket directory, then `KIDO_STATE_DIR`, `XDG_STATE_HOME/kido`, and
`~/.local/state/kido`. The same resolution serves the launcher, `kido
server`, and the switch commands. The explicit socket reaches both the
control connection and the model's one-shot tmux calls.

`kido server --server DIR` ensures a detached server and returns its tmux
executable and socket paths alongside `protocol`, `server` and `expected`.
`protocol` is always the binary's `Protocol.value` string. `server` is
always present: the creating server's global `KIDO_SERVER` stamp, or null
when unset, even when it matches. `expected` is the binary's own stamp,
`Launch.stamp`. Ensuring or attaching an existing server
does not change its stamp. The binary build id from `kido --version` is a
separate value, not a protocol version.

## Compatibility before snapshots

`Protocol.value` is the binary's MAJOR.MINOR protocol constant, currently
`4.0`. It versions the RPC surface between the binary and its client, and
nothing the tmux server holds, so bumping it never requires a server
restart.

The server's side is a separate stamp, `Launch.stamp`: the first 12 hex
digits of an MD5 over the fork revision the build pinned, the server.conf
`Launch.server_conf` writes and the environment `Launch.server_env` gives
the server, both computed for fixed placeholder paths over a placeholder
environment, so the inherited user environment is left out. It is derived,
so nobody bumps it: a fork bump or any change to `kido-tmux.conf`, the
generated template or what the launcher sets in the environment changes it,
while the install's own paths (the kido executable, its bin directory, the
user's kido.conf) do not. The build
learns the revision from `scripts/install-tmux-fork.sh --print-revision`,
which reads the gitlink, so it needs the git checkout the fork build needs
anyway. The launcher stamps it into the tmux server's global `KIDO_SERVER`
at creation, before its configuration runs. RPC probes that stamp before
opening the model's control connection.

The first stdout event is a hello carrying the binary protocol. If the
server stamp equals the binary's, the hello carries nothing else. If it
differs or is absent, the hello adds `server`, the server's stamp or null,
and `expected`, the binary's; then RPC writes an error event and exits 2.
There are no snapshots or requests processed on that path, and there is no
compatibility negotiation.

Additive fields and enum values bump the minor version. Removing or
renaming a field, changing its meaning, or changing a reply shape bumps
the major version. Clients ignore unknown fields and handle unknown enum
values. Snapshots retain `v:2` as their schema marker; hello governs the
whole RPC surface, including requests and replies. The contract also
pins the fork behaviours clients depend on.

Kido.app checks that hello is first and that its protocol is compatible
before accepting snapshots. A rejected or incompatible hello stops the
feed and exposes a protocol mismatch rather than retrying it as a
transient failure. An ordinary disconnect or unreadable event causes a
new subprocess connection, with exponential backoff capped at eight
seconds. A snapshot resets the backoff. The client fails pending requests
on reconnect rather than replaying them.

## One model, two views

`Sidebar` owns the tick, per-pane tracking and the typed session
and node tree; `Pane_status` owns a pane's typed status and the tracking
behind it. RPC serializes that model; `Kido_sidebar` in `bin/` draws it
with Mosaic; `lib/` has no TUI dependencies. The model reports
classification and semantic status, never presentation or
acknowledgement: no width, colour, layout, glyph, caption, span or seen
state. Each frontend composes labels and captions from the plain title
and typed status, picks glyphs and palette, owns its seen outcomes,
and derives bracket and continuation columns from the same
tree. RPC sends uncut text; the external view truncates and styles it.

The tick reads tmux topology, live agent reports, process information,
run metadata and outstanding asks. Only root apps pi and claude-code identify agents;
State supplies local pi identity but is not a detection signal. It also performs the reap sweep. These operations are idempotent with a TUI
sidebar running beside RPC; the feed is not a passive file reader.
RPC uses the default 100ms interval. Stall and linger knobs come from the
RPC process environment, through the same option readers as the TUI,
not through requests or per-client tmux options.

## Whole snapshots

A snapshot holds the named client's session, window and pane location,
a transient error, and sessions in display order.
Each session holds its name, current marker and a tree of nodes. A
multi-pane window is a window group containing pane items; a one-pane
window is an item directly. Each pane item carries a plain title, a
lifecycle (Ended with its run result, or Live with the pane kind and its
status), its raw records, run metadata and child windows hoisted under
it. Hoisting stays within a session.

Run classification distinguishes subagents, plain bash and streamed bash,
including ended or lingering panes. A live run carries its metadata start
time while its pane is alive and no outcome is recorded, independently
of activity text or agent status. Ended runs, top-level agents, shells
and ssh have no run start time. Clients compute elapsed time locally;
a running clock does not produce a snapshot every second. The TUI shows
an elapsed caption for runs with no message or progress and schedules
its own redraw at the next second boundary.

Run kind and the optional running start time are derived once in Sidebar's
typed rows; ask targets are likewise resolved once in the typed snapshot,
not by either frontend.

An outstanding ask makes its local pi agent Waiting with the ask as its
source, and also appears in a separate snapshot list. The list matches the TUI's
`a` mode: stable id, agent display name, full question text (the TUI
renders its first line), and a live-pane association that distinguishes
ended asks. Agent session identity and creation time support stable
identity and ordering; ended and revivable report whether activation
would need revival and whether its directory/session file exist.
Paths remain private persistence details. The model polls revival
availability so removing a file changes the snapshot even without an
ask-file change. The client's location comes from its session's active pane, matching both
pane and session for linked windows. A modal pane (`display-popup` or
`display-menu`) is not a sidebar row, and the pane under it counts as the
client's pane. The last known location remains
while no matching active pane is available.

The first model tick emits a snapshot once a client location is known.
Subsequent ticks wait for relevant tmux control notifications or the poll
interval. Notifications are coalesced before reading fresh state; polling
also observes changes that have no tmux notification, including agent
reports and asks. `Sidebar.step` rebuilds on its snapshot change test or
when a command debounce or stall tracking comes due. RPC serializes rebuilt
models and sends only a line different from the last snapshot sent. A
rebuild with no wire-visible change produces nothing. This is a stream
of full current views, not a delta log or a record of every intermediate
transition.

Each pane item also carries `program_status`: the pane emission serial
and every OSC 7501 record, ordered by id, raw. Title and message are
decoded UTF-8; optional app is the record's own app, inherited by
consumers from the nearest ancestor with one, including root across
missing parents. Topology is authoritative: every topology read includes
`#{pane_program_status}` in `Tmux_pane.format`, parsed once into each pane,
for control-mode and one-shot views alike. `%program-status`
notifications only wake the tick; their payload is ignored.

The lifecycle is computed once per read by `Pane_status.observe`, which
keeps per-pane tracking across ticks in the model. Ended, for a run pane
with a recorded outcome or a dead pane, overrides any status; its result
is unknown until the outcome file exists, never inferred from the
process. Otherwise the pane's kind (design-program-status.md) carries its
status. An agent's status is waiting (an outstanding ask of a local pi,
which outranks blocked records, or a blocked record), stalled (a local
pi with a working root and a stale heartbeat, rebased against wake),
running or idle, in that precedence, with ties by bytewise record id
and the oldest of several asks. A shell's status is its OSC 133 phase plus a generic report, the same
reduction without asks or stall. Outcomes come from per-record transitions
into done or error, stamped with the read's pane serial, held pending
while other records still work and cleared by a new live episode; `since`
records when this feed first saw the current state. Tracking resets on an
agent's root app change (a terminal's report app is not tracked), a
State session change, an ssh destination change, a pane leaving a
successful read, and a changed server identity.

Messages come from the representative record (blocked, working, the
outcome's record, idle, then any), falling back to local pi's State
activity; a local pi message duplicating its title is dropped. pi State
records contain identity, session name, inbox, parentage, activity, model
and heartbeat, not status or completion. pi addressing uses its reported
session name, including when a nested program overwrites the OSC root.
Unnamed pi sessions are addressable only by id. Native agents without a
local pi State identity have no session id or inbox and are not listed by
list_runs; kido prompt can paste to them.

Seen state belongs to each frontend. The TUI marks the client's active
pane's current outcomes seen on every successful tick, keyed by outcome
source and serial, or a command exit's start and end; an exit that ended
before the TUI started counts as seen. Child record rows always show raw states. The
0.5s post-finish running hold, and drawing a run that starts inside it at
once, are the TUI's own remembered display, not wire state.

## Server identity

`server_instance` is tmux's `#{start_time}` and `#{pid}`, read with
`Tmux_pane.server` on the model's control connection once, and again
after each reconnect (`Tmux.Client.dials`). A failed read keeps
the last good identity and topology, sets `error`, and tracks nothing. No
snapshot is sent before the first good pair and topology. A pair that
changes between reads drops all tracking before the new read is tracked.
A control reconnect keeps the pair and therefore the tracking; a new RPC
process starts tracking afresh.

## Requests and navigation

Search is client-side. The model always contains all sessions; the TUI
keeps its search text locally and applies its pure fuzzy filter to
the session tree it renders. Matching uses session names, agent titles
and ssh destinations, and sorts matching sessions by score. Empty text
keeps the original ordering. An ssh destination is the typed `user@host`
of the pane kind, never remote command text. RPC accepts no filter
request and emits no filter field.

Switch-window and switch-session requests carry an integer id and a
`next` or `prev` direction. Each receives a correlated reply with the
switched session and window, null if there is no eligible target, or an
error. Switching uses fresh state through the same functions as the CLI,
not a client-provided ordering. A reply reports
the switch operation; it is not an accompanying post-switch snapshot.

Jump, activate-ask, delete-ask and release-side-focus also carry integer
ids and return correlated, typed results. Sidebar's request GADT and
handle function own these actions for both the TUI and RPC; Protocol
alone decodes JSON and encodes replies. Jump takes a full location and
validates it against fresh topology before switching, retaining the
session for linked windows. Ask activation takes an id, rereads the
authoritative ask, resolves its live holder or revives it, then jumps.
It prefers the current session's occurrence of a linked live pane.
Deletion uses human semantics and notifies the live asker best-effort.
Release changes tmux side-status keyboard focus, not frontend cursor or
OS focus. Every tmux call in these paths uses the model's explicit
socket, including revived window creation.

Search clearing after successful activation and standalone picker exit
remain TUI-local. Request errors and syscall failures are recoverable
at each frontend's execution boundary and do not occupy snapshot.error.
A revived window can outlive a failed subsequent jump: there is no
rollback or automatic replay. Concurrent views can still revive one
ended ask twice before a live holder reports. pi resolution retains
tmux's command-client PATH semantics.

Protocol 3.1 changes from 3.0:
- Added: reorder-session and reorder-window requests, replying `reordered`.
- Added: session order honours a session's `@kido-order` rank.

Protocol 3.0 changes from 2.1:
- Added: `server_instance`; no snapshot before the first valid identity.
- Changed: pane items are `kind` "pane" with a plain `title` and a typed
  `lifecycle` of kind, agent status or shell phase and report, outcomes
  and `since`.
- Removed: `tail`, span roles, `indicator`, `attention` and the ended-run
  caption; acknowledgement leaves kido's model for each frontend.

Protocol 2.1 changes from 2.0:
- Changed: pi row titles and addressing use the reported session name.
  Unnamed pi sessions display the pane-title label but are addressable only by id.
- Unchanged: wire shapes and snapshot v remain the same.

Protocol 2.0 changes from 1.1:
- Removed: the server-side filter request and top-level snapshot.filter.
  Snapshots contain all sessions; search is client-side.
- Added: new-window/new-session, select-window/select-session, jump,
  activate-ask/delete-ask and release-side-focus requests, using the
  existing integer-id reply and error envelopes. New-window takes a window
  id and inserts immediately after it, inheriting its active pane directory.
- Added: the top-level snapshot asks list and program_status on pane items.
- Changed: switch-window steps among direct siblings in feed order; prev
  from the first child selects its direct parent. Next from the last child
  steps from its top-level ancestor. Top-level steps skip run-marked windows,
  never descend, and wrap across sessions in sidebar order. The CLI and
  sidebar Shift-Up/Down keys share this order; a sole eligible root selects itself.
- Changed: pi item indicator, attention and caption use native OSC records;
  its title uses the pane title
  instead of State status/title/completion. Pi compaction is running with
  a message, not compacting. Gone runs outrank terminal status.
- Changed: pi stall requires a working root and stale State heartbeat;
  bare pi never stalls. Pi addressing uses the pane title verbatim. State supplies
  identity, inbox, parentage, activity and the ask overlay; agent-status
  removes --status, --ended and --title.
- Unchanged: switch-session requests and integer-correlated replies were
  already present in 1.1. Snapshot v remains 2.
No compatibility shims are provided.

Sessions with a rank, the session-scoped `@kido-order` user option, come
first by rank; the rest follow. Ties and unranked sessions are ordered
oldest first, with name breaking creation-time ties, so a new session
appends after the ranked ones. The rank is read in the topology format
like any other pane field, so a change refreshes snapshots and the TUI;
an empty or non-canonical value is unranked. It is read through the
ordinary format, so a global value would be inherited; kido only ever
sets it per session. It lives
as long as the tmux server, with no other copy.
Windows use the sidebar's parent-first tree ordering within each session,
starting from tmux window order; panes within a window are oldest first
by pane id. A child window anchors under the pane of its parent agent.
Missing anchors remain roots rather than dropping windows.

Window navigation first steps among a nested window's direct siblings in
feed order, including run windows. Prev from the first child selects its
direct parent, even when nested and run-marked. Next from the last child
steps from its top-level ancestor to the next top-level window. Top-level
steps never descend into children: they skip windows containing run-marked
panes and wrap across sessions in sidebar order. A sole eligible root can
select itself; no eligible root yields null. Siblings of a multi-pane
parent follow its panes' feed order, then each pane's child order.
These rules share Sidebar's typed Switch_window request across RPC, the CLI
and focused or unfocused sidebar Shift-Up/Down keys. Session navigation
remains independent: it wraps through the unfiltered session order and
preserves the target session's active window. A single session has no
session-switch target.

Invalid or unknown requests with integer ids get error replies. Invalid
JSON and requests without integer ids are ignored. Request errors do not end the stream. The stdin reader
thread only queues lines, EOF and read errors under a mutex. The tick
drains that queue and owns the control connection and stdout writer.
Replies and snapshots may alternate, but their JSON lines never
interleave bytes.

## Ending and recovering

Stdin EOF ends RPC with exit 0 after the tick drains queued input. A stdin
read error ends it with exit 1. Missing arguments, an absent server socket
or a missing named client also exit 1 with stderr diagnostics; option
parse errors are reported by cmdliner. Protocol mismatch exits 2 as
described above.

A transient tick failure occupies the snapshot's error field and the
stream continues; a successful tick clears it. A missing client is
terminal, including when the server disappears. RPC closes its control
connection on termination. Reconnecting belongs to the external client:
a new RPC subprocess performs a new hello and starts a new model.

## Limits of the surface

RPC exposes no TUI-local cursor, scroll, glyphs, seen state or layout,
and it does not synchronize those between views. Per-pane tracking belongs
to that subprocess, so two feeds can stamp one outcome with different
serials. Navigation includes shell/session creation, absolute window/session selection,
relative switches, pane activation, session and top-level window
reordering, ask activation/deletion and releasing tmux side-status keyboard focus,
not arbitrary tmux commands,
terminal output, pane geometry, run control or inbox delivery. The
contract's fork dependencies describe the separate tmux capabilities an
external client can use, not additional RPC messages.

Snapshot node ids are unique only within a session. A linked window and
its panes occur in each session with the same ids; clients key nodes by
session as well as node id. Moving a node within a session keeps its id.
Snapshots are current display state, not durable run history or a
transactional view of every underlying store.

## Creation and absolute selection

New_window and New_session return `(client, string) result`, as do
Select_window (a session/window pair) and Select_session (a session id).
All are Sidebar requests; Protocol owns their integer-id correlation and
wire representation.

New_window takes a window id and inserts immediately after that window
in its session with tmux new-window -a -t. Creation inherits the target
window's active pane cwd for a window, or the named client's current
session cwd for a session. It uses the server's default shell/command,
naming and indexing. Selection retains a window's
active pane and the requested session occurrence of a linked window.
Creation is detached, followed by a jump. Failure after creation identifies
the created location in the error and leaves the effect intact; reconnects
must fail pending callbacks rather than replay them. Directory lookup,
creation and selection all use the model's explicit socket.

## Reordering

Reorder_session and Reorder_window are Sidebar requests over a typed
move: source, anchor and Before or After. Both reread topology and check
the source and anchor against it, so the client's drag is only feedback.
Session order is rewritten whole: the source is placed beside its
anchor in the current order and every session gets a dense rank in one
tmux invocation, through `Tmux_pane.rank_sessions`, the module that also
reads the rank. Window order stays tmux's window index: only top-level roots of the
session's tree are movable, and a grouped session is refused, since a
move would change the other members' windows. `move-window -d -b/-a`
inserts beside the anchor, shifting every occupied index in the range,
nested run windows' included; the tree still hoists them under their
parent. tmux skips renumber-windows for a move with `-s`, so when the
session's option is on the handler compacts with `move-window -r`; off,
gaps stay. Moving the session's current window makes tmux select a
fallback; one chained tmux command checks whether the source is current,
moves it, and selects it again only in that case, so a concurrent
selection of another window is never undone. It switches no client and
selects no pane. Attached clients can see the fallback briefly.

## Client boundary

A client uses rpc plus its own tmux control client. Navigation and shell
creation use rpc; terminal I/O, content and geometry use the control
client. Starting or inspecting a server with `kido server` and transport
setup such as ssh come before rpc exists.
