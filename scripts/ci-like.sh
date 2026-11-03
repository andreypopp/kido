#!/usr/bin/env bash
# Run a test command inside a Linux container with the repo bind-mounted
# and CPU/memory capped, so a CI-runner-only failure (slow, contended
# hardware) can be reproduced without saturating the host's cores the way
# a test run on every core does.
#
# Usage: scripts/ci-like.sh [--cpus N] [--memory SIZE] [--timeout SECONDS]
#                            [--cpu-shares N] [--contend N] [--budget N]
#                            -- <command...>
#
#   --cpus N        CPU quota handed to the container (default 0.5)
#   --memory SIZE   memory limit, podman syntax e.g. 1g (default 1g)
#   --timeout SEC   kill the container if it runs longer than this (default 300)
#   --cpu-shares N  relative CPU weight against --contend's siblings (podman
#                   default 1024; pass a low number, e.g. 1, to be reliably
#                   outweighed by them)
#   --contend N     start N independent busy sibling containers (each
#                   spinning 16 threads) before running, removed on exit
#   --budget N      total host cores this run may use, test container and
#                   siblings together (default 2)

set -euo pipefail

cpus=0.5
memory=1g
timeout_s=300
cpu_shares=
contend=0
budget=2

while [ $# -gt 0 ]; do
	case "$1" in
	--cpus)
		cpus=$2
		shift 2
		;;
	--memory)
		memory=$2
		shift 2
		;;
	--timeout)
		timeout_s=$2
		shift 2
		;;
	--cpu-shares)
		cpu_shares=$2
		shift 2
		;;
	--contend)
		contend=$2
		shift 2
		;;
	--budget)
		budget=$2
		shift 2
		;;
	--)
		shift
		break
		;;
	*)
		echo "ci-like.sh: unrecognized argument: $1" >&2
		exit 1
		;;
	esac
done

if [ $# -eq 0 ]; then
	echo "usage: scripts/ci-like.sh [--cpus N] [--memory SIZE] [--timeout SECONDS] [--cpu-shares N] [--contend N] [--budget N] -- <command...>" >&2
	exit 1
fi

podman=$(command -v podman || true)
if [ -z "$podman" ]; then
	echo "ci-like.sh: podman not found on PATH; install it (brew install podman) to reproduce runner-only failures" >&2
	exit 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
# The repo under test is the caller's cwd, not the script's own location:
# reproducing a pre-fix failure means running this against a scratch
# checkout elsewhere, with this script (and its Dockerfile) still found
# relative to itself.
repo_root=$(pwd)

machine_state=$("$podman" machine list --format '{{.Name}}\t{{.Running}}' 2>/dev/null | awk -F'\t' '$1 ~ /\*$/ || $1 == "podman-machine-default" {print $2; exit}')
if [ "$machine_state" != "true" ]; then
	echo "==> starting podman machine" >&2
	"$podman" machine start >&2
	deadline=$((SECONDS + 60))
	while [ "$SECONDS" -lt "$deadline" ]; do
		if "$podman" info >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done
	if ! "$podman" info >/dev/null 2>&1; then
		echo "ci-like.sh: podman machine did not become ready within 60s" >&2
		exit 1
	fi
fi

ko_root=$(cd "$script_dir/.." && pwd)
dockerfile_digest=$(cat "$script_dir/ci-like/Dockerfile" "$script_dir/install-zig.sh" "$ko_root/rust-toolchain.toml" | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-12)
image="ko-ci-like:$dockerfile_digest"

if ! "$podman" image exists "$image" 2>/dev/null; then
	echo "==> building $image (installs the toolchains; can take several minutes)" >&2
	"$podman" build \
		-t "$image" \
		-f "$script_dir/ci-like/Dockerfile" \
		"$ko_root"
fi

userns_args=()
if [ "$("$podman" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
	userns_args=(--userns=keep-id)
else
	repo_owner=$(stat -f '%u:%g' "$repo_root" 2>/dev/null || stat -c '%u:%g' "$repo_root")
	userns_args=(--user "$repo_owner")
fi

# A linked worktree's .git file names a directory of the main repository, which the
# container needs for git (ko_server/build.rs reads the ghostty pin through it).
git_args=()
if [ -f "$repo_root/.git" ]; then
	git_common=$(cd "$(sed -n 's/^gitdir: //p' "$repo_root/.git")/../.." && pwd)
	git_args=(-v "$git_common:$git_common:ro")
fi

env_args=()
for var in $(env | awk -F= '/^KO_/{print $1}'); do
	case "$var" in
	KO_STATE_DIR) continue ;; # always the container's own, below
	KO_AGENT_* | KO_PANE | KO_SOCKET | KO_RUN_ID | KO_RUN_OUTPUT) continue ;; # the host's own pane and parent edge, never the container's
	esac
	env_args+=(-e "$var")
done

busy_names=()
cleanup() {
	for name in ${busy_names[@]+"${busy_names[@]}"}; do
		"$podman" stop -t 1 "$name" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

if [ "$contend" -gt 0 ]; then
	sibling_cpus=$(awk -v b="$budget" -v c="$cpus" -v n="$contend" 'BEGIN{printf "%.3f", (b-c)/n}')
	if awk -v s="$sibling_cpus" 'BEGIN{exit !(s <= 0)}'; then
		echo "ci-like.sh: --cpus $cpus leaves nothing of the --budget $budget for $contend sibling(s); raise --budget or lower --cpus" >&2
		exit 1
	fi
	echo "==> starting $contend busy sibling container(s) for contention, $sibling_cpus cpu each (budget $budget total)" >&2
	for i in $(seq 1 "$contend"); do
		name="ko-ci-like-busy-$$-$i"
		"$podman" run -d --rm --name "$name" --cpus "$sibling_cpus" busybox \
			sh -c 'for i in $(seq 1 16); do (while true; do :; done) & done; wait' >/dev/null
		busy_names+=("$name")
	done
	sleep 2 # let each sibling's 16 threads actually ramp up before the run starts
fi

cpu_shares_args=()
if [ -n "$cpu_shares" ]; then
	cpu_shares_args=(--cpu-shares "$cpu_shares")
fi

container_name="ko-ci-like-$$"
watcher_pid=""
if [ "$timeout_s" -gt 0 ]; then
	(
		sleep "$timeout_s"
		"$podman" stop -t 2 "$container_name" >/dev/null 2>&1
	) >/dev/null 2>&1 &
	watcher_pid=$!
fi

status=0
"$podman" run --rm --init \
	--name "$container_name" \
	--cpus "$cpus" \
	--memory "$memory" \
	--shm-size 1g \
	${cpu_shares_args[@]+"${cpu_shares_args[@]}"} \
	${userns_args[@]+"${userns_args[@]}"} \
	-e KO_STATE_DIR=/tmp/ko-state \
	-e HOME=/home/ci \
	${env_args[@]+"${env_args[@]}"} \
	-v "$repo_root:/repo:Z" \
	${git_args[@]+"${git_args[@]}"} \
	-v ko-ci-like-target:/repo/target \
	-v ko-ci-like-build:/repo/build \
	-w /repo \
	"$image" \
	"$@" || status=$?

if [ -n "$watcher_pid" ]; then
	kill "$watcher_pid" 2>/dev/null || true
	wait "$watcher_pid" 2>/dev/null || true
fi

exit "$status"
