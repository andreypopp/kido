# kido's zsh shell integration: makes a plain shell pane report to tmux
# when a command starts and finishes, so the sidebar can show it as
# running or idle the way it does for agent panes.
#
# It is installed by pointing ZDOTDIR at this directory instead of editing
# any of your own startup files, which is what the one tmux line does:
#
#   set -g default-command 'KIDO_ZDOTDIR="$ZDOTDIR" ZDOTDIR=<brew prefix>/share/kido/shell/zsh exec zsh'
#
# zsh reads this .zshenv first, before anything else, so the prologue
# below is kept POSIX-cautious: it must not depend on anything a later
# startup file sets up.

# Restore ZDOTDIR to whatever the user had (KIDO_ZDOTDIR carries it in;
# empty means they had none), then hand straight over to their real
# .zshenv. Because that happens here, at the very first startup file, the
# rest of zsh's startup - .zprofile, .zshrc, .zlogin - is read from the
# user's own ZDOTDIR as usual: this directory needs no shims for them, and
# neither ZDOTDIR nor KIDO_ZDOTDIR leaks into the session or its children.
if [ -n "$KIDO_ZDOTDIR" ]; then ZDOTDIR="$KIDO_ZDOTDIR"; else unset ZDOTDIR; fi
unset KIDO_ZDOTDIR
[ -f "${ZDOTDIR:-$HOME}/.zshenv" ] && . "${ZDOTDIR:-$HOME}/.zshenv"

# OSC 133 shell integration markers, which tmux next-3.9 parses into
# #{pane_command_running}, #{pane_command_start_time} and
# #{pane_last_prompt_time}: D (the last command's exit status) and A (a
# prompt is here) at each prompt, C just before a command runs.
kido_osc133_precmd()  { printf '\033]133;D;%s\007\033]133;A\007' $? }
kido_osc133_preexec() { printf '\033]133;C\007' }
autoload -Uz add-zsh-hook
add-zsh-hook precmd  kido_osc133_precmd
add-zsh-hook preexec kido_osc133_preexec
