# pi extension: kido-status

Reports a [pi](https://github.com/earendil-works/pi) session's live status to
kido, so pi sessions show up in the kido tmux sidebar next to Claude Code ones,
and opens an *inbox* socket so kido can send a prompt into the session.

It shells out to:

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
cp kido-status.ts ~/.pi/agent/extensions/
```

Extensions in `~/.pi/agent/extensions/` are auto-discovered at startup and can
be hot-reloaded with `/reload`. For a project-local install use
`.pi/extensions/` instead.

For a one-off run without installing:

```sh
pi -e /path/to/kido-status.ts
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

Four tools register unconditionally when the extension loads, and simply do
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
- `notice` - delivered as informational text.
- anything else - delivered anyway, marked as an unrecognised kind, so a
  typo or a newer kido talking to an older extension is visible rather
  than silently read as a plain message.

### Cycles

Each extension instance keeps its outstanding asks in memory only: an
edge to a target exists exactly as long as an `ask_agent` call is waiting
on it. If this session is holding an ask to X and receives an ask from X
before that one resolves, it answers `refused` on the wire
instead of `ok` - a distinct answer kido's `deliverInbox` reports as its
own error, never triggering the send-keys paste fallback, since nothing
was mis-delivered. A refused ask is not delivered to the model at all.
