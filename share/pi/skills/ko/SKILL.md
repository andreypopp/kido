---
name: ko
description: Read and change the user's ko terminal layout - sessions, windows (tabs), panes, splits, floats, focus and the sidebar's pane rows (title, status, cwd, runtime, program) - with the ko command. Use when the user talks about their windows, tabs, panes, sessions, splits, floats or the sidebar, asks what runs where, or asks to open, split, rename or close one.
---

# ko: the user's layout

This pi runs in a pane of a ko server. Every `ko` command in your bash
tool talks to that server: `$KO_SOCKET` names it, `$KO_PANE` is your own
pane, and ko sends your pane's identity with each request. `ko api-schema`
prints the OpenAPI description of every route and body; look a field up
there, do not guess it.

## Rules

- Read before you write. Read the layout first, and name sessions, windows
  and panes by the ids that you read.
- Change the layout (create, split, move, rename, close) only when the user
  asks for that change.
- Never send input to another pane, and never close or stop a pane that
  you did not create, unless the user asks for it.
- Never run `ko kill-server` or `ko server`. They stop or start the user's
  terminal.
- You act only as your own pane. You cannot act as the user or as another
  pane, and the server refuses some writes for other panes (their
  variables, their `close`).
- You cannot move the user's focus or switch their view. A new window does
  not take the focus.

## The model

- A **session** (`session_N`) holds an ordered list of **windows**
  (`window_N`). A window is one tab of the client.
- A window has a `tree` of tiled panes and a list of `floats`. A tree node
  is a leaf (`pane`, `cols`, `rows`) or a split (`split` with `children`).
  Axis `h` puts the children side by side, `v` stacks them.
- A float is a pane over the tree, at `x`, `y` with `cols` x `rows` cells.
- A window's `focus` is its last-focused pane; `zoom` is its zoomed pane,
  when one is zoomed. The layout does not say which window a client shows.
- A **pane** (`pane_N`) has a row: `title`, `cwd`, `command`, `foreground`
  (the foreground process `name` and `pid`), `status`, `dead` (null while it
  lives), `runtime` (absent on the host), `parent`, `close` and `vars`. The
  `cwd` is the start directory until the shell reports its directory; then
  it is a `file://host/path` URL.
- A pane's `close` says what happens when its program ends: `exit` (the
  default) removes the pane at once, `on_exit` after a short grace, and
  `keep` keeps it, dead, until it is closed. A kept pane shows its exit in
  the `STATE` column of `ko panes`.
- The sidebar is the sessions and windows of the layout with these rows.
  `status.title` is the caption of a pane, and `status.kind.type` is its
  kind: `terminal`, `pi_agent`, `some_agent` (for example Claude Code) or
  `ssh`. An agent's `status.kind.status.state.type` is `running`, `waiting`
  or `idle`.

## Read

```sh
ko layout                   # {revision, layout: {sessions}, panes}: the document and every row
ko panes                    # a table of every pane
ko panes --json             # every pane's row
ko api /panes/$KO_PANE      # your own row
ko api /runtimes            # the runtimes, with their state
```

Find your own window and session in `ko layout`: the window whose tree or
floats name `$KO_PANE`. With `jq`:

```sh
ko layout | jq --arg p "$KO_PANE" '.layout.sessions[] | {session: .id, name} + (.windows[] | select([.. | .pane? | strings] | index($p)) | {window: .id, window_name: .name})'
```

Read what a pane shows:

```sh
ko api "/panes/pane_3/screen"                  # the visible rows, as plain text
ko api "/panes/pane_3/screen?history=200"      # the visible rows, with the last 200 rows of history above them
ko api "/panes/pane_3/screen?history=all"      # the whole scrollback
```

## Create

A new window with one pane, in your session, after your window:

```sh
echo '{"name":"logs","cwd":"/tmp","command":{"type":"shell","command":"tail -f app.log"}}' | ko api /panes --input -
```

It prints the new `session`, `window` and `pane`. Without `command` the pane
runs the user's shell, and the window takes the name of its program unless
you give `name`. `cwd` is an absolute path or `{"pane":"pane_3"}`, the
directory of that pane. `session` puts the window in another session, by id
or name; `runtime` runs the pane in a runtime of `ko api /runtimes`.

For one change of the layout, use `ko layout edit` with one edit. It reads
the current revision and applies the edit again when the layout changed
meanwhile:

```sh
ko layout edit '{"type":"split","pane":"pane_3","axis":"h","new":{}}'               # a new pane right of pane_3
ko layout edit '{"type":"split","pane":"pane_3","axis":"v","before":true,"new":{}}' # a new pane above pane_3
ko layout edit '{"type":"float","pane":"pane_4"}'                                   # float pane_4 over its window
ko layout edit '{"type":"rename_window","window":"window_2","name":"build"}'
ko layout edit '{"type":"rename_session","session":"session_1","name":"work"}'
ko layout edit '{"type":"add_session","name":"scratch","new":{}}'
```

It prints `snapshot`, the new document, and `created`, the session, window or
pane that the edit made. Every edit, with its fields (`edge` is
`left`, `right`, `top` or `bottom`; `?` marks an optional field):

| `type` | fields |
|---|---|
| `split` | `pane`, `axis`, `new`, `before?` |
| `float` | `pane`, `x?`, `y?`, `cols?`, `rows?`, `z?`, `border?`, `title?` |
| `unfloat` | `pane`, `target`, `edge`: tile the float beside `target` |
| `dock` | `pane`, `target`, `edge`: move the pane beside `target` |
| `dock_window` | `pane`, `window`, `edge`: move the pane to an edge of a window |
| `break_pane` | `pane`: move the pane into a new window |
| `swap` | `pane`, `other` |
| `resize_by` | `pane`, `edge`, `delta` (cells) |
| `resize_pair` | `first`, `second`, `first_size` (cells) |
| `equalize` | `pane`: equal sizes in its split |
| `zoom` | `window`, `pane?`: zoom the pane, or unzoom without `pane` |
| `toggle_zoom` | `pane` |
| `add_window` | `session`, `after` (a window), `new` |
| `add_session` | `name`, `new` |
| `ensure_session` | `name`, `new`: a session only when the server has none |
| `rename_window` | `window`, `name` |
| `rename_session` | `session`, `name` |
| `reorder_windows` | `session`, `order` (window ids) |
| `reorder_sessions` | `order` (session ids) |

`new` is a new pane: `{}`, or any of `cwd`, `command`, `env`, `vars`,
`runtime`, `parent` and `close`, as in `POST /panes`.

For a larger change, write the whole document back: edit the output of `ko
layout` and send it with `ko layout put FILE` (`-` reads stdin). It keeps the
revision rules for you. A raw `PUT /layout` with a stale revision gets 409
with the current document: apply your change to that document and send it
again. Every live pane must stay in the document; a new pane is a leaf or a
float whose `pane` is `{"new":{...}}`.

## Close

```sh
ko api -X DELETE /panes/pane_4          # close one pane; an empty window goes with it
ko api -X DELETE /windows/window_2      # close a window and all its panes
ko api -X DELETE /sessions/session_2    # close a session and all its windows
```

## Prompt an agent

`ko prompt` sends stdin to the one agent of your window, else of your
session. It exits 4 when there is no agent and 5 when there are several. For
an agent that you spawned, use your own agent tools, not `ko prompt`.

```sh
echo "run the tests again" | ko prompt
```

## Errors

On a status that is not 2xx, `ko api` prints the error body (`kind` and
`message`), writes `ko api: HTTP <status>` to stderr and exits 1. `not_found`
is an unknown id, `gone` a dead pane, `refused` a request that your pane may
not make.
