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
e2e() {
  make e2e KIDO_TMUX= COUNT="${COUNT:-1}" E2E="${E2E:-.}"
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
ko_run() {
  local IFS='|'
  KIDO_E2E_REQUIRED=1 KO_BIN=$1 go test ./test_e2e_ko/ -count="${COUNT:-1}" -run "^(${*:2})\$" -v
}
ko_suite() {
  local names=() name
  for name in $(sed -n 's/^func \(Test[A-Za-z0-9_]*\)(t \*testing\.T).*/\1/p' test_e2e_ko/*_test.go); do
    [[ $name =~ ${E2E_KO:-.} ]] && names+=("$name")
  done
  (( ${#names[@]} )) || return 0
  ko_run "${KO_RUST:-$KO_OCAML}" "${names[@]}"
}
case ${1:-verify} in
  ko-suite) ko_suite || status=1 ;;
  flake)
    [[ -n ${RUN:-} && ${COUNT:-20} =~ ^[1-9][0-9]*$ ]] || { echo 'flake requires RUN and a positive COUNT' >&2; exit 1; }
    E2E=$RUN COUNT=${COUNT:-20} stage e2e e2e
    ;;
  verify|verify-ko)
    default='build unit e2e e2e-ko ts'
    [[ ${1:-} == verify-ko ]] && default='build unit-ko e2e-ko lint verus'
    for name in ${STAGES:-$default}; do
      case $name in
        build)
          if [[ ${1:-} == verify-ko ]]; then stage build make build-ko; else stage build dune build; fi ;;
        unit) stage unit env KO_CHECK_CONTRACTS=true dune test --force ;;
        e2e) stage e2e e2e ;;
        unit-ko) stage unit-ko make test-ko ;;
        lint) stage lint make lint-ko ;;
        verus) stage verus verus ;;
        e2e-ko) stage e2e-ko make e2e-ko ;;
        ts) stage ts ./scripts/test-ts.sh ;;
        *) echo "Unknown stage: $name" >&2; status=1 ;;
      esac
    done
    ;;
  *) exit 1 ;;
esac
exit "$status"
