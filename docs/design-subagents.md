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

Every tool shells out to a `kido` subcommand, so the e2e suite, which
cannot host a TypeScript extension, drives the same paths through fake
agent binaries.

| tool | command |
|---|---|
| `list_agents()` | `kido agents --json` |
| `set_status(activity)` | `kido agent-status --activity` |
| `message_agent(to, message, replyTo?)` | `kido message [--kind reply --reply-to ID] -- <to>` |
| `ask_agent(to, question, timeoutMs?)` | `kido message --kind ask --id ID -- <to>` |
| `spawn_subagent(task, name?, model?, tools?, keepAlive?)` | `kido spawn` |
| `spawn_subagent(resume, model?, tools?, keepAlive?)` | `kido spawn --resume` |
| `interrupt_subagent(to)` | `kido interrupt -- <to>` |
| `stop_subagent(to, force?)` | `kido stop [--force] -- <to>` |
| `notify_parent(summary)` | `kido message --kind notice -- <parent>` |

There is no `kido ask`: the answer arrives on the asker's own inbox,
and only a long-lived process has one (design.md, "Ask and reply").
Tools register unconditionally and report kido as unavailable until a
session has resolved it. `set_status` and `notify_parent` cap their
text by truncating, at 256 and 4000 bytes, and their schemas do not
repeat the cap as a `maxLength`: that counts UTF-16 code units and
rejects the whole call, which cost a subagent a redo of its one report.

`list_agents` returns every agent whose pane is in the caller's tmux
session, itself included, ordered parent-first: id, name, agent, pane,
window, status, activity, parent, depth, self, cwd, model, `canMessage`
(whether it has an inbox; a Claude Code session is visible but only
reachable by paste), `sinceReport` and `stalled`. Sessions in another
tmux session are not listed, and nothing here can reach them.

## What a child is given

`kido spawn` reads the caller's pane from `$TMUX_PANE`, and from it the
tmux session, the working directory, and the caller's own state record.
It creates a detached window in that session, named as asked, at the
caller's directory, running the command after `--` or plain `pi`. When
the command is literally `pi`, `--session-id <run-id>` is inserted after
it, so the run id is the child's pi session id and there is no mapping
to keep. The extension adds `--name`, and passes `--model` and `--tools`
through when given; a narrow toolset is the blast-radius bound the
depth ceiling is not.

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

## The run record

Each spawn owns `<state>/runs/<run-id>/`, written before the window is
created so the child can read its task the instant tmux starts it:

- `task`, the text as given, never deleted;
- `delivered`, written by the child after it has read the task, so a
  `/reload` does not deliver it twice;
- `meta.json`, the name, parent instance, depth, window, pane, pid,
  cwd, model, tools and start time;
- `outcome`, once the run has ended: `completed` or `failed` from the
  child itself, `died` from a sweep, `stopped` from `kido stop`;
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
the parent as a `notice` envelope and nowhere else. An automatic notice
on every settled turn was removed, because a turn settles for reasons
that are not the task - most sharply, answering a sibling's `ask_agent`
settled a turn and sent the parent a report meant for the sibling
(design.md, "Notifying the parent"). The price is stated there and
stands here: a child that crashes, or is reaped without ever calling
the tool, tells its parent nothing, and the run record is what is left.

On the parent's side a notice is rendered the moment it lands, as a
`notification from <name>` line above the editor, and separately
enters the model's context at the next turn boundary as a collapsed
message that ctrl-o expands. Those used to be one event, and two
children's notices sat invisible until the parent's long turn ended.
A notice is steered rather than queued as a follow-up, so a parent
mid-turn sees it between tool calls and decides for itself whether to
act; every other kind still waits for the turn.

**Idle self-exit.** A child - the real one, by the session-id test above
- that has settled a turn and stayed idle for thirty seconds calls pi's
own shutdown on itself, unless it was spawned with `keepAlive`. Any new
work, or a message about to be delivered, restarts the clock. A window
some client is looking at is not taken
away; the timer re-arms and tries again later. A root session, one with
no parent in its environment, never arms it.

**Shutdown.** Whether it quit, self-exited, was stopped, or lost its
parent, the child runs one teardown: the parent poll and idle timer
stop, every waiting ask is released, the inbox closes, the outcome is
recorded (`completed` if the session was idle, else `failed`), the
record is removed, and a detached helper is spawned to run
`kido close-window` after the linger. A `/reload` runs the same handler
and does none of the run-ending parts, since the run carries on.

**The window.** The helper closes the window after thirty seconds
unless a client is in it or it is the session's last. The sidebar's
sweep is the backstop: a marked window whose panes are all dead for the
same thirty seconds is closed, its screen captured and `died` recorded
if nothing else was. Two thirty-second clocks stack, so up to a minute
can pass between a child's last turn and its window going (design.md,
"Window lifecycle" and "Idle self-exit, and resuming a run").

## Ending one from outside

`interrupt_subagent` aborts the target's current turn and leaves it
idle with its context intact. `stop_subagent` asks it to shut down,
waits up to five seconds for its record to go, and kills its pane if it
is still there; a target with no inbox, or a stale one, is killed
outright and only with `force`. Both reach descendants only, checked
twice: by kido before sending and by the receiving extension on
arrival, since the sender field is advisory. A human at the CLI, with
no record, may act on anything (design.md, "Interrupt and stop").

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

`kido spawn --resume <run-id>` puts a finished or dead run back in a
window: `pi --session <run-id>` at the run's own directory, under the
run's original name, with the model its meta recorded unless the
command after `--` names one, through the same window creation and
mark as a fresh spawn. The run record continues rather than doubling;
its old outcome and screen are cleared. It refuses a run still alive,
one with no pi session file, and one whose pi session lives under a
`sessionDir` setting kido does not read.

The parent edge is whoever resumes. Given `--parent-pid` and
`--parent-instance`, they are used; omitted, they default to the
caller's own record, so an agent resuming becomes the run's new parent
and a human at a bare shell resumes a parentless session that will not
self-exit. A named instance must belong to a live agent, checked before
the window exists: the sweep keeps no history, and a stale edge would
have the window closed as an orphan within seconds with nothing to say
why. `spawn_subagent(resume)` always passes the caller's own live
identity, and refuses `task` or `name` alongside `resume` rather than
guessing which the model wanted. `pi --fork <run-id>` stays a bare
command; a fork is a standalone session with no record.

## In the sidebar

A subagent's window is drawn indented under the pane that spawned it,
not after that agent's whole window, with the parent window's bracket
carried down a `│` stem beside it. Several children of one pane are
grouped with `├` and `└` on their first rows, so ownership reads at a
glance; a lone child keeps its own dot. The anchor is the parent edge
the walk found, from the child's record while it exists and from the
mark's `parent=` token once the record is gone, so a finished child
stays nested while its window lingers. A child whose parent is in
another session, or gone, is drawn as a root.

The cost is that hoisted windows leave tmux's own order. Shift-Up and
Shift-Down skip any marked window, dead or alive, so the keys cycle the
windows the user opened and a subagent's is reached through the
sidebar. Skipping a dead one without a liveness test is deliberate: the
key would otherwise change behaviour under the user's fingers as a
window aged out.

## Limits

- A child that crashes or is reaped before calling `notify_parent`
  tells its parent nothing. The run record and the captured screen are
  what remain.
- A child that is shutting down on its own notice when its parent dies
  can have its window closed mid-exit and be recorded as `died` rather
  than recording its own outcome. Whatever it managed to write first
  wins (`RecordOutcome` is O_EXCL).
- Nesting stops at depth 2 and no flag raises it.
- A blocked `ask_agent` holds the asker's whole turn, for one turn of
  the target's latency; a parent asking three children serially is idle
  a long time.
- `--resume` does not honour pi's own `sessionDir` setting when looking
  for the session file.
- A child that exits before `remain-on-exit` is set loses its window
  and its last screen; only the run record remains.
- A subagent's window moved to another tmux session is outside its
  parent's scope and cannot be reached.
- Everything assumes one machine: shared filesystem, shared pid
  namespace, a kido binary beside every agent.
