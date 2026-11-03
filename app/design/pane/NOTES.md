# Pane chrome reference — hover toolbar and find bar

Open `mockup.html` through the design preview server (`python3 -m http.server 8765 --bind 127.0.0.1` from `app/design`, then http://127.0.0.1:8765/pane/mockup.html) or directly in a browser. Self-contained: system fonts, inline CSS/JS, no network. Design reference only; nothing searches, splits or closes.

## What is shown

The per-pane hover toolbar and the find bar, both as the user approved them, in the sidebar mockup's window chrome with the light `#fefaf1` / dark `#192028` terminal themes. Controls above the window select the find state, whether the pane is hovered (toolbar shown), the layout (two panes, a 300pt pane, a 420pt float), the theme and a hover-zone overlay. A gallery below the window renders every find state in light and dark at 380pt, plus the compact form. Exported 2× PNGs of every state live outside the repo (see the message that delivered them); the preview is the source.

Decisions (2026-10-17): find sits at the pane's top-right; while it is open the hover toolbar always goes below it; the capsule grows with the pane up to 420pt; Done is the × inside the capsule; the hovered toolbar may cover the COPY and history pills on narrow panes. The app matches this mockup exactly: both controls use the theme-background capsule below, not NSGlassEffectView.

## Implementation spec

Both controls are one capsule style. "Background" and "foreground" are the pane's Ghostty theme background and foreground colors; "secondary" is `NSColor.secondaryLabelColor`, "label" is `NSColor.labelColor`, "accent" is `NSColor.controlAccentColor`, all resolved for the pane's effective appearance.

### Capsule (shared)

| Property | Value |
| --- | --- |
| Height | 32pt |
| Corner radius | 12pt |
| Fill | background mixed 8% toward foreground, opaque, drawn over the terminal (no blur, no glass, no translucency: terminal text must not show through) |
| Edge | 0.5pt stroke, foreground at 12%, drawn outside the fill |
| Highlight | 0.5pt inner top edge, white at 12% |
| Shadow | black at 20%, y offset 6pt, blur 18pt |
| Content inset | 3pt on every side |
| Icon button | 26×26pt, SF Symbol 15pt regular, secondary tint; hover: label tint and label at 12% fill with 8pt radius; disabled: 35% opacity, no fill; focus ring: accent at 45%, 3pt |
| Separator | 0.5pt (1 device pixel) wide, 14pt tall, vertically centered (y = 9), foreground at 20% (dark) / 17% (light): `separatorColor` is acceptable |
| Text | 13pt system regular, label color; placeholder secondary |

### Hover toolbar

Frame x = paneWidth − 8 − 145, y = 8, width 145, height 32 (as today). Content unchanged: Drag pane `line.3.horizontal`, Split right `rectangle.split.2x1`, Split down `rectangle.split.1x2`, Zoom pane `arrow.up.left.and.arrow.down.right` / Unzoom pane `arrow.down.right.and.arrow.up.left`, buttons at x = 3, 29, 55, 81, then the separator at x = 111, then Close pane `xmark` at x = 116; all at y = 3. Hot zone: the frame extended 24pt left and 24pt down, clipped to the pane; fade in on entry, visible while over the zone or the toolbar. Drag pane disabled while zoomed.

While the pane's find bar is open: frame y = 48 (8 + 32 + 8), same x and width. The hot zone follows the frame. The find capsule is not part of the zone, so hovering find does not summon the toolbar.

### Find capsule

- **Frame.** x = paneWidth − 8 − width, y = 8, height 32; width = clamp(paneWidth − 16, 200, 420). Floats use the same rule inside their own bounds. Persistent while open; never hover-gated; above the toolbar in z-order.
- **Contents, left to right, all at y = 3 inside the capsule.** Magnifier slot 22pt wide: `magnifyingglass` 14pt, secondary tint, centered. Field: flexible width, height 26, borderless, no bezel, 13pt system, 2pt horizontal text inset, placeholder "Find in Terminal". Count: 11pt system with tabular digits, secondary color (red `systemRed` for "Search failed"), padding 4pt left / 6pt right, never wraps or truncates, the field absorbs the width. Separator. Previous match `chevron.up` 26×26. Next match `chevron.down` 26×26. Separator. Done `xmark` 26×26. Separators have 4.75pt on each side; the trailing button ends 3pt from the capsule edge.
- **Count strings.** "Searching…" with a 9pt indeterminate spinner (1.5pt stroke, secondary) 5pt before the text; "N matches"; "i of N"; "No matches"; "Search failed"; copy mode "N matches (loaded)" / "No matches (loaded)"; empty query shows nothing.
- **Compact (capsule width < 300pt).** Same frame rules; count strings become "…", "N", "i/N", "0", "Failed", "N (loaded)", "0 (loaded)". Nothing else changes.
- **Previous / Next** are disabled until a search has matches.
- **Focus.** Field is first responder: a 3pt ring in accent at 40% follows the capsule's rounded rect (outside the edge), query text in label color. Focus returned to the pane (Return in copy mode, Cmd-G from the pane): no ring, query text in secondary color, bar stays open with its count.
- **Pills.** The COPY pill and the history "Load more" pill keep their positions (x = 8 / centered, y = 8) while find is open unless the capsule would overlap them horizontally, i.e. paneWidth − 16 − capsuleWidth < 72; then both move to y = 48. The hovered toolbar may cover them on narrow panes (accepted).
- **Accessibility.** Capsule: role search, label "Find in Terminal". Field: "Find in Terminal". Count: a polite live region. Buttons: "Previous match" (tooltip "Previous match (Shift-Return)"), "Next match" ("Next match (Return)"), "Done" ("Done (Escape)"). Key-view loop: field, Previous, Next, Done, then the pane.

Behaviour preserved exactly: Cmd-F opens or focuses per pane; Return / Shift-Return and Cmd-G / Shift-Cmd-G navigate; Escape or Done closes and clears highlights; in copy mode Cmd-F, `/` and `?` open or focus the bar without leaving copy mode, Return returns focus to the pane with the bar open, the first Escape closes the bar and a second exits copy mode; whole-history search shows "Searching…" and an unloaded match triggers history loading.

## Proposal: copy-mode and history pills — awaiting user review

Today (`App/PaneView.swift`) both are NSBoxes: `windowBackgroundColor` fill, 5pt radius, 8×2pt content margins, no border or shadow; COPY is 11pt semibold label text ("COPY…" while entering), the history pill is 11pt secondary "Older history not loaded" beside a small rounded "Load more" NSButton. COPY sits at x = 8, the history pill centered, both at y = 8, moving to y = 44 while find is open.

Proposed: the same capsule style as the toolbar and find bar, at label size.

| Property | Value |
| --- | --- |
| Height | 22pt |
| Corner radius | 8pt (the family's radius at this height; not a full round) |
| Fill, edge, highlight, shadow | as the shared capsule table |
| COPY | 11pt system semibold, label color, tracking +4%, 9pt horizontal padding; "COPY…" while entering in secondary color |
| History pill | 11pt system regular secondary "Older history not loaded", 9pt left padding; 0.5pt separator (14pt tall, 8pt before and 4pt after); "Load more" as an 11pt medium accent-colored text button, 18pt tall, 7pt horizontal padding, 6pt radius, hover fill label at 12%; 2pt right padding |
| Position | COPY at x = 8, y = 8; history pill centered, y = 8. Both move to y = 48 only when an open find capsule would overlap them horizontally (paneWidth − 16 − capsuleWidth < 72), matching the find spec; on wide panes they stay at y = 8 beside the capsule |
| With the toolbar | unchanged; the hovered toolbar may cover them on narrow panes (accepted) |

The preview's "Copy mode" states show the pill alone, entering, and with find open; the hovered checkbox adds the toolbar; the narrow layout shows the pills under the capsule. The gallery renders both pills in light and dark.

Open questions:

1. 8pt radius (family proportion) or a full 11pt round pill?
2. Keep "Load more" as text inside the pill (as mocked) or as a small bezel button as today?
3. On narrow panes the centered history pill and COPY overlap each other at y = 48 (they already can today at y = 44); move the history pill right of COPY when both show, or accept?
4. Should the pills dim with the unfocused-pane overlay, or stay full strength as chrome?

## Measurements from the code

Toolbar frame and hot zone from `App/PaneChrome.swift:33` (x = max(0, paneWidth − 153), y = 8, width min(145, paneWidth), height 32; zone = frame + 24pt left and down, intersected with the pane). Float frame, radius and shadow in the preview are illustrative; match highlight colors (yellow, orange for the current match) are illustrative and the app's highlights are unchanged.
