# kido

A tmux sidebar for Claude Code sessions. It runs inside the side status
column of [andreypopp/tmux](https://github.com/andreypopp/tmux), a tmux fork
with `side-status-command`, and lists every session and pane with the live
status of Claude Code panes.

```
tmux
┌ ● Tmux config          <- a Claude Code session: ● running, ◆ waiting, ◌ compacting, ○ idle
└ zsh
· nvim
· ssh deploy@build-box      <- panes running ssh show the destination
review
· ◆ Fix login redirect
```

## Install

```sh
brew install andreypopp/tap/kido
brew uninstall tmux && brew install andreypopp/tap/tmux
```

`~/.tmux.conf`:

```tmux
source-file /opt/homebrew/share/kido/kido-side.tmux
```

Then `kido setup-claude` registers the hook in `~/.claude/settings.json` so
Claude Code reports its status.

## Keys

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| drag the sidebar's edge | resize it |
| `j` / `k`, `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| `gg` / `G` | first / last pane |
| `/` | search: type to fuzzy-filter sessions by name, `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or return focus to the pane |
| `Enter` / click | jump to the pane |

## Status

`kido hook` is the Claude Code hook. Prompt submit and tool use show
`● running`, permission requests `◆ waiting`, context compaction `◌`,
session start and stop `○ idle`. State lives in `~/.local/state/kido/`.

## Setting up another machine

For an agent or a human bootstrapping a fresh macOS box with Homebrew:

1. Install the tmux fork and kido (the tap's `tmux` replaces Homebrew's):

       brew uninstall tmux 2>/dev/null; brew install andreypopp/tap/tmux andreypopp/tap/kido

2. Load the sidebar on every server start and register the Claude Code hook.
   Use the literal path: tmux does not expand `$(brew --prefix)`.

       printf '\n# kido sidebar\nsource-file %s/share/kido/kido-side.tmux\n' "$(brew --prefix)" >> ~/.tmux.conf
       kido setup-claude

3. Start or attach a session from a terminal outside tmux. To carry a layout
   over from another machine, capture it there with `tmux list-panes -a -F`
   into a script of `new-session`, `split-window` and `select-layout` calls,
   typing `claude --continue` into panes that were running Claude.

4. Check: `tmux -V` prints `next-3.9`, the sidebar is on the left, `prefix K`
   hides and shows it, `prefix k` toggles keyboard focus, `/` searches.
