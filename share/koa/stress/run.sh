#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
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
case "$mode" in
  table) ;;
  page) shift; node "$root/share/koa/stress/run.ts" "$@" || status=$? ;;
  kido) make -C "$root/app" koa-stress || status=$? ;;
  all) node "$root/share/koa/stress/run.ts" || status=$?; make -C "$root/app" koa-stress || status=$? ;;
  *) echo 'usage: run.sh [all|page [ID ...]|kido|table]' >&2; exit 2 ;;
esac
node "$root/share/koa/stress/report.ts" || status=$?
exit "$status"
