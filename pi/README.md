# pi extension: kido-status

Reports a [pi](https://github.com/earendil-works/pi) session's live status to
kido, so pi sessions show up in the kido tmux sidebar next to Claude Code ones,
and opens an *inbox* socket so kido can send a prompt into the session.

It shells out to:

```
kido agent-status --agent pi --session <id> --status running|waiting|compacting|idle \
     [--title <text>] [--ended] [--remove] [--inbox <path>]
```

kido reads `$TMUX_PANE` from the environment, so the command is spawned from
inside the pi process, which lives in the tmux pane.

## Install

```sh
mkdir -p ~/.pi/agent/extensions
cp kido-status.ts ~/.pi/agent/extensions/
```

Extensions in `~/.pi/agent/extensions/` are auto-discovered at startup and can
be hot-reloaded with `/reload`. For a project-local install use
`.pi/extensions/` instead.

For a one-off run without installing:

```sh
pi -e /path/to/kido-status.ts
```

## Behaviour

| pi event | reported status |
|---|---|
| `session_start` | `idle` (also captures session id and name) |
| `agent_start`, `turn_start`, `tool_execution_start`, `tool_call` | `running` |
| `ui_prompt_start` / `ui_prompt_end` | `waiting` / back to `running` (or `idle`, if the prompt was raised while pi was idle) |
| `session_before_compact` | `compacting` |
| `session_compact`, `session_compact_failed` | back to the status from before compaction |
| `agent_settled` (and `ctx.isIdle()`) | `idle --ended` |
| `session_shutdown` | `--remove` (and the inbox socket is closed and unlinked) |

- If `kido` is not on `PATH`, or pi is not running inside tmux, the extension
  does nothing at all, quietly.
- Every invocation is fire-and-forget (detached, `stdio: "ignore"`); a missing
  binary, a non-zero exit, or a spawn error never reaches pi and never prints
  to the TUI.
- Reports are coalesced: kido is only invoked when the status or title actually
  changes, so a burst of tool calls costs one process, not one per call.

## Inbox

The inbox lets something outside the session — kido, a script, another agent —
hand this pi session a prompt, so a session you are not typing into can still be
given work.

On `session_start` the extension binds a unix **stream** socket and reports its
path once, as `--inbox <path>` on the first status report; kido carries that
value forward, so later reports omit it. On `session_shutdown` the socket is
closed and the file unlinked.

Path: `<state>/inbox/<first 8 chars of the session id>.sock`, where `<state>` is
`$KIDO_STATE_DIR`, else `$XDG_STATE_HOME/kido`, else `~/.local/state/kido`. The
directory is created mode 0700. The name is kept short because a unix socket
path may be no longer than ~104 bytes; if the path would exceed that, the
extension simply runs without an inbox. A leftover socket file from a pi that
died without cleaning up is removed before binding — but only after a probe
connect proves nothing is listening; if something is, the extension falls back
to `<pid>.sock` and otherwise skips the inbox.

Protocol — a client:

1. connects,
2. writes the prompt as UTF-8, with no framing,
3. half-closes its write half (`shutdown(SHUT_WR)`),
4. reads `ok\n`, and closes.

```sh
# with socat; any client that half-closes will do
printf 'run the tests and summarise failures' | socat - UNIX-CONNECT:"$sock"
```

The prompt then arrives as a real user message. Delivery mode follows the
session's state: when pi is idle it is sent plainly, which triggers a turn
immediately; while the agent is mid-stream it is sent with `deliverAs:
"followUp"`, so the running turn finishes first — `"steer"` would redirect work
the user is watching, which an externally injected prompt has no business doing.

An empty message is ignored, and anything over 1 MiB is dropped rather than
buffered. Like the status reporting, the inbox is silent and non-fatal: it never
writes to pi's stdout or stderr, and if it cannot be created or served, status
reporting carries on unaffected.
