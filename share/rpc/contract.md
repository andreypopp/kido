# kido rpc protocol 4.0

fork revision: 336cb9a1d437a52ec03a0f8dba7538ccb586f1c5

Protocol.value is the binary's protocol constant. It versions this RPC
surface only; the server's compatibility is a separate stamp (below), so a
protocol bump never requires restarting the tmux server. New fields and new enum values are MINOR changes:
the app ignores unknown fields and decodes unknown enum values as unknown.
Removing or renaming a field, changing its meaning, or changing a reply
shape is MAJOR. Snapshots retain "v":2 as a schema marker; hello governs
compatibility for the entire RPC surface.

## Invocation and hello

    kido rpc --server <dir> --client <name>

The private, user-owned server directory contains socket. --server defaults
to the pane's convention-following TMUX socket directory, KIDO_STATE_DIR,
XDG_STATE_HOME/kido, then ~/.local/state/kido. --client names the app's
control client. Socket paths fit the platform's sun_path including NUL.
Run outside tmux with no KIDO_AGENT_* environment.

The launcher stamps the server's global KIDO_SERVER environment at creation
with the binary's server stamp: 12 hex digits digesting the pinned fork
revision, the server.conf the launcher generates and the environment changes
it makes to the server's (dropping KIDO_STATE_DIR, putting its bin directory
first on PATH), all with fixed placeholder paths. Install paths do not change
it; a fork bump, an edit to kido-tmux.conf, to the generated configuration or
to the launch environment does.

The first stdout line is {"hello":{"protocol":"4.0"}} when KIDO_SERVER equals
the binary's stamp. A differing or absent stamp produces
{"hello":{"protocol":"4.0","server":"other","expected":"0123456789ab"}} or
{"hello":{"protocol":"4.0","server":null,"expected":"0123456789ab"}}, followed
by {"error":"server stamp does not match binary stamp"}, then exit 2.
expected is the binary's stamp; the server needs a restart.
Exit 0 means stdin EOF. Exit 1 means a missing argument, absent server/client,
or stdin read error; diagnostics use stderr. Option errors use cmdliner.
Transient tick errors occupy snapshot.error and do not stop the stream.
The tick also performs idempotent reap.

## Requests and replies

Stdin is one JSON object per line. Search is client-side; filter requests
are unknown requests.
{"id":7,"switch-window":{"direction":"next"}} or direction "prev" uses the
same fresh-state navigation as the CLI and sidebar keys. A nested window
steps to its adjacent direct sibling in feed order, including run windows.
Prev from the first child selects its direct parent, even a nested run
window. Next from the last child steps from its top-level ancestor to the
next top-level window. Top-level steps never descend into children: they
skip windows containing run-marked panes and wrap across all sessions in
sidebar order.
A successful switch replies
{"reply":{"id":7,"switched":{"session":"$3","window":"@12"}}}.
{"id":7,"switch-session":{"direction":"next"}} or direction "prev" uses the
same session ordering as the sidebar and CLI, wrapping at either end. Its
reply has the same switched session and window shape.
No eligible target replies
{"reply":{"id":7,"switched":null}}. A sole eligible top-level window can
select itself; a single session has no switch-session target.
An invalid or unknown request carrying an integer id replies
{"reply":{"id":7,"error":"invalid or unknown request"}}; requests without an
integer id and invalid JSON are ignored. Errors do not stop the stream.
Pane activation preserves the session, including linked windows:
{"id":8,"jump":{"session":"$3","window":"@12","pane":"%9"}}
replies {"reply":{"id":8,"jumped":{"session":"$3","window":"@12","pane":"%9"}}}.
The full location must exist in fresh server topology; invalid membership
returns an error without switching. Jump selects the pane and releases
the named client's side-status keyboard focus.

{"id":9,"activate-ask":"A12345678"} resolves the authoritative ask by id,
jumps to its live session's pane, or revives pi from its saved session file
in its recorded cwd, in the named client's current tmux session. A live
pane linked into that session stays there; otherwise its first session
occurrence is selected. Success replies
{"reply":{"id":9,"activated":{"session":"$3","window":"@12","pane":"%9"}}}.
A missing ask, cwd, session file or pane returns an error. Revival does
not remove the ask. Creation followed by a failed jump is not rolled back
or retried. pi is resolved through the tmux command client's PATH.

{"id":10,"delete-ask":"A12345678"} removes the ask as the user and sends
the asking agent a best-effort removal note through its live inbox.
Success replies {"reply":{"id":10,"deleted":true}}; a missing ask errors.
{"id":11,"release-side-focus":true} releases the named tmux client's
side-status keyboard focus and replies {"reply":{"id":11,"released":true}}.
All four requests require integer ids, use the existing error envelope,
and keep the stream alive on errors. No cursor or OS focus is affected.
Jump's payload has exactly the three identifier fields; ask ids follow
the ask tool's syntax. Release accepts only true. Multiple recognized
operations in one object are invalid. Outer extra fields are ignored.

Creation and absolute window/session selection also require integer ids:
{"id":12,"new-window":"@12"} creates a detached default-shell window
immediately after @12 in @12's session (new-window -a -t @12), then selects
it for the named client and releases side focus.
{"id":13,"new-session":true} creates a detached session with a default-shell
window, then selects it and releases side focus. Both reply with
{"reply":{"id":12,"created":{"session":"$3","window":"@13","pane":"%10"}}}.
The new session replies with its newly allocated session id instead.

New-window inherits the target window's active pane directory. New-session
inherits the named client's current session's active pane directory. Both
resolve that directory on the server at execution, use tmux's configured
default shell/command, and let tmux allocate names and indexes. No local
frontend home, command, environment or cwd is supplied. A missing window, session,
client or directory is an error, not permission to create elsewhere.
Creation and selection are separate effects: a selection failure returns
an error identifying the created session/window/pane. The created shell
is not rolled back, and clients must not replay the request on reconnect.

{"id":14,"select-window":{"session":"$3","window":"@13"}} validates
fresh session/window membership and selects that window's active pane,
not its first pane. The session qualifies linked windows.
{"id":15,"select-session":"$3"} selects that session's active window and
pane using fresh server state. Both release side focus and reply with
{"reply":{"id":14,"selected":{"session":"$3","window":"@13","pane":"%10"}}}.
These replies report the operation, not a promised subsequent snapshot.
New-window accepts only a tmux window id (@ followed by digits),
select-session only a tmux session id ($ followed by digits), new-session
only true, and select-window exactly session and
window identifier fields ($N and @N). Multiple recognized operations are
invalid. All requests use the existing error envelope and explicit socket.

Reordering also requires integer ids and commits one drop per request:
{"id":51,"reorder-session":{"session":"$3","relative-to":"$1","placement":"before"}}
{"id":52,"reorder-window":{"session":"$3","window":"@12","relative-to":"@9","placement":"after"}}
placement is "before" or "after"; every field is required and no other
field is accepted. Success replies {"reply":{"id":51,"reordered":true}}.
Both validate against fresh server topology: source and anchor must exist
and differ ("no such session", "no such top-level window in session",
"cannot reorder relative to itself"). Reorder-session places the source
session before or after the anchor in session order, then writes dense
ranks 0..n-1 to every current session as its session-scoped @kido-order
option. Reorder-window requires the window and the anchor to be top-level
roots of that session's tree, never a window nested under its parent
agent nor another session's window, and refuses a grouped session ("cannot
reorder windows in a grouped session") before changing anything. It runs
move-window -d -b (before) or -a (after) -s '$S:@src' -t '$S:@anchor',
which shifts every occupied index in the range, nested windows' included;
the tree still hoists them under their parent. When the session's
renumber-windows is on, move-window -r -t '$S' follows; off, gaps stay.
When the moved window was the session's current window, select-window
selects it again in the same tmux command; attached clients can briefly
see the fallback. No client is switched and no pane is selected.

## Changes from 3.1 to 4.0

- Changed: the server's compatibility is the KIDO_SERVER stamp, derived
  from the fork revision and the generated server.conf, instead of
  KIDO_PROTOCOL holding Protocol.value. An RPC-only bump no longer needs a
  server restart.
- Changed: a refused hello carries `server` (the server's stamp or null)
  and `expected` (the binary's stamp).
- Changed: `kido server` reports `server` as the KIDO_SERVER stamp and adds
  `expected`.
- Unchanged: requests, replies, snapshot shapes and v.

## Changes from 3.0 to 3.1

- Added: reorder-session and reorder-window requests with the
  `reordered` reply.
- Added: a session's @kido-order rank orders ranked sessions first;
  unranked sessions keep creation-time/name order after them.
- Unchanged: snapshot shapes and v.

## Changes from 2.1 to 3.0

- Added: top-level `server_instance` (tmux start time and pid); no snapshot
  before the first valid pair and topology.
- Changed: pane items have `kind` "pane", a plain string `title` and a
  typed `lifecycle`: Ended with its run result, or Live with the pane kind
  (Terminal, Some_agent, Pi_agent, Ssh with typed destination) and its
  agent status or shell phase and generic report, each with `since`.
- Removed: `tail`, span roles, `indicator`, `attention` and the
  ended-run caption. Frontends compose labels, captions and glyphs,
  and own seen state; kido acknowledges nothing, and child
  records are raw.
- Changed: an unrecognized OSC 7501 blocked kind is dropped, not a parse error.
- Unchanged: requests, replies, asks, sessions, groups, ordering and
  snapshot v.

## Changes from 2.0 to 2.1

- Changed: pi row titles and addressing use the reported session name.
  Unnamed pi sessions display the pane-title label but are addressable only by id.
- Unchanged: wire shapes and snapshot v remain the same.

## Changes from 1.1 to 2.0

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
- Changed: pi item indicator, attention and caption use pi's native OSC
  records instead of State status/completion; the title uses the pane title.
  Pi compaction is running with
  a message, not compacting. Gone runs outrank terminal status.
- Changed: pi stall requires a working root and stale State heartbeat;
  bare pi never stalls. Pi addressing uses the State session name. State supplies
  identity, inbox, parentage, activity and the ask overlay; agent-status
  removes --status, --ended and --title.
- Unchanged: switch-session requests and integer-correlated replies were
  already present in 1.1. Snapshot v remains 2.

No compatibility shims are provided.

All stdout events are NDJSON from one writer; replies and snapshots can
alternate, but bytes from separate lines do not interleave.

## stdout: NDJSON, one full snapshot per model change

After hello, a full snapshot is emitted when visible model data changes.
None is emitted before the first valid server identity and topology read:

```json
{
  "v": 2,
  "server_instance": { "started_at": 1780000000, "pid": 12345 },
  "client": { "session": "$1", "window": "@2", "pane": "%3" },
  "asks": [],
  "error": null,
  "sessions": [
    {
      "id": "$1",
      "name": "main",
      "current": true,
      "nodes": [
        {
          "kind": "pane",
          "id": "%3",
          "pane": "%3",
          "window": "@2",
          "title": "kido",
          "lifecycle": ["Live", ["Pi_agent", {"id": "pi-session-id", "status": {"since": 1780000000.5, "msg": "fixing tests", "state": ["Running", {"progress": null}]}}]],
          "program_status": { "serial": 4, "records": [ { "id": "", "state": "working", "app": "pi" } ] },
          "run": null,
          "started": null,
          "children": [
            {
              "kind": "window",
              "id": "@7",
              "window": "@7",
              "name": "agents",
              "children": [
                { "kind": "pane", "id": "%9", "pane": "%9", "window": "@7", "...": "...", "children": [] },
                { "kind": "pane", "id": "%10", "pane": "%10", "window": "@7", "...": "...", "children": [] }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

- **`server_instance`**: the tmux server's `#{start_time}` (whole seconds,
  the server's own start) and `#{pid}`, both positive integers, read
  together on the RPC's explicit socket once per control connection,
  and again after each reconnect. The pair tells ordinary
  same-second restarts apart, but pid reuse within the same start second
  can collide, and it is not unique across hosts or restored environments.
  A changed pair means a new server: the feed drops its tracking, and a
  frontend drops its seen and posted state for that destination.
- **`client`**: the named client's current session, window and pane ids.
- **`asks`**: outstanding asks in creation-time/id order, including ended
  sessions. Each entry has `id`, agent `session`, display `name`, full
  `text`, `created` (RFC 3339 UTC), `pane` (live holder's pane id or null),
  `ended` (no live holder), and `revivable` (ended, with an existing cwd
  directory and session file). Revival availability is polled; it does not
  promise a successful future activation. Pane is a display association,
  not a jump target: activate by ask id to resolve current topology.
  Session-file paths and cwd are not exposed.
- **`error`**: null or a transient error string; the stream continues. A
  failed read keeps the last good identity and topology, tracks no
  transitions and prunes no panes.
- **`sessions`**: in display order, each with the
  session's top-level nodes in display order. A session is the
  source-list section; it is not itself a node. Sessions with an integer
  session-scoped @kido-order option come first, by rank; the rest follow.
  Ties and unranked sessions are oldest first by creation time, then name.
  An empty or malformed rank (anything but a canonical decimal integer) is
  unranked. The option is read through the ordinary format, so a value set
  globally would be inherited; kido never sets one there. Ranks live as
  long as the tmux server. Switch-session,
  cross-session window steps and the TUI use the same order.
- **Nodes** are one of two shapes, told apart by `kind`.

### Group node: `"kind": "window"`

A tmux window with more than one pane (the TUI's `┌├└` bracket).
`{"kind", "id", "window", "name", "children"}`:
- `id` = `window` = the window id `@N`;
- `name`: the window's name, tmux's `#{window_name}`;
- `children`: its panes as item nodes, oldest pane first. A group never
  holds a group directly.

A window with one pane has no group node: its pane is an item node in the
group's place. Groups are the "group" rows the app may draw differently.

### Item node: `"kind": "pane"`

`{"kind", "id", "pane", "window", "title", "lifecycle", "program_status",
"run", "started", "children"}`, all required:
- `id` = `pane` = the pane id `%N`, stable for the pane's life, including
  a dead lingering pane. `window` is its window id. Both are the jump target.
- `title`: the plain resolved label, never a result or caption. Local pi:
  its State session name when set, otherwise the pane title verbatim (even
  empty). Native and remote agents: the pane title, or the app name when it
  is empty; record titles never rename an agent. Terminals and remote
  terminals: the representative record's title, then its inherited app,
  then the foreground command (`ssh` for a remote terminal with no
  records). A live run with no records: the run name. An ended run: when a live local pi State record
  names the pane, even one whose root was cleared or replaced, its session
  name or else the pane title; otherwise the run name.
- `lifecycle`: `["Ended",{"result":R}]` for a run pane whose outcome is
  recorded or whose pane is dead, overriding any program or shell status.
  R is `unknown` until an outcome is recorded (never inferred from the
  process), then `completed`, `failed`, `died` or `stopped`. Ended always
  has a non-null `run`. Otherwise `["Live",KIND]`, one of:

```json
["Terminal",{"phase":["Idle",{"last":null}],"report":null}]
["Some_agent",{"name":"claude-code","status":AGENT}]
["Pi_agent",{"id":"pi-session-id","status":AGENT}]
["Ssh",{"user":"alice","host":"example.org","pane":["Remote_terminal",{"interactive":true,"status":SHELL}]}]
["Ssh",{"user":"alice","host":"example.org","pane":["Remote_agent",{"name":"pi","status":AGENT}]}]
```

  Detection is OSC 7501 root app `pi` or `claude-code`, and the believed
  `@kido_ssh` mark (only while the foreground command is `ssh`). A pi root
  with a live State record naming the pane is `Pi_agent`, whose `id` is
  that State session; other agent roots are `Some_agent`. A run uses its
  actual kind: a subagent with no agent root yet is a `Terminal`.
- AGENT is `{"since","msg","state"}`; state is one of:

```json
["Running",{"progress":42}]
["Waiting",{"source":["Blocked",{"kind":"permission"}],"progress":null}]
["Waiting",{"source":["Ask",{"id":"A12345678"}],"progress":null}]
["Stalled"]
["Idle",{"outcome":null}]
["Idle",{"outcome":{"serial":17,"result":"success"}}]
["Idle",{"outcome":{"serial":18,"result":"failure"}}]
```

  Precedence is waiting > stalled > running > idle. An outstanding ask of
  a local pi session is Waiting with source Ask (the oldest in `asks`
  order among several; the question is in `asks`), progress null; it outranks
  blocked records. Otherwise the blocked record with the smallest
  bytewise id gives Waiting with its kind (`permission`, `question`,
  `auth`, or null for absent or unrecognized) and progress. Stalled is a
  local pi with a working root and a stale State heartbeat (rebased across
  sleep); native and remote agents never stall, and any blocked record
  outranks it. Running takes the smallest-id working record's progress.
  `msg` comes from the representative record (blocked, then working, then
  the retained outcome's record, then idle, then any, ties by id), falling
  back to local pi's State activity; a local pi message equal to its title,
  or prefixing it as `msg - `, is dropped. An ask supplies the source only.
- SHELL is `{"phase","report"}`; phase is one of:

```json
["Unknown"]
["Idle",{"last":null}]
["Idle",{"last":{"code":1,"command":"false","started_at":1780000000.0,"ended_at":1780000001.0}}]
["Running",{"origin":["Command",{"command":"make","started_at":1780000000.0}],"fullscreen":false}]
["Running",{"origin":["Unknown"],"fullscreen":true}]
```

  Unknown is a shell without OSC 133 prompts, not an idle one. Idle is a
  known prompt; `last` is the last command's exit, captured whole from
  one read (code, command line, start and end, whole seconds) and kept
  until the next command is promoted to Running; a missing D yields no
  exit. A command is Running once it has been observed for 0.2s (kido's
  clock, from its first observation, restarted by a new start); until then
  the previous Idle is sent, so a short command never runs. The alternate
  screen is Running at once with `fullscreen`, its origin the command when
  OSC 133 knows one, else Unknown. An ssh before a remote prompt strictly
  later than its start is a transport command; after it, `interactive`
  is latched for that destination and the remote shell's markers drive
  the phase.
- `report` is null or `{"since","msg","state"}`, the pane's generic OSC
  7501 records reduced blocked > working > idle with the agent rules
  above, without asks or stall:

```json
["Running",{"progress":42}]
["Waiting",{"kind":"auth","progress":null}]
["Idle",{"outcome":null}]
["Idle",{"outcome":{"serial":17,"result":"success"}}]
```

  It rides every phase. Its outcome survives an empty record set until a
  command is promoted to Running (an outcome first seen during that
  command's debounce stays) or a new report episode begins. It is never a
  command exit code.
- Outcomes: entering done or error in a record (first sight, reappearance,
  done to error and back included) creates an outcome stamped with that
  read's pane emission serial; unrelated message, progress, title or
  serial changes never do. Simultaneous entries take the smallest record id.
  An outcome is shown at aggregate Idle; arriving during other work it
  waits until then, and a new live episode after Idle clears it. Removing
  a record keeps a retained outcome.
- `since` is when this feed first observed the current state tag (or, at
  Idle, the current outcome). Progress, message, representative, kind,
  serial and title changes do not move it. It is for display.
- Tracking resets when an agent's root app changes, appears or clears
  (including the agent exiting to the shell, or a shell becoming an
  agent); when the local State session id or the ssh destination
  changes; and when a pane leaves a successful topology read. A
  terminal's report changing app or clearing is not a reset: its
  retained report outcome stays. Linked occurrences of one pane share
  tracking.
- `program_status`: an object with integer `serial` and `records` array,
  always present (serial 0 and an empty array before any emission).
  Records are ordered bytewise by `id`; root has id "". Each has string
  `id` and `state` (idle, working, done, blocked, error), and optional own
  `app`, `kind` (permission, question, auth; an unknown kind is dropped),
  integer `progress` (0..100), `title` and `msg`. Title and msg are decoded,
  validated UTF-8 strings, not base64; the tmux input accepts padded or
  unpadded base64. Msg is limited to 2048 decoded bytes (2732 encoded
  bytes). Kind is meaningful only on blocked, progress only on
  working/blocked. App is inherited from the nearest ancestor that has one,
  including root across missing parents; inheritance is not materialized
  into these records. All records are included, raw: no visit or
  acknowledgement removes or hides any of them.
- `run`: `"agent"` for a subagent run, `"bash"` for plain async_bash,
  `"stream"` for async_bash launched with streaming, or null for anything
  else. It remains set on ended or lingering run panes. The run's meta
  records this classification at launch.
- `started`: unix seconds as a number that may carry a fraction, equal to the run's meta.started_at
  while its pane is alive and no outcome has been recorded; null for ended
  runs, top-level agents, shells and ssh. Independent of `msg`.
- `children`: nodes hoisted under this pane, in display order: the
  windows of this agent's subagents and runs, each as a group node or,
  for a one-pane window, an item node. Nesting has no depth limit
  (subagents of subagents). Empty for most panes.

Every option in these shapes is present as null when absent, never
omitted, and variant-specific fields appear only inside their case.
Variants are arrays: the tag, then its record when it has one. Every
time is a JSON number of Unix seconds that may carry a fraction, whole
values included (`1780000000.0`), so a client decodes it as floating
point; only `server_instance.started_at` is an integer.

Ids are unique within a session. A window linked into several sessions
appears in each of them, with the same ids. A pane or window moving to another
place in the tree keeps its id, so the app can key expansion and
selection on `id`.

Frontends own seen outcomes, notifications, glyphs, palettes,
labels assembled from these facts, captions and elapsed clocks. Seen keys
are the destination, `server_instance`, pane id and outcome source: an
agent or report outcome by its serial, a command exit by
(`started_at`, `ended_at`). These identities are weaker than exactly-once:
two commands can share whole-second start and end; concurrent feeds can
give one outcome different serials, as can a feed started after an
unrelated update; a restarted feed loses a retained outcome whose record
went idle or away, while an exit tmux still holds is reconstructed.

The TUI draws the same tree: its glyph columns are derived from these
nodes inside kido, so the feed and the TUI cannot disagree about
structure. Hoisting stays per session.

## Server endpoint

kido server --server <dir> ensures a detached server and prints one line:
{"tmux":"/absolute/kido-tmux","socket":"/dir/socket","protocol":"4.0","server":"0123456789ab","expected":"0123456789ab"}.
protocol is the binary's Protocol.value, always a string. server is always present:
the server's KIDO_SERVER stamp, or null when absent, even when it matches expected.
expected is the binary's own stamp, always a string. The app compares server
and expected to detect a kido upgrade that needs a server restart.
The stamp does not change when ensuring or attaching an existing server.
kido --version independently prints the binary build id.

## Fork dependencies

The control client enables new-layouts: layout notifications and layout
formats use JSON trees, including floating-pane geometry, so the app can
lay out pane views without decoding tmux's traditional layout string.
new-pane creates floating panes with -x/-y dimensions and -X/-Y positions,
-B border lines, -s pane style, -S/-R border styles and -T title;
-W blocks the command queue until the pane's command exits; -E creates an
empty pane with no command.
Control-client pause flush delivers pending output before %pause, so the
app's view contains the last screen before pausing.
The no-detach-on-destroy client flag keeps the control client connected
when its last session is destroyed.
tmux -N attach does not start a server when the target server is absent.
OSC 7501 records are delivered server-wide to every control client as
`%program-status %N <serial> <JSON>`, throttled to 100ms per pane. The
payload is a full record set, identical to `#{pane_program_status}`.
Topology is authoritative: every topology read includes
`#{pane_program_status}`, and kido parses records only from it, for
control-mode and one-shot reads alike. `%program-status` notifications
only wake the next read; their payload is ignored. OSC 133 A clears the
applicable records; process exit, RIS and respawn also follow the fork's
program-status clear rules.
These behaviours come from the pinned fork, not stock tmux.
pi status comes from pi 1.2.0's native OSC 7501 root record, with no
title or progress. Named pi labels use the session name reported in State,
exactly as set by /name. Unnamed or untracked pi labels use the pane title
set through OSC 0/2, verbatim; unnamed tracked sessions
are addressable only by session id or id prefix. Generic programs retain
their OSC record title. A pi message duplicating the session name is
dropped from `msg`.

share/dune installs only its named source trees and files; this contract
and testdata are checkout-only review artifacts.

