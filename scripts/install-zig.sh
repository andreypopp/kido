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
release=0.17.0

if [ "${1:-}" = "--print-key" ]; then
	printf '%s-%s\n' "$release" "$(git hash-object "$script_dir/install-zig.sh")"
	exit 0
fi
prefix=${1:?"usage: $0 <prefix>"}

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) platform=aarch64-macos sum=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
	Darwin-x86_64) platform=x86_64-macos sum=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
	Linux-x86_64) platform=x86_64-linux sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
	Linux-aarch64 | Linux-arm64) platform=aarch64-linux sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
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
