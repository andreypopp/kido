# kido's zsh shell integration: makes a plain shell pane report to tmux
# when a command starts and finishes, so the sidebar can show it as
# running or idle the way it does for agent panes.
#
# It ships with kido; `kido setup-zsh` finds it and adds a line to
# your ~/.zshrc that sources it.
#
# The markers are OSC 133, which tmux next-3.9 parses into its own
# formats: A (a prompt is here) feeds #{pane_last_prompt_time}, C (a
# command is about to run) starts #{pane_command_running} and
# #{pane_command_start_time}, and D (the command finished, with its exit
# status) ends them and feeds #{pane_command_status} and
# #{pane_command_end_time}.
# D is emitted only after a C, so the first prompt of a shell - where
# nothing has run and $? carries whatever the rc files happened to leave -
# reports a prompt and not the end of a command that never began.
typeset -g kido_osc133_ran=0
kido_osc133_precmd() {
  # Not named status: that is a special parameter in zsh, a synonym for
  # $?, and shadowing it stops this function dead.
  local ret=$?
  if (( kido_osc133_ran )); then
    kido_osc133_ran=0
    printf '\033]133;D;%s\007' $ret
  fi
  printf '\033]133;A\007'
}
kido_osc133_preexec() {
  kido_osc133_ran=1
  local cmdline=$1
  (( ${#cmdline} > 1024 )) && cmdline=${cmdline[1,1024]}
  printf '\033]133;C;cmdline=%q\007' "$cmdline"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd  kido_osc133_precmd
add-zsh-hook preexec kido_osc133_preexec
