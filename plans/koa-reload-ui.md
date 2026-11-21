# koa: `/reload` reloads the page

Status: unit 1 is built; its design is in docs/design-koa.md
("Reload, restart and failure", "One document, one instance"). Unit 2
is not built.

## Goal

`/reload` always brings the installed page into the running pane. A
change of only the page (HTML, CSS, page bundle) needs no process
replacement and has no deferral. The page and the program stay one
matched build. The design leaves room for UI extensions: pi
extensions that contribute page code, which a developer iterates on
with `/reload`.

The user decided: `KOA_PAGE_RELOAD` goes; a changed page swaps also
when the session reload is refused; a change of koa's program needs a
process replacement, with no state hand-over; UI extensions register
their page files at run time, in a later plan.

Not in scope: an in-process reload of koa's program, view memory
across a process replacement, and UI extensions (the hooks for them are below).

## Decisions

### View memory

The page keeps its view memory across a reload of
the same document entry in `history.state`. It needs no storage
permission and no origin, it is local to one tab or pane, and it ends
with the entry. A probe in Playwright's WebKit showed that a state
written in `pagehide` survives both `location.reload()` and a reload
from the browser. The page writes the memory in its `pagehide`
listener, so the app's Reload Page keeps the position also.

    type PageMemory = {
      scroll: Saved[]                   // of scroll.ts, with the current view's position added
      drafts: [view: string, text: string][]   // with the composer's current text
    }

- `koa/page/scroll.ts` owns the scroll part: one function gives the
  saved positions with the current position (reader anchor, or
  following), and `scrollInitial` takes them. Restoration uses the
  existing `restoring` state: it loads older content until the anchor
  is present, and a missing anchor opens at the end. A saved position
  keeps its session identity, so a position of another session is not
  used. Following needs no record.
- Drafts are restored by view id. A draft of a view that does not
  exist is dropped when the page reads the memory.
- Folds and thread filters go into the same record only if their
  keys are stable across a reset of the same session. The unit's
  planner checks this.
- Composer attachments, open pickers and dialogs' page state do not
  survive; the program publishes dialogs again.
- After a process replacement the app loads a new document entry, so
  the memory is gone. That stays.

Assumption to check in the unit: WKWebView keeps `history.state`
across a reload on the pane's custom scheme. If it does not, the
fallback is a route that holds one memory record per instance in the
program; decide then.

### UI extensions (later)

UI extensions are not part of this work. One decision is made: an
extension registers its page files (a browser ES module, a style
sheet) at run time, from its factory. koa does not find them as
static files beside the extension. The design of the registration,
the page API and the fault isolation is a later plan.

Units 1 and 2 must provide these hooks, and nothing more:

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

## Units

Each unit is a koa unit (docs/dev-koa.md) and leaves `main`
installable. Unit 2 does not depend on unit 1.

### Unit 2: the page keeps its view memory

Changes: `koa/page/scroll.ts` (memory out, memory in),
`koa/page/page.ts` (`pagehide` write, read at start, drafts).

Tests that fail first:

- `koa/koa-scroll.test.ts`: a reader position goes through the
  memory and gives `restoring` with the same anchor; a following view
  gives no record; a record of another session is not used; a missing
  anchor ends at the end.
- `koa/koa-page.test.ts` (real WebKit): scroll up in a long
  transcript, type a draft, deliver a `reload` record; after the load
  the anchor row has the same offset and the composer has the draft.

Docs at the end: `docs/design-koa.md`, "Views" (a page load no
longer clears the memory; a process replacement does).

### Later: UI extensions

Not a unit of this plan. It needs its own plan, on the decision and
the hooks of "UI extensions (later)" above.
