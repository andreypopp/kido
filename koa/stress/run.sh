#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
mode=${1:-all}
if test "$mode" = table; then
  : "${KOA_STRESS_OUTPUT:?Set KOA_STRESS_OUTPUT to a completed run directory}"
else
  base=$(make -s --no-print-directory -C "$root/app" koa-stress-root)
  test -n "$base" || { echo 'KOA_STRESS_OUTPUT must not be empty' >&2; exit 2; }
  mkdir -p "$base"
  KOA_STRESS_OUTPUT=$(mktemp -d "$base/run-XXXXXX")
  KOA_STRESS_RUN=$KOA_STRESS_OUTPUT
  export KOA_STRESS_OUTPUT KOA_STRESS_RUN
  echo "koa stress run: $KOA_STRESS_OUTPUT"
fi
status=0
case "$mode" in table|kido) ;; *) make -s -C "$root/koa" build || exit 1 ;; esac
case "$mode" in
  table) ;;
  page) shift; node "$root/koa/stress/run.ts" "$@" || status=$? ;;
  kido) make -C "$root/app" koa-stress || status=$? ;;
  stream) node "$root/koa/stress/run.ts" 13 14 || status=$?; make -C "$root/app" koa-stress ONLY="KoaStressTests/testStreamingHistory KoaStressTests/testStreamingHistoryProbe KoaStressTests/testStreaming KoaStressTests/testStreamingProbe" KOA_STRESS_VISIBLE=1 || status=$? ;;
  all) node "$root/koa/stress/run.ts" || status=$?; make -C "$root/app" koa-stress || status=$? ;;
  *) echo 'usage: run.sh [all|page [ID ...]|kido|stream|table]' >&2; exit 2 ;;
esac
node "$root/koa/stress/report.ts" || status=$?
exit "$status"
