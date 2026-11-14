# In-process subagents for koa

This plan moves every agent of a koa pane into koa's own process as
a pi SDK session. A subagent is no longer a pane: it is a sidebar
record of koa's pane, and the page shows it as a view. The child-pane
machinery goes: slots, breadcrumbs, child windows, the parent watch,
reports over ko, task variables, the agent environment.

Settled by the user (2026-11-13):

1. Subagents are `AgentSession`s inside koa, through the pi SDK, not
   pi processes in child panes. The shared crash blast radius is
   accepted.
2. Each subagent is a status record of koa's pane. A click on the
   record goes to koa through the pane's message queue; koa treats it
   as control input and switches its page to that agent's view.
3. The child-pane code goes. The generic pane `parent` stays where a
   user remains.
4. The root agent moves in-process too.
5. Messaging reaches what it reaches today, and a sender that knows
   an in-process agent's address reaches it in another pane. Listing
   and `@name` show the caller's own tree and the pane peers' roots
   only.
6. The sidebar item API knows nothing of agents or jobs.
7. The way back to the root is a bar in koa's page. Hierarchy keys
   are out of this plan and come back later as their own item.
8. An inside subagent of a host koa goes. `/restart` is an
   unconditional `execve` restart. The guard reads `koa.edge`. The
   suite runs on a fake provider. `close: on_exit` goes in a later
   unit.

Verified against this worktree (origin/main 2b8125a58) and the
installed pi 1.5.2. The prototype notes in
`/tmp/koa-inproc-pso3Ea/NOTES.md` read an older checkout: its
`share/pi/ko-pi.ts` is `share/koa/koa-agent.ts` here, and
`koa-sessions.ts` is `koa-channel.ts`. Its findings about the SDK
hold.

## Decisions of this plan

**The root agent moves too.** koa stops spawning `pi --mode rpc`.
Every agent of the pane, the root included, is an in-process session
of one host. The alternative, an RPC child for the root and SDK
sessions for the children, keeps two event paths (RPC JSON lines and
SDK events), two extension loading paths (`--extension` with
`globalThis` state, and inline factories with per-session services),
the fd 3 channel, the `/koa-reload` prompt trick and the RPC
deadlines, and gives the root a crash isolation that its children do
not have. One model is smaller and has one set of bugs. The cost:
koa must supply what RPC mode supplied for free (the extension UI
context, the command handlers, the session switch), a pi fault now
ends koa (mitigated below), and koa's tests can no longer script a
pi (they script a model provider instead, "Tests").

**One host, per-agent services.** `koa.ts` becomes the host of the
pane: the HTTP server and the page, the view selection, the status
records, the one shutdown. A new module `koa-agents.ts` holds the
tree of in-process agents and creates each session:

    type Agent = {
      id: string;                       // the pi session id
      name: string;                     // the window-name rule of today: 1..64 bytes, no control, no "/"
      parent: Agent | undefined;        // undefined for the root
      children: Agent[];
      runtime: AgentSessionRuntime;     // root: the one that /new, /resume, /fork switch
      services: AgentSessionServices;
      jobs: JobRegistry;                // owned by the host, see "Jobs"
      view: AgentView;                  // today's per-pi state of koa.ts: feed, queue, dialogs, bash, compaction, model facts
      routed: Routed | { refusal: string } | undefined;
      life: { type: "starting" } | { type: "ready" } | { type: "failed"; message: string } | { type: "ended"; cause: string };
    };

A session is made with `createAgentSessionServices({ cwd, agentDir,
modelRuntime, extensionFlagValues, resourceLoaderOptions: {
extensionFactories: [{ name: "koa", hidden: true, factory:
agentExtension(host) }] } })` and `createAgentSessionFromServices`
over a `SessionManager` of the agent's file, wrapped in
`createAgentSessionRuntime` so that the root's `/new`, `/resume` and
`/fork` use pi's own switch. One `ModelRuntime` serves the process:
the credentials are the host's `auth.json`, the same for every
agent. (The probe used one runtime for each session only to fake a
transport.) Each session gets `bindExtensions` with koa's own
`ExtensionUIContext`: `select`, `confirm`, `input` and `editor` are
the page's dialog cards of that agent's view, `notify` is a notice
item of that view, `setStatus` the foot's statuses, `setEditorText`
the composer of that view; `setWidget` and `setTitle` do nothing, as
today. `hasUI` is true for every agent, so the extension's gates do
not change meaning.

**The agent extension takes its host from a closure.**
`share/koa/koa-agent.ts` exports `agentExtension(host: AgentHost):
ExtensionFactory` and is loaded as an inline extension of each
session, never through `--extension`. `AgentHost` is the one
interface between the extension and koa:

    type AgentHost = {
      self: Agent;                                  // identity: no KO_PANE, KO_AGENT_* or process.cwd()
      pane: string | undefined;                     // koa's pane, for ko api calls and the status route
      ko: string | undefined;                       // the ko executable, or undefined outside ko
      browser: boolean;                             // from koa's --browser flag, for top-level spawns
      scope(): Agent[];                             // self's children, siblings and ancestors with their siblings, in this process
      spawn(plan: SpawnPlan): Promise<Agent | { error: string }>;
      deliver(to: Agent, message: InProcessMessage): Promise<void>;
      stop(agent: Agent): Promise<void>;
      report(from: Agent, text: string): Promise<void>;
      records: RecordWriter;                        // one queue for the pane's status route
      completionContext: (resolve: () => Promise<CompletionContext>) => void;
    };

Everything that was process-wide in the extension becomes a field of
the host or of the agent: the message receiver and its id ring, the
job registry and its exit cleanup, the pane and parent identity, the
cwd of the routed tools (`host.self.services.cwd`, never
`process.cwd()`), the completion-context resolver (one for each
agent; koa asks the viewed agent's), the fd 3 channel (gone), the
`isFirstCopy` claim (gone: the factory runs once for each session).
The `AgentSession.prototype.clearQueue` wrapper stays one
process-wide patch, applied once in `koa-agents.ts` at import, because
the queue take-back is the host's own command now and the wrapper
protects custom messages in every session alike; the plan asks pi for
a `clearQueue` that keeps custom messages, and the patch goes when pi
has it.

**Session files.** A subagent's session lives where it lives today:
`<agent dir>/ko-subagents/<per-cwd name>/`, through
`SessionManager.create(cwd, dir)` for a fresh session,
`SessionManager.open(file)` to continue one and
`SessionManager.forkFrom(file, cwd, dir)` for a copy. The reasons of
design-subagents.md, "Where a child's session lives", hold: pi lists
`--resume` sessions before any extension loads, so a subagent's file
must be outside pi's tree. The root's session is where pi puts it.

**The registry stays in the parent's session.** The parent's
`koa.agent` (role `subagent`: `name`, `session`, `model`, `fork`,
`cwd`, `runtime`; no `pane`), `koa.work`, `koa.report` and
`koa.ended` entries stay, with `owner`, for the reasons of
design-subagents.md, "The registry": `read_report`, a restart after
koa's own restart, and `/tree` semantics. The child's own `koa.work`,
`koa.report` and `koa.sent` entries go: "has this child reported on
its last work" is one fact, computed from the parent's branch by the
host, which holds both sessions. A child's session gets one entry at
its creation, `koa.edge { parent: <session id> }` (its own fact that
it is a subagent); the repo's `no-git-writes` guard reads that entry
from `ctx.sessionManager.getBranch()` instead of
`KO_AGENT_PARENT_SESSION`, which goes. A top-level agent and a session
that a person started have no edge entry.

**Names and depth.** The rules of "What a child is given" stay: a
name is unique among the caller's registry children and live own
children, `async_bash` names share that set, depth is at most 2
(root 0, subagent 1, subagent 2), checked on the in-process tree.

**Spawning.** `spawn_agent` without `toplevel` creates an in-process
agent: it resolves the model with the services' `ModelRegistry`
(`pi --list-models` goes), checks `cwd`, mints the session id, makes
the session, appends `koa.agent` and `koa.work` in the caller's
session and `koa.edge` in the child's, writes the child's status
record and delivers the task as the child's first user message
(`sendUserMessage`; the `koa.task` pane variable goes). `fork: true`
copies the caller's file with `forkFrom`; `resume_from` opens the
found file as today ("Resuming a saved session" keeps its directory
walk and its model-from-file rule). A session that a live in-process
agent or a live pane holds in `pi.session` is refused. Project trust:
the host gives the child's runtime a `projectTrustContext` whose
answer is `yes` for the directory that the spawner trusts
(`isProjectTrusted()` and the same git common directory), and
`undecided` otherwise; `KO_AGENT_TRUSTED_CWD` goes. The result text
stays; its placement names the agent, not a window and pane:
`spawned reviewer (session <id>)`.

`toplevel: true` stays a pane: `POST /panes` with `ko shell -- koa`,
no `parent`, `--browser` under `host.browser`, the task as `koa.task`.
It is the one remaining use of `koa.task`, of `ko shell -- koa` and
of `restartArgs`.

**An agent's address is (pane, session).** Every in-process agent
shares koa's pane, so the pane no longer names an agent. An agent is
its pi session id, as today, and its place is the pane that hosts
it. Nothing publishes the in-process agents of a pane: there is no
pane variable for them, because no other pane lists them.

**What a caller lists.** `list_agents`, the `@name` completion and
name resolution show the caller's scope: its own tree by today's
rule (its children, its siblings, each ancestor and that ancestor's
siblings), all in its own process and read from the host, and the
pane peers of its root: the root agents of the other pi agent panes
of the ko session, from `/layout` as today. Another pane's subagents
never list. `AgentRow` keeps `id` as the session and gets

    where: { type: "process" } | { type: "pane"; pane: string }

`which` keeps its three values: `subagents` the caller's children,
`peers` its siblings (the pane peers for a root), `all` the scope.
An own child's row keeps `model`, `reported` and `report`. An ended
child is a registry child with no live agent, with the cause
`stopped`, `koa restarted` or `its session ended on an error`. The
page's `@name` links and koa's `agentDiscovery` use the same set for
the viewed agent.

**An explicit address reaches a subagent of another pane.**
`message_agent` accepts, beside the forms of design.md,
"Addressing", the form `pane_N/<session id>`, with a whole session
id. It is not resolved against a list: the tool posts to `pane_N`
with `data.to`, and the host of that pane answers. A sender learns
the address from the header of a message that the subagent sent it,
which names the session and the pane: `message from @reviewer
(session <id> in pane_7; another agent in this session, not the
user):`. There is no lookup from a session id alone: ko keeps no
such fact, and the plan adds no store for it. `stop_agent` and
`read_report` do not take the form: a stop reaches a caller's own
tree and the pane peers' roots.

**The message names its target and its sender in `data`.** A message
to or from an agent that is not its pane's root carries, in the
existing `data` field (4 KiB, which the server never reads):

    data: { to?: string; from?: { session: string; name: string }; runtime?: string }

`to` is the target's session id; absent means the pane's root agent,
so `ko prompt`, the app's prompt palette and a plain pi peer need no
change. `from` is the sending agent when it is not its pane's root.
The server still stamps `from` (the pane, with the root's
`pi.session` and `pi.name`) and `relation` from the pane edges and
enforces the pane scope; it reads no `kind`, `text` or `data`. The
trust is today's: every process of a pane can send as that pane.

**koa demultiplexes the pane's one queue.** The host owns the pane's
one message stream (`ko api --stream /panes/$KO_PANE/messages`), the
ring of received ids and the acks; they were the extension's, and
`session.reload()` does not touch them. For each `user`, `message`,
`steer`, `interrupt` and `notice` it resolves `data.to` to a live
agent of its tree (absent: the root) and hands the message to that
agent's extension instance, which delivers it as today, with the
sender header built from `data.from` and the stamped pane when
`data.from` is present, else from the stamped sender. koa adds no
scope check of its own: every sender that the server let reach the
pane reaches the agent that it names. A `to` that names no live
agent is refused (`refuse`), so the sender's tool says "no longer
running". A `stop` shuts koa down, as today; a `stop` with `to` is
refused, because no tool sends one. `select` goes to the host's view
switch ("The click").

**Sending.** A target in the caller's own process is handled by the
host directly (`host.deliver`, `host.stop`): the same custom message
types, headers and `details` as today (`ko-message` with `followUp`,
`ko-steer` with `steer`, interrupt as abort then message at the
settle), the relation from the tree, `koa.work` appended in the
sender's session for an own child, no ko round trip, no ids or
resends; the result is `delivered to NAME` or the error. A target in
another pane (a peer's root, or an explicit address) goes through
`POST /panes/{pane}/messages` as today, with `data.to` for an
explicit address and `data.from` when the sender is not its own
pane's root; ids, resends and the reply states are today's.
`stop_agent` on a pane peer's root is today's path: kind `stop`,
then the pane stop with its escalation, and `force`. `force` is
refused for an in-process target.

**Peers.** Only a pane's root agent records peers, from its
`/client` stream, as today; a recorded peer is a pane's root, and an
ended one restarts as a top-level pane on a message.

**Reports** are in-process. The child's settle rule stays as
design-subagents.md states it (not aborted, not ended by a control,
not a provider error, not yet reported on its last work or a new
text, no own running non-service job, no own live child that owes a
report), computed by the host without any ko read. `host.report`
appends `koa.report` in the parent's session and delivers a
`ko-notice` custom message with `details.inbound.form = "report"`,
`deliverAs: "steer"`, `triggerTurn: true`, capped at 4000 bytes with
the `read_report` pointer. The error notice (a turn that stops on a
provider error) stays. The exit notice goes: a child ends only
through its parent, `stop_agent`, or koa's own end, and in every
case the parent knows. The `ended` message of the server goes
("Where generic `parent` stays, and what goes").

**Stopping.** A stop of an in-process agent stops its subtree,
deepest first: each agent's jobs get the stop of "Stopping a job",
its records are cleared, `session.abort()` is awaited, pi's
`session_shutdown` runs for its extensions, then `dispose()`.
`koa.ended` is appended for an own child. The implementer verifies
whether `AgentSessionRuntime.dispose()` emits `session_shutdown`
(the probe found that `AgentSession.dispose()` does not); if it does
not, the host emits it through the session's extension runner before
`dispose()`. Stopping an ancestor stops the caller with it.

**The subagent record.** koa writes one status record for each
in-process agent other than the root, through the pane's status
route, in one ordered queue with the job records (today's
`writeJobRecord`). The id is the path of names from the root:
`agents/<name>` and `agents/<a>/agents/<b>`; an agent's jobs are
`agents/<a>/jobs/<id>`, and the root's jobs stay `jobs/<id>`
(renamed from `job/<id>`: one namespace rule, plural, for both). The
depth stays under `MAX_STATUS_DEPTH` (8). A clear of `agents/<a>`
removes the agent's subtree, which is what a stop needs. The fields:
`title` is the name; `state` and `msg` follow the root's own rule in
`status()` of `koa.ts`: `working` from `agent_start` and during a
compaction, `blocked` with kind `question` while a dialog of that
agent is open, `done` or `error` from the last assistant message at
the settle, `idle` after an abort; `msg` is the dialog's title, the
error's first line, else the first line of the last assistant text.
`selection` is `selected` for the viewed agent and `offered` for
every other. The server stamps `started`, so the sidebar
clock runs while the agent works. The root's own OSC 7501 root
record stays koa's and is written on stdout as today.

**The sidebar item API is agnostic of what an item is.** A record
is an item of a pane's row; ko, ko_client and Kido.app know nothing
of agents or jobs in it:

- A record id is an opaque path. The server and the clients read
  only its `/` nesting (`StatusId::is_within`, the clear of a prefix,
  the row tree of `Rows.swift`). Checked in this worktree: no code of
  `ko_server`, `ko_wire`, `ko_client`, `ko_tui` or `app/` dispatches
  on an id prefix; `job/` occurs only in tests of
  `program_status.rs` and `pane_status.rs`, as sample ids. The names
  `agents/` and `jobs/` above are koa's own.
- `state`, `title`, `msg`, progress and the server's `started` are
  generic. `app` is the one field with an agent meaning, and only on
  the root: the root's `app` of `pi` or `claude-code` classifies the
  pane (`pane_status.rs`). On a non-root record it is inherited text
  that nothing dispatches on, and koa sets none. It does not change.
- Kido.app maps a record to a row through the agent row path
  (`Rows.swift`: the row's `agent` flag, "exactly one hidden child
  that is an agent"). Unit 2 renames that flag to what it means (the
  folded line shows the child's title) so that no record code says
  agent or job; the look does not change.

`StatusRecord` in `ko_wire/src/protocol.rs` gets one field, carried
into `ProgramRecord` unchanged:

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<Selection>,

    #[serde(rename_all = "snake_case")]
    pub enum Selection { Offered, Selected }

Absent: a selection of the record means nothing to the program.
`offered`: the program acts on a `select` of this record.
`selected`: it is the record that the program shows now. It is one
enum, not two bools, because a selected record that is not
selectable is not a state. Only the status route can set it:
Ghostty's OSC 7501 parser has no such option, so an OSC record never
has it. Clients ignore it on the root record: the pane row is a
pane.

**The program owns which record is selected.** The fact has one
store, the record set, and one writer, the program: koa writes
`selected` on the viewed agent's record and `offered` on the others
at each view switch, through its one record queue, so the server's
`status` event carries the change to every client, and a client that
connects late reads it from the row. A client never marks a row from
its own click or from the reply of the `select`: another client, the
page's own bar or an `@name` link can switch the view too.
The meaning is generic: a program with selectable items says which
one it shows. Client rule, for any program: at most one record of a
pane is `selected` (the client takes the first by id if a program
writes two); while the pane is the focused pane and has a selected
record, that record's row takes the focused-row fill and the
semibold title, and the pane row drops them; with no selected record
the pane row has them, as today.

**The click.** A client that shows records offers the selection of a
record only while its `selection` is set and the pane's `inbox` is
open. It sends `POST /panes/{id}/messages` with a new `SendKind::Select`,
the record id as `text`, no `data` and a minted `MessageId`. The
server reads none of it, as for every kind: it stamps the sender and
queues. Any program can receive it on its message stream. The
receiver decides what a `select` is; koa accepts it only from
`from: user`, as control input, never as a prompt, switches its view
to the agent of that record id and acks; one from a pane, or for an
unknown id, is acked and ignored. The empty id, the root record's,
selects the root view, so a client needs no second message for the
way back. Kido.app sends it through one new
C ABI function, `ko_client_select_record(client, pane, record_id,
out)` in `ko_client/src/ffi/calls.rs`, declared in `ko_client.h`
and `exports.txt` beside `ko_client_prompt`, with the `Posted` state
in `out` (`ko_client_select` is the pane selection). The app selects
the pane first, as a click on the pane row does, then sends the
select, and treats every reply but an error as done. A record row
with a `selection` is a click and Return target, part of the arrow
navigation, with the accessibility role of a button; any other
record stays display-only. While a record is `selected`, a click or
Return on the pane row sends the select of the root record after the
pane select. A record can also be `closeable`; its × sends a `close`
message through `ko_client_close_record`, and koa stops that subagent
and tells its parent (docs/protocol.md, section 7, "Messages";
docs/design-app.md and docs/design-subagents.md give the rules). `ko_tui` draws no records and still draws
none. No ko route is added.

**The view in the page.** koa keeps one `Transcript` feed for each
agent and shows one at a time, the view. `State` gets:

    view: { id: string; path: { id: string; name: string }[] }   // the root first, the viewed agent last
    agents: { name: string; target: { type: "view"; id: string } | { type: "pane"; pane: string } }[]

A switch publishes a `reset` from the new agent's feed under a new
epoch and a `state` of that agent: the fields that are one agent's
(`working`, `since`, `aborted`, `name`, `model`, `thinking`,
`levels`, `context`, `cwd`, `sessionId`, `sessionFile`, `queue`,
`dialogs`, `statuses`, `editor`, `bash`, `compaction`) come from its
`AgentView`; `pi` becomes `life`, per agent, with `switching` and
`reloading` only on the root. The look and the geometry of a
subagent view are the spec of `app/design/koa/NOTES.md`, "The view
bar: a subagent's transcript in koa's page", which this plan does
not repeat: the bar, its overflow, the composer's placeholders and
the sidebar's mark. Its behaviour, as this design builds it:

- **One switch.** `switchView(agent)` in `koa.ts` is the only code
  that changes the view. The `select` message of the sidebar, an
  `@name` link (`POST /view` from the page), the bar's buttons and
  back control (the same route) all call it. It is
  instant; the new view opens at its end, following the bottom. It
  writes the `selection` of the two records that change.
- **No keys.** No key switches the view in this plan: Kido.app
  sends no `select` from a key, and the page binds none. Keys for
  the hierarchy come back later as their own item.
- **The composer** targets the viewed agent as the user's own text
  (`sendUserMessage`, no header: the person is the user of every
  view). Escape, the queue, the pickers, dialogs, attachments and
  `!` commands act on the viewed agent, and the foot shows its state.
  The placeholder names it by the spec.
- **Commands.** `/model`, `/thinking`, `/compact`, `/copy`,
  `/session`, `/export` and `/name` act on the viewed agent. `/new`,
  `/resume`, `/reload`, `/restart` and `/quit` are refused outside
  the root view with the warning line `<command>: only in @<root's
  name>'s view`.

The external editor (Control-G) opens for the viewed agent's draft; a
view switch while it is open cancels it as a session change does. An
`@name` link in the transcript switches to the view of an agent of
this pane, and for an agent of another pane focuses that pane with
`window.ko.focus`, as today; that pane keeps its own view. Every
request of the page carries the view's `sessionId`, so the existing
409 rule covers a request that lands after a switch.

**Jobs** are per agent. The host makes each agent's `JobRegistry`
and keeps it: it survives `session.reload()` because the host, not
the session, owns it, so the `globalThis[Symbol.for("koa.jobs")]`
envelope, `JOB_SHAPE`, the adopt and the parking go. One
`process.on("exit")` handler of the host sends `SIGKILL` through
`signalJob` to every running local job of every agent. The rules of
"A job", "Stopping a job", "Streaming a job's output" and "The bash
tool's move" stay; the records move to the namespaces above. A job's
log stays `<tmpdir>/koa/<session id>-<job id>.log` with the agent's
session id. `list_async_bash` lists the caller's jobs.

**Runtimes.** `Routed` is per agent. `spawn_agent(runtime)` from a
host koa starts a routed in-process child (`--runtime` becomes the
agent's `extensionFlagValues` entry); without `runtime` a routed
spawner's child is routed in the same runtime. A koa that runs
inside a runtime (`pi: "runtime"`, `KO_RUNTIME` set) spawns its
children inside that runtime by construction, and refuses another
runtime, as today. What goes: an *inside* subagent of a host koa (a
child pane with `runtime`), because a subagent is no longer a pane.
`toplevel: true` with `runtime` keeps both modes, because it is a
pane. The registry's `runtime` keeps only the name; the `mode` goes.
The completion context of the page is the viewed agent's resolver.

**Reload and restart.** `/reload` keeps its two layers. Layer 1
calls `session.reload()` on every live agent, root first, which
reloads pi's settings, extensions, skills and prompts in place; the
jobs and the records stay because the host owns them. Layer 2, when
`installedIdentity` changed, is today's `execve` restart with the
same deferral rules (running jobs, children that owe a report, no
session file, in that order; `restartState` is a host function now,
no channel). `/restart` is that `execve` restart without the
identity check, on the root's session file: it is the escape hatch
that "start pi again" was. After an `execve` restart the subagents
are gone: koa starts only the root, each registry child lists as
ended with `koa restarted`, and `message_agent` to it resumes its
session in-process under its name (today's "Restarting through a
message", without a pane). A crash of koa ends every agent and the
pane. koa installs one `uncaughtException` handler that sets its
own pane's `close` to `keep` with a synchronous `ko api PATCH`,
writes the error to stderr, which is the pane's screen, and exits 1,
so the user can read it; a normal exit keeps `close: exit`. A fault
of one session that pi reports through `onError` or an extension
error listener is a notice of that agent's view, not a crash.

**What users lose** (no migration): subagents in their own windows,
with their own screen; an inside subagent of a host koa; a subagent
that survives its parent's koa restart (it resumes on a message); a
subagent's `force` stop; a child's lingering screen in the ending
notice; the `KO_AGENT_*` environment in a child's shell and its
jobs; a session written before this change loses its recorded
children's panes, which no longer exist, and keeps their names for a
resume.

## Where generic `parent` stays, and what goes

`parent` and `close` stay on the pane for every program. The users
after this change: koa's editor float (a floating child in koa's
window, `close: on_exit`, removed by koa or by the orphan rule),
`toplevel` agents (no parent), and any program that creates a helper
pane over itself. What stays in the server: the `parent` and `close`
fields and their validation, the floating-child-in-parent's-window
rule, the orphan rule and the cascade removal of the sweep, the
scope and relation of messages and stops, the focus repair to the
parent after a removal. What goes:

- The child-window invariant: "in any other window a tiled child is
  the only tiled pane" and the window-switch rule that steps over
  child windows (`ko_server/src/layout.rs`, `client.rs`). A pane
  whose parent is in another window is an ordinary window of its
  session with a tab.
- The `ended` message (`Content::Ended`, `End`, `tell_parent`,
  `tell_parent_gone`, `MessageId::ended`): nothing reads it after
  the harness stops.
- `SendKind` gains `Select`; `Relation` stays.
- `ko_client`: the outline nests a pane under its parent only when
  both are in the same window; a child in another window is a root.
  `Item::Pane.depth` stays for the in-window nesting.
- Kido.app: `PaneSlots`, the slot part of `PaneProjection` (`shown`,
  `rootWindows`, `addressed` for replacements, `path`), `ShownPane`,
  `PaneDirection`, `PaneBreadcrumb`, `WindowView.shownPanes` and
  `updateBreadcrumbs`, `ChildFloats` and the floats drawn over a slot,
  the ⌘↑ and ⌘↓ commands (Show Parent Pane, Show Child Pane) with
  their menu and palette entries and the reserved `super+up` and
  `super+down` of `ko_config/src/keys.rs`, the tab rule "a
  child shown in a slot keeps its top-level tab active", the
  `navigation(_:panes:)` projection argument of `SessionModel`, the
  slot reset on a new server instance. `Item.layer` goes too: only
  the slot projection read it. The sidebar's folded children, the wait-opens-a-path
  rule and the record tree stay and now carry the subagents.
- `ko_tui`: nothing but the outline change it inherits.
- koa: `createPane` for children, the depth read of `/layout`, the
  `KO_AGENT_SESSION`, `KO_AGENT_PARENT_SESSION` and
  `KO_AGENT_TRUSTED_CWD` environment, the `edge` from the environment,
  the parent watch and its tick (`KO_PARENT_POLL_MS`), the resend of
  reports (`KO_RESEND_MS` stays for pane sends), `koa.sent`, the
  `ended` handling and the screen read, the exit notice, the restart
  lock for children (the host serializes), the receiver's `globalThis`
  parking (the receiver and its id ring are the host's), the fd 3
  channel
  (`koa-channel.ts`, `koaSessionsConnection`, the `session` record,
  `list`, `completion_context`, `restart_state`), the startup helper
  (`koa-startup.ts`: koa imports pi's `parseArgs` directly, because it
  imports pi's package now), `RELOAD_COMMAND`, the RPC link, `rpc()`,
  `spawnPi`, `stopPi`, the exit card of pi (a session that fails to
  create shows its error in the view; "Start pi again" becomes "Start
  again", which creates the session again), `koa-fake-pi.ts`. The
  `--resume` picker child (`koa-resume.ts`) stays a child process for
  this plan, because it owns the terminal before the webview; a later
  unit can run it in-process.
- Docs: design-subagents.md is rewritten around the in-process
  tree; design.md loses "Identity" (the environment), "Window
  lifecycle" keeps only the generic rules, "Notifying the parent"
  and "The sidebar tree" change, "Known limits" and "Decisions" gain
  this change; design-koa.md's "The process" is rewritten (no RPC
  child, the views, the records); design-app.md loses "Children in
  the slot", changes "Sidebar" (records with a selection) and "Folded
  children"; protocol.md sections 6, 7 and 10 (the field, the kind,
  the dropped invariant and message); design-program-status.md gets
  the field; design-runtimes.md "Agents in a runtime" loses the
  inside child; AGENTS.md's "koa is the one harness" and "Panes and
  the sweep" paragraphs change; `share/koa/skills/ko/SKILL.md` where
  it names child windows.

## Tests

- **A fake provider replaces the fake pi.** `koa-fake-pi.ts`
  scripted pi's RPC; with the SDK in-process there is no pi to
  script. The suite gets `koa-fake-provider.ts`: a local HTTP server
  that speaks the OpenAI chat completions stream, scripted per test
  (assistant text, tool calls, errors, delays as `KO_FAKE_*`-style
  gates), named by a `models.json` of the test's private agent
  directory with its `baseUrl`. The tests then run real pi sessions,
  real extensions and real tools. The implementer verifies that pi
  1.5.2 accepts such a provider without an API key prompt; the
  fallback is `markRuntimeStreamFunction` with a scripted `streamFn`
  on a test `ModelRuntime`, which the probe used.
- `koa-program-*.test.ts` keep their assertions over the page and
  the routes, on the fake provider. `koa-agent-*.test.ts` drive the
  host modules (`koa-agents.ts` with the extension) and the fake ko
  for pane-level calls; spawn, report, ending, addressing and
  restart-state tests change to the in-process rules; identity and
  inbound tests shrink to the root's receiver. New tests: the view
  switch (reset, state, composer target), the `select` handling, the
  record writes of an agent's life, the stop of a subtree, the
  resume of a child after an `execve` restart, the depth rule, the
  demultiplexer (`data.to` absent, live, unknown; `data.from` in the
  header), the explicit address form.
- Kido.app: `SidebarFeed` tests for record rows with a selection,
  the selected row's mark and the
  outline without child windows; `PaneSlotsTests` and the slot parts
  of `ProjectionTests`, `WindowsTests` and `SidebarChildrenTests` go;
  `KoaWebviewTests` snapshot the view bar and a subagent view in light
  and dark, windowed and narrow.
- ko: unit tests of the `selection` field and the `select` kind in
  `ko_wire`; the e2e `messages.rs` `ended` case goes; `layout.rs`
  cases that pin the child-window invariant become cases that a child
  in another window is an ordinary window; `ko_client` outline tests
  change to the same-window rule.
- The prompt fixture (`make prompts`) changes with the tool texts.

## Units

A unit that adds comes before the unit that removes, so that `main`
works after each: the child-pane code goes only after koa stops
making child panes.

1. **ko and ko_client: the additions.** `selection` on
   `StatusRecord` and `ProgramRecord`; `SendKind::Select`;
   `ko_client_select_record` in the C ABI (needs the approval of
   "Approval for new unsafe code and new routes": it is an `unsafe
   extern` function, no route); `make schemas`; protocol.md,
   design-program-status.md. Risk: low. No dependency.
2. **Kido.app: records with a selection.** Depends on 1. The record
   row as a click and Return target that sends
   `ko_client_select_record`, the selected row's mark with the pane
   row's fill rule, the neutral rename of the record row flag, the
   visual tests; design-app.md "Sidebar". Risk: medium.
3. **koa on the SDK, root only.** No dependency. `koa.ts` creates
   the root session in-process with the inline extension and the UI
   context; the page behaves as today. The fake provider and the
   suite move first, so the unit's tests exist before the host does.
   The extension takes `AgentHost` with one agent; `spawn_agent`
   without `toplevel` is refused with "not yet" between this unit
   and unit 4, so no Kido.app release is cut between them. Removes
   the RPC link, the channel, the helper, pi's exit card and
   `/restart`'s old meaning. Risk: high: the largest rewrite, and the
   one that proves the SDK path (the UI context, `reload()`, the
   switch through `AgentSessionRuntime`, the project trust context,
   the crash handler).
4. **In-process subagents.** Depends on 1 and 3; its sidebar click
   needs 2. `koa-agents.ts`, the tools over the tree, the queue
   demultiplexer and the explicit address, the records and the
   `select`, the views and the view bar by its spec, the deletions
   in koa, design-subagents.md, design.md, design-koa.md,
   design-runtimes.md, AGENTS.md. Risk: high.
5. **The child-pane code goes.** Depends on 4. Server: the `ended`
   message, the child-window invariant, the window-switch stepping.
   `ko_client`: the outline's same-window nesting. Kido.app: the
   slots, the breadcrumb, the floats over a slot, ⌘↑ and ⌘↓;
   `ko_config`: the two reserved keybinds. Their tests and docs
   (protocol.md, design.md "The sidebar tree" and "Window lifecycle",
   design-app.md). Risk: medium-high: the slot code is spread over
   `WindowOwner`, `WindowView`, `SessionView` and `SessionModel`, and
   the visual suite records once at the end.
6. **Later items, each its own unit:** `close: on_exit` and the
   linger grace, whose reason (the parent's ending notice reads the
   lingering screen) is gone, so the editor float can take the
   default `exit` and the sweep loses a rule and the focus guard;
   keys for the view hierarchy; the `--resume` picker in-process; a
   pi `clearQueue` option that keeps custom messages, which removes
   the prototype patch.

Order: 1 and 3 in parallel; 2 after 1; 4 after 1, 2 and 3; 5 after
4; then 6.
