#!/bin/bash
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
tools=$HOME/.local/share/ko-tools
mkdir -p "$tools" "$HOME/.local/bin"
if ! cmp -s "$base/tools/package-lock.json" "$tools/installed-lock.json"; then
    rm -f "$tools/installed-lock.json"
    cp "$base/tools/package.json" "$base/tools/package-lock.json" "$tools/"
    npm ci --prefix "$tools" --no-audit --no-fund
    "$tools/node_modules/.bin/claude" --version
    "$tools/node_modules/.bin/pi" --version
    cp "$tools/package-lock.json" "$tools/installed-lock.json"
fi
ln -sfn "$tools/node_modules/.bin/pi" "$HOME/.local/bin/pi"
ln -sfn "$tools/node_modules/.bin/claude" "$HOME/.local/bin/claude"
ln -sfn /usr/bin/fdfind "$HOME/.local/bin/fd"
if [[ ! -e $HOME/.pi/agent/settings.json ]]; then
    install -D -m 0644 "$base/files/pi-settings.json" "$HOME/.pi/agent/settings.json"
fi
