# kido inside a native tmux side column.
# Needs the patched tmux: brew install andreypopp/tap/tmux
# (github.com/andreypopp/tmux, branch side-pane).
#   source-file "$(brew --prefix)/share/kido/kido-side.tmux"

set -g side-status left
set -g side-status-width 40
# the style is the sidebar's default text and background (like popup-style),
# so keep it at the terminal defaults
set -g side-status-style "fg=default,bg=default"
set -g side-status-command "kido"
set -g mouse on

# prefix + K: show the side column with keyboard focus, or hide it
bind-key K if-shell -F '#{==:#{side-status},off}' \
  'set -g side-status left ; refresh-client -f side-status-focus' \
  'set -g side-status off'

# prefix + k: toggle keyboard focus between the side column and the pane
# (drag the line next to the window area with the mouse to resize)
bind-key k if-shell -F '#{m:*side-status-focus*,#{client_flags}}' \
  'refresh-client -f !side-status-focus' \
  'refresh-client -f side-status-focus'
