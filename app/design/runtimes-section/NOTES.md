# Runtimes section of the sidebar (design, mockups only)

`mockup.html` is a self-contained reference for a collapsible
**Runtimes** section at the bottom of Kido.app's sidebar. The user's
motivation: "see which runtimes are configured and running; be able
to start and stop a runtime." It is implemented (docs/design-app.md,
"Runtimes section"); "What the client knows today" below describes
the state before it. The user
decided every point below on 2026-11-06 ("Decisions" at the end).
The states marked "rejected" in
the mockup stay only as the record of the alternatives. Open it through the design preview server
(`python3 -m http.server 8766 --bind 127.0.0.1` from `app/design`, then
http://127.0.0.1:8766/runtimes-section/mockup.html);
`?state=<id>&theme=Light|Dark` selects a state. The states are the
options of the State control; `/tmp/kido-runtimes-section-shots/`
holds a render of each in both themes with a README.

The facts it builds on: docs/design-runtimes.md ("The model",
"Clients", "The link", "Down"), docs/design-app.md ("Sidebar",
"Runtime marks", "Shutting down a runtime", "Command palette"),
docs/protocol.md section 15, plans/adhoc-runtimes.md sections 1 to 3,
and the approved `app/design/runtime/` mockup, whose colour, swatch,
pill and row suffix are reused unchanged. The runtime fixture is the
same four names: buildbox (ssh, up, 3 panes), py311 (container,
down), gpu-1 (ssh, failed, the configured amber `#d08a2a`), e2e
(podman, starting).

## What the client knows today

- The `Welcome` lists every runtime as a `ClientRuntime` (name, kind,
  colour, link state) and the `runtime` and `runtime_deleted` events
  follow it (protocol.md, section 15). The link state is one of
  `Down`, `Starting`, `Up` and `Failed { message }` (`LinkState` in
  `ko_server/src/protocol.rs`). **There is no `Stopping` on the
  wire.**
- The pane count is the app's: `WindowOwner.runtimePaneCount` counts
  the live panes whose row `runtime` is the name. The same count feeds
  the Shut Down sheet and File > Runtimes.
- Shut Down exists: `WindowOwner.shutDownRuntime`, gated by
  `canShutDownRuntime` (starting or up), sends `POST
  /runtimes/NAME/down` with `force`, after the sheet
  `Shut down “NAME”?` with "N panes run in this runtime. Shutting it
  down ends them." (or "1 pane runs in this runtime. Shutting it down
  ends the pane.") when live panes exist.
- Start does not exist: "No request brings a runtime up"
  (design-runtimes.md, "The link"). A runtime starts with its first
  pane or exec session.
- **A configuration file error does not reach clients.**
  `Registry::listed` (`ko_server/src/runtime/mod.rs`) discards the
  `LoadError` of `adopt` (`let _ = self.adopt(loaded)`) and announces
  the list it last read; the `Welcome` and the events carry no error.
  The error reaches a caller only as the `invalid` reply of a runtime
  request (`FILE: runtimes: gpu-1: unknown field "prot"`). The config
  error row below is a proposal that needs a server change.

## 1. The section

**Where (decided: pinned; states `expanded`, `pinned-long`).** Below
the sessions, at the bottom of the sidebar, in the sidebar's shade.
The section is a fixed footer of the sidebar's split: the table of
sessions scrolls above it, the section never scrolls. A 0.5pt
`separatorColor` hairline at its top, inset 8pt at both sides as the
table is. The state "which runtimes are running" is then visible
without a scroll, and the start and stop actions are always one click
away. Cost: 29pt collapsed, 29 + 28·N expanded; with many runtimes
the user collapses it. Rejected: the section as the last block of the
scrolling table (state `scrolling`), out of view in a long tree.

**Header.** A 29pt row like a session header: "Runtimes" in 11pt
semibold `secondaryLabelColor` at the 12pt inset (aligned with the
session labels), the aggregate right-aligned in 11pt regular
`secondaryLabelColor` with tabular digits, then a disclosure chevron
(`chevron.right` collapsed, `chevron.down` expanded, 11pt,
`secondaryLabelColor`) centred 15pt from the right edge, where the
session header's plus sits. The chevron is the only part of the header
that reads as a control; the whole header is the click target. The
collapsed state persists in the app's defaults (one bool), not in ko.

**Aggregate.** Every non-zero count of up, starting, stopping and
failed, in that order, joined with ` · `: `1 up · 1 starting · 1
failed`, the failed part in `systemRed`. All down: `4 down`. When the
header cannot hold the whole string (the 200pt sidebar, state
`narrow`), the first of failed, stopping, starting, up alone:
`1 failed`. The aggregate has an 8pt minimum gap from the label and
never pushes the chevron.

**Rows (state `expanded`).** One row for each runtime of the Welcome,
in its order (name order today; configured first, then ad-hoc, by the
plan). 28pt tall (5pt vertical padding around the 18pt title line),
7pt corners, the sidebar's fonts:

| Element | Geometry | Colour |
| --- | --- | --- |
| Swatch | 6pt circle centred at x=20 (the status dot's column) | the runtime colour (`Chrome.runtimeTint`: configured `color`, else the FNV-1a hue) |
| Name | 13pt regular, from x=36 | `labelColor`; it never truncates below 96pt |
| Detail | 13pt regular, 6pt after the name, one line, truncates at its end with an ellipsis | `secondaryLabelColor`; the failed message in `systemRed` |
| Spinner | 9pt indeterminate (the find capsule's), 5pt after the detail | while starting or stopping |
| Trailing inset | 12pt | the hover button's slot (section 2) |

**Why 28pt and not 32pt (decided: 28pt).** A runtime row is always
one line (no caption, no clock), and the section is a status footer,
not the tree: 4pt less a row keeps four runtimes at 141pt instead of
157pt and sets the section apart from the pane rows at a glance.
Rejected: 32pt rows (state `rows-32`).

**Strings.** `kind · state`, with ` · N panes` only while up and N
is not zero (`1 pane`, `3 panes`); the count is
`runtimePaneCount`'s, live panes with `row.runtime == name`.

| State | Detail |
| --- | --- |
| up, 3 panes | `ssh · up · 3 panes` |
| up, no pane (idle until the idle rule) | `ssh · up` |
| down | `container · down` |
| starting | `podman · starting` + spinner |
| failed | `ssh · failed: ssh: connect to host gpu-1 port 22: Connection refused`; `failed:` and the message in `systemRed`, truncated at the row's end, the whole message as the row's tooltip |
| stopping (client-local, section 2) | `ssh · stopping` + spinner |

The kind is the wire's `RuntimeKind` word: `ssh`, `container`,
`podman`, `command`.

**None configured (decided: hidden; state `none-hidden`).** With an
empty `runtimes` in the Welcome the section does not exist; the table
keeps its 10pt bottom inset. The first `runtime` event adds it, and
the last `runtime_deleted` removes it. A user without runtimes sees
nothing of them, as today. Rejected: a header with `No runtimes`
(state `none-header`).

**Config error (decided: build it in the same unit; state
`config-error`).** A row above the
runtime rows: a `exclamationmark.triangle.fill` in `systemRed` in the
swatch slot, the message in 13pt `systemRed` from x=36, truncated at
the row's end, the file path and the whole message as the tooltip;
the aggregate reads `config error` in red. The rows below it are the
last good list, which is what the registry announces. To build it,
the server adds an optional message to the Welcome (for example
`runtimes_error: Option<String>` beside `runtimes`) and one event
that carries the new value or its absence, set on each read of the
file (`adopt`). A per-runtime error does not exist: the file decodes
as a whole, so one row is right.

## 2. Actions

**Hover (states `hover`, `hover-stop`).** The whole row takes a 5%
`labelColor` fill, and a 16pt button appears at the trailing inset,
vertically centred: `play.fill` for a down or failed runtime,
`stop.fill` for a starting or up one, 10pt glyph in
`secondaryLabelColor`. Hovering the button brightens it with a 10%
`labelColor` fill at a 4pt radius, as the row × does. The detail text
does not move; a long detail truncates 24pt earlier while the button
shows. This is the sidebar's hover-close pattern, at the trailing end
because the swatch slot carries no status to replace and the state
text is the row's purpose. The stop button runs Shut Down through the
existing confirmation when live panes exist; the play button runs
Start (below).

**Click (state `selected`).** One click selects the row (10%
`labelColor` fill, 7pt corners, the sidebar's keyboard-selection
fill). The tree above does not change: the user rejected a highlight
of the runtime's panes on selection, so the selection is only the
keyboard's and the menu's target. The selection clears on Escape, on
a click elsewhere, and when the runtime leaves the list.

**Double-click or Return** opens the palette's runtime step for that
runtime (`PaletteMode.runtime`: New Window, Split Right, Split Down,
Shut Down Runtime), which is today's one place to open a pane in a
runtime.

**Context menu (state `menu`).** Three items, the standard menu:

| Item | Enabled | Does |
| --- | --- | --- |
| Start | down or failed | Start (below) |
| Shut Down… | starting or up | `shutDownRuntime`, with the existing sheet when live panes exist |
| Copy Name | always | the name to the pasteboard |

A "Reveal Panes" item went with the pane highlight.

The same menu opens for a keyboard-selected row with the Action
menu key. Shut Down through any path is the one existing flow; this
design adds no second confirmation text.

**Stopping (state `stopping`).** The wire has no such state. After
Shut Down is sent, the app shows `kind · stopping` with the spinner
and disables both actions until the server's `runtime` event with
`down` arrives or the request fails (then the row shows the server's
state again and the failure goes to the owner's notice sheet, as
today). It is a client-local pending state like a pending close. The
aggregate counts it as `N stopping`.

**Start (decided: a start route).** The server has no start route
today; a runtime starts with its first pane or exec session. The
user chose a route: `POST /runtimes/NAME/up` binds and starts the
link without a pane and returns at once; the row follows the
`runtime` events. Every runtime can start this way: runtimes have
no interactive login step (ssh runs in BatchMode, there is no
leader), so every down or failed row gets the play button and an
enabled Start. The idle rule takes an unused link down after
`runtime_idle_seconds`, so a started link with no pane goes down on
its own. This is a new route in the `routes!` block, approved by the
top-level session, plus a `ko_client` function and an ffi entry. The
button's tooltip is "Start buildbox".

Rejected: Start as the palette step's New Window (a pane in the
runtime). It leaves a pane behind that a user who only wanted the
link up has to close.

## 3. Ad-hoc runtimes (decided: the current session's only; state `adhoc`)

`ClientRuntime` has a `source` (`ko_server/src/protocol.rs`):
`config` or `session { id }`, configured first, then the ad-hoc ones
in session order. The section lists the configured runtimes and the runtimes of
the window's current session only; another session's runtimes do
not appear, and the list changes when the user switches session.
A session-owned row looks like a configured one (`dev   container ·
up · 1 pane`): no suffix and no caption, because every row in the
list belongs to this session or to the config. The aggregate counts
only the listed rows. The row goes when the session goes
(`runtime_deleted`) or when the window leaves the session. Its Shut
Down sends the session query of the plan's section
3.3. Rejected: a ` · main` suffix with every session's runtimes in
one list, and the session's runtimes under a caption `in session
main` (state `adhoc-grouped`).

## 4. The 200pt sidebar (state `narrow`)

The name keeps 96pt, the detail truncates with an ellipsis from its
end (`ssh · up · 3…`), the spinner stays after the ellipsis, the
hover button still fits at the trailing inset, and the aggregate
drops to its first count (section 1). No element wraps.

## 5. Keyboard

The sidebar's table reaches the section as the last rows of its
navigation. Exact keys:

| Key | On the header | On a runtime row |
| --- | --- | --- |
| Down / j | to the first runtime row when expanded, else stays | to the next runtime row; stays on the last |
| Up / k | to the last pane row of the last session | to the previous row; from the first to the header |
| Right | expands | nothing |
| Left | collapses | to the header |
| Return | toggles collapse | opens the palette's runtime step (as double-click) |
| Space | toggles collapse | the hover button's action: Start when down or failed, Shut Down (with the sheet) when starting or up |
| Escape | releases the sidebar's focus to the pane and clears the selection, as today | the same |
| Command-C | nothing | copies the name |
| Action menu key | nothing | the context menu |

The header is the one selectable header in the sidebar, because
collapse needs a key target; session headers stay noninteractive.
Down from the last pane row of the last session goes to the header.
With the section hidden (no runtimes) the keys are unchanged.

## 6. ko_tui (decided: read-only rows; state `tui`)

The terminal client's sidebar is a 24-column cell list
(`ko_tui/src/sidebar.rs`). The section is the last rows of that
column, pinned to its bottom, with one empty row above:

    runtimes      1 up
    buildbox          up 3
    py311             down
    gpu-1         failed ✗
    e2e          starting …

The header is faint (SGR 2) with the aggregate at the right; a row is
the name at the left and the state right-aligned: `up N` (N only
while live panes exist), `down`, `starting …` faint, `failed ✗` in
red; the row truncates at 24 columns as the pane lines do. No colour
swatch (the client has no hue), no collapse, no actions and no
selection: the client stays the minimal mirror, and `ko api
/runtimes/NAME/down` is its stop. Rows appear only when the Welcome
has runtimes. Keys come only if the user asks.

## Decisions (2026-11-06)

1. Pinned, not scrolling.
2. 28pt rows.
3. No runtimes: the section is hidden.
4. Start: a start route, `POST /runtimes/NAME/up`, without a pane,
   for every runtime (approved).
5. The config error row, with its server change, in the same unit.
6. Ad-hoc runtimes: the section lists the configured runtimes and
   the current session's own, with no suffix.
7. ko_tui gets the read-only rows, no keys.
8. No highlight of the runtime's panes on selection.
