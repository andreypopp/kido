#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
unset KIDO_AGENT_PARENT_SESSION KIDO_AGENT_DEPTH KIDO_AGENT_TASK_FILE KIDO_AGENT_PARENT_PID KIDO_AGENT_RUN_ID TMUX_PANE TMUX
IFS=: read -r -a entries <<< "$PATH"
PATH=
for entry in "${entries[@]}"; do
  [[ ${entry%/} == *share/kido/bin ]] || PATH+="${PATH:+:}$entry"
done
export PATH KIDO_E2E_REQUIRED=1 KIDO_TS_TEST_REQUIRED=1
status=0
stage() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; status=1; fi
}
e2e() {
  make e2e KIDO_TMUX= COUNT="${COUNT:-1}" E2E="${E2E:-.}"
}
case ${1:-verify} in
  flake)
    [[ -n ${RUN:-} && ${COUNT:-20} =~ ^[1-9][0-9]*$ ]] || { echo 'flake requires RUN and a positive COUNT' >&2; exit 1; }
    E2E=$RUN COUNT=${COUNT:-20} stage e2e e2e
    ;;
  verify)
    for name in ${STAGES:-build unit e2e ts}; do
      case $name in
        build) stage build dune build ;;
        unit) stage unit dune test --force ;;
        e2e) stage e2e e2e ;;
        ts) stage ts ./scripts/test-ts.sh ;;
        *) echo "Unknown stage: $name" >&2; status=1 ;;
      esac
    done
    ;;
  *) exit 1 ;;
esac
exit "$status"
