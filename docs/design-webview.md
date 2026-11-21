# Webview pane mode

A program can show an HTML page over its pane's terminal. The mode
is server state, so every attached client sees the same mode. The
program serves the document and data through ko; the client does not
read a socket path supplied by the program.

The contracts and owners are:

- [protocol.md](protocol.md), section 16: the escape, support query,
  serve stream, proxy route and webview commands.
- [design-app.md](design-app.md#webview-panes): the native view,
  sandbox, keys, find, theme, previews and hidden-page retention.
- [design-koa.md](design-koa.md#the-webview-sdk): the Node SDK,
  browser target and page-authoring constraints.
- [design-koa.md](design-koa.md#page-and-transport): koa's page and
  delivery model.

## Pane state

`ko_pane_wire/src/webview.rs` owns escape parsing and encoding.
`ko-pane` receives the escape through libghostty-vt's unknown-sequence
callback. That callback's reply path orders query answers with the
terminal's own replies. The coordinator receives typed state rather
than parsing terminal bytes again.

Leaving the mode, pane death, terminal reset and a primary shell
prompt end the page. A prompt means that the foreground program that
showed the page has ended. The alternate screen is independent.
Program status does not come from webview mode: the sidebar still
reports the pane's program.

Support means that at least one connected client can show webviews.
It does not mean that a client currently shows this pane. The client
hello supplies capability; the server reports its aggregate through
the query and serve stream. A terminal client keeps the terminal
content and its webview status word. It does not render HTML.

The page is not a DOM terminal, an inline history block or a document
that outlives its program. Keeping the terminal surface underneath
lets the native client return to current terminal content on leave.
A host with no ko serve path cannot supply an HTML document merely
by writing the escape.

## Reverse transport

The program opens the serve stream with its pane identity. The
client fetches through the proxy route. A runtime socket path has no
meaning on the host, and letting a pane choose a server-side socket
would grant the wrong authority. An outbound authenticated stream
works for local, remote and runtime panes without that authority.

`ko webview serve` adapts an ordinary HTTP server on a private Unix
socket to this stream. The SDK starts it only after the program's
server listens. The server marks serving when the stream opens, so
reversing that order could make the first document request fail.

The serve stream is separate from the pane's message queue. HTTP
needs bodies, streaming, upgrades and cancellation; the message queue
has delivery acknowledgements. Neither contract is a substitute for
the other.

Back-pressure stops a reader while the next queue is full. Requests
in flight have a pane-local cap. Waiting requests remain connections
and waiters under the server's loop rule, not worker threads. A slow
page affects its pane's requests, not unrelated server work.

A remote client uses its existing ko connection for the proxy. It
needs no additional SSH port forward. A runtime program uses the
runtime listener and its pane token for serving; the proxy remains a
host-client route. A pane's parent changes none of these rules.

## Sandbox boundary

The page is untrusted code, even on a local host. The app's WebKit
process and navigation gates enforce the native sandbox; host trust
cannot loosen it. The server's CSP is defined in `ko_wire/src/http.rs`.
A program can send a stricter CSP, not weaken the server's policy.
Inline scripts permit a one-document page, so an author must still
escape text it did not produce.

Each native view has its own non-persistent store. A pane origin does
not name its server: sharing stores would join equal pane names from
two servers or two server lifetimes. Page-to-page communication and
general network access are not features of this transport.

A real clicked external link follows the app's terminal-link policy;
a scripted click cannot open another application. The app supplies
only the native bridge in `app/App/WebviewPaneView.swift`, not a
message bus to ko. Browser development has different security gates
and must not be treated as a native sandbox test.

## Verification

The e2e suite checks the real webview bridge. Kido.app's
`WebviewPaneTests` checks the sandbox and WebKit constraints. See
[dev-koa.md](dev-koa.md) for SDK and page tests,
including the open-ended fetch-body constraint and replay fixtures.
