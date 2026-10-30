# Reading notes (untracked scratch, kido-server design)

Read 2026-10-29: kido AGENTS.md, docs/design.md, design-rpc.md,
design-program-status.md, share/rpc/contract.md (6.2, fork c3be2327),
lib_tmux/AGENTS.md, design-subagents.md headings; kido-app design-app.md,
known-issues-app.md; notes: libghostty-vt-renderers, remote-hosts-plan,
smooth-scroll-research, ios-app-idea, torn-off-floats-idea,
kitty-clipboard-research (head), osc5522-plan-v3 (head), tmux-pause-stall.

## Fork inventory

tmux fork (14 commits on upstream master e880cf63.. next-3.9):
side-status-command; pause flush; %exit reason; hang up pane child;
query-reply routing to owner; OSC 7501 program status; kitty: keep bytes,
-G/-K capture, refresh-client -C pixels, no-output focus, DA1 sixel gate,
t=s shm + image-shm, a=f frame edits, animation. Diff vs upstream
~36k insertions / 432 files (includes upstream churn; kido part smaller).

Ghostty fork (20 commits on 1.4.0): manual IO + authoritative grids,
suppressed replies, config snapshots, producer join order, tokened render
fences, stable row identity, pixel scroll bands, search FIFO, atomic
prepend + viewport anchor, restore without host effects, typed clipboard
reads/OSC 52 bounds, 5522 paste opt-out, kitty clipboard via embedder,
selection API, compression timer, blink timer, held placements, shm
images/refused media/animation restore. ~6.6k insertions / 52 files.

App: App/*.swift 13.9k lines; TmuxControl package 942 lines (Capture,
Client, Command, Event, HistoryCapture, Layout, PaneLayout, PaneSync,
ScrollAnchor, SearchCapture).

## What tmux gives kido today (must be re-supplied)

- topology: sessions/windows/panes, linked windows, grouped sessions,
  floats (new-pane -x/-y/-X/-Y, new-layouts JSON), zoom, layouts,
  move-pane/swap-pane/join, remain-on-exit, pane_dead_status/signal,
  pane_current_command, alternate_on, pane_current_path.
- pane-scoped user options: @kido_run, @kido_session/_name/_inbox/
  _activity, @kido_ssh, @kido_ssh_args, session @kido-order.
- OSC 133 formats (pane_last_prompt_time, pane_command_*), hooks only.
- OSC 7501 storage per pane + %program-status notification.
- control mode: %output, %layout-change, %window-*, %session-*, %pause,
  %exit reason, pause-after, no-output/ignore-size/image-shm flags,
  window-size latest sizing with pixel cell size.
- capture-pane -p -e -J -F -L -T -N -S -E -a -P -C -G -K -k -r.
- send-keys -H, load-buffer/paste-buffer -p, set-clipboard/OSC 52
  forwarding, display-popup/menu (modal), run-shell bindings, hooks.
- server environment (KIDO_SERVER stamp), new-window -e/-c/-d, -a/-b,
  default-command, side-status-command + TMUX_SIDE_CLIENT,
  side-status-focus, key tables, prefix bindings, copy mode (TUI only).
- socket -S path, -u, protocol version mismatch, kill-server HUP.

## Pain points confirmed in docs

1. two emulators: known-issues "Resync loses pen/charset/pending wrap",
   "Alternate-screen option disagrees", "Reflow row counts can disagree",
   "History metadata is sampled", "Resize anchors cover only newest
   capture", "Extra loaded history dropped on resize", stale rows.
2. restore = capture-pane batches, 10k chunks, Load more, separate -F -L
   -T metadata, find via 5000-row chunk captures; ~20 ms / 10k lines.
3. control protocol: %begin/%end counting + marker hack for nested
   batches, layout-change after reply, pause stall (fixed in fork),
   octal %output, 64 MiB buffered reply limit, 8 MiB -K pages.
4. query replies: one owner; MANUAL_MIRROR suppresses Ghostty.
5. input: send-keys -H; prefix bindings don't fire; popups no-op.
6. images: second image-only client per connection; shm guard timers;
   fetch rows can drift.
7. status: polling tick at 100 ms; whole-second OSC 133; stuck flag heal;
   pane options as metadata; watched/current-window coupling between
   two app windows (shared current window per session, window-size
   latest fights); feed restart loses outcome tracking.
8. clipboard: OSC 52 two-responder problem; get-clipboard server-wide;
   consent per host.
9. ops: rebase cost, restart stamp, 103-byte socket paths, -u, state-dir.
