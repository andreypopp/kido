# Sidebar reference — macOS 27

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

## Proposal: OSC 7501 display-only child records — awaiting user review

The default **Claude Code · child records** fixture proposes program records below their owning pane, before selectable child windows. It contains three working Claude Code subagents (one with a caption) and a nested blocked permission record. Records are not panes: no leading agent/terminal icon, no @ prefix, no clock, no button role, no tab stop, no click handler, no hover/selection/focus fill. Their smaller secondary text distinguishes them from 12pt, icon-bearing selectable child-window rows. They remain inside the owning window's continuous active fill; they never create another rounded window group or independent highlight.

| Property | Proposed geometry |
| --- | --- |
| Single line / with caption | 24pt / 39pt |
| Title | 11pt regular secondary, 16pt line box |
| Caption | 10pt regular secondary, 14pt line box, 1pt below title |
| Vertical inset | 4pt top/bottom |
| First record title | owning pane title + 12pt |
| Each additional slash component | +12pt (child windows remain +16pt) |
| Status | existing 6pt dot / check symbol, centered 15pt from group right edge |
| Separation after records | 3pt when records end the window; ordinary child-window spacing otherwise |

Like `lib/sidebar.ml` / `lib/ui.ml` at kido main 2e8acae6: exclude the root id, order ids lexicographically by slash components (bytewise UTF-8), indent by component count even if intermediate records are absent, fall back to full id for empty title, and show msg as caption. Program rows precede child windows. Unlike the TUI's character tree branches, the AppKit proposal preserves this sidebar's existing no-guide treatment.

State mapping: working→green, blocked→orange, error→red, done→green check, idle→no indicator. Visiting the parent pane (by row or tab) acknowledges done/error for that pane's serial; records/captions remain, working/blocked stay visible, and a newer serial restores completion/error indicators. Preview acknowledgement state is separate from feed data, mirroring the per-view model. Fixtures retain raw program_status records; no extra feed field is needed. Existing mock parent indicators are static fixture data, not a full recomputation of kido's representative status algorithm.

**Not approved or implementation-ready yet.** Review especially the 12pt record indent, icon omission, secondary typography, and how records share the active-window fill. No Swift implementation changes are requested until the user settles this proposal.

## Approved sidebar geometry

Sessions are plain noninteractive 11pt semibold secondary labels in 29pt headers, followed by windows; no session card or folding. Label line-box y=6.5pt. The trailing 13pt plus creates a new window (preview placeholder), with icon-only hover and center aligned to status circles, 15pt from the item's right edge. Session bottom gap is 16pt. The scrolling list has 8pt horizontal insets, 2pt top and 10pt bottom space.

Each window is one 7pt-rounded item containing its pane rows and their descendants. Active window gets continuous 10% labelColor fill, including all nested descendants. Focusing a child highlights its own subtree, not ancestors. Single-pane windows need no extra focus mark; multi-pane windows retain a 2pt leading mark with the row's vertical padding as its inset (85% white dark / 75% black light). Keyboard selection independently adds 10% fill and clears on mouse interaction.

Render children immediately after their owning pane, before the next sibling pane. Indent 16pt per level, no guides. Window bottom spacing is 3pt, with an additional 3pt after a pane's children, matching the native rows. Top-level windows alone have separators BETWEEN windows: 7pt row, centered 1pt line, 12pt end insets, 7.5% labelColor. No nested dividers, no divider before the session's first window, none between panes of one window.

| Window kind | One-line height | Activity height | Top padding | Activity y |
| --- | --- | --- | --- | --- |
| Top-level single | 32pt | 44pt | 7pt | 25.5pt |
| Top-level multi | 30pt | 42pt | 6pt | 24.5pt |
| Nested single | 28pt | 40pt | 5pt | 22.5pt |
| Nested multi | 26pt | 38pt | 4pt | 21.5pt |

These activity positions/heights were approved by eye in AppKit and remain unchanged on macOS 27. Titles: 13pt top-level / 12pt nested, 18pt line box. Activity: 11pt, 15pt line box. Leading inset 12pt top-level / 8pt nested, 16pt monochrome icon then 8pt gap. Activity aligns with title at x=36pt / 32pt. Trailing inset stays 12pt; clocks are 10pt tabular digits on the first line.

Exactly two leading icon types: `text.bubble` for agents/agent-runs, `terminal` otherwise. The preview uses inline vectors, not embedded SF Symbols. Agent display names get `@` without doubling it; feed identities and tmux tab names are unchanged. Quiet shell panes show dimmed **Terminal**, retaining completion/failure statuses: match native Rows.swift exactly (kind shell, no run, indicator idle/done/failed). Unintegrated/unknown and running shells retain their original titles.

Statuses remain: idle absent; running/compacting green dot; done and gone/completed the same green check; waiting for input orange dot; failure red dot; stalled red exclamation. The feed's attention flag also includes completion and must not itself select orange. Dots are 6pt; native check/exclamation symbols use 10pt bold configurations drawn in a 12pt box. Checks/exclamation strokes in HTML remain approximations.

## Interaction and fixtures

Arrow keys/j/k navigate, Enter focuses a pane, / reveals filtering, Escape clears it. Session/window creation and terminal content are placeholders. Captured timestamps are historical, not a live feed connection. Fixtures include nested multi-pane windows, long titles, waiting/stalled/failure/completion, SSH/shells, and orphaned windows. Preview selectors cover Light/Dark, docked/collapsed/floating, fullscreen, widths 236/292/320pt, live/flattened material, local/remote/long host and connection state.

Tabs restore each window's remembered active pane. Names/existence/order come from simulated tmux inventory; hierarchy and error/request status come from the last unfiltered snapshot, so filtering does not change tabs. Descendants select their nearest surviving ancestor's tab; orphan windows get their own. Error wins over input requests; completion/running/idle/stalled add no tab dot. Cmd-1…9 follows tab order, clamping out-of-range numbers to the final tab.

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
