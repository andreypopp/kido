---
description: Release Kido.app and kido together, Kido.app first
---
Release kido, and Kido.app with it. $ARGUMENTS can name the kido commit to
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
   `homebrew-tap/Formula/kido.rb` records its `revision:` and
   `version`. From `git log <revision>..<commit>`, decide:
   - The version: a patch, unless a tool or a subcommand is removed or
     renamed. Then it is a minor bump. `scripts/release.sh --dry-run` makes
     the final decision.
   - Protocol: compare `Protocol.value` in `lib/protocol.ml`. A protocol
     change needs a Kido.app change, so Kido.app must release first
     (docs/design-rpc.md).
   - Stamp: `kido server` prints `expected`. If the stamp changes, every user
     must restart the kido server. Tell the user before you release.
   - kido-pi.ts: the user's agents run the kido-pi that Kido.app bundles,
     because the Kido.app shim is first on PATH. Thus, a harness change
     reaches them only through a Kido.app release.
3. Kido.app releases first. Send @kido-app (message_agent) the commit, the
   changes since the last release, and whether the protocol or stamp changed.
   Ask it to rebase kido-app onto the commit, run its checks (make test, the
   whole make visual, make stress), release Kido.app with
   app/scripts/release.sh, and tell you the tag and tap commit. Then end the
   turn. Its reply wakes you.
4. When kido-app reports the release, run kido's release in a subagent,
   because scripts/release.sh builds two worktrees and takes minutes. Spawn
   one agent on deepseek/deepseek-flash:low. It does the work itself: no
   subagents, no ask_agent. It may make only these git writes: the tap pull
   and what scripts/release.sh does itself. Its steps:
   - `git -C homebrew-tap pull --ff-only`. The tap head must be
     kido-app's tap commit.
   - In kido: `scripts/release.sh --dry-run VERSION`. If it
     reports a removed command or tool that the version does not allow, or CI
     is not green, it stops and reports.
   - `scripts/release.sh VERSION`.
   - It reports the dry-run summary, the result and
     `git -C homebrew-tap log --oneline -2`.
   - It does not run `brew upgrade`.
5. Stop the release agent. Tell @kido-app the kido version and tap commit.
   Tell the user:
   - the two versions and the tap commits
   - to run `brew upgrade kido` and update Kido.app
   - to restart the pi agents when kido-pi.ts changed (/reload is not
     sufficient after a release that removes tools)
   - to restart the kido server when the stamp changed
