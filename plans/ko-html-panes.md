# HTML panes and inline HTML blocks

A plan. Nothing of it is built. When the work is complete, the agreed
design moves into `docs/design-html.md` and the sections of the docs
that it touches, and this file is deleted.

The idea: a program in a Kido pane shows HTML. It sends one escape
sequence to switch its pane into HTML mode, or to put one HTML block
into the grid among its text lines. Its page and data come from the
program itself, through ko. Kido.app renders the page with WKWebView.
Use cases: a markdown viewer, a diff viewer, pi's own UI, a log or a
table viewer, a form that an agent shows to the user.

## 1. Goals and non-goals

Goals, in priority order:

1. **A pane mode.** A program switches its pane to a page that fills
   the pane. The mode is pane state in the server: every client and a
   reattach see it, and it ends when the program ends.
2. **Inline blocks.** A program puts a page into the grid, N rows
   tall, between its text lines. The block scrolls with the history,
   as an inline image does.
3. **Live content without the pty.** The program serves its page and
   its data over HTTP, through ko. A page updates from a streaming
   response. The same path works for a remote server and for a pane
   in a runtime.
4. **A strict sandbox.** Any program, local or remote, runs JavaScript
   inside Kido.app. The page gets only its own pane's resources: no
   file access, no network, no other pane, no persistence.
5. **Kido's keys stay Kido's.** The app's Command keys, the sidebar
   and the palette work while a page has focus. `ko_tui` keeps its
   `C-a` table.
6. **Small for authors.** One escape with the grammar of OSC 7501, a
   plain HTTP server on a unix socket, and a `ko html` command that
   emits the escapes and bridges the socket.

Non-goals:

- A browser. A page cannot navigate to another origin, open windows,
  download, or reach the network. Links to `http(s)` are a decision
  of the user's configuration, not of the page (section 8).
- HTML in `ko_tui`. The terminal client shows the pane's terminal
  content and a hint (section 11).
- A DOM-based terminal, as DomTerm is. The grid stays libghostty-vt's.
  A page lives beside the grid, never inside a cell.
- WebSockets from a page. WKURLSchemeHandler does not intercept `ws:`
  (section 7). A page streams with `fetch`.
- A page that outlives its program, or survives a server restart.
- Pages of one pane that talk to pages of another pane.

## 2. Prior art

- **DomTerm** inserts HTML with `OSC 72 ; html BEL` and replaces an
  earlier fragment with `OSC 721 ; key ; html BEL`, after a
  safety scrub of elements and attributes
  ([wire protocol](https://domterm.org/Wire-byte-protocol.html)).
  It is a DOM terminal: every cell is a DOM node. Kido takes the idea
  of a replace key (a block id) and rejects the DOM terminal and the
  scrubbed-HTML model: a scrub is a security boundary that moves with
  every browser release; a process boundary with no network is not.
- **Wave Terminal** shows files and HTML in blocks of its layout
  through its `wsh` command (`wsh view`, `wsh web open`), not through
  an escape in the pty stream
  ([wsh reference](https://docs.waveterm.dev/wsh-reference)). Kido's
  `ko html` is the same shape of command, but the escape is the
  contract, so a program over `ko ssh` can use it with no `ko` on the
  host.
- **Extraterm** frames each command's output with OSC 133 and shows
  files and images in frames through its `show` command
  ([guide](https://extraterm.org/guide.html)). Frames are a layout
  concept of the client, as Kido's blocks are an overlay of the client.
- **iTerm2** added a browser pane on WKWebView and keeps inline
  content to images (`OSC 1337 ; File=`)
  ([escape codes](https://iterm2.com/3.4/documentation-escape-codes.html)).
  Kido takes the WKWebView pane and adds the escape that iTerm2 does
  not have.
- **Hyper** is Electron: plugins inject DOM. No escape.
- **euporie** renders Jupyter's `text/html` outputs inside a TUI with
  its own HTML renderer ([euporie](https://github.com/joouha/euporie)).
  This is the `ko_tui` question in reverse: Kido does not render HTML
  in a grid.
- **kitty's graphics protocol** gives the escape style (key=value
  pairs, base64 payload in chunks with `m=1`, a query with a reply)
  and the placement machinery that inline blocks reuse: a placement
  at a cell that scrolls with the history, and a virtual placement
  whose position comes from U+10EEEE placeholder cells
  ([kitty graphics](https://sw.kovidgoyal.net/kitty/graphics-protocol/)).
- **OSC 7501** (program status) gives the pair grammar, the base64
  text values and the `?` query
  ([program status](https://www.superlogical.com/rex/docs/build/program-status)).
  OSC 7502 follows it exactly.
- No terminal working group has a standard for HTML in a terminal:
  the grid model and the security model are the reasons. Kido's
  escape is its own, in the 75xx range beside 7501.

## 3. The escape

`ko-pane`'s terminal reports the sequence through libghostty-vt's
unknown-sequence callback (`GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE`
with `GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES`), so the Ghostty fork
does not change for the parse. The callback gives the bytes between
`ESC ]` and the terminator, and may write a reply to the pty in order
with the terminal's own replies.

    OSC 7502 ; pairs ST        a command
    OSC 7502 ; ? ST            feature detection

    pairs := pair (":" pair)*
    pair  := key "=" value
    key   := [a-z]+
    value := [A-Za-z0-9_.,+/=-]*

The grammar, the separators, the character set, the base64 text
values, the "last value wins" rule and the "ignore an unknown key"
rule are those of OSC 7501. A command with a malformed pair is
processed without that pair. A command without `a`, or with an `a`
that the terminal does not know, is ignored whole.

| key | value | meaning |
|---|---|---|
| `a` | `enter`, `leave`, `block`, `delete`, `clear` | the action (required) |
| `t` | `serve` (default), `doc` | where the page comes from |
| `p` | a URL path, base64 | for `t=serve`: the path that the page loads, default `/` for the pane and `/blocks/<i>/` for a block |
| `i` | integer 1 to 4294967295 | the block id; also the kitty image id of its placement |
| `d` | base64 | for `t=doc`: a chunk of the document |
| `m` | `0` (default), `1` | more chunks of `d` follow |

Actions:

- **`a=enter`**: the pane enters HTML mode. The page is
  `ko://pane_N/` plus `p`. With `t=doc`, the page is the document that
  `d` carries. A second `enter` replaces the first.
- **`a=leave`**: the pane leaves HTML mode. The terminal content under
  the page shows again, as the alternate screen does on exit.
- **`a=block`**: a block with id `i`. The program also sends the
  block's placement as a kitty image (section 10): a 1 by 1
  transparent RGBA image with image id `i`, placed with `c=<cols>`
  and `r=<rows>` at the cursor, or as a virtual placement with
  placeholder cells. A `block` with an id that exists replaces its
  content: this is the update. The order of the escape and the kitty
  placement does not matter.
- **`a=delete`**: removes the record of block `i`. The program deletes
  the kitty image with the protocol's own `a=d`; a placement without a
  record shows nothing, and a record without a placement is not seen.
- **`a=clear`**: removes every block record and leaves HTML mode.

Chunks: a `d` value is at most 4096 bytes of base64 for each
command, with `m=1` on every chunk but the last, as a kitty image is
sent. `ko-pane` joins the chunks of one `enter` or `block` and refuses
a document over 1 MiB with no record change. A chunk sequence that
another command interrupts is dropped.

Size and placement: in HTML mode the page fills the pane's content
rectangle. A block covers the cells of its placement: `c` columns
by `r` rows of the kitty placement. The pixel size follows the
client's cell size, as an image's does. A page lays itself out in CSS
and reads nothing about cells unless it wants to (section 9).

Query: `OSC 7502 ; ? ST` is answered by `ko-pane`, through the
callback's reply path, with `OSC 7502 ; ? : actions=enter,leave,block,delete,clear ST`,
with the terminator of the query. A program sends `CSI c` after the
query, as OSC 7501 recommends; the DA reply first means no support.
The answer says that the server keeps the mode; it does not say that
the client renders it, as kitty's reply under tmux does not.

Through `ko ssh` the escape reaches the local pane's terminal as any
byte does, so `enter` with `t=doc`, `block` with `t=doc`, `leave` and
`clear` work on a host without ko. `t=serve` needs the serve stream
(section 5), which needs `ko` beside the program.

The parse lives in `ko-pane` (`ko_pane/src/html.rs`): the pair
grammar, the base64 decode, the chunk join and the limits. It is the
one place that parses text of this escape; the coordinator gets a
typed frame `FromPane::Html(HtmlReport)` with the decoded action,
the id, the source and the document bytes. The grammar functions are
pure and unit-tested; a fuzz target `html` replays the corpus on
stable, as the other targets do.

## 4. The pane field and its lifecycle

The coordinator keeps one `Html` record for each pane
(`ko_server/src/html.rs`), as it keeps the OSC 7501 record set:

    Html { page: Option<Page>, blocks: Vec<Block>, serving: bool }
    Page { content: Content }
    Block { id: u32, content: Content }
    Content = Serve { path: String } | Doc

The row (`Row.html: Option<Html>`, absent when the pane has no page,
no block and no serve stream) carries it, so the welcome's layout event
and `GET /panes` give it to every client, and a `html` event on
`/client` carries the whole record of the pane on each change, as
`progress` does. A document's bytes are not in the row: a client
fetches a document through the proxy route (section 5), and the row
only says `Doc`. The server holds at most 1 MiB for each document
and 8 MiB of documents for each pane; a `block` over the pane's
limit evicts the block updated longest ago. A pane holds at most 256
block records, with the same eviction.

Lifecycle:

- `enter` sets `page`; `leave` and `clear` remove it.
- The pane's death removes `page` and closes the serve stream. The
  blocks stay: they are history, and a `Doc` block still renders. A
  `Serve` block of a dead pane shows its last snapshot or the paper.
- RIS removes everything, as it does for the OSC 7501 records.
- A primary prompt start (OSC 133 `A`) removes `page`: the program
  that entered the mode has ended. It keeps the blocks.
- `clear_history` and a kitty image delete remove nothing from the
  record; the placement decides what is seen.
- The alternate screen is independent of the mode. A block in the
  alternate screen is seen while that screen is active, because the
  render state places it.
- The record goes with its pane. Nothing persists.

`serving` is true while the pane's serve stream is open, as `inbox`
is true while the message stream is open, so a client can say "the
program is not serving" instead of a blank page.

The model (`model.rs`) does not read `Html`. A pane in HTML mode has
the status of its program as before; the sidebar shows nothing new.
Kido.app and `ko_tui` read `html` from the row.

## 5. The routes

Both routes are declared in the `routes!` block of
`ko_server/src/api.rs`, so `make schemas` writes them into
`share/ko/openapi.json` and `share/pi/ko-api.d.ts`.

**The serve stream**, `GET /panes/{id}/html/serve`, a WebSocket of
JSON text messages. The pane itself (its `Ko-Pane` and token), or the
user, opens it; a pane has at most one, as it has one message stream,
and a second upgrade is `refused`. It is in the runtime gate's list,
because a program in a runtime serves over the runtime listener with
its own pane identity. Messages:

    server → program   request  { req, method, path, headers }
                       body     { req, data (base64), more }
                       cancel   { req }
    program → server   response { req, status, headers }
                       body     { req, data (base64), more }

`req` is a serial that the server mints for each proxied request. A
`body` with `more: false` ends that side. The program answers each
request in any order. A `data` payload is at most 64 KiB before
encoding, the exec session's limit, so the serve stream never sends a
message over the client limit. A stream that closes fails every
request in flight with `502`. The program sees `path` and `headers`
as the page sent them, with `Host` removed and the pane's id in
`Ko-Pane`.

**The proxy route**, `GET|POST|PUT|DELETE /panes/{id}/html/{path...}`,
with `{path...}` a new `Rest` parameter of `ko_server/src/route.rs`
that takes the rest of the target, query string included. The caller
must be the user with a `Ko-Client` header of a live client: the app's
client link, never a pane identity and never a bare `ko api`. A pane
identity is `refused`; a runtime connection is `refused` (the route is
not in the gate's list). The request body is at most 1 MiB. The
server answers:

- From the record, when the path names a `Doc`: `/` in HTML mode with
  a `Doc` page, and `/blocks/<i>/` for a `Doc` block, with
  `text/html; charset=utf-8`. Any other path of a `Doc` source is
  `404`.
- Through the serve stream, when the path's source is `Serve`: it
  sends `request` and the body, then streams the program's `response`
  and `body` messages into the proxy connection as they arrive. The
  pane has no serve stream: `503` with `kind: unavailable`, which the
  client shows as "the program is not serving".
- `404` when the pane has no page and no block for the path, `gone`
  for a dead pane's `Serve` path, `not_found` for an unknown pane.

Backpressure: the proxy connection is one connection, so its queue
and cap are those of any other control reply, and the server stops
reading the serve stream while any proxy connection of that pane has
its queue over the cap (the rule of protocol.md, section 1, applied to
the stream's reader). A slow page therefore slows every request of
its pane, not the server. A proxy connection that closes sends
`cancel`. A page may hold a streaming response open for its life: a
request in flight is a `Phase::Handling` connection with its waiter
in `State`, never a thread, under the loop rule. The server allows at
most 16 requests in flight for each pane and answers `429` past it.

A document fetched from the record and a response from the program
both get `Cache-Control: no-store` and a `Content-Security-Policy`
header that the app also enforces (section 8), so a page cannot
weaken it.

Why a reverse stream and not a socket path: a program's socket path
means nothing to the server for a pane in a container or on the far
side of an ssh runtime, and a path that a pane names would make the
server connect wherever the pane says. The pane's own connection to
its server proves that the serving process is the pane, on every
kind of runtime and on a remote server. The cost is a bridge for a
program that only knows HTTP: `ko html serve` (section 6).

Why not `/panes/{id}/messages`: that queue is the agent prompt path
with ack semantics, at most 16 in flight for a pi harness. HTTP
requests are a different contract, with bodies, streaming and
cancellation.

## 6. The `ko html` command

`ko html` (`ko/src/html.rs`, clap) writes escapes to its own tty, as
`ko prompt` writes to the server, so an author needs no byte layout:

- `ko html enter [--path P | --doc FILE]`
- `ko html leave`
- `ko html block --id N --rows R [--cols C] [--path P | --doc FILE]`:
  emits the kitty placeholder image with the placement, then the
  escape. `--cols` defaults to the pane's width, as a full-width block.
- `ko html delete --id N`, `ko html clear`.
- `ko html serve --socket PATH`: opens the pane's serve stream with
  the pane's identity and forwards each request to the unix socket
  `PATH` as HTTP/1.1, one connection for each request, and streams
  the response back. It runs until its stdin closes or the stream
  closes. A program starts it as a child, or the user runs it with
  `&`. It exits 1 on a refused upgrade with the server's message.

`ko html serve` is the one HTTP client of a program's socket, in
`ko_client` beside the wire layer, with the head reader of
`ko_server::http`. It does not exist on a host without ko.

## 7. The live channel

A page talks to its program with HTTP only:

- Program to page: a streaming response body. The page reads it with
  `fetch` and a `ReadableStream`. The spike (section 14) measured the
  first chunk at 2 ms after the request through the scheme handler.
  A page that wants events uses a `text/event-stream` body and an
  `EventSource`-like reader on the body; the app does nothing special.
- Page to program: `fetch` with a method and a body, at most 1 MiB.
- WebSockets do not exist on the `ko:` scheme: WKURLSchemeHandler
  intercepts URL loads, not `ws:` connections, and the app opens no
  TCP listener. A page that opens a `ws:` URL fails at once, by the
  content rule list (section 8).

The app also gives every page a small JavaScript object, `window.ko`,
in the page world, for what a page cannot get from HTTP: the pane id,
the theme and the cell size (section 9), and an event `ko-theme` on
`window` when they change. It has no method that reaches the program
or the server: the app is not a message bus between a page and ko.

## 8. The sandbox and the configuration

Every page runs in a WKWebView of Kido.app with these settings, which
no page and no configuration key can loosen:

- `WKWebsiteDataStore.nonPersistent()`, one store for the whole app,
  so views can share WebKit's processes (the spike shows that they do
  not; section 14), and nothing of a page reaches the disk: no
  cookies, no cache, no local storage after the view goes.
- The one scheme is `ko:`, through a WKURLSchemeHandler that calls
  `ko_client_html_fetch` (section 12). The origin of a page is
  `ko://pane_N`, so the pages of two panes are two origins, and a
  page fetches only its own pane's paths. The handler refuses a
  request whose host is not the view's pane.
- A `WKContentRuleList` blocks every load of `http`, `https`, `ws`,
  `wss`, `file`, `data` and `blob` top-level navigations. The
  navigation delegate allows only `ko://pane_N/` of the view's pane
  and refuses every other navigation, a new window, a download and a
  link preview. `javaScriptCanOpenWindowsAutomatically` is false, and
  the UI delegate answers `alert`, `confirm` and `prompt` with
  nothing.
- A `Content-Security-Policy` header on every proxied response:
  `default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'self'`.
  The page world script of `window.ko` is injected by the app and is
  not subject to it.
- No `isInspectable` unless `app.html.inspector` is true.
- Media does not autoplay. No microphone, camera, geolocation,
  notifications or clipboard API: a custom scheme is not a secure
  context, so these APIs do not exist in the page; the plan relies on
  this and tests it (section 17, "Risks of the whole").
- A page from a remote server gets the same sandbox. There is no
  trust by host.

Configuration, the `app:` key of `config.yaml` (`ko_config`):

    app:
      html:
        enabled: true            # false: a pane in HTML mode shows the hint of ko_tui
        links: deny              # or `open`: an http(s) link opens in the default browser
        live_blocks: 4           # live WKWebViews for blocks for each window
        inspector: false

`links: open` is the one way out of the sandbox: the link opens in the
user's browser, outside the app, through `NSWorkspace`, after the
first-time sheet of the clipboard family ("Allow pages on HOST to
open links in your browser?"), with the same grant store. The page
never learns whether the link opened. A link with another scheme
does nothing.

## 9. Keys, focus, copy, find, theme and font

**Focus.** In HTML mode the pane's view hosts one WKWebView over the
Ghostty surface, as a chrome view of the pane. The surface keeps its
view and its feed, so the terminal content under the page stays
current and shows again at `leave` with no snapshot. A click in the
page selects the pane, as a click in a surface does, through the
same left-mouse-down monitor, and makes the web view first responder.
The pane's focus treatment (the edge, the shift) applies to the
chrome, so the page is inside it. The server's focus for the pane
follows the client's current pane as before: the program gets focus
in and out while its page has focus.

**Keys.** The host view's `performKeyEquivalent` runs before the web
view's and offers every Command key to the main menu first, as
`PaneView.performKeyEquivalent` does, so Kido's keys (the palette,
the sidebar, the windows, copy mode's toggle, find) win over the page.
The spike confirms that a Command key reaches the menu while the web
view is first responder (section 14). Every other key goes to the
page, through WebKit. Escape goes to the page; the sidebar's keys
return focus to Kido. `ko_tui` is not affected: the page does not
exist there.

**Copy and paste.** The page's selection is WebKit's. Cmd-C copies it
through the Edit menu's `copy:`, which the web view answers. Cmd-V
pastes the pasteboard into a focused field of the page: this is the
user's action on their own clipboard, and no page can read the
pasteboard by itself (no clipboard API without a secure context).
The pane's copy mode is not available while the page has focus; the
Shift-click gesture of the surface is not seen under the page.

**Find.** Cmd-F opens the pane's find bar; in HTML mode it drives
`WKWebView.find(_:configuration:)` instead of Ghostty's search, with
"i of N" from the find result's count. Blocks do not take part in a
find of the pane's terminal.

**Theme and font.** A user script at document start sets CSS custom
properties on `:root` and `window.ko`:

    --ko-bg, --ko-fg, --ko-cursor, --ko-selection-bg, --ko-selection-fg
    --ko-color-0 … --ko-color-15
    --ko-font-family, --ko-font-size (px), --ko-cell-width, --ko-cell-height (px)
    --ko-appearance: light | dark

The values are the pane's effective Ghostty theme and font, the same
that the chrome derives. The web view's appearance follows the pane's,
so `prefers-color-scheme` agrees with `--ko-appearance`, and
`underPageBackgroundColor` is `--ko-bg`, so a page that sets nothing
shows the pane's paper and no white flash. A theme or font change
runs one `evaluateJavaScript` that sets the properties again and
dispatches `ko-theme`. The spike shows the properties applied at
document start and switched live (section 14).

## 10. Inline blocks

**The placement is a kitty image.** The program sends a 1 by 1
transparent RGBA image (`f=32,s=1,v=1`, 4 bytes, `t=d`) with image id
`i`, and places it with `c=<cols>,r=<rows>` at the cursor, or as a
virtual placement (`U=1`) with U+10EEEE placeholder cells. Then it
sends `OSC 7502 ; a=block:i=<i>… ST`. Everything about position is
the kitty protocol's, which libghostty-vt already implements in the
pane's terminal and in every mirror: the placement moves with the
cursor, scrolls into the history, reflows with the placeholder cells
of a virtual placement, is in every snapshot, and goes with the
scrollback. The 4-byte image costs nothing in the ring, the snapshot
or the image storage. The mirror contract is unchanged: a block's
placement is bytes that the mirror parses as the server does. Nothing
is synthesized into the ring.

**What the app does.** `PaneBlocks` (`app/App/PaneBlocks.swift`), a
controller of each pane view beside `PaneImages`:

- After each feed and each viewport move, on the pane's serial scroll
  queue, it reads the surface's render-state placements through a new
  fork API, `ghostty_surface_image_placements`, which lists each
  Kitty placement that the render state shows, with the image id, the
  viewport column and row, the columns and rows, and the clip
  (section 12 names the fork change). A virtual placement arrives as
  one placement for each row of placeholder cells; the controller
  joins consecutive rows of one image id into one rectangle.
- It keeps the pane's `Html.blocks` from the model and intersects: an
  image id that is a block id is a block on screen, at the cell
  rectangle that `PaneLayout` maps to points, clipped to the grid.
  Every other placement is an image, which Ghostty draws.
- For each block on screen it places one overlay view at that
  rectangle in the pane's chrome: a live WKWebView or an `NSImageView`
  of its last snapshot. The overlay moves with the rows on the same
  main hop that moves the scroller, so a block scrolls with the text
  at the publish cadence of output. Between hops a block can trail
  its row by one hop; the known limit of the scroller's thumb.
- The Ghostty renderer draws the 1 by 1 image under the overlay,
  scaled to the placement, transparent.

**The budget.** `app.html.live_blocks` (4) live web views for blocks
for each window, over all its panes, by visibility and then by the
time of the last scroll into view. A block past the budget, or
scrolled out of the viewport, is snapshotted (`takeSnapshot`, 7 ms
for a 300 by 200 view in the spike) and its web view is removed; its
`NSImageView` shows the snapshot at the placement. A block that comes
back gets a web view again and loads `ko://pane_N/blocks/<i>/` again:
a block's page must be reloadable, and its state is its program's.
A block that was never live shows the pane's paper until its page
loads. The pane-mode page counts as one live view of the window and
is never evicted while the pane is shown. Hidden windows keep no live
block views, and an evicted window keeps no snapshots.

Memory: the spike measured about 27 MB of resident memory for each
extra live web view, in its own WebContent process (section 14), so
the default budget costs about 110 MB for a window with every slot
full, and a window with no block costs nothing.

**What the server keeps.** The pane's terminal keeps the 4-byte
images and their placements in the kitty storage, under the existing
limit. The coordinator keeps the block records (section 4). A
snapshot carries the placements; the welcome carries the records. The
server never reads the placements for blocks: it does not know where
a block is, and it does not need to.

**Order of arrival.** The block's escape and its placement arrive in
either order, and the record's `html` event and the view's bytes have
no order across the two links. The app shows a block when it has
both; until then the placement is a transparent image. A `delete`
removes the record at once; the placement stays blank until the
program deletes the image.

**Why not a pixel snapshot into the mirror.** The app cannot add
bytes to a mirror: a mirror that differs from the server's terminal
breaks the contract and every resync. The overlay is the client's
own, as the scroller and the pills are.

## 11. `ko_tui`

The terminal client draws the mirror as before. A pane in HTML mode
shows the terminal content under the page, which the program may
prepare ("HTML view: open this pane in Kido.app"), and the status line
shows `[html]` for the active pane, as it shows `[resize]`. A block's
placeholder cells draw as blank cells, as a kitty image does in the
terminal client today. Nothing else changes; the row's `html` is read
for the status word only.

## 12. The client core and the fork

`ko_client`:

- The model gets `html` on each pane row (`client-model.json`).
- `ko_client_html_fetch(client, pane, method, path, headers, body, callbacks)`:
  one request on a new connection, as `ko_client_image` is, but
  streaming: a response callback with the status and headers, a body
  callback for each chunk, and an end callback, on the caller's
  serial queue, with a handle that cancels. The core sends
  `Ko-Client` for the client. The I/O thread owns the connection,
  under the same cancellation wake as every other blocking call.
- `ko_tui` reads `html` for the status word.

The Ghostty fork (`third_party/ghostty`, `kido-upstream`): one commit,
`ghostty_surface_image_placements`, the surface twin of the render
state's image iterator (`render.h`, "Images"): it fills a caller's
array with the placements of the last render-state update under the
renderer lock, as `ghostty_surface_kitty_pending_frames` does for
frames. A pin bump moves `Ko-Vt`, so this unit ships with a
coordinated release (AGENTS.md, "One Ghostty"). The pane mode needs
no fork change.

## 13. Remote servers and runtimes

- **A remote server.** The app's proxy request goes through the
  forwarded client link, as an image fetch does, to the remote server,
  which answers from its record or through the pane's serve stream.
  The program's serve stream is a connection on the remote host's
  socket. Nothing on the Mac changes, and no SSH port forward is
  added. Latency: a page load is one round trip for the document and
  one for each asset; a page keeps its assets few.
- **A pane in a runtime.** The program inside the container or the
  ssh runtime opens the serve stream on `KO_SOCKET`, the runtime
  listener, with its pane identity, which the gate allows. The proxy
  route is a host route, on the host listener, as `/client` is. A
  routed pi's host pane serves from the host.
- **`ko ssh` without ko.** Only `t=doc`, `leave` and `clear` work
  (section 3). `ko html` is not there.
- **A pane with a `parent`.** No rule changes: a page is the pane's
  own.

## 14. The spike

`~/Workspace/kido-html-spike-1/` holds `spike.swift` (an AppKit app
with no activation, a window far off screen, one WKWebView and a
WKURLSchemeHandler for `ko:` that forwards each request over a unix
socket) and `toy.py` (an HTTP/1.1 server on that socket: a page with
an input, a streaming `/events` body in chunked encoding, a `POST
/echo`). The run used a private socket under `/tmp/ko-html-spike/` and
no ko server. Results on this Mac (M-series, macOS 27.0.1, WebKit of
the system):

| measurement | result |
|---|---|
| `ko://pane_1/` ready, from `load` to the page's `ready` message through the bridge | 104 ms (194 ms on the first run of the process) |
| the web view takes first responder on `makeFirstResponder` | yes |
| Cmd-K while the web view is first responder, offered to the main menu first | the menu took it (the host view rule of section 9) |
| two typed keys through `NSWindow.sendEvent` reach the page's input | `xy` |
| streaming `fetch` of 5 chunked lines, first chunk after the request | 2 ms; all 5 arrived; `POST /echo` answered |
| CSS variables set at document start, and switched live | `rgb(30, 30, 46)`, then `rgb(250, 250, 250)` |
| WebKit processes and their resident memory for 1 view | 3 processes (WebContent, Networking, GPU), 68 MB |
| 21 views of one non-persistent data store, all loaded | 716 ms to load all; 23 processes, 634 MB: one WebContent for each view, about 27 MB each |
| `takeSnapshot` of a 300 by 200 view in the off-screen window | 7 ms |
| after removing the 20 extra views, 2 s later | 23 processes still, 561 MB: WebKit keeps idle content processes for a while |
| the app's own footprint with 21 views | 30 MB |

Conclusions that the design uses: the scheme handler streams, so the
live channel needs no WebSocket; the menu rule gives Kido its keys;
one data store does not make WebKit share content processes, so a
budget of live views is the memory control; a snapshot is cheap, so
eviction to an image is the right fallback; the chunked decoder of a
proxy must handle a chunk split over reads (the first run of the
spike crashed on that in its own code, not in WebKit).

Not measured: the view over a real Ghostty surface in Kido.app, the
latency through a ko server and the SSH forward, and a page's memory
when it holds a large DOM. The first unit of the app measures them
with `KIDO_APP_TIMING`.

## 15. pi

Two uses, after the core units:

- **Inline blocks from pi-tui.** pi already shows kitty images
  through its `Image` component when `PI_IMAGE_PROTOCOL=kitty`, which
  `ko-pi` sets. An `HtmlBlock` component is an `Image` component whose
  image is the 1 by 1 placeholder and that emits the `block` escape
  with a document: a tool renderer (`pi.registerToolRenderer`) can
  show a diff or a table as a block in the transcript, which scrolls
  with the transcript as an image does. `ko-pi` serves nothing for
  this: the block is a `Doc`.
- **pi's UI as a page.** pi has an RPC mode (JSON records on stdio,
  `docs/rpc.md`) and an HTML export of a session. A `/html` command
  of `ko-pi` starts a small HTTP server on a unix socket inside the
  extension, opens the serve stream through `ko html serve`, and
  sends `enter`: the page is the transcript, rendered from the
  session's events as a streaming response, and a prompt field whose
  `POST` becomes `sendUserMessage`. `/html` again sends `leave`. The
  TUI keeps running under the page, so `leave` shows it at once. The
  dialogs of the extension UI (`select`, `confirm`, `input`) go on in
  the TUI: this unit moves only the transcript and the prompt, and
  the RPC extension-UI protocol is the reference for the rest.

Both are pi-side work in `share/pi/`, with the fake ko of the
TypeScript suite teaching `ko html` a stub.

## 16. Open questions for the user

1. **The number.** OSC 7502, beside 7501, in the Rex range. Agreed?
2. **Default on.** `app.html.enabled: true` by default, because the
   sandbox is the same for a local and a remote program. Or off until
   the user enables it?
3. **Links.** `links: deny` by default, `open` after a consent sheet.
   Or no `open` at all in the first release?
4. **The proxy's callers.** Only a client link (`Ko-Client`). A pane
   can never fetch a page, also not its own. Agreed?
5. **The budget.** 4 live block views for each window, and the pane
   page always live. Agreed, or a global budget?
6. **pi first.** Inline blocks from tool renderers (small) or the
   transcript page (large)? The plan proposes the blocks first.
7. **`ko_tui`.** Only the `[html]` word, or also a dim box with the
   block's id over its placeholder cells?
8. **Documents.** 1 MiB for each document and 8 MiB for each pane,
   the variable limits. Enough for a rendered markdown file with
   inline images as `data:`?
9. **Find.** WebKit's find for the page in HTML mode, with the pane's
   find bar. Agreed?

## 17. Units, estimates and risks

Each unit is one manager with one implementer and the reviewers of
AGENTS.md; the estimate is agent-days of one implementer.

| unit | what | days | risk |
|---|---|---|---|
| 1. The escape and the record | `ko_vt`'s unknown-sequence callback and option; `ko_pane/src/html.rs` (grammar, chunks, limits, the query reply); the `Html` frame; `ko_server/src/html.rs` (the record, eviction, lifecycle); `Row.html` and the `html` event; e2e tests through `text` input, as the OSC 7501 tests go; the `html` fuzz target | 2 | the callback's truncation rule (a 2 KiB buffer, allocations above it) sets the chunk size; a pane that sends only chunks never completes: the join has a limit |
| 2. The serve stream and the proxy route | the `Rest` parameter of `routes!`; both routes in `api.rs` and `router.rs`; the stream's reader with the per-pane backpressure; the in-flight waiters under the loop rule; `cancel`; the CSP and `no-store` headers; hostile tests; `make schemas` | 3 | a long streaming response holds a `Phase::Handling` connection: the 16-request cap and the cancel on close must be exact, or a page leaks connections |
| 3. `ko html` | the clap command, the escapes, the placeholder image, `ko html serve` with the head reader of `ko_server::http`; e2e tests against a toy socket | 1 | none |
| 4. `ko_client` and `ko_tui` | the model's `html`; `ko_client_html_fetch` with streaming callbacks and cancellation in `ffi::engine`; the header and `exports.txt`; `ko_tui`'s `[html]` | 1.5 | the first streaming call of the ABI: its cancellation must join the I/O thread's request as `ko_view_close` does |
| 5. Kido.app, pane mode | `HtmlPaneView` and the scheme handler over `ko_client_html_fetch`; the data store, the content rule list, the navigation and UI delegates, the CSP; keys through the host view; find; the theme script and `ko-theme`; `app.html` keys in `ko_config` and `GhosttyConf`'s neighbours; visual tests of the page over a pane, light and dark, with a toy server in the VISUAL build | 3 | WebKit's first-responder behaviour under the pane's event monitors; a key that WebKit consumes before `performKeyEquivalent` of the host view (the spike covered the menu path, not every key) |
| 6. Kido.app, inline blocks | the fork API `ghostty_surface_image_placements` and the pin bump; `PaneBlocks`; the overlay placement on the scroll hop; the budget, the snapshots, the reload; visual tests with scrolled blocks, a virtual placement, a split and a zoom | 4 | the fork: a wrong lock in the render-state read deadlocks the renderer (design-app.md, "Threads"); overlay trailing during a fast scroll; a block in the alternate screen |
| 7. pi, blocks | the `HtmlBlock` component on `Image`, a diff renderer as the first user; the fake ko stub; tests of the TypeScript suite | 2 | pi-tui's image handling of a re-rendered transcript re-sends the placement: the escape must be re-sent with it |
| 8. pi, the transcript page | the `/html` command, the HTTP server on a unix socket in the extension, the transcript as a stream, the prompt field | 3 | the pi session's event stream as the page's source: a long session re-sends everything on each load |
| Docs | `docs/design-html.md`; protocol.md's new section; design-app.md's "HTML panes"; design.md's "Knobs" and AGENTS.md's rules | with each unit | |

Units 1 to 4 are ko and ship together in one release. Units 5 and 6
are Kido.app; 6 bumps the Ghostty pin. Units 7 and 8 come after 5.
Total: about 20 agent-days of implementation, plus review and docs.

Risks of the whole:

- **Security.** A page is untrusted code in the app's process space,
  behind WebKit's process boundary. The sandbox of section 8 has no
  switch that a page or a server can flip; the app tests each rule
  (a `ws:` load, an `https:` fetch, a navigation, `window.open`, a
  clipboard read) and fails on any that passes. A WebKit change that
  makes a custom scheme a secure context would enable APIs that the
  plan assumes absent; the tests catch that at the next macOS.
- **Memory.** Each live web view is a WebContent process of about 27
  MB and more with its DOM. The budget and the snapshots bound it;
  the stress harness gains a block action and a window with many
  blocks.
- **The fork.** One API for the render state. It is small, but it is
  a pin bump and a coordinated release.
