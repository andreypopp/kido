# kido as the entry point

kido stops being a sidebar plus a CLI installed beside the user's tmux and
becomes the program the user runs. It ships the tmux fork as `kido-tmux`,
starts it on its own socket, layers its own configuration over the user's,
and gives every pane a shell with the integration on. The user installs
one package and configures nothing for tmux or their shell.

This is a plan, not the design. When a phase lands, its design goes into
docs/design.md and this file loses the phase.

## Decisions taken

- **kido is the multiplexer**, not something run inside one. Bare `kido`
  attaches to the kido server, starting it if needed. Run inside any
  tmux, stock or kido's own, it refuses: `$TMUX` set means a multiplexer
  is already in charge of this terminal, and nesting one under it gives a
  second prefix and a second status line for no gain. The message says to
  run `kido` from a plain terminal.
- **Socket** is `kido` (`kido-tmux -L kido`), under `TMUX_TMPDIR` as tmux
  does it. Stock tmux and kido-tmux never share a server.
- **kido finds kido-tmux beside itself**, the way `findShared` finds
  shipped files: `KIDO_TMUX` when set, else `<dir of kido>/kido-tmux`, else
  `tmux` on PATH for a developer running from a checkout. The e2e harness
  keeps `KIDO_TMUX`.
- **The bin directory shadows `tmux` and `ssh`**. `tmux` is not optional:
  the fork's protocol differs from stock tmux, and inside a kido pane
  `$TMUX` names the kido socket, so a stock client reaching it fails with
  a version mismatch. Plugins, editors and the user's own `run-shell`
  lines all resolve `tmux` on PATH.
- **PATH is prepended from the shell integration**, which runs after the
  user's rc files, not from the launcher: macOS `path_helper` and Debian's
  `/etc/profile` both rewrite an inherited PATH.
- **The tmux fork is a git submodule** at `third_party/tmux`, pinned to a
  commit on andreypopp/tmux's `fork` branch. The pin moves from the tap
  into this repo. Homebrew's git download does not initialise submodules,
  so the formula fetches tmux as a resource at the revision the submodule
  records, printed by the same script CI uses.
- **kido has its own configuration file**, `~/.config/kido/kido.conf`
  (under `$XDG_CONFIG_HOME` when set), in tmux's syntax. The user's
  `~/.tmux.conf` is never read: a stock config often fights the side
  column, and a user who wants theirs writes one `source-file` line. The
  server starts with kido's overlay, then the user's file, so the user
  wins over kido except for what kido must own (the side column and the
  default command, which the overlay sets after).
- **Setup goes entirely**: tmux and shell configuration become
  launch-time injection, and the Claude Code hooks and the pi extensions
  are handed to those programs on their own command lines by the bin
  directory's shims, so nothing is written into anybody's home and there
  is nothing for a first launch to check.
- **Shells other than zsh and bash** get a working pane with no
  command-line status, as `kido ssh` gives them today.

## Phase 1: the fork ships with kido

Vendor the fork and build it as `kido-tmux`. Nothing user-visible changes
yet; the sidebar keeps running under whatever tmux the user has.

- `third_party/tmux` submodule; `scripts/install-tmux-fork.sh` builds from
  it and installs the binary as `kido-tmux` (`--print-revision` reads the
  gitlink, so the tap and CI resolve one commit). CI checks out with
  submodules and drops the tap lookup. `make install` places `kido-tmux`
  beside `kido`.
- `internal/tmux`: binary resolution as decided above, with a unit test
  for the order and one for a sibling that is absent.
- Tap: the `kido` formula gains a `tmux` resource and builds both; the
  separate `tmux` formula is retired at the phase 4 release, not here.
- Proof: `make e2e` passes with `KIDO_TMUX` pointing at the built
  `kido-tmux`; CI builds it from the submodule and caches by its SHA.

## Phase 2: `kido` starts or attaches

- `kido` with no arguments: refuse when `$TMUX` is set; else if a server
  answers on the kido socket, attach; else start one with a generated
  configuration. A server running an older `kido-tmux` refuses
  the new client; kido detects the mismatch and says to restart rather
  than printing tmux's error.
- The server starts with `-f` on a generated file: kido's defaults, then
  `source-file -q ~/.config/kido/kido.conf`, then the options kido owns.
  `side-status-command` names the absolute kido binary. `~/.tmux.conf`
  is not read; a `kido.conf` that sources it is the user's choice. An
  error in `kido.conf` is reported the way tmux reports one, at start.
- `kido shell`: the default command. Execs the user's shell, honouring
  their own `default-command` and `default-shell` if set, as a login
  shell to match tmux, with the integration arranged the way `kido ssh`
  arranges it on the far side: the ZDOTDIR swap for zsh, `ENV` with
  `--login --posix` for bash 4.4 and up, plain for anything else. The
  bootstrap is one implementation shared with `kido ssh`, not a copy.
- Proof, e2e: a `kido` started in the outer harness pty produces a server
  on the kido socket with a sidebar; a second `kido` attaches to it; a
  `kido` typed inside a kido pane refuses and starts nothing (the
  server's client count is unchanged, which is the assertion with teeth,
  as the refusal tests in AGENTS.md put it); the
  first pane's shell reports prompts and command lines with no rc file
  edited (the harness gives it a HOME with no integration block); a HOME
  with a `kido.conf` setting an option sees it honoured; a HOME with a
  `.tmux.conf` and no `kido.conf` sees the `.tmux.conf` ignored.

## Phase 3: the bin directory

- `<share>/bin/tmux` execs `kido-tmux`; `<share>/bin/ssh` execs
  `kido ssh`; `<share>/bin/pi` execs the real pi with `--extension` for
  each of kido's extension files, so nothing is written into
  `~/.pi/agent/extensions`. Every shim finds the real program on PATH
  after its own directory, never itself. The shell integration prepends
  the directory to PATH. Only pi started from a kido pane gets the
  extensions, which is exactly the set of sessions kido tracks.
- `<share>/bin/claude` execs the real Claude Code with `--settings`
  naming a shipped file that carries the hooks (verified on 2.1.273: the
  flag takes a file or inline JSON and merges it). Claude Code run by
  pi-claude-bridge uses the SDK's own binary, not PATH, so it gets no
  hooks and writes no inner record, which is the outcome the outer-wins
  rule in `internal/state` exists to force today.
- Proof: inside a kido pane, `tmux display-message` and `which ssh`
  resolve to the shims; `ssh -V`, `ssh host true`, and an `ssh` with a
  broken bootstrap reach the real ssh; a login shell on macOS still has
  the shim first after `path_helper`; a pi started in a kido pane with an
  empty `~/.pi/agent/extensions` has kido's tools, and one started with
  the old symlinks present does not register them twice.

## Phase 4: the release

The commands and the documentation have landed: no `setup-*` command
remains, README is written around `brew install andreypopp/tap/kido` then
`kido`, and AGENTS.md's "Releasing" section names the `kido` formula
alone. What is left is the release itself.

- Release: tap bump, the `tmux` formula retired, `brew upgrade`, and the
  user's own tmux restored to stock. The formula's tmux resource takes the
  revision `scripts/install-tmux-fork.sh --print-revision` prints.

## Phase 5, optional: tagged releases

With the fork pinned in this repo, a tag pins everything. A workflow on
`push: tags: v*` runs CI and, green, rewrites the tap formula's revision
and version and pushes with a token scoped to the tap. Needs the token.

## Order and ownership

One phase per commit series, each shippable on its own: after phase 1
nothing changes for users; after phase 2 `kido` works as an entry point
while the old setup keeps working; phase 3 and 4 remove what 2 made
redundant. Phases 1 and 3 are sonnet tasks. Phase 2 is the hard one and
gets opus, split into the launcher and the shell bootstrap once the
shared-bootstrap refactor of `kido ssh` has landed as its own commit.
