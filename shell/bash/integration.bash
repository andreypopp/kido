# kido's bash shell integration: makes a plain shell pane report to tmux
# when a command starts and finishes, so the sidebar can show it as
# running or idle the way it does for agent panes.
#
# It ships with kido; `kido setup-bash` finds it and adds a line to
# your ~/.bashrc that sources it.
#
# The markers are the same OSC 133 sequences shell/zsh/integration.zsh
# sends, and mean the same to tmux next-3.9: A (a prompt is here) feeds
# #{pane_last_prompt_time}, C (a command is about to run) starts
# #{pane_command_running} and #{pane_command_start_time} and feeds
# #{pane_command_line} from its cmdline= parameter, and D (the command
# finished, with its exit status) ends them and feeds
# #{pane_command_status} and #{pane_command_end_time}.
# D is emitted only after a C, so the first prompt of a shell - where
# nothing has run and $? carries whatever the rc files happened to leave -
# reports a prompt and not the end of a command that never began.
#
# Where zsh has precmd and preexec, bash has PROMPT_COMMAND and PS0, which
# is the pair kitty's bash integration uses too. PS0 is what makes the
# command-start marker fire once per command line: bash expands it exactly
# once, after reading a line and before running it, so a pipeline, a
# function body and a loop each get one C - which a DEBUG trap, firing per
# simple command, would not give without a flag to suppress the rest of
# them. It also leaves a user's own DEBUG trap alone, there being none to
# chain.

# PS0 and PROMPT_COMMAND are read nowhere but an interactive shell.
[[ $- == *i* ]] || return 0
# PS0 arrived in bash 4.4, and macOS still ships 3.2 as /bin/bash. An old
# bash reports nothing rather than half of it, which is what the sidebar
# shows for any shell it knows nothing about.
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
  # The whole line as typed, which only the history holds: BASH_COMMAND -
  # a DEBUG trap's view - is one simple command out of it. A shell that
  # keeps no history for the line (set +o history, or a HISTCONTROL that
  # drops it) leaves the previous entry here, so the marker is right and
  # the command line it carries is stale.
  local cmdline
  cmdline=$(HISTTIMEFORMAT= builtin history 1)
  cmdline=${cmdline#*[[:digit:]][[:space:]]}     # the history number
  cmdline=${cmdline#"${cmdline%%[![:space:]]*}"} # and the run of spaces after it
  # By character under a UTF-8 locale, where bash indexes strings by
  # character, so the cut cannot land inside a multibyte rune. Under LC_ALL=C
  # bash counts bytes instead and a cut can split one, which costs that
  # command line its last character in the sidebar and nothing else.
  ((${#cmdline} > 1024)) && cmdline=${cmdline:0:1024}
  # Control characters only: a BEL or an ESC would end the sequence early.
  # Everything else goes through verbatim - cmdline= is the last parameter
  # and its value runs to the end of the string, so ';' and '=' are safe -
  # because tmux sanitises what it stores and would escape any escaping
  # this end added a second time.
  cmdline=${cmdline//[[:cntrl:]]/ }
  printf '\033]133;C;cmdline=%s\007' "$cmdline"
}

# Sourced twice, each hook is installed once: a second PS0 fragment would
# report every command line twice over.
[[ $PS0 == *kido_osc133_preexec* ]] ||
  # The assignment is a parameter expansion because it has to happen in
  # this shell: it is what tells the next prompt a command line was
  # entered, and the command substitution beside it runs in a subshell
  # that could not say so. It expands to nothing, having no value.
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
