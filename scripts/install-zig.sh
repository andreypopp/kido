#!/usr/bin/env bash
# Install the pinned zig release into the given prefix, as <prefix>/zig.
# ko_vt_sys/build.rs builds libghostty-vt with it, so it must be on PATH.
# The pin is the exact release that third_party/ghostty/build.zig.zon names
# as .minimum_zig_version; lint checks that they agree.
#
# Usage: scripts/install-zig.sh <prefix>
#        scripts/install-zig.sh --print-key
#
# --print-key prints <release>-<git hash-object of this script>, the cache key
# of an install.
#
# Requires: curl, tar with xz, shasum or sha256sum.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
release=0.17.1

if [ "${1:-}" = "--print-key" ]; then
	printf '%s-%s\n' "$release" "$(git hash-object "$script_dir/install-zig.sh")"
	exit 0
fi
prefix=${1:?"usage: $0 <prefix>"}

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) platform=aarch64-macos sum=75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d ;;
	Darwin-x86_64) platform=x86_64-macos sum=9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7 ;;
	Linux-x86_64) platform=x86_64-linux sum=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;;
	Linux-aarch64 | Linux-arm64) platform=aarch64-linux sum=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;;
	*) echo "install-zig.sh: no zig release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM
archive="$workdir/zig.tar.xz"
curl -fL --connect-timeout 15 --max-time 900 \
	"https://ziglang.org/download/$release/zig-$platform-$release.tar.xz" -o "$archive"
if command -v sha256sum >/dev/null; then
	echo "$sum  $archive" | sha256sum -c -
else
	echo "$sum  $archive" | shasum -a 256 -c -
fi
tar -xJf "$archive" -C "$workdir"
"$workdir/zig-$platform-$release/zig" version | grep -qx "$release"
rm -rf "$prefix"
mkdir -p "$(dirname "$prefix")"
mv "$workdir/zig-$platform-$release" "$prefix"
echo "installed zig $release into $prefix" >&2
