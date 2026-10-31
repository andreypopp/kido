#!/usr/bin/env bash
# Install the pinned F* binary release, which ships Pulse, Karamel (krml) and
# Z3, into the given prefix, as <prefix>/bin/fstar.exe and <prefix>/bin/krml.
# Used by `make proofs` (ko_proofs/extract.sh) and its CI job.
#
# Usage: scripts/install-fstar.sh <prefix>
#        scripts/install-fstar.sh --print-key
#
# --print-key prints <release>-<git hash-object of this script>, the cache key
# of an install: the Makefile installs into build/fstar/<key> and keeps the
# .checked files in build/fstar-checked/<key>.
#
# Requires: curl, tar, shasum or sha256sum.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
release=v2026.10.25
fstar_commit=362e792b3aa882f1766b95c7450e3fe63081163d
krml_commit=98ffca53b25c8ac50f303dae87c083de65cc1db8
z3=z3-5.3.0

if [ "${1:-}" = "--print-key" ]; then
	printf '%s-%s\n' "$release" "$(git hash-object "$script_dir/install-fstar.sh")"
	exit 0
fi
prefix=${1:?"usage: $0 <prefix>"}

case "$(uname -s)-$(uname -m)" in
	Darwin-arm64) platform=Darwin-arm64 sum=cdd215b977380b7b0b3c8a5e628a556042789406d8684128e4e074a3d2ecf1e1 ;;
	Darwin-x86_64) platform=Darwin-x86_64 sum=0f9bcbbca4e9e3cc6dda0bf70bfaef0775f7891dfb7da4b8964e066cb835a40d ;;
	Linux-x86_64) platform=Linux-x86_64 sum=a716153960545bc26b9d093f55614fedc716a202e4daa1665e5c63e4a2fb04e4 ;;
	Linux-aarch64 | Linux-arm64) platform=Linux-aarch64 sum=38050095f5027fa1a81f2d4416683b95323a2849c4a29f619a46770b9038177c ;;
	*) echo "install-fstar.sh: no F* release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM
archive="$workdir/fstar.tar.gz"
curl -fL --connect-timeout 15 --max-time 900 \
	"https://github.com/FStarLang/FStar/releases/download/$release/fstar-$release-$platform.tar.gz" -o "$archive"
if command -v sha256sum >/dev/null; then
	echo "$sum  $archive" | sha256sum -c -
else
	echo "$sum  $archive" | shasum -a 256 -c -
fi
tar -xzf "$archive" -C "$workdir"
"$workdir/fstar/bin/fstar.exe" --version | grep -q "commit=$fstar_commit"
"$workdir/fstar/bin/krml" -version | grep -q "$krml_commit"
test -x "$workdir/fstar/lib/fstar/$z3/bin/z3"
rm -rf "$prefix"
mkdir -p "$(dirname "$prefix")"
mv "$workdir/fstar" "$prefix"
echo "installed F* $release into $prefix" >&2
