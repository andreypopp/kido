#!/bin/sh
# Runs inside the VM, started by `make visual` through `kido-vm exec` in the app directory.
set -eo pipefail
settings=$1
stress_tests=$2
shift 2
server=/tmp/ka-visual-vm
rm -rf "$server"
mkdir -p "$server"
trap '../build/ko/bin/ko kill-server --server "$server" 2>/dev/null || true; rm -rf "$server"' EXIT
derived=build/xcode.noindex/derived-visual
# The first run of a binary from the share takes seconds, longer than a test waits.
/usr/bin/python3 -I -c 0 & /opt/homebrew/bin/node -e 0 & wait
xcodebuild -project Kido.xcodeproj -scheme Visual -configuration Debug -destination platform=macOS -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$PWD/$derived/SourcePackages" -disableAutomaticPackageResolution $settings KOA_STRESS_TESTS="$stress_tests" "$@" test-without-building 2>&1 |
	awk '/^[^ \t]/ { print; fflush() }'
python3 scripts/quit-check.py "$PWD/$derived/Build/Products/Debug/Kido.app"
