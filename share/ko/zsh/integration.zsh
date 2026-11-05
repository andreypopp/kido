# zsh shell integration: reports command start/finish via OSC 133 for ko's status.
typeset -g ko_osc133_ran=0
ko_osc133_precmd() {
  # Not named status: that is a special parameter in zsh and shadowing it stops this function dead.
  local ret=$?
  if (( ko_osc133_ran )); then
    ko_osc133_ran=0
    printf '\033]133;D;%s\007' $ret
  fi
  local uri=$PWD
  if [[ $PWD == *[!a-zA-Z0-9/._~-]* ]]; then
    uri=
    local LC_ALL=C byte hex i
    for (( i=0; i<${#PWD}; i++ )); do
      byte=${PWD[i+1]}
      case $byte in
        [a-zA-Z0-9/._~-]) uri+=$byte ;;
        *) printf -v hex '%%%02X' "'$byte"; uri+=$hex ;;
      esac
    done
  fi
  printf '\033]7;file://%s%s\007' "$HOST" "$uri"
  printf '\033]133;A\007'
}
ko_osc133_preexec() {
  ko_osc133_ran=1
  local cmdline=$1
  # By character, not by byte: zsh indexes strings by character here.
  (( ${#cmdline} > 1024 )) && cmdline=${cmdline[1,1024]}
  # Control characters only: a BEL or an ESC would end the sequence early.
  cmdline=${cmdline//[[:cntrl:]]/ }
  # A ';' ends the parameter and a '%' starts a two-digit hex escape, so
  # encode those two. Everything else goes through verbatim.
  cmdline=${cmdline//\%/%25}
  cmdline=${cmdline//;/%3B}
  printf '\033]133;C;cmdline_url=%s\007' "$cmdline"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd  ko_osc133_precmd
add-zsh-hook preexec ko_osc133_preexec
