#!/bin/sh
# Verify the Pulse proofs of the ring and of its callers, extract the ring to
# C (ko_ring_proved.h) and the callers to OCaml (ko_server/pane_core.ml and
# view_core.ml), and check that the OCaml calls each stateful extern as many
# times as the F* does. With --write, replace the committed files; otherwise compare against
# them. Needs fstar.exe and krml on PATH; KO_FSTAR_CACHE names the directory
# that keeps the .checked files between runs.
set -eu
mode=${1:-}
dir=$(cd "$(dirname "$0")" && pwd)
server=$dir/../ko_server
cache=${KO_FSTAR_CACHE:?KO_FSTAR_CACHE names the .checked cache}
mkdir -p "$cache"
scratch=$(mktemp -d /tmp/ko-proofs-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
check="--cache_checked_modules --cache_dir $cache --include $dir"
# Each group depends only on the groups before it; its modules check in parallel.
for group in "KoAtomic.fsti KoRing.Spec.fst Oint.fsti Protocol.fsti" KoRing.Mask.fst KoRing.Inv.fst \
  "Feed.fst KoRing.Init.fst KoRing.Reader.fst KoRing.Writer.fst" KoRing.Walk.fst Ring.fsti \
  "Ring_proof.fst Connection.fsti" Delivery_io.fsti "Pane_core.fst View_core.fst"; do
  set --
  for module in $group; do
    fstar.exe $check "$dir/$module" >"$scratch/$module.log" 2>&1 &
    set -- "$@" "$!:$module"
  done
  for job in "$@"; do
    wait "${job%%:*}" || { cat "$scratch/${job#*:}.log"; exit 1; }
  done
done

entries=
for entry in Inv.min_capacity Inv.max_capacity Writer.available Writer.put_record \
  Reader.observe Reader.header Walk.advance Walk.end_offset Walk.resume Walk.reachable; do
  entries="$entries --custard_entry KoRing.$entry"
done
(cd "$scratch" &&
  fstar.exe $check --codegen KrmlC $entries --custard_split --odir . "$dir/KoRing.Walk.fst" >log 2>&1 &&
  krml -skip-compilation -minimal -add-include '<stdbool.h>' -add-include '<stddef.h>' \
    -add-include '<stdint.h>' -fparentheses -fcurly-braces \
    -bundle 'KoRing.Inv+KoRing.Writer+KoRing.Reader+KoRing.Walk=KoRing.*,KoAtomic[rename=ko_ring_proved]' \
    -static-header 'KoRing.*' -tmpdir c Custard.krml >log 2>&1) || { cat "$scratch/log"; exit 1; }

entries=
for entry in Pane_core.make Pane_core.ring Pane_core.busy Pane_core.deliver Pane_core.note_snapshot Pane_core.snapshot_done \
  Pane_core.fail_requests Pane_core.scan View_core.make_view View_core.open_view View_core.conn View_core.pump View_core.close \
  View_core.view_waiting View_core.on_slice View_core.on_done View_core.request_snapshot \
  View_core.decide; do
  entries="$entries --custard_entry $entry"
done
mkdir "$scratch/ml"
fstar.exe $check --codegen OCaml $entries --custard_split --odir "$scratch/ml" \
  --custard_extern_type 'Ring.t=Ring.t' --custard_extern_type 'Ring.rkind=Ring.kind' \
  --custard_extern_type 'Protocol.history=Protocol.history' \
  --custard_extern_type 'Connection.written=Connection.written' \
  "$dir/View_core.fst" >"$scratch/log" 2>&1 || { cat "$scratch/log"; exit 1; }
# The calls of Ring.advance leave out its labels.
sed -i.orig '2s/"-3-5-/"-3-5-6-/' "$scratch/ml/Pane_core.ml"
grep -q '"-3-5-6-' "$scratch/ml/Pane_core.ml"

# Every stateful extern of the trusted interfaces, as F* name and OCaml
# target, from its [@@custard_extern] attribute; each is called as often in
# the generated OCaml as in the F* cores, so extraction dropped no effect.
for module in Ring Connection Delivery_io Oint; do
  awk -v m="$module" '
    /custard_extern "/ { match($0, /custard_extern "[^"]*"/); t = substr($0, RSTART + 16, RLENGTH - 17); pending = 1 }
    pending && /(val|fn) [a-z_]+/ {
      match($0, /(val|fn) [a-z_]+/); split(substr($0, RSTART, RLENGTH), w, " "); name = w[2]; decl = $0; pending = 0; grab = 1; next }
    grab { decl = decl " " $0; if ($0 ~ /^$/ || $0 ~ /^\[@@/ || $0 ~ /^(let|val|type|new|noeq)/) { emit(); grab = 0 } }
    END { if (grab) emit() }
    function emit() { if (decl ~ /stt |stt_atomic|^fn |[ ]fn /) print m, name, t }
  ' "$dir/$module.fsti"
done >"$scratch/externs"
test -s "$scratch/externs"
status=0
while read -r module name target; do
  pattern=$(printf '%s' "$target" | sed 's/[.()]/\\&/g')
  aliases=$(grep -h -E "^module [A-Z]+ = $module\$" "$dir/Pane_core.fst" "$dir/View_core.fst" | awk '{print $2}' | sort -u)
  f=0
  for alias in $aliases; do
    f=$((f + $(cat "$dir/Pane_core.fst" "$dir/View_core.fst" | grep -oE "(^|[^A-Za-z0-9_.])$alias\\.$name " | wc -l)))
  done
  o=$(cat "$scratch/ml/Pane_core.ml" "$scratch/ml/View_core.ml" | grep -oE "\\($pattern " | wc -l)
  if [ "$f" -ne "$o" ]; then
    echo "effect $module.$name ($target): $f call sites in F*, $o in OCaml"
    status=1
  fi
done <"$scratch/externs"
[ $status = 0 ] || exit 1
echo "effects: $(wc -l <"$scratch/externs" | tr -d ' ') stateful externs, call-site counts match"

if [ "$mode" = --write ]; then
  cp "$scratch/c/ko_ring_proved.h" "$dir/ko_ring_proved.h"
  cp "$scratch/ml/Pane_core.ml" "$server/pane_core.ml"
  cp "$scratch/ml/View_core.ml" "$server/view_core.ml"
else
  diff -u "$dir/ko_ring_proved.h" "$scratch/c/ko_ring_proved.h"
  diff -u "$server/pane_core.ml" "$scratch/ml/Pane_core.ml"
  diff -u "$server/view_core.ml" "$scratch/ml/View_core.ml"
fi
