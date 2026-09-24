#!/usr/bin/env bash
# Run a test command inside a Linux container with the repo bind-mounted
# and CPU/memory capped, so a CI-runner-only failure (slow, contended
# hardware) can be reproduced without saturating the host's cores the way
# `go test -parallel N` on every core does.
#
# Usage: scripts/ci-like.sh [--cpus N] [--memory SIZE] [--timeout SECONDS]
#                            [--cpu-shares N] [--contend N] -- <command...>
#
#   --cpus N        CPU quota handed to the container (default 0.5)
#   --memory SIZE   memory limit, podman syntax e.g. 1g (default 1g)
#   --timeout SEC   kill the container if it runs longer than this (default 300)
#   --cpu-shares N  relative CPU weight against --contend's siblings (podman
#                   default 1024; pass a low number, e.g. 1, to be reliably
#                   outweighed by them)
#   --contend N     start N independent busy sibling containers (each
#                   spinning 16 threads) before running, removed on exit
#
# A CPU quota alone throttles the whole test container in lockstep - the
# command being tested and its own child processes pause and resume
# together, so their relative timing survives even a severe cap. What a
# contended CI runner actually does is different: independent processes
# (or, here, independent cgroups) compete for the same cores, so how much
# of any given instant a thread gets depends on what else is runnable at
# that instant - which desynchronizes a wrapper's batching timer from the
# command it is timing. Hence --contend: several separate busy containers
# reproduce that competition; one large one does not, measured against
# the timing regression below.
#
# Any KIDO_* variable already set in the caller's environment is passed
# through into the container. KIDO_TMUX and KIDO_STATE_DIR are always the
# container's own (the fork built into the image, and a directory under
# /tmp inside the container) regardless of what the host has set, so this
# never touches the host's tmux, kido or state dir.
#
# The env -u list is the one AGENTS.md's "Working here as a spawned agent"
# gives for running the suites: it strips the agent-tracking variables so
# the command runs as it would on a CI runner, not as a spawned subagent.
#
# The image is built once per tmux fork revision and cached by a tag that
# includes it (kido-ci-like:<sha>), so a tap bump rebuilds automatically.

set -euo pipefail

cpus=0.5
memory=1g
timeout_s=300
cpu_shares=
contend=0

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
	echo "usage: scripts/ci-like.sh [--cpus N] [--memory SIZE] [--timeout SECONDS] [--cpu-shares N] [--contend N] -- <command...>" >&2
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

tmux_revision=$("$script_dir/install-tmux-fork.sh" --print-revision)
image="kido-ci-like:$tmux_revision"

if ! "$podman" image exists "$image" 2>/dev/null; then
	echo "==> building $image (first build compiles the tmux fork from source; can take several minutes)" >&2
	"$podman" build \
		--build-arg "TMUX_REVISION=$tmux_revision" \
		-t "$image" \
		-f "$script_dir/ci-like/Dockerfile" \
		"$script_dir"
fi

env_args=()
for var in $(env | awk -F= '/^KIDO_/{print $1}'); do
	case "$var" in
	KIDO_TMUX | KIDO_STATE_DIR) continue ;; # always the container's own, below
	esac
	env_args+=(-e "$var")
done

busy_names=()
cleanup() {
	for name in "${busy_names[@]}"; do
		"$podman" stop -t 1 "$name" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

if [ "$contend" -gt 0 ]; then
	echo "==> starting $contend busy sibling container(s) for contention" >&2
	for i in $(seq 1 "$contend"); do
		name="kido-ci-like-busy-$$-$i"
		"$podman" run -d --rm --name "$name" busybox \
			sh -c 'for i in $(seq 1 16); do (while true; do :; done) & done; wait' >/dev/null
		busy_names+=("$name")
	done
	sleep 2 # let each sibling's 16 threads actually ramp up before the run starts
fi

cpu_shares_args=()
if [ -n "$cpu_shares" ]; then
	cpu_shares_args=(--cpu-shares "$cpu_shares")
fi

container_name="kido-ci-like-$$"
watcher_pid=""
if [ "$timeout_s" -gt 0 ]; then
	(
		sleep "$timeout_s"
		"$podman" stop -t 2 "$container_name" >/dev/null 2>&1
	) &
	watcher_pid=$!
fi

status=0
"$podman" run --rm \
	--name "$container_name" \
	--cpus "$cpus" \
	--memory "$memory" \
	"${cpu_shares_args[@]}" \
	-e KIDO_STATE_DIR=/tmp/kido-state \
	"${env_args[@]}" \
	-v "$repo_root:/repo:Z" \
	-v kido-ci-like-gomodcache:/go/pkg/mod \
	-v kido-ci-like-gobuildcache:/root/.cache/go-build \
	-w /repo \
	"$image" \
	env -u KIDO_AGENT_PARENT_INSTANCE -u KIDO_AGENT_DEPTH -u KIDO_AGENT_TASK_FILE -u KIDO_AGENT_PARENT_PID -u TMUX_PANE \
	"$@" || status=$?

if [ -n "$watcher_pid" ]; then
	kill "$watcher_pid" 2>/dev/null || true
	wait "$watcher_pid" 2>/dev/null || true
fi

exit "$status"
