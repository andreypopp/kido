# kido rpc protocol 1.0

fork revision: 3efc7299bdc443843f3c41a7f601bdab7bd635a4

Protocol.value is the binary's protocol constant. The launcher stamps it into
the server's global KIDO_PROTOCOL environment at creation. Exact MAJOR.MINOR
equality is required. New fields and new enum values are MINOR changes:
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

The first stdout line is {"hello":{"protocol":"1.0"}}. A differing or absent
server stamp produces {"hello":{"protocol":"1.0","server":"other"}} or
{"hello":{"protocol":"1.0","server":null}}, followed by
{"error":"server protocol does not match binary protocol"}, then exit 2.
Exit 0 means stdin EOF. Exit 1 means a missing argument, absent server/client,
or stdin read error; diagnostics use stderr. Option errors use cmdliner.
Transient tick errors occupy snapshot.error and do not stop the stream.
The tick also performs idempotent reap and Claude screen probing.

## Requests and replies

Stdin is one JSON object per line. {"filter":"text"} sets the filter;
{"filter":""} clears it. Neither replies.
{"id":7,"switch-window":{"direction":"next"}} or direction "prev" uses the
same fresh-state flat tree ordering and eligible windows as the CLI.
A successful switch replies
{"reply":{"id":7,"switched":{"session":"$3","window":"@12"}}}.
No eligible target replies {"reply":{"id":7,"switched":null}}.
An invalid or unknown request carrying an integer id replies
{"reply":{"id":7,"error":"invalid or unknown request"}}; requests without an
integer id and invalid JSON are ignored. Errors do not stop the stream.
There is no switch-session request. The CLI navigation commands remain.
All stdout events are NDJSON from one writer; replies and snapshots can
alternate, but bytes from separate lines do not interleave.

## stdout: NDJSON, one full snapshot per model change

After hello, a full snapshot is emitted when visible model data changes:

```json
{
  "v": 2,
  "client": { "session": "$1", "window": "@2", "pane": "%3" },
  "filter": "",
  "error": null,
  "sessions": [
    {
      "id": "$1",
      "name": "main",
      "current": true,
      "nodes": [
        {
          "kind": "agent",
          "id": "%3",
          "pane": "%3",
          "window": "@2",
          "indicator": { "kind": "running" },
          "title": [ { "text": "kido", "role": "plain" } ],
          "tail": [ { "text": "fixing tests", "role": "dim" } ],
          "run": null,
          "started": null,
          "attention": false,
          "children": [
            {
              "kind": "window",
              "id": "@7",
              "window": "@7",
              "name": "agents",
              "children": [
                { "kind": "agent", "id": "%9", "pane": "%9", "window": "@7", "...": "...", "children": [] },
                { "kind": "shell", "id": "%10", "pane": "%10", "window": "@7", "...": "...", "children": [] }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

- **`client`**: the named client's current session, window and pane ids.
- **`filter`**: the active search string, empty when cleared.
- **`error`**: null or a transient error string; the stream continues.
- **`sessions`**: the
  session's top-level nodes in display order. A session is the
  source-list section; it is not itself a node.
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

### Item node: one pane

`"kind"` is one of:
- `agent`: a pane with an agent session (pi, Claude Code), or a finished
  subagent's lingering pane (its `indicator` is `gone`);
- `run`: an `async_bash` run's pane, running (`started` set) or ended;
- `ssh`: a pane whose foreground is an ssh session;
- `shell`: anything else (a shell, or a program that has taken the
  terminal).

Fields:
- `id` = `pane` = the pane id `%N`, stable for the pane's life, including
  a dead lingering pane. `window` is its window id. Both are always
  present, and both are the jump target.
- `indicator`: null or an object with `kind`: running, waiting, compacting,
  idle, unknown, done, failed, stalled or gone. Gone also carries `outcome`:
  completed, failed, died, stopped or null.
- `title` and `tail`: arrays of spans with `text` and `role`: plain, current,
  proc, dim, err, running, waiting, compacting, done or stalled.
- `attention`: boolean, whether attention navigation visits this pane.
- `run`: `"agent"` for a subagent run, `"bash"` for plain async_bash,
  `"stream"` for async_bash launched with streaming, or null for anything
  else. It remains set on ended or lingering run panes. `kind` stays
  `"agent"` for subagent runs and `"run"` for both async_bash modes.
  The run's meta records this classification at launch.
- `started`: unix seconds as a number, equal to the run's meta.started_at
  while its pane is alive and no outcome has been recorded. Independent
  of `tail`: a subagent with activity text still has its run start time,
  even when that subagent is idle. Null for ended, lingering or gone runs,
  top-level agents (pi or Claude Code, any status), shells and ssh.
  The app can draw elapsed time alongside activity text; kido's TUI
  Elapsed caption remains restricted to runs without activity text.
- `children`: nodes hoisted under this pane, in display order: the
  windows of this agent's subagents and runs, each as a group node or,
  for a one-pane window, an item node. Nesting has no depth limit
  (subagents of subagents). Empty for most panes.

Ids are unique within a session. A window linked into several sessions
appears in each of them, with the same ids. A pane or window moving to another
place in the tree keeps its id, so the app can key expansion and
selection on `id`.

The TUI draws the same tree: its glyph columns are derived from these
nodes inside kido, so the feed and the TUI cannot disagree about
structure. Hoisting stays per session.

## Server endpoint

kido server --server <dir> ensures a detached server and prints one line:
{"tmux":"/absolute/kido-tmux","socket":"/dir/socket","protocol":"1.0","server":"1.0"}.
protocol is the binary's Protocol.value, always a string. server is always present:
the server's KIDO_PROTOCOL stamp, or null when absent, even when it matches protocol.
The app compares them to detect a kido upgrade with an old server.
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
These behaviours come from the pinned fork, not stock tmux.

share/dune installs only its named source trees and files; this contract
and testdata are checkout-only review artifacts.

