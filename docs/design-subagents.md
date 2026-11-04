# Subagents, as built

A subagent is a pi session that another agent starts in a window of
its own. Its pane has the spawner's pane as its `parent` and `close:
on_exit`. ko keeps no record of an agent after its pane goes: the
parent's own pi session holds what the parent knows about its
children, and each harness keeps only its own facts. Runs stay for
`async_bash` and `ko run`. This document follows a subagent from the
tool call that creates it to the sweep that removes its pane.

[design.md](design.md) describes the mechanisms that subagents use:

- The pi extension, ko-pi
- Messages
- Addressing
- Identity
- The window lifecycle
- Run outcomes

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
| `list_agents(which?)` | `ko api /layout`, `/version`, the registry in the own session |
| `read_report(agent, which?)` | the own session's `ko-pi.report` entries |
| `list_async_bash()` | `ko runs --json --all --parent $KO_PANE` |
| `message_agent(to, message, mode?)` | `POST /panes/{t}/messages`; `POST /panes` to restart an ended child |
| `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?, runtime?)` | pi's session directories, `pi --list-models`, `GET /runtimes/NAME`, `POST /panes` |
| `stop_agent(agent, force?)` | `POST /panes/{t}/messages` kind `stop`, then `POST /panes/{t}/stop` |
| `async_bash(command, name, stream?)` | `ko run-child $KO_PANE --name N -- bash -o pipefail -c CMD` (a routed pi: `POST /runs` with `runtime`), `ko run-wait ID --json`, `ko api --stream /panes/P/output` |
| `stop_async_bash(run)` | `ko run-stop ID` |

The parent of every run and every child is `$KO_PANE`. No agent has
`KO_RUN_ID`. A tool checks its own arguments and refuses them with a
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
row has `id` (the pi session), `name`, `pane`, `window`, `status`
(the root's OSC 7501 state, `starting` before it has one, `ended`),
`activity`, `parent` (the parent's pi session), `depth`, `cwd`,
`runtime` (the row's field, else a trusted `pi.runtime`; a routed
agent's `cwd` is that variable's), `canMessage` (the row's `inbox`: the pane's message stream is open),
`kind` (`agent` or `subagent`), `relationship` (`own`, `parent`,
`peer`, `relative`) and `state` (`running` or `ended`). An own child
adds `model`, `reported` and `report`: the first 1000 bytes of its
last report. `read_report` gives the rest. An ended child is a
registry entry whose pane is gone, dead or of another server
instance (`/version`'s `instance`); every ended child lists, with
`ended`, its cause or "its pane is gone". The agents come from the
panes with a pi root and `pi.session` (design.md, "The trust rule")
and from the caller's own children whose pane has not yet published
`pi.session`.

**read_report** returns the whole text of an own child's last report,
or with `which: all` every report in order with its time, from the
caller's own session. It never reads the child's session.

**list_async_bash** lists the caller's own runs: all running and the
newest 20 ended, newest first, with `run`, `name`, `state`,
`outcome`, `startedAt`, `pane` and the `ko api` command that reads
the pane's screen.

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

In the parent:

| entry | when | data |
|---|---|---|
| `ko-pi.child` | at each spawn and restart | `name`, `session`, `model`, `fork`, `cwd`, `pane: { instance, pane }`; the last entry of a name is current |
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
children, its live own children and its runs. A reused name is
refused with "message it instead" (spawn) or "choose another name"
(async_bash). A `toplevel` name is unique among the live agents of
the caller's session instead.

**Spawning.** Without `model`, the child runs the caller's current
model and thinking level, `provider/model-id:thinking`. A caller with
no model is refused. An explicit `model` is checked with `pi
--list-models`. The registry records the resolved value, so a restart
runs the model that the child ran. `cwd` must be an existing
directory. Without it, the child starts in the caller's directory, or
in a resumed session's own directory. Then the harness reads
`/layout` and checks the depth: the length of the caller's `parent`
chain over the rows, at most 2. Then it sends one `POST /panes`
(protocol.md, section 7):

    name: N, cwd: C
    command: [ko, shell, --, ko-pi, --session-id ID | --session FILE, --name N, --model M, --fork FILE?]
    env: KO_AGENT_SESSION=ID, KO_AGENT_PARENT_SESSION=S, KO_AGENT_TRUSTED_CWD=C?
    parent: $KO_PANE, close: on_exit
    vars: { "ko-pi.task": { text, from: { session, name, pane } } }   (a non-empty task)

`ko shell --` starts pi through the user's login shell, so the child
has the environment of an interactive pane (design.md, "The login
environment"). S is the caller's own pi session id. The harness mints
the child's session id, 32 hex characters. The task never enters a
command line: it is the pane variable `ko-pi.task`, and its JSON
must fit the variable limit of 1,044,480 bytes. After the request
returns, the harness appends `ko-pi.child` and, with a task,
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
the caller's session directory and each directory directly under its
parent, and matches the id at the end of a file name
(`<time>_<id>.jsonl`). An exact id wins; otherwise the prefix must
match one file. Then it reads the header line of the match, where pi
records the session's working directory.

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
<minted id> --fork <session file>`. The original stays as it was, and
a live original is not refused, because pi only reads it.

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
edge does not name the caller. There is no registry entry, no notice
and no orphan rule. When pi exits, the pane dies and stays until the
user closes it. The depth ceiling does not apply; `fork`,
`resume_from`, `model`, `cwd` and the trusted cwd apply as for a
child. One of the caller's own children cannot become top-level.

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
4. Adopts its live runs and starts the parent watch.

Every turn's system prompt then contains these standing instructions:

- While an async run of your own is running or a subagent of your own
  still owes a report, ending your turn sends nothing to your parent.
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
5. Its runs and its children are readable. A failed read sends
   nothing, and the next settle reads again.
6. No own bash run is live, and no own live child owes a report.
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
pending report, oldest first, with its own id until its mark. The server delivers each id once (protocol.md,
section 7, "Ids"), so the parent never reads a report twice, also
after a `/reload`. An empty last message sends `subagent "<name>"
ended its turn with no message`.

The parent, on a notice with `data.report` from a current registry
child, appends `ko-pi.report` with the whole text before it acks; if
the append throws, it answers `refuse`, and the child retries. A
report id that the parent has already stored is acked and not
delivered again. The parent's model gets a notice of at most 4000
bytes with the guidance included: a report that does not fit sends
its start and a final line `full report: read_report("<name>")`.

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
2. `ko run-stop` for each own live bash run.
3. It closes the message stream.
4. It deletes its pane variables with the conditional delete of
   design.md, "The variables".

No outcome is recorded: an agent has no run. `/reload` keeps the
message stream, the variables and the run watches. `/new`, `/resume`
and `/fork` tear down as a quit does, without the exit notice.

**The pane.** The sweep removes the child's pane after it has been
dead for the linger grace (`close: on_exit`), or at once when its
parent pane is gone or dead (design.md, "Window lifecycle"). An
agent's pane gets no screen capture: the ending notice reads the
screen while the pane lingers.

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
each report. A tool call resends on `delivered` or `io` up to three
times, `KO_RESEND_MS` (1 s) apart, then reports the last state:
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
notifies as before.

**The orphan rule.** The server removes a pane whose `parent` pane is
gone or dead (design.md, "Window lifecycle"). It reads no pi
evidence: a pi that quits inside a shell pane that stays open keeps
its pane alive, so its children end through their own parent watch,
which reads `pi.session`.

## Restarting through a message

`message_agent` in `message` mode to an ended own child restarts it:
`POST /panes` with `--session-id <id>` in the recorded cwd, the
message as `ko-pi.task`, the parent's `ko-pi.work` and a new
`ko-pi.child` with the new pane. The message is never in pi's argv:
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

## An async bash run

`async_bash(command, name, stream?)` runs a command in its own
window and tells the caller once the command ends. It is a run, not
an agent:

    ko run-child $KO_PANE --name N -- bash -o pipefail -c '<command>'

The server starts the argv directly, so text from the model never
reaches a shell other than that `bash`. A routed pi starts the same
argv in its runtime ("Agents in a runtime" in design-runtimes.md). There is no wrapper: the
command's output is its pane's content. The depth ceiling does not
apply.

The result names the run id, the window and the pane, and the `ko
api` command that reads the screen. The harness starts `ko run-wait
ID --json` in the background and formats the ending notice:

    async run "build" failed: exit 3
    pane: pane_7
    --- last 4000 bytes of its screen ---
    ...

The tail is the last 4000 bytes of `GET
/panes/pane_N/screen?history=all` while the pane lingers, else of `GET
/runs/ID/screen`, the capture of the sweep. It uses the tail, because
failure information comes last.

**Exactly one notice.** `run-wait` exits once, so the harness sends
one notice for each run, or none for a run that it stopped with
`stop_async_bash`, which silences the watch first. A stop that fails
clears the silence. When `run-stop` exits 5, because the run had
already ended, the line reads `had already ended`.

A bash run is not an agent. `message_agent` and `stop_agent` do not
resolve it. The orphan rule collects it.

## Streaming a run's output

With `stream: true`, the harness opens `ko api --stream
/panes/pane_N/output?offset=O` beside the `run-wait` (protocol.md,
section 4, "The output stream") and reads its `bytes` and `skip`
records. It strips escape sequences (CSI, OSC, DCS, APC, PM, SOS and
other ESC sequences), keeps text, tabs and newlines, and applies the
carriage-return rule: a `\r` that a `\n` does not follow starts the
line over, so a progress bar leaves its last state. A `skip` adds `...
N bytes omitted (the pane's screen has them)` to the next batch.

The held lines go as one collapsed custom message (`deliverAs:
"steer"`, `triggerTurn: true`) at one of two times:

- While the caller works, at a tool boundary: a `turn_end` that ran
  tools.
- While the caller is idle, on the idle schedule: the first batch
  after `KO_STREAM_FLUSH_MS` (1000), each later one at double the
  delay, up to `KO_STREAM_MAX_WAIT_MS` (30000). A tool boundary
  resets the delay.

Each run has a budget of `KO_STREAM_BUDGET_BYTES` (256 KiB) of sent
batches. After it, one last message names the screen route and no
more batches go. A batch keeps a tail of up to 200 lines within 16 KB;
one line above it reads `... N lines omitted (the pane's screen has
them)`, for lines cut by the cap and lines dropped from the held
5000-line buffer.

When `run-wait` exits, the harness waits up to `KO_STREAM_DRAIN_MS`
(1500) for the output stream to close after the pane's death, sends
the partial last line and the held lines, then the ending notice.
Thus, the model never reads "this is how it ended" before the output.
A `/reload` parks each watch with its offset and held lines on
`globalThis`, and the reloaded module reopens the stream at that
offset, the resume path. A restarted harness re-watches a live run
for its ending only.

## A human at a shell

A human uses ko's own commands, not the tools:

- `ko prompt` sends text to an agent in scope as kind `user`, which
  the agent reads as the user's own words (design.md, "Delivery, and
  when a paste is allowed").
- `ko run --name N -- CMD...` starts a parentless run.
- `ko-pi` in a pane starts a top-level agent.

A shell has no message stream and no session. It cannot receive a
message or a notice.

## In the sidebar

Both clients nest a subagent's window under the pane that spawns it,
not after that agent's whole window (design.md, "The sidebar tree").
The terminal client shows the nesting as one column of indentation
for each level. Kido.app's sidebar (design-app.md, "Sidebar") draws it
in full: the parent window's bracket continues beside the child as a
`│` stem, children of one pane form a group with `├` and `└` on their
first rows, and an only child also receives `└`, not its own dot. This
makes ownership immediately visible.

The anchor is the `parent` of the child's pane row, which the server
sets to the spawner's pane when it creates the pane. The edge stays
for a live and a finished child alike. Thus, a finished child remains
nested while its window lingers. A child whose parent is absent or in
another session is a root.

In Kido.app, a lingering run window shows its run's result in the
status slot, by the Ended rule of design-app.md ("Sidebar"): a green
`✓` for `completed`, a red dot for `failed` and `died`, a gray dot for
`stopped`. A subagent's pane has no run and has `close: on_exit`: it
shows a dimmed `✓` for exit 0 and a dimmed `×` otherwise until the
sweep removes it.

These nested windows do not follow the document's window order.

## Limits

- A `/tree` back past a spawn drops the child's registry entry. The
  child lives on with its row's `parent`, lists and can be messaged,
  but cannot be restarted by name and its ending sends no notice.
- A message queued for a pane that dies is dropped without word to
  its sender.
- The task variable is visible to clients until the child deletes it.
- An agent's pane gets no screen capture. The ending notice reads the
  screen while the pane lingers.
- The escape stripper is simpler than a terminal: a sequence it does
  not know reaches the model as noise. A `skip` loses bytes that only
  the screen keeps.
- A run's output is bounded by the terminal's scrollback and the
  capture's cap.
- Nesting stops at depth 2 within each parent chain.
- A re-watched bash run after a restart sends no batches.
- `/reload` forgets the last turn's error and that the first turn
  never ran.
- A child idle behind an async bash run that never ends, such as a
  watcher, never reports while that run lives.
- A subagent's window moved to another session is outside its
  parent's scope.
- The name claim and the restart lock are in the caller's process.
  Two callers that resume one saved session at the same time can both
  pass the live check, and two pi processes then write one session
  file.
