# Agents without runs, with ko as the mediator

This plan replaces the run-based subagent of
[design-subagents.md](../docs/design-subagents.md) with a pane that
has a parent, and moves every exchange between agents into ko. ko
keeps no record of an agent after its pane goes. pi's session files
keep what the harness knows, and each harness keeps only its own.
Runs stay for `async_bash` and `ko run`.

**The principle.** ko is the mediator. ko-pi uses only ko's API
through `KO_SOCKET`. It never reads another agent's files and never
connects to another agent's socket. Its own data lives only in its
own pi session. Thus, the same harness works when a pane runs in a
container, on an ssh host or in a VM, whose `KO_SOCKET` is a
runtime-scoped socket and whose filesystem is not the host's
(section 9).

User decisions that this revision applies: `close` is the enum
`keep | on_exit`; `stop_agent`, `steer` and `interrupt-and-steer`
reach every agent in the mention scope; a quitting ko-pi stops its
own `async_bash` runs; no new CLI commands; `stop_async_bash` takes
one target; the pane wait is dropped for the queued `ended` message;
the message endpoint is generic and queues up to 64 MiB for each pane;
the output stream is in this plan; trust is by the child's cwd
(`KO_AGENT_TRUSTED_CWD`, 5.11); message ids are sender-generated and
idempotent (2.6), so a sender resends on an unknown outcome instead
of "never resend"; the report in `list_agents`
is capped with a reference that is not `list_agents`; the earlier
deviations (no session-file variable, the task by variable, runs with
`parent` and `close`, the screen tail, the exit notice) are accepted.

## 1. Prototype findings: pi's session API

A scratch script under `/tmp` ran pi 1.4.0's `SessionManager`
(`dist/index.js` exports it; `ReadonlySessionManager` is the type of
`ctx.sessionManager`). The design now reads only the own session, so
item 1 is no longer needed; it stays as evidence.

1. `SessionManager.open(path)` reads another session's file
   read-only, and `getBranch()` returns the active branch's custom
   entries. `open` rewrites only a version 1 or 2 file.
   `parseSessionEntries` skips a line that does not parse.
2. **Custom entries are branch-scoped.** `appendCustomEntry` writes a
   tree entry under the leaf. After `branch(id)`, an entry on the old
   branch was absent from `getBranch()` and present in `getEntries()`.
   `pi.appendEntry` calls `appendCustomEntry`. A compaction keeps the
   path.
3. **What a copy copies.** `/fork` and `/clone` call
   `createBranchedSession`: the root-to-leaf path with its custom
   entries, under a new id. The CLI's `--fork` calls `forkFrom`, which
   copies every entry of every branch; `--fork --session-id ID` gives
   the copy the chosen id. Thus, registry entries need an owner tag.
4. **`--session-id` lets the parent choose the id.** pi opens the file
   of that exact id in the cwd's project directory (`findById`, which
   reads headers), else creates a new session with that id and prints
   a warning. Ids of letters, digits, `.`, `_` and `-` pass; ko-pi's
   32-hex ids pass. A restart is `ko-pi --session-id ID` in the
   recorded cwd, with no file path.
5. **The file's path** is `<sessionDir>/<time>_<id>.jsonl`, known from
   `session_start` as `getSessionFile()`, but written only at the first
   user or assistant message. A custom entry before that waits in
   memory. A child that never ran a turn has no file.
6. **`--no-session`** gives an in-memory session with the chosen id
   and no file. ko-pi does not use it.

## 2. The server

### 2.1 The new pane fields

`CreatePane` (`ko_server/src/protocol.rs`) gains these fields, and
the pane's `Row` carries them for the pane's life:

- `parent: Option<PaneId>`. Immutable. The parent must be a pane of
  the document that is not dead: `missing` for an unknown pane, `gone`
  for a dead one. No cycle can form, because the parent exists before
  the child and the field never changes. A caller with a pane identity
  (2.8) may name only itself as `parent`.
- `close: Close`, a unit enum: `keep` (default, absent from JSON: a
  dead pane stays, as any command pane does today) or `on_exit` (the
  sweep removes the pane after it has been dead for the linger grace,
  `KO_LINGER_SECONDS`, unless a client with terminal focus shows it).
  A later `on_success` could remove only a pane that exited 0; it is
  not in this plan.
- `runtime: Option<RuntimeName>`. Immutable, absent for the host.
  ko-runtimes.md
  defines the name and the rules; its U1 adds the field (section 12).
  The layout event that adds the pane carries it (2.9).

`Seen` (`ko_server/src/runs.rs`) gains `parent` and `close`, and
loses `pi_evidence`, whose only reader was the pane-parent rule.

### 2.2 One sweep for panes and runs

The sweep reads the rows, not the run meta:

1. A pane with `close: on_exit`, dead for the grace: remove it.
2. A pane with `parent` whose parent pane is gone or dead: remove it,
   live or dead.

Both skip a shown pane and try again at the next focus change. When
the removed pane carries a run, the sweep first records the run's
outcome as today and captures the screen into the run directory
(2.7). A pane without a run gets no record and no capture.

`POST /runs` sets the run pane's `parent` (a `Parent::Pane` as given;
a `Parent::Run` resolved to that run's pane) and `close: on_exit`.
The run meta's `parent` serves `ko runs --parent` and the history
only. The rule "a pane parent shows neither a pi root nor
`pi.session`" leaves the server: a child of a pi that quit inside a
living shell pane ends through its own parent watch (5.9), and a
quitting ko-pi stops its own bash runs (5.10).

### 2.3 `POST /panes`

Creates one window with one pane as one server-made `PUT` of the
document, like `POST /runs`. Body `NewWindow`:

    { session?: SessionRef, name?: Name, runtime?: RuntimeName, #[serde(flatten)] pane: CreatePane }

Reply `Created { session, window, pane }`. A pane's runtime is the
caller's connection's runtime when the caller is a runtime pane, else
`runtime` when given, else the host. A runtime caller that names a
`runtime` other than its own is `refused`. A `parent` in another
runtime is permitted only for a host caller. The request returns when
the pane exists; a runtime that is not yet up starts in the pane
(ko-runtimes.md, section 4). The same field and rule apply to `POST
/runs` and to a new pane of `PUT /layout`; there is no `--runtime`
flag on any `ko` command, the API carries it. Defaults: `session`
explicit, else the parent's, else the caller's, else a new session
with no name. Position: after the parent's window, else after the
caller's window, else at the end. `name` is the window's name in the
same change. No client switches to the window. The `vars` are the
pane's initial variables with the limits of protocol.md, section 7.
Errors: `invalid`, `missing` (session or parent), `gone` (dead
parent), `io` (the pane cannot start; the old document is kept). The
top-level spawn uses this one request instead of `add_window` and
`rename_window`, so no unnamed window flashes.

### 2.4 `GET /panes/{id}/output`: the raw output stream

A WebSocket that carries a pane's pty bytes from the ring, for a
reader that has no terminal decoder. Query `offset?`: absent, the
stream starts at the pane's current offset; inside the ring, it
starts there (the resume path); outside the ring, it starts at the
oldest byte the ring holds after a `skip`. Server to client, text
messages only, so `ko api --stream` prints each as one line:

    { type: "bytes", offset, data: base64 }
    { type: "skip", from, to }        the ring overran the reader; bytes from..to are lost
    { type: "dead", at, cause }       the pane died; the close follows

Consecutive `bytes` have consecutive offsets. The server writes a
record only while the connection's queue is empty; when a write would
block, it stops and, on drain, resumes from the ring at the reader's
offset, or sends `skip` when the ring moved past it. Thus, the memory
of an output stream is the ring, and it never spills and never sends a
snapshot. A view (protocol.md, section 4) stays the client's stream:
its backpressure path sends compressed libghostty snapshots, which
only a terminal decoder can apply, and that is the reason the harness
cannot read a view. The output stream reuses the view's ring reader
(`ko_server::delivery`, Verus-verified), so its proofs gain a second
consumer without a snapshot; this is the one costly part (section 12).
The caller must be the user, the pane itself or its parent (2.8).

There is no `GET /panes/{id}/wait`: the parent gets a child's ending
as the `ended` message on its own stream (2.6), a human reads the
row's `dead`, and a run has `run-wait`.

### 2.5 `POST /panes/{id}/stop`

Body `StopPane { wait_ms }`. Records nothing. It waits up to
`wait_ms` for the pane to die, then removes it; the removal hangs up
the program, and the coordinator kills a removed pane that lives past
`KO_STOP_ESCALATION_MS`. `WaitKind::Stopping` and `kill_run_pane`
move from `run_ops.rs` to `state/pane_ops.rs`. A dead pane is removed
at once; an unknown pane is `missing`. The caller must be the user or
a pane whose scope holds the target (2.8). `POST /runs/{id}/stop`
records the outcome, then calls it. `ko run-stop` is unchanged. ko-pi
calls `ko api -X POST --input - /panes/pane_N/stop`.

### 2.6 Messages through ko

The per-agent inbox socket and `pi.inbox` go away. The server carries
every message between agents, and `ko prompt`'s text.

**The stream.** `GET /panes/{id}/messages` upgrades to a WebSocket
on which the pane receives its messages. Only the pane itself may
open it (2.8), and a pane has at most one: a second upgrade is
`refused`, "the pane already has a message stream", so a pi that a
tool starts inside the pane cannot take the pane's messages. The row
gains `inbox: bool`, true while the stream is open, with a `ClientEvent::Inbox
{ pane, inbox }` on each change; Kido.app's `inbox` reads it, and
prompt scope uses it in place of `pi.inbox`. A close, a ping timeout
or the pane's death closes the stream.

**The send.** `POST /panes/{id}/messages`, body `SendMessage`:

    { id: MessageId, kind: message | steer | interrupt | stop | notice, text: String, data?: Value }

`id` is the sender's: 8 to 64 characters of `[A-Za-z0-9_-]`, with at
least 96 bits of randomness (ko-pi mints 128 random bits as 22
base64url characters); a shorter or malformed id is `invalid`. `text`
is at most 1 MiB minus the head, the body limit; `data` is at most
4 KiB of JSON, for the harness's own marks. The server stamps
the sender from the caller's pane identity (2.8): `from: { pane,
session?, name?, runtime? }`, where `session` and `name` are the
sender pane's `pi.session` and `pi.name` under the trust rule,
`runtime` the sender pane's runtime, so a receiver's header can say
`(in runtime dev)`, and `relation`, which
the server computes from the `parent` edges: `parent`, `child`,
`sibling`, `ancestor`, `ancestor_sibling`. The user (no pane identity)
sends with `from: { user: true }`; `ko prompt` sends `kind: user`
through the same path, and a non-pi candidate still gets a paste. The
receiver gets one text message:

    { seq, id, from, relation, kind, text, data? }

`id` is the sender's id, so the receiver can also drop a repeat.

**Idempotent ids.** The server delivers each `(pane, id)` at most
once. A repeat of an id that the pane has seen is not enqueued; the
request answers with the original message's state and `duplicate:
true`, and a repeat of a written, unacked message waits for its ack
as the first request did. The body of a repeat is not compared: the
id decides, and a sender that reuses an id for another text has a bug
of its own. Thus, a sender may always resend after a timeout, an `io`
error or a dropped connection, and gets the truth. The server
remembers ids for the pane's life, in two places: a queued or written
message holds its id in the FIFO, and an acked or refused message
leaves its id and final state in a per-pane ring of the last 4096
ids, oldest out first, so the memory of ids is bounded by the queue
cap plus 4096 small entries. A repeat older than that ring is a new
message; a sender resends within seconds, not after 4096 later
messages. The ring goes with the pane.

**The endpoint is generic.** The server does not read `kind` or
`text`; it stamps the sender and the relation, enforces the scope
and carries the bytes. The kinds above are ko-pi's vocabulary.

**The queue.** Each pane has one FIFO of messages, and `seq` counts
them in arrival order. The server writes the head of the FIFO to the
stream while the stream is open and fewer than 16 written messages
wait for an ack; the rest stay queued. Without a stream, every
message stays queued. The queue holds at most 64 MiB of message
bytes (`text` and `data` as sent) for each pane; a send that would
pass the cap is `refused`, "the pane's message queue is full". A
receiver that connects gets the queue in order, then the live sends,
which enter the same FIFO. A message has three states:

- `queued`: in the FIFO, not written.
- `delivered`: written to the stream.
- `acked`: the receiver answered `{ type: "ack", id }`, naming the
  sender's id.

A stream that closes with written, unacked messages puts them back at
the head of the FIFO in `seq` order, and the next stream gets them
again: the receiver drops a repeat by its id, so a write is safe to
repeat.

**What the sender's POST returns.** When the message is written at
once, the request waits for the ack as a `Wait` of the loop with a
2 s timer: an `ack` is `200 { state: "acked", seq }`, the receiver has
the message and sees it at its next turn boundary; `{ type:
"refuse", id }` is `refused`; the timer is `200 { state: "delivered",
seq }`, the message is written and not yet acked, and the sender
resends with the same id when it wants the final state. When the
message cannot be written at once (no stream, or 16 unacked ahead of
it), the request returns `200 { state: "queued", seq }` at once; a
later ack or refuse of a queued message updates the state that a
repeat reads. A POST to a dead pane is `gone` ("pane_N is dead"), to
an unknown pane `missing`. A request whose connection drops before
the reply leaves the message where it is; the sender repeats it.

**When the pane dies.** Its queue is dropped. A sender whose message
was `queued` does not learn it, as a sender to a process that crashes
does not; `list_agents` shows the pane dead. The `ended` message
does not count the dropped messages (decided): the parent knows what
it sent, and a count would not say which. A sender that must know
sends again to the restarted pane.

**A queued `stop`.** The server accepts it like every kind: it does
not read kinds, and a receiver that connects and reads `stop` ends,
which is what the sender wanted. ko-pi's `stop_agent` does not depend
on it: it sends the request only to a pane with an open stream, waits
`wait_ms`, then kills the pane; without a stream it refuses unless
`force`, which kills at once (section 4).

**The receiver.** ko-pi reads the stream through `ko api --stream
/panes/$KO_PANE/messages`, a new flag of `ko api` (open question 1):
it upgrades, prints each text message as one line on stdout, sends
each line of stdin as a text message, and exits when the socket
closes. The extension acks after `sendMessage` returned, and
restarts the process with a short backoff when it exits; a `/reload`
parks it on `globalThis` as the inbox server is parked today. Before
it hands a message to pi, the receiver checks the id against its own
ring of the last 4096 received ids, held on `globalThis` across a
`/reload`: a repeat is acked and not delivered. What each kind does:

| kind | the receiving extension |
|---|---|
| `user` | `sendUserMessage` as the user's own text (`ko prompt`) |
| `message` | a custom message with the header `message from @<name> (<relation text>[, in runtime R]):`, `followUp`; `details.work` when `relation` is `parent` |
| `steer` | a `ko-steer` custom message, `steer`; `details.work` when from the parent |
| `interrupt` | holds the text, marks the turn ended by a control, calls `abort()`; delivers the text at the settle as a `message` |
| `stop` | `shutdown()` through the one teardown |
| `notice` | a `ko-notice` custom message, `steer`; a report when `data.report` is set (5.4) |
| `ended` | server-made (below): the ending notice of a child (5.7) |

**Server-made endings.** When a pane with `parent` dies or leaves the
document, the server sends `{ id: "ended-<pane>", kind: "ended", from:
{ pane }, end: { type: "dead", at, cause } | { type: "gone" } }` on the
parent's stream, queued like any message, so a parent in a reload gap
reads it when its stream returns. A parent whose own pane dies loses
its queue with it.

**What `pi.*` remains.** `pi.session`, `pi.name` and `pi.activity`.
`pi.inbox` goes. The trust rule for them is unchanged.

### 2.7 Runs without an output file

`KO_RUN_OUTPUT` and the `tee` wrapper go. A run's output is its pane's
content: `GET /panes/{id}/screen?history=all` or the output stream (2.4)
while the pane exists, and the run directory's `screen` after the
sweep, captured with `history=all` up to `KO_RUN_SCREEN_BYTES`
(64 MiB, replacing the 64 KiB `SCREEN_MAX`; the end is kept). The run directory keeps
`meta.json`, `outcome` and `screen`. `ko runs ID` prints the screen.
`ko run --name N -- CMD` starts a parentless run pane with `close:
on_exit`. `Started` loses `output`.

### 2.8 Identity and scope in the server

**Pane identity.** Every pane gets `KO_PANE_TOKEN`, 16 random bytes
as hex, minted at creation and kept in the `Pane`. A request that
acts as a pane sends `Ko-Pane: pane_N` and `Ko-Pane-Token`; the
`ko` CLI sends both from its environment. A header pair that does not
match is `refused`. A request without the headers over the local
socket is the user: the socket's mode and the peer uid check already
give that user everything. A connection carries an `Origin`, `Host`
or `Runtime(name)`, from the listener that accepted it. On
`Origin::Runtime(R)` a request must carry a valid pane identity of a
pane whose `runtime` is `R`, else it is `refused`; the user identity
does not exist there, and `/client`, views and search are `refused`
there. The token is checked the same way on both origins. Every
process inside a pane inherits the token, so a pane is one trust
unit: the agent is its pane.

**The scope rule**, over panes and `parent` only, within the
caller's ko session:

    children(c)  = panes p with parent(p) = c
    siblings(c)  = panes p with parent(p) = parent(c), p ≠ c
                   (for a root, the other root panes of the session)
    ancestors(c) = parent(c), parent(parent(c)), ...
    scope(c)     = children(c) ∪ siblings(c) ∪ ⋃ a ∈ ancestors(c): {a} ∪ siblings(a)

| request | the caller c may act on t when |
|---|---|
| `POST /panes/{t}/messages`, every kind | t ∈ scope(c) |
| `POST /panes/{t}/stop` | t ∈ scope(c) |
| `GET /panes/{t}/output` | t = c or t ∈ children(c) |
| `GET /panes/{t}/messages` (the stream) | t = c |
| `POST /panes` with `parent` | parent = c |
| `POST /runs` with `parent` | parent = c, or a run whose pane is c |
| `PUT`, `DELETE` on `/panes/{t}/vars` | t = c |

A refused scope is `refused` with the reason. Reads stay open for a
host caller: the layout is one document for every client. The user
may do everything. On a runtime connection, reads are narrowed: rows
and `/panes/{t}` only for panes of the caller's runtime and
`scope(c)`; `/screen`, `/clear_history`, `/input` and resources only
for panes of the caller's runtime or descendants of `c`; a hidden
pane is `refused`. The table's rows for `/output`, `/messages`,
`/stop`, vars writes, `POST /panes` and `POST /runs` apply unchanged,
so a parent and a child in different runtimes exchange messages,
endings and stops as local ones do. ko-pi keeps a check of its own
only to word its refusals; the server's check is the one that holds.

### 2.9 Events and schemas

`parent` and `close` are immutable: the layout event that adds the
pane carries them. `inbox` has its event. A pane's death is the `dead`
event, its removal a layout event. `GET /version` adds `instance`.
`make schemas` regenerates the three schema files; the app
regenerates `KoSchema.swift`.

## 3. The clients

**The tree.** `Model::outline` nests a window under the pane that the
window's first pane with a `parent` names, in document order; every
pane of that window follows it. The run meta's parent is no longer
read for the tree. A parent that is absent or in another session
leaves the window a root.

**The lingering window.** Kido.app's field column shows a dead pane
with `close: on_exit` by its cause: a dimmed `✓` for exit 0, a dimmed
`×` otherwise. A run pane keeps the outcome glyph of its `RunRow`. A
dead pane with `close: keep` keeps today's display. The `inbox` dot
reads the row's `inbox`. The terminal client indents by depth.

**Prev and next.** `adjacentWindow` reads the displayed nesting; its
rule does not change.

**The ffi.** The model JSON gains the row fields through the schema;
no new function. `ko_client`'s prompt resolve reads the row's `inbox`.

## 4. The tools

| tool | what it uses |
|---|---|
| `list_agents(which?)` | `ko api /layout`, the registry in the own session |
| `read_report(agent, which?)` | the own session's `ko-pi.report` entries |
| `list_async_bash()` | `ko runs --json --all --parent $KO_PANE` |
| `message_agent(to, message, mode?)` | `POST /panes/{t}/messages`; `POST /panes` to restart an ended child |
| `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?, runtime?)` | pi's session directories, `pi --list-models`, `GET /runtimes/{name}`, `POST /panes` |
| `stop_agent(agent, force?)` | `POST /panes/{t}/messages` kind `stop`, then `POST /panes/{t}/stop` |
| `async_bash(command, name, stream?)` | `ko run-child $KO_PANE --name N -- bash -o pipefail -c CMD` |

Every run's parent is `$KO_PANE`. No agent has `KO_RUN_ID`. Every
call goes through `ko api`; the extension starts no `run-wait` and
opens no socket.

**`list_agents(which: all | peers | subagents = all)`.** The scope is
`scope(c)` of 2.8, the `@` completion's. Rows: `id` (the session),
`name`, `pane`, `window`, `status`, `activity`, `parent` (the parent's
session), `depth`, `cwd`, `runtime` (from the pane row, absent on the
host), `canMessage` (the row's `inbox`), `kind`
(`agent` or `subagent`), `relationship` (`parent`, `peer`, `relative`,
`own`). An own child adds `model`, `state` (`running` or `ended`),
`reported` and `report`: the first 1000 bytes of its last report, with
`read_report` named for the rest. An ended child of the caller is a
registry entry whose pane is gone, dead or of another instance; every
ended child lists. The list excludes the caller.

**`read_report(agent, which: last | all = last)`** returns the whole
text of an own child's last report, or every report of it in order,
from the caller's own session (5.1). It never reads the child's
session.

**`list_async_bash()`** lists the caller's own runs: all running and
the newest 20 ended, newest first, with `run`, `name`, `state`,
`outcome`, `startedAt`, `pane` and the screen route to read.

**`stop_agent(agent, force?)`** resolves one address in the scope by
the addressing rules of design.md; it refuses only the caller. It
sends `stop`, then `POST /panes/{t}/stop` with `wait_ms: 5000`.
`force` skips the request; without an open stream and without `force`
it refuses, as today. For an own child it first silences the ending
(5.7). Lines: `stopped NAME; it had reported`, `stopped NAME; it had
not reported on its last work`, `stopped NAME` for a peer or ancestor,
`NAME had already ended: exit 1`. A child that stops its parent orphans
itself a moment later (section 8).

**`spawn_agent`'s `runtime?: string`** passes as `POST /panes`'s
`runtime`. It is refused together with `resume_from` or `fork`: "a
saved session is a file of this filesystem". The result line gains
`in runtime NAME` when set.

**`stop_async_bash(run)`** takes one run id, name or unique prefix of
the caller's own runs and runs `ko run-stop ID`; the line names the
pane and, after the sweep, the run's screen. It silences the watch
first.

### Tool texts

- `list_agents`: "List the agents you can message: your subagents,
  your peers, each ancestor and its peers, in this session. which
  selects all (default), peers or subagents. An own subagent's row
  says whether it has reported on its last work and starts its last
  report; read_report gives the whole text. Bash jobs are in
  list_async_bash."
- `read_report`: "The whole last report of one of your subagents, or
  all of its reports in order, as they reached you."
- `list_async_bash`: "List your own async_bash jobs: all running and
  the newest 20 ended, newest first, with the run id that
  stop_async_bash takes and the pane whose screen holds the output."
- `stop_agent`: "Stop one agent in your scope: a subagent, a peer, an
  ancestor or a pi the user started. It asks the agent to shut down
  and then kills its pane. force kills an agent that is not receiving
  messages. The result is the only signal: a subagent you stop sends
  no ending notice. Stopping an ancestor ends you with it."
- `stop_async_bash`: "Stop one of your async_bash jobs by run id, name
  or unique id prefix; its pane is killed and lingers for a while with
  its last output."
- `async_bash`: "Its output is the pane's screen: read it with ko api
  /panes/PANE/screen?history=all meanwhile. With stream=true the new
  lines arrive in batches. list_async_bash lists it and
  stop_async_bash stops it."
- `spawn_agent` and `message_agent`: as today, with "pane" for "run",
  and `message_agent`'s modes "steer joins the current turn of any
  agent in your scope". `spawn_agent`'s `runtime`: "Start the agent
  in a configured runtime (a container or an ssh host) by name; not
  with resume_from or fork, which name a saved session of this
  filesystem."

The prompt guidelines and standing instructions rename the tools and
say `pane` for `run`. `PARENT_GUIDANCE` names `stop_agent` and
`read_report`.

## 5. The ko-pi lifecycle

### 5.1 What a harness keeps: its own session

Every harness appends custom entries to its own session with
`pi.appendEntry`, each with `owner`, its own session id; an entry whose
`owner` differs is ignored, so a `--fork` or `/clone` copy inherits no
children and no reports. The registry is read with
`ctx.sessionManager.getBranch()` at each use.

In the parent:

- `ko-pi.child`: `{ owner, name, session, model, fork, cwd, pane: {
  instance, pane } }`, at each spawn and restart; the last entry of a
  name on the branch is current.
- `ko-pi.work`: `{ owner, child, at }`, before it sends an own child
  work in any mode, and at a spawn or restart with a task.
- `ko-pi.report`: `{ owner, child, name, text, at }`, when a child's
  report arrives on the stream. The whole text, so it survives the
  child's pane. `read_report` reads it.

In the child:

- `ko-pi.work`: `{ owner, at }`, at `message_start` of a message with
  `details.work`, and when it delivers its task.
- `ko-pi.report`: `{ owner, text, at, sent }`, before it sends; a
  second entry with `sent: true` after the ack.

**Has a child reported?** For the parent: its last `ko-pi.report` for
the child is later than its last `ko-pi.work` for it; or it gave no
work. For the child: its last report mark is later than its last work
mark. A tie is not reported. Both are own facts; nothing reads the
other side.

### 5.2 Spawn

With the name claim and the restart lock of today:

1. Checks `name`, the task's encoded size (its JSON must fit the pane
   variable limit, 1,044,480 bytes), `model`, `cwd`, `resume_from`
   (the directory scan by file name, which reads headers of the user's
   saved sessions on the own filesystem) and `fork`.
2. Reads `/layout`. Depth is the length of the caller's `parent`
   chain; a child at depth 3 is refused.
3. Refuses a name that an own registry entry or an own live child
   holds; for `toplevel`, a name that a live agent of the session
   holds.
4. `POST /panes`:

       session: the caller's (toplevel only)
       name: N, cwd: C
       command: [ko, shell, --, ko-pi, --session-id ID | --session FILE, --name N, --model M, --fork FILE?]
       env: KO_AGENT_SESSION=ID, KO_AGENT_PARENT_SESSION=S, KO_AGENT_TRUSTED_CWD=C?
       parent: $KO_PANE, close: on_exit            (child only)
       vars: { "ko-pi.task": { text, from: { session, name, pane } } }   (non-empty task)

   With `runtime`, the body carries it; the `command` is unchanged,
   because the server wraps it in `ko runtime-exec` and the runtime's
   transport, and `ko enter` runs it inside (ko-runtimes.md, sections
   4 and 6). `cwd` for a spawn into a runtime from the host is a host
   path that the server maps (ko-runtimes.md, section 7);
   `KO_AGENT_TRUSTED_CWD` is in `env` and must be the mapped path, so
   ko-pi maps it itself first (5.11).
5. Appends `ko-pi.child` and, with a task, `ko-pi.work`.
6. Returns `spawned N (session ID, window W, pane P[, in runtime R])`
   with the rule text. No watch process: the ending comes on the
   stream.

### 5.3 Start and task delivery

At `session_start`:

1. The edge: `KO_AGENT_SESSION` equals the own session id and
   `KO_AGENT_PARENT_SESSION` is set. A nested pi has another id. The
   parent pane is the own row's `parent`.
2. Starts the stream reader, writes `pi.session` and `pi.name`.
3. Reads the own row. With `ko-pi.task`: an edge whose parent is
   `from.session` appends `ko-pi.work` and delivers the text as the
   first user message, with `awaiting-first-turn`; otherwise it
   delivers a `message` custom message with the sender header. Then it
   deletes the variable, the delivered marker. A read failure leaves
   it for the next attempt.
4. Starts the parent watch (5.9).

### 5.4 Report

At `agent_settled` with `ctx.isIdle()`, the child sends its report
when all hold, in order: it has an edge; no abort and no control ended
the turn; the turn did not stop on an error; it has not reported on
its last work; its own runs and children are readable; no own bash run
is live and no own child owes a report. The text is the last assistant
message's text blocks. The child appends `ko-pi.report { sent: false
}`, then sends `kind: notice` to its parent pane with `data: { report:
true }` and the text within the 4000-byte bound and the guidance; a
report that does not fit ends with:

    full report: read_report("worker")

The report entry holds the message id, minted once for each report,
so every send of that report, also after a `/reload`, carries the
same id and the parent gets it once. After the ack it appends `{
sent: true }`. A `delivered`, `queued` or `io` result leaves the mark
unsent, and the parent watch tick (5.9) resends with the same id until
an `ack`; a `refused` ends the retries. An empty last message sends
`subagent "worker" ended its turn with no message` with the guidance.

The parent, on a notice with `data.report`, appends `ko-pi.report`
with the whole received text before it acks; if the append throws, it
answers `refuse`, so the child retries.

**How ko-pi resends.** Every send mints one id for one intent and
keeps it for the retries of that intent: a `message_agent` call, the
`stop` request of `stop_agent`, each error and exit notice, each
report. A tool call resends on `delivered` or `io` up to three times,
1 s apart, and then reports the last state: `acked`, `queued` (the
agent is not receiving; it reads it when it reconnects) or `delivered`
(written, not confirmed). `ko prompt` mints its id in the CLI and
resends once on `io`. A sender never mints a second id for the same
intent, so no receiver reads a message twice.

### 5.5 Locating sessions

The parent needs no child file: a restart is `--session-id ID` in the
recorded cwd, and the reports are in its own session. `resume_from`
keeps the directory scan over the user's saved sessions on the own
filesystem.

### 5.6 The error notice and the exit notice

A turn that stops on a provider error sends the status notice once for
each failed attempt: `subagent stopped on an error: <error>` and
`message it to retry, or stop_agent to end it`. At `session_shutdown`
with reason `quit`, a child with an edge that owes a report sends one
last notice before it tears down: `subagent "N" is exiting before its
first turn ran`, or `subagent "N" is exiting without a report on its
last work: its last turn failed: <error>` when an error was not yet
notified. `/reload`, `/new`, `/resume` and `/fork` send nothing.

### 5.7 Endings

The server's `ended` message on the parent's stream carries the
child's pane and its end. The parent reads the lingering pane's
screen (`ko api '/panes/PANE/screen?history=all'`, the last 4000
bytes) and formats the notice from its own `reported` rule:

    subagent "worker" ended: exit 0; it had reported

    subagent "worker" ended: exit 1; it had not reported on its last work
    --- last 4000 bytes of its screen ---
    ...
    message it to continue it, or stop_agent to end it

    subagent "worker" ended: signal KILL; it had not reported on its last work
    ...

    subagent "worker" ended: its pane was removed; it had reported

The screen block appears only when the pane still lingers and the
child had not reported. An `ended` for a pane that is not a current
registry child, or that the parent silenced with `stop_agent`, sends
nothing. The `ended` message is queued, so a reload gap loses
nothing; a parent that restarts under its own session id in a new
pane has a new queue, and its `session_start` reads the rows of its
registry children: one whose pane is gone, dead or of another instance
gets the notice with `its pane is gone`, or the dead pane's cause,
once, recorded as `ko-pi.ended { owner, child, at }`.

### 5.8 Restart, resume, fork

A `message` to an ended own child restarts it: `POST /panes` with
`--session-id ID` in the recorded cwd, the message as `ko-pi.task`,
the parent's `ko-pi.work`, and a new `ko-pi.child` with the new pane.
The rules of "Restarting through a message" stay. `resume_from`
continues a saved session with `--session FILE`; a live session and an
ancestor are refused. Another parent's ended child becomes the caller's
child; the old parent's entry stays, and that parent sees the session
live under another pane and cannot restart it. `fork` is `--fork FILE
--session-id ID`.

### 5.9 The parent watch and the orphan rule

The server removes a child whose parent pane is gone or dead. The
child's watch, every `KO_PARENT_POLL_MS`, reads its own row's `parent`
pane: not dead and `pi.session` equal to the edge's parent means
alive; a failed read is no evidence; otherwise it calls `shutdown`.
The parent's row is visible on a runtime connection, because an
ancestor is in `scope(c)` (2.8). The same tick retries an unsent
report (5.4).

### 5.10 Shutdown

One teardown: the exit notice when owed, `POST /runs/{id}/stop` for
each own live bash run, close the stream reader, delete the own pane
variables with the conditional delete. No outcome. A `/reload` keeps
the stream and the variables.

### 5.11 Trust and depth

Decided: `KO_AGENT_TRUSTED_CWD` replaces `KO_AGENT_TRUSTED_ROOT`. The
trust holds for the one directory that the parent chose, not for every
worktree of a repository, and it compares paths of the child's own
filesystem, so it holds in a runtime. The spawner
sets it to the child's cwd when `ctx.isProjectTrusted()` holds and
that cwd is in the spawner's git repository, both checked on the
spawner's side, where both paths are its own. The child's
`project_trust` answers `yes` when the real path of `event.cwd` equals
the real path of the variable, both in the child's filesystem;
`undecided` otherwise. A pi the user starts in that pane in that
directory also gets `yes`; in another directory it asks. For a spawn
into a runtime from the host, `KO_AGENT_TRUSTED_CWD` must be the
mapped path: `GET /runtimes/{name}` reports the runtime's effective
`paths`, ko-pi applies the longest matching prefix to the trusted
cwd, and a cwd with no mapping gets no variable, so the child asks the
trust question as a pi without the variable does. The depth ceiling
stays at 2, over the rows' `parent` chain.

### 5.12 `async_bash` output and streaming

The command runs on the pane's pty with no wrapper, so its output is
the pane's content. `stream: true` opens `ko api --stream
/panes/PANE/output` at the pane's creation and reads `bytes` records;
the extension strips escape sequences (CSI, OSC, APC, DCS, ESC
sequences, and `\r` handling: a `\r` without `\n` starts the line
over, so a progress bar leaves its last state) and splits lines. A
`skip` adds `... N bytes omitted (the pane's screen has them)` to the
batch. The budget, batch caps and schedule stay; a `/reload` parks the
stream reader with its offset and reopens it at that offset, which is
the resume path. The ending notice carries the last 4000 bytes of the
screen while the pane lingers:

    async run "build" failed: exit 3
    pane: pane_7
    --- last 4000 bytes of its screen ---
    ...

The watch for a bash run's ending stays `ko run-wait ID --json`, a run
route; a pane watch is not needed for it.

## 6. What happens to every rule of design-subagents.md

| rule or limit | fate |
|---|---|
| five tools | **change**: seven (section 4) |
| P is `KO_RUN_ID`, else `$KO_PANE` | **change**: always `$KO_PANE` |
| `steer`, `interrupt-and-steer`, `stop_run`: descendants only | **change**: the mention scope, enforced by the server |
| report bound 4000 bytes, kept whole | keep; the whole text in the parent's session |
| discovery scope | keep; the server's `scope(c)` |
| names unique within the parent | keep; registry and live children |
| model, `cwd` rules | keep; recorded in the registry |
| `run-child`, `KO_AGENT_DIR`, `KO_RUN_ID`, `KO_RUN_OUTPUT` for agents | **drop** |
| `KO_AGENT_PARENT_SESSION` | keep; also the edge's parent |
| `KO_AGENT_TRUSTED_ROOT`, project trust | **change**: `KO_AGENT_TRUSTED_CWD` (5.11) |
| depth from the agent map | **change**: from the rows |
| task over 1 MB, never in argv | **change**: fits the variable limit; never in argv |
| the pane tied to its run | **drop** for agents |
| spawn result names the run | **change**: the pane |
| fork, resume, live check, ancestor check | keep |
| resume removes the other parent's `agent.json` | **change**: the entry stays, harmless |
| empty task to continue | keep |
| top-level agent: two layout edits, inbox wait | **change**: one `POST /panes`, task by variable |
| the agent directory | **drop** (5.1) |
| `delivered` | **change**: the deleted variable |
| the inbox socket, `pi.inbox`, the v1 envelope | **drop**: ko carries messages (2.6) |
| `ok` and `refused`, 2 s deadline, never resend | **change**: ack and refuse name the sender's id; a sender resends with the same id, and the server delivers each id once |
| sender header and relation | keep; the server supplies `relation` |
| "has reported" by file times | **change**: by own entry times |
| inbox bound before the task | keep: the stream before the task |
| standing instructions | keep, renamed |
| parent watch | keep (5.9) |
| report conditions 1 to 6 | keep |
| report written but not sent counts as sent | **change**: retried until acked (5.4) |
| error notice | keep, no `run:` line |
| ending from `run-wait` | **change**: the server's `ended` message, queued |
| the parent ends a child; no idle timer | keep |
| shutdown records an outcome | **drop**; exit notice (5.6) |
| sweep after 30 s, screen capture | **change**: `close: on_exit`; no capture for an agent |
| `stop_run` list, parallel stops | **change**: one target |
| orphan rule reads pi evidence | **change**: parent pane gone or dead |
| restart with `session-file` or inbox | **change**: `--session-id` and the task variable |
| `async_bash` output file, `tee` | **drop**: the screen and the output stream (5.12) |
| streaming by tailing the file | **change**: the output stream, escape sequences stripped |
| human at a shell: `ko prompt` | keep, through the stream |
| sidebar from the run meta | **change**: the row's `parent` |
| lingering window shows the outcome | **change**: the cause |
| limits on outcomes and the shared directory | **drop** |
| nesting depth 2, re-watched run sends no batches, `/reload` forgets the error, a watcher holds the report, a moved window, two resumers, one machine | keep |

## 7. Migration

No compatibility. Delete in the same change: the agent directory
code of ko-pi, the inbox server and client (`startInbox`,
`sendEnvelope`, `parseEnvelope`, the v1 envelope, `inboxPath`,
`privateDir`, the fallback inbox directory), `readEdge` from
`agent.json`, `endOwnRun`, the agent branch of the stop tool, the
agent run watches, the file tail of streaming, `KO_AGENT_DIR`,
`KO_RUN_OUTPUT`; in the server `runs::parent_ended`'s pane case,
`pi_evidence`, `msg.rs` (the server's inbox send), the output path of
runs; the `add_window` and `rename_window` calls of the top-level
spawn. The ko-pi state directory goes entirely. `share/pi/README.md`'s
inbox protocol goes. The fake ko gains `api -X POST /panes`, the pane stop, `api --stream`
for the message and output streams, and loses the agent `run-child`
cases.
The `discriminator.json` fixture goes.

Docs that the manager rewrites: design-subagents.md in full;
design.md ("Who is authoritative for what", "The pi extension,
ko-pi", "Identity", "The inbox", "Delivery", "Addressing",
"Spawning", "Window lifecycle", "Ending a child", "Steer, interrupt
and stop", "Notifying the parent", "Run outcomes", "The sidebar
tree", "Knobs", "Known limits"); protocol.md (sections 1, 3, 6, 7, 10,
11, and the new pane routes); design-ko.md ("Pane variables",
"Status, runs and the model"); design-app.md ("Sidebar"); AGENTS.md
("The harness is one pi extension", "The server", "Runs", "Native
agent status"); `share/pi/README.md`; `testdata/ko-prompts.txt`.

## 8. Risks

- **A child can stop its parent** (the scope includes ancestors). The
  orphan rule then removes the child. The tool text says so.
- **`/tree` back past a spawn** drops the child's registry entry; the
  child lives on with its row's `parent`, lists, can be messaged, but
  cannot be restarted by name.
- **A queued message to a pane that dies** is dropped without word to
  its sender; only the parent's `ended` counts them.
- **The task variable is visible** to clients for a few seconds.
- **No screen capture for an agent**; the ending notice reads the
  screen while the pane lingers.
- **Stripping escape sequences in the harness** is a second, simpler
  parser beside the terminal's; a sequence it does not know reaches
  the model as noise. A `skip` after a 1 MiB burst loses bytes that
  only the screen keeps.
- **A run's output is bounded** by the terminal's scrollback and the
  64 MiB capture cap; a build that prints more keeps only the end.
- **The output stream touches the verified ring reader**; its proofs
  must cover a consumer without snapshots.
- **The token is inherited by every process of the pane**, so a tool
  inside an agent's pane acts as the agent. This is the pane as the
  trust unit, as today's environment already was.
- **Clock.** Entry times are one clock, as today.
- **`ko api --stream` is one process per stream for its life.** It
  restarts on exit; between exits, messages queue.

## 9. Runtimes

ko-runtimes.md
designs the runtimes: the model, the configuration, the link, the
identity on a runtime connection, how a pane starts in one, the cwd
and env mapping, and the transports. This plan carries its changes in
2.1, 2.3, 2.6, 2.8, 4, 5.2, 5.9, 5.11 and 12. `ko ssh` and the remote
attach are not runtimes and do not change.

## 10. Deviations from the fixed decisions

- The server sends a child's ending on the parent's stream, queued;
  `GET /panes/{id}/wait` is dropped, because nothing else needs it.
- `read_report` is the reference for a capped report, and the parent
  keeps the whole text in its own session.
- A report that is not acked is resent with the same id until acked,
  so the inbox-down case no longer loses a report, and no parent reads
  it twice.

## 11. Open questions

None. Every question is decided: `ko api --stream` is the bridge; the
`ended` message is the only ending signal and the pane wait is
dropped; `read_report` is the name; the 16-message window and the 2 s
ack timer stay; the capture cap is 64 MiB; the output stream is in
this plan; trust is by the child's cwd (5.11); an output stream that
the ring overruns gets `skip` and loses those bytes, because a slow
harness must not hold the pane (2.4); the `ended` message carries no
count of dropped messages (2.6); message ids are the sender's and
idempotent, so resending replaces "never resend" (2.6).

## 12. Units and estimates

U1a and U1b are the server; U2 and U3 follow them and run in
parallel. U3 can start on the fake ko from this plan's shapes.

**The dependency on the runtimes plan.** ko-runtimes.md's U1 depends
on U1a here: the token and `POST /panes` come first, and the
identity rule of its section 5 needs both. Thus, U1a lands first and
carries no `runtime` field and no `Origin`; ko-runtimes.md's U1 adds
`runtime` to `CreatePane` and `Row`, the `runtime` body field of
`POST /panes`, `POST /runs` and `PUT /layout`, the `Origin` of a
connection and the narrowed reads (its change 10). U1b, U2 and U3
build on both: `from.runtime`, the `runtime` row of `list_agents`,
`spawn_agent`'s `runtime` and the trusted cwd mapping of 5.11 are in
U1b and U3 and need ko-runtimes.md's U1 before their verification.

- **U1a panes** (2.1 to 2.3 without `runtime`, 2.5, 2.7, 2.8 identity
  without `Origin`, 2.9): `parent`, `close`, `POST /panes`, stop, the
  sweep on rows, runs without an output file and with the larger
  capture, the token, `instance` in `/version`, schemas, e2e
  (`layout.rs`, `runs.rs`, `reap.rs`, `wait.rs`, `spawn_tree.rs`,
  `agents.rs`, a new `panes.rs`). About 2 agent-days.
- **U1b messages and output** (2.4, 2.6, 2.8 scope): the message
  stream, the queue with its states and cap, the acks, the scope
  rule, `relation`, `inbox` on the row, the `ended` message, `ko
  prompt` through the queue, `ko api --stream`, the removal of
  `msg.rs`; the output stream on the ring reader with its Verus
  proofs; e2e (`prompt.rs`, new `messages.rs` and `output.rs`,
  `hostile.rs` cases for both streams, the idempotent ids with their
  ring and the requeue on a stream close). About 4 agent-days, of
  which the output stream and its proofs are about 1.5 and the ids
  about 0.5.
- **U2 clients** (section 3): `ko_client` model and tests, `ko_tui`,
  the ffi model, Kido.app projection, the lingering display, the
  `inbox` field, visual tests. About 1 agent-day.
- **U3 ko-pi** (sections 4, 5, 7): the harness, the fake ko, the
  TypeScript suite, the prompt snapshot, the id minting, resend and
  receiver dedupe. About 4.5 agent-days.
- **Docs** (section 7): the managers, about 1 agent-day in total,
  before each unit's review.
