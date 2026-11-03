---
description: Release Kido.app and ko together, Kido.app first
---
Release ko, and Kido.app with it. $ARGUMENTS can name the commit to
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
   - ko-pi.ts: the user's agents run the ko-pi that Kido.app bundles,
     because the Kido.app shim is first on PATH. Thus, a harness change
     reaches them only through a Kido.app release.
3. When Kido.app must release first, send @kido-app (message_agent) the commit, the
   changes since the last release, and whether the schemas or the pin
   changed. Ask it to run its checks on that commit of main (make test, the
   whole make visual, make stress), release Kido.app with
   app/scripts/release.sh, and tell you the tag and tap commit. Then end the
   turn. Its reply wakes you. Otherwise go to step 4 at once.
4. When kido-app reports the release, or no app release is needed,
   release ko. The only git writes are the tap pull and what
   scripts/release.sh does itself:
   - `git -C homebrew-tap pull --ff-only`. The tap head must be
     kido-app's tap commit, else origin/main.
   - `scripts/release.sh --dry-run VERSION`. If it reports a removed
     command or tool that the version does not allow, or CI is not
     green, stop and report.
   - `scripts/release.sh VERSION`.
   - Do not run `brew upgrade`.
5. Tell @kido-app the ko version and tap commit when it released.
   Tell the user:
   - the two versions and the tap commits
   - to run `brew upgrade ko` and update Kido.app
   - to restart the pi agents when ko-pi.ts changed (/reload is not
     sufficient after a release that removes tools)
   - to restart the ko server (`ko kill-server`, then `ko`) when the
     server changed: until upgrade in place (plans/ko-upgrade.md), a
     restart ends its panes
