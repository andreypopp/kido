#!/bin/sh
# Where the time goes between the pty and a view, and the tmux and kitty baselines,
# on the same producer and stream. The kitty rows open kitty windows.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bytes=${BYTES:-1073741824}
kitty=${KITTY:-/opt/homebrew/bin/kitty}
tmux=${TMUX_BIN:-/opt/homebrew/bin/tmux}
cd "$root"
dune build ko_pane/ko-pane spikes/coordinator.exe bench/produce.exe bench/drain.exe bench/pty_read.exe bench/acker.exe
build=$root/_build/default
s=$root/bench/streams
streams="$s/text.vt $s/ls.vt $s/gitlog.vt $s/yes.vt $s/tui.vt $s/osc8.vt $s/shell.vt"
produce="$build/bench/produce.exe"
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
run() { deadline 900 "$@" 2>&1 | grep -v '^drain '; }
seconds() { awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else print $1 * 60 + $2 }'; }
cd "$build"

echo "== 1. raw pty, read until EAGAIN and discard"
run ./bench/pty_read.exe discard ./bench/drain.exe "$produce" "$bytes" $streams
echo "== 2. pty + vt_write in the reader"
run ./bench/pty_read.exe parse ./bench/drain.exe "$produce" "$bytes" $streams
echo "== 3. ko-pane + ring, C tail-acker"
run ./bench/acker.exe "$build/ko_pane/ko-pane" callbacks "$produce" "$bytes" $streams
echo "== 4. ko-pane + ring + coordinator (writev, 2 ms) + view socket + drain"
run ./spikes/coordinator.exe throughput writev "$bytes" callbacks 2 $streams
echo "== 5. control: pty -> copier -> socketpair -> drain"
run ./bench/pty_read.exe socket ./bench/drain.exe "$produce" "$bytes" $streams

echo "== 6. tmux $("$tmux" -V), detached private server"
dir=$(mktemp -d /tmp/ko-tmux-XXXXXX)
"$tmux" -S "$dir/socket" -f /dev/null new-session -d -x 80 -y 24 \
  "sleep 0.5; /usr/bin/time -p $produce $bytes $streams 2>$dir/time; $tmux -S $dir/socket wait-for -S done; sleep 60"
server=$("$tmux" -S "$dir/socket" display -p '#{pid}')
before=$(ps -o cputime= -p "$server" | seconds)
deadline 900 "$tmux" -S "$dir/socket" wait-for done || echo "tmux run missed its deadline"
after=$(ps -o cputime= -p "$server" | seconds)
"$tmux" -S "$dir/socket" kill-server
awk -v b="$bytes" -v cpu="$(echo "$after - $before" | bc)" \
  '/^real/ { printf "tmux bytes=%d seconds=%.3f MB/s=%.1f server_cpu=%.2f\n", b, $2, b / $2 / 1e6, cpu }' "$dir/time"
rm -rf "$dir"

for options in "" "-o input_delay=0 -o repaint_delay=2 -o sync_to_monitor=no"; do
  echo "== 6. kitty $options, a visible window, rendering on"
  dir=$(mktemp -d /tmp/ko-kitty-XXXXXX)
  # shellcheck disable=SC2086
  deadline 900 /usr/bin/time -l "$kitty" --config NONE -o macos_quit_when_last_window_closed=yes $options \
    sh -c "/usr/bin/time -p $produce $bytes $streams 2>$dir/time" 2>"$dir/kitty" >/dev/null || true
  awk -v b="$bytes" '
    FNR == NR && /^real/ { real = $2 } FNR == NR && /^(user|sys)/ { producer += $2 }
    FNR != NR && / real .* user .* sys/ { total = $3 + $5 }
    END { printf "kitty bytes=%d seconds=%.3f MB/s=%.1f kitty_cpu=%.2f (producer %.2f excluded)\n", b, real, b / real / 1e6, total - producer, producer }
  ' "$dir/time" "$dir/kitty"
  rm -rf "$dir"
done
