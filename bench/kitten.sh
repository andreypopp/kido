#!/bin/sh
# kitty's parser benchmark in ko-pane, a private tmux server and kitty. Opens kitty windows.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
kitten=${KITTEN:-/opt/homebrew/bin/kitten}
kitty=${KITTY:-/opt/homebrew/bin/kitty}
tmux=${TMUX_BIN:-/opt/homebrew/bin/tmux}
repetitions=${REPETITIONS:-500}
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
results() { grep -E '^ *(Only ASCII|Unicode chars|Unique multi|CSI codes|Long escape|Images).*: ' || true; }
cd "$root"
dune build bench/coordinator.exe ko_pane/ko-pane bench/drain.exe

echo "== ko-pane"
deadline 900 ./_build/default/bench/coordinator.exe run writev "$kitten" __benchmark__ --repetitions "$repetitions" 2>/dev/null | results

echo "== tmux $("$tmux" -V)"
dir=$(mktemp -d /tmp/ko-tmux-XXXXXX)
"$tmux" -S "$dir/socket" -f /dev/null new-session -d -x 120 -y 60 \
  "$kitten __benchmark__ --repetitions $repetitions; $tmux -S $dir/socket wait-for -S done; sleep 60"
deadline 900 "$tmux" -S "$dir/socket" wait-for done || echo "tmux run missed its deadline"
"$tmux" -S "$dir/socket" capture-pane -p -S - | results
"$tmux" -S "$dir/socket" kill-server
rm -rf "$dir"

for options in "" "-o input_delay=0 -o repaint_delay=2 -o sync_to_monitor=no"; do
  echo "== kitty $options"
  dir=$(mktemp -d /tmp/ko-kitty-XXXXXX)
  # shellcheck disable=SC2086
  "$kitty" --config NONE $options -o allow_remote_control=yes --listen-on "unix:$dir/socket" --hold \
    "$kitten" __benchmark__ --repetitions "$repetitions" >/dev/null 2>&1 &
  pid=$!
  text=""
  for _ in $(seq 1 900); do
    sleep 1
    text=$("$kitten" @ --to "unix:$dir/socket" get-text --extent all 2>/dev/null || true)
    echo "$text" | grep -qE '^ *Images +:' && break
  done
  echo "$text" | results
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir"
done
