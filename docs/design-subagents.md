# Subagents, as built

A subagent is a pi session that another agent starts in a separate tmux
window in the same tmux session. Its first message is a task. kido keeps
its run record after the window closes, and the parent keeps its agent
directory. This document describes a subagent from the tool call that
creates it to the sweep that closes its window.

[design.md](design.md) describes the mechanisms that subagents use:

- The pi extension, kido-pi
- The inbox
- Addressing
- Identity
- The window lifecycle
- Run outcomes

This document refers to those sections by name instead of repeating them.
`AGENTS.md` describes what kido cannot change.

## The tools, and what they call

The ten tools are in `share/pi/kido-pi.ts`. No tool has a kido
subcommand of its own. A tool that starts, waits for or stops a run
calls a run command. Every other tool reads tmux and the extension's
state directory, and writes to inboxes.

| tool | what it uses |
|---|---|
| `list_runs()` | `kido runs --json --all --parent P`, `agents/<me>/*`, one `tmux list-panes -a` |
| `set_status(activity)` | `tmux set-option -p @kido_activity` |
| `message_agent(to, message, replyTo?)` | the target's inbox; `kido run-child` to restart an ended child |
| `ask_agent(to, question, timeoutMs?)` | the target's inbox; `kido run-child` to restart an ended child |
| `spawn_subagent(task, name, model?, tools?, fork?)` | `pi --list-models`, `kido run-child P --name N --env ... -- kido-pi ...` |
| `steer_subagent(to, message)` | the target's inbox |
| `interrupt_subagent(to)` | the target's inbox |
| `stop_run(to, force?)` | the target's inbox, then `kido run-stop` |
| `async_bash(command, name, stream?)` | `kido run-child P --name N -- bash -o pipefail -c ...` |
| `notify_parent(summary)` | the parent's inbox |

P is the caller's `KIDO_RUN_ID` for a subagent, else its `$TMUX_PANE`.
For each run that it starts, the parent also runs `kido run-wait ID
--json` in the background ("Endings", below).

A tool checks its own arguments and refuses them with a reason. The
model reads that reason as the tool result.

**The suffix is the scope.** Each half of a tool's name has a meaning.
The second half gives a rule:

| suffix | who it may act on | tools |
|---|---|---|
| `_agent` | any agent in this tmux session | `message_agent`, `ask_agent` |
| `_subagent` | your own descendants | `spawn_subagent`, `steer_subagent`, `interrupt_subagent` |
| `_run` / `_runs` | run listing and stopping | `list_runs`, `stop_run` |

The scope includes descendants, not only children. Nesting permits two
levels, so the controls can reach a grandchild. The sender walks the
parent chain of the agent map. The receiver checks again in
`senderIsAncestor`.

The `_subagent` rule does not give protection. Trust is uid-scoped, and
the inbox directory is `0700`. Any process that can reach the socket can
write an envelope that claims any identity (design.md, "The inbox"). The
rule gives a consistent vocabulary. A tool's name identifies whose work
it can affect.

**What steers and what queues.** `steer_subagent` and `notify_parent`
steer; `message_agent` and `ask_agent` queue. design.md, "Steer and
followUp", gives the rule and the envelope kinds ("v0 and v1").

`notify_parent` takes no target. Its parent is the parent edge
(design.md, "Identity"). Tools register unconditionally. They report
kido as unavailable outside kido.

`set_status` and `notify_parent` have bounds of 256 and 4000 bytes,
respectively. Their schemas do not repeat the bounds as `maxLength`.
The tool cuts an activity, because it is a UI label. It keeps a report
whole, because it is a work product. Only the text *sent* to the parent
has a bound ("Reporting", below).

**list_runs** is the only tool for finding agents to message and runs to
stop with `stop_run`. A top-level caller sees other top-level agents in
its tmux session as peers. A subagent sees its parent and its live
sibling subagents as peers. It does not see other top-level agents or
its parent's bash runs.

Both callers see their own runs: all running runs and the newest 20
ended runs, newest first. The list excludes the caller itself and
unrelated agents' runs. A live child merges into its pane's row: the row
id is the child's session id, and `run` is its current run id. Children
that `kido run-child %N` started for a top-level pi are listed too.

Rows carry `kind` (`agent`, `subagent`, `bash`) and `relationship`
(`peer`, `parent`, `own`). The agent map decides `subagent` against
`bash`, not kido. Live agents carry id, name, pane, window, status,
activity, parent, depth, cwd, model, `canMessage` and `canReply`. Own
runs add `run`, `startedAt`, `state` (`running` or `ended`), the
ending's `outcome`, and a subagent's `task` and `report` from its agent
directory.

The listed status is the pane root's OSC 7501 state: working, blocked,
done, error or idle, else unknown. The name is the pane's `@kido_name`,
or its title when the session has no name. Native Claude Code has no
`@kido_session` and does not appear in the list. `canReply` also reflects
a subagent's tool allowlist.

Names still resolve across the entire tmux session for messaging,
asking, steering and interrupting. The list does not restrict
addressing. Sender checks, ancestry and `canReply` use the same
snapshot: all panes and the whole agent map, not the scoped display.
The `@` completion reads the list and excludes bash and ended rows.

## What a child is given

**Names.** `spawn_subagent` and `async_bash` require `name`. The
extension refuses a name with `'`, `"`, `$`, `#`, `\`, a backtick, a
newline or a carriage return, and a name over 64 bytes, before kido
sees it. kido's `run-child` applies the same rule (`Tmux.safe`). A name
is unique within its parent, for live and ended children: the
directory `agents/<parent>/<name>/` or a run of the same name exists, or
it does not. A reused name is refused with "message it instead" (spawn)
or "choose another name" (async_bash). A name a child of the same parent
used means "message it" ("Restarting through a message", below).

**Spawning.** `spawn_subagent` checks the model with
`pi --list-models`. It checks the depth (maximum 2). Then it writes the
child's agent directory, `task` and `agent.json` with an empty `run`,
before the child starts. Then it runs:

    kido run-child P --name N --env KIDO_AGENT_PARENT_SESSION=S \
      --env KIDO_AGENT_DIR=D -- kido-pi --session-id <minted id> \
      --name N [--model M] [--fork S] [--tools a,b,notify_parent]

S is the caller's own pi session id. The extension mints the child's
session id. It writes the run id that `run-child` prints into
`agent.json`. A failed spawn removes the directory.

The window's environment is what `run-child` gives every run
(design.md, "Window lifecycle") plus the two `--env` values:

| variable | what it carries |
|---|---|
| `KIDO_RUN_ID` | the child's run id; the child's own runs name it as their parent |
| `KIDO_RUN_OUTPUT` | the run's output path; a pi child writes nothing there |
| `KIDO_AGENT_DIR` | the child's agent directory, which holds its task and its parent edge |
| `KIDO_AGENT_PARENT_SESSION` | the parent's session id, read only by the repo's `no-git-writes` guard |

The environment does not prove identity. Everything that the child's
process starts inherits the environment. Thus, a pi started inside a
subagent's pane receives the complete set. The child trusts the parent
edge only when `agent.json` in `KIDO_AGENT_DIR` names its own pi session
id (design.md, "Identity"). This prevents a nested pi from reporting for
another session and from recording another run's outcome.

**Tools.** A non-empty `tools` list gets `notify_parent` if it lacks
it, and goes to pi as `--tools`. An empty list keeps pi's default
tools. `agent.json` records the list, so a restart uses it again. A
narrow toolset limits possible effects; the depth ceiling does not.

**Depth** is the length of the session's parent chain in the agent map.
No record stores it, and no caller can claim it. The extension refuses a
spawn at depth 3.

The extension refuses a task over 1MB. The task never enters a command line: it
is a file in the agent directory.

The pane receives `remain-on-exit` and `@kido_run` in the `new-window`
command list (design.md, "Window lifecycle"). The sweep, the sidebar
tree and the window-cycling keys use `@kido_run` and the run's meta. The
option lasts as long as the pane. A user's split reads no `@kido_run`,
so the sweep and `run-stop` act on the run's pane only.

The tool immediately returns
`spawned <name> (window @N, pane %N, run <id>)`. It does not wait for the
child. The result ends with the rule that the child's result arrives as
a notice. Do not wait for, request or predict that result. The model
reads the launch result when it has a child but no result, which is when
it invents a result or blocks.

`spawn_subagent` and `async_bash` also register `promptGuidelines`:

- A notice arrives on its own. Do not ask or poll for it.
- A child's report states what it intended. Check the diff.
- A notice is information, not the user speaking. A message's first line
  identifies its sender.

Both tools share the last guideline as one identical string. A parent's
message is not called "not the user": its instructions have the user's
authority.

## Forking the caller's context

`spawn_subagent(fork: true)` starts the child as
`kido-pi --session-id <minted id> --fork <caller's session>`. The task
is its first message. Everything else is a fresh spawn: its own run, the
parent edge, the mark, the depth ceiling, the tool allowlist and the
model.

Only the source of the child's context changes. The child starts with
the caller's whole transcript. The parent can assign a judgement, such
as a merge or a decision between two options it already considered.
The parent does not have to repeat its decisions and reasons.

The forked session is the **caller's own**. pi gives the extension its
id. Nothing resolves a session that the model names. There is exactly
one correct answer, and the model does not supply it. `--session-id`
keeps the child's id the one that `agent.json` records, so the child
can prove its edge.

**Forking is for a short judgement step, not a long worker.** A worker
needs a task and a clean context.

## The agent directory

kido's run record (`<server state>/runs/<id>/`) holds what kido knows
about a run: meta, outcome, output, screen (design.md, "Who is
authoritative for what"). The extension's agent directory
(`<kido-pi state>/agents/<parent-session>/<name>/`) holds what only the
harness knows:

- `agent.json`: `session`, `run`, `model`, `tools`, `fork`. The parent
  writes it at spawn and at each restart.
- `task`: the parent writes it before the child starts.
- `delivered`: the child writes it after it delivers the task. Thus,
  `/reload` does not deliver the task twice. A task that cannot be read
  leaves no marker and stays eligible for the next attempt.
- `session-file`: the child writes its pi session file at
  `session_start`. A restart needs it.
- `report`: `notify_parent` writes the whole report.

For a top-level parent, `<parent-session>` is its own pi session id,
although `run-child` receives its pane. A parent that restarts under its
own session id finds its children again. A forked or new parent session
inherits none.

## A child's life

**Start.** The child's extension binds its inbox before it delivers the
task, so it can receive questions during its first turn. It reads
`task` and delivers it as its first user message.

Every turn's system prompt then contains these standing instructions:

- You were spawned.
- If the work is done or blocked, call `notify_parent`.
- A reply to another agent's question is the whole response.

The system prompt contains the instructions instead of the task because
the task arrives only once. Otherwise, a restart or a follow-up message
from the parent would not include the instructions.

**Watching the parent.** The child's pi is a child of the tmux server.
Thus, no signal tells it that its parent has ended. Every
`KIDO_PARENT_POLL_MS` (five seconds), it reads `@kido_session` and
`#{pane_dead}` of the parent's pane with `list-panes`.
It finds that pane with one `list-panes -a`, and reads the list again
only when the pane no longer matches. A pane that is not dead and has the parent's
`@kido_session` means that the parent is alive, with or without a pi
root, because pi clears its root while it is in the external editor or
suspended. A
failed read is no evidence. When the parent is gone, the child shuts
down through the normal exit path. A slow read holds later ticks back.

**Reporting.** Nothing reports for the child. The child calls
`notify_parent` itself, once, when its model judges the work done.
The summary goes only to the parent as a `notice` envelope. Its address
is the parent edge, not a session from a lookup.

The tool **keeps the report whole**. The notice enters the parent's next
turn, so the text sent to the parent has a 4000-byte bound. The guidance
that ends every report notice - the child stays alive, so end it with
`stop_run` or continue it with `message_agent` - is part of that bound.

Thus, `notify_parent` writes the full text as `report` in the agent
directory. A report that does not fit sends its start plus a final line
that names the file:

    full report: <kido-pi state>/agents/<parent>/<name>/report

The report's start, the final line and the guidance together remain
within the cap. A report that fits arrives byte for byte. The tool
removes any partial character from the end of the report's start. It
refuses a summary that is not valid UTF-8.

A settle is not itself a report. A turn can settle for reasons
unrelated to the task, such as answering a sibling's `ask_agent`;
kido never sends that turn's text to the parent.

**A settled turn with no report sends the parent one notice.** On
`agent_settled` with `ctx.isIdle()`, a child that did not call
`notify_parent` since its last new work tells the parent that it is
idle without a report, and how to continue or end it. It does so only
if it waits on nothing. A child waits while at least one run of its own
is live: a subagent that has not reported, or an async bash run. A
subagent of its own that reported but stays alive does not count, so a
manager that forgot to report is still noticed. A restarted child first
finishes its read of its live runs, so an early settle cannot miss
them. When the last such run
reports or ends, its notice wakes the child for a turn. That turn
settles with nothing to wait for, and the notice goes then. A turn that stops
on a provider error sends the error instead, once per failed attempt,
with how to retry. An aborted turn sends nothing: someone stopped it
deliberately. This also holds for a turn that an accepted interrupt or
stop request ended, and for an error ending when the child's run
already has an outcome (`stop_run --force` writes one and sends no
request). A terminated provider can end the turn with an error, not an
abort, so the rule does not rely on the stop reason alone. These status notices write no `report` and carry no
guidance: a status is not the child's account of its work. New work
clears that memory: a prompt or an inbound message that starts an agent
run. The model's further turns within one run, such as the turn that
reads `notify_parent`'s result, are not new work. A child that never starts a turn and never
exits sends no notice: only a settled turn is evidence.

**Endings.** The parent learns of every ending, report or not. For each
run that it starts, the parent runs `kido run-wait ID --json` in the
background. When it exits, the parent formats the notice:

    subagent "worker" completed without reporting: it never called notify_parent, so this is the whole account of it
    detail: no turn ever ran: ...
    run: 6f1c...
    message it to continue it, or stop_run to end it

A child with a `report` file reads `subagent "worker" completed`, with
no "message it" line. No notice has a resume line. A parent that
restarts under its own session starts one `run-wait` per live child,
once, at its first turn event. Its ended children are not watched.

Without this notice, a parent that assigns work and waits quietly for a
report would wait for a report that never arrives. The notice claims
nothing about the work, only how the run ended.

The parent's UI displays a notice immediately as a dimmed
`│ @<name> notifies: <first line>` line above the editor. Separately, the
notice enters the model's context at the next turn boundary as a
collapsed message that a mouse click expands, or expanded outside
fullscreen mode. A notice steers instead of queuing as a follow-up, so a
parent in a turn sees it between tool calls.

**The parent ends a child.** A child has no idle timer. After it
reports, or after a turn settles with nothing to do, it stays alive.
Only its parent (`stop_run`), the user, or the orphan rule ends it.
`stop_run` records `completed` for a child that reported, and `stopped`
for one that did not.

**Shutdown.** The child uses one teardown, whether it quits, is stopped
or loses its parent:

1. It closes the inbox, and releases every waiting ask.
2. It stops the parent watch and its own `run-wait` processes.
3. It records its run's outcome with `kido run-outcome`: `completed` if
   the session is idle, `failed` otherwise. A session waiting for its
   first turn reports idle but has done nothing. Thus, it records
   `failed` with "no turn ever ran". The detail of a session whose last
   turn failed names that error.
4. It unsets its four pane options.

`/reload` keeps the inbox listening, keeps the pane options and its
`run-wait` watches, and records no outcome, because the run continues
(design.md, "The inbox"). `/new`, `/resume` and `/fork` record nothing either: the
process continues as another session.

**The window, and the pane.** The sweep collects a marked run's pane
after it has been dead for thirty seconds, and captures its screen. If
no outcome exists, it records the pane's ending. A window with the
user's own split keeps that split and loses its mark (design.md,
"Window lifecycle").

## Redirecting one, and ending one from outside

`steer_subagent` leaves the turn running and adds text inside its loop.
The child reads it between tool calls and continues with the correction
instead of restarting. On arrival, the text identifies its sender.
Otherwise, an instruction arriving during a task would appear to be the
child's own idea.

`interrupt_subagent` aborts the target's current turn. It leaves the
target idle with its context intact.

`stop_run` resolves its target among the caller's own runs and its
descendants, in this order: an exact run or session id, a unique prefix
of at least eight characters, an unambiguous running name. It removes
one leading `@`.

- A bash run: `kido run-stop ID`.
- A subagent: `kido run-outcome ID` records `completed` if a `report`
  exists, else `stopped`. Then the stop request goes over its inbox, and
  `kido run-stop ID --wait 5` follows. A healthy
  child ends itself within the wait. kido escalates for one that does
  not (design.md, "Window lifecycle"). `force` skips the request.
  Without an inbox and without `force`, the stop is refused.

All three controls reach descendants only. The sender checks before
sending, and the receiving extension checks on arrival, because the
sender field is advisory (design.md, "Steer, interrupt and stop").

The sweep collects orphans. A marked run pane is an orphan if its run
meta names a parent that has ended (design.md, "Window lifecycle").
Before it closes the run's pane, it records `failed` with "its parent
ended". A one-shot `kido reap` also applies this rule.

A top-level parent is its pane (`%N`): it has ended when its pane is
gone, dead or shows neither a pi root nor `@kido_session`. A subagent
parent is its run. When pi exits, both go, so the next sweep collects
its runs. While pi is in the external editor or suspended, only its
root goes; `/new`, `/resume` and `/fork` change the parent's session id
but keep a pi root on the pane. The sweep keeps the children in these
cases (design.md, "Window lifecycle", rule 2). A subagent's own parent
watch, which reads `@kido_session`, ends it.

## Restarting through a message

`message_agent` or `ask_agent` to an ended subagent restarts it as a
new run under the same session. The rules:

- Only the parent restarts its child. The lookup is
  `agents/<sender>/<name>/`, so another parent's ended child is not
  found. An `async_bash` run is refused: "a background command, not an
  agent".
- A name resolves to a live agent first, then to the newest ended child
  of the sender. After a restart, the old runs of the session are
  history: only the run in `agent.json` takes the name, so they never
  compete with the live child for its address.
- A child restarts once at a time. Discovery, the restart and the
  `agent.json` write run under a lock for that child's session; the
  delivery follows after the lock. Thus, two concurrent messages to an
  ended child start one run: the second sees the first's live run and
  is delivered to it. Another child's restart does not wait.
- PARENT is the sender's current run id or pane, not the one at the
  spawn. A stale parent would make the sweep's orphan rule close the
  child at once.
- With `session-file`, the restart is
  `kido run-child P ... -- kido-pi --session <session-file> --name N [--model M] [--tools ...] <message>`.
  The message is pi's first prompt, in argv, so there is no inbox race.
- Without `session-file`, the restart uses `--session-id <id>` and no
  prompt. The extension removes `delivered`, so the stored task is
  delivered again. The message follows over the inbox, which the
  sender waits for up to 5000 ms.
- An ask never becomes pi's first prompt, because the ask id would be
  lost. The child starts, then receives the ask envelope over its
  inbox. The ask's deadline starts before the restart, so it includes
  pi's start and the wait for the inbox.
- The extension rewrites `agent.json` with the new run before it
  delivers the message, removes the old `report` and starts a new
  `run-wait`. A second message while the new run's inbox is not bound
  waits for the inbox. It never starts a second run, because the run
  in `agent.json` is live.
- A stopped child restarts on a message. Stopped is not finished.

The sweep closes the old dead window like any dead run.

## An async bash run

`async_bash(command, name, stream?)` runs a command in its own detached
window. It tells the caller once the command ends. It is a run with a
command as its child, not a pi session:

    kido run-child P --name N -- bash -o pipefail -c '<command> 2>&1 | tee "$KIDO_RUN_OUTPUT"'

There is no wrapper around the command (design.md, "Window lifecycle").
tmux `execvp`s the argv, so text from the model never reaches tmux's
parser. The depth ceiling does not apply, because a bash run starts no
agents. An agent at the ceiling can still run a build.

The result names the run id and the output file. kido decides where a
run's output is, and `run-child` prints it, so the extension never
derives kido's state directory.

The parent's `run-wait` gives the ending, and the parent formats the
notice:

    async run "build" failed: exit 3
    run: 6f1c...
    output: <server state>/runs/6f1c.../output
    --- last 4000 bytes of output (12034 omitted) ---
    ...

The notice contains the last 4000 bytes of the output file. It uses the
tail, not the start, because failure information comes last. If the
tail starts inside a UTF-8 character, the extension removes that partial
character. The output file is the source of truth; nothing truncates
it.

**Exactly one notice.** The parent's `run-wait` exits once, so the
parent sends one notice for each run. The ending itself has one
recorded write: `Run.record_outcome` links a complete temporary file
with `Unix.link`, and the first write wins. `run-stop`, the sweep and
the child's own `run-outcome` can race; the notice shows whichever won.
A run whose parent is gone has nobody to tell.

A bash run is not an agent. `message_agent` and `ask_agent` refuse it.
`stop_run` reaches it, and the orphan rule collects it. `kido runs`
shows it like any other run.

## Streaming a run's output

With `stream: true`, the parent tails the run's `output` file every
`KIDO_STREAM_POLL_MS` (default 1000) and holds the new lines. It sends
the held lines as one collapsed custom message (`deliverAs: "steer"`,
`triggerTurn: true`) at one of two times:

- While the parent works, at a tool boundary: a `turn_end` that ran
  tools. The batch steers into the running work without costing a
  turn. A long turn without tools holds its lines until it ends.
- While the parent is idle, on the idle schedule: the first held batch
  goes after `KIDO_STREAM_FLUSH_MS` (default 1000). Each batch sent this
  way doubles the delay, up to `KIDO_STREAM_MAX_WAIT_MS` (default
  30000). Each starts a turn, so a long noisy command starts fewer and
  fewer turns. A tool boundary resets the delay. `agent_end` starts the
  schedule for lines held during the work.

Each run has a budget of `KIDO_STREAM_BUDGET_BYTES` (default 256 KiB)
of sent batches. After the budget is spent, one last message reads
`... output budget spent; the rest is only in <path>`, and the run
sends no more batches and stops tailing. The budget is checked before
each batch, so the last batch can pass it by up to one batch. The
ending notice still follows.

A batch keeps a tail of up to 200 lines within a 16KB line budget. It
keeps a single overlong last line, truncated to 16KB. One line above the
tail reads `... N lines omitted (see <path>)`. N counts lines removed by
the cap, lines dropped from the held 5000-line buffer, and a read gap
over 256 KiB. The batch uses the tail, for the same reason as the
notice. The batch's first line names the run.

A partial last line waits for its newline. When the run ends, the
parent reads the rest of the file and sends it before the ending
notice. Thus, the model never reads "this is how it ended" before the
corresponding output.

kido stores no stream flag. A `/reload` keeps the watch and its held
lines. A parent that restarts re-watches a bash run for its ending
only, not for batches. `stream` defaults to off.

## A human at a shell

A human uses kido's own commands, not the tools:

- `kido prompt` sends text to an agent in scope as v0 text, which the
  agent reads as the user's own words (design.md, "Delivery, and when a
  paste is allowed").
- `kido run --name N -- CMD...` starts a parentless run.
  `kido runs`, `kido run-wait`, `kido run-stop` and `kido run-outcome`
  act on any run by id.
- `kido-pi` in a pane starts a top-level agent.

A shell has no inbox and no session. It cannot ask, steer, interrupt or
receive a notice.

## In the sidebar

The sidebar indents a subagent's window under the pane that spawns it,
not after that agent's whole window. The parent window's bracket
continues beside it as a `│` stem. Children of one pane form a group
with `├` and `└` on their first rows. This makes ownership immediately
visible. An only child also receives `└`, not its own dot.

On a subagent's row, child identity is more important than the number of
panes in its window. Grouping already makes the same choice.
A multi-pane subagent window still ends with its own `└` on the row
below, one column further inward. A one-pane window without a parent
keeps its dot. Only an anchored window changes.

The anchor is the parent edge in the run's meta: a run parent, or the
pane of a top-level pi. The edge stays for a live and a finished child
alike. Thus, a finished child remains nested while its window lingers.
The sidebar draws a child as a root if its parent is absent or in
another session.

A lingering window shows its run's outcome in the field column.
A completed run has a dimmed `✓`. Every other outcome has a dimmed `×`,
including `failed`, `died` and `stopped`. A stop after a report is
`completed`: the work finished. A stop before it is not a failure, but
it did not finish the work. A window without an outcome yet keeps the
`×`.

The arriving outcome changes the row from a name to a result.
Showing success a tick early would be the only false claim this column
could make. The dim `✓` is distinct from the bold green `✓` for a live
agent's finished turn. A lingering row has no live agent to earn the
green indicator. This is the TUI's `Kido_sidebar.indicator` for an `Ended`
lifecycle.

These nested windows no longer follow tmux's own order. design.md,
"The sidebar tree", gives the Shift-Up and Shift-Down order.

## Limits

- If the sweep collects a child without a recorded outcome, the parent's
  notice gives how the pane ended, not whether the child finished its
  work. Only the run record and captured screen remain as evidence.
- A child can start shutdown when its parent dies. The sweep can close
  its window during shutdown and record "its parent ended" before the
  child records its own outcome. The first write wins.
- Nesting stops at depth 2 within each parent chain.
- The `ask_agent` tool waits for a reply. kido selects `followUp` to keep
  correlated questions ordered (design.md, "Steer and followUp").
  Expected scheduling is the target's current work plus a reply turn,
  not a round-trip. A correction that cannot wait uses `steer_subagent`.
- A child that exits before tmux sets `remain-on-exit` loses its window
  and last screen. Only the run record remains, and the parent's notice
  reads `died`.
- A re-watched bash run after a parent restart sends no batches.
- A child idle behind an async bash run that never ends, such as a
  watcher, never sends the idle-without-reporting notice while that run
  lives ("A child's life").
- A subagent's window moved to another tmux session is outside its
  parent's scope. The parent cannot reach it.
- Everything assumes one machine: a shared filesystem and a kido binary
  beside every agent.
