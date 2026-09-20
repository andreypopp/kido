# kido

A tmux sidebar for coding agent sessions. It runs inside the side status
column of [andreypopp/tmux](https://github.com/andreypopp/tmux), a tmux fork
with `side-status-command`, and lists every session and pane with the live
status of agent panes. Claude Code and pi are both supported, and look the
same in the sidebar: a status indicator and the session title, whichever
agent is running.

```
tmux
┌ ● Tmux config          <- an agent session: ● running, ◆ waiting, ◌ compacting, ✓ done, ○ idle
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
| `/` | search: type to fuzzy-filter by session name or agent session title, `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or return focus to the pane |
| `Enter` / click | jump to the pane |

## Commands

`kido switch-session next|prev [-client NAME]` switches the current client
to the adjacent session in the sidebar's order (oldest first, ties by name),
wrapping around. It defaults to `$TMUX_SIDE_CLIENT`, then the current
client, when `-client` is not given. Not bound by default; bind it yourself,
e.g. in `~/.tmux.conf`:

```
bind-key -n S-Up   run-shell "kido switch-session prev -client '#{client_name}'"
bind-key -n S-Down run-shell "kido switch-session next -client '#{client_name}'"
```

`kido switch-window next|prev [-client NAME]` switches the current client to
the adjacent window in the sidebar's order: a single flat list across the
whole server, sessions oldest first then each session's windows in tmux's
own order, wrapping around. This walks *across* sessions - advancing past a
session's last window moves to the next session's first window - unlike
tmux's own `next-window`/`previous-window`, which wrap inside one session.
It otherwise behaves exactly like `switch-session` above (same flags,
defaults, and no-op cases). It's the same example keys as `switch-session`
above; bind one or the other, or pick different keys for each:

```
bind-key -n S-Up   run-shell "kido switch-window prev -client '#{client_name}'"
bind-key -n S-Down run-shell "kido switch-window next -client '#{client_name}'"
```

`kido prompt [--window]` reads a prompt from stdin and types it into the
one agent pane in scope, then presses Enter. By default the scope is
the caller's own tmux window, widening to the whole session when the
window has no agent pane at all; a window with several is still
ambiguous and never widens (several in the window means several in the
session too), so only "not found" widens the search. `--window` pins the
scope to the caller's window only, never widening to the session. Exit
codes: `0` sent, `1` no prompt given (empty stdin) or a tmux error, `4`
agent not found in scope, `5` multiple agents found.

```sh
echo "run the tests" | kido prompt
echo "run the tests" | kido prompt --window
```

## Status

Agents report what they are doing and the sidebar badges their pane with
it: work in flight shows `● running`, a permission prompt or a question
`◆ waiting`, context compaction `◌`, a session that is sitting at its
prompt `○ idle`. A session stays `● running` at turn end while background
commands or agents it started are still running, and one that finishes
while you are elsewhere shows `✓ done` until you visit its pane. The label
next to the indicator is the pane's own title, as the agent set it. State
lives in `~/.local/state/kido/`.

Claude Code reports through `kido hook`, registered by `kido setup-claude`.
Dismissing a question or denying a permission fires no hook at all, so
there kido reads the pane instead and returns the session to idle as soon
as its input box is back with nothing running.

pi reports through `kido agent-status`, which any agent that is not Claude
Code can call from inside its own pane:

```
kido agent-status --agent NAME --session ID --status running|waiting|compacting|idle [--title TITLE] [--ended] [--remove]
```

`--title` is the session's name, shown in place of the agent's pane title
(kept across calls that omit it, so an extension only needs to re-send it
when it changes). `--ended` marks the end of a turn (that is what `✓ done`
tracks) and `--remove` drops the session's record when the agent exits. A
pi pane is recognised even before it reports anything, from the pi in the
pane's process tree.

`kido setup-pi` installs a status extension for the pi coding agent into
`~/.pi/agent/extensions/`, which pi discovers on its next start. pi panes
then show the same indicators and titles as Claude Code panes. When pi
runs Claude Code inside itself, the sidebar shows pi, not the embedded
session.

`kido snapshot` prints a shell script that recreates every session,
window, pane and layout, resuming Claude Code panes by their exact session
id. Run it outside tmux after a `tmux kill-server`.

## Debugging

`kido setup-claude --debug` registers `kido hook --debug` for every Claude
Code hook event (not just the ones kido acts on). Each event then appends
a line to `kido debug-log`'s path (tab-separated: timestamp, `TMUX_PANE`,
the raw hook payload, and the effect kido computed, or `unmapped` for
events outside its table) instead of changing behavior otherwise. Run
`kido setup-claude` again (without `--debug`) to go back to normal.

```sh
kido setup-claude --debug
tail -f "$(kido debug-log)"
kido setup-claude   # back to normal
```

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
