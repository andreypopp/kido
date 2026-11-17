#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
container build --cpus 2 --memory 2G --progress plain --tag ko-quic-test:debian13 "$root/scripts/quic-test-image"
