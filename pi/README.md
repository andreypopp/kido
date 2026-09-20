# pi extension: kido-status

Reports a [pi](https://github.com/earendil-works/pi) session's live status to
kido, so pi sessions show up in the kido tmux sidebar next to Claude Code ones.

It shells out to:

```
kido agent-status --agent pi --session <id> --status running|waiting|compacting|idle \
     [--title <text>] [--ended] [--remove]
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
| `session_shutdown` | `--remove` |

- If `kido` is not on `PATH`, or pi is not running inside tmux, the extension
  does nothing at all, quietly.
- Every invocation is fire-and-forget (detached, `stdio: "ignore"`); a missing
  binary, a non-zero exit, or a spawn error never reaches pi and never prints
  to the TUI.
- Reports are coalesced: kido is only invoked when the status or title actually
  changes, so a burst of tool calls costs one process, not one per call.
