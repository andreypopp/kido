# zsh shell integration: reports command start/finish via OSC 133 for kido's sidebar.
typeset -g kido_osc133_ran=0
kido_osc133_precmd() {
  # Not named status: that is a special parameter in zsh and shadowing it stops this function dead.
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
  # By character, not by byte: zsh indexes strings by character here.
  (( ${#cmdline} > 1024 )) && cmdline=${cmdline[1,1024]}
  # Control characters only: a BEL or an ESC would end the sequence early.
  # Everything else goes through verbatim - tmux escapes it once already.
  cmdline=${cmdline//[[:cntrl:]]/ }
  printf '\033]133;C;cmdline=%s\007' "$cmdline"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd  kido_osc133_precmd
add-zsh-hook preexec kido_osc133_preexec
