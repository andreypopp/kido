# Kido

A terminal server for coding agents. It supports pi and Claude Code.

Website: <https://kido.tools>

Kido runs `ko`, its server and command-line client. ko holds the
terminal of every pane, collects the status of every agent and shell,
and runs agents as subagents of each other. Kido.app is the native
macOS client. ko-pi is the pi harness for process management: subagents,
messages between agents and an async bash tool.

## Install

```sh
brew install andreypopp/tap/ko
```

Kido.app, the macOS client:

```sh
brew install --cask andreypopp/tap/kido-app
```

## Use

Start ko from a plain terminal:

```sh
ko
```

`ko` connects to your server, and starts one if none runs. It shows one
pane at a time, with every pane in a list grouped by session, and one
status mark for each pane: a running agent or command, a waiting
agent, an unseen success, an unseen failure. The mark clears when you
visit the pane.

The keys are Ctrl+Shift chords, which need a terminal with the kitty
keyboard protocol (Ghostty, kitty, WezTerm, foot, Kido.app):

| key | action |
|-----|--------|
| `Ctrl+Shift+S` | show or hide the list |
| `Ctrl+Shift+Up` / `Down` | show the previous / next pane |
| `Ctrl+Shift+N` | add a window to the shown pane's session |
| `Ctrl+Shift+E` | open the pane's scrollback in `$PAGER` |
| `Ctrl+Shift+Q` | detach |
| `Ctrl+D` on an exited pane | remove it |
| click a row | show that pane |

The wheel scrolls the shown pane. The terminal client shows no splits,
tabs or windows and has no copy mode: the scrollback goes to `$PAGER`.
Kido.app shows sessions, windows, splits and floats.

`ko HOST` attaches to a ko server on another machine over ssh, and
reconnects when the connection drops. It never starts a server there:
run `ssh HOST ko server` once.

Every pane runs your login shell with a shell integration, so shell
panes show a running command, a green `✓` for the last command's
success and a red mark for a failure, until you visit the pane. Kido
overrides `ssh` to add the same integration on the remote side.

## Agents

The OSC 7501 root app `pi` or `claude-code` identifies agent panes. pi
and Claude Code show native running, waiting, done and idle status.
Claude Code runs unmodified, without a shim or settings.
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` also disables its native
status.

Start pi as `ko-pi` to load the harness. Only a pi started as `ko-pi`
appears in `list_runs` and accepts `message_agent`. `ko prompt` sends
text from stdin to the agent in your window, over its inbox or as a
paste for a native agent.

`ko --help` lists the commands: the server, `ko api` for one request
to the server, the run commands, `ko panes` and `ko layout`.

## Development

ko is a Rust cargo workspace. It needs:

- git
- rustup from Homebrew (`brew install rustup`, then
  `$(brew --prefix rustup)/bin/rustup toolchain install`, which reads
  `rust-toolchain.toml`). The Makefile finds that cargo itself.
- zig at the release of `scripts/install-zig.sh`, on PATH
- make, a C compiler and `tic`
- Node 24 or newer for the pi extension's tests

```sh
git clone --recurse-submodules https://github.com/andreypopp/kido.git && cd kido
make build-ko   # the installed layout under build/ko/
make install    # binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/ko
make verify     # the whole verification: build, unit tests, e2e, lint, the pi extension's suite, Verus
```

The first build compiles libghostty-vt and the crates in a few
minutes. Kido.app is in `app/` (docs/design-app.md). CI verifies every push to
`main` and every pull request on Linux and macOS.

Ask your coding agent for help. Kido is designed for development with a
coding agent.
