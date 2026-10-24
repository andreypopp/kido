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
- `notice`: a dimmed row above the editor at once, then a collapsed
  custom message steered into the current turn.
- `steer`: joins the running turn (`deliverAs: "steer"`), labelled with
  its sender.
- `interrupt-and-steer`: aborts the running turn, waits for the abort to
  settle, then queues the text as a `message` from its sender. The
  aborted turn sends no report or notice.
- `stop`: `ctx.shutdown()`.
- anything else: delivered as text marked with the unrecognised kind.

`steer`, `interrupt-and-steer` and `stop` are refused on the wire unless the sender
is an ancestor of this session in the agent map. `from` is advisory.

An empty message is ignored, and a payload over 1 MiB is dropped. A
`/reload` keeps the socket bound; connections during the reload wait for
the reloaded module.

## Tools

- `list_runs()`: same-parent peers, the caller's parent, and its own
  subagent and bash runs (all running, the newest 20 ended).
- `set_status(activity)`: one line, at most 256 bytes, in
  `@kido_activity`; an empty string clears it.
- `message_agent(to, message, mode?)`: to an agent's inbox. `message`
  (the default) queues for any agent until its turn ends; to an ended
  child of this session, it resumes the child in its own session, with
  its history, and the message is its next turn.
  `steer` joins a descendant's running turn. `interrupt-and-steer`
  aborts a descendant's turn, then starts a new turn with the text.
- `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?)`:
  a child through `kido run-child ... -- kido-pi`, in the caller's model
  unless `model` names one. `resume_from` continues a saved pi session
  by id or unique prefix; with `fork`, it starts a copy. `toplevel`
  starts a peer through `kido run`, with no parent, report or notice.
  The result holds the new pi session id, which `resume_from` takes. A
  child's ending arrives as a notice.
- `async_bash(command, name, stream?)`: a command through
  `kido run-child ... -- bash -o pipefail -c '... | tee "$KIDO_RUN_OUTPUT"'`.
  Its ending arrives as a notice with the output tail; with `stream`,
  batches of output arrive while it runs.
- `stop_run(to, force?)`: a bash run through `kido run-stop`; a subagent
  by a stop request, then `kido run-stop --wait 5`. A child that reported
  since its last new work ends as completed, else stopped.

A subagent has no report tool. When its turn ends with nothing of its
own still running, its last message goes to its parent as a notice,
once for each piece of work. The whole report is kept in the agent
directory's `report`.
