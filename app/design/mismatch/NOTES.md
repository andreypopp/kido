# Incompatible-server dialog mockup

Open `mockup.html` in a browser, or serve this directory with `python3 -m http.server 8766 --bind 127.0.0.1` and open http://127.0.0.1:8766/mockup.html. Self-contained: system fonts, inline CSS/JS, no network assets.

## Native behavior

The user requested a standard macOS modal dialog rather than a custom mismatch surface. Default is a window-modal `NSAlert` sheet. AppKit owns the actual layout/material/icon/buttons; HTML only approximates it. Existing sidebar window chrome is reused: 44pt title-bar strip, 85–220pt tabs with 28pt/7pt-radius surfaces, remote host identifier at the start, dimmed while disconnected. No Connect Anyway path.

Headlines use plain language (update/restart), not protocol jargon. A secondary paragraph provides the exact compatibility data (server stamp and expected stamp, or required and spoken RPC versions), explicitly distinguished from app release numbers. Every local mismatch has one dialog: destructive red Restart and Close, with Close the default and Escape action. Its informative text warns that all sessions/panes end, commands and agents stop, and other attached clients disconnect. Restart acts immediately, with no separate confirmation or Cancel-back flow. Each Local window has its own mismatch sheet; a successful restart notifies other owners on the same socket, closes their mismatch sheets and repeats discovery so all connect to the new server. A restart failure remains a banner. A local RPC mismatch keeps its update title and guidance, with the same destructive Restart/Close controls. Remote Reconnect/Close presentation remains unchanged. Closing a dialog never attaches. The HTML mockup's two-step restart simulation is not the native behavior.

The previous banner can still be selected for comparison. Its optional version/fix disclosures and simulated Open SSH Terminal action are exploratory only, not part of the default standard-dialog proposal. No SSH process, update, restart or clipboard action is performed. Fix text is selectable; the Homebrew upgrade example is installation-dependent. There is deliberately no invented runnable restart command: kido has no CLI restart command.

## Compatibility model

Two independent checks, one sheet.

- **Server stamp.** A kido server records `KIDO_SERVER`, a 12-hex stamp derived from the tmux fork revision and the generated server config, so it changes only when the server itself would differ. `kido server` reports `server` (the running server's stamp, or null for an older or unstamped server) and `expected` (what this kido would create). Compatible means server == expected. A stamp says only *different*, never older or newer, so this cause never uses upgrade wording: the server must be restarted (locally by the destructive Restart, remotely by the user on the host, then Reconnect).
- **RPC protocol.** Separate from the stamp, currently 6.0. The app requires exactly 6.0 from the kido it talks to: the bundled kido locally, the installed kido over SSH. A remote kido speaking an older version means upgrade kido on the host; a newer one means update Kido.app on this Mac. Locally the bundled kido should always match, so a mismatch means reinstall or update Kido.app.

## Cases

1. Local server stamp mismatch (stamped differently or unstamped): "Restart the local kido server", restart using this bundle. Destructive Restart and Close.
2. Local bundled kido speaks an older RPC: "Update Kido.app", reinstall or update; same controls.
3. Local bundled kido speaks a newer RPC: "This server needs a newer Kido.app", update, then reconnect; same controls.
4. Remote server stamp mismatch, including an unstamped server with a compatible binary: "Restart kido on user@host". The host's kido already matches; restart its server, then Reconnect. No upgrade wording.
5. Remote older kido RPC: "Update kido on user@host". Upgrade kido there, then reconnect.
6. Remote newer kido RPC: "Update Kido.app to connect". Update Kido.app on this Mac, not the host.
7. Local restart confirmation: the preview's two-step simulation only; natively Restart acts immediately.

Dark/light and unstamped/different-stamp fixtures are switchable. The fixtures use the stamps `a1b2c3d4e5f6` (server) and `f0e1d2c3b4a5` (expected), and RPC 5.0 for an older kido and 7.0 for a newer one; the app's copy in `App/WindowOwner.swift` (`mismatchAlert`) is the source of the wording.

## Behavior and native implementation

Use NSAlert.beginSheetModal(for:). Sheet blocks the affected window, not all other host windows. Existing snapshots, if available, remain read-only behind it; the mocked snapshot is a previous-connection fixture, not a claim that first attachment can produce one. Tab labels are stale/unavailable, not navigable. No server attach is attempted until compatibility succeeds. Reconnect re-checks; this mockup stays incompatible and reports that no real check was made.

HTML approximation: 440pt sheet, 24pt padding, 64pt placeholder app icon with warning badge, 13pt semibold headline, 12pt body, 11pt technical secondary text. These are NOT custom-rendering requirements: native NSAlert geometry takes precedence. Escape dismisses/cancels; Tab cycles sheet buttons. Preview controls outside the simulated window remain available to compare cases.

## Open questions for iteration

- Is a sheet preferable to a persistent banner after the user closes it? Closing currently leaves the disconnected snapshot; reopening UX is not yet specified.
- Keep the stamp and RPC details in a secondary paragraph, omit them, or use a standard accessory-view disclosure? The native sheet currently omits the stamps and names only the RPC versions.
- Should remote mismatch offer an actual Open SSH Terminal action? It is only shown in the previous-banner comparison, not in the default dialog.
- Agree a safe remote restart workflow before presenting commands. Never imply upgrade/restart is nondestructive.
- Initial-attach/no-snapshot appearance is not separately mocked yet.

Native implementation: `App/WindowOwner.swift`. Hosted off-screen VisualTests drive the actual NSAlert buttons for single-window Restart, Close and two-window restart/reconnect. Snapshot references do not change.
