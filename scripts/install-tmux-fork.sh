#!/usr/bin/env bash
# Build the andreypopp/tmux fork vendored at third_party/tmux and install it
# into the given prefix, as <prefix>/bin/kido-tmux. Used by CI
# (.github/workflows/ci.yml), scripts/ci-like/, `make install`, and by
# humans setting up a local build of the fork kido runs inside.
#
# Usage: scripts/install-tmux-fork.sh <prefix>
#        scripts/install-tmux-fork.sh --self-contained <prefix>
#        scripts/install-tmux-fork.sh --print-revision
#
# --print-revision prints the pinned commit via `git ls-files -s third_party/tmux`:
# the gitlink resolves without the submodule checked out.
#
# Requires: git (for --print-revision only), sh, tar, a C toolchain,
# bison, autoconf, automake, pkg-config, and the libevent/ncurses/utf8proc
# development headers.
# --self-contained is macOS-only: it uses Homebrew's static libevent archive,
# builds pinned utf8proc source (curl, shasum), and links system ncurses.
# Its binary needs no Homebrew installation; dependency licenses are installed
# in <prefix>/share/kido-tmux.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
submodule="$repo_root/third_party/tmux"

if [ "${1:-}" = "--print-revision" ]; then
	git -C "$repo_root" ls-files -s third_party/tmux | awk '{print $2}'
	exit 0
fi

self_contained=false
if [ "${1:-}" = "--self-contained" ]; then
	self_contained=true
	shift
	if [ "$(uname -s)" != "Darwin" ]; then
		echo "install-tmux-fork.sh: --self-contained requires macOS" >&2
		exit 1
	fi
fi
prefix=${1:?"usage: $0 [--self-contained] <prefix>"}

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

if $self_contained; then
	libevent=$(brew --prefix libevent)
	if [ ! -f "$libevent/lib/libevent_core.a" ]; then
		echo "install-tmux-fork.sh: missing $libevent/lib/libevent_core.a" >&2
		exit 1
	fi
	curl -fL --connect-timeout 15 --max-time 120 \
		https://github.com/JuliaStrings/utf8proc/releases/download/v2.12.0/utf8proc-2.12.0.tar.gz \
		-o "$workdir/utf8proc.tar.gz"
	echo "a393fbef160835fb315bc3e91ba8d86f7a73a7cec9e6198b6c60b848b498bfeb  $workdir/utf8proc.tar.gz" | shasum -a 256 -c -
	tar -xf "$workdir/utf8proc.tar.gz" -C "$workdir"
	utf8proc="$workdir/utf8proc-2.12.0"
	make -C "$utf8proc" libutf8proc.a
	PKG_CONFIG=false
	LIBEVENT_CORE_CFLAGS="-I$libevent/include"
	LIBEVENT_CORE_LIBS="$libevent/lib/libevent_core.a"
	LIBTINFOW_CFLAGS=" "
	LIBTINFOW_LIBS="$(xcrun --show-sdk-path)/usr/lib/libncurses.tbd"
	LIBUTF8PROC_CFLAGS="-I$utf8proc"
	LIBUTF8PROC_LIBS="$utf8proc/libutf8proc.a"
	export PKG_CONFIG LIBEVENT_CORE_CFLAGS LIBEVENT_CORE_LIBS
	export LIBTINFOW_CFLAGS LIBTINFOW_LIBS LIBUTF8PROC_CFLAGS LIBUTF8PROC_LIBS
elif [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
	# Homebrew's ncurses is keg-only, so pkg-config falls back to the OS's
	# ancient one unless pointed at the brewed one explicitly.
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

if $self_contained; then
	otool -L tmux
	if otool -L tmux | awk 'NR > 1 {print $1}' | grep -Ev '^(/usr/lib/|/System/)'; then
		echo "install-tmux-fork.sh: non-system library in self-contained binary" >&2
		exit 1
	fi
fi

echo "==> make install" >&2
make install

# Renamed so it can sit beside a stock tmux install without shadowing it.
mv "$prefix/bin/tmux" "$prefix/bin/kido-tmux"
if [ -e "$prefix/share/man/man1/tmux.1" ]; then
	mv "$prefix/share/man/man1/tmux.1" "$prefix/share/man/man1/kido-tmux.1"
fi

mkdir -p "$prefix/share/kido-tmux"
git -C "$submodule" rev-parse HEAD > "$prefix/share/kido-tmux/REVISION"
if $self_contained; then
	cp "$libevent/LICENSE" "$prefix/share/kido-tmux/libevent-LICENSE"
	cp "$utf8proc/LICENSE.md" "$prefix/share/kido-tmux/utf8proc-LICENSE.md"
fi

echo "==> installed:" >&2
"$prefix/bin/kido-tmux" -V
