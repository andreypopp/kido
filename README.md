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
A `default-command` you set is kept and run by `kido shell`, primed.

## The bin directory

Inside a kido pane, four names resolve to shims kido ships (its bin
directory is first on `PATH`):

| name | what it runs |
|------|--------------|
| `tmux` | `kido-tmux`. Required, not a convenience: `$TMUX` in a kido pane names the kido socket, and a stock tmux client gets a protocol mismatch there. |
| `ssh` | `kido ssh`, so a remote shell reports what it is running (see below). |
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

## Shells

Every pane's shell is started by `kido shell`, as a login shell, with kido's
OSC 133 integration arranged around it: zsh through a throwaway `ZDOTDIR`
that sources your real dotfiles first, bash 4.4 and up through `ENV` with
`--login --posix`. That is what makes a shell row show what it is running.
Any other shell - fish, or a bash below 4.4, which is what macOS ships as
`/bin/bash` - gets a working pane with no command status.

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
pane gets the picker; the side column keeps the behaviour above. It is not
bound by default:

```tmux
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
`$TMUX_SIDE_CLIENT`, then the current client. Not bound by default (the
defaults file carries the same thing for `switch-window`, commented out):

```tmux
bind-key -n S-Up   run-shell "kido switch-session prev -client '#{client_name}'"
bind-key -n S-Down run-shell "kido switch-session next -client '#{client_name}'"
```

### `kido switch-window next|prev [-client NAME]`

The same, over one flat list of windows across the whole server: sessions
oldest first, each session's windows in tmux's order. Advancing past a
session's last window moves to the next session, where tmux's own
`next-window` wraps inside one session.

### `kido ssh [ssh args...] destination`

ssh, with the remote zsh or bash primed to report to the sidebar: the row
then shows what the shell on the far side is running, on a host where
nothing is installed. This is what `ssh` runs inside a kido pane.

```sh
kido ssh deploy@build-box
kido ssh -o BatchMode=yes -p 2222 build-box
```

The arguments are ssh's own and are passed through in order. kido sends a
small bootstrap as the remote command, which decodes the shell
integration into a temporary directory and execs the login shell primed
for it. For zsh that means pointing `ZDOTDIR` at the directory; its
`.zshenv` hands `ZDOTDIR` straight back before the real dotfiles are read
and then deletes itself. Bash has no `ZDOTDIR`, and a login bash ignores
`--rcfile`, so the bootstrap execs it with `--login --posix` and an `ENV`
pointing into the same directory - the one lever that gets bash to read a
file of its own choosing before a login shell's - which turns posix mode
back off, sources `/etc/profile` and the first of `~/.bash_profile`,
`~/.bash_login` or `~/.profile`, sources the integration, and removes the
directory. Either way the remote `$HOME` is never touched and nothing
outlives the session.

Bash needs 4.4 for the `PS0` hook the integration uses; an older bash gets
its login files and no priming, the same as any other shell kido does not
know.

Anything kido cannot prime - a remote command of your own, no terminal,
a login shell that is neither zsh nor bash, a remote with no `base64`, an
option meaning there is no login shell in this connection - is a plain
ssh session, unchanged. `kido ssh host` is never worse than `ssh host`.

The payload rides in the ssh command line, where the remote's `ps` can
read it. It is a public shell script with no secrets in it, which is what
makes that acceptable; the alternative channel is the interactive
session's own stdin. The remote also self-reports, which is a weaker
claim than the local process table kido reads for everything else.

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

### `kido snapshot`

Prints a shell script that recreates every session, window, pane and
layout, resuming Claude Code and pi panes by session id. A pane that
reported no session is recreated bare. Run it outside tmux after a
`kido-tmux -L kido kill-server`.

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
make install          # binary to $BIN (default ~/.local/bin), shared files to $BIN/../share/kido
make test             # go vet, the unit tests, and the pi extensions' node suite
make e2e              # drives kido inside a real tmux server
```

`make install` also builds the tmux fork from the `third_party/tmux`
submodule and installs it as `$BIN/kido-tmux`. kido finds its tmux as
`$KIDO_TMUX`, else a `kido-tmux` beside its own binary, else `tmux` on
`PATH` - the last being how a build in a checkout runs.

`make e2e` needs the fork on `PATH` or at `KIDO_TMUX=/path/to/tmux`, and
skips without it; `KIDO_E2E_REQUIRED=1` makes it fail instead. Build the
fork on its own with `scripts/install-tmux-fork.sh <prefix>`.

CI runs both suites on every push to `main` and every pull request, on
Linux and macOS, building the fork from the submodule at the revision it
pins.
