#!/bin/sh
# Kill, recreate and attach to the patched-tmux test server with a
# 50-session layout for kido. Run it from a terminal outside tmux:
#
#   scripts/side-testbed.sh            # kill && start && attach
#   scripts/side-testbed.sh --no-attach
#
# Env: TMUX_SIDE_BIN (default ~/.local/tmux-side/bin/tmux), SOCKET (default side)

set -e
T="${TMUX_SIDE_BIN:-$HOME/.local/tmux-side/bin/tmux}"
L="${SOCKET:-side}"
here=$(cd "$(dirname "$0")/.." && pwd)
cwd="$here"

"$T" -L "$L" kill-server 2>/dev/null || true
sleep 1
TMUX= "$T" -L "$L" -f "$here/tmux/kido-side.tmux" new-session -d -s try -x 239 -y 57 -c "$cwd"

names="api web worker db cache auth billing search mail notify infra ci docs design ops sre data ml etl bench proxy gateway edge cdn dns vpn backup logs metrics trace alerts sandbox staging prod canary demo lab notes blog shop cart pay ship stock admin support crm hr legal finance"
i=0
for s in $names; do
  i=$((i+1)); "$T" -L "$L" new-session -d -s "$s" -x 200 -y 50 -c "$cwd"; w="$s:0"
  case $((i % 6)) in
    0) "$T" -L "$L" split-window -h -t "$w" 'sleep 100000' \; split-window -v -t "$w" 'top -l 0 -s 5' \; select-pane -t "$w.0" \; split-window -v -t "$w" \; select-layout -t "$w" tiled \; new-window -t "$s" -n build 'sleep 100000' \; new-window -t "$s" -n logs 'tail -f /dev/null' \; select-window -t "$w" ;;
    1) "$T" -L "$L" split-window -h -t "$w" 'sleep 100000' ;;
    2) "$T" -L "$L" split-window -h -l 60 -t "$w" \; split-window -v -t "$w" 'sleep 100000' \; select-pane -t "$w.0" \; rename-window -t "$w" edit ;;
    3) "$T" -L "$L" split-window -v -t "$w" \; split-window -v -t "$w" \; split-window -v -t "$w" 'ping -i 5 127.0.0.1' \; split-window -v -t "$w" \; select-layout -t "$w" even-vertical \; new-window -t "$s" -n shell ;;
    4) "$T" -L "$L" rename-window -t "$w" main ;;
    5) "$T" -L "$L" split-window -h -t "$w" \; split-window -h -t "$w" 'sleep 100000' \; select-layout -t "$w" main-horizontal \; new-window -t "$s" -n w2 \; new-window -t "$s" -n w3 'sleep 100000' \; new-window -t "$s" -n w4 \; select-window -t "$w" ;;
  esac
done

echo "server '$L': $("$T" -L "$L" list-sessions | wc -l | tr -d ' ') sessions, $("$T" -L "$L" list-windows -a | wc -l | tr -d ' ') windows, $("$T" -L "$L" list-panes -a | wc -l | tr -d ' ') panes"
if [ "$1" = --no-attach ]; then
  echo "attach with: unset TMUX; $T -L $L attach -t try"
  exit 0
fi
unset TMUX
exec "$T" -L "$L" attach -t try
