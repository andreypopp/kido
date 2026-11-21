# koa: `/reload` reloads the page

Status: units 1 and 2 are built; their design is in docs/design-koa.md
("Reload, restart and failure", "One document, one instance",
"Views"). Two items are open, below.

## Open

### WKWebView keeps `history.state`

The view memory lives in `history.state`, written on `pagehide`. A
probe in Playwright's WebKit showed that it survives
`location.reload()`. Whether WKWebView keeps it across a reload on the
pane's custom scheme is not checked. If it does not, the fallback is
a route of koa's own HTTP server that holds one memory record per
instance in the program; decide then.

### Drafts of views that are gone

A draft of a view that no longer exists is not dropped when the page
reads the memory, because the page has no full list of views: job
views are missing from it.

## Later: UI extensions

UI extensions are not part of this work. One decision is made: an
extension registers its page files (a browser ES module, a style
sheet) at run time, from its factory. koa does not find them as
static files beside the extension. The design of the registration,
the page API and the fault isolation is a later plan. It builds on
these properties of units 1 and 2:

1. The page identity is the hash of every byte that goes into the
   document, computed where the document is assembled. Registered
   files then join the same hash and the same document.
2. The page comparison runs after the session reloads, because a
   session reload runs the factories, and thus the registrations,
   again.
3. The swap is one function of `koa/koa.ts` with no argument about
   its cause, so a registration, a session switch or a new child can
   call it later.
4. View memory survives the reload, so iteration on page code keeps
   the reader's place.

No new ko route and no C export: all of it is koa's own HTTP server
and document.
