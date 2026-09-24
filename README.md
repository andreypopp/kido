# kido

A terminal multiplexer for coding agent sessions: tmux, with a side column
listing every session, window and pane and live status for the ones running
an agent. Claude Code and pi both report; the sidebar renders them the same.

```
tmux
┌◼ Tmux config           an agent: ◼ running, ◆ waiting, ◌ compacting, ✓ done
└ zsh
╶◼ cargo test            a shell running a command (red ◼ when the last failed)
╶ ssh deploy@build-box   ssh panes show the destination
review
╶◆ Fix login redirect
```

kido ships its own tmux, [andreypopp/tmux](https://github.com/andreypopp/tmux)
built as `kido-tmux`, because the side column is a fork feature. It runs on
a socket of its own, so a stock tmux on the same machine is untouched.

## Install

```sh
brew install andreypopp/tap/kido
```

Then, from a plain terminal:

```sh
kido
```

That is the whole setup: nothing is written into `~/.zshrc`, `~/.tmux.conf`,
`~/.claude/settings.json` or `~/.pi/agent/extensions`. Check that the
sidebar is on the left, `prefix K` hides and shows it, `prefix k` toggles
focus and `/` searches.

## The launcher

`kido` with no arguments starts kido's server, or attaches to it if one is
already running. Every other invocation is a subcommand.

- The server lives on the tmux socket `kido`, under `$TMUX_TMPDIR` like any
  tmux socket. kido-tmux and a stock tmux never share a server.
- Run inside a multiplexer - `$TMUX` set, kido's own included - `kido`
  refuses and starts nothing: nesting buys a second prefix and a second
  status line. Run it from a plain terminal.
- After an upgrade the server still runs the old kido-tmux and refuses the
  new client. kido says so, and names the socket; detach and
  `kido-tmux -L kido kill-server` once its windows are free.

## Configuration

Your own configuration goes in `~/.config/kido/kido.conf`
(`$XDG_CONFIG_HOME/kido/kido.conf` when that is set), in tmux's syntax.
`~/.tmux.conf` is **not** read - a config written for stock tmux tends to
fight the side column - so if you want it, source it yourself:

```tmux
source-file ~/.tmux.conf
```

The server starts with a generated file in three layers: kido's defaults
(`tmux/kido-tmux.conf` in this repo - the side column and its keys), then
your `kido.conf`, which may override any of them, then the two options kido
owns and you cannot override, `side-status-command` and `default-command`.
The first session is named `main`. A `default-command` you set is kept and run by `kido shell`, primed. If it is just a shell's name, `zsh` or `bash` or a path to one, that shell is what gets primed, rather than being run as a command inside the login shell.

## The bin directory

Inside a kido pane, four names resolve to shims kido ships (its bin
directory is first on `PATH`):

| name | what it runs |
|------|--------------|
| `tmux` | `kido-tmux`. Required, not a convenience: `$TMUX` in a kido pane names the kido socket, and a stock tmux client gets a protocol mismatch there. |
| `ssh` | `kido ssh`, so a remote shell reports what it is running. |
| `pi` | the real pi with `--extension` for kido's two extensions, where the package ships them. |
| `claude` | the real Claude Code with `--settings` naming the shipped hooks file. |

Each finds the real program on `PATH` after its own directory, so nothing is
shadowed twice and `ssh -V`, `tmux -V` and the rest behave as always. Only
sessions started from a kido pane get any of this, which is exactly the set
of sessions kido tracks.

**pi** therefore needs no installation step: a pi started in a kido pane has
kido's status reporting, its inbox and its agent tools. **Claude Code**
reports through the hooks in the shipped settings file; `--settings` merges
with your own `~/.claude/settings.json`, which kido does not touch.

**ssh** sends a small bootstrap as the remote command, which primes the
remote zsh or bash the same way a local pane is primed, so the row shows
what the shell on the far side is running, on a host where nothing is
installed. Anything kido cannot prime - a remote command of your own, no
terminal, a login shell that is neither zsh nor bash, a remote with no
`base64`, an old bash without `PS0` - is a plain ssh session, unchanged.
`kido ssh host` is never worse than `ssh host`, and the remote `$HOME` is
never touched.

## Shells

Every pane's shell is started by `kido shell`, as a login shell, with kido's
OSC 133 integration arranged around it: zsh through a throwaway `ZDOTDIR`
that sources your real dotfiles first, bash 4.4 and up through `ENV` with
`--login --posix`. That is what makes a shell row show what it is running.
Any other shell - fish, or a bash below 4.4, which is what macOS ships as
`/bin/bash` - gets a working pane with no command status.

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
