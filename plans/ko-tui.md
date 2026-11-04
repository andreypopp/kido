# ko_tui: a tmux-like terminal client

Status: plan (2026-11-04). Unit 1 is built: `ko_tui/src/keys.rs` with
the prefix, the help overlay, the prompts and the chooser, the status
line and the unit-1 bindings; the chords and the warning row are gone
(docs/design-ko.md 4.11). The `Repeat` state moved to unit 3, with
the first repeatable binding. Unit 2 is built: `ko_tui/src/geometry.rs`, one
mirror for each visible pane, the server's sizing gate and the hello's
client kind removed (docs/design-ko.md 4.5 and 4.11). A zoomed window's
zoomed pane is the active one, as in Kido.app. The neighbour function
and the divider hit test of section 6.2 move to units 3 and 4, with
their first callers. Unit 3 is built: the `Repeat` state and
`Keys::deadline`, the pane commands (`%` `"` `z` `o` `;`, directional
select, the resize keys, `{` `}` `E`) and `geometry::neighbour`
(docs/design-ko.md 4.11). `C-a l` selects the right neighbour (section
12), so the last window is `C-a Tab`. Unit 4 is built: resize mode
(`C-a R`) and the divider drag with `geometry::divider`
(docs/design-ko.md 4.11). Unit 5 is built: copy mode in `ko_tui/src/copy.rs`, the
freeze and resync in `ko_tui/src/mirror.rs`, and the viewport,
wrap and selection-text calls of ko_vt
(docs/design-ko.md 4.11). The client refuses copy mode while a mirror
restores a snapshot or holds synchronized output.

The terminal client `ko` (`ko_tui/`) shows one pane at a time, lists
the panes in a sidebar and takes Ctrl+Shift chords under the kitty
keyboard protocol. This arc turns it into a tmux-like client of the
same server: a `C-a` prefix, the window's splits, zoom, floats, a
status line, a copy mode and a resize mode. Kido.app and ko_tui then
show the same layout document in two ways.

## 1. What this plan supersedes

The user's direction reverses these decisions. The manager of the
first unit updates each place; the code of the first unit removes the
chords.

- docs/design-ko.md:38-39, goal 7 "a thin terminal client: one pane
  at a time, a list grouped by session", and docs/design-ko.md:47,
  the non-goal "Copy mode, splits, tabs or windows in the terminal
  client".
- docs/design-ko.md:406-446, section 4.11: one pane at a time, the
  clip or pad of a split pane, Ctrl+Shift chords, the kitty
  requirement, the warning row and "no prefix key fallback (decided
  2026-10-30)".
- docs/design-ko.md:604-606 and 616-617, the decisions of
  2026-10-30: "The terminal client shows one pane at a time ... never
  splits, tabs or windows" and "A terminal without extended keys gets
  no chords and no prefix fallback". A new dated decision records the
  reversal; the old lines stay as history of the decision list.
- docs/protocol.md:261-263: "A terminal client claims only a window
  with one leaf and no floats; a pane in a split keeps its leaf size
  and the terminal client clips or pads it." The terminal client
  becomes a sizing client like Kido.app (section 7 below).
- ko_server/src/state.rs:1527-1535 `sizable`, the gate that refuses a
  terminal client's size for a window with splits or floats, and
  ko_server/src/layout.rs:61-63 `Window::single`, its one user.
- README.md:39-54, the key table and "The terminal client shows no
  splits, tabs or windows and has no copy mode".
- docs/design.md:717-719 (`Ctrl+Shift+Up` and `Down` walk the list),
  docs/design-runtimes.md:106-109 (`Ctrl+Shift+N` inherits the
  runtime), AGENTS.md:579-592 ("the shown view", "the compressor
  thread" in the singular).
- The code: `Command` and `command` in ko_tui/src/input.rs:164-194,
  `Client::key` in ko_tui/src/client.rs:691-730, `Panel::Choosing`
  and `warning` in ko_tui/src/client.rs:57-70 and 304, the
  warning row of ko_tui/src/renderer.rs:168-176, `probe`'s kitty
  verdict in ko_tui/src/client.rs:210-273 as a requirement (the push
  of kitty flag 1 stays, for the panes), and the e2e helpers
  `chord`, `CHORD_UP` and `CHORD_DOWN` in ko_e2e/tests/e2e/outer.rs:26-27
  and 412-414 with the tests of ko_e2e/tests/e2e/client.rs that use
  them, among them `client_attach_or_start_and_warning` (442) and
  `client_warning_mouse_bounds` (757).

`Ctrl+D` on a dead pane (ko_tui/src/input.rs:181,
ko_tui/src/sidebar.rs:55) stays: a dead pane takes no input, so the
key needs no prefix.

## 2. Goals and non-goals

Goals:

1. A `C-a` prefix, not configurable. `C-a C-a` sends `C-a` to the
   pane. A plain terminal without the kitty keyboard protocol gets
   every key.
2. The shown window with its splits, dividers, zoom and floats, as
   Kido.app shows it, from the same layout document and the same
   `Edit` operations (ko_client/src/edit.rs:22-116).
3. tmux's default bindings under `C-a`, with a documented difference
   where ko has no equivalent or a better one (section 4).
4. A copy mode with vi keys over the pane's whole history, with
   search, selection and copy to the outer terminal's clipboard.
5. A resize mode: arrows or `hjkl` resize the active pane until
   `Enter` or `Escape`.
6. A status line in tmux's shape, which also shows the pending
   prefix and the active mode.
7. Zero configuration. Nothing of this plan reads a file.

Non-goals:

- A command prompt (`C-a :`), a command language, hooks, key tables
  or any tmux file. docs/design-ko.md, "Non-goals", keeps
  "Compatibility with any multiplexer's clients, commands,
  configuration files, plugins, hooks or key tables".
- Preset layouts (`M-1` to `M-7`, `Space`), pane marks (`m`, `M`),
  pane titles (`T`), the clock (`t`), the information popups (`i`,
  `~`, `q`), window index prompts (`'`, `.`), the fuzzy chooser
  (tmux's `Tab`; ko's `C-a Tab` is the last window), buffer lists (`#`, `-`, `=`), activity markers (`M-n`,
  `M-p`), rotate (`C-o`, `M-o`), detach another client (`D`:
  protocol.md section 3, no route moves another client), suspend
  (`C-z`: a signal to the own pid, which ko_sys::pid refuses).
- Server-side paste buffers. The copy buffer is one buffer in the
  client process (section 8).
- Emacs copy-mode keys (section 8 gives the reason).
- Float creation by drag, float move keys (`g`): a float is created,
  focused, read and removed; its geometry changes through Kido.app or
  `ko layout edit`.

## 3. What ko_tui is today, and what carries over

ko_tui/src/client.rs:73-93 holds one `View` (one pane, one
`Mirror`, one `Frame`), and `Client` (client.rs:287-330) a `Panel`
for the sidebar and the loop over
stdin, the `/client` link, the view's link and the signal pipe. Every
pane's row and the layout `Snapshot` are in `ko_client::Model`
(ko_client/src/model.rs:51-59); its `outline` and `order`
(model.rs:433-495) give the sidebar's rows. A `Mirror`
(ko_tui/src/mirror.rs:176-200) opens one view with `History::All`,
mirrors it in a `ko_vt::Terminal` under a `Mutex` and runs the
scrollback compressor on its own thread. The renderer
(ko_tui/src/renderer.rs:195-280) composes one cell grid from the
sidebar and the one frame and writes it through the differ, at most
once per 8 ms, inside synchronized output. Input is vte tokens turned
into `KeyEvent`s (ko_tui/src/input.rs:94-127); `Client::key` routes
them. The layout edits of the client go through
`ko_client::layout::add_session` and `add_window`
(ko_client/src/layout.rs:217-243), which run `edit_from` with the
`409` retry (layout.rs:129-149). Kido.app sends every gesture as one
`Edit` through `ko_client_edit` (ko_client/src/ffi/calls.rs:225-256),
which calls the same `edit_from`.

Everything above carries over. The changes are: several mirrors at
once, a pure key state machine in front of `Client::key`, a geometry
module for the window's rectangles, a copy-mode state over one
mirror, and the status line.

## 4. The keybinding table

The prefix is `C-a`. "tmux" is tmux's default binding under its
`C-b`; the column "differs" says where ko's action is not tmux's and
why. A repeatable binding (tmux's `bind -r`) is marked `r`: after it,
the next key of a repeatable binding acts without the prefix for
500 ms (tmux's `repeat-time`). The user reviews this table later.

### Prefix and client

| key | tmux | ko action | differs |
|---|---|---|---|
| `C-a C-a` | send prefix | send `C-a` to the active pane | |
| `C-a d` | detach | detach | |
| `C-a r` | redraw | redraw: invalidate the differ and the modes | |
| `C-a ?` | list keys | show this table as an overlay in the pane area; any key closes it | |
| `C-a (` / `)` | previous/next session | `ClientRequest::Switch` over sessions | |
| `C-a L` | last session | select the session the client showed before | |
| `C-a s` | choose session | the sidebar chooser: the list takes `Up`, `Down`, `Enter`, `Escape` (today's `Panel::Choosing`) | ko's list is one tree of sessions and panes |
| `C-a w` | choose window | the same chooser | as above |
| `C-a $` | rename session | a prompt in the status line; `Edit::RenameSession` | |
| `C-a C-s` | unbound | show or hide the sidebar | ko only (the user's choice) |
| `C-a e` | unbound | open the active pane's scrollback in `$PAGER` | ko only; today's `Ctrl+Shift+E` |

### Windows

| key | tmux | ko action | differs |
|---|---|---|---|
| `C-a c` | new window | `Edit::AddWindow` after the shown window, the new pane inherits the active pane's runtime (design-runtimes.md, "A new pane inherits") | |
| `C-a &` | kill window | status-line prompt `kill-window NAME? (y/n)`; `DELETE /windows/{id}` | |
| `C-a ,` | rename window | status-line prompt; `Edit::RenameWindow` | |
| `C-a n` / `p` | next/previous window | `ClientRequest::Switch` over windows (document order, wraps) | |
| `C-a l` | last window | select the pane on the right (section 12) | the user's choice |
| `C-a Tab` | unbound | select the window the client showed before, in the same session | the user's choice, as `l` selects a pane |
| `C-a 0` to `9` | select window 0 to 9 | the window at that position in the current session, from 0 as tmux's `base-index` | |
| `C-a !` | break pane | a new `Edit::BreakPane { pane }` (section 6.4): the pane becomes a new window after the current one | a new edit, which Kido.app may use later |

### Panes

| key | tmux | ko action | differs |
|---|---|---|---|
| `C-a %` | split left/right | `Edit::Split { axis: Horizontal, before: false }` of the active pane; the new pane is selected, as in Kido.app | |
| `C-a "` | split top/bottom | the same with `Axis::Vertical` | |
| `C-a x` | kill pane | prompt `kill-pane? (y/n)`; `DELETE /panes/{id}` | |
| `C-a z` | toggle zoom | `Edit::ToggleZoom` | |
| `C-a o` | next pane | select the next pane of the window in document order, floats after the tree, wraps | |
| `C-a ;` | last pane | select the pane the client showed before in this window | |
| `C-a Up/Down/Left/Right` (r) | select pane in direction | the neighbour across the divider on that side (section 6.2) | |
| `C-a C-Up/Down/Left/Right` (r) | resize by 1 | `Edit::ResizeBy { edge, delta: 1 }`; unzooms first, as in Kido.app | |
| `C-a M-Up/Down/Left/Right` (r) | resize by 5 | `Edit::ResizeBy { edge, delta: 5 }` | |
| `C-a {` / `}` | swap with previous/next | `Edit::Swap` with the previous/next pane in document order | |
| `C-a E` | spread panes evenly | `Edit::Equalize { pane: active }` | |
| `C-a *` | create a floating pane | toggle: a tiled active pane becomes a float (`Edit::Float`, default geometry); a float docks back beside the window's focus (`Edit::Unfloat`) | tmux creates a new float; ko floats the existing pane |
| `C-a R` | unbound | enter resize mode (section 5.3) | ko only |
| `Ctrl+D` on a dead pane | | remove it (`DELETE /panes/{id}`), no prefix | ko only; exists today |

### Copy mode

| key | tmux | ko action | differs |
|---|---|---|---|
| `C-a [` | copy mode | enter copy mode on the active pane | |
| `C-a PageUp` | copy mode, one page up | the same, then one page up | |
| `C-a ]` | paste buffer | paste the client's buffer into the active pane as a `Paste` input | one buffer in the client, not a server buffer |

The keys inside copy mode and resize mode are in section 5.

Mouse, always on (tmux's `mouse` is off by default; ko's is on today):

| gesture | ko action |
|---|---|
| click a sidebar row | select that pane (as today) |
| click in a pane | select that pane; the press also goes to the pane when it tracks the mouse |
| drag a divider | `Edit::ResizePair` with the two panes beside it, as Kido.app's divider drag |
| wheel over a pane | scroll that pane's mirror; the pane gets the wheel when it tracks the mouse (as today for the shown pane) |
| click, drag, double click in copy mode | place the cursor, select, select a word (section 5.4) |

Removed bindings: `Ctrl+Shift+S`, `E`, `N`, `Q`, `Up`, `Down`. The
kitty keyboard requirement goes with them: a terminal that does not
confirm extended keys gets no warning row and the same bindings,
because `C-a` arrives as byte `0x01`, which `control_key`
(ko_tui/src/input.rs:430-438) already decodes as `Char('a')` with
`CTRL`, the same `KeyEvent` as kitty's `CSI 97;5u`.

Nesting: inside a tmux with its default `C-b` nothing conflicts.
Inside another ko_tui, or a tmux with `C-a`, the outer takes `C-a`
and `C-a C-a` sends one `C-a` to the inner, so the inner's prefix is
`C-a C-a`. This is tmux's own nesting story and needs no code.

## 5. The key state machine

`ko_tui/src/keys.rs` (built in unit 1) is the pure state machine:
`Keys::feed` turns a key into a key for the pane, an action or
nothing, and the client matches on the result. The state machine knows
nothing of the layout, so a unit test drives it with key sequences.
Unit 3 adds the `Repeat` state and `Keys::deadline(&self) ->
Option<Instant>`, the repeat deadline, which `Client::turn` arms as a
`Deadline` like the escape timer.

States:

- `Normal`. `C-a` press goes to `Prefix`. Every other key is
  `Pane(key)`. A `Ctrl+D` press while the active pane is dead is
  `Act(Remove)`: `Client` tells `Keys` the dead flag with the event,
  as `Client::key` does today (client.rs:695-700).
- `Prefix`. tmux has no timeout for the prefix, and neither does ko:
  the status line shows `C-a` until a key arrives. `C-a` is
  `Pane(C-a)`. A bound key is `Act`. A repeatable key is `Act` and
  goes to `Repeat`. An unbound key is `Swallow`, as tmux discards it.
  A release event (kitty flag 2 is never pushed, so these are rare)
  is `Swallow`. Then `Normal`.
- `Repeat { until }`. A key of a repeatable binding, without the
  prefix, is `Act` and resets `until` to `now + 500 ms`. `C-a` goes
  to `Prefix`. Any other key, or the deadline, goes to `Normal`, and
  the key is handled as in `Normal`.
- `Resize` (section 5.3) and `Copy` (section 5.4) are modes with
  their own tables. In both, `C-a` leaves the mode and goes to
  `Prefix`, so `C-a d` works inside a mode.
- `Prompt { kind, text }` (rename, kill confirmations): printable
  keys edit the text, `Enter` is `Act(kind(text))`, `Escape` cancels,
  `Backspace` deletes. The status line shows the prompt.
- `Chooser` is the sidebar list's `Up`, `Down`, `Enter`, `Escape`
  (today's `Panel::Choosing` in client.rs:732-759), moved into
  `Keys` so one place owns every mode.

Release events: a release whose press was consumed is `Swallow`, as
`Client::key` does today (client.rs:707-711). `Kind::Repeat` counts
as a press.

### 5.3 Resize mode

`C-a R` enters it. The status line shows `[resize]`, and the active
pane's dividers turn yellow (colour 3) instead of green. Keys:

| key | action |
|---|---|
| `h` `j` `k` `l`, arrows | `Edit::ResizeBy` toward that edge by 1 |
| `H` `J` `K` `L`, Shift+arrows | by 5 |
| `=` | `Edit::Equalize` |
| `z` | `Edit::ToggleZoom` |
| `Enter`, `Escape`, `q` | leave the mode |
| `C-a` | leave the mode, then `Prefix` |
| other | `Swallow` |

A resize while zoomed unzooms first, which `Edit::ResizeBy` does
(edit.rs:30-32). Each key is one `Edit`, sent at once; a conflict
retries on the newer document (layout.rs:129-149), so two fast keys
are two steps, as in Kido.app (design-app.md:1017-1022). The mode
ends also when the active pane leaves the window.

### 5.4 Copy mode

`C-a [` enters it on the active pane; `C-a PageUp` enters and pages
up. The status line shows `[copy]`; the pane's top right shows
`[offset/history]` in yellow, as tmux does. Only one pane is in copy
mode at a time; another pane's selection leaves it.

Keys are vi's. tmux's default is emacs unless `VISUAL` or `EDITOR`
contains `vi`. ko fixes vi because: Kido.app's copy mode is vi
(`v`, `V`, `y`, `/`, `?`, `n`, `N`, `hjkl`; design-app.md:551-580),
so one vocabulary serves both clients; the emacs table needs `C-Space`
and `M-w`, which many terminals do not deliver; and reading `EDITOR`
is configuration by environment, against the zero-config goal.

| function | key |
|---|---|
| cursor | `h` `j` `k` `l`, arrows |
| word | `w` `b` `e`, `W` `B` `E` |
| line | `0` start, `^` first non-blank, `$` end |
| screen | `H` top, `M` middle, `L` bottom |
| history | `g` top, `G` bottom |
| page | `C-b` `PageUp` up, `C-f` `PageDown` down, `C-u` `C-d` half |
| scroll | `C-y` up one line, `C-e` down one line |
| jump in line | `f` `F` `t` `T` with a character, `;` again, `,` reverse |
| selection | `Space` or `v` begin, `V` line, `C-v` rectangle toggle, `o` other end, `Escape` clear |
| copy | `Enter` (tmux), `y` (Kido.app): copy the selection, leave the mode |
| search | `/` forward, `?` backward, with a status-line prompt; `n` again, `N` reverse |
| leave | `q`, or `Escape` with no selection |
| `C-a` | leave, then `Prefix` |

Differences from tmux: `v` begins a selection (tmux's vi `v` toggles
rectangle; Kido.app and vim use `v` to begin), so rectangle is
`C-v` as in vim; `y` copies, which tmux's default table lacks.

Mouse in copy mode: a click places the cursor, a drag selects, a
double click selects the word, a triple click the line, the wheel
scrolls; no mouse event reaches the pane, as in Kido.app
(design-app.md:564-566).

**Freezing.** On entry the mirror stops applying the view's bytes: the
link is still read, so the server's backpressure does not build, and
the bytes are dropped with a `dirty` flag, as Kido.app's frozen feed
does (design-app.md:475-478). On exit a dirty mirror sends
`ViewRequest::Resync` and loads a snapshot. The history does not
move under the cursor, and the position indicator is exact.

**Coordinates.** The cursor is `(col, history_row)` where
`history_row` counts from the top of the mirror's history, the row
space of `ko_vt::Terminal::total_rows` (ko_vt/src/lib.rs:1014) and
of `Search::matches` (ko_vt/src/search.rs:72-74). The viewport's
first row is the scrollbar offset that `scrollbar` reads
(lib.rs:895-902), which becomes `pub fn viewport_offset`. The frame's
cell `(x, y)` is history row `offset + y`. Moving the cursor off the
viewport scrolls with `Terminal::scroll` (lib.rs:885); `g` needs
`scroll_top`, a new sibling of `bottom` (lib.rs:903) with
`GHOSTTY_SCROLL_VIEWPORT_TOP`.

**Selection text.** A new `Terminal::text_between(start, end,
rectangle: bool) -> Result<Vec<u8>, Error>` in ko_vt builds a
`GhosttySelection` over two `GHOSTTY_POINT_TAG_SCREEN` points and runs
the plain formatter, as `format` does for the whole extent
(lib.rs:1107-1170). The copy goes to the outer terminal as OSC 52
through `clipboard::write` (ko_tui/src/clipboard.rs:8), the path that
already forwards a pane's clipboard writes, and into the client's one
paste buffer. `C-a ]` sends the buffer as `Wire::Paste` with
`check_safe: false`, as a bracketed paste from the outer terminal does
today (client.rs:813-819).

**Search.** Local, on the mirror, with `Terminal::search`
(ko_vt/src/search.rs:23-44), not the server's `/panes/{id}/search`.
Reasons: the mirror holds the whole history (`History::All`,
mirror.rs:20-23) and is frozen, so its rows are stable; protocol.md
section 11 itself says "a client jumps to a match by taking a full
snapshot and searching its mirror, since server rows move with
output"; and Kido.app searches its mirror. `Search::step` runs in
bounded ticks on the mirror's compressor thread, which already owns
the terminal's CPU work under the `Mutex`, and publishes the match
list into the shared `State`; the loop reads it with the frame. The
matches are highlighted in yellow; the selected match is the cursor.

## 6. Rendering

### 6.1 Regions

The screen is: an optional sidebar on the left (today's width 24
plus a bar, ko_tui/src/sidebar.rs:8 and 24), the pane area, and one
status line at the bottom, full width. The pane area is `cols -
sidebar` by `rows - 1`. That is the size the client sends in its
`Hello` and `Size` (client.rs:1282-1294 `pane_size`), with the outer
tty's `cell_px` as today.

The status line has tmux's default shape and colours (green
background, black text): `[session] 0:name 1:name* 2:name-` on the
left, where `*` marks the shown window and `-` the last one, and on
the right the pending prefix `C-a`, the mode (`[copy]`, `[resize]`),
a prompt, or the reconnect notice (`reconnecting to HOST` today in
client.rs:437-441). It replaces the warning row.

### 6.2 Geometry

A new module `ko_tui/src/geometry.rs` walks a `Window` of the model
(`ko_server::protocol::Window`, protocol.rs:894-907) into rectangles:
one `Rect { x, y, cols, rows }` for each leaf and each float, and one
for each divider. The document reserves one cell between the
children of a split (ko_server/src/layout.rs:318-319: `dividers =
count - 1`, `room = total - dividers`), so the offsets along a split's
axis are the children's sizes plus one. A horizontal split's divider
is a column `│` over the split's rows; a vertical split's is a row
`─` over its columns; where a divider meets another, the cell gets
the junction glyph (`├` `┤` `┬` `┴` `┼`). A zoomed window
(`Window::zoom`) has one rectangle, the whole window, for the zoomed
pane, as `pane_sizes` gives it (protocol.rs:1198-1202). A float is
its own `Float` record's `x`, `y`, `cols`, `rows`, drawn after the
tree in `z` order with a one-cell border when `border` is set, and
its `title` in the border's top row.

The neighbour of a pane in a direction (for `C-a Up` and friends) is
the rectangle across the divider on that side whose span overlaps the
active pane's cursor column or row; without one, the rectangle with
the largest overlap. Floats are not neighbours. The divider under a
mouse position, with the two leaves beside it, is the same module's
hit test, which gives `Edit::ResizePair { first, second, first_size
}` its arguments. The module is pure and has proptest tests: every
leaf once, no two rectangles overlap, every cell of the window is a
pane cell or a divider cell.

Kido.app computes its rectangles in Swift
(app/Packages/PaneGeometry/Sources/PaneGeometry/PaneLayout.swift) and
keeps them; the module has one user, so it is in ko_tui, not in
ko_client ("Do not abstract something with one use").

### 6.3 Composition

`View::Showing` becomes `Shown { window: WindowId, panes:
Vec<ShownPane> }`, with one `Mirror` and one `Frame` for each visible
pane: the leaves and floats of the shown window, or only the zoomed
pane while zoomed. A pane that leaves the visible set (another window
is selected, a zoom hides it, it is removed) closes its mirror; one
that enters opens a mirror, which loads a snapshot. Only visible panes
have views, as today one pane has: a view costs the server a write
for each output record, and a snapshot of 100k lines decodes in under
ten milliseconds (design-ko.md, "Performance"). Hidden windows have no
views; their sidebar marks come from the rows of the model.

`Renderer::paint` takes the layout, the geometry and `&[(serial,
&Frame, Rect)]`. For each pane it copies the frame's cells into the
rectangle, clipped at the rectangle; a frame smaller than the
rectangle leaves blank cells (section 7). The active pane's dividers
are green (colour 2), the others default, as tmux's
`pane-active-border-style`. A dead pane's line (`sidebar::dead_line`)
is the last row of its rectangle, as it is the last row of the pane
area today. The cursor is the active pane's cursor, moved by its
rectangle's origin, and hidden when the active pane is dead, in copy
mode (the copy cursor is drawn as an inverse cell), or outside its
rectangle. The outer terminal's mouse and keyboard modes
(`Modes::apply`, ko_tui/src/modes.rs) follow the active pane's frame.

A frame is fetched only when its mirror's generation changed
(`Mirror::frame`, mirror.rs:492-508), so a quiet split costs nothing
in a paint. The paint pace stays 8 ms for output and immediate for
input. The differ writes only the changed cells, so a split that
scrolls does not repaint its neighbours.

Each `Mirror` keeps its compressor thread. With N visible panes there
are N such threads, each idle except after output. This keeps
mirror.rs as it is; one shared thread would save nothing measurable
for the N of a terminal (under ten). AGENTS.md's "except for the
terminal client's mirror compressor" becomes plural.

The `C-a ?` help overlay and the chooser draw in the pane area over
the panes, from one cell grid, and need no new drawing path.

### 6.4 Edits

Every layout command is one `Edit` through a new
`Client::edit(&mut self, edit: Edit) -> Result<Edited, String>`, which
calls `ko_client::layout::edit` (layout.rs:151-156) with the client's
id, as `ko layout edit` does. The edit blocks with the deadlines of
`ko api`, as the client's create and delete requests do today
(AGENTS.md, "The terminal client"). The layout event that follows
redraws the window. After a split the new pane is selected; after a
zoom, the zoomed pane; as Kido.app does (design-app.md:1025-1027).

`Edit::BreakPane { pane }` is new in ko_client/src/edit.rs: it
detaches the leaf with `take` (edit.rs:447) and appends a window with
that leaf as its tree after the pane's window. The server names the
new window after the moved pane's old window (protocol.md section 7).
The edit is shared, so Kido.app may bind it later; `make schemas`
regenerates the schema files.

The float toggle `C-a *` floats the active tiled pane with
`Edit::Float` at a default geometry (centred, half the window) and
docks a float back with `Edit::Unfloat { target: window.focus, edge:
Right }`.

## 7. Focus, selection and sizing with Kido.app

**Selection is per client.** The active pane of ko_tui is the
client's current pane in the server (protocol.md section 3). A select
sends `ClientRequest::Select` and the server answers `selected`
(client.rs:1208-1218 handles it today). Kido.app's active pane is its
own selection. A focused client's select also sets the window's
read-only `focus` (ko_server/src/state.rs:675-688 `note_focus`), which
Kido.app reads only when it enters a window where it has no current
pane (design-app.md:1395-1397). So a selection in ko_tui never moves
what Kido.app shows, and the reverse holds. Nothing changes here.

**The document is shared.** A split, a kill, a swap, a float and a
zoom are document changes, visible in every client at once. Zoom is
per window, as tmux's is, so zooming in ko_tui zooms the window in
Kido.app. This is the existing design of the one layout document
(design-ko.md 4.5), and tmux's behaviour for two clients of one
window.

**Sizing.** The window that a client shows is sized by the client
that claims it: the one whose terminal has focus, else the one that
last switched to it (ko_server/src/client.rs:65-77 `claims`). ko_tui
becomes a full sizing client: `sizable` (state.rs:1527-1535) and
`Window::single` go, and with them `ClientKind`, which nothing else
read. When ko_tui is the sizer, the window is exactly
its pane area and the server rescales the tree (layout.rs normalize).
When it is not, ko_tui draws the window at the server's geometry,
anchored top left, clipped where the window is larger and blank where
it is smaller, as it clips or pads one leaf today
(renderer.rs:224-245), and as Kido.app clips during a stale-root
shrink (design-app.md:945). A resize of the outer terminal sends one
`Size`, the pane area; ko_tui never sends a leaf's size. Dividers are
moved by edits, not by sizes.

The `Hello` of a reconnect (`reconnect` and `restore`,
client.rs:1127-1176, and `hello`, client.rs:1253) carries the
shown window, not a pane, when the client shows a window; its current
pane is the one the server chooses from `focus` or the one the client
names.

## 8. Mouse

`Client::mouse` (ko_tui/src/client.rs:761-800) routes a mouse event to the sidebar or
the shown pane. It becomes: sidebar rows as today; a divider under the
press starts a drag that sends `Edit::ResizePair` on each motion
event with a new position, latest step only, as Kido.app's drag does
(design-app.md:1010-1011), and ends on release; a press in a pane
selects it when it is not the active pane, and the press, drags and
release go to that pane when its frame's `mouse` is on
(`MouseTracking`, as today); the wheel scrolls the mirror under the
pointer, or goes to the pane when it tracks the mouse. The outer
terminal's mouse reporting stays on while a pane is shown (decided
2026-10-30; unchanged). `input::mouse` (input.rs:311-327) takes the
pane's origin instead of `pane_x`.

## 9. Configuration

None. The defaults are this plan's. If a `tui:` key ever enters the
configuration file of plans/app-config.md, the candidates are the
prefix key, the status line (on or off), the sidebar's width and
default visibility, and the copy-mode key table. None is planned;
the user asked for zero configuration.

## 10. Tests

Unit tests (`#[cfg(test)] mod tests` in each file):

- `keys.rs`: sequences and their `Step`s. `C-a C-a` gives
  `Pane(C-a)`; `C-a d` gives `Act(Detach)`; an unbound key after the
  prefix is swallowed; `C-a Up Up Up` within 500 ms gives three
  `Act(SelectPane(Up))` and a fourth after the deadline goes to the
  pane; `C-a Up` then `x` sends `x` to the pane; `C-a R` then `h` `h`
  `Enter` gives two resizes then `Normal`; `C-a` inside copy mode
  leaves it and `d` detaches; a release after a consumed press is
  swallowed; a prompt collects text and `Escape` cancels. A legacy
  `0x01` and a kitty `CSI 97;5u` give the same steps.
- `geometry.rs`: rectangles of `h[1:40x24 v[2:39x12 3:39x11]]` in
  80x24 are pane 1 at (0,0) 40x24, a divider column at x=40, pane 2 at
  (41,0) 39x12, a divider row at y=12 from x=41, pane 3 at (41,13)
  39x11, and the junction at (40,12) is `├`. Neighbours: `Right` of
  pane 1 with the cursor at row 3 is pane 2, at row 20 is pane 3. A
  zoomed window gives one rectangle. Floats overlap and are not
  neighbours. The divider hit test names the two leaves. Proptest:
  every leaf once, no overlap, every cell covered.
- copy mode (`copy.rs`): a pure `Copy` state over `(cols, total_rows,
  offset)`: `w` and `b` over a row's text, `V` selects the row,
  `C-v` makes a rectangle, `o` swaps the ends, `G` and `g` move the
  offset, the indicator text is `[offset/history]`.
- `renderer.rs`: the status line's text and the mode field; the
  active pane's divider cells are green and the others default; a
  frame smaller than its rectangle leaves blanks; a float covers the
  tree and draws its border and title.
- `edit.rs`: `BreakPane` moves the leaf into a new window after the
  old one, keeps the old window's other leaves, and is refused for a
  window's only pane.

e2e (`ko_e2e/tests/e2e/client.rs`, through `Outer`,
ko_e2e/tests/e2e/outer.rs:103-215): `chord` becomes `prefix(key)`,
which sends `0x01` then the key, and the tests that use `CHORD_UP` and
`CHORD_DOWN` use `prefix` with arrows. New tests, one server each,
several cases in one test where the setup is shared:

- `client_prefix_passes_through_and_works_without_extended_keys`:
  with `Keys::Unconfirmed`, `C-a C-a` reaches a pane that echoes its
  input as hex (the `SELECTS_THEN_ECHOES_INPUT` fixture,
  client.rs:747-754) as `01`; `C-a d` detaches; no warning row.
- `client_splits_zoom_and_directional_select`: `C-a %` then `C-a "`
  give the three-pane tree in `s.doc()`; the screen has `│` at the
  divider column and `─` on the divider row and `├` at their meet;
  `C-a Left` and `C-a Right` move the active pane, seen by the input
  that reaches each pane's fixture; `C-a z` zooms (the document's
  `zoom`, the dividers gone), `C-a z` unzooms.
- `client_resize_mode_and_repeat`: `C-a R`, `h` three times, `Enter`
  move the divider by three in `s.doc()`; `C-a C-Left C-Left` moves
  it by two without a second prefix; `C-a M-Left` by five.
- `client_copy_mode_copies_and_pastes`: a pane prints known lines;
  `C-a [`, `k`, `V`, `y` put the line into `o.clipboard()` (the
  outer terminal's OSC 52, outer.rs:308); `C-a ]` pastes it into the
  echo fixture; `?` with a needle and `Enter` moves the indicator to
  the match's row; output during copy mode does not move the cursor
  and appears after `q`.
- `client_two_clients_one_window_and_the_sizer`: two `Outer`s of
  different sizes show one split window; the smaller focused one
  sizes it (`s.doc()` cols and rows) and the larger shows it clipped
  with its dividers at the server's columns; after the smaller
  detaches, the larger's next select claims the window.
- `client_status_line_windows_and_prompts`: `C-a c` adds a window
  marked `*` and the old one `-`; `C-a 0` and `C-a 1` select by
  position; `C-a ,` with a name renames it in `s.doc()`; `C-a &`
  then `y` deletes it; `C-a x` then `n` keeps the pane.
- `client_float_toggle_and_break_pane`: `C-a *` makes the active pane
  a float in `s.doc()` and the screen shows its border; `C-a *`
  docks it; `C-a !` moves it into a new window.
- `client_mouse_selects_a_pane_and_drags_a_divider`: a click in the
  second pane makes it active (the next typed key reaches its
  fixture); a press on the divider, a motion and a release move it in
  `s.doc()`.

Every wait is `o.wait` or `o.contains` with the harness's deadline. A
fixture that echoes its input shows which pane is active; no test
reads the client's private state.

## 11. Units, estimates and order

Each unit is one manager, one implementer and the reviewers of
AGENTS.md, in one worktree, in this order. Estimates are agent-days
for the implementer, with review.

1. **The prefix and the status line** (2 days). `keys.rs` with the
   `Prefix`, `Prompt` and `Chooser` states; the status
   line; the bindings that need no splits: detach, redraw, help
   overlay, sidebar toggle and chooser, pager, new window, next and
   previous window and session, `0` to `9`, last window and session,
   rename and kill prompts, `Ctrl+D`. Removal of the Ctrl+Shift
   chords, the warning row and the kitty requirement. The e2e tests
   move to `prefix`. Docs: README, design-ko.md 4.11 and 7, design.md,
   design-runtimes.md, AGENTS.md.
2. **The window: geometry and several mirrors** (3 days).
   `geometry.rs`; `Shown` with one mirror for each visible pane;
   dividers, the active border, dead lines, the cursor and modes of
   the active pane; floats and zoom drawn from the document; input to
   the active pane; mouse click to select and wheel for each pane;
   the server's `sizable` gate removed with the protocol.md and
   design-ko.md text; the clip-or-pad rule for a non-sizing client;
   the reconnect hello with a window. Docs: protocol.md section 3,
   design-ko.md 4.5 and 4.11.
3. **Pane and window commands** (2 days). The `Repeat` state of
   `keys.rs` and `Keys::deadline`, with the first repeatable
   bindings: directional select (arrows, `h/j/k/l`, `C-h/j/k/l`) and
   the resize keys. Split, zoom, `o`,
   `;`, directional select, resize keys with repeat, swap, equalize;
   `Client::edit`; selection after a split and a zoom.
4. **Resize mode and divider drag** (1 day). The `Resize` state and
   its table; `Edit::ResizePair` from a divider drag.
5. **Copy mode** (3 days). Freeze and resync; `copy.rs`; the ko_vt
   additions `viewport_offset`, `scroll_top` and `text_between`;
   movement, selection, copy by OSC 52, the paste buffer and `C-a ]`;
   `C-a PageUp`; the position indicator; mouse in copy mode.
6. **Copy-mode search** (1 day). `/`, `?`, `n`, `N` on the mirror's
   `Search`, stepped on the compressor thread; highlights.
7. **Floats and break-pane** (1.5 days). `C-a *` with `Edit::Float`
   and `Edit::Unfloat`; `Edit::BreakPane` with its schema; `C-a !`.

Total: 13.5 agent-days. Units 5 and 6 can run in parallel with 3 and
4 after unit 2, in their own worktrees, because they touch `copy.rs`,
`mirror.rs` and ko_vt, not `geometry.rs` or the edits.

## 12. Open questions (decided)

The user accepted every recommendation below on 2026-11-04. The user also decided that
`C-a C-h`, `C-a C-j`, `C-a C-k` and `C-a C-l` move between the panes of
a window (left, down, up, right; no wrap), repeatable within 500 ms
like the arrows, and `C-a h/j/k/l` do the same. Without the prefix the
four keys go to the program.


Each with a recommendation. The user decides.

1. **Window numbers from 0 or 1?** tmux's `base-index` is 0; the
   sidebar numbers panes from 1 (sidebar.rs:81-99). Recommendation:
   0, as the user asked for tmux's defaults, and show the number in
   the status line so the key and the label agree.
2. **A status line always?** tmux shows one by default and has no
   default key to hide it. Recommendation: always on, no key; it
   carries the prefix indicator and the modes, which have no other
   place when the sidebar is hidden.
3. **Should the prefix indicator show?** tmux shows nothing by
   default while the prefix is pending. Recommendation: show `C-a`
   in the status line; it costs one word and makes a stuck prefix
   visible, and tmux users commonly configure the same.
4. **`v` begins a selection or toggles rectangle?** tmux's vi table
   has `v` as rectangle toggle and `Space` as begin. Recommendation:
   `v` begins, `C-v` toggles rectangle, `Space` also begins; this is
   vim's and Kido.app's vocabulary, and the user said "vi keys".
5. **Local or server search in copy mode?** Recommendation: local
   (section 5.4); the server's search keeps its one user, the
   harness.
6. **Views for hidden panes of the shown window while zoomed?**
   Keeping them makes unzoom instant at the cost of a view for each
   hidden pane. Recommendation: close them; a snapshot reload is
   milliseconds, and the server's write work stays proportional to
   what is on screen.
7. **One compressor thread for all mirrors or one for each?**
   Recommendation: one for each, as `Mirror` is today; the count is
   the visible panes.
8. **`C-a *` as a float toggle or as tmux's "new floating pane"?**
   Recommendation: the toggle; it reuses `Edit::Float` and
   `Edit::Unfloat`, needs no float geometry keys, and a new float is
   `C-a %` then `C-a *`.
9. **`Edit::BreakPane` in ko_client, or compose it in ko_tui from a
   `PUT`?** Recommendation: the edit, so Kido.app and `ko layout
   edit` get it; it is one function beside `take` and `beside`.
10. **Keep `C-a e` (the pager)?** Copy mode covers the history.
    Recommendation: keep it for this arc; it is built and tested and
    costs one row of the table. Remove it in a later cleanup if the
    user does not use it.
11. **Mouse on by default?** tmux's is off; ko's is on today and the
    sidebar needs it. Recommendation: on, unchanged, with the outer
    terminal's override modifier for native selection as today.
