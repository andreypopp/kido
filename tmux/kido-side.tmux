# kido inside a native tmux side column.
# Needs the patched tmux: brew install andreypopp/tap/tmux
# (github.com/andreypopp/tmux, branch side-pane).
#   source-file <brew prefix>/share/kido/kido-side.tmux   (see README: Install)

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

# example: show running/idle status for plain shell panes too, not just
# agent panes. kido reads that from tmux's OSC 133 support, which only
# knows what the shell tells it, so the shell has to emit the markers:
# kido ships a zsh shim that does, installed by pointing ZDOTDIR at it
# (your own ZDOTDIR is restored immediately, so your .zprofile/.zshrc/
# .zlogin are still read from where they always were). zsh only, and it
# only reaches shells started after this line is loaded, so it is not set
# by default - uncommenting it would override every user's shell choice.
# Write the literal brew prefix: tmux does not expand $(brew --prefix).
# set -g default-command 'KIDO_ZDOTDIR="$ZDOTDIR" ZDOTDIR=/opt/homebrew/share/kido/shell/zsh exec zsh'
