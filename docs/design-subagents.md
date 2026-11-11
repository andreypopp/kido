# Subagents, as built

A subagent is a pi session that another agent starts in a window of
its own. Its pane has the spawner's pane as its `parent` and `close:
on_exit`. ko keeps no record of an agent after its pane goes: the
parent's own pi session holds what the parent knows about its
children, and each harness keeps only its own facts. An agent's
background commands are jobs of its own harness, not panes ("A
job", below). This document follows a subagent from the
tool call that creates it to the sweep that removes its pane.

[design.md](design.md) describes the mechanisms that subagents use:

- The pi extension, ko-pi
- Messages
- Addressing
- Identity
- The window lifecycle

This document refers to those sections by name instead of repeating them.
`AGENTS.md` describes what ko cannot change.

**The principle.** ko is the mediator. The harness uses only ko's API
through `ko` commands. It never reads another agent's files and never
connects to another agent's socket. Every exchange between two agents
(a task, a message, a report, a stop, an ending) goes through ko.

## The tools, and what they call

The eight tools are in `share/pi/ko-pi.ts`. No tool has a ko
subcommand of its own.

| tool | what it uses |
|---|---|
| `list_agents(which?)` | `ko api /layout`, `/version`, the registry in the own session, which a top-level pi keeps with `ko api --stream /client` |
| `read_report(agent, which?)` | the own session's `ko-pi.report` entries |
| `list_async_bash()` | the process's job registry |
| `message_agent(to, message, mode?)` | `POST /panes/{t}/messages`; `POST /panes` to restart an ended child or peer |
| `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?, runtime?)` | pi's session directories, `pi --list-models`, `GET /runtimes/NAME`, `POST /panes` |
| `stop_agent(agent, force?)` | `POST /panes/{t}/messages` kind `stop`, then `POST /panes/{t}/stop` |
| `async_bash(command, name, stream?)` | a child process of pi through pi's shell configuration (a routed pi: `ko api --stream /runtimes/NAME/exec`) |
| `stop_async_bash(job)` | `signalJob` on the job's own process |

The parent of every child is `$KO_PANE`. A tool checks its own arguments and refuses them with a
reason, which the model reads as the tool result. Tools register
unconditionally and report ko as unavailable outside ko.

**Scope.** Every tool that acts on another agent acts on the agents of
the caller's scope: its children, its siblings, and each ancestor
with that ancestor's siblings, within its ko session (protocol.md,
section 7, the stop's scope). The server enforces the scope on every
send and stop; the harness resolves addresses over the same set only
to word its refusals. `stop_agent`, `steer` and `interrupt-and-steer`
thus reach a peer and an ancestor, not only a descendant. A child
that stops its parent removes itself a moment later through the
orphan rule.

**list_agents** lists the scope, without the caller. `which` selects
`all` (the default), `peers` or `subagents` (the caller's own). A
row is an `AgentRow` of `ko-pi.ts`. Its `id` is the pi session. Its
`status` is the root's OSC 7501 state, `starting` before the pane
has one, or `ended`. Its `runtime` is the row's field, else the `pi.runtime` of a host
pi agent; a routed agent's `cwd` is that variable's. Its
`canMessage` is the row's `inbox`: the pane's message stream is
open. An own child adds `model`, `reported` and `report`: the first
1000 bytes of its last report. `read_report` gives the rest. An
ended child is a registry entry whose pane is gone, dead or of
another server instance (`/version`'s `instance`); every ended child
lists, with `ended`, its cause or "its pane is gone". An ended
peer is a recorded peer ("Peers", below) whose session no live pi
agent pane runs, by the trust rule; it lists under `all` and `peers` as a peer with
`ended`, and only while its session file exists. The agents
come from the panes whose status kind is a pi agent (design.md, "The
trust rule") and from the caller's own children whose pane has not
yet published `pi.session`.

**read_report** returns the whole text of an own child's last report,
or with `which: all` every report in order with its time, from the
caller's own session. It never reads the child's session.

**list_async_bash** lists the caller's own jobs: all running and the
newest 20 ended, newest first. Each row names the job id, the name,
the command, the state, the end of an ended job, the start time, the
log and, for a routed job, the runtime.

A report notice has a bound of 4000 bytes. The parent keeps the
report whole, because it is a work product ("Reporting", below).

## The registry: the own pi session

Each harness appends custom entries to its own pi session with
`pi.appendEntry`. Every entry carries `owner`, the appending
session's id, and `at`; an entry whose `owner` is not the own
session id is ignored. Thus, a `--fork` or `/clone` copy, which
copies the entries, inherits no children and no reports. The
harness reads the entries with `ctx.sessionManager.getBranch()` at
each use, so a `/tree` back past a spawn drops the child from the
registry (Limits, below).

The registry rests on these facts of pi's session API, read in pi
1.4.0's `SessionManager`: a custom entry is a tree entry under the
leaf, so it belongs to its branch, and `getBranch()` returns only the
active branch's entries. `/fork` and `/clone` copy the path from the
root to the leaf with its custom entries under a new id, and the
CLI's `--fork` copies every entry of every branch; that is why an
entry carries `owner`. `--session-id ID` opens the file of that id in
the cwd's project directory, else it creates a new session with that
id, so a restart names only the id and the recorded cwd, never a file
path. pi writes the session file at the first user or assistant
message, not at `session_start`, so a child that never ran a turn has
no file.

In the parent:

| entry | when | data |
|---|---|---|
| `ko-pi.agent`, role `subagent` | at each spawn and restart | `name`, `session`, `model`, `fork`, `cwd`, the `runtime`, and `pane: { instance, pane }`; the last entry of a name is current |
| `ko-pi.agent`, role `peer` | when the `/client` stream shows a peer whose facts differ from its last entry, and at a top-level spawn or a peer restart (a top-level host pi only) | `name`, `session`, `cwd`; the last entry of a session is current |
| `ko-pi.work` | before it sends an own child work, in any mode, and at a spawn or restart with a task | `child` |
| `ko-pi.report` | when a child's report arrives, before the ack | `child`, `name`, `text`, `id` |
| `ko-pi.ended` | when it announces a child's ending, and when it stops the child | `child`, `pane` |

In the child:

| entry | when | data |
|---|---|---|
| `ko-pi.work` | when it delivers its task, and at `message_start` of a message or steer with `details.work` | none |
| `ko-pi.report` | before it sends a report | `text`, `id` |
| `ko-pi.sent` | when the parent acks or refuses a report | `id`, `refused` when refused |

**Has a child reported?** The parent's rule: its last `ko-pi.report`
for the child comes after its last `ko-pi.work` for it on the branch,
or it gave the child no work. The child's rule about itself is the
same over its own entries. The order is the position on the branch,
not a time, so there is no tie and no clock. Both are own facts:
nothing reads the other side.

## What a child is given

**Names.** `spawn_agent` and `async_bash` require `name`. The server
refuses a name over 64 bytes or with a control character (design.md,
"Spawning"); the harness also refuses an empty name, `.`, `..` and a
name with `/`. A child's name is unique among the caller's registry
children and its live own children. A job's name is unique,
case-insensitive, among the running jobs and the caller's registry
children: an ended job frees its name, so a watcher can start again
under its name. `stop_async_bash` by name takes the running job of
that name, else the newest ended one. A moved `bash` call has no name: its job id stands for it.
A reused name is refused
with "message it instead" (spawn) or "choose another name"
(async_bash). A `toplevel` name is unique among the live agents of
the caller's session instead.

**Spawning.** Without `model`, the child runs the caller's current
model and thinking level, `provider/model-id:thinking`. A caller with
no model is refused. An explicit `model` is checked with `pi
--list-models`. A resumed session has its own default ("Resuming a
saved session"). The registry records the resolved value. `cwd` must
be an existing
directory. Without it, the child starts in the caller's directory, or
in a resumed session's own directory. Then the harness reads
`/layout` and checks the depth: the child's depth, the length of the
caller's `parent` chain over the rows plus one, is at most 2. Then
`createPane` in `ko-pi.ts` sends one `POST /panes` (protocol.md,
section 7). The pane's command is `ko shell -- ko-pi`, or `ko shell
-- koa` when ko-pi runs inside koa (`--harness koa`, with
`--browser` for `--harness koa-browser`), so a child takes its
parent's harness, with the
session (`--session-id` for a fresh or copied session, `--session`
for a continued one), the name, the model, for a copy `--fork`, for a
routed child `--runtime` and, except for an inside child,
`--session-dir` ("Where a child's session lives").
`ko shell --` starts pi through the user's login shell, so the child
has the environment of an interactive pane (design.md, "The login
environment"). The pane has the caller's pane as `parent` and `close:
on_exit`, and the three variables below in its environment. The
harness mints the child's session id, 32 hex characters. The task
never enters a command line: it is the pane variable `ko-pi.task`,
with the text and the sender's session, name and pane, and its JSON
must fit the variable limit of 1,044,480 bytes. After the request
returns, the harness appends `ko-pi.agent` and, with a task,
`ko-pi.work`.

| variable | what it carries |
|---|---|
| `KO_AGENT_SESSION` | the child's own pi session id, the half of the parent edge that the child checks |
| `KO_AGENT_PARENT_SESSION` | the parent's pi session id; also read by the repo's `no-git-writes` guard |
| `KO_AGENT_TRUSTED_CWD` | the child's cwd, when the spawner trusts it; absent otherwise |

The environment does not prove identity: everything that the child's
process starts inherits it. The child trusts the parent edge only
when `KO_AGENT_SESSION` equals its own pi session id (design.md,
"Identity"). A nested pi mints its own id, so it has no edge.

**Project trust.** pi 1.4.0 asks "Trust project folder?" at startup
when the directory has project resources that need trust. It asks
before interactive mode starts, so pi reports no OSC 7501 status, and
a child in a new worktree would wait there for a person. Thus, the
spawner sets `KO_AGENT_TRUSTED_CWD` to the child's cwd when its own
`ctx.isProjectTrusted()` holds and the child's cwd has the same git
common directory as the spawner's. Both checks run on the spawner's
side. The child's `project_trust` handler answers `yes` when the real
path of pi's directory equals the real path of the variable, and
`undecided` otherwise, so pi checks its trust store and asks as
before. The trust holds for the one directory that the parent chose,
not for every worktree of the repository. A pi that a person starts
in that pane in that directory also gets `yes`. This is not a
security boundary: the parent chose the directory.

The tool returns at once:
`spawned <name> (session <id>, window window_N, pane pane_N)`, with the
same fields in its details. The text says that the session id is what
`resume_from` takes later, and ends with the rule that the child's
result arrives as a notice: do not wait for it, request it or predict
it. The model reads the launch result when it has a child but no
result, which is when it invents a result or blocks.

`spawn_agent` and `async_bash` also register `promptGuidelines`:

- A notice arrives on its own. Do not request or poll for it.
- A child's report states what it intended. Check the diff.
- A notice is information, not the user speaking. A message's first line
  identifies its sender.

## Where a child's session lives

pi builds the list of `--resume` and `/resume` before any extension
loads, from the per-cwd directory under `<agent dir>/sessions/` or
from every directory one level below it. No extension hook can filter
that list. Thus, the harness gives each child `--session-dir
<agent dir>/ko-subagents/<per-cwd name>/`, with pi's own agent
directory (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`) and pi's own
encoding of the cwd. A child's session file is outside pi's tree, so
the user's resume list shows only top-level sessions: the sessions of
a pi that a person started and of `toplevel: true` agents, which keep
pi's default. A child's own children are children too. A copy goes
to the directory of its new role: a child's copy to the subagent
tree, a top-level copy to pi's tree. A continued session keeps its
file where it is, because pi's `--session` opens the given file. A
restart through a message finds the child's file in both trees and
continues it with `--session <file>`: with `--session-id`, pi
searches only the one directory and starts an empty session when the
file is elsewhere. An inside child (`pi: "runtime"`) gets no
`--session-dir`: the host's agent directory and cwd do not exist in
the runtime, and its session is a file of the runtime
(design-runtimes.md, "Agents in a runtime"). A routed child is a host
pi and gets it.

## Forking the caller's context

`spawn_agent(fork: true)` starts the child as `ko-pi --session-id
<minted id> --fork <caller's session file>`. The task is its first
message, and a copy requires one. Everything else is a fresh spawn.
The child starts with the caller's whole transcript, so the parent
can assign a judgement without repeating its reasons. Without
`resume_from`, the copy's source is the caller's own session; with
it, that session. A copy inherits the custom entries, which its
`owner` check ignores. Forking is for a short judgement step, not a
long worker.

## Resuming a saved session

`resume_from` names a pi session by its id or a unique prefix of at
least eight characters. The harness reads only directory listings:
the caller's session directory, each directory directly under its
parent, under `<agent dir>/sessions/` and under
`<agent dir>/ko-subagents/`, and matches the id at the end of a file name
(`<time>_<id>.jsonl`). An exact id wins; otherwise the prefix must
match one file. Then it reads the header line of the match, where pi
records the session's working directory. A session that never ran a
turn has no file ("The registry"), so it cannot be resumed.

**Continue** (`resume_from` alone) starts `ko-pi --session <session
file>`: the same session id, with its history, in its recorded
directory; a different `cwd` is refused. A session is refused while a
pane that is not dead holds its `pi.session`, and when it is an
ancestor of the caller. An own registry child resumes only under its
existing name. Any other session becomes the caller's child; its old
parent's registry entry stays, and that parent sees the session live
under another pane and cannot restart it. The checks and the request
run under the restart lock for that session.

**Copy** (`resume_from` with `fork: true`) starts `ko-pi --session-id
<minted id> --fork <session file>`. The original is unchanged, and
a live original is not refused, because pi only reads it.

**The model.** Without `model`, a continued or copied session gets
the model and thinking level that it last used, so a `/model` or
thinking change inside the agent survives its return. The harness
reads the file once, without pi's `SessionManager.open`, which can
write to it, and walks the current branch as pi's own resume does:
the last model change or assistant response sets the model, but a
response does not replace a virtual model that a change selected;
the last thinking level change sets the thinking level. A file
without a thinking level change gives no `:thinking`, so pi applies
its default. A file that records no model gets the caller's model.
An explicit `model` wins.

**An empty task** is allowed only to continue a session. The session
comes back and starts no turn. No `ko-pi.task` and no `ko-pi.work`
are written, so the child owes no report until its parent sends it
work.

## A top-level agent

`toplevel: true` starts the agent with no parent edge: the same `POST
/panes` with the caller's ko session as `session` and no `parent`,
`close` or `KO_AGENT_PARENT_SESSION`. The server places the window
after the caller's window and names it in the same change, so no
unnamed window flashes. The task goes as `ko-pi.task` like a child's;
the new agent delivers it as a message from the caller, because its
edge does not name the caller. It is a peer ("Peers", below): there
is no subagent entry, no notice and no orphan rule. The pane has the default `close: exit`: when pi
exits, the sweep removes it at once, as for any other command, and
the agent leaves `list_agents`. `resume_from` reads the pi session,
not the pane, so a closed top-level agent stays resumable. The depth ceiling does not apply; `fork`,
`resume_from`, `model`, `cwd` and the trusted cwd apply as for a
child. One of the caller's own children cannot become top-level.

## Peers

A peer of a top-level pi is another top-level pi agent of its ko
session: a pane whose status kind is a pi agent (design.md, "The
trust rule"), with `pi.session` and no `parent`. It does not matter
who started it: `spawn_agent(toplevel: true)`, another agent or a
person. A subagent is never a peer here, and a child pi records no
peers.

**Recording.** A top-level host pi (no parent edge, no
`KO_RUNTIME`) opens `ko api --stream /client` after its own pane
variables are written, with a hello that shows no window, is not
focused and takes no part in sizing (protocol.md, section 3), so the
server never picks it as a window's viewer. It keeps the rows of the
stream's layout and events, and after each change it appends a peer
entry for each peer whose name, session or cwd differs from its last
entry in the session, so a reconnect or a restart of this pi appends
nothing for a peer that did not change. A stream that ends without a
`refused` event connects again with a backoff that resets at the
next `Welcome`; a `refused` before the `Welcome` stops it, as for any
client. The session's shutdown ends the stream and its timer. After
a reconnect, the new layout shows every peer that lives, so a peer
that lives across the outage is recorded.

**Peer activity never notifies the agent.** A peer's start, end or
cwd change only appends entries to the own session: no message, no
notice, no turn, no context and no UI notification. The entries are
read only when a tool resolves an address or lists.

**The model** of a peer is not recorded. A restart reads it from the
peer's session file by the rule of "Resuming a saved session", so a
peer comes back on the model that it last ran on, whoever started
it.

**Names.** Two peers can have the same name; each is its own row,
and an address that matches several needs the session id or a unique
prefix (design.md, "Addressing"). A live agent wins over an ended
peer. A recorded peer does not reserve its name for `spawn_agent`.

**Restart and stop.** `message_agent` in `message` mode to an ended
peer restarts it ("Restarting through a message"), and
`spawn_agent(name, resume_from)` of a recorded peer continues it as
a peer. A peer never gets `ko-pi.work`, a report, a notice or
`ko-pi.ended`. `stop_agent` stops a live peer as any agent of the
scope; to an ended peer it answers `NAME had already ended`, sends
nothing and keeps the entry.

## A child's life

**Start.** At `session_start` the child:

1. Checks its edge: `KO_AGENT_SESSION` equals its own session id and
   `KO_AGENT_PARENT_SESSION` is set.
2. Opens its message stream, then writes `pi.session` and `pi.name`.
   Thus, it can receive questions during its first turn.
3. Reads its own row. With `ko-pi.task`, a child whose edge parent is
   the task's `from.session` appends `ko-pi.work` and delivers the
   text as its first user message; otherwise it delivers the text as
   a message with the sender header. Then it deletes the variable,
   which is the delivered marker. A failed read leaves the variable
   for the next attempt.
4. Starts the parent watch. The job registry's adopt runs before step
   3 ("Jobs across /reload").

Every turn's system prompt then contains these standing instructions:

- While a non-service async job of your own is running or a subagent
  of your own still owes a report, ending your turn sends nothing to
  your parent.
- You were spawned. Your report is the last message of a turn that
  ends after all of them finish, once for each piece of work from
  your parent. It must stand on its own.
- If you stop to wait for another agent or the user, say so; when the
  work completes later, tell your parent with `message_agent`.
- Reporting does not end this session: the parent ends it with
  `stop_agent` and continues it with `message_agent`.

The system prompt contains the instructions instead of the task
because the task arrives only once. A subagent caller gets the same
fact in the results of `async_bash`, `spawn_agent` (except a
top-level spawn and a resume with an empty task) and a restarting
`message_agent`.

**Watching the parent.** The child's pi is a child of the server, so
no signal tells it that its parent has ended. Every
`KO_PARENT_POLL_MS` (5 s) it reads `/layout`: its own row's `parent`
pane is alive when it is not dead and its `pi.session` is the edge's
parent, with or without a pi root, because pi clears its root while
it is in the external editor or suspended. A failed read is no
evidence. Otherwise the child shuts down through the one teardown.
The same tick resends an unsent report ("Reporting").

**Reporting.** When a turn of the child settles idle (`agent_settled`
with `ctx.isIdle()`), the harness sends the last assistant message of
that run to the parent. The text is the concatenation of that
message's `text` blocks. Only the last message counts, because an
earlier one can be stale narration.

The settle sends the report only if all of these are true, in this
order:

1. The child has a parent edge.
2. The turn was not aborted, and no accepted interrupt or stop ended
   it. The child reads this from `agent_settled`'s `aborted` field
   and from its own control mark.
3. The turn did not stop on a provider error. Such a turn sends the
   error notice instead.
4. The child has not reported on its last work, by the rule of "The
   registry". Thus, a turn that something else started (a prompt
   typed into the pane, a notice, a stream batch, a sibling's
   message) sends nothing after the report.
5. Its children are readable. A failed read sends nothing, and the
   next settle reads again.
6. No own job is running, except service jobs ("A job"), and no own
   live child owes a report.
   When the last one ends or reports, its notice wakes the child for
   a turn whose last message is the report.

The reads of 5 and 6 wait on the server, so after them the child
checks again: an accepted interrupt or stop, new work, or a report
since the read cancels the report.

The child mints one message id for the report, appends `ko-pi.report
{ text, id }`, and sends `kind: notice` with `data: { report: true }`
to its parent pane. The text is the whole last message, up to about
1 MB. An `acked` or `refused` reply appends `ko-pi.sent { id }`. The
mark is its own entry, so a late ack after new work does not count as
a report on that work. A `delivered`, `queued` or `io` reply leaves
the report pending, and every tick of the parent watch resends each
pending report, oldest first, with its own id until its mark. A
report has at most one send in flight: a tick skips a report whose
send has no reply yet, so one reply appends one mark. The server delivers each id once (protocol.md,
section 7, "Ids"), so the parent never reads a report twice, also
after a `/reload`. An empty last message sends `subagent "<name>"
ended its turn with no message`.

The parent, on a notice with `data.report` from a current registry
child, appends `ko-pi.report` with the whole text before it acks; if
the append throws, it answers `refuse`, and the child retries. A
report id that the parent has already stored is acked and not
delivered again. The parent's model gets a notice of at most 4000
bytes with the guidance included: a report that does not fit sends
its start and the line `full report: read_report("<name>")`.

**A child that waits on something ko cannot see**, such as a peer's
message or a file, reports when its turn ends. Its last message says
what it waits for, and the standing instruction tells it to tell its
parent with `message_agent` when the work completes.

**The error notice.** A turn that stops on a provider error sends
`subagent stopped on an error: <error>` and `message it to retry, or
stop_agent to end it`, once for each failed attempt. It writes no
report entry.

**The exit notice.** At `session_shutdown` with reason `quit`, a
child with an edge that has not reported on its last work, and that
no stop or parent loss is ending, sends one last notice: `subagent
"N" is exiting before its first turn ran`, `... without a report on
its last work: its last turn failed: <error>` when the error was not
yet sent, or `... without a report on its last work`. The error notice
and the exit notice each keep one message id across their resends. `/reload`,
`/new`, `/resume` and `/fork` send nothing.

**Endings.** When a child's pane dies or leaves the document, the
server enqueues the message `ended-pane_N` of kind `ended` on the
parent's stream (protocol.md, section 7). The parent formats the
notice from its own rule:

    subagent "worker" ended: exit 0; it had reported

    subagent "worker" ended: exit 1; it had not reported on its last work
    --- last 4000 bytes of its screen ---
    ...
    message it to continue it, or stop_agent to end it

    subagent "worker" ended: its pane was removed; it had reported

The screen block appears only for a dead pane that lingers and a
child that had not reported; the harness reads it with `GET
/panes/pane_N/screen?history=all`. An `ended` message for a pane that
is not a current registry child of this server instance, or for a
child that `stop_agent` silenced, sends nothing. The message is
queued, so a reload gap loses nothing. A parent that restarts under
its own session id in a new pane has a new queue: its `session_start`
reads the rows of its registry children, and one whose pane is gone,
dead or of another instance gets the notice once, with `its pane is
gone` or the dead pane's cause. `ko-pi.ended` records each
announcement, so each ending of a child's current pane is announced
once.

The parent's UI displays a notice at once as a dimmed `│ @<name>
notifies: <first line>` line above the editor. The notice enters the
model's context at the next turn boundary as a steer: a parent in a
turn sees it between tool calls.

**The parent ends a child.** A child has no idle timer. After it
reports, it stays alive. Only its parent (`stop_agent`), an agent in
its scope, the user or the orphan rule ends it.

**Shutdown.** The child uses one teardown, whether it quits, is
stopped or loses its parent:

1. The exit notice, when it is owed.
2. It stops each own running job ("Stopping a job").
3. It closes the message stream.
4. It deletes its pane variables with the conditional delete of
   design.md, "The variables".

ko records nothing for an agent's ending. `/reload` keeps the
message stream, the variables and the jobs. `/new`, `/resume`
and `/fork` tear down as a quit does, without the exit notice.

**The pane.** The sweep removes the child's pane after it has been
dead for the linger grace (`close: on_exit`), or at once when its
parent pane is gone or dead (design.md, "Window lifecycle"). The
ending notice reads the screen while the pane lingers.

## Redirecting one, and ending one from outside

`message_agent` has three modes, and all three reach any agent of the
scope:

- `message` queues with `followUp` until the receiver's turn ends.
- `steer` leaves the turn running and adds the text inside its loop,
  as a `ko-steer` custom message with `deliverAs: "steer"`. An idle
  receiver starts a turn with it.
- `interrupt-and-steer` sends kind `interrupt`. The receiver marks
  its turn as ended by a control, holds the text and requests pi's
  abort. pi's extension `abort()` returns before the run ends, and a
  message sent while the run streams is a follow-up that the aborted
  run never drains. Thus, the receiver delivers the held text at the
  run's `agent_settled`, as an ordinary message from its sender. An
  idle receiver delivers it at once. The aborted turn's settle sends
  no report and no error notice.

A message and a steer from the parent carry `details.work`, so the
child's `message_start` marks new work. The parent marks
`ko-pi.work` before it sends its own child work in any mode; the mark
stays after a failed send, because the message can have arrived.
There is no interrupt without text.

**Sending.** Every send mints one id, 128 random bits as 22 base64url
characters, for one intent, and keeps it for that intent's retries: a
`message_agent` call, the stop request, each error and exit notice,
each report. A tool call posts up to three times, again on
`delivered` or `io`, `KO_RESEND_MS` (1 s) apart, then reports the
last state:
`delivered to N` (acked), `queued for N` (the agent is not receiving
and reads it when its stream returns), or `sent to N: written ..., not
yet confirmed`. An acked `message` to a working agent says that it
reads the text when its turn ends and points to `steer`.

**stop_agent** resolves one address in the scope by the addressing
rules of design.md and refuses only the caller. A target with an open
message stream gets kind `stop`; then the harness sends `POST
/panes/pane_N/stop` with `wait_ms: 5000`, whatever the request
returned, so the pane dies also when the agent does not end itself
(design.md, "Steer, interrupt and stop"). A target without a stream is
refused unless `force`, which skips the request and stops the pane
with `wait_ms: 0`, so it is removed at once.
Lines: `stopped NAME; it had reported`, `stopped NAME; it had not
reported on its last work`, `stopped NAME` for a peer or ancestor,
`NAME had already ended: <cause>`.

**The result is the only signal.** Before it stops an own child,
`stop_agent` appends `ko-pi.ended` for it, so the server's `ended`
message for that pane sends no notice. A child that ends any other way
notifies through that message ("Endings").

**The orphan rule.** The server removes a pane whose `parent` pane is
gone or dead (design.md, "Window lifecycle"). It reads no pi
evidence: a pi that quits inside a shell pane that stays open keeps
its pane alive, so its children end through their own parent watch,
which reads `pi.session`.

## Restarting through a message

`message_agent` in `message` mode to an ended own child or an ended
recorded peer restarts it. A child restarts as follows:
`POST /panes` with `--session <file>` of the child's session, or
`--session-id <id>` when it has no file yet, in the recorded cwd, on
the file's last model as for a resume (the registry's `model` when the
file records none), the
message as `ko-pi.task`, the parent's `ko-pi.work` and a new
`ko-pi.agent` with the new pane. The message is never in pi's argv:
pi's parser reads an argument that starts with `@` as a file, even
after `--`. The rules:

- Only the parent restarts its child: the registry is the parent's
  own. `steer` and `interrupt-and-steer` to an ended child are
  refused.
- A name resolves to a live agent first, then to an ended registry
  child.
- A child restarts once at a time. Discovery and the restart run
  under a lock for that child's session. A second message during the
  restart finds the first one's live pane and goes to it.
- The new pane's `parent` is the sender's current pane.

A peer restarts as a top-level agent ("A top-level agent"): `POST
/panes` with the sender's ko session, no `parent`, `close` or
`KO_AGENT_PARENT_SESSION`, `--session <file>` in the directory of
the file's header, on the file's last model, and the message as `ko-pi.task`. It is
refused without a session file: a peer never restarts as an empty
session. The restart lock and the live-first rule above apply. A
peer entry has no pane, so the harness keeps the new pane in memory
as the peer's starting pane until it publishes `pi.session` or ends;
a second message in that time goes to it. No `ko-pi.work` is
written, and the reply asks for no report.

## A job

A job is a command that runs in the background as a child process
of pi, and that tells the caller once it ends. It is not a pane: it
has no window, and its row in the sidebar is a status record of pi's
own pane ("A job's row"). Two tools make one:

- `async_bash(command, name, stream?, service?)` starts a job.
- A `bash` call that still runs after `KO_JOB_MOVE_MS` (60 000), or
  that the user moves with ctrl+b, becomes a job ("The bash tool's
  move").

**The registry.** Every job is a `Job` record of one registry for
each process, `globalThis[Symbol.for("ko-pi.jobs")]`. Its envelope
(`JobRegistry` in `ko-pi.ts`) never changes shape; `JOB_SHAPE` is
raised with each change of the `Job` layout. The pipe listeners of a
job write its log and its buffers and never call pi; only the hooks
of the current extension instance call pi. Thus, a job and its
output survive `/reload`, whose old instance can no longer send a
message ("Jobs across /reload"). It is a `Symbol.for` key with a
fixed envelope, not a typed global, because a ko-pi of another
version must still read and stop it. The registry keeps every running
job, every ended job whose notice is still owed, and the newest 20
announced ones, so a list can show more than 20 ended jobs while
notices are owed. Nothing reads ko for the list. A
`bash` call that runs in the foreground also has a record, so its
abort and its stop go through the same signal function; it is not a
job, and no list, name, notice or stream sees it.

**The command.** A local job runs through pi's shell configuration
(`getShellConfig` with the user's `shellPath`, and pi's shell
environment), as pi's `bash` does, in its own process group
(`detached`), with the call's cwd. It copies pi's local operations
(`createLocalShellOperations` in pi's `dist/core/tools/bash.js`),
because those hide the `ChildProcess` that a move and a stop need; a
pi upgrade checks the copy. `set -o pipefail` is the model's to write. A routed pi
runs the command in its runtime: the job's process is the `ko api
--stream /runtimes/NAME/exec` child of pi (design-runtimes.md,
"Agents in a runtime"). The depth ceiling does not apply.

**The log.** Both pipes write one file in arrival order, raw, with
no size cap: `<tmpdir>/ko-pi/<session id>-<job id>.log`, the
directory mode 0700 and the file 0600. It is never deleted, as pi's
own `bash` output files are not: the user or the model reads it after
the end. Only the in-memory tail (64 KiB) is bounded. The result of
`async_bash` names the job id, the name and the log.

**Exactly one notice.** At the end, the harness sends one notice
(`deliverAs: "steer"`, `triggerTurn: true`):

    job "build" (j4k2m9qp) exit 3
    --- last 4000 bytes of its output ---
    ...
    log: /tmp/ko-pi/<session>-j4k2m9qp.log

The first line names the end: `exit N`, `signal NAME`, `failed:
<message>`, or `timed out after N s`. The tail is the last 4000 bytes
with escape sequences stripped, because failure information comes
last. A job that `stop_async_bash` stopped sends none; a stop of an
ended job answers `had already ended` with its end. Each job sends
its own notice; ko-pi groups none.

A job is not an agent. `message_agent` and `stop_agent` do not
resolve it.

**A service.** `async_bash` with `service: true` starts a process that
is meant to keep running, such as a server or a watcher, not a build
or a test. A service is not the agent's own unfinished work: it does
not hold a child's report ("Reporting", rule 6), so a child whose
only running jobs are services reports when its turn settles.
Everything else is as for any other job. Only `async_bash` sets the
flag: a `bash` call that moves is never a service.

## A job's row

Each job is an OSC 7501 child record of pi's pane, which ko-pi writes
through the status route (protocol.md, section 6), so Kido.app
draws it as a child row under the pane row (design-program-status.md,
"The record set"). A foreground `bash` call has no record. It gets
one when it moves. A routed job has one as a local job does.

- The id is `job/<job id>`. A job id is unique in the registry. Only
  ko-pi writes the namespace `job`, so a clear of `job` removes every
  job record and nothing else.
- The title is the job's name, so a row reads name first and command
  second. While the job runs, the state is working and the message is
  the command. A running service is idle: it is not the agent's work,
  so it does not make the pane or the folded circles of its ancestors
  look running. When it ends, the state is done
  for exit 0. Every other end is error: an exit code, a signal, a
  failure to start, a timeout or a stop. The message is the end text
  of its notice (`exit 3`, `signal SIGTERM`).
- The title and the message are sanitized by ko-pi's own rule:
  pi-tui's control character replacement, then whitespace collapses
  to one space. The text is cut at a UTF-8 boundary to the route's
  limits. An empty title or message is omitted.
- A finished record lingers for `KO_JOB_RECORD_LINGER_MS` (5000).
  Then ko-pi clears its id. A job's record never changes the pane's
  status: an agent's status comes from its root record alone
  (design-program-status.md, "Reduction").

**The writer.** ko-pi writes each record as one `ko api POST
/panes/$KO_PANE/status`, never on its stdout, so a record reaches the
server in every mode of pi with a UI: the TUI, RPC mode, a routed pi in a
runtime and a pi on a remote server. A record needs no OSC 7501
support of the outer terminal. ko-pi writes only while it is active in
the pane, as for its message stream: a headless pi that a tool starts
inherits `KO_PANE`, and it must not touch its parent's rows. The posts go through one queue, one
after another, in the order of the changes; a failed post is dropped,
and the next change of the job writes it again. A shutdown waits for
the queue, so a post of the old instance never follows the clear of a
`/reload`'s new instance. The queue is ordered only against itself: a
post in flight can land after pi's root clear ("pi's clears") and
bring that row back early.

**At most 32 records.** The server's set has a limit, and a new record
over the limit removes the oldest record. That can be pi's root
record. Thus ko-pi admits at most 32 job records at once. When a new
job needs a slot, ko-pi clears the oldest finished record first. When
all 32 jobs run, the new job gets no row, also not at its end. The cap
is ko-pi's own, not a server rule.

**pi's clears.** pi-tui's `Terminal.stop()` writes a root clear. This
removes every record of the pane, the job records too. It runs at
pi's exit, at a suspend (ctrl+z) and around the external editor.
`start()` sends only pi's root record again. Thus ko-pi writes its
running job records again at `input` and `agent_start`, and it writes
a job's record at each change of that job. It never writes on a timer
or on each key. While the editor is open or pi is suspended, and
until the next submit or agent start, the rows are absent. A finished
record that such a clear removed does not come back.

A prompt start (OSC 133 `A`) removes every record of the pane that has
not ended: working, blocked and idle, so also a service's.
pi 1.5.0's TUI strips its OSC 133 zone markers before it writes, so
the job rows and pi's own working status stay.
`share/pi/package.json` pins 1.5.0.

**Across /reload and quit.** A `/reload` cancels the linger timers of
the old instance. The new instance clears `job` at adopt. Then it
writes the record of each running job that it adopted, within the
cap, so a job that had no slot before can get one. A job that ended
before or during the reload gets no record, only its notice. Every
other shutdown, and the registry's exit handler, clears `job` before
it stops the jobs, so a stopped job writes no record after the clear.
The exit handler's clear is a synchronous `ko api` call, because Node
runs no asynchronous work in an `exit` handler; a post that is in
flight at the exit can land after it.

## Stopping a job

Every signal of ko-pi goes through `signalJob(job, signal)`, which
takes a record of the registry, never a pid from an argument, a
message or a tool parameter. A local job's signal goes to the group
that its `detached` spawn created. The function refuses when the
shell has exited: Node has reaped it, and the group id can be reused
once its last member is gone. A job whose shell exited while a
descendant holds its pipes waits for the pipes, and a stop sends
nothing. An `ESRCH` or `EPERM` from a group signal means that no
member can get it, not an error: macOS returns `EPERM` for a group
whose members are all zombies, which occurs after the shell exits and
before Node reaps it. A routed job's stop is `kill()` of its own `ko api` child:
ko closes the exec session, and the inside ko signals the command's
group (design-runtimes.md, "The exec session"). ko-pi sends no
`signal` frame. A process that leaves its group (`setsid`) escapes.

A stop sends `SIGTERM`, then `SIGKILL` after `KO_JOB_KILL_MS` (5000)
when the job still runs. The registry's one `process.on("exit")`
handler sends `SIGKILL` through `signalJob` to every local group that
still runs at pi's exit; a registry that was replaced keeps its
handler until its jobs have closed. `scripts/lint.sh` refuses
`process.kill(` in `share/pi/` outside `signalJob`.

**Known limit: an orphan after `SIGKILL`.** A pane's hangup sends
`SIGHUP` to pi's group and `SIGKILL` 250 ms later. pi's `SIGHUP`
handler runs a `quit` shutdown, which sends `SIGTERM` to every job,
but the exit handler does not run after `SIGKILL`, and a detached
job lives on in its own group. The user accepted this limit on
2026-11-05: pi's own detached `bash` commands have it already, and a
job only lengthens the window.

## Streaming a job's output

With `stream: true`, the job's pipe listener also splits the output
into lines. It strips escape sequences (CSI, OSC, DCS, APC, PM, SOS
and other ESC sequences), keeps text, tabs and newlines, and applies
the carriage-return rule: a `\r` that a `\n` does not follow starts
the line over, so a progress bar leaves its last state.

The held lines go as one collapsed custom message (`deliverAs:
"steer"`, `triggerTurn: true`). A job sends at most one batch in each
`KO_STREAM_INTERVAL_MS` (5000), counted from the last send attempt,
or from the move for the first one, so a failed send also waits an
interval. When the interval has passed, the held
lines go:

- While the caller works, at a tool boundary: a `turn_end` that ran
  tools. A boundary inside the interval sends nothing; the lines wait
  for a later boundary.
- While the caller is idle, on a timer at the end of the interval.
  When the caller becomes idle, the timer starts again.

A job has no total budget: the throttle limits how often the model
reads a batch, and each batch has the limit of pi's `bash` output. A
batch is the tail of the held lines through pi's `truncateTail`, with
its default limits. One line above it reads `... N lines omitted
(log: <path>)`, for the lines that the truncation cut and the lines
dropped from the held buffer, which keeps pi's default line limit.
The held text has a bound of 64 KiB, the partial line included. A
batch that lost the start of a long line, in the buffer or in the
truncation, has one line `... long lines were truncated (log:
<path>)`. The log keeps every byte. A batch
leaves the buffer only when its message went, so a failed send keeps
it for the next adopt. A pipe loses nothing, so no batch reports lost
bytes. At the end, the partial last line and the held lines go before
the notice, without the throttle: the model never reads "this is how
it ended" before the output.

## The bash tool's move

At `session_start`, when the `bash` of `pi.getAllTools()` is pi's
builtin (`sourceInfo.path` starts with `builtin:`), ko-pi registers
a `bash` with pi's own definition (`createBashToolDefinition`, with
the user's `shellPath` and `shellCommandPrefix`), whose operations
are `handoff(localExec)`. An extension tool with a builtin's name
replaces it. A routed pi's `bash` is ko-pi's routed tool, with
`handoff` over the exec session. Another extension's `bash` stays
alone: no move and no ctrl+b. `!` commands are not wrapped.

- A `timeout` under `KO_JOB_MOVE_MS` passes through: the command is
  stopped at its timeout with pi's timeout error.
- No `timeout`, or a longer one: at `KO_JOB_MOVE_MS`, the running
  command becomes a job and the call returns at once, not as an
  error: `still running after 60 s; it continues as job ID; a notice
  arrives when it ends; output so far:`, the tail, and the log. The
  command is not stopped. An explicit timeout becomes the job's
  deadline, and its notice reads `timed out after N s`.
- With a UI, ctrl+b (`ctx.ui.onTerminalInput`) moves every running
  call at once; the key is consumed only then. After
  `KO_JOB_HINT_MS` (3000) of a call, the widget `ko-job-hint` shows
  `ctrl+b moves this command to a job`, until the call ends or moves.
- A call that runs at a `/reload` shutdown moves, because the new
  instance cannot complete the old call.

The foreground call keeps the last 64 KiB of its output, so a moved
job's log starts with it; when the call produced more, the first line
of the log says that the earlier output is cut.

## Jobs across /reload

pi reloads an extension in the same Node process, so the children
and their listeners live on. These facts of pi 1.4.0 decide the
design; a probe extension observed them through one `/reload`:

- A child and the `data` and `close` listeners of the old instance
  keep firing after the reload, beside the new instance's own.
- `session_shutdown` with reason `reload` runs on the old instance,
  then the new factory, then `session_start` with reason `reload`,
  about 150 ms later.
- After the reload, the old instance's `pi.sendMessage` throws ("This
  extension ctx is stale after session replacement or reload").

Thus the registry keeps a job's output and ending as plain data, and
only the current instance calls pi. At `session_shutdown` with reason
`reload`, ko-pi moves its running `bash` calls, clears each job's
hooks and flush timers, removes the hint and the ctrl+b listener,
and leaves the registry on `globalThis`. At the next `session_start`,
after the pane variables and before the task, the new instance:

- adopts the registry when its shape and session are its own: it
  sets the hooks, sends the notice of each job that ended in the gap,
  and schedules the flush of a streaming job, whose held lines and
  UTF-8 carry crossed the reload. A deadline's timer calls the stop,
  not pi, so it keeps running. A notice that fails stays owed for the
  next adopt.
- otherwise stops the old jobs through the old registry's `stopAll`,
  replaces the registry and sends one notice: `N async_bash jobs of
  the previous ko-pi version were stopped at /reload: a, b`.

The other reasons (`quit`, `new`, `resume`, `fork`) stop every job,
wait up to `KO_JOB_KILL_MS` for the ends and clear the registry.

## A human at a shell

A human uses ko's own commands, not the tools:

- `ko prompt` sends text to an agent in scope as kind `user`, which
  the agent reads as the user's own words (design.md, "Delivery, and
  when a paste is allowed").
- `ko-pi` in a pane starts a top-level agent.

A shell has no message stream and no session. It cannot receive a
message or a notice.

## In the sidebar

Both clients nest a subagent's window under the pane that spawns it,
not after that agent's whole window (design.md, "The sidebar tree").
The terminal client shows the nesting as one column of indentation
for each level. Kido.app's sidebar (design-app.md, "Sidebar" and
"Folded children") indents each level by 15pt and folds a pane's
children into circles on its row unless the pane or one of its
descendants is focused.

The anchor is the `parent` of the child's pane row, which the server
sets to the spawner's pane when it creates the pane. The edge stays
for a live and a finished child alike. Thus, a finished child remains
nested while its window lingers. A child whose parent is absent or in
another session is a root.

In Kido.app, a subagent's pane has `close: on_exit`: it shows a dimmed check for exit
0 and a dimmed `×` otherwise until the sweep removes it.

These nested windows do not follow the document's window order.

## Limits

- A `/tree` back past a spawn drops the child's registry entry. The
  child lives on with its row's `parent`, lists and can be messaged,
  but cannot be restarted by name and its ending sends no notice.
- A message queued for a pane that dies is dropped without word to
  its sender.
- The task variable is visible to clients until the child deletes it.
- The ending notice reads a child's screen only while its pane
  lingers; ko keeps nothing after the sweep.
- The escape stripper is simpler than a terminal: a sequence it does
  not know reaches the model as noise. The log keeps the raw bytes.
- A job of a pi that ends with `SIGKILL` is an orphan ("Stopping a
  job").
- A moved `bash` call's log starts with the last 64 KiB before the
  move.
- The jobs rest on pi 1.5.0 internals: `createBashToolDefinition`,
  `getShellConfig`, `rawKeyHint`, `onTerminalInput`, the `builtin:`
  prefix of `sourceInfo.path`, the override of a builtin by name, and
  the copy of pi's local shell operations. A pi upgrade checks them.
- A runtime's cap of 32 exec sessions counts its routed jobs, so many
  long jobs make the routed tools wait.
- A routed job's log is on the host. The routed `read` runs in the
  runtime, so it cannot read a log that the runtime does not map.
- Nesting stops at depth 2 within each parent chain.
- `/reload` forgets the last turn's error and that the first turn
  never ran.
- A child idle behind a job that never ends, such as a watcher, never
  reports while that job runs.
- A subagent's window moved to another session is outside its
  parent's scope.
- A top-level pi records only the peers that its `/client` stream
  shows. A peer that starts and ends while the stream is down, or
  while this pi does not run, is never recorded.
- A pi inside a runtime records no peers: the runtime gate refuses
  `/client` (design-runtimes.md, "Identity on a runtime connection").
- A routed peer restarts as a host pi: a peer entry holds no runtime.
  Its recorded cwd is the one that `list_agents` shows, the
  runtime's for a routed peer; the restart uses the session file's.
- Two top-level pis that record one peer can both restart it at the
  same time, because each restart lock is in its own process. Then
  two pis write one session file.
- The name claim and the restart lock are in the caller's process.
  Two callers that resume one saved session at the same time can both
  pass the live check, and two pi processes then write one session
  file.
