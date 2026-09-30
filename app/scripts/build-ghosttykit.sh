#!/bin/sh
# Build GhosttyKit.xcframework from the ghostty fork at app/third_party/ghostty
# into app/build/ghosttykit/<pinned revision>-<flags hash>/, once per revision
# and flags, and print its path. $GHOSTTY_OPTIMIZE picks the zig optimize mode
# (default ReleaseFast). Builds in place: every product lands in paths
# the fork gitignores.

set -eu

app_root=$(cd "$(dirname "$0")/.." && pwd)
submodule="$app_root/third_party/ghostty"
revision=$(git -C "$app_root" ls-files -s third_party/ghostty | awk '{print $2}')
flags="-Doptimize=${GHOSTTY_OPTIMIZE:-ReleaseFast} -Dsentry=false -Di18n=false"
out="$app_root/build/ghosttykit/$revision-$(printf %s "$flags" | shasum | cut -c1-12)"

if [ ! -e "$out/GhosttyKit.xcframework" ]; then
	if [ ! -e "$submodule/build.zig" ]; then
		echo "build-ghosttykit.sh: $submodule is empty; run git submodule update --init" >&2
		exit 1
	fi
	DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
	export DEVELOPER_DIR
	prefix=$(mktemp -d)
	trap 'rm -rf "$prefix"' EXIT INT TERM
	(cd "$submodule" && zig build -p "$prefix" \
		-Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native $flags)
	mkdir -p "$out.tmp"
	rm -rf "$out.tmp/GhosttyKit.xcframework"
	cp -R "$submodule/macos/GhosttyKit.xcframework" "$out.tmp/"
	mv "$out.tmp" "$out"
fi

echo "$out/GhosttyKit.xcframework"
