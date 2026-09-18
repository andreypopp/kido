# kido

A tmux sidebar for Claude Code sessions. It runs inside the side status
column of [andreypopp/tmux](https://github.com/andreypopp/tmux), a tmux fork
with `side-status-command`, and lists every session and pane with the live
status of Claude Code panes.

```
tmux
┌ ● Tmux config          <- a Claude Code session: ● running, ◆ waiting, ◌ compacting, ✓ done, ○ idle
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

Load the sidebar on every server start. tmux does not expand
`$(brew --prefix)` inside its config, so write the literal path:

```sh
printf '\n# kido sidebar\nsource-file %s/share/kido/kido-side.tmux\n' "$(brew --prefix)" >> ~/.tmux.conf
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
| `n` / `N` | next / previous session that wants you (waiting, or done since you last looked) |
| `/` | search: type to fuzzy-filter sessions by name, `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or return focus to the pane |
| `Enter` / click | jump to the pane |

## Status

`kido hook` is the Claude Code hook. Prompt submit and tool use show
`● running`, permission prompts and questions `◆ waiting`, context
compaction `◌`, session start and stop `○ idle`. A session stays
`● running` at turn end while background commands or agents it started
are still running. A session that finishes while you are elsewhere shows
`✓ done` until you visit its pane. State lives in `~/.local/state/kido/`.

`kido snapshot` prints a shell script that recreates every session,
window, pane and layout, resuming Claude Code panes by their exact session
id. Run it outside tmux after a `tmux kill-server`.

## Tests

`make test` runs `go vet` and the unit tests.

`make e2e` runs the end-to-end tests, which drive a real tmux server built
from the [andreypopp/tmux](https://github.com/andreypopp/tmux) fork (branch
`side-pane`). They need that fork's `tmux` binary either on `PATH` or
pointed to via `KIDO_TMUX=/path/to/tmux`; set `KIDO_E2E_REQUIRED=1` to make
them fail instead of skip when the fork isn't available. Build the fork
locally with `scripts/install-tmux-fork.sh <prefix>`.

CI runs both `make test` and `make e2e` on every push to `main` and every
pull request, on both Linux and macOS.

## Setting up another machine

For an agent or a human bootstrapping a fresh macOS box with Homebrew:

1. Install the tmux fork and kido (the tap's `tmux` replaces Homebrew's):

       brew uninstall tmux 2>/dev/null; brew install andreypopp/tap/tmux andreypopp/tap/kido

2. Add the `source-file` line from Install to `~/.tmux.conf`, then
   `kido setup-claude`.

3. To carry the sessions over, run `kido snapshot > layout.sh` on the old
   machine, copy the script, adjust any paths that differ, and run it from a
   terminal outside tmux on the new one.

4. Check: `tmux -V` prints `next-3.9`, the sidebar is on the left, `prefix K`
   hides and shows it, `prefix k` toggles keyboard focus, `/` searches.
