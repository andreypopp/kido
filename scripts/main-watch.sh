#!/usr/bin/env bash
# Prints origin/main moves and each new commit's CI result and failure lines.
# Meant to run streamed: async_bash with stream: true.
cd "$(dirname "$0")/.." || exit 1
last=$(git ls-remote origin refs/heads/main | cut -f1)
echo "watching origin/main from ${last:0:7}"
pending=(${KIDO_WATCH_PENDING:-})

report() {
	local sha=$1 run status conclusion jobs failed log report
	report=$(gh run list --commit "$sha" --workflow ci.yml --limit 1 \
		--json databaseId,status,conclusion -q '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null) || return 1
	read -r run status conclusion <<< "$report"
	[ -z "$run" ] || [ "$status" != completed ] && return 1
	jobs=$(gh run view "$run" --json jobs -q '.jobs[] | "  \(.name): \(.conclusion)"' 2>/dev/null) || return 1
	[ -n "$jobs" ] || return 1
	report="CI ${sha:0:7}: $conclusion (run $run)
$jobs"
	if [ "$conclusion" != success ]; then
		log=$(gh run view "$run" --log-failed 2>/dev/null) || return 1
		failed=$(printf '%s\n' "$log" | cut -f1,3- | sed -E 's/[0-9T:.-]+Z //' |
			grep -E -- '--- FAIL|FAIL:|panic:|Error|_test\.go:[0-9]+:|✖|AssertionError' |
			grep -v -E 'conn_test|measured|older-than|no-unattended|no-zsh|DEBUG' | head -25)
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
		echo "origin/main moved ${last:0:7} -> ${cur:0:7}:"
		git log --format='  %h %an: %s' "$last..$cur" 2>/dev/null || echo "  (history rewritten?)"
		pending+=("$cur")
		last=$cur
	fi
	still=()
	for sha in "${pending[@]}"; do
		report "$sha" || still+=("$sha")
	done
	pending=("${still[@]}")
done
