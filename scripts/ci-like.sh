#!/usr/bin/env bash
# Run a test command inside a Linux container with the repo bind-mounted
# and CPU/memory capped, so a CI-runner-only failure (slow, contended
# hardware) can be reproduced without saturating the host's cores the way
# `go test -parallel N` on every core does.
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
#
# A run never takes more of the host than --budget: the test container gets
# --cpus, and whatever is left of the budget is split as a CPU quota across
# the --contend siblings, however many threads each of them spins. The cap
# matters because the siblings exist to be busy - uncapped, N of them at 16
# spinning threads saturate every core the podman machine has, which are
# the host's cores, and the machine that is being kept honest for one
# reproduction stalls every other thing running on the box. Contention is
# for chasing one named failure; a whole-suite run wants no siblings at all.
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
# The command runs as a non-root uid, the one owning the bind-mounted repo
# - a GitHub runner is the `runner` user, and a test asserting a file
# chmodded to 000 is unreadable holds for nobody else. Under rootless
# podman that is --userns=keep-id, which maps the caller's uid to itself
# inside the container and leaves the bind mount writable with no chown;
# under a rootful podman the mapping is already the identity, so the uid
# is passed with --user instead. The locale is the image's (C.UTF-8, see
# its Dockerfile), so no caller has to pass one.
#
# The env -u list is the one AGENTS.md's "Working here as a spawned agent"
# gives for running the suites: it strips the agent-tracking variables so
# the command runs as it would on a CI runner, not as a spawned subagent.
#
# The image is built once per tmux fork revision and cached by a tag that
# includes it and a digest of the Dockerfile (kido-ci-like:<sha>-<digest>),
# so a tap bump or an edit to the image rebuilds automatically; podman's
# own layer cache keeps the rebuild off the tmux compile.

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

kido_repo_root=$(cd "$script_dir/.." && pwd)
tmux_revision=$("$script_dir/install-tmux-fork.sh" --print-revision)
dockerfile_digest=$( (shasum -a 256 "$script_dir/ci-like/Dockerfile" 2>/dev/null || sha256sum "$script_dir/ci-like/Dockerfile") | cut -c1-12)
image="kido-ci-like:$tmux_revision-$dockerfile_digest"

if ! "$podman" image exists "$image" 2>/dev/null; then
	echo "==> building $image (first build compiles the tmux fork from source; can take several minutes)" >&2
	# The build context is kido's own repo root, not scripts/: the
	# Dockerfile builds the fork from third_party/tmux, which only exists
	# there.
	"$podman" build \
		--build-arg "TMUX_REVISION=$tmux_revision" \
		-t "$image" \
		-f "$script_dir/ci-like/Dockerfile" \
		"$kido_repo_root"
fi

userns_args=()
if [ "$("$podman" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
	userns_args=(--userns=keep-id)
else
	repo_owner=$(stat -f '%u:%g' "$repo_root" 2>/dev/null || stat -c '%u:%g' "$repo_root")
	userns_args=(--user "$repo_owner")
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
	sibling_cpus=$(awk -v b="$budget" -v c="$cpus" -v n="$contend" 'BEGIN{printf "%.3f", (b-c)/n}')
	if awk -v s="$sibling_cpus" 'BEGIN{exit !(s <= 0)}'; then
		echo "ci-like.sh: --cpus $cpus leaves nothing of the --budget $budget for $contend sibling(s); raise --budget or lower --cpus" >&2
		exit 1
	fi
	echo "==> starting $contend busy sibling container(s) for contention, $sibling_cpus cpu each (budget $budget total)" >&2
	for i in $(seq 1 "$contend"); do
		name="kido-ci-like-busy-$$-$i"
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
	"${userns_args[@]}" \
	-e KIDO_STATE_DIR=/tmp/kido-state \
	-e HOME=/home/ci \
	"${env_args[@]}" \
	-v "$repo_root:/repo:Z" \
	-v kido-ci-like-gomodcache:/go/pkg/mod \
	-v kido-ci-like-gocache:/gocache \
	-w /repo \
	"$image" \
	env -u KIDO_AGENT_PARENT_INSTANCE -u KIDO_AGENT_DEPTH -u KIDO_AGENT_TASK_FILE -u KIDO_AGENT_PARENT_PID -u TMUX_PANE \
	"$@" || status=$?

if [ -n "$watcher_pid" ]; then
	kill "$watcher_pid" 2>/dev/null || true
	wait "$watcher_pid" 2>/dev/null || true
fi

exit "$status"
