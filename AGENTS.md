# Developing kido

[README.md](README.md) describes kido and its installation. This file
supplies context that the code does not contain:

- The tmux fork that kido needs.
- What terminal programs report.
- The invariants that a change can break, even if the change looks correct.

[docs/design.md](docs/design.md) contains kido's design decisions:

- The authoritative store for each fact.
- The inbox protocol and addressing.
- The ask/reply cycle rule.
- Spawning and the window lifecycle.
- Run outcomes.
- The boundary between kido and its pi extension.

[docs/design-subagents.md](docs/design-subagents.md) describes subagents.
[docs/design-rpc.md](docs/design-rpc.md) describes the external-client RPC.
[docs/design-program-status.md](docs/design-program-status.md) describes
pane classification and status reads. Before you change these mechanisms,
read these files. The code comments and this file do not repeat them.

Work in progress has a plan in `plans/`, with one markdown file per
plan. A plan describes work that is not complete. When the work is
complete, its agreed design moves into `docs/`. The plan is then
deleted.

## Code rules

These rules apply to OCaml and TypeScript.

**No backward compatibility, ever.** The binary, extensions, shims and
tmux config ship together from one checkout. When they must agree, the
tmux server restarts. Do not write fallbacks for state from an older
kido: old tmux marks, record fields, flags or environment variables.
Do not add version gates, deprecated aliases or migration paths.
Change both sides.

Delete the old one.

State from an older kido is not a bug if a restart or user action
clears it.

**Plain functions over data.** Use abstraction only when it has a benefit.
Do not use a functor, object or first-class module without a second
instance. Express the design through data structures. Make illegal
states unrepresentable.

- Use a variant for a set of cases (a discriminated union in TS).
  Do not use a record of options or a combination of bools.
- Give a value with its own rules its own type, abstract in the `.mli`.
  Parse it once at the edge. Do not check a string in several places.
- Use one record for parallel fields or maps that describe one thing.

**Minimal line count.** Do not abstract something with one use. Inline a
function, type, interface, constant, option struct or test helper with
one caller. Do not add wrappers that only forward. Do not add interfaces
or swappable variables without a second implementation. Remove dead
code and unused parameters.

Put duplicated logic in one place.

**Module boundaries.** Each subcomponent has its own module: an OCaml
module with its `.mli`, or a TS module. Use its exported surface.
`bin/main.ml` connects subcommands to `lib/` modules. It contains
commands too small for library code. Domain logic belongs in the module
that owns the domain.

**Library code returns, the CLI reports.** A `lib/` function returns
its result: a value, an `option` or a `result`. It does not print, call
`failwith` or call `exit`. A command body belongs in `bin/main.ml` if it
only calls the library, prints and returns an exit code.

If a `lib/` module exports only such a body, used only by
`bin/main.ml`, inline it there.

**No display logic in `lib/`.** Human-facing formatting belongs in
`bin/`. This includes tables, alignment, padding, truncation, glyphs,
styles, local time, usage text, and labels and captions composed from
facts. The RPC snapshot contains only semantic data: plain titles and
typed status, as uncut text.

**State.** Use one source of truth for each fact. Never hold the same
fact in two stores:

- A run record and a tmux option.
- An OCaml record and a TS copy.
- A file and an in-memory mirror.

Do not store a fact that you can derive. Compute it when necessary.
Read and write each piece of state through its owner module only.

**No comments unless absolutely necessary.** Code should explain itself.
Do not add narration or doc comments that repeat the name. Do not add
history ("previously", "no longer", "since this fix"). Design rationale
belongs in `docs/`, not comments. Keep only these comments:

- A verified external constraint that the code cannot express:
  a tmux, pi, Claude Code or OS quirk.
- The reason for a workaround, while that workaround exists.
- A link to the issue for either case.

Build, compiler and formatter directives are not comments. If a
diagnostic suppression hides a correctness failure, fix the cause.
A stale comment is worse than no comment because readers trust it.
When a mechanism changes, use grep to find prose that describes it.

## Communication

Always use ASD-STE100:

- When you communicate with the user.
- When you produce commit messages or commit descriptions.
- When you produce PR titles or PR descriptions.
- When you add code comments (see **no comments unless absolutely necessary** above).

## OCaml

These requirements are fixed:

- **Layout.** `bin/main.ml` contains the cmdliner command table and
  small command bodies (`ssh`, `runs`, `run-outcome`, ...).
  It also contains failure printing and the CLI's tables and text.
  `lib/` is the library `kido`. Each domain or subcommand with its
  own logic has one module. `lib_tmux/` is the library `tmux`.
  Call sites use `Tmux` and `Tmux.Client`.

  Unit tests use ppx_expect. Put them at the bottom of the module
  under test, in a `let%test_module "Tests"` submodule. This includes
  the `kido_sidebar` library in `bin/`. Thus, `.mli` exports only
  what production callers use. The out-of-line exception is
  `lib/test/tmux_server/`.
- **Every stanza compiles with `-open Containers`.** Every `.ml`
  has an `.mli` unless it contains only types or constants. The test-helper modules
  `Sh`, `Test_support`, `Test_fixture`, `View_fixture` and
  `State_fixture` have no `.mli`.
  Only `tmux.mli` exposes `lib_tmux/program_status.ml`.

  JSON uses yojson with ppx_yojson_conv. Equality and comparison use
  ppx_compare. String conversion uses ppx_string_conv.
  `lib/` and `lib_tmux/` also open their runtime primitives:
  `Ppx_compare_lib.Builtin` and
  `Ppx_yojson_conv_lib.Yojson_conv.Primitives`.
  The TUI uses Mosaic, pinned in `dune-project`.
  Concurrency uses `unix` and `threads.posix`, not Eio or Lwt.
- **The command line is a contract** with `share/` and `test_e2e/`.
  This includes subcommands, flags, exit codes, every parsed or asserted
  stdout/stderr line, JSON shapes and environment variables.
  A long option is `--name`, never `-name`.

Conventions:

- **Errors.** A `lib/` failure is a `result`. Use a string error
  that contains the message to print. If the caller or message differs
  by case, use a variant (`Run_stop.stop` returns `Error (No_run _)`).
  The I/O exceptions `Unix_error` and `Sys_error` propagate.
  Do not catch them to rethrow them.
- **Subcommands.** A subcommand body in `bin/main.ml` returns its
  exit code. It runs under its `run name`. This prints a raised
  failure as `kido <name>: <message>` and returns 1.
  A string error reaches it through `Result.get_or_failwith`.
  After `error`, the body returns a special code.
  cmdliner's own parse errors exit 1.

  Library errors do not repeat the command name or append usage text.
  `run` supplies the name. The command body appends its `usage:`
  line. Warnings during a command use a `~warn` callback to keep
  stderr in order.
- **Environment.** Read the environment at the edge. Pass its values
  to functions through `~dir`, `~threshold` and `~now`.
  Tests pass a temporary directory. No test sets an environment
  variable or swaps a global.
- **Time** uses `Timestamp.t`: unix seconds as a float, and RFC 3339
  UTC on disk. Timeouts are optional arguments, not mutable refs.
- **Containers** shadows polymorphic `=` and `compare`.
  Use `String.equal`, `Float.(>)`, etc.
- **Options.** Do not use `Option.map_or`. Use a `match` on the option.
  Use the `Option.Infix` let-ops (`let*`, `let+`) only for two or more
  binds in a chain, with a local `let open Option.Infix in`.
  For one step, use `Option.map` or `Option.flat_map`.
- **Derivers.** Equality, comparison, string conversion and JSON codecs
  use ppx_compare, ppx_string_conv and ppx_yojson_conv, not ad hoc functions.
  The `.ml` derives each one whose derived form is correct.
  Write the others manually under the derived name. Examples are numeric
  `Tmux.compare_pane_id` and validating `Tmux.pane_id_of_string`.
  For derived and manually written functions, use `[@@deriving ...]`
  in the `.mli`, not explicit `val` declarations.

  A validating `_of_string` raises `Invalid_argument` that names
  the bad value. A caller maps it over an absent value (an unset or empty
  environment variable) rather than parsing one. It calls it directly
  on a string that must be valid. It catches it only at an
  untrusted-input edge: an RPC request or a `_of_yojson`.
  `run` reports it like `Failure`.
- **JSON decoding** raises `Of_yojson_error`. Manually written
  `_of_yojson` functions raise it through `of_yojson_error`.
  `Fs.read_json` is the only edge that turns a file into an `option`.
  Variants encode as `["Tag"]`, so string enums need manually written
  codecs. A field omitted at its default needs
  `[@default v] [@yojson_drop_default.equal]`.
  An option needs `[@default None] [@yojson_drop_if Option.is_none]`
  because `[@yojson.option]` rejects an explicit `null`.

  A bare option field encodes `None` as `null`.
- **Cmdliner docs.** A bare `$` is markup.
  It produces "unescaped $" on `--help`.
  Write environment variables as `$(b,NAME)`.
- **Tmux I/O.** Do not inject tmux/ops records whose only other
  implementation is a test fake. Call `Tmux` directly.
  Test through e2e. `Tmux.t` is immutable.
  `Tmux.create` makes a one-shot handle.
  `Tmux.Client.tmux` makes a handle fixed to that control client.

  The two deliberate read fallbacks use the same socket without
  changing the handle:
  - `Tmux.list_clients` on an empty reply or control error.
  - `Tmux.list_panes` on a control error.

  Other control commands never silently retry as a one-shot.
  `Tmux.Client.t` has no mutex. Only the sidebar's single tick may
  access it. `Tmux.binary` is the accepted exception for lazy
  environment lookup.
- **Mosaic (`bin/kido_sidebar.ml`).** The grid's default foreground
  is truecolor white. Thus, every style sets `fg` explicitly.
  A lone Escape arrives about 0.5s late.
- Use `dune build`, `dune test` and `dune fmt`, without opam.
  dune's package management builds the compiler and every dependency
  of `dune.lock` into `_build` (README.md, "Building" below).

## Layout

    bin/main.ml        the cmdliner command table and the small commands:
                       ssh, switch-session/window, server, run,
                       run-child, runs, run-outcome, run-wait,
                       run-stop, reap, rpc; failure printing,
                       and every human-readable rendering of library
                       results
    bin/kido_sidebar.ml  the library kido_sidebar: Mosaic rendering, keys, cursor
                       and inline tests; consumes Kido.Sidebar's model
    lib/               the library kido: domain logic and data, no presentation
      launch.ml        the launcher and `kido server`: --server, the
                       server.conf in its state dir, the KIDO_SERVER stamp
      build_id.ml      the immutable dune-build-info version, or unknown
      shell.ml, prime.ml  kido shell: the login shell and its priming files
      bin_dir.ml       the shipped-file and bin-directory lookup
      tmux_vars.ml     names of kido's tmux user options and environment variables
      state.ml         the pane view and its one read: every pane, its
                       harness options and the runs their marks name; a run's
                       ending from its pane; ordering, navigation and a
                       window's run pane
      sidebar.ml       the sidebar's model: the tick, tracking and the shell-status
                       debounce, rows as data, the feed's v2 JSON
      server_dir.ml    the server state directory and socket
      pane_kind.ml     pane classification and titles
      ssh.ml           kido ssh: argument parsing, priming and the pane's ssh marks
      msg.ml           the inbox client: one payload over the unix socket
      tree.ml          the parent-first walk behind the sidebar
      reap.ml          which run panes are finished with, and when
      run.ml           run records in runs/<id>/ and the first-write-wins
                       outcome write
      pane_status.ml   a pane's status from its shell marks and OSC 7501 records
      protocol.ml      the RPC protocol: version, requests and the snapshot
      run_window.ml    the tracked run window that both launchers create,
                       and its name checks
      prompt.ml, run_wait.ml (run-wait), run_stop.ml (run-stop),
      run_history.ml (the runs history reader)
                       one subcommand or family each
      fs.ml, timestamp.ml  files, paths, executable lookup, time;
                       Fs is the shared kido_fs library used by kido and tmux
      test_fixture.ml, test_support.ml, view_fixture.ml, state_fixture.ml, sh.ml
                       shared inline-test scaffolding
      test/tmux_server/  the Client and pane-read tests against a real tmux, run only with $KIDO_TMUX
    lib_tmux/          the library tmux: tmux.ml and tmux.mli (server handles,
                       flat ids, operations, binary lookup and Client),
                       program_status.ml (OSC 7501 parsing, re-exported through
                       tmux.mli; no separate .mli)
    share/             the source of share/kido, installed by share/dune:
      bin/             the bin directory's sh shims (kido, tmux, ssh, kido-pi)
      shim.sh          their shared helper
      bash/, zsh/      the OSC 133 integrations every primed shell sources
      tmux/            kido-tmux.conf and kido-tmux-unstamped.conf, the
                       defaults the launcher writes into
                       server.conf (embedded, not installed)
      pi/              kido-pi.ts, the harness, which the kido-pi shim loads
                       with --extension
      pi/testdata/fake_kido/, pi/testdata/fake_tmux/, pi/testdata/fake_common/
                       the TypeScript suite's fake kido and fake tmux, and
                       their shared helpers, built by scripts/test-ts.sh
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

Before you change `lib_tmux/`, read `lib_tmux/AGENTS.md`. pi does not
load it for an agent that starts at the repo root.

`prompt`, `switch-session`, `reap` and `runs` remain,
even without production callers. e2e calls `reap` for a deterministic
sweep. `runs` is the CLI reader of run history.

`dune build` builds the executable stanza `bin/main.exe`, installed as
`kido`. `lib/` embeds the shell integrations,
`share/tmux/kido-tmux.conf`, `share/tmux/kido-tmux-unstamped.conf`
and the fork pin.
Promotion substitutes the build id through dune-build-info.
`make install` and e2e copy the stamped executable `build/main.exe`.
`_build/default/bin/main.exe` reports `unknown`.
`kido --version` prints that id.

`kido server` reports these JSON fields:

- `protocol`: the binary's `Protocol.value`, always a string.
- `server`: the creating server's global `KIDO_SERVER`, always present.
  If unset, it is null. Otherwise, it is the stamp string, even when
  it matches.
- `expected`: the binary's `Launch.stamp`.

The stamp digests these inputs:

- The pinned fork revision, read at build time through
  `install-tmux-fork.sh --print-revision`.
- The `server.conf` template, without
  `share/tmux/kido-tmux-unstamped.conf`.
- The launcher's environment changes.

Thus, a fork or `kido-tmux.conf` change restarts the server.
An RPC protocol bump does not.
A change to `kido-tmux-unstamped.conf` does not. Only new servers get it.
docs/design.md, "The launcher", tells which file gets a setting.
The launcher, `kido server`, `rpc` and `switch-session/window`
accept `--server DIR`. `switch-window` prints nothing.
A server is its state directory. Its socket is `<dir>/socket`.

`Server_dir.dir` resolves the default. Inside a pane, `$TMUX` has priority
if its socket is named `socket` and `server.conf` exists beside it.
Otherwise, the order is:

1. `$KIDO_STATE_DIR`.
2. `$XDG_STATE_HOME/kido`.
3. `~/.local/state/kido`.

The launcher does not export `KIDO_STATE_DIR`.
It creates its state directory with mode 0700.
It refuses these paths:

- A directory not owned by the user.
- A directory accessible to the group or others.
- A directory path that contains a comma.
- A socket path over 103 bytes, the macOS `sun_path` limit without its
  terminator, on every platform.

To debug the default server, use
`kido-tmux -u -S ~/.local/state/kido/socket`.
`Tmux.argv` adds `-u` to every kido tmux client, including the
control client and launcher.
`share/bin/tmux` does the same for shell use.

**The harness is one pi extension.** `share/pi/kido-pi.ts` holds every
agent tool. It calls only kido's run commands (`run-child`, `runs
--json`, `run-wait --json`, `run-stop`, `run-outcome`) and tmux. These
commands, their flags, exit codes and JSON are the contract between the
two (docs/design.md, "The pi extension, kido-pi"). The extension never
finds or parses kido's state directory; it reads only the output path
that a run command prints. kido never reads the extension's files.

## The tmux fork

kido runs only under [andreypopp/tmux](https://github.com/andreypopp/tmux),
vendored as the submodule `third_party/tmux`.
`tmux -V` prints `next-3.9`. kido pins the `fork` branch.
This branch contains kido's commits in a linear sequence after
[PR tmux/tmux#5468](https://github.com/tmux/tmux/pull/5468) (side status).
The PR's commits are rebased onto current upstream tmux master.

When master changes, the PR's commits and kido's commits are rebased
onto it. If the PR is merged, kido's commits follow master directly.
Use only rebase for maintenance, never merges or cherry-picks from upstream.

Kido's commit order after the PR is:

- Side status first: `side-status-command`, its conventions, the drag
  fixes, the pane-border edge.
- Then OSC 133 command-line capture; the control-client fixes (pause
  flush, `%exit` reason, control-state guard, hanging up a pane's child);
  terminal query-reply routing to the query's owner.

Before you force-push `fork`, push its previous head as a dated branch
`fork-YYYY-MM-DD`. This keeps older submodule pins reachable.
`master` on `andreypopp/tmux` only mirrors upstream.
A PR into it has the wrong target.
Push over SSH (`git@github.com:andreypopp/tmux.git`).

A fork change updates kido's submodule pin and the `fork revision:`
line in `share/rpc/contract.md`. lint checks their agreement.
Only when the wire format changes, bump the protocol version.
The server stamp follows the pin automatically.

`scripts/install-tmux-fork.sh <prefix>` builds the fork into
`<prefix>/bin/kido-tmux`.
`--self-contained <prefix>` is macOS-only.
It links Homebrew's static libevent, source-built utf8proc and system
ncurses. Thus, the binary needs no Homebrew at runtime
(licenses in `share/kido-tmux`).
`--print-revision` reads the pin with `git ls-files -s`.
It works if the submodule is not checked out or the pin is only staged.

`Tmux.binary` finds kido's tmux in this order:

1. `$KIDO_TMUX`.
2. A `kido-tmux` beside kido's executable. It uses the unresolved
   invoked path first, as for the shipped files.
3. `tmux` on PATH.

The e2e harness supplies that sibling to the built kido.
Thus, the suite uses the same resolution as users.

**The side column.** `side-status-command` runs a program in the side
column with `$TMUX_SIDE_CLIENT` set.
Its absence means exactly "not started as a side column":
`Kido_sidebar.model.standalone`.
A popup or plain pane gets the one-shot picker.
The client flag `side-status-focus` specifies keyboard focus.

**OSC 133.**
[docs/design-program-status.md](docs/design-program-status.md) describes
the sequences and how kido reads them.
The fork's `input_osc_133()` in `input.c` stores them as the
`#{pane_last_prompt_time}` and `#{pane_command_*}` formats.
It fires these hooks:

- `pane-shell-prompt` (`A`, `N`).
- `pane-command-started` (`C`).
- `pane-command-finished` (`D`).

`C` stores its `cmdline=` parameter as `#{pane_command_line}`.
tmux stores the value through `clean_name()`.
`utf8_stravis()` escapes control bytes and backslashes.
`#(` becomes `_(`.

Thus, the shell integrations send the command line **verbatim**, except
that they blank control characters and limit it to 1024 characters.
The fork limits it to 1024 bytes without splitting UTF-8.
If the integrations escaped anything, tmux would escape it again.
The sidebar would receive unreadable text.

Consequences:

- **These are hooks only.** No control-mode notification exists for them.
  kido reads the `#{pane_command_*}` formats when it polls.
  Do not search for `%pane-command-started`.
- **Timestamps are whole seconds.** `State.shell` compares
  `last_prompt > command_start`. A tie resolves to *running*.
  A false idle when a command starts is the worse error.
- **`cmd_status` is cleared on `C`,** so the last exit code is absent
  when the next command starts. `Pane_status` captures the exit whole
  from one read. It keeps this as the Idle phase's `last` until the
  next command is promoted to running.

`State.shell` also corrects a stuck flag.
A `C` with no `D` leaves `PANE_CMDRUNNING` set.
A later prompt's `A` makes `shell` report idle without clearing the flag.
Each of these two fork changes would remove a workaround:

- Clear `PANE_CMDRUNNING` on `A` (the heal rule).
- Do not clear `cmd_status` on `C` (the captured `last`).

Neither change is complete.

**Why not `pane_current_command`.** It reports the process-group leader.
This confuses an interactive shell with a batch `zsh -c`.
`#{alternate_on}` reports whether the alternate screen is active.
Thus, it detects `less` under `git` or `nvim` under `sudo`.
The sidebar uses it to decide whether a program has taken the terminal.

## tmux gotchas

- After `new-session`, `set-environment` cannot reach the pane that
  `new-session` started. Use `new-session -e VAR=value` or the command
  line.
- A window linked into two sessions has one pane id in several sessions.
  `Sidebar.step` finds the client's pane by active pane id **and**
  `Tmux.client.session_id`.
- `-S` takes a socket path as supplied. A bare name is relative to
  the working directory, not `/tmp/tmux-<uid>/`.
  `-L` creates its socket directory.
  If `TMUX_TMPDIR` is unset, tmux selects `/tmp`.
  If it names a nonexistent directory, tmux reports an error.
  Programmatic tmux uses `-S` with an absolute path, especially for cleanup.
- An empty `TMUX=` still forces tmux's UTF-8 detection.
  For locale tests, unset `TMUX` entirely
  (`test_e2e/locale_test.go`).
- `list-sessions` can succeed with an empty list while the server
  reads its config. Only the launching client blocks.
  Readiness waits poll for a non-empty list.
  `test_e2e/launch_test.go` covers a slow `kido.conf`.
- `kill-server` returns before the processes that it SIGHUP'd exit.
  Teardown first collects the server's descendants.
  Then it waits for each to exit.
  A survivor is an error (`test_e2e/harness_test.go`).
- `display-popup` opens a floating pane in the fork's upstream base.
  `popup-style` and `popup-border-style` are invalid options.
  The fork reports the popup as `#{pane_modal_flag}`.
  It reports the pane under the popup as `#{pane_last}`.
- The side column's edge is a pane border.
  It follows `pane-border-lines` and `pane-border-style`.
  `share/tmux/kido-tmux.conf` deliberately sets no `pane-border-style`.
  That option would also change the style of real split borders.
- `share/tmux/kido-tmux.conf` applies to every kido user.
  Personal settings belong in `~/.config/kido/kido.conf`.
- Never assert on automatic `#{window_name}`.
  `automatic-rename` can read a transient process name.
  Rename the window to a fixed name. This turns `automatic-rename` off.

## Format-string invariants (`lib/state.ml`)

`State.format` joins fields with `\x1f`.
`State.parse` parses them by position.

- `#{pane_title}` stays **last** because it can contain anything.
- `pane_command_duration` is deliberately **absent**.
  It changes every second and would redraw the sidebar once a second forever.
- If you add a field, increase `State.fields`.
  Both the split count and the short-line guard in `parse_line` read it.
  The inline "field count pinned" test in `lib/state.ml` connects
  the two. The "fixture generated from the format" test checks a
  case that the "parse:" test misses. The manually typed fixture in
  the "parse:" test still passes if it omits a new field.
- If unset, `pane_command_status` prints **empty**, not `0`.
  Thus, `last_exit` is an `exit option`.
  It uses `None`, not a zero status (the "parse:" test's empty status).

## Native agent status

Only OSC 7501 root apps pi and claude-code identify agent panes.
Four pane options supply local pi identity, never detection:
`@kido_session`, `@kido_name`, `@kido_inbox` and `@kido_activity`.
kido trusts them only while the pane has an OSC 7501 root with
`app=pi` (docs/design.md, "Who is authoritative for what").
ssh panes use the pane-scoped `@kido_ssh` mark.
kido trusts this mark only while the foreground is `ssh`.
`kido ssh` sets the mark before exec and leaves it in place.
`@kido_ssh_args` records the connection arguments. See
[docs/design-program-status.md](docs/design-program-status.md) for the
option classification and read contract.

pi and Claude Code status, completion and blocked messages come from
their terminal records. kido ships no Claude Code executable shim.

Claude Code 2.1.295 queries OSC 7501.
Then it emits a root `app=claude-code` record: idle, working, done,
or blocked with permission/question kind and a base64 message.
Escape on a permission dialog emits idle immediately.
Exit clears all records.
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` also disables this reporting.
Its OSC 0 title was "Claude Code" at startup and "Reply with ok" for
the session.

Pane titles display verbatim, including status glyphs and prefixes.
For an empty title, native-only agents use the app name.
If its `@kido_name` is set, local pi uses that name.

## Agent runs, and delivering a prompt

Runs use the server directory resolved above.
Every run has one directory `runs/<id>/`. `kido run` and
`kido run-child` mint an opaque id. A run id is not a pi session id: a
restarted agent is a new run with the same session. `meta.json` and
`command` are written once at the start. `outcome` has racing writers,
and the first write wins. Each write replaces the whole file. There is
**no locking**. Policy resolves races:

- **kido has no caller.** `run-child` takes its parent as an argument:
  a run id, or the pane `%N` of a top-level pi. kido never finds a
  caller from the environment or its pane.
- **kido stores nothing for a pi session.** The extension writes the
  four options on its pane. A pane is a local pi only with a pi root
  and `@kido_session`. Thus, a stale option is no agent.
- **A run's status comes from its outcome and its pane, never a pid.**
  `Run.effective_outcome`: the outcome file, else the dead pane's
  `#{pane_dead_status}` (0 `completed`, N `failed` "exit N") or
  `#{pane_dead_signal}` (`failed` "signal NAME"), else `died`.
  Only the sweep, `run-outcome` and `run-stop` write an outcome.
- **The orphan rule reads the parent's status.** A `Run` parent has
  ended by the status rule above; a `Pane` parent (`%N`) when its pane
  is gone, dead or shows neither a pi root nor `@kido_session`. pi
  clears its root while it runs (external editor, Ctrl+Z), so the
  root alone is no evidence. Then `Reap.sweep` collects the
  unfocused run even while its command runs and records `failed` "its
  parent ended". A parentless run is exempt.

For a `Pi_agent`, `kido prompt` uses the pane's `@kido_inbox`.
`kido prompt` uses a tmux paste **only** when the pane has no
`@kido_inbox` (`Prompt.deliver`).
An advertised but unavailable inbox is an error, not permission to paste.

Other socket errors also return without a fallback.
The message may already have arrived.
Sending it again would deliver it twice.
A `Some_agent` receives a paste. `Terminal` is excluded.
The RPC prompt request uses the same scope rule and `Prompt.deliver`
(docs/design-rpc.md, "Prompting an agent").

`Prompt.send_prompt` **pastes rather than types**.
`send-keys -l` writes raw bytes.
Under bracketed paste, a bare newline submits and splits a multi-line
prompt. `load-buffer` + `paste-buffer -p` brackets the paste when
the application requests it. Otherwise, it pastes raw bytes.

Enter uses a **separate** `send-keys` after a delay.
If sent with the paste, Enter cuts the paste mid-line.

Exit codes are:

- `0`: sent.
- `1`: empty stdin or an error.
- `4`: no agent in scope.
- `5`: several agents in scope.

Scope is the caller's window.
Only if the window has no agents, scope widens to the session.
`--window` never widens.
Thus, widening can never resolve `5`.

## Installed-file lookup (`lib/bin_dir.ml`)

Shipped files are at `<prefix>/share/kido/...`, beside
`<prefix>/bin/kido`. This is Homebrew's `pkgshare` layout.
`make install` uses the same layout.

`Bin_dir.of_exe` tries the **unresolved** path first.
It resolves only as a fallback (`Fs.candidates`).
It starts from `Fs.invoked_path` on `argv[0]`.
It uses `Sys.executable_name` only as its last resort:

- Homebrew's `bin/kido` and `share/kido` are symlinks.
  Each upgrade changes their targets.
  The resolved path names a Cellar version directory that the next
  `brew cleanup` deletes.
  This leaves `side-status-command` and every pane's PATH with a
  nonexistent target.
- On Linux, `Sys.executable_name` reads `/proc/self/exe`.
  It always resolves, which defeats the ordering.

## Building

`make install PREFIX=<prefix>` installs these files:

- `bin/kido`.
- `bin/kido-tmux`.
- `share/kido`, including the shim that routes bare `kido` to that prefix.

It reuses the e2e revision-keyed fork cache under `build/tmux-fork/`.
`SELF_CONTAINED=1` passes `--self-contained` to the fork installer.
It uses a separate `<revision>-self-contained` cache entry.

kido uses the dune **3.24.2** binary distribution for builds.
Package management is on (`dune-workspace`).
The README's install line fetches this distribution.
`dune-project` declares dependencies.
Mosaic uses `(pin ...)` stanzas on a git commit.
Dependency resolution writes the committed `dune.lock`.

`dune pkg lock` regenerates the lock.
It always resolves against the newest opam-repository.
Thus, a re-lock requires review.
To change one dependency without other upgrades, pin the repositories
for the re-lock only. In `dune-workspace`, temporarily add a
`(repository ...)` stanza for each repository commit that
`dune.lock/lock.dune` records, and a `(lock_dir (path dune.lock)
(repositories ...))` stanza that names them. Run `dune pkg lock`, then
remove the stanzas. The lock diff must show only the intended package.
There is no `kido.opam`.
`dune-project` is the only dependency list.

The first build of a checkout compiles OCaml and every package in
`dune.lock`. This takes a few minutes.
After a clean `_build`, dune's shared cache restores them in seconds
(see `dune-workspace`).
`dune cache trim --size 5GB` limits the cache size.

ocamlformat is a dev tool, not a dependency.
Use `dune tools install ocamlformat`.
Then use `dune fmt`.
Dev tools are per checkout under `_build`.
`dune clean` deletes them.

They are not on PATH by default.
Use `dune tools which`, `dune tools exec` or
`eval "$(dune tools env)"`.

`dune show
depexts` prints nothing because there are no depexts.

Dune 3.24.2 with package management fails on an absolute
`DUNE_BUILD_DIR`.
Thus, `scripts/ci-like/Dockerfile` sets a relative one.

## Tests

    make verify  scrubbed dune build, dune test --force, full e2e and TypeScript tests
    make test    dune test --force and scripts/test-ts.sh (including scripts/lint.sh)
    make prompts regenerate the prompt fixtures through scripts/lint.sh --update-prompts
    make e2e     builds the pinned fork and runs the e2e suite
    make flake RUN=TestFoo COUNT=20  repeat one e2e test in the scrubbed environment
    make clean-forks  remove fork builds other than the pin
    make install binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/kido
    make website the website's dev server at http://localhost:4321 (website/README.md)

`make verify E2E=TestFoo` limits e2e.
`STAGES=e2e` selects only that stage.
Every selected stage runs even after a failure and prints PASS/FAIL.
Before a release, validation uses `make verify` in full.

CI runs on Ubuntu and macOS on every push and PR.
`scripts/main-watch.sh` watches main and reports each observed head's CI.
CI builds the fork at the pinned revision, cached by SHA.
`/gh-watch` starts `scripts/main-watch.sh` through streamed `async_bash`.
While you work, use `dune test` for repeated checks.
After you read an expect diff, `dune promote` accepts it.

**Test speed.** Tests stay very fast, because fast tests give fast
iterations. `make verify` prints the time of each stage on its
PASS/FAIL line. A full local run takes about 35 s. A change that makes
a stage slower needs a reason.

- Wait for the event, not for a time. A test that only waits longer
  than necessary is a defect. `scripts/lint.sh` permits `time.Sleep`
  in e2e only through its table of exact statements. The usual reason
  is tmux's whole-second timestamps.
- An absence check waits for the harness's `quiet` window. Do not add
  one where a positive assertion shows the same fact.
- Shorten a product timer through the inner server's environment
  (see "The e2e harness" below).
- Every e2e test calls `t.Parallel()`. A serial test needs a verified
  reason in a comment. e2e wall time is the CPU of all tests divided
  by the cores, so each tmux server start costs the whole suite. Put
  cases that need the same setup in one test, on one server.
- Test pure logic in a unit test, not through a tmux server.
- In the TypeScript suite, the fake `kido` is the OCaml executable
  `share/pi/testdata/fake_kido`. A Node process start costs about
  70 ms. A fake delay is a `KIDO_FAKE_*` gate that the test releases,
  not a delay that the test waits out. A test that reads only the
  registered tools needs no fixture.
- An ask's `timeoutMs` starts before discovery and the send. On
  macOS, the first execution of a freshly built fake costs about
  140 ms. Thus, an ask that expects a reply gets a timeout of
  seconds. Only a test of the timeout path uses a short one.
- A test earns its time. Do not keep a test that repeats another test,
  the prompt snapshot or the compiler.

To find slow tests:

    make verify STAGES=e2e | grep '^--- ' | sort -t'(' -k2 -nr | head -20
    make verify STAGES=ts | grep '^✔' | sort -t'(' -k2 -nr | head -20

**Prefer e2e tests.** Use `test_e2e/` to test behaviour that a user or
agent can observe through the binary. This includes a subcommand's
output, exit code, and effects on tmux or state.
Unit tests check pure library logic that e2e cannot reach or test
precisely: parsers, formats and ordering. Layout above specifies their
location.
Do not write a unit test that execs the binary.

`make e2e` builds the fork into `build/tmux-fork/<revision>/`.
It rebuilds only on a submodule bump.
It runs with `KIDO_E2E_REQUIRED=1`.
`KIDO_TMUX` in the environment names another fork and skips the build.
CI uses this to use its cached fork.
A bare `go test ./test_e2e/` with neither skips.

The harness requires the fork's `share/kido-tmux/REVISION` to match
the gitlink pin. If it is missing or differs, rebuild with
`scripts/install-tmux-fork.sh`.
The TypeScript suite requires Node 24 or newer.
Without it, the suite skips.
`KIDO_TS_TEST_REQUIRED=1` (set in CI) makes that a failure.

**Reproducing a CI-only failure:** `scripts/ci-like.sh` runs a Linux
container with the repo bind-mounted and CPU/memory capped.
It builds the fork at the pinned revision
(`make ci-like ARGS="--cpus 0.25 -- go test
./test_e2e/ -run TestFoo"`).
A CPU quota alone rarely reproduces timing failures.

`--contend N` starts N busy sibling containers.
With a low `--cpu-shares`, this makes a wrapper's timer run out of step
with its command as a loaded runner does.
If `--contend N` exceeds zero, the siblings equally share
`--budget` (default 2) minus the run's `--cpus` as their CPU quotas.
The script rejects a sibling quota of zero or less.
It does not cap a plain `--cpus`.

Use contention for one named failure, not a whole suite.
Never saturate the host's cores to reproduce a runner failure.
Other agents work in parallel.

**The e2e harness** (`test_e2e/harness_test.go`) nests two tmux servers.
The outer server hosts a pty.
The inner server is under test, with kido as its
`side-status-command`.
The harness reads the sidebar with `capture-pane`.

It builds kido with `dune build @install`.
Thus, it needs that dune on PATH.
It also builds fake `node` binaries that emit terminal titles and
native program status.

- The inner server's PATH starts with the built kido and the fork
  (`serverPathPrefix`).
  `kido-tmux.conf` bindings name bare `kido`/`tmux`.
  `run-shell` resolves them against the server's PATH.
  An installed kido hides a missing entry locally.
  CI gets exit 127.
- `cleanEnv` removes installed `share/kido/bin` PATH entries,
  `TMUX`, `TMUX_PANE`, `KIDO_STATE_DIR`, `KIDO_AGENT_*` and
  `KIDO_TMUX`.
  The suite often runs from a tracked agent's pane.
  `new-window` gives the inner server's environment to a spawned child.
  Otherwise, the developer's parent edge would enter the tests.
- `settle = 5s` is the default wait deadline.
  Wait helpers poll at 100ms, kido's tick.
  Shorten grace periods (linger, stop escalation)
  only through the inner server's environment, never in-process.
  This keeps the sidebar and extension's helper in agreement
  ("Knobs" in docs/design.md).
- Never put a fake on a shared PATH.
  It also shadows that name for every startup file.
  Tests that need a fake `pi` get their own PATH through
  `startPathPrefix`.
- After you send Escape to the sidebar, wait for its effect.
  Then send the next key.
  On a loaded runner, Mosaic joins a buffered ESC with the next byte
  into an Alt-key.
- macOS limits unix socket paths to 104 bytes, including the terminator.
  The suffix from `t.TempDir` can exceed this limit.
  Use the harness's short socket directories (`serverDir` /
  `launcherEnv`).
  A pid-0 liveness check tests a process group, not the child.
  Wait for a real published pid.
- Tests that execute `zsh -i` detach from the terminal
  (no TTY, `setsid`). Otherwise, the run hangs.
  Prefer timing ratios against a baseline measured in the same run
  to fixed wall-clock bounds.
- Ubuntu CI does not install zsh.
  compinit's insecure-directories prompt blocks e2e shells.
  Unit probes of host shells silently skip a missing shell.
  They print only mismatches.
- `dune test --force` can reuse a cached `.exe.output` target.
  `lib/test/tmux_server` does not declare `KIDO_TMUX` as a rule
  dependency.
  A flake loop over it needs the cache off.
- On macOS CI, `split-window` reporting "fork failed: Device not
  configured" is a runner pty flake.
  Rerun only the failed job (`gh run rerun --failed`).
  Do not cap parallelism.

Many tests have a comment that identifies their check or their
important assertion. Before you weaken or simplify such a test, read
its comment. Negative controls are essential.
Never delete one half of a pair.

### Other traps

- **`kido ssh` keeps `Bin_dir.look_path_past`.**
  Kido's bin directory precedes PATH in a primed pane.
  Removing the lookup breaks `TestKidoSSHOpensAnOrdinarySession`
  and `TestKidoSSHPrimesARemoteShell` in
  `test_e2e/ssh_prime_test.go`.
- **`Sidebar.same` compares panes by exclusion.**
  A new `State.pane` field participates in equality unless its local
  `drawn` blanks it.
  Failure causes extra redraws, which is the safe direction.
- **A window's panes are ordered oldest first**, by pane id number
  (`State.order_sessions`).
  This is not list-panes layout order: `split-window
  -b` puts a new pane first.
  The tree, the group glyph's row 0, `kido switch-session` and
  `kido switch-window` use that one sort.
- **`@kido_run` is pane-scoped (`set-option -p`).**
  It marks only the pane where a run runs.
  A user's split from that window reads "".
  There is no window-scoped fallback to inherit.
- **`Kido_sidebar.parts` is the column-alignment contract.**
  It draws every pane row's indicator as a one-column field.
  These cases get an empty field that keeps the column:
  - An unintegrated shell.
  - A program that has taken the terminal (no indicator).
  - An idle one (no glyph).

  Anything drawn left of a label must fit in space already included.
  `Kido_sidebar.lines` builds tree prefixes before the indicator column.
- **A standalone kido finds its client from a filtered count.**
  `#{client_name}` from a popup is unanswerable.
  `Sidebar.resolve_client` checks who is attached to the pane's session.
  It ignores kido's control-mode connections, one per real client.
  It reads control mode from its boolean, not an empty tty.
  A read-only client also has an empty tty.
- **`Tmux.exec` over a control handle kills its client on any timeout**.
  Subsequent calls re-dial after the retry backoff.
  One slow command requires a full reconnect.
- **`share/zsh/integration.zsh` must not name a local `status`**.
  This is a zsh special parameter.
  Shadowing it silently stops the precmd hook.
  The local is called `ret`.
- **A tmux command reaching a further parser has no surviving escape.**
  The generated `server.conf` (tmux -> sh) and a `new-window` window
  name (tmux -> sh -> tmux) use `Tmux.safe`.
  It refuses `'`, `"`, `$`, `#`, `\`, a backtick, a newline
  or a carriage return.
  It quotes a space.

## Working here as a spawned agent

These rules apply to every agent that kido spawns into this repo.
A brief does not repeat them.

- **One manager for each unit of work.** The top-level session gives a
  unit of work to one manager. The manager does not write code. It does
  these steps:
  1. It spawns one implementer.
  2. When the implementer reports, the manager writes the docs that the
     change needs itself, in `docs/`, this file and READMEs. The
     implementer reports the facts.
  3. The manager spawns the four read-only reviewers of a simplify pass,
     one angle each, so that review has fresh context. They review the
     code and the docs.
  4. The manager merges their findings and decides which to apply. It
     changes the docs that the findings affect.
  5. It gives the findings to apply to the same implementer with
     `message_agent`. The implementer keeps its context. The
     implementer's final `make verify` runs after the last docs edit,
     because `scripts/lint.sh` checks the references in the docs.
  6. It reports to the top-level session: the result, and each finding
     with the reason it was applied or rejected. Then it stops the
     implementer.
- **Do the task yourself.** An implementer or reviewer does not spawn
  subagents.
  Do not call `ask_agent`.
  Nobody waits for a question.
- **No git writes.** Do not commit, push, reset, add, checkout or stash.
  The top-level session commits.
  Leave work uncommitted.
  Never use `git stash`.
  If `KIDO_AGENT_PARENT_SESSION` is set,
  `.pi/extensions/no-git-writes` guards bash tool calls.
- **Other agents' uncommitted changes are expected.**
  Work runs in parallel.
  The brief identifies your files.
  Do not revert, clean or fix anything outside those files.
  Report it instead.
- **You are inside the user's live tmux server.**
  `kill-server` without `-S` and your own absolute socket path can
  kill that server.
  Start every test server on its own explicit socket
  (`tmux -S "$scratch/socket"`).
  End it with `kill-session`.
  Never change `~/bin/tmux`, `/opt/homebrew/bin/tmux` or the running server.
- **Scratch worktrees.** Use `mktemp -d /tmp/<name>-XXXXXX`.
  A bare `mktemp -d` on macOS resolves under `/var/folders`.
  There, `.pi/extensions/no-git-writes/policy.ts` refuses
  `git worktree add --detach`.
  It permits detached worktrees only under `/tmp`.

  The submodule makes `git worktree remove` refuse here.
  Remove the scratch directory with `rm -rf`.
  Then use `git worktree prune`.
- **Every wait has a deadline.**
  Do not poll without a deadline in code or your shell.
  macOS has no `timeout` command.
  Give the wait its deadline another way.
- **Verify what you touched; CI runs the whole.**
  If a bug's cause is not clear from the code, write the test first.
  This includes a race, a flake, or an incorrect assumption about
  tmux, pi or Claude Code.
  Watch the test fail.
  Quote that failure.
  A simple fix or a feature needs tests that only pass.

  Test in proportion to the change.
  For a trivial change, update the expected strings that it breaks.
  Do not add new tests for it.
  Trivial changes include a character of spacing or a word of text.

  Use negative controls only where a test could pass without checking
  the intended behaviour:
  timing, races, deduplication or polling.
  Negative controls break the code to prove that a test can fail.
  Never use them for a trivial change such as text, spacing or a
  renamed field.

  After the last edit, run `make verify` once.
  Use `E2E=TestFoo` to limit e2e to the changed behaviour.
  It controls environment scrubbing and pinned-fork selection.
  This replaces the separate build/test recipes.
  Do not also run `make test` or `make e2e`.

  Unless the brief requests `make flake`, do not use loops or a
  second tmux build.
  Report PASS/FAIL/SKIP as printed.
  If a failure is in a file you do not own, report it.
  Do not fix it.
- **Docs are not per task.**
  An implementer or reviewer does not edit `docs/`, this file or
  READMEs. Put prose that a change needs in your report.
  The manager writes the docs.
- **Report through `notify_parent`, under 4000 characters**.
  Start with what you built and the pre-fix failures.

## Releasing

kido deliberately has **no release version and no tags**.
Versioning uses the `kido` formula in `andreypopp/homebrew-tap`:
a git `revision:` with a manually increased `version`.
The formula pins only the kido git revision.
`make install` builds the fork from that revision's pinned
`third_party/tmux` submodule through `scripts/install-tmux-fork.sh`.

After the change is on `main`, run `scripts/release.sh VERSION`
(or `make release VERSION=x.y.z`).
Use `--dry-run` to inspect its actions.
It requires green CI for origin/main.
It compares tool and subcommand lists with the tap's current revision.
Removals or renames require a minor bump.
Panes must restart, not /reload.

The script edits and commits the brew tap formula.
It fast-forwards `~/Workspace/homebrew-tap`.
It pushes from that SSH checkout.
It never runs `brew upgrade`.

`make preview-pi` atomically replaces the installed pi extension.
It backs up the originals once.
`make unpreview-pi` restores them.
Afterward, run `/reload` in the panes.
`KIDO_PREVIEW_PREFIX` selects a fake install for tests.

Only `kido-app/N.N.N` tags mark Kido.app releases.
`app/scripts/release.sh` builds them from `kido-app`.
They are published as `Casks/kido-app.rb` in `andreypopp/homebrew-tap`.
kido itself never has tags.

`brew audit`/`brew style` vendor gems into the Homebrew checkout itself.
This can leave the checkout dirty.
Before a release, verify against a real tmux server.
The ppx_expect tests do not need tmux.
Without the fork, e2e silently skips.

## Commit style

Use one imperative sentence, usually with no prefix and no trailing period.
The body explains *why*, in hard-wrapped prose.
For a subtle change, it also explains why the test has that design.
Use recent history as the reference:

    Send a prompt as a paste, so its newlines survive
    Quitting an editor no longer flashes the row green
    A program that has taken the terminal is not a running job
    One status vocabulary for agents and shells

## Known-open

- A marked `ssh` pane stays running if its first remote prompt arrives
  in the same whole second that ssh starts.
  It stays running until a later remote prompt.
  `Pane_status.observe` requires `last_prompt > command_start`.
  Accepting a tie would mistake the local prompt for a remote one.
- An `ssh` from an unintegrated local shell reports Unknown until
  the first remote command completes.
  Without a local `command_start`, a remote prompt alone cannot latch
  `interactive`.

The subagent system has these design limits:

- A child moves to another session.
- A blocked ask holds a whole turn.
- A child exits before its window is kept.
- A child crashes before `notify_parent`.

These limits are under "Known limits" in docs/design.md and "Limits" in
docs/design-subagents.md.
