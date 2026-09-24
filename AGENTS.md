# Developing kido

What kido does and how it is installed is in [README.md](README.md). This
file is the context that is not in the code: the tmux fork it depends on,
what Claude Code actually reports, and the invariants a plausible-looking
change would break.

kido's own design decisions - which store is authoritative for what, the
inbox protocol, addressing, the ask/reply cycle rule, spawning and the
window lifecycle, run outcomes, the heartbeat, and the seam between the
two pi extensions - live in [docs/design.md](docs/design.md), the design
as built, with the subagent side of it in
[docs/design-subagents.md](docs/design-subagents.md). Read them before
changing any of that; the code's comments no longer repeat it, and
neither does this file.

## Code commenting guidelines

A comment earns its place by saying something the code cannot. Most do
not, and the honest fix is to delete rather than reword: narration that
restates the line below it, banners labelling a section the reader can
already see, and commented-out code that version control is already
keeping.

What to keep, each for a reason narration does not have:

- An external constraint this project cannot change - a platform
  behaviour, a vendor's protocol, a dependency's quirk - once it has
  been verified. The tmux and Claude Code notes in this file exist for
  exactly that reason.
- A link to the issue or discussion behind a constraint the code has no
  way to express.
- Legal notices, and doc comments stating a public contract.
- A workaround's explanation, for as long as the workaround is there.
  When the constraint goes the workaround goes with it; deleting the
  explanation alone leaves code nobody will dare touch.

Some comments are not comments. Build, compiler and formatter
directives are instructions wearing comment syntax, and that syntax
does not make them safe to remove. A diagnostic suppression needs its
rule read before it is judged: one covering a false positive or a
style-only rule stays, and one hiding a correctness or safety failure
calls for fixing the cause rather than finding a quieter way to spell
the same silence.

Treat a loud comment as a claim to check, not a verdict to obey or to
discard. `IMPORTANT`, `do not remove`, `too risky`, `fine for now` and
a long justification all show that somebody was worried, not that they
were right. A claimed external constraint needs evidence it still holds
on a live path; where that evidence is missing, keep the comment and
say what is missing. Do not invent a defect, and do not call deliberate
behaviour a bug.

Removing comments never licenses changing behaviour. The two are
separate changes and a diff that mixes them hides both.

A comment explaining *why* can outlive its reason, and a stale
explanation is worse than none because it is trusted. This repo has
already carried a measured claim about which client tmux names inside a
popup, true when written and false once kido had its own control
client; a test comment pointing at machinery that had since been
deleted; and a refusal describing itself as mirroring a rule that had
changed underneath it. When a mechanism changes, grep for the prose
that described it.

Design rationale belongs in [docs/design.md](docs/design.md) and
[docs/design-subagents.md](docs/design-subagents.md), not beside the
code. A comment re-explaining a decision is a second copy of it, and
the copy is the one that drifts.

## Layout

    cmd/kido/          subcommand dispatch (main.go), the launcher
                       (launch.go, shell.go, prime.go, bindir.go), prompt,
                       message_agent (also ask_agent and notify_parent),
                       set_status, list_agents, spawn_subagent,
                       async_bash and its async-run wrapper,
                       steer/stop/interrupt_subagent, reap, runs,
                       snapshot, inbox
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
    shell/zsh/         the OSC 133 integration every primed shell sources
    tmux/              kido-tmux.conf, the defaults the launcher writes into server.conf
    shims/             the bin directory's sh shims (tmux, ssh, pi, claude) and shim.sh
    claude/            settings.json, the hooks file the claude shim hands to Claude Code
    scripts/           install-share.sh, the one description of share/kido; the fork build
    third_party/tmux   the tmux fork, a git submodule built as kido-tmux
    pi/                the two pi extensions, which the pi shim loads with --extension
    e2e/               tests driving kido inside a real tmux server

`go build ./cmd/kido`; module name is `kido`, no external build steps.

Every subagent tool in `pi/` invokes the subcommand of its own name, and
the table in [docs/design-subagents.md](docs/design-subagents.md) is that
mapping. A new tool brings a subcommand spelled the same way; a
subcommand nobody's tool calls is named however it reads best. These are
strings handed to a subprocess, so a divergence is a silent runtime
failure rather than a build one - and there are no aliases to fall back
on, deliberately. `async_bash` is spelled with the tool's underscore
before the tool exists, because renaming a command once something calls
it is the harder half of that rule; its wrapper, `async-run`, is nobody's
tool and is spelled as it reads.

## The tmux fork

kido only runs under [andreypopp/tmux](https://github.com/andreypopp/tmux),
vendored as the git submodule `third_party/tmux` and pinned there (`tmux -V`
prints `next-3.9`). `scripts/install-tmux-fork.sh <prefix>` builds the
submodule into `<prefix>/bin/kido-tmux`, and `--print-revision` reads the
pin with `git ls-files -s`, which answers from the index and so works when
the submodule is not checked out or the pin is only staged. The fork is
[PR tmux/tmux#5468](https://github.com/tmux/tmux/pull/5468) (side status)
plus a `side-status-command` patch and the OSC 133 command-line capture.

kido finds its tmux binary in this order: `$KIDO_TMUX`, then a `kido-tmux`
beside its own executable (the unresolved invoked path first, for the
same Homebrew-symlink reason as `findShared`), then `tmux` on PATH. The
e2e harness gives its freshly built kido that sibling, so the suite runs
the resolution users get.

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
| `C` | sets `PANE_CMDRUNNING`, `cmd_start_time`, **`cmd_status = -1`**, stores the `cmdline=` parameter as `#{pane_command_line}`, fires `pane-command-started` |
| `D[;status]` | clears `PANE_CMDRUNNING`, sets `cmd_end_time`/`cmd_status`, fires `pane-command-finished` |

`#{pane_command_line}` is newer than the rest of the table and not in
every build of the fork. A tmux without it expands the name to the empty
string - not an error, and not the literal text - so the field costs an
unpatched tmux nothing but a blank value, which is also what a shell that
reports no command line looks like. That is the probe an e2e test asserting
on it gates itself with (`TestSSHRowShowsRemoteCommandLine`), and it is why
no row may require the value to draw.

tmux stores the value through `clean_name()`: control bytes are dropped and
`#(` is rewritten to `_(`, so a command line can carry neither the `\x1f`
the pane format is joined with nor a format substitution. `shell/zsh`
therefore sends the command line **verbatim** apart from stripping control
characters; anything it escaped would be escaped a second time there and
reach the sidebar unreadable (kitty's `%q` convention works only because
kitty decodes it again).

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
- Adding a field means bumping `paneFields`, the one constant the
  `SplitN` count and the `len(f)` guard in `parsePanes` both read.
  `TestPaneFormatFieldCountMatchesConstant` pins the two together, and
  `TestPaneFormatFixtureFromFormat` exists because `TestParsePanes` alone
  would not: its fixture is hand-typed, so a new field left out of it
  keeps every parse test green while real output loses a field into
  `pane_title`.

`pane_command_status` prints **empty**, not `0`, when unset — hence the
separate `CommandStatusOK` bool. `TestParsePanesEmptyCommandStatus` pins
it.

## What Claude Code actually reports

`internal/hook/hook.go` is the event table. The behaviours below were
measured over ~10k logged events (every event registered, and
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
- **`TaskCompleted` never appeared.** It is in `allEvents`, so it is a
  name to register by hand if it ever shows up, but nothing fires it,
  which is why a
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
  non-Claude records on one pane fall through to the timestamp and the
  winner flips — which happens: a headless `pi --print` inherits
  `TMUX_PANE` from the pane it was launched in.
  `TestLoadTwoOuterRecordsOnOnePaneFlipByTimestamp` records the flip as
  known and accepted rather than fixing it: an agent's own record
  legitimately changes on its pane and must win when it does, and nothing
  in the comparison can tell that from an intruder. What used to make the
  flip destructive — the reaper closing a parent's children the tick its
  record vanished — is gone because the reaper is no longer handed this
  map: `Load` is `LoadLive` plus `ByPane`, and anything asking "is this
  instance running *anywhere*" takes the slice, which drops nothing.
  Pass a pane-keyed view to `reap.Sweep` and you reintroduce the bug that
  killed two live agents.

`kido prompt` prefers the recorded inbox socket (`kido-status.ts` binds one)
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

## Installed-file lookup (`cmd/kido/shared.go`)

Shipped files live at `<prefix>/share/kido/...` beside `<prefix>/bin/kido`
— Homebrew's `pkgshare` layout, which `make install` mirrors so one
lookup works for both.

`findShared` tries the **unresolved** path first and resolves only as a
fallback, and `invokedPath(os.Args[0])` is used instead of
`os.Executable()`. Both matter, and both were bugs:

- Homebrew's `<prefix>/bin/kido` and `<prefix>/share/kido` are symlinks it
  repoints on every upgrade. The unresolved spelling stays valid; the
  resolved one names a Cellar version directory that the next
  `brew cleanup` deletes — leaving the server's `side-status-command`,
  and every pane's PATH, pointing at nothing.
- On Linux `os.Executable()` reads `/proc/self/exe` and *always* resolves,
  so it defeats the ordering above on exactly the platform where nobody
  tests it.

## Tests

    make test    go vet ./..., the unit tests (cmd/..., internal/...),
                 and scripts/test-ts.sh: one node suite for both pi extensions
    make e2e     go test ./e2e/ -count=1 -v
    make install binary to $BIN (default ~/.local/bin), shared files to $BIN/../share/kido

A failure that passed here and failed on GitHub's slower, contended
runners reproduces in `scripts/ci-like.sh`: a Linux container with the
repo bind-mounted, CPU and memory capped, and the tmux fork built in at
the revision the tap pins (`make ci-like ARGS="go test ./cmd/kido/ -run
TestFoo"`). A bare CPU quota throttles the whole container in lockstep
and rarely reproduces a timing failure by itself; `--contend N` starts N
independent busy sibling containers, real multi-tenant contention, and
paired with a low `--cpu-shares` it desyncs a wrapper's timer from the
command it times, the way a loaded runner does. The host's own cores are
never saturated to chase a runner failure: work here runs in parallel,
and one agent spinning every core stalls all the others while, measured,
still failing to reproduce.

Validation is `make test` then `make e2e`, both in full; `go test -run` on
one test or `go test` on one package is for chasing a specific failure
while you work, not a substitute for running either target whole.

`make e2e` needs the fork on `PATH` or at `KIDO_TMUX=/path/to/tmux` and
**skips** without it; `KIDO_E2E_REQUIRED=1` fails instead, which is what
CI uses so a broken fork build cannot pass as a skip. The TypeScript suite
has the same shape — it skips without a node new enough to run `.ts`
unflagged, and `KIDO_TS_TEST_REQUIRED=1` fails instead, which CI sets
for the same reason, having pinned a node rather than trusting whatever
the runner ships. The
harness (`e2e/harness_test.go`) nests two tmux servers — an outer one
hosting a pty, the inner one under test with kido as its
`side-status-command` — and reads the sidebar back with `capture-pane`.
The inner server's own PATH starts with the built kido's directory and
the fork (`serverPathPrefix`), the way `serverEnv` primes a real launch:
`kido-tmux.conf` names a bare `kido` and a bare `tmux` in bindings that
`run-shell` resolves against the server's PATH, not a pane's. A machine
with kido installed masks a missing entry, and runs the installed binary
instead of the built one; CI, with neither, got exit 127.
`cleanEnv` strips `KIDO_AGENT_*` along with `KIDO_TMUX`, because the
suite is routinely run from inside a tracked agent's pane: everything the
harness starts inherits that agent's parent edge, the inner tmux server
included, and the server's environment is what `new-window` gives a
spawned child - so a test asking whether a `--no-parent` child has a
parent edge would be answered by the developer's own.
It builds fake `claude` and `node` binaries that reproduce the real
agents' screens. `settle = 5s` is the only wait; every wait helper polls
at 100ms, matching kido's default tick. Every grace period kido reads
(the linger, stop escalation, the stall threshold)
is shortened through the environment the inner server exports, and only
there: the sweep in the sidebar and the helper the extension runs read
the same variable, so shortening one in-process would leave the two
halves disagreeing about when a window is finished with. The full list is
under "Knobs" in docs/design.md.

CI runs both suites on Ubuntu and macOS for every push to `main` and every
PR, building the fork from the submodule at the revision it pins -
`scripts/install-tmux-fork.sh --print-revision`, the commit the tap
formula must pin so CI and `brew install` build the same one - cached by that SHA,
with `cache/restore` + `cache/save` split so a failing job still saves the
build it paid for).

### Tests that exist to pin something a cleanup would delete

- **`TestShellDebounceRedraws`** — `Update` computes `pending :=
  m.shellPending()` *before* `m.at`/`m.snap`/`track()` are updated. With
  the gate removed, or read after the tick, every assertion about
  `shellIndicator` still passes and the row freezes on screen, because
  `rebuild` is never called. Debounce deadlines are driven by kido's own
  clock, so a tick where tmux reports nothing new must still redraw.
  `TestStallRedrawsOnAQuietTick` pins the same trap for `stallPending`: a
  wedged agent is exactly a pane about which tmux has nothing new to say.
- **`TestSnapshotSameIgnoresHeartbeatTS`** — a running pi session re-sends
  its unchanged status every heartbeat purely to keep `TS` fresh for
  `state.Stalled`. Without the exclusion in `sameStates` that alone
  rebuilds the sidebar on every agent's heartbeat, the objection above to
  `pane_command_duration` in another form.
- **`TestInteractiveLeavesNoHold`** — quitting nvim used to flash the row
  green for ~300ms. Negative control included.
- **`TestShellOutcome`** — two cases keyed to exact tmux/zsh quirks: the
  cleared `cmd_status`, and a first prompt that emits `D` with no `C`
  before it (which would checkmark every freshly opened pane).
- **`TestPromptMultiLine`** (e2e) — asserts **ordering**, not presence:
  both lines run either way once Enter fires, so only "the second line
  reached the prompt before the first one's output" distinguishes a paste
  from typed keys.
- **`TestAskAgentRefusesACallerWithNoReplyPath`** — the assertion that
  carries the test is the last one: the target's inbox got *nothing*. A
  refusal that returned an error and still delivered would satisfy every
  other assertion, and delivering is the bug itself — a question that
  spent a turn of the target's attention and then could not be answered,
  the asker not even being addressable. Its negative control,
  `TestAskAgentFromAnAgentWithAnInboxStillSends`, is there because a gate
  on the sender could as easily swallow the only caller `ask_agent` was
  ever for. Its e2e twin,
  `TestAskFromAShellRefusesAndLeavesTheTargetUndisturbed`, asserts the
  same thing about the *target* - its inbox got nothing and its pane was
  not typed into - because that is where the claim lives, and run against
  the pre-fix binary it reproduces the original report exactly:
  "delivered to ask-target-e2e by inbox", rc=0, question in the inbox.
  `TestMessageFromAShellReachesTheAgent` and
  `TestSteerFromAShellIsNotHeldToTheDescendantRule` are its positive
  controls, and are not decoration: without them both refusals would pass
  on a kido where *everything* from a shell was broken, which is the one
  failure a negative-only test cannot report.
- **`TestSpawnNoParentIsNotReaped`** — drives a real `reap.Sweep` instead
  of asserting `meta.ParentInstance == ""`: the sweep is the reader whose
  verdict `--no-parent` is claiming, and the field on its own pins
  nothing. Point the record's parent at a name nobody claims and the same
  sweep closes the window, which is what gives it teeth. Its e2e twin is
  the same claim with a live sidebar and `kido reap` over the top, and is
  paired there with `TestSpawnFabricatedParentIsRefusedUpFront`: one flag
  apart, one makes a window the sweep declines to touch and the other
  makes no window at all. Without the pair the exemption reads as
  incidental — on the pre-fix binary the second test is what prints
  `windows = "bash\norphan-e2e"`, the orphan itself.
- **`TestSpawnResumeCarriesToolsOntoThePiCommandLine`** (e2e) reads
  `#{pane_start_command}` rather than a child's own report, because the
  allowlist is only spelled out when the command is literally `pi`, and
  tmux's record of the argv it was handed is a better witness than kido's
  belief about what it passed. It is the one test given a PATH of its own
  (`startPathPrefix`), holding a fake `pi` and nothing else: pi is not
  installed in CI, the pane would exit before the second tmux call sets
  `remain-on-exit`, and the window would be gone. That prefix went on
  every pane's PATH once, which put a fake `node` that never exits ahead
  of the real one - enough for a login shell sourcing nvm to hang at
  startup and take twenty-two tests with it, all of them ones that type
  into a shell. A fake on a shared PATH shadows that name for every
  startup file too, not only for the command you meant. Its sibling,
  `TestSpawnResumeCarriesKeepAlive`, does have a live child and reads the
  environment from it; neither names the flag it asserts on the resume
  command line, which is the whole point — it can only come from the run.
- **`TestEveryToolHasASubcommandOfItsName`** and its TypeScript twin —
  one list, `pi/testdata/tools.json`, checked from both sides: pi's suite
  asserts the registered tools are exactly those names, this one asserts
  each is in `subcommands`. Either half alone is decoration. Delete the
  TypeScript half and a tool added with no subcommand passes, which is
  the drift the pair exists to catch and the exact confusion that
  produced the rule; delete the Go half and the fixture pins nothing but
  itself. Same shape, and same reason, as
  `internal/msg/testdata/discriminator.json`.
- **`pi/kido-status.test.ts`, the four ask_agent release cases** — each
  asserts the call *settles promptly* against a `timeoutMs` of ten
  minutes, because the defect was never a wrong message: it was that no
  resolution arrived at all, and every one of them passes trivially if
  the assertion is narrowed to what the text says. The abort case is the
  only one the liveness poll does not carry (its target is alive
  throughout), and its last assertion is the one with teeth — a reply
  naming that id is delivered as a message, which is how the pending
  entry is shown to be gone rather than merely unawaited. Its sibling
  aborts while the send is still in flight, the one ordering where the
  wait ends before the liveness watch is armed, and what it asserts is
  that the readings *stop*: an interval started after its own settle is
  one nothing will ever clear, and it is invisible to every assertion
  about the returned text. The last is
  the negative control the others are unsafe without: a live target
  that is merely slow is still waited for, through many liveness
  readings and an abort signal that never fires, and the answer that
  arrives is its own. A fix that gave up on a slow healthy target would
  be worse than the hang, and only that case can report it. The reading
  count is polled for, not sampled after one fixed sleep: a sleep sized
  for three 50ms-interval readings came up short on a loaded CI runner,
  since each reading is a real subprocess round trip and not a timer
  tick. `makeFixture`'s `restore()` retries its `rmSync` past `ENOTEMPTY`
  for the same reason on the other side of the same race - a liveness or
  send poll's subprocess can still be writing its log line into the
  fixture's directory after a test's own assertions are done with it.
- **`TestSSHWithoutRemoteIntegrationStaysQuiet`** — the negative control
  the ssh gate is only safe with. `observeRemote` latches, so a wrong
  reading is permanent for that session, and the row it produces is a
  green one that never ends: the test therefore holds a non-integrated
  far side still for ten ticks rather than checking it once.
  `TestSSHRemoteShellReports` is its positive half, and
  `TestSSHRemoteLatchDropped` pins that the latch is a reading of one ssh
  session and not of the pane.
- **`TestParseGuardLookalike`** — command output resembling a control-mode
  guard line must not be read as `%end`.
- **`TestLoadAgentPrecedence`** — pi wins over Claude Code for the same
  pane regardless of timestamp, since pi runs Claude Code inside its own
  pane.
- **`TestSweepSurvivesAPaneCollisionOnTheParent`** — the orphan rule
  closes a window, which kills the process in it, and what it reads must
  therefore be complete rather than merely checked. The test builds the
  collision in real state files and sweeps *both* views: the full one
  closes nothing, and the pane-keyed one closes the window. That second
  assertion is the point — it is the input that killed two live agents,
  and without it the test stops being about anything.
  `TestSidebarSurvivesAParentPaneCollision` (e2e) is the same incident
  end to end, and fails within a second if `take` goes back to handing
  the sweep `s.states`.
- **`TestReapCancelsSubagentOfDeadParent`** (e2e) — the orphan rule from
  a one-shot `kido reap`, which it could not apply while a debounce made
  the rule need two sweeps. It hides the sidebar first: with one reading
  deciding, a sidebar left running would close the window itself and the
  test would pass without the command doing anything.
- **`TestLingeringSubagentsCarryForward`** — the previous tick's entry is
  reused, so the test deletes `meta.json` between the two calls: an
  implementation that re-reads loses the name. The second half pins the
  deliberate exception, an entry with no outcome yet, which must keep
  asking.
- **`TestStalledSinceTakesTheBaselineItIsGiven`** — `StalledSince` must
  read nothing, so the test records a wake and checks the verdict ignores
  it. Reaching for the file inside would put an open in the 100ms path
  and let `stallPending`'s two instants be judged from two baselines.
- **`TestBuildAgentsRecycledPIDNoEdge`** — the parent edge in `kido
  list_agents` matches on `ParentInstance`, not `ParentPID`, because
  `alive()` reports `EPERM` as alive and cannot tell a recycled pid from the
  parent. Nothing in the reaper consults a pid any more either, which is
  what removed the matching known limit.
- **`TestLeakCheckCatchesAccumulation`** (e2e) — the harness's control-
  client leak check asks the test's own server for its clients, after a
  version that scanned the whole machine failed on whatever else was
  running. Its companion, `TestLeakCheckIgnoresUnrelatedServer`, pins the
  scoping; this one proves the check can still fail at all. The older
  assertion — kill the server, wait for the clients to exit — could not,
  because the server's death closes their pipes regardless.
- **`pi/kido-status.test.ts`, the parent-liveness poll** — the pair of
  cases pinning that one `kido agent-alive` reading is conclusive and
  that ticks do not pile up. The first counts calls, not elapsed time:
  an assertion that the child merely exits would pass with a debounce
  back in place. The second measures a fixed window rather than waiting
  for a call count, because `setInterval` fires whether or not the last
  callback finished, and stopping at the first few readings stops before
  an unguarded pile-up is distinguishable from a handful of sequential
  calls. The `set_status` test in the same file reads the report it means
  rather than the last one to arrive, for a related reason: a session
  emits its own report at start, and nothing orders the two.
- **`pi/kido-status.test.ts`, the startup-idle pair** — a child whose pi
  never reaches a first turn, and its negative control. The positive
  half's assertion with teeth is the `--text`, not the `failed`: a fix
  that armed the clock and left the outcome alone records `completed`
  for a child that did nothing, and a parent reading "completed" acts on
  work that never happened. The control holds a child whose turn started
  for six idle windows and asserts **zero** shutdowns, which is what
  stops the clock being armed from session start instead - that version
  passes the positive half and kills a resumed run, and a slow first
  turn, thirty seconds in. There is no e2e twin: every part of this
  ending is the extension's, and a fake pi would pin the fake.
- **`pi/kido-status.test.ts`, the heartbeat stopping** — counts *every*
  report, not the `running` ones, and that is the whole test. `send()`
  sets `current` before it calls `stopHeartbeat()`, so a heartbeat that
  failed to stop goes on re-sending **`idle`** — and its heartbeat flag
  bypasses the coalescing that would otherwise drop an unchanged report.
  A count filtered to `running` therefore cannot move however broken the
  stop is: the test this replaced passed against a `stopHeartbeat` edited
  to return immediately. Narrowing the count back to the status the test
  is named after is the one change that silently empties it. It also
  polls for a value that stays put rather than sampling twice a fixed
  distance apart, because a spawn already in flight when the session went
  idle lands whenever it lands, and on a loaded runner that is after the
  first window closes — which is how the old test failed on CI while
  passing everywhere else.
- **`TestAsyncRunReportsBeforeItExits`** — the whole argument for a
  wrapper over reading the dead pane, in one assertion: the outcome and
  the notice are on disk by the time the call returns, so the window is
  free to lose the `remain-on-exit` race. Its e2e twin,
  `TestAsyncBashThatExitsInstantlyStillNotifiesOnce`, runs the command
  that actually loses it (`true`) and logs which windows survived rather
  than asserting on them — the race is tmux's to win or lose, and
  asserting either way would pin the wrong thing. Run against a
  `#{pane_dead_status}` implementation both fail, which is what gives
  them teeth.
- **`TestSpawnMarkFailureOnAVanishedWindowIsNotAFailure`** — the negative
  control that makes `TestSpawnMarkFailureKillsTheWindowAndRecordsFailure`
  a rule about *mark failures* rather than about everything that can go
  wrong after `new-window`. It asserts two absences — no window killed,
  no outcome written — because a command that beat remain-on-exit has
  neither a window to kill nor a story anyone else may tell. Collapse the
  two cases back into one and `kido async_bash -- true` answers "tmux
  set-window-option -t @1 remain-on-exit on: exit status 1" over an
  outcome its own wrapper had already recorded truthfully.
- **`TestAsyncRunLeavesAnOutcomeItDidNotWin`** — what it asserts is
  silence, so the second half of the same function is the test: the same
  wrapper, the same unresolvable parent, an outcome race it wins, and the
  send path complaining out loud. Without it every assertion passes
  against a wrapper that never notifies at all. Its e2e siblings watch an
  inbox over a *span* for the same reason `stays` does — one notice and
  the first of two are identical at any instant, and so are "nothing yet"
  and "nothing ever" (`TestAsyncBashStillRunningSaysNothing`,
  `TestAsyncBashWithNoParentStillRecordsItsOutcome`).
- **`TestSweepSaysNothingForABashRunItsWrapperReported`** and
  **`TestReapSaysNothingForARunItsWrapperReported`** — the negative
  controls that carry "exactly one notice per run". The window in each is
  indistinguishable from the one its positive half sweeps: dead, marked,
  past the linger. Only the outcome already on disk tells them apart, and
  reading it is the whole mechanism — so a sweep that notified
  unconditionally passes every assertion the positive halves make, and
  the duplicate notice it sends is the bug itself, a parent told twice
  about one build and acting twice. `TestSweepNotifiesOnceUnderTwoObservers`
  pins the same claim against the input that actually produces it: two
  readings of one window with nothing else differing, which is a sidebar
  per client plus whatever `kido reap` an operator types.
- **`TestSweepNotifiesOnlyForBashRuns`** — design.md's deliberate cost,
  which this feature would otherwise revert in passing: a subagent that
  crashes without calling `notify_parent` tells its parent nothing,
  because an agent's completion is a judgement only the model can make.
  A bash run's completion is an exit code. The test asserts the agent
  run keeps the `died` it always got, not merely that no notice was
  sent, since a fix that spoke for everything would otherwise only be
  half caught.
- **`TestStopBashRunLeavesTheWrapperToReportIfItCan`** — why the stop
  signals before it speaks. A wrapper that is still there reports with
  the exit status and the output tail a stop can only guess at, and
  having asked for the stop is no licence to tell a second story about
  it. Its positive half,
  `TestStopBashRunReportsWhenTheWrapperCannot`, uses a pid belonging to
  nothing — the SIGKILLed-wrapper case — because that is the one where
  the grace must be skipped rather than waited out.
  `TestStopBashRunStillNeedsForce` asserts three absences (nothing
  killed, no outcome, nothing sent): a refusal that returned an error
  and still stopped the run satisfies the first assertion alone, and
  relaxing that gate is a separate change to a refusal.
- **`TestKilledWrapperIsReportedByWhoeverFindsIt`** (e2e) — deliberately
  does *not* hide the sidebar, unlike its neighbours in `reap_test.go`:
  the session's own sweep and the `kido reap` typed over it are two real
  observers racing for one ending, which is the arbitration end to end
  rather than a claim about one command. It finds the wrapper by the run
  id on its command line rather than by reading `meta.json`, because the
  file is kido's belief and the process list is what is running.
- **The streaming pair in `pi/kido-status.test.ts`,
  `TestStreamBatchRidesAToolTurn`** — the second half is the test. A
  receiver that flushes on *every* `turn_end` passes the first half
  (N chunks in one tool-bearing turn, one `sendMessage`) and
  reintroduces exactly the seizure coalescing exists to avoid: a flush
  after a tool-less turn buys a turn, that turn has no tool calls
  either, more output lands while it runs, and it repeats until the
  command ends. So the negative half holds the same chunks after a turn
  with `toolResults: []` and asserts **zero** sends until the idle timer
  fires. The `toolResults` guard is one `if`, and it is the first thing
  a cleanup would read as redundant.
- **`TestStreamBackoffDoubles`** — two halves for one claim, because
  neither alone is honest. The schedule is a pure function
  (`nextStreamFlushDelay`) and is checked with no clock at all; what a
  clock could only measure badly is then a *count of flushes over a
  fixed window*, never an elapsed-time assertion. Feeding output right
  through that window is load-bearing: a schedule only re-arms when
  there is something held, so a test that stops feeding stops measuring
  the schedule.
- **`TestWrapperDoesNotBlockOnADeadParent`** — two parents that cannot
  take the output, and only one of them can fail the test. A socket with
  nothing listening fails a send instantly, so no amount of blocking
  shows; the stalled listener (`testutil.StartInbox(t, "")`, which reads
  and never answers) costs a sender the whole wire deadline, and that is
  the half with teeth. What it measures is the **command's** own
  duration, read off the output file's last write rather than the
  wrapper's return, because the wrapper's ending legitimately waits out
  a stalled send or two and would drown the signal. What that duration
  is compared against is **measured in the test**, not written down: the
  same command through the same wrapper with no parent configured, the
  one arrangement that cannot block, and the budget is twice that
  baseline. A constant budget measures the machine — the version that
  bounded the command at 1.4s went red on a loaded macOS runner in the
  half that cannot block at all (`the command took 2.93s, want under
  1.4s`), and it stays green only while the machine is quick. The
  stalled wire deadline is scaled to the same baseline and kept half as
  long again as the budget, because a send made from the copy path
  blocks *while* the command runs and so costs one deadline rather than
  a deadline on top of the run; at two thirds it fails by 14ms, which is
  no margin at all. Run against a wrapper that sends from the copy path
  it prints `the command took 3.122547222s, want under 2.074312648s
  (1.037156324s with no parent at all, and a 3.111468972s wire deadline
  to block on)`. Its second assertion, the notice's `N lines not
  streamed`, is readable only because a stalled inbox still records what
  arrived.
- **`TestCompletionNoticeFollowsTheFinalChunk`** — the batch interval is
  set *longer than the whole run* on purpose, and the command's last
  line has no newline: both make the only chunk there is come from the
  close, which is the one the ordering rule is about. With an ordinary
  interval the sender has already drained everything by the time the
  command exits, and a wrapper that notified before closing its stream
  passes.
- **`TestStreamCoalescesAndStripsAnsi`** — the lines are written slowly,
  one every 30ms. Written in a burst they arrive in one `Write` and are
  coalesced by the pipe alone, so a wrapper sending one envelope per
  line passes; measured, that version of the test stayed green and the
  e2e twin reported `50 lines arrived as 50 envelopes`. The batch window
  is set far wider than that spacing (2s against 30ms) and the envelope
  count is judged against the number of windows the run **actually
  spanned**, `elapsed/batch + 2`, for the converse reason: a fixed count
  measures how far a loaded machine stretched the gaps, which is how
  this went red on macOS with `20 lines arrived as 15 envelopes`. Under
  the same load the per-line wrapper still fails it, `20 envelopes over
  3.419727792s, want at most 3`.
- **`TestStreamNeverPastes`** — the same shape, and the same load-
  bearing assertion, as `TestAskAgentRefusesACallerWithNoReplyPath`: the
  pane was not typed into. A build's output tail typed into whatever
  shell reclaimed a dead parent's pane is every line of it run as a
  command.
- **`TestAsyncNoticeTailIsValidUTF8`** — the cut is at a byte offset, and
  the send path refuses a message that is not valid UTF-8 outright. A
  log ending mid-character is an ordinary build log, and without the
  rune-boundary trim it costs the run the one notice it gets. Reads as a
  tidiness check; is not one.
- **`TestRenderLiveMarkedPaneWithNoRecordShowsRunning`** and its negative
  control **`TestRenderDeadMarkedPaneWithNoRecordStaysTombstone`** — a
  marked pane with no state record used to render as finished for its
  whole life regardless of `p.Dead`, which is wrong for any process that
  never writes a record (a plain bash run) and briefly wrong for every
  agent run (the window between `new-window` and its first report). The
  label keys on `p.Dead` now, not on record-absence alone; the negative
  control is what stops a fix that renders every such pane as running
  from passing the positive case too.
- **`TestChildrenAliveReadsTheRunRecords`** — the live-child reading that
  holds a parent open is kido's, not the extension's: `kido children-alive`
  reads the run records, the durable half, because a child outlives the
  turn that spawned it and a `/reload` forgets memory. A dead pid with no
  outcome counts as ended, in the direction that lets a parent go idle
  rather than one that holds it open on a corpse forever.
- **`TestSweepSaysNothingForAnAgentRunThatReported`** and
  **`TestRunOutcomeWithoutUnreportedSaysNothing`** — what makes "exactly one
  notice per ending" a rule rather than "notify always": each is the
  positive case's window with only the outcome on disk, or only the flag,
  different. Without them a sweep or a shutdown that always notified would
  pass every other test and the parent would hear each ending twice.
- **`interleaving: an inbound ask from the same target is refused even while the outbound send to it is still in flight`** (TS) — once waited a fixed 120ms for the agents lookup subprocess, and a slow macOS runner outlived the guess. It now awaits the instant the cycle edge is registered, through `setAskEdgeListener`, with the lookup deliberately slowed to 400ms so a return to a wall-clock guess fails at once.
- **`TestBareIsTheLauncher`** — two halves: a bare `kido` is the
  launcher and refuses under `TMUX`, and a bare `kido` with
  `TMUX_SIDE_CLIENT` set is still the side column, because that is how
  the fork starts it. Drop the second half and the sidebar itself is
  refused on its first tick. Client inference is now reachable only with
  a flag, which is what moved in `e2e/client_infer_test.go`.
- **`TestServerConfLayersInOrder`** — asserts positions, not presence:
  the user's `kido.conf` after kido's defaults and before the two options
  kido owns. Every line present in the wrong order passes a presence
  check, and the wrong order is the bug (a user losing the side column,
  or kido losing to the user's `default-command` without capturing it).
- **`TestKidoInsideAKidoPaneRefuses`** (e2e) — the assertion with teeth
  is the server's client count unchanged over a span, the same shape as
  the ask refusal: a refusal that printed the message and attached anyway
  passes everything else.
- **`TestFirstPaneShellIsPrimed`** (e2e) — a pane in a fresh HOME with no
  rc file reports a prompt. Verified with teeth: with `default-command`
  emptied from the generated config it fails.
  `TestKidoConfDefaultCommandIsCaptured` is its sibling and checks the
  pane really runs the user's command, not merely that the option was
  copied.
- **`reportedPrompt`** (e2e harness) — `#{pane_last_prompt_time}` on a
  pane that never reported one is the *empty string*, not `0`: tmux
  formats an unset timestamp as empty (measured on the fork). A check
  against `"0"` alone held for every pane there has ever been.
- **`TestKidoPaneRunsTheShims`** (e2e) — on macOS its last assertion is
  the control that makes the rest mean anything: a nested
  `zsh -l -c 'command -v ssh'` in the same pane, with the same inherited
  PATH but no integration after it, finds the system ssh, so path_helper
  really does demote the launcher's PATH on that machine. Without that
  half, a shim first in the pane could be the server's PATH surviving a
  login that rewrote nothing. With `primeLocal(mode, "")` in
  `kido shell` it fails with `command -v ssh = "/usr/bin/ssh"`.
  `TestPrimedZshPutsTheBinDirectoryFirst` is the same claim as a unit
  test, with a `.zprofile` standing in for path_helper; its unprimed run
  is the control and aborts the test if the rewrite demoted nothing.
- **`TestShimsReachTheRealPrograms`** (e2e) — the fakes go on PATH from
  the test HOME's `.zshrc`/`.bash_profile`, not from `startPathPrefix`:
  on macOS path_helper would put `/usr/bin`, and the real ssh, ahead of
  a launcher-level fake directory, and the rc file keeps the fakes out of
  every other test's PATH. `'echo a  b'` is there for its double space,
  which a shim that lost the quotes around `"$@"` collapses.
- **`TestShimFindsTheProgramPastItsOwnDirectory`** — "past a second
  install" is the case that makes "after my directory" rather than
  "anything but me" the rule. The no-real-program case asserts a prompt
  exit 127 under a deadline, because a shim that runs itself never
  returns.
- **`TestPiShimLoadsKidosToolsOnce`** (e2e; skips without pi, so never
  in CI) — real pi, because the collision is pi's behaviour. It needs a
  link to the checkout, whose real path differs from the shipped copies'.
  With the guard removed it prints `Tool "list_agents" conflicts with
  .../share/kido/pi/kido-agents.ts`. Its TS sibling, "a second copy of
  the extensions ..." in `pi/kido-status.test.ts`, has the reload half
  as its control: a guard that refused every second factory call would
  pass the copy half and leave a reloaded session with no tools.
- **`TestOnlyALocalPrimeMovesPATH`** — the seam. The remote bootstrap's
  payloads are the shipped integrations byte for byte
  (`TestSSHBootstrapCarriesTheIntegration`), so asserting those carry no
  `_kido_bin` is what stops a later refactor from routing `kido ssh`
  through `primeFiles` with the local bin directory.
- **`TestShippedClaudeSettingsAreKidosHooks`** — pins
  `claude/settings.json` to `hook.Events()`. The file is JSON and cannot
  carry the "SessionEnd must finish, so it is the one hook that is not
  async" comment, so the test asserts that rule instead.
- **`TestNotifyParentUnderTheCapIsUntouched`** — the negative control the
  report split is unsafe without. Every assertion the over-cap case makes
  is satisfied by a command that splits *every* report, at the cost of a
  file and a path line on each four-sentence notice. The claim is
  delivery byte for byte and no file left behind.
- **`TestNotifyParentHeadIsCutOnARuneBoundary`** — three thousand
  three-byte runes, so wherever the cap falls it falls inside one. The
  send path refuses a message that is not valid UTF-8, so a head cut at
  the byte would cost the parent the whole notice, path line included;
  the head is cut back to the rune the way the tail is cut forward.
- **`TestAgentAliveSurvivesAPaneCollisionOnTheParent`** — the reaper's
  collision test in the second place that asked the same question. Its
  negative control runs `buildAgents` over the per-pane view and asserts
  the child's parent is *unresolved* there; without that half the test
  stops being about anything, exactly as in `internal/reap`.

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
  about that pane. Anything drawn to the *left* of a label has to fit in
  the space already accounted for: the sibling-group glyph replaces that
  row's bracket rather than adding a column, because a first draft added
  one and every label below shifted by two cells.
- **A standalone kido infers its client by counting, and the count is
  wrong without a filter.** `#{client_name}` asked from inside a popup is
  unanswerable — a popup is not a client, and the answer has changed
  between measurements. `tmux.ResolveClient` asks who is attached to the
  pane's session instead, ignoring kido's own control-mode connections:
  there is one per real client, so counting them makes every session look
  ambiguous. Control mode is read from its own boolean, not from an empty
  tty, which a read-only client also has.
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
- **A tmux command that reaches a further parser has no escape that
  survives.** The generated `server.conf` (tmux -> sh) and a window name
  on a `new-window` command line (tmux -> sh -> tmux) both go through
  `tmuxConfUnsafe` (`cmd/kido/launch.go`), which refuses a quote, a double
  quote, `$`, `#`, a backslash, a backtick or a newline rather than trying
  to quote it. A space is quoted, being the case that happens.
- **`KIDO_HOOK_DEBUG` is the only switch for the hook's debug log.**
  Claude Code runs `kido hook` from the settings file kido ships, so no
  flag of kido's can reach it; the environment of the pane Claude Code
  started in can. It logs the events that file registers, which is
  `hook.Events()` — anything else has to be registered by hand in the
  user's own settings.json, which `--settings` merges with.

## Working here as a spawned agent

These apply to every agent kido spawns into this repo, and a brief does
not repeat them.

- **Do the task yourself.** Do not spawn subagents, and do not call
  `ask_agent`; nobody is waiting to be asked. Forwarding a brief down a
  level is not parallelization.
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
- **Verification is yours; it is not re-run.** For a bug fix, write the
  test first and watch it fail before touching the code; quote that
  failure. A feature needs no such proof - its tests need only pass.
  Then, once:

      env -u KIDO_AGENT_PARENT_INSTANCE -u KIDO_AGENT_DEPTH -u KIDO_AGENT_TASK_FILE -u KIDO_AGENT_PARENT_PID -u TMUX_PANE KIDO_TS_TEST_REQUIRED=1 make test
      env -u KIDO_AGENT_PARENT_INSTANCE -u KIDO_AGENT_DEPTH -u KIDO_AGENT_TASK_FILE -u KIDO_AGENT_PARENT_PID -u TMUX_PANE KIDO_E2E_REQUIRED=1 KIDO_TMUX=$HOME/bin/tmux make e2e

  No loops, no second tmux build. Report PASS/FAIL/SKIP as printed; a
  failure in a file you do not own is reported, not fixed.
- **Docs are not per task.** Do not edit `docs/` or this file unless the
  brief assigns them. Put any prose a change deserves in your report.
- **Report through `notify_parent`, under 4000 characters**, leading
  with what was built and the pre-fix failures.

## Releasing

The repo carries **no version and no tags, deliberately**. Versioning
lives in `andreypopp/homebrew-tap`, in the `kido` formula alone: a git
`revision:` with a hand-bumped `version`. The separate `tmux` formula is
retired — kido ships the fork itself, and the formula fetches it as a
resource at the revision this repo pins, which
`scripts/install-tmux-fork.sh --print-revision` prints. A release is

1. land on `main` here (CI green),
2. bump `revision:` and `version` in the `kido` formula — and its tmux
   resource when the submodule pin moved — then push the tap,
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
- An interactive `ssh` pane whose far side reaches its first prompt in
  the same whole second the ssh started in reports nothing until the
  prompt after its first remote command: `observeRemote`
  (`internal/ui`) reads `LastPromptTime > CommandStartTime` strictly,
  and tmux's timestamps have no finer resolution to read. Accepting the
  tie is not the fix — a local prompt and an ssh launched from it share
  a second just as readily, and every non-integrated remote would then
  hold the row green for the life of the connection.

The limits of the subagent system — a child moved to another session, a
blocked ask holding a whole turn, a child that exits before its window
is kept and leaves only its run record — are design limits, listed as
such under "Known limits" in docs/design.md. A child that crashes without
calling `notify_parent` tells its parent nothing, by the same design;
the run record is what is left.
