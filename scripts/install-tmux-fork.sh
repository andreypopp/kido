#!/bin/sh
# Build and install the andreypopp/tmux fork (branch side-pane) into the
# prefix given as $1. Used by CI (.github/workflows/ci.yml) and by humans
# setting up a local build of the fork kido runs inside.
#
# Usage: scripts/install-tmux-fork.sh <prefix>
#
# Requires: git, sh, a C toolchain, bison, autoconf, automake, pkg-config,
# and the libevent/ncurses/utf8proc development headers.

set -eu

prefix=${1:?"usage: $0 <prefix>"}

repo_url="https://github.com/andreypopp/tmux.git"
branch="side-pane"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM

echo "==> cloning $repo_url (branch $branch) into $workdir" >&2
git clone --depth 1 --branch "$branch" "$repo_url" "$workdir/tmux"

cd "$workdir/tmux"

# On macOS, Homebrew's ncurses is keg-only (not linked into
# /opt/homebrew/lib/pkgconfig), so pkg-config falls back to the ancient
# ncurses that ships with the OS unless we point at the brewed one
# explicitly. libevent and utf8proc are normally linked and found without
# help, but we add them too for robustness against non-default brew setups.
jemalloc_flag=""
if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
	for formula in ncurses libevent utf8proc jemalloc; do
		formula_prefix=$(brew --prefix "$formula" 2>/dev/null || true)
		if [ -n "$formula_prefix" ] && [ -d "$formula_prefix/lib/pkgconfig" ]; then
			PKG_CONFIG_PATH="$formula_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
		fi
	done
	export PKG_CONFIG_PATH
	# The fork's configure requires an explicit --enable-jemalloc or
	# --disable-jemalloc choice on macOS; use it since Homebrew's jemalloc
	# is installed above.
	jemalloc_flag="--enable-jemalloc"
fi

echo "==> autogen.sh" >&2
sh autogen.sh

echo "==> configure --prefix=$prefix --enable-utf8proc $jemalloc_flag" >&2
./configure --prefix="$prefix" --enable-utf8proc $jemalloc_flag

njobs=$(command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo "==> make -j$njobs" >&2
make -j"$njobs"

echo "==> make install" >&2
make install

echo "==> installed:" >&2
"$prefix/bin/tmux" -V
