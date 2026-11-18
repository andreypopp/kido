---
name: ko
description: Read and change the user's ko terminal layout - sessions, windows (tabs), panes, splits, floats, focus and the sidebar's pane rows (title, status, cwd, runtime, program) - with `ko api`. Use when the user talks about their windows, tabs, panes, sessions, splits, floats or the sidebar, asks what runs where, or asks to open, split, rename or close one.
---

# ko: the user's layout

This pi runs in a pane of a ko server. Every `ko` command in your bash
tool talks to that server: `$KO_SOCKET` names it, `$KO_PANE` is your own
pane, and ko sends your pane's identity with each request.

## The interface

`ko api PATH` sends one request to the server and prints the response body
(`-X METHOD`, `--input FILE` for the body, `-` reads stdin; `ko api --help`).
`ko api-schema` prints the OpenAPI document of every route: its
description, its parameters, its body and its responses. It is the
reference. Look up the routes that you need there, do not guess a field:

```sh
ko api-schema | jq -r '.paths | to_entries[] | .key + " " + (.value | keys | join(","))'
ko api-schema | jq '.paths["/layout"].put'
ko api-schema | jq '.components.schemas.PutLayout'
```

`ko api-schema --client` describes the model and the edits of ko's client
core, which `ko api` does not use.

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
  pane, and the server refuses some writes for other panes.

## Examples

```sh
# The layout document, its revision and every pane's row
ko api /layout

# Your own row
ko api /panes/$KO_PANE

# Your own session and window
ko api /layout | jq --arg p "$KO_PANE" '.layout.sessions[] | {session: .id, name} + (.windows[] | select([.. | .pane? | strings] | index($p)) | {window: .id, window_name: .name})'

# What a pane shows, with the last 200 rows of history
ko api "/panes/pane_3/screen?history=200"

# A new window with one pane, in your session
echo '{"name":"logs","cwd":"/tmp"}' | ko api /panes --input -

# A new pane right of your own pane
ko api /layout | jq --arg p "$KO_PANE" '{revision, layout: (.layout | walk(if type == "object" and .pane? == $p and has("x") == false then {split: "h", children: [{pane: $p}, {pane: {new: {}}}]} else . end))}' | ko api -X PUT /layout --input -

# Rename a window
ko api /layout | jq '{revision, layout: (.layout | (.sessions[].windows[] | select(.id == "window_2")).name = "build")}' | ko api -X PUT /layout --input -

# Close a pane, a window or a session
ko api -X DELETE /panes/pane_4
ko api -X DELETE /windows/window_2
ko api -X DELETE /sessions/session_2
```

A `PUT /layout` with a stale revision gets 409 and the current layout: run
the same pipeline again, so it reads the new revision.

On a status that is not 2xx, `ko api` prints the error body, writes
`ko api: HTTP <status>` to stderr and exits 1.
