#!/bin/sh
# Claude Code hook: records this session's activity state for the kido sidebar.
# Registered for several events; dispatches on hook_event_name from stdin.
# Must never fail or block: always exits 0.

dir="${KIDO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kido}"
mkdir -p "$dir" 2>/dev/null || exit 0

input=$(cat 2>/dev/null)

# Minimal JSON field extraction; the payload is single-line JSON from claude.
field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

event=$(field hook_event_name)
session=$(field session_id)
cwd=$(field cwd)
[ -n "$session" ] || exit 0
file="$dir/$session.json"

case "$event" in
  SessionEnd) rm -f "$file"; exit 0 ;;
  UserPromptSubmit|PreToolUse|PostToolUse|PostToolUseFailure) status=running ;;
  SessionStart|Stop) status=idle ;;
  PermissionRequest|Elicitation) status=waiting ;;
  Notification)
    case "$(field notification_type)" in
      permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input) status=waiting ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp="$file.tmp.$$"
printf '{"session_id":"%s","pane":"%s","pid":%d,"cwd":"%s","status":"%s","event":"%s","ts":"%s"}\n' \
  "$session" "${TMUX_PANE:-}" "${PPID:-0}" "$cwd" "$status" "$event" "$ts" > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$file" 2>/dev/null
exit 0
