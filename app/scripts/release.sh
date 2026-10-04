#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dry=false
if [[ ${1:-} == --dry-run ]]; then dry=true; shift; fi
[[ $# == 1 && $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'usage: app/scripts/release.sh [--dry-run] VERSION' >&2; exit 1; }
version=$1
tag="kido-app/$version"
tap="$HOME/Workspace/homebrew-tap"
action() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if ! $dry; then "$@"; fi
}
[[ $(git branch --show-current) == kido-app && -z $(git status --porcelain) ]] || { echo 'Repository must be clean and on kido-app' >&2; exit 1; }
echo '+ git fetch origin kido-app'
git fetch origin kido-app
[[ $(git rev-parse HEAD) == $(git rev-parse origin/kido-app) ]] || { echo 'HEAD must equal origin/kido-app' >&2; exit 1; }
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag")
if [[ -n $remote_tag ]]; then
  echo "Tag $tag already exists on origin" >&2; exit 1
fi
local_tag=$(git tag --list "$tag")
if [[ -n $local_tag ]]; then
  tag_commit=$(git rev-parse "refs/tags/$tag^{commit}")
  head_commit=$(git rev-parse HEAD)
  [[ $tag_commit == "$head_commit" ]] || { echo "Local tag $tag points to $tag_commit, but HEAD is $head_commit" >&2; exit 1; }
fi
[[ $(git -C "$tap" branch --show-current) == main && -z $(git -C "$tap" status --porcelain) ]] || { echo 'Tap must be clean and on main' >&2; exit 1; }
brew_tap=$(brew --repo andreypopp/tap)
[[ -z $(git -C "$brew_tap" status --porcelain) ]] || { echo 'Homebrew tap checkout is dirty; refusing to update it' >&2; exit 1; }
make all CONFIG=Release DERIVED=build/derived-release GHOSTTY_OPTIMIZE=ReleaseFast \
  XCODE_SETTINGS="MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$version"
app=build/derived-release/Build/Products/Release/Kido.app
for key in CFBundleShortVersionString CFBundleVersion; do
  [[ $(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist") == "$version" ]] || { echo "$key must equal $version" >&2; exit 1; }
done
mkdir -p build/release
zip="build/release/Kido-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | awk '{print $1}')
echo "SHA256: $sha"
if [[ -z $local_tag ]]; then action git tag "$tag"; fi
action git push origin "refs/tags/$tag"
action gh release create "$tag" "$zip" --repo andreypopp/kido --title "Kido.app $version" \
  --notes "Native macOS client for kido. Apple Silicon and macOS 26 or later required. Ad-hoc signed; not notarized. Install with brew install --cask andreypopp/tap/kido-app." --prerelease
action git -C "$tap" pull --ff-only origin main
cask="$tap/Casks/kido-app.rb"
echo "+ write $cask"
if $dry; then cask=build/release/kido-app.rb; else mkdir -p "$tap/Casks"; fi
cat > "$cask" <<EOF
cask "kido-app" do
  version "$version"
  sha256 "$sha"
  url "https://github.com/andreypopp/kido/releases/download/kido-app%2F#{version}/Kido-#{version}.zip"
  name "Kido"
  desc "Native macOS client for the kido tmux agent multiplexer"
  homepage "https://github.com/andreypopp/kido"
  depends_on arch: :arm64
  depends_on macos: :tahoe
  app "Kido.app"
  caveats <<~EOS
    Kido.app is ad-hoc signed, not notarized. Upgrades require relaunching the app
    and confirming a restart of its separate app server. If macOS refuses to open it, run:
      xattr -dr com.apple.quarantine "#{appdir}/Kido.app"
  EOS
end
EOF
action git -C "$tap" add Casks/kido-app.rb
action git -C "$tap" commit -m "kido-app $version"
action git -C "$tap" push origin main
[[ -z $(git -C "$brew_tap" status --porcelain) ]] || { echo 'Homebrew tap checkout is dirty; refusing to update it' >&2; exit 1; }
action git -C "$brew_tap" pull --ff-only origin main
