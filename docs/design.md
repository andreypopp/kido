# kido's design, as built

This document describes how kido works and the reasons for its design.
Its companion, [design-subagents.md](design-subagents.md), follows one
subagent from spawn to sweep. That document refers here for the mechanisms
that support the subagent. `AGENTS.md` describes constraints kido cannot
change: the tmux fork and the reports from Claude Code and pi. It also
describes problems that an apparently correct change can cause. This
document does not repeat those constraints or problems.

tmux owns the topology. Agents report information that only they know to
a directory of state files. pi's extension binds one unix socket per
session to receive text as a real user message. Each operation on another
agent is a `kido` subcommand that a pi tool calls:

- list;
- message;
- ask;
- spawn;
- interrupt;
- stop.

The e2e suite cannot host a TypeScript extension. It uses fake agent
binaries to test all these operations. The sidebar polls tmux and the
state directory. This poll also collects subagent windows.

## Who is authoritative for what

Four stores each hold information that no other store can hold:

**tmux, for topology.** tmux supplies these facts:

- the window and session that contain each pane;
- the pane's foreground command;
- whether anyone is attached;
- whether the pane's process has exited.

kido never caches these facts. A pane can move between windows and
sessions while its process runs. A window id has meaning only on the
server that issued it. Each command that needs an agent's session reads
a fresh pane list and finds the agent's pane there. A state record names
only a pane, not its window or session.

**State files, for what only an agent knows.** `State.dir` resolves the
server's state directory once at the command boundary. It uses this order:

- a convention-following `$TMUX` socket with `server.conf` beside it;
- `$KIDO_STATE_DIR`;
- `$XDG_STATE_HOME/kido`;
- `~/.local/state/kido`.

Each agent session has one JSON file, named by session id. A write uses a
temporary file and then a rename. A record contains the agent's pane,
pid, inbox socket, free-text activity, model, heartbeat timestamp and
place in the spawn tree. Only OSC 7501 root records supply status.
OSC 0/2 supplies the pane title.

A trusted `@kido_ssh` pane option takes precedence as `Ssh`. It contains
`Remote_agent` for a remote pi or Claude Code root, or `Remote_terminal`
otherwise. Otherwise, `State.pane_kind` classifies a pane as:

- `Pi_agent`: a pi root with `State`;
- `Some_agent`: a `claude-code` root or pi without `State`;
- `Terminal`: any other case.

Prompt scope accepts both agent cases. It uses the local pi inbox or
otherwise pastes. `list_runs` includes live `State`
identities, regardless of the current root app. `get-agent` context,
coordination tools and run history also use live `State`, not
`pane_kind`.

Native Claude Code has no identity, inbox or heartbeat. It never stalls.
Its blocked message is the caption. A visit acknowledges completion, and
clear restores a terminal row. The sidebar displays pane titles
verbatim. Only a native-only agent with an empty title uses its root app
name instead.

`State` does not identify a pane as an agent. Only root apps `pi` and
`claude-code` do this. A pi root with a live `State` record displays as a
local pi agent. Claude Code and bare pi display as native agents. Every
other app displays as a terminal. A local pi's identity and inbox remain
reachable by session when a nested program replaces or clears its root.

There is no locking beyond the session claim. `State.load_live` removes
dead-pid records. If two records name one pane, the latest timestamp wins.

This deletion affects the rest of the design. With a sidebar running,
`State.load_live` runs every 100ms. It removes a dead agent's record within
one tick of the agent's death. Code that needs information about a dead
agent cannot read its state record, because the record no longer exists.

**Pane options, for facts that must survive kido's own cleanup.**
`kido spawn_subagent` sets `@kido_run` (`set-option -p`) to the run id on
the pane that runs the command. The option exists in the tmux server,
where no race removes it. It names a current pane, not a pane id that a
later server can give to another process. Only a pane that kido creates
can have this option. This option alone makes a window eligible for
collection.

Killing the run's pane removes the option without a separate unmark step.
The pane-scoped option lets a sweep and the sidebar distinguish the run's
pane from a pane that the user later creates with a split. A window-scoped
option would also apply to the user's pane. It would not show that the
user's pane is not the run's pane.

**The runs directory, for facts that must outlive the process.**
`<state>/runs/<run-id>/` contains:

- the task text;
- a meta file, written at spawn and rewritten at resume, with pane, pid,
  cwd, model, tools, parent and depth;
- an outcome, after the run ends.

A run record is not a state record. A state record disappears when its
pid dies. A run record must survive the process. `State.read_all` reads
only `*.json` entries and skips directories. Thus, it ignores `runs/`,
the inbox socket directory and the wake marker. No code may depend on a
change to this behavior.

Two more files exist beside the records. The `inbox/` directory contains
one socket per pi session. Its mode is `0700`, like the state directory.
Anyone who can write there can impersonate an agent's socket. The `wake`
file is the staleness rebase marker described below.

## Identity

**An agent is its session, not its process.** The session id is the
identity. It names the state file and the parent that a child records.
`kido get-agent` answers about this id. The tree, the reaper and the ask
cycle rule match this id.

A pid is not an identity, because the OS reuses pids. kido's liveness
test (`kill(pid, 0)`) interprets `EPERM` as alive. Thus, another user's
process with a reused pid looks like a live parent. kido still records
and passes the parent pid, but uses it only for a quick first liveness
check. `ESRCH` definitely means "gone". For any other result, kido checks
whether a live process holds the parent session.

`State.session` stores this edge as one `parent : State.parent option`:
`{ session; pid }`, or `None` for a root agent. It does not use two
parallel fields that a caller could set independently.

This identity supports a restart. If a user quits pi and resumes the
same session (`pi --resume`), a new process uses the same session id.
When that process reports, each child with that parent id belongs to the
session again. A per-process identity would orphan children on restart.

The extensions read the session id; they never generate it. Both halves
use `ctx.sessionManager`, the one source that pi supplies. The status
half holds the id, and the agent half reads it through the seam. Both
halves independently read parent pid, parent session and depth from the
environment. Two readers of a constant cannot disagree.

**One holder per session id.** The first live process holds the session
id. Without this rule, a second process could overwrite the first
process's pane, pid and inbox, then delete its record on exit. This can
happen with two pi processes from one session file, or two calls to
`pi --session <file>`. `State.record` makes the claim in the write path,
without a lock, through three rules:

- If no record exists, the writer creates it with `Unix.link` from its
  own temporary file. This operation is atomic and fails if the name is
  taken. If two processes start together, exactly one claims the id.
  The other reads its record and stops claiming it.
- If the record names the writer's own pid, it belongs to the writer.
  Every report after the first continues unchanged.
- If the record names another live pid, kido refuses the write. If that
  pid is dead, kido overwrites the record. This lets a restart reclaim
  its session id. Two processes can both write to replace a dead holder.
  A takeover therefore rereads the written record and informs the
  losing process. No other write needs a second read.

`State.remove` uses the same rule. Thus, a second process cannot delete
the running session's record on exit. A refusal is `Error holder`, and
`kido agent-status` exits **6**. This separate code lets pi's extension
respond to the refusal. The second pi stops reporting for the rest of
the session. It tells its user once, naming the holder's pane and pid.

The second pi does not bind an inbox. Its pid-based socket path would
not collide with another path. However, only a state record publishes
the address, so nothing could reach that inbox.

`session_start` makes the claim in the session's first status report.
The extension awaits this report because it needs the answer. It does
not await later reports, because the first report settles the claim.
Thus, the extension cannot observe a later refusal from a lost takeover
or a reused pid on a stale record. Such a refusal removes that session's
row, not another session's row.

**The record must survive a reload.** The extension's `session_shutdown`
handler removes this session's state record for every reason except
literally `"reload"`. Unconditional removal with
`send("idle", { remove: true })` would leave a gap before
`session_start` reports a fresh record. During that gap, a liveness poll
can find "no record" for an unchanged session id. This independently
orphans a live parent's children.

This condition differs from `endOwnRun`, which controls the run outcome
and completion linger described below. Those operations answer "did the
run finish". They treat `"new"`, `"resume"` and `"fork"` as not run-ending,
because the run continues. Record removal instead asks whether the
*filename* (the session id) still refers to this session. For those
three reasons, the handler removes the old record.

Without removal, the old file has a live pid. `State.load_live` deletes
only records with dead pids, so it leaves that file indefinitely. The
old record and the fresh record under the new id then claim the same
pane.

**Children belong to the session that spawned them.** `/new`, `/resume`
and `/fork` move a pi process to a new session id. A child still names
the old id. The old session has no live holder, so the ordinary rule
makes its children orphans. No special case is necessary or wanted.

The session that spawned them and receives their reports has ended.
The process at that terminal now represents another session with its own
work. Transferring the parent edge would send a child's report to a
session that nobody reads.

**What the child asks, and of what.** `parentIsAlive()` calls the separate
command `kido get-agent <session>`. It reads `State.get_live`: the named
record, without a per-pane collapse. It prints
`{"id": SESSION, "alive": bool}`. An unknown session returns false. A
dead record returns false without removal.

One read decides the result, without debounce. The optional `--children`
flag scans run records and adds `"childrenAlive": bool` and
`"keepAlive": bool`. `keepAlive` comes from the session's run metadata,
or is false if no run exists. If the metadata exists but cannot be read
or decoded, the output omits `keepAlive`. For this inconclusive result,
the idle timer rearms instead of shutting down the child.

A display cannot answer this question. `kido tool list_runs` uses a
per-pane view (`State.by_pane`). This view suits a display, but not a
liveness check. A `pi --print` inside the parent's pane takes precedence
for that pane. The answer then omits the parent's record. If a command
calls pi in the child's pane, the answer also omits the child's row.

Either case reports a healthy parent as gone. Debounce would wait for a
second identical wrong answer. It would treat an incorrect answer as a
slow answer. A pane collision decides who owns the pane. `get-agent`
never asks that question, so a collision cannot affect its answer.

`get-agent` is a separate subcommand, not a `kido tool list_runs` flag.
It shares only a command prefix, not pane listing, session scope or
per-pane collapse. Giving a display a second meaning can make a
liveness poll read the pane owner instead. Without a pane list, the
timer also avoids a tmux round trip every five seconds per subagent,
for the subagent's lifetime.

Two consequences are intentional. First, `false` ends the session on
that poll. A dead parent, or a reused pid with no session holder,
therefore causes a prompt response. `keepAlive` protects against the
idle-exit timer, not against an orphan surviving its parent. However, a
child can poll between a quit and `pi --resume`. It then reads a
definite "false" and exits, even if the parent restarts.

Second, the answer has no scope restriction to the caller's tmux
session. The record file does not identify the pane's tmux session.
This matches the server-wide rule 2 in `lib/reap.ml`, which reads the
same fact. Session-scoped polling would disagree with the sweep. A
child moved to another tmux session would find no parent in that list
and exit, while the sweep still finds the parent's record.

Messaging remains session-scoped (`list_runs` is the display, and the
limit below still applies). Liveness needs no such scope. The only
inconclusive result is no answer from kido. This result supplies no
evidence and never causes an action.

`pollInFlight` addresses a separate problem. `setInterval` fires even
when the previous callback's asynchronous work is unfinished. Without
this guard, each tick during a slow read would start another process.
Overlapping reads cannot corrupt the result, because each read is
independently reliable. They only add load to an already slow machine.

## Every report is whole

Every report is complete. Nothing continues from the previous report.
On every call, `kido agent-status` builds a fresh `State.session` from
its arguments. An omitted flag supplies its zero value, not the
previous report's value. To keep a field, the caller sends it on every
call: inbox, activity, model, parent pid, parent session or depth.

The agent knows these values from its own state and environment.
Reporting fresh values is more reliable than following the parent
chain, which fails when an intermediate record disappears. `--inbox ""`
means the agent's socket is gone. Thus, `share/pi/kido-status.ts` sends
`--model` and `--inbox` on every report, with empty values when necessary.

`kido tool set_status -- <activity>` updates only the activity field.
This command implements the `set_status` tool. It finds the calling
session by its pane and writes no other field. It does not rename
`agent-status`, which reports identity and heartbeat. Rewriting the
previous record with only activity replaced preserves its identity and
timestamp.

Activity is the only field a model writes directly into a state record.
Both commands sanitize it once, at input. They replace control
characters with spaces and truncate at 256 bytes on a rune boundary.
The sidebar allows one terminal line per row, and
`kido tool list_runs` prints a tab-separated table. Rejecting newlines
where arguments become a record requires less work than protecting
both displays separately.

A model can ignore a schema. Any same-uid process can run either
command. Thus, only kido's cap is authoritative. The extension sends
text unchanged.

The extension coalesces reports by activity, model, inbox path and
removal. A newly bound inbox changes the key. Its first report cannot
match a duplicate from before the bind. kido does not combine heartbeat
reports.
Status and title are not identity-report fields.

## The inbox

A pi session that accepts prompts as real user messages listens on a
unix stream socket and reports its path. `kido get-inbox <pid>` prints
`{"path": "<state>/inbox/<pid>.sock"}` as an absolute path. It creates
nothing and refuses paths beyond the kernel's `sun_path` limit. Just
before binding, the extension creates the state directory, then the
uid-private inbox directory, with mode 0700.

kido selects the path. The extension need not duplicate the
state-directory precedence or estimate the length limit. After a
refusal, the session runs without an inbox, instead of listening where
kido cannot connect. The name uses the pi process's pid, which is unique
among live processes. A remaining file at that path cannot belong to a
running listener. kido's convention therefore makes unlinking before
binding safe.

**A `/reload` does not take the inbox down.** A reload keeps the process,
pid and session id. The path uses the pid, so the listening server
survives the module that bound it. `globalThis.__kidoPiExtensionInbox`
holds the server, with the same reload-survival mechanism as the seam.
The server's connection listener uses that slot indirectly, not a
closure over one module's handler.

For reason `"reload"`, `session_shutdown` clears the handler but leaves
the socket bound. The reloaded module's `session_start` installs its
handler without rebinding. Every other reason closes the server and
unlinks the socket. The next `session_start` binds a new server.

Connections accepted between the old module's shutdown and the new
handler's installation wait. The server does not discard or refuse
them. The new handler receives these waiting connections. A notice has
no paste fallback and kido sends it exactly once. Thus, the reload gap
must not discard it.

The wire protocol uses one message per connection, with these steps:

1. Connect.
2. Write the payload as UTF-8 without framing.
3. Half-close the write side, so EOF ends the message.
4. Read the reply.
5. Close.

The reply is `ok` or `refused`. One two-second deadline covers the whole
exchange, including connection. An unresponsive listener with a full
accept backlog blocks in `connect()`, before a connection exists to
receive a deadline. The agent answers immediately after reading the
message. kido treats any slower response as unresponsive.

`ok` means the agent has the message and sees it at its next turn
boundary. This is the only acknowledgement level. `message_agent`
promises delivery, not action. The next section describes which kinds
queue and which join current work. The following section describes how
an idle session starts a turn, because it has no current turn to wait
behind.

An agent's message identifies its sender. A `message` from another agent
reaches the model as a custom message, like a notice. It uses
`pi.sendMessage` with a `customType`. One header line identifies the
sender and its relationship to this session:
`message from @<name> (your parent,
who spawned you):`, `(your subagent):`, or `(another agent in this
session, not the user):`.

kido reads the relationship from the agent list, not the envelope. A
parent is the session that spawned this run. A child has a parent edge
that points to this session. Any other agent is a peer. Only the peer
header says it is not the user. A child's only user is its parent, so a
parent's instruction has that authority.

The renderer removes the header and displays `message from @<name>:`
with the full text. Unlike a notice, a message never collapses, because
its purpose is to be read.

A message without an agent sender is the user's own text, without a
header. This means a human runs `kido message_agent` from a pane with
no state record. `from` contains a pane but no session, and no listed
agent owns that pane. The steer and control paths use these two facts to
identify a human.

Both sender types use the same delivery: `followUp` while streaming,
or a wake while idle. Only the label depends on the sender.

An `ask` uses the same custom-message handling and relationship header:
`ask from @<name> (your parent, who spawned you):`, and the other forms.
Both kinds need the same sender and relationship information. The
model's text includes:

- the question;
- the ask's id;
- a line saying the asker cannot see this session's context;
- the exact `message_agent` call for the reply.

The renderer displays only `ask from @<name>:` and the question. The id
and reply instructions are for the model, not the human reading the
transcript.

### Steer and followUp

kido uses `followUp` to queue work and `steer` to interleave work.
An idle recipient uses the wake path below.

The rule, one line:

> Steer what is safe to interleave. Queue what must be answered in order.

This rule determines the incoming work and report kinds:

- **`ask` queues.** An ask requires a correlated reply. Two asks must
  never remain in flight inside one turn. kido uses `followUp` to keep
  correlated questions in order. The cost is the wait under "Known limits".
- **`message` queues.** It has no correlation to confuse and no authority
  over the receiver's work. It waits for the current turn, like user text.
- **`steer` steers.** The agent that assigned the work sends a correction.
  It needs no correlation and has no value after that work ends.
- **`notice` steers.** The parent needs this information to assign the
  next work. Thus, kido interleaves it instead of queueing it.
- **`stream` is held, then steers.** For each send, the wrapper resolves
  the parent's live record and inbox (`Async_stream.send`). It does not
  retain a stale address after a socket rebind. A running command's
  output batch is the only kind not delivered on arrival. kido buffers
  it until model delivery requires no turn. `design-subagents.md`,
  "Streaming a run's output", describes the schedule. It also explains
  why a flush at the wrong turn boundary causes a loop, not only an expense.

Escape and the dequeue key restore only queued user text to the editor.
Custom messages remain in their steering and follow-up queues, in order.
They reach the next turn boundary exactly once. The agent extension
wraps `AgentSession.clearQueue` to preserve them while pi clears editor
queues. `globalThis` holds the original method. Thus, `/reload` replaces
the wrapper instead of adding another wrapper.

### Waking an idle session

For an idle recipient, kido queues the arrival with
`sendMessage(..., { deliverAs: "nextTurn" })`, then sends a short
user-role **trigger** with `sendUserMessage`. While the session is
streaming, kido sends no trigger and uses the kind's steer or follow-up mode.

The trigger is one line. Only the incoming kind changes:
`(kido: a
message arrived; it follows)` and its three related forms.
kido installs a wrapper that removes its triggers from outgoing
messages. A remaining trigger says only what follows. kido sets
`expandPromptTemplates` to false.

**One trigger at a time.** If a trigger is pending, kido queues an
arrival without another trigger. It accepts two asks in one turn
instead of serializing them. Each ask has its own id and receives a
reply with `replyTo`, so simultaneous arrival causes no misattribution.
The `turn_start` handler clears the pending-trigger flag.
`sendUserMessage` failure also clears it, so a failed wake cannot delay
later arrivals. The trigger uses the kind's delivery mode.

This handling does not change the idle-exit clock. Arrival of the
envelope resets the clock, not delivery to the model. Thus, a session
cannot exit while an arrival waits for its turn.

### v0 and v1

A v0 payload is raw prompt text, as the inbox has always accepted.
A v1 payload is one JSON object with:

- a version;
- a kind (`message`, `ask`, `reply`, `notice`, `stream`, `steer`,
  `interrupt`, `stop`);
- an id;
- a sender;
- an optional `replyTo`;
- the text.

Only a `stream` envelope also names the output's run and the file that
contains all its output.

A payload is v1 only if it parses as a JSON object with both `v` and
`kind`. All other payloads are v0 text, including JSON objects missing
either field. A user prompt can itself be a JSON object. The parser
must not treat that prompt as a control message. A fixture table tests
the extension's parser with envelope and raw-text payloads.

The sender checks only the target's `inbox` field to select the version.
Every pi session with a bound inbox uses v1. A non-empty `inbox`
therefore means v1, without another advertisement. A plain message to a
target without an inbox uses v0 text. For a target without an inbox, kido
refuses every other kind.

A paste or v0 payload cannot carry a kind or id. Converting an ask to a
plain prompt would remove the information that makes it an ask.

`kido prompt` always uses v0. It is independent of agent type and must
continue to support Claude Code panes. It targets only top-level agents.
A pane is never a candidate if its window contains a run pane
(`@kido_run`). This uses the same reader as the sweep and
`switch-window`, and excludes a child between spawn and its first report.

If the caller's window has no candidate, the search widens to the
session. Without this exclusion, one agent and one live child in the
session would give two candidates and exit 5. A human could reasonably
have meant the agent.

The protocol has no version gates, including for interrupt and stop.
kido runs on one machine, and the binary and extension upgrade together.
Thus, a version gate would serve no purpose. Stop escalation kills the
pane whether or not the target understands the request.

The sender field is advisory. The state and inbox directory modes
enforce uid-scoped trust. State records are `0644` files in a `0700`
directory. Any same-uid process can already write a record claiming any
agent identity. A peer-credential check would add no protection.

For the same reason, sending commands have no `--from`. The sender is
the identity in the calling process's record, found by its pane. A
caller without a record sends only its pane.

## Delivery, and when a paste is allowed

`Msg.Unavailable` means nothing was sent. The path is empty or unusable,
the socket file is missing, or a stale socket has no listener. After
connection, kido reports each failure as `Msg.Failed`. The message can
already have arrived, so a retry could deliver it twice.

kido permits a bracketed paste and separate Enter when an identity names
no inbox, or `kido prompt` selects a native-only agent pane. A local pi
with a failed bind remains reachable through prompt and plain
`message_agent`. Claude Code has no identity and is reachable only
through prompt. An advertised but unavailable inbox is an error. It
means the target does not accept messages.

For a subagent run, the error gives these instructions:

1. Wait for the run to exit.
2. Resume it with `spawn_subagent(resume: RUN)`.
3. Resend the message.

Shutdown closes the inbox before removing the state record or exiting
the process. A live pid does not prove that the inbox accepts messages.

A refusal (`Msg.Refused`) is not a delivery failure. The target reads
the question and intentionally declines it. A paste would bypass this
refusal. Non-message kinds never use a paste. Model-authored text must
not run as a command line in the target's pane. A dead parent has nobody
to receive a report.

Two more refusals occur before sending. kido refuses a message to the
sender's own pane. Although `list_runs` excludes the caller, an explicit
self-message would return its own message as a fresh user turn.

kido also refuses invalid UTF-8, because the delivery paths handle it
differently. JSON marshalling substitutes U+FFFD. A paste writes the
original bytes. Thus, the same message would arrive differently
according to whether the target has an inbox.

## Addressing

The tmux session limits addressing for `message_agent`, `ask_agent`,
`steer_subagent` and `interrupt_subagent`. `list_runs` has a narrower
scope. It shows same-parent peers, the caller's parent and its own runs.
For a root, peers are other top-level agents. For a subagent, peers are
live siblings. The list excludes the caller, other agents' children
and bash jobs.

Own runs include all running runs and the newest 20 ended runs by start
time, newest first. This display scope does not restrict addressing.
Across both kinds, `stop_run` resolves run ids before running run names.
Id prefixes must be unique and contain at least eight characters. It
then applies descendant scope through agent records or the parent
session in bash meta.

kido reports a target in another session as such, not as "not found".
It reports an ambiguity there as an ambiguity, not a single match with
an empty id.

Within scope, kido applies these rules in order:

1. An exact case-insensitive name.
2. An exact session id.
3. A unique id prefix.

Each rule reports its own ambiguity. It does not try another rule to
guess a match. A session matches the reported pi session name that
`kido tool list_runs` displays. Unnamed pi sessions match only by id.
Native-only panes have no addressable session. A name from `list_runs`
can always resolve to its session.

kido refuses instead of guessing. It never infers `replyTo`, even with
exactly one pending ask from the target. A wrong guess would resolve the
wrong pending ask and assign one question's answer to another question.
`ask_agent` resolves the target once in the extension. It passes that
id to `kido tool ask_agent`, so kido cannot resolve a different target.

In pi's prompt editor, `@` and a prefix complete live agent rows from
`list_runs`: same-parent peers, the caller's parent and its own
subagents. Completion excludes bash and ended runs. Each row shows
status, activity and a subagent's parent. Internal sender, ancestry and
reply checks use the live graph from `get-agent --context`. Thus, the
checks do not identify an unlisted sender as a human, and addressing
remains session-wide.

kido wraps the completion provider to place agent matches first. It
delegates tokens with no agent match. A token matches the start of a
name or any word in it, with whole-name matches first. A whitespace name
cannot form one `@` token. For that name, completion inserts the shortest
unique id prefix, which addressing resolves like a name.

A keystroke uses the last list without waiting for `kido tool list_runs`.
If the list is older than `KIDO_AGENT_LIST_TTL_MS` (1s), a background
refresh starts. kido fetches nothing until the first `@`.

## User asks

Top-level pi agents use `ask_user` to record questions that need the
user's decision. They use `remove_ask` to remove answered questions or
questions that no longer apply. Kido owns `<state>/asks/<id>.json`.
Each ask contains its id, session, pi session file path, cwd, display
name, text and creation time. An atomic link claims a fresh id.

`replaces` rewords an existing ask without changing its id. It uses an
atomic temporary-file rename and refreshes the session, cwd, name and
time. Asks persist after their session ends. Ended means no live state
record holds the session. kido derives this from the full registry and
never stores it. `get-asks` returns asks, optionally filtered by session.

Pi shows the session's open asks in full above the editor. It refreshes
them on startup, reload and tool actions. An `asks` inbox envelope
invalidates a live session's widget after external changes. External
removals also queue a kido notice with the removed ask's id and first
text line. This notice waits for the model's next turn without waking
or interrupting it.

Open asks give a live agent the existing waiting indicator. This
indicator takes precedence over Done and ordinary state, and remains
after a visit. `a` toggles the all-asks list, including dimmed ended
sessions. `d` removes the selected ask. Escape returns to windows.

Enter rereads the full live registry. For a live session, it selects the
session's pane. For an ended session, it opens a window in the ask's cwd
with `pi --session <session-file>`. This uses the spawn's pi launch path,
without a parent edge or run record. A missing cwd or session file is an
error. The resumed session's widget reads asks from the same store.

## Ask and reply

An ask blocks the calling tool until an answer arrives at the asker's
inbox. `kido tool ask_agent` sends and returns without waiting. A
short-lived CLI process has no reply inbox; only the long-lived
extension has one. The extension assigns the envelope id and registers
a waiter before sending through `kido tool ask_agent`. The answer
arrives later in a separate `reply` envelope with that id.

The wire `ok` means received, not answered. A model turn takes minutes.
The two-second inbox timeout must not include that turn.

**A caller with no inbox is refused, rather than delivered.** Replies
can arrive only through the asker's inbox. Without one, nothing can
answer the caller's question. Delivering it would cause a one-way
interrupt, not an answerable question. `kido tool ask_agent` refuses
before target resolution, as `kido tool notify_parent` refuses a root
session. The refusal names `message_agent`, the one-way send suitable
for a shell.

kido also refuses a target that cannot reply. A reply requires a
`message_agent` call. A child's tools allowlist can exclude that tool,
leaving no way to answer. The ask would only block. `kido tool list_runs --json`
reports `canReply` beside `canMessage`. A child's result arrives as a
notice, as the spawn and ask descriptions state.

The sender check is the check that `send` applies to recipients of
non-message envelopes. A reply is such an envelope. The caller's pane
must have a live state record, so `kido tool message_agent -- <asker>`
can resolve it. That record must name an inbox, so the `reply` has an
address. A reply never uses a paste fallback.

An unavailable inbox causes delivery failure. A weaker check is not
sufficient: an agent without an inbox accepts only a paste, and a paste
is not a reply. The extension's `ask_agent` binds an inbox before it can
register a waiter.

The expected latency is one full turn, not a round-trip. kido uses
`followUp` for questions and waits for an explicit `message_agent`
reply. The default wait is five minutes. Thus, timeout does not mean
that the question failed. A late reply reaches the model as an ordinary
message instead of being discarded. The ask id remains a valid
correlation for that reply.

### The cycle edge

A subagent cannot ask an ancestor, so the parent remains free to
coordinate work. The extension follows the parent field from
`kido get-agent --context` to enforce this rule. Parent-to-child and
peer-to-peer asks remain possible. Thus, two peers can block on each
other.

Each extension keeps the prevention rule in memory. If this session
already has a waiting ask to an inbound ask's sender, it answers
`refused` on the wire. It does not deliver that ask to the model.
An on-disk edge set would survive `kill -9` on the asker. It would then
permanently block future reverse asks.

The edge set is the waiting-ask map itself, not a separate count.
An edge exists exactly while an ask to that target waits. Thus, no
second count can disagree. An unmatched reply-shaped envelope does not
remove a waiter. A failed reply therefore leaves the edge present.

The extension registers the waiter synchronously before it calls the
`await` that starts sending. An inbound ask already sees the edge while the
outbound subprocess runs. Settling a waiter is idempotent. A late
"could not deliver" after a reply causes no action.

### When the inbox goes away

Without an answer destination, a waiter would wait for its whole
timeout on an unserved socket. Its cycle edge would remain closed for
the same duration. Thus, shutdown releases every waiting ask, including
on reload. On reload, the socket remains bound and the reloaded module
receives the listener. The old module abandons its waiters. The status
extension informs the agent extension about bind failure and shutdown.

Shutdown ordering is necessary. `session_shutdown` first stops this
module from serving the inbox. It clears the handler on reload, or
closes the server for any other reason. Before its first `await`, it
runs the agent extension's synchronous prefix: stop the parent poll and
release every waiter. Thus, the inbox never appears open while the
session is shutting down.

`ask_agent` can therefore use one synchronous "is the inbox open" check
to detect shutdown. No `await` occurs between that check and waiter
registration. The check reads the module's view, not the retained
server. It conservatively refuses during a reload gap, even while the
socket listens. Otherwise, the waiter would belong to a module that no
longer exists.

### When the target goes away

Only the asked process can answer. If the target stops running, the
ask ends, regardless of how the process stops. Refusal before sending
covers only a target that has already ended. A target can be alive then
and dead a second later. Without another check, the asker would wait
for the whole `timeoutMs`, spending minutes on an impossible answer.

Ordinary endings cause this problem. A child can finish and exit
without replying, or `stop_run` can kill it.

A waiting ask therefore polls `kido get-agent <session>`. This uses the
same one-bit question and rules as the status extension's
parent-liveness poll. A definite `false` settles the waiter. Failure to
get an answer from kido supplies no evidence and never ends the wait.
`KIDO_ASK_POLL_MS` sets the interval, with a five-second default.

The poll prevents overlapping reads. `setInterval` can fire before the
last callback finishes. The timer is unref'd, so the wait never keeps
pi's event loop open.

Both alternatives are worse. Using `notify_parent` to settle a pending
ask would infer a `replyTo` that the child never supplied. A notice is
not an answer. A child finishing other work could then send its summary
as the answer to an unrelated question.

Wire refusal of unanswered asks during shutdown would require a
`refused` envelope kind that does not exist. `Msg.kind` has message,
ask, reply, notice, stream, steer, interrupt and stop. This adds nothing
the poll cannot detect. A killed or crashed child cannot refuse on the
wire, just as it cannot call `notify_parent`. One mechanism reads the
fact common to every case: the process is gone. No second mechanism
needs synchronization.

### When the human interrupts

The ask tool listens to its `AbortSignal`. The signal settles the
waiter like any other outcome. It removes the pending entry and cycle
edge. The tool reports the ask id as it does for a timeout. A later
reply still reaches the model as a message.

## Spawning

`kido tool spawn_subagent` creates a detached window in the caller's tmux
session. It runs `pi` by default. The environment supplies the child's
place in the tree and its task. Three `new-window` flags are necessary:

- `-d` keeps focus on the caller's window during its turn.
- `-c` starts the child in the parent's directory, not the session's
  default directory.
- `-e` supplies each variable. `new-window` uses the server and session
  environment, not the caller's environment. No other route supplies
  those variables.

The task is never a command-line argument. A model writes text of any
form. A tmux command line nests three parsers, and no escape survives
all three. kido stores the task in the run directory and names the file
in `KIDO_AGENT_TASK_FILE`. On `session_start`, the child reads this file
and delivers its first user message, as it delivers an inbox prompt.

At the tool boundary, the task remains text. `spawn_subagent` sends it
on stdin to `kido tool spawn_subagent`. kido decides to store it in a
file. Another backend could instead write it inside a sandbox.

The model also writes the window name, which does enter the command
line. `Launch.tmux_safe` refuses characters that cannot survive the
nested tmux, sh and tmux parsers. kido also refuses names over 64 bytes,
instead of silently changing them.

### A parentless spawn, and a parent that must exist

A fresh spawn requires one of these choices:

- a live parent, with `--parent-pid` and `--parent-session`;
- no parent, explicitly specified with `--no-parent`.

A parent with no holder is an error, which kido refuses as described
below. `--no-parent` lets a human start a standalone agent from a shell.
No parent owns it, no mechanism collects it, and it reports to nobody.
Existing mechanisms already support a child without a parent:

- A record with `parent` equal to `None` is exempt from sweep rule 2.
- Without `KIDO_AGENT_PARENT_SESSION`, the child fails the subagent
  test, arms no idle timer and cannot call `notify_parent`.
- For a caller without a record, `--resume` defaults to no parent.

`--no-parent` also works with `--resume`. It removes the caller's edge
instead of using that edge by default.

**Why a flag and not an empty `--parent-session`.** These errors differ.
A script with an empty parent session intended to name a parent but lost
that value. Silently creating a window that cannot be collected would
misinterpret that intent. An explicit flag cannot result from that
accident. The tool never passes this flag, because a live pi session
names itself as parent. Only humans use this entry point, and only they
can make this error.

**And the session named must be alive.** `--no-parent` explicitly means
no parent. Thus, `--parent-session` with no holder is an error, not
another way to specify no parent. kido refuses it before creating the
window. The check uses the same registry reading as `--resume`,
described below. It reads the named record and tests its pid, not a
pane-keyed view. As with the sweep, a pane collision can remove exactly
the parent's record from that view.

### The depth ceiling is derived

Nesting has a limit of two levels below the root.
`kido tool spawn_subagent` accepts no `--depth` flag. kido finds the
caller's last-reported record by `$TMUX_PANE`. It sets the child's depth
to the caller's depth plus one. A caller without a record has depth 0:
a human at the CLI or an agent that has not yet reported.

This uses the same trust decision as `State.load_live` for other
same-uid records. A missing record gives the caller the root's limit.
The extension can refuse early from its `KIDO_AGENT_DEPTH` environment
value. This avoids a subprocess in the common case. However, kido's own
limit is authoritative, because a caller could understate its depth.

### The run id is the child's session id

`kido tool spawn_subagent` creates the run id. If the command is
literally `pi`, it inserts `--session-id <run-id>` after the command.
kido prints `pi --session <run-id>` for restart and `pi --fork <run-id>`
for a fork, each preceded by `cd <cwd> &&`. Only one id exists, so no
mapping between ids is necessary. kido always sets `KIDO_AGENT_RUN_ID`.
A non-pi child, including every e2e fake, has no session from which to
read the id, but needs it to report an outcome.

This id also distinguishes the run's child from a process that only
inherits the child's environment. Every process that an agent starts
inherits `KIDO_AGENT_*`. Examples include a human's `pi` in that pane
and a tool calling `pi --print`. Thus, any descendant can claim the
parent edge. Trusting that claim would let an extension act on another
process's run.

A nested pi would resolve itself by pane and find the real agent's
record. On exit, it would schedule `kido close-run` for the real agent's
window. Instead, the extension checks its own identity. It is a
subagent only when `KIDO_AGENT_PARENT_SESSION` is set *and* its pi
session id equals `KIDO_AGENT_RUN_ID`. The real child meets both
conditions through `--session-id` and `--session`. A nested pi creates
its own id and cannot meet them.

An unknown session id means not a subagent, which causes no action.
The id is null until `session_start` resolves it. It remains unknown
outside tmux or without kido on PATH. A real child has its id before
any hook, turn or tool call. However, a wrapper command that execs `pi`
gets its own session, not the run's session. kido treats it as the root
session that it is.

### Failure leaves a record

kido creates the run directory and task file before the window. The
child can read its task as soon as tmux starts it. An existing directory
also lets a failed spawn record its outcome. If `new-window` fails,
kido writes meta and marks the run `failed` with the error. Thus,
`kido runs` does not show an unexplained run without a window.

If window creation succeeds but marking fails, kido kills the window
and records `failed` in the same way. No sweep can collect an unmarked
window. A window that nothing can find again is worse than no window.

## Window lifecycle

A spawned window enables `remain-on-exit` on the run's pane through
`set-option -p`, not a window option. The pane survives its command's
exit. This gives the user time to read during linger. It also gives the
sweep a pane to find if linger never runs.

A second tmux call sets the option after `new-window`. A fast command
can exit before that call. Thus, an immediately failing child loses its
window and last screen. The run record survives, and its pid still
makes it read as `died`. Every fix costs more than this gap.

**The linger helper.** Before exiting, a subagent starts a detached
`sh -c 'sleep N && exec kido close-run @id'`. This helper survives the
pi process, whose event loop ends before the sleep expires. The helper
receives the window but collects only the run's pane. The window belongs
to its occupants; kido creates only one pane there.

If the run occupies the whole window, the helper closes the window.
If the user has a split pane, that pane remains. Killing the run's pane
returns the window to ordinary use. `@kido_run` exists only on that pane
and disappears with it, without a separate unmark step.

The helper refuses any client's current window. The user can be reading
the child's last screen there. This protects both pane and window
collection: killing a pane removes its screen and resizes the remaining
panes. The helper also refuses a session's only window, because closing
it destroys the session and detaches every client. It refuses a run
whose pane remains alive.

The helper checks once without retry. A later sweep collects what it
leaves. `Reap.decide` applies the same checks in this order:

1. Focus.
2. Whether the run is still running.
3. Which unit to release.
4. The last-window refusal.

It returns either a `Reap.close` for the caller to release, or a refusal
to print. `kido close-run` parses flags and prints around that one call.

**The sweep.** `Reap.sweep` runs at every sidebar poll tick. It collects
subagent windows in a live session. `kido reap` calls the same function
manually, for a test or operator. The sweep uses the sidebar snapshot
from `Sidebar.take`, through `Reap.collect`. It does not run from
`State.load_live`.

`kido prompt` and the popup picker also call `load_live`. Reading the
state directory must not close a window as a side effect. Several
sidebars, one per client, can sweep simultaneously. A sidebar can ask
tmux to close a window another sidebar already closed. This produces an
error that nobody reads.

A sweep decides from tmux, not kido's state. A dead subagent's record
cannot identify the window to close. With a sidebar running, the record
disappears within one tick of death, before a sweep sees it. A pane id
is not an identity. Each new tmux server restarts pane ids at `%0`,
while global state files survive the server.

A stale record can therefore name another process's current pane.
Without a mark check, a sweep could close a plain shell window that is
not a subagent.

Two rules apply only to windows that contain a run pane:

1. The run's pane has been dead for the linger grace period. This rule
   reads no state record.
2. A live subagent's parent is gone. The sweep kills the run's pane to
   cancel the subagent.

Rule 2 forces a stop instead of requesting graceful shutdown like the
child's poll. It is the only available action outside pi. This rule
needs records, because tmux does not know parentage. The run-pane check
prevents a stale, reused pane id from closing an unrelated window.
A record without a parent session represents a root agent that the
sweep must not cancel.

Rule 2 also covers `async_bash`. Its parent edge is in run meta, not an
agent record. `Bash` and `Stream` runs without a live parent-session
holder receive a `failed` outcome and the detail "its parent ended".
Neither rule acts on a client's current window or closes a session's
last window. Waiting loses nothing, because the sweep runs next tick.

**A split window is the user's window.** The collection unit is the
run's pane, not its original window. Waiting until every pane dies would
leave the dead run beside the user's shell until the user leaves.
Thus, the sweep returns a pane or window (`Reap.close`). The caller
kills the run's pane with `kill-pane`. If that pane occupies the whole
window, the caller uses `kill-window`.

These operations differ. Killing a window's last pane also closes the
window. However, only the window case can destroy a session. Only that
case must obey the last-window refusal.

The pane-scoped `@kido_run` returns the window to ordinary use without a
separate unmark step. Killing the run's pane removes the option, which
exists nowhere else. Other readers use that option:

- The tree nests the window under its parent.
- Top-level window cycling skips the window.
- The sidebar draws the run's label.
- A later sweep considers the window again.

After pane removal, the sidebar draws an ordinary window with the user's
remaining panes. Stop escalation and bash dead-wrapper cleanup do the
same: they kill the target pane and leave an ordinary window. A user's
split pane has no `@kido_run`. No window-scoped fallback supplies one.
It also has no `remain-on-exit`, so its normal exit closes the pane and,
when appropriate, the window.

Rule 2 acts on one read. This is safe because "gone" means no live
process holds the parent session. It concerns the full registry, not a
pane. The sweep receives every live record from `State.load_live`, or
`State.read_all` for `kido reap`.

`State.by_pane` cannot answer this question. It keeps one record per
pane. A `pi --print` inside an agent's pane inherits the pane and takes
precedence while reporting. The view then omits the real parent's
record. No check inside the sweep can recover a missing record.
Debounce would treat an incorrect answer as a slow answer.

With the full registry, a collision does not matter. It decides pane
ownership, which the reaper never asks about. The sidebar still uses
the per-pane view for rows, because a pane has one label. It derives
both views from one directory read: `State.by_pane` over the
`load_live` list. Thus, the sweep adds no I/O to a 100ms tick.

No other guard applies: no grace period, debounce or check of the
child's recorded parent pid. A reused pid could make a dead parent look
alive. The rule consults no pid. This also lets a one-shot `kido reap`
apply the rule in its single sweep.

Without grace, a child already shutting down can lose its window during
exit. It can receive `died` before recording its own outcome.
`Subrun.record_outcome` uses an atomic link to preserve the first written
outcome. Only a child that has not yet written an outcome risks this.

**The screen capture.** Only the sweep sees a marked window's dead pane
before closing permanently destroys its screen. This is the only chance
to capture crash diagnostics. Before closing each run pane, the sweep
saves its visible screen and bounded scrollback with
`capture-pane -S -1000`. It saves them in the run directory before the
caller closes the window.

`Subrun.save_screen` writes `<run-dir>/screen` with a temporary file and
rename, like `State.record`. The last writer wins. Unlike
`record_outcome`, this does not use first-write-wins. Outcomes need
precedence: an earlier `stopped` must not lose to `completed`. Two
captures of one window need no such precedence.

First-write-wins would also prevent `kido tool spawn_subagent --resume`
from replacing an old screen. Only a sweep writes this file. The first
attempt's screen would then survive every later attempt without a way
to replace it. Instead, `kido tool spawn_subagent --resume` clears it.
`Subrun.reset_for_resume` removes both screen and outcome.

During a second attempt, the run shows no screen instead of the first
attempt's stale screen. `kido runs <id>` prints the screen when present.
An inaccessible screen cannot help diagnosis.

Capture does not depend on the ending. Rule 2 can close a window whose
subagent recorded nothing. Even a clean exit's last screen can be useful.
Every window the sweep closes therefore gets a capture attempt. The
outcome guess (`Died`, or an existing outcome) is independent of screen
availability.

Losing a screen is better than leaving an uncollected window. A
`capture-pane` error or lost race never prevents closure. The byte cap,
`Subrun.max_screen_bytes`, is much smaller than a task's 1MB and much
larger than an activity line's 256 bytes. An unresponsive agent's
scrollback otherwise has no size limit. Truncation keeps the end,
because the last output is the most likely crash diagnostic.

Both helper and sweep use the same 30-second grace from one environment
variable. They run in different processes. A shorter sweep linger
would close the window before the helper.

**Parent death.** The child's pi belongs to the tmux server, not the
parent's pi process. Thus, no OS parent-death signal reaches it. It
polls every five seconds. First, `kill(pid, 0)` gives a definite answer
for `ESRCH` without a subprocess. Otherwise, it calls
`kido get-agent <parent-session>`, which a reused pid cannot deceive.
"What the child asks, and of what" above explains why it uses this
command, not a listing.

Unavailable kido supplies no evidence and never causes shutdown. If
the parent is dead, the child calls pi's `shutdown`. This uses the same
teardown as a normal exit.

## Idle self-exit, and resuming a run

After `KIDO_IDLE_EXIT_SECONDS` of idle time, a subagent calls pi's own
`shutdown`. The default is 30, like the window linger default. The
explanation below shows why these are separate numbers. No other signal
distinguishes "done forever" from "waiting for follow-up". Without this
timer, an idle child keeps its window, pi process and model context until
someone quits it, stops it, or its parent dies. Five spawned children
would all remain.

**One signal, reused.** The timer uses its own `agent_settled` listener.
It trusts the same `agent_settled` / `ctx.isIdle()` event as the status
report to identify a fully ended turn. It does not use a second,
independently timed event. It arms on *every* settle, even without new
result text. A settle with nothing to report is still idle.

New work cancels and restarts the timer. This includes `turn_start`,
the rest of the `running` family and messages about to reach the model.
The timer measures 30 seconds of idle time, not time since the first
settle. An actively used child remains alive. Task delivery also arms
it, covering a child whose pi never starts its first turn.
`design-subagents.md`, "Idle self-exit", describes this case.

The clock also rearms after every `shutdown` call until the session
ends.

**Only a child arms it**, using the session-id identity test under
"The run id is the child's session id". `notify_parent` uses the same
test for refusal. A root session must never collect itself. This
includes a human's interactive pi started inside an agent's pane with
that agent's environment.

`spawn_subagent` also accepts a run-metadata `keepAlive` boolean for a
long-lived helper. Each idle check reads it through
`get-agent --children`. While true, the timer rearms. An edit takes
effect at the next check.

**A session with a live child of its own is not idle.** Waiting for a
child's report settles a turn just like finished work. Before shutdown,
the timer calls `kido get-agent --children <session>`. It checks whether
any session run remains active. Run records supply the parent edge
that survives a turn.

Unless the answer is definitely no, the timer rearms. Errors and
timeouts leave the session open. Exiting would also remove the child:
the orphan rule closes the window of the child that the parent awaits.
See `design-subagents.md`, "Idle self-exit".

**A window a client is looking at is not reaped out from under them.**
Before shutdown, the timer calls `kido get-window <id>`. It prints
`{"id": ID, "focused": bool}`, with false for a missing window.
This uses `Tmux_pane.window_focused`, like `kido close-run` and the
sweep. If focused, the timer rearms instead of exiting. The sweep also
checks again on its next pass. Collection occurs after the user looks
away.

**The outcome is `completed`, not `stopped`**. Nobody intervenes; the
child finishes its own work. `ctx.shutdown()` uses the normal exit's
`session_shutdown` handler. `endOwnRun` accepts an absent reason,
because plain shutdown has no reason. It records `completed` from its
in-process settled flag, like any other quit. A child still waiting for
its first turn instead records `failed`.

**Two 30-second figures stack, and are not one number.** Idle self-exit
runs inside the child's pi process. Only after shutdown does the
separate 30-second window linger begin, before a sweep can close it.
See "Window lifecycle" above. Do not combine these settings. They run
in different processes, use different environment variables and protect
different things: a live child's exit decision and a dead child's pane
awaiting collection.

**`kido tool spawn_subagent --resume <run-id>`.** kido routinely collects
idle children. Resume is the normal way to continue work with them.
A bare `pi --session <id>` starts a standalone session. It has no parent
edge, `@kido_run` mark or new run record. Stop and ask scope do not
recognize it as a descendant.

`--resume` uses the same window-creation path as a fresh spawn:
`Tmux.new_window` and the mark. It makes these changes:

- It launches `pi --session <run-id>` if the pi session file exists.
  Otherwise, it launches `pi --session-id <run-id>` to create the session.
- It continues the existing run record, preserving task, history and id.
  `Subrun.read_meta` supplies the window name and cwd. Resume leaves the
  task file unchanged. It clears `delivered` only if the pi session file
  is missing. Thus, a newly created session receives the stored task again.
- It uses the model, tools allowlist and `keepAlive` from spawn meta.
  The idle timer reads `keepAlive` from the same meta on every check.
  Model and tools use command-line arguments. A tool-restricted child
  must not regain all tools on resume. A narrow toolset limits possible
  damage; the depth ceiling does not provide that limit.

  Explicit `--keep-alive`, or a command's own `--model`/`--tools`, takes precedence.
  Recorded values are defaults, not limits. Resume intentionally cannot
  turn `keepAlive` *off*, with the same asymmetry as `--model`.
- It writes the *new* pane, pid and parent edge into the same meta file.
  Documentation says a fresh spawn calls `Subrun.write_meta` once, but
  code does not enforce that restriction. Resume changes these live facts.
- It clears an existing outcome. Only this operation outside
  `Subrun.record_outcome` may change an outcome. The atomic-link
  "first writer wins" rule still prevents *exit paths describing the
  same ending* from overwriting each other. Resume is not an exit-path
  race. A human or agent intentionally declares the run alive again.
  This occurs strictly *before* any exit path can describe the new attempt.

Resume refuses an unknown run id (`Subrun.read_meta` returns `None`).
It also refuses a run with a live recorded pid (`State.alive`), even
with an outcome. Shutdown can write an outcome before process exit.
Resuming a live agent is not meaningful.

If the pi session file is gone, `--session-id` creates a fresh session
with the run's id. See `design-subagents.md`, "Resuming a run".
`pi_session_file_exists` in `lib/spawn_subagent.ml` checks this. It uses
`PI_CODING_AGENT_SESSION_DIR` if set, or
`<agentDir>/sessions/--<cwd, its slashes and colons dashed>--` otherwise.
The depth ceiling still derives from the *resumer's* caller record,
exactly as for a fresh spawn. Resume cannot bypass it.

Only `--resume` makes `--parent-pid`/`--parent-session` optional.
A fresh spawn requires them or `--no-parent`. See "A parentless spawn,
and a parent that must exist". Omitted values default to the caller's
reported pid and session id, the same source as depth. A human without
a state record therefore resumes a parentless, root-like session that
does not self-collect. An agent becomes the new parent without explicit
parent arguments.

Thus, `kido runs <id>` can print one parent-free
`kido tool spawn_subagent --resume <id>` line. It works for any caller
that uses `cd` to enter the run's cwd. It does not embed an identity that
could be wrong when someone later runs it. `pi --fork <id>` remains a bare command. A
standalone fork, without a parent edge or run record, is a different,
valid operation.

A bare `pi`, without `-- pi --model ...`, uses the run's recorded
`model` as `--model`. A model already named in the caller's command
takes precedence. Meta retains the run's model, so the resumer need not
repeat it.

**`--parent-session` is refused, before the window exists, unless it names
somebody currently alive.** Rule 2 in `lib/reap.ml` closes a marked
window whose child's `parent` session has no live holder. The rule
keeps no history. An unknown session and a session with a dead process
therefore give the same result. The tool has a live caller, but that
caller can end before the command checks.

`--resume` intentionally lets a *different*, manual caller claim the
parent edge, as described above. A value that cannot be checked can
therefore cause a failure. A parent without a holder makes the resumed run an
orphan. Rule 2 detects it in another process at the next sidebar poll,
after the resume command has returned success. The human receives no
error message for this delayed close.

A liveness check before window creation uses the same reading as rule 2.
It replaces silent delayed closure with an immediate refusal that the
caller can act on. A resumer without a state record, or without those
flags, is unaffected. An empty `--parent-session` skips the check and
resumes without a parent.

**`spawn_subagent(resume)`.** The tool follows the CLI. An optional
`resume` parameter calls `kido tool spawn_subagent --resume <resume>`
instead of a fresh spawn. It passes this session's
`--parent-pid`/`--parent-session`, as for a fresh spawn. Combining
`resume` with `task` or `name` causes refusal before sending anything
to kido. A resumed run retains its original task and window name.

A new task or name makes the model's intent ambiguous. The tool does
not silently discard either choice. It accepts `model` and `tools`.
If supplied, they follow `--`, as for a fresh spawn, and override meta
defaults. If omitted, nothing follows `--`, and
`kido tool spawn_subagent --resume` supplies the defaults. `keepAlive`
behaves the same in both cases.

## Steer, interrupt and stop

These three verbs intentionally differ, in increasing order of force.
`steer` adds text to a running turn inside the loop. See "Steer and
followUp". The target reads the correction between tool calls and
continues, instead of restarting. `interrupt` aborts the current turn
through pi's `ctx.abort()`. It leaves the target alive and idle, ready
for a corrected instruction.

Interrupt has no escalation. A target that cannot receive it cannot
abort a turn. No destructive fallback fits "redirect this, do not kill
it". `stop` ends the session through the normal exit's shutdown path.
It needs no second teardown.

**Scope.** An agent caller can reach only its descendants. A human at
the CLI without a state record is exempt from the ancestry check.
Steer and interrupt address live agents. Stop addresses recorded agent
or bash runs by run id or name. Unlike `message_agent`, steer has the
same restriction as interrupt. Both redirect current work with the same
authority, but steer uses less force.

Allowing anyone to steer while only ancestors can interrupt would be
inconsistent. Names express this scope: `_subagent` commands act on
your descendants; `_agent` commands act on any agent. See
`docs/design-subagents.md`, "The tools, and their commands".

This is not a security boundary. It prevents a confused peer from
acting on a tree branch it does not own. kido checks the scope before
sending, using its tree view. The receiving extension checks again with
`get-agent --context`. The sender field is advisory. A session must not
trust an envelope only because it claims an ancestor sender.

The receiver recognizes a human from two facts: an empty sender session
and a pane that no agent occupies. A confused agent must therefore make
two simultaneous errors to appear human. Both walks use the ancestor
chain that `ask_agent` follows in reverse. Both immediately refuse a
self-edge. A corrupt record naming itself as parent therefore cannot
let the session stop itself.

**Escalation.** An unresponsive child does not answer. `stop` sends its
request, then polls the target's record for up to five seconds. If the
record remains, it kills the pane. A held-open connection, invalid
answer or receiver scope refusal causes escalation, not cancellation.
Returning only the send error would make stop fail in the case it must
handle.

Stop kills the target's pane, not its window. The request names one
agent; window closure would also kill unrelated panes. It refuses the
only pane in a session's only window, because that would end the
session. `--force` cannot bypass this refusal.

Stop does not refuse a focused window. This intentionally differs from
linger and sweep, which act automatically. Those must protect a screen
that the user can be reading. A stop instead names an explicit target.

**No inbox means no quiet stop.** Without an inbox, an agent cannot
receive a request. Stop immediately kills its pane instead. This is
destructive and irreversible, so it requires `--force`. An advertised
but unavailable inbox (`Msg.Unavailable`) also requires `--force` for
stop. It does not permit paste delivery of a message.

## Notifying the parent

Notification is explicit. The model calls `notify_parent(summary)`
only when it decides its work is complete. The tool sends an ordinary
`notice` envelope, without a second transport or automatic notification.
Automatic notification cannot identify completion of delegated work.
Any work can settle a turn, not only the delegated task.

For example, answering a peer's inbox `ask_agent` settles a turn just
like finishing the delegated task. Only the subagent's model knows
whether a turn completes the work its parent needs. A "a turn settled,
tell the parent" rule cannot distinguish that result from work for
another agent.

The content is exactly the model's summary. It does not come from
`agent_end` message data, because the model writes it directly. The
parent receives at most 4000 bytes. This exceeds the activity cap,
because it carries work results, not a UI label. It is much smaller
than `MAX_PROMPT_BYTES`, because the whole message enters the parent's
context, rather than travelling as an arbitrary payload.

The full report is not truncated. `kido tool notify_parent` stores a
longer report in the run directory and names it in the notice. See
`design-subagents.md`, "Reporting". The command enforces the cap, not
the tool, so it can preserve the full report. The tool schema therefore
has no duplicate `maxLength`.

For the same reason, `set_status`'s `activity` is left out of its schema.
The tool sends it unchanged to kido. Only `Reporting.one_line`
truncates it, and the schema leaves that handling to the command.

A session that is not itself a spawned child receives refusal before
sending. See "The run id is the child's session id". Such a session has
no parent to notify. The refusal states this instead of silently doing
nothing.

**Who the parent is, and who reads it.** `kido tool notify_parent`
accepts no target. It reads `KIDO_AGENT_PARENT_SESSION` from its own
environment. `kido tool spawn_subagent` sets this parent edge. The
child's pi and every process it starts inherit the edge. The command
resolves the session through `State.load_live`, using the same registry
and question as `kido get-agent`.

An indirect lookup would list agents, find the caller's row, read its
`parent`, then return that target to kido. This would ask a display for
a fact kido already supplies. It would also retain the per-pane view's
problem. A `pi --print` in the parent's pane takes precedence and
removes the parent's record from the answer. The liveness poll and
orphan sweep both reject that view.

An absent variable means a root session. Both command and tool refuse
it. A session without a live record means the parent has exited. This
is an error, not permission to use a fallback.

**What this costs, and what covers it.** A crashed or idle-collected
subagent that never calls `notify_parent` supplies no work report.
kido does not invent one. A fallback *report* would reproduce the
false-positive problem above. A settled turn says nothing reliable
about completion of delegated work.

Instead, that run produces one notice about its **ending**. It contains
the run name, recorded outcome, run id and resume instructions. The
observer that wins the outcome write sends it: the child's shutdown or
a sweep. See `design-subagents.md`, "Reporting". An ending needs no
judgment about the work. Without this limited notice, a parent could
wait forever for a child that no longer exists.

`Msg.notify` sends the ending notice. `Reap.body` supplies the text,
and `Reap.send` sends it. Unlike `notify_parent`, this path never uses
`Message_agent`. `Reap` is below the subcommand modules and can contact
the inbox directly. The `Sidebar` sweep calls `Reap.collect` without a
separate connection to a subcommand module. Plain messages and asks
still use `Message_agent` for target resolution and envelope marshalling.

**Telling a child this is its job.** No other mechanism gives this
instruction. `before_agent_start` appends a standing instruction to the
subagent's system prompt on every turn. It uses the same identity test
as the tool's refusal. It does not add the instruction only once to
`deliverTask`'s first message. Task delivery occurs only once.

A `/reload`, `kido tool spawn_subagent --resume`, or later parent
`message_agent` call can start work without that one-time instruction.
The system prompt keeps it present throughout the subagent session.
The model must consider it on every turn, so it uses only two
sentences.

**The rendered side.** An inbound `notice` uses a custom message:
`pi.sendMessage` with a `customType`, not `pi.sendUserMessage`.
It can collapse to "@X notifies: <first line>...". pi's
`registerMessageRenderer` `options.expanded` exposes the full text.
kido registers no keybinding for this.

Collapse affects only transcript display. The model receives the full
text with one header:
`notice from <from> (a subagent or background
run's report, not the user):`.
The renderer removes this header. Without it, a steered notice reads
like user input. The header distinguishes them. kido marks the custom
message for LLM context.

Every notice collapses identically, even if its sender is not a
subagent. The sender chooses the kind, not the identity, through
`kido tool notify_parent` or `kido tool message_agent`. `from` remains
advisory, as elsewhere in the inbox protocol. Rendering therefore
needs no identity lookup. A notice always requests a turn. An idle
parent receives the same wake trigger as a plain message, described
under "Waking an idle session".

**Visual arrival is immediate; model delivery steers.** These use two
paths. Immediately on envelope dispatch, before any message `await`,
`ctx.ui.setWidget` displays a fully dimmed
"@X notifies: <first line>..." line. When the message reaches the
transcript, `message_start` matches its newly created `noticeId`.
pi's `registerMessageRenderer` then displays the permanent collapsed
row, and kido removes the widget entry.

The text goes to `sendMessage` exactly once. The widget represents the
wait, not a second copy. Thus, a notice never displays twice or reaches
the model twice.

Notices use `"steer"`, like corrections and flushed stream batches,
not `"followUp"`. A parent cannot act on a child's completion without
seeing the report. Subagents permit parallel work. A long parent turn,
with tool calls or other children to coordinate, would otherwise delay
the report until that turn ends.

kido sends a steer, not an abort. The model decides whether to act now
or continue. Coordination requires that judgment, and unseen text
cannot inform it.

Plain messages and asks intentionally keep `followUp`. The model replies to an ask synchronously through
`message_agent`, on its own schedule regardless of arrival time.
A plain message has no equivalent urgency from a sender blocked while
awaiting a response. A notice exists to communicate that urgency.

## Run outcomes

Code that knows how a run ended writes its outcome. A subagent whose
last turn ends with an error also sends an automatic diagnostic notice
on `agent_settled`. It sends this once per failed attempt. The child
remains alive for retry. Thus, this notice is neither an outcome nor a
work report.

The child's own outcomes are `completed` and `failed`. The shutdown
handler reports them through `kido run-outcome` and schedules window
linger. It records `completed` if the session ends idle after reaching
its first turn. It records `failed` otherwise. kido cannot distinguish
more cases from outside the process.

`run-outcome` accepts no other values. `died` and `stopped` are kido's
external judgments. A model-authored process cannot claim these about
itself, for the same reason no `--from` exists. This is a separate
command, not a status-report flag. Any spawned command can end,
including one that never reports status.

A sweep writes `died` when closing a marked window without a recorded
outcome. The child had no chance to report. For bash runs, the sweep
instead writes `failed` and describes the cause: an unreported wrapper
ending or a parent ending. See `design-subagents.md`, "Exactly one
ending". `kido tool stop_run` writes `stopped`.

**Written once.** `Subrun.record_outcome` uses `Unix.link` to link a
complete temporary file into place. It atomically refuses overwrite.
Several exit paths can race, but the first recorded ending wins.
A later, less precise guess never overwrites it. This rule determines
the other ordering:

- kido writes `stopped` immediately after sending the stop request,
  before waiting. It deterministically precedes the child's later
  `completed` from an externally requested exit. Writing earlier would
  be incorrect: every stop refusal leaves the run running, and the
  premature outcome could not be corrected. During escalation, kido
  writes it after the last-pane guard and before killing, for the same
  two reasons.
- A `/reload` must not record `completed`. The shutdown handler excludes
  reloads. Otherwise, it would mark a live run finished and silently
  discard its real ending. The same condition prevents reload from
  scheduling closure of the child's live window.
- `kido runs` guesses `died` for a dead pid without an outcome. It never
  stores this guess. A read-only report must not write on every call.
  Only a sweep closing the run's window may write the outcome.

  The guess inherits liveness-test biases: `EPERM` and a pid reused after reboot
  both mean alive. Both can show a long-dead run as running. Neither
  can mark a live run `died`. A stale running row is the tolerable error.

kido never deletes the task file. The task file records the requested
work. The
sibling `delivered` marker is written only after a successful read.
It prevents duplicate task delivery on `/reload`. A task that cannot be
read remains eligible for the next attempt. The extension does not mark
an unread task as permanently delivered.

kido does not prune run records. A run without a written outcome remains,
and `kido runs` can still report it. The captured screen contains copied
bytes, not a reference to another store. See "The screen capture"
above. Its cap is 64KB.

## Heartbeat and staleness

A live pid can still be unresponsive. pi's identity extension sends a
heartbeat when work starts. An unref'd timer sends another every thirty
seconds while a turn or compaction is active. It stops when
`ctx.isIdle()` is true at settle or compaction completion. The initial
heartbeat refreshes an identity that can have been idle for hours.
All heartbeats bypass the identity-report coalescing key.

A pi is stalled only if both conditions apply:

- Its pane's OSC 7501 root record says working.
- `State`'s heartbeat timestamp is at least three minutes old after
  rebasing against the wake marker.

Blocked, idle, done, error and absent roots never stall. A bare pi has no State heartbeat and never stalls.
The sidebar and one-shot agent graph use the same rule;
`ask_agent` refuses a stalled target before sending anything.
The sidebar also redraws when a refreshed heartbeat clears a stall,
without redrawing on ordinary heartbeat-only changes.

A heartbeat tick changes only one session field. The sidebar compares
records to decide whether to redraw. It compares sessions with zeroed
timestamps, so heartbeat-only changes cause no redraw. Only the stalled
indicator uses the timestamp on screen. A separate check reads it
against kido's clock. Thus, crossing the stall threshold causes redraw
even on an otherwise quiet tick.

### A sleeping machine is not a hundred wedged agents

Staleness compares the current time with the wall-clock report time.
During machine sleep, wall time advances but agent work does not.
On wake, every running agent exceeds the threshold before missing a
real heartbeat. The sidebar's `!` would correct itself. However,
`ask_agent` refuses stalled targets, and a model stops a child reported
as stalled. Thus, closing the lid could cause a healthy tree to be killed.

Only the sidebar ticks continuously, so only it can detect this gap.
Across one tick, it compares the wall-clock interval with the monotonic
interval. `Sidebar.read_clock` creates each `Sidebar.reading` from a
wall time and `Mtime.t` together. `Sidebar.detect_pause` detects a pause
from the difference between intervals. A `Timestamp.t` or disk-read
wall time alone has no monotonic component and cannot participate.

After detection, the sidebar records the wake time in the state
directory's `wake` file, but only if it is newer. Staleness then starts
its threshold at the later of report time and recorded wake. The rule
is not weaker, only later. It still detects an unresponsive agent one
threshold after wake, instead of immediately. An agent that reports
after wake uses its fresh timestamp, as if no pause occurred.

`State.stalled_since`'s `~wake` parameter supplies the marker reading.
A tick caller reads the marker once and uses that reading for every
session. To decide redraw, the sidebar asks the same question at two
instants. Separate reads would use different baselines and prevent a
valid comparison. They also kept a file open per session on the 100ms
path for a value that changes once per suspend.

`kido tool list_runs` reads the marker once through `State.wake` and
passes it the same way. It asks once and exits. The marker is on disk,
not only in sidebar memory, because each call starts a fresh process
without its own tick. `ask_agent` calls `get-agent --context`, which
uses the same agent-row builder. Both must give the same result without
pi's extension needing information about sleep.

This does not cover a session without a running sidebar. Nothing there
detects the gap. An ask against that session still has the original
problem.

## pi extensions, and the seam between them

The pi shim loads two extensions. After interactive terminal feature
detection, pi 1.1.0 natively emits OSC 7501 root records with `app=pi`.
Its lifecycle supplies working, blocked, done, idle and error. Native
dialogs report blocked; extension custom UI does not. Terminal stop
clears the root without app. `PI_PROGRAM_STATUS=0` disables reporting,
and `=1` forces it.

pi supplies no OSC title or progress. OSC 0/2 sets the pane title to
"π - <name> - <cwd>". This title names pi rows and agents verbatim.
The records control indicators and completion attention even without
extensions. The caption omits a local pi message that duplicates its
session name. Other messages remain visible.

A `State` identity adds inbox, parentage, activity and the user-ask
overlay. Gone runs take precedence over terminal records. Activity
supplies the caption if the program supplies no message. A live
subagent without either uses its elapsed clock.

`kido-status.ts` handles:

- identity reporting and coalescing;
- the heartbeat;
- the session claim;
- the inbox server with plain v0 delivery.

The inbox belongs to the status half because it predates the agent
work. It lets `kido prompt` send a prompt to a session without someone
typing there. `kido-agents.ts` handles:

- the tools;
- envelope dispatch beyond plain prompts;
- ask tracking and the cycle edge;
- task delivery;
- the idle self-exit timer;
- outcome reporting;
- window linger;
- the parent-liveness poll.

The two files have different responsibilities. Either can load alone,
but some functions do not work. Without the agent half, envelope text
arrives as a plain prompt. Without the status half, every tool reports
kido unavailable.

The inbox cannot simply divide between them. The agent half needs it to
dispatch arrivals and refuse asks without an answer destination. Only
one socket and one identity-report coalescing key exist. Neither may
be duplicated. The halves communicate through two slots.

The status half publishes accessors for the kido path, session id and
inbox-open state, plus shared `deliver`, `runKido` and `spawnDetached`.
The agent half publishes only hooks with actual callers. It retains no
published hook for a possible future reader.

**The slots are on `globalThis.__kidoPiExtensionSeam`.**
`kido-status.ts` declares the global property's type; `kido-agents.ts`
imports only types from it and accesses the same property. Neither half
imports runtime values from the other.

**There is no load-order assumption.** Neither half reads a slot at
factory time. Each writes its own slot and reads the other only during
an event, tool call or hook. Agent tools register at factory time.
Their calls do nothing until the session resolves kido and its session
id. Resource lookup belongs in `session_start`.

User-ask tools register after resolution, so only top-level sessions
receive them. A session that switches to subagent identity hides any
previously registered user-ask tools.

**The hooks exist because ordering within one lifecycle event is
load-bearing**. The status half calls the agent half's hooks at these
exact points:

- `session_start` first captures the session context, including its UI
  for the notice widget and `@name` completion. A reload's fresh context
  replaces the old context even without kido.
- Parent polling and task delivery occur after inbox binding or adoption.
  The first task turn can already receive an answer. They occur before
  the first report, which carries `--inbox`.
- Shutdown records the outcome and schedules linger after this module
  stops serving the inbox, but before the removal report. kido can still
  resolve the session's parent edge and window during these operations.

Without a status-half ordering dependency, the agent half listens
independently. Its own `agent_settled` listener arms the idle self-exit
timer without depending on status reporting. See "Idle self-exit, and
resuming a run" above. None of these points sends a parent report.
The subagent decides when to call `notify_parent`.

`runKido` uses asynchronous `spawn`, never `execFileSync`. A blocking
call stops the whole process while kido runs. A slow ask or message can
take five seconds. During this time, the process's inbox listener
cannot accept connections. A peer's arriving message connects and
writes, but reaches its two-second read deadline without acknowledgement.

On failure, `runKido` returns kido's stderr line. The model can act on
"no agent session matches" or "ask refused", not other failure details.
It reports a timeout as a timeout, not a failure, because kido can
already have completed its work.

## The sidebar tree

The sidebar indents a subagent's window under its spawning agent's
*pane*, not after the whole parent window. The subagents belong to the
coordinating agent, not a shell sharing its window. The walk supplies
both anchor and indent. Reported depth does not supply them. A
subagent can report depth 1 even if its parent is absent or in another
session.

Indenting by depth alone would place it under an unrelated preceding
row. The walk nests a window only under a pane with a found edge.
Every agent pane is an anchor, not only the window's first pane.
A window can contain two agents, such as a top-level pi with a second
pi in a split. The second agent's child nests under that pane's row.

The window's own tree position still comes from one record: its first
agent pane's record. A window has exactly one position, regardless of
its agent count.

Nesting inside a window divides its bracket. The ┌ ├ └ glyphs join the
window's panes in one column. A │ stem continues that column left of
nested rows instead of restarting it. Thus, a three-pane window with a
middle-pane subagent has one bracket around an indented block:

    ┌ zsh
    ├◼orchestrator
    │ ┌◼subagent
    │ └ zsh
    └ zsh

The stem stops when no parent rows remain below it. A child of the last
pane therefore has no line extending into empty space.

Windows anchored to one pane form a second, inner bracket. Each child's
first row uses ├, except the last child's row uses └. Three children
therefore appear as one group, not identical dots without a visible
relationship. A lone child also uses └. Its spawning pane matters more
than its pane count.

A one-pane child uses only that glyph, because a one-row bracket adds
no information. A multi-pane child keeps its own ┌…└ bracket in a
separate column immediately after the group glyph. The group
continuation, │ or a blank under └, extends beside every row:

    └ working-on-kido
      ├┌◼helper
      │└ zsh
      └ other-child

A user-created split in a running child's window therefore appears as
that window's second pane. The group glyph does not hide its window
relationship. Window rows run from oldest pane to newest, by numeric
pane id. tmux allocates these numbers monotonically. `list-panes`
uses layout order, and `split-window -b` places a new pane above an
older pane. `Tmux_pane.order_sessions` sorts once, so all readers agree
on row 0.

A window nested under a parent's pane does not follow tmux window order.
A subagent window can appear above a lower-numbered window. Later parent
panes can appear below another whole window. This is an intentional
trade, not a bug: the sidebar displays the spawn tree.
`kido switch-window` (S-Up/S-Down) first moves among the nested window's
direct siblings in feed order, including runs.

Prev from the first child selects its direct parent, even when nested.
Next from the last child moves from its top-level ancestor. Top-level
steps never descend. They skip windows containing `@kido_run` panes and
wrap across sessions in sidebar order. A sole eligible root can select
itself.

The command prints nothing. Its key bindings use `run-shell`, which
would display output in the pane. RPC and the focused sidebar's
Shift-Up/Down keys use the same order. If an anchor row never appears,
the tree displays the item as a root. As with missed ordering items,
this prevents an agent from becoming invisible.

The sidebar and `kido tool list_runs` walks share parent-first ordering.
It emits every item exactly once, with or without a tree. A reporting
bug or replayed old state file can create a cycle. A roots-only walk
cannot reach that cycle. The walk therefore emits missed items afterward
as roots. An invalid edge loses only the item's tree position.

A self-edge means "no parent". Siblings retain arrival order.
`kido tool list_runs` first sorts by report time, then breaks ties by id.
Without this tie-break, two agents reporting within one clock tick could
change order between calls reading the same state.

## The sidebar's model, and the feed

### Tmux handles

`Tmux.t` identifies a server and fixes command delivery. `Tmux.create`
creates a one-shot handle. `Tmux.Client.connect` lazily attaches a
control client to the named real client's session. `Tmux.Client.tmux`
returns a new handle on the same socket, with commands through that
control client. The handle is immutable. `Tmux.Client.t` owns the
control client's link, parser, replies and retry backoff.

Only the sidebar's single tick accesses this mutable state. Following
sessions and waiting for notifications belong to the control client,
not the server handle.

A failed control command remains failed, including after timeout or
client closure. The channel never silently becomes one-shot. Two
explicit read fallbacks exist: `Tmux.list_clients` for an empty reply
or control error, and `Tmux.list_panes` for a control error. They read
the same socket through one-shot calls without replacing the handle's
original channel.

`tmux.mli` exposes:

- flat pane, window and session ids;
- `Pane_map`;
- server operations;
- `Client`;
- `Program_status` OSC 7501 types and parsing API.

The library contains only `tmux.ml` and `program_status.ml`. Filesystem
and executable-path helpers belong to `lib/fs.ml`, built as shared
`kido_fs`. Thus, tmux binary lookup and kido installed-file lookup share
unresolved-path rules without a dependency cycle. Lazy tmux binary
lookup and `-u` argv construction remain in tmux.

### Model and feed

The shared sidebar model and RPC feed are described in [design-rpc.md](design-rpc.md).

## Priming a remote shell

An `ssh` pane reports remote activity only from remote reports. tmux
parses OSC 133 from pane output without knowing the markers crossed a
network. `Pane_status.observe` latches the pane after a remote prompt
marker later than the local ssh-start marker. The remote shell must
source `share/zsh/integration.zsh` or `share/bash/integration.bash`.
Both emit the same four markers.

On a host without an installed integration, the marked pane remains
running throughout the connection. `kido ssh` resolves user and hostname
with `ssh -G`, sets `@kido_ssh` on its pane, then execs ssh. The mark
remains after ssh exits. kido trusts it only while the foreground
command is `ssh`. A remote pi or Claude Code root gives a nested
`Remote_agent`, including paste prompt support; otherwise it gives
`Remote_terminal`.

`kido shell` supplies a local pane's integration. It primes every pane
that the kido server starts, as described under "Priming a local shell".
It writes nothing to the user's rc files. The bash integration uses
`PS0` for command-start markers and `PROMPT_COMMAND` for prompt markers.
It requires bash 4.4 or newer. Sourcing it a second time causes no action.

`kido ssh` supplies the remote host's integration with the connection.

**What is sent.** The binary embeds the integration (`kido/shell`).
kido base64-encodes it in a POSIX sh bootstrap and sends this as ssh's
remote command. Every connection carries both integrations, regardless
of the remote login shell. stdin remains available for the interactive
session.

**What that costs, said plainly.** The payload is a public shell script
without secrets, so kido permits it in argv. A payload with a secret
would require another channel. All sidebar information about the pane
comes from the remote host's report. This is less reliable than the
local process table that kido uses elsewhere. A host can report any
claim about what it runs.

**The ZDOTDIR swap.** The bootstrap creates a fresh directory with
`mktemp -d` and decodes the integration there. It writes `.zshenv`
beside the integration, sets `ZDOTDIR` to that directory and execs the
login shell. The generated `.zshenv` restores `ZDOTDIR`. If the user
already has `ZDOTDIR`, `KIDO_ORIG_ZDOTDIR` carries it for restoration.
Otherwise, `.zshenv` unsets `ZDOTDIR` again.

The bootstrap never writes or installs anything in remote `$HOME`.
The swap occurs only if the user already has zsh dotfiles.

**The bash branch.** The bootstrap sets `ENV` to a file beside the
decoded integration in the same temporary directory. It execs the login
shell with `--login --posix`. That file disables posix mode again.
It sources `/etc/profile`, then the first of `~/.bash_profile`,
`~/.bash_login` or `~/.profile`. It then sources the integration and
removes the directory.

Before priming bash, the bootstrap checks the minimum version, 4.4.
It starts the login shell once with `"$kido_shell" -c 'echo
"${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"'`. An answer below 4.4 uses
`kido_plain`. A non-version answer, from a shell only named bash, also
uses `kido_plain`. Older bash reads its login files without markers,
through the same route as an unsupported shell.

The version check occurs before `--posix`. The inline test in
`lib/prime.ml`, "the bootstrap leaves a bash too old for PS0 alone",
pins this behavior. Unlike the zsh branch, the bash branch has no
dotfile guard.

**Nothing persists.** kido resends the payload on every connection.
`.zshenv` reads the integration into a parameter and removes the whole
directory. The bootstrap also installs `trap ... EXIT` to clean its
returning paths.

zsh sources the integration at its first `precmd`, not in `.zshenv`.
This places kido's hooks after the user's setup.

**Degrade, never break.** `kido ssh host` must not behave worse than
`ssh host`. kido passes the command line unchanged, without `-t` or a
remote command, unless all priming conditions apply:

- a destination;
- no user-supplied remote command;
- a local tty;
- none of these no-login-shell options: `-N`, `-T`, `-W`, `-f`, `-n`,
  `-s`, `-O`, `-Q`, `-V`, `-G`.

For priming, kido adds `-t` for an interactive shell. Every remote
failure starts the same login shell without priming. These failures
include an unsupported shell, missing `mktemp` or `base64`, directory
creation failure and payload decoding failure. kido execs ssh. Signals,
exit status and tty therefore behave as with ssh alone. If `ssh -G`
fails, kido skips the pane mark but still runs the connection.

The bootstrap reads remote `$SHELL`. It primes zsh and bash, with both
base64-encoded integrations on the command line. It selects the branch
by login-shell basename. Every connection therefore includes the bash
payload, regardless of the selected shell. Together the payloads use
only a few KB, well within ssh command-line capacity.

kido intentionally does not implement:

- terminfo shipping or compilation;
- a remote kido binary;
- ControlMaster sharing;
- askpass;
- fish.

## The launcher

The user runs `kido` without arguments. A word as the first argument
selects a subcommand. UI flags select the interactive UI.
`kido --client <name>` selects the one-shot picker that `C-s` opens in
a popup. The side column is an exception: the fork starts bare `kido`.
`TMUX_SIDE_CLIENT` distinguishes it, and
`Kido_sidebar.model.standalone` reads that variable.

The launcher never runs inside a multiplexer. If `TMUX` is set, it
refuses, starts nothing and requests a plain terminal. A multiplexer
already owns that terminal. Nesting another adds a second prefix and
status line.

The launcher starts `kido-tmux`, the vendored fork beside kido or named
by `$KIDO_TMUX`. `AGENTS.md`, "The tmux fork", describes lookup order
and fork features. Only the state directory identifies the server.
The socket is `<dir>/socket`. The launcher starts and attaches with
`-S`, never a socket name. Every tmux client kido starts uses `-u`, so
UTF-8 does not depend on the invoking locale.

`kido --server DIR`, `kido server --server DIR`, and outside-pane helpers
explicitly select the directory. Without this option, they use
`State.dir`. Inside a pane, it uses the socket's dirname from `$TMUX`
if the basename is `socket` and `server.conf` exists beside it. The
config marker distinguishes kido from a plain tmux socket named `socket`.

This takes precedence over the default environment order. Hooks, tools,
extensions and the sidebar therefore read the same records, even if
ambient `KIDO_STATE_DIR` points elsewhere. Extensions and shims call
kido instead of resolving the directory independently. The launcher
removes `KIDO_STATE_DIR` from the new server's environment. Only the
build stamp and PATH need export. Servers have separate `server.conf`
files and records, even when their pane ids repeat.

The socket gives full shell access. kido creates state directories with
mode 0700. Start and connect refuse these paths:

- a non-directory, including a symlink;
- a directory not owned by the current user;
- a directory with any group or other permissions.

The socket path, including terminating NUL, must fit
`sizeof(sockaddr_un.sun_path)`: 104 bytes on macOS, 108 on Linux.
kido refuses a directory name with a comma, because `$TMUX` uses commas
between socket path, pid and session. It refuses overlong paths before
creating the directory. The error includes the path and maximum length.
To debug the default server, use
`kido-tmux -S ~/.local/state/kido/socket`.

The launcher probes with `list-sessions` and handles three results:

- If a server answers, it attaches.
- If stderr reports "protocol version mismatch", an older kido-tmux
  remains after upgrade. kido reports the socket and restart instructions.
- For any other result, it starts a server and lets tmux report socket
  problems.

At creation, kido writes `<dir>/server.conf`. The new server reads it
in this order:

1. kido's defaults, exactly `share/tmux/kido-tmux.conf`.
2. `source-file -q` of `$XDG_CONFIG_HOME/kido/kido.conf` or
   `~/.config/kido/kido.conf`.
3. kido-owned `side-status-command` and `default-command`, each using
   the kido binary's absolute path.

The user's file follows defaults, so user settings take precedence.
kido-owned options come last to prevent accidental loss of the side
column. kido first captures a user-set `default-command` with `set -gF
@kido-user-command '#{default-command}'`. `kido shell` runs that command.
The server never reads `~/.tmux.conf`. To use it, add one `source-file`
line.

Paths have two quoting layers: one for tmux and one for the shell that
tmux uses to run the command.
`Launch.tmux_safe` refuses a path with characters that cannot survive
quoting, before anything starts.

Inner shell-level quotes apply only to paths with spaces. At spawn,
tmux names a fresh window from the first word of `default-command`.
The fork's `names.c` function `default_window_name` removes at most
one quoting layer. Unnecessary path quotes produce a single backslash.
With `automatic-rename off`, nothing corrects this name.

The window is therefore named `kido`, the command's first word, not
the shell name. The pane runs `kido shell`, not the shell directly.
Installation paths with spaces still produce the backslash. The first
session is `main`, not tmux's `0`. Only fresh server startup creates
it, so nothing already holds the name.

`kido server` provides the launcher without a terminal. A client such
as Kido.app attaches independently. The command uses the same probe.
If the server is down, it starts detached through `Launch.new_session`:
`server.conf`, environment, PATH and session `main`. It never attaches,
so it can also run inside tmux.

It prints one JSON line,
`{"tmux":...,"socket":...,"protocol":...,"server":...,"expected":...}`,
with these values:

- the resolved kido-tmux as an absolute path;
- the convention's `<dir>/socket` path;
- the binary's `Protocol.value`, always a string;
- global server environment `KIDO_SERVER`, or JSON null if absent;
- the binary's `Launch.stamp`.

`server` always exists, even when it equals `expected`. The app compares
them to detect an upgrade requiring server restart. `docs/design-rpc.md`
describes stamp derivation. The launcher sets `Launch.stamp` in the
started tmux process's environment. tmux copies it before forking the
server and accepting clients. The stamp is therefore readable while
`server.conf` still runs.

Config options would not be readable then. During config, tmux blocks
only the initial client. The probe uses one invocation:
`list-sessions -F '#{socket_path}' ;
show-environment -g KIDO_SERVER`. A direct reader uses
`kido-tmux -S SOCKET show-environment -g KIDO_SERVER`. It prints
`KIDO_SERVER=VALUE`, or exits 1 for a missing variable. Attaching or
making sure an existing server runs never changes its stamp.

`kido --version` prints the binary's embedded build id and a newline.
`Build_id` reads `Build_info.V1.version`, with default `unknown`.
This project has no tags. The commit tree identifies the tmux gitlink,
so the id has no separate fork pin. The executable contains the id,
not a mutable manifest. `make install` and the e2e harness copy
`build/main.exe` over the raw install-tree binary.

After a failed start, the launcher probes again. A responding server
means success. Two simultaneous clients race for `main`; the loser's
`new-session` fails against the winner's server. A mismatch causes the
launcher's refusal under `kido server:`.

`Shell.command` primes a captured single-word command if it names zsh,
bash or the login-shell executable under another name. It does not run
that command inside another shell. kido primes it with `-l` instead of
nesting it. A command with arguments still runs as a command. So does
a command naming a shell that kido does not prime.

### Priming a local shell

`kido shell` is the default command. It resolves the user's shell in
this order, checking each candidate for executability:

1. The server's `default-shell`, if set.
2. `$SHELL`.
3. `/bin/sh`.

It runs a login shell with the same priming as `kido ssh`:

- zsh uses a temporary `ZDOTDIR`. Its files source the user's real
  files, then the integration.
- bash 4.4 or newer uses `ENV` with `--login --posix`.
- Other shells use plain mode.

`lib/prime.ml` supplies one implementation for mode selection,
temporary-directory contents, argv tail and minimum bash version.
Transport intentionally differs. The remote side has only sh, so these
parts generate a POSIX ssh bootstrap. Version comparison exists once
in OCaml and once in sh. A plain-mode local shell uses tmux's dashed
argv[0]; the remote shell uses `-l`. sh cannot set another process's
argv[0].

### The bin directory

kido ships four `sh` shims in `<prefix>/share/kido/bin`: `kido`, `tmux`,
`ssh` and `pi`. Their source is `share/bin`. The shared helper
`share/shim.sh` installs as `share/kido/shim.sh`. Inside a kido pane,
those names resolve to these shims:

- `kido` execs `<prefix>/bin/kido` relative to its shim. Pane commands
  and server-side bindings therefore use this prefix's binary, not
  another installation on PATH.
- `tmux` uses `Tmux.binary`'s order: `$KIDO_TMUX` if set, then adjacent
  `kido-tmux`, then the first `tmux` on PATH after the shim. Lookup of a
  bare-name `KIDO_TMUX` also starts after the shim. Otherwise, `exec`
  would find the shim itself. This shim is necessary, not only convenient.
  `$TMUX` in a kido pane names the kido socket, and the shim selects
  kido's client.
- `ssh` runs `kido ssh "$@"`. For the same reason,
  `Bin_dir.look_path_past` finds the real ssh after the bin directory.
- `pi` runs the real pi with `--extension` for
  `share/kido/pi/kido-status.ts` and `kido-agents.ts`. It writes nothing
  to `~/.pi/agent/extensions`. It passes pi subcommands unchanged when
  they are the first argument: `install`, `remove`, `uninstall`,
  `update`, `list`, `config`, `auth`.

A shim never embeds an installed path. It calculates every location
from `$0`. `kido_share` is `$0/../..`. The kido and kido-tmux directory
is `$0/../../../bin`, the inverse of `Bin_dir.of_exe`.

For user-installed programs, the shim selects the first same-name
executable on PATH *after* its own directory. If its directory is
absent from PATH, as for a path invocation, it selects the first match
that is not itself. The rule is "after", not "anything but me".
A second installation's shim is a different file. The latter rule
would send the call there, and that shim would send it back.

**PATH.** The bin directory becomes first on PATH in two places:

- The launcher starts the server with it first. The server preserves
  that environment for commands without an intervening user shell:
  `run-shell`, plugins, `new-window` commands and every spawned `pi`.
- Every locally primed shell's integration places it first again at the
  end. `Prime.files` appends `Bin_dir.path_prepend_script` when given a
  bin directory. This occurs after login files, which can rewrite PATH.

The prepend first removes all existing occurrences. A nested shell or
second launch therefore never increases PATH length.

`kido ssh` sends the shipped integrations unchanged. The remote side
has no kido or shims, so nothing changes PATH there. The local-only
connection is `Prime.files ~bin_dir mode`. `Prime.ssh_bootstrap` never
calls it.

A path containing `:` cannot form a PATH entry. `Bin_dir.of_exe`
therefore reports that bin directory absent, and kido uses no shims.
A kido binary without adjacent `share/kido` also uses no shims. A checkout
build is one example.

A plain-mode shell has no integration. This includes fish, zsh without
dotfiles and bash below 4.4. It keeps shims only if login files preserve
the inherited PATH order.

**One copy of each pi extension.** On its first factory call, each file
claims a `globalThis` property containing its path. These properties are
`__kidoPiExtensionStatusCopy` and `__kidoPiExtensionAgentsCopy`.
A copy at another path registers nothing. The key is
`fileURLToPath(import.meta.url)`, so test imports with `?fresh=` count
as the same copy.

**Install layout.** The `install` stanza in `share/dune` is the only
layout definition for `share/kido`. It mirrors repository `share/`,
beside `bin/kido`:

- `bin/`;
- `shim.sh`;
- `bash/`;
- `zsh/`;
- two pi extensions under `pi/`, without tests, testdata or package files.

This excludes `kido-tmux.conf`. The launcher writes its embedded copy
into startup configuration. Nothing reads that file from disk.
`make install` copies `bin` and `share` from `_build/install/default`
into `PREFIX`, default `~/.local`. This tree contains `bin/kido`,
`bin/kido-tmux` and `share/kido` together.

The fork comes from the revision-keyed cache under `build/tmux-fork/`,
shared with e2e. Repeated installs reuse it.
`make install PREFIX=<prefix> SELF_CONTAINED=1` passes `--self-contained`
to the fork installer and uses a separate
`<revision>-self-contained` cache entry. The e2e harness copies the same
tree into `<tmp>`.

## Knobs

Every duration that a test must shorten is a package variable.
Durations used by e2e also read environment variables. The suite uses
a separately built binary, so only environment values reach it. These
variables are:

- `KIDO_LINGER_SECONDS`, shared by the sweep and extension helper;
- `KIDO_IDLE_EXIT_SECONDS`, the separate idle self-exit timer that adds
  to linger rather than sharing it (see "Idle self-exit, and resuming a run");
- `KIDO_STALL_THRESHOLD_MS`;
- `KIDO_STOP_ESCALATION_MS`;
- `KIDO_HEARTBEAT_MS`;
- `KIDO_PARENT_POLL_MS`;
- `KIDO_ASK_POLL_MS`;
- `KIDO_SPAWN_TIMEOUT_MS`;
- `KIDO_STOP_TIMEOUT_MS`;
- `KIDO_AGENT_LIST_TTL_MS`;
- wrapper streaming variables `KIDO_STREAM_BATCH_MS`,
  `KIDO_STREAM_BACKOFF_MS` and `KIDO_STREAM_BACKOFF_CAP_MS`.

Streaming variables control batch frequency and retry delay after a
failed send. The extension reads its variables once at module scope.
Its tests re-import both files with a cache-busting specifier to read
fresh values. Both files must be re-imported together. Otherwise, a
fresh half and cached half would silently connect through `globalThis`
and serve a session that neither started.

## Known limits

- A child spawned with `--no-parent` has no parent to collect it. It
  arms no idle timer, `notify_parent` has no target, and no sweep rule
  applies while it lives. The user must close its window. This is the
  flag's purpose, not a defect. It is the only agent type that kido
  never collects.
- A subagent moved to another session with `move-window` is outside its
  parent's scope and cannot be asked.
- A blocked `ask_agent` holds a whole pi turn, for one turn of the
  target's latency.
- A child that exits before `remain-on-exit` lands loses its window and
  its last screen; only the run record remains.
- Pause detection needs a sidebar ticking when the machine sleeps.
- A `kido ssh` session killed after ssh starts but before remote zsh
  reads `.zshenv` leaves its temporary directory. The exec removes the
  trap before cleanup runs. This leaves one nearly empty directory under
  remote `$TMPDIR`.
- The design assumes one machine. All agents share filesystem access to
  the state directory, the sockets and the task file. Agents share a pid
  namespace, and each has an
  adjacent kido binary. Remote subagents would reverse discovery and
  transport. The design intentionally does not support them.
