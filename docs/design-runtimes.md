# Runtimes, as built

A **runtime** is a named place where a pane's program runs and where
an exec session runs a command: an Apple container (the `container`
kind), an ssh host (the `ssh` kind), and the test-only `command` kind.
The host is the implicit runtime of every other pane. This document
describes the runtime core: the configuration, the link, the listener
and the identity on it, how a pane starts in a runtime, the exec
session, the two kinds, and agents in a runtime. [protocol.md](protocol.md), section 15,
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

The configuration is the crate `ko_config` ("The configuration
file"). The coordinator's modules are `ko_server/src/runtime/`: `mod.rs` (the registry, the link states and the
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

ko has one configuration file, for what cannot be derived (design-ko.md,
"Decisions", 2026-10-30 and 2026-11-04): `$XDG_CONFIG_HOME/ko/config.yaml`,
else `~/.config/ko/config.yaml`, else the file of `ko server --config
FILE`. Its `runtimes:` key holds the runtimes; Kido.app's settings
become other top-level keys (plans/app-config.md). The server reads the
file when a runtime is used or listed, and again at each link start,
a retry after `Failed` included, so an edit needs no reload. A link
that is up keeps the configuration that it started with. A missing
file, an empty file and a file without `runtimes` have no runtimes. A
file that does not decode fails every runtime request with the error,
and the server runs regardless.

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/andreypopp/kido/main/share/ko/config-schema.json
runtimes:
  gpu:
    ssh:
      destination: me@gpu-host
      ssh_args: [-p, 2222]
    env:
      CUDA_VISIBLE_DEVICES: 0
    cwd: /work
    color: "#d08a2a"
  dev:
    container:
      from: {image: debian:trixie}
      volumes:
        - {host: /Users/me/src, runtime: /src}
    paths:
      - {host: /Users/me/src, runtime: /src}
    pi: runtime
```

The crate `ko_config` owns the file: the types (`ko_config/src/config.rs`
and `ko_config/src/runtime.rs`), their newtypes
(`ko_config/src/values.rs`), the path rule, the decode and the JSON
schema `share/ko/config-schema.json`, which `ko api-schema --config`
prints and `make schemas` regenerates. It depends on no ko crate. The
server reads the file through it; ko_client, ko_shell and ko take its
values that the wire and the command line share (`RuntimeName`,
`AbsPath`) and the ssh option classifier (`ssh_args.rs`). Kido.app
will read the file through ko_client (plans/app-config.md). The fields that every runtime has
are its `env`, its default `cwd`, the `paths` prefix list of the cwd
mapping, `pi`, where an agent's pi runs ("Agents in a runtime"), and
`color`, an sRGB `#rrggbb` that clients draw the runtime in
("Clients"). The kind is one key beside them, `ssh`, `container` or
`command`, whose value holds the kind's fields; an entry gives exactly
one. `GET /runtimes/NAME` reports the effective `paths`, the `cwd`,
`pi` and the `color`; a spawner and a routed pi read the first three.

**The decode.** Every type is decoded by serde's derive, with
`deny_unknown_fields` on every record, and its schema comes from
schemars' derive. A rule that serde cannot state, such as an absolute
path, a name, a connection-only `ssh_args` or an option of `container
run` that ko owns, is the `TryFrom` of a newtype. Only the format is
written by hand (`ko_config/src/yaml.rs`): saphyr-parser's events
become a tree with positions, and one serde `Deserializer` reads it.
It resolves scalars by the type that asks:

- A string field takes any scalar as its text, so `yes`, `no`, `on`,
  `NO`, `0755`, `1:20` and the `2222` of `ssh_args` stay as written.
- A bool, an integer or a float field takes only the YAML 1.2 core
  schema's plain forms: `true`/`false` in three cases, decimal, `0o`
  and `0x` integers, and the core floats. No YAML 1.1 forms: `yes` is
  not a bool, `0755` not octal, `1:20` not sexagesimal. A quoted scalar
  is never a bool or a number.
- A plain `~`, `null` or an empty value is null. A key with a null
  value is the same as a missing key, also in a map such as `env`;
  the schema is stricter and does not allow the null.
- `deserialize_any` gives a scalar as text, so a value that serde
  buffers (an untagged enum) keeps the text as written.

The decode refuses a duplicate key, more than one document, a tag and
a key that is not a scalar. It expands anchors and aliases, and it
refuses a file, a depth or a node count, aliases expanded, over the
caps of `yaml.rs` and `config.rs` while it builds the tree, so a
hostile file costs the server no more than the caps. YAML 1.2 has no merge key, so `<<` is an unknown
field. An error names the path of keys and items to the value and its
line and column, after the file's path: `runtimes: dev: ssh: ssh_args:
-N is not a connection option; ko owns the rest of the ssh command at
line 5 column 17`.

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

## Clients

A client shows where a pane runs: Kido.app with a stripe and a label
on the pane and a suffix on its sidebar row (design-app.md, "Panes"
and "Sidebar"), the terminal client with the suffix only. The
protocol is protocol.md, section 15: the `Welcome` lists the
runtimes, and the `runtime` and `runtime_deleted` events follow
them, because the pane row carries no link state.

**Where a pane runs** is one function, `Model::place` in
`ko_client/src/model.rs`, which both clients use (Kido.app through
the model JSON's `place`): the row's `runtime`, else, only while the
pane's status is a pi agent, the `name` of its `pi.runtime`
("Agents in a runtime"), which is a routed pi. `ko.runtime` is not
read: any program can set it, and no rule makes it trusted. A pane
whose runtime is not in the list still shows the name, without a
state.

**The colour** is the configured `color`, else a hue from the name
(FNV-1a of the UTF-8 name, mod 360) with a saturation and brightness
for each theme; the client computes it, so the server stores no
colour that the configuration does not have. It is for display only.

**A new pane inherits** the runtime of the focused pane's row, not of
a routed pi's variable: a split or a new window from a routed pi is a
host pane, as the pi's own shell is. The terminal client's
`Ctrl+Shift+N` and Kido.app's split and new-window commands follow
this rule; Kido.app's command palette names a runtime or `Host`
explicitly. Kido.app sends the source pane's cwd only from a host
pane, which the server maps into a runtime ("The cwd"): a runtime
pane's directory is not a host path. The terminal client sends its
own host cwd.

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
runtime-exec` are plumbing, hidden from `ko --help`; so are `ko enter`'s
`--exec` ("The exec session") and `--watch` ("The container kind").

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
three non-blocking pipes on the loop and reaps on `SIGCHLD`. On every
kind the helper's transport runs `ko enter --exec` of the ko inside
the runtime, which runs the command: for `command`, the `prefix`,
then the server's own ko; for `container`, `container exec` ("The
container kind"); for ssh, a passenger ("The ssh kind"). The argv is
only `ko enter --exec`: the command, its cwd, its environment and the
escalation go in the first frame, so no value of the runtime's `env`
appears in an argv, which `ps` shows to every user.

**The inside ko** (`ko_shell/src/session.rs`) starts the command as
the leader of a new session and process group, with its own pipes. The
helper's stdin and stdout carry the frames of
`ko_server/src/exec_wire.rs`, server to ko and ko to server. The
helper's stderr stays raw: it is the transport's and the inside ko's
own text (ssh's errors, a missing ko, `ko enter: ...`), and reaches
the client as stderr. A signal and an exit cross as the JSON of the
protocol's types, by name, never by number, because the host is macOS
and the runtime is often Linux. The ko sends the exit, a status or a
signal, after the leader ended and both of the command's pipes ended;
a normal exit signals nothing, so a process that the command put in
the background survives, as on the host.

**Cancel.** The end of the helper's stdin or stdout, a frame that
does not parse, or a `SIGTERM`, `SIGHUP` or `SIGINT` to the ko
cancels: `SIGTERM` to the group, then `SIGKILL` at the escalation, or
at once when the leader ends after the cancel. The ko watches both
ends for a hangup even while backpressure pauses its reads, so a
command that never reads its stdin cannot hide the transport's end
(`Interest::Hangup` in `ko_sys/src/event.rs`). The escalation is half
of `KO_STOP_ESCALATION_MS`: a margin, not a guarantee, for the ko's
`SIGKILL` to come before the server's `SIGKILL` of the helper. The ko
holds the leader's zombie until the session ends (`ko_sys::pid::Program`),
so the group's id is not reused while the ko can signal it, and a
cancel after the leader's exit still reaches the processes that hold
its output. The ko signals only that group. A process that leaves the
group (`setsid`, `setpgid`) escapes the cancel.

An exit frame is the command's end, whatever the helper's own status.
A helper that ends without one is classified by the kind
(`Runtime::ending`: the helper's exit, a refused channel, or the
transport's own error); a missing program or cwd is the inside ko's
exit 127 or 1 with its message on stderr. A frame that does not parse
ends the session at once with `error`; output that a remote login
shell prints before the ko starts is such a frame. The kinds still to come plug in at the launch
and at that classification; a bridge kind can serve the session by
the same frames with no process.

**The environment** of the command is the runtime's `env`, then the
request's, then the forced `KO_RUNTIME`. Nothing of the caller's or
the server's environment crosses, which is the credential boundary of
a routed agent's tools. Inside the runtime, the command starts from
the environment that the kind's transport gives to the inside ko: an
ssh host's login environment, an image's environment in a container,
and nothing for the `command` kind, whose `PATH` is the runtime's,
else `/usr/bin:/bin`. The ko adds no variable of its own: an exec is
not a pane, and gets no `KO_SOCKET`, `KO_PANE` or token.

**Backpressure, both ways.** The server reads the WebSocket only
while the child's stdin pipe takes bytes, and reads a stdout or
stderr pipe only while the connection's queue is below its cap, so a
slow reader blocks the command on its write as a full pipe does; the
inside ko applies the same rule between its frames and the command's
pipes. Nothing is dropped and nothing spills. While a session pauses its
WebSocket reads for stdin, its pong deadline restarts at each ping,
and a hangup of the peer still ends it. A WebSocket that closes first
closes the helper's stdin, which cancels the command inside, and sends
the helper `SIGTERM`, then `SIGKILL` after `KO_STOP_ESCALATION_MS`;
a step that a failed or cancelled start ends gets the same. At its
exit the server kills every child that it is ending, but sends a
running exec helper only `SIGTERM`, so the ko inside finishes its own escalation
after the server is gone. A `signal`
message is a frame to the inside ko, which signals the command's
group. The server signals only its own child, never a pid from a
message.

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
`Container` in `ko_config/src/runtime.rs`. `from` names either an
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
`container exec -i <target> <ko> enter --watch` with a stdin that the
server never writes; `--watch` only waits for the end of its stdin. It ends when the container stops, from outside too, and its
end takes the link `Down` as a forced down does, which removes the
runtime's panes, whose `container exec` ended with the VM anyway. The
next pane or exec starts the link again. `container logs --follow`
ended at once, and `container start --attach` refuses a running
container, so neither can be the watch.

**A pane** runs `ko runtime-exec NAME -- container exec -t -i [-u
USER] --env-file <panes>/pane_N.env <target> <ko> enter --socket
/run/ko/socket --pane pane_N --runtime NAME [--cwd DIR] [--env
K=V]...`. The env file brings `KO_PANE_TOKEN` into the pane's
environment, where `ko enter` reads it, so the token is in no argv.
The cwd mapping has the configured volumes as `paths` entries, host
to runtime, before the configured `paths`; `GET /runtimes` reports
the combined list.

**An exec session** runs `container exec -i [-u USER] <target> <ko>
enter --exec` ("The exec session"), with no `-e` and no `--cwd`
of the CLI, so the CLI copies nothing of the server's environment;
`PATH` is the image's unless an `env` names it. A missing ko exits 1
with `failed to find target executable` on stderr. The `container
exec` client ignores `SIGTERM` and `SIGINT` (it prints `missing
signal in xpc message`) and passes no signal into the container, and
it reports a signal exit as 128 plus the signal; the frames carry
both instead. A close before `exit` ends the client at the
escalation's `SIGKILL`, which ends the inside ko's stdin and thus
cancels the command.

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
remote `dir` (`ko_config/src/runtime.rs`). `ssh_args` takes
only connection options, the kept class of the option classifier in
`ko_config/src/ssh_args.rs`, which `ko ssh` and the remote attach also
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

**The exec helper** is a passenger that runs the remote `ko enter
--exec` ("The exec session"), with the variables in its first frame,
because sshd accepts no other variables. The server finds `ssh`
on its own `PATH` and runs the passenger with an empty environment,
because a `SendEnv` of the user's ssh configuration would carry the
server's variables to the command, and a `SendEnv` on the command
line cannot clear it. The end of the local ssh closes the channel,
which ends the remote ko's stdin and cancels the command; sshd sends
it no signal. The exit frame is the command's status or signal.
Without one, ssh's exit 255 is `error` with ssh's stderr. A 255 whose stderr
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

## Agents in a runtime

An agent works in a runtime in one of two modes, by the runtime's
`pi`. The harness side is `share/pi/ko-pi.ts`; ko's part of either
mode is the configuration's `pi`, the `cwd` and `pi` of `GET
/runtimes/NAME`, the exec session and the `runtime` body field.

**Routed** (`pi: "host"`, the default). pi runs on the host in a host
pane, as `ko-pi --runtime NAME`: its session file, extensions,
skills, prompt templates and credentials are the host's. Its seven
built-in tools (`bash`, `read`, `write`, `edit`, `ls`, `find`,
`grep`), its `!` commands and its `async_bash` run in the runtime.
The pane is a host pane in every row field.

- **The tools** keep pi's names and schemas. The harness registers
  them only with `--runtime`, at `session_start`, so a host pi runs
  pi's own tools with the user's settings. `bash`, `read`, `write`, `edit`, `ls` and `find` are
  pi's tools over operations of the harness; `grep` is the
  harness's own tool with pi's schema and output form, because pi's
  grep runs the host's `rg` whatever its operations say. Each
  operation is one exec session through `ko api --stream
  /runtimes/NAME/exec`. A path is always an argv word, never text in
  a shell script; a write sends the content as `stdin`. `read` keeps
  a file's bytes; `write` and `edit` are text, as pi's are on the
  host. A path that starts with `~` means the runtime's home. A shell command runs
  as `bash -lc`, else `sh -lc` when a first probe of the runtime
  finds no bash; the same probe finds `fd` and `rg`, else `find` and
  `grep` run. An exec carries no environment: pi offers the host's
  to its bash operations, and the harness drops it, so the runtime's
  login environment and its `env` apply (the credential boundary of
  "The exec session"). A signal exit reads as 128 plus the signal's
  Linux number, as pi's bash contract asks.
- **`!`** goes through pi's `user_bash` event with the same
  operations. A routed pi that cannot route throws there, so a `!`
  command never falls back to the host.
- **The cwd** inside the runtime is the longest `paths` match of the
  host cwd, else the runtime's `cwd`, else the `pwd` of one exec. The
  harness keeps its own copy of the server's mapping (`map_cwd` in
  `ko_server/src/runtime/pane.rs`), because it maps every path
  argument of a tool; the two must agree. A
  relative path from the model resolves there. An absolute path
  under a `paths` host prefix maps before the exec, so a host path
  that the user typed through `@` on a mounted project works; any
  other absolute path is a runtime path.
- **The prompt.** `before_agent_start` sets pi's cwd line to the
  runtime cwd and replaces the context files with the host's global
  `AGENTS.md`, then the runtime's, from the root down to the cwd
  (pi's order and pi's candidate names, the nearest last), read by one
  exec at `session_start` and after `/reload`. That read runs in the
  background, so pi starts at once, and the first prompt and the
  first tool wait for it. A read that fails is tried again at the
  next prompt or tool when it was the only way to learn the cwd. It is also the exec that starts a runtime that is down: the
  harness itself never starts one, and `GET /runtimes/NAME` starts
  nothing. A prompt section `runtime` says that the built-in tools
  and `!` run in the runtime at its cwd and that every other tool runs
  on the host at the host cwd, and names those tools; a notice at
  `session_start` tells the user the same. Other extensions' tools,
  MCP tools and codemode stay on the host: the harness cannot know
  which of them touch files, and a refusal would break the user's
  setup. Skills, prompt templates, project `.pi/` resources and `@`
  completion stay the host's; on a mounted project they are the same
  files, and on an ssh project they are absent.
- **What refuses.** At `session_start` the harness reads `GET
  /runtimes/NAME`. A missing runtime or one whose `pi` is `"runtime"`
  leaves pi running with every routed tool, `!`, `async_bash` and a
  `spawn_agent` without `runtime` refusing with the reason, and a
  notice. A `Failed` runtime does not
  refuse: the next exec starts it again, and a failed start reaches
  the tool as the exec's `error`.
- **`async_bash`** is `POST /runs` through `ko api` with `runtime`,
  `parent` the own pane and `cwd` the host cwd, which the server maps
  as for a new pane, because `ko run-child` has no runtime flag. Its pane is a runtime pane; the
  wait, the stop, the output stream and the list are a host run's.
- **The variables.** The harness writes `pi.runtime` (`{ name, cwd }`,
  the runtime cwd) beside `pi.session`, believed under the same trust
  rule, and `ko.runtime` (the name), and deletes both with the others
  at shutdown. `ko.runtime` is a generic marker: any program that
  sends its work into a runtime from a host pane may set it; no
  client reads it, because nothing makes it trusted ("Clients"), and
  ko itself reads neither.
- **Messages.** A message from a routed pi carries `data.runtime`,
  and the receiver's header adds `in runtime NAME`; the server never
  reads a message's data.

**Inside** (`pi: "runtime"`). pi runs in a runtime pane, through
`ko enter`, with `KO_RUNTIME` in its environment, and the harness
routes nothing. Its session is a file of the runtime, so a spawner
refuses `resume_from` and `fork` into such a runtime.

**Spawning.** `spawn_agent`'s `runtime` reads `GET /runtimes/NAME`
and starts a routed child (a host pane whose command gains `--runtime
NAME`) or an inside child (`POST /panes` with `runtime`; the server
maps its host cwd). Without `runtime`, a routed spawner's child is
routed in the same runtime, and an inside spawner's child is in its
runtime by the server's inheritance; an inside spawner refuses another
runtime. `KO_AGENT_TRUSTED_CWD` is the host cwd for a routed child
and the mapped runtime path for an inside child, which is the
directory that child's pi sees. The registry entry of a child
records its runtime and mode, so a restart through a message starts
it the same way. `list_agents` shows `runtime` from the row's field,
else from a trusted `pi.runtime`, and a routed agent's `cwd` from
that variable.

**Cancel.** A tool's abort or timeout kills its `ko api --stream`
process, which closes the session. On every kind, the inside ko then
ends the command's process group ("The exec session"); a process that
left the group survives.

## Decisions

The configuration file, 2026-11-04:

- The file is YAML 1.2, `config.yaml`, with no JSON form: a person
  writes it, with comments, and an editor checks it with the JSON
  schema through the `yaml-language-server` line.
- One file for every setting that ko and Kido.app cannot derive, with
  one top-level key for each owner; `runtimes:` is the server's.
- The parser is saphyr-parser, the event parser of the yaml-rust2 line:
  pure Rust without `unsafe`, YAML 1.2, two packages. serde-saphyr and
  serde_norway were rejected: a serde YAML crate must pick a type for a
  plain scalar in `deserialize_any`, so a buffered string field fails
  on `2222`; serde-saphyr adds about twelve packages, and serde_norway
  is unsafe-libyaml, unreleased since 2024-12, and keeps the last of
  two duplicate keys. serde_yml has a RUSTSEC advisory. libyaml's YAML
  1.1 resolution reads `no` as false.
- The deserializer resolves a scalar by the type that asks, not by the
  scalar alone: a string field takes `yes` and `0755` as written, and
  a bool, an integer or a float field takes only the core schema's
  forms.
- The kind is a key of the entry (`ssh:`, `container:`, `command:`),
  not a `kind:` tag beside flattened fields: serde's `flatten` and an
  internal tag buffer the value through `deserialize_any` and refuse
  `deny_unknown_fields`. A derived raw record with the three optional
  keys converts through `try_from` into the runtime, whose kind is an
  enum; the schema states the rule as a `oneOf` of `required` keys.
- The error for zero or two kinds names `ssh` and `container` only:
  `command` is a test kind, and the server's knob check explains it.

2026-11-04:

- The ssh master is the leader pane's process, with
  `ControlPersist=yes`, not the server's child: a headless server
  cannot answer ssh's prompts, and a batch-mode master would need a
  login command.
- The remote directory is resolved on the remote by `ko enter`, both
  for `--prepare` and for a pane, so the pane's argv needs no fact
  of the link.
- The exec passes variables in the first frame to `ko enter --exec`, not `SetEnv`,
  which a default sshd's `AcceptEnv` refuses.
- The option classifier lives in `ko_config::ssh_args`, because the
  configuration validates `ssh_args` and `ko_server`, `ko_shell` and
  `ko_client` depend on `ko_config`. The ssh facts that the remote
  attach shares stay in `ko_server::ssh`.
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

Agents in a runtime, 2026-11-04:

- An agent in a runtime is routed unless the runtime says `pi:
  "runtime"`; ko never copies pi into a runtime.
- Other extensions' tools in a routed pi run on the host, with a
  prompt section and a notice, not a refusal.
- `@` completion in a routed pi lists host files.
- A routed pi's `async_bash` is a run in the runtime, through `POST
  /runs`, not an exec session: it keeps a pane, a screen and the
  run's lifecycle.
- A routed tool's cancel is ko's, not the harness's.

Exec cancel, 2026-11-04:

- Every exec runs under the ko inside the runtime, not as the
  transport's own command: no transport passes a signal (the container
  CLI and sshd do not), and only a process inside can end the
  command's group and report a signal exit by name.
- The signal and the stdin's end reach the inside ko as frames on the
  helper's stdin, not through the runtime socket: an exec has no pane
  identity there, and the stdin is there on every kind. The output
  and the exit are frames on the helper's stdout; the helper's stderr
  stays raw, because the transport writes its own errors there.
- A normal exit leaves the group alone, as a host shell does; only a
  cancel kills it.

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

Clients, 2026-11-04:

- A runtime's `color` is an optional configuration field, with a hue
  from the name as the fallback: a hash alone cannot be corrected when
  two names collide.
- Clients get a narrow `ClientRuntime` (name, kind, colour, state),
  not `RuntimeInfo`: a pane count in it would go stale between events.
- The `runtime` event carries the whole entry, and `runtime_deleted`
  removes one, because the configuration file can change while a
  client is connected.
- `ko.runtime` marks no pane in a client; only the row's `runtime` and
  a trusted pi's `pi.runtime` do.
- A new pane takes the focused row's `runtime`; a routed pi's host
  pane gives a host pane.
