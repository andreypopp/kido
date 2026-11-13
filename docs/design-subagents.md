# Subagents, as built

A subagent is a pi session that another agent starts inside koa's own
process, through pi's SDK. Every agent of a koa pane, the root
included, is an `AgentSession` of one host (design-koa.md, "The
process"). A subagent has no pane, no window and no process of its
own: it is a node of the host's tree, a status record of koa's pane in
the sidebar, and a view of koa's page. The parent's own pi session
holds what the parent knows about its children, as custom entries.
An agent's background commands are jobs of the host, not panes ("A
job", below). A `toplevel: true` agent is the one agent that is still
a pane of its own ("A top-level agent").

[design.md](design.md) describes the mechanisms that subagents use:

- The harness extension
- Messages
- Addressing

This document refers to those sections by name instead of repeating them.
`AGENTS.md` describes what ko cannot change.

**The principle.** The host is the mediator inside its process; ko
is the mediator between panes. An exchange between two agents of one
koa (a task, a message, a report, a stop) is a call of the host: no
ko round trip, no ids and no resends. An exchange with an agent of
another pane goes through ko's message route, as before. The
extension never reads another agent's files and never opens ko's
socket.

## The tree

`share/koa/koa-agents.ts` owns the tree: the root, each agent's
children, the one `ModelRuntime` of the process (one `auth.json` for
every agent), the pane's message stream ("The pane's queue") and the
one queue of status records ("In the sidebar"). Each agent has its own
`AgentSessionRuntime`, its own services (cwd, settings, resource
loader, extension flags), its own extension instance, job registry,
routed context and page view (`koa-view.ts`). The agent extension
(`koa-agent.ts`) is an inline factory of each session; it reaches the
tree only through `AgentHost`, which names the agent it serves. A
subagent discovers its own resources (the agent directory's and its
cwd's `.pi/`); the root's command line options, such as
`--extension`, are not the child's.

The root is the session that koa starts from its command line; its
`/new`, `/resume` and `/fork` switch it through pi's runtime. A
subagent's runtime refuses those three: only the root replaces its
session. A committed replacement of the root stops its children
first, as a quit does; a cancelled one keeps them.

**Depth** is at most 2 (root 0, subagent 1, subagent 2), checked on
the tree.

**Names.** `spawn_agent` and `async_bash` require `name`. A name is 1
to 64 bytes, without control characters and without `/`, and is not
`.` or `..`; the extension checks it, because no server sees an
in-process name. A child's name is unique among the caller's
registry children and its live own children. A job's name is unique,
case-insensitive, among the running jobs and the caller's registry
children: an ended job frees its name, so a watcher can start again
under its name. `stop_async_bash` by name takes the running job of
that name, else the newest ended one. A moved `bash` call has no
name: its job id stands for it. A reused name is refused with
"message it instead" (spawn) or "choose another name" (async_bash).
A `toplevel` name is unique among the live agents of the caller's ko
session instead.

The registered name is the child's address and its record path. pi's
session name (`/name`) is a separate fact: it changes the title of
the session, not the address under which the parent registered it.

## The tools, and what they call

The eight tools are in `share/koa/koa-agent.ts`. No tool has a ko
subcommand of its own.

| tool | what it uses |
|---|---|
| `list_agents(which?)` | the host's tree, the own registry, and for the pane peers `ko api /layout` |
| `read_report(agent, which?)` | the own session's `koa.report` entries |
| `list_async_bash()` | the caller's job registry |
| `message_agent(to, message, mode?)` | the host for an agent of this process; `POST /panes/{t}/messages` for another pane; `POST /panes` to restart an ended peer |
| `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?, runtime?)` | the host's spawn; pi's session directories; `GET /runtimes/NAME`; `POST /panes` for `toplevel` |
| `stop_agent(agent, force?)` | the host's stop; for another pane `POST /panes/{t}/messages` kind `stop`, then `POST /panes/{t}/stop` |
| `async_bash(command, name, stream?)` | a child process of koa through pi's shell configuration (a routed agent: `ko api --stream /runtimes/NAME/exec`) |
| `stop_async_bash(job)` | `signalJob` on the job's own process |

A tool checks its own arguments and refuses them with a reason, which
the model reads as the tool result.

**Scope.** A caller's scope is its own tree by the rule of today's
pane tree: its children, its siblings, each ancestor and that
ancestor's siblings, all in its own process; and the pane peers of its
root: the root agents of the other pi agent panes of its ko session,
from `/layout`. Another pane's subagents never list and never
resolve by name: an agent of another pane reaches one only by its
explicit address ("Addressing an agent of another pane"). The page's
`@name` links and completion use the same scope, for the viewed
agent.

**list_agents** lists the scope, without the caller. `which` selects
`all` (the default), `peers` (the caller's siblings; the pane peers
for a root) or `subagents` (the caller's own children). A row is an
`AgentRow` of `koa-agent.ts`. Its `id` is the pi session and its
`where` says whether it runs in this process or names its pane. An
own child adds `model`, `reported` and `report`: the first 1000
bytes of its last report. `read_report` gives the rest. An ended own
child is a registry child with no live agent; it lists with its
cause: `stopped`, `koa restarted` or `its session ended on an error`.
An ended peer is a recorded peer ("Peers", below) whose session no
live pi agent pane runs; it lists under `all` and `peers` while its
session file exists.

**read_report** returns the whole text of an own child's last report,
or with `which: all` every report in order with its time, from the
caller's own session.

**list_async_bash** lists the caller's own jobs: all running and the
newest 20 ended, newest first. Each row names the job id, the name,
the command, the state, the end of an ended job, the start time, the
log and, for a routed job, the runtime.

## The registry: the own pi session

Each extension instance appends custom entries to its own pi session
with `pi.appendEntry`. Every entry carries `owner`, the appending
session's id, and `at`; an entry whose `owner` is not the own
session id is ignored. Thus, a `--fork` or `/clone` copy, which
copies the entries, inherits no children and no reports. The
extension reads the entries with `ctx.sessionManager.getBranch()` at
each use, so a `/tree` back past a spawn drops the child from the
registry (Limits, below).

The registry rests on these facts of pi's session API: a custom
entry is a tree entry under the leaf, so it belongs to its branch,
and `getBranch()` returns only the active branch's entries. `/fork`,
`/clone` and `SessionManager.forkFrom` copy entries under a new id;
that is why an entry carries `owner`. pi writes the session file at
the first user or assistant message, not at `session_start`, so a
child that never ran a turn has no file.

In the parent:

| entry | when | data |
|---|---|---|
| `koa.agent`, role `subagent` | at each spawn and resume | `name`, `session`, `model`, `fork`, `cwd`, the `runtime`'s name; the last entry of a name is current |
| `koa.agent`, role `peer` | when the `/client` stream shows a peer whose facts differ from its last entry, and at a top-level spawn or a peer restart (a root only) | `name`, `session`, `cwd`; the last entry of a session is current |
| `koa.work` | when the child's turn takes a user message or a message with `details.work`, and before the parent sends its own child work | `child` |
| `koa.report` | when the child reports, before the notice | `child`, `name`, `text` |
| `koa.ended` | when the child is stopped or its session ends on an error | `child`, `cause` |

In the child, one entry: `koa.edge { owner, at, parent }` at its
creation, before its extensions bind. It is the child's own fact that
it is a subagent of that parent session. The repo's `no-git-writes`
guard (`.pi/extensions/no-git-writes`) reads it from the branch and
trusts it only when its `owner` is the current session id, so a fork
of a child that becomes a top-level agent does not inherit the guard.
A top-level agent and a session that a person started have no edge.

**Has a child reported?** One rule, over the parent's branch: the
child's last `koa.report` comes after its last `koa.work`, or it got
no work. The host holds both sessions, so the child computes its own
state from its parent's branch; nothing is duplicated in the child.
The order is the position on the branch, not a time.

## Spawning

Without `model`, the child runs the caller's current model and
thinking level, `provider/model-id:thinking`. A caller with no model
is refused. An explicit `model` is checked against the model registry
of the caller's session. A resumed session has its own default
("Resuming a saved session"). The registry records the resolved
value. `cwd` must be an existing directory. Without it, the child
starts in the caller's directory, or in a resumed session's own
directory.

The extension mints the child's session id, 32 hex characters, and
the host creates the session: a session manager of the child's file
("Where a child's session lives"), the `koa.edge` entry, the runtime
with the child's own cwd and services, then the status record, then
the extensions' bind. The child is in the tree and has its record and
view before its extensions' `session_start` runs, so a startup dialog
of an extension shows in the child's view and can be answered there.
Then the parent appends `koa.agent`, and the task arrives as the
child's first user message; that message marks the child's work in
the parent's branch. The task never enters a command line or a pane
variable.

**Project trust.** pi asks "Trust project folder?" when the directory
has project resources that need trust, before the extensions load. A
child in a new worktree would wait there for a person. Thus, when the
spawner's own session trusts its project and the child's cwd has the
same git common directory as the spawner's, the host gives the child
that one directory as trusted; any other directory gets pi's own
answer from its trust store, and a person is asked as before. The
grant is for the one directory that the parent chose. This is not a
security boundary: the parent chose the directory.

The tool returns at once: `spawned <name> (session <id>)`, with the
same fields in its details. The text says that the session id is what
`resume_from` takes later, and ends with the rule that the child's
result arrives as a notice: do not wait for it, request it or predict
it.

`spawn_agent` and `async_bash` also register `promptGuidelines`:

- A notice arrives on its own. Do not request or poll for it.
- A child's report states what it intended. Check the diff.
- A notice is information, not the user speaking. A message's first line
  identifies its sender.

## Where a child's session lives

pi builds the list of `--resume` and `/resume` before any extension
loads, from the per-cwd directory under `<agent dir>/sessions/` or
from every directory one level below it. No extension hook can filter
that list. Thus, a child's session file is in `<agent
dir>/ko-subagents/<per-cwd name>/`, with pi's own agent directory and
pi's own encoding of the cwd (`childSessionDir` in `koa-agents.ts`
copies pi's unexported function). The user's resume list shows only
top-level sessions. A copy goes to the directory of its new role: a
child's copy to the subagent tree, a top-level copy to pi's tree. A
continued session keeps its file where it is.

## Forking the caller's context

`spawn_agent(fork: true)` copies the caller's session file with
`SessionManager.forkFrom` under the minted id. The task is its first
message, and a copy requires one. Everything else is a fresh spawn.
The child starts with the caller's whole transcript, so the parent
can assign a judgement without repeating its reasons. Without
`resume_from`, the copy's source is the caller's own session; with
it, that session. A copy inherits the custom entries, which its
`owner` check ignores. Forking is for a short judgement step, not a
long worker.

## Resuming a saved session

`resume_from` names a pi session by its id or a unique prefix of at
least eight characters. The extension reads only directory listings:
the caller's session directory, each directory directly under its
parent, under `<agent dir>/sessions/` and under
`<agent dir>/ko-subagents/`, and matches the id at the end of a file
name (`<time>_<id>.jsonl`). An exact id wins; otherwise the prefix
must match one file. Then it reads the header line of the match, where
pi records the session's working directory. A session that never ran
a turn has no file, so it cannot be resumed.

**Continue** (`resume_from` alone) opens the file: the same session
id, with its history, in its recorded directory; a different `cwd` is
refused. A session is refused while a live agent of this process or a
pane that is not dead holds it, and when it is an ancestor or a
relative of the caller. An own registry child resumes only under its
existing name. The checks and the creation run under one lock for
that session in the process.

**Copy** (`resume_from` with `fork: true`) forks the file under a
minted id. The original is unchanged, and a live original is not
refused, because pi only reads it.

**The model.** Without `model`, a continued or copied session gets
the model and thinking level that it last used, so a `/model` or
thinking change inside the agent survives its return. The extension
reads the file once, without pi's `SessionManager.open`, which can
write to it, and walks the current branch as pi's own resume does:
the last model change or assistant response sets the model, but a
response does not replace a virtual model that a change selected;
the last thinking level change sets the thinking level. A file that
records no model gets the caller's model. An explicit `model` wins.

**An empty task** is allowed only to continue a session. The session
comes back and starts no turn, and the child owes no report until its
parent sends it work.

## A top-level agent

`toplevel: true` starts the agent in a pane of its own with no parent
edge: one `POST /panes` with the caller's ko session as `session`, no
`parent` and no `close`, the command `ko shell -- koa` (with
`--browser` when the caller's host is in browser mode, the session as
`--session-id`, `--session` or `--fork`, the name and the model), and
the task as the pane variable `koa.task`, which the new root delivers
as a message from the caller and then deletes. This is the one
remaining use of `koa.task` and of `ko shell -- koa`. The server
places the window after the caller's window and names it in the same
change. It is a peer ("Peers", below): there is no subagent entry, no
notice and no orphan rule. The pane has the default `close: exit`.
`resume_from` reads the pi session, not the pane, so a closed
top-level agent stays resumable. The depth ceiling does not apply;
`fork`, `resume_from`, `model` and `cwd` apply as for a child. One of
the caller's own children cannot become top-level.

## Peers

A peer of a root is another root agent of its ko session: a pane whose
status kind is a pi agent (design.md, "The trust rule"), with
`pi.session` and no `parent`. It does not matter who started it.
A subagent records no peers.

**Recording.** A root of a host koa (no `KO_RUNTIME`) opens `ko api
--stream /client` after its own pane variables are written, with a
hello that shows no window, is not focused and takes no part in
sizing (protocol.md, section 3). It keeps the rows of the stream's
layout and events, and after each change it appends a peer entry for
each peer whose name, session or cwd differs from its last entry, so
a reconnect or a restart appends nothing for a peer that did not
change. A stream that ends without a `refused` event connects again
with a backoff that resets at the next `Welcome`; a `refused` before
the `Welcome` stops it. The session's shutdown ends the stream.

**Peer activity never notifies the agent.** A peer's start, end or
cwd change only appends entries to the own session.

**The model** of a peer is not recorded. A restart reads it from the
peer's session file by the rule of "Resuming a saved session".

**Names.** Two peers can have the same name; each is its own row, and
an address that matches several needs the session id or a unique
prefix (design.md, "Addressing"). A live agent wins over an ended
peer. A recorded peer does not reserve its name for `spawn_agent`.

**Restart and stop.** `message_agent` in `message` mode to an ended
peer restarts it as a top-level pane ("Restarting through a
message"), and `spawn_agent(name, resume_from)` of a recorded peer
continues it as a peer. A peer never gets `koa.work`, a report, a
notice or `koa.ended`.

## The pane's queue

A pane has one message queue (protocol.md, section 7), and every agent
of koa's pane shares it. The host owns the one stream (`ko api
--stream /panes/$KO_PANE/messages`), its ring of the last 4096
accepted ids and its acks (`koa-inbox.ts`); a `/reload` or a session
switch of the root does not touch them. Each message's `data` can
name its target and its sender: `to`, the target's session id, and
`from`, the sending agent's session and name when it is not its own
pane's root. The server stamps the pane sender and the relation as
for every message and reads no `data`.

- `user`, `message`, `steer`, `interrupt` and `notice`: absent `to` is
  the root; a `to` that names no live agent of the tree is refused,
  so the sender's tool says "no longer running"; malformed `data` is
  refused. The message goes to that agent's extension, which delivers
  it as before. With `data.from`, the sender header names that agent
  and its return address ("Addressing an agent of another pane").
- `stop` with no `to` shuts koa down; with `to` it is refused, because
  no tool sends one.
- `select` from the user switches the page's view to the agent of the
  record id in its text (the empty id is the root); one from a pane,
  or for an unknown id, is acked and ignored (design-koa.md, "Views").

Messages wait until the root has started and while a `/reload` runs,
so none reaches an extension that is being replaced.

## Addressing an agent of another pane

An agent's address is (pane, session). `message_agent` accepts,
beside the forms of design.md, "Addressing", `pane_N/<session id>`
with a whole session id. It is not resolved against a list: the tool
posts to `pane_N` with `data.to`, and that pane's host answers. A
sender learns the address from the header of a message that the agent
sent it: `message from @reviewer (session <id> in pane_7; ...)`.
There is no lookup from a session id alone: ko keeps no such fact.
`stop_agent` and `read_report` do not take the form.

## A child's life

Every turn's system prompt of a child contains these standing
instructions:

- While a non-service async job of your own is running or a subagent
  of your own still owes a report, ending your turn sends nothing to
  your parent.
- You were spawned. Your report is the last message of a turn that
  ends after all of them finish. A message that says you wait is a
  report too; a later turn of the same work that ends with a new
  message sends a further report. It must stand on its own.
- If you stop to wait for another agent or the user, say so; when the
  work completes later, tell your parent with `message_agent`.
- Reporting does not end this session: the parent ends it with
  `stop_agent` and continues it with `message_agent`.

**Reporting.** When a turn of the child settles idle (`agent_settled`
with `ctx.isIdle()`), its last assistant message is the report: the
concatenation of that message's `text` blocks. The settle reports
only if all of these are true:

1. The child is in the tree under a live parent and is not stopping.
2. The turn was not aborted, and no interrupt ended it.
3. The turn did not stop on a provider error. Such a turn sends the
   error notice instead.
4. The child has not reported on its last work, or the turn's last
   message is not empty and differs from its last report on that
   work. A later turn of the same work, which a stream batch or a
   notice woke, sends its real result as a further report; one that
   ends with no message or the same text sends nothing.
5. No own job is running, except service jobs ("A job"), and no own
   live child owes a report. When the last one ends or reports, its
   notice wakes the child for a turn whose last message is the
   report.

The parent appends `koa.report` with the whole text, then its model
gets a notice (`deliverAs: "steer"`, `triggerTurn: true`) of at most
4000 bytes with the guidance included: a report that does not fit
sends its start and the line `full report: read_report("<name>")`. An
empty last message reports `subagent "<name>" ended its turn with no
message`. A user who types into a child's view gives it work too, so
that child reports to its parent when the turn settles.

**A child that waits on something ko cannot see**, such as a peer's
message or a file, reports when its turn ends. Its last message says
what it waits for.

**The error notice.** A turn that stops on a provider error sends
`subagent stopped on an error: <error>` and `message it to retry, or
stop_agent to end it`, once for each failed attempt. It writes no
report entry.

There is no exit notice and no ending message: a child ends only
through its parent, an agent of its scope, the user or koa's own end,
and in every case the one who ended it knows.

**The parent ends a child.** A child has no idle timer. After it
reports, it stays alive until `stop_agent`, a stop of an ancestor, or
koa's end.

**Stopping.** A stop of an in-process agent stops its subtree,
deepest first. First every member is marked stopping, so it sends no
report and takes no new message or spawn. Then for each: its dialogs
are cancelled, its runtime's `dispose()` aborts the turn, runs pi's
`session_shutdown` (which stops the agent's jobs, "Stopping a job")
and disposes the session; its record is cleared, which clears its
subtree's records; the parent appends `koa.ended`. When the viewed
agent is in the subtree, the page switches first to the nearest
ancestor that survives. A stop of the root shuts koa down. A caller
that stops its own ancestor gets its result first; the stop runs
after the tool returns, because the caller's own abort cannot wait
inside its tool.

## Redirecting one, and ending one from outside

`message_agent` has three modes, and all three reach any agent of the
scope:

- `message` queues with `followUp` until the receiver's turn ends.
- `steer` leaves the turn running and adds the text inside its loop,
  as a `ko-steer` custom message with `deliverAs: "steer"`. An idle
  receiver starts a turn with it.
- `interrupt-and-steer` marks the receiver's turn as ended by a
  control, holds the text and aborts the turn. pi's extension
  `abort()` returns before the run ends, and a message sent while the
  run streams is a follow-up that the aborted run never drains. Thus,
  the receiver delivers the held text at the run's `agent_settled`,
  as an ordinary message from its sender. An idle receiver delivers
  it at once. The aborted turn's settle sends no report and no error
  notice.

A message and a steer from the parent carry `details.work`, so the
child's `message_start` marks new work in the parent's branch. There
is no interrupt without text.

**To this process.** The host delivers directly: the same custom
messages, headers and `details` as from a pane, the relation from the
tree. The result is `delivered to NAME` or the refusal.

**To another pane.** Every send mints one id, 128 random bits as 22
base64url characters, for one intent, and keeps it for that intent's
retries. A tool call posts up to three times, again on `delivered` or
`io`, `KO_RESEND_MS` (1 s) apart, then reports the last state:
`delivered to N` (acked), `queued for N` (the agent is not receiving
and reads it when its stream returns), or `sent to N: written ..., not
yet confirmed`. A sender that is not its pane's root adds
`data.from`, an explicit address adds `data.to`.

**stop_agent** resolves one address in the scope by the addressing
rules of design.md and refuses only the caller. An agent of this
process stops by "Stopping" above; `force` is refused for it. An
agent of another pane with an open message stream gets kind `stop`;
then the extension sends `POST /panes/pane_N/stop` with `wait_ms:
5000`, whatever the request returned. A target without a stream is
refused unless `force`, which skips the request and stops the pane
with `wait_ms: 0`. Lines: `stopped NAME; it had reported`, `stopped
NAME; it had not reported on its last work`, `stopped NAME` for a peer
or ancestor, `NAME had already ended: <cause>`. The result is the only
signal.

## Restarting through a message

`message_agent` in `message` mode to an ended own child or an ended
recorded peer starts it again. A child resumes in this process under
its registered name: its session file opens again ("Resuming a saved
session"), on the file's last model (the registry's `model` when the
file records none), and the message is its next turn. Only the
parent resumes its child; `steer` and `interrupt-and-steer` to an
ended child are refused. A name resolves to a live agent first, then
to an ended registry child. A child resumes once at a time: a second
message during the resume finds the live agent.

This is how a child comes back after koa's `execve` restart: the new
koa starts only the root, every registry child lists as ended with
`koa restarted`, and a message resumes it.

A peer restarts as a top-level agent ("A top-level agent") with
`--session <file>` in the directory of the file's header, on the
file's last model, and the message as `koa.task`. It is refused
without a session file. A peer entry has no pane, so the extension
keeps the new pane in memory as the peer's starting pane until it
publishes `pi.session` or ends; a second message in that time goes
to it. No `koa.work` is written, and the reply asks for no report.

## In the sidebar

Each in-process agent other than the root is a status record of koa's
pane, written through `POST /panes/$KO_PANE/status` in one ordered
queue with the job records. The id is the path of registered names
from the root: `agents/<a>`, `agents/<a>/agents/<b>`; an agent's jobs
are `agents/<a>/jobs/<id>` and the root's are `jobs/<id>`. The id is
koa's own: ko and the clients read only its `/` nesting
(design-program-status.md, "The record set"). The title is the name;
the state is `working` while a turn runs, `blocked` with kind
`question` while a dialog of that agent is open (the message is its
title), `done` or `error` at the settle and `idle` after an abort; the
message is the error's first line, else the first line of the last
assistant text. `selection` is `selected` for the viewed agent and
`offered` for every other; a click on the row in Kido.app sends the
`select` message ("The pane's queue"). The root's own record stays
koa's OSC 7501 root and names the root, whatever the page shows.

## A job

A job is a command that runs in the background as a child process
of koa, and that tells the agent that started it once it ends. It is
not a pane: it has no window, and its row in the sidebar is a status
record of koa's pane ("A job's row"). Two tools make one:

- `async_bash(command, name, stream?, service?)` starts a job.
- A `bash` call that still runs after `KO_JOB_MOVE_MS` (60 000)
  becomes a job ("The bash tool's move").

**The registry.** Every job is a `Job` record of its agent's registry
(`JobRegistry` in `koa-agent.ts`). The tree creates one registry for
each agent and keeps it for the agent's life, so it outlives one run
of the extension's factory. The pipe listeners of a job write its log
and its buffers and never call pi; the registry reaches pi only
through the agent's current extension instance. Thus, a job and its
output survive `/reload`, whose old instance can no longer send a
message ("Jobs across /reload"). The registry keeps every running
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
no size cap: `<tmpdir>/koa/<session id>-<job id>.log`, the
directory mode 0700 and the file 0600. It is never deleted, as pi's
own `bash` output files are not: the user or the model reads it after
the end. Only the in-memory tail (64 KiB) is bounded. The result of
`async_bash` names the job id, the name and the log.

**Exactly one notice.** At the end, the harness sends one notice
(`deliverAs: "steer"`, `triggerTurn: true`):

    job "build" (j4k2m9qp) exit 3
    --- last 4000 bytes of its output ---
    ...
    log: /tmp/koa/<session>-j4k2m9qp.log

The first line names the end: `exit N`, `signal NAME`, `failed:
<message>`, or `timed out after N s`. The tail is the last 4000 bytes
with escape sequences stripped, because failure information comes
last. A job that `stop_async_bash` stopped sends none; a stop of an
ended job answers `had already ended` with its end. Each job sends
its own notice; the extension groups none.

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

Each job is a child record of koa's pane, which the agent extension
writes
through the status route (protocol.md, section 6), so Kido.app
draws it as a child row under the pane row (design-program-status.md,
"The record set"). A foreground `bash` call has no record. It gets
one when it moves. A routed job has one as a local job does.

- The id is `jobs/<job id>` for the root's jobs and
  `agents/<a>/jobs/<job id>` for a subagent's ("In the sidebar"). A
  job id is unique in its registry, so a clear of an agent's `jobs`
  removes its job records and nothing else.
- The title is the job's name, so a row reads name first and command
  second. While the job runs, the state is working and the message is
  the command. A running service is idle: it is not the agent's work,
  so it does not make the pane or the folded circles of its ancestors
  look running. When it ends, the state is done
  for exit 0. Every other end is error: an exit code, a signal, a
  failure to start, a timeout or a stop. The message is the end text
  of its notice (`exit 3`, `signal SIGTERM`).
- The title and the message are sanitized by the extension's own rule:
  pi-tui's control character replacement, then whitespace collapses
  to one space. The text is cut at a UTF-8 boundary to the route's
  limits. An empty title or message is omitted.
- A finished record lingers for `KO_JOB_RECORD_LINGER_MS` (5000).
  Then the extension clears its id. A job's record never changes the pane's
  status: an agent's status comes from its root record alone
  (design-program-status.md, "Reduction").

**The writer.** Every record of the pane, job and agent alike, is one
`ko api POST /panes/$KO_PANE/status` through the tree's one queue,
never koa's stdout, which is the pane's screen. The posts go one after
another, in the order of the changes; a failed post is dropped, and
the next change writes it again. The queue is ordered only against
itself: a post in flight can land after koa's root clear and bring
that row back early.

**At most 32 records.** The server's set has a limit, and a new record
over the limit removes the oldest record. That can be pi's root
record. Thus each agent's extension admits at most 32 job records at
once.
When a new job needs a slot, it clears the oldest finished record
first. When all 32 jobs run, the new job gets no row, also not at its
end. The cap is the extension's own, not a server rule.

**Root clears.** A root clear removes every record of the pane, the
job and agent records too. koa writes one only when it exits
(design-koa.md, "Status and title"). Thus the extension writes a
job's record only at each change of that job, never on a timer or on
each key.

**Across /reload and quit.** The records and their linger timers
belong to the registry, so a `/reload` leaves them as they are. Every
other shutdown of an agent clears its `jobs` before it stops the
jobs, so a stopped job writes no record after the clear. The host's
exit handler clears the root's `jobs` and `agents` with a synchronous
`ko api` call, because Node runs no asynchronous work in an `exit`
handler; a post that is in flight at the exit can land after it.

## Stopping a job

Every signal of the extension goes through `signalJob(job, signal)`, which
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
group (design-runtimes.md, "The exec session"). The extension sends no
`signal` frame. A process that leaves its group (`setsid`) escapes.

A stop sends `SIGTERM`, then `SIGKILL` after `KO_JOB_KILL_MS` (5000)
when the job still runs. The host's one `process.on("exit")` handler
sends `SIGKILL` through `signalJob` to every local group of every
agent that still runs at koa's exit. `scripts/lint.sh` refuses
`process.kill(` in `share/koa/` outside `signalJob`.

**Known limit: an orphan after `SIGKILL`.** A pane's hangup sends
`SIGHUP` to koa's group and `SIGKILL` 250 ms later. koa's `SIGHUP`
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
it for the next try. A pipe loses nothing, so no batch reports lost
bytes. At the end, the partial last line and the held lines go before
the notice, without the throttle: the model never reads "this is how
it ended" before the output.

## The bash tool's move

At `session_start`, when the `bash` of `pi.getAllTools()` is pi's
builtin (`sourceInfo.path` starts with `builtin:`), the extension registers
a `bash` with pi's own definition (`createBashToolDefinition`, with
the user's `shellPath` and `shellCommandPrefix`), whose operations
are `handoff(localExec)`. An extension tool with a builtin's name
replaces it. A routed agent's `bash` is the extension's routed tool, with
`handoff` over the exec session. Another extension's `bash` stays
alone: no move. `!` commands are not wrapped.

- A `timeout` under `KO_JOB_MOVE_MS` passes through: the command is
  stopped at its timeout with pi's timeout error.
- No `timeout`, or a longer one: at `KO_JOB_MOVE_MS`, the running
  command becomes a job and the call returns at once, not as an
  error: `still running after 60 s; it continues as job ID; a notice
  arrives when it ends; output so far:`, the tail, and the log. The
  command is not stopped. An explicit timeout becomes the job's
  deadline, and its notice reads `timed out after N s`.
- A call that runs at a `/reload` shutdown moves, because the new
  instance cannot complete the old call.

The foreground call keeps the last 64 KiB of its output, so a moved
job's log starts with it; when the call produced more, the first line
of the log says that the earlier output is cut.

## Jobs across /reload

`session.reload()` runs the extension's factory again in the same
process, so the children and their listeners live on. These facts of
pi decide the design; a probe extension observed them through one
`/reload`:

- A child and the `data` and `close` listeners of the old instance
  keep firing after the reload, beside the new instance's own.
- `session_shutdown` with reason `reload` runs on the old instance,
  then the new factory, then `session_start` with reason `reload`,
  about 150 ms later.
- After the reload, the old instance's `pi.sendMessage` throws ("This
  extension ctx is stale after session replacement or reload").

Thus the registry keeps a job's output and ending as plain data, and
only the agent's current instance calls pi. At `session_shutdown`
with reason `reload`, the extension moves its running `bash` calls;
the registry, its records and its deadlines stay with the host. When
the new instance binds, the registry delivers through it, once, the
notice of each job that ended in the gap and the held lines of each
streaming job, whose UTF-8 carry crossed the reload. A notice that
fails stays owed for the next try.

The other reasons (`quit`, `new`, `resume`, `fork`) stop every job of
the agent and wait up to `KO_JOB_KILL_MS` for the ends.

koa's `/reload` restarts koa only when nothing would be lost this
way: the tree's `restartState()` adds up every agent's running jobs,
services included, and its children that have not reported on their
last work (design-koa.md, "`/reload` reloads pi"). `/restart` does
not ask: it is the escape hatch, and the jobs end with the process.

## A human at a shell

A human uses ko's own commands, not the tools:

- `ko prompt` sends text to the root agent of a pane as kind `user`,
  which the agent reads as the user's own words (design.md, "Delivery, and
  when a paste is allowed").
- `koa` in a pane starts a top-level agent.

A shell has no message stream and no session. It cannot receive a
message or a notice.

## Limits

- Every agent of a pane shares koa's process: a fault that ends koa
  ends them all, and the pane shows the error (design-koa.md, "The
  process").
- A `/tree` back past a spawn drops the child's registry entry. The
  child lives on in the tree and can be messaged, but after it ends it
  cannot be resumed by name.
- A message queued for a pane that dies is dropped without word to
  its sender.
- An agent of another pane reaches a subagent only by its explicit
  address, which it learns from a message of that subagent.
- The escape stripper is simpler than a terminal: a sequence it does
  not know reaches the model as noise. The log keeps the raw bytes.
- A job of a koa that ends with `SIGKILL` is an orphan ("Stopping a
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
- Nesting stops at depth 2.
- `/reload` forgets the last turn's error.
- A child idle behind a job that never ends, such as a watcher, never
  reports while that job runs.
- A root records only the peers that its `/client` stream shows. A
  peer that starts and ends while the stream is down, or while this
  koa does not run, is never recorded.
- A koa inside a runtime records no peers: the runtime gate refuses
  `/client` (design-runtimes.md, "Identity on a runtime connection").
- A routed peer restarts as a host koa: a peer entry holds no runtime.
- Two roots that record one peer can both restart it at the same
  time, because each restart lock is in its own process. Then two
  processes write one session file.
- The live check of a resume reads this process and the panes' `pi.session`.
  Two koas that resume one saved session at the same time can both
  pass it, and two processes then write one session file.
