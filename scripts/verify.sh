#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
unset KIDO_AGENT_PARENT_SESSION KIDO_AGENT_DIR KIDO_RUN_ID KIDO_RUN_OUTPUT TMUX_PANE TMUX
IFS=: read -r -a entries <<< "$PATH"
PATH=
for entry in "${entries[@]}"; do
  [[ ${entry%/} == *share/kido/bin ]] || PATH+="${PATH:+:}$entry"
done
export PATH KIDO_E2E_REQUIRED=1 KIDO_TS_TEST_REQUIRED=1
status=0
now() {
  perl -MTime::HiRes=time -e 'printf "%.6f", time'
}
stage() {
  local name=$1
  shift
  local start end elapsed result
  start=$(now)
  if "$@"; then result=PASS; else result=FAIL; status=1; fi
  end=$(now)
  elapsed=$(perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$start" "$end")
  echo "$result: $name (${elapsed}s)"
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
