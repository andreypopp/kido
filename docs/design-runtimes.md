# Runtimes, as built

A **runtime** is a named place where a pane's program runs and where
an exec session runs a command: an Apple container (the `container`
kind), an ssh host (the `ssh` kind), and the test-only `command` kind.
The host is the implicit runtime of every other pane. This document
describes the runtime core: the configuration, the link, the listener
and the identity on it, how a pane starts in a runtime, the exec
session, and the two kinds. [protocol.md](protocol.md), section 15,
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
(what only the `command` kind does), `container.rs` (the container
kind: its start stages, its argvs and its cleanup), `ssh.rs` (the ssh
kind: its start stages, its argvs, the remote quoting and the
classification of ssh's exits), `exec.rs` (the helper process,
the session's stages and the session limiter) and `leaving.rs` (the
children that the server ended, until they are reaped).
`state/runtime_ops.rs` holds the routes, the identity gate and the
idle rule, and `state/exec_ops.rs` drives the exec sessions through
their stages; `exec.rs` holds the helper's types and its spawn, and
no session logic. A new kind adds one arm
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
An unknown field is an error that names the runtime and the field
(`runtime NAME: unknown field "X"`). The kind's fields are flattened
into the entry, and serde refuses `deny_unknown_fields` with
`flatten`, so `file.rs` compares the entry's keys with the fields of
its kind after the typed decode.

**The `command` kind** exists for the e2e suite only. The server
accepts it only with `KO_RUNTIME_COMMAND_KIND=1` in its environment;
without the knob, a `command` entry is a configuration error. Its
transport is a `prefix` argv put in front of `ko enter` and of an
exec's argv, on the host. Two optional steps model the other kinds,
so that the link machinery is tested without them: `lead`, an
interactive step that one waiting pane runs on its own pty (the ssh
master's login), and `up`, a step that the server runs as its own
child (the ssh forward). The fields of the other kinds are in their
sections below.

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
`lead` step, then the kind's stages, then sets `Up`. A stage is one
helper child of the server, reaped on `SIGCHLD`, whose exit, stdout
and stderr decide the next stage, `Up` or a failure; the `command`
kind's `up` step is one stage, and the container kind has several
("The container kind"). One deadline of 120 s covers every stage of a
start. A failure sets `Failed`, unbinds the listener, removes the
socket and the token files, runs the kind's cleanup, and answers every
waiter with the message.

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
user's arguments. For the `command` and `container` kinds, the server
writes the pane's token file in `<state>/runtimes/<name>/panes/`
(directory `0700`, file `0600`) before it answers `Up` to that pane's
wait, and removes it when the pane leaves the document and at down.
The kind chooses the file's name and text: `pane_N.token` with the
bare token, which `ko enter` reads, or the container kind's
`pane_N.env`, an env file with `KO_PANE_TOKEN=...`, which `container
exec --env-file` reads. The ssh kind's token file is on the remote
("The ssh kind").
`ko enter --token-file F` reads and unlinks it; a file that is missing
or not private is `ko enter: no token`, exit 1. Without
`--token-file`, `ko enter` takes `KO_PANE_TOKEN` from its environment,
which the container kind uses.

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
inside runtime NAME; attach from the host`. A `ko` command that acts as
a pane (`KO_SOCKET` names the pane's own server, so the identity
headers go with it) does not require that the socket's directory is
private and its own (`Dir::Own` in `ko_server/src/config.rs`): a
container's `/run/ko`, the parent of the relayed socket, is made by
the engine, owned by root and `0755`, and the token, not the
directory, is the identity on a runtime socket. A command without a
pane identity (`--server`, `KO_STATE_DIR`) keeps the check. `ko enter` and `ko
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
`prefix` and the argv, with no shell. For `container`, it is
`container exec` ("The container kind"). The kinds still to come plug
in at the launch and at the classification of an exit
(`Runtime::ending`: the command's exit, a refused channel, or the
transport's own error); a bridge kind can serve the session by frames
with no process. The ssh kind's helper is described in "The ssh kind".

**The environment** of the command is the runtime's `env`, then the
request's, then the forced `KO_RUNTIME`. Nothing of the caller's or
the server's environment crosses, which is the credential boundary of
a routed agent's tools. Inside the runtime, the command starts from
the environment that the kind's transport gives: an ssh host's login
environment, an image's environment in a container, and nothing for
the `command` kind, whose `PATH` is the runtime's, else
`/usr/bin:/bin`.

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
runtime ends (at once when one ended since it started), then reported
as `error`. Only the ssh kind classifies one.

## The container kind

The `container` kind runs a runtime's panes and exec sessions in one
Apple container, through the `container` CLI (measured with 1.5.0).
Each container is one lightweight Linux VM on arm64. The fields are
`Container` in `ko_server/src/runtime/file.rs`. `from` names either an
image, from which ko creates and owns the container `ko-<name>`, or a
container that the user created and manages. The server finds the
`container` binary on its own `PATH` at each link start, unless the
field names a path.

**The socket relay.** A `--volume` whose source is a socket file is a
relay over vsock, not a mount: a process in the VM that connects to
the target connects to the host socket. A directory with a socket in
it does not cross. The relay goes by path and follows a new bind at
the same path, so the listener binds before `container run`, and a
container created once keeps working across server restarts. The
target is always `/run/ko/socket`. A user's container must have been
created with `-v <socket>:/run/ko/socket`, where `<socket>` is the
`socket` that `GET /runtimes/{name}` reports; else the start fails
and names that `-v`.

**The ko inside.** `ko: "shipped"`, the default, mounts the static
Linux ko of `share/ko/linux/aarch64` beside the server's installation
(AGENTS.md, "Layout") read-only at `/opt/ko`, so an image needs no ko
of its own. A missing layout fails only a start that must create the
container, with the path and `make build-ko-linux`. `{ "mount": DIR }`
mounts another layout there, and `"path"` uses the image's `ko`. The
layout is always aarch64, because the VM's kernel is arm64 whatever
the image; an amd64 image under Rosetta was not measured.

**The start stages**, each a helper child (`Plan::next` in
`container.rs`, a pure function of the stage and its outcome):

1. `container system status`. A failure is `container system is not
   running: run container system start`.
2. `container inspect <target>`. A missing container (exit 1, `not
   found`) of an image runtime goes to `container run -d --name
   ko-<name> --init` with the socket relay, each configured volume as
   `-v`, the `/opt/ko` mount, `--ssh` for `ssh_agent: forward`,
   `run_args`, the image and `init` (default: `sleep` with the
   argument `infinity`; `--init` reaps the orphans of the panes). A
   stopped container goes to `container start`, a running one to the
   next stage. For a user's container, this stage also checks the
   socket relay's mount.
3. `container exec <target> <ko> version`: the version check. Another
   protocol major or another `Ko-Vt` fails the start with both builds.
   Exit 127 or `failed to find target executable` is `ko is not
   installed in runtime NAME`.

A container that exists keeps the volumes, mounts and `run_args` that
it was created with: an edit of these fields takes effect after a
`DELETE` of the runtime.

**The watch.** The link holds one more helper while it is up:
`container exec -i <target> cat` with a stdin that the server never
writes. It ends when the container stops, from outside too, and its
end takes the link `Down` as a forced down does, which removes the
runtime's panes, whose `container exec` ended with the VM anyway. The
next pane or exec starts the link again. `container logs --follow`
ended at once, and `container start --attach` refuses a running
container, so neither can be the watch. The watch needs `cat` in the
image.

**A pane** runs `ko runtime-exec NAME -- container exec -t -i [-u
USER] --env-file <panes>/pane_N.env <target> <ko> enter --socket
/run/ko/socket --pane pane_N --runtime NAME [--cwd DIR] [--env
K=V]...`. The env file brings `KO_PANE_TOKEN` into the pane's
environment, where `ko enter` reads it, so the token is in no argv.
The cwd mapping has the configured volumes as `paths` entries, host
to runtime, before the configured `paths`; `GET /runtimes` reports
the combined list.

**An exec session** runs `container exec [-i] [-u USER] [--cwd DIR]
-e K=V... <target> ARGV...`, with `-i` only when the request has
stdin. Each variable has a value, because `-e K` alone copies the
host's value. The `container` CLI runs with the server's environment,
and none of it reaches the command; `PATH` is the image's unless an
`env` names it. The exit status is the command's; a command that a
signal ended exits with 128 plus the signal, as a shell reports it,
never as `exit { signal }`. A missing program exits 1 with `failed to
find target executable` on stderr. The `container exec` client
ignores `SIGTERM` and `SIGINT` (it prints `missing signal in xpc
message`) and passes no signal into the container, so a `signal`
message or a close before `exit` ends the client at the escalation's
`SIGKILL` and leaves the command running with its stdin closed; a
command that reads its stdin then ends on the EOF.

**Down and cleanup.** Down, the idle rule, a failed start and the
server's exit stop a container that ko created (`container stop`); a
user's container is never stopped. `DELETE /runtimes/{name}` also
removes a container that ko created (`container delete --force`) and
never a user's. The cleanup of a runtime is one queue of the
registry, in order: first the start stage and the watch that the down
ended, until they are reaped, then the stop, then the delete. A
stage that was killed can still finish its engine operation, which is
why the stop waits for its reap. Each cleanup command is a child of
the server with its stdio on `/dev/null`; the server reaps it and
kills it after 30 s, but never sends it `SIGTERM`. A start of the
same runtime that arrives meanwhile is `Starting` and runs its first
stage only when the queue is empty, so an old stop never stops a new
start's container. The reply to `DELETE` does not wait for the
removal. At the server's exit the stops start without the queue's
order and finish after the server is gone.

## The ssh kind

An `ssh` entry names a `destination`, `ssh_args` and an optional
remote `dir` (`ko_server/src/runtime/file.rs`). `ssh_args` takes
only connection options, the kept class of the option classifier in
`ko_server/src/ssh.rs`, which `ko ssh` and the remote attach also
use; a control-socket option (`-S`, `ControlPath`, `ControlMaster`,
`ControlPersist`) is refused too, because it would replace ko's.
Every pane, passenger and exec session of the runtime is one channel
of one master connection, whose control socket is `ctl` in the
runtime directory. `ko_server/src/runtime/ssh.rs` builds every argv
of the kind.

**The start.** The steps run in this order:

1. A check of the control socket. When a master answers, the server
   adopts it and skips the lead step. Thus a server that restarted
   does not log in again, and an exec session can start a link whose
   master is alive.
2. Otherwise the server removes a stale `ctl`, and the lead step is
   the master, with `ControlPersist=yes`. The leader runs it on its
   pane's pty, so a passphrase, a password or a security key's touch
   reaches the user. ssh forks to the background when the master is
   up. The master is not the server's child: the checks are the
   server's only source for its state.
3. The prepare passenger, `ko enter --prepare` through the master
   (`ko_shell/src/enter.rs`). It resolves the remote directory
   (`dir`, else a private default of the remote user), refuses a
   directory that is not private and the user's, removes a stale
   socket and every token file, and prints the directory and its
   `ko version`. A missing remote ko fails the start, and so does
   another protocol major or `Ko-Vt`, with both builds, by the check
   that every kind shares. The server keeps the directory for
   the link's life.
4. For an adopted master, a cancel of the old forward, whose failure
   is ignored: OpenSSH skips a forward that is identical to one it
   has, and prepare removed that forward's remote socket.
5. The forward of the remote socket to the runtime's listener.
   Success is `Up`. A refused forward fails with the text of a
   remote attach whose host refuses unix-socket forwarding.

**Through the master.** With `ControlMaster=no`, ssh connects
directly when the control socket does not answer. Every passenger,
pane and exec session sets a proxy command that always fails, so
none of them runs without the master and its forward. Every remote
word is single-quoted, because sshd hands the command line to the
remote user's login shell.

**A pane.** Before a pane's wait gets `Up`, the server checks the
master, then writes the pane's token file on the remote through a
passenger that gets the token on its stdin. A dead master restarts
the link from `Down`, and the pane waits in the new start and may
lead it. The pane's program is `ssh -t` through the master, then `ko
enter` without `--socket`: it resolves the remote directory as
`--prepare` does and reads the socket and the token file there,
because the pane's argv is fixed before the link knows the
directory.

**A dead master** ends every pane of the runtime, as a lost ssh
connection does. The link stays `Up` until a check shows the death:
the next pane's check, or the check that follows an exec session
that ended with ssh's own failure.

**The exec helper** is a passenger that runs `env(1)` with the
variables as words, because sshd accepts no other variables and
`env` takes any name in every login shell. The server finds `ssh`
on its own `PATH` and runs the passenger with an empty environment,
because a `SendEnv` of the user's ssh configuration would carry the
server's variables to the command, and a `SendEnv` on the command
line cannot clear it. A program whose name
contains `=` is refused, because `env` would read it as a variable.
ssh's exit is the command's status, except 255, which is `error` with
ssh's stderr; a remote signal also ends as 255. A 255 whose stderr
says that sshd refused the channel (its `MaxSessions`) is retried
once, only when no output reached the client and no stdin or EOF
reached the helper, because the refused helper's input is lost.
Otherwise it is `error` with the refusal line. The stderr of the
refused attempt reaches the client.

**Down**, the idle rule, a failed start and the server's exit end
the master with `-O exit`, a cleanup command of the runtime's queue
("Down and cleanup" of the container kind), and the forward ends
with it. A failed start thus asks for the login again. A link whose
master died queues the same exit before it starts again. The remote
socket and token files stay until the next `--prepare`; the tokens
are dead with their panes. A start that begins while the exit is
queued waits for it, and `DELETE` removes the runtime directory,
`ctl` with it, only after the queue is empty; a start in between
keeps the directory. At its exit the server starts every queued
cleanup of every runtime, a runtime that is already down included,
and leaves them and the running ones to finish after it is gone, so
no master outlives a down.

## Decisions

2026-11-04:

- The ssh master is the leader pane's process, with
  `ControlPersist=yes`, not the server's child: a headless server
  cannot answer ssh's prompts, and a batch-mode master would need a
  login command.
- The remote directory is resolved on the remote by `ko enter`, both
  for `--prepare` and for a pane, so the pane's argv needs no fact
  of the link.
- The exec passes variables as words of `env(1)`, not `SetEnv`,
  which a default sshd's `AcceptEnv` refuses.
- The option classifier and the ssh facts that the remote attach
  shares live in `ko_server::ssh`, because the server validates
  `ssh_args` and `ko_shell` and `ko_client` depend on `ko_server`.
- Down does not clean the remote files: the next `--prepare` does,
  and a dead pane's token buys nothing.

- The configuration's kinds are a closed enum that holds only what is
  built.
- The interactive step's report is `POST /runtimes/{name}/lead`, one
  name for every kind, and the wait's reply carries the step's argv
  only for the leader, as one optional field.
- A runtime connection is deny by default: `PUT /layout` and the
  `/runtimes` routes are refused there.
- A live exec session keeps a runtime from going idle, as a pane does.
- The `runtime` event on `/client` and the runtimes of the `Welcome`
  come with the clients' unit, not with the core.

Container kind, 2026-11-04:

- The relay of a socket-file volume carries the runtime socket;
  `--publish-socket` and `--ssh` are not used for it.
- The container's name is `ko-<name>`, not tied to a server instance,
  so a restarted server reuses it and the files that agents installed
  in it persist.
- The token reaches the pane through an env file written when the
  link is up, at the same point as the `command` kind's token file,
  not before the pane's `ko-pane` starts: the pane's `container exec`
  runs only after its wait returned `Up`.
- The link learns that its container stopped from a watch child, not
  from a poll and not only from the next pane.
