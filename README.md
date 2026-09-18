# kido

A tmux sidebar for agent harnesses. Lists every tmux session and one row per
pane: the pane's foreground command, or for a pane running Claude Code, the
Claude session name and its live status: running, waiting for permission, or
idle. The session name comes from the pane title Claude Code sets.

```
tmux                                 <- current session in bold
┌ claude Tmux config ● running 17s   <- panes of one window share a bracket
└ zsh
· nvim                               <- single-pane window
review
· claude Fix login redirect ◆ waiting 40s
weave
· zsh
```

The selected row is shown inverted.

## How it works

- `kido` (Go, Bubble Tea) polls `tmux list-panes -a` and `ps` twice a second.
- `kido-hook` is a Claude Code hook script. Claude runs it on session start,
  prompt submit, tool use, permission requests, stop, and session end. It
  writes one JSON file per session under `~/.local/state/kido/` containing the
  tmux pane, claude pid, and status. The sidebar joins these to panes by pane id.
- Files whose claude pid is gone are treated as stale.

## Install

```sh
brew install andreypopp/tap/kido        # kido, kido-hook and the tmux configs
brew install andreypopp/tap/tmux   # the patched tmux (replaces Homebrew's tmux)
make install-hooks                      # merges hooks/settings-hooks.json into ~/.claude/settings.json
```

From source: `make install` builds and copies kido and kido-hook to
`~/.local/bin`; the tmux configs then need absolute paths since tmux's
run-shell may not have that directory on PATH.

Then in `~/.tmux.conf`:

```tmux
source-file ~/Workspace/kido/tmux/kido.tmux
```

Running Claude sessions pick up the hook config live; a session started
before the hooks were installed shows `? no hook data` until its next event.

## Keys

| key | action |
|-----|--------|
| `prefix K` | toggle the pinned sidebar server-wide: every window in every session gets a 40-column pane on the left |
| `prefix k` | focus the pinned sidebar when it is on; otherwise open the sidebar as a popup |
| `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| any text | fuzzy-filter sessions by name, best matches first |
| `Esc` | clear the filter; with no filter, closes the popup or returns focus to the pane |
| `Enter` | jump to the selected pane and clear the filter (closes the popup) |
| `C-c` | quit |

## Pinned sidebar

`kido toggle` flips the server option `@kido_sidebar`. When it turns on, every
window on the server gets a sidebar pane marked `@kido=1`; the window you
toggled from gets the focused one, with the cursor on the pane you came from.
When it turns off, all sidebar panes are killed.

`kido ensure` is run from tmux hooks (new window, new session, select window,
client session change, window layout change) so windows created while the
sidebar is on get one too. A sidebar that a layout command moved is joined
back to the left edge at full height and the configured width. Because
rotate-window and swap-pane fire no layout hook, each sidebar also checks
its own position every tick and fixes it itself.

While kido rearranges panes it holds a short lock in the server option
`@kido_busy`, so the hooks its own commands trigger do not re-enter.

Each sidebar is its own `kido` process polling once a second, so with many
windows open expect one process per window.

## Flags

- `-popup` exit after jumping (used by the popup binding)
- `-interval 500ms` refresh interval
- `-show-self` include the pane kido itself runs in
- `-socket PATH` tmux server socket; hooks pass `#{socket_path}` because their environment lacks it
- `kido toggle|ensure|focus -pane %id [-width 40]` manage the pinned sidebar; `focus` falls back to a popup when it is off

## Status mapping

| hook event | status |
|------------|--------|
| UserPromptSubmit, PreToolUse, PostToolUse | running |
| PermissionRequest, Notification(permission_prompt, agent_needs_input, elicitation_*) | waiting |
| SessionStart, Stop | idle |
| SessionEnd | file removed |

## Native sidebar in tmux?

See `docs/tmux-native-sidebar-research.md`. Upstream PR tmux/tmux#5468 adds
a display-only side status column for 3.9. On top of it we patched in
`side-status-command` (`docs/tmux-side-status-command.patch`): the column
runs kido as a real interactive program, no pane per window needed. Build
that tmux, then `source-file tmux/kido-side.tmux`. `scripts/side-testbed.sh`
kills, recreates and attaches to a throwaway server on it with a
50-session layout for trying things out (`--no-attach` to skip the attach).

## Limitations

- `make install-hooks` merges by replacing each event's hook list, and
  `uninstall-hooks` drops every event key that mentions kido-hook. If you add
  your own hooks under the same events, edit `settings.json` by hand instead.
- In pinned mode every window has its own sidebar process; jumping to another
  session lands you in that window's sidebar-equipped layout.
- Status comes only from hooks. A Claude session started before the hooks
  were installed shows `? no hook data` until its next event.

Environment: `KIDO_STATE_DIR` overrides the state directory for both the hook
and the sidebar.
