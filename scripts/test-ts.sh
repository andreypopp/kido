#!/bin/sh
# Run pi/kido-status.test.ts under node's native TypeScript support. One
# suite covers both extensions: it drives kido-status.ts and kido-agents.ts
# as the pair a pi host loads, through one fake pi and one real inbox
# socket, and almost every case needs both halves at once.
#
# Skips cleanly when node is missing or too old; KIDO_TS_TEST_REQUIRED=1
# fails instead, the same convention e2e uses for KIDO_E2E_REQUIRED. `make
# test` calls this so the Go unit tests never gain a node dependency of
# their own.
#
# The floor is 24, not the 22.18 where unflagged TypeScript became stable.
# Parsing was never the binding constraint: 22.18 reads these files and
# then its test runner abandons the suite, cancelling 77 of 79 cases in
# half a second with "Promise resolution is still pending but the event
# loop has already resolved". CI pinned 22.18 on that reasoning and found
# it, which is the only reason the number here is one anything has checked.

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

cd "$(dirname "$0")/../pi"
if [ ! -d node_modules ]; then
	npm install --silent
fi
exec node --test kido-status.test.ts
