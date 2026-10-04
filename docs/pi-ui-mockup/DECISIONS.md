# Pi surface design session

## Starting constraints
- Interactive design with Andrey; HTML exploration only, no Swift implementation.
- Embedded pane, no private window toolbar or duplicated Kido sidebar.
- Standard macOS 26 components and semantic colors; light/dark and ~440pt narrow panes.
- Keep reading layout stable during streaming; avoid per-token heavyweight layout.
- Only synthetic sample content in the mockup; do not copy private captures.

## Directions proposed (not yet selected)
1. Quiet conversation: readable prose, softly filled user prompts, compact tool disclosures, composer-contained controls.
2. Work journal: tighter leading layout with a subtle execution rail and Xcode-like commands/diffs.
3. Conversation + activity: prose-first with consecutive tool calls in expandable activity groups.

These were superseded by Andrey's direction below.

## Selected direction — minimal session journal
Andrey requested:
- Session journal above, composer below, one-line model/context status below the composer.
- Confirmed: the model picker belongs in the status bar, not the composer toolbar. The mockup's model label is its clickable trigger; the final design will show its menu interaction there.
- Flat composer separated from the journal by a rule, not a rounded standalone card. Host pane geometry decides whether the bottom is rounded.
- Single-line text input that grows with additional lines, plus attach, microphone, and send toolbar actions.
- Latest exploration requested by Andrey: the empty/short composer is a single row, input on the left and all buttons on the right. Once the draft wraps or contains a newline, input gets the full width and buttons sit right-aligned on a second row below. It returns to single-row when text fits again. Mockup uses 10pt vertical / 12pt horizontal composer padding, 28pt controls and a 10pt text/control gap. Longer drafts keep growing to a bounded editor height.
- Group tool calls and thinking into one activity summary, preserving chronological runs: `thinking, bash ×3, codemode, bash ×2, thinking, codemode, bash 43s`.
- Confirmed revision: collapsed activity truncates the preceding history with an ellipsis before the active last item. The active tool name and duration remain fully visible, including in narrow panes. When inactive, the whole summary can truncate normally.
- Click expands activity into one line per tool/thinking block. Thinking shows its first line; tools show command/code preview and duration. Active tool shows its latest three output lines.
- Confirmed revision: scrolling away from the live end shows a small bottom-centered pill in the journal, labeled `to recent messages`. Clicking returns to the live end and resumes following; hide at the live end. Mockup uses a 48pt bottom proximity threshold. Pill overlays the journal only, never the composer. Preview starts at the recent end.
- User input and agent output render markdown; agent text streams.
- Include compaction/service messages and warnings.

## First mockup — 1
- Implemented the selected structure in index.html, with both collapsed and expanded examples and synthetic coding content.
- Preview-only controls outside the pane switch light/dark, 440pt/wide, host-rounded bottom, and running/idle.
- Confirmed revision: no `You` label. User messages are distinguished by a quiet background tint, no border, and 8pt rounded corners (subsequently requested by Andrey). Applied to sample and newly submitted preview messages.
- Confirmed revision: compact journal insets at all widths, no centered/max-width reading lane. Mockup uses 12pt journal inset and full available width; user tint has 9pt vertical / 10pt horizontal padding.
- Provisional typography: 14pt prose, 12pt activity, 11pt status. No activity boxes.
- Confirmed revision: the trailing composer action swaps Send → Stop while running, never shows both. Return can still submit steering text while running; the visible trailing button stops work.
- Durations are synthetic static examples. Implementation must use available timing or observe live start/end, never invent historical timing.
- Attach opens a browser file chooser; mic and model actions are labeled placeholders, not real integrations. Voice capture/transcription is not present in the existing pi RPC contract and needs separate implementation scope.
- Dynamic preview submission preserves literal draft text; the static sample demonstrates markdown. Production user messages must render markdown as requested.

## Composer growth correction
Andrey noticed wrapping did not resize the input. Browser inspection reproduced a multiline draft with 63pt scroll height but 21pt visible height: flex sizing was compressing the editor. Disabled flex sizing for the multiline editor. Verified in the browser that wrapping grows to 63pt and a short draft returns to 21pt/single-row.

## Pending user-message treatment
Andrey rejected the conversational right-aligned/inset option because it wastes space. Keep user messages full-width. Applied a 3pt accent leading edge and medium-weight prose alongside the existing rounded tint. Andrey approved the current design and requested handoff.

## Handoff
Andrey: “ok, good, please handoff to parent”. Final implementable mapping is in `SPEC.md`. Mockup remains in `index.html`. No Swift implementation or git writes performed. Mic/transcription, full model menu, attachment transmission and expanded per-tool detail interactions remain implementation scope, not working HTML integrations.

## Reference observations
Current screenshots show weak turn separation, tool details competing with prose, broad empty output areas, and composer controls that read as a settings form. The redesign must establish hierarchy rather than just restyle borders. Static mockups cannot demonstrate runtime responsiveness; performance requirements remain separate.

## Implementation alignment
The implemented Swift surface supersedes provisional controls and timings above:
- Removed microphone; attachment chooser accepts multiple PNG/JPEG/GIF/WebP images and shows an image count.
- Model selection remains in the status bar; thinking levels are in its context menu, not the model menu.
- No activity durations: pi supplies no timing. Summaries preserve consecutive runs and the active tool name.
- Context usage is shown only with reported usage and a known context window.
- Native borderless composer actions, semantic fills, 12pt status inset, and compact body typography replace provisional styling.
- Expansion grows downward and stops live following; history loading appears only when older history exists. Recent-message navigation resumes following.
- The committed preview is synthetic; screenshots were used only for visual comparison.
