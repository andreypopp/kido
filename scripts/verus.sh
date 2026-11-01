#!/usr/bin/env bash
# Install the pinned Verus release archive (verus, cargo-verus and Z3) and verify
# the crates with `cargo verus verify`.
#
# Usage: scripts/verus.sh --print-key
#        scripts/verus.sh install <prefix>
#        scripts/verus.sh verify <prefix>
#
# --print-key prints the release, which is also the cache key of the archive.
# install downloads the archive into <prefix> unless <prefix>/verus exists.
# verify cleans the verified crates, so that Verus runs on them again, then runs
# cargo verus verify with $CARGO (the Makefile's cargo). It prints Verus's
# per-module times, fails without a "verification results" line for each crate,
# and fails over the cap. It prints SKIP and exits 0 when the archive cannot be
# fetched, unless KO_VERUS_REQUIRED=1.
#
# Requires: curl, unzip, shasum or sha256sum.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
release=0.2026.10.26.d17fbd0
# The crates.io version of vstd and verus_state_machines_macros that the release builds; the
# workspace Cargo.toml pins both with = (scripts/lint.sh compares). vstd pins the other Verus crates.
crates_version=0.0.0-2026-10-25-0158
cap_seconds=120
crates=(ko_pane_wire)

if [ "${1:-}" = "--print-key" ]; then
	echo "$release"
	exit 0
fi

if [ "${1:-}" = "fetch" ]; then
	prefix=${2:?"usage: $0 fetch <prefix>"}
	case "$(uname -s)-$(uname -m)" in
		Darwin-arm64) platform=arm64-macos sum=5e62be446a5da782d64caeee41bb1490c8aa3c65c0afe380d1c1dcbe207571ff ;;
		Darwin-x86_64) platform=x86-macos sum=24a23b0267f7a225c6ece4bc019930ca273bd57207fe0c1dd3cc7dc5726a37bc ;;
		Linux-x86_64) platform=x86-linux sum=361674d05f0c1b2c9c3f4d5bc56a8fb2ab9241ed0cceca27780668c292bb4940 ;;
		Linux-aarch64 | Linux-arm64) platform=arm64-linux sum=55d0179000c2c78732825d47a8b8fed1aa4afbe6d24896acc6e060eddcd338e4 ;;
		*) echo "verus.sh: no Verus release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
	esac
	workdir=$(mktemp -d)
	trap 'rm -rf "$workdir"' EXIT INT TERM
	archive="$workdir/verus.zip"
	curl -fL --connect-timeout 15 --max-time 600 \
		"https://github.com/verus-lang/verus/releases/download/release/$release/verus-$release-$platform.zip" -o "$archive"
	if command -v sha256sum >/dev/null; then
		echo "$sum  $archive" | sha256sum -c -
	else
		echo "$sum  $archive" | shasum -a 256 -c -
	fi
	unzip -q "$archive" -d "$workdir/unpacked"
	"$workdir/unpacked/verus-$platform/verus" --version | grep -q "Version: $release"
	rm -rf "$prefix"
	mkdir -p "$(dirname "$prefix")"
	mv "$workdir/unpacked/verus-$platform" "$prefix"
	echo "installed Verus $release into $prefix" >&2
	exit 0
fi

install() {
	local prefix=$1
	[ -x "$prefix/verus" ] || bash "$script_dir/verus.sh" fetch "$prefix"
}

verify() {
	local prefix=$1 status ms
	if ! install "$prefix"; then
		if [ "${KO_VERUS_REQUIRED:-}" = 1 ]; then
			echo "FAIL: the Verus archive is not available" >&2
			return 1
		fi
		echo "SKIP: the Verus archive is not available"
		return 0
	fi
	: "${CARGO:?verus.sh verify runs under make}"
	log=$(mktemp)
	trap 'rm -f "$log"' EXIT
	export PATH="$prefix:$PATH"
	local args=()
	for crate in "${crates[@]}"; do
		args+=(-p "$crate")
		"$CARGO" clean --locked -p "$crate"
	done
	# The first run builds and verifies vstd; its time is not counted.
	"$CARGO" verus verify --locked "${args[@]}" -- --time-expanded 2>&1 | tee "$log"
	status=${PIPESTATUS[0]}
	if [ "$status" != 0 ]; then
		return "$status"
	fi
	local missing
	missing=$(awk -v crates=" ${crates[*]} " '
		/^ *(Checking|Compiling) / { current = $2 }
		/^verification results:: [0-9]+ verified, 0 errors/ { done[current] = 1 }
		END { for (n = split(crates, list, " "); n > 0; n--) if (!(list[n] in done)) print list[n] }' "$log")
	if [ -n "$missing" ]; then
		echo "FAIL: no verification result for: $missing" >&2
		tail -n 20 "$log" >&2
		return 1
	fi
	ms=$(awk -v crates=" ${crates[*]} " '
		/^ *(Checking|Compiling) / { counted = index(crates, " " $2 " ") > 0 }
		/^total-time:/ && counted { total += $2 }
		END { print total + 0 }' "$log")
	echo "verified ${crates[*]} in ${ms} ms (cap $((cap_seconds * 1000)) ms)"
	if [ "$ms" -gt $((cap_seconds * 1000)) ]; then
		echo "FAIL: the verification takes more than ${cap_seconds} s; time of each module:" >&2
		awk -v crates=" ${crates[*]} " '
			/^ *(Checking|Compiling) / { counted = index(crates, " " $2 " ") > 0; inside = 0 }
			/total verify-time:/ { inside = counted }
			/total air-time:/ { inside = 0 }
			inside && /^ +[0-9]+\. / { print }' "$log" >&2
		return 1
	fi
}

case ${1:-} in
	install) install "${2:?usage: $0 install <prefix>}" ;;
	verify) verify "${2:?usage: $0 verify <prefix>}" ;;
	*) echo "usage: $0 --print-key|install <prefix>|verify <prefix>" >&2; exit 1 ;;
esac
