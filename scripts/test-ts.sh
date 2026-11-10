#!/bin/sh
# Typecheck the pi extension and run its tests under node's native TypeScript support.
#
# Skips cleanly when node is missing or too old; KO_TS_TEST_REQUIRED=1
# fails instead, the same convention as verify.sh.
#
# The floor is node 24: 22.18 reads these files but its test runner then
# abandons the suite, cancelling most cases with "Promise resolution is
# still pending but the event loop has already resolved".

set -eu

fail_or_skip() {
	if [ "${KO_TS_TEST_REQUIRED:-}" = "1" ]; then
		echo "test-ts: $1" >&2
		exit 1
	fi
	echo "test-ts: skipping, $1" >&2
	exit 0
}

if ! command -v node >/dev/null 2>&1; then
	fail_or_skip "node not found on PATH"
fi

if ! node -e '
const [maj] = process.versions.node.split(".").map(Number);
process.exit(maj >= 24 ? 0 : 1);
'; then
	fail_or_skip "node $(node --version) is too old to run this suite (need >=24)"
fi

cd "$(dirname "$0")/../share/pi"
repo=$(cd ../.. && pwd)
make --no-print-directory -C "$repo" share/pi/node_modules/.package-lock.json share/koa/node_modules/.package-lock.json
if [ "${1:-}" = lint ]; then
	exec ../../scripts/lint.sh
fi
make --no-print-directory -C "$repo" build-fake-ko
KO_FAKE_KO="$repo/target/debug/fake_ko"
export KO_FAKE_KO
make -C ../.. koa-page
../koa/node_modules/.bin/tsc -p ../koa/page
../koa/node_modules/.bin/tsc -p .
../koa/node_modules/.bin/tsc --ignoreConfig --strict --noEmit --module NodeNext --moduleResolution NodeNext \
	--target ES2024 --allowImportingTsExtensions --erasableSyntaxOnly --skipLibCheck \
	--typeRoots ./node_modules/@types --types node ../../.pi/tests/no-git-writes.test.ts
if [ "$#" -gt 0 ]; then
	exec node --test --test-concurrency=4 --test-reporter=spec "$@"
fi
exec node --test --test-concurrency=4 --test-reporter=spec ko-pi-*.test.ts agents.test.ts ../koa/koa-*.test.ts ../../.pi/tests/no-git-writes.test.ts
