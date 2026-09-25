# kido

A workflow on top of tmux to manage coding agents (pi and Claude Code are supported).

Kido runs a modified tmux to gather status from every pane and to render a
sidebar with this information. On top of that, kido ships with a small set of pi
extensions for process management (subagents, an async bash tool), which use
tmux for supervision and status reporting.

## Install

```sh
brew install andreypopp/tap/kido
```

Then, from a plain terminal:

```sh
kido
```

Now use it as you would use tmux.

## Configuration

Your own configuration goes in `~/.config/kido/kido.conf`
(`$XDG_CONFIG_HOME/kido/kido.conf` when that is set), in tmux's syntax.

If you want your `~/.tmux.conf` to take effect, you need to source it from
`kido.conf`:

```tmux
source-file ~/.tmux.conf
```

## Keys

By default the following keys are bound:

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| `C-s` | with the sidebar hidden, open the picker in a popup; with it shown, toggle keyboard focus |
| drag the sidebar's edge | resize it |
| `S-Up` / `S-Down` | switch the client to the previous / next window (works with the sidebar unfocused too) |

While the sidebar is focused:

| key | action |
|-----|--------|
| `j` / `k`, `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| `n` / `N` | next / previous session that wants you (waiting, or done since you last looked) |
| `gg` / `G` | first / last pane |
| `/` | fuzzy-filter by session name, agent title, or ssh destination; `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or close the picker |
| `Enter` / click | jump to the pane, then close the picker |
| `q` | close the picker |

## Status

Agent panes show `▌ running`, `◆ waiting`, `◌ compacting`, `✓ done`, or nothing
when idle. `✓ done` lasts until you visit the pane.

Shell panes with the OSC 133 integration use the same indicators: green `▌`
while a command runs, then, until you visit the pane, green `✓` if the last
one exited zero or red `▌` if it exited nonzero.

Kido overrides the `ssh` command to inject shell integration on the remote side.
This means shell panes show the status and command for remote shells as well.

## Upgrading from the setup-command era

Earlier kido was a sidebar installed beside your own tmux, configured by
`kido setup-*`. Those commands are gone, and so is the tap's `tmux`
formula. Nothing below is required - what the old setup left behind is
inert under kido - but all of it can go:

```sh
brew uninstall andreypopp/tap/tmux   # and `brew install tmux` for a stock one
rm -f ~/.pi/agent/extensions/kido-status.ts ~/.pi/agent/extensions/kido-agents.ts
```

Then delete, by hand, the marked kido blocks (`# >>> kido ... >>>` to
`# <<< kido ... <<<`) from `~/.tmux.conf`, `~/.zshrc`, `~/.bashrc` and
whichever of `~/.bash_profile`, `~/.bash_login` or `~/.profile` has one,
and the `kido hook` entries from `~/.claude/settings.json` - the shipped
settings file has them, and a duplicate just runs the hook twice.

Anything you want to keep from the sidebar block in `~/.tmux.conf` belongs
in `~/.config/kido/kido.conf` now.

## Development

```sh
make install          # binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/kido
make test             # go vet, the unit tests, and the pi extensions' node suite
make e2e              # drives kido inside a real tmux server
```

CI runs both suites on every push to `main` and every pull request, on Linux
and macOS.

Ask your coding agent for assistance; kido was built to be developed with one.

## Debugging

With `KIDO_HOOK_DEBUG` set in the environment Claude Code was started in,
every hook event appends a tab-separated line to `kido debug-log`'s path:
timestamp, `TMUX_PANE`, the raw payload, and the effect kido computed
(`unmapped` for an event outside its table). Behaviour is otherwise
unchanged. It is an environment variable rather than a flag because Claude
Code is what runs the hook.

```sh
KIDO_HOOK_DEBUG=1 claude
tail -f "$(kido debug-log)"
```

The shipped settings file registers only the events kido acts on. To see
one it does not, add a `kido hook` entry for that event to your own
`~/.claude/settings.json`; the two files are merged.
