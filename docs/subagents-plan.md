# Plan: agent-to-agent messaging and tmux-native subagents

A tmux session is a work stream. Every agent in that session can see the
others, tell them what it is doing, message them, and delegate to a
subagent that gets its own window. kido owns discovery, transport and
window lifecycle; pi's extension exposes the tools.

Status: proposal, revised after review. Nothing here is built yet.

## Why kido rather than an existing package

`pi-intercom` already does peer messaging between pi sessions, and
`pi-subagents` already does delegation. Neither is tmux-native:
pi-intercom routes through a broker process scoped to the pi agent
directory, and pi-subagents runs children either in-process or in a
detached headless runner. Its one "give the child a visible pane" path
goes through [Herdr](https://herdr.dev), a separate commercial pane
manager, via `src/inspectors/herdr/project-panes.ts`.

kido is the tmux-native equivalent of that Herdr seam, and it already owns
most of the substrate:

- `internal/state` is a registry: one JSON file per session keyed by pane,
  with dead-pid records deleted on read.
- `cmd/kido/inbox.go` is a transport: a unix socket per agent, a
  `sun_path` budget, `CloseWrite` framing, an `ok` acknowledgement.
- `kido prompt` already models addressing failure — exit `4` for no agent
  in scope, `5` for several, scope widening from window to session.

## Decisions

| # | Decision |
|---|---|
| 1 | A subagent may not `ask_agent` an ancestor. The parent stays free to orchestrate. |
| 2 | The tmux **session** is the visibility boundary. |
| 3 | `set_status` is free text, separate from `state.Status`. |
| 4 | A finished subagent's window lingers ~30s, then closes. If the parent dies, its subagents are cancelled. |
| 5 | Maximum nesting depth is 2: root `0` → subagent `1` → subagent `2`. A spawn at depth 2 is refused. |

Derived from (1): asks still run parent→child and between peers, so peer
cycles (A asks B while B asks A) remain possible and need their own rule.

## Everything goes through a kido command

Every tool shells out to a `kido` subcommand, including spawn. This is not
just symmetry: `e2e/harness_test.go` builds fake `claude` and `node`
binaries and drives kido through `kido agent-status`. It cannot host a
TypeScript extension. A tool whose behaviour lives only in
`kido-status.ts` is a tool the e2e suite cannot test, which rules out
every window-creation, env-passing and linger case.

## Data model

`state.Session` gains six `omitempty` fields, which read as zero in files
written by an older kido.

```go
// Activity is free text the agent sets ("refactoring internal/ui").
// Unlike Status it is not a closed vocabulary and does not drive colour.
Activity string `json:"activity,omitempty"`

// Instance is an opaque id an agent generates once per process and
// reports on every call (msg.NewID works). It, not the parent's session
// id, is what a child names as its ParentInstance: a session id changes
// under /resume and /reload (kido-status.ts re-runs session_start on
// both), so a child keyed to its parent's old session id would look
// orphaned while the parent is very much alive.
Instance string `json:"instance,omitempty"`

// ParentPID is the pid of the agent that spawned this one, kept for a
// later phase to poll for liveness — it is not how a parent edge is
// matched. ParentInstance, that parent's own Instance, is: an instance
// string cannot be confused with a live process the way a recycled pid
// can, since alive() reports EPERM as alive and would read a pid
// reused by another user's process as a living parent. Zero/empty for
// a root agent.
//
// An earlier draft paired ParentPID with the parent's start time
// instead, on the theory that a start time would guard pid reuse the
// same way. That field was never implementable: nothing in Session
// holds an agent's own start time to compare it against, so it would
// have read as zero in every file kido ever wrote. Instance replaces
// it and is simpler besides — there is no clock to read, and no
// `omitempty` trap: a zero time.Time is not empty to encoding/json,
// so the old field could never actually be omitted either.
ParentPID      int    `json:"parentPid,omitempty"`
ParentInstance string `json:"parentInstance,omitempty"`

// Depth is 0 for a root agent, 1 for its subagent, 2 for that
// subagent's. Spawning at maxDepth is refused.
Depth int `json:"depth,omitempty"`

// Model is the name of the model the agent is currently running.
Model string `json:"model,omitempty"`
```

There is no `Window` field. Window ids are monotonic for the server's
lifetime (verified: kill `@1`, next window is `@2`), so the stated reason
for caching one was wrong — but so is caching it at all, since
`tmux.Pane.WindowID` already arrives with every poll and a pane can be
moved between windows. Resolve the window from the pane, live.

### Carry-forward

`recordSession` (`cmd/kido/main.go:369`) builds a **whole fresh
`state.Session`** from its arguments; `Title` and `Inbox` survive only
because `agentStatus` explicitly reads the previous record and carries
them forward, using `fs.Visit` to distinguish "flag omitted, keep" from
"flag empty, clear" (`main.go:454`). `state.go:84` documents the same trap
for `Background`.

So `Activity` must follow the `--inbox` rule exactly: omitted keeps,
`--activity ""` clears. Without that, the first `running` report after a
`set_status` blanks the activity.

`Instance`, `ParentPID`, `ParentInstance` and `Depth` need **no**
carry-forward: the child knows them from its own generated id and its
environment, and reports them on every status call. That is cheaper than
carry-forward and more robust than walking the `Parent` chain, which
fails as soon as one intermediate record is gone.

`Model` follows the `--inbox`/`Activity` rule: omitted keeps, `--model ""`
clears.

### Coalescing

`kido-status.ts:193` keys coalescing on `[status, title, ended, remove]`.
`Activity` and `Model` must join that key, or a `set_status` or a model
switch that does not change the status is silently dropped.

### Session scoping

`state.Load()` stays pane-keyed and global; scoping to the tmux session is
a view, resolved live on every call:

```go
func SessionOf(pane string) (string, error)   // "%18" -> "$3"
```

Never cached: a pane can be moved between windows and sessions while its
process runs. The pane id is immutable for the process lifetime; its
window and session are not.

## Wire protocol

Today's inbox is "write UTF-8, `CloseWrite`, read `ok\n`" — no sender, no
message id, no reply.

**v1 envelope**, a single JSON object, still terminated by `CloseWrite`:

```json
{
  "v": 1,
  "kind": "message" | "ask" | "reply" | "notice",
  "id": "01J...",
  "from": {"session": "abc123", "name": "worker-2", "pane": "%18"},
  "replyTo": "01J...",
  "text": "..."
}
```

The wire reply stays a bare `ok\n`. For `ask` it means *received*, not
*answered*: the answer returns later as a separate `reply` envelope to the
asker's own inbox, because a model turn takes minutes and the 2s
`inboxTimeout` must not cover it.

**Backward compatible.** A payload that is not a v1 envelope is v0 raw
prompt text, as today. A payload only counts as v1 if it parses as a JSON
object **and** carries both `v` and `kind` — otherwise a user prompt that
happens to be a JSON object would be swallowed as a control message.

**Forward compatible.** The reverse case is the one that bites: a new
`kido message` talking to an unupgraded extension would deliver raw JSON
as the user's prompt. So the receiver advertises what it speaks —
`agent-status --protocol 1` — and a sender that sees no version sends v0
text or refuses, by kind. `kido prompt` stays v0 forever: it is the
agent-agnostic path and must keep working against Claude Code panes.

## Trust

**Trust is uid-scoped, and the `0700` inbox directory already enforces
it** (`inbox.go:77`). The `from` field is advisory.

An earlier draft specified peer-credential verification — read the peer
pid off the socket, map it to a state record, refuse a mismatch. That is
theatre. `state.Record` writes `0644` files into a `0755` directory
(`state.go:222`), so any same-uid process can already write a state record
claiming to be any agent; an attacker simply registers a record for its
own pid and passes the check. It is also unimplementable as described:
macOS `LOCAL_PEERCRED` yields an `xucred` with no pid at all (the pid needs
a separate `LOCAL_PEERPID`), the accepting side is Node's `net`, which
exposes neither, and `golang.org/x/sys` is only an indirect dependency
today.

If the state directory is ever hardened to `0700` with authenticated
records, revisit. Until then a peer check buys nothing and costs a
dependency and a platform-specific spike.

## Delivery semantics

`pi.sendUserMessage(text, { deliverAs: "followUp" })`, as the extension
already does. An externally injected prompt queues behind the work the
user is watching rather than redirecting the running turn the way
`"steer"` would. pi-intercom chooses `steer`; kido's existing comment
argues the other way and wins for a sidebar the user is watching.

One acknowledgement level: `ok` means *the agent has the message and will
see it at its next turn boundary*. pi-intercom models eight receipt states
to support cancel/supersede across a broker; not worth importing.
`message_agent` promises delivery, not action.

## Tools

Tools register **unconditionally** and no-op at call time. They cannot
gate on the environment: pi registers tools at factory time, and
`kido-status.ts:234` deliberately defers resource lookup to `session_start`
because "the factory may run in invocations that never start a session".

### `list_agents()`

Every agent in the current tmux session, including self:

```ts
{ id, name, agent, pane, window, status, activity,
  parent, depth, self, cwd, model, sinceReport, stalled }
```

Sorted parent-first then by spawn time, so the list reads as the tree.
Includes Claude Code sessions, which have no inbox — they are visible but
not messageable, and the shape must say so (`canMessage: false`).

### `set_status(activity)`

Free text, capped at 256 bytes, `""` clears. Reported with
`kido agent-status --activity`.

### `message_agent(to, message, replyTo?)`

Fire-and-forget. `to` resolves by exact name, then exact session id, then
unique id prefix, erroring on ambiguity rather than guessing — matching
`reply-tracker.ts` and `kido prompt`'s exit-5 philosophy.

Against an agent with no inbox (Claude Code), it falls back to a v0 paste,
which is what `kido prompt` already does and the only reason the v0 path
survives.

`replyTo` answers a pending ask; if omitted, the message is sent
unthreaded rather than guessed at, even when exactly one ask from `to` is
pending. Inferring it was considered and dropped: the ask id is already
handed to the model verbatim, with a literal `replyTo=<id>` to copy, so
inference would only ever cover a model that ignored an explicit
instruction - and guessing wrong does not fail safe, it resolves the
*wrong* pending ask on the far side, handing one question's answer to
another. That is worse than the unthreaded send already prescribed for
the ambiguous case, so the single-pending case gets no special treatment
either.

### `ask_agent(to, question, timeoutMs?)`

Blocks the calling tool until the answer arrives. Default 5 minutes.

**Expect one full turn of latency, not a round-trip.** Delivery is
`followUp`, so the question waits for the target's entire current turn,
and the answer requires its model to decide to call `message_agent`. A
child mid-task will routinely take minutes.

Because of that, a timeout is not a failure of the question: a `reply`
arriving after its asker gave up must still surface, delivered as a user
message rather than dropped, or the answer is lost silently.

Refused when `to` is an ancestor (decision 1), is outside the current tmux
session, has no inbox, is not live, or when it would close a cycle.

### `spawn_subagent(task, name?, model?, tools?)`

Creates a window, launches pi, returns the new agent's id immediately.
Refused at `depth >= 2`.

## Cycles

Decision (1) removes parent↔child deadlock; two peers can still block on
each other.

No shared state: each extension keeps its pending asks **in memory**, and
on receiving an ask from X while holding an outstanding ask to X, answers
`refused` on the wire instead of `ok`. An on-disk edge set would survive
`kill -9` on the asker and block every future reverse ask permanently.

From pi-intercom's tests, one detail to keep: a **failed** reply must not
release the edge.

## Spawning

```
kido spawn --parent-pid P --parent-instance I --name NAME --task-file F [--depth N] [-- pi ...]
```

which runs:

```
tmux new-window -d -t <session> -n <name> -c <parent cwd> \
     -e KIDO_AGENT_PARENT_PID=P -e KIDO_AGENT_PARENT_INSTANCE=I \
     -e KIDO_AGENT_DEPTH=<derived> -e KIDO_AGENT_TASK_FILE=F \
     -PF '#{window_id}' -- pi --name <name> [--model M] [--tools ...]
```

`--depth` above is **not** where `<derived>` comes from. `--depth` is a
claim about the caller's own depth, and a caller already at the ceiling
could pass a smaller one and spawn without limit - which would defeat the
ceiling entirely, since it would only ever be as real as the caller chose
to make it. `kido spawn` derives the child's depth itself, as one more
than the depth in the caller's own last-reported `state.Session` record
(found via `$TMUX_PANE`), and refuses when that exceeds `maxDepth`. A
caller with no record at all - a human running `kido spawn` by hand, or an
agent that has not reported yet - is treated as depth 0, the same trust
decision `state.Load` already makes for every other same-uid record (see
Trust, above); it can only make a spawn's ceiling stricter, never looser.
`--depth`, if given, is still accepted (pi's extension sends it, for its
own early refusal - see below) but is never consulted for the child's
actual depth, and an explicit negative value is refused rather than read
as an omission.

- `-e` is required: `new-window` runs the command with the server's and
  session's environment, **not** the caller's, so nothing is inherited.
- `-c` is required for the same reason — without it the child starts in
  the session's default directory, not the parent's. `snapshot.go:55`
  already passes `-c` for this.
- `-d` so the parent's turn is not yanked to the new window.

The task goes in a **file**. It is model-authored text of arbitrary shape,
and `AGENTS.md` already records that a tmux command line "nests three
parsers (tmux -> sh -> tmux again) and no escape survives all three". The
child reads it on start, delivers it as the first user message, and
unlinks it.

The **window name is model-authored too** and goes on that same command
line, so it needs the `tmuxConfUnsafe`-style rejection `tmuxConfBlock`
already applies — reject quotes, `$`, `#`, backslash, backtick, newline
rather than trying to quote them.

`--tools` is the capability ceiling. A child that need not delegate should
not receive `spawn_subagent`. Depth bounds the tree; a narrow toolset
bounds the blast radius.

## Lifecycle

**Completion.** The child reports its final status and sends the parent a
`notice` with a short result. A dead parent yields `errInboxUnavailable`
and the notice is dropped — there is nobody to tell.

**Window linger.** Before exiting, the child spawns a detached
`sh -c 'sleep 30; kido close-window @7'`. Not a bare `tmux kill-window`:
the user may have switched to that window to read it, so the helper skips
a window that is any client's current window. pi-subagents does the same
thing with a `CLEANUP_DELAY_MS` watchdog in `orca-progress-tabs.ts`.

It checks once and does **not** retry, because it does not have to: the
sweep below collects the window on a later pass.

**The sweep.** `internal/reap.Sweep` runs on the sidebar's own poll
(`internal/ui`, every tick) and is what actually closes a subagent's
window in a live session; `kido reap` is the same function by hand. It is
never called from `state.Load()`, which `kido prompt` and the popup picker
also call and which must not become a window killer.

**A sweep identifies a subagent window from tmux, not from kido's
state.** `kido spawn` sets a window option, `@kido_subagent`, and turns on
`remain-on-exit`; a window carrying that option whose panes are all
`#{pane_dead}` is finished, and is closed once it has been dead for the
linger. That is the only design that works:

- **The record is gone before any sweep sees it.** `internal/ui` calls
  `state.Load()` every 100ms and `Load` deletes a dead-pid record as a
  side effect of reading it, so a rule keyed to the record of a dead
  subagent fires essentially never in a session with a sidebar. The
  window option lives in the tmux server and nothing races it away.
- **A pane id is not an identity.** Pane ids restart at `%0` on every new
  tmux server while state files are global and outlive it, so a stale
  record names a pane somebody else holds now. Requiring the window to be
  one kido itself marked is what keeps a sweep from closing an unrelated
  window - demonstrated, before the mark existed, against a plain `sleep`
  shell that was nobody's subagent.

The second rule - cancel a live subagent whose parent is gone - still
needs the record, since nothing in tmux knows who spawned whom, and
carries the same "must be a window we marked" guard.

Neither rule ever closes a window that is a client's current one (the
user is reading it; it is collected on a later pass) or a session's last
window (closing it destroys the session).

**Parent death cancels children.** The child's pi is a child of the tmux
server, not of the parent pi, so no OS parent-death signal applies. The
child polls `KIDO_AGENT_PARENT_PID` every 5s with `kill(pid, 0)` and calls
`ctx.shutdown()` when the parent is gone. `kill(pid, 0)` alone cannot tell
a live parent from an unrelated process that reused its pid; a full check
also confirms that some session in `kido agents` still reports that pid
with `KIDO_AGENT_PARENT_INSTANCE` as its `Instance`.

Cancellation lives in **one named place** — a `kido reap` path — never in
`state.Load()`. `Load()` is called by `kido prompt` and the popup picker,
and neither should become a window killer as a side effect.

## Sidebar

```
  ~/Workspace/kido            running   refactoring internal/ui
    worker-2                  running   writing tests
    scout-1                   idle      done
```

- `field()` is the column-alignment contract; the subagent row is a new
  pane-label branch and must route through it.
- Redraws: `Activity` lives in `state.Session`, which `snapshot.same`
  compares with `maps.Equal` (`ui.go:365`), so any record change already
  redraws. The `drawnPart` exclusion rule applies to `tmux.Pane`, a
  different struct — relevant only if the tree adds a pane field.
- **Switching to a subagent's window is new work.** `tmux.SwitchWindow`
  (`tmux.go:303`) steps to the *adjacent* window in kido's order; it
  cannot target a named one. Selecting the row is the mechanism to build
  on, not `switch-window`.

## kido CLI twins

```
kido agents [--session S] [--json]
kido agent-status --activity TEXT --instance ID --parent-pid P --parent-instance ID --depth N --model NAME --protocol V
kido message <to> [-]            # text on stdin
kido ask <to> [--timeout D] [-]
kido spawn --parent-pid P --parent-instance I --name N --task-file F [--depth N]
kido close-window <id>           # linger helper, skips a focused window
kido reap                        # one sweep by hand; the sidebar's poll
                                 # runs the same one continuously
```

`kido message --from` is deliberately **not** offered: it would let any
caller assert any sender, contradicting the advisory-but-honest `from`.
The sender is whatever the calling process's own record says.

## Testing

Unit:

- `TestInboxV0RawTextStillDelivers` — the compatibility path
- `TestInboxJSONPromptIsNotAnEnvelope` — needs both `v` and `kind`
- `TestAgentStatusCarriesActivityForward` — omitted keeps, empty clears
- `TestResolveTargetAmbiguous` — name/prefix precedence and the error
- `TestAskRefusesAncestor` / `TestAskRefusesCycle` — and that a failed
  reply leaves the edge
- `TestSpawnRefusedAtMaxDepth`, and that a caller at the ceiling cannot
  escape it by passing a smaller `--depth`
- `TestSpawnRejectsUnsafeWindowName`
- `TestParentLivenessSurvivesSessionIdChange` — the `/reload` case

e2e, driving `kido spawn` with the fake `node` binary:

- spawn → child window exists in the same session with the right cwd and
  env, parent gets the notice
- kill the parent → child window goes away
- child finishes → window present at +5s, gone after linger, **with a
  real sidebar polling the same state directory**: the record is deleted
  by that sidebar's own `state.Load` before the window closes, which is
  the case the first design failed
- a sweep leaves an unmarked window alone, and never closes a session's
  last window
- linger skips a window the client is currently in, and that window is
  collected once the client leaves it
- `list_agents` sees both windows of a session and no agent from another

Linger needs a shortened duration; keep it a package variable as
`inboxTimeout` already is.

## Interrupting and stopping a subagent

Two verbs, deliberately distinct, both delivered as new v1 envelope
kinds (`internal/msg.KindInterrupt`, `KindStop`) over the existing inbox -
no protocol version 2: kido runs on one machine with the binary and the
extension upgraded together, so a version gate here would be ceremony.
The risk it would cover - a stale extension showing the model an
envelope's literal JSON - is already covered by the existing v1
advertisement check every non-`message` kind requires (`kido message`'s
`--kind ask/reply/notice` rule, reused as-is), and for `stop` specifically
by its own escalation: a receiver too old to recognise the kind still
leaves the session alive, so the window gets killed regardless.

- **`interrupt`** aborts the subagent's *current turn*. It stays alive
  and idle, ready for a corrected instruction - the common case, where a
  child went the wrong way and the accumulated context is worth keeping.
  pi's extension answers it with `ctx.abort()`.
- **`stop`** ends the session outright. The child shuts down through the
  same teardown phase 6 already built (`session_shutdown`: inbox closed,
  parent notified, record removed, window linger scheduled); its window
  then lingers and is collected by the existing sweep. There is no second
  teardown path.

**Scope.** A caller may only interrupt/stop its own descendants, or
anything at all when the caller is a human at the CLI (one with no
state record of its own - AGENTS.md's Trust section already treats an
unauthenticated same-uid record as a reasonable basis for this kind of
decision). This is not a security boundary; it exists so a confused peer
cannot reach into a part of the tree it does not own. Enforced twice, on
purpose: `cmd/kido/control.go` checks it before ever sending the envelope
(the primary guard, using kido's own view of the spawn tree), and
pi/kido-status.ts checks it again on receipt (defence in depth, using the
receiving session's own `list_agents`), since `from` is advisory and a
session must not act on a message just because it arrived claiming to be
from an ancestor. Both walk the same ancestor chain `ask_agent`'s own
ancestor refusal already walks, in the opposite direction.

**Escalation.** A wedged child will not answer - a real pi has been
observed sitting alive and blocked for hours after a laptop slept and its
provider connection died. So `stop` asks over the inbox and then polls
the target's own state record for up to `stopEscalation` (a package
variable, default 5s, overridable via `KIDO_STOP_ESCALATION_MS` for the
e2e suite the same way `KIDO_LINGER_SECONDS` already is) waiting for it
to go; if it has not, it kills the target's window instead of trusting
that the request was received. Without this, `stop` is only reliable
exactly when it is least needed.

That kill (of the target's own pane, not its window - killing the window
would take every bystander pane sharing it down too) refuses a session's
only pane, for the same reason `kido close-window` refuses a session's
only window: destroying it ends the session and detaches every client
attached to it, which is never what stopping one agent asked for, and
`--force` does not buy it. It does *not* refuse a focused window, and
that difference is deliberate: `close-window` and the reap sweep act on
their own initiative and must not take a screen away from a user who may
be reading it, while a `stop` was asked for by name.

That guard cannot actually fire through `kido stop` today
(`cmd/kido/control.go`'s `killTargetPane`, D7): `controlTarget` refuses a
target outside the caller's own tmux session, and the caller's own pane
is therefore always somewhere in that session, either in the target's
window (so the target is not its window's only pane) or in another
window (so the target's window is not the session's only one). It stays
as defence for a future caller that reaches a target without a live
caller pane in the same session, rather than being deleted just because
nothing exercises it yet.

**No inbox, no `stop` without saying so.** An agent with no inbox at all
(Claude Code, or a pi whose socket bind failed) cannot be asked anything,
so `kido stop` against one degrades straight to killing its pane -
destructive and irreversible, with no chance for the agent to clean up.
This is the opposite of `kido message`'s paste fallback, where degrading
silently was the whole point (there was always a gentler "some other
way"). Here there is not, so it requires an explicit `--force`. The same
degrade, and the same `--force` requirement, applies when an inbox was
reported but has since gone stale (`errInboxUnavailable`): a recorded
socket nobody answers is functionally no inbox at all.

Delivered as `kido stop <agent> [--force]`, `kido interrupt <agent>`, and
`stop_subagent`/`interrupt_subagent` tools in `pi/kido-status.ts`. The CLI
twins are required for the same reason every other tool has one: the e2e
harness cannot host a TypeScript extension, so anything living only in
the extension is untestable.

## Stall detection

An agent can be alive and wedged - the same failure mode `stop`'s
escalation exists for, seen from the other side. kido currently models
only "running" and "gone": a wedged subagent sits in its window reporting
`running` forever, its pane is not dead so the sweep will not touch it,
and `TaskCompleted` never fires (AGENTS.md's note on what Claude Code
actually reports), so there is no completion event to end it either. A
parent blocked in `ask_agent` burns the full five-minute timeout finding
that out.

The signal is `state.Session.TS`, the last report time - but status
reporting is *not* already a heartbeat, which an earlier draft of this
section assumed. `send()` in pi/kido-status.ts coalesces a report away
whenever its key (status/title/activity/model/ended/remove) matches the
last one sent, and `agent_start`, `turn_start`, `tool_execution_start` and
`tool_call` all send the identical `"running"` key - so in a real session
only the first of them ever reaches kido, and `TS` then marks the start of
the current turn, not the time since the agent last did anything. A turn
has no upper bound, so raising the threshold cannot fix this: a healthy
pi minutes into one long turn would still cross it, and worse, a parent
blocked in `ask_agent` reports nothing itself for as long as the call
lasts, so it would mark *itself* stalled before a busy child had any
chance to answer.

So `send()` also runs a real heartbeat: while the reported status is
`"running"`, it re-sends that status every `HEARTBEAT_MS` (~30s),
bypassing the coalescing key entirely, and stops the moment the status
leaves `"running"` - unref'd, like the parent-liveness poll, so it cannot
hold pi's process alive by itself. That makes `TS` a real last-seen
heartbeat again, and `state.Stalled(s, now)` derives "claims running but
has not reported in N minutes" from it the way `ShellStatus` derives a
shell's state from timestamps rather than trusting a flag - never a new
`state.Status` value, since that vocabulary is what an agent reports
about *itself*, and a wedged agent by definition reports nothing.
`state.StallThreshold` (a package variable, default three minutes -
overridable via `KIDO_STALL_THRESHOLD_MS` the same way `stopEscalation`
and `reap.Grace` are, since the e2e suite drives a built binary: six
missed heartbeats is a margin against one or two dropped or delayed
reports, not against turn length, and it still leaves most of
`ask_agent`'s five-minute default timeout for a genuinely busy target to
answer) is never true for anything but `Running` - idle and waiting are
legitimately quiet.

The heartbeat's re-send changes `TS` on every tick with nothing else
about the session changing, so the sidebar's `snapshot.same` (comparing
`state.Session` wholesale via `maps.Equal`) would otherwise force a full
redraw every `HEARTBEAT_MS` per running agent - the same objection
AGENTS.md raises against `pane_command_duration`. `sameStates` fixes this
the way `drawnPart` already does for `tmux.Pane`: it compares sessions
with `TS` zeroed (`drawnSession`), so a TS-only change draws nothing.
`stallPending` (`internal/ui`) is the deliberate exception - it reads `TS`
directly, off kido's own clock, to still catch a session crossing
`state.StallThreshold` on an otherwise quiet tick, so the one thing `TS`
is allowed to drive on screen still does.

`AgentInfo.idleFor` (`kido agents` / `list_agents`) is renamed
`sinceReport`: it was already this derivation's input, and the old name
read as though it meant idle time, which is misleading for a session
reporting `Running`. A new `stalled` field sits beside it, and the
sidebar shows the same derivation as a distinct indicator.

`ask_agent` reads `stalled` off the `list_agents` fetch it already makes
before sending anything, so refusing a stalled target costs nothing extra
and fails fast instead of blocking for the default five-minute timeout
against a target that is never going to answer.

## Phasing

1. **Protocol.** v1 envelope, v0 fallback, version advertisement.
   `kido message` as the exercise. No new tools.
2. **`list_agents` + `set_status`.** New fields, carry-forward,
   coalescing key, session scoping, `kido agents`. Sidebar shows activity.
3. **`message_agent`.** Addressing rules, Claude-pane paste fallback.
4. **`ask_agent`.** Reply correlation, timeout, ancestor rule, in-memory
   cycle refusal, late-reply surfacing.
5. **`spawn_subagent`.** `kido spawn`, env, task file, depth ceiling,
   completion notice.
6. **Lifecycle + tree.** Linger, `kido reap`, indented sidebar,
   select-row-to-switch.
7. **Interrupt, stop, stall detection.** `kido interrupt`/`kido stop`,
   escalation, `state.Stalled`, `ask_agent` fail-fast.
8. **A durable record of a run.** `internal/subrun`, `kido runs`, the run
   id doubling as the child's own pi session id, and outcomes on every
   exit path. See "A durable record of a run" below.

## Open risks

- **A blocked `ask_agent` holds a whole pi turn**, and the latency is one
  turn of the target, not a round-trip. A parent asking three children
  serially is idle a long time. Consider a parallel `ask_many` later.
- **`state.Load()` deletes dead-pid files.** A pending reply addressed to
  a session that died is collected with it. Confirm that is desired and
  not a silently dropped answer.
- **`alive()` reports EPERM as alive** (`state.go:216`). `ParentInstance`
  covers the parent case; anything else relying on `alive()` for identity
  has the same hole.
- **Moving a child's window to another session** with `move-window` puts
  it outside the parent's scope and breaks `ask_agent`. Probably
  acceptable; say so explicitly rather than discovering it.
- **A child that exits instantly loses its window.** `tmux.NewWindow`
  sets `remain-on-exit` in a second tmux call, and the pane can be gone
  first - measured at 20 out of 20 for `/bin/true`, so an unexec'able or
  immediately-failing command is the *normal* case here, not the unlucky
  one. The linger, the reap and the persisted `died` outcome all go with
  it; the run record survives and still reads as `died` from
  `EffectiveOutcome`'s guess. Every fix costs more than the gap - see
  `NewWindow`'s own doc, which lists the three that were considered.
- **A guessed `died` is not stable.** `EffectiveOutcome` asks whether
  `Meta.PID` is alive, and `state.Alive` reports EPERM as alive; pids also
  recycle, which a record that outlives a reboot invites. Both biases push
  the same way - a long-finished run can read as `running` again - and
  neither can invent a `died` for a run that is in fact alive.

## A durable record of a run

Today, when a subagent finishes, almost nothing survives it. The
completion notice to the parent is a short lossy summary; `state.Load()`
deletes the session record the moment its pid dies, so the subagent
vanishes from `list_agents` with no trace; the window closes after its
linger, taking its scrollback with it; and nothing distinguishes
"finished cleanly" from "crashed" - both are simply absence. Meanwhile the
child's own pi session file *does* persist (it runs plain `pi`), but kido
records no pointer to it, so finding it later means guessing by timestamp
and cwd.

**A run directory per spawn**, under `<state>/runs/<run-id>/`, fixes
this - deliberately outside `state.Session`. `state.Load()` deletes a
dead-pid record on purpose (it is what cleans up the per-turn records
pi's Claude bridge writes), and a record that outlives the process is the
entire point here. `Load` already skips directory entries when it scans
the state directory, so `runs/` is invisible to it for free; nothing may
ever depend on that changing; internal/subrun's own package comment says
so for the same reason.

**The run id is the child's own pi session id.** `kido spawn` generates
it and passes `--session-id <run-id>` when the command being launched is
`pi` (checked literally, since the e2e suite's fake commands are not),
which pi's own `--help` documents as "use exact project session ID,
creating it if missing". Restarting a finished run is
`pi --session <run-id>`; forking it is `pi --fork <run-id>` - but pi
sessions are project-scoped, so either only resolves as given from the
run's own cwd. Run from anywhere else, pi asks "Session found in
different project... Fork into current directory? [y/N]" instead of just
working, so `kido runs <run-id>` prints `cd <cwd> && pi --session
<run-id>` (and the `--fork` equivalent) rather than the bare command - the
only way to make the printed line actually copy-pasteable from anywhere,
which is the whole point of printing one. No separate bookkeeping ever
maps the run id to the session id, because there is only one id.
A non-`pi` command (or a non-tmux-local backend, see "Deferred" below)
has no session of its own to tie to it, so kido also sets
`KIDO_AGENT_RUN_ID` in the child's environment unconditionally - the one
case `--session-id` cannot cover.

**Contents.** `meta.json` (parent instance, depth, window, pane, pid,
cwd, model, tools, started-at, the name), `task` (the task text - see
below) and, once the run ends, `outcome`. The directory and the task file
are created *before* `tmux.NewWindow` is called, because the child may
read its task the instant tmux starts it; `meta.json` is written once,
after, since window/pane/pid are only known then
(`internal/subrun.WriteMeta`). If window creation itself fails, the run is
marked `failed` rather than left a silent, never-a-window mystery.

**The task file moves into the run directory**, and stops being deleted.
It used to live in the OS temp directory and be unlinked once delivered,
as the signal that a later `/reload` (which re-runs `session_start`)
should not deliver it again. Keeping the file - so `kido runs <run-id>`
can show it later - meant that signal had to move to a sibling `delivered`
marker file instead: written only once the read has actually succeeded,
so a task that failed to read (bad permissions, a race) is still eligible
on the next `/reload` rather than being marked delivered and never shown
to the model at all.

**Outcomes, recorded on every exit path**, each written by whichever code
is actually positioned to know it happened:

- **`completed` / `failed`** - the child's own verdict about itself,
  written via a new CLI twin, `kido run-outcome --result completed|failed
  <run-id>`, from the same `session_shutdown` handler that already sends
  the parent its completion notice. `completed` if the session ended idle
  (`agent_settled`'s own definition of finished on its own terms);
  `failed` for anything else - waiting, compacting, still running - since
  that is as finely as kido can tell from the outside what actually went
  wrong. `run-outcome` refuses any other `--result`: `died` and `stopped`
  are kido's own verdicts about a run from the outside, not something a
  model-authored process gets to claim about itself, for the same reason
  `kido message --from` is not offered - a caller cannot assert something
  only kido itself is positioned to know. It is a verb of its own rather
  than a flag on the `agent-status` report the child already makes on
  every status change, because any spawned command can end, including one
  that never reported an agent status in its life and has no business
  claiming to.
- **`died`** - written by a sweep (`internal/reap.Sweep`) that closes a
  marked window with no outcome already recorded: the child never got a
  chance to say anything about how it ended (SIGKILL, an OOM kill, a
  crash). The run id travels to the sweep the same way the parent instance
  already does - embedded in the `@kido_subagent` window option kido spawn
  sets (`"run=<id> parent=<instance> depth=<depth>"`) - which is the one
  token of that otherwise-free-text mark that `internal/reap` parses back
  out.
- **`stopped`** - written by `cmd/kido/control.go`'s `stopCmd` as soon as
  the stop request is away, and by `killTargetPane` just after its own
  last-window guard: whether the target goes quietly or has to be
  escalated to a pane kill, `kido stop` is what ended it, and that must
  win the race against the child's own `session_shutdown` reporting
  `completed` a moment later for a reason that was never really its own
  idea. Never a line earlier than that, though: `stop` has several
  refusals (no inbox, or a stale one, without `--force`; a target outside
  the caller's scope; a pane whose loss would take its session with it),
  every one of which leaves the run running - and with `O_EXCL` an outcome
  written before them could never be corrected.
  `TestStopRefusedLeavesNoOutcome` pins it.

All of this rests on **`RecordOutcome` writing once**, with `O_EXCL`: the
first writer to observe how a run ended is definitionally the true story,
and a later, cruder guess (a sweep's `died`) must never clobber it. This
is also why `stopped` is written the moment `kido stop`'s request is away
rather than after the target has answered: it must win that race
deterministically rather than hope it finishes first.

**A run whose outcome is never written is itself informative.** If no
sweep or `kido stop` ever ran against it - no sidebar, nobody typed
`kido reap` - the run directory just sits there with no outcome file,
forever, and that is fine: `kido runs` still has something useful to say
about it. `Meta.PID` (the child's own pid, taken from `tmux.NewWindow`'s
now-three-part `-P -F` output - `#{window_id}:#{pane_id}:#{pane_pid}` -
rather than the process-group leader `pane_current_command` would report,
for the same reason AGENTS.md gives for preferring `#{alternate_on}`)
lets `subrun.EffectiveOutcome` answer without any tmux session at all: no
recorded outcome and a dead pid reads as `died`, a guess that is never
persisted by the read itself - only a sweep, actually closing the run's
window, earns the right to write that down. It is the same conclusion the
sweep persists, reached differently (a dead pid rather than a window of
`remain-on-exit` corpses), and it inherits what pid liveness cannot know -
see "Open risks" above.

**`kido runs [--json] [<run-id>]`** is the CLI twin, listing every run
(id, name, parent, started, duration, outcome, cwd) most recent first, or
showing one in detail: its task text and the exact `pi --session` /
`pi --fork` command to resume or branch from it. Like every other tool
here, it exists because the e2e harness cannot host a TypeScript
extension, so anything living only in `kido-status.ts` would be
untestable.

**`spawn_subagent` returns the run id.** `list_agents` does not change: it
keeps showing only live agents, and a finished run is never merged into
it - `kido runs` is a different question ("what happened") from
`list_agents`'s ("who is here now").

**The task moves from a path to text at the tool boundary.**
`spawn_subagent` used to write the task to a temp file itself and hand
`kido spawn` its path; now it passes the task as text on `kido spawn`'s
stdin (`--task-file -`), and kido is what decides that becomes a file -
exactly the refactor the "Deferred" section below already called for,
done now because Phase 8 needed kido to own the run directory anyway.
`--task-file FILE` still works, for the CLI and the e2e suite.

**No retention.** kido never prunes an old run directory, deliberately -
the same as pi never pruning its own session files. A run record is a
pointer to that session (its window, briefly; its pi session file,
always), not a copy of anything, so deleting the pointer would not free
the space a cleanup would be chasing anyway. `internal/subrun`'s own
package comment says so, so a later change does not "fix" it.

## Fixed: staleness could not see a sleeping machine

Stall detection compares `now - TS` against a threshold, and `TS` is wall
clock. A machine that sleeps advances wall clock without advancing any
agent's work, so on wake every running agent was over the threshold at
once, before any of them had missed a real heartbeat.

The sidebar's `!` is cosmetic and self-corrects, but `ask_agent` refuses
to deliver to a stalled target, and the obvious next move a model makes
on being told a child is stalled is to stop it. So a closed lid could
cascade into killing a healthy subagent tree.

**Detection.** `internal/ui`'s sidebar ticks continuously, so it is the
only thing in kido positioned to notice a gap. `state.DetectPause(prev,
now time.Time) bool` compares two readings taken across one tick: the
wall clock's own account of the interval (`now.Round(0).Sub(prev.Round(0))`,
which strips the monotonic reading first) against the monotonic clock's
account of the same interval (`now.Sub(prev)`, which uses it - see the
`time` package's own doc on monotonic clocks). On both macOS and Linux the
monotonic reading does not advance across a suspend - confirmed against
each runtime's own source rather than assumed: Linux's `nanotime` reads
`CLOCK_MONOTONIC`, Darwin's reads `mach_absolute_time`, and both are
defined not to include suspended time, unlike `CLOCK_BOOTTIME` or
`mach_continuous_time`. A tick that was merely slow for a real, awake
reason - a blocked tmux call, GC, scheduler jitter - advances both
readings together, since the process kept running throughout it; only an
actual suspend leaves the monotonic one behind. The wall account
outrunning the monotonic one by more than `state.PauseSlack` (5s) is what
`DetectPause` calls a sleep.

**Rebasing.** `state.Stalled(s, now)` already compared `now` against
`s.TS`; it now compares against `max(s.TS, wake)`, where `wake` is the
most recent moment `DetectPause` fired. That gives every running agent a
full `StallThreshold` measured from the wake rather than from its
already-stale `TS` - not weaker, just later: an agent that really is
wedged is still caught, one threshold after the machine woke instead of
the instant it did. An agent that reports again after the wake is judged
on its own fresh `TS` again, same as if nothing had ever paused.

**Reaching `ask_agent`.** The wake moment can't live only in the
sidebar's own memory: `ask_agent` shells out to `kido agents --json`, a
fresh process per call, which has no tick of its own and so could never
detect the gap itself. So `DetectPause` firing writes the wake to a small
shared file in the state directory (`state.RecordPause`), and
`state.Stalled` reads it back - which means both the sidebar and every
fresh `kido agents` invocation, including the one `ask_agent` makes, see
the same rebased verdict without pi's extension needing to know anything
about sleep at all.

**What this does not cover.** Detection needs a sidebar actually ticking
at the moment the machine sleeps; a session with no sidebar running has
nothing to notice the gap, and `ask_agent` against it is back to the
original flaw. This is the same shape as every other gap in this
document's Known-open and Open-risks sections: a real limit, written down
rather than silently accepted.

The same flaw applies to anything else that infers health from elapsed
wall clock, and to any watcher that reports a stall through a channel
the same event breaks.

## Deferred: subagents off this machine

Spawning a subagent into a VM or a container, for isolation, is wanted
soon. Nothing here is built for it, and the point of writing it down now
is to record which parts already survive and which two decisions keep the
door open at no cost.

**What survives.** Spawning does: `tmux new-window` is local either way,
and the isolation only changes what the window runs (`docker exec …`,
`ssh host pi …`). So does the whole of the lifecycle above: the
`@kido_subagent` mark and `#{pane_dead}` are facts tmux owns, so a pane
whose `ssh` exits dies and is collected exactly as a local one is. So
does identity, because an instance id is opaque and location-independent
- which is the second reason it beat the parent start time it replaced.

**What does not.** Three assumptions, each in one place: a shared
filesystem (`state.Load` reading a directory, the inbox socket, the task
file's path, `-c`), a shared pid namespace (`kill(parentPid, 0)`), and a
kido binary on the agent's side (status reporting shells out to it).
Unix sockets are the hardest of these: they cannot cross a host boundary
at all, which is why pi-intercom carries a TCP transport beside its own.

**The shift that cannot be dodged.** Discovery and transport invert.
Today an agent writes state into a directory kido reads, and kido dials a
socket on the agent's filesystem; remote means agents report *to* kido
and kido serves a connection - kido gains a broker. That is a real
change and is not worth building speculatively.

**The two things worth doing before then**, because they cost nothing
now:

- Make heartbeat staleness the primary liveness signal and `kill(pid, 0)`
  a local optimisation, not the other way round. "Has not reported in N
  seconds" works across any boundary; a pid check works across none. The
  stall detection this phase adds is already that mechanism.
- Keep the task as content at the tool boundary, not a path. A file is
  the right answer to the local tmux parser problem, but `kido spawn`
  should be what decides it becomes one, so another backend can write it
  inside the sandbox instead.

A container sharing the state directory by bind-mount is much the cheaper
case: same filesystem, sockets intact, and only the pid namespace
differs - which is exactly what the first of those two removes the
dependence on.
