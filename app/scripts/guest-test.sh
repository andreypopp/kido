#!/bin/sh
set -eo pipefail
target=$1
shift
echo guest-test-start
t0=$(date +%s)
fmt() { echo "$target: $1 $(($2 / 60))m$(($2 % 60))s" >&2; }
# The first run of a binary from the share takes seconds, longer than a test waits.
/usr/bin/python3 -I -c 0 & /opt/homebrew/bin/node -e 0 & wait
status=0
case "$target" in
visual|ko-test)
	scheme=$1 derived=$2 server=$3 settings=$4
	shift 4
	rm -rf "$server"
	mkdir -p "$server"
	trap '"$KO_CHECKOUT/build/ko/bin/ko" kill-server --server "$server" 2>/dev/null || true; rm -rf "$server"' EXIT
	xcodebuild -project Kido.xcodeproj -scheme "$scheme" -configuration Debug -destination platform=macOS -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$PWD/$derived/SourcePackages" -disableAutomaticPackageResolution $settings "$@" test-without-building 2>&1 || status=$?
	fmt tests $(($(date +%s) - t0))
	case "$target" in
	visual)
		t1=$(date +%s)
		if test "$status" = 0; then python3 scripts/quit-check.py "$PWD/$derived/Build/Products/Debug/Kido.app" || status=$?; fi
		fmt quit-check $(($(date +%s) - t1)) ;;
	ko-test) python3 scripts/ko-test-leak-check.py "$server" || status=1 ;;
	esac ;;
app)
	for package in "$@"; do
		(cd "Packages/$package" && swift test --skip-build 2>&1) || { status=$?; break; }
	done
	fmt tests $(($(date +%s) - t0)) ;;
*)
	"$@" || status=$?
	fmt tests $(($(date +%s) - t0)) ;;
esac
exit "$status"
