#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dry=false
if [[ ${1:-} == --dry-run ]]; then dry=true; shift; fi
version=${1:?usage: scripts/release.sh [--dry-run] VERSION}
if [[ ${2:-} == --dry-run ]]; then dry=true; fi
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be major.minor.patch' >&2; exit 1; }
action() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if ! $dry; then "$@"; fi
}
tap=$(brew --repo andreypopp/tap)
formula="$tap/Formula/kido.rb"
ssh_tap="$HOME/Workspace/homebrew-tap"
action git fetch origin main
sha=$(git rev-parse origin/main)
echo "+ gh run list --commit $sha --json conclusion,status --limit 100"
ci=$(gh run list --commit "$sha" --json conclusion,status --limit 100)
python3 -c 'import json,sys; runs=json.loads(sys.argv[1]); assert runs and all(r["status"]=="completed" and r["conclusion"]=="success" for r in runs), "origin/main CI is not all green"' "$ci"
read -r old previous < <(python3 - "$formula" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
print(re.search(r'revision: "([a-f0-9]+)"',s)[1],re.search(r'version "([^"]+)"',s)[1])
PY
)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for rev in "$old" "$sha"; do
  mkdir "$work/$rev"
  echo "+ git archive $rev | tar -x -C $work/$rev"
  git archive "$rev" | tar -x -C "$work/$rev"
  echo "+ (cd $work/$rev && dune build bin/main.exe)"
  (cd "$work/$rev" && dune build bin/main.exe)
  "$work/$rev/_build/default/bin/main.exe" --help=plain > "$work/$rev/top.help"
  "$work/$rev/_build/default/bin/main.exe" tool --help=plain > "$work/$rev/tool.help"
done
python3 - "$work" "$old" "$sha" "$previous" "$version" <<'PY'
import json,re,sys,pathlib
root,old,new,previous,version=sys.argv[1:]
def names(rev):
    p=pathlib.Path(root)/rev
    tools=json.loads((p/'share/pi/testdata/tools.json').read_text())
    result={'tool:'+n for n in tools}
    for scope in ('top','tool'):
        help=(p/(scope+'.help')).read_text().split('COMMANDS\n',1)[1]
        help=re.split(r'\n[A-Z][A-Z ]*\n',help,maxsplit=1)[0]
        result.update(scope+':'+x for x in re.findall(r'^       ([a-z][a-z_-]+)(?: |$)',help,re.M))
    return result
before=tuple(map(int,previous.split('.')))
after=tuple(map(int,version.split('.')))
if after<=before: sys.exit('VERSION must increase')
removed=names(old)-names(new)
if removed:
    print('Removed commands/tools: '+', '.join(sorted(removed)))
    print('panes must be restarted, not /reloaded')
    if after[:2]<=before[:2]: sys.exit('Removed or renamed commands/tools require a minor version bump')
else: print('Patch release is sufficient')
PY
[[ -z $(git -C "$tap" status --porcelain) && -z $(git -C "$ssh_tap" status --porcelain) ]] || { echo 'Tap checkout is dirty' >&2; exit 1; }
remote=$(git -C "$ssh_tap" remote get-url --push origin)
[[ $remote == git@* || $remote == ssh://* ]] || { echo 'Workspace tap must push over SSH' >&2; exit 1; }
action git -C "$ssh_tap" pull --ff-only origin main
action git -C "$tap" pull --ff-only "$ssh_tap" HEAD
if $dry; then
  echo "+ edit $formula: revision: $sha, version $version"
else
  python3 - "$formula" "$sha" "$version" <<'PY'
import re,sys,pathlib
p=pathlib.Path(sys.argv[1]); s=p.read_text()
s=re.sub(r'revision: "[a-f0-9]+"','revision: "'+sys.argv[2]+'"',s,count=1)
s=re.sub(r'version "[^"]+"','version "'+sys.argv[3]+'"',s,count=1)
p.write_text(s)
PY
fi
action git -C "$tap" add Formula/kido.rb
action git -C "$tap" commit -m "kido $version"
action git -C "$ssh_tap" fetch "$tap" HEAD
action git -C "$ssh_tap" merge --ff-only FETCH_HEAD
action git -C "$ssh_tap" push origin HEAD
