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
  its pane is the active pane, with a solid cursor (and, until
  2026-11-21, the 1pt accent focus stroke: a float draws none now,
  section E "The paper"); the main window's tiled panes are all unfocused
  (hollow cursor, no stroke, the 3% shifted paper, also on a sole
  tiled pane: user, 2026-11-20, section E "The paper"), and the
  other floats keep their 45% inactive overlay. When the main window
  is key: its active tiled pane has the stroke and the solid cursor,
  and every float has the overlay, the last-active float too. A click anywhere in the
  main window (sidebar, tabs, a pane) makes it key; a click in a float
  makes that float key. The menu bar and ⌘-shortcuts act on the key
  window's pane, and never on the main window while a float is key
  (section F, "The menu while a float is key": the Window and
  Session menus are disabled then). The palette opens over the main
  window as today and returns key to the window it took it from.
- **Dragging** the main window moves the floats with it (child
  windows), with no edit: the cell geometry is unchanged. A resize of
  the main window keeps each float where it is (section E; it
  re-laid them by their cells before).
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

- **Move: the top band.** The float's top padding is chrome above
  the grid (no cells under it): 10pt here, 22pt since section F; the
  move handle is a band straddling the top edge, the padding inside
  and 6pt outside in the drawn shadow's margin, the full width; the
  hover toolbar sits on it and keeps precedence. Cursor: open hand,
  closed while dragging. The toolbar's grip button stayed here as the
  only handle that docks (section A); section F removes it from a
  float's toolbar, and the band docks with Option. A runtime float's
  3pt stripe sits at the bottom of that padding, directly above the
  first row (the band is chrome, the stripe marks the runtime's
  content). Visible on hover of the band: a 36×4pt pill
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

## C · The toolbar button: Float Pane / Dock Pane (2026-11-18, spec)

The user wants the ⌥⌘F toggle of section A as a button on the pane,
so a float docks and a tiled pane pops out without the menu.

- **Which toolbar.** The pane's hover toolbar (design/pane/NOTES.md,
  "Hover toolbar"), on tiled panes and floats alike: the one capsule
  gets one more button, between Zoom and the separator. The capsule
  is 171pt wide (was 145): buttons at x 3, 29, 55, 81, 107, the
  separator at 137, Close at 142, all at y 3; the frame still ends
  8pt from the pane's right edge, the hot zone follows. The find
  rule (the toolbar at y 48 while find is open) is unchanged.
- **The glyphs.** `pip.exit` for Float Pane on a tiled pane and
  `pip.enter` for Dock Pane on a float: the picture-in-picture pair
  is the pop-out and the return. The same size and colours as the
  other toolbar symbols. Accessibility labels "Float pane" and "Dock
  pane"; no tooltips, as the other toolbar buttons have none.
- **What it does.** Exactly the menu item: Float Pane sends
  `Edit::Float` without geometry; Dock Pane sends `Edit::Unfloat`
  with the dock rule of section A (the window's last-focused tiled
  pane, else the first; a child float beside its parent when the
  parent is tiled in that window). "Pop out" is a float, and with
  section B every float is a child window, so there is no second
  kind; nothing new to choose.
- **Disabled, not hidden**, so the toolbar's geometry never shifts:
  at 35% opacity like the grip, while the pane is zoomed and on a
  window's sole tiled pane (section A: a window needs a tiled pane).
  Never hidden. ko_tui gets nothing: its toggle is `*`.
- **Focus after.** As the menu: the new float is the active pane; a
  docked pane stays the active pane. The toolbar of the pane that
  moved shows only if the pointer is over its new hot zone, else it
  is gone with the old frame; no toolbar is shown on the pane that
  took the place.
- **Snapshots** (light and dark, PaneChrome's toolbar states): the
  toolbar on a tiled pane of a two-pane window (Float enabled); on a
  float (Dock); on a window's sole pane (Float disabled); while
  zoomed (Float disabled, with the grip); the toolbar at its new
  width under an open find bar. The existing toolbar snapshots are
  re-recorded at 171pt.

## E · Floats are top-level windows (2026-11-20, spec)

The user, after section B shipped: floats become top-level macOS
windows, independent of the main window. Moving the main window does
not move them; switching the main window to another session or window
does not hide them. A pane-area resize does not reset them (the first
request of the day, folded in here: a float's local frame is a screen
frame). AppKit's child windows gave following, ordering above the
parent, minimise and Space for free; each is now a rule of ours.

- **Which floats are on screen.** Every float pane of the connected
  server, from the moment the client learns of it (the layout that
  creates it, a pop out, a reconnect) until it is docked, closed or
  its pane goes; what the main window shows does not matter. A float
  whose session or window the main window does not show is as real
  as the others. Seen-state and clipboard-read permission count a
  float as "shown in an attended window" while its window is on
  screen and Kido is active, whatever the main window shows.
- **The owner.** A float belongs to one Kido window: the one
  connected to its server. With several Kido windows on one server,
  the first in window order owns every float of that server, and the
  others show none (a float is never doubled); when the owner
  closes, the next window on that server adopts its floats with
  their frames. When the last window on the server closes, the
  floats close with it (the panes live on). On reconnect in a
  running window the frames stay; on relaunch they are gone, and the
  floats reappear at their cell geometry in the owner's pane area,
  as a float without a local frame does today. No position memory
  beyond the run.
- **Level and order.** Normal window level; no panel. A float is an
  ordinary window of the app: a click on the main window brings it
  above the floats, a click on a float brings that one to the front.
  Every focus route to a float (section B's list) orders it front;
  focusing a tiled pane does not reorder. Floats are on all Spaces
  (`canJoinAllSpaces` with `fullScreenAuxiliary`): a float stays on
  screen over the main window's full-screen Space and over every
  other Space, which is what "independent" means for a window that
  the user put somewhere. ⌘\` cycles the floats with the main window;
  Mission Control, Exposé and the Dock menu list them as windows
  under their titles (next); Hide Kido hides all. No minimise for a
  float, and no menu change: the app has no Minimize command, the
  Window menu stays the ko windows' menu (no native window list, no
  Bring All to Front; ⌘\` cycles), and a float is borderless, so it
  cannot be minimised; a float that is in the way is docked or
  closed. Minimising the main window (the title bar's button) leaves
  the floats on screen: the user asked for independence.
- **Focus.** A float that becomes key makes its pane the server's
  active pane, as today; the main window does not switch session or
  window for that: its tabs and the shown ko window stay, and the
  sidebar marks no row (a float has none, section F). A focus route that
  lands on a tiled pane (⌘[, the sidebar, the palette, Back/Forward)
  switches the main window to show it, as the sidebar does today; a
  route that lands on a float never switches the main window.
- **The paper** (user, 2026-11-20; replaces "no 3% shift" in
  section B and the same in docs/design-app.md "Focus treatment").
  One rule: the focused pane is the pane of the key window among
  Kido's, and it alone has the pure paper and the solid cursor, and
  the stroke if it is a tiled pane among several; every other pane
  is unfocused. An unfocused tiled pane has
  the 3% shifted paper, no stroke and a hollow cursor, so while a
  float is key every tiled pane of the main window is shifted, a
  sole tiled pane too (the single-pane exception of "Focus
  treatment" holds only while the main window is key, when that pane
  is the focused one). A float draws no focus stroke, ever (user,
  2026-11-21): it is alone in its window, as a sole tiled pane is,
  and its window edge is its border. A float's paper is never
  shifted: a key float is pure paper, solid cursor, no stroke, no
  overlay; a float that is not key (the main window key, or another
  float) is pure paper under its 45% theme-background overlay,
  hollow cursor, no stroke. A koa page follows its pane's paper through
  `--ko-bg`, so the page of a tiled koa pane dims while its editor
  float is key. A sheet or panel over a Kido window (the close
  confirmation of section D, a save panel, the command palette,
  which opens over the main window or, from a float, over the main
  window and returns key to the float: it counts for the window it
  took key from) counts as that
  window being key for the paper, the stroke and the overlay: a
  sheet on a float keeps the float's paper pure (no stroke, as
  never) under section D's dim, which is the same 45% treatment, so
  a float under its own sheet looks like a not-key float, and the
  tiled panes stay shifted; a sheet on the main window keeps its active
  tiled pane pure with the stroke. Only the cursor follows the key
  panel, hollow under a sheet as today. When no Kido window and no
  sheet of one is key, the not-key rule as today: no pane is
  focused, every tiled pane shifted, every float under the overlay.
- **One transition, no blink.** A key handoff between two Kido
  windows (main to float, float to main, float to float) is one
  change of the focused pane, painted once: AppKit sends resign-key
  to one window before become-key to the other, and the intermediate
  "no key window" state must never reach the screen. The app derives
  the focused pane from the key window on become-key and repaints
  both windows' panes (paper, stroke, cursor, overlay) in that one
  pass; a resign-key repaints only when the key goes outside Kido,
  which it tells apart by deferring the resign-key repaint to the
  next run-loop turn and dropping it when a Kido window became key
  meanwhile. The paper and the stroke of one pane change in the same
  draw, never in two.
- **Identity on screen.** The window title (Dock menu, Mission
  Control, ⌘\`, accessibility) is "<pane title> — <session> /
  <window>", the pane title as the tab shows it. On the float
  itself, nothing (section F removed the place capsule of this
  bullet; the rest of the bullet is history). Before: nothing new
  while its ko window is the one the main window
  shows; when it is not, a native **place capsule**, drawn by
  Kido.app over the float for every pane kind (the app has no native
  breadcrumb any more; koa's view bar is the page's): the pane
  capsule family (koa NOTES, the breadcrumb pill's geometry: 22pt
  high, 8pt radius, 11pt system font, pane background mixed 8%
  toward the foreground, the 0.5pt edge and the contact shadow),
  content "<session> › <window>" in the muted colour, the "›" at
  the ancestors' tone, nothing else: no pane ancestors and no pane
  title, because the float is the pane. The whole capsule is a
  button, a hand cursor, no hover: a click switches the main window
  to show that ko window and keeps the float key. Placement: at (8,
  8) of the pane's content, under the move band and the runtime
  stripe (which stay in the 10pt chrome above); when the COPY or
  history pill shows, COPY stays at (8, 8) and the capsule sits 6pt
  to its right, as the old breadcrumb did. For a koa pane the app
  sets the page's `--ko-inset-top` to 30px while the capsule shows
  (0 otherwise), and the page lays its view bar and transcript out
  below that inset, so the view bar never sits under the capsule.
  Truncation: the capsule may use the width up to 6pt before the
  hover toolbar or the find capsule; the session is middle-
  ellipsized first, then the window, each to at least 40pt; if even
  that does not fit, the capsule is hidden, never clipped. The
  runtime stripe, the hover toolbar, the close confirmation
  (section D: attached to the float) and the
  focus treatment are unchanged. Notices stay in the main window:
  a transient notice about a float's pane shows in the owner's
  notices column, and the connection banner hides the floats as
  today (a hidden float is not "shown").
- **The screen rule.** A float's local frame is a screen frame. A
  resize of the main window, of the docked sidebar or a full-screen
  change leaves the floats where they are and sends nothing; a float
  without a local frame follows its cells on the new grid. The one
  constraint, applied at a resize, a screen change and on adoption,
  as a move and never a resize: the whole move band and 60pt of
  the width inside the visible frame of the screen that holds the
  float (menu bar and Dock excluded). Never inside the main window: a
  float may cover the sidebar, the toolbar, the tabs, the edge, or
  lie outside. Not during a gesture (2026-11-21): while a float is
  dragged the window follows the pointer, a screen change that the
  drag itself causes is not a moment of the rule, and the rule runs
  once at the drop.
- **Size: the server's cells** (user, 2026-11-20: the server keeps
  clamping floats into the ko window's room on every float edit and
  every ko-window resize, and this unit leaves the server unchanged).
  The float's size follows the layout's cells, the pty's truth, in
  the float's own grid; its local frame keeps only x and y. So a
  layout that changes the ko window's size is a clamp, not another
  client's move: the float keeps its screen x and y and takes the
  layout's size, so a main-window shrink can shrink a float, and a
  float is never larger than the pane area's room on this Mac. Only
  an x and y change in a layout whose ko window size did not change
  (another client's move) releases the local frame, as today. A move
  or resize edit sends the cells clamped into the grid, as today.
  Follow-up, not in this unit: the server keeps float cells through
  resizes and ko_tui clips, which frees the size on this Mac.
- **Docking.** The drop targets are the tiled panes of the ko window
  the main window shows, and only when that is the float's own ko
  window; over any other content the drag shows no bars and a drop
  leaves the float where it was dropped. Dock Pane (⌥⌘F, the
  toolbar button, the palette, the menu) from a float whose ko
  window is not shown first switches the main window to show it, then
  docks beside the remembered last-focused tiled pane (section A).
  Float Pane is unchanged.
- **ko_tui and other clients** are unchanged: the server keeps the
  cell copies; a terminal client shows a float inside its ko window
  as today.
- **Tests.** WindowOwner or WindowView tests, no snapshot: a float
  keeps its screen x and y through a main-window move, a resize, a
  sidebar width change, a session switch and a full-screen entry,
  and takes the layout's size when a shrink clamps its cells; a
  float without a local frame follows its cells; a float of another
  session is on screen, shown for the seen-state, and its window
  title names the session and window; focusing it does not switch the main
  window; Dock Pane from it switches first; a second Kido window on
  the same server shows no floats and adopts them when the first
  closes; the screen rule moves a float by the least amount.

## F · A float is a window, not a row (2026-11-21, spec)

The user, after section E shipped: a float is its own macOS window,
so it is not in the sidebar, carries no chip, has no grip, and the
keyboard never reaches the main window through it. Its lifecycle
does not change: the server's cascade still closes a float with its
parent pane (koa's editor float with koa's pane), and Dock Pane,
Float Pane and the close confirmation (section D) stay as they are.
The mockup is `mockup.html` (light and dark): the float's chrome
before and after, the band's hover, the toolbar, a runtime float,
the Option drag, and the sidebar without the float's row.

- **Not in the sidebar.** The rows of a window are its tiled panes;
  a pane that floats has no row, and neither do its program records
  (OSC 7501) and its folded cluster: they are the float's, and the
  float is a window of its own. A child pane that is itself a float
  is absent; a tiled child pane of a float keeps its row in its own
  window, at depth 0 (its parent has no row). The folded cluster of a
  pane counts only its tiled children. Tabs do not change: the
  window's tab stays, and its status aggregate still takes the
  window's floats (a waiting agent in a float still marks the tab and
  notifies, as today). While the active pane is a float, no row has
  the focus fill, and the keyboard selection is where it was; a focus
  route that lands on a float raises its window and marks no row.
  The palette lists a float under its window as today, as the one
  list that finds a float besides ⌘\` and the Dock menu, and
  Back/Forward keeps float targets. A float's pane closing, docking
  or floating changes the rows in the same snapshot as the layout.
- **No chip** (user, 2026-11-21: confirmed). The place capsule of section E ("<session> ›
  <window>") goes, with the `--ko-inset-top` it set: the float's
  identity is its window title (Dock menu, Mission Control, ⌘\`),
  and nothing is drawn over a float's content for it. `PanePlaceCapsule`
  is deleted.
- **No grip; a taller top padding.** A float's hover toolbar has no
  Drag pane button, and no Split right, Split down or Zoom either
  (2026-11-21, the floatf unit's question: ko refuses a split of a
  float and zoom hides it, so they would be buttons that never
  enable): Dock Pane, separator, Close pane, at the tiled toolbar's
  spacing (Dock at x 3, the separator at x 33, Close at x 38), 67×32pt
  at (paneWidth − 8 − 67, 8);
  the tiled toolbar keeps its six buttons and its 171pt. Instead the top
  padding, the chrome above the grid with no cells under it, grows
  from 10pt to 22pt (`PaneLayout.floatTop`): padding, not border,
  because a thicker border would read as a frame of another colour,
  and the padding is paper the user already drags. The move band is
  then 28pt: the 22pt padding inside and 6pt outside in the shadow's
  margin, the full width, the toolbar over it with precedence; the
  hover pill (36×4pt, 2pt radius, foreground 25%, 120ms) is centred
  in the padding, at y 9–13 of the frame. The resize zones of
  section C are unchanged (the top edge's 8pt band wins over the
  move band in its 4pt). A runtime float's 3pt stripe sits at the
  bottom of the padding, y 19–22, directly above the first row. The
  COPY and history pills, the find capsule and the runtime pill keep
  their places in the content, below the padding: find at content y
  8 (frame y 30–62), and while it is open the hover toolbar sits
  below it at content y 48 (frame y 70), as the tiled rule has it
  (design/pane/NOTES.md); the toolbar is never hidden and find is
  never narrowed for it. A koa page's
  `--ko-inset-top` is 0 in a float (nothing sits over the page).
  The float's size in cells does not change; the window is 12pt
  taller for the same grid.
- **Docking by drag.** A drag by the band moves the float, with no
  drop targets and no bar, as before (user, 2026-11-13: a float that
  is moved over the main window must not dock by accident, and a
  top-level float lives over the main window more than ever). The
  deliberate dock by drag stays, under Option: while Option is held
  during a band drag and the pointer is over a tiled pane of the
  float's own ko window shown in the main window, the drop targets
  and the accent insertion bar show as for a tiled source, and the
  drop sends `dock {pane, target, edge}`: pane-edge targets only,
  no window-edge zone and no swap (a float has no place to swap
  with); releasing Option hides
  the bar and the drop is a move; over any other content the drag is
  a move with or without Option. Option is read on each move and on
  the drop, as the pop out's is (section A). A band move commits
  once, on the drop: the window follows the pointer locally and
  nothing streams to the server during the drag, so Escape or a
  click cancels and the float returns to where it started (the
  floatf unit, 2026-11-21). A float's drag never shows the
  pop-out ghost. The other docking routes are unchanged: Dock Pane
  in the Shell menu (⌥⌘F), the toolbar button, the palette.
- **The menu while a float is key.** The key window's first
  responder is the float's pane, and nothing acts on the main window
  (the user: ⌘{ and ⌘} must not switch the main window's tabs).
  Three kinds of items, by menu, with their keys; "disabled" means
  the item is grey and its key does nothing, neither in the main
  window nor in the float's program:
  - Kido: Hide Kido, Quit Kido (⌘Q): app-wide.
  - File: New Session (⌘N), New Window (⌘T), New Agent (⇧⌘N):
    app-wide, as today: the new session or window is made on the
    float's server, shown in the main window, which becomes key.
    Close Window: disabled (it would close a window the user does
    not see as the float's). Connect to Local Host, Connect to Remote
    Host… (⇧⌘K), Pair Server…, the Runtimes submenu: app-wide.
  - Shell: Close Pane (⌘W): the float's pane, with section D's sheet
    on the float. Dock Pane (⌥⌘F): the float's pane. Split Right
    (⌘D), Split Down (⇧⌘D): disabled (ko refuses a split of a
    float). Zoom Pane (⇧⌘↩): disabled. Select Pane Left, Above,
    Right, Below (⌥⌘ arrows, ⌘H ⌘J ⌘K ⌘L), Next Pane (⌘]), Previous
    Pane (⌘[): disabled; they would move the focus in the main
    window's layout. Back (⌃⌘[), Forward (⌃⌘]) and the mouse's back
    and forward buttons on a float: disabled; the history is the
    main window's.
  - Edit: Undo, Redo, Cut, Copy (⌘C), Paste (⌘V), Paste and Match
    Style, Delete, Select All (⌘A), Find… (⌘F), Find Next (⌘G), Find
    Previous (⇧⌘G), Reload Page (⌘R), Prompt with Selection… (⌘O),
    Copy Mode (⇧⌘C), and the pane's context menu: the float's pane,
    as today (⌘O's palette opens over the main window and returns
    key to the float). Reset Clipboard and Upload Permissions:
    app-wide.
  - View: Hide Sidebar (⇧⌘S), Focus Sidebar (⌘S): disabled (user,
    2026-11-21: ⌘S is not the way out of a float). Command Palette… (⌘P,
    ⇧⌘P): app-wide, over the main window, key back to the float on
    close unless the palette navigated. Theme…: app-wide.
  - Window: Next Window (⌘}), Previous Window (⌘{), the window list
    (⌘1…⌘9): disabled.
  - Session: Next Session (⌥⌘]), Previous Session (⌥⌘[), the session
    list, Rename Session…, Close Session: disabled.
  - Full Screen (⌃⌘F) is the main window's native item; a float has
    no title bar and no full screen, so the key does nothing in a
    float. ⌘\` cycles the windows, floats included, as AppKit does.
  The keyboard's way back to the main window is ⌘\` (and ⇧⌘\`),
  the system's own cycle, which a borderless float takes part in
  (section E); no command of ours is needed, and none is added:
  the palette (⌘P) also returns to the main window when a row
  navigates to a tiled pane, and a click does the rest. The main
  window's own shortcuts work again the moment it is key.
  The palette's rows follow the same table: while a float is key the
  palette's root hides the Window and Session rows that are disabled
  (Next/Previous Window, Next/Previous Session, Close Window, Rename
  Session, Close Session, Hide Sidebar, Focus Sidebar, Zoom Pane,
  Split Right/Down),
  and keeps the sessions, panes, recent hosts and app-wide commands.
- **Float again, same place** (user, 2026-11-21). A pane that is
  docked and then floated again comes back where it was and at the
  size it had. What is remembered: for each pane, by its pane id, in
  the Kido window that owns the server's floats (section E): the
  float's last screen origin and its last cell size (cols × rows;
  the size is the server's, in cells, section E "Size"), taken from
  the frame the float showed when the layout turned it tiled, by any
  route: Dock Pane, the Option drop, another client's `unfloat`.
  How long: for the run of the app, while the pane lives; across a
  reconnect in a running window (as the frames are) and across an
  adoption (the memory moves with the float frames); not across a
  relaunch (section E: no position memory beyond the run), and gone
  when the pane goes. What uses it: Float Pane (the menu, ⌥⌘F, the
  toolbar button, the palette) on a pane with a memory sends
  `Edit::Float` with the remembered cols and rows and with x and y
  as a move would send them, the remembered origin mapped into the
  ko window's cell grid and clamped (the server clamps the cells
  into the window's room as on any float edit, so the size may come
  back smaller when the room shrank); when the layout shows the
  float, the app gives it the remembered screen origin as a local
  frame, the way a pop out holds its ghost's frame until the float
  appears, then applies the screen rule of section E (the move band
  and 60pt of the width inside the visible frame of the screen that
  held it, else of the main window's screen; a move, never a
  resize). So a display that went away or shrank moves the float
  the least amount and keeps its size, and a smaller pane area
  shrinks it through the server's clamp, as section E has it. The
  memory is used once: the layout that shows the float again clears
  it, whichever client floated the pane (a float that another client
  creates appears at its cells, as today, and the memory is cleared
  then too). A pop out by drag (the tiled grip's ghost, section A)
  is an explicit placement: it uses the ghost's frame and clears the
  memory. A pane that was never a float, or whose memory is gone, is
  unchanged: Float Pane sends `Edit::Float` without geometry, and
  the server places it.
- **Dock into another window** (user, 2026-11-21). A float docks by
  drag into any ko window of its own session that a Kido window of
  the same connection shows; without a target it docks back into
  the window it came from.
  - *The targets.* During an Option band drag (above), the drop
    targets are the pane-edge targets of the tiled panes that the
    Kido windows of the float's connection show, when the ko window
    shown is of the float's session: the owner's main window and
    every other Kido window on the same server (same server
    instance, same session; not another session, never another
    server). The Kido window under the pointer is found by the
    screen point, front to back, among those windows' main windows
    (float windows, the dragged one included, are never targets);
    its WindowView supplies the targets and draws the bar in its own
    pane area, as it does for a tiled source; moving to another
    window clears the bar there and shows it here, one bar at a
    time. No Kido window changes order during the drag, and the
    main window does not switch what it shows to offer targets: a
    ko window of the session that no Kido window shows has no
    targets (switch the main window to it first). The float itself
    moves under the pointer and never shows the ghost.
  - *The edit.* The drop sends `dock {pane, target, edge}`, as a
    dock in the own window does: `ko_client`'s `Dock` takes the pane
    from the window whose floats hold it and puts it beside the
    target in the target's window, and the layout `PUT` carries the
    move (a pane can move between windows, protocol.md, section 7;
    the source window's focus moves in the same layout event). No
    new route and no new edit; the window-edge `dock_window` and the
    swap are not offered to a float (above). A child float may dock
    into another window: a tiled child is valid in any window and
    is a root of that window's tree (design.md, "Who is
    authoritative for what"); its edge still decides its lifetime.
    The server's rule that a floating child is valid only in its
    parent's window goes (user, 2026-11-21): a child may float in
    any window, so the window a child is docked into is a window it
    can float in again; the lifetime edge is unchanged.
  - *After the drop.* The docked pane is the focused pane of its
    new ko window, as a dock in the own window keeps it active, and
    the Kido window that received the drop becomes key (it shows the
    pane; the user dropped there). The owner's float window closes
    in the layout pass that shows the pane tiled. The source ko
    window's focus goes to its last-focused tiled pane (the server
    moves it when the focused pane leaves; the app's per-window
    memory of section A agrees). The ownership of the floats does
    not change.
  - *Dock Pane without a target* (⌥⌘F, the toolbar button, the
    palette, the menu) docks the float back into the window it came
    from: the ko window it was floated from (Float Pane, the pop
    out), or, for a pane created as a float (koa's editor), the
    window it was created in. That window is always the ko window
    whose floats hold it: a float never changes ko window while it
    floats (a `float` edit keeps its window), so the origin needs no
    memory, and Dock Pane is as today: beside the remembered
    last-focused tiled pane of that window (section A), after
    switching the main window to show it when it does not
    (section E). A child float docks in its own window: beside its
    parent when the parent is tiled in that window, as today; else
    beside the remembered last-focused tiled pane, like any float.
  - *Float again, same place* (above) for a pane that was docked
    into another window: the memory is the pane's, by id, in the
    owning Kido window, and it holds a screen origin and a cell
    size, nothing about a ko window; Float Pane floats the pane in
    the ko window it is tiled in now, at the remembered screen
    origin and size, clamped to that window's room: the same place
    on screen, which is what the user remembers. A child is no
    exception (the parent's-window rule is gone): it floats again in
    the window it is tiled in, at its remembered place.
- **Tests.** Rows: a window with a float lists its tiled panes only,
  a float's records and cluster are absent, a tiled child of a float
  is a depth-0 row, the cluster count omits a floating child, the
  tab's aggregate includes the float, no row is focused while the
  float is the active pane. Chrome: a float's toolbar has two
  buttons (Dock Pane, Close pane) at 67pt, the pill is at y 9–13, the
  stripe at 19–22, the
  grid starts at 22pt. Menu: with a float key, validate returns false
  for every item of the disabled list and true for the others, and
  ⌘} with a float key leaves the shown window unchanged; an Option
  band drag over the shown ko window's tiled pane shows the bar and
  docks, the same drag without Option moves. Float again: a dock
  then Float Pane sends the remembered cols, rows, x and y and the
  float shows at its old screen origin; a second Float Pane after
  another dock in a smaller pane area comes back clamped in size
  and moved the least amount; a pop out by drag ignores the memory;
  a never-floated pane sends no geometry; the memory does not
  survive a relaunch. Another window: an Option band drag over a
  tiled pane of a second Kido window on the same server showing the
  same session shows the bar there and the drop sends `dock` with
  that target, the pane is focused in the second window, which is
  key, and the float window is gone; over a Kido window showing
  another session, no bar and the drop moves; over another server's
  window, the same; Dock Pane without a target after the main
  window switched to another session docks into the float's own ko
  window; Float Pane after a dock into another window floats the
  pane in that window at the old screen origin, a child too; Dock
  Pane on a child float whose parent is in another window docks it
  beside that window's last-focused tiled pane.
