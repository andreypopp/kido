#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
unset KO_STATE_DIR KO_PANE KO_SOCKET KO_RUN_ID KO_RUN_OUTPUT "${!KO_AGENT_@}"
IFS=: read -r -a entries <<< "$PATH"
PATH=
for entry in ${entries[@]+"${entries[@]}"}; do
  [[ ${entry%/} == *share/ko/bin ]] || PATH+="${PATH:+:}$entry"
done
export PATH KO_TS_TEST_REQUIRED=1
status=0
now() {
  perl -MTime::HiRes=time -e 'printf "%.6f", time'
}
stage() {
  local name=$1
  shift
  local start end elapsed result
  start=$(now)
  "$@"
  case $? in
    0) result=PASS ;;
    77) result=SKIP ;;
    *) result=FAIL; status=1 ;;
  esac
  end=$(now)
  elapsed=$(perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$start" "$end")
  echo "$result: $name (${elapsed}s)"
}
# make verus prints SKIP: and succeeds when the Verus archive cannot be fetched.
verus() {
  local log rc
  log=$(mktemp)
  make verus 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if (( rc == 0 )) && grep -q '^SKIP:' "$log"; then rc=77; fi
  rm -f "$log"
  return "$rc"
}
for name in ${STAGES:-build-ko lint unit-ko e2e-ko ts verus}; do
  case $name in
    build-ko) stage build-ko make build-ko ;;
    unit-ko) stage unit-ko make test-ko ;;
    e2e-ko) stage e2e-ko make e2e-ko E2E_KO="${E2E_KO:-}" ;;
    lint) stage lint make lint ;;
    lint-rs) stage lint-rs make lint-rs ;;
    ts) stage ts ./scripts/test-ts.sh ;;
    verus) stage verus verus ;;
    *) echo "Unknown stage: $name" >&2; status=1 ;;
  esac
done
exit "$status"
