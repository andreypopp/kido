# Sidebar mockup

Self-contained, interactive HTML reference for the shipped sidebar. Open it with:

```sh
open design/sidebar/mockup.html
```

The implementation is the source of truth: `App/SidebarView.swift`, `App/SidebarRow.swift`, `App/IconButton.swift`, and `Packages/SidebarFeed/Sources/SidebarFeed/Rows.swift`. This mockup approximates native glass, SF Symbols, and AppKit semantic colors using system fonts, inline CSS/JS, and no network resources.

The preview supports pane focus, separate keyboard selection (↑/↓ or j/k, Enter to focus), ←/→ session folding, session-name fold buttons, / filtering with zero matches, sidebar collapse, and light/dark themes. Mouse presses clear keyboard selection. Toolbar/plus icons brighten on hover; rows and session headers have no hover or press feedback, rings, or tooltips. Creation buttons and terminal content are visual placeholders.

Fixtures include a captured working-session tree adapted to the current nullable `run` field (`agent`, `bash`, `stream`) plus illustrative deep nesting, activity, waiting/stalled/failed, ssh, long titles, and ticking clocks. Clock display requires both `run` and `started`. The normal agent with a timestamp but no run intentionally has no clock. Captured timestamps are historical, not a live feed connection.

Geometry follows the code: 292pt sidebar; 31pt headers; 28/44pt pane rows and 25/41pt nested rows; 17pt indents; 9pt divider rows containing a 1pt separatorColor approximation. Fonts are 12pt titles, 11pt nested titles/semibold headers, 10pt tails and tabular clocks. Dots are 6pt; idle has none. Session corners are 10pt; nested windows round left corners at 6pt, except bottom-left at the session edge. Pane highlights are rectangular and clipped by their window/session containers. Active-window fill is labelColor at 7.5%, focus/keyboard selection at 10%, cards at 2.5% with a 7.5% stroke. Exact native colors/materials remain AppKit-owned.

## Remaining data gaps

- `started` is nullable. No clock is invented when it or `run` is absent. Persisting runtime after completion would require an end timestamp or duration.
- `tail` is display text, not an explicit `set_status` field. Distinguishing tool-set activity from other captions requires a feed change.
- No pi/Claude provider field or separate monitor item kind: monitors use `run: stream`; provider-specific branding needs additional data.

## Open questions

- Independent subtree folding is not implemented; only sessions fold.
- Whether the focused-pane leading mark should remain is a future design decision; the shipped implementation includes it.
