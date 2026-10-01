#!/bin/sh
set -eu

app_root=$(cd "$(dirname "$0")/.." && pwd)
submodule="$app_root/third_party/ghostty"
revision=$(git -C "$submodule" rev-parse HEAD)
source_hash=$({
	git -C "$submodule" diff HEAD --binary
	git -C "$submodule" ls-files --others --exclude-standard | while IFS= read -r file; do
		shasum "$submodule/$file"
	done
} | shasum | cut -c1-12)
flags="-Doptimize=${GHOSTTY_OPTIMIZE:-ReleaseFast} -Dsentry=false -Di18n=false"
out="$app_root/build/ghosttykit/$revision-$source_hash-$(printf %s "$flags" | shasum | cut -c1-12)"

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
