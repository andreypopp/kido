# Copy mode: selection, context menu and prompt box — approved design

Open `mockup.html` through the design preview server (`python3 -m http.server 8765 --bind 127.0.0.1` from `app/design`, then http://127.0.0.1:8765/copy-select/mockup.html). Self-contained, no network, nothing is sent. Controls select the selection gesture, the stage (menu and every box state), the surrounding chrome (COPY pill, hover toolbar, find open with the toolbar below), a narrow 320pt pane and the theme. Right-click the pane or press `p` for the flow; Enter sends (simulated: the box closes, the selection clears), Escape cancels. The panel under the window shows exactly what would be sent; the gallery renders every box state in light and dark.

Decided by the user on 2026-10-18 from `/tmp/kido-copy-select-plan.md` (all recommendations) plus the designer's fixes listed below. Reuses the pane capsule style from `app/design/pane/NOTES.md` (opaque theme-background fill mixed 8% toward foreground, 0.5pt foreground-12% edge, 0.5pt white-12% inner top highlight, 6/18pt black-20% shadow, 12pt radius, 26pt IconButtons with 15pt symbols).

## 1. Mouse selection in copy mode (app-side, never forwarded to Ghostty)

- Left press places the copy cursor (a press on a selection drops it); drag selects from the press cell; double-click selects the word, triple-click the wrapped line; a drag after double or triple extends by word or line; Shift-click extends the current selection to the clicked cell in the current mode. Keyboard motion continues from a mouse-placed cursor; `y`/Return copy a mouse selection. Drag beyond the grid autoscrolls the frozen viewport within loaded rows only.
- The mouse never enters copy mode from a normal pane; outside copy mode Ghostty's own selection stays as it is. Both feed the same menu and box through `read_selection`.
- Selection color: `controlAccentColor` at 35% (dark) / 28% (light) behind the cells, 2pt radius on run ends, text unchanged; the copy cursor keeps its hollow block.

## 2. Context menu (native NSMenu, built fresh per click)

- Trigger: right-click or Control-click on a pane that has a selection, in copy mode or not. A right-click outside the selection, including on empty cells, keeps the existing selection and opens the menu for it; with no selection it selects the word under the pointer first (in copy mode, in `v` mode); with no text under it and no selection, nothing opens.
- Items, in order: **Copy** (⌘C) and **Prompt with Selection…** (`p` in copy mode). Nothing else: no Select All, no Exit Copy Mode, no submenu, no ⌘⇧P or ⌘⇧↩.
- Copy behaves as today: in copy mode it copies and exits copy mode; outside it copies Ghostty's selection and keeps it.
- Prompt with Selection… is always enabled when a selection exists; availability of a target is shown inside the box, because candidates are known only after the resolve request.
- Mouse-reporting programs receive the right-click unless Shift is held; a user `right-click-action` other than `context-menu` hides the menu (documented, not worked around).

## 3. Prompt box (inline capsule in the pane)

- **Placement.** Bottom-left of the pane: x = 8, bottom inset 8, width = min(paneWidth − 16, 560), 12pt radius. The COPY pill, the find capsule and the hover toolbar stay exactly where they are; opening the box closes nothing. Floats use the same rule inside their bounds.
- **Rows, top to bottom.**
  - Head, 32pt: the **target popup** at x 3, 26pt tall, 8pt radius, 12pt text, hover fill label 12%, chevron: "Prompt **@name** in this window". It is always a popup: agents in the pane's window first, then the rest of the session (with window name), the closest (first same-window) preselected; each item shows the status dot, title and pane id. While the resolve request is in flight it reads "Resolving…" (secondary, inert). With no candidates the popup is absent and the head reads "No agent in this window or session" in secondary, with the field and Send disabled. Spacer, then × Cancel (26pt IconButton, tooltip "Cancel (Escape)", accessibility label "Cancel").
  - Text: an NSTextView without bezel, 13pt system, 18pt lines, 11pt inset, placeholder "Ask about the selection", grows from one to five lines (90pt) then scrolls. Enter sends; Shift-Enter inserts a newline; Escape cancels.
  - Quote, below the text: the selection's first two lines in 11pt monospace secondary with a 2pt accent-60% left bar, each line truncated with an ellipsis, then "+N lines" in italic when longer. Captured when the box opens (`read_selection`), not at Send; the full captured text is the quote's tooltip. Not editable.
  - Foot, 32pt: status text (11pt) at the left, spacer, the hint "↩ send · ⇧↩ newline" in secondary while idle, and **Send**: a 26pt accent-filled button with the arrow glyph (tooltip "Send (Return)"), disabled (label 14% fill) while the text is empty or no target exists.
- **Focus.** The text view is first responder on open; the capsule shows the accent focus ring (40%, 3pt) while it is. Key loop: text, target popup, Cancel, Send. Clicking the pane body does not close the box. Escape, Cancel, a pane switch, pane removal and copy-mode exit close it. ⌘ chords typed in the field go to the field, not to the pane's copy-mode handling.
- **Sending.** Text, popup and Send disable; status shows a 9pt spinner and "Sending to @name…". The request names the pane and the explicit target chosen in the popup.
- **Delivered.** The box closes, the selection clears, copy mode exits and the live pane is restored. No jump to the target.
- **Errors** (status in red under the field, text kept, verbatim kido message):
  - *Refused* ("@name is not accepting messages", inbox advertised but not accepting, nothing delivered): a **Retry** button next to the message; Send stays disabled until Retry or an edit.
  - *Delivery unknown* (socket error after connect): "Could not send: <error>. It may have arrived; not resent." with a **Copy Prompt** button that puts the composed text on the clipboard; Send is hidden for this composition, there is no Retry.
  - *Invalid* ("no such pane", "empty prompt", "pane %12 is not an agent"): the message only; Send re-enabled after an edit or a new pick.
  - *Candidates changed* (ambiguous reply after an explicit target): the popup refreshes and the user picks again.
- **Composed text**, exactly as delivered through the prompt RPC:

      <prompt text>:
      > line 1 of selection
      > line 2 of selection

  One trailing newline from line mode is stripped first; every remaining selection line, empty ones included, gets "> "; the colon is added unless the prompt already ends with ":".
- **Accessibility.** Box: role dialog "Prompt with selection". Popup: "Send to", pop-up button. Text view: "Prompt". Quote: static text "Selected text, N lines". Status: polite live region. Send: "Send prompt". Cancel: "Cancel".

## 4. Fixes the user accepted over the plan

Keep the find bar and the COPY pill while the box is open; × and a 26pt icon Send instead of text buttons; Enter sends and Shift-Enter inserts a newline; the menu item stays enabled and the box reports "No agent…"; the quote sits below the prompt with the full selection as its tooltip; a right-click on empty cells opens the menu for the existing selection; placeholder "Ask about the selection"; the popup is always shown (not only for several candidates). The error reply needs a kind the app can read, so refused, delivery-unknown and invalid render differently.
