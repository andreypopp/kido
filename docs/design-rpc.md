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
executable and socket paths alongside `protocol` and `server`. `protocol`
is always the binary's `Protocol.value` string. `server` is always present:
the creating server's global `KIDO_PROTOCOL` stamp, or null when unset,
even when it matches `protocol`. Ensuring or attaching an existing server
does not change its stamp. The binary build id from `kido --version` is a
separate value, not a protocol version.

## Compatibility before snapshots

`Protocol.value` is the binary's MAJOR.MINOR protocol constant, currently
`1.1`. The launcher stamps it into the tmux server's environment at
creation, before its configuration runs. RPC probes that stamp before
opening the model's control connection.

The first stdout event is a hello carrying the binary protocol. If the
stamp matches exactly, the hello omits `server`. If it differs or is
absent, the hello includes the server stamp or null, then RPC writes an
error event and exits 2. There are no snapshots or requests processed on
that path. Exact minor equality is required as well as major equality;
there is no compatibility negotiation.

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
and node tree. RPC serializes that model; `Ui` draws it with Mosaic. The
model has no width, colour or layout. The TUI owns its cursor, scroll and
keys, maps roles to styles and indicators to glyphs, and derives bracket
and continuation columns from the same tree. RPC sends uncut text and
semantic roles, not glyph strings; the external view truncates and
styles it.

The tick reads tmux topology, live agent reports, process information,
run metadata and outstanding asks. It also performs the reap sweep and
Claude waiting-screen probes. These operations are idempotent with a TUI
sidebar running beside RPC; the feed is not a passive file reader.
RPC uses the default 100ms interval. Stall and linger knobs come from the
RPC process environment, through the same option readers as the TUI,
not through requests or per-client tmux options.

## Whole snapshots

A snapshot holds the named client's session, window and pane location,
a transient error, and sessions in display order.
Each session holds its name, current marker and a tree of nodes. A
multi-pane window is a window group containing pane items; a one-pane
window is an item directly. Items distinguish agents, async bash runs,
ssh and shells, with indicators, title and tail spans, and child windows
hoisted under their parent's pane. Hoisting stays within a session.

Run classification distinguishes subagents, plain bash and streamed bash,
including ended or lingering panes. A live run carries its metadata start
time while its pane is alive and no outcome is recorded, independently
of activity text or agent status. Ended runs, top-level agents, shells
and ssh have no run start time. Clients compute elapsed time locally;
a running clock does not produce a snapshot every second. The TUI shows
an elapsed caption for runs without activity text and schedules its own
redraw at the next second boundary.

Outstanding asks affect agent waiting indicators and the attention flag
and appear in a separate snapshot list. The list matches the TUI's
`a` mode: stable id, agent display name, full question text (the TUI
renders its first line), and a live-pane association that distinguishes
ended asks. Agent session identity and creation time support stable
identity and ordering; ended and revivable report whether activation
would need revival and whether its directory/session file exist.
Paths remain private persistence details. The model polls revival
availability so removing a file changes the snapshot even without an
ask-file change. Attention uses the same model
predicate as the TUI's attention navigation: an outstanding ask, a waiting
agent, or an idle agent that completed since this view last visited it.
The client's location comes from its session's active pane, matching both
pane and session for linked windows. The last known location remains
while no matching active pane is available.

The first model tick emits a snapshot once a client location is known.
Subsequent ticks wait for relevant tmux control notifications or the poll
interval. Notifications are coalesced before reading fresh state; polling
also observes changes that have no tmux notification, including agent
reports and asks. `Sidebar.step` rebuilds on its snapshot change test or
when shell debounce or stall tracking comes due. RPC serializes rebuilt
models and sends only a line different from the last snapshot sent. A
rebuild with no wire-visible change produces nothing. This is a stream
of full current views, not a delta log or a record of every intermediate
transition.

## Requests and navigation

Search is client-side. The model always contains all sessions; the TUI
keeps its search text locally and applies Sidebar's pure fuzzy filter to
the session tree it renders. Matching uses session names, agent titles
and ssh destinations, and sorts matching sessions by score. Empty text
keeps the original ordering. Agent titles are row title spans; an ssh
destination is the host span following the "ssh " prefix, excluding any
remote command text. RPC accepts no filter request and emits no filter
field.

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

The new requests and asks list retain protocol 1.1 for this development
phase; the version bump will be batched with OSC 7501.

Sessions are ordered oldest first, with name breaking creation-time ties.
Windows use the sidebar's parent-first tree ordering within each session,
starting from tmux window order; panes within a window are oldest first
by pane id. A child window anchors under the pane of its parent agent.
Missing anchors remain roots rather than dropping windows.

Window navigation walks that flat tree order across session boundaries
and wraps. Ordinary next/prev targets skip windows containing run-marked
panes. The nested-window anchor rule is the exception: prev from a
hoisted child targets its direct parent's window, even if that parent is
itself hoisted and run-marked. Next from a hoisted window follows the
ordinary walk. Session navigation wraps through the unfiltered session
order and preserves the target session's active window. A single session
has no session-switch target.

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

RPC exposes no TUI-local cursor, scroll, glyphs or layout,
and it does not synchronize those between views. Per-pane tracking belongs
to that subprocess. Navigation includes shell/session creation, absolute window/session selection,
relative switches, pane activation,
ask activation/deletion and releasing tmux side-status keyboard focus,
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

Creation inherits the target session's active pane cwd for a window, or
the named client's current session cwd for a session. It uses the server's
default shell/command, naming and indexing. Selection retains a window's
active pane and the requested session occurrence of a linked window.
Creation is detached, followed by a jump. Failure after creation identifies
the created location in the error and leaves the effect intact; reconnects
must fail pending callbacks rather than replay them. Directory lookup,
creation and selection all use the model's explicit socket.

## Client boundary

A client uses rpc plus its own tmux control client. Navigation and shell
creation use rpc; terminal I/O, content and geometry use the control
client. Starting or inspecting a server with `kido server` and transport
setup such as ssh come before rpc exists.
