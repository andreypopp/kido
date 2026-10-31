#!/usr/bin/env bash
# Usage: scripts/fuzz.sh [--merge] TARGET SECONDS
set -uo pipefail
cd "$(dirname "$0")/.."
# the trusted Ring, Connection and Delivery_io assert what ko_proofs/ assumes of them
export KO_CHECK_CONTRACTS=true
targets='frame control ring pane-proc view http loop ring-afl pane-proc-afl http-afl'
merge=
if [[ ${1:-} == --merge ]]; then
  merge=1
  shift
fi
target=${1:-}
seconds=${2:-}
if [[ -z $target || -z $seconds ]] || ! grep -qw -- "$target" <<<"$targets" || [[ ! $seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: make fuzz TARGET=<$(tr ' ' '|' <<<"$targets")> TIME=<seconds> [MERGE=1]" >&2
  echo "       MERGE=1 fuzzes TIME seconds, then replaces ko_pane/fuzz/TARGET/ with the minimal set" >&2
  echo "       of the checked-in inputs and the new ones; only a plain run never writes there" >&2
  exit 1
fi
if [[ -n $merge && ! -d ko_pane/fuzz/$target ]]; then
  echo "fuzz.sh: $target has no checked-in corpus in ko_pane/fuzz/$target" >&2
  exit 1
fi
scratch=$(mktemp -d /tmp/kofuzz-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 143' TERM INT HUP

# build ARGS...: dune build, waiting up to 90 s while another dune instance holds the build lock
build() {
  local out end=$((SECONDS + 90))
  while ((SECONDS < end)); do
    out=$(dune build "$@" 2>&1) && { grep -v 'ignoring duplicate libraries' <<<"$out"; return 0; }
    grep -q 'Another Dune instance' <<<"$out" || { echo "$out" >&2; return 1; }
    sleep 3
  done
  echo "fuzz.sh: dune stayed locked for 90 s" >&2
  return 1
}

# boxed SECONDS CMD...: runs CMD in its own process group; on timeout or TERM/INT/HUP kills and reaps the group
boxed() {
  perl -e '
    my $limit = shift;
    my $pid = fork();
    die "fork failed" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
    my $stop = sub {
      my ($why, $code) = @_;
      kill "TERM", -$pid; select(undef, undef, undef, 2); kill "KILL", -$pid;
      waitpid($pid, 0);
      print STDERR "fuzz.sh: $why\n";
      exit $code;
    };
    $SIG{ALRM} = sub { $stop->("killed the target after ${limit}s", 124) };
    $SIG{$_} = sub { $stop->("interrupted", 143) } for qw(TERM INT HUP);
    alarm $limit;
    waitpid($pid, 0);
    my $status = $?;
    kill "KILL", -$pid;
    exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
  ' "$@"
}

export TMPDIR=$scratch
case $target in
  frame | control)
    cc=${KO_FUZZ_CC:-}
    if [[ -z $cc ]]; then
      printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){return 0;}' >"$scratch/probe.c"
      for candidate in $(ls -r /opt/homebrew/opt/llvm*/bin/clang /usr/lib/llvm*/bin/clang 2>/dev/null) "$(command -v clang || true)"; do
        [[ -x $candidate ]] || continue
        if "$candidate" -fsanitize=fuzzer,address "$scratch/probe.c" -o "$scratch/probe" >/dev/null 2>&1 &&
          boxed 10 "$scratch/probe" -runs=1 >/dev/null 2>&1; then cc=$candidate; break; fi
      done
    fi
    if [[ -z $cc ]]; then
      echo "SKIP $target: no clang with libFuzzer found (Apple clang has none); install LLVM or set KO_FUZZ_CC" >&2
      exit 0
    fi
    export KO_FUZZ_CC=$cc
    build --profile fuzz "ko_pane/fuzz-$target-libfuzzer" || exit 1
    corpus=$scratch/corpus
    mkdir -p "$corpus"
    [[ -d ko_pane/fuzz/$target ]] && cp ko_pane/fuzz/$target/* "$corpus"/
    options=()
    [[ -f ko_pane/fuzz/$target.dict ]] && options+=("-dict=$PWD/ko_pane/fuzz/$target.dict")
    max_len=$(sed -n 's/^max_len *= *//p' "ko_pane/fuzz/$target.options" 2>/dev/null)
    options+=("-max_len=${max_len:-1024}" -rss_limit_mb=4000 -timeout=10 -artifact_prefix="$PWD/_build/fuzz-")
    # ASan on macOS keeps what libghostty-vt frees, so a libFuzzer process grows by about
    # 100 KiB per input; restart it every 24000 inputs, which stays under the RSS limit.
    end=$((SECONDS + seconds))
    total=0
    while ((SECONDS < end)); do
      boxed $((end - SECONDS + 30)) _build/default/ko_pane/fuzz-"$target"-libfuzzer -runs=24000 -max_total_time=$((end - SECONDS)) "${options[@]}" "$corpus" >"$scratch/log" 2>&1
      status=$?
      if [[ ! -f $scratch/out/default/fuzzer_stats ]]; then
        cat "$scratch/log"
        exit $((status == 0 ? 1 : status))
      fi
      if ((status != 0)); then
        cat "$scratch/log"
        exit $status
      fi
      total=$((total + $(sed -n 's/^Done \([0-9]*\) runs.*/\1/p' "$scratch/log")))
    done
    tail -3 "$scratch/log"
    echo "fuzz.sh: $target ran ${total} inputs in ${seconds}s, corpus $(ls "$corpus" | wc -l) inputs"
    if [[ -n $merge ]]; then
      destination=ko_pane/fuzz/$target
      staging=ko_pane/fuzz/.$target.new
      mkdir "$scratch/merged" || exit 1
      boxed 300 _build/default/ko_pane/fuzz-"$target"-libfuzzer -merge=1 "${options[@]}" "$scratch/merged" "$corpus" >"$scratch/log" 2>&1 || { cat "$scratch/log"; exit 1; }
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
    ;;
  *)
    case $target in
      ring | ring-afl) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_ring.ml ;;
      view) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_view.ml ;;
      http | http-afl) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_http.ml ;;
      loop) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_loop.ml ;;
      pane-proc | pane-proc-afl) library=ko_server dir=ko_server root=.. file=ko_server/pane_proc.ml ;;
    esac
    props=$(grep -cE '(Fuzz_check\.check|Fuzz_run\.monolith) ' "$file")
    if ((seconds < props)); then
      echo "fuzz.sh: $target has $props properties and needs TIME of at least $props" >&2
      exit 1
    fi
    runner=".$library.inline-tests/inline-test-runner.exe"
    only=$file
    case $target in
      http-afl) only=$file:$(grep -n 'let%test "AFL bytes' "$file" | cut -d: -f1) ;;
      pane-proc-afl) only=$file:$(grep -n 'let%test "control frames' "$file" | cut -d: -f1) ;;
    esac
    run_args=(inline-test-runner "$library" -source-tree-root "$root" -diff-cmd - -only-test "$only")
    if [[ $target == *-afl ]]; then
      afl_fuzz=${KO_AFL_FUZZ:-$(command -v afl-fuzz || true)}
      if [[ -z $afl_fuzz ]]; then
        echo "SKIP $target: no afl-fuzz found; install AFL++ or set KO_AFL_FUZZ" >&2
        exit 0
      fi
      # dune-workspace.afl locks an OCaml compiler with ocaml-option-afl, so the dependencies are
      # instrumented too; its own build directory keeps the plain build in _build.
      afl_build() { build --workspace dune-workspace.afl --build-dir _build_afl "$@"; }
      targets_to_build=("$dir/$runner")
      [[ $target == http-afl ]] && targets_to_build+=(ko_pane/ko-pane)
      afl_build "${targets_to_build[@]}" || exit 1
      mkdir "$scratch/in" || exit 1
      if [[ $target == http-afl ]]; then
        printf 'GET /version HTTP/1.1\r\nHost: ko\r\nKo-Protocol: 1.0\r\n\r\n' >"$scratch/in/seed"
      else
        head -c 256 /dev/urandom >"$scratch/in/seed"
      fi
      # AFL_MAP_SIZE and AFL_SKIP_BIN_CHECK: the OCaml runtime's fork server does not report a map
      # size, and afl-fuzz then asks for an 8 MiB map, which macOS refuses (kern.sysv.shmmax is 4 MiB).
      # __AFL_PERSISTENT: afl-fuzz sets it only after its binary check, which AFL_SKIP_BIN_CHECK skips.
      cd "_build_afl/default/$dir" || exit 1
      KO_AFL_SOURCE=$scratch/input __AFL_PERSISTENT=1 AFL_MAP_SIZE=65536 AFL_SKIP_BIN_CHECK=1 \
        AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
        boxed $((seconds + 60)) "$afl_fuzz" -V "$seconds" -i "$scratch/in" -o "$scratch/out" \
        -f "$scratch/input" -- "./$runner" "${run_args[@]}" >"$scratch/log" 2>&1
      status=$?
      grep -E 'Statistics|execs_per_sec' "$scratch/log" | tail -1
      grep -E '^(execs_done|execs_per_sec|edges_found|total_edges)' "$scratch/out/default/fuzzer_stats" | tr -s ' \n' ' '
      echo
      crash=$(ls "$scratch"/out/default/crashes/id* 2>/dev/null | head -1)
      if [[ -n $crash ]]; then
        echo "fuzz.sh: $target found $(ls "$scratch"/out/default/crashes/id* | wc -l) crashing inputs; the first one runs as:"
        KO_AFL_SOURCE=$crash boxed 60 "./$runner" "${run_args[@]}" >"$scratch/replay" 2>&1
        head -60 "$scratch/replay"
        exit 1
      fi
      if ((status != 0)); then
        cat "$scratch/log"
        exit $status
      fi
      exit 0
    fi
    build "$dir/$runner" ko_pane/ko-pane || exit 1
    cd "_build/default/$dir" || exit 1
    KO_FUZZ_SECONDS=$((seconds / props)) boxed $((seconds + 60)) "./$runner" "${run_args[@]}"
    exit $?
    ;;
esac
