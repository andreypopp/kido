# pi extension: ko-pi

`ko-pi.ts` is Kido's harness for pi: the agent tools, the inbox, the
subagent lifecycle and the pane variables that ko reads. pi natively
reports status through OSC 7501 in interactive mode after terminal
feature detection. Its pane title, set through OSC 0/2, names the
session. These work without the extension.

The extension uses only ko's run commands (`run`, `run-child`, `runs
--json`, `run-wait --json`, `run-stop`, `run-outcome`) and `ko api`:
`GET /layout` for the panes with their sessions and windows, and `PUT`
and `DELETE` on `/panes/$KO_PANE/vars`. It never opens ko's socket
itself. It never finds or parses ko's state directory; it reads a
run's output at the path a run command prints. Its own state is per
user, in `$KO_PI_STATE_DIR`, else `$XDG_STATE_HOME/ko-pi`, else
`~/.local/state/ko-pi`:

- `inbox/<session-id>.sock`, the session's inbox, when that path fits
  the 103-byte socket limit. Otherwise the inbox is in
  `/tmp/ko-pi-<uid>/`, which must be a directory of the user with
  mode 0700 and not a symlink, under a name that is a hash of the
  state directory and the session id. Thus, a parent still computes
  a child's inbox with no lookup, and two state directories do not
  collide.
- `agents/<parent-session>/<name>/`, one directory for each child:
  `agent.json`, `task`, `delivered`, `session-file`, `report` and `work`.

docs/design.md, "The pi extension, ko-pi", and docs/design-subagents.md
give the design. The shapes of the API come from `ko-api.d.ts`, which
`make schemas` generates from `share/ko/openapi.json`; the extension
writes none by hand.

## Install

Nothing to install: `ko-pi` in ko's bin directory runs the real pi
with `--extension` for this file where the package ships it, and
`PI_IMAGE_PROTOCOL=kitty` unless that variable is set. A bare `pi` is
plain pi, without the harness.

To run it against a checkout:

```sh
pi -e /path/to/ko-pi.ts
```

## Behaviour

Inside ko (`KO_RUN_ID` set, or `$KO_SOCKET` set and `ko` on PATH), a
pi with a UI and a session id:

- writes `pi.session` and `pi.name` on its pane (`$KO_PANE`) at
  `session_start` and `pi.inbox` after it binds the inbox. At shutdown
  it deletes these three and `pi.activity`, the pane's activity text
  that ko shows as the caption fallback, with one conditional delete
  on its own `pi.session`, so it never removes another pi's variables.
- binds its inbox. A stale socket file is unlinked only after a connect
  probe fails, so a second pi on the same session binds nothing. When
  ko-pi cannot bind its inbox, or cannot deliver a notice to its
  parent's inbox, pi shows a warning.
- for a subagent, delivers its task once, watches its parent's pane, and
  records its own run's outcome with `ko run-outcome` at shutdown.

Outside ko, without a UI or without a session id, it writes nothing and
binds no inbox. The tools still register and report ko as unavailable.

## Inbox

The inbox lets ko or another agent hand this pi session a message.

Protocol: a client

1. connects,
2. writes the payload as UTF-8, with no framing,
3. half-closes its write half (`shutdown(SHUT_WR)`),
4. reads `ok\n` or `refused\n`, and closes.

```sh
# with socat; any client that half-closes works
printf 'run the tests and summarise failures' | socat - UNIX-CONNECT:"$sock"
```

A v0 payload is plain text, which `ko prompt` sends. It arrives as a
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

- `list_runs()`: the agents in the caller's discovery scope (top-level
  agents, its peers, each ancestor and its peers, its direct subagents)
  and its own subagent and bash runs (all running, the newest 20
  ended). The `@` completion offers the same agents. `message_agent`
  still addresses any agent in the session.
- `message_agent(to, message, mode?)`: to an agent's inbox. `message`
  (the default) queues for any agent until its turn ends; to an ended
  child of this session, it resumes the child in its own session, with
  its history, and the message is its next turn.
  `steer` joins a descendant's running turn. `interrupt-and-steer`
  aborts a descendant's turn, then starts a new turn with the text.
  `to` takes a name, a session or run id, a unique id prefix of at
  least eight characters, or a mention such as `@impl (run 9702ddd1)`,
  which `@` completion inserts in the prompt editor.
- `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?)`:
  a child through `ko run-child ... -- ko shell -- ko-pi`, in the
  user's login-shell environment and the caller's model
  unless `model` names one. `resume_from` continues a saved pi session
  by id or unique prefix; with `fork`, it starts a copy. `toplevel`
  starts a peer through `ko run`, with no parent, report or notice.
  The result holds the new pi session id, which `resume_from` takes. A
  child's ending arrives as a notice.
- `async_bash(command, name, stream?)`: a command through
  `ko run-child ... -- bash -o pipefail -c '... | tee "$KO_RUN_OUTPUT"'`.
  Its ending arrives as a notice with the output tail; with `stream`,
  batches of output arrive while it runs.
- `stop_run(to[], force?)`: one or more runs, stopped in parallel, with
  one result line for each target; a bash run through `ko run-stop`; a
  subagent by a stop request, then `ko run-stop --wait 5`. A child that
  reported since its last new work ends as completed, else stopped.
  Each line gives the output or report path. A run that the caller
  stops sends it no ending notice; the result is the only signal.

A subagent has no report tool. When its turn ends with nothing of its
own still running, its last message goes to its parent as a notice,
once for each piece of work. The whole report is kept in the agent
directory's `report`.

## Tests

`scripts/test-ts.sh` runs `ko-pi-*.test.ts` under node's native
TypeScript support, on the fake `ko` of `testdata/fake_ko/` (a Rust
binary that `make build-fake-ko` builds). A fake delay is a `KO_FAKE_*`
gate that a test releases. `testdata/ko-prompts.txt` is the snapshot
of every prompt text the extension registers (`make prompts`
regenerates it).
