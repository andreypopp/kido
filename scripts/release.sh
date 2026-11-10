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
# KO_RELEASE_TAP, KO_RELEASE_SSH_TAP and KO_RELEASE_OLD_KO replace the tap checkout, its push checkout
# and the installed ko, for a dry run against a copy of the tap.
tap=${KO_RELEASE_TAP:-$(brew --repo andreypopp/tap)}
formula="$tap/Formula/ko.rb"
ssh_tap=${KO_RELEASE_SSH_TAP:-$HOME/Workspace/homebrew-tap}
old_ko=${KO_RELEASE_OLD_KO:-$(brew --prefix ko)/bin/ko}
action git fetch origin main
sha=$(git rev-parse origin/main)
if [[ $(git rev-parse HEAD) != "$sha" ]]; then
  echo "HEAD is not origin/main: the command diff reads this checkout's build" >&2
  $dry || exit 1
fi
echo "+ gh run list --commit $sha --json conclusion,status --limit 100"
ci=$(gh run list --commit "$sha" --json conclusion,status --limit 100)
python3 -c 'import json,sys; runs=json.loads(sys.argv[1]); assert runs and all(r["status"]=="completed" and r["conclusion"]=="success" for r in runs), "origin/main CI is not all green"' "$ci"
[[ -z $(git -C "$tap" status --porcelain) && -z $(git -C "$ssh_tap" status --porcelain) ]] || { echo 'Tap checkout is dirty' >&2; exit 1; }
remote=$(git -C "$ssh_tap" remote get-url --push origin)
[[ $remote == git@* || $remote == ssh://* ]] || { echo 'Workspace tap must push over SSH' >&2; exit 1; }
action git -C "$ssh_tap" pull --ff-only origin main
action git -C "$tap" pull --ff-only "$ssh_tap" HEAD
if ! grep -Eq '^[[:space:]]*depends_on[[:space:]]+"node(@[0-9]+)?"[[:space:]]*=>[[:space:]]*:build([[:space:]]|$)' "$formula"; then
  echo 'The tap’s ko formula lacks depends_on "node" => :build: make install bundles koa’s page with Node and npm; add it to Formula/ko.rb first' >&2
  $dry || exit 1
fi
read -r old previous < <(python3 - "$formula" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
print(re.search(r'revision: "([a-f0-9]+)"',s)[1],re.search(r'version "([^"]+)"',s)[1])
PY
)
installed=$("$old_ko" version | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])')
[[ $old == "$installed"* ]] || { echo "The installed ko ($installed) is not the formula's revision ($old): brew upgrade ko first" >&2; exit 1; }
make build
work=$(mktemp -d /tmp/ko-release-XXXXXX)
trap 'rm -rf "$work"' EXIT
"$old_ko" --help > "$work/old.help"
build/ko/bin/ko --help > "$work/new.help"
git show "$old:share/pi/testdata/ko-prompts.txt" > "$work/old.prompts"
cp share/pi/testdata/ko-prompts.txt "$work/new.prompts"
python3 - "$work" "$previous" "$version" <<'PY'
import re,sys,pathlib
root,previous,version=sys.argv[1:]
def names(which):
    p=pathlib.Path(root)
    help=(p/(which+'.help')).read_text().split('Commands:\n',1)[1]
    help=re.split(r'\n\S',help,maxsplit=1)[0]
    result={'command:'+x for x in re.findall(r'^  ([a-z][a-z-]*)(?: |$)',help,re.M)}
    text=(p/(which+'.prompts')).read_text().split('## Tools\n',1)[1].split('\n## ',1)[0]
    result.update('tool:'+x for x in re.findall(r'^### (.+)$',text,re.M))
    return result
before=tuple(map(int,previous.split('.')))
after=tuple(map(int,version.split('.')))
if after<=before: sys.exit('VERSION must increase')
removed=names('old')-names('new')
if removed:
    print('Removed commands/tools: '+', '.join(sorted(removed)))
    print('panes must be restarted, not /reloaded')
    if after[:2]<=before[:2]: sys.exit('Removed or renamed commands/tools require a minor version bump')
else: print('Patch release is sufficient')
PY
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
action git -C "$tap" add Formula/ko.rb
action git -C "$tap" commit -m "ko $version"
action git -C "$ssh_tap" fetch "$tap" HEAD
action git -C "$ssh_tap" merge --ff-only FETCH_HEAD
action git -C "$ssh_tap" push origin HEAD
