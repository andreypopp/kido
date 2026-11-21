# koa: design and development

koa is Kido's pi harness. It runs pi sessions through pi's SDK in
one Node process and shows one HTML page in a pane or a browser.
This file owns the design of koa, its page, its agent extension, and
its development and release procedures.

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
A reload requires every agent to be ready and idle, with no pending
user queue, dialog, user shell command or external editor.

After that reload, `koa/koa-identity.ts` compares the installed
program, page and webview SDK with their startup content hash. A failed hash
read does not trigger a restart. If files changed, koa restarts only
with a saved root session, no running jobs, no child that owes a
report, and no new busy state. Services also block this restart.
Otherwise a notice explains the deferral, and a later reload can try
again. Node's module cache makes a process replacement necessary for
a change to koa's own extension factory.

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
asset. koa assembles the document at startup and serves that copy for
its lifetime. It also reads the shell-completion script at startup.
An install must not pair a running program with new page code.
The development reload option is described below.

The document carries koa's instance identity. Each event stream open
sends it back. A different identity gets a reload record rather than
new state for an old page. This also covers hidden pages and browser
back/forward restoration. It is a reload boundary, not support for
old record formats.

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
a missing anchor opens at the end. A page load clears this local
memory. Selection is not persistent session state.

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
answer later arrives.

A reconnect sends the epoch and the last final item, not
Last-Event-ID. Patches change unfinished items, so an event id would
be the wrong cursor. A current cursor gets the missing items; another
epoch gets a capped reset window. Older history uses the same window
limits. The page asks for older history when its top comes into view. After
the first page, each older page and a thread reload, it asks for the
next older page while its top is still in view, so a window that the
rows do not fill fills itself; a failed page stops this until the next
scroll. A slow page whose output queue exceeds the feed cap is
disconnected and can catch up; it does not block other pages.

An exception while applying a record is different from a transport
failure. The page closes the feed and asks for a reload. Automatic
reconnect would apply the same bad record over partly changed state.
Transport loss and revision gaps have their explicit recovery paths.

### Runs, Markdown and rendering

A run is page presentation, not a feed record. It groups consecutive
thinking, tool, agent and job steps between visible prose or user
messages. A notice joins an existing run but does not open one.
Whitespace-only text and hidden metadata do not split a run. A gap of
unloaded history does. `koa/page/extent.ts` assigns each run one owner
for rendering, positioning, unread counts and find.

The grouping is independent of turn boundaries. A report received
while idle can join the last run. Thread filtering does not regroup
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
every token. The frame reads needed geometry before its writes and
renders each changed item once. ResizeObserver supplies measurements
for later work. Hidden pages use a timer because WebKit pauses their
animation frames. A visibility change transfers pending work between
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

`koa/page/scroll.ts` is the one scroll owner for transcripts and job
logs. It is a pure state machine. DOM code supplies events and
measurements and applies its decisions. Browser scroll anchoring is
disabled to avoid a second owner.

Following keeps the bottom exact after layout while the pane has
focus. Reader input establishes an item anchor. Layout changes above
that anchor preserve its offset and any intervening reader movement.
A scrollbar jump into unmounted space uses the position table to
mount the destination. A fold toggle holds its header at the same
screen position and ends scroll travel.

The follow slide is a transform of the transcript, not an animated
scroll. It smooths growth without competing with bottom correction.
Instant causes, such as a reset, restore or resize, only update its
baseline. A clipping wrapper prevents the transform from changing
the scrollable extent and feeding back into the next measurement.

A hidden or unfocused following page becomes a reader when new
content or layout moves the bottom. Focus alone never resumes
following. The user's send and Latest do; a reset opens a following
view at the end even in the background. New-content counts use
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
lines and thumbnails.

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

### Reply annotations and threads

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

Threads belong only to the root. `koa/text.ts` scans markers and
`koa/records.ts` validates names. The agent labels its own text; no
second model classifies it. Tool and thinking blocks follow the last
label in the turn. Agent and job details carry the root's assignment.
Children do not receive that label as a task marker.

The root's prompt requires a marker and reuse of an existing thread
for related work. Its branch stores a name index, not a second copy
of each text label. Compaction sends the names in a hidden message
for the next run rather than changing the system prompt cache.
A missing marker produces a hidden correction for the next turn.

The transcript projects sections without marker syntax and keeps the
mapping back to pi's content indices. Images, tools and annotations
use that mapping. An annotation that crosses sections is dropped.
A partial last line that could become a marker is held until resolved.
A label learned after an item became final is a separate metadata
item, for the same cursor reason as annotations.

The page derives thread colors from order and keeps filtering local.
The live feed is not filtered. Older-history reads filter before
window limits, so sparse threads can load useful history. A filtered
prompt gets a marker at submission, except a slash command: pi needs
the slash at the start to expand a template or skill. Take-back hides
the inserted marker. Runs remain whole under filtering.

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
the tree, inbox, record writer and each agent's jobs. The extension
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
follow its last work, or it must have no work. The child reads this
fact through its parent; there is no duplicate child-side store.
Work includes text sent by the user in the child's page view.

A child reports the final text of each turn that ends without a tool
call, when it has work to report, no non-service job running and no
live own child that owes a report. The report goes at the turn's end,
not when the run settles: a message queued while the turn runs starts
the next turn in the same run, and pi settles only after that turn.
That turn's own final text is a further report. Aborted or
interrupted turns do not report. Provider errors send an error notice
instead. Empty or repeated text does not duplicate a result. While
live work holds the report, a later final text replaces the held
one. A stopped job sends no notice, so job ending also checks whether
a settled child can now report the held text.

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
notifying the model. A refused initial connection stops retrying;
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

The tree's ordered record queue is shared by agents and jobs.
Subagent records are selectable, closeable and promptable; job records
are selectable and closeable. Paths encode tree nesting, but only the
harness interprets their agent/job meaning. Root status continues to
name the root while the user views a child or log.

Finished job records linger only while not watched. An event-stream
subscriber, selected or named, keeps the viewed record; selection
without a subscriber does not. A keepalive detects a lost subscriber.
The per-agent admission cap can omit a new row when all slots are
occupied by running or watched records. Omitting a row does not stop
the job. Starting a tree clears its agent and job record subtrees
before publishing new records, so a process restart does not leave
live-looking rows from its predecessor.

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
Passing a browser test does not prove the native bridge works: body
transport, focus, keys, clipboard and previews need native tests.

## Development

### Source layout and types

Start at these owners rather than duplicating their contracts:

- `koa/koa.ts`: program startup, HTTP dispatch and view selection.
- `koa/koa-agents.ts`, `koa/koa-view.ts`, `koa/koa-inbox.ts`: agent
  lifetime, session projection and pane message delivery.
- `koa/koa-agent.ts`: tools, registry, routed operations and jobs.
- `koa/koa-records.ts`, `koa/records.ts`: page records and extension
  details. `webview/ko-api.d.ts` is generated from ko's schema.
- `koa/page/`: page composition, editor, Markdown and pure rendering
  models. `koa/page/page.html` is the real DOM structure used by tests.
- `webview/index.ts`: pane and browser transports.
- `koa/testdata/`: fixtures, replay, scenarios, fake ko and prompt
  snapshot.
- `app/KoaSnapshots/`: shared WebKit state driver and image comparison.
  `app/KoaHost/` is its host command-line runner.

`koa/package.json` and its lockfile pin the build and test dependencies,
including the real pi used by tests. TypeScript checks the Node side
with `koa/tsconfig.json` and the page with `koa/page/tsconfig.json`.
The page check has DOM globals only. Keep type-only ko imports at the
boundary; do not hand-copy API shapes.

### Build, install and run

Install the released harness with Homebrew:

```sh
brew install andreypopp/tap/koa
```

For a checkout, koa builds independently of cargo and git:

```sh
make -C koa
build/koa/bin/koa --help
build/koa/bin/koa --browser
make -C koa install PREFIX=/path/to/prefix
```

`koa/Makefile` is the installed-file manifest. Its output in
`build/koa/` has a launcher and a share tree with the program, built
page, extension, skill and webview SDK. The program and SDK remain
TypeScript; only the page is bundled. The bundle is unminified for
WebKit inspection and is not committed. The checkout and installed
share tree keep koa and webview as siblings so relative imports agree.

Run the built launcher in a pane for the native page. Outside a pane,
use browser mode. Select a different pi executable with koa's pi
option. The program loads that executable's package, so a development
pi and the test pin need not be the same installation.

For page-only iteration:

```sh
make -C koa watch
```

In another terminal, start the built launcher with
`KOA_PAGE_RELOAD=1`. Reload Page then assembles from the rebuilt
assets. The watcher updates page assets, not a running Node module
cache. Program or extension changes need a build and process restart.
For an installed preview, put the preview prefix's bin directory
before Homebrew in the login shell's PATH. New Agent resolves that
PATH at each start; changing only the server's old environment is not
the selection mechanism.

Use a private ko server under `/tmp` for integration work. Do not
stop or change the live server that runs the developer's pane.
Native app test prerequisites and the VM are in
[build.md](build.md#the-visual-test-vm).

### Choose the test boundary

Use the narrowest test that observes the rule:

- Pure parsers, queue matching, scrolling, Markdown, extents and
  annotation conversion belong in the corresponding
  `koa/koa-*.test.ts` files.
- DOM presence, order and event handling belong in
  `koa/koa-dom.test.ts`. Its fake document uses the real page HTML
  but does not implement CSS layout. Drive its frame, observer and
  clock seams for reveal behavior; do not assert browser geometry.
- Extension tools and registry behavior use
  `koa/koa-agent-fixture.ts`. These tests have a fake pi and host,
  plus the typed fake ko. They do not need a real model session just
  to inspect tool registration.
- Session, startup, reload, switch, route and feed behavior use
  `koa/koa-program-fixture.ts`: real pinned pi in koa and a scripted
  model. This catches SDK event-order assumptions that a fake pi
  cannot establish.
- Page appearance and browser-computed geometry use the replay-driven
  WebKit cases. Host-state changes alone should not rewrite page
  snapshots.
- Native focus, menus, editor floats and the real serve path use
  app integration tests in the VM. Browser mode is not their substitute.

`scripts/test-ts.sh` installs pinned dependencies when needed, builds
fake ko and koa, checks types, and runs the Node suite. With no file
arguments, `koa/testdata/run-tests.mjs` schedules the suite with long
files first. With file arguments it runs only those files after the
build and type checks:

```sh
scripts/test-ts.sh koa-scroll.test.ts
scripts/test-ts.sh koa-program-session.test.ts
scripts/test-ts.sh koa-webview-sdk.test.ts
```

The script scrubs pane identity from the test environment. Fixture
children get private home and agent directories. A gate waits for a
test action, not elapsed time. Follow the repository's bounded-wait
and no-repeat rules in `AGENTS.md`. Final unit verification uses
`make checks`; inspect its plan with `make checks DRY=1`. Run koa
visual checks with `make -C app koa-host` on the host.

### Fake ko and fake model

`koa/testdata/fake_ko/` is a Rust workspace member built by
`make build-fake-ko`. It decodes and encodes real ko protocol types,
so wire changes fail its build. Files drive message arrival and gates;
stdin receives acknowledgements. Deliberately malformed messages use
the fixture's raw-feed path. Runtime exec tests run the requested argv
with only the requested environment. A separate integration case
checks the same exec client against a real command runtime.

`koa/koa-fake-provider.ts` is an HTTP model provider, not a fake pi
process. It speaks the OpenAI completions stream and scripts text,
thinking, tool argument chunks, errors and held replies. It rejects
unexpected request methods, paths, authorization, models and script
exhaustion and records violations. Tests release named gates and check
requests. Private model settings use a literal test key, so no real
credentials or model service is needed.

Use real session files for saved history and small test extensions
for dialogs, startup UI and extension errors. Do not enlarge a fake
model to invent host facts.
`koa/testdata/ko-prompts.txt` snapshots extension prompt text;
`make prompts` regenerates it when that text intentionally changes.

### Replay scenarios and snapshots

`koa/testdata/replay.ts` is a test server, not a product mode. It
serves the built page through `assemblePage` and the SDK without
loading pi. `koa/testdata/scenario.ts` types scenario steps against
PageRecord and `koa/page/http.ts`. Shared scenario data belongs in
`koa/testdata/scenario-parts.ts` only when several scenarios use it.

A script opens with records, then expects either an explicit advance
or one page request. A request step can send records before and after
its typed reply, and hold that reply until released. Unexpected method,
path or checked body produces a mismatch, not a successful default.
The test must finish with every step consumed, no mismatch and no
held reply. File and attachment requests use the product's serving
modules rather than a permissive mock. `koa/koa-replay.test.ts`
checks this harness.

Add new states as typed steps under `koa/testdata/scenarios/`.
Stable path names and explicit clock seams make captures deterministic.
A new state does not require a model recording or a product test flag.
Use one fixture with multiple phases for related states and resize it
for width changes instead of restarting the whole chain.

`app/KoaSnapshots/Cases.swift` assigns capture policy;
`app/KoaSnapshots/Capture.swift` crops the union of matched selectors
at the image's backing scale. Missing or out-of-page rectangles fail,
not clamp. Insets include borders and shadows. Most images cover a
component; composition anchors cover the whole page. Geometry-only states keep their
assertions without a redundant image. Capture stable states, not an
uncontrolled animation frame.

`WebviewPaneTests` checks the generic sandbox and WebKit constraints.
The test files, not a duplicated method list, define coverage.

### Host visual checks

`make -C app koa-host` runs the shared state driver in an off-screen
WKWebView without an XCTest host or an app window on the screen.
`app/KoaHost/main.swift` uses prohibited activation and fails if the
run changes the active application. It starts headless replay without
opening a browser. koa visual checks run only on the host, not in the VM.

Its references are local to the host macOS build under
`app/build/koa-host/`, not committed references. Record them with
`RECORD=1`; select a fixture or capture with ONLY. All phases of a
selected fixture still run. A geometry-only fixture must be named
explicitly. COMPARE can additionally report differences from committed
references, but those differences are informational. Native-only
states are reported as skipped. Image comparison uses the color-space
conversion in `app/KoaSnapshots/Pixels.swift`.

```sh
make -C app koa-host ONLY=Fixture
make -C app koa-host ONLY=Fixture RECORD=1
```

Use actual names from the driver. Record affected host images once
after the last implementation and review change, then inspect them.

### Measurement

`koa/page/metrics.ts` instruments only metrics mode. The report
separates receipt, frame scheduling and frame work; a frame timestamp
is not proof of completed paint. Timing and probe passes are separate
because DOM instrumentation changes cost. The probe counts geometry
reads after writes and working-mark detachments. Chrome heap and
WebContent physical footprint are different measures and must not be
compared as the same quantity.

Loaded history remains in the model while DOM windowing limits
mounted rows. Measurement must distinguish those two costs.

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
extensions in place and replace their process when the installed koa
files changed, subject to the reload rules above. An explicit restart
also reloads the installed pi SDK. A pi-only upgrade does not change
koa's content hash and therefore does not itself trigger automatic
process replacement on reload.

Undone work is tracked in `plans/koa.md`. It is not a description of
current behavior.
