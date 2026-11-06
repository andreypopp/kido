# Runtimes, as built

A **runtime** is a named place where a pane's program runs and where
an exec session runs a command: an Apple container (the `container`
kind), a Podman container on a Linux server (the `podman` kind), an
ssh host (the `ssh` kind), and the test-only `command` kind.
The host is the implicit runtime of every other pane. This document
describes the runtime core: the configuration, the link, the listener
and the identity on it, how a pane starts in a runtime, the exec
session, the two kinds, and agents in a runtime. [protocol.md](protocol.md), section 15,
gives the routes. [design-ko.md](design-ko.md) describes the server,
and [design.md](design.md) the agent features. This document does not
repeat them.

## The model

A runtime has a name (`RuntimeName` in `ko_config/src/values.rs`), a
kind, a link and a listener. The pane record holds its membership
(`Membership` in `ko_server/src/pane.rs`): `Born`, a pane that
started in the runtime and stays there for its life, or `Visit`, a
host pane that `ko run` holds in the runtime ("A visit"). The row
carries the runtime's name while either lasts, absent for the host.
A runtime pane's `ko-pane`
runs on the host with a host pty, as every pane's does. Its program
is the transport's client, which carries the pty into the runtime.
Thus the ring, the views, the status model and the input path do not
change: the runtime is a property of how the pane's program started
and of which socket its processes talk to.

**The key.** The server identifies a runtime by its key
(`RuntimeKey` in `ko_server/src/runtime/mod.rs`): its name and its
source (`RuntimeSource` in `ko_server/src/protocol.rs`), an entry of
the configuration file or a definition of one layout session. The
registry, the connection's `Origin`, the pane record, the exec
sessions and the start's waiters hold the key; the wire keeps the
bare name where the request gives the session. A request's name
resolves to a key by the request's session: the caller pane's
session, the session that a new pane lands in, or, for the user,
the `session` query (protocol.md, section 15). In that session the
name resolves to the session's ad-hoc runtime of that name, else the
configured one (`Registry::resolve`); a name that neither has is
`not_found` with "no runtime NAME in SESSION or in FILE". An ad-hoc
runtime thus shadows a configured runtime that gains its name later,
while it lives. The user's requests without `session` resolve to the
configured runtime. The
key's **tag** (`RuntimeKey::tag`) is its one-word form for a file
system and a container engine: the name for a configured runtime,
`<session>-<name>` for a session's. A session id has an underscore and
a name cannot, so the two forms never collide. The tag names the
runtime directory, the container `ko-<tag>` and the ssh kind's
remote directory.

The configuration is the crate `ko_config` ("The configuration
file"). The coordinator's modules are `ko_server/src/runtime/`: `mod.rs` (the registry, the link states and the
one dispatch over the kinds), `pane.rs` (the runtime directory's
layout, the cwd mapping and a pane's host-side argv), `command.rs`
(what only the `command` kind does), `container.rs` (the container
and podman kinds: one stage machine, its argvs and its cleanup, with
a table of facts for each engine), `ssh.rs` (the ssh
kind: its start stages, its argvs, the remote quoting and the
classification of ssh's exits), `exec.rs` (the helper process,
the session's stages and the session limiter) and `leaving.rs` (the
children that the server ended, until they are reaped).
`state/runtime_ops.rs` holds the routes, the identity gate and the
idle rule, `state/exec_ops.rs` drives the exec sessions through
their stages, and `state/visit_ops.rs` drives the visits ("A visit"); `exec.rs` holds the helper's types and its spawn, and
no session logic. A new kind adds one arm
to each method of the dispatch in `mod.rs` and its bodies in a module
of its own.

## The configuration file

The runtimes are the `runtimes:` key of the configuration file
(design-ko.md, "The configuration file", which gives the path, the
owner crate and the decode). The server reads the file
when a runtime is used or listed, and again at each link start,
a retry after `Failed` included, so an edit needs no reload. A link
that is up keeps the configuration that it started with. A missing
file, an empty file and a file without `runtimes` have no runtimes. A
file that does not decode fails every runtime request with the error,
and the server runs regardless. The registry keeps the last list that
decoded, and it gives the clients the error as well (protocol.md,
section 15, "Clients"), so a client shows that list under the error
and not an empty one. A runtime is a thing of the host that
runs it, so a remote host's runtimes are in that host's file.

```yaml
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

The types are `ko_config/src/runtime.rs`, with the newtypes of
`ko_config/src/values.rs`. ko_client, ko_shell and ko take the values
that the wire and the command line share (`RuntimeName`, `AbsPath`)
and the ssh option classifier (`ssh_args.rs`). The fields that every runtime has
are its `env`, its default `cwd`, the `paths` prefix list of the cwd
mapping, `pi`, where an agent's pi runs ("Agents in a runtime"), and
`color`, an sRGB `#rrggbb` that clients draw the runtime in
("Clients"). The kind is one key beside them, `ssh`, `container`,
`podman` or `command`, whose value holds the kind's fields; an entry gives exactly
one. `GET /runtimes/NAME` reports the effective `paths`, the `cwd`,
`pi` and the `color`; a spawner and a routed pi read the first three.

**The `command` kind** exists for the e2e suite only. The server
accepts it only with `KO_RUNTIME_COMMAND_KIND=1` in its environment;
without the knob, a `command` entry is a configuration error. Its
transport is a `prefix` argv put in front of `ko enter` and of an
exec's argv, on the host. An optional `up` step, which the server
runs as its own child, models the stages of the other kinds (the ssh
forward), so that the link machinery is tested without them. The fields of the other kinds are in their
sections below.

## Ad-hoc runtimes

A pane defines a runtime of its own layout session with `PUT
/runtimes/NAME` (protocol.md, section 15 gives the rules and the
refusals), and `ko run <kind>` (`ko/src/run.rs`) is that request
from the command line. The body is a `Runtime` of
`ko_config/src/runtime.rs`, the shape of a configuration entry, so
one decode and one validation serve the file and the route, and
`ko run`'s options are the fields. A definition starts nothing: a
pane born in the runtime, an exec session or `ko-pi --runtime NAME`
uses it by name, as a configured runtime. The registry keeps the
definitions in memory only, in its `adhoc` map beside the links
(`ko_server/src/runtime/mod.rs`); nothing persists across a server
restart.

**A pane stays where its runtime name resolves.** A row carries the
bare `runtime` name, and the name resolves by the pane's session.
Thus `PUT /layout` refuses a move of a pane into a session where its
name resolves to another key, and a runtime connection creates panes
only in its runtime's session: the row's name and the pane's session
always give the pane's key, and a client finds the entry with one
lookup.

**The end of a definition.** A session goes with its last window,
with `DELETE /sessions/{id}` or with a `PUT /layout` that leaves it
out. Its panes go first, in the same layout change; then each ad-hoc
runtime of the session gets a forced down and then the effects of
`DELETE /runtimes/NAME`: the kind's delete cleanup runs, the runtime directory goes
but its `io/`, the definition leaves the map, and `runtime_deleted`
names the key. The idle rule only takes the link down and keeps the
definition, so the next pane or exec starts the link from it again.
At its exit the server takes every link down and then queues the
delete cleanup of every ad-hoc runtime, because nothing would remove
its container later; the cleanup runs after the server as the stops
do.

## A visit

`ko run` (`ko/src/run.rs`, over `visit` in
`ko_client/src/visit.rs`) enters a runtime in place: the current
host pane runs the runtime's transport until the transport exits,
and then it is a host pane again. `ko run <kind>` first defines the
runtime ("Ad-hoc runtimes"); `ko run --name NAME` visits a defined
or a configured runtime. The visit is the WebSocket `GET
/runtimes/NAME/visit` (protocol.md, section 15) with the pane's
identity on the host socket.

**The lease is a connection.** Membership gates identity, so its
start and its end are facts that the server owns. Only a process of
the pane has the pane's token, which starts the visit. The kernel
closes the socket when `ko run` exits for any reason, `SIGKILL`
included, and the end of the connection ends the visit; no message
and no process name ends it. Thus `ko run` does not exec the
transport as `ko ssh` does. A `ko run` that `SIGSTOP` stopped keeps
its connection and thus its visit, which is correct: the pane is
still in the runtime. It keeps the connection and runs the
transport as its child on the pane's tty, in the shell's foreground
process group. Its loop (`ko_sys::event`, one thread) watches the
connection and the signals. `SIGHUP` and `SIGTERM` go to the child;
`SIGINT` reaches the child's group from the tty itself. Before a
child runs (while the link starts), each of the
three signals ends the visit, and `ko run` exits with 128 plus the
signal. The child's
exit closes the connection and is `ko run`'s exit status. When the
server ends the visit or the connection closes, `ko run` sends the
child `SIGHUP`, then `SIGKILL` after half of `KO_STOP_ESCALATION_MS`,
prints `runtime NAME: <message>` and exits 1.

**The server at a visit** (`ko_server/src/state/visit_ops.rs`) sets
the pane's membership to `Visit` with a fresh visit token, sends the
pane's `pane_runtime` event, counts the pane as an occupant (the idle
timer stops), and starts a link that is `Down` or `Failed`, as a
first pane does. The visit then waits for the link as a pane wrapper
does (`Who::Visit`). On `Up` the server writes the token file, or
passes the token to the remote as for a pane ("The ssh kind"), and
sends the transport's argv: the argv of a pane in the runtime
(`runtime::pane::transport`, "How a pane starts in a runtime")
without the `ko runtime-exec` head, because the visit did the wait.
Its cwd is the host directory that `ko run` read, mapped forward as
a host `cwd` is, else the runtime's `cwd`. On `Failed` the visit gets
the message and `ko run` exits 1 at the host prompt.

**The visit token.** Inside the runtime, `KO_PANE` is the pane and
`KO_PANE_TOKEN` is the visit token, not the pane's own token. On a
runtime connection a request acts as a pane when the pane is in that
runtime and the token is its membership's token: the pane's own for
`Born`, the visit token for `Visit`. On the host connection only the
pane's own token counts. The host shell's token cannot be rotated,
because it is in that shell's environment; a visit is short and
repeats. A process that a visit leaves inside the runtime holds a
token that dies with the visit, and the next visit mints another, so
nothing inside acts as the pane between or across visits.

**The end of a visit** (`State::end_visit`): the membership goes,
the `pane_runtime` event follows without `runtime`, the local token
file goes (the ssh kind's remote file stays, "The ssh kind"), the idle rule counts the runtime again, and the runtime
connections whose last request acted as the pane close (the
`caller` of `Conn` in `ko_server/src/conn.rs`). A visit ends when its
connection closes or hangs up, when its link leaves `Up` (a down of
any cause, a `DELETE`, the end of its session, a failed restart, the
server's exit), and when the pane dies or leaves the document. A
forced down ends a visit with `ended` and keeps the pane, which is
back at its host prompt; a down without `force` refuses while a visit
lasts, as it refuses while panes live.

**Refusals.** A pane that is in a runtime or visits one is refused
("pane_N is already in runtime NAME"), so a `ko run &` beside a
visit is refused, and the shell of a visiting pane waits for its
`ko run`. Inside a runtime, every `/runtimes` route is refused by the
gate, so a nested `ko run` is refused by the server; `ko run` says
`inside runtime NAME; run it from a host pane` when `KO_RUNTIME` is
set, before it asks. A runtime inside a runtime would run the inner
kind's start stages inside the outer runtime, which the server cannot
reach. `ko run` also refuses without a pane identity ("needs a
pane") and without a terminal on stdin ("needs the pane's
terminal").

**Status and cwd.** While a visit lasts, the pane is read as a
runtime pane ("Status", "The cwd"): its OSC records alone, no
foreground title, `ssh.dest` ignored, no OS cwd read, and its OSC 7
report is a runtime path that maps back through `paths`. After the
visit, the host shell's next prompt reports the host directory.

**A fresh definition** has not yet reached `Up`. An image runtime of
the container kinds finds its container `ko-<tag>` by name, and a
container of that name can remain from an earlier server that ended
before its cleanup ran, with another image or other volumes. The
first start of a fresh definition therefore deletes a `ko-<tag>` that
it finds ("The container kind", the start stages) and creates it
again. The name is the proof that ko created it: the tag carries the
session id, which no user container of `from: {container}` uses, and
that source is never deleted. A start that fails keeps the
definition fresh; after `Up`, a start after an idle down reuses the
container.

## Clients

A client shows where a pane runs: Kido.app with a stripe and a label
on the pane and a suffix on its sidebar row (design-app.md, "Panes"
and "Sidebar"), the terminal client with the suffix only. Both
clients also list the runtimes at the bottom of the sidebar: the
configured runtimes and those of the current session, never another
session's. Kido.app's section has the start and stop actions
(design-app.md, "Runtimes section"); the terminal client's rows are
read-only (design.md, "The sidebar tree"). The
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
state. `Model::place` returns the runtime's key: the name and the
source that the name resolves to in the pane's session, a definition
of that session, else the configuration. The clients find the entry
of the list by that key, so two entries with one name stay apart.

**The colour** is the configured `color`, else a hue from the name
(FNV-1a of the UTF-8 name, mod 360; `app/App/RuntimeTint.swift`).
Kido.app computes it, so the server stores no colour that the
configuration does not have. It is for display only. The terminal
client draws no colour: its suffix is the name, with a glyph for a
`Starting` or `Failed` link (`ko_tui/src/sidebar.rs`).

**A new pane inherits** the runtime of the focused pane's row, not of
a routed pi's variable: a split or a new window from a routed pi is a
host pane, as the pi's own shell is. The terminal client's
`C-a c` and Kido.app's split and new-window commands follow
this rule; Kido.app's command palette names a runtime or `Host`
explicitly. Both clients name the source pane as the new pane's
`cwd` (`{pane}`), and the server moves its directory into the new
pane's place ("The cwd"), so a split of a runtime pane starts in the
same runtime directory. Without a source pane, Kido.app sends the home
directory and the terminal client its own host cwd (none when it is
remote). A visited pane is a runtime pane while its visit lasts: the
`pane_runtime` event updates the row's `runtime`, so the mark comes
and goes with it, and a split of a visited pane is born in that
runtime.

## The link

The server owns every link. It is one thread on the loop, so a link
is a state machine driven by `SIGCHLD`, readiness and timers, with no
thread and no blocking wait. The states are `Down`, `Starting`, `Up`
and `Failed` with a message (`LinkState` in
`ko_server/src/protocol.rs`). A runtime's entry in the registry is
optional: a runtime that has not started, or that is down, has
none, and a kind can have panes without a link.

**The first use starts the runtime.** A request that creates a pane
in a runtime that is `Down` or `Failed` (`POST /panes`, a new pane of
`PUT /layout`) starts the link and returns at once with the pane, as
for a host pane; an exec session starts it too. `POST
/runtimes/NAME/up` starts the link with no pane and returns at once;
the caller follows the `runtime` events. It exists for a client's
Start action (design-app.md, "Runtimes section"): a pane that only
brings the link up is a pane that the user must then close. A live
link is unchanged by it. A `Failed` runtime starts again at the next
request. The start binds the listener, then runs the
kind's stages, then sets `Up`. A stage is one
helper child of the server, reaped on `SIGCHLD`, whose exit, stdout
and stderr decide the next stage, `Up` or a failure; the `command`
kind's `up` step is one stage, and the container kind has several
("The container kind"). One deadline of 120 s covers every stage of a
start. A failure sets `Failed`, unbinds the listener, removes the
socket and the token files, runs the kind's cleanup, and answers every
waiter with the message. While the server handles a finished stage,
the link's phase is `Starting` (`Step::Cleaning` in
`ko_server/src/runtime/mod.rs`), never `Up`, until the outcome sets
the next step, `Up` or `Failed`: a link that fails there never was
`Up`, so its end records no departure and ends no waiting visit
before that visit gets the failure.

The pane's host-side program is `ko runtime-exec NAME -- ARGV`
(`ko/src/runtime.rs`, over `bring_up` in `ko_client/src/runtimes.rs`).
It long-polls `GET /runtimes/NAME/wait` over
the host socket with its own pane identity and prints `starting
runtime NAME` once while it waits. On `Up` it execs ARGV without the
host's `KO_SOCKET`, `KO_PANE` and `KO_PANE_TOKEN`. On `Failed` it
prints `runtime NAME: <message>` and exits 1, so the pane dies with
the failure on its screen, and a parent gets the death as any pane
death. After 120 s it prints `runtime NAME: still starting` and exits
1; the link continues. The wait is a waiter of the loop
(`Wait` in `ko_server/src/runtime/mod.rs`). Concurrent first panes
wait on one start.

**No user input.** Every stage runs without a tty and reads nothing
from a pane, so no pane shows a login prompt, and every waiter (a
pane, a visit or an exec session) starts and waits in the same way.
A step that would prompt on a terminal (a passphrase, a password)
fails the start with its stderr. Thus the user supplies a credential
before the start: for ssh, a key in the agent of the server's
`SSH_AUTH_SOCK`, a key without a passphrase, or a master that is
already running ("The ssh kind"). A request that does not use the
terminal can still wait for the user outside ko: a security key's
touch, or an agent's confirmation dialog (`ssh-add -c`). The start
waits for it up to its deadline of 120 s.

**Down.** A runtime with no pane in the document, live or dead, and
no live exec session goes down after the `server: runtime_idle_seconds`
of the configuration file (600; a fraction is permitted; `none` disables
the rule; read when the timer starts), on a loop timer. A link that
`up` started with no pane arms the timer at once, so an unused start
goes down on its own.
`POST /runtimes/NAME/down` refuses while the runtime has live panes,
visits or exec sessions, unless `force`, which ends the visits and
removes the born panes first as a stop does. `DELETE /runtimes/NAME` refuses in the same way, takes the link
down and removes the runtime directory but its empty `io/` ("The
runtime directory"); for an ad-hoc runtime it also drops the
definition ("Ad-hoc runtimes"). Down unbinds the listener,
removes the socket and the token files and closes the runtime's
connections. At its exit the server takes every link down after the
panes. Nothing reconnects on its own: the next pane, exec or `up`
starts the link again.

**The runtime directory** is `<state>/runtimes/<tag>/`. The
listener's `socket`, mode `0666`, is alone in its subdirectory `io/`,
mode `0755`, so a process of any
uid inside a container can connect through a relay, inside the `0700`
state directory that no other host user traverses. `io/` holds nothing
else, because the podman kind mounts it into the container, and the
token files are in the sibling `panes/`. ko creates `io/` once and
never removes it: down removes the socket, and `DELETE` removes every
other entry of the runtime directory, so a container that mounts
`io/` keeps a valid mount across a down, a `DELETE` and a server
restart. A socket path over
103 bytes fails the start with `runtime socket path exceeds 103
bytes; set KO_STATE_DIR to a shorter path`.

## Identity on a runtime connection

A connection carries an `Origin` from the listener that accepted it:
`Host` or `Runtime` with the name (`ko_server/src/server.rs`). The host
listener admits only the server's uid. A runtime listener admits any
peer uid, because the peer of a relay or a forward is not the
process inside, and tags the connection for its life; a WebSocket
upgraded on it keeps the tag. Nothing below `State::accept` knows
which socket delivered a connection, so a kind can hand a
socketpair end to it with the same tag.

On a runtime connection every request must carry the identity
(`Ko-Pane` and `Ko-Pane-Token`) of a live pane of that runtime, with
the token of its membership ("A visit", "The visit token"), else
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
- `GET /panes/{t}`: `t` visible.
- `/screen`, `/clear_history`, `/input`: `t` in
  `R` or a descendant of `c`.
- `POST /panes`, the stop, `PATCH /panes/{t}` (only for the caller
  itself), the variable writes and the messages: the rules that every pane identity has (protocol.md,
  sections 7 and 10), unchanged, so a parent and a child in different
  runtimes exchange messages.
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
transport's directory. A cwd that names a source pane (docs/protocol.md,
section 15, "The cwd of a new pane") takes that pane's OSC 7 pwd.
A runtime pane's pwd maps back to the host through the same entries,
by the longest runtime prefix, so a pane on the host made from a
runtime pane starts in the host directory that the runtime mounts.
The server keeps no host path for a runtime pane that never reported
a pwd: its start directory is the wrapper's, on the host, and the
server never reads the OS directory of a runtime pane's process,
which is the transport's.

**The token** never appears in an argv, because `ps` shows every
user's arguments. For the `command`, `container` and `podman` kinds, the server
writes the pane's token file in `<state>/runtimes/<tag>/panes/`
(directory `0700`, file `0600`) before it answers `Up` to that pane's
wait, and removes it when the pane leaves the document and at down.
The kind chooses the file's name and text: `pane_N.token` with the
bare token, which `ko enter` reads, or the container kind's
`pane_N.env`, an env file with `KO_PANE_TOKEN=...`, which `container
exec --env-file` and `podman exec --env-file` read. The ssh kind's token file is on the remote
("The ssh kind").
`ko enter --token-file F` reads and unlinks it; a file that is missing
or not private is `ko enter: no token`, exit 1. Without
`--token-file`, `ko enter` takes `KO_PANE_TOKEN` from its environment,
which the container and podman kinds use. Where the token is readable: on the
host, in the wrapper's environment (`ps -E` shows only the caller's
own processes on macOS, and `/proc/PID/environ` is `0400` on Linux)
and in the `0600` files; inside the runtime, in the pane's
environment, as any pane's.

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
runtime, which a routed agent's tools use. The user and every
host pane identity may open one in any runtime, because a host pane
may already create a pane there; on a runtime connection the route is
`refused`, so it is never a runtime's way into another.

The first client message is `exec`; nothing else is read before it.
A runtime that is `Down` or `Failed` starts as for a first pane, and
the session waits for `Up` as a waiter of the loop.

**The helper.** The kind turns the request into a helper process
(`Runtime::exec_launch` in `ko_server/src/runtime/mod.rs`), which the server runs as its child with
three non-blocking pipes on the loop and reaps on `SIGCHLD`. On every
kind the helper's transport runs `ko enter --exec` of the ko inside
the runtime, which runs the command: for `command`, the `prefix`,
then the server's own ko; for `container`, `container exec` ("The
container kind"); for `podman`, `podman exec` ("The podman kind"); for ssh, a passenger ("The ssh kind"). The argv is
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
shell prints before the ko starts is such a frame. A kind plugs in
at the launch and at that classification.

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
WebSocket reads for stdin, queued or running, the server still pings
it and does not wait for a pong, and a hangup of the peer still ends
it (protocol.md, section 1). A WebSocket that closes first
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
connection, which sshd's `MaxSessions` bounds, 10 by default; the
other kinds keep it for one behaviour. The cap has no configuration
field: it bounds what ko admits to the loop, and sshd's limit is met
on the retry path. A helper exit that the kind classifies as a
refused channel is retried once, after the next session of that
runtime ends (at once when one ended since it started), then reported
as `error`. Only the ssh kind classifies one.

## The container kind

The `container` kind runs a runtime's panes and exec sessions in one
Apple container, through the `container` CLI (measured with 1.5.0).
Each container is one lightweight Linux VM on arm64. The fields are
`Container` in `ko_config/src/runtime.rs`. `from` names either an
image, from which ko creates and owns the container `ko-<tag>` (the
CLI accepts the underscore of a session's tag), or a
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

**Measured** (2026-11-03, `container` 1.5.0, macOS 27.0.1): a `GET
/version` through the relay on one keep-alive connection has a round
trip of about 100 us (p50 98 us, p99 668 us), and an echo through
`--publish-socket`, the other direction, p50 80 us, so the relay is
as fast as `--publish-socket`. `--ssh` relays the host's
`SSH_AUTH_SOCK` the same way (its documentation calls it the
equivalent of a `--volume` of that socket), which is why a socket
volume carries the runtime socket and `--ssh` stays for the agent
alone. `container stop` removes a published host socket. `container
exec` into a stopped container is refused. `container image pull` of
a multi-platform image unpacks every platform, about a minute for
`python:3-alpine`, so a first start is slow; the waiting pane shows
only `starting runtime NAME`, because the pull is the server's child
and no progress is relayed, and the start's 120 s deadline is a
guess.

**The ko inside.** `ko: "shipped"`, the default, mounts the static
Linux ko of `share/ko/linux/aarch64` beside the server's installation
(AGENTS.md, "Layout") read-only at `/opt/ko`, so an image needs no ko
of its own. `make install` builds the layout, and a Release Kido.app
bundles it (docs/design-app.md). A missing layout fails only a start
that must create the container, with the path and `make build-linux`. `{ "mount": DIR }`
mounts another layout there, and `"path"` uses the image's `ko`. The
layout is always aarch64, because the VM's kernel is arm64 whatever
the image; ko has no measurement of an amd64 image under Rosetta.

**The start stages**, each a helper child (`Plan::next` in
`container.rs`, a pure function of the stage and its outcome):

1. `container system status`. A failure is `container system is not
   running: run container system start`.
2. `container inspect <target>`. For the fresh definition of an
   ad-hoc image runtime ("Ad-hoc runtimes"), a container that exists
   goes to `container delete --force ko-<tag>` and then to `container
   run`. A missing container (exit 1, `not
   found`) of an image runtime goes to `container run -d --name
   ko-<tag> --init` with the socket relay, each configured volume as
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
never a user's; so do the end of an ad-hoc runtime's session and the
server's exit for an ad-hoc runtime ("Ad-hoc runtimes"). The cleanup of a runtime is one queue of the
registry, in order: first the start stage and the watch that the down
ended, until they are reaped, then the stop, then the delete. A
stage that was killed can still finish its engine operation, which is
why the stop waits for its reap. Each cleanup command is a child of
the server with its stdio on `/dev/null`; the server reaps it and
kills it after 30 s, but never sends it `SIGTERM`. A start of the
same runtime that arrives meanwhile is `Starting` and runs its first
stage only when the queue is empty, so an old stop never stops a new
start's container. The reply to `DELETE` does not wait for the
removal. At the server's exit the stops and the deletes start without
the queue's order and finish after the server is gone.

## The podman kind

The `podman` kind runs a runtime's panes and exec sessions in one
Podman container on the same Linux host as the server, through the
`podman` CLI (measured with podman 6.0.2, rootless, SELinux
enforcing, in Fedora CoreOS). The fields are `Podman` in
`ko_config/src/runtime.rs`: those of the container kind without
`ssh_agent`, and `podman` for the program; the configuration holds
both kinds as one `Kind::Container` with an `Engine`, so the server
dispatches them as one kind. They share `container.rs`: the stages, the target
`ko-<tag>` or the user's container, the inner ko, the env-file
token, the watch and the cleanup queue are the same, and only the
argvs and the classification of the CLI's output differ. The podman
kind runs only on a Linux server: on another OS the first stage
fails with `the podman kind runs only on a Linux server`, and no
podman command runs, the cleanup included. The refusal is at the
link start, not at the decode, so one `config.yaml` decodes on every
host and `GET /runtimes` lists the entry; it is the one platform
branch outside `ko_sys` that is a rule, not an OS call.

```yaml
runtimes:
  box:
    podman:
      from: {image: docker.io/library/debian:trixie}
      volumes:
        - {host: /home/me/src, runtime: /src}
      user: "1000"
    cwd: /src
```

**The socket.** The container mounts the runtime's `io/` directory at
`/run/ko` (`-v <runtime>/io:/run/ko`), so `KO_SOCKET` inside is
`/run/ko/socket`. A bind mount of the socket file pins its inode, and a
connect after a re-bind is `ECONNREFUSED`; a directory mount follows
the new socket. The container runs with `--security-opt
label=disable`, because under SELinux a connect to a host socket in a
bind-mounted directory is `EACCES` (a `:z` relabel does not help). A
user's container (`from: {container}`) must have been created with
`--security-opt label=disable -v <dir>:/run/ko`, where `<dir>` is the
parent of the `socket` that `GET /runtimes/{name}` reports; else the
start fails and names that `-v`. Because ko never removes `io/`, the
user's container keeps working after a down or a `DELETE`.

**Rootless and rootful.** The kind runs the `podman` that the server
finds, as the server's user: rootless for a user's server, rootful for
a server that runs as root. The runtime listener admits any peer uid
("Identity on a runtime connection"): rootless, container root reaches
the host as the user's uid and `--user 1000` as a subuid (`100999`
measured), and the token is the identity.

**The ko inside.** `ko: shipped` mounts the static Linux ko of
`share/ko/linux/<arch>` read-only at `/opt/ko`, where `<arch>` is the
server's own architecture (`aarch64` or `x86_64`), because the
container shares the host's kernel; another architecture fails the
start. `{mount: DIR}` and `path` are as for the container kind.

**The start stages** have no system check, because podman has no
service to start; a broken podman fails the inspect with its own
error:

1. `podman container inspect <target>`. A missing
   container of an image runtime goes to `podman run -d --name
   ko-<tag> --init --security-opt label=disable --http-proxy=false`,
   the `io/` mount, each volume as `-v`, the `/opt/ko` mount,
   `run_args`, the image and `init`. A stopped container goes to
   `podman start`, a running one to the next stage; for a user's
   container this stage checks the `/run/ko` mount.
2. `podman exec <target> <ko> version`, the container kind's version
   check; a missing executable is exit 127.

`--http-proxy=false` because `podman run` otherwise copies the
server's proxy variables into the container's environment, and every
later exec sees them, which breaks the rule that nothing of the
server's environment reaches a runtime ("The exec session").
`run_args` refuses the options that ko sets (`ko_config/src/values.rs`).

**A pane** runs `podman exec -t -i [-u USER] --env-file
<panes>/pane_N.env <target> <ko> enter --socket /run/ko/socket ...`,
the container kind's argv with the other program. `podman exec` copies
no variable of the host without an explicit `-e` (podman-exec(1)), and
ko gives none and no `-w`. **An exec session** runs `podman exec -i
[-u USER] <target> <ko> enter --exec`, **the watch** `podman exec -i
<target> <ko> enter --watch`, with the container kind's semantics: an
outside `podman stop` ends the watch and takes the link `Down`.

**Down and cleanup** are the container kind's, with `podman stop` and
`podman rm --force`, only for a container that ko created.

**No `ssh_agent`.** The host agent's socket path belongs to a login
session, and the container outlives it. A user who keeps an agent at a
stable path (a systemd user socket under `$XDG_RUNTIME_DIR`) mounts
its directory through `volumes` and sets `SSH_AUTH_SOCK` in `env`.

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
   adopts it and skips the master stage. Thus a server that restarted
   does not log in again.
2. Otherwise the server removes a stale `ctl` and runs the master as
   a stage, with `BatchMode=yes` and `ControlPersist=yes`
   (`master` in `ko_server/src/runtime/ssh.rs`). `BatchMode` turns
   off every terminal prompt: ssh authenticates only with the agent of the
   server's `SSH_AUTH_SOCK`, a key without a passphrase or another
   non-interactive method, and a failed login exits at once with
   ssh's error ("Permission denied (publickey)."), the message of the
   failed start. ssh forks to the background when the master is up
   (`-f`), and the stage ends with the exit of the foreground ssh;
   the server reaps it and does not wait for the end of the pipes,
   which the background master keeps. The master is not the server's
   child: the checks are the server's only source for its state.
   A user whose key needs a passphrase loads it into the agent first
   (`ssh-add`), or starts a master on the control socket `ctl` of
   the runtime directory, which step 1 adopts.
3. The prepare passenger, `ko enter --prepare` through the master
   (`ko_shell/src/enter.rs`). It resolves the remote directory
   (`dir`, else a private default of the remote user, with the
   runtime's tag as the last component: `--tag`, which the server
   passes only for a session's runtime, else the name), refuses a
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

**sshd and the remote socket.** sshd never removes a forward's socket
file: `-O cancel -R` and `-O exit` leave it, and
`StreamLocalBindUnlink` is sshd's option, not the client's, so a
forward to a path with a stale socket fails with `remote port
forwarding failed`, exit 255 under `ExitOnForwardFailure=yes`; a
forward into a directory that does not exist fails the same way. That
is why `--prepare` creates the directory and removes the stale socket
before the forward. The forwarded socket is `srw-------` of the remote
user in a `0700` directory: on a shared remote host another user
cannot connect, and the remote user's other processes can, with a
pane token of that runtime. `AllowStreamLocalForwarding` is on by
default in macOS and Linux OpenSSH; a host that turns it off fails at
the forward.

**Through the master.** With `ControlMaster=no`, ssh connects
directly when the control socket does not answer. Every passenger,
pane and exec session sets a proxy command that always fails, so
none of them runs without the master and its forward. Every remote
word is single-quoted, because sshd hands the command line to the
remote user's login shell.

**A pane.** Before a pane's wait gets `Up`, the server checks the
master, then writes the pane's token file on the remote through a
passenger that gets the token on its stdin. A dead master restarts
the link from `Down`, and the pane waits in the new start. The pane's program is `ssh -t` through the master, then `ko
enter` without `--socket`, with the same `--tag` as `--prepare`: it
resolves the remote directory as `--prepare` does and reads the
socket and the token file there, because the pane's argv is fixed
before the link knows the directory. The default directory is
`$XDG_RUNTIME_DIR/ko-rt/<tag>`, else `/tmp/ko-rt-<uid>/<tag>`
(`remote_dir` in `ko_shell/src/enter.rs`), so two sessions' runtimes
of one name on one host have separate directories; a `dir` is used
as it is, and two runtimes that name the same `dir` share it.

A visit writes its token file the same way. A visit that ends after its file
reached the remote but before its transport read it leaves the file
there; the server does not remove it. The token in the file died with
the visit, the next visit of the pane writes over the same path, and
the next `--prepare` removes the file. A remove passenger at the end
of the visit could run after the next visit's write and remove that
file.

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
with it. Thus the next start after a failure logs in again. A link whose
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
/runtimes/NAME`, the exec session and the `runtime` body field. The
harness sends a runtime's name with its pane identity, so the name
resolves in the pane's session ("The model"), and an ad-hoc runtime
works in both modes as a configured one, with no branch in the
harness; a child's pane lands in its spawner's session and resolves
the same name. An ad-hoc runtime that is down starts at the first
exec from its stored definition.

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
  nothing. A prompt section `runtime` says that the built-in tools,
  `async_bash` and `!` run in the runtime at its cwd and that every other tool runs
  on the host at the host cwd, and names those tools; a notice at
  `session_start` tells the user the same. Other extensions' tools,
  MCP tools and codemode stay on the host: the harness cannot know
  which of them touch files, and a refusal would break the user's
  setup. Skills, prompt templates, project `.pi/` resources and `@`

[Showing lines 1-923 of 1230 (50.0KB limit). Use offset=924 to continue.]