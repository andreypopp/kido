# koa: design

koa is Kido's pi harness. It runs pi sessions through pi's SDK in
one Node process and shows one HTML page in a pane or a browser.
This file owns the design of koa, its page, its agent extension and
its release. [dev-koa.md](dev-koa.md) holds its development workflow.

The boundaries have their own contracts:

- [protocol.md](protocol.md): ko's routes, pane identity and webview
  transport. koa's page routes are not ko routes.
- [design-webview.md](design-webview.md): ko's webview pane mode and
  reverse transport.
- [design-app.md](design-app.md#webview-panes): the native webview,
  sandbox, keys, theme and preview bridge.
- [design-runtimes.md](design-runtimes.md): runtime placement,
  identity, path mapping and exec sessions.
- [design-program-status.md](design-program-status.md): the server's
  classification and reduction of program status.
- [reply-annotations.md](reply-annotations.md): the contract between
  annotation producers and consumers.

`app/design/koa/NOTES.md` indexes the UI references. Use those
references for visual decisions; use the source for constants,
record shapes, command catalogs and tool schemas.

## Overview and process model

### Ownership

`koa/koa.ts` connects the HTTP server, the agent tree and the page.
`koa/koa-agents.ts` owns the tree. Each agent has a pi
`AgentSessionRuntime`, its own services and extension instance, and
one view from `koa/koa-view.ts`. The process shares one
`ModelRuntime`, so credentials and model discovery have one owner.
A subagent is not a pane or a child process. A background command is
a job, not an agent. A top-level spawn is a separate koa pane.

The host mediates inside the process. ko mediates between panes.
Neither the extension nor the host reads ko's state directory or
another live agent's private state. The extension uses `ko api`,
with types from `webview/ko-api.d.ts`; the webview SDK uses
`ko webview`. ko does not read pi session files.

This shared process gives one extension-loading path and one event
path. The accepted cost is a shared failure domain: an uncaught
exception can end every agent in the pane. koa has no terminal UI.
A client without webviews gets a terminal notice while koa continues
to serve. Outside a ko pane, use browser mode. A plain `pi` is not
this harness; its classification belongs to the status model.

### Startup and the SDK boundary

`koa/bin/koa` checks Node and pi before it starts the program.
The host needs Node 24 or later and an installed pi. The client that
shows the page needs neither. `koa/koa-child.ts` finds pi's package
from its executable, including Homebrew's wrapper layout.
`koa/koa-sdk.ts` loads that package, not a second installed copy.
Its resolve hook applies only to imports from koa's own directory,
so a user's extension keeps its own module resolution.

The installed program has no `node_modules`. It uses the selected
pi's SDK and supporting modules; the page's dependencies are bundled
at build time. Node's compile cache is enabled before the SDK loads.
The SDK boundary also imports pi modules that its public index does
not export. A pi update must check these imports and the copied shell
and session-directory rules, not only TypeScript types.

`koa/koa-args.ts` is the accepted option table. koa parses strictly,
then gives pi the reconstructed arguments. Options that bypass an
interactive session are not accepted. Values that start with `-`
use `--option=value`. File expansion through a positional `@file`
is refused; the page's attachments supply files. Positional messages
run once after startup, in order, with each turn settled before the
next message. A page connection never starts them again.

The root's session manager is made before its services. At command-line
startup the launch directory is authoritative, including when opening
a saved root session. Resource paths resolve from that directory.
A later page session switch uses pi's runtime and the selected
session's directory. koa does not change the process working directory.
A child's services use the child's directory and resources; the root's
command-line extension and tool options are not inherited.

The host adds pi's built-in extensions as well as the hidden inline
`agentExtension(host)` factory. The SDK alone does not add the
built-ins that pi's CLI adds. Project trust uses pi's RPC trust
context, not the presence of a page. After trust resolution, the
session gets koa's UI context.

### Binding and readiness

The HTTP server and the view exist before extensions bind. The host
sets the new session as the owner, resets its view, subscribes to its
events, and then binds extensions. A `session_start` handler can
start a turn or ask a dialog; both must reach the page. The runtime's
rebind hook is the only binding path. A second bind would emit a
second `session_start`.

`uiContext` in `koa/koa-agents.ts` maps dialogs, notices, statuses
and editor text to the page. Terminal-only UI methods do not create
terminal UI. Custom components reject, and theme switching reports
that it is unsupported. The session binds in RPC mode. Loader and
extension-handler errors become notices.

Each page route declares its access and scope in `koa/koa.ts`.
Session actions wait for readiness. Startup dialogs can be answered
before readiness, and completion and uploads have their own access
rules. Do not replace these declarations with a general ready check:
a startup handler can wait for a page answer.

The host receives whole pi message events. It does not use the RPC
stream's deltas. pi owns argument parsing; koa treats pi's messages
as read-only and converts the newest message at a feed flush.

### Session changes

The page's session picker and new-session action use pi's runtime.
An extension can cancel a switch. A committed root replacement ends
its children and resets session-owned state before the new
extensions bind. Fire-and-forget UI updates during the switch are
buffered and replayed in order. A cancelled switch keeps the session.
A failed switch that has invalidated the old session leaves a failed
view; it never reuses that session object.

The page asks before it switches away from a running turn or user
shell command. The picker lists top-level sessions only and searches
names and first messages. Subagent files are outside pi's resume
search tree. `koa/koa-session-dir.ts` supplies the directory rule to
both pickers.

`koa --resume` has a separate terminal picker before the webview
starts. `koa/koa-resume.ts` runs as a pi extension in a child process
that owns the terminal. `koa/koa-child.ts` bounds its readiness and
exit, validates its reply, forwards signals and reports failures with
pi's version. Cancellation exits without opening a page. This picker
is not a second harness.

### Reload, restart and failure

`/reload` first reloads each live pi session, root first. The pane's
inbox stays open but holds delivery. The tree, jobs, status records
and event subscriptions survive replacement of the extension
instances. koa refreshes each view and replays buffered UI updates.
The session reload requires every agent to be ready and idle, with no
pending user queue, dialog, user shell command or external editor.
When one is busy, `/reload` does not reload the sessions, but it
still does the page step below: a page load is safe at any time.

The rule that pairs the page with the program is: one install is one
build, and koa serves a page only beside the program that it was
built with. The page bundle compiles the shared modules into itself,
and `koa/Makefile` copies the same sources as the program, so equal
program files mean a page of the running program. There is no page
protocol version and no hash of the wire types: those find a changed
type, not a changed meaning, and would permit a new page beside an
old program.

After the session reload, koa reads the installed page, then
`koa/koa-identity.ts` hashes the installed program and webview SDK
without the page files. The order matters: an install that runs
during the read cannot pair a new page with the old program, because
the program is read last.

- If the program changed, koa restarts only with a saved root
  session, no running jobs, no child that owes a report, and no busy
  state. Services also block this restart. Otherwise a notice
  explains the deferral, and a later reload can try again. The old
  document stays while the old program runs. A failed program read
  does not trigger a restart.
- If the program is equal and the page changed, koa swaps the served
  document ("One document, one instance"). The notice says when the
  agents were not reloaded because one was busy.
- If the page cannot be read, the old document stays, with a warning
  notice.

`make -C koa install` is atomic for a running koa: it copies to
`share/koa.new` and renames, so a read sees the old files, the new
files or no files, never half of a file.

A process replacement is the only way to load new program code.
Node's ESM cache has no eviction, and the state that must survive
(the tree, jobs, inbox, status records, feeds and the HTTP server)
is held by closures that new code cannot adopt. A hand-over of that
state as data would be a migration path from an older program.

`/restart` bypasses the identity, idle and deferral checks. It ends
running work and replaces koa on the root session file when one
exists, or on the original startup arguments otherwise. Both commands
are root-view commands. They are not an alternative HTTP access path
for a session that is unavailable.

A process replacement answers the request first, shuts down, drains
stdout and stderr, then uses `process.execve`. The SDK closes without
leaving webview mode. The pane remains while the app shows its
not-serving state, and the new serve stream loads a new document.
The new process starts only the root. Saved children can resume on a
message. Composer attachments and page-local scroll state do not
survive. Browser mode opens a new port and tab.

A failed session start keeps the transcript and offers Start again.
The root retries from its restart arguments; a child retries from its
spawn plan. An uncaught exception writes to stderr, tries to set the
pane's close policy to keep, and exits. Reported provider or extension
errors do not take that crash path.

Shutdown cancels dialogs and disposes runtimes deepest first before
other teardown. The host-disposal wait is bounded so a stuck extension
cannot keep koa alive. Each resource registers cleanup when created.
The reply to a page quit is allowed to finish before shutdown.
Signals to koa's own helper groups go through `signalChild` in
`koa/koa-child.ts`; job signals have their separate owner below.
Temporary image and upload stores are removed on normal shutdown.
An uncatchable termination can leave them for host temporary-file
cleanup.

## Page and transport

### The webview SDK

`webview/index.ts` defines `@kido/webview`. It has no package
runtime dependencies and is shipped with ko and with koa. It is not
published to npm. A page program gives `webview(server)` an ordinary
`node:http` server, not a special handler. The SDK owns listening and
closing. It listens on a private Unix socket before it starts the
bridge, so the app cannot load a document before its server is ready.
HTTP stacks and WebSocket upgrades can use this same server.

For the pane target, ko determines pane identity. The SDK does not
infer it from environment variables. A missing ko executable or the
bridge's no-identity exit returns no view. Support reports come from
the bridge, and an unexpected bridge exit starts a reconnect. The
program decides when to show. koa shows on support and otherwise
prints a notice; it does not stop serving.

Show and hide calls run in order. Pane show needs a TTY on stdout,
because `ko webview enter` writes the escape there. The SDK's shown
state records its own last action, not the app's current display.
Close cancels listeners and queued work and removes the private
socket directory. Close without leave supports process replacement.
The deadlines and child escalation are defined in `webview/index.ts`.

The browser target forwards a loopback listener to that same socket
and needs no ko. It validates Host and Origin on each request and
WebSocket upgrade, not only at connection creation. A foreign Host
is refused, as is a foreign or null Origin. An absent Origin is
allowed: local processes may call the routes. Host-owned request
headers are removed before forwarding. This is not authentication
against a local process.

Browser show opens a URL with an absolute path. Repeating the current
path does nothing; hide cannot close a browser tab. Close allows
responses in progress to finish within its bound before it destroys
remaining connections. Browser mode supplies neither Kido's sandbox
nor its page bridge.

### One document, one instance

`koa/koa-assemble.ts` combines HTML, CSS and JavaScript into one
response. Remote page loads otherwise pay a round trip for each
asset. It hashes the exact bytes that it reads, so the page identity
and the document cannot come from two reads. It reads the files twice
and refuses the page when the two hashes differ: one install rename
can mix at most one of the reads, so equal hashes mean a page of one
build. koa assembles the
document at startup and serves that copy until `/reload` swaps it
("Reload, restart and failure"); a page load never reads the files.
koa also reads the shell-completion script at startup.

The document carries an instance identity. It identifies the served
document, not the process: a swap makes a new instance. Each event
stream open sends it back. A different identity gets a reload record
rather than new state for an old page. This also covers hidden pages
and browser back/forward restoration. It is a reload boundary, not
support for old record formats.

A swap writes the reload record to each open event stream that named
an instance, agent feeds and job feeds, selected and named, and ends
it (`reloadPages` in `koa/koa-feed.ts`). A stream that named no
instance belongs to no document and is not touched. The page that
sent `/reload` gets its reload on its stream as every other page
does; the notice is a koa-owned item, so the new document shows it.
Browser mode keeps its port and tab. The swap takes no cause, so a
later caller (a UI extension's page files, a session switch) can use
it.

### Requests and delivery

koa uses finite HTTP requests and an `EventSource` stream, not a
WebSocket. `koa/page/http.ts` defines the page's route types;
`koa/koa.ts`, `koa/koa-attach.ts` and `koa/koa-transcript.ts` own the
handlers. The records are in `koa/koa-records.ts`. Page records do
not import pi types: pi's declarations would introduce Node globals
into the DOM-only type check. Compile-time checks at the host boundary
compare the shared pi value sets and statistics.

POST bodies must have the required non-simple content type. This
rejects cross-origin form submissions even if a browser omits Origin.
Bodies are strings or bytes. WebKit does not give the scheme handler
a Blob or FormData body. The app's tests pin that external constraint.
The bridge requests identity encoding; compressed responses are not
supported by the native scheme path.

Use EventSource for an open-ended response. WebKit bug 322545 can
hold bytes received while a fetch-body reader is busy until another
chunk or EOF. A quiet stream can therefore hide its tail. EventSource
uses a different loader. `WebviewPaneTests` pins the fault; finite
fetch responses are not affected. The transport must not work around
it with invented keepalive data in a model answer.

A request that acts on a session carries its session identity. koa
checks it after reading the body and again at asynchronous ownership
boundaries. A switch must not send an old prompt to the new session.
Uploads belong to the pane's shared attachment store; sending a prompt
is the session gate for them.

### Views

Each agent has a feed. The pane selects one agent or job view.
`switchView` in `koa/koa.ts` is the selection owner. Sidebar record
actions, page links and the view bar use it. A stop of the viewed
subtree selects the nearest surviving ancestor. A switch publishes
state before transcript data, since links and image requests need the
new identity. It cancels the external editor but does not rebuild an
agent's feed or interrupt its work.

The composer, abort, queue, dialogs, pickers, user shell commands and
session-local commands act on the viewed agent. Process and root
session commands remain root-only. A job view refuses agent actions;
Escape does not abort the job owner's turn.

The page keeps drafts and scroll positions by view, with session
identity for a saved scroll position. A switch cancels uploads and
pending completion/history requests and closes transient UI. Returning
to a reader position loads older content until its anchor is present;
a missing anchor opens at the end. Selection is not persistent
session state.

A reload of the same document entry keeps this memory: the saved
positions with the current reader anchor, the non-empty drafts and
the topic filters. The page writes them to `history.state` on
`pagehide`, so a `reload` record and the app's Reload Page keep them,
and reads them once at start. `history.state` needs no storage
permission or origin and ends with its entry. A following view saves
its following intent, not an anchor. Restoration is the `restoring` path of a switch, so a
position of another session is not used. Folds do not survive,
because their keys depend on the loaded range. Attachments, pickers
and dialogs do not survive. A process replacement loads a new entry,
so the memory is gone.

A client with its own navigation can name a view on each request.
Named requests do not change the pane's selection. Only the selection
change route does that. Selected event streams move on a switch;
named streams stay with their feeds. A feed with subscribers keeps
its epoch. A stopped agent sends named subscribers a gone-view record
with the surviving parent, so clients can navigate back.
`ViewAddress` in `koa/koa-feed.ts` defines this distinction.

The external draft editor has one owner: the selected agent. A named
request for another agent cannot open it. A named job clear does not
move the pane's selection. Agent feeds live with their agents; job
feeds live while selected or subscribed, and a new job feed gets a
new epoch.

### Transcript model

`koa/koa-transcript.ts` projects the active session branch, not only
the model's current context. A rebuild walks the branch and uses pi's
entry-to-message conversion. Compaction keeps earlier turns visible
and adds a summary at its branch position. Other branches are not
shown. Live and rebuilt messages use the same conversion.

Tool results belong to their call blocks. Partial messages are held
until a flush; only the newest is converted. An assistant item becomes
final when its message has ended and every call has a result or will
not run. Tool and thinking times come from live events; replay cannot
invent thinking durations that pi did not save.

The module caps large arguments, results and agent text and reports
truncation. It keeps the session's projected history in memory; the
wire windows and the mounted DOM, not the whole session, are bounded.
Image bytes are stored separately. Constants and the item vocabulary
belong to the source, not a second table here.

Notifications and command outcomes that pi does not store remain
koa-owned items. Rebuilds of the same session keep them; another
session drops them. A completed compaction replaces its running
outcome at the same position with the saved summary. It does not
rebuild the earlier transcript, so scroll anchors remain valid.

Each rebuild makes a new epoch. Within an epoch, every published
change increments an item's revision. A patch states the revision it
needs. History snapshots flush first and contain published state only.
The page ignores an older patch, applies a matching patch, and resets
on a revision gap. It holds patches for missing items while a history
request is pending. A reset invalidates that request even when an old
answer later arrives, and so does an anchor load of a restore: the
new snapshot starts its own load.

A connection, as a view switch, gets the state before the reset or
the catch-up, so the page knows the view before its snapshot. A
restore waits for the snapshot that follows its switch, except at
the start of a page: a snapshot that arrives before the first state
can only be of that state's view.

A reconnect sends the epoch and the last final item, not
Last-Event-ID. Patches change unfinished items, so an event id would
be the wrong cursor. A current cursor gets the missing items; another
epoch gets a reset window. A window, and each unfiltered older page, holds the
newest records back to and including the hundredth counted message,
with every record between them, and back to the start of the run that
holds the first of them, so a page does not cut a run. A user message and an assistant
message with visible text count; tool steps, agent and job items,
notices and metadata records do not, so a tool-heavy turn does not
fill a page by itself. A page has no byte limit: the per-field cuts
of tool arguments and results bound its records.
`koa/page/transcript-history.ts` owns the page's older-history
requests: the cursor, the pending request and the patches that it
holds. The page's lowest loaded item is a separate fact of the page,
not this cursor. Without a topic filter, the cursor for the next older
page is the lowest seq of every record that it received, metadata
included, so a page of only metadata still moves it; a filtered
reload's cursor ignores annotation and topic records, which can lie
outside its message range ("Reply annotations and topics" gives the
filtered page). The page installs a page as one batch: it adds
every row, then rebuilds run ownership, the topic index, the
projections and the order once. A live record keeps its own
incremental path. The page asks for older history when its top comes into view. After
the first page (also when the initial state that follows the reset
moves the scroll), each older page and a topic reload, it asks for the
next older page while its top is still in view, so a window that the
rows do not fill fills itself; a failed page stops this until the next
scroll. A slow page whose output queue exceeds the feed cap is
disconnected and can catch up; it does not block other pages. A
reset (a first connection, a view switch, a resync or a job's reset)
is always written whole, because its window has no byte limit. The
catch-up of a reconnect with a matching epoch is written whole in the
same way: its corrected items do not move the page's cursor, so a
capped catch-up would reconnect in a loop. The cap counts only the
live records queued after the undrained reset or catch-up.

An exception while applying a record is different from a transport
failure. The page closes the feed and asks for a reload. Automatic
reconnect would apply the same bad record over partly changed state.
Transport loss and revision gaps have their explicit recovery paths.

### Runs, Markdown and rendering

A run is page presentation, not a feed record. It groups consecutive
thinking, tool, agent and job steps between visible prose or user
messages. A notice joins an existing run but does not open one.
Whitespace-only text and hidden metadata do not split a run. A gap of
unloaded history does. `koa/topic-run.ts` assigns each run one owner
for rendering, positioning, unread counts, find and topic filtering.

The grouping is independent of turn boundaries. A report received
while idle can join the last run. Topic filtering does not regroup
runs: prose hidden by a filter still separates them. Fold state is
page-local. `koa/page/steps.ts` supplies labels and detail text to
both rendering and find; the page never parses model-facing message
headers to recover agent or job facts.

`koa/page/markdown.ts` memoizes top-level Markdown blocks. An append
re-lexes the affected tail with enough preceding context for a token
to absorb another token. Invalid boundaries or changed reference
links cause a full lex. Unchanged blocks retain their nodes; remend
repairs only the unfinished tail. Keep current source separate from
cached blocks so slices do not retain old copies of a growing reply.

Model HTML is escaped. Only permitted absolute links become links.
A parsed detached document becomes DOM nodes; model text is not
trusted HTML. User messages use the same renderer with the explicit
quote rule used by question answers. Thinking renders as Markdown
only when opened. A closed thinking step does no Markdown work.

The reveal is presentation only. Records update the model at once;
new unfinished assistant text becomes visible by complete blocks and
whole line units. History and final text render whole. Paragraph line
boxes, list items, table rows and fence lines determine the clip.
A width change cannot leave a clip through a line. Content clipped
to zero occupies no space. Long fences fold independently of the
stream. `koa/page/reveal.ts` and the reveal settings in
`koa/page/page.ts` define the units and limits.

Record application schedules a frame rather than rebuilding DOM for
every token. The frame reads the geometry for its scroll decision
before its writes, measures after them only the rows that it marked, and renders each
changed item once. Hidden pages use a timer because WebKit pauses
their animation frames. A visibility change transfers pending work between
these mechanisms; pagehide cancels it.

The working mark belongs to the turn, not a Markdown block. It moves
between its own row and a running step without being rebuilt for each
token. Run rows are patched in place. Keeping the node attached lets
WebKit's compositor animate it while the main thread is busy. The
bare row's height is not removed mid-turn merely because a tool
starts. Reduced motion makes the dots static and disables grow and
scroll travel; it does not disable chunking or fence folds.

### Windowing, scrolling, find and copy

The page retains loaded items in its model but mounts only rows near
the viewport, the live tail, and rows needed by a drag selection.
Runs that span items mount as a unit. A position table retains measured
extents after rows unmount and estimates unseen extents. A width or
line-height change invalidates measurements. Padding and gap boxes
stand for absent rows. Mount work is time-bounded per frame.

A row is sized once. Its height is known when it is inserted, and
koa measures it then, because only layout knows the height of
wrapped text. Nothing inside a row changes its height by itself, so
no observer remeasures rows: an unexpected change would move the
reader's anchor, and no later correction could hide that frame. Every
element whose box could change on its own has its size before
insertion. An image thumbnail reserves its scaled box from the
width and height that koa reads from the image's header when it
publishes the item (`imageInfo` in `koa/koa-image.ts`); an image
without them gets a fixed box, and a failed load keeps the box
(`app/design/koa/NOTES.md`, images). The page has no remote fonts,
embeds or asynchronous highlighting. The first rows mount after
`document.fonts.ready`.

The only later height changes are koa's own: a revised or streaming
item, a reveal step and its grow animation, a fold, a fence
expansion, rhythm and working-mark moves, a topic chip edit, a
change of the transcript's width or line height, and a change of the
page's font settings. The code that makes such a change marks its row
(`dirtyExtent` in `koa/page/page.ts`); the frame measures the marked
rows once and corrects the reader in the same frame, before it
paints. A grow animation is measured on each frame only for its own
rows, until it ends. Scrolling reads row positions to find the
reader's anchor but never measures an extent.

`koa/page/scroll.ts` is the one scroll owner for transcripts and job
logs. It is a pure state machine. DOM code supplies events and
measurements and applies its decisions. Browser scroll anchoring is
disabled to avoid a second owner. The user never scrolls the document
itself: every body child is positioned, and the root hides its
overflow, so a
body that is taller than the viewport for a moment (a resize) does not
give the host's web view a scrollbar of its own beside the transcript's.

Following keeps the bottom exact after layout while the pane has
focus. Reader input establishes an item anchor. Layout changes above
that anchor preserve its offset and any intervening reader movement.
A scrollbar jump into unmounted space uses the position table to
mount the destination. A fold toggle holds its header at the same
screen position and ends scroll travel.

Following has no animation: growth puts the transcript at the new
bottom in the same frame. While following, the written scroll
position never decreases. The following state keeps a floor, the
largest natural transcript height seen, and the page applies it as
the minimum height of the transcript's clipping wrapper before it
writes the scroll. So a shrink at the tail (a revised reveal slice,
a working row that goes, merged run rows, the typing dots, the
unread divider) leaves a blank reserve under the content instead of
an upward jump, and later growth consumes the reserve. Turn end does
not release it. A reader keeps only the part of it that the current
position needs, so leaving following causes no clamp, and the part
goes as the reader moves up; a reset, a switch, a filter or a resize
clears it. Each frame measures fresh geometry after the
render and reveal writes, and the divider and rhythm changes are
applied and measured once more before the frame's one scroll write,
so no write uses a stale height.

A hidden or unfocused following page becomes a reader when new
content or layout moves the bottom. Focus alone never resumes
following. The user's send and Latest do; a reset opens a following
view at the end even in the background. An explicit following intent
(the start of a page, a reset, or a switch to a view that the memory
does not hold as a reader) lasts through the initial delivery and
layout, focused or not, until the view is placed at a non-empty
bottom or reader input cancels it; only growth after that placement
makes an unfocused page a reader. So a reload or `/restart` of a
following view opens at the bottom.

Each topic filter and All topics keep a separate scroll position,
with the same save and restore rule as agent views. A view left at
the bottom follows the bottom on return. A view left in reader mode
restores its anchor without animation; new visible items received
while away get a divider and a new-item count.
The composer's topic follows the filter at once, but the
transcript keeps its shown filter, rows and position until the
filter's history reload arrives. Then the page installs the rows,
changes the projection and lands in one move, so the switch lands
once. A response for a filter that a later switch replaced is
dropped. Anchor restoration loads the anchor's history when needed.
A saved topic reader also loads unfiltered history from the reset window back
to its saved last sequence before restoration completes, so topic badges
include replies that arrived while the reader was away.
A view not visited before opens at the divider above the first unread
row that the filter shows, or follows the bottom when it shows none.
Unread state belongs to the row, not to the filter: a row that the
filter hides keeps it, so the row is still unread in a later view
that shows it. The count and the divider cover only the shown rows.
This state is in memory only, not in the page's history state. `pagehide` saves the memory
before its last scroll update. New-content counts use
visible assistant prose and runs, not patches, metadata or each step
that joins a run. `koa/page/extent.ts` and the scroll reducer share
that unit of content.

Native find cannot search unmounted DOM. Under Kido the page's find
hook searches its model, loads older history, opens the required folds,
mounts the match and places the selection for WebKit to highlight it.
`koa/page/find.ts` uses displayed plain text, including folded details,
not raw Markdown syntax. A changed query, view or item cancels stale
work before it moves the selection.

Select All copy uses the model when the selection covers the whole
transcript. It exports all loaded items without mounting every row.
Other selections use WebKit's copy. A quote-selection action changes
the composer but sends nothing. In a job view, Kido's prompt palette
receives the selection and preselects the job's owner. The native
bridge contract stays in [design-app.md](design-app.md#webview-panes).

### Composer, commands and queue

`koa/page/composer.ts` owns the CodeMirror editor. Its keymap owns
Enter variants, including during IME composition: committing a
candidate must not send a prompt. Prompt Return sends; Shift-Return
inserts a Markdown-aware newline; follow-up input queues while work
runs. The source defines the complete keymap. Kido's Command keys
belong to the app.

Prompt history comes from the session transcript, including user
shell commands, when browsing begins. It is not a second saved
history. Completion and IME keep their arrow keys. Editing leaves
history browsing; moving past its newest entry restores the draft.

The composer takes focus only when the document has focus and no
page control owns it. Printable keys outside a field route there.
The border indicates where typing goes, not simply which DOM element
has focus. The composer and its dock determine transcript bottom
padding; queue and attachment growth must not cover the last item.
The foot drops information by available field width, not window
width. Hidden picker cells remain available through commands.

`koa/koa-commands.ts` intercepts pi's built-ins before prompt
submission. A known but unsupported built-in is refused, never sent
to the model. Built-ins win over same-named extension commands and
templates. The catalog is the source of the supported set and its
completion order. Built-ins do not consume draft attachments.
Clipboard export uses OSC 52 on koa's stdout, subject to the client's
clipboard policy; a browser outside a terminal pane has no native
clipboard guarantee from that path.

A prompt sent while working uses pi's prompt method with streaming
behavior. This still lets extension commands run. Escape takes back
queued user text before aborting, so queued work cannot start after
the abort. `koa/koa-agents.ts` patches pi's clearQueue once to retain
custom agent messages that pi would otherwise discard with user text.
Remove the patch only when pi supplies that guarantee.

A single-entry removal must clear and resend pi's queue because pi
has no single-entry removal API. koa verifies the displayed entry,
serializes removals, take-backs and sends, and returns unsent entries
to the composer after a failed resend. The accepted race is that pi
can consume an entry or end a turn between clear and resend.
`koa/koa-queue.ts` owns attachment matching, including images-only
messages and pi's queue-update-before-message ordering.

A leading `!` runs a user shell command, not a model prompt or a
background job. The double form excludes it from model context.
`runBash` in `koa/koa-agents.ts` emits user_bash first, so routed
operations can handle it without a host fallback. Only one such
command runs at a time; it has no product deadline. Escape cancels
it before aborting the agent turn. Attachments are refused.

Live command output is view state. The saved pi bash message becomes
the transcript item. Completed commands can wait for pi to record
them at turn settlement; reconciliation removes their temporary
state before rebuilding, and restores it on failure. This prevents
duplicate rows. Live output retains a bounded tail, not its start.

### Completion and editors

`koa/koa-complete.ts` completes supported commands and agent/file
mentions. `koa/token.ts` is shared with the page. The host supplies
match positions and insertion text; the page does not duplicate the
matching rules. File queries follow `--` in fd's arguments and have
cancellation, output bounds and deadlines. Prompt completion is not
plain-path or forced Tab completion. Code spans and fences do not
complete.

In user shell mode, only Tab completes. The host asks the current
extension for `CompletionContext`, because only that extension knows
whether its runtime is ready or refused. Unavailable never means
host. `koa/koa-shell.ts` runs `koa/koa-shell.sh` in that context,
without adding a command to the transcript. The script uses the
execution environment's bash-completion, not the host's when routed.
It parses input as data and refuses constructs that could require
execution. It converts the returned byte span to UTF-16 offsets once
at the page boundary. Typing, selection and session changes cancel
pending feedback; a late reply cannot restore it.

Control-G opens a private draft through `koa/koa-editor.ts` and
`koa/koa-float.ts`. The editor is a child float of the koa pane, with
a terminal and the login environment. Its command follows pi's
editor setting order. The draft stays visible but locked while the
editor opens or runs. A repeated action focuses the same float.
A successful changed result replaces text only in the session that
opened it; it never sends. Failure, removal or loss of the observation
link keeps the draft. The float uses on-exit retention because koa
must observe its death before removing it. An inside-runtime koa
cannot open this host draft editor.

Inline code paths use `koa/path-token.ts`. Each span must contain a
complete path, relative to the session directory or absolute, with
an optional line location. The server parses it again before acting.
A click opens a separate child float on the real file; it reads no
draft back. Routed files open an editor in a runtime pane after a
runtime path check. Each click can open another editor; there is no
unsaved-change check. Path floats use the default exit policy, with
an error wrapper that keeps an editor's failed exit readable.
Browser mode and inside-runtime koa do not offer path-editor links.

### Images, attachments and previews

`koa/koa-image.ts` recognizes image bytes; a claimed MIME type is not
trusted. Transcript images go to private files and the feed carries
references, not base64. All session images are retained without an
eviction budget; the cost is temporary disk. URLs include epoch and
image revision because WebKit can retain decoded pixels for a URL
despite cache headers. Closed tool steps do not create image elements
until opened.

`koa/koa-attach.ts` receives copied bytes in bounded chunks. The page
cannot ask it to attach an arbitrary host path. This works for local,
remote and browser pages and avoids requiring ko to have the app's
macOS file-access grant. Folders are refused without discarding files
from the same drop. Image attachments go to pi as images only; other
files become path lines. pi, not the page, resizes images for a model.

`ATTACHMENT_LIMITS` in `koa/koa-records.ts` is shared by both sides.
Aborted or idle uploads release their files and quota. Used files
cannot be deleted or moved back to queued by a late acknowledgement.
Take-back restores queued files. Live sends keep typed text and chips
separate; a rebuild without that send record shows pi's saved path
lines and thumbnails. A thumbnail reserves its box before its image
loads ("Windowing, scrolling, find and copy").

`koa/koa-http.ts` serves only checked regular files within its size
bound, with nosniff, a restrictive file CSP and a disposition name.
The page cannot turn a claimed image into a document on koa's origin.
Step previews name a transcript step, never a free-form path. The
host resolves the path from its own item. This lookup is host-side;
it is not a general runtime file proxy. A routed path must be visible
on the host for that preview to work.

Kido previews use the native same-origin bridge. In a browser, images
use the page lightbox and other files open in a tab. Preview and
path-editor actions are distinct: the latter can create a runtime
editor; the former reads the file available to koa.

### Job views

`koa/koa-job-view.ts` and `koa/koa-job-log.ts` stream raw log bytes,
not transcript items. The initial tail and subsequent chunks have
absolute file offsets; earlier reads walk the file backward. The
writer flushes before a file read. Reconnect catches up from the file
and tail before sending the ending state, so an end cannot precede
its last output. A different epoch resets the view.

A job can be found in its owner's live registry or in transcript job
facts. The page supplies an id, not a log path. A cleared registry
record can still have a read-only log view; a missing log reports that
it is gone. Stop uses the job's stop path and keeps the view. Clear
removes the record and, for a selected view, returns to its owner.

`koa/page/job-output.ts` decodes incrementally, keeps supported SGR
styles and strips other controls. Carriage returns replace a progress
line. Earlier ranges drop an incomplete first line and start with
default style. Text nodes, not log HTML, reach the page. Job rows use
byte offsets as scroll anchors under the same scroll owner as the
transcript.

### Reply annotations and topics

Annotations arrive as custom session entries. The transcript validates
them against the active branch and projected reply, and drops invalid
or stale spans. Annotations are separate final items: changing a
final reply in place would be invisible to a reconnect cursor that
had passed it. The page uses the newest annotation for a reply block.
The producer contract remains in
[reply-annotations.md](reply-annotations.md).

`koa/page/annotations.ts` converts code-point offsets to UTF-16 once.
The Markdown renderer inserts private markers before parsing and
replaces them in text nodes afterward. Producer boundaries must not
fall inside Markdown syntax. User-provided marker characters cannot
forge controls. Question controls edit the composer; they do not send.
`koa/page/answers.ts` owns quote/answer text. An answer follows its
explicit quote lines without a blank line; user rendering therefore
does not apply CommonMark lazy quote continuation. Assistant Markdown
keeps its normal rule. koa supplies no annotation-producing model.

Topics belong only to the root. `koa/text.ts` scans markers and
`koa/records.ts` validates names. A name is a short topic, as in
Zulip, not a slug: the models are asked for at most 60 characters,
and validation accepts up to 200 without `]` or control characters,
with whitespace normalised. Names match exactly, because the agent
continues a topic by repeating its name. The agent labels its own
text. Tool and thinking blocks follow the last label in the turn.
Agent and job details carry the root's assignment. Children do not
receive that label as a task marker.

A user message to the root gets its marker before pi sees it, so the
agent starts from the right topic (`Tree.labelPrompt` in
`koa/koa-agents.ts`). This covers the page's prompts, steers and
follow-ups, the command-line messages and `ko prompt` to the root;
not subagents, messages between agents, a resent queue item, a slash
command, empty text or a text whose topic a filter or a typed marker
already decides. First, quoted lines that match reply sections of
exactly one topic among the recent replies select that topic
without a model call; this works also when the classifier is off.
Otherwise a small model classifies the message
(`koa/koa-classify.ts`) from the newest topics and their newest
messages. The setting `koa.topics.model` in pi's global settings is
`provider/id` or `off`; the default is on. The classifier runs without reasoning,
no tools and a 15 s deadline, and the parser accepts the usual
wrappings of a name. A failure sends the message without a marker
and shows one warning for each process, with the raw reply in its
text; there is no retry. The agent still labels its own replies:
the classifier only gives it the user's topic.

Classification must not delay the user. The prompt is accepted and
shown as pending in the queue at once (`hold` in `koa/koa-queue.ts`),
before the model answers, and prompts are submitted in the order the
user sent them. A pending prompt keeps reload and restart waiting,
like a running turn. When the submission of an accepted prompt fails,
its text and attachments return to the composer through the editor
state, but only while the same pi session is current.

The user corrects topics with two session entries, which
`koa/topic-list.ts` folds into one derivation of the branch for
the transcript and the extension. `koa.topic-move` renames or
merges a topic: its names resolve to the target, and a chain of
moves resolves to its end. `koa.message-topic` moves messages, named
by their pi entry ids, to a topic; a move from a reply moves its
whole turn. Entry ids, not timestamps, identify messages, because
timestamps collide. pi emits `message_end` before it persists the
entry, so the transcript keeps each item's message object and finds
its entry id by identity when the user acts; an unpersisted message
cannot move. The transcript keeps the original labels of its items
and projects them through that derivation, so a live correction and a
replay agree by construction. A correction keeps the epoch, so open
pages keep their loaded history and position: the transcript compares
each item's projection before and after the entry, and sends each
changed item as a full item record with its next revision, then the
new topic list in the state record. A correction can change items
that a reconnect cursor has passed, so the transcript remembers the
corrected items of the epoch, and a cursor reconnect gets them again
before the missing items. The page ignores an item record below its
loaded history, or holds it while a history request is pending; its
later history page projects the current names. It takes an unloaded
item inside its loaded history, so an item that a correction moves
into the filtered topic appears in place. The page that renames a topic moves its own filter
to the target; another page with a filter on the old name clears it.

The root's prompt requires a marker and reuse of an existing topic
for related work. The root-only `list_topics` tool recalls active topics in
most-recent-use order, derived from branch messages and topic entries.
Its branch stores a name index, not a second copy
of each text label. Compaction sends the names in a hidden message
for the next run rather than changing the system prompt cache.
A missing marker produces a hidden correction for the next turn.

The transcript projects sections without marker syntax and keeps the
mapping back to pi's content indices. Images, tools and annotations
use that mapping. An annotation that crosses sections is dropped.
A partial last line that could become a marker is held until resolved.
A label learned after an item became final is a separate metadata
item, for the same cursor reason as annotations.

`koa/page/topics.ts` owns the page's topic state: the filter and
composer topic of each scope, the naming, rename and drag
interactions, the chips, the topic panel and the saved topic memory.
It asks the page for corrections and reloads; it does not change the
transcript or its history.

The page derives topic colors from order and keeps filtering local.
The live feed is not filtered. A run's filter membership follows the
topic of its first step that has a known topic; its notices and its
steps of other topics follow the run. A filtered older-history read
counts only text in the topic, so sparse topics can load useful
history. It does not return the whole range: a sparse topic's range
can hold thousands of records that the filter hides, and the page
would parse and project each. The transcript keeps an index of each
topic's counted messages and member runs, which it updates when a
record appends or changes, when a label arrives and when a
correction moves, renames or merges a topic, and which it builds
again on a rebuild. A filtered page holds the topic's counted
messages back to the quota, the runs in that range whose membership
is the topic, the whole run of each assistant record that it holds,
also a run of another topic that touches a matching message, until
no new run joins, and the topic and annotation records that they
depend on. A run is never cut, so the page filters history with the
same rule as the live feed and gets the same rows. The server and
the page share that rule, `koa/topic-run.ts`: run ownership, topic
membership and the counted message.

The page shows topics only in its own rendering: a header row on each
user and agent message holds the message's time and its topic's
chip, and a later section of a reply starts with a row of its own
chip. The feed carries no header, so the native app's feed does not
change. Under a filter the chips are omitted, because each would name
the same topic.

The composer's topic and the transcript's filter are two separate
states of the root view, each kept per session in the page's history
state, so both survive a reload. A click on a message's chip sets the
composer's topic; it does not filter. Only the topic widget sets and
clears the filter, and setting a filter also sets the composer's
topic. A filter that is active without a composer topic, such as
one restored from the history state, gives the composer its topic,
unless the user set or dropped the composer's topic after the filter.
Clearing the filter also drops the composer's topic when it is the
filtered topic; a different topic that the user chose after the
filter stays. The composer's × drops only the composer's topic. The
composer's topic, not the filter, labels a submitted prompt: the
prompt gets a marker and the classifier is not asked, except for a
slash command, because pi needs the slash at the start to expand a
template or skill. The topic stays after a send, so the next prompt
goes to the same topic. Take-back hides the inserted marker. Child
and job views have no composer topic: only the root takes topic
labels.

The topic panel shows for each topic the first line of its newest
non-empty user or assistant message. The user drags a topic row onto
another row to merge it, double-clicks a row to rename it, and drags a
row onto a message to move its turn. The page and the transcript
select a turn's messages with one rule, `koa/topic-turn.ts`, in seq
order. A message is a drop target when its turn has ended and, without
a filter, when some message of the turn has another topic; under a
filter the page does not hold whole turns, so the server decides. A
rename, a naming or a drag acts on the session and view where it
started; a change of view or session, or a reset, cancels it without
a commit. Rename to an existing name is a
merge, and a filter on a merged topic follows to its target. A
single click filters only after the double-click interval, so a
rename does not filter. Long names are cut on the page with the whole
name in the title. The visual rules of these interactions are in
`app/design/koa/NOTES.md`, "Topics".

The user names a topic with the "+ topic" chip. In the composer it
sets the composer's topic and writes nothing to the session. A new
topic exists only when a message carries it. On the header of a
message without a topic it moves the message's turn through the same
`koa.message-topic` entry as a drag. A message with a topic, or a
reply with a topic in any section, has no "+ topic": a drag from the
widget changes its topic. A name that no topic has yet creates that topic, so the
move route accepts any valid name. There is no slash command for
topics.

Archiving hides a topic from the classifier and from the line-mode
capsule. The topic stays in the panel. A `koa.topic-archive` entry
records each archive and restore. `koa/topic-list.ts` folds these
entries in branch order together with the moves, so a replay and a
resume agree. A rename keeps the archived state of its source. A
merge keeps the state of its target, because the source ends there.
A topic counts as an existing target when the branch before the move
uses it in a message. A name that only the index holds does not count.
Only a restore clears the archived state. A message, a move, a merge
or an agent label that goes into an archived topic leaves it
archived. The classifier gets no archived topic in its context, and
the quote match ignores archived topics. An answer that resolves to
an archived topic is a classification failure, so the message goes
without a marker. The archive route is serial with the prompt routes,
so an archive cannot land while a prompt waits for its
classification. Archived state reaches the page as an optional field
of the root state's topics. No feed item changes and no reset occurs.

## Agent extension, subagents and jobs

### Extension boundary and identity

`koa/koa-agent.ts` is an inline factory of koa sessions only. It has
no terminal widgets, renderers, input handlers or autocomplete
providers. It takes pane identity, ko, browser mode and runtime facts
from `AgentHost` in `koa/koa-agents.ts`, not from pi's UI mode.
Shared data and helpers live in the modules that both sides use;
program modules are reached through the host interface, not imported
into the extension for side effects.

The extension has no state directory of its own and does not read
ko's socket or state directory. It imports shared data modules and
host types, not koa's program modules. Its settings use the `KO_*`
prefix; host launch controls are separate.

The host owns everything that must outlive one factory invocation:
the tree, inbox, status publisher and each agent's jobs. The extension
owns tools and pi event handlers. Its ko calls are asynchronous,
except synchronous process-exit cleanup. A blocking call would stop
all agents and delay inbox acknowledgements.

The root publishes session identity and name as pane variables and
conditionally removes them only while the session still owns them.
It removes the optional activity variable but does not write activity.
The host writes root status and title from the root session, regardless
of the selected view. Subagents use status records, not pane variables.
Discovery trusts ko's classified koa-agent status, not a stale variable
on a shell. Resume liveness also checks a live pane's held session id,
since a starting root can be absent from status.

The ko skill is discovered only where the extension's host tools can
use it. A routed session does not advertise the host skill path.
The skill adds guidance, not a new tool or server route.

### Addressing and messages

An agent address is a pane plus a pi session identity. The local tree
supplies in-process relations. ko supplies the sender pane and pane
relation for a cross-pane message. The harness carries an in-process
sender or target in message data; the server does not interpret it.
`koa/koa-inbox.ts` validates and dispatches the pane's one stream.

Scope consists of own children, siblings, ancestors and their siblings,
plus the root agents of peer panes in the ko session. Other panes'
subagents do not list by name. An explicit pane/session address from
a received message can reach one. Report reads are restricted to own
children. `koa/agents.ts` supplies the shared discovery forms used
by tools and page completion.

Address resolution prefers an exact case-insensitive name, then an
exact identity, then a unique sufficiently long session prefix. Each
step prefers live agents and reports ambiguity. A full mention uses
its parenthesized identity so a reused name cannot capture it. Name
validation and prefix limits are in the extension and shared module.
Registered child names are addresses; changing a session title does
not rename its registration.

A normal message queues for the next turn; a steer can interleave
with current work. Interrupt-and-steer holds its text, aborts, then
delivers at settlement. pi's abort call returns before the run ends,
so sending the new work immediately could lose it in an aborted queue.
An idle receiver starts a turn. Notices and job batches steer. Only
user prompts enter as the user's own words; agent messages identify
their sender and relation.

In-process delivery is a host call with no retry transport. A
cross-pane send keeps one id for one intent across retries. The inbox
acknowledges only after handing the message to its target, and retains
a bounded ring of accepted ids across stream reconnects. A repeated
id is acknowledged without a second delivery. Invalid or unavailable
targets are refused. Reload holds messages without closing the stream.
The extension never pastes model text into another pane.

The host dispatches user prompts by status-record address. User
selection and close actions control views and subagents; a pane-sent
selection or close is ignored. Closing a child from the sidebar stops
its subtree and informs its parent. Closing an unknown agent record
clears that record. A stop message for the pane shuts down the root.

### The registry and reporting

The extension stores durable child, peer, work and report facts as
custom entries in its own pi session. `koa/koa-agent.ts` defines the
entry codecs. Reads use the active branch and check the owner session,
so a fork does not inherit another session's children and reports.
The child's edge is written before extensions bind. The repository's
git-write guard reads that owned edge.

Report state is derived from branch order: a child's last report must
follow its last work and must not be interim, or it must have no work. The child reads this
fact through its parent; there is no duplicate child-side store.
Work includes text sent by the user in the child's page view.

A child reports the final text of a turn that ends without a tool
call, when it has work to report, no non-service job running and no
live own child that owes a report. It reports when the run settles. A
turn's end also reports when external input is queued, whoever sent
it: a message or steer from the parent, a sibling, a peer or an agent
with no relation, or a steer or follow-up that the user typed in the
child's page. pi starts the next turn in the same run and settles
only after that turn, so the earlier result would be lost. Each
queued input is consumed only when that input starts. That turn's own
final text is a further report. A report made while work input is
still queued (the parent's, the user's or an agent's plain text) is
interim: the parent records and shows it, but it does not cover the
work, so the child still owes a report and stays live work for its
parent until a report made with no work input queued. Otherwise the
parent would end its own turn and report while the child still works
on the queued input. A sibling's or peer's message is not work for
the parent, so a report that only it released is complete. Input that the child queues for itself, such as
a job's notice or output, a child's report or a system notice,
continues its own work: its turn's end waits for the settle. Aborted or
interrupted turns do not report. Provider errors send an error notice
instead. Empty or repeated text does not duplicate a result. While
live work holds the report, a later final text replaces the held
one. A job's end that sends a notice starts the turn that reports. A
stopped job sends no notice, so only its end checks whether a settled
child can now report the held text.

The parent records the report before delivering its capped notice.
`read_report` reads the stored text. Reporting does not end a child;
it stays alive until explicitly stopped or its koa ends. A child that
waits for a peer or other external event can report that wait, because
the host cannot infer unfinished work outside its own tree and jobs.

### Spawn, resume and peers

A fresh child defaults to the caller's model and thinking level.
An explicit model is resolved against pi's registry. A resumed or
copied session defaults to the model and thinking level saved on its
active branch, with the caller as fallback only when none is saved.
The extension reads this without opening the file for writing.

The host creates a child runtime and view before binding extensions,
so startup dialogs can be answered. It then delivers the task without
putting task text in argv. The tree enforces its depth limit. A child
in the same trusted git common directory can receive a one-directory
trust grant from its spawner; other directories use pi's trust rules.
The grant is not saved and is not a security boundary against the
agent that chose the directory.

Child files live outside pi's top-level session search tree, under
the agent directory's subagent area. `childSessionDir` in
`koa/koa-agents.ts` defines the path. A copied file goes to the new
role's directory; a continued file stays where it is. A session that
has never saved a turn has no file to resume.

Continue preserves identity, history and recorded directory. Copy
uses pi's fork operation with a new identity and requires a task.
Continue refuses a live session or a conflicting relative and keeps
an own child's registered name. A per-session process lock protects
check and creation. Two different koa processes can still race to
resume the same saved file; there is no cross-process file lease.
An empty task is allowed only for a continuation and starts no turn.

A normal message to an ended own child resumes it with that message
as its next work. This is also how children return after a koa
process restart. Steer modes cannot resume an ended child. A stopped
subtree is marked stopping before disposal, so it accepts no new
message or spawn and sends no report. Disposal runs deepest first.
Stopping an ancestor is deferred until the caller's tool returns.

A top-level spawn creates a pane through ko's typed koa command.
It has no parent edge, report obligation or subagent lifecycle. The
initial task is a pane variable that the new root consumes and removes.
It takes its spawner's browser mode. It cannot convert an existing
own child into a peer. Server-side launch and placement rules stay in
[design.md](design.md#starting-a-koa-agent).

A root outside a runtime observes peers with a non-sizing, unfocused
client stream. Changed peer facts append to its registry without
notifying the model. The page's agent rows (the `agents` of its
state, which make `@name` links) derive from the selected agent's
scope. They are derived again, from a fresh pane list, when this
stream applies a change of the panes, so a peer that writes its name
after its spawn or resume ended still becomes a link. View switches,
agent-tool ends and displayed custom messages also derive them. At
most one derivation runs for each agent; changes during it cause one
more. The state is published only when the rows changed. A refused initial connection stops retrying;
a transport disconnect reconnects. A peer that begins and ends while
unobserved is not recorded. An inside-runtime root cannot open this
client stream. A saved ended peer can restart as a new top-level pane
through a normal message, on its saved model and recorded routed
runtime. The starting-pane record prevents duplicate starts within
one process, not between two roots.

Stopping another pane requests shutdown through its inbox and then
uses ko's pane-stop route. A target without an inbox needs explicit
force. Force is not available for an in-process child. A stop's result
is the only ending signal; it generates no child report.

### Background jobs

`koa/koa-agent.ts` owns the job registry, process handles, logs,
stream batches and ending notices. `async_bash` starts a background
job. The replacement for pi's built-in bash tool can move a long
foreground call into the same registry. Another extension's bash and
user `!` commands are not wrapped.

Local jobs use pi's shell configuration and their own process groups.
Routed jobs own a `ko api` exec child. The foreground form also has a
registry record, so stop and abort use the same signal owner. A move
returns a successful handoff, not a timeout failure. An explicit
short timeout stays a foreground timeout; a longer timeout follows
the job as its deadline. A foreground call that crosses extension
reload is handed off because its old instance cannot finish it.

Both pipes write one private log in arrival order, with no size cap.
The in-memory tail is bounded. A moved call begins its log with the
retained tail and marks any missing earlier output. Logs remain after
the job ends; the temporary host storage policy removes them, not
registry pruning. Pipe back-pressure follows the log writer.

An ordinary end delivers one notice through the current extension,
with the ending and a bounded cleaned tail. A stop suppresses that
notice. Every running job and every unannounced end remains listed;
only announced ends are pruned to the retained history limit. Names
can be reused after a job ends; name lookup prefers a running job,
then the newest ended one.

A service is intended to keep running. It does not hold a child's
report and its status is idle, not working. It still has logs, stop,
ending notices and restart-deferral behavior. A moved bash call is
not a service.

Streaming sends cleaned lines in bounded batches. During work, a due
batch goes at a tool boundary; while idle, a timer can deliver it.
A failed delivery keeps the held text for retry. The final partial
line and held lines go before the ending notice, without the normal
throttle. Escape stripping is not a terminal emulator; raw bytes
remain in the log.

Jobs survive extension reload because pipe listeners write plain
registry data and only the current extension calls pi. A new instance
delivers the output and endings held in the gap. Session replacement
and shutdown stop jobs instead. Do not keep a stale extension context
in a child-process callback.

### Status records and signals

The subagent and job records are derived, never written one by one.
`deriveRecords` in `koa/koa-status.ts` is a pure function from the
tree (each agent's view, life, dialogs and the selection) and each
agent's retained jobs to the whole record set of the `agents` and
`jobs` subtrees. Every revision contains each record's ancestors by
construction: a record of a stopped or stopping agent's subtree is
not in it, so no job completion can restore that subtree. A report
does not remove an agent's record; the agent stays a live member that
can take another turn. Subagent records are selectable, closeable and
promptable; job records are selectable and closeable. Paths encode
tree nesting, but only the harness interprets their agent/job
meaning. Root status is OSC and is not part of the derivation; it
continues to name the root while the user views a child or log.

The root record's message is the first line of the latest user or
assistant message with visible text, by the order of their ends; a
slash command is not such a message. Only the end of such a message
changes it. The state (working, idle, done, error) changes on its
own and keeps the message: an error turn sets the state, not the
message. A session switch, new session, resume or reload takes the
latest such message of the loaded branch, or the agent's name when
there is none. An open dialog's title replaces the message while the
dialog is open.

One publisher sends each revision as one `replace_subtrees` of
`agents` and `jobs` (protocol.md, section 6), so ko never holds a
child without its parent and a restarted koa replaces its
predecessor's rows in its first publication. Any change of a
derivation input marks a new revision. The publisher coalesces the
revisions that arrive while one is in flight, sends only the newest,
and does no I/O when the derived set equals the one ko acknowledged.
The acknowledged set is unknown from the start of each POST until its
successful response, so a lost response never hides a later revision
that returns to the earlier set. A failed revision is retried a
bounded number of times and then logged and abandoned; the next
change starts a new revision. Exit cleanup sends an empty
replacement synchronously. Publication needs only the pane identity,
also with `--browser`.

The budget is pane-wide: ko's `status_record_limit` from
`GET /version`, less one slot for the root and the pane's records
outside the two subtrees. The derivation fits the budget by removing
whole entries only: first the lingering finished jobs, oldest first;
then it admits agents parent first and the remaining jobs of admitted
agents. It never publishes more records than ko keeps, so ko's
eviction never cuts a subtree. A 409 for capacity, because another
writer added records, makes the next attempt read the pane again.

A finished job's record lingers for `KO_JOB_RECORD_LINGER_MS` only
while not watched. An event-stream subscriber, selected or named,
retains it; selection without a subscriber does not. A keepalive
detects a lost subscriber. A dismissed job leaves the derivation.
Omitting a row does not stop the job.

`signalJob` accepts only a registry job, never a pid supplied by a
tool or message. It signals a local group only while its owned child
has not been reaped. A routed stop signals its own ko child, whose
connection end cancels the remote exec. The harness does not send a
remote signal frame or search for escaped descendants.

Stop first requests termination, then escalates at its deadline.
Readers stay open long enough to drain the child's final output.
After escalation, pipes held by an escaped process can be closed so
the job can finish. The result distinguishes a completed stop from a
request that is still pending. A process that leaves its group can
survive, and an uncatchable kill of koa can orphan a detached local
job because exit cleanup cannot run. These are accepted limits, not
reasons to signal unverified pids.

## Host and runtime execution

Runtime placement and the exec security boundary belong to
[design-runtimes.md](design-runtimes.md#agents-in-a-runtime). The
extension implements the harness side in `koa/koa-agent.ts` and
`koa/runtime-exec.ts`.

A routed koa remains on the host. Its pi session, credentials,
extensions, skills and prompt templates remain there. The routed-tool
set in `koa/koa-agent.ts`, user shell commands and background jobs
execute in the runtime. Other extension tools, MCP and codemode stay
on the host; the runtime prompt names that boundary instead of
pretending all tools moved.

Routed tools preserve pi's tool contracts over runtime operations.
Grep has its own implementation because pi's implementation otherwise
starts the host's search program. Paths are argv values and writes
use stdin. Execs do not inherit host credentials or the host
operations' environment. The runtime's login environment and request
policy decide the command environment.

The runtime cwd comes from the longest host path mapping, then the
runtime's configured directory, then a runtime probe. Absolute paths
under a mapped host prefix translate; other absolute paths belong to
the runtime. Relative paths resolve from the runtime cwd. The mapping
must agree with the server's path rule.

Runtime context loading begins at session start and reload. The first
prompt and routed operation wait for it. The context keeps global
host instructions and reads the runtime's directory instructions in
pi's order. An exec can start a down runtime; a runtime information
read does not. A missing runtime or a runtime configured for inside
koa leaves the session available but refuses routed operations. A
failed runtime can retry on the next exec. Refusal never falls back
to executing a command on the host.

The root publishes routed placement for clients under koa's identity
trust rule. The extension also writes the generic runtime variable;
clients do not use that untrusted generic variable for placement.
Messages can identify a routed sender's runtime. The server does not
interpret that message data.

An inside koa runs with pi and its files in the runtime. Its image
needs koa, Node and pi; ko's static layout supplies no harness.
Its children are sessions of that same process. It cannot select
another runtime for a child. A host koa can make a routed child but
cannot make an inside child in another process: that would be a pane,
not a subagent. A top-level spawn can use either placement.

Host file completion remains host-side in a routed session. Shell
completion uses the resolved execution context. Job logs, uploaded
non-image attachment paths and step-preview reads are also on the
koa host; a routed tool can read such a file only through a suitable
mapping. The page's byte upload does not transfer a file into a second
runtime filesystem.

## Kido.app and browser embedding

Kido.app embeds the page, not the Node program or pi. It does not
bundle koa. New Agent asks ko for a typed koa command; the server's
login shell resolves the installed executable. Native pane layout,
focus, Command keys, theme injection, navigation policy, Quick Look
and hidden-view retention remain app behavior in
[design-app.md](design-app.md#webview-panes).

The app's webview sandbox treats every page as untrusted, including a
local koa. koa must not depend on general network or host file access
from the page. The page calls its own HTTP origin. `window.ko`
supplies only the app bridge and theme facts defined by
`app/App/WebviewPaneView.swift`. It is not a route to ko's API.

The page uses the app's theme properties when present and its own
light/dark fallback otherwise. The native app owns menu key routing.
The page's find and quote hooks let native actions work with a
virtualized transcript without giving the app a second transcript
model. A background page cannot use the focus bridge to select a pane.

A released hidden webview reloads from koa. Durable session and job
state therefore belongs to the host, not the page. Folds, drafts,
filters and scroll memories can be page-local only where losing them
on a page reload is part of the design. A live hidden page uses its
timer path to keep rendering state current without animation frames.

Browser mode runs the same server and page but has no `window.ko`,
native theme or native sandbox. Agent links within the process still
switch views; links to another pane have no native focus action.
The page supplies browser quote keys, a lightbox and fallback colors.

## Release

koa has its own Homebrew formula and release cadence. ko, ko-bin and
Kido.app do not include it. The formula installs the architecture-free
built launcher/share tarball and depends on Node and pi, not ko:
Kido.app or a ko installation supplies the latter. A remote host or
runtime can unpack the same tarball into a prefix on its PATH.

After the commit is on origin/main with green CI, the top-level
release session runs `scripts/release.sh koa VERSION`. The script
checks the packed paths, compares the prompt snapshot's tool names
with the formula's release, rebuilds `build/koa/`, packs the tarball,
creates the tag and GitHub release, and updates the tap formula.
A removed or renamed tool requires a minor version increase.
The script never upgrades the user's installation.

`--dry-run` does not publish, but still builds and packs. Do not use
it as a no-build inspection command. The release workflow and its
approval rules are in `.pi/prompts/release.md` and
[release.md](release.md). When the generated ko API changed since
koa's last release, release the matching koa with ko or Kido.app and
tell users to upgrade both. koa has no version gate or compatibility
fallback for a mismatched API.

New panes resolve koa from the login PATH. Existing panes can reload
extensions and the page in place and replace their process when the
installed koa program changed, subject to the reload rules above. An explicit restart
also reloads the installed pi SDK. A pi-only upgrade does not change
koa's content hash and therefore does not itself trigger automatic
process replacement on reload.

Undone work is tracked in `plans/koa.md`. It is not a description of
current behavior.
