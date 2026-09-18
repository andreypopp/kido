# kido inside a native tmux side column.
# Needs the patched tmux: brew install andreypopp/tap/tmux
# (github.com/andreypopp/tmux, branch side-pane).
#   source-file "$(brew --prefix)/share/kido/kido-side.tmux"

set -g side-status left
set -g side-status-width 40
# just the line, no background behind it
set -g side-status-style "fg=green"
set -g side-status-command "kido"
set -g mouse on

# prefix + K: show the side column with keyboard focus, or hide it
bind-key K if-shell -F '#{==:#{side-status},off}' \
  'set -g side-status left ; refresh-client -f side-focus' \
  'set -g side-status off'

# prefix + k: toggle keyboard focus between the side column and the pane
bind-key k if-shell -F '#{m:*side-focus*,#{client_flags}}' \
  'refresh-client -f !side-focus' \
  'refresh-client -f side-focus'

# prefix + < / > shrink or widen the side column by 4 (the line next to the
# window area can also be dragged with the mouse)
bind-key -r < set-option -F side-status-width "#{e|-|:#{side-status-width},4}"
bind-key -r > set-option -F side-status-width "#{e|+|:#{side-status-width},4}"
