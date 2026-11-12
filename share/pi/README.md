# koa's agent extension

`ko-pi.ts` is the extension that koa (`share/koa/`), Kido's one pi
harness, loads into its pi: the agent tools, the message stream, the
subagent lifecycle and the pane variables that ko reads. koa writes
the pane's OSC 7501 status and its title for its pi.

The extension reaches ko only through `ko` commands: `ko api` for
routes (`/layout`, `/version`, `POST /panes`, the pane messages and
stop, screens, `/panes/$KO_PANE/vars`) and `ko api --stream` for its
own message stream and a routed pi's exec sessions. Its background
commands are jobs, child processes of pi, not ko runs. It never
opens ko's socket itself, never reads ko's state directory and has no
state directory of its own: its registry of children and their
reports are custom entries in its own pi session.

docs/design.md, "The harness extension" and "Messages", and
docs/design-subagents.md give the design. The shapes of the API come
from `ko-api.d.ts`, which `make schemas` generates from
`share/ko/openapi.json`; the extension writes none by hand.

## Install

Nothing to install: `koa` in ko's bin directory runs pi with
`--extension` for this file where the package ships it. A bare `pi`
is plain pi, without the harness.

## Behaviour

Inside ko (`$KO_SOCKET` set and `ko` on PATH), a pi with a UI and a
session id:

- opens its pane's message stream with `ko api --stream
  /panes/$KO_PANE/messages` and answers each message with an ack or a
  refuse on the command's stdin. A `/reload` keeps the stream.
- writes `pi.session` and `pi.name` on its pane at `session_start`.
  At shutdown it deletes them and `pi.activity`, the pane's activity
  text that ko shows as the caption fallback, with one conditional
  delete on its own `pi.session`, so it never removes another pi's
  variables.
- for a subagent (`KO_AGENT_SESSION` equal to its own session id),
  delivers the `ko-pi.task` variable once, watches its parent's pane,
  and sends its report to the parent when a turn of its work settles.
- replaces pi's builtin `bash` with pi's own definition over its job
  operations: a call that runs past 60 s continues as a job, and the
  call returns at once.
- keeps its jobs across `/reload`; at quit, `/new`, `/resume` and
  `/fork` it stops them.
- with `--runtime NAME` (the routed mode), runs its built-in tools,
  `!` commands and jobs in that runtime through exec sessions, reads the context files there, and writes `pi.runtime` and
  `ko.runtime` (docs/design-runtimes.md, "Agents in a runtime").

Outside ko, without a UI or without a session id, it writes nothing and
opens no stream. The tools still register and report ko as
unavailable.

## Tools

- `list_agents(which?)`: the agents in the caller's scope (its
  subagents, its peers, each ancestor and its peers), with an own
  subagent's model, whether it has reported, and the start of its last
  report.
- `read_report(agent, which?)`: the whole last report of an own
  subagent, or all of them.
- `list_async_bash()`: the caller's own jobs, all running and the
  newest 20 ended, with their logs.
- `message_agent(to, message, mode?)`: `message` (the default) queues
  for any agent until its turn ends; to an ended own subagent, it
  restarts the subagent in its own session, with its history, and the
  message is its next turn. `steer` joins the running turn of any
  agent in scope. `interrupt-and-steer` aborts its turn, then starts a
  new turn with the text. `to` takes a name, a session id, a unique id
  prefix of at least eight characters, or a mention such as
  `@impl (session 9702ddd1)`, which `@` completion inserts.
- `spawn_agent(task, name, model?, cwd?, resume_from?, fork?, toplevel?, runtime?)`:
  a child in a new window through `POST /panes`, as `ko shell -- koa`
  in the user's login-shell environment and the caller's model unless
  `model` names one. `resume_from` continues a saved pi session by id
  or unique prefix; with `fork`, it starts a copy. `toplevel` starts a
  peer with no parent, report or notice. `runtime` works in a
  configured runtime: a routed child (`koa --runtime NAME` on the
  host) or, for a runtime with `pi: "runtime"`, a child inside it. A
  child's ending arrives as a notice.
- `stop_agent(agent, force?)`: one agent in scope, by a stop message
  and then the pane stop; `force` kills an agent that is not receiving
  messages. A subagent that the caller stops sends no ending notice.
- `async_bash(command, name, stream?)`: a job through pi's shell
  configuration. Both streams go to one log in the temp directory. Its
  ending arrives as a notice with the output's tail; with `stream`,
  batches of output arrive while it runs.
- `stop_async_bash(job)`: one own job, by id or name.

A subagent has no report tool. When its turn ends with nothing of its
own still running, its last message goes to its parent as a notice,
and the parent keeps it whole. A later turn of the same work that
ends with a new message sends a further report.

## Tests

`scripts/test-ts.sh` runs `ko-pi-*.test.ts` under node's native
TypeScript support, on the fake `ko` of `testdata/fake_ko/` (a Rust
binary that `make build-fake-ko` builds). The fake answers the routes
that the extension calls with the real server's shapes: it decodes and
encodes every wire message through `ko_wire::protocol`'s types, so a
change of a wire shape breaks its build. A test sends a deliberately
malformed stream message through `feedRaw`, which the fake prints verbatim. It serves the
message stream from files that a test writes, reading the acks on
stdin. Local jobs run real shells, gated on files that a test writes. It serves a runtime's exec session by running the argv
on the host with only the requested environment; one test drives the
same exec client against a real `ko server` with a `command` runtime. A fake delay is a `KO_FAKE_*` gate that a test
releases. `testdata/ko-prompts.txt` is the snapshot of every prompt
text the extension registers (`make prompts` regenerates it).
