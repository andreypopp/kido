# koa, the webview harness for pi

koa is a program for a Kido pane. It runs pi's session in its own
process through pi's SDK and shows the session as an HTML page in the
pane through the webview feature. In development the same
page shows in a browser (`koa --browser`). koa is also the stress test
of the webview feature: its workloads load and measure the webview
path.

This document gives koa's design and its reasons. Other documents
give what koa builds on and do not repeat it here:

- [design-webview.md](design-webview.md): webview panes, the SDK
  `@kido/webview` and its browser target, the live channel and the
  sandbox.
- [protocol.md](protocol.md), section 16: the escape, `supported`,
  the serve stream and the proxy route.
- [design-app.md](design-app.md), "Webview panes": the web view,
  keys, the theme properties, hidden pages, Quick Look from a page
  and drops on a page.
- [design.md](design.md), "The harness extension", and
  [design-subagents.md](design-subagents.md): the agent extension,
  koa's extension inside its session, which holds the agent tools.
- [design-program-status.md](design-program-status.md): the OSC 7501
  record that koa writes.

The UI reference is the set of mockups in `app/design/koa/`; the
index at the top of its `NOTES.md` names the reference for each part
of the page. This document does not repeat the mockups' values.

## Goals and non-goals

Goals, in priority order:

1. **One pane, one page.** The transcript, the composer and its foot.
   Streaming Markdown; each run of tool calls and thinking folds into
   one line, and each step opens to its details.
2. **A koa pane is an agent pane.** The sidebar shows it as a pi
   agent, `ko prompt` and `message_agent` reach it, and the agent
   extension's tools work in it. koa is Kido's one pi harness.
3. **The webview path under load, measured.** Long sessions, fast
   token streams, large tool output, reloads and reconnects, many
   panes, hidden pages and theme changes.
4. **Small.** TypeScript that Node 24 runs as is, with no runtime
   dependency in the program; the page's npm packages are bundled at
   build time.

Non-goals:

- A terminal UI, and a terminal harness (the user's decision). In a
  client that shows no webviews (`ko_tui`, a terminal view of a
  remote server), koa prints one line that says so and keeps
  serving; the page shows when a client with webviews connects, or in
  a browser with `koa --browser` on the host where koa runs. Outside
  a pane, koa runs only with `--browser`. A plain `pi` stays usable
  in such a client, but as a `SomeAgent` with no harness
  (design-program-status.md, "Pane kinds").
- Session trees, `/tree`, forks and clones from the page, and the
  built-in slash commands that koa refuses
  ([plans/koa.md](../plans/koa.md)).

## Where koa lives

`share/koa/` holds the program (`koa.ts` and its `koa-*.ts` modules),
the page's sources (`page/`), the fake model provider of the tests
(`koa-fake-provider.ts`), the suite (`koa-*.test.ts`) and the stress runner
(`stress/`). It also holds the agent extension (`koa-agent.ts`), its
suite (`koa-agent-*.test.ts` over `koa-agent-fixture.ts`, on the fake
ko of `testdata/fake_ko/`), the prompt snapshot
`testdata/ko-prompts.txt`, the ko skill (`skills/ko/SKILL.md`),
`ko-api.d.ts`, and the modules that the extension, koa and the page
share: `records.ts` (the
facts that the extension writes into its messages' details, with
their guards), `agents.ts`, `token.ts` (the token grammar: the
extension's `@` agent token runs through the file token rules),
`text.ts`, `completion-context.ts` (the place where a command runs,
which the extension answers through its host; "Shell
completion") and
`runtime-exec.ts` (the client of a runtime's exec route, the
extension's routed commands and koa's shell completion). The records of koa and its page are
`share/koa/koa-records.ts`.

The files of `share/koa/`: `koa.ts`, the program; `page/`, the
TypeScript sources of its page (`page.ts`, `markdown.ts`, the
streaming markdown over marked and remend, `page.html`, `page.css`),
which `make koa-page` bundles with esbuild into one unminified
`page.js`; `package.json` and its lockfile pin esbuild, TypeScript 7
(the one type checker of every TypeScript in the repository), the
page's npm packages and the development packages of the extension and
the suites; `koa-assemble.ts`, the one HTML response;
`koa-transcript.ts`, the transcript model, its delivery and the image
store; `koa-image.ts`, the image sniffer; `koa-timer.ts`, the timer
that reports a throw; `koa-http.ts`, the HTTP helpers and the one
file server with its checked, size-capped open; `koa-records.ts`, the
records that koa and its page share; `koa-complete.ts`, completion;
`koa-shell.ts` and `koa-shell.sh`, Tab completion in `!` mode from
bash; `koa-attach.ts`, attachments; `koa-queue.ts`, the queue's
attachments; `koa-child.ts`, the signals of koa's own children, pi's
package lookup and the run of the session picker; `koa-sdk.ts`, the
SDK's import boundary; `koa-agents.ts`, the host of the session: the session's
creation from pi's arguments, the UI context, the binding and the
helpers that call the session; `koa-args.ts`, the rules for pi's
arguments at startup and at a restart; `koa-resume.ts`, the picker
extension of `koa --resume`; `koa-commands.ts`, the built-in slash
commands; `koa-identity.ts`, the hash of koa's installed files;
`koa-session-dir.ts`, the session directory rule of both pickers;
`prompt.ts`, the prompt text rules that koa and its page share;
`koa-fake-provider.ts`, the scripted model provider of its suite
`koa-*.test.ts`, `koa-fake-picker.ts`, the scripted picker, and
`koa-fake-tty.ts`, the terminal preload;
`stress/`, the stress workloads and runner (not installed);
`testdata/replay.ts`, the replay server of the page tests, with its
scenario types (`testdata/scenario.ts`), their shared records
(`testdata/scenario-parts.ts`, the records that two or more
scenarios share) and the scenarios
(`testdata/scenarios/`), none of them installed ("Tests").

`make build` installs the program, the extension, the shared
modules, `ko-api.d.ts`, the skill and the built page in
`share/ko/koa/`, and the shim `share/ko/bin/koa`. The installed
layout keeps `share/koa/` and `share/webview/` as siblings (`koa/`
and `webview/`), so koa's relative imports of `../webview/` resolve
the same way in the checkout and in every installed layout: `make
install` and the Homebrew formula, Kido.app's bundle and the static
Linux layout that runtimes and containers use.

**The host's needs.** koa runs where its pane's program runs: the
Mac, a remote server (`ko HOST`), or a runtime or container. That
host needs Node 24 or later and `pi` on PATH; the page's client needs
nothing. The shim checks both before any JavaScript runs, so a
missing one shows as one line in the pane. koa installs everywhere ko
installs, because remote use needs it on the server.

**The page is built, not committed.** The page is TypeScript in
`share/koa/page/`, which esbuild bundles with CodeMirror, `marked`
and `remend` from `share/koa/package.json` into one unminified
`page.js` at `make build` (`make koa-page`; `make koa-watch` rebuilds
on each save). The user decided this: vendored files needed a rewriter
of their imports, and a committed bundle is a large generated diff in
every page commit that no reviewer reads. The cost is that `make
build` needs Node and npm. The bundle is not minified, so it is
readable in WebKit's inspector; the bridge does not compress, so the
plain size is the wire size. The program itself is not bundled: Node
runs `koa.ts` and the agent extension as they are.

**One response for the page.** A remote server costs one round trip
for each asset, so koa inlines `page.html`, `page.css` and `page.js`
into one document for `/` (`koa-assemble.ts`). koa assembles it once
at startup and serves that copy for its whole life, and it reads
`koa-shell.sh` at startup too: a running koa always serves the page of
its own code, so an install that replaces the files under it (a
Kido.app update) cannot give an old koa a new page that expects state
it does not send. A page file that is missing at startup stops koa.
For development, `KOA_PAGE_RELOAD=1` assembles the page again for each
load, so `make koa-watch` and ⌘R show a change. A new page reaches a
running pane only through `/reload`, which replaces koa itself
when its files changed ("`/reload` reloads pi" below), or `/restart`.

**A page talks only to the koa that served it.** koa mints an
instance id at start and puts it in the document's `koa-instance`
meta; the page sends it with each open of `/events`. koa answers an
open with another id with one `reload` record, and the page loads
its document again. A page of an older koa that reconnects to a new
one (the app missed the serve stream's drop, a hidden page comes
back, a back/forward cache) thus never applies a new koa's records.
The record and the parameter are the one contract between two koa
versions.

**A record that the page cannot apply ends the feed.** A throw while
the page applies an event record closes the event source and shows
the error with a request to reload the pane; it does not reconnect,
also not when the page comes back from the back/forward cache,
because a reconnect gets the same record and throws again, over state
that is partly applied. Only a transport error reconnects.

**Type checks.** TypeScript 7 from `share/koa/package.json` is the one
type checker of the repository. `share/koa/tsconfig.json` checks the
Node side, koa and the agent extension included; `share/koa/page/tsconfig.json` checks the
page against the DOM alone. The record modules import nothing from
pi, because pi's declarations pull Node's globals into the page's
check. Where `koa-records.ts` names a closed set that pi also defines
(the thinking levels, the dialog methods, the command sources),
`koa.ts` proves at compile time that the two sets are equal, so pi
stays the source and a change in pi fails the check. The relations
of `records.ts` derive from ko's schema (`ko-api.d.ts`).

## The process

**One process in the pane.** koa is the pane's program: its stdout
is the pane's tty, so the SDK's `show` and `hide` and koa's own OSC
7501 and OSC 0 reach the pane. Every agent of the pane runs inside
koa as an `AgentSession` of pi's SDK, each wrapped in an
`AgentSessionRuntime`: the root, which koa starts from its command
line, and its subagents (design-subagents.md, "The tree"). The root's
`/new`, `/resume` and an extension's `newSession`, `fork` and
`switchSession` use pi's own switch. There is no pi child, no RPC
stream and no session channel. One process has one set of bugs and
one event path. The cost: koa supplies what pi's RPC mode supplied
(the extension UI context, the command handlers, the session switch),
and a fault of pi or of an extension ends every agent of the pane ("A
crash keeps the pane" below).

**pi's package.** koa loads the SDK of the pi that the user runs, not
a copy of its own. It finds pi's package directory (`piPackage` in
`koa-child.ts`): the executable on PATH (or `--pi`), its real path,
the first parent directory whose `package.json` names
`@earendil-works/pi-coding-agent`, else Homebrew's
`../libexec/lib/node_modules/@earendil-works/pi-coding-agent` beside
the real path, because Homebrew's `pi` is a shell wrapper. A pi
whose package koa cannot find stops koa with one line.

**The import boundary.** The installed koa has no `node_modules`, and
pi's package exports only its index. `loadSdk`
(`koa-sdk.ts`) registers one `node:module` resolve hook that maps the specifiers
`@earendil-works/pi-coding-agent` and `typebox` to the files of the
selected package, only for importers inside koa's own directory (its
real path, because Node reports `/tmp` as `/private/tmp`), so a user's
extension resolves its own imports unchanged. Then koa imports pi's
index and, by absolute file URL, the modules that the index does not
export: the built-in extensions, the project trust resolution and its
RPC context, the path helpers and the theme. `koa.ts` imports
`koa-agents.ts`, and with it the agent extension, only after the hook
exists. One SDK instance serves the process, so the queue patch below
reaches the class that every session uses.

**The host.** `koa-agents.ts` holds the tree of agents (`createTree`)
and makes the root session from pi's parsed arguments, as pi's `main.js` does
for its own modes; `main.js` exports no function that does it without
printing, prompting or exiting. The session manager comes first, from
`--session`, `--fork`, `--continue`, `--session-id` and
`--no-session`, with the session directory rule of
`koa-session-dir.ts`; then the services: the settings, the resource
loader with the extension, skill and prompt paths of the command line
(resolved from the launch directory), the model and its thinking
level, the scoped models and the tool flags. The resource loader gets
pi's own built-in extensions (`builtInExtensions` of
`dist/extensions/index.js`), which pi's `main.js` adds and the SDK
does not, then the agent extension as an inline factory named `koa`
and hidden. Without the first list, the built-in tools of pi would
vanish in koa. One `ModelRuntime` serves every session of the host:
the credentials and the models of the agent directory, which koa
resolves once with pi's `getAgentDir` and gives to the editor and
completion too. Unknown flags, such as the extension's `--runtime`, go
to the services as `extensionFlagValues`, which pi checks after the
factories register their flags. A subagent's services have its own
cwd, the built-in extensions and the agent extension, and only its
`--runtime` as a flag value: the root's command line options are not
the child's.

**Project trust** follows `main.js` in RPC mode: a trust cache for
each directory, the stored decision, the command line override and
pi's default, and an extension's `project_trust` handler asked with
pi's RPC context (`mode: "rpc"`, `hasUI: false`), not with koa's
page. A page is not a reason to trust a project: the root keeps the
trust that a pi in RPC mode had. The session's own UI context, bound
after it, has `hasUI` true.

**The UI context.** `uiContext` in `koa-agents.ts` is the
`ExtensionUIContext` of every extension: `select`, `confirm`,
`input` and `editor` are the page's dialog cards, with the signal and
the timeout of pi's options; `notify` is a notice item; `setStatus`
the foot's statuses; `setEditorText` and `pasteToEditor` the
composer. The members that only pi's TUI can show (widgets, the
footer, the header, the title, the working indicator, custom
components, themes) do nothing, as they did over RPC. The session
binds it with `mode: "rpc"`, so the extensions' mode checks keep
their meaning, and with the command context actions of RPC mode
(`waitForIdle`, `newSession`, `fork`, `navigateTree`,
`switchSession`, `reload`). `onError` and the loader's diagnostics
are notice items: a fault of one extension handler does not stop the
session.

**The binding order.** koa listens before it binds: the HTTP server
exists, then the session's subscription, then `bindExtensions`,
because a `session_start` handler can ask a dialog or start a turn,
and both must reach the page. `setRebindSession` runs the same
binding for each new session of a switch, and it is the only binding;
koa does not bind again after a switch, because a binding emits
`session_start`.

**Events.** koa subscribes to the session's events. They are not
pi's RPC records: RPC strips the growing message from
`message_update` and sends deltas. koa gives the transcript the
session's own message at each `message_update` and takes only the
thinking start and end times from the delta; pi parses the tool
arguments. The transcript treats pi's objects as read-only and
converts them at its flush ("The transcript").

**Readiness.** koa refuses the session's routes until the session is
loaded and rebuilt, because a prompt sent before that snapshot was
lost when the snapshot arrived. Each route names its access in
`koa.ts`:
completion, the attachment routes and the dialog answer work while
the session starts, because a `session_start` handler can wait for a
dialog's answer.

**The command line is checked before the webview.** koa parses pi's
arguments with pi's exported `parseArgs`, so koa has no copy of pi's
flag table, and `koa-args.ts` decides from the parsed value. koa
refuses, with `koa: <flag>: <reason>` and exit code 1, the flags that
end or bypass the session: `--mode` other than `rpc`, `--print`,
`--export`, `--list-models`, `--version`, `--tui-mode`, `--theme`,
`--use-theme` and `--no-themes` (the page has its own theme), and
every error of pi's parser. An `@file` argument is refused too: an
attachment is not pi's inline file expansion, so the page's
attachments are the way. koa sends pi's positional messages as pi's
interactive mode does: one by one, each after the previous run
settles, once after the session is ready, not when a page connects.

**`--resume` picks before the webview.** When an argument is
`--resume` or `-r`, koa first runs a picker child on the terminal,
before the SDK's view exists: `pi --mode rpc --no-session
--no-extensions --extension koa-resume.ts`, with the terminal as its
streams, koa's pi arguments in `KOA_RESUME_ARGS` and a pipe on fd 3
(`pickSession` in `koa-child.ts`). The picker stays a child because
it owns the terminal before the webview does. The extension decides
with pi's exported `parseArgs`: when pi would not run its picker
(`--session`, `--fork`, `--no-session` and the other flags that
precede the picker in pi's `main.js`), it answers `skip`. Else it
shows pi's exported `SessionSelectorComponent` with pi's two session
loaders and the session directory that pi resolves
(`koa-session-dir.ts`, which the page's picker also uses), answers
`ready` when the screen takes input, then `selected` with the file or
`cancel`, restores the terminal and exits. On `selected`, koa adds
`--session <file>` before `--`. On `cancel`, koa prints "No session
selected" and exits 0 with no webview. Subagent sessions do not
show, because they live outside pi's session tree.

The picker relies on one pi detail: pi awaits an extension's factory
before it starts its RPC loop, so the factory owns the terminal and
exits the process. A pi that changes this never hangs koa: koa waits
for `ready` for `KOA_RESUME_READY_MS` (default 10 s), and an exit or
an end of fd 3 without a result, an invalid line or a picker that
does not exit after its result is an error that names `pi
--version`'s output, with exit code 1. koa forwards `SIGTERM`,
`SIGHUP` and `SIGINT` to the picker while it runs and stops it on
every exit. pi exports its keybindings manager only as a type, so the
picker's list uses pi's app bindings, but its search field has
pi-tui's default editing keys.

**A top-level agent takes its spawner's mode** (the user's decision).
A top-level agent is `ko shell -- koa`. koa gives the agent extension
browser mode as a field of its host, never from pi's mode, and the
extension adds `--browser` to the new `koa` under it.

**The agent extension inside the session.** The extension takes its
host from a closure (`agentExtension(host)` in `koa-agent.ts`); the
host names the agent that the instance serves. The host's `facts` are
the pane, the ko executable and the runtime, which koa reads once from
its environment at its edge (`hostFacts`); the extension reads no
environment for them. The tree keeps what must outlive one load of an
extension: the pane's message stream and its id ring, each agent's
jobs and records, the exit cleanup, because `session.reload()` runs
the factory again. The root's `session_start` writes the `pi.*`
variables and starts the peer client; a subagent's writes neither. A
message on the pane's stream goes to the agent that its `data.to`
names (design-subagents.md, "The pane's queue") and reaches koa as
that session's message events.

**The queue patch.** pi's `clearQueue` drops queued custom messages
with the user's text, and koa's queue take-back must keep the
agents' messages. `koa-agents.ts` wraps `AgentSession.prototype.clearQueue`
once in the process, so that it puts the custom messages back. The
patch goes when pi has a `clearQueue` that keeps them.

**Status and title.** koa writes the pane's root record `app=pi`
itself, always for the root agent, whatever the page shows: working from `agent_start` (and during a compaction), at
`agent_settled` idle when aborted, else error or done from the last
assistant message, blocked with kind question while a dialog is open,
and `clear` when the session fails. With the extension's
`pi.session`, the row is a `PiAgent` (design-program-status.md). koa
sets the pane title with OSC 0 from the root session's name and
directory. Each subagent's status is a record of the pane
(design-subagents.md, "In the sidebar"), by the same rule. The
record is selectable and closeable: a `select` from the user switches
the view, a `close` stops that subagent (design-subagents.md, "The
pane's queue").

**The session's directory** is the runtime's `cwd`, which pi sets
from the session that it opened: a session of another directory runs
in that directory, and `/new` after a switch to another folder starts
in that folder. koa's own working directory does not change.

**A session that fails to start.** When the root's session cannot be made
(an unknown model, a broken settings file, a switch whose new session
fails after pi tore the old one down), koa goes to `failed`: the
transcript stays, the foot says that the agent failed, and the
failed card shows pi's error and "Start again". "Start again"
(`/agent/start`) makes the session again from the arguments of a
restart (`restartArgs` in `koa-args.ts`: `--session` of the last
session file, without the session, provider, model and thinking
flags, because the session file holds the pickers' changes). A torn
down session is never used again, also when the next one has the
same id. A subagent whose extensions fail to bind shows the same card
in its view; "Start again" there makes only that child again, from
its spawn's inputs.

**A crash keeps the pane.** pi and every extension run in koa's
process, so an uncaught exception ends koa and every agent in it.
koa installs one `uncaughtException` handler: it writes the error to
stderr, which is the pane's screen, sets its own pane's `close` to
`keep` with a synchronous `ko api PATCH /panes/$KO_PANE` (2 s
deadline), and exits 1, so the user can read the error. A normal exit
keeps `close: exit`. A fault that pi reports (an extension error, a
provider error) is a notice, not a crash.

**Shutdown.** koa ends on `SIGTERM`, `SIGHUP`, `SIGINT`, a `stop`
message, a quit from the root's view (Control-D in an empty composer)
and the root's extension's `ctx.shutdown()`; a subagent's
`ctx.shutdown()` stops only that subagent. Every part that koa makes
registers its own teardown as it is made, and one shutdown, which
exists from the moment the SDK's view exists, cancels the open
dialogs, disposes every agent's runtime first, deepest first (pi
aborts the turn, emits `session_shutdown` with reason `quit` to the
extensions and settles its credential writes), bounded by
`HOST_STOP_MS`, then starts every other teardown in
reverse order and waits for all of them. A stuck extension thus never
keeps koa alive. The reply to the page's own quit request is sent
before the shutdown starts, with a deadline (`QUIT_REPLY_MS`). Every
group signal of koa goes through one function, `signalChild` in
`koa-child.ts`, which takes a child that koa spawned (`fd`) and
ignores `ESRCH` and `EPERM`, as `signalJob` does
(design-subagents.md, "Stopping a job"); `scripts/lint.sh` permits
`process.kill` only there. The session picker shares koa's group, so
it gets its signals through its own `ChildProcess.kill`.

**Errors do not stop koa.** An error of a child, a stream, an event
handler or a timer callback is reported as one `koa:` line on stderr
or as a notice, and koa goes on; only the loss of the terminal and
an uncaught exception stop it. The edges:

- The transcript's flush takes each held message or tool result out
  of its queue before it applies it, and reports a throw, so one bad
  entry does not block the later ones.
- Every timer callback runs through `later` (`koa-timer.ts`), which
  reports a throw.
- A signal error other than `ESRCH` and `EPERM` is reported by
  `signalChild`, which never throws, so the shutdown continues.
- An error on the `fd` child's stdout ends the completion read with
  no result.
- An error on koa's own stdout means that the terminal is gone: koa
  shuts down as on `SIGHUP`; before the shutdown exists (`--help`),
  the error is ignored. An error on koa's own stderr is ignored,
  because there is no other place to report it.

**`/reload` reloads pi, and replaces koa when koa was updated.** It
has two layers (the user's decision):

1. **pi in place.** koa calls `session.reload()` on every live
   agent, root first, while the pane's queue holds its messages. pi emits
   `session_shutdown` with reason `reload`, loads its settings,
   extensions, skills and prompts again, runs the inline factory
   again, binds the saved UI and emits `session_start`; the session,
   its history, koa's subscription, the page and the transcript stay.
   The tree keeps the message stream, the id ring, the jobs and the
   records, so the new extension instance uses them. koa holds the session in
   `reloading`, which blocks the composer as a session switch does
   but keeps the events, because a `session_start` handler can start
   a turn and the restart must see it. koa buffers the UI records,
   drops the extensions' statuses and refreshes. The factory's own
   code (koa's modules) does not load again: Node keeps the module,
   so a change of it needs the second layer. A failure shows pi's
   error and goes no further.
2. **koa when it was updated.** A page of a new koa must not run
   against an old koa: one once crash-looped on a record's shape.
   koa hashes its installed files at start (`installedIdentity` in
   `koa-identity.ts`: `koa/` with the page and the agent extension,
   and `webview/`) and again after layer 1. A content hash, not a
   build stamp: ko's build id changes with every commit, and only
   koa's own files matter. A read that fails counts as no change.
   When the hash differs, koa asks the tree (`restartState`) for the
   running jobs of every agent, services included, and the children
   that have not reported on their last work, because a restart ends
   them. koa restarts only when nothing
   is running, a session file exists (a restart without one loses
   the conversation) and the session is still idle; else it shows one
   info note with the first reason, in the order jobs, subagents, no
   session file (`deferralText` in `koa-commands.ts`). The next
   `/reload` tries again.

The restart answers the page, runs koa's one shutdown, except that
the SDK's `close(false)` keeps the pane in webview mode, waits for
its own stdout and stderr to drain, and calls `process.execve` with
Node, its script path as the shim gave it, its own flags and pi's
arguments by the rule of "Start again" (`restartArgs`): the same pid
in the same pane, so the pane's row and children stay, and the script
path resolves to the files that a Kido.app update installed, pi's SDK
included. `KOA_RELOAD=1` in the new process, which koa reads and
removes at start, skips the `--resume` picker and the positional
messages and adds the note "reloaded" once the session is ready.
While the restart runs, the page shows "Reloading…" in its error line
and blocks the composer; during the gap the app shows its "The
program is not serving", and the new serve stream loads the new page
(the user's design, never a fall back to the terminal). Attachments
in the composer and the scroll position go with the page. In browser
mode, the new koa listens on a new port and opens a new tab.

`/reload` runs only when every agent is ready and idle: no turn, no
compaction, no `!` command that has not completed, no queued prompt,
no dialog and no external editor, opening and closing included,
because each is state that a reload or a restart cannot carry, and
pi's `reload()` refuses a streaming session.
Otherwise it is refused with a warning line.

**`/restart` restarts koa.** It is the second layer of `/reload`
without its checks: no identity check, no idle rule and no deferral,
on the session file of the root. It is the escape hatch for a koa or
a pi in a bad state, so it must work in that state; a running turn
ends, and the jobs end with the process. Without a session file the
new koa starts by the original arguments. The new koa starts only the
root: each subagent lists as ended with `koa restarted` and resumes
on a message (design-subagents.md, "Restarting through a message").
`/new`, `/resume`, `/reload`, `/restart` and `/quit` act on the root,
so they run only in the root's view ("Views").

**The private directory.** koa makes one directory `koa-<pid>-*` under
the temporary directory at start (0700) for the image stores and the
uploads, and removes it at exit; a stopped agent's image store goes
with its view. A koa that dies by a signal leaves
it; the host's cleaning of the temporary directory removes it.

## The page and koa

The page talks to koa over HTTP only: one `EventSource` on `/events`
and short `fetch` requests. No WebSocket. Every body is a string or a
`Uint8Array`, because WebKit gives a scheme handler a `Blob` or
`FormData` body empty (design-app.md, "Webview panes"). koa's routes
are in `koa.ts` (the commands), `koa-transcript.ts` (`/events`,
`/items`, `/images/`) and `koa-attach.ts` (`/attachments`, `/steps/`);
each route's body validator is beside its handler, in `koa.ts` for
the commands. A call of the session that fails answers 409 with
pi's error text, and the page keeps the composer's text.

**Commands need a typed body.** A `POST` must have the content type
`application/json` (an upload chunk `application/octet-stream`), else
koa answers 415. A browser sends a form post with a simple content
type to any origin without asking; this rule makes such a post do
nothing ("Browser mode" below).

**Built-in commands are koa's.** pi's session does not run the
built-in slash commands of its TUI, so a built-in sent as a prompt
reaches the model as text. koa intercepts every built-in before pi's
`prompt` (`koa-commands.ts`): its catalog is pi's own
`BUILTIN_SLASH_COMMANDS` with pi's descriptions, plus the names that
pi dispatches but does not list (`debug` and two easter eggs). A
built-in wins over an extension command or a template of the same
name, as in pi's TUI, which dispatches its built-ins before
`session.prompt`; completion drops the shadowed entry. The user chose
the supported set; each calls the session:

- `/model` and `/thinking` without an argument open the foot's
  picker. `/model <text>` sets the model when pi's
  `findExactModelReferenceMatch` finds it among the available
  models, else it opens the picker with the text as its search.
  `/thinking <level>` sets an available level. Both report
  "model: … · thinking …" as a notification.
- `/compact [instructions]` calls pi's `compact` and answers the
  page at once; pi's compaction events own the outcome ("The
  transcript" below), and Escape aborts it as it aborts a run. While
  a compaction runs, Return sends and queues nothing.
- `/session` shows `getSessionStats`; `/export [path]` writes pi's
  HTML export, with pi's default name when no path is given (a
  `.jsonl` path is refused: the page exports HTML only); `/name` sets
  or shows the session name, in pi's words.
- `/copy` puts `getLastAssistantText` on the clipboard with OSC 52
  on koa's own stdout, the pane's tty, where koa also writes OSC 7501
  and OSC 0. The user's `clipboard.write` policy decides, and it
  works for a remote koa and in a browser. A page's
  `navigator.clipboard` write needs a user gesture in WebKit and the
  text arrives after it.
- `/resume` and `/new` switch the session inside the page ("Sessions
  inside the page" below).
- `/quit` shuts koa down as Control-D does.
- `/reload` reloads pi in place, and replaces koa on the same
  session when koa was updated ("`/reload` reloads pi" above).
- `/restart` restarts koa on its session ("`/restart` restarts koa"
  above).

Every other built-in is refused with a warning line, "/settings is
not available in koa", and its text stays out of pi; completion does
not list it. The arguments of a built-in never carry attachments: the
page keeps them in the composer. The built-ins come first in
completion, in the supported order, with the kind `built-in`.

## Sessions inside the page

`/resume` opens a session picker in the page and `/new` starts a new
session, as in pi's TUI; `koa --resume` keeps its terminal picker
("The process" above), which the user decided. Both commands consume
their text in the composer; the rest of the draft (its attachments)
stays across the switch. The picker's look is the mockup's
(app/design/koa, "Sessions inside the page").

**In place, through pi's runtime.** koa calls the runtime's
`switchSession` or `newSession`: pi's runtime asks the
extensions (`session_before_switch`, which can cancel), aborts the
turn and a running bash command, shuts the old session down and starts
a new `AgentSession`, which koa binds ("The binding order"). The
agent extension follows through its own `session_shutdown` and
`session_start` (its pane variables, registry and peers), so koa does
nothing for it. A cancelled switch changes nothing in koa. A switch
that fails after pi tore the old session down leaves koa `failed`
("A session that fails to start").

**The list.** The host lists the sessions (`list` in
`koa-agents.ts`) with pi's `SessionManager.list` or `listAll` over the
session directory that pi resolves, for this folder or all, with the
page's abort as the signal. The first message of a row is cut to its
first line on the wire. Subagent sessions do not show, because they
live outside pi's session tree.

**The switch.** Every replacement of the session goes through one
path in the host (`replace` in `koa-agents.ts`): koa's `/new` and
`/resume`, and an extension's `ctx.newSession`, `ctx.switchSession`
and `ctx.fork`, so each gets the same reset and refresh. koa's state
has a `switching` phase. While it lasts, koa refuses the routes of
the session (prompts, abort, the queue, model, thinking, completion,
attachments and step files); dialog answers and quit still work,
because an extension can ask before it allows the switch. When pi
has made the new session, the rebind resets koa's state of the
session once (`resetSession`: the queue, the attachments, the
partial message, dialogs, statuses, the `!` commands) and makes the
new session the owner of the events, before pi binds the extensions
and runs `session_start`. So a turn that a `session_start` handler
starts reaches the page. koa keeps the extensions' fire-and-forget UI
records of the switch and replays them in order after it. On success
koa refreshes as at start and adds one notice: "session: <name> · N
messages" or "new session". A refresh that fails ends with an empty
transcript, the error as a notice and the session ready. An
extension's `ctx.navigateTree` stays in the same session: koa
rebuilds the transcript and puts pi's returned editor text into the
composer.

Every request that acts on a session carries the page's `sessionId`:
a JSON command in its body, a read (`/items`, `/history`, `/models`,
`/images`, `/steps`) in its query. koa refuses a request of another
session than the viewed agent's with 409, and checks again after the
body has arrived and before it acts, so a request that a session
switch or a view switch overtook never reaches the new session. The
attachment routes are the host's, like `/events`: the store is one
for the pane, because Kido.app's native drop posts a file without a
session, and the send of the prompt is the gate.

**pi's busy rule.** pi aborts a running turn or command on a switch
and does not ask. The page asks first: while pi works or a `!` command
runs, "Switch session?" with Cancel and Switch; Switch sends the page's
abort (once for each of the two that runs, because the route cancels
the command first), then opens the picker or starts the session. The
confirmation is single-use. The reset drops the `!` commands of the
old session, so a late result does not reach the new one.

**Search** is a subsequence match over the name and the first message,
in the page. pi's TUI also searches the message text, through a
function that pi does not export, so the page's search is narrower.
The rows of each scope stay while the picker is open, so ⇥ does not
scan again.

## Views

koa keeps one transcript feed for each agent and shows one at a time,
the view. The page's `State` (`koa-records.ts`) is the viewed agent's:
its `view` gives the path from the root to the viewed agent, and its
`agents` the targets of `@name` links, a view of this process or a
pane. The look of a subagent's view and of the bar is the spec of
app/design/koa/NOTES.md, "The view bar".

**One switch.** `switchView` in `koa.ts` is the only code that changes
the view: a `select` message of the user from the sidebar
(design-subagents.md, "The pane's queue"), an `@name` link and the
bar's buttons (`POST /view` from the page), and the stop of a viewed
subagent, which switches to its nearest surviving ancestor. A switch
is instant. It cancels the external editor and moves the page's
event stream to the new agent's feed: it publishes the new agent's
`state` first, then a `reset` of its feed under a new epoch, because
the page renders `@name` links from the state and scopes its image
reads by its `sessionId`. The feed is not rebuilt, so a streaming
reply and a running tool continue where they were. Then the tree
writes the `selection` of the two records that change. No key
switches the view; keys for the hierarchy are a later item.

**What follows the view.** The composer targets the viewed agent as
the user's own text, without a header: the person is the user of
every view. Escape, the queue, the pickers, the dialogs, the
attachments, `!` commands, `/model`, `/thinking`, `/compact`, `/copy`,
`/session`, `/export` and `/name` act on the viewed agent, and the
foot shows its state. `/new`, `/resume`, `/reload`, `/restart` and
`/quit` are refused outside the root's view with the warning line
`<command>: only in @<root's name>'s view`, also as routes. The page
keeps one draft for each view (the text and the ready attachments),
cancels pending uploads, completion and history reads at a switch,
closes its pickers, menus and the lightbox, and opens the new view at
its end.

**Links.** An `@name` link of an agent of this process switches the
view; one of another pane focuses that pane with `window.ko.focus`,
and that pane keeps its own view.

## The transcript

`koa-transcript.ts` projects pi's session into items in memory: user
messages, assistant messages with their text, thinking and tool
blocks, the custom messages that pi displays, user `!` commands,
summaries, and koa's notifications. It takes whole pi messages, so a
replay from the session's `messages` and the live stream use one
conversion.
`koa-records.ts` defines the items and the records.

- **Live messages.** Each `message_update` of the session carries
  pi's whole partial message, with the tool arguments that pi parsed
  so far, so a step line names its tool while the arguments still
  stream. The module keeps only the newest message and converts it at
  its flush; it never changes pi's object. `message_end` gives pi's
  authoritative content.
- **A tool's result** goes into the block of its call, so the page
  never needs the call's item to place a result. koa stamps the times
  of tool blocks and, with its own clock, of thinking blocks; a
  replayed session has no thinking times, because pi's messages
  carry none. A bash exit code comes from pi's structured result, or
  from its status line on a replay, so no page parses it.
- **Final.** An item is final when it can no longer change. An
  assistant item becomes final after its end, when each call has its
  result or will never run (an aborted or failed response).
- **Caps.** Tool arguments, results, command output and agent texts
  are capped, with the count of cut bytes (`MAX_WEBVIEW_*` in
  `koa-transcript.ts`). The feed is the page's memory, so nothing in
  it is unbounded.
- **Runs are the page's.** A run is every consecutive thinking and
  tool block between two texts; nothing stores it. Fold state is
  page-local and a reload loses it.
- **Thinking is Markdown when open.** A thinking step's line shows
  its first line without Markdown syntax, as an agent line does. Its
  text renders through the reply's Markdown memo only when the step
  is open: the first open renders it, and while it streams open, each
  rebuild gives the memo the new text, as a reply streams. A closed
  step does no Markdown work. Redacted thinking stays plain text.
  Inside the step, Markdown keeps the muted tone of thinking: bold is
  weight only, code and quotes are quieter than in a reply, headings
  are body size, and the step's own 260px scroller is the one
  vertical scroll.
- **Notifications** (pi's `notify`) are items, one line where they
  arrived, and they stay. pi's messages have no notifications, so a
  rebuild keeps the module's own notification items and merges them
  by time when the rebuild is of the same session (a compaction, a
  restart), and drops them for another session (a switch, a new
  session, a fork, a clone).
- **Command outcomes** are one item kind, `command`, whose result
  is the outcome of a built-in: the copied length, the exported path,
  the session's stats, or a compaction. A compaction's item is
  running from `compaction_start` and ends as done (tokens before and
  after, pi's summary), failed (pi's error, a refusal of `compact`,
  or the session's failure during it), or cancelled (an aborted
  `compaction_end`). A rebuild of the same session keeps these items
  as it keeps notifications.
- **One text edge.** The user decided with `refine.html` that the
  transcript, the user block, the composer, the dialogs and the failed
  card share edges: the user block and the composer's field extend
  `--pad` past the transcript's text edge, so the field's text starts
  where the assistant's text starts, and every item's time ends on the
  text edge (the user block's time on its own padding). A user message
  The sides do not shrink in a narrow pane: `--side-pad` and `--pad`
  are the same at every width, so the blocks keep 8pt from the pane's
  edge; the narrow rule changes only the vertical padding. A user message
  is a solid block of the accent colour; its quotes, code and time
  derive from its ink, not from the accent.
- **Every notice is one row.** The user decided with `lines.html`
  (2026-11-12) that notifications, command outcomes, koa's own notes,
  the reply's error, a custom message without agent details and a
  summary from the history look like an agent line: one prose line in
  the muted colour, the time at the text edge, no chevron and no
  terminal text except a path or a session file. The item kinds stay
  separate, because a rebuild keeps or drops them by kind; only the
  page's renderer (`noticeRow` in `page/page.ts`) is one. A warning's
  text is in the warning colour and an error's text in the error
  colour; the time stays faint. A row opens on a click of the whole
  line when it has more than its line: a body (the session's
  statistics, the compaction summary), a text of more than one line,
  or a line that does not fit, which opens to its whole text. A
  summary from the history shows its kind ("compacted", "branch") and
  the start of its text, and keeps only the kind when open. The reply's
  error is a row after the reply's blocks, with the reply's time, so it
  groups with the rows after it. The texts are the user's, family by
  family, in the mockup's notes.
- **A rebuild** (at start, after `new_session`, `switch_session`,
  `fork`, `clone` and `compaction_end`) mints a new epoch.

## Delivery

A long session must not cost its whole size on each page load, and a
stream of tokens must not cost the square of its size.

- **`/events` is server-sent events,** one JSON record for each
  event. A page with the current epoch gives its last final item and
  gets only the items after it. Any other page gets `reset`: the
  newest items under the window caps, and whether older items exist.
  A page that loses the stream opens it again with its epoch and last
  final item, never with `Last-Event-ID`: a patch changes an
  unfinished item many times, so the item, not the event, is the
  cursor. The feed is SSE and not a `fetch` body because of WebKit
  bug 322545 (design-webview.md, "The live channel"): under eight
  streaming pages a fetch body hid up to 116 KB of an answer's tail.
- **`/items?before=N`** gives older items under the same caps when the
  page's top comes into view; the scroll stays anchored.
- **Flushes.** While an item streams, the module keeps only the newest
  raw message and converts it once for each flush (`FLUSH_MS` in
  `koa.ts`). A flush sends `patch` records: for each changed block its
  new suffix when the block only grew, else the block whole.
- **Revisions order a snapshot and the stream.** `/items` is a
  separate request, so a patch can reach the page before or after a
  snapshot that already holds it, and an item outside the loaded
  window can still stream; arrival order says nothing, and the epoch
  only separates rebuilds. Each item has a revision that each
  published change raises by one; a patch names the revision it
  applies to and the one it makes. `/items` flushes first, so a
  snapshot holds only published state at its revision. The page
  applies a patch only on its own revision, skips an older one, and
  on a gap reconnects without its epoch, which gets a `reset`: a gap
  is recoverable, unlike a record that the page cannot apply. While a
  history request is outstanding, the page keeps the patches for the
  items that it lacks and applies them after the snapshot by the same
  rule; otherwise such a patch is for an item that a later snapshot
  gives whole. A reset invalidates the outstanding request, whatever
  epoch its answer names.
- **A slow page.** A `write` that returns false is ordinary buffering.
  Only an event response whose buffered output passes its cap is
  ended; that page reconnects with its epoch and gets what it lacks,
  and the other pages continue.

**Streaming Markdown.** `page/markdown.ts` is a block memoization
after Streamdown's design, in plain DOM. marked's lexer splits the
source into top-level blocks; every block before the first that
changed keeps its node; the last block is the streaming tail, which
`remend` heals (an open emphasis, code span, link or fence) before
marked parses it. Thus a token costs the size of its paragraph, not of
the message. The memo keeps the latest raw text apart from the blocks:
a kept block that held a slice of the message kept every old version
of a streaming answer alive (117 MB of JS heap after 20 000 tokens,
16 MB after the fix). marked passes raw HTML through, so the page
renders every `html` token as escaped text and parses marked's output
into a detached document; no model text reaches `innerHTML`
unescaped. A link is a link only when it is an absolute `http`,
`https` or `mailto` URL, so model text cannot point at koa's routes.
A click on it opens as every webview page's link does
(design-webview.md, "The sandbox"): the app opens
`http` and `https`, and refuses `mailto` with a notice.
The user's text renders through the same renderer.

**The reveal.** An answer grows by blocks and by slices of whole
lines, not by the chunk (app/design/koa/NOTES.md, item 9; `REVEAL`
in `page/page.ts` holds its parameters). It is presentation only:
the page applies every patch to its items at once, by the revision
rule above, and the reveal only chooses how much of the assistant
text to show.

- **What it covers.** Only assistant text that the page first sees
  unfinished. History, the user block, agent bodies, thinking,
  images and annotations render whole at once; marks apply to final
  text only, which is never cut. A text block is complete when its
  item is final or a later block of the same item began (a tool
  step, an agent card).
- **Blocks.** A top-level block of the lexer appears when it is
  complete, that is when the next block began, and grows in. Typing
  dots stand where the caret stood while a block arrives.
- **Slices.** The tail block's raw text is cut at a whole unit
  before `remend` and the lexer, so a slice is never a half line:
  a code fence by lines, a table by rows, a list by items, a
  paragraph by its wrapped lines, which the page finds on an
  off-screen copy at the transcript's width. A quote, a heading and
  a list with a fence or a quote at any depth are not cut; they
  appear whole. A slice is revealed when the hidden part reaches the
  height cap, a share of the viewport, or when nothing was revealed
  for the time cap and whole units wait. Without a whole unit the
  page waits for new text or a new width.
- **The fold.** A code fence of assistant prose, history included,
  longer than the fold limit shows its first lines and a bar "Show N
  more lines". A click expands it for good, also while it streams;
  until then a streaming fence stays folded and the count grows, so
  a long fence costs a fixed height during the stream.
- **Frames.** The reveal, the grow and the glide run in one frame
  loop, which runs only while something animates or waits for a
  measurement; the time cap is one timeout. A hidden page and a
  `reset` cancel both, so a background page accumulates no timers.

## The composer

The composer is a CodeMirror 6 editor (`page/composer.ts`), so
completion and Markdown use CodeMirror's own state, tooltip and
keymaps. The page keeps every key rule: Return sends, Shift-Return
inserts a newline, Option-Return queues a follow-up while pi works,
Escape aborts and a second Escape clears, Control-D in an empty
composer quits. Kido's Command keys never reach the page, so the page
binds none. A send while pi works is a steer: koa always sends pi's
`prompt` with a streaming behaviour, never `steer` or `follow_up`,
because only `prompt` runs an extension command while pi streams.
Escape first takes the queue back into the composer, then aborts, so
no queued work runs after it. While a `!` command runs, Escape cancels
the command first ("`!` commands" below).

- **One owner of Enter.** The composer's highest-precedence keymap
  owns every Enter variant; `standardKeymap`'s Enter binding is
  filtered out, because it would run during an input method's
  composition and indent a Shift-Return newline. Each Enter binding
  returns false while a composition has started, so the Enter that
  commits a candidate never sends.
- **Prompt history** follows pi's editor: Up on the first visual
  line browses when the field is empty, already browsing, or the
  cursor is at its start, else it moves the cursor to the start;
  Down on the last visual line goes forward while browsing, and past
  the newest entry it restores the draft and its selection. An edit
  ends browsing. Completion and an input method's composition keep
  their arrows. The entries are the newest 100 user messages and `!`
  commands of the session, trimmed, without empty entries and
  consecutive repeats, so a resumed session has its history. They
  come from koa's transcript (`GET /history`) when browsing starts;
  the page stores none (`page/history.ts`). A built-in command never
  reaches the transcript and is not in the history.
- **Option-Up** takes the whole queue back into the composer, with no
  abort.
- **The cursor** is CodeMirror's `drawSelection()` in the pane's
  cursor and selection colours. WebKit's native caret lagged visibly
  when the Markdown highlighting rebuilt the spans around it.
- **Focus.** Outside dialogs, pickers and the lightbox, Tab and
  Shift-Tab keep keyboard focus in the composer. Tab keeps its completion
  behaviour; without a completion it does nothing. Shift-Tab does nothing.
  The composer takes the focus at start, when pi's
  readiness makes it available, and when the pane gets focus, each
  only while the document has focus and no dialog, picker or control
  of the page holds it. A printable key typed outside a field goes to
  the composer; a selection in the transcript stays.
- **The focus border.** The composer's focus border shows where keys
  go, not the DOM focus: it is on while the document has focus, the
  composer is enabled, no dialog or lightbox is open and no other
  text input of the page holds the focus. One predicate decides it
  and the routing of printable keys, so a click in the transcript
  keeps the border. The model and thinking picker keeps the border
  but takes the keys while it is open, because it is a menu over the
  composer.
- **Markdown.** The composer parses GFM through
  `@codemirror/lang-markdown`'s named exports, never its `markdown()`,
  which bundles the HTML, CSS and JavaScript parsers (about 345 KB).
  The markup is muted and code is in the terminal font, after the
  user's plain rule, with no colours of its own. Shift-Return
  continues a list or a quote and ends an empty item; Backspace at an
  item's start deletes its marker; Return stays send. Fences get no
  language parsers.
- **The glass.** The composer floats over the transcript on a CSS
  `backdrop-filter`; a `ResizeObserver` keeps the transcript's bottom
  padding at the dock's height. WebKit's private system glass needs a
  private preference, and WebKit's snapshot does not show it, so no
  test could check it.
- **Bottom-following.** The transcript follows its bottom while the
  user is within 60 px of it; a new record, an image load or a
  resize of the viewport or the dock scrolls to the bottom in the
  next frame. A browser dispatches a scroll event at the next frame
  and the handler reads the geometry then, not at the time of the
  scroll. After a send, the cleared composer shrinks the dock, the
  shorter padding clamps the scroll position, and the submitted
  message can arrive before the clamp's event runs: that event then
  sees the new message's height below the view. Thus the page keeps
  the scroll position that it caused itself (its own scroll, and the
  clamp of a resize), and a scroll event at that position does not
  change the following. Only a scroll to another position, the
  user's, decides it again. A reveal does not jump: it glides to
  the bottom once, ease-out, through the same scheduler, which owns
  every write of the scroll position; the glide stops when the user
  scrolls away, and a patch whose text stays hidden does not
  scroll.
- **Focus, new items and "↓ Latest".** The look and the rules are in
  app/design/koa/NOTES.md, "Auto-scroll, the "new messages" divider
  and "↓ Latest"". The pane is focused when the document has the
  focus and is visible; the page reads both at each decision and
  re-checks on focus, blur, `visibilitychange` and scroll, so no
  native message is necessary and browser mode behaves the same.
  While the pane is not focused, the scheduler writes no automatic
  scroll, so an append, a patch, an image load or a resize leaves
  the position; focus alone never scrolls, and the bottom-and-focused
  state resumes following. A reset still opens at the bottom when
  the page follows, focused or not, so a page that loads in a
  background pane does not open at its top. An item is new at its
  first append only: a revision or a patch of the same sequence
  number is growth. The user's message and the `!` row that the
  send creates are the user's own; the command's output counts
  once, keyed by the live row's id. The recorded `bash` item has no
  id, so it takes the key of the live row with the same command, or
  its own sequence number when no live row exists.
  The count is of new items whose top is below the dock's top,
  because the dock covers the bottom of the transcript. The capsule's
  click is a user action: it sets following and gives the scheduler
  a short ease-out to the bottom (a snap under Reduce Motion), so
  the scroll handler sees a position that the page wrote and does
  not misread it as the user's. The divider and the count clear
  together, on a send and on a reset of the transcript, which a
  session switch, `/new`, `/reload` and `/restart` all cause.

**Completion.** pi's session offers only its command list
(`commandList` in `koa-agents.ts`: extension commands, prompt
templates and skills, no argument completions) and has no file
search. koa cannot import pi's provider: `pi-tui` is not
reachable from pi's package exports, and pi's bun binary has no
modules. So koa copies pi's rules (`koa-complete.ts`), behind its own
`POST /complete`:

- `/` at the start of the first line: koa's supported built-ins,
  then the session's commands, read at each request so that an extension's
  new command shows at once, with pi's fuzzy filter over both. `@token`: the agents of the session first, then files from
  `fd` with pi's arguments and scoring. No forced Tab completion and
  no plain-path completion in a prompt (the user's decision).
- In `!` mode, `/` and `@` offer nothing, and nothing completes as
  the user types: only Tab completes, from bash ("Shell completion").
- The token rules are one copy in `share/koa/token.ts`, which koa
  and the page import, so the page asks only in a context and the
  two sides agree on where a token starts. koa computes the prefix,
  the options, their insert text and the matched letters; the page
  decides nothing.
- The user's pattern follows `--` in `fd`'s argv, so a query such as
  `@"--help` is a pattern, never an option. Each search has a
  deadline and caps. A request that the page aborts ends its `fd`.
- `@name` agents are the viewed agent's scope from the tree
  (design-subagents.md, "The tools, and what they call"), with the
  shared rules in `share/koa/agents.ts`; only the pane peers come from
  `ko api GET /layout`. A completed `@name (session <prefix>)` reaches
  the model as typed, and the extension's tools resolve it.
- No completion inside a code span or a fence: the source checks the
  Markdown tree.
- The popup is CodeMirror's tooltip, mounted in a layer at the page's
  root (inside the field, the field's own backdrop filter made it a
  backdrop root, so the popup's blur saw only the field), pinned above
  the field.

**Shell completion.** In `!` and `!!` mode, Tab asks bash for the
word at the caret where the command would run (the user's decision;
the mockup is `app/design/koa/`, NOTES.md "Tab completes, from
bash"). `/complete` answers a `shell` result (`koa-records.ts`) for a
`!` text and a `prompt` result otherwise, so the page has one
completion source for each mode.

- **Where.** koa cannot know the extension's resolved runtime: the
  extension starts
  and checks a routed runtime itself, and a pane variable cannot say
  that a runtime is still starting or was refused. So koa asks the
  extension (`host.extension.completionContext`), which answers
  through the resolver of its current session (`share/koa/completion-context.ts` holds the
  type): the host with the session's
  cwd, a runtime with the cwd that `user_bash` would give the routed
  command, or `unavailable`. A refused or unready runtime, or no
  resolver, is `unavailable`, never the host. A session end or a
  switch aborts the requests in flight, and a reply for a session
  that is no longer current is a 409.
- **How.** One exec of `koa-shell.sh` for each Tab, never pi's
  `executeBash` (it would enter the transcript) and no persistent shell. On
  the host it runs in koa's environment; in a runtime it runs through
  the runtime's exec route (`share/koa/runtime-exec.ts`, the
  extension's client) with no environment from the host, in the login
  shell that the extension's routed commands use (`bash -lc`, else `sh -lc`), and then
  changes to the resolved cwd, because a profile can change it. The
  script prefers a bash of version 4 or later from that environment's
  PATH and the usual prefixes, starts it without profile or rc files,
  and sources only an installed bash-completion of that environment.
  A registered completion function decides the matches, its
  `compopt` options and its fallbacks (`default`, `bashdefault`,
  `dirnames`, `plusdirs`; a loader's 124 retries at most three times);
  without one, command names in command position, else files and
  directories. `-W` and `-C` specs are not evaluated: they fall back
  to files.
- **Never the typed text.** The line and the caret's byte offset are
  arguments. The script splits the line with its own lexer (quotes,
  escapes, separators, assignments and redirections) and returns no
  matches for a line with a substitution, a heredoc, a process
  substitution or a parenthesis, so nothing that the user typed runs.
- **Bounds.** Each request has a deadline of 2 s and 1 MiB of output;
  the page's abort kills the process group. The script sends the
  replacement span in bytes, the common prefix over every match
  (shortened to a whole UTF-8 character), the count and at most 200
  NUL-separated matches with their quoted insert text; koa checks the
  framing and converts the span to the page's UTF-16 offsets.
- **The page.** A pending Tab waits (no second request) and shows
  "completing…" after 150 ms; typing or a caret move cancels it. A
  stale answer (another text, caret, session or child) is dropped.
  Tab and ↓ move in the list and ↩ accepts, as its hints line says:
  the spec's "Tab accepts" conflicted with its hints, and the hints
  won. Measured: 28 ms on the host, 311 ms for a cold command runtime.

## The external editor

Control-G in the composer opens the draft in the user's editor, as
pi's external-editor key does (`koa-editor.ts`). The editor runs in a
ko pane, so it gets a real terminal, and its result replaces the
composer's text; koa never sends it.

- **The command** is pi's, in pi's order: `externalEditor` of the
  project's `.pi/settings.json`, then of the agent directory's
  `settings.json`, then `$VISUAL`, `$EDITOR` and `nano`, split on
  spaces as pi splits it. The draft's path is the last argument.
- **The login environment.** The float runs the command under `ko
  shell --`, like a spawned agent, so the editor gets what the user's
  dotfiles set, such as `NVIM_APPNAME` (docs/design.md, "The login
  environment", names the shells whose dotfiles `ko shell` reads).
- **The draft** is `koa-draft-<pane>.md` in a new private directory
  under the temporary directory, so the editor highlights Markdown;
  the file is `0600` and is created, never reused. koa removes the
  directory on every end: a result, a failure, a session change and
  koa's own exit.
- **The float.** koa adds the editor as a bordered float over its
  own pane, not the whole window, because the editor belongs to that
  pane's draft and must not hide a terminal beside it: centred on
  koa's pane, 80% of it, at least 60 columns by 16 rows, moved to stay
  inside the window; only a pane below that minimum gets the float
  centred on the window, clipped to it.
  koa writes the float through `PUT /layout` with the
  revision it read, and reads the layout again on a `409`, three
  times at most. The float is a child pane: `parent` is koa's pane
  and `close` is `on_exit`, so the sweep removes it with koa, and a
  child float may share only its parent's window (protocol.md,
  section 7). Its `fixed_title` is "Draft for @<koa's name>", so the
  sidebar, the tab and a close alert name the draft and not the
  editor's temporary file, and its `close_confirm` is `never`: the
  draft is safe in the composer, so the user closes the float
  without a question. The editor runs on the host also when pi's tools are
  routed to a runtime, because koa and the draft are on the host; a
  koa inside a runtime refuses Control-G.
- **The end.** A `/client` connection that does not size or focus
  anything, opened before the float, gives the float's `dead` event
  with its cause. Exit 0 with a text that
  differs from the draft (without a leading BOM and the final newline,
  as pi compares) replaces the composer's text through the same
  `editor` record as `set_editor_text`, only while the session is
  the one that opened it. Any other end keeps the draft with a
  notice, such as "Editor exited 1; draft kept": a non-zero exit, a
  signal, a failed start and the loss of the `/client` connection.
  A float that leaves the layout alive (the user closed it) is a
  cancelled edit: the composer keeps the draft that it held, with
  the one info notice "editor closed · the draft is as before". The
  end claims the edit before it reads the result file, so a removal
  during the read cannot cancel and then replace the draft. A
  session change or koa's exit during the opening or the edit cancels
  it and removes a float that the opening already made. koa then removes the
  float itself and the server gives the window's focus back to koa's
  pane, the removed pane's parent.
- **Focus.** The page focuses the new float at once through
  `window.ko.focus` (Kido.app, "Focus from a page" in
  design-app.md); a second Control-G while the editor is open
  focuses it again and opens nothing. When the edit ends, the page
  focuses the composer. The terminal client has no `window.ko`, and
  no koa page, so the float stays unfocused there.
- **While the editor is open**, from the Control-G on, the draft is
  locked; once the float exists, the state record's `edit` names the
  float and the editor. The draft stays visible and read-only, the
  state cell says "Editing…" with the tooltip "Editing in <editor>", sending, the take-back and
  the pickers are off, and Escape and Return do nothing; the queue and
  the transcript stay live. While `edit` is set, the field is `inert`
  and has the class `editing` (design: `app/design/floats/NOTES.md`):
  the composer is dimmed to 45%, except the state cell. The dim is on
  the children of the field and on the chips and the queue, not on
  the field itself, because a child cannot be more opaque than its
  parent. Nothing in the composer takes a pointer event. A click
  anywhere on the composer focuses the editor's float through
  `window.ko.focus`, and its press does not move the page's focus. A page without a ko pane (`--browser`) shows
  "C-g needs a ko pane" for 4 s.

## The composer's foot

The user decided with the mockup that koa has no status bar: the
foot of the field holds the state, the model and thinking-level
buttons, the context, the extensions' statuses (`setStatus`) and the
working directory at the right. The state cell has a fixed width, so
a change of state or time never moves the cells to its right. The row
has no send or stop button and says nothing about Return and Escape.

- **Narrow widths.** The foot drops cells by its own width, a
  container query on the field, not the window's: the field is what
  the cells must fit, whatever the pane and the sidebar do. The
  extensions' statuses go first. Under 540px the level, the cwd's
  leading directories and the context numbers go; the model picker
  then offers the levels. Under 340px the model and the cwd go, and
  the context moves to the right. Under 200px the context goes and
  the state cell gives up its reserved width, so its text ellipsizes.
  The cwd and the model's name ellipsize at every width, so a deep
  directory or a long model never pushes the other cells, and the
  foot never overflows the field. What a step hides stays reachable:
  `/model` and `/thinking` open the pickers, above the field when the
  model cell is hidden; `/session` lists the model and the context
  numbers, and the cwd is the pane's title.

- **Pickers.** The model and level buttons open pickers above the
  foot; a pick goes through `set_model` or `set_thinking_level`. No
  key inside the field opens them: Control letters are Cocoa text
  bindings.
- **Dialogs.** An extension's `select`, `confirm`, `input` or `editor`
  is a card above the field. The open dialogs are part of the `state`
  record, the one record that a page gets again when it loads, so a
  reload during a dialog shows it again. One card at a time; a
  dialog's timeout is koa's, which removes it as pi does. An editor
  field submits with Control-Return, because Return and Shift-Return
  are newlines there and every Command key goes to Kido first.
- **The queue.** pi's `queue_update` carries the whole queue, so the
  page shows the steering messages, then the follow-ups, in the dock
  above the field. The user decided with `lines.html` (2026-11-12):
  each entry is a dimmed user block of one line, the first line of
  its text with the Markdown syntax removed, its attachments as a
  count, its kind where a sent message has its time, and a × that
  removes only that entry. The transcript's bottom padding is the
  dock's height, so the bottom that the view follows is the top of
  the queue: a block that arrives or goes keeps a view at the bottom
  there and keeps the scroll position of a view scrolled up.
  Taking it back (Option-Up, Escape) calls `clear_queue` and puts the
  texts, with their attachments, into the composer.
- **Removing one entry.** pi has no removal of one entry, only
  `clear_queue`. So `POST /queue/remove` names the entry by kind,
  index and text; koa refuses it when its queue view differs there,
  clears the queue, and sends the other entries again in their order,
  with their kinds and attachments. If the cleared queue no longer has
  that text at that place, koa sends every entry again and refuses.
  The user accepted that pi can take an entry or end the turn between
  the clear and the resend, as with a take-back. A send that waits in
  the queue, a take-back and a removal go one at a time through one
  chain in koa, so Escape's take-back waits for a removal and then
  aborts. When a resend fails, koa stops and returns the entries that
  it did not send, and the page puts them into the composer as a
  take-back does, so no queued work is lost.
- **Context and model facts** come from the session (its model,
  thinking level, name and file), the pickers' results,
  `thinking_level_changed`, and `getSessionStats` after each turn,
  settle and compaction. koa runs no git: the user removed
  the branch and dirty mark.
- `setEditorText` replaces the composer's text; `setWidget`,
  `setTitle` and the other fire-and-forget methods are ignored.

## `!` commands

A message that starts with `!` runs a shell command as pi's TUI does:
`!cmd` puts the command and its output into the model's context,
`!!cmd` keeps them out. koa runs it as pi's RPC mode does (`runBash`
in `koa-agents.ts`), never as a prompt and never through the queue:
it emits `user_bash` to the extensions first and records their
result, else calls the session's `executeBash` with the operations
that they returned. So the extension runs a routed pi's command in
its runtime (design-runtimes.md, "Agents in a
runtime") with no work in koa. The mockup is `app/design/koa/`,
NOTES.md "`!` runs a command".

- **One running command.** koa refuses a second command while one
  runs: pi's `abortBash` cancels every running command, so with one
  a cancel reaches only the command that the user sees. A completed
  command does not block the next. koa also refuses `!` with
  attachments, because their paths would become shell text, and `!`
  with no command.
- **While pi works** the command runs at once, beside the turn, as in
  pi. pi stores its `bashExecution` message only after the turn
  settles.
- **No deadline.** A command runs as long as it runs, and ends by
  its exit, a cancel or the session's end. koa answers the page's
  `/prompt` at once and waits for the result in the background.
- **A live command is state, not an item.** `State.bash` holds the
  running command, with the output of pi's `bash_execution_update`
  deltas for the id that koa gave the command, published once for each
  flush, and the completed commands that pi has not stored yet. The
  live output keeps its tail under the cap of a tool result
  (`koa-transcript.ts`), with the count of the bytes that it dropped,
  because a running command's newest line is the one to see; pi's
  stored output also drops its start. The page shows each command
  where it ran. At most 16 completed commands wait for their record,
  so the state stays bounded through a long turn; koa refuses the
  next `!` until the turn ends. pi stores a completed command's
  message at once while it is idle, and at `agent_settled` while it
  streams. So every rebuild that starts while pi is idle (the
  reconcile after a command, at `agent_settled`, a compaction's)
  takes the completed commands of that moment, and one rebuild runs
  at a time; a `!` sent during a rebuild starts after it. A rebuild
  while pi streams keeps them, and a running command stays in every
  case. The rebuild publishes the state without the
  completed commands of its snapshot before it sends its reset, and
  puts them back when the conversion fails, so no command shows
  twice, even when the page paints between two records. The stored
  message is the one source of the item, and a resumed session shows
  the same item. koa adds no item of its own and matches nothing.
- **Duration.** pi stores only the time of a command, so the duration
  shows only while koa measured it: during the run and until the
  rebuild.
- **Cancel.** While a command runs, Escape and the abort route send
  `abortBash` once; pi returns before the command ends, so the next
  Escape aborts the turn. pi keeps the output that the command wrote
  before the cancel.

## Images

pi stores images as base64 inside its messages: a user message's
images, and a tool result's (`read` of an image, any tool's image
blocks). The bytes never go through the feed: one screenshot is
megabytes, a record that carried it would end the response of every
slow page, and the page's items would hold it for the life of the
document. So koa writes each image to its own file in its private
directory and the records carry a reference (`ImageRef` in
`koa-records.ts`). The user decided that every image is kept, with no cap
and no eviction, as pi keeps them; koa's heap stays flat, and the cost
is disk under the temporary directory, rewritten at each rebuild.

- **Ids and revisions.** An image's id comes from its item, its block
  and its ordinal, so a rebuild gives the same ids to the same images.
  A changed partial result under the same id increments the
  revision. The page's URL `/images/{id}` carries the epoch and the
  revision, because WebKit keeps a decoded image for a URL whatever
  `Cache-Control` says: without them a rebuilt id showed old pixels.
- **The type** comes only from the sniffed header (`koa-image.ts`:
  pi's set of image types and its exclusions, with the dimensions),
  never from pi's claimed `mimeType`; an image that matches no header
  is served as bytes with no type.
- **A served file is never a document.** Every file response of koa
  (`koa-http.ts`) carries `nosniff`, a `sandbox` CSP of its own and the
  file's name in `Content-Disposition`, so a payload that only claims
  an image type never runs on koa's origin. The page never uses
  `blob:` URLs, which the server's CSP forbids.
- **Lazy loads.** A step's images are created at the step's first
  open, because a hidden `<img>` still loads; a user message's
  thumbnails load at once. Each `<img>` reuses its node and carries
  its size, so the bottom-following scroll does not jump.

## Attachments

A file that the user drops or pastes reaches pi on the host where pi
runs, as one of two kinds:

- **A local session: the original path.** The user decided that pi
  edits the user's file, not a copy. A session is local when the
  window's server is the Mac's and the pane has no runtime
  (`WindowOwner.isLocalProgram`, given to the page as
  `window.ko.local`). Kido.app takes a Finder drop on such a page
  itself and posts each path to `/attachments` with the header
  `Kido-Native-Drop: 1`.
- **Every other case: the bytes.** A paste, and a drop in a remote
  session, a runtime or a browser, upload the bytes in chunks below
  the bridge's body cap into koa's private directory, so the file
  exists where pi runs. A path on the page's machine means nothing to
  a pi on another host.

**The native drop is the one grant of a host path.** Only Kido.app
can name a host path: koa refuses a path attachment without the
header (403), and Kido.app's scheme handler and the SDK's browser
target remove every `Kido-` header from a page's requests. Thus no
page, local or foreign, can read a host file that the user did not
drop. The app gives the page only the attachment records of koa's
answers, through the `ko-drop` event; koa removes a path attachment
whose answer did not reach the app, and the app removes one that it
does not give to the page, so a cancelled drop holds nothing.
design-app.md, "Drops on a page", gives the app's side.

- **Folders are not attached** (the user's decision), local or not,
  as the terminal's upload refuses them; the files of the same drop
  still attach, and the chip row says so.
- **The kind** (image or file) comes from the sniffed header, never
  from the browser's type or the extension.
- **Limits** are one record, `ATTACHMENT_LIMITS` in `koa-records.ts`, which
  koa and the page read; the per-file limit equals Kido's upload
  limit. An upload that is aborted, or that stalls between chunks for
  `KOA_UPLOAD_IDLE_MS`, is removed with its file and its share of the
  limits.
- **Sending.** An image goes to pi as an image of the `prompt`
  command, in every mode; any other file as a path line after the
  typed text, as pi's TUI pastes copied files. A local dropped image
  goes only as an image, because pi's `read` of the path would send
  the same pixels again. pi accepts an empty message with images.
  The page does not resize: pi resizes to the model's limits, and a
  resize in the page would change what the session keeps.
- **States.** An attachment is ready, queued (in a prompt that pi
  has not delivered) or used (in a delivered message). A used
  attachment cannot be deleted, a take-back returns only queued ones,
  and a late acknowledgement never moves a used one back.
- **Chips of a sent message.** The page never guesses attachments
  from the text. koa keeps a record of each send (`koa-queue.ts`) and
  matches a delivered user message to it with pi's own bookkeeping:
  pi removes a delivered text from its steering queue first, then
  from the follow-up queue, and emits `queue_update` before the
  message, so the text that left a queue names the mode and the text
  of the next message. koa then strips the path lines that it
  appended, so the item shows the typed text with its chips. pi never
  removes an empty text (an images-only prompt) from its queue lists,
  so koa counts the delivered empty texts of each mode and drops that
  many from the queue view and the take-back. A rebuilt item has no
  such record: it shows pi's text, path lines included, and its
  thumbnails.

## Quick Look and the lightbox

A click on a thumbnail or a chip, Space or Enter on a focused one, and
⇧⌘-click on the label of a `read`, `edit` or `write` step with a path,
call `window.ko.preview(url, rect)` (design-app.md, "Quick Look from a
page"). The user chose ⇧⌘-click to match the terminal's gesture for a
kitty image; a plain click still folds, and the label shows a link's
underline only while both keys are held. Quick Look shows any type
that it can; the app limits only the size.

The URL is always on the pane's own origin, so one mechanism serves a
local and a remote session and the app fetches no Mac path itself.
koa serves a step's file at `/steps/{seq}/{block}/file`: the page
names a step, never a path, because a route that took a path would
let the page read any file of pi's host, and in browser mode that
route sits on a localhost port. koa takes the path from its own record
of the step, resolves it as pi's tools do (against the session's
directory, `~` expanded, a leading `@` removed), and streams a regular
file from the descriptor that it checked.

In a browser, `window.ko` does not exist: an image opens in a lightbox
inside the page, which Escape closes before it aborts anything, and a
file opens in a new tab.

## Agent lines and job lines

The agent extension is the only writer of agent messages and job
notices, and it ships with koa, so it writes the facts that the page
needs
into each message's `details` (and into the `details` of the
`spawn_agent`, `message_agent` and `async_bash` results), typed by
`share/koa/records.ts`. The transcript reads `details` only, never the
header lines, which stay in the text for the model.
`details` is also in the session file, so a rebuild shows the same
lines. A custom message without these details (another extension's,
or a session written before them) stays a plain notice.

The user decided the look with the mockups `agents.html` and
`refine.html`:

- `spawn_agent`, `message_agent` and every inbound agent message are
  one line, like a step's line, not a card: one phrase in the prose
  font, `<kind> to|from @<name> <relation>` ("steer from @kido-app
  parent"), then the first line of the text, then the time at the
  text edge, in the prose font. The relation is one word,
  `subagent`, `peer` or `parent`, that folds the extension's five
  relations; its own notices have none. The line splits its run as a text
  does. The first line is plain text with its Markdown syntax
  removed (the first code line when the text starts with a fence),
  and it ellipsizes, so a closed line keeps its height. A click opens
  the text under the line, as Markdown rendered as final text by the
  reply's renderer. A custom message without agent details is not
  an agent line: it is a notice row ("Every notice is one row" under
  "The transcript") of its first line with the same syntax removed,
  and it opens to the rest as Markdown when it has more lines. A line shows no delivery status and no
  meta lines: only a failure shows, in the error colour in the
  kind's place ("refused to @name", "not reported from @name
  subagent").
- **Run, agent and job lines are one look.** None has a chevron; the
  whole line folds it. Tool names, step names and the agent lead are
  prose at the row's size; only a command or path inside a step is
  terminal text. Times are prose at .8em with tabular digits. A
  running tool shows its name and then the spinner, not its command.
  Rows indent by `--pad` from the text edge and their times end on it;
  an opened body, a run's steps or an agent's text, indents from that
  point. Consecutive run, agent, job and notice rows sit 2pt apart;
  the last of a group and an opened row keep 14pt.
- **`@name` goes to the agent.** An agent's name in an agent line,
  and an `@name` in the prose of a reply or a user message, is a link
  while the name is in koa's list of live agents. A click on an agent
  of this process switches the view ("Views"); one of another pane
  calls `window.ko.focus(pane)` (design-app.md, "Focus from a page"),
  as a click on the agent's sidebar row does. The list is the state's
  `agents` (`koa-records.ts`): the live agents of the viewed agent's
  scope, the same set as `@` completion. koa reads it at start, at
  each change of the tree and after each
  `spawn_agent`, `message_agent`, `stop_agent` and `list_agents`
  result and each displayed custom message, not on a timer, and
  publishes the state only when the list changed. A change elsewhere
  (another pane starts or ends an agent) shows at the next of these
  events; a stale pane id is harmless, because the app refuses a pane
  that is not in its layout. Prose links a name only when it renders
  (never inside code or an existing link), so a name in an older reply
  does not follow later changes; an agent line renders again when its
  agent joins or leaves the list, and a name that left it is muted,
  with no link ("ended"). In a browser, a click does nothing.
- `stop_agent`, `list_agents`, `read_report`, `list_async_bash` and
  `stop_async_bash` stay steps: they are the caller's own actions, not
  messages.
- A job is not an agent (design-subagents.md, "A job"): its end
  notice is one prose line, like a run line, with no end text; it opens
  to its output, gray on success and in the error colour on failure,
  and the stream
  batches of one job join into one entry. The page has no live list of
  jobs; the sidebar shows them.

## Reply annotations

Any pi extension can mark spans of a final reply with a type and its
data, in a custom session entry; reply-annotations.md is the contract.
koa does not depend on a producer: the first is pi-infer-questions,
which finds the questions of a reply, and the page renders the
`question` type. The user decided:

- **An annotation is an item of its own kind,** placed by time, not a
  field of the assistant item. A final item never changes, and the
  page's cursor is its last final item, so a later change of a final
  reply would not reach a page that reconnects after it. As an item,
  an annotation enters the window and the `/items?before` page as a
  job notice does.
- **The transcript checks the entry at its edge.** Live, koa gives it
  each `entry_appended`; on a rebuild, the session manager's entries
  (a custom entry is not a message) that are on the parent chain of
  pi's leaf, placed by time among the messages, which keep their
  branch order. koa reads the messages, the entries and the leaf in
  one synchronous step, so no event falls between them.
  The transcript resolves the reply key to the assistant item and its
  block, and applies the contract's drop rules. The page never sees
  an unknown type, a stale entry or a bad span. A second entry for the
  same block is a new item; the page uses the newest.
- **The page hides the item** and renders the reply's text block
  again with the annotations; a reply that arrives after its
  annotation (a window cut, an older page) reads the page's map of
  annotations when it renders.
- **Markers, not a second parser.** `page/annotations.ts` converts the
  code points to UTF-16 offsets once and makes the marks: an option's
  start and end, and a question's end. `page/markdown.ts` inserts each
  mark into the raw source of the top-level token that owns it before
  marked parses that token. A closing mark at a token boundary belongs
  to the token before it, an opening mark to the token after it, so a
  question's controls stay in its list item. marked passes the
  private-use marker characters through as text, and a walk over the
  text nodes of the parsed HTML replaces them with the options and
  the controls. An option is an inline span with the button role, not
  a `<button>`: WebKit lays out a button as an atomic inline block that
  centres its text, so a long option in a list item would not wrap as
  prose. The controls after a question are buttons. This is the TUI's technique on the DOM, so both
  renderers share one rule for where a marker can fall: the
  producer's guarantee that a boundary is never inside Markdown syntax.
  A marker character in the reply's own text is replaced before the
  marks go in, so a reply cannot forge a control.
- **The labels and the click are the TUI's**, except for the blank
  line below (pi-infer-questions'
  `extension.ts`): `page/answers.ts` is its quote and answer rule, a
  pure function. A click sends nothing: it sets the composer's text
  and puts the cursor at the end, and the user edits and sends. A
  control is selected while its answer is the answer of its
  question's block in the composer; the composer's input refreshes
  the selection.
- **The answer follows its quote with no blank line.** The user
  decided against the TUI's empty line: a block is the quote's `> `
  lines and then the answer on the next line, and blank lines
  separate the blocks. In CommonMark that answer is a lazy
  continuation of the quote, so the composer and the render of a user
  message have no lazy continuation: a quote is only its consecutive
  `>` lines, and the line after it starts a new block. The composer
  thus shows the answer as plain text, and the sent message shows the
  quote and then the answer as its own paragraph. The rule is in the
  parsers' blockquote rule, so fences, indented code and list items
  keep their own rules. An assistant reply keeps CommonMark, and the
  model gets the raw text.
- **The look** is the mockup `questions.html`, chips version
  (app/design/koa/NOTES.md, "Question controls in a reply").

Without the producer in koa's pi (not installed, an unsupported
platform, models that fail to load) there is no entry and the reply
shows as before. A routed runtime's pi runs on the host with the
host's extensions; only a `pi: runtime` runtime and a remote host need
the producer where pi runs, and koa does not supply it.

## Browser mode and its origin rule

`koa --browser` uses the SDK's browser target: the same program and
page on a localhost port, opened in the user's browser. A local port
is open to every local process and to every web page. The SDK's
forwarder refuses a foreign or null `Origin` and a foreign `Host`
(design-webview.md, "The SDK"). A request without `Origin` passes the
forwarder, so koa's typed-body rule makes a form post that arrives
without one do nothing.
The user decided that a local process may call koa's routes, so there
is no token. A host path is never reachable from a browser page: the
native-drop header comes only from Kido.app, and a step's file comes
only from koa's own record.

In the browser, the page applies its fallback theme (the mockup's
`:root`, after `prefers-color-scheme`); in Kido.app the `--ko-*`
properties win, and every tone of the page is a `color-mix` of them,
so a theme change needs no code in the page.

## Measurement

`share/koa/stress/` runs scripted workloads (`workloads.ts`) through
the scripted pi in headless Chrome (`run.sh`) and in off-screen Kido
windows (`make -C app koa-stress`), and prints one report
(`report.ts`), which fails a page above its memory budget. With
`--metrics`, koa stamps each flush and the page reports when it
applied it (Kido's off-screen windows run no `requestAnimationFrame`)
or framed it (Chrome), with koa's byte, reconnect and cap counters.
The runs are manual, never in `make verify`. What they found shaped
the design: the SSE feed, the memo's raw-text rule, and no limit on
the number of webviews in Kido, because eight visible streaming panes
keep up.

## Tests

The TypeScript suite runs koa with the pinned real pi of
`share/koa/package.json` and the fake ko. pi's session runs in koa's
process, so no pi can be scripted; the suite scripts the model
instead. `koa-fake-provider.ts` is a local HTTP server that speaks
the OpenAI chat completions stream: each test gives its replies
(text, thinking, tool calls with arguments in pieces, HTTP errors)
and its gates, which the test releases and which end with the
provider. It refuses an unexpected method, path, key, model or a
request after the script ends, and records it, so a test cannot pass
on a request that it did not expect. A private agent directory names
it in `models.json` with a literal key, so pi asks for no
credentials. `realFixture` in `koa-program-fixture.ts` starts koa
with a private `HOME` and agent directory; facts that a model cannot
make come from real pieces: a session file written with pi's
`SessionManager` for history, a small test extension for dialogs,
statuses, startup UI and extension errors, and pi's own tools for
tool results. The suite covers the feed, the delivery, the routes,
the attachments, the reload and the restart, the session switch, the
project trust, the crash handler, the status bytes, the transcript
module, completion, the queue's matching, the image sniffer, and the page's DOM rules over a
fake document with the page's types stripped (`koa-dom.test.ts`);
its reveal tests drive the frame loop and the clock by hand over a
height model. The
Markdown memo is a pure module, tested under Node against a full
render of every prefix, its annotation marks over each kind of block
and the reveal's cut at whole units (`koa-page.test.ts`).

Kido.app's `KoaWebviewTests` snapshot each state of the mockups in
light and dark, windowed and narrow, and check the composer's keys,
focus and popup, and the question controls' placement and clicks, in
a real WebKit. They test the page, not the host: the page runs
against `testdata/replay.ts`, not koa, so a host change moves no
page snapshot. A snapshot moves only when the page's code or the
page-record format changes. The replay server is a test program, not
a mode of koa, so the product has no test path. It serves the page
that `assemblePage` builds from the built `share/ko/koa/` (the one
source of the page and its `koa-instance` meta for koa and the
replay), runs in a pane through the webview SDK as koa does, and
loads no pi.

A scenario is a typed script: the `PageRecord`s that the feed opens
with, then a list of steps. A step either pushes records when the
test posts `/replay/next`, or answers one page request with a canned
reply of the page's own route type (`Routes` in `page/http.ts`) and
pushes the records around it. A reply can be held until the test
posts `/replay/release` with its name, so the page shows its waiting
state. So a change of the record format or of a route's shape
fails `tsc` in the scenarios, never silently. A request that is not
the next step gets 409 and counts as a mismatch; every page test
asserts at its end, through `/replay/status`, that the script ran to
its end with no mismatch and no held reply. The attachments, the
step files and the images do not fit a script, so the replay serves
them with koa's own modules (`attachments()`, `stepFile`,
`serveFile`) and koa's POST content-type rule. The scenarios were
recorded once from the real chain; the recorder is gone, and a new
state gets a step written by hand from the types, as
`koa-dom.test.ts` writes its records. A frame that shows a path of
the test's directory needs a fixed directory name, which the Swift
test sets. The `reveal` scenario injects its own clock and pauses the
grow at a fixed point, so a mid-reveal frame is deterministic.

`KoaHostTests` keeps four tests on the real chain (koa, the pinned
pi, the fake provider): the startup and the interrupt, the editor
float, the feed's held tail, and one lifecycle from a prompt through
the real feed to `/quit` and the pane back at the terminal. Every
other host fact that the page tests checked on the way has its test
in the TypeScript suite.
