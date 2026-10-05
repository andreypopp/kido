# Sidebar reference

Self-contained HTML reference for **shipped Kido.app 0.1.5 pane focus and window tabs**. Remote support is being finished; the new remote-only host label below is a design proposal for user review.

```sh
open design/sidebar/mockup.html
```

The code is authoritative: `App/SidebarRow.swift`, `App/WindowTabs.swift`, `App/SessionModel.swift`, `App/Sidebar.swift`, and `Packages/SidebarFeed/Sources/SidebarFeed/{Rows,Windows}.swift`. CSS approximates native colors/materials and system-font metrics; it is not AppKit.

## Shipped sidebar and focus

Sessions fold on their names, with no triangles. Window dividers replace window rows. Nested subagents/runs indent without guide lines. Status/time stay on the title line, activity below. Idle has no dot; running green, attention orange, error red. Clocks require both `run` and `started` and use native elapsed formatting.

Geometry: 292pt sidebar; 31pt headers; 28/44pt pane rows and 25/41pt nested rows; 17pt indents; 9pt divider rows containing a 1pt separator. Fonts: 12pt titles, 11pt nested titles/semibold headers, 10pt tails/tabular clocks. Dots are 6pt. Session corners are 10pt; nested windows round only left corners at 6pt, except bottom-left at the session edge.

**The focused pane has no extra fill.** Its only mark is a 3pt left-edge strip with 4pt top/bottom insets, 85% white in dark / 75% black in light. The active window retains its continuous 7.5% labelColor fill, including descendants. For a one-pane window that fill covers its single row; that is a window highlight, not an additional pane highlight. Independent keyboard-navigation selection still uses 10% fill. Cards use 2.5% fill and a 7.5% stroke.

Arrow keys/j/k move keyboard selection; Enter focuses a pane; mouse clears keyboard fill. Left/right and session names fold/unfold sessions. / opens the session-name filter, including zero-match state. Toolbar/plus icons brighten on hover, but pane/header rows have no hover/press feedback or tooltips.

## Approved spacing changes

Every window divider, top-level and nested, is a 3pt row: 1pt gap, 1pt line, 1pt gap. The line uses the same color as the outer sidebar border (labelColor at 12% alpha; `--guide` in the preview), not tertiaryLabelColor. Nested lines start at the window's indent (depth × 21pt) and extend to the right edge. Resolve the native color at draw time and pixel-snap the line. This supersedes the previous top-level-only divider/no-nested-divider variants. No sidebar row may be 0pt: NSTableView aborts on one, which crashed `make demo`. Pane heights and text padding are unchanged. Nesting uses indentation only: 21pt per level (up from 17pt), with no guides. Both elbowed and vertical-only guides were tried and rejected as too busy. The user approved these changes and requested implementation handoff. They are reflected in the mockup, not yet claimed as shipped-code changes.

## Approved divider placement

Render a divider before every window's first pane, including the first window in a session and the first nested child window. Do not add dividers between panes of the same window. Color and 3pt geometry remain unchanged. The user approved this placement and requested handoff to kido-app.

## Approved completion, request, and stalled states

Completed agent turns (`done`) and successful shell commands (`done`) show a green checkmark in the existing trailing status slot, not an orange dot. Completed retained runs (`gone/completed`) use the same bright green checkmark. The user chose one completion appearance for simplicity, with no dim/fresh distinction. Idle remains empty; running/compacting remain green dots; failures stay red.

Orange means an agent actually awaits input (`waiting`, agent or agent-run). The feed's `attention` flag also includes completed turns, so it must not directly select an orange dot. Keep the feed's existing navigation/acknowledgement semantics separate from the visual state. Tab aggregation uses actual errors/input requests, not completion; completed turns don't produce orange tab dots. The stress fixture includes agent `done` with `attention: true` as a regression example and successful shell/run completion.

Stalled uses a bold red exclamation mark in the trailing status slot, distinct from failure's red dot and input requests' orange dot, matching kido's TUI. It produces neither an orange request dot nor a failure dot on tabs under the existing error/request-only aggregation. The user approved this stalled treatment and then simplified all successful completion to the same green checkmark. A checkmark does not invent a completion duration; completed run fixtures have no ticking `started` timestamp. Native implementation can use SF Symbols `checkmark` and `exclamationmark` without circles; preview uses simple CSS strokes/text.

## Shipped title-bar tabs

The shipped tabs are custom AppKit `WindowTabs` drawing, not native macOS NSWindow tabbing. The preview follows that code: a 44pt titlebar strip, equal tab widths clamped to 85–220pt, a tab surface inset 2pt left/1pt right and 8pt vertically, 7pt corner radius, 11pt centered/truncating labels. Active surfaces have 7.5% fill/stroke. There is no hover background or keyboard focus ring. Status dots are 6pt, 12pt from the surface's right edge. Overflow scrolls horizontally (including vertical-wheel input). Tabs remain visible with the sidebar collapsed, after the traffic lights and Show Sidebar button.

- Window names, existence, ordering and each window's last active pane come from a separate simulated tmux window listing, not sidebar pane titles. Fixture names intentionally differ from pane titles to make that distinction visible.
- The last **unfiltered** feed supplies hierarchy/status projection. Filtering the sidebar changes neither tab membership nor attention/error dots. The preview keeps its full snapshot and filters only sidebar rendering.
- Descendant windows are grouped beneath the nearest surviving ancestor; focusing a descendant selects that ancestor's tab. If a parent window closes, surviving child windows get their own tabs. **Parent window closed** demonstrates a retained feed snapshot with the parent absent from the tmux listing.
- Error wins over attention when aggregating all descendant pane statuses; running/idle never produce a tab dot. Accessible tab labels include the aggregated status.
- Tab clicks select the window and restore its last active pane, as tmux does, rather than choosing its first pane. Sidebar pane clicks update that window's remembered active pane in the preview. Cmd-1…9 follows the projected tab list (out-of-range numbers clamp to the last tab, matching the code).

The preview fixtures include captured working-session structure, illustrative activity/states, nested multi-pane windows, long titles, ssh/shell panes, and historical clocks. Captured timestamps are not a live feed connection. Session/window creation and terminal content are placeholders.

## Remote host label — draft for review

A fixed, noninteractive host label sits at the start of the existing 44pt title-bar strip, before the scrolling tabs. Local windows allocate no label space. Remote windows show the resolved `user@host`; only the original SSH alias is in the tooltip (e.g. `buildbox`). No menu, hover treatment, press feedback, icon, or connection-status dot.

Draft geometry/style: 11pt medium system font in secondaryLabelColor (active tab titles remain 11pt regular labelColor). Text has a 16pt line box centered vertically at y=14; 2pt leading inset; up to 166pt text width, further constrained by a label container at most 35% of the full strip. Long text truncates at the tail. After the text, 12pt spacing, a 1pt separatorColor rule 16pt tall, and 10pt gap before the tabs (the first tab keeps its own 2pt inset). Label does not scroll; remaining width goes to tabs, preserving their 85–220pt widths and 8pt/28pt surface geometry.

Connected uses the normal secondary label color. Reconnecting/offline dims the whole label to 45% opacity; no spinner or extra warning glyph. A window banner explains the connection state. The host/alias stays visible offline, never a stale session title. This is implementable as a noneditable NSTextField label plus a separator; native window dragging should continue through the label, without treating it as a tab hit target.

Preview controls select Local/dev@buildbox/long host, Connected/Reconnecting/Offline, and Docked/Collapsed/Floating sidebar. In floating mode, the strip retains its previous horizontal origin while the sidebar overlays the terminal. The same fixed label remains beside the tabs in all modes.

## Remote entry point and window titles

The agreed Spotlight/Shortcuts action is **Connect to Remote Host in Kido**, taking a required Host string (`user@hostname` or SSH alias). Each request opens a new native window, including repeated requests for the same host. Remote connections use that host's kido-app server. There are no in-app connection controls or saved-host history. The new host label is informational, not a connection control.

Session-aware window titles are **Session** for Local (e.g. `main`) and **user@host / Session** for remote windows. They track that window's current session; offline, omit a stale session name. The preview does not show a separate title-bar window title: its title bar contains the shipped window tabs. The terminal heading remains illustrative pane content, not a window title.

## Data gaps and open questions

- `started` is nullable; a retained completion runtime needs an end timestamp or duration.
- `tail` is generic display text, not an explicit `set_status` field.
- No pi/Claude provider field or separate monitor kind; monitors use `run: stream`.
- Independent subtree folding is not implemented; only sessions fold.

Window-name availability, last-active-pane restoration, and orphan-window tab projection are implemented in 0.1.5, not outstanding feed gaps.
