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

## Code commenting guidelines

A comment earns its place by saying something the code cannot. Delete,
rather than reword, narration of the line below, banners, and
commented-out code. Keep: a verified external constraint (platform,
vendor protocol, dependency quirk); a link to the issue behind a
constraint the code cannot express; legal notices and public-contract
doc comments; and a workaround's explanation for as long as the
workaround lives - they go together.

Build, compiler and formatter directives are not comments. Read a
diagnostic suppression's rule before judging it: a false positive or
style-only rule stays; one hiding a correctness or safety failure means
fixing the cause.

A loud comment (`IMPORTANT`, `do not remove`, a long justification) is a
claim to check, not obey or discard. Where evidence that a claimed
constraint still holds is missing, keep the comment and say so. Do not
invent a defect or call deliberate behaviour a bug. Removing comments
never licenses changing behaviour; keep the two in separate changes.

A stale *why* is worse than none because it is trusted: when a mechanism
changes, grep for the prose that described it. Design rationale belongs
in `docs/`, not beside the code.

## Layout

    cmd/kido/          subcommand dispatch (main.go), the launcher
                       (launch.go, shell.go, prime.go, bindir.go), prompt,
                       message_agent (also ask_agent and notify_parent),
                       set_status, list_agents, spawn_subagent,
                       async_bash and its async-run wrapper,
                       steer/stop/interrupt_subagent, reap, runs,
                       snapshot, inbox, ssh (the remote bootstrap)
    internal/ui/       the Bubble Tea model, rendering, shell-status debounce
    internal/tmux/     pane listing and formats (tmux.go), control-mode client (conn.go)
    internal/state/    one JSON file per agent session, keyed by pane
    internal/hook/     Claude Code hook event -> status table
    internal/procs/    process-tree scan: agent panes, ssh destinations
    internal/msg/      the inbox wire protocol: v0 raw prompt, v1 envelope
    internal/tree/     the parent-first walk behind list_agents and the sidebar
    internal/reap/     which subagent windows are finished with, and when
    internal/subrun/   the durable record of one `kido spawn_subagent`
    internal/testutil/ test scaffolding shared by more than one package
    shell/             the zsh and bash OSC 133 integrations every primed shell sources
    tmux/              kido-tmux.conf, the defaults the launcher writes into server.conf
    shims/             the bin directory's sh shims (tmux, ssh, pi, claude) and shim.sh
    claude/            settings.json, the hooks file the claude shim hands to Claude Code
    scripts/           install-share.sh, the one description of share/kido; the fork build;
                       ci-watch.sh, which waits for a commit's CI run (async_bash it);
                       ci-like.sh; test-ts.sh; dump-prompts.ts, every prompt text pi registers
    third_party/tmux   the tmux fork, a git submodule built as kido-tmux
    pi/                the two pi extensions, which the pi shim loads with --extension
    e2e/               tests driving kido inside a real tmux server

`go build ./cmd/kido`; module name is `kido`, no external build steps.

**Tool name == subcommand name.** Every subagent tool in `pi/` invokes
the subcommand of its own name (table in docs/design-subagents.md). A new
tool brings a subcommand spelled the same way; there are no aliases, and
a divergence is a silent runtime failure, not a build one. A subcommand
no tool calls is named however it reads best (`async-run`); `async_bash`
took the underscore before its tool existed, because renaming a command
once something calls it is the harder half.

## The tmux fork

kido only runs under [andreypopp/tmux](https://github.com/andreypopp/tmux),
vendored as the submodule `third_party/tmux` (`tmux -V` prints
`next-3.9`): [PR tmux/tmux#5468](https://github.com/tmux/tmux/pull/5468)
(side status) plus a `side-status-command` patch and the OSC 133
command-line capture. `scripts/install-tmux-fork.sh <prefix>` builds it
into `<prefix>/bin/kido-tmux`; `--print-revision` reads the pin with
`git ls-files -s`, so it works with the submodule unchecked-out or the
pin only staged.

kido finds its tmux in this order: `$KIDO_TMUX`, then a `kido-tmux`
beside its own executable (unresolved invoked path first, as in
`findShared`), then `tmux` on PATH. The e2e harness gives the built kido
that sibling, so the suite runs the resolution users get.

**The side column.** `side-status-command` runs a program in the side
column with `$TMUX_SIDE_CLIENT` set. Its absence is exactly "not started
as a side column", i.e. `ui.Options.Standalone` - a popup or plain pane
gets the one-shot picker. Keyboard focus is the client flag
`side-status-focus`.

**OSC 133.** `input_osc_133()` in the fork's `input.c`:

| sequence | effect |
|---|---|
| `A`, `N` | `wp->last_prompt_time = time(NULL)`, fires `pane-shell-prompt` |
| `C` | sets `PANE_CMDRUNNING`, `cmd_start_time`, **`cmd_status = -1`**, stores the `cmdline=` parameter as `#{pane_command_line}`, fires `pane-command-started` |
| `D[;status]` | clears `PANE_CMDRUNNING`, sets `cmd_end_time`/`cmd_status`, fires `pane-command-finished` |

`#{pane_command_line}` is not in every build of the fork; a tmux without
it expands it to the empty string, the same as a shell reporting no
command line. So no row may require the value to draw, and an e2e test
asserting on it gates on that probe (`TestSSHRowShowsRemoteCommandLine`).

tmux stores the value through `clean_name()`: control bytes are dropped
and `#(` becomes `_(`. The shell integrations therefore send the command
line **verbatim** apart from blanking control characters (zsh also caps
it at 1024); anything it
escaped would be escaped again and reach the sidebar unreadable.

Consequences:

- **These are hooks only.** No control-mode notification exists for
  them; kido reads the `#{pane_command_*}` formats on its poll. Do not go
  looking for `%pane-command-started`.
- **Timestamps are whole seconds.** `Pane.ShellStatus()` compares
  `LastPromptTime > CommandStartTime`, and a tie resolves to *running* —
  a false idle the instant a command starts is the worse error.
- **`cmd_status` is cleared on `C`,** so the last exit code is gone when
  the next command starts. `shellPhase.held`/`heldOK` (`internal/ui`)
  carry it across the following run.

`ShellStatus` also heals a stuck flag: a `C` with no `D` leaves
`PANE_CMDRUNNING` set, and the next prompt's `A` clears it. Two fork
changes would each delete a workaround: clearing `PANE_CMDRUNNING` on `A`
(the heal rule), and not clearing `cmd_status` on `C` (`held`/`heldOK`).
Not done.

**Why not `pane_current_command`.** It reports the process-group leader,
which confuses an interactive shell with a batch `zsh -c`.
`#{alternate_on}` reports the *innermost* program (`less` under `git`,
`nvim` under `sudo`) and is what `model.interactivePane` uses to decide a
program has taken the terminal.

## Format-string invariants (`internal/tmux/tmux.go`)

`paneFormat` is `\x1f`-joined and parsed positionally by `parsePanes`.

- `#{pane_title}` stays **last**; it may contain anything.
- `pane_command_duration` is deliberately **absent**: it ticks every
  second and would redraw the sidebar once a second forever.
- Adding a field means bumping `paneFields`, which both the `SplitN`
  count and the `len(f)` guard read.
  `TestPaneFormatFieldCountMatchesConstant` pins the two together;
  `TestPaneFormatFixtureFromFormat` exists because `TestParsePanes`'s
  hand-typed fixture stays green when a new field is left out of it.
- `pane_command_status` prints **empty**, not `0`, when unset — hence the
  separate `CommandStatusOK` bool (`TestParsePanesEmptyCommandStatus`).

## What Claude Code actually reports

`internal/hook/hook.go` is the event table. These were measured from
logged events (`tail -f "$(kido debug-log)"`), not read from docs:

- **`SubagentStop` fires on every subagent turn.** Its firing means
  nothing; only its `background_tasks` do.
- **A subagent's tool calls arrive under the parent `session_id`** with
  `agent_id` set. So `working()` clears the background flag only when
  `AgentID == ""`; otherwise the session would strand at running.
- **`idle_prompt` fires ~60s after *every* `Stop`** and carries no
  `background_tasks`. Without the `in.Background` guard a session doing
  background work goes idle a minute in.
- **`TaskCompleted` never appears.** It is in `allEvents`, but nothing
  fires it, so a session held open by a background *shell* alone never
  returns to idle. Known gap.

Claude Code reports nothing when a question is dismissed or a permission
denied; kido reads the pane's screen instead (`internal/ui/screen.go`,
fixtures from real screens). That probe runs for `AgentClaude` only,
enforced by an early `continue`, not by a type.

## Agent state, and delivering a prompt

State lives in `$KIDO_STATE_DIR`, else `$XDG_STATE_HOME/kido`, else
`~/.local/state/kido` — one JSON file per agent session, named by session
id, written temp-file-then-rename. There is **no locking**; races are
resolved by policy:

- **One live holder per session id.** `Record` creates a record with
  `os.Link` from its own pid-named temp file (atomic, fails if taken); an
  existing record is overwritten only by the pid it names or once that
  pid is dead. `Remove` follows the same rule. A refusal is
  `state.HeldError`, and `kido agent-status` exits **6** for it, which
  `pi/kido-status.ts` reads to stop reporting. Change that exit code in
  one half only and a second pi silently clobbers a live session.
- `Load()` **removes** a file whose recorded pid is dead, rather than
  skipping it; that is what cleans up pi's per-turn headless Claude Code
  sessions.
- When two records claim one pane, the **outer** agent wins regardless of
  timestamp (`outer()`, `beats()`): pi runs Claude Code in its own pane.
  Anything not literally `"claude"` is outer, so two non-Claude records on
  one pane fall to the timestamp and the winner flips (a headless
  `pi --print` inherits `TMUX_PANE`). That flip is accepted
  (`TestLoadTwoOuterRecordsOnOnePaneFlipByTimestamp`): nothing can tell
  it from an agent's own record legitimately changing.
- **Never hand `reap.Sweep` a pane-keyed view.** `Load` is `LoadLive`
  plus `ByPane`; anything asking "is this session running *anywhere*"
  takes the slice, which drops nothing. A pane-keyed view makes the flip
  above close a parent's children — the bug that killed two live agents.

`kido prompt` prefers the recorded inbox socket (`kido-status.ts` binds
one) and falls back to a tmux paste **only** on `errInboxUnavailable`.
Any other socket error returns without a fallback: the message may
already have been delivered, and re-sending would double-send.

`SendPrompt` **pastes rather than types**: `send-keys -l` writes raw
bytes, and under bracketed paste a bare newline submits, splitting a
multi-line prompt. `load-buffer` + `paste-buffer -p` brackets when the
application asked for it and pastes raw otherwise. Enter is a
**separate** `send-keys` after a delay; sent with the paste it cuts the
paste mid-line.

Exit codes: `0` sent, `1` empty stdin or an error, `4` no agent in scope,
`5` several. Scope is the caller's window, widening to the session only
when the window had none (`--window` never widens) — so `5` can never
be resolved by widening.

## Installed-file lookup (`cmd/kido/shared.go`)

Shipped files live at `<prefix>/share/kido/...` beside `<prefix>/bin/kido`
(Homebrew's `pkgshare` layout; `make install` mirrors it).

`findShared` tries the **unresolved** path first and resolves only as a
fallback, and uses `invokedPath(os.Args[0])`, not `os.Executable()`:

- Homebrew's `bin/kido` and `share/kido` are symlinks repointed on every
  upgrade. The resolved path names a Cellar version directory the next
  `brew cleanup` deletes, leaving `side-status-command` and every pane's
  PATH pointing at nothing.
- On Linux `os.Executable()` reads `/proc/self/exe` and always resolves,
  defeating the ordering.

## Tests

    make test    go vet ./..., the unit tests (cmd/..., internal/...),
                 and scripts/test-ts.sh: one node suite for both pi extensions
    make e2e     builds the fork into build/ and runs go test ./e2e/ against it
    make install binary to $PREFIX/bin (default ~/.local), shared files to $PREFIX/share/kido

Validation before a release is `make test` then `make e2e`, in full; CI
runs both on Ubuntu and macOS on every push and PR (`scripts/ci-watch.sh`
waits for it), building the fork at the pinned revision, cached by SHA.
While working, `go test` on the changed package is the loop.

`make e2e` builds the fork into `build/tmux-fork/<revision>/` (rebuilt
only on a submodule bump) and runs with `KIDO_E2E_REQUIRED=1`. A
`KIDO_TMUX` in the environment names another fork and skips the build
(how CI uses its cached one). A bare `go test ./e2e/` with neither
skips. The TypeScript suite skips without a node that runs `.ts`
unflagged; `KIDO_TS_TEST_REQUIRED=1` (set in CI) makes that a failure.

**Reproducing a CI-only failure:** `scripts/ci-like.sh` runs a Linux
container with the repo bind-mounted, CPU/memory capped, and the fork
built at the pinned revision (`make ci-like ARGS="--cpus 0.25 -- go test
./cmd/kido/ -run TestFoo"`). A CPU quota alone rarely reproduces timing
failures; `--contend N` starts N busy sibling containers, and with a low
`--cpu-shares` desyncs a wrapper's timer from its command the way a
loaded runner does. `--budget` (default 2) caps the host cores a run
takes, siblings included; contention is for one named failure, not a
whole suite. Never saturate the host's own cores to chase a runner
failure: other agents are working in parallel.

**The e2e harness** (`e2e/harness_test.go`) nests two tmux servers — an
outer one hosting a pty, the inner one under test with kido as its
`side-status-command` — and reads the sidebar with `capture-pane`. It
builds fake `claude` and `node` binaries that reproduce real screens.

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

- **Indicator styles must render on call, never at package init.** A
  lipgloss style fixes its colour profile on first render, and `ui.Run()`
  sets the profile after init (tmux passes `CI` to the side-status job,
  which termenv reads as "no TTY"). A package-level
  `var x = style.Render("▌")` comes out unstyled, and no test catches it.
- **`samePanes`/`drawnPart` compare by exclusion.** A new `tmux.Pane`
  field participates in equality unless zeroed in `drawnPart`. It fails
  toward extra redraws, the safe direction.
- **A window's panes are ordered oldest first**, by pane id number
  (`tmux.OrderSessions`), not in list-panes layout order (`split-window
  -b` puts a new pane first). The tree, the group glyph's row 0,
  `kido switch-session` and `kido switch-window` rely on that one sort.
- **A pane option that must not fall back to the window needs
  `set-option -p`.** `@kido_subagent` (`-w`) answers for every pane;
  `@kido_subagent_pane` (`SubagentPaneOption`) reads empty on a user's
  split. They are set by two commands, so a tick can see the window mark
  first; `lingeringSubagents` re-reads until the pane has one.
- **`field()` is the column-alignment contract.** Every pane-label
  branch routes through it. An unintegrated shell and a program that has
  taken the terminal get an empty field — no glyph, column kept. Anything
  drawn left of a label must fit in space already accounted for; a child
  window's group glyph has its own column, its bracket the next.
- **A standalone kido infers its client by counting, filtered.**
  `#{client_name}` from a popup is unanswerable. `tmux.ResolveClient`
  asks who is attached to the pane's session, ignoring kido's own
  control-mode connections (one per real client). Control mode is read
  from its boolean, not an empty tty (a read-only client has one too).
- **`Conn.Run` kills and re-dials on any timeout**; one slow command
  costs a full reconnect.
- **`shell/zsh/integration.zsh` must not name a local `status`** — a zsh
  special parameter; shadowing it silently stops the precmd hook. It is
  called `ret`.
- **`kido hook` must never fail the caller.** Errors print to stderr and
  return, never exit nonzero.
- **`ReporterPID(viaShell)` walks up to three ancestors past wrapping
  shells.** Claude Code runs `sh -c "kido hook"`, and Linux dash does not
  `exec` the final command.
- **A tmux command reaching a further parser has no surviving escape.**
  The generated `server.conf` (tmux -> sh) and a `new-window` window name
  (tmux -> sh -> tmux) go through `tmuxConfUnsafe` (`cmd/kido/launch.go`),
  which refuses `'`, `"`, `$`, `#`, `\`, a backtick, a newline or a
  carriage return. A space is quoted.
- **`KIDO_HOOK_DEBUG` is the only switch for the hook's debug log**, set
  in the environment of the pane Claude Code starts in; no kido flag can
  reach `kido hook`. It logs `hook.Events()`; other events must be
  registered by hand in the user's settings.json (`--settings` merges).

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
  tests need only pass. Then run `go vet ./...` and the tests of the
  packages you changed (an e2e test you wrote with
  `KIDO_E2E_REQUIRED=1 KIDO_TMUX=$(command -v kido-tmux) go test ./e2e/
  -run Name`, or the fork under `build/tmux-fork/` once `make e2e` built
  it; `scripts/test-ts.sh` if you touched `pi/`), each once, with the
  environment scrubbed:

      env -u KIDO_AGENT_PARENT_SESSION -u KIDO_AGENT_DEPTH -u KIDO_AGENT_TASK_FILE -u KIDO_AGENT_PARENT_PID -u KIDO_AGENT_RUN_ID -u TMUX_PANE go test ./internal/ui/

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
tmux server before releasing — unit tests do not run tmux, and e2e skips
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
  after its first remote command: `observeRemote` reads
  `LastPromptTime > CommandStartTime` strictly. Accepting the tie is not
  the fix — a local prompt and an ssh launched from it share a second
  just as readily, and every non-integrated remote would then hold the
  row green for the life of the connection.

The subagent system's design limits (a child moved to another session, a
blocked ask holding a whole turn, a child that exits before its window is
kept, a child that crashes before `notify_parent`) are under "Known
limits" in docs/design.md and "Limits" in docs/design-subagents.md.
