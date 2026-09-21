# kido

A tmux sidebar for coding agent sessions. It runs in the side status column
of [andreypopp/tmux](https://github.com/andreypopp/tmux), a fork with
`side-status-command`, and lists every session, window and pane with live
status for agent panes. Claude Code and pi both report; the sidebar renders
them the same.

```
tmux
┌ ▌ Tmux config          an agent: ▌ running, ◆ waiting, ◌ compacting, ✓ done
└   zsh
· ▌ cargo test           a shell running a command (red ▌ when the last failed)
· ssh deploy@build-box   ssh panes show the destination
review
· ◆ Fix login redirect
```

## Install

1. Install the fork and kido (the tap's `tmux` replaces Homebrew's):

       brew uninstall tmux 2>/dev/null; brew install andreypopp/tap/tmux andreypopp/tap/kido

2. `kido setup-tmux` adds a marked block to `~/.tmux.conf` sourcing the
   sidebar config kido ships. Reload with `tmux source-file ~/.tmux.conf`,
   or restart tmux.

3. `kido setup-claude` registers the hook in `~/.claude/settings.json` so
   Claude Code reports its status. If you use pi, `kido setup-pi` installs
   its status extension into `~/.pi/agent/extensions/`.

4. Optional, zsh only: `kido setup-zsh` adds a marked block to `~/.zshrc`
   sourcing the script that emits the OSC 133 markers tmux reads to tell
   whether a pane is running a command. Shells already running are
   unaffected.

5. Optional: bind the popup picker, which is not bound by default (see
   Popup for what the wrapping is for):

       bind-key P run-shell -b "tmux display-popup -c '#{client_name}' -E -w 40 -h 80% 'kido -client #{client_name}'"

6. Check: `tmux -V` prints `next-3.9`, the sidebar is on the left,
   `prefix K` hides and shows it, `prefix k` toggles focus, `/` searches,
   and `prefix P` opens the picker if you bound it.

Both `setup-tmux` and `setup-zsh` source the shipped file only if it is
there. A second run leaves the block alone; a block pointing elsewhere is
rewritten in place.

## Keys

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| drag the sidebar's edge | resize it |
| `j` / `k`, `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| `gg` / `G` | first / last pane |
| `S-Up` / `S-Down` | switch the client to the previous / next window |
| `n` / `N` | next / previous session that wants you (waiting, or done since you last looked) |
| `/` | fuzzy-filter by session name, agent title, or ssh destination; `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or return focus to the pane |
| `Enter` / click | jump to the pane |

## Popup

kido runs as a one-shot picker whenever `$TMUX_SIDE_CLIENT` is empty, which
the fork sets only for the `side-status-command` job. A popup or a plain
pane gets the picker; the side column keeps the behaviour above.

```
bind-key P run-shell -b "tmux display-popup -c '#{client_name}' -E -w 40 -h 80% 'kido -client #{client_name}'"
```

`display-popup` does not expand `#{...}` in the command it runs, and a
popup has no client of its own, so `#{client_name}` asked from inside it
answers with whichever client tmux saw last. `run-shell` does expand
formats, which is what lets `-client` and `-c` name the right one.

| key | action |
|-----|--------|
| `q` | close the picker |
| `Esc` / `C-c` | clear the filter, or close the picker |
| `Enter` / click | jump to the pane, then close the picker |

## Commands

### `kido switch-session next|prev [-client NAME]`

Switches the client to the adjacent session in the sidebar's order (oldest
first, ties by name), wrapping around. `-client` defaults to
`$TMUX_SIDE_CLIENT`, then the current client. Not bound by default:

```
bind-key -n S-Up   run-shell "kido switch-session prev -client '#{client_name}'"
bind-key -n S-Down run-shell "kido switch-session next -client '#{client_name}'"
```

### `kido switch-window next|prev [-client NAME]`

The same, over one flat list of windows across the whole server: sessions
oldest first, each session's windows in tmux's order. Advancing past a
session's last window moves to the next session, where tmux's own
`next-window` wraps inside one session.

### `kido prompt [--window]`

Reads a prompt from stdin and sends it to the one agent pane in scope.

Scope is the caller's tmux window, widening to the session when the window
has no agent pane. A window with several agents does not widen. `--window`
never widens.

pi receives a user message over the unix socket its extension reported with
`kido agent-status --inbox`. Every other agent, Claude Code included, gets
the prompt pasted into its pane followed by Enter, as does pi when the
socket has gone away. It is a paste rather than typed keys because an
application with bracketed paste on reads a bare newline as a submit,
which would split a multi-line prompt into one input per line.

Exit codes: `0` sent, `1` empty stdin or an error, `4` no agent in scope,
`5` several.

```sh
echo "run the tests" | kido prompt
echo "run the tests" | kido prompt --window
```

### `kido agent-status`

```
kido agent-status --agent NAME --session ID --status running|waiting|compacting|idle \
  [--title TITLE] [--inbox PATH] [--ended] [--remove]
```

How any agent other than Claude Code reports, called from inside its own
pane. `--title` is shown in place of the pane title. `--inbox` is a unix
socket the agent takes prompts on. Both are kept across calls that omit
them; `--inbox ""` clears the socket. `--ended` marks the end of a turn,
which is what `✓ done` tracks. `--remove` drops the record.

The socket speaks one prompt per connection: written with no framing,
ended by half-closing the write half, answered with `ok\n`. An agent whose
own socket frames messages differently must not report it here.

### `kido inbox-path NAME`

Prints `<state dir>/inbox/NAME.sock`, creating the `inbox` directory with
mode `0700`. A name containing a path separator or `..`, or one whose path
would not fit in `sun_path`, prints nothing and exits 1.

```sh
kido agent-status --agent pi --session "$id" --status idle \
  --inbox "$(kido inbox-path "$id")"
```

### `kido setup-pi`

Installs the status extension into `~/.pi/agent/extensions/`, which pi
picks up on its next start. A symlink there is left alone, so that name can
point at a checkout. When pi runs Claude Code inside itself, the sidebar
shows pi, not the embedded session.

### `kido snapshot`

Prints a shell script that recreates every session, window, pane and
layout, resuming Claude Code and pi panes by session id. A pane that
reported no session is recreated bare. Run it outside tmux after a
`tmux kill-server`.

## Status

Agent panes show `▌ running`, `◆ waiting`, `◌ compacting`, `✓ done`, or
nothing when idle. A session stays running at turn end while background
commands or agents it started are still going. `✓ done` lasts until you
visit the pane.

Shell panes with the OSC 133 integration use the same indicators: green `▌`
while a command runs, then, until you visit the pane, green `✓` if the last
one exited zero or red `▌` if it exited nonzero. A shell without the
integration has no indicator column. A program that has taken the
terminal (an editor, a pager, an `ssh` shell) shows no indicator.

Claude Code reports through `kido hook`. Dismissing a question or denying a
permission fires no hook, so kido reads the pane and returns it to idle
once the input box is back and nothing is running. pi reports through
`kido agent-status`, and a pi pane is recognised before it reports anything
from the pi in its process tree.

State lives in `~/.local/state/kido/`.

## Debugging

`kido setup-claude --debug` registers `kido hook --debug` for every Claude
Code hook event, not only the ones kido acts on. Each event appends a
tab-separated line to `kido debug-log`'s path: timestamp, `TMUX_PANE`, the
raw payload, and the effect kido computed (`unmapped` for events outside
its table). Behaviour is otherwise unchanged.

```sh
kido setup-claude --debug
tail -f "$(kido debug-log)"
kido setup-claude   # back to normal
```

## Tests

`make test` runs `go vet` and the unit tests.

`make e2e` drives a real tmux server built from the fork's `side-pane`
branch. It needs that binary on `PATH` or at `KIDO_TMUX=/path/to/tmux`, and
skips without it; `KIDO_E2E_REQUIRED=1` makes it fail instead. Build the
fork with `scripts/install-tmux-fork.sh <prefix>`.

CI runs both on every push to `main` and every pull request, on Linux and
macOS.
