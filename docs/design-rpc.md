# The RPC protocol

`kido rpc` lets an external client such as Kido.app monitor one kido server
and navigate its sessions and windows. It is a subprocess protocol over
stdio, not a socket service. stdin carries requests. stdout carries
newline-delimited JSON events. The client keeps stdin open while the feed
runs and reads stdout continuously.

[The wire contract](../share/rpc/contract.md) is the authoritative source
for exact message shapes, fields, enum values and fork dependencies.
Lint and tests enforce that contract. This document describes the model
and its lifecycle without repeating the schema.

## Selecting a server and client

The invocation is `kido rpc --server DIR --client NAME`. `DIR` selects the
state directory and its `socket`. `NAME` is the tmux client whose current
location the feed follows. RPC does not create that client or start a
server. It can run outside tmux without creating `TMUX`. An external
client runs it without `KIDO_AGENT_*` environment variables.

Without `--server`, resolution uses these sources in order:

1. The pane's tmux socket directory, if it follows the convention.
2. `KIDO_STATE_DIR`.
3. `XDG_STATE_HOME/kido`.
4. `~/.local/state/kido`.

The launcher, `kido server`, and the switch commands use the same
resolution. Both the control connection and the model's one-shot tmux
calls use the explicit socket.

`kido server --server DIR` makes sure a detached server exists.
It returns the tmux executable and socket paths with `protocol`, `server`
and `expected`.

- `protocol` is always the binary's `Protocol.value` string.
- `server` is always present, even when it matches. It is the creating
  server's global `KIDO_SERVER` stamp, or null if unset.
- `expected` is the binary's own stamp, `Launch.stamp`.

Making sure an existing server exists, or attaching it, does not change
its stamp. The binary build id from `kido --version` is a separate value,
not a protocol version.

## Compatibility before snapshots

`Protocol.value` is the binary's MAJOR.MINOR protocol constant, currently
`4.0`. It versions only the RPC surface between the binary and its client,
not anything in the tmux server. Thus, changing it never requires a
server restart.

The server uses a separate stamp, `Launch.stamp`. It contains the first
12 hex digits of an MD5 over:

- The fork revision pinned by the build.
- The `server.conf` that `Launch.server_conf` writes.
- The environment that `Launch.server_env` gives the server.

The latter two use fixed placeholder paths and a placeholder environment.
Thus, the stamp excludes the inherited user environment. The code derives
the stamp. Nobody changes it manually.

These changes change the stamp:

- A fork revision change.
- A change to `kido-tmux.conf`.
- A change to the generated template.
- A change to the environment values that the launcher sets.

The installation paths do not change the stamp: the kido executable,
its bin directory, and the user's `kido.conf`.

The build gets the revision from
`scripts/install-tmux-fork.sh --print-revision`, which reads the gitlink.
Thus, it needs the git checkout that the fork build already needs.
At creation, the launcher writes the stamp to the tmux server's global
`KIDO_SERVER` before the configuration runs. RPC checks that stamp before
it opens the model's control connection.

The first stdout event is a hello with the binary protocol. If the server
stamp equals the binary's stamp, the hello contains nothing else.
If the server stamp differs or is absent, the hello adds:

- `server`: the server's stamp or null.
- `expected`: the binary's stamp.

RPC then writes an error event and exits 2. On that path, it processes
no snapshots or requests. There is no compatibility negotiation.

Additional fields and enum values increase the minor version.
These changes increase the major version:

- Removing a field.
- Renaming a field.
- Changing a field's meaning.
- Changing a reply shape.

Clients ignore unknown fields and handle unknown enum values.
Snapshots keep `v:2` as their schema marker. Hello controls the whole RPC
surface, including requests and replies. The contract also specifies
the fork behaviours that clients require.

Before it accepts snapshots, Kido.app checks that hello is first and its
protocol is compatible. A rejected or incompatible hello stops the feed
and reports a protocol mismatch. The client does not retry it as a
transient failure.

An ordinary disconnect or unreadable event causes a new subprocess
connection, with exponential backoff limited to eight seconds.
A snapshot resets the backoff. On reconnect, the client fails pending
requests instead of replaying them.

## One model, two views

`Sidebar` controls the tick, per-pane tracking, and the typed session and
node tree. `Pane_status` controls a pane's typed status and its tracking.
RPC serializes that model. `Kido_sidebar` in `bin/` draws it with Mosaic.
`lib/` has no TUI dependencies.

The model reports classification and semantic status, never presentation
or acknowledgement. It has no width, colour, layout, glyph, caption, span
or seen state.

Each frontend:

- Makes labels and captions from the plain title and typed status.
- Selects glyphs and a palette.
- Controls its seen outcomes.
- Derives bracket and continuation columns from the same tree.

RPC sends complete text. The external view truncates and styles it.

The tick reads tmux topology, live agent reports, process information,
run metadata and outstanding asks. Only root apps `pi` and `claude-code`
identify agents. A pane run supplies local pi identity but does not
identify an agent pane. The tick also performs the reap sweep. These operations
are idempotent when a TUI sidebar runs beside RPC.

The feed is not a passive file reader. RPC uses the default 100ms
interval. Stall and linger settings come from the RPC process environment
through the same option readers as the TUI. They do not come from
requests or per-client tmux options.

## Whole snapshots

A snapshot contains the named client's session, window and pane location,
a transient error, and sessions in display order. Each session contains
its name, current marker and a tree of nodes. A multi-pane window is a
window group that contains pane items. A one-pane window is an item
directly.

Each pane item contains:

- A plain title.
- A lifecycle: Ended with its run result, or Live with the pane kind and
  its status.
- Its raw records.
- Run metadata.
- Child windows placed under it.

Child windows stay within a session.

Run classification distinguishes subagents, plain bash and streamed bash,
including ended or lingering panes. A live run contains its metadata start
time while its pane is alive and no outcome is recorded. This is independent
of activity text or agent status. Ended runs, top-level agents, shells
and ssh have no run start time.

Clients calculate elapsed time locally. A running clock does not produce
a snapshot every second. For runs with no message or progress, the TUI
shows an elapsed caption. It schedules its own redraw at the next second
boundary.

`Sidebar` derives run kind and the optional running start time once in
its typed rows. It also resolves ask targets once in the typed snapshot.
Neither frontend performs these operations.

An outstanding ask makes its local pi agent Waiting, with the ask as its
source. The ask also appears in a separate snapshot list.
The list matches the TUI's `a` mode:

- Stable id.
- Agent display name.
- Full question text. The TUI shows its first line.
- A live-pane association that distinguishes ended asks.

Agent session identity and creation time support stable identity and
ordering. Ended and revivable report whether activation needs revival
and whether its directory/session file exist. Paths remain private
persistence details. The model polls revival availability. Thus, removing
a file changes the snapshot even without an ask-file change.

The client's location comes from its session's active pane.
For linked windows, it matches both pane and session. A modal pane
(`display-popup` or `display-menu`) is not a sidebar row.
The pane under it counts as the client's pane. While no matching active
pane is available, the last known location remains.

The first model tick emits a snapshot once a client location is known.
Subsequent ticks wait for relevant tmux control notifications or the poll
interval. The tick combines notifications before it reads fresh state.
Polling also observes changes without tmux notifications, including agent
reports and asks.

`Sidebar.step` rebuilds when its snapshot change test detects a change,
or when a command debounce or stall tracking becomes due. RPC serializes
rebuilt models. It sends a line only if it differs from the last snapshot
sent. A rebuild with no wire-visible change produces nothing.
The stream contains full current views, not a delta log or a record of
every intermediate transition.

Each pane item also contains `program_status`: the pane emission serial
and every raw OSC 7501 record, ordered by id. Title and message are
decoded UTF-8. Optional app is the record's own app. Consumers inherit app
from the nearest ancestor with one, including root across missing parents.

Topology is the authoritative source. Every topology read includes
`#{pane_program_status}` in `Tmux_pane.format` and parses it once into
each pane. This applies to control-mode and one-shot views.
`%program-status` notifications only wake the tick. The tick ignores
their payload.

`Pane_status.observe` calculates the lifecycle once per read.
It keeps per-pane tracking across ticks in the model.
For a run pane with a recorded outcome or a dead pane, Ended overrides
any status. Its result is unknown until the outcome file exists.
The model never infers the result from the process. Otherwise, the
pane's kind (design-program-status.md) contains its status.

An agent's status uses this precedence:

1. Waiting: an outstanding ask of a local pi, or a blocked record.
   The outstanding ask has precedence over blocked records.
2. Stalled: a local pi with a working root and a stale heartbeat,
   rebased against wake.
3. Running.
4. Idle.

Bytewise record id resolves ties. For several asks, the oldest has
precedence. A shell's status is its OSC 133 phase plus a generic report.
It uses the same reduction without asks or stall.

Outcomes come from per-record transitions into done or error.
They have the read's pane serial and remain pending while other records
still work. A new live episode clears them. `since` records when this
feed first observes the current state.

Tracking resets on:

- An agent's root app change. The model does not track a terminal's report app.
- A change of the pane's run.
- An ssh destination change.
- A pane leaving a successful read.
- A changed server identity.

Messages come from the representative record: blocked, working, the
outcome's record, idle, then any. If that record supplies no message,
local pi's run activity supplies it. The model removes a local pi
message that repeats its title.

pi run records (`meta.json` and `pi.json`) contain identity, session
name, inbox, parentage, activity, model and heartbeat, not status or
completion. pi addressing
uses its reported session name, including when a nested program
overwrites the OSC root. Unnamed pi sessions are addressable only by id.
Native agents without a pane run have no session id or inbox. `list_runs` does not list them. `kido prompt` can paste to them.

Each frontend controls seen state. On every successful tick, the TUI
marks the client's active pane's current outcomes seen. It keys them by
outcome source and serial, or a command exit's start and end.
An exit that ends before the TUI starts counts as seen.
Child record rows always show raw states.

The TUI remembers its 0.5s running hold after a run finishes.
It immediately draws a run that starts during that hold.
These are display state, not wire state.

## Server identity

`server_instance` is tmux's `#{start_time}` and `#{pid}`.
The model reads it once with `Tmux_pane.server` on its control connection,
and again after each reconnect (`Tmux.Client.dials`).

A failed read keeps the last good identity and topology, sets `error`,
and tracks nothing. The model sends no snapshot before the first good
pair and topology. If the pair changes between reads, the model removes
all tracking before it tracks the new read. A control reconnect keeps
the pair and thus the tracking. A new RPC process starts new tracking.

## Requests and navigation

Search is client-side. The model always contains all sessions.
The TUI keeps its search text locally and applies its pure fuzzy filter
to the session tree it draws. Matching uses session names, agent titles
and ssh destinations. It sorts matching sessions by score.
Empty text keeps the original order.

An ssh destination is the typed `user@host` of the pane kind, never
remote command text. RPC accepts no filter request and emits no filter
field.

Switch-window and switch-session requests contain an integer id and a
`next` or `prev` direction. Each receives a correlated reply with one of
these results:

- The switched session and window.
- Null, if there is no eligible target.
- An error.

Switching uses fresh state through the same functions as the CLI,
not an order from the client. A reply reports the switch operation.
It is not an accompanying post-switch snapshot.

Jump, activate-ask, delete-ask and release-side-focus also contain integer
ids and return correlated, typed results. `Sidebar`'s request GADT and
handle function control these actions for the TUI and RPC.
Only `Protocol` decodes JSON and encodes replies.

Jump takes a full location and validates it against fresh topology before
switching. It keeps the session for linked windows.
Ask activation takes an id, rereads the authoritative ask, resolves its
live holder or revives it, then jumps.
It prefers the current session's occurrence of a linked live pane.

Deletion uses human semantics and notifies the live asker best-effort.
Release changes tmux side-status keyboard focus, not the frontend cursor
or OS focus. Every tmux call in these paths uses the model's explicit
socket, including revived window creation.

Search clearing after successful activation and standalone picker exit
remain TUI-local. Each frontend can recover from request errors and
syscall failures at its execution boundary. These failures do not occupy
`snapshot.error`.

A revived window can remain after a later jump fails.
There is no rollback or automatic replay. Concurrent views can still
revive one ended ask twice before a live holder reports.
pi resolution keeps tmux's command-client `PATH` semantics.

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
  id and inserts immediately after it. It inherits that window's active
  pane directory.
- Added: the top-level snapshot asks list and program_status on pane items.
- Changed: switch-window steps among direct siblings in feed order; prev
  from the first child selects its direct parent. Next from the last child
  steps from its top-level ancestor. Top-level steps skip run-marked windows,
  never descend, and wrap across sessions in sidebar order. The CLI and
  sidebar Shift-Up/Down keys share this order. A sole eligible root selects itself.
- Changed: pi item indicator, attention and caption use native OSC records.
  Its title uses the pane title instead of a reported status/title/completion.
  Pi compaction is running with a message, not compacting.
  Gone runs have precedence over terminal status.
- Changed: pi stall requires a working root and a stale run heartbeat.
  Bare pi never stalls. Pi addressing uses the pane title without changes.
  The pane run supplies identity, inbox, parentage, activity and the ask overlay.
  `agent-status` removes `--status`, `--ended` and `--title`.
- Unchanged: switch-session requests and integer-correlated replies were
  already present in 1.1. Snapshot v remains 2.
There are no compatibility shims.

Sessions with a rank come first, in rank order. The rank is the
session-scoped `@kido-order` user option. The other sessions follow.
Ties and unranked sessions use oldest-first order. Names resolve
creation-time ties. Thus, a new session follows the ranked sessions.

The topology format reads the rank like any other pane field.
A rank change refreshes snapshots and the TUI. An empty or non-canonical
value is unranked. The ordinary format would inherit a global value,
but kido only sets the option per session. It exists as long as the tmux
server, with no other copy.

Within each session, windows use the sidebar's parent-first tree order,
starting from tmux window order. Panes within a window use oldest-first
order by pane id. A child window has its anchor under its parent agent's
pane. Windows with missing anchors remain roots; the model does not
remove them.

Window navigation first steps among a nested window's direct siblings in
feed order, including run windows. Prev from the first child selects its
direct parent, even when nested and run-marked. Next from the last child
steps from its top-level ancestor to the next top-level window.

Top-level steps never descend into children. They skip windows that
contain run-marked panes and wrap across sessions in sidebar order.
A sole eligible root can select itself. If there is no eligible root,
the result is null. Siblings of a multi-pane parent follow its panes'
feed order, then each pane's child order.

These rules use `Sidebar`'s typed `Switch_window` request across:

- RPC.
- The CLI.
- Sidebar Shift-Up/Down keys, with or without keyboard focus.

Session navigation remains independent. It wraps through the unfiltered
session order and keeps the target session's active window.
A single session has no session-switch target.

Invalid or unknown requests with integer ids receive error replies.
RPC ignores invalid JSON and requests without integer ids.
Request errors do not end the stream. The stdin reader thread only
queues lines, EOF and read errors under a mutex. The tick drains that
queue and controls the control connection and stdout writer.
Replies and snapshots can alternate, but their JSON lines never
interleave bytes.

## Ending and recovering

Stdin EOF ends RPC with exit 0 after the tick drains queued input.
A stdin read error ends it with exit 1.
These conditions also cause exit 1 with stderr diagnostics:

- Missing arguments.
- An absent server socket.
- A missing named client.

cmdliner reports option parse errors. Protocol mismatch causes exit 2
as described above.

A transient tick failure occupies the snapshot's error field.
The stream continues, and a successful tick clears the error.
A missing client ends the stream, including when the server disappears.
On termination, RPC closes its control connection.

The external client controls reconnecting. A new RPC subprocess performs
a new hello and starts a new model.

## Limits of the surface

RPC exposes no TUI-local cursor, scroll, glyphs, seen state or layout.
It does not synchronize these between views. Per-pane tracking belongs
to that subprocess. Thus, two feeds can stamp one outcome with different
serials.

Navigation includes:

- Shell/session creation.
- Absolute window/session selection.
- Relative switches.
- Pane activation.
- Session and top-level window reordering.
- Ask activation/deletion.
- Release of tmux side-status keyboard focus.

It does not include:

- Arbitrary tmux commands.
- Terminal output.
- Pane geometry.
- Run control.
- Inbox delivery.

The contract's fork dependencies describe separate tmux capabilities
that an external client can use, not additional RPC messages.

Snapshot node ids are unique only within a session. A linked window and
its panes occur in each session with the same ids. Clients key nodes by
session and node id. Moving a node within a session keeps its id.
Snapshots are current display state, not durable run history or a
transactional view of every underlying store.

## Creation and absolute selection

`New_window` and `New_session` return `(client, string) result`.
`Select_window` (a session/window pair) and `Select_session` (a session id)
return the same type. All are `Sidebar` requests. `Protocol` controls
their integer-id correlation and wire representation.

`New_window` takes a window id. It inserts immediately after that window
in its session with `tmux new-window -a -t`. Window creation inherits the
target window's active pane cwd. Session creation inherits the named
client's current session cwd. Creation uses the server's default
shell/command, naming and indexing.

Selection keeps a window's active pane and the requested session
occurrence of a linked window. Creation is detached, followed by a jump.
If creation succeeds but a later operation fails, the error identifies
the created location. The created location remains. On reconnect,
clients must fail pending callbacks instead of replaying them.

Directory lookup, creation and selection all use the model's explicit
socket.

## Reordering

`Reorder_session` and `Reorder_window` are `Sidebar` requests over a
typed move: source, anchor and `Before` or `After`. Both reread topology
and check the source and anchor against it. Thus, the client's drag is
only feedback.

The handler rewrites the complete session order. It places the source
beside its anchor in the current order. Every session receives a dense
rank in one tmux invocation through `Tmux_pane.rank_sessions`.
That module also reads the rank.

Window order remains tmux's window index. Only top-level roots of the
session's tree can move. The handler refuses a grouped session because
a move would change the other members' windows.
`move-window -d -b/-a` inserts beside the anchor. It shifts every occupied
index in the range, including nested run windows' indices.
The tree still places these windows under their parent.

For a move with `-s`, tmux skips `renumber-windows`.
If the session's option is on, the handler compacts with `move-window -r`.
If it is off, gaps remain.

Moving the session's current window makes tmux select a fallback.
One chained tmux command checks whether the source is current, moves it,
and selects it again only in that case. Thus, it never reverses a
concurrent selection of another window. It switches no client and
selects no pane. Attached clients can see the fallback briefly.

## Client boundary

A client uses RPC and its own tmux control client. Navigation and shell
creation use RPC. Terminal I/O, content and geometry use the control
client. Server start or inspection with `kido server`, and transport
setup such as ssh, occur before RPC exists.
