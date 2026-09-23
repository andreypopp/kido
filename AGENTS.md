# Developing kido

What kido does and how it is installed is in [README.md](README.md). This
file is the context that is not in the code: the tmux fork it depends on,
what Claude Code actually reports, and the invariants a plausible-looking
change would break.

kido's own design decisions - which store is authoritative for what, the
inbox protocol, addressing, the ask/reply cycle rule, spawning and the
window lifecycle, run outcomes, the heartbeat, and the seam between the
two pi extensions - live in [docs/design.md](docs/design.md), the design
as built. Read it before changing any of that; the code's comments no
longer repeat it.

## Layout

    cmd/kido/          subcommand dispatch (main.go), setup-*, prompt, snapshot, inbox
    internal/ui/       the Bubble Tea model, rendering, shell-status debounce
    internal/tmux/     pane listing and formats (tmux.go), control-mode client (conn.go)
    internal/state/    one JSON file per agent session, keyed by pane
    internal/hook/     Claude Code hook event -> status table
    internal/procs/    process-tree scan: agent panes, ssh destinations
    internal/msg/      the inbox wire protocol: v0 raw prompt, v1 envelope
    internal/tree/     the parent-first walk behind `kido agents` and the sidebar
    internal/reap/     which subagent windows are finished with, and when
    internal/subrun/   the durable record of one `kido spawn`
    internal/testutil/ test scaffolding shared by more than one package
    shell/zsh/         the OSC 133 integration sourced from ~/.zshrc
    tmux/              kido-side.tmux, sourced from ~/.tmux.conf
    pi/                the two pi extensions, embedded and written out by setup-pi
    e2e/               tests driving kido inside a real tmux server

`go build ./cmd/kido`; module name is `kido`, no external build steps.

## The tmux fork

kido only runs under [andreypopp/tmux](https://github.com/andreypopp/tmux),
branch `side-pane` (`tmux -V` prints `next-3.9`). Build one with
`scripts/install-tmux-fork.sh <prefix>`. The fork is
[PR tmux/tmux#5468](https://github.com/tmux/tmux/pull/5468) (side status)
plus a `side-status-command` patch.

Two things kido depends on:

**The side column.** `side-status-command` runs a program in the side
column and gives it `$TMUX_SIDE_CLIENT`. That variable's absence is
exactly "kido was not started as a side column", which is what
`ui.Options.Standalone` means — a popup or a plain pane gets the one-shot
picker (`opts.Standalone` in `main()`). Keyboard focus is the client flag
`side-status-focus`.

**OSC 133.** `input_osc_133()` in the fork's `input.c`:

| sequence | effect |
|---|---|
| `A`, `N` | `wp->last_prompt_time = time(NULL)`, fires `pane-shell-prompt` |
| `C` | sets `PANE_CMDRUNNING`, `cmd_start_time`, **`cmd_status = -1`**, fires `pane-command-started` |
| `D[;status]` | clears `PANE_CMDRUNNING`, sets `cmd_end_time`/`cmd_status`, fires `pane-command-finished` |

Three consequences worth holding on to:

- **These are hooks only.** `control_build_events()` registers no sink for
  them, so a control-mode client is never notified. kido reads the
  `#{pane_command_*}` formats on its poll instead. Do not go looking for a
  `%pane-command-started` notification to subscribe to; there isn't one.
- **The timestamps are whole seconds.** `Pane.ShellStatus()` compares
  `LastPromptTime > CommandStartTime`, and a tie resolves to *running* — a
  false idle the instant a command starts is the worse error.
- **`cmd_status` is cleared on `C`,** so the last command's exit code is
  gone the moment the next one starts. `shellPhase.held`/`heldOK`
  (`internal/ui`) carry it across the following run.

`ShellStatus` also heals a stuck flag: a program that emits `C` without a
matching `D` would leave `PANE_CMDRUNNING` set forever, and the next
prompt's `A` clears it. Two fork changes would each delete one of these
workarounds: clearing `PANE_CMDRUNNING` on `A` would delete the heal rule,
and not clearing `cmd_status` on `C` would delete `held`/`heldOK`.
Arguably upstreamable; not done.

**Why not `pane_current_command`.** It reports the process-group leader
(`tcgetpgrp()`), which confuses an interactive shell with a batch `zsh -c`.
`#{alternate_on}` reports the *innermost* program instead — it sees `less`
under `git` and `nvim` under `sudo` — and is what
`model.interactivePane` uses to decide a program has taken the terminal.

## Format-string invariants (`internal/tmux/tmux.go`)

`paneFormat` is `\x1f`-joined and parsed positionally by `parsePanes`.
Three rules:

- `#{pane_title}` stays **last**; it may contain anything.
- `pane_command_duration` is deliberately **absent**: it ticks every
  second and would defeat snapshot change-detection, redrawing the sidebar
  once a second forever.
- Adding a field means updating the `SplitN` count and the `len(f)` guard
  in `parsePanes` together.

`pane_command_status` prints **empty**, not `0`, when unset — hence the
separate `CommandStatusOK` bool. `TestParsePanesEmptyCommandStatus` pins
it.

## What Claude Code actually reports

`internal/hook/hook.go` is the event table. The behaviours below were
measured over ~10k logged events (`kido setup-claude --debug`, then
`tail -f "$(kido debug-log)"`), not read from documentation:

- **`SubagentStop` fires on every subagent turn** — 546 times in one
  session. Its firing means nothing; only its `background_tasks` do.
- **A subagent's tool calls arrive under the parent `session_id`** with
  `agent_id` set (1567 of 2509 `PreToolUse` in one session). That is why
  `working()` only clears the background flag when `AgentID == ""`:
  treating a subagent's calls as the main loop waking would clear the flag
  immediately and strand the session at running.
- **`idle_prompt` fires ~60s after *every* `Stop`,** background work or
  not, and carries no `background_tasks`. Without the `in.Background`
  guard it turns a session doing background work idle a minute in. This
  was a real bug.
- **`TaskCompleted` never appeared.** It is in `allEvents` (so `--debug`
  logs it if it ever shows up) but nothing fires it, which is why a
  session held open by a background *shell* alone can never return to
  idle. Known gap.

Claude Code also reports nothing when a question is dismissed or a
permission denied. kido reads the pane's screen instead
(`internal/ui/screen.go`, fixtures captured from real Claude Code
screens). That probe runs for `AgentClaude` only, enforced by an
early-`continue`, not by a type.

## Agent state, and delivering a prompt

State lives in `$KIDO_STATE_DIR`, else `$XDG_STATE_HOME/kido`, else
`~/.local/state/kido` — one JSON file per agent session, named by session
id, written temp-file-then-rename. There is **no locking**; races are
resolved by policy instead:

- `Load()` removes a file whose recorded pid is dead, rather than skipping
  it. That is what cleans up the per-turn headless Claude Code sessions pi
  spawns.
- When two records claim one pane, the **outer** agent wins regardless of
  timestamp (`outer()`, `beats()`): pi runs Claude Code inside its own
  pane, and the inner one's hooks would otherwise fight pi's reports.
  `outer()` treats anything not literally `"claude"` as outer, so two
  non-Claude agents in one pane would flip-flop — an unenforced
  precondition with no test.

`kido prompt` prefers the recorded inbox socket (pi's extension binds one)
and falls back to a tmux paste **only** on `errInboxUnavailable`. Any
other socket error returns immediately without a fallback: the message may
already have been delivered, and re-sending would double-send.

`SendPrompt` pastes rather than types. `send-keys -l` writes raw bytes, and
an application with bracketed paste on reads a bare newline as submit — so
a multi-line prompt arrived as one input per line. `load-buffer` +
`paste-buffer -p` brackets the text when the application asked for it and
degrades to a raw paste when it did not, so panes that already worked keep
working. Enter is a **separate** `send-keys` after a delay; sending it with
the paste cuts the paste mid-line.

Exit codes: `0` sent, `1` empty stdin or an error, `4` no agent in scope,
`5` several. Scope is the caller's window, widening to the session only
when the window had none — which is why `5` can never be resolved by
widening.

## Installed-file lookup (`cmd/kido/setup.go`)

Shipped files live at `<prefix>/share/kido/...` beside `<prefix>/bin/kido`
— Homebrew's `pkgshare` layout, which `make install` mirrors so one
lookup works for both.

`findShared` tries the **unresolved** path first and resolves only as a
fallback, and `invokedPath(os.Args[0])` is used instead of
`os.Executable()`. Both matter, and both were bugs:

- Homebrew's `<prefix>/bin/kido` and `<prefix>/share/kido` are symlinks it
  repoints on every upgrade. The unresolved spelling stays valid; the
  resolved one names a Cellar version directory that the next
  `brew cleanup` deletes — leaving a `.zshrc` pointing at nothing.
- On Linux `os.Executable()` reads `/proc/self/exe` and *always* resolves,
  so it defeats the ordering above on exactly the platform where nobody
  tests it.

`setup-zsh` and `setup-tmux` share `blockSpec`/`installBlock`: both write
a marked block that sources the shipped file **only if it exists**. A
second run leaves the block alone; a block pointing elsewhere is rewritten
in place.

## Tests

    make test    go vet ./... and the unit tests (cmd/..., internal/...)
    make e2e     go test ./e2e/ -count=1 -v
    make install binary to $BIN (default ~/.local/bin), shared files to $BIN/../share/kido

`make e2e` needs the fork on `PATH` or at `KIDO_TMUX=/path/to/tmux` and
**skips** without it; `KIDO_E2E_REQUIRED=1` fails instead, which is what
CI uses so a broken fork build cannot pass as a skip. The harness
(`e2e/harness_test.go`) nests two tmux servers — an outer one hosting a
pty, the inner one under test with kido as its `side-status-command` — and
reads the sidebar back with `capture-pane`. It builds fake `claude` and
`node` binaries that reproduce the real agents' screens. `settle = 5s` is
the only timeout; every wait helper polls at 100ms, matching kido's
default tick.

CI runs both suites on Ubuntu and macOS for every push to `main` and every
PR, building the fork from the live `side-pane` SHA (cached by that SHA,
with `cache/restore` + `cache/save` split so a failing job still saves the
build it paid for).

### Tests that exist to pin something a cleanup would delete

- **`TestShellDebounceRedraws`** — `Update` computes `pending :=
  m.shellPending()` *before* `m.at`/`m.snap`/`track()` are updated. With
  the gate removed, or read after the tick, every assertion about
  `shellIndicator` still passes and the row freezes on screen, because
  `rebuild` is never called. Debounce deadlines are driven by kido's own
  clock, so a tick where tmux reports nothing new must still redraw.
- **`TestInteractiveLeavesNoHold`** — quitting nvim used to flash the row
  green for ~300ms. Negative control included.
- **`TestShellOutcome`** — two cases keyed to exact tmux/zsh quirks: the
  cleared `cmd_status`, and a first prompt that emits `D` with no `C`
  before it (which would checkmark every freshly opened pane).
- **`TestPromptMultiLine`** (e2e) — asserts **ordering**, not presence:
  both lines run either way once Enter fires, so only "the second line
  reached the prompt before the first one's output" distinguishes a paste
  from typed keys.
- **`TestParseGuardLookalike`** — command output resembling a control-mode
  guard line must not be read as `%end`.
- **`TestLoadAgentPrecedence`** — pi wins over Claude Code for the same
  pane regardless of timestamp, since pi runs Claude Code inside its own
  pane.

### Other traps

- **Indicator styles must render on call, never at package init.** A
  lipgloss style fixes its colour profile on its first render, and
  `ui.Run()` sets the profile *after* package init (tmux passes `CI` into
  the side-status job, which termenv would otherwise read as "no TTY" and
  strip). A package-level `var x = style.Render("▌")` comes out unstyled,
  and no test catches it.
- **`samePanes`/`drawnPart` compare by exclusion.** A new `tmux.Pane`
  field participates in equality by default and must be zeroed in
  `drawnPart` to be ignored. It fails toward extra redraws, which is the
  safe direction — the opposite convention to most such comparators.
- **`field()` is the column-alignment contract.** Every pane-label branch
  routes through it; a new pane kind that forgets it misaligns the whole
  column. A shell with no OSC 133 integration deliberately gets *no*
  field at all — the missing offset is the tell that kido knows nothing
  about that pane.
- **`Conn.Run` kills and re-dials on any timeout**, on the theory that a
  missed reply means the stream is out of step. One slow command costs a
  full reconnect.
- **`shell/zsh/integration.zsh` must not name a local `status`** — it is a
  zsh special parameter, a synonym for `$?`, and shadowing it stops the
  precmd hook dead with no error. It is called `ret`.
- **`kido hook` must never fail the caller.** Claude Code runs it as a
  hook; errors print to stderr and return, they never exit nonzero.
- **`ReporterPID(viaShell)` walks up to three ancestors past wrapping
  shells.** Claude Code runs the hook via `sh -c "kido hook"`, and dash on
  Linux does not `exec` the final command — so the immediate parent is a
  short-lived `sh`, not the agent.
- **The `setup-tmux` block nests three parsers** (tmux -> sh -> tmux again
  for `source-file`), and no escape survives all three. `tmuxConfBlock`
  therefore refuses a path containing a quote, a double quote, `$`, `#`, a
  backslash, a backtick, or a newline (`tmuxConfUnsafe`) rather than trying
  to quote it.
- **`setup-pi` leaves a symlink alone** so a dev can point that name at a
  checkout; only a real file is backed up and replaced.

## Releasing

The repo carries **no version and no tags, deliberately**. Versioning
lives in `andreypopp/homebrew-tap`: formulas `kido` and `tmux`, each
pinned by a git `revision:` with a hand-bumped `version`. A release is

1. land on `main` here (CI green),
2. bump `revision:` and `version` in the tap formula, push the tap,
3. `brew upgrade`.

Do not add a tag. Note that `brew audit`/`brew style` vendor gems into
the Homebrew checkout itself, which can leave it dirty.

Verify a change against a real tmux server before releasing — the unit
tests do not run tmux, and the e2e suite skips silently without the fork.

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

- A background shell has no completion event (see above), so a session
  held open by one alone never returns to idle.
- An interactive `ssh` pane is suppressed wholesale, so a remote shell
  that *has* the integration installed reports nothing. Gating the
  suppression on `LastPromptTime > CommandStartTime` — a prompt marker
  arriving after the ssh launch came from the far side — would fix it.
