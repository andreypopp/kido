# @kido/webview

Serve an HTML page in a Kido pane with Node 24 or later.
The package is not published. Install the copy that comes with ko:

```sh
npm i "$(brew --prefix ko)/share/ko/webview"
```

You can also import `index.ts` from that directory by its absolute path.

```ts
import http from "node:http";
import { webview } from "@kido/webview";

const wv = await webview();
if (wv) {
  const server = http.createServer((_req, res) => res.end("Hello"));
  server.listen(wv.socketPath);
  wv.on("supported", supported => {
    if (supported) void wv.show();
    else void wv.hide();
  });
  if (wv.supported) await wv.show();
  // Before exit: await wv.close(); server.close();
}
```

`webview()` returns `null` when ko reports no pane identity or the ko executable is not found. The SDK starts the bridge
and restarts it after an unexpected exit. `show(path?)` needs a TTY on
stdout; while a page is shown, a different path replaces it and the
same path does nothing. `hide()` shows the terminal and does nothing
when no page is shown. `shown` is the last state that the SDK set, not
a report from the app. `close()` hides the page, ends the
bridge and removes its private socket directory; `close(false)` keeps
the pane in webview mode, for a program that replaces its own process
and serves again. Use `off` to remove a
`supported` listener. Pass `{ ko: "/path/to/ko" }` to select the executable.
`timeoutMs` (default 5000) bounds the bridge's start, each `show` and
`hide`, and `close`; a step that passes it rejects, and the SDK ends
its child.

For development, `webview({ target: "browser" })` serves the same
server on a free port of `127.0.0.1` and shows the page in your
browser, in a Kido pane or not; it never returns `null` and needs no
ko. `url` is the page's address, `show(path)` opens it once for each
path, `hide()` does nothing and `supported` is always true. `close()` stops
the port, lets responses that are on their way reach the browser, and
ends what remains after one second. The SDK
refuses each request and WebSocket upgrade whose `Host` is not that
address (421), which stops DNS rebinding, and each one whose `Origin`
is present and not that address (403), which stops other web pages;
any local process can still call your routes. A browser sends a
simple cross-origin form post without `Origin`, so accept a mutation
only with a non-simple `Content-Type`, such as `application/json`.
Request headers that start with `Kido-` belong to the host: the SDK
removes them, as Kido.app does. `show(path)` refuses a path that does not start with
`/`. A browser
has no `window.ko` and no `--ko-*` properties, so give `:root` a
fallback theme.

For a live stream from your program to the page, use server-sent
events and `EventSource`, not a long `fetch` body read with a
`ReadableStream`: the WebKit of current macOS can hold the end of such
a body until more data arrives (WebKit bug 322545). A `fetch` whose
response ends is not affected.

Kido does not decode compressed responses: requests reach your server
with `Accept-Encoding: identity`, and a response with another
`Content-Encoding` fails in the page (502).

Kido.app shows the page in a sandbox with no network: the page reaches
only your server, through `fetch` and `WebSocket`. Send a request body
as a string or bytes. A `Blob` or `FormData` body reaches your server
empty, because WebKit does not pass it to the app.

The SDK tests are in `share/pi/ko-pi-webview-sdk.test.ts`. Run them with
`scripts/test-ts.sh ko-pi-webview-sdk.test.ts`.
