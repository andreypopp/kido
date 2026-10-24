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

The six tools are in `share/pi/kido-pi.ts`. No tool has a kido
subcommand of its own. A tool that starts, waits for or stops a run
calls a run command. Every other tool reads tmux and the extension's
state directory, and writes to inboxes.

| tool | what it uses |
|---|---|
| `list_runs()` | `kido runs --json --all --parent P`, `agents/<me>/*`, one `tmux list-panes -a` |
| `set_status(activity)` | `tmux set-option -p @kido_activity` |
| `message_agent(to, message, mode?)` | the target's inbox; `kido run-child` to restart an ended child |
| `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?)` | pi's session list, `pi --list-models`, `kido run-child P --name N --cwd D --env ... -- kido-pi ...`, or `kido run` for a top-level agent |
| `stop_run(to, force?)` | the target's inbox, then `kido run-stop` |
| `async_bash(command, name, stream?)` | `kido run-child P --name N -- bash -o pipefail -c ...` |

P is the caller's `KIDO_RUN_ID` for a subagent, else its `$TMUX_PANE`.
For each run that it starts, the parent also runs `kido run-wait ID
--json` in the background ("Endings", below).

A tool checks its own arguments and refuses them with a reason. The
model reads that reason as the tool result.

**Scope.** `message_agent` in `message` mode acts on any agent in this
tmux session. Its `steer` and `interrupt-and-steer` modes and
`stop_run` act only on the caller's descendants, which includes a
grandchild. design.md, "Steer, interrupt and stop", gives the rule and
its reason.

**What steers and what queues.** `message_agent` in `steer` mode and a
child's report steer; `message_agent` in `message` and
`interrupt-and-steer` mode queues. design.md, "Steer and
followUp", gives the rule and the envelope kinds ("v0 and v1").

No tool reports to the parent. The harness sends a child's report
itself, to the parent edge (design.md, "Identity"; "Reporting",
below). Tools register unconditionally. They report kido as
unavailable outside kido.

`set_status` has a bound of 256 bytes, and a report notice a bound of
4000 bytes. The schema does not repeat the bound as `maxLength`.
The tool cuts an activity, because it is a UI label. The harness keeps
a report whole, because it is a work product. Only the text *sent* to
the parent has a bound ("Reporting", below).

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
activity, parent, depth, cwd, model and `canMessage`. Own
runs add `run`, `startedAt`, `state` (`running` or `ended`), the
ending's `outcome`, and a subagent's `task` and `report` from its agent
directory.

The listed status is the pane root's OSC 7501 state: working, blocked,
done, error or idle, else unknown. The name is the pane's `@kido_name`,
or its title when the session has no name. Native Claude Code has no
`@kido_session` and does not appear in the list.

Names still resolve across the entire tmux session for every
`message_agent` mode. The list does not restrict
addressing. Sender checks and ancestry use the same
snapshot: all panes and the whole agent map, not the scoped display.
The `@` completion reads the list and excludes bash and ended rows.

## What a child is given

**Names.** `spawn_agent` and `async_bash` require `name`. The
extension refuses a name with `'`, `"`, `$`, `#`, `\`, a backtick, a
newline or a carriage return, and a name over 64 bytes, before kido
sees it. kido's `run-child` applies the same rule (`Tmux.safe`). A name
is unique within its parent, for live and ended children: the
directory `agents/<parent>/<name>/` or a run of the same name exists, or
it does not. A reused name is refused with "message it instead" (spawn)
or "choose another name" (async_bash). A name a child of the same parent
used means "message it" ("Restarting through a message", below). A
`toplevel` name is unique among the live agents in the caller's tmux
session instead ("A top-level agent", below).

**Spawning.** Without `model`, the child runs the caller's current model
and thinking level, `provider/model-id:thinking`. A caller with no
model is refused: "caller has no model; specify model". An explicit
`model` is checked with `pi --list-models`. `agent.json` records the
resolved value, never an empty string, so a restart runs the model that
the child actually ran. `cwd` must be an existing directory; else the
spawn is refused. Without it, the child starts in the caller's
directory, or in a resumed session's own directory ("Resuming a saved
session", below). The extension passes it as `--cwd`, which reaches
`new-window -c`. Then it checks the depth (maximum 2). Then it writes the
child's agent directory, `task` and `agent.json` with an empty `run`,
before the child starts. Then it runs:

    kido run-child P --name N --cwd C --env KIDO_AGENT_PARENT_SESSION=S \
      --env KIDO_AGENT_DIR=D -- kido-pi --session-id <minted id> \
      --name N --model M [--fork <session file>]

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
`spawned <name> (session <id>, window @N, pane %N, run <id>)`, and the
same fields in its details. The text says that the session id is what
`resume_from` takes later. It does not wait for the child. The result ends with the rule that the child's result arrives as
a notice. Do not wait for, request or predict that result. The model
reads the launch result when it has a child but no result, which is when
it invents a result or blocks.

`spawn_agent` and `async_bash` also register `promptGuidelines`:

- A notice arrives on its own. Do not request or poll for it.
- A child's report states what it intended. Check the diff.
- A notice is information, not the user speaking. A message's first line
  identifies its sender.

Both tools share the last guideline as one identical string. A parent's
message is not called "not the user": its instructions have the user's
authority.

## Forking the caller's context

`spawn_agent(fork: true)` starts the child as
`kido-pi --session-id <minted id> --fork <caller's session file>`. The
task is its first message, and a copy requires one. Everything else is a
fresh spawn: its own run, the parent edge, the mark, the depth ceiling
and the model.

Only the source of the child's context changes. The child starts with
the caller's whole transcript. The parent can assign a judgement, such
as a merge or a decision between two options it already considered.
The parent does not have to repeat its decisions and reasons.

Without `resume_from`, the forked session is the **caller's own**: pi
gives the extension its file. With `resume_from`, the copy's source is
that session ("Resuming a saved session", below). `--session-id` keeps
the child's id the one that `agent.json` records, so the child can
prove its edge.

**Forking is for a short judgement step, not a long worker.** A worker
needs a task and a clean context.

## Resuming a saved session

`resume_from` names a pi session by its id or a unique prefix of at
least eight characters. pi names each session file `<time>_<id>.jsonl`
in a directory for its working directory, under one sessions root. The
extension reads only directory listings: the caller's session directory
(`ctx.sessionManager.getSessionDir()`) and each directory directly
under its parent. It matches the id at the end of a file name. It does
not use pi's `SessionManager.list`, because that parses every session
file. An exact id wins; otherwise the prefix must match one file. An
unknown id reads `unknown session "<id>"`; an ambiguous prefix reads
`"<p>" matches several sessions by id: ...` with up to five ids. The extension then reads the header line of the one match,
where pi records the session's working directory.

**Continue** (`resume_from` alone) starts
`kido-pi --session <session file>` in a new window: the same session id,
with its history. pi takes the working directory of a `--session` from
the header, not from its process. Thus, the agent runs in its recorded
directory: a different `cwd` is refused, and so is a recorded directory
that no longer exists. A session is refused while it is live: a pane that is not
dead holds its `@kido_session`, with or without a pi root ("session <id> is live in a pane"), or it
is one of the caller's own children whose recorded run is live. Two pi
processes must never write one session file. The lookup and the check
run under the restart lock for that session ("Restarting through a
message").

- An ended child of the caller resumes through the restart path of
  `message_agent` ("Restarting through a message"): the same name is
  required.
- The caller itself and its ancestors in the agent map are refused,
  because the map must stay a tree: "session <id> is an ancestor of
  this session".
- Any other session becomes the caller's child: a new agent directory
  under the caller with `session-file`, started by the same restart
  path. After the launch succeeds, the
  extension removes every other parent's `agent.json` for that session.
  Their `task`, `report` and history stay. Thus, the session has one
  parent edge, and the old parent can no longer restart it by name.

**Copy** (`resume_from` with `fork: true`) starts
`kido-pi --session-id <minted id> --fork <session file>`. The original
stays as it was, and a live original is not refused, because pi only
reads it. pi's fork takes the process's working directory, so `cwd`
applies.

**An empty task** (or only whitespace) is allowed only to continue a
session. The session comes back and starts no turn. The extension writes
an empty `task`, `delivered` and no `work`, and a child with an empty `task` and no `work` has reported
("The agent directory"). Thus, it owes no report until its parent
sends it work. Its ending notice reads `subagent "<name>" completed;
no report was owed`.

## A top-level agent

`toplevel: true` starts the agent with no parent edge:

    kido run --name N --cwd C --session <caller's tmux session> -- kido-pi ...

The window is in the caller's tmux session. There is no agent
directory, no `KIDO_AGENT_DIR`, no `run-wait` and no notice to the
caller, and the run meta has no parent, so the orphan rule never
applies. The task goes over the new agent's inbox, as a message from
the caller. The spawn waits up to 5000 ms for the pane to publish
`@kido_session` and its inbox, also for an empty task, and holds the
name claim and the session lock during the wait. Thus, a second spawn
from the same caller sees the agent live. On a timeout, the result
still names the agent and adds `timed out waiting for its inbox; no task
was delivered`. The
agent is a peer: the
caller reaches it with `message_agent` in `message` mode. `stop_run`
and the `steer` and `interrupt-and-steer` modes refuse it, because it is
not a descendant. A top-level caller sees it in `list_runs` as a peer.
A subagent caller does not, because a subagent sees only its parent and
siblings ("list_runs", above); it addresses the agent by the name or
session id in the spawn result.

The depth ceiling does not apply. `fork`, `resume_from`, `model` and
`cwd` apply as for a child. One of the caller's own children cannot
become top-level: "resume this child with its existing name and without
toplevel". Another parent's ended child loses that parent's
`agent.json` after the launch, as above.

## The agent directory

kido's run record (`<server state>/runs/<id>/`) holds what kido knows
about a run: meta, outcome, output, screen (design.md, "Who is
authoritative for what"). The extension's agent directory
(`<kido-pi state>/agents/<parent-session>/<name>/`) holds what only the
harness knows:

- `agent.json`: `session`, `run`, `model`, `fork`. The parent
  writes it at spawn and at each restart. `model` is the resolved
  `provider/model-id:thinking`, never empty.
- `task`: the parent writes it before the child starts. A restart with
  a session file rewrites it to the new first prompt. It is empty only
  for a resume without work.
- `delivered`: the child writes it after it delivers the task. Thus,
  `/reload` does not deliver the task twice. A task that cannot be read
  leaves no marker and stays eligible for the next attempt.
- `session-file`: the child writes its pi session file at
  `session_start`. A restart needs it.
- `report`: the child writes the whole report before it sends it. An
  empty file is an empty report. If it cannot write the file, it sends
  nothing.
- `work`: the parent writes it, empty, before it sends its own child new
  work by `message_agent`, in any mode. It stays
  after a failed send, because the message can have arrived. The child
  writes it again when pi takes its parent's message or steer into the
  transcript (`message_start`), because a report written while the
  message waits in pi's queue covers only the earlier work. The child
  marks each message and steer from its parent with `work: true` in
  the custom message's `details`, and writes `work` when
  `message_start` shows that mark. The message carries the fact, so
  the child keeps no list of pending work: pi keeps queued custom
  messages through Escape, an aborted run and `/reload`, and a list
  in the extension would not. The child never compares the content,
  which pi can change. A notice and a message from another agent are
  not new work. A restart that
  delivers the message as the child's first prompt writes no `work`:
  the restart removes `report` before the child starts, and a later
  `work` could hide a report that the child wrote before the restart
  returned.

A child **has reported** when `report` exists and `work` is absent or
older than `report`, or when `task` is empty and `work` is absent: such
a child was given no work. Both sides read this rule: the parent for its
children, and the child for its own report. A tie counts as not
reported: the child then reports again on its next settle, which is the
safe direction. Thus, an earlier report does not count for later work, and the
earlier report stays readable at its path until the child reports again.
`list_runs` shows the `report` path whenever the file exists.

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
- The last message of a turn that ends with no async run of your own
  running and no subagent of your own still owing a report is your
  report, once for each piece of work from your parent.
  It must stand on its own.
- If you stop to wait for another agent or the user, say so; when the
  work completes later, tell your parent with `message_agent`.

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

**Reporting.** The report is automatic. When a turn of the child
settles idle (`agent_settled` with `ctx.isIdle()`), the harness sends
the last assistant message of that run to the parent as a `notice`
envelope. Its address is the parent edge, not a session from a lookup.
The text is the concatenation of that message's `text` blocks, without
thinking blocks and tool calls. pi's `agent_end` carries only the
run's own messages, from its first prompt to its settle, with every
steer and follow-up that drained into it. pi ends a run with an
assistant message that has no tool call, so that message is the
model's closing text. Claude Code subagents use the same rule. Only the
last message counts, not the last non-empty one, because an earlier
message can be stale narration from the middle of the run.

The settle sends the report only if all of these are true, in this
order:

1. The child has a parent edge. A top-level agent sends nothing.
2. The turn was not aborted, and no accepted interrupt or stop ended
   it. Escape, `message_agent` in `interrupt-and-steer` mode and
   `stop_run` end a turn deliberately, and `stop_run` records `stopped` first. The child
   reads this from `agent_settled`'s `aborted` field, not only from
   the last stop reason: Escape during pi's retry delay after a
   provider error leaves an error as the last stop reason.
3. The turn did not stop on a provider error. Such a turn sends the
   error notice instead (below).
4. The child has not reported on its last work, by the rule above.
   Thus, the report goes once for each piece of work, and only the
   parent's work creates the obligation: the first task, or work that
   the parent marked with `work`. A turn that something else started
   sends nothing after the report: a prompt typed into the child's pane,
   a notice or stream batch from a run of its own, or a sibling's message.
   New `work` from the parent re-arms it. A restart or `/reload` needs
   no memory, because the state is files.
5. The child's run list is readable (`kido runs --json` succeeds and
   prints a list). A failed read is not an empty list: that settle
   sends nothing, and the next settle reads again. A restarted child
   first finishes its read of its live runs, so an early settle cannot
   miss them.
6. The child waits on nothing: no async bash run of its own is live,
   and no subagent of its own is live without a report on its last
   work. A subagent that reported but stays alive does not count. When
   the last such run reports or ends, its notice wakes the child for a
   turn. That turn settles with nothing to wait for, and its last
   message is the report.

**An empty last message is still the report.** The child writes an
empty `report` and sends `subagent "<name>" ended its turn with no
message`, with the guidance. A child with an empty report has
reported: `stop_run` records `completed`. A separate "no report" state
would need memory of what it already sent.

The harness **keeps the report whole**. The notice enters the parent's
next turn, so the text sent to the parent has a 4000-byte bound. The
guidance that ends every report notice - the child stays alive, so end
it with `stop_run` or continue it with `message_agent` - is part of
that bound.

Thus, the child writes the full text as `report` in the agent directory
before it sends. If the write fails, it sends nothing, and the next
settle on the same work tries again: a sent report without its file
would count as no report. A report that does not fit sends its start
plus a final line that names the file:

    full report: <kido-pi state>/agents/<parent>/<name>/report

The report's start, the final line and the guidance together remain
within the cap. A report that fits arrives byte for byte. The harness
removes any partial character from the end of the report's start.

The child finds the parent's pane before it writes and sends, and that
lookup waits on tmux. pi holds back a message that arrives during
`agent_settled` until the handler returns, so no new turn shows the
change. Thus, after the lookup, the child checks again: an accepted
interrupt or stop, or a `work` time different from the one it read,
cancels the report before the write. A cancelled report is not written
and does not count as sent. A failed tmux read is no evidence, so the
child writes nothing and sends nothing, and the next settle on the same
work tries again. If the parent is gone or has no inbox, or the send
fails, the report is written and nothing is sent; `list_runs` and the
ending notice still read the file.

**A child that waits on something kido cannot see**, such as a peer's
message or a file, reports when its turn ends. Its last message says
what it waits for. Its later completion sends nothing, because it has
reported on this work. The standing instruction tells it to tell its
parent with `message_agent` then.

**The error notice.** A turn that stops on a provider error sends the
error and how to retry, once for each failed attempt: a prompt or an
inbound message that starts an agent run begins a new attempt. It
sends nothing for an error ending when the child's run already has an
outcome (`stop_run --force` writes one and sends no request). A
terminated provider can end the turn with an error, not an abort, so
the rule does not rely on the stop reason alone. The error notice
writes no `report` and carries no guidance: a status is not the
child's account of its work. A child that never starts a turn and
never exits sends nothing: only a settled turn is evidence.

**Endings.** The parent learns of every ending, report or not. For each
run that it starts, the parent runs `kido run-wait ID --json` in the
background. When it exits, the parent formats the notice:

    subagent "worker" completed without a report: none of its turns ended in a report, so this is the whole account of it
    detail: no turn ever ran: ...
    run: 6f1c...
    message it to continue it, or stop_run to end it

A child that has reported reads `subagent "worker" completed`, with
no "message it" line. A child with a report older than its last work
reads `subagent "worker" completed without reporting on its last work:
its earlier report is <path>`, with the "message it" line. No notice has a resume line. A parent that
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
`stop_run` records `completed` for a child that has reported, and
`stopped` for one that has not.

**Shutdown.** The child uses one teardown, whether it quits, is stopped
or loses its parent:

1. It closes the inbox.
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

`message_agent` has three modes. `steer` and `interrupt-and-steer`
redirect a descendant's work:

- `steer` leaves the turn running and adds text inside its loop, as a
  `kido-steer` custom message with `deliverAs: "steer"`. The child reads
  it between tool calls and continues with the correction instead of
  restarting. An idle child starts a turn with it.
- `interrupt-and-steer` sends one `interrupt-and-steer` envelope with
  the text. The child marks its turn as ended by a control, waits for
  pi's `abort()` to settle, and then delivers the text as an ordinary
  message from its parent with `followUp`. It answers `ok` only after
  the abort settles and the text is queued. The text starts a new turn.
  An idle child only starts that turn. The aborted turn's settle sends
  no report, no error notice and no idle notice, because the control
  mark holds until the text is delivered as new work.

On arrival, the text identifies its sender. Otherwise, an instruction
arriving during a task would appear to be the child's own idea. Both
modes are new work from the parent ("Reporting", `work`). There is no
interrupt without text: a parent that wants the child idle stops it with
`stop_run`, or steers it to wait.

`stop_run` resolves its target among the caller's own runs and its
descendants, in this order: an exact run or session id, a unique prefix
of at least eight characters, an unambiguous running name. It removes
one leading `@`.

- A bash run: `kido run-stop ID`.
- A subagent: `kido run-outcome ID` records `completed` if the child has
  reported, else `stopped`. Then the stop request goes over its inbox, and
  `kido run-stop ID --wait 5` follows. A healthy
  child ends itself within the wait. kido escalates for one that does
  not (design.md, "Window lifecycle"). `force` skips the request.
  Without an inbox and without `force`, the stop is refused.

These controls reach descendants only ("Scope", above).

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

`message_agent` to an ended subagent restarts it as a
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
  `kido run-child P ... -- kido-pi --session <session-file> --name N --model M`.
  The message is never in pi's argv: pi's parser reads an argument that
  starts with `@` as a file, even after `--`. The extension writes the
  message as `task` and removes `delivered`, and the child delivers it
  at `session_start`, so there is no inbox race.
- Without `session-file`, the restart uses `--session-id <id>` and no
  prompt. The extension removes `delivered`, so the stored task is
  delivered again. The message follows over the inbox, which the
  sender waits for up to 5000 ms.
- A restart removes the old `report` and `work` before the child
  starts. `spawn_agent` with `resume_from` uses the same path for an
  ended child ("Resuming a saved session").
- The extension rewrites `agent.json` with the new run before it
  delivers the message, and starts a new `run-wait`. A second message
  while the new run's inbox is not bound waits for the inbox. It never starts a second run, because the run
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

A bash run is not an agent. `message_agent` refuses it.
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

A shell has no inbox and no session. It cannot message, steer, interrupt or
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
including `failed`, `died` and `stopped`. A stop after the child has reported is
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
- A child that exits before tmux sets `remain-on-exit` loses its window
  and last screen. Only the run record remains, and the parent's notice
  reads `died`.
- A re-watched bash run after a parent restart sends no batches.
- Report state is file times, not work ids. A `work` write in the
  same time as the `report` counts as new work, so the child reports
  again. A clock that moves back can make new work older than an old
  report.
- A report that the child wrote but could not send (parent gone, its
  inbox missing, or the send failed) counts as sent for that work.
- A child that waits on something kido cannot see reports once, when
  its turn ends. Its later completion reaches the parent only if it
  sends a message ("Reporting").
- The agent directory is shared by the runs of one child. If a
  message restarts the child before the parent formats the old run's
  ending, that ending reads the new run's `report` state.
- A `run-wait` that exits without an outcome sends no ending and
  removes the watch, so it no longer holds the report back.
- `/reload` forgets the last turn's error and that the first turn
  never ran. A quit after the reload records `completed` without them.
- A child idle behind an async bash run that never ends, such as a
  watcher, never sends its report while that run lives ("A child's
  life").
- A subagent's window moved to another tmux session is outside its
  parent's scope. The parent cannot reach it.
- The session lock and the name claim are in the caller's process. Two
  different callers that resume one saved session at the same time can
  both pass the live check before either agent publishes
  `@kido_session`, and two pi processes then write one session file.
- A subagent does not see a top-level agent that it started in
  `list_runs`. It addresses it by the name or session id from the spawn
  result.
- Everything assumes one machine: a shared filesystem and a kido binary
  beside every agent.
