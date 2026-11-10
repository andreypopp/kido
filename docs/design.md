# Kido's agent features, as built

This document describes how Kido's agent features work and the reasons
for their design: the pi harness, messages, addressing, spawning,
the window lifecycle and the sidebar tree. [design-ko.md](design-ko.md)
describes the server that holds them, [protocol.md](protocol.md) its
protocol, and [design-program-status.md](design-program-status.md)
the status of a pane. Its companion,
[design-subagents.md](design-subagents.md), follows one subagent from
spawn to sweep. `AGENTS.md` describes constraints that Kido cannot
change and problems that an apparently correct change can cause. This
document does not repeat them.

Kido has two parts. The `ko` server and CLI manage windows, the panes
in them, their status, and the messages between panes. A subagent is
a pane with a `parent`; an agent's background command is a job of its
harness, not a pane.

The **harness** is everything that only an agent has: the pi session,
the tools, the task, the report and the names. It is one pi
extension, `share/pi/ko-pi.ts`, which the `ko-pi` shim loads. The two
parts talk only through `ko api` on ko's routes and streams, and
the `@kido/webview` SDK (`ko webview serve`, `enter` and `leave`) for
the harness's page. ko never
reads the
harness's files, and the harness reads no ko file. **ko is the
mediator**: every exchange between two agents goes through ko, so the
harness never reads another agent's files and never connects to
another agent's socket.

## Who is authoritative for what

Three stores each hold information that no other store can hold:

**The layout document, for topology.** The server supplies these
facts (protocol.md, section 7):

- the window and session that contain each pane;
- each pane's immutable `parent` and `close`;
- the pane's foreground command;
- which clients show a pane and which has focus;
- whether the pane's process has exited, and how;
- whether the pane's message stream is open (the row's `inbox`).

Nothing caches these facts. A pane can move between windows and
sessions while its process runs.

**Pane variables, for the facts only an agent has.** The extension owns
three pane variables, written with `ko api` (protocol.md, section 7):

| variable | value | ko reads it for |
|---|---|---|
| `pi.session` | the pi session id | `PiAgent`, the status identity, a message's `from` |
| `pi.name` | the session name | the row title of a local pi, a message's `from` |
| `pi.activity` | the agent's activity text, one line | the caption fallback |

A routed pi (design-runtimes.md, "Agents in a runtime") also writes
`pi.runtime`, its runtime and the directory there, which only the
harness reads, under the same trust rule, and the generic
`ko.runtime`, the name of the runtime where the pane's program sends
its work, which any program may set for clients.

ko trusts them only while the pane has an OSC 7501 root with `app=pi`,
as it trusts `ssh.dest` only while the foreground is `ssh`. The
server drops the records on pane death, a shell prompt (non-final
records) and RIS, so a crashed pi's variables are stale but not
believed. A spawner also sets `ko-pi.task` on a new pane; the child
deletes it after it delivers the task, and ko never reads it.

**The pi session, for what a harness knows.** A harness keeps its
registry of children, their work marks and their reports as custom
entries in its own pi session (design-subagents.md, "The registry").
ko keeps no record of an agent after its pane goes.

Only OSC 7501 root records supply status. OSC 0/2 supplies the pane
title. design-program-status.md, "Pane kinds", gives the
classification. Prompt
scope accepts both agent kinds: a pane with an open message stream
gets a message, any other agent a paste.

There is no locking, because every writer is the server's loop thread.

## The pi extension, ko-pi

`share/ko/bin/ko-pi` starts pi with `--extension <share>/pi/ko-pi.ts`
in front of every argument and `PI_IMAGE_PROTOCOL=kitty` unless the
variable is set. A bare `pi` in a pane is plain pi: it reports OSC
7501 status and has no harness.

After interactive terminal feature detection, pi natively emits OSC
7501 root records with `app=pi`. Its lifecycle supplies working,
blocked, done, idle and error. pi reports blocked for its own
dialogs and for an extension dialog that declares itself blocked.
`PI_PROGRAM_STATUS=0` disables reporting, and `=1` forces it. OSC 0
sets the pane title to "π - <session name> - <cwd basename>". The
caption omits a local pi message that duplicates its session name.

The extension uses only these interfaces of ko:

- `ko api`: `GET /layout` and `GET /version`; `POST /panes` for a
  child and a top-level agent; `POST /panes/pane_N/messages` and
  `POST /panes/pane_N/stop`; `GET /panes/pane_N/screen?history=all`;
  `PUT` and `DELETE` on `/panes/$KO_PANE/vars`; `POST
  /panes/$KO_PANE/status` for its job rows (design-subagents.md, "A
  job's row").
- `ko api --stream` for its own message stream,
  `/panes/$KO_PANE/messages` (protocol.md, section 7), and, in a
  top-level host pi, `/client` for its peers (design-subagents.md,
  "Peers").
- In a routed pi, `GET /runtimes/NAME` and `ko api --stream
  /runtimes/NAME/exec` for its tools and its jobs
  (design-runtimes.md, "Agents in a runtime").

`async_bash` and a moved `bash` call are jobs, child processes of pi (design-subagents.md, "A
job").

It never opens ko's socket itself and never reads ko's state
directory. It has no state directory of its own: its registry is in
its pi session.

**Inside ko** is `$KO_SOCKET` set and `ko` on PATH. Its pane is
`$KO_PANE`. A pi outside ko, a pi without a UI or a pi without a
session id writes no variable and opens no message stream. A headless
`pi --print` has its own session id, so it cannot act as the agent of
the pane that it runs in.

**The variables.** The extension writes `pi.session` and `pi.name` at
`session_start`, after it opens its message stream, and `pi.name`
again on `session_info_changed`. It writes no `pi.activity` value,
but ko reads that variable and the extension deletes it with the
others. Without `$KO_PANE`, nothing is written. A routed pi writes
`pi.runtime` and `ko.runtime` too. At shutdown it
deletes them all with one conditional `DELETE` whose condition is
`pi.session` equal to its own session, so it never removes another
pi's variables: the pane can have a new owner before the old one
cleans up. An uncaught crash exits through `process.exit`, so a
synchronous `exit` handler sends the same delete. The handler stays
across `/reload` until the next `session_start` replaces it. Only a
process that ends without cleanup, such as with SIGKILL, leaves them;
the trust rule makes them harmless for identity.

**The trust rule.** The extension's own discovery uses ko's rule
through the row's status: a pane is a pi agent only when its kind is
a `pi_agent`, on the host or in a runtime, and the agent's id is that
kind's `session`. Discovery and addressing apply it. `pi.runtime`
places only a host pi agent; a runtime pane's row `runtime` and `cwd`
win. A stale variable on a
shell pane is no agent. Liveness of a known session is the exception,
because pi clears its root while it runs: pi-tui's `stop()` writes a
`clear` record while pi opens the external editor and while Ctrl+Z
suspends it. The parent watch finds a parent alive while its pane is
not dead and holds the parent's `pi.session`, with or without a pi
root, and a resume refuses a session that a live pane holds in
`pi.session` for the same reason. Thus, an agent in its external editor or suspended is not
listed and cannot be addressed by name, but its children stay. A
suspended pi reads its message stream only after `fg`.

**Project trust.** The extension handles pi's `project_trust` event,
which pi sends to `--extension` extensions before it reads its trust
store. It answers `yes` when the real path of pi's directory is the
real path of `KO_AGENT_TRUSTED_CWD`, which a spawner passes only for a
directory that it trusts. It never saves the answer
(design-subagents.md, "What a child is given").

**The ko skill.** Inside ko, the extension answers pi's
`resources_discover` with the `skills` directory beside its own file,
which holds the skill `ko` (`share/pi/skills/ko/SKILL.md`, installed
as `share/ko/pi/skills/ko/SKILL.md`). pi puts only the skill's name,
description and path in the system prompt, and the model reads the
file when a task needs it. Inside ko, `before_agent_start`
also adds one guideline: the user runs ko, and the model reads the
skill when the user talks about windows, tabs, panes, sessions,
splits, floats or the sidebar. A routed pi gets neither: its `read`
and `bash` run in the runtime, where the skill's host path does not
exist and `ko` does not reach the user's server. The skill is text
only: it adds no tool and no route. `make preview-pi` previews the
skill directory with `ko-pi.ts`.

**One copy.** On its first factory call, the extension claims
`globalThis.__koPiExtensionCopy` with its path. A copy at another path
registers nothing, because pi dedupes extensions by real path only.

**Subprocesses.** The extension starts every ko process with
asynchronous `spawn`, never `execFileSync`, except the synchronous
cleanup at `exit`. A blocking call stops the whole process while ko
runs, and the message stream's acks wait. A failed command returns
its stderr line, which the model can act on. A timeout reads as a
timeout, because ko can already have completed its work.

## Identity

**An agent is its pane.** Every pane gets `KO_PANE_TOKEN`, and every
process inside a pane inherits it, so the server knows the pane that
a request acts as (protocol.md, section 1). The pane's `parent` edges
give every relation, and the server stamps each message with its
sender and the relation.

**The pi session id names the agent.** `pi.session` publishes it, and
the registry names children by it. A pid is not an identity, because
the OS reuses pids. The parent mints the child's pi session id and
passes it with `--session-id`; a restart is the same id in a new
pane, and the registry entry records the pane of each start with the
server's `instance`, because pane ids restart at `pane_1` in a new
server.

**The parent edge.** The child trusts its edge only when
`KO_AGENT_SESSION` equals its own pi session id. Every process that an
agent starts inherits its environment: a human's `pi` in that pane, or
a tool calling `pi --print`. A nested pi mints its own session id, so
it has no edge. `KO_AGENT_PARENT_SESSION` names the parent's session;
the parent's pane is the own row's `parent`. The repo's
`no-git-writes` guard also reads `KO_AGENT_PARENT_SESSION`.

**Children belong to the session that spawned them.** A parent that
restarts under its own session id finds its children again in its
own session's registry. `/new`, `/resume` and `/fork` move a pi
process to a new session id. A child still names the old id, and its
parent watch ends it. Transferring the parent edge would send a
child's report to a session that nobody reads.

**Two pis in one pane** cannot both receive: a pane has at most one
message stream, and the server refuses a second upgrade (protocol.md,
section 7). The second pi's receiver retries with its backoff and
receives nothing while the first lives.

## Messages

Every message between agents, and `ko prompt`'s text, goes through
ko: `POST /panes/pane_N/messages` enqueues it on the target pane, and
the pane receives it on its one message stream (protocol.md, section
7, "Messages"). The server does not read a message's kind or text; the
kinds are the harness's vocabulary:

| kind | the receiving extension |
|---|---|
| `user` | `sendUserMessage` as the user's own text (`ko prompt`) |
| `message` | a custom message with the sender header, `followUp`; `details.work` when the sender is the parent |
| `steer` | a `ko-steer` custom message, `steer`; `details.work` when from the parent |
| `interrupt` | holds the text, marks the turn ended by a control, calls `abort()`; delivers the text at the settle as a `message` |
| `stop` | `shutdown()` through the one teardown, after the ack |
| `notice` | a `ko-notice` custom message, `steer`; a child's report when `data.report` is set |
| `ended` | server-made: the ending of a child (design-subagents.md, "Endings") |

The extension takes the message's shape from `ko-api.d.ts`; a line
without that shape is refused, not delivered.

**The receiver.** The extension runs `ko api --stream
/panes/$KO_PANE/messages`: the command prints each message as one
line and sends each line of its stdin as one text message. For each
message, the extension answers `{ type: "ack", id }` after it has
handed the message to pi, or `{ type: "refuse", id }` when that
throws. The stream process restarts with a backoff (from
`KO_RECEIVER_BACKOFF_MS`, 200 ms, doubling up to 5 s) when it exits.
The extension keeps the ids of the last 4096 messages that it acked
in a ring; a repeat of one is acked and not delivered. The server
delivers each id once, but a stream that closes with unanswered
messages gives them again to the next stream, so the ring makes that
repeat safe.

**A `/reload` does not take the stream down.** A reload keeps the
process and the session id. For reason `"reload"`, `session_shutdown`
parks the stream process on `globalThis.__koPiExtensionReceiver`,
detached from the old module; messages wait in its pipe. The
reloaded module's `session_start` adopts it. The ring of received ids
is on `globalThis` too. Every other reason kills the process, and the
server's queue keeps what arrives until the next stream.

A reload also keeps the pane variables, because the session
continues: deleting them would make the parent look gone during the
gap. The jobs survive in their registry on `globalThis`
(design-subagents.md, "Jobs across /reload").

**The sender header.** A `message` from another agent reaches the
model as a custom message with one header line that names the sender
and the relation that the server stamped:
`message from @<name> (your parent, who spawned you):`,
`(your subagent):`, `(another agent in this session, not the user):`
for a sibling, and a description for a descendant or a sibling's
descendant. A child's only user is its parent, so a parent's
instruction has that authority. Only kind `user` is the user's own
text, without a header.

### Steer and followUp

The extension uses `followUp` to queue work and `steer` to interleave
work. The rule, one line:

> Steer what is safe to interleave. Queue what waits for the turn to end.

- **`message` queues.** It has no authority over the receiver's work.
- **`steer` steers.** The agent that assigned the work sends a
  correction. It has no value after that work ends.
- **`interrupt` queues after the abort.** The receiver aborts the
  turn first, so nothing remains to steer into.
- **`notice` steers.** The parent needs this information to assign the
  next work.
- **A stream batch steers.** It is not a message: the harness reads
  the job's pipes itself (design-subagents.md, "Streaming a job's
  output").

Escape and the dequeue key restore only queued user text to the
editor. Custom messages remain in their steering and follow-up queues,
in order. The extension wraps `AgentSession.clearQueue` to preserve
them while pi clears editor queues. `globalThis` holds the original
method, so `/reload` replaces the wrapper instead of adding another.

### Waking an idle session

The extension sends each arrival with
`sendMessage(..., { deliverAs, triggerTurn: true })`. While a run is
active, pi queues the message in that mode. While the session is idle,
pi starts a run with the custom message as its first message. pi
starts this run with the same setup as a prompt: `before_agent_start`
runs with `messageType: "custom"`, and the extension's handler adds
its prompt guidelines.

**One run at a time.** pi counts the session as busy from the start of
the run, also while `before_agent_start` handlers run. A second
arrival during that time goes into the starting run's queue in its own
mode.

## Delivery, and when a paste is allowed

`ko prompt` reads its text from stdin and sends it to the server with
its pane identity, its pane as `from` and an id that it mints; the
server resolves the scope and delivers (protocol.md, section 11). A
pane whose message stream is open gets the text as a message of kind
`user`. When the connection fails after the request may have been
sent, the CLI resends once with the same id to a candidate whose
stream was open: the server delivers each id once, so the resend
learns the truth and never delivers twice. A paste has no id, so it is
never repeated.

A paste and a separate Enter key go only to a candidate without an
open message stream: Claude Code has no stream and is reachable only
through a paste, and so is a pi without the harness or a pi whose
stream is down.

The extension never pastes. A target without an open stream gets
the message queued: the server keeps it until the target's stream
returns, and the tool says so. Model-authored text must not run as a
command line in the target's pane. The extension refuses four sends
before sending: a message to the caller itself, an empty message,
text that is not valid UTF-8 and text over `MAX_MESSAGE_BYTES`
(1 MB).

## Addressing

The tools that take an agent (`message_agent`, `stop_agent`,
`read_report`) resolve it over the caller's scope, the set that
`list_agents` and the `@` completion show (design-subagents.md, "The
tools, and what they call"); `read_report` over the caller's own
children only. The server enforces the same scope on every send and
stop.

The tools show names, not ids, and still accept a session id or a
unique id prefix: two top-level pis may share a name. Within scope, a
target resolves by these rules in order:

1. An exact case-insensitive name.
2. An exact session id or pane id.
3. A unique prefix of a session id, of at least eight
   characters. A shorter prefix that matches an id is refused for its
   length.

Each rule prefers a live agent over an ended child or peer and reports its own
ambiguity. A target in another ko session is reported as such, not as
"not found". Unnamed pi sessions match only by id. Native-only panes
have no addressable session.

Every tool that takes an agent removes one leading `@`. It also
accepts a whole mention from the prompt: `@reviewer (session
01a0bfcf)` resolves by the id in the parentheses only, so another
agent's name cannot capture it.

In pi's prompt editor, `@` and a prefix complete the agent rows of
`list_agents`: the live ones, and the ended peers that it lists, so a
stopped peer can be mentioned and messaged back to life. Completion
excludes ended children. For the same match, a live agent comes before
an ended peer. Each row shows the name, status, activity and a
subagent's parent; an ended peer shows that it ended. The extension wraps
the completion provider to place agent matches first, and delegates
tokens with no agent match. Completion inserts `@reviewer (session
01a0bfcf)`, where the id is the shortest prefix, of at least eight
characters, that no other row's id starts with. A keystroke uses the
last list without waiting for discovery. If the list is older than
`KO_AGENT_LIST_TTL_MS` (1 s), a background refresh starts.

## Spawning

`spawn_agent` starts a child or a top-level agent with one `POST
/panes` (design-subagents.md, "What a child is given" and "A
top-level agent"). The window goes after the parent pane's window,
else after the caller's window; no client switches to it. The pi in it runs under `ko shell --` ("The
login environment", below). The request carries the cwd and each
environment variable, because a new pane gets the server's
environment, not the caller's.

The task is never a command-line argument. A model writes text of any
form, and pi's parser reads an argument that starts with `@` as a
file, even after `--`. The task is the pane variable `ko-pi.task`,
which the child reads at `session_start` and then deletes; a
restart's message goes there too.

The model also writes the window name. The server refuses a name over
64 bytes or with a control character, instead of silently changing
it. The name never reaches a shell: the server starts the argv
directly. The extension also refuses an empty name, `.`, `..` and a
name with `/`.

### The login environment

The server starts a pane's argv directly, with only the server's
environment and the request's. A pi that the user starts in a pane
runs under `ko shell`, which read the user's dotfiles: EDITOR, PATH
additions, API keys, LANG. So that every agent gets the same
environment, the extension starts each pi, child or top-level, new or
restarted, as `<its ko path> shell -- ko-pi ...` (or `-- koa ...`
under `--harness`, design-subagents.md). A job runs its
command through pi's shell configuration, as pi's `bash` does,
because its command is not an agent.

`ko shell -- CMD...` resolves the shell as the bare `ko shell` does
("Priming a local shell"). For bash, zsh, sh, dash and ksh it execs
`SHELL -l -i -c SCRIPT SHELL CMD...`. SCRIPT puts ko's bin directory
first on PATH again, as a primed pane does after the login files, then
runs `exec "$@"`. It names only ko's own directory, and the argv
passes as positional parameters, so no shell parses model text. The
shell is interactive, because EDITOR often lives in `.zshrc`. The
shell integration is not installed, and no prompt runs before the
exec, so the pane gets no OSC 133 marks from ko, and pi's OSC 7501
root classifies it. Because the shell execs, pi keeps the pane's
process: the pane's death is pi's. If the exec fails, the shell exits
127 (126 for permission). Another shell, such as fish, has no `"$@"`
semantics: ko execs CMD directly, and the user's dotfiles do not run.

### Failure leaves no pane

A `POST /panes` that cannot start its pane keeps the old document and
answers `io`.

## Window lifecycle

A child's window is a pane that `POST /panes` creates with the
spawner's pane as `parent` and `close: on_exit`. ko has no other
lifecycle object: a pane's row is the whole record, and ko keeps
nothing after the pane goes.

**The pane stop.** `POST /panes/pane_N/stop` (protocol.md, section 7)
waits up to its `wait` for the pane to die and removes it. The
removal hangs up the program: `ko-pane` sends `SIGHUP`, then
`SIGKILL` 250 ms later; if the removed pane still lives after
`KO_STOP_ESCALATION_MS`, the coordinator kills it.

A dead pane keeps its last screen until the sweep removes it. Thus,
an immediately failing child keeps its pane and its last screen for
the parent's ending notice.

**The sweep** (`ko_server/src/state/sweep.rs`). The server sweeps
when one of its inputs changes: a pane's death or removal, the
focused panes, and the end of a linger grace (protocol.md, section
10). It reads only the pane rows, so it acts on any pane by its
`close` and `parent`. Three rules apply:

1. A pane with `close: exit`, the default, has died by an exit or a
   signal. The sweep removes it at once, also while a focused client
   shows it: a shell that ends with Ctrl-D closes its pane, as in a
   terminal. An exec or `cwd` failure of `ko-pane` (the cause
   `failed`) keeps its dead pane, so the user reads the error on its
   screen. ko's own wrappers (`ko shell`, `ko enter`, `ko
   runtime-exec`) that fail before the user's program runs, for
   example when a runtime does not come up, first set their own
   pane's `close` to `keep` with `PATCH /panes/{id}` (protocol.md,
   section 7), then print the error and exit 1: a normal exit that
   the sweep does not remove. A shell's Ctrl-D returns the status of
   its last command, so the exit code does not select the rule.
2. A pane with `close: on_exit` has been dead for the linger grace
   (`server: linger_seconds` of the configuration file, 30 s by
   default; design-ko.md, "The configuration file"). The sweep
   removes it.
3. A pane's `parent` is gone or dead. The sweep removes the pane at
   once, live or dead, also while a focused client shows it: a child
   shows in its parent's slot, so when the dead parent lingers, the
   removal shows its last screen in its place. The rule reads no process and no pi evidence,
   by design: a child of a pi that quits inside a living shell pane
   ends through its own parent watch, not the sweep.

Rule 3 forces a stop instead of requesting graceful shutdown like the
child's poll. It is the only available action outside the child, and
it ends a `tail -f` that an exited parent started. A pane without a
parent is a root that the sweep must not cancel.

The sweep never collects an `on_exit` pane for its linger grace while
a client with terminal focus shows it (protocol.md, section 3); it
tries again when the focus changes.
Waiting loses nothing. It does not protect a session's last window: an
empty session ends.

**A removal takes the subtree.** The collection unit is the pane,
not its window. The sweep removes the pane with a pane delete, which,
as every delete, also removes the pane's descendants through their
`parent` links, focused or not, in the same change; a window that
loses its last pane goes with it, and an empty session with it
(protocol.md, section 7). The server owns this cascade, so a close in
Kido.app, a `ko api` delete and the sweep remove the same panes, and
no client sends a delete for each descendant. The focus guard above
only defers the sweep's choice of a pane; it does not keep a
descendant of a pane that is removed. The pane stop and its
escalation do the same.

**The selection after a removal.** When the child's window goes with
the child, its client moves to the child's nearest surviving
ancestor pane, because the user came from there (protocol.md, section
3). The death of an `on_exit` or `keep` pane alone moves no client,
so the last screen stays readable for the linger grace. The removal
of an `exit` pane moves its clients by the same repair rules.

No other guard applies: no debounce. Without grace under rule 3, a
child already shutting down can lose its pane during exit.

**Parent death.** The child's pi belongs to the server, not the
parent's pi process. Thus, no OS parent-death signal reaches it. Its
extension watches the parent's pane (design-subagents.md, "A child's
life", "Watching the parent"). A failed read supplies no evidence and never causes shutdown.
If the parent is gone, the child calls pi's `shutdown`. The sweep's
rule 3 covers a child whose parent pane is gone or dead, pi or not.

## Ending a child, and restarting it

A child has no idle timer. After it reports, or after a turn settles
with nothing to do, it keeps its window, pi process and model context.
Only these end it: its parent or another agent of its scope, with
`stop_agent`; the user, who quits or kills the window; the orphan
rule, after its parent ends.

The parent decides, because only the parent knows whether it needs
more work. The child's report is not an ending. The report notice that
a parent receives says so: end the child with `stop_agent` when
nothing more is needed, or continue it with `message_agent`.

**An ended child restarts on a message.** `message_agent` to an ended
own child starts it again in a new pane under the same pi session,
with `ko-pi --session-id <id>` and the message as its task. A reused
name means "message it". design-subagents.md, "Restarting through a
message", gives the rules. An ended peer that a top-level pi
recorded restarts the same way, as a top-level agent
(design-subagents.md, "Peers"). `spawn_agent` with `resume_from` continues
any saved session that no pane holds.

## Steer, interrupt and stop

These three verbs differ, in increasing order of force. `message_agent`
in `steer` mode adds text to a running turn inside the loop ("Steer
and followUp"). `interrupt-and-steer` mode aborts the current turn and
then starts a new turn with the text. An interrupt always carries the
next instruction, so a child is never left idle with work it did not
finish and no report owed. Interrupt has no escalation: a target that
cannot receive it cannot abort a turn, and no destructive fallback fits
"redirect this, do not kill it". `stop` ends the session through the
normal exit's shutdown path.

**Scope.** All three reach every agent of the caller's scope: its
children, its siblings, and each ancestor with that ancestor's
siblings (protocol.md, section 7). The server checks the scope on
every send and stop, from the `parent` edges of the rows; the
receiver does not check again. A child that stops an ancestor ends
with it through the orphan rule.

**Escalation.** `stop_agent` sends the `stop` message to a target
whose message stream is open, then sends `POST /panes/pane_N/stop`
with `wait_ms: 5000` whatever the message returned: a healthy agent
ends itself within the wait, and the stop removes the pane of one that
does not. The removal hangs up the program, and the coordinator kills
a pane that lives past `KO_STOP_ESCALATION_MS` ("Window lifecycle").
The extension's deadline for the stop call is a constant, 11.5 s,
above the wait and the server's default escalation, so that the kill
and the removal run before the call times out. `force` sends
`wait_ms: 0`.

Stop removes the target's pane, not its window. The request names one
agent; a window removal would also kill unrelated panes. Stop does not
refuse a focused pane. This differs from the sweep, which acts
automatically and must protect a screen that the user can be reading.

**No stream means no quiet stop.** A target without an open message
stream cannot receive a request. The server would queue the `stop` for
a stream that may never return, so `stop_agent` refuses unless
`force`, which removes the pane at once. This is destructive and
irreversible.

## Notifying the parent

Notification is automatic. When a subagent's turn settles idle after
work from its parent, and it waits on nothing of its own, the harness
sends the last assistant message of that run to the parent as a
`notice` with `data.report` (design-subagents.md, "A child's life",
Reporting). An explicit tool would make each report depend on the
model calling it at the right moment.

The parent's model receives at most 4000 bytes, the guidance
included, because the whole notice enters its context; the parent
keeps the whole report in its session for `read_report`.

**What this costs, and what covers it.** A crashed subagent that never
settles a turn supplies no work report. ko does not invent one.
Instead, the server's `ended` message tells the parent how the pane
ended. A child that the parent stops itself with `stop_agent` sends
no ending notice: the tool result is the only signal.

**Telling a child this is its job.** `before_agent_start` appends a
standing instruction to the subagent's system prompt on every turn, if
it has a parent edge, because a `/reload`, a restart or a later parent
message can start work without the task's one-time first message.

**The rendered side.** An inbound `notice` uses a custom message that
can collapse to "@X notifies: <first line>...". The model receives the
full text with one header: `notice from <from> (a subagent or
background run's report, not the user):`. As soon as the message
arrives, a dimmed widget line shows it; when the message reaches the
transcript, the permanent collapsed row appears and the widget entry
goes. The text goes to `sendMessage` exactly once.

Notices use `"steer"`, not `"followUp"`: a long parent turn would
otherwise delay the report until that turn ends. The extension sends a
steer, not an abort. The model decides whether to act now or continue.

## The sidebar tree

Both clients build the tree from the layout document and the pane
rows (`ko_client/src/model.rs`, with the walk of
`ko_client/src/tree.rs`). A subagent's panes follow the pane that
spawned it, one level deeper, not after the whole parent window: the
subagents belong to the coordinating agent, not a shell sharing its
window. The edge is the row's immutable `parent`, which the server
sets at create: a child's pane gets its spawner's pane. A pane with a
`parent` is alone in its window, which the server enforces for every
client (protocol.md, section 7), so a child window is one pane and
nests under the pane that its `parent` names. A parent that is absent
or in another session leaves the window a root of its session's tree,
but its pane is still a child: it stays alone in its window, and a
removal of its parent still takes it.

A **top-level window** is one whose pane has no parent pane in the
same session; every other window is a child window of the pane that
its pane's `parent` names. The server's window switch (protocol.md,
section 3) steps over top-level windows only: from a child window it
steps from the child's top-level ancestor, so Next and Previous Window
never enter child windows, in the terminal client and in Kido.app
alike. The tree and the chooser reach the children.

The terminal client draws the list as session headers and pane rows,
indented by depth (`ko_tui/src/sidebar.rs`); its chooser (`C-a s`)
visits every row in that order. Kido.app draws its tree with
indentation and folded children (design-app.md, "Sidebar").

Below the tree, pinned to the bottom of the sidebar, both clients
list the runtimes of the configuration and of the current session
(design-runtimes.md, "Clients"). In the terminal client they are the
last rows of the column, after one empty row, and they are read-only: a faint header with the count of up
runtimes, then each name with its state at the right, a failed state
in red. They have no colour, actions or selection, so the client stays
a mirror; `ko api` is its start and stop. It does not show the
configuration error. The tree does not scroll, so the rows appear only
when the whole tree fits above them; a longer tree takes the column,
and the chooser never selects a row that the footer hides.

The walk uses parent-first ordering and emits every item exactly once,
with or without a tree. Parent edges across windows can create a
cycle; the walk emits missed items afterward as roots, so an invalid
edge loses only the item's tree position. A self-edge means "no
parent". Siblings retain arrival order.

## Priming a remote shell

An `ssh` pane reports remote activity only from remote reports. The
pane's terminal parses OSC 133 from the output without knowing the
markers crossed a network. The status model latches the pane after a
remote prompt marker later than the local ssh-start marker. The remote
shell must source `share/ko/zsh/integration.zsh` or
`share/ko/bash/integration.bash`. Both emit the same markers.

On a host without an installed integration, the marked pane remains
running throughout the connection. `ko ssh` sets `ssh.dest` on its
pane to the destination as typed, then execs ssh. The mark remains
after ssh exits; ko trusts it only while the foreground command is
`ssh` (design-program-status.md, "The ssh mark").

**What is sent.** The binary embeds the integrations
(`ko_shell/src/prime.rs`, with `include_str!`). ko base64-encodes them
in a POSIX sh bootstrap and sends this as ssh's remote command. Every
connection carries both integrations, regardless of the remote login
shell. It also carries ko's compiled `xterm-ghostty` entry, which ko
reads at run time from the terminfo of the installed layout
(`ko_shell/src/bin_dir.rs`); a missing entry ships nothing. stdin
remains available for the interactive session.

**The terminfo.** A pane's `TERM` is `xterm-ghostty`, and ssh passes
it on, so a host without the entry gives full-screen programs an
unknown terminal. Before it selects a branch, the bootstrap asks
`infocmp xterm-ghostty`. When the host resolves the entry, it does
nothing. Otherwise (a missing `infocmp` counts as a missing entry,
because a probe of the system directories would only guess at the
host's ncurses), it decodes the entry into `~/.terminfo` in both
directory forms, `x/` (ncurses on Linux) and `78/` (macOS), because
the host's form is unknown and the file is the same. It never
overwrites an existing file there: each write goes to a temporary file
in the target directory and moves with `mv -n`, so a concurrent
connection or a user's own entry wins. No `tic` runs on the host. The
install succeeds when `infocmp` then resolves the entry, or, without
`infocmp`, when both files exist. Otherwise (a read-only home, no
space, no payload, an unusable existing file) the session gets
`TERM=xterm-256color` and starts as before.

**What that costs, said plainly.** The payload is a public shell
script without secrets, so ko permits it in argv. All sidebar
information about the pane comes from the remote host's report. A host
can report any claim about what it runs.

**The ZDOTDIR swap.** The bootstrap creates a fresh directory with
`mktemp -d` and decodes the integration there. It writes `.zshenv`
beside the integration, sets `ZDOTDIR` to that directory and execs the
login shell. The generated `.zshenv` restores `ZDOTDIR`:
`KO_ORIG_ZDOTDIR` carries the user's value when set. Apart from the
terminfo entry, the bootstrap writes nothing in remote `$HOME`. The
swap occurs only if the user already has zsh dotfiles.

**The bash branch.** The bootstrap sets `ENV` to a file beside the
decoded integration and execs the login shell with `--login --posix`.
That file disables posix mode again, sources `/etc/profile`, then the
first of `~/.bash_profile`, `~/.bash_login` or `~/.profile`, then the
integration, and removes the directory. Before priming bash, the
bootstrap asks the login shell for its version once; an answer below
4.4, or no version, starts the login shell plain. Older bash reads its
login files without markers, through the same route as an unsupported
shell.

**Nothing persists but the terminfo.** ko resends the payload on every
connection, and only the terminfo entry stays on the host, except for
the zsh completion directory of a shell that ends without `zshexit`. `.zshenv`
reads the integration into a parameter and keeps the directory for
`_ko` ("Completion" below). At its first `precmd` zsh loads `_ko`,
deletes `.zshenv` and the integration file, then sources the integration,
not in `.zshenv`, so ko's hooks come after the user's setup and ko's
bin directory is again first on PATH as the last step.

**Degrade, never break.** `ko ssh host` must not behave worse than
`ssh host`. ko passes the command line unchanged, without `-t` or a
remote command, unless all priming conditions apply: a destination, no
user-supplied remote command, a local tty, and none of the
no-login-shell options `-N`, `-T`, `-W`, `-f`, `-n`, `-s`, `-O`, `-Q`,
`-V`, `-G`. For priming, ko adds `-t`. Every remote failure (an
unsupported shell, a missing `mktemp` or `base64`, a decoding failure)
starts the same login shell without priming; a failed terminfo install
only changes `TERM`. ko execs ssh, so signals, exit status and tty
behave as with ssh alone. The bootstrap selects
its branch by the remote login shell's basename.

ko intentionally does not implement a remote ko binary, ControlMaster
sharing, askpass or fish. `ko HOST`, the remote attach, is a different
thing (design-ko.md, "Remote").

## Priming a local shell

`ko shell` is the default pane command. It resolves the user's shell
in this order, checking each candidate for executability: `$KO_SHELL`
(the server's shell: `server: shell` of the configuration file, else
its own `$SHELL`), `$SHELL`, the shell of the user's account
(`ko_sys::user::login_shell`, `getpwuid_r`), `/bin/sh`. Inside a
runtime (`$KO_RUNTIME` set) it skips `$KO_SHELL`, because that is the
host server's shell: a container's environment often has no `$SHELL`,
and the account's shell (root's `/bin/bash` in Debian) is primed where
`/bin/sh` is not. A command that is one word whose basename is `bash`
or `zsh` (a bare name found on PATH) is that interactive shell, with
the same priming. It runs a login shell
with the same priming as `ko ssh`:

- zsh with any of `.zshrc`, `.zshenv`, `.zprofile` or `.zlogin` in
  `$ZDOTDIR` else `$HOME` uses a temporary `ZDOTDIR` (`ko-shell.XXXXXX`,
  mode 0700). Its files source the user's real files, then the
  integration.
- bash 4.4 or newer uses `ENV` with `--login --posix`.
- Other shells use plain mode: no files, a dashed argv[0].

`ko_shell/src/prime.rs` supplies one implementation for mode selection,
temporary-directory contents, argv tail and minimum bash version.
Transport differs: the remote side has only sh, so these parts
generate a POSIX ssh bootstrap. A failure to write the files falls
back to plain mode. `ko shell -- CMD...` with any other command runs
it in the same shell, without priming ("The login environment").

The bash integration uses `PS0` for command-start markers and
`PROMPT_COMMAND` for prompt markers. Sourcing it a second time causes
no action. The integrations blank control characters and limit the
command line to 1024 characters. At each prompt, before the prompt
marker, both report the directory as OSC 7, `file://HOST/PATH`, with
the shell's own hostname (`$HOST`, `$HOSTNAME`) and every byte of the
path outside `[A-Za-z0-9/._~-]` percent-encoded, so a split or a new
tab starts there (protocol.md, section 15, "The cwd of a new pane").
The real hostname matters: the same integrations run on the far side
of `ko ssh`, and the server ignores a host pane's report for another
host.

**Completion.** Every primed shell completes `ko` with no change to the user's
dotfiles. The shells ask the `ko` that the pane's PATH resolves (the
bin directory's shim, so Kido.app's bundled ko answers in its panes).
The stubs hold clap_complete's callback themselves and never run the
registration form `COMPLETE=<shell> ko`: a ko without completion
treats that as plain `ko` and starts the terminal client, while the
callback's `ko -- WORDS...` is only a usage error there, which the
stub discards. A clap_complete bump that changes the callback's
variables fails the e2e test that compares them with the generated
script.

- zsh: the temporary `ZDOTDIR` holds `_ko` (`share/ko/zsh/_ko`, with
  `#compdef ko`) in its own `0700` subdirectory `completions`, because
  `compaudit` also checks the parent of each `fpath` entry, and a
  world-writable `/tmp` as that parent makes `compinit` stop at its
  "insecure directories" question. Its `.zshenv` puts that
  subdirectory first on `fpath`
  before it sources the user's `.zshenv`, and again after it, so the
  user's own `compinit` finds `_ko`; ko never runs `compinit`. At the
  first prompt it loads `_ko` into memory, maps `ko` to it with
  `compdef` when `compinit -C` read an older dump without `_ko`, and
  deletes the other two files. The directory with `_ko` stays on
  `fpath` until the main shell's `zshexit` deletes it; the cleanup does
  nothing in a subshell, because zsh also runs `zshexit` when a
  subshell exits with `exit` (`(exit)`, `$(exit)`). So a `compinit`
  that runs after
  the first prompt (a plugin manager's reload, a hook that runs
  `compinit` again when `$FPATH` changed) still finds `_ko`. ko does
  not change `fpath` after `.zshrc`, so such a hook sees no change. A
  shell killed without `zshexit` leaves the directory with `_ko` in the
  temporary directory (`ko-shell.*` locally, `${TMPDIR:-/tmp}/ko-ssh.*`
  on a remote), where the OS clears it; so does an `exec` that replaces
  the shell, because `zshexit` does not run then.
- bash: `share/ko/bash/integration.bash` registers its function with
  the builtin `complete`, so completion works with or without
  bash-completion, also in bash 3.2, which gets no OSC 133 marks. It
  joins the words that bash splits at `=` and `:` before the callback,
  so `--server=DIR` reaches ko as one word.

Over `ko ssh` the same files go to the remote side; where the remote
has no `ko`, Tab completes nothing for `ko`.

## The bin directory

ko ships three `sh` shims in `<prefix>/share/ko/bin`: `ko`, `ssh` and
`ko-pi`. Their source is `share/ko/bin`; the shared helper is
`share/ko/shim.sh`. Inside a pane, those names resolve to these shims:

- `ko` execs `<prefix>/bin/ko` relative to its shim. Pane commands use
  this prefix's binary, not another installation on PATH.
- `ssh` runs `ko ssh "$@"`. `ko ssh` finds the real ssh after the bin
  directory (`look_path_past` in `ko_shell/src/bin_dir.rs`).
- `ko-pi` runs the real pi with `--extension share/ko/pi/ko-pi.ts` in
  front of every argument. It writes nothing to `~/.pi/agent/extensions`.

A shim never embeds an installed path. It calculates every location
from `$0`. For user-installed programs, the shim selects the first
same-name executable on PATH *after* its own directory, or, if its
directory is absent from PATH, the first match that is not itself. The
rule is "after", not "anything but me": a second installation's shim
is a different file, and the latter rule would send the call there and
back.

**PATH.** The bin directory becomes first on PATH in two places: the
server puts it first in every pane's environment (`--bin-dir`, else
`share/ko/bin` beside the installed `ko`), before `ko shell` runs, so
commands without an intervening user shell see it; and every locally
primed shell's integration places it first again at the end, after
login files that can rewrite PATH. The prepend first removes all
existing occurrences, so a nested shell never increases PATH length.
`ko ssh` sends the shipped integrations unchanged; the remote side has
no ko or shims, so nothing changes PATH there.

`of_exe` in `ko_shell/src/bin_dir.rs` tries the unresolved executable
path first and resolves only as a fallback: Homebrew's `bin/ko` and
`share/ko` are symlinks whose targets change on each upgrade, and a
resolved Cellar path would leave every pane's PATH with a nonexistent
target after the next cleanup. A `ko` binary without an adjacent
`share/ko`, such as a checkout build, uses no shims. A plain-mode shell
keeps the shims only if its login files preserve the inherited PATH
order.

**Install layout.** `make build` lays out `build/ko/` as installed:
`bin/ko`, `bin/ko-pane` and `share/ko` with `bin/`, `shim.sh`,
`pi/` (ko-pi, the modules that it shares with koa, `ko-api.d.ts` and
the skills), `koa/`, `webview/` (the SDK) and the terminfo. `make
install` copies it under
`PREFIX`, default `~/.local`. This is Homebrew's `pkgshare` layout.

## Knobs

Every duration that a test must shorten is an environment variable
that the process under test reads when it uses it:

- `KO_STOP_ESCALATION_MS`, `KO_CLIPBOARD_TIMEOUT_MS`, `KO_MESSAGE_ACK_MS` (a message's wait
  for its ack),
  `KO_VIEW_QUEUE_BYTES`, `KO_VIEW_SPILL_BYTES` and
  `KO_RUNTIME_EXEC_WAIT_MS`, read by `ko server`
  (`ko_server/src/config.rs`), beside `KO_RUNTIME_COMMAND_KIND=1`,
  which admits the test-only runtime kind (design-runtimes.md),
  `KO_LOG_BYTES`, the cap of `DIR/log` before its rotation, and
  `KO_DEBUG_INPUT=1`, which adds a line for each input to the log
  (design-ko.md, "Lifecycle and the command line");
- `KO_PARENT_POLL_MS`, `KO_SPAWN_TIMEOUT_MS`, `KO_RESEND_MS` (the
  delay between the resends of one message), `KO_RECEIVER_BACKOFF_MS`
  (the first restart delay of the message stream),
  `KO_AGENT_LIST_TTL_MS`, `KO_STREAM_INTERVAL_MS` (the least time
  between two batches of a streamed job), `KO_JOB_MOVE_MS`
  (when a `bash` call becomes a job), `KO_JOB_HINT_MS` (when the
  ctrl+b hint shows), `KO_JOB_KILL_MS` (a job's `SIGTERM` to
  `SIGKILL`) and `KO_JOB_RECORD_LINGER_MS` (how long a finished job's
  status record stays), read by the extension.

The extension's tests set them in the environment of the process under
test. The e2e suite sets the server's through its environment. The
linger grace and the runtime idle are not knobs but `server:` keys of
the configuration file (design-ko.md, "The configuration file"), which
the server reads at each use, so a test writes them into its server's
file.

## Known limits

- A job of a pi that ends with `SIGKILL`, as a pane's hangup does
  250 ms after its `SIGHUP`, is an orphan in its own process group:
  pi's exit handlers do not run (design-subagents.md, "Stopping a
  job"). The user accepted this limit on 2026-11-05. A pi child ends
  through its own parent watch when the parent's session id goes
  (design-subagents.md, "Watching the parent").
- A subagent whose window moved to another session is outside its
  parent's scope and cannot be messaged.
- pi asks its startup project trust question before it reports OSC
  7501 status. A pi that ko did not spawn into a trusted repository
  shows no blocked status while it waits for the answer.
- A `ko ssh` session killed after ssh starts but before remote zsh
  reads `.zshenv` leaves its temporary directory under remote
  `$TMPDIR`.
- The harness reaches ko only through `ko` and `KO_SOCKET`, so it
  needs no filesystem in common with another agent, except that
  `resume_from` reads the saved sessions of the caller's own
  filesystem. A remote attach shows a remote server's agents; it does
  not make them peers of local ones.

## Decisions

Each decision names its date. The code states the rest.

2026-11-05, jobs in place of async runs:

- `async_bash` is a job of the harness, a child process of pi with
  pipes and a temp log, not a ko run in a pane. The user never
  watches an agent's command, so it gets no window and no sidebar
  row, and a pipe gives the exact exit code, both streams and every
  byte.
- A `bash` call that runs past 60 s, or that the user moves with
  ctrl+b, becomes a job instead of a blocked turn. An explicit
  timeout under 60 s keeps its meaning; a longer one becomes the
  job's deadline, because the model asked for it.
- One log holds both streams in arrival order, as a `bash` result
  and a terminal show them. It has no size cap, because a cap cuts
  the end, and it is never deleted, as pi's own temp output is not.
- `async_bash` runs through pi's shell configuration, so the two
  tools run a command the same way.
- Jobs survive `/reload` through one process-wide registry, because
  pi reloads an extension in the same process, its children live on,
  and only the new instance can call pi.
- A routed pi's jobs are exec sessions of its runtime, in the same
  registry.
- ko-pi signals only its own process groups, through one function,
  and a pi killed with `SIGKILL` can leave an orphan job: pi's own
  detached `bash` commands already have that limit.
- Runs leave ko with `async_bash`: the run commands, the `/runs`
  routes, the run records, outcomes and screen captures, and the pane
  output stream. After the jobs, only tests, demos and one tool script
  started a run, and a pane with `parent` and `close: on_exit` does
  what they need. The sweep stays, because it acts on pane rows.

2026-11-04, agents without runs:

- ko is the mediator. A subagent is a pane with a `parent`, not a
  run; ko keeps no record of an agent after its pane goes, and a
  harness's own data lives only in its own pi session. Thus, the same
  harness works where `KO_SOCKET` is a runtime's socket and the
  filesystem is not the host's (design-runtimes.md).
- No new CLI command for agents: `ko api --stream` is the harness's
  bridge to the message stream. `stop_agent`
  and `stop_async_bash` take one target.
- The `ended` message on the parent's stream is the only ending
  signal. There is no `GET /panes/{id}/wait`, because nothing else
  needs one: a human reads the row's `dead`.
- `ended` carries no count of the messages that died with the child's
  queue: the parent knows what it sent, and a count would not say
  which.
- Message ids are the sender's and idempotent: a sender resends after
  a timeout, an `io` error or a dropped connection and learns the
  truth, and no receiver reads a message twice. The server keeps its
  16-message window and its 2 s ack wait.
- A report that is not acked is resent with the same id until it is;
  the parent keeps the whole text in its session, and `read_report`
  is the reference of a capped report notice.
- The prompt routes take the scope pane as `from`, and the identity
  headers stay identity only: Kido.app holds no pane token, and a
  client identity for it would add a concept for no gain.
- Trust is by the child's cwd, `KO_AGENT_TRUSTED_CWD`, not by a
  repository root: it holds for the one directory that the parent
  chose, and it compares paths of the child's own filesystem, so it
  holds in a runtime.
- `close` is `exit`, `keep` or `on_exit`. There is no `on_success`,
  which would remove only a pane that exited 0.

2026-11-05, panes close at exit:

- `exit` is the default `close`, so every pane that a client creates
  without `close` (a new tab, split or session, `POST /panes`, a new
  pane of `PUT /layout`) goes when its program ends, with no linger
  and no focus guard. Children keep `on_exit`, because their parent
  reads the lingering screen for the ending notice.
- A start failure keeps its pane, because the error is the one thing
  that the user must read. ko's wrappers set their own pane to
  `keep` before they exit with an error, because their exit is an
  ordinary exit to `ko-pane`. The route is the generic `PATCH
  /panes/{id}`, not a report of its own, so one route changes a
  pane's properties; a shell's failure to run a command is the shell's exit and closes the
  pane. The exit code does not decide: a shell's
  Ctrl-D returns the last command's status.
