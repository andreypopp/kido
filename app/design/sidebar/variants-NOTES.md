# Sidebar hierarchy and grouping — variants

`variants.html` shows eight treatments of two questions: how rows show
hierarchy (a pane's child windows) and how the panes of one window are
grouped. It is self-contained and reuses the current mockup's geometry:
32pt rows, 48pt rows with a caption, 13pt titles on an 18pt line, 11pt
captions, a 6pt status indicator centred 20pt from the row edge, a 15pt
nesting step, the run clock at the right, semibold live-agent titles.
Light is kido-light `#FFF9EC`, dark is kido-dark `#171717`; the sidebar
is the terminal background mixed 10% toward black. `?theme=Light` or
`?theme=Dark` renders one theme. Every column uses the same fixture:
session `main` with a single-pane window, a 3-pane window (`kido-app`
focused; `sidebar-tests` owns two subagent windows, `review-notes` and
`perf-notes`; `review-notes` owns a nested 2-pane run window `checks`
with `lint` and a shell), and a top-level run window `main-watch`.
Each variant is also rendered at 200pt, and D once more with
`sidebar-tests` collapsed.

Renders: `/tmp/kido-sidebar-variants/all-{light,dark}.png` and
`{A,B,C,D,D-collapsed,E,F,G,H}-{292,200}-{light,dark}.png`.

"Label" below means the theme's label colour: black on light, white on
dark. Percentages are its alpha.

## A · Cards

Hierarchy: indent only, 15pt per level, no guides.
Grouping: every multi-pane window sits on a rounded card.

- Card: label 5% (`#0000000D` light, `#FFFFFF0F` dark), 11pt radius,
  4pt padding on all sides, margin −4pt horizontally so it is 4pt wider
  than the rows on each side and the row content does not move. The
  card holds the window's panes and all their descendants.
- Focused row: the usual label 10% fill, 7pt radius, concentric inside
  the card (4pt margin).
- Top-level windows have a 4pt gap. A nested multi-pane window gets the
  same card, so cards stack (10% inside a card).

Better than the current design: the strongest "these panes are one
window" signal, with no line work at all; the focused row still reads
clearly inside the card. Worse: hierarchy at 3+ levels rests on indent
alone, which is the weakest hierarchy signal of the four; stacked cards
get darker with every nested multi-pane window. At 200pt the card costs
nothing in width, but the indent alone eats 45pt by level 3. With many
small windows the 4pt gaps plus cards make the list visibly longer and
busier than flat rows.

## B · Outline

Hierarchy: classic tree lines with elbows.
Grouping: a bracket on the left of a multi-pane window.

- Stem: 1pt in the tree colour (`#BFBAB1` light, `#4F555C` dark), at
  the parent indicator's centre (20pt from the parent row's edge), from
  3pt below the indicator to the last child's arm.
- Arm: a 1pt horizontal line at the child's title line centre (row top
  + 16), from the stem to 3pt before the child's indicator (9pt long).
  A nested multi-pane child gets its arm to a nested bracket at its
  block's left + 9pt (4pt long); that bracket has no ticks.
- Top-level bracket: x = 5 from the window item's edge, from the first
  pane row's top + 10 to the item bottom − 10, with 4pt ticks to the
  right at both ends. It crosses the focused row's fill as the current
  guide does.
- No fills besides the focused row; no gaps between windows.

Better than the current design: elbows make each child's parent
unambiguous even at depth 3 or more, where parallel vertical guides
blur together. Worse: the busiest line work; the bracket ticks and the
nested arm-to-bracket joint are 4pt details that disappear at a glance
and look like noise at 1× scale. At 200pt it is as compact as the
current design. With many small windows it is as tight as today, but
every multi-pane window shows a bracket.

## C · Window headers

Hierarchy: indent plus captions.
Grouping: a caption row names the window.

- Header: 24pt row, 11pt semibold muted text (same as a session label)
  with the window name, then the pane count in 10pt regular, at x = 12
  from the item's edge; 5pt top padding so the 18pt line sits low.
- Panes of a multi-pane window indent 15pt under the header (indicator
  at 35). Single-pane windows have no header and stay at 20, so a
  single-pane window is its own header.
- Child windows are sub-rows at the next 15pt step; a nested multi-pane
  window gets its own header at that depth.
- No guides, no gaps, no fills besides the focused row.

Better than the current design: the window gets a name, which the
current sidebar never shows (the tab strip does), and the grouping is
unmistakable. Worse: the extra row per multi-pane window, and the
header looks like a session label unless the pane count is kept; panes
of multi-pane windows sit 15pt deeper than single-pane rows, so the
indicator column is no longer straight. Deep nesting pays twice, indent
and header. At 200pt the extra indent truncates titles earliest of the
four. With many small multi-pane windows the list grows by 24pt each.

## D · Disclosure

Hierarchy: a chevron and a dot leader.
Grouping: whitespace, and a rail for the focused window.

- Chevron: 6pt, 1.5pt stroke in the muted colour, in the 12pt gutter at
  x = 4 to 10, centred on the title line (top 13), only on rows that
  own child windows. Down when expanded, right when collapsed; the
  children block is hidden when collapsed.
- Leader: 1pt dotted line (dash 1 on, 2 off) in the tree colour at the
  chevron's centre (row left + 7), from row top + 22 to the last
  descendant's bottom − 10.
- Windows: 6pt gap between top-level windows, no separators. The
  multi-pane window that holds the focused pane gets a 2pt rail at its
  left edge, 1pt radius, label 75% light / 85% dark, inset 7pt top and
  bottom. Single-pane windows rely on the focused row fill.
- The collapsed column shows `sidebar-tests` folded.

Better than the current design: the only variant that lets a deep tree
be folded, so 3+ levels stop costing space; the leader is quieter than a
solid guide and sits in the gutter, so it never crosses a fill. Worse:
the leader sits 28pt left of the children's indicators, so it reads as
a block rail, not as a line to the parent; the chevron adds a control
to the gutter next to the 2pt rail, and a collapsed row hides its
children's status (a rolled-up indicator would be needed). Grouping by
whitespace alone is weak: a 6pt gap and a rail only on the focused
window leave unfocused multi-pane windows ungrouped. At 200pt the
leader and chevron take no title width. With many small windows the
gaps add 6pt each and unfocused windows look like a flat list.

## E · Hybrid (the recommendation drawn out)

Hierarchy: B's elbows. Grouping: A's card, no bracket.

- Card: label 5%, 11pt radius, 4pt padding, margin −4pt horizontally,
  only on a top-level multi-pane window; 4pt gaps between windows.
- Stem and arms as in B: 1pt tree colour from the parent indicator's
  centre, a 9pt arm to each child row at its title centre.
- A nested multi-pane window gets no card. Each of its panes gets its
  own arm from the parent's stem, so `lint`, `Terminal` and
  `perf-notes` hang from `review-notes`'s stem alike.

Better than the current design: one line system, and the window group
is unmistakable without a second vertical. Worse: a nested multi-pane
window is invisible as a group; its panes read as siblings of the next
child window. At 200pt it costs nothing beyond the current indent.
Many small windows get 4pt gaps and one card per multi-pane window.

## F · Pane strip

Hierarchy: indent under the window row. Grouping: the window is a row,
its panes are chips.

- Window row: a normal 32pt row titled with the window name in regular
  weight, led by the worst status among its panes (error > attention >
  running > done > idle).
- Chips: 20pt tall, 6pt radius, label 5% fill, 11pt text, 7pt left and
  8pt right padding, 5pt gap after the 6pt dot, 4pt gaps, wrapping;
  they start at x = 36 (the title column) and end 8pt above the next
  row. The focused chip has the label 10% fill with a 1pt inset ring
  of the same colour. Live agents stay semibold with the @; a chip
  carries the pane's clock in 10pt muted.
- Children of a pane hang under the chip strip at the next 15pt step,
  in pane order; the chip they belong to is not drawn.

Better than the current design: a window with many panes costs one row
plus one or two chip lines; the window name is visible. Worse: the
chips lose captions, so a waiting pane's question is gone; a child
window cannot be tied to its chip; the focused pane is a small chip
instead of a full row, so the keyboard-selection and the focused fill
need a new shape. At 200pt the chips wrap to three lines, which still
works, but the chip names truncate at 150pt max width. Deep nesting
behaves as today below the strip.

## G · Layout glyph

Hierarchy: indent, no guides. Grouping: a miniature of the layout.

- Glyph: 16×12pt, 1pt muted outline with 1pt split lines that follow
  the tmux layout (`app` is a left pane and a right column split in
  two; `checks` is two columns); the highlighted pane is a muted fill.
  It sits between the indicator slot and the title with the usual 8pt
  gaps, so titles in a multi-pane window start at x = 60 and captions
  move with them.
- Window row: a 32pt row with the window name, no status indicator,
  the glyph showing the focused pane filled.
- Pane rows follow flat at the same x, each with the glyph filling its
  own pane. Children of a pane indent one step. Single-pane windows
  have no row and no glyph.

Better than the current design: the only variant that tells the user
where a pane is on screen; grouping needs no fill or line. Worse: a
second leading mark on every row of a multi-pane window costs 24pt of
title width, so at 200pt the titles truncate earliest of all eight
variants; a window row without an indicator breaks the "every row has
a mark" rule; the glyph needs the real layout from tmux, and a layout
with five or more panes becomes a smudge at 16×12. Deep nesting is
indent only, as in A.

## H · Dim ancestors

Hierarchy: typography and a short connector. Grouping: hairlines.

- An ancestor with a running descendant (`sidebar-tests`,
  `review-notes`) takes the muted colour for its title; the children
  stay full strength. Captions are muted already.
- Connector: a 1pt dotted elbow (1 on, 2 off, tree colour) from the
  parent indicator (3pt below it, at its centre x) down to the first
  child's title centre and across to 3pt before its indicator. Later
  children have no connector.
- Multi-pane window: a 1pt hairline (label 7.5%) above and below the
  window, inset 12pt on each side, 3pt inner padding; the rows keep
  their full width. A nested multi-pane window gets the same frame at
  its depth; two adjacent framed windows share one hairline.

Better than the current design: the quietest treatment, nothing
crosses a fill, and it reads which branch is active. Worse: dimming a
title that is waiting for the user (`sidebar-tests`, orange dot) works
against the attention state; an idle ancestor stays full strength, so
hierarchy depends on what runs, and the connector reaches only the
first child, so the second child's parent is implied by indent alone.
At 200pt it costs nothing. Hairlines between many small windows look
like the separators the current design removed.

## Not built

E (whitespace plus a focused accent rail) is folded into D's grouping.
A pure disclosure variant without the leader is Finder's outline and
was judged too weak on its own at depth 3.

## Recommendation

Unchanged after E to H: build E, B's elbows on A's card. Of the new
four, F is the strongest alternative when windows carry many panes, and
G's glyph is worth keeping as a hover or tooltip detail rather than a
leading mark. Reasons:

- Elbows are the one change that improves depth 3+, which is where the
  current parallel guides fail; the stem already starts at the parent
  indicator, so the geometry is the current one plus a 9pt arm.
- The card answers the grouping question without a second line system,
  so the line work stays one tree. The bracket in B and the leader in D
  both add a second vertical at x = 5 to 7 that competes with the stem.
- Cards and elbows cost no width at 200pt and no height per window
  beyond a 4pt gap, unlike C's headers.
- E draws the nested multi-pane window without a card. Its panes then
  read as siblings of the next child window; a nested bracket as in B
  is the fallback if that matters.

C is the runner-up if window names matter in the sidebar. D's folding
is worth keeping as a later feature on top of whichever treatment wins;
it does not need the leader.

## Open questions

- Should the tree lines and card stop at the focused row's fill, or
  cross it as today?
- Does a card need a hairline edge on the dark theme, where 5% white is
  faint over the shaded sidebar?
- C: is the window name worth 24pt per multi-pane window, given the tab
  strip already shows it?
- D: what does a collapsed row show for hidden children's status?
- F: where do a chip's caption and its children's attachment go?
- H: should a waiting ancestor keep its full-strength title?
