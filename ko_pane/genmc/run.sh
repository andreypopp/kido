#!/bin/sh
# Model-check the extracted ring writer and reader with GenMC, as two threads
# over one ring: ring_mc.c writes and reads a wrapping ring of Bytes records,
# wakeup_mc.c the idle handshake of head and read. The atomics are the ring's
# own (sc: ko_proofs/ko_atomic.h, sequentially consistent) or acqrel/
# (release stores and acquire loads).
#
# Usage: ko_pane/genmc/run.sh sc|acqrel ring|wakeup
# GENMC names the genmc binary (default: genmc on PATH).
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  sc) atomics=$dir/../../ko_proofs/ko_atomic.h ;;
  acqrel) atomics=$dir/acqrel/ko_atomic.h ;;
  *) echo "usage: $0 sc|acqrel ring|wakeup" >&2; exit 2 ;;
esac
case "${2:-}" in
  ring | wakeup) model=$dir/${2}_mc.c ;;
  *) echo "usage: $0 sc|acqrel ring|wakeup" >&2; exit 2 ;;
esac
scratch=$(mktemp -d /tmp/ko-genmc-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
# ko_ring_proved.h includes "ko_atomic.h" from its own directory.
cp "$dir/../../ko_proofs/ko_ring_proved.h" "$model" "$scratch/"
cp "$atomics" "$scratch/ko_atomic.h"
"${GENMC:-genmc}" -disable-mm-detector -- -I"$scratch" "$scratch/$(basename "$model")"
