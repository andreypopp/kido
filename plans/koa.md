# koa: a webview harness for pi

Status: a plan, 2026-11-08. The UI reference is the mockup
`app/design/koa/mockup.html` and its notes `app/design/koa/NOTES.md`
(renders in `/tmp/koa-shots/<section>-{light,dark}.png`). The plan
refers to the mockup's sections and does not repeat its rules. The
user decided the open questions of NOTES.md on 2026-11-08: prose in
the system font; a failed run stays collapsed; the status bar at the
bottom; the context bar always shown; a user message shows its
timestamp, so the record model carries the time of each user message
(`at` below). The design agent adds the timestamp to the mockup.

koa is a program for a Kido pane. It starts pi in RPC mode, owns pi's
stdin and stdout, and renders the session as an HTML page through the
webview feature (docs/design-webview.md). In a Kido pane the page
fills the pane; during development it renders in a browser on
localhost through the SDK's browser target. koa is also the stress
test of the webview feature: its workloads exercise and measure the
webview path, and section 5 says what they measure and how.

The documents that this plan builds on: docs/design-webview.md,
docs/protocol.md section 16, docs/design-app.md "Webview panes",
docs/design-program-status.md, docs/design.md "The pi extension,
ko-pi", `share/webview/index.ts` and `share/webview/README.md`, and
pi's `docs/rpc.md`, `rpc-commands.md`, `rpc-extension-ui.md`,
`json.md`, `message-types.md`, `session-format.md` and `sessions.md`
(pi 1.5.0). Every pi fact below comes from those files.

## Goals and non-goals

Goals, in priority order:

1. One pane, one page: transcript, composer, one status bar, as the
   mockup shows. Streaming markdown, runs of tool calls and thinking
   folded into one line, each step expandable to its details.
2. A koa pane is an agent pane. The sidebar shows it as a pi agent
   with ko's harness, `ko prompt` and `message_agent` reach it, and
   its agent tools work.
3. The webview path under load, measured. Long sessions, fast token
   streams, large tool output, reconnects and reloads, several panes,
   hidden pages and theme changes.
4. Small: TypeScript on Node 24, no runtime dependency, one page file,
   one program file beside a shared transcript module.

Non-goals, for this plan:

- A terminal UI. Without a client that shows webviews, koa prints one
  line that says so and keeps serving; the page shows when a client
  with webviews connects (`supported`).
- Session trees, `/tree`, forks and clones from the page. The RPC
  commands exist; the page gets them when the user asks.
- Images in prompts and in results. A result image is a count, as in
  ko-pi's page.

## Decisions

1. koa lives in `share/koa/`, installed as `share/ko/koa/`, with the
   shim `share/ko/bin/koa`. The reason is the relative import of the
   SDK and of the shared transcript module, which must resolve the
   same way in the checkout and in the installed layout.
2. koa is TypeScript that Node 24 runs as is, with no runtime
   dependency. Its pi types are `import type` from
   `@earendil-works/pi-coding-agent`, which the suite's
   `share/pi/package.json` already pins; Node strips them.
3. Markdown renders with `marked` and `remend` from npm, under a
   block memoization that koa's page writes itself in plain DOM. The
   user decided the libraries on 2026-11-08 and, on 2026-11-09, the
   build pipeline of section 7 in place of vendored files: the page
   is TypeScript that esbuild bundles into one `page.js` at `make
   build`, never committed.
4. koa spawns `pi --mode rpc --extension <share>/pi/ko-pi.ts`, so the
   agent tools, the message stream and the `pi.*` variables stay
   ko-pi's. koa owns the pane's OSC 7501 root record and its title.
5. The transcript model, the caps, the window and the incremental
   delivery (`reset`, `item`, `patch`) move out of `ko-pi.ts` into one
   shared module, `share/pi/transcript.ts`. ko-pi feeds it from pi's
   in-process events; koa feeds it from RPC events. Neither keeps a
   copy.
6. The run grouping and the fold state are the page's. A run is
   derived from the items; nothing stores it.
7. The page talks to koa over HTTP only: one `EventSource` on
   `/events` and short `fetch` requests. No WebSocket.
8. Every signal of koa goes through one function, `signalPi`, which
   takes koa's own child record. `scripts/lint.sh` applies the
   `process.kill` rule of `share/pi/` to `share/koa/`.
9. A new route, `POST /panes/{id}/status`, writes one report into the
   pane's record set; ko-pi's job rows go through it in every mode,
   and its OSC job writer goes. The user approved the route on
   2026-11-08.
10. A child takes its parent's harness: ko-pi inside koa's pi, which
    koa marks with `--harness koa`, spawns its children as koa; a TUI
    ko-pi spawns TUI ko-pi children as today. The user decided this
    on 2026-11-08.

## 1. Where koa lives

    share/koa/
      koa.ts              the program
      records.ts          the wire types of the feed, shared by koa.ts,
                          transcript.ts and the page (section 7, "The records module")
      koa-assemble.ts     the one HTML response: page.html with page.css
                          and the built page.js inlined
      page/               the page's sources, bundled by esbuild (section 7)
        page.ts           its script
        markdown.ts       the block memoization over marked and remend
        page.html         the document
        page.css          its style
        tsconfig.json     the page's browser-only type check
      package.json        esbuild, typescript 7, marked, remend (CodeMirror
      package-lock.json   from unit 10), pinned
      koa-fake-pi.ts      the scripted pi of the tests and the stress runs
      koa-*.test.ts       the suite
      stress/             the stress workloads and the runner (section 5)
    share/pi/transcript.ts   the shared transcript module (decision 5)
    share/ko/bin/koa      the shim
    build/ko/share/ko/koa/   the installed layout: koa.ts, records.ts,
                          koa-assemble.ts, package.json, page.html,
                          page.css and the built page.js

**The shim.** `share/ko/bin/koa` sources `shim.sh` and runs
`exec node "$ko_share/koa/koa.ts" "$@"`, with `node` from PATH.
`koa.ts` resolves `pi` on PATH itself; `pi` has no shim, so the plain
lookup is right.

**What koa needs on its host.** koa runs where its pane's program
runs: the local machine, a remote server (`ko HOST`) or a runtime or
container. That host needs Node 24 or later and `pi` on PATH; the
page's client needs nothing. The shim checks both before it starts:
without `node` it prints `koa: node 24 or later is required on this
host; none found on PATH` and exits 127; with an older `node`, the
same line with the version found; without `pi` it prints `koa: pi is
required on this host; none found on PATH` and exits 127. The check
is the shim's, so the message reaches the pane before any JavaScript
runs. The user decided this on 2026-11-08: koa installs everywhere ko
installs, because remote use needs it on the server.

**Build and install.** `koa` joins the Makefile's `SHARE` list
(`Makefile:93`), so every layout that copies `SHARE` carries
`share/ko/koa/` and the `bin/koa` shim: `make build` under
`build/ko/`, `make install` and the Homebrew formula, Kido.app's
bundle (`app/scripts/bundle-ko.py`) and the static Linux layout
`share/ko/linux/<arch>/share/ko/` of `make build-linux`, which
runtimes and containers use. `build` depends on `koa-page`, which
bundles the page into `build/ko/share/ko/koa/` (section 7, "The
Makefile targets"), and copies `share/koa/koa.ts`, `records.ts`,
`koa-assemble.ts` and `package.json` beside it, and
`share/pi/transcript.ts` beside `ko-pi.ts`. `preview-pi` gets the
same installed `koa/` files from `build/ko` and `pi/transcript.ts`.
The sources under `page/`, the tests and the stress files are not
installed. koa reads `page.html`, `page.css` and `page.js` beside
itself on each request of `/` and serves one HTML response (section
4), so a rebuilt page shows at the next page load (⌘R; `make
koa-watch` rebuilds on each save); a failed read answers 500; any
other path but its routes is 404.

**Checks.** `share/pi/tsconfig.json` includes `../koa/*.ts` (the
Node side of koa) and maps `@earendil-works/pi-coding-agent` to
`share/pi/node_modules` in its `paths`, so koa's type-only imports
resolve from `share/koa/`; `share/koa/page/tsconfig.json` checks the
page against the DOM alone (section 7, "Type checks"). Both checks
run with the `tsc` of `share/koa/node_modules`, typescript 7.
`scripts/test-ts.sh` runs `koa-*.test.ts` with the ko-pi suite.
`scripts/lint.sh` adds `share/koa/*.ts` and `share/koa/page/*.ts` to
its TypeScript globs: the stale-prose check, the `as`/`any`/`!`
hygiene check and the `process.kill` rule, whose one permitted site
becomes `signalJob` in `ko-pi.ts` and `signalPi` in `koa.ts`.
`share/koa/node_modules` is ignored as `share/pi/node_modules` is.

**Dependencies.** In the page, `marked` and `remend` from
`share/koa/package.json`, bundled into `page.js` ("Markdown" below;
CodeMirror joins them in unit 10). In `koa.ts`, none at run time.
Type-only imports:
`RpcCommand`, `RpcResponse`, `JsonAgentSessionEvent`,
`RpcExtensionUIRequest` and `RpcExtensionUIResponse` from
`@earendil-works/pi-coding-agent`, and `AgentMessage` for the shared
module. The suite type-checks them through `share/pi/node_modules`.

**Markdown.** The page renders GitHub-flavoured markdown with two
libraries, both without dependencies: `marked` (MIT), the
lexer and the parser, and `remend` (Apache-2.0, from
`vercel/streamdown`, `packages/remend`), which heals an incomplete
markdown source before a render: an open emphasis, an open inline
code span, an open link, an open fence. The page uses marked's lexer
for the top-level blocks and its parser for one block at a time; the
block memoization over them is koa's own (section 4, "Streaming
markdown"). marked passes raw HTML through, so the page renders every
`html` token, block or inline, as escaped text; the CSP of
`ko_server/src/http.rs` stays as it is. A link is text with a `href`;
the app's `app.webview.links` decides what a click does. These two
libraries are the page's only runtime dependencies until unit 10,
and the page is their only user; `koa.ts` imports neither. They are
pinned exactly in `share/koa/package.json` and its lockfile; an
update is one commit that changes the pin and, when the output
changed, the memoization tests of section 5.

## 2. The process model

**Two processes in the pane.** koa is the pane's program: its stdout
is the pane's tty, so the SDK's `show` and `hide` and koa's own OSC
7501 and OSC 0 reach the pane. pi is koa's child with its three
standard streams piped. pi's stdout is the RPC stream, so nothing in
pi may write an escape to it (see "ko-pi inside the RPC pi").

**Spawn.** koa runs `pi --mode rpc --extension <share>/pi/ko-pi.ts
--harness koa`, then every argument that koa does not own, unchanged:
the session and model flags of pi's `cli.md` (`--continue`,
`--session`, `--session-id`, `--fork`, `--no-session`,
`--session-dir`, `--name`, `--model`, `--thinking`) and ko-pi's own
flags (`--runtime`). koa adds nothing to pi's environment: `KO_PANE`,
`KO_PANE_TOKEN`, `KO_SOCKET` and the `KO_AGENT_*` variables reach
ko-pi as they reach a TUI ko-pi. pi gets its own process group
(`detached: true`), so a stop can signal the group that pi's tools
spawn into. koa's own flags are `--browser` (the SDK's browser
target), `--metrics FILE` (section 5) and `--pi PATH`.

**A child takes its parent's harness.** The user decided this on
2026-11-08. ko-pi learns its harness from an explicit flag, not from
`ctx.mode`: it registers `harness` beside `runtime` and `webview`
(`share/pi/ko-pi.ts:1528`), a string flag whose one value is `koa`,
and koa passes `--harness koa` to pi. A pi without the flag is a TUI
ko-pi, as today. `createPane` (`share/pi/ko-pi.ts:3005`) builds the
child's argv from the harness:

- A TUI ko-pi starts `ko shell -- ko-pi ...` as today
  (docs/design-subagents.md, "What a child is given").
- A koa-hosted ko-pi starts `ko shell -- koa ...` with the same
  arguments after the program name: `--runtime` for a routed child,
  `--session` or `--session-id`, `--name`, `--model`, `--session-dir`
  and `--fork`, which koa passes through to its pi. Thus `resume_from`
  and `fork` work unchanged, and the registry, the parent edge, the
  task variable and the notices do not change: the child's pi is the
  same pi with the same ko-pi.
- A koa-hosted ko-pi with `--browser` adds `--browser` to the child's
  argv: the child is a browser target too, and its `show()` opens one
  more browser tab on the child's own localhost port when the child's
  page first shows. A parent in a pane never passes it.
- An inside child in a runtime runs `ko shell -- koa`, which is the
  runtime's own `bin/koa` of the static Linux layout
  (`share/ko/linux/<arch>/share/ko/bin/koa`), so the runtime's host
  needs `node` and `pi` as section 1 says. A routed child runs koa on
  the host with `--runtime NAME`, as a routed ko-pi does.

A koa child in `ko_tui` is a webview pane in a client that shows no
webviews: the row shows the status word `[webview]` and the pane
shows koa's one line (section "Goals and non-goals"); the child
works, reports and ends as any child, and only its page is not
visible there. `supported` is a fact of the server, so with Kido.app
connected the page shows there and `ko_tui` still shows the line.

**Framing.** koa splits pi's stdout on LF only and strips one
preceding CR, with a byte decoder, never `readline`: pi's `rpc.md`
says that `readline` also splits on U+2028 and U+2029. koa reads
stdout continuously, because pi honours back-pressure and a reader
that stops can stall pi. koa writes a command only when `write`
returned true or after `drain`. Every command carries an `id`, and
koa correlates responses by id. A line that is not JSON goes to koa's
own stderr with a prefix; it is a bug.

**Shutdown.** `rpc.md`: closing pi's stdin requests an orderly
shutdown. koa's end, in order: end the page's `/events` streams,
`hide` and `close` the SDK (which then drains the remaining
responses at once), end pi's stdin, wait `KOA_PI_EXIT_MS` (5000) for pi's exit, then `SIGTERM` to
the group through `signalPi`, then `SIGKILL` after the same wait. koa
ends on `SIGTERM`, `SIGHUP` and `SIGINT`, and on a `quit` from the
page. `koa --help` prints its usage and starts nothing. The pane's hangup rules are ko's (docs/design.md, "Window
lifecycle").

**pi exits by itself.** When pi exits with code 0, koa shuts down as
on a `quit`, as a TUI pi leaves the user in the shell: a subagent's pi
leaves when its parent goes (docs/design-subagents.md), and its koa
must go with it so that its pane goes. When pi fails (a non-zero code
or a signal), koa keeps the pane: the transcript stays, the
status bar says `pi exited N` or `pi died by SIGNAL`, the composer
shows the last 20 lines of pi's stderr, and a "Start pi again" action
spawns pi again with the original arguments minus the session flags
(`--session`, `--session-id`, `--fork`, `--continue`, `--no-session`)
and minus `--model` and `--thinking`, plus `--session <sessionFile>`
from the last `get_state`: the session file's model and thinking
changes are the selection, so a picker change survives the restart.
Without a known session file (`--no-session`, or pi died before
`get_state`), the original arguments run unchanged and the exit view
says that the session starts fresh.
The reason: a pane with the default `close: exit` vanishes with koa,
and the user must see the failure. A crash of koa itself is a loud
stop, as everywhere in ko.

**Resume.** `--continue` and `--session` pass to pi. For a `--session`
of another directory, pi runs the session in its own working
directory (pi's `sessions.md`); koa learns that directory from the
session file (below, "The status facts"), not from its own `cwd`.

**ko-pi inside the RPC pi.** ko-pi's `session_start` sets `active`
when `ctx.hasUI`, the session id, `ko` and `KO_PANE` are present;
`ctx.hasUI` is true in RPC mode (pi's `extensions.md`). Thus, in a
koa pane ko-pi opens the message stream, writes `pi.session` and
`pi.name`, registers the agent tools and starts the peer client, as in
a TUI pane. Its own webview starts only with `ctx.mode === "tui"`, so
it does not serve a second page. A message that arrives on the stream
goes through `pi.sendUserMessage` into the RPC pi, and its custom
message reaches koa as a `message_start` and `message_end` event.
ko-pi writes its job rows through the status route (`SetStatus`,
docs/protocol.md), not to its stdout, so in koa's RPC pi a koa pane
has its job rows as a TUI pane has, with no work in koa.

**Status.** pi reports OSC 7501 only in interactive mode
(docs/design.md, "The pi extension, ko-pi": after terminal feature
detection). koa writes the root record `app=pi` itself, on its
stdout, with the states that docs/design-program-status.md names:

- `agent_start` and `compaction_start`: working, with the session
  name as the message.
- `agent_settled`: idle when `aborted`, else the outcome of the last
  assistant `message_end`: error with the first line of
  `errorMessage` when its `stopReason` is `error`, else done.
- An `extension_ui_request` with a dialog method (`select`,
  `confirm`, `input`, `editor`): blocked, kind question, with the
  request's `title` as the message, until its response.
- pi's exit: `clear`.

The row's kind is then `PiAgent`: root app `pi` from koa and
`pi.session` from ko-pi (docs/design-program-status.md, "Pane kinds").
koa sets the pane title with OSC 0 to `koa - <session name> - <cwd
basename>`, and again on `session_info_changed`.

## 3. The page and program protocol

**The shared transcript module**, `share/pi/transcript.ts`, exists
(unit 2). Its `transcript({ flushMs })` takes whole pi messages, so the conversion
to items is in one place and a replay and the live stream share it:
`message(message, phase)` with the phases `start`, `update` and `end`,
`rebuild(messages)`, `toolRunning`, `toolPartial` and
`toolDone` with explicit times, and `state`, `send`, `handle` (the
`/events` and `/items` routes) and `close`. koa feeds it whole
messages on `message_start` and `message_end`, the partial assistant
message that it builds from the deltas on each `message_update`, and
`get_messages` for a rebuild.

The module adds what the mockup needs and ko-pi's page lacked: `at`
on every item (pi's message timestamp, ms; the user message's
timestamp that the mockup shows), `started` and `ended` on a tool
block and `durationMs` from `tool_execution_end`. ko-pi's page
ignores them. ko-pi keeps its own event handlers and calls the
module; its `webview*` state variables go. The module gets unit
tests for the pure parts: the cap, the window, the patch diff.

**koa's feed.** RPC `message_update` records are delta-only (pi's
`json.md`). koa keeps the partial assistant message itself: a
`text_delta` and a `thinking_delta` append to the block at
`contentIndex`; `toolcall_start` opens a tool block with its `id` and
`toolName`; `toolcall_delta` appends argument bytes; the `*_end`
events replace the block with the authoritative content; `message_end`
replaces the whole message. koa then calls `assistantApply` as ko-pi
does. `tool_execution_start`, `_update` and `_end` map to the tool
calls. A user `message_start` is `user`; a `custom` message with
`display` is `notice`; `bashExecution`, `compactionSummary` and
`branchSummary` map as in ko-pi. At start and after `new_session`,
`switch_session`, `fork`, `clone` and `compaction_end`, koa rebuilds
from `get_messages` (the active branch's `AgentMessage` list), with a
new epoch.

**Runs.** The page derives runs from the items: every consecutive
thinking and tool block, across assistant items, between two text
blocks or between the user's message and the first text. A run's
line, its step lines and the step details follow mockup sections 3
to 6 and `app/design/koa/NOTES.md`, from "No step counts" to "No exit
codes": no step counts, no kind marks and no status icons; a step line
names its tool, a run line lists the tools by name, colour alone marks
a failure, and a running run shows a gray spinner and the current
step's label. A
failed run stays collapsed, as the user decided. The elapsed time is
`ended - started` of the run's first and last step. Fold state is a
page-local `Map` keyed by `seq:index`; a reload loses it, which the
plan accepts.

**Records from koa to the page**, as server-sent events on `/events`, in
addition to the shared module's `reset`, `item` and `patch`:

```ts
type State = { type: "state"; working: boolean; since?: number; aborted: boolean;
  name: string; model?: string; thinking?: string; levels: string[];
  context?: { tokens: number | null; window: number; percent: number | null };
  cwd: string;
  queue: { steering: string[]; followUp: string[] };
  pi?: { exited: number } | { signal: string };
  dialogs: RpcExtensionUIRequest[] };                                // open dialog requests, oldest first
type Notice = { type: "notify"; message: string; level: "info" | "warning" | "error" };
type Editor = { type: "editor"; text: string };                      // set_editor_text
type Metrics = { type: "flush"; t: number };                          // with --metrics only
```

**Requests from the page to koa**, `POST` with a JSON body as a
string, never a `Blob` or `FormData` (docs/design-app.md, "Webview
panes"):

| Path | Body | RPC |
|---|---|---|
| `/prompt` | `{ text, mode: "prompt" \| "steer" \| "follow_up" }` | always `prompt`: plain while idle; while working with `streamingBehavior` `steer` (for `prompt` and `steer`) or `followUp`; never the `steer` and `follow_up` commands, because only `prompt` runs an extension command during streaming (pi's `rpc-commands.md`); the reply carries the disposition |
| `/abort` | `{}` | `abort` |
| `/queue/clear` | `{}` | `clear_queue`; the texts return in the response, and the page puts them in the composer |
| `/model` | `{ provider, modelId }` | `set_model`; `GET /models` lists `get_available_models` |
| `/thinking` | `{ level }` | `set_thinking_level`; the levels come in `state` |
| `/dialog` | `{ id, value? , confirmed?, cancelled? }` | `extension_ui_response` |
| `/editor/ack` | `{ id }` | none: clears `state.editor` when its id matches, after the page applied the text |
| `/pi/start` | `{}` | spawns pi again after an exit |
| `/quit` | `{}` | koa ends |
| `/metrics` | a batch of samples | written to the metrics file |

A failed RPC response answers 409 with pi's `error` text, and the
page keeps the composer's text. A body over 1 MiB answers 413; the
server refuses it first with `invalid` (`MAX_BODY`,
`ko_server/src/http.rs`).

**The status facts.** `working` runs from `agent_start` to
`agent_settled`; `since` is the `agent_start` time. The model and the
thinking level come from `get_state` at start, from the `set_model`
response and from `thinking_level_changed`. The context usage comes
from `get_session_stats` after each `turn_end`, `agent_settled` and
`compaction_end`; `contextUsage` is absent without a model and its
`tokens` and `percent` are `null` right after a compaction (pi's
`rpc-commands.md`). The queue is `queue_update`, which carries the
whole queue, so koa shows what ko-pi's page could not. `cwd` is the
`cwd` of the session header, the first line of `sessionFile`
(pi's `session-format.md`), else koa's own. The status bar shows no
git branch or dirty mark (the user, 2026-11-09), so koa runs no git.

**Extension UI.** A dialog request shows as a card above the composer
with its title, options or field and the `timeout` when present. The
open dialogs are part of `state`, because `state` is the one record
that a page gets again when it loads: a reload during a dialog shows
the dialog again. The page answers once; koa sends the
`extension_ui_response` and a new `state` without the request. A
second dialog while one is open queues behind it.
`notify` shows for 4 s in the status bar's flexible segment.
`setStatus` shows as a status segment under its key. `setWidget`,
`setTitle` and the other fire-and-forget methods are ignored.
`set_editor_text` replaces the composer's text.

## 4. The page

Several source files, one response. The sources are `page.html`,
`page.css` and the TypeScript modules under `share/koa/page/`;
esbuild bundles the modules with `marked` and `remend` into one
`page.js` (section 7). `markdown.ts` stays a module of its own so
that the tests import it under Node. A remote server costs one round
trip for each asset (docs/design-webview.md, "Remote servers and
runtimes"), so koa inlines the three built files into the one HTML
document that it serves for `/`: the style in a `<style>` and the
bundle in one `<script type="module">`, through the small assembly
function in `koa-assemble.ts` that the suite tests. koa does the
assembly for each request of `/`; a page load is one request. The server's CSP permits the inline script and style. The
page escapes every text that it did not write. marked produces an HTML string for one
block; the page parses it with a `DOMParser` into a detached document
and adopts the nodes, after the `html` tokens were escaped at the
lexer's output, so no model text reaches `innerHTML` unescaped.

**Theme.** Only `--ko-*` properties, with the mockup's `:root`
fallback for the browser. The fallback follows `prefers-color-scheme`
only when `window.ko` is absent; in Kido.app the properties that the
app sets win and a `ko-theme` event changes nothing in the page's
code, because every tone is a `color-mix` of the properties.

**Keys.** Kido's Command keys never reach the page (docs/design-app.md,
"Webview panes"), so the page defines none. Return sends, Shift-Return
inserts a newline, Option-Return queues a follow-up while the agent
works, Escape aborts and a second Escape clears the composer, as
NOTES.md says. Control-D in an empty composer quits koa, as in pi and a
shell; Control-C does nothing. The focused composer's border is
`--ko-focus`, the pane's focus colour. Command-F is WebKit's find. The composer's one button,
its placeholders and when its key hints show are NOTES.md, "The
composer"; the page follows it and the plan does not repeat it. The
composer floats over the transcript on a CSS glass (`backdrop-filter`);
a `ResizeObserver` on the dock keeps the transcript's bottom padding at
the dock's height, so a page pinned to the bottom keeps its last line
above the glass. WebKit's private `-apple-visual-effect` material is not
used: it needs the private `useSystemAppearance` preference, and
WebKit's snapshot does not show it, so no test could check it. The
composer takes the focus at start, on load, when pi's readiness makes it
available and when the page's window gets focus (the pane became first responder), each only while the
document has focus, because a focus while it has none shows no caret
later; unless a dialog or a picker is open or the
focus is in a control of the page (native or by its role), and after a
send, a picker or a dialog; a printable key typed outside a field goes to
the composer, while Space and Enter on a focused control keep their
action, and a selection in the transcript stays. A click on a run or step line toggles it. The page has no other shortcut.

**Streaming markdown.** `page/markdown.ts` is the block memoization,
after Streamdown's design, in plain DOM:

- It splits the text block's source into top-level blocks with
  marked's lexer and keeps, for each rendered block, its source text
  and its DOM node.
- A finished block, every block but the last, renders once: on a
  `patch` with a suffix it re-lexes the source, compares each block's
  source with the kept one from the start, and keeps every node whose
  source is equal. Only the blocks from the first difference on
  render again; in a stream that is the last block alone.
- The last block is the streaming tail. remend heals its source
  before marked parses it, so an open `**`, a half-written link or an
  unclosed fence render as their intended element and not as literal
  characters, and the tail renders again on each patch.
- Thus, the cost of a token is the size of the current paragraph,
  code block or table, not of the message. A `patch` that sends a
  block whole resets the memo of that block and renders it again.
- The caret of mockup section 2 is the last node of the streaming
  text block and goes with the item's `final`; at `final` the tail
  renders once more without remend.

marked's lexer runs over the whole source at each patch. That is a
tokenization, not a render, and it is linear; workload 2 of
section 5 measures it, and a source offset for the lexer is the
optimization if the measurement needs one.

**Scrolling.** The transcript follows the bottom while the user is
within 60 px of it and stops when the user scrolls up, as ko-pi's page
does. Older items load through `/items?before=N` when the top comes
into view, with the scroll anchored to the first item.

**The browser target.** `koa --browser` passes
`{ target: "browser" }` to the SDK; `show` opens the browser once. The
same server and page serve both targets. In the browser `window.ko`
is absent, the fallback theme applies and the WebSocket shim does not
exist; the page uses none.

## 5. The stress test

koa measures the webview path at its two ends. The server has no
metric route, and this plan adds none: the server's queues show as
back-pressure at the ends, and a route needs the top-level session's
approval.

**Measurements.**

- Flush to frame (Chrome) and flush to apply (Kido, whose off-screen
  windows run no `requestAnimationFrame`): with `--metrics FILE`, each flush that koa sends
  carries `{type:"flush", t}` with koa's `Date.now()`. The page, after
  it applies the records of one read, takes `performance.timeOrigin
  + performance.now()` in a `requestAnimationFrame` and sends the
  pairs in batches of 50 to `/metrics`. Both clocks are the host's
  wall clock. koa writes the samples as JSON lines; the runner prints
  p50, p95 and p99.
- Bytes: koa counts the bytes it wrote to each `/events` response and
  the `writableLength` high-water mark; the page counts the bytes it
  read. The difference over time is what sits in the bridge, the
  server and the app.
- WebContent memory: the runner sums the `rss` of every
  `com.apple.WebKit.WebContent` process (`ps -axo rss=,comm=`) before
  and after each workload. The count of processes is the count of
  live pages.
- Reconnects: koa counts `/events` opens, the `reset` and the
  cursor-based opens, and the responses that it ended at its 1 MiB
  output cap.
- The server's log (`DIR/log`) for view and client lifecycle, and a
  crash report or an `app.log` line for the app.

**The scripted pi.** `koa-fake-pi.ts` is a Node program that speaks
the RPC protocol on its stdin and stdout from a script: a JSON lines
file of commands to expect and events to emit, with gates (`wait` for
a command and `repeat` with a count and a delay in ms). It emits the exact
event shapes of pi's `json.md` and answers `get_state`,
`get_messages`, `get_session_stats` and the extension UI records. It
runs the tests and the stress workloads, so both are repeatable. The
stress runner also has a `--real-pi` mode for the same workloads
where a model answers; those runs are manual.

**Workloads**, each a script of the scripted pi, and what each is
expected to hit:

1. Long session: 2000 items, half with tool calls, loaded at start.
   Measures the time to the first paint, the `reset` size under the
   window caps (`MAX_WEBVIEW_WINDOW_ITEMS`, `_BYTES`) and the paging
   cost of `/items`. Expected limit: none; the caps do their work.
2. Fast tokens: 20 000 `text_delta` events of 20 bytes at 1 ms.
   Measures token to paint and the flush count (`flushMs` coalesces
   them). Expected: the 50 ms flush bounds the records; the DOM grows
   by one element per paragraph, not per token.
3. Large tool output: one tool result of 16 MiB and tool arguments of
   4 MiB. Expected: the result cap (`MAX_WEBVIEW_RESULT_BYTES`) and the
   args cap cut them in koa, so the page never sees them; koa's own
   memory shows the raw message once.
4. A large prompt: a 900 KiB and a 1.5 MiB composer text. Expected:
   the first passes; the second gets the server's `invalid` at
   `MAX_BODY` before koa sees it. The page shows the refusal.
5. Reloads and reconnects: 200 page reloads during a stream, and 200
   `/events` reconnects with the epoch. Measures the bytes of each
   catch-up and koa's subscriber count after the run (must be 1), and
   the WebContent memory before and after.
6. Many panes: 8 koa panes in one window, all streaming. Measures the
   WebContent count and memory and the token-to-paint of the focused
   pane. Expected: 8 processes of about 27 MB each
   (docs/design-webview.md, "Memory").
7. Hidden and shown: a streaming pane hidden past `app.webview.keep_hidden`
   and shown again. Expected: the released page loads again and gets
   a `reset`; the catch-up bytes and time are the measurement.
8. Theme changes: 50 appearance toggles during a stream. Expected: no
   reload, no `/events` reconnect; measures paint time after
   `ko-theme`.
9. Fetch concurrency: the page keeps one long fetch open, which takes
   one of the app's 6 in-flight slots for the page's lifetime. The
   workload fires 8 `/items` requests at once. Expected: 5 run, 3
   wait in arrival order, none fails; the page never exceeds 5 short
   requests at once by design. The server's `MAX_IN_FLIGHT` (16) is
   not reached from one page; workload 6 reaches it only with 3 pages
   of one pane, which the design excludes.
10. A slow page: a reader that stops for 10 s during workload 2.
    Expected: koa ends that response at its 1 MiB output cap, the
    page reconnects with its epoch and misses nothing; the other
    pages continue.
11. Body kinds: a `Blob` body and a `FormData` body from the page.
    Expected: koa receives an empty body and answers 400; the page
    sends strings only, so this is a guard, as `WebviewPaneTests` is.
12. A parent and N koa children, most hidden: one koa parent whose
    scripted pi spawns 6 children through `spawn_agent`, each a koa
    pane with its own scripted pi that streams; the parent's window
    is shown, the children's are hidden past `app.webview.keep_hidden`.
    Measures the WebContent count and memory with the children
    hidden, the catch-up of each child when it is shown, and the
    parent's token-to-paint while the children stream. Expected: the
    hidden children past the cap hold no WebContent process; the
    children's reports arrive as notices in the parent's transcript.

The `data` chunk cap (`EXEC_CHUNK`, 64 KiB) and the WebSocket close
rules of protocol.md section 16 are not reached: the bridge chunks
response bodies, and koa opens no WebSocket.

**What becomes an automated test.** The TypeScript suite runs with
the scripted pi and the fake ko, in under a second each:

- The feed: deltas to blocks, `*_end` replacement, `message_end`
  replacement, tool lifecycle with times, the rebuild after
  `compaction_end`.
- The protocol: `reset` with caps, cursor catch-up, `patch` suffixes,
  the cut at the output cap and the reconnect.
- The composer: `prompt` idle and `steer` while working, a refused
  `prompt` while streaming without a behaviour, `abort`,
  `clear_queue`, the dialog round trip, `set_editor_text`.
- The markdown: `page/markdown.ts` is a pure function from a source
  and the kept blocks to the per-block HTML strings and the reuse
  decisions; `page/page.ts` applies them to the DOM. The Node test
  drives `page/markdown.ts`; no DOM shim. For every prefix of a
  fixture that holds each GFM construct, the incremental render equals
  the full render of the same prefix (the memoization adds nothing and
  loses nothing); the healing cases (an open `**`, `_`, `` ` ``, `[`,
  a fence without its close) render as their intended element while
  streaming and as marked renders the final source at the end; an
  `html` token, block and inline, renders as escaped text; a finished
  block is marked "kept" after a patch, so its node is not touched.
- The status: `state` after `thinking_level_changed`, after
  `get_session_stats`, the queue, and the OSC 7501 and OSC 0 bytes on
  koa's stdout for each transition of section 2.
- The process: stdin close then `SIGTERM` through `signalPi` after
  `KOA_PI_EXIT_MS` (shortened), pi's exit shown in `state`, the
  restart.
- The shared module's pure parts.

Kido.app's visual suite gets `KoaWebviewTests`: koa with the scripted
pi on a fixture script that reaches the nine states of the mockup,
snapshotted in light and dark, windowed and at 60 columns. The
workloads 1 to 11 are the manual benchmark, `share/koa/stress/run.sh`,
which prints one table and writes the metrics file; they never run in
`make verify`.

## 6. Units of work

Each unit is one implementer. The manager writes the docs of each
unit. The order is fixed, because each unit builds on the one before.

1. **The status route.** Done on main (c6a1f242): `POST
   /panes/{id}/status`; ko-pi writes its job rows through it in every
   mode.
2. **The shared transcript module.** Done (d8a68f83).
3. **koa, the program.** Done (e86bd4ac).
4. **The page.** The page files after the mockup: the transcript with
   runs, steps and details, the composer as NOTES.md "The composer"
   describes it, the status bar with its segments and the narrow
   rules, the browser fallback theme; the markdown module over
   `marked` and `remend`, and the one-response assembly in
   `koa-assemble.ts`. Done, as vendored JavaScript; unit 9 moved it to
   the TypeScript pipeline of section 7. Tests: the assembly test and
   `KoaWebviewTests` in the app's visual suite with the fixture
   script; the manager compares each snapshot with `/tmp/koa-shots/`.
   The markdown tests of section 5 run under Node against the
   markdown module directly, which is why it is a module of its own.
5. **Dialogs, queue and pickers.** Thinking times: koa stamps `thinking_start`
   and `thinking_end` with its own clock into `started` and `ended` of
   a thinking block (the transcript module's block gets the two fields
   for thinking as it has them for tools), so a live run shows a
   thinking step's time; a replayed session shows none, because pi's
   messages carry no thinking times. koa also stamps a live assistant
   item's end at `message_end`, so an aborted run, whose pending tools
   have no times, shows its elapsed time. `/queue/clear`, `/model`,
   `/models`, `/thinking`, `/dialog`, `/editor/ack`, `/pi/start`, the
   dialog card, the queue under the composer, `notify`, `setStatus`
   and `set_editor_text`, and the exit view with "Start pi again".
   Tests: the composer and the restart tests of section 5.
   Also the child's harness: the `harness` flag in ko-pi, the argv of
   `createPane` by harness, `--browser` for the child of a browser
   parent, and koa's pass-through of `--runtime`. Tests: TS, the
   spawn fixture under `--harness koa` posts a `/panes` command whose
   argv is `[ko, "shell", "--", "koa", ...]` with the same tail as
   the ko-pi case of `ko-pi-spawn.test.ts:39`, with `--browser` when
   the parent has it, and `resume_from` and `fork` give `--session`
   and `--fork` after `koa`; a koa test that `--runtime x` reaches pi's
   argv. The e2e suite does not run koa (section 5), so a child's
   start in a real pane is the manual check of the stress workload 12.
6. **The stress runner.** Done: `share/koa/stress/run.sh` (page
   workloads in headless Chrome over the DevTools protocol) and `make
   -C app koa-stress` (Kido workloads in off-screen windows, which run
   no `requestAnimationFrame`, so they measure flush to apply). Its
   findings are the units 6a and 6b.
6a. **A page's memory.** Done: finished markdown blocks kept slices of
   every old version of the message; a page now holds about 16 MB of
   JS heap after W2 (was 117 MB) and +232 MiB of WebContent memory
   (was +423 MiB). The stress report fails a page above 32 MiB of
   retained JS heap or 320 MiB of WebContent memory.
6b. **Many streaming pages.** Done: Kido sets no limit on the number
   of webviews. On the screen, eight streaming panes finish in 24 s
   with a flush-to-frame p95 of 194 ms. Off the screen, pages lost the
   tail of the stream; 6d found the cause. Coalescing the chunks of one
   fetch changed nothing measurable and was dropped.
6c. **A visible page's memory.** Measure the physical footprint of a
   visible page (the stress report has no budget for it yet), find what
   WebKit keeps for a long transcript, and whether windowing old items
   lowers it. Off the screen, one W6 page of eight had a footprint of
   320 MiB against 88 to 113 MiB for the others.
6d. **The live feed is SSE.** Done: WebKit bug 322545 hid the tail of
   a `fetch` body (docs/design-webview.md, "The live channel");
   `/events` is now server-sent events, and the empty-line workaround
   is gone. Finished prose keeps no copy of its text, and the stress
   report measures the physical footprint of the test app's own
   WebContent processes.
6e. **The transport's faults.** Done: the app bounds its waiting
   fetches and the WebSocket shim's pending sends; response heads reach
   the page without framing headers, and a compressed response is
   refused (docs/protocol.md, "The serve stream"); a program's failed
   response ends only its own request.
7. **ko-pi's page goes.** Done: koa replaces it; ko-pi has no page,
   no webview flags and no use of the transcript module, whose shared
   text helpers moved to `share/pi/text.ts`.
8. **Docs.** `docs/design-koa.md` from this plan's decisions as built,
   the koa paragraph in `docs/design-webview.md` and AGENTS.md's
   layout, and this plan's deletion. The manager writes it; the
   implementers of units 6 and 7 report the facts.
9. **The page pipeline.** Section 7, "CodeMirror 6". `share/koa/page/`
   with `page.ts` and `markdown.ts` moved from the JavaScript files
   and typed, `page/tsconfig.json`, `share/koa/package.json` and its
   lockfile (esbuild, typescript 7, CodeMirror, marked, remend),
   `make koa-page` and `koa-watch`, `build`'s dependency and
   `KOA_FILES`, the assembler without its rewriter, `vendor/` gone,
   `scripts/test-ts.sh` (every `tsc` call through
   `share/koa/node_modules/.bin/tsc`, the `.pi/tests` call with
   `--ignoreConfig`, the page's `tsc -p`; `share/pi` keeps
   typescript 5 for openapi-typescript) and the lint globs. Tests: the assembly test over the bundle; the DOM
   tests over the stripped TypeScript; the markdown tests over
   `page/markdown.ts`; the app's suite unchanged. No CodeMirror in the
   composer yet: this unit changes no behaviour, and its check is that
   every existing snapshot is unchanged. The Homebrew formula's
   `depends_on "node" => :build` is a step of the next release in the
   tap, not of this unit.
10. **The composer on CodeMirror 6.** Section 7, "The editor".
   `page/composer.ts`, the page's use of it, the CSS, the deletions,
   `window.composer` for the app's tests. Tests: the DOM tests on the
   fake composer; the app's `KoaWebviewTests` on `window.composer`,
   with the existing snapshots unchanged (the manager compares the
   composer area pixel by pixel: the same border, padding, font, line
   height and six-line cap). No completion yet.
11. **Completion.** Section 7, "Completion". The design agent first
   mocks the popup; the unit follows the mockup. `share/pi/agents.ts`
   out of `ko-pi.ts` with its tests, `koa-complete.ts` and its tests,
   the `/complete` route and its program tests, `page/complete.ts`
   (the CM6 source, the keymap, the popup), the popup's CSS, the fake
   pi's `get_commands`, and three new snapshots in `KoaWebviewTests`
   (a `/` list, an `@` list with agents and files, an `@` list with
   files alone) in light and dark.
12. **Images in the transcript.** Section 8, "The image store and its
   route". The design agent first mocks the thumbnails of a user
   message and the image in an open `read` step; the unit follows the
   mockup. `share/pi/image.ts` (`imageInfo`) with its
   tests; koa's directory `koa-<pid>` and its removal at exit; the
   on-disk store, `ImageRef` and `GET /images/{id}` in
   `transcript.ts` (`transcript({ dir })`); `records.ts` gets
   `ImageRef`; the page renders the refs and creates a step's images
   at its first open; the fake pi gets the 1×1 PNG fixture. Tests:
   the transcript tests of section 8 (the fail-first one: a `read`
   result's image reaches the route), the program test over
   `get_messages` with images, and two snapshots in `KoaWebviewTests`
   (a user message with two thumbnails, an open `read` step with its
   image), light and dark. Deletes the `images` count and the page's
   "N images" line.
13. **Attachments.** Section 8, "A local session", "Attachments: drop
   and paste" and "Sending". The design agent first mocks the chips
   (an image chip, a file chip, a path chip, an uploading chip, a
   refused chip) above the field, windowed and narrow; the unit
   follows the mockup. The app: `isLocalProgram`, `window.ko.local`
   in the theme script, the native drop of `PaneView` for a local
   page with `__koDrop` and the `ko-drop` event, and its
   `WebviewPaneTests`. The page: `page/attach.ts` (the drop, paste
   and `ko-drop` handlers, the chips, the folder refusal line, the
   chunked upload), the
   composer's `drop` and `paste` handlers that take file drops before
   CodeMirror. koa: the attachment routes (upload, path, bytes,
   delete) in `koa.ts`, `/prompt` with `attachments`, the queue
   records with their attachments and the take-back, the fake pi's
   log of `images`, and the check with the real pi of an empty
   message with images. Tests: section 8, "Tests"; three snapshots in
   `KoaWebviewTests` (chips over the field, a sent message with a
   thumbnail and a path line, the queue with an attachment), light and
   dark. The manual check in Kido: a Finder drop of a PNG and of a
   text file onto a koa pane, local (the chips show the paths, and pi
   edits the original), a folder with a file (the refusal line and
   one chip) and over `ko HOST` (the chips show copies).
14. **Quick Look.** Section 8, "Quick Look". Before it starts, the
   `webview` branch is rebased onto `main`, because main has the
   terminal's Quick Look (62c6f1f5, "Shift-Command-click opens a
   kitty image in Quick Look") with `app/App/ImagePreview.swift` and
   `PrivateTemporaryDirectory`. The app side reuses them: the
   `koPreview` handler and `window.ko.preview` in
   `WebviewPaneView.swift` hand the fetched bytes to main's
   `ImagePreview` and its private temporary directory, not to a
   `kido-previews` writer of their own; the `QLPreviewPanel` data
   source and delegate on the pane's webview view, the 64 MiB stop
   and `WebviewPaneTests` for the validation and the file follow
   main's shapes, and the full redesign of that part (section 8,
   "Quick Look", "The app") happens after the rebase. koa: `GET
   /steps/{seq}/{block}/file` and the `Content-Disposition` of every
   served file. The page: a click or Space on an image or a chip, and
   ⇧⌘-click on the label of a `read`, `edit` or `write` step with a
   file (the ⇧⌘-hover look mocked first), call `window.ko.preview`
   when it exists, else the lightbox for an image and a new tab for a
   file; Escape closes the lightbox first. Tests: section 8, "Tests",
   and one snapshot in `KoaWebviewTests` (a `read` step's label under
   ⇧⌘-hover). The manager sends the handler's shape to the top-level
   session before the implementer writes it: it is a new page-to-app
   surface.
15. **Markdown in the composer.** Section 7, "Markdown in the
   composer". After unit 11, as its own unit: it has its own
   snapshots and demo, and unit 11 is in flight. `@codemirror/lang-markdown`
   and `@lezer/highlight` as direct dependencies, the language and
   the highlight style in `page/composer.ts`, the Shift-Return and
   Backspace bindings, the completion's code check in
   `page/complete.ts`, the CSS tokens. Tests: the DOM tests for the
   two keys (a list item continues on Shift-Return, an empty item
   loses its marker, Backspace deletes a marker, Return still sends),
   a unit test that the completion source answers null inside a code
   span and a fence, and two snapshots in `KoaWebviewTests` (a draft
   with a heading, emphasis, a code span, a link, a list and a quote;
   a fence), light and dark, which the manager checks against the
   rule of section 7, "Highlighting", and the user judges in a demo.

## 7. The composer: CodeMirror 6 and completion

Status: a design, 2026-11-09, for the user's request "transition to
CodeMirror 6 for the composer, and add completion of what pi
completes, with the same API if possible". The pi facts come from the
installed pi 1.5.0 (`/opt/homebrew/Cellar/pi-coding-agent/1.5.0/libexec/lib/node_modules/@earendil-works/`,
`pi-coding-agent/` and its nested `pi-coding-agent/node_modules/@earendil-works/pi-tui/`).
File and line references below are into that install.

### What pi completes

pi's interactive editor (`pi-tui/dist/components/editor.js`) asks one
provider and shows at most 5 rows (`editor.js:232`). Its triggers:

- `/` when the text before it on the first line is blank
  (`isAtStartOfMessage`, `editor.js:1850-1858`); a letter, digit,
  `.`, `-` or `_` typed in a `/` context asks again (`editor.js:1033-1046`).
- `@` at a token start (`buildTriggerPattern`, `editor.js:178`), with a
  debounce of 20 ms (`ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`,
  `editor.js:169`, `editor.js:1971-1978`); `/` commands have none.
- Tab with no menu forces a file completion of the token under the
  cursor (`forceFileAutocomplete`, `editor.js:1912-1920`).
- With the menu open: Escape closes it, ↑↓ move, Tab accepts, Enter
  accepts and, for a `/` command, falls through to submit
  (`editor.js:606-650`). A paste closes it (`editor.js:1057-1058`).

The provider is `CombinedAutocompleteProvider`
(`pi-tui/dist/autocomplete.js`, exported by `pi-tui/dist/index.d.ts:2`):

- `/name`: a fuzzy filter (`fuzzyFilter`, `pi-tui/dist/fuzzy.js`) over
  the command names, with `skill:` names matched by their bare name
  first and by the full name after (`autocomplete.js:225-254`).
- `/name arg`: the command's own `getArgumentCompletions` when it has
  one (`autocomplete.js:256-271`).
- `@token`: a fuzzy file search through `fd` from the session's cwd,
  or from the directory of a token with a `/`, with `--hidden
  --follow`, `.git` excluded, `.gitignore` honoured, 100 results
  scored and cut to 20, with the base directory's own entries first
  (`walkDirectoryWithFd`, `autocomplete.js:118-200`;
  `getFuzzyFileSuggestions`, `autocomplete.js:610-660`). Without
  `fd`, no `@` suggestions (`autocomplete.js:611-613`).
- A plain path token (`./`, `../`, `~/`, `/`, or a token with a `/`,
  or an empty token after a space): the directory's entries
  (`extractPathPrefix`, `autocomplete.js:420-440`;
  `getFileSuggestions`).
- `@"a b` quotes a path with spaces; an opening `(`, `[`, `{`, `<`
  or `` ` `` before the token is not part of it (`autocomplete.js:9-10,
  56-75`).
- Apply (`applyCompletion`, `autocomplete.js:272-350`): a command
  becomes `/name ` with a space; an `@` path gets a space unless it
  is a directory; a quoted path keeps its quotes.

The command list of the TUI (`pi-coding-agent/dist/modes/interactive/interactive-mode.js:468-546`)
is the built-ins (`settings`, `model`, `tree`, `thinking`,
`scoped-models`, `export`, `import`, `share`, `bug`, `copy`, `name`,
`session`, `changelog`, `hotkeys`, `fork`, `clone`, `trust`, `login`,
`logout`, `new`, `compact`, `resume`, `reload`, `quit`), the prompt
templates, the extension commands with their `getArgumentCompletions`,
and the skills as `skill:<name>` when the setting permits. `/model`,
`/thinking` and `/login` get argument completions from the session
(`interactive-mode.js:475-515`). `fd` is pi's managed tool at
`~/.pi/agent/bin/fd` (`$PI_CODING_AGENT_DIR/bin/fd`), else the `fd` on
PATH (`dist/utils/tools-manager.js:63-79`, `dist/config.js:510-516,
538-540`). ko-pi adds `@name` for the agents it knows, through
`ui.addAutocompleteProvider` (`share/pi/ko-pi.ts:3381-3410`).

### The RPC API: what koa can and cannot get

`get_commands` (`rpc-commands.md`, "get_commands";
`dist/modes/rpc/rpc-mode.js:540-567`) returns the extension commands,
the prompt templates and the skills, each with `name`, `description`,
`source` and `sourceInfo`. It has no `argumentHint` and no argument
completions: a `getArgumentCompletions` is a function in pi's process
and does not cross the wire. The built-ins are excluded on purpose:
they "are handled only in interactive mode and would not execute if
sent via `prompt`". `prompt` runs an extension command, and expands a
`/skill:name` or a `/template` before it sends or queues
(`rpc-commands.md`, "prompt"), so a completed command works as typed.
RPC mode ignores `addAutocompleteProvider` (`rpc-mode.js:194-195`),
so ko-pi's `@name` agents do not exist in koa's pi. RPC has no
completion command and no file search.

Thus "the same API" holds for the command names, through
`get_commands`, and for the apply rules, which koa copies. It does
not hold for the files, the argument completions or the agent names.

**koa cannot import pi's provider.** `pi-tui` is a nested dependency
of `pi-coding-agent` (`pi-coding-agent/node_modules/@earendil-works/pi-tui`),
and `pi-coding-agent`'s `exports` names only `.` and `./rpc-entry`
(`package.json:14-21`). koa's process has no resolution path to it:
the `pi` on PATH is Homebrew's bash wrapper over `libexec/bin/pi`,
not a symlink that `realpath` follows to the package, and pi's bun
single binary has no modules at all. `autocomplete.js` also imports
`utils.js`, which imports `get-east-asian-width`. A vendored copy of
`autocomplete.js` would carry that chain. So koa implements the rules
above itself, in `share/koa/koa-complete.ts` ("Completion" below),
and the `@` token rule, which ko-pi already copies from pi
(`share/pi/ko-pi.ts:832-847`, `atToken`), moves to the shared module
`share/koa/token.ts` ("Completion" below) so that ko-pi, koa and the
page share one copy.

### CodeMirror 6: the packages and their cost

The composer needs these ES modules, all MIT:

| Package | Version | File | Bytes |
|---|---|---|---|
| `@codemirror/state` | 6.7.6 | `dist/index.js` | 147,400 |
| `@codemirror/view` | 6.43.15 | `dist/index.js` | 495,588 |
| `@codemirror/commands` | 6.11.1 | `dist/index.js` | 84,624 |
| `@codemirror/autocomplete` | 6.20.4 | `dist/index.js` | 90,056 |
| `@codemirror/language` | 6.13.1 | `dist/index.js` | 97,134 |
| `@codemirror/streamparser` | 6.0.0 | `dist/index.js` | 5,120 |
| `@lezer/common` | 1.5.5 | `dist/index.js` | 84,581 |
| `@lezer/highlight` | 1.2.5 | `dist/index.js` | 29,921 |
| `style-mod` | 4.1.4 | `src/style-mod.js` | 7,042 |
| `w3c-keyname` | 2.2.8 | `index.js` | 2,630 |
| `crelt` | 1.0.7 | `index.js` | 951 |
| `@marijn/find-cluster-break` | 1.0.4 | `src/index.js` | 4,270 |
| `@lezer/lr` | 1.4.12 | `dist/index.js` | 73,047 (installed, not bundled) |

Total in the bundle: 1,049,317 bytes of module source. `commands` gives the history (⌘Z) and the
standard keymap; `autocomplete` gives the completion state, the
tooltip and its keymap; `language`, `streamparser`, `@lezer/common`
and `@lezer/highlight` are imports of `commands` and `autocomplete`
that the composer never calls. Not in the bundle: `@lezer/lr`, which
`@codemirror/language` declares as a dependency (so npm installs it
and the lockfile lists it) but does not import, so esbuild leaves it
out; and `@codemirror/lang-markdown` and `@lezer/markdown`, which
nothing depends on (the composer does not highlight). The direct
dependencies of `share/koa/package.json` are the four `@codemirror`
packages, `marked`, `remend`, `esbuild` and `typescript`; everything
else is transitive. A tree-shaken bundle of the same exports, made once with
esbuild 0.25.0 in a scratch directory, measures 623,637 bytes plain
and 296,935 bytes minified (96,922 gzipped); the bridge refuses a
compressed response (docs/protocol.md, "The serve stream"), so the
plain size is the wire size. The page is one response with
`Cache-Control: no-store` (docs/protocol.md), so the bytes travel at
each page load, once for each pane.

**Decision: a build pipeline for the page.** The user decided on
2026-11-09: neither vendored files nor a committed bundle. The page is
TypeScript, esbuild bundles it with CodeMirror, marked and remend from
npm, and TypeScript 7 type-checks it. The pipeline covers only the
page, the one browser code of `share/`: `koa.ts` and
`koa-complete.ts` stay TypeScript that Node runs as is (the shim's
`node koa.ts`), as `share/pi/ko-pi.ts` (pi loads it), `transcript.ts`,
`text.ts` and `share/webview/index.ts` do. Nothing else in `share/`
needs a bundle. The vendored `marked` and `remend` go: npm supplies
them, pinned in the same lockfile as CodeMirror.

**Verified facts (2026-11-09).** `typescript@7.0.2` is the `latest`
tag on npm (`7.1.0-beta` is `beta`); its binary is still `bin/tsc`,
its engine `node >=16.20.0`, and the compiler is native: the package
is 3.5 MB with one `optionalDependencies` entry for each platform
(`@typescript/typescript-darwin-arm64`, `-linux-x64`, ...). It
accepts `share/pi/tsconfig.json` unchanged (`tsc -p share/pi` exits
0 on this checkout), so `erasableSyntaxOnly`,
`allowImportingTsExtensions`, `paths`, `NodeNext` and `ES2024` hold.
One change: with files on the command line beside a `tsconfig.json`
it exits with `TS5112` and asks for `--ignoreConfig`, so the second
`tsc` call of `scripts/test-ts.sh` (the `.pi/tests` check) adds that
flag. `@typescript/native-preview` is the old preview name and is not
used. typescript@7.0.2 has no JavaScript API: its `lib/` holds only
`tsc.js`, `getExePath.js` and `version.cjs`, and
`require('typescript').factory` is undefined. openapi-typescript
(`share/pi/package.json`) builds and prints its output through that
API and names typescript ^5 as its peer, so `share/pi` keeps
typescript ^5.9.3 as openapi-typescript's library only; nothing runs
its `tsc`, and no npm override or `legacy-peer-deps` is used. `esbuild@0.28.2` is current; it installs one platform binary
through `optionalDependencies` (`@esbuild/darwin-arm64`,
`@esbuild/linux-x64`, ...). `module.stripTypeScriptTypes` exists in
Node 24 and 26 (the DOM tests below use it).

**Where the sources live.**

    share/koa/
      koa.ts, koa-complete.ts, koa-assemble.ts    Node, run as is
      records.ts                                the wire types ("The records module" below)
      page/                                     the page's sources
        page.ts                                 the script (was koa-page.js)
        markdown.ts                             the memoization (was koa-markdown.js)
        composer.ts                             the CodeMirror composer (unit 10)
        complete.ts                             the completion source and popup (unit 11)
        page.html, page.css
        tsconfig.json                           lib ES2024 + DOM, strict, noEmit, types []
      package.json, package-lock.json           esbuild, typescript, marked, remend; @codemirror/* from unit 10
      koa-*.test.ts, koa-fake-pi.ts, stress/
    build/ko/share/ko/koa/
      koa.ts, koa-complete.ts, koa-assemble.ts, records.ts, package.json
      page.html, page.css, page.js              built by esbuild, never committed

`share/koa/package.json` is the second npm manifest beside
`share/pi/package.json`, with `esbuild` and `typescript` pinned
exactly (`0.28.2`, `7.0.2`), `marked` and `remend` pinned exactly at
the versions the vendored files had (18.1.3, 1.4.0), and, from unit
10, `@codemirror/state`, `view`, `commands` and `autocomplete` at the
versions of the table; the transitive packages are in the lockfile.
The one type checker is this `typescript@7.0.2`; `share/pi`'s
typescript 5 stays for openapi-typescript ("Verified facts" above).
The `vendor/` directory and its README are gone.

**The Makefile targets.** The Makefile is the one place that runs
esbuild, as it is for cargo:

- `make koa-page`: `npm ci --silent` in `share/koa` when
  `node_modules` is older than the lockfile (the rule of
  `scripts/test-ts.sh:33-36`), then one esbuild command with three
  entry points: `share/koa/node_modules/.bin/esbuild
  share/koa/page/page.ts share/koa/page/page.css
  share/koa/page/page.html --bundle --format=esm --platform=browser
  --target=safari26 --loader:.html=copy
  --outdir=build/ko/share/ko/koa`. The script bundles to `page.js`,
  the CSS to `page.css` and the HTML is copied, so the three built
  files sit beside `koa.ts`. No minify (decided 2026-11-09): the
  bundle is readable in WebKit's inspector, and the bridge does not
  compress (above).
- `make build` depends on `koa-page` and copies `koa.ts`,
  `koa-complete.ts`, `koa-assemble.ts`, `records.ts` and
  `package.json` beside the built files; `KOA_FILES` names these.
  `build-linux`, `install`, `preview-pi` and Kido.app's
  `bundle-ko.py` copy from `build/ko` as today, so the one bundle
  reaches every layout. The bundle has no platform.
- `make koa-watch`: the same esbuild command with `--watch`, for
  development. Because the CSS and the HTML are entry points, a save
  of any of the three rebuilds it (esbuild 0.28.2 follows all three;
  tested 2026-11-09). The installed koa reads the built files beside
  itself at each request of `/` (section 1, "Build and install"), so
  a save, then ⌘R, shows the change. Without the watch, `make
  koa-page` then ⌘R.
- `make build` now needs Node 24 on PATH. `make verify` already
  needs it for the lint and ts stages; CI installs Node 24 on both
  runners (`.github/workflows/ci.yml:118-122`).

**Built, not committed.** The bundle is about 750 KB of generated
code (the page is 126,843 bytes bundled today; CodeMirror adds the
623,637 bytes measured above) that would change with every page edit,
and a committed generated file needs a lint check that rebuilds and
compares it, as `make schemas` does for `openapi.json`; a 750 KB diff
in every page commit is noise that no reviewer reads. The cost of
building is Node at build time. The Homebrew formula
(`~/Workspace/homebrew-tap/Formula/ko.rb`) already needs the network
for the toolchain and the cargo registry (its own comment says so,
and `HOMEBREW_CACHE` persists), so `npm ci` fits: the formula adds
`depends_on "node" => :build`, and `make install` builds the bundle as
`make build` does. The static Linux layout and Kido.app copy the
host's bundle. Recommendation: built by `make build`.

**The records module.** Since unit 7, `share/pi/transcript.ts` has
one consumer, koa, so its wire shapes are koa's contract with its
page. `share/koa/records.ts` is a type-only module with no runtime
code and no `node:` import: `Text`, `ToolState`, `Block`, `Item`,
`Assistant` and the feed records (`reset`, `item`, `patch`) move
there from `transcript.ts`, and `State`, `notify`, `editor` and
`flush` from `koa.ts`, as one discriminated union on `type` for the
`/events` payload. `transcript.ts` and `koa.ts` import it;
`page/page.ts` imports it with `import type`, which esbuild erases.
The Node types (`respond`, `handle`) stay in `transcript.ts`, so they
never reach the page's check. `records.ts` imports nothing from pi
either: an `import type` of a package pulls its whole declaration
graph, and pi's declarations reference `@types/node`, so Node's
globals would enter the page's check (`setTimeout` returning
`NodeJS.Timeout` was the symptom). A closed set stays a union, not a
string: `records.ts` declares `ThinkingLevel` (pi-agent-core's seven
names) and `DialogMethod` (`select`, `confirm`, `input`, `editor`)
as string-literal unions, and `koa.ts`, which sees pi's types, proves
at compile time that pi's `ThinkingLevel` and the `method` of pi's
`RpcExtensionUIRequest` equal them both ways (a two-way assignability
check on an erasable constant), so pi stays the one source and a pi
change fails the typecheck instead of drifting. The `Dialog` record
carries exactly the fields the page reads (`id`, `method`, `title`,
`message`, `options`, `placeholder`, `prefill`, `timeout`,
`expires`); `koa.ts` narrows pi's request to it once at its edge,
where it queues a dialog. The page's `tsconfig.json` has `types: []`
and no `paths`; the page redeclares no field.

**The assembler.** `koa-assemble.ts` reads `page.html`, `page.css`
and `page.js` beside `koa.ts` and inlines them as the `<style>` and
the one `<script type="module">`; its import and export rewriter goes,
because esbuild made one module scope. The per-request read stays, so
⌘R shows a new bundle. The assembly test shrinks to: the served
document holds the three files once and no `import` statement.

**Type checks.** `scripts/test-ts.sh` installs `share/koa`'s modules
under the same lockfile rule as `share/pi`'s, then runs
`share/koa/node_modules/.bin/tsc -p share/pi` (it covers
`share/koa/*.ts`, the Node side, through its `include`) and the
`.pi/tests` check with `--ignoreConfig`, then
`share/koa/node_modules/.bin/tsc -p share/koa/page`, whose
`tsconfig.json` has `lib: ["ES2024", "DOM", "DOM.Iterable"]`,
`types: []`, `strict`, `noUnusedLocals`, `noEmit`,
`erasableSyntaxOnly` and `moduleResolution: "bundler"`, so the
`@codemirror/*` types resolve from `share/koa/node_modules`. The
`share/pi` tsconfig excludes `../koa/page/`. `scripts/lint.sh` adds
`share/koa/page/*.ts` to its TypeScript globs (the stale-prose check
and the `as`/`any`/`!` hygiene check at `scripts/lint.sh:122-128`),
which the page's JavaScript escaped until now; `share/koa/node_modules`
is ignored as `share/pi/node_modules` is.

**CSP.** CodeMirror inserts one `<style>` element into
`document.head` through style-mod (`style-mod.js:100`); the server's
`style-src 'self' 'unsafe-inline'` permits it. CodeMirror has no
`eval` and no `new Function`. esbuild's ESM output has no module
system at run time. No CSP change.

### The editor

`share/koa/page/composer.ts` is one page module beside
`markdown.ts`, so that the page's tests run without a DOM: `page.ts`
imports `{ composer } from './composer.ts'`, and the DOM tests of
`koa-dom.test.ts`, which run the page's script in a `vm` context with
a fake document, supply a fake `composer` in that context instead of
the module. `composer(host, handlers)` mounts an `EditorView` in
the `<div id="prompt">` that replaces the `<textarea>` and returns
`{ text(), empty(), setText(text), insert(text), focus(),
hasFocus(), placeholder(text) }`. `handlers` are the page's:
`input(user)`, `send(mode)` and `quit()`; unit 11 adds `escape()`
for the completion's close, because until then Escape bubbles to the
document's handler unchanged. `input(user)` runs for every
transaction that changed the document, and `user` is true when the
transaction carries a `Transaction.userEvent` annotation (typing,
paste, delete, undo, redo, and the composer's own `insert()` and
Shift-Return newline, which annotate `input.type`) and false for
`setText()`. The page refreshes the composer on every call and
resets its second-Escape state only when `user` is true, so the
state survives an editor-ack or a take-back, and no caller of
`setText` can forget the refresh. `PromptMode` (`prompt`, `steer`,
`follow_up`) is one type in `records.ts` that the composer's `send`
handler, the page and koa share. The page keeps every rule of
"Keys" and the composer focus paragraph of section 4; this is how
each maps:

- **Return sends, Shift-Return inserts a newline, Option-Return
  queues a follow-up.** One `Prec.highest(keymap.of([...]))` in the
  editor: `Enter` → `send('prompt')`; `Shift-Enter` → insert `"\n"`;
  `Alt-Enter` → `send('follow_up')`. The page's `send` keeps its
  disposition rules, and a `prompt` while working stays a steer
  (section 3, `/prompt`).
- **Escape.** With the completion open, Escape closes it and nothing
  else (`closeCompletion`). Otherwise the editor's keymap does not
  bind it, and the document's `keydown` handler keeps the rule: the
  first Escape aborts, the second clears (`composer.setText('')`).
- **Control-D in an empty composer quits**: `Ctrl-d` in the keymap,
  which runs `quit()` only when `text() === ''` and otherwise returns
  false, so WebKit's own Control-D (delete forward) applies.
  **Control-C does nothing**: unbound; WebKit copies the selection.
- **The take-back of the queue** puts the texts into the composer
  with `setText`, cursor at the end, as today.
- **⌃↩ in a dialog's editor field** is the dialog card's own
  `<textarea>` and stays as it is; the composer is not involved.
- **The dock's `ResizeObserver`** stays: the editor grows with its
  text and `.cm-scroller { max-height: 9.6em; overflow: auto }`
  caps it at six lines, so the dock's height changes as before and
  the observer sets `--dock-h`. The `promptMaxHeight` constant and
  the `scrollHeight` measurement of `composer()` go.
- **Inert while pi starts.** `#field` keeps its `inert` attribute;
  the editor inside takes no focus and no key while it is set.
- **`focusComposer`** calls `focus()` under the same conditions;
  `document.activeElement === element('prompt')` becomes
  `composer.hasFocus()` (`EditorView.hasFocus`), because the focused
  element is CodeMirror's content element, a child of the host. The
  `isControl` test already treats `isContentEditable` as a control,
  so the editor counts as one.
- **Printable-key forwarding**: a printable key typed outside a
  field calls `focus()` then `insert(key)`, a `dispatch` that
  replaces the selection, in place of `setRangeText`; the
  `closest('input,textarea,select')` test gains
  `[contenteditable]`, which `isContentEditable` covers.
- **IME.** CodeMirror ignores key events during a composition that
  has changed the text (`ignoreDuringComposition`,
  `view/dist/index.js:4699-4712`, at `composing > 0`, with a
  Safari-specific window of 100 ms after `compositionend`). Between
  `compositionstart` and the first change, `composing` is 0 and a
  key still reaches the keymap, so each Enter binding returns false
  while `view.compositionStarted` (`composing >= 0`,
  `view/dist/index.js:7928`), and WebKit commits the candidate. Thus
  the Enter that commits a candidate never sends. The page's own
  `isComposing` checks on the composer go with the textarea; the
  dialog card and the picker keep theirs. A test cannot commit a
  candidate: that needs an active input method, and switching the
  input source would change the user's own; `setMarkedText` marks
  text without one, so WebKit's native editing still runs Return's
  default. The app's test asserts what the product needs (no send
  while `compositionStarted`), and the commit with a real input
  source is one manual check of the unit.
- **Paste** is CodeMirror's native paste: plain text, no change. A
  paste closes an open completion, as in pi.
- **The `--ko-focus` border and the glass** are CSS on `.field`;
  `:focus-within` sees the focus inside the editor. koa's theme sets
  `.cm-editor.cm-focused { outline: none }`, `.cm-editor` and
  `.cm-scroller` to no background and no padding, `.cm-content` to
  the prose font at `--ko-font-size`, line height 1.6, and
  `.cm-placeholder` to `--faint` (the mockup's values, NOTES.md "The
  composer"). The `textarea` rules of `page.css` go.
- **The placeholder** ("Message koa…", "Steer koa…") is CodeMirror's
  `placeholder()` in a `Compartment` that `composer()` reconfigures.
  The hint line and the status bar's working text derive from
  `state` at each refresh and each tick; nothing reads them back
  from the DOM.
- **The editor-ack path** is unchanged: `state.editor` →
  `setText(text)` → `POST /editor/ack`.
- **History**: `history()` and `historyKeymap` (⌘Z, ⇧⌘Z);
  `standardKeymap` for the cursor and selection keys, which WebKit's
  contenteditable does not supply once CodeMirror owns the content,
  with its Enter binding filtered out: `@codemirror/commands` binds
  Enter and Shift-Enter to `insertNewlineAndIndent`
  (`commands/dist/index.js:1762`), which would run when the
  composer's Enter handlers return false during a composition and
  would indent a Shift-Return newline. The composer's keymap is the
  only owner of the Enter variants, and Shift-Return inserts a plain
  newline, as the textarea did.
  Tab is not bound in the editor when no completion is open, so Tab
  leaves the field as NOTES.md "The model and thinking pickers"
  requires; pi's forced file completion on Tab is not offered (the
  user's decision of 2026-11-09).

**The seam for the tests.** The page exposes the composer object
itself as `window.composer`, typed as the `text`, `setText` and
`focus` subset; because `setText` reports through `input(false)`,
the page refreshes after an external `setText` too. The app's
`KoaWebviewTests` set and read text through it in place of
`#prompt.value` and the synthetic `input` event
(`app/VisualTests/KoaWebviewTests.swift:320-351`), and the
focus checks compare `document.activeElement` with
`document.querySelector('#prompt .cm-content')`. The stress runner's
page workloads do the same. The DOM tests (`koa-dom.test.ts`) keep
their fake document: they read `page/page.ts`, strip its types with
`module.stripTypeScriptTypes` (Node 24; the sources are erasable
syntax only, which the `tsconfig` enforces), strip the `import`
lines as today, and put a fake `composer` and the real `markdown`
(imported from `page/markdown.ts`) into the `vm` context. They never
run esbuild. The composer's own behaviour, which needs a real DOM, is
checked in the app's suite and by the stress runner's headless
Chrome. `koa-page.test.ts` imports `page/markdown.ts` directly, with
`marked` and `remend` from `share/koa/node_modules`.

### Completion

**Triggers and keys**, after pi: `/` with a blank before it on the
first line; `@` at a token start; a letter, digit, `.`, `-` or `_`
extends an open list. No forced completion and no plain-path
completion without `@` (decided 2026-11-09). ↑↓ move, Tab accepts,
Enter accepts and, for a command, then sends (pi's rule,
`editor.js:636-650`); for a file or an agent, Enter only accepts.
Escape closes.
CodeMirror's `autocompletion({ override: [source], defaultKeymap:
false, icons: false, activateOnTypingDelay: 20, maxRenderedOptions:
20 })` supplies the state and the tooltip; koa's keymap above binds
the keys, with `completionStatus(state) === 'active'` as the guard.
The source gets a `CompletionContext`. It decides first whether the
cursor is in a trigger context, with the same pure token rules that
koa uses: `share/koa/token.ts`, a module with no imports, holds
`atToken` (the agent token, moved from `ko-pi.ts`), `fileToken` (pi's
`extractAtPrefix` with its quotes and wrappers) and `slashToken` (the
`/` on the first line with blank before it). Without a token the
source returns null and sends nothing, as pi's editor asks its
provider only in a context (`editor.js:1030-1046`); with one it posts
the whole text and the cursor offset, and koa computes the prefix and
the options with the same functions, so the two sides agree on where
a token starts. The page filters the options not at all: pi asks its
provider again at each keystroke in a context, and so does koa.
`ko-pi.ts`, `koa-complete.ts` and `page/complete.ts` import
`token.ts` (`agents.ts` does not need it); the fuzzy matcher's
`matched` indices are koa's, and the page only turns them into
ranges; `KOA_FILES` installs it, and `ko-pi.ts` reaches it as
`../koa/token.ts` in both layouts, like `records.ts`.

**The route.** `POST /complete` with the body `{ text, pos }`,
access `alive` (file completion works while pi starts; the command
list is then empty). It answers `{ from, to, options }` with
`options`, each a `CompletionOption` of `records.ts`, a union on
`kind`: `command` with its `source` (pi's RPC names `extension`,
`prompt` and `skill`, a union in `records.ts` that `koa.ts` proves
equal to pi's `SlashCommandSource` at compile time, as it does for
`ThinkingLevel`; the page shows the word "template" for `prompt`),
`agent`, `file` and `directory`, each with `label`, `detail?`,
`insert`, `cursor?` (the caret's offset inside `insert`, default its
length; `insert.length - 1` for a quoted directory, pi's
`applyCompletion` rule) and, for commands and agents, `matched`
(the indices of the fuzzy-matched letters, so the page runs no second
matcher). The body and the reply are types of `records.ts`, because
the page reads them. `to` is `pos`, or `pos + 1` when the prefix is
quoted and a `"` follows the caret, which pi's apply consumes. A file
row shows the display path with a muted trailing `/` for a directory
and no detail, as the mockup draws it. `from` is the start of the prefix
that the option replaces and `to` is `pos`; `insert` is the text that
pi's apply rule produces for the prefix (`/name `, `@path `, `@dir/`,
the quotes), so the page inserts it and decides nothing. An empty
`options` closes the list. koa's routes are its own, keyed by the
exact URL (`share/koa/koa.ts:333, 413`); the body is JSON as every
other route's, under the 1 MiB limit.

**The source**, `share/koa/koa-complete.ts`, exports
`complete(text, pos, { cwd, commands, fd, signal })`:

- It takes the line of `pos` and the text before the cursor on it,
  as pi does (`autocomplete.js:213-214`).
- `/` on the first line: `commands()` is koa's `get_commands` through
  the RPC link, asked at each `/` request (a local round trip; no
  cache, so a `/reload` in pi shows at once), fuzzy-filtered with pi's
  rule (`skill:` by bare name first). Each `detail` is the
  description. No argument completion.
- `@token`: `atToken` and `fileToken` of `token.ts`, then `fd` from the token's base
  directory with pi's arguments, 100 results, pi's scoring, 20 rows,
  the base directory's entries first. One rule beyond pi's: the
  user's pattern comes after `--` in `fd`'s argv, so a quoted query
  such as `@"--help` is a pattern and never an option of `fd`; the
  test for it asks `@"--help.txt` and expects the pattern, not an
  empty result. `fd` is pi's: `~/.pi/agent/bin/fd`
  (`$PI_CODING_AGENT_DIR/bin/fd`), else `fd` on PATH, resolved once
  at start; without one, `@` returns no options and koa prints one
  line to its stderr at start. Tests name their `fd` through `KOA_FD`.
- A request closed by the page (`request.on('close')`) aborts the
  `signal`, and koa kills the `fd` child that it spawned for it, as
  pi does (`autocomplete.js:166-170`). The signal goes through koa's
  one signal function, `signalChild(child: ChildProcess, signal)` in
  `share/koa/koa-child.ts` (today `signalPi`, `koa.ts:30`), imported
  by `koa.ts` for pi's group and by `koa-complete.ts` for `fd`; the
  lint's permitted-site entry moves to that file, and `KOA_FILES`
  installs it. The route
  aborts through `response.once('close')`, attached before the
  search starts, because an `IncomingMessage`'s `close` is the end
  of the body, not the client's departure. It takes koa's own child
  record (decision
  8): the function grows from pi's record to any child that koa
  spawned, and `scripts/lint.sh`'s one permitted site stays one.
- `fuzzyFilter` is koa's copy of pi's rule (`pi-tui/dist/fuzzy.js`,
  125 lines), because the module is unreachable (above).

**`@name` agents.** ko-pi completes the agents of the pane's
neighbourhood in a TUI pi (`share/pi/ko-pi.ts:3381-3410`): for an `@`
token, `agentCompletionItems` (`ko-pi.ts:951-971`) over the rows of
its `discovery()` (`ko-pi.ts:1720-1831`), then pi's file items after
them under one prefix. The rows come from `ko api GET /layout`
(`listPanesResult`, `ko-pi.ts:262-271`; `parsePanes`, `ko-pi.ts:234-258`):
every live pane of the own session whose kind is a pi agent, with its
`pi.name` as the name, the pane's `parent` chain as the relationship
(parent, relative, peer, own child; `ko-pi.ts:1722-1744`), its root
state as the status and `pi.activity` as the activity. ko-pi adds
rows from its registry, the custom entries of its own pi session:
ended children and peers, and a child's name before its pane writes
`pi.name`. The completion offers the named rows that are not self
and not `other`, running or an ended peer (`ko-pi.ts:3393`), by name
prefix first and by word prefix second, at most 10
(`MAX_AGENT_COMPLETIONS`), each as `@name (session <id prefix>)`
with the shortest prefix of at least 8 characters that is unique
among the rows (`completionValue`, `ko-pi.ts:945-949`), and a
description of status, activity and parent. RPC mode drops the
provider (`rpc-mode.js:194-195`), so koa gets none of this for free.

koa computes the same from the same source: `koa-complete.ts` runs
`ko api GET /layout` as ko-pi does (`ko` from PATH, which in a pane
is the shim; the pane's identity headers come from `KO_PANE` and
`KO_PANE_TOKEN` in koa's environment, so the call is the pane's), and
builds the rows of the live panes with the shared code. The pure
parts move out of `ko-pi.ts` into a shared module `share/pi/agents.ts`
(installed beside `ko-pi.ts` as `transcript.ts` is; the Makefile and
`preview-pi` lists get it): `PaneInfo`, `parsePanes`, `placesOf`,
`piAgent`, `rootRecord`, `peerPanes`, the relationship computation of
`discovery` as a pure function `relationships(panes, me)`,
`agentCompletionItems` over the fields it reads (`id`, `name`,
`named`, `self`, `status`, `activity`, `parent`, `state`,
`relationship`), `completionValue`, `NAME_WORD_SEPARATORS`,
`MAX_AGENT_COMPLETIONS` and `MIN_ID_PREFIX`. ko-pi imports them and
keeps its registry merge; koa has no registry, so its rows are the
live named pi panes of its session only. What koa does not show:
ended children and peers, and a child in the seconds before its pane
writes `pi.name`. Its `ko api` call has ko-pi's 5 s deadline and the
same 1 s cache (`KO_AGENT_LIST_TTL_MS`, `ko-pi.ts:3390`), refreshed
in the background; a failed call gives no agent items and the files
still come. The agent items go first, the file items after, under
the `@token` prefix, as ko-pi merges them; each is
`kind: "agent"`, and Enter accepts without sending.

What the mention then does: nothing in koa or pi rewrites it. The
text `@impl (session 9702ddd1)` reaches the model as typed, and
ko-pi's tools keep the promise: `message_agent`'s `to`,
`read_report`'s `agent` and `stop_agent`'s `agent` each accept "an
@-mention from the prompt such as @impl (session 9702ddd1)"
(`ko-pi.ts:2868, 2914, 3104`), and `normalizeAddress`
(`ko-pi.ts:848-851`) takes the session id out of the parenthesis and
resolves it in ko-pi's snapshot (`resolveIn`, `ko-pi.ts:1855-1870`).
ko-pi runs unchanged inside koa's pi, so a completed mention in a koa
prompt addresses the same agent that it addresses in a TUI pane. One
difference: koa's id prefix is unique among koa's rows, which lack
the ended registry rows, so a prefix can match an ended child too;
`resolveIn` then answers "matches several", and the model asks or
uses a longer prefix. The 8-character floor makes this rare.

**Latency and cancellation.** CodeMirror starts a request 20 ms after
the last keystroke (`activateOnTypingDelay`) and aborts the previous
one through `CompletionContext.addEventListener('abort', ...)`, which
the source maps to the fetch's `AbortController`; the bridge turns an
aborted fetch into the request's `cancel` (docs/protocol.md, section
16), koa sees `close`, and `fd` dies. A `/` request is one RPC round
trip; an `@` request is one `fd` run, tens of milliseconds in a
repository of this size. The page shows nothing until the answer.

**The popup** is CodeMirror's tooltip above the field (the composer
is at the bottom, so it opens upward): `tooltips({ position:
"absolute", parent: field, tooltipSpace })` makes the field its
containing block; the space has the field's left and right, less the
9px row margin, and the viewport's top and bottom, so CodeMirror
clamps the x to the field and never hides or shrinks the popup for
want of room above the caret line inside the field; and one CSS
rule, `top: auto !important; bottom: calc(100% + 6px)`, pins it 6pt
above the field whatever line the caret is on, because CodeMirror
writes only inline `top` and `left`; `aboveCursor: true` keeps its
side class in agreement. No `TooltipView.offset` plugin. CodeMirror
appends the tooltip in a wrapper under `parent`, so the rule selects
the wrapper that holds the popup. One known limit, accepted: when a
token's start scrolls out of the six-line box while the list is open
(a wrapped `@path` longer than the box), CodeMirror would hide the
popup through a private sentinel that the rule overrides, so the
popup keeps its last x, inside the field, until the next keystroke;
the rule does not reach for that sentinel. The app's test asserts the
popup's bottom above the field's top and its left and right inside
the field. It is
restyled in `page/page.css`
through `--ko-*` tones after the mockup `app/design/koa/complete.html`
and its notes, NOTES.md "The completion popup": the card, its width
and anchor at the token's x, the 27pt rows with the current row on
`--well2`, 8 rows before the list scrolls, the footer, the label in
the terminal font, the muted detail, the kind tag for commands and
agents, the bold matched letters. The plan does not repeat the
mockup's values; the page follows it, and the three snapshots of
unit 11 are its states 1, 3 and 4.

**Tests.**

- `koa-complete.test.ts`, pure: the `/` filter and the `skill:`
  order, the `insert` of each kind, the `@"a b` quoting, the wrapper
  stripping, the token rule shared with ko-pi (one table for both),
  `@` over a temporary directory with a fake `fd` on `KOA_FD` that
  prints fixed lines (the base directory's entries first, 20 rows),
  and the agent rows from a `/layout` fixture through the fake `ko`
  (`share/pi/testdata/fake_ko`): the relationship of each pane,
  self and `other` excluded, the unique id prefix, agents before
  files.
- `agents.test.ts` beside `share/pi/agents.ts`: the moved pure
  functions keep their ko-pi tests; a test that reads them through
  ko-pi moves with them.
- `koa-program.test.ts`: `/complete` for `/fi` with the fake pi's
  `get_commands`; `/complete` for `@ko` with the fake `fd` and the
  fake `ko`'s layout; a closed request kills a fake `fd` that sleeps
  (the fake writes its pid to a file, and the test waits for its
  exit); `/complete` while pi starts answers files and agents and no
  commands.
- `koa-page.test.ts`: the assembly test over the built bundle; the
  ts stage runs after `make build`, so `build/ko/share/ko/koa/page.js`
  exists, and the test reads the page files from there.
- `koa-dom.test.ts`: the keys through the fake composer: Enter sends,
  Alt-Enter queues, Escape twice clears, Ctrl-D quits only when
  empty, the take-back's `setText`, the editor-ack's `setText`.
- `KoaWebviewTests`: two new snapshots, the `/` list and the `@`
  list; the existing composer snapshots unchanged.

**Deleted.** `share/koa/vendor/` and its README; the rewriter of
`koa-assemble.ts`; `koa-page.js`, `koa-markdown.js` and
`koa-markdown.d.ts` (now `page/page.ts` and `page/markdown.ts`); the
`<textarea id="prompt">` and its CSS; `promptMaxHeight` and the height
code in `composer()`; `setRangeText` and the `isComposing` checks on
the composer; every `element('prompt').value` read and write; the
pane, relationship and completion functions of `ko-pi.ts` that move
to `share/pi/agents.ts`.

### Markdown in the composer

Status: a design, 2026-11-09, for the user's request "for the
composer we should use CM6's markdown extensions". Unit 15.

**Verified facts.** `@codemirror/lang-markdown` 6.5.2 (MIT,
`sideEffects: false`) depends on `@lezer/markdown` 1.8.1 and on
`@codemirror/lang-html` 6.4.12, which brings `lang-css` 6.3.1,
`lang-javascript` 6.2.5, `@lezer/html` 1.3.13, `@lezer/css` 1.3.9
and `@lezer/javascript` 1.5.6. Its `markdown()` function makes an
HTML language at module level (`dist/index.js:402`, `htmlNoMatch`)
and uses it as the default `htmlTagLanguage` (`:407`), so a bundle
that calls `markdown()` carries the whole HTML, CSS and JavaScript
chain. Its named exports `markdownLanguage`,
`insertNewlineContinueMarkup` and `deleteMarkupBackward` do not
reference it, and esbuild drops it. Measured on the unit 10 and 11
exports as the base (esbuild 0.28.2, no minify):

| Bundle | Bytes | Over the base |
|---|---|---|
| base: state, view, commands, autocomplete | 624,621 | |
| + `markdown()` | 969,532 | 344,911; HTML, CSS and JavaScript parsers in |
| + `markdownLanguage`, the two commands, `syntaxHighlighting`, `HighlightStyle`, `tags` | 713,914 | 89,293; no HTML chain |
| + `@lezer/markdown` `parser` with `GFM` and `@codemirror/language`'s `Language` alone | 701,890 | 77,269; no continuation commands |

The third row is the design: `lang-markdown`'s named exports, never
`markdown()`. The fourth saves 12 KB and loses the two markup
commands, which live in `lang-markdown`; not worth a hand-written
`Language`. `markdownLanguage` is CommonMark plus GFM (tables, task
lists, strikethrough, autolinks), subscript, superscript and emoji
(`dist/index.js:62-74`); `commonmarkLanguage` is strict CommonMark.
The two commands return false outside markup
(`markdownLanguage.isActiveAt` checks in each), so a key bound to
them falls through to the next binding. The HTML, CSS and JavaScript
packages are installed and in the lockfile as transitive packages,
not bundled, under the `@lezer/lr` rule above. Direct dependencies
added to `share/koa/package.json`: `@codemirror/lang-markdown` 6.5.2
and `@lezer/highlight` 1.2.5 (for `tags`; already transitive).

**What "markdown extensions" means here.** The composer gets the
language, so the field understands what the user writes as the model
will read it, and three things that follow from it:

1. **Highlighting.** `syntaxHighlighting(HighlightStyle.define([...]))`
   over `@lezer/highlight`'s tags as the markdown parser emits them,
   with one plain rule, decided by the user on 2026-11-09 without a
   mockup; the user judges it in a demo. The composer keeps its type,
   the prose font at `--ko-font-size`, and the rule adds only this:
   the markup characters (`#`, `*`, `_`, `` ` ``, `>`, the list marks,
   the fence lines, the link brackets and the URL: the tags
   `processingInstruction`, `meta`, `url` and the fence's `meta`) in
   the muted tone; `strong` bold; `emphasis` italic; `strikethrough`
   struck; `monospace` (code spans and fenced code text) in
   `--ko-font-family` at the transcript's code size (`code{font:.92em
   ...}` in `page.css`), with no background; `heading` bold at the
   field's size, no larger type; link text in the fg colour; nothing
   else coloured. Every tone is a `--ko-*` property or a mix of them,
   as the rest of the page; no highlight colour of its own.
2. **Continuation.** `insertNewlineContinueMarkup` on Shift-Return:
   in a list item or a quote it inserts the newline with the next
   marker (`- `, `3. `, `> `, `- [ ] `), and on an empty item it
   removes the marker instead; outside markup it returns false and the
   plain newline of unit 10 follows in the same keymap. Return keeps
   its one meaning, send: a user who wants the next list item presses
   Shift-Return, as for any newline. `deleteMarkupBackward` on
   Backspace: at the start of an item's text it deletes the marker;
   elsewhere it returns false and `standardKeymap`'s `deleteCharBackward`
   runs. Both bindings go into the composer's `Prec.highest` keymap
   beside Enter, so the keymap of unit 10 stays the one owner of Enter
   and of its composition guard: `insertNewlineContinueMarkup` runs
   under the same `outsideComposition` wrapper as the Enter handlers.
   `markdownKeymap` itself is not used: it binds Enter.
3. **Fenced code.** No `codeLanguages`: a fence's text is `monospace`
   and nothing more. One parser per language costs 20 to 80 KB
   (`@lezer/javascript` alone is 80,799 bytes of source) and the
   composer is for prompts, not for code editing.

`commonmarkLanguage` versus `markdownLanguage`: `markdownLanguage`,
because the page renders GFM through marked and the field should
parse what the transcript shows (a table, a task list, `~~text~~`).

**Completion and the tree.** Completion does not need the tree: pi's
provider works on the line's text and so does koa's. With the
language present, the source adds one check: `syntaxTree(state)
.resolveInner(pos, -1)` and, when the node or an ancestor is
`InlineCode`, `FencedCode` or `CodeBlock` (the names of
`@lezer/markdown`), the source returns null, so a `/` or an `@` in a
code span or a fence is literal text. pi's TUI does not do this; it
is a small gain from the tree and costs three lines (open question 3).
The tree is incremental, so the check is cheap at every keystroke.

**What does not change.** The IME guard and the Enter ownership of
unit 10; the textarea-equivalent `input(user)` rule, because the
highlighting is a view decoration and not a document change; the
six-line cap and the `--ko-focus` border; the completion popup.
`page.css` gains the highlight tokens as classes of the
`HighlightStyle` (CodeMirror writes them into its one `<style>`
element; a `HighlightStyle.define` with `themeType` is not needed,
because every tone is a `--ko-*` property that follows the theme).

## 8. Images and attachments

Status: a design, 2026-11-09, for the user's requests "show images in
koa as pi's TUI shows them", "Quick Look on a click", "attach a
dropped image instead of inserting a path" and "handle other
attachments too". The pi facts come from the installed pi 1.5.0, with
file and line references into
`/opt/homebrew/Cellar/pi-coding-agent/1.5.0/libexec/lib/node_modules/@earendil-works/pi-coding-agent/`.
The design builds on section 7: the page is TypeScript under esbuild
(unit 9) and the composer is CodeMirror 6 (unit 10). The design agent
(`@kido-app-design`) mocks each visible part before its unit starts;
the values below are the starting point for the mockup, not the
design.

### Where images occur in pi's messages

- **A user message.** `UserMessage.content` is a string or
  `(TextContent | ImageContent)[]` (`docs/message-types.md:114`). It
  holds images only when the prompt carried `images`: the RPC
  commands `prompt`, `steer` and `follow_up`
  (`docs/rpc-commands.md:15-17, 54-59, 78-83`) and the CLI's `@file`
  arguments (`dist/cli/file-processor.js`). pi's own TUI never
  attaches an image: a pasted image becomes a temporary file
  `pi-clipboard-<uuid>.<ext>` in `os.tmpdir()`, and its path is
  inserted into the editor as text (`handleClipboardPaste`,
  `dist/modes/interactive/interactive-mode.js:2550-2578`); copied
  files insert their paths, one for each line. The model then reads
  the path with its `read` tool. A terminal drop pastes a path, and
  pi treats it as typed text.
- **A tool result.** `ToolResultMessage.content` is
  `(TextContent | ImageContent)[]` (`message-types.md:168`). `read`
  returns a text note `Read image file [<mime>]` and one image block
  for a file whose first bytes are PNG, JPEG, GIF, WebP or BMP
  (`dist/core/tools/read.js:80-109`; the sniff is
  `detectSupportedImageMimeType`, `dist/utils/mime.js:4-21`, which
  refuses an animated PNG). `processImage` converts BMP to PNG and
  resizes the image to the model's `inputLimits.images.resize`,
  default 4.5 MiB (`dist/utils/image-resize-core.js:9`). With a model
  whose `input` lacks `image`, the note adds "[Current model does not
  support images. The image will be omitted from this request.]" and
  the image block is still in the message (`read.js:40-45, 100-106`).
  Any tool, codemode's `image()` included, can return image blocks,
  and a `tool_execution_update` can carry them in a partial result.
- **A custom message** has the same content union
  (`message-types.md:228`); ko-pi's notices carry none today.
- **The session file** stores the images as base64 in the message
  (`docs/session-format.md:185`), so `get_messages` returns them and
  a resumed session has them.

pi's TUI shows the images of a tool result through the kitty
graphics protocol (`Image` of pi-tui, used in
`dist/modes/interactive/components/tool-execution.js`), under the
settings `showImages` and `imageWidthCells` (60 cells). That is what
the user sees in a terminal pane and not in koa.

**What koa does today.** `contentText` (`share/pi/text.ts`) keeps
only the text blocks, so a tool result's image vanishes and the
`read` step's detail says "1 lines". A user item carries
`images: number`, and the page appends "N images" to the text
(`page/page.ts`, the user item's render). Nothing of an image's bytes
leaves pi's process.

### The image store and its route

**Decision: the bytes go through a route, never through the feed.**
The feed's records are the page's memory: a `reset` window is 256 KiB
(`MAX_WEBVIEW_WINDOW_BYTES`), an `/events` response ends at 1 MiB of
buffered output, and the page's retained heap has a budget of 32 MiB
(unit 6a). One Retina screenshot is 2 to 6 MiB, 4/3 of that as base64
in JSON. A record that carried it would end the response of every
slow page and keep the bytes in the page's items map for the life of
the document. The page loads an image with `<img src="/images/<id>">`
and WebKit owns the decoded pixels, which it drops for an image that
is not in a document.

**Every image is kept, on disk.** The user decided on 2026-11-09: no
cap, no eviction, no placeholder, as pi keeps every image of the
session. koa's memory must not grow with the images, so the bytes
live in files, not in a `Map`: the transcript module decodes each
image block from base64 at conversion, in `applyMessage` for a user
message and in `flush` for a tool result, and writes it with
`writeFileSync` to `<dir>/images/<id>`, where `<dir>` is koa's
own directory `<os.tmpdir()>/koa-<pid>/` (0700, made at start,
removed at exit; the attachments below share it). The id is
`<seq>.<n>` for a user message's images and `<seq>.<block>.<n>` for a
tool result's, with `block` the tool block's index in the assistant
item and `n` the image's ordinal in that content list, so two blocks
of one item never share a name, a block's partial and final results
write the same ids (the final result replaces that block's images
file by file and removes the ids beyond its count), a block's images
are written again only when its result changed, and a rebuild gives
the same ids to the same images. The module keeps only the index `images: Map<string,
ImageRef & { path: string }>`, and the route streams the file with
`createReadStream`. `transcript({ dir })` takes the directory from
koa; the module's tests pass a temporary one. A record carries a
reference, not bytes:

```ts
type ImageRef = { id: string; revision: number; mimeType: string; bytes: number; width?: number; height?: number };
```

`revision` starts at 0 and increments when a write under the same id
finds different bytes: the module's index keeps a sha1 digest of the
decoded bytes for each id (computed once at conversion, so koa holds
no base64 between flushes) and compares before it writes. The page's
source is `/images/<id>?e=<epoch>&r=<revision>`, so a changed partial
result changes one `src` attribute and the browser fetches again,
while an unchanged ref leaves its node alone; the route ignores the
query. The epoch is in the URL because a rebuild resets the index
and its revisions, and WebKit's memory cache keys an image on its
URL whatever `Cache-Control` says: without it, a rebuilt `0.1` of
other bytes under the same id showed the old pixels in a new `<img>`. A
block's result "changed" when its text or any image digest changed.

in `records.ts`, on the user item as `images: ImageRef[]` (the count
goes) and on a tool block's result as `images: ImageRef[]` beside
`text` and `cut`. `width` and `height` come from the file's header
(PNG `IHDR`, JPEG `SOFn`, GIF, WebP `VP8`/`VP8L`/`VP8X`, BMP) in
`share/pi/image.ts`, a new module installed beside `transcript.ts`,
whose one export `imageInfo(bytes)` returns the type from the first
bytes (an allow-list: pi's set and pi's exclusions) with the
dimensions, or nothing; the attachment routes below are its second
caller. The sniffed type is the stored `mimeType`. A block whose
bytes match no header gets no type at all: the record carries no
`mimeType` and no size, the page reserves no space, and the route
serves it as `application/octet-stream`; the `mimeType` that pi
supplies with the block is never trusted or stored (the security
review of 2026-11-10, which supersedes the earlier fallback).

**The cost, stated.** Disk under `$TMPDIR` equal to the decoded size
of every image of the branch, written once at conversion and again
at each `rebuild` (`rebuild` removes `images/` and writes the branch
again from `get_messages`: a compaction or a session switch rewrites
every image; a 200 MiB session writes 200 MiB, well under a second
on the hosts koa runs on). koa's heap holds one image at a time
during a conversion, plus the `get_messages` response itself, which
koa already holds whole during a rebuild. `writeFileSync` on the
event loop is the one synchronous write; the alternative, a read of
the session file for each click, has no index from an item to a
message, so it is not used. A koa that dies by a signal leaves its
directory; the next koa does not reuse a pid's directory, and the
host's `$TMPDIR` cleaning removes it (the plan accepts this, as pi
accepts its `pi-clipboard-*` files).

**The route.** `GET /images/{id}` in `transcript.ts`'s `handle`
beside `/items`: `Content-Type` is the stored `mimeType`, else
`application/octet-stream`, `Content-Length` its size, the body the
file; an unknown id is 404, and a missing file (the directory was
cleaned under koa) is 410. Every `/images` response adds
`X-Content-Type-Options: nosniff` and its own
`Content-Security-Policy: sandbox; default-src 'none'`, so a served
file is never a document with the pane's origin; koa's CSP applies
beside the server's, which a program can make stricter
(protocol.md, "The serve stream"). Every proxy response carries
`Cache-Control: no-store` and the server's CSP (protocol.md, section
16). The CSP's `img-src 'self'
data:` permits the route and forbids `blob:`, so the page never uses
`createObjectURL`, also for a chip's thumbnail (below). `no-store`
means that a second `<img>` with the same URL fetches again, so the
page creates one `<img>` for each ref and reuses the node when it
renders the item again (the `slots` of its view, as the markdown
memo keeps its blocks). A step's detail is collapsed by default and a
hidden `<img>` with a `src` still loads, so the page creates a step's
images at the first open of the step, never before; a user message's
thumbnails are visible and load at once. Each `<img>` has
`width`/`height` attributes from the ref, so the bottom-following
scroll does not jump when the bytes arrive.

**The look** (the design agent mocks it): in a user message, a row of
thumbnails under the text, at most 160 px tall, with the hairline and
the radius of the mockup's cards; in a step's detail, the image after
the text note, at most the detail's width and 320 px tall, in its
aspect; the `read` step's line says `image 1200×800` in place of
`N lines` when the result has an image. Light and dark, windowed and
narrow.

### A local session

Two features below act on a path of the Mac: a dropped file whose
original pi should edit, and a Quick Look of a file by its path. Both
need one fact: koa and pi run on this Mac. The app has it from three
facts that it already holds for a pane, and the predicate is one
function, `WindowOwner.isLocalProgram(pane)`:

- `host == .local` (`WindowOwner.host`): the window's server is the
  Mac's own server, not a `ko HOST` remote.
- `pane.runtimeMark == nil` (`PaneView.runtimeMark`, set from the
  model's `place` in `WindowView.swift:420-428`): the pane is neither
  a pane of a runtime nor the host pane of a routed pi, whose tools
  run in the runtime (docs/design-runtimes.md, "Clients"); a path on
  the Mac means nothing to either.
- The pane shows a page (`webviewView != nil`). A page shows only
  when its program serves through the pane's own serve stream, so the
  program runs where the pane's server runs; an ssh foreground
  (`sshDestination`, `WindowOwner.swift:736-739`) cannot show a page
  from the far host, so it needs no check of its own.

The theme script gives the page the fact as `window.ko.local`, a
boolean, so the page knows which drop and which preview to expect; a
browser has no `window.ko` and is never local in this sense. The fact
changes only with the pane's row, and a change replaces the scripts
as a theme change does.

### Quick Look

**The channel today.** A page reaches the app only through the one
script message handler `koSocket`, the WebSocket shim
(`WebviewPaneView.swift:65, 346-399`), which checks `!stopped`, the
main frame, `allowed(frameInfo.request.url)` (the `ko:` scheme, the
view's pane as host, no port, no user), the document generation, and
the shape of each field. `window.ko` (the theme script,
`WebviewPaneView.swift:315-334`) has no method, and
docs/design-webview.md says why: the app is no message bus between a
page and ko. A preview is not that: it reaches neither the program
nor the server; it is a client action, as `app.webview.links` is.

**Everything Quick Look can show.** The user decided on 2026-11-09:
not images only. `QLPreviewPanel` decides what it shows from the
file's name and type (a PDF, text, source, an image, a video, an
archive's listing; an unknown type gets its icon), so the app checks
no type and caps only the size. What is clickable:

- An image of the transcript (a user message's thumbnail, a step's
  image).
- An attachment chip: a click on the chip's body previews it, × still
  removes it.
- The target of a `read`, `edit` or `write` step whose arguments
  name a file: ⇧⌘-click on the step's label (the user decided on
  2026-11-10, in place of ⌘-click, to match the terminal's gesture
  on main: "Shift-Command-click opens a kitty image in Quick Look",
  62c6f1f5). A plain click still folds, and the step has no control
  inside it. While ⇧ and ⌘ are both held over such a label, the
  cursor is the pointer and the label gets the underline of a link
  (`:hover` under a page-level class that the `keydown` and `keyup`
  of Shift and Meta toggle, set only while both are down); a label of
  any other step, or of a step whose `path` argument is missing,
  shows nothing and ⇧⌘-click folds as a click does. It shows the file as it is now on pi's host, not as the tool
  saw it.

**The message.** The document-start script adds one function,
`window.ko.preview(url)`, which posts `{ document, url }` to a second
handler, `koPreview`, with the generation that the socket shim
carries. The URL is always on the pane's own origin: one mechanism
serves a local and a remote session, and the app fetches no Mac path
itself (a local shortcut by path would be a second mechanism for the
same click, and Quick Look shows the copy under its real name,
below). koa serves three kinds of URL:

| URL | Serves | Refusals |
|---|---|---|
| `/images/{id}` | a transcript image | 404, 410 as above |
| `/attachments/{id}` | an attachment's bytes, also the chip's thumbnail | 404 |
| `/steps/{seq}/{block}/file` | the file that a `read`, `edit` or `write` step names: koa takes the `path` argument from its own item at `seq` and block index `block`, resolved against the session `cwd` when relative | 404 when no such step or the file is absent, 403 when not a regular readable file, 413 over 64 MiB |

Each answer carries `Content-Type` (the sniffed image type, else
`application/octet-stream`), `Content-Length` and
`Content-Disposition: inline; filename="<name>"` with the basename,
so Quick Look gets the name and the extension that it types the file
by. The page names a step, never a path: a route that took a path
would let the page read any file of pi's host, and in browser mode
that route sits on a localhost port. koa resolves the path from the
transcript's own item, writes nothing and follows no path outside a
regular file (`lstat`, then `S_IFREG`). The app's validation, in this order: `!stopped`, main
frame, `allowed(frameInfo.request.url)`, `document == generation`,
`url` parses and `allowed(url)` (a page previews only its own pane's
resources), the pane is the active pane of a key window, and no
preview of this pane is in flight; a message that fails any check is
dropped without a reply, as a socket message is. The app then fetches
the URL through `KoWebviewFetch`, the path of a page's own `fetch`
(it takes one of the 6 slots; a remote server answers through the
pane's serve stream, so a preview works over `ko HOST` and in a
runtime), stops the fetch and shows a notice when the body passes
64 MiB (Kido's per-file upload limit, docs/design-app.md,
"Uploads") or the status is not 200, writes the bytes to
`$TMPDIR/kido-previews/<pid>/<uuid>/<name>` (0700; `<name>` from
`Content-Disposition`, sanitized to a basename, else `preview` with
an extension from `Content-Type` through `UTType`) and opens
`QLPreviewPanel.shared()` with that one item. The webview pane view
answers `acceptsPreviewPanelControl` and is the panel's data source
and delegate (it is in the responder chain above the WKWebView). The
file goes when the panel ends its control, when the pane is disposed,
and at launch for a dead process's directory, under the lock rule of
`kido-promises`. A failed fetch shows a transient notice card ("Kido
could not preview the file"). The user closes the panel with Space or
Escape, as in Finder.

**The page.** A click on an image or a chip, Space and Enter on a
focused one (each has `tabIndex` 0 and `role="button"`), or ⇧⌘-click
on the label of a `read`, `edit` or `write` step with a file calls
`window.ko.preview(url)` when the function exists. Without it, the browser target, the page opens a lightbox
for an image: a fixed overlay on the dock's glass with the image at
its natural size, at most the viewport; a click or Escape closes it.
For a file in a browser the page opens the URL in a new tab, which a
browser shows or downloads itself; in Kido a page cannot open a tab
or download (docs/design-webview.md, "Non-goals"), which is why the
app has the preview. While the lightbox is open, Escape closes it and
nothing else, before the abort rule of section 4.

### Attachments: drop and paste

**What a drop delivers today.** In Kido, `PaneView` refuses a drag
while a page is shown (`webviewView == nil` in `draggingEntered`,
`app/App/PaneView.swift:1404-1406`), so the WKWebView, which
registers its own drag types, takes the drop, and the page gets the
standard `drop` event with `dataTransfer.files`: `File` objects with
the bytes, the name and the type, and no path (WebKit does not expose
the file URL of an outside drag). Kido's terminal-pane upload (the
drops directory, the pasted path; design-app.md, "Uploads") does not
apply to a webview pane. Without a handler, WebKit would navigate to
the dropped `file:` URL, which the navigation delegate refuses, so the
page calls `preventDefault` on `dragover` and `drop` of the document.
`@codemirror/view` reads a dropped file as text and inserts it, so the
composer's `domEventHandlers.drop` takes a drop with files before
CodeMirror sees it. A paste with `clipboardData.files` (a copied
image, a Finder copy) goes the same way; a text paste stays
CodeMirror's.

**Two drops, by the session.** The user decided on 2026-11-09: in a
local session pi gets the original path, so it edits the user's file
and not a copy. Remote sessions, runtimes and the browser keep the
bytes.

- **A local session: the native drop.** `PaneView.draggingEntered`
  returns `.copy` for a pane that shows a page when
  `isLocalProgram(pane)` holds, `acceptingInput` holds and the
  pasteboard has `.fileURL` items; for any other drag over a page it
  returns `[]`, so WebKit takes a drag without file URLs (a promise
  from Photos or Mail) and the page gets its bytes. `performDragOperation`
  reads the file URLs and validates them as the terminal upload does,
  through `Upload(files:copying: false)` (`app/App/Upload.swift:20-32`:
  regular files only, no packages, symlinks or aliases, at most 16),
  after it has set aside the folders: a URL whose `lstat` is a
  directory and that is not a package (`isPackageKey`) is a folder,
  and `Upload` never sees it. The app hands the page the file list
  and whether the drop had a folder, with
  `browser.evaluateJavaScript("window.__koDrop('<generation>', <json>)")`,
  where the document-start script defines `__koDrop` to check the
  generation and dispatch a `ko-drop` `CustomEvent` on `window` with
  `{ files: string[]; refused: boolean }`. The app hands the page
  nothing else: no bytes, no URL, no folder path, and a file path
  only after `Upload`'s checks; a failed check shows Kido's own upload
  notice and hands nothing of that drop. The page validates the event
  in turn (an array of strings, each absolute and without control
  characters, at most 16, and a boolean) and makes a path chip for
  each file. **A folder is not attached** (the user decided on
  2026-11-10, in place of the `@dir/` text of 2026-11-09): the
  terminal's upload refuses a folder, and the page does the same,
  local or not, with one muted line in the chip row, "Folders are not
  attached", shown for 4 s or until the next drop. The files of the
  same drop still become chips. In a session that is not local, the
  page names the folder itself: WebKit gives a `File` of size 0 for a
  directory, and `webkitGetAsEntry().isDirectory` names it. The drop
  position does not matter: the whole page is the composer's target.
- **Every other session: the bytes.** The page's `drop` and `paste`
  handlers read `dataTransfer.files` and upload them in chunks
  (below). When `window.ko.local` is true, the page ignores
  `dataTransfer.files` of a `drop`, because the app took the drag;
  it still reads a paste's files, which have no path on any host.

**The chips.** A dropped or pasted file becomes a chip above the
field, inside the dock (the design agent mocks them): a thumbnail
for an image (an `<img>` of `/attachments/{id}`), a document glyph
with the name and the size for a file, a progress state while its
bytes upload, a refused state with the reason (too big, too many, not
readable), and × to remove it. A path chip shows the file's name and
its directory muted, so the user sees that pi gets the original. At
most 16 attachments for one prompt. A chip's removal deletes koa's
copy; a path chip has none.

**The bytes to koa.** The proxy's request body is at most 1 MiB
(`MAX_BODY`, `ko_server/src/http.rs`; `ko_client/include/ko_client.h:658`),
and WebKit delivers a string or a `Uint8Array` body whole and a `Blob`
or `FormData` body empty (design-app.md, "Webview panes"). The page
thus sends chunks as `Uint8Array` bodies, never a `Blob`:

| Route | Body | Answer |
|---|---|---|
| `POST /attachments` | `{ name, type, size }` as JSON | `{ id }`; 413 over 64 MiB, 409 at 16 pending or 256 MiB pending |
| `POST /attachments` | `{ path }` as JSON (a local session) | `{ id, kind, mimeType?, width?, height?, size, name }` at once; 404 when absent, 403 when not a regular readable file, 413 over 64 MiB |
| `POST /attachments/{id}/{offset}` | the bytes from `offset`, at most 768 KiB | `{ received }`; 409 when `offset` is not the bytes received so far; after the last chunk `{ received, kind: "image" \| "file", mimeType?, width?, height? }` |
| `GET /attachments/{id}` | | the bytes with their type, name and length (the chip's thumbnail, Quick Look) |
| `POST /attachments/{id}/delete` | `{}` | `{}`; a copy is gone, a path is forgotten |

koa writes each uploaded attachment to
`<dir>/attachments/<id>/<name>` (the name with its path separators
and control characters replaced), in the directory of "The image
store" above, so koa holds no attachment in memory; the one exception
is the image that it encodes at send time. A path attachment is not
copied: koa `lstat`s it, refuses what is not a regular readable file,
and keeps the path. When the last chunk lands, or at once for a path,
`imageInfo` decides the kind and the dimensions from the first bytes
(pi's set and exclusions, never from the browser's `type` or the
extension). The directory goes at koa's exit; a
sent copy's file stays until then, because pi reads a file's path
later and the session's transcript names it. These routes have an id
in the path, so `koa.ts` matches them by prefix as `transcript.ts`
matches `/items`; they are `alive`, so a user can attach while pi
starts.

The page does not resize an image: pi converts and resizes it to the
model's limits itself (`processImage`), and a resize in the page would
change what the session keeps.

### Sending

`POST /prompt` takes `{ text, mode, attachments: string[] }`. koa
reads each attachment, a copy or a path alike:

- An image becomes one `ImageContent` of the RPC command: the file's
  bytes as base64 and the sniffed `mimeType`. `prompt` takes `images`
  in every mode, also with `streamingBehavior` (`session.prompt`
  passes them to the steer and follow-up queues,
  `dist/core/agent-session.js:1670-1711`), so a steer or follow-up
  carries its images. A dropped image in a local session is thus
  both: pi gets the pixels, and the path is not added, because pi's
  own `read` of the path would send the same pixels again.
- A file becomes a line of text: its path, one for each file, after
  the typed text, as pi's TUI pastes copied files
  (`interactive-mode.js:2552-2560`): the original path for a path
  attachment, the copy's path for an upload. The model reads it with
  `read`, as it reads a path that the user typed, and edits it in
  place. The text is otherwise as typed; `@` is not added.

`promptBody` accepts an empty `text` when `attachments` is not empty.
The user approved on 2026-11-09: the unit first checks with the real
pi whether `prompt` with `message: ""` and `images` starts a run; if
pi refuses, the page requires text for an images-only send and the
chip row says so.

**The rule for a path.** koa runs where pi runs: the local machine,
a remote server or a runtime. A path means something to pi only on
pi's host. In a local session the Mac is pi's host, so the dropped
file's own path goes to pi, and pi edits the original. Elsewhere the
page's machine is another one, WebKit gives no path, and koa's copy
on pi's host is the file that pi reads. A file that is already on
pi's host, in any session, is named with `@path` through the
completion of section 7.

**The queue.** `queue_update` carries texts only, and `clear_queue`
returns texts. koa keeps `{ text, attachments }` for each queued
prompt until a `queue_update` no longer lists its text, and
`/queue/clear` answers `{ steering: [{ text, attachments }], followUp:
[...] }` with the attachments that koa still holds, so a take-back
restores the chips with the texts. The queue list under the composer
shows a glyph and the count beside a text with attachments.

**The transcript.** pi stores the user message as
`[{ text }, ...images]` (`agent-session.js:1525`), so the user item
shows the thumbnails of "The image store" above. The page does not
guess attachment paths from the text's trailing lines; the chips of
sent attachments come with unit 13's data, and until then the text
shows as text.

### Limits

| Limit | Value | Where |
|---|---|---|
| One request body | 1 MiB | `MAX_BODY`, the server |
| One chunk | 768 KiB | the page |
| One attachment, upload or path | 64 MiB | koa, at `POST /attachments`; Kido's per-file upload limit |
| Attachments for one prompt, dropped paths included | 16 | koa, the page and `Upload.countLimit` |
| Pending uploads | 256 MiB | koa, on disk |
| Image store | no cap; disk under `$TMPDIR`, koa's heap flat | `transcript.ts` |
| A preview | 64 MiB, any type | the app |
| `/steps/{seq}/{block}/file` | 64 MiB, a regular readable file that a step names | koa |
| An image on the wire to pi | pi's `processImage` resizes to the model's limit, default 4.5 MiB | pi |

The feed's caps (`MAX_WEBVIEW_WINDOW_BYTES`, the 1 MiB output cap)
do not change: a record carries a reference of under 100 bytes for
each image.

### Tests

- `transcript.test.ts` (fail-first: today a `read` result's image
  vanishes and the user item has a count): a user message with two
  image blocks gives `images: [ref, ref]` with the ids `<seq>.0` and
  `<seq>.1`, the mime and the size of the 1×1 PNG fixture, and the
  files exist under the test's directory; `GET /images/<id>` answers
  the bytes with the mime and the length; an unknown id 404; a
  removed file 410; a `read` result with a text note and an image
  gives the block's `result.images`; `rebuild` gives the same ids and
  rewrites the files; `close` leaves the directory to koa.
- `image.test.ts` beside `share/pi/image.ts`: the sniff for each of
  pi's types and its refusals (an animated PNG, a JPEG with `f7`,
  junk); the size of a fixture of each type and `undefined` for a cut
  header.
- `koa-program.test.ts`: `get_messages` with images fills the route;
  the upload flow over the 1×1 PNG and a text file (create, two
  chunks, the completion's kind and size, `GET /attachments/{id}`
  returns the bytes with the name); a path attachment over a file of
  the test's directory answers its kind at once, a directory 403, a
  missing path 404; an offset out of order answers 409; a declared
  size over 64 MiB answers 413; a 17th pending attachment answers
  409; `/prompt` with an uploaded image, an uploaded file and a path
  file: the fake pi's log shows `images` with the fixture's base64
  and `image/png`, and the message ends with the copy's path and the
  original path on their own lines, and the copy has the bytes;
  `/prompt` with a path image sends `images` and adds no path line;
  `/attachments/{id}/delete` removes the copy;
  `/steps/{seq}/{block}/file` for a `read` step with a relative path
  answers the file against the session `cwd` with the name, 403 for
  a directory, 413 over a lowered limit, 404 for a block that is not
  a `read`, `edit` or `write` step and for a path the page passes as
  a query; a `Blob` body gives 400
  (workload 11's guard stays); a queued prompt's attachments come
  back from `/queue/clear`; the directory `koa-<pid>` is gone after
  `/quit`.
- `koa-dom.test.ts`: a `drop` with files makes chips and inserts no
  text; with `window.ko.local` true a `drop`'s files are ignored and a
  `ko-drop` event with two paths makes two path chips, and an event
  with a relative path or a control character makes none; a `paste`
  with files makes chips, a text paste does not; × removes a chip and
  posts the delete; Enter sends the ids; a `ko-drop` with `refused`
  shows the refusal line for 4 s and makes the chips of its files,
  the next drop clears the line, and a non-local drop with a
  directory entry shows the same line and uploads the files; a click
  on an image or a chip,
  or ⇧⌘-click on a `read` step's label, calls `window.ko.preview`
  with the URL when it exists, a ⇧⌘-click on a `bash` step folds and
  a ⌘-click without ⇧ on a `read` step folds; without it an image opens the lightbox and Escape closes
  it and does not abort; a step's `<img>` exists only after the first
  open.
- `WebviewPaneTests`: a `koPreview` message with another generation,
  a foreign URL or a non-key window is dropped; a valid one writes
  the fetched bytes to `kido-previews/<pid>/<uuid>/<name>` with the
  name of `Content-Disposition` and the data source answers that
  item; a body over a lowered cap writes no file and shows the
  notice; the file is gone after the pane is disposed. A drag over a
  webview pane: `draggingEntered` answers `.copy` only for a local
  pane with file URLs on the pasteboard (a fake `NSDraggingInfo` with
  a pasteboard; the test sets the owner's host and the pane's
  `runtimeMark`), and `performDragOperation` with a symlink hands the
  page nothing and shows the upload notice; with a regular file the
  page's `ko-drop` listener (set by the test through
  `evaluateJavaScript`) records the path.
- `KoaWebviewTests`: the snapshots of units 12 to 14.

**Deleted.** `images: number` on the user item and the "N images"
line of the page; the non-goal "Images in prompts and in results" of
this plan and the sentence "an image is a count" of
docs/design-webview.md, "koa's page" (the manager edits both when
unit 12 lands); `promptBody`'s refusal of an empty text when
attachments exist; the sentence of docs/design-webview.md that
`window.ko` has no method (the manager rewrites it: it has no method
that reaches the program or the server, and `preview` reaches the
app).

### Decided (user, 2026-11-09)

1. A local session's drop gives pi the original path; the app
   supplies it through the native drop above.
2. Quick Look shows everything it can; the app checks the size, not
   the type.
3. Every image is kept, on disk in koa's directory; no cap.
4. An images-only send may require text when pi refuses an empty
   message; the unit checks pi first.

5. A step's file opens in Quick Look on ⇧⌘-click of the step's label,
   the terminal's gesture on main (changed from ⌘-click on
   2026-11-10); a plain click folds, and the hover affordance shows
   while ⇧ and ⌘ are both held.
6. A dropped folder is not attached and inserts no text (changed on
   2026-11-10 from the `@dir/` insertion): local or not, the chip row
   shows "Folders are not attached" for 4 s or until the next drop,
   and the files of the same drop still become chips.

No open questions.

## Open questions for the user

The user decided every question of sections 1 to 6 and of
`app/design/koa/NOTES.md` on 2026-11-08. Section 7 has these:

Decided on 2026-11-09: a build pipeline for the page, not vendored
files or a committed bundle (question 1 as first asked); koa copies
pi's `@` file rules; built-in slash commands come later; `@name`
agents are koa's own computation from `ko api`, as section 7 now
says; Tab accepts and otherwise leaves the field; Enter on a command
accepts and sends, on a file or an agent accepts; the popup gets a
mockup before unit 11; koa's one signal function takes any own child.
Also decided on 2026-11-09: the bundle is built by `make build`, not
committed (section 7, "Built, not committed"), so `make build` needs
Node 24; the Homebrew formula's `depends_on "node" => :build` and its
`npm ci` are a release step of the tap at the next release, not a
change in this repository; and the bundle is not minified.

Section 7, "Markdown in the composer", decided on 2026-11-09: the
named exports of `lang-markdown`, never `markdown()`; Shift-Return
continues a list or a quote and ends an empty item, Return stays
send, Backspace at an item's start deletes the marker; no `/` or `@`
completion inside a code span or a fence; fences stay plain
monospace; no mockup, the highlighting follows the plain rule of
"Highlighting" and the user judges it in a demo.

None open.
