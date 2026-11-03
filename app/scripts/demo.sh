#!/bin/bash
# KidoDev.app on a private ko server in $KIDO_DEMO_DIR, with a fixed layout and fake agents.
#   demo.sh <app binary>   start the server if needed, populate it, launch the app
#   demo.sh stop           kill the demo server
set -e
D=${KIDO_DEMO_DIR:?}
export XDG_STATE_HOME=$D/state
unset TMUX TMUX_PANE KO_PANE KO_SOCKET KO_SERVER
APP=${2:-$1}
KO=$(cd "$(dirname "$APP")/../Resources/ko/bin" && pwd)/ko
# The app's server directory: a Release build always uses $XDG_STATE_HOME/ko-app.
SERVER=$XDG_STATE_HOME/ko-app
k() { local command=$1; shift; "$KO" "$command" --server "$SERVER" "$@"; }

case $1 in
stop) k kill-server; exit ;;
esac

mkdir -p "$D/state" && chmod 700 "$D"
if ! k api /layout 2>/dev/null | grep -q '"name":"research"'; then
  k kill-server 2>/dev/null || true
  ("$KO" server --server "$SERVER" >>"$D/server.log" 2>&1 &)
  deadline=$((SECONDS + 10))
  until k api /version >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "demo: the ko server did not start" >&2; exit 1; }
    sleep 0.1
  done
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
  # A pi agent: its identity in pane variables, its title and status records on the terminal.
  cat > "$D/pi-agent.sh" <<'SH'
#!/bin/sh
for pair in "pi.session=$1" "pi.name=$3"; do
  printf '"%s"' "${pair#*=}" | "$KO" api -X PUT --input - "/panes/$KO_PANE/vars/${pair%%=*}" >/dev/null
done
printf '\033]2;%s\007' "$3"
shift 3
for record in "$@"; do printf '\033]7501;%s\007' "$record"; done
exec sleep 86400
SH
  chmod +x "$D/pi-agent.sh"
  python3 - "$D" "$KO" > "$D/layout.json" <<'PY'
import json, sys
d, ko = sys.argv[1:]
def pane(command=None, **env):
    new = {'command': {'type': 'shell', 'command': command}} if command else {}
    if env: new['env'] = [{'name': k, 'value': v} for k, v in env.items()]
    return {'pane': {'new': new}}
def agent(session, name, *records):
    return pane(f"{d}/pi-agent.sh {session} '' '{name}' " + ' '.join(f"'{r}'" for r in records), KO=ko)
kido = agent('demo-kido', 'π kido', 'state=working:app=pi',
             'id=agent-a:state=working:title=SW52ZXN0aWdhdGUgc2lkZWJhciBsYXlvdXQ=:msg=Q29tcGFyaW5nIG5hdGl2ZSByb3cgbWVhc3VyZW1lbnRz',
             'id=agent-a/permission:state=blocked:kind=permission:title=QXBwcm92ZSB0ZXN0IGNvbW1hbmQ=:msg=TWF5IEkgcnVuIHRoZSBpbnRlZ3JhdGlvbiB0ZXN0cz8=',
             'id=agent-b:state=working:title=Q2hlY2sgdG9vbGJhciBnZW9tZXRyeQ==',
             'id=agent-c:state=working:title=UmV2aWV3IGFjY2Vzc2liaWxpdHk=')
log = lambda lines: pane(f"awk -v lines={lines} -f '{d}/log.awk'; exec $SHELL")
print(json.dumps({'revision': 0, 'layout': {'sessions': [
    {'name': 'main', 'windows': [
        {'name': 'kido', 'tree': {'split': 'h', 'children': [kido, pane()]}},
        {'name': 'web', 'tree': {'split': 'h', 'children': [pane('top -o cpu'), {'split': 'v', 'children': [pane(), pane()]}]}}]},
    {'name': 'research', 'windows': [
        {'name': 'notes', 'tree': pane("printf '\\033]2;✳ notes\\007\\033]7501;state=idle:app=claude-code\\007'; exec sleep 86400")},
        {'name': 'deep', 'tree': agent('demo-deep', 'π deep-dive', 'state=working:app=pi')}]},
    {'name': 'ops', 'windows': [
        {'name': 'logs', 'tree': pane('tail -f /var/log/system.log')},
        {'name': 'log-1m', 'tree': log(1000000)},
        {'name': 'log-100k', 'tree': log(100000)}]}]}}))
PY
  k api -X PUT --input "$D/layout.json" /layout >/dev/null
  k run --session main --name build -- sleep 3600 >/dev/null
  kido_pane=$(k api /layout | python3 -c 'import json,sys; t=json.load(sys.stdin)["layout"]["sessions"][0]["windows"][0]["tree"]; print(t["children"][0]["pane"])')
  deadline=$((SECONDS + 10))
  until k api "/panes/$kido_pane/vars" 2>/dev/null | grep -q pi.session; do
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.1
  done
  KO=$KO k run-child "$kido_pane" --session main --name review --env KO="$KO" -- \
    "$D/pi-agent.sh" demo-review '' 'π review' 'state=blocked:app=pi:kind=question' >/dev/null
  KO=$KO k run-child "$kido_pane" --session main --name tests --env KO="$KO" -- \
    "$D/pi-agent.sh" demo-tests '' 'π tests' 'state=working:app=pi' >/dev/null
fi
export KIDO_APP_DEBUG=1
printf '\n=== %s launch %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$APP" >>"$D/app.log"
exec "$APP" >>"$D/app.log" 2>&1
