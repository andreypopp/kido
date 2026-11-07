# Notices: errors over the pane area (design, mockups only)

`mockup.html` is a self-contained reference for the **notice card**: the
one place for a failure that has no UI of its own. The user's
direction: the sidebar never shows errors; a failure of an action with
its own UI shows there; every other failure is a transient card over
the bottom of the pane area that never takes the keyboard; the
connection state is the pane-area banner alone; the config error is
the same card, persistent, with "Open config". It is implemented
(docs/design-app.md, "Notices"); "What shows errors today" below
describes the state before it, and the states `center` and
`two-replace` stay only as the record of the rejected alternatives.
The user approved the design on 2026-11-07 ("Decisions" at the end).
Open it through a preview server from `app/design`
(`python3 -m http.server 8767 --bind 127.0.0.1`, then
http://127.0.0.1:8767/notices/mockup.html); `?state=<id>&theme=Light|Dark&presentation=windowed|fullscreen&sidebar=docked|floating|collapsed&position=right|center`
selects a view. The "Live" buttons run the real rules: the clock, the
hover pause, the click, the cap of three. `/tmp/kido-notices-shots/`
holds a render of each state in both themes with a README.

## What shows errors today

Four mechanisms, in `app/App/`:

- **The sidebar status line** (`SidebarView.swift:144`, `statusLine`;
  `failed(_:)` at 280, `offline(_:)` at 267, `noteChanged` at 285): a
  16pt one-line label at the top of the list, red for `failure`, grey
  for the `feedNote`, cut at its end, the full text as a tooltip.
- **The banner** (`Banner.swift`): the 85% veil of the whole pane area
  with a title, a detail and one button, for every connection state
  (`WindowOwner.down`, 380). It clears the first responder.
- **The config strip** (`ConfigBanner.swift`): a 62pt strip at the top
  of the pane area with the file's path, the `line:column: message`
  and "Reveal in Finder"; the panes reflow under it
  (`Sidebar.showConfigError`, 120; `WindowOwner.showConfigError`, 387).
- **The notice sheet** (`WindowOwner.notice`, 836): a window-modal
  `NSAlert` with a title and a detail, and one `note` line, for the
  upload path and `confirmCommand`'s failures.

Every `note` line goes to `~/Library/Logs/Kido/app.log` (docs/design-app.md,
"The log").

## The classification

Every caller of the status line, the strip and the sheet, with its
class: **inline** (the control that failed shows it), **card** (a
transient notice), **banner** (the connection state, unchanged),
**config** (the persistent notice), or **log** (a `note` line only).

| Caller (`WindowOwner.swift` unless named) | Today | Class | Shows |
| --- | --- | --- | --- |
| `down(...)`, 380: every connection state (`start`, `startServer`, `restartServer`, `refused`, the welcome timeout at 904, `failed` at 953, the `failed` event at 1004, the remote failures at 509–580, "Relaunch Kido.app" at 877) | banner + `list.offline(title)` | **banner** | The banner alone. The sidebar copy of the title goes. |
| `connecting()`, 1203 | banner "Connecting to HOST…" + `list.offline("Connecting…")` | **banner** | The banner alone. |
| `resetSession()`, 1037: a fresh welcome | `list.offline("Connecting…")` | **banner** | Nothing new: the banner that `down` showed stays until `ready()`. |
| `ensureSession()`, 1217: the `ensure_session` edit failed | banner "Could not create a session" with Retry | **banner** | Unchanged: the window has no session to show, and Retry sends the edit again. |
| `makeEditor`, 1024: `LayoutEditor.onFailure` for every refused edit without an owner: New Window (menu, ⌘T, the tab strip's plus, the session header's plus, the palette, File > Runtimes), Split Right/Down, Close Pane, Zoom, a pane resize or a float move from `SessionView.edit`, a window's `close: on_exit` edit | `list.failed(text)` | **card** | Title from the edit's case (table below), the server's text as the detail. |
| `makeEditor`, 1024: the same callback for an edit that has an owner: `create(..., done:)` for the palette's New Session and Rename Session (`main.swift:521`), the sidebar's rename (`SidebarView.swift:135`), a reorder (`submit(ReorderMove)`, 1476) | `list.failed(text)` **and** the owner's own report: the failure shows twice | **inline** | Only the owner shows it. `onFailure` fires only for an edit without a `then`. |
| `create(...)`, 1224: no editor, "HOST is not connected." | `list.failed` + `done?(text)` | **banner** | Nothing: with no editor the link is down and the banner already says so. An owner with a field (the palette, the rename) keeps its inline text. |
| `newSession()`, 1252: File > New Session, ⌘N | `list.failed(error)` | **card** | "Could not create a session" + the server's text. |
| `perform(_ navigation:)`, 1441–1474: a `select` or `switchOver` that throws (a transport failure) | `list.failed("\(error)")` | **card** | "Could not select the pane" (or window, session) + the error. |
| `perform`, 1443: not connected | `list.failed` | **banner** | Nothing: the banner shows. |
| `settleOrder`, 1493: a refused reorder (drag in the sidebar or the tab strip) | `list.failed(error)` | **card** | "Could not move the window" / "… the session" + the server's text. The projected order snaps back as today. |
| `SidebarView.rejectRename`, 110 | inline under the field | **inline** | Unchanged. |
| `Palette.reject` (`main.swift:508–518`): New Session, Rename Session, Connect, Prompt, Theme | inline in the palette | **inline** | Unchanged. The prompt's refused/unknown/invalid states stay in the palette. |
| `PaletteEntries`, a failed runtime's message; `RuntimeSection.configError` (the server's view of `config.yaml`, from the Welcome) | inline in the palette and the section | **inline** | Unchanged: the server's runtime error is the section's row, decided with the Runtimes section. |
| `Sidebar.showConfigError` / `ConfigBanner`: the app's own load of `~/.config/ko/config.yaml` or a theme file (`GhosttyRuntime.configError`) | the 62pt strip, "Reveal in Finder" | **config** | The persistent card with "Open config". The strip goes; the panes no longer reflow. |
| `notice(_:_:)`, 836: the upload refusals and failures (701–832), `confirmCommand`'s failure (1413: a kill, a runtime shutdown, a close that the server refused), the clipboard reader's errors and timeouts | a window-modal `NSAlert` + a `note` line | **card** | The same card, with the sheet's title and detail: a failure of a background action does not block the window. The detail of an upload failure can be long: the long-message rule below. `notice(_:_:)` becomes the call that shows a card, and the sheet goes. |
| `Notifications.failed` (`Notifications.swift:28`): authorization denied, a post or a badge that failed | one `note` line for each launch | **card** | One card for each launch, at the first notification that could not post, in the key window: "Kido could not post a notification" with the system's text ("authorization denied", or the error). The `loggedFailure` once-per-launch rule stays, now for the card and the line. |

The sidebar keeps no status line: `statusLine`, `failure`, `feedNote`,
`failed(_:)`, `offline(_:)` and `noteChanged` go, and the list starts at
the top. `ConfigBanner.swift` goes. `Banner.swift` is unchanged.

**The edit titles.** `LayoutEditor.onFailure` gets the edit with the
error, and the owner names the action from the edit's case, in one
table (the `KoSchema.Edit` enum is the type that names the cases):
add window "Could not open a window", split "Could not split the
pane", delete pane/window/session "Could not close the pane/window/session",
zoom "Could not zoom the pane", resize "Could not resize the pane",
float "Could not move the float", add session "Could not create a
session", rename "Could not rename the session", reorder "Could not
move the window/session", ensure session (never a card: the banner). A
case with no row falls back to "Kido could not change the layout".
The detail is `failureText(error)`: the server's `detail`, else the
error's description.

## 1. The card

**Where (states `transient`, `columns`, `float`; control Position).**
A column at the pane area's bottom-right, 16pt from the right and the
bottom edge of the terminal area (`sidebar.content`), the area that the
banner veils: under the title band, right of a docked sidebar, the
whole width when the sidebar floats or is collapsed. It belongs to the
area, not to a pane, so it crosses dividers and takes no part in the
layout. The anchor is the same in every sidebar mode and in full
screen. Why bottom-right: the top-right holds the hover toolbar and
find, the top-left the COPY pill, and a shell's prompt and cursor are
at the bottom-left; the bottom-right is the corner with the least
chrome and the least text. Bottom-centre (Position control) is the
alternative: more visible, over the shell's output. Recommendation:
bottom-right.

**Size and surface.** 360pt wide (`min(360, area width − 32)`),
height from its content, 12pt corners, the capsule surface of the
pane chrome (`Chrome.capsuleSurface`: the terminal background mixed 8%
toward the foreground, a 0.5pt edge at 12% of the foreground, the
0.5pt inner highlight), the float's shadow (`Chrome.floatShadow`:
black 22%, blur 12, here drawn a little deeper). Opaque: no blur, no
glass, so terminal text never bleeds through. 12pt padding at the
sides, 9pt at the top, 10pt at the bottom.

**Content.** A 6pt `systemRed` dot at x=12, centred on the title's
line: the sidebar's error mark, so the card speaks the same status
vocabulary. The title at x=26: 12pt semibold `labelColor`, one line,
cut at its end. The detail under it, 2pt down: 12pt regular
`secondaryLabelColor`, wrapped to at most five lines, then cut with an
ellipsis (state `long`). No tooltip, no disclosure: the whole text is
in app.log, the one place for it.

**Z-order.** Panes, dividers, floats, the banner, then the notices.
A card draws above a float under the anchor (state `float`) and above
the banner's veil (state `banner`); the anchor never moves to avoid
either.

**Never the keyboard.** The column is an `NSView` of the terminal
area, not a window. No view in it accepts first responder; the config
card's buttons have `refusesFirstResponder`. A click on a card is
consumed by the card (`hitTest` returns the card) and changes neither
the first responder nor the focused pane. The pane under the card
keeps the focus, the cursor and the typing. Accessibility: a new card
posts an announcement (`NSAccessibility.post(..., .announcementRequested)`)
with its title and detail, so VoiceOver reads it; the card is a group
with the two texts, and its buttons are reachable by the VoiceOver
cursor.

## 2. A transient card

**Timing.** Shows at once; the clock is 5 s from the show, 8 s when
the detail wraps to three lines or more. The pointer over the card
pauses the clock (the standard behaviour of a toast; it lets the user
read a long one) and leaving resumes it. A click anywhere on the card
dismisses it at once. It has no × and no buttons.

**Animation.** In: 150 ms, opacity 0→1 and a rise of 8pt, ease-out.
Out: 200 ms fade. With Reduce Motion: the fades alone. The column
reflows with the same 150 ms when a card above leaves.

**Several (states `two`, `two-replace`).** A second failure within the
first's clock gets its own card above the first, 8pt apart, each with
its own clock; the column grows upward from the anchor, so the newest
is nearest the edge and nothing below it moves when a card above
leaves. At most three transient cards show; a fourth pushes the oldest
out at once. The same failure text arriving while its card shows
(a drag refused twice) resets that card's clock instead of adding a
card. Rejected: replace, where the newer card takes the older's place.
Cheaper, but a refused drag followed by a refused split loses the first
text within a second, and the user sees one card flicker.
Recommendation: stack.

**The log.** Every card writes one `note` line, in the form that
`notice` writes today: `HOST: TITLE: DETAIL`, with the whole detail.

**Several windows.** A transient card belongs to the window whose
action failed. Two windows on one server that both refuse the same
edit each show their own card; the log gets one line for each.

## 3. The config card (states `config`, `config-transient`, `banner`)

The same card, persistent. Title: the file's path, abbreviated as the
strip shows it (`runtime.abbreviate`), "~/.config/ko/config.yaml has
an error" (or the theme file's path). Detail: `line:column: message`,
one line, cut. An × at the top-right in the 16pt slot of the tab close
button (hover: the 10% `labelColor` fill at a 4pt radius). A row of
actions under the detail, right-aligned: **Open config**, a 22pt
rounded bezel (`NSButton`, `.rounded`, small control size), which
opens the file with its default app (`NSWorkspace.shared.open`), so
the user lands in the file's editor, not in Finder. Rejected: "Reveal
in Finder", the strip's button, because the file needs an edit, not a
selection. A click on the card's body does nothing.

**Life.** It shows when a load fails (`GhosttyRuntime.configError`
becomes non-nil or changes its text) and stays until × or a load that
decodes. × remembers the error text: the same text does not show
again; a different one does (the next failed reload, a new line
number). App-wide: the error is the app's, so every window shows the
card, × in one dismisses it in all, and a window opened while the
error stands shows it. One `note` line for each failed load, as today.

**The anchor.** The config card holds the anchor; transient cards
stack above it (state `config-transient`) and leave on their own, so
the config card never moves. It stays over the banner's veil (state
`banner`): the file error is not the connection's, and a user who
fixes the file while the server restarts needs the line number. A
transient card that is showing when the banner appears stays too and
leaves on its clock.

**What goes.** The 62pt strip and the reflow of the panes under it;
the panes keep their size when the config breaks. `ConfigBanner.swift`
and `Sidebar.showConfigError` go; `WindowOwner.showConfigError` becomes
the call that shows the card. `testConfigErrorBanner` records the card
instead.

## 4. The modes (controls Window, Sidebar)

Windowed and full screen, docked, floating and collapsed: the anchor
is the terminal area's bottom-right, 16pt in, in all six. A floating
sidebar is on the left and never reaches the column. In full screen
the area starts under the 52pt band, as today. On a narrow area the
card is the area's width minus 32pt.

## Decisions (2026-11-07)

1. The card, as drawn: bottom-right of the pane area, 16pt in, 360pt
   wide, the capsule surface, the 6pt red dot. It never takes the
   keyboard.
2. Every error goes through it: the sidebar status line's callers,
   the config strip, and the notice sheet's callers (uploads,
   `confirmCommand`, the clipboard reader), and the notification
   failures. The sheet, the strip and the status line go. The
   connection banner stays as it is.
3. Transient: 5 s, 8 s for three lines or more, the pointer pauses, a
   click dismisses. Stacked, newest nearest the edge, at most three.
   The same text while its card shows resets that card's clock.
4. The config card is persistent with × and "Open config" (the
   default app for the file). App-wide: every window, one ×
   dismisses it in all, a new error text shows it again. It holds the
   anchor and stays over the banner.
5. System notifications stay what they are: for what happens while
   the user is away. An in-app failure is never a system
   notification: Kido suppresses them while frontmost, they can be
   denied, they do not persist on the window, and they would pile up
   in Notification Center.
