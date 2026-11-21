#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
repo=$(cd .. && pwd)
mode=$1
shift
failed=0
if [ "$mode" = lint ]; then python3 scripts/lint.py || failed=1; fi
. ./scripts/node.sh
if node_ok; then
	:
else
	status=$?
	if [ "$status" = 2 ]; then failed=1; fi
	exit "$failed"
fi
make --no-print-directory node_modules/.package-lock.json
case "$mode" in
typecheck)
	./node_modules/.bin/tsc -p page
	exec ./node_modules/.bin/tsc -p .
	;;
lint|prompts)
	scratch=$(mktemp)
	trap 'rm -f "$scratch"' EXIT
	if ! ../scripts/quiet-limit 180 -- node scripts/dump-prompts.ts > "$scratch"; then
		failed=1
	elif [ "$mode" = prompts ]; then
		cp "$scratch" testdata/ko-prompts.txt
	else
		diff -u testdata/ko-prompts.txt "$scratch" || {
			echo 'koa/testdata/ko-prompts.txt:1: prompt snapshot differs; regenerate: make -C koa prompts'
			failed=1
		}
		if [ "$failed" = 0 ]; then echo 'koa lint: PASS'; fi
	fi
	exit "$failed"
	;;
test) ;;
*) echo "unknown check: $mode" >&2; exit 1 ;;
esac
make --no-print-directory -C "$repo" build-fake-ko
KO_FAKE_KO="$repo/target/debug/fake_ko"
export KO_FAKE_KO
make --no-print-directory build
if [ "$#" -gt 0 ]; then
	exec ../scripts/quiet-limit 180 -- node --test --test-timeout=60000 --test-concurrency=4 --test-reporter=spec --test-reporter-destination=stdout --test-reporter=./testdata/start-reporter.mjs --test-reporter-destination=stdout "$@"
fi
set -- koa-program-lifecycle.test.ts koa-program-agents.test.ts koa-program-editor.test.ts koa-program-session.test.ts koa-webview-sdk.test.ts koa-program-job-view.test.ts koa-agent-runtime.test.ts koa-program-real.test.ts
for file in koa-*.test.ts agents.test.ts; do
	case " $* " in *" $file "*) ;; *) set -- "$@" "$file" ;; esac
done
exec ../scripts/quiet-limit 180 -- node ./testdata/run-tests.mjs "$@"
