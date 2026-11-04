#!/usr/bin/env bash
# Usage: scripts/fuzz.sh [--merge] TARGET SECONDS | --list
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/nightly.sh
targets='frame control ring loop head http decode frames client ws'
if [[ ${1:-} == --list ]]; then
  tr ' ' '\n' <<<"$targets"
  exit 0
fi
merge=
if [[ ${1:-} == --merge ]]; then
  merge=1
  shift
fi
target=${1:-}
seconds=${2:-}
if [[ -z $target || -z $seconds ]] || ! grep -qw -- "$target" <<<"$targets" || [[ ! $seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: make fuzz TARGET=<$(tr ' ' '|' <<<"$targets")> TIME=<seconds> [MERGE=1]" >&2
  echo "       MERGE=1 fuzzes TIME seconds, then replaces fuzz/corpus/TARGET/ with the minimal set" >&2
  echo "       of the checked-in inputs and the new ones; only a plain run never writes there" >&2
  exit 1
fi
if [[ -n $merge && ! -d fuzz/corpus/$target ]]; then
  echo "fuzz.sh: $target has no checked-in corpus in fuzz/corpus/$target" >&2
  exit 1
fi
skip_without_nightly "$target" fuzz --help
scratch=$(mktemp -d /tmp/kofuzz-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 143' TERM INT HUP

export TMPDIR=$scratch
target_dir=$PWD/target/fuzz
# -a: debug assertions and overflow checks, which carry the contract checks of the ring and the connections
boxed fuzz.sh 3000 make --no-print-directory nightly-cargo ARGS="fuzz build -a --target-dir $target_dir $target" || exit 1
binary=$(find "$target_dir" -maxdepth 3 -path "*/release/$target" -type f | head -1)
if [[ $target == http ]]; then
  boxed fuzz.sh 1500 make --no-print-directory cargo ARGS="build --release -p ko_pane" || exit 1
  export KO_PANE_EXE=$PWD/target/release/ko-pane
fi
corpus=$scratch/corpus
mkdir -p "$corpus" "$PWD/target/fuzz-artifacts"
[[ -d fuzz/corpus/$target ]] && cp fuzz/corpus/$target/* "$corpus"/
options=()
[[ -f fuzz/$target.dict ]] && options+=("-dict=$PWD/fuzz/$target.dict")
max_len=$(sed -n 's/^max_len *= *//p' "fuzz/$target.options" 2>/dev/null)
options+=("-max_len=${max_len:-1024}" -rss_limit_mb=4000 -timeout=10 -artifact_prefix="$PWD/target/fuzz-artifacts/$target-")
# ASan on macOS keeps what libghostty-vt frees, so a libFuzzer process grows by about
# 100 KiB per input; restart it every 24000 inputs, which stays under the RSS limit.
end=$((SECONDS + seconds))
total=0
while ((SECONDS < end)); do
  boxed fuzz.sh $((end - SECONDS + 30)) "$binary" -runs=24000 -max_total_time=$((end - SECONDS)) "${options[@]}" "$corpus" >"$scratch/log" 2>&1
  status=$?
  if ((status != 0)); then
    cat "$scratch/log"
    exit $status
  fi
  total=$((total + $(sed -n 's/^Done \([0-9]*\) runs.*/\1/p' "$scratch/log")))
done
tail -3 "$scratch/log"
echo "fuzz.sh: $target ran ${total} inputs in ${seconds}s, corpus $(ls "$corpus" | wc -l) inputs"
if [[ -n $merge ]]; then
  destination=fuzz/corpus/$target
  staging=fuzz/corpus/.$target.new
  mkdir "$scratch/merged" || exit 1
  boxed fuzz.sh 300 "$binary" -merge=1 "${options[@]}" "$scratch/merged" "$corpus" >"$scratch/log" 2>&1 || { cat "$scratch/log"; exit 1; }
  if [[ -z $(ls -A "$scratch/merged") ]]; then
    echo "fuzz.sh: the merge produced no inputs; $destination is unchanged" >&2
    exit 1
  fi
  rm -rf "$staging"
  if ! { mkdir "$staging" && cp "$scratch"/merged/* "$staging"/; }; then
    rm -rf "$staging"
    echo "fuzz.sh: could not stage the merged corpus; $destination is unchanged" >&2
    exit 1
  fi
  if ! mv "$destination" "$scratch/old"; then
    rm -rf "$staging"
    echo "fuzz.sh: could not move $destination away; it is unchanged" >&2
    exit 1
  fi
  if ! mv "$staging" "$destination"; then
    mv "$scratch/old" "$destination"
    rm -rf "$staging"
    echo "fuzz.sh: could not install the merged corpus; $destination is restored" >&2
    exit 1
  fi
  echo "fuzz.sh: $destination now has $(ls "$destination" | wc -l) inputs"
fi
