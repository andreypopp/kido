#!/bin/sh
# Run share/pi/kido-status.test.ts under node's native TypeScript support.
#
# Skips cleanly when node is missing or too old; KIDO_TS_TEST_REQUIRED=1
# fails instead, the same convention e2e uses for KIDO_E2E_REQUIRED.
#
# The floor is node 24: 22.18 reads these files but its test runner then
# abandons the suite, cancelling most cases with "Promise resolution is
# still pending but the event loop has already resolved".

set -eu

fail_or_skip() {
	if [ "${KIDO_TS_TEST_REQUIRED:-}" = "1" ]; then
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
if [ ! -d node_modules ]; then
	npm install --silent
fi
exec node --test kido-status.test.ts
