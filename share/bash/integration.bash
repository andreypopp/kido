# bash shell integration: reports command start/finish via OSC 133 for kido's sidebar.

# PS0 and PROMPT_COMMAND are read nowhere but an interactive shell.
[[ $- == *i* ]] || return 0
# PS0 arrived in bash 4.4, and macOS still ships 3.2 as /bin/bash.
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || return 0
# With promptvars unset bash does not expand a prompt string at all, so
# PS0 would print its own source text before every command.
shopt -q promptvars || return 0

kido_osc133_precmd() {
  local ret=$?
  if [[ -v kido_osc133_ran ]]; then
    unset kido_osc133_ran
    printf '\033]133;D;%s\007' "$ret"
  fi
  printf '\033]133;A\007'
}

kido_osc133_preexec() {
  # The whole line as typed, which only the history holds; BASH_COMMAND is
  # one simple command out of it.
  local cmdline
  cmdline=$(HISTTIMEFORMAT= builtin history 1)
  cmdline=${cmdline#*[[:digit:]][[:space:]]}     # the history number
  cmdline=${cmdline#"${cmdline%%[![:space:]]*}"} # and the run of spaces after it
  # By character under a UTF-8 locale; under LC_ALL=C bash counts bytes instead,
  # so a cut can split a multibyte rune.
  ((${#cmdline} > 1024)) && cmdline=${cmdline:0:1024}
  # Control characters only: a BEL or an ESC would end the sequence early.
  # Everything else goes through verbatim - tmux escapes it once already.
  cmdline=${cmdline//[[:cntrl:]]/ }
  printf '\033]133;C;cmdline=%s\007' "$cmdline"
}

# Sourced twice, each hook is installed once: a second PS0 fragment would
# report every command line twice over.
[[ $PS0 == *kido_osc133_preexec* ]] ||
  # The assignment must happen in this shell; the command substitution
  # beside it runs in a subshell and could not set the flag.
  PS0+='${kido_osc133_ran=}$(kido_osc133_preexec)'

# Prepended, not appended: the exit status precmd reports is $?, and
# anything of the user's that ran first would have replaced it with its
# own.
if [[ -z ${PROMPT_COMMAND[*]} ]]; then
  PROMPT_COMMAND=(kido_osc133_precmd)
elif [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
  # An array since bash 5.1, and one entry of it is one command.
  [[ ${PROMPT_COMMAND[*]} == *kido_osc133_precmd* ]] ||
    PROMPT_COMMAND=(kido_osc133_precmd "${PROMPT_COMMAND[@]}")
else
  [[ $PROMPT_COMMAND == *kido_osc133_precmd* ]] ||
    PROMPT_COMMAND="kido_osc133_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
