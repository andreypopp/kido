# Native sidebar support in tmux: research notes

Date: 2026-09-16. tmux source at `~/Workspace/tmux-src` (HEAD e880cf6, 2026-09-11,
"next-3.9"). PR #5468 branch checked out at `~/Workspace/tmux-pr5468` and built
into `~/.local/tmux-side/bin/tmux`.

## Summary

- tmux has no notion of a global sidebar. Everything kido does today
  (a pane per window, hooks, self-repositioning) is an emulation forced by
  that gap.
- Upstream is adding one. Pull request tmux/tmux#5468 "Add a vertical (side)
  status line" (open, 1235 additions, rebased 2026-09-16, approved in approach by
  the maintainer, held for the 3.9 release) reserves a column at the left or
  right of every client and fills it from a format string.
- I built that branch and confirmed that kido's listing renders in it with
  colours, using `#()` command output and `#[nl]` row separators. Mouse
  clicks on it are exposed to bindings with the row number.
- What it does not give: a real interactive pane in the column. Keys cannot be
  typed into it. Navigation would be emulated with key tables and a
  selection kept in a server option.
- A fork that adds a job-backed interactive column on top of PR #5468 is
  feasible in roughly 400-700 lines, mostly in status.c and server-client.c,
  because the PR already solves geometry, redraw offsets, resize and mouse
  translation. The maintenance cost is a permanent rebase burden against a
  fast-moving codebase (screen-redraw.c was rewritten this month).

Recommendation: do not fork. Target PR #5468 as the native sidebar and add a
`kido render` mode that emits the listing as a tmux format. Keep the current
pane-based mode for full interactivity until 3.9 ships. Revisit a fork only
if the interactive column proves essential and upstream declines it.

## What tmux offers today (3.7c, the version installed)

- Panes belong to a window's layout tree. `struct window_pane` carries a
  `layout_cell`, offsets, and a back pointer to its window. Layout commands
  (select-layout, rotate-window, swap-pane) rearrange every cell; nothing
  marks a cell as pinned.
- The status line is the only chrome drawn outside the window area, and it
  is horizontal only: `status_line_size` is subtracted from the client
  height in resize.c:193-194 and 298-299, and drawing shifts y by that
  amount in screen-redraw.c:1480-1486. There is no x counterpart anywhere.
- Popups are per-client overlays (popup.c). A popup is a screen, an input
  parser and a pty job, not a window_pane. The overlay gets first refusal on
  every key (server-client.c:1775-1785) and can only answer "consumed" or
  "close"; there is no pass-through, and one overlay per client
  (server-client.c:86-87). A non-modal sidebar cannot be built on overlays
  without changing that contract.
- Floating panes arrived in 3.8 (CHANGES: "Many improvements to floating
  panes"). They are real panes with a z-order inside one window, so they get
  key tables, modes and formats, but they are still per window, not global.

## Upstream PR #5468: vertical side status

Options added (from the PR's tmux.1):

| option | default | meaning |
|---|---|---|
| `side-status` | off | `left`, `right` or `off` |
| `side-status-width` | 14 | column width including the separator line |
| `side-status-format` | tree of sessions and windows | format string; `#[nl]` or newline ends a row |
| `side-status-style` | green on black | style of the column |

Mechanics (from the diff, 25 files):

- Geometry: `status_side_size(c)` is subtracted from `tty.sx` in resize.c
  where `status_line_size` is subtracted from `tty.sy`. A `CLIENT_SIDESTATUSOFF`
  flag hides the column when the terminal is too narrow.
- Redraw: screen-redraw.c gains a `side_left` offset added to every x when
  the column is on the left, and a `REDRAW_SIDE_STATUS` pass that draws the
  column's own `struct screen` row by row.
- Content: `status_side_redraw` in status.c expands the format with
  `format_expand_time`, so `#()` commands work and the column refreshes on
  `status-interval` or `refresh-client -S`. A new `format_draw_lines` splits
  rows and keeps style ranges across rows.
- Mouse: `struct mouse_event` gains `sideat` and `sidecols`; clicks in the
  column resolve to `KEYC_MOUSE_LOCATION_STATUS`, so `MouseDown1Status`
  bindings fire, with `mouse_y` giving the row. Rows produced by the default
  format carry window and session ranges so clicks select them.
- Maintainer feedback: approach approved; single column only; single format
  option, not an array; naming and default styling settled. Target 3.9.

Empirical test on the built branch (nested client, 133 columns wide):

- With `side-status left` and width 44 the window area became 89 columns and
  the two panes were laid out inside it.
- `side-status-format "#(cat file)"` where the file contains kido's listing
  with `#[fg=...]` styles and `#[nl]` between rows rendered the full listing
  in colour.
- The same content with literal newlines rendered only the last line. Row
  breaks must be `#[nl]` when the content comes from `#()`.

## How kido would use it

1. Add `kido render`: print the current listing once, with tmux style
   markup and `#[nl]` row separators, and record which pane each row maps
   to in a small state file.
2. tmux config:
   `set -g side-status left`, `set -g side-status-width 40`,
   `set -g side-status-format '#(kido render)'`, `set -g status-interval 1`.
   Hooks that already fire (Claude Code hooks, window changes) can call
   `refresh-client -S` so updates appear immediately instead of on the
   interval.
3. Mouse: bind `MouseDown1Status` to `run-shell "kido click -y #{mouse_y}"`,
   which looks up the row and jumps.
4. Keyboard: a `kido` key table entered with `prefix k`; `j`/`k` move a
   selection stored in a server option and refresh, `Enter` jumps, `q`
   leaves the table. The column is never focused; it only displays.

Limits: no free-form typing into the sidebar, refresh is pull-based
(`#()` runs every interval), and the width is a session-wide option.

## Fork option A: interactive column on top of PR #5468

Idea: let `side-status-format` be replaced by a job. The column becomes what
a popup is (screen + input parser + pty), drawn in the reserved strip, with
keys routed to it only while a per-client "side focused" flag is set.

Pieces, with where they would go:

- Data: extend `struct side_status_line` (tmux.h, added by the PR) with the
  fields of `struct popup_data` that matter: `struct job *job`,
  `struct input_ctx *ictx`, `struct colour_palette palette`. Start the job
  with `job_run(..., JOB_NOWAIT|JOB_PTY|JOB_KEEPWRITE, sx, sy)` as popup.c
  does at popup.c:651-653 and parse output with `input_parse_screen`
  (popup.c:463-483).
- Drawing: unchanged. The PR's `REDRAW_SIDE_STATUS` pass already copies the
  column's screen to the terminal row by row; only the screen's producer
  changes.
- Resize: on client resize call `screen_resize` and `job_resize` (see
  popup.c:285-322). The PR's `CLIENT_SIDESTATUSOFF` handling stays.
- Input: add a `CLIENT_SIDEFOCUS` flag and a `select-side` command (or a
  `-S` flag on `select-pane`). In `server_client_key_callback`, after the
  overlay block and before key-table lookup (server-client.c:1786-1830),
  when the flag is set and the key is not a prefix, deliver it with
  `input_key(&side.screen, job_get_event(job), key)` like popup.c:437-458.
  Keep the prefix and key tables working so `prefix k` can leave.
- Cursor: `server_client_check_redraw` paths that pick the cursor from the
  active pane (server-client.c:2180-2216) need a branch for side focus.
- Mouse: the PR already maps clicks into the column; forward them to the
  job with `input_key_get_mouse` as popup.c does.
- Per client versus per session: a job per client means one process per
  attached terminal (you have two clients). One job per server with the
  screen copied to each client is simpler but then every client shares one
  cursor and selection. Per client is the popup precedent.

Estimate: 400-700 lines on top of the PR. The hard parts are focus
semantics (pane focus events in window.c:684-688 assume the overlay model)
and the fast-path regression the PR already notes: with a left column no
pane is "full width", so `tty_full_width` (tty.c:78-79) never allows the
insert/delete line shortcuts, and scrolling costs redraws unless the
terminal supports margins.

## Fork option B: a server-owned pane in a reserved strip

Make the sidebar a real `window_pane` not attached to any window, drawn in
the strip and receiving keys through the normal pane path. Rejected on
inspection; the window coupling is structural, not incidental:

- `window_pane_create` (window.c:1389-1390) sets `wp->window` and creates
  the pane's options as a child of the window's options tree; every option
  lookup on a pane goes through that.
- Every pane event and format target goes through `cmd_find_from_pane`
  (cmd-find.c:827-835), which needs the pane's window to be reachable from a
  session's winlinks (cmd-find.c:790-804) and fails otherwise. Hooks,
  `#{pane_*}` formats and `send-keys` would all miss a window-less pane.
- `spawn_pane` (spawn.c:243-556) reads the session for history-limit,
  default-shell, environment and termios, and the window for pixel size,
  then inserts the pane into the window's layout (spawn.c:351-360).
- Visibility and mouse offsets are keyed on the client's current window:
  `window_pane_is_visible` (window.c:2054-2059) dereferences `wp->window`,
  and `tty_window_offset` (tty.c:965-1035) is computed from
  `c->session->curw->window`.

Faking a window to satisfy all of that is a larger change than option A
and buys nothing over it.

## Fork option C: a pinned layout cell

Teach the layout code to leave one cell alone. There is a precedent: the
only cell flag today is `LAYOUT_CELL_FLOATING` (tmux.h:1582), and every
layout-set function rebuilds the tree from tiled cells only, then re-attaches
the non-tiled cells with `layout_set_link_floating` (layout-set.c:139-152,
called at 286, 385, 484, 584, 726). A `LAYOUT_CELL_PINNED` flag could ride
the same path, with the difference that a pinned cell must also reserve its
column from the root geometry, which floating cells do not.

What else would need the flag:

- `cmd-rotate-window.c:65-101` reassigns cells across all panes with no
  tiled filter, so a pinned cell would be handed to an arbitrary pane.
- `cmd-swap-pane.c:48-57` already skips non-tiled panes for `-U`/`-D`; the
  explicit-target path (123-143) does not.
- Pane navigation `window_pane_find_up/down/left/right` (window.c:2164-2340)
  iterates every pane without a visibility or floating filter, so
  `select-pane -L` would land on the sidebar unless filtered.
- `layout_fix_panes` (layout.c:420-483), `layout_resize` (816-870), kill,
  break, join, zoom and mouse drag would each need a decision.

The result is still one pane per window, which is exactly what kido
emulates now from outside with hooks. It removes the hooks and the
self-repositioning but keeps a process per window. Not worth a fork; if
anything, this is the shape of a small upstream proposal.

## Cost of maintaining a fork

- Build is routine: autoconf, automake, libevent, ncurses via Homebrew; the
  PR branch configured and built in about a minute.
- Rebase burden is real. screen-redraw.c was rewritten on 2026-09-09
  (scenes and spans replaced the old draw context), the layout format
  changed to JSON, and floating panes touched window.c, layout.c and most
  cmd-*.c files in this cycle. A private branch touching status.c and
  server-client.c would conflict regularly.
- Upstream stance: the maintainer accepted a display-only column and
  explicitly narrowed the PR (one column, one format option). An interactive
  column would be a separate proposal; issue #4910 asked for display only.

## Result of the attempt (2026-09-17)

We forked anyway. Branch `side-pane` in `~/Workspace/tmux-pr5468` on top of
PR #5468; the diff is saved as `docs/tmux-side-status-command.patch`
(about 530 insertions across tmux.h, options-table.c, status.c, server-client.c,
window.c, tmux.1). Installed at `~/.local/tmux-side/bin/tmux`.

What it adds:

- `side-status-command`: when set, the side column runs the command in a
  pty sized to the column and shows its screen instead of the format. One
  job per client, kept in step with the option and column size by a check
  in the server loop; restarted on the next status redraw after it exits,
  at most once a second like `#()` jobs; kept alive while the terminal is
  too narrow for the column; killed
  when the column is hidden or the client goes away. The job gets
  `TMUX_SIDE=1` and `TMUX_SIDE_CLIENT=<client name>`.
- Client flag `side-focus`, toggled with `refresh-client -f side-focus` and
  `-f !side-focus`, visible in `#{client_flags}`. While set, every key except
  the prefix keys goes to the job; the cursor is placed from the job's
  screen; the active pane gets a focus-out.
- Mouse events inside the column go to the job; a button press inside sets
  the flag and a press elsewhere clears it. Dragging the separator line
  resizes the column through tmux's own drag callback, with the job's pty
  resized once on release.

Verified with a nested client on an isolated server: kido renders in the
column at 44 columns wide, `j` moves the cursor when focused, Enter jumps
across sessions, `C-b c` still creates a window, `q` exits kido and the flag
clears and the job restarts, a mouse click on a row focuses the column and
jumps, a click in a pane unfocuses, right-side placement offsets correctly,
hiding the column kills the job and showing it restarts it, and
kill-server leaves no job behind.

kido changes: side mode (`TMUX_SIDE=1`) with the client taken from the
environment, mouse support, and it now runs the tmux binary that owns the
server in `$TMUX` so the patched tmux talks to itself. Config for the fork
is `tmux/kido-side.tmux` (`prefix K` shows or hides the column, `prefix k`
toggles focus).

The job writes straight to the owning client's terminal at the column's
offset, like a popup does. A dedicated `CLIENT_REDRAWSIDESTATUS` flag
covers the cases where that is not possible, so job output never triggers
a full status-line redraw, and the copy into the side status screen only
happens when the job screen changed since the last copy. A fast printer scrolling the column at full
speed left tmux responsive.

A max-effort code review found and we fixed: a hoisted prefix test that
broke root-table bindings from copy mode, an invisible cursor in the job,
read-only clients able to type into the job, bracketed paste split around
the prefix, the job killed when the terminal got narrower than the column,
cursor precedence with the prompt and menu, ghost double clicks, focus
stolen by mouse motion, the focus flag honoured without a job, a negative
column on size-ignored clients, a 1 Hz restart loop for failing commands,
and mouse modes rebuilt from panes only. Still open: a drag that crosses the
column edge is split between the job and the pane, keys typed during a
`bind -r` repeat window go to the pane, and the after-redraw copy ignores
the job's palette and hyperlinks.

Known gaps: one kido process per attached client; the job's default colours
are the terminal's, not `side-status-style`; no scroll fast paths for panes
next to the column (inherited from the PR); nothing upstreamable yet.

## Files worth reading first if you do fork

- `~/Workspace/tmux-pr5468/status.c` (side status: `status_side_*`)
- `~/Workspace/tmux-src/popup.c` (job-backed screen, key delivery, resize)
- `~/Workspace/tmux-src/server-client.c:1740-1830` (key routing order)
- `~/Workspace/tmux-src/screen-redraw.c:27-96` (scene architecture notes)
- `~/Workspace/tmux-src/resize.c:191-194, 280-323` (client to window size)
