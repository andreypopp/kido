# Command palette (approved)

`mockup.html` is a self-contained reference for the ⌘P command palette, based on PR #11 (branch `command-palette`). Open it in a browser; `?state=<id>&theme=Light|Dark` selects a state. Code is the source of truth.

## Base (from the PR, kept)

- ⌘P and ⇧⌘P both open the same root list (as in the PR); there is no separate commands-only palette.
- One flat root list: sessions, panes, recent hosts that have no open Kido window (the mockup's window is on devbox, so devbox is absent) and these commands, in this order, with their shortcuts: New Session ⌘N, Rename Session…, Close Session, New Window ⌘T, Close Window (new), Split Right ⌘D, Split Down ⇧⌘D, Close Pane ⌘W, Zoom Pane ⇧⌘↩, Connect to Remote Host… ⇧⌘K (new shortcut), Hide/Show Sidebar ⇧⌘S, Focus Sidebar ⌘S, Enter Full Screen ⌃⌘F, Find… ⌘F, Copy Mode ⇧⌘C, Prompt… ⌘O, Reset Clipboard and Upload Permissions. Not listed: Next/Previous Session/Window/Pane, the eight Select Pane items, the numbered window and session lists, Find Next/Previous, Hide Kido, Quit Kido and system items. New Local Window and Clear are removed from the app, menus included. Fuzzy-filtered with the sidebar's scorer. Matched characters in `controlAccentColor`. The first row is selected; ↑↓ move, ↩ performs, Escape closes.
- Rows: 34pt, 6pt radius, selected row `labelColor` 10% fill, inset 6pt from the card edge. Leading 36pt icon slot: status dot for panes, `square.stack` for sessions, `globe` for hosts, empty for commands. Detail (`host › session`, menu path) in `secondaryLabelColor`, title in `labelColor`, agents semibold. Shortcut right-aligned, 11pt `secondaryLabelColor`.
- Field 16pt, head 45pt, placeholder "Search sessions, panes and commands". "No matches" row at 34pt.
- Card 600pt wide (window width − 32 when narrower), 12pt radius, opaque terminal background mixed 7% toward foreground (dark `#232323`-ish, light `#f2ede0`-ish), 0.5pt edge `foreground` 14%, shadow black 40%, y 14, blur 40. Theme-relative: follows the key window's terminal theme; with no window, the app's appearance and the default theme.

## One palette for the app

- Over the key Kido window: horizontally centred on the window, the card's top 20% of the content area below the toolbar. The panes show the 0.31 treatment under it (shifted inactive panes; the focused pane keeps its edge but its cursor goes hollow because the panel is key).
- With no Kido window: a floating panel on the main screen, centred, top at 20% of the screen height (Spotlight's position). The root then lists every recent host, New Session and Connect to Remote Host… only.
- Following: the palette is one `NSPanel` at `.floating` level, keyed. It closes when it resigns key (PR behaviour). Thus switching to another Kido window closes it; reopening ⌘P there opens it over that window. It does not move with a window drag; it closes on window resign-key.

## Submodes

A mode is a chip at the left of the field: 22pt high, 6pt radius, `labelColor` 10% fill, 12pt medium, SF symbol 12pt before the text. The chip is not a control. Entering a mode clears the field. Backspace on an empty field, or Escape, returns to the root with an empty query; Escape at the root closes. ↩ performs the mode's action and closes.

A foot under the list, 11pt `secondaryLabelColor`, names the keys: `↩ connect · ⌫ on empty field back · esc back`. Errors are a line between the head and the list: 11pt `systemRed` with `exclamationmark.triangle.fill` 12pt, wrapped, the field text kept.

**Connect** (chip `globe` "Connect", placeholder "user@hostname or SSH alias"). Entered from the root row "File › Connect to Remote Host…" or ⇧⌘K while the palette is open. The list shows recent hosts (title, relative time at the right, like the sheet), filtered by the typed text; with text, the first row is "Connect to <typed>" in accent with ↩, selected. Last row with no text: "Clear Recent Hosts", a secondary command row. With no recent hosts: "No recent hosts". ↩ connects to the selected row, or the typed text. An invalid host keeps the text and shows the `Host` failure message as the error line; no connect row is offered until the text changes. A chosen host opens a new window as the sheet did. The Connect to Remote Host sheet goes away.

**Rename session** (chip `pencil` "Rename session"). Entered from "Session › Rename Session…". Targets the key window's session; the foot says "session main of the key window". The field holds the current name, fully selected. ↩ commits through the sidebar's `SessionRename`: empty or unchanged reverts silently; `:` or `.` and a duplicate name show its message as the error line; a tmux refusal shows tmux's message. With no window the row is absent. The sidebar's double-click inline rename stays beside this mode; both commit through the same `SessionRename` rules.

## Decisions (user approved)

- Rename targets the key window's session, no picker first. A picker would be a second step for a rare action; a user who wants another session switches to it first or double-clicks its name in the sidebar.
- Mode marker is the label left of the field, not a title line: it keeps the field on one row and the card the same height as the root.
- Clear Recent Hosts has no confirmation.
- Errors above the list, not below the field inline: the field stays single-line and the list below it is still the answer.

## Prompt mode (approved, replaces the floating prompt boxes)

One prompt at a time, in the palette card, centred over the window like the other modes. States `prompt*` and `root-agent`.

**Layout, top to bottom.**

- Head row (45pt): the mode chip `bubble.left` "Prompt", then the **target picker**: a popup-style chip "Prompt **@kido-app** in this window ⌄" (12pt, agent semibold, place in `secondaryLabelColor`, chevron). With no agent in scope it reads "No agent in this window or session" in secondary colour and is disabled. For a closed source pane the place reads "in window app (pane closed)".
- Field: 13pt, 18pt lines, 9pt/10pt vertical padding, placeholder "Ask the agent" ("Ask about the selection" with a quote). Shift-Return adds a line; the card grows to 6 lines (108pt) then the field scrolls. Return sends.
- Quote, only with a selection: between the field and the foot, 2pt accent-60% bar, 11pt monospace secondary, condensed as the box did (first line, italic "⋯ N lines", last line; all lines for 1–3). Hover shows the full selection as a tooltip.
- Status line (11pt, between quote and foot, `separatorColor` rule above): sending (spinner, "Sending to @kido-app…"), refused (red, `exclamationmark.triangle.fill`, message, **Retry** at the right in accent), unknown (red, "<message> It may have arrived; not resent.", **Copy Prompt** at the right, field read-only and muted, Send hidden), invalid (red, message; the picker stays enabled), pane closed (secondary, "Source pane closed; agents resolved earlier stay available."). After a successful send the palette closes; no sent state.
- Foot: key hints `↩ send · ⇧↩ new line · ⇥ agent · esc close, keeps draft`, "· draft restored" when a draft came back, and the 26pt Send button at the right (8pt radius, accent, `arrow.right`; 14% label fill when the field is empty or sending is impossible).

**Picker operation.** Mouse: click the chip opens an NSMenu-style list under it: group "This window" with its agents, then "Session <name>" with the rest, the current one checked. Keyboard: Tab moves focus from the field to the chip (2pt accent-55% focus ring); Space or Return opens the list; Up/Down move in the list, Return chooses and focus returns to the field; Escape closes the list without change. With the chip focused and the list closed, Left/Right cycle agents without opening it. Up/Down inside the field move the caret, so the field and the picker never fight. Shift-Tab from the field goes to the Send button.

**Entry points.** ⌘O from a pane: closest agent (same window first, then the session), no quote. ⌘O in the root list with an agent pane row selected: Prompt mode targeting that agent; the selected agent row shows a right-aligned "⌘O prompt" hint in the shortcut column (state `root-agent`), on the selected row only. Root command "Prompt…" (⌘O): like ⌘O. `p` in copy mode and right-click "Prompt with Selection…": Prompt mode with the selection as quote.

**Drafts.** Closing the palette (click outside, window switch, Escape) keeps one draft per source pane with its text, quote and chosen target; the next ⌘O from that pane restores it and the foot says "draft restored". Send clears it; deleting the text discards it.

**Decided (user).** Escape keeps the draft. Tab focuses the picker. The "⌘O prompt" hint shows only on the highlighted agent row. With no agent in scope the field stays editable so a draft can be written; Send is disabled.

## Match highlight (open, user to choose)

The PR colours matched characters in `controlAccentColor` (A). The Match highlight control and `?match=accent|bold|run|dim|ul` switch the variants; the "Match highlight variants" section under the stage shows all five in both themes for the current state. Use the states "rm" (scattered matches over several rows), "mterm" (scattered across detail and title), "watch" (contiguous) and Connect typing "dev".

- **A accent (PR).** Matched characters in `controlAccentColor`. Loud, and the accent already means "action" in the Connect row.
- **B bold, label colour.** Matched characters at weight bold in the row's own colour. Invisible on agent rows, which are already semibold, and detail text turns from secondary to label colour.
- **C background run.** Each matched run gets a fill of the terminal foreground at 14% with a 3pt radius and a 1pt halo of the same colour, text unchanged. Reads in both themes, works on semibold rows and on secondary detail text, and leaves the row's colour and weight alone. Recommended.
- **D dim the unmatched.** Unmatched characters at 55% of their colour, matched ones at full colour. Calm, but the list as a whole gets harder to read, and a one-character match dims a whole row.
- **E underline.** 1pt underline at 55% label colour, 2pt offset. Fine for contiguous runs, noisy for scattered ones.

Recommendation: C. Fallback: D.

## States (gallery, light and dark)

Root empty, root filtered "mwatch", root filtered "ren" (commands), no match, connect empty, connect typing "dev", connect invalid host, connect with no recent hosts, rename, rename duplicate, rename bad character, no-window panel.
