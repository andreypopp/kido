#!/usr/bin/env bash
set -euf -o pipefail
cd "$(dirname "$0")/.."
dry=0
if [[ ${1:-} == --dry-run ]]; then dry=1; shift; fi
if (( $# > 1 )) || [[ ${1:-} == -* ]]; then
  echo 'Usage: scripts/checks.sh [--dry-run] [BASE]' >&2
  exit 1
fi
base=${1:-}
if [[ -z $base ]]; then
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || upstream=origin/main
  base=$(git merge-base HEAD "$upstream")
fi
if [[ ${KO_CHECKS_PATHS+x} ]]; then
  paths=$KO_CHECKS_PATHS
else
  changed=$(git diff --name-only --no-renames "$base")
  untracked=$(git ls-files --others --exclude-standard)
  paths=$(printf '%s\n%s\n' "$changed" "$untracked" | sort -u)
fi
printf 'Base: %s\n' "$base"
if [[ -z $paths ]]; then echo 'no changes'; exit 0; fi
all='build build-linux lint unit e2e ts verus app ko-test visual'
stages=' '
e2e=' '
visual=' '
e2e_all=0
visual_all=0
visual_file() {
  local names
  names=$(awk '
    /final class [A-Za-z_][A-Za-z_0-9]*: (VisualTestCase|AppWindowCase)/ {
      line = $0; sub(/.*final class /, "", line); sub(/:.*/, "", line); print line
    }
  ' "$1" 2>/dev/null) || names=
  if [[ -z $names ]]; then visual_all=1; fi
  for name in $names; do
    if [[ $visual != *" $name "* ]]; then visual+="$name "; fi
  done
}
while IFS= read -r path; do
  [[ -n $path ]] || continue
  while IFS='|' read -r patterns adds; do
    matched=0
    for pattern in $patterns; do
      if [[ $path == $pattern ]]; then matched=1; break; fi
    done
    (( matched )) || continue
    printf '%s -> %s\n' "$path" "$patterns"
    case $adds in
      all) adds=$all; e2e_all=1; visual_all=1 ;;
      module)
        module=${path##*/}; module=${module%.rs}
        case $module in
          main|harness|outer|sshd) adds='build lint unit e2e'; e2e_all=1 ;;
          *) adds='build lint-sh lint-rs e2e';
             if [[ $e2e != *" $module:: "* ]]; then e2e+="$module:: "; fi ;;
        esac ;;
      page) adds='build lint ts visual'; visual_file app/VisualTests/KoaWebviewTests.swift ;;
      snapshot)
        adds=visual; name=${path#app/VisualTests/__Snapshots__/}; name=${name%%/*}
        visual_file "app/VisualTests/$name.swift" ;;
      swift) adds=visual; visual_file "$path" ;;
      website) adds=; echo '  no check covers it' ;;
      *)
        [[ " $adds " != *' e2e '* ]] || e2e_all=1
        [[ " $adds " != *' visual '* ]] || visual_all=1 ;;
    esac
    stages+="$adds "
    break
  done <<'TABLE'
third_party/ghostty Makefile app/Makefile app/project.yml rust-toolchain.toml Cargo.toml Cargo.lock .cargo/* scripts/install-zig.sh scripts/verify.sh scripts/checks.sh .github/*|all
docs/* plans/* *.md|build lint-sh
ko_e2e/tests/e2e/*.rs|module
ko_e2e/*|build lint unit e2e
ko_pane_wire/* ko_server/* ko_wire/*|build lint unit e2e verus app ko-test
ko_client/* share/ko/*.json|build lint unit e2e app ko-test
ko_sys/* ko_vt_sys/*|build build-linux lint unit e2e
ko/* ko_*/* fuzz/* share/ko/*|build lint unit e2e
share/koa/page/*|page
share/pi/* share/koa/* share/webview/* .pi/* scripts/test-ts.sh|build lint ts
app/VisualTests/__Snapshots__/*/*|snapshot
app/VisualTests/*.swift|swift
app/VisualTests/*|visual
app/App/* app/Resources/*|app ko-test visual
app/*|app ko-test
website/*|website
scripts/* bench/*|build lint-sh lint-rs
*|all
TABLE
done <<< "$paths"
selected=
for stage in build build-linux lint lint-rs lint-sh unit e2e ts verus app ko-test visual; do
  [[ $stages == *" $stage "* ]] || continue
  case $stage in
    lint-rs|lint-sh) [[ $stages != *' lint '* ]] || continue ;;
  esac
  selected+="${selected:+ }$stage"
done
if (( e2e_all )); then e2e=; fi
if (( visual_all )); then visual=; fi
e2e=${e2e# }; e2e=${e2e% }
visual=${visual# }; visual=${visual% }
printf 'STAGES=%s\nE2E=%s\nVISUAL_ONLY=%s\n' "$selected" "$e2e" "$visual"
if (( dry )) || [[ -z $selected ]]; then exit 0; fi
STAGES=$selected E2E=$e2e VISUAL_ONLY=$visual bash scripts/verify.sh
