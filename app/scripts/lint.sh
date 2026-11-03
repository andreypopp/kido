#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
find app/App app/Packages/*/Sources -name '*.swift' ! -path app/App/Chrome.swift -exec awk '
function masked(s,    i,c,out,quoted,escaped) {
    comment = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s,i,1)
        if (!quoted && c == "/" && substr(s,i+1,1) == "/") { comment = substr(s,i); break }
        if (quoted) {
            if (escaped) escaped = 0
            else if (c == "\\") escaped = 1
            else if (c == "\"") quoted = 0
            out = out " "
        } else if (c == "\"") { quoted = 1; out = out " " }
        else out = out c
    }
    return out
}
{
    s = masked($0)
    if (comment ~ /^\/\/ chrome-allow: .+$/) next
    if (s ~ /(^|[^[:alnum:]_])(NSColor|CGColor|Color)[[:space:]]*\(/ ||
        s ~ /\.init[[:space:]]*\([[:space:]]*srgbRed[[:space:]]*:/ ||
        s ~ /\([[:space:]]*(red|white|gray|hue)[[:space:]]*:/ ||
        s ~ /(^|[^[:alnum:]_?])\.(labelColor|secondaryLabelColor|tertiaryLabelColor|separatorColor|windowBackgroundColor|controlAccentColor|white|black)([^[:alnum:]_]|$)/ ||
        s ~ /NSColor\.(labelColor|secondaryLabelColor|tertiaryLabelColor|separatorColor|windowBackgroundColor|controlAccentColor|white|black)([^[:alnum:]_]|$)/ ||
        s ~ /NSColor\.system[A-Z][a-z]+([^[:alnum:]_]|$)/ ||
        s ~ /\.system(Red|Green|Orange|Blue|Yellow|Pink|Purple|Brown|Gray|Teal|Indigo|Mint|Cyan)([^[:alnum:]_]|$)/ ||
        s ~ /withAlphaComponent[[:space:]]*\(/ ||
        s ~ /shadow(Opacity|Radius|BlurRadius|Color)[[:space:]]*(=[[:space:]]*|\([[:space:]]*)[0-9.]/) {
        print FILENAME ":" FNR ": " $0
        failed = 1
    }
}
END { if (failed) exit 1 }
' {} +

# A surface's terminal changes only on its view's decoder thread: the restore and the grid size in
# KoClient.swift, the pty output in KoClient.swift and PaneView.feed. The one exception is a fetched
# Kitty image frame: PaneImages attaches it from its fetch task, and the surface refuses a stale stamp.
writers=$(grep -rnE 'ghostty_surface_(restore_snapshot|set_grid_size)' app/App --include='*.swift' | grep -v '^app/App/Ko/KoClient.swift:' || true)
writers="$writers$(grep -rnE 'ghostty_surface_process_output' app/App --include='*.swift' | grep -v '^app/App/Ko/KoClient.swift:\|^app/App/PaneView.swift:' || true)"
writers="$writers$(grep -rnE 'ghostty_surface_kitty_frame_(attach|adopt)' app/App --include='*.swift' | grep -v '^app/App/PaneImages.swift:' || true)"
if [ -n "$writers" ]; then
	echo "lint.sh: a surface's terminal changes only on its view's decoder thread:" >&2
	echo "$writers" >&2
	exit 1
fi
