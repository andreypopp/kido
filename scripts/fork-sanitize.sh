#!/usr/bin/env bash
# Build the tmux fork with ASan and UBSan inside a podman container and run
# its regressions there, optionally followed by a time-boxed input fuzzer run.
# Every tmux server a regression starts lives and dies with the container, so
# the host's servers are unreachable.
#
# Usage: scripts/fork-sanitize.sh [--source DIR] [--revision REV | --worktree]
#                                 [--tests NAME,...] [--fuzz SECONDS]
#
#   --source DIR    the fork checkout (default third_party/tmux)
#   --revision REV  the revision built (default the submodule pin)
#   --worktree      build the checkout's working tree, uncommitted changes included
#   --tests LIST    comma-separated regress/ scripts (default all of them)
#   --fuzz SECONDS  then run input-fuzzer for SECONDS with OSC 7501 tokens and
#                   max_len 4500, past the 4096-byte OSC 7501 limit
#
# Prints PASS, FAIL, TIMEOUT or SANITIZER per test, with the log tail and report
# sites of each non-PASS, then the distinct sanitizer sites. Exits 1 on any.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_dir="$script_dir/../third_party/tmux"
revision=
worktree=0
tests=
fuzz=0
while [ $# -gt 0 ]; do
	case "$1" in
	--source) source_dir=$2; shift 2 ;;
	--revision) revision=$2; shift 2 ;;
	--worktree) worktree=1; shift ;;
	--tests) tests=$2; shift 2 ;;
	--fuzz) fuzz=$2; shift 2 ;;
	*) echo "fork-sanitize.sh: unrecognized argument: $1" >&2; exit 1 ;;
	esac
done
[ -n "$revision" ] || [ "$worktree" = 1 ] || revision=$("$script_dir/install-tmux-fork.sh" --print-revision)

if ! podman info >/dev/null 2>&1; then
	echo "fork-sanitize.sh: podman is not reachable; run podman machine start" >&2
	exit 1
fi

dockerfile='FROM docker.io/library/debian:13
RUN apt-get update && apt-get install -y --no-install-recommends \
		build-essential bison autoconf automake pkg-config \
		libevent-dev libncurses-dev libutf8proc-dev \
		clang libclang-rt-dev llvm python3 perl procps \
	&& rm -rf /var/lib/apt/lists/*'
# Native, not whatever platform a cached base image happens to have.
platform=linux/$(podman info --format '{{.Host.Arch}}')
image="localhost/kido-fork-sanitize:$(printf '%s %s' "$platform" "$dockerfile" | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-12)"
if ! podman image exists "$image"; then
	echo "==> building $image" >&2
	printf '%s\n' "$dockerfile" | podman build -q --platform "$platform" -t "$image" -f - "$script_dir" >/dev/null &
	build=$!
	(exec >/dev/null 2>&1; sleep 1800; kill "$build") &
	timer=$!
	wait "$build" || { echo "fork-sanitize.sh: podman build failed or timed out" >&2; pkill -P "$timer" sleep; exit 1; }
	pkill -P "$timer" sleep || true
fi

# The container reads the source as a tar on stdin; nothing of the host is
# mounted.
archive() {
	if [ "$worktree" = 1 ]; then
		cd "$source_dir"
		git ls-files -z --cached --others --exclude-standard |
			while IFS= read -r -d '' f; do
				if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi
			done |
			COPYFILE_DISABLE=1 tar --null -T - -cf -
	else
		git -C "$source_dir" archive "$revision"
	fi
}

inner=$(cat <<'INNER'
set -uo pipefail
tests=$1 fuzz=$2
export HOME=/work/home TMUX_TMPDIR=/work/tmp
mkdir -p "$HOME" "$TMUX_TMPDIR" /work/tmux /work/logs
cd /work/tmux
# Extraction time, not the commit's: the VM's clock can be behind it, and
# automake would then regenerate configure on every make.
tar -xmf - --warning=no-unknown-keyword || exit 1

export CC=clang CFLAGS='-O1 -g -fsanitize=undefined' LDFLAGS=-fsanitize=undefined
step() {
	log=/work/logs/$1.log
	shift
	if ! "$@" >"$log" 2>&1; then
		echo "$* failed:"
		tail -n 40 "$log"
		exit 1
	fi
}
step autogen sh autogen.sh
step configure ./configure --enable-asan --enable-utf8proc
step build make -j"$(nproc)"
echo "sanitizer build: PASS"

# UBSan recovers during the regressions, so one report does not end a test and
# hide what follows it. The server daemonizes with stderr on /dev/null, so
# reports go to files.
sanitizer='abort_on_error=1:detect_leaks=0:print_stacktrace=1'
failed=0
cd regress
[ -n "$tests" ] || tests=$(ls *.sh | paste -sd, -)
for t in ${tests//,/ }; do
	reports=/work/reports/${t%.sh}
	mkdir -p "$reports"
	started=$SECONDS
	timeout -k 5 180 env -i PATH="$PATH" LC_CTYPE=C.UTF-8 HOME="$HOME" TMUX_TMPDIR="$TMUX_TMPDIR" \
		ASAN_OPTIONS="$sanitizer:log_path=$reports/asan" \
		UBSAN_OPTIONS="$sanitizer:halt_on_error=0:log_path=$reports/ubsan" \
		sh -x "./$t" >"/work/logs/$t.log" 2>&1 </dev/null
	code=$?
	sites=$(cat "$reports"/* 2>/dev/null | sed -n 's/^SUMMARY: //p' | sort -u)
	if [ -n "$sites" ]; then status=SANITIZER
	elif [ "$code" = 124 ] || [ "$code" = 137 ]; then status=TIMEOUT
	elif [ "$code" != 0 ]; then status=FAIL
	else status=PASS
	fi
	echo "$t: $status ($((SECONDS - started))s)"
	if [ "$status" != PASS ]; then
		failed=1
		tail -n 15 "/work/logs/$t.log" | sed 's/^/    /'
		[ -z "$sites" ] || printf '%s\n' "$sites" | tee -a /work/sites | sed 's/^/  site: /'
	fi
done
[ ! -s /work/sites ] || { echo "distinct sanitizer sites:"; sort /work/sites | uniq -c; }

if [ "$fuzz" -gt 0 ]; then
	cd /work/tmux
	sed -i 's/^#define FUZZER_MAXLEN 512$/#define FUZZER_MAXLEN 4500/' fuzz/input-fuzzer.c
	printf '"%s"\n' '\x1b]7501;' state= id= app= kind= progress= title= msg= \
		'\x1b\\' '\x07' '?' '\x1b]9;4;' '\x1b]133;A' >>fuzz/input-fuzzer.dict
	mkdir /work/corpus
	printf '\033]7501;state=done\007' >/work/corpus/done
	printf '\033]7501;state=clear\033\\' >/work/corpus/clear
	printf '\033]7501;state=working:msg=SGk=\007' >/work/corpus/msg
	{ printf '\033]7501;state=done:'; head -c 4400 /dev/zero | tr '\0' a; printf '\007'; } >/work/corpus/long
	# configure adds the fuzzer's coverage only without CFLAGS, and the fuzzers
	# are check programs, built only on request.
	export CFLAGS="$CFLAGS -fsanitize=fuzzer-no-link"
	step fuzz-clean make clean
	step fuzz-configure ./configure --enable-asan --enable-utf8proc --enable-fuzzing
	step fuzz-build make -j"$(nproc)"
	step fuzz-link make fuzz/input-fuzzer
	if ASAN_OPTIONS="$sanitizer" UBSAN_OPTIONS="$sanitizer:halt_on_error=1" \
		timeout -k 5 $((fuzz + 60)) fuzz/input-fuzzer -dict=fuzz/input-fuzzer.dict \
		-max_len=4500 -max_total_time="$fuzz" -timeout=10 -rss_limit_mb=768 \
		-artifact_prefix=/work/crash- /work/corpus >/work/logs/fuzz.log 2>&1; then
		echo "fuzz: PASS ($(grep -m1 DONE /work/logs/fuzz.log))"
	else
		failed=1
		echo "fuzz: FAIL"
		tail -n 60 /work/logs/fuzz.log | sed 's/^/    /'
		for f in /work/crash-*; do
			[ -e "$f" ] && echo "  $f (base64): $(base64 -w0 "$f")"
		done
	fi
fi
exit "$failed"
INNER
)

name="kido-fork-sanitize-$$"
stop() { podman stop -t 2 "$name" >/dev/null 2>&1 || true; }
# The whole run's deadline: a host-side stop of this one container.
(exec >/dev/null 2>&1; sleep $((7200 + fuzz)); stop) &
watcher=$!
cleanup() {
	pkill -P "$watcher" sleep 2>/dev/null || true
	stop
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# In the background: bash runs a trap only once a foreground pipeline ends,
# but interrupts a wait.
archive | podman run --rm --init -i --name "$name" --cpus 2 --memory 3g \
	"$image" bash -c "$inner" fork-sanitize "$tests" "$fuzz" &
wait $!
