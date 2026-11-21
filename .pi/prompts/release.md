---
description: Release Kido.app, ko, koa and kow, Kido.app first
---
Release ko, and Kido.app, koa and kow with it when they changed. $ARGUMENTS can name the commit to
release. If it does not, release origin/main. The user approved the release
when they typed this command. Each step needs the result of the step before
it.

1. Check the commit:
   - `git fetch origin`. main must equal origin/main at the commit. The tree
     must be clean, except for files that other agents own.
   - CI must be green on Ubuntu and macOS for that commit
     (`gh run list --branch main`). If CI is red or still runs, stop and tell
     the user.
2. Find what changed since the last release. The tap formula
   `homebrew-tap/Formula/ko.rb` records its `revision:` and
   `version`. From `git log <revision>..<commit>`, decide:
   - The version: a patch, unless a tool or a subcommand is removed or
     renamed. Then it is a minor bump. `scripts/release.sh --dry-run` makes
     the final decision.
   - The protocol: compare `share/ko/openapi.json` and
     `share/ko/client-model.json` between the two revisions, and the
     `third_party/ghostty` pin. Kido.app releases first only when one
     of them changed: a schema change needs a Kido.app change, and a
     pin change moves `Ko-Vt`, which the app's bundled ko must match.
   - koa: the tap formula `homebrew-tap/Formula/koa.rb` records its
     `version`, and the tag `koa/<version>` marks it. koa releases when
     `git log koa/<version>..<commit> -- koa webview` is not empty, or
     when there is no koa formula yet. koa also releases when
     `webview/ko-api.d.ts` differs between that tag and the commit, and
     the notes say to upgrade ko and koa together. Its version: a patch,
     unless a tool is removed or renamed; then a minor bump.
   - kow: the tap formula `homebrew-tap/Formula/kow.rb` and the tag
     `kow/<version>` mark it. kow releases when `git log
     kow/<version>..<commit> -- kow` is not empty, when there is no
     kow formula yet, or when ko or koa releases now: kow pins the ko
     and koa releases that it installs. Its version: a patch, unless a
     subcommand is removed or renamed; then a minor bump.
3. When Kido.app must release first, send @kido-app (message_agent) the commit, the
   changes since the last release, and whether the schemas or the pin
   changed. Ask it to run its checks on that commit of main (make test, the
   whole make visual and make stress, in app/; each whole target runs once:
   after a fix, only the failing tests and the tests that the fix touches
   run again, by name), release Kido.app with
   app/scripts/release.sh, and tell you the tag and tap commit. Then end the
   turn. Its reply wakes you. Otherwise go to step 4 at once.
4. When kido-app reports the release, or no app release is needed,
   release ko. The only git writes are the tap pull and what
   scripts/release.sh does itself:
   - `git -C homebrew-tap pull --ff-only`. The tap head must be
     kido-app's tap commit, else origin/main.
   - `scripts/release.sh --dry-run ko VERSION`. If it reports a removed
     command that the version does not allow, or CI is not green, stop
     and report.
   - `scripts/release.sh ko VERSION`. It needs an arm64 Mac: it tags
     `ko/VERSION`, uploads the three `ko-bin` tarballs and updates
     `Formula/ko.rb` and `Formula/ko-bin.rb`.
   - When koa releases: `scripts/release.sh --dry-run koa VERSION`, with
     the same stop rule for a removed tool, then `scripts/release.sh
     koa VERSION`. It tags `koa/VERSION`, uploads the tarball and
     writes `Formula/koa.rb`. A koa release needs no ko or Kido.app
     release.
   - When kow releases, after the ko and koa releases: run `kow/kow
     --pin`, commit the changed pins ("kow pins ko X and koa Y"), push
     to main and wait for green CI. Then `scripts/release.sh --dry-run
     kow VERSION` and `scripts/release.sh kow VERSION` at that commit.
     It tags `kow/VERSION`, uploads the tarball and writes
     `Formula/kow.rb`.
   - Do not run `brew upgrade`.
5. Tell @kido-app the ko version and tap commit when it released.
   Tell the user:
   - the versions and the tap commits
   - to run `brew upgrade ko` and update Kido.app
   - after a koa release, to run `brew upgrade koa` (`brew install
     andreypopp/tap/koa` the first time) and `/reload` in a koa pane
   - after a kow release, to run `brew upgrade kow` (`brew install
     andreypopp/tap/kow` the first time) and `kow NAME install` for
     each remote server
   - to restart the koa agents after a koa release that removes tools
     (/reload is not sufficient then)
   - to restart the ko server (`ko kill-server`, then `ko`) when the
     server changed: until upgrade in place (plans/ko-upgrade.md), a
     restart ends its panes
