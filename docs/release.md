# Releasing Kido

This file describes the mechanics of a release. AGENTS.md,
"Releasing", holds the rules; `.pi/prompts/release.md` (`/release`)
is the whole sequence for an agent: Kido.app first when the schemas
or the Ghostty pin changed, then ko, and koa on its own cadence.

## ko

ko and Kido.app ship from `main`. ko has two formulas in
`andreypopp/homebrew-tap`: `ko` builds from source, at a git
`revision:` with a manually increased `version`, with the pinned
toolchains (the rustup toolchain of `rust-toolchain.toml` and the zig
of `scripts/install-zig.sh`), through `make install`; `ko-bin`
installs prebuilt tarballs, the assets of the GitHub release of the
tag `ko/<version>`. Neither ships koa ("koa").

After the change is on `main`, `scripts/release.sh ko VERSION` (or
`make release PRODUCT=ko VERSION=x.y.z`) releases ko, and
`scripts/release.sh koa VERSION` releases koa ("koa") and
`scripts/release.sh kow VERSION` releases kow ("kow"). The script
requires HEAD equal to origin/main, a tree without changes in what it
packs, and green CI for the commit; `--no-ci` skips the CI check,
only when the user asks for it. `--dry-run` prints the tag, the
upload and every git command of the taps instead of running them,
and only warns about a HEAD that is not origin/main or a changed
tree. It still builds and packs the tarballs into a temporary
directory, which it keeps and prints. The version must increase over
the tap formulas'. The variables `KO_RELEASE_TAP`,
`KO_RELEASE_SSH_TAP` and `KO_RELEASE_OLD_KO` override its inputs for
a dry run.

For ko, the script compares the command list with the tap's current
revision: the old names come from `$(brew --prefix ko)/bin/ko --help`,
the new from the checkout's build, with no worktrees; it checks that
the installed `ko version` build is a prefix of the formula's
revision. A removed or renamed command requires a minor bump. Panes
must restart, not /reload. It runs only on an arm64 Mac, because the
`ko-bin` tarballs are the Mac's `make install` with the static Linux
ko of aarch64 (the one that a container runtime mounts) and the two
static Linux layouts (`make build-linux`), each with top-level `bin/`
and `share/`. It tags the commit `ko/<version>`, pushes the tag, creates
the GitHub release with the three tarballs, and updates `ko.rb`
(revision, version) and `ko-bin.rb` (version, URLs, sha256) in one
tap commit.

The script commits to the brew tap. It fast-forwards
`~/Workspace/homebrew-tap`. It pushes from that SSH checkout. It
never runs `brew upgrade`.

## koa

See [design-koa.md](design-koa.md#release) for koa's packaging, version rules and coordinated releases.

## kow

kow (docs/kow.md) has its own formula, `Formula/kow.rb` in the same
tap, and its own versions, tagged `kow/X.Y.Z`. The formula installs
the one script `kow/kow` from the tarball `kow-X.Y.Z.tar.gz` of the
GitHub release, depends on Homebrew's Python and OpenTofu, and takes
rsync and OpenSSH from the system. kow pins the ko and koa releases
that `install` downloads, each with its SHA-256. `scripts/release.sh
kow VERSION` first runs `kow/kow --check-pins` with Homebrew's
`python`, the formula's interpreter, which refuses when a
newer ko or koa release exists: run `kow/kow --pin`, commit the
change through the usual path, then release. So a kow release
follows the ko and koa releases that it must install, and a Kido.app
release that needs a new ko on the server is followed by a kow
release. The script then packs the tarball, tags the commit, creates
the GitHub release and commits the formula to the tap, as for koa.

## Kido.app

Only `kido-app/N.N.N` tags mark Kido.app releases.
`app/scripts/release.sh` builds them from `main`. They are published
as `Casks/kido-app.rb` in `andreypopp/homebrew-tap`. The app bundles
its own `ko` (`app/scripts/bundle-ko.py`), without koa: the user
installs koa with Homebrew. A Ghostty pin bump changes `Ko-Vt`, so it is a coordinated release of
ko and Kido.app. design-app.md, "Release signing", describes the
app's signing.

## Previewing koa

See [design-koa.md](design-koa.md#build-install-and-run) for an installed preview and login PATH selection.
