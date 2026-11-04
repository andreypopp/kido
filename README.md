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
window at a time, with every pane in a list grouped by session, and one
status mark for each pane: a running agent or command, a waiting
agent, an unseen success, an unseen failure. The mark clears when you
visit the pane.

The keys are tmux's defaults under the prefix `C-a`, in every
terminal. A status line at the bottom shows the session, its windows
(`*` the shown one, `-` the last one) and the pending prefix.

| key | action |
|-----|--------|
| `C-a C-a` | send `C-a` to the pane |
| `C-a d` | detach |
| `C-a ?` | show the keys; any key closes the list |
| `C-a r` | redraw the screen |
| `C-a c` | add a window to the shown pane's session |
| `C-a n` / `p` | show the next / previous window |
| `C-a 0` to `9` | show the window at that position in the session |
| `C-a Tab` | show the last window |
| `C-a )` / `(` | show the next / previous session |
| `C-a L` | show the last session |
| `C-a ,` / `$` | rename the window / session |
| `C-a &` | kill the window, after `y` |
| `C-a x` | kill the pane, after `y` |
| `C-a %` / `"` | split the pane left and right / top and bottom; the new pane is selected |
| `C-a z` | zoom the pane, or end the zoom |
| `C-a o` / `;` | select the next pane of the window / the pane selected before |
| `C-a` arrow, `h` `j` `k` `l`, `C-h` `C-j` `C-k` `C-l` | select the pane on that side (r) |
| `C-a C-`arrow / `M-`arrow | move the pane's divider by 1 / 5 cells (r) |
| `C-a {` / `}` | swap the pane with the previous / next pane |
| `C-a E` | give the panes of the split equal sizes |
| `C-a *` | float the pane over the window, or dock a float back into the window's split |
| `C-a !` | move the pane into a new window after the shown one |
| `C-a R` | resize mode: `h` `j` `k` `l` or arrows move the pane's divider by 1, `H` `J` `K` `L` or Shift+arrows by 5, `=` equal sizes, `z` zoom; `Enter`, `Escape` or `q` leaves |
| `C-a s` or `w` | choose a pane from the list with `Up`, `Down`, `Enter`; `Escape` leaves |
| `C-a C-s` | show or hide the list |
| `C-a e` | open the pane's scrollback in `$PAGER` |
| `C-a [` | enter copy mode on the active pane |
| `C-a PageUp` | enter copy mode one page up |
| `C-a ]` | paste the copy buffer into the active pane |
| `Ctrl+D` on an exited pane | remove it |
| click a row | show that pane |
| drag a divider | move it |

A key marked (r) repeats: for 500 ms after it, another key marked (r)
acts without the prefix, and each one restarts the 500 ms. Without
the prefix, `h` `j` `k` `l` and `C-h` `C-j` `C-k` `C-l` go to the
program. `C-a l` selects the pane on the right, so the last window
is `C-a Tab`.

The terminal client shows the window's splits, zoom and floats as
Kido.app does, and both edit the same layout. A click in a pane
selects it, a drag on a divider moves it, and the wheel scrolls the
pane under the pointer.

Copy mode uses vi keys over the pane's whole history. The pane's
output stops on the screen until you leave, and the pane's top right
shows `[offset/history]`.

| key in copy mode | action |
|-----|--------|
| `h` `j` `k` `l`, arrows | move the cursor |
| `w` `b` `e`, `W` `B` `E` | move by word |
| `0` `^` `$` | start, first non-blank, end of the line |
| `H` `M` `L` | top, middle, bottom of the screen |
| `g` / `G` | top / bottom of the history |
| `C-b` `PageUp` / `C-f` `PageDown` | one page up / down |
| `C-u` / `C-d` | half a page up / down |
| `C-y` / `C-e` | scroll one line up / down |
| `f` `F` `t` `T` and a character | jump in the line; `;` again, `,` reverse |
| `Space` or `v` | begin a selection |
| `V` | select whole lines |
| `C-v` | toggle a rectangle selection |
| `o` | go to the other end of the selection |
| `/` / `?` and a text, `Enter` | search forward / backward in the history |
| `n` / `N` | the next match in the search's direction / the reverse one |
| `Escape` | stop a running search, else clear the selection, or leave with none |
| `Enter` or `y` | copy the selection to the clipboard and the copy buffer, and leave |
| `q` | leave |
| `C-a` | leave, then take a prefix key |

A search moves the cursor to the start of the next match and wraps at
the ends of the history. `Enter` on an empty prompt repeats the last
search. ASCII letters match in either case; other letters match only
in their own case. Every match on the screen has a yellow background,
and the match under the cursor is bold.

In copy mode a click places the cursor, a drag selects, a double
click selects a word, a triple click a line, and the wheel scrolls;
the pane gets no mouse event.

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
appears in `list_agents` and accepts `message_agent`. `ko prompt` sends
text from stdin to the agent in your window, over its message stream or
as a paste for a native agent.

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
make build-ko-linux  # the static Linux ko under build/ko/share/ko/linux/<arch>/
make install    # binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/ko
make verify     # the whole verification: build, unit tests, e2e, lint, the pi extension's suite, Verus
```

The first build compiles libghostty-vt and the crates in a few
minutes. Kido.app is in `app/` (docs/design-app.md). CI verifies every push to
`main` and every pull request on Linux and macOS.

Ask your coding agent for help. Kido is designed for development with a
coding agent.
