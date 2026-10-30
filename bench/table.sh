#!/bin/sh
# usage: bench/table.sh   (KIDO_TMUX overrides the fork's kido-tmux)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
KIDO_TMUX=${KIDO_TMUX:-$root/build/tmux-fork/$(scripts/install-tmux-fork.sh --print-build-key)/bin/kido-tmux}
export KIDO_TMUX
dune build @install bench/usage.exe
echo "== throughput"
sh bench/baselines.sh
python3 -B bench/client.py
echo "== library memory figures"
./_build/default/bench/usage.exe 100000 95 30
