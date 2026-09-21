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
  parent, depth, self, cwd, model, idleFor }
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

`replyTo` answers a pending ask; if omitted and exactly one ask from `to`
is pending it is inferred, and if several are the message is sent
unthreaded rather than guessed at.

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
kido spawn --parent-pid P --depth N --name NAME --task-file F [-- pi ...]
```

which runs:

```
tmux new-window -d -t <session> -n <name> -c <parent cwd> \
     -e KIDO_AGENT_PARENT_PID=P -e KIDO_AGENT_PARENT_INSTANCE=I \
     -e KIDO_AGENT_DEPTH=N -e KIDO_AGENT_TASK_FILE=F \
     -PF '#{window_id}' -- pi --name <name> [--model M] [--tools ...]
```

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
a window that is any client's current window and retries. pi-subagents
does the same thing with a `CLEANUP_DELAY_MS` watchdog in
`orca-progress-tabs.ts`.

This misses the `kill -9` case, where nothing runs the shutdown path. The
backstop is a reaper in kido's poll. Both are needed; neither alone is
sufficient, which is worth stating rather than pretending otherwise.

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
kido spawn --parent-pid P --depth N --name N --task-file F
kido close-window <id>           # linger helper, skips a focused window
kido reap                        # cancel orphaned subagents
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
- `TestSpawnRefusedAtMaxDepth`
- `TestSpawnRejectsUnsafeWindowName`
- `TestParentLivenessSurvivesSessionIdChange` — the `/reload` case

e2e, driving `kido spawn` with the fake `node` binary:

- spawn → child window exists in the same session with the right cwd and
  env, parent gets the notice
- kill the parent → child window goes away
- child finishes → window present at +5s, gone after linger
- linger skips a window the client is currently in
- `list_agents` sees both windows of a session and no agent from another

Linger needs a shortened duration; keep it a package variable as
`inboxTimeout` already is.

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
