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

- Head row (45pt): the mode chip `bubble.left` "Prompt", then the **target picker**: a popup-style chip "Prompt **@kido-app** in this window ⌄" (12pt, agent semibold, place in `secondaryLabelColor`, chevron). For a closed source pane the place reads "in window app (pane closed)".
- Field: 13pt, 18pt lines, 9pt/10pt vertical padding, no placeholder: an empty field shows only the caret. Shift-Return adds a line; the card grows to 6 lines (108pt) then the field scrolls. Return sends. The field holds plain markdown, styled in place as the user types; markers stay visible and the text is exactly what kido gets.
- Quote: no separate block. Select + ⌘O appends to the end of the text: if the text is not empty and does not end with a blank line, a blank line first; then the empty caret line; then the selection as `> ` lines. Thus the caret line always has a blank line before it (after earlier text or an earlier quote) and the quote directly after it: a blockquote can interrupt a paragraph, so what the user types on the caret line stays a paragraph, and the blank line before it keeps it out of an earlier quote (CommonMark's lazy continuation). A second selection appends the same way (duplicates are not skipped, state `prompt-twoquotes`: text, blank, quote 1, blank, caret line, quote 2). The quote shows in full and is ordinary text: editable, deletable.

**Markdown styles in the field** (state `prompt-markdown`). All styles keep the 18pt line and the 13pt base size, so lines never reflow when a marker is typed.

- Quote styling follows the markdown parse (blockquote nodes from swift-markdown), not each line that starts with `> `; a lazy continuation line is styled as quote because it is one. A blockquote line shows the bar, its `> ` marker and the quote text. The marker (`>` and its following space) is visible, in `tertiaryLabelColor`; the quote text after it is in `secondaryLabelColor`; nothing is hidden, so editing has no special cases. The marker sits at the field's normal text edge and the quote text follows it; the 2pt bar sits in the padding, 8pt left of that edge (x = 8pt in the 16pt padding), in `secondaryLabelColor` at 45% opacity, spanning the line's full 18pt so consecutive quote lines form one bar; an empty line between quotes breaks the bar.
- The other markers (`**`, `*`, `` ` ``, `#`) stay visible for now; the user asked only about quotes.
- `` `code` ``: SF Mono 12pt on the 18pt line, `labelColor` 8% fill, 3pt radius, 1pt horizontal padding, backticks inside the fill.
- `**bold**`: semibold, markers included. `*italic*`: italic, markers included.
- `# heading` (any level): semibold at the same 13pt, marker included; no size change, so the line stays 18pt.
- Nothing else is styled (lists, links, rules render as plain text).
- Status line (11pt, between quote and foot, `separatorColor` rule above): sending (spinner, "Sending to @kido-app…"), refused (red, `exclamationmark.triangle.fill`, message, **Retry** at the right in accent), unknown (red, "<message> It may have arrived; not resent.", **Copy Prompt** at the right, field read-only and muted, Send hidden), invalid (red, message; the picker stays enabled), pane closed (secondary, "Source pane closed; agents resolved earlier stay available."). After a successful send the palette closes; no sent state.
- Foot: key hints `↩ send · ⇧↩ new line · ⇥ agent · esc close, keeps draft`, "· draft restored" when a draft came back, and the 26pt Send button at the right (8pt radius, accent, `arrow.right`; 14% label fill when the field has no non-blank text or sending is impossible).

**Picker operation.** Mouse: click the chip opens an NSMenu-style list under it: group "This window" with its agents, then "Session <name>" with the rest, the current one checked. Keyboard: Tab moves focus from the field to the chip (2pt accent-55% focus ring); Space or Return opens the list; Up/Down move in the list, Return chooses and focus returns to the field; Escape closes the list without change. With the chip focused and the list closed, Left/Right cycle agents without opening it. Up/Down inside the field move the caret, so the field and the picker never fight. Shift-Tab from the field goes to the Send button.

**Entry points.** ⌘O from a pane: closest agent (same window first, then the session), no quote. ⌘O in the root list with an agent pane row selected: Prompt mode targeting that agent; the selected agent row shows a right-aligned "⌘O prompt" hint in the shortcut column (state `root-agent`), on the selected row only. Root command "Prompt…" (⌘O): like ⌘O. `p` in copy mode and right-click "Prompt with Selection…": Prompt mode with the selection as quote.

**Drafts.** Closing the palette (click outside, window switch, Escape) keeps one draft per source pane with its text, quote and chosen target; the next ⌘O from that pane restores it and the foot says "draft restored". Send clears it; deleting the text discards it.

**Decided (user).** Send is enabled whenever the field holds any non-blank text, a quote alone included. No placeholders. Quote markers visible, dimmed to `tertiaryLabelColor` (reversed from hidden: too many editing edge cases). Escape keeps the draft. Tab focuses the picker. The "⌘O prompt" hint shows only on the highlighted agent row. With no agent in this window or session, ⌘O and every other prompt entry (root command, `p` in copy mode, right-click Prompt with Selection…) only beep and open nothing; there is no no-agent Prompt state. The root command "Prompt…" is absent from the list (state `root-noagent`) because the PR lists only enabled menu items and the Prompt… menu item is disabled without an agent.

## Theme mode (approved)

Root entry "View › Theme…" (no shortcut). States `theme*`.

**List.** Chip `paintpalette` "Theme", placeholder "Search themes", fuzzy-filtered. One row per theme, 34pt: a swatch (18pt rounded square in the theme's background with "Aa" in its foreground, plus a 2×2 grid of its blue, green, red and yellow), the name, a small "light" or "dark" tag derived from the background luminance (below 0.5 is dark), and at the right "✓ Light" / "✓ Dark" on the themes the config currently uses for each appearance. Order: bundled first, then `~/.config/kido/themes` by name. No light/dark grouping: the tag and the filter are enough for four to twenty themes.

**Preview.** Moving the selection (Up/Down, or hover with the mouse) applies the theme live to every pane, the sidebar shade, the chrome and the palette card itself; the card's colours derive from the terminal theme, so it changes with the app and never floats in the old colours. A status line says "Previewing <name>. ↩ chooses where to use it, esc restores the current theme." Escape, click outside, window switch and ⌘P all restore the current theme. Hover previews only while the pointer is over the list and restores the keyboard selection's preview when it leaves.

**Save step** (second step in the palette, not an alert). The head shows the chosen theme as a chip with its swatch and the field reads "Use for…". Three radio rows, keyboard Up/Down, ↩ confirms, Escape goes back to the list: "<Current appearance> mode · the current appearance" (preselected), the other mode, "Both · one theme whatever the appearance", "This session only · not saved to kido-app.conf" (state `theme-save-session` shows it selected; its foot reads "applies until quit; ~/.config/kido/kido-app.conf is not changed" at the left, "esc back" at the right). On ↩ with "This session only", the theme applies to both appearances until quit and the palette closes; the conf is untouched, so a read-only conf gives no error. The picker later previews from and restores to that session theme; a later real save replaces it; the "✓ Light" / "✓ Dark" marks keep showing what the conf names. The foot shows the exact line it will write: `theme = light:A,dark:B` into `~/.config/kido/kido-app.conf` (Ghostty syntax), with the other side kept from the config, or the current default when the config has no theme line. On ↩ the palette writes, applies and closes.

**Errors.**

- Config not writable: red status "Could not write ~/.config/kido/kido-app.conf: permission denied. <theme> is applied for this session only." with "Reveal in Finder" at the right. The list stays open.
- Theme file missing or invalid: the row is dimmed with "theme file not found" (or "invalid: <line>") in red at the right. A dimmed row can be selected and hovered, and the preview shows what the file gives (Ghostty's defaults), but Return and click do nothing. The red status reads "<path or name>: not found. The current config names it for <Light|Dark>; Ghostty's default colours are shown instead." For an invalid file: "<path or name>: invalid: <first diagnostic>. The current config names it for <Light|Dark>; Ghostty's default colours are shown instead." Ghostty's defaults, not kido-light: the user's theme line replaces kido's defaults, so a missing theme leaves Ghostty's built-in colours.

**Keys and mouse (decided).** In the list, click on a row = Return. ⌫ on an empty field goes back to root and restores the current theme. In the save step: Up/Down move the radio; click or Return writes and closes; Escape or ⌫ go back to the list with the preview still live.

**Decided (user).** Pointer hover previews and restores on leave. "Both" with no theme line writes `theme = light:<name>,dark:<name>`. The current marks are the text "✓ Light" / "✓ Dark". Themes of the other appearance preview anyway. There is no check for inline colours in the config (dropped).

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
