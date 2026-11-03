# Kido's agent features, as built

This document describes how Kido's agent features work and the reasons
for their design: runs, the pi harness, the inbox, addressing,
spawning, outcomes and the sidebar tree. [design-ko.md](design-ko.md)
describes the server that holds them, [protocol.md](protocol.md) its
protocol, and [design-program-status.md](design-program-status.md)
the status of a pane. Its companion,
[design-subagents.md](design-subagents.md), follows one subagent from
spawn to sweep. `AGENTS.md` describes constraints that Kido cannot
change and problems that an apparently correct change can cause. This
document does not repeat them.

Kido has two parts. The `ko` server and CLI manage windows, the runs
in them and their status. A **run** is a process that ko starts in a
window of its own: a bash command, or a pi agent. The server mints an
opaque run id, keeps `runs/<id>/`, records the ending and answers
queries by id after the window is gone.

The **harness** is everything that only an agent has: the pi session,
the inbox, the tools, the task, the report and the names. It is one pi
extension, `share/pi/ko-pi.ts`, which the `ko-pi` shim loads. The two
parts talk through the run commands ("Window lifecycle") and pane
variables ("Who is authoritative for what"). ko never reads the
harness's files. The harness reads no ko file except the output path
that a run command prints.

## Who is authoritative for what

Three stores each hold information that no other store can hold:

**The layout document, for topology.** The server supplies these
facts (protocol.md, section 7):

- the window and session that contain each pane;
- the pane's foreground command;
- which clients show a pane and which has focus;
- whether the pane's process has exited, and how.

Nothing caches these facts. A pane can move between windows and
sessions while its process runs. A run record names only a pane, not
its window or session.

**The pane's row, for which run a pane holds.** The server ties a run
to its pane when it creates the pane inside the run's window, and the
row carries the run (protocol.md, section 10). Nothing changes the tie
later, and no variable names a run. Removing the pane removes the tie
without a separate unmark step. A user's split beside the run's pane
has no run, so a sweep and the sidebar distinguish the run's pane from
the user's pane.

**Pane variables, for the facts only an agent has.** The extension owns
four pane variables, written with `ko api` (protocol.md, section 7):

| variable | value | ko reads it for |
|---|---|---|
| `pi.session` | the pi session id | `PiAgent`, the status identity, the session column of `ko runs` |
| `pi.name` | the session name | the row title of a local pi |
| `pi.inbox` | the inbox socket's full path | `ko prompt`'s delivery |
| `pi.activity` | the agent's activity text, one line | the caption fallback |

ko trusts them only while the pane has an OSC 7501 root with `app=pi`,
as it trusts `ssh.dest` only while the foreground is `ssh`. The
server drops the records on pane death, a shell prompt (non-final
records) and RIS, so a crashed pi's variables are stale but not
believed. A crash in an integrated shell can leave a final root: the
inbox is then dead, and a prompt fails. No variable copies a field of
the run record. A top-level pi has a session but no run.

**The runs directory, for everything else.** The server's state
directory is `$KO_STATE_DIR`, else `$XDG_STATE_HOME/ko`, else
`~/.local/state/ko` (design-ko.md, "Lifecycle and the command line").
Every run has one directory `<state>/runs/<run-id>/`
(`ko_server/src/runs.rs`). Each write replaces a whole file:

- `meta.json`: written at the start. It contains the id, name, parent,
  pane, argv, cwd and start time. The parent is optional: absent for
  a top-level run, a run id for a run that owns it, or the pane id
  `pane_N` of a top-level pi (`ko run-child pane_N`). A run id is 32
  lowercase hex characters, so no id looks like `pane_N`.
- `outcome`: written once by the server, which refuses a second
  outcome ("Run outcomes").
- `output`: written by the run's own command. A caller that wants it
  puts `tee "$KO_RUN_OUTPUT"` in its command line.
- `screen`: the capture of the dead pane before the sweep removes it.
  The last write wins.

A top-level pi has no run and no directory. ko stores nothing for a pi
session.

A run's status comes from its outcome and its pane, never from a pid.
A run has **ended** when it has an outcome, or when its pane is dead or
gone. Without an outcome, the dead pane supplies the ending: exit 0 is
`completed`, another status is `failed` with the text `exit N`, a
signal is `failed` with `signal NAME`. A dead pane with neither, or no
pane, is `died`. `ko runs --all`, `ko runs ID`, `ko run-wait` and the
`run` event show a derived ending like a recorded one. Only the sweep
stores it.

Only OSC 7501 root records supply status. OSC 0/2 supplies the pane
title. design-program-status.md, "Pane kinds", gives the
classification. A run does not identify a pane as an agent. Prompt
scope accepts both agent kinds: a `PiAgent` over its inbox, any other
agent by paste.

There is no locking, because every writer is the server's loop thread.
Runs are never deleted.

## The pi extension, ko-pi

`share/ko/bin/ko-pi` starts pi with `--extension <share>/pi/ko-pi.ts`
in front of every argument and `PI_IMAGE_PROTOCOL=kitty` unless the
variable is set. A bare `pi` in a pane is plain pi: it reports OSC
7501 status and has no harness.

After interactive terminal feature detection, pi natively emits OSC
7501 root records with `app=pi`. Its lifecycle supplies working,
blocked, done, idle and error. Native dialogs report blocked;
extension custom UI does not. `PI_PROGRAM_STATUS=0` disables reporting,
and `=1` forces it. OSC 0/2 sets the pane title to "π - <name> -
<cwd>". The caption omits a local pi message that duplicates its
session name.

The extension uses only these interfaces of ko:

- The run commands `run-child`, `runs --json --all [--parent P]`,
  `run-wait ID --json`, `run-stop` and `run-outcome`.
- `ko api`: `GET /layout` for the panes with their sessions and
  windows, `PUT` on `/panes/$KO_PANE/vars/<name>` for its variables,
  and one conditional `DELETE` on `/panes/$KO_PANE/vars` at the end.
  It never opens ko's socket itself.
- `ko layout edit` for a top-level agent's window.

It never finds or parses ko's state directory. The only ko file it
reads is a run's output, at the path that `run-child` and `runs
--json` print. It sends envelopes in the v1 inbox format directly to
the target's `pi.inbox` socket.

**Inside ko** is `KO_RUN_ID` set, or `$KO_SOCKET` set and `ko` on
PATH. Its pane is `$KO_PANE`. A pi outside ko, a pi without a UI or a
pi without a session id writes no variable and binds no inbox. A
headless `pi --print` has its own session id, so it cannot act as the
agent of the pane that it runs in.

**The state directory** is per user and shared by every ko server:
`$KO_PI_STATE_DIR`, else `$XDG_STATE_HOME/ko-pi`, else
`~/.local/state/ko-pi`. It is not under a server directory, because
the agent map outlives a server. It is not under `$TMPDIR`, because
the map outlives a reboot. It holds:

- `inbox/<session-id>.sock`, in a 0700 directory, when that path fits
  the 103-byte socket limit. Otherwise the inbox is in
  `/tmp/ko-pi-<uid>/`, which must be a directory of the user with mode
  0700 and not a symlink, under a name that is a hash of the state
  directory and the session id. Thus, a parent still computes a
  child's inbox with no lookup, and two state directories do not
  collide.
- `agents/<parent-session>/<name>/`, the agent map
  (design-subagents.md, "The agent directory").

**The variables.** The extension writes `pi.session` and `pi.name` at
`session_start`, `pi.inbox` after the bind, and `pi.name` again on
`session_info_changed`. It writes no `pi.activity` value, but ko reads
that variable and the extension deletes it with the others. Without
`$KO_PANE`, nothing is written. At shutdown it deletes the four with
one conditional `DELETE` whose condition is `pi.session` equal to its
own session, so it never removes another pi's variables: the pane can
have a new owner before the old one cleans up. An uncaught crash exits
through `process.exit`, so a synchronous `exit` handler sends the same
delete. The handler stays across `/reload` until the next
`session_start` replaces it. Only a process that ends without cleanup,
such as with SIGKILL, leaves them; the trust rule makes them harmless
for identity.

**The trust rule.** The extension's own discovery uses ko's rule: a
pane is a local pi agent only with an OSC 7501 root with `app=pi` and
`pi.session`. Discovery and addressing apply it. A stale variable on a
shell pane is no agent. Liveness of a known session is the exception,
because pi clears its root while it runs: pi-tui's `stop()` writes a
`clear` record while pi opens the external editor and while Ctrl+Z
suspends it.
A child's report and the parent watch find a session alive while a
pane that is not dead holds its `pi.session`, with or without a pi
root. A dead pane counts as gone, because a run pane keeps its screen
and its stale variables until the sweep removes it. Thus, an agent in
its external editor or suspended is not listed and cannot be
addressed, but a child's report reaches a parent in its editor. A
suspended pi reads its inbox only after `fg`.

**Project trust.** The extension handles pi's `project_trust` event,
which pi sends to `--extension` extensions before it reads its trust
store. It answers `yes` when the real git common directory of pi's
directory is `KO_AGENT_TRUSTED_ROOT`, which a spawner passes only for
a repository that it trusts. It never saves the answer
(design-subagents.md, "What a child is given").

**One copy.** On its first factory call, the extension claims
`globalThis.__koPiExtensionCopy` with its path. A copy at another path
registers nothing, because pi dedupes extensions by real path only.

**Subprocesses.** The extension starts every ko process with
asynchronous `spawn`, never `execFileSync`, except the synchronous
cleanup at `exit`. A blocking call stops the whole process while ko
runs. During that time, the inbox listener cannot accept connections,
and a peer's message reaches its two-second deadline without
acknowledgement. A failed command returns its stderr line, which the
model can act on. A timeout reads as a timeout, because ko can already
have completed its work.

## Identity

**An agent is its session, not its process.** The pi session id is the
identity. `pi.session` publishes it, the inbox path derives from it,
and the agent map names parents and children by it. A pid is not an
identity, because the OS reuses pids.

**A run id is not a session id.** The server mints the run id. A
restarted agent is a new run with the same session. The parent mints
the child's pi session id and passes it with `--session-id`.
`agent.json` records both, so no mapping needs to be derived.

**The parent edge.** `KO_AGENT_DIR` names the child's agent directory.
The child trusts it only when that directory's `agent.json` names the
child's own pi session id. Every process that an agent starts inherits
its environment: a human's `pi` in that pane, or a tool calling
`pi --print`. A nested pi mints its own session id, so it cannot meet
the rule, and it inherits nothing. The parent is the session in the
directory name above it. `KO_AGENT_PARENT_SESSION` is also set, only
for the repo's `no-git-writes` guard.

**The relationship comes from the map, not from ko.** A sender is the
parent if its session is the parent session, a child if it is in
`agents/<own session>/`, else a peer.

**ko has no caller for a parent.** The run commands take their parent
as an argument (`run-child PARENT`). The caller's own pane reaches the
server as its pane identity, `Ko-Pane` and `Ko-Pane-Token` from
`$KO_PANE` and `$KO_PANE_TOKEN` (protocol.md, section 1), for the
session of a new run, for prompt scope and for the checks of what a
pane may do; it limits the parent to the caller's own pane or one of
its runs, and never supplies one.

**Children belong to the session that spawned them.** A parent that
restarts under its own session id finds its children again in
`agents/<session>/`. `/new`, `/resume` and `/fork` move a pi process to
a new session id. A child still names the old id, and its parent watch
ends it. Transferring the parent edge would send a child's report to a
session that nobody reads.

**Two pis on one session** share only the inbox socket path. The
extension unlinks a stale socket file only after a 200 ms connect
probe fails, so it never displaces a live listener. The second pi
binds nothing and publishes no `pi.inbox`.

## The inbox

A pi session that accepts prompts as real user messages listens on a
unix stream socket and publishes its path as `pi.inbox`. Just before
binding, the extension creates the inbox directory with mode 0700.
Anyone who can write there can impersonate an agent's socket. When
ko-pi cannot bind its inbox, or cannot deliver a notice to its
parent's inbox, pi shows a warning.

**A `/reload` does not take the inbox down.** A reload keeps the
process and session id. `globalThis.__koPiExtensionInbox` holds the
server, which survives the module that bound it. For reason
`"reload"`, `session_shutdown` parks the socket: it stays bound, and
connections wait. The reloaded module's `session_start` adopts the
server and its waiting connections without rebinding. Every other
reason closes the server and unlinks the socket. A notice has no paste
fallback and is sent exactly once. Thus, the reload gap must not
discard it.

A reload also keeps the four pane variables, because the socket stays
bound and the session continues. Deleting them would make the parent
look gone during the gap. The `run-wait` watches survive in
`globalThis.__koPiExtensionWatches`, with all their stream state. The
old module detaches each waiter before it kills it, so only the
reloaded module can send an ending. Its `session_start` restarts one
waiter for each. A run that ended during the gap is reported by its
new waiter, so its notice is not lost.

The wire protocol uses one message per connection, with these steps:

1. Connect.
2. Write the payload as UTF-8 without framing.
3. Half-close the write side, so EOF ends the message.
4. Read the reply.
5. Close.

The reply is `ok` or `refused`. One two-second deadline covers the
whole exchange, including connection. The agent answers immediately
after reading the message. A sender treats any slower response as
unresponsive. The server's own send for `ko prompt` is
`ko_server/src/msg.rs`, a non-blocking connect and a stored send on
the loop with the same deadline.

`ok` means the agent has the message and sees it at its next turn
boundary. This is the only acknowledgement level. `message_agent`
promises delivery, not action.

An agent's message identifies its sender. A `message` from another
agent reaches the model as a custom message, like a notice, with one
header line that names the sender and its relationship to this
session: `message from @<name> (your parent, who spawned you):`,
`(your subagent):`, or `(another agent in this session, not the
user):`. Only the peer header says it is not the user. A child's only
user is its parent, so a parent's instruction has that authority. The
renderer removes the header and displays `message from @<name>:` with
the full text. A message never collapses, because its purpose is to be
read. Only v0 text, which `ko prompt` sends, is the user's own text,
without a header.

### Steer and followUp

The extension uses `followUp` to queue work and `steer` to interleave
work. The rule, one line:

> Steer what is safe to interleave. Queue what waits for the turn to end.

- **`message` queues.** It has no authority over the receiver's work.
- **`steer` steers.** The agent that assigned the work sends a
  correction. It has no value after that work ends.
- **`interrupt-and-steer` queues after the abort.** The receiver
  aborts the turn first, so nothing remains to steer into.
- **`notice` steers.** The parent needs this information to assign the
  next work.
- **A stream batch steers.** It is not an envelope: the parent tails
  the run's output file itself (design-subagents.md, "Streaming a
  run's output").

Escape and the dequeue key restore only queued user text to the
editor. Custom messages remain in their steering and follow-up queues,
in order. The extension wraps `AgentSession.clearQueue` to preserve
them while pi clears editor queues. `globalThis` holds the original
method, so `/reload` replaces the wrapper instead of adding another.

### Waking an idle session

The extension sends each arrival with
`sendMessage(..., { deliverAs, triggerTurn: true })`. While a run is
active, pi queues the message in that mode. While the session is idle,
pi starts a run with the custom message as its first message. No
user-role text is sent. pi starts this run with the same setup as a
prompt: `before_agent_start` runs with `messageType: "custom"`, and the
extension's handler adds its prompt guidelines.

**One run at a time.** pi counts the session as busy from the start of
the run, also while `before_agent_start` handlers run. A second
arrival during that time goes into the starting run's queue in its own
mode.

### v0 and v1

A v0 payload is raw prompt text. A v1 payload is one JSON object with a
version, a kind (`message`, `notice`, `steer`, `interrupt-and-steer`,
`stop`), an id, a sender (session, name and pane) and the text. A
payload is v1 only if it parses as a JSON object with both `v` and
`kind`. All other payloads are v0 text, including JSON objects missing
either field: a user prompt can itself be a JSON object. A fixture
table (`share/pi/testdata/discriminator.json`) tests the parser. An
unknown kind reaches the model as text labelled with that kind.

The extension sends only v1. `ko prompt` always sends v0. It targets
only top-level agents: a pane is never a candidate if its window
contains a run pane (`ko_server/src/state/prompt.rs`). If the caller's
window has no candidate, the search widens to the session. Without
this exclusion, one agent and one live child in the session would give
two candidates and exit 5.

The protocol has no version gates. The binary and the extension
upgrade together. The sender field is advisory: the inbox directory's
mode enforces uid-scoped trust, and any same-uid process can write an
envelope that claims any identity.

## Delivery, and when a paste is allowed

`ko prompt` reads its text from stdin and sends it to the server with
its pane in `Ko-Pane`; the server resolves the scope and delivers
(protocol.md, section 11). A `PiAgent` whose trusted `pi.inbox` names
an inbox gets the text over that socket. An inbox that cannot be
reached is `refused` and nothing was sent. A timeout or another
failure after the connect is `io`: the message can already have
arrived, so a retry could deliver it twice. Neither falls back to a
paste. The extension's sends use the same rule: a timeout or error
before the connection is `unavailable`, and only that is retried while
a restarted child binds its inbox.

A paste and a separate Enter key go only to a candidate that is not a
`PiAgent`: Claude Code has no identity and is reachable only through
a paste, and so is a pi without the harness. An advertised but
unavailable inbox is an error, not permission to paste.

The extension never pastes. A target without `pi.inbox` is "not
accepting messages". Model-authored text must not run as a command
line in the target's pane. A refusal (`refused`) is not a delivery
failure. The extension refuses two more sends before sending: a
message to the caller itself, and text that is not valid UTF-8.

## Addressing

The session limits addressing for `message_agent` in every mode.
`list_runs` and the `@` completion share a narrower discovery scope
(design-subagents.md, "The tools, and what they call"). That scope
never limits addressing.

The tools show names, not ids, and still accept a session id, a run id
or a unique id prefix: two top-level pis may share a name, and another
parent's child has no name for the caller. Within scope, a target
resolves by these rules in order:

1. An exact case-insensitive name.
2. An exact session id or run id.
3. A unique prefix of a session id or run id, of at least eight
   characters. A shorter prefix that matches an id is refused for its
   length.

Each rule reports its own ambiguity. A match in the caller's session
wins over a match elsewhere. A target in another session is reported
as such, not as "not found". Unnamed pi sessions match only by id.
Native-only panes have no addressable session. `stop_run` resolves run
ids first (design-subagents.md, "Redirecting one, and ending one from
outside").

Every tool that takes `to` removes one leading `@`. It also accepts a
whole mention from the prompt: `@impl (run 9702ddd1)` or
`@reviewer (session 01a0bfcf)` resolves by the id in the parentheses
only, so another agent's name cannot capture it.

In pi's prompt editor, `@` and a prefix complete live agent rows from
`list_runs`. Completion excludes bash and ended runs. Each row shows
the name, status, activity and a subagent's parent. The extension
wraps the completion provider to place agent matches first, and
delegates tokens with no agent match. Completion inserts
`@impl (run 9702ddd1)` for an agent with a run and
`@reviewer (session 01a0bfcf)` for a pi that the user started in a
pane. The id is the shortest prefix, of at least eight characters,
that no other row's session id or run id starts with, over every row
that `message_agent` and `stop_run` resolve over. A keystroke uses the
last list without waiting for discovery. If the list is older than
`KO_AGENT_LIST_TTL_MS` (1 s), a background refresh starts.

## Spawning

`spawn_agent` starts a child through `ko run-child`, or a top-level
agent through `ko layout edit` (design-subagents.md,
"What a child is given" and "A top-level agent"). A child's run window
goes after its parent's window, a top-level agent's at the end of the
caller's session; no client switches to either, and
both wrap pi in `ko shell --` ("The login environment", below). The
request carries the cwd (the `cwd` argument, a resumed session's own
directory, or the caller's) and each environment variable, because a
new pane gets the server's environment, not the caller's.

The task is never a command-line argument. A model writes text of any
form. The task is a file in the agent directory, and the child reads
it at `session_start`; a restart's message also goes there. A
top-level agent has no agent directory, so its task goes over its
inbox. No task is pi's argv: pi's parser reads an argument that starts
with `@` as a file, even after `--`.

The model also writes the window name. The server refuses a name over
64 bytes or with a control character (`RunName` in
`ko_server/src/runs.rs`), instead of silently changing it. The name
never reaches a shell: the server starts the argv directly. The
extension also uses the name as a directory, `agents/<parent>/<name>/`,
so it refuses an empty name, `.`, `..` and a name with `/` before it
writes anything.

### The login environment

The server starts a run's argv directly, with only the server's
environment. A pi that the user starts in a pane runs under `ko
shell`, which read the user's dotfiles: EDITOR, PATH additions, API
keys, LANG. So that every agent gets the same environment, the
extension's one pi argv builder starts each pi, child or top-level,
new or restarted, as `<its ko path> shell -- ko-pi ...`. `async_bash`
starts its command directly, because its command is not an agent. `ko
run` and `ko run-child` add no wrapper.

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
process: the pane's death is pi's, and "Run outcomes" applies
unchanged to a child. If the exec fails, the shell exits 127 (126 for
permission). Another shell, such as fish, has no `"$@"` semantics: ko
execs CMD directly, and the user's dotfiles do not run.

A top-level agent's task goes over its inbox, so the spawn waits for
the inbox through the shell's startup and pi's: up to
`KO_INBOX_WAIT_MS`, 30000 ms by default.

### Failure leaves a record

`POST /runs` creates the run directory and its meta before the window.
If the pane cannot start, the server keeps the old document and the
run is `failed` with the error. Thus, `ko runs` does not show an
unexplained run without a window. The pane that a run gets enters the
document with its run in one layout event, so no reader sees an
unmarked run window.

## Window lifecycle

**Run commands.** ko starts a run without the harness
(`ko/src/runs.rs`):

| command | does |
|---|---|
| `ko run --name N [--cwd D] [--session S] [--env K=V]... -- CMD...` | starts a parentless run; prints the JSON of `Started` (`ko_server/src/protocol.rs`): the id, window, pane and output path |
| `ko run-child PARENT ...` | the same, under PARENT: a live run id, or a pane `pane_N` that is not dead; a caller in a pane names only its own pane or one of its runs |
| `ko runs [--json] [--all] [--parent P] [ID]` | lists live runs newest first, with a SESSION column, or one run in any state with its argv and, without `--json`, its screen (`GET /runs/<id>/screen`); `--all` also lists ended runs |
| `ko run-outcome ID --result completed\|failed\|stopped [--text T]` | records an ending; a second write exits 5 |
| `ko run-wait ID [--json]` | blocks until the run has ended; prints the result, or the outcome object |
| `ko run-stop ID [--wait SECS] [--result stopped\|completed]` | records the result, then ends the process and removes its pane |

`--name` is required, because a command's first word (`bash`, `pi`)
says nothing. `--session` takes a session id or name and defaults to
the caller's session; `--cwd` defaults to the caller's cwd. The argv
is the pane's command, with no wrapper. The pane's environment has
`KO_RUN_ID` and `KO_RUN_OUTPUT=<dir>/runs/<id>/output`, plus each
`--env`. The SESSION column of `ko runs` is the live pane's
`pi.session` while the pane has a pi root, else empty.

Exit codes: 0 success; 1 usage or any other error; 2 a bad or unknown
PARENT (an unknown or ended run, a gone or dead pane); 3 a bad or
unknown run id; 4 a refused window name; 5 `run-stop` of a run that
has ended, or a `run-outcome` write that loses to an earlier outcome.
A parent that the caller's pane may not name is 1.

`run-wait` is a long poll (protocol.md, section 10): the server
answers at the run's end, and the waiting connection makes no work for
the server until then. A pid is never evidence: a killed pane whose
process survives its hangup has ended, and `run-wait` reports `died`.

**run-stop** records its result first, so that an ending that the pane
produces later cannot replace it. A run that has already ended exits 5
at once and records nothing, so the ending that the pane gave stays
the run's ending. Then it stops the pane as `POST /panes/pane_N/stop`
does: it waits `--wait` seconds (default 0) for the pane to die and
removes the pane. The removal hangs up the program:
`ko-pane` sends `SIGHUP`, then `SIGKILL` 250 ms later; if the removed
pane still lives after `KO_STOP_ESCALATION_MS`, the coordinator kills
it. A caller that must act between the record and the stop records
first with `run-outcome`, then runs `run-stop`. `--result completed`
is for a subagent that reported since its last new work before it was
stopped. `ko run-stop` sends no notice; the caller's `run-wait` reports
the ending.

A run's pane stays dead with its last screen until the sweep removes
it. Thus, an immediately failing child keeps its pane and last screen.

**The sweep.** The server sweeps when one of its inputs changes: a
pane's death or removal, the focused panes, and the end of a linger
grace (protocol.md, section 10). It reads the pane rows, not the run
records, so it acts on any pane by its `close` and `parent`, and a
plain shell pane, which has neither, stays. The run record matters
only for what the sweep writes: a pane whose row carries a run, and
whose run meta names that pane, gets the run's outcome and the screen
capture first. A pane id is not an identity across servers: each new
server restarts pane ids at `pane_1`, while run records survive the
server, so both must agree.

Two rules apply:

1. A pane with `close: on_exit` has been dead for the linger grace
   (`KO_LINGER_SECONDS`, 30 s by default). Every run pane has it. For
   a run, the sweep records the ending that the dead pane gives
   (`completed`, `exit N`, `signal NAME` or `died`).
2. A pane's `parent` is gone or dead. The sweep removes the pane at
   once, live or dead. For a run whose pane still lives, it records
   `failed` with the text "its parent ended". A run parent is its
   pane: a run whose pane lives keeps its children, whatever its
   outcome. The rule reads no process and no pi evidence, by design:
   a child of a pi that quits inside a living shell pane ends through
   its own parent watch, not the sweep.

An earlier outcome, from `run-outcome` or `run-stop`, stands in both
cases: the server refuses the second write. Rule 2 forces a stop
instead of requesting graceful shutdown like the child's poll. It is
the only available action outside the child, and it ends a `tail -f`
that an exited parent started. A pane without a parent is a root that
the sweep must not cancel.

The sweep never closes a run pane that a client with terminal focus
shows (protocol.md, section 3); it tries again when the focus changes.
Waiting loses nothing. It does not protect a session's last window: an
empty session ends.

**A split window is the user's window.** The collection unit is the
run's pane, not its original window. The sweep removes the run's pane
with a pane delete; a window that loses its last pane goes with it in
the same change, and an empty session with it (protocol.md, section
7). After the removal, the sidebar draws an ordinary window with the
user's remaining panes. `run-stop` and stop escalation do the same.

No other guard applies: no debounce. Without grace under rule 2, a
child already shutting down can lose its pane during exit. It can
receive "its parent ended" before recording its own outcome. The
server keeps the first written outcome.

**The screen capture.** Before the sweep removes a run's pane, and
before a `failed` outcome of a run whose pane exists, the server
captures the pane's screen and its whole scrollback through the pane's
formatter (`ko_server/src/state/run_ops.rs`) and writes
`<run-dir>/screen`. This is the only chance to capture crash
diagnostics. Capture does not depend on the ending: even a clean
exit's last screen can be useful. Losing a screen is better than
leaving an uncollected pane: a capture error never prevents the
removal. The capture holds the whole history, cut to
`KO_RUN_SCREEN_BYTES` (64 MiB by default); truncation keeps the end,
because the last output is the most likely crash diagnostic. The
coordinator keeps at most twice the cap while the chunks arrive and
cuts at a character boundary. `ko runs <id>` prints the screen when
present.

**Parent death.** The child's pi belongs to the server, not the
parent's pi process. Thus, no OS parent-death signal reaches it. Its
extension watches the parent's pane (design-subagents.md, "A child's
life"). A failed read supplies no evidence and never causes shutdown.
If the parent is gone, the child calls pi's `shutdown`. The sweep's
rule 2 covers a child whose parent pane is gone or dead, pi or not.

## Ending a child, and restarting it

A child has no idle timer. After it reports, or after a turn settles
with nothing to do, it keeps its window, pi process and model context.
Only three things end it: its parent, with `stop_run`; the user, who
quits or kills the window; the orphan rule, after its parent ends.

The parent decides, because only the parent knows whether it needs
more work. The child's report is not an ending. The report notice that
a parent receives says so: end the child with `stop_run` when nothing
more is needed, or continue it with `message_agent`.

**An ended child restarts on a message.** `message_agent` to an ended
subagent starts it again as a new run under the same pi session, with
`ko-pi --session <session file>` and the message as pi's first prompt.
A reused name means "message it". design-subagents.md, "Restarting
through a message", gives the rules. `spawn_agent` with `resume_from`
continues any saved session that no pane holds, and resumes an ended
child through the same path.

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

**Scope.** These verbs reach only descendants: agents with the caller
in their parent chain in the agent map, a grandchild included. Both
redirect current work with the same authority, so both have the same
restriction. This is not a security boundary. The sender checks the
scope before sending; the receiving extension checks again with its
own agent map. The chain walk stops at a repeated session, so a
corrupt map entry that names itself as parent cannot let a session
stop itself.

**Escalation.** An unresponsive child does not answer. `stop_run` first
records the outcome with `ko run-outcome ID --result stopped`. The
child's own shutdown writes `completed` or `failed`, so a request sent
before the record would let that write win. A record that loses to an
earlier outcome (exit 5) means that the child ended on its own:
`stop_run` sends no request and reports that ending. Otherwise, it
sends its request, and runs `ko run-stop ID --wait 5` whatever the
request returned: a recorded stop must also end the process. The
extension's deadline for `run-stop` is its `--wait` plus
`KO_STOP_ESCALATION_MS` plus 1.5 s, so that the kill and the pane
removal always run. A refused request does not cancel the stop.

Stop removes the target's pane, not its window. The request names one
agent; a window removal would also kill unrelated panes. Stop does not
refuse a focused pane. This differs from the sweep, which acts
automatically and must protect a screen that the user can be reading.

**No inbox means no quiet stop.** Without an inbox, an agent cannot
receive a request. Stop then removes its pane at once. This is
destructive and irreversible, so it requires `force`.

## Notifying the parent

Notification is automatic. When a subagent's turn settles idle after
work from its parent, and it waits on nothing of its own, the harness
sends the last assistant message of that run to the parent as an
ordinary `notice` envelope. design-subagents.md, "A child's life",
Reporting, gives the trigger, its conditions, the `report` file and
the cases that send nothing. An explicit tool would make each report
depend on the model calling it at the right moment.

The parent receives at most 4000 bytes, the guidance included, because
the whole message enters the parent's context.

**What this costs, and what covers it.** A crashed subagent that never
settles a turn supplies no work report. ko does not invent one.
Instead, the parent's own `run-wait` tells it how the run ended. A run
that the parent stops itself with `stop_run` sends no ending notice:
the tool result is the only signal.

**Telling a child this is its job.** `before_agent_start` appends a
standing instruction to the subagent's system prompt on every turn, if
it has a parent edge, because a `/reload`, a restart or a later parent
message can start work without the task's one-time first message.

**The rendered side.** An inbound `notice` uses a custom message that
can collapse to "@X notifies: <first line>...". The model receives the
full text with one header: `notice from <from> (a subagent or
background run's report, not the user):`. Immediately on envelope
dispatch, a dimmed widget line shows the arrival; when the message
reaches the transcript, the permanent collapsed row appears and the
widget entry goes. The text goes to `sendMessage` exactly once.

Notices use `"steer"`, not `"followUp"`: a long parent turn would
otherwise delay the report until that turn ends. The extension sends a
steer, not an abort. The model decides whether to act now or continue.

## Run outcomes

Code that knows how a run ended writes its outcome. A pi child's own
outcomes are `completed` and `failed`. Its shutdown reports them
through `ko run-outcome`: `completed` if the session ends idle after
reaching its first turn, `failed` otherwise. `run-outcome` also
accepts `stopped`, which a parent's `stop_run` records before it stops
the child. `died` is ko's external judgment only.

The sweep writes the ending that the pane gives, or `failed` with "its
parent ended" under the orphan rule. `ko run-stop` writes `stopped`,
or `completed` with `--result completed`.

**Written once.** Every writer of an outcome is the server's loop
thread. The server refuses a second outcome, and the file is a plain
atomic write (protocol.md, section 10). The first recorded ending
wins; a later, less precise guess never overwrites it. This rule
determines the other ordering:

- `run-stop` writes its result before it waits or signals.
- A `/reload` must not record `completed`. The shutdown handler
  records only for reason `quit`.
- `ko runs` and `ko run-wait` derive an ending from the pane for a run
  without an outcome. They never store it.

ko does not prune run records. A listing without `--all` shows only
live runs. The extension passes `--all`, because `list_runs`, name
checks and restarts need ended children.

## The sidebar tree

Both clients build the tree from the layout document, the pane rows
and their runs (`ko_client/src/model.rs`, with the walk of
`ko_client/src/tree.rs`). A subagent's panes follow the pane that
spawned it, one level deeper, not after the whole parent window: the
subagents belong to the coordinating agent, not a shell sharing its
window. A run's parent comes from its meta: a run parent nests the
run's window under the pane of that run, and a pane parent (`pane_N`,
from `ko run-child`) under that pane, with or without a run record.
Every pane of a run window follows the run's parent, so a user's split
beside the run pane nests under the same parent. A parent that is
absent or in another session leaves the child a root of its own.

The terminal client draws the list as session headers and pane rows,
indented by depth (`ko_tui/src/sidebar.rs`); `Ctrl+Shift+Up` and
`Down` visit every row in that order. Kido.app draws its tree with
brackets and group glyphs (design-app.md, "Sidebar").

The walk uses parent-first ordering and emits every item exactly once,
with or without a tree. A reporting bug or edited run meta can create a
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
shell. stdin remains available for the interactive session.

**What that costs, said plainly.** The payload is a public shell
script without secrets, so ko permits it in argv. All sidebar
information about the pane comes from the remote host's report. A host
can report any claim about what it runs.

**The ZDOTDIR swap.** The bootstrap creates a fresh directory with
`mktemp -d` and decodes the integration there. It writes `.zshenv`
beside the integration, sets `ZDOTDIR` to that directory and execs the
login shell. The generated `.zshenv` restores `ZDOTDIR`:
`KO_ORIG_ZDOTDIR` carries the user's value when set. The bootstrap
never writes or installs anything in remote `$HOME`. The swap occurs
only if the user already has zsh dotfiles.

**The bash branch.** The bootstrap sets `ENV` to a file beside the
decoded integration and execs the login shell with `--login --posix`.
That file disables posix mode again, sources `/etc/profile`, then the
first of `~/.bash_profile`, `~/.bash_login` or `~/.profile`, then the
integration, and removes the directory. Before priming bash, the
bootstrap asks the login shell for its version once; an answer below
4.4, or no version, starts the login shell plain. Older bash reads its
login files without markers, through the same route as an unsupported
shell.

**Nothing persists.** ko resends the payload on every connection.
`.zshenv` reads the integration into a parameter and removes the whole
directory. zsh sources the integration at its first `precmd`, not in
`.zshenv`, so ko's hooks come after the user's setup.

**Degrade, never break.** `ko ssh host` must not behave worse than
`ssh host`. ko passes the command line unchanged, without `-t` or a
remote command, unless all priming conditions apply: a destination, no
user-supplied remote command, a local tty, and none of the
no-login-shell options `-N`, `-T`, `-W`, `-f`, `-n`, `-s`, `-O`, `-Q`,
`-V`, `-G`. For priming, ko adds `-t`. Every remote failure (an
unsupported shell, a missing `mktemp` or `base64`, a decoding failure)
starts the same login shell without priming. ko execs ssh, so signals,
exit status and tty behave as with ssh alone. The bootstrap selects
its branch by the remote login shell's basename.

ko intentionally does not implement terminfo shipping, a remote ko
binary, ControlMaster sharing, askpass or fish. `ko HOST`, the remote
attach, is a different thing (design-ko.md, "Remote").

## Priming a local shell

`ko shell` is the default pane command. It resolves the user's shell
in this order, checking each candidate for executability: `$KO_SHELL`
(the server's `--shell`), `$SHELL`, `/bin/sh`. It runs a login shell
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
back to plain mode. `ko shell -- CMD...` runs a command in the same
shell, without priming ("The login environment").

The bash integration uses `PS0` for command-start markers and
`PROMPT_COMMAND` for prompt markers. Sourcing it a second time causes
no action. The integrations blank control characters and limit the
command line to 1024 characters.

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

**Install layout.** `make build-ko` lays out `build/ko/` as installed:
`bin/ko`, `bin/ko-pane` and `share/ko` with `bin/`, `shim.sh`,
`pi/ko-pi.ts` and the terminfo. `make install` copies it under
`PREFIX`, default `~/.local`. This is Homebrew's `pkgshare` layout.

## Knobs

Every duration that a test must shorten is an environment variable
that the process under test reads when it uses it:

- `KO_LINGER_SECONDS` (the sweep's grace, with an optional fraction),
  `KO_STOP_ESCALATION_MS`, `KO_RUN_SCREEN_BYTES` (a size, not a
  duration, so that a test reaches the capture's cap),
  `KO_CLIPBOARD_TIMEOUT_MS`,
  `KO_VIEW_QUEUE_BYTES` and `KO_VIEW_SPILL_BYTES`, read by `ko server`
  (`ko_server/src/config.rs`);
- `KO_PARENT_POLL_MS`, `KO_SPAWN_TIMEOUT_MS`, `KO_INBOX_WAIT_MS`,
  `KO_AGENT_LIST_TTL_MS`, `KO_STREAM_POLL_MS`, `KO_STREAM_FLUSH_MS`,
  `KO_STREAM_MAX_WAIT_MS`, `KO_STREAM_BUDGET_BYTES` and
  `KO_TIMEOUT_MS`, read by the extension.

The extension's tests set them in the environment of the process under
test. The e2e suite sets the server's through its environment.

## Known limits

- A pi that quits inside a shell pane that stays open leaves its
  `async_bash` runs alive: their parent is the pane, which lives. They
  end when the pane closes, or the user stops them. A pi child ends
  through its own parent watch when the parent's session id goes
  (design-subagents.md, "Watching the parent").
- A `ko run` without a parent has nobody to collect it while it lives.
  The user must close its window. The sweep still collects its dead
  pane.
- A subagent whose window moved to another session is outside its
  parent's scope and cannot be messaged.
- Runs are never pruned, and neither is the agent map.
- pi asks its startup project trust question before it reports OSC
  7501 status. A pi that ko did not spawn into a trusted repository
  shows no blocked status while it waits for the answer.
- A `ko ssh` session killed after ssh starts but before remote zsh
  reads `.zshenv` leaves its temporary directory under remote
  `$TMPDIR`.
- The design assumes one machine for the agents of one server. All
  agents share filesystem access to the state directories and the
  sockets, and each has an adjacent ko binary. A remote attach shows a
  remote server's agents; it does not make them peers of local ones.
