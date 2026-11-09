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
3. Markdown renders with vendored `marked` and `remend` in
   `share/koa/vendor/`, under a block memoization that koa's page
   writes itself in plain DOM. The user decided this on 2026-11-08.
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
7. The page talks to koa over `fetch` only: one long `GET /events`
   and short requests. No WebSocket.
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
      koa-page.html       the page's document
      koa-page.css        its style
      koa-page.js         its script, an ES module
      koa-markdown.js     the block memoization over marked and remend
      koa-assemble.ts     the one HTML response: the page with its script,
                          koa-markdown.js and vendor/ inlined
      vendor/             marked and remend as ES modules, with their
                          license files and README.md ("Vendored code")
      koa-fake-pi.ts      the scripted pi of the tests and the stress runs
      koa-*.test.ts       the suite
      stress/             the stress workloads and the runner (section 5)
    share/pi/transcript.ts   the shared transcript module (decision 5)
    share/ko/bin/koa      the shim

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
runtimes and containers use. `build` copies `share/koa/koa.ts`, the
four page files and `share/koa/vendor/` to `share/ko/koa/`, and
`share/pi/transcript.ts` beside `ko-pi.ts`. `preview-pi` gets
`koa/koa.ts`, the four page files, `koa/vendor` and
`pi/transcript.ts`. The tests and the stress files are not installed.
koa reads the page files and the vendored modules once at start and
serves one HTML response for `/` (section 4); any other path but its
routes is 404.

**Checks.** `share/pi/tsconfig.json` includes `../koa/*.ts` and maps
`@earendil-works/pi-coding-agent` to `share/pi/node_modules` in its
`paths`, so koa's type-only imports resolve from `share/koa/`.
`scripts/test-ts.sh` runs `koa-*.test.ts` with the ko-pi suite.
`scripts/lint.sh` adds `share/koa/*.ts` to its TypeScript globs: the
stale-prose check, the `as`/`any`/`!` hygiene check and the
`process.kill` rule, whose one permitted site becomes `signalJob` in
`ko-pi.ts` and `signalPi` in `koa.ts`. `share/koa/vendor/` is excluded
from every lint check and from `tsconfig.json`: vendored code is not
ours to edit, and a change to it goes through a vendored update
(below).

**Dependencies.** In the page, the two vendored modules ("Markdown"
below). In `koa.ts`, none at run time. Type-only imports:
`RpcCommand`, `RpcResponse`, `JsonAgentSessionEvent`,
`RpcExtensionUIRequest` and `RpcExtensionUIResponse` from
`@earendil-works/pi-coding-agent`, and `AgentMessage` for the shared
module. The suite type-checks them through `share/pi/node_modules`.

**Markdown.** The page renders GitHub-flavoured markdown with two
vendored libraries, both without dependencies: `marked` (MIT), the
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
libraries are the only runtime dependencies of koa, and the page is
the only user; `koa.ts` imports neither.

**Vendored code.** `share/koa/vendor/README.md` names, for each
library, the pinned version, the source URL of the file that was
copied (the npm tarball or the git tag), its license file beside it,
and the one command that fetches it again. The files are the
libraries' own ES module builds, copied byte for byte, so a `diff`
against the source at the pinned version is empty. A vendored update
is one commit that changes the files, the README's version and URL
and, when the build changed, the memoization tests of section 5. No
local edit of a vendored file is permitted; a needed change goes
upstream or into `koa-markdown.js`.

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
page. The pane's hangup rules are ko's (docs/design.md, "Window
lifecycle").

**pi exits by itself.** koa keeps the pane: the transcript stays, the
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
module; its `webview*` state variables go. The ko-pi tests
(`ko-pi-webview.test.ts`) keep their assertions; the module gets unit
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
to 6: the marks `$` bash, `✎` edit, `◇` read, `∴` thinking, and the
tool name with its first argument for any other tool; the result at
the right. A run's summary names the current step while a step runs,
the counts by kind when done, the failure count when a tool result
has `isError`, and "aborted" when the item's `stop` is `aborted`. A
failed run stays collapsed, as the user decided. The elapsed time is
`ended - started` of the run's first and last step. Fold state is a
page-local `Map` keyed by `seq:index`; a reload loses it, which the
plan accepts.

**Records from koa to the page**, as JSON lines on `/events`, in
addition to the shared module's `reset`, `item` and `patch`:

```ts
type State = { type: "state"; working: boolean; since?: number; aborted: boolean;
  name: string; model?: string; thinking?: string; levels: string[];
  context?: { tokens: number | null; window: number; percent: number | null };
  cwd: string; branch?: string; dirty?: boolean;
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
(pi's `session-format.md`), else koa's own. The branch and the dirty
flag come from `git symbolic-ref --short HEAD` and `git status
--porcelain --untracked-files=no` in that directory, run with
asynchronous `spawn` at start and after each `agent_settled`, with a
deadline of 2 s; a failure leaves them absent.

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

Several source files, one response. The sources are the document,
its style, its script, `koa-markdown.js` and the two vendored
modules, kept as separate files so that the tests import
`koa-markdown.js` and the vendored files stay byte-for-byte copies.
A remote server costs one round trip for each asset
(docs/design-webview.md, "Remote servers and runtimes"), so koa
inlines them into the one HTML document that it serves for `/`: the
style in a `<style>`, the modules and the script in `<script
type="module">` elements, in dependency order, with their `import`
and `export` statements rewritten to one module scope by a small
assembly function in `koa-assemble.ts` that the suite tests. koa does the
assembly once at start and keeps the result; a page load is one
request. The server's CSP permits the inline script and style. The
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
NOTES.md says. Command-F is WebKit's find. The composer's one button,
its placeholders and when its key hints show are NOTES.md, "The
composer"; the page follows it and the plan does not repeat it. The
composer has focus at load and after a send; a click on a run or step
line toggles it. The page has no other shortcut.

**Streaming markdown.** `koa-markdown.js` is the block memoization,
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
- The markdown: `koa-markdown.js` is a pure function from a source
  and the kept blocks to the per-block HTML strings and the reuse
  decisions; `koa-page.js` applies them to the DOM. The Node test
  drives `koa-markdown.js`; no DOM shim. For every prefix of a
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
   rules, the browser fallback theme; `koa-markdown.js` over the
   vendored `marked` and `remend`, with `vendor/README.md` and the
   license files, and the one-response assembly in `koa-assemble.ts`. Tests:
   the assembly test (the served document holds each source once, in
   order, with no `import` left) and
   `KoaWebviewTests` in the app's visual suite with the fixture
   script; the manager compares each snapshot with `/tmp/koa-shots/`.
   The markdown tests of section 5 run under Node against
   `koa-markdown.js` directly, which is why it is a module of its own
   and not part of the page's script.
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
6a. **A page's memory.** One koa page costs about 370 MiB of
   WebContent memory in Kido (W2: +377 MiB; W12's parent: +168 MiB)
   and a 136 to 168 MB JS heap in Chrome (W2, W5, W8), against the
   27 MB of an empty view. Find what the page keeps (the item views,
   the markdown memo, the records, the samples) with a heap snapshot
   in Chrome, bound it, and give the stress table a memory budget per
   page that fails above it.
6b. **Many streaming pages.** W6 (eight panes that stream at once)
   fails: one page does not finish in 90 s, flush to apply reaches a
   p95 of 27 s, and WebKit logs `Too many messages (129) in the queue`
   of `WebPage_URLSchemeTaskDidReceiveData` for seven renderers. The
   scheme handler hands every small chunk to WebKit as its own
   `didReceive`; coalesce the chunks of one turn of the main queue
   into one call (and check that `testWebviewStreamingLastRecord`
   still holds), then measure W6 again.
7. **ko-pi's page goes.** The user decided on 2026-11-08 that koa
   replaces ko-pi's page when koa is stable: its visual tests and its
   stress runs pass, and every finding of unit 6 is fixed. Until then
   ko-pi's page is the reference that koa must match in behaviour. The
   unit deletes from ko-pi: the flags `--webview` and
   `--webview-browser`, `share/pi/ko-pi-page.html`, the page server
   (`webviewStart`, `webviewStop`, `webviewHandle`, the
   `globalThis.__koPiExtensionWebview*` hand-over), the wish and
   dialog tracking (`ui_prompt_start`, `ui_prompt_end`, `/terminal`),
   and every part of the shared transcript module that only ko-pi
   used; what koa uses stays in `share/pi/transcript.ts`. It deletes
   their tests, `ko-pi-webview.test.ts` (the SDK tests,
   `ko-pi-webview-sdk.test.ts`, stay), the fake ko's `ko webview`
   parts that no test uses any more, `KoPiWebviewTests` and its
   snapshots, and the Makefile's `ko-pi-page.html` lines in `build`
   and `preview-pi`. The docs change with it: design-webview.md
   "pi's page" becomes koa's page, design.md "The pi extension,
   ko-pi" loses the `--webview` interface, and AGENTS.md's mentions of
   `ko-pi-page.html` and the webview flags go. Tests: the ko-pi suite
   passes without the deleted tests; `scripts/lint.sh` finds no
   reference to the deleted files.
8. **Docs.** `docs/design-koa.md` from this plan's decisions as built,
   the koa paragraph in `docs/design-webview.md` and AGENTS.md's
   layout, and this plan's deletion. The manager writes it; the
   implementers of units 6 and 7 report the facts.

## Open questions for the user

None. The user decided every question of this plan and of
`app/design/koa/NOTES.md` on 2026-11-08; each decision is recorded
where it applies.
