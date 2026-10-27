# Split pane mockups

Open `splits.html` in a browser. It has no network dependencies.
The URL hash selects a state, for example
`splits.html#variant=dimonly&layout=mixed&theme=light&cells=true`.

The panes have no titles and no buttons. The sidebar names the panes.

## The constraint

tmux puts panes on one cell grid. Between two panes, there is one
divider cell: about 8pt wide or 17pt high at the default font.
Today, `PaneLayout` puts each pane's grid at its tmux cell position
and draws a 1px line in the divider cell.

The app places each pane's grid itself (`PaneLayout.tiled`), so it can
add points at a divider. The mockup does the same calculation:

1. Extra points for each vertical divider:
   `max(0, 2 * padX + gapX - cell.width)`. The same for horizontal
   dividers with `padY`, `gapY` and `cell.height`.
2. The client size that the app reports to tmux becomes smaller by
   the extra points on the widest path across the layout.
3. A subtree with fewer dividers than its siblings gets slack. The
   slack goes to the card padding, never to the grid.

Consequences:

- A horizontal divider is 17pt high. It holds 4.5pt + 8pt + 4.5pt
  without extra points. A vertical divider is only 8pt wide, so a
  real gap costs columns: about 2 columns for each vertical divider
  on the widest path.
- The client size depends on the layout. A split or a close can
  change the client width, and tmux then resizes every pane in the
  window. A zoomed pane keeps the client size of the full layout.
- The tmux divider cell stays where it is. The mouse resize drag
  (`WindowView` divider hit areas) maps to the gutter center.

## Variants

| Variant | Gap | Padding | Radius | Focus | Cost at 1180pt, 2 columns |
| --- | --- | --- | --- | --- | --- |
| A · One-cell gutter | 3pt | 2.5pt × 7pt | 6pt | accent ring | none |
| B · Gutter cards | 8pt | 8pt × 4.5pt | 10pt | 1.5pt accent ring, others dimmed | about 2 columns per vertical divider |
| C · Raised focus | 10pt | 10pt × 6pt | 12pt | shadow and bright edge, no accent | about 3 columns per vertical divider |
| D · Dim only | 6pt | 6pt × 4pt | 8pt | stronger dim, no line | about 1.5 columns per vertical divider |
| E · Outline, no dim | 6pt | 6pt × 4pt | 8pt | 1pt accent outline only | about 1.5 columns per vertical divider |

B is the recommended starting point. The readout under the window
shows the exact cost for the current layout and width.

All variants keep these parts of the current design:

- The pane color is the Ghostty theme background.
- Unfocused panes use the `PaneChrome.dimmed` overlay (except E).
- The floating pane keeps its 10pt radius and shadow.

The gutter "canvas" color is the theme background mixed toward black
(dark) or toward a warm gray (light). Thus, it follows each theme.

## Zoom signs

Select the "Zoomed" layout. Then the "Zoom sign" selector and a
second gallery compare the signs:

| Sign | Where | What it tells |
| --- | --- | --- |
| Stacked sheets | two sheets under the card's bottom edge | other panes are behind this one |
| Edge ticks | a 3pt accent tick in the margin, on each side with hidden panes | where the hidden panes are |
| Layout map | a 36×24pt map at the right of the title bar | the full layout and which pane is zoomed; a click restores |
| Tab glyph | the window tab: zoom glyph and "1/3" | zoom is on in that window, from every tab |
| Corner badge | an accent badge on the card's top-right corner | the most visible; it covers a few points of row 1 |

In every sign, the sidebar marks the zoomed pane with the zoom glyph
and fades the hidden panes. No sign changes the client size: a zoomed
pane keeps the client size of the full layout.
