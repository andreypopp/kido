#!/bin/sh
# Install the files kido reads beside its binary into <dest>, which is
# <prefix>/share/kido: the layout findShared looks for and the bin
# directory's shims work back from. `make install` runs it, and so does
# the e2e harness for the kido it builds, so the suite runs the layout an
# install has.
#
#   scripts/install-share.sh <dest>

set -eu

if [ $# -ne 1 ]; then
	echo "usage: $0 <dest>" >&2
	exit 2
fi
dest=$1
src=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$dest/shell/zsh" "$dest/shell/bash" "$dest/bin" "$dest/pi" "$dest/claude"
cp "$src/shell/zsh/integration.zsh" "$dest/shell/zsh/integration.zsh"
cp "$src/shell/bash/integration.bash" "$dest/shell/bash/integration.bash"
cp "$src/shims/shim.sh" "$dest/shim.sh"
for f in tmux ssh pi claude; do
	cp "$src/shims/bin/$f" "$dest/bin/$f"
	chmod 755 "$dest/bin/$f"
done
cp "$src/pi/kido-status.ts" "$src/pi/kido-agents.ts" "$dest/pi/"
cp "$src/claude/settings.json" "$dest/claude/settings.json"
