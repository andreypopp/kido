#!/bin/sh
# usage: [KO_BIN_REF=path/to/reference/ko] [CELLS="150:100 300:100"] [VARIANTS="none ssh-c deflate"] [RUNS=3] [ROWS=attach,plain,mixed,echo] bench/rtt.sh OUT.jsonl
# The RTT sweep: one cell at a time, the local floor first. A cell is "RTT_MS:MBIT" (0 = unlimited).
# Prints a progress line per measurement and the Markdown tables at the end. Every measurement has a
# deadline of 180 s and prints "timeout" past it.
set -eu
out=${1:?usage: bench/rtt.sh OUT.jsonl}
. "$(dirname "$0")/setup.sh"
make build
export KO_BIN="$root/build/ko/bin/ko"
cells=${CELLS:-"150:100 300:100 150:0 300:0 50:100 50:0 150:10 300:10 50:10"}
variants=${VARIANTS:-"none ssh-c deflate"}
runs=${RUNS:-3}
rows=${ROWS:-attach,plain,mixed,echo}
client="python3 -B bench/client.py"
echo "== local floor ($(uptime | sed 's/.*load/load/'))"
deadline 1800 $client rtt --rtt 0 --bw 0 --variant local --rows "$rows" --runs "$runs" --out "$out"
for cell in $cells; do
  for variant in $variants; do
    case $variant in none|ssh-c) [ -n "${KO_BIN_REF:-}" ] || { echo "SKIP $variant: KO_BIN_REF names no build without snapshot deflate"; continue; } ;; esac
    echo "== cell rtt=${cell%:*} ms bw=${cell#*:} Mbit/s variant=$variant ($(uptime | sed 's/.*load/load/'))"
    deadline 1800 $client rtt --rtt "${cell%:*}" --bw "${cell#*:}" --variant "$variant" --rows "$rows" --runs "$runs" --out "$out"
  done
done
$client rtt-table "$out"
