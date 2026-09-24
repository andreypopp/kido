# kido's tmux defaults: the side column and the keys around it. The
# launcher writes this file into the configuration it starts the kido
# server with, ahead of the user's own ~/.config/kido/kido.conf, so
# anything here can be overridden there.

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

# example: switch to the adjacent window in the sidebar's order, across
# session boundaries (unlike tmux's own next-window/previous-window, which
# wrap inside one session); not bound by default, uncomment to enable, or
# bind other keys of your choosing
# bind-key -n S-Up   run-shell "kido switch-window prev -client '#{client_name}'"
# bind-key -n S-Down run-shell "kido switch-window next -client '#{client_name}'"
