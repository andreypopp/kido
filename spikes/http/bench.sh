#!/bin/sh
# usage: spikes/http/bench.sh [server flags --] [client flags]
# Runs server.exe on a scratch socket and the Go client against it.
# The whole run ends after $DEADLINE seconds (default 120).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d /tmp/kohttp-XXXXXX)
pid=""
watchdog=""
trap '[ -n "$watchdog" ] && pkill -P "$watchdog"; kill $pid $watchdog 2>/dev/null || true; rm -rf "$scratch"' EXIT
server_args=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do server_args="$server_args $1"; shift; done
[ $# -gt 0 ] && shift
(cd "$root" && dune build spikes/http/server.exe)
(cd "$root/spikes/http/client" && go build -o "$scratch/client" .)
# shellcheck disable=SC2086
"$root/_build/default/spikes/http/server.exe" --socket "$scratch/socket" $server_args >"$scratch/server.log" 2>&1 &
pid=$!
(sleep "${DEADLINE:-120}"; touch "$scratch/deadline"; kill "$pid"; pkill -f "$scratch/client") >/dev/null 2>&1 &
watchdog=$!
i=0
while [ ! -S "$scratch/socket" ]; do
  i=$((i + 1))
  [ $i -gt 100 ] && { cat "$scratch/server.log"; echo "server did not start" >&2; exit 1; }
  sleep 0.05
done
status=0
"$scratch/client" -socket "$scratch/socket" "$@" || status=$?
grep -v '^listening' "$scratch/server.log" || true
[ -e "$scratch/deadline" ] && { echo "bench.sh: deadline of ${DEADLINE:-120}s passed" >&2; status=1; }
exit $status
