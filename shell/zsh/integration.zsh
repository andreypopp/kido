# kido's zsh shell integration: makes a plain shell pane report to tmux
# when a command starts and finishes, so the sidebar can show it as
# running or idle the way it does for agent panes.
#
# It ships with kido, which arranges for it to be sourced: `kido shell`
# for a local pane, `kido ssh` for a remote one.
#
# The markers are OSC 133, which tmux next-3.9 parses into its own
# formats: A (a prompt is here) feeds #{pane_last_prompt_time}, C (a
# command is about to run) starts #{pane_command_running} and
# #{pane_command_start_time} and feeds #{pane_command_line} from its
# cmdline= parameter, and D (the command finished, with its exit
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
  # By character, not by byte: zsh indexes strings by character here, so
  # the cut cannot land inside a multibyte rune.
  (( ${#cmdline} > 1024 )) && cmdline=${cmdline[1,1024]}
  # Control characters only: a BEL or an ESC would end the sequence early.
  # Everything else goes through verbatim - cmdline= is the last parameter
  # and its value runs to the end of the string, so ';' and '=' are safe -
  # because tmux sanitises what it stores and would escape any escaping
  # this end added a second time.
  cmdline=${cmdline//[[:cntrl:]]/ }
  printf '\033]133;C;cmdline=%s\007' "$cmdline"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd  kido_osc133_precmd
add-zsh-hook preexec kido_osc133_preexec
