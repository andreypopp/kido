# koa — the webview harness, reference mockup

`mockup.html` beside this file is self-contained: inline CSS and JS,
no network. Open it from a static server (`python3 -m http.server`
in `app/design`) and use the two controls: theme (kido-light,
kido-dark) and pane width (980pt, or 60 terminal cells). Each
numbered section is one state of the page, rendered inside a frame
that stands for the pane's content area. Click a run line or a step
line to fold or unfold it.

Status: reviewed by the user on 2026-11-08. Decided: prose in the
system font; a failed run stays collapsed; the status bar at the
bottom; the context bar always shows; a user message carries a
timestamp (below, "The transcript").

## Rules the page follows

- **Only `--ko-*`.** The page's colours are `--ko-bg`, `--ko-fg`,
  `--ko-cursor` and the palette (`--ko-color-N`), and every other
  tone is a `color-mix` of them: muted text 55% fg, faint 35%,
  hairlines 12% and 18%, wells 5% and 8%. The accent is palette 4
  (blue), ok is 2, error is 1, warning is 3, so a theme's own palette
  colours the page. The `:root` block at the top of the mockup is the
  browser fallback, kido-light and kido-dark copied from
  `app/Resources/ghostty/themes`; in Kido.app the properties the app
  sets override it, and `prefers-color-scheme` is not consulted.
- **Two fonts.** Prose (user and assistant text, thinking, the
  composer's text) is the system font at `--ko-font-size`, line
  height 1.6. Everything that is a terminal fact is the terminal font
  (`--ko-font-family`): code, the run and step lines, diffs, bash
  output, the composer's footer hints and the status bar.
- **No header.** The pane's sidebar row and the title tabs already
  name the agent and its session. The page is transcript, composer,
  status bar, nothing above.
- **No chrome of its own.** No borders around messages, no avatars,
  no bubbles. A user message is a 2pt left bar in the accent colour.
  An assistant message is plain prose. Hairlines separate only the
  status bar.

## The transcript

- Content column: 720pt wide, centred, 14pt top and 20pt side
  padding (22/24 before 2026-11-09). In the narrow pane it is fluid
  with 12pt sides.
- An empty session shows nothing: the paper, the composer and the
  status bar, no wordmark or "nothing yet" text (user, 2026-11-09;
  the earlier centred empty state is gone).
- Markdown: headings in the prose font, 1.3/1.15/1em, 600 weight;
  lists with muted markers; inline code in an 8% well with 4pt
  corners; code blocks in a 5% well with a 12% hairline, 7pt corners,
  the language as a faint label at the top right; tables with a
  hairline under each row, uppercase muted header cells, no vertical
  lines; blockquotes with an 18% left bar.
- A user message's timestamp (user, 2026-11-08): the time of sending
  at the right of the message's first line, terminal font at 80%,
  faint, tabular digits, 14pt after the text, never wrapping; the
  text wraps in the remaining width. Form: `14:32` (local, 24-hour)
  for today, `Nov 7 14:32` for an earlier day, `2025 Nov 7 14:32` for
  an earlier year. A `<time datetime>` element, so it is machine
  readable. Assistant messages and runs carry no timestamp; the run
  has its elapsed time.
- Streaming: the text appears as it arrives; a 2pt caret in
  `--ko-cursor` blinks at the end of the streamed text (1s, steps).
  The transcript stays scrolled to the bottom while it streams and
  stops following when the user scrolls up.

## The run

A run is every consecutive thinking block and tool call between two
assistant texts (or between the user's message and the first text).

- **Collapsed** (default): one terminal-font line, muted. A chevron,
  then the summary, then the elapsed time at the right. While running
  the summary is a gray spinner (hairline ring, muted arc; no accent
  colour) and the running label in regular weight, muted ("⟳ make
  cargo …"; no word "running"); done, it is the tools by name in the
  muted tone ("thinking, read, edit, bash"; "bash x2" when one ran
  twice). A failed run colours the failed tool's name red; an aborted one
  reads "aborted, you pressed Escape" in the muted tone. No icon.
- **Expanded to lines**: the steps, indented 18pt, with a 12% hairline
  guide under the run line's chevron (4pt from the run's left edge;
  user, 2026-11-09). One line per step: the action name in muted (bash, read, edit, write; a generic tool
  is its own name; a thinking block reads "thinking"), then
  (`$` bash, `✎` edit, `◇` read, `∴` thinking), the command or path
  in the fg colour, the step's own detail in faint (`+5 −1`, `212
  lines`, the thinking's first words), and the result at the right:
  green ✓ with the time, red `exit N` with the time, or `aborted`.
  Summaries ellipsize before the time; the time never wraps.
- **Expanded to details**: bash shows `cwd` and the output in a well,
  cut to 260pt and scrollable; an edit shows the file name in a
  header bar and a diff with added lines on a 12% green tint and
  removed lines on an 11% red tint, markers in the margin; thinking
  shows the full text as muted prose, 260pt cut and scrollable.
- Fold state is per run and per step, kept while the session is open.
  A run that is running stays collapsed unless the user opened it.

## The composer

- A 9pt-radius field with an 18% hairline, 9pt 12pt padding. Focused:
  the hairline darkens to 40%. The text grows to six lines and then
  scrolls.
- **One button**, at the bottom right inside the field, light
  weight (user, 2026-11-09, after two heavier forms): a 26pt square
  hit area with no fill, no border and no text, only a 15pt icon at a
  1.6pt stroke. Send is a right arrow in the accent colour while the
  field has text, and in the faint tone (fg 35%), inert, while it is
  empty. While koa works the same spot holds stop: a filled 8pt
  rounded square in the muted tone, red on hover. Hover on a live
  button is the 8% well behind the icon (7pt radius), nothing else.
  Clicking send sends (a steer while
  koa works), clicking stop aborts. No pill, no labelled button, no
  circle (user, 2026-11-08: the text pill, the `↩ send` label and a
  round button were each rejected).
- The key hints are faint terminal-font text at the left of the same
  line, shown only while the field is focused or koa works: `⇧↩
  newline` with text present, `↩ steers while koa works` while it
  works. The send key is not spelled out; the button says it.
- Placeholder "Message koa…"; while koa works, "Steer koa…".
- **While the agent works** the field stays editable and a thin accent
  sweep runs along its top edge. Escape anywhere on the page aborts;
  a second Escape clears the field.

## The status bar, one line

24pt, terminal font at 82%, a 12% hairline above. Segments left to
right, separated by hairlines:

1. state: a 6pt dot and a word — gray "idle", green "working 12s",
   orange "waiting for you", gray "aborted";
2. the model, then "· thinking high" (muted);
3. context: a 44pt bar (18% track, faint fill; warning colour over
   75%), the exact "84k / 200k" in faint, and the percent;
4. a flexible gap;
5. the cwd with its last component in the fg colour (no git branch
   and no dirty mark: user, 2026-11-09).

In the narrow pane the thinking label, the exact token numbers and
the cwd's leading directories go first; the bar, the percent, the
model, the state and `kido` stay.

## The narrow pane (60 cells)

Same page. The transcript column loses its centring margin, tables
and code blocks scroll inside their block, run summaries ellipsize,
the status bar drops the segments above. Nothing hides otherwise.

## What the page needs from koa

- The session as items: user text, assistant text (streaming deltas),
  thinking blocks, tool calls with their arguments, start and end
  times, result or error, and an abort marker.
- For each tool a one-line summary rule: bash → the command; edit →
  the path and the line counts; read → the path and the line count;
  anything else → the tool name and its first argument.
- The status facts: model, thinking level, context tokens used and
  the limit, cwd, and the run state with its start time.
- Steer and abort as requests from the page.

## Decisions (user, 2026-11-08)

1. Prose in the system font; terminal facts in the terminal font.
2. A finished run stays collapsed, also after a failure.
3. The status bar is at the bottom, under the composer.
4. The context bar always shows.
5. A user message carries a timestamp, no label.

Decisions, 2026-11-09 (the feedback round below): run and step
lines in the prose font; compact spacing; the composer floats over
the transcript on glass, the status bar stays a band; the composer
button is icon-only with no fill; an empty session shows nothing.
The user approved the round as shown ("much better, let's go with
that"), with the user message as A, the gray block, which the mockup
showed; B and C stay in the control for reference.

## Dialogs from extensions (unit 5)

pi's extension UI requests (`select`, `confirm`, `input`, `editor`)
are one card above the composer, in the content column: a 9pt
radius, the 18% hairline, 11pt 12pt padding. The title is 600
weight; the message, when there is one, muted under it. A request
with a timeout shows the seconds left in the terminal font at the
right of the title and a 2pt accent fuse along the card's top edge
that shrinks to zero; at zero the request is cancelled as pi does.
The buttons sit at the bottom right, secondary (hairline) then
primary (accent fill): Cancel / Select, No / Yes, Cancel / Submit,
each with its key in a faint kbd. The hint at the bottom left is
the terminal font at 80%.

- `select`: the options as rows, the current one filled (8% well)
  with a `›` in the accent colour; an option's description, when pi
  gives one, muted after it. ↑↓ move, ↩ selects, ⎋ cancels, a digit
  jumps.
- `confirm`: no field. ↩ is Yes, ⎋ is No.
- `input`: one line in a 7pt-radius hairline field, focused on
  arrival, prefilled when pi says so. ↩ submits, ⎋ cancels.
- `editor`: the same field at four lines, growing to ten; ↩ and ⇧↩
  are newlines (the text is multi-line), ⌃↩ submits, ⎋ cancels. Not
  ⌘↩: every Command key goes to Kido's menu first (⇧⌘↩ is Zoom Pane,
  ⌘↩ is unused today, but the page should not depend on that), and
  ⌃↩ has no Cocoa text binding.

One card at a time, in request order. A second queued request is a
one-line note under the card, "+1 queued · its title", and takes
the card when the first is answered. While a card is up the composer
stays visible, inert (the field keeps its text, the button is off),
the status bar says "waiting for you" with the orange dot, and focus
is in the card; ⎋ in the card cancels the request, not the run.

## The queue while koa works

Steering and follow-up messages that pi holds are listed under the
field, inside the composer column: one line each, a tag in the
terminal font (`steer`, `follow-up`) in a 62pt column, the text
ellipsized. Under them, the count and a "take back ⌥⌫" button, the
hairline button style, no key of its own (⌥⌫ is delete-word in the
field; Tab from the field reaches the button, ↩ or Space presses
it): it calls pi's `clear_queue` and puts every message into the
composer, each on its own paragraph in queue order, caret at the
end, the queue line gone. The composer's own hint line stays as it
is while working (↩ steers, ⌥↩ queues a follow-up).

## The model and thinking pickers

A click on the model segment or the thinking segment of the status
bar opens a popover above that segment. The two segments are
buttons: Tab from the composer reaches them (after the queue's
button when it shows), ↩ or Space opens. No key inside the field
opens them: ⌃M and ⌃T are Cocoa text bindings (newline, transpose)
that WebKit fields honour. The popover is
anchored at the segment's left edge, 30pt above the bar's top, 220pt
minimum, a 9pt radius, the 18% hairline, a soft shadow (fg 14%, 8pt
down, 28pt blur), 6pt padding, the terminal font at 88%. A faint
caption (Model, Thinking), then the rows: a 10pt tick column (✓ in
the accent colour on the current entry), the name, and for a model
the provider faint at the right. The highlighted row is the 8% well.
The bottom hint row reads "↑↓ move · ↩ choose · ⎋ close". While the
popover is up, its segment is filled (8% well, 5pt corners). ↩
applies through pi's `set_model` / `set_thinking_level` and closes;
⎋ closes with no change; a click outside closes. The model list is
what pi reports as available, grouped in pi's order.

## Notifications and extension status in the bar

An extension's `notify` is a toast in the bar's flexible segment:
a 12pt round badge with `i`, `!` or `✕` in the accent, warning or
error colour and the message in the fg colour, ellipsized. It stays
4 s; a newer one replaces it at once; a click dismisses it. An
extension's `setStatus(key, text)` adds a segment, "key text" with
the key faint, between the context segment and the flexible one, in
key order; an empty text removes it. In the narrow pane the
extension segments hide before the toast does.

## pi has exited

When pi exits (a code, or a signal), the transcript stays as it was.
The composer's place holds a card with a hairline in the error
colour at 35%: "pi exited · code N" (or "· signal SIGKILL") in the
title line with the time at the right, the last five lines of pi's
stderr in a muted well cut to 140pt, a faint line that names where
the whole log is, and the primary button "Start pi again"; ↩ presses
it. The stderr lines are the last five koa received; the whole
output is in the pane's terminal (koa writes pi's stderr to its own
stderr and keeps no log file). The status bar's dot turns to the error colour and its word is
"pi exited · code N"; the model, thinking and context segments keep
their last values. A start replaces the card with the composer and
continues the session.

## Times

Every step shows its own time at the right of its line, the thinking
step included (`✓ 6s`); a run's time is from its first step's start
to its last step's end. An aborted run shows its elapsed time like
any other, and its aborted step shows the time it ran before the
abort (`aborted 23s`).

## Keyboard

Everything works without a mouse. Command keys go to Kido first. In
the page: ↩ sends or steers, ⇧↩ newline, ⌥↩ queues a follow-up,
⎋ aborts (twice: clears the field); in a dialog ↑↓ ↩ ⎋ as above, ⌃↩
submits an editor, and ⎋ cancels the dialog, not the run; ↑↓ ↩ ⎋
inside a picker; ↩ on the exit card starts pi again. Tab moves from
the field to the dialog's controls, the queue's button, and the
model and thinking segments, in that order; ↩ or Space presses the
focused one. No Command key and no Control-letter key is bound in
the page: Command keys go to Kido first, Control letters are Cocoa
text bindings.

## Open questions (unit 5)

1. The `editor` submit key: ⌃↩ (mockup) or ↩ with ⇧↩ for newlines
   as in the composer? Recommendation: ⌃↩, because an editor's text
   is multi-line by nature and ↩ as submit loses text; ⌘↩ would go
   to Kido first.
2. Where the queue list sits: under the field (mockup) or above it,
   where the built page has `#queue`? Recommendation: under, so the
   field keeps its place and the queue reads as what follows the
   current message.
3. Pickers from the bar only, or also a `/model` style command in the
   composer? Recommendation: bar and keys only for now.
4. Toast replace or stack? Recommendation: replace; the bar has one
   line, and the log has every message.
5. On exit, start pi again automatically after a crash (code ≠ 0)
   once? Recommendation: no; the card makes the restart one key.

## Feedback round, 2026-11-09 (five notes from the user's first use)

Every value below is in `mockup.html`; the "Composer" and "User
message" controls switch the treatments that need a choice.

### 1. Run and step lines in the system font

The run line, the step lines and the thinking line are the prose
font now; only the glyphs and the code-like parts stay in the
terminal font.

- `.run`: `font: .95em/1.5 var(--prose)`, colour muted (was
  `.92em/1.6 var(--mono)`).
- Terminal font, `.92em`: the chevron and the mark (`›`, `$`, `✎`,
  `◇`, `∴`), a command (`.cmd`), a path (`.path`) and the time at the
  right (`.time`, tabular digits). Everything else in a line (the
  count, "thinking", the tool names, the delta words, "aborted") is
  prose.
- The thinking block's text was prose already; it is `1em/1.5`,
  muted, `white-space: pre-wrap`.

### 2. The thinking block's padding

The space under an expanded thinking block came from three margins
that added up. Now: `.detail{margin:2px 0 4px 20px}`,
`.detail .think{padding:0;margin:0}`, `.detail pre{margin:3px 0 4px}`,
`.diff{margin:3px 0 4px}`. The block ends 4pt above the next step
line, like a command's output well does.

### 3. Compact

| Property | Was | Now |
| --- | --- | --- |
| Pane line height (prose) | 1.6 | 1.5 |
| Transcript padding, wide | 22 24 10 | 14 20 8 |
| Transcript padding, narrow | 16 14 8 | 10 12 6 |
| Gap after a message or a run (`.msg`, `.run` margin-bottom) | 22 | 14 |
| Paragraph gap (`.assistant p`) | .9em | .65em |
| Heading margins | 1.3em 0 .5em | 1em 0 .4em |
| List margin-bottom | .9em | .65em |
| Code block (`pre`) | 1.5 line, 10 12 padding, 1em below | 1.45 line, 8 10 padding, .75em below |
| Run and step line padding, gap | 2 0, 9 | 1 0, 8 |
| Steps indent (`.steps` margin-left, padding-left) | 18, 12 | 17, 11 |
| Step margin | 1 0 | 0 |

The 720pt content column is unchanged: shorter lines read worse,
and the side margins were already the 20pt the narrow pane needs.

### 4. The user message (needs the user's choice)

Three treatments, the "User message" control, all from `--ko-*`:

- **A · gray block (default in the mockup).** `background: var(--well)`
  (fg 5% over bg), `border-radius: 8px`, `padding: 7px 12px`, no bar.
  The timestamp sits at the right inside the block. Reads as "what
  you said" without colour; the accent stays for the working sweep
  and the focus ring.
- **B · accent tint.** The same block with
  `background: color-mix(in srgb, var(--accent) 7%, var(--ko-bg))`.
  Warmer in kido-light (a blue-grey over cream), bluer in kido-dark.
- **C · gray block with the bar.** A, plus `border-left: 2px solid
  var(--accent)`, `border-radius: 0 8px 8px 0`, `padding-left: 12px`.
  The old bar as a hint of "you", on the new block.
- "current" keeps the old bar-only form for comparison.

Chosen: A (user, 2026-11-09, as the default the mockup showed). The block alone separates the two voices, the
bar added a second cue, and B's tint competes with the accent's
other meanings. In all three the text is `--fg`, the time is faint
`.8em` terminal font, tabular digits, at the right of the first line.

### 5. The composer floats over the transcript

The "Composer" control: "floating glass" (default) or "docked band"
(the earlier design).

**Layout.** The pane is the positioning context. The scroller
(`.scroll`) is absolute, `inset: 0 0 24px 0`, so it runs under the
dock; the transcript's bottom padding is the dock's height plus 8pt
(`--dock-h`, measured from the dock's box, set on the pane; the
built page measures it with a ResizeObserver on the dock and sets
the padding, so the last message is never under the glass when
scrolled to the end). The dock (`.dock`) holds everything that was
between the transcript and the status bar: the dialog card and its
"+1 queued" line, the composer with its queue, the exit card. It is
absolute, `left: 0; right: 0; bottom: 24px`, `pointer-events: none`
with `auto` on its children, so a click beside the composer reaches
the transcript. The status bar stays a 24pt opaque band at the
bottom (`position: absolute; bottom: 0; background: var(--bg)`):
its numbers and the context bar must not sit over moving text, and a
band gives the glass a floor to float above. The composer's 24pt
side padding and 12pt bottom padding are unchanged, so the capsule
floats 12pt above the band.

**Glass, the base style (what a browser and the mockup show).** On
`.field`, `.dialog`, `.exited .card` and `.queue` inside the dock:

    background: color-mix(in srgb, var(--ko-bg) 72%, transparent);
    -webkit-backdrop-filter: blur(18px) saturate(1.35);
    backdrop-filter: blur(18px) saturate(1.35);
    border: 1px solid color-mix(in srgb, var(--ko-fg) 22%, transparent);
    box-shadow: inset 0 .5px 0 color-mix(in srgb, #fff 28%, transparent),
                0 6px 22px color-mix(in srgb, var(--ko-fg) 14%, transparent),
                0 1px 3px color-mix(in srgb, var(--ko-fg) 10%, transparent);

Focus: border `fg 45%`; working: border `accent 55%`, the sweep as
before. The queue list gets the same surface with `border-radius:
8px; padding: 4px 8px 6px`; the one-line "+1 queued" note has a
`text-shadow` of the background so it reads over text. Radius (9pt
field, 9pt cards), padding and the content inset are the docked
values: the shape does not change with the material.

**Liquid Glass in Kido, the enhancement.** Kido's WKWebView can set
the private `useSystemAppearance`, which enables WebKit's private
`-apple-visual-effect` (see alastair.is, "Apple has a private CSS
property to add Liquid Glass effects to web content"). The mockup
carries it as

    @supports (-apple-visual-effect: -apple-system-glass-material) {
      .dock .field, .dock .dialog, .dock .exited .card, .dock .queue {
        background: transparent;
        backdrop-filter: none; -webkit-backdrop-filter: none;
        -apple-visual-effect: -apple-system-glass-material;
        box-shadow: none;
        border-color: color-mix(in srgb, var(--ko-fg) 14%, transparent);
      }
    }

A browser and Safari do not support the property, so the mockup
shows the base style only. The real material should look like the
system's: a clear, lensing glass that takes the pane's colour from
what is under it, with its own specular edge and shadow (hence
`box-shadow: none` and the lighter border; if the material draws its
own edge, drop the border too). What must hold in both: the same
rounded rect (the material clips to the element's border-radius),
the same padding and content inset, the text in `--fg` and the hints
in `--faint`. The implementer verifies on macOS 27 that the material
renders in a pane's web view and in the off-screen snapshots; if the
snapshots show no material, they show the base style, which is the
same shape.

**Contrast.** The base glass is 72% of the pane background over an
18pt blur: a code block or a table under it becomes a soft tone
shift, not legible shapes, and `--fg` text on it measures within a
few percent of `--fg` on the plain background (the mix lightens or
darkens by at most 28% of what is beneath, and the blur averages
that). The placeholder and hints are `--faint` (fg 35% over bg) as
before; over busy content they lose a little, which the mockup shows
in the stream state. If the real material is clearer than the base
style, the field keeps a tinted fill behind the text
(`color-mix(var(--ko-bg) 40%, transparent)`) rather than a weaker
text colour.

**The unfocused pane.** The glass and the band are mixes of
`--ko-bg`, which the app shifts to the unfocused paper together with
the pane: both follow it with no branch, and the base glass stays
72% of whatever the paper is, so a focused and an unfocused pane
differ by the same step inside and outside the composer.

**States that changed.** Every state: the compact spacing and the
prose run lines are everywhere; the user block is in every state
with a user message; the floating dock is in every state with a
composer, a dialog or the exit card. The mockup scrolls each
transcript so that text sits under the glass, to show it; a real
page scrolled to its end shows the last message above the dock.


## No step counts (user, 2026-11-09)

The run line names no steps: no "step i of n" while running (the
number is not known in advance), no "N steps ·" before the kinds when
done or failed, and "aborted, you pressed Escape" without a count.
The done line lists the tools by name, "xN" when one ran several
times ("thinking, read, edit, bash", "read, bash x2"); The failed
run colours that tool's name red in the same list. blocks.html and mockup.html show the new wording; the
page's run() in share/koa/koa-page.js still writes the counts.

## No kind marks (user, 2026-11-09)

Step lines carry no sigil ($, ✎, ◇, ∴). The action name is the mark:
"bash make verify …", "read ko_server/src/sweep.rs 212 lines", "edit …
+5 −1", "write …", a generic tool by its name, and "thinking". The
name is muted, the label in the fg colour, as before. The page's
stepInfo() in koa-page.js still sets a mark; the .mark column goes.

## No status icons (user, 2026-11-09)

No check, cross, abort glyph or spinner on a run line or a step line.
Colour alone carries the status: gray (the muted tone) for success,
running and aborted, red (`--ko-color-1`) for a failure. No word "failed"
anywhere: on the run line the failed tool's name is red in the list
("read, bash x2" with "bash x2" red); on its step the name and the
time are red, with no outcome word and no exit code (user, 2026-11-09:
"let's not specify exit codes"); the output holds what the command
printed. A finished step shows
only its time; a running one shows the time counting, no "…". The
edit's "+5 −1" keeps green and red: it is the diff count, not a
status. The .ok, .warn, .spin and .glyph rules of the run leave
koa-page.css; .err stays and also colours the failed step's time.

## Tool names on the run line (user, 2026-11-09)

The run line uses the tool's name, never "command": "bash", not
"command". A tool that ran N times is "bash xN", not "N commands";
once is the bare name. The same form for every tool: "read x2",
"edit". A failure is the red name, never the word "failed" or an exit code.

Tool names are in the terminal font (`--ko-font-family`, .92em like
the labels): the step's name span and the run line's list of names
(user, 2026-11-09), and the "thinking" label with them. "failed",
"running" and the aborted text stay in the prose font.

## The steps guide under the chevron (user, 2026-11-09)

The hairline at the left of a run's steps is under the run line's
chevron: .steps has margin-left 4pt (the glyph is centred in its 9pt
box, so its ink is at 4.5pt in both states) and padding-left 13pt, so
the step lines start 18pt from the run's left edge. (Was margin 17pt, padding 11pt, with the guide to
the right of the chevron and the steps at 28pt.)

Tool output and diffs inside a step's detail are smaller than the step
text: .detail pre and .diff at .88em (was 1em and .95em of the .98em
detail); user, 2026-11-09.

## Running: a gray spinner, no word, no bold (user, 2026-11-09)

The run line in progress shows an animated spinner in the gray tones
(8pt ring, 1.5pt, `--hair2` with a `--muted` arc, .8s) and then the
running label as regular text in the muted tone: "⟳ make verify
STAGES=unit", "⟳ thinking". The word "running" and the bold label go.
The spinner is the one animated mark; the status-icon rule still holds
for finished states (colour only).

## Even word spacing on a step line (user, 2026-11-09)

The step summary (.step .sum) is set in the terminal font at .92em, so
the spaces between the name, the label and the detail are all terminal
spaces; before, the spaces were prose spaces between terminal-font
spans and looked narrower. The detail text ("212 lines", "+5 −1", a
thinking's first line) is reset to the prose font at the step size
(1.087em of .92em).

## The chevron on the spinner's centre (user, 2026-11-09)

The chevron glyph (›) is centred in its 9pt box (text-align center)
and dropped 1pt (position relative, top 1pt), so its ink, folded or
rotated open, is centred on the spinner and on the x-height middle of
the label. Before, the open chevron sat about 1.5pt high and the
folded one about 1pt high.

## No empty output box (user, 2026-11-09)

A tool step's detail shows the output pre only when there is output;
a running bash with nothing yet shows just its cwd line, and a tool
that ended with empty output shows no box. (Before: an empty pre.)

## Smaller timings (user, 2026-11-09)

The times on the run line and on the step lines are .8em of the line
(was .92em, the size of the labels), in the terminal font and the
faint tone as before.

## No exit codes (user, 2026-11-09)

A failed bash step shows no "exit N": only its name and its time in
red, like any other failed tool. The outcome column holds a word only
for "aborted".

## The completion popup (complete.html; proposal, 2026-11-09)

`complete.html`, beside `blocks.html`, is the reference for unit 11
(plans/koa.md, section 7, "Completion"). It copies `mockup.html`'s
style block and draws the popup over the floating glass composer in
six states, light and dark, wide and 60 columns:

1. `/` at the start: every command of `get_commands` (templates,
   skills, extension commands), first row current, 8 of 10 visible.
2. `/re`: pi's fuzzy filter; `skill:` names by their bare name first.
3. `@si`: the session's agents first, as ko-pi shows them, then
   files; a directory ends with `/`.
4. `@ko_s`: files and directories alone, the base directory's
   entries first.
5. `@` in the middle of a message, the second row current, text after
   the caret.
6. `@zzz`: no match closes the list; there is no empty state.

**The card.** The dock's glass (`--ko-bg` 72% over a blur), its 22%
hairline and shadow, radius 9pt, padding 5pt, 6pt above the field.
Width: at least 260pt, at most 460pt and never wider than the field;
it opens at the token's x (the `/` or `@`, less the 9pt row padding)
and shifts left to stay inside the field. Rows: 23pt (the .95em prose line
plus 3pt padding top and bottom), radius 6pt, 8pt horizontal
padding, the current row on the 8% well (`--well2`), at most 8 rows
(184pt) before the list scrolls. A footer in the faint
terminal font: "↑↓ move · ⇥ ↩ accept · ⎋ close".

**A row.** The label in the terminal font at .92em in the fg colour:
`/name`, `@name`, or the path (a directory with a muted trailing `/`).
The detail in the muted tone, prose at .92em, ellipsized: a command's
description; an agent's status, activity and parent ("running -
applying the review findings, subagent of kido-app"); a file has none.
A kind tag at the right in the faint terminal font at .8em for
commands (`template`, `skill`, `extension`) and agents (`agent`); files
and directories carry none, the trailing `/` tells them apart. The
fuzzy-matched letters of a command or agent name are bold; paths are
plain.

**Keys** (the plan's): ↑↓ move, Tab accepts, Enter accepts and, for a
command, sends; Escape closes. The typed token in the field is the
accent colour for `/` and the fg colour for `@`, in the mockup only, to
show where the popup anchors; the page need not colour it.

Fixtures: the extension commands `/koa`, `/runtime`, `/review` and the
skill `/skill:ko-api` are invented for the list; the templates and the
other skills are the user's. Renders: `/tmp/koa-shots/complete-<state>-<theme>-<width>.png`.

## A working agent, five ways (working.html; proposals, 2026-11-09)

`working.html` compares five ways to show that pi is working, each in
light and dark, wide and 60 columns, on one frame of a live pane (a
user message, a run in progress with its gray spinner, the status bar
at "working 12s"). The run line's spinner stays in every variant.

- **A · shipped.** The field's border mixes 55% accent over the glass;
  a 1pt accent light, 40% of the width, crosses the top edge every
  1.6s (`.field.working`, `.field.working::after`, `sweep`).
- **B · the border travels.** No accent: the border is a gray ring
  (`--hair`) with one brighter segment (fg 85%) that runs around the
  field once every 2.4s, a conic gradient on a `::before` masked to
  the 1pt border (`@property --a`, `ring`).
- **C · quiet, a spinner in the foot.** The border rests. The foot's
  hint becomes the run line's gray spinner, then "working 12s · ⎋
  abort"; the status dot breathes (opacity to .35 and back, 1.6s).
- **D · the status bar carries it.** A 2pt muted light, 30% of the
  width, sweeps along the top edge of the status bar every 1.8s
  (`.status::before`); the field rests; the dot breathes.
- **E · the placeholder shimmers.** A light travels through "Steer
  koa…" every 2.2s (a gradient clipped to the text, `shine`); border
  and bar rest; the dot breathes.

Renders: `/tmp/koa-shots/working-<a..e>-<theme>-<width>.png`, one
frame each at 45% of the cycle.

**Chosen: C** (user, 2026-11-09, "let's do C"). mockup.html's working
state now shows it: the field's border stays the resting hairline
(the accent tint and the top-edge sweep go), the foot's hint is the
run line's gray spinner (8pt ring, 1.5pt, `--hair2` with a `--muted`
arc, .8s) then "working 12s · ⎋ abort" in the faint terminal font,
and the status bar's green dot breathes (opacity to .35 and back,
1.6s ease-in-out). The placeholder stays "Steer koa…", so the ↩ hint
is not needed. The run line's spinner is unchanged.

## Images, attachments and Quick Look (media.html; proposal, 2026-11-10)

`media.html` is the reference for units 12 to 14 (plans/koa.md,
section 8), ten states, light and dark, wide and 60 columns. It copies
`mockup.html`'s style block.

**12 · Images in the transcript.**
- A `read` of an image: the step's delta is `png · 1440×900` (the
  sniffed type and the pixel size) in place of "N lines". Open, the
  detail shows pi's note ("Read image file [image/png]") in the faint
  tone at .85em, then the thumbnail: the image at its own aspect, at
  most 240pt tall in a step (160pt in a user message), a `--hair`
  border, radius 6pt, `--well` behind it while it loads; the pixel
  size in a small label at its lower right on hover. It is a button
  (`role=button`, `tabIndex 0`, zoom-in cursor): click, Space or
  Enter previews it. Several images in one result sit in a row that
  wraps, 6pt apart.
- A user message: the text, then its thumbnails (160pt), then the
  path lines of its file attachments in the terminal font at .92em
  in the muted tone, one per line. The time stays at the right of
  the first line.
- An image that is gone (404, 410): a dashed `--hair2` box, 120×80pt,
  radius 6pt, "Image unavailable" in the faint prose at .8em; not a
  button.

**13 · Attachments.** A chip row above the field, inside the dock,
6pt gaps, wrapping. A chip is 28pt tall, radius 7pt, a `--hair2`
border, the dock's 72% glass fill, at most 320pt wide: a 20pt square
(the image's thumbnail, cover-cropped, or a document glyph on
`--well2` in the muted tone), the name (ellipsized), then the size in
the faint terminal font at .85em, then × (16pt, faint, `--well2` on
hover). A path chip shows the directory muted after the name instead
of a size. An upload shows the run line's gray spinner in the 20pt
square and "18 / 41 MB". A refused chip has its border tinted 45%
`--err` and the reason in red prose in place of the size ("over 64
MB", "too many", "not readable"). A click on the chip's body previews
it; × removes it. Drop hover: the field's border turns dashed at 45%
fg and the placeholder reads "Drop to attach"; nothing else moves. A
folder in any drop, local or not, is not attached (user, 2026-11-10:
no `@dir/` for now): one line in the chip row in the muted prose at
.85em, "Folders are not attached", for 4 s or until the next drop;
the files of the same drop still become chips. The queue: a row with attachments shows a
paper-clip glyph and the count after its text in the faint terminal
font. After Send: the chips go and the user message shows the
thumbnails and path lines of 12.

**14 · Quick Look.** While ⇧ and ⌘ are both held, the path of a
`read`, `edit` or `write` step with a file takes the pointer cursor
and an underline in the muted tone, offset 2pt (a page-level `cmd`
class that keydown and keyup set from `metaKey && shiftKey`);
⇧⌘-click previews the file (user, 2026-11-10: the terminal's
Shift-Command-click on images), a plain click folds. Other steps show nothing. The browser lightbox: a fixed
overlay on the dock's glass (72% `--ko-bg`, blur 18) over the whole
pane, the image at its natural size at most the viewport less 24pt a
side and 96pt of height, radius 6pt, a shadow; a caption below in the
faint terminal font: name · pixel size · "click or ⎋ to close".

Renders: `/tmp/koa-shots/media-<state>-<theme>-<width>.png`, states
read-image, user-images, image-gone, chips, drop, folder, queue, sent,
cmd-hover, lightbox. Approved by the user on 2026-11-10 ("mockups look
good, please go ahead"), as shown.

## Agent messages and job notices (agents.html; proposal, 2026-11-10)

`agents.html` is the reference for section 9 of plans/koa.md: what
passes between agents and what background jobs report, in six
states, light and dark, wide and 60 columns. It copies
`mockup.html`'s style block. The texts are ko-pi's today
(`noticeHeader`, `senderHeader`, `RELATION_TEXT`, `steerHeader`,
`jobEndText`, `streamBatch`, the `spawn_agent` reply); the fields
are the planner's. The user's direction (2026-11-10): messages look
like user messages with a "to @name" / "from @name" header, two
lines at most with a toggle; job notices are one minimal line,
name, exit and time, gray for success and red for failure, with a
toggle for the output.

**An agent message** (outgoing: `spawn_agent`, `message_agent`;
incoming: ko-pi's `ko-message`, `ko-steer`, `ko-notice` and a
report) is the user message's block: `--well` fill, radius 8pt,
padding 6pt 12pt 7pt, with a header line above the text.
- The header, in the muted prose at .92em: "to @name" (outgoing) or
  "from @name" (incoming), the @name in the terminal font in the fg
  colour; for incoming the relation faint after a "·" (RELATION_TEXT
  shortened: "your parent", "your subagent", "another agent in this
  session", "a subagent of your subagent"; none for ko-pi's own
  notices); at the right, before the time, the kind in the faint
  terminal font at .8em: `task` (a spawn), `message`, `steer`,
  `interrupt` (outgoing); `message`, `steer`, `report`, `ended` (a
  child's end), `notice` (ko-pi's own) (incoming); then the time in
  tabular digits. No delivery status (user, 2026-11-10: no
  delivered, queued, sent, spawned): a failure alone shows, in red,
  in the kind's place ("refused", "no agent named …", "not reported"
  for an ended child that had not reported). A card splits the run
  it sits in.
- The body is the text as prose. Collapsed (the default), it is one
  line: the first line of the text, cut with an ellipsis (nowrap,
  text-overflow), so a card is two lines at most (user, 2026-11-10:
  "too much info … 2 lines max"); the ellipsis is the sign of more.
  A click anywhere on the block expands it to the whole text
  (pre-wrap); a second click collapses it. Every block toggles, so a text
  that wraps in a narrow pane also stays one line until clicked; a
  text that fits shows no ellipsis.
- No meta lines: a spawn shows no session, window, pane or model
  line, and a cut report shows no "full report: read_report(…)"
  trailer (user, 2026-11-10). A failed spawn has the name and
  "refused" in red and ko-pi's refusal as the body; a refused
  `message_agent` keeps its text and the refusal in red in place of
  "delivered".

**A job notice** (`async_bash`'s end notice, a `ko-stream` batch) is
one line in the terminal font at .92em, muted: a chevron (as a
step's), the job's name in fg, the kind only when it is not a plain
job (`service`, `stream`, faint .85em), the end in ko-pi's words
("exit 0", "exit 1", "signal SIGKILL", "failed: …", "timed out
600 s"; none for a stream batch), and the time at the right in faint
tabular digits. Gray when it succeeded; the name and the end in
`--err` when it failed (exit ≠ 0, a signal, failed, timed out). A
click on the line opens the output under a 1pt `--hair` guide at
17pt, 11pt of padding (a step's geometry): the tail in a `--well`
pre, radius 7pt, at most 200pt, scrolling; consecutive stream
batches of one job in one entry, separated by "+ HH:MM" lines; then
"log: <path> · … N lines omitted" faint, ellipsized. Closed by
default.

**Plain agent tools** (`list_agents`, `read_report`, `stop_agent`,
`list_async_bash`, `stop_async_bash`) stay steps in a run, by name
with their first argument, as blocks.html draws them.

The states follow the planner's section 9 list (in: message from
parent/child/peer, steer, notice, report, ended reported/not, job end
exit 0/1/signal/timeout, stream; out: spawn pending/spawned/failed,
message queued/sent/delivered/refused; a folded text; a card between
runs; narrow); the planner's "6 lines" is superseded by the user's
three.

Renders: `/tmp/koa-shots/agents-<state>-<theme>-<width>.png`, states
out, failed, in, jobs, fold-a, fold-b, tools. Approved by the user on
2026-11-10, as shown.

## The status bar moves into the composer (composer.html; proposal, 2026-11-10)

`composer.html`: the 24pt status bar goes and its facts move into the
composer's foot, the row under the text that holds the send or stop
button. Eight states, light and dark, wide and 60 columns. The foot
is the terminal font at .8em, 20pt tall, 2pt below the text and 5pt
above the field's bottom edge (user, 2026-11-10: less padding; was
24pt, 6pt and 8pt), no button; its
cells, left to right, each with a 1pt `--hair` separator 10pt either
side:

1. **The state**: a 6pt dot (faint for idle and starting, `--ko-color-2`
   breathing for working, `--ko-color-3` for waiting, `--ko-color-1`
   for exited) and the word with its time in tabular digits: "idle",
   "working 12s", "waiting", "starting", "exited 137" / "signal 9".
   **Reserved width: 15ch of the .8em terminal font plus the dot and
   its 6pt gap** (`min-width: calc(15ch + 12px)`, about 106pt at the
   13pt base), the width of "working 12m 34s"; so a state change or a
   tick moves nothing to its right (user, 2026-11-10). Escape aborts;
   nothing in the row says so.
2. **The model**: a button "claude-opus-5-5 · high" (the level faint);
   the picker opens above it, 8pt up, left-aligned 6pt out; the cell
   takes `--well2` while the picker is open or on hover.
3. **The context**: the 44pt bar (18% track, faint fill, warning colour
   over 75%), "84k / 200k" faint, the percent; reserved at the bar
   plus 3ch.
4. **The gap**: flexible, the one cell with no reserved width.
5. **The cwd**: the leading directories faint, the last component
   muted, at the field's right padding.

Nothing else is in the composer (user, 2026-11-10: "no icons … only
status, model picker, context, cwd"): the send/stop button goes
(Return sends, Escape aborts, as the keys already do), and a
notification is not a toast in the foot but one line in the
transcript where it arrived: terminal font .92em muted, the text
ellipsized, the time at the right in faint tabular digits as a job
line; a warning in `--warn`, an error in `--err`; no badge; it stays.

Narrow (60 columns) drops, in order: the thinking level, the cwd's
leading directories, the context numbers; the bar, the percent, the
model, the state and "kido" stay, and the state keeps its reserved
width. The transcript gains the 24pt; the dock sits on the pane's
bottom edge. Renders: `/tmp/koa-shots/composer-<state>-<theme>-<width>.png`,
states idle, working, waiting, exited, picker, toast, toast-err,
narrow. Approved by the user on 2026-11-10, as shown.

## Times end at one edge (user, 2026-11-10)

The time of a run line, a step line and a job line ends where the
user message's time ends: 12pt in from the transcript's edge, the
user block's horizontal padding (`.run .line{padding-right:12px}`,
the same on a job line). Agent message blocks share the user block's
padding, so their times align too.

## The user message is the accent at 18% (user, 2026-11-10)

The user message's block is `color-mix(in srgb, var(--accent) 18%,
var(--ko-bg))` (`--accent` is `--ko-color-4`), in place of the 5% gray
well, so it carries more weight than the agent message blocks, which
keep the 5% well; radius 8pt and padding 7pt 12pt unchanged. The user
chose it from 9, 13, 18 and 24% and from gray 12 and 16%. Every koa
mockup page has it; mockup.html's "User message" control keeps the
old treatments for reference.
