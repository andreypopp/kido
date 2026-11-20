# koa — the webview harness, reference mockups

The files beside this one are self-contained mockups: inline CSS and
JS, no network. Open them from a static server (`python3 -m
http.server` in `app/design`) and use their controls: theme
(kido-light, kido-dark) and pane width (980pt, or 60 terminal cells).
Each numbered section is one state of the page, rendered inside a
frame that stands for the pane's content area. Click a run line or a
step line to fold or unfold it.

These notes give the look; docs/design-koa.md gives koa's design. Git
keeps the superseded designs and the rejected alternatives; these
notes describe only the current state, and the last section, the
question controls, is approved but not built yet.

## Index: the authoritative state of each part

| Part | Reference | Sections here |
| --- | --- | --- |
| Colours, fonts, the column | `mockup.html` | "Rules the page follows", "The transcript", "Compact spacing" |
| User message | `agents.html` (every page has it) | "The user message is the accent at 18%" |
| Runs and steps | `blocks.html` | "The run", "No step counts" to "No exit codes", "Times end at one edge" |
| The composer and its glass | `composer.html` | "The composer", "The composer floats over the transcript" |
| The composer's foot: state, model, level, context, cwd | `composer.html` | "The composer's foot" |
| A working agent | `composer.html`, the foot's breathing dot | "The composer", "The composer's foot" |
| Notifications and extension status | `composer.html` | "The composer's foot" |
| Dialogs, queue, pickers, exit card | `mockup.html` | "Dialogs from extensions", "The queue while koa works", "The model and thinking pickers", "pi has exited" |
| The completion popup | `complete.html` | "The completion popup" |
| Images, attachments, Quick Look | `media.html` | "Images, attachments and Quick Look" |
| Agent cards and job lines | `agents.html` | "Agent messages and job notices" |
| Question controls in a reply | `questions.html` | "Question controls in a reply" |
| The user message | `user.html` | "The user message is the accent at 18%" |
| `!` runs a command | `bang.html` | "`!` runs a command" |
| Built-in slash commands | `commands.html` | "Built-in slash commands" |
| Sessions inside the page | `sessions.html` | "Sessions inside the page" |
| Markdown in a thinking step | `thinking.html` | "Markdown inside a thinking step" |
| The foot at narrow widths | `foot.html` | "The foot at narrow widths" |

`working.html` holds the five working-state variants from which the
user chose; the foot of `composer.html` replaced the chosen one.
On 2026-11-11 `mockup.html`, `agents.html`, `complete.html`,
`media.html` and `working.html` got the shipped composer foot of
`composer.html` (status, model and level, context, cwd; no button)
and lost their bottom status bar, which the page has not had since
24b2451e. `composer.html` stays the reference for the foot's states.
`mockup.html`'s "Composer" and "User message" controls keep earlier
treatments for reference only.

## Rules the page follows

- **Only `--ko-*`.** The page's colours are `--ko-bg`, `--ko-fg`,
  `--ko-cursor` and the palette (`--ko-color-N`), and every other
  tone is a `color-mix` of them: muted text 55% fg, faint 35%,
  hairlines 12% and 18%, wells 5% and 8%. The accent is palette 4
  (blue), ok is 2, error is 1, warning is 3, so a theme's own palette
  colours the page. The `:root` block at the top of the mockup is the
  browser fallback, kido-light and kido-dark copied from
  `app/Resources/ghostty/themes`; in Kido.app the properties the app
  sets override it; in a browser the fallback follows
  `prefers-color-scheme`.
- **Two fonts.** Prose (user and assistant text, thinking, the
  composer's text) is the system font at `--ko-font-size`, line
  height 1.5. Everything that is a terminal fact is the terminal font
  (`--ko-font-family`): code, tool names, commands and paths on the
  run and step lines, times, diffs, bash output, job and notification
  lines, and the composer's foot.
- **No header.** The pane's sidebar row and the title tabs already
  name the agent and its session. The page is the transcript and the
  composer, nothing above.
- **No chrome of its own.** No borders around messages, no avatars,
  no bubbles. A user message is a block in the accent's tint ("The
  user message is the accent at 18%"); an agent card is a block in
  the 5% well. An assistant message is plain prose.

## The transcript

- Content column: 720pt wide, centred, 14pt top and 20pt side
  padding. In the narrow pane it is fluid with 12pt sides.
- An empty session shows nothing: the paper and the composer, no
  wordmark or "nothing yet" text (user, 2026-11-09).
- Markdown: headings in the prose font, 1.3/1.15/1em, 600 weight;
  lists with muted markers; inline code in an 8% well with 4pt
  corners; code blocks in a 5% well with a 12% hairline, 7pt corners,
  the language as a faint label at the top right; tables with a
  hairline under each row, uppercase muted header cells, no vertical
  lines; blockquotes with an 18% left bar.
- A user message's timestamp (user, 2026-11-08): the time of sending
  at the right of the message's first line, terminal font at 80%,
  in the accent ink ("The user message is the accent at 18%"),
  tabular digits, 14pt after the text, never wrapping; the
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
An agent card splits a run as a text does.

- **Collapsed** (default): one line, muted. A chevron, then the
  summary, then the elapsed time at the right. While running the
  summary is a gray spinner and the running label ("⟳ make cargo …",
  "⟳ thinking"); done, it is the tools by name ("thinking, read,
  edit, bash"; "bash x2" when one ran twice). A failed run colours the
  failed tool's name red; an aborted one reads "aborted, you pressed
  Escape". No counts and no icons; the sections from "No step counts"
  to "No exit codes" give each rule.
- **Expanded to lines**: the steps, under a hairline guide below the
  run line's chevron ("The steps guide under the chevron"). One line
  per step: the tool's name (a thinking block reads "thinking"), the
  command or path in the fg colour, the step's own detail in faint
  (`+5 −1`, `212 lines`, the thinking's first words), and the time at
  the right. Summaries ellipsize before the time; the time never
  wraps.
- **Expanded to details**: bash shows `cwd` and the output in a well,
  cut to 260pt and scrollable; an edit shows the file name in a
  header bar and a diff with added lines on a 12% green tint and
  removed lines on an 11% red tint, markers in the margin; thinking
  shows the full text as muted prose, 260pt cut and scrollable.
- Fold state is per run and per step, kept while the page is open.
  A run that is running stays collapsed unless the user opened it.

## The composer

- A 9pt-radius field on the dock's glass ("The composer floats over
  the transcript"), 9pt 12pt padding. Focused: the border takes
  `--ko-focus`, the pane's focus colour. The text grows to nine lines
  and then scrolls ("Question controls in a reply"); a quote line is
  in `--muted`. The editor draws its cursor in `--ko-cursor`.
- No button: Return sends (a steer while koa works), Escape aborts,
  and nothing in the field says so (user, 2026-11-10, with
  `composer.html`).
- Placeholder "Message koa…"; while koa works, "Steer koa…"; during a
  drag, "Drop to attach"; after pi exits, "pi has exited".
- **While the agent works** the field stays editable and its border
  rests; the foot's state dot breathes. Escape anywhere on the page
  aborts; a second Escape clears the field.
- **While the C-g editor is open** the foot's state cell (15ch) reads
  "Editing…"; the editor's name goes to the cell's tooltip, "Editing in
  nvim". The cell has no wider form, so the name is never cut.
- **Markdown in the field** (user, 2026-11-09, without a mockup): the
  markup characters muted, strong bold, emphasis italic, code in the
  terminal font at the transcript's code size with no background,
  headings bold at the field's size, link text in fg; nothing else
  coloured.

## The narrow pane (60 cells)

Same page. The transcript column loses its centring margin, tables
and code blocks scroll inside their block, run summaries ellipsize,
and the composer's foot drops cells in the order of "The composer's
foot". Nothing hides otherwise.

## Decisions (user, 2026-11-08 and 2026-11-09)

1. Prose in the system font; terminal facts in the terminal font.
2. A finished run stays collapsed, also after a failure.
3. The context bar always shows.
4. A user message carries a timestamp, no label.
5. Compact spacing; the composer floats over the transcript on
   glass; an empty session shows nothing.

## Dialogs from extensions

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
stays visible and inert (the field keeps its text), the foot's state
says "waiting" with the orange dot, and focus is in the card; ⎋ in
the card cancels the request, not the run.

## The queue while koa works

Steering and follow-up messages that pi holds are listed above the
field (user, 2026-11-10; they were under it), inside the composer
column, with a 6pt gap under the list and none above; when the draft
has attachment chips, the order from the top is the queue, the chips,
the field: the chips belong to the draft and stay against it, the
queue is what pi already holds. A dialog card and its "+1 queued"
line stay above all of them. The list is one line each, a tag in the
terminal font (`steer`, `follow-up`) in a 62pt column, the text
ellipsized. Under them, the count and a "take back ⌥⌫" button, the
hairline button style, no key of its own (⌥⌫ is delete-word in the
field; Tab from the field reaches the button, ↩ or Space presses
it): it calls pi's `clear_queue` and puts every message into the
composer, each on its own paragraph in queue order, caret at the
end, the queue line gone. A queued row with attachments shows a
paper-clip glyph and their count after its text.

## The model and thinking pickers

The model cell of the composer's foot is two buttons: the model name
opens the model picker, the level opens the same picker with the
thinking levels. Tab from the composer reaches them (after the
queue's button when it shows), ↩ or Space opens. No key inside the
field opens them: ⌃M and ⌃T are Cocoa text bindings (newline,
transpose) that WebKit fields honour. The popover opens 8pt above the
cell, left-aligned 6pt out, 220pt minimum, a 9pt radius, the 18%
hairline, a soft shadow (fg 14%, 8pt down, 28pt blur), 6pt padding,
the terminal font at 88%. A faint caption (Model, Thinking), then the
rows: a 10pt tick column (✓ in the accent colour on the current
entry), the name, and for a model the provider faint at the right.
The highlighted row is the 8% well. The bottom hint row reads "↑↓
move · ↩ choose · ⎋ close". While the popover is up, its cell takes
`--well2`. ↩ applies through pi's `set_model` / `set_thinking_level`
and closes; ⎋ closes with no change; a click outside closes. The model
list is what pi reports as available, grouped in pi's order. When the
narrow pane drops the level's text, the model picker offers the
levels.

## pi has exited

When pi fails (a code other than 0, or a signal), the transcript
stays as it was. A card above the field has a hairline in the error
colour at 35%: "pi exited · code N" (or "· signal SIGKILL") in the
title line with the time at the right, the last five lines of pi's
stderr in a muted well cut to 140pt, a faint line that names where
the whole log is, and the primary button "Start pi again"; ↩ presses
it. The stderr lines are the last five koa received; the whole
output is in the pane's terminal (koa writes pi's stderr to its own
stderr and keeps no log file). The foot's dot turns to the error
colour and its word is "exited N" (or "signal 9"); the model, level
and context cells keep their last values. A start removes the card
and continues the session. A pi that exits with code 0 ends koa and
its pane, so it shows no card.

## Times

Every step shows its own time at the right of its line, the thinking
step included; a run's time is from its first step's start
to its last step's end. An aborted run shows its elapsed time like
any other, and its aborted step shows the time it ran before the
abort (`aborted 23s`).

## Keyboard

Everything works without a mouse. Command keys go to Kido first. In
the page: ↩ sends or steers, ⇧↩ newline, ⌥↩ queues a follow-up,
⎋ aborts (twice: clears the field), ⌃D in an empty field quits koa; in a dialog ↑↓ ↩ ⎋ as above, ⌃↩
submits an editor, and ⎋ cancels the dialog, not the run; ↑↓ ↩ ⎋
inside a picker; ↩ on the exit card starts pi again. Tab moves from
the field to the dialog's controls, the queue's button, and the
foot's model and level buttons, in that order; ↩ or Space presses the
focused one. No Command key and no other Control-letter key is bound
in the page: Command keys go to Kido first, Control letters are Cocoa
text bindings.

## Run and step lines in the system font (user, 2026-11-09)

The run line, the step lines and the thinking line are the prose
font now; only the glyphs and the code-like parts stay in the
terminal font.

- `.run`: `font: .95em/1.5 var(--prose)`, colour muted (was
  `.92em/1.6 var(--mono)`).
- Terminal font, `.92em`: the chevron, the tool names and
  "thinking" ("Tool names on the run line"), a command (`.cmd`), a
  path (`.path`) and the time at the right (`.time`, tabular digits,
  "Smaller timings"). The delta words and "aborted" are prose.
- The thinking block's text was prose already; it is `1em/1.5`,
  muted, `white-space: pre-wrap`.

## The thinking block's padding (user, 2026-11-09)

The space under an expanded thinking block came from three margins
that added up. Now: `.detail{margin:2px 0 4px 20px}`,
`.detail .think{padding:0;margin:0}`, `.detail pre{margin:3px 0 4px}`,
`.diff{margin:3px 0 4px}`. The block ends 4pt above the next step
line, like a command's output well does.

## Compact spacing (user, 2026-11-09)

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

## The composer floats over the transcript (user, 2026-11-09)

**Layout.** The pane is the positioning context. The scroller
(`.scroll`) runs under the dock to the pane's bottom edge; the
transcript's bottom padding is the dock's height plus 8pt (`--dock-h`,
which the page measures with a ResizeObserver on the dock), so the
last message is never under the glass when scrolled to the end. The
dock (`.dock`) holds the dialog card and its "+1 queued" line, the
composer (its queue, then the chips, then the field), and the exit
card. It sits on the
pane's bottom edge, `pointer-events: none` with `auto` on its
children, so a click beside the composer reaches the transcript.

**Glass.** On `.field`, `.dialog`, `.exited .card` and `.queue` inside
the dock:

    background: color-mix(in srgb, var(--ko-bg) 72%, transparent);
    -webkit-backdrop-filter: blur(18px) saturate(1.35);
    backdrop-filter: blur(18px) saturate(1.35);
    border: 1px solid color-mix(in srgb, var(--ko-fg) 22%, transparent);
    box-shadow: inset 0 .5px 0 color-mix(in srgb, #fff 28%, transparent),
                0 6px 22px color-mix(in srgb, var(--ko-fg) 14%, transparent),
                0 1px 3px color-mix(in srgb, var(--ko-fg) 10%, transparent);

The queue list gets the same surface with `border-radius: 8px;
padding: 4px 8px 6px`; the one-line "+1 queued" note has a
`text-shadow` of the background so it reads over text. The glass is
CSS only: WebKit's private system glass material needs a private
preference and does not show in WebKit's snapshots.

**Contrast.** The glass is 72% of the pane background over an 18pt
blur: a code block or a table under it becomes a soft tone shift, not
legible shapes, and `--fg` text on it measures within a few percent of
`--fg` on the plain background.

**The unfocused pane.** The glass is a mix of `--ko-bg`, which the app
shifts to the unfocused paper together with the pane, so a focused and
an unfocused pane differ by the same step inside and outside the
composer.

## No step counts (user, 2026-11-09)

The run line names no steps: no "step i of n" while running (the
number is not known in advance), no "N steps ·" before the kinds when
done or failed, and "aborted, you pressed Escape" without a count.
The done line lists the tools by name, "xN" when one ran several
times ("thinking, read, edit, bash", "read, bash x2"); The failed
run colours that tool's name red in the same list.

## No kind marks (user, 2026-11-09)

Step lines carry no sigil ($, ✎, ◇, ∴). The action name is the mark:
"bash make verify …", "read ko_server/src/sweep.rs 212 lines", "edit …
+5 −1", "write …", a generic tool by its name, and "thinking". The
name is muted, the label in the fg colour.

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
status.

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
the step lines start 18pt from the run's left edge.

Tool output and diffs inside a step's detail are smaller than the step
text: .detail pre and .diff at .88em; user, 2026-11-09.

## Running: one indicator, the typing dots (user, 2026-11-15; was the gray spinner of 2026-11-09)

The spinner goes. The typing dots are the one working mark of the
page, in the tool row and alone:

- **The dots** (user, 2026-11-15: the old spinner's size, not the
  composer dots'): three 3px circles, 3px apart, 15px wide in all;
  the bounce 2px high (the old spinner was an 8px ring, and the
  dots' box with the bounce is 8px tall: 3px dots, 2px travel, the
  rest the ring's margin), `--faint`, the bounce (2026-11-16, it
  was jumpy with linear timing): up in the first 30% of the 1.1s
  cycle with ease-out, down by 60% with ease-in, then at rest;
  the dots 180ms apart, opacity .55 at rest and 1 at the top.
  Use CSS animation (user decision): its phase can restart when the
  mark moves between the bare row and a tool row. Keep the same node
  through patches. The box is 15×8px, `inline-flex`, `vertical-align:
  middle` so its centre sits on the row text's x-height centre as
  the spinner's ring did (the spinner had `vertical-align: -1px` on
  an 8px ring; the same -1px on the 8px box gives the same place),
  so it adds no height to a row. The same 15×8 box in the `!`
  command row (after the command, the spinner's 6px gap), in the
  completion popup's last row (at the row's text start) and inline
  after the caret. The composer's own typing dots (6px) are gone with
  the old typing element. Reduce Motion: the three dots static, no
  bounce.
- **In a running tool row**: after the tool's name with the 6px gap
  the spinner had: "bash ···"; the elapsed time at the right as
  today. In an expanded run only the running step's line has the
  dots; finished steps have their times. The folded run line shows
  one dots mark after its summary ("read x2, bash ···"); several
  tools running at once show one mark on each running step and one
  after the folded summary.
- **The rule of the last element** (user, 2026-11-16, the same as
  on iOS): the working mark sits in the last visible element of the
  transcript when that element is a run row, and in a bare row
  otherwise. So:
  - Last element a run row (folded or open), no step running (the
    agent thinks between calls): the dots on the run's own line,
    after its summary ("thinking, bash x2 ···"), the time at the
    right as the row has it; never a bare row under a run row.
  - A step running: the dots on the running step's line in an open
    run, and after the summary of a folded one; parallel steps one
    each; the header carries none while a step runs in an open run.
  - A new tool call starting while the mark is on the run's line:
    the call joins that run (the run grows by a step), the mark
    moves from the summary to the running step's line in the same
    frame (open) or stays after the summary (folded); nothing
    appears or goes, the row count does not change.
  - Thinking is a step of the run as today ("thinking" in the
    summary, a step line when open): the mark follows the same rule
    as a tool step.
  - Reply text starting to stream after the run: the first text
    block appends below the run and the mark leaves the run's line
    in the same frame and stands as the bare row under the arriving
    text (where the caret stood), because the last element is now
    text; when the text is final and a run follows, the mark goes
    into that run again. The bare row exists only when the last
    element is not a run row: under streaming text, or right after
    the user's message before anything else.
  - The bare row: a run row with the dots and no name, the same
    `.run > .line` (padding-left `--pad`, 1px paddings, the row's
    line height), the box where the name's first glyph starts,
    nothing at the right; exactly a tool row's height; the same
    space above it as a run row has after text (it is one).
- **Transitions, one frame per patch**: every move of the mark
  (summary → step, step → summary, run → bare row, bare row → run)
  happens in the frame of the patch that changes the last element;
  no frame shows no mark while the turn works, no frame shows two.
- **The turn's end**: the mark goes in one frame (the Auto-scroll
  rule): the run's line keeps its time, a bare row is removed; an
  abort turns a running step into the "aborted" row as today, dots
  gone.
- The status-icon rule holds for finished states: colour only.

## The foot without the status cell (user, 2026-11-15, spec)

The working mark in the transcript (the dots) says what the status
cell's dot and word said; the cell goes. The foot is then: model ·
thinking, the context, the extension statuses, the gap, the cwd; the
separator after the first cell goes with it, so the foot starts with
the model button at the field's left padding. Where each thing the
cell carried goes:

- **The agent state**: `working` and its elapsed time: the dots in
  the transcript, no clock (the run rows carry their own times; the
  turn's elapsed time was never acted on). `starting` and `loading`:
  the composer's placeholder reads "Starting pi…" / "Loading…" with
  the field inert; nothing else. `compacting`: the compaction row in
  the transcript ("compacting ···", the notice row with the dots)
  already shows it; the field stays usable as today. `waiting` (a
  dialog is open): the dialog card above the field is the state;
  nothing in the foot. `idle`: nothing: a quiet transcript end and an
  enabled field. `aborted`: the run's "aborted, you pressed Escape"
  row says it; nothing in the foot. `failed` (pi failed to start or
  exited): the exit card above the field, as today, with its red
  text; the foot has no red dot any more.
- **`!` mode**: the mode is the field's own look (the bang in the
  link colour, the mono font); the words "run" / "run, quiet" go. A
  live command: its `.cmdrun` row in the transcript has the dots
  and the elapsed time (the same mark); the foot shows nothing. A
  `!` draft with attachments: the attachment chips take the refused
  border (`.attach-chip.refused`), their detail staying muted (the
  directory is not the reason; the red detail is for a chip whose
  detail is a reason word), and the existing `.attach-notice` "a
  command takes no attachments" sits beside the chips in their row,
  as "Folders are not attached" does; Return is refused as today.
- **Completion hints**: "completing…" becomes the dots at the end
  of the completion popup's list (one row, the dots at the row's
  text start) while the request runs, and the popup's empty state
  reads "no completions" for 1.5 s as today, in the popup, not the
  foot. With no popup open yet (Tab pressed, nothing back), the dots
  appear in the field after the caret for the wait (inline, the same
  mark); they go with the answer.
- **"Editing…"**: the field's `editing` look (45% opacity, inert) is
  the state; the words go; the tooltip "Editing in nvim" moves to the
  field (the whole composer's `title` while editing).
- **The job view's foot** keeps its own cell: it is the job's state,
  not the agent's, and the job view has no transcript mark for it
  (the dot, "running 3m 04s", the byte count, Stop/Clear stay as the
  job page draws them). Its layout is `#jobfoot`'s, unchanged.
- **Narrow breakpoints** (page.css 29–32): the `< 540` rule hides the
  level, the cwd's lead and the context's numbers; `< 340` hides the
  model cell and its separator, the gap and the cwd, leaving the
  context at the right (`margin-left: auto`); `< 200` hides the
  context too, leaving an empty foot of its min-height (20px) so the
  field's bottom padding does not change. The `.foot .st + .sep`
  rule goes with the cell.
- **Extension statuses** (`#status-extras`, the 630px rule) stay as
  they are, after the context cell.
- **Accessibility**: the state words move with their elements (the
  dots carry `aria-label="working"`, the placeholder its text, the
  exit card its own); nothing loses a spoken name.

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
the label.

## No empty output box (user, 2026-11-09)

A tool step's detail shows the output pre only when there is output;
a running bash with nothing yet shows just its cwd line, and a tool
that ended with empty output shows no box.

## Smaller timings (user, 2026-11-09)

The times on the run line and on the step lines are .8em of the line
in the terminal font and the
faint tone as before.

## No exit codes (user, 2026-11-09)

A failed bash step shows no "exit N": only its name and its time in
red, like any other failed tool. The outcome column holds a word only
for "aborted".

## The completion popup (complete.html; approved, 2026-11-09)

`complete.html` is the reference for the composer's completion
(docs/design-koa.md, "The composer"). It copies `mockup.html`'s
style block and draws the popup over the floating glass composer in
six states, light and dark, wide and 60 columns:

1. `/` at the start: every command of `get_commands` (templates,
   skills, extension commands), first row current, 8 of 10 visible.
2. `/re`: pi's fuzzy filter; `skill:` names by their bare name first.
3. `@si`: the session's agents first, as the agent extension shows them, then
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

## Images, attachments and Quick Look (media.html; approved, 2026-11-10)

`media.html` is the reference for images, attachments and Quick Look
(docs/design-koa.md), ten states, light and dark, wide and 60 columns. It copies
`mockup.html`'s style block.

**Images in the transcript.**
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

**Attachments.** A chip row above the field, inside the dock,
6pt gaps, wrapping. A chip is 28pt tall, radius 7pt, a `--hair2`
border, the dock's 72% glass fill, at most 320pt wide: a 20pt square
(the image's thumbnail, cover-cropped, or a document glyph on
`--well2` in the muted tone), the name (ellipsized), then the size in
the faint terminal font at .85em, then × (16pt, faint, `--well2` on
hover). Every attachment, a Finder drop included, is an uploaded
copy (2026-11-20: WebKit reads the dropped file and the page uploads it, since
macOS TCC blocks koa from reading Desktop or Downloads as `ko`; the
path chip is gone). An upload shows the run line's gray spinner in the 20pt
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
thumbnails and path lines above.

**Quick Look.** While ⇧ and ⌘ are both held, the path of a
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

## Agent messages and job notices (agents.html; approved, 2026-11-10)

`agents.html` is the reference for agent cards and job lines
(docs/design-koa.md): what passes between agents and what background
jobs report, light and dark, wide and 60 columns. It copies
`mockup.html`'s style block. The texts are the agent extension's (`noticeHeader`,
`senderHeader`, `RELATION_TEXT`, `steerHeader`, `jobEndText`,
`streamBatch`, the `spawn_agent` reply). The user's direction
(2026-11-10): messages look
like user messages with a "to @name" / "from @name" header, two
lines at most with a toggle; job notices are one minimal line,
name, exit and time, gray for success and red for failure, with a
toggle for the output.

**An agent message** (outgoing: `spawn_agent`, `message_agent`;
incoming: the agent extension's `ko-message`, `ko-steer`, `ko-notice` and a
report) is the user message's block: `--well` fill, radius 8pt,
padding 6pt 12pt 7pt, with a header line above the text.
- The header, one phrase in the muted prose at .92em (user,
  2026-11-10; nothing in the header is in the terminal font except
  the time): `<kind> to|from @<name> <relation>`, as "message to
  @sidebar-right", "steer from @kido-app parent", "report from
  @sidebar-right subagent"; the @name in 600 in the fg; the relation
  one word in the faint tone (`subagent`, `peer`, `parent`; none for
  the agent extension's own notices); at the right only the time, .8em terminal
  faint tabular; for incoming the relation faint after a "·" (RELATION_TEXT
  shortened: "your parent", "your subagent", "another agent in this
  session", "a subagent of your subagent"; none for the agent extension's own
  notices); the kinds: `task` (a spawn), `message`, `steer`,
  `interrupt` (outgoing); `message`, `steer`, `report`, `ended` (a
  child's end), `notice` (the agent extension's own) (incoming). No delivery status
  (user, 2026-11-10: no delivered, queued, sent, spawned): a failure
  takes the kind's place, in red ("refused to @name", "not reported
  from @name subagent"). A card splits the run
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
  "refused" in red and the agent extension's refusal as the body; a refused
  `message_agent` keeps its text and the refusal in red in place of
  "delivered".

**A job notice** (`async_bash`'s end notice, a `ko-stream` batch) is
one line; since 2026-11-11 (unit koa-jobline) it takes the run
line's look of item 5 in "refine.html": prose .95em, muted, the
name as plain row-coloured text, no end text on the folded line
(the exit code or the failure is in the opened body), the name in
`--ko-color-1` when it failed, as a failed tool call; the kind
label, the time and the opened body are as before. Before that it
was one line in the terminal font at .92em, muted: a chevron (as a
step's), the job's name in fg, the kind only when it is not a plain
job (`service`, `stream`, faint .85em), the end in the agent extension's words
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

The states cover, in: a message from a parent, a child and a peer, a
steer, a notice, a report, an ended child that reported or not, job
ends with exit 0, exit 1, a signal and a timeout, and a stream; out: a
spawn and a message, with their failures; a folded text; a card
between runs; narrow.

Renders: `/tmp/koa-shots/agents-<state>-<theme>-<width>.png`, states
out, failed, in, jobs, fold-a, fold-b, tools. Approved by the user on
2026-11-10, as shown.

## The composer's foot (composer.html; approved, 2026-11-10)

`composer.html`: koa has no status bar; its facts are in the
composer's foot, the row under the text. Eight states, light and
dark, wide and 60 columns. The foot is the terminal font at .8em,
20pt tall, 2pt below the text and 5pt above the field's bottom edge,
no button; its
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
2. **The model**: "claude-opus-5-5 · high" (the level faint), two
   buttons: the name opens the model picker, the level the thinking
   picker ("The model and thinking pickers"); the cell takes
   `--well2` while a picker is open or on hover.
3. **The context**: the 44pt bar (18% track, faint fill, warning colour
   over 75%), "84k / 200k" faint, the percent; reserved at the bar
   plus 3ch.
4. **Extension statuses**: an extension's `setStatus(key, text)` is
   one cell for each key, in the foot's cell style, gone when its
   text goes.
5. **The gap**: flexible, the one cell with no reserved width.
6. **The cwd**: the leading directories faint, the last component
   muted, at the field's right padding.

Nothing else is in the composer (user, 2026-11-10: "no icons … only
status, model picker, context, cwd"): Return sends and Escape aborts,
and nothing says so. A notification is one line in the transcript
where it arrived: terminal font .92em muted, the text
ellipsized, the time at the right in faint tabular digits as a job
line; a warning in `--warn`, an error in `--err`; no badge; it stays.

Narrow (60 columns) drops, in order: the extension statuses, the
thinking level, the cwd's leading directories, the context numbers;
the bar, the percent, the model, the state and the cwd's last
component stay, and the state keeps its reserved width. The dock sits
on the pane's bottom edge. Renders: `/tmp/koa-shots/composer-<state>-<theme>-<width>.png`,
states idle, working, waiting, exited, picker, toast, toast-err,
narrow. Approved by the user on 2026-11-10, as shown.

## Times end at one edge (user, 2026-11-10)

Every time on the page ends at the transcript column's edge. The user
message's block and the agent cards outset by their horizontal
padding, so the time inside them ends at the column's edge, and a run
line, a step line, a job line and a notification line have no right
inset, so their times end at the same edge.

## The user message is the accent at 18% (user, 2026-11-10)

The user message's block is `color-mix(in srgb, var(--accent) 18%,
var(--ko-bg))` (`--accent` is `--ko-color-4`), in place of the 5% gray
well, so it carries more weight than the agent message blocks, which
keep the 5% well; radius 8pt and padding 7pt 12pt. The user
chose it from 9, 13, 18 and 24% and from gray 12 and 16%. Every koa
mockup page has it; mockup.html's "User message" control keeps the
old treatments for reference.

Its time is not the faint gray: over the tint that read as dirty
(user, 2026-11-10). It is an accent ink, `color-mix(in srgb,
var(--accent) 60%, var(--fg))`, .8em terminal font as before, in
light and dark. The same for a blockquote in the user message (a
quote from ⌘O or a question control): the gray text read as dirty on
the tint (user, 2026-11-10), so `.msg.user blockquote` takes the
same accent ink and its 2pt bar the accent at 45% over transparent;
inline `code` in the user message takes the accent at 12% over
transparent in place of the gray well; a fenced block in the user
message is the accent at 10% over transparent with a 30% accent
edge, the text in `--fg`, no language label; the paths of sent
attachments (media.html) take the quote's ink. Nothing in the user
message is gray. user.html shows every state: one line, paragraphs
with a list and code, one quote with its answer, two quotes in one
message, a code block, attachments, a long message; light and dark,
wide and narrow. Renders: `/tmp/koa-shots/user-<state>-<theme>-<width>.png`,
states one, paras, quote, quote2, code, attach, long. agents.html's `data-ut` holds the two rejected
alternatives (fg over the tint, the bare accent) for reference.

## Question controls in a reply (questions.html; approved, 2026-11-10)

The "reply annotations" contract (docs/reply-annotations.md, and
docs/design-koa.md, "Reply annotations"): an
extension marks the questions of a final reply (range, kind, the
options of a choice), and the page puts controls in the prose. The
labels and the click rule are the TUI's (pi-infer-questions,
`extension.ts:333-360`), except that no blank line separates the
answer from its quote: a choice shows each option in
place, then Other; a choice with one option shows the option, then
Yes, Other; a yes/no question or a proposal shows Yes, No, Other; an
open question shows Answer. A click sends nothing: it puts the
question as a quote (`> ` lines) and, on the next line, the answer into the
composer, after the current text and a blank line; a second click on
the same question replaces its answer (Other replaces it with
nothing; a block per question; `answer()` in the mockup is the TUI's
function without its blank line, as the page has it since 0e4cea65).
The question's own text is not styled.

- **An option in place** (`.ann`): the question's own words as a
  button in the prose, the accent colour, a 1pt underline at 40%
  accent 3pt under the baseline (a link's is 35%: an option's is a
  shade stronger, and it is a button, not a link), 1pt horizontal
  padding, 3pt radius. Hover: a 12% accent fill and the underline at
  full accent. Selected (its answer is in the composer): the 18%
  accent fill (the user message's tint), the text in `--fg`, no
  underline, a 1pt outline of the same fill so the fill clears the
  descenders. An option that wraps keeps its fill across the break.
- **The labels** (`.ctl .ann`): chips 8pt after the question's end,
  4pt apart, in the question's line and font: .88em, the accent with a
  1pt edge at 35% accent, 5pt radius, 0 6pt padding, line-height
  1.45. Hover: the 12% fill and the edge at full accent. Selected: the
  18% fill, `--fg`, no edge. In a list item, a table cell or a
  heading, the chips follow the text where it ends; in a paragraph
  that goes on after the question ("Do you want the Linux check at
  all? It costs…") the chips sit between the sentences.
- The "Labels" control shows the TUI's form for reference (words
  with slashes, underlined, no chips); the chips are the proposal.
- **The composer** after a click: the plain Markdown, the quote
  lines (`> …`) in `--muted`, the answer on the next line in `--fg`,
  the cursor at the end; `.field .text` grows to 9 lines before it scrolls (6 before)
  so two answered questions show whole.
- Narrow: nothing changes in size; the chips wrap as words.

Renders: `/tmp/koa-shots/questions-<state>-<theme>-<width>.png`,
states reply (hover on "wait for CI" and on a "Yes"), answered (two
clicks), narrow; and `questions-reply-slash-light-wide.png` (the TUI's
labels). Approved by the user; the chips version is built
(docs/design-koa.md, "Reply annotations").

## `!` runs a command (bang.html; shipped 2026-11-10: 3695fb19, Tab completion 16c79407)

As pi's TUI: a message that starts with `!` is a shell command, not a
prompt. koa sends pi's `bash` RPC command (docs/rpc-commands.md,
"bash"; output streams as `bash_execution_update`), and pi stores a
`bashExecution` message, which the model gets as user text before its
next turn. `!!` sends it with `excludeFromContext: true`: stored and
shown, never in the model's context. `!` or `!!` followed by a space
is allowed; `!` alone is the mode with no command, and Return does
nothing.

**The composer.** The one mode cue is the font: while the text starts
with `!`, `.field .text` is `var(--ko-font-size)/1.5
var(--ko-font-family)` (the whole text, not only after the `!`). The
`!` is the accent at 600; the `!!` pair is `--muted` at normal weight
(a quiet run). The foot's state cell reads "run" or "run, quiet" in
`--muted` in place of "idle", so the row says what Return does; model,
context and cwd stay. No tag, badge or border change, no button.
Completion: `@` and `/` are off in this mode; path completion stays
(a command takes paths). Attachments: a command takes none. A drop in
`!` mode is refused with the usual line under the field ("a command
takes no attachments"); chips present when `!` is typed stay, and
Return does not send while they exist (the state cell "run" in
`--err`, tooltip "remove the attachments").

**The transcript.** A user-run command is a line of its own kind
(`.cmdrun`) in a run line's geometry, placed where it ran: a `!` in
the accent at 600 in the chevron's 9pt slot (a faint `!!` for a quiet
run, tooltip "not in the model's context"; nothing marks a `!` run),
the command in the terminal font .92em in `--fg` (`--err` when the
exit is not 0, as a failed tool's name), and at the right in the
time's place, `.8em` terminal faint: "exit N" in `--err` when N is not
0, "cancelled" for a cancelled run, then the duration. The output is
folded by default and opens on a click of the line: a step's guide
(4pt margin, 1pt `--hair`, 13pt padding) and a `pre` as a step's
output (.88em, `--well`, `--hair` edge, max 260pt, own scroll), in
`--fg`. While it runs, the spinner takes the `!`'s slot, the output
is open and streams in `--muted`, and turns `--fg` at the end. A
cancelled run keeps the output it got. Truncated output (pi's
`truncated`) ends with "… full output: <path>" in the faint terminal
font.

**Cancel, and a busy pi.** While a command runs and pi is idle, the
field stays in `!` mode with the text cleared, placeholder "running…
⎋ cancels", state cell "running Ns" with the breathing dot; Return
sends nothing, Escape cancels (pi's `abort_bash`), typing starts the
next message. While pi works, a `!` message runs at once, as pi 1.5.0
does (only the session record waits for the turn's end): its line is
appended at the end of the transcript, under the streaming reply, and
streams there while the reply goes on above it; the state cell stays
"working Ns" (the turn is the session's state; the command's spinner
says it runs); the field returns to the working placeholder "Steer
koa…". Escape then cancels the command first (`abort_bash`); a second
Escape aborts the turn.

**Tab completes, from bash** (user, 2026-11-10: Tab only, bash
only, where the command runs). Tab asks bash for the completions of
the word at the caret (bash-completion's functions where installed,
else command names and paths); nothing completes as you type. The
answer is plain words, so there are no kinds and no detail column.
One match: the word completes inline, with a space after it, or `/`
after a directory, as bash reports it. Several: the common prefix is
inserted inline first, then the list opens in the `/` popup's
geometry (`.complete.sh`): rows in the terminal font .92em in
`--fg`, bash's order, eight visible then scroll; a second Tab or ↓
moves, ↩ or Tab accepts, ⎋ closes, typing closes it (the next Tab
narrows). The list never opens by itself. None: the state cell reads
"no completions" in `--faint` for 1.5 s in place of "run"; nothing
moves (the cell's reserved width holds it). Slow (over 150 ms): the
state cell reads "completing…" with the spinner in the dot's slot
until the answer; Tab waits, typing cancels the request. Cap: 200
words fetched; over it, the last row "… N more, type to narrow" in
`.8em` `--faint`, not selectable.

Renders: `/tmp/koa-shots/bang-<state>-<theme>-<width>.png`, states
bang, bang2, runs, running, busy (both running), typing (`!` typed
while pi works), tab (five matches after the prefix), tab-none,
tab-pending, tab-cap. Shown to the user for a final look;
the spec went to the implementer the same day.

## The composer's focus border (2026-11-10)

The focused treatment (`--ko-focus` border) is a fact of the page, not
of the DOM focus: the composer looks focused whenever a keypress would
reach it. Rule: `.field.focus` is set when the document has focus
(the window is key and the pane is Kido's focused pane) and no other
text input of the page holds the focus (a dialog's field, a rename, a
search); the hairline shows otherwise. The page sets the class on
`focus`/`blur` of the window and on every focus change inside the
page; `:focus-within` is not used. Cases: a click or a selection in
the transcript keeps it focused (printable keys still go to the
composer); the completion popup, the model picker and a running `!`
command keep it focused (they are the composer's own, or typing starts
the next message); an open dialog card with its own field, and the
lightbox, show the hairline (keys go to them); pi exited shows the
hairline always (the field is disabled). The mockups already show the
treatment as a static `.focus` class and do not change.

## Built-in slash commands (commands.html; shipped: 172b8bcc)

koa runs seven of pi's built-ins itself through RPC: `/model`,
`/thinking`, `/compact`, `/session`, `/copy`, `/export`, `/quit`
(with `/name`, and `/resume` and `/new` from sessions.html). Every
other pi built-in (`/settings`, `/tree`, `/fork`, `/login`, `/reload`,
`/hotkeys`, …) gets one notice line in `--warn`, "/x is not available
in koa", and the text never reaches the model.

- **In the popup**: one list; the built-ins first, in a fixed order
  (model, thinking, compact, session, copy, export, name, resume, new,
  quit), then `get_commands` in its order; the kind column reads
  `built-in` in the same faint tone as `extension`, `template`,
  `skill`; the detail is pi's one-line description. The fuzzy filter
  runs over all together. Refused built-ins are not listed.
- **Outcomes** are lines in the transcript where the command ran, in
  the notice geometry (terminal .92em `--muted`, time at the right,
  12pt in): `/copy` "copied the last reply · N characters"; `/export`
  "exported <path>", the path in `--fg`, ⇧⌘-click Quick Look as a
  step's file label; `/model x` and `/thinking x` with an argument set
  through pi and give the existing "model: … · thinking …" notice;
  without an argument they open the foot's picker (the one the click
  opens), nothing in the transcript. A result with more than one line
  is an **info line** (`.info`, a job line's geometry: chevron, name in
  `--fg`, the rest muted, time right; closed by default, a click opens
  a body behind a step's guide): `/session` "name · N messages · $x"
  opening to a key/value grid in the terminal font (name, id, file,
  model, messages, tokens in/out/cache read/cache write, cost,
  context); `/compact` first a notice with the spinner "compacting…"
  while the state cell reads "compacting Ns" with the breathing dot,
  then the info line "compacted · 184k → 31k tokens" opening to pi's
  summary as prose; a failure "compact failed: <message>" in `--err`.
  `/quit` ends pi and koa; the pane closes as a shell's exit does;
  nothing is drawn.
  `/reload` (2026-11-12, unit koa-reload) replaces koa's process
  with a fresh one on the same session, only when idle. Before the
  serve stream drops, the old page shows "Reloading…" in the line
  where "Connection lost. Reconnecting…" shows, same element and
  styling, no spinner; the field is inert as while a dialog holds
  the keys (`#field[inert]`, the faded text), the foot's word stays
  "idle". Its popup row says "Reload extensions, settings and koa"; without
  a saved session (`--no-session`) it refuses with "reload: not
  without a saved session". The gap (1–2 s): koa stays
  in webview mode, so the app shows its own "The program is not
  serving" label; the pane never falls back to the terminal. The new
  page loads as a first load does, then one note line "reloaded" in
  the style of /resume's "session: …" note, time at the right; focus
  to the composer. Two layers (user): first pi reloads in-process
  (settings, extensions, skills, prompts; pi, the session, jobs and
  subagents stay), and only when the installed koa differs from the
  running one does koa restart itself, and only when nothing would
  be lost. The note is "reloaded" after layer 1 alone and after the
  full restart alike. When a newer koa is installed but the restart
  did not run, one info note (muted, not a warning: nothing failed)
  with the reason after a middle dot: "reloaded · a newer koa waits
  for 3 jobs" ("1 job"), "reloaded · a newer koa waits for 2
  subagents to report" ("1 subagent"), "reloaded · a newer koa
  needs a saved session", "reloaded · a newer koa waits; ko-pi did
  not answer, try /reload again". Refused while a turn, a `!` command, a queue, a
  dialog or the editor float is open, on the path the other commands
  use, with the text "reload: not while a turn, a command, a queue,
  a dialog or an editor is open" where that path shows one.
  While the C-g editor float is open (user, 2026-11-13): the field
  stays inert and takes `editing`: the whole field at 45% opacity in
  both themes, the hairline border, the draft visible under it, the
  foot's status cell "Editing…" (the editor's name in the cell's
  tooltip; the 15ch cell must never cut the name) alone at full
  opacity; model,
  thinking, context, cwd, the chips and the queue dim with it and take
  no click; `cursor: pointer` over the whole composer, and a click
  anywhere on it focuses the editor's pane (Kido.app raises and keys
  the float) without moving the page's focus; Escape and Return do
  nothing on the page. The editor's close removes the class and
  returns the text and the focus as today.
  After a restart or a crash the in-process subagents' records are
  cleared (koa's registry is the truth; a normal stop leaves no row);
  a restart adds one info note "restarted · 2 subagents ended" ("1
  subagent ended"); a crash says nothing. A submitted `@name` that
  matches no agent of the scope and no existing path gets one
  warning note after the user's block, "@name matches no agent"
  ("@a, @b match no agent"); the text goes to the model unchanged;
  nothing before submit, nothing for a path (2026-11-16).
  `/restart` (2026-11-12) quits pi and starts a new one on the same
  session, koa, the page and the transcript staying; popup "Start pi
  again on this session". During: "Restarting pi…" in the line where
  "Reloading…" shows, the field inert, the foot "starting" then
  "idle". Success note "pi restarted". Refused like /reload:
  "restart: not while a turn, a command, a queue, a dialog or an
  editor is open". Deferred (info, pi stays): "restart waits for 3
  jobs", "restart waits for 2 subagents to report", "restart needs a
  saved session", "restart waits; ko-pi did not answer, try /restart
  again". A failed start: "pi did not start: <message>" (error) and
  the exit card.
- **Prompt history**: Up on the first line of an empty or unedited
  field puts the previous submitted prompt in the field, Down the next;
  a draft typed before Up comes back with Down. No cue: the field looks
  as when the user types. **Alt-Up** takes the queue back, the same as
  the queue's button; the list goes, the texts stand in the field; no
  other cue.

Renders: `/tmp/koa-shots/commands-<state>-<theme>-<width>.png`, states
pop, pop-filter, outcomes, picker, session, compact.

## Sessions inside the page (sessions.html; shipped: 55094dd9)

`/resume` opens a session picker; `/new` starts a new session (pi's
`switch_session`, `new_session`). The picker is a card in the dock
above the field, where an extension's dialog card sits (`.sess` in
the `.dialogs` column: the dialog's 9pt radius, hairline and glass;
padding 9pt 10pt 8pt; the column's 10pt under it; rows are a grid,
name and first message in the first column, date over count in the
second), so the transcript stays visible and the keys are the
dialog's; the composer under it is inert (text in `--faint`).

- **Top row**: the search field (focused; fuzzy over name and first
  message, as pi's selector), and at the right a two-part scope "this
  folder" / "all" (.8em terminal, 6pt radius, the on part in
  `--well2`); ⇥ switches it; this folder is the default.
- **Rows**, newest first, 4pt 8pt padding, 6pt radius, current in
  `--well2`, 8 visible then scroll: the name in `--fg` (the first
  message when unnamed), then `current` for the open session (.8em
  terminal faint) and, in "all", the folder in faint .9em; the first
  message under it in `--muted` .92em, ellipsized; at the right the
  date (time today, date otherwise) over the message count, .8em
  terminal faint, tabular. ↩ on the current row does nothing.
- **Empty**: "no sessions in this folder" with the hint "⇥ all
  folders" under it; "no match" with a search.
- **Switch**: the card closes, the transcript empties, the field is
  inert with "loading…", the state cell reads "loading"; then the
  session's transcript, scrolled to the end, with one notice line
  "session: <name> · N messages"; the foot shows its model and
  context. `/new`: an empty transcript and the notice "new session".
  The queue goes with the old session; the draft in the field is kept.
- **While a turn or a `!` command runs**: pi's confirm dialog first,
  "Switch session?", "koa is working on a turn; it will be aborted."
  or "a command is running; it will be cancelled.", ⎋ Cancel, ↩
  Switch; Switch aborts (`abort` or `abort_bash`), then opens the
  picker or starts the session.

Renders: `/tmp/koa-shots/sessions-<state>-<theme>-<width>.png`, states
pick, pick-all, pick-search, pick-empty, loading, after, confirm.

## Markdown inside a thinking step (thinking.html; shipped: 5e339b57, rendered when the step is expanded)

An expanded thinking step (`.think`) renders its text through the
reply's Markdown renderer. The rule: the thinking tone stays. The
whole block is `--muted`; bold is weight alone; code and quotes go a
shade quieter, not louder; headings are body size; the 260pt scroller
is the one scroll. The reply's `.prose` rules for `p`, `ul`, `ol`,
`li`, `blockquote`'s geometry, `a`'s geometry, `hr` and `table`
apply as they are. What changes, on `.think`:

- `.think`: `font: 1em/1.5 var(--prose); color: var(--muted);
  white-space: normal` (was pre-wrap); `max-height: 260px; overflow:
  auto; padding: 0 12px 0 0; margin: 0`. `.think > :first-child
  { margin-top: 0 }`, `.think > :last-child { margin-bottom: 0 }`.
- `li::marker`: `--faint`. `strong`: weight 600, colour inherited.
- `code`: `.92em var(--ko-font-family)`, colour inherited, background
  `--well` (the reply's inline code has `--well2`), radius 4pt,
  padding 1pt 5pt.
- `pre`: `.88em/1.45`, colour inherited, `--well`, 1pt `--hair`,
  radius 7pt, padding 8pt 10pt, margin .3em 0 .75em, `max-height:
  none`, `overflow: auto hidden` (horizontal scroll only), no
  `.lang` label (`display: none`). `pre code`: no background, 1em.
- `h1`–`h6`: `600 1em/1.35`, colour inherited, margin .8em 0 .3em.
- `blockquote`: colour `--faint`, bar 2pt `--hair2`, margin .3em 0
  .75em. `hr`: 1pt `--hair`, margin .6em 0. `table`: .95em, `th`
  `--faint`, rules `--hair`. `a`: colour inherited, 1pt `--hair2`
  underline (not the accent).

Renders: `/tmp/koa-shots/thinking-<state>-<theme>-<width>.png`,
states basic, rich, long.

## The foot at narrow widths (foot.html; shipped: 9b218d82)

Shipped with the 540, 340 and 200 steps below as CSS px of the field container (page.css), plus a 630px step for the extension status that the mockup does not draw.

The composer's foot drops its cells by its own width, a container
query on `.field` (`container-type: inline-size`), not the window's:
the field is what the cells must fit, whatever the pane and the
sidebar do. The pane is the foot plus 74pt (the composer's 24pt and
the field's 12pt on each side, and the 1pt borders).

- **Full**, foot 540pt and up: state · model · level · context bar,
  numbers, percent · cwd. Natural widths at 13px: state 106 (its
  reserved width), separators 1 + 10 each side, model 145 (level 38 of
  it), context 137 (numbers 63), cwd 100.
- **Step 1**, under 540: the thinking level, the cwd's leading
  directories and the context numbers go (`.lvl`, `.cwd .lead`,
  `.ctxc .n` display none; `.ctxc` min-width 44px + 6px + 3ch). The
  bar and the percent stay, "kido" stays.
- **Step 2**, under 340: the model, its separator, the gap and the
  cwd go (`.model`, `.model + .sep`, `.gap`, `.cwd`); the context takes
  `margin-left: auto`: the state at the left, the context at the
  right.
- **Step 3**, under 200: the context and the state's separator go
  (`.ctxc`, `.st + .sep`); the state's reserved `min-width` is
  released (0, overflow hidden, its text ellipsized), so the widest
  texts ("working 12m 34s", "completing…") fit a 200pt foot and
  ellipsize under it.
- The cwd is `flex: 0 1 auto; min-width: 0; max-width: 40cqw` with an
  ellipsis at its end, in every step, so a deep directory never pushes
  the other cells; the gap has no min-width (`padding: 0 5px`).
- **Reachable**: `/model` and `/thinking` open the pickers the hidden
  cell opened; `/session` lists the model and the context numbers;
  the cwd is the pane's title in the sidebar and in `/session`.
- The state texts of every mode go through the same steps with the
  cell's reserved width intact in steps 1 and 2: "run", "run, quiet",
  "completing…" with the spinner, "compacting Ns", "working Ns".

Renders: `/tmp/koa-shots/foot-<row>-<theme>.png`, rows idle, run,
quiet, comp, compact, work, cwd; each row the foot at 600, 480, 300,
200 and 150pt. Measured: no foot overflows at any width.

## refine.html: the width, the user message, agent lines, @names (2026-11-11, proposals)

Four refinements the user asked for, on the shipped page. Decided
2026-11-11: the width (1); the user message is F, solid accent (2),
with its dark rule below; the agent line without the chevron, its
lead "kind to @name relation" one run of text with ordinary spaces
(3); the links (4). Every item's time ends on the transcript's text
edge: the user block's time sits `--pad` in from the block's edge,
the agent line's and the run's at the edge.

**1 · The composer's width.** Shipped: the transcript's text is 680pt
(720 − 2×20), the user block 704 (−12/+12 of margin), the composer's
field 672 (720 − 2×24) and its text 648. Proposed: the composer takes
`--side-pad` − `--pad` (8pt; 4pt narrow) of padding and the field
`--pad` (12pt) of its own, so the field is the user block's width
and its text edge is the assistant's. `.dialogs` and `.exited` take
the same 8pt. One rule in page.css; nothing moves in the transcript.

The sides do not shrink in a narrow pane (user, 2026-11-11): the
narrow 12pt/8pt put the user block and the field 4pt from the pane's
edge, where they blended with its border. `--side-pad` stays the wide
value and `--pad` too at every width (20pt and 12pt then; 24pt and
16pt since item 6); the narrow rule keeps only its
top and bottom (10pt and 6pt in the transcript, 10pt under the
composer). The "Compact spacing" table's narrow row becomes
10 20 6.

**2 · The user message**, six treatments, a picker on the page:
A the shipped 18% accent tint; B a bubble at the right, at most 82%
wide, the time under it; C no fill, a 2pt accent bar, the text on
the transcript's text edge; D the composer's own card (background,
`--hair2` hairline, 9pt radius, a 1pt shadow at 8%), the time faint;
E no block, the text at 600 and 1.04em, a `--hair` rule under the
message; F the accent as the fill and `--ko-bg` as ink in a light
theme; in a dark theme (`--ko-appearance: dark`) the fill is the
accent at 82% over `--ko-bg` and the ink is white, because the dark
themes' accent is darker and the page's background on it does not
read. The quote, the code and the paths take the ink at 80%, 18%
and 80%; `pre code` keeps no background.

**3 · A message between agents is one line**: `kind` to|from
`@name` relation, the first line of the body ellipsized in the muted
tone, the time at the right on the text edge; .95em prose like a
run line, without a chevron (the picker shows it with one). The lead
is one run of text with ordinary spaces, not flex items with gaps;
an 8pt gap separates it from the body's start. A click opens the body under the line, 16pt in with a
`--hair` left rule like a run's steps, and hides the ellipsized
start; a second click closes it. A refused call or a failed spawn
colours the kind, the name and the start red. This replaces
agents.html's card: no fill, no two-line header.

**5 · One look for run lines and agent lines** (user, 2026-11-11;
the "Rows" picker, `unified`). A run line and an agent line (and a
job line, which drops its end text and shows a failure by its name
in `--err`; unit koa-jobline) are the same row: no chevron (the
whole line is still the
click that opens it); the prose font at the row's .95em for the tool
names, the step names and the lead, the mono only for a command or a
path inside a step; the time in the prose font at .8em with
`font-variant-numeric: tabular-nums`. While a tool runs the line
says its name, then the spinner 6pt after it ("bash ◌"), not the
command. Every row is indented by `--pad` (12pt; 16pt with item 6)
from the transcript's text edge; an opened run's steps and an
opened agent line's body (its bar at the row's start, the text 12pt
in) indent from that point, never back to the edge; the times end on the text edge, as the user
block's timestamp does (the run line's 12pt right padding goes).
Consecutive run, agent and job lines sit 2pt apart (4pt at first;
the user asked for less); the last of the group keeps the 14pt gap
after it, and an opened row keeps 14pt
under its body.

**6 · The composer's padding** (user, 2026-11-11, v3 of three): the
scale grows so the alignment of item 1 holds. `--side-pad` is 24pt
and `--pad` 16pt at every width, so the transcript's text is 672
wide, the user block and the field 704, and both sit 8pt from the
pane's edge; the user block pads 8pt 16pt, the field 12pt 16pt 8pt
(was 9pt 12pt 5pt). The narrow rule keeps only its top and bottom,
as decided for the narrow padding.

**7 · Radii** (user, 2026-11-11): the composer's field and the user
block are 12pt (were 9pt and 8pt, which looked square beside
macOS 27's rounder controls); 12pt is the pane capsule family's
radius. The other radii (code blocks 7pt, chips, the queue 8pt)
stay.

**8 · The composer's depth** (user, 2026-11-12: "border", the
shipped look without the glow). The user first chose the pane
capsules' contact treatment (11 Nov), then preferred the old border:
the field keeps its 1px edge at 22% of the foreground, the inset top
highlight at white 28% and the 1pt/3pt shadow at 10%, and loses only
the 6pt/22pt shadow at 14%, which on a dark theme read as a halo.
The glass background and blur stay. The same for the dock's dialog,
exited card and queue, which share the field's rule. The mockup's
"Composer depth" picker keeps contact, flat and fade for comparison.

**9 · Streaming reveal, "G"** (user, 2026-11-11; chosen on the iOS
comparison page ~/Workspace/kido-ios/app/design/ios/streaming.html,
column G, and wanted on the desktop page too). The reply does not
grow by the chunk; it grows by blocks and by slices of whole lines.

- A finished top-level block (the lexer's token: paragraph, list,
  code fence, table, heading, quote) appears when it is complete,
  that is when the next block has begun or the item is final, and
  grows in over 220 ms (max-height from 0 to its height, opacity
  0 to 1). While a block is still arriving, the working indicator
  (the bare dots row of "Running: one indicator", indented like a
  tool row) stands under the arriving block, where the caret stood.
- Height cap: while the tail block is incomplete, when its hidden
  part reaches 40% of the transcript's viewport height, the page
  reveals a slice of whole lines and repeats: a paragraph by its
  wrapped lines, a code fence by lines, a table by rows, a list by
  items; never a half line. A nested block (a quote with a code
  fence, a list with a fence) is not sliced: it appears whole. The
  slice is a clip of the whole tail block at the bottom of its last
  revealed line (2026-11-16): the hidden text is in the page for at
  most one time cap, so find-in-page or a drag selection can reach
  it in that time.
- Time cap: when nothing was revealed for 1.5 s and text waits,
  reveal the whole lines that arrived.
- The reveal is rendering only; it moves no scroll of its own
  (2026-11-15, the Auto-scroll section): while the reader follows,
  the follower writes the bottom instantly before each paint the
  reveal changes, so the grown block is in view at once; a reader
  who scrolled up keeps their anchor and is never pulled down. The
  earlier glide per reveal is dropped.
- A code fence with more than 15 lines is folded: the first 15
  lines, then a full-width bar "Show N more lines" under the pre
  (the well's fill, a hairline above, the accent colour, the
  prose at .88em), a click expands it in place for good. While a
  fence streams it stays folded and the bar's count grows, so a
  long fence costs at most 15 lines during the stream. The fold
  applies to every fence in the transcript, history included.
- Annotations, agent cards, images and the user block are not
  touched: marks apply to final text only, which is never sliced.
- Reduce Motion (2026-11-16, the gap @ko found): the chunking is
  not motion and stays as it is: blocks still appear when complete,
  the height and time caps still cut slices of whole lines, the
  fence still folds. Only the animation goes: a block appears in
  one frame at its full height and opacity, no 220 ms grow, no
  scroll travel; the dots are static. So the reader sees the same
  blocks at the same moments, without movement.

**4 · `@name` links to the agent's pane.** Every name of an agent
(an agent line's, a `@name` in the answer's or the user's prose, a
`list_agents` step) is an `<a class="who">`: 600, the text's colour,
no underline; hover is the accent with a 1pt underline at 45% and
the hand pointer; the title is "Focus the pane of @name". A click
asks the host to focus that pane, as a sidebar click does. koa links
a `@name` in prose only when the name is in the agent extension's agent list at
render time; otherwise it stays text. An ended agent keeps 600 in
the muted tone and is no link.

## lines.html: one row for every notice; the queue as dimmed user messages (approved 2026-11-12)

Two requests of the user, approved as drawn ("ok let's implement"):
A as drawn; B in the dock with the `tint` dimming, and no click-to-
edit on a queued block (not asked for; Option-Up takes all back).
On refine.html's language, with its decided pickers (solid user message, unified rows, v3 padding, 12pt
radii, the border depth). The inventory of what the transcript
renders today is /tmp/koa-notices/inventory.md (26 families).

**A · Every notice is one row.** The user: "all of them in the same
style as agent messages and tool calls; some are monospace now".
One element, the row of item 5, replaces `.note` (the mono
one-liners), `.info` (the mono disclosure with the chevron), `.msg.
summary` (the prose block without a time) and the reply's `.msg.err`
(the prose error block without a time):

- The row: prose `.95em/1.5`, `--muted`, `padding-left: var(--pad)`
  like a run line, the text one line with an ellipsis, the time in
  prose `.8em` `tabular-nums` `--faint` at the transcript's text
  edge. No chevron. Consecutive run, agent, job and notice rows sit
  2pt apart; the group keeps the 14pt gap after it; an opened row
  keeps 14pt under its body (the rule of item 5, extended).
- Colour: `info` muted; `warning` the text in `--ko-color-3`; `error`
  the text in `--ko-color-1`; the time stays faint in every case.
  Inside the text only a path or a session file is `--mono .92em`
  in `--ko-fg` (as a step's path); everything else is the row's
  colour, regular weight; no `.nm` in the foreground any more.
- Opening: a row with more than its line (a body, a text of more
  than one line, or one line that does not fit, like the routed
  runtime's announcement) opens on a click of the whole row, the hover
  lifting it to `--ko-fg` and the pointer a hand, like a run. The
  body sits `var(--pad)` in with the hairline at its left and 12pt
  of padding, the text in `--ko-fg` prose, like an agent line's
  body. A row with a lead (session name, "compacted") hides its
  preview when open and keeps the lead; a row without a lead keeps
  its first line as the header, and the body is the rest.
- The session's statistics open to the same key-value grid in
  prose: keys `--faint`, values `--ko-fg`, the id and the file in
  the mono. The compaction summary opens to its text as prose
  paragraphs, no 200px cap (the agent body has none either).
- Texts, one for each family of the inventory (family numbers):
  1–3, 10–12 `notify`: the text as given, by level; koa's own are
  "Session name set: Release", "Unknown thinking level: max", the
  routed runtime's announcement, "runtime devbox: <error>; its
  context files are not read", "Editor pane not closed: <error>";
  an extension's text is whatever it sends (none drawn).
  4–5 reload: "reloaded", "reloaded · a newer koa waits for 3 jobs".
  6 "model: claude-opus-5-5 · thinking high"; "Unknown thinking
  level: x" warning. 7 "session: Release · 12 messages", "new
  session". 8–9 as today, warnings. 13 "copied the last reply · 2.1k
  characters". 14 "exported" + path (mono, previewable). 15 "sidebar-
  right · 212 messages · $1.42", opens. 16 "compacting" + the
  spinner 6pt after the word (the run line's). 17 "compacted · 184k →
  31k tokens", opens to the summary. 18 "compaction cancelled". 19
  "compaction · <message>" in error colour (no "failed", the rule
  of runs). 20 the reply's error: the error text as an error row,
  with its time, 14pt after the reply like any row group (merged
  into the row). 21 stays in the run. 22–23 are the reference and
  do not change. 24 a custom notice: its first line as Markdown;
  opens when it has more lines. 25 a summary from the history:
  "compacted · <first words…>" or "branch · <first words…>", opens
  to the whole text; with the message's time when known, else no
  time (merged with 17's look). 26 stays inside the step's detail;
  only the read-with-image note there goes to prose `.85em` faint.
- Disappears: the chevron of `.info`; the `.note`/`.info` split;
  `.msg.summary`; `.msg.err`'s block; the 200px cap on the summary.
  Nothing outside the transcript changes (foot toasts, `#error`, the
  dialogs, the exit card).

**B · The queue: dimmed user messages with a ×.** The user: "like a
user message but dimmed, with a close icon to remove them from the
queue".

- Each queued steer and follow-up is the user block itself: the same
  Markdown renderer, 12pt radius, `8px var(--pad)` padding, the full
  block width, dimmed, but one line only (user, 2026-11-12: long
  queued messages must not take the pane): the first line of the
  text, ellipsized, blocks and paragraphs flattened into it;
  attachments as a paperclip and a count after the text, in the
  block's ink at 80%. Steers first, then follow-ups, in pi's order;
  6pt between blocks.
- Dimming, three on the picker; recommended `tint`: fill the accent
  at 14% over the page (22% in dark), the ink the accent at 55%
  toward the foreground (35% in dark), the user block's quote ink.
  `opacity` shows the solid block at 45% (inline code washes out);
  `outline` a dashed accent hairline with muted text.
- The kind sits where the sent message's time sits: "steer" or
  "follow-up", prose `.8em`, in the block's ink mixed to muted. A
  sent message has a time and no kind; a queued one a kind and no
  time.
- The ×: 16×16, the attachment chip's remove button (9px glyph,
  1.6 stroke, 4px radius), at the right after the kind, on the first
  line, in the ink at 55% opacity; hover: 100% and a 14% fill of the
  ink; tooltip "Remove from the queue". Not in the Tab order (the
  composer's buttons are `tabindex=-1`). A click removes that one
  entry from pi's queue and the block goes; nothing enters the
  draft. pi has `clear_queue` only: koa clears and re-queues the
  others with their kinds and attachments, in order.
- Placement (user, 2026-11-12: "stick queued messages to the
  composer"): the dock, above the field, as today. The blocks are
  opaque over the scrolled transcript (the tint over the page's
  background, a 1pt/3pt shadow at 10%), 8pt above the field. The
  scroll: the transcript's bottom padding is the dock's whole height
  (the ResizeObserver on the dock that sets it today), so the last
  line of the reply stays readable above the first queued block.
  The user's concern is the reply that streams while blocks wait:
  "the bottom" that follow-bottom keeps in view is the top of the
  dock, queue included, so every new line of the reply (and every
  block that strategy G reveals) lands above the queue, never under
  it; a block that arrives or goes changes the padding in the same
  frame, and a view at the bottom stays there, a view scrolled up
  keeps its scrollTop. When pi takes a steer mid-turn, its block
  leaves the dock and the sent block appears in the transcript, and
  the same rule keeps the end in view. The first proposal,
  the transcript's end, stays on the picker for the record.
- Gone: the "N queued · take back" footer and the mono `steer` /
  `follow-up` tags. Option-Up still takes every entry back into the
  draft, as today (the only keyboard path; a per-entry take-back is
  not in this proposal). Escape's stop keeps its take-back-then-abort.
- Open for the user: should a click on a queued block's text take
  that one entry back into the composer for editing? Recommended
  yes, as a later step; not drawn.

Renders: `/tmp/koa-shots/koa-lines-{lines-a,lines-b,lines-a-shipped,
lines-a-narrow}-{light,dark}.png`, `koa-lines-queue-{tint,opacity,
outline,dock,narrow}-{light,dark}.png`.


## The view bar: a subagent's transcript in koa's page (2026-11-13, spec)

Subagents are sessions of koa's process (docs/design-subagents.md): a click on
a subagent's sidebar record switches the page to that agent's view.
The breadcrumb pill that Kido.app drew for descendant panes moved into
the page, with its geometry (app/design/sidebar/NOTES.md, the
breadcrumb; app/design/pane/NOTES.md, the capsule family).

- **Placement.** A capsule pinned at the top left of the pane, over
  the transcript, outside the scroll: inset 8pt from the top and the
  left, 22pt high, 8pt radius, at most the content column's width
  minus 16pt. The transcript scrolls under it; while the bar shows,
  the transcript's top padding grows by 30pt so the first item is not
  under it on a fresh view. The composer, the dock and the queue do
  not move. Root view: no bar.
- **Look.** The capsule family: fill the page's background mixed 8%
  toward the foreground, a 0.5pt edge at 16% of the foreground
  (14% in dark), the contact shadow (black 8%, y 1pt, blur 2pt;
  dark 30%, 1pt, 3pt); the theme's `--ko-*` only, no light/dark
  branches beyond those two numbers. Text .85em prose (≈11pt), 8pt
  side padding, 5pt between items. Content, left to right: the back
  control "‹" (a button, the foreground at 55%, 16pt wide, hover to
  the foreground; it goes to the parent), then the path from the root:
  each ancestor a button in the muted colour (hover: the foreground,
  no underline, the pointer a hand), "›" separators at 35%, the
  viewed agent's name last in the foreground at 600. The root's name
  is koa's name as the sidebar shows it ("@ko"); the agents' names
  carry the "@" of the sidebar row.
- **Overflow**, never clipping: shorten the middle ancestors first to
  one "…" button (a click opens a plain list of the hidden ancestors
  under the bar, in the completion popup's style, one row each, a
  click switches); then ellipsize the remaining ancestors' names to
  60pt each; then the viewed name; if the viewed name would have
  under 40pt, drop the back control's label last. Depth is at most 8.
- **The switch**: instant, no animation; the new view's transcript
  replaces the old at its end (follow-bottom); the bar appears or
  goes with it. The sidebar's click, an `@name` link and the bar's
  buttons all go through the same switch.
- **The composer** targets the viewed agent (the plan): its
  placeholder names it, "Message @reviewer…" / "Steer @reviewer…";
  the root keeps "Message koa…"; the foot shows the viewed agent's
  status, model, context and cwd (the plan's per-agent state). A
  command refused outside the root (`/new`, `/resume`, `/reload`,
  `/restart`, `/quit`) says "<command>: only in @ko's view" as the
  warning line.
- **The sidebar** marks the shown record: the viewed subagent's
  record row takes the focused-row fill (systemFill, 10%) and the
  semibold title, and koa's pane row drops its fill while a subagent
  view is shown (the pane stays the active pane; the window tab and
  the pane title stay koa's); the root view puts the fill back on the
  pane row. Nothing else in the sidebar changes: the records' status,
  clocks and folds are as today.

## Auto-scroll, the "new messages" divider and "↓ Latest" (rewritten 2026-11-15)

The user's model after the research into chat UIs (use-stick-to-
bottom, assistant-ui, Virtuoso, TanStack Virtual, LibreChat, LobeChat,
Open WebUI): the scroll has two states and one animation.

- **States.** `following`, or `reader(anchor)` with an anchor of item
  id and pixel offset. A third case, restoring a saved view, is a
  `reader` anchor applied once at the switch. There is no glide
  while following.
- **Following writes the bottom instantly.** While the pane is
  focused and the state is `following`, the page sets the scroll to
  the bottom before every paint that changes the layout: streaming
  text, a revealed block, an image that loaded, a fold, the dock's
  height (the queue, a dialog, the exit card, the composer growing),
  a viewport resize, the typing dots going. The block reveal
  animation (strategy G) stays as rendering; the scroll follows the
  measured layout frame by frame, never animates toward it. Nothing
  flashes, because the write happens before the paint.
- **Leaving following.** Only the reader's input leaves it: a wheel
  or trackpad scroll, a touch drag, a key (Page Up, Home, the arrows
  in the transcript), a scrollbar drag. A layout change never leaves
  it. The state becomes `reader(anchor)` at the item under the
  viewport's top and its offset.
- **Keeping the anchor.** In `reader`, every layout change keeps
  the anchored item where it is: content above it (older history
  loaded, a fold above, an image above) moves the scroll by its
  delta; content below changes nothing. The anchor's item being
  removed moves the anchor to the next item below (or the bottom
  when none).
- **Resuming following.** Only three things resume it: the reader
  reaches the bottom (within 1px, by any input); the user's send
  from the composer; a click on "↓ Latest". Nothing else: not a
  focus change, not a turn's end, not a layout change.
- **Focused.** `document.hasFocus()` and `visibilityState ===
  "visible"`. Not focused: the state is kept as it is, but a
  `following` page does not write the bottom while not focused (new
  items append without moving the scroll; the first such append
  places the divider); on the return of the focus the page is at its
  old position with the divider and the button, and it resumes
  following only by the three ways above. Browser mode: the same,
  the focus the browser window's.
- **New items** (user, 2026-11-15): an item is new only if it is an
  assistant message with visible content (text, or a run with at
  least one step shown). Nothing else counts and nothing else places
  the divider: not the user's own items, not agent cards, job rows,
  notices, command results, summaries or `!` output. Counted once at
  first append; streaming growth adds nothing. The divider and the
  count follow the same rule, so the divider stands above the first
  new assistant message, and the rows between it and the previous
  content (a notice, a job row) are above the rule.
- **The divider.** One rule across the transcript's text width: a
  1px line in the accent at 35%, the label "new messages" centred in
  a 6pt gap, prose .8em 500 in the accent, 14pt above and below. It
  appears above the first assistant message that appends while the
  state is `reader` or the pane is not focused; later ones extend the
  region; never a second one. It goes when the state becomes
  `following` with the pane focused, on the user's send, on a view
  switch, a session switch, `/reload`, `/restart` and `/new`.
- **"↓ Latest".** A capsule centred in the content column 8pt above
  the dock's topmost element (the queue's first block, else the
  dialog card, the exit card or the field): 24pt high, 12pt radius,
  padding 0 10pt, the field's material (the background at 72% with
  the blur), a 0.5pt edge at 16% of the foreground (14% dark), the
  contact shadow (black 8%, 1pt, 2pt; dark 30%, 1pt, 3pt), text prose
  .85em in the foreground: "↓ Latest" while nothing is new, "↓ 3
  new" ("1 new") while new items are below the viewport. Shown while
  the state is `reader`, focused or not, and the bottom is farther
  than the threshold below (2026-11-17, user); 120ms fade; the pointer a
  hand; it never takes the focus; pinned with the dock. A click is
  **the one animated scroll** of the page: one interruptible scroll
  toward the bottom (about 250ms, re-targeted each frame while the
  bottom moves; any reader input cancels it and stays `reader`);
  when it arrives the state is `following` and the divider goes.
  Reduce Motion: instant.
- **The threshold.** In `reader`, show "↓ Latest" when
  `scrollHeight − scrollTop − clientHeight > clientHeight/3`.
  Once shown, hide only when the distance is less than `clientHeight/4`.
  Re-read both lines on resize. Keep the 120ms fade in both directions.
  "↓ N new" shows at any distance in `reader`. Following resumes only
  within 1px of the bottom, by any input. Between 1px and the threshold,
  the state stays `reader` without a pill; new content does not pull
  the reader down (user, 2026-11-17).
- **The user's send** sets `following` and writes the bottom in the
  frame the sent block appends; the divider goes and the button
  hides; focus or not; browser mode too. A send that is not the
  user's (a delivered steer, a programmatic message, a queued
  follow-up pi takes) is a new item under the normal rule.
- **A view that is not shown** (a subagent view) is a not-focused
  pane: the page remembers each view's state on leave and restores
  it on return, instantly: `reader(anchor)` restored with the divider
  above what arrived meanwhile and "↓ N new"; `following` restored at
  the end, no divider and no button.
- **The typing dots at the turn's end** go in one frame; following
  writes the new bottom in the same frame, so the text moves down by
  the dots' height at once. The earlier 220ms collapse is dropped:
  the one animation is "↓ Latest".
- **Kept animated, and why.** Only "↓ Latest" scrolls animated: it
  is the reader's request to travel, and a jump would lose where
  they were. Everything the layout does under a following reader is
  instant in the scroll, because an animated follow and a streaming
  layout fight each other, which was the "sometimes it jumps". The
  glide the reader sees comes from the slide below, which moves no
  scroll.
- **The follow slide** (user, 2026-11-16: "scroll just jumps to the
  latest"; the glide comes back without touching the scroll). While
  `following` and focused, the scroll is still written to the exact
  bottom before the paint, and the transcript's content (the one
  element that holds every item, the dots row and the bottom
  padding; the dock is outside it) is offset down by the amount the
  bottom moved and eases back to 0: `transform: translateY(offset)`,
  so the frame first shows what was in view before, and the new
  content slides up into place from behind the dock. One mechanism
  for everything that moves the bottom: a revealed slice, a block
  that completes, a new item, the dots row appearing or going, the
  sent block, a loaded image, the composer growing (the dock's
  height change moves the bottom; the content slides, the dock
  does not). The grow of a block (strategy G's 220 ms) adds its
  frame-by-frame deltas to the same offset, so a growing block and
  a revealed slice read as one motion.
  - Offset and timing: on each bottom change by `h` px, `offset +=
    h`; the offset eases to 0 over 180 ms `ease-out` from its
    current value, the animation restarted on each change, so
    content arriving mid-slide retargets from where the content is
    now and never steps back. The offset is clamped to the
    viewport's height: a burst larger than the viewport starts
    from one viewport away, never from further, so a slide is at
    most one screen and about 180 ms. A bottom change downward
    (content removed, the dots going, a fold) adds a negative `h`:
    the content slides down the same way.
  - Not following: no slide. The reader's anchor keeps its item in
    place, exactly as before; nothing moves for them.
  - The user's send: `following` and the exact bottom in the frame
    the sent block appends; its height goes through the slide like
    any bottom change when the reader was already following; when
    the reader was up, the jump to the bottom is instant and only
    the sent block slides in (the offset is the block's height,
    not the distance travelled).
  - No slide: a view switch, a session switch, a restored view,
    history loading above, `/reload`, `/restart`, `/new`, the first
    paint of a transcript, a resize. The "↓ Latest" travel is
    unchanged (it is scroll, not the slide); when it arrives,
    following begins with offset 0.
  - Reduce Motion: no slide, offset always 0; the layout is as
    today, instant.
  - Nothing else changes: the write before paint, the divider, the
    counts and the states are as above. The slide is a transform on
    one element, so it costs no layout and cannot lose a follow:
    `scrollTop` is exact at every frame, whatever the offset shows.

## The job page (job.html; 2026-11-15, approved)

A background job (async_bash, a bash call gone to the background)
becomes a view of koa's page, as an in-process subagent is: a click
on its sidebar record switches the view, the record is `selected`,
the pane row's fill goes, the pane row's click (or the view bar's
back) returns to the agent. No float, no second pane.

- **The view bar**: the job under the agent that started it: "‹ @ko
  › make-verify", or "‹ @ko › @sidebar-right › main-watch" for a
  subagent's job; the job's name is the last item, 600; the ancestors
  switch to their views.
- **The header** (the transcript's column, under the bar): the name
  at 1.15em 600 with a "service" tag (11pt, a hairline pill) when it
  is one; the command in a mono block (the pre's well, wrapping);
  one facts line in the muted prose: "started 14:31 by @ko · on this
  Mac" (or "on runtime devbox") · "log <path>", the path mono,
  previewable as a step's path (⇧⌘-click Quick Look in Kido; a click
  opens the file in browser mode).
- **The output**: the log as text in the mono at .88em, wrapping
  (`pre-wrap`, `overflow-wrap: anywhere`), ANSI SGR colours mapped to
  the theme's `--ko-color-N` (bold, dim and the 16 colours; every
  other escape stripped; no cursor movement: a progress bar that
  rewrites its line shows as its last state, carriage returns
  collapsing the line). Live: the page appends what koa's tail
  streams, with the transcript's follow rule: following at the
  bottom, the position kept otherwise, "↓ Latest" above the foot
  while not at the bottom (no count: lines are not messages), no
  divider. At the open the page shows koa's in-memory tail (the last
  64 KB); "Load earlier output · 1.2 MB on disk" at the top reads
  the file backward in 256 KB steps when the tail did not hold the
  start; the button goes when the start is reached. Nothing is
  truncated at the end.
- **The foot** replaces the composer (the field keeps its frame, no
  text input, no model/context/cwd): the state at the left with the
  dot (green breathing "running 3m 04s", red "exit 1 2m 10s", gray
  "done 2m 10s", "stopped", "signal TERM"), the byte count after a
  separator, and at the right one text button: "Stop" while running
  (services too; hover red), "Clear" when ended. Stop sends the
  job's stop; the view stays and shows the end. Clear removes the
  record and returns to the agent's view.
- **The job ends while viewed**: the output shows its last lines, an
  outcome line "exit 1 · 14:30" (the colour of the state) under the
  output, the foot's state changes, Stop becomes Clear. The record's
  60 s linger does not run while the job is viewed: it starts when
  the view is left, so a viewed record never vanishes under the
  reader. A record cleared by another client while viewed: the view
  stays until left, then is gone.
- **Browser mode** (no sidebar): the transcript's job row card gets
  one link "open" at its end that switches to the same view; the view
  bar's back returns. The same link exists in Kido for parity.
- **Keys**: none new; Escape in the view is the agent's abort, as in a
  subagent view, so the view has nothing to abort and Escape does
  nothing.

Renders: /tmp/koa-shots/koa-job-{running,ended,service,running-narrow}-light.png,
koa-job-{running,ended}-dark.png.

- **Settled with the unit** (2026-11-15): the "open" link also on the
  async_bash tool result and on a bash call gone to the background;
  a cleared or pruned record opens read-only from the file (the
  card's facts, foot "cleared", no button; the link hides when the
  file is gone); a missing log shows one muted line "the log is
  gone"; a start failure is foot "failed" red with the error as the
  outcome line; a timeout "timeout 5m 00s" red; "on this Mac" on
  macOS, "on this machine" elsewhere, "on runtime NAME", "on <host>"
  for a remote koa; a chunk that is not the file start drops its
  partial first line, default colour until the first SGR; the output
  keeps the pre's well.

Renders: /tmp/koa-shots/koa-job-{running,ended,service,running-narrow}-light.png,
koa-job-{running,ended}-dark.png.

## Ended subagents and unknown mentions (kido-app-design, 2026-11-16)

- **A restart or a crash ends every subagent of the process.** koa's
  registry after the start is the truth: the new koa clears the
  sidebar records of the agents and jobs of the old process, the same
  as a normal stop, which leaves no row. A live-looking record for a
  gone agent is worse than no row. After a `/restart` the transcript
  gets one info note: "restarted · 2 subagents ended" ("1 subagent
  ended"; none when no subagent ended). Nothing after a crash.
- **An `@name` that matches no agent.** Nothing before submit:
  `@path` is legal. After submit, when a token `@name` matches no
  agent of the scope and no existing path relative to the cwd, one
  warning note follows the user's block: "@pr2549-asses matches no
  agent" (several: "@a, @b match no agent"). The text still goes to
  the model unchanged. An existing path: nothing. A matching agent:
  the link, as before.

## Find and selection on a virtualized transcript (2026-11-16, spec)

koa's page keeps only the rows near the viewport in the DOM
(docs/design-koa.md, "The window"). Kido's find bar asks the page for the match in its model,
the page mounts the row, WKWebView.find highlights it.

- **Count.** The bar shows "3 of 12" for a koa page, as it does for
  a terminal pane: the page counts in its model, so the count is of
  the whole transcript, not of the mounted rows. "No matches" stays
  for zero; "Searching…" while the model is still loading older
  history (the whole-history rule of the pane find).
- **Folds.** A match inside a collapsed run, step or folded fence is
  a match: the page opens that fold to show it when the match is
  made current (Return, ⌘G), as the TUI's search does, and keeps it
  open afterwards (an opened fold is the user's state now). A match
  in a fold that is not current is counted and not opened. A
  thinking step's Markdown counts once rendered: the page renders a
  collapsed thinking step's text for the count (its text is in the
  model).
- **Mounting.** While the page mounts the match's row, the bar keeps
  its last status; the count and the highlight update together in
  the frame the row is mounted. No "Searching…" for the mount: it is
  one frame.
- **Browser mode.** The browser's own find works over the mounted
  rows only, and nothing more: no page-level find bar. The page
  mounts a generous window (the plan's margin) so a ⌘F in a browser
  finds what is near; a whole-history find is Kido's.
- **Selection.** Rows inside an active selection stay mounted. Select
  All (⌘A in the transcript) selects the whole transcript in the
  model, not the mounted rows: the copy produces the whole text from
  the model (the page's own copy handler), and the visible selection
  highlight covers the mounted rows, which is what the eye sees
  anyway. No visible cue is needed because what the user gets is
  right. A drag selection that crosses unmounted rows (scrolling
  while dragging) mounts them as it goes, as the plan says.

## Paths in the transcript open in the editor (2026-11-18, spec)

The user: "sometimes I see references to files and want to open them
in nvim to review." The simplest design: a path in a code span is a
link to the editor float that Control-G already has.

- **What counts.** Only the text of an inline code span, in
  assistant and user blocks and in the opened bodies of agent lines:
  one token of the form `path`, `path:line` or `path:line:col`,
  where `path` is relative or absolute, has no spaces and at least
  one `/` or a file extension (`koa.ts`, `koa/koa.ts:120`,
  `/etc/hosts`, `~/x.md`). Bare prose is never a path: the model
  writes paths in code spans, and prose has too many false hits
  (`and/or`). A span with other text in it (`git add koa.ts`) is not
  a path. No existence check at render: the page knows nothing of the
  file system, and a check for each span would cost a request each;
  the check happens on the click, below.
- **Resolution.** A relative path is against the session's cwd of
  the view (the directory the composer's foot shows); `~` is the
  home; absolute as is. The same cwd whether the tools run on the
  host or in a runtime: when the session's tools are routed, the
  path is a runtime path, and koa resolves it with the routed cwd
  that completion uses (`completionContext`).
- **The gesture.** A plain click, as the page's links: the span gets
  `cursor: pointer` and on hover a 1px underline at 50% of the
  foreground (the links' underline of the solid user block), nothing
  at rest, so a transcript does not fill with link colour. Cmd-click
  is the same; no new modifier. A drag selection over the span does
  not open it (the link rule).
- **What opens.** koa's editor float, as Control-G opens it, with the
  command pi's editor command and `+LINE` before the path when a
  line is given (`nvim +120 koa/koa.ts`; `+LINE` is what vi, vim,
  nvim, nano, emacs and micro take; an editor whose command is not
  one of those gets the path alone), not read-only: the user edits
  if they want, the editor saves to the real file, koa reads
  nothing back. The float's `fixed_title` is the path as the span
  shows it ("koa/koa.ts:120"); `close_confirm` stays `never`, as the
  editor asks itself about unsaved changes. Every click opens a new
  float (the user's decision): koa never closes or replaces an open
  editor, and a float that the user does not close stays. Quitting
  the editor closes its float at once (the default `close: exit`).
  A failure stays, so its error shows: a start failure of the pane
  (cause `failed`), and an editor that exits non-zero, such as a
  missing `$EDITOR` (127), whose wrapper sets the float to
  `close: keep` (the user's decision). An editor killed by a signal
  closes its float.
- **On the click**, before the float: koa stats the resolved path
  where it would open (the host, or the runtime through its exec
  route). A file that is not there gets one warning note in the
  transcript, "koa/koa.ts: no such file", under the row of the span,
  as the unknown-@name warning; a directory opens the editor on the
  directory (nvim's and emacs' browsers; nano says it cannot).
- **Runtime.** A session whose tools are routed opens the editor in
  the runtime: the float's command runs through the runtime's exec
  route with the runtime's environment (`$EDITOR` there, else `vi`),
  because that is where the file is; the host's editor cannot see a
  runtime path. A refused or unready runtime gets the note "koa/x:
  the runtime is not up".
- **Remote and TLS.** The float is a pane of koa's server, so a koa
  in a remote window opens its editor there, exactly as Control-G
  does; nothing differs for the Mac.
- **Browser mode.** No float can open (no ko pane from a browser):
  the span is not a link; a click does nothing. The page gets the
  `pointer` and the underline only when its host can open a float.
- **Snapshots** (KoaWebviewTests, light and dark): a reply with
  three code spans, one a path with a line, one a bare path, one a
  command (`git add koa.ts`, no link), with the pointer over the
  path (the underline); the warning note "no such file" under a
  row; the editor float with the path title (the existing editor
  float snapshot with a new title).

## Threads: the widget, the marks and the filter (threads.html; approved 2026-11-18)

docs/design-koa.md, "Threads". The agent labels its sections with `[thread:
name]` lines; the transcript turns them into marks; the page lists
the threads and filters to one. States `two`, `many`, `many-narrow`,
`marks`, `marks-narrow`, `filter`, `filter-panel`, `filter-narrow`,
light and dark in the gallery.

- **The widget** is a capsule of the view bar's family (fill the
  background mixed 8% toward the foreground, a 0.5pt edge at 16% /
  14% dark, the contact shadow, 22pt high, 8pt radius, 8pt side
  padding, .85em prose) at the top left of the pane, outside the
  scroll, at 8pt from the top and the left. Threads exist only in
  the root agent's view (user, 2026-11-18): a subagent's view has no
  widget, no marks and no filter, and the view bar shows only there,
  so the two never share the corner. While the capsule shows, the
  transcript's top padding is 44pt (the view bar's rule). It does
  not show for a session with no thread. Threads have no status and
  no dot or circle anywhere (user, 2026-11-18): koa sends a name, a
  position, a summary and the time of the last section, and "#
  name" in the thread's colour is the lead, in the widget as in the
  transcript. Content (user, 2026-11-18: show more while the width
  allows, collapse only on overflow): as many threads as fit, newest
  first, each as "# name" ("#" at 55% of the colour, the name at 600
  in it), "·" at 35% between, then "+N" muted for the ones that do
  not fit, then a "▾" in
  the faint colour; a click opens the panel, a second click, Escape
  or a click outside closes it; the pointer is a hand. The fit rule,
  the same at every width: the capsule is at most the pane's width
  minus 16pt; names are added in newest-first order while the whole
  capsule with its tail ("·", "+N" and "▾", or "▾" alone when all
  fit) stays within that; a name is never cut and has no maximum of
  its own (32 characters at most), except the first, which always
  shows and ellipsizes when it alone does not fit. Re-fitted on each
  state update and resize.
- **Two modes** (user, 2026-11-20; threads.html sections 1 and 1b;
  not confirmed, being redesigned: the 10% rule below is retracted,
  and iteration 2 on the page puts the transcript left-aligned and
  the block at its right, with no card, when at least 30 cells are
  free there; do not implement until this note says so).
  The widget is in block mode when its rows can stand at the left of
  the transcript and cover at most 10% of the transcript's width,
  else in line mode: so block in a wide pane, line in a narrow one.
  The rule, with the transcript 720pt at most and centred, so the
  gutter is (pane − transcript) / 2: block when 240pt (the least
  usable block), from 8pt in, exceeds the gutter by at most 10% of
  the transcript's width; the block is then the gutter plus that
  10% wide, at most 340pt (a 1400pt pane: a 340pt gutter, the block
  entirely in it; a 980pt pane: a 130pt gutter, 110pt short, more
  than 72: line mode). Re-decided on each resize. *Line mode* is the
  capsule as before, with two changes: a click on a name applies the
  filter at once (hover underlines the name in its colour at 50%,
  like the reply's pill), and the "▾" is a "…" at the right (the
  muted colour, 600, hover the well2) that opens the panel. *Block
  mode* is the panel's rows standing at the top left of the pane,
  8pt from the top and the left, on the popup's card (user,
  2026-11-20: the panel's background, 1px edge at 18%, 9pt radius,
  the 8/28 shadow at 14%, 6pt padding), with no capsule: for each
  thread, newest first,
  "# name" in the colour (ellipsized at 45% of the block), the
  first line of the last message muted and ellipsized, the age at
  the right, the panel's 28pt rows and 6pt radius, hover the well.
  A click on a row applies the filter; the current row has the
  well2 fill; a click on it or on the "All threads" row under a
  hairline clears it. Block mode has no popup. The transcript keeps
  its normal top padding in block mode (the block stands beside
  it, within the 10%), and the 44pt only in line mode.
- **The panel**, under the capsule (top 36pt, the capsule's left):
  the completion popup's style (the background, a 1px edge at 18%,
  9pt radius, the 8/28 shadow at 14%, 6pt padding, .88em prose),
  300pt to 420pt wide, never wider than the pane minus 16pt, its
  bottom at most at 60% of the pane's height (so its height is at
  most 60% minus its 36pt top) and then scrolling. One row for each
  thread, newest first by the last section's time, a thread with no
  section yet before them, 28pt, 4/8pt padding, 6pt radius, hover the
  well: "# name" in the thread's colour (the name at 600, ellipsized
  at 160pt), the summary
  muted and ellipsized to the row's end, the age of the last section
  at the right in the faint colour at .9em: "now" under a minute,
  then "Nm" to 59m, "Nh" to 23h, then "Nd"; computed when the panel
  opens and at each state update, no timer. A click on
  a row sets the filter and closes the panel. With a filter active,
  the current row has the well2 fill and a last row "All threads",
  separated by a hairline, clears the filter.
- **The mark** (superseded 2026-11-20 by the reply's pill, next
  bullet: a run, agent or job line carries no mark and no colour
  edge. Rendering only: the transcript keeps every item's thread,
  the filter still uses it; the page shows the thread on a reply
  only). The earlier label line, kept for the record:
  .8em prose at line-height 1.35 (a 14pt line box at the 13px base;
  no fixed height), "#" at 55% of the thread's colour, a 6px gap, then the name
  in the colour at 600, 12pt above and 3pt below (10pt above inside
  a reply; none above a reply's first section). The mark is a
  control (user, 2026-11-18): a click sets the filter to its thread,
  like a panel row; the pointer a hand over the label's own box
  (`width: fit-content`, not the whole line); hover underlines the
  name 1px in the colour at 50%, 2pt under the baseline, pressed at
  100%; nothing at rest, so the transcript keeps its quiet labels;
  the pending line is not a control. A mark shows only where the
  thread differs from the last mark above; a line with no thread shows no
  mark and does not reset the last one. A reply about two threads
  has a mark above each section; a run, its steps and a notice get
  none (user, 2026-11-20; see "Runs split only at prose"). A user message never carries a mark: its
  threads are the ones its reply names, and the reply's marks stand
  right under it. Nothing says "new" for a thread's first mark.
- **The reply's pill** (user, 2026-11-20; threads.html `marks`,
  steps.html, lines.html). Inside a reply the mark line is replaced
  by a pill at the right of the message, floated on its first line
  with the text flowing beside it, its time ending on the same
  vertical as the user message's time, the text edge (the pill's
  right margin is minus its own 8pt padding): "# name  HH:MM", "#" at 55% of the
  thread's colour, the name at 600 in it, a 6px gap, the time in
  the mono at tabular numerals, the text .8em at line-height 1.5,
  1pt/8pt padding, 999pt radius, the fill the colour at 10%. The
  time is the message's time, the same clock as the user message's.
  A reply with no thread shows the time alone in the faint colour on
  the foreground at 6%: every assistant message has a pill, in a
  session with no thread too. A reply about two threads has a pill
  on each section, each with the message's time (user, 2026-11-20:
  the same message still needs its time on every pill). The pill is the
  mark's control: the hand over the pill, hover underlines the name
  at 50%, pressed 100%; the time-only pill is no control. With it
  no colour edge remains anywhere (user, 2026-11-20: "remove left
  border everywhere, from tool calls as well"), and a run, agent or
  job line shows no mark (rendering only: the item keeps its thread
  for the filter; the page shows the thread on the reply, whose
  pill stands for the lines of its turn). The user message keeps
  its plain time (chips with its threads were tried and removed,
  user, 2026-11-20). The pending line "waiting for its thread"
  above a pending user message in a filtered view is removed too
  (user, 2026-11-20): the message shows with nothing above it until
  its label arrives.
- **The filter.** In line mode the capsule becomes the thread: "#
  name" in its colour and an × (14pt, the muted colour, hover the
  well2) that clears it; a click on the name opens the panel, and
  the "…" is gone. In block mode the current row is marked and the
  "All threads" row appears. The transcript
  shows the thread's items only; every reply keeps its pill, but
  with the time alone, in the faint style of an unthreaded reply
  (the name would say the same on every row; the filter names the
  thread), plus a pending user
  message, one whose reply the agent is still working on and that
  has no label yet, shown as any user message, with nothing above
  it (an old unlabelled message has no thread and shows only
  unfiltered). The composer's placeholder keeps the page's verb rule
  with the thread added: "Steer @ko in #sidebar…" while the agent
  works, "Message @ko in #sidebar…" when it is idle (the view's
  agent, the thread; the three filter states have a working agent,
  so they show "Steer"), and the foot gets a
  first cell before the model: "#" faint, the name at 600 in the
  foreground, then the separator; at the narrow breakpoints the cell
  stays and the model goes first. The prompt carries the thread and
  koa writes the marker; the queue and steers the same.
- **Narrow pane**: the page's existing narrow breakpoint (the
  transcript's narrow padding rule), not a new one: the panel is the
  pane's width minus 16pt and the section's edge sits 8pt left of
  the text; the capsule follows its fit rule, which needs no rule of
  its own; the mark and the foot cell unchanged.
- **Colour** (user, 2026-11-18: "color code the different
  threads"). A thread's colour is its index in the session's thread
  list (order of first use, stable for the session's life; koa sends
  the index) modulo six, in a palette of six hues that are none of
  the sidebar's status green and orange, the error red or the accent
  blue of the user block:

      index  light     dark
      0      #6a4fcf   #a99bff   violet
      1      #11827e   #52d1c2   teal
      2      #b42d7f   #f27bc0   magenta
      3      #8c6a12   #d8b85a   ochre
      4      #4b6a8a   #94b0cc   slate
      5      #5e7a1e   #b3cf5a   olive

  The light values read on `#FFF9EC` at 4.5:1 or better; the dark
  on `#171717`. The colour shows on the name wherever the name is:
  the mark ("#" at 55% of it, the name at 600 in it), the panel
  row's name, the filtered capsule's name, the composer's foot cell;
  and as a 2pt edge at the section's left, in the transcript's gutter
  12pt left of the text (8pt in a narrow pane), 1pt radius, the
  colour at 45%, one continuous line spanning the section (a reply
  section, or a run, agent or job line and what follows it in the
  same thread) to its last line. The summary stays muted; nothing fills, so the user
  block's accent stays the one filled thing. A seventh thread shares
  the first's hue: the name tells them apart, the colour is a scan
  aid, not an identity.
- **Snapshots** (KoaWebviewTests, light and dark): the eight states
  above.

## ⌘O in a koa pane: the selection goes into the composer (2026-11-19, spec)

The user: "if I select some text and click ⌘O we open a prompt
dialogue but I'd prefer koa to handle that and just put the selected
text into own composer." So in a koa pane ⌘O is the page's, not the
palette's. One page function does it, `quoteSelection()`, which the
app calls for ⌘O (as it calls the page's find) and which the page
binds itself in browser mode.

- **A transcript selection.** The selected text, as `answers.ts`'s
  `quote()` makes it (Markdown syntax removed, one line per line,
  blank lines dropped), goes into the composer as `> ` lines in
  koa's own quote format (`head()`): at the end of the draft; a
  draft that is not empty and does not end with a blank line gets a
  blank line first; then the quote lines; then a newline and the
  caret on the empty line directly under the quote, where an answer
  goes (the format of the reply annotations, so `current()` and
  `answer()` read it). A second ⌘O appends the same way after the
  text typed so far (a blank line, the quote, the caret line);
  duplicates are not skipped. The composer takes the focus and
  scrolls to the caret; the transcript's selection is cleared, as
  the palette clears it on delivery. The dock grows as it does for
  typing.
- **No selection.** ⌘O focuses the composer, nothing more: in a koa
  pane "prompt" is the composer. With the focus already there,
  nothing happens; no beep.
- **A selection inside the composer** is not a transcript selection:
  ⌘O does nothing (the composer has the focus; the user can indent
  with `> ` themselves).
- **The menu item.** In a koa pane the Edit item reads "Quote
  Selection" (⌘O) with a selection and "Focus Composer" (⌘O) without,
  no ellipsis: no dialog opens. In a terminal pane it stays "Prompt
  with Selection…" / "Prompt…" and opens the palette's Prompt mode as
  today. The webview's context menu does not change.
- **Views.** A subagent's view: the quote goes into that view's
  composer, which targets the viewed agent, and into that view's
  draft. The job view has no composer; ⌘O goes to the job's owner
  through the terminal path, "Prompt with Selection…" / "Prompt…":
  the palette's Prompt mode with the job view's selection as the
  quote and the job's real owner, root agent or subagent,
  preselected: the app preselects the job's record, and the palette
  resolves it to its owner (the longest prefix among its candidates).
  The menu item has the terminal titles there.
- **Browser mode.** The page binds ⌘O (⌃O where ⌘ is not the
  modifier) itself to `quoteSelection()` and prevents the browser's
  default, so the behaviour is the same; the app's call and the key
  share the one function. With no app there is no palette: in a
  job view, ⌘O does nothing.
- **Snapshots** (KoaWebviewTests, light and dark): a transcript
  selection quoted into an empty composer with the caret line under
  it; a second quote appended after typed text (blank line, quote,
  caret).

## The bare dots row never leaves mid-turn (user, 2026-11-20, spec; steps.html section 1)

The user sees the bare dots row appear, then vanish, and the layout
jump up. The invariant: once a turn has rendered the bare row, no
frame before the turn's end removes its vertical space. The rule of
the last element stays; its transitions are now these, and only
these:

- **The bare row is the last element, always.** It exists after the
  user's message before anything else, and under streaming text.
  Reply text appends above it (the text block is inserted before the
  row), so the row stays last and the text grows over it; the row
  never moves above the text, and the caret carries no second mark.
- **Bare row → run widget is a change of the same node.** When a
  tool call or a thinking block starts while the bare row shows, the
  row becomes that run's own line: the same element gains the
  chevron and the name, the mark moves from the name's place to
  where the summary rule puts it, in one frame. The bare row is
  exactly a run line's height and sits with a run line's spacing (it
  is one), so nothing is reserved and nothing jumps: the row count
  and the height are the same before and after. A run never appends
  as a new row beside a bare row.
- **Run widget → bare row** happens only when text starts streaming
  after a run: the text block appends below the run and the bare row
  appends below the text, in the frame of the first text patch; the
  mark leaves the run's line. Growth, never removal. When that text
  is final and a run follows, the bare row becomes the run's line
  (the rule above).
- **Nothing else moves the row.** A step that finishes, a parallel
  step, a message, a job event: the mark changes place inside the
  run, the bare row (if any, under text) stays.
- **The turn's end** removes the bare row in one frame, with the
  Auto-scroll rule (following keeps the bottom, so the content moves
  up by one row's height at most, once, when the agent is done); an
  abort turns a running step into the "aborted" row and removes the
  bare row in the same frame. These are the only removals.
- **Reduce Motion**: the same frames, static dots.

## Agent messages and jobs are steps of the run (user, 2026-11-20, spec; steps.html section 2)

The user: the transcript is too long; messages from and to agents,
reports and async_bash job items go inside the tool/thinking run
widget as steps. The user's own messages and the assistant's prose
stay rows; koa's own notice rows (lines.html, A) stay rows (amended
by "Runs split only at prose" below: a notice after a step joins the
run).

- **The run** is every consecutive thinking block, tool call, agent
  message (outgoing `spawn_agent`, `message_agent`; incoming
  `ko-message`, `ko-steer`, `ko-notice`, a report, a child's end) and
  job item (an `async_bash` start, a stream batch, a job's end)
  between two assistant texts, or between the user's message and the
  first text. An agent card no longer splits a run; "A card splits
  the run it sits in" and the separate card and job rows of
  agents.html and lines.html item 5 are superseded.
- **An agent step, folded** is one step line like a tool's: the name
  is the header phrase of the card, in the step's name tone
  ("message to @impl", "steer from @ko parent", "report from
  @reviewer subagent", "@impl ended"; the @name in 600 in the fg
  as today), then the body's first line in the fg colour where a
  tool shows its command, ellipsized before the time, the time at
  the right. A failure colours the name red as a failed tool's
  ("refused to @impl"; "not reported from @impl"): colour only.
- **An agent step, open**: the whole body as prose in the step's
  details, `--ko-fg`, no height cap (the agent body never had one);
  the quote and Markdown as the card rendered them; @names linked
  as everywhere.
- **A job step, folded**: the name is "job <name>" with the job's
  name in the fg ("job make-verify"), the detail the event: a start
  "started", a stream "N lines", an end "exit 0" muted, "exit 1",
  "signal TERM", "failed", "timeout 60s" in `--ko-color-1` with the
  name (the job line's rule: no end text, no exit wording beyond
  the number). The time at the right. Open: the output as a bash
  step shows it (a well, 260pt cut, scrollable) with the "open" link
  to the in-page job view at the well's head, as the async_bash
  result has it; a start has no body and does not open.
- **The folded run summary**: names in order of first occurrence,
  tools as today ("thinking, bash x2"), agent steps as "to @impl"
  and "from @impl" ("to @impl x2"; a report is "from"), job steps as
  "job make-verify"; a failed step's name red; no counts beyond xN,
  no icons. The dots rule is unchanged (the run is just larger).
- **Times** (runsteps, 2026-11-20). A run's time is the duration of
  its timed steps, as today: a tool, a thinking block, and an
  outgoing agent step (a `spawn_agent` or `message_agent` call is a
  tool call: its line shows the call's duration like a tool, not
  the card's clock time). An incoming step (a message, a steer, a
  report, a child's end, a notice) and a job event are moments:
  their line shows the clock time, and they add nothing to the
  run's duration. A run with no timed step (an idle report, "job
  verify-unit, job lint") shows the clock time of its last step at
  the right of the summary, so the folded line still says when; a
  mixed run shows its duration. So the line's time is a duration
  when the run has a timed step, else the last moment.
  notice) joins the last element when that is a run and nothing
  stands between (no user message, no assistant text); otherwise it
  starts a new run row with that one step, folded, at the end. The
  next item joins it. Whether the item starts a turn is pi's; the
  turn's first step joins the same run, because it is consecutive.
  visible content, or a run with at least one step shown, counts
- **Outside a turn.** An incoming item (a report, a job's end, a
  notice) joins the last element when that is a run and nothing
  stands between (no user message, no assistant text); otherwise it
  starts a new run row with that one step, folded, at the end. The
  next item joins it. Whether the item starts a turn is pi's; the
  turn's first step joins the same run, because it is consecutive.
- **Unread counting**: the rule stands: an assistant text with
  visible content, or a run with at least one step shown, counts
  once when it appears; a step that joins an existing run adds no
  count and moves no divider. So a report while idle is one new
  item (its new run), and a report inside a working run is none.
- **Threads**: superseded by "Runs split only at prose" below.
- **Find and copy**: a step's body is in the model like a tool's
  details: counted when folded, opened when current, selected and
  copied with the transcript.
- **Browser mode and subagent views**: the same rendering; a
  subagent's view shows its own messages to its children, their
  reports, and its parent's messages as steps of its runs.

## Runs split only at prose (user, 2026-11-20)

The user saw one turn as three adjacent run rows: its tools carried
no thread, its `async_bash` job carried one, and the run split at
each change. The decision: a step's thread never splits a run, and
koa's notices join runs too.

- **A run splits** only at a user message, assistant text with
  visible content, a `!` command row (the user's input) and a gap of
  unloaded history. Agent, job and tool steps of any threads stay
  one run.
- **A notice in a run.** A notice (a notification, a command
  outcome, koa's note, the reply's error, a history summary) that
  follows a step of the open run is a step of it: its one muted line
  with the warning or error colour, opening to its row's body when
  it has one. The folded summary names it by family: "note",
  "notify", "command", "error", "compacted", "branch". A notice with
  no open run (after prose, after the user's message, at the start)
  stays a row, and a later step starts a new run below it.
- **Thread marks** stand only on prose: a run, its steps and a
  notice carry none.
- **The filter** keeps the unfiltered runs: prose of another thread
  still ends a run, and two runs never merge because the prose
  between them is hidden. A run's thread is the first known thread
  of its steps (a notice has none); the run shows whole under that
  thread's filter and hides under the others. A run with no known
  thread shows only unfiltered.
