# Developing kido

What kido does and how it is installed is in [README.md](README.md). This
file is the context that is not in the code: the tmux fork it depends on,
what terminal programs actually report, and the invariants a plausible-looking
change would break.

kido's own design decisions - which store is authoritative for what, the
inbox protocol, addressing, the ask/reply cycle rule, spawning and the
window lifecycle, run outcomes, the heartbeat, and the seam between the
two pi extensions - live in [docs/design.md](docs/design.md), with the
subagent side in [docs/design-subagents.md](docs/design-subagents.md),
the external-client RPC in [docs/design-rpc.md](docs/design-rpc.md),
and how a pane is classified and its status read in
[docs/design-program-status.md](docs/design-program-status.md).
Read them before changing any of that; neither the code's comments nor
this file repeat it.

## Code rules

These are hard rules, for OCaml and TypeScript alike.

**No backward compatibility, ever.** The binary, the extensions, the
shims and the tmux config ship together from one checkout, and the tmux
server is restarted when they must agree. Do not write fallbacks for
state an older kido left behind (old tmux marks, old record fields, old
flags or env vars), version gates, deprecated aliases or migration
paths. Change both sides and delete the old one. A leftover from an
older kido that a restart or a user action clears is not a bug.

**Plain functions over data.** Abstraction only when it pays: no
functor, object or first-class module without a second instance. Data
structures carry the design: make illegal states unrepresentable. A set
of cases is a variant (a discriminated union in TS), not a record of
options or a combination of bools; a value with its own rules gets its
own type, abstract in the `.mli`, parsed once at the edge, not a string
checked in several places; parallel fields or maps describing one thing
are one record.

**Minimal line count.** Do not abstract what has one use: a function,
type, interface, constant, option struct or test helper with a single
caller is inlined. No wrappers that only forward, no interfaces or
swappable vars without a second implementation, no dead code or unused
parameters. Duplicated logic is merged into one place.

**Module boundaries.** Each subcomponent lives in its own module (an
OCaml module and its `.mli`, a TS module) and is used through its
exported surface. `bin/main.ml` wires subcommands to `lib/` modules
and holds the commands too small to be library code; domain logic
belongs in the module that owns the domain.

**Library code returns, the CLI reports.** A `lib/` function returns
its result (a value, an `option`, a `result`); it does not print,
`failwith` or `exit`. A command body that only calls the library, prints
and returns an exit code lives in `bin/main.ml`. A `lib/` module whose
sole export is such a command body, used only by `bin/main.ml`, is
inlined there.

**State.** One source of truth per fact: never hold the same fact in two
stores (a state record and a tmux option, an OCaml record and a TS copy, a
file and an in-memory mirror). Do not store what can be derived; compute
it when needed. Each piece of state is read and written through the one
module that owns it.

**No comments unless absolutely necessary.** Code should explain
itself: no narration, no doc comment restating the name, no history
("previously", "no longer", "since this fix"), no design rationale -
that belongs in `docs/`. What remains is a verified external constraint
the code cannot express (a tmux, pi, Claude Code or OS quirk), the
reason for a workaround for as long as the workaround lives, and a link
to the issue behind either.

Build, compiler and formatter directives are not comments. A diagnostic
suppression hiding a correctness failure means fixing the cause. A stale
comment is worse than none because it is trusted: when a mechanism
changes, grep for the prose that described it.

## OCaml

These are fixed:

- **Layout.** `bin/main.ml` is the cmdliner command table, plus the
  bodies of small commands (`set_status`, `get-agent`, `snapshot`,
  `ssh`, ...). `lib/` is the library `kido`,
  one module per domain or subcommand with logic of its own. `lib_tmux/` is the library `tmux` (call sites read
  `Tmux.Conn`, `Tmux.Pane`, `Tmux.Exec`). Tests are ppx_expect in
  `lib/test/` and `lib_tmux/test/`.
- **Every stanza compiles with `-open Containers`.** Every `.ml` has an
  `.mli` unless it holds only types. JSON is yojson with
  ppx_deriving_yojson. The TUI is Mosaic, pinned in `dune-project`.
  Concurrency is `unix` and `threads.posix`; no Eio, no Lwt.
- **The command line is a contract** with `share/` and `test_e2e/`: subcommands, flags, exit codes, every parsed or
  asserted stdout/stderr line, JSON shapes, env vars. A long option is
  `--name`, never `-name`.

Conventions:

- **Errors.** A `lib/` failure is a `result`: a string error holding the
  message to print, or a variant where the caller or the message differs
  by case (`State.record` returns `Error holder`). The `Unix_error` and
  `Sys_error` the I/O raised propagate. Nothing catches to rethrow.
- **Subcommands.** A subcommand body in `bin/main.ml` returns its exit
  code, run under `Cli.run name` (`bin/cli.ml`), which prints a raised
  failure as `kido <name>: <message>` and returns 1; a string error
  reaches it through `Result.get_or_failwith`. A special code is
  returned after `Cli.error`. cmdliner's own parse errors exit 1.
  Library errors do not repeat the command name: `Cli.run` supplies it.
  Warnings during a command go through a `~warn` callback so stderr stays
  in order.
- **Environment.** Read it at the edge and pass the value: functions
  take `~dir`, `~threshold`, `~now`. Tests pass a temp dir; nothing in a
  test sets an env var or swaps a global.
- **Time** is `Timestamp.t`, unix seconds as a float, on disk as RFC 3339
  UTC. Timeouts are optional arguments, not mutable refs.
- **Containers** shadows polymorphic `=` and `compare`: use
  `String.equal`, `Float.(>)`, etc. ppx_deriving_yojson encodes variants
  as `["Tag"]`; string enums need hand-written codecs.
- **Cmdliner docs.** A bare `$` is markup and produces "unescaped $"
  on `--help`; write environment variables as `$(b,NAME)`.
  `test_e2e/help_test.go` rejects any help stderr.
- **Quoting.** `Reap.quote` in `lib/reap.ml` deliberately uses Go-style
  `%q` quoting: OCaml `%S` escapes non-ASCII agent names.
- **Inbox JSON.** `from.session` must be written even when empty.
  It has no default annotation; `Msg.envelope_to_yojson` adds `v` to the
  derived encoding. `lib/test/test_msg.ml` pins the field set.
- **Tmux I/O.** No injected tmux/ops records whose only other
  implementation is a test fake: call `Tmux.Exec` directly and test
  through e2e. `Tmux.Conn` has no mutex; only the sidebar's single tick
  may touch it.
- **Mosaic.** The grid's default foreground is truecolor white, so
  every style sets `fg` explicitly. A lone Escape arrives about 0.5s
  late.
- `dune build`, `dune test`, `dune fmt`, with no opam: dune's package
  management builds the compiler and every dependency of `dune.lock`
  into `_build` (README.md, "Building" below).

## Layout

    bin/main.ml        the cmdliner command table and the small commands:
                       set_status, get-agent, get-inbox, snapshot,
                       ssh, get-window, switch-session/window, server,
                       runs, run-outcome, reap, close-run,
                       rpc
    bin/cli.ml         failure printing and tables
    lib/               the library kido:
      launch.ml        the launcher and `kido server`: --server, the
                       server.conf in its state dir, KIDO_PROTOCOL
      build_id.ml      the immutable dune-build-info version, or unknown
      shell.ml, prime.ml  kido shell: the login shell and its priming files
      bin_dir.ml       the shipped-file and bin-directory lookup
      sidebar.ml       the sidebar's model: the tick, tracking and the shell-status
                       debounce, rows as data, the feed's v2 JSON
      ui.ml            the Mosaic sidebar: the model's rows drawn, keys, cursor
      state.ml         one JSON file per agent session, keyed by session id
      reporting.ml     kido agent-status
      procs.ml         ssh argument parsing and whitespace fields
      msg.ml           the inbox wire protocol and its client: v0 raw prompt,
                       v1 envelope, the unix-socket sender and notify
      tree.ml          the parent-first walk behind list_runs and the sidebar
      reap.ml          which subagent windows are finished with, and when;
                       an ending's text and its send to the parent's inbox
      subrun.ml        the durable record of one `kido tool spawn_subagent`
      prompt.ml, message_agent.ml (also ask_agent and notify_parent),
      list_runs.ml, spawn_subagent.ml, async_bash.ml,
      async_run.ml (its wrapper), async_stream.ml, runs.ml,
      control.ml (stop_run, interrupt_subagent)
                       one subcommand or family each
      fs.ml, timestamp.ml  files, time
      test/            ppx_expect unit tests, test_<module>.ml; fixture.ml and
                       sh.ml the shared scaffolding
    lib_tmux/          the library tmux: pane.ml (the pane format and its
                       parse), exec.ml (one-shot tmux commands, the binary
                       lookup), conn.ml (the control-mode client)
      test/            its ppx_expect tests, needing only tmux; fixture.ml's
                       pane, which lib/test's Fixture includes; tmux_server/
                       the Conn tests against a real tmux, run only with $KIDO_TMUX
    share/             the source of share/kido, installed by share/dune:
      bin/             the bin directory's sh shims (kido, tmux, ssh, pi)
      shim.sh          their shared helper
      bash/, zsh/      the OSC 133 integrations every primed shell sources
      tmux/            kido-tmux.conf, the defaults the launcher writes into
                       server.conf (embedded, not installed)
      pi/              the two pi extensions, which the pi shim loads with --extension
    .pi/prompts/       gh-watch.md, /gh-watch: starts scripts/main-watch.sh streamed
    .pi/extensions/    no-git-writes, the spawned agent's bash-tool guard
    scripts/           install-tmux-fork.sh, the fork build;
                       verify.sh, scrubbed verification and flake runs;
                       release.sh, the Homebrew tap release;
                       lint.sh, code hygiene, doc references and prompt snapshots;
                       main-watch.sh, CI for each observed main head;
                       ci-website-watch.sh, deploys for observed heads touching the website;
                       ci-like.sh and ci-like/Dockerfile, the Linux reproduction;
                       test-ts.sh; dump-prompts.ts, every prompt text pi registers
    third_party/tmux   the tmux fork, a git submodule built as kido-tmux
    test_e2e/          tests driving kido inside a real tmux server, in Go

`snapshot`, `prompt`, `switch-session`, `reap` and `runs` stay even
without production callers: e2e calls `reap` for a deterministic sweep,
and `runs` is the CLI reader of run history.

`dune build`; the executable stanza is `bin/main.exe`, installed as `kido`.
`lib/` embeds the shell integrations and `share/tmux/kido-tmux.conf`.
Promotion substitutes the build id through dune-build-info.
`build/main.exe` is the stamped executable copied by `make install` and
e2e; `_build/default/bin/main.exe`
reports `unknown`. `kido --version` prints that id; `kido server` reports the
binary's `Protocol.value` as its JSON `protocol` field (always a string), and the
creating server's global `KIDO_PROTOCOL` as its `server` field (always present,
null if unset, the stamp string otherwise even when it matches `protocol`).
The launcher, `kido server`, `rpc` and `switch-session/window`
accept `--server DIR`. `switch-window` prints nothing. A server is its
state directory; its socket is `<dir>/socket`. The default is resolved by `State.dir`: inside a pane,
`$TMUX` wins when its socket is named `socket` and `server.conf` exists
beside it; otherwise `$KIDO_STATE_DIR`, `$XDG_STATE_HOME/kido`, then
`~/.local/state/kido`. The launcher does not export `KIDO_STATE_DIR`.
It creates its state directory with mode 0700 and refuses a directory
not owned by the user or accessible to group or others, a directory path
containing a comma, and a socket path that cannot fit the platform's
`sun_path` including its terminator.
For debugging the default server, use
`kido-tmux -u -S ~/.local/state/kido/socket`.
`Tmux.Exec.argv` puts `-u` on every kido tmux client, including the
control client and launcher; `share/bin/tmux` does the same for shell use.

**Tool name == `kido tool` subcommand name.** Every subagent tool in `share/pi/` invokes
the `kido tool` subcommand of its own name (table in docs/design-subagents.md). A new
tool brings a subcommand spelled the same way; there are no aliases, and
a divergence is a silent runtime failure, not a build one;
`lib/test/test_tool_parity.ml` runs each tool in `share/pi/testdata/tools.json` as
a `kido tool` subcommand. A subcommand
no tool calls is named however it reads best (`async-run`); `async_bash`
took the underscore before its tool existed, because renaming a command
once something calls it is the harder half.

## The tmux fork

kido only runs under [andreypopp/tmux](https://github.com/andreypopp/tmux),
vendored as the submodule `third_party/tmux` (`tmux -V` prints
`next-3.9`). `fork` is the branch kido pins. It carries kido's commits
linearly on top of
[PR tmux/tmux#5468](https://github.com/tmux/tmux/pull/5468) (side status),
whose commits are rebased onto current upstream tmux master. When master
moves, the PR's commits and kido's are rebased onto it. If the PR lands,
kido's commits sit directly on master. Maintenance is by rebase only,
never merges or cherry-picks from upstream.

Kido's commit order on top of the PR is:

- Side status first: `side-status-command`, its conventions, the drag
  fixes, the pane-border edge.
- Then OSC 133 command-line capture; the control-client fixes (pause
  flush, `%exit` reason, control-state guard, hanging up a pane's child);
  terminal query-reply routing to the query's owner.

Before force-pushing `fork`, push its previous head as a dated branch
`fork-YYYY-MM-DD`, so older submodule pins stay reachable. `master` on
`andreypopp/tmux` only mirrors upstream; a PR into it is mistargeted.
Push over SSH (`git@github.com:andreypopp/tmux.git`).

A fork change bumps kido's submodule pin and the `fork revision:` line
in `share/rpc/contract.md`; lint enforces their agreement. Bump the
protocol version only when the wire format changes.

`scripts/install-tmux-fork.sh <prefix>` builds it
into `<prefix>/bin/kido-tmux`; `--self-contained <prefix>` is macOS-only,
linking Homebrew's static libevent, source-built utf8proc and system ncurses
so the binary needs no Homebrew at runtime (licenses in `share/kido-tmux`).
`--print-revision` reads the pin with
`git ls-files -s`, so it works with the submodule unchecked-out or the
pin only staged.

kido finds its tmux in this order: `$KIDO_TMUX`, then a `kido-tmux`
beside its own executable (unresolved invoked path first, as for the
shipped files), then `tmux` on PATH: `Tmux.Exec.resolve_binary`. The e2e harness gives the built kido
that sibling, so the suite runs the resolution users get.

**The side column.** `side-status-command` runs a program in the side
column with `$TMUX_SIDE_CLIENT` set. Its absence is exactly "not started
as a side column", i.e. `Ui.model.standalone` - a popup or plain pane
gets the one-shot picker. Keyboard focus is the client flag
`side-status-focus`.

**OSC 133.** What the sequences mean and how kido reads them is in
[docs/design-program-status.md](docs/design-program-status.md). The fork's
`input_osc_133()` in `input.c` keeps them as the `#{pane_last_prompt_time}`
and `#{pane_command_*}` formats and fires the hooks `pane-shell-prompt`
(`A`, `N`), `pane-command-started` (`C`) and `pane-command-finished` (`D`).
`C` stores its `cmdline=` parameter as `#{pane_command_line}`; tmux stores
the value through `clean_name()`: control bytes and backslashes
are escaped by `utf8_stravis()`, and `#(` becomes `_(`. The shell
integrations therefore send the command line **verbatim** apart from
blanking control characters and capping it at 1024 characters; the fork
caps it at 1024 bytes without splitting UTF-8. Anything the integrations
escaped would be escaped again and reach the sidebar unreadable.

Consequences:

- **These are hooks only.** No control-mode notification exists for
  them; kido reads the `#{pane_command_*}` formats on its poll. Do not go
  looking for `%pane-command-started`.
- **Timestamps are whole seconds.** `Tmux.Pane.shell` compares
  `last_prompt > command_start`, and a tie resolves to *running* —
  a false idle the instant a command starts is the worse error.
- **`cmd_status` is cleared on `C`,** so the last exit code is gone when
  the next command starts. `Sidebar.phase.held` (a `Tmux.Pane.exit option`)
  carries it across the following run.

`Tmux.Pane.shell` also heals a stuck flag: a `C` with no `D` leaves
`PANE_CMDRUNNING` set, and a later prompt's `A` makes `shell` report idle
without clearing the flag. Two fork changes would each delete a workaround: clearing `PANE_CMDRUNNING` on `A`
(the heal rule), and not clearing `cmd_status` on `C` (`Sidebar.phase.held`).
Not done.

**Why not `pane_current_command`.** It reports the process-group leader,
which confuses an interactive shell with a batch `zsh -c`.
`#{alternate_on}` reports whether the alternate screen is active, so it
sees `less` under `git` or `nvim` under `sudo`, and is what
the sidebar uses to decide a program has taken the terminal.

## tmux gotchas

- `set-environment` after `new-session` cannot reach the pane it
  started. Use `new-session -e VAR=value` or the command line.
- A window linked into two sessions has one pane id in several sessions.
  `Sidebar.step` finds the client's pane by active pane id **and**
  `Tmux.Exec.client_state.session_id`.
- `-S` takes a socket path as supplied; a bare name is relative to the
  working directory, not `/tmp/tmux-<uid>/`. `-L` creates its socket
  directory. An unset `TMUX_TMPDIR` selects `/tmp`; a nonexistent
  directory named by it is an error. Programmatic tmux, cleanup above
  all, uses `-S` with an absolute path.
- An empty `TMUX=` still forces tmux's UTF-8 detection. Unset `TMUX`
  entirely for locale tests (`test_e2e/locale_test.go`).
- `list-sessions` can succeed with an empty list while the server reads
  its config; only the launching client blocks. Readiness waits poll
  for a non-empty list. `test_e2e/launch_test.go` covers a slow
  `kido.conf`.
- `kill-server` returns before the processes it SIGHUP'd exit. Teardown
  collects the server's descendants first, then waits for each to exit;
  a survivor is an error (`test_e2e/harness_test.go`).
- `display-popup` opens a floating pane in the fork's upstream base.
  `popup-style` and `popup-border-style` are invalid options.
- The side column's edge is a pane border, following `pane-border-lines`
  and `pane-border-style`. `share/tmux/kido-tmux.conf` deliberately sets
  no `pane-border-style`, which would also restyle real split borders.
- `share/tmux/kido-tmux.conf` applies to every kido user; personal
  settings belong in `~/.config/kido/kido.conf`.
- Never assert on automatic `#{window_name}`: `automatic-rename` can
  read a transient process name. Rename the window to a fixed name,
  which turns `automatic-rename` off.

## Format-string invariants (`lib_tmux/pane.ml`)

`Pane.format` is `\x1f`-joined and parsed positionally by `Pane.parse`.

- `#{pane_title}` stays **last**; it may contain anything.
- `pane_command_duration` is deliberately **absent**: it ticks every
  second and would redraw the sidebar once a second forever.
- Adding a field means bumping `Pane.fields`, which both the split count
  and the short-line guard in `parse_line` read. lib_tmux/test/test_pane.ml's
  "field count pinned" test ties the two together; its "fixture
  generated from the format" test exists because the hand-typed fixture
  in its "parse:" test stays green when a new field is left out of it.
- `pane_command_status` prints **empty**, not `0`, when unset — hence
  `last_exit` is an `exit option`, `None` rather than a zero status
  (the "parse:" test's empty status).

## Native agent status

Only OSC 7501 root apps pi and claude-code identify agent panes. State supplies
local pi identity and coordination, never detection; ssh panes use the
pane-scoped `@kido_ssh` mark, believed only while the foreground is `ssh`.
`kido ssh` sets the mark before exec and leaves it in place. pi and Claude
Code status, completion and blocked messages come from their terminal records. No Claude Code executable shim is shipped.

Claude Code 2.1.295 queries OSC 7501, then emits a root app=claude-code
record: idle, working, done, or blocked with permission/question kind and
a base64 message. Escape on a permission dialog emits idle immediately;
exit clears all records. CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 disables
this reporting too. Its OSC 0 title was "Claude Code" at startup and
"Reply with ok" for the session. Pane titles are displayed verbatim, including
status glyphs and prefixes. Native-only agents fall back to the app name for
an empty title; local pi uses its State name when set.

## Agent state, and delivering a prompt

State lives in the server directory resolved above — one JSON file per agent session, named by session
id, written temp-file-then-rename. There is **no locking**; races are
resolved by policy:

- **One live holder per session id.** `State.record` creates a record
  with `Unix.link` from its own pid-named temp file (atomic, fails if
  taken); an existing record is overwritten only by the pid it names or
  once that pid is dead. `State.remove` follows the same rule. A refusal
  is `Error holder`, and `kido agent-status` exits **6** for it, which
  `share/pi/kido-status.ts` reads to stop reporting. Change that exit code in
  one half only and a second pi silently clobbers a live session.
- `State.load_live` **removes** a file whose recorded pid is dead.
- When two records claim one pane, the latest timestamp wins. A headless
  pi inherits TMUX_PANE, so it can take the pane's identity view; liveness
  readers must not use that collapsed view.
- **Never hand `Reap.sweep` a pane-keyed view.** The sidebar's view is
  `State.load_live` then `State.by_pane`; anything asking "is this
  session running *anywhere*" takes `load_live`'s list, which drops
  nothing. A pane-keyed view makes the flip
  above close a parent's children.
- **The orphan rule includes `async_bash`.** `Reap.sweep` reads the parent
  session from run metadata for plain and streamed bash runs. If it has no
  live record, the unfocused run is collected even while its command runs;
  a parentless bash run is exempt.

For a Pi_agent, `kido prompt` prefers the recorded inbox socket
(`kido-status.ts` binds one) and uses a tmux paste **only** when its record names no inbox
(`Prompt.deliver_or_paste`). An advertised but unavailable inbox is an
error, not permission to paste. Other socket errors also return without
a fallback: the message may already have been delivered, and re-sending
would double-send. A Some_agent is reached by paste; Terminal is excluded.
Live State remains authoritative for coordination and run history even when
the pane's current root app is replaced or cleared.

`Tmux.Exec.send_prompt` **pastes rather than types**: `send-keys -l` writes raw
bytes, and under bracketed paste a bare newline submits, splitting a
multi-line prompt. `load-buffer` + `paste-buffer -p` brackets when the
application asked for it and pastes raw otherwise. Enter is a
**separate** `send-keys` after a delay; sent with the paste it cuts the
paste mid-line.

Exit codes: `0` sent, `1` empty stdin or an error, `4` no agent in scope,
`5` several. Scope is the caller's window, widening to the session only
when the window had none (`--window` never widens) — so `5` can never
be resolved by widening.

## Installed-file lookup (`lib/bin_dir.ml`)

Shipped files live at `<prefix>/share/kido/...` beside `<prefix>/bin/kido`
(Homebrew's `pkgshare` layout; `make install` mirrors it).

`Bin_dir.of_exe` tries the **unresolved** path first and resolves only
as a fallback (`Tmux.Exec.candidates`), and starts from
`Tmux.Exec.invoked_path` on `argv[0]`, with `Sys.executable_name` only
as its last resort:

- Homebrew's `bin/kido` and `share/kido` are symlinks repointed on every
  upgrade. The resolved path names a Cellar version directory the next
  `brew cleanup` deletes, leaving `side-status-command` and every pane's
  PATH pointing at nothing.
- On Linux `Sys.executable_name` reads `/proc/self/exe` and always
  resolves, defeating the ordering.

## Building

`make install PREFIX=<prefix>` installs `bin/kido`, `bin/kido-tmux` and
`share/kido`, including the shim that routes bare `kido` to that prefix.
It reuses the e2e revision-keyed fork cache under `build/tmux-fork/`.
`SELF_CONTAINED=1` passes `--self-contained` to the fork installer and
uses a separate `<revision>-self-contained` cache entry.

kido is built by dune **3.24.2**, the binary distribution, with package
management on (`dune-workspace`); the README's install line fetches it.
Dependencies are declared in `dune-project`, Mosaic as `(pin ...)`
stanzas on a git commit, and resolved into the committed `dune.lock`;
`dune pkg lock` regenerates the lock and always resolves against the
newest opam-repository, so a re-lock is a reviewed change. There is no
`kido.opam`: `dune-project` is the one dependency list. The first build
of a checkout compiles OCaml and every package in `dune.lock` (a few
minutes); dune's shared cache (see `dune-workspace`) restores them in
seconds after a clean `_build`, and `dune cache trim --size 5GB` bounds
it. ocamlformat is a dev tool, not a dependency:
`dune tools install ocamlformat`, then `dune fmt`. Dev tools are per
checkout under `_build`: `dune clean` deletes them, and they are not on
PATH by default. Use `dune tools which`, `dune tools exec` or
`eval "$(dune tools env)"`. `dune show
depexts` prints nothing; there are none.

Dune 3.24.2 with package management dies on an absolute
`DUNE_BUILD_DIR`; `scripts/ci-like/Dockerfile` therefore sets a relative
one.

## Tests

    make verify  scrubbed dune build, dune test --force, full e2e and TypeScript tests
    make test    dune test --force and scripts/test-ts.sh (including scripts/lint.sh)
    make prompts regenerate the prompt fixtures through scripts/lint.sh --update-prompts
    make e2e     builds the pinned fork and runs the e2e suite
    make flake RUN=TestFoo COUNT=20  repeat one e2e test in the scrubbed environment
    make clean-forks  remove fork builds other than the pin
    make install binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/kido
    make website the website's dev server at http://localhost:4321 (website/README.md)

`make verify E2E=TestFoo` limits e2e; `STAGES=e2e` selects only that stage.
Every selected stage runs even after a failure and prints PASS/FAIL.
Validation before a release is `make verify`, in full; CI
runs both on Ubuntu and macOS on every push and PR (`scripts/main-watch.sh`
watches main and reports each observed head's CI), building the fork at the
pinned revision, cached by SHA. `/gh-watch` starts it via streamed `async_bash`.
While working, `dune test` is the loop; `dune promote` accepts an expect
diff once it has been read.

**Prefer e2e tests.** A behaviour a user or an agent can observe (a
subcommand's output, exit code, side effects on tmux or state) is
tested in `test_e2e/`, through the binary. Unit tests in `lib/test/` and `lib_tmux/test/` are for pure
library logic that e2e cannot reach or cannot pin precisely (parsers,
formats, ordering); do not write a unit test that execs the binary.
The one exception is `lib/test/test_tool_parity.ml`, which runs each tool
as a `kido tool` subcommand.

`make e2e` builds the fork into `build/tmux-fork/<revision>/` (rebuilt
only on a submodule bump) and runs with `KIDO_E2E_REQUIRED=1`. A
`KIDO_TMUX` in the environment names another fork and skips the build
(how CI uses its cached one). A bare `go test ./test_e2e/` with neither
skips. The harness requires the fork's `share/kido-tmux/REVISION` to
match the gitlink pin; rebuild with `scripts/install-tmux-fork.sh` if it
is missing or differs. The TypeScript suite requires Node 24 or newer and
skips without it; `KIDO_TS_TEST_REQUIRED=1` (set in CI) makes that a failure.

**Reproducing a CI-only failure:** `scripts/ci-like.sh` runs a Linux
container with the repo bind-mounted, CPU/memory capped, and the fork
built at the pinned revision (`make ci-like ARGS="--cpus 0.25 -- go test
./test_e2e/ -run TestFoo"`). A CPU quota alone rarely reproduces timing
failures; `--contend N` starts N busy sibling containers, and with a low
`--cpu-shares` desyncs a wrapper's timer from its command the way a
loaded runner does. With `--contend N` greater than zero, `--budget`
(default 2) minus the run's `--cpus` is split equally among the siblings
as their CPU quotas; a nonpositive sibling quota is rejected. It does
not cap a plain `--cpus`. Contention is for one named failure, not a
whole suite. Never saturate the host's own cores to chase a runner
failure: other agents are working in parallel.

**The e2e harness** (`test_e2e/harness_test.go`) nests two tmux servers — an
outer one hosting a pty, the inner one under test with kido as its
`side-status-command` — and reads the sidebar with `capture-pane`. It
builds kido with `dune build @install` (so it needs that dune on PATH), and fake
`node` binaries that emit terminal titles and native program status.

- The inner server's PATH starts with the built kido and the fork
  (`serverPathPrefix`), because `kido-tmux.conf` bindings name bare
  `kido`/`tmux` resolved by `run-shell` against the server's PATH. An
  installed kido masks a missing entry locally; CI gets exit 127.
- `cleanEnv` strips installed `share/kido/bin` PATH entries, `TMUX`,
  `TMUX_PANE`, `KIDO_STATE_DIR`, `KIDO_AGENT_*` and `KIDO_TMUX`: the suite is often
  run from a tracked agent's pane, and the inner server's environment is
  what `new-window` gives a spawned child, so the developer's own parent
  edge would leak into tests.
- `settle = 5s` is the default wait deadline; wait helpers poll at 100ms, kido's
  tick. Every grace period (linger, stop escalation, stall threshold) is
  shortened only through the inner server's environment, never
  in-process, so the sidebar and the extension's helper agree ("Knobs" in
  docs/design.md).
- Never put a fake on a shared PATH: it shadows that name for every
  startup file too. Tests needing a fake `pi` get their own PATH through
  `startPathPrefix`.
- After sending Escape to the sidebar, wait for its effect before the
  next key: on a loaded runner Mosaic joins a buffered ESC with the next
  byte into an Alt-key.
- macOS limits unix socket paths to 104 bytes including the terminator;
  `t.TempDir`'s suffix can exceed it. Use the harness's short socket
  directories (`serverDir` / `launcherEnv`). A pid-0 liveness check tests
  a process group, not the child; wait for a real published pid.
- Tests executing `zsh -i` detach from the terminal (no TTY, `setsid`),
  or the run hangs. Prefer timing ratios against a baseline measured in
  the same run to fixed wall-clock bounds.
- Ubuntu CI does not install zsh: compinit's insecure-directories prompt
  blocks e2e shells. Unit probes of host shells silently skip a missing
  shell and print only mismatches.
- `dune test --force` can reuse a cached `.exe.output` target
  (`lib_tmux/test/tmux_server` does not declare `KIDO_TMUX` as a rule
  dependency). A flake loop over it needs the cache off.
- On macOS CI, `split-window` reporting "fork failed: Device not
  configured" is a runner pty flake. Rerun only the failed job
  (`gh run rerun --failed`), rather than capping parallelism.

Many tests carry a comment saying what they pin or which assertion
carries them; read it before weakening or "cleaning up" such a test.
Negative controls are load-bearing: never delete one half of a pair.

### Other traps

- **`kido ssh` keeps `Bin_dir.look_path_past`.** Kido's bin directory
  precedes PATH in a primed pane; removing the lookup breaks
  `TestKidoSSHOpensAnOrdinarySession` and
  `TestKidoSSHPrimesARemoteShell` in `test_e2e/ssh_prime_test.go`.
- **`Sidebar.same` compares panes by exclusion.** A new `Tmux.Pane.t` field
  participates in equality unless blanked in its local `drawn`. It fails
  toward extra redraws, the safe direction.
- **A window's panes are ordered oldest first**, by pane id number
  (`Tmux.Pane.order_sessions`), not in list-panes layout order (`split-window
  -b` puts a new pane first). The tree, the group glyph's row 0,
  `kido switch-session` and `kido switch-window` rely on that one sort.
- **`@kido_run` is pane-scoped (`set-option -p`).** It marks the one
  pane a run actually runs in; a user's split off that window reads "",
  with no window-scoped fallback to inherit.
- **`Ui.parts` is the column-alignment contract.** Every pane row's
  indicator is drawn there as a one-column field. An unintegrated shell and
  a program that has taken the terminal (no indicator) and an idle one (no
  glyph) get an empty field — column kept. Anything
  drawn left of a label must fit in space already accounted for; tree
  prefixes are built by `Ui.lines`, before the indicator column.
- **A standalone kido infers its client by counting, filtered.**
  `#{client_name}` from a popup is unanswerable. `Tmux.Exec.resolve_client`
  asks who is attached to the pane's session, ignoring kido's own
  control-mode connections (one per real client). Control mode is read
  from its boolean, not an empty tty (a read-only client has one too).
- **`Tmux.Conn.run` kills the control client on any timeout** and subsequent
  calls re-dial after the retry backoff; one slow command costs a full reconnect.
- **`share/zsh/integration.zsh` must not name a local `status`** — a zsh
  special parameter; shadowing it silently stops the precmd hook. It is
  called `ret`.
- **A tmux command reaching a further parser has no surviving escape.**
  The generated `server.conf` (tmux -> sh) and a `new-window` window name
  (tmux -> sh -> tmux) go through `Launch.tmux_safe`,
  which refuses `'`, `"`, `$`, `#`, `\`, a backtick, a newline or a
  carriage return. A space is quoted.
## Working here as a spawned agent

These apply to every agent kido spawns into this repo; a brief does not
repeat them.

- **Do the task yourself.** Do not spawn subagents or call `ask_agent`;
  nobody is waiting to be asked.
- **No git writes.** No commit, push, reset, add, checkout or stash. The
  top-level session commits. Leave work uncommitted. Never `git stash`.
  `.pi/extensions/no-git-writes` guards bash tool calls when
  `KIDO_AGENT_PARENT_SESSION` is set.
- **Other agents' uncommitted changes are expected.** Work runs in
  parallel; the brief says which files are yours. Do not revert, clean
  or fix anything outside them - report it instead.
- **You are inside the user's live tmux server.** `kill-server` without
  `-S` and your own absolute socket path risks killing it. Start every
  test server on its own explicit socket (`tmux -S "$scratch/socket"`),
  end it with `kill-session`, and never touch `~/bin/tmux`,
  `/opt/homebrew/bin/tmux` or the running server.
- **Scratch worktrees.** Use `mktemp -d /tmp/<name>-XXXXXX`.
  A bare `mktemp -d` on macOS resolves under `/var/folders`, where
  `.pi/extensions/no-git-writes/policy.ts` refuses
  `git worktree add --detach`; it permits detached worktrees only under
  `/tmp`. The submodule makes `git worktree remove` refuse here: remove
  the scratch directory with `rm -rf`, then `git worktree prune`.
- **Every wait has a deadline.** No open-ended polling in code or in
  your own shell. macOS has no `timeout` command; give the wait its
  deadline another way.
- **Verify what you touched; CI runs the whole.** For a bug whose cause
  is not plain from the code (a race, a flake, a wrong guess about tmux,
  pi or Claude Code), write the test first, watch it fail, and quote that
  failure. A simple fix, and a feature, need tests that only pass. Test in proportion to the change: a trivial
  one (a character of spacing, a word of text) updates the expected
  strings it breaks and adds no new tests. Negative controls (breaking the code to prove
  a test can fail) only where a test could plausibly pass vacuously -
  timing, races, deduplication, polling; never for a trivial change
  such as text, spacing or a renamed field. Then run `make verify` once
  after the last edit (`E2E=TestFoo` to limit e2e to the touched behaviour).
  It owns environment scrubbing and pinned-fork selection. This replaces
  the separate build/test recipes: do not also run `make test` or `make e2e`.
  No loops or second tmux build unless the brief requests `make flake`.
  Report PASS/FAIL/SKIP as
  printed; a failure in a file you do not own is reported, not fixed.
- **Docs are not per task.** Do not edit `docs/` or this file unless the
  brief assigns them. Put any prose a change deserves in your report.
- **Report through `notify_parent`, under 4000 characters**, leading
  with what was built and the pre-fix failures.

## Releasing

kido carries **no release version and no tags, deliberately**. Versioning
lives in `andreypopp/homebrew-tap`'s `kido` formula: a git `revision:`
with a hand-bumped `version`. The formula pins only the kido git revision;
`make install` builds the fork from the `third_party/tmux` submodule that
revision pins, via `scripts/install-tmux-fork.sh`.

After landing on `main`, run `scripts/release.sh VERSION` (or
`make release VERSION=x.y.z`); use `--dry-run` to inspect its actions.
It requires green CI for origin/main, compares tool and subcommand lists
with the tap's current revision, and requires a minor bump for removals
or renames: panes must be restarted, not /reloaded. It edits and commits
the brew tap formula, fast-forwards `~/Workspace/homebrew-tap`, and pushes
from that SSH checkout. It never runs `brew upgrade`.

`make preview-pi` atomically replaces the installed pi extensions,
backing up originals once; `make unpreview-pi` restores them. Run `/reload`
in the panes afterward. `KIDO_PREVIEW_PREFIX` selects a fake install for tests.

Only `kido-app/N.N.N` tags mark Kido.app releases, built from `kido-app`
by `app/scripts/release.sh` and published as `Casks/kido-app.rb` in
`andreypopp/homebrew-tap`; kido itself is never tagged.
`brew audit`/`brew style` vendor gems into the
Homebrew checkout itself, which can leave it dirty. Verify against a real
tmux server before releasing — the ppx_expect tests do not need tmux, and e2e skips
silently without the fork.

## Commit style

One imperative sentence, usually with no prefix and no trailing period.
The body says *why*, in prose, hard-wrapped — and where a change is
subtle, why the test was written the way it was. Recent history is the
reference:

    Send a prompt as a paste, so its newlines survive
    Quitting an editor no longer flashes the row green
    A program that has taken the terminal is not a running job
    One status vocabulary for agents and shells

## Known-open

- A marked `ssh` pane whose far side reaches its first prompt in the same
  whole second ssh started stays running until a later remote prompt.
  `Sidebar.observe_remote` requires `last_prompt > command_start`: accepting
  the tie would mistake the local prompt for a remote one.

The subagent system's design limits (a child moved to another session, a
blocked ask holding a whole turn, a child that exits before its window is
kept, a child that crashes before `notify_parent`) are under "Known
limits" in docs/design.md and "Limits" in docs/design-subagents.md.
