#!/bin/sh
# Coordinator under flooding panes. PANES, BYTES (per pane) and WINDOWS are overridable.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bytes=${BYTES:-134217728}
windows=${WINDOWS:-"2 8 16"}
counts=${PANES:-"5 20"}
views=${VIEWS:-all}
reps=${REPS:-2}
cd "$root"
dune build bench/coordinator.exe bench/produce.exe bench/drain.exe bench/latency_drain.exe ko_pane/ko-pane
s=$root/bench/streams
streams="$s/text.vt $s/ls.vt $s/gitlog.vt $s/yes.vt $s/tui.vt $s/osc8.vt $s/shell.vt"
cd "$root/_build/default"
. "$root/bench/coordinator.sh"
for count in $counts; do
  for window in $windows; do
    for rep in $(seq "$reps"); do
      echo "== panes=$count window=$window rep=$rep $(uptime | sed 's/.*load/load/')"
      shown=$views
      [ "$shown" = all ] && shown=$count
      perl -e 'alarm shift; exec @ARGV' 120 "$coordinator" flood "$count" "$shown" "$bytes" "$window" $streams 2>&1
    done
  done
done
