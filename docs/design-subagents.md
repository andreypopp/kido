# Subagents, as built

A subagent is a pi session that another agent starts in a separate tmux
window in the same tmux session. Its first message is a task. Its run
record remains after the session ends. This document describes a subagent
from the tool call that creates it to the sweep that closes its window.

[design.md](design.md) describes the mechanisms that subagents use:

- The inbox
- Addressing
- Session identity
- The window lifecycle
- Run outcomes
- Staleness
- The connection between the two pi extensions

This document refers to those sections by name instead of repeating them.
`AGENTS.md` describes what kido cannot change.

## The tools, and their commands

Every tool calls a `kido tool` subcommand **of the same name**. Thus, the
tools and commands use one vocabulary, not two. The e2e suite cannot host
a TypeScript extension. It uses fake agent binaries to test the same paths.

| tool | command |
|---|---|
| `list_runs()` | `kido tool list_runs --json` |
| `set_status(activity)` | `kido tool set_status -- <activity>` |
| `message_agent(to, message, replyTo?)` | `kido tool message_agent [--reply-to ID] -- <to>` |
| `ask_agent(to, question, timeoutMs?)` | `kido tool ask_agent --id ID -- <to>` |
| `spawn_subagent(task, name?, model?, tools?, keepAlive?, fork?)` | `kido tool spawn_subagent --name NAME --task-file - [--fork SESSION_ID] [--model M] [--tools T,...] [--keep-alive] -- pi ...` |
| `spawn_subagent(resume, model?, tools?, keepAlive?)` | `kido tool spawn_subagent --resume RUN_ID [--model M] [--tools T,...] [--keep-alive] -- pi ...` |
| `steer_subagent(to, message)` | `kido tool steer_subagent -- <to>` |
| `interrupt_subagent(to)` | `kido tool interrupt_subagent -- <to>` |
| `stop_run(to, force?)` | `kido tool stop_run [--force] -- <to>` |
| `async_bash(command, name?, stream?)` | `kido tool async_bash [--name NAME] [--stream] -- COMMAND...` |
| `notify_parent(summary)` | `kido tool notify_parent` |

The rule applies in one direction only: a tool names its command. A
subcommand without a tool keeps the name that fits it. These include
`shell`, `ssh`, `get-agent`, `prompt`, `snapshot`, `reap`, `runs` and the
other subcommands. `kido agent-status` also keeps its own name. It claims
a session's run and reports its identity and heartbeat. In contrast, `set_status` writes only
activity (design.md, "Every report is whole").

Tests enforce this agreement. Both suites read one list in
`share/pi/testdata/tools.json`. pi's suite checks that the registered
tools have exactly those names. `lib/test/test_tool_parity.ml` runs each
as a `kido tool` subcommand. A registered tool absent from the list fails
pi's suite. A listed tool without a command fails the OCaml suite.

Every command knows its caller from `PI_SESSION_ID`, which pi sets for
its bash tool and the extension sets for the commands that it runs
(design.md, "Identity"). No tool passes its own session as a flag.

A tool forwards its arguments and lets its command refuse them.
`spawn_subagent`'s schema does not express these rules:

- `resume` excludes `task`, `name` and `fork`.
- A spawn needs a task.

The tool does not check these rules either. Every argument goes to
`kido tool spawn_subagent`. The command refuses these combinations and
spawns that exceed the nesting depth ceiling. Thus, one location contains
the rules, and the model reads kido's own refusal.

**The suffix is the scope.** Each half of a tool's name has a meaning.
The second half gives a rule:

| suffix | who it may act on | tools |
|---|---|---|
| `_agent` | any agent in this tmux session | `message_agent`, `ask_agent` |
| `_subagent` | your own descendants | `spawn_subagent`, `steer_subagent`, `interrupt_subagent` |
| `_run` / `_runs` | run listing and stopping | `list_runs`, `stop_run` |

The scope includes descendants, not only children. Nesting permits two
levels, so the controls can reach a grandchild. One predicate checks this
for all three controls. It uses the `Descendant` and `Descendant_run`
recipients of `Message_agent.resolve`. For agent controls, the receiver
makes the corresponding check in `senderIsAncestor`.

The `_subagent` rule does not give protection. Trust is uid-scoped, and
the inbox directory is `0700`. Any process that can reach the socket can
write an envelope that claims any identity (design.md, the inbox). The
rule gives a consistent vocabulary. A tool's name identifies whose work
it can affect.

**What steers and what queues.** `message_agent` queues messages.
`steer_subagent` permits interleaving for a correction that is useful only
before the work finishes. design.md ("Steer and followUp") gives the rule:

> Steer what is safe to interleave. Queue what must be answered in order.

`steer_subagent` steers a correction from the agent that assigned the
work. It has nothing to correlate and is useless after the work finishes.
`notify_parent` steers information that the parent needs to assign the
next work. `message_agent` queues messages with no correlation or
authority. `ask_agent` also queues questions. An ask requires a correlated
reply, so kido chooses `followUp` to keep questions ordered.

The tool and command interface has no `--kind` flag. The command gives
the kind: `message_agent --reply-to ID` is a reply, `ask_agent` is an ask,
and `notify_parent` is a notice. Each states the fact once. A single
`kido message --kind K` would state it twice with
`--kind reply --reply-to ID`.

An envelope carries these kinds:

- message
- ask
- reply
- notice
- steer
- interrupt
- stop
- stream

A reply correlates on `kind: "reply"` (design.md, "v0 and v1").

`kido tool ask_agent` sends and returns without waiting. The answer
arrives on the asker's own inbox. Only a long-lived process has an inbox.
If the caller has no inbox, the command refuses delivery. It tells the
caller to use `message_agent` instead (design.md, "Ask and reply").

`kido tool notify_parent` takes no target. It reads the parent edge from
`KIDO_AGENT_PARENT_SESSION` (design.md, "Notifying the parent"). Tools
register unconditionally. They report kido as unavailable until a session
resolves it.

`set_status` and `notify_parent` have bounds of 256 and 4000 bytes,
respectively. Their schemas do not repeat the bounds as `maxLength`:
the commands control the byte bounds. An activity is a UI label, which
the command truncates. A report is a work product, which the command
keeps whole. Only the text *sent* to the parent has a bound
("Reporting", below).

`list_runs` is the only tool for finding agents to message and runs to
stop with `stop_run`. A top-level caller sees other top-level agents in
its tmux session as peers. A subagent sees its parent and its live sibling
subagents as peers. It does not see other top-level agents or its
parent's bash jobs.

Both callers see their own runs. These include all running runs and the
newest 20 ended runs by start time. The own-run group shows the newest
runs first. The list excludes the caller itself and unrelated agents'
runs. An untracked shell sees top-level agents in its tmux session and
has no own runs.

Rows carry `kind` (`agent`, `subagent`, `bash`) and `relationship`
(`peer`, `parent`, `own`). Live agents retain id, name, pane, window,
status, activity, parent, depth, cwd, model, `canMessage`, `canReply`,
`sinceReport` and `stalled`. Own runs add `run`, `startedAt`,
`state` (`running` or `ended`) and the ending's `outcome` result and text.
A bash run or an ended subagent without a live holder has no agent
status and cannot reply.

Pane runs define the coordination graph, regardless of the pane's root
app. Clearing or replacing the root does not remove an identity, inbox,
parent link or run history. pi's listed status is the pane root's OSC
7501 state: working, blocked, done, error or idle. The listed status is
unknown when the state is absent. pi's name is the session name in its
`pi.json`, or the unchanged pane title when the session has no name.

Native Claude Code has no run and does not appear in the list.

A pi is stalled only with a working root and an old `pi.json` heartbeat.
A bare pi never stalls. One fresh tmux read supplies the graph; it is not
a cache. `ask_agent` refuses a stalled target before sending. `canReply`
also reflects an agent run's tool allowlist.

Names still resolve across the entire tmux session for messaging, asking,
steering and interrupting. The list does not restrict addressing.
The extension's autocomplete reads `list_runs` and excludes bash and
ended rows.

These internal checks use the live graph from the pure
`get-agent --context` lookup, not the scoped display:

- Sender validation
- Ancestry
- Self-window lookup
- `resolveAgent`/`canReply` checks

An unlisted sender is still an agent, and a grandparent remains an
ancestor.

## What a child is given

`kido tool spawn_subagent` reads the caller's pane from `$TMUX_PANE`.
From that pane, it reads the tmux session and working directory. The
caller's run (`PI_SESSION_ID`) is the parent. It creates a detached
window in that session, with the requested name, at the caller's
directory. The window runs the command
after `--`, or plain `pi`.

If the command is literally `pi`, kido inserts `--session-id <run-id>`
after it. Thus, the run id is the child's pi session id, with no mapping
to store. The extension adds `--name` and `--model` to pi's command.
It passes tools only as kido's `--tools` flag. kido selects that list,
or the stored list on resume, and records it in the run metadata.
For a pi child with a parent, kido adds `notify_parent` to a non-empty
list unless present. It emits `--tools` once. An empty list keeps pi's
default tools; `--tools ''` also selects defaults on resume.
A `--no-parent` child keeps its requested list.
A narrow toolset limits possible effects; the depth ceiling does not.

The spawn-specific environment uses `new-window`'s `-e` flags.
Otherwise, the command receives tmux's global and session environment,
not the caller's full environment. It takes `PATH` from the client when
available:

| variable | what it carries |
|---|---|
| `KIDO_AGENT_PARENT_SESSION` | the parent's session id, the parent edge |
| `KIDO_AGENT_TASK_FILE` | the task text, in the run's directory |
| `KIDO_AGENT_RUN_ID` | the run id, which for a pi child is also the session id it must prove it holds |

For a `--no-parent` spawn, kido omits the parent variable. It does not
set it empty. The child's subagent test checks its presence ("A human at
a shell", below).

The environment does not prove identity. Everything that the child's
process starts inherits the environment. Thus, a pi started inside a
subagent's pane receives the complete set. The child's extension trusts
the parent edge only when its own pi session id is also
`KIDO_AGENT_RUN_ID`. See design.md, "The run id is the child's session id".
This prevents a nested pi from ending another session's run and closing
another session's window.

Depth is the length of the run's parent chain in run metas. No run stores
it, and no caller can claim it. kido refuses a spawn at depth 3. A run
without a parent is top-level, at depth 0, and its children start at depth
1 (design.md, "The depth ceiling is derived").

kido refuses a window name that contains a character tmux's parsers
cannot pass, or that exceeds 64 bytes. If the model gives no name, the
extension generates a hex name. kido refuses a task over 1MB.

The pane receives `remain-on-exit`, so it remains after its command exits.
This is a pane option, so a later split does not inherit it. The pane
also receives the pane-scoped option `@kido_run` (`set-option -p`). Its
value is only the run id.

The sweep, sidebar tree and window-cycling keys use `@kido_run` and the
run's kind to identify the window as a subagent's window. The option
lasts as long as the pane (design.md, "Who is authoritative for what").
The child's claim sets the same mark again, with the same run id. If kido cannot mark the
pane, it kills the window instead of leaving a window it cannot collect.

The pane-scoped option distinguishes the run's pane from a later split
that the user creates. A window option would apply to every pane,
including splits, and could not identify the run's pane. A pane option
has no such fallback and reads empty on the split.

The sidebar draws the run's row on the pane with the option. It shows
the running row, or the tombstone with its outcome. It draws every other
pane as its actual shell or command. The sweep and `kido tool stop_run`
act on the run's pane, not the whole window. The user's split remains.
Killing the run's pane also clears `@kido_run`; no separate unmark step
is necessary because the option exists nowhere else.

The extension tool immediately returns
`spawned <name> (window @N, pane %N, run <id>)`. It does not wait for the
child. Both a spawn result and a resume result end with the same rule:
the child's result arrives as a notice. Do not wait for, request or
predict that result. The model reads the launch result when it has a
child but no result, which is when it invents a result or blocks.

`spawn_subagent` and `async_bash` also register `promptGuidelines`:

- A notice arrives on its own. Do not ask or poll for it.
- A child's report states what it intended. Check the diff.
- A notice is information, not the user speaking. A message's first line
  identifies its sender.

Both tools share the last guideline as one identical string. A parent's
message is not called "not the user": its instructions have the user's
authority. Each guideline applies to its tool. Thus, the model receives
the rules where it can start background work.

## Forking the caller's context

`spawn_subagent(fork: true)`, `kido tool spawn_subagent --fork SESSION_ID`,
starts the child as `pi --fork <session> --session-id <run-id>`.
The task is its first message. Everything else uses the fresh spawn path:

- The same `Spawn_subagent.create_run_window` and `run_env`
- Its own run id
- The parent edge
- The mark
- The depth ceiling
- The tool allowlist
- Model handling

Only the source of the child's context changes. The child starts with
the caller's whole transcript. The parent can assign a judgement, such
as a merge or a decision between two options it already considered.
The parent does not have to repeat its decisions and reasons.

kido passes both flags to preserve its identity rule. A child proves
its run identity with `sessionId() === KIDO_AGENT_RUN_ID`
(design.md, "The run id is the child's session id").

The forked session is the **caller's own**. pi gives the extension its
id, and the extension passes that id. kido does not guess it from a pane.
Nothing resolves a session that the model names. There is exactly one
correct answer, and the model does not supply it.

**Forking is for a short judgement step, not a long worker.** A worker
needs a task and a clean context.

The flag reaches tmux's command line. Thus, the window name's rule
(`Launch.tmux_safe`) applies: kido refuses an unsafe value instead of
quoting it. kido refuses `--fork` and `--resume` together. `--resume`
continues a run's own session; `--fork` starts a new session from another
session.

Unlike `--resume`, nothing checks that the source session exists.
The source is the caller's own live session, so it exists by construction.
If it somehow does not exist, pi's own error appears in the child's
window.

## The run record

Each spawn owns `<state>/runs/<run-id>/`. kido writes it before creating
the window, so the child can read its task as soon as tmux starts it.
The run id is the abstract type `Run.id`, not a bare string.
`Run.parse_id` is the only check that the id names nothing outside
that directory.

Each location where an id enters the module applies this check:

- `kido run-outcome`
- `spawn_subagent --resume`
- A `Tmux_pane.t`'s `run` reader
- A `KIDO_AGENT_RUN_ID` reader

Every function that takes a `Run.id` trusts it. design.md, "Who is
authoritative for what", gives the layout of the directory and the
writer of each file. Two files have reasons that belong to subagents:

- `delivered`: the child writes this after reading the task. Thus,
  `/reload` does not deliver the task twice.
- `screen`: the window's last screen and a bounded tail of scrollback.
  The run's shutdown captures its pane before recording a failure
  (`kido run-outcome`). At that moment, the pane is certainly alive.
  A completion's screen supplies no evidence, so nothing keeps it.

  A sweep captures the pane it will close when the child cannot capture
  it. Both write the same file. `kido close-run` captures nothing.

An outcome has one write per run attempt. Nothing overwrites it until a
resume clears it. design.md's "Run outcomes" gives the rules for each
writer and explains why the first recorded ending wins.

`kido runs` lists every run, `pi` runs included, most recent first.
Alternatively, it shows one run with its task, its screen if present,
and its resume command. It shows a run with no outcome and a dead pid as
`died`, without recording that guess.

## A child's life

**Start.** The child's extension binds its inbox before delivering the
task, so it can receive questions during its first turn. It reads the
task file and delivers it as its first user message, as it delivers an
inbox prompt.

Every turn's system prompt then contains these standing instructions:

- You were spawned.
- If the work is done or blocked, call `notify_parent`.
- A reply to another agent's question is the whole response.

The system prompt contains the instructions instead of the task because
the task arrives only once. Otherwise, a resume or a follow-up message
from the parent would not include the instructions.

**Watching the parent.** The child's pi is a child of the tmux server.
Thus, no signal tells it that its parent has ended. It polls every five
seconds with `kido get-agent <parent-session>`. The poll acts on one
reading of the answer. That command reads the parent's `pi.json` by id
and reports whether its pid is alive. The orphan sweep asks the same
question.

The poll does not list panes. Thus, each child uses one process and no
tmux round trip every five seconds. A failure of kido to answer is the
only inconclusive case and is never evidence. If the parent is dead, the
child shuts down through the normal exit path.

**Reporting.** Nothing reports for the child. The child calls
`notify_parent` itself, once, when its model judges the work done.
The summary goes only to the parent as a `notice` envelope. Its address
is the session in the child's environment, not a session from a lookup.

The command **keeps the report whole**. The notice enters the parent's
next turn, so the text sent to the parent has a 4000-byte bound.
Discarding the rest, as the tool would, cuts the report mid-sentence
without indicating that more text exists.

Thus, `kido tool notify_parent` writes the full text as `report` in the
sender's own run directory, beside `task` and `output`. It sends the start
of the report plus a final line that names the file:

    full report: <state>/runs/<run-id>/report

The report's start and final line together remain within the cap.
A report within the cap arrives byte for byte and leaves no file.
Nothing is lost, so no file reference is necessary. The command removes
any partial rune from the end of the report's start. The send path
refuses a message that is not valid UTF-8, like `Reap.body` in the other
direction.

A sender without a run directory has nowhere to keep the report.
This can be a session kido never spawned, with another session's parent
edge. The command truncates that report. It also truncates the report
if the write fails, because the parent must receive something.
`kido runs <id>` includes one `report:` line for a run that leaves a
report file.

Nothing notifies on a settled turn because a turn can settle for reasons
unrelated to the task. For example, answering a sibling's `ask_agent`
settles a turn. An automatic notice would send the parent the report
meant for the sibling (design.md, "Notifying the parent").

A turn that ends in a provider error is the only exception. kido retains
the last `agent_end` result and checks it in `agent_settled`.
If the turn stops on `"error"`, the child immediately sends its parent
one notice through `notify_parent`'s path. The notice names the error and
explains how to continue the run. An aborted turn, such as a turn the
parent interrupts, is not a failure and sends nothing.

The notice does not count as the child's report. If the child then sends
nothing, the ending notice below still arrives. Its detail contains the
last error. The child still decides what to say about its work.

An **ending** is not a judgement. If the child shuts down without calling
`notify_parent` in this session, it produces one notice that states this
fact.
The notice names the run, its recorded outcome, its run id and
`spawn_subagent(resume:)` to continue it. It claims nothing about the
work. It states only that the run ended without a report, which any
observer can establish.

Without this notice, the parent learns nothing here. A parent that
assigns work and waits quietly for a report would wait for a report
that never arrives.

Two observers can send the notice. They correspond to the two ways a
run can end without a report:

- The child's own shutdown after an idle self-exit, a quit or a lost
  parent, if the session never calls `notify_parent`. The notice comes
  from the outcome-recording location, `kido run-outcome --unreported`.
- A sweep of a marked run pane dead past the linger, or collected as an
  orphan, with no recorded outcome. The notice states that it is unknown
  whether the child called `notify_parent`. Any report that the child
  sends remains valid.

The atomic-link outcome write selects the sender, as for every other
ending ("Exactly one ending", below). A run stopped from outside already
has a notice from its stopper and an outcome on disk. It produces no
extra notice when its child shuts down.

The parent's UI displays a notice immediately as a dimmed
`│ @<name> notifies: <first line>` line above the editor. Separately, the
notice enters the model's context at the next turn boundary. In
fullscreen mode, it is a collapsed message that a mouse click expands.
Outside fullscreen mode, it is expanded. kido keeps visual arrival
separate from model delivery.

A notice steers instead of queuing as a follow-up. Thus, a parent in a
turn sees it between tool calls and decides whether to act.
A `steer` envelope works the same way, for the same reason ("What steers
and what queues", above). A message and an ask still wait for the turn.

**Idle self-exit.** The session-id test above identifies the real child.
After settling a turn and staying idle for thirty seconds, that child
calls pi's own shutdown. It does not shut down if its run metadata's
`keepAlive` is true at the idle check. While `keepAlive` is true, the timer
re-arms. Metadata edits take effect at the next check.

The same clock also arms when the task arrives. A child with its task
has everything it needs; after thirty seconds, kido stops waiting.
This delivery timer covers a child that never reaches its first turn.
The clock starts from delivery, not session start. Thus, it does not
affect a resumed run waiting idle for a message, or a session without a
task file.

Delivery is not itself work. The first actual sign of work clears the
clock. New work, or a message ready for delivery, restarts the clock.
If a client is viewing the window, the timer re-arms and tries later
instead of removing the window.

One call to pi's shutdown does not prove that the session ends.
After every shutdown call, the clock re-arms, as it does for other
conditions that prevent exit. The session's own ending clears it.
A root session, with no parent in its environment, never arms the clock.

**A session with a live child of its own is not idle**, even when it is
quiet. "I have spawned it and I am waiting for its report" settles a turn
in the same way as finished work. A clock that cannot distinguish them
shuts down the parent thirty seconds after it spawns. The orphan rule
then closes the child during its work.

Thus, the timer first asks `kido get-agent --children <session>`.
If the answer is yes or inconclusive, the timer re-arms.
It also re-arms if the run's own `keepAlive` field is true, as for a
focused window.

The check reads **run records**, not the session's memory.
A live child is a run whose meta names this session as its parent, with
no recorded outcome and a live pid. `kido runs` shows that run as running.
A child continues after the turn that spawns it. `/reload` forgets
everything in memory. The record remains and contains the parent edge.

A child with a dead process but no outcome yet reads as ended.
This is the safe result: a dead child that prevents parent exit would
never let the parent become idle again. An error or timeout is
inconclusive. The timer re-arms until kido definitely reports that no
child is alive.

**Shutdown.** The child uses one teardown, whether it quits, self-exits,
is stopped or loses its parent:

1. The child stops the parent poll and idle timer.
2. The child releases every waiting ask.
3. The child closes the inbox.
4. The child records `completed` if the session is idle, or `failed`
   otherwise. A session waiting for its first turn reports idle but has
   done nothing. Thus, it records `failed`, with a detail that states no
   turn ever ran. This lets the parent distinguish "never started" from
   "ended mid-work".

   For a session where no turn ran, the detail also names pi's
   "Use /login" line if the captured screen contains it. This is the only such ending with a cause known without
   opening the screen. If the session never calls `notify_parent`, the
   command also uses `--unreported`.
5. The child starts a detached helper to run `kido close-run` after the
   linger.
6. The child releases its run: `pi.json` stays, with pid 0.

`/reload` runs the same handler but omits all run-ending parts because
the run continues.

**The window, and the pane.** The helper collects the run's pane after
thirty seconds. It does not collect the pane while a client is in the
window or the run continues. If this is the window's only pane, the
window also closes unless it is the session's last window.

The sidebar's sweep supplies a second collection path. It collects a
marked run's pane dead for the same thirty seconds and captures its
screen. If no outcome exists, it records `died`.
A window with the user's own split keeps that split and loses its mark.
It becomes an ordinary user window (design.md, "Window lifecycle" and
"Idle self-exit, and resuming a run").

## Redirecting one, and ending one from outside

`steer_subagent` leaves the turn running and adds text inside its loop.
The child reads it between tool calls and continues with the correction
instead of restarting. On arrival, the text identifies its sender.
Otherwise, an instruction arriving during a task would appear to be the
child's own idea.

`interrupt_subagent` aborts the target's current turn. It leaves the
target idle with its context intact. `stop_run` asks the target to shut
down and waits up to five seconds for its holder to end. If the holder
is still live, it kills the pane. For a target with no inbox,
or a stale inbox, it kills the pane immediately, and only with `force`.

All three controls reach descendants only. kido checks before sending,
and the receiving extension checks on arrival, because the sender field
is advisory. A human at the CLI has no caller and can act on anything
(design.md, "Steer, interrupt and stop").

The sweep collects orphans. A marked run pane is an orphan if its run
meta names a parent whose run has no live holder.
The sweep collects it on one reading, unless its window is focused or
collection would destroy the session. Before closing a bash run's pane,
it records failure with the detail "its parent ended".
The wrapper forwards the hangup to its command. A notice to the absent
parent fails without an error report.

The check reads the parent's run by id, not a pane. A session that
claims the parent's pane changes only the pane's mark, not the answer.
A one-shot `kido reap` also applies this rule. It needs no second sweep.

The parent edge names the parent's **session**. A parent can quit and
resume with `pi --session`, as a new process on the same session id.
Its children belong to it again as soon as it claims its run.
During the gap, no process holds that session id. Its children are then
orphans, and the sweep acts on one reading.

This includes `kido tool async_bash` runs. The sweep reads their parent
edge from the run meta. An agent child's own parent-liveness poll can
also end the child. `/new`, `/resume` and `/fork` change the parent's
session id and orphan its runs. `/reload` keeps the parent's claim and
does not orphan its runs.

## Resuming a run

`kido tool spawn_subagent --resume <run-id>` starts a finished or dead run
again in a window. It uses `pi --session <session file>` at the run's own
directory, under the original name. It uses the model recorded in meta,
unless the command after `--` names a model. It uses the same window
creation and mark as a fresh spawn. The run continues without a
duplicate; kido clears its old outcome and screen.

kido refuses a run while its recorded pid is alive, even if shutdown
records an outcome. It does not refuse a run without a pi session file.
The run id is the child's own session id. Without a file on disk, the
id is free, not stale.

If the run's `pi.json` names no pi session file that exists, the resume
creates a fresh session
under that id with `--session-id` and clears the run's delivered marker.
Thus, the child receives the stored task again instead of skipping it
as already delivered.

The resumed run uses its recorded model, tool allowlist and `keepAlive`.
Arguments after `--` can override the model and tools.
`--keep-alive` can enable `keepAlive`, but cannot disable a recorded true
value (design.md, "Idle self-exit, and resuming a run").

The caller that resumes becomes the parent edge. Thus, an agent that
resumes becomes the run's new parent. A human at a bare shell resumes a
parentless session that does not self-exit.

`--no-parent` explicitly requests a parentless session. Thus, an agent
can transfer a run instead of becoming its parent. kido checks that the
caller is a live agent before creating the window. The sweep keeps no
history. A stale edge would cause orphan collection within seconds,
without an explanation.

`spawn_subagent(resume)` runs with the caller's own session.
kido refuses `--task-file`, `--name` or `--fork` with `--resume` instead
of guessing the model's intent. A fresh spawn and a resume are two
variants of one parsed request. After each variant's specific part, they
share these checks and operations:

- The depth ceiling
- The parent check
- The model check
- Window creation

The `pi --fork <run-id>` line from `kido runs` remains a bare command.
Forking a *finished run* from a shell creates a standalone session with
a `pi` run of its own and no parent. In contrast, `spawn_subagent(fork)` forks the *caller's live
session* into a child with a record ("Forking the caller's context",
above).

## An async bash run

`kido tool async_bash [--name NAME] [--stream] -- COMMAND...` runs a command
in its own detached window. It tells the caller once the command ends.
Its structure is a spawn with a command as its child, not a pi session.
It uses the same components:

- `Spawn_subagent.create_run_window`
- `run_env`
- The `@kido_run` mark
- The run record
- The sweep

`meta.json` always contains a `kind`: `pi`, `agent`, `bash` or `stream`.
`agent` names a subagent run. `bash` and `stream` name plain and streamed
`async_bash` runs. `pi` names a pi that kido did not start. This field is the source of truth for whether the
wrapper streams.

One word after `--` is a shell command line that runs under `bash -c`.
This is the form a model writes ("make -j8 && ./run"). Several words are
an argv that the wrapper executes as given. In either case, kido writes
the command to the run's `command` file before creating the window.
It also writes `meta.json`, which gives the wrapper the run's name and
parent. After tmux answers, kido atomically adds the window's pane and
pid to meta.

The window's command line is always `kido async-run --run-id ID`.
Text from the model never reaches tmux's parser. `--name` is optional.
Without a name, kido uses the basename of the command's first word.
It retains only alphanumerics, `-`, `_` and `.`, with a 64-byte cap.
For an empty result, it uses `bash`.

The parent is the caller's run, from `PI_SESSION_ID`, not a flag. That
run is the only correct answer to who must receive the notice. A command
without a caller, such as one from a human's shell, has no parent. The run then records its
outcome and tells nobody.

The spawn depth ceiling does not apply because a bash run starts no
agents. An agent at the ceiling can still run a build.

**The wrapper.** `kido async-run` is the window's command and the complete
completion mechanism. It reads the run's argv and runs it. It tees
stdout and stderr to the run's `output` file and to the pane. It waits
and gets the exit status from `wait(2)`, not from tmux observations.
Then it does these operations in order, never concurrently:

1. It records the outcome: `completed` for exit 0, or `failed` otherwise.
   The text is the status ("exit status 3", "signal: killed").
2. It sends one completion notice to the parent. This is a `notice`
   envelope through the parent's inbox, addressed to the parent session
   in the run's meta. The wrapper needs no `pi.json` of its own, like a
   spawned child's report to its parent.

The wrapper reports everything **before this process exits**.
Thus, the feature does not depend on the window remaining.
tmux sets `remain-on-exit` in a second call after `new-window`.
A fast command can finish before kido marks its pane. The run record
and notice do not depend on retaining the pane. The race only removes
the dead pane from the screen.

Thus, a missing window is not a creation failure. kido skips the mark,
does not overwrite the command's outcome, and prints the ids as usual.
The code explicitly permits this for the **bash or stream** case only.
It depends entirely on a wrapper in the window that already reports
for the run.

An agent spawn that loses the same race records a failure. Nothing else
can describe that run. The missing window has no marked pane, so neither
sweep rule can reach it. A pi that disappears that quickly never reaches
its task.

The async wrapper and spawned agents inherit `$TMUX`. Thus, their kido
calls resolve the parent's server directory without `KIDO_STATE_DIR`.
Watcher scripts derive their run directory from `KIDO_AGENT_TASK_FILE`,
which kido already resolves. They do not copy the state resolver.

`kido tool async_bash` prints the spawn line with a fourth field: the
run's output file. kido determines where it keeps a run's output.
A tool that reconstructs the path would duplicate `State.dir`'s pane
socket derivation and default environment precedence. Thus, the tool's
single call supplies the path.

The notice names the run itself:

    async run "build" failed: exit status 3
    run: 6f1c...
    output: <state>/runs/6f1c.../output
    --- last 4000 bytes of output (12034 omitted) ---
    ...

The envelope's `from` also names the run, for the same reason.
A bash run has no `pi.json`. Thus, kido could otherwise identify only
the *process* that observes the ending:

- The wrapper's pane, which is not an agent. The parent would read
  "notification from %47".
- A sidebar that sweeps the pane.
- An unrelated agent that types `kido tool stop_run`.

The run's name is the only correct answer. The parent's widget row shows
that name.

The output file is the source of truth. Nothing truncates it.
For a run that does not stream, the notice contains its last 4000 bytes.
It uses the tail, not the start, because failure information comes last.
If the tail starts inside a UTF-8 character, kido removes that partial
character. It replaces invalid UTF-8 with replacement characters.
Thus, a log ending mid-character cannot prevent the run's only notice.

A streamed run's wrapper notice has no tail because the parent already
receives the output during the run. It includes only the
"N lines not streamed" count above, if that count is nonzero.

**Exactly one ending.** The outcome has one recorded write; the first
write wins. The winner sends the notice. `Run.record_outcome` links a
completed temporary file with `Unix.link`. The same write, read in the
same way, decides the winner. No flag or "notified" marker is necessary.
Three observers can win:

| Observer | Discovers the ending | Records | Notifies |
|---|---|---|---|
| the wrapper | its own `wait(2)`, or a signal it can catch | `completed`/`failed` | yes, with the exit status |
| a sweep's rule 1 (`Reap.sweep`) | a marked window dead for the linger | `failed`, "ended without its wrapper reporting" | yes, if it won |
| `kido tool stop_run` | a deliberate stop | `stopped`, "stopped by its parent" | yes, if it won |

The wrapper covers every ending that it survives long enough to observe.
Thus, it forwards `SIGTERM`, `SIGHUP` and `SIGINT` to the command.
It then reports `failed` during its own exit. It cannot survive
`SIGKILL`. If that signal leaves a marked dead pane without an outcome,
rule 1 finds it and sends a notice.

Killing the window removes the mark. If the window disappears and the
wrapper dies without reporting, the sweep cannot report the ending.
Recording `died` without a notice for a marked dead pane would leave the
parent of a killed build waiting forever.

Both kinds of run have ending reports, but the claims differ.
A bash process's completion is an exit code, which the wrapper's notice
reports. An agent's completion is a judgement that only the model can
make. Thus, a sweep's notice for an agent reports only that the run ends
without recording its own outcome ("Reporting", above). The sweep records
`died`.

Neither kind of run sends a notice without a parent session.
`kido tool async_bash` at a human's shell produces such a run.

The three observers share one notice builder: `Reap.body`, over a
`Reap.ending`. Thus, the notice does not differ according to which
process observes the build's ending. Observers outside the run use one
write-then-decide function, `Reap.record_ending`. A third observer can call
this function instead of implementing the same invariant again.

The wrapper writes for itself because it is inside the run's own
process. It is the only observer that can distinguish a failed write
from a write that loses. `Reap.sweep` sends nothing. It returns the runs
whose parents the caller must now notify.

`Reap.collect`, called from `kido reap` and the sidebar's poll, sweeps,
releases, then sends each ending with `Reap.send`. A window sweep does
not need to know what an inbox is. It can know only that a run ends
without a report.

**Stopping one.** `kido tool stop_run -- <name>` ends a run.
It resolves the address in this order:

1. The exact run id.
2. A unique id prefix of at least eight characters.
3. An unambiguous running run name, case-insensitive.

It removes one leading `@` at the input boundary. For an ambiguous name,
it lists the matching run ids. It refuses an explicitly addressed ended
run. Both agent and bash runs obey descendant scope. Bash runs identify
their caller through the parent in meta. A human with no caller can
stop any run.

For an agent run, stop asks its inbox to shut down. It waits up to five
seconds and kills the pane if necessary. `--force` permits a pane kill
when no usable inbox exists.

A bash run needs no `--force`. Stop records `stopped` with the text
"stopped by its parent" before sending TERM to the wrapper pid.
The wrapper forwards TERM to its command. First-write-wins keeps the
stopping outcome instead of the wrapper's generic signal error.
Stop waits for the wrapper's pid and escalates with KILL if necessary.
It sends the one ending notice with the output tail.

Stopping a live wrapper does not depend on its pane. The existing
pane-kill path removes a dead wrapper's lingering pane.

Except for stop and orphan collection, a bash run is deliberately not an
agent. It has no `pi.json`, but appears among its caller's own runs
in `kido tool list_runs`. `message_agent` and `ask_agent` cannot address
it. It has no status to report and nothing that can answer.
Its run record stores facts that remain after a process ends.
`kido runs` shows it like any other run.

## Streaming a run's output

`async_bash(command, name?, stream?)` and `kido tool async_bash --stream`
request the command's output as it arrives, not only at the end.
The tool interface uses one boolean because one flag controls the
capability. A second tool would give it a second name. Every tool calls
the subcommand of its own name.

kido **coalesces** at both ends to bound the number of messages.
It does not send an envelope for each line. The receiver's `turn_end`
handler is one opportunity to flush held output.

**The wrapper's side.** For a run whose meta kind is `stream`,
`kido async-run` tees output into a third writer. This writer batches
whole lines. It sends one `stream` envelope on a 250ms tick, or when at
least 4KB of whole lines are pending.

The writer removes ANSI escapes and control bytes below 0x20, except
tabs, from the sent text. The output file keeps the bytes as written.
An unfinished line waits for its newline or for the close.
Every send resolves the parent's inbox by session id. This reads the
state directory without a tmux pane listing. Thus, the parent's current
inbox receives the next batch.

If the orphan sweep observes a quit-then-resume gap, the run ends.
Resuming the parent does not restart it.

Sending output must never block the command's output. The tee to the
output file is unconditional and is the source of truth.
The stream tries to send from a buffer of whole lines.
The wrapper's output pump writes to this buffer under a mutex.
One separate thread sends the buffer's contents.

A failed or stalled send discards its chunk instead of retrying it.
Late, out-of-order build output is worse than absent output, and the file
contains all output. The sender uses a doubling backoff before the next
attempt. A buffer over 64KB discards its oldest lines. Thus, a slow parent
receives the tail.

After acknowledgements reach at least 256KB for a run, the next batch
reports this once and the stream stops sending. The batch that crosses
the threshold arrives whole.

The wrapper counts every line that the parent does not acknowledge.
The completion notice contains the count as `N lines not streamed`.
Thus, a model that receives output does not incorrectly believe it sees
all output.

The wrapper sends the notice **after** the final chunk. Before building
the notice, it closes the stream, which flushes and waits for pending
sends. The wire uses one connection per message, without sequencing.
The wrapper sends messages one at a time. This is the only available
ordering.

**The receiver's side.** A `stream` envelope is the only kind that
reaches nobody on arrival. `kido-agents.ts` appends its lines to a per-run
buffer. It gives the buffer to the model as **one** collapsed custom
message at one of three moments:

- At `turn_end`, **only if that turn ran tools**. This single `if` guard
  makes streaming affordable. A turn with tool calls already commits to
  its next LLM call, so the batch costs zero extra turns.

  A turn without tool calls means the agent stops. Flushing then starts
  another turn, whose `turn_end` also has no tool calls. More lines arrive during that
  turn. The resulting loop ends only when the command ends. This is the
  uncontrolled loop the design prevents, even through the coalesced
  channel.
- Otherwise, 1s after the last chunk, and at most 30s after the first
  held chunk. Each chunk restarts one timer for the session, not one per
  run. Thus, a burst becomes one batch. A quiet watcher's lines reach the
  model a second after they are written. Each such flush costs one
  actual turn.
- Immediately before a run's completion notice. Thus, the model never
  reads "this is how it ended" before the corresponding output.

A batch keeps a tail of up to 200 lines within a 16KB line budget.
It retains a single overlong last line, truncated to 16KB.
One line above the tail reads `... N lines omitted (see <path>)`.
N counts lines removed by the cap and lines discarded by the held
5000-line buffer while waiting for a turn. One number is the only one
the model can act on.

The batch uses the tail, not the start, for the same reason as the
completion notice. The row and the batch's first line contain the run's
name. A bash run has no `pi.json`, so the label would otherwise use a
pane id.

`stream` defaults to off.

## A human at a shell

The commands belong to the tools, but humans can also run them.
This is a supported use. A bare shell has no `PI_SESSION_ID`, so it is
no caller: no inbox, no session id and no parent. Every difference
follows from this fact.

What works:

- `kido tool message_agent`: a one-way send with no sender requirements.
  An agent whose run names an inbox receives a real user message.
  An advertised but unavailable inbox is an error. Only an agent whose
  run names no inbox receives a paste. The message arrives without a
  label because a command with no caller is the user speaking. An agent's
  own message has a header that names the sender (design.md, "The inbox").
- `kido tool spawn_subagent --no-parent`: a standalone agent in a window,
  owned by nobody (design.md, "A parentless spawn, and a parent that
  must exist"). Setting `PI_SESSION_ID` to a live agent's session also
  works and makes that agent the child's parent. kido refuses a dead or
  invented agent instead of spawning the child.
- `kido tool spawn_subagent --resume <id>`: parentless by default from a
  shell, and with `--no-parent` from an agent.
  `kido runs <id>` prints exactly this line.
- `kido tool steer_subagent`, `interrupt_subagent`, `stop_run`: a shell
  with no caller is nobody's ancestor. It can act on anything instead of
  nothing (design.md, "Steer, interrupt and stop").
- `kido tool list_runs` shows top-level agents from an untracked shell.
  `kido runs` and `kido reap` are read-only or read-mostly and unscoped.

The commands refuse these calls and state what to do instead:

- `kido tool ask_agent`: the answer can arrive only on the asker's inbox.
  A shell has no inbox. Delivering the question would use a target turn
  for a question it cannot answer.
- `kido tool notify_parent`: a shell is not spawned, so it has nobody to
  notify.
- `kido tool set_status`: no run exists for the activity.

The child of a `--no-parent` spawn has no idle self-exit, no orphan rule
and no report to its parent. The user can close its live window.
The sweep still collects a dead marked pane.

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

The anchor is the parent edge that the walk finds. The run's meta file
supplies the edge through its owner, for a live and a finished
child alike. Thus, a finished child remains nested while its window
lingers.
The sidebar draws a child as a root if its parent is absent or in
another session.

A lingering window shows its run's outcome in the field column.
A completed run has a dimmed `✓`. Every other outcome has a dimmed `×`,
including `failed`, `died` and `stopped`. A deliberate stop is not a
failure, but it does not finish the work. A window without an outcome
yet keeps the `×`.

The arriving outcome changes the row from a name to a result.
Showing success a tick early would be the only false claim this column
could make. The dim `✓` is distinct from the bold green `✓` for a live
agent's finished turn. A lingering row has no live agent to earn the
green indicator. This is the TUI's `Kido_sidebar.indicator` for an `Ended`
lifecycle.

These nested windows no longer follow tmux's own order.
Shift-Up and Shift-Down skip every window with a run pane, dead or alive.
Thus, the keys cycle through windows the user opens. The user reaches
subagent windows through the sidebar. Skipping a dead window without a
liveness test is deliberate. Otherwise, the key's behavior would change
during use as a window disappears after its linger.

## Limits

- If the sweep collects a child without a recorded outcome, it tells the
  parent that the child ends, but not whether it reports. One notice
  contains the run's name, outcome, id and resume instructions. Nothing
  reconstructs the work's progress. Only the run record and captured
  screen remain as evidence.
- A child can start shutdown when its parent dies. The sweep can close
  its window during shutdown and record `died` before the child records
  its own outcome. Whatever it managed to write first
  wins (`Run.record_outcome` links a completed temporary file with
  `Unix.link`).
- Nesting stops at depth 2 within each parent chain.
- `--no-parent` makes an ordinary top-level run, with depth 0. Its children
  start at depth 1. No depth ceiling or restriction carries over from the
  caller. This also applies to resume. It has no idle self-exit, no orphan
  rule and no parent to report to. The user can close its live window.
  The sweep still collects its dead marked pane.
- `kido tool ask_agent` deliberately refuses calls from a shell because
  the answer has nowhere to arrive. A human who needs a round trip must
  use a long-lived process, or use `message_agent` and read the reply on
  screen.
- The `ask_agent` tool waits for a reply. kido selects `followUp` to keep
  correlated questions ordered (design.md, "Steer and followUp").
  Expected scheduling is the target's current work plus a reply turn,
  not a round-trip. A correction that cannot wait uses `steer_subagent`.
  It is not correlated, so it does not need to queue.
- A child that exits before tmux sets `remain-on-exit` loses its window
  and last screen. Only the run record remains. For a bash run, only the
  screen is lost: the wrapper already records and reports the outcome.
  For an agent run, the spawn itself reports the failure. No other
  account follows.
- A subagent's window moved to another tmux session is outside its
  parent's scope. The parent cannot reach it.
- Everything assumes one machine: a shared filesystem, a shared pid
  namespace, and a kido binary beside every agent.
