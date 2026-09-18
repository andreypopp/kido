# kido

A tmux sidebar for Claude Code sessions. It lives in the side status column
of [andreypopp/tmux](https://github.com/andreypopp/tmux), a tmux fork that
adds `side-status-command`: a column on the edge of every window, in every
session, running an interactive program. kido lists sessions and panes
there and badges Claude Code panes with their live status.

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

## Install

```sh
brew install andreypopp/tap/kido
brew uninstall tmux && brew install andreypopp/tap/tmux   # the fork, replaces Homebrew's tmux
```

In `~/.tmux.conf`:

```tmux
source-file "$(brew --prefix)/share/kido/kido-side.tmux"
```

Then merge `$(brew --prefix)/share/kido/settings-hooks.json` into
`~/.claude/settings.json` (or run `make install-hooks` from a checkout) so
Claude Code reports session status. Running Claude sessions pick the hooks
up live; a session started before that shows `? no hook data` until its next
event.

## Keys

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| `prefix <` / `>` | narrow or widen the sidebar (or drag its edge with the mouse) |
| `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| any text | fuzzy-filter sessions by name, best matches first |
| `Esc` | clear the filter; with no filter, return focus to the pane |
| `Enter` | jump to the selected pane and clear the filter |
| click | jump to the pane under the pointer |

## How it works

- tmux runs `kido` once per attached client in a pty the size of the column.
- kido polls `tmux list-panes -a` and `ps` twice a second, sorts sessions by
  creation time, and follows the client's active pane.
- `kido-hook` is a Claude Code hook script. Claude runs it on session start,
  prompt submit, tool use, permission requests, stop, and session end. It
  writes one JSON file per session under `~/.local/state/kido/` with the tmux
  pane, claude pid, and status; the sidebar joins these to panes by pane id.

| hook event | status |
|------------|--------|
| UserPromptSubmit, PreToolUse, PostToolUse | running |
| PermissionRequest, Notification(permission_prompt, agent_needs_input, elicitation_*) | waiting |
| SessionStart, Stop | idle |
| SessionEnd | file removed |

`KIDO_STATE_DIR` overrides the state directory for both the hook and the
sidebar. `scripts/side-testbed.sh` starts a throwaway server with 50
sessions for trying things out.

## From source

`make install` builds and copies `kido` and `kido-hook` to `~/.local/bin`.
tmux's `run-shell` may not have that directory on PATH, so point the config
at absolute paths in that case. The binary also still supports running as a
pinned pane per window (`kido toggle`, `kido ensure`, `kido focus`) or in a
popup (`kido -popup`) on a stock tmux.
