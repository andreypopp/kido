# Focused pane treatment (proposal, not approved)

`mockup.html` is a self-contained reference for how Kido.app can show which pane has keyboard focus in a multi-pane window. Open it in a browser; no network access. Code is the source of truth: today `PaneChrome.draw` fills an inactive pane with the terminal background at 45% alpha.

## Treatments

- **Current.** Inactive overlay, terminal background at 45%. Cost: text in inactive panes drops to about half contrast, and those panes are where output is read while typing elsewhere. The overlay also covers selection and find highlights.
- **Background shift.** Inactive panes take the terminal background mixed toward black on a light theme and toward white on a dark one. Glyphs, cursor, selection and highlights are untouched. The focused pane is then the only surface with the pure terminal background. The Shift strength control previews 5%, 8% and 12%. The app's shift is set by `kido-unfocused-background-shift` (default 3%, 0 turns it off).
- **Active dividers.** The separators that touch the focused pane are drawn in the accent colour (accent mixed 70% into `separatorColor`), 1pt as before. Separators between two inactive panes keep `separatorColor`.
- **Focus edge.** A 1pt inset stroke on the focused pane in the accent at 50% opacity. It sits over the pane padding, not over cells.
- **Shift + focus edge.** The shift plus the 1pt accent stroke on the focused pane. Louder than the dividers in a light theme because the stroke closes all four sides.
- **Shift + active dividers.** The recommendation: the shift carries the focus reading at a glance, the dividers make the focused rectangle explicit without covering cells.

## Sidebar focus

When the sidebar is first responder (Focus control, or click the sidebar), it gets the same 1pt inset accent stroke at 50% around its whole column, including the title row. No pane looks focused: every pane takes the inactive treatment (the shift on all panes, or the overlay on all panes in the current treatment), there is no focus edge and no accent divider, and the active pane's cursor is hollow. Only one surface carries focus at a time. The active pane is still remembered, so clicking back into the terminal area or pressing Escape returns to it. The keyboard-selection fill on a sidebar row is unchanged.

## Window chrome

The real window has no toolbar, no top line and no divider lines: panes are cards on a canvas and the ring is 1.5pt (docs/design-app.md, "Focus treatment").

Historical: the sections below describe an earlier mockup with divider lines and a docked sidebar shadow. The app has neither now: the docked sidebar is the canvas colour (docs/design-app.md, "Focus treatment").

## Sidebar separation (chosen: soft shadow)

With the shift, the sidebar and an inactive pane next to it are the same tone, so only the divider separates them. The Sidebar separation control previews three options (see renders `*-sepi-*` in the review directory, with the left pane inactive):

- **Soft shadow.** The sidebar casts a shadow onto the terminal area: offset 4pt right, blur 14pt, spread −2pt, black 40% in dark and black 18% in light; the divider stays. In light the shadow alone is too faint, so there the sidebar divider is the background mixed 28% toward the foreground (#cac6bc over #fff9ec); dark keeps 18%. The sidebar reads as a raised sheet, as the macOS 26 inset (Liquid Glass) sidebar does. User's choice.
- **Stronger divider.** The split divider only, terminal background mixed 35% toward foreground instead of 18%. Cheapest, but a 1px line cannot separate two surfaces of the same tone by much.
- **Larger tone step.** Sidebar at 12% shift, inactive panes at 5%. Native-looking (Finder and Xcode sidebars differ from content by tone), but on a dark theme 12% is still close to 5%. Rejected: the sidebar is the canvas now.

HIG: not against it. A plain split-view sidebar has only its divider, while the macOS 26 inset sidebar floats with its own soft edge and shadow, so a subtle cast shadow puts a docked sidebar in the same family. Keep it soft (blur under about 16pt, low opacity) and never on the content's own edges.

## Floating sidebar

Sidebar mode control. The floating card (shown over the terminal when the docked sidebar is collapsed) keeps its 18pt radius and 0.5pt 12% `labelColor` border and gets:

- The same soft shadow, but ambient rather than cast to the right, because a one-sided shadow looks wrong on a rounded card: offset x 0, y 4pt, blur 14pt, spread −2pt, black 40% dark / 18% light, following the 18pt corner. This replaces whatever shadow the card draws today.
- When it is first responder, the same 1pt inset accent stroke at 50%, inset 1pt inside the border and following the corner (radius 17pt). The shadow stays. The panes behave as under docked sidebar focus: all shifted, no pane edge, hollow cursor.

The terminal area under the card is unchanged; the shift and the focused pane's edge draw as if the card were not there, and the card covers them.

## Rules shared by every treatment

- Nothing is drawn in a single-pane window (Single pane control).
- Floats are not covered by this proposal.
- Colours are theme-relative: terminal background and `separatorColor` from the theme, accent from `controlAccentColor` or the theme's blue (palette 4).
- Clicking a pane in the mockup moves focus; the Focused control does the same.

## Open questions

- Shift strength: 5% keeps inactive panes identical to the sidebar; 8% or 12% reads faster at the cost of a visible step between the sidebar and an inactive pane.
- Whether the focus edge is wanted at all, or only on top of the shift when a window has four or more panes.
