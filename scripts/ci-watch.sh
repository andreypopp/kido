#!/bin/sh
# ci-watch.sh [sha]: wait for the GitHub Actions run of a commit (default
# HEAD) and exit with its status. Prints each job's conclusion; on failure
# also the failing test lines, with the suite's known noise filtered out.
# Meant to run in the background: kido async_bash -- scripts/ci-watch.sh
set -eu

sha=$(git rev-parse "${1:-HEAD}")
short=$(git rev-parse --short "$sha")

id=
i=0
while [ -z "$id" ]; do
	id=$(gh run list --commit "$sha" --json databaseId,url -q '.[0] | select(. != null) | "\(.databaseId) \(.url)"' 2>/dev/null || true)
	[ -n "$id" ] && break
	i=$((i + 1))
	if [ $i -ge 30 ]; then
		echo "no CI run for $short after 5 minutes" >&2
		exit 2
	fi
	sleep 10
done
url=${id#* }
id=${id%% *}
# OSC 8: the run id is a link to the run in a terminal that draws them,
# underlined and blue so it reads as one.
printf '%s: run \033]8;;%s\033\\\033[4;34m%s\033[0m\033]8;;\033\\\n' "$short" "$url" "$id"

rc=0
gh run watch "$id" --exit-status >/dev/null 2>&1 || rc=$?
gh run view "$id" --json jobs -q '.jobs[] | "\(.name): \(.conclusion)"'
if [ $rc -ne 0 ]; then
	gh run view "$id" --log-failed 2>/dev/null |
		grep -E -- '--- FAIL|FAIL:|panic:|Error' |
		grep -v -E 'conn_test|measured|older-than|no-unattended|no-zsh|DEBUG' |
		head -40
fi
exit $rc
