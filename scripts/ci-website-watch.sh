#!/usr/bin/env bash
# Usage: scripts/ci-website-watch.sh [commit...]
# Prints the website deploy result of each new commit on main that touches
# the website, with the failed steps' last lines.
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
			printf 'ci-website-watch: cannot resolve commit %s\n' "$c" >&2
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
            if not any(re.search(r'''(^|[\s/'"])scripts/ci-website-watch\.sh($|[\s;'"&|])''', arg) for arg in command):
                continue
            os.kill(peer['pid'], 0)
            print(path.parent.name)
            break
        except (KeyError, OSError, ValueError):
            continue
PY
)
if [ -n "$peer" ]; then
	echo "ci-website-watch already running (run $peer)"
	exit 0
fi
last=$(git ls-remote origin refs/heads/main | cut -f1)
echo "watching website deploys on origin/main from ${last:0:7}"

link() {
	printf '\033]8;;%s\033\\\033[34m%s\033[39m\033]8;;\033\\' "$1" "$2"
}

report() {
	local sha=$1 run status conclusion url title metadata failed
	read -r run status conclusion url title <<< "$(gh run list --commit "$sha" --workflow website.yml --limit 1 \
		--json databaseId,status,conclusion,url,displayTitle -q '.[0] | "\(.databaseId) \(.status) \(.conclusion) \(.url) \(.displayTitle)"' 2>/dev/null)"
	[ -z "$run" ] || [ "$status" != completed ] && return 1
	metadata=$(git log -1 --format='at %cd by %an%n  %s' --date=format-local:'%Y-%m-%d %H:%M' "$sha" 2>/dev/null) || metadata="(metadata unavailable)"$'\n  '"$title"
	printf 'commit %s %s\n  website deploy %s: %s\n' "$(link "${url%/actions/runs/*}/commit/$sha" "${sha:0:7}")" "$metadata" "$(link "$url" "$run")" "$conclusion"
	if [ "$conclusion" != success ]; then
		failed=$(gh run view "$run" --log-failed 2>/dev/null | cut -f3- | sed -E 's/^[0-9T:.-]+Z //' | tail -25 | sed 's/^/      /')
		[ -z "$failed" ] || printf '%s\n' "$failed"
	fi
}

touches_website() {
	git diff --name-only "$1" "$2" -- website .github/workflows/website.yml 2>/dev/null | grep -q .
}

while :; do
	sleep 20
	cur=$(git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
	if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
		git fetch -q origin main 2>/dev/null
		touches_website "$last" "$cur" && pending+=("$cur")
		last=$cur
	fi
	still=()
	for sha in "${pending[@]}"; do
		report "$sha" || still+=("$sha")
	done
	pending=("${still[@]}")
done
