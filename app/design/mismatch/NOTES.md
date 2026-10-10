# Incompatible-server dialog mockup

Open `mockup.html` in a browser, or serve this directory with `python3 -m http.server 8766 --bind 127.0.0.1` and open http://127.0.0.1:8766/mockup.html. Self-contained: system fonts, inline CSS/JS, no network assets.

## Native behavior

The user requested a standard macOS modal dialog rather than a custom mismatch surface. Default is a window-modal `NSAlert` sheet. AppKit owns the actual layout/material/icon/buttons; HTML only approximates it. Existing sidebar window chrome is reused: 44pt title-bar strip, 85–220pt tabs with 28pt/7pt-radius surfaces, remote host identifier at the start, dimmed while disconnected. No Connect Anyway path.

Headlines use plain language (update/restart), not protocol jargon. A secondary paragraph provides the exact required and server protocol versions, explicitly distinguished from app release numbers. Every local mismatch has one dialog: destructive red Restart and Close, with Close the default and Escape action. Its informative text warns that all sessions/panes end, commands and agents stop, and other attached clients disconnect. Restart acts immediately, with no separate confirmation or Cancel-back flow. Each Local window has its own mismatch sheet; a successful restart notifies other owners on the same socket, closes their mismatch sheets and repeats discovery so all connect to the new server. A restart failure remains a banner. Newer-local keeps its title and update guidance, with the same destructive Restart/Close controls. Remote Reconnect/Close presentation remains unchanged. Closing a dialog never attaches. The HTML mockup's two-step restart simulation is not the native behavior.

The previous banner can still be selected for comparison. Its optional version/fix disclosures and simulated Open SSH Terminal action are exploratory only, not part of the default standard-dialog proposal. No SSH process, update, restart or clipboard action is performed. Fix text is selectable; the Homebrew upgrade example is installation-dependent. There is deliberately no invented runnable restart command: kido has no CLI restart command.

## Cases

1. Local unstamped/older server: restart using this bundle.
2. Local newer protocol: existing newer-Kido.app title and update guidance, with the same warning and destructive Restart/Close controls.
3. Remote unstamped/older server: upgrade host kido and restart its server, then reconnect.
4. Remote newer major: update Kido.app on this Mac, not the host.
5. Remote binary upgraded, running server still old: show both versions and advise restarting the server, not upgrading again.
6. Several Local windows: Restart in one dismisses the other mismatch sheets and reconnects all to the same new server.

Dark/light and unstamped/0.9 fixtures are switchable. The current requirement is exactly protocol 2.1. Protocol 2.0 is an older minor; 2.2 is newer. Version stamps are protocol compatibility data, not application release versions.

## Behavior and native implementation

Use NSAlert.beginSheetModal(for:). Sheet blocks the affected window, not all other host windows. Existing snapshots, if available, remain read-only behind it; the mocked snapshot is a previous-connection fixture, not a claim that first attachment can produce one. Tab labels are stale/unavailable, not navigable. No server attach is attempted until compatibility succeeds. Reconnect re-checks; this mockup stays incompatible and reports that no real check was made.

HTML approximation: 440pt sheet, 24pt padding, 64pt placeholder app icon with warning badge, 13pt semibold headline, 12pt body, 11pt technical secondary text. These are NOT custom-rendering requirements: native NSAlert geometry takes precedence. Escape dismisses/cancels; Tab cycles sheet buttons. Preview controls outside the simulated window remain available to compare cases.

## Open questions for iteration

- Is a sheet preferable to a persistent banner after the user closes it? Closing currently leaves the disconnected snapshot; reopening UX is not yet specified.
- Keep exact version numbers in a secondary paragraph, omit them, or use a standard accessory-view disclosure?
- Should remote mismatch offer an actual Open SSH Terminal action? It is only shown in the previous-banner comparison, not in the default dialog.
- Agree a safe remote restart workflow before presenting commands. Never imply upgrade/restart is nondestructive.
- Initial-attach/no-snapshot appearance is not separately mocked yet.

Native implementation: `App/WindowOwner.swift`. Hosted off-screen VisualTests drive the actual NSAlert buttons for single-window Restart, Close and two-window restart/reconnect. Snapshot references do not change.
