#!/usr/bin/env bash
# Usage: scripts/main-watch.sh [commit...]
# Prints each new commit's CI result and failure lines.
# Meant to run streamed: async_bash with stream: true.
cd "$(dirname "$0")/.." || exit 1
pending=()
fetched=
for c in "$@"; do
	if ! sha=$(git rev-parse --verify "$c^{commit}" 2>/dev/null); then
		if [ -z "$fetched" ]; then
			git fetch -q origin 2>/dev/null
			fetched=1
		fi
		sha=$(git rev-parse --verify "$c^{commit}" 2>/dev/null) || {
			printf 'main-watch: cannot resolve commit %s\n' "$c" >&2
			exit 1
		}
	fi
	pending+=("$sha")
done
peer=$(python3 - <<'PY'
import json, os, pathlib, re
try:
    own = pathlib.Path(os.environ['KIDO_AGENT_TASK_FILE']).parent
    runs = own.parent
    meta = json.loads((own / 'meta.json').read_text())
    parent = meta['parentSession'] if meta['kind'] == 'bash' else ''
except (KeyError, OSError, ValueError):
    parent = ''
if parent:
    for path in runs.glob('*/meta.json'):
        try:
            peer = json.loads(path.read_text())
            if path.parent == own or peer['parentSession'] != parent or peer['kind'] != 'bash' or peer['pid'] <= 0 or (path.parent / 'outcome').exists():
                continue
            command = json.loads((path.parent / 'command').read_text())
            if not any(re.search(r'''(^|[\s/'"])scripts/main-watch\.sh($|[\s;'"&|])''', arg) for arg in command):
                continue
            os.kill(peer['pid'], 0)
            print(path.parent.name)
            break
        except (KeyError, OSError, ValueError):
            continue
PY
)
if [ -n "$peer" ]; then
	echo "main-watch already running (run $peer)"
	exit 0
fi
last=$(git ls-remote origin refs/heads/main | cut -f1)
echo "watching origin/main from ${last:0:7}"

report() {
	local sha=$1 run status conclusion url title metadata jobs failed log report
	report=$(gh run list --commit "$sha" --workflow ci.yml --limit 1 \
		--json databaseId,status,conclusion,url,displayTitle -q '.[0] | "\(.databaseId) \(.status) \(.conclusion) \(.url) \(.displayTitle)"' 2>/dev/null) || return 1
	read -r run status conclusion url title <<< "$report"
	[ -z "$run" ] || [ "$status" != completed ] && return 1
	jobs=$(gh run view "$run" --json jobs -q '.jobs[] | "    \(.name): \(.conclusion) (\u001b]8;;\(.url)\u001b\\\u001b[34mlink\u001b[39m\u001b]8;;\u001b\\)"' 2>/dev/null) || return 1
	[ -n "$jobs" ] || return 1
	if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
		git fetch -q origin 2>/dev/null
	fi
	metadata=$(git log -1 --format='at %cd by %an%n  %s' --date=format-local:'%Y-%m-%d %H:%M' "$sha" 2>/dev/null) || metadata="(metadata unavailable)"$'\n  '"$title"
	report="commit $(printf '\033]8;;%s\033\\\033[34m%s\033[39m\033]8;;\033\\' "${url%/actions/runs/*}/commit/$sha" "${sha:0:7}") $metadata
  CI run $(printf '\033]8;;%s\033\\\033[34m%s\033[39m\033]8;;\033\\' "$url" "$run"): $conclusion
$jobs"
	if [ "$conclusion" != success ]; then
		log=$(gh run view "$run" --log-failed 2>/dev/null) || return 1
		failed=$(printf '%s\n' "$log" | cut -f1,3- | sed -E 's/[0-9T:.-]+Z //' |
			awk -F '\t' '
				{
					line = $0
					sub(/^[^\t]*\t[[:space:]]*/, "", line)
					split(line, words, /[[:space:]]+/)
					if (line ~ /^=== (RUN|PAUSE|CONT|NAME) /) {
						current[$1] = words[3]
						next
					}
					if (line ~ /^--- (FAIL|PASS|SKIP): /) {
						key = $1 SUBSEP words[3]
						if (words[2] == "FAIL:") {
							printf "%s", messages[key]
							print
						}
						delete messages[key]
						next
					}
					if (line ~ /_test\.go:[0-9]+:/) {
						key = $1 SUBSEP current[$1]
						messages[key] = messages[key] $0 "\n"
					} else if (line ~ /^(FAIL:|panic:|Error:|File ".*", line)|✖|AssertionError/)
						print
				}' | head -25 | sed 's/^/      /')
		[ -z "$failed" ] || report="$report
$failed"
	fi
	printf '%s\n' "$report"
	return 0
}

while :; do
	sleep 20
	cur=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
	if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
		git fetch -q origin main 2>/dev/null
		pending+=("$cur")
		last=$cur
	fi
	still=()
	for sha in "${pending[@]}"; do
		report "$sha" || still+=("$sha")
	done
	pending=("${still[@]}")
done
