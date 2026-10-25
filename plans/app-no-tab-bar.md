# Kido.app without the tab bar

Status: step 1 (the spike) is implemented, without the `kido-titlebar`
key: the branch is the experiment. The toolbar is gone, the sidebar top
row holds the toggle and New Session, and `WindowView` keeps the top
16pt free. With spacing, the gap above the cards is the strip.
`WindowTabs` still exists but is not in the window.

## The problem

The window has a unified `NSToolbar`. It is 52pt high. It holds the
traffic lights, the sidebar toggle, New Session and `WindowTabs`.
At Menlo 13 (17pt rows), the band costs 3 terminal rows.

## Measured facts (macOS 27.0.1, a probe window)

| Title bar | Band | Traffic lights (x, center from top) |
| --- | --- | --- |
| `.unified` toolbar (today) | 52pt | 19...79, 26pt |
| `.unifiedCompact` toolbar | 40pt | 12...72, 20pt |
| No toolbar | 32pt | 9...69, 16pt |
| `.expanded` toolbar | 68pt | 9...69, 16pt |

With no toolbar, `.fullSizeContentView` and a transparent title bar:

- The content view reaches the top edge of the window. The sidebar glass
  goes to the top, with the traffic lights in it.
- Inside the 32pt band, a click goes to the content view under it. A
  probe view at 20pt from the top got the click. Thus, the terminal can
  start above 32pt and stay usable.
- A view in the band that does not take the mouse
  (`mouseDownCanMoveWindow` is true) drags the window natively. A
  double-click on it does the system action (zoom or minimize).
- Below the band, a view can call `NSWindow.performDrag(with:)` from
  `mouseDown`. A double-click must then read `AppleActionOnDoubleClick`
  and do the action itself.
- AppKit adds `NSTitlebarBackgroundView` (32pt) over the sidebar and the
  content. In the probe, it drew nothing. `docs/design-app.md` says that
  "without it AppKit adds a plain titlebar strip". The probe render
  (`cacheDisplay`) does not draw the real glass. Thus, step 1 must check
  this in the live app before more work.

Not measured: the height of the resize zone at the top edge of the
window. A drag strip loses these points. Step 1 measures them.

## Question 1: a narrow strip to move the window

Yes. Three heights are possible:

| Strip | Saves | Move | Double-click | Notes |
| --- | --- | --- | --- | --- |
| 32pt (native band) | 20pt, about 1 row | native | native | The lowest risk. Space for a title. |
| 12-16pt (recommended) | 36-40pt, about 2 rows | native (inside the band) | native | Space for one line of 11pt text at 16pt. |
| 0pt | 52pt, 3 rows | system gesture only | none | Ctrl-Cmd-drag needs `NSWindowShouldDragOnGesture`, a user default. Not a design. |

With `kido-pane-spacing = 8`, the canvas above the cards is already
about 12pt. That gap is the strip, at no cost.

## Question 2: where the title goes

The title today is the tab strip: one tab for each top-level tmux
window, with a status mark, plus the remote `user@host` label.
These places are possible:

1. **The sidebar (docked).** The sidebar already shows each window as a
   group, and the current one is highlighted. No other title is
   necessary. The `user@host` label moves to the sidebar header row.
2. **A small title in the strip.** A centered 11pt label: the current
   window's label, its status mark, and `user@host` for a remote host.
   This needs a 16pt strip. It works with the sidebar collapsed.
3. **A hover capsule.** With the sidebar collapsed, a glass capsule at
   the top-left shows the traffic lights, the sidebar toggle and the
   title when the pointer is in the top strip. This is the same idea as
   the pane toolbar hot zone.
4. **A HUD on a window switch.** The title shows for 1s at the top
   center after Command-{/}, Command-1...9 or a palette jump.
5. **System only.** `NSWindow.title` stays set in all options. The
   Window menu, Mission Control and the Dock menu show it.

Panes get no titles (rejected for the split mockups).

## What the tab bar does today, and where it goes

| Function | New place |
| --- | --- |
| Select a window | Sidebar row, Command-{/}, Command-1...9, Cmd+P palette |
| Reorder windows | Sidebar drag (exists) |
| Close a window | Sidebar row ×, Command-W |
| New window (+) | Sidebar group +, Command-T |
| Status marks when the sidebar is collapsed | The title mark (option 2 or 3) |
| `user@host` label | Sidebar header; the title when collapsed |
| Sidebar toggle, New Session | Sidebar header row, right of the traffic lights |

## Recommendation

- Remove the `NSToolbar`.
- Use one constant strip of 16pt above the terminal, docked and
  collapsed. The terminal then never moves vertically when the sidebar
  collapses, which is a current rule (`docs/design-app.md`). A change
  of the top would resize the tmux client.
- Docked: the sidebar header row (32pt) holds the traffic lights, the
  toggle and New Session. The terminal side shows no title (option 1).
- Collapsed: the strip shows the small title (option 2). The traffic
  lights and the toggle show in a hover capsule (option 3), because at
  16pt they would cover the first terminal row.
- Full screen: no strip and no title bar. Remove the `.autoHideToolbar`
  override and the `NSToolbarFullScreenWindow` background.

## Implementation steps

1. **Spike (the go/no-go).** Do not install the toolbar.
   Pin `Sidebar.content` to `terminalHost.topAnchor`, not to the safe
   area. `WindowView` keeps the top 16pt free. Run the live app, docked, collapsed, floating, full screen,
   light and dark themes. Check:
   - No plain strip over the sidebar glass or the terminal.
   - The drag works in the strip, and a double-click zooms.
   - The size of the top resize zone.
   - The traffic lights in the sidebar glass are not clipped.
2. **Sidebar header row.** Move the toggle and New Session from the
   toolbar items to buttons in the sidebar's top row, right of the
   traffic lights. The list starts below the 32pt row. Keep
   `toggleSidebar(_:)` and `newSession` as the targets.
3. **Drag strip.** A `TitleStrip` view over the top 16pt of the terminal
   area: `mouseDownCanMoveWindow = true` inside the native band. It
   draws the theme background, or the canvas color with spacing on.
   `PaneLayout` gets the top from the strip, not from the safe area.
   The `topLine` separator goes away.
4. **Title.** The strip draws the current window's label, its status
   mark and `user@host`, only with the sidebar collapsed. It uses the
   tab model that `WindowTabs` uses now (`SessionModel.Tab`, the
   status ranking).
5. **Collapsed traffic lights.** Hide the standard buttons with the
   sidebar collapsed. Show a capsule with them and the toggle when the
   pointer enters the strip's left part. Check that AppKit does not
   show them again on a re-layout (the doc says that AppKit lays them
   out at will). If it does, keep them visible and move the title right
   of them.
6. **Delete.** `WindowTabs`, `ToolbarTabsHost`, `HeaderBackground`,
   `headerDivider`, `refreshHeader`, the toolbar delegate, the full
   screen override, and the `ToolbarTests` header and tab snapshots.
7. **Tests.** Visual snapshots for docked, collapsed (with and without
   the hover capsule), floating, full screen, a remote host, light and
   dark, with spacing 0 and 8. A unit or visual test that a point in
   the strip hit-tests to a view that moves the window, and a point in
   the first pane row does not.
8. **Docs.** Replace the toolbar and tab paragraphs in
   `docs/design-app.md` with the strip, the header row and the title.
   Then delete this plan.

## Decisions

- The strip is 16pt.
- With the sidebar collapsed, the traffic lights show in a hover capsule.
- The tabs are removed.
