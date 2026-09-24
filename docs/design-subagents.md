# Subagents, as built

A subagent is a pi session that another agent started, in a tmux window
of its own, in the same tmux session, with a task as its first message
and a record of the run that outlives it. This document follows one
from the tool call that creates it to the sweep that closes its window.
The mechanisms it rides on - the inbox, addressing, the instance id,
the window lifecycle, run outcomes, staleness, and the seam between the
two pi extensions - are described in [design.md](design.md), and are
referred to by section name rather than repeated. AGENTS.md carries
what kido cannot change.

## The tools, and their commands

Every tool shells out to a `kido` subcommand **of the same name**, so
there is one vocabulary rather than two, and the e2e suite - which
cannot host a TypeScript extension - drives the same paths through fake
agent binaries.

| tool | command |
|---|---|
| `list_agents()` | `kido list_agents --json` |
| `set_status(activity)` | `kido set_status -- <activity>` |
| `message_agent(to, message, replyTo?)` | `kido message_agent [--reply-to ID] -- <to>` |
| `ask_agent(to, question, timeoutMs?)` | `kido ask_agent --id ID -- <to>` |
| `spawn_subagent(task, name?, model?, tools?, keepAlive?, fork?)` | `kido spawn_subagent [--fork SESSION_ID]` |
| `spawn_subagent(resume, model?, tools?, keepAlive?)` | `kido spawn_subagent --resume` |
| `steer_subagent(to, message)` | `kido steer_subagent -- <to>` |
| `interrupt_subagent(to)` | `kido interrupt_subagent -- <to>` |
| `stop_subagent(to, force?)` | `kido stop_subagent [--force] -- <to>` |
| `async_bash(command, name?, stream?)` | `kido async_bash [--name NAME] [--stream] -- COMMAND...` |
| `notify_parent(summary)` | `kido notify_parent` |

The rule runs one way only: a tool names its command, while a subcommand
that is nobody's tool keeps whatever name fits it - `hook`, the
`setup-*` commands, `agent-alive`, `prompt`, `snapshot`, `reap`, `runs`
and the rest. `kido agent-status` is the sharpest case and keeps its own
name too: it reports a session's whole state on every turn, of which
`set_status`'s activity is one flag of fourteen, so the narrow tool got a
narrow command of its own (design.md, "Reporting, and what is carried
forward") rather than the report being renamed after it.

The parity is pinned rather than merely written down. `pi/testdata/
tools.json` is one list read by both suites: pi's own asserts the
registered tools are exactly those names, and `cmd/kido`'s
`TestEveryToolHasASubcommandOfItsName` asserts each is in `subcommands`.
A tool added without a command fails the first, then the second.

**The suffix is the scope.** The two halves of a tool's name each carry
something, and the second one is a rule:

| suffix | who it may act on | tools |
|---|---|---|
| `_agent` | any agent in this tmux session | `list_agents`, `message_agent`, `ask_agent` |
| `_subagent` | your own descendants | `spawn_subagent`, `steer_subagent`, `interrupt_subagent`, `stop_subagent` |

Descendants, not children: nesting goes two deep, so a grandchild is
reachable, and one predicate answers it for all four (`descendantTarget`,
cmd/kido/control.go, with the receiving half's mirror in
`senderIsAncestor`).

Be clear about what the `_subagent` rule is not. Trust is uid-scoped and
the inbox directory is `0700`, so any process that can reach the socket
can write an envelope claiming to be anybody (design.md, the inbox).
The rule buys a coherent vocabulary - you can tell from a tool's name
whose work it can touch - and not protection.

**What steers and what queues.** `steer_subagent` exists because
`message_agent` waits: a message is drained only after the target has
decided to stop, which is useless for a correction whose whole value is
arriving before the work is finished. The dividing line is design.md's
("Steer and followUp"), and it is worth repeating here in one line:

> Steer what is safe to interleave. Queue what must be answered in order.

So `steer_subagent` steers (a course correction from the agent that
assigned the work, nothing to correlate, worthless late) and
`notify_parent` steers (information the parent needs to dispatch the next
thing), while `message_agent` queues (no correlation, no authority) and
`ask_agent` queues - which is the one to remember. An ask demands a
correlated reply, so two must never interleave inside one turn, or an
answer can go back against the wrong `replyTo`; queueing is what makes a
consultant serving four agents answer them one at a time.

Three of the commands above used to be one, `kido message --kind K`.
Splitting it dropped `--kind` from the surface entirely: the command is
the kind. `message_agent --reply-to ID` is a reply - the old spelling
wanted `--kind reply --reply-to ID`, one fact stated twice - `ask_agent`
is an ask, `notify_parent` is a notice. The wire is untouched: an
envelope still carries all four kinds and a reply is still correlated on
`kind: "reply"` (design.md, "v0 and v1").

`kido ask_agent` sends and returns rather than waiting: the answer
arrives on the asker's own inbox, and only a long-lived process has one -
so a caller without one is refused outright rather than delivered, and
told to use `message_agent` instead (design.md, "Ask and reply").
`kido notify_parent` takes no target at all, reading the parent edge out
of `KIDO_AGENT_PARENT_INSTANCE` (design.md, "Notifying the parent").
Tools register unconditionally and report kido as unavailable until a
session has resolved it. `set_status` and `notify_parent` are bounded at
256 and 4000 bytes, and their schemas do not repeat the bound as a
`maxLength`: that counts UTF-16 code units and rejects the whole call,
which cost a subagent a redo of its one report. An activity is a UI label
and is truncated; a report is a work product and is kept whole, with only
what the parent is *sent* bounded ("Reporting", below).

`list_agents` returns every agent whose pane is in the caller's tmux
session, itself included, ordered parent-first: id, name, agent, pane,
window, status, activity, parent, depth, self, cwd, model, `canMessage`
(whether it has an inbox; a Claude Code session is visible but only
reachable by paste), `sinceReport` and `stalled`. Sessions in another
tmux session are not listed, and nothing here can reach them.

## What a child is given

`kido spawn_subagent` reads the caller's pane from `$TMUX_PANE`, and from it
the tmux session, the working directory, and the caller's own state record.
It creates a detached window in that session, named as asked, at the
caller's directory, running the command after `--` or plain `pi`. When the
command is literally `pi`, `--session-id <run-id>` is inserted after it, so
the run id is the child's pi session id and there is no mapping to keep. The
extension adds `--name`, and passes `--model` and `--tools` through when
given; a narrow toolset is the blast-radius bound the depth ceiling is not.

The environment is the only channel, because `new-window` runs its
command with the server's environment, not the caller's:

| variable | what it carries |
|---|---|
| `KIDO_AGENT_PARENT_PID` | the parent's pid, a cheap first liveness check |
| `KIDO_AGENT_PARENT_INSTANCE` | the parent's instance id, the parent edge proper |
| `KIDO_AGENT_DEPTH` | the child's depth, derived by kido |
| `KIDO_AGENT_TASK_FILE` | the task text, in the run's directory |
| `KIDO_AGENT_RUN_ID` | the run id, which for a pi child is also the session id it must prove it holds |
| `KIDO_AGENT_KEEP_ALIVE` | `1` when spawned with `keepAlive` |

Every row of that table is absent for a `--no-parent` spawn's parent
edge: the two parent variables are not set at all rather than set empty,
since their presence is what the child's own subagent test reads
("A human at a shell", below).

None of it is proof. The environment is inherited by everything the
child's own process starts, so a pi run from inside a subagent's pane
arrives carrying the whole set; the child's extension therefore believes
the parent edge only when its own pi session id is `KIDO_AGENT_RUN_ID`
too (design.md, "The run id is the child's session id"), which is what
keeps a nested pi from ending someone else's run and closing someone
else's window.

Depth is one more than the caller's own record says, never what the
caller claims, and a spawn at depth 3 is refused; a caller with no
record is depth 0 (design.md, "The depth ceiling is derived"). The
window name is refused if it carries a character tmux's parsers cannot
pass through, or exceeds 64 bytes; the extension generates a hex name
when the model gives none. The task is refused over 1MB.

The window gets `remain-on-exit`, so it survives its command exiting,
and the window option `@kido_subagent`, valued `run=<id>
parent=<instance> depth=<n>`. The mark is what makes the window a
subagent's to every reader that comes later: the sweep, the sidebar's
tree, and the window-cycling keys all key off it, because a state record
is deleted within a tick of its process dying and the mark lasts as long
as the window (design.md, "Who is authoritative for what"). A window
that cannot be marked is killed rather than left uncollectable.

The tool returns `spawned <name> (window @N, pane %N, run <id>)` at
once. It does not wait for anything the child does.

## Forking the caller's context

`spawn_subagent(fork: true)`, `kido spawn_subagent --fork SESSION_ID`,
starts the child as `pi --fork <session> --session-id <run-id>` with the
task as its first message - everything else is a fresh spawn's own path:
the same `createRunWindow` and `runEnv`, its own run id, parent edge,
mark, depth ceiling, tool allowlist and model handling. What changes is
where the child's context comes from. It starts holding the caller's
whole transcript, so it can be given a judgement to make - a merge, a
decision between two things the parent already weighed - without the
parent having to restate what it decided and why.

The two flags compose, which is what makes this possible at all: measured
against pi 0.85.1, `createSessionManager` (`main.js`) forks the resolved
source through `SessionManager.forkFrom(..., { id: sessionId })`, so the
forked session is created *with* the id kido asked for, and it refuses up
front if a session already holds that id. Verified by running it: a
session told to say BANANA, forked with `--fork <id> --session-id <new
id>`, answered BANANA when asked what it had said before, under the new
id's own session file. That matters beyond convenience - the run id is
the child's session id, and a child proves it is the run it claims to be
by `sessionId() === KIDO_AGENT_RUN_ID` (design.md, "The run id is the
child's session id"). A fork that could not be given an id would be a
child with no identity proof, and would be no child at all.

The session forked is the **caller's own**, and the extension passes it
(pi hands it the id) rather than kido guessing it from a pane. Nothing
resolves a session a model named: there is exactly one right answer, and
it is not the model's to give.

**A fork replays the parent's whole context on every turn.** That is the
cost, it is per-turn rather than once, and it is why this is for a short
judgement step and not for a long worker: a child forked from a large
conversation pays for it again with every tool call it makes. A worker
wants a task and a clean context.

The flag reaches tmux's command line, so it is held to the window name's
rule (`tmuxConfUnsafe`) and refused rather than quoted. `--fork` and
`--resume` together are refused: one continues a run's own session and
the other starts a new one from somebody else's. Nothing checks that the
source session exists, unlike `--resume` - the source is the caller's own
live session, which by construction does, and pi's own error lands in the
child's window if it somehow does not.

## The run record

Each spawn owns `<state>/runs/<run-id>/`, written before the window is
created so the child can read its task the instant tmux starts it:

- `task`, the text as given, never deleted;
- `delivered`, written by the child after it has read the task, so a
  `/reload` does not deliver it twice;
- `meta.json`, the name, parent instance, depth, window, pane, pid,
  cwd, model, tools, `keepAlive` and start time - everything a spawn was
  given that a resume has to start it with again, which is why `keepAlive`
  is there at all (design.md, "Idle self-exit, and resuming a run");
- `outcome`, once the run has ended: `completed` or `failed` from the
  child itself, `died` from a sweep, `stopped` from `kido stop_subagent`;
- `report`, for a `notify_parent` report too long to send whole - the
  text as the child wrote it, which the parent's notice names ("A child's
  life", below);
- `command` and `output`, for a bash run only: the argv the wrapper
  execs and everything the command wrote (see "An async bash run");
- `screen`, the window's last screen and a bounded tail of scrollback,
  captured by the sweep before it closes the window.

An outcome is written once and never overwritten; the rules for who
writes which, and why `stopped` wins a race against `completed`, are
design.md's "Run outcomes". `kido runs` lists every run, most recent
first, or shows one with its task, its screen if any, and the command
to resume it. A run with no outcome and a dead pid is shown as `died`
without that guess being written down. Nothing prunes the directory.

## A child's life

**Start.** The child's extension reads the task file and delivers it
as its first user message, the way an inbox prompt is delivered, after
its own inbox is bound so the first turn can already be asked things.
From then on a standing instruction rides on every turn's system
prompt: you were spawned, call `notify_parent` when the work is done or
blocked, and a reply to another agent's question is the whole response.
It rides the system prompt rather than the task because a task is
delivered once, and a resume or a follow-up message from the parent
would otherwise leave the instruction behind.

**Watching the parent.** The child's pi is a child of the tmux server,
so no signal tells it the parent has gone. It polls every five seconds:
`kill(pid, 0)` first, where ESRCH is definite and ends the session on
that poll without spawning anything; a live pid is not proof, since pids
are recycled, so anything else asks `kido agent-alive <parent-instance>`
and acts on the answer, on one reading. That command reads every live
state record and answers whether one reports that instance - the same
question the orphan sweep asks, of the same registry. It replaced `kido
agents --json`, which was a display asked a liveness question: that view
keeps one record per pane, so a `pi --print` inside the parent's pane
took the pane and the parent's record was missing from the answer
altogether, and a two-poll debounce rode that out rather than fixing it.
The debounce is gone with the reason for it, and the poll also no longer
lists panes, which is one process and no tmux round trip every five
seconds per child. kido failing to answer remains the one inconclusive
case and is never evidence. On a dead parent the child shuts itself down
through the same path a normal exit takes.

**Reporting.** Nothing reports for the child. It calls `notify_parent`
itself, once, when its model judges the work done; the summary goes to
the parent as a `notice` envelope and nowhere else, addressed to the
instance in its own environment rather than to anything it looked up.

A report is **kept whole**. The notice is spliced into the parent's next
turn, so what the parent is sent is bounded at 4000 bytes - but the bound
used to be applied by throwing the rest away, in the tool, and a report
over it reached its parent cut mid-sentence with no sign there had been
more. Now `kido notify_parent` writes the full text to the sender's own
run directory as `report`, beside `task` and `output`, and sends the head
of it plus a final line naming that file:

    full report: <state>/runs/<run-id>/report

Head and line together stay inside the cap, so the notice is no larger
than it ever was. A report within the cap is delivered byte for byte and
leaves no file: nothing was lost, so there is nothing to point at. The
head is cut back off a partial rune, because the send path refuses a
message that is not valid UTF-8 outright - `tailOfFile`'s rule
(`ending_notice.go`) in the other direction. A sender with no run
directory - a session kido never spawned, carrying somebody else's parent
edge - has nowhere to keep it and is truncated as before; so is one whose
write fails, since the point of the call is that the parent hears
something. `kido runs <id>` gains one line, `report:`, for a run that
left one.
An automatic notice on every settled turn was removed, because a turn
settles for reasons that are not the task - most sharply, answering a
sibling's `ask_agent` settled a turn and sent the parent a report meant
for the sibling
(design.md, "Notifying the parent").

What the child says about its work is therefore still its own to say.
But an **ending** is not a judgement, and a child that ends without ever
calling the tool now produces exactly one notice saying so - naming the
run, the outcome recorded for it, the run id and `spawn_subagent(resume:)` to
pick it up. It claims nothing about the work; it says only that the run
ended and nothing was said about it, which is a fact any observer can
establish. The parent used to learn nothing at all here, and a parent
that had dispatched work and gone quiet waiting for a report waited for
one that was never coming.

Two observers can send it, and they are the two ways a run can end
silently:

- the child's own shutdown - an idle self-exit, a quit, a lost parent -
  when `notify_parent` was not called in this session. It is sent from
  where the outcome is recorded, `kido run-outcome --unreported`;
- a sweep, for a run whose window is gone or dead with no outcome
  recorded at all: the crash, the kill, the window closed by hand.

Which of them speaks is settled the way every other ending is, by the
O_EXCL outcome write ("Exactly one ending", below), so a run stopped
from outside - whose stopper has already spoken, and whose outcome is
already on disk - produces nothing extra when its child gets round to
shutting down.

On the parent's side a notice is rendered the moment it lands, as a
`notification from <name>` line above the editor, and separately
enters the model's context at the next turn boundary as a collapsed
message that ctrl-o expands. Those used to be one event, and two
children's notices sat invisible until the parent's long turn ended.
A notice is steered rather than queued as a follow-up, so a parent
mid-turn sees it between tool calls and decides for itself whether to
act - as a `steer` envelope is, and for the same reason ("What steers
and what queues", above); a message and an ask still wait for the turn.

**Idle self-exit.** A child - the real one, by the session-id test above
- that has settled a turn and stayed idle for thirty seconds calls pi's
own shutdown on itself, unless it was spawned with `keepAlive`. Any new
work, or a message about to be delivered, restarts the clock. A window
some client is looking at is not taken
away; the timer re-arms and tries again later. A root session, one with
no parent in its environment, never arms it.

**A session with a live child of its own is not idle**, however quiet it
has been. "I have spawned it and I am waiting for its report" settles a
turn exactly as finished work does, and the clock could not tell them
apart: a parent shut itself down thirty seconds after spawning, and the
orphan rule then closed the child it was waiting for, mid-work. So the
timer asks `kido children-alive <instance>` first and re-arms if the
answer is yes, exactly as it does for a focused window. The last child
ending resumes the clock, as does that child's notice, which is new work
like any other.

The reading is of the **run records**, not of anything the session
remembers: a run whose meta names this instance as its parent and which
has not ended - no outcome recorded, and a pid still alive, which is what
`kido runs` shows as running. A child outlives the turn that spawned it
and a `/reload` forgets everything in memory, while the record is the
durable half and is where a parent edge lives. A child whose process is
gone but whose outcome has not landed yet reads as ended, which is the
safe direction: a parent held open by a corpse would never go idle again.
kido being unreachable reads the same way, leaving the behaviour the
clock had before there was a query at all.

**Shutdown.** Whether it quit, self-exited, was stopped, or lost its
parent, the child runs one teardown: the parent poll and idle timer
stop, every waiting ask is released, the inbox closes, the outcome is
recorded (`completed` if the session was idle, else `failed`, and
`--unreported` alongside it if the session never called `notify_parent`),
the record is removed, and a detached helper is spawned to run
`kido close-window` after the linger. A `/reload` runs the same handler
and does none of the run-ending parts, since the run carries on.

**The window.** The helper closes the window after thirty seconds
unless a client is in it or it is the session's last. The sidebar's
sweep is the backstop: a marked window whose panes are all dead for the
same thirty seconds is closed, its screen captured and `died` recorded
if nothing else was. Two thirty-second clocks stack, so up to a minute
can pass between a child's last turn and its window going (design.md,
"Window lifecycle" and "Idle self-exit, and resuming a run").

## Redirecting one, and ending one from outside

`steer_subagent` leaves the turn running and joins it: the text arrives
inside the loop, so the child reads it between tool calls and continues
with the correction instead of starting over. It is labelled with its
sender on arrival, since an instruction landing mid-task would otherwise
read as if the child had thought of it itself. `interrupt_subagent`
aborts the target's current turn and leaves it idle with its context
intact. `stop_subagent` asks it to shut down, waits up to five seconds
for its record to go, and kills its pane if it is still there; a target
with no inbox, or a stale one, is killed outright and only with `force`.
All three reach descendants only, checked twice: by kido before sending
and by the receiving extension on arrival, since the sender field is
advisory. A human at the CLI, with
no record, may act on anything (design.md, "Steer, interrupt and
stop").

An orphan is the sweep's business. A live marked window whose child
names a parent instance no live record claims is closed, on one
reading. The reading is trustworthy because of what it is taken from:
every live record, not the per-pane view `state.Load` returns. In that
view a `pi --print` started inside an agent's pane inherits that pane
and wins it for as long as it reports, and the real parent is then not
in what the sweep was handed at all - so its children were killed with
nothing wrong with them. A debounce used to absorb that. Asking the
whole registry instead makes the collision irrelevant: it settles who
owns a pane, and the sweep only ever asks whether an instance is
running somewhere. A one-shot `kido reap` applies this rule too, since
nothing needs a second sweep any more.

## Resuming a run

`kido spawn_subagent --resume <run-id>` puts a finished or dead run back in
a window: `pi --session <run-id>` at the run's own directory, under the
run's original name, with the model its meta recorded unless the command
after `--` names one, through the same window creation and mark as a fresh
spawn. The run record continues rather than doubling; its old outcome and
screen are cleared. It refuses a run still alive, one with no pi session
file, and one whose pi session lives under a `sessionDir` setting kido does
not read.

The run comes back as what it was: its recorded model, tool allowlist and
`keepAlive`, unless the caller overrides them after `--` (design.md,
"Idle self-exit, and resuming a run").

The parent edge is whoever resumes. Given `--parent-pid` and
`--parent-instance`, they are used; omitted, they default to the
caller's own record, so an agent resuming becomes the run's new parent
and a human at a bare shell resumes a parentless session that will not
self-exit. `--no-parent` asks for that outright, so an agent that does
have a record can hand a run over instead of adopting it. A named instance must belong to a live agent, checked before
the window exists: the sweep keeps no history, and a stale edge would
have the window closed as an orphan within seconds with nothing to say
why. `spawn_subagent(resume)` always passes the caller's own live
identity, and refuses `task`, `name` or `fork` alongside `resume` rather
than guessing which the model wanted. The `pi --fork <run-id>` line `kido
runs` prints stays a bare command: forking a *finished run* from a shell
is a standalone session with no record, which is a different thing from
`spawn_subagent(fork)` forking the *caller's live session* into a child
that has one ("Forking the caller's context", above).

## An async bash run

`kido async_bash [--name NAME] [--stream] -- COMMAND...` runs a command in a
detached window of its own and tells the caller once it has ended. It is
structurally a spawn whose child is a command rather than a pi session:
the same `createRunWindow`, the same `runEnv`, the same `@kido_subagent`
mark, the same run record and the same sweep. `meta.json` carries a
`kind` - `agent` or `bash`, absent meaning `agent` - and that is the
whole of what distinguishes the two records.

One word after `--` is a shell command line and is run under `bash -c`,
which is the shape a model writes ("make -j8 && ./run"); several words
are an argv and are exec'd as given. Either way what will run is written
to the run's `command` file before the window exists, and the window's
own command line is only ever `kido async-run --run-id ID --name NAME` -
model-authored text never reaches tmux's parser. `--name` is optional;
without one the window is named after the first word of the command.

The parent is the caller's own state record, found from `$TMUX_PANE`,
rather than a flag: this command is run by whoever is at the pane, and
that record is the only honest answer to who should be told. A caller
with no record - a human's shell - has no parent, and the run then
records its outcome and tells nobody. The depth ceiling a spawn is held
to does not apply, since a bash run starts no agents: an agent at the
ceiling may still run a build.

**The wrapper.** `kido async-run` is the window's command and the whole
of the completion mechanism. It reads the run's argv, runs it with stdout
and stderr teed to the run's `output` file and to the pane, waits, and
learns the exit status from `wait(2)` rather than from anything tmux
observed. Then, in this order and never concurrently:

1. the outcome: `completed` for exit 0, `failed` otherwise, with the
   status as its text ("exit status 3", "signal: killed");
2. the completion notice, once, to the parent - a `notice` envelope over
   the parent's inbox, addressed to the instance in its own environment
   and needing no record of its own, exactly as a spawned child's report
   home is.

Everything is reported **before this process exits**, which is what makes
the feature independent of the window surviving. tmux sets
`remain-on-exit` in a second call after `new-window` and a fast command
beats it every time, so a window running `true` is usually gone before
kido can finish creating it; the run record and the notice are already
written, and what the race costs is the corpse on screen. Finding the
window gone is therefore not a creation failure: the mark is skipped, no
outcome is recorded over the command's own, and the ids are printed as
usual.

That tolerance is the **bash** case and says so in the code: it rests
entirely on there being a wrapper in the window that has already spoken
for the run. An agent spawn losing the same race keeps the failure it
has always recorded, because nothing else will ever describe that run -
a window tmux has lost carries no marked pane, so neither sweep rule can
reach it, and a pi that vanished that fast never got to its task.

What `kido async_bash` prints is the spawn line with a fourth field, the
run's output file. Where kido keeps a run's output is kido's own to say,
and a tool rebuilding the path would be a second copy of `state.Dir`'s
`KIDO_STATE_DIR`/XDG precedence - so the one call the tool makes answers
it.

The notice names the run itself:

    async run "build" failed: exit status 3
    run: 6f1c...
    output: <state>/runs/6f1c.../output
    --- last 4000 bytes of output (12034 omitted) ---
    ...

It has to, twice over: the envelope's `from` names the run as well, and
for the same reason. A bash run writes no state record, so the sender
kido can fill in is whichever *process* observed the ending - the
wrapper's own pane, which is no agent, leaving a parent reading
"notification from %47", or a sweeping sidebar, or the unrelated agent
that typed `kido stop_subagent`. The run's name is the only honest
answer, and it is what the parent's widget row shows.

The output file is the source of truth
and is never truncated; the notice carries its last 4000 bytes, the tail
rather than the head because what a failure has to say, it says last, cut
back to a whole rune so a log ending mid-character cannot cost the run
its only notice.

**Exactly one ending.** Every async run produces exactly one terminal
notice, from whichever observer discovers the ending - including the
ones that discover it by finding a corpse. Never zero, or a model waits
forever on a build that has already stopped existing; never two, or it
acts twice.

The winner of the outcome write is the sender of the notice.
`RecordOutcome` is already a once-only, crash-safe arbiter of exactly
this question (O_EXCL), so nothing else is introduced to decide it: not
a flag, not a "notified" marker, the same write read the same way. Three
observers can win it:

| Observer | Discovers the ending | Records | Notifies |
|---|---|---|---|
| the wrapper | its own `wait(2)`, or a signal it can catch | `completed`/`failed` | yes, with the exit status |
| a sweep's rule 1 (`internal/reap`) | a marked window dead for the linger | `failed`, "ended without its wrapper reporting" | yes, if it won |
| `kido stop_subagent` | a deliberate stop | `stopped`, naming itself | yes, if it won |

The wrapper covers every ending it lives to see, which is why `SIGTERM`,
`SIGHUP` and `SIGINT` are passed on to the command and then reported as
`failed` on the wrapper's own way out. `SIGKILL` is not survivable, and
neither is having the window killed under it or the process tree taken
away: those leave a marked window with dead panes and no outcome, which
is exactly what rule 1 finds. It used to record `died` and say nothing,
and the parent of a killed build waited forever.

Both kinds of run are spoken for this way, but not with the same claim.
A bash process's completion is an exit code, and the notice reports it;
an agent's completion is a judgement only the model can make, so the
notice for an agent run reports only that the run ended and nobody spoke
for it ("Reporting", above) - the outcome recorded is still the `died`
it always was. A run with no parent instance is told to nobody either
way, which is what `kido async_bash` typed at a human's shell produces.

The three observers share one notice builder (`cmd/kido`'s
`asyncNotice`), so a parent cannot tell how its build ended by which
process happened to notice, and write-then-decide is one function
(`reap.RecordEnding`) for the observers that find an ending from outside
the run, so a third finds a call site rather than reimplementing the
invariant. The wrapper writes for itself: it is inside the run's own
process, holds no meta file, and is the one observer that can tell a
write failing from a write lost. The sweep itself sends nothing: `reap.Sweep`
returns the runs whose parents are now the caller's to tell, and the
caller - `kido reap`, or the sidebar through a seam `main` fills in -
does the sending. A window sweep has no business knowing what an inbox
is, and the one thing it can know is that a run ended with nothing said
about it.

**Stopping one.** `kido stop_subagent --force -- <name>` ends a run,
addressed by the name or the run id `kido async_bash` printed. A run has
no state record for the usual target resolution to find, so stop matches
it against the runs that have no outcome yet - a finished run can never
shadow a live agent - and applies the same scope rule every `_subagent`
command shares to the only parent edge a run has, the instance in its
meta. `--force` is required for the reason it always is: a bash run has
no inbox to ask nicely over, so stopping it degrades straight to killing
something.

The stop signals the wrapper first and waits out the stop escalation,
because a wrapper that is still there reports the ending itself with the
exit status and the output tail the stop could only guess at. Only if it
does not report does the stop record and send its own notice - and a
wrapper that is already gone is not waited for at all, since waiting
would delay a notice nobody else was ever going to send. Each observer's
outcome text says which of them it was.

Apart from stop, a bash run is deliberately not an agent. It has no state
record, so it is not in `kido list_agents`, cannot be addressed by
`message_agent` or `ask_agent`, and has no status to report - there is
nothing there to answer. What it has is the run record, which is already
the store for facts that outlive a process, and `kido runs` shows it like
any other.

## Streaming a run's output

`async_bash(command, name?, stream?)` and `kido async_bash --stream` ask
for the command's output as it arrives, not only at the end. The tool
surface is one boolean because the capability is one flag deep; a second
tool would be a second name for it, and every tool invokes the
subcommand of its own name.

The reason a line is not an envelope is pi's own delivery model.
Measured against 0.85.1, the steering queue drains **one** message per
poll by default (`PendingMessageQueue.drain`, `steeringMode` defaulting
to `one-at-a-time`), and every drained message is one LLM call carrying
the whole context. One envelope per line would therefore be one turn per
line: a thousand-line build takes the agent hostage at a cost quadratic
in its output. What makes streaming affordable is not rate limiting,
which only lengthens that, but **coalescing** at both ends - and one
fact about pi's loop: extension `turn_end` handlers are awaited before
the loop polls the steering queue (`agent.js`'s emit, `agent-session.js`
forwarding `turn_end` with `await`, `agent-loop.js` polling after it), so
a message enqueued from inside that handler is drained by the very next
poll, riding a call the agent was already going to make.

**The wrapper's side.** With `--stream`, `kido async-run` tees into a
third writer that batches whole lines and sends one `stream` envelope
per 250ms or 4KB, whichever comes first, with ANSI escapes and control
bytes stripped from what travels (the output file keeps the bytes as
written). A line the command has not finished writing waits for the next
batch, or for the close. The parent's inbox is resolved **once** and
held, and re-resolved only after a failed send: `send()`'s own
resolution is a state-directory read plus a tmux pane listing, which is
right for one notice and not for a chunk stream.

Nothing about it may cost the command anything. The tee to the output
file is unconditional and is the source of truth; the stream is
best-effort from a bounded buffer, written to by the copy goroutine
under a mutex and sent by one goroutine of its own. A failed or stalled
send drops its chunk rather than retrying it - a build's output
redelivered late and out of order is worse than absent, and the file has
all of it - and takes a doubling backoff before the next attempt. A
buffer past 64KB drops its own oldest lines, so what survives a slow
parent is the tail. Per run, 256KB may be streamed; past that the stream
says so once and goes quiet.

Every line the parent did not acknowledge is counted, and the count goes
in the completion notice (`N lines not streamed`), so a model that
watched output arrive is never left believing it saw all of it. The
notice is sent **after** the final chunk - the stream is closed, which
flushes and waits for anything in flight, before the notice is built -
because the wire is one connection per message with no sequencing, and
the only ordering available is that the wrapper sends nothing
concurrently.

**The receiver's side.** A `stream` envelope is the one kind that
reaches nobody on arrival: `kido-agents.ts` appends its lines to a
per-run buffer, and the buffer is handed to the model as **one**
collapsed custom message at one of three moments:

- at `turn_end`, **only if that turn ran tools**. This guard is the
  whole of why streaming is affordable, and it is one `if`. A turn with
  tool calls has its next LLM call already committed, so the batch costs
  zero extra turns. A turn without them was the agent stopping: flushing
  there buys a turn, that turn's own `turn_end` has no tool calls
  either, more lines arrive while it runs, and the loop ends when the
  command does - the seizure this design exists to avoid, re-entering
  through the coalesced channel.
- otherwise on a backoff schedule - 10s, then 20s, 40s, ..., capped at
  300s - each flush costing one genuine turn. The first wakes are
  frequent, which is when an early failure is worth seeing; the later
  ones are sparse, which is when there is nothing to do but wait. One
  timer for the session, not one per run.
- immediately before a run's completion notice, which also resets the
  schedule, so the model never reads "this is how it ended" above the
  output it is the ending of.

A batch carries the last 200 lines or 16KB, whichever binds first, under
one line reading `... N lines omitted (see <path>)` - N counting both
what the cap cut and what the held buffer (5000 lines) dropped while
waiting for a turn, since one number is the only one a model can act on. Tail, not head, for
the reason the completion notice carries one. The run's name is on the
row and in the batch's first line, because a bash run has no state
record and the label would otherwise fall through to a pane id.

What this costs, stated plainly: while the agent is working, the stream
costs it context bytes and no turns at all; while it is idle, a
ten-minute build wakes it about six times and an hour-long one about
sixteen. `stream` defaults to off.

## A human at a shell

The commands are the tools' commands, but nothing stops a human from
running them, and doing so is a supported path rather than an accident.
What a bare shell has is a pane with no state record: no inbox, no
instance, no parent, depth 0. Every difference follows from that one
fact.

What works:

- `kido message_agent` - the one-way send, which needs nothing of the
  sender. An agent with an inbox gets a real user message; one without
  gets a paste.
- `kido spawn_subagent --no-parent` - a standalone agent in a window,
  owned by nobody (design.md, "A parentless spawn, and a parent that
  must exist"). Naming a live agent with `--parent-pid`/`--parent-instance`
  works too and makes the child that agent's; naming a dead or invented
  one is refused, not spawned.
- `kido spawn_subagent --resume <id>` - parentless by default from an
  untracked pane, and `--no-parent` from a tracked one. The line
  `kido runs <id>` prints is exactly this.
- `kido steer_subagent`, `interrupt_subagent`, `stop_subagent` - a caller
  with no record is nobody's ancestor, and is allowed to act on anything
  rather than nothing (design.md, "Steer, interrupt and stop").
- `kido list_agents`, `kido runs`, `kido reap` - all read-only or
  read-mostly, and none of them ask who is calling.

What is refused, each naming what to do instead:

- `kido ask_agent` - the answer can only arrive on the asker's inbox, and
  a shell has none. This used to deliver, interrupting the target with a
  question it could not answer.
- `kido notify_parent` - a shell was not spawned, so there is nobody to
  tell.
- `kido set_status` - there is no record to set an activity on.

The one thing to know about the child of a `--no-parent` spawn is that
nothing will ever collect it: no idle self-exit, no orphan rule, no
report home. It is the user's window to close.

## In the sidebar

A subagent's window is drawn indented under the pane that spawned it,
not after that agent's whole window, with the parent window's bracket
carried down a `│` stem beside it. Children of one pane are grouped with
`├` and `└` on their first rows, so ownership reads at a glance - an only
child included, which gets a `└` rather than its own dot: on a subagent's
row, which child you are is worth more than how many panes your own
window has, the same trade grouping already made. A multi-pane subagent
window still closes with its own `└` on the row below, now one column
further in. A one-pane window that is nobody's child keeps its dot; only
an anchored window is affected. The anchor is the parent edge
the walk found, from the child's record while it exists and from the
mark's `parent=` token once the record is gone, so a finished child
stays nested while its window lingers. A child whose parent is in
another session, or gone, is drawn as a root.

A lingering window carries its run's verdict in the field column: a
dimmed `✓` for a run that completed, and a dimmed `×` for every other
outcome - `failed`, `died`, and `stopped` too, since ending something on
purpose did not fail but did not finish the work either. A window whose
outcome has not landed yet keeps the `×`: the outcome arriving is what
turns that row from a name into a verdict, and claiming success a tick
early is the one lie this column could tell. Why the dim `✓` does not
collide with the green one a live agent gets for a finished turn is on
`indicatorGone` (internal/ui), which owns the argument.

The cost is that hoisted windows leave tmux's own order. Shift-Up and
Shift-Down skip any marked window, dead or alive, so the keys cycle the
windows the user opened and a subagent's is reached through the
sidebar. Skipping a dead one without a liveness test is deliberate: the
key would otherwise change behaviour under the user's fingers as a
window aged out.

## Limits

- A child that crashes or is reaped before calling `notify_parent`
  tells its parent that it ended and nothing else: one notice with the
  run's name, its outcome, its id and how to resume it. Nothing
  reconstructs what the work had reached - the run record and the
  captured screen are what remain of that.
- A child that is shutting down on its own notice when its parent dies
  can have its window closed mid-exit and be recorded as `died` rather
  than recording its own outcome. Whatever it managed to write first
  wins (`RecordOutcome` is O_EXCL).
- Nesting stops at depth 2 and no flag raises it.
- A `--no-parent` child is nobody's to collect: no idle self-exit, no
  orphan rule, no report home. Its window is the user's to close. Its
  depth is still derived from whoever spawned it, so a parentless child
  of an agent at depth 1 sits at 2 and can spawn nothing itself.
- `kido ask_agent` cannot be used from a shell at all, by design: there
  is nowhere for the answer to arrive. A human wanting a round trip has
  to be a long-lived process, or use `message_agent` and read the reply
  on screen.
- A blocked `ask_agent` holds the asker's whole turn. The wait is not
  one turn of the target's latency but however long the target takes to
  reach the end of whatever it is already doing, plus a turn: an ask is
  delivered as `followUp`, so a busy target does not see the question
  until it would otherwise have stopped. That is deliberate, not an
  accident of scheduling - it is what keeps two correlated replies from
  interleaving (design.md, "Steer and followUp") - but it means a parent
  asking three working children serially is idle a long time. A
  correction that cannot wait that long is `steer_subagent`, which is
  not correlated and so need not queue.
- `--resume` does not honour pi's own `sessionDir` setting when looking
  for the session file.
- A child that exits before `remain-on-exit` is set loses its window
  and its last screen; only the run record remains. For a bash run that
  is only the screen: the wrapper has already recorded and reported. For
  an agent run the spawn itself reports the failure, which is the whole
  account of it there will be.
- The orphan rule does not reach a bash run - rule 2 reads state
  records, and a bash run has none - so a run whose parent has died
  keeps going until the command ends.
- A subagent's window moved to another tmux session is outside its
  parent's scope and cannot be reached.
- Everything assumes one machine: shared filesystem, shared pid
  namespace, a kido binary beside every agent.
