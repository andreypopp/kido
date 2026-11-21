# Kido's agent features, as built

This document owns ko's agent-facing behavior: pane messages, launches,
window lifecycle and sidebar topology. [design-ko.md](design-ko.md)
describes the server and [protocol.md](protocol.md) its contract.
[design-program-status.md](design-program-status.md) owns pane
classification. For the harness, see [design-koa.md](design-koa.md).

ko mediates between panes. It does not read harness files or own the
agents inside a harness. `AGENTS.md` supplies repository constraints.

## Who is authoritative for what

Each owner holds its own facts:

**The layout document, for topology.** The server supplies these
facts (protocol.md, section 7):

- the window and session that contain each pane;
- each pane's immutable `parent` and `close`;
- the pane's foreground command;
- which clients show a pane and which has focus;
- whether the pane's process has exited, and how;
- whether the pane's message stream is open (the row's `inbox`).

Nothing caches these facts. A pane can move between windows and
sessions while its process runs.

**Harness identity and session state.** See [design-koa.md](design-koa.md#extension-boundary-and-identity) for koa's identity publication and registry; ko keeps only pane state.

Only OSC 7501 root records supply status. OSC 0/2 supplies the pane
title. design-program-status.md, "Pane kinds", gives the
classification. Prompt
scope accepts both agent kinds: a pane with an open message stream
gets a message, any other agent a paste.

There is no locking, because every writer is the server's loop thread.

## The harness extension

See [design-koa.md](design-koa.md#agent-extension-subagents-and-jobs) for the extension, identity, messages and delivery inside koa.

## Delivery, and when a paste is allowed

`ko prompt` reads its text from stdin and sends it to the server with
its pane identity, its pane as `from` and an id that it mints. The
server picks the one agent of the caller's window other than the
caller, unless `--target PANE[/RECORD]` names another live agent in
the caller's session or a promptable record of it, such as a koa
subagent, and delivers (protocol.md, section 11). A pane whose message
stream is open, and every record target, gets the text as a message
of kind `user` that names the target's record. The CLI
sends once: a paste has no id, and a prompt that the user did not see
arrive is the user's to send again.

A paste and a separate Enter key go only to a classified agent
without an open message stream. A bare pi is not an agent target;
see design-program-status.md.

See [design-koa.md](design-koa.md#addressing-and-messages) for the extension's message-only delivery rule.

## Spawning

See [design-koa.md](design-koa.md#spawn-resume-and-peers) for tool addressing, subagent creation and top-level agent requests.

### Starting a koa agent

A koa agent starts in one of two ways, and both give the same
`koa_agent` row: the user types `koa` in a pane, or a client sends
`POST /panes` (or a new pane of `PUT /layout`) with the `koa` case of
`Command` (`ko_wire/src/protocol.rs`), whose fields are typed. The
server alone turns it into koa's
flags (`program` in `ko_server/src/panes.rs`), so no client builds
koa's argv. Each valued flag is one argument, `--name=VALUE`, so a
value that starts with `-`, such as a name `--browser`, stays a value
for koa's strict parser. The task is not part of it: a spawner gives it as the
pane variable `koa.task`.

On the host, routed or not, the server runs `<its ko> shell -- koa
...` ("The login environment"): the server does not look koa up. The
login shell resolves the bare name `koa` on the PATH that the user's
login files give at this start, so a new install of koa or a change
of the dotfiles needs no server restart, while the server's own PATH
is the one fixed when it started (design-app.md). When the login PATH
has no koa, `ko shell` keeps the pane as a start failure ("Window
lifecycle") and its screen reads `ko shell: koa was not found on the
login PATH`. The row's `command` is `koa` and its flags, without the
shell. In a runtime, the runtime's shell runs the bare `koa`.

The request's `cwd` is koa's launch directory, and koa takes it as
the session's directory, also for a resumed session or an existing
session id. A `runtime` places the pane by the runtime's `koa`
setting (design-runtimes.md, "A koa command in a runtime"), which
also says what the cwd is there.

### The login environment

The server starts a pane's argv directly, with only the server's
environment and the request's. A koa that the user starts in a pane
runs under the user's shell, which read the user's dotfiles: EDITOR,
PATH additions (node), API keys, LANG. So that every agent gets the
same environment, the server starts a `koa` command ("Starting a koa
agent") as `<its ko> shell -- koa ...`. A subagent shares
its koa's environment. A job runs its
command through pi's shell configuration, as pi's `bash` does,
because its command is not an agent.

`ko shell -- CMD...` resolves the shell as the bare `ko shell` does
("Priming a local shell"). For bash, zsh, sh, dash and ksh it execs
`SHELL -l -i -c SCRIPT SHELL KO CMD...`. SCRIPT puts ko's bin directory
first on PATH again, as a primed pane does after the login files, then
runs `exec "$@"` on CMD. It names only ko's own directory, and ko's
path and the argv pass as positional parameters, so no shell parses
model text. When `command -v` does not find CMD's first word after
the login files, SCRIPT sets its pane's `close` to `keep` through
`KO api` and exits 1 with `ko shell: NAME was not found on the login
PATH`, as ko's wrappers do for a failure before the user's program
("Window lifecycle"). The
shell is interactive, because EDITOR often lives in `.zshrc`. The
shell integration is not installed, and no prompt runs before the
exec, so the pane gets no OSC 133 marks from ko, and koa's OSC 7501
root classifies it. Because the shell execs, koa keeps the pane's
process: the pane's death is koa's. If the exec of a command that was
found fails, the shell exits 126. Another shell, such as fish, has no `"$@"`
semantics: ko execs CMD directly, and the user's dotfiles do not run.

### Failure leaves no pane

A `POST /panes` that cannot start its pane keeps the old document and
answers `io`.

## Window lifecycle

A pane with a `parent` is a child pane, such as koa's editor
floats. ko has no other lifecycle object: a pane's row is
the whole record, and ko keeps nothing after the pane goes. A
subagent is no pane, so none of this applies to it.

**The pane stop.** `POST /panes/pane_N/stop` (protocol.md, section 7)
waits up to its `wait` for the pane to die and removes it. The
removal hangs up the program: `ko-pane` sends `SIGHUP`, then
`SIGKILL` 250 ms later; if the removed pane still lives after
`KO_STOP_ESCALATION_MS`, the coordinator kills it.

A dead pane keeps its last screen until the sweep removes it.

**The sweep** (`ko_server/src/state/sweep.rs`). The server sweeps
when one of its inputs changes: a pane's death or removal, the
focused panes, and the end of a linger grace (protocol.md, section
10). It reads only the pane rows, so it acts on any pane by its
`close` and `parent`. Three rules apply:

1. A pane with `close: exit`, the default, has died by an exit or a
   signal. The sweep removes it at once, also while a focused client
   shows it: a shell that ends with Ctrl-D closes its pane, as in a
   terminal. An exec or `cwd` failure of `ko-pane` (the cause
   `failed`) keeps its dead pane, so the user reads the error on its
   screen. ko's own wrappers (`ko shell`, `ko enter`, `ko
   runtime-exec`) that fail before the user's program runs, for
   example when a runtime does not come up, first set their own
   pane's `close` to `keep` with `PATCH /panes/{id}` (protocol.md,
   section 7), then print the error and exit 1: a normal exit that
   the sweep does not remove. A shell's Ctrl-D returns the status of
   its last command, so the exit code does not select the rule.
2. A pane with `close: on_exit` has been dead for the linger grace
   (`server: linger_seconds` of the configuration file, 30 s by
   default; design-ko.md, "The configuration file"). The sweep
   removes it.
3. A pane's `parent` is gone or dead. The sweep removes the pane at
   once, live or dead, also while a focused client shows it. The rule
   reads no process and no pi evidence, by design.

Rule 3 forces a stop instead of requesting a graceful shutdown. It is
the only available action outside the child, and it ends a `tail -f`
that an exited parent started. A pane without a
parent is a root that the sweep must not cancel.

The sweep never collects an `on_exit` pane for its linger grace while
a client with terminal focus shows it (protocol.md, section 3); it
tries again when the focus changes.
Waiting loses nothing. It does not protect a session's last window: an
empty session ends.

**A removal takes the subtree.** The collection unit is the pane,
not its window. The sweep removes the pane with a pane delete, which,
as every delete, also removes the pane's descendants through their
`parent` links, focused or not, in the same change; a window that
loses its last pane goes with it, and an empty session with it
(protocol.md, section 7). The server owns this cascade, so a close in
Kido.app, a `ko api` delete and the sweep remove the same panes, and
no client sends a delete for each descendant. The focus guard above
only defers the sweep's choice of a pane; it does not keep a
descendant of a pane that is removed. The pane stop and its
escalation do the same.

**The selection after a removal.** When the child's window goes with
the child, its client moves to the child's nearest surviving
ancestor pane, because the user came from there (protocol.md, section
3). The death of an `on_exit` or `keep` pane alone moves no client,
so the last screen stays readable for the linger grace. The removal
of an `exit` pane moves its clients by the same repair rules.

No other guard applies: no debounce. Without grace under rule 3, a
child already shutting down can lose its pane during exit.

## Subagent lifecycle

See [design-koa.md](design-koa.md#the-registry-and-reporting) for reports, stops and resumed work.

## The sidebar tree

Both clients build the tree from the layout document and the pane
rows (`ko_client/src/model.rs`, with the walk of
`ko_client/src/tree.rs`). A subagent of koa is no pane: it is a status
record of koa's pane, and Kido.app draws it as a record row under the
pane row (design-koa.md, "Status records and signals"). A child pane
follows the pane that created it, one level deeper, not after the
whole parent window. The edge is the row's immutable `parent`, which
the server sets at create. The tree nests a pane under its parent
only when both are in the same window: a child in its parent's
window, such as koa's editor, floating or docked beside it, nests
under its parent. A child in another window, or under a parent in
another session, is a root of its window, and its window is an
ordinary window of its session, with its own tab, which the
server's window switch (protocol.md, section 3) visits like any
other. The edge still decides the lifetime: a removal of the parent
takes the child, in any window.

The terminal client draws the list as session headers and pane rows,
indented by depth (`ko_tui/src/sidebar.rs`); its chooser (`C-a s`)
visits every row in that order. Kido.app draws its tree with
indentation and folded children (design-app.md, "Sidebar").

Below the tree, pinned to the bottom of the sidebar, both clients
list the runtimes of the configuration and of the current session
(design-runtimes.md, "Clients"). In the terminal client they are the
last rows of the column, after one empty row, and they are read-only: a faint header with the count of up
runtimes, then each name with its state at the right, a failed state
in red. They have no colour, actions or selection, so the client stays
a mirror; `ko api` is its start and stop. It does not show the
configuration error. The tree does not scroll, so the rows appear only
when the whole tree fits above them; a longer tree takes the column,
and the chooser never selects a row that the footer hides.

The walk uses parent-first ordering and emits every item exactly once,
with or without a tree. A parent edge can form a cycle in a
document that a client did not get from the server; the walk emits
missed items afterward as roots, so an invalid
edge loses only the item's tree position. A self-edge means "no
parent". Siblings retain arrival order.

## Priming a remote shell

An `ssh` pane reports remote activity only from remote reports. The
pane's terminal parses OSC 133 from the output without knowing the
markers crossed a network. The status model latches the pane after a
remote prompt marker later than the local ssh-start marker. The remote
shell must source `share/ko/zsh/integration.zsh` or
`share/ko/bash/integration.bash`. Both emit the same markers.

On a host without an installed integration, the marked pane remains
running throughout the connection. `ko ssh` sets `ssh.dest` on its
pane to the destination as typed, then execs ssh. The mark remains
after ssh exits; ko trusts it only while the foreground command is
`ssh` (design-program-status.md, "The ssh mark").

**What is sent.** The binary embeds the integrations
(`ko_shell/src/prime.rs`, with `include_str!`). ko base64-encodes them
in a POSIX sh bootstrap and sends this as ssh's remote command. Every
connection carries both integrations, regardless of the remote login
shell. It also carries ko's compiled `xterm-ghostty` entry, which ko
reads at run time from the terminfo of the installed layout
(`ko_shell/src/bin_dir.rs`); a missing entry ships nothing. stdin
remains available for the interactive session.

**The terminfo.** A pane's `TERM` is `xterm-ghostty`, and ssh passes
it on, so a host without the entry gives full-screen programs an
unknown terminal. Before it selects a branch, the bootstrap asks
`infocmp xterm-ghostty`. When the host resolves the entry, it does
nothing. Otherwise (a missing `infocmp` counts as a missing entry,
because a probe of the system directories would only guess at the
host's ncurses), it decodes the entry into `~/.terminfo` in both
directory forms, `x/` (ncurses on Linux) and `78/` (macOS), because
the host's form is unknown and the file is the same. It never
overwrites an existing file there: each write goes to a temporary file
in the target directory and moves with `mv -n`, so a concurrent
connection or a user's own entry wins. No `tic` runs on the host. The
install succeeds when `infocmp` then resolves the entry, or, without
`infocmp`, when both files exist. Otherwise (a read-only home, no
space, no payload, an unusable existing file) the session gets
`TERM=xterm-256color` and starts as before.

**What that costs, said plainly.** The payload is a public shell
script without secrets, so ko permits it in argv. All sidebar
information about the pane comes from the remote host's report. A host
can report any claim about what it runs.

**The ZDOTDIR swap.** The bootstrap creates a fresh directory with
`mktemp -d` and decodes the integration there. It writes `.zshenv`
beside the integration, sets `ZDOTDIR` to that directory and execs the
login shell. The generated `.zshenv` restores `ZDOTDIR`:
`KO_ORIG_ZDOTDIR` carries the user's value when set. Apart from the
terminfo entry, the bootstrap writes nothing in remote `$HOME`. The
swap occurs only if the user already has zsh dotfiles.

**The bash branch.** The bootstrap sets `ENV` to a file beside the
decoded integration and execs the login shell with `--login --posix`.
That file disables posix mode again, sources `/etc/profile`, then the
first of `~/.bash_profile`, `~/.bash_login` or `~/.profile`, then the
integration, and removes the directory. Before priming bash, the
bootstrap asks the login shell for its version once; an answer below
4.4, or no version, starts the login shell plain. Older bash reads its
login files without markers, through the same route as an unsupported
shell.

**Nothing persists but the terminfo.** ko resends the payload on every
connection, and only the terminfo entry stays on the host, except for
the zsh completion directory of a shell that ends without `zshexit`. `.zshenv`
reads the integration into a parameter and keeps the directory for
`_ko` ("Completion" below). At its first `precmd` zsh loads `_ko`,
deletes `.zshenv` and the integration file, then sources the integration,
not in `.zshenv`, so ko's hooks come after the user's setup and ko's
bin directory is again first on PATH as the last step.

**Degrade, never break.** `ko ssh host` must not behave worse than
`ssh host`. ko passes the command line unchanged, without `-t` or a
remote command, unless all priming conditions apply: a destination, no
user-supplied remote command, a local tty, and none of the
no-login-shell options `-N`, `-T`, `-W`, `-f`, `-n`, `-s`, `-O`, `-Q`,
`-V`, `-G`. For priming, ko adds `-t`. Every remote failure (an
unsupported shell, a missing `mktemp` or `base64`, a decoding failure)
starts the same login shell without priming; a failed terminfo install
only changes `TERM`. ko execs ssh, so signals, exit status and tty
behave as with ssh alone. The bootstrap selects
its branch by the remote login shell's basename.

ko intentionally does not implement a remote ko binary, ControlMaster
sharing, askpass or fish. `ko HOST`, the remote attach, is a different
thing (design-ko.md, "Remote").

## Priming a local shell

`ko shell` is the default pane command. It resolves the user's shell
in this order, checking each candidate for executability: `$KO_SHELL`
(the server's shell: `server: shell` of the configuration file, else
its own `$SHELL`), `$SHELL`, the shell of the user's account
(`ko_sys::user::login_shell`, `getpwuid_r`), `/bin/sh`. Inside a
runtime (`$KO_RUNTIME` set) it skips `$KO_SHELL`, because that is the
host server's shell: a container's environment often has no `$SHELL`,
and the account's shell (root's `/bin/bash` in Debian) is primed where
`/bin/sh` is not. A command that is one word whose basename is `bash`
or `zsh` (a bare name found on PATH) is that interactive shell, with
the same priming. It runs a login shell
with the same priming as `ko ssh`:

- zsh with any of `.zshrc`, `.zshenv`, `.zprofile` or `.zlogin` in
  `$ZDOTDIR` else `$HOME` uses a temporary `ZDOTDIR` (`ko-shell.XXXXXX`,
  mode 0700). Its files source the user's real files, then the
  integration.
- bash 4.4 or newer uses `ENV` with `--login --posix`.
- Other shells use plain mode: no files, a dashed argv[0].

`ko_shell/src/prime.rs` supplies one implementation for mode selection,
temporary-directory contents, argv tail and minimum bash version.
Transport differs: the remote side has only sh, so these parts
generate a POSIX ssh bootstrap. A failure to write the files falls
back to plain mode. `ko shell -- CMD...` with any other command runs
it in the same shell, without priming ("The login environment").

The bash integration uses `PS0` for command-start markers and
`PROMPT_COMMAND` for prompt markers. Sourcing it a second time causes
no action. The integrations blank control characters and limit the
command line to 1024 characters. At each prompt, before the prompt
marker, both report the directory as OSC 7, `file://HOST/PATH`, with
the shell's own hostname (`$HOST`, `$HOSTNAME`) and every byte of the
path outside `[A-Za-z0-9/._~-]` percent-encoded, so a split or a new
tab starts there (protocol.md, section 15, "The cwd of a new pane").
The real hostname matters: the same integrations run on the far side
of `ko ssh`, and the server ignores a host pane's report for another
host.

**Completion.** Every primed shell completes `ko` with no change to the user's
dotfiles. The shells ask the `ko` that the pane's PATH resolves (the
bin directory's shim, so Kido.app's bundled ko answers in its panes).
The stubs hold clap_complete's callback themselves and never run the
registration form `COMPLETE=<shell> ko`: a ko without completion
treats that as plain `ko` and starts the terminal client, while the
callback's `ko -- WORDS...` is only a usage error there, which the
stub discards. A clap_complete bump that changes the callback's
variables fails the e2e test that compares them with the generated
script.

- zsh: the temporary `ZDOTDIR` holds `_ko` (`share/ko/zsh/_ko`, with
  `#compdef ko`) in its own `0700` subdirectory `completions`, because
  `compaudit` also checks the parent of each `fpath` entry, and a
  world-writable `/tmp` as that parent makes `compinit` stop at its
  "insecure directories" question. Its `.zshenv` puts that
  subdirectory first on `fpath`
  before it sources the user's `.zshenv`, and again after it, so the
  user's own `compinit` finds `_ko`; ko never runs `compinit`. At the
  first prompt it loads `_ko` into memory, maps `ko` to it with
  `compdef` when `compinit -C` read an older dump without `_ko`, and
  deletes the other two files. The directory with `_ko` stays on
  `fpath` until the main shell's `zshexit` deletes it; the cleanup does
  nothing in a subshell, because zsh also runs `zshexit` when a
  subshell exits with `exit` (`(exit)`, `$(exit)`). So a `compinit`
  that runs after
  the first prompt (a plugin manager's reload, a hook that runs
  `compinit` again when `$FPATH` changed) still finds `_ko`. ko does
  not change `fpath` after `.zshrc`, so such a hook sees no change. A
  shell killed without `zshexit` leaves the directory with `_ko` in the
  temporary directory (`ko-shell.*` locally, `${TMPDIR:-/tmp}/ko-ssh.*`
  on a remote), where the OS clears it; so does an `exec` that replaces
  the shell, because `zshexit` does not run then.
- bash: `share/ko/bash/integration.bash` registers its function with
  the builtin `complete`, so completion works with or without
  bash-completion, also in bash 3.2, which gets no OSC 133 marks. It
  joins the words that bash splits at `=` and `:` before the callback,
  so `--server=DIR` reaches ko as one word.

Over `ko ssh` the same files go to the remote side; where the remote
has no `ko`, Tab completes nothing for `ko`.

## The bin directory

ko ships two `sh` shims in `<prefix>/share/ko/bin`: `ko` and `ssh`.
Their source is `share/ko/bin`; the shared helper is
`share/ko/shim.sh`. Inside a pane, those names resolve to these shims:

- `ko` execs `<prefix>/bin/ko` relative to its shim. Pane commands use
  this prefix's binary, not another installation on PATH.
- `ssh` runs `ko ssh "$@"`. `ko ssh` finds the real ssh after the bin
  directory (`look_path_past` in `ko_shell/src/bin_dir.rs`).

`koa` is not ko's: it is its own package with its own shim
(design-koa.md, "Build, install and run"), so `koa` in a pane is the first
`koa` of the user's PATH.

A shim never embeds an installed path. It calculates every location
from `$0`. For user-installed programs, the shim selects the first
same-name executable on PATH *after* its own directory, or, if its
directory is absent from PATH, the first match that is not itself. The
rule is "after", not "anything but me": a second installation's shim
is a different file, and the latter rule would send the call there and
back.

**PATH.** The bin directory becomes first on PATH in two places: the
server puts it first in every pane's environment (`--bin-dir`, else
`share/ko/bin` beside the installed `ko`), before `ko shell` runs, so
commands without an intervening user shell see it; and every locally
primed shell's integration places it first again at the end, after
login files that can rewrite PATH. The prepend first removes all
existing occurrences, so a nested shell never increases PATH length.
`ko ssh` sends the shipped integrations unchanged; the remote side has
no ko or shims, so nothing changes PATH there.

`of_exe` in `ko_shell/src/bin_dir.rs` tries the unresolved executable
path first and resolves only as a fallback: Homebrew's `bin/ko` and
`share/ko` are symlinks whose targets change on each upgrade, and a
resolved Cellar path would leave every pane's PATH with a nonexistent
target after the next cleanup. A `ko` binary without an adjacent
`share/ko`, such as a checkout build, uses no shims. A plain-mode shell
keeps the shims only if its login files preserve the inherited PATH
order.

**Install layout.** `make build` lays out `build/ko/` as installed:
`bin/ko`, `bin/ko-pane` and `share/ko` with `bin/`, `shim.sh`,
`webview/` (the SDK and `ko-api.d.ts`) and the terminfo; koa has its
own layout (design-koa.md, "Build, install and run"). `make
install` copies it under
`PREFIX`, default `~/.local`. This is Homebrew's `pkgshare` layout.

## Knobs

`ko_server/src/config.rs` defines server test knobs. The e2e suite
passes them in the server's environment. The linger grace and runtime
idle are configuration keys, read at each use; tests change their
private server's configuration file.

See [design-koa.md](design-koa.md#development) for harness test controls.

## Known limits

A `ko ssh` session killed before remote zsh reads its bootstrap can
leave its temporary directory on the remote host. A remote attach
shows the remote server's agents; it does not make them peers of
local agents.

See [design-koa.md](design-koa.md#agent-extension-subagents-and-jobs) for the harness's lifecycle and signal limits.
