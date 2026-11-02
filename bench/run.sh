#!/bin/sh
# Spike 1 and 2 numbers. BYTES defaults to 1 GiB.
set -eu
bytes=${BYTES:-1073741824}
. "$(dirname "$0")/setup.sh"
b=build/bench
run() { deadline 600 "$@" 2>&1 | grep -v '^drain '; }
echo "== control: pty -> plain copier -> socketpair -> drain"
run $b/pty_read socket $b/drain "$root/$b/produce" "$bytes" $streams
echo "== ko-pane ring -> coordinator view write -> socketpair -> drain"
run "$coordinator" throughput writev "$bytes" 2 $streams
echo "== vt_write in process, mixed corpus and each stream"
$b/parse 268435456 65536 $streams
for f in $streams; do $b/parse 67108864 65536 "$f" | tail -1 | sed "s|^|$(basename "$f") |"; done
echo "== hop latency, pty byte to view client read"
run "$coordinator" latency writev 5000 2
echo "== snapshots through the ring"
run "$coordinator" snapshot writev 10000
run "$coordinator" snapshot writev 100000
echo "== snapshots in process, mirror determinism"
deadline 600 "$coordinator" mirror 2000 $streams
echo "== macOS pty probes"
$b/wait_master
run "$coordinator" cpu-check
