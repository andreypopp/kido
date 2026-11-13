# Floats: pop out, dock back, and floats as child windows (2026-11-12)

Two specs for Kido.app, on the user's approved direction. No mockup:
the chrome is the shipped float's (docs/design-app.md, "Floats"), and
the drag feedback is the shipped tiled drag's.

## A · Pop out and dock back (unit float-pop)

**One toggle, two words.** The Pane menu has one item whose title
follows the focused pane: "Float Pane" on a tiled pane, "Dock Pane"
on a float; the palette shows the one that applies ("Pane › Float
Pane" / "Pane › Dock Pane"). One key for both: ⌥⌘F (⌘F is Find,
⌃⌘F full screen, ⇧⌘F free but taken by Finder habits). ko_tui's
`*` toggle is the same pair. Disabled while zoomed, as the grip is.

- **Float Pane**: `Edit::Float` without geometry; the server places
  it. The float becomes the active pane. A single-pane window cannot
  float its pane (the menu item is disabled, the palette row absent):
  a window needs a tiled pane.
- **Dock Pane**: `Edit::Unfloat`; the float docks to the right of
  the window's last-focused tiled pane: the app remembers, per
  window, the tiled pane that was active before a float took the
  focus (ko keeps no such record), forgets it when that pane goes,
  and falls back to the first tiled pane in document order. The pane
  stays the active pane.

**Drag gestures.** Both reuse the tiled drag: the same drop targets
on the tiled panes' edges and the window's edges, the same accent
insertion bar, Escape and a click cancel, a drop on the source cancels.

- **A float's grip over a tiled target** docks it there: the bar
  shows as for a tiled source; the drop sends `dock {pane, target,
  edge}` with the float as the source. Over no target the gesture is
  today's move. A float's drag never shows the pop-out ghost. Only
  the grip button docks (user, 2026-11-13): a drag by the move band
  or the padding (section C) only moves the float, with no targets,
  no bar and no dock on the drop.
- **A tiled grip over no target** pops the pane out at that spot.
  The source pane is a cancel zone: over it, no ghost and no bar, and
  a drop cancels (Option over the source forces the ghost). Feedback,
  once the pointer has left the source: a ghost rectangle follows the
  pointer, the pane's current size clamped to 60% of the pane area in
  each dimension, min 20 columns × 6 rows, its top-left so the pointer
  keeps its position relative to the pane's grip (the grip's x in the
  pane, 14pt from the top); drawn as a 1pt accent stroke at 50%, the
  float's corner radius, a fill of the accent at 8%, over everything,
  no shadow. When the pointer enters a drop target, the ghost goes and
  the insertion bar shows; leaving it, the ghost returns. The drop
  sends `float {pane, geometry}` with the ghost's cell geometry, cells
  from PaneLayout's inverse; the float appears where the ghost was,
  and it is the active pane. A drop with the ghost shown is a pop
  out; a drop on the bar is today's swap or dock.
- **Option** held while a tiled grip is over a target forces the pop
  out: the ghost shows instead of the bar, and the drop pops the pane
  out at the pointer. Option over no target changes nothing. The key
  state is read on the drop and on each move, so pressing Option
  mid-drag switches the feedback at once.
- The last tiled pane of a window cannot be dragged out (the ghost
  never shows; the drag is today's: no targets, so a drop cancels).

## B · Floats as child windows (unit float-win)

Each float is a borderless child `NSWindow` of the main window, with
today's chrome drawn by the app: the grip toolbar, the 1pt border, the
corner radius, the drawn shadow. `hasShadow` is off; the drawn shadow
is the only one, so a float looks the same inside the main window and
past its edge.

What changes visibly:

- **At the main window's edge** nothing clips: the float, its border,
  its corners and its shadow continue past the edge, over the desktop
  or the window behind. The float keeps its own four rounded corners
  everywhere; the main window's corner is simply under it. Position
  past the edge is local: the `float` edit carries the geometry
  clamped to the cell grid (other clients see it at the edge; ko_tui
  unchanged); the local frame does not snap back on release, and
  follows a later layout only when the layout's position differs from
  the clamped one it sent (another client moved it). Size syncs by
  the `float` edit as today.
- **Full screen**: floats stay child windows over the full-screen
  window; the screen's edge is the limit (a float cannot leave the
  screen; the clamp is the screen's, and the local frame equals the
  sent one). Entering or leaving full screen keeps each float's cell
  geometry; the frames follow the new grid.
- **Minimized**: floats hide (`orderOut`) when the main window
  miniaturizes and return at deminiaturize, so the Dock tile is the
  main window alone. **Hidden app**: the same, by AppKit.
- **Tab switch, session switch, zoom**: the floats of the shown
  window appear, every other float hides, without animation, in the
  same layout pass that moves the tiled panes; zoom hides every float
  as today. A float whose pane goes closes its window.
- **Ordering** (user, 2026-11-13): the active float is the top
  float. Every focus change to a float raises it: a press, keyboard
  navigation, the sidebar row, Back/Forward, the palette, an @name
  link, Cmd-1…9 to a window whose active pane is a float, a focus the
  server moves. It sends the `float` edit of the z order as the press
  does and `orderFront`s the window in the same layout pass that
  shows the focus; the children's order is the floats' z order. A
  focus change to a tiled pane leaves the float order as it is.
- **Focus.** The main window stays the main window (its title bar and
  traffic lights active) while a float window is key: the float is
  a non-activating child that can become key. When the float is key:
  its pane is the active pane, with the 1pt accent focus stroke and a
  solid cursor; the main window's tiled panes follow the not-key rule
  (hollow cursor, no stroke, no 3% shift), and the other floats keep
  their 45% inactive overlay. When the main window is key: its active
  tiled pane has the stroke and the solid cursor, and every float has
  the overlay, the last-active float too. A click anywhere in the
  main window (sidebar, tabs, a pane) makes it key; a click in a float
  makes that float key. The menu bar and ⌘-shortcuts act on the key
  window's pane: the Pane menu on the float's pane while the float is
  key. The palette opens over the main window as today and returns
  key to the window it took it from.
- **Dragging** the main window moves the floats with it (child
  windows), with no edit: the cell geometry is unchanged. A resize of
  the main window re-lays the floats by their cell geometry, as today.
- **Notices** stay above floats: the pane-area notices column (the
  transient card, the config notice) becomes its own borderless child
  window ordered above every float child, re-asserted when a float is
  raised; non-activating, never key, hit-testing as today (the card
  takes its dismissing click, the rest passes through). The
  connection banner keeps hiding the floats.
- **Mission Control, Exposé, Stage Manager**: the floats are grouped
  with the main window (child windows are); nothing to add.

## C · Handles that can be hit (user, 2026-11-13)

The 5pt edges were too thin.

- **Move: the top band.** The float's top padding is 10pt of chrome
  above the grid (no cells under it); the move handle is a 16pt band
  straddling the top edge, 10pt inside (that padding) and 6pt outside
  in the drawn shadow's margin, the full width; the hover toolbar
  sits on it and keeps precedence. Cursor: open hand, closed while
  dragging. The toolbar's grip button stays, and it is the only
  handle that docks (section A); the band and the draggable padding
  elsewhere only move the float. Visible on hover of the band: a 36×4pt pill
  centred in it, 2pt radius, the foreground at 25% in both themes,
  120ms fade; nothing otherwise.
- **Resize: the bottom-right corner first.** A 20×20pt square
  straddling that corner (12 in, 8 out), the system's diagonal
  resize cursor. The other corners keep 12×12 (6 in, 6 out) and the
  four edges an 8pt band (4 in, 4 out); the top edge's band wins over
  the move band in its 4pt. Visible on hover of the float: a corner
  mark in the bottom-right padding, two diagonal 1pt lines 4pt apart,
  8 and 4pt long, the foreground at 30%, 3pt inside the corner;
  nothing otherwise.
- **Precedence**, outside-in: resize corners, resize edges, the
  toolbar, the move band, the padding, Ghostty's grid; a click inside
  the grid is always the terminal's.
- **Child windows**: the float window's frame carries an 8pt margin on
  every side for the shadow, so the outside halves of the hit areas
  are inside the float window and work past the main window's edge.
  No separate light/dark values. ko_tui unchanged.

## D · Closing a float: the confirmation (user, 2026-11-13)

Cmd-W on a float dragged past the main window's edge showed the
main window dimmed, a flat grey rectangle around the float (the
float window's shadow margin veiled), the sheet on the main window
far from the float, and a five-line title (the editor's temp path).

- **Attach**: the alert is a sheet of the float's own child window,
  hanging from the float's top edge, centred on it, wherever the
  float is. A float narrower than the alert (under about 440pt) gets
  the alert centred over its frame instead. (Built: AppKit places
  the sheet; on macOS 27 it centres it on a float taller than the
  sheet, and a forced top hang did not hold, so the app does not
  position it.) Modal to the float only:
  the main window keeps its look and takes clicks.
- **Dim**: only the float, with its inactive treatment (the 45%
  theme-background overlay), a layer of the float's content view
  clipped by its corner path; nothing outside the drawn frame, no
  veil on the main window. Light/dark: the theme's, as today.
- **Title**: "Close “<name>”?", the name as the sidebar shows it,
  truncated in the middle to 40 characters on one line. The text
  stays "A program is still running in this pane. Closing the pane
  will end it."
- **The editor float's name**: koa sets the pane's title "Draft for
  @ko" (its own name) when it opens the editor pane, and that title
  wins over the program's OSC title in the sidebar, the tab and the
  alert (the pane's `fixed_title`, preferred over the OSC title). The
  sidebar row's activity is the program ("nvim").
- **No confirmation for the editor float**: koa creates its pane
  with `close_confirm: never`; the app closes it without asking; koa treats
  the close as a cancelled edit: the composer keeps the draft it held
  while editing, and one info row says "editor closed · the draft is
  as before". A normal editor exit returns the text as today. Every
  other float with a running program asks, as above.
