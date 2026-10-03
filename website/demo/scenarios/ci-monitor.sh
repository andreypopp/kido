#!/bin/bash
set -eu
printf '%s\n' 'commit a22dfd pushed to main, starting CI'
deadline=$((SECONDS + 90))
while [[ ! -e "$KIDO_DEMO_CI_SIGNAL" && $SECONDS -lt $deadline ]]; do
  /bin/sleep 0.2
done
printf '%s\n' 'CI failed, check logs'
deadline=$((SECONDS + 300))
while [[ $SECONDS -lt $deadline ]]; do
  /bin/sleep 1
done
