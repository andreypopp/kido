# Releasing Kido

This file describes the mechanics of a release. AGENTS.md,
"Releasing", holds the rules; `.pi/prompts/release.md` (`/release`)
is the whole sequence for an agent: Kido.app first when the schemas
or the Ghostty pin changed, then ko.

## ko

ko and Kido.app ship from `main`. Kido deliberately has **no release
version and no tags** for ko. Versioning uses the `ko` formula in
`andreypopp/homebrew-tap`: a git `revision:` with a manually
increased `version`. The formula builds ko from source with the
pinned toolchains (the rustup toolchain of `rust-toolchain.toml` and
the zig of `scripts/install-zig.sh`), through `make install`. `make
build` bundles koa's page with Node and npm, so the formula needs
`depends_on "node" => :build`; `scripts/release.sh` refuses to
release while the tap's formula lacks it, and does not add it.

After the change is on `main`, `scripts/release.sh VERSION` (or
`make release VERSION=x.y.z`) releases ko. `--dry-run` inspects its
actions. It requires HEAD equal to origin/main and green CI for it.
It compares the command and tool lists with the tap's current
revision: the old names come from `$(brew --prefix ko)/bin/ko --help`
and `share/pi/testdata/ko-prompts.txt` at the old revision, the new
from the checkout, with no worktrees; it checks that the installed
`ko version` build is a prefix of the formula's revision. Removals or
renames require a minor bump. Panes must restart, not /reload. The
variables `KO_RELEASE_TAP`, `KO_RELEASE_SSH_TAP` and
`KO_RELEASE_OLD_KO` override its inputs for a dry run.

The script edits and commits the brew tap formula. It fast-forwards
`~/Workspace/homebrew-tap`. It pushes from that SSH checkout. It
never runs `brew upgrade`.

`brew audit`/`brew style` vendor gems into the Homebrew checkout
itself. This can leave the checkout dirty.

## Kido.app

Only `kido-app/N.N.N` tags mark Kido.app releases.
`app/scripts/release.sh` builds them from `main`. They are published
as `Casks/kido-app.rb` in `andreypopp/homebrew-tap`. The app bundles
its own `ko` (`app/scripts/bundle-ko.py`), so the user's agents run
the `koa` that Kido.app bundles, because the app's shim is first on
PATH: a harness change reaches them only through a Kido.app release.
A Ghostty pin bump changes `Ko-Vt`, so it is a coordinated release of
ko and Kido.app. design-app.md, "Release signing", describes the
app's signing.

## Previewing the harness

`make preview-pi` atomically replaces the installed pi extension, its
page and the webview SDK and backs up the originals once; `make
unpreview-pi` restores them, and removes a file that the install did
not have. Afterward, run `/reload` in the panes. `KO_PREVIEW_PREFIX`
selects a prefix other than `brew --prefix ko`.
