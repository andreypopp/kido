# kido's design, as built

This document describes how kido works and the reasons for its design.
Its companion, [design-subagents.md](design-subagents.md), follows one
subagent from spawn to sweep. That document refers here for the mechanisms
that support the subagent. `AGENTS.md` describes constraints kido cannot
change: the tmux fork and the reports from Claude Code and pi. It also
describes problems that an apparently correct change can cause. This
document does not repeat those constraints or problems.

kido has two parts. The `kido` binary manages tmux windows, the runs in
them and their status. A **run** is a process that kido starts in a
tracked window: a bash command, or a pi agent. kido mints an opaque run
id, keeps `runs/<id>/`, records the ending and answers queries by id
after the window is gone.

The **harness** is everything that only an agent has: the pi session,
the inbox, the tools, the task, the report and the names. It is one pi
extension, `share/pi/kido-pi.ts`, which the `kido-pi` shim loads. The
two parts talk through the run commands ("Window lifecycle") and pane
options ("Who is authoritative for what"). kido never reads the
harness's files. The harness reads no kido file except the output path
that a run command prints.

The sidebar polls tmux and the run records of the panes it shows. This
poll also collects run windows.

## Who is authoritative for what

Three stores each hold information that no other store can hold:

**tmux, for topology.** tmux supplies these facts:

- the window and session that contain each pane;
- the pane's foreground command;
- whether anyone is attached;
- whether the pane's process has exited, and how.

kido never caches these facts. A pane can move between windows and
sessions while its process runs. A window id has meaning only on the
server that issued it. A run record names only a pane, not its window or
session.

**Pane options, for which run a pane holds.** `@kido_run`
(`set-option -p`) names the run of the pane. `kido run` and `kido
run-child` set it in the `new-window` command list of the pane that they
create. The option is in the tmux server, where no race removes it. It
names a current pane, not a pane id that a later server can give to
another process.

Killing the pane removes the option without a separate unmark step. The
pane-scoped option lets a sweep and the sidebar distinguish the run's
pane from a pane that the user later creates with a split. A
window-scoped option would also apply to the user's pane.

**Pane options, for the facts only an agent has.** The extension writes
four more pane options with `set-option -p`:

| option | value | kido reads it for |
|---|---|---|
| `@kido_session` | the pi session id | `Pane_kind.Pi_agent`, `Pane_status` identity, the session column of `kido runs` |
| `@kido_name` | the session name | the row title of a local pi |
| `@kido_inbox` | the inbox socket's full path | `Prompt.reachable`: `kido prompt` and the RPC prompt |
| `@kido_activity` | `set_status` text, one line, at most 256 bytes | the caption fallback |

kido trusts them only while the pane has an OSC 7501 root with
`app=pi`, as it trusts `@kido_ssh` only while the foreground is `ssh`.
The fork drops the records on pane death, a shell prompt (non-final
records), RIS and respawn, so a crashed pi's options are stale but not
believed. A crash in an integrated shell can leave a final root: the
inbox is then dead, and a prompt fails with "not accepting". No option
copies a field of the run record. Both `@kido_run` and `@kido_session`
exist because kido writes one and the harness writes the other, and a
top-level pi has a session but no run.

**The runs directory, for everything else.** `Server_dir.dir` resolves the
server's state directory once at the command boundary. It uses this
order:

- a convention-following `$TMUX` socket with `server.conf` beside it;
- `$KIDO_STATE_DIR`;
- `$XDG_STATE_HOME/kido`;
- `~/.local/state/kido`.

Every run has one directory `<state>/runs/<run-id>/`. Each write
replaces a whole file:

- `meta.json`: written by `kido run` or `kido run-child` at the start.
  It contains the id, name, parent, pane, the pane's pid, cwd and the
  start time. The parent is optional: absent for a
  top-level run, a run id for a run that owns it, or the pane id `%N`
  of a top-level pi (`kido run-child %N`). The JSON is the bare string
  in both cases; a run id never starts with `%`.
- `command`: the argv, written with the meta.
- `outcome`: several writers can race (a failed start, `run-outcome`,
  `run-stop`, the sweep). The first write wins ("Run outcomes").
- `output`: written by the run's own command. A caller that wants it
  puts `tee "$KIDO_RUN_OUTPUT"` in its command line.
- `screen`: the sweep's capture of the dead pane. The last write wins.

A top-level pi has no run and no directory. kido stores nothing for a
pi session.

A run's status comes from its outcome file and its pane, never from a
pid. Its pane is the pane that `@kido_run` marks with its id and that
its meta names. A run has **ended** when it has an outcome, or when
that pane is dead or gone. Without an outcome, tmux supplies the ending
while the dead pane exists: `#{pane_dead_status}` 0 is `completed`,
another status is `failed` with the text `exit N`, and
`#{pane_dead_signal}` is `failed` with `signal NAME` (`State.parse`
upper-cases the name, which tmux spells per platform). A dead pane with
neither, or no pane, is `died`. `Run.effective_outcome` derives this;
`kido runs`, `kido run-wait` and the RPC `Ended` result show a derived
ending like a recorded one. Only the sweep stores it, through the
first-write-wins link.

Only OSC 7501 root records supply status. OSC 0/2 supplies the pane
title.

A trusted `@kido_ssh` pane option takes precedence as `Ssh`. It contains
`Remote_agent` for a remote pi or Claude Code root, or `Remote_terminal`
otherwise. Otherwise, `Pane_kind.classify` classifies a pane as:

- `Pi_agent`: a pi root on a pane with `@kido_session`;
- `Some_agent`: a `claude-code` root, or a pi root without the option;
- `Terminal`: any other case.

The root gate makes a stale option no agent: a pane whose pi exited to
its shell is a terminal, whatever options remain. A run does not
identify a pane as an agent. Prompt scope accepts both agent cases. It
uses `@kido_inbox` or otherwise pastes.

Native Claude Code has no identity or inbox.
Its blocked message is the caption. A visit acknowledges completion, and
clear restores a terminal row. The sidebar displays pane titles
verbatim. Only a native-only agent with an empty title uses its root app
name instead.

There is no locking. Runs are never deleted.

## The pi extension, kido-pi

`share/bin/kido-pi` starts pi with `--extension <share>/pi/kido-pi.ts`
in front of every argument. It has no case for pi's package
subcommands; use plain `pi` for those. A bare `pi` in a kido pane is
plain pi: it reports OSC 7501 status and has no harness.

After interactive terminal feature detection, pi 1.2.0 natively emits
OSC 7501 root records with `app=pi`. Its lifecycle supplies working,
blocked, done, idle and error. Native dialogs report blocked; extension
custom UI does not. Terminal stop clears the root without app.
`PI_PROGRAM_STATUS=0` disables reporting, and `=1` forces it. pi
supplies no OSC title or progress. OSC 0/2 sets the pane title to
"π - <name> - <cwd>". The caption omits a local pi message that
duplicates its session name.

The extension uses only these interfaces of kido:

- The run commands `run-child`, `runs --json [--parent P]`,
  `run-wait ID --json`, `run-stop` and `run-outcome`.
- `tmux set-option -p -t %PANE` and `set-option -pu`, for the four
  pane options.
- `tmux list-panes -a` and `display-message`, for discovery and
  liveness.

It never finds or parses kido's state directory. The only kido file it
reads is a run's output, at the path that `run-child` and `runs --json`
print. It sends envelopes in the v1 inbox
format directly to the target's `@kido_inbox` socket.

**Inside kido** is `KIDO_RUN_ID` set, or `$TMUX` set and `kido` on
PATH. A pi outside kido, a pi without a UI or a pi without a session
id writes no option and binds no inbox. A headless `pi --print` has its
own session id, so it cannot act as the agent of the pane that it runs
in.

**The state directory** is per user and shared by every kido server:
`$KIDO_PI_STATE_DIR`, else `$XDG_STATE_HOME/kido-pi`, else
`~/.local/state/kido-pi`. It is not under a server directory, because
the agent map outlives a server. It is not under `$TMPDIR`, because the
map outlives a reboot. It holds:

- `inbox/<session-id>.sock`, in a 0700 directory. The path derives from
  the session id, so `notify_parent` needs no lookup. The 103-byte
  socket limit applies.
- `agents/<parent-session>/<name>/`, the agent map
  (design-subagents.md, "The agent directory").

**The options.** The extension writes `@kido_session` and `@kido_name`
at `session_start`, `@kido_inbox` after the bind, `@kido_name` again on
`session_info_changed`, and `@kido_activity` on `set_status`. Writes
are coalesced, and one `tmux` call carries each batch, with `;`
between the commands. Without `$TMUX_PANE`, nothing is written. At
shutdown it unsets the four. A crash leaves them; the trust rule makes
them harmless. `set_status` replaces control characters with spaces and
cuts the text at 256 bytes on a character boundary, because the sidebar
allows one terminal line per row.

**The trust rule.** The extension's own discovery uses kido's rule: a
pane is a local pi agent only with an OSC 7501 root with `app=pi`
(`#{pane_program_status}`) and `@kido_session`. Discovery, addressing,
the parent watch and the ask's liveness poll all apply it. A stale
option on a shell pane is no agent.

**One copy.** On its first factory call, the extension claims
`globalThis.__kidoPiExtensionCopy` with its path. A copy at another
path registers nothing, because pi dedupes extensions by real path
only. The key is `fileURLToPath(import.meta.url)`, so test imports with
`?fresh=` count as the same copy.

**Subprocesses.** The extension starts every kido and tmux process
with asynchronous `spawn`, never `execFileSync`. A blocking call stops
the whole process while kido runs. During that time, the inbox listener
cannot accept connections, and a peer's message reaches its two-second
deadline without acknowledgement. A failed command returns its stderr
line, which the model can act on. A timeout reads as a timeout, because
kido can already have completed its work.

## Identity

**An agent is its session, not its process.** The pi session id is the
identity. `@kido_session` publishes it, the inbox path derives from it,
and the agent map names parents and children by it. A pid is not an
identity, because the OS reuses pids.

**A run id is not a session id.** kido mints the run id. A restarted
agent is a new run with the same session. The parent mints the child's
pi session id and passes it with `--session-id`. `agent.json` records
both, so no mapping needs to be derived.

**The parent edge.** `KIDO_AGENT_DIR` names the child's agent directory.
The child trusts it only when that directory's `agent.json` names the
child's own pi session id. Every process that an agent starts inherits
its environment: a human's `pi` in that pane, or a tool calling
`pi --print`. A nested pi mints its own session id, so it cannot meet
the rule, and it inherits nothing. The parent is the session in the
directory name above it. `KIDO_AGENT_PARENT_SESSION` is also set, only
for the repo's `no-git-writes` guard.

**The relationship comes from the map, not from kido.** A sender is the
parent if its session is the parent session, a child if it is in
`agents/<own session>/`, else a peer.

**kido has no caller.** kido commands take their parent as an
argument (`run-child PARENT`). kido never finds a caller from the
environment or from its pane.

**Children belong to the session that spawned them.** A parent that
restarts under its own session id finds its children again in
`agents/<session>/`. `/new`, `/resume` and `/fork` move a pi process to
a new session id. A child still names the old id, and its parent watch
ends it. Transferring the parent edge would send a child's report to a
session that nobody reads.

**Two pis on one session** share only the inbox socket path. The
extension unlinks a stale socket file only after a 200 ms connect probe
fails, so it never displaces a live listener. The second pi binds
nothing and publishes no `@kido_inbox`.

## The inbox

A pi session that accepts prompts as real user messages listens on a
unix stream socket and publishes its path as `@kido_inbox`. Just before
binding, the extension creates the inbox directory with mode 0700.
Anyone who can write there can impersonate an agent's socket. A path
over the 103-byte limit binds nothing, so the session runs without an
inbox instead of listening where nobody can connect.

**A `/reload` does not take the inbox down.** A reload keeps the process
and session id. `globalThis.__kidoPiExtensionInbox` holds the server,
which survives the module that bound it. The server's connection
listener uses that slot indirectly, not a closure over one module's
handler.

For reason `"reload"`, `session_shutdown` parks the socket: it stays
bound, and connections wait. The reloaded module's `session_start`
adopts the server and its waiting connections without rebinding. Every
other reason closes the server and unlinks the socket. A notice has no
paste fallback and is sent exactly once. Thus, the reload gap must not
discard it.

A reload also keeps the four pane options, because the socket stays
bound and the session continues. Unsetting them would make the parent
look gone during the gap: a child's `notify_parent` would find no
parent, and its parent watch would end it. Only the other reasons unset
them. The `run-wait` watches survive in
`globalThis.__kidoPiExtensionWatches`, with all their stream state: the
offset, the held lines, the budget and the idle schedule. The old
module detaches each waiter before it kills it, so only the reloaded
module can send an ending. Its `session_start` restarts one waiter for
each. A run
that ended during the gap is reported by its new waiter, so its notice
is not lost.

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
message. A sender treats any slower response as unresponsive.

`ok` means the agent has the message and sees it at its next turn
boundary. This is the only acknowledgement level. `message_agent`
promises delivery, not action.

An agent's message identifies its sender. A `message` from another agent
reaches the model as a custom message, like a notice. It uses
`pi.sendMessage` with a `customType`. One header line identifies the
sender and its relationship to this session:
`message from @<name> (your parent,
who spawned you):`, `(your subagent):`, or `(another agent in this
session, not the user):`. Only the peer header says it is not the user.
A child's only user is its parent, so a parent's instruction has that
authority.

The renderer removes the header and displays `message from @<name>:`
with the full text. Unlike a notice, a message never collapses, because
its purpose is to be read. Only v0 text, which `kido prompt` sends, is
the user's own text, without a header.

An `ask` uses the same custom-message handling and relationship header:
`ask from @<name> (your parent, who spawned you):`, and the other forms.
The model's text includes:

- the question;
- the ask's id;
- a line saying the asker cannot see this session's context;
- the exact `message_agent` call for the reply.

The renderer displays only `ask from @<name>:` and the question. The id
and reply instructions are for the model, not the human reading the
transcript.

### Steer and followUp

The extension uses `followUp` to queue work and `steer` to interleave
work. An idle recipient uses the wake path below.

The rule, one line:

> Steer what is safe to interleave. Queue what must be answered in order.

This rule determines the incoming work and report kinds:

- **`ask` queues.** An ask requires a correlated reply. Two asks must
  never remain in flight inside one turn. `followUp` keeps correlated
  questions in order. The cost is the wait under "Known limits".
- **`message` queues.** It has no correlation to confuse and no authority
  over the receiver's work. It waits for the current turn, like user text.
- **`steer` steers.** The agent that assigned the work sends a correction.
  It needs no correlation and has no value after that work ends.
- **`notice` steers.** The parent needs this information to assign the
  next work. Thus, it is interleaved instead of queued.
- **A stream batch steers.** It is not an envelope: the parent tails the
  run's output file itself (design-subagents.md, "Streaming a run's
  output").

Escape and the dequeue key restore only queued user text to the editor.
Custom messages remain in their steering and follow-up queues, in order.
They reach the next turn boundary exactly once. The extension wraps
`AgentSession.clearQueue` to preserve them while pi clears editor
queues. `globalThis` holds the original method. Thus, `/reload` replaces
the wrapper instead of adding another wrapper.

### Waking an idle session

The extension sends each arrival with
`sendMessage(..., { deliverAs, triggerTurn: true })`. `deliverAs` is the
kind's steer or follow-up mode. While a run is active, pi queues the
message in that mode. While the session is idle, pi starts a run with
the custom message as its first message. No user-role text is sent.
Thus, the run contains no synthetic user prompt. The arrival keeps
its custom type, header and renderer.

pi starts this run with the same setup as a prompt. It runs
`before_agent_start` with `messageType: "custom"`, and the extension's
handler adds its prompt guidelines. The run gets the current system
prompt and selected tools. It also contains every pending `nextTurn`
message.

**One run at a time.** pi counts the session as busy from the start of
the run, also while `before_agent_start` handlers run. A second
arrival during that time goes into the starting run's queue in its own
mode. It does not start a second run. Two asks can thus be in one run.
Each ask has its own id and receives a reply with `replyTo`, so
simultaneous arrival causes no misattribution.

### v0 and v1

A v0 payload is raw prompt text. A v1 payload is one JSON object with:

- a version;
- a kind (`message`, `ask`, `reply`, `notice`, `steer`, `interrupt`,
  `stop`);
- an id;
- a sender: session, name and pane;
- an optional `replyTo`;
- the text.

A payload is v1 only if it parses as a JSON object with both `v` and
`kind`. All other payloads are v0 text, including JSON objects missing
either field. A user prompt can itself be a JSON object. The parser
must not treat that prompt as a control message. A fixture table
(`share/pi/testdata/discriminator.json`) tests the parser. An unknown
kind reaches the model as text labelled with that kind.

The extension sends only v1. `kido prompt` always sends v0. It is
independent of agent type and must continue to support Claude Code
panes. It targets only top-level agents. A pane is never a candidate if
its window contains a run pane (`@kido_run`). This uses the same reader
as the sweep and `switch-window`.

If the caller's window has no candidate, the search widens to the
session. Without this exclusion, one agent and one live child in the
session would give two candidates and exit 5. A human could reasonably
have meant the agent.

The protocol has no version gates, including for interrupt and stop.
kido runs on one machine, and the binary and extension upgrade together.
Thus, a version gate would serve no purpose. Stop escalation kills the
pane whether or not the target understands the request.

The sender field is advisory. The inbox directory's mode enforces
uid-scoped trust. Any same-uid process can write an envelope that
claims any identity. A peer-credential check would add no protection.

## Delivery, and when a paste is allowed

`kido prompt` delivers through `Msg.deliver`. `Msg.Unavailable` means
nothing was sent: the path is empty or unusable, the socket file is
missing, or a stale socket has no listener. After connection, kido
reports each failure as `Msg.Failed`. The message can already have
arrived, so a retry could deliver it twice. The extension's sends use
the same rule: a timeout or error before the connection is
`unavailable`, and only that is retried while a restarted child binds
its inbox. A timeout or error after the connection is `failed`, never
retried.

kido permits a bracketed paste and separate Enter only when the pane
has no `@kido_inbox`, or `kido prompt` selects a native-only agent pane.
Claude Code has no identity and is reachable only through a paste. An
advertised but unavailable inbox is an error. It means the target does
not accept messages.

The extension never pastes. A target without `@kido_inbox` is "not
accepting messages". Model-authored text must not run as a command line
in the target's pane. A refusal (`refused`) is not a delivery failure.
The target reads the question and intentionally declines it.

The extension refuses two more sends before sending: a message to the
caller itself, which would return as a fresh user turn, and text that is
not valid UTF-8.

## Addressing

The tmux session limits addressing for `message_agent`, `ask_agent`,
`steer_subagent` and `interrupt_subagent`. `list_runs` has a narrower
scope (design-subagents.md, "The tools, and what they call").

The tools show names, not ids, and still accept a session id or a
unique prefix: two top-level pis may share a name, and another parent's
child has no name for the caller. Within scope, a target resolves by
these rules in order:

1. An exact case-insensitive name.
2. An exact session id.
3. A unique id prefix.

Each rule reports its own ambiguity. It does not try another rule to
guess a match. A match in the caller's tmux session wins over a match
elsewhere. A target in another session is reported as such, not as "not
found". Unnamed pi sessions match only by id. Native-only panes have no
addressable session. `stop_run` resolves run ids first; its rules are in
design-subagents.md, "Redirecting one, and ending one from outside".

The extension refuses instead of guessing. It never infers `replyTo`,
even with exactly one pending ask from the target. A wrong guess would
resolve the wrong pending ask and assign one question's answer to
another question. A reply re-resolves the asker from the pane the ask
came from, so it reaches an asker whose session id a `/reload` changed.

In pi's prompt editor, `@` and a prefix complete live agent rows from
`list_runs`. Completion excludes bash and ended runs. Each row shows
status, activity and a subagent's parent. The extension wraps the
completion provider to place agent matches first. It delegates tokens
with no agent match. A token matches the start of a name or any word in
it, with whole-name matches first. A whitespace name cannot form one
`@` token. For that name, completion inserts the shortest unique id
prefix, which addressing resolves like a name.

A keystroke uses the last list without waiting for discovery. If the
list is older than `KIDO_AGENT_LIST_TTL_MS` (1s), a background refresh
starts. Nothing is fetched until the first `@`.

## Ask and reply

An ask blocks the calling tool until an answer arrives at the asker's
inbox. The extension assigns the envelope id and registers a waiter
before it sends the `ask`. The answer arrives later in a separate
`reply` envelope with that id.

The wire `ok` means received, not answered. A model turn takes minutes.
The two-second inbox timeout must not include that turn.

**A caller with no inbox is refused.** Replies can arrive only through
the asker's inbox. Without one, nothing can answer the caller's
question.

The extension also refuses a target that cannot reply. A reply requires
a `message_agent` call. A child's tools allowlist can exclude that tool,
leaving no way to answer. The ask would only block. `list_runs` reports
`canReply` beside `canMessage`.

The expected latency is one full turn, not a round-trip. Questions
queue with `followUp` and wait for an explicit `message_agent` reply.
The default wait is five minutes. Thus, timeout does not mean that the
question failed. A late reply reaches the model as an ordinary message
instead of being discarded. The ask id remains a valid correlation for
that reply.

### The cycle edge

A subagent cannot ask an ancestor, so the parent remains free to
coordinate work. The extension follows the parent chain of the agent
map to enforce this rule. Parent-to-child and peer-to-peer asks remain
possible. Thus, two peers can block on each other.

Each extension keeps the prevention rule in memory. If this session
already has a waiting ask to an inbound ask's sender, it answers
`refused` on the wire. It does not deliver that ask to the model.
An on-disk edge set would survive `kill -9` on the asker. It would then
permanently block future reverse asks.

The edge set is the waiting-ask map itself, not a separate count.
An edge exists exactly while an ask to that target waits. Thus, no
second count can disagree. An unmatched reply-shaped envelope does not
remove a waiter.

The extension registers the waiter synchronously before the `await`
that starts sending. An inbound ask already sees the edge while the
send is in flight. Settling a waiter is idempotent.

### When the inbox goes away

Without an answer destination, a waiter would wait for its whole
timeout on an unserved socket. Its cycle edge would remain closed for
the same duration. Thus, shutdown releases every waiting ask, including
on reload. On reload, the socket remains bound and the reloaded module
adopts the listener; the old module's waiters have no module to settle
in.

`session_shutdown` first stops this module from serving the inbox:
it parks the socket on reload, or closes it for any other reason. Then
it releases every waiter. `ask_agent` uses one synchronous "is the inbox
open" check before it registers a waiter, with no `await` between them.
The check reads the module's view, not the held server. It refuses
during a reload gap, even while the socket listens.

### When the target goes away

Only the asked process can answer. If the target stops running, the
ask ends, regardless of how the process stops. A target can be alive at
the send and dead a second later. Without another check, the asker would
wait for the whole `timeoutMs`.

A waiting ask therefore reads the target's pane every
`KIDO_ASK_POLL_MS` (five seconds), or every pane with `list-panes -a`
when the target's pane is not known, as after a restart. A successful
read that does not show the target's session under a pi root settles
the waiter. A failed read supplies no evidence and settles nothing.
The poll prevents overlapping reads, and its timer is unref'd, so the
wait never keeps pi's event loop open.

Using `notify_parent` to settle a pending ask would infer a `replyTo`
that the child never supplied. A notice is not an answer. A killed or
crashed child cannot refuse on the wire. One mechanism reads the fact
common to every case: the process is gone.

### When the human interrupts

The ask tool listens to its `AbortSignal`. The signal settles the
waiter like any other outcome. It removes the pending entry and cycle
edge. The tool reports the ask id as it does for a timeout. A later
reply still reaches the model as a message.

## Spawning

`spawn_subagent` starts a child through `kido run-child`
(design-subagents.md, "What a child is given"). `run-child` creates a
detached window in the caller's tmux session. Three `new-window` flags
are necessary:

- `-d` keeps focus on the caller's window during its turn.
- `-c` starts the child in the parent's directory, not the session's
  default directory.
- `-e` supplies each variable. `new-window` uses the server and session
  environment, not the caller's environment. No other route supplies
  those variables.

The task is never a command-line argument. A model writes text of any
form. A tmux command line nests three parsers, and no escape survives
all three. The task is a file in the agent directory, and the child
reads it at `session_start`. A restart's message is an exception: it is
pi's argv, which tmux `execvp`s without a parser.

The model also writes the window name, which does enter the command
line. `Tmux.safe` refuses characters that cannot survive the nested
tmux, sh and tmux parsers. kido also refuses names over 64 bytes,
instead of silently changing them. The extension applies the same rule
before it calls kido. The extension also uses the name as a directory,
`agents/<parent>/<name>/`. Thus, it refuses an empty name, `.`, `..`
and a name with `/` before it writes anything.

### Failure leaves a record

`run` and `run-child` create the run directory before the window. If
`new-window` fails, kido writes meta and marks the run `failed` with the
error. Thus, `kido runs` does not show an unexplained run without a
window. If window creation succeeds but marking fails, kido kills the
window and records `failed` in the same way. No sweep can collect an
unmarked window. A window that nothing can find again is worse than no
window.

## Window lifecycle

**Run commands.** kido starts a run without the harness:

| command | does |
|---|---|
| `kido run --name N [--cwd D] [--session S] [--env K=V]... -- CMD...` | starts a parentless run; prints `{"id":ID,"window":"@WIN","pane":"%PANE","output":PATH}` |
| `kido run-child PARENT ...` | the same, under PARENT: a live run id, or the pane `%N` of a live pi root |
| `kido runs [--json] [--parent P] [ID]` | lists runs newest first, with a SESSION column, or one run; each JSON row has the run's `output` path |
| `kido run-outcome ID --result completed\|failed\|stopped [--text T]` | records an ending, first write wins; a lost write exits 5 |
| `kido run-wait ID [--json]` | blocks until the run has ended; prints the result, or the outcome object |
| `kido run-stop ID [--wait SECS] [--result stopped\|completed]` | records the result, then ends the process and closes its pane |

`run` and `run-child` mint an opaque id, write `meta.json` and
`command`, and create the window through `Run_window.start`. `--name` is required, because a
command's first word (`bash`, `pi`) says nothing; it passes `Tmux.safe`
and the 64-byte cap. `--session` takes a session id or name and
defaults to the caller's session; `--cwd` defaults to the caller's cwd.
The argv is the pane's command, `execvp`'d by tmux; no wrapper runs
around it. The window's environment has `KIDO_RUN_ID` and
`KIDO_RUN_OUTPUT=<dir>/runs/<id>/output`, plus each `--env`. The
SESSION column of `kido runs` is the live pane's `@kido_session` while
the pane has a pi root, else empty; kido stores nothing for it.

Exit codes: 0 success; 1 usage or any other error (a tmux failure, the
last-window refusal); 2 a bad or unknown
PARENT or `--parent` (an unknown or ended run, a gone or dead pane, a
pane without a pi root); 3 a bad or unknown run id; 4 a refused window
name; 5 `run-stop` of a run with no live pane (dead or gone), or a
`run-outcome` write that loses to an earlier outcome.

`run-wait` polls at the sidebar's tick. Each poll reads the outcome
file, then the panes of the run's own window (`State.read_run`), not
the whole server. tmux gives the same error for a gone pane and for a
failed server, so after an error one `list-panes -a` tells them apart.
`run-stop` waits with the same read. A pid is never evidence: a killed pane whose process survives
its HUP has ended, and `run-wait` reports `died`.

**run-stop** records its result first, so that an ending that the pane
produces later cannot replace it. If an outcome already exists, the
earlier outcome stays and the stop continues. Then it waits `--wait`
seconds (default 0) for the pane to die, sends TERM to the pane's process
group, KILL after `KIDO_STOP_ESCALATION_MS`, and kills the pane under
the last-window refusal (`Reap.close_of`). A refusal exits 1 with the
outcome recorded. A run with no live pane (dead or gone) exits 5 at once.

A caller that must act between the record and the stop records first
with `run-outcome`, then runs `run-stop`. `--result completed` is for a subagent that reported
before it was stopped. `kido run-stop` sends no notice; the caller's
`run-wait` reports the ending.

A `pane-died` hook in place of `run-wait` is rejected: it costs a
process per death, puts the state directory on its command line, and
`kill-pane` fires none.

A spawned window enables `remain-on-exit` on the run's pane through
`set-option -p`, not a window option. The pane survives its command's
exit. Thus, a dead pane stays for the sweep's grace.

The `new-window` command list also sets `@kido_run` and
`remain-on-exit` on the new pane. Thus, no snapshot sees an unmarked run
window, and an immediately failing child keeps its pane and last screen.

Before closing a run's pane, the sweep saves its last screen. It
collects only the run's pane, so a user's split pane remains. "The
sweep" below gives the pane and window rules.

**The sweep.** `Reap.sweep` runs at every sidebar poll tick. It collects
subagent windows in a live session. `kido reap` calls the same function
manually, for a test or operator. The sweep uses the sidebar snapshot's
`State.t` from `Sidebar.take`, through `Reap.collect`: every pane, its
options, and the runs that their marks name, from one `State.read`.
For each marked child, the sweep finds its parent's meta in that
state's runs, and reads it from disk only for a parent with no live
pane. The state keeps modal panes. The sweep acts only on the pane of
a run that kido started in its own window, never a modal pane.
`Sidebar.take` filters modal panes out once, into the snapshot's
`visible`, which the rows and the feed read.

Several sidebars, one per client, can sweep simultaneously. A sidebar
can ask tmux to close a window another sidebar already closed. This
produces an error that nobody reads.

A sweep starts from tmux, not from kido's runs. A pane id is not an
identity. Each new tmux server restarts pane ids at `%0`, while run
records survive the server. A run's meta can therefore name another
process's current pane. The sweep acts only on a pane whose `@kido_run`
names the run, and whose run meta names that same pane. Thus, a sweep
cannot close a plain shell window or a top-level pi's window.

Two rules apply:

1. The run's pane has been dead for the linger grace period. The sweep
   records the ending that the dead pane gives ("Who is authoritative
   for what": `completed`, `exit N`, `signal NAME` or `died`).
2. The run's parent has ended. A run parent has ended by the same
   status rule. A pane parent (`%N`) has ended when its pane is gone,
   dead, or shows no OSC 7501 root with `app=pi`. The sweep kills the
   run's pane while its command runs and records `failed` with the
   text "its parent ended".

An earlier outcome, from `run-outcome` or `run-stop`, stands in both
cases: `Run.record_outcome`'s link refuses the second write. Rule 2
forces a stop instead of requesting graceful shutdown like the child's
poll. It is the only available action outside pi, and it ends a `tail
-f` that an exited parent started. This rule needs run meta, because
tmux does not know parentage. A run without a parent is a root that the
sweep must not cancel. A stale final root keeps a child of a crashed
top-level pi alive until RIS, respawn or the pane's death; `run-stop`
reaches it. Neither rule acts on a client's current window or closes a
session's last window. Waiting loses nothing, because the sweep runs
next tick.

**A split window is the user's window.** The collection unit is the
run's pane, not its original window. Waiting until every pane dies would
leave the dead run beside the user's shell until the user leaves.
Thus, the sweep returns a pane or window (`Reap.close`). The caller
kills the run's pane with `kill-pane`. If that pane occupies the whole
window, the caller uses `kill-window`.

These operations differ. Killing a window's last pane also closes the
window. However, only the window case can destroy a session. Only that
case must obey the last-window refusal. A window linked into several
sessions lists its one pane once for each session. Thus, the whole-window
case counts distinct pane ids, and it refuses when the window is the last
window of any session that it is linked into.

The pane-scoped `@kido_run` returns the window to ordinary use without a
separate unmark step. Killing the run's pane removes the option, which
exists nowhere else. Other readers use that option:

- The tree nests the window under its parent.
- Top-level window cycling skips the window.
- The sidebar draws the run's label.
- A later sweep considers the window again.

After pane removal, the sidebar draws an ordinary window with the user's
remaining panes. `run-stop` and stop escalation do the same: they kill the target pane and leave an ordinary window. A user's
split pane has no `@kido_run`. No window-scoped fallback supplies one.
It also has no `remain-on-exit`, so its normal exit closes the pane and,
when appropriate, the window.

Rule 2 acts on one read of the panes. No pid decides.

No other guard applies: no grace period or debounce. This also lets a
one-shot `kido reap` apply the rule in its single sweep.

Without grace, a child already shutting down can lose its window during
exit. It can receive "its parent ended" before recording its own outcome.
`Run.record_outcome` uses an atomic link to preserve the first written
outcome. Only a child that has not yet written an outcome risks this.

**The screen capture.** Only the sweep sees a marked window's dead pane
before closing permanently destroys its screen. This is the only chance
to capture crash diagnostics. Before closing each run pane, the sweep
saves its visible screen and bounded scrollback with
`capture-pane -S -1000`. It saves them in the run directory before the
caller closes the window.

`Run.save_screen` writes `<run-dir>/screen` with a temporary file and
rename. The last writer wins. Unlike
`record_outcome`, this does not use first-write-wins. Outcomes need
precedence: an earlier `stopped` must not lose to `completed`. Two
captures of one window need no such precedence.

`kido runs <id>` prints the screen when present.
An inaccessible screen cannot help diagnosis.

Capture does not depend on the ending. Rule 2 can close a window whose
subagent recorded nothing. Even a clean exit's last screen can be useful.
Every window the sweep closes therefore gets a capture attempt. The
recorded ending is independent of screen availability.

Losing a screen is better than leaving an uncollected window. A
`capture-pane` error or lost race never prevents closure. The byte cap,
`Run.max_screen_bytes`, is much smaller than a task's 1MB and much
larger than an activity line's 256 bytes. An unresponsive agent's
scrollback otherwise has no size limit. Truncation keeps the end,
because the last output is the most likely crash diagnostic.

The sweep uses a 30-second grace from `KIDO_LINGER_SECONDS`.

**Parent death.** The child's pi belongs to the tmux server, not the
parent's pi process. Thus, no OS parent-death signal reaches it. Its
extension watches the parent's pane (design-subagents.md, "A child's
life"). A failed read supplies no evidence and never causes shutdown.
If the parent is gone, the child calls pi's `shutdown`. This uses the
same teardown as a normal exit. The sweep's rule 2 covers a run that is
not a pi.

## Ending a child, and restarting it

A child has no idle timer. After it reports, or after a turn settles
with nothing to do, it keeps its window, pi process and model context.
Only three things end it:

- its parent, with `stop_run`;
- the user, who quits or kills the window;
- the orphan rule, after its parent ends.

The parent decides, because only the parent knows whether it needs more
work. The child's report is not an ending. The notice a parent receives
from `notify_parent` says so: end the child with `stop_run` when nothing
more is needed, or continue it with `message_agent`.

**An ended child restarts on a message.** `message_agent` or `ask_agent`
to an ended subagent starts it again as a new run under the same pi
session, with `kido-pi --session <session file>` and the message as
pi's first prompt. There is no resume tool: a reused name means "message
it". design-subagents.md, "Restarting through a message", gives the
rules.

## Steer, interrupt and stop

These three verbs intentionally differ, in increasing order of force.
`steer` adds text to a running turn inside the loop. See "Steer and
followUp". The target reads the correction between tool calls and
continues, instead of restarting. `interrupt` aborts the current turn
through pi's `ctx.abort()`. It leaves the target alive and idle, ready
for a corrected instruction. An interrupt answers only after the abort
settles.

Interrupt has no escalation. A target that cannot receive it cannot
abort a turn. No destructive fallback fits "redirect this, do not kill
it". `stop` ends the session through the normal exit's shutdown path.
It needs no second teardown.

**Scope.** An agent can reach only its descendants: agents with the
caller in their parent chain in the agent map. Unlike `message_agent`,
steer has the same restriction as interrupt. Both redirect current work
with the same authority, but steer uses less force.

Allowing anyone to steer while only ancestors can interrupt would be
inconsistent. Names express this scope: `_subagent` tools act on your
descendants; `_agent` tools act on any agent. See
`docs/design-subagents.md`, "The tools, and what they call".

This is not a security boundary. It prevents a confused peer from
acting on a tree branch it does not own. The sender checks the scope
before sending. The receiving extension checks again with its own
agent map. The sender field is advisory. A session must not trust an
envelope only because it claims an ancestor sender. The chain walk
stops at a repeated session, so a corrupt map entry that names itself
as parent cannot let a session stop itself.

**Escalation.** An unresponsive child does not answer. `stop_run` first
records the outcome with `kido run-outcome ID --result stopped`. The child's
own shutdown writes `completed` or `failed`, so a request sent before
the record would let that write win. A record that loses to an earlier
outcome is ignored. Then it sends its request, and runs
`kido run-stop ID --wait 5` whatever the request returned: a
recorded stop must also end the process. A request that fails is
reported beside the cleanup's result. The extension's deadline for
`run-stop` is its `--wait` plus `KIDO_STOP_ESCALATION_MS` plus 1.5 s,
so that the KILL and the pane cleanup always run. A healthy child
ends itself within the wait. Otherwise, kido sends TERM to the pane's
process group, KILL after `KIDO_STOP_ESCALATION_MS`, and kills the
pane. A refused request does not cancel the stop: the escalation still
runs. Returning only the send error would make stop fail in the case it
must handle.

Stop kills the target's pane, not its window. The request names one
agent; window closure would also kill unrelated panes. It refuses the
only pane in a session's only window, because that would end the
session. `force` cannot bypass this refusal.

Stop does not refuse a focused window. This intentionally differs from
the sweep, which acts automatically and must protect a screen that the
user can be reading. A stop instead names an explicit target.

**No inbox means no quiet stop.** Without an inbox, an agent cannot
receive a request. Stop then kills its pane at once. This is
destructive and irreversible, so it requires `force`.

## Notifying the parent

Notification is explicit. The model calls `notify_parent(summary)`
only when it decides its work is complete. The tool sends an ordinary
`notice` envelope, without a second transport or automatic notification.
Automatic notification cannot identify completion of delegated work.
Any work can settle a turn, not only the delegated task.

For example, answering a peer's inbox `ask_agent` settles a turn just
like finishing the delegated task. Only the subagent's model knows
whether a turn completes the work its parent needs.

The content is the model's summary. The parent receives at most 4000
bytes. Every report notice ends with the guidance that the child stays
alive, so the parent must end it with `stop_run` or continue it with
`message_agent`. That guidance is part of the bound. This exceeds the
activity cap, because it carries work results, not a UI label. It is
much smaller than the 1MB inbox payload cap, because the whole message
enters the parent's context. Every delivered report is kept whole in the
agent directory's `report` file (design-subagents.md, "A child's life").

A session that is not itself a spawned child is refused before sending.
Such a session has no parent to notify. The refusal states this instead
of silently doing nothing. A parent whose pane no longer shows its
session under a pi root has exited. This is an error, not permission to
use a fallback.

**What this costs, and what covers it.** A crashed subagent that never
calls `notify_parent` supplies no work report. kido does not invent one.
A settled turn says nothing reliable about completion of delegated work.
Instead, the parent's own `run-wait` tells it how the run ended
(design-subagents.md, "A child's life", Endings). An ending needs no
judgment about the work. Without this limited notice, a parent could
wait forever for a child that no longer exists.

**Telling a child this is its job.** `before_agent_start` appends a
standing instruction to the subagent's system prompt on every turn. It
uses the same parent-edge test as the tool's refusal. A `/reload`, a
restart, or a later parent message can start work without the task's
one-time first message. The system prompt keeps the instruction present
throughout the session. The model must consider it on every turn, so it
uses only two sentences.

**The rendered side.** An inbound `notice` uses a custom message:
`pi.sendMessage` with a `customType`, not `pi.sendUserMessage`.
It can collapse to "@X notifies: <first line>...". pi's
`registerMessageRenderer` `options.expanded` exposes the full text.

Collapse affects only transcript display. The model receives the full
text with one header:
`notice from <from> (a subagent or background
run's report, not the user):`.
The renderer removes this header. Without it, a steered notice reads
like user input.

**Visual arrival is immediate; model delivery steers.** These use two
paths. Immediately on envelope dispatch, before any message `await`,
`ctx.ui.setWidget` displays a fully dimmed
"@X notifies: <first line>..." line. When the message reaches the
transcript, `message_start` matches its `noticeId`, the permanent
collapsed row appears, and the widget entry goes. The text goes to
`sendMessage` exactly once, so a notice never displays twice or reaches
the model twice.

Notices use `"steer"`, like corrections and stream batches, not
`"followUp"`. A parent cannot act on a child's completion without
seeing the report. A long parent turn, with tool calls or other children
to coordinate, would otherwise delay the report until that turn ends.
The extension sends a steer, not an abort. The model decides whether to
act now or continue.

Plain messages and asks intentionally keep `followUp`. The model replies
to an ask through `message_agent`, on its own schedule. A plain message
has no equivalent urgency. A notice exists to communicate that urgency.

## Run outcomes

Code that knows how a run ended writes its outcome. A pi child's own
outcomes are `completed` and `failed`. Its shutdown reports them through
`kido run-outcome`: `completed` if the session ends idle after reaching
its first turn, `failed` otherwise (design-subagents.md, "A child's
life"). kido cannot distinguish more cases from outside the process.

`run-outcome` also accepts `stopped`, which a parent's `stop_run`
records before it stops the child. `died` is kido's external judgment
only. This is a
separate command, so any run can end, including one that never reports
status.

A sweep that closes a marked window without a recorded outcome writes
the ending that the pane gives: `completed`, `failed` with `exit N` or
`signal NAME`, or `died`; or `failed` with "its parent ended" under the
orphan rule ("Window lifecycle"). `kido run-stop` writes `stopped`, or
`completed` with `--result completed`.

**Written once.** `Run.record_outcome` uses `Unix.link` to link a
complete temporary file into place. It atomically refuses overwrite.
Several exit paths can race, but the first recorded ending wins.
A later, less precise guess never overwrites it. This rule determines
the other ordering:

- `run-stop` writes its result before it waits or signals. It
  deterministically precedes the child's later `completed` from a
  requested exit, and the pane's signal ending.
- A `/reload` must not record `completed`. The shutdown handler records
  only for reason `quit`. Otherwise, it would mark a live run finished
  and silently discard its real ending.
- `kido runs` and `kido run-wait` derive an ending from the pane for a
  run without an outcome (`Run.effective_outcome`). They never store
  it. A read-only report must not write on every call. Only a sweep
  closing the run's window, `run-outcome` and `run-stop` write the
  outcome. Without a reachable tmux server, `kido runs` reads no panes,
  so every run without an outcome reads `died`.

kido does not prune run records. A run without a written outcome remains,
and `kido runs` can still report it. The captured screen contains copied
bytes, not a reference to another store. See "The screen capture"
above. Its cap is 64KB.

## The sidebar tree

The sidebar indents a subagent's window under its spawning agent's
*pane*, not after the whole parent window. The subagents belong to the
coordinating agent, not a shell sharing its window. The walk supplies
both anchor and indent. A run's parent comes from its meta, through the
run mark of its pane: a run parent nests the window under the pane of
that run, and a pane parent (`%N`, from `kido run-child`) under that
pane, with or without a run record. A parent can be absent or in another
session.

Indenting by depth alone would place it under an unrelated preceding
row. The walk nests a window only under a pane with a found edge.
Every agent pane is an anchor, not only the window's first pane.
A window can contain two agents, such as a top-level pi with a second
pi in a split. The second agent's child nests under that pane's row.

The window's own tree position still comes from one run: the first pane
whose run names a parent. A window has exactly one position, regardless of
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
older pane. `State.order_sessions` sorts once, so all readers agree
on row 0.

A window nested under a parent's pane does not follow tmux window order.
A subagent window can appear above a lower-numbered window. Later parent
panes can appear below another whole window. This is an intentional
trade, not a bug: the sidebar displays the spawn tree.
`kido switch-window` (S-Up/S-Down) first moves among the nested window's
direct siblings in feed order, including runs.

Prev from the first child selects its direct parent, even when nested.
Next from the last child moves from its top-level ancestor. Top-level
steps never descend. They skip windows containing the `@kido_run` pane
of a run that kido started, and wrap across sessions in sidebar order. A sole eligible root can select
itself.

The command prints nothing. Its key bindings use `run-shell`, which
would display output in the pane. RPC and the focused sidebar's
Shift-Up/Down keys use the same order. If an anchor row never appears,
the tree displays the item as a root. As with missed ordering items,
this prevents an agent from becoming invisible.

The sidebar's walk (`Tree`) uses parent-first ordering.
It emits every item exactly once, with or without a tree. A reporting
bug or edited run meta can create a cycle. A roots-only walk
cannot reach that cycle. The walk therefore emits missed items afterward
as roots. An invalid edge loses only the item's tree position.

A self-edge means "no parent". Siblings retain arrival order.

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
`Server_dir.dir`. Inside a pane, it uses the socket's dirname from `$TMUX`
if the basename is `socket` and `server.conf` exists beside it. The
config marker distinguishes kido from a plain tmux socket named `socket`.
This rule lives only in `Server_dir.dir`. A command that reads state for
a directory talks to that directory's server through `Server_dir.tmux`,
never through `$TMUX` or tmux's default socket: outside a pane, or in a
plain tmux pane, the two name different servers, and a live run would
read as `died`. `kido shell` and `kido ssh` are the exception: they act
on the pane's own server.

This takes precedence over the default environment order. Hooks, tools,
extensions and the sidebar therefore read the same records, even if
ambient `KIDO_STATE_DIR` points elsewhere. Extensions and shims call
kido instead of resolving the directory independently. The launcher
removes `KIDO_STATE_DIR` from the new server's environment. Only the build stamp and PATH need export. Servers have separate `server.conf`
files and records, even when their pane ids repeat.

The socket gives full shell access. kido creates state directories with
mode 0700. Start and connect refuse these paths:

- a non-directory, including a symlink;
- a directory not owned by the current user;
- a directory with any group or other permissions.

The socket path, including terminating NUL, must fit
`sizeof(sockaddr_un.sun_path)`: 104 bytes on macOS, 108 on Linux.
kido uses the smaller limit, 103 bytes without the NUL, on every platform.
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
`Tmux.safe` refuses a path with characters that cannot survive
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
`ssh` and `kido-pi`. Their source is `share/bin`. The shared helper
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
- `kido-pi` runs the real pi with `--extension
  share/kido/pi/kido-pi.ts` in front of every argument. It writes
  nothing to `~/.pi/agent/extensions`. A bare `pi` is the user's own
  pi, without the harness.

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
  `run-shell`, plugins, `new-window` commands and every spawned
  `kido-pi`.
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

**Install layout.** The `install` stanza in `share/dune` is the only
layout definition for `share/kido`. It mirrors repository `share/`,
beside `bin/kido`:

- `bin/`;
- `shim.sh`;
- `bash/`;
- `zsh/`;
- the pi extension `pi/kido-pi.ts`, without tests, testdata or package
  files.

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

- `KIDO_LINGER_SECONDS`, the sweep's grace;
- `KIDO_STOP_ESCALATION_MS`;
- `KIDO_PARENT_POLL_MS`;
- `KIDO_ASK_POLL_MS`;
- `KIDO_SPAWN_TIMEOUT_MS`;
- `KIDO_AGENT_LIST_TTL_MS`;
- `KIDO_STREAM_POLL_MS`, the extension's output tail;
- `KIDO_STREAM_FLUSH_MS`, `KIDO_STREAM_MAX_WAIT_MS` and
  `KIDO_STREAM_BUDGET_BYTES`, the stream schedule and its per-run
  budget.

The extension reads its variables when it uses them. Its tests set them
in the environment of the process under test.

## Known limits

- A `kido run` without a parent has nobody to collect it while it
  lives. The user must close its window. The sweep still collects its
  dead pane.
- A subagent moved to another session with `move-window` is outside its
  parent's scope and cannot be asked.
- A blocked `ask_agent` holds a whole pi turn, for one turn of the
  target's latency.
- A child that exits before `remain-on-exit` lands loses its window and
  its last screen; only the run record remains.
- Runs are never pruned, and neither is the agent map.
- A `kido ssh` session killed after ssh starts but before remote zsh
  reads `.zshenv` leaves its temporary directory. The exec removes the
  trap before cleanup runs. This leaves one nearly empty directory under
  remote `$TMPDIR`.
- The design assumes one machine. All agents share filesystem access to
  the state directories and the sockets, and each has an adjacent kido
  binary. Remote subagents would reverse discovery and transport. The
  design intentionally does not support them.
