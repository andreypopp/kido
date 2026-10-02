#!/usr/bin/env bash
# Build the andreypopp/tmux fork vendored at third_party/tmux and install it
# into the prefix given as $1, as <prefix>/bin/kido-tmux. Used by CI
# (.github/workflows/ci.yml), scripts/ci-like/, `make install`, and by
# humans setting up a local build of the fork kido runs inside.
#
# Usage: scripts/install-tmux-fork.sh <prefix>
#        scripts/install-tmux-fork.sh --print-revision
#
# --print-revision prints the pinned commit via `git ls-files -s third_party/tmux`:
# the gitlink resolves without the submodule checked out.
#
# Requires: git (for --print-revision only), sh, tar, a C toolchain,
# bison, autoconf, automake, pkg-config, and the libevent/ncurses/utf8proc
# development headers.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
submodule="$repo_root/third_party/tmux"

if [ "${1:-}" = "--print-revision" ]; then
	git -C "$repo_root" ls-files -s third_party/tmux | awk '{print $2}'
	exit 0
fi

prefix=${1:?"usage: $0 <prefix>"}

if [ ! -e "$submodule/configure.ac" ]; then
	echo "install-tmux-fork.sh: $submodule is empty; run git submodule update --init" >&2
	exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM

echo "==> copying $submodule into $workdir" >&2
mkdir -p "$workdir/tmux"
(cd "$submodule" && tar -cf - --exclude=.git .) | (cd "$workdir/tmux" && tar -xf -)
cd "$workdir/tmux"

# Homebrew's ncurses is keg-only, so pkg-config falls back to the OS's
# ancient one unless pointed at the brewed one explicitly.
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

# Renamed so it can sit beside a stock tmux install without shadowing it.
mv "$prefix/bin/tmux" "$prefix/bin/kido-tmux"
if [ -e "$prefix/share/man/man1/tmux.1" ]; then
	mv "$prefix/share/man/man1/tmux.1" "$prefix/share/man/man1/kido-tmux.1"
fi

mkdir -p "$prefix/share/kido-tmux"
git -C "$submodule" rev-parse HEAD > "$prefix/share/kido-tmux/REVISION"

echo "==> installed:" >&2
"$prefix/bin/kido-tmux" -V
