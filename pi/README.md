# pi extensions: kido-status and kido-agents

Two extensions, installed together:

- **`kido-status.ts`** reports a [pi](https://github.com/earendil-works/pi)
  session's live status to kido, so pi sessions show up in the kido tmux
  sidebar next to Claude Code ones, and opens an *inbox* socket so kido can
  send a prompt into the session.
- **`kido-agents.ts`** is agent coordination: the tools below, dispatch of
  everything but a plain prompt arriving on that inbox, and the subagent
  lifecycle.

They are separate because they are separate jobs — being visible in a
sidebar and coordinating a fleet of agents — but they share one session's
inbox and one status report, so they find each other at load time through
a pair of slots on `globalThis`, keyed by `Symbol.for("kido.pi.extension.seam")`.
`kido-agents.ts` imports nothing but *types* from `kido-status.ts`, on
purpose: pi evaluates each extension in a module registry of its own, so
an ordinary import of the neighbouring file loads a second copy of it
rather than reaching the one pi started (measured against pi 0.85.1 —
list_agents answered `[]`). Load order does not matter either: pi may run
either factory first, and neither reads the other's slot until a tool call
or an event.

Install both. Either on its own still loads and degrades quietly: without
`kido-agents.ts`, an envelope arriving on the inbox is delivered as its
own text rather than dispatched by kind; without `kido-status.ts`, the
tools report kido as unavailable.

The status half shells out to:

```
kido agent-status --agent pi --session <id> --status running|waiting|compacting|idle \
     [--title <text>] [--activity <text>] [--model <name>] [--instance <id>] \
     [--parent-pid <pid>] [--parent-instance <id>] [--depth <n>] \
     [--ended] [--remove] [--inbox <path>] [--protocol <n>]
```

kido reads `$TMUX_PANE` from the environment, so the command is spawned from
inside the pi process, which lives in the tmux pane.

`--instance` is a random id generated once for this process (not per session)
and reported on every call, so kido can tell this process from another one
reusing its pid. `--parent-pid`, `--parent-instance` and `--depth` are read
once from `KIDO_AGENT_PARENT_PID`, `KIDO_AGENT_PARENT_INSTANCE` and
`KIDO_AGENT_DEPTH`, which `kido spawn` sets in a subagent's environment (see
`docs/subagents-plan.md`); absent for a root session.

## Install

```sh
mkdir -p ~/.pi/agent/extensions
cp kido-status.ts kido-agents.ts ~/.pi/agent/extensions/
```

`kido setup-pi` does exactly this, from copies embedded in the binary.
Extensions in `~/.pi/agent/extensions/` are auto-discovered at startup and can
be hot-reloaded with `/reload`. For a project-local install use
`.pi/extensions/` instead.

For a one-off run without installing, pass both (`-e` repeats); they need
not be in the same directory, but there is no reason not to be:

```sh
pi -e /path/to/kido-status.ts -e /path/to/kido-agents.ts
```

## Behaviour

| pi event | reported status |
|---|---|
| `session_start` | `idle` (also captures session id and name) |
| `agent_start`, `turn_start`, `tool_execution_start`, `tool_call` | `running` |
| `ui_prompt_start` / `ui_prompt_end` | `waiting` / back to `running` (or `idle`, if the prompt was raised while pi was idle) |
| `session_before_compact` | `compacting` |
| `session_compact`, `session_compact_failed` | back to the status from before compaction |
| `agent_settled` (and `ctx.isIdle()`) | `idle --ended` |
| `session_shutdown` | `--remove` (and the inbox socket is closed and unlinked) |

- If `kido` is not on `PATH`, or pi is not running inside tmux, the extension
  does nothing at all, quietly.
- Every invocation is fire-and-forget (detached, `stdio: "ignore"`); a missing
  binary, a non-zero exit, or a spawn error never reaches pi and never prints
  to the TUI.
- Reports are coalesced: kido is only invoked when the status or title actually
  changes, so a burst of tool calls costs one process, not one per call.

## Inbox

The inbox lets something outside the session — kido, a script, another agent —
hand this pi session a prompt, so a session you are not typing into can still be
given work.

On `session_start` the extension binds a unix **stream** socket and reports its
path once, as `--inbox <path> --protocol <n>` on the first status report; kido
carries both values forward, so later reports omit them. `--protocol` is the
highest inbox envelope version this extension speaks (kido's `internal/msg`;
see AGENTS.md), and a sender that sees no advertised protocol sends plain v0
text instead of a JSON envelope. On `session_shutdown` the socket is closed and
the file unlinked.

Where to bind is kido's decision, not the extension's: it runs `kido inbox-path
<pid>`, which prints `<state>/inbox/<pid>.sock`, creating the directory mode
0700. kido owns the state-directory precedence and the socket-path length
budget; if the path would not fit, `inbox-path` exits non-zero and the extension
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

- `list_agents()` runs `kido agents --json` and returns every agent visible
  in the current tmux session, including this one.
- `set_status(activity)` runs `kido agent-status --activity <text>`, free
  text capped at 256 bytes and shown next to this session in kido's
  sidebar, separate from the running/waiting/idle status above. An empty
  string clears it.
- `message_agent(to, message, replyTo?)` runs `kido message [--kind reply
  --reply-to <id>] <to>`, piping `message` on stdin. `to` is resolved by
  an exact, case-insensitive name, then an exact session id, then a
  unique id prefix, scoped to this tmux session; ambiguity is an error
  naming the candidates rather than a guess. An agent with an inbox gets
  it as a real user message; an agent with none (Claude Code, above all)
  gets it pasted into its pane instead. Either way kido's stdout reports
  which happened and to whom, and the tool relays that back verbatim.
  `replyTo`, when given, sends the message as kind `reply` so the
  receiver's dispatch (below) can correlate it with a pending `ask_agent`.
- `ask_agent(to, question, timeoutMs?)` runs `kido message --kind ask --id
  <id> <to>`, then blocks the tool call until a matching `reply` envelope
  arrives at this session's own inbox - which is also why there is no
  `kido ask` CLI twin: a short-lived subprocess has no inbox of its own to
  receive the answer on. Default timeout is 5 minutes; a timeout returns
  an error naming the ask's id, and a reply that arrives after the timeout
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
- `notice` - delivered as a custom message, rendered collapsed to one
  line ("notification from X - ctrl-o to expand") with the full text
  behind pi's own ctrl-o toggle; the model always sees the full text
  regardless of how it renders.
- anything else - delivered anyway, marked as an unrecognised kind, so a
  typo or a newer kido talking to an older extension is visible rather
  than silently read as a plain message.

### Notices to a parent

A subagent no longer notifies its parent automatically. `notify_parent(summary)`
runs `kido message --kind notice`, sent only when the model itself decides
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

- `interrupt_subagent(to)` runs `kido interrupt <to>`, which delivers an
  `interrupt` envelope; this session answers one addressed to it with
  `ctx.abort()`, aborting the current turn without ending the session.
- `stop_subagent(to, force?)` runs `kido stop <to> [--force]`, which
  delivers a `stop` envelope; this session answers one addressed to it
  with `ctx.shutdown()`, the same teardown a normal exit runs
  (`session_shutdown`: inbox closed, record removed, own window's linger
  scheduled). `kido stop` escalates to killing the target's window if it
  does not go within a few seconds - see `docs/subagents-plan.md`.
- `notify_parent(summary)` runs `kido message --kind notice <parent>`,
  piping `summary` on stdin. Refused, before anything is sent, for a
  session with no parent - a root session was not spawned, so there is
  nobody to tell. Call this once, when the model itself judges its
  delegated work is actually done; nothing calls it automatically (see
  "Notices to a parent" below).

Both are refused - on the wire, as `refused` - unless the sender can be
verified as an ancestor of this session (the same ancestor walk
`ask_agent`'s own refusal uses, in the opposite direction): a caller may
only interrupt or stop its own descendants. `kido interrupt`/`kido stop`
already enforce this before ever sending the envelope; this session
checks it again on receipt, since `from` is advisory.
