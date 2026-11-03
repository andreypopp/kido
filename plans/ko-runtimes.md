# Runtimes: panes that run on an ssh host or in an Apple container

A **runtime** is a place where a pane's program runs: a filesystem, a
set of processes and a way to reach them with a pty. The host is the
implicit runtime of every pane today. This plan adds named runtimes
from a configuration file, two kinds first (`ssh` and Apple's
`container`, both validated on this Mac), and the stream layer under
which a forwarded socket today and a byte-channel bridge later are two
transports of one abstraction. It fits the agents plan
[ko-agents.md](ko-agents.md): ko is the only mediator between
agents, a pane is one trust unit with a token, messages are queued
per pane with idempotent ids, and the scope rule is over `parent`
edges. Where the two touch, this plan names the interface and changes
nothing on the agents side.

Decisions fixed by the user before this plan: the first kinds are
`ssh` and Apple `container` only; podman on Linux and Firecracker are
later and get no detailed design here (section 11); a pane in a
runtime gets a `KO_SOCKET` that belongs to that runtime only; every
pane, run and agent that a runtime pane creates is in the same
runtime; no stdio fallback for attaching clients; the configuration
is JSON; runtimes are managed only through the HTTP API, with no `ko
runtime` subcommands, a runtime starts with its first pane and stops
by the idle rule; ko ships a static musl Linux `ko` for the container
kind; the `command` kind is test-only; ssh panes ride the master; no
views and no `/client` on a runtime socket; the idle time is 600 s;
the container e2e runs locally behind `KO_E2E_CONTAINER=1`. The
podman-machine transport of macOS is out of scope.

Decided on 2026-11-04: an agent that `spawn_agent(runtime)` starts
runs its pi on the host and routes its tools into the runtime (the
**routed** mode, section 6.2). pi runs inside a runtime (the **inside**
mode) only when the runtime's configuration says that pi is installed
there; ko never copies pi. The primitive for the routed mode is the
exec session of section 6.1.

## 1. Prototype findings

Every measurement ran on 2026-11-03 on this Mac (macOS 27.0.1). The
ssh host was the macOS sshd of `localhost` (OpenSSH 10.3,
non-interactive login already worked). The `container` CLI was 1.5.0
with the image `python:3-alpine`, pulled for the test and removed;
`container system` was started for it and left running. The ko was
the build of `~/Workspace/kido-demo` (protocol 1.0), because this
worktree has no checked out submodule and does not build. The HTTP
probe sent `GET /version` 20 times on one keep-alive connection and
reports the round trip; the echo probe sent 200 messages of 64 bytes.

### 1.1 ssh: a reverse streamlocal forward

| case | result |
|---|---|
| `ssh -N -f -R REMOTE.sock:LOCAL.sock localhost`, then `nc -U REMOTE.sock` | the echo came back; the remote socket was created `srw-------` |
| a scratch `ko server`, its socket forwarded with `-R` to another path; an ssh session with only `KO_SOCKET=<that path>` ran `ko api /version` and `ko api /layout` | the server's JSON and `{"revision":0,"layout":{"sessions":[]},"panes":[]}` |
| a stale socket file at the remote path before `-R` | `remote port forwarding failed for listen path`, exit 255 with `ExitOnForwardFailure=yes` |
| the same with client-side `-o StreamLocalBindUnlink=yes` | the same failure: the option is sshd's |
| `-O forward -R` on a control master, then `-O cancel -R` | cancel exit 0, **the socket file stayed** |
| `-O forward -R`, then `-O exit` of the master | **the socket file stayed** |
| `-R` into a remote directory that does not exist | `remote port forwarding failed`, exit 255 |

Conclusions: the `ko` CLI works through a forwarded socket unchanged,
because it reads `KO_SOCKET` and connects to that path. sshd never
removes the forward's socket file, so every forward is preceded by a
remote `mkdir` and `rm -f` (section 4.1).

### 1.2 Apple `container`

| case | result |
|---|---|
| `-v <state>:/run/ko` (the directory holding the ko socket), connect inside | `[Errno 95] Not supported` |
| `-v <state>/socket:/run/ko/socket` (the socket file), `GET /version` inside | `HTTP/1.1 200 OK`, the server's JSON; round trip p50 98 us, p99 668 us |
| `--ssh` with `SSH_AUTH_SOCK=<state>/socket`, `GET /version` on `/var/host-services/ssh-auth.sock` | `200 OK`; p50 104 us; the real agent is then not forwarded |
| `--publish-socket <host>/out.sock:/run/ko/out.sock`, an echo listener inside, dialled from the host | `out.sock` appeared on the host; echo round trip p50 80 us, p99 443 us |
| `exec -t -e KO_SOCKET=... -e KO_PANE=pane_3 --cwd /usr CTR sh -c '...'` | a tty, the variables, the cwd, `uid=0` |
| the scratch server killed and started again (a new inode at the same path) while the container ran, then `GET /version` inside | `200 OK`: the relay follows the path |
| `container stop`, `container start`, then `GET /version` inside | `200 OK` |
| `container stop` | the published host socket file was removed |
| `container exec` into a stopped container, `container image pull` of a multi-platform image | refused; the pull unpacked every platform (about 1 min) |

Conclusions: a `--volume` whose source is a **socket file** is a
relay over vsock, not a virtiofs mount. The documentation of `--ssh`
(`docs/host-integration.md`) says it "performs the equivalent of the
options `--volume "${SSH_AUTH_SOCK}:/var/host-services/ssh-auth.sock"
--env ...`", and the measurement confirms that any host socket relays
this way, so the `--ssh` trick is not needed and would cost the real
agent forwarding. A directory with a socket in it does not cross.
`--publish-socket` is the other direction and works, so an
in-container bridge dialled from the host is possible but
unnecessary. The relay follows a re-bind at the same path, which a
server restart needs. Each container is one VM, and the hop costs
about 100 us.

### 1.3 Linux podman, for the later section

Measured inside the running `podman machine` VM (Fedora CoreOS,
podman 6.0.2, rootless, SELinux enforcing), used only as a Linux
machine: a host unix socket in a bind-mounted directory is `EACCES`
until the container runs with `--security-opt label=disable` (`:z`
does not help); a directory mount follows a re-bind, a file mount
pins the old inode (`ECONNREFUSED`); the peer uid the host sees is
the user's for container root and a subuid (`100999`) for `--user
1000`; `podman exec -t -e -w` gives a pty, env and cwd. Section 11
uses these.

### 1.4 Not measured

- A pane started inside a runtime through `ko enter` (section 6): the
  subcommand does not exist yet.
- An ssh host other than `localhost`: sshd defaults
  (`AllowStreamLocalForwarding yes`) were assumed and are the same on
  Linux OpenSSH.
- Firecracker: no KVM here (section 11).

## 2. The model

A runtime has a **name**, a **kind**, a **link** and a **listener**:

- The name is a `RuntimeName` newtype: 1 to 32 bytes of `[a-z0-9-]`,
  not `host`. It is the key of the configuration and the value of
  `KO_RUNTIME` in every pane of the runtime.
- The kind is an enum: `ssh`, `container`, and `command`, which only
  the e2e suite uses; later kinds in section 11. Each kind knows how
  to bring the link up, how to start a pane's program and how to take
  the link down.
- The link is the runtime's one connection to the host: an ssh master
  with a reverse forward, or a running Apple container whose socket
  relay carries the listener. One link for each runtime, never one for
  each pane (section 4).
- The listener is one unix listener on the host at
  `<state>/runtimes/<name>/socket`, bound while the link is up. The
  link carries it into the runtime, where it is `KO_SOCKET`. Every
  connection that the server accepts on it belongs to that runtime
  (section 5).

Every pane has a runtime: the host (no name) or one runtime name. The
pane record and its `Row` carry `runtime: Option<RuntimeName>`,
immutable, absent from JSON for the host. A runtime pane's `ko-pane`
runs on the host as today, with a host pty; its program is the
transport's client (`ssh`, `container exec`), which carries the pty
to the program inside the runtime. Thus the ring, the views, the
status model and the input path do not change: the runtime is a
property of how the pane's program was started and of which socket
its processes talk to.

## 3. The configuration file

ko has no configuration file (design-ko.md, decision of 2026-10-30).
A runtime cannot be derived, so this plan adds one file with one
purpose: `$XDG_CONFIG_HOME/ko/runtimes.json`, else
`~/.config/ko/runtimes.json`; `ko server --runtimes FILE` names
another. The server reads the file when a runtime is first used or
listed, and again on each `up`, so an edit needs no reload command: a
link that is up keeps the configuration it started with until `ko
runtime down` and `up`. A file that does not parse makes every
runtime request fail with the parse error and its line; the server
starts regardless.

JSON, because serde is in ko and a JSON schema can be generated: `ko
api-schema --runtimes` writes `share/ko/runtimes-schema.json`, which
`make schemas` regenerates and lint checks. The shape, in the plan's
notation only; the code
is the authority once it exists:

    { "runtimes": { "<name>": Runtime } }

    Runtime = { "kind": "ssh", ...Ssh } | { "kind": "container", ...Container } | { "kind": "command", ...Command }

Fields common to every kind:

- `env`: a map of variables for every pane of the runtime, applied
  before a request's `env`.
- `cwd`: the default directory inside the runtime, used when a
  request names none and the caller's cwd does not map. Absent means
  the runtime's own default: the login directory of an ssh host, the
  image's `WorkingDir` in a container.
- `paths`: a list of `{ "host": PREFIX, "runtime": PREFIX }`. A host
  path that a host caller passes as `cwd` is translated by the longest
  matching host prefix; no match falls back to `cwd` (section 7). The
  container kind derives entries from its `volumes` and needs `paths`
  only for more.
- `ko`: where `ko` is inside the runtime. For ssh, `"path"` (the
  default): `ko` on the PATH of the remote's shell, as `ko HOST`
  requires on a remote. For container, `"shipped"` (the default): the
  static Linux ko that ko installs beside itself (section 4.3),
  mounted read-only at `/opt/ko`; or `"path"`, the image's own.
  `{ "mount": DIR }` mounts another installed layout the same way.
- `pi`: where an agent's pi runs when a spawner names this runtime:
  `"host"` (the default; the routed mode of 6.2: pi on the host, its
  tools in the runtime) or `"runtime"` (the inside mode: the runtime
  has `pi` on the PATH of the primed shell, and the `ko-pi` shim of
  its ko installation starts it). ko never installs pi; a `"runtime"`
  entry whose runtime has no pi gives a child pane that dies with
  `pi: command not found` on its screen, which the spawner gets as the
  `ended` message. `GET /runtimes/{name}` reports the value.

`Ssh`:

- `destination`: the ssh destination as typed (`host`, `user@host`).
- `ssh_args`: connection options only, as `ssh.args` records them
  (`ko_shell/src/ssh.rs`'s `Keep` class: `-p`, `-J`, `-F`, `-i`,
  `-l`, `-o`, ...). An option of the `Drop` or `Refuse` class is a
  configuration error.
- `dir`: the remote directory of the forwarded socket. Default
  `$XDG_RUNTIME_DIR/ko-rt/<name>` else `/tmp/ko-rt-<uid>/<name>`,
  resolved on the remote by `ko enter --prepare` (section 4.1).
- `agent`: `forward | none`, default `forward`: the master runs with
  the destination's configured `ForwardAgent`, so sshd gives each pane
  session its `SSH_AUTH_SOCK`, which `ko enter` keeps.

`Container` (Apple's `container`, macOS):

- `from`: `{ "image": IMAGE }`, a container that ko creates and owns,
  or `{ "container": NAME }`, a container that the user created with
  `-v <state>/runtimes/NAME/socket:/run/ko/socket` (the path that
  `GET /runtimes/NAME` reports as `socket`) and manages.
- `container`: the binary, default `container` on the server's PATH.
- `volumes`: a list of `{ "host": DIR, "runtime": DIR, "options"?:
  "ro" }`, each a `-v` (virtiofs; files only, never a socket, section
  1.2). ko adds the socket relay itself.
- `user`: the `-u` of each `exec`; default the image's.
- `run_args`: more arguments of `container run` (`--cpus`,
  `--memory`, `--network`). ko refuses `-v`, `--volume`, `--mount`,
  `--name`, `-d`, `--rm`, `--publish-socket` and `--ssh`, which it
  owns.
- `init`: the command that keeps the container alive, default
  `["sleep", "infinity"]`.
- `ssh_agent`: `forward | none`, default `none`: `forward` adds
  `--ssh`, the host's real agent at `/var/host-services/ssh-auth.sock`
  with `SSH_AUTH_SOCK` set by the engine.

`Command` (test-only: the server accepts the kind only with the knob
`KO_RUNTIME_COMMAND_KIND=1` in its environment, read by
`ko_server/src/config.rs`; without it a `command` entry is a
configuration error): `prefix`, an
argv that ko puts in front of `ko enter ...` (section 6), and
`socket`, where the runtime socket is reachable inside (default: the
host path itself). The e2e suite needs a runtime without ssh or a
container engine. Its link is nothing: the listener is bound and the
kind is up.

The server validates the file with the same typed newtypes as the
API: a name, an absolute path, an option class. A bad field is an
error that names the runtime and the field.

## 4. The link: lifecycle

The server owns every link. It is the one process that starts
`ko-pane` and holds the listener, and it is one thread on the loop
(design-ko.md, "The loop rule"), so a link is a state machine driven
by `SIGCHLD`, readiness and timers, as `Remote` in
`ko_client/src/remote.rs` is for the client: no thread, no blocking
wait. `ko_server/src/runtime/` holds the registry, the listener and
one module for each kind. Every helper process (`ssh`, `container`)
runs with the server's environment and is reaped on `SIGCHLD` under a
deadline of the loop.

States: `Down`, `Starting`, `Up`, `Failed { message }`. `GET
/runtimes` reports them, and a `runtime` event on `/client` carries
each change.

**The first pane starts the runtime.** There is no `up` request. A
request that creates a pane in a runtime (`POST /panes`, `POST
/runs`, or a `PUT /layout` with a new pane that names `runtime`)
returns at once with the pane created, as for a host pane; the
request never waits for the link. When the link is `Down` or
`Failed`, the request sets it `Starting` and starts the kind's steps
on the loop. The pane's host-side program is `ko runtime-exec NAME --
<transport argv>` (section 6), a plumbing command of the `ko` binary
that the user never types: it long-polls `GET
/runtimes/NAME/wait?timeout_ms=` over the host socket with its own
pane identity until the state is `Up` or `Failed`, prints one line
`starting runtime NAME` on its pty while it waits, then execs the
transport argv, or prints `runtime NAME: <message>` and exits 1. Thus
the pane shows the start, the pane dies with the failure on its
screen, and a parent that spawned an agent there gets the death as
the `ended` message of the agents plan, which is the one failure
path a spawner has to handle anyway. The wait is a waiter of the
loop (`WaitKind::RuntimeUp`), never a thread. Concurrent first panes
all wait on the one start; the ssh kind elects one of them (4.1).

**Interactive steps.** The server is headless, so a step that needs
the user runs on the first pane's pty: the ssh kind's master (4.1).
The container kind has none; its image pull shows no progress in the
pane beyond the one line, because `container run` is the server's
child; no progress is relayed, and `starting runtime NAME` is the
whole text that a waiting pane shows.

**Down.** The idle rule: a link whose runtime has had no pane for
`KO_RUNTIME_IDLE_SECONDS` (600; `none` disables) goes down on its own
on a loop timer. `POST /runtimes/{name}/down { force }` exists for
the API: it refuses while the runtime has live panes unless `force`,
which removes them first as a stop does. `DELETE /runtimes/{name}`
also removes what ko created for it (a container, the runtime
directory). The server takes every link down at its own exit, after
the panes. A link that dies (the master ends, the container stops)
goes `Down` at once, and its panes die as their transport dies: an
ssh session ends with its master, an `exec` ends with its container,
an ordinary pane death with the transport's exit status. The server
does not reconnect on its own; the next pane does. Agents inside lose
their `KO_SOCKET` for that time: inner `ko api` fails, and ko-pi's
stream reader exits and restarts with its backoff (ko-agents.md,
2.6); a message sent to them meanwhile waits in its queue, because
the queue is the server's.

**Failure.** A failed start sets `Failed { message }`, answers every
waiting `runtime-exec` with it, and the `runtime` event carries it;
the next pane request retries at once, from `Down`. The row of a
runtime pane whose transport never started is a dead pane with the
message on its screen; the row carries no link state, and clients
read it from `GET /runtimes` and the `runtime` event only.

**The listener and the runtime directory.** `<state>/runtimes/<name>/`
is stable across server restarts, created `0755`; the socket in it is
`0666`, so a container process of any uid can connect through the
relay, inside the `0700` state directory that no other host user
traverses. The path must fit `SUN_PATH_MAX`; a state directory too
long for it makes the runtime fail with `runtime socket path exceeds
103 bytes` and the advice to set `KO_STATE_DIR` shorter. `down`
unbinds and removes the socket file; `DELETE /runtimes/{name}`
removes the directory.

### 4.1 ssh

The steps, each a stage of the state machine, with the arguments of
`ko HOST` as the model:

1. A master, started by the first pane, not by the server, so that a
   password prompt or a security key's touch reaches the user. The
   server removes a stale `ctl`, sets `Starting` and answers the
   first `runtime-exec` that asks with `lead: true`; that process
   runs `ssh -M -N -f -o ControlPath=<rt dir>/ctl -o
   ControlMaster=yes -o ControlPersist=yes -o
   ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o
   ServerAliveCountMax=3 <ssh_args> <destination>` with the pane's
   pty as its stdio: ssh asks on the pane, then forks to the
   background and the command returns 0 when the master is up, or
   255 with the error on the pane. The leader reports the result with
   `POST /runtimes/NAME/master { exit, stderr }` (its pane identity
   is the proof that it is the leader) and goes on to wait like every
   other pane. The server does not watch the file system: the report
   is the event. A host whose key is in the agent prompts nothing, and
   the pane shows only `starting runtime NAME`. If a live master
   already answers at `ctl` (`-O check`, a child of the server), the
   server skips this step.
2. The prepare passenger through the master (`-S ctl -T -o
   RemoteCommand=none -o BatchMode=yes`, as `remote_ko_args`): `ko
   enter --prepare [--dir DIR]` on the remote prints the remote
   socket directory (`dir`, or the default of section 3, created
   `0700`), removes a stale `socket` and every `*.token` in it,
   refuses a directory that is not private, and prints `ko version`'s
   JSON on a second line (section 4.4). Exit 127 is "ko was not found
   on NAME", the text of `Remote::NoRemoteKo`.
3. The forward: `ssh -S ctl -O forward -R <remote dir>/socket:<rt
   dir>/socket <destination>`. Exit 0 is `Up`.

**Authentication, and why the master is the pane's child.** A
headless server cannot answer ssh. The alternative, a batch-mode
master of the server that fails with "needs interactive
authentication", would need a CLI command to log in, which the user
ruled out. So the leader pane runs the master on its pty, which is
where a user who opened the pane is looking, in Kido.app and in the
terminal client alike. `ControlPersist=yes` detaches the master from
the pane, so the pane's own ssh session (step 3's forward and every
later pane) outlives the leader's `ko runtime-exec`; the master is
not a child of the server, so the server learns of its death by the
next `-O check` at the next pane, by its forward's panes dying, and
by the idle timer, which runs `-O exit`. A concurrent first pane that
is not the leader waits; if the leader's ssh fails (exit 255), the
link is `Failed` with ssh's last stderr line, every waiter dies with
it, and the next pane request starts over with a new leader.

**Panes through the master.** Each pane's `ssh` runs `-o
ControlPath=ctl -o ControlMaster=no`, so it authenticates once with
the master and is one channel of its connection. A master that dies
ends every pane of the runtime, the behaviour of a lost ssh session.
The alternative, one connection for each pane, keeps panes alive
through a master loss but authenticates for each pane and leaves the
inner agents without a socket while the master is down; it was not
chosen. The master runs with `ControlPersist=yes`; the idle rule's
`-O exit` ends it, and the server watches no file for it: the
leader's `master` report and `-O check` are its only sources.

**Cleanup.** `down` runs `-O cancel -R` (which leaves the file,
section 1.1), the passenger `rm -f <remote dir>/socket <remote
dir>/*.token`, then `-O exit`. A crash leaves the remote files; the
next `ko enter --prepare` removes them. A host
whose sshd sets `AllowStreamLocalForwarding no` fails at step 3 with
`Error::Refused`'s text.

**ko on the remote.** The ssh kind relies on an installed `ko` on
the Linux or macOS host, found on the PATH of a non-interactive
login, as `ko HOST` does today; `ko enter --prepare` reports its
absence. ko does not copy its static Linux build over ssh in this
plan; the upload comes with the bridge (section 10).

### 4.2 container

Apple's `container` runs each container in its own lightweight VM on
Virtualization.framework; its API server must run. The link:

1. `container system status`; a failure is `Failed` with "container
   system is not running: run container system start".
2. For `from.image`: `container inspect ko-<name>`; `container start
   ko-<name>` when it exists stopped; else `container run -d --name
   ko-<name> -v <rt dir>/socket:/run/ko/socket [-v HOST:RUNTIME[:ro]]...
   --mount type=bind,source=<share/ko/linux/<arch>>,target=/opt/ko,readonly
   [--ssh] <run_args> IMAGE <init>`, where `<arch>` is the image's
   architecture from `container image inspect` (section 4.3). The socket-file volume is the
   relay of section 1.2, so the runtime listener is bound before this
   command and stays at the same path forever; a re-bind is followed.
   For `from.container`: `container start` when stopped, and a check
   (`container inspect`) that it was created with a volume whose
   target is `/run/ko/socket`; without it the link fails with the
   `-v` the user must add.
3. `container exec ko-<name> ko version` (with `/opt/ko/bin` first on
   PATH when mounted): the version check of section 4.4, and "ko is
   not installed in runtime NAME" on exit 127.

The container's name is `ko-<name>`, not bound to the server
instance: a server restart finds and reuses it, and the files that an
agent installed inside persist, as a remote host's do. `DELETE
/runtimes/{name}` takes the link down and removes a
container that ko created (`container rm`); it never removes a
`from.container`. `down` stops a container that ko created
(`container stop`) and leaves a user's container running.
`--publish-socket` is not used: it is the container-to-host
direction, which an in-container bridge would need; the relay makes
that unnecessary, and the measured relay is the fallback's equal in
latency.

### 4.3 The static Linux ko

`make build-ko-linux` builds `ko` for `aarch64-unknown-linux-musl`
and `x86_64-unknown-linux-musl` with zig as the C compiler and linker
(`zig cc -target <arch>-linux-musl`, through the linker wrappers that
`.cargo/config.toml` names for the two targets), so libghostty-vt,
zig's static libc++ and musl link into one static executable with no
runtime dependency; the Rust targets come from the pinned toolchain
(`rustup target add`, recorded in `rust-toolchain.toml`'s `targets`).
The layout under `build/ko/share/ko/linux/<arch>/` is `bin/ko` and
`share/ko` with the shims and the terminfo; no `ko-pane`, because no
server runs inside. `make install` copies it, so the Homebrew formula
builds it too, and `make verify` checks that each binary is static
(`file` reports `statically linked`) and starts under `qemu-user` or
in the container e2e. The container kind mounts it read-only at
`/opt/ko` and `ko enter` puts `/opt/ko/bin` first on PATH, so an
image needs no ko of its own; `ko: "path"` opts out. The build is
part of the container unit (section 13), and the host's own ko and
the shipped Linux ko have the same `Ko-Vt` by construction, so the
version check of 4.4 holds for a shipped ko without a network.

### 4.4 The version check

Every kind runs the runtime's `ko version` once per link start and refuses
another `Ko-Protocol` major or another `Ko-Vt`: a runtime's `ko
shell`, `ko enter` and ko-pi must speak the host server's protocol,
and `xterm-ghostty` inside must match the terminfo of the host's
libghostty-vt. The error names both builds, as a remote attach's
mismatch does.

## 5. Identity and scope on a runtime connection

The agents plan (2.8) defines pane identity: `KO_PANE_TOKEN`, sent as
`Ko-Pane` and `Ko-Pane-Token`; a request without them over the host
socket is the user; a runtime's socket never grants user identity.
This plan supplies the other half:

- `Verified` (`ko_server/src/server.rs`) carries an `Origin`: `Host`
  or `Runtime(RuntimeName)`. The host listener admits a peer of the
  server's uid, as today. A runtime listener admits any peer uid (an
  ssh forward's peer is the local master; Apple's relay's peer is the
  engine's helper; a Linux container's is a namespaced uid, section
  1.3) and tags the connection with its runtime. The tag is the
  connection's for its life; a WebSocket upgraded on it keeps it.
- A request on a runtime connection must carry a valid pane identity
  of a pane **of that runtime**; else it is `refused`, "a runtime
  connection must act as one of its panes". A host pane's token
  presented through a runtime socket is refused: a token that leaks
  into a container buys nothing there. The token is minted and
  checked exactly as the agents plan says; this plan adds only the
  runtime comparison.
- `/client` is refused on a runtime connection: a client is the
  user's. Views and search are refused too: nothing
  inside a runtime mirrors a terminal; a harness reads a pane's bytes
  through `GET /panes/{id}/output` (ko-agents.md 2.4), which stays
  under the agents plan's rule.

**Visibility.** The agents plan keeps reads open for host callers.
For a runtime caller `c` of runtime `R`, this plan narrows them:

| request | a runtime caller may use it when |
|---|---|
| `GET /layout`, `GET /panes` | the document is returned whole; rows only for `visible(c)` |
| `GET /panes/{t}`, `/panes/{t}/vars` reads | `t ∈ visible(c)` |
| `GET /panes/{t}/screen`, `/clear_history`, `POST /panes/{t}/input`, resources | `t` is in `R` or a descendant of `c` |
| `GET /panes/{t}/output`, `/panes/{t}/messages`, `/stop`, vars writes, `POST /panes`, `POST /runs` | the agents plan's table (2.8), unchanged |
| `GET /runtimes/{name}/exec` (6.1) | never: a process inside a runtime has a shell of its own |

    visible(c) = panes of R ∪ scope(c)   (scope as in ko-agents.md 2.8)

**Who may exec.** On the host origin, the user and every pane
identity may open an exec session in any runtime: a host pane may
already create a pane in any runtime through `POST /panes`, so an
exec grants it nothing more, and no pane field is needed to permit
it. On a runtime origin the route is `refused`. The exec session is
the host's way into a runtime; it is never a runtime's way into
another.

A hidden pane is `refused`, not `missing`: the document already names
its id. Thus a host agent with a child in a container exchanges
messages, endings and stops with it through the same routes as with a
local child, the queued and idempotent messages of the agents plan
included (a child whose runtime link was down finds its messages
queued when its stream reader reconnects), the child reads its
parent's row and status for the parent watch, and neither reads the
other's screen unless the parent asks for the child's. The parent
edge is the one thing that crosses a runtime boundary.

**Inheritance.** A pane created on a runtime connection is in that
runtime: `POST /panes`, `POST /runs`, and the agents plan's restart
through `POST /panes`. The body field `runtime` is for host callers
only: the user through `ko api`, Kido.app, a host agent's
`spawn_agent(runtime)`. A
runtime caller that sets it to anything but its own runtime is
`refused`. A `PUT /layout` from a host client may create a pane with
`{new: {..., runtime?}}`. A host pane may parent a child in a
runtime; a runtime pane cannot parent a pane outside its runtime,
because it cannot create one.

**Interface with the agents plan.** `spawn_agent` gains `runtime?:
string`. In the routed mode (6.2, the default) the child is a host
pane whose ko-pi runs with `--runtime R`; `POST /panes` carries no
`runtime`, and the child's session file, `resume_from` and `fork`
are host files, so both work with `runtime`. In the inside mode
(`pi: "runtime"`) `runtime` is the `runtime` field of `POST /panes`;
the server refuses it for a runtime caller, so ko-pi needs no check
beyond wording, and `resume_from` and `fork` are refused with
`runtime`, because a saved session is a file of the spawner's
filesystem. `KO_AGENT_TRUSTED_CWD` (ko-agents.md 5.11) is a path of
the child pi's own filesystem: the host cwd for a routed child, the
mapped cwd (section 7) for an inside child. `list_agents` rows gain
`runtime` from the row's `runtime` field or from the trusted
`pi.runtime` variable (6.2). Everything else of the agents plan holds
unchanged, because nothing crosses a filesystem that a routed pi does
not cross through the exec session.

## 6. How a pane starts in a runtime, and how a command runs in one

`ko-pane` runs on the host and spawns the transport's client on the
pane's pty. The server builds the argv from the kind, the pane's
identity and the request. The inner side is one new subcommand, `ko
enter`, which runs inside the runtime:

    ko enter --socket PATH --pane pane_N [--token-file FILE] --runtime NAME [--cwd DIR] [--env K=V]... [-- CMD...]

The token never appears in an argv: `ko enter` takes it from
`KO_PANE_TOKEN` in its environment (the container kind) or reads it
from `--token-file`, a `0600` file that it unlinks after the read
(the ssh kind); a file that is missing or not private is `ko enter:
no token`, exit 1. It sets `KO_SOCKET`, `KO_PANE`, `KO_PANE_TOKEN`, `KO_RUNTIME`,
`TERM=xterm-ghostty`, `TERM_PROGRAM=ko`, `TERMINFO_DIRS` from its own
installation (the host's terminfo does not reach the runtime), its
own `share/ko/bin` first on PATH, each `--env`, changes to `DIR` and
execs `ko shell [-- CMD...]`. A `DIR` that does not exist is `ko
enter: cwd DIR: No such file or directory`, exit 1, and the pane dies
with it, as a host pane with a bad cwd does. `ko enter` never
overrides an inherited `SSH_AUTH_SOCK`.

Inside a runtime the `ko` CLI never starts a server: with
`KO_RUNTIME` set, the launcher of `ko` with no command refuses
("inside runtime NAME; attach from the host"), and `ko api` already
starts none.

The host-side argv for each kind:

- **ssh:** the server first writes the token file through a
  passenger over the master, with the token on the passenger's stdin
  and nothing secret in its argv: `ssh -S <ctl> -T -o BatchMode=yes
  <destination> umask 077 && cat > <remote dir>/pane_N.token`, a
  child reaped on `SIGCHLD` like every helper, after which the pane's
  `runtime-exec` is released from its wait. Then the pane runs `ssh
  -t -o ControlPath=<ctl> -o ControlMaster=no -o BatchMode=yes
  <ssh_args> -- <destination> exec ko enter --token-file <remote
  dir>/pane_N.token ...`, every remote argument single-quoted for
  `sh` (`'` as `'\''`), since sshd hands the string to the login
  shell. `SetEnv` was rejected: it needs the
  variable in sshd's `AcceptEnv`, which a default sshd limits to
  `LANG` and `LC_*` (macOS and Debian alike), and `SendEnv` has the
  same condition.
- **container:** `container exec -t -i [-u U] --env-file <rt
  dir>/panes/pane_N.env -e KO_SOCKET=/run/ko/socket -e KO_PANE=...
  -e KO_RUNTIME=... [-e K=V] [--cwd DIR] ko-<name> ko enter ...`, where
  the env file holds `KO_PANE_TOKEN=...`, written `0600` by the
  server before it starts the pane's `ko-pane`, in the `0700` state
  directory. `exec` takes the environment and the cwd as
  options, so `ko enter` repeats them only for `TERMINFO_DIRS` and
  PATH. The host-side argv is visible to every local user (`ps aux`
  shows other users' arguments on macOS and on Linux without
  `hidepid`), so a `-e KO_PANE_TOKEN=` there would publish the token.
- **command:** `<prefix> ko enter --socket <socket> ...`, on the
  host.

Each of these is wrapped as `ko runtime-exec NAME -- <argv>` (section
4): the host-side plumbing that only waits for the link, runs the
ssh master when it is the leader, and execs `<argv>`. The wrapper's
environment is a host pane's: the server's environment with the
host's `KO_SOCKET`, the pane's `KO_PANE` and `KO_PANE_TOKEN`, so it
can ask the host server about its own runtime with its own identity,
and nothing else of the pane's inner environment or the requested
`env`, which belong inside. Its cwd is the server's. The one token
thus lives on both sides of one pane, which is one trust unit.

**The server writes and removes the token files.** It writes the
container env file before the pane's `ko-pane` starts, and the ssh
remote file through the passenger above once the link is `Up`,
before it releases that pane's wait; the wrapper writes nothing and
needs no `ctl`, `dir` or destination. The server removes the env
file when the pane leaves the document; `ko enter` unlinks the
remote file after the read; a remote file that `ko enter` never read
(the pane's ssh died first) is removed by the next `ko enter
--prepare` of that runtime, which clears every `*.token` in the
directory, and by `down`'s cleanup passenger (4.1). Where the token
is readable: on the host, in the wrapper's environment (`ps -E`
shows only the caller's own processes on macOS; `/proc/PID/environ`
is `0400` on Linux) and in the `0600` files; inside the runtime, in
the pane's environment, as any pane's. Nowhere in an argv (section
9).

`ko enter` (with its modes `--prepare` and, later, `--bridge`) and
`ko runtime-exec` are plumbing:
hidden from `ko --help` (clap's `hide`), named in docs only as the
contract between the server and the runtime, and never typed by a
user.

### 6.1 The exec session: `GET /runtimes/{name}/exec`

A WebSocket that runs one command inside the runtime without a pane:
no pty, separate stdout and stderr, an exit status, and stdin from
the client. It is what a routed pi's tools call (6.2), and it is the
dedicated-connection session of the bridge (section 10) as an API.
Text messages, JSON, so `ko api --stream` carries it: each stdin line
of `ko api --stream` is one client message, each server message one
stdout line (ko-agents.md 2.6).

Client to server, the first message is `exec`; nothing else is read
before it:

    { type: "exec", argv: [String], cwd?: String, env?: {K: V}, stdin: bool }
    { type: "stdin", data: base64 }
    { type: "eof" }
    { type: "signal", signal: term | kill | int }

Server to client:

    { type: "stdout", data: base64 }
    { type: "stderr", data: base64 }
    { type: "exit", status: N } | { type: "exit", signal: NAME }
    { type: "error", message }

`cwd` is a runtime path and passes unchanged; absent means the
runtime's `cwd`, else the transport's default directory. `env` is
applied after the runtime's `env` and before the forced `KO_*`
variables, as section 7 says for a pane; a request names only what it
means to set, and nothing of the caller's environment crosses on its
own. `argv` is executed without a shell; a caller that wants a shell
names one (`["sh", "-lc", CMD]`). A `data` payload is at most 64 KiB
before encoding, so a message stays under the 1 MiB WebSocket limit.
After `exit` the server closes with 1000. `error` (the runtime is
`Failed`, the transport could not start, a message that does not
parse) closes with 1011 and is the one way a session ends without
`exit`. An `exec` into a runtime that is `Down` or `Failed` starts the
link as a first pane does (section 4) and waits for `Up` as a waiter
of the loop; an ssh runtime whose master needs the user cannot start
from an exec, because an exec has no pty: the session ends with
`error` "runtime NAME needs a pane to log in", and the spawner's own
pane is where the login happens.

**How it runs.** The server starts the kind's helper process as a
child with three pipes, non-blocking, on the loop
(`ko_server/src/runtime/exec.rs`; reaped on `SIGCHLD` like every
helper): for ssh a passenger over the master, `ssh -S <ctl> -T -o
BatchMode=yes <destination> -- cd DIR && exec ARGV...` with the remote
words quoted as section 6 quotes them, and the runtime's `env` plus
the request's as `K=V` words before `exec`, because sshd accepts no
other variables; for container, `container exec -i [-u U] --cwd DIR
-e K=V... ko-<name> ARGV...`; for `command`, `<prefix> ARGV...` on the
host with `cwd` as its directory. The helper's exit is the command's:
ssh returns the remote status (255 is ssh's own failure, reported as
`error`), `container exec` the process's (to measure in U3). A signal
ends as `exit { signal }` where the transport reports one; ssh
reports a remote signal as 255 with text, which the server maps to
`error`.

**Backpressure, both ways.** The server reads the WebSocket only
while the child's stdin pipe takes bytes, and it writes a `stdout` or
`stderr` record only while the connection's queue is below the cap;
otherwise it stops reading that pipe, and the command blocks on its
write as it does behind a full shell pipe. Nothing is dropped and
nothing spills. A WebSocket that closes first ends the session: the
server closes the child's stdin, sends `SIGTERM` to the helper, and
`SIGKILL` after `KO_STOP_ESCALATION_MS`; the remote command ends as a
closed ssh channel or a stopped `exec` ends it, best effort, which is
what a tool's abort or timeout wants.

**No file routes.** Read, write, list and search inside a runtime
are commands of its shell: `cat`, `test`, `mkdir -p`, `ls -1Ap`,
`find` or `fd`, `grep` or `rg`, which every image with a shell has.
A file route would need a file server inside the runtime, which the
ssh kind's installed ko could offer and the bridge's static ko could
too, but the exec session reaches the same files with less code and
no second protocol; a slow case (a large tree search) is slow inside
the runtime, not in ko.

**Limits.** One runtime has at most 32 exec sessions at once; a
request past that waits as a waiter of the loop until one ends, in
order, and `error`s after `KO_RUNTIME_EXEC_WAIT_MS` (30 s). The cap
exists for the ssh kind, whose master carries panes, passengers and
exec sessions as channels of one connection, which sshd's
`MaxSessions` (10 by default) bounds (decision 3 of 15a); the other
kinds inherit the cap for one behaviour.

### 6.2 Agents in a runtime: the routed mode and the inside mode

`spawn_agent(runtime: R)` starts, by the runtime's `pi` (section 3):

- **routed** (`pi: "host"`, the default): a host pane, `POST /panes`
  without `runtime`, whose command is `ko shell -- ko-pi --runtime R
  ...`. pi, its session file, its extensions, skills and provider
  credentials are the host's; its built-in tools and `!` commands run
  in R through exec sessions. The pane is a host pane in every row
  field: `runtime` absent, `cwd` the host shell's. ko-pi marks it with
  the pane variable `pi.runtime: { name: R, cwd: DIR }`, the runtime
  and the directory inside it that the agent works in, trusted as
  `pi.session` is (AGENTS.md, "Native agent status"); the variable is
  the fifth of the `pi.*` family and goes with pi's exit. Clients show
  it as they show the `runtime` field (section 8). The harness side is
  ko-agents.md 5.13.
- **inside** (`pi: "runtime"`): a runtime pane, `POST /panes` with
  `runtime: R`, whose command `ko shell -- ko-pi ...` runs inside
  through `ko enter`; the pane's `runtime` is R and every row field is
  the inner shell's. ko-pi sees `KO_RUNTIME` in its environment and
  routes nothing. This is the mode of the plan before 2026-11-04 and
  it stays as designed: the runtime socket, the identity rule and the
  visibility rule of section 5 are for it.

A routed pi is a host caller: it spawns through the host socket, its
children are routed by default in the same runtime (ko-pi passes
`--runtime R`), `spawn_agent(runtime: X)` from it is any host
spawner's, and the user's `ko-pi --runtime R` in a host shell pane is
the same thing by hand. A routed pi's `async_bash` is `POST /runs`
with `runtime: R` (a run pane inside the runtime, whose screen is
the output, ko-agents.md 5.12); `ko run-child` has no runtime flag by
decision 8, and `ko api` carries the body. The two modes do not mix
in one agent: a routed pi has no runtime socket and needs none.

**The row.** `Row.foreground` is the transport's process (`ssh`,
`container`), which says nothing about the inner program. The status
model (`ko_server/src/pane_kind.rs`) treats a runtime pane by its OSC
133 and OSC 7501 records alone, which the inner primed shell and the
inner agents emit through the transport as a remote shell does for
`ko ssh`: the kind is never `Ssh` (no `ssh.dest`), the foreground
name is not a title fallback, and the OSC 133 command line is. The
row's `cwd` is the inner shell's OSC 7 path, a runtime path. Clients
show the runtime from the row (section 8).

## 7. cwd and env mapping

A request's `cwd` is in the caller's filesystem. From a runtime
caller it is a runtime path and passes unchanged, as does the
default "the caller's cwd" (the row's cwd, a runtime path). From a
host caller into a runtime, the server maps it: the longest `paths`
entry whose `host` prefix matches gives `runtime` plus the rest; no
match gives the runtime's `cwd`; no `cwd` either gives no `--cwd`,
and `ko enter` runs in the runtime's own default directory. The
container kind derives `paths` from `volumes` (host to runtime) and
adds `paths` after them; ssh has `paths` only. The row's `cwd` shows
where the pane landed.

Environment: the pane gets the runtime's `env`, then the request's
`env`, then the forced `KO_*` and `TERM*` variables, which nothing
overrides. No host variable crosses unless named in one of the two
maps. `SSH_AUTH_SOCK` follows the kind's `agent` or `ssh_agent`.

## 8. Clients and the CLI

- Routes: `GET /runtimes` lists `{ name, kind, state, panes, socket,
  paths, cwd, pi }` (`paths` is the effective host-to-runtime prefix
  list of section 7, which a spawner uses to map a path; `cwd` the
  configured default directory; `pi` the agent mode of section 3);
  `GET /runtimes/{name}` one; `GET /runtimes/{name}/exec`, the exec
  session of 6.1; `GET /runtimes/{name}/wait?timeout_ms=`
  (a long poll for `Up` or `Failed`, answering `{ state, lead }`;
  `lead` is true for the one waiter that runs an interactive step,
  with the ssh master's arguments in `master_argv`; the server
  answers `Up` to a pane only after its token file is in place);
  `POST /runtimes/{name}/master { exit, stderr }` (the leader's
  report); `POST /runtimes/{name}/down { force }`; `DELETE
  /runtimes/{name}`. The `wait` and `master` routes accept only a
  host pane whose `runtime` is that runtime (its `runtime-exec`). The
  `runtime` event carries a changed entry. The `Welcome` carries the
  list, so a client needs no extra request to offer a runtime for a
  new pane. There are no `ko runtime` subcommands: `ko api /runtimes`
  and `ko api -X POST /runtimes/NAME/down` are the shell's way.
- The CLI gains no flag: a runtime pane is created through `ko api`
  (`POST /panes` or `POST /runs` with `runtime`), and `ko panes` shows
  a `RUNTIME` column.
- The terminal client: a pane row of a runtime shows the runtime name
  after the title, dimmed, from the row's `runtime` field, else from
  a trusted `pi.runtime` variable (6.2), with one style for both,
  because the user's question is "where does this agent work";
  `Ctrl+Shift+N` adds a window in the shown pane's `runtime` field
  (the host for a host pane, a routed pi's included). It has no
  chooser; the CLI and Kido.app have.
- Kido.app: the row shows the runtime name as a dimmed suffix of the
  title, one style for every runtime, by the same rule as the
  terminal client. The command palette gains one
  entry for each runtime of the `Welcome`, "Runtime: NAME", whose
  detail is the kind and the state (`ssh · up`); a `Failed` runtime
  shows its message there. When the focused pane is in a runtime, a
  "Host" entry comes first. Enter on an entry opens its step
  (`PaletteMode.runtime`), as Connect and Theme do, with three
  entries: New Window, Split Right and Split Down. The splits need a
  live focused pane, as the split commands do; Esc goes back to the
  root. Each entry sends one layout edit whose new pane names the
  runtime (none for Host); a runtime that is down starts with that
  pane. The step has no New Session: a session holds host and
  runtime windows together. The menu's split and new-window commands
  and their shortcuts keep one rule: the new pane takes the runtime
  of the focused pane. The sidebar's tree nests across runtimes by
  `parent` as before. A remote window to a Linux host offers that
  host's runtimes through the same `Welcome`.

## 9. Security

- The runtime socket is reachable by anything inside the runtime,
  whatever its uid, and the server trusts the transport to deliver
  only the runtime's connections: the state directory is `0700`, and
  the relay or the forward is the only path in. The token of a pane
  of that runtime is the identity; the uid is not.
- A runtime connection acts as a pane of its runtime or not at all.
  Its reads are the runtime's panes and the agent scope. It never
  attaches a client or a view. The host socket is never relayed or
  forwarded into a runtime.
- The token travels in `0600` files and environments only: a remote
  file in the `0700` socket directory that `ko enter` unlinks at
  once, or a host env file in the `0700` state directory; never an
  argv, because `ps` shows every user's arguments. Inside the runtime
  it is readable by processes of the same user, as the pane's
  environment is. The agents plan accepts the pane as the trust unit;
  this holds inside a runtime too.
- An Apple container is a VM: it shares with the host only the
  volumes it was given and the one relayed socket. `--ssh` is added
  only on request.
- `run_args` and `ssh_args` are the user's configuration, executed as
  the user; ko refuses the options it owns and nothing else.
- The reverse-forwarded remote socket is `srw-------` of the remote
  user in a `0700` directory. On a shared remote host, another user
  cannot connect; the remote user's other processes can, with a pane
  token of that runtime.

## 10. The stream layer: one abstraction, two transports

Every kind of link delivers **connections** to the server. Today a
connection comes from a listener (`Listener::accept` gives a
`UnixStream`, `Verified::admit` tags it, `State::accept` wraps it in
`Conn`). The socket transports (ssh `-R`, Apple's socket relay, and
later a bind mount or Firecracker's `uds_path_PORT`) all end in a
unix connection on the host's runtime listener, so they need nothing
new in `conn.rs`, `http.rs` or `ws.rs`. On the pane side, each kind
gives the pane's program one dedicated byte channel with a pty at the
far end (`ssh -t`, `exec -t`), so no multiplexing is needed either.

A bridge transport delivers the same things by other means: one byte
channel (the pane's pty with APC frames, a `virtio-serial` port, a
vsock connection) that carries frames:

| frame | direction | carries |
|---|---|---|
| `exec` | host to guest | argv, env, cwd, and a pty size or none |
| `data` | both | bytes, tagged `stdin`, `stdout` or `stderr` when the session has no pty |
| `resize` | host to guest | rows, cols |
| `exit` | guest to host | the status or the signal |
| `open`, `close`, `credit` | both | a stream id; only on a shared channel |

Over a dedicated connection a session is `exec`, `data`, `resize`,
`exit`. The exec session of 6.1 is this session as a WebSocket: its
messages are these frames with a base64 payload, and a bridge kind
serves `GET /runtimes/{name}/exec` by sending them on its channel
instead of starting a helper process. Over one shared channel the bridge adds `open`, `close` and
`credit` and multiplexes streams; the host side then creates a
`socketpair` for each `open` that is an API stream, keeps one end as
the stream's pump and hands the other end to `State::accept` as a
`Verified` with `Origin::Runtime(name)`, so from there the connection
is any connection. The pump is a plain owner on the loop: `data`
frames write to the socketpair, readable socketpair bytes become
`data` frames, `credit` is the window (the pump reads the socketpair
only while it has credit, so a slow inner reader stalls one stream,
not the channel). The codec lives in `ko_pane_wire` beside the pane
frames, because `ko-pane` will strip and inject the pty variant; that
variant's payload is base64 inside `ESC _ ko ... ESC \`, since APC
cannot carry `ESC \`, and the stdio variant is raw with a length
prefix. This plan fixes only that shape; the bridge is not in the
first units.

What the transports share: the runtime listener's identity rule
(section 5), `ko enter` (section 6), the link states (section 4), the
version check (4.4) and the clients' view of a runtime pane. What
differs is only how a connection arrives.

**`ko enter` grows into the pty bridge.** A later `ko enter --bridge`
is the pane's first process inside a runtime that gives only a pty:
it opens an inner pty for `ko shell`, binds its own unix socket in
the runtime as that pane's `KO_SOCKET`, and carries each connection
to it as `open`, `data`, `credit` and `close` frames in APC
(`ESC _ ko ... ESC \`) over its own stdin and stdout, which are the
outer pty; `ko-pane` strips the frames from the pty's output and
injects the host's frames into its input, and hands each stream to
`State::accept` through the socketpair pump above. The channel is
per pane, so the identity of every connection on it is the pane
itself, derived from the channel; no token travels on that path.
When the runtime has no `ko`, the host uploads the static musl ko
(4.3) over the same pty before `ko enter --bridge` starts. That is
the whole statement; the bridge is not designed here.

**Must not block the bridge.** The decisions of U1 to U3 that must
stay compatible with it:

- A connection is a stream with an `Origin`, whatever delivered it:
  `State::accept` takes a `Verified` from a listener today and from a
  socketpair pump later. No code below `accept` knows about sockets
  on disk.
- The identity rule of section 5 is "a valid pane identity of a pane
  of this runtime", with the token as one proof. A connection whose
  origin is a pane's own channel is that pane's identity without a
  token, and the token check is skipped, not failed, for it. The
  `Origin` enum gets a `Channel(PaneId)` variant then; `Runtime(name)`
  stays for the listeners.
- `ko enter`'s contract: the secret comes from the environment or a
  file, never an argv; the argv names the socket, the pane and the
  runtime; `--bridge` later adds a mode, and `-- CMD...` stays the
  tail; the server, not the wrapper, puts the secret in place. `ko
  runtime-exec` builds that argv in one place, and `--prepare` is the
  remote side's one other mode.
- Nothing assumes one link for each runtime: a bridge runtime has a
  channel for each pane and no link at all, so the registry's link is
  `Option`-shaped from the start (the `command` kind already has
  none), the listener is a kind's choice, and the idle rule counts
  panes, not links.
- `KO_SOCKET` inside a runtime is whatever the kind says, not always
  `/run/ko/socket`; `ko enter` takes it as an argument, as it does.
- The version check runs through whatever carries the first exec,
  not through a listener.
- The pane's host-side foreground is the transport; the status model
  reads only the inner records, so a bridge whose frames `ko-pane`
  strips changes nothing there.

## 11. Later kinds, and how they fit

Not designed here; this section shows that the model and the stream
layer hold for each, with the facts measured or read on 2026-11-03.

- **podman on Linux.** The link is a running container with the
  runtime *directory* bind-mounted (`-v <rt dir>:/run/ko`; a file
  mount pins the old inode) and `--security-opt label=disable` on a
  SELinux host (section 1.3); the pane is `podman exec -it -e -w ...
  ko enter`. The peer uid is a namespaced uid, which the runtime
  listener ignores by design. The kind is the container kind's
  module with a second argv table. The podman-machine case of macOS
  is out of scope.
- **Firecracker on Linux (KVM).** Its vsock device forwards a guest
  connection to CID 2 port P to the host unix socket `<uds_path>_P`
  (`docs/vsock.md`: "forwarded to AF_UNIX sockets expected to be
  listening at `./v.sock_<port_num>`"), so the runtime listener is
  bound at that name and nothing on the host changes. The guest
  needs a small `ko guest`: a unix listener at `/run/ko/socket` that
  connects each client to vsock 2:P (one guest connection is one
  host connection), and a vsock listener for exec sessions that the
  host reaches with `CONNECT port\n` and the dedicated-connection
  frames of section 10, with the pty in the guest; the host-side
  pane program is a small vsock client in `ko`. One VM for each
  runtime; snapshot and restore keep the guest's listen sockets and
  close its connections (`snapshot-support.md`), which suits the
  relay. cloud-hypervisor has the same vsock model and adds
  virtio-fs. Neither can be run here (no KVM).
- **QEMU.** On Linux through `vhost-vsock`, which needs an AF_VSOCK
  listener type on the host; on macOS only through `virtio-serial`
  with a unix chardev, one byte stream, the shared-channel bridge of
  section 10. **Lima** is the ssh kind with `ssh_args: ["-F",
  <limactl show-ssh config>]`; its `portForwards` also reverse-forward
  unix sockets. **Apple Virtualization.framework** directly exposes
  vsock only in the VM's owner process; Apple's `container` is that
  owner with a CLI, which is why it is the macOS kind.

## 12. Failure modes

| failure | what happens |
|---|---|
| the configuration does not parse | every runtime request is `invalid` with the line; the server runs |
| a runtime name that the file does not have | `missing`: "no runtime NAME in <file>" |
| `container system` is not running | `Failed`: "container system is not running: run container system start" |
| no `ko` on the remote or in the image | `io`: "ko is not installed in runtime NAME" |
| the runtime's ko is another protocol or terminal revision | `Failed` with both builds (4.4); the first pane dies with the text |
| ssh needs a password or a touch | the leader pane shows ssh's prompt; the other first panes show `starting runtime NAME` until the master is up |
| the user cancels the prompt or the login fails | `Failed` with ssh's last stderr line; every first pane dies with it; the next pane request starts a new leader |
| a pane request arrives while the runtime is `Starting` | the pane is created and waits with the others |
| the remote refuses streamlocal forwarding | `io` with `Error::Refused`'s text |
| the master dies or the container stops | the link is `Down`; every pane of the runtime dies with its transport; the next demand brings the link up |
| the host server restarts | the listener binds the same path; Apple's relay follows (1.2); an ssh forward is gone with the master and comes back on demand |
| the runtime directory is removed by hand | `up` recreates it; a container created against it keeps working, because its relay is by path |
| a pane's `cwd` does not exist in the runtime | the pane dies at once with `ko enter`'s message on its screen |
| a stale remote socket or token file after a crash | `ko enter --prepare` removes them at the next link start |
| an image pull takes longer than 120 s | the request fails with "still starting"; the link continues and the next request may find it `Up` |
| a link is down while a parent messages a child inside | the message waits in the server's queue (ko-agents.md 2.6) until the child's stream reader reconnects, or the child's pane dies and the parent gets `ended` |
| an exec session into a runtime that is `Down` | the session waits for the link as a first pane does; an ssh runtime that needs the user ends it with `error` "runtime NAME needs a pane to log in" |
| the link dies during an exec session | the helper exits; the session ends with `error` (ssh 255) or the transport's status; a routed pi's tool call fails with that text, and the next call starts the link again |
| a routed pi's `--runtime R` names no runtime, or one whose kind cannot start | ko-pi refuses every routed tool with the server's message and notifies the user at `session_start`; the pi itself runs |

## 13. Units and estimates

In order; U2 and U3 run in parallel after U1. U1 depends on the
agents plan's U1a (the token and `POST /panes`), because the identity
rule of section 5 needs both.

- **U1 runtime core** (sections 2 to 5, 6's `command` kind, the exec
  route of 6.1, 7, 8's routes and CLI): the configuration file and its schema (with
  `pi`), the registry and link state machine, the per-runtime
  listener and `Origin`, the identity and visibility rules, `runtime`
  on the pane record and row, inheritance and the `runtime` body
  field, the `/runtimes` routes with `wait` and the leader election,
  the exec session with its helper child, both backpressures, the
  close path and the session cap, `ko enter` and `ko runtime-exec`,
  the `RUNTIME` column of `ko panes`, the test-only `command` kind
  behind its knob with its exec, e2e on it (a new `runtime.rs`:
  inheritance, refusals, hidden rows, the first pane's wait and
  failure text, concurrent first panes, down with live panes, idle;
  exec with stdin, stderr, a status, a signal, a close before exit, a
  slow reader, the cap, and the refusal on a runtime origin). About
  4.5 agent-days, of which the exec session is about 1.5.
- **U2 ssh kind** (4.1, 6, 6.1): the leader's master on the pane's
  pty, the `master` report, `-O check` adoption, `ko enter
  --prepare`, the token passenger, the forward, the pane argv with
  quoting, the exec passenger with its `env` words and status
  mapping, cleanup; e2e under `KO_E2E_HOST_SSH=1` against the private
  sshd of `remote.rs`, which already has a test that refuses
  forwarding, plus one test with a key that needs a passphrase, typed
  into the leader pane, and one exec round trip. About 2.75
  agent-days.
- **U3 container kind and the static Linux ko** (4.2, 4.3, 6, 6.1):
  `make build-ko-linux` for the two musl targets with zig as the
  linker, the layout under `share/ko/linux/<arch>`, the static check
  in verify, the formula's build of the host's architecture only (the
  x86_64 target joins the formula when ssh starts copying ko, with
  the bridge); the container lifecycle, the socket-file volume, the
  `/opt/ko` mount, volumes, `--ssh`, the system check, `DELETE`, the
  exec through `container exec -i` with its status measured; e2e only
  behind `KO_E2E_CONTAINER=1` on a Mac where `container system
  status` succeeds, with a small image that the test pulls once.
  About 3.75 agent-days, of which the static build is about 1.5.
- **U4 clients** (section 8): `ko_client` model, the terminal
  client's suffix from the field or the trusted `pi.runtime` and
  `Ctrl+Shift+N` inheritance, Kido.app's palette entries and runtime
  step (with Host), row suffix and inheritance on split, visual
  snapshot tests for each palette state (the root entries, the step
  with and without a focused pane, a failed runtime, Host) and one
  for a routed pi's row. About 2.75 agent-days.
- **U5 ko-pi in a runtime** (6.2, and ko-agents.md 5.13): the routed
  mode, which is the larger part: `--runtime`, the mode choice from
  `GET /runtimes/{name}`, the exec client over `ko api --stream`, the
  seven routed tools with grep rebuilt, `!` through `user_bash`, the
  runtime cwd and the prompt sections, the context files read from
  the runtime, `pi.runtime`, `async_bash` through `POST /runs` with
  `runtime`, the notice about host-side tools; the inside mode's
  refusals and trusted cwd mapping; `runtime` on `spawn_agent` and in
  `list_agents` rows; the fake ko's exec and runtimes; the TypeScript
  suite and the prompt snapshot. About 3.5 agent-days, after the
  agents plan's U3 and this plan's U1, with the fake ko before U2 and
  U3.
- **Later** (section 11, not scheduled): the podman kind, about 2
  agent-days; the bridge codec and `ko guest` with a Firecracker kind,
  about 7 agent-days.
- **Docs**: a new `docs/design-runtimes.md` from this plan, and
  edits to design-ko.md ("Lifecycle and the command line",
  "Decisions"), protocol.md (sections 1, 7 and a runtimes section),
  design.md ("Spawning", "Knobs"), design-app.md ("Sidebar", "Command
  palette"), AGENTS.md ("The server"). The managers, about 1
  agent-day in total.

## 14. Risks

- **`ko` inside the runtime.** The Linux `ko` links `libstdc++` and
  glibc dynamically (`ko_vt_sys/build.rs`), so a `ko` mounted into a
  musl or slim image can fail to start, and a macOS host has no Linux
  ko to mount at all. A static Linux build (zig's static libc++, a
  musl target) would make one shipped layout work in any image. Until
  then the image provides its own ko. This is the largest practical
  risk of the container kind.
- **Two ko builds must agree.** The version check refuses a mismatch,
  so a release of ko has to reach every runtime, as a remote attach
  already requires.
- **Apple's socket relay is a documented side effect of `--volume`.**
  It is measured, and `--ssh` is documented as that very volume, but
  a future `container` could change it; `--publish-socket` with an
  in-container bridge is the fallback.
- **A token file left behind.** A pane whose `ko enter` never ran (an
  ssh session that died first) leaves `pane_N.token` on the remote
  until `down`'s cleanup or the next `ko enter --prepare`; the file
  is `0600` in a `0700` directory meanwhile, and the token is dead
  with its pane.
- **A master loss ends every pane of an ssh runtime.** Chosen for one
  authentication and one connection; a laptop that sleeps loses its
  remote panes as it loses a `ko ssh` pane today.
- **The runtime directory is `0755` and its socket `0666`** inside
  the `0700` state directory, so a non-root container process can
  connect.
- **The pane's host-side foreground is the transport.** Status comes
  from the inner shell's markers, which need the inner `ko shell`
  priming (bash 4.4 or zsh with dotfiles); a plain inner shell shows a
  running command for the whole pane life, as an unprimed `ko ssh`
  does.
- **Interactive ssh authentication** needs a terminal; Kido.app has
  none and shows the message with the command.
- **Image pulls** of `container` unpack every platform of a
  multi-platform image (about a minute for `python:3-alpine`), so a
  first start is slow, and the first pane shows one line meanwhile;
  the 120 s deadline is a guess.
- **The master outlives the server's knowledge.** A `ControlPersist`
  master that the leader pane started is nobody's child; the server
  finds its state by `-O check` at the next pane and ends it on idle.
  A server that crashes leaves it; the next server adopts it.
- **A static musl ko is a new build target**: zig as the linker for
  Rust, two more Rust targets in the pinned toolchain, and libghostty
  built for musl; the first unit may find a zig or wuffs issue.
- **sshd's `MaxSessions`** bounds the channels of one master: panes,
  passengers and exec sessions together. A routed pi with parallel
  tool calls beside several panes can hit 10; the cap of 6.1 queues
  rather than fails, but a host whose sshd sets a low `MaxSessions`
  still refuses a channel, which the exec reports as `error` and the
  tool call as a failure (15a, decision 3).
- **A routed pi is two filesystems.** Its session, extensions, skills,
  prompt templates, project `.pi/` resources and `@` completion are
  the host's; its tools, `!` and cwd line are the runtime's. A
  mounted project (container volumes) sees the same files on both
  sides; an ssh project sees them only through the tools, and pi's
  own loaders find nothing of it on the host. ko-agents.md 5.13 names
  what the harness reads from the runtime instead.
- **The helper's exit status is the transport's word.** ssh folds a
  remote signal into 255 and container's `exec` status is not yet
  measured; a tool that reads the status gets `error` text in those
  cases, not a number.

## 15. Decisions of 2026-11-03

The user decided the plan's last open questions; the sections above
apply them. For the record:

1. The test-only `command` kind exists only with the server knob
   `KO_RUNTIME_COMMAND_KIND=1` (section 3).
2. The ssh master's leader is elected through `wait`'s `lead` and
   reports through `POST /runtimes/{name}/master`; the server watches
   no file (4.1).
3. The master runs with `ControlPersist=yes`, and the idle rule's
   `-O exit` ends it (4.1).
4. A container image pull shows one line in the first pane and no
   progress (section 4).
5. A pane request into a `Failed` runtime retries the start at once
   (section 4).
6. The pane row carries no link state; clients read `GET /runtimes`
   and the `runtime` event (sections 4 and 8).
7. The Homebrew formula builds the static Linux ko for the host's
   architecture only; x86_64 joins when ssh starts copying ko (4.3,
   U3).
8. No `--runtime` flag on `ko run` or `ko layout edit`: the API only
   (sections 5 and 8).
9. An ssh host needs an installed ko; the upload of the static ko
   comes with the bridge (4.1, section 10).
10. `starting runtime NAME` is the whole text of a waiting pane
    (section 4).

## 15a. Decisions of 2026-11-04

The user decided these; the sections above apply them. No open
question remains.

1. An agent in a runtime is routed by default (6.2); the inside mode
   exists only for a runtime whose configuration says `pi:
   "runtime"`; ko never copies pi.
2. **The exec session is a WebSocket** (6.1), not a run: a run would
   give every tool call a pane, a pty that merges stderr and rewrites
   bytes, a window in the layout and a sweep; the tools need bytes, a
   status and stdin. The route is part of U1 (section 13).
3. **The ssh channel budget has no configuration field.** The cap is
   32 sessions for each runtime, which queue past it. sshd's default
   `MaxSessions` is 10, below the cap, and the two do not contradict:
   the cap bounds what ko admits to the loop, and sshd's limit is met
   on the retry path. An ssh `exec` that fails to open a channel (ssh
   exits 255 with "open failed" before any output) is retried once
   after the next session of that runtime ends, then reported as
   `error`. A host that shows the need can get a `max_sessions`
   field later.
4. **The exec session carries no caller environment.** pi's bash tool
   offers the host's environment to its operations; ko-pi passes none
   of it (ko-agents.md 5.13), and the runtime's login environment plus
   its `env` map apply. This is the credential boundary that pi's
   containerization doc says Gondolin does not give.
5. **`@` completion in a routed pi** lists host files, accepted for
   U5: a mounted project is the same tree, and an ssh project has no
   host tree to confuse. A later change can wrap the provider with
   `ctx.ui.addAutocompleteProvider` over an exec of `fd` or `find`,
   at a round trip for each keystroke.
6. **Other extensions' tools in a routed pi run on the host**, allowed
   with a prompt sentence and a notice (ko-agents.md 5.13): the
   harness cannot know which of them touch files, a refusal would
   break the user's setup, and pi documents the same for Gondolin.

## 16. Where the agents plan carries the runtimes

[ko-agents.md](ko-agents.md) applies the runtime changes; this list
is the index of them. On 2026-11-04 it gained the routed mode (its
section 4, 5.2, 5.11, 5.12 and 5.13) and the fixes that U1a's code
needs (its 2.5, 2.7 and 2.8).

1. **2.1 and 2.3.** `runtime: Option<RuntimeName>` on `CreatePane`
   and `Row`; the `runtime` body field of `POST /panes`, `POST /runs`
   and a new pane of `PUT /layout`, with the inheritance and refusal
   rules of section 5.
2. **2.6.** `from.runtime`, the sender pane's runtime, for the
   receiver's header. For a routed sender, ko-pi adds the runtime of
   its `pi.runtime` to the header itself.
3. **2.8.** The `Origin` of a connection, the identity rule on a
   runtime origin and the narrowed reads of section 5.
4. **Section 4 and 5.2.** `spawn_agent`'s `runtime`, the two modes,
   `async_bash` through `POST /runs` with `runtime` for a routed pi,
   and the `runtime` column of `list_agents`.
5. **5.9.** The parent watch reads the parent's row, which the
   visibility rule shows to a runtime child.
6. **5.11.** `KO_AGENT_TRUSTED_CWD` is the host cwd for a routed
   child and the mapped cwd for an inside child.
7. **5.13.** The routed mode in the harness: the exec client, the
   tools, `!`, the cwd and context files, `pi.runtime`, the notices.
8. **12.** U1a landed first without `runtime` and `Origin`; this
   plan's U1 adds them. U5 here follows the agents plan's U3.
