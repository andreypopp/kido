#!/bin/sh
set -eu
out=$1
source=$2
shift 2
cxx=$(sh ../ko_vt/cxx.sh)
case $(uname -s) in Darwin) pty=;; *) pty=-lutil;; esac
exec cc -std=c11 -Wall -Wextra -Werror -I../third_party/ghostty/include "$source" ../ko_vt/libghostty-vt.a "$cxx" $pty "$@" -o "$out"
