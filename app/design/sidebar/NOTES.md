# Sidebar reference — macOS 27

## Current redesign draft: uniform rows and hierarchy guides

This preview now explores a new direction requested by the user, superseding the older geometry and no-guide decisions below. Native window chrome remains unchanged.

- All pane and child-record titles: 13pt system font, 18pt line height, regardless of depth or single-/multi-pane window; agent, agent-run and record titles semibold, shell and bash/stream-run titles regular.
- All rows: 32pt single-line / 48pt with caption, 7pt vertical padding. Captions: 11pt system font, 15pt line height, 1pt gap below title.
- Uniform 15pt nesting step for child windows and slash-separated program records, chosen so each nested guide sits exactly on the parent icon's center (12pt inset + 8pt half icon = 20pt; 15pt indent + 5pt guide inset = 20pt). No extra window/pane spacing or divider rows.
- All guides are identical vertical 1pt lines in one opaque color (`#bfbab1` light, `#4f555c` dark), with no horizontal arms, no transparency and no overlapping segments. A guide sits 5pt inside the left edge of the group it covers and spans that whole group, 10pt inset top and bottom: a multi-pane top-level window's guide covers its pane rows and every descendant between and below them; a nested guide covers a parent's entire children block, including grandchildren; a program-record guide covers all records under their parent. Single-pane windows have no window guide.
- Only the focused pane row gets a background highlight, with 7pt corners. No focused left-edge mark, window-wide fill, neighboring-pane fill or descendant fill. Guides are decorative, noninteractive, and do not affect hit targets.
- Program records are nested agent rows: the preview maps each record to an agent node (title or ID, caption as the activity line, state mapped onto the indicator kinds working→running, blocked→waiting, error→failed, done→done) and draws it through the one row builder, so heights, the 15pt step per slash component, the leading status indicator, the semibold title and the ellipsis all come from the same code as subagent and run rows. Differences: no @ prefix, no click or keyboard selection, and arrow navigation skips them. The @ means "an agent you can message", which is exactly a local pi agent (Pi_agent) or an agent run. A native agent pane such as Claude Code (Some_agent) and an agent reached over SSH (an Ssh pane running a remote agent; message_agent only reaches pi sessions on the same server) cannot be messaged, so their rows and tabs stay semibold without the @. The preview marks both with the `unmessageable` flag: the Claude Code fixture and the "pi-review on devbox" row in the work session. Native code should do the same: one row view, records fed as agent rows with a display-only flag.

Guide geometry, measured in the preview (points from the window item's left edge; rows are 32pt or 48pt tall, titles at a 16pt baseline band):

| Guide | x (from its group's left edge) | Vertical extent |
| --- | --- | --- |
| Multi-pane window guide | 5 | first pane row top + 10 to window item bottom − 10 |
| Children-block guide | the parent row's status indicator center (20 from the parent row's edge) | parent indicator bottom + 3 to last descendant bottom − 10 |
| Program-record guide | the parent row's (pane or record) indicator center | parent indicator bottom + 3 to last nested record bottom − 10 |

Nested guides therefore grow directly out of the parent's status indicator, not from the first child's top. Multi-pane window guides have no parent icon and keep their own column.

Lines are 1pt with crisp edges, centered on their x. Guides draw above fills, as content does in native lists; the multi-pane guide therefore crosses the left edge of a focused row's fill. Keyboard-selection and focused fills both use 7pt corners.

Self-review (headless Chrome, light and dark, Claude Code and stress fixtures): every row measures 32pt or 48pt at 13pt title size across all depths; nesting steps are a uniform 15pt; indicators lead and clocks share one trailing column for rows and records. Fixed during review: record elbows previously started 28pt right of child-window stems and from the parent's bottom edge; the keyboard fill was square-cornered. Open visual point: whether the multi-pane window guide should stop at the focused row's fill instead of crossing it.

Leading icons are removed for now; the status indicator takes their place. Earlier icon variations, kept for reference (not in the preview any more):

| Set | Agents | Terminals | Runs | Notes |
| --- | --- | --- | --- | --- |
| A | `text.bubble` | `terminal` | as terminal | shipped before 0.17; removed |
| B | `sparkles` | `terminal` | as terminal | reads "AI" at a glance, lighter than a framed bubble |
| C | `text.bubble.fill` | `terminal.fill` | as terminal | heavier; solid shapes hold up better when dimmed and at 2× |
| D | `text.bubble` | `chevron.right` + underscore (`terminal` without frame) | as terminal | less boxy; the bare prompt is quieter next to the bubble |
| E | bot face (custom; no exact SF Symbol, closest `faceid` or a custom symbol) | bare prompt | as terminal | strongest agent/shell contrast, least Apple-native |
| F | `text.bubble` | `terminal` | `play.circle` | three kinds: async bash and stream monitors become runs, separating them from interactive shells |

Current rule: no leading icon of any kind. The status indicator (6pt dot; for done a plain green check with no circular base: the path `M0.2 3.2 2.1 5.1 5.8 1.1` in a 6pt box, stroked 2pt with round caps and joins in opaque green, which the app draws with NSBezierPath rather than an SF Symbol; its visual center sits on the dot's center, horizontally on the dot column and vertically on the title line's center, like every other indicator) sits in the former icon slot, centered 20pt from the row's edge (12pt inset + half the 16pt slot) plus 15pt per nesting level; idle is a gray dot (secondary color at 45%) so every row has a mark. The trailing column keeps only the elapsed clock. Program records use the same row layout, so a record's dot and title line up with child-window rows at its depth. Agent titles (agents, agent runs and program records) are semibold (600); shells and bash/stream runs stay regular. With the @ prefix and the dimmed "Terminal" title, that is the whole agent/shell distinction.

Review the default Claude Code fixture for program records and scroll to the multi-pane kido-app group for selectable nested windows. This is a draft for visual review, not an approved implementation specification.

---

## Earlier reference (historical geometry below)

Self-contained reference for Kido.app 0.10.1 on macOS 27. The implementation is authoritative: `App/{Sidebar,SidebarView,SidebarRow,WindowTabs}.swift` and `Packages/SidebarFeed/Sources/SidebarFeed/{Rows,Windows}.swift`. The HTML approximates native drawing; it does not replace AppKit.

```sh
open design/sidebar/mockup.html
```

## Evidence and appearance

Updated against `/tmp/kido-visual-macos27/index.html`: paired macOS 26/27 captures of `testSidebarCards.*`, `testFloatingSidebar.collapsed-floating`, `testHostLabel.*`, and `testWindowTabs.*`. Chrome now follows `/tmp/kido-chrome-macos27/{windowed-docked,windowed-collapsed,windowed-floating,fullscreen-docked}{,-crop}.png` and `frames.txt`: real active/key-window captures with measured AppKit frames at 2× backing scale. Fullscreen states also follow `/tmp/kido-fs-probe/kido-{light,dark}-{docked,wide,collapsed,floating,switched,reentered}.png`. Final corner verification uses `/tmp/kido-corners-macos27/{light,dark}-windowed-docked{,-crop}.png` and `{light,dark}-fullscreen-docked-crop.png`: these show the corrected square/edgeless docked sidebar. Their “could not reach Local” message is stopped-test-server content, not a design change. These supersede the initial fullscreen screenshot for toolbar/background geometry. All paths are local review artifacts, not runtime dependencies.

The old/new pairs primarily change native glyph shapes/rasterization, not the approved row geometry or palette. Keep system fonts at the existing point sizes rather than inventing larger sizes or heavier weights. Browser text uses the installed OS system font; CSS line boxes and SVG approximations cannot reproduce NSString/SF Symbol rasterization exactly.

The default preview is Light, with warm terminal/toolbar `#fefaf1` and beige sidebar `#f0ebe2`, approximately sampled from the latest real captures. Windowed light glass has a subtle `#eeece1` top tint fading into the body. Dark approximates the real captures with terminal/toolbar `#192028` and glass `#21272e`. These static colors approximate wallpaper-, theme-, appearance-, and color-profile-dependent materials; they are not new hardcoded AppKit colors. **Visual-test surface** switches the sidebar to white in Light / `#1e1e1e` in Dark, matching isolated `testSidebarCards` captures, while leaving the terminal theme intact. Native tests flatten materials and are not evidence that the live sidebar should be white.

The sidebar has no inset/shadow in docked mode. Default width is 292pt; Width previews also cover the measured 236pt and 320pt variants. Docked glass fills the full sidebar width/height with square corners and no hairline edge, in both windowed and fullscreen modes. The rounded outline visible in the supplied docked captures was a Kido bug and is intentionally not reproduced. Docked glass continues behind the toolbar seamlessly. Only the floating overlay keeps an 18pt rounded card with a 0.5pt labelColor-12% border. Floating mode overlays terminal content; in fullscreen its rounded card begins below the themed toolbar band.

Toolbar controls sit in window-level 52pt chrome. Coordinates below are CSS/AppKit points measured from the top-left, not 2× screenshot pixels. Traffic lights are 14pt, at x=19/42/65, y=19, with 9pt gaps. New Session is hidden in collapsed/floating modes. Toolbar symbols approximate the app's 20pt/small SF Symbol configuration.

| Control | x | y | width × height |
| --- | --- | --- | --- |
| New Session, docked | sidebar width − 86 | 8.5 | 32.5 × 34 |
| Toggle, docked/floating | sidebar width − 42 | 9.5 | 32.5 × 32 |
| Tab host, docked/floating | sidebar width + 8 | 8 | remaining width − 8, × 36 |
| Toggle, windowed collapsed | 142 | 9.5 | 32.5 × 32 |
| Tab host, windowed collapsed | 184 | 8 | remaining width − 8, × 36 |
| Toggle, fullscreen collapsed | 56 | 9.5 | 32.5 × 32 |
| Tab host, fullscreen collapsed | 98 | 8 | remaining width − 8, × 36 |

For 292pt docked: New Session x=206, Toggle x=250, tabs x=300. The header's first row begins at y=54 (52pt safe area + 2pt list inset); heading line box y=60.5; first pane row y=83. Table x=8, width=sidebar width−16. No decorative CSS border consumes layout space. Fullscreen hides traffic lights without inventing new docked/floating button positions.

The tab host is 36pt tall at y=8 within the 52pt toolbar. Tab surfaces stay 28pt tall (4pt inset in the host), 7pt radius, 2pt leading/1pt trailing inset, equal widths clamped to 85–220pt, with 11pt system labels. Active tabs use 7.5% labelColor fill and a 1pt stroke. No hover/press/focus-ring treatment. Fixed remote label: 11pt medium secondary text, 16pt line box centered in the host, 2pt leading inset, up to 166pt text width; total reservation is text width + 25pt, capped at 35% of the strip. Separator sits 11pt before that reservation's end. Offline/reconnecting dim label and separator to 45%; only the alias is a tooltip. Tabs scroll independently.

**Fullscreen background fix is represented, implementation settled; user's final native-app look remains pending.** Docked sidebar glass extends through the 52pt toolbar band, identical to the glass below. The themed band begins only to the right of the sidebar divider. Collapsed and floating fullscreen modes retain the themed band across the entire window; floating glass starts below that band. Width changes, session switches and fullscreen re-entry preserve this boundary. Docked glass has square edges and no outline. Only the floating card has rounded corners and a hairline border. This replaces the previous preview's incorrect cream band over docked glass.

## Proposal: closing, new windows and Connect to Remote Host — awaiting user review

Previewed in the mockup; nothing of this is implemented natively yet.

- **Close confirmation.** Closing a pane or window that still has a running process (running or waiting indicator anywhere in it, descendants included) first shows a standard window-modal alert sheet: app icon, bold 13pt title `Close “name”?`, 11pt message ("A process is still running in this pane. Closing the pane will end it." / "Processes are still running in this window. Closing the window will end them."), then stacked full-width buttons: **Close** (default, blue, Enter) above **Cancel** (Escape). Quiet panes and windows close without asking. The user settled that every path that ends a pane or window goes through this one confirmation: the × buttons, Cmd-W, menu commands, and any other app-issued kill. Closing the native macOS window is not one of them: it only closes that window's control client, the app and every pane keep running, and reopening redials, so it never confirms. Native: NSAlert as a sheet on the window, `.warning` style, Close as the default button, Cancel bound to Escape.
- **Tab status and close buttons.** The tab's status dot moves to the leading side: centered 15pt from the tab surface's leading edge. Hovering the indicator's own 16pt slot (not the rest of the tab) replaces the dot with a 16pt × close button centered on the same point; the dot returns when the pointer leaves the slot, and hovering elsewhere on the tab changes nothing. The label is always inset 26pt on both sides, so neither the dot nor the button changes the label's position or width on hover. Hovering the button only brightens it and adds a faint 4pt-radius fill. Click goes through the confirmation above. No press feedback beyond that. Cmd-W closes the focused pane through the same confirmation.
- **Close buttons on sidebar rows.** Hovering the status indicator's own 16pt slot on a pane row (never a program record, and not the rest of the row) replaces the indicator with the same × button in that slot; elsewhere on the row the indicator stays. Clicking closes that pane (its nested windows with it), via the same confirmation.
- **Tab titles in the sidebar's style.** A tab whose active pane is an agent or agent run shows its name semibold, exactly like the sidebar row, with the display-only @ prefix (not doubled if already present) when that agent can be messaged; shell, run and other tabs stay regular with no @. Window names, identities and tmux data are unchanged.

- **Inline session rename.** Double-clicking a session heading's name edits it in place, Finder-style. The field replaces the label exactly in place: same 11pt semibold font and 18pt line, text starting at the label's x, primary text color on the sidebar background with a hairline edge and the accent focus ring, the whole name selected; the session + does not move and the body below does not shift. Enter or clicking elsewhere commits; Escape cancels. An empty or unchanged name reverts silently. A name tmux would reject (a duplicate of another session, or one containing ":" or ".") keeps the field open and shows the reason under it in 10pt red ("A session named “x” already exists." / "Session names can’t contain “:” or “.”."), the heading growing to fit; editing again clears the error. A single click still does what it does today (nothing on the label). Native: an NSTextField swapped into the header cell on double-click, committed through rename-session, with tmux's refusal shown as the inline error rather than an alert. The preview changes only its own data.

- **Tab status marks by sidebar mode.** A top-level tab carries one mark, combined from all its panes and nested child windows in the order error (stalled included) > waiting > running > done > quiet, where a done pane counts only while its outcome is unseen. The mark is the sidebar row's own indicator (6pt dot, or the green check) in the tab's 16pt leading slot, which the hover × still replaces; quiet shows nothing and the 26pt label inset never changes. Docked sidebar: red and orange only, as today, because the sidebar rows already show the rest. Collapsed or floating sidebar: running (green dot) and unseen done (green check) appear as well. Accessibility labels take the suffix of the shown mark only: " — error", " — waiting", " — running", " — done". Tabs cover only the current session; other sessions have no indicator. The "Tab status marks" panel under the window renders the same tab strip docked and collapsed/floating, light and dark, from the current fixture. The preview has no seen state for done rows, so every done row counts as unseen there.

- **New window button.** A 28pt-wide, icon-only + at the trailing end of the tab strip, outside the scrolling tabs, hover brightening only like the session plus. It opens a new shell window in the current session and focuses it.
- **Connect to Remote Host (redesigned).** A 440pt window-modal sheet: bold title, one-line lead ("Opens a new window attached to the host's kido server over SSH."), a **Host:** field (user@hostname or SSH alias, 11pt help line "Uses your SSH configuration, keys and known hosts."), then a bordered **Recent** list (132pt tall, 24pt rows, host plus a relative time, alternating row fill, blue selection). Clicking a recent host fills the field; double-clicking connects. Buttons: **Clear Recent** on the left (disabled when the list is empty, which shows "No recent hosts"), **Cancel** and the default **Connect** on the right; Enter connects, Escape cancels. Connecting records or refreshes the host in the recent list. The preview stores the list in browser localStorage and opens the sheet from the **Connect to Remote Host…** control above the window; natively it is the Spotlight/Shortcuts action's window or a menu command, and the recent list lives in app preferences. SSH's own checks still apply; the dialog never bypasses them.

## OSC 7501 child records — shipped

The default **Claude Code · child records** fixture shows program records below their owning pane, before selectable child windows: three working Claude Code subagents (one with a caption) and a nested blocked permission record. Like `lib/sidebar.ml` / `lib/ui.ml`: exclude the root id, order ids lexicographically by slash components (bytewise UTF-8), indent by component count even if intermediate records are absent, fall back to the full id for an empty title, show msg as the activity line. State mapping: working→running, blocked→waiting (orange), error→failed (red), done→done (green check), idle→gray. Visiting the parent pane (by row or tab) acknowledges done/error for that pane's serial; records stay, working/blocked stay visible, and a newer serial restores completion/error indicators. Everything else about a record's appearance is in the redesign draft above: it is an agent row.

## Approved sidebar geometry

Sessions are plain noninteractive 11pt semibold secondary labels in 29pt headers, followed by windows; no session card or folding. Label line-box y=6.5pt. The trailing 11pt plus (matching the 11pt heading type) creates a new window (preview placeholder), with icon-only hover and center aligned to status circles, 15pt from the item's right edge. Session bottom gap is 16pt. The scrolling list has 8pt horizontal insets, 2pt top and 10pt bottom space.

Each window is one 7pt-rounded item containing its pane rows and their descendants. Active window gets continuous 10% labelColor fill, including all nested descendants. Focusing a child highlights its own subtree, not ancestors. Single-pane windows need no extra focus mark; multi-pane windows retain a 2pt leading mark with the row's vertical padding as its inset (85% white dark / 75% black light). Keyboard selection independently adds 10% fill and clears on mouse interaction.

Render children immediately after their owning pane, before the next sibling pane. Indent 16pt per level, no guides. Window bottom spacing is 3pt, with an additional 3pt after a pane's children, matching the native rows. Top-level windows alone have separators BETWEEN windows: 7pt row, centered 1pt line, 12pt end insets, 7.5% labelColor. No nested dividers, no divider before the session's first window, none between panes of one window.

| Window kind | One-line height | Activity height | Top padding | Activity y |
| --- | --- | --- | --- | --- |
| Top-level single | 32pt | 44pt | 7pt | 25.5pt |
| Top-level multi | 30pt | 42pt | 6pt | 24.5pt |
| Nested single | 28pt | 40pt | 5pt | 22.5pt |
| Nested multi | 26pt | 38pt | 4pt | 21.5pt |

Superseded by the redesign draft above for titles, insets and the leading slot. Still true: activity is 11pt on a 15pt line box, aligned with the title at x=36pt plus nesting; trailing inset 12pt; clocks are 10pt tabular digits on the first line.

No leading icons (superseded; see the redesign draft above). Agent display names get `@` without doubling it; feed identities and tmux tab names are unchanged. Quiet shell panes show dimmed **Terminal**, retaining completion/failure statuses: match native Rows.swift exactly (kind shell, no run, indicator idle/done/failed). Unintegrated/unknown and running shells retain their original titles.

Statuses: idle gray dot; running/compacting green dot; done and gone/completed the same plain green check; waiting for input orange dot; failure and stalled the same red dot (no separate stalled glyph). The feed's attention flag also includes completion and must not itself select orange. Dots are 6pt; the check is the same 2pt-stroked path in HTML and in the app, so the two render identically.

## Interaction and fixtures

Arrow keys/j/k navigate, Enter focuses a pane, Escape returns focus to the pane. Session/window creation and terminal content are placeholders. Captured timestamps are historical, not a live feed connection. Fixtures include nested multi-pane windows, long titles, waiting/stalled/failure/completion, SSH/shells, and orphaned windows. Preview selectors cover Light/Dark, docked/collapsed/floating, fullscreen, widths 236/292/320pt, live/flattened material, local/remote/long host and connection state.

Tabs restore each window's remembered active pane. Names/existence/order come from simulated tmux inventory; hierarchy and error/request status come from the last snapshot. Descendants select their nearest surviving ancestor's tab; orphan windows get their own. Error (including stalled, which maps to error) wins over input requests; completion/running/idle add no tab dot. Cmd-1…9 follows tab order, clamping out-of-range numbers to the final tab.

Remote entry remains Spotlight/Shortcuts **Connect to Remote Host in Kido**, with Host input and a separate window per request. No in-app picker or Recent Connections. Titles are Session locally, user@host / Session remotely; the native title is hidden, with the host identity displayed beside tabs.

## Final capture review

Re-reviewed native light/dark corner-fixed crops and the earlier populated chrome/fullscreen references against a rendered Chrome preview, including a temporary matching single-window `main`/`zsh` fixture at 900×560. Corrected remaining small differences: traffic lights had flat colors instead of the native shaded treatment; pane SVGs had excess internal whitespace; tab strokes sat entirely outside rather than centered on the path; title truncation differed by 1pt without a clock and 2pt with one; the last window's 3pt gap could collapse into the session's 16pt gap (the body now establishes a flow root).

Browser-measured coordinates match frames.txt: traffic lights (19/42/65,19), New Session (206,8.5,32.5,34), Toggle (250,9.5,32.5,32), tab host (300,8,…,36), first heading (8,54,276,29), first pane (8,83,276,32). Windowed collapsed Toggle/tabs x=142/184; fullscreen collapsed x=56/98. Docked has no border pseudo-element; floating retains its 18pt outline below the 52pt band in fullscreen. CSS 0.5pt borders are one physical pixel at native 2× backing scale; a 1× browser can round them to a full CSS pixel. Exact native rasterization/material equivalence is not claimed.

## Limitations

- Native glass, font metrics, SF Symbols and color management cannot be exactly reproduced by HTML; compare against the real app for final visual decisions.
- `started` is nullable; retained completion runtime requires an end timestamp/duration.
- `tail` is generic display text, not a distinct set_status field.
- No pi/Claude provider field or separate monitor kind; monitors use stream runs.
- Independent subtree folding is not implemented; sessions are plain labels.
- Fullscreen background implementation is settled and reflected; final native-app user review is pending.
