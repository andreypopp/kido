# Webview panes, as built

A program in a Kido pane can show an HTML page. It sends one escape to
switch its pane into webview mode, and the page fills the pane. The page
and its data come from the program itself, through ko. Kido.app shows
the page in a WKWebView. Uses: a markdown viewer, a diff viewer, pi's
own transcript, a log or table viewer, a form that an agent shows to
the user.

This document gives the design and its reasons. The other documents
give the behaviour and do not repeat it here:

- [protocol.md](protocol.md), section 16: the escape, the query,
  `supported`, the record, the serve stream, the proxy route and `ko webview`.
- [design-app.md](design-app.md), "Webview panes": the web view, the
  sandbox, the WebSocket shim, keys, find, the theme and hidden pages.
- [design-ko.md](design-ko.md), section 4.11, "The terminal client": the `[webview]`
  status word.
- [design.md](design.md), "The pi extension, ko-pi": the interfaces
  of ko that the harness uses.
- [design-koa.md](design-koa.md): koa, the pi harness that renders
  through a page.

## Goals and non-goals

Goals, in priority order:

1. **A pane mode.** A program switches its pane to a page that fills
   the pane. The mode is pane state in the server: every client and a
   reattach see it, and it ends when the program ends.
2. **Live content without the pty.** The program serves its page, its
   data and its WebSockets over HTTP, through ko. The same path works
   for a remote server and for a pane in a runtime.
3. **A strict sandbox.** Any program, local or remote, runs JavaScript
   inside Kido.app. The page gets only its own pane's resources: no
   file access, no network, no other pane, no persistence.
4. **Kido's keys stay Kido's.** The app's Command keys, the sidebar
   and the palette work while a page has focus. `ko_tui` keeps its
   `C-a` table.
5. **Small for authors.** One escape with the grammar of OSC 7501, a
   plain HTTP server on a unix socket, and a `ko webview` command that
   emits the escapes and bridges the socket.

Non-goals:

- A browser. A page cannot navigate to another origin, open windows,
  download or reach the network. A link to `http(s)` is a decision of
  the user's configuration (`app.webview.links`), not of the page.
- Inline documents in the escape. The page always comes from the
  program through the serve stream, so a host without ko (a plain
  `ko ssh` to a host that has no `ko`) cannot show HTML: the pane
  shows "the program is not serving" until `leave`.
- HTML in `ko_tui`. The terminal client shows the pane's terminal
  content and the status word `[webview]`.
- A DOM-based terminal, as DomTerm is. The grid stays libghostty-vt's.
  A page lives over the grid, never inside a cell.
- A page that outlives its program or a server restart.
- Pages of one pane that talk to pages of another pane.
- Inline HTML blocks among the text lines. A block needs a placement
  that scrolls with the history, a Ghostty pin bump, an overlay that
  trails the rows by one publish hop and a budget of live views, at
  about 27 MB each; pane apps cover the uses first.

## Prior art

- **DomTerm** inserts HTML with `OSC 72` and replaces a fragment with
  `OSC 721`, after a scrub of elements and attributes
  ([wire protocol](https://domterm.org/Wire-byte-protocol.html)).
  Kido rejects the DOM terminal and the scrubbed-webview model: a scrub
  is a security boundary that moves with every browser release; a
  process boundary with no network does not.
- **Wave Terminal** shows files and HTML in blocks of its layout
  through its `wsh` command, not through an escape
  ([wsh reference](https://docs.waveterm.dev/wsh-reference)). `ko
  webview` is the same shape of command, but the escape is the contract.
- **Extraterm** frames each command's output with OSC 133 and shows
  files in frames ([guide](https://extraterm.org/guide.html)). Frames
  are a layout of the client; Kido's page is an overlay of the client.
- **iTerm2** has a browser pane on WKWebView and keeps inline content
  to images
  ([escape codes](https://iterm2.com/3.4/documentation-escape-codes.html)).
  Kido takes the WKWebView pane and adds the escape.
- **euporie** renders Jupyter's `text/html` inside a TUI with its own
  renderer ([euporie](https://github.com/joouha/euporie)). Kido does
  not render HTML in a grid.
- **kitty's graphics protocol** gives the escape style: key=value
  pairs and a query with a reply
  ([kitty graphics](https://sw.kovidgoyal.net/kitty/graphics-protocol/)).
- **OSC 7501** (program status) gives the pair grammar, the base64
  text values and the `?` query
  ([program status](https://www.superlogical.com/rex/docs/build/program-status)).
  OSC 7502 follows it exactly, in the 75xx range beside it. No
  terminal working group has a standard for HTML in a terminal.

## The escape and the record

`ko-pane` gets OSC 7502 through libghostty-vt's unknown-sequence
callback, so the Ghostty fork does not change, and the callback's
reply path keeps the query's answer in order with the terminal's own
replies. `ko_pane_wire/src/webview.rs` is the one parser and the one
encoder: `ko webview` uses its encoder, and so does every program
that runs `ko webview enter` and `ko webview leave`, the SDK
included. The coordinator gets a typed frame.

The page ends at `leave`, at the pane's death, at RIS and at a
primary prompt start (OSC 133 `A`): after a prompt start, the program
that entered the mode has ended. The alternate screen is independent
of the mode. The status model does not read the record, and the
sidebar shows no marker: a pane in webview mode has the status of its
program.

**Supported.** Each `/client` hello declares whether the client can
show webviews (Kido.app with `app.webview.enabled`, never `ko_tui`).
`supported` is one fact of the server: at least one connected client
can show webviews. It does not say that a client shows this pane. A
program learns it from the query or, live, from the serve stream's
`supported` message, which `ko webview serve` prints on its stdout;
the SDK reports it, and koa shows and hides its page on it.

## Why a reverse stream

The program serves over its own pane's connection to the server (the
serve stream), and the page's client fetches through the proxy route.
A socket path that a pane names means nothing to the server for a
pane in a container or across an ssh runtime, and it would make the
server connect wherever a pane says. The pane's own connection proves
that the serving process is the pane, on every runtime kind and on a
remote server. The cost is a bridge for a program that only speaks
HTTP: `ko webview serve`. Programs use the bridge, through the SDK
below; the serve stream's JSON is for the bridge and for the tests.

The serve stream is not `/panes/{id}/messages`: that queue is the
agent prompt path with ack semantics. HTTP requests are another
contract, with bodies, streaming and cancellation.

A slow page slows the requests of its own pane, not the server: each
reader stops while the other side's queue is over its cap, and a
pane has a cap of requests in flight. A request in flight is a
connection with its waiter in the pane's record, under the loop rule
(design-ko.md, "The loop rule").

## The SDK, `@kido/webview`

`share/webview/` is a Node package, `@kido/webview`, with no
dependencies, in TypeScript that Node 24 runs as is (erasable syntax
only). It is not published yet; `make build` installs it as
`share/ko/webview/`. Its README gives the interface. It takes the
shape of the `supported` line from the generated `ko-api.d.ts`, which
`make build` installs as `share/ko/pi/ko-api.d.ts`, through a type-only
import of `../pi/ko-api.d.ts`; Node's type stripping removes the
import, so the SDK runs without the file.

The decision is that a page's program is a plain `node:http` server.
The SDK does not take a handler and does not listen: `webview()`
returns a socket path, the program calls `server.listen(socketPath)`
itself, and Express, `ws` and every other `node:http` stack work
unchanged, WebSocket upgrades included.

The SDK has two targets, and the program's code is the same for both.
The pane target, the default, shows the page in the program's Kido
pane and returns `null` outside one. The browser target is for
development: the page shows in a regular browser, in a pane or not.
It needs no ko. The program chooses the target; it is an option in
code, which a program can expose as its own flag (koa's
`--browser`).

The README gives the calls; the rules that it does not state:

- ko alone decides whether the program runs in a pane. The SDK reads
  no environment: `webview()` returns `null` when the bridge exits 6
  (no pane identity) or when no `ko` executable exists.
- `supported` comes only from the bridge's stdout. A bridge that exits
  makes `supported` false, and the SDK starts it again until `close`.
- `show` and `hide` run `ko webview enter|leave` with the program's
  stdout inherited, so the escape reaches the pane's tty, and they run
  in call order. The program decides when to show; the SDK never
  shows by itself.
- `close` removes the `supported` listeners before it leaves, so a
  listener that hides does not run during the close.
- Every wait has a deadline, `timeoutMs` (5 s by default): the
  bridge's first `supported` line, each `enter` and `leave`, the
  browser opener and `close`. A child of the SDK that passes it, or
  that a `close` cancels, gets `SIGTERM` and, 1 s later, `SIGKILL`.
  A program that ends must not hang on a bridge or a client that
  does not answer. `close` is one promise for every caller; it
  cancels the queued `show` and `hide`, and always removes the
  socket directory.

The browser target's rules:

- The SDK listens on `127.0.0.1` on a free port and forwards each
  request and each WebSocket upgrade to the socket with `node:http`,
  so streaming bodies and WebSockets work as in Kido. It starts no
  `ko webview serve`.
- A local port is open to every local process, to every web page
  through DNS rebinding, and to every web page through a simple
  cross-origin request, which a browser sends without asking. The SDK
  checks each request and each upgrade before it forwards it, because
  one keep-alive connection can carry requests of several pages: a
  `Host` other than exactly one `127.0.0.1:<port>` or
  `localhost:<port>` gets 421; an `Origin` other than exactly one
  `http://` plus that `Host`, `null` included, gets 403. A request
  without `Origin` passes: a browser omits it only on a navigation or
  a same-origin `GET`, and a local process can call the routes anyway.
  There is no token: the user decided that a local process may call
  the page's routes. A page's program still refuses a mutation with a
  simple content type (koa requires `application/json`), so a form
  post from a foreign page that a browser sends without `Origin` does
  nothing.
- `close` must not cut a response that is on its way, such as the
  reply to a page's own quit request: it stops the listener, closes
  the idle connections, lets each response end, and destroys what
  remains after `timeoutMs` or 1 s, whichever is shorter.
- `show` opens the URL in the browser, and refuses a path without a
  leading `/`, which could name another host; `hide` does nothing, because a
  program cannot close a tab, so a show after a hide opens no second
  tab. `supported` is always true.
- Nothing of Kido's page environment exists in a browser: no
  `window.ko`, no `--ko-*` properties, no CSP from ko and no sandbox.
  A page sets a fallback theme on `:root`. A page that passes in a
  browser can still fail in Kido, for example with a `Blob` body
  (design-app.md, "Webview panes").

## The live channel

A page talks to its program with HTTP and WebSockets only:

- Program to page: server-sent events, which the page reads with
  `EventSource`.
- Page to program: `fetch` with a method and a body.
- Both ways: the standard `new WebSocket(url)`. WKURLSchemeHandler
  does not see WebSocket connections, so the app injects a shim of the
  API that goes through `ko_client`. The app opens no TCP listener.

`window.ko` gives a page what HTTP cannot: the pane id, the theme and
the cell size, with a `ko-theme` event on a change. It has no method
that reaches the program or the server: the app is not a message bus
between a page and ko.

A page reads a live stream with `EventSource`, not with a `fetch`
body. WebKit before 319981@main (bug 322545, commit `718031552ba1`),
which includes macOS 27.0.1's WebKit, stashes the bytes that arrive
while a `fetch` body's reader is busy, and the reader's next pull does
not take them (`FetchBodySource::pull`): they wait for the next chunk
or the end of the response, and a stream that goes quiet can hide its
tail for good. Kido hands WebKit every byte; the fault is in WebCore.
WebKit's `EventSource` reads through its own loader, which does not
take that path. `testWebviewFetchStashedChunks` pins the fault and
fails when WebKit ships the fix; a finite `fetch` is not affected,
because its end releases the stash.

## The sandbox

A page is untrusted code, local or remote, behind WebKit's process
boundary. No page, server or configuration key can loosen the rules,
and a page from a remote server gets the same sandbox: there is no
trust by host. design-app.md, "Webview panes", gives the rules; their
reasons are these:

- **One non-persistent data store for each view.** The origin
  `ko://pane_N` names no server, so a shared store would join the
  `pane_1` pages of two servers, or of one server across a restart.
- **One scheme, one host for each view.** The pages of two panes are
  two origins, and a page reaches nothing but its own program.
- **The server's CSP** (`CSP` in `ko_server/src/http.rs`) keeps
  `'unsafe-inline'`, so a page can be one file. An author who shows
  text that the page did not write escapes it, or sends a stricter
  CSP of its own: both apply, and the server never weakens it.
- **The secure-context APIs stay.** A script that removes them misses
  the first document of a `srcdoc` frame, and WebKit has no public
  switch, so the app relies on WebKit's gates, and its tests fail when
  a gate opens.
- **`app.webview.links: open`** (`ko_config/src/app.rs`) is
  configuration only, with no prompt: the user who writes it has
  decided.

## Keys, focus, copy, find, theme and memory

The web view is a chrome view of the pane over the Ghostty surface,
which keeps its view and its feed, so `leave` shows current terminal
content with no snapshot. design-app.md, "Webview panes", gives the
key route, find, the theme properties and hidden pages. The
decisions: Kido's Command keys win over the page and every other key
goes to the page; the selection is WebKit's and copy mode is off
while the page has focus; find is WebKit's, which gives no count; the
pane's theme reaches the page as CSS properties, so a page that sets
nothing shows the pane's paper, also the shifted paper of an unfocused
pane, and no white flash.

**Memory.** Each live web view is its own WebContent process of about
27 MB (21 views of one data store measured 23 processes and 634 MB),
one data store does not make WebKit share them, and WebKit keeps idle
content processes after a view goes. Thus `app.webview.keep_hidden`
bounds the hidden pages that stay live in each window. A page must be
reloadable: its state is its program's.

## Remote servers and runtimes

- **A remote server.** The app's proxy request goes through the
  forwarded client link to the remote server, which answers through
  the pane's serve stream. No SSH port forward is added. A page load
  is one round trip for the document and one for each asset, so a
  page keeps its assets few.
- **A pane in a runtime.** The program opens the serve stream on the
  runtime listener with its pane identity, which the runtime gate
  allows. The proxy route is a host route, as `/client` is.
- **A pane with a `parent`.** No rule changes: a page is the pane's
  own.

## koa

koa (`share/koa/`), pi's session under a page, is the largest page
and the stress test of this feature: its stress runs found WebKit's
fetch-body bug above and showed that Kido needs no limit on the
number of webviews. [design-koa.md](design-koa.md) gives its design.

## Tests

The TypeScript suite drives the SDK through the fake ko, whose `ko
webview serve` prints the `supported` lines that the test releases.
The e2e suite covers the real bridge. Kido.app's `WebviewPaneTests`
cover the web view, its sandbox and the WebKit facts that this
document relies on.
