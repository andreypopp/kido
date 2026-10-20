# Shift-hover: paragraphs, questions and answer options — proposal

`mockup.html` is a self-contained reference for the Kido.app feature where holding Shift over a pane treats the text under the pointer as blocks, the on-device model decides whether the hovered block is a question, and its answer options become clickable spans. Open it from any static server (for example `python3 -m http.server 8765` in `app/design/`), no network access. The code is the source of truth once built; the prototype this follows is `ParagraphsView.swift` (uncommitted).

Controls: State (live, or one of the numbered states for screenshots), Analysing effect (the proposed shimmer, or the pulse alternative) and Theme. In **Live** hold Shift, move over a block, wait for the simulated analysis (1.4 s) and click an option; a second narrow pane shows wrapped spans and a block that starts above the viewport. The panel under the window shows the exact text that a click sends. The gallery at the bottom repeats the core states in the other theme.

## 1. Blocks and geometry

- A block is a run of consecutive non-blank rows; soft-wrapped rows join their row without a newline; list items belong to the block they follow. This matches `Paragraphs.partition`.
- **Block rect**: from the block's first row to its last, from the smallest leading column to the widest trimmed last column, in cell units (`paragraphRect`). Drawn inset by −3pt horizontally and −1pt vertically, radius 4pt.
- **Option rect**: one rect per row segment of the located span, inset −2pt horizontally, exactly the row height vertically, radius 3pt. A span that wraps onto a continuation row or a list item that wraps gets two or more rects; every segment of one option highlights, hovers and flashes together. Each segment is fully rounded; no joined corners across rows (they are on different rows, so a joined look reads wrong).
- Row geometry in the mockup: 7.2pt cells, 21.6pt rows, 20pt/14pt pane insets. The real values come from Ghostty's cell size and the render insets.

## 2. Colors (theme-relative)

`fg` is the pane's terminal foreground (`runtime.foreground`), `accent` is `controlAccentColor`, green/red are `systemGreen`/`systemRed`. Fills never cover legibility: the strongest fill over text is 30%.

| Element | Fill | Edge (1pt) |
|---|---|---|
| Block, analysing | none | fg 10% |
| Block, analysed question | fg 5% | fg 12% |
| Option | accent 16% | accent 65% |
| Option hovered | accent 30% | accent 90% |
| Option sent | green 30% | green 90% |
| Option failed / no agent | red 30% | red 90% |

Captions (the only non-overlay element): 10pt system font on a 16pt pill, radius 5pt, 6pt horizontal padding, placed 8pt after the end of the option's last segment, vertically centered on that row; when it would not fit before the pane's right edge minus 8pt, it goes under the segment's left edge, 3pt below the row. Styles: neutral caption `muted` text on bg mixed 20% toward fg with a 0.5pt fg-14% edge; error caption white on systemRed; success caption white on systemGreen.

## 3. States

1. **Hover, analysing.** The block rect appears at once (edge only, fg 10%) and the analysing effect runs until the result arrives. The 150 ms hover debounce of the prototype stays, so moving across blocks does not start requests; the rect itself appears without delay because it is cheap.
   - **Proposed effect: shimmer sweep.** A soft diagonal band of light (fg at 9%, 100° angle, about a quarter of the block wide, feathered) sweeps from right to left across the block once every 1.6 s, ease-in-out, repeating. It reads as "scanning the text" and is calm: low contrast, slow, no edge movement. Native: a `CAGradientLayer` with the block's rounded path as its `mask`, `colors` [clear, fg 9%, clear], `locations` about [0.38, 0.5, 0.62], animated with a `CABasicAnimation` on `startPoint`/`endPoint` (or on `locations`), `repeatCount = .infinity`; Core Animation composites it, there is no per-frame drawing. Remove the layer when the result arrives or the hover ends; respect `NSWorkspace.accessibilityDisplayShouldReduceMotion` by falling back to the pulse at a slower rate.
   - **Alternative: outline pulse.** The edge breathes between fg 10% at 1pt and fg 28% at 1.5pt over 1.2 s, ease-in-out. Also a layer animation (on `borderColor`/`borderWidth` of a `CAShapeLayer` or a plain layer with `cornerRadius`). Calmer but easier to miss on a large block; the shimmer is the recommendation.
2. **Analysed, question with options.** Block fill fg 5% / edge 12%; option rects as in the table; the pointing hand over any option segment, I-beam elsewhere in the pane while Shift is held. Inline options ("update the docs" / "keep the change to the code only") use the same rects as list options, with the list marker never inside the rect (`stripMarkers`).
3. **Question, no options located.** The block stays highlighted at the analysed level (fill 5%) and a neutral caption **"No answer options found"** sits after the last row. The user sees that the model did recognise a question and that nothing is clickable; nothing is sent on click.
4. **Not a question.** The analysing effect ends and the block rect fades out over 120 ms. Nothing stays: an idle highlight would suggest something to click, and the absence is itself the answer. Moving the pointer out and back in does not re-request while the block's text is unchanged (cache the result for the block text while Shift is held).
5. **Sent / failed / no agent.** Sent: the clicked option turns green for 1 s with the caption "Sent to @name" (the resolved target), then returns to the normal option style; the block stays, so the user can send another option. Not delivered: the option turns red and stays red while the caption "Not delivered: <kido message>" is shown; the red clears on the next hover change or after 4 s. No agent: red option with "No agent in this window or session"; same clearing. Only the clicked option changes; the others keep their style and remain clickable. During the send the clicked option shows the hovered style; no spinner (delivery is fast; the result state follows).
6. **Wrapped spans and list lines.** One rect per segment, see section 1. **Block partly scrolled off:** the block rect is drawn clipped to the viewport with its cut edge straight (no top corners when the block continues above, no bottom corners when it continues below); the shimmer and the fill clip with it. Options that are fully outside the viewport are not drawn and not clickable; the payload still quotes the whole block as the model saw it (the rows the app read, which are the viewport rows, so a scrolled-off block is quoted from its visible rows only; see open question 3).
7. **Shift released mid-analysis.** Every overlay disappears at once (no fade), the pending request is cancelled or its result dropped, the cursor returns to the arrow/I-beam the pane had. **Hover moves to another block mid-analysis:** the first block's rect is removed, the new block gets its rect and effect immediately, the first request's result is dropped when it arrives (the prototype's `hovered?.text == text` guard). Leaving the pane clears everything like a release.

Shift with any other modifier, or a Shift-click selection, does not enter the mode; the mode starts on Shift-down with no other modifier and ends on Shift-up, focus loss or the pane losing the pointer.

## 4. Cursor

Pointing hand over an option segment, I-beam over the rest of the pane while Shift is held (the pane's normal cursor), arrow when the pointer leaves the pane. No cursor change during analysing.

## 5. Payload

Exactly what the prototype sends, through the prompt RPC to the nearest agent (a resolve request first, then the first candidate in the pane's window, else the first candidate):

```
> <each line of the block>

<option text without list marker>
```

The block lines are the block text split on its newlines (wrapped rows already joined), each prefixed by `> `. The option text is the located span with list markers removed.

## 6. Answers to the open questions

1. **What the hovered block shows when it is not a question:** nothing after the analysis; the rect fades out (state 4). While analysing, every block shows the rect plus the effect.
2. **Effect choice:** shimmer sweep, with the outline pulse as the reduce-motion fallback.
3. **A block cut by the viewport:** the overlay clips at the viewport edge with a straight cut; the quoted text covers the rows the app read. If the implementation reads scrollback rows beyond the viewport for the block, the quote should include them; the mockup assumes it does not.
4. **Failure captions:** the failure reason is shown next to the option (the user needs to know whether to retry), success is a brief green flash with the target's name. Captions are the only element that is not an overlay on cells; they never cover the block's own text because they sit after the row's end or under it.
5. **Not covered here:** keyboard access (the feature is pointer-driven by definition) and VoiceOver (no accessible elements are proposed for the overlays).
