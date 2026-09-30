# Developing kido

What kido does and how it is installed is in [README.md](README.md). This
file is the context that is not in the code: the tmux fork it depends on,
what Claude Code actually reports, and the invariants a plausible-looking
change would break.

kido's own design decisions - which store is authoritative for what, the
inbox protocol, addressing, the ask/reply cycle rule, spawning and the
window lifecycle, run outcomes, the heartbeat, and the seam between the
two pi extensions - live in [docs/design.md](docs/design.md), with the
subagent side in [docs/design-subagents.md](docs/design-subagents.md).
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
  bodies of commands that only read, print and exit (`set_status`,
  `agent-alive`, `snapshot`, `ssh`, ...). `lib/` is the library `kido`,
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
- **Environment.** Read it at the edge and pass the value: functions
  take `~dir`, `~threshold`, `~now`. Tests pass a temp dir; nothing in a
  test sets an env var or swaps a global.
- **Time** is `Timestamp.t`, unix seconds as a float, on disk as RFC 3339
  UTC.
- `dune build`, `dune test`, `dune fmt`, with no opam: dune's package
  management builds the compiler and every dependency of `dune.lock`
  into `_build` (README.md, "Building" below).

## Layout

    bin/main.ml        the cmdliner command table and the small commands:
                       set_status, agent-alive, children-alive, snapshot,
                       ssh, window-focused, switch-session/window, server,
                       sidebar-feed
    bin/cli.ml         failure printing and tables
    lib/               the library kido:
      launch.ml        the launcher and `kido server`: the kido server, its
                       server.conf
      shell.ml, prime.ml  kido shell: the login shell and its priming files
      bin_dir.ml       the shipped-file and bin-directory lookup
      sidebar.ml       the sidebar's model: the tick, tracking and the shell-status
                       debounce, rows as data, the feed's JSON
      ui.ml            the Mosaic sidebar: the model's rows drawn, keys, cursor
      screen.ml        reading a Claude Code screen for a dismissed prompt
      state.ml         one JSON file per agent session, keyed by pane
      hook.ml          Claude Code hook event -> status table
      reporting.ml     kido hook and kido agent-status
      procs.ml         process-tree scan: agent panes, ssh destinations
      msg.ml           the inbox wire protocol and its client: v0 raw prompt,
                       v1 envelope, the unix-socket sender and notify
      tree.ml          the parent-first walk behind list_agents and the sidebar
      reap.ml          which subagent windows are finished with, and when;
                       an ending's text and its send to the parent's inbox
      subrun.ml        the durable record of one `kido spawn_subagent`
      prompt.ml, message_agent.ml (also ask_agent and notify_parent),
      list_agents.ml, spawn_subagent.ml, async_bash.ml,
      async_run.ml (its wrapper), async_stream.ml, runs.ml,
      control.ml (stop/interrupt_subagent)
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
      bin/             the bin directory's sh shims (tmux, ssh, pi, claude)
      shim.sh          their shared helper
      bash/, zsh/      the OSC 133 integrations every primed shell sources
      tmux/            kido-tmux.conf, the defaults the launcher writes into
                       server.conf (embedded, not installed)
      claude/          settings.json, the hooks file the claude shim hands to Claude Code
      pi/              the two pi extensions, which the pi shim loads with --extension
    scripts/           the fork build; ci-watch.sh, which waits for a commit's CI run (async_bash it);
                       ci-like.sh; test-ts.sh; dump-prompts.ts, every prompt text pi registers
    third_party/tmux   the tmux fork, a git submodule built as kido-tmux
    test_e2e/          tests driving kido inside a real tmux server, in Go

`dune build`; the binary is `bin/main.exe`, installed as `kido`. `lib/`
embeds the shell integrations and `share/tmux/kido-tmux.conf` at build time.

**Tool name == subcommand name.** Every subagent tool in `share/pi/` invokes
the subcommand of its own name (table in docs/design-subagents.md). A new
tool brings a subcommand spelled the same way; there are no aliases, and
a divergence is a silent runtime failure, not a build one;
`lib/test/test_tool_parity.ml` runs each tool in `share/pi/testdata/tools.json` as
a subcommand. A subcommand
no tool calls is named however it reads best (`async-run`); `async_bash`
took the underscore before its tool existed, because renaming a command
once something calls it is the harder half.

## The tmux fork

kido only runs under [andreypopp/tmux](https://github.com/andreypopp/tmux),
vendored as the submodule `third_party/tmux` (`tmux -V` prints
`next-3.9`): [PR tmux/tmux#5468](https://github.com/tmux/tmux/pull/5468)
(side status) plus a `side-status-command` patch and the OSC 133
command-line capture, the pause flush for control clients. The fork is
kept rebased, never merged: `fork` is a linear branch of kido's commits on
top of the PR's current head, which the PR keeps rebased on upstream
master. An upstream fix therefore arrives by rebasing onto the PR (or
onto master, should the PR land), not by cherry-picking it, and a commit
upstream or the PR already carries is dropped. Force-pushing `fork`
leaves older submodule pins unreachable, so the previous head is pushed
first as a dated branch (`fork-YYYY-MM-DD`).
`scripts/install-tmux-fork.sh <prefix>` builds it
into `<prefix>/bin/kido-tmux`; `--print-revision` reads the pin with
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

**OSC 133.** `input_osc_133()` in the fork's `input.c`:

| sequence | effect |
|---|---|
| `A`, `N` | `wp->last_prompt_time = time(NULL)`, fires `pane-shell-prompt` |
| `C` | sets `PANE_CMDRUNNING`, `cmd_start_time`, **`cmd_status = -1`**, stores the `cmdline=` parameter as `#{pane_command_line}`, fires `pane-command-started` |
| `D[;status]` | clears `PANE_CMDRUNNING`, sets `cmd_end_time`/`cmd_status`, fires `pane-command-finished` |

tmux stores the value through `clean_name()`: control bytes are dropped
and `#(` becomes `_(`. The shell integrations therefore send the command
line **verbatim** apart from blanking control characters (zsh also caps
it at 1024); anything it
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
`PANE_CMDRUNNING` set, and the next prompt's `A` clears it. Two fork
changes would each delete a workaround: clearing `PANE_CMDRUNNING` on `A`
(the heal rule), and not clearing `cmd_status` on `C` (`Sidebar.phase.held`).
Not done.

**Why not `pane_current_command`.** It reports the process-group leader,
which confuses an interactive shell with a batch `zsh -c`.
`#{alternate_on}` reports the *innermost* program (`less` under `git`,
`nvim` under `sudo`) and is what `Sidebar.interactive_pane` uses to decide a
program has taken the terminal.

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

## What Claude Code actually reports

`lib/hook.ml` is the event table (`Hook.apply`). These were measured from
logged events (`tail -f "$(kido debug-log)"`), not read from docs:

- **`SubagentStop` fires on every subagent turn.** Its firing means
  nothing; only its `background_tasks` do.
- **A subagent's tool calls arrive under the parent `session_id`** with
  `agent_id` set. So `working` in `Hook.apply` clears the background
  flag only when `agent_id` is empty; otherwise the session would strand
  at running.
- **`idle_prompt` fires ~60s after *every* `Stop`** and carries no
  `background_tasks`. Without the `parked` guard a session doing
  background work goes idle a minute in.
- **`TaskCompleted` never appears.** Nothing fires it, so a session held
  open by a background *shell* alone never returns to idle. Known gap.

Claude Code reports nothing when a question is dismissed or a permission
denied; kido reads the pane's screen instead (`lib/screen.ml`, fixtures
from real screens in lib/test/test_screen.ml). That probe runs for a
`State.Claude` session in `Waiting` only, enforced by a match in
`Sidebar.dismissals`, not by a type.

## Agent state, and delivering a prompt

State lives in `$KIDO_STATE_DIR`, else `$XDG_STATE_HOME/kido`, else
`~/.local/state/kido` — one JSON file per agent session, named by session
id, written temp-file-then-rename. There is **no locking**; races are
resolved by policy:

- **One live holder per session id.** `State.record` creates a record
  with `Unix.link` from its own pid-named temp file (atomic, fails if
  taken); an existing record is overwritten only by the pid it names or
  once that pid is dead. `State.remove` follows the same rule. A refusal
  is `Error holder`, and `kido agent-status` exits **6** for it, which
  `share/pi/kido-status.ts` reads to stop reporting. Change that exit code in
  one half only and a second pi silently clobbers a live session.
- `State.load_live` **removes** a file whose recorded pid is dead, rather than
  skipping it; that is what cleans up pi's per-turn headless Claude Code
  sessions.
- When two records claim one pane, the **outer** agent wins regardless of
  timestamp (`outer`, `beats` in `State.by_pane`): pi runs Claude Code
  in its own pane.
  Anything not literally `"claude"` is outer, so two non-Claude records on
  one pane fall to the timestamp and the winner flips (a headless
  `pi --print` inherits `TMUX_PANE`). That flip is accepted
  (lib/test/test_state.ml, "the outer agent wins a shared pane"): nothing
  can tell it from an agent's own record legitimately changing.
- **Never hand `Reap.sweep` a pane-keyed view.** The sidebar's view is
  `State.load_live` then `State.by_pane`; anything asking "is this
  session running *anywhere*" takes `load_live`'s list, which drops
  nothing. A pane-keyed view makes the flip
  above close a parent's children — the bug that killed two live agents.

`kido prompt` prefers the recorded inbox socket (`kido-status.ts` binds
one) and falls back to a tmux paste **only** on `Msg.Unavailable`
(`Prompt.deliver_or_paste`).
Any other socket error returns without a fallback: the message may
already have been delivered, and re-sending would double-send.

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
`dune tools install ocamlformat` once, then `dune fmt`. `dune show
depexts` prints nothing; there are none.

Dune 3.24.2 with package management dies on an absolute
`DUNE_BUILD_DIR`; `scripts/ci-like/Dockerfile` therefore sets a relative
one.

## Tests

    make test    dune test (the ppx_expect suites in lib/test/ and lib_tmux/test/) and
                 scripts/test-ts.sh: one node suite for both pi extensions
    make e2e     builds the fork into build/ and runs go test ./test_e2e/ against it
    make install binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/kido

Validation before a release is `make test` then `make e2e`, in full; CI
runs both on Ubuntu and macOS on every push and PR (`scripts/ci-watch.sh`
waits for it), building the fork at the pinned revision, cached by SHA.
While working, `dune test` is the loop; `dune promote` accepts an expect
diff once it has been read.

**Prefer e2e tests.** A behaviour a user or an agent can observe (a
subcommand's output, exit code, side effects on tmux or state) is
tested in `test_e2e/`, through the binary. Unit tests in `lib/test/` and `lib_tmux/test/` are for pure
library logic that e2e cannot reach or cannot pin precisely (parsers,
formats, ordering); do not write a unit test that execs the binary.

`make e2e` builds the fork into `build/tmux-fork/<revision>/` (rebuilt
only on a submodule bump) and runs with `KIDO_E2E_REQUIRED=1`. A
`KIDO_TMUX` in the environment names another fork and skips the build
(how CI uses its cached one). A bare `go test ./test_e2e/` with neither
skips. The TypeScript suite skips without a node that runs `.ts`
unflagged; `KIDO_TS_TEST_REQUIRED=1` (set in CI) makes that a failure.

**Reproducing a CI-only failure:** `scripts/ci-like.sh` runs a Linux
container with the repo bind-mounted, CPU/memory capped, and the fork
built at the pinned revision (`make ci-like ARGS="--cpus 0.25 -- go test
./test_e2e/ -run TestFoo"`). A CPU quota alone rarely reproduces timing
failures; `--contend N` starts N busy sibling containers, and with a low
`--cpu-shares` desyncs a wrapper's timer from its command the way a
loaded runner does. `--budget` (default 2) caps the host cores a run
takes, siblings included; contention is for one named failure, not a
whole suite. Never saturate the host's own cores to chase a runner
failure: other agents are working in parallel.

**The e2e harness** (`test_e2e/harness_test.go`) nests two tmux servers — an
outer one hosting a pty, the inner one under test with kido as its
`side-status-command` — and reads the sidebar with `capture-pane`. It
builds kido with `dune build` (so it needs that dune on PATH), and fake
`claude` and `node` binaries that reproduce real screens.

- The inner server's PATH starts with the built kido and the fork
  (`serverPathPrefix`), because `kido-tmux.conf` bindings name bare
  `kido`/`tmux` resolved by `run-shell` against the server's PATH. An
  installed kido masks a missing entry locally; CI gets exit 127.
- `cleanEnv` strips `KIDO_AGENT_*` and `KIDO_TMUX`: the suite is often
  run from a tracked agent's pane, and the inner server's environment is
  what `new-window` gives a spawned child, so the developer's own parent
  edge would leak into tests.
- `settle = 5s` is the only wait; wait helpers poll at 100ms, kido's
  tick. Every grace period (linger, stop escalation, stall threshold) is
  shortened only through the inner server's environment, never
  in-process, so the sidebar and the extension's helper agree ("Knobs" in
  docs/design.md).
- Never put a fake on a shared PATH: it shadows that name for every
  startup file too. Tests needing a fake `pi` get their own PATH through
  `startPathPrefix`.

Many tests carry a comment saying what they pin or which assertion
carries them; read it before weakening or "cleaning up" such a test.
Negative controls are load-bearing: never delete one half of a pair.

### Other traps

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
  indicator is drawn there as a two-column field. An unintegrated shell and
  a program that has taken the terminal (no indicator) and an idle one (no
  glyph) get an empty field — column kept. Anything
  drawn left of a label must fit in space already accounted for; a child
  window's group glyph has its own column, its bracket the next.
- **A standalone kido infers its client by counting, filtered.**
  `#{client_name}` from a popup is unanswerable. `Tmux.Exec.resolve_client`
  asks who is attached to the pane's session, ignoring kido's own
  control-mode connections (one per real client). Control mode is read
  from its boolean, not an empty tty (a read-only client has one too).
- **`Tmux.Conn.run` kills the control client on any timeout** and the
  next call re-dials; one slow command costs a full reconnect.
- **`share/zsh/integration.zsh` must not name a local `status`** — a zsh
  special parameter; shadowing it silently stops the precmd hook. It is
  called `ret`.
- **`kido hook` must never fail the caller.** Errors print to stderr and
  exit 0: `Cli.run ~failure:0`, and `bin/main.ml` exits 0 for a `hook`
  whose arguments cmdliner rejects.
- **`Procs.reporter_pid` walks up to three ancestors past wrapping
  shells.** Claude Code runs `sh -c "kido hook"`, and Linux dash does not
  `exec` the final command.
- **A tmux command reaching a further parser has no surviving escape.**
  The generated `server.conf` (tmux -> sh) and a `new-window` window name
  (tmux -> sh -> tmux) go through `Launch.tmux_safe`,
  which refuses `'`, `"`, `$`, `#`, `\`, a backtick, a newline or a
  carriage return. A space is quoted.
- **`KIDO_HOOK_DEBUG` is the only switch for the hook's debug log**, set
  in the environment of the pane Claude Code starts in; no kido flag can
  reach `kido hook`. It logs the events share/claude/settings.json registers
  (lib/test/test_bin_dir.ml pins the list); other events must be registered
  by hand in the user's settings.json (`--settings` merges).

## Working here as a spawned agent

These apply to every agent kido spawns into this repo; a brief does not
repeat them.

- **Do the task yourself.** Do not spawn subagents or call `ask_agent`;
  nobody is waiting to be asked.
- **No git writes.** No commit, push, reset, add, checkout or stash. The
  top-level session commits. Leave work uncommitted. Never `git stash`.
- **Other agents' uncommitted changes are expected.** Work runs in
  parallel; the brief says which files are yours. Do not revert, clean
  or fix anything outside them - report it instead.
- **You are inside the user's live tmux server.** `kill-server` without
  `-L` or `-S` naming your own socket kills it. Start every test server
  on its own socket (`tmux -L t-$$`), end it with `kill-session`, and
  never touch `~/bin/tmux`, `/opt/homebrew/bin/tmux` or the running
  server.
- **Every wait has a deadline.** No open-ended polling in code or in
  your own shell.
- **Verify what you touched; CI runs the whole.** For a bug fix, write
  the test first, watch it fail, and quote that failure. A feature's
  tests need only pass. Then run `dune build` and `dune test` (an e2e
  test you wrote with `KIDO_E2E_REQUIRED=1 KIDO_TMUX=$(command -v
  kido-tmux) go test ./test_e2e/ -run Name`, or the fork under
  `build/tmux-fork/` once `make e2e` built it; `scripts/test-ts.sh` if
  you touched `share/pi/`), each once, with the environment scrubbed:

      env -u KIDO_AGENT_PARENT_SESSION -u KIDO_AGENT_DEPTH -u KIDO_AGENT_TASK_FILE -u KIDO_AGENT_PARENT_PID -u KIDO_AGENT_RUN_ID -u TMUX_PANE dune test

  Do not run `make test` or `make e2e`: the top-level session pushes and
  CI runs both. No loops, no second tmux build. Report PASS/FAIL/SKIP as
  printed; a failure in a file you do not own is reported, not fixed.
- **Docs are not per task.** Do not edit `docs/` or this file unless the
  brief assigns them. Put any prose a change deserves in your report.
- **Report through `notify_parent`, under 4000 characters**, leading
  with what was built and the pre-fix failures.

## Releasing

The repo carries **no version and no tags, deliberately**. Versioning
lives in `andreypopp/homebrew-tap`'s `kido` formula: a git `revision:`
with a hand-bumped `version`. The formula fetches the tmux fork as a
resource at the revision `scripts/install-tmux-fork.sh --print-revision`
prints (the separate `tmux` formula is retired). A release is

1. land on `main` here (CI green),
2. bump `revision:` and `version` in the `kido` formula — and its tmux
   resource when the submodule pin moved — then push the tap,
3. `brew upgrade`.

Do not add a tag. `brew audit`/`brew style` vendor gems into the
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

- A background shell has no completion event, so a Claude Code session
  held open by one alone never returns to idle.
- An interactive `ssh` pane whose far side reaches its first prompt in
  the same whole second the ssh started reports nothing until the prompt
  after its first remote command: `Sidebar.observe_remote` reads
  `last_prompt > command_start` strictly. Accepting the tie is not
  the fix — a local prompt and an ssh launched from it share a second
  just as readily, and every non-integrated remote would then hold the
  row green for the life of the connection.

The subagent system's design limits (a child moved to another session, a
blocked ask holding a whole turn, a child that exits before its window is
kept, a child that crashes before `notify_parent`) are under "Known
limits" in docs/design.md and "Limits" in docs/design-subagents.md.
