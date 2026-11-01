#!/usr/bin/env bash
# Regenerates ko_vt_sys/src/bindings.rs from the pinned libghostty-vt headers.
# Needs the bindgen CLI (cargo install --locked bindgen-cli) and libclang;
# on macOS LIBCLANG_PATH may name the Command Line Tools' usr/lib.
set -euo pipefail
cd "$(dirname "$0")/.."
include=third_party/ghostty/include
case "${1:-}" in
  --print-hash)
    find "$include" -type f -name '*.h' | LC_ALL=C sort | xargs cat | shasum -a 256 | cut -d' ' -f1
    exit 0 ;;
  '') ;;
  *) echo "usage: scripts/bindgen.sh [--print-hash]" >&2; exit 1 ;;
esac
hash=$("$0" --print-hash)
bindgen "$include/ghostty/vt.h" \
  --rust-target 1.85 --rust-edition 2024 \
  --allowlist-function 'ghostty_.*' \
  --allowlist-type 'Ghostty.*' \
  --allowlist-var 'GHOSTTY_.*' \
  --no-prepend-enum-name \
  --with-derive-default \
  --no-doc-comments \
  --raw-line "// ghostty headers sha256: $hash" \
  --output ko_vt_sys/src/bindings.rs \
  -- -I"$include"
