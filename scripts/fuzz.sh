#!/usr/bin/env bash
# Usage: scripts/fuzz.sh TARGET SECONDS
set -uo pipefail
cd "$(dirname "$0")/.."
targets='frame control ring pane-proc view http'
target=${1:-}
seconds=${2:-}
if [[ -z $target || -z $seconds ]] || ! grep -qw -- "$target" <<<"$targets" || [[ ! $seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: make fuzz TARGET=<$(tr ' ' '|' <<<"$targets")> TIME=<seconds>" >&2
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
      if ((status != 0)); then
        cat "$scratch/log"
        exit $status
      fi
      total=$((total + $(sed -n 's/^Done \([0-9]*\) runs.*/\1/p' "$scratch/log")))
    done
    tail -3 "$scratch/log"
    echo "fuzz.sh: $target ran ${total} inputs in ${seconds}s, corpus $(ls "$corpus" | wc -l) inputs"
    ;;
  *)
    case $target in
      ring) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_ring.ml ;;
      view) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_view.ml ;;
      http) library=ko_server_fuzz dir=ko_server/fuzz root=../.. file=ko_server/fuzz/fuzz_http.ml ;;
      pane-proc) library=ko_server dir=ko_server root=.. file=ko_server/pane_proc.ml ;;
    esac
    props=$(grep -cE '(Fuzz_check\.check|^ +soak) ' "$file")
    if ((seconds < props)); then
      echo "fuzz.sh: $target has $props properties and needs TIME of at least $props" >&2
      exit 1
    fi
    build "$dir/.$library.inline-tests/inline-test-runner.exe" ko_pane/ko-pane || exit 1
    cd "_build/default/$dir" || exit 1
    KO_FUZZ_SECONDS=$((seconds / props)) boxed $((seconds + 60)) \
      "./.$library.inline-tests/inline-test-runner.exe" inline-test-runner "$library" \
      -source-tree-root "$root" -diff-cmd - -only-test "$file"
    exit $?
    ;;
esac
