# Sidebar reference — macOS 27

## Children in place, collapsed by default — approved 2026-11-07

Two changes the user asked for, previewed in the mockup ("Working
session + states" and "Claude Code · child records"; the **Split
Right** control above the window shows the layout rule). It is
implemented; docs/design-app.md ("Folded children") is the reference
for the code. The user answered every open question ("Decisions"
below). Change 1 went on 2026-11-13 with the child panes of subagents
(plans/koa-subagents.md): a child in another window is an ordinary
window with a tab, and the slots, the breadcrumb and ⌘↑/⌘↓ are gone.

**1. A child shows in its parent's place.** The window layout holds
top-level panes only. A child window (a subagent, a run, a Claude Code
child) never has a layout of its own: it is one pane, and the app
shows it inside the slot of its top-level ancestor pane. Clicking a
child row (or Enter on it) swaps that slot to the child and focuses it;
the other slots of the window do not change. Clicking the parent row
swaps the slot back. A grandchild shows in the same top-level slot. The
tab strip is unchanged: the tab is the top-level window, and it stays
active while a child shows. Each slot remembers the pane it shows
(per top-level pane, in memory): switching tabs and back, or focusing
another slot, keeps the child in place. When the shown pane goes (the
run ends, the subagent's window closes), the slot returns to the
parent. When the parent goes, the slot goes with its subtree, as
today.

- **Layout edits act on the top-level window only.** Split Right/Down
  on a slot that shows a child adds the new pane beside that slot in
  the top-level window; the child stays in its slot. Zoom zooms the
  slot. Resize and float edits address the top-level pane. The app
  never sends a layout edit to a child window; nested layouts stop
  existing in the app. Close Pane (⌘W, the ×, the menu) closes the
  focused pane: with a child shown that is the child (and its window),
  through the same confirmation as today, and the slot returns to the
  parent.
- **A breadcrumb pill in the pane** (user, 2026-11-08, back after the
  2026-11-07 rejection). A slot that shows a descendant draws a pill at
  its top left, 8pt from the top and the left edges, in the COPY
  pill's family: 22pt high, 8pt radius, the pane background mixed 8%
  toward the foreground, the shared capsule edge and contact shadow of
  pane/NOTES.md "Capsule (shared)" (since 2026-11-09: edge 16% light /
  14% dark, shadow black 8% y1 blur 2 light / 30% y1 blur 3 dark, no
  inner highlight; the earlier lift shadow smeared on cream), 11pt
  text. It holds the path
  from the top-level pane to the shown one, `@kido-app › @sidebar-mockup`,
  names separated by `›`. Each ancestor is a button in the muted
  colour; clicking it shows that ancestor in the slot and focuses it.
  The shown pane's own name ends the path, in the label colour, not a
  button. A slot that shows its own top-level pane has no pill. The
  pill sits above the pane's content like the COPY pill and behaves
  like it: the toolbar and find do not hide it, and it moves down to
  y 48 together with COPY when the find capsule would leave less than
  72pt of clearance. In copy mode COPY keeps its place at (8, 8) and
  the breadcrumb sits to its right, 6pt after COPY's right edge, on
  the same line; they stay two capsules. Width: the pill takes what
  its text needs up to the slot width minus 16pt, minus COPY's width
  plus 6pt when COPY shows. Over that, it shortens in this order:
  middle ancestors (all but the first and the last) collapse into one
  "…" that is not a button; then each remaining ancestor name
  ellipsizes at its end, down to about 60pt each; last, the shown
  pane's name ellipsizes. While find or the hover toolbar shows on
  the pill's line, the cap also ends 6pt before them, and the pill
  shortens in the same order; it moves down to y 48 only when the
  room that leaves is under 72pt. When even the shortest form does not
  fit, with the shown pane's name down to about 40pt, the pill hides;
  it never clips inside its capsule, and ⌘↑ still works. The runtime
  pill at the slot's top right gives way: it hides when less than its width plus 6pt remains
  after the breadcrumb at its shortest, because the stripe and the
  sidebar suffix still name the runtime. The mockup does not show
  these collisions; this paragraph is the spec for them.
  The keys still move in the hierarchy: ⌘↑ shows the parent of the
  focused pane in its slot, ⌘↓ shows the child the slot last showed,
  or the first child when it never showed one; both do nothing at the
  end of the chain. Focus follows the shown pane.
- **Focus.** The focused row is the pane on screen in the focused slot,
  parent or child. No row marks a child that is on screen in an
  unfocused slot.
- **The server** (decided during the implementation, user,
  2026-11-07) keeps a child window to one pane for every client,
  removes a pane's whole subtree with it, and sizes each window that a
  client reports, so a child gets its slot's size. ko_tui keeps
  showing child windows as windows.

**2. Children are collapsed by default.** (The geometry of this
paragraph, the 30pt circles, the 40/54pt rows, the trailing chevron
and the hover fill, is the 2026-11-07 state; "Indicator on the right"
below replaced it on 2026-11-08.) A pane row with children
(child windows and Claude Code child records alike) shows them folded.
The hidden children appear as a line of the row (the third line in
this decision; the activity line since 2026-11-08, below): a row of 6pt status indicators, one for
each direct child that is not shown as a row, in the children's
order, 4pt apart, each in the
child's own colour (the same dot or green check as its row would show;
gray for idle). The circles start at the title's x, 30pt from the
row's edge, and the child rows come to them: the nesting step is 15pt,
so a child row's indicator (6pt in a 12pt slot, 12pt inset) also
starts at 30pt, and a folded and an expanded child line up under the
parent's text. The rest follow at 10pt centres. More
than six: the first six, then `+N` in 10pt muted tabular digits.
Exactly one hidden child: its name follows its circle on the same
line, in the activity text's 11pt muted style, cut with an ellipsis
before the trailing column, so the row keeps its height and the
common case (one subagent, one run) reads without expanding. The
line is a 12pt line box, so the row is 40pt (title + circles) or 54pt
(title + activity + circles); the title and activity keep their
places. The circles are the toggle: clicking them (or → on the
selected row) expands the children; the line goes, the row shrinks
back to 28/42pt, and a 10pt chevron-down appears in the trailing
column after the clock; clicking it (or ←) folds them again. Hover
brightens the circles and gives them the 10% labelColor fill at a 4pt
radius. Clicking the row's body still focuses the pane. Expanded state
is per pane, in memory, and goes with the pane.

- **Waiting expands only its child.** A collapsed parent whose
  descendant waits for input (a live agent, or a blocked Claude Code
  record) shows that descendant's row, and the rows on the path to
  it, under the circles line. The expanded child has no circle: the
  line lists only the children that are not shown as rows, so each
  child appears once, as a circle or as a row, and the circles plus
  the rows are the whole set. A parent whose every child is shown
  this way has no circles line and, until the user expands it, no
  chevron either. When the wait clears, the row folds
  back unless the user expanded the parent. A failure does not expand
  anything: its red circle shows it. Neither does a completion.
- **No tree guides.** The hierarchy guides go (user, 2026-11-07).
  Nesting alone shows the hierarchy: the 15pt step per level (so a
  child's indicator starts at its parent's title x), and the circles
  line under a folded parent. The multi-pane window bracket
  stays: the 1pt line 5pt inside a top-level window item that holds
  more than one pane, from the first pane row's top plus 10pt to the
  item's bottom minus 10pt, so it also spans the descendants shown
  under those panes. The nested-guide geometry below is historical.

### Indicator on the right — approved 2026-11-08

The row's status indicator moves from the leading slot to the
trailing column, after the clock (the mockup's **Indicator: Right**):
the same 6pt dot or check in the same 12pt slot, 1pt after the clock,
so 4pt of space separate the clock's text from the mark, the gap of
the folded-child circles (user, 2026-11-08).
The hover × replaces it there. The geometry (5pt padding, the leading
chevron slot, text at 23pt, the indicator centre 11pt from the right
edge) is below; it is implemented, and docs/design-app.md ("Sidebar",
"Folded children") is the reference for the
code.

The folded circles line is on the row's second line, the activity
line, not on a third line of its own: a row with folded children is
42pt like any two-line row. The circles take their width first, right
aligned; the activity text gets the rest and ends in an ellipsis
before them, with 6pt between. Without activity text the line holds
the circles alone. When the circles themselves do not fit between
the text column's start (23pt plus the indent) and the trailing
indicator, in a narrow sidebar or at deep nesting, the activity text
is already gone (it hides once its width falls under 16pt, so no
lone letter remains), and the line drops circles from the end into `+N`
until it fits, down to one circle and `+N`; a single child's name
ellipsizes instead. When one circle and `+N` still do not fit, the
line shows `+N` alone, the count without a circle; when even that
does not fit, the line is absent and the chevron alone says that
children exist. Nothing clips. The trailing column is the same on
every row: the elapsed clock, 1pt, then the 12pt indicator slot, so
the clock ends 4pt before the 6pt mark.

Each circle of a folded line summarises the hidden child's whole
subtree (user, 2026-11-08): the child itself, its descendant panes
and its OSC 7501 records, reduced by the order error > running >
idle. A folded circle has no "done": a clean end (the gray check:
done, or gone with outcome completed) counts as idle and is the gray
idle circle; a failed end (the gray cross) counts as error. So a
dead or idle child with a running grandchild shows a running circle,
and a child whose work all ended cleanly shows a gray one. The line
summarises the progress of the work, so the circles are ordered by
their reduced status, error first, then running, then idle, and only
then cut to the limit (six, or fewer on a narrow row) with `+N`;
within one status the children keep their sidebar order. The order
applies always, not only when the line overflows, so a running or
failed child never disappears into `+N` behind idle ones (user,
2026-11-08). The stress fixture's `@devpi` pane shows it: nine
children, the failed and the running one last in sidebar order,
first in the line. A waiting descendant needs no rule: it unfolds its
path. The rule is for the circles of the folded line only; an
unfolded row's mark and a top-level row's mark are their own status.

A running `async_bash(..., service: true)` job does not make its
ancestors look running (user, 2026-11-08): its OSC 7501 record is
`state=idle` with the msg "service: <name>", so its own row shows the
gray idle dot and the caption, and it reduces as idle in a folded
circle; its end still writes done or error. (The agent extension
wrote `working` then; the client cannot tell a service from a job
without parsing the msg, so the change is in the extension.)

An idle pane is a gray circle (the muted colour at 50%) everywhere:
in the folded circles line, where the line counts the children so
each one needs a mark, and in the row's own trailing indicator, top
level included (user, 2026-11-08; before that the row's idle
indicator drew nothing). So every row has a mark, and the header's
plus, centred 11pt from the edge, sits on the same column. The line
has no hover fill.

With the indicator on the right, the folded children line is right
aligned too: its last circle ends under the trailing indicator, and
for a single hidden agent child the name comes first, then its
circle (`@sidebar-mockup ●`); a single hidden job (a bash run, a
stream, a finished subagent with no live agent) is a circle alone
(user, 2026-11-09). The hit area is the circles and the name, as
before.

The collapse control is a disclosure chevron in the parent row's
leading slot, the 12pt slot that the status indicator left. Rows and
session headers have 5pt of horizontal padding (was 12pt), so the
chevron starts 5pt from the row edge, the title, the activity text
and the single-child name start at 23pt, the trailing indicator's
centre is 11pt from the right edge, and the folded circles end under
it. The header's plus is centred 11pt from the edge, on the
indicator column (user, 2026-11-08; it was 15pt). The nesting step stays 15pt. A row with children always
shows it, folded (right) or open (down): a 10pt chevron with a
1.75pt stroke (the one the title tabs use), muted at 70% with no
hover or pressed state, like the other
sidebar controls, but with the pointing-hand cursor, centred on the
title line. A
row without children has an empty slot. The chevron folds and unfolds
the block; the folded circles line still unfolds it too, and so do
Left/Right on the selected row.

A Claude Code record row with child records folds like a pane row
(2026-11-08, from the implementer's question): it has the chevron,
its own fold state keyed by the record id (in memory beside the
pane's, gone with the pane), and its own circles line on its activity
line for the hidden child records. The same rules apply: folded by
default, a waiting descendant forces its path open, failures stay
circles, only children not shown as rows appear as circles. The
record row itself stays display-only; its chevron and circles line
are its only controls.

The chevron shows the fold state, not what is visible. A folded
parent whose every child is shown for a wait, so that it has no
circles line, still shows the right-pointing chevron; a click sets
the state to expanded and turns it down, and nothing else changes.
The fixture "Claude Code · child records" shows this on the record
"Investigate sidebar layout".

Grouping is **Dividers + active fill** (decided, user, 2026-11-08;
renders `dividers-{light,dark}.png`). Between
two top-level windows of a session sits a 9pt divider row with a 1pt
line in the separator colour, inset 5pt from both edges, like the row
padding. No divider before the first window or after the last, and
none between nested windows. The fills are the standard system
fills, measured on macOS 27 (changed 2026-11-11, user: the stacked
fills were too dark). The focused pane row and the keyboard-selected
row get `systemFill`, labelColor at 10% in both appearances, 7pt
corners: the fill of a standard list selection, and the row fill that
shipped. A single-pane window gets nothing else: its row fill is the
window. A multi-pane visible window of the focused client is one
block in `quaternarySystemFill`, labelColor at 2.7% in both
appearances, 7pt corners, the block clips its rows, over all its
rows, including its expanded descendants, the records among them and
their circles lines; the focused row inside it is the flat 10% over
the sidebar colour, not 10% over the block, so a focused pane reads
the same in every window. (In AppKit: draw the block, then the row
fill as `systemFill` composited onto the sidebar colour, or clip the
row's rect out of the block.) Rows have no hover fill, so nothing
else stacks on the block. The separator is labelColor at 10% in both
appearances. The session header is outside every block: no divider
between it and the first window, and none after a session's last
window; the 10pt session gap separates sessions. The old
bracket and the other variants stay in the Grouping control for
comparison; nested hierarchy still has no guides.

Renders: `right-{light,dark}-*.png`.

### Grouping variants (exploration, not decided)

The **Grouping** control switches how the panes of one top-level
window read as a group, with the rest of the design unchanged. Renders
in `/tmp/kido-sidebar-children/group-{light,dark}-*.png`, on the
working session after one Split Right (a three-pane window).

- **Bracket** (the current design): the 1pt line 5pt inside the item.
- **Window row**: a 20pt header above the panes, the window's name in
  11pt semibold muted with "N panes" after it. Explicit, and a place
  for a rename and a close; costs 20pt per multi-pane window and a
  third row kind that single-pane windows do not get.
- **Card**: the item gets the 10% labelColor fill and a 0.5pt edge,
  with 2pt above and 4pt below. Reads at a glance with no extra
  height, but it is the same mark as the focused-row and the
  keyboard-selection fills, which then sit on it as a darker step.
- **Tight stack**: no ink; 8pt between window items, none between
  the panes of one window. Quietest, and it depends on noticing the
  gap; a two-line row next to one-line rows blurs it.
- **Layout miniature**: a 14×10pt glyph before the clock on each pane
  row of the window, N equal cells, the row's own cell filled (the
  preview knows pane count, not the real split). Says which pane is
  where, which nothing else does; costs trailing width and drawing
  code.
- **Position labels**: a 10pt muted word before the clock (left,
  middle, right). Cheapest "where"; labels each pane without drawing
  the group.
- **Shared status column**: the indicators of the window's panes move
  to the trailing column, with the bracket on the right edge. The
  group reads from the right; status leaves the leading edge the
  rest of the design uses.

### Decisions (user, 2026-11-07)

- Children show in the parent's slot; layout edits act on top-level
  panes; no nested layout.
- Children collapsed by default, a toggle on the parent row, the hidden
  children as circles, a waiting child expanded alone.
- Only a waiting child expands on its own. A failed child stays a red
  circle.
- Claude Code child records fold under the same circles.
- A breadcrumb pill in the pane when a slot shows a descendant
  (2026-11-08; rejected on 2026-11-07, brought back). ⌘↑ and ⌘↓ move
  up and down the hierarchy in the slot.
- No mark on a child that is on screen in an unfocused slot.
- Six circles, then `+N`, drawn in the row under the title, not in
  the trailing column (third line on 2026-11-07; on the activity
  line, right aligned, since 2026-11-08).
- A job row (an `async_bash` job, an OSC 7501 record `job/<id>` that
  koa's agent extension writes under its pi's pane) reads name first: the record's
  title is the job's name and its message is the command while it
  runs (`main-watch` over `scripts/main-watch.sh --stream`), and the
  end text when it ended (`lint` over `exit 1`). A running service
  reads the same, name over command, with no `service:` prefix; only
  its idle state (the gray dot) marks it as a service (user,
  2026-11-09; the fixture's `preview` row). Before 2026-11-09 the
  title was the command and the message the name; the user asked for
  the swap. The change is in the extension's writer and
  docs/design-subagents.md "A job's row", not in the app: the app
  draws a record's title over its message as for every record. The
  "Claude Code + records" fixture shows both forms.
- A single hidden child shows its name with its circle, in the small
  muted font, on the same line (user, 2026-11-07), only when that
  child is an agent: a pane with a live agent or a program record. A
  single hidden job (bash run, stream monitor, or a subagent whose
  agent is gone) is a circle alone (user, 2026-11-09).
- No tree guides; nesting alone shows the hierarchy. The bracket that
  groups the panes of a multi-pane window stayed on 2026-11-07 and is
  gone since 2026-11-08 (dividers and the active window fill replace it).
- Condensed rows (user, "more condensed"): 13pt titles on an 18pt
  line with 5pt vertical padding, so 28pt one-line rows; the activity
  line is 11pt on 14pt, 23pt from the row's top, so 42pt; the circles
  line is 12pt, so 40pt and 54pt (since 2026-11-08 the circles share
  the activity line, so 28/42pt only). Session headers are 26pt with the
  label 5pt from the top, and the gap after a session is 10pt. These
  replace the 32/48pt rows, 29pt headers and 16pt session gap of the
  draft below.
- No gray circle (user, 2026-11-07; replaced on 2026-11-08: an idle
  pane is a gray circle again, in the circles line and in the row's
  own indicator alike): an idle indicator draws nothing, in the row's
  leading slot and in the circles line alike, but keeps its 6pt
  space, so nothing shifts: an idle row's title stays at 30pt, and an
  idle child in the circles line is a gap that still counts. The
  hover × still appears in the empty slot.
- Tighter leading slot (user, 2026-11-07; replaced on 2026-11-08 by
  the trailing indicator, the leading chevron slot and 5pt padding):
  the indicator slot is 12pt wide at the
  12pt inset, with a 6pt gap to the text, so the dot's centre is 18pt
  and the title, the activity text and the circles start at 30pt
  from the row's edge (was a 16pt slot, an 8pt gap and 36pt). The
  hover × fits the 12pt slot. The nesting step is 15pt again.

## Superseded draft (2026-11-07): uniform rows and hierarchy guides

History only. The guides were removed on 2026-11-08 ("Children in place" above: chevrons, no guides); the uniform rows stayed. The text below is the draft as it was. Native window chrome remains unchanged.

- All pane and child-record titles: 13pt system font, 18pt line height, regardless of depth or single-/multi-pane window; regular weight, semibold only on the focused and the keyboard-selected row (weight rule below).
- All rows: 32pt single-line / 48pt with caption, 7pt vertical padding. Captions: 11pt system font, 15pt line height, 1pt gap below title.
- Uniform 15pt nesting step for child windows and slash-separated program records, chosen so each nested guide sits exactly on the parent icon's center (12pt inset + 8pt half icon = 20pt; 15pt indent + 5pt guide inset = 20pt). No extra window/pane spacing or divider rows.
- All guides are identical vertical 1pt lines in one opaque color (`#bfbab1` light, `#4f555c` dark), with no horizontal arms, no transparency and no overlapping segments. A guide sits 5pt inside the left edge of the group it covers and spans that whole group, 10pt inset top and bottom: a multi-pane top-level window's guide covers its pane rows and every descendant between and below them; a nested guide covers a parent's entire children block, including grandchildren; a program-record guide covers all records under their parent. Single-pane windows have no window guide.
- Only the focused pane row gets a background highlight, with 7pt corners. No focused left-edge mark, window-wide fill, neighboring-pane fill or descendant fill. Guides are decorative, noninteractive, and do not affect hit targets.
- Program records are nested agent rows: the preview maps each record to an agent node (title or ID, caption as the activity line, state mapped onto the indicator kinds working→running, blocked→waiting, error→failed, done→done) and draws it through the one row builder, so heights, the 15pt step per slash component, the leading status indicator, the semibold title and the ellipsis all come from the same code as subagent and run rows. Differences: no @ prefix, no click or keyboard selection, and arrow navigation skips them. The @ means "an agent you can message", which is exactly a live local pi agent (Pi_agent). A native agent pane such as Claude Code (Some_agent) and an agent reached over SSH (a remote agent; message_agent only reaches pi sessions on the same server) cannot be messaged, so their rows and tabs stay semibold without the @. The preview gives both an `agent` of another kind: the Claude Code fixture (`native`) and the "pi-review on devbox" row in the work session (`remote`). Native code should do the same: one row view, records fed as agent rows with a display-only flag.

Guide geometry, measured in the preview (points from the window item's left edge; rows are 32pt or 48pt tall, titles at a 16pt baseline band):

| Guide | x (from its group's left edge) | Vertical extent |
| --- | --- | --- |
| Multi-pane window guide | 5 | first pane row top + 10 to window item bottom − 10 |
| Children-block guide | the parent row's status indicator center (20 from the parent row's edge) | parent indicator bottom + 3 to last descendant bottom − 10 |
| Program-record guide | the parent row's (pane or record) indicator center | parent indicator bottom + 3 to last nested record bottom − 10 |

Nested guides therefore grow directly out of the parent's status indicator, not from the first child's top. Multi-pane window guides have no parent icon and keep their own column.

Lines are 1pt with crisp edges, centered on their x. Guides draw above fills, as content does in native lists; the multi-pane guide therefore crosses the left edge of a focused row's fill. Keyboard-selection and focused fills both use 7pt corners.

Self-review (headless Chrome, light and dark, Claude Code and stress fixtures): every row measures 32pt or 48pt at 13pt title size across all depths; nesting steps are a uniform 15pt; indicators lead and clocks share one trailing column for rows and records. Fixed during review: record elbows previously started 28pt right of child-window stems and from the parent's bottom edge; the keyboard fill was square-cornered. Open visual point: whether the multi-pane window guide should stop at the focused row's fill instead of crossing it.

Leading icons are removed for now; the status indicator takes their place. Earlier icon variations, kept for reference (not in the preview any more):

| Set | Agents | Terminals | Runs | Notes |
| --- | --- | --- | --- | --- |
| A | `text.bubble` | `terminal` | as terminal | shipped before 0.17; removed |
| B | `sparkles` | `terminal` | as terminal | reads "AI" at a glance, lighter than a framed bubble |
| C | `text.bubble.fill` | `terminal.fill` | as terminal | heavier; solid shapes hold up better when dimmed and at 2× |
| D | `text.bubble` | `chevron.right` + underscore (`terminal` without frame) | as terminal | less boxy; the bare prompt is quieter next to the bubble |
| E | bot face (custom; no exact SF Symbol, closest `faceid` or a custom symbol) | bare prompt | as terminal | strongest agent/shell contrast, least Apple-native |
| F | `text.bubble` | `terminal` | `play.circle` | three kinds: async bash and stream monitors become runs, separating them from interactive shells |

Current rule: no leading icon of any kind. The status indicator (6pt dot; for done a plain green check with no circular base: the path `M0.2 3.2 2.1 5.1 5.8 1.1` in a 6pt box, stroked 2pt with round caps and joins in opaque green, which the app draws with NSBezierPath rather than an SF Symbol; its visual center sits on the dot's center, horizontally on the dot column and vertically on the title line's center, like every other indicator) sits in the former icon slot, centered 20pt from the row's edge (12pt inset + half the 16pt slot) plus 15pt per nesting level; idle is a gray dot (secondary color at 45%) so every row has a mark. The trailing column keeps only the elapsed clock. Program records use the same row layout, so a record's dot and title line up with child-window rows at its depth. Titles are regular; only the focused pane's row and the keyboard-selected row are semibold (600), whatever the pane runs (since 2026-11-09). The @ prefix and the dimmed "Terminal" title are the whole agent/shell distinction.

Review the default Claude Code fixture for program records and scroll to the multi-pane kido-app group for selectable nested windows. This is a draft for visual review, not an approved implementation specification.

---

## Earlier reference (historical geometry below)

Self-contained reference for Kido.app 0.10.1 on macOS 27. The implementation is authoritative: `App/{Sidebar,SidebarView,SidebarRow,WindowTabs}.swift` and `Packages/SidebarFeed/Sources/SidebarFeed/{Rows,Windows}.swift`. The HTML approximates native drawing; it does not replace AppKit.

```sh
open design/sidebar/mockup.html
```

## Evidence and appearance

Updated against `/tmp/kido-visual-macos27/index.html`: paired macOS 26/27 captures of `testSidebarCards.*`, `testFloatingSidebar.collapsed-floating`, `testHostLabel.*`, and `testWindowTabs.*`. Chrome now follows `/tmp/kido-chrome-macos27/{windowed-docked,windowed-collapsed,windowed-floating,fullscreen-docked}{,-crop}.png` and `frames.txt`: real active/key-window captures with measured AppKit frames at 2× backing scale. Fullscreen states also follow `/tmp/kido-fs-probe/kido-{light,dark}-{docked,wide,collapsed,floating,switched,reentered}.png`. Final corner verification uses `/tmp/kido-corners-macos27/{light,dark}-windowed-docked{,-crop}.png` and `{light,dark}-fullscreen-docked-crop.png`: these show the corrected square/edgeless docked sidebar. Their “could not reach Local” message is stopped-test-server content, not a design change. These supersede the initial fullscreen screenshot for toolbar/background geometry. All paths are local review artifacts, not runtime dependencies.

The old/new pairs primarily change native glyph shapes/rasterization, not the approved row geometry or palette. Keep system fonts at the existing point sizes rather than inventing larger sizes or heavier weights. Browser text uses the installed OS system font; CSS line boxes and SVG approximations cannot reproduce NSString/SF Symbol rasterization exactly.

The sidebar is a solid colour, not a material: the effective terminal background (Ghostty `background`) mixed toward black or white by the `window.sidebar_shade` percent of the YAML config file (`kido-sidebar-shade` of kido-app.conf before 68fc22e1) (−100…100; negative toward black, positive toward white, 0 = the terminal background). With no key or an empty value the default depends on the theme: −5% (toward black) when the terminal background is light, +5% (toward white) when it is dark, where light/dark is the app's existing decision from the terminal background's luminance (below 0.5 is dark). An explicit value applies as given on both themes. It follows live theme changes. The preview computes it the same way with `color-mix(in srgb, bg (100 − |shade|)%, black | white)` from the bundled themes kido-light `#fff9ec` and kido-dark `#171717` (app/Resources/themes); the defaults render as `#f2ede0` light and `#232323` dark. The **Shade** control previews the default and −100, −30, −10, −5, 0, +5, +10, +30 and +100. There is no separate visual-test surface any more: a solid colour renders the same under the snapshot tests as in the live window.

**Sidebar text appearance (approved, implemented).** The sidebar's light/dark appearance comes from the shade colour's own relative luminance, not from the terminal theme, so a large shade in the other direction (for example +100% on a dark theme) still reads. White text has the higher contrast ratio while the colour's relative luminance L is below 0.179 (the point where (L + 0.05) / 0.05 equals 1.05 / (L + 0.05)); above it, the light appearance (dark text) wins. In the app this is one `NSAppearance` choice for the sidebar subtree, computed from the same colour that fills it. The preview flips the sidebar's palette variables, not the terminal's.

The sidebar has no inset/shadow in docked mode. Default width is 292pt; Width previews also cover the measured 236pt and 320pt variants. Docked, the shade fills the full sidebar width/height with square corners and no hairline edge, in both windowed and fullscreen modes, up to the window top and behind the toolbar. The rounded outline visible in the supplied docked captures was a Kido bug and is intentionally not reproduced. Only the floating overlay keeps an 18pt rounded card with a 0.5pt labelColor-12% border. Floating mode overlays terminal content; in fullscreen its rounded card begins below the themed toolbar band.

Toolbar controls sit in window-level 52pt chrome. Coordinates below are CSS/AppKit points measured from the top-left, not 2× screenshot pixels. Traffic lights are 14pt, at x=19/42/65, y=19, with 9pt gaps. New Session is hidden in collapsed/floating modes. Toolbar symbols approximate the app's 20pt/small SF Symbol configuration.

| Control | x | y | width × height |
| --- | --- | --- | --- |
| New Session, docked | sidebar width − 86 | 8.5 | 32.5 × 34 |
| Toggle, docked/floating | sidebar width − 42 | 9.5 | 32.5 × 32 |
| Tab host, docked/floating | sidebar width + 8 | 8 | remaining width − 8, × 36 |
| Toggle, windowed collapsed | 142 | 9.5 | 32.5 × 32 |
| Tab host, windowed collapsed | 184 | 8 | remaining width − 8, × 36 |
| Toggle, fullscreen collapsed | 56 | 9.5 | 32.5 × 32 |
| Tab host, fullscreen collapsed | 98 | 8 | remaining width − 8, × 36 |

For 292pt docked: New Session x=206, Toggle x=250, tabs x=300. The header's first row begins at y=54 (52pt safe area + 2pt list inset); heading line box y=60.5; first pane row y=83. Table x=8, width=sidebar width−16. No decorative CSS border consumes layout space. Fullscreen hides traffic lights without inventing new docked/floating button positions.

The tab host is 36pt tall at y=8 within the 52pt toolbar. Tab surfaces stay 28pt tall (4pt inset in the host), 7pt radius, 2pt leading/1pt trailing inset, equal widths clamped to 85–220pt, with 11pt system labels. Active tabs use 7.5% labelColor fill and a 1pt stroke. No hover/press/focus-ring treatment. Fixed remote label: 11pt medium secondary text, 16pt line box centered in the host, 2pt leading inset, up to 166pt text width; total reservation is text width + 25pt, capped at 35% of the strip. Separator sits 11pt before that reservation's end. Offline/reconnecting dim label and separator to 45%; only the alias is a tooltip. Tabs scroll independently.

**Fullscreen background fix is represented, implementation settled.** The docked shade extends through the 52pt toolbar band, identical to the colour below. The themed band begins only to the right of the sidebar divider. Collapsed and floating fullscreen modes retain the themed band across the entire window; the floating card starts below that band. Width changes, session switches and fullscreen re-entry preserve this boundary. The docked shade has square edges and no outline. Only the floating card has rounded corners and a hairline border. This replaces the previous preview's incorrect cream band over docked glass.

## Closing, new windows and Connect to Remote Host — shipped

The close confirmation, the tab and row close buttons and the new-window controls shipped as below. The Connect to Remote Host sheet did not: the palette's Connect mode replaced it (../palette/NOTES.md); the sheet in the mockup is history.

- **Close confirmation.** Closing a pane or window asks unless every live pane in it, descendants included, is a quiet shell (the row titled "Terminal") that holds the foreground; any agent, also idle, a running command, a full-screen program, a shell of unknown phase (no integration, ssh) or another foreground process makes it ask, and a dead or lingering pane does not. The question is a standard window-modal alert sheet: app icon, bold 13pt title `Close “name”?`, 11pt message ("A program is still running in this pane. Closing the pane will end it." / "Programs are still running in this window. Closing the window will end them."), then stacked full-width buttons: **Close** (default, blue, Enter) above **Cancel** (Escape). Windows of quiet shells close without asking. The user settled that every path that ends a pane or window goes through this one confirmation: the × buttons, Cmd-W, menu commands, and any other app-issued kill. Closing the native macOS window is not one of them: it only closes that window's control client, the app and every pane keep running, and reopening redials, so it never confirms. Native: NSAlert as a sheet on the window, `.warning` style, Close as the default button, Cancel bound to Escape.
- **Tab status and close buttons.** The tab's status dot moves to the leading side: centered 15pt from the tab surface's leading edge. Hovering the indicator's own 16pt slot (not the rest of the tab) replaces the dot with a 16pt × close button centered on the same point; the dot returns when the pointer leaves the slot, and hovering elsewhere on the tab changes nothing. The label is always inset 26pt on both sides, so neither the dot nor the button changes the label's position or width on hover. Hovering the button only brightens it and adds a faint 4pt-radius fill. Click goes through the confirmation above. No press feedback beyond that. Cmd-W closes the focused pane through the same confirmation.
- **Close buttons on sidebar rows.** Hovering the status indicator's own 16pt slot on a pane row (never a program record, and not the rest of the row) replaces the indicator with the same × button in that slot; elsewhere on the row the indicator stays. Clicking closes that pane (its nested windows with it), via the same confirmation.
- **Tab titles in the sidebar's style.** Every tab title is regular weight (since 2026-11-09; before, a live agent's tab was semibold). A tab whose active pane is a live Pi_agent shows the display-only @ prefix (not doubled if already present); shell, run and other tabs have no @. Window names, identities and tmux data are unchanged.

- **Inline session rename.** Double-clicking a session heading's name edits it in place, Finder-style. The field replaces the label exactly in place: same 11pt semibold font and 18pt line, text starting at the label's x, primary text color on the sidebar background with a hairline edge and the accent focus ring, the whole name selected; the session + does not move and the body below does not shift. Enter or clicking elsewhere commits; Escape cancels. An empty or unchanged name reverts silently. A duplicate of another session's name keeps the field open and shows the reason under it in 10pt red ("A session named “x” already exists."), the heading growing to fit; editing again clears the error. A single click still does what it does today (nothing on the label). Native: an NSTextField swapped into the header cell on double-click, committed through rename-session, with tmux's refusal shown as the inline error rather than an alert. The preview changes only its own data.

- **Tab status marks by sidebar mode.** A tab carries one mark, combined from the panes of its window (since 2026-11-13; before, also from nested child windows) in the order error > waiting > running > done > quiet, where a done pane counts only while its outcome is unseen. The mark is the sidebar row's own indicator (6pt dot, or the green check) in the tab's 16pt leading slot, which the hover × still replaces; quiet shows nothing and the 26pt label inset never changes. Docked sidebar: red and orange only, as today, because the sidebar rows already show the rest. Collapsed or floating sidebar: running (green dot) and unseen done (green check) appear as well. Accessibility labels take the suffix of the shown mark only: " — error", " — waiting", " — running", " — done". Tabs cover only the current session; other sessions have no indicator. The "Tab status marks" panel under the window renders the same tab strip docked and collapsed/floating, light and dark, from the current fixture. The preview has no seen state for done rows, so every done row counts as unseen there.

- **New window button.** A 28pt-wide, icon-only + at the trailing end of the tab strip, outside the scrolling tabs, hover brightening only like the session plus. It opens a new shell window in the current session and focuses it.
- **Connect to Remote Host (redesigned).** A 440pt window-modal sheet: bold title, one-line lead ("Opens a new window attached to the host's kido server over SSH."), a **Host:** field (user@hostname or SSH alias, 11pt help line "Uses your SSH configuration, keys and known hosts."), then a bordered **Recent** list (132pt tall, 24pt rows, host plus a relative time, alternating row fill, blue selection). Clicking a recent host fills the field; double-clicking connects. Buttons: **Clear Recent** on the left (disabled when the list is empty, which shows "No recent hosts"), **Cancel** and the default **Connect** on the right; Enter connects, Escape cancels. Connecting records or refreshes the host in the recent list. The preview stores the list in browser localStorage and opens the sheet from the **Connect to Remote Host…** control above the window; natively it is the Spotlight/Shortcuts action's window or a menu command, and the recent list lives in app preferences. SSH's own checks still apply; the dialog never bypasses them.

## OSC 7501 child records — shipped

The default **Claude Code · child records** fixture shows program records below their owning pane, before selectable child windows: three working Claude Code subagents (one with a caption) and a nested blocked permission record. Like `lib/sidebar.ml` / `lib/ui.ml`: exclude the root id, order ids lexicographically by slash components (bytewise UTF-8), indent by component count even if intermediate records are absent, fall back to the full id for an empty title, show msg as the activity line. State mapping: working→running, blocked→waiting (orange), error→failed (red), done→done (green check), idle→gray. Visiting the parent pane (by row or tab) acknowledges done/error for that pane's serial; records stay, working/blocked stay visible, and a newer serial restores completion/error indicators. Everything else about a record's appearance is in the redesign draft above: it is an agent row.

## RPC 6.0 rules (approved)

The preview's fixtures follow the 6.0 feed shape:

- A pane item's `run` is an opaque run id or null, never a kind. The elapsed clock is attached when `run` is non-null and `started` is non-null, for any run.
- A pane item's `agent` is the live agent it reports, or null: `{kind: "pi", session}` for a local Pi_agent (its field is `session`, not `id`), `{kind: "native"}` for Some_agent (Claude Code), `{kind: "remote"}` for an agent over SSH.
- **Weight.** Since 2026-11-09, a sidebar row's title is semibold only when the row is the focused pane or the keyboard-selected row; agents, records, shells and runs are otherwise all regular. Weight marks selection, not kind: the status indicator, the @ and the dimmed "Terminal" title carry the agent/shell distinction. Tabs are all regular, the active tab included (2026-11-09); the tab's fill marks the active one.
- **The @.** Display-only, and only for a live Pi_agent. Native and remote agents are semibold without it; runs and records never get it.
- **Waiting is attention** only on a live agent or a record; a waiting indicator on a plain run is not an orange tab mark.
- **Notifications.** A run pane is silent only when it is nested under another item. A top-level run (no parent item) notifies like any pane.

The "Working session + states" fixture shows the regular-weight cases: the completed `pi-ui-perf`-style subagent under review-notes (gone, completed, `agent: null`) and the still-starting `perf-notes` subagent (a run with a clock, `agent: null`, idle dot).

## Approved (user, 2026-11-12): back and forward

The user asked for back/forward buttons in the sidebar header,
because a pane is now reached by many jumps (a sidebar click, a
koa `@name` link, Cmd-Up/Down, the palette, a tab). The mockup's
header has them; a click on rows fills the history. The user
approved the mockups and left the shortcut to the designer:
Control-Command brackets, as below.

- **Placement.** After the traffic lights, where Safari and Finder
  put them, as one native 64pt toolbar item (two 32×28 buttons) in
  the toolbar's own flow, so every point of both buttons is
  clickable: the first item starts at 96pt in the unified title
  bar, so back is at 96 and forward at 128, and the items after
  it (New Session, the toggle, the tab strip) move right by the
  item's width. Collapsed: lights, back, forward, New Session's
  hidden slot (as before), then the toggle; the tab strip after
  it. `chevron.left` and `chevron.right` at the sidebar
  symbol size (`IconButton.sidebarSymbols`), the same hover
  brightening and no background. Fullscreen (no lights): the item
  is first, and the rest follows it in the same flow. Floating: as
  docked. The mockup's hand-placed numbers (80/112, 142/184,
  10/42) are the picture, not the spec; the native flow is.
  The docked sidebar's minimum width rises from 200pt to 256pt
  (one constant: the split's minimum, the initial clamp and the
  saved-width threshold), the least at which lights, history, New
  Session and the toggle fit without the toolbar's overflow menu
  (the toggle ends at about 246pt in the native flow, plus
  NSToolbar's margin); a narrower sidebar had no room for its rows
  anyway. Disabled at 35% opacity when the history has nothing
  that way; tooltips "Back ⌃⌘[" and "Forward ⌃⌘]".
- **One entry** is a focus target `(session, window, pane)` of one
  macOS window; each window has its own history. Only the shown
  pane counts: the target of a jump, not the top-level slot.
- **What pushes.** Every change of the window's focused pane that
  the user asked for: a sidebar row, a tab, Cmd-1…9, a `@name`
  link, the palette, Cmd-Up/Down, the directional pane moves
  (h/j/k/l, Cmd-Opt-arrows, Next/Previous Pane), a session switch,
  and a new pane or split (its new pane is the entry). Not: back
  and forward themselves, and a focus that the app moved on its
  own (the pane closed, the server reconnected, a window was
  killed). A repeat of the current entry pushes nothing.
- **Gone panes.** When a pane goes, its entries drop; the index
  stays on the current entry. So Back always lands on a live pane,
  and the buttons disable when nothing live remains that way.
- **Length.** 100 entries for each window; the oldest drops.
- **Shortcuts.** Cmd-[ and Cmd-] are Next/Previous Pane, Cmd-Shift
  the windows, Cmd-Option the sessions; so back/forward are
  Control-Command-[ and Control-Command-] (Xcode's Go Back/Forward
  are Control-Command-arrows). The mouse's back and forward buttons
  (buttons 4 and 5, `otherMouseDown` with buttonNumber 3 and 4)
  do the same when over the window. No swipe: the terminal scrolls.
- **Menu.** "Back" and "Forward" in the Shell menu's navigation
  group, after Next Pane and Previous Pane, with the shortcuts;
  disabled like the buttons. The palette lists them as commands.
- **ko_tui** gets nothing: its one view is the pane it shows.
- History is client state; no ko route.

## Proposal (user, 2026-11-11): two lines always, focus expands

The mockup's "Rows" picker (`rows=auto`, the default; `chevrons` is
the shipped design) shows two changes.

- **Every row is two lines** (42pt): the title, and under it the
  agent's status (its `tail`, what `set_status` set). A pane without
  a status, and every Terminal, app, ssh pane and job, has an empty
  second line (user, 2026-11-11: no cwd there, it is too noisy; an
  empty line is fine). An ended failure's second line is its cause
  ("exited with code 2", the signal, the start failure). A Claude
  Code record row shows its `msg`; a record without one shows its
  state word (working, needs your input, error, done, idle). The
  folded-children circles keep their place at the right of the
  second line; the text ellipsizes before them.
- **No chevrons.** A row's children show when the row is focused,
  or when the focused pane is one of its descendants (so a focused
  child keeps its path open); an unfocused row folds them into the
  circles. A waiting descendant still forces its path open. Record
  rows follow their pane: a focused Claude Code pane shows its
  records, an unfocused one folds them. Left and Right do nothing;
  Cmd-Up and Cmd-Down still step the hierarchy. With the chevron
  slot gone, the text starts at the row's 5pt padding.

## Approved sidebar geometry

Sessions are plain noninteractive 11pt semibold secondary labels in 26pt headers (29pt before the 2026-11-07 density pass), followed by windows; no session card or folding. Label line-box y=6.5pt. The trailing 11pt plus (matching the 11pt heading type) creates a new window (preview placeholder), with icon-only hover and center aligned to status circles, 11pt from the item's right edge (since 2026-11-08; 15pt before). Session bottom gap is 10pt (16pt before the density pass). The scrolling list has 8pt horizontal insets, 2pt top and 10pt bottom space.

Each window is one 7pt-rounded item containing its pane rows and their descendants. Active window gets continuous 10% labelColor fill, including all nested descendants. Focusing a child highlights its own subtree, not ancestors. Single-pane windows need no extra focus mark; multi-pane windows retain a 2pt leading mark with the row's vertical padding as its inset (85% white dark / 75% black light). Keyboard selection independently adds 10% fill and clears on mouse interaction.

Render children immediately after their owning pane, before the next sibling pane. Indent 16pt per level, no guides. Window bottom spacing is 3pt, with an additional 3pt after a pane's children, matching the native rows. Top-level windows alone have separators BETWEEN windows: the 9pt divider row with a 1pt line at 10% of the label colour, inset 5pt ("Grouping is Dividers + active fill" above). No nested dividers, no divider before the session's first window, none between panes of one window.

| Window kind | One-line height | Activity height | Top padding | Activity y |
| --- | --- | --- | --- | --- |
| Top-level single | 32pt | 44pt | 7pt | 25.5pt |
| Top-level multi | 30pt | 42pt | 6pt | 24.5pt |
| Nested single | 28pt | 40pt | 5pt | 22.5pt |
| Nested multi | 26pt | 38pt | 4pt | 21.5pt |

Superseded by the redesign draft above for titles, insets and the leading slot. Still true: activity is 11pt on a 15pt line box, aligned with the title at x=36pt plus nesting; trailing inset 12pt; clocks are 10pt tabular digits on the first line.

No leading icons (superseded; see the redesign draft above). Agent display names get `@` without doubling it; feed identities and tmux tab names are unchanged. Quiet shell panes show dimmed **Terminal**, retaining completion/failure statuses: match native Rows.swift exactly (kind shell, no run, indicator idle/done/failed). Unintegrated/unknown and running shells retain their original titles.

Statuses: idle gray dot; running/compacting green dot; done and gone/completed the same plain green check; waiting for input orange dot; failure red dot. The feed's attention flag also includes completion and must not itself select orange. Dots are 6pt; the check is the same 2pt-stroked path in HTML and in the app, so the two render identically.

## Interaction and fixtures

Arrow keys/j/k navigate, Enter focuses a pane, Escape returns focus to the pane. Session/window creation and terminal content are placeholders. Captured timestamps are historical, not a live feed connection. Fixtures include nested multi-pane windows, long titles, waiting/failure/completion, SSH/shells, and orphaned windows. Preview selectors cover Light/Dark, docked/collapsed/floating, fullscreen, widths 236/292/320pt, sidebar shade, local/remote/long host and connection state.

Tabs restore each window's remembered active pane. Names/existence/order come from simulated tmux inventory; hierarchy and error/request status come from the last snapshot. Descendants select their nearest surviving ancestor's tab; orphan windows get their own. Error wins over input requests; completion/running/idle add no tab dot. Cmd-1…9 follows tab order, clamping out-of-range numbers to the final tab.

Remote entry remains Spotlight/Shortcuts **Connect to Remote Host in Kido**, with Host input and a separate window per request. No in-app picker or Recent Connections. Titles are Session locally, user@host / Session remotely; the native title is hidden, with the host identity displayed beside tabs.

## Final capture review

Re-reviewed native light/dark corner-fixed crops and the earlier populated chrome/fullscreen references against a rendered Chrome preview, including a temporary matching single-window `main`/`zsh` fixture at 900×560. Corrected remaining small differences: traffic lights had flat colors instead of the native shaded treatment; pane SVGs had excess internal whitespace; tab strokes sat entirely outside rather than centered on the path; title truncation differed by 1pt without a clock and 2pt with one; the last window's 3pt gap could collapse into the session's 16pt gap (the body now establishes a flow root).

Browser-measured coordinates match frames.txt: traffic lights (19/42/65,19), New Session (206,8.5,32.5,34), Toggle (250,9.5,32.5,32), tab host (300,8,…,36), first heading (8,54,276,29), first pane (8,83,276,32). Windowed collapsed Toggle/tabs x=142/184; fullscreen collapsed x=56/98. Docked has no border pseudo-element; floating retains its 18pt outline below the 52pt band in fullscreen. CSS 0.5pt borders are one physical pixel at native 2× backing scale; a 1× browser can round them to a full CSS pixel. Exact native rasterization/material equivalence is not claimed.

## Limitations

- Font metrics, SF Symbols and color management cannot be exactly reproduced by HTML; compare against the real app for final visual decisions.
- `started` is nullable; retained completion runtime requires an end timestamp/duration.
- `tail` is generic display text, not a distinct set_status field.
- No pi/Claude provider field or separate monitor kind; `run` is an opaque id, so bash runs and stream monitors look alike.
- Independent subtree folding is not implemented; sessions are plain labels.
