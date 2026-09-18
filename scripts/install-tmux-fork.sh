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
