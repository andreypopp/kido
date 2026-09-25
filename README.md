# kido

A workflow on top of tmux to manage coding agents (pi and claude code are supported).

Kido runs modified tmux to gather status from every pane and to render a
sidebar with this information. On top of that kido ships with a small set of pi
extensions for process management (subagents, async bash tool) which are
integrated with use tmux for supervision and status reporting.

## Install

```sh
brew install andreypopp/tap/kido
```

Then, from a plain terminal:

```sh
kido
```

Now start using it as you are using tmux.

## Configuration

Your own configuration goes in `~/.config/kido/kido.conf`
(`$XDG_CONFIG_HOME/kido/kido.conf` when that is set), in tmux's syntax.

If you want your `~/.tmux.conf` to take effect, you need to source it from
`kido.conf`:

```tmux
source-file ~/.tmux.conf
```

## Keys

kido runs as a one-shot picker whenever `$TMUX_SIDE_CLIENT` is empty, which
the fork sets only for the `side-status-command` job - a popup or a plain
pane gets the picker, and the side column keeps the behaviour below.

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| `C-s` | with the sidebar hidden, open the picker in a popup; with it shown, toggle keyboard focus |
| drag the sidebar's edge | resize it |
| `j` / `k`, `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| `gg` / `G` | first / last pane |
| `S-Up` / `S-Down` | switch the client to the previous / next window (works with the sidebar unfocused too) |
| `n` / `N` | next / previous session that wants you (waiting, or done since you last looked) |
| `/` | fuzzy-filter by session name, agent title, or ssh destination; `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or return focus to the pane |
| `Enter` / click | jump to the pane |

The picker has its own, smaller set:

| key | action |
|-----|--------|
| `q` | close the picker |
| `Esc` / `C-c` | clear the filter, or close the picker |
| `Enter` / click | jump to the pane, then close the picker |

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

An `ssh` pane is the exception: once its far side marks a prompt, the row
shows the remote shell's commands with the same indicators, beside the
destination. That needs the integration on the remote, which `kido ssh`
supplies for a host that does not have it.

Claude Code reports through `kido hook`. Dismissing a question or denying a
permission fires no hook, so kido reads the pane and returns it to idle
once the input box is back and nothing is running. pi reports through
`kido agent-status`, and a pi pane is recognised before it reports anything
from the pi in its process tree.

State lives in `~/.local/state/kido/`.

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

`make install` also builds the tmux fork from the `third_party/tmux`
submodule and installs it as `$PREFIX/bin/kido-tmux`. kido finds its tmux as
`$KIDO_TMUX`, else a `kido-tmux` beside its own binary, else `tmux` on
`PATH` - the last being how a build in a checkout runs.

`make e2e` needs the fork on `PATH` or at `KIDO_TMUX=/path/to/tmux`, and
skips without it; `KIDO_E2E_REQUIRED=1` makes it fail instead. Build the
fork on its own with `scripts/install-tmux-fork.sh <prefix>`.

CI runs both suites on every push to `main` and every pull request, on
Linux and macOS, building the fork from the submodule at the revision it
pins.
