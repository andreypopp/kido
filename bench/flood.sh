#!/bin/sh
# Coordinator under flooding panes. PANES, BYTES (per pane) and WINDOWS are overridable.
set -eu
bytes=${BYTES:-134217728}
windows=${WINDOWS:-"2 8 16"}
counts=${PANES:-"5 20"}
views=${VIEWS:-all}
reps=${REPS:-2}
. "$(dirname "$0")/setup.sh"
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
