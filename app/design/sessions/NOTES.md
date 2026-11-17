# Sessions: open, closed, delete (2026-11-12, proposal)

The reference for plans/ko-sessions.md phase 1 in Kido.app:
mockup.html, one stage per state (the palette mockup's frame).
Questions 3 and 4 of the plan.

## Where closed sessions show

- **The sidebar**: a section "Closed" at the bottom of the list,
  after the open sessions' cards, the section header's style (11pt
  600, the muted label) with the count at the right; one 28pt row
  per closed session, the name in the muted colour, a hollow 6pt
  circle where the status indicator sits (no status: nothing runs),
  no activity line, no children. Hover shows "Open" in the accent at
  the right (11pt); a click on the row selects it (keyboard too),
  a double-click or Return opens it. The section is absent when
  there is no closed session. The rows come from `GET /sessions`
  (key, name), sorted by name; the sidebar re-reads on the server's
  change notification for sessions.
- **The palette**: one root row per closed session, "Open › name",
  with the session icon dashed, after the open sessions' rows and
  before the commands; it is found by the name. Return opens it.
- **The Session menu**: "Open Session ▸" with one item per closed
  session, after the open sessions and before Rename; absent when
  none is closed. "Close Session" stays, under its name: the word
  is right now (it closes, it never destroyed more than the
  layout). "Delete" is not in the menu bar.

## Close, Open, Delete

- **Close** (the menu, the palette, the sidebar's hover × on the
  session card as today): a quiet session closes at once; a session
  with running programs asks, with the stock alert that pane and
  window closing use: "Close the session “main”?" / "Its N running
  programs end: <names>. The session keeps its name, layout and
  settings under Closed, and Open brings it back." Close (default,
  Return) / Cancel (Escape). The card leaves the list; the row
  appears under Closed.
- **Open** (the row's "Open", a double-click, Return, the palette
  row, the menu item): `POST /sessions/{key}/open`; the session's
  card appears with its windows and the focus goes to its first
  window's focused pane; the Closed row goes. A refusal (a runtime
  that resolves nowhere) is a transient notice over the pane area,
  the notices design.
- **Delete**: only from the context menu of a Closed row ("Open",
  a separator, "Delete…") and the Delete key on a selected Closed
  row; always confirmed: "Delete the session “kido-ios”?" / "Its
  layout, context and runtime settings are removed. This cannot be
  undone." Cancel (default, Return) / Delete. The row goes. An open
  session cannot be deleted from the app (the server refuses too):
  close it first, so the two actions never share a menu.
- **Rename** stays on open sessions (the card's double-click, the
  palette, the menu); a closed session is renamed after an open.

## No open session

A window whose server has no open session shows the sidebar with
only the Closed section, no tabs, and the pane area with "No open
session" and "Open one from the sidebar, or press ⌘N for a new
one." with a New Session button. The client makes no session by
itself when closed ones exist. When there is no session at all,
open or closed, it creates one as today, so the first launch looks
as it does now. The terminal client ko_tui, read-only here, lists
the closed sessions in its sidebar under the same header and
opens one with Return; it has no delete.

## Phase 3: the session agent

A direction, not a spec: a koa page in a float over the window,
640×460 centred, titled "Session · name", opened from the palette
("Session › Session Agent…", Cmd-P then the row) and closed with
Escape; the page is the koa page as it is, the agent's tools being
the session routes (config, context). Not a palette mode (the
palette is one line of input, the agent talks back) and not a
sheet (a sheet blocks the window; the agent's changes should be
seen in the sidebar while it works). The pane is a pane of the
session with the role variable, hidden from the sidebar's rows
(the float is its only view) and resumed by the recipe.

Renders: /tmp/koa-shots/sessions-{closed,menu,delete,close,smenu,
palette,noopen,agent}-light.png.
