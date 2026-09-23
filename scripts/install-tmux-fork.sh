#!/bin/sh
# Build and install the andreypopp/tmux fork into the prefix given as $1, at
# the revision the Homebrew tap pins (or the revision given as $2). Used by
# CI (.github/workflows/ci.yml) and by humans setting up a local build of the
# fork kido runs inside.
#
# Usage: scripts/install-tmux-fork.sh <prefix> [revision]
#        scripts/install-tmux-fork.sh --print-revision
#
# With no revision, reads the tap's pinned revision so a plain
# `scripts/install-tmux-fork.sh <prefix>` builds the same commit
# `brew install andreypopp/tap/tmux` would. --print-revision only resolves
# and prints that SHA, without cloning or building anything.
#
# Requires: git, curl, sh, a C toolchain, bison, autoconf, automake,
# pkg-config, and the libevent/ncurses/utf8proc development headers.

set -eu

tap_formula_url="https://raw.githubusercontent.com/andreypopp/homebrew-tap/main/Formula/tmux.rb"

resolve_revision() {
	formula=$(curl -fsSL "$tap_formula_url")
	revision=$(printf '%s\n' "$formula" | sed -n 's/.*revision: *"\([0-9a-fA-F]*\)".*/\1/p' | head -n1)
	case "$revision" in
	[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
	*)
		echo "install-tmux-fork.sh: could not extract a 40-hex revision from $tap_formula_url" >&2
		exit 1
		;;
	esac
	printf '%s\n' "$revision"
}

if [ "${1:-}" = "--print-revision" ]; then
	resolve_revision
	exit 0
fi

prefix=${1:?"usage: $0 <prefix> [revision]"}
revision=${2:-$(resolve_revision)}

repo_url="https://github.com/andreypopp/tmux.git"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM

echo "==> fetching $repo_url at $revision into $workdir" >&2
git init -q "$workdir/tmux"
cd "$workdir/tmux"
git remote add origin "$repo_url"
git fetch --depth 1 origin "$revision"
git checkout -q FETCH_HEAD

# On macOS, Homebrew's ncurses is keg-only (not linked into
# /opt/homebrew/lib/pkgconfig), so pkg-config falls back to the ancient
# ncurses that ships with the OS unless we point at the brewed one
# explicitly. libevent and utf8proc are linked normally and need no help.
if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
	PKG_CONFIG_PATH="$(brew --prefix ncurses)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
	export PKG_CONFIG_PATH
fi

echo "==> autogen.sh" >&2
sh autogen.sh

# The fork's configure insists on an explicit jemalloc choice on Darwin;
# passing --disable-jemalloc is a no-op on Linux, so it is unconditional.
echo "==> configure --prefix=$prefix --enable-utf8proc --disable-jemalloc" >&2
./configure --prefix="$prefix" --enable-utf8proc --disable-jemalloc

njobs=$(command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo "==> make -j$njobs" >&2
make -j"$njobs"

echo "==> make install" >&2
make install

echo "==> installed:" >&2
"$prefix/bin/tmux" -V
