# Incompatible-server dialog mockup

Open `mockup.html` in a browser, or serve this directory with `python3 -m http.server 8766 --bind 127.0.0.1` and open http://127.0.0.1:8766/mockup.html. Self-contained: system fonts, inline CSS/JS, no network assets.

## Current proposal

The user requested a standard macOS modal dialog rather than a custom mismatch surface. Default is a window-modal `NSAlert` sheet. AppKit owns the actual layout/material/icon/buttons; HTML only approximates it. Existing sidebar window chrome is reused: 44pt title-bar strip, 85–220pt tabs with 28pt/7pt-radius surfaces, remote host identifier at the start, dimmed while disconnected. No Connect Anyway path.

Headlines use plain language (update/restart), not protocol jargon. A secondary paragraph provides the exact required and server protocol versions, explicitly distinguished from app release numbers. Local offers Restart… and Close; remote offers Reconnect and Close. The local restart action leads to a separate warning confirmation, with Cancel focused initially and Restart explicit. Confirmation warns that all sessions/panes end, commands and agents stop, and other attached clients disconnect. Cancel returns to the mismatch dialog. Closing a dialog never attaches.

The previous banner can still be selected for comparison. Its optional version/fix disclosures and simulated Open SSH Terminal action are exploratory only, not part of the default standard-dialog proposal. No SSH process, update, restart or clipboard action is performed. Fix text is selectable; the Homebrew upgrade example is installation-dependent. There is deliberately no invented runnable restart command: kido has no CLI restart command.

## Cases

1. Local unstamped/older server: restart using this bundle.
2. Local newer major: update Kido.app, or restart with this bundle after the destructive warning (e.g. after downgrading the app).
3. Remote unstamped/older server: upgrade host kido and restart its server, then reconnect.
4. Remote newer major: update Kido.app on this Mac, not the host.
5. Remote binary upgraded, running server still old: show both versions and advise restarting the server, not upgrading again.
6. Local restart confirmation shown directly.

Dark/light and unstamped/0.9 fixtures are switchable. The current requirement is major 1, minor 0+, so there is no representable lower minor within major 1. The stamped older fixture therefore uses major 0, not an impossible 1.-1. Version stamps are protocol compatibility data, not application release versions.

## Behavior and native implementation

Use NSAlert.beginSheetModal(for:). Sheet blocks the affected window, not all other host windows. Existing snapshots, if available, remain read-only behind it; the mocked snapshot is a previous-connection fixture, not a claim that first attachment can produce one. Tab labels are stale/unavailable, not navigable. No server attach is attempted until compatibility succeeds. Reconnect re-checks; this mockup stays incompatible and reports that no real check was made.

HTML approximation: 440pt sheet, 24pt padding, 64pt placeholder app icon with warning badge, 13pt semibold headline, 12pt body, 11pt technical secondary text. These are NOT custom-rendering requirements: native NSAlert geometry takes precedence. Escape dismisses/cancels; Tab cycles sheet buttons. Preview controls outside the simulated window remain available to compare cases.

## Open questions for iteration

- Is a sheet preferable to a persistent banner after the user closes it? Closing currently leaves the disconnected snapshot; reopening UX is not yet specified.
- Keep exact version numbers in a secondary paragraph, omit them, or use a standard accessory-view disclosure?
- Should remote mismatch offer an actual Open SSH Terminal action? It is only shown in the previous-banner comparison, not in the default dialog.
- Agree a safe remote restart workflow before presenting commands. Never imply upgrade/restart is nondestructive.
- Initial-attach/no-snapshot appearance is not separately mocked yet.

Source reference: shipped `App/WindowOwner.swift` mismatch/restart behavior at 573034b. Proposed wording and presentation differ from the shipped banner. No approval or implementation claim yet.
