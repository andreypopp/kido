# Pair a TLS server (proposal, unit 6 of plans/remote-mtls.md)

`mockup.html` shows every state of 4.9 of the plan, light and dark;
`?state=<id>&theme=Light|Dark` selects one. The rules are in the
plan's section 4.9. This file holds only what the mockup decided
beyond them. Nothing is approved by the user yet beyond 4.9.

## Components reused

- The palette card, its modes, error line, status line and foot
  (`palette/NOTES.md`). The Pair mode is a mode like Connect.
- The mismatch sheet (`mismatch/NOTES.md`) for the two certificate
  failures, with the app icon and the warning badge.
- The stock `NSAlert` for Forget, the same look as the restart
  confirmation of the mismatch mockup.
- The connection banner (`RemoteFailure.banner`) for not reachable.
- The tab strip's host label at the start, as for an SSH window.

## Decisions beyond 4.9

- **The Pair mode's chip** is `key` "Pair" (SF Symbol `key`, 12pt),
  not "Pair Server": the chip names the mode in one word like
  "Connect".
- **The code field** is the palette field with the placeholder
  "Paste the pairing code". A pasted code shows in SF Mono 14pt on
  the 22pt line (the code is an opaque string, not prose), aligned
  to its end as a text field does with the caret at the end, so the
  token is what the user sees. The field accepts the code with or
  without the `kido-pair:` prefix and with whitespace around it.
- **The device name** is a second row under the head, 36pt: the
  label "Device name" in `secondaryLabelColor`, then the editable
  value, filled with the Mac's name. Tab moves the focus from the
  code to the name (2pt accent-55% focus ring, the picker's ring of
  Prompt mode) and back; Return pairs from either. The name is sent
  as typed; an empty name is the Mac's name.
- **The parsed line.** When the code parses, the status line (the
  secondary line above the foot) says "Pairs this Mac with HOST",
  HOST in `labelColor` medium. It is the one check the user has
  before Return that the code is the server they expect. In Pair
  Again it says "Pairs this Mac with HOST again; the old key stays
  until this pairing succeeds" and the field holds HOST, read-only,
  with the placeholder of the code field gone: the user pastes a
  new code over it.
- **The foot** reads `↩ pair · ⇥ device name · esc back`, with the
  reminder at the right "the code the server's CLI printed, valid
  about 2 minutes" while the code is empty or parses.
- **Inert states** (in progress, waiting, uncertain send) dim the
  head, the name row and the list to 45%, the `inert` treatment of
  the koa composer; the status line stays at full opacity. Escape
  still leaves the mode; the request is not cancelled.
- **The network failure line** gives the OS message after the colon
  ("The network connection was lost."); Retry at the right in the
  accent, as the Retry of Prompt mode.
- **The uncertain send** has no Retry and no spinner: the line
  "HOST may have paired this Mac; try Connect." The user leaves with
  Escape and connects from the recent list, where HOST is now
  listed, because the pairing stored the identity before the POST.
- **The recent list's kind word** sits after the name, 11pt
  `secondaryLabelColor`, 8pt gap: "ko.example.com https",
  "devbox ssh". Both kinds keep the `globe` icon in the slot. The
  root list's "Connect › host" rows carry the same word.
- **The hint line** of Connect is the last-but-one row, the hint
  style (28pt, 12pt secondary): "Paste a pairing code: Pair
  Server…", where "Pair Server…" is in the accent and a click or
  Return on the row switches the mode. "Clear Recent Hosts" stays
  last.
- **The context menu** of a recent row (right-click or Control-
  click) is a stock `NSMenu` with one item: "Forget HOST…" for an
  https row, "Remove from Recents" for an ssh row. The row under the
  menu gets a 1.5pt inset ring in `labelColor` 35%, the menu's
  anchor, while the menu is open.
- **The refused sheet** has a second line under the title: "The
  server has revoked this Mac, or has not activated it yet. Pair
  again with a new code from the server, or close this window."
  "Pair Again" is the default button; it closes the window's sheet
  and opens the palette in Pair mode with HOST filled in. **The TLS
  sheet's** second line: "The server presented a certificate that
  this Mac cannot verify. Fix the certificate on the server, then
  connect again." The reason after the colon is the OS text of the
  TLS error, as `ko_client` reports it.
- **The Forget alert** is window-modal on the key window (the
  palette closes first), "Forget" the default button at the right,
  "Cancel" beside it; Escape cancels.
- **The window title** is "HOST / Session" ("ko.example.com /
  main"); the tab strip shows HOST at its start, in the host label
  of an SSH window. There is no user part, so nothing is cut.
- **The File menu** gets "Pair Server…" directly under "Connect to
  Remote Host…", with no shortcut.

## Open for the user

- Paste only on macOS, no QR scan and no `kido-app://enroll` link
  (4.9, point 2): the recommendation stands until the user says
  otherwise.
- The device name is sent and the server shows it to the operator;
  the mockup assumes the Mac's name is a good default and that the
  user rarely edits it.

## A file drop on a window of an https server (phase 1)

No upload route exists yet, so the drop does not upload. The existing
notice (`WindowOwner.notice`, the title "Kido did not upload") shows
the body:

    Files cannot be uploaded to HOST yet. Copy the file to the server
    with another tool.

HOST is the host's label as in the other upload notices. One sentence
of fact and one of what to do; no "phase", no "not supported", no
promise of a date. The notice component is unchanged.

## The version-mismatch sheet for an https host

The same `mismatchAlert` as for SSH (`mismatch/NOTES.md`), with the
host step changed: there is no SSH, systemd owns ko on the host
(`ko.service`, binaries in /opt/ko), and `deploy/install.sh`, run in
the Kido checkout that deployed the host, builds ko from that
checkout, reads the host from the checkout's Terraform state,
installs ko there and restarts the service. It takes no argument and
does not use the app's bundled ko. HOST is the host's label.

- The server speaks a newer protocol: title "Update Kido.app to
  connect to HOST"; body "The server speaks ko protocol X; this app
  speaks Y. Update Kido.app on this Mac. The server is build A; this
  app is build B." No host step, no command field.
- The server speaks an older protocol: title "Update ko on HOST";
  body "This app speaks ko protocol Y. The server speaks X. Update ko
  on the host, then reconnect. The server is build A; this app is
  build B." then, after a blank line, the host step below.
- Different releases (the terminal revision differs): title
  "Kido.app and ko on HOST are from different releases"; body "This
  app runs terminal revision R1; the server runs R2. Install the ko
  release of this Kido.app on the host, or update Kido.app. The
  server is build A; this app is build B." then the host step.
- The host step, for the two cases that change the host: "In the
  Kido checkout that deployed HOST, checked out at the release of
  this Kido.app, run the command below. It builds ko there, installs
  it on HOST and restarts its service. All sessions and panes on
  that server will end." The selectable monospace field under it
  holds `deploy/install.sh`, with no argument. The release clause is
  there because the script builds whatever is checked out; a
  checkout at another release installs another mismatch.
- Buttons as for SSH: "Reconnect" (not destructive) and "Close"
  (default, Escape). Reconnect checks the versions again.

## The server's friendly name (unit 6b, 2026-11-17)

The code carries a required `name` (`ko-pair --name`, default the
machine's hostname). The name is the TLS host's title everywhere;
the DNS host is its second value, shown where the row has room and
as the tooltip where it has none.

- Connect recent rows and the root's "Connect › …" rows stay one
  line, 34pt: the title is the name; the trailing muted 11pt word
  becomes "https · ko.example.com" (the kind, a middle dot, the DNS
  host), truncated from its right when the row is narrow; the time
  keeps its place. Fuzzy match on the name and on the DNS host: a
  query that matches either lists the row, and the highlight is in
  whichever matched.
- The host chip of the tab strip: the name, with the DNS host as its
  tooltip, exactly as an SSH chip shows the identity with the
  destination as tooltip (`hostLabel`: text = name, alias = DNS).
- The window title: "Home VM / Session".
- The name where HOST stood in text: "Forget Home VM…", the alert
  "Forget Home VM?" with "This Mac's key and certificate for Home VM
  (ko.example.com) are deleted. Pair again to connect."; the refused
  sheet "Home VM does not accept this Mac's certificate"; the
  banners "Disconnected from Home VM", "Home VM is not reachable";
  the pairing lines "Pairing with Home VM…", "Waiting for Home VM to
  activate…", "Could not reach Home VM: …", "Home VM may have paired
  this Mac; try Connect." (the payload has the name before the store
  does). The parsed line: "Pairs this Mac with Home VM
  (ko.example.com)", the DNS host muted, so the user checks both
  before Return. Pair Again: the field holds "Home VM", selected, as
  plain text (a field editor shows no attributes); the parsed line
  below it carries the DNS host.
- The DNS host stays alone in the TLS sheet ("ko.example.com's
  certificate is not valid: …"): the certificate is the DNS name's.
