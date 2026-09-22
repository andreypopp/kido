# kido's design, as built

This is how kido works and why it is built that way. It is the companion
to [subagents-plan.md](subagents-plan.md), which records what was decided
and in what order; this document records what stands. AGENTS.md carries
the things kido cannot change (the tmux fork, what Claude Code and pi
actually report) and the traps a plausible change would fall into. Those
are not repeated here.

The shape in one paragraph: tmux owns the topology. Agents report what
only they know into a directory of state files. pi's extension binds a
unix socket per session so text can be handed to it as a real user
message. Everything an agent can do to another agent - list, message,
ask, spawn, interrupt, stop - is a `kido` subcommand that a pi tool
shells out to, so the e2e suite (which cannot host a TypeScript
extension) can drive all of it through fake agent binaries. The sidebar
polls tmux and the state directory, and its poll is also where subagent
windows get collected.

## Who is authoritative for what

Four stores, each holding what nothing else can:

**tmux, for topology.** Which pane is in which window and session, what
its foreground command is, whether anyone is attached, whether its
process has exited. None of this is ever cached: a pane can be moved
between windows and sessions while its process runs, and a window id is
only meaningful on the server that issued it. Every command that needs
to know which session an agent is in takes a fresh pane list and looks
its pane up there. A state record names a pane and nothing above it.

**State files, for what only an agent knows.** `$KIDO_STATE_DIR`, else
`$XDG_STATE_HOME/kido`, else `~/.local/state/kido`, one JSON file per
agent session named by session id, written temp-then-rename. A record
carries the agent's status, its pane, its pid, its title, its inbox
socket and protocol version, its free-text activity, its model, its
instance id, and its place in the spawn tree. There is no locking. The
one policy that stands in for it is that `Load` removes any record whose
pid is dead, rather than skipping it: pi's headless Claude Code bridge
writes one such record per turn, and nothing else would ever clean them
up. When two records name one pane the outer agent wins regardless of
timestamp, because pi runs Claude Code inside its own pane and the inner
one's hooks would otherwise fight pi's reports.

That deletion has a consequence that shaped the rest of the design: with
a sidebar running, `Load` is called every 100ms, so the record of a dead
agent is gone within a tick of its death. Anything that has to reason
about an agent after it has died cannot read its record, because there
will not be one.

**Window options, for facts that must survive kido's own cleanup.**
`kido spawn` sets `@kido_subagent` on the window it creates. The option
lives in the tmux server: nothing races it away, it names a window that
exists now rather than a pane id some later server may hand to somebody
else, and it can only ever be on a window kido itself made. It is the
sole thing that makes a window reapable. Its value is free text for a
human reading `show-options -w`, of which one token, `run=<id>`, is
parsed back out so a sweep can record an outcome for the run whose
window it is closing.

**The runs directory, for facts that must outlive the process.** Under
`<state>/runs/<run-id>/`: the task text, a meta file fixed at spawn time
(window, pane, pid, cwd, model, tools, parent, depth), and once the run
has ended, an outcome. A run record is deliberately not a state record,
since a state record is deleted the moment its pid dies and a run record
exists precisely to survive that. `Load`'s scan only reads `*.json`
entries and skips directories, which is what keeps `runs/`, and the
inbox socket directory, and the wake marker, invisible to it. Nothing
may come to depend on that changing.

Two more files live beside the records. The `inbox/` directory holds
one socket per pi session, and is the one thing in the state directory
made `0700`: anyone who can write into it can impersonate an agent's
socket. The `wake` file is the staleness rebase marker described below.

## Identity

A session id is not a process identity. pi re-runs `session_start` on
`/resume` and `/reload`, and a session id can change under both, so a
child keyed to its parent's session id would look orphaned while the
parent was very much alive. A pid is not one either: pids are recycled,
and kido's liveness test (`kill(pid, 0)`) reads EPERM as alive, so a pid
reused by another user's process looks like a living parent.

So every pi process generates an opaque instance id once, at module
scope, and reports it on every status call. A child names its parent by
that instance, passed through the environment at spawn, and a parent
edge is matched on it and nothing else. The parent pid is still recorded
and still passed, but only as a cheap first check for the liveness poll:
ESRCH is a definite "gone", and anything else defers to whether some
live record in scope still reports the parent instance as its own. An
instance string cannot collide the way a recycled pid can, and it is
location-independent, which is what would let it survive a subagent
running somewhere other than this machine.

The instance is the one identity that is generated rather than read, so
it is the one the agent extension reads across the seam from the status
extension instead of computing itself; a second copy would be a second
id. Parent pid, parent instance and depth are read from the environment
by both halves independently, since two readers of a constant cannot
disagree.

## Reporting, and what is carried forward

`kido agent-status` builds a whole fresh record from its arguments on
every call, so a field the caller omits would blank unless kido carries
the previous value forward. Which fields carry forward is decided per
field, and by the flag's presence rather than its value:

- Title: an empty value keeps the old one, since an extension's
  coalescing may not re-send it.
- Inbox, protocol, activity, model: omitted keeps the old value, an
  explicit empty value clears it. `--inbox ""` is how an agent says its
  socket is gone, and a stale path would otherwise keep kido dialling a
  socket nobody listens on; `--activity ""` is how `set_status("")`
  clears the activity rather than being read as an omission.
- Instance, parent pid, parent instance, depth: never carried forward.
  The agent knows them from its own environment and reports them fresh
  on every call, which is cheaper than carry-forward and more robust
  than walking the parent chain, which fails as soon as one intermediate
  record is gone.

Activity is the one field a model writes directly into a state record,
so it is sanitised once, on the way in: control characters become spaces
and the result is cut at 256 bytes on a rune boundary. The sidebar
budgets one terminal line per row and `kido agents` prints a tab-separated
table, and defending each of those against a newline is more work than
refusing one at the single place a record is built from arguments. The
extension caps the same text too, but a model is free to ignore a schema
and any same-uid process can run `kido agent-status`, so the cap that
counts is kido's.

The extension coalesces reports: one whose key (status, title, activity,
model, ended, remove) matches the last one sent is dropped. Activity and
model are in the key because a `set_status` or a model switch that does
not change the status would otherwise be silently lost. The one report
that carries `--inbox` bypasses coalescing entirely, because another
handler can send an equivalent idle report while `session_start` is
still awaiting the socket bind, and kido would never learn the path.

## The inbox

A pi session that can take a prompt as a real user message listens on a
unix stream socket and reports its path. `kido inbox-path <name>` says
where: `<state>/inbox/<name>.sock`, absolute, with the directory created,
refusing a name with a separator or `..` and a path over the kernel's
`sun_path` limit. The path is kido's decision so that the extension does
not have to reimplement the state-directory precedence or guess the
length budget; a refusal means the session runs without an inbox rather
than listening where kido cannot dial. The name is the pi process's pid,
which is unique among live processes, so a leftover file at that path
cannot belong to a running listener and is always safe to unlink before
binding.

The wire protocol is one message per connection: connect, write the
payload as UTF-8 with no framing, half-close the write side so EOF ends
the message, read the reply, close. The reply is `ok` or `refused`. One
deadline of two seconds bounds the whole exchange, connect included,
because a listener whose owner is wedged with a full accept backlog
blocks in `connect()` before there is a connection to put a deadline on.
The agent answers as soon as it has read the message, so anything slower
is a wedged peer, not a busy one.

`ok` means the agent has the message and will see it at its next turn
boundary. That is the only acknowledgement level: `message_agent`
promises delivery, not action. Delivery into pi is always `followUp`,
which queues behind the work the user is watching rather than redirecting
the running turn the way `steer` would; when pi is not streaming the
message triggers a new turn immediately regardless, so one call covers
both cases with no window between a check and a send.

### v0 and v1

A v0 payload is raw prompt text, exactly as the inbox always took it. A
v1 payload is one JSON object carrying a version, a kind (`message`,
`ask`, `reply`, `notice`, `interrupt`, `stop`), an id, a sender, an
optional `replyTo`, and the text.

A payload counts as v1 only if it parses as a JSON object and carries
both `v` and `kind`. Anything else, including a JSON object missing one
of the two, is v0 text. The case that matters is a user prompt that
happens to be a JSON object: it must not be swallowed as a control
message. The rule is implemented twice, in Go and in the extension, and
both are driven from the same fixture table so they cannot drift.

The reverse direction is the one that bites. A new `kido message` talking
to an unupgraded extension would deliver an envelope's literal JSON as
the user's prompt. So the receiver advertises what it speaks, with
`--protocol 1` alongside `--inbox`, and a sender that sees no advertised
version sends v0 text for a plain message and refuses any other kind
outright, since a paste or a v0 payload has nowhere to carry a kind or an
id and silently downgrading an ask to a plain prompt would strip the
thing that made it one. `kido prompt` stays v0 forever: it is the
agent-agnostic path and has to keep working against Claude Code panes.

There is no protocol 2 for interrupt and stop. kido runs on one machine
with the binary and the extension upgraded together, so a version gate
would be ceremony; the v1 advertisement already refuses a receiver that
has never spoken an envelope, and for stop the escalation kills the pane
regardless of whether the request was understood.

The sender field is advisory. Trust is uid-scoped and enforced by the
inbox directory's mode; state records are `0644` files in a `0755`
directory, so any same-uid process can already write a record claiming
to be any agent, and a peer-credential check would buy nothing. That is
also why `kido message` offers no `--from`: the sender is whatever the
calling process's own record says, found by its pane, and a caller with
no record sends only its pane.

## Delivery, and when a paste is allowed

Two errors come out of a delivery attempt, and they mean different
things. `errInboxUnavailable` says nothing was sent: the path is empty or
unusable, the socket file is missing, or it is a stale socket a dead
process left behind. Every failure from the moment the connection is up
is reported as itself, because the message may already have arrived and
a retry would deliver it twice.

The paste fallback, which types the text into the pane with a bracketed
paste and a separate Enter, fires only on `errInboxUnavailable`. That is
what makes an agent with no inbox at all (Claude Code, or a pi whose bind
failed) reachable by `kido prompt` and by a plain `kido message`, and it
is the only reason the v0 path survives. A refusal (`errAskRefused`) is
not a delivery failure either: the question was read and deliberately
declined, and pasting it again would hand the target the same cycle it
just refused.

Non-message kinds never paste. A dead target that advertised v1 while it
was alive still passes the protocol check, because that check reads a
record written when it was alive; only the dial finds the socket gone,
and the fallback's answer to that would be to type model-authored text
at whatever shell the pane fell back to and press Enter. For a
subagent's completion notice that is a command line the model wrote,
run in its parent's pane. The rule for a dead parent is that there is
nobody to tell.

Two more refusals happen before anything is sent. A message to the
sender's own pane is refused, because `list_agents` reports the caller
alongside everyone else and a model picking a name off that list can
pick its own, which would hand it its own message back as a fresh user
turn. Invalid UTF-8 is refused, because the two delivery paths disagree
about it: JSON marshalling substitutes U+FFFD while a paste writes the
bytes through, and the same message would then arrive differently
depending on whether the target happened to have an inbox.

## Addressing

The tmux session is the visibility boundary. `kido agents` lists every
agent whose pane is currently in the caller's session, and `kido message`,
`interrupt` and `stop` resolve their target within that same scope. A
target that exists but sits in another session is reported as such, not
as "not found"; an ambiguity out there is reported as an ambiguity rather
than as a single match with an empty id.

Within scope the rules run in order, and each errors on its own
ambiguity rather than falling through to guess with a different rule:
an exact case-insensitive name, then an exact session id, then a unique
id prefix. The name a session is matched by is the same one `kido agents`
displays for it, its reported title falling back to its pane's title, so
a name read off `list_agents` can always be resolved back. Refusal over
guessing is the stance throughout: `replyTo` is never inferred even when
exactly one ask from the target is pending, because guessing wrong does
not fail safe, it resolves the wrong pending ask on the far side and
hands one question's answer to another. `ask_agent` resolves the target
once in the extension and passes the resolved id to `kido message`, so
a second resolution inside kido cannot disagree with the first.

## Ask and reply

An ask blocks the calling tool until the answer arrives on the asker's
own inbox. That is why there is no `kido ask`: a short-lived CLI process
has no inbox to receive a reply on, only a long-lived extension does. The
extension sends the question with `kido message --kind ask`, assigning
the envelope id itself so it can register a waiter before the send, and
the answer comes back later as a separate `reply` envelope naming that
id. The wire `ok` for an ask means received, not answered: a model turn
takes minutes and the two-second inbox timeout must not cover it.

Expect one full turn of latency, not a round-trip. Delivery is
`followUp`, so the question waits for the target's whole current turn,
and the answer requires its model to decide to call `message_agent`. The
default wait is five minutes. A timeout is therefore not a failure of
the question: a reply arriving after its asker gave up is delivered to
the model as an ordinary message rather than dropped, and the ask id
stays a valid correlation for that.

### The cycle edge

A subagent may not ask an ancestor, so the parent stays free to
orchestrate; that rule is walked on the extension side from the parent
field `kido agents` reports. Asks still run parent to child and between
peers, so two peers can block on each other. The rule for that is kept
in memory, in each extension: an inbound ask from a session this one is
holding an outstanding ask to is answered `refused` on the wire, and is
not delivered to the model at all. An on-disk edge set would survive
`kill -9` on the asker and block every future reverse ask permanently.

The edge set is the map of waiting asks itself, not a count kept beside
it: an edge to a target exists exactly as long as an ask to it is
waiting, so there is no second tally to fall out of step. A reply-shaped
envelope that matches nothing does not drop a waiter, which is what
makes a failed reply leave the edge in place. The waiter is registered
synchronously before the `await` that starts the send, so an inbound ask
dispatched while the outbound send's subprocess is still running already
sees the edge; and settling a waiter is idempotent, so a late "could not
deliver" after a reply has already raced in is a no-op.

### When the inbox goes away

A waiter with nowhere for its answer to land would sit out its whole
timeout on a socket nobody listens to, holding its cycle edge shut for
just as long. So the inbox going away releases every waiting ask, but
only when it is not coming back: a `/reload` tears the inbox down and
rebinds it at the same pid-named path, and a wait genuinely survives
that. The status extension therefore does not release waiters from its
own teardown; it tells the agent extension when a rebind has failed, and
on shutdown.

The shutdown case rests on ordering. `session_shutdown` closes the inbox
and runs the agent extension's synchronous prefix (stop the parent poll,
release every waiter) before its first `await`, so there is no moment at
which the session is on its way out but its inbox still looks open. That
is what lets `ask_agent` use a synchronous "is the inbox open" check,
with no `await` between the check and registering its waiter, as its
whole test for "this session is shutting down". A momentarily closed
inbox during a reload that goes on to succeed is refused the same
conservative way.

## Spawning

`kido spawn` creates a detached window in the caller's own tmux session,
running `pi` by default, with the child's place in the tree and its task
in the environment. Three `new-window` flags are load-bearing: `-d` so
the caller's turn is not yanked to the new window; `-c` because the child
otherwise starts in the session's default directory rather than the
parent's; and `-e` for each variable, because `new-window` runs its
command with the server's and session's environment, not the caller's,
so nothing arrives any other way.

The task is never a command-line argument. It is model-authored text of
arbitrary shape, and a tmux command line nests three parsers that no
escape survives. It goes in a file inside the run's own directory, named
in `KIDO_AGENT_TASK_FILE`, which the child reads on `session_start` and
delivers as its first user message, the same way an inbox prompt is
delivered. At the tool boundary the task is text: `spawn_subagent` hands
it to `kido spawn` on stdin, and kido is what decides it becomes a file,
so another backend could write it inside a sandbox instead. The window
name is model-authored too and does go on the command line, so it is
refused if it contains any character the setup-tmux path check refuses,
and refused over 64 bytes rather than quietly mangled.

### The depth ceiling is derived

Nesting is capped at two levels below the root. The caller's `--depth`
is accepted, because the extension sends it for a cheap early refusal
that skips a subprocess, but it is a claim the caller makes about itself
and is never consulted for the child's depth: a caller already at the
ceiling could pass a smaller number and spawn without limit, and the
ceiling would only ever be as real as the caller chose to make it. kido
reads the caller's own last-reported record, found by `$TMUX_PANE`, and
sets the child's depth to one more than that. A caller with no record
at all, a human at the CLI or an agent that has not reported yet, is
treated as depth 0. That is the same trust decision `Load` makes for
every other same-uid record, and it can only make a spawn's ceiling
stricter than a real record would, never looser. An explicit negative
`--depth` is a wrong value, not an omission, and is refused.

### The run id is the child's session id

`kido spawn` mints the run id and, when the command is literally `pi`,
inserts `--session-id <run-id>` after it, which pi documents as "use
exact project session ID, creating it if missing". Restarting a finished
run is `pi --session <run-id>` and forking it is `pi --fork <run-id>`,
with no bookkeeping mapping one id to the other because there is only
one id. pi sessions are project-scoped, so `kido runs <id>` prints those
commands with `cd <cwd> &&` in front, the only way to make the printed
line copy-pasteable from anywhere; run from the wrong directory, pi asks
whether to fork into the current project instead of just working. The
id also goes into `KIDO_AGENT_RUN_ID` unconditionally, because a child
that is not pi (every e2e fake) has no session of its own to learn it
from and still needs it to report an outcome.

### Failure leaves a record

The run directory and task file are created before the window, because
the child may read its task the instant tmux starts it, and because a
directory that already exists is what lets a spawn that then fails
record that as an outcome. If `new-window` fails, the meta is written
and the run marked `failed` with the error, so `kido runs` does not show
a run with no window and no explanation. If the window is created but
the mark cannot be set, the window is killed and the run marked `failed`
the same way: an unmarked window is one no sweep will ever collect, and
a window nothing can ever find again is worse than no window at all.

## Window lifecycle

A spawned window has `remain-on-exit` turned on, so it survives its own
command exiting: both for the read window the linger gives the user and
so a sweep has something to find if the linger never ran. The option is
set by a second tmux call after `new-window`, and a command that exits
fast enough beats it every time, so a child that fails immediately loses
its window and its last screen. The run record survives and still reads
as `died` from the pid; every fix costs more than the gap.

**The linger helper.** Before exiting, a subagent spawns a detached
`sh -c 'sleep N && exec kido close-window @id'`, so it outlives the pi
process whose event loop is gone by the time the sleep would fire. The
helper refuses a window that is some client's current one, because the
user may have switched there to read the subagent's last screen, and a
session's only window, because closing that destroys the session and
detaches every client. It checks once and does not retry: the window it
leaves is a marked window with a dead pane, which is exactly what the
sweep collects on a later pass.

**The sweep.** `reap.Sweep` runs on the sidebar's own poll, every tick,
and is what actually collects a subagent window in a live session; `kido
reap` is the same function by hand, for a test or an operator. It runs
from the snapshot goroutine and deliberately not from `Load`: `kido
prompt` and the popup picker call `Load` too, and a state-directory read
has no business closing a window as a side effect. Several sidebars may
sweep at once, one per client, and each asks tmux to close windows
another already closed; that costs an error nobody reads.

A sweep decides from tmux, not from kido's state, and this is the part
that had to be learned the hard way. An earlier design read the record
of a dead subagent and closed the window its pane was in. It cannot
work: with a sidebar running the record is gone within a tick of the
process dying, long before any sweep sees it. And a pane id is not an
identity: pane ids restart at `%0` on every new tmux server while state
files are global and outlive it, so a stale record names a pane somebody
else holds now. Before the mark existed, a sweep closed a plain shell
window that was nobody's subagent.

So there are two rules, and both may only close a window carrying the
mark. First: every pane of a marked window is dead and has been for the
linger grace. This reads no record at all. Second: a live subagent whose
parent is gone is cancelled by closing its window, a forced stop rather
than the graceful one the child's own poll asks for, but the only lever
a process outside pi has. This one needs the records, since nothing in
tmux knows who spawned whom, and the mark is what keeps a stale record
naming a recycled pane id from closing an unrelated window. A record with
no parent instance is a root agent and nobody's to cancel. Neither rule
closes a window that is any client's current one or a session's last
window; nothing is lost by waiting, since the sweep runs again next tick.
A split window is finished only once all of it is.

**The screen capture.** The sweep is the only thing that ever sees a
marked window's dead pane before closing it destroys that screen for
good, so it is also where a crash gets its one chance at a diagnosis: for
every window the sweep is about to close, it saves each pane's visible
screen plus a bounded amount of scrollback (`tmux.CaptureScreen`) to that
run's own directory, before the caller actually closes the window -
`internal/subrun.WriteScreen` writes `<run-dir>/screen` temp-then-rename,
the way `state.Record` writes a state file, and last writer wins. This is
deliberately not `RecordOutcome`'s O_EXCL discipline: an outcome has
precedence to defend (`stopped` written before `completed` must not lose
to it), but two screen captures of one window do not - rule 1's panes are
already dead and frozen, so both captures read the same thing, and rule
2's pane is still live, so a later capture is only ever more complete,
never a worse answer competing with a better one. O_EXCL here would also
have permanently stranded `kido spawn --resume`: nothing besides a sweep
ever writes this file, so a first attempt's screen would outlive every
subsequent attempt with no way to write a fresh one. `kido spawn --resume`
clears it instead (`subrun.ClearScreen`, alongside `ClearOutcome`), so a
run mid-second-attempt shows no screen rather than the first attempt's
stale one. `kido runs <id>` prints it when present, since a screen nobody
can reach is not a diagnosis. Capture is not gated on how the run ended:
rule 2 closes a window whose subagent never got to record anything, and
even a clean exit's last screen can be worth reading, so every window the
sweep closes gets a capture attempt, and the outcome guess (Died, or
whatever was already recorded) is a separate question from whether there
is a screen to go with it. Losing a screen is always better than leaking
a window, so a capture-pane error or a losing race never stops the window
from being closed; the byte cap
(`internal/reap.maxScreenBytes`, far smaller than a task's 1MB and
comfortably larger than an activity line's 256 bytes) exists because a
wedged agent's scrollback has no size limit of its own, and truncation
keeps the tail, on the theory that whatever a crash has to say, it said
last.

The grace is the same 30 seconds on both sides, read from one environment
variable, because the helper and the sweep run in different processes
and a sweep with a shorter idea of the linger would simply close the
window first.

**Parent death.** The child's pi is a child of the tmux server, not of
the parent's pi, so no OS parent-death signal reaches it. It polls every
five seconds: `kill(pid, 0)` first, where ESRCH is a definite answer
given without a subprocess, and otherwise whether its own entry in `kido
agents` still resolves a parent, which a recycled pid cannot fake. kido
being unavailable is not evidence of anything and never shuts a session
down. On a dead parent the child calls pi's `shutdown`, through the same
teardown as a normal exit.

## Idle self-exit, and resuming a run

A subagent that finishes a turn and goes idle used to just sit there:
nothing told it "done forever" from "waiting for follow-up", so it held
its window, its pi process and its model context until someone quit it,
stopped it, or its parent died. Spawn five and there are five idle
agents. The fix is to reap it: a subagent idle for `KIDO_IDLE_EXIT_SECONDS`
(30, matching the window linger's own default, but see below for why the
two are not one figure) calls pi's own `shutdown` on itself.

**One signal, reused.** The timer arms from the same `agent_settled` /
`ctx.isIdle()` event Phase 12's turn notice already trusted for "the turn
is truly over" ("Notifying the parent", above) - not a second,
independently timed one. It arms on *every* settle, not only one with new
result text to report: a settle with nothing to say is still idle. Any
sign of new work - `turn_start` and the rest of the `running` family, or a
message about to be delivered to the model - cancels and restarts it, so
this is idle-for-30s, not 30s-since-the-first-settle: a child being
actively used stays up.

**Only a child arms it**, gated on `KIDO_AGENT_PARENT_INSTANCE` exactly as
the turn notice is: a root session - a human's own interactive pi - must
never reap itself. `spawn_subagent` also takes a `keepAlive` boolean,
plumbed through as `KIDO_AGENT_KEEP_ALIVE`, for a deliberately long-lived
helper that opts out of self-reaping entirely.

**A window a client is looking at is not reaped out from under them.**
Before shutting down, the timer asks `kido window-focused <id>` - the
same `tmux.WindowFocused` test `kido close-window` and the sweep already
share - and, if focused, simply re-arms rather than giving up, exactly as
the linger helper re-checks on its own next pass; the window is collected
once the user looks away.

**The outcome is `completed`, not `stopped`**: nobody intervened, the
child finished its own work on its own terms. `ctx.shutdown()` runs the
same `session_shutdown` handler a normal exit does, so `recordOwnOutcome`
sees `isRunEnding(undefined)` (a plain shutdown carries no reason) and
records `completed` off `host.status() === "idle"`, same as any other
quit.

**Two 30-second figures stack, and are not one number.** Idle self-exit
is entirely inside the child's own pi process; only once it actually
shuts down does the window even become eligible for the linger helper's
own, entirely separate 30 seconds ("Window lifecycle", above) before a
sweep may close it. A child can therefore sit for up to a minute, total,
between its last turn and its window disappearing. Nobody may fold these
two into one knob: they run in different processes, guard different
things (a live child deciding to leave, versus a dead child's corpse
waiting to be swept), and read from different environment variables.

**`kido spawn --resume <run-id>`.** Once idle children are routinely
reaped, resuming one becomes the normal way to keep working with it, and
a bare `pi --session <id>` (what `kido runs` used to print) comes back an
orphan: no parent edge, no `@kido_subagent` mark, not a descendant for
stop/ask scoping, and - worse - a *second* run record, since `kido spawn`
normally mints a fresh run id from the command line it is given and a
bare `pi` was never given one at all. `--resume` instead runs through the
identical window-creation path (`tmux.NewWindow`, the mark) a fresh spawn
uses, but:

- launches `pi --session <run-id>` (not `--session-id`, which would
  create one if missing - the point here is that it must already exist);
- continues the existing run record rather than creating a second one:
  its task, its history and its id stay, since `subrun.ReadMeta` is what
  supplies the window's name and cwd and nothing about the task file or
  its `delivered` marker is touched;
- writes the *new* window, pane, pid and parent edge into that same meta
  file - `WriteMeta` is only documented as being called once by a fresh
  spawn, not enforced to be, and a resumed run's living facts have
  changed;
- clears any outcome already recorded. This is the one place outside
  `RecordOutcome` allowed to touch an outcome at all, and it does not
  weaken the O_EXCL "first writer wins" rule: that rule exists so that
  several *exit paths racing to describe the same ending* cannot clobber
  each other, and a resume is not a race between exit paths, it is a
  deliberate act, by a human or an agent, asserting the run is alive
  again, running strictly *before* any of those paths have anything to
  say about this new attempt.

It refuses an unknown run id (`ReadMeta` fails), a run that is still
alive (`EffectiveOutcome`'s `ok` is false exactly when nothing has been
recorded and the pid is live - resuming a live agent makes no sense), and
a run whose pi session file is gone (`piSessionDir`, mirroring pi
0.85.1's own `getDefaultSessionDirPath`: `PI_CODING_AGENT_SESSION_DIR` if
set, else `<agentDir>/sessions/--<cwd, its slashes and colons dashed>--`;
it does not walk pi's own per-project `sessionDir` setting, a known gap).
The depth ceiling still applies, derived from the *resumer's* own caller
record exactly as a fresh spawn's is - resuming does not bypass it.
`--parent-pid`/`--parent-instance` are optional for `--resume` alone (a
fresh spawn still requires them): omitted, they default to the caller's
own reported pid and instance, the same source depth already reads, so a
human with no state record resumes into a parentless (root-like) session
that will not self-reap, while another agent resuming becomes the run's
new parent without having to be named up front - which is what lets `kido
runs <id>` print a single, parent-free `kido spawn --resume <id>` line
that works from anywhere `cd`'d into the run's own cwd, rather than a
line baked with somebody's identity that may no longer be the right
resumer by the time it is run. `pi --fork <id>` stays the bare command it
always was: forking into a standalone session, with no parent edge or run
record of its own, is a different, legitimate thing.

## Interrupt and stop

Two verbs, deliberately distinct. `interrupt` aborts the target's current
turn and leaves it alive and idle, ready for a corrected instruction; pi
answers it with `ctx.abort()`. It has no escalation, because aborting a
turn is meaningless to anything that cannot receive it and there is no
destructive fallback that makes sense for "redirect this, do not kill
it". `stop` ends the session through the same shutdown path a normal
exit takes, so there is no second teardown.

**Scope.** A caller that is itself an agent may only reach its own
descendants; a human at the CLI, who has no state record, may act on
anything. This is not a security boundary, it exists so a confused peer
cannot reach into a part of the tree it does not own. It is enforced
twice on purpose: kido checks it before sending, using its own view of
the tree, and the receiving extension checks it again on receipt, using
its own `list_agents`, because the sender field is advisory and a session
must not act on an envelope just because it arrived claiming to be from
an ancestor. The receiver recognises a human by the pair, an empty sender
session and a pane no agent occupies, so a confused agent has to get two
things wrong at once to be mistaken for one. Both walks share the
ancestor chain `ask_agent` walks in the other direction, and both refuse
a self-edge outright rather than walking for it, so a corrupt record
naming itself as its parent cannot let a session stop itself.

**Escalation.** A wedged child will not answer; a real pi has sat alive
and blocked for hours after a laptop slept and its provider connection
died. So `stop` sends the request and then polls the target's own record
for up to five seconds, and if it is still there, kills its pane. A
request the target did not agree to (held the connection open, answered
badly, or refused on its own scope check) is a reason to escalate, not to
give up; an earlier draft that returned the send error left stop failing
outright in exactly the case it was written for.

The kill is of the target's pane, not its window, because a stop was
asked against one agent and killing the window would take every
bystander pane sharing it. It refuses a pane that is the only one in its
session's only window, since losing it ends the session, and `--force`
does not buy that. It does not refuse a focused window, and that
difference from the linger and the sweep is deliberate: those act on
their own initiative and must not take a screen from a user who may be
reading it, while a stop was asked for by name.

**No inbox means no quiet stop.** An agent with no inbox cannot be asked
anything, so stopping one degrades straight to killing its pane, which is
destructive and irreversible. That is the opposite of the paste fallback,
where degrading silently was the point because there was always a gentler
way. Here there is none, so it requires `--force`. A recorded socket
nobody answers (`errInboxUnavailable`) is functionally no inbox at all
and carries the same requirement.

## Notifying the parent

A subagent's completion notice used to be wired to `session_shutdown`
alone. That is wrong for the common case: an interactive pi does not
shut down when a turn ends, it goes idle and waits for more input, so a
subagent that took a task, answered it and settled told its parent
nothing until its process eventually exited - never, for a session that
stays open to take more work. `spawn_subagent` is delegation; a parent
that has to poll `kido agents` to learn a child answered defeats the
point of the notice existing at all.

So there are two notices, not one, and they read differently on purpose.
`sendCompletionNotice` (`session_shutdown`, gated on `isRunEnding` as
before) still means the run itself has ended. `sendTurnNotice` fires on
every *settled turn* - `agent_settled` with `ctx.isIdle()` true - and
means the child is still alive, resumable, and may yet be given more
work; its wording ("finished a turn", never a status in parentheses)
keeps a parent from reading it as the run being over. It fires again for
every later turn a follow-up produces: each is its own news, not a
repeat.

**Content, not just a heads-up.** The notice carries the child's own
last answer, extracted from `agent_end`'s `event.messages` (the last
assistant message with no error) since `agent_settled`'s own event
carries no message data at all. Capped at 4000 bytes - larger than the
activity cap, since this is the child's actual work product and not a
UI label, but far smaller than `MAX_PROMPT_BYTES`, since it is spliced
whole into the parent's next turn as a followUp message rather than
transported as an arbitrary payload.

**One trigger, not two.** pi-subagents, which drives its own hand-rolled
child session loop in-process, tracks two independent signals for "the
child is done" and takes whichever arrives first, because it needs a
signal that survives a stuck hook in its own machinery. This extension
only observes pi's public lifecycle, where `agent_end` fires once per
low-level run and pi's own docs say explicitly that pi "may still
auto-retry, auto-compact and retry, or continue with queued follow-up
messages" afterward - it is not a completion signal by itself. Reading
pi 0.85.1's own bundle confirms `agent_settled` is emitted exactly once,
in the same `finally` block that ends that retry/compaction/follow-up
loop, which this file already trusted for "idle" before this change. A
second, independently timed trigger here would race that authoritative
signal instead of covering a real gap in it, so content and completion
come from two different events for a real reason (one has the text, the
other has the truth), but only one of them decides a turn is over.

**No notice with nothing to say.** The same source confirms
`agent_settled` is only ever emitted from inside the loop a real
`prompt()` call starts, so a settle at session start, before any task has
run an agent loop at all, cannot fire it - not merely "is assumed not
to", but structurally cannot. The extension still keeps its own guard
for it: the last captured result text is consumed (reset to empty) the
moment it is handed to the notice, so a settle with nothing new to report
sends nothing.

## Run outcomes

An outcome is written by whichever code is positioned to know how the
run ended. `completed` and `failed` are the child's own verdict, reported
through `kido run-outcome` from the same shutdown handler that sends the
parent its completion notice: `completed` if the session ended idle,
`failed` for anything else, since that is as finely as kido can tell from
the outside. `run-outcome` accepts nothing else, because `died` and
`stopped` are kido's verdicts from the outside and a model-authored
process does not get to claim them about itself, for the same reason
there is no `--from`. It is its own verb rather than a flag on the status
report because any spawned command can end, including one that never
reported a status in its life. `died` is written by a sweep closing a
marked window with no outcome recorded: the child never got to say
anything. `stopped` is written by `kido stop`.

**Written once.** `RecordOutcome` opens with `O_EXCL` and refuses to
overwrite. Several exit paths race to describe the same run, and the
first to observe it ending is definitionally the true story; a later,
cruder guess must never clobber it. That single rule decides the
ordering everywhere else:

- `stopped` is written the moment the stop request is away, before the
  wait, so it wins deterministically against the child's own `completed`
  a moment later for a reason that was never its own idea. It is not
  written a line earlier, because every refusal stop has leaves the run
  running, and an outcome written before a refusal could never be
  corrected. On the escalation path it is written after the last-pane
  guard and before the kill, for the same two reasons.
- A `/reload` must not record `completed`. pi fires `session_shutdown`
  for a reload too, with the session carrying straight on in the same
  process; an outcome written there reports a live run as finished, and
  the run's real ending, an hour later, would then be silently discarded.
  The same gate keeps a reload from telling the parent the child finished
  and from scheduling the child's own window to be closed out from under
  it.
- `kido runs` guesses `died` for a run with no outcome and a dead pid,
  and never persists the guess: a read-only report should not write on
  every invocation, and only a sweep actually closing the run's window
  earns the right to write that down. The guess inherits the liveness
  test's biases (EPERM reads as alive, and a pid recycled after a reboot
  reads as alive), both of which push toward showing a long-dead run as
  running; neither can invent a `died` for a run that is alive. A stale
  running row is the wrong answer kido can afford.

The task file is never deleted; it is the record of what the run was
asked to do. A sibling `delivered` marker, written only after the read
has succeeded, is what stops a `/reload` from delivering the task twice;
a task that failed to read stays eligible next time rather than being
marked delivered and never shown. There is no retention: a run record is
a pointer to a pi session file that pi itself never prunes, so deleting
the pointer would not free the space a cleanup would be chasing. A run
whose outcome is never written just sits there, and `kido runs` still
has something to say about it. The captured screen ("The screen
capture", above) is the one exception to "a run record is a pointer": it
is copied bytes, not a reference to something kept elsewhere. Its cap is
chosen small enough that this does not matter - a few KB in the common
case, 64KB at the ceiling - next to the pi session file the run already
points to and that pi keeps forever regardless, which for any real
conversation dwarfs it.

## Heartbeat and staleness

An agent can be alive and wedged. kido models only running and gone: a
wedged subagent sits reporting `running` forever, its pane is not dead so
no sweep touches it, and a parent blocked in `ask_agent` burns the whole
five-minute timeout finding out. The signal is the record's report time,
but status reporting is not a heartbeat by itself. The extension
coalesces identical reports, and `agent_start`, `turn_start`,
`tool_execution_start` and `tool_call` all send the same `running` key,
so only the first reaches kido and the timestamp marks the start of the
turn, not the last sign of life. A turn has no upper bound, so no
threshold fixes that: a healthy pi minutes into one long turn would
cross it, and a parent blocked in `ask_agent` reports nothing itself and
would mark itself stalled before a busy child had a chance to answer.

So while the reported status is `running`, the extension re-sends it
every thirty seconds, bypassing the coalescing key, on an unref'd timer
that stops the moment the status leaves `running`. That makes the
timestamp a real last-seen heartbeat, and `state.Stalled` derives
"claims running but has not reported in three minutes" from it, the way
a shell's state is derived from timestamps rather than read from a flag.
It is never a new status value: the status vocabulary is what an agent
reports about itself, and a wedged agent by definition reports nothing.
It is never true for anything but `running`; idle and waiting are
legitimately quiet. Three minutes is six missed heartbeats, a margin
against a dropped or delayed report rather than against turn length, and
it leaves most of an ask's default timeout for a genuinely busy target.
`ask_agent` reads the stalled flag off the agent list it already fetches
and refuses a stalled target immediately.

The heartbeat changes one field on every tick with nothing else about
the session changing, and the sidebar compares records to decide whether
to redraw. It therefore compares sessions with the timestamp zeroed, so
a heartbeat-only change draws nothing; the one thing the timestamp is
still allowed to drive on screen is the stalled indicator, and a
separate check reads it directly, off kido's own clock, so a session
crossing the threshold on an otherwise quiet tick is still redrawn.

### A sleeping machine is not a hundred wedged agents

Staleness compares now against a wall-clock report time. A machine that
sleeps advances wall clock without advancing any agent's work, so on
wake every running agent is over the threshold at once, before any has
missed a real heartbeat. The sidebar's `!` would self-correct, but
`ask_agent` refuses a stalled target, and a model told its child is
stalled will stop it, so a closed lid could cascade into killing a
healthy tree.

The sidebar is the only thing in kido that ticks continuously, so it is
the only thing positioned to notice a gap. It compares two readings
taken across one tick: the wall clock's account of the interval against
the monotonic clock's account of the same interval. Go's `time.Sub` uses
the monotonic reading when both operands carry one, and on both macOS
and Linux that reading does not advance across a suspend. A tick that
was merely slow for an awake reason advances both readings together;
only a suspend leaves the monotonic one behind. The wall account
outrunning the monotonic one by more than five seconds is a sleep. The
readings must be raw `time.Now()` values: anything round-tripped through
`Round(0)`, `Unix()` or JSON has lost its monotonic reading, and the
subtraction silently falls back to wall clock for both terms, so the gap
reads as zero rather than being caught wrongly.

On detection the sidebar records the wake moment in the `wake` file in
the state directory, only if newer than what is already there, since two
sidebars racing to record roughly the same wake must not let the one that
writes second clobber the other with an older value. `state.Stalled`
then measures its threshold from the later of the report time and the
recorded wake. That is not weaker, just later: an agent that really is
wedged is still caught, one threshold after the machine woke instead of
the instant it did, and an agent that reports again after the wake is
judged on its own fresh timestamp as if nothing had paused. The marker
is on disk rather than in the sidebar's memory because `kido agents` is a
fresh process per call, with no tick of its own, and it is what
`ask_agent` shells out to; both have to reach the same verdict without
pi's extension knowing anything about sleep.

What this does not cover: a session with no sidebar running has nothing
to notice the gap, and an ask against it is back to the original flaw.

## Two extensions, and the seam between them

pi's support is two extensions installed together. `kido-status.ts` is
the status report, its coalescing, the heartbeat, the instance id, and
the inbox server with plain v0 delivery; the inbox is status-side because
it predates all the agent work and exists so `kido prompt` can hand a
prompt to a session nobody is typing into. `kido-agents.ts` is the tools,
envelope dispatch beyond a plain prompt, the ask bookkeeping and cycle
edge, task delivery, the turn and completion notices, outcome reporting,
and the parent-liveness poll. They are two files because they are two jobs, and
either loads alone and degrades: without the agent half an envelope's
text is delivered as a plain prompt, without the status half every tool
reports kido as unavailable.

The inbox is the one thing that could not simply be split: the agent
half needs it to dispatch what arrives and to refuse an ask when there is
nowhere for the answer to land, and it is one socket, with one coalescing
key and one last-reported status beside it, none of which may be
duplicated. So the two halves meet at a pair of slots: the status half
publishes a small host of accessors (the kido path, the instance id, the
session id, title, activity and status, whether the inbox is open, and
the shared `deliver`, `runKido` and `spawnDetached`), and the agent half
publishes its hooks.

**The slots are on `globalThis`, keyed by a `Symbol.for` name, and that
was measured rather than reasoned about.** The obvious argument, that ES
modules are singletons per resolved path so an import of the neighbouring
file is the module pi loaded, is false for pi: each extension is evaluated
in a module registry of its own, so `kido-agents.ts` importing a runtime
value from `kido-status.ts` produced a second evaluation of that file,
under the identical URL, with its own module scope and its own generated
instance id. Module-scope slots left each half holding a copy of the
other that no session had ever started, and `list_agents` in a real pi
answered `[]` while every unit test passed. `globalThis` and the
`Symbol.for` registry are shared across those evaluations, also measured.
`kido-agents.ts` consequently imports nothing but types from
`kido-status.ts`, which type-stripping erases, and declares the same
symbol and slot shape itself.

**There is no load-order assumption.** pi discovers extensions in a
directory and the order is not kido's to choose, but every factory runs
before any `session_start`. Neither slot is read at factory time: each
half writes its own slot and reads the other only from inside an event,
a tool call or a hook, by which point both factories have long since run.
Tools register unconditionally at factory time and no-op at call time
until a session has resolved kido and a session id, because pi may run
the factory in invocations that never start a session; resource lookup
belongs in `session_start`.

**The hooks exist because ordering within one lifecycle event is
load-bearing**, and nothing says pi runs two extensions' handlers in any
particular order. The status half calls the agent half's hooks at exact
points in its own handlers: the session context is captured first thing
in `session_start` so a `/reload`'s fresh context replaces the old one
even in a session with no kido; the parent poll and task delivery run
after the inbox is bound (so a task's first turn can already be answered)
and before the first report (which is what carries `--inbox`); on
shutdown the outcome and the completion notice go out after the inbox is
down and before the removal report, so kido still resolves this session's
parent edge and window while they run; and a turn notice
("Notifying the parent", above) goes out from `agent_settled`, driven
through the same hook mechanism rather than the agent half registering
its own `pi.on("agent_settled", ...)` handler, for the same ordering
reason.

`runKido` is asynchronous, via `spawn`, never `execFileSync`. A blocking
call parks the whole process for as long as kido takes, up to five
seconds for a slow ask or message, and while parked the process's own
inbox listener cannot accept a connection; composed with the sender's
two-second timeout, a peer's message arriving in that window connects,
writes, and hits its own read deadline with the message never
acknowledged. On failure it yields the line kido printed on stderr, since
"no agent session matches" or "ask refused" is the only part a model can
act on, and a timeout is reported as a timeout rather than a failure,
because kido may already have done its work.

## The sidebar tree

A subagent's window is drawn indented under the *pane* of the agent that
spawned it, not after that agent's whole window: an orchestrator's
subagents belong to the orchestrator, and a shell sharing its window has
nothing to do with them. The anchor and the indent both come from the
walk, not from the depth the agent reports about itself: a subagent whose
parent is in another session, or gone, still reports depth 1, and used to
be drawn indented under whatever row happened to precede it. A window is
only nested under a pane the walk actually found an edge to.

Nesting inside a window cuts its bracket in two, since the ┌ ├ └ glyphs
join a window's panes into one column. The column is carried on down the
left of the nested rows with a │ stem rather than restarted, so a
three-pane window with a subagent hanging off its middle pane reads as
one bracket with an indented block inside it:

    ┌ zsh
    ├ ▌ orchestrator
    │ ┌ ▌ subagent
    │ └ zsh
    └ zsh

The stem stops where the parent has no rows left below it, so a child of
a window's last pane hangs free instead of dangling a line into empty
space.

The price is that a window hoisted under a parent's pane is no longer in
tmux's own window order: a subagent's window can sit above a
lower-numbered one, and a parent's later panes sit below a whole foreign
window. That is the trade, not a bug - the spawn tree is what the sidebar
is for, and tmux's order is still one ⇧↓ away. The walk also draws as a
root anything whose anchor row never appeared, for the same reason the
ordering emits what it missed: a dropped row is an agent nobody can see.

Both walks, the sidebar's and `kido agents`', share one parent-first
ordering that emits every item exactly once, tree or no tree. A cycle is
reachable through a bug in a reporting agent or a replayed old state
file, and a walk from the roots alone would never reach a ring; whatever
the walk missed is emitted afterwards as a root, so a nonsense edge costs
an item its place in the tree and nothing else. A self-edge is read as
"no parent". Siblings keep the order they arrived in, so `kido agents`
sorts by report time first, with the id as a tiebreak because two agents
reporting inside one clock tick would otherwise reorder between two calls
that saw the same state.

## Knobs

Every duration a test has to shorten is a package variable, and the ones
the e2e suite needs also read an environment variable, because that
suite drives kido as a separately built binary and only the environment
reaches it: `KIDO_LINGER_SECONDS` (read by both the sweep and the
extension's helper, so they agree), `KIDO_IDLE_EXIT_SECONDS` (the idle
self-exit timer, a different figure that stacks with `KIDO_LINGER_SECONDS`
rather than sharing it - see "Idle self-exit, and resuming a run"),
`KIDO_STALL_THRESHOLD_MS`, `KIDO_STOP_ESCALATION_MS`, `KIDO_HEARTBEAT_MS`,
`KIDO_PARENT_POLL_MS`, `KIDO_SPAWN_TIMEOUT_MS` and `KIDO_STOP_TIMEOUT_MS`.
The extension reads
its own once at module scope, so its test suite re-imports both files
under a cache-busting specifier to pick up a fresh value, and re-imports
both together, because a fresh half and a cached half would silently pair
up through `globalThis` and serve a session neither started.

## Known limits

- A subagent moved to another session with `move-window` is outside its
  parent's scope and cannot be asked.
- A blocked `ask_agent` holds a whole pi turn, for one turn of the
  target's latency.
- A child that exits before `remain-on-exit` lands loses its window and
  its last screen; only the run record remains.
- Pause detection needs a sidebar ticking when the machine sleeps.
- Everything assumes one machine: a shared filesystem for the state
  directory, the sockets and the task file; a shared pid namespace; and
  a kido binary beside every agent. Remote subagents would invert
  discovery and transport, and are deliberately not built for.
