#!/bin/sh
# Spike 1 and 2 numbers. BYTES defaults to 1 GiB.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bytes=${BYTES:-1073741824}
cd "$root"
dune build ko_pane/ko-pane spikes/coordinator.exe spikes/wait_master.exe \
  bench/produce.exe bench/drain.exe bench/pty_read.exe bench/parse.exe bench/mirror.exe
build=$root/_build/default
s=$root/bench/streams
streams="$s/text.vt $s/ls.vt $s/gitlog.vt $s/yes.vt $s/tui.vt $s/osc8.vt $s/shell.vt"
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
run() { deadline 600 "$@" 2>&1 | grep -v '^drain '; }
cd "$build"
echo "== control: pty -> plain copier -> socketpair -> drain"
run ./bench/pty_read.exe socket ./bench/drain.exe "$build/bench/produce.exe" "$bytes" $streams
echo "== ko-pane ring -> coordinator view write -> socketpair -> drain"
for view in luv-write writev; do
  run ./spikes/coordinator.exe throughput $view "$bytes" callbacks 2 $streams
done
run ./spikes/coordinator.exe throughput writev "$bytes" callbacks 0 $streams
run ./spikes/coordinator.exe throughput writev "$bytes" no-callbacks 2 $streams
echo "== vt_write in process, mixed corpus and each stream"
./bench/parse.exe 268435456 65536 $streams
for f in $streams; do ./bench/parse.exe 67108864 65536 "$f" | tail -1 | sed "s|^|$(basename "$f") |"; done
echo "== hop latency, pty byte to coordinator write"
run ./spikes/coordinator.exe latency luv-write 5000 0
run ./spikes/coordinator.exe latency writev 5000 0
echo "== snapshots through the ring"
run ./spikes/coordinator.exe snapshot writev 10000
run ./spikes/coordinator.exe snapshot writev 100000
echo "== snapshots in process, mirror determinism"
deadline 600 ./bench/mirror.exe 2000 $streams
echo "== macOS pty probes"
./spikes/wait_master.exe
run ./spikes/coordinator.exe pty-pipe
run ./spikes/coordinator.exe allocation
run ./spikes/coordinator.exe cpu-check
