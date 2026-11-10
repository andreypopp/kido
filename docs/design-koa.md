# koa, the webview harness for pi

koa is a program for a Kido pane. It starts pi in RPC mode as its
child, owns pi's stdin and stdout, and shows the session as an HTML
page in the pane through the webview feature. In development the same
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
- [design.md](design.md), "The pi extension, ko-pi", and
  [design-subagents.md](design-subagents.md): ko-pi, which runs
  unchanged inside koa's pi.
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
   agent, `ko prompt` and `message_agent` reach it, and ko-pi's agent
   tools work in it.
3. **The webview path under load, measured.** Long sessions, fast
   token streams, large tool output, reloads and reconnects, many
   panes, hidden pages and theme changes.
4. **Small.** TypeScript that Node 24 runs as is, with no runtime
   dependency in the program; the page's npm packages are bundled at
   build time.

Non-goals:

- A terminal UI. In a client that shows no webviews, koa prints one
  line that says so and keeps serving; the page shows when a client
  with webviews connects. Outside a pane, koa runs only with
  `--browser`.
- Session trees, `/tree`, forks and clones from the page, and pi's
  other built-in slash commands except `/name`
  ([plans/koa.md](../plans/koa.md)).

## Where koa lives

`share/koa/` holds the program (`koa.ts` and its `koa-*.ts` modules),
the page's sources (`page/`), the scripted pi of the tests
(`koa-fake-pi.ts`), the suite (`koa-*.test.ts`) and the stress runner
(`stress/`). `share/pi/` holds only what ko-pi and koa share at run
time: `records.ts` (the facts that ko-pi writes into its messages'
details, with their guards), `agents.ts`, `token.ts` (the token
grammar: ko-pi's `@` agent token runs through the file token rules)
and `text.ts`. The records of koa and its page are
`share/koa/koa-records.ts`. AGENTS.md, "Layout", names each file.

`make build` installs the program and the built page in
`share/ko/koa/` and the shim `share/ko/bin/koa`. The installed layout
keeps `share/koa/` and `share/pi/` as siblings (`koa/` and `pi/`),
so koa's relative imports of `../pi/` and of `../webview/` resolve
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
runs `koa.ts` as is, as pi loads `ko-pi.ts`.

**One response for the page.** A remote server costs one round trip
for each asset, so koa inlines `page.html`, `page.css` and `page.js`
into one document for `/` (`koa-assemble.ts`). koa reads the three
files again for each page load, so a rebuild and ⌘R show a change.

**Type checks.** TypeScript 7 from `share/koa/package.json` is the one
type checker of the repository. `share/pi/tsconfig.json` checks the
Node side, koa included; `share/koa/page/tsconfig.json` checks the
page against the DOM alone. The record modules import nothing from
pi, because pi's declarations pull Node's globals into the page's
check. Where `koa-records.ts` names a closed set that pi also defines
(the thinking levels, the dialog methods, the command sources),
`koa.ts` proves at compile time that the two sets are equal, so pi
stays the source and a change in pi fails the check. The relations
of `records.ts` derive from ko's schema (`ko-api.d.ts`).

## The process

**Two processes in the pane.** koa is the pane's program: its stdout
is the pane's tty, so the SDK's `show` and `hide` and koa's own OSC
7501 and OSC 0 reach the pane. pi is koa's child in its own process
group, with its three streams piped; pi's stdout is the RPC stream.

**The spawn.** koa runs `pi --mode rpc --extension
<share>/pi/ko-pi.ts --harness koa` (`koa-browser` with `--browser`)
and passes every argument that it does not own to pi unchanged, so
pi's session and model flags and ko-pi's `--runtime` work as in a TUI
pane. koa adds nothing to pi's environment: the pane identity reaches
ko-pi as it does in a TUI pane. `koa --help` lists koa's own flags.

**`--resume` picks before the webview.** pi runs its session picker
for `--resume` (`-r`) in every mode, also in RPC, where it would wait
for keys on the RPC pipe. Thus, when an argument is `--resume` or
`-r`, koa first runs a picker child on the terminal, before the SDK's
view exists: `pi --mode rpc --no-session --no-extensions --extension
koa-resume.ts`, with the terminal as its streams, koa's pi arguments
in `KOA_RESUME_ARGS` and a pipe on fd 3 (`pickSession` in
`koa-child.ts`). The extension decides with pi's exported `parseArgs`,
so koa has no copy of pi's grammar: when pi would not run its picker
(`--session`, `--fork`, `--no-session` and the other flags that
precede the picker in pi's `main.js`), it answers `skip`. Else it
shows pi's exported `SessionSelectorComponent` with pi's two session
loaders and the session directory that pi resolves, answers `ready`
when the screen takes input, then `selected` with the file or
`cancel`, restores the terminal and exits. On `selected`, koa adds
`--session <file>` before `--` and keeps `--resume`, because pi's
`--session` wins over it, so the restart's rules stay as they are.
On `cancel`, koa prints "No session selected" and exits 0 with no
webview. Subagent sessions do not show, because ko-pi keeps them out
of pi's session tree.

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

**A child takes its parent's harness** (the user's decision). ko-pi
learns its harness from the explicit `--harness` flag, never from
pi's mode. A ko-pi with the flag spawns its children as `koa`, with
`--browser` for `koa-browser`; without it, as `ko-pi`. Everything
else of a child (its arguments, `resume_from`, `fork`, the registry
and the notices) does not change, because the child's pi is the same
pi with the same ko-pi. A koa child in `ko_tui` is a webview pane in a
client that shows no webviews; it works and reports as any child.

**The RPC link.** koa splits pi's stdout on LF only, with a byte
decoder, never `readline`, which also splits on U+2028 and U+2029
(pi's `rpc.md`). It reads continuously, because pi honours
back-pressure. It writes a command only after the previous write
drained, correlates each response by its id, and gives each command
a deadline (`RPC_RESPONSE_MS` in `koa.ts`). A line that is not JSON
goes to koa's stderr: it is a bug.

**Readiness.** koa refuses pi's commands from the page until pi's
session is loaded (`get_state`, then the rebuild, the levels and the
stats), because a prompt sent before that snapshot was lost when the
snapshot arrived. Each route names its access (`ready`, `alive`,
`exited`, `any` in `koa.ts`): completion, the attachment routes and
the dialog answer work while pi starts, because pi can wait for a
dialog's answer before it answers anything else.

**ko-pi inside the RPC pi.** ko-pi's `session_start` sees a UI in RPC
mode, so it opens the message stream, writes the `pi.*` variables,
registers the agent tools and starts the peer client, as in a TUI
pane. Its job rows go through the status route, so a koa pane has
them with no work in koa. A message on the stream goes through
`pi.sendUserMessage` and reaches koa as pi's message events.

**Status and title.** pi reports OSC 7501 only in its TUI, so koa
writes the pane's root record `app=pi` itself: working from
`agent_start` (and during a compaction), at `agent_settled` idle when
aborted, else error or done from the last assistant message, blocked
with kind question while a dialog is open, and `clear` when pi exits.
With ko-pi's `pi.session`, the row is a `PiAgent`
(design-program-status.md). koa sets the pane title with OSC 0 from
the session name and the session's directory.

**The session's directory.** For a session of another directory, pi
runs in that directory, so koa reads `cwd` from the session file's
header, not from its own working directory. pi writes a new
session's file only at its first message; a missing file is a new
session in koa's own directory.

**pi exits by itself.** When pi exits with code 0, koa shuts down as
on a quit, as a TUI pi leaves the user in the shell: a subagent's pi
leaves when its parent goes, and its pane must go with it. When pi
fails (a code other than 0, a signal or a spawn failure), koa keeps
the pane, because a pane with the default `close: exit` would vanish
and the user must see the failure. The transcript stays, the foot's
state says how pi ended, and the exit card shows the last lines of
pi's stderr and "Start pi again". The restart drops the session,
model and thinking flags and adds `--session <file>` of the last
`get_state`, because the session file holds the model and thinking
changes of the pickers; without a known session file, the original
arguments run again.

**Shutdown.** koa ends on `SIGTERM`, `SIGHUP`, `SIGINT`, a quit from
the page (Control-D in an empty composer) and pi's clean exit. Every
part that koa makes registers its own teardown as it is made, and one
shutdown, which exists from the moment the SDK's view exists, starts
every teardown in reverse order and waits for all of them, so an
early failure also cleans up. The HTTP server and the feed's streams
close; pi's stdin closes, koa waits for pi's exit
(`KOA_PI_EXIT_MS`), then sends `SIGTERM` and later `SIGKILL` to pi's
group; koa's directory goes; the SDK's view closes, and its waits have
their own deadlines. A stuck bridge or pi thus never keeps koa
alive. The reply to the page's own quit request is sent before the
shutdown starts, with a deadline (`QUIT_REPLY_MS`). Every group
signal of koa goes through one function, `signalChild` in
`koa-child.ts`, which takes a child that koa spawned (pi or `fd`) and
ignores `ESRCH` and `EPERM`, as `signalJob` does (design-subagents.md,
"Stopping a job"); `scripts/lint.sh` permits `process.kill` only
there. The session picker shares koa's group, so it gets its signals
through its own `ChildProcess.kill`.

**Errors do not stop koa.** An error of a child, a stream, a pi record
or a timer callback is reported as one `koa:` line on stderr, and koa
goes on; only the loss of the terminal stops it. The edges:

- A record from pi whose handling throws is a protocol error of pi.
  koa drops the record with one line that names its type and handles
  the next records. It does not validate each record's shape: pi's
  types are the contract, and one catch at the dispatch in `rpc`
  covers every field. A bad record does not end pi, because pi can
  still work and the user keeps the session. A handler that throws
  midway keeps what it changed before the throw.
- The transcript's flush takes each held message or tool result out
  of its queue before it applies it, and reports a throw, so one bad
  entry does not block the later ones.
- Every timer callback runs through `later` (`koa-timer.ts`), which
  reports a throw.
- An error on pi's stdout or stderr is reported; pi's exit path
  owns the rest of its lifecycle.
- A signal error other than `ESRCH` and `EPERM` is reported by
  `signalChild`, which never throws, so the shutdown continues.
- An error on the `fd` child's stdout ends the completion read with
  no result.
- An error on koa's own stdout means that the terminal is gone: koa
  shuts down as on `SIGHUP`; before the shutdown exists (`--help`),
  the error is ignored. An error on koa's own stderr is ignored,
  because there is no other place to report it.

**The private directory.** koa makes one directory `koa-<pid>-*` under
the temporary directory at start (0700) for the image store and the
uploads, and removes it at exit. A koa that dies by a signal leaves
it; the host's cleaning of the temporary directory removes it.

## The page and koa

The page talks to koa over HTTP only: one `EventSource` on `/events`
and short `fetch` requests. No WebSocket. Every body is a string or a
`Uint8Array`, because WebKit gives a scheme handler a `Blob` or
`FormData` body empty (design-app.md, "Webview panes"). koa's routes
are in `koa.ts` (the commands), `koa-transcript.ts` (`/events`,
`/items`, `/images/`) and `koa-attach.ts` (`/attachments`, `/steps/`);
each route's body validator is beside its handler, in `koa.ts` for
the commands. A failed RPC
answers 409 with pi's error text, and the page keeps the composer's
text.

**Commands need a typed body.** A `POST` must have the content type
`application/json` (an upload chunk `application/octet-stream`), else
koa answers 415. A browser sends a form post with a simple content
type to any origin without asking; this rule makes such a post do
nothing ("Browser mode" below).

**`/name` is koa's.** The user decided that `/name` sets pi's session
name through RPC instead of reaching the model as text. koa
intercepts `/name <text>` and a bare `/name` before pi's `prompt` and
answers with a notification in pi's words. No other built-in command
of pi's TUI is handled; completion offers only `get_commands`.

## The transcript

`koa-transcript.ts` projects pi's session into items in memory: user
messages, assistant messages with their text, thinking and tool
blocks, the custom messages that pi displays, user `!` commands,
summaries, and koa's notifications. It takes whole pi messages, so a
replay from `get_messages` and the live stream use one conversion.
`koa-records.ts` defines the items and the records.

- **Live messages.** pi's `message_update` records carry deltas only
  (pi's `json.md`). koa keeps the partial assistant message itself,
  applies each delta to the block at its index, and gives the module
  the whole message; the `*_end` events and `message_end` replace
  the partial with pi's authoritative content. A tool call's argument
  bytes parse once for each flush, so a step line names its tool
  while the arguments still stream.
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
- **Notifications** (pi's `notify`) are items, one line where they
  arrived, and they stay. `get_messages` has no notifications, so a
  rebuild keeps the module's own notification items and merges them
  by time when the rebuild is of the same session (a compaction, a
  restart), and drops them for another session (a switch, a new
  session, a fork, a clone).
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
no queued work runs after it.

- **One owner of Enter.** The composer's highest-precedence keymap
  owns every Enter variant; `standardKeymap`'s Enter binding is
  filtered out, because it would run during an input method's
  composition and indent a Shift-Return newline. Each Enter binding
  returns false while a composition has started, so the Enter that
  commits a candidate never sends.
- **The cursor** is CodeMirror's `drawSelection()` in the pane's
  cursor and selection colours. WebKit's native caret lagged visibly
  when the Markdown highlighting rebuilt the spans around it.
- **Focus.** The composer takes the focus at start, when pi's
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
  user's, decides it again.

**Completion.** pi's RPC mode offers only its command list
(`get_commands`: extension commands, prompt templates and skills, no
argument completions), ignores ko-pi's agent completion provider, and
has no file search. koa cannot import pi's provider: `pi-tui` is not
reachable from pi's package exports, and pi's bun binary has no
modules. So koa copies pi's rules (`koa-complete.ts`), behind its own
`POST /complete`:

- `/` at the start of the first line: `get_commands`, asked at each
  request so that a `/reload` in pi shows at once, with pi's fuzzy
  filter. `@token`: the agents of the session first, then files from
  `fd` with pi's arguments and scoring. No forced Tab completion and
  no plain-path completion (the user's decision).
- The token rules are one copy in `share/pi/token.ts`, which ko-pi,
  koa and the page import, so the page asks only in a context and the
  two sides agree on where a token starts. koa computes the prefix,
  the options, their insert text and the matched letters; the page
  decides nothing.
- The user's pattern follows `--` in `fd`'s argv, so a query such as
  `@"--help` is a pattern, never an option. Each search has a
  deadline and caps. A request that the page aborts ends its `fd`.
- `@name` agents are koa's own computation from `ko api GET /layout`
  with ko-pi's shared rules in `share/pi/agents.ts`. koa has no
  registry, so it lacks ended children and peers; a completed
  `@name (session <prefix>)` reaches the model as typed, and ko-pi's
  tools resolve it.
- No completion inside a code span or a fence: the source checks the
  Markdown tree.
- The popup is CodeMirror's tooltip, mounted in a layer at the page's
  root (inside the field, the field's own backdrop filter made it a
  backdrop root, so the popup's blur saw only the field), pinned above
  the field.

## The composer's foot

The user decided with the mockup that koa has no status bar: the
foot of the field holds the state, the model and thinking-level
buttons, the context, the extensions' statuses (`setStatus`) and the
working directory at the right. The state cell has a fixed width, so
a change of state or time never moves the cells to its right. The row
has no send or stop button and says nothing about Return and Escape. A
narrow pane drops the extensions' statuses first, then the level's
text; the model picker then offers the levels.

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
  page lists the steering and follow-up messages above the composer,
  so the field and its attachment chips stay together.
  Taking it back calls `clear_queue` and puts the texts, with their
  attachments, into the composer.
- **Context and model facts** come from `get_state`, the pickers'
  responses, `thinking_level_changed`, and `get_session_stats` after
  each turn, settle and compaction. koa runs no git: the user removed
  the branch and dirty mark.
- `set_editor_text` replaces the composer's text; `setWidget`,
  `setTitle` and the other fire-and-forget methods are ignored.

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

## Agent cards and job lines

ko-pi is the only writer of agent messages and job notices, and ko-pi
and koa ship together, so ko-pi writes the facts that the page needs
into each message's `details` (and into the `details` of the
`spawn_agent`, `message_agent` and `async_bash` results), typed by
`share/pi/records.ts`. The transcript reads `details` only, never the
header lines, which stay in the text for the model and for pi's TUI.
`details` is also in the session file, so a rebuild shows the same
cards. A custom message without these details (another extension's,
or a session written before them) stays a plain notice.

The user decided the look with the mockup `agents.html`:

- `spawn_agent`, `message_agent` and every inbound agent message are
  a card with a "to @name" or "from @name" header, which splits its
  run as a text does. A card shows one line of its text until a
  click: the first line as plain text with its Markdown syntax
  removed (the first code line when the text starts with a fence),
  so a closed card keeps its height. Open, the text is Markdown,
  rendered as final text by the reply's renderer. A custom message
  without agent details is not Markdown: it stays a one-line notice
  of its first line, with the same syntax removed and no expansion,
  because another extension's text need not be Markdown. A card
  shows no delivery status and no meta lines: only a failure
  shows, as a word in the kind's place. The `@name` has no action: a
  focus of another pane would be a new page-to-app surface.
- `stop_agent`, `list_agents`, `read_report`, `list_async_bash` and
  `stop_async_bash` stay steps: they are the caller's own actions, not
  messages.
- A job is not an agent (design-subagents.md, "A job"): its end
  notice is one line in the terminal font that opens to its output,
  gray on success and in the error colour on failure, and the stream
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
  each `entry_appended`; on a rebuild, the entries of `get_entries`
  (one call beside `get_messages`; a custom entry is not a message)
  that are on the parent chain of pi's leaf, placed by time among the
  messages, which keep their branch order. koa applies the rebuild in
  the callback of the `get_messages` response, which it sends after
  `get_entries`, so no event that pi wrote after that response is lost.
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

The TypeScript suite drives koa over the scripted pi
(`koa-fake-pi.ts`) and the fake ko: the feed, the delivery, the
routes, the attachments, the restart and the status bytes
(`koa-program.test.ts`), the transcript module, completion, the
queue's matching, the image sniffer, and the page's DOM rules over a
fake document with the page's types stripped (`koa-dom.test.ts`). The
Markdown memo is a pure module, tested under Node against a full
render of every prefix, and its annotation marks over each kind of block
(`koa-page.test.ts`). Kido.app's `KoaWebviewTests` snapshot each
state of the mockups in light and dark, windowed and narrow, and
check the composer's keys, focus and popup, and the question
controls' placement and clicks, in a real WebKit.
