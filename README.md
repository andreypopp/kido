# kido

A tmux workflow to manage coding agents. It supports pi and Claude Code.

Website: <https://kido.tools>

Kido runs a modified tmux to collect status from every pane and show this
information in a sidebar. Kido includes a small set of pi extensions for
process management: subagents and an async bash tool. These extensions use
tmux for supervision and status reporting.

## Install

```sh
brew install andreypopp/tap/kido
```

Then start kido from a plain terminal:

```sh
kido
```

Use kido as you use tmux.

## Configuration

Put your configuration in `~/.config/kido/kido.conf`, with tmux syntax.
If you set `$XDG_CONFIG_HOME`, use `$XDG_CONFIG_HOME/kido/kido.conf` instead.

If you want to use your `~/.tmux.conf`, source it from `kido.conf`:

```tmux
source-file ~/.tmux.conf
```

### Sidebar colours

The sidebar colours are tmux options that use tmux style syntax:
`fg=`, `bg=`, `bold`, `italics`, ... . Colours use the 16 ANSI colour names,
`colourN` or `#rrggbb`. The sidebar reads the options about once a second.
Thus, a reload changes its style within a second. An unset option keeps
the default. The sidebar's last row names the first invalid option.

| option | styles |
|--------|--------|
| `@kido-sidebar-row-style` | pane titles: agents, and the host of an ssh row |
| `@kido-sidebar-command-style` | a shell's command |
| `@kido-sidebar-dim-style` | tree lines, captions, elapsed times |
| `@kido-sidebar-session-style` | other sessions' names; `bg=` fills the row |
| `@kido-sidebar-current-style` | the current session's name; `bg=` fills the row |
| `@kido-sidebar-current-rows-style` | `bg=` fills the current session's rows |
| `@kido-sidebar-running-style`, `-waiting-`, `-done-`, `-error-` | status glyphs |

`side-status-style` sets the panel behind these rows. For example:

```tmux
set -g @kido-sidebar-row-style          "fg=#eee8d5"
set -g @kido-sidebar-command-style      "fg=#eee8d5"
set -g @kido-sidebar-dim-style          "fg=#586e75"
set -g @kido-sidebar-session-style      "fg=#c9d1cf,bold,bg=#123c48"
set -g @kido-sidebar-current-style      "fg=#fdf6e3,bold,bg=#1f5566"
set -g @kido-sidebar-current-rows-style "bg=#0f3a47"
```

## Keys

The default key bindings are:

| key | action |
|-----|--------|
| `prefix K` | show the sidebar with keyboard focus, or hide it |
| `prefix k` | toggle keyboard focus between the sidebar and the pane |
| `C-s` | with the sidebar hidden, open the picker in a popup; with it shown, toggle keyboard focus |
| drag the sidebar's edge | resize it |
| `S-Up` / `S-Down` | switch the client to the previous / next window (works with the sidebar unfocused too) |

When the sidebar has keyboard focus:

| key | action |
|-----|--------|
| `j` / `k`, `C-j` / `C-k`, `C-n` / `C-p` | move between panes |
| `gg` / `G` | first / last pane |
| `/` | fuzzy-filter by session name, agent title, or ssh destination; `Esc` cancels |
| `Esc` / `C-c` | clear the filter, or close the picker |
| `Enter` / click | jump to the pane, then close the picker |
| `q` | close the picker |

## Status

The OSC 7501 root app `pi` or `claude-code` identifies agent panes.
pi and Claude Code show native running, waiting, done and idle status.
Blocked messages supply the caption. Pane titles name sessions.
Done status continues until you visit the pane.

Claude Code runs unmodified, without a kido shim or settings.
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` also disables its native status.
`kido prompt` can paste to a native agent pane. Only local pi identities
appear in `list_runs`, accept `message_agent`, or answer `get-agent`.
Snapshots resume local pi identities or restart bare pi, not Claude Code.

Shell panes with the OSC 133 integration use the same indicators:

- Green `▌` while a command runs.
- Green `✓` if the last command exited zero, until you visit the pane.
- Red `▌` if the last command exited nonzero, until you visit the pane.

Kido overrides the `ssh` command to add shell integration on the remote side.
Thus, shell panes also show the status and command for remote shells.

## Upgrading from the setup-command era

Earlier kido used a sidebar installed beside your own tmux, with
configuration from `kido setup-*`. Those commands and the tap's `tmux`
formula no longer exist. The old setup files have no effect under kido.
The steps below are optional, but you can remove all these files:

```sh
brew uninstall andreypopp/tap/tmux   # and `brew install tmux` for a stock one
rm -f ~/.pi/agent/extensions/kido-status.ts ~/.pi/agent/extensions/kido-agents.ts
```

Then manually delete the marked kido blocks (`# >>> kido ... >>>` to
`# <<< kido ... <<<`) from these files:

- `~/.tmux.conf`
- `~/.zshrc`
- `~/.bashrc`
- Whichever of `~/.bash_profile`, `~/.bash_login` or `~/.profile` has a block.

Delete obsolete kido entries from `~/.claude/settings.json`.

If you want to keep settings from the sidebar block in `~/.tmux.conf`,
put them in `~/.config/kido/kido.conf`.

## Development

kido uses OCaml and dune's own package management. dune downloads and
builds the compiler and every dependency from `dune.lock` into `_build`.
It does not use opam.

`make install` builds the tmux fork first. It needs:

- git
- A C toolchain
- make
- bison
- autoconf
- automake
- pkg-config
- The headers and libraries for libevent, ncurses and utf8proc.

`make e2e` needs Go. The TypeScript tests need Node 24 or newer.

```sh
curl -fsSL https://get.dune.build/install | sh -s - --release 3.24.2
export PATH="$HOME/.local/bin:$PATH"
git clone --recurse-submodules https://github.com/andreypopp/kido.git && cd kido
make install   # binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/kido
make test      # the unit tests and the pi extensions' suite (needs node 24)
make e2e       # drives kido inside a real tmux server
dune tools install ocamlformat && dune fmt   # ocamlformat is a dune dev tool, not a dependency
```

The dune installer installs into `~/.local`. It also prints an environment
file that you can source. It cannot change the calling shell's `PATH`.

The first build compiles OCaml and the dependencies in a few minutes.
After a dependency changes in `dune-project`, `dune pkg lock` regenerates
`dune.lock`. The project commits the resulting file.

CI runs both suites on Linux and macOS for every push to `main` and every
pull request.

Ask your coding agent for help. kido is designed for development with a
coding agent.
