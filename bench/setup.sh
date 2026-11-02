# Sourced by the bench scripts: builds the helpers and sets root, streams, coordinator and deadline.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
make build-bench
streams="$root/bench/streams/text.vt $root/bench/streams/ls.vt $root/bench/streams/gitlog.vt $root/bench/streams/yes.vt $root/bench/streams/tui.vt $root/bench/streams/osc8.vt $root/bench/streams/shell.vt"
coordinator=target/release/ko-bench
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
