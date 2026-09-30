#!/bin/sh
# A stand-in for `kido sidebar-feed`, pointed to by KIDO_APP_FEED: prints a
# v1 snapshot of a fixed tree every 0.5s, appends each stdin line to
# /tmp/fake-feed.log, and exits on stdin EOF, like the real subcommand.
# `filter <text>` keeps the sessions whose name contains the text and is
# echoed; a filter containing "!" sets `error`.
# The ids match a server built in this order: new-session -s main (%0),
# split-window (%1), new-window x4 (%2-%5), new-session -s work (%6),
# new-window (%7), split-window (%8), new-window (%9), split-window (%10).
# bash redirects a backgrounded job's own stdin to /dev/null unless it reads
# from a fd saved before backgrounding it, hence `exec 3<&0` and `<&3` below.
exec 3<&0
state=${TMPDIR:-/tmp}/fake-sidebar-feed.$$
: >"$state"
(
  exec >/dev/null
  while IFS= read -r line <&3; do
    echo "$line" >>/tmp/fake-feed.log
    case $line in
    filter) : >"$state" ;;
    "filter "*) printf '%s' "${line#filter }" >"$state" ;;
    esac
  done
  kill "$$"
) &
trap 'rm -f "$state"; exit 0' TERM

span() { printf '{"text":"%s","role":"%s"}' "$1" "$2"; }
row() {
  printf '{"pane":%s,"window":%s,"tree":"%s","indicator":%s,"title":[%s],"tail":[%s],"attention":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
session() {
  case $2 in *"$filter"*) ;; *) return ;; esac
  printf '%s{"id":"%s","name":"%s","current":%s,"rows":[%s]}' "$sep" "$1" "$2" "$3" "$4"
  sep=,
}

n=0
while :; do
  n=$((n + 1))
  filter=$(cat "$state")
  case $filter in *!*) error='"could not read the agent state"' ;; *) error=null ;; esac
  case $((n / 10 % 2)) in 0) tests='{"kind":"running"}' tests_att=false ;; *) tests='{"kind":"waiting"}' tests_att=true ;; esac
  main=$(
    row '"%0"' '"@0"' '┌' '{"kind":"running"}' "$(span orchestrator plain)" "$(span '  ' plain),$(span "fixing the failing sidebar tests, step $n" dim)" false
    printf ,
    row '"%2"' '"@1"' '│ ├' "$tests" "$(span tests plain)" "$(span '  ' plain),$(span 'Allow running make test?' dim)" "$tests_att"
    printf ,
    row '"%3"' '"@2"' '│ └' '{"kind":"done"}' "$(span docs plain)" "$(span '  ' plain),$(span 'wrote docs/design.md' dim)" true
    printf ,
    row null null '│   ├' '{"kind":"gone","outcome":"completed"}' "$(span lint dim)" "$(span '  ' plain),$(span completed dim)" false
    printf ,
    row '"%4"' '"@3"' '│   └' '{"kind":"gone","outcome":"died"}' "$(span flaky dim)" "$(span '  ' plain),$(span died dim)" false
    printf ,
    row '"%1"' '"@0"' '└' null "$(span zsh proc)" '' false
    printf ,
    row '"%5"' '"@4"' '╶' '{"kind":"running"}' "$(span 'make test' proc)" '' false
  )
  work=$(
    row '"%6"' '"@5"' '╶' '{"kind":"stalled"}' "$(span 'review the pull request' plain)" "$(span '  ' plain),$(span 'reading files' stalled)" false
    printf ,
    row '"%7"' '"@6"' '┌' '{"kind":"failed"}' "$(span 'cargo build --release' proc)" '' false
    printf ,
    row '"%8"' '"@6"' '└' null "$(span 'ssh ' proc),$(span devbox plain),$(span ': ' proc),$(span 'tail -f /var/log/system.log' plain)" '' false
    printf ,
    row '"%9"' '"@7"' '┌' '{"kind":"compacting"}' "$(span refactor plain)" "$(span '  ' plain),$(span compacting compacting)" false
    printf ,
    row '"%10"' '"@7"' '└' '{"kind":"unknown"}' "$(span - plain)" '' false
  )
  sep=
  sessions=$(
    session '$0' main true "$main"
    session '$1' work false "$work"
  )
  printf '{"v":1,"client":{"session":"$0","window":"@0","pane":"%%0"},"filter":"%s","error":%s,"sessions":[%s]}\n' \
    "$filter" "$error" "$sessions"
  sleep 0.5
done
