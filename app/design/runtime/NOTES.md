# Runtime indicator (decided, mockups only)

**Decided (user), 2026-11-04.** The four recommendations below are
accepted: a `color` field with the FNV-1a hash as the fallback; the
terminal client shows the suffix only; the stripe text is `NAME`,
`NAME · tools`, `NAME · starting` and `NAME · failed: <message>`; the
palette root and step as drawn. Also decided: the 3pt band is
reserved only for a runtime pane; a nested row omits its suffix when
it equals its parent's; `· tools` stays on the routed pi's pill; the
failed pill shows the message inline.

`mockup.html` is a self-contained reference for how Kido.app and the
terminal client show that a pane executes in a runtime (ko runtimes,
plan unit U4). Open it through the design preview server
(`python3 -m http.server 8765 --bind 127.0.0.1` from `app/design`, then
http://127.0.0.1:8765/runtime/mockup.html); `?state=<id>&theme=Light|Dark`
selects a state. Nothing is implemented. The runtime model is
docs/design-runtimes.md ("The link": Down, Starting, Up, Failed with
a message; "Agents in a runtime": a routed pi is a host pane in every
row field and sets `ko.runtime`/`pi.runtime`; a runtime pane carries
`row.runtime`). The plan's wording for clients is section 8 of
/tmp/ko-runtimes-plan.md.

## What a pane shows

Three marks, all derived from one fact: the pane's runtime, which is
`row.runtime`, else a trusted `pi.runtime` (a routed pi). A host pane
has none of them.

1. **The stripe.** A band across the top of the pane chrome in the
   runtime's colour, full width, 3pt tall.
2. **The label pill.** The runtime's name in a small pill at the
   toolbar's corner, top-right.
3. **The row suffix.** The name, dimmed, after the sidebar row's
   title, with a 6pt swatch.

The link state of the runtime (`GET /runtimes`, the `runtime` event;
the pane row carries none, plan decision 6) changes the pill text and
the suffix text, never the colour.

## Geometry

Points, from the pane chrome's top-left.

| Element | Frame | Notes |
| --- | --- | --- |
| Stripe | x 0, y 0, width = pane width, height 3 | Above the 1pt focus edge of the 0.31 treatment: the band replaces the edge's top side. Full width, the dividers are not covered (they are outside the chrome). |
| Label pill | x = paneWidth − 8 − width, y 8, height 22, radius 8 | The COPY pill's family (pane/NOTES.md, "Proposal: copy-mode and history pills"): capsule fill (background mixed 8% toward foreground), 0.5pt edge foreground 12%, inner top highlight, the same shadow. Padding 8pt left, 9pt right. Contents: a 6pt swatch in the runtime colour, 6pt gap, the name in 11pt system medium `labelColor`, then the state in 11pt regular `secondaryLabelColor` after " · ". Max width 300pt; the state text truncates with an ellipsis, the name never. |
| Row suffix | after the title: 6pt gap, 6pt swatch, 4pt gap, name | 13pt system regular `secondaryLabelColor` on the title's 18pt line. The title truncates first; the suffix keeps 96pt and truncates only past it. The clock stays in its trailing column. |
| Row swatch | 6pt circle, the runtime colour | The same size as the status dot, so the two read as one vocabulary: status at the left, place at the right of the title. |

**Why 3pt and why a reserved band.** The app sets Ghostty's
`window-padding-x/y = 0`, so the cells start at the content frame.
`PaneLayout` (Packages/TmuxControl) places the grid from the bottom:
a root pane's grid begins between 0 and one cell below the top line
(the slack of `floor((bottom − topLine.maxY) / cell.height)`), and the
12pt `minimumMargin.height` sits at the bottom. A pane under a
horizontal split keeps `before.height` (half a cell less a pixel,
about 7pt for a 16pt cell) between its chrome top and its grid. So
the stripe cannot rely on free space above a root pane's first row.
**Decided (user):** `PaneLayout` reserves the 3pt band only for a
pane in a runtime, as part of that pane's `RenderInsets.top`. A host
pane keeps today's geometry. Consequence: a runtime pane's grid
starts 3pt lower than a host pane's beside it in the same window,
so the first rows of the two panes do not align (state `window`:
the left runtime pane's first line sits 3pt below the right host
pane's). A root runtime pane loses one row when its slack was under
3pt; host-only windows lose nothing. 2pt is the rejected
alternative (state `stripe-2pt`): it reads at 2× but disappears on
a light theme with a pastel hue; 3pt is the smallest band that reads
on both themes without a tint change. The pill, like the COPY pill
and the toolbar, may cover cells; that is the accepted rule for
chrome at y = 8.

**Unfocused panes.** The 0.31 treatment shifts the inactive pane's
background 5% toward the sidebar tone and gives only the active pane
the 1pt accent edge. On an inactive pane the stripe draws at 55%
opacity and the pill at 70%, so the focused pane's stripe is the
loudest, as its background is the purest. The shift alone does not
dim a saturated 3pt band enough; the opacity does.

**Split panes, mixed host and runtime.** Each pane chrome draws its
own stripe inside its own bounds. In one window with host and
runtime panes (state `window`), the runtime panes carry a band and
the host panes do not; two adjacent runtime panes of the same
runtime show two bands of one colour, separated by the divider. The
band never crosses a divider.

**Zoomed.** The zoomed pane is a root pane and keeps its stripe
across the full area (state `zoomed`). The hidden panes draw nothing.

**Float.** The float's chrome is the rounded card; the stripe is its
top 3pt, but it sits at the top of the grid's padding: 10pt
(`PaneLayout.floatTop`) below the card's top edge, directly above the
first row; the card's top band, with the move handle, stays above it
(state `float`). Tiled panes keep the stripe at the chrome's top. The
pill sits at the float's own top-right. The pane under the float is
unchanged.

**Hover toolbar and find.** The pill shares the toolbar's corner and
hides while the hover toolbar or the find capsule is shown (states
`window-hover`, `label-find`). The stripe stays, so the runtime never
goes unmarked. The pill is not part of the toolbar's hot zone.

**Copy mode.** The COPY pill is at the left (x 8), the runtime pill
at the right; they do not meet above 200pt of pane width. On a
narrower pane the runtime pill hides first.

## Colour

**Hash rule.** `hue = FNV-1a-32(name as UTF-8) mod 360`. The colour
is `NSColor(hue: hue / 360, saturation: 0.73, brightness: 0.66)` on a
light terminal theme (the mockup's `hsl(hue 58% 42%)`) and
`NSColor(hue: hue / 360, saturation: 0.47, brightness: 0.84)` on a
dark one (`hsl(hue 55% 64%)`), where light/dark is the app's
existing luminance decision for the terminal background. Both pass
3:1 against kido-light `#FFF9EC` and kido-dark `#171717` for a 3pt
band and a 6pt dot (non-text contrast). The same hue feeds the
stripe, the pill swatch, the row swatch and the palette's leading
dot.

The full circle is used on purpose: a restricted range (for example
away from the status reds and oranges) halves the spread for four
runtimes and does not remove collisions. The four names of the
mockup hash to 292° (buildbox), 197° (py311), 307° (gpu-1) and 313°
(e2e): gpu-1 and e2e are six degrees apart (state `colour-hash`).
With four names the chance that two hues fall within 20° is about one
in five.

**Configured colour.** `"color": "#d08a2a"` on a runtime in
`runtimes.json`, an optional sRGB hex, parsed once with the file and
carried in the runtime entry of the `Welcome` and `GET /runtimes`, so
every client draws the same colour. Absent means the hash (state
`colour-config`). The value is used as given on both themes; a user
who sets it chooses a colour that works on their themes.

## Strings

Exact strings, in the pill and in the row suffix.

| Case | Pill | Row suffix |
| --- | --- | --- |
| Runtime pane, link up | `buildbox` | `buildbox` |
| Routed pi (host pane, tools in the runtime) | `buildbox · tools` | `buildbox` |
| Starting | `e2e · starting` + a 9pt indeterminate spinner (the find capsule's) | `e2e · starting` |
| Failed (decided) | `gpu-1 · failed: ssh: connect to host gpu-1 port 22: Connection refused`, the state text truncated with an ellipsis at the pill's 300pt; the full message is the tooltip | `gpu-1 · failed` with `failed` in `systemRed`; message as tooltip |

A tooltip-only failed pill (`gpu-1 · failed`) was proposed and
rejected by the user. In the row the name and " · starting" are
`secondaryLabelColor`; only " · failed" takes `systemRed`. The
starting stripe is dashed (8pt on, 6pt at 35%) and does not animate;
the failed stripe keeps the colour at full strength, because the
pane's own screen shows the red message (`runtime gpu-1: …`, from
`ko runtime-exec`) and the row's dot is already red for a dead pane.

A routed pi's row suffix is the same as a runtime pane's (plan
section 8: one style, "where does this agent work"); only the pill
adds " · tools" (decided: it stays), because the pill is on the pane
itself, where the difference matters: the shell in that pane is the
host's.

## Sidebar rows (state `rows`)

Rows follow sidebar/NOTES.md's redesign draft: 32pt, 6pt dot centred
20pt in, title at 36pt, 15pt nesting, 1pt guides. **Decided (user):**
a nested row omits its suffix when its runtime equals its parent
row's; it shows it when it differs (the `pytest -x` child in py311
under the buildbox pi) and always at the top level. The parent is
the nearest ancestor pane row, so a grandchild in the parent's
runtime shows nothing either. The rows state and the sidebar
fixture show `make e2e`, `@pi-review` and `@pi-review-notes` under
`@kido-app` without a suffix.

Three suffix styles are shown side by side:

- **Swatch + dimmed name (recommended).** The colour carries the tie
  to the stripe in a 6pt dot; the text stays `secondaryLabelColor`,
  readable on every shade.
- **A · dimmed name only.** One style, no colour; the row and the
  stripe are tied only by the name.
- **B · the name tinted in the runtime colour.** Some hues fail text
  contrast on the shade, and a tinted word competes with the status
  dot's meaning.

## Command palette (states `palette-root`, `palette-step*`)

Root list, after the sessions and panes and before the Connect hosts
and the commands: one row for each runtime of the `Welcome`, title
`Runtime: NAME`, a 6pt swatch in the leading icon slot, and the
detail at the right in the shortcut column: `kind · state` (`ssh · up`,
`container · up`, `command · starting`). A failed runtime shows
`ssh · failed · <message>` in `systemRed`, the message truncated at
300pt. When the focused pane is in a runtime, a `Host` row (icon
`desktopcomputer`, detail `this Mac`) comes first, selected. Fuzzy
filtering matches the title and the detail as for other rows.

Enter opens the step (`PaletteMode.runtime`), in the Theme save
step's shape: the chip is the swatch and the name, the field reads
`Open as…`, three rows `New Window · in session main`, `Split Right ·
beside the focused pane`, `Split Down · below the focused pane`; Up
and Down move, Return performs and closes, Escape or Backspace on
the empty field go back to the root. The foot names the kind and
state and says where the pane runs (`ssh · up · the new pane runs in
buildbox`). For a failed runtime a red status line above the foot
repeats the message and says `The new pane starts it again.` The
`Host` step is the same with no swatch.

## Terminal client (states `tui-*`)

`ko_tui` keeps one sidebar line for each pane (`ko_tui/src/sidebar.rs`:
number, depth, the mark glyph, the title, the dead suffix). The
runtime goes after the title as ` NAME` in the faint attribute (SGR
2), from `row.runtime` else a trusted `pi.runtime`, and the line
truncates at the sidebar's 24 columns as today, so a long title loses
the suffix. States are ` NAME …` for starting and ` NAME ✗` for
failed, both faint (the failed row's mark is already red). No colour:
the client has 16 colours and no hash would survive them.

Recommended: the suffix only. The stripe alternative (state
`tui-stripe`) spends one terminal row of the pane on a reverse-video
line in an indexed colour with the name, which the pane's program
cannot see, so the 24-row minimum of the layout shrinks and every
pane in a runtime is one row shorter than its host neighbour. The
sidebar line answers the question "where does this run" already, and
the minimal client stays minimal.

## Recommendations (all accepted by the user)

- **(a) Colour.** A per-runtime `color` with the hash as the
  fallback. The hash alone cannot be corrected when two names
  collide, which the four mockup names already do, and the field is
  one optional value carried where the name already travels.
- **(b) ko_tui.** The sidebar suffix only. A stripe costs a pane row.
- **(c) Stripe text.** Name only on a runtime pane; `NAME · tools` on
  a routed pi; `NAME · starting` with the spinner and a dashed band
  while starting; `NAME · failed: <message>` inline when failed (the
  user chose the inline message over a tooltip-only pill). The
  message is also on the pane's screen and in the palette row.
- **(d) Palette.** As mocked: `Host` first when the focused pane is
  in a runtime, `Runtime: NAME` rows with `kind · state` at the
  right, the message on a failed row, and a three-row step in the
  Theme save step's shape.
- **Label placement.** The pill at the top-right, hidden under the
  toolbar and the find capsule. The top-left (state `label-left`)
  collides with the COPY pill and the history pill, which would both
  have to move. A tag hanging from the stripe (state `label-tag`) ties
  the two visually but puts a saturated block over the first text
  row at every width and has no room for the state.
- **Row colour.** The 6pt swatch, not a tinted name.

## Decided (user)

1. The 3pt band is reserved only for a pane in a runtime; a runtime
   pane's grid starts 3pt lower than a host pane's beside it.
2. A nested row omits its suffix when it equals its parent's.
3. " · tools" stays on the routed pi's pill.
4. The failed pill shows the message inline.

5. The colour is for display only: the runtime config's `color` reaches
   clients through `GET /runtimes`, the `Welcome` and the runtime
   events, not `ko panes` or `list_agents`.
