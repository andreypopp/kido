#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. ./koa/scripts/node.sh
if node_ok; then
	:
else
	status=$?
	if [ "$status" = 1 ]; then exit 0; fi
	exit 1
fi
make -C koa node_modules/.package-lock.json
koa/node_modules/.bin/tsc --ignoreConfig --strict --noEmit --module NodeNext --moduleResolution NodeNext \
	--target ES2024 --allowImportingTsExtensions --erasableSyntaxOnly --skipLibCheck \
	--typeRoots ./koa/node_modules/@types --types node .pi/tests/no-git-writes.test.ts
exec scripts/quiet-limit 180 -- node --test --test-timeout=60000 .pi/tests/no-git-writes.test.ts
