#!/bin/bash
# KidoDev.app on a private kido server in $KIDO_DEMO_DIR, with a fixed layout and fake agents.
#   demo.sh <app binary>   start the server if needed, populate it, launch the app
#   demo.sh stop           kill the demo server
set -e
D=${KIDO_DEMO_DIR:?}
export XDG_STATE_HOME=$D/state
unset KIDO_STATE_DIR
unset KIDO_TMUX
unset TMUX TMUX_PANE KIDO_AGENT_PARENT_SESSION KIDO_AGENT_DEPTH KIDO_AGENT_TASK_FILE KIDO_AGENT_PARENT_PID KIDO_AGENT_RUN_ID
APP=${2:-$1}
PREFIX=$(cd "$(dirname "$APP")/../Resources/kido" && pwd)
K=$PREFIX/bin/kido
SERVER=$XDG_STATE_HOME/kido-app
S=$SERVER/socket
t() { "$PREFIX/bin/kido-tmux" -S "$S" "$@"; }

case $1 in
stop) t kill-server; exit ;;
esac

mkdir -p "$D/state" && chmod 700 "$D"
if ! t has-session -t main:kido 2>/dev/null; then
  t kill-server 2>/dev/null || true
  "$K" server --server "$SERVER"
  t rename-window -t main: kido
  t split-window -d -h -t main:kido
  t new-window -d -t main -n web
  t split-window -d -h -t main:web
  t split-window -d -v -t main:web
  t send-keys -t main:web.0 "top -o cpu" Enter
  t new-session -d -s research -n notes
  t new-window -d -t research -n deep
  t new-session -d -s ops -n logs
  t send-keys -t ops:logs "tail -f /var/log/system.log" Enter
  t set-option -g history-limit 1100000
  cat > "$D/log.awk" <<'AWK'
BEGIN {
  for (i = 1; i <= lines; i++) {
    level = i % 4999 == 0 ? "\033[31mERROR" : i % 997 == 0 ? "\033[33mWARN" : "\033[32mINFO"
    text = sprintf("built module-%03d in %dms", i % 256, 10 + i % 190)
    if (i % 10000 == 0) text = text " dependencies=" sprintf("%0300d", i)
    if (i == 10) text = "DEMO-MARKER near top"
    if (i == int(lines / 2)) text = "DEMO-MARKER middle"
    if (i == lines - 10) text = "DEMO-MARKER near bottom"
    printf "2026-10-01 %02d:%02d:%02d %s\033[0m [%07d] %s\n", int(i / 3600) % 24, int(i / 60) % 60, i % 60, level, i, text
  }
}
AWK
  for size in 1m 100k; do
    case $size in 1m) lines=1000000 ;; 100k) lines=100000 ;; esac
    t new-window -d -t ops -n "log-$size"
    t send-keys -t "ops:log-$size" "awk -v lines=$lines -f '$D/log.awk'" Enter
  done
  KIDO_STATE_DIR=$SERVER "$K" run --session main --name build -- sleep 3600 >/dev/null
  cat > "$D/pi-agent.sh" <<'SH'
#!/bin/sh
tmux set-option -p -t "$TMUX_PANE" @kido_session "$1"
tmux set-option -p -t "$TMUX_PANE" @kido_name "$3"
tmux set-option -p -t "$TMUX_PANE" @kido_activity "$2"
printf '\033]2;%s\007' "$3"
shift 3
for record in "$@"; do printf '\033]7501;%s\007' "$record"; done
sleep 86400
SH
  chmod +x "$D/pi-agent.sh"
  t set-option -p -t main:kido.0 @kido_session demo-kido
  t set-option -p -t main:kido.0 @kido_name 'π kido'
  t set-option -p -t main:kido.0 @kido_activity 'fixing sidebar tests'
  t send-keys -t main:kido.0 "printf '\\033]2;π kido\\007\\033]7501;state=working:app=pi\\007\\033]7501;id=agent-a:state=working:title=SW52ZXN0aWdhdGUgc2lkZWJhciBsYXlvdXQ=:msg=Q29tcGFyaW5nIG5hdGl2ZSByb3cgbWVhc3VyZW1lbnRz\\007\\033]7501;id=agent-a/permission:state=blocked:kind=permission:title=QXBwcm92ZSB0ZXN0IGNvbW1hbmQ=:msg=TWF5IEkgcnVuIHRoZSBpbnRlZ3JhdGlvbiB0ZXN0cz8=\\007\\033]7501;id=agent-b:state=working:title=Q2hlY2sgdG9vbGJhciBnZW9tZXRyeQ==\\007\\033]7501;id=agent-c:state=working:title=UmV2aWV3IGFjY2Vzc2liaWxpdHk=\\007'; sleep 86400" Enter
  kido_pane=$(t display-message -p -t main:kido.0 '#{pane_id}')
  deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    case $(t display-message -p -t main:kido.0 '#{pane_program_status}') in
    *'"app":"pi"'*) break ;;
    esac
    sleep 0.1
  done
  KIDO_STATE_DIR=$SERVER "$K" run-child "$kido_pane" --session main --name review -- \
    "$D/pi-agent.sh" demo-review 'needs your answer' 'π review' 'state=blocked:app=pi:kind=question'
  KIDO_STATE_DIR=$SERVER "$K" run-child "$kido_pane" --session main --name tests -- \
    "$D/pi-agent.sh" demo-tests 'running e2e' 'π tests' 'state=working:app=pi'
  t send-keys -t research:notes "printf '\\033]2;✳ notes\\007\\033]7501;state=idle:app=claude-code\\007'; sleep 86400" Enter
  t set-option -p -t research:deep @kido_session demo-deep
  t set-option -p -t research:deep @kido_name 'π deep-dive'
  t set-option -p -t research:deep @kido_activity compacting
  t send-keys -t research:deep "printf '\\033]2;π deep-dive\\007\\033]7501;state=working:app=pi\\007'; sleep 86400" Enter
fi
t select-window -t main:kido
export KIDO_APP_DEBUG=1
printf '\n=== %s launch %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$APP" >>"$D/app.log"
exec "$APP" >>"$D/app.log" 2>&1
