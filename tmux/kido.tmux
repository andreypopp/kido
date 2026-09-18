# kido: tmux sidebar for Claude Code sessions.
# Source from your tmux.conf:   source-file ~/Workspace/kido/tmux/kido.tmux
# Expects `kido` on the tmux server's PATH (brew install andreypopp/tap/kido
# puts it there). With `make install` it lands in ~/.local/bin, which tmux's
# run-shell may not have on PATH: use absolute paths in that case.

# --- prefix + K toggles the pinned sidebar server-wide. When on, every window
# in every session gets a 40-column sidebar pane on the left (marked @kido=1);
# windows created later get one via the hooks below.
bind-key K run-shell "kido toggle -socket '#{socket_path}' -pane '#{pane_id}'"

# --- prefix + k focuses the pinned sidebar when it is on, otherwise opens the
# sidebar as a popup (Enter jumps and closes it).
bind-key k run-shell "kido focus -socket '#{socket_path}' -pane '#{pane_id}'"

set-hook -g after-new-window   'run-shell "kido ensure -socket \"#{socket_path}\" -pane \"#{pane_id}\""'
set-hook -g after-new-session  'run-shell "kido ensure -socket \"#{socket_path}\" -pane \"#{pane_id}\""'
set-hook -g after-select-window 'run-shell "kido ensure -socket \"#{socket_path}\" -pane \"#{pane_id}\""'
# any layout change (select-layout, rotate, swap, resize, split, kill) may
# move the sidebar; ensure puts it back at the left edge
set-hook -g window-layout-changed 'run-shell "kido ensure -socket \"#{socket_path}\" -pane \"#{pane_id}\""'
set-hook -g client-session-changed 'run-shell "kido ensure -socket \"#{socket_path}\" -pane \"#{pane_id}\""'
