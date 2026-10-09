# pi extensions: kido-status and kido-agents

Two extensions, installed together. pi 1.1.0 natively reports status
through OSC 7501 in interactive mode after terminal feature detection.
Its pane title, set through OSC 0/2, names the session in kido.
These work even without the kido extensions.

- **`kido-status.ts`** reports identity, activity and heartbeat to kido,
  and opens an *inbox* socket so kido can send a prompt into the session.
- **`kido-agents.ts`** is agent coordination: the tools below, dispatch of
  everything but a plain prompt arriving on that inbox, and the subagent
  lifecycle.

The two kido extensions are separate because they are separate jobs —
reporting identity and coordinating a fleet of agents — but they share
one session's inbox and one identity report, so they find each other at
load time through
a pair of slots on `globalThis.__kidoPiExtensionSeam`.
`kido-agents.ts` imports nothing but *types* from `kido-status.ts`, on
purpose: pi evaluates each extension in a module registry of its own, so
an ordinary import of the neighbouring file loads a second copy of it
rather than reaching the one pi started (measured against pi 0.85.1 —
list_runs answered `[]`). Load order does not matter either: pi may run
either factory first, and neither reads the other's slot until a tool call
or an event.

Install both. Either kido extension on its own still loads and
degrades quietly: without
`kido-agents.ts`, an envelope arriving on the inbox is delivered as its
own text rather than dispatched by kind; without `kido-status.ts`, the
tools report kido as unavailable.

The status half shells out to:

```
kido agent-status --agent pi --session <id> \
     [--activity <text>] [--model <name>] \
     [--parent-pid <pid>] [--parent-session <id>] [--depth <n>] \
     [--remove] [--inbox <path>]
```

kido reads `$TMUX_PANE` from the environment, so the command is spawned from
inside the pi process, which lives in the tmux pane.

The session id is the agent's identity: one live process holds it, and a
child names its parent by it. The first report of a session is the claim
on that id, and is the one call this extension awaits: kido exits 6 if
another live process already holds the session (two pi processes started
from one session file), and the extension then reports nothing more,
binds no inbox and tells the user once, naming the holder. `--parent-pid`, `--parent-session` and
`--depth` are read
once from `KIDO_AGENT_PARENT_PID`, `KIDO_AGENT_PARENT_SESSION` and
`KIDO_AGENT_DEPTH`, which `kido tool spawn_subagent` sets in a subagent's
environment (see docs/design-subagents.md, "What a child is given");
absent for a root session.

Those variables are inherited by anything the session starts, so they are
not on their own what makes this process a subagent: everything that acts
like one (kido-agents.ts's `ownRunID`) also requires this session's own pi
session id to equal `KIDO_AGENT_RUN_ID`, which only the child kido actually
spawned can satisfy. See docs/design.md, "The run id is the child's session
id".

## Install

Nothing to install: the `pi` in kido's bin directory runs the real pi with
`--extension` for both files where the package ships them, so a
pi started from a kido pane has them and one started anywhere else does
not. A copy in `~/.pi/agent/extensions/` from an earlier kido registers
nothing and can be deleted (docs/design.md, "One copy of each pi
extension").

To run them against a checkout, pass both (`-e` repeats); they need
not be in the same directory, but there is no reason not to be:

```sh
pi -e /path/to/kido-status.ts -e /path/to/kido-agents.ts
```

## Behaviour

pi's native root record (`id=""`, `app=pi`) supplies working, blocked,
done, idle and error. Native question, permission and auth dialogs report
blocked, but extension custom UI does not. pi supplies no OSC title or
progress; its pane title is "π - <name> - <cwd>". A message duplicating
the session name is omitted from the caption; other messages remain.
Terminal stop sends clear without app. `PI_PROGRAM_STATUS=0` disables
reporting and `=1` forces it.

`kido-status.ts` claims the session identity at `session_start`, reports
activity, model and inbox changes, and sends heartbeats when work starts
and every thirty seconds while work or compaction is active. At
`session_shutdown` it sends `--remove` and closes and unlinks the inbox.
Pi status, title and completion are not stored in State. A tracked pi
stalls only when the root record is working and its heartbeat is stale;
a bare pi has no heartbeat and never stalls.

- If `kido` is not on `PATH`, or pi is not running inside tmux, the kido
  extensions do nothing at all, quietly. OSC reporting is independent.
- The initial identity claim is awaited. Later reports are fire-and-forget
  (detached, `stdio: "ignore"`); their missing binary, non-zero exit or spawn
  error never reaches pi and never prints to the TUI.
- Identity reports coalesce activity, model, inbox and removal changes;
  heartbeats bypass that key. Native OSC reports coalesce separately.

## Inbox

The inbox lets something outside the session — kido, a script, another agent —
hand this pi session a prompt, so a session you are not typing into can still be
given work.

On `session_start` the extension binds a unix **stream** socket and reports its
path as `--inbox <path>` on identity reports. kido's agent tools send v1
JSON envelopes; the inbox also accepts plain v0 prompts. On
`session_shutdown` the socket is closed and the file unlinked.

Where to bind is kido's decision, not the extension's: it runs `kido get-inbox
<pid>`, which prints `{"path": "<state>/inbox/<pid>.sock"}` without creating
anything. The extension creates the state directory and then the inbox
directory mode 0700 immediately before binding. kido owns the state-directory precedence and the socket-path length
budget; if the path would not fit, `get-inbox` exits non-zero and the extension
simply runs without an inbox. Because the name is this pi's process id, no live
process can own a leftover file at that path, so one is unlinked unconditionally
before binding — no liveness probe, no fallback names.

Protocol — a client:

1. connects,
2. writes the prompt as UTF-8, with no framing,
3. half-closes its write half (`shutdown(SHUT_WR)`),
4. reads `ok\n`, and closes.

Plain v0 text is delivered by `kido-status.ts` itself — that is what the
inbox was built for, and it works with `kido-agents.ts` absent. A v1
envelope is handed to `kido-agents.ts` and dispatched by kind (below);
with no agent half loaded it degrades to its own text rather than being
lost.

```sh
# with socat; any client that half-closes will do
printf 'run the tests and summarise failures' | socat - UNIX-CONNECT:"$sock"
```

The prompt then arrives as a real user message, always sent with `deliverAs:
"followUp"`. That single mode is right in both states: `deliverAs` is only
consulted while the agent is streaming, where `"followUp"` waits for it to
finish all its tools — `"steer"` would redirect work the user is watching, which
an externally injected prompt has no business doing — and when pi is idle the
message is sent immediately and triggers a new turn.

An empty message is ignored, and anything over 1 MiB is dropped rather than
buffered. Like the status reporting, the inbox is silent and non-fatal: it never
writes to pi's stdout or stderr, and if it cannot be created or served, status
reporting carries on unaffected.

## Tools

These register unconditionally when `kido-agents.ts` loads, and simply do
nothing useful until a session has started and kido has been found:

- `list_runs()` runs `kido tool list_runs --json` and returns same-parent
  peers, the caller's parent and its own subagent and bash runs, excluding
  itself. A root sees other roots; a subagent sees its live siblings.
  All running own runs and the newest 20 ended ones are included, with
  kind, relationship, status and outcome. Autocomplete uses its live
  agent rows; internal sender, ancestry and reply validation uses
  `get-agent --context` so addressing stays session-wide.
- `stop_run(to, force?)` runs `kido tool stop_run [--force] -- <to>`,
  resolving run ids (unique prefixes of at least eight characters) before
  unambiguous running names. It stops descendant agent or bash runs,
  asking an agent to shut down with pane-kill escalation, or signalling
  a bash wrapper by pid. Bash needs no force flag and records
  "stopped by its parent". `steer_subagent` and `interrupt_subagent`
  remain agent-only; both `spawn_subagent` and `async_bash` return the
  run id to use with `stop_run`.
- `set_status(activity)` runs `kido tool set_status -- <text>`, free text
  capped at 256 bytes and shown next to this session in kido's sidebar,
  separate from the OSC 7501 state above. An empty string
  clears it. The extension keeps its own copy of the activity as well,
  since that is what every later `kido agent-status` report carries; the
  narrow command is what writes the record without touching anything
  else on it.
- `message_agent(to, message, replyTo?)` runs
  `kido tool message_agent [--reply-to <id>] -- <to>`, piping `message` on
  stdin. `to` is resolved by
  an exact, case-insensitive name, then an exact session id, then a
  unique id prefix, scoped to this tmux session; ambiguity is an error
  naming the candidates rather than a guess. An agent with an inbox gets
  it as a real user message; an identity with none
  gets it pasted into its pane instead. Either way kido's stdout reports
  which happened and to whom, and the tool relays that back verbatim.
  `replyTo`, when given, is what makes it a reply - kido derives the
  envelope kind from the flag - so the receiver's dispatch (below) can
  correlate it with a pending `ask_agent`. The message waits for the
  receiver's current turn to end, which the tool's own description says
  out loud and which is the whole reason `steer_subagent` exists.
  Descriptions are read by a model every time it chooses a tool, so a
  cost that decides between two tools belongs in one.
- `ask_agent(to, question, timeoutMs?)` runs
  `kido tool ask_agent --id <id> -- <to>`, then blocks the tool call until a
  matching `reply` envelope arrives at this session's own inbox - which is
  also why `kido tool ask_agent` itself only sends, and why it refuses a
  caller that has no inbox rather than delivering a question nobody
  could answer: a short-lived subprocess has no inbox of its own to
  receive the answer on (docs/design.md, "Ask and reply"). This tool is
  unaffected - the session binds an inbox before it can register a
  waiter at all. Default timeout is 5
  minutes; a timeout returns an error naming the ask's id, and a reply
  that arrives after the timeout
  still reaches the model, as an ordinary message (see Inbox dispatch,
  below). A wait also ends early, with a different error, if this
  session's inbox goes away under it - `session_shutdown`, or a `/reload`
  whose rebind fails - since an answer would then have nowhere to arrive
  and waiting out the remaining five minutes would only pretend
  otherwise. A `/reload` that rebinds normally does *not* end the wait:
  the socket is named after the pid, which does not change, so a reply
  still lands. Refused, before anything is sent: the target is an ancestor (a
  subagent may not block the parent that spawned it), is outside this
  tmux session, has no inbox (there is no way back over a paste), or is
  the caller itself. If this session already has an ask outstanding to
  the same target and that target asks it something in the meantime, the
  reverse ask is refused on the wire rather than let both sides deadlock
  (see "Cycles" below).

### Inbox dispatch

A payload's `kind` (see "Inbox" above) decides what happens to it, never
silently: every kind, recognised or not, reaches the model as some form of
text rather than being dropped.

- `message` - delivered as the user message it always was.
- `ask` - delivered with an explicit instruction to reply via
  `message_agent(to, message, replyTo=<id>)`. Refused instead (see
  "Cycles") if doing so would close a cycle.
- `reply` - resolves the matching `ask_agent` call, if one is still
  waiting on that id. If none is (the asker already timed out, or the id
  is foreign), the answer is still delivered, as an ordinary message -
  never dropped.
- `notice` - a "notification from X" row appears above the editor the
  instant the envelope arrives (a `ctx.ui.setWidget` line, outside the
  transcript entirely), before anything about it is delivered. The text
  itself is sent as a custom message and steered into the model's current
  turn (`deliverAs: "steer"`, as a `steer` envelope gets, rather than the
  `"followUp"` a message or an ask gets) rather than waiting for the turn
  to end - a finished child a
  parent does not know about defeats the point of spawning it. Once that
  message actually reaches the transcript it renders collapsed
  ("notification from X - ctrl-o to expand", full text behind pi's own
  ctrl-o toggle) and the widget row for it is removed - the widget is a
  stand-in for the wait, not a second copy, so a notice is shown once and
  delivered to the model once. See docs/design.md, "Notifying the
  parent", for why steer is safe here (it can only land between a
  completed turn's tool results and the next model call, never mid-tool)
  and why a message and an ask stay on followUp.
- `steer` - a course correction from an ancestor, delivered as a user
  message with `deliverAs: "steer"` so it joins the turn already running
  instead of queueing behind it, and labelled with its sender, since an
  instruction arriving mid-task would otherwise read as if this session
  had told itself. Refused on the wire for a sender that is not an
  ancestor, the same check `interrupt` and `stop` get and for the same
  reason: `from` is advisory.
- anything else - delivered anyway, marked as an unrecognised kind, so a
  typo or a newer kido talking to an older extension is visible rather
  than silently read as a plain message.

### Notices to a parent

A subagent no longer notifies its parent automatically. `notify_parent(summary)`
runs `kido tool notify_parent`, sent only when the model itself decides
its work is done - a settled turn can be triggered by anything, a peer's
`ask_agent` included, and only the subagent's own model knows whether a
given turn was actually its delegated work finishing. A subagent that
crashes or is idle-reaped without calling it tells its parent nothing;
the run record still holds the outcome (`kido runs`). A standing
instruction to call it, appended to the system prompt on every turn
(`before_agent_start`, gated on this being a subagent at all) is what
tells a spawned child this is its job - see docs/design.md, "Notifying
the parent".

### Cycles

Each extension instance keeps its outstanding asks in memory only: an
edge to a target exists exactly as long as an `ask_agent` call is waiting
on it. If this session is holding an ask to X and receives an ask from X
before that one resolves, it answers `refused` on the wire
instead of `ok` - a distinct answer kido's `deliverInbox` reports as its
own error, never triggering the send-keys paste fallback, since nothing
was mis-delivered. A refused ask is not delivered to the model at all.

- `steer_subagent(to, message)` runs `kido tool steer_subagent -- <to>`,
  piping `message` on stdin. It delivers a `steer` envelope: the text
  joins the turn the target is already running rather than waiting for it
  to end, which is what makes it the tool for a correction that is
  worthless once the work is done. Use `message_agent` when the message
  can wait. Descendants only, like the two below - see docs/design.md,
  "Steer, interrupt and stop".
- `interrupt_subagent(to)` runs `kido tool interrupt_subagent -- <to>`, which
  delivers an `interrupt` envelope; this session answers one addressed to
  it with `ctx.abort()`, aborting the current turn without ending the
  session.
- `stop_run(to, force?)` runs `kido tool stop_run [--force] -- <to>`,
  which delivers a `stop` envelope; this session answers one addressed to it
  with `ctx.shutdown()`, the same teardown a normal exit runs
  (`session_shutdown`: inbox closed, record removed, own window's linger
  scheduled). `kido tool stop_run` escalates to killing the target's pane
  if it does not go within a few seconds - see docs/design.md, "Interrupt and
  stop".
- `notify_parent(summary)` runs `kido tool notify_parent`, piping `summary` on
  stdin and naming no target: the command reads the parent out of
  `KIDO_AGENT_PARENT_SESSION` in its own environment. Refused, before
  anything is sent, for a session with no parent - a root session was not
  spawned, so there is nobody to tell, and both the tool and the command
  say so. Call this once, when the model itself judges its delegated work
  is actually done; nothing calls it automatically (see
  "Notices to a parent" above).

All three are refused - on the wire, as `refused` - unless the sender can
be verified as an ancestor of this session (the same ancestor walk
`ask_agent`'s own refusal uses, in the opposite direction): a caller may
only steer, interrupt or stop its own descendants, which is what the
`_subagent` suffix in those names means. `kido tool steer_subagent`,
`kido tool interrupt_subagent` and `kido tool stop_run` already enforce this
before ever sending the envelope; this session
checks it again on receipt, since `from` is advisory.
