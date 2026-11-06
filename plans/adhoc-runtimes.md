# Ad-hoc runtimes

A plan. Nothing of it is built. When the work is complete, the agreed
design moves into `docs/design-runtimes.md`, `docs/protocol.md`
(sections 1, 7 and 15), `docs/design.md` and AGENTS.md ("Runtimes"),
and this file is deleted.

Today a runtime exists only as an entry of `runtimes:` in
`config.yaml`, and a pane is in a runtime for its whole life. This
plan adds runtimes that a user defines from the command line, that
belong to one ko session, and that a pane enters and leaves in place.

## 1. Goals

1. `ko run <kind> --name N [options] [-- CMD]` defines a runtime
   without an edit of the configuration file and puts the current
   pane into it, as `ko ssh` puts a pane onto a host.
2. The runtime is the session's: two sessions each have their own
   `dev`, and the server drops a session's runtimes with the session.
3. Everything that works for a configured runtime works for an ad-hoc
   one: `spawn_agent(runtime)`, `ko-pi --runtime`, inside and routed
   agents, exec sessions, the cwd mapping, the clients' marks.
4. The server learns when a pane enters and leaves a runtime from
   facts that it owns, never from a pane variable or a process name.

## 2. The user decisions

Settled before this plan; the design does not reopen them.

- Ad-hoc runtimes exist beside `runtimes:`, which stays. One
  `ko_config::runtime::Runtime` holds a config entry and an ad-hoc
  definition: one decode, one validation. The options of
  `ko run <kind>` map one to one to the kind's fields. Plug-in kinds
  are later (section 11).
- An ad-hoc runtime belongs to one layout session, in server memory
  only. When the session goes, the server stops it and drops the
  definition. The idle rule still takes an unused link down; the
  definition stays until the session goes.
- Names are for each session. An ad-hoc name equal to a configured
  name is refused. A name resolves by the caller's session.
- `ko run` with the same name and the same definition joins the
  runtime; `ko run --name N` with no kind joins it; another
  definition is refused.
- In place: `ko run` runs in the current pane as a foreground child
  of the shell. While it runs, the pane is in the runtime. When it
  exits, the pane is a host pane again.
- **One interface.** A configured runtime and an ad-hoc runtime are
  the same thing to every caller: the same `RuntimeInfo` in
  `GET /runtimes` and `GET /runtimes/{name}`, the same `Welcome` and
  `runtime` events, the same `wait`, `lead`, `down`, `exec` and
  `DELETE` routes, the same `spawn_agent(runtime)`, `ko-pi
  --runtime`, pane creation with `runtime`, client stripe and suffix,
  and the same Kido.app File > Runtimes menu and palette shutdown.
  The one difference is where the definition comes from: one enum
  field on the record, `source`. There is no parallel API and no
  second registry. The one new write is the registration of an
  ad-hoc definition.

## 3. The design

### 3.1 The key of a runtime

A runtime is identified by its **key**: its name and its source.

```rust
// ko_server/src/protocol.rs (wire)
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RuntimeSource {
    /// An entry of the configuration file. Its name is global.
    Config,
    /// A definition that a pane of the session registered; it goes with the session.
    Session { id: SessionId },
}

// ko_server/src/runtime/mod.rs
pub(crate) struct RuntimeKey { pub(crate) name: RuntimeName, pub(crate) source: RuntimeSource }
```

The one registry (`Registry` in `ko_server/src/runtime/mod.rs`)
holds every link under its key, and `settings_in(key)` reads the
definition from the file for `Config` and from the registry's
`adhoc` map for `Session`. Below that line nothing knows the source:
the link states, the start stages, the kinds, the listener, the
identity gate, the exec session, the idle rule and the cleanup queue
run on a key.

Every place that holds a `RuntimeName` as the identity of a runtime
holds a `RuntimeKey` instead: `Origin::Runtime`, the registry's
`links`, `cleanups`, `waits` and `announced`, the pane record, the
exec sessions, the `Wait` and `Who` of the start. The wire keeps the
bare `name` where the session is known from the request: a route
path, the `runtime` field of `CreatePane`, the row's `runtime`.

**The tag** is the key's one-word form for a file system and a
container engine: `<name>` for a configured runtime, `<session>-<name>`
(`session_3-dev`) for an ad-hoc one. A `RuntimeName` is
`[a-z0-9-]{1,32}` and a session id has an underscore, so the two
forms never collide. The tag names the runtime directory
`<state>/runtimes/<tag>/`, the container `ko-<tag>` and the remote
directory of the ssh kind. `RuntimeKey::tag()` is the one function
that forms it.

**Resolution.** A request names a runtime by name. The server
resolves it in this order: the ad-hoc runtime of that name in the
request's session, else the configured one, else `not_found` ("no
runtime dev in session_3 or in FILE"). The request's session is:

- for a pane identity, the session of the caller's pane in the
  layout;
- for `POST /panes` and a new pane of `PUT /layout`, the session the
  new pane lands in (the body's `session`, else the parent's, else
  the caller's; a new session of a `PUT` has no ad-hoc runtimes);
- for the user, who has no session: the configured runtimes alone,
  unless the request names a session (section 3.3, "The user
  caller", an open question).

An ad-hoc runtime shadows a configured runtime that gains the same
name later, while it lives; a new definition under a configured
name is refused (section 3.3).

**A pane stays in its runtime's session.** A pane whose runtime is
`Session { id }` is in session `id`. `PUT /layout` refuses a document
that moves such a pane into another session (`invalid`, "pane_7 runs
in runtime dev of session_3"). Thus the row's bare `runtime` name and
the pane's session in the layout always resolve to the pane's key,
and a client resolves a row with one lookup.

### 3.2 One type, two sources

`ko_config::runtime::Runtime` is the definition of both. The ad-hoc
definition travels as the JSON of `Runtime` (its `RawRuntime` codec,
one kind key beside the shared fields) in the body of `PUT
/runtimes/{name}`, and the server decodes it through
`protocol::decode`, so the newtypes of `values.rs` validate it once,
as they validate the file. The `command` kind in a body is refused
without `KO_RUNTIME_COMMAND_KIND=1`, as the file's is.

`ko run` builds a `Runtime` from its options in `ko/src/run.rs`:
clap's `value_parser` goes through the `TryFrom<String>` of each
newtype, and the kind is a clap subcommand.

    ko run ssh --name N [--ssh-arg OPT]... [--dir DIR] DEST [-- CMD]
    ko run container --name N (--from-image I | --from-container C)
        [--volume HOST:RUNTIME[:ro]]... [--user U] [--run-arg A]...
        [--init ARGV] [--ssh-agent forward|none] [--ko shipped|path|mount=DIR]
        [--program PATH] [-- CMD]
    ko run podman --name N ... (the container options without --ssh-agent)
    ko run command --name N ...  (test-only, as the kind is)
    ko run --name N [-- CMD]     (join: no PUT; the visit alone, of an
                                 ad-hoc or a configured runtime, because
                                 the visit is one route for both sources)

The shared options of every kind: `--env K=V` (repeatable), `--cwd
DIR`, `--path HOST:RUNTIME` (repeatable; the `paths` field),
`--pi host|runtime` and `--color #rrggbb`. Each option's `///` doc is
the field's `///` doc, so `--help` and the schema say the same.
`--volume` and `--path` parse `HOST:RUNTIME` into the config's
records; the config's YAML form stays a record. A `ko-run-<kind>`
shim is not in this plan.

### 3.3 The routes

Every existing `/runtimes` route serves both sources unchanged:
`GET /runtimes`, `GET /runtimes/{name}`, `GET .../wait`, `POST
.../lead`, `POST .../down`, `GET .../exec` and `DELETE
/runtimes/{name}` take a name, resolve it by section 3.1 and act on
the key. `RuntimeInfo` and `ClientRuntime` gain the one field
`source`. `DELETE` on an ad-hoc runtime drops the definition too
(section 3.7), as it removes a configured runtime's files; the route
is the same.

Two routes are new, and the user caller's disambiguation is one
query. Each needs the top-level session's approval.

**`PUT /runtimes/{name}`** registers an ad-hoc definition or joins
one. It is the one new write.

- Caller: a host-connection pane identity. The user without an
  identity is `refused` ("define an ad-hoc runtime from a pane of its
  session"); a runtime connection is `refused` by the gate (deny by
  default). The source is `session` with the caller's session.
- Body: `Runtime` (the config entry's shape). Required.
- Reply: `RuntimeInfo` of the runtime, with `source: session`.
- Refusals: a configured runtime has the name, `refused` ("dev is a
  runtime of FILE"); the session has an ad-hoc `dev` with another
  definition (`Runtime: PartialEq`), `refused` ("runtime dev of
  session_3 has another definition; delete it or use another name");
  the same definition, `200`, nothing changes; a body that does not
  decode, `invalid`; the `command` kind without the knob, `invalid`.
- Effects: the definition goes into the registry's `adhoc` map under
  the key with `fresh: true` (section 3.7). No link starts. A
  `runtime` event announces it to the clients.

**`GET /runtimes/{name}/visit`** is a WebSocket: the pane's lease on
the runtime (section 3.4).

- Caller: a host-connection pane identity whose pane is a host pane,
  not dead, and has no visit. Refusals: no identity, `refused`; a
  pane in a runtime or with a visit, `refused` ("pane_7 is already in
  runtime dev"); a runtime connection, `refused` by the gate; a
  name that does not resolve, `not_found`.
- The first client message is `visit`; nothing else is read before
  it:

  ```json
  {"type":"visit","cwd":"/Users/me/src","command":["bash"],"env":[{"name":"A","value":"1"}]}
  ```

  `cwd` is the pane's host directory as `ko run` read it, mapped as a
  `POST /panes` cwd is (`Dir::Host`); `command` is the `-- CMD`,
  optional; `env` is the `--env` list, after the runtime's `env`.
- Server messages, one JSON object each: `starting`; `lead {argv}`
  for the one visitor elected to lead (the ssh master's login);
  `up {argv}` with the transport argv to run (section 3.4); `failed
  {message}`; `ended {message}` when the server ends the visit. The
  client message `lead {exit, stderr}` is the `LeadReport`. After
  `failed` or `ended` the server closes with 1000. The connection's
  end, from either side, ends the visit.
- The gate: `WaitRuntime` and `ReportLead` stay for the wrappers of
  born runtime panes, with their rule "a pane of the runtime"; a
  visiting pane is a pane of the runtime while its visit lasts, so
  nothing changes there.

**The user caller.** A pane identity has a session, so a name
resolves. The user (no identity: `ko api` from outside a pane,
Kido.app) has none, and two sessions can each have `dev`.
`GET /runtimes` for the user lists every runtime, each with its
`source`, so a list needs nothing. A route with `{name}` does: the
smallest shape is one optional query `session` (`Option<SessionId>`,
a `Param`) on `GetRuntime`, `DownRuntime`, `DeleteRuntime` and
`ExecRuntime`, the four routes that the user calls; without it the
name is a configured runtime's. `PutRuntime`, `VisitRuntime`,
`WaitRuntime` and `ReportLead` are pane routes and have none. A pane
identity that sends `session` must name its own, as it may name only
itself elsewhere (protocol.md, section 1); another is `refused`. The
alternative is a second path, `/sessions/{id}/runtimes/{name}/...`,
which is a parallel API; the query keeps one route for each action.
The query is the decided shape (section 4).

`GET /runtimes` lists, for a pane identity, the configured runtimes
and the ad-hoc runtimes of its session; for the user, every runtime.
Both are one `Vec<RuntimeInfo>`.

### 3.4 The visit

**The lease is a connection.** Compare the ssh rule: `ko ssh` sets
`ssh.dest`, which any program can set, and the server believes it
only while an OS fact holds, the `ssh` foreground. That rule is
display-only trust, because the fact is a process name. A runtime
membership gates identity, so its facts must be the server's own:

- The start is a request with the pane's token on the host socket.
  Only a process of the pane has the token.
- The end is the end of that connection. The kernel closes the socket
  when `ko run` exits for any reason, a `SIGKILL` included. No message
  and no process name is trusted for the end.

Therefore `ko run` does not `exec` the transport as `ko ssh` does. It
holds the visit WebSocket and runs the transport as its child, on the
pane's tty, in the shell's foreground process group (the child
inherits the group). Its loop (`ko_sys::event`, one thread) watches
the WebSocket, `SIGCHLD` and `SIGHUP`, `SIGTERM`, `SIGINT`: a hangup
or term goes to the child; an interrupt is the tty's and reaches the
child's group by itself. The child's exit ends the visit (the
WebSocket closes) and is `ko run`'s exit status. The server's `ended`
or a close makes `ko run` send the child `SIGHUP`, then `SIGKILL`
after half of `KO_STOP_ESCALATION_MS`, print `runtime N: <message>`
on stderr and exit 1. The client side lives in
`ko_client/src/runtimes.rs` beside `bring_up` and `lead`, whose lead
step runner it reuses.

**What the server does at `visit`.** It resolves the key, mints the
visit token (section 3.5), sets the pane's membership to
`Visit`, sends the row event with `runtime: "dev"`, calls
`touch_runtime` (the pane occupies the runtime; the idle timer
stops) and, when the link is `Down` or `Failed`, begins the start,
as a first pane does. Then the visit is a waiter: `Who::Visit(pane)`
beside `Who::Pane` and `Who::Exec`. On `Starting` with an unclaimed
lead step the server sends `lead {argv}` at once, as `elect` does
for a wait. On `Up` the server writes the token file (or passes the
token to the remote through the ssh passenger) and sends `up` with
the argv; on `Failed` it sends `failed` and closes, and `ko run`
exits 1 with the message, as a wrapper's pane dies with it; the host
shell is back.

**The argv of `up`** comes from `runtime::pane::wrapper` without the
`ko runtime-exec NAME --` head, because the visit itself did the wait:
`<prefix> ko enter --socket S --pane pane_N --token-file F --runtime
dev [--tag TAG] [--cwd DIR] [--env K=V]... [-- CMD]`; for the
container kinds the `exec -t -i --env-file` form; for ssh, `ssh -t`
through the master. The server builds it, so no kind's argv exists
twice. `ko run` runs it as its child with the pane's tty as stdio.
The cwd is the mapped `cwd` of the `visit` message, else the
runtime's `cwd`.

**The row and the events.** `Row.runtime` becomes mutable: "the
runtime that runs the pane's program now; the host has none". A
change is a row change (protocol.md, section 7: no revision bump),
sent as the pane's row event, which exists today for variables and
status. The membership in the pane record:

```rust
// ko_server/src/pane.rs
pub(crate) enum Membership {
    /// Born in the runtime; the pane's token is its identity there, for the pane's life.
    Born { key: RuntimeKey },
    /// A host pane that `ko run` holds in the runtime while its visit connection lives.
    Visit { key: RuntimeKey, token: PaneToken, conn: Token },
}
// Pane { runtime: Option<Membership>, .. }; Pane::runtime() -> Option<&RuntimeKey> serves every reader.
```

`Telemetry.in_runtime` goes: it duplicates the pane's membership,
which now changes. `pane_kind::classify` and the cwd resolution take
the fact from `Pane::runtime()` at each use, so a visited pane is
read as a runtime pane (OSC records only; no foreground title; no OS
cwd read of the transport) and reads as a host pane again after the
visit. `ssh.dest` on a visited pane is ignored as on a born runtime
pane: the foreground is the transport.

**The cwd** of a visited pane follows the rule of a runtime pane
while the visit lasts: the inner shell's OSC 7 report is a runtime
path, mapped back through the runtime's `paths` for a new pane made
from it. After the visit, the host shell's next prompt reports the
host directory. The row's `cwd` is the last report, as today.

**The token file** is `<state>/runtimes/<tag>/panes/pane_N.token`
(or `.env`), the kind's choice, written before `up` and removed at
the end of the visit, as a born pane's is removed when the pane
leaves. The ssh kind's passenger writes it on the remote.

**The end of a visit**, from the server side (`State::end_visit`):
the membership goes back to `None`, the row event follows, the token
file goes, `touch_runtime` runs (the idle timer may start), and the
connections of the runtime that act as this pane are closed, because
their identity is dead (section 3.5). A visit ends when: the
WebSocket closes or hangs up (the child exited, `ko run` ended); the
runtime goes down for any reason (a forced `down`, a `DELETE`, the
watch of a container that stopped, a dead ssh master, the server's
exit); the pane dies or is removed. A down does not kill a visited
pane as it kills a born pane: it sends `ended {message}` and closes
the visit, and `ko run` ends the transport. `POST .../down` without
`force` refuses while a visit lasts, as it refuses live panes.

**The session goes while a pane visits.** `DELETE /sessions/{id}`
removes every pane of the session first, which ends their visits;
then section 3.7 stops and drops the session's runtimes. A visited
pane in another session cannot exist (section 3.1).

**Nested `ko run`** is refused. Inside a runtime, `KO_SOCKET` is the
runtime's socket, where every `/runtimes` route is refused by the
gate, so `PUT` and `visit` are refused by the server; `ko run` says
`ko run: inside runtime dev; run it from a host pane` when
`KO_RUNTIME` is set, before it asks, for the message only. Reasons:
a runtime inside a runtime would run the inner kind's CLI inside the
outer runtime, where the server, which runs every start stage as its
own child on the host, cannot reach; and the token files, the cwd
mapping and the listener would need a second hop. A second `ko run`
in the host shell of a visited pane cannot happen: that shell waits
for the first. A background `ko run &` of the same pane gets
`refused` ("pane_7 is already in runtime dev"). `ko run` also
refuses without a pane identity ("needs a pane") and without the
pane's tty on stdin ("needs the pane's terminal"), as the transport
needs one.

### 3.5 The visit token

The identity inside the runtime during a visit is a **visit token**,
not the pane's token. The server mints it at `visit` and writes it
to the token file; inside, `KO_PANE=pane_N` and
`KO_PANE_TOKEN=<visit token>`. On a runtime connection of key `K`,
`router::acting` accepts a request as `pane_N` when the pane is in
`K` and the given token matches the membership's token: the pane's
own token for `Born`, the visit token for `Visit`. On the host
connection only the pane's own token counts, as today.

Why: the host shell's token is the pane's identity for the pane's
whole life and cannot be rotated, because it is in the shell's
environment. A visit is short and repeats. A process that a visit
left behind inside the runtime (a background job in the container)
holds the visit token; after the visit it is dead, and at the next
visit a fresh one is minted, so nothing inside can act as the pane
between or across visits. With one token, a process left inside
could act as the pane at every later visit of that pane. A born
runtime pane's token dies with the pane, so `Born` keeps one token.
The cost is one field and one match arm.

### 3.6 Clients

`ClientRuntime` gains `source: RuntimeSource`. The `Welcome` lists
every runtime, configured ones first in name order, then the ad-hoc
ones in session order; `runtime` carries a whole entry as today, and
`runtime_deleted` carries `name` and `source`. The server announces an
ad-hoc runtime at its `PUT` and deletes it when its session goes or
at `DELETE`.

`Model::place` (`ko_client/src/model.rs`) returns the key: `Place::Pane
{ name, source }` and `Place::Routed { name, source }`, where the
source comes from the pane's session in the layout (an ad-hoc runtime
of that session has the name, else `Config`). `ko_tui`'s
`runtime_suffix` and Kido.app's lookup of the stripe's `RuntimeMark`
find the entry by key. The model JSON's `place` carries the source,
so the app changes one lookup. Kido.app's File > Runtimes menu and
its palette's shutdown list the model's `runtimes` as today, with
the session's name after an ad-hoc entry; the shutdown sends the same
`down` with the `session` query of 3.3. A visited pane shows the mark when
its row event arrives and loses it when the visit ends; the app's
stripe and label follow the row as they follow a status change.

**The colour** of an ad-hoc runtime is its `color` (`--color`), else
the hue of its name, the same rule as a configured one; two
sessions' `dev` share a hue, which is what a user who calls both
`dev` expects. The server stores no colour that the definition does
not have.

**A new pane** from a visited pane inherits the focused row's
`runtime`, as from a born runtime pane: a split of a visited pane is
a pane born in that runtime, in the same session, so the name
resolves; its cwd is the source pane's, mapped.

### 3.7 The lifecycle of a definition

The registry keeps `adhoc: BTreeMap<RuntimeKey, Adhoc { runtime:
Runtime, fresh: bool }>`. `settings_in(key)` reads the map for a
`Session` key and the file for a `Configured` key; `known` and
`sync` merge both. Nothing is written to disk but the runtime
directory, which exists for the link as for a configured runtime.

**The session's end.** `State::delete` compares the session ids of
the document before and after a removal (a session goes with its
last window, or with `DELETE /sessions/{id}`). For each session that
left: every ad-hoc runtime of that session gets a forced down
(its panes are already removed by the same change) and a
`delete` (the cleanup queue: the container `ko-<tag>` is stopped and
removed; the ssh master gets `-O exit`), its directory goes, the
definition leaves the map, and `runtime_deleted` goes out. `DELETE
/runtimes/{name}` on an ad-hoc runtime does the same for one.

**The idle rule** takes the link down and keeps the definition, so
the next visit or pane starts the link again and finds the stopped
container `ko-<tag>` by name, as a configured runtime does.

**A fresh definition and a stale container.** The container kinds
find a container by name. An ad-hoc container's name,
`ko-session_3-dev`, can exist from an earlier server that crashed
before its cleanup ran, with other volumes and another image. The
first start of a fresh definition (`fresh: true`) treats a container
of that name that ko created as stale: `inspect` finds it, a stage
`delete --force` removes it, and `run` creates it. After the first
start the flag is `false`, and a restart after an idle down reuses
the container. A user's container (`from: {container}`) is never
touched, as today. The ssh kind needs no such rule: `--prepare`
clears the remote directory at each start.

**The server's exit.** `Registry::shutdown` takes every link down.
For an ad-hoc runtime it also queues `Cleanup::Delete`, because the
definition dies with the server and nothing would remove the
container later. The commands run detached after the server, as the
stops do today.

### 3.8 The ssh kind and the tag

`ko enter` derives the remote directory from the runtime's name
(`enter::remote_dir`). Two sessions' `dev` on one remote host would
share it, so `ko enter --prepare` and a pane's `ko enter` take `--tag
TAG` (default: the name) and build the directory from the tag;
`KO_RUNTIME` inside stays the name, which the harness compares with
`spawn_agent`'s `runtime`. The server passes `--tag` only for an
ad-hoc runtime. The master's control socket is `ctl` in the runtime
directory on the host, which the tag already separates.

### 3.9 The harness

`spawn_agent(runtime)`, `ko-pi --runtime`, `fetchRuntime`, the exec
sessions and the registry entries of children send a name with the
pane's identity, so they resolve in the pane's session without a
change. A child's pane lands in the spawner's session, so it
resolves the same name. The tool text says "a configured runtime or
an ad-hoc runtime of this session" (`make prompts`). `list_agents`
shows the name as today.

**`ko-pi --runtime <name>` starts an agent in a runtime by name**,
ad-hoc or configured, in one way (a user requirement). It exists
today for configured runtimes (design-runtimes.md, "Agents in a
runtime"): at `session_start` the harness reads `GET
/runtimes/<name>` with its pane identity and follows the runtime's
`pi`. For an ad-hoc runtime nothing in the harness changes:

- **The name resolves in the caller's ko session**: the pane that
  runs `ko-pi` is a host pane of that session, a new pane or the
  same pane after `ko run` ended. `GET /runtimes/<name>` returns the
  session's ad-hoc `dev`, else the configured `dev`.
- **The link is down** (the idle rule took it down, or no pane has
  used the definition yet): `GET /runtimes/<name>` starts nothing,
  as today, and the first exec session of the routed pi (the context
  read at `session_start`) starts the link from the stored
  definition, as a configured runtime's first use does. The pane
  shows the harness's notice while the exec waits for `Up`.
- **The name is unknown in the session** and in the file:
  `GET /runtimes/<name>` is `not_found` with "no runtime dev in
  session_3 or in FILE", and the harness refuses as it refuses a
  missing configured runtime today: pi runs, every routed tool, `!`,
  `async_bash` and `spawn_agent` refuse with that message, and a
  notice says it. The error names the session, so a user who ran
  `ko run` in another session sees why.
- **Both pi modes.** `pi` is a shared field of `Runtime`, so
  `ko run <kind> --pi host|runtime` sets it (section 3.2; the default
  is `host`). `ko-pi --runtime dev` follows it as for a configured
  runtime: `host` routes the built-in tools through exec sessions;
  `runtime` refuses with "runtime dev runs pi inside it: start ko-pi
  in a pane of that runtime", and the way in is a pane born in `dev`
  (`POST /panes` with `runtime`, a split of a visited pane, or
  `spawn_agent(runtime: "dev")`, which reads `pi` and starts an
  inside child). Inside, `KO_RUNTIME=dev` and the harness routes
  nothing, as today.

## 4. Decisions on the open questions

The user took each recommendation; the top-level session approved the
two new routes of section 3.3.

1. **The user caller** names a session with one optional query
   `session` on the four `{name}` routes that the user calls. No
   second path under `/sessions/{id}/`.
2. **A stale container** `ko-<tag>` that ko created is deleted at a
   fresh definition's first start, with the engine label or the
   `ko-` prefix as the proof that ko created it, never a user's
   `from: {container}`.
3. **`--volume` and `--path`** take the colon form
   `HOST:RUNTIME[:ro]`; the YAML form stays a record.

## 5. Units, in order

Each unit has one manager, one implementer and the reviewers of
AGENTS.md. Tests are e2e first, on the `command` kind through
`serve` of `ko_e2e/tests/e2e/runtime.rs`; an ssh case runs under
`KO_E2E_HOST_SSH=1`.

**Unit 1: the key.** About 2 agent-days. `RuntimeKey`,
`RuntimeSource`, the tag, the registry and `Origin` keyed by it,
`ClientRuntime.source`, `runtime_deleted` with the source, the
`session` query on the four routes, resolution by session,
`Model::place` with the source, the TUI suffix and the app lookup,
`ko enter --tag`, `make schemas`. No ad-hoc runtime exists yet, so
every key is `Configured`; the unit is the plumbing.
Tests: the existing runtime e2e passes unchanged; a unit test of the
tag and of `RuntimeKey` ordering; a `ko_client` model test that a
`runtime` event with a `session` source is kept apart from a
configured entry of the same name; an e2e of the `session` query:
a pane identity that names another session is `refused`.

**Unit 2: definitions.** About 2 agent-days. `PUT /runtimes/{name}`,
the `adhoc` map, the join and refusal rules, the shadow rule,
`POST /panes` and `PUT /layout` with an ad-hoc runtime (a born pane),
the move refusal of 3.1, `GET /runtimes` for a pane and for the user,
the session's end (3.7), the fresh-and-stale stage, the delete at
exit, and `ko run` without the visit: the option mapping into
`Runtime` and the `PUT`. The e2e (command kind): a pane defines
`dev`; `GET /runtimes` from that pane lists it with `source: session`;
from a pane of another session it does not; the same `PUT` again is
200 and a different body is `refused`; a `PUT` under a configured
name is `refused`; a pane born in `dev` through `POST /panes` reaches
the runtime socket and its `KO_RUNTIME` is `dev`; `PUT /layout` that
moves it into another session is `invalid`; `DELETE /sessions/{id}`
takes the link down, drops the definition and sends
`runtime_deleted` with the source on a `/client`; two sessions each
define `dev` with different `prefix` argvs and each pane's `ko
version` through its socket reaches its own; the server's exit runs
the delete cleanup (a `command` kind `down` argv that writes a
file). A unit test: `ko run container --from-image I --volume
/a:/b:ro` builds the same `Runtime` as the YAML of that entry.

The `ko-pi --runtime` cases of 3.9 belong to this unit, because it
adds the name resolution. E2e (command kind, `ko_e2e/tests/e2e/agents.rs`
or `runtime.rs`): a pane of session A defines `dev` with `--pi host`,
then a new host pane of A runs `ko-pi --runtime dev` (the real `pi`
is absent in the suite, so the case runs `ko api /runtimes/dev` with
the pane's identity and asserts `source: session`, `pi: host` and
`state: down`, then opens one exec session on `dev` and asserts that
the link starts from the stored definition and the command runs); the
same request from a host pane of session B is `not_found` and its
message names `session_b` and the file; a definition with `--pi
runtime` reports `pi: runtime`. TypeScript (`share/pi/ko-pi-*.test.ts`,
the fake ko): with the fake's `GET /runtimes/dev` answering `source:
{type: session, id: session_3}` and `pi: host`, `ko-pi --runtime
dev` registers the routed tools and its first exec goes to
`/runtimes/dev/exec`; with `pi: runtime` the tools refuse with the
"runs pi inside it" message; with `not_found` and the session in the
message, the refusal text carries that message; `spawn_agent(runtime:
"dev")` on an ad-hoc `pi: runtime` entry starts an inside child with
`runtime: dev` in its `POST /panes` body.

**Unit 3: the visit.** About 3 agent-days. `Membership`, the visit
token, `router::acting` for both tokens, `GET /runtimes/{name}/visit`,
`Who::Visit`, the `up` argv, the row's mutable `runtime` and its
event, `Telemetry.in_runtime` removed, the end rules of 3.4, and
`ko run`'s client: the lease loop, the child, the signals, the lead
step. E2e (command kind, in the outer terminal where a tty is
needed): a pane runs `ko run command --name dev ...`; its row gains
`runtime: dev` and the sidebar of the terminal client shows ` dev`;
inside, `ko api /version` on `KO_SOCKET` succeeds with the visit
token and `KO_PANE_TOKEN` differs from the host shell's; the host
pane's token is `refused` on the runtime socket and the visit token
on the host socket; `exit` inside returns the host shell, the row
loses `runtime`, and the visit token is `refused` on the runtime
socket; a second visit mints another token; `POST .../down` without
`force` is `refused` while the visit lasts, and with `force` the
pane shows `runtime dev: ...` and is at the host prompt, not dead;
`ko run` under `kill -9` ends the visit (the row loses `runtime`)
without a message from it; a `ko run` on a runtime connection and a
`ko run &` of a visited pane are `refused`; the idle timer does not
fire while a visit lasts and fires after it; `ko run --name dev`
with no kind joins; the cwd of a split made from a visited pane maps
back through `paths`. A unit test of `acting`: the four token and
origin cases.

**Unit 4: the kinds, the harness and the docs.** About 1.5
agent-days. The ssh kind's `--tag` on the passenger and the pane
argv; the container kinds' `ko-<tag>` and the stale stage with a
`KO_E2E_CONTAINER=1` case (a fresh `ko run container --name dev`
in a second session beside a first); the harness text and `make
prompts`; an e2e under `KO_E2E_HOST_SSH=1`: `ko run ssh --name box
localhost` leads the login in place and the inside `ko version`
answers through the forwarded socket; `spawn_agent(runtime: "dev")`
from a routed pi in an ad-hoc runtime (the TypeScript suite's fake
ko answers `GET /runtimes/dev` with `source: session`). The manager
moves the agreed design into the docs and deletes this plan.

Total: about 8.5 agent-days.

## 6. Risks

- **The in-place transition is new state.** Every reader of
  `Pane::runtime()` must handle a change: the status model, the cwd
  resolution, the gate, the idle rule, the clients. Unit 3's tests
  cover each; the review checks every call site of `in_runtime` and
  `is_in`.
- **The lease as a connection** depends on the server's hangup
  detection on a request that waits, which the stop route already
  relies on (protocol.md, section 7). A `ko run` that is stopped with
  `SIGSTOP` keeps the visit, correctly: the pane is still in the
  runtime.
- **Container names with the tag.** `ko-session_3-dev` has an
  underscore; Apple's `container` and podman accept `[a-zA-Z0-9][a-zA-Z0-9_.-]*`
  (podman's rule; Apple's is measured in unit 4 before the stale
  stage is built).
- **A dead ssh master** ends a visit only when a check shows it
  (design-runtimes.md, "A dead master"); the visitor's transport dies
  with the master, so `ko run` exits and the visit ends from the
  client side. No new rule.
- **A loaded CI** and the outer-terminal e2e of unit 3: each case
  waits for a row event or a socket answer, never a time.

## 7. Not in this plan

- Plug-in kinds (`ko run <plugin>`), and the `ko-run-<kind>` shims.
- A definition by the user without a pane (Kido.app's "New
  runtime…"): `PUT /runtimes/{name}` would take `session` in a
  query, as the four routes do; the resolution rules already allow
  it.
- A runtime inside a runtime (section 3.4).
- Persisting an ad-hoc definition across a server restart.
- A `ko run` that attaches a second pane in place to a runtime whose
  kind needs a tty for the login while another pane leads: the second
  visit waits as a second pane does today.
