# kido

A tmux sidebar for Claude Code sessions. It runs inside the side status
column of [andreypopp/tmux](https://github.com/andreypopp/tmux), a tmux fork
with `side-status-command`, and lists every session and pane with the live
status of Claude Code panes.

```
tmux
┌ claude Tmux config ● running 17s
└ zsh
· nvim
review
· claude Fix login redirect ◆ waiting 40s
```

## Install

```sh
brew install andreypopp/tap/kido
brew uninstall tmux && brew install andreypopp/tap/tmux
```

`~/.tmux.conf`:

```tmux
source-file "$(brew --prefix)/share/kido/kido-side.tmux"
```

Then `kido setup-claude` registers the hook in `~/.claude/settings.json` so
Claude Code reports its status.

## Keys

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| `prefix <` / `>` | narrow or widen the sidebar (or drag its edge) |
| `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| typing | fuzzy-filter sessions by name |
| `Esc` | clear the filter, or return focus to the pane |
| `Enter` / click | jump to the pane |

## Status

`kido hook` is the Claude Code hook. Prompt submit and tool use show
`● running`, permission requests `◆ waiting`, session start and stop
`○ idle`. State lives in `~/.local/state/kido/`.
