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
bridge and removes its private socket directory. Use `off` to remove a
`supported` listener. Pass `{ ko: "/path/to/ko" }` to select the executable.

For development, `webview({ target: "browser" })` serves the same
server on a free port of `127.0.0.1` and shows the page in your
browser, in a Kido pane or not; it never returns `null` and needs no
ko. `url` is the page's address, `show(path)` opens it once for each
path, `hide()` does nothing and `supported` is always true. The SDK
refuses a connection whose first request has a `Host` other than that
address (421), which stops DNS rebinding; any local process can still
call your routes. `show(path)` refuses a path that does not start with
`/`. A browser
has no `window.ko` and no `--ko-*` properties, so give `:root` a
fallback theme.

Kido.app shows the page in a sandbox with no network: the page reaches
only your server, through `fetch` and `WebSocket`. Send a request body
as a string or bytes. A `Blob` or `FormData` body reaches your server
empty, because WebKit does not pass it to the app.

The SDK tests are in `share/pi/ko-pi-webview-sdk.test.ts`. Run them with
`scripts/test-ts.sh ko-pi-webview-sdk.test.ts`.
