#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fork_repo=${1:-$repo}
prefix="$here/output/prefix"
pin=$("$repo/scripts/install-tmux-fork.sh" --print-revision)
source_revision=$(git -C "$fork_repo/third_party/tmux" rev-parse HEAD)
if [[ "$pin" != "$source_revision" ]]; then
  echo "Fork source $source_revision does not match worktree pin $pin" >&2
  exit 1
fi
unset DUNE_BUILD_DIR TMUX TMUX_PANE
"$fork_repo/scripts/install-tmux-fork.sh" "$prefix"
cd "$repo"
dune build
make install PREFIX="$prefix"
printf '\nRecord with:\nKIDO_DEMO_PREFIX=%q %q tmux\n' "$prefix" "$here/record.sh"
