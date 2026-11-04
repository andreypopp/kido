# Runtimes, as built

A **runtime** is a named place where a pane's program runs and where
an exec session runs a command: an ssh host or a container later, and
today only the test-only `command` kind. The host is the implicit
runtime of every other pane. This document describes the runtime core:
the configuration, the link, the listener and the identity on it, how
a pane starts in a runtime, and the exec session. The kinds `ssh` and
`container` do not exist yet. [protocol.md](protocol.md), section 15,
gives the routes. [design-ko.md](design-ko.md) describes the server,
and [design.md](design.md) the agent features. This document does not
repeat them.

## The model

A runtime has a name (`RuntimeName` in `ko_server/src/ids.rs`), a
kind, a link and a listener. The pane record and its row carry
`runtime`, immutable, absent for the host. A runtime pane's `ko-pane`
runs on the host with a host pty, as every pane's does. Its program
is the transport's client, which carries the pty into the runtime.
Thus the ring, the views, the status model and the input path do not
change: the runtime is a property of how the pane's program started
and of which socket its processes talk to.

The coordinator's modules are `ko_server/src/runtime/`: `file.rs`
(the configuration), `mod.rs` (the registry, the link states and the
one dispatch over the kinds), `pane.rs` (the runtime directory's
layout, the cwd mapping and a pane's host-side argv), `command.rs`
(what only the `command` kind does), `exec.rs` (the helper process,
the session's stages and the session limiter) and `leaving.rs` (the
children that the server ended, until they are reaped).
`state/runtime_ops.rs` holds the routes, the identity gate and the
idle rule, and `state/exec_ops.rs` drives the exec sessions through
their stages; `exec.rs` holds only the types. A new kind adds one arm
to each method of the dispatch in `mod.rs` and its bodies in a module
of its own.

## The configuration file

ko has no configuration file for anything else (design-ko.md,
"Decisions", 2026-10-30). A runtime cannot be derived, so it has one:
`$XDG_CONFIG_HOME/ko/runtimes.json`, else `~/.config/ko/runtimes.json`,
else the file of `ko server --runtimes FILE`. The server reads the
file when a runtime is used or listed, and again at each link start,
a retry after `Failed` included, so an edit needs no reload. A link that is up keeps the configuration
that it started with. A missing file is an empty configuration. A
file that does not parse fails every runtime request with the parse
error and its line, and the server runs regardless.

The shape is the code's (`ko_server/src/runtime/file.rs`);
`share/ko/runtimes-schema.json` is its JSON schema, which `ko
api-schema --runtimes` prints and `make schemas` regenerates. The
fields that every kind has are the runtime's `env`, its default
`cwd` and the `paths` prefix list of the cwd mapping. The server
validates the file with the API's newtypes (a name, an absolute
path); a bad field is an error that names the runtime and the field.
Unknown fields are ignored: the kind's fields are flattened into the
entry, and serde refuses `deny_unknown_fields` with `flatten`.

**The `command` kind** exists for the e2e suite only. The server
accepts it only with `KO_RUNTIME_COMMAND_KIND=1` in its environment;
without the knob, a `command` entry is a configuration error. Its
transport is a `prefix` argv put in front of `ko enter` and of an
exec's argv, on the host. Two optional steps model what the ssh and
container kinds will do, so that the link machinery is tested before
they exist: `lead`, an interactive step that one waiting pane runs on
its own pty (the ssh master's login), and `up`, a step that the
server runs as its own child (the ssh forward, the container start).

## The link

The server owns every link. It is one thread on the loop, so a link
is a state machine driven by `SIGCHLD`, readiness and timers, with no
thread and no blocking wait. The states are `Down`, `Starting`, `Up`
and `Failed` with a message (`LinkState` in
`ko_server/src/protocol.rs`). A runtime's entry in the registry is
optional: a runtime that was never started, or that went down, has
none, and a later bridge kind can have panes without one link.

**The first pane starts the runtime.** No request brings a runtime
up. A request that creates a pane in a runtime that is `Down` or
`Failed` (`POST /panes`, `POST /runs`, a new pane of `PUT /layout`)
starts the link and returns at once with the pane, as for a host
pane; an exec session starts it too. A `Failed` runtime starts again
at the next request. The start binds the listener, then runs the
`lead` step, then the `up` step, then sets `Up`. A failure sets
`Failed`, unbinds the listener, removes the socket and the token
files, and answers every waiter with the message.

The pane's host-side program is `ko runtime-exec NAME -- ARGV`
(`ko/src/runtime.rs`). It long-polls `GET /runtimes/NAME/wait` over
the host socket with its own pane identity and prints `starting
runtime NAME` once while it waits. On `Up` it execs ARGV without the
host's `KO_SOCKET`, `KO_PANE` and `KO_PANE_TOKEN`. On `Failed` it
prints `runtime NAME: <message>` and exits 1, so the pane dies with
the failure on its screen, and a parent gets the death as any pane
death. After 120 s it prints `runtime NAME: still starting` and exits
1; the link continues. The wait is a waiter of the loop
(`WaitKind::RuntimeUp`). Concurrent first panes wait on one start.

**Leader election.** When the start has a `lead` step, the first
waiter that asks gets the step's argv in the wait's reply; the others
keep waiting. The leader runs the step on its pty, passes its stderr
through and keeps the last line, and reports with `POST
/runtimes/NAME/lead`. Exit 0 continues the start; another exit fails
it with the last stderr line. A leader whose pane ends before it
reports fails the start. The leader then waits like the others. The
report is the only event: the server watches no file.

**Down.** A runtime with no pane in the document, live or dead, and
no live exec session goes down after `KO_RUNTIME_IDLE_SECONDS` (600;
a fraction is permitted; `none` disables the rule), on a loop timer.
`POST /runtimes/NAME/down` refuses while the runtime has live panes or
exec sessions, unless `force`, which removes them first as a stop
does. `DELETE /runtimes/NAME` refuses in the same way, takes the link
down and removes the runtime directory. Down unbinds the listener,
removes the socket and the token files and closes the runtime's
connections. At its exit the server takes every link down after the
panes. Nothing reconnects on its own: the next pane or exec starts
the link again.

**The runtime directory** is `<state>/runtimes/<name>/`, mode `0755`,
with the listener's `socket` in it, mode `0666`, so a process of any
uid inside a container can connect through a relay, inside the `0700`
state directory that no other host user traverses. A socket path over
103 bytes fails the start with `runtime socket path exceeds 103
bytes; set KO_STATE_DIR to a shorter path`.

## Identity on a runtime connection

A connection carries an `Origin` from the listener that accepted it:
`Host` or `Runtime` with the name (`ko_server/src/server.rs`). The host
listener admits only the server's uid. A runtime listener admits any
peer uid, because the peer of a relay or a forward is not the
process inside, and tags the connection for its life; a WebSocket
upgraded on it keeps the tag. Nothing below `State::accept` knows
which socket delivered a connection, so a later bridge can hand a
socketpair end to it with the same tag.

On a runtime connection every request must carry the identity
(`Ko-Pane` and `Ko-Pane-Token`) of a live pane of that runtime, else
it is `refused`, "a runtime connection must act as one of its panes".
A host pane's token is refused there, so a token that leaks into a
runtime buys nothing; so is a pane of another runtime. The user does
not exist on a runtime connection.

**What a runtime caller may use.** A route that the list below does
not name is refused (`router.rs` checks the identity,
`State::runtime_gate` the route): `/client`, views, search, `PUT
/layout`, every `/runtimes` route and the exec session among them.
For a caller `c` of runtime `R`,
`visible(c) = panes of R ∪ scope(c)`, with the one `scope` of the
stop and the messages (protocol.md, section 7; `ko_server/src/panes.rs`):

- `GET /layout` and `GET /panes`: the document whole, the rows only
  of visible panes.
- `GET /panes/{t}` and the runs' reads: `t` visible. A run whose pane
  is gone is visible only when the run was started in `R`, which its
  run record keeps.
- `/screen`, `/clear_history`, `/input` and a run's screen: `t` in
  `R` or a descendant of `c`.
- `POST /panes`, `POST /runs`, the stop, the variable writes, the
  output stream and the messages: the rules that every pane identity
  has (protocol.md, sections 7 and 10), unchanged, so a parent and a
  child in different runtimes exchange messages and the parent reads
  the child's output.
- The prompt routes: `from` is the caller, and the candidates follow
  the scope rule. A send that would end as a paste is `refused` unless
  its target is in `R` or a descendant of `c`, the rule of `/input`;
  a message or inbox delivery follows the scope.

A hidden pane is `refused`, not `missing`, because the document
already names its id. The parent edge is the one thing that crosses
a runtime boundary: a host agent and its child in a runtime see each
other's rows.

**Inheritance.** A pane created on a runtime connection is in that
runtime. The body field `runtime` is for host callers; a runtime
caller that names another runtime is `refused`. A host caller may
parent a pane in a runtime; a runtime caller cannot create a pane
outside its runtime.

## How a pane starts in a runtime

The server builds the pane's argv in one place
(`ko_server/src/runtime/pane.rs`): `ko runtime-exec NAME -- <prefix> ko enter
--socket S --pane pane_N --token-file F --runtime NAME [--cwd DIR]
[--env K=V]... [-- CMD...]`. The wrapper's environment is a host
pane's: the server's environment with the host's `KO_SOCKET` and the
pane's `KO_PANE` and `KO_PANE_TOKEN`; its cwd is the server's. The
runtime's `env`, then the request's, go into the runtime as `--env`
only. A shell-form command runs as `/bin/sh -c` inside the runtime,
because the host's shell path means nothing there. The row's
`command` is the requested command, not the wrapper's argv.

**The cwd.** A cwd from a caller in the target runtime passes
unchanged. A host path maps through the longest `paths` entry whose
host prefix matches whole components; no match gives the runtime's
`cwd`; without one, `ko enter` gets no `--cwd` and stays in the
transport's directory.

**The token** never appears in an argv, because `ps` shows every
user's arguments. The server writes `<state>/runtimes/<name>/panes/pane_N.token`
(directory `0700`, file `0600`) before it answers `Up` to that pane's
wait, and removes it when the pane leaves the document and at down.
`ko enter --token-file F` reads and unlinks it; a file that is missing
or not private is `ko enter: no token`, exit 1. Without
`--token-file`, `ko enter` takes `KO_PANE_TOKEN` from its environment,
which the container kind will use.

**`ko enter`** (`ko_shell/src/enter.rs`) is the inner side. It sets
`KO_SOCKET`, `KO_PANE`, `KO_PANE_TOKEN`, `KO_RUNTIME`,
and the terminal variables that every host pane gets (one function
in `ko_server/src/config.rs` makes them for both), with
`TERMINFO_DIRS` from its own installation and its own `share/ko/bin`
first on PATH, applies each `--env`, changes to `DIR` (`ko enter: cwd DIR: No such file or
directory`, exit 1, and the pane dies) and execs `ko shell [-- CMD...]`.
It never lets `--env` override an inherited `SSH_AUTH_SOCK`. It opens
the token file without following a link, checks the open descriptor
(a regular file of its own uid, no group or other bits), reads it and
unlinks it; the server creates the file new, never through an
existing link. Inside a runtime,
`ko` with no command refuses to start a client or a server: `ko:
inside runtime NAME; attach from the host`. `ko enter` and `ko
runtime-exec` are plumbing, hidden from `ko --help`.

**Status.** A runtime pane's foreground is the transport's process,
which says nothing about the program inside. `pane_kind.rs` reads a
runtime pane only through its OSC 133 and OSC 7501 records, which
the inner primed shell and agents emit through the transport: its
kind is never `Ssh`, and the foreground's name is not a title
fallback.

## The exec session

`GET /runtimes/NAME/exec` is a WebSocket that runs one command inside
the runtime without a pane: no pty, separate stdout and stderr, an
exit status and stdin from the client. It is the host's way into a
runtime, which a routed agent's tools will use. The user and every
host pane identity may open one in any runtime, because a host pane
may already create a pane there; on a runtime connection the route is
`refused`, so it is never a runtime's way into another.

The first client message is `exec`; nothing else is read before it.
A runtime that is `Down` or `Failed` starts as for a first pane, and
the session waits for `Up` as a waiter of the loop. A start that
needs a `lead` step that no pane has taken cannot be led by an exec,
which has no pty: the session ends with `error` "runtime NAME needs a
pane to log in". A start whose leader is already elected is waited
for.

**The helper.** The kind turns the request into a helper process
(`Runtime::exec_launch` in `ko_server/src/runtime/mod.rs`), which the server runs as its child with
three non-blocking pipes on the loop and reaps on `SIGCHLD`. The
helper's exit is the command's. For `command`, the helper is the
`prefix` and the argv, with no shell. The kinds still to come plug
in at the launch and at the classification of an exit
(`Runtime::refused`, "the transport refused a channel before any
output"); a bridge kind can serve the session by frames with no
process.

**The environment** of the command is the runtime's `env`, then the
request's, then the forced `KO_RUNTIME`. Nothing of the caller's or
the server's environment crosses, which is the credential boundary of
a routed agent's tools. `PATH` is the runtime's, else `/usr/bin:/bin`,
and the program is searched there.

**Backpressure, both ways.** The server reads the WebSocket only
while the child's stdin pipe takes bytes, and reads a stdout or
stderr pipe only while the connection's queue is below its cap, so a
slow reader blocks the command on its write as a full pipe does.
Nothing is dropped and nothing spills. While a session pauses its
WebSocket reads for stdin, its pong deadline restarts at each ping,
and a hangup of the peer still ends it. A WebSocket that closes first
closes the child's stdin and sends it `SIGTERM`, then `SIGKILL` after
`KO_STOP_ESCALATION_MS`; a step that a failed or cancelled start
ends gets the same, and at its exit the server kills and reaps every
such child. A `signal` message signals the same child.
The server signals only its own child, never a pid from a message.

**Limits.** One runtime runs at most 32 exec sessions at once. A
session past the cap waits in order for one to end and ends with
`error` after `KO_RUNTIME_EXEC_WAIT_MS` (30 s) of waiting for a slot;
the wait for `Up` does not count. The cap exists for the ssh kind,
whose master carries panes and sessions as channels of one
connection, which sshd's `MaxSessions` bounds; the other kinds keep
it for one behaviour. A helper exit that the kind classifies as a
refused channel is retried once, after the next session of that
runtime ends, then reported as `error`. The `command` kind never
classifies one.

## Decisions

2026-11-04:

- The configuration's kinds are a closed enum that holds only what is
  built: `command` until the ssh and container units add theirs.
- The interactive step's report is `POST /runtimes/{name}/lead`, one
  name for every kind, and the wait's reply carries the step's argv
  only for the leader, as one optional field.
- A runtime connection is deny by default: `PUT /layout` and the
  `/runtimes` routes are refused there.
- A live exec session keeps a runtime from going idle, as a pane does.
- The `runtime` event on `/client` and the runtimes of the `Welcome`
  come with the clients' unit, not with the core.
