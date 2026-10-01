#!/bin/bash
# Kido.app on a private kido server in $KIDO_DEMO_DIR, with a fixed layout and fake agents.
#   demo.sh <app binary>   start the server if needed, populate it, launch the app
#   demo.sh stop           kill the demo server
set -e
D=${KIDO_DEMO_DIR:?}
export TMUX_TMPDIR=$D KIDO_STATE_DIR=$D/state KIDO_TMUX KIDO_APP_KIDO
: "${KIDO_TMUX:?}" "${KIDO_APP_KIDO:?}"
unset TMUX TMUX_PANE KIDO_AGENT_PARENT_SESSION KIDO_AGENT_DEPTH KIDO_AGENT_TASK_FILE KIDO_AGENT_PARENT_PID KIDO_AGENT_RUN_ID
APP=$1
K=$KIDO_APP_KIDO
S=$D/tmux-$(id -u)/kido
t() { "$KIDO_TMUX" -S "$S" "$@"; }

case $1 in
stop) t kill-server; exit ;;
esac

mkdir -p "$D/state" && chmod 700 "$D"
if ! t has-session 2>/dev/null; then
  "$K" server
  sleep 1
  t rename-window -t main:1 kido
  t split-window -d -h -t main:kido
  t new-window -d -t main -n review
  t new-window -d -t main -n tests
  t split-window -d -v -t main:tests
  t new-window -d -t main -n web
  t split-window -d -h -t main:web
  t split-window -d -v -t main:web
  t send-keys -t main:web.0 "top -o cpu" Enter
  t new-session -d -s research -n notes
  t new-window -d -t research -n deep
  t new-session -d -s ops -n logs
  t send-keys -t ops:logs "tail -f /var/log/system.log" Enter
  t send-keys -t main:kido.0 "$K async_bash --name build -- sleep 3600" Enter
fi
# Agents are status records only; they turn stalled without heartbeats, so rerun to refresh.
t send-keys -t main:kido.0 "$K agent-status --agent pi --session demo-kido --status running --title kido --activity 'fixing sidebar tests'" Enter
t send-keys -t main:review "$K agent-status --agent pi --session demo-review --parent-session demo-kido --depth 1 --status waiting --title review --activity 'needs your answer'" Enter
t send-keys -t main:tests.0 "$K agent-status --agent pi --session demo-tests --parent-session demo-kido --depth 1 --status running --title tests --activity 'running e2e'" Enter
t send-keys -t research:notes "$K agent-status --agent claude --session demo-notes --status idle --title notes --activity 'wrote summary'" Enter
t send-keys -t research:deep "$K agent-status --agent pi --session demo-deep --status compacting --title deep-dive" Enter
t select-window -t main:kido
sleep 1
exec "$APP"
