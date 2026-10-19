# pi extension: kido-pi

`kido-pi.ts` is kido's harness for pi: the agent tools, the inbox, the
subagent lifecycle and the pane options that kido reads. pi 1.2.0
natively reports status through OSC 7501 in interactive mode after
terminal feature detection. Its pane title, set through OSC 0/2, names
the session in kido. These work without the extension.

The extension uses only kido's run commands (`run-child`, `runs --json`,
`run-wait --json`, `run-stop`, `run-outcome`) and tmux (`set-option -p`,
`list-panes -a`, `list-panes -t`). It never finds or parses kido's
state directory; it reads a run's output at the path a run command
prints. Its own state is per user, in `$KIDO_PI_STATE_DIR`, else
`$XDG_STATE_HOME/kido-pi`, else `~/.local/state/kido-pi`:

- `inbox/<session-id>.sock`, the session's inbox;
- `agents/<parent-session>/<name>/`, one directory for each child:
  `agent.json`, `task`, `delivered`, `session-file`, `report` and `work`.

docs/design.md, "The pi extension, kido-pi", and docs/design-subagents.md
give the design.

## Install

Nothing to install: `kido-pi` in kido's bin directory runs the real pi
with `--extension` for this file where the package ships it. A bare `pi`
is plain pi, without the harness.

To run it against a checkout:

```sh
pi -e /path/to/kido-pi.ts
```

## Behaviour

Inside kido (`KIDO_RUN_ID` set, or `$TMUX` set and `kido` on PATH), a pi
with a UI and a session id:

- writes `@kido_session` and `@kido_name` on its pane at
  `session_start`, `@kido_inbox` after it binds the inbox, and
  `@kido_activity` on `set_status`. It unsets the four at shutdown.
- binds its inbox. A stale socket file is unlinked only after a connect
  probe fails, so a second pi on the same session binds nothing.
- for a subagent, delivers its task once, watches its parent's pane, and
  records its own run's outcome with `kido run-outcome` at shutdown.

Outside kido, without a UI or without a session id, it writes nothing and
binds no inbox. The tools still register and report kido as unavailable.

## Inbox

The inbox lets kido or another agent hand this pi session a message.

Protocol: a client

1. connects,
2. writes the payload as UTF-8, with no framing,
3. half-closes its write half (`shutdown(SHUT_WR)`),
4. reads `ok\n` or `refused\n`, and closes.

```sh
# with socat; any client that half-closes will do
printf 'run the tests and summarise failures' | socat - UNIX-CONNECT:"$sock"
```

A v0 payload is plain text, which `kido prompt` sends. It arrives as a
real user message with `deliverAs: "followUp"`. A v1 payload is a JSON
envelope that the tools send, dispatched by kind:

- `message`: a custom message headed with its sender and relationship
  (parent, subagent or peer), queued with `followUp`.
- `ask`: the same, with the ask id and the exact `message_agent` call
  for the reply. Refused on the wire if this session waits on an ask to
  the same sender (a cycle).
- `reply`: settles the waiting `ask_agent` call with that id, else
  arrives as an ordinary message. A reply is never dropped.
- `notice`: a dimmed row above the editor at once, then a collapsed
  custom message steered into the current turn.
- `steer`: joins the running turn (`deliverAs: "steer"`), labelled with
  its sender.
- `interrupt`, `stop`: `ctx.abort()`, `ctx.shutdown()`.
- anything else: delivered as text marked with the unrecognised kind.

`steer`, `interrupt` and `stop` are refused on the wire unless the sender
is an ancestor of this session in the agent map. `from` is advisory.

An empty message is ignored, and a payload over 1 MiB is dropped. A
`/reload` keeps the socket bound; connections during the reload wait for
the reloaded module.

## Tools

- `list_runs()`: same-parent peers, the caller's parent, and its own
  subagent and bash runs (all running, the newest 20 ended).
- `set_status(activity)`: one line, at most 256 bytes, in
  `@kido_activity`; an empty string clears it.
- `message_agent(to, message, replyTo?)`: to an agent's inbox; with
  `replyTo` a reply. To an ended child of this session, it restarts the
  child with the message.
- `ask_agent(to, question, timeoutMs?)`: sends an ask and blocks until
  the reply, the timeout (5 minutes), an abort, the target's end or this
  inbox's close. Refused for an ancestor, yourself, a target without an
  inbox or without `message_agent`.
- `spawn_subagent(task, name, model?, tools?, fork?)`: a child through
  `kido run-child ... -- kido-pi`. Its ending arrives as a notice.
- `async_bash(command, name, stream?)`: a command through
  `kido run-child ... -- bash -o pipefail -c '... | tee "$KIDO_RUN_OUTPUT"'`.
  Its ending arrives as a notice with the output tail; with `stream`,
  batches of output arrive while it runs.
- `steer_subagent(to, message)`, `interrupt_subagent(to)`: to a
  descendant's inbox.
- `stop_run(to, force?)`: a bash run through `kido run-stop`; a subagent
  by a stop request, then `kido run-stop --wait 5`. A child that reported
  since its last new work ends as completed, else stopped.
- `notify_parent(summary)`: a notice to the parent. The whole report is
  kept in the agent directory's `report`.
