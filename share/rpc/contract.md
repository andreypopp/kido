# kido rpc protocol 6.2

fork revision: a0422edea09188133f9ea7cd408ba5f7c1922694

Protocol.value is the binary's protocol constant. It versions this RPC
surface and the tmux commands this contract names, such as the "Pane
images" capture flags and the image-shm control flag; the server's compatibility is a separate stamp
(below), so a protocol bump never requires restarting the tmux server. New fields and new enum values are MINOR changes:
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
with the binary's server stamp: 12 hex digits digesting the fork build key
(the pinned fork revision and the digest of scripts/install-tmux-fork.sh),
the server.conf the launcher generates and the environment changes
it makes to the server's (dropping KIDO_STATE_DIR, putting its bin directory
first on PATH), all with fixed placeholder paths. Install paths do not change
it; a fork bump, an installer edit, an edit to kido-tmux.conf, to the generated configuration or
to the launch environment does.

The first stdout line is {"hello":{"protocol":"6.2"}} when KIDO_SERVER equals
the binary's stamp. A differing or absent stamp produces
{"hello":{"protocol":"6.2","server":"other","expected":"0123456789ab"}} or
{"hello":{"protocol":"6.2","server":null,"expected":"0123456789ab"}}, followed
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

{"id":11,"release-side-focus":true} releases the named tmux client's
side-status keyboard focus and replies {"reply":{"id":11,"released":true}}.
Both requests require integer ids, use the existing error envelope,
and keep the stream alive on errors. No cursor or OS focus is affected.
Jump's payload has exactly the three identifier fields. Release accepts
only true. Multiple recognized operations in one object are invalid. Outer extra fields are ignored.

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

Prompting sends text to an agent through the mechanism of `kido prompt`.
A resolve sends nothing:
{"id":21,"prompt":{"pane":"%9"}}
replies
{"reply":{"id":21,"prompt":{"candidates":[{"pane":"%12","session":"$1","window":"@3","title":"claude-code"}]}}}.
The candidates are the agent panes of `pane`'s session, closest first:
the agents of `pane`'s window, then the other agents in feed order
(window order, panes oldest first). Panes in run windows, terminals and
ssh panes without a remote agent are never candidates. `pane` itself is
a candidate if it is an agent. An empty list means no agent. `title` is
the plain, uncut title of the pane's snapshot item.
A send delivers `text` verbatim to one candidate:
{"id":22,"prompt":{"pane":"%9","target":"%12","text":"explain this"}}
replies
{"reply":{"id":22,"prompt":{"delivered":{"pane":"%12","via":"inbox"}}}}.
`via` is "inbox" when the pane advertises an inbox socket, else "paste":
a bracketed paste, then Enter. An advertised inbox is never replaced by a
paste. The prompt object has exactly `pane`, or `pane`, `target` and a
string `text`; ids are pane ids (% followed by digits). Other shapes are
"invalid or unknown request".
A prompt error adds a `kind` to the error envelope:
{"reply":{"id":22,"error":"claude-code is not accepting messages","kind":"refused"}}.
- `refused`: nothing was delivered; the client may send again. The
  advertised inbox does not accept, or fresh state could not be read.
- `unknown`: the text may have arrived (an inbox failure after connect, a
  failed paste); the client must not send it again.
- `invalid`: empty text, `pane` not found in fresh state, or `target` not a
  candidate of `pane`.

## Changes from 5.0 to 6.0

- Changed: an item node's `run` is the run id that the pane's `@kido_run`
  option names, or null. It was the run's kind (`"agent"`, `"bash"` or
  `"stream"`). A top-level pi that claims a run now has a non-null `run`.
- Changed: `Pi_agent` carries `session`, the pane's `@kido_session`
  option, in place of `id`. A pi root with that option is a local pi; the
  pane's run does not decide it.
- Changed: an Ended pane's result is derived from the dead pane's exit
  status or signal when no outcome is recorded, never `unknown`.
- Unchanged: `started`, the Ended shape, the prompt request and
  its replies, other requests, sessions, ordering and snapshot v. A prompt
  candidate's inbox now comes from the pane's `@kido_inbox` option.

## Changes from 4.0 to 5.0

- Added: the prompt request, with `candidates` and `delivered` replies and
  the error `kind`.
- Removed: the top-level snapshot `asks` list and the activate-ask and
  delete-ask requests with their `activated` and `deleted` replies.
- Changed: agent Waiting carries the blocked record's `kind` and
  `progress` directly, the same shape as a generic report's Waiting; the
  `source` field and its Ask case are gone. Only an OSC 7501 blocked
  record makes an agent Waiting.
- Removed: the agent state `["Stalled"]`. A local pi with a working root
  is Running however old its run's last report is; agent precedence is
  waiting > running > idle, the same as a generic report's.
- Unchanged: other requests, replies, sessions, ordering and snapshot v.

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
  records instead of reported status/completion; the title uses the pane title.
  Pi compaction is running with
  a message, not compacting. Gone runs outrank terminal status.
- Changed: pi stall requires a working root and a stale run heartbeat;
  bare pi never stalls. Pi addressing uses the reported session name. The
  pane run supplies identity, inbox, parentage, activity and the ask
  overlay; agent-status removes --status, --ended and --title.
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
          "lifecycle": ["Live", ["Pi_agent", {"session": "pi-session-id", "status": {"since": 1780000000.5, "msg": "fixing tests", "state": ["Running", {"progress": null}]}}]],
          "program_status": { "serial": 4, "records": [ { "id": "", "state": "working", "app": "pi" } ] },
          "run": "pi-session-id",
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
  its `@kido_name` option when set, otherwise the pane title verbatim (even
  empty). Native and remote agents: the pane title, or the app name when it
  is empty; record titles never rename an agent. Terminals and remote
  terminals: the representative record's title, then its inherited app,
  then the foreground command (`ssh` for a remote terminal with no
  records). A live run with no records: the run name. An ended run: its
  `@kido_name` option or else the run name, which is the session name its
  pi last reported, else its launch name.
- `lifecycle`: `["Ended",{"result":R}]` for a run pane whose outcome is
  recorded or whose pane is dead, overriding any program or shell status.
  R is the recorded outcome, else the ending derived from the dead pane:
  `completed` for exit status 0, `failed` for another status or a signal,
  `died` without either. Values are `completed`, `failed`, `died` and
  `stopped`; kido no longer sends `unknown`. Ended always
  has a non-null `run`. Otherwise `["Live",KIND]`, one of:

```json
["Terminal",{"phase":["Idle",{"last":null}],"report":null}]
["Some_agent",{"name":"claude-code","status":AGENT}]
["Pi_agent",{"session":"pi-session-id","status":AGENT}]
["Ssh",{"user":"alice","host":"example.org","pane":["Remote_terminal",{"interactive":true,"status":SHELL}]}]
["Ssh",{"user":"alice","host":"example.org","pane":["Remote_agent",{"name":"pi","status":AGENT}]}]
```

  Detection is OSC 7501 root app `pi` or `claude-code`, and the believed
  `@kido_ssh` mark (only while the foreground command is `ssh`). A pi root
  on a pane with the `@kido_session` option is `Pi_agent`, whose `session`
  is that option's value; other agent roots are `Some_agent`. A run uses its
  actual kind: a subagent with no agent root yet is a `Terminal`.
- AGENT is `{"since","msg","state"}`; state is one of:

```json
["Running",{"progress":42}]
["Waiting",{"kind":"permission","progress":null}]
["Idle",{"outcome":null}]
["Idle",{"outcome":{"serial":17,"result":"success"}}]
["Idle",{"outcome":{"serial":18,"result":"failure"}}]
```

  Precedence is waiting > running > idle. The blocked record with the
  smallest bytewise id gives Waiting with its kind (`permission`,
  `question`, `auth`, or null for absent or unrecognized) and progress.
  Running takes the smallest-id working record's progress.
  `msg` comes from the representative record (blocked, then working, then
  the retained outcome's record, then idle, then any, ties by id), falling
  back to local pi's `@kido_activity` option; a local pi message equal to its title,
  or prefixing it as `msg - `, is dropped.
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
  above:

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
  agent); when the pane's `@kido_session` or the ssh destination
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
- `run`: the run id that the pane's `@kido_run` option names, or null for
  a pane without the option. It remains set on ended or lingering run
  panes.
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
{"tmux":"/absolute/kido-tmux","socket":"/dir/socket","protocol":"6.2","server":"0123456789ab","expected":"0123456789ab"}.
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
pi status comes from pi 1.4.0's native OSC 7501 root record, with no
title or progress. Named pi labels use the session name reported in its run,
exactly as set by /name. Unnamed or untracked pi labels use the pane title
set through OSC 0/2, verbatim; unnamed tracked sessions
are addressable only by session id or id prefix. Generic programs retain
their OSC record title. A pi message duplicating the session name is
dropped from `msg`.

## Pane images

kido's tmux is built with images (`#{image_support}` is 1). A pane stores
the kitty images that its program sends; control clients also get the
program's APC unchanged in `%output`. Three fork extensions let a client
restore them. They are not RPC requests; the app sends them as tmux
commands. The server image limits stay at upstream's defaults.

Ids. For an image sent with `i=`, `i=` is its client id, and `p=` the
client placement id, omitted when there is none. A later live `a=p i=N`
or `a=d d=I i=N` thus names the same image in tmux and in the app. An
image sent without `i=` gets an id in `0x80000000`-`0xffffffff` at
capture time, and its placements have no `p=`. That id is no client id
in the pane and no other image's id in the capture. `-G` and `-K` with
the same range and pane state give the image the same id, and the calls
of one `-K` sequence keep it. A live program can later send a client id
that equals such an id; the app then replaces the restored image with
the program's image, while tmux keeps the two images separate.

Selection. `-G` and `-K` use one rule: a placement counts when any of its
grid spans lies on a row of the range (`-S`/`-E`; `-a` reads the saved
main grid). A placement keeps its spans when it scrolls into history and
through a width resize.

`capture-pane -p -G` writes each such placement into the text output at the
cell where it starts, on its first row inside the range:

    ESC _G a=p,i=I[,z=Z][,X=XO][,Y=YO][,p=P],q=2,C=1,c=COLS,r=ROWS,x=X,y=Y,w=W,h=H ESC \

`z=` is the placement's z-index as the program sent it, omitted when it
is 0. tmux stores it only for `-G` and the upload replay below; its own
drawing for terminal clients ignores it. `X=` and `Y=` are the pixel
offsets in the placement's first cell, written when they are not 0 and
that cell's column (`X=`) or row (`Y=`) is in the output.

`C=1` keeps the cursor, so the row text after it is unchanged; spaces
before a placement are kept. `x=,y=,w=,h=` are the source rectangle of
the rows in range. A placement whose top is above the range has a crop
that starts at the first row in range. `c=` and `r=` are the cells that
the written part covers. When an axis is drawn at the image's own pixel
size and its last cell is not full, that key is 0, so the client draws
that axis at its own size and does not stretch it to the cell edge. A
scaled axis whose last cell is not full (the program gave only one of
`c=` and `r=`) keeps its cell count; the client then stretches it to the
cell edge, a known limit. `-G` applies with `-e`, `-J` and
every range. Without placements its output equals the same capture
without `-G`. When the capture includes the live screen and the pane's
program is in the middle of a chunked upload (`m=1`), `-G` writes after
the last row that upload's bytes so far, as `a=T` or `a=t` chunks with
its keys and `m=1`, if they fit in 8 MiB. The live chunks that follow
the reply continue it. The replay carries the same decoded bytes; its
chunk boundaries can differ from the sender's, and its last chunk can
end in base64 padding.

`capture-pane -p -K [-k TOKEN]` writes no text. For each selected image, in
order of first appearance in the range, it writes the received bytes,
verbatim, as a kitty transmit, one chunk per line:

    ESC _G a=t,i=I,f=F[,o=z][,s=S][,v=V],q=2,m=1;BASE64 ESC \
    ESC _G m=1,q=2;BASE64 ESC \
    ...
    ESC _G m=0,q=2;BASE64 ESC \

The first chunk has the keys and the last has `m=0`; an image of one
chunk has `m=0` on the first. `o=z` appears only for zlib data, `s=` and
`v=` only when the sender sent them. Every chunk except an image's last
carries 3072 bytes, 4096 base64 characters without padding. `a=t` only
transmits; the placements come from `-G`. An image appears once in a
reply sequence.

A `-K` reply is at most 8 MiB, far below the control client's 64 MiB
limit for buffered replies. When more remains, the reply's last line is

    more TOKEN

The client repeats the same range with `-k TOKEN` until a reply has no
`more` line. When the cut is inside an image, the reply's last chunk has
`m=1` and the next reply starts with continuation chunks of that image.
When the cut is at an image boundary, the reply's last image is complete
(`m=0`) and the next reply starts with the first chunk of the next image.
Then come the images after it. The
token is opaque. When the token's image is no longer in the range's
images (deleted, replaced, or no longer placed there), the image was
edited after the previous call (frame edits, below), or the token is
invalid, the command fails with `image changed` and writes nothing; the
client drops the partial transmission and starts again without `-k`.
An empty reply means no images. If output scrolls between calls, the
range can select other images; images that moved before the token's
image are not sent in that sequence.

Frame edits (`a=f`). tmux accepts a kitty `a=f` that edits frame 1,
the image itself: `i=I,r=1`, a rectangle `s`x`v` at `x`,`y` in format
24, 32 or 100, sent by `t=d` (also in `m=1` chunks) or `t=s`. It
blends the rectangle over the image with the same integer arithmetic as
Ghostty (non-premultiplied source over) or, with `X=1`, replaces the
pixels. A rectangle that overhangs the image is clipped;
one larger than the image answers `EINVAL`. `c=` and `Y=` have no
effect on an edit, as in kitty and Ghostty. A missing image answers
`ENOENT`. The reply is `ESC _G i=I,r=1;OK ESC \`. tmux does not yet
store more frames: `r=0`, or an `r=` that names a new frame, answers
`ENOTSUP`, while the app adds that frame. Thus frame numbers can differ
until a restore.

In every chunked upload (`m=1`), tmux keeps the first chunk's keys, as
Ghostty does. A later chunk changes only `m=`, and its `q=` applies
only when it is not 0. Thus `q=2` on the first chunk keeps the reply
suppressed.

An edit does not change the image's id or its placements. After an
edit, `-K` writes the image's current pixels, not the received bytes:

    ESC _G a=t,i=I,f=32,s=W,v=H,q=2,m=1;BASE64 ESC \

`W` and `H` are the image's size in pixels. Chunks, the budget and
`more` are as above. With `image-shm` it is one `t=s` line with
`f=32,s=W,v=H`. An edit of an image that stays a mapping of the
program's object (`t=s` below) first copies it, so tmux never writes
the object.

`-K` depends on the target pane, not on the calling client's session or
size. It gives the same output to a one-shot client and to a control
client, except that a client with `image-shm` gets shared-memory lines
(below).
In a control-mode reply, the capture lines are not octal-escaped (only
`%output` is), so the ESC bytes arrive raw, as for `-e` captures.
Kido.app runs it on a second control client per connection, attached
with `-f no-output,ignore-size`. Such a client takes no part in pane
focus. Without images in the build, `-G` gives the capture without
placements and `-K` writes nothing.

Shared memory (`t=s`). tmux accepts kitty `t=s` for `a=t`, `a=T`,
`a=f` and `a=q`. The payload is the base64 name of a POSIX shared-memory object:
1 to 31 bytes (the macOS limit), an optional leading `/`, no other `/`,
no NUL. Other names answer `EINVAL`. tmux opens the object read-only. It
checks the byte range (`S=`, `O=`, else `s*v*bytes` for raw formats, else
the object's size) against the object's size and `image-size-limit`
before it reads. A missing object or a bad range answers `EBADF`.
`a=q,t=s` answers `OK`. Raw RGBA (`f=32` without `o=z`) on macOS stays a
read-only mapping of the object; tmux never writes it. Other formats,
and every format on Linux, are copied. tmux stores the image in the same
read of pane output, before any control client gets that output. Thus a
`-K` that the client sends after the `%output` line selects the image by
its id. If the program has replaced the image with the same `i=`, `-K`
returns the newer image.

Every control client gets the raw `t=s` APC in `%output`, as it gets
every APC. A control client attached or refreshed with `-f image-shm`
(Kido.app on the local machine) opens the name itself, then unlinks it,
as the kitty spec requires. tmux does not unlink the name while such a
client receives the pane. When the block of `%output` that carries the
APC has left tmux's queue of every such client (taken from the queue to
be written, dropped by `%pause`, or the client went away), tmux unlinks
the name after 1 s. The guard does not wait for the write to drain to
the socket. It stops leaks from a client that never opens the name. If no such client receives the pane, tmux unlinks
the name at once. When the server exits, it unlinks every name that it
still guards. A client can stop after tmux has taken the block and open
the name more than 1 s later. It then gets `ENOENT`, and it recovers
the image with `-K` on its image client.

A control client without `image-shm` must not act on `t=s` in
`%output`: on a remote machine the name can denote another object, and
tmux unlinks it at once. tmux gives such a client the image as `t=d`.
Directly after the APC's terminator, before the bytes that follow it in
the same read, it queues the image's stored bytes as `%output` chunks:

    ESC _G a=A,t=d,i=I,p=P,f=F[,o=z][,s=S][,v=V],x=X,y=Y,w=W,h=H,X=XO,Y=YO,c=C,r=R,C=N,z=Z,S=SIZE,q=2,m=1;BASE64 ESC \
    ESC _G m=1,q=2;BASE64 ESC \
    ...
    ESC _G m=0,q=2;BASE64 ESC \

`A` is the original action (`t`, `T` or `f`) and the other keys are the
original command's, so the client ends with the same image and the same
placement. For `a=f`, `r=`, `c=`, `x=`, `y=`, `X=`, `Y=` and `z=` are
the frame keys, and the client applies the same edit. The chunk size is as for `-K`. `a=q` gets no chunks. No
control client may act on `t=f` or `t=t` in `%output`: tmux answers
them `ENOTSUP` and the path can denote another file on the client's
machine.

`-K` from a client with `image-shm` writes each selected image as one
line, without `m=`:

    ESC _G a=t,i=I,f=F[,o=z][,s=S][,v=V],t=s,S=SIZE,q=2;BASE64NAME ESC \

The name is a new object, `/kt<pid>-<n>`, mode 0600, that holds the
image's stored bytes (as received; `o=z` and PNG stay encoded). The
client opens and unlinks it. tmux unlinks it 10 s after it creates it if
the client has not. The 8 MiB budget and `more TOKEN` apply as for chunks.
Without `image-shm`, `-K` writes chunks as above. `-G`'s replay of an
incomplete upload always uses chunks.

DA1 (`CSI c`) from a pane answers `CSI ?1;2;4c` (sixel) only while at
least one attached terminal client has the `sixel` terminal feature;
otherwise `CSI ?1;2c`. Control clients do not count. Thus under
Kido.app alone a program that selects sixel from DA1 (chafa, timg)
prints text instead of sixel that the app does not show.

`refresh-client -C WxHxXPxYP` also sets the control client's cell size in
pixels. The plain `-C WxH` resets the pixels to 0. tmux gives the window
the cell size of the clients that take part in its sizing (not
`ignore-size` clients; with `window-size latest`, only the latest
client): the first one that is strictly larger on both axes than the
one before wins. With no pixel size from any of them, tmux uses 16x32.
A manual window size keeps the window's current pixels. The window's
value is used for kitty placement and the CSI 14t/16t replies. Thus the
image client, which is `ignore-size`, does not set it; the main control
client sends the pixel form. pi reads the cell size once at start, so
the client sends it before it starts panes and after every size or font
change. A pi that runs during a font change keeps its old cell size
until it restarts.

share/dune installs only its named source trees and files; this contract
and testdata are checkout-only review artifacts.

