#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dry=false
ci=true
product=
version=
for arg in "$@"; do
  case $arg in
    --dry-run) dry=true ;;
    --no-ci) ci=false ;;
    ko|koa|kow) [[ -z $product ]] || exit 1; product=$arg ;;
    *) [[ -z $version && $arg != -* ]] || exit 1; version=$arg ;;
  esac
done
[[ -n $product && -n $version ]] || { echo 'usage: scripts/release.sh [--dry-run] [--no-ci] ko|koa|kow VERSION' >&2; exit 1; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be major.minor.patch' >&2; exit 1; }
action() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if ! $dry; then "$@"; fi
}
tap=${KO_RELEASE_TAP:-$(brew --repo andreypopp/tap)}
formula="$tap/Formula/$product.rb"
ssh_tap=${KO_RELEASE_SSH_TAP:-$HOME/Workspace/homebrew-tap}
action git fetch origin main
sha=$(git rev-parse origin/main)
if [[ $(git rev-parse HEAD) != "$sha" ]]; then
  echo "HEAD is not origin/main: the comparison reads this checkout's build" >&2
  $dry || exit 1
fi
if { [[ $product == kow ]] && [[ -n $(git status --porcelain -- kow scripts/release.sh) ]]; } ||
   { [[ $product == koa ]] && [[ -n $(git status --porcelain -- koa webview) ]]; } ||
   { [[ $product == ko ]] && [[ -n $(git status --porcelain) ]]; }; then
  echo "$product has uncommitted changes: the tarball and comparison would not match the release tag" >&2
  $dry || exit 1
fi
if $ci; then
  echo "+ gh run list --commit $sha --json conclusion,status --limit 100"
  runs=$(gh run list --commit "$sha" --json conclusion,status --limit 100)
  python3 -c 'import json,sys; runs=json.loads(sys.argv[1]); assert runs and all(r["status"]=="completed" and r["conclusion"]=="success" for r in runs), "origin/main CI is not all green"' "$runs"
else
  echo 'CI check skipped (--no-ci)' >&2
fi
[[ -z $(git -C "$tap" status --porcelain) && -z $(git -C "$ssh_tap" status --porcelain) ]] || { echo 'Tap checkout is dirty' >&2; exit 1; }
remote=$(git -C "$ssh_tap" remote get-url --push origin)
[[ $remote == git@* || $remote == ssh://* ]] || { echo 'Workspace tap must push over SSH' >&2; exit 1; }
action git -C "$ssh_tap" pull --ff-only origin main
action git -C "$tap" pull --ff-only "$ssh_tap" HEAD
work=$(mktemp -d /tmp/koa-release-XXXXXX)
if ! $dry; then trap 'rm -rf "$work"' EXIT; fi
previous=
if [[ -f $formula ]]; then
  previous=$(python3 -c 'import re,sys; print(re.search(r"version \"([^\"]+)\"",open(sys.argv[1]).read())[1])' "$formula")
fi
if [[ $product == kow ]]; then
  python="$(brew --prefix python)/bin/python3"
  [[ -x $python ]] || { echo 'kow release requires Homebrew python; run brew install python' >&2; exit 1; }
  "$python" kow/kow --check-pins
  if [[ -n $previous ]]; then
    python3 -c 'import sys; assert tuple(map(int,sys.argv[2].split("."))) > tuple(map(int,sys.argv[1].split("."))), "VERSION must increase"' "$previous" "$version"
  fi
  archive="$work/kow-$version.tar.gz"
  tar -czf "$archive" -C kow kow
  digest=$(shasum -a 256 "$archive" | awk '{print $1}')
  action git tag -a "kow/$version" "$sha" -m "kow $version"
  action git push origin "kow/$version"
  action gh release create "kow/$version" "$archive" --repo andreypopp/kido --title "kow $version" --notes 'Install with brew install andreypopp/tap/kow.'
  formula_text=$(cat <<RUBY
class Kow < Formula
  include Language::Python::Shebang

  desc "Manage a ko workspace server"
  homepage "https://github.com/andreypopp/kido"
  url "https://github.com/andreypopp/kido/releases/download/kow/$version/kow-$version.tar.gz"
  sha256 "$digest"
  version "$version"
  depends_on "python"
  depends_on "opentofu"

  def install
    bin.install "kow"
    rewrite_shebang detected_python_shebang, bin/"kow"
  end

  test do
    system bin/"kow", "--help"
  end
end
RUBY
)
  if $dry; then
    echo "+ write $formula"
    printf '%s\n' "$formula_text"
    echo "+ tarball $archive"
  else
    printf '%s\n' "$formula_text" > "$formula"
  fi
  action git -C "$tap" add Formula/kow.rb
  action git -C "$tap" commit -m "kow $version"
  action git -C "$ssh_tap" fetch "$tap" HEAD
  action git -C "$ssh_tap" merge --ff-only FETCH_HEAD
  action git -C "$ssh_tap" push origin HEAD
  exit 0
fi
if [[ $product == ko ]]; then
  [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'ko release requires a Darwin arm64 host' >&2; exit 1; }
  python3 - "$tap/Formula/ko-bin.rb" "$version" <<'PY'
import re,sys
before=re.search(r'version "([^"]+)"',open(sys.argv[1]).read())[1]
if tuple(map(int,sys.argv[2].split('.'))) <= tuple(map(int,before.split('.'))):
    sys.exit('VERSION must increase over ko-bin')
PY
  old=$(python3 -c 'import re,sys; print(re.search(r"revision: \"([a-f0-9]+)\"",open(sys.argv[1]).read())[1])' "$formula")
  old_ko=${KO_RELEASE_OLD_KO:-$(brew --prefix ko)/bin/ko}
  installed=$("$old_ko" version | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])')
  [[ $old == "$installed"* ]] || { echo "The installed ko ($installed) is not the formula revision ($old): brew upgrade ko first" >&2; exit 1; }
  rm -rf build/ko
  make install PREFIX="$work/darwin" LINUX_ARCHS=aarch64
  make build-linux LINUX_ARCHS=x86_64
  make check-static LINUX_ARCHS="aarch64 x86_64"
  "$old_ko" --help > "$work/old"
  build/ko/bin/ko --help > "$work/new"
else
  if [[ -n $previous ]]; then git show "koa/$previous:koa/testdata/ko-prompts.txt" > "$work/old"; fi
  cp koa/testdata/ko-prompts.txt "$work/new"
fi
python3 - "$work" "$previous" "$version" "$product" <<'PY'
import re,sys,pathlib
root,previous,version,product=sys.argv[1:]
if not previous: sys.exit(0)
def names(which):
    text=(pathlib.Path(root)/which).read_text()
    if product=='ko':
        text=re.split(r'\n\S',text.split('Commands:\n',1)[1],maxsplit=1)[0]
        return set(re.findall(r'^  ([a-z][a-z-]*)(?: |$)',text,re.M))
    text=text.split('## Tools\n',1)[1].split('\n## ',1)[0]
    return set(re.findall(r'^### (.+)$',text,re.M))
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
if [[ $product == ko ]]; then
  archives=()
  digests=()
  for platform in darwin-arm64 linux-arm64 linux-x86_64; do
    case $platform in
      darwin-arm64) source="$work/darwin" ;;
      linux-arm64) source=build/ko/share/ko/linux/aarch64 ;;
      linux-x86_64) source=build/ko/share/ko/linux/x86_64 ;;
    esac
    archive="$work/ko-$version-$platform.tar.gz"
    tar -czf "$archive" -C "$source" bin share
    digest=$(shasum -a 256 "$archive" | awk '{print $1}')
    printf '%s  %s\n' "$digest" "$archive"
    archives+=("$archive")
    digests+=("$digest")
  done
  python3 - "$tap" "$work" "$sha" "$version" "${archives[@]}" "${digests[@]}" <<'PY'
import pathlib,re,sys
tap,work,sha,version,*assets=sys.argv[1:]
for name in ['ko','ko-bin']:
    text=(pathlib.Path(tap)/'Formula'/f'{name}.rb').read_text()
    text=re.sub(r'version "[^"]+"',f'version "{version}"',text,count=1)
    if name=='ko':
        text=re.sub(r'revision: "[a-f0-9]+"',f'revision: "{sha}"',text,count=1)
        text=re.sub(r'^\s*depends_on "node(?:@[0-9]+)?"\s*=>\s*:build[^\n]*\n','',text,flags=re.M)
    else:
        for archive,digest in zip(assets[:3],assets[3:],strict=True):
            path=pathlib.Path(archive)
            platform=path.name.removeprefix(f'ko-{version}-').removesuffix('.tar.gz')
            pattern=r'url "[^"]*/ko/[^/]+/ko-[^"]+-'+re.escape(platform)+r'\.tar\.gz"\s*\n\s*sha256 "[^"]+"'
            text,count=re.subn(pattern,f'url "https://github.com/andreypopp/kido/releases/download/ko/{version}/{path.name}"\n      sha256 "{digest}"',text)
            if count!=1: sys.exit(f'Expected one {platform} asset in ko-bin formula')
        text=re.sub(r'(  def caveats\n).*?(\n  end)',r'\1    <<~EOS\n      Install koa separately with brew install andreypopp/tap/koa.\n    EOS\2',text,count=1,flags=re.S)
    (pathlib.Path(work)/f'{name}.rb').write_text(text)
PY
  action git tag -a "ko/$version" "$sha" -m "ko $version"
  action git push origin "ko/$version"
  action gh release create "ko/$version" "${archives[@]}" --repo andreypopp/kido --title "ko $version" --latest=false --notes 'koa is a separate package: brew install andreypopp/tap/koa'
  for name in ko ko-bin; do
    if $dry; then
      echo "+ write $tap/Formula/$name.rb"
      cat "$work/$name.rb"
    else
      cp "$work/$name.rb" "$tap/Formula/$name.rb"
    fi
  done
else
  rm -rf build/koa
  make -C koa build
  archive="$work/koa-$version.tar.gz"
  tar -czf "$archive" -C build/koa bin share
  digest=$(shasum -a 256 "$archive" | awk '{print $1}')
  action git tag -a "koa/$version" "$sha" -m "koa $version"
  action git push origin "koa/$version"
  action gh release create "koa/$version" "$archive" --repo andreypopp/kido --title "koa $version" --notes 'Install with brew install andreypopp/tap/koa. Update with brew upgrade koa, then /reload in each koa pane.'
  formula_text=$(cat <<RUBY
class Koa < Formula
  desc "Agent harness for ko"
  homepage "https://github.com/andreypopp/kido"
  url "https://github.com/andreypopp/kido/releases/download/koa/$version/koa-$version.tar.gz"
  sha256 "$digest"
  version "$version"
  depends_on "node"
  depends_on "andreypopp/tap/pi-coding-agent"

  def install
    prefix.install "bin", "share"
  end

  def caveats
    <<~EOS
      koa runs in a pane of ko, from Kido.app or the ko or ko-bin formula.
    EOS
  end

  test do
    system bin/"koa", "--help", "--pi", "/nonexistent"
  end
end
RUBY
)
  if $dry; then
    echo "+ write $formula"
    printf '%s\n' "$formula_text"
    echo "+ tarball $archive"
  else
    printf '%s\n' "$formula_text" > "$formula"
  fi
fi
if [[ $product == ko ]]; then
  action git -C "$tap" add Formula/ko.rb Formula/ko-bin.rb
else
  action git -C "$tap" add Formula/koa.rb
fi
action git -C "$tap" commit -m "$product $version"
action git -C "$ssh_tap" fetch "$tap" HEAD
action git -C "$ssh_tap" merge --ff-only FETCH_HEAD
action git -C "$ssh_tap" push origin HEAD
