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

koa has its own formula, `Formula/koa.rb` in the same tap, and its own
versions, tagged `koa/X.Y.Z` in this repository. The formula installs
a prebuilt tarball: koa is TypeScript and one bundled page, with no
architecture. `scripts/release.sh koa VERSION`:

- compares the tool list of `koa/testdata/ko-prompts.txt` with the
  same file at the tag of the formula's version; a removed or renamed
  tool requires a minor bump. A tap without `Formula/koa.rb` is the
  first release, with no comparison.
- builds `build/koa` again from nothing (`make -C koa`) and packs its
  `bin/` and `share/` into `koa-X.Y.Z.tar.gz`.
- tags the commit `koa/X.Y.Z`, pushes the tag, creates the GitHub
  release of that tag with the tarball as its asset, and writes the
  formula: the asset's URL and sha256, `depends_on "node"` and
  `depends_on "andreypopp/tap/pi-coding-agent"` (koa loads pi's SDK
  from the installed pi), `prefix.install "bin", "share"`, and a test
  that runs `koa --help`. The formula does not depend on ko: Kido.app,
  `ko` and `ko-bin` all supply it.

A koa release needs no ko or Kido.app release: a pane runs the `koa`
of the server's PATH, and `/reload` in a koa pane takes the new
version. When `webview/ko-api.d.ts` changed between koa's last tag
and the commit of a ko or Kido.app release, koa releases in the same
run, and the notes say to upgrade both.

koa has no compatibility check against ko. The surface between them is
the `ko` command line (`ko api`, `ko webview serve`, `ko shell`), the
route shapes, OSC 7501 and the `koa.*` variables, and a mismatch is
already loud: `ko api` exits non-zero with the server's message. The
protocol major of `ko version` is no usable signal, because it changes
only by a manual rule at a release, not with each shape change. So the
one rule is the coordinated release above.

The first ko and Kido.app releases without koa run after `rm -rf
build/ko`, because a checkout that built before keeps a stale
`build/ko/share/ko/koa` that the app's bundle would copy. Their notes
say: "koa is now a separate package. Run `brew install
andreypopp/tap/koa` before you update, or New Agent and `koa` fail.
Update koa with `brew upgrade koa`; `/reload` in a koa pane takes the
new version."

`brew audit`/`brew style` vendor gems into the Homebrew checkout
itself. This can leave the checkout dirty.

## kow

kow (docs/kow.md) has its own formula, `Formula/kow.rb` in the same
tap, and its own versions, tagged `kow/X.Y.Z`. The formula installs
the one script `kow/kow` from the tarball `kow-X.Y.Z.tar.gz` of the
GitHub release, depends on Homebrew's Python and OpenTofu, and takes
rsync and OpenSSH from the system. kow pins the ko and koa releases
that `install` downloads, each with its SHA-256. `scripts/release.sh
kow VERSION` first runs `kow/kow --check-pins` with Homebrew's
`python@3.14`, the formula's interpreter, which refuses when a
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

`make -C koa install PREFIX=DIR` installs the checkout's koa; with
`DIR/bin` before Homebrew's on the server's PATH, new koa panes run
it.
